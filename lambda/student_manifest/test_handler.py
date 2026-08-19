"""
Unit tests for the manifest Lambda using moto.

Exercises the full Create/Update/Delete lifecycle without touching real AWS.
Verifies:
  - Correct number of secrets created with correct naming pattern
  - Roster + manifest written to S3 with the expected schema
  - Update no-op path returns same physical id, doesn't churn secrets
  - Update with new StudentCount returns new physical id
  - Delete sweeps secrets + S3 objects

Run:
  cd trainium-course-cluster/lambda/student_manifest
  python -m pytest test_handler.py -v
"""

from __future__ import annotations

import json
import os
import re
import string
import sys
from types import SimpleNamespace
from unittest.mock import patch

import boto3
import pytest
from hypothesis import HealthCheck, given, settings, strategies as st
from moto import mock_aws


CLUSTER = "test-cluster"
CLASS_TAG = "nki-test"
BUCKET = "test-staging-bucket"
REGION = "us-east-2"


# -----------------------------------------------------------------------------
# Shared hypothesis strategies for StudentCount
# -----------------------------------------------------------------------------
# Reused by the property tests added in tasks 10.2-10.7 (design Properties
# P1-P7). Defined here, alongside the moto `env_and_bucket` fixture, so those
# tests can use them directly without a second setup path.
#
# The Manifest Lambda accepts StudentCount as an integer in the inclusive range
# [1, 500] and MUST reject anything else -- missing, non-numeric, non-integer,
# < 1, or > 500 (see handler._validate_student_count; requirements 2.4 and 6.5,
# Property 7).
#
# Contract these strategies uphold, so the property tests can assert cleanly:
#   * every value drawn from `valid_student_counts` is ACCEPTED by the handler;
#   * every value drawn from `invalid_student_counts` is REJECTED by it.
# The invalid strategies therefore deliberately avoid values that int() would
# silently coerce into range -- e.g. a float object like 5.7, since
# int(5.7) == 5 would be accepted. Float-valued *strings* ("5.70") are used
# instead, because int("5.70") raises and is correctly rejected.
STUDENT_COUNT_MIN = 1
STUDENT_COUNT_MAX = 500

# Valid: integers within [1, 500]. Every draw provisions successfully.
valid_student_counts = st.integers(min_value=STUDENT_COUNT_MIN, max_value=STUDENT_COUNT_MAX)

# Invalid -- an integer, but outside the accepted range (fails the range check).
out_of_range_student_counts = st.one_of(
    st.integers(max_value=STUDENT_COUNT_MIN - 1),   # 0 and negative values
    st.integers(min_value=STUDENT_COUNT_MAX + 1),   # 501 and above
)

# Invalid -- missing or non-integer values that int() cannot parse.
non_integer_student_counts = st.one_of(
    st.none(),                                             # missing -> "required"
    st.text(alphabet=string.ascii_letters, min_size=1),    # e.g. "abc" -> ValueError
    # Float-valued strings ("3.14", "-0.50") -- int() rejects the decimal point.
    st.floats(allow_nan=False, allow_infinity=False).map(lambda f: f"{f:.2f}"),
)

# Invalid -- everything the handler must reject (union of the two above).
invalid_student_counts = st.one_of(out_of_range_student_counts, non_integer_student_counts)


@pytest.fixture(autouse=True)
def env_and_bucket():
    """Set the env vars the handler expects, then create the staging bucket in moto."""
    os.environ.update({
        "CLUSTER_NAME": CLUSTER,
        "CLASS_TAG": CLASS_TAG,
        "STAGING_BUCKET": BUCKET,
        "USERNAME_PREFIX": "student",
        "UID_BASE": "10000",
        "AWS_TARGET_REGION": REGION,
        "AWS_DEFAULT_REGION": REGION,
    })

    with mock_aws():
        # Bucket lives outside the fixture body's imports so handler picks it up
        boto3.client("s3", region_name=REGION).create_bucket(
            Bucket=BUCKET,
            CreateBucketConfiguration={"LocationConstraint": REGION},
        )
        # Reload handler after env is set (module-level globals baked in on import).
        sys.path.insert(0, os.path.dirname(__file__))
        for mod in list(sys.modules):
            if mod == "handler":
                del sys.modules[mod]
        import handler  # noqa: F401  # re-import under moto
        yield handler


# -----------------------------------------------------------------------------
# Fake CFN context + response capture
# -----------------------------------------------------------------------------
class _CapturingResponse:
    """Stubs urllib.request.urlopen so we capture what the handler PUTs to CFN."""

    def __init__(self):
        self.calls = []

    def __call__(self, req, *args, **kwargs):
        body = json.loads(req.data.decode("utf-8"))
        self.calls.append(body)

        class R:
            def read(self_inner): return b""
            def __enter__(self_inner): return self_inner
            def __exit__(self_inner, *a): pass
        return R()


