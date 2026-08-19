#!/usr/bin/env bash
# deploy-pcs.sh — Trainium Course Cluster, AWS PCS (Parallel Computing Service)
# variant. Stands up a Slurm cluster whose compute fleet is a trn2 ML Capacity
# Block, using AWS PCS instead of AWS ParallelCluster.
#
# This is the PCS sibling of scripts/deploy.sh (the ParallelCluster deploy) and
# deliberately mirrors its style: `set -euo pipefail`, flag parsing, local +
# AWS-side validation, clear `==>` progress echoes, idempotent re-runs, and a
# summary banner. It does NOT touch the ParallelCluster kit — it only calls
# `aws ec2`, `aws iam`, `aws ssm`, and `aws pcs`.
#
# ----------------------------------------------------------------------------
# PROVEN core (empirically validated live via the AWS CLI, 2026):
#   PCS launches a trn2.3xlarge from a Trainium ML Capacity Block even though
#   the PCS docs list Capacity Blocks as P6/P5/P4d only. Evidence: instance
#   i-04fdfe05274edb571 (trn2.3xlarge, InstanceLifecycle=capacity-block) came
#   up in cr-0e168cd22e5919f69 under PCS management. See ../README.md.
#
# This script reproduces that proven sequence:
#   1. Validate region + the Capacity Block (state / AZ / instance type / size).
#   2. Create/reuse a self-referencing security group (all traffic within
#      itself; all egress — the SG default).
#   3. Create/reuse an IAM role whose NAME STARTS WITH `AWSPCS` (PCS rejects a
#      non-AWSPCS role with "The role ARN is invalid"), trusting ec2, with the
#      4 managed policies attached, plus a same-named instance profile.
#   4. Resolve the PCS sample AMI from SSM.
#   5. Create/reuse an EFS filesystem (encrypted, generalPurpose, elastic) with
#      a mount target in the compute subnet on the cluster SG, so /shared can be
#      NFS-mounted by the compute nodes. Created BEFORE the launch template
#      because the filesystem id is baked into the UserData.
#   6. Create an EC2 launch template: ImageId, InstanceType,
#      InstanceMarketOptions.MarketType=capacity-block,
#      CapacityReservationSpecification -> the CB id, the SG, and base64
#      UserData = the Neuron install script (../bootstrap/neuron-userdata.sh),
#      rendered with the EFS filesystem id + region injected.
#   7. Create the PCS cluster: SLURM 25.11 (24.11 is EOL), size SMALL,
#      networking = {subnet, SG}, managed accounting mode STANDARD.
#   8. Create the PCS compute node group: purchaseOption CAPACITY_BLOCK,
#      the custom launch template, the AWSPCS instance profile, subnet in the
#      CB AZ, static scaling (min==max), instanceConfigs = the trn2 type.
#   9. Create the PCS queue `nki` bound to the compute node group.
#
# ----------------------------------------------------------------------------
# SCOPE / FOUNDATION NOTE. This script reproduces the PROVEN core plus the EFS
# /shared filesystem (Phase 4). The login node (student SSH + per-student POSIX
# users + sacctmgr QoS), the NeuronCore GRES wiring, and the budget/kill-switch
# + manifest automations (reused from the parent ParallelCluster kit) remain
# documented follow-ups — see ../docs/design.md "OPEN ITEMS". --student-count
# and --alert-email are accepted now so the CLI contract is stable, and are
# echoed in the banner, but are not yet wired to live resources here.
#
# Idempotent: safe to re-run. SG / IAM / launch-template / cluster / node-group
# / queue creation each detect an existing resource and reuse it.

set -euo pipefail

# ============================================================================
# CLI parsing
# ============================================================================
usage() {
  cat >&2 <<EOF
usage: $0 [options]

Required:
  --cluster-name NAME              PCS cluster name. [A-Za-z][A-Za-z0-9-]{2,40}
  --region REGION                  only sa-east-1 or us-east-2 are supported
  --capacity-reservation-id CR_ID  the trn2 ML Capacity Block, format cr-XXXX
  --availability-zone AZ           must match the Capacity Block's AZ
  --subnet-id SUBNET_ID            private subnet in the CB AZ (subnet-XXXX)
  --vpc-id VPC_ID                  VPC the subnet lives in (vpc-XXXX)
  --student-count N                1..500 (recorded for the follow-up login node)
  --alert-email EMAIL              budget alert destination (follow-up wiring)

Common:
  --compute-instance-type TYPE     default trn2.3xlarge
  --compute-node-count N           default 1 (must be <= Capacity Block size)
  --efs-id FS_ID                   reuse an existing EFS filesystem (fs-XXXX) for
                                   /shared instead of creating/reusing one by tag
  --dry-run                        run all validation, then stop before mutating
  -h|--help                        show this help
EOF
  exit 2
}

# Defaults
COMPUTE_INSTANCE_TYPE=trn2.3xlarge
COMPUTE_NODE_COUNT=1
EFS_ID=""            # empty => create (or reuse-by-tag) an EFS; else reuse this fs-id
DRY_RUN=false
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The Slurm scheduler version PCS provisions. 25.11 is current; 24.11 is EOL
# and MUST NOT be used (PCS also gates the per-CNG scale-down idle time on
# >= 25.11). Kept as a constant so the proven value is single-sourced.
SLURM_VERSION="25.11"

