#!/usr/bin/env bash
# fetch-manifest.sh — pull the TA-facing student manifest from the parent stack.
#
# The manifest lists slot -> username -> Secrets Manager ARN mappings plus
# login hints. Distribute each row privately to the corresponding student.
#
# Usage:
#   scripts/fetch-manifest.sh --cluster-name NAME --region REGION [--pretty] > manifest.json

set -euo pipefail

CLUSTER_NAME=""; REGION=""; PRETTY=false
while (( $# )); do
  case "$1" in
    --cluster-name) CLUSTER_NAME="$2"; shift 2;;
    --region)       REGION="$2"; shift 2;;
    --pretty)       PRETTY=true; shift 1;;
    -h|--help) echo "usage: $0 --cluster-name NAME --region REGION [--pretty]"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[[ -n "${CLUSTER_NAME}" && -n "${REGION}" ]] || { echo "cluster-name + region required" >&2; exit 2; }

# The manifest lives in two places:
#   1. s3://<staging>/roster/manifest.json - the Lambda's own copy, PATCHED
#      post-deploy by scripts/update-manifest-head-dns.sh so each login_hint
#      carries the real head-node DNS (divergence D2 / Requirement 8.6). This is
#      the copy a TA wants: it yields a working ssh target.
#   2. The CFN stack output StudentManifestJson - a single-shot snapshot captured
#      at parent-stack creation, BEFORE the head node existed, so its login hints
#      still contain the literal `<head-node-public-dns>` placeholder.
#
# We therefore PREFER the S3 object (Req 8.4) and fall back to the stack output
# only if the S3 copy is unavailable (e.g. the staging bucket/object is gone).

STAGING=$(aws cloudformation describe-stacks \
  --stack-name "${CLUSTER_NAME}-parent" --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='StagingBucketName'].OutputValue" \
  --output text 2>/dev/null || true)

json=""
if [[ -n "${STAGING}" && "${STAGING}" != "None" ]]; then
  json=$(aws s3 cp "s3://${STAGING}/roster/manifest.json" - --region "${REGION}" 2>/dev/null || true)
fi

if [[ -z "${json}" ]]; then
  echo "==> S3 manifest unavailable; falling back to CFN stack output" >&2
  echo "    (login hints may still show the <head-node-public-dns> placeholder)" >&2
  json=$(aws cloudformation describe-stacks \
    --stack-name "${CLUSTER_NAME}-parent" --region "${REGION}" \
    --query "Stacks[0].Outputs[?OutputKey=='StudentManifestJson'].OutputValue" \
    --output text 2>/dev/null || true)
fi

if [[ -z "${json}" || "${json}" == "None" ]]; then
  echo "no manifest found; is the stack up?" >&2
  exit 1
fi

if $PRETTY; then
  echo "${json}" | jq .
else
  echo "${json}"
fi