def _fake_context():
    return SimpleNamespace(log_stream_name="test-stream", function_name="test-fn")


def _event(request_type: str, student_count: int = 2, revision: str = "v1",
           old_count: int | None = None, physical_id: str | None = None):
    props = {"StudentCount": student_count, "Revision": revision}
    old_props = {"StudentCount": old_count, "Revision": revision} if old_count else {}
    return {
        "RequestType": request_type,
        "ResponseURL": "https://cfn-fake-url/",
        "StackId": "arn:aws:cloudformation:us-east-2:111111111111:stack/test/abc",
        "RequestId": "req-1",
        "LogicalResourceId": "TestManifest",
        "PhysicalResourceId": physical_id or "",
        "ResourceProperties": props,
        "OldResourceProperties": old_props,
    }


# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------
def test_create_generates_secrets_and_roster(env_and_bucket):
    handler = env_and_bucket
    cap = _CapturingResponse()
    with patch.object(handler.urllib.request, "urlopen", cap):
        handler.on_event(_event("Create", student_count=3), _fake_context())

    assert len(cap.calls) == 1, "handler should send exactly one CFN response"
    resp = cap.calls[0]
    assert resp["Status"] == "SUCCESS", resp
    assert "ManifestJson" in resp["Data"]
    assert "n3-v1" in resp["PhysicalResourceId"], resp["PhysicalResourceId"]

    manifest = json.loads(resp["Data"]["ManifestJson"])
    assert manifest["cluster_name"] == CLUSTER
    assert manifest["student_count"] == 3
    assert len(manifest["students"]) == 3

    # Slot assignments
    slots = [s["slot"] for s in manifest["students"]]
    assert slots == [1, 2, 3]
    usernames = [s["username"] for s in manifest["students"]]
    assert usernames == ["student01", "student02", "student03"]
    uids = [s["uid"] for s in manifest["students"]]
    assert uids == [10001, 10002, 10003]

    # Every student has an ARN
    for s in manifest["students"]:
        assert s["private_key_secret_arn"].startswith("arn:aws:secretsmanager:")

    # Secrets Manager side
    secrets = boto3.client("secretsmanager", region_name=REGION)
    listed = secrets.list_secrets(
        Filters=[{"Key": "name", "Values": [f"trn-course-{CLUSTER}-"]}]
    )["SecretList"]
    assert len(listed) == 3

    # Each secret's value is PEM-formatted OpenSSH ed25519 private key
    for s in listed:
        val = secrets.get_secret_value(SecretId=s["Name"])["SecretString"]
        assert "-----BEGIN OPENSSH PRIVATE KEY-----" in val
        assert "-----END OPENSSH PRIVATE KEY-----" in val

    # No EC2 keypairs left over
    ec2 = boto3.client("ec2", region_name=REGION)
    kp = ec2.describe_key_pairs()["KeyPairs"]
    assert not kp, f"expected 0 EC2 keypairs remaining, got {[k['KeyName'] for k in kp]}"

    # Roster + manifest written to S3
    s3 = boto3.client("s3", region_name=REGION)
    roster_body = json.loads(s3.get_object(Bucket=BUCKET, Key="roster/roster.json")["Body"].read())
    assert len(roster_body) == 3
    for r in roster_body:
        assert set(r.keys()) == {"username", "uid", "public_key_openssh"}
        assert r["public_key_openssh"].startswith("ssh-ed25519 ")

    manifest_body = json.loads(s3.get_object(Bucket=BUCKET, Key="roster/manifest.json")["Body"].read())
    assert manifest_body["student_count"] == 3


def test_update_no_change_is_noop(env_and_bucket):
    handler = env_and_bucket
    cap = _CapturingResponse()

    # Prime with a Create so S3 manifest object exists.
    with patch.object(handler.urllib.request, "urlopen", cap):
        handler.on_event(_event("Create", student_count=2), _fake_context())
    create_physical_id = cap.calls[-1]["PhysicalResourceId"]

    # Count secrets before the update
    secrets = boto3.client("secretsmanager", region_name=REGION)
    before = {s["Name"] for s in secrets.list_secrets(
        Filters=[{"Key": "name", "Values": [f"trn-course-{CLUSTER}-"]}]
    )["SecretList"]}

    # Update with same count and revision -> should be no-op
    cap.calls.clear()
    with patch.object(handler.urllib.request, "urlopen", cap):
        handler.on_event(
            _event("Update", student_count=2, old_count=2, physical_id=create_physical_id),
            _fake_context(),
        )
    assert cap.calls[-1]["Status"] == "SUCCESS"
    assert cap.calls[-1]["PhysicalResourceId"] == create_physical_id, "no-op update must preserve physical id"

    # Same secrets exist, no new ones created
    after = {s["Name"] for s in secrets.list_secrets(
        Filters=[{"Key": "name", "Values": [f"trn-course-{CLUSTER}-"]}]
    )["SecretList"]}
    assert after == before


