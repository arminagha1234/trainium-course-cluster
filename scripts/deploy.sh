#!/usr/bin/env bash
# deploy.sh — Trainium Course Cluster end-to-end deploy.
#
# Order:
#   1. Validate inputs, confirm the MLCB matches the given AZ.
#   2. Create a per-cluster "bootstrap" S3 bucket, package + upload the
#      manifest Lambda zip.
#   3. Deploy infra/parent-stack.yaml (VPC, EFS, SGs, staging bucket, Lambda,
#      manifest custom resource). The Lambda writes roster.json + manifest.json
#      to the staging bucket as part of stack creation.
#   4. Upload bootstrap scripts, the rendered Slurm include, and student
#      artifacts (RUNBOOK.md + run.sh) to the staging bucket.
#   5. Render infra/pcluster-config.yaml via envsubst.
#   6. `pcluster create-cluster` and wait for CREATE_COMPLETE.
#   7. Deploy infra/budget.yaml.
#   8. Print manifest + head node info.
#
# Idempotent: safe to re-run. Parent + budget CFN deploys use `aws
# cloudformation deploy` which is a no-op when nothing changes; s3 mb and
# uploads are naturally idempotent; pcluster create-cluster fails cleanly if
# a cluster with the same name already exists (we detect and skip).

set -euo pipefail

# ============================================================================
# CLI parsing
# ============================================================================
usage() {
  cat >&2 <<EOF
usage: $0 [options]

Required:
  --cluster-name NAME              lowercase, 3-40 chars, unique in region
  --capacity-reservation-id CR_ID  format cr-XXXXXXXX
  --availability-zone AZ           e.g. sa-east-1a; must match the MLCB
  --region REGION                  only sa-east-1 is supported (see docs/inputs.md#region)
  --student-count N                1..500
  --ssh-allowed-cidr CIDR[,CIDR...] one CIDR, or up to ${MAX_SSH_CIDRS} comma-separated ranges,
                                   e.g. 10.20.0.0/16  or  10.20.0.0/16,192.0.2.0/24
                                   (0.0.0.0/0 and ::/0 rejected in ANY range)
  --alert-email EMAIL              budget alerts destination
  --admin-ssh-key-name KEYNAME     EC2 keypair for the head node ubuntu sudoer

Common:
  --compute-node-count N           default 1
  --compute-instance-type TYPE     default trn2.3xlarge
  --head-instance-type TYPE        default m6i.xlarge
  --username-prefix PREFIX         default student
  --class-tag TAG                  default nki-2026-fall
  --monthly-budget-usd USD         default 500
  --retain-efs {true|false}        default true
  --dry-run                        show what would run and exit

Per-student Slurm limits (Requirement 18):
  --max-wall-time TIME             per-job wall clock, Slurm time string (default 1-00:00:00);
                                   accepts [days-]HH:MM:SS, HH:MM:SS, MM:SS, or bare minutes;
                                   must resolve to between 1 minute and 7 days
  --max-concurrent-jobs-per-user N max concurrent running jobs/student, 1..100 (default 8)
  --max-cores-per-user N           max NeuronCores/student, 1..cluster total (default 4)
  --core-hours-budget N            per-student core-hours budget; 0 = unlimited (default 0)

Advanced:
  --neuron-ami-id AMI_ID           OPTIONAL. Pin a specific Neuron AMI, used verbatim as the
                                   ParallelCluster CustomAmi and validated in-region before
                                   cluster creation. When omitted, ParallelCluster's stock AMI
                                   for --image-os is used and the Neuron SDK + torch-neuronx are
                                   installed at first boot by the compute bootstrap from the
                                   public Neuron apt/pip repos.
  --vpc-cidr CIDR                  default 10.42.0.0/16
  --public-subnet-cidr CIDR        default 10.42.0.0/24
  --private-subnet-cidr CIDR       default 10.42.1.0/24
  --efs-throughput-mode MODE       elastic|bursting (default elastic)
  --image-os OS                    default ubuntu2404
  --repo-dir DIR                   default: parent of this script's directory
  --parent-only                    deploy the parent stack only (no MLCB / pcluster / budget).
                                   Skips validation of CR id + admin SSH key. Use for testing.
EOF
  exit 2
}

# Defaults
# Max number of comma-separated ranges accepted by --ssh-allowed-cidr. The
# parent stack renders one head-node ingress rule per range across a
# fixed-length CommaDelimitedList (indices 0..MAX-1); CFN cannot loop
# unboundedly, so this cap is shared by both sides (divergence D8).
MAX_SSH_CIDRS=5
COMPUTE_NODE_COUNT=1
COMPUTE_INSTANCE_TYPE=trn2.3xlarge
HEAD_INSTANCE_TYPE=m6i.xlarge
USERNAME_PREFIX=student
CLASS_TAG=nki-2026-fall
MONTHLY_BUDGET_USD=500
RETAIN_EFS=true
VPC_CIDR=10.42.0.0/16
PUB_CIDR=10.42.0.0/24
PRV_CIDR=10.42.1.0/24
EFS_MODE=elastic
IMAGE_OS=ubuntu2404
DRY_RUN=false
PARENT_ONLY=false
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Per-student Slurm limit defaults (Requirement 18; divergence D5). These are
# plumbed to bootstrap/head-node-setup.sh as positional args $3..$6 via the
# pcluster HeadNode OnNodeConfigured Args (rendered in the envsubst block below).
MAX_WALL_TIME=1-00:00:00
MAX_CONCURRENT_JOBS_PER_USER=8
MAX_CORES_PER_USER=4
CORE_HOURS_BUDGET=0

# Neuron AMI (Requirement 19; divergence D4). OPTIONAL. Empty => use the
# ParallelCluster stock AMI for --image-os and install the Neuron SDK +
# torch-neuronx at first boot via bootstrap/compute-node-setup.sh (from the
# public apt/pip repos). Non-empty (operator-supplied) => use verbatim as the
# PC CustomAmi and validate it resolves in-region before cluster creation.
NEURON_AMI_ID=""
NEURON_AMI_SOURCE=""      # set during AMI resolution: "operator-supplied" | "none (stock AMI)"
NEURON_SDK_VERSION=""     # recorded in the deploy banner (Requirement 19.6)

CLUSTER_NAME=""; CR_ID=""; AZ=""; REGION=""; STUDENT_COUNT=""
SSH_CIDR=""; ALERT_EMAIL=""; ADMIN_SSH_KEY=""

while (( $# )); do
  case "$1" in
    --cluster-name)             CLUSTER_NAME="$2"; shift 2;;
    --capacity-reservation-id)  CR_ID="$2"; shift 2;;
    --availability-zone)        AZ="$2"; shift 2;;
    --region)                   REGION="$2"; shift 2;;
    --student-count)            STUDENT_COUNT="$2"; shift 2;;
    --ssh-allowed-cidr)         SSH_CIDR="$2"; shift 2;;
    --alert-email)              ALERT_EMAIL="$2"; shift 2;;
    --admin-ssh-key-name)       ADMIN_SSH_KEY="$2"; shift 2;;
    --compute-node-count)       COMPUTE_NODE_COUNT="$2"; shift 2;;
    --compute-instance-type)    COMPUTE_INSTANCE_TYPE="$2"; shift 2;;
    --head-instance-type)       HEAD_INSTANCE_TYPE="$2"; shift 2;;
    --username-prefix)          USERNAME_PREFIX="$2"; shift 2;;
    --class-tag)                CLASS_TAG="$2"; shift 2;;
    --monthly-budget-usd)       MONTHLY_BUDGET_USD="$2"; shift 2;;
    --retain-efs)               RETAIN_EFS="$2"; shift 2;;
    --vpc-cidr)                 VPC_CIDR="$2"; shift 2;;
    --public-subnet-cidr)       PUB_CIDR="$2"; shift 2;;
    --private-subnet-cidr)      PRV_CIDR="$2"; shift 2;;
    --efs-throughput-mode)      EFS_MODE="$2"; shift 2;;
    --image-os)                 IMAGE_OS="$2"; shift 2;;
    --max-wall-time)                MAX_WALL_TIME="$2"; shift 2;;
    --max-concurrent-jobs-per-user) MAX_CONCURRENT_JOBS_PER_USER="$2"; shift 2;;
    --max-cores-per-user)           MAX_CORES_PER_USER="$2"; shift 2;;
    --core-hours-budget)            CORE_HOURS_BUDGET="$2"; shift 2;;
    --neuron-ami-id)                NEURON_AMI_ID="$2"; shift 2;;
    --repo-dir)                 REPO_DIR="$2"; shift 2;;
    --parent-only)              PARENT_ONLY=true; shift 1;;
    --dry-run)                  DRY_RUN=true; shift 1;;
    -h|--help)                  usage;;
    *) echo "unknown arg: $1" >&2; usage;;
  esac
