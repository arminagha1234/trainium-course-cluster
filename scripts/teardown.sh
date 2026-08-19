#!/usr/bin/env bash
# teardown.sh — Trainium Course Cluster ordered teardown.
#
# Order (reverse of deploy.sh):
#   1. `pcluster delete-cluster` and wait for DELETE_COMPLETE.
#   2. Delete the budget stack.
#   3. Empty the staging S3 bucket (CFN can't delete non-empty buckets).
#   4. Delete the parent stack. If RetainEfsOnDelete=true was set at deploy,
#      the EFS filesystem stays behind; instructor keeps or drops manually.
#   5. Empty + delete the bootstrap bucket (Lambda zip host).
#
# Flags:
#   --cluster-name NAME    (required)
#   --region REGION        (required)
#   --purge-efs            explicitly delete any retained EFS filesystem
#                          named after this cluster. Off by default so a
#                          teardown never accidentally destroys student work.
#   --dry-run              print actions and exit
#
# Idempotent: safe to re-run if a previous teardown failed mid-way.

set -euo pipefail

CLUSTER_NAME=""; REGION=""; PURGE_EFS=false; DRY_RUN=false

while (( $# )); do
  case "$1" in
    --cluster-name) CLUSTER_NAME="$2"; shift 2;;
    --region)       REGION="$2"; shift 2;;
    --purge-efs)    PURGE_EFS=true; shift 1;;
    --dry-run)      DRY_RUN=true; shift 1;;
    -h|--help) echo "usage: $0 --cluster-name NAME --region REGION [--purge-efs] [--dry-run]"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[[ -n "${CLUSTER_NAME}" && -n "${REGION}" ]] || { echo "cluster-name + region required" >&2; exit 2; }

command -v aws >/dev/null || { echo "aws CLI not on PATH" >&2; exit 1; }
# pcluster is only needed if a cluster exists; soft-check with a warning.
HAS_PCLUSTER=false
if command -v pcluster >/dev/null 2>&1; then
  HAS_PCLUSTER=true
fi

PARENT_STACK="${CLUSTER_NAME}-parent"
BUDGET_STACK="${CLUSTER_NAME}-budget"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BOOT_BUCKET="${CLUSTER_NAME}-${ACCOUNT_ID}-${REGION}-bootstrap"

run() { echo "+ $*"; $DRY_RUN || eval "$@"; }

# ---- 1. pcluster ----
echo "==> deleting pcluster ${CLUSTER_NAME}"
if ! $HAS_PCLUSTER; then
  echo "    pcluster CLI not installed; skipping pcluster delete (parent-only deploys have no cluster)"
elif pcluster describe-cluster --cluster-name "${CLUSTER_NAME}" --region "${REGION}" >/dev/null 2>&1; then
  run "pcluster delete-cluster --cluster-name '${CLUSTER_NAME}' --region '${REGION}' >/dev/null"
  echo "==> waiting for pcluster DELETE_COMPLETE"
  while :; do
    status=$(pcluster describe-cluster --cluster-name "${CLUSTER_NAME}" --region "${REGION}" 2>/dev/null | jq -r '.clusterStatus // "GONE"' 2>/dev/null || echo GONE)
    echo "    status=${status}"
    case "${status}" in
      GONE|DELETE_COMPLETE) break;;
      DELETE_FAILED) echo "    pcluster delete failed; investigate before continuing" >&2; exit 1;;
      *) $DRY_RUN && break; sleep 30;;
    esac
  done
else
  echo "    pcluster ${CLUSTER_NAME} not found; skipping"
fi

# ---- 2. budget stack ----
echo "==> deleting budget stack ${BUDGET_STACK}"
if aws cloudformation describe-stacks --stack-name "${BUDGET_STACK}" --region "${REGION}" >/dev/null 2>&1; then
  run "aws cloudformation delete-stack --stack-name '${BUDGET_STACK}' --region '${REGION}'"
  run "aws cloudformation wait stack-delete-complete --stack-name '${BUDGET_STACK}' --region '${REGION}'"
else
  echo "    ${BUDGET_STACK} not found; skipping"
fi

# ---- 3. capture parent stack info BEFORE deleting anything ----
STAGING_BUCKET=$(aws cloudformation describe-stacks --stack-name "${PARENT_STACK}" --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='StagingBucketName'].OutputValue" --output text 2>/dev/null || echo "")
EFS_ID=$(aws cloudformation describe-stacks --stack-name "${PARENT_STACK}" --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='EfsFilesystemId'].OutputValue" --output text 2>/dev/null || echo "")