def test_update_new_count_triggers_replacement(env_and_bucket):
    handler = env_and_bucket
    cap = _CapturingResponse()

    with patch.object(handler.urllib.request, "urlopen", cap):
        handler.on_event(_event("Create", student_count=2), _fake_context())
    old_pid = cap.calls[-1]["PhysicalResourceId"]

    cap.calls.clear()
    with patch.object(handler.urllib.request, "urlopen", cap):
        handler.on_event(
            _event("Update", student_count=5, old_count=2, physical_id=old_pid),
            _fake_context(),
        )
    new_pid = cap.calls[-1]["PhysicalResourceId"]
    assert new_pid != old_pid, "physical id must change to trigger CFN Delete on old"
    assert "n5-v1" in new_pid

    manifest = json.loads(cap.calls[-1]["Data"]["ManifestJson"])
    assert manifest["student_count"] == 5


def test_delete_sweeps_all_cluster_resources(env_and_bucket):
    handler = env_and_bucket
    cap = _CapturingResponse()

    with patch.object(handler.urllib.request, "urlopen", cap):
        handler.on_event(_event("Create", student_count=3), _fake_context())
    physical_id = cap.calls[-1]["PhysicalResourceId"]

    # Confirm 3 secrets before delete
    secrets = boto3.client("secretsmanager", region_name=REGION)
    listed = secrets.list_secrets(
        Filters=[{"Key": "name", "Values": [f"trn-course-{CLUSTER}-"]}]
    )["SecretList"]
    assert len(listed) == 3

    cap.calls.clear()
    with patch.object(handler.urllib.request, "urlopen", cap):
        handler.on_event(_event("Delete", physical_id=physical_id), _fake_context())

    assert cap.calls[-1]["Status"] == "SUCCESS"
    assert cap.calls[-1]["Data"].get("DeletedSecretCount") == 3

    # Secrets gone
    listed = secrets.list_secrets(
        Filters=[{"Key": "name", "Values": [f"trn-course-{CLUSTER}-"]}]
    )["SecretList"]
    assert listed == [], f"expected no secrets remaining, got {[s['Name'] for s in listed]}"

    # S3 roster + manifest gone
    s3 = boto3.client("s3", region_name=REGION)
    from botocore.exceptions import ClientError
    for key in ("roster/roster.json", "roster/manifest.json"):
        with pytest.raises(ClientError):
            s3.get_object(Bucket=BUCKET, Key=key)


def test_create_validates_student_count(env_and_bucket):
    handler = env_and_bucket
    cap = _CapturingResponse()

    # Missing StudentCount -> FAILED response
    with patch.object(handler.urllib.request, "urlopen", cap):
        event = _event("Create")
        del event["ResourceProperties"]["StudentCount"]
        handler.on_event(event, _fake_context())
    assert cap.calls[-1]["Status"] == "FAILED"

    # StudentCount out of range -> FAILED
    cap.calls.clear()
    with patch.object(handler.urllib.request, "urlopen", cap):
        handler.on_event(_event("Create", student_count=0), _fake_context())
    assert cap.calls[-1]["Status"] == "FAILED"

    cap.calls.clear()
    with patch.object(handler.urllib.request, "urlopen", cap):
        handler.on_event(_event("Create", student_count=501), _fake_context())
    assert cap.calls[-1]["Status"] == "FAILED"


# -----------------------------------------------------------------------------
# Property-based tests (design Properties P1-P7)
# -----------------------------------------------------------------------------
def _count_cluster_secrets(secrets_client) -> int:
    """Number of Secrets Manager secrets under this cluster's naming prefix."""
    return len(secrets_client.list_secrets(
        Filters=[{"Key": "name", "Values": [f"trn-course-{CLUSTER}-"]}]
    )["SecretList"])


