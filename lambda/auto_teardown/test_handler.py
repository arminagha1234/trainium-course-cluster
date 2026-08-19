"""
Unit tests for the auto-teardown Lambda using moto.

Exercises lambda_handler / _build_targets / _run_teardown against moto-backed
CloudFormation, SNS, and EFS -- no real AWS is touched. Verifies the behavior
promised by Requirement 22 (design divergence D1):

  - 22.2  The parent stack and the EFS filesystem are RETAINED whether the
          teardown succeeds or fails; the parent stack is refused defensively
          even if it were ever passed as a target.
  - 22.3  A "started" notification is published to the alerts SNS topic.
  - 22.4  A "complete" (success) notification is published once both target
          stacks are deleted.
  - 22.5  A "FAILED" notification is published when a delete cannot complete.

Style/setup mirrors lambda/student_manifest/test_handler.py: env vars are set
BEFORE the handler is imported (its config + boto3 clients are baked in at
module import), the import happens under an active `mock_aws()`, and outbound
calls are captured by patching the client method (there: urlopen; here:
sns.publish) so we can assert exactly what would have been sent.

Run:
  cd trainium-course-cluster/lambda/auto_teardown
  python -m pytest test_handler.py -v
"""

from __future__ import annotations

import json
import os
import sys
from unittest.mock import patch

import boto3
import pytest
from botocore.exceptions import ClientError
from moto import mock_aws


CLUSTER = "test-cluster"
CLASS_TAG = "nki-test"
REGION = "us-east-2"

PCLUSTER_STACK = "test-cluster-pcluster"
BUDGET_STACK = "test-cluster-budget"
PARENT_STACK = "test-cluster-parent"

# moto's default account id is 123456789012, so this ARN is deterministic and
# can be set in the environment (before import) without first creating the topic.
ALERTS_TOPIC_ARN = f"arn:aws:sns:{REGION}:123456789012:{CLUSTER}-alerts-topic"

# Minimal template body whose single resource type is modeled by moto's
# CloudFormation implementation, so create/describe/delete behave like a real
# stack. An SQS queue needs no required properties and stands in cheaply for
# "a stack exists".
_TEMPLATE = json.dumps(
    {
        "AWSTemplateFormatVersion": "2010-09-09",
        "Resources": {"Placeholder": {"Type": "AWS::SQS::Queue"}},
    }
)


@pytest.fixture(autouse=True)
def moto_env():
    """Set the env the handler reads at import, then import it fresh under moto.

    The handler builds its module-level config (CLUSTER_NAME, *_STACK_NAME,
    ALERTS_TOPIC_ARN, REGION) and its boto3 `cfn` / `sns` clients at import time,
    so the environment must exist and `mock_aws()` must be active *before* the
    import for those clients to be moto-backed.
    """
    os.environ.update(
        {
            "CLUSTER_NAME": CLUSTER,
            "CLASS_TAG": CLASS_TAG,
            "PCLUSTER_STACK_NAME": PCLUSTER_STACK,
            "BUDGET_STACK_NAME": BUDGET_STACK,
            "PARENT_STACK_NAME": PARENT_STACK,
            "ALERTS_TOPIC_ARN": ALERTS_TOPIC_ARN,
            "AWS_TARGET_REGION": REGION,
            "AWS_DEFAULT_REGION": REGION,
            # Dummy credentials so botocore can sign under moto in any environment.
            "AWS_ACCESS_KEY_ID": "testing",
            "AWS_SECRET_ACCESS_KEY": "testing",
            "AWS_SECURITY_TOKEN": "testing",
            "AWS_SESSION_TOKEN": "testing",
        }
    )

    with mock_aws():
        # Import (or re-import) the handler so its module-level clients bind to
        # the active moto session. Drop any cached `handler` first so we don't
        # pick up a sibling lambda's module of the same name.
        sys.path.insert(0, os.path.dirname(__file__))
        sys.modules.pop("handler", None)
        import handler  # noqa: F401  # imported under moto with env set

        yield handler

        # Leave no cached module behind for other test modules / sessions.
        sys.modules.pop("handler", None)


# -----------------------------------------------------------------------------
# Test doubles
# -----------------------------------------------------------------------------
class _PublishRecorder:
    """Stands in for sns.publish so we can capture start/success/failure alerts.

    Mirrors the manifest test's _CapturingResponse (which stubs urlopen): we
    record the outbound call args instead of hitting the mocked service, so the
    assertions read the exact TopicArn / Subject / Message the handler emits.
    """

    def __init__(self):
        self.calls: list[dict] = []

    def __call__(self, **kwargs):
        self.calls.append(kwargs)
        return {"MessageId": "test-message-id"}

    @property
    def subjects(self) -> list[str]:
        return [c.get("Subject", "") for c in self.calls]


class _FakeContext:
    """Minimal Lambda context exposing get_remaining_time_in_millis().

    Returns a large budget that decreases on each call. The handler's poll loop
    uses the value to decide whether to keep waiting; starting high lets the
    (synchronous, under moto) deletes be observed on the first pass, while the
    monotonic decrease guarantees the loop can never spin forever even if a
    delete were somehow never observed to reach a terminal state.
    """

    def __init__(self, start_ms: int = 300_000, step_ms: int = 60_000):
        self._remaining = start_ms
        self._step = step_ms

    def get_remaining_time_in_millis(self) -> int:
        current = self._remaining
        self._remaining -= self._step
        return current


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
def _create_stack(name: str) -> None:
    boto3.client("cloudformation", region_name=REGION).create_stack(
        StackName=name, TemplateBody=_TEMPLATE
    )