# Deep-empty a versioned bucket (both live versions AND delete markers).
# CFN's AWS::S3::Bucket can't delete non-empty buckets, and the Manifest
# Lambda's Delete handler adds new delete markers between our empty and the
# stack delete. Workaround: retain the bucket during stack delete, then
# delete it manually here.
deep_empty_bucket() {
  local bucket="$1"
  aws s3api head-bucket --bucket "$bucket" --region "${REGION}" 2>/dev/null || return 0
  local vers_json="/tmp/${CLUSTER_NAME}-${bucket}-vers.json"
  aws s3api list-object-versions --bucket "$bucket" --region "${REGION}" --output json 2>/dev/null | \
    python3 -c "
import json, sys
d = json.load(sys.stdin)
objs = []
for v in d.get('Versions') or []:
    objs.append({'Key': v['Key'], 'VersionId': v['VersionId']})
for m in d.get('DeleteMarkers') or []:
    objs.append({'Key': m['Key'], 'VersionId': m['VersionId']})
print(json.dumps({'Objects': objs}))
" > "$vers_json"
  local count
  count=$(python3 -c "import json; print(len(json.load(open('$vers_json'))['Objects']))")
  echo "    $bucket: $count objects+markers"
  if (( count > 0 )) && ! $DRY_RUN; then
    aws s3api delete-objects --bucket "$bucket" --region "${REGION}" --delete "file://$vers_json" >/dev/null
  fi
  rm -f "$vers_json"
}

# Delete the staging bucket OUTSIDE CFN first. CFN's AWS::S3::Bucket can't
# delete non-empty buckets, and the Manifest Lambda's Delete handler will
# add fresh delete markers as part of the stack delete flow, which races
# with our empty. By deleting the bucket outside CFN before delete-stack,
# CFN's bucket deletion becomes a no-op (resource-not-found = success).
if [[ -n "${STAGING_BUCKET}" && "${STAGING_BUCKET}" != "None" ]]; then
  echo "==> deep-emptying + deleting staging bucket manually (before stack delete)"
  deep_empty_bucket "${STAGING_BUCKET}"
  run "aws s3api delete-bucket --bucket '${STAGING_BUCKET}' --region '${REGION}' 2>&1 || true"
fi

# ---- 4. parent stack ----
echo "==> deleting parent stack ${PARENT_STACK}"
if aws cloudformation describe-stacks --stack-name "${PARENT_STACK}" --region "${REGION}" >/dev/null 2>&1; then
  run "aws cloudformation delete-stack --stack-name '${PARENT_STACK}' --region '${REGION}'"
  # Give CFN a moment then poll — we intentionally don't `wait stack-delete-complete`
  # because it errors hard on DELETE_FAILED, and we want to retry.
  sleep 20
  for i in 1 2 3 4 5 6 7 8 9 10; do
    st=$(aws cloudformation describe-stacks --stack-name "${PARENT_STACK}" --region "${REGION}" \
      --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo GONE)
    echo "    poll $i: ${st}"
    case "$st" in
      GONE|*"does not exist"*|DELETE_COMPLETE) break;;
      DELETE_FAILED)
        # Some resource is stuck. Retry with retain to skip anything that failed.
        stuck=$(aws cloudformation list-stack-resources --stack-name "${PARENT_STACK}" --region "${REGION}" \
          --query 'StackResourceSummaries[?ResourceStatus==`DELETE_FAILED`].LogicalResourceId' --output text)
        echo "    stuck resources: ${stuck:-none}"
        if [[ -n "${stuck}" ]]; then
          run "aws cloudformation delete-stack --stack-name '${PARENT_STACK}' --region '${REGION}' --retain-resources ${stuck}"
        fi
        ;;
    esac
    sleep 20
  done
else
  echo "    ${PARENT_STACK} not found; skipping"
fi

# ---- 6. EFS (retained by design; purged only with --purge-efs) ----
if $PURGE_EFS && [[ -n "${EFS_ID}" && "${EFS_ID}" != "None" ]]; then
  echo "==> --purge-efs set; deleting retained EFS ${EFS_ID}"
  aws efs update-file-system-protection --region "${REGION}" --file-system-id "${EFS_ID}" \
    --replication-overwrite-protection DISABLED 2>/dev/null || true
  mt_ids=$(aws efs describe-mount-targets --file-system-id "${EFS_ID}" --region "${REGION}" \
    --query 'MountTargets[].MountTargetId' --output text 2>/dev/null || echo "")
  for mt in ${mt_ids}; do
    run "aws efs delete-mount-target --mount-target-id '${mt}' --region '${REGION}' 2>&1 || true"
  done
  $DRY_RUN || sleep 20
  run "aws efs delete-file-system --file-system-id '${EFS_ID}' --region '${REGION}' 2>&1 || true"
elif [[ -n "${EFS_ID}" && "${EFS_ID}" != "None" ]]; then
  echo "    EFS ${EFS_ID} retained (pass --purge-efs to delete)"
fi

# ---- 7. bootstrap bucket ----
echo "==> deleting bootstrap bucket s3://${BOOT_BUCKET}"
if aws s3api head-bucket --bucket "${BOOT_BUCKET}" --region "${REGION}" 2>/dev/null; then
  # Bootstrap bucket is not versioned but for safety use deep_empty_bucket anyway.
  deep_empty_bucket "${BOOT_BUCKET}"
  run "aws s3api delete-bucket --bucket '${BOOT_BUCKET}' --region '${REGION}' 2>&1 || true"
else
  echo "    ${BOOT_BUCKET} not found; skipping"
fi

echo ""
echo "==> teardown complete for ${CLUSTER_NAME}"
if [[ -n "${EFS_ID:-}" && "${EFS_ID}" != "None" ]] && ! $PURGE_EFS; then
  echo "==> student EFS retained: ${EFS_ID}"
  echo "    to fully remove, re-run with --purge-efs"
fi