def _sweep_cluster_secrets(secrets_client) -> None:
    """Force-delete every secret under the cluster prefix.

    Hypothesis reuses a function-scoped fixture (`env_and_bucket`) across all
    generated examples -- it does NOT re-enter the moto context per example, so
    the Secrets Manager store is not reset between draws. Student secret names
    are deterministic (student01, student02, ...), so an earlier example with a
    larger N would leave stale secrets that break the cardinality assertion of a
    later, smaller-N example. Sweeping at the start of each example guarantees
    every draw provisions against a clean slate. (The S3 roster/manifest are
    single, overwritten keys, so they always reflect the latest Create and need
    no sweeping.)
    """
    for s in secrets_client.list_secrets(
        Filters=[{"Key": "name", "Values": [f"trn-course-{CLUSTER}-"]}]
    )["SecretList"]:
        secrets_client.delete_secret(SecretId=s["Name"], ForceDeleteWithoutRecovery=True)


@pytest.mark.property
@settings(
    max_examples=25,
    deadline=None,  # moto call latency varies; a per-example deadline is flaky
    suppress_health_check=[HealthCheck.function_scoped_fixture],
)
@given(count=valid_student_counts.map(lambda n: (n - 1) % 8 + 1))
def test_property_roster_manifest_secret_cardinality(env_and_bucket, count):
    """Property 1: Roster/manifest/secret cardinality.

    For StudentCount N, a Create yields exactly N manifest students, exactly N
    roster entries, and exactly N Secrets Manager secrets under the cluster
    prefix:

        len(manifest.students) == len(roster) == count_secrets(prefix) == N

    N is drawn from the shared `valid_student_counts` strategy and mapped into
    [1, 8] so the moto-backed provisioning loop stays fast.

    **Validates: Requirements 6.1**
    """
    handler = env_and_bucket
    secrets = boto3.client("secretsmanager", region_name=REGION)

    # env_and_bucket is function-scoped; moto state persists across examples.
    # Reset the cluster's secrets so the counts reflect only this example's N.
    _sweep_cluster_secrets(secrets)

    cap = _CapturingResponse()
    with patch.object(handler.urllib.request, "urlopen", cap):
        handler.on_event(_event("Create", student_count=count), _fake_context())

    resp = cap.calls[-1]
    assert resp["Status"] == "SUCCESS", resp

    manifest = json.loads(resp["Data"]["ManifestJson"])

    s3 = boto3.client("s3", region_name=REGION)
    roster = json.loads(
        s3.get_object(Bucket=BUCKET, Key="roster/roster.json")["Body"].read()
    )

    secret_count = _count_cluster_secrets(secrets)

    # One-to-one correspondence across manifest, roster, and secrets (Property 1).
    assert len(manifest["students"]) == len(roster) == secret_count == count


@pytest.mark.property
@settings(
    max_examples=25,
    deadline=None,  # moto call latency varies; a per-example deadline is flaky
    suppress_health_check=[HealthCheck.function_scoped_fixture],
)
@given(count=valid_student_counts.map(lambda n: (n - 1) % 8 + 1))
def test_property_slot_username_uid_bijection(env_and_bucket, count):
    """Property 2: Slot/username/UID bijection.

    For StudentCount N, a Create assigns the slots exactly [1..N] in order and,
    for each slot, a username of ``f"{prefix}{slot:02d}"`` and a UID of
    ``10000 + slot``. Usernames and UIDs are each unique across the manifest
    (the mapping is a bijection), and every UID clears the account-sync guard
    (strictly, ``uid > 10000``).

    N is drawn from the shared `valid_student_counts` strategy and mapped into
    [1, 8] so the moto-backed provisioning loop stays fast (mirrors the
    cardinality test).

    **Validates: Requirements 6.2, 6.3**
    """
    handler = env_and_bucket
    secrets = boto3.client("secretsmanager", region_name=REGION)

    # env_and_bucket is function-scoped; moto state persists across examples.
    # Reset the cluster's secrets so each example provisions against a clean
    # slate (same rationale as the cardinality test).
    _sweep_cluster_secrets(secrets)

    # The identity mapping is parameterised by the handler's configured prefix
    # and UID base (env_and_bucket sets these to "student" / 10000).
    prefix = handler.USERNAME_PREFIX
    uid_base = handler.UID_BASE

    cap = _CapturingResponse()
    with patch.object(handler.urllib.request, "urlopen", cap):
        handler.on_event(_event("Create", student_count=count), _fake_context())

    resp = cap.calls[-1]
    assert resp["Status"] == "SUCCESS", resp

    students = json.loads(resp["Data"]["ManifestJson"])["students"]

    # Slots are exactly [1..N], in order.
    slots = [s["slot"] for s in students]
    assert slots == list(range(1, count + 1)), slots

    # Per-slot identity mapping: username == f"{prefix}{slot:02d}", uid == 10000 + slot.
    for s in students:
        slot = s["slot"]
        assert s["username"] == f"{prefix}{slot:02d}", s
        assert s["uid"] == uid_base + slot, s
        assert s["uid"] == 10000 + slot, s   # design's literal mapping
        assert s["uid"] > 10000, s           # clears the account-sync uid guard

    # Usernames and UIDs are each unique across all slots (bijection).
    usernames = [s["username"] for s in students]
    uids = [s["uid"] for s in students]
    assert len(set(usernames)) == len(usernames) == count, usernames
    assert len(set(uids)) == len(uids) == count, uids


