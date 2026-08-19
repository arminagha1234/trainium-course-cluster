"""
Unit tests for the cost kill-switch Lambda using moto.

Launches a mix of EC2 instances under moto's mocked EC2 and asserts
`lambda_handler` in `lambda/kill_switch/handler.py` stops exactly the right set,
per Requirement 20 (design divergence D13):

  - 20.3  Only class-tagged instances are ever in scope; an instance without the
          class tag is ignored entirely (never stopped, never even considered).
  - 20.4  The prepaid MLCB compute fleet is spared. The ParallelCluster fleet
          carries `AutoStop=false` (propagated from the cluster config in
          infra/pcluster-config.yaml), so any class-tagged instance also tagged
          `AutoStop=false` is NOT stopped.
  - 20.5  Active student sessions are spared for the same reason: the head node
          and the compute nodes running student jobs are all part of that
          `AutoStop=false` fleet.

Any OTHER class-tagged instance (a genuine runaway with no `AutoStop=false` tag)
IS stopped -- the containment backstop (20.3).

Style mirrors the sibling suites (lambda/auto_teardown/test_handler.py,
lambda/student_manifest/test_handler.py): the handler resolves its config
(CLASS_TAG, REGION) and constructs its module-level boto3 EC2 client at import
time, so the environment is set and `mock_aws()` is active BEFORE the handler is
imported -- otherwise that client would not be moto-backed. No real AWS is ever
contacted.

Run:
  cd trainium-course-cluster/lambda/kill_switch
  python -m pytest test_handler.py -v
"""

from __future__ import annotations

import os
import sys

import boto3
import pytest
from moto import mock_aws


CLASS_TAG = "nki-test"
REGION = "us-east-2"

# moto accepts an arbitrary well-formed AMI id for run_instances; no real image
# is resolved and nothing is billed -- it just needs to look like an AMI id.
AMI_ID = "ami-0abcdef1234567890"

# A representative SNS event (the budget stack invokes the switch via SNS at the
# 90% ACTUAL threshold). The handler only logs the event, so its exact shape is
# irrelevant to the scoping logic under test -- any truthy dict works.
BUDGET_EVENT = {
    "Records": [
        {"EventSource": "aws:sns", "Sns": {"Message": "class budget 90% ACTUAL breached"}}
    ]
}