# Fixed short names for the compute node group and queue. Both PCS names are
# capped at 25 chars and must start with a letter (pattern
# ^[A-Za-z][A-Za-z0-9-]+), so they are NOT derived from --cluster-name (which
# may be up to 40 chars). The queue name `nki` is the Slurm partition students
# submit to (queue == partition), matching the ParallelCluster kit's `nki`.
CNG_NAME="nki-cng"
QUEUE_NAME="nki"

CLUSTER_NAME=""; REGION=""; CR_ID=""; AZ=""; SUBNET_ID=""; VPC_ID=""
STUDENT_COUNT=""; ALERT_EMAIL=""

while (( $# )); do
  case "$1" in
    --cluster-name)            CLUSTER_NAME="$2"; shift 2;;
    --region)                  REGION="$2"; shift 2;;
    --capacity-reservation-id) CR_ID="$2"; shift 2;;
    --availability-zone)       AZ="$2"; shift 2;;
    --subnet-id)               SUBNET_ID="$2"; shift 2;;
    --vpc-id)                  VPC_ID="$2"; shift 2;;
    --student-count)           STUDENT_COUNT="$2"; shift 2;;
    --alert-email)             ALERT_EMAIL="$2"; shift 2;;
    --compute-instance-type)   COMPUTE_INSTANCE_TYPE="$2"; shift 2;;
    --compute-node-count)      COMPUTE_NODE_COUNT="$2"; shift 2;;
    --efs-id)                  EFS_ID="$2"; shift 2;;
    --dry-run)                 DRY_RUN=true; shift 1;;
    -h|--help)                 usage;;
    *) echo "unknown arg: $1" >&2; usage;;
  esac
done

# ============================================================================
# Local validation (before any AWS call)
# ============================================================================
required_vars=(CLUSTER_NAME REGION CR_ID AZ SUBNET_ID VPC_ID STUDENT_COUNT ALERT_EMAIL)
missing=()
for var in "${required_vars[@]}"; do
  [[ -z "${!var}" ]] && missing+=("$var")
done
if (( ${#missing[@]} )); then
  echo "missing required flags: ${missing[*]}" >&2
  usage
fi

# PCS cluster name pattern (from the PCS API): starts with a letter, then
# letters/digits/hyphens, total 3..41 chars. We cap the tail at 40 to match the
# parent kit's convention.
[[ "${CLUSTER_NAME}" =~ ^[A-Za-z][A-Za-z0-9-]{2,40}$ ]] || {
  echo "cluster-name must match ^[A-Za-z][A-Za-z0-9-]{2,40}\$ (got '${CLUSTER_NAME}')" >&2
  exit 1
}
[[ "${CR_ID}" =~ ^cr-[0-9a-f]{8,17}$ ]] || {
  echo "capacity-reservation-id must look like cr-XXXXXXXX (got '${CR_ID}')" >&2
  exit 1
}
[[ "${SUBNET_ID}" =~ ^subnet-[0-9a-f]{8,17}$ ]] || {
  echo "subnet-id must look like subnet-XXXXXXXX (got '${SUBNET_ID}')" >&2
  exit 1
}
[[ "${VPC_ID}" =~ ^vpc-[0-9a-f]{8,17}$ ]] || {
  echo "vpc-id must look like vpc-XXXXXXXX (got '${VPC_ID}')" >&2
  exit 1
}
[[ "${STUDENT_COUNT}" =~ ^[0-9]+$ ]] && (( STUDENT_COUNT >= 1 && STUDENT_COUNT <= 500 )) || {
  echo "student-count must be an integer in [1, 500] (got '${STUDENT_COUNT}')" >&2
  exit 1
}
[[ "${COMPUTE_NODE_COUNT}" =~ ^[0-9]+$ ]] && (( COMPUTE_NODE_COUNT >= 1 )) || {
  echo "compute-node-count must be a positive integer (got '${COMPUTE_NODE_COUNT}')" >&2
  exit 1
}

# --efs-id is OPTIONAL. When supplied it must look like an EFS filesystem id and
# is reused as-is; when empty we create (or reuse-by-tag) an EFS for /shared.
if [[ -n "${EFS_ID}" ]]; then
  [[ "${EFS_ID}" =~ ^fs-[0-9a-f]{8,17}$ ]] || {
    echo "efs-id must look like fs-XXXXXXXX (got '${EFS_ID}')" >&2
    exit 1
  }
fi

# ---------------------------------------------------------------------------
# Region constraint. Same allow-list as the ParallelCluster kit
# (scripts/deploy.sh): sa-east-1 (São Paulo, the trn2.3xlarge MLCB home) and
# us-east-2 (Ohio, trn2.48xlarge). PCS itself is available in more regions, but
# the course kit pins these two for parity with the parent kit and the proven
# runs.
# ---------------------------------------------------------------------------
case "${REGION}" in
  sa-east-1|us-east-2) : ;;
  *)
    echo "ERROR: --region ${REGION} is not supported by this kit." >&2
    echo "  Only sa-east-1 and us-east-2 are supported (parity with the PCluster kit)." >&2
    exit 1
    ;;
esac

for c in aws jq base64; do
  command -v "$c" >/dev/null || { echo "${c} not on PATH" >&2; exit 1; }
done

# The Neuron user-data script that becomes the launch template's UserData.
USERDATA_FILE="${REPO_DIR}/bootstrap/neuron-userdata.sh"
[[ -f "${USERDATA_FILE}" ]] || {
  echo "ERROR: user-data script not found at ${USERDATA_FILE}" >&2
  exit 1
}

# Derived resource names.
SG_NAME="AWSPCS-${CLUSTER_NAME}-cluster-sg"   # SG name is cosmetic; kept prefixed for grouping
ROLE_NAME="AWSPCS-${CLUSTER_NAME}-compute"     # MUST start with AWSPCS (PCS requirement)
PROFILE_NAME="${ROLE_NAME}"                    # instance profile shares the role name
LT_NAME="AWSPCS-${CLUSTER_NAME}-lt"
EFS_CREATION_TOKEN="${CLUSTER_NAME}-shared-efs" # stable token => idempotent create-file-system

# Per-node NeuronCore count, derived from the compute shape (trn2.3xlarge=4,
# trn2.48xlarge=16; default 4 as a sane fallback). Mirrors the parent
# ParallelCluster kit's derivation in scripts/deploy.sh, but on PCS this value
# feeds the node **Feature** `neuroncores<N>` at CNG creation (step 7), NOT a
# Slurm `Gres=neuroncore:N` — `Gres`/`GresTypes` are in NEITHER the PCS cluster
# nor CNG custom-settings allow-lists, so NeuronCore selection on PCS is
# node-level (via --constraint) only. See ../docs/design.md Phase 2.
case "${COMPUTE_INSTANCE_TYPE}" in
  trn2.48xlarge) PER_NODE_NEURONCORES=16 ;;
  trn2.3xlarge)  PER_NODE_NEURONCORES=4  ;;
  *)             PER_NODE_NEURONCORES=4  ;;