@pytest.mark.property
@settings(
    max_examples=25,
    deadline=None,  # moto call latency varies; a per-example deadline is flaky
    suppress_health_check=[HealthCheck.function_scoped_fixture],
)
@given(count=valid_student_counts.map(lambda n: (n - 1) % 8 + 1))
def test_property_one_keypair_per_student_private_key_only_in_secrets(env_and_bucket, count):
    """Property 4: Exactly one keypair per student, private key only in Secrets Manager.

    For StudentCount N, a Create provisions exactly one keypair per student and
    keeps the private half only in Secrets Manager:

      * exactly N secrets exist under the cluster prefix, and each secret value
        is an OpenSSH-PEM ed25519 private key (BEGIN/END OPENSSH PRIVATE KEY);
      * ZERO ephemeral EC2 keypairs remain after Create -- the handler captures
        both halves then deletes the EC2-side keypair (requirement 7.5);
      * each student's public key is recorded in the roster as an ``ssh-ed25519``
        OpenSSH public key (requirement 7.1, ed25519);
      * NO private-key material leaks into the CFN response outputs -- neither
        the response Data nor the manifest JSON contains the ``PRIVATE KEY``
        substring, so the private key lives only in the secret (requirements
        7.2, 7.4).

    N is drawn from the shared `valid_student_counts` strategy and mapped into
    [1, 8] so the moto-backed provisioning loop stays fast (mirrors the
    cardinality and bijection tests).

    **Validates: Requirements 7.1, 7.2, 7.4, 7.5**
    """
    handler = env_and_bucket
    secrets = boto3.client("secretsmanager", region_name=REGION)
    ec2 = boto3.client("ec2", region_name=REGION)

    # env_and_bucket is function-scoped; moto state persists across examples.
    # Reset the cluster's secrets so each example provisions against a clean
    # slate (same rationale as the cardinality/bijection tests). Ephemeral EC2
    # keypairs need no sweep -- the handler deletes each one during Create, so
    # the residual-keypair assertion below holds across examples on its own.
    _sweep_cluster_secrets(secrets)

    cap = _CapturingResponse()
    with patch.object(handler.urllib.request, "urlopen", cap):
        handler.on_event(_event("Create", student_count=count), _fake_context())

    resp = cap.calls[-1]
    assert resp["Status"] == "SUCCESS", resp

    manifest = json.loads(resp["Data"]["ManifestJson"])
    students = manifest["students"]
    assert len(students) == count, students

    # (1) Exactly one secret per student, each an OpenSSH-PEM ed25519 private key.
    listed = secrets.list_secrets(
        Filters=[{"Key": "name", "Values": [f"trn-course-{CLUSTER}-"]}]
    )["SecretList"]
    assert len(listed) == count, [s["Name"] for s in listed]
    for s in listed:
        val = secrets.get_secret_value(SecretId=s["Name"])["SecretString"]
        assert "-----BEGIN OPENSSH PRIVATE KEY-----" in val, s["Name"]
        assert "-----END OPENSSH PRIVATE KEY-----" in val, s["Name"]

    # (2) No ephemeral EC2 keypair remains after Create (requirement 7.5): the
    #     handler captures both halves via EC2 then deletes the EC2-side copy.
    remaining = ec2.describe_key_pairs()["KeyPairs"]
    assert remaining == [], [k["KeyName"] for k in remaining]

    # (3) Each student's public key is recorded in the roster as an ed25519
    #     OpenSSH public key (requirements 7.1, 7.3).
    s3 = boto3.client("s3", region_name=REGION)
    roster = json.loads(
        s3.get_object(Bucket=BUCKET, Key="roster/roster.json")["Body"].read()
    )
    roster_by_user = {r["username"]: r for r in roster}
    assert len(roster_by_user) == count, roster
    for stu in students:
        entry = roster_by_user.get(stu["username"])
        assert entry is not None, f"missing roster entry for {stu['username']}"
        assert entry["public_key_openssh"].startswith("ssh-ed25519 "), entry

    # (4) No private-key material leaks into the CFN response outputs. The check
    #     is case-sensitive: the uppercase "PRIVATE KEY" only matches PEM key
    #     bytes, never the lowercase `private_key_secret_arn` field name that
    #     legitimately appears in the manifest (requirements 7.2, 7.4).
    assert "PRIVATE KEY" not in resp["Data"]["ManifestJson"]
    assert "PRIVATE KEY" not in json.dumps(resp["Data"])
    assert "PRIVATE KEY" not in json.dumps(resp)