def _stack_present(name: str) -> bool:
    """True if a stack `name` currently exists (and is not already deleted)."""
    cfn = boto3.client("cloudformation", region_name=REGION)
    try:
        stacks = cfn.describe_stacks(StackName=name)["Stacks"]
    except ClientError:
        return False
    return bool(stacks) and stacks[0]["StackStatus"] != "DELETE_COMPLETE"


def _create_efs() -> str:
    """Create a stand-in 'student work' EFS filesystem; return its id."""
    fs = boto3.client("efs", region_name=REGION).create_file_system(
        CreationToken="student-work"
    )
    return fs["FileSystemId"]


def _efs_ids() -> list[str]:
    efs = boto3.client("efs", region_name=REGION)
    return [f["FileSystemId"] for f in efs.describe_file_systems()["FileSystems"]]


# -----------------------------------------------------------------------------
# _build_targets: which stacks the handler will delete (Requirement 22.2 guard)
# -----------------------------------------------------------------------------
def test_build_targets_lists_pcluster_then_budget(moto_env):
    handler = moto_env
    assert handler._build_targets() == [PCLUSTER_STACK, BUDGET_STACK]


def test_build_targets_refuses_parent_stack(moto_env, monkeypatch):
    """Defensive guard: a target equal to PARENT_STACK_NAME is never deleted.

    Force the budget-stack slot to collide with the parent stack name and assert
    _build_targets drops it, so no code path can target the stack that holds the
    VPC / EFS / student work (Requirement 22.2).
    """
    handler = moto_env
    monkeypatch.setattr(handler, "BUDGET_STACK_NAME", handler.PARENT_STACK_NAME)

    targets = handler._build_targets()

    assert handler.PARENT_STACK_NAME not in targets
    assert targets == [PCLUSTER_STACK]


# -----------------------------------------------------------------------------
# Success path (Requirements 22.2, 22.3, 22.4)
# -----------------------------------------------------------------------------
def test_teardown_deletes_targets_retains_parent_and_efs_and_notifies(moto_env):
    handler = moto_env

    _create_stack(PCLUSTER_STACK)
    _create_stack(BUDGET_STACK)
    _create_stack(PARENT_STACK)
    fs_id = _create_efs()
    efs_before = set(_efs_ids())

    recorder = _PublishRecorder()
    with patch.object(handler.sns, "publish", recorder), \
            patch.object(handler.time, "sleep", lambda *a, **k: None):
        result = handler.lambda_handler({}, _FakeContext())

    # Both target stacks were deleted...
    assert result["status"] == "succeeded", result
    assert not _stack_present(PCLUSTER_STACK)
    assert not _stack_present(BUDGET_STACK)
    assert result["results"] == {PCLUSTER_STACK: "deleted", BUDGET_STACK: "deleted"}

    # ...the parent stack was NOT (never a target) -- 22.2...
    assert _stack_present(PARENT_STACK)
    assert PARENT_STACK not in result["results"]

    # ...and the EFS filesystem survives untouched -- 22.2.
    assert fs_id in _efs_ids()
    assert set(_efs_ids()) == efs_before

    # Start (22.3) + success (22.4) notifications went to the alerts topic;
    # no failure/in-progress alert on the clean path.
    assert all(c["TopicArn"] == ALERTS_TOPIC_ARN for c in recorder.calls)
    assert any("teardown started" in s for s in recorder.subjects), recorder.subjects
    assert any("teardown complete" in s for s in recorder.subjects), recorder.subjects
    assert not any("FAILED" in s for s in recorder.subjects), recorder.subjects
    assert not any("in progress" in s for s in recorder.subjects), recorder.subjects


# -----------------------------------------------------------------------------
# Failure path (Requirements 22.5, and 22.2 "whether succeeds or fails")
# -----------------------------------------------------------------------------
def test_teardown_publishes_failure_notification_and_retains_efs(moto_env):
    handler = moto_env

    _create_stack(PCLUSTER_STACK)
    _create_stack(BUDGET_STACK)
    _create_stack(PARENT_STACK)
    fs_id = _create_efs()

    # Simulate a delete that cannot be initiated -- the handler's documented
    # failure trigger ("the delete cannot be initiated").
    delete_error = ClientError(
        {"Error": {"Code": "ValidationError", "Message": "simulated delete failure"}},
        "DeleteStack",
    )

    recorder = _PublishRecorder()
    with patch.object(handler.sns, "publish", recorder), \
            patch.object(handler.time, "sleep", lambda *a, **k: None), \
            patch.object(handler.cfn, "delete_stack", side_effect=delete_error):
        result = handler.lambda_handler({}, _FakeContext())

    # Handler reports failure and emits both a start (22.3) and a FAILED (22.5)
    # notification to the alerts topic.
    assert result["status"] == "failed", result
    assert all(c["TopicArn"] == ALERTS_TOPIC_ARN for c in recorder.calls)
    assert any("teardown started" in s for s in recorder.subjects), recorder.subjects
    assert any("FAILED" in s for s in recorder.subjects), recorder.subjects

    # EFS and the parent stack are retained even when teardown fails -- 22.2.
    assert fs_id in _efs_ids()
    assert _stack_present(PARENT_STACK)