esac

# ============================================================================
# AWS-side validation
# ============================================================================
echo "==> validating AWS context"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "    account=${ACCOUNT_ID} region=${REGION}"

# ---------------------------------------------------------------------------
# Capacity Block validation. The DEPLOYING identity needs
# ec2:DescribeCapacityReservations for this call; PCS itself additionally needs
# ec2:DescribeCapacityReservations, ec2:DescribeCapacityBlocks, and
# ec2:DescribeCapacityBlockStatus to manage a CAPACITY_BLOCK-backed node group.
# See ../docs/design.md for the full IAM note.
# ---------------------------------------------------------------------------
echo "==> validating Capacity Block ${CR_ID}"
cr_json=$(aws ec2 describe-capacity-reservations \
  --region "${REGION}" \
  --capacity-reservation-ids "${CR_ID}" \
  --query 'CapacityReservations[0].{state:State,az:AvailabilityZone,type:InstanceType,count:TotalInstanceCount,rtype:ReservationType,end:EndDate}' \
  --output json 2>/dev/null || echo '{}')
cr_state=$(echo "${cr_json}" | jq -r '.state // "unknown"')
cr_az=$(echo "${cr_json}" | jq -r '.az // "unknown"')
cr_type=$(echo "${cr_json}" | jq -r '.type // "unknown"')
cr_count=$(echo "${cr_json}" | jq -r '.count // "0"')
cr_rtype=$(echo "${cr_json}" | jq -r '.rtype // "unknown"')
cr_end=$(echo "${cr_json}" | jq -r '.end // empty')
echo "    state=${cr_state} az=${cr_az} type=${cr_type} count=${cr_count} reservationType=${cr_rtype} end=${cr_end:-<none>}"

if [[ "${cr_state}" == "unknown" ]]; then
  echo "    ERROR: could not describe Capacity Block ${CR_ID} in ${REGION}." >&2
  echo "      Check the id/region and that the caller has ec2:DescribeCapacityReservations." >&2
  exit 1
fi
if [[ "${cr_state}" != "active" && "${cr_state}" != "scheduled" && "${cr_state}" != "payment-pending" ]]; then
  echo "    ERROR: Capacity Block is in state ${cr_state}; expected active/scheduled/payment-pending." >&2
  exit 1
fi
if [[ "${cr_az}" != "${AZ}" ]]; then
  echo "    ERROR: --availability-zone ${AZ} does not match the CB AZ ${cr_az}." >&2
  echo "      The PCS compute node group subnet MUST be in the CB's AZ." >&2
  exit 1
fi
if [[ "${cr_type}" != "${COMPUTE_INSTANCE_TYPE}" ]]; then
  echo "    ERROR: --compute-instance-type ${COMPUTE_INSTANCE_TYPE} does not match CB type ${cr_type}." >&2
  exit 1
fi
if [[ "${cr_rtype}" != "capacity-block" ]]; then
  echo "    WARNING: reservation type is '${cr_rtype}', expected 'capacity-block'." >&2
  echo "      Proceeding, but purchaseOption=CAPACITY_BLOCK expects a Capacity Block reservation." >&2
fi
if (( COMPUTE_NODE_COUNT > cr_count )); then
  echo "    ERROR: --compute-node-count ${COMPUTE_NODE_COUNT} exceeds CB size ${cr_count}." >&2
  exit 1
fi

# Confirm the subnet is really in the CB AZ (cheap guard against a mismatched
# --subnet-id that would otherwise fail deep inside node-group creation).
echo "==> validating subnet ${SUBNET_ID} is in ${AZ}"
subnet_az=$(aws ec2 describe-subnets --region "${REGION}" --subnet-ids "${SUBNET_ID}" \
  --query 'Subnets[0].AvailabilityZone' --output text 2>/dev/null || echo "unknown")
subnet_vpc=$(aws ec2 describe-subnets --region "${REGION}" --subnet-ids "${SUBNET_ID}" \
  --query 'Subnets[0].VpcId' --output text 2>/dev/null || echo "unknown")