# Secrets Manager ARN shape: arn:aws{,-cn,-us-gov}:secretsmanager:<region>:<acct>:secret:<name>.
# The [^:]* after "aws" admits the aws-cn / aws-us-gov partitions without letting
# the match run past the ":" that ends the partition segment.
_SECRETSMANAGER_ARN_RE = re.compile(r"^arn:aws[^:]*:secretsmanager:")


@pytest.mark.property
@settings(
    max_examples=25,
    deadline=None,  # moto call latency varies; a per-example deadline is flaky
    suppress_health_check=[HealthCheck.function_scoped_fixture],
)
@given(count=valid_student_counts.map(lambda n: (n - 1) % 8 + 1))
def test_property_manifest_carries_arns_never_key_material(env_and_bucket, count):
    """Property 5: Manifest carries ARNs, never key material.

    For StudentCount N, a Create produces a manifest in which every student's
    private key is referenced *solely* by a Secrets Manager ARN and in which no
    private-key bytes ever appear:

      * each ``students[i].private_key_secret_arn`` is a Secrets Manager ARN --
        it matches ``^arn:aws[^:]*:secretsmanager:`` (the ``[^:]*`` admits the
        aws-cn / aws-us-gov partitions) -- and the ARNs are distinct across the
        manifest, one per student (requirement 8.2); and
      * the full manifest JSON string carries NO private-key material -- the
        case-sensitive substring ``PRIVATE KEY`` is absent, so neither a PEM
        header (``-----BEGIN OPENSSH PRIVATE KEY-----``) nor raw key bytes can
        hide in any field (requirement 8.3). The check is case-sensitive on
        purpose: it never trips on the lowercase ``private_key_secret_arn``
        field name that legitimately appears in every entry.

    N is drawn from the shared `valid_student_counts` strategy and mapped into
    [1, 8] so the moto-backed provisioning loop stays fast (mirrors the other
    Manifest-Lambda property tests).

    **Validates: Requirements 8.2, 8.3**
    """
    handler = env_and_bucket
    secrets = boto3.client("secretsmanager", region_name=REGION)

    # env_and_bucket is function-scoped; moto state persists across examples.
    # Reset the cluster's secrets so each example provisions against a clean
    # slate (same rationale as the other property tests).
    _sweep_cluster_secrets(secrets)

    cap = _CapturingResponse()
    with patch.object(handler.urllib.request, "urlopen", cap):
        handler.on_event(_event("Create", student_count=count), _fake_context())

    resp = cap.calls[-1]
    assert resp["Status"] == "SUCCESS", resp

    # The manifest JSON string as CFN would receive it (Property 5 is about this
    # exact serialized value).
    manifest_json = resp["Data"]["ManifestJson"]
    manifest = json.loads(manifest_json)
    students = manifest["students"]
    assert len(students) == count, students

    # (1) Every student references its private key solely by a Secrets Manager
    #     ARN, and those ARNs are distinct across the manifest (requirement 8.2).
    arns = [s["private_key_secret_arn"] for s in students]
    for arn in arns:
        assert _SECRETSMANAGER_ARN_RE.match(arn), arn
    assert len(set(arns)) == len(arns) == count, arns

    # (2) No private-key material anywhere in the manifest JSON string. The
    #     case-sensitive "PRIVATE KEY" catches the PEM header/body
    #     ("-----BEGIN ... PRIVATE KEY-----") while never matching the lowercase
    #     private_key_secret_arn field name (requirement 8.3).
    assert "PRIVATE KEY" not in manifest_json


