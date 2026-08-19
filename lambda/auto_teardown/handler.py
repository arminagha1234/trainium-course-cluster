"""
Auto-teardown Lambda for the Trainium Course Cluster.

Invoked by a one-time EventBridge Scheduler schedule (infra/auto-teardown.yaml)
that fires at the MLCB `EndDateTime`. Deletes the ParallelCluster CloudFormation
stack and the Budget_Stack via the CloudFormation API, then reports progress to
the parent stack's alerts SNS topic. The Parent_Stack (VPC / EFS / manifest) and
the EFS filesystem are deliberately left untouched so student work survives
end-of-block teardown (Requirement 22, divergence D1).

Environment variables (set by the CFN template):
  CLUSTER_NAME         cluster identifier, used in notification text
  CLASS_TAG            Class= tag value, used in notification text
  PCLUSTER_STACK_NAME  ParallelCluster CloudFormation stack name to delete
  BUDGET_STACK_NAME    Budget_Stack name to delete
  PARENT_STACK_NAME    Parent_Stack name - NEVER deleted; used only as a guard
  ALERTS_TOPIC_ARN     SNS topic ARN for start/success/failure notifications
  AWS_TARGET_REGION    region for CloudFormation + SNS (echoes AWS::Region)

Unlike lambda/student_manifest/handler.py this is NOT a CloudFormation custom
resource - it is a scheduled invocation, so it sends no CFN (urllib) response.

Notification contract (Requirement 22.3/22.4/22.5):
  - start:   published unconditionally when the handler begins.
  - success: published only when every targeted stack reaches DELETE_COMPLETE.
  - failure: published when any targeted stack reaches a *_FAILED state or the
             delete cannot be initiated.
An extra "in progress" notification is published when the Lambda's time budget
is exhausted before the (long-running) ParallelCluster delete completes; this
avoids falsely reporting success (22.4) or failure (22.5) for a delete that is
still healthy.
"""

from __future__ import annotations

import json
import logging
import os
import time
from typing import Any

import boto3
from botocore.exceptions import ClientError

log = logging.getLogger()
log.setLevel(logging.INFO)

# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------
CLUSTER_NAME = os.environ.get("CLUSTER_NAME", "unknown-cluster")
CLASS_TAG = os.environ.get("CLASS_TAG", "unknown")
PCLUSTER_STACK_NAME = os.environ.get("PCLUSTER_STACK_NAME", "")
BUDGET_STACK_NAME = os.environ.get("BUDGET_STACK_NAME", "")
PARENT_STACK_NAME = os.environ.get("PARENT_STACK_NAME", "")
ALERTS_TOPIC_ARN = os.environ.get("ALERTS_TOPIC_ARN", "")
REGION = os.environ.get("AWS_TARGET_REGION") or os.environ.get("AWS_REGION")

# Milliseconds reserved at the end of the invocation so the final SNS
# notification always goes out before the Lambda times out.
_RESERVE_MS = 20_000
_POLL_SECONDS = 15

cfn = boto3.client("cloudformation", region_name=REGION)
sns = boto3.client("sns", region_name=REGION)


# -----------------------------------------------------------------------------
# SNS notifications
# -----------------------------------------------------------------------------
def _publish(subject: str, message: str) -> None:
    """Publish an alert to the imported alerts topic.

    Never raises: a notification hiccup must not abort (or mask) the teardown.
    """
    if not ALERTS_TOPIC_ARN:
        log.warning("ALERTS_TOPIC_ARN not set; skipping SNS publish: %s", subject)
        return
    # SNS subjects are capped at 100 chars and may not contain newlines.
    clean_subject = subject.replace("\n", " ")[:100]
    try:
        sns.publish(TopicArn=ALERTS_TOPIC_ARN, Subject=clean_subject, Message=message)
        log.info("published alert: %s", clean_subject)
    except ClientError as e:
        log.error("failed to publish SNS alert %r: %s", clean_subject, e)


# -----------------------------------------------------------------------------
# CloudFormation helpers
# -----------------------------------------------------------------------------
def _describe_stack(stack_ref: str) -> dict | None:
    """Return the stack description, or None if the stack does not exist.

    `stack_ref` may be a stack name or a stack id (ARN). Querying by id lets us
    observe DELETE_COMPLETE after the name stops resolving.
    """
    try:
        resp = cfn.describe_stacks(StackName=stack_ref)
        stacks = resp.get("Stacks", [])
        return stacks[0] if stacks else None
    except ClientError as e:
        msg = e.response.get("Error", {}).get("Message", "")
        if "does not exist" in msg:
            return None
        raise


def _initiate_delete(name: str) -> str | None:
    """Start deletion of stack `name`.

    Returns the StackId to poll, or None if the stack is already absent
    (idempotent no-op, mirroring teardown.sh + the manifest lambda's delete).
    """
    stack = _describe_stack(name)
    if stack is None:
        log.info("stack %s already absent; nothing to delete", name)
        return None
    stack_id = stack["StackId"]
    cfn.delete_stack(StackName=name)
    log.info("initiated delete of stack %s (%s)", name, stack_id)
    return stack_id


