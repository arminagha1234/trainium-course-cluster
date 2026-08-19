#!/usr/bin/env bash
# verify-teardown.sh — post-teardown assertions (design Property 11 /
# Requirements 10.6, 21.1, 21.2).
#
# Confirms scripts/teardown.sh did what it promises, WITHOUT changing anything.
# This script is strictly READ-ONLY: it only issues describe / head / list
# calls and never deletes, empties, or modifies a resource.
#
# Two modes, mirroring teardown.sh's own flag:
#
#   (default, no --purge-efs)  teardown was run WITHOUT --purge-efs, so:
#       - pcluster CFN stack    {cluster}                             -> gone
#       - budget stack          {cluster}-budget                      -> gone
#       - parent stack          {cluster}-parent                      -> gone
#       - staging S3 bucket     {cluster}-{acct}-{region}-staging     -> gone
#       - bootstrap S3 bucket   {cluster}-{acct}-{region}-bootstrap   -> gone
#       - EFS filesystem (Name tag {cluster}-efs)  -> STILL EXISTS  (retained)
#
#   (--purge-efs)  teardown was run WITH --purge-efs, so everything above is
#       gone AND the EFS filesystem is ALSO deleted.
#
# Why we reconstruct the bucket/EFS identifiers instead of reading them from the
# parent stack's outputs (as teardown.sh does at teardown time): by the time
# this verification runs, the parent stack has been deleted, so its outputs are
# gone. The staging + bootstrap bucket names are deterministic
# (`{cluster}-{acct}-{region}-{staging|bootstrap}`, per infra/parent-stack.yaml
# and scripts/teardown.sh) and the retained EFS keeps a stable Name tag
# (`{cluster}-efs`, per infra/parent-stack.yaml), so we can locate them by
# name/tag alone. Stack/bucket/EFS naming is sourced from scripts/teardown.sh
# and infra/parent-stack.yaml so the two stay in lock-step.
#
# Requires: aws CLI. The pcluster CLI is used as an extra signal when present
# but is not required (the ParallelCluster CFN stack check is authoritative).

set -euo pipefail

CLUSTER_NAME=""; REGION=""; PURGE_EFS=false
while (( $# )); do
  case "$1" in
    --cluster-name) CLUSTER_NAME="$2"; shift 2;;
    --region)       REGION="$2"; shift 2;;
    --purge-efs)    PURGE_EFS=true; shift 1;;
    -h|--help)
      echo "usage: $0 --cluster-name NAME --region REGION [--purge-efs]"
      echo ""
      echo "  --purge-efs   assert the teardown WAS run with --purge-efs, i.e. the"
      echo "                EFS filesystem should ALSO be gone. Omit to assert the"
      echo "                default teardown that RETAINS the EFS filesystem."
      exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[[ -n "${CLUSTER_NAME}" && -n "${REGION}" ]] || { echo "cluster-name + region required" >&2; exit 2; }

command -v aws >/dev/null || { echo "aws CLI not on PATH" >&2; exit 1; }

PARENT_STACK="${CLUSTER_NAME}-parent"
BUDGET_STACK="${CLUSTER_NAME}-budget"
PCLUSTER_STACK="${CLUSTER_NAME}"          # pcluster names its CFN stack after the cluster
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
STAGING_BUCKET="${CLUSTER_NAME}-${ACCOUNT_ID}-${REGION}-staging"
BOOT_BUCKET="${CLUSTER_NAME}-${ACCOUNT_ID}-${REGION}-bootstrap"
EFS_NAME_TAG="${CLUSTER_NAME}-efs"

pass=0; fail=0
check() {
  local name="$1" out="$2" ok="$3"
  # Use `x=$((x + 1))` (assignment, always exit 0) rather than `((x++))`: under
  # `set -e`, `((pass++))` returns non-zero the first time pass goes 0 -> 1 (the
  # post-increment evaluates to the old value 0, and (( )) exits 1 on a zero
  # result), which would abort the whole script right after its first PASS.
  # Same guard as verify-cluster.sh.
  if [[ "${ok}" == "true" ]]; then
    echo "  [PASS] ${name}"; pass=$((pass + 1))
  else
    echo "  [FAIL] ${name}: ${out}"; fail=$((fail + 1))
  fi
}

# ---------------------------------------------------------------------------
# CFN / pcluster stacks removed (Requirement 21.1: pcluster, budget, parent).
#
# `describe-stacks` by name errors ("Stack ... does not exist") once a stack is
# fully deleted, so a non-zero exit == absent. A stack still mid-delete returns
# DELETE_IN_PROGRESS, which we surface as a FAIL (teardown did not finish).
# ---------------------------------------------------------------------------
stack_status() {
  aws cloudformation describe-stacks --stack-name "$1" --region "${REGION}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo ABSENT
}