@pytest.mark.property
@settings(
    max_examples=25,
    deadline=None,  # moto call latency varies; a per-example deadline is flaky
    suppress_health_check=[HealthCheck.function_scoped_fixture],
)
@given(count=valid_student_counts.map(lambda n: (n - 1) % 8 + 1))
def test_property_update_idempotence_and_delete_sweep(env_and_bucket, count):
    """Property 6: Update idempotence & Delete sweep.

    For StudentCount N, the manifest custom-resource lifecycle is well-behaved
    end to end:

      * a no-op Update -- one whose StudentCount AND Revision both match the
        prior request -- returns the SAME PhysicalResourceId and creates no new
        secrets, leaving every existing secret under the cluster prefix
        byte-for-byte unchanged (requirements 9.1, 9.2);
      * an Update that CHANGES StudentCount returns a DIFFERENT
        PhysicalResourceId, which is how the handler signals CloudFormation to
        Delete the prior resource (requirement 9.3); and
      * a Delete sweeps the cluster clean -- every ``trn-course-{cluster}-*``
        secret is gone and both the roster and manifest S3 objects are removed
        (requirement 9.4).

    N is drawn from the shared `valid_student_counts` strategy and mapped into
    [1, 8] so the moto-backed provisioning loop stays fast (mirrors the other
    Manifest-Lambda property tests). The changed-count Update draws its new
    count as ``(count % 8) + 1``, which is always in [1, 8] and always differs
    from ``count`` (so the encoded physical id must change).

    Mirrors the lifecycle unit tests ``test_update_no_change_is_noop``,
    ``test_update_new_count_triggers_replacement``, and
    ``test_delete_sweeps_all_cluster_resources``.

    **Validates: Requirements 9.1, 9.2, 9.3, 9.4**
    """
    handler = env_and_bucket
    secrets = boto3.client("secretsmanager", region_name=REGION)
    s3 = boto3.client("s3", region_name=REGION)

    # env_and_bucket is function-scoped; moto state persists across examples.
    # Reset the cluster's secrets so each example provisions against a clean
    # slate (same rationale as the other property tests). The prior example's
    # Delete also drops the S3 objects, but the Create below re-writes them.
    _sweep_cluster_secrets(secrets)

    def _cluster_secret_map() -> dict:
        """{secret_name: secret_value} for every secret under the cluster prefix.

        Captures both the names AND the values so the no-op Update can assert
        the stronger requirement 9.2 property: not just "no new secrets" but
        "every existing secret's value is left unchanged".
        """
        listed = secrets.list_secrets(
            Filters=[{"Key": "name", "Values": [f"trn-course-{CLUSTER}-"]}]
        )["SecretList"]
        return {
            s["Name"]: secrets.get_secret_value(SecretId=s["Name"])["SecretString"]
            for s in listed
        }

    # --- Create: record the physical id and the provisioned secret map -------
    cap = _CapturingResponse()
    with patch.object(handler.urllib.request, "urlopen", cap):
        handler.on_event(_event("Create", student_count=count), _fake_context())
    create_resp = cap.calls[-1]
    assert create_resp["Status"] == "SUCCESS", create_resp
    create_pid = create_resp["PhysicalResourceId"]

    secrets_after_create = _cluster_secret_map()
    assert len(secrets_after_create) == count, sorted(secrets_after_create)

    # --- Update with UNCHANGED count + revision -> idempotent no-op ----------
    # (requirements 9.1, 9.2)
    cap.calls.clear()
    with patch.object(handler.urllib.request, "urlopen", cap):
        handler.on_event(
            _event("Update", student_count=count, old_count=count,
                   physical_id=create_pid),
            _fake_context(),
        )
    noop_resp = cap.calls[-1]
    assert noop_resp["Status"] == "SUCCESS", noop_resp
    # 9.1: an unchanged Update returns the identical PhysicalResourceId.
    assert noop_resp["PhysicalResourceId"] == create_pid, noop_resp
    # 9.2: no new secrets created AND every existing secret value is unchanged.
    assert _cluster_secret_map() == secrets_after_create

    # --- Update that CHANGES count -> replacement (requirement 9.3) ----------
    changed_count = (count % 8) + 1   # always in [1, 8] and guaranteed != count
    assert changed_count != count
    cap.calls.clear()
    with patch.object(handler.urllib.request, "urlopen", cap):
        handler.on_event(
            _event("Update", student_count=changed_count, old_count=count,
                   physical_id=create_pid),
            _fake_context(),
        )
    changed_resp = cap.calls[-1]
    assert changed_resp["Status"] == "SUCCESS", changed_resp
    # 9.3: a changed Update returns a NEW physical id, which is how the handler
    #      tells CloudFormation to Delete the old resource after this SUCCESS.
    changed_pid = changed_resp["PhysicalResourceId"]
    assert changed_pid != create_pid, (create_pid, changed_pid)

    # --- Delete -> full cluster sweep (requirement 9.4) ----------------------
    cap.calls.clear()
    with patch.object(handler.urllib.request, "urlopen", cap):
        handler.on_event(_event("Delete", physical_id=changed_pid), _fake_context())
    delete_resp = cap.calls[-1]
    assert delete_resp["Status"] == "SUCCESS", delete_resp

    # 9.4: every secret under the cluster prefix is gone (the sweep is by
    #      prefix, so it also clears any secret left behind by the count change).
    assert _count_cluster_secrets(secrets) == 0

    # 9.4: both S3 objects (roster + manifest) are removed. Mirrors the
    #      ClientError expectation in test_delete_sweeps_all_cluster_resources.
    from botocore.exceptions import ClientError
    for key in ("roster/roster.json", "roster/manifest.json"):
        with pytest.raises(ClientError):
            s3.get_object(Bucket=BUCKET, Key=key)


