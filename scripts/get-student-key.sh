#!/usr/bin/env bash
# get-student-key.sh — student-side helper: fetch the SSH private key from
# Secrets Manager and drop it in the current directory with mode 600.
#
# Usage:
#   scripts/get-student-key.sh --secret-arn arn:aws:secretsmanager:... --username student01 --region ap-southeast-4
#
# The secret-arn + username come from the manifest row the TA gave you.
# Requires the student to have AWS credentials with permission to read the
# specific secret. TAs typically provide these via a short-lived STS session
# or a scoped IAM user - out of scope for this script.

set -euo pipefail

ARN=""; USERNAME=""; REGION=""; OUTPUT_DIR="${PWD}"
while (( $# )); do
  case "$1" in
    --secret-arn) ARN="$2"; shift 2;;
    --username)   USERNAME="$2"; shift 2;;
    --region)     REGION="$2"; shift 2;;
    --output-dir) OUTPUT_DIR="$2"; shift 2;;
    -h|--help) echo "usage: $0 --secret-arn ARN --username NAME --region REGION [--output-dir DIR]"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[[ -n "${ARN}" && -n "${USERNAME}" && -n "${REGION}" ]] || {
  echo "secret-arn, username, and region are all required" >&2; exit 2;
}

mkdir -p "${OUTPUT_DIR}"
KEY_PATH="${OUTPUT_DIR}/${USERNAME}.pem"

aws secretsmanager get-secret-value \
  --region "${REGION}" \
  --secret-id "${ARN}" \
  --query SecretString --output text > "${KEY_PATH}"
chmod 600 "${KEY_PATH}"

echo "wrote ${KEY_PATH}"
echo "connect with:  ssh -i ${KEY_PATH} ${USERNAME}@<head-node-public-dns>"
