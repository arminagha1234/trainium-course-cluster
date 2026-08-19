"""
Student Manifest custom resource for the Trainium Course Cluster.

Called by CloudFormation via a Custom::StudentManifest resource in
infra/parent-stack.yaml. Generates StudentCount SSH keypairs, stores
private keys in Secrets Manager, writes a roster to S3 for head- and
compute-node bootstrap consumption, and returns a TA-facing manifest as
the resource's `ManifestJson` data attribute.

Environment variables (set by the CFN template):
  CLUSTER_NAME       cluster identifier, used in secret + roster paths
  CLASS_TAG          Class= tag applied to every secret and roster object
  STAGING_BUCKET     S3 bucket for roster.json and public-key material
  USERNAME_PREFIX    e.g. "student" -> usernames "student01", "student02", ...
  UID_BASE           starting POSIX UID (default 10000); slot N gets UID_BASE + N
  AWS_TARGET_REGION  region for EC2 + Secrets Manager (echoes AWS::Region)

CloudFormation custom resource contract (docs):
  https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/crpg-ref-requesttypes.html
"""

from __future__ import annotations

import json
import logging
import os
import re
import time
import traceback
import urllib.request
from typing import Any

import boto3
from botocore.exceptions import ClientError

log = logging.getLogger()
log.setLevel(logging.INFO)

# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------
CLUSTER_NAME = os.environ["CLUSTER_NAME"]
CLASS_TAG = os.environ["CLASS_TAG"]
STAGING_BUCKET = os.environ["STAGING_BUCKET"]
USERNAME_PREFIX = os.environ.get("USERNAME_PREFIX", "student")
UID_BASE = int(os.environ.get("UID_BASE", "10000"))
REGION = os.environ.get("AWS_TARGET_REGION") or os.environ.get("AWS_REGION")

SECRET_NAME_TEMPLATE = f"trn-course-{CLUSTER_NAME}-{{username}}-key"
KEYPAIR_NAME_TEMPLATE = f"trn-course-{CLUSTER_NAME}-{{username}}-ephemeral"
ROSTER_KEY = "roster/roster.json"
MANIFEST_KEY = "roster/manifest.json"  # extra copy for TA convenience

ec2 = boto3.client("ec2", region_name=REGION)
secrets = boto3.client("secretsmanager", region_name=REGION)
s3 = boto3.client("s3", region_name=REGION)


# -----------------------------------------------------------------------------
# CFN response helper
# -----------------------------------------------------------------------------
def send_response(
    event: dict,
    context: Any,
    status: str,
    data: dict | None = None,
    reason: str | None = None,
    physical_resource_id: str | None = None,
) -> None:
    """POST the CFN custom resource response to its pre-signed URL.

    Uses urllib (stdlib) so we don't depend on the deprecated `cfnresponse`
    helper module (which only ships with inline Lambdas anyway).
    """
    body = {
        "Status": status,
        "Reason": reason or f"See CloudWatch log stream: {context.log_stream_name}",
        "PhysicalResourceId": physical_resource_id or event.get("PhysicalResourceId") or context.log_stream_name,
        "StackId": event["StackId"],
        "RequestId": event["RequestId"],
        "LogicalResourceId": event["LogicalResourceId"],
        "NoEcho": False,
        "Data": data or {},
    }
    encoded = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        event["ResponseURL"],
        data=encoded,
        method="PUT",
        headers={"content-type": "", "content-length": str(len(encoded))},
    )
    log.info("sending CFN response: status=%s physical_id=%s", status, body["PhysicalResourceId"])
    try:
        urllib.request.urlopen(req, timeout=30)  # noqa: S310 - AWS-signed URL
    except Exception as e:
        log.error("failed to send response to CFN: %s", e)
        raise


# -----------------------------------------------------------------------------
# Naming / identity helpers
# -----------------------------------------------------------------------------
def _username(slot: int) -> str:
    """Slot 1 -> student01, slot 10 -> student10. Zero-padded to 2 digits."""
    return f"{USERNAME_PREFIX}{slot:02d}"