echo "    subnet az=${subnet_az} vpc=${subnet_vpc}"
if [[ "${subnet_az}" != "${AZ}" ]]; then
  echo "    ERROR: subnet ${SUBNET_ID} is in ${subnet_az}, not the CB AZ ${AZ}." >&2
  exit 1
fi
if [[ "${subnet_vpc}" != "${VPC_ID}" ]]; then
  echo "    ERROR: subnet ${SUBNET_ID} is in ${subnet_vpc}, not --vpc-id ${VPC_ID}." >&2
  exit 1
fi

if $DRY_RUN; then
  echo "==> dry-run: validation passed; stopping before creating any resources"
  exit 0
fi

# ============================================================================
# 1. Security group (self-referencing; all traffic within itself; all egress)
# ============================================================================
# PCS compute nodes + the cluster controller talk to each other over the full
# port range (slurmctld/slurmd/munge etc.), so the cluster SG allows all
# traffic FROM ITSELF and (by SG default) all egress. No inbound from the
# world. Reused across re-runs by name.
echo "==> ensuring security group ${SG_NAME}"
SG_ID=$(aws ec2 describe-security-groups --region "${REGION}" \
  --filters "Name=group-name,Values=${SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")

if [[ "${SG_ID}" == "None" || -z "${SG_ID}" ]]; then
  SG_ID=$(aws ec2 create-security-group --region "${REGION}" \
    --group-name "${SG_NAME}" \
    --description "AWS PCS cluster SG for ${CLUSTER_NAME} (self-referencing; all egress)" \
    --vpc-id "${VPC_ID}" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Class,Value=${CLUSTER_NAME}},{Key=Purpose,Value=trn-course-pcs}]" \
    --query 'GroupId' --output text)
  echo "    created ${SG_ID}"
else
  echo "    reusing ${SG_ID}"
fi

# Self-referencing all-traffic ingress. Idempotent: an existing rule returns
# InvalidPermission.Duplicate, which we treat as success.
echo "==> ensuring self-referencing ingress on ${SG_ID}"
if err=$(aws ec2 authorize-security-group-ingress --region "${REGION}" \
      --group-id "${SG_ID}" \
      --ip-permissions "IpProtocol=-1,UserIdGroupPairs=[{GroupId=${SG_ID}}]" 2>&1); then
  echo "    added self-referencing all-traffic ingress"
else
  if grep -qi 'Duplicate' <<<"${err}"; then
    echo "    self-referencing ingress already present"
  else
    echo "${err}" >&2
    exit 1
  fi
fi
# Egress: SGs are created with a default allow-all egress rule, so no action.

# ============================================================================
# 2. IAM role (name MUST start with AWSPCS) + instance profile + policies
# ============================================================================
# CRITICAL: PCS validates the compute node group's instance-profile role and
# REJECTS a role whose name does not start with `AWSPCS` ("The role ARN is
# invalid"). The role trusts ec2.amazonaws.com and carries the 4 managed
# policies below. IAM is global (no --region).
MANAGED_POLICIES=(
  "arn:aws:iam::aws:policy/AWSPCSComputeNodePolicy"
  "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
  "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
)
TRUST_DOC='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

echo "==> ensuring IAM role ${ROLE_NAME} (must start with AWSPCS)"
if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  echo "    role already exists"
else
  aws iam create-role --role-name "${ROLE_NAME}" \
    --assume-role-policy-document "${TRUST_DOC}" \
    --description "AWS PCS compute node role for ${CLUSTER_NAME}" \
    --tags "Key=Class,Value=${CLUSTER_NAME}" "Key=Purpose,Value=trn-course-pcs" >/dev/null
  echo "    created role ${ROLE_NAME}"
fi

for pol in "${MANAGED_POLICIES[@]}"; do
  echo "    attaching ${pol##*/}"
  aws iam attach-role-policy --role-name "${ROLE_NAME}" --policy-arn "${pol}"
done

echo "==> ensuring instance profile ${PROFILE_NAME}"
if aws iam get-instance-profile --instance-profile-name "${PROFILE_NAME}" >/dev/null 2>&1; then
  echo "    instance profile already exists"
else
  aws iam create-instance-profile --instance-profile-name "${PROFILE_NAME}" \
    --tags "Key=Class,Value=${CLUSTER_NAME}" "Key=Purpose,Value=trn-course-pcs" >/dev/null
  echo "    created instance profile ${PROFILE_NAME}"
fi

# Add the role to the instance profile (idempotent: LimitExceeded / already-in
# is tolerated). An instance profile can hold exactly one role.
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
# 3. Resolve the PCS sample AMI from SSM
# ============================================================================
# PCS publishes sample DLAMI-base AMIs under /aws/service/pcs/ami/... . The
# ubuntu2404 x86_64 base AMI carries the PCS agent (which handles Slurm
# registration) and matches the parent kit's ubuntu2404 / Python 3.12 target.
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
# 4. EFS filesystem + mount target for /shared
# ============================================================================
# Students need a shared home + work area (and the reused job templates expect
# /shared). There is no head node on PCS, so /shared is mounted on every compute
# node by the launch-template UserData (../bootstrap/neuron-userdata.sh) — which
# means the filesystem id must exist BEFORE the launch template is rendered
# (step 5). We therefore create/reuse the EFS here.
#
# Idempotent: if --efs-id was supplied we reuse it as-is; otherwise we look for
# an existing filesystem tagged Class=${CLUSTER_NAME} + Purpose=trn-course-pcs
# and reuse it, only creating a new one when none is found. A stable creation
# token additionally makes the create call itself safe under a re-run/race.
if [[ -n "${EFS_ID}" ]]; then
  echo "==> using caller-supplied EFS ${EFS_ID}"