done

# ============================================================================
# Local validation
# ============================================================================
# --parent-only skips everything downstream of the parent CFN stack: no
# MLCB validation, no pcluster create-cluster, no admin SSH key required.
# Useful for testing the VPC + EFS + Manifest custom resource wiring without
# committing to an MLCB purchase. See Tier 3 in the testing plan.
required_vars=(CLUSTER_NAME REGION STUDENT_COUNT SSH_CIDR ALERT_EMAIL AZ)
if ! $PARENT_ONLY; then
  required_vars+=(CR_ID ADMIN_SSH_KEY)
fi
missing=()
for var in "${required_vars[@]}"; do
  [[ -z "${!var}" ]] && missing+=("$var")
done
if (( ${#missing[@]} )); then
  echo "missing required flags: ${missing[*]}" >&2
  usage
fi

# In --parent-only mode we still need a syntactically valid cr- id because the
# parent stack has an AllowedPattern on it. Fill in a dummy if unset.
if $PARENT_ONLY && [[ -z "${CR_ID}" ]]; then
  CR_ID="cr-0000000000000dead"
  echo "==> --parent-only: using placeholder CapacityReservationId=${CR_ID}"
fi

# ---------------------------------------------------------------------------
# SSH-allowed CIDR validation (Requirements 14.2, 23.3, 23.5; divergence D8).
# --ssh-allowed-cidr accepts a single CIDR or a comma-separated list of up to
# MAX_SSH_CIDRS ranges. EACH range is validated independently: it must be a
# syntactically valid IPv4/IPv6 CIDR and must NOT be an open range (0.0.0.0/0
# or ::/0) - an open range anywhere in the list is rejected. The cleaned list
# is then padded to exactly MAX_SSH_CIDRS comma-separated elements (empty
# placeholders) so the parent stack's fixed-length CommaDelimitedList +
# per-index conditional ingress rules line up (see infra/parent-stack.yaml).
# The single-range default therefore still yields exactly one ingress rule.
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
  # Reject an open range anywhere in the list (Requirement 14.2).
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

# Re-join the cleaned ranges and pad to exactly MAX_SSH_CIDRS elements with
# trailing empty placeholders (each extra comma adds one empty list element).
SSH_CIDR="$(IFS=','; echo "${ssh_cidr_ranges[*]}")"
_pad=$(( MAX_SSH_CIDRS - ${#ssh_cidr_ranges[@]} ))
while (( _pad-- > 0 )); do SSH_CIDR="${SSH_CIDR},"; done
[[ "${CLUSTER_NAME}" =~ ^[a-z][a-z0-9-]{2,39}$ ]] || {
  echo "cluster-name must be lowercase, 3-40 chars, [a-z0-9-]" >&2
  exit 1
}
[[ "${STUDENT_COUNT}" =~ ^[0-9]+$ ]] && (( STUDENT_COUNT >= 1 && STUDENT_COUNT <= 500 )) || {
  echo "student-count must be an integer in [1, 500]" >&2
  exit 1
}
# compute-node-count feeds the Slurm gres NodeName range `[1-N]`. If it is
# unset, empty, non-numeric, or zero, that range is malformed and slurmd would
# fail to register the neuroncore gres (design divergence D6). Fail fast here,
# before any AWS call or include-file render.
[[ "${COMPUTE_NODE_COUNT:-}" =~ ^[0-9]+$ ]] && (( COMPUTE_NODE_COUNT >= 1 )) || {
  echo "compute-node-count must be a positive integer (got '${COMPUTE_NODE_COUNT:-<unset>}');" >&2
  echo "  the Slurm gres NodeName range [1-N] would otherwise be malformed" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Per-student Slurm limit validation (Requirement 18; divergence D5). Validated
# here, before any AWS call, alongside the other local input checks. Ranges:
# wall time 1 min..7 days (18.1); concurrent jobs 1..100 (18.2); cores 1..cluster
# total (18.3); core-hours budget >= 0 with 0 = unlimited (18.5). These values
# are plumbed to head-node-setup.sh as OnNodeConfigured Args $3..$6 by the
# pcluster render block below.
# ---------------------------------------------------------------------------

# Convert a Slurm time string ([days-]HH:MM:SS, HH:MM:SS, MM:SS, or bare minutes)
# to total seconds on stdout; non-zero exit on parse failure. Arithmetic is
# 10#-prefixed to force base 10 so zero-padded fields like "08" are not misread
# as (invalid) octal.
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
# 1 minute (60s) .. 7 days (604800s), per Requirement 18.1.
(( WALL_SECONDS >= 60 && WALL_SECONDS <= 604800 )) || {
  echo "max-wall-time must resolve to between 1 minute and 7 days (got '${MAX_WALL_TIME}')" >&2
  exit 1
}

# Concurrent running jobs per student: integer 1..100 (Requirement 18.2).
[[ "${MAX_CONCURRENT_JOBS_PER_USER}" =~ ^[0-9]+$ ]] && \
  (( MAX_CONCURRENT_JOBS_PER_USER >= 1 && MAX_CONCURRENT_JOBS_PER_USER <= 100 )) || {
  echo "max-concurrent-jobs-per-user must be an integer in [1, 100] (got '${MAX_CONCURRENT_JOBS_PER_USER}')" >&2
  exit 1
}

# Max NeuronCores per student: integer 1..(cluster total) (Requirement 18.3). The
# cluster total is COMPUTE_NODE_COUNT * per-node NeuronCores; the per-node count
# tracks the compute shape and matches the gres include's `neuroncore:N`
# (trn2.3xlarge=4, trn2.48xlarge=16), defaulting to 4 as a sane cap.
case "${COMPUTE_INSTANCE_TYPE}" in
  trn2.48xlarge) PER_NODE_NEURONCORES=16 ;;
  trn2.3xlarge)  PER_NODE_NEURONCORES=4  ;;
  *)             PER_NODE_NEURONCORES=4  ;;
esac
CLUSTER_TOTAL_NEURONCORES=$(( COMPUTE_NODE_COUNT * PER_NODE_NEURONCORES ))
[[ "${MAX_CORES_PER_USER}" =~ ^[0-9]+$ ]] && \
  (( MAX_CORES_PER_USER >= 1 && MAX_CORES_PER_USER <= CLUSTER_TOTAL_NEURONCORES )) || {
  echo "max-cores-per-user must be an integer in [1, ${CLUSTER_TOTAL_NEURONCORES}]" >&2
  echo "  (COMPUTE_NODE_COUNT=${COMPUTE_NODE_COUNT} x ${PER_NODE_NEURONCORES} NeuronCores/node for ${COMPUTE_INSTANCE_TYPE})" >&2
  exit 1
}

# Per-student core-hours budget: non-negative integer; 0 = unlimited (Req 18.5).
[[ "${CORE_HOURS_BUDGET}" =~ ^[0-9]+$ ]] || {
  echo "core-hours-budget must be a non-negative integer (0 = unlimited; got '${CORE_HOURS_BUDGET}')" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Region constraint (Requirement 4; divergence D10). Single, single-sourced
# allow-list enforced HERE in the local-validation section, BEFORE any AWS call,
# in ALL modes including --parent-only (Req 4.4). sa-east-1 and us-east-2 are
# permitted.
#
# trn2.3xlarge MLCBs are sold in both sa-east-1 (Sao Paulo) and ap-southeast-4
# (Melbourne); sa-east-1 remains the trn2.3xlarge home because AWS ParallelCluster
# does not support Melbourne. us-east-2 (Ohio) is also a valid ParallelCluster
# region and is where trn2.48xlarge MLCBs are used, so it is permitted too.
# ap-southeast-4 stays rejected (PC cannot deploy there). See docs/inputs.md#region
# and the PC supported-regions page:
# https://docs.aws.amazon.com/parallelcluster/latest/ug/supported-regions.html
# ---------------------------------------------------------------------------
case "${REGION}" in
  sa-east-1|us-east-2)
    : # supported: valid ParallelCluster regions (sa-east-1 = trn2.3xlarge home; us-east-2 = trn2.48xlarge) (Req 4.1)
    ;;
  ap-southeast-4)
    echo "ERROR: --region ap-southeast-4 (Melbourne) is not supported by AWS ParallelCluster." >&2
    echo "  Melbourne sells trn2.3xlarge MLCBs but ParallelCluster cannot deploy there." >&2
    echo "  Use sa-east-1 for trn2.3xlarge MLCB courses. See docs/inputs.md#region." >&2
    exit 1
    ;;
  *)
    echo "ERROR: --region ${REGION} is not supported by this kit." >&2
    echo "  Only sa-east-1 and us-east-2 are supported. See docs/inputs.md#region." >&2
    exit 1
    ;;
esac

command -v aws       >/dev/null || { echo "aws CLI not on PATH" >&2; exit 1; }
if ! $PARENT_ONLY; then
  command -v pcluster >/dev/null || { echo "pcluster CLI not on PATH (install with pip install aws-parallelcluster)" >&2; exit 1; }
fi
command -v envsubst  >/dev/null || { echo "envsubst not found; install gettext (mac: brew install gettext)" >&2; exit 1; }
command -v zip       >/dev/null || { echo "zip not found" >&2; exit 1; }
command -v jq        >/dev/null || { echo "jq not found" >&2; exit 1; }

# ============================================================================
# AWS-side validation
# ============================================================================
echo "==> validating AWS context"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "    account=${ACCOUNT_ID} region=${REGION}"

if $PARENT_ONLY; then
  echo "==> --parent-only mode: skipping MLCB and admin-SSH-key validation"
else
  echo "==> validating MLCB ${CR_ID}"
  cr_json=$(aws ec2 describe-capacity-reservations \
    --region "${REGION}" \
    --capacity-reservation-ids "${CR_ID}" \
    --query 'CapacityReservations[0].{state:State,az:AvailabilityZone,type:InstanceType,count:TotalInstanceCount,end:EndDate}' \
    --output json 2>/dev/null || echo '{}')
  cr_state=$(echo "${cr_json}" | jq -r '.state // "unknown"')
  cr_az=$(echo "${cr_json}" | jq -r '.az // "unknown"')
  cr_type=$(echo "${cr_json}" | jq -r '.type // "unknown"')
  cr_count=$(echo "${cr_json}" | jq -r '.count // "0"')
  # EndDate drives the one-time auto-teardown schedule (design divergence D1,
  # Requirement 22.1). It is absent for EndDateType=unlimited reservations;
  # captured here and normalized + consumed at the auto-teardown deploy below.
  cr_end_raw=$(echo "${cr_json}" | jq -r '.end // empty')
  echo "    state=${cr_state} az=${cr_az} type=${cr_type} count=${cr_count} end=${cr_end_raw:-<none>}"

  if [[ "${cr_state}" != "active" && "${cr_state}" != "scheduled" && "${cr_state}" != "payment-pending" ]]; then
    echo "    WARNING: reservation is in state ${cr_state}; proceeding but launches may fail"
  fi
  if [[ "${cr_az}" != "${AZ}" ]]; then
    echo "    ERROR: --availability-zone ${AZ} does not match reservation AZ ${cr_az}" >&2
    exit 1
  fi
  if [[ "${cr_type}" != "${COMPUTE_INSTANCE_TYPE}" ]]; then
    echo "    ERROR: --compute-instance-type ${COMPUTE_INSTANCE_TYPE} does not match reservation type ${cr_type}" >&2
    exit 1
  fi
  if (( COMPUTE_NODE_COUNT > cr_count )); then
    echo "    ERROR: --compute-node-count ${COMPUTE_NODE_COUNT} exceeds reservation capacity ${cr_count}" >&2
    exit 1
  fi

  echo "==> validating admin SSH key ${ADMIN_SSH_KEY}"
  aws ec2 describe-key-pairs --region "${REGION}" --key-names "${ADMIN_SSH_KEY}" >/dev/null 2>&1 || {
    echo "    ERROR: EC2 keypair ${ADMIN_SSH_KEY} not found in ${REGION}" >&2
    exit 1
  }

  # ---------------------------------------------------------------------------
  # Neuron AMI resolution + validation (Requirement 19; divergence D4).
  #
  # Precedence:
  #   --neuron-ami-id supplied -> use verbatim as the PC CustomAmi (Req 19.1),
  #                               and validate it resolves + is 'available'
  #                               in-region via describe-images BEFORE creating
  #                               any cluster resources (Req 19.4).
  #   omitted (default)        -> do NOT resolve or validate any AMI. PC uses its
  #                               stock AMI for --image-os and the Neuron SDK +
  #                               torch-neuronx are installed at first boot by
  #                               bootstrap/compute-node-setup.sh from the public
  #                               Neuron apt/pip repos. NEURON_AMI_ID stays empty
  #                               so CUSTOM_AMI_LINE renders blank below.
  #
  # Skipped entirely under --parent-only (no cluster is created there).
  if [[ -n "${NEURON_AMI_ID}" ]]; then
    NEURON_AMI_SOURCE="operator-supplied"
    NEURON_SDK_VERSION="operator-supplied (not introspected)"
    echo "==> using operator-supplied Neuron AMI ${NEURON_AMI_ID} (verbatim CustomAmi)"

    # Validate the supplied AMI actually resolves in-region (Req 19.4). Capture
    # the image Name too so the deploy banner records the concrete build. This
    # runs ONLY when an AMI was supplied; the stock-AMI path skips it.
    echo "==> validating Neuron AMI ${NEURON_AMI_ID} resolves in ${REGION}"
    ami_json=$(aws ec2 describe-images --region "${REGION}" \
      --image-ids "${NEURON_AMI_ID}" \
      --query 'Images[0].{name:Name,state:State}' --output json 2>/dev/null || echo '{}')
    ami_name=$(echo "${ami_json}" | jq -r '.name // empty')
    ami_state=$(echo "${ami_json}" | jq -r '.state // empty')
    if [[ -z "${ami_name}" ]]; then
      echo "    ERROR: Neuron AMI ${NEURON_AMI_ID} could not be validated in ${REGION}" >&2
      echo "      (describe-images found no such image). Aborting before cluster creation." >&2
      echo "      Check the AMI id and region, or omit --neuron-ami-id to use the stock AMI. (Req 19.4)" >&2
      exit 1
    fi
    if [[ "${ami_state}" != "available" ]]; then
      echo "    ERROR: Neuron AMI ${NEURON_AMI_ID} is in state '${ami_state}' (expected 'available')" >&2
      echo "      in ${REGION}. Aborting before cluster creation. (Req 19.4)" >&2
      exit 1
    fi
    echo "    ok: ${NEURON_AMI_ID} (${ami_name}) state=${ami_state}"
    # Surface the image Name as the best-available SDK-version signal (Req 19.6).
    NEURON_SDK_VERSION="from AMI Name: ${ami_name}"
  else
    # No AMI supplied: PC uses its stock ${IMAGE_OS} image and the compute
    # bootstrap installs the public Neuron SDK + torch-neuronx at first boot.
    # No SSM lookup and no describe-images call are made. NEURON_AMI_ID stays
    # empty so CUSTOM_AMI_LINE renders blank and PC falls back to its default.
    NEURON_AMI_SOURCE="none (ParallelCluster stock ${IMAGE_OS} AMI; Neuron SDK installed at bootstrap)"
    NEURON_SDK_VERSION="installed at first boot from public Neuron repos (aws-neuronx-* 2.x + torch-neuronx 2.9)"
    echo "==> no --neuron-ami-id supplied: using ParallelCluster's stock ${IMAGE_OS} AMI;"
    echo "    the Neuron SDK + torch-neuronx will be installed at first boot by"
    echo "    bootstrap/compute-node-setup.sh from the public Neuron apt/pip repos."
  fi
fi

if $DRY_RUN; then
  echo "==> dry-run: would deploy stack ${CLUSTER_NAME}, class tag ${CLASS_TAG}, ${STUDENT_COUNT} students"
  exit 0
fi

# ============================================================================
# 1. Bootstrap bucket + Lambda zip
# ============================================================================
BOOT_BUCKET="${CLUSTER_NAME}-${ACCOUNT_ID}-${REGION}-bootstrap"
echo "==> preparing bootstrap bucket s3://${BOOT_BUCKET}"
if ! aws s3api head-bucket --bucket "${BOOT_BUCKET}" --region "${REGION}" 2>/dev/null; then
  if [[ "${REGION}" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "${BOOT_BUCKET}" --region "${REGION}"
  else
    aws s3api create-bucket \
      --bucket "${BOOT_BUCKET}" --region "${REGION}" \
      --create-bucket-configuration LocationConstraint="${REGION}"
  fi
  aws s3api put-public-access-block --bucket "${BOOT_BUCKET}" --public-access-block-configuration \
    'BlockPublicAcls=true,BlockPublicPolicy=true,IgnorePublicAcls=true,RestrictPublicBuckets=true'
  aws s3api put-bucket-encryption --bucket "${BOOT_BUCKET}" --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  aws s3api put-bucket-tagging --bucket "${BOOT_BUCKET}" --tagging "TagSet=[{Key=Class,Value=${CLASS_TAG}}]"
fi

echo "==> packaging manifest Lambda"
LAMBDA_ZIP="/tmp/${CLUSTER_NAME}-student_manifest.zip"
rm -f "${LAMBDA_ZIP}"
(cd "${REPO_DIR}/lambda/student_manifest" && zip -q -r "${LAMBDA_ZIP}" . -x "*.pyc" "__pycache__/*" "README.md")
LAMBDA_KEY="lambda/student_manifest-$(date +%Y%m%d-%H%M%S).zip"
aws s3 cp --region "${REGION}" "${LAMBDA_ZIP}" "s3://${BOOT_BUCKET}/${LAMBDA_KEY}"
echo "    uploaded s3://${BOOT_BUCKET}/${LAMBDA_KEY}"

# ============================================================================
# 2. Deploy parent stack
# ============================================================================
PARENT_STACK="${CLUSTER_NAME}-parent"
echo "==> deploying parent stack ${PARENT_STACK}"
aws cloudformation deploy \
  --stack-name "${PARENT_STACK}" \
  --template-file "${REPO_DIR}/infra/parent-stack.yaml" \
  --parameter-overrides \
      ClusterName="${CLUSTER_NAME}" \
      ClassTag="${CLASS_TAG}" \
      StudentCount="${STUDENT_COUNT}" \
      UsernamePrefix="${USERNAME_PREFIX}" \
      CapacityReservationId="${CR_ID}" \
      AvailabilityZone="${AZ}" \
      SshAllowedCidr="${SSH_CIDR}" \
      VpcCidr="${VPC_CIDR}" \
      PublicSubnetCidr="${PUB_CIDR}" \
      PrivateSubnetCidr="${PRV_CIDR}" \
      EfsThroughputMode="${EFS_MODE}" \
      ManifestLambdaCodeBucket="${BOOT_BUCKET}" \
      ManifestLambdaCodeKey="${LAMBDA_KEY}" \
      RetainEfsOnDelete="${RETAIN_EFS}" \
  --region "${REGION}" \
  --capabilities CAPABILITY_NAMED_IAM

STAGING_BUCKET=$(aws cloudformation describe-stacks --stack-name "${PARENT_STACK}" --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='StagingBucketName'].OutputValue" --output text)
PUB_SUBNET=$(aws cloudformation describe-stacks --stack-name "${PARENT_STACK}" --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='PublicSubnetId'].OutputValue" --output text)
PRV_SUBNET=$(aws cloudformation describe-stacks --stack-name "${PARENT_STACK}" --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='PrivateSubnetId'].OutputValue" --output text)
HEAD_SG=$(aws cloudformation describe-stacks --stack-name "${PARENT_STACK}" --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='HeadNodeSecurityGroupId'].OutputValue" --output text)
COMPUTE_SG=$(aws cloudformation describe-stacks --stack-name "${PARENT_STACK}" --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='ComputeSecurityGroupId'].OutputValue" --output text)
EFS_ID=$(aws cloudformation describe-stacks --stack-name "${PARENT_STACK}" --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='EfsFilesystemId'].OutputValue" --output text)
# Slurm accounting DB password secret (Requirement 18; divergence D5). Feeds
# BOTH the PC SlurmSettings.Database.PasswordSecretArn AND the head-node
# OnNodeConfigured $7 arg, so the local MariaDB user and slurmdbd share one
# password. The accounting DB itself is head-node-local (127.0.0.1:3306) — no
# RDS — so there is no user-facing flag; the URI + user below are fixed constants.
SLURM_DB_SECRET_ARN=$(aws cloudformation describe-stacks --stack-name "${PARENT_STACK}" --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='SlurmDbPasswordSecretArn'].OutputValue" --output text)
echo "    staging=${STAGING_BUCKET} pub=${PUB_SUBNET} prv=${PRV_SUBNET} efs=${EFS_ID}"
echo "    slurm-acct-db=head-node-local MariaDB @127.0.0.1:3306 (secret=${SLURM_DB_SECRET_ARN})"

# ============================================================================
# 3. Upload bootstrap + slurm + student artifacts to staging bucket
# ============================================================================
echo "==> uploading bootstrap + slurm + student artifacts to s3://${STAGING_BUCKET}/"
aws s3 cp --region "${REGION}" "${REPO_DIR}/bootstrap/head-node-db-setup.sh" "s3://${STAGING_BUCKET}/bootstrap/head-node-db-setup.sh"
aws s3 cp --region "${REGION}" "${REPO_DIR}/bootstrap/head-node-setup.sh"    "s3://${STAGING_BUCKET}/bootstrap/head-node-setup.sh"
aws s3 cp --region "${REGION}" "${REPO_DIR}/bootstrap/compute-node-setup.sh" "s3://${STAGING_BUCKET}/bootstrap/compute-node-setup.sh"

# Render + upload the slurm include file.
#
# The template no longer carries any envsubst variables. ParallelCluster owns
# the compute NodeName line (it generates its own
# slurm_parallelcluster_<queue>_partition.conf) and deny-lists Gres/NodeName for
# CustomSlurmSettings, so the per-node `Gres=neuroncore:N` is NOT set in this
# include — it is appended to PC's OWN NodeName line by the head + compute
# bootstraps (head-node-setup.sh section 6.5 and compute-node-setup.sh) and they
# reload. So there is no NodeName pattern / queue / resource name to derive here
# anymore; we render the include with a plain no-op `envsubst` (equivalent to a
# copy) and upload it unchanged. The per-node NeuronCore count still reaches the
# bootstraps via the pcluster config render below
# (NEURONCORE_COUNT=${PER_NODE_NEURONCORES} -> HeadNode OnNodeConfigured $8).
SLURM_TMP=$(mktemp)
envsubst < "${REPO_DIR}/slurm/slurm.conf.d/neuroncore-gres.conf.template" > "${SLURM_TMP}"
aws s3 cp --region "${REGION}" "${SLURM_TMP}" "s3://${STAGING_BUCKET}/slurm/neuroncore-gres.conf"
rm -f "${SLURM_TMP}"

# Student-facing artifacts: RUNBOOK.md and default run.sh get dropped into
# each student's home by the head bootstrap.
aws s3 cp --region "${REGION}" "${REPO_DIR}/student-runbook.md" "s3://${STAGING_BUCKET}/student/RUNBOOK.md" 2>/dev/null || \
  echo "    WARN: student-runbook.md not present; students will not get a RUNBOOK.md in their home"
aws s3 cp --region "${REGION}" "${REPO_DIR}/slurm/job-templates/run.sh"            "s3://${STAGING_BUCKET}/student/run.sh"
aws s3 cp --region "${REGION}" "${REPO_DIR}/slurm/job-templates/run-multi-core.sh" "s3://${STAGING_BUCKET}/student/run-multi-core.sh"

# Harness - uploaded but head-node bootstrap does not currently sync these
# into homes automatically. deploy.sh drops them into a well-known /shared
# location the run.sh templates already reference (HARNESS_DIR).
aws s3 cp --region "${REGION}" --recursive "${REPO_DIR}/harness" "s3://${STAGING_BUCKET}/harness/" \
  --exclude "*/__pycache__/*" --exclude "*.pyc"

# ============================================================================
# 4. Render + create the ParallelCluster cluster
# ============================================================================
if $PARENT_ONLY; then
  echo "==> --parent-only: skipping pcluster create-cluster"
  echo "==> --parent-only: skipping budget stack (no MLCB spend to guard)"
  HEAD_DNS="<n/a - parent-only>"
  cr_az="${AZ}"; cr_count="0"
  cat <<END

============================================================
Parent stack deploy complete (--parent-only mode).
  Cluster:       ${CLUSTER_NAME}
  Region:        ${REGION}
  Staging:       s3://${STAGING_BUCKET}
  Students:      ${STUDENT_COUNT} (usernames ${USERNAME_PREFIX}01..${USERNAME_PREFIX}$(printf %02d "${STUDENT_COUNT}"))

Verify the manifest resource actually generated secrets:
  aws secretsmanager list-secrets --region ${REGION} \\
    --filters Key=name,Values=trn-course-${CLUSTER_NAME}

Fetch the manifest:
  scripts/fetch-manifest.sh --cluster-name ${CLUSTER_NAME} --region ${REGION} --pretty

Teardown (idempotent):
  scripts/teardown.sh --cluster-name ${CLUSTER_NAME} --region ${REGION} --purge-efs
============================================================
END
  exit 0
fi

PC_CLUSTER_NAME="${CLUSTER_NAME}"  # pcluster and CFN stack names differ; keep both same
echo "==> checking for existing pcluster ${PC_CLUSTER_NAME}"
if pcluster describe-cluster --cluster-name "${PC_CLUSTER_NAME}" --region "${REGION}" >/dev/null 2>&1; then
  echo "    cluster ${PC_CLUSTER_NAME} already exists in ${REGION}; skipping create"
else
  # Build the single-line CustomAmi render var per task 5.1's convention: exactly
  # two leading spaces + "CustomAmi: <id>" when an operator-supplied AMI is set,
  # else "" so the sentinel line in pcluster-config.yaml renders blank and PC
  # uses its default stock image. In the default path NEURON_AMI_ID is empty
  # (no --neuron-ami-id; the compute bootstrap installs Neuron at first boot),
  # so CUSTOM_AMI_LINE renders blank and PC falls back to its stock ${IMAGE_OS} AMI.
  if [[ -n "${NEURON_AMI_ID}" ]]; then
    CUSTOM_AMI_LINE="  CustomAmi: ${NEURON_AMI_ID}"
  else
    CUSTOM_AMI_LINE=""
  fi

  PC_CFG=$(mktemp)
  CUSTOM_AMI_LINE="${CUSTOM_AMI_LINE}" \
  MAX_WALL_TIME="${MAX_WALL_TIME}" \
  MAX_CONCURRENT_JOBS_PER_USER="${MAX_CONCURRENT_JOBS_PER_USER}" \
  MAX_CORES_PER_USER="${MAX_CORES_PER_USER}" \
  CORE_HOURS_BUDGET="${CORE_HOURS_BUDGET}" \
  SLURM_DB_URI="127.0.0.1:3306" \
  SLURM_DB_USERNAME="slurm" \
  SLURM_DB_PASSWORD_SECRET_ARN="${SLURM_DB_SECRET_ARN}" \
  REGION="${REGION}" \
  IMAGE_OS="${IMAGE_OS}" \
  HEAD_NODE_INSTANCE_TYPE="${HEAD_INSTANCE_TYPE}" \
  HEAD_NODE_SUBNET_ID="${PUB_SUBNET}" \
  COMPUTE_SUBNET_ID="${PRV_SUBNET}" \
  COMPUTE_SECURITY_GROUP_ID="${COMPUTE_SG}" \
  HEAD_SECURITY_GROUP_ID="${HEAD_SG}" \
  COMPUTE_INSTANCE_TYPE="${COMPUTE_INSTANCE_TYPE}" \
  COMPUTE_NODE_COUNT="${COMPUTE_NODE_COUNT}" \
  NEURONCORE_COUNT="${PER_NODE_NEURONCORES}" \
  CAPACITY_RESERVATION_ID="${CR_ID}" \
  EFS_FILESYSTEM_ID="${EFS_ID}" \
  STAGING_BUCKET="${STAGING_BUCKET}" \
  HEAD_DB_BOOTSTRAP_SCRIPT="s3://${STAGING_BUCKET}/bootstrap/head-node-db-setup.sh" \
  HEAD_BOOTSTRAP_SCRIPT="s3://${STAGING_BUCKET}/bootstrap/head-node-setup.sh" \
  COMPUTE_BOOTSTRAP_SCRIPT="s3://${STAGING_BUCKET}/bootstrap/compute-node-setup.sh" \
  SLURM_INCLUDE_FILE="s3://${STAGING_BUCKET}/slurm/neuroncore-gres.conf" \
  ADMIN_SSH_KEY_NAME="${ADMIN_SSH_KEY}" \
  CLUSTER_TAG="${CLASS_TAG}" \
    envsubst < "${REPO_DIR}/infra/pcluster-config.yaml" > "${PC_CFG}"
  echo "    rendered pcluster config to ${PC_CFG}"

  echo "==> creating pcluster ${PC_CLUSTER_NAME} (this can take 10-15 min)"
  pcluster create-cluster \
    --cluster-name "${PC_CLUSTER_NAME}" \
    --cluster-configuration "${PC_CFG}" \
    --region "${REGION}" \
    --rollback-on-failure false >/dev/null

  echo "==> waiting for pcluster CREATE_COMPLETE"
  while :; do
    status=$(pcluster describe-cluster --cluster-name "${PC_CLUSTER_NAME}" --region "${REGION}" 2>/dev/null | jq -r '.clusterStatus // "UNKNOWN"' 2>/dev/null || echo UNKNOWN)
    echo "    status=${status}"
    case "${status}" in
      CREATE_COMPLETE) break;;
      CREATE_FAILED|DELETE_IN_PROGRESS|DELETE_COMPLETE|UNKNOWN)
        echo "    cluster create failed with status ${status}" >&2
        exit 1;;
      *) sleep 30;;
    esac
  done
  rm -f "${PC_CFG}"
fi

# ============================================================================
# 5. Deploy budget stack
# ============================================================================
# Package the kill-switch Lambda (design divergence D13; Requirement 20). Like
# the manifest + auto_teardown lambdas, the code now lives in lambda/kill_switch/
# and is loaded from S3 (not inlined in budget.yaml) so it is unit-testable. Zip
# + upload to the bootstrap bucket, then hand the location to the budget stack
# via LambdaCodeBucket / LambdaCodeKey.
echo "==> packaging kill-switch Lambda"
KILLSWITCH_ZIP="/tmp/${CLUSTER_NAME}-kill_switch.zip"
rm -f "${KILLSWITCH_ZIP}"
(cd "${REPO_DIR}/lambda/kill_switch" && zip -q -r "${KILLSWITCH_ZIP}" . -x "*.pyc" "__pycache__/*" "README.md")
KILLSWITCH_KEY="lambda/kill_switch-$(date +%Y%m%d-%H%M%S).zip"
aws s3 cp --region "${REGION}" "${KILLSWITCH_ZIP}" "s3://${BOOT_BUCKET}/${KILLSWITCH_KEY}"
echo "    uploaded s3://${BOOT_BUCKET}/${KILLSWITCH_KEY}"

BUDGET_STACK="${CLUSTER_NAME}-budget"
echo "==> deploying budget stack ${BUDGET_STACK}"
aws cloudformation deploy \
  --stack-name "${BUDGET_STACK}" \
  --template-file "${REPO_DIR}/infra/budget.yaml" \
  --parameter-overrides \
      ClusterName="${CLUSTER_NAME}" \
      ClassTag="${CLASS_TAG}" \
      MonthlyBudgetUsd="${MONTHLY_BUDGET_USD}" \
      AlertEmail="${ALERT_EMAIL}" \
      LambdaCodeBucket="${BOOT_BUCKET}" \
      LambdaCodeKey="${KILLSWITCH_KEY}" \
  --region "${REGION}" \
  --capabilities CAPABILITY_NAMED_IAM

# ============================================================================
# 6. Deploy auto-teardown stack (design divergence D1; Requirement 22.1)
#
# Arms a one-time EventBridge schedule that fires at the MLCB EndDateTime and
# invokes a Lambda which deletes the pcluster + budget stacks (never the parent
# stack or EFS). Reached only on the full deploy path: --parent-only exits
# before the budget stack above, so this step is skipped there too.
# ============================================================================
echo "==> packaging auto-teardown Lambda"
TEARDOWN_ZIP="/tmp/${CLUSTER_NAME}-auto_teardown.zip"
rm -f "${TEARDOWN_ZIP}"
(cd "${REPO_DIR}/lambda/auto_teardown" && zip -q -r "${TEARDOWN_ZIP}" . -x "*.pyc" "__pycache__/*" "README.md")
TEARDOWN_KEY="lambda/auto_teardown-$(date +%Y%m%d-%H%M%S).zip"
aws s3 cp --region "${REGION}" "${TEARDOWN_ZIP}" "s3://${BOOT_BUCKET}/${TEARDOWN_KEY}"
echo "    uploaded s3://${BOOT_BUCKET}/${TEARDOWN_KEY}"

# Normalize the MLCB EndDate captured during MLCB validation to the
# YYYY-MM-DDTHH:MM:SS UTC format the template's MlcbEndTimeUtc AllowedPattern
# requires. EC2 returns EndDate in UTC; grab the leading date+time and drop any
# fractional seconds / timezone suffix (.000Z, Z, or +00:00). A reservation
# with EndDateType=unlimited has no EndDate, so there is nothing to schedule.
MLCB_END_UTC=$(printf '%s' "${cr_end_raw:-}" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}' || true)
if [[ -z "${MLCB_END_UTC}" ]]; then
  echo "    WARNING: MLCB ${CR_ID} has no usable EndDate (got '${cr_end_raw:-<none>}');" >&2
  echo "    skipping auto-teardown stack. Tear down manually with scripts/teardown.sh." >&2
else
  TEARDOWN_STACK="${CLUSTER_NAME}-auto-teardown"
  echo "==> deploying auto-teardown stack ${TEARDOWN_STACK} (fires at ${MLCB_END_UTC} UTC)"
  aws cloudformation deploy \
    --stack-name "${TEARDOWN_STACK}" \
    --template-file "${REPO_DIR}/infra/auto-teardown.yaml" \
    --parameter-overrides \
        ClusterName="${CLUSTER_NAME}" \
        ClassTag="${CLASS_TAG}" \
        MlcbEndTimeUtc="${MLCB_END_UTC}" \
        PClusterStackName="${PC_CLUSTER_NAME}" \
        BudgetStackName="${BUDGET_STACK}" \
        ParentStackName="${PARENT_STACK}" \
        LambdaCodeBucket="${BOOT_BUCKET}" \
        LambdaCodeKey="${TEARDOWN_KEY}" \
    --region "${REGION}" \
    --capabilities CAPABILITY_NAMED_IAM
fi

# ============================================================================
# 7. Print next steps
# ============================================================================
HEAD_DNS=$(pcluster describe-cluster --cluster-name "${PC_CLUSTER_NAME}" --region "${REGION}" 2>/dev/null | jq -r '.headNode.publicIpAddress // "<unknown>"' 2>/dev/null || echo "<unknown>")

# Patch the TA manifest's login hints with the real head-node DNS now that the
# cluster exists (design divergence D2; Requirement 8.6). The Manifest Lambda
# ran during PARENT-stack creation, before the head node existed, so each
# student's login_hint still ends in the literal `<head-node-public-dns>`
# placeholder. This is reached only on the full deploy path: --parent-only exits
# in section 4 above (no head node), so the patch is naturally skipped there.
# Non-fatal: the cluster is already up, so a patch failure only means the TA
# manifest keeps the placeholder (re-runnable via update-manifest-head-dns.sh).
if [[ -n "${HEAD_DNS}" && "${HEAD_DNS}" != "<unknown>" && "${HEAD_DNS}" != "None" ]]; then
  echo "==> patching manifest login hints with head DNS ${HEAD_DNS}"
  "${REPO_DIR}/scripts/update-manifest-head-dns.sh" \
    --cluster-name "${CLUSTER_NAME}" --region "${REGION}" --head-dns "${HEAD_DNS}" \
    || echo "    WARN: manifest login-hint patch failed; TA manifest still carries the <head-node-public-dns> placeholder"
else
  echo "==> skipping manifest login-hint patch: head-node DNS not resolved (${HEAD_DNS:-<empty>})"
fi

echo ""
echo "============================================================"
echo "Deploy complete."
echo "  Cluster:       ${PC_CLUSTER_NAME}"
echo "  Region:        ${REGION}"
echo "  Head node IP:  ${HEAD_DNS}"
echo "  Students:      ${STUDENT_COUNT} (usernames ${USERNAME_PREFIX}01..${USERNAME_PREFIX}$(printf %02d "${STUDENT_COUNT}"))"
echo "  MLCB:          ${CR_ID} (${cr_count} instances in ${cr_az})"
echo "  Class tag:     ${CLASS_TAG}"
echo "  Neuron AMI:    ${NEURON_AMI_ID} (${NEURON_AMI_SOURCE})"
echo "  Neuron SDK:    ${NEURON_SDK_VERSION}"
echo "  Per-student:   wall=${MAX_WALL_TIME} concurrent-jobs=${MAX_CONCURRENT_JOBS_PER_USER} cores=${MAX_CORES_PER_USER} core-hours=${CORE_HOURS_BUDGET}"
echo "  Slurm acct DB: head-node-local MariaDB (slurm@127.0.0.1:3306; enables Req-18 enforcement; secret ${SLURM_DB_SECRET_ARN})"
echo "  Auto-teardown: ${TEARDOWN_STACK:-<skipped: no MLCB EndDate>} (fires ${MLCB_END_UTC:-n/a} UTC)"
echo ""
echo "Next steps:"
echo "  1. Confirm the SNS email subscription sent to ${ALERT_EMAIL}"
echo "  2. Activate the 'Class' cost allocation tag in the Billing console"
echo "     (takes ~24h to reflect in the budget filter)"
echo "  3. Fetch the TA manifest:"
echo "     scripts/fetch-manifest.sh --cluster-name ${CLUSTER_NAME} --region ${REGION} > manifest.json"
echo "  4. Distribute each student's row privately (Secrets Manager ARN + login hint)"
echo "  5. Post-deploy smoke tests:"
echo "     scripts/verify-cluster.sh --cluster-name ${CLUSTER_NAME} --region ${REGION}"
echo "============================================================"
