#!/usr/bin/env bash
# deploy-login-node.sh — stand up a STANDALONE AWS PCS login node for the
# Trainium Course Cluster PCS variant (Phase 1 + Phase 3; see ../docs/design.md).
#
# PCS runs the Slurm controller (slurmctld + slurmdbd) in a service-owned
# account, so there is NO head node this kit owns — students have nowhere to
# `ssh` in and `sbatch`, and there is nowhere to run `sacctmgr`. This script
# launches a self-managed EC2 that JOINS the managed cluster's Slurm as a submit
# host (via sackd), creates the per-student POSIX users, and (Phase 3) sets the
# per-student QoS limits.
#
# It is the sibling of scripts/deploy-pcs.sh and deliberately mirrors its style:
# `set -euo pipefail`, flag parsing, local + AWS-side validation, `==>` progress
# echoes, idempotent re-runs, and a summary banner. It touches only
# `aws sts|ec2|iam|ssm|pcs|secretsmanager` and does NOT modify the parent kit.
#
# ----------------------------------------------------------------------------
# This reproduces the AWS-documented "standalone login node" flow:
#   https://docs.aws.amazon.com/pcs/latest/userguide/working-with_login-nodes_standalone.html
# and is NOT yet live-validated on a real PCS cluster (see ../docs/design.md
# "OPEN ITEMS"). Content on AWS PCS behavior was summarized from AWS
# documentation and rephrased for compliance with licensing restrictions.
#
# Sequence:
#   1. Validate region + inputs (incl. --ssh-allowed-cidr, copied from the
#      parent kit's scripts/deploy.sh) locally, before any AWS call.
#   2. aws pcs get-cluster -> the Slurm auth secret ARN, the SLURMCTLD endpoint
#      (private IP + port), and the cluster security group.
#   3. Create/reuse a login security group (TCP/22 from the allowed CIDR(s) only).
#   4. Create/reuse an IAM role (AWSPCS-<cluster>-login) + instance profile with
#      a scoped inline policy granting secretsmanager:GetSecretValue on EXACTLY
#      the cluster secret ARN, plus SSM + S3 read-only managed policies.
#   5. Resolve the PCS sample Ubuntu 24.04 base AMI from SSM.
#   6. Render bootstrap/login-node-setup.sh (placeholders substituted on a temp
#      copy via sed — the source is never mutated), STAGE that rendered copy to
#      a per-cluster S3 boot bucket, and build a TINY UserData that downloads +
#      runs it at first boot. WHY: EC2 caps raw user-data at 16 KB, but the
#      rendered setup script is ~24 KB (live symptom: "Encoded User data is
#      limited to 25600 bytes"), so it CANNOT be inlined — we mirror the parent
#      kit's scripts/deploy.sh, which stages its bootstrap scripts to S3.
#   7. run-instances ONE on-demand instance (NOT capacity-block) attached to
#      [loginSG, clusterSG] + the instance profile + the key pair, with IMDSv2
#      required and a low hop limit — retrying on IAM instance-profile
#      eventual-consistency errors (a freshly created profile can be briefly
#      invisible to EC2), mirroring deploy-pcs.sh's create-node-group retry.
#   8. Wait running; print IPs, an SSH hint, and a reminder to confirm `sinfo`.
#
# Idempotent: SG / role / instance-profile / instance creation each detect an
# existing resource and reuse it. --dry-run stops after all validation.

set -euo pipefail

# ============================================================================
# CLI parsing
# ============================================================================
# Max number of comma-separated ranges accepted by --ssh-allowed-cidr, matching
# the parent kit's scripts/deploy.sh. Each range becomes one TCP/22 ingress rule
# on the login SG; an open range (0.0.0.0/0 or ::/0) anywhere is rejected.
MAX_SSH_CIDRS=5

usage() {
  cat >&2 <<EOF
usage: $0 [options]

Required:
  --cluster-name NAME              existing PCS cluster name. [A-Za-z][A-Za-z0-9-]{2,40}
  --region REGION                  only sa-east-1 or us-east-2 are supported
  --vpc-id VPC_ID                  VPC the cluster/subnet live in (vpc-XXXX)
  --subnet-id SUBNET_ID            subnet for the login node (in the cluster VPC)
  --ssh-allowed-cidr CIDR[,CIDR...] one CIDR, or up to ${MAX_SSH_CIDRS} comma-separated ranges,
                                   e.g. 10.20.0.0/16  or  10.20.0.0/16,192.0.2.0/24
                                   (0.0.0.0/0 and ::/0 rejected in ANY range)
  --key-name KEYNAME               EC2 keypair for the login node ubuntu sudoer

Optional:
  --login-instance-type TYPE       default m6i.large
  --student-count N                1..500 (recorded; drives roster expectations)
  --staging-bucket BUCKET          S3 bucket holding roster/roster.json. If omitted,
                                   the login node expects /shared/etc/passwd.roster
                                   from the Phase-4 EFS mount instead.
  --efs-id fs-XXXX                 EFS filesystem to mount at /shared
  --max-wall-time TIME             per-job wall clock (default 1-00:00:00);
                                   [days-]HH:MM:SS, HH:MM:SS, MM:SS, or bare minutes;
                                   must resolve to between 1 minute and 7 days
  --max-concurrent-jobs-per-user N default 8 (integer 1..100)
  --dry-run                        run all validation, then stop before mutating
  -h|--help                        show this help
EOF
  exit 2
}