else
  echo "==> ensuring EFS filesystem (tags Class=${CLUSTER_NAME}, Purpose=trn-course-pcs)"
  # describe-file-systems returns Tags per filesystem; filter client-side for one
  # carrying BOTH our Class and Purpose tags and not already being deleted.
  EFS_ID=$(aws efs describe-file-systems --region "${REGION}" \
    --query 'FileSystems[].{id:FileSystemId,state:LifeCycleState,tags:Tags}' \
    --output json 2>/dev/null \
    | jq -r --arg cls "${CLUSTER_NAME}" '
        [ .[]
          | select(.state != "deleting" and .state != "deleted")
          | select([.tags[] | select(.Key == "Class"   and .Value == $cls)] | length > 0)
          | select([.tags[] | select(.Key == "Purpose" and .Value == "trn-course-pcs")] | length > 0)
          | .id ] | first // empty' 2>/dev/null || echo "")
  if [[ -n "${EFS_ID}" ]]; then
    echo "    reusing ${EFS_ID}"
  else
    EFS_ID=$(aws efs create-file-system --region "${REGION}" \
      --creation-token "${EFS_CREATION_TOKEN}" \
      --encrypted \
      --performance-mode generalPurpose \
      --throughput-mode elastic \
      --tags "Key=Name,Value=${CLUSTER_NAME}" \
             "Key=Class,Value=${CLUSTER_NAME}" \
             "Key=Purpose,Value=trn-course-pcs" \
      --query 'FileSystemId' --output text)
    echo "    created ${EFS_ID}"
  fi
fi

# Wait for the filesystem to be 'available' before adding a mount target.
echo "==> waiting for EFS ${EFS_ID} to be available"
while :; do
  efs_state=$(aws efs describe-file-systems --region "${REGION}" \
    --file-system-id "${EFS_ID}" \
    --query 'FileSystems[0].LifeCycleState' --output text 2>/dev/null || echo "unknown")
  echo "    efs state=${efs_state}"
  case "${efs_state}" in
    available) break;;
    deleting|deleted|error|unknown)
      echo "    ERROR: EFS ${EFS_ID} reached terminal/unexpected state ${efs_state}" >&2
      exit 1;;
    *) sleep 10;;
  esac
done

# Mount target in the compute subnet, on the self-referencing cluster SG.
#
# NFS ingress: NO extra rule is needed. The cluster SG (${SG_ID}) already allows
# ALL traffic FROM ITSELF, and the compute nodes' launch template places them in
# ${SG_ID}; putting the mount target in that same SG means NFS/2049 from
# compute -> mount target is already permitted. The Phase-1 login node will also
# join ${SG_ID}, so it gets /shared for free. (The parent ParallelCluster kit
# needs a dedicated EFS SG with an explicit 2049 ingress rule; the PCS self-
# referencing SG makes that unnecessary here.)
#
# A filesystem has at most one mount target per AZ, and this kit is single-AZ
# (one subnet), so "already has a mount target" == done.
echo "==> ensuring EFS mount target in ${SUBNET_ID}"
mt_count=$(aws efs describe-mount-targets --region "${REGION}" \
  --file-system-id "${EFS_ID}" \
  --query 'length(MountTargets)' --output text 2>/dev/null || echo "0")
if [[ "${mt_count}" != "0" && "${mt_count}" != "None" ]]; then
  echo "    mount target already exists (count=${mt_count}); reusing"
else
  MT_ID=$(aws efs create-mount-target --region "${REGION}" \
    --file-system-id "${EFS_ID}" \
    --subnet-id "${SUBNET_ID}" \
    --security-groups "${SG_ID}" \
    --query 'MountTargetId' --output text)
  echo "    created mount target ${MT_ID}; waiting for it to be available"
  while :; do
    mt_state=$(aws efs describe-mount-targets --region "${REGION}" \
      --mount-target-id "${MT_ID}" \
      --query 'MountTargets[0].LifeCycleState' --output text 2>/dev/null || echo "unknown")
    echo "    mount target state=${mt_state}"
    case "${mt_state}" in
      available) break;;
      deleting|deleted|error|unknown)
        echo "    ERROR: mount target ${MT_ID} reached terminal/unexpected state ${mt_state}" >&2
        exit 1;;
      *) sleep 10;;
    esac
  done
fi
echo "    EFS ready: ${EFS_ID} (/shared is mounted by the compute-node UserData)"

# ============================================================================
# 5. Launch template (capacity-block market + CR target + SG + base64 UserData)
# ============================================================================
# Render the Neuron user-data with the EFS filesystem id + region injected,
# WITHOUT mutating the source file: sed the two placeholder assignments into a
# temp copy, then base64 that copy. `base64 | tr -d '\n'` is portable across
# macOS (no -w flag) and Linux (which would otherwise wrap at 76 cols).
echo "==> rendering + encoding user-data from ${USERDATA_FILE} (EFS_FS_ID=${EFS_ID}, region=${REGION})"
rendered_userdata=$(mktemp "${TMPDIR:-/tmp}/pcs-neuron-userdata.XXXXXX.sh")
sed -e "s|^EFS_FS_ID=.*|EFS_FS_ID=\"${EFS_ID}\"|" \
    -e "s|^EFS_REGION=.*|EFS_REGION=\"${REGION}\"|" \
    "${USERDATA_FILE}" > "${rendered_userdata}"