assert_stack_gone() {
  local stack="$1" st ok=false
  st=$(stack_status "${stack}")
  case "${st}" in
    ABSENT|DELETE_COMPLETE) ok=true;;
  esac
  check "stack ${stack} removed (status=${st})" "${st}" "${ok}"
}

echo "==> CFN / pcluster stacks removed"
assert_stack_gone "${PCLUSTER_STACK}"
assert_stack_gone "${BUDGET_STACK}"
assert_stack_gone "${PARENT_STACK}"

# pcluster CLI cross-check (optional; only when the CLI is installed). Once the
# pcluster stack is deleted, `describe-cluster` reports the cluster as absent.
if command -v pcluster >/dev/null 2>&1; then
  pc_status=$(pcluster describe-cluster --cluster-name "${CLUSTER_NAME}" --region "${REGION}" 2>/dev/null | jq -r '.clusterStatus // "GONE"' 2>/dev/null || echo GONE)
  ok=false
  case "${pc_status}" in
    GONE|DELETE_COMPLETE) ok=true;;
  esac
  check "pcluster ${CLUSTER_NAME} absent (status=${pc_status})" "${pc_status}" "${ok}"
else
  echo "  (pcluster CLI not installed; relying on the ${PCLUSTER_STACK} stack check above)"
fi

# ---------------------------------------------------------------------------
# Staging + bootstrap S3 buckets removed (Requirement 21.1).
#
# head-bucket exits 0 iff the bucket exists and is reachable; any non-zero exit
# (404 Not Found being the expected post-teardown case) means it is gone. The
# raw error text is surfaced so an unexpected 403/Forbidden stays visible rather
# than being silently read as "gone".
# ---------------------------------------------------------------------------
assert_bucket_gone() {
  local bucket="$1" out flat
  if out=$(aws s3api head-bucket --bucket "${bucket}" --region "${REGION}" 2>&1); then
    check "bucket ${bucket} removed" "still present (head-bucket succeeded)" false
  else
    flat=$(printf '%s' "${out}" | tr '\n' ' ')
    check "bucket ${bucket} removed" "absent (${flat})" true
  fi
}

echo "==> staging + bootstrap buckets removed"
assert_bucket_gone "${STAGING_BUCKET}"
assert_bucket_gone "${BOOT_BUCKET}"

# ---------------------------------------------------------------------------
# EFS filesystem retained / purged (Requirements 10.6, 21.2 / Property 11).
#
# The retained filesystem keeps its Name tag ({cluster}-efs) after the parent
# stack is gone, so we locate it by tag. We treat available/creating/updating as
# "present"; a filesystem that is absent or in deleting/deleted is "gone" (a
# lingering `deleting` during eventual consistency still counts as gone for the
# purge assertion). The raw id(state) list is surfaced either way.
# ---------------------------------------------------------------------------
echo "==> EFS filesystem (Name tag ${EFS_NAME_TAG})"
efs_query_ok=true
if ! efs_rows=$(aws efs describe-file-systems --region "${REGION}" \
      --query "FileSystems[?Tags[?Key=='Name' && Value=='${EFS_NAME_TAG}']].[FileSystemId,LifeCycleState]" \
      --output text 2>/dev/null); then
  efs_query_ok=false
  efs_rows=""
fi

efs_live=""       # ids in a live (present) lifecycle state
efs_all=""        # id(state) list, for the report message
if [[ -n "${efs_rows}" ]]; then
  while read -r fsid state; do
    if [[ -n "${fsid}" ]]; then
      efs_all="${efs_all:+${efs_all} }${fsid}(${state})"
      case "${state}" in
        available|creating|updating) efs_live="${efs_live:+${efs_live} }${fsid}";;
      esac
    fi
  done <<< "${efs_rows}"
fi

if ! $efs_query_ok; then
  check "EFS lookup by Name tag ${EFS_NAME_TAG}" "describe-file-systems call failed" false
elif $PURGE_EFS; then
  # teardown WITH --purge-efs -> the EFS filesystem must be gone.
  if [[ -z "${efs_live}" ]]; then
    check "EFS ${EFS_NAME_TAG} deleted (--purge-efs)" "${efs_all:-none found}" true
  else
    check "EFS ${EFS_NAME_TAG} deleted (--purge-efs)" "still present: ${efs_all}" false
  fi
else
  # teardown WITHOUT --purge-efs -> the EFS filesystem must be retained.
  if [[ -n "${efs_live}" ]]; then
    check "EFS ${EFS_NAME_TAG} retained (no --purge-efs)" "${efs_all}" true
  else
    check "EFS ${EFS_NAME_TAG} retained (no --purge-efs)" \
      "no live filesystem with Name tag ${EFS_NAME_TAG} (found: ${efs_all:-none}) -- retained student data appears to be gone" false
  fi
fi

echo ""
mode_desc="retain-EFS"; $PURGE_EFS && mode_desc="purge-EFS"
echo "verify-teardown [${mode_desc}] (${pass} passed, ${fail} failed)"
(( fail == 0 )) && exit 0 || exit 1