def _uid(slot: int) -> int:
    return UID_BASE + slot


# -----------------------------------------------------------------------------
# Keypair generation via EC2 API
# -----------------------------------------------------------------------------
def _generate_keypair(username: str) -> tuple[str, str, str]:
    """Create an ephemeral EC2 ed25519 keypair, extract both halves, delete.

    Returns (private_key_pem, public_key_openssh, fingerprint).

    We use EC2 as the keygen because Lambda's Python runtime does not ship
    the `cryptography` library and packaging it just for keygen adds ~40MB
    to the deployment zip. EC2 returns the private key material as OpenSSH
    PEM; DescribeKeyPairs with IncludePublicKey=True returns the OpenSSH
    public key. We then delete the EC2 keypair (we've captured both halves).
    """
    keypair_name = KEYPAIR_NAME_TEMPLATE.format(username=username)

    # If a stale keypair from a prior failed run exists, delete it first.
    try:
        ec2.delete_key_pair(KeyName=keypair_name)
        log.info("cleaned up stale keypair %s", keypair_name)
    except ClientError as e:
        if e.response.get("Error", {}).get("Code") not in ("InvalidKeyPair.NotFound",):
            log.warning("stale cleanup of %s returned %s", keypair_name, e)

    created = ec2.create_key_pair(
        KeyName=keypair_name,
        KeyType="ed25519",
        KeyFormat="pem",
        TagSpecifications=[{
            "ResourceType": "key-pair",
            "Tags": [
                {"Key": "Class", "Value": CLASS_TAG},
                {"Key": "Cluster", "Value": CLUSTER_NAME},
                {"Key": "Purpose", "Value": "trn-course-student-keygen-ephemeral"},
            ],
        }],
    )
    private_pem = created["KeyMaterial"]
    fingerprint = created["KeyFingerprint"]

    desc = ec2.describe_key_pairs(KeyNames=[keypair_name], IncludePublicKey=True)
    public_openssh = desc["KeyPairs"][0]["PublicKey"].strip()

    # We've captured both halves; delete the EC2-side keypair.
    ec2.delete_key_pair(KeyName=keypair_name)

    return private_pem, public_openssh, fingerprint


# -----------------------------------------------------------------------------
# Secrets Manager
# -----------------------------------------------------------------------------
def _put_private_key_secret(username: str, private_pem: str) -> str:
    """Create or update the student's private-key secret. Returns the ARN."""
    secret_name = SECRET_NAME_TEMPLATE.format(username=username)
    tags = [
        {"Key": "Class", "Value": CLASS_TAG},
        {"Key": "Cluster", "Value": CLUSTER_NAME},
        {"Key": "Username", "Value": username},
        {"Key": "Purpose", "Value": "trn-course-student-ssh-private-key"},
    ]
    try:
        resp = secrets.create_secret(
            Name=secret_name,
            Description=f"SSH private key for {username} on cluster {CLUSTER_NAME}",
            SecretString=private_pem,
            Tags=tags,
        )
        log.info("created secret %s", secret_name)
        return resp["ARN"]
    except ClientError as e:
        code = e.response.get("Error", {}).get("Code")
        if code == "ResourceExistsException":
            # Idempotent update - overwrite value, refresh tags.
            resp = secrets.put_secret_value(SecretId=secret_name, SecretString=private_pem)
            try:
                secrets.tag_resource(SecretId=secret_name, Tags=tags)
            except ClientError:
                pass  # tags aren't critical
            log.info("updated existing secret %s", secret_name)
            return resp["ARN"]
        raise