USER_DATA_B64=$(base64 < "${rendered_userdata}" | tr -d '\n')
rm -f "${rendered_userdata}"

# Build launch-template-data as JSON via jq so values are injected safely.
LT_DATA=$(jq -n \
  --arg ami "${PCS_AMI}" \
  --arg itype "${COMPUTE_INSTANCE_TYPE}" \
  --arg crid "${CR_ID}" \
  --arg sg "${SG_ID}" \
  --arg ud "${USER_DATA_B64}" \
  '{
     ImageId: $ami,
     InstanceType: $itype,
     InstanceMarketOptions: { MarketType: "capacity-block" },
     CapacityReservationSpecification: {
       CapacityReservationTarget: { CapacityReservationId: $crid }
     },
     SecurityGroupIds: [ $sg ],
     UserData: $ud
   }')

echo "==> ensuring launch template ${LT_NAME}"
LT_ID=$(aws ec2 describe-launch-templates --region "${REGION}" \
  --launch-template-names "${LT_NAME}" \
  --query 'LaunchTemplates[0].LaunchTemplateId' --output text 2>/dev/null || echo "None")

if [[ "${LT_ID}" == "None" || -z "${LT_ID}" ]]; then
  create_lt_json=$(aws ec2 create-launch-template --region "${REGION}" \
    --launch-template-name "${LT_NAME}" \
    --launch-template-data "${LT_DATA}" \
    --tag-specifications "ResourceType=launch-template,Tags=[{Key=Class,Value=${CLUSTER_NAME}},{Key=Purpose,Value=trn-course-pcs}]")
  LT_ID=$(echo "${create_lt_json}" | jq -r '.LaunchTemplate.LaunchTemplateId')
  LT_VERSION=$(echo "${create_lt_json}" | jq -r '.LaunchTemplate.LatestVersionNumber')
  echo "    created ${LT_ID} version ${LT_VERSION}"
else
  # Reuse: publish a new version so any user-data / AMI change is picked up,
  # and point the node group at that new version.
  new_ver_json=$(aws ec2 create-launch-template-version --region "${REGION}" \
    --launch-template-id "${LT_ID}" \
    --source-version '$Latest' \
    --launch-template-data "${LT_DATA}")
  LT_VERSION=$(echo "${new_ver_json}" | jq -r '.LaunchTemplateVersion.VersionNumber')
  echo "    reused ${LT_ID}; published version ${LT_VERSION}"
fi

# ============================================================================
# 6. PCS cluster (SLURM 25.11, size SMALL, managed accounting STANDARD)
# ============================================================================
# Managed accounting (accounting mode STANDARD) stands up Slurm accounting
# WITHOUT a self-managed database, which is what lets a follow-up login node
# run `sacctmgr` to set per-student QoS limits. See ../docs/design.md.
echo "==> ensuring PCS cluster ${CLUSTER_NAME}"
existing_cluster_status=$(aws pcs get-cluster --region "${REGION}" \
  --cluster-identifier "${CLUSTER_NAME}" \
  --query 'cluster.status' --output text 2>/dev/null || echo "MISSING")

if [[ "${existing_cluster_status}" == "MISSING" ]]; then
  # Slurm config on the cluster: managed accounting (mode=STANDARD) PLUS
  # AccountingStorageEnforce=associations,limits,qos so the login-node QoS
  # (MaxWall + MaxJobsPerUser, set via sacctmgr in Phases 1/3) is actually
  # ENFORCED. AccountingStorageEnforce IS in the PCS cluster custom-settings
  # allow-list (slurm-custom-settings-cluster). The whole --slurm-configuration
  # value is SINGLE-quoted because the enforce value contains commas and inner
  # double-quotes; single quotes make the shell pass exactly one literal arg
  # (no variable expansion is needed here). Member casing note: `accounting` is
  # lowercase (already proven working in this script) while `SlurmCustomSettings`
  # follows the AWS docs' casing — re-verify this mixed shorthand parses on the
  # first live run.
  #
  # DELIBERATELY OMITTED: AccountingStorageTRES=gres/neuroncore. That would need
  # a `neuroncore` Slurm GRES, and Gres/GresTypes are in NEITHER the cluster nor
  # the CNG PCS allow-lists — so only the base TRES plus wall-time/job-count QoS
  # limits are enforceable on PCS (no per-core tracking). See ../docs/design.md
  # Phase 2.
  aws pcs create-cluster --region "${REGION}" \
    --cluster-name "${CLUSTER_NAME}" \
    --scheduler "type=SLURM,version=${SLURM_VERSION}" \
    --size SMALL \
    --networking "subnetIds=${SUBNET_ID},securityGroupIds=${SG_ID}" \
    --slurm-configuration 'accounting={mode=STANDARD},SlurmCustomSettings=[{parameterName=AccountingStorageEnforce,parameterValue="associations,limits,qos"}]' \
    --tags "Class=${CLUSTER_NAME}" "Purpose=trn-course-pcs" >/dev/null
  echo "    create-cluster submitted"
else
  echo "    cluster already exists (status=${existing_cluster_status}); skipping create"
fi

CLUSTER_ID=$(aws pcs get-cluster --region "${REGION}" \
  --cluster-identifier "${CLUSTER_NAME}" --query 'cluster.id' --output text)
echo "    cluster id=${CLUSTER_ID}"