# Defaults
LOGIN_INSTANCE_TYPE=m6i.large
STUDENT_COUNT=""
STAGING_BUCKET=""
EFS_ID=""
MAX_WALL_TIME=1-00:00:00
MAX_CONCURRENT_JOBS_PER_USER=8
DRY_RUN=false
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The Slurm release line the login node installs / expects. Matches deploy-pcs.sh
# (25.11; 24.11 is EOL). Passed to the bootstrap as SLURM_VERSION so the
# /opt/aws/pcs/scheduler/slurm-${SLURM_VERSION} paths line up.
SLURM_VERSION="25.11"

CLUSTER_NAME=""; REGION=""; VPC_ID=""; SUBNET_ID=""; SSH_CIDR=""; KEY_NAME=""

while (( $# )); do
  case "$1" in
    --cluster-name)                 CLUSTER_NAME="$2"; shift 2;;
    --region)                       REGION="$2"; shift 2;;
    --vpc-id)                       VPC_ID="$2"; shift 2;;
    --subnet-id)                    SUBNET_ID="$2"; shift 2;;
    --ssh-allowed-cidr)             SSH_CIDR="$2"; shift 2;;
    --key-name)                     KEY_NAME="$2"; shift 2;;
    --login-instance-type)          LOGIN_INSTANCE_TYPE="$2"; shift 2;;
    --student-count)                STUDENT_COUNT="$2"; shift 2;;
    --staging-bucket)               STAGING_BUCKET="$2"; shift 2;;
    --efs-id)                       EFS_ID="$2"; shift 2;;
    --max-wall-time)                MAX_WALL_TIME="$2"; shift 2;;
    --max-concurrent-jobs-per-user) MAX_CONCURRENT_JOBS_PER_USER="$2"; shift 2;;
    --dry-run)                      DRY_RUN=true; shift 1;;
    -h|--help)                      usage;;
    *) echo "unknown arg: $1" >&2; usage;;
  esac
done

# ============================================================================
# Local validation (before any AWS call)
# ============================================================================
required_vars=(CLUSTER_NAME REGION VPC_ID SUBNET_ID SSH_CIDR KEY_NAME)
missing=()
for var in "${required_vars[@]}"; do
  [[ -z "${!var}" ]] && missing+=("$var")
