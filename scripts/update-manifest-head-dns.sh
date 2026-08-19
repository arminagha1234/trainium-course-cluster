#!/usr/bin/env bash
# update-manifest-head-dns.sh — patch the TA manifest's login hints with the
# real head-node public DNS once the cluster exists (divergence D2; Req 8.6).
#
# The Manifest Lambda runs during PARENT-stack creation, BEFORE the head node
# exists, so every student's `login_hint` ends in the literal placeholder
# `<head-node-public-dns>` (see lambda/student_manifest/handler.py, which builds
# the hint as "... ssh -i <user>.pem <user>@<head-node-public-dns>"). Once
# `pcluster` reaches CREATE_COMPLETE this script rewrites the staging bucket's
# roster/manifest.json, replacing that placeholder in each login hint with the
# actual head-node public DNS/IP, so the TA (via fetch-manifest.sh) hands each
# student a working ssh target.
#
# Idempotent: the patch is a no-op when no login hint still carries the
# placeholder (e.g. re-running with the same DNS) — the S3 object is only
# rewritten when at least one hint actually changes. Note this keys off the
# placeholder, so it performs the initial substitution only; it does not later
# rewrite an already-substituted host to a new DNS (Req 8.6 covers the initial
# placeholder replacement).
#
# Usage:
#   scripts/update-manifest-head-dns.sh --cluster-name NAME --region REGION [--head-dns DNS]
#
# --head-dns is optional; when omitted it is resolved from
#   `pcluster describe-cluster ... headNode.publicIpAddress` (the same query
#   deploy.sh uses for its banner).

set -euo pipefail

CLUSTER_NAME=""; REGION=""; HEAD_DNS=""
while (( $# )); do
  case "$1" in
    --cluster-name) CLUSTER_NAME="$2"; shift 2;;
    --region)       REGION="$2"; shift 2;;
    --head-dns)     HEAD_DNS="$2"; shift 2;;
    -h|--help)
      echo "usage: $0 --cluster-name NAME --region REGION [--head-dns DNS]"
      echo ""
      echo "  --head-dns DNS   head-node public DNS/IP to substitute for the"
      echo "                   <head-node-public-dns> placeholder. When omitted it is"
      echo "                   resolved via 'pcluster describe-cluster ... headNode.publicIpAddress'."
      exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[[ -n "${CLUSTER_NAME}" && -n "${REGION}" ]] || { echo "cluster-name + region required" >&2; exit 2; }

command -v aws >/dev/null || { echo "aws CLI not on PATH" >&2; exit 1; }
command -v jq  >/dev/null || { echo "jq not found" >&2; exit 1; }

PLACEHOLDER="<head-node-public-dns>"
PARENT_STACK="${CLUSTER_NAME}-parent"

# ---------------------------------------------------------------------------
# Resolve the head-node public DNS/IP if not supplied. Mirrors the query
# deploy.sh uses for its banner (headNode.publicIpAddress).
# ---------------------------------------------------------------------------
if [[ -z "${HEAD_DNS}" ]]; then
  command -v pcluster >/dev/null || {
    echo "pcluster CLI not on PATH; pass --head-dns explicitly" >&2; exit 1;
  }
  echo "==> resolving head-node public DNS via pcluster describe-cluster"
  HEAD_DNS=$(pcluster describe-cluster --cluster-name "${CLUSTER_NAME}" --region "${REGION}" 2>/dev/null | jq -r '.headNode.publicIpAddress // empty' 2>/dev/null || echo "")
fi
if [[ -z "${HEAD_DNS}" || "${HEAD_DNS}" == "None" || "${HEAD_DNS}" == "<unknown>" ]]; then
  echo "could not determine head-node public DNS (got '${HEAD_DNS:-<empty>}');" >&2
  echo "  is the cluster CREATE_COMPLETE? pass --head-dns to override." >&2
  exit 1
fi
echo "    head DNS: ${HEAD_DNS}"

# ---------------------------------------------------------------------------
# Resolve the staging bucket. Prefer the parent stack's StagingBucketName output
# (authoritative); fall back to the deterministic name if the output is empty
# (matches infra/parent-stack.yaml + scripts/verify-teardown.sh).
# ---------------------------------------------------------------------------
STAGING=$(aws cloudformation describe-stacks --stack-name "${PARENT_STACK}" --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='StagingBucketName'].OutputValue" --output text 2>/dev/null || echo "")
if [[ -z "${STAGING}" || "${STAGING}" == "None" ]]; then
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  STAGING="${CLUSTER_NAME}-${ACCOUNT_ID}-${REGION}-staging"
  echo "==> parent stack output empty; using deterministic staging bucket ${STAGING}"
fi
MANIFEST_URI="s3://${STAGING}/roster/manifest.json"

# ---------------------------------------------------------------------------
# Read the current manifest from S3.
# ---------------------------------------------------------------------------
echo "==> reading ${MANIFEST_URI}"
manifest=$(aws s3 cp "${MANIFEST_URI}" - --region "${REGION}" 2>/dev/null || true)
if [[ -z "${manifest}" ]]; then
  echo "no manifest found at ${MANIFEST_URI}; is the parent stack up?" >&2
  exit 1
fi

# How many login hints still carry the placeholder? (`contains` is a literal
# substring test.) Zero means the manifest is already patched -> no-op.
pending=$(jq --arg ph "${PLACEHOLDER}" \
  '[.students[]? | select((.login_hint // "") | contains($ph))] | length' <<< "${manifest}")

if [[ "${pending}" == "0" ]]; then
  echo "==> no login hints contain the placeholder; manifest already patched (no-op)"
  exit 0
fi

# ---------------------------------------------------------------------------
# Patch every login hint: replace the placeholder host with the real DNS. Use
# split()|join() (literal) rather than gsub() (regex) so the substitution is
# never affected by regex metacharacters.
# ---------------------------------------------------------------------------
patched=$(jq --arg ph "${PLACEHOLDER}" --arg dns "${HEAD_DNS}" \
  '.students |= map(.login_hint |= (split($ph) | join($dns)))' <<< "${manifest}")

# Preserve the Class tag (read from the manifest itself) + SSE, matching how the
# Manifest Lambda originally wrote the object.
class_tag=$(jq -r '.class_tag // empty' <<< "${manifest}")

tmp=$(mktemp)
printf '%s' "${patched}" > "${tmp}"
put_args=(--bucket "${STAGING}" --key "roster/manifest.json" --body "${tmp}"
          --content-type application/json --server-side-encryption AES256
          --region "${REGION}")
if [[ -n "${class_tag}" ]]; then
  put_args+=(--tagging "Class=${class_tag}&Purpose=trn-course-manifest")
fi
aws s3api put-object "${put_args[@]}" >/dev/null
rm -f "${tmp}"

echo "==> patched ${pending} login hint(s) with head DNS ${HEAD_DNS}"
echo "    wrote ${MANIFEST_URI}"