@pytest.fixture(autouse=True)
def moto_env():
    """Set the env the handler reads at import, then import it fresh under moto.

    The handler resolves CLASS_TAG / REGION and constructs its module-level
    ``ec2`` client at import time, so the environment must exist and
    ``mock_aws()`` must be active *before* the import for that client to be
    moto-backed. We drop any cached ``handler`` first so we don't pick up a
    sibling lambda's module of the same name.
    """
    os.environ.update(
        {
            "CLASS_TAG": CLASS_TAG,
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
        sys.path.insert(0, os.path.dirname(__file__))
        sys.modules.pop("handler", None)
        import handler  # noqa: F401  # imported under moto with env set

        yield handler

        # Leave no cached module behind for other test modules / sessions.
        sys.modules.pop("handler", None)


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
def _launch(tags: dict[str, str] | None = None) -> str:
    """Launch one (running) instance carrying `tags`; return its instance id.

    moto starts run_instances instances in the ``running`` state, which is what
    the handler's ``instance-state-name=running`` describe filter selects.
    """
    ec2 = boto3.client("ec2", region_name=REGION)
    kwargs: dict = {"ImageId": AMI_ID, "MinCount": 1, "MaxCount": 1}
    if tags:
        kwargs["TagSpecifications"] = [
            {
                "ResourceType": "instance",
                "Tags": [{"Key": k, "Value": v} for k, v in tags.items()],
            }
        ]
    return ec2.run_instances(**kwargs)["Instances"][0]["InstanceId"]


def _state(instance_id: str) -> str:
    """Current EC2 state name for `instance_id` (e.g. 'running', 'stopped')."""
    ec2 = boto3.client("ec2", region_name=REGION)
    reservations = ec2.describe_instances(InstanceIds=[instance_id])["Reservations"]
    return reservations[0]["Instances"][0]["State"]["Name"]


# -----------------------------------------------------------------------------
# Full scoping: spare the fleet, stop runaways, ignore out-of-scope instances
# (Requirements 20.3, 20.4, 20.5)
# -----------------------------------------------------------------------------
def test_stops_runaway_spares_fleet_ignores_untagged(moto_env):
    handler = moto_env

    # AutoStop=false -> the ParallelCluster head + compute fleet. Sparing these
    # protects the prepaid MLCB compute (20.4) and active student sessions (20.5).
    fleet_head = _launch({"Class": CLASS_TAG, "AutoStop": "false", "Name": "head"})
    fleet_compute = _launch({"Class": CLASS_TAG, "AutoStop": "false", "Name": "compute"})
    # A capitalised value still spares -- the handler lower-cases + strips.
    fleet_capital = _launch({"Class": CLASS_TAG, "AutoStop": "False"})

    # Class-tagged but NOT AutoStop=false -> genuine runaways that must be stopped.
    runaway_plain = _launch({"Class": CLASS_TAG, "Name": "stray-box"})
    runaway_autostop_true = _launch({"Class": CLASS_TAG, "AutoStop": "true"})

    # Out of scope: a different class tag, and no tags at all. The handler's
    # tag:Class describe filter must never surface these (20.3).
    other_class = _launch({"Class": "some-other-class", "AutoStop": "false"})
    untagged = _launch(None)

    # Context is unused by the handler; pass a minimal event and None context.
    result = handler.lambda_handler(BUDGET_EVENT, None)

    spared = set(result["spared"])
    stopped = set(result["stopped"])

    # Fleet + active-session instances are spared (20.4 / 20.5)...
    assert spared == {fleet_head, fleet_compute, fleet_capital}, result
    # ...runaways are stopped (20.3 containment backstop)...
    assert stopped == {runaway_plain, runaway_autostop_true}, result
    # ...and stopped/spared are disjoint.
    assert spared.isdisjoint(stopped), result

    # Instances without the class tag appear in NEITHER list -- they were never
    # in scope (20.3), even the one that happens to carry AutoStop=false.
    assert other_class not in spared and other_class not in stopped, result
    assert untagged not in spared and untagged not in stopped, result

    # Observed EC2 state confirms the return value: spared instances (and the
    # out-of-scope ones) stay running; only the runaways leave the running state.
    assert _state(fleet_head) == "running"
    assert _state(fleet_compute) == "running"
    assert _state(fleet_capital) == "running"
    assert _state(other_class) == "running"
    assert _state(untagged) == "running"
    assert _state(runaway_plain) in {"stopping", "stopped"}
    assert _state(runaway_autostop_true) in {"stopping", "stopped"}


# -----------------------------------------------------------------------------
# Early return when every candidate is spared (Requirements 20.4, 20.5)
# -----------------------------------------------------------------------------
def test_nothing_stopped_when_only_fleet_present(moto_env):
    """If every class-tagged running instance is AutoStop=false, none are stopped.

    Exercises the handler's 'no stoppable instances' branch and confirms the
    prepaid fleet / active sessions are left running (20.4 / 20.5).
    """
    handler = moto_env
    head = _launch({"Class": CLASS_TAG, "AutoStop": "false"})
    compute = _launch({"Class": CLASS_TAG, "AutoStop": "false"})

    result = handler.lambda_handler(BUDGET_EVENT, None)

    assert result["stopped"] == [], result
    assert set(result["spared"]) == {head, compute}, result
    assert _state(head) == "running"
    assert _state(compute) == "running"


# -----------------------------------------------------------------------------
# The predicate the scoping relies on (Requirements 20.4, 20.5)
# -----------------------------------------------------------------------------
def test_is_spared_matches_only_autostop_false(moto_env):
    """`_is_spared` spares exactly AutoStop=false (case- and space-insensitive).

    Directly covers the predicate the fleet/active-session sparing depends on:
    the fleet's `AutoStop=false` is honoured even as ` False ` / `FALSE`, while
    `AutoStop=true`, a class tag with no AutoStop, or no tags at all are NOT
    spared (so a genuine runaway is never mistaken for the fleet).
    """
    handler = moto_env

    def inst(tags: dict[str, str]) -> dict:
        return {"Tags": [{"Key": k, "Value": v} for k, v in tags.items()]}

    assert handler._is_spared(inst({"AutoStop": "false"})) is True
    assert handler._is_spared(inst({"AutoStop": "False"})) is True
    assert handler._is_spared(inst({"AutoStop": "  FALSE  "})) is True

    assert handler._is_spared(inst({"AutoStop": "true"})) is False
    assert handler._is_spared(inst({"Class": CLASS_TAG})) is False
    assert handler._is_spared({}) is False