done
if (( ${#missing[@]} )); then
  echo "missing required flags: ${missing[*]}" >&2
  usage
fi

# Same PCS cluster-name pattern as deploy-pcs.sh.
[[ "${CLUSTER_NAME}" =~ ^[A-Za-z][A-Za-z0-9-]{2,40}$ ]] || {
  echo "cluster-name must match ^[A-Za-z][A-Za-z0-9-]{2,40}\$ (got '${CLUSTER_NAME}')" >&2
  exit 1
}
[[ "${VPC_ID}" =~ ^vpc-[0-9a-f]{8,17}$ ]] || {
  echo "vpc-id must look like vpc-XXXXXXXX (got '${VPC_ID}')" >&2
  exit 1
}
[[ "${SUBNET_ID}" =~ ^subnet-[0-9a-f]{8,17}$ ]] || {
  echo "subnet-id must look like subnet-XXXXXXXX (got '${SUBNET_ID}')" >&2
  exit 1
}
if [[ -n "${EFS_ID}" ]]; then
  [[ "${EFS_ID}" =~ ^fs-[0-9a-f]{8,17}$ ]] || {
    echo "efs-id must look like fs-XXXXXXXX (got '${EFS_ID}')" >&2
    exit 1
  }
fi
if [[ -n "${STUDENT_COUNT}" ]]; then
  [[ "${STUDENT_COUNT}" =~ ^[0-9]+$ ]] && (( STUDENT_COUNT >= 1 && STUDENT_COUNT <= 500 )) || {
    echo "student-count must be an integer in [1, 500] (got '${STUDENT_COUNT}')" >&2
    exit 1
  }
fi

# ---------------------------------------------------------------------------
# --ssh-allowed-cidr validation (COPIED from the parent kit's scripts/deploy.sh,
# Requirements 14.2/23.3/23.5). Accepts a single CIDR or a comma-separated list
# of up to MAX_SSH_CIDRS ranges. EACH range must be a syntactically valid
# IPv4/IPv6 CIDR and must NOT be an open range (0.0.0.0/0 or ::/0) — an open
# range anywhere in the list is rejected. The cleaned list is kept as an array
# and one TCP/22 ingress rule is created per range on the login SG.
# ---------------------------------------------------------------------------
IFS=',' read -r -a _ssh_cidr_fields <<< "${SSH_CIDR}"
ssh_cidr_ranges=()
for _raw in "${_ssh_cidr_fields[@]}"; do
  # Trim surrounding whitespace so "a/24, b/24" is accepted.
  _c="${_raw#"${_raw%%[![:space:]]*}"}"
  _c="${_c%"${_c##*[![:space:]]}"}"
  [[ -z "${_c}" ]] && continue   # ignore empties from stray/trailing commas
  ssh_cidr_ranges+=("${_c}")
done

if (( ${#ssh_cidr_ranges[@]} < 1 )); then
  echo "ssh-allowed-cidr must contain at least one CIDR range" >&2
  exit 1
fi
if (( ${#ssh_cidr_ranges[@]} > MAX_SSH_CIDRS )); then
  echo "ssh-allowed-cidr accepts at most ${MAX_SSH_CIDRS} comma-separated ranges (got ${#ssh_cidr_ranges[@]})" >&2
  exit 1
fi
for _c in "${ssh_cidr_ranges[@]}"; do
  # Reject an open range anywhere in the list.
  [[ "${_c}" =~ ^0\.0\.0\.0/0$|^::/0$ ]] && {
    echo "refusing to deploy with an open SSH range (${_c}) in --ssh-allowed-cidr" >&2
    exit 1
  }
  # Each range must be a syntactically valid IPv4 or IPv6 CIDR.
  [[ "${_c}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ || "${_c}" =~ ^[0-9A-Fa-f:]+/[0-9]+$ ]] || {
    echo "ssh-allowed-cidr range '${_c}' is not a valid CIDR" >&2
    exit 1
  }
done

# ---------------------------------------------------------------------------
# Region constraint — same allow-list as deploy-pcs.sh / the parent kit:
# sa-east-1 (Sao Paulo, trn2.3xlarge MLCB home) and us-east-2 (Ohio).
# ---------------------------------------------------------------------------
case "${REGION}" in
  sa-east-1|us-east-2) : ;;
  *)
    echo "ERROR: --region ${REGION} is not supported by this kit." >&2
    echo "  Only sa-east-1 and us-east-2 are supported (parity with deploy-pcs.sh)." >&2
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# Per-student wall-time validation (same helper as the parent kit's deploy.sh).
# Converts a Slurm time string to seconds and bounds it to 1 minute .. 7 days.
# Concurrent-jobs is an integer 1..100. These feed the login bootstrap's Phase-3
# sacctmgr QoS (MaxWall + MaxJobsPerUser). NOTE: there is deliberately no
# per-core / core-hours limit here — neuroncore cannot be a TRES on PCS (see
# ../docs/design.md Phase 2 and the bootstrap's section 7).
# ---------------------------------------------------------------------------
wall_time_to_seconds() {
  local t="$1" days=0 hours=0 mins=0 secs=0 rest
  if [[ "$t" =~ ^([0-9]+)-(.*)$ ]]; then
    days="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"
    if   [[ "$rest" =~ ^([0-9]+)$ ]]; then hours="${BASH_REMATCH[1]}"
    elif [[ "$rest" =~ ^([0-9]+):([0-9]+)$ ]]; then hours="${BASH_REMATCH[1]}"; mins="${BASH_REMATCH[2]}"
    elif [[ "$rest" =~ ^([0-9]+):([0-9]+):([0-9]+)$ ]]; then hours="${BASH_REMATCH[1]}"; mins="${BASH_REMATCH[2]}"; secs="${BASH_REMATCH[3]}"
    else return 1; fi
  elif [[ "$t" =~ ^([0-9]+)$ ]]; then mins="${BASH_REMATCH[1]}"
  elif [[ "$t" =~ ^([0-9]+):([0-9]+)$ ]]; then mins="${BASH_REMATCH[1]}"; secs="${BASH_REMATCH[2]}"
  elif [[ "$t" =~ ^([0-9]+):([0-9]+):([0-9]+)$ ]]; then hours="${BASH_REMATCH[1]}"; mins="${BASH_REMATCH[2]}"; secs="${BASH_REMATCH[3]}"
  else return 1; fi
  echo $(( 10#$days*86400 + 10#$hours*3600 + 10#$mins*60 + 10#$secs ))
}
WALL_SECONDS=$(wall_time_to_seconds "${MAX_WALL_TIME}") || {
  echo "max-wall-time '${MAX_WALL_TIME}' is not a valid Slurm time string" >&2
  echo "  (accepted: [days-]HH:MM:SS, HH:MM:SS, MM:SS, or a bare minute count)" >&2
  exit 1
}
(( WALL_SECONDS >= 60 && WALL_SECONDS <= 604800 )) || {
  echo "max-wall-time must resolve to between 1 minute and 7 days (got '${MAX_WALL_TIME}')" >&2
  exit 1
}
[[ "${MAX_CONCURRENT_JOBS_PER_USER}" =~ ^[0-9]+$ ]] && \
  (( MAX_CONCURRENT_JOBS_PER_USER >= 1 && MAX_CONCURRENT_JOBS_PER_USER <= 100 )) || {
  echo "max-concurrent-jobs-per-user must be an integer in [1, 100] (got '${MAX_CONCURRENT_JOBS_PER_USER}')" >&2
  exit 1
}

for c in aws jq base64; do
  command -v "$c" >/dev/null || { echo "${c} not on PATH" >&2; exit 1; }
done

# The login-node UserData script we render + inject.
USERDATA_FILE="${REPO_DIR}/bootstrap/login-node-setup.sh"
[[ -f "${USERDATA_FILE}" ]] || {
  echo "ERROR: login-node UserData script not found at ${USERDATA_FILE}" >&2
  exit 1
}

# Derived resource names (the login role name starts with AWSPCS for parity with
# deploy-pcs.sh's grouping; the SG name is cosmetic).
LOGIN_SG_NAME="AWSPCS-${CLUSTER_NAME}-login-sg"
ROLE_NAME="AWSPCS-${CLUSTER_NAME}-login"
PROFILE_NAME="${ROLE_NAME}"
LOGIN_NODE_NAME="AWSPCS-${CLUSTER_NAME}-login"

# ============================================================================
# AWS-side validation
# ============================================================================
echo "==> validating AWS context"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "    account=${ACCOUNT_ID} region=${REGION}"

echo "==> validating admin SSH key ${KEY_NAME}"
aws ec2 describe-key-pairs --region "${REGION}" --key-names "${KEY_NAME}" >/dev/null 2>&1 || {
  echo "    ERROR: EC2 keypair ${KEY_NAME} not found in ${REGION}" >&2
  exit 1
}

# Confirm the subnet is in the cluster VPC and learn whether it auto-assigns a
# public IP (so we can associate one only when the subnet is public; private
# subnets reach the box via SSM instead).
echo "==> validating subnet ${SUBNET_ID}"
subnet_vpc=$(aws ec2 describe-subnets --region "${REGION}" --subnet-ids "${SUBNET_ID}" \
  --query 'Subnets[0].VpcId' --output text 2>/dev/null || echo "unknown")
SUBNET_PUBLIC=$(aws ec2 describe-subnets --region "${REGION}" --subnet-ids "${SUBNET_ID}" \
  --query 'Subnets[0].MapPublicIpOnLaunch' --output text 2>/dev/null || echo "unknown")
echo "    subnet vpc=${subnet_vpc} mapPublicIpOnLaunch=${SUBNET_PUBLIC}"
if [[ "${subnet_vpc}" != "${VPC_ID}" ]]; then
  echo "    ERROR: subnet ${SUBNET_ID} is in ${subnet_vpc}, not --vpc-id ${VPC_ID}." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# PCS cluster lookup (Step 1 of the standalone-login-node flow). One
# get-cluster call yields everything the login node needs:
#   - the Slurm auth secret ARN  (cluster.slurmConfiguration.authKey.secretArn)
#   - the SLURMCTLD private IP + port (cluster.endpoints[type==SLURMCTLD])
#   - the cluster security group (cluster.networking.securityGroupIds[0]) — the
#     login node attaches this so it can reach the controller (the cluster SG is
#     self-referencing: all traffic within itself).
# ---------------------------------------------------------------------------
echo "==> looking up PCS cluster ${CLUSTER_NAME}"
cluster_json=$(aws pcs get-cluster --region "${REGION}" \
  --cluster-identifier "${CLUSTER_NAME}" --output json 2>/dev/null || echo '{}')
CLUSTER_STATUS=$(echo "${cluster_json}" | jq -r '.cluster.status // "MISSING"')
if [[ "${CLUSTER_STATUS}" == "MISSING" ]]; then
  echo "    ERROR: could not describe PCS cluster '${CLUSTER_NAME}' in ${REGION}." >&2
  echo "      Deploy the cluster first with scripts/deploy-pcs.sh." >&2
  exit 1
fi
CLUSTER_ID=$(echo "${cluster_json}" | jq -r '.cluster.id // empty')
SECRET_ARN=$(echo "${cluster_json}" | jq -r '.cluster.slurmConfiguration.authKey.secretArn // empty')
SLURMCTLD_IP=$(echo "${cluster_json}" | jq -r '[.cluster.endpoints[]? | select(.type=="SLURMCTLD") | .privateIpAddress][0] // empty')
SLURMCTLD_PORT=$(echo "${cluster_json}" | jq -r '[.cluster.endpoints[]? | select(.type=="SLURMCTLD") | .port][0] // empty')
CLUSTER_SG=$(echo "${cluster_json}" | jq -r '[.cluster.networking.securityGroupIds[]?][0] // empty')
[[ -z "${SLURMCTLD_PORT}" || "${SLURMCTLD_PORT}" == "null" ]] && SLURMCTLD_PORT="6817"
echo "    status=${CLUSTER_STATUS} id=${CLUSTER_ID} slurmctld=${SLURMCTLD_IP}:${SLURMCTLD_PORT}"
echo "    authSecret=${SECRET_ARN}"
echo "    clusterSG=${CLUSTER_SG}"

if [[ -z "${SECRET_ARN}" ]]; then
  echo "    ERROR: cluster has no slurmConfiguration.authKey.secretArn; cannot configure sackd." >&2
  exit 1
fi
if [[ -z "${SLURMCTLD_IP}" ]]; then
  echo "    ERROR: cluster has no SLURMCTLD endpoint yet (is it ACTIVE?); cannot configure sackd." >&2
  exit 1
fi
if [[ -z "${CLUSTER_SG}" ]]; then
  echo "    ERROR: cluster has no security group; cannot let the login node reach the controller." >&2
  exit 1
fi

if $DRY_RUN; then
  echo "==> dry-run: validation passed; stopping before creating any resources"
  exit 0
fi

# ============================================================================
# 1. Login security group (TCP/22 from the allowed CIDR(s) only; all egress)
# ============================================================================
# The login node carries TWO security groups: this one (student SSH ingress)
# AND the cluster SG (fetched above) so it can reach the Slurm controller. This
# SG opens only TCP/22, only from the validated --ssh-allowed-cidr range(s);
# egress is the SG default allow-all.
echo "==> ensuring login security group ${LOGIN_SG_NAME}"
LOGIN_SG_ID=$(aws ec2 describe-security-groups --region "${REGION}" \
  --filters "Name=group-name,Values=${LOGIN_SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")

if [[ "${LOGIN_SG_ID}" == "None" || -z "${LOGIN_SG_ID}" ]]; then
  LOGIN_SG_ID=$(aws ec2 create-security-group --region "${REGION}" \
    --group-name "${LOGIN_SG_NAME}" \
    --description "AWS PCS login node SSH SG for ${CLUSTER_NAME}" \
    --vpc-id "${VPC_ID}" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Class,Value=${CLUSTER_NAME}},{Key=Purpose,Value=trn-course-pcs-login}]" \
    --query 'GroupId' --output text)
  echo "    created ${LOGIN_SG_ID}"
else
  echo "    reusing ${LOGIN_SG_ID}"
fi

# One TCP/22 ingress rule per validated CIDR range. Idempotent: an existing rule
# returns InvalidPermission.Duplicate, which we treat as success.
for _c in "${ssh_cidr_ranges[@]}"; do
  echo "==> ensuring SSH ingress 22 from ${_c} on ${LOGIN_SG_ID}"
  if err=$(aws ec2 authorize-security-group-ingress --region "${REGION}" \
        --group-id "${LOGIN_SG_ID}" \
        --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${_c}}]" 2>&1); then
    echo "    added SSH ingress from ${_c}"
  else
    if grep -qi 'Duplicate' <<<"${err}"; then
      echo "    SSH ingress from ${_c} already present"
    else
      echo "${err}" >&2
      exit 1
    fi
  fi
done

# ============================================================================
# 2. IAM role (AWSPCS-<cluster>-login) + instance profile + policies
# ============================================================================
# The role trusts ec2.amazonaws.com and carries:
#   - a SCOPED inline policy: secretsmanager:GetSecretValue on EXACTLY the
#     cluster secret ARN (least privilege — the login node only needs to read
#     that one secret to configure sackd);
#   - AmazonSSMManagedInstanceCore (SSM access — the private-subnet fallback for
#     shell access), AmazonS3ReadOnlyAccess (fetch roster/roster.json).
# IAM is global (no --region).
MANAGED_POLICIES=(
  "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
)
TRUST_DOC='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

echo "==> ensuring IAM role ${ROLE_NAME}"
if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  echo "    role already exists"
else
  aws iam create-role --role-name "${ROLE_NAME}" \
    --assume-role-policy-document "${TRUST_DOC}" \
    --description "AWS PCS standalone login node role for ${CLUSTER_NAME}" \
    --tags "Key=Class,Value=${CLUSTER_NAME}" "Key=Purpose,Value=trn-course-pcs-login" >/dev/null
  echo "    created role ${ROLE_NAME}"
fi

for pol in "${MANAGED_POLICIES[@]}"; do
  echo "    attaching ${pol##*/}"
  aws iam attach-role-policy --role-name "${ROLE_NAME}" --policy-arn "${pol}"
done

# Scoped inline policy for the cluster secret (built via jq so the ARN is
# injected safely).
echo "    putting scoped inline policy read-cluster-secret (GetSecretValue on the exact ARN)"
SECRET_POLICY=$(jq -n --arg arn "${SECRET_ARN}" \
  '{Version:"2012-10-17",Statement:[{Effect:"Allow",Action:"secretsmanager:GetSecretValue",Resource:$arn}]}')
aws iam put-role-policy --role-name "${ROLE_NAME}" \
  --policy-name "read-cluster-secret" \
  --policy-document "${SECRET_POLICY}"

echo "==> ensuring instance profile ${PROFILE_NAME}"
if aws iam get-instance-profile --instance-profile-name "${PROFILE_NAME}" >/dev/null 2>&1; then
  echo "    instance profile already exists"
else
  aws iam create-instance-profile --instance-profile-name "${PROFILE_NAME}" \
    --tags "Key=Class,Value=${CLUSTER_NAME}" "Key=Purpose,Value=trn-course-pcs-login" >/dev/null
  echo "    created instance profile ${PROFILE_NAME}"
fi

# Add the role to the instance profile (idempotent: already-in is tolerated).
if err=$(aws iam add-role-to-instance-profile \
      --instance-profile-name "${PROFILE_NAME}" --role-name "${ROLE_NAME}" 2>&1); then
  echo "    added role to instance profile"
else
  if grep -qiE 'LimitExceeded|already' <<<"${err}"; then
    echo "    role already attached to instance profile"
  else
    echo "${err}" >&2
    exit 1
  fi
fi

PROFILE_ARN=$(aws iam get-instance-profile --instance-profile-name "${PROFILE_NAME}" \
  --query 'InstanceProfile.Arn' --output text)
echo "    instance profile ARN=${PROFILE_ARN}"

# ============================================================================
# 3. Resolve the PCS sample Ubuntu 24.04 base AMI from SSM
# ============================================================================
# Same base AMI as the compute node group (dlami-base-ubuntu2404, x86_64). It
# ships the AWS PCS software + a PCS-compatible Slurm, so the login bootstrap's
# installer step is usually a no-op skip. Ubuntu 24.04 / Python 3.12 matches the
# parent kit's target.
SSM_AMI_PARAM="/aws/service/pcs/ami/dlami-base-ubuntu2404/x86_64/latest/ami-id"
echo "==> resolving PCS AMI from SSM ${SSM_AMI_PARAM}"
PCS_AMI=$(aws ssm get-parameter --region "${REGION}" \
  --name "${SSM_AMI_PARAM}" --query 'Parameter.Value' --output text 2>/dev/null || echo "")
[[ "${PCS_AMI}" =~ ^ami-[0-9a-f]+$ ]] || {
  echo "    ERROR: could not resolve a PCS AMI from ${SSM_AMI_PARAM} in ${REGION} (got '${PCS_AMI}')" >&2
  exit 1
}
echo "    PCS AMI=${PCS_AMI}"

# ============================================================================
# 4. Render the login setup script (substitute placeholders on a TEMP COPY)
# ============================================================================
# The source bootstrap/login-node-setup.sh is NEVER mutated. We sed-replace each
# line-anchored placeholder assignment in a temp copy. That rendered copy is NOT
# inlined as UserData: at ~24 KB it exceeds EC2's 16 KB raw user-data limit
# (live symptom: "Encoded User data is limited to 25600 bytes"). Instead it is
# staged to S3 (section 5) and run-instances is handed a tiny bootstrap that
# fetches + runs it — mirroring how the parent kit's scripts/deploy.sh stages
# its bootstrap scripts to S3.
#
# Assumption: the substituted values (ARN, private IP, port, region, bucket
# name, fs-id, wall-time, integer) contain no sed metacharacters for the '|'
# delimiter or '&' in the replacement — true for all AWS ids and the accepted
# input formats validated above.
RENDERED=$(mktemp)
# The tiny fetch-and-run UserData built in section 5; declared empty here so the
# single EXIT trap can clean up BOTH temp files safely under `set -u`.
BOOTSTRAP_USERDATA=""
# Remove both temp files on exit. Single-quoted so the vars expand at trap time
# (not registration time), catching the bootstrap file created later too.
trap 'rm -f "${RENDERED}" "${BOOTSTRAP_USERDATA}"' EXIT
sed -e "s|^PCS_SECRET_ARN=.*|PCS_SECRET_ARN=\"${SECRET_ARN}\"|" \
    -e "s|^SLURMCTLD_IP=.*|SLURMCTLD_IP=\"${SLURMCTLD_IP}\"|" \
    -e "s|^SLURMCTLD_PORT=.*|SLURMCTLD_PORT=\"${SLURMCTLD_PORT}\"|" \
    -e "s|^AWS_REGION=.*|AWS_REGION=\"${REGION}\"|" \
    -e "s|^STAGING_BUCKET=.*|STAGING_BUCKET=\"${STAGING_BUCKET}\"|" \
    -e "s|^STUDENT_COUNT=.*|STUDENT_COUNT=\"${STUDENT_COUNT}\"|" \
    -e "s|^EFS_FS_ID=.*|EFS_FS_ID=\"${EFS_ID}\"|" \
    -e "s|^MAX_WALL_TIME=.*|MAX_WALL_TIME=\"${MAX_WALL_TIME}\"|" \
    -e "s|^MAX_CONCURRENT_JOBS_PER_USER=.*|MAX_CONCURRENT_JOBS_PER_USER=\"${MAX_CONCURRENT_JOBS_PER_USER}\"|" \
    -e "s|^SLURM_VERSION=.*|SLURM_VERSION=\"${SLURM_VERSION}\"|" \
    "${USERDATA_FILE}" > "${RENDERED}"
echo "==> rendered login setup script to ${RENDERED}"

# ============================================================================
# 5. Stage the rendered setup script to S3 + build a tiny bootstrap UserData
# ============================================================================
# EC2 caps raw user-data at 16 KB; the rendered login-node-setup.sh is ~24 KB,
# so it cannot be inlined (live symptom: "Encoded User data is limited to 25600
# bytes"). Mirroring scripts/deploy.sh, we create/reuse a per-cluster boot
# bucket, upload the rendered script, and make the actual UserData a
# few-hundred-byte script that `aws s3 cp`s the object down and runs it. The
# login node's instance role already carries AmazonS3ReadOnlyAccess, so it can
# read the object at first boot.
#
# S3 bucket names must be lowercase, but PCS cluster names may contain uppercase
# (pattern ^[A-Za-z]...), so the cluster-name segment is lowercased. ACCOUNT_ID
# was captured by the get-caller-identity call in AWS-side validation above.
CLUSTER_NAME_LC="$(printf '%s' "${CLUSTER_NAME}" | tr '[:upper:]' '[:lower:]')"
BOOT_BUCKET="${CLUSTER_NAME_LC}-${ACCOUNT_ID}-${REGION}-login-boot"
echo "==> preparing login boot bucket s3://${BOOT_BUCKET}"
if ! aws s3api head-bucket --bucket "${BOOT_BUCKET}" --region "${REGION}" 2>/dev/null; then
  # us-east-1 rejects a LocationConstraint; every other region requires one.
  # This kit only allows sa-east-1/us-east-2, so the else-branch is the normal
  # path, but the guard keeps the create correct everywhere.
  if [[ "${REGION}" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "${BOOT_BUCKET}" --region "${REGION}" >/dev/null
  else
    aws s3api create-bucket \
      --bucket "${BOOT_BUCKET}" --region "${REGION}" \
      --create-bucket-configuration LocationConstraint="${REGION}" >/dev/null
  fi
  aws s3api put-public-access-block --bucket "${BOOT_BUCKET}" --public-access-block-configuration \
    'BlockPublicAcls=true,BlockPublicPolicy=true,IgnorePublicAcls=true,RestrictPublicBuckets=true'
  aws s3api put-bucket-encryption --bucket "${BOOT_BUCKET}" --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  aws s3api put-bucket-tagging --bucket "${BOOT_BUCKET}" \
    --tagging "TagSet=[{Key=Class,Value=${CLUSTER_NAME}},{Key=Purpose,Value=trn-course-pcs-login}]"
  echo "    created ${BOOT_BUCKET}"
else
  echo "    reusing ${BOOT_BUCKET}"
fi

# Upload the rendered setup script under a timestamped key so a re-run does not
# clobber a prior copy.
BOOT_KEY="bootstrap/login-node-setup-$(date +%Y%m%d-%H%M%S).sh"
aws s3 cp --region "${REGION}" "${RENDERED}" "s3://${BOOT_BUCKET}/${BOOT_KEY}"
echo "    staged rendered setup script to s3://${BOOT_BUCKET}/${BOOT_KEY}"

# Build the tiny fetch-and-run UserData (a few hundred bytes — safely under the
# 16 KB limit). It logs to /var/log/trn-course-pcs-login-bootstrap.log, retries
# the download a few times, then runs the real setup script (which in turn logs
# to /var/log/trn-course-pcs-login-setup.log). The bucket/key/region expand now;
# the loop counter (\$i) and its arithmetic are escaped so they stay literal in
# the generated script.
BOOTSTRAP_USERDATA=$(mktemp)
cat > "${BOOTSTRAP_USERDATA}" <<EOF
#!/bin/bash
set -euo pipefail
exec > >(tee -a /var/log/trn-course-pcs-login-bootstrap.log) 2>&1
echo "[trn-course-pcs] fetching login-node-setup from s3://${BOOT_BUCKET}/${BOOT_KEY}"
for i in 1 2 3 4 5; do
  aws s3 cp "s3://${BOOT_BUCKET}/${BOOT_KEY}" /root/login-node-setup.sh --region ${REGION} && break
  echo "retry \$i: s3 cp failed"; sleep \$((i*10))
done
chmod +x /root/login-node-setup.sh
bash /root/login-node-setup.sh
EOF
echo "==> built tiny bootstrap UserData ($(wc -c < "${BOOTSTRAP_USERDATA}") bytes) at ${BOOTSTRAP_USERDATA}"

# ============================================================================
# 6. Launch (or reuse) the login node
# ============================================================================
# Idempotency: reuse an existing pending/running/stopped instance tagged for
# this cluster's login role rather than launching a duplicate.
echo "==> checking for an existing login node"
EXISTING_INSTANCE=$(aws ec2 describe-instances --region "${REGION}" \
  --filters "Name=tag:Name,Values=${LOGIN_NODE_NAME}" \
            "Name=tag:Purpose,Values=trn-course-pcs-login" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || echo "")

if [[ -n "${EXISTING_INSTANCE}" && "${EXISTING_INSTANCE}" != "None" ]]; then
  INSTANCE_ID=$(awk '{print $1}' <<<"${EXISTING_INSTANCE}")
  echo "    reusing existing login node ${INSTANCE_ID} (skipping run-instances)"
else
  # IMDSv2 required + a low hop limit: the login node is multiuser, so this
  # (together with the bootstrap's iptables owner-match rule) limits students'
  # ability to borrow the instance profile via the metadata service.
  METADATA_OPTS="HttpTokens=required,HttpPutResponseHopLimit=2,HttpEndpoint=enabled"
  TAG_SPEC="ResourceType=instance,Tags=[{Key=Name,Value=${LOGIN_NODE_NAME}},{Key=Class,Value=${CLUSTER_NAME}},{Key=Purpose,Value=trn-course-pcs-login}]"

  # Associate a public IP only when the subnet is public; otherwise rely on SSM.
  RUN_EXTRA=()
  if [[ "${SUBNET_PUBLIC}" == "True" ]]; then
    RUN_EXTRA+=(--associate-public-ip-address)
    echo "    subnet is public: will associate a public IP"
  else
    RUN_EXTRA+=(--no-associate-public-ip-address)
    echo "    subnet is private: no public IP (use SSM Session Manager to connect)"
  fi

  # IAM is eventually consistent: a freshly created instance profile can be
  # briefly invisible to EC2, surfacing as "Invalid IAM Instance Profile ARN" /
  # "iamInstanceProfile.arn is invalid" from run-instances (observed live; a
  # re-run ~25s later succeeded). Retry with linear backoff on exactly that
  # error and fail immediately on anything else, mirroring deploy-pcs.sh's
  # create-compute-node-group retry. `2>&1` folds stderr into the captured value
  # so a success yields the instance id and a failure yields the error text.
  echo "==> launching login node (${LOGIN_INSTANCE_TYPE}, on-demand, IMDSv2 required)"
  attempt=1; max_attempts=6
  while :; do
    if out=$(aws ec2 run-instances --region "${REGION}" \
          --image-id "${PCS_AMI}" \
          --instance-type "${LOGIN_INSTANCE_TYPE}" \
          --key-name "${KEY_NAME}" \
          --subnet-id "${SUBNET_ID}" \
          --security-group-ids "${LOGIN_SG_ID}" "${CLUSTER_SG}" \
          --iam-instance-profile "Arn=${PROFILE_ARN}" \
          --metadata-options "${METADATA_OPTS}" \
          --user-data "file://${BOOTSTRAP_USERDATA}" \
          --tag-specifications "${TAG_SPEC}" \
          "${RUN_EXTRA[@]}" \
          --query 'Instances[0].InstanceId' --output text 2>&1); then
      INSTANCE_ID="${out}"
      echo "    launched ${INSTANCE_ID}"
      break
    fi
    if grep -qiE 'Invalid IAM Instance Profile ARN|iamInstanceProfile\.arn is invalid' <<<"${out}" && (( attempt < max_attempts )); then
      echo "    WARN: IAM instance profile not yet consistent (attempt ${attempt}/${max_attempts}); retrying in $(( attempt * 10 ))s..." >&2
      sleep $(( attempt * 10 ))
      (( attempt++ ))
      continue
    fi
    echo "${out}" >&2
    exit 1
  done
fi

echo "==> waiting for ${INSTANCE_ID} to reach running"
aws ec2 wait instance-running --region "${REGION}" --instance-ids "${INSTANCE_ID}" || {
  echo "    WARNING: wait instance-running did not confirm; check the console" >&2
}

PUBLIC_IP=$(aws ec2 describe-instances --region "${REGION}" --instance-ids "${INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text 2>/dev/null || echo "None")
PRIVATE_IP=$(aws ec2 describe-instances --region "${REGION}" --instance-ids "${INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text 2>/dev/null || echo "None")

# ============================================================================
# 7. Summary banner
# ============================================================================
echo ""
echo "============================================================"
echo "AWS PCS login node deploy complete (standalone flow; NOT yet live-validated)."
echo "  Cluster:        ${CLUSTER_NAME} (id ${CLUSTER_ID}, status ${CLUSTER_STATUS})"
echo "  Region:         ${REGION}"
echo "  Login node:     ${INSTANCE_ID} (${LOGIN_INSTANCE_TYPE})"
echo "  Public IP:      ${PUBLIC_IP}"
echo "  Private IP:     ${PRIVATE_IP}"
echo "  Login SG:       ${LOGIN_SG_ID} (TCP/22 from: ${ssh_cidr_ranges[*]})"
echo "  Cluster SG:     ${CLUSTER_SG} (attached so the node reaches slurmctld)"
echo "  slurmctld:      ${SLURMCTLD_IP}:${SLURMCTLD_PORT}"
echo "  IAM role:       ${ROLE_NAME} (instance profile ${PROFILE_ARN})"
echo "  Secret access:  scoped to ${SECRET_ARN}"
echo "  IMDS:           v2 required, hop-limit 2 (+ bootstrap iptables owner-match)"
echo "  Boot script:    staged to s3://${BOOT_BUCKET}/${BOOT_KEY} (fetched + run at first boot;"
echo "                  full ~24 KB setup script exceeds EC2's 16 KB user-data limit)"
echo "  EFS /shared:    ${EFS_ID:-<none: expects Phase-4 EFS or pre-mounted /shared>}"
echo "  Roster source:  ${STAGING_BUCKET:+s3://${STAGING_BUCKET}/roster/roster.json}"
echo "                  ${STAGING_BUCKET:-/shared/etc/passwd.roster (Phase-4 EFS)}"
echo "  Students:       ${STUDENT_COUNT:-<unset>}"
echo "  Per-student:    wall=${MAX_WALL_TIME} concurrent-jobs=${MAX_CONCURRENT_JOBS_PER_USER}"
echo "                  (NO gres/TRES limits — neuroncore is not a TRES on PCS; see ../docs/design.md Phase 2)"
echo ""
echo "Next steps:"
if [[ "${PUBLIC_IP}" != "None" && -n "${PUBLIC_IP}" ]]; then
  echo "  1. SSH as the admin sudoer:  ssh -i <key> ubuntu@${PUBLIC_IP}"
else
  echo "  1. Private subnet: connect via SSM Session Manager (aws ssm start-session --target ${INSTANCE_ID})"
fi
echo "  2. Watch first-boot logs:    sudo tail -f /var/log/trn-course-pcs-login-bootstrap.log  # S3 fetch of the setup script"
echo "                               sudo tail -f /var/log/trn-course-pcs-login-setup.log      # the setup script itself"
echo "  3. Confirm the cluster join:  sinfo   (should list the PCS partitions, e.g. 'nki')"
echo "  4. Students SSH in with their per-student key from the manifest and 'sbatch' to '${SLURMCTLD_IP:+nki}'."
echo "============================================================"