echo "==> waiting for cluster ACTIVE (can take several minutes)"
while :; do
  status=$(aws pcs get-cluster --region "${REGION}" \
    --cluster-identifier "${CLUSTER_ID}" --query 'cluster.status' --output text 2>/dev/null || echo "UNKNOWN")
  echo "    cluster status=${status}"
  case "${status}" in
    ACTIVE) break;;
    CREATE_FAILED|DELETE_IN_PROGRESS|DELETING|DELETED|UNKNOWN)
      echo "    ERROR: cluster reached terminal/failed status ${status}" >&2
      exit 1;;
    *) sleep 15;;
  esac
done

# ============================================================================
# 7. PCS compute node group (CAPACITY_BLOCK)
# ============================================================================
# purchaseOption CAPACITY_BLOCK + the custom launch template (which carries the
# capacity-block market option and CR target) + the AWSPCS instance profile.
# Static scaling for a Capacity Block: minInstanceCount == maxInstanceCount.
echo "==> ensuring compute node group ${CNG_NAME}"
existing_cng_status=$(aws pcs get-compute-node-group --region "${REGION}" \
  --cluster-identifier "${CLUSTER_ID}" \
  --compute-node-group-identifier "${CNG_NAME}" \
  --query 'computeNodeGroup.status' --output text 2>/dev/null || echo "MISSING")

if [[ "${existing_cng_status}" == "MISSING" ]]; then
  # NeuronCore selection on PCS (Phase 2). We advertise the node Feature
  # `neuron,neuroncores<N>` via SlurmCustomSettings so students select a
  # Trainium node with `--constraint=neuron` (or the more specific
  # `neuroncores4`/`neuroncores16`). This is the PCS SUBSTITUTE for the parent
  # ParallelCluster kit's per-node `Gres=neuroncore:N`: `Features` IS in the PCS
  # CNG custom-settings allow-list (slurm-custom-settings-cng) while
  # `Gres`/`GresTypes` are NOT — so this gives NODE-LEVEL selection only, with no
  # per-core scheduling isolation (the parent kit's per-core gres sharing is
  # unavailable on PCS). The comma inside the feature value is why that one arg
  # is single-quoted around the ${PER_NODE_NEURONCORES} splice:
  #   'SlurmCustomSettings=[{parameterName=Features,parameterValue="neuron,neuroncores'"${N}"'"}]'
  # -> literal SlurmCustomSettings=[{parameterName=Features,parameterValue="neuron,neuroncores4"}]
  # See ../docs/design.md Phase 2.
  #
  # IAM is eventually consistent: a freshly created role/instance profile can
  # be briefly invisible to PCS, which surfaces as "The role ARN is invalid".
  # Retry the create with backoff on exactly that error.
  attempt=1; max_attempts=6
  while :; do
    if err=$(aws pcs create-compute-node-group --region "${REGION}" \
          --cluster-identifier "${CLUSTER_ID}" \
          --compute-node-group-name "${CNG_NAME}" \
          --ami-id "${PCS_AMI}" \
          --subnet-ids "${SUBNET_ID}" \
          --purchase-option CAPACITY_BLOCK \
          --custom-launch-template "id=${LT_ID},version=${LT_VERSION}" \
          --iam-instance-profile-arn "${PROFILE_ARN}" \
          --scaling-configuration "minInstanceCount=${COMPUTE_NODE_COUNT},maxInstanceCount=${COMPUTE_NODE_COUNT}" \
          --instance-configs "instanceType=${COMPUTE_INSTANCE_TYPE}" \
          --slurm-configuration 'SlurmCustomSettings=[{parameterName=Features,parameterValue="neuron,neuroncores'"${PER_NODE_NEURONCORES}"'"}]' \
          --tags "Class=${CLUSTER_NAME}" "Purpose=trn-course-pcs" 2>&1); then
      echo "    create-compute-node-group submitted"
      break
    fi
    if grep -qiE 'role ARN is invalid|instance profile|not authorized to perform: iam' <<<"${err}" && (( attempt < max_attempts )); then
      echo "    WARN: IAM not yet consistent (attempt ${attempt}/${max_attempts}); retrying in $(( attempt * 10 ))s..." >&2
      sleep $(( attempt * 10 ))
      (( attempt++ ))
      continue
    fi
    echo "${err}" >&2
    exit 1
  done
else
  echo "    compute node group already exists (status=${existing_cng_status}); skipping create"
fi

CNG_ID=$(aws pcs get-compute-node-group --region "${REGION}" \
  --cluster-identifier "${CLUSTER_ID}" \
  --compute-node-group-identifier "${CNG_NAME}" \
  --query 'computeNodeGroup.id' --output text)
echo "    compute node group id=${CNG_ID}"

echo "==> waiting for compute node group ACTIVE"
while :; do
  status=$(aws pcs get-compute-node-group --region "${REGION}" \
    --cluster-identifier "${CLUSTER_ID}" \
    --compute-node-group-identifier "${CNG_ID}" \
    --query 'computeNodeGroup.status' --output text 2>/dev/null || echo "UNKNOWN")
  echo "    node group status=${status}"
  case "${status}" in
    ACTIVE) break;;
    CREATE_FAILED|DELETING|DELETED|UNKNOWN)
      echo "    ERROR: compute node group reached terminal/failed status ${status}" >&2
      exit 1;;
    *) sleep 15;;
  esac
done