def _delete_secrets_for_cluster() -> list[str]:
    """Force-delete every secret matching this cluster's naming prefix."""
    deleted: list[str] = []
    prefix = f"trn-course-{CLUSTER_NAME}-"
    paginator = secrets.get_paginator("list_secrets")
    for page in paginator.paginate(Filters=[{"Key": "name", "Values": [prefix]}]):
        for s in page.get("SecretList", []):
            name = s["Name"]
            if not name.startswith(prefix):
                continue
            try:
                secrets.delete_secret(SecretId=name, ForceDeleteWithoutRecovery=True)
                deleted.append(name)
                log.info("deleted secret %s", name)
            except ClientError as e:
                log.warning("could not delete secret %s: %s", name, e)
    return deleted


# -----------------------------------------------------------------------------
# S3 roster
# -----------------------------------------------------------------------------
def _put_roster(roster: list[dict]) -> None:
    """Write the head/compute-facing roster (compact: username, uid, pubkey)."""
    body = json.dumps(roster, indent=2).encode("utf-8")
    s3.put_object(
        Bucket=STAGING_BUCKET,
        Key=ROSTER_KEY,
        Body=body,
        ContentType="application/json",
        ServerSideEncryption="AES256",
        Tagging=f"Class={CLASS_TAG}&Purpose=trn-course-roster",
    )
    log.info("uploaded roster with %d students to s3://%s/%s", len(roster), STAGING_BUCKET, ROSTER_KEY)


def _put_manifest(manifest: dict) -> None:
    """Write the TA-facing manifest (rich: ARNs, fingerprints, login hints)."""
    body = json.dumps(manifest, indent=2).encode("utf-8")
    s3.put_object(
        Bucket=STAGING_BUCKET,
        Key=MANIFEST_KEY,
        Body=body,
        ContentType="application/json",
        ServerSideEncryption="AES256",
        Tagging=f"Class={CLASS_TAG}&Purpose=trn-course-manifest",
    )
    log.info("uploaded manifest to s3://%s/%s", STAGING_BUCKET, MANIFEST_KEY)


def _delete_s3_objects() -> None:
    for key in (ROSTER_KEY, MANIFEST_KEY):
        try:
            s3.delete_object(Bucket=STAGING_BUCKET, Key=key)
            log.info("deleted s3://%s/%s", STAGING_BUCKET, key)
        except ClientError as e:
            log.warning("could not delete s3://%s/%s: %s", STAGING_BUCKET, key, e)


# -----------------------------------------------------------------------------
# Manifest construction
# -----------------------------------------------------------------------------
def _build_manifest_and_roster(student_count: int) -> tuple[dict, list[dict]]:
    """Provision keys + secrets for slots 1..student_count. Returns (manifest, roster)."""
    generated_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    students_manifest: list[dict] = []
    students_roster: list[dict] = []

    for slot in range(1, student_count + 1):
        username = _username(slot)
        uid = _uid(slot)
        log.info("provisioning slot %d (%s uid=%d)", slot, username, uid)

        private_pem, public_openssh, fingerprint = _generate_keypair(username)
        secret_arn = _put_private_key_secret(username, private_pem)

        students_manifest.append({
            "slot": slot,
            "username": username,
            "uid": uid,
            "home": f"/shared/home/{username}",
            "work_dir": f"/shared/work/{username}",
            "private_key_secret_arn": secret_arn,
            "public_key_fingerprint": fingerprint,
            "login_hint": (
                f"aws secretsmanager get-secret-value --region {REGION} "
                f"--secret-id {secret_arn} --query SecretString --output text "
                f"> {username}.pem && chmod 600 {username}.pem && "
                f"ssh -i {username}.pem {username}@<head-node-public-dns>"
            ),
        })
        students_roster.append({
            "username": username,
            "uid": uid,
            "public_key_openssh": public_openssh,
        })

    manifest = {
        "cluster_name": CLUSTER_NAME,
        "class_tag": CLASS_TAG,
        "region": REGION,
        "generated_at": generated_at,
        "student_count": student_count,
        "students": students_manifest,
    }
    return manifest, students_roster