def _build_targets() -> list[str]:
    """Ordered list of stacks to delete: pcluster first, then budget.

    The parent stack is refused defensively so that no code path can delete the
    VPC / EFS / manifest scaffolding that holds student work (Requirement 22.2).
    The two targets have no interdependency (neither imports the other), so the
    order is only a convention shared with teardown.sh.
    """
    targets: list[str] = []
    for name in (PCLUSTER_STACK_NAME, BUDGET_STACK_NAME):
        if not name:
            continue
        if name == PARENT_STACK_NAME:
            log.error("refusing to delete parent stack %s (holds EFS/student work)", name)
            continue
        targets.append(name)
    return targets


def _run_teardown(targets: list[str], context: Any) -> dict[str, str]:
    """Initiate deletes then wait (bounded) for terminal states.

    Returns a {stack_name: "deleted" | "failed" | "in_progress"} map.
    """
    results: dict[str, str] = {}
    pending: dict[str, str] = {}  # stack_name -> stack_id

    for name in targets:
        try:
            stack_id = _initiate_delete(name)
            if stack_id is None:
                results[name] = "deleted"
            else:
                pending[name] = stack_id
        except ClientError as e:
            log.error("failed to initiate delete of %s: %s", name, e)
            results[name] = "failed"

    # Poll (check-then-sleep so already-gone stacks resolve without waiting),
    # always leaving _RESERVE_MS for the closing notification.
    while pending and context.get_remaining_time_in_millis() > _RESERVE_MS:
        for name in list(pending):
            try:
                stack = _describe_stack(pending[name])
            except ClientError as e:
                log.warning("describe during wait failed for %s: %s", name, e)
                continue
            if stack is None:
                results[name] = "deleted"
                pending.pop(name)
                continue
            status = stack["StackStatus"]
            log.info("stack %s status=%s", name, status)
            if status == "DELETE_COMPLETE":
                results[name] = "deleted"
                pending.pop(name)
            elif status.endswith("_FAILED"):
                results[name] = "failed"
                pending.pop(name)

        if not pending:
            break
        if context.get_remaining_time_in_millis() <= _RESERVE_MS + _POLL_SECONDS * 1000:
            break
        time.sleep(_POLL_SECONDS)

    # Whatever is still pending ran past our time budget but has not failed.
    for name in pending:
        results[name] = "in_progress"
    return results


# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------
def lambda_handler(event: dict, context: Any):
    log.info("auto-teardown invoked; event=%s", json.dumps(event) if event else "{}")

    targets = _build_targets()
    retained = (
        f"The parent stack ('{PARENT_STACK_NAME}') and the EFS filesystem are "
        f"retained; student work is preserved."
    )

    _publish(
        subject=f"[{CLUSTER_NAME}] end-of-block teardown started",
        message=(
            f"Automated end-of-block teardown has started for cluster "
            f"'{CLUSTER_NAME}' (Class={CLASS_TAG}) in {REGION}.\n\n"
            f"Deleting stacks: {', '.join(targets) or '(none found)'}.\n\n"
            f"{retained}"
        ),
    )

    try:
        results = _run_teardown(targets, context)
    except Exception as e:  # noqa: BLE001 - report any unexpected failure
        log.exception("auto-teardown failed unexpectedly")
        _publish(
            subject=f"[{CLUSTER_NAME}] end-of-block teardown FAILED",
            message=(
                f"Automated end-of-block teardown for cluster '{CLUSTER_NAME}' "
                f"failed with an unexpected error: {type(e).__name__}: {e}\n\n"
                f"{retained}\n\nInspect the Lambda logs and re-run "
                f"scripts/teardown.sh if needed."
            ),
        )
        return {"status": "failed", "error": f"{type(e).__name__}: {e}"}

    deleted = sorted(n for n, s in results.items() if s == "deleted")
    failed = sorted(n for n, s in results.items() if s == "failed")
    in_progress = sorted(n for n, s in results.items() if s == "in_progress")

    if failed:
        _publish(
            subject=f"[{CLUSTER_NAME}] end-of-block teardown FAILED",
            message=(
                f"Automated end-of-block teardown for cluster '{CLUSTER_NAME}' "
                f"(Class={CLASS_TAG}) did not complete cleanly.\n\n"
                f"Failed: {', '.join(failed)}\n"
                f"Deleted: {', '.join(deleted) or '(none)'}\n"
                f"Still in progress: {', '.join(in_progress) or '(none)'}\n\n"
                f"{retained}\n\nInspect the CloudFormation events for the failed "
                f"stack(s) and re-run scripts/teardown.sh if needed."
            ),
        )
        return {"status": "failed", "results": results}

    if in_progress:
        _publish(
            subject=f"[{CLUSTER_NAME}] end-of-block teardown in progress",
            message=(
                f"Automated end-of-block teardown for cluster '{CLUSTER_NAME}' "
                f"(Class={CLASS_TAG}) was initiated and is still running.\n\n"
                f"Still deleting: {', '.join(in_progress)}\n"
                f"Already deleted: {', '.join(deleted) or '(none)'}\n\n"
                f"{retained}\n\nDeletion will continue asynchronously in "
                f"CloudFormation after this notification."
            ),
        )
        return {"status": "in_progress", "results": results}

    _publish(
        subject=f"[{CLUSTER_NAME}] end-of-block teardown complete",
        message=(
            f"Automated end-of-block teardown for cluster '{CLUSTER_NAME}' "
            f"(Class={CLASS_TAG}) completed successfully.\n\n"
            f"Deleted: {', '.join(deleted) or '(none)'}\n\n"
            f"{retained}"
        ),
    )
    return {"status": "succeeded", "results": results}