# ============================================================================
# 8. PCS queue `nki` (queue == Slurm partition) bound to the node group
# ============================================================================
echo "==> ensuring queue ${QUEUE_NAME}"
existing_queue_status=$(aws pcs get-queue --region "${REGION}" \
  --cluster-identifier "${CLUSTER_ID}" \
  --queue-identifier "${QUEUE_NAME}" \
  --query 'queue.status' --output text 2>/dev/null || echo "MISSING")

if [[ "${existing_queue_status}" == "MISSING" ]]; then
  aws pcs create-queue --region "${REGION}" \
    --cluster-identifier "${CLUSTER_ID}" \
    --queue-name "${QUEUE_NAME}" \
    --compute-node-group-configurations "computeNodeGroupId=${CNG_ID}" \
    --tags "Class=${CLUSTER_NAME}" "Purpose=trn-course-pcs" >/dev/null
  echo "    create-queue submitted"
else
  echo "    queue already exists (status=${existing_queue_status}); skipping create"
fi

echo "==> waiting for queue ACTIVE"
while :; do
  status=$(aws pcs get-queue --region "${REGION}" \
    --cluster-identifier "${CLUSTER_ID}" \
    --queue-identifier "${QUEUE_NAME}" \
    --query 'queue.status' --output text 2>/dev/null || echo "UNKNOWN")
  echo "    queue status=${status}"
  case "${status}" in
    ACTIVE) break;;
    CREATE_FAILED|DELETING|DELETED|UNKNOWN)
      echo "    ERROR: queue reached terminal/failed status ${status}" >&2
      exit 1;;
    *) sleep 15;;
  esac
done

# ============================================================================
# 9. Summary banner
# ============================================================================
echo ""
echo "============================================================"
echo "AWS PCS deploy complete (proven core)."
echo "  Cluster:        ${CLUSTER_NAME} (id ${CLUSTER_ID})"
echo "  Region / AZ:    ${REGION} / ${AZ}"
echo "  Scheduler:      SLURM ${SLURM_VERSION}, size SMALL, managed accounting STANDARD"
echo "  Accounting:     AccountingStorageEnforce=associations,limits,qos (login-node QoS enforced)"
echo "  Node group:     ${CNG_NAME} (id ${CNG_ID}) purchaseOption=CAPACITY_BLOCK"
echo "  NeuronCore:     node Feature 'neuron,neuroncores${PER_NODE_NEURONCORES}' -> select with --constraint=neuron"
echo "  Queue:          ${QUEUE_NAME} (Slurm partition)"
echo "  Compute:        ${COMPUTE_NODE_COUNT} x ${COMPUTE_INSTANCE_TYPE}"
echo "  Capacity Block: ${CR_ID} (${cr_count} instances in ${cr_az})"
echo "  PCS AMI:        ${PCS_AMI}"
echo "  Launch tmpl:    ${LT_ID} v${LT_VERSION} (capacity-block market + CR target + Neuron user-data)"
echo "  EFS /shared:    ${EFS_ID} (mount target in ${SUBNET_ID}, cluster SG ${SG_ID})"
echo "  Security group: ${SG_ID} (self-referencing; all egress)"
echo "  IAM role:       ${ROLE_NAME} (instance profile ${PROFILE_ARN})"
echo "  Students:       ${STUDENT_COUNT} (login node + per-student accounts: follow-up)"
echo "  Alert email:    ${ALERT_EMAIL} (budget/kill-switch wiring: follow-up)"
echo ""
echo "FOUNDATION — PCS-on-CB core + EFS /shared (Phase 4) + NeuronCore selection"
echo "and accounting enforcement (Phase 2). Documented but NOT live-validated."
echo "  Phase 2 (this script) now wires:"
echo "    * NeuronCore selection as the CNG node Feature 'neuron,neuroncores${PER_NODE_NEURONCORES}';"
echo "      students select a Trainium node with --constraint=neuron. This is"
echo "      NODE-LEVEL selection ONLY — per-core NeuronCore isolation is NOT"
echo "      available on PCS (Gres is not in the PCS allow-list), so it replaces"
echo "      the parent kit's per-node Gres=neuroncore:N."
echo "    * cluster AccountingStorageEnforce=associations,limits,qos, so the"
echo "      login-node per-student QoS (MaxWall + MaxJobsPerUser) IS enforced."
echo "  Sibling phases (see ../docs/design.md): the login node that SETS that QoS"
echo "  via sacctmgr (Phases 1/3) and EFS /shared (Phase 4, created above)."
echo "  STILL not wired in this script:"
echo "    * login node itself (student SSH + POSIX users + sacctmgr per-student QoS)"
echo "    * per-student roster sync onto /shared (login-node follow-up)"
echo "    * budget/kill-switch + manifest automations (reuse the parent kit)"
echo "  See ../docs/design.md 'OPEN ITEMS / NOT YET IMPLEMENTED'."
echo ""
echo "Next steps:"
echo "  1. Create a PCS login node group + queue, or register a self-managed"
echo "     login EC2 to the cluster (put it in ${SG_ID} so it also mounts /shared)."
echo "  2. Connect to a login node and run sacctmgr against managed accounting"
echo "     to set per-student QoS limits (student-count=${STUDENT_COUNT}); the"
echo "     cluster's AccountingStorageEnforce above makes those limits binding."
echo "  3. Submit a smoke-test job to the '${QUEUE_NAME}' partition with"
echo "     --constraint=neuron (see pcs/slurm/job-templates/run.sh); confirm the"
echo "     compute node mounted /shared (EFS ${EFS_ID})."
echo "============================================================"