# -----------------------------------------------------------------------------
# CFN event handlers
# -----------------------------------------------------------------------------
def _physical_id(student_count: int, revision: str) -> str:
    """Deterministic id so unchanged updates are no-ops."""
    return f"trn-course-manifest-{CLUSTER_NAME}-n{student_count}-{revision}"


def _validate_student_count(props: dict) -> int:
    raw = props.get("StudentCount")
    if raw is None:
        raise ValueError("StudentCount is required")
    try:
        n = int(raw)
    except (TypeError, ValueError) as e:
        raise ValueError(f"StudentCount must be an integer, got {raw!r}") from e
    if n < 1 or n > 500:
        raise ValueError(f"StudentCount out of range [1, 500]: {n}")
    return n


def _on_create(event: dict, context: Any) -> None:
    props = event.get("ResourceProperties", {})
    n = _validate_student_count(props)
    revision = str(props.get("Revision", "v1"))

    manifest, roster = _build_manifest_and_roster(n)
    _put_roster(roster)
    _put_manifest(manifest)

    send_response(
        event,
        context,
        status="SUCCESS",
        data={"ManifestJson": json.dumps(manifest)},
        physical_resource_id=_physical_id(n, revision),
    )


def _on_update(event: dict, context: Any) -> None:
    """
    Simplification for V0: any property change forces replacement. We return a
    new PhysicalResourceId when either StudentCount or Revision differs from
    what the old resource id encodes; CFN will then invoke DELETE against the
    old resource id after this handler returns SUCCESS.
    """
    old = event.get("OldResourceProperties", {}) or {}
    new = event.get("ResourceProperties", {}) or {}

    old_count = _validate_student_count(old) if old.get("StudentCount") else None
    new_count = _validate_student_count(new)
    old_rev = str(old.get("Revision", "v1"))
    new_rev = str(new.get("Revision", "v1"))

    if old_count == new_count and old_rev == new_rev:
        # Genuinely nothing to do. Return same PhysicalResourceId so CFN skips DELETE.
        # We still need to re-read the manifest for the Data output.
        try:
            body = s3.get_object(Bucket=STAGING_BUCKET, Key=MANIFEST_KEY)["Body"].read().decode("utf-8")
        except ClientError:
            body = "{}"
        send_response(
            event,
            context,
            status="SUCCESS",
            data={"ManifestJson": body},
            physical_resource_id=event["PhysicalResourceId"],
        )
        return

    # Change - do a fresh create. Returning a new PhysicalResourceId tells CFN
    # to call DELETE against the old id after this SUCCESS.
    manifest, roster = _build_manifest_and_roster(new_count)
    _put_roster(roster)
    _put_manifest(manifest)

    send_response(
        event,
        context,
        status="SUCCESS",
        data={"ManifestJson": json.dumps(manifest)},
        physical_resource_id=_physical_id(new_count, new_rev),
    )


def _on_delete(event: dict, context: Any) -> None:
    # Delete secrets tagged for this cluster + drop the roster/manifest.
    deleted = _delete_secrets_for_cluster()
    _delete_s3_objects()
    send_response(
        event,
        context,
        status="SUCCESS",
        data={"DeletedSecretCount": len(deleted)},
        physical_resource_id=event["PhysicalResourceId"],
    )


# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------
def on_event(event: dict, context: Any):
    log.info("event: %s", json.dumps({k: v for k, v in event.items() if k != "ResponseURL"}))
    request_type = event.get("RequestType", "")

    try:
        if request_type == "Create":
            _on_create(event, context)
        elif request_type == "Update":
            _on_update(event, context)
        elif request_type == "Delete":
            _on_delete(event, context)
        else:
            raise ValueError(f"unknown RequestType {request_type!r}")
    except Exception as e:
        log.error("handler failed: %s\n%s", e, traceback.format_exc())
        send_response(
            event,
            context,
            status="FAILED",
            reason=f"{type(e).__name__}: {e}",
        )
