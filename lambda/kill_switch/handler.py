"""
Cost kill-switch Lambda for the Trainium Course Cluster.

Invoked via SNS when the class budget (infra/budget.yaml) crosses its 90%
ACTUAL threshold. Stops runaway EC2 instances that carry the class tag
`Class=<ClassTag>` **except** those explicitly tagged `AutoStop=false`.

Why the AutoStop=false exclusion (design divergence D13; Requirements 20.3/20.4/20.5):
  The ParallelCluster fleet -- the head node (login + slurmctld + live student
  SSH sessions) and the compute nodes (which run student Slurm jobs) -- is tagged
  `AutoStop: 'false'` at the cluster level in infra/pcluster-config.yaml, so PC
  propagates that tag to every fleet instance. Skipping any `Class`-tagged
  instance that also carries `AutoStop=false` therefore:
    * 20.4 -- never stops the prepaid MLCB compute fleet (stopping it saves
              nothing, because the reservation is prepaid regardless), and
    * 20.5 -- never interrupts an active student session, since the head node
              and the compute nodes running student jobs are all part of that
              AutoStop=false fleet.
  Any OTHER instance carrying the class tag (a genuinely runaway, non-cluster
  resource: a stray EBS-backed EC2, a forgotten test box, etc.) has no
  AutoStop=false tag and is still stopped -- satisfying 20.3 (stop only
  class-tagged resources) as the containment backstop.

The IAM role in infra/budget.yaml keeps ec2:StopInstances scoped by the
`ec2:ResourceTag/Class == <ClassTag>` condition, so even a logic bug here can
only ever stop class-tagged instances -- defense in depth for 20.3.

Environment variables (set by the CFN template):
  CLASS_TAG          Class= tag value identifying this course's resources
  AWS_TARGET_REGION  region for the EC2 client (echoes AWS::Region)
"""

from __future__ import annotations

import json
import logging
import os
from typing import Any

import boto3

log = logging.getLogger()
log.setLevel(logging.INFO)

# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------
CLASS_TAG = os.environ.get("CLASS_TAG", "unknown")
REGION = os.environ.get("AWS_TARGET_REGION") or os.environ.get("AWS_REGION")

# An instance is SPARED from the kill-switch when it carries this tag/value.
# The ParallelCluster head + compute fleet sets it (infra/pcluster-config.yaml);
# see the module docstring for how sparing it satisfies Requirements 20.4/20.5.
AUTOSTOP_TAG_KEY = "AutoStop"
AUTOSTOP_SPARE_VALUE = "false"

ec2 = boto3.client("ec2", region_name=REGION)


def _is_spared(instance: dict) -> bool:
    """True if this instance must NOT be stopped by the kill-switch.

    An instance is spared iff it carries the tag ``AutoStop=false`` (the value
    is matched case-insensitively and whitespace-trimmed so a stray ``False`` /
    `` false `` still protects the fleet). Because the ParallelCluster head +
    compute instances all carry this tag, sparing them protects the prepaid MLCB
    compute (Requirement 20.4) and any active student session (Requirement 20.5).
    Instances without the tag are NOT spared and remain eligible to be stopped.
    """
    for tag in instance.get("Tags", []):
        if tag.get("Key") == AUTOSTOP_TAG_KEY and \
                str(tag.get("Value", "")).strip().lower() == AUTOSTOP_SPARE_VALUE:
            return True
    return False


def lambda_handler(event: dict, context: Any):
    # API-side scope mirrors the IAM Class condition: only class-tagged, running
    # instances are ever candidates. The AutoStop=false exclusion is applied
    # client-side below because EC2 tag filters cannot express "tag not equal".
    paginator = ec2.get_paginator("describe_instances")
    filters = [
        {"Name": "tag:Class", "Values": [CLASS_TAG]},
        {"Name": "instance-state-name", "Values": ["running"]},
    ]

    to_stop: list[str] = []
    spared: list[str] = []
    for page in paginator.paginate(Filters=filters):
        for reservation in page.get("Reservations", []):
            for inst in reservation.get("Instances", []):
                iid = inst["InstanceId"]
                if _is_spared(inst):
                    spared.append(iid)
                else:
                    to_stop.append(iid)

    log.info(
        "kill-switch: class=%s running_candidates=%d spared(AutoStop=false)=%d to_stop=%d",
        CLASS_TAG, len(to_stop) + len(spared), len(spared), len(to_stop),
    )
    if spared:
        log.info("kill-switch: sparing MLCB / active-session instances: %s", spared)

    if not to_stop:
        log.info("kill-switch: no stoppable class=%s instances", CLASS_TAG)
        return {"stopped": [], "spared": spared}

    ec2.stop_instances(InstanceIds=to_stop)
    log.info("kill-switch: stopped %d instances: %s", len(to_stop), to_stop)
    log.info("kill-switch: triggered by event=%s", json.dumps(event) if event else "{}")
    return {"stopped": to_stop, "spared": spared}