@pytest.mark.property
@settings(
    max_examples=25,
    deadline=None,  # moto call latency varies; a per-example deadline is flaky
    suppress_health_check=[HealthCheck.function_scoped_fixture],
)
@given(
    bad=invalid_student_counts,
    good=valid_student_counts.map(lambda n: (n - 1) % 8 + 1),
)
def test_property_student_count_validation(env_and_bucket, bad, good):
    """Property 7: StudentCount is validated.

    The Manifest Lambda accepts StudentCount only as an integer in [1, 500] and
    MUST reject everything else -- missing, non-numeric, non-integer (e.g. a
    float-valued string), < 1, or > 500. This test asserts the shared strategy
    contract *both ways* on every generated example:

      * REJECT branch -- for a value drawn from the shared
        `invalid_student_counts` strategy, a Create emits a CloudFormation
        ``FAILED`` response AND provisions nothing: zero secrets under the
        cluster prefix and neither the roster nor the manifest S3 object is
        created. `_validate_student_count` raises before
        `_build_manifest_and_roster` runs, so a rejected request cannot leave
        partial state (requirements 2.4, 6.5). A drawn ``None`` models a
        genuinely *missing* property, so its key is deleted from
        ResourceProperties (mirrors `test_create_validates_student_count`);
        every other invalid value is set verbatim.

      * ACCEPT branch -- a value drawn from the shared `valid_student_counts`
        strategy (mapped into [1, 8] so the moto provisioning loop stays fast,
        as in the other property tests) yields a ``SUCCESS`` response. This
        keeps the FAILED assertion honest: it proves the handler is rejecting
        *invalid* input specifically, not failing on everything.

    moto state is NOT reset per hypothesis example (the `env_and_bucket`
    fixture is function-scoped and entered once for the whole test), so each
    example first restores a clean slate: `_sweep_cluster_secrets` clears the
    prior example's secrets and the roster/manifest S3 objects are deleted.
    The invalid Create is then evaluated against that clean slate -- so
    "provisions nothing" reflects only this example -- and the positive Create
    runs last, its residue swept at the top of the next example.

    **Validates: Requirements 2.4, 6.5**
    """
    handler = env_and_bucket
    secrets = boto3.client("secretsmanager", region_name=REGION)
    s3 = boto3.client("s3", region_name=REGION)

    # env_and_bucket is function-scoped; moto state persists across examples.
    # Restore a clean slate: sweep this cluster's secrets and drop the S3
    # roster/manifest left by a previous example's positive Create, so the
    # "provisions nothing" assertions below reflect only this example. S3
    # DeleteObject is idempotent under moto, so deleting absent keys is a no-op.
    _sweep_cluster_secrets(secrets)
    for key in ("roster/roster.json", "roster/manifest.json"):
        s3.delete_object(Bucket=BUCKET, Key=key)

    # --- REJECT branch: an invalid StudentCount -> FAILED + provisions nothing.
    event = _event("Create")
    if bad is None:
        # A missing property, not StudentCount=None: delete the key so
        # props.get("StudentCount") is genuinely absent (mirrors
        # test_create_validates_student_count).
        del event["ResourceProperties"]["StudentCount"]
    else:
        event["ResourceProperties"]["StudentCount"] = bad

    cap = _CapturingResponse()
    with patch.object(handler.urllib.request, "urlopen", cap):
        handler.on_event(event, _fake_context())

    resp = cap.calls[-1]
    # Invalid input -> CloudFormation FAILED response (requirement 6.5, Property 7).
    assert resp["Status"] == "FAILED", (bad, resp)

    # ...and nothing was provisioned: no secrets under the cluster prefix.
    assert _count_cluster_secrets(secrets) == 0, bad

    # ...and neither S3 object was created -- validation raises before any
    # _put_roster / _put_manifest call, so a rejected Create leaves no partial
    # state (requirement 6.5). Mirrors the ClientError expectation in
    # test_delete_sweeps_all_cluster_resources.
    from botocore.exceptions import ClientError
    for key in ("roster/roster.json", "roster/manifest.json"):
        with pytest.raises(ClientError):
            s3.get_object(Bucket=BUCKET, Key=key)

    # --- ACCEPT branch: a valid StudentCount is accepted (contract both ways).
    cap = _CapturingResponse()
    with patch.object(handler.urllib.request, "urlopen", cap):
        handler.on_event(_event("Create", student_count=good), _fake_context())
    assert cap.calls[-1]["Status"] == "SUCCESS", (good, cap.calls[-1])
