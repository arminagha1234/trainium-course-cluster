#!/usr/bin/env bash
# head-node-setup.sh
#
# Runs on the head node during ParallelCluster's OnNodeConfigured phase.
# Executes as root.
#
# Responsibilities:
#   1. Pull the student roster (usernames + UIDs + public SSH keys) from S3.
#   2. Create each POSIX student on the head node with a fixed UID.
#   3. Create per-student home + work directories on EFS at /shared.
#   4. Install the student's authorized_keys so they can SSH in.
#   5. Publish a canonical /shared/etc/passwd.roster that compute nodes read.
#   6. Harden sshd for password auth off + root login off.
#   6.5 Attach the neuroncore GRES to ParallelCluster's OWN compute NodeName
#       line. PC deny-lists Gres/NodeName in CustomSlurmSettings, so we append
#       `Gres=neuroncore:N` to PC's generated partition conf directly and
#       restart slurmctld. Best-effort / non-fatal.
#   7. (Optional) Create a per-student Slurm QoS + associations enforcing the
#      per-student wall-time / concurrent-job / NeuronCore / core-hours limits
#      (when accounting is enabled).
#
# NOT here: the head-node-local MariaDB accounting DB + `slurm` MySQL user is
# provisioned EARLIER by bootstrap/head-node-db-setup.sh in the HeadNode
# OnNodeStart phase — before ParallelCluster's config_slurm_accounting chef
# recipe runs (that recipe starts slurmdbd during the cookbook converge and
# blocks on the DB being reachable). By the time THIS OnNodeConfigured script
# runs, slurmdbd is already up against that DB, so section 7's sacctmgr calls
# succeed.
#
# Args:
#   $1 = staging bucket name
#   $2 = AWS region
#   $3 = max wall time per job          (optional; env MAX_WALL_TIME wins)
#   $4 = max concurrent jobs per user   (optional; env MAX_CONCURRENT_JOBS_PER_USER wins)
#   $5 = max NeuronCores per user       (optional; env MAX_CORES_PER_USER wins)
#   $6 = per-student core-hours budget  (optional; env CORE_HOURS_BUDGET wins)
#   $7 = Slurm accounting DB password Secrets Manager ARN
#                                       (optional; env SLURM_DB_PASSWORD_SECRET_ARN
#                                       wins). RETAINED for positional-arg
#                                       stability only — this script no longer
#                                       provisions the DB (see the note above and
#                                       bootstrap/head-node-db-setup.sh).
#   $8 = NeuronCores per compute node   (optional; env NEURONCORE_COUNT wins).
#                                       Used by section 6.5 to append
#                                       `Gres=neuroncore:N` to ParallelCluster's
#                                       generated compute NodeName line so the
#                                       controller advertises the neuroncore gres.
#
# The per-student Slurm limit inputs ($3..$6) and the accounting DB password
# secret ARN ($7) may be supplied by environment variable (preferred) or
# positional arg; env wins, positional is the fallback, then a built-in sensible
# default ($3..$6) or "skip" (empty $7). scripts/deploy.sh supplies them.
#
# Idempotent: safe to re-run.

set -euo pipefail

# ParallelCluster installs the Slurm CLIs (sacctmgr, scontrol, ...) in
# /opt/slurm/bin, which is NOT on PATH during the OnNodeConfigured custom
# action. Put it on PATH so section 6.5 (systemctl/scontrol) and section 7
# (sacctmgr) can resolve their tools.
export PATH="/opt/slurm/bin:${PATH}"

STAGING_BUCKET="${1:?staging bucket required as $1}"
REGION="${2:?region required as $2}"

# -----------------------------------------------------------------------------
# Per-student Slurm limit inputs (design divergence D5; Requirement 18).
#
# Consumed by the QoS/associations block (section 7). The deploy orchestrator
# (scripts/deploy.sh, task 3.3) supplies them. Resolution order per value:
# environment variable (preferred) -> positional arg ($3..$6) -> built-in
# default, so head-node setup never breaks when a value is omitted.
#
#   MAX_WALL_TIME                 -> QoS   MaxWall (per-job wall clock)          [18.1, 18.4]
#   MAX_CONCURRENT_JOBS_PER_USER  -> QoS   MaxJobsPerUser (running jobs/student) [18.2, 18.6]
#   MAX_CORES_PER_USER            -> QoS   MaxTRESPerUser=gres/neuroncore        [18.3, 18.7]
#   CORE_HOURS_BUDGET             -> assoc GrpTRESMins=gres/neuroncore (x60)     [18.5]
#
# Formats: MAX_WALL_TIME is a Slurm time string ([days-]HH:MM:SS, or minutes);
# the other three are integers. CORE_HOURS_BUDGET is in core-hours; a value of
# 0 (or unset / non-integer) means "no budget" (unlimited) — the budget is an
# optional limit per Requirement 18.5.
MAX_WALL_TIME="${MAX_WALL_TIME:-${3:-1-00:00:00}}"
MAX_CONCURRENT_JOBS_PER_USER="${MAX_CONCURRENT_JOBS_PER_USER:-${4:-8}}"
MAX_CORES_PER_USER="${MAX_CORES_PER_USER:-${5:-4}}"
CORE_HOURS_BUDGET="${CORE_HOURS_BUDGET:-${6:-0}}"

# -----------------------------------------------------------------------------
# Slurm accounting DB password ARN (Requirement 18; divergence D5). Same
# env-wins, positional-fallback resolution style as the limits above.
#
#   SLURM_DB_PASSWORD_SECRET_ARN  -> Secrets Manager ARN of the MariaDB `slurm`
#                                    user's password (env or $7).
#
# The MariaDB accounting DB + `slurm` user are provisioned EARLIER, by
# bootstrap/head-node-db-setup.sh in the HeadNode OnNodeStart phase (which reads
# this same secret). THIS OnNodeConfigured script no longer consumes the ARN;
# it is parsed only to keep the OnNodeConfigured positional-arg contract stable
# (the pcluster config still passes 7 args). An empty value just means
# accounting is off. The DB user (`slurm`) and name (`slurm_acct_db`) constants
# now live only in head-node-db-setup.sh.
SLURM_DB_PASSWORD_SECRET_ARN="${SLURM_DB_PASSWORD_SECRET_ARN:-${7:-}}"

# -----------------------------------------------------------------------------
# NeuronCores per compute node (section 6.5). Same env-wins, positional-fallback
# resolution style. Consumed ONLY by section 6.5, which appends
# `Gres=neuroncore:${NEURONCORE_COUNT}` to ParallelCluster's generated compute
# NodeName line so slurmctld advertises the neuroncore gres (PC deny-lists
# Gres/NodeName for CustomSlurmSettings, so it cannot be attached via the
# rendered Slurm include). Empty / non-integer => section 6.5 logs and skips.
NEURONCORE_COUNT="${NEURONCORE_COUNT:-${8:-}}"

LOG=/var/log/trn-course-head-setup.log
exec > >(tee -a "$LOG") 2>&1
echo "[trn-course] head-node-setup starting at $(date -u)"
echo "[trn-course] bucket=${STAGING_BUCKET} region=${REGION}"

# -----------------------------------------------------------------------------
# 0. Prereqs
# -----------------------------------------------------------------------------

# Wait for /shared (EFS) to be mounted. PC generally mounts before this hook
# runs, but we check to be defensive.
for i in {1..30}; do
  if mountpoint -q /shared; then break; fi
  echo "[trn-course] waiting for /shared to mount..."
  sleep 2
done
if ! mountpoint -q /shared; then
  echo "[trn-course] FATAL: /shared is not a mountpoint after 60s" >&2
  exit 1
fi

# Ensure aws + jq are available.
command -v aws >/dev/null || { echo "aws CLI missing" >&2; exit 1; }
if ! command -v jq >/dev/null; then
  apt-get update -qq && apt-get install -y -qq jq
fi

# -----------------------------------------------------------------------------
# 1. Fetch the roster
# -----------------------------------------------------------------------------
ROSTER_JSON=/root/roster.json
aws s3 cp --region "${REGION}" \
  "s3://${STAGING_BUCKET}/roster/roster.json" "${ROSTER_JSON}"

if [[ ! -s "${ROSTER_JSON}" ]]; then
  echo "[trn-course] FATAL: roster.json empty or missing" >&2
  exit 1
fi

STUDENT_COUNT=$(jq 'length' "${ROSTER_JSON}")
echo "[trn-course] roster has ${STUDENT_COUNT} students"

# -----------------------------------------------------------------------------
# 2. Create shared skeleton on EFS
# -----------------------------------------------------------------------------
install -d -m 755 /shared/home
install -d -m 755 /shared/work
install -d -m 755 /shared/assignments        # TAs populate this later, RO to students
install -d -m 755 /shared/etc

# -----------------------------------------------------------------------------
# 3. Create students
# -----------------------------------------------------------------------------
# Each roster entry: {username, uid, public_key_openssh}
jq -c '.[]' "${ROSTER_JSON}" | while read -r entry; do
  USERNAME=$(echo "${entry}" | jq -r '.username')
  UID_NUM=$(echo "${entry}" | jq -r '.uid')
  PUBKEY=$(echo "${entry}" | jq -r '.public_key_openssh')

  # Sanity check
  if ! [[ "${USERNAME}" =~ ^[a-z][a-z0-9_-]{1,31}$ ]]; then
    echo "[trn-course] skipping invalid username: ${USERNAME}"; continue
  fi
  if ! [[ "${UID_NUM}" =~ ^[0-9]+$ ]] || (( UID_NUM < 10000 )); then
    echo "[trn-course] skipping invalid uid: ${UID_NUM}"; continue
  fi

  HOME_DIR="/shared/home/${USERNAME}"
  WORK_DIR="/shared/work/${USERNAME}"

  # Create the user with a fixed UID and home on /shared. -M avoids copying
  # /etc/skel over EFS the first time; we do it explicitly below so re-runs
  # do not overwrite user edits.
  if ! id -u "${USERNAME}" >/dev/null 2>&1; then
    useradd -M -u "${UID_NUM}" -d "${HOME_DIR}" -s /bin/bash "${USERNAME}"
    echo "[trn-course] created user ${USERNAME} (uid=${UID_NUM})"
  else
    echo "[trn-course] user ${USERNAME} already exists"
  fi

  # Home dir (create if new)
  if [[ ! -d "${HOME_DIR}" ]]; then
    install -d -m 700 -o "${USERNAME}" -g "${USERNAME}" "${HOME_DIR}"
    # Copy skeleton so bash finds .profile etc.
    (cd /etc/skel && tar cf - .) | (cd "${HOME_DIR}" && tar xf -) 2>/dev/null || true
    chown -R "${USERNAME}:${USERNAME}" "${HOME_DIR}"
  fi

  # Work dir
  if [[ ! -d "${WORK_DIR}" ]]; then
    install -d -m 700 -o "${USERNAME}" -g "${USERNAME}" "${WORK_DIR}"
  fi

  # authorized_keys — always overwrite from roster (source of truth)
  install -d -m 700 -o "${USERNAME}" -g "${USERNAME}" "${HOME_DIR}/.ssh"
  echo "${PUBKEY}" > "${HOME_DIR}/.ssh/authorized_keys"
  chown "${USERNAME}:${USERNAME}" "${HOME_DIR}/.ssh/authorized_keys"
  chmod 600 "${HOME_DIR}/.ssh/authorized_keys"
done

# -----------------------------------------------------------------------------
# 4. Publish canonical roster for compute-node sync
# -----------------------------------------------------------------------------
# Write a mode-644 copy of the roster JSON that compute nodes read via
# /shared (EFS is faster than S3 for the sync path and works without S3 IAM
# on the compute side).
install -m 644 -o root -g root "${ROSTER_JSON}" /shared/etc/passwd.roster

# -----------------------------------------------------------------------------
# 5. Publish MOTD + student-facing helpers
# -----------------------------------------------------------------------------
cat >/etc/motd <<'MOTD'
================================================================================
 Trainium Course Cluster
================================================================================
 - Submit jobs with: sbatch --gres=neuroncore:1 run.sh
 - Your work dir:    /shared/work/$USER
 - Your assignments: /shared/assignments (read-only)
 - Job logs land in: /shared/work/$USER/<assignment>/<jobid>/

 Compute is shared: 4 NeuronCores per node. Please stop stopping jobs early.
 See ~/RUNBOOK.md or student-runbook.md in the repo for details.

 SECURITY NOTE: NKI is not a secure sandbox. Peers on the same compute node
 can inspect device memory. Don't put credentials or private data in kernels.
================================================================================
MOTD

# Copy the student runbook and job template into each student's home. Idempotent:
# only writes if the file doesn't already exist so student edits are preserved.
if aws s3 ls --region "${REGION}" "s3://${STAGING_BUCKET}/student/" >/dev/null 2>&1; then
  TMP=$(mktemp -d)
  aws s3 sync --region "${REGION}" "s3://${STAGING_BUCKET}/student/" "${TMP}/"
  jq -r '.[].username' "${ROSTER_JSON}" | while read -r USERNAME; do
    HOME_DIR="/shared/home/${USERNAME}"
    [[ -d "${HOME_DIR}" ]] || continue
    for f in RUNBOOK.md run.sh; do
      if [[ -f "${TMP}/${f}" && ! -f "${HOME_DIR}/${f}" ]]; then
        install -m 644 -o "${USERNAME}" -g "${USERNAME}" "${TMP}/${f}" "${HOME_DIR}/${f}"
      fi
    done
    # run.sh needs to be executable
    [[ -f "${HOME_DIR}/run.sh" ]] && chmod +x "${HOME_DIR}/run.sh"
  done
  rm -rf "${TMP}"
fi

# -----------------------------------------------------------------------------
# 6. sshd hardening (idempotent)
# -----------------------------------------------------------------------------
# PC's default sshd_config disables password auth already. Belt-and-braces.
SSHD_CONF=/etc/ssh/sshd_config
harden_line() {
  local key="$1" val="$2"
  if grep -qE "^\s*${key}\b" "${SSHD_CONF}"; then
    sed -i -E "s|^\s*${key}\b.*|${key} ${val}|" "${SSHD_CONF}"
  else
    echo "${key} ${val}" >> "${SSHD_CONF}"
  fi
}
harden_line "PasswordAuthentication" "no"
harden_line "PermitRootLogin" "no"
harden_line "PubkeyAuthentication" "yes"
harden_line "ChallengeResponseAuthentication" "no"
systemctl reload sshd

# -----------------------------------------------------------------------------
# 6.5 Attach neuroncore GRES to ParallelCluster's own NodeName line
# -----------------------------------------------------------------------------
# ParallelCluster generates its OWN `NodeName=<queue>-st-<resource>-N ...` line
# for each static compute node in
# /opt/slurm/etc/pcluster/slurm_parallelcluster_<queue>_partition.conf, and it
# DENY-LISTS `Gres`/`NodeName`/`Features` for CustomSlurmSettings — so the
# neuroncore gres CANNOT be attached via the rendered Slurm include. Instead we
# append `Gres=neuroncore:${NEURONCORE_COUNT}` to PC's EXISTING NodeName line(s)
# here on the controller and restart slurmctld so it registers the gres. The
# compute bootstrap does the same on the slurmd side, because PC is NOT
# configless (no enable_configless in SlurmctldParameters) — each node reads its
# own local config copy, so both the controller and slurmd must carry the gres.
#
# NOTE: this edits a PC-GENERATED file. That is acceptable for a create-once,
# static CAPACITY_BLOCK cluster; a `pcluster update-cluster` could rewrite the
# partition conf and drop the edit (re-running this script re-applies it).
#
# The WHOLE step is best-effort / NON-FATAL: a usable cluster without the gres
# attached beats a failed head-node bootstrap, so any failure logs loudly but
# does not abort setup.
attach_neuroncore_gres() {
  # Guard: need a positive integer core count, else skip (non-fatal).
  if ! [[ "${NEURONCORE_COUNT}" =~ ^[0-9]+$ ]] || (( NEURONCORE_COUNT <= 0 )); then
    echo "[trn-course] WARNING: NEURONCORE_COUNT='${NEURONCORE_COUNT:-<unset>}' is not a positive integer; skipping neuroncore gres attach" >&2
    return 0
  fi

  # Find PC's generated partition conf file(s).
  local -a conf_files=()
  local f
  shopt -s nullglob
  for f in /opt/slurm/etc/pcluster/slurm_parallelcluster_*partition*.conf; do
    conf_files+=("${f}")
  done
  shopt -u nullglob
  # Fallback: any pcluster conf that actually declares NodeName lines.
  if (( ${#conf_files[@]} == 0 )); then
    while IFS= read -r f; do
      [[ -n "${f}" ]] && conf_files+=("${f}")
    done < <(grep -l '^NodeName=' /opt/slurm/etc/pcluster/*.conf 2>/dev/null || true)
  fi
  if (( ${#conf_files[@]} == 0 )); then
    echo "[trn-course] WARNING: no ParallelCluster partition conf with a NodeName line found under /opt/slurm/etc/pcluster; cannot attach neuroncore gres" >&2
    return 1
  fi

  # For each conf, append ` Gres=neuroncore:N` to NodeName lines that do NOT
  # already carry it (idempotent — the /Gres=neuroncore/! guard skips re-runs).
  for f in "${conf_files[@]}"; do
    echo "[trn-course] attaching Gres=neuroncore:${NEURONCORE_COUNT} to NodeName lines in ${f}"
    sed -i.bak -E "/^NodeName=/ { /Gres=neuroncore/! s/$/ Gres=neuroncore:${NEURONCORE_COUNT}/ }" "${f}"
  done

  # Restart slurmctld so it re-reads the NodeName gres (a reconfigure alone may
  # not apply NodeName gres changes). Safe here: no jobs are running yet. Guard
  # on the unit actually existing.
  if systemctl cat slurmctld >/dev/null 2>&1; then
    systemctl restart slurmctld
    echo "[trn-course] restarted slurmctld to register neuroncore gres"
  else
    echo "[trn-course] slurmctld unit not present; skipping restart (PC will start it and read the edited conf)"
  fi
  return 0
}

if ! attach_neuroncore_gres; then
  echo "[trn-course] WARNING: neuroncore gres attach failed; continuing head-node setup (cluster is usable without the gres; fix later)" >&2
fi

# -----------------------------------------------------------------------------
# 7. Per-student Slurm QoS + associations (design divergence D5; Requirement 18)
# -----------------------------------------------------------------------------
# Create a single "student-qos" carrying the per-student caps and attach every
# student association to it, so slurmctld gates submissions on:
#   - MaxWall            per-job wall-clock limit                  (18.1, 18.4)
#   - MaxJobsPerUser     concurrent running jobs per student       (18.2, 18.6)
#   - MaxTRESPerUser     max NeuronCores per student               (18.3, 18.7)
#   - GrpTRESMins        per-student core-hours budget             (18.5)
#
# Enforcement is turned on cluster-side by the rendered Slurm include
# (slurm/slurm.conf.d/neuroncore-gres.conf.template ->
# AccountingStorageEnforce=associations,limits,qos and
# AccountingStorageTRES=gres/neuroncore) and requires slurmdbd
# (SlurmSettings.Database in pcluster-config.yaml). When accounting is not
# active, sacctmgr just no-ops/errors and this block is inert — accounting is
# OPTIONAL, so every call stays guarded and non-fatal (|| true) as before.
#
# NOTE on the core-hours budget: a *per-student* budget must live on each
# student's association GrpTRESMins, NOT on the shared QoS. GrpTRESMins on a
# QoS is an aggregate cap across ALL users of that QoS, which would stall the
# whole class once the sum is reached — not the per-student semantics
# Requirement 18.5 mandates. So the naturally-per-user caps (MaxWall,
# MaxJobsPerUser, MaxTRESPerUser) go on the QoS and the core-hours budget goes
# on each association.
#
# Idempotent: "add" then "modify ... set" so re-runs update the limits in place
# rather than failing on already-existing entities.
# Resolve sacctmgr robustly: prefer PATH (now includes /opt/slurm/bin via the
# export at the top of this script), but fall back to the well-known PC install
# path so a stale PATH can never silently skip the whole per-student
# QoS/association block (the OnNodeConfigured bug this fixes).
SACCTMGR="$(command -v sacctmgr || echo /opt/slurm/bin/sacctmgr)"
if [[ -x "${SACCTMGR}" ]]; then
  # Core-hours budget -> GrpTRESMins is expressed in TRES-*minutes*, hence x60.
  # A non-positive / non-integer / unset budget means "no budget"; Slurm's -1
  # clears the limit (unlimited), which also keeps re-runs idempotent.
  if [[ "${CORE_HOURS_BUDGET}" =~ ^[0-9]+$ ]] && (( CORE_HOURS_BUDGET > 0 )); then
    BUDGET_TRESMINS="gres/neuroncore=$(( CORE_HOURS_BUDGET * 60 ))"
  else
    BUDGET_TRESMINS="gres/neuroncore=-1"
  fi

  echo "[trn-course] configuring student-qos:" \
       "MaxWall=${MAX_WALL_TIME}" \
       "MaxJobsPerUser=${MAX_CONCURRENT_JOBS_PER_USER}" \
       "MaxTRESPerUser=gres/neuroncore=${MAX_CORES_PER_USER}" \
       "assoc GrpTRESMins=${BUDGET_TRESMINS}"

  # 7a. Account (idempotent).
  "${SACCTMGR}" -i add account trn-course \
    Description="Trainium course students" Organization="course" 2>/dev/null || true

  # 7b. QoS carrying the naturally-per-user caps (create, then modify to set so
  #     limit changes on re-run are applied in place).
  "${SACCTMGR}" -i add qos student-qos 2>/dev/null || true
  "${SACCTMGR}" -i modify qos student-qos set \
    MaxWall="${MAX_WALL_TIME}" \
    MaxJobsPerUser="${MAX_CONCURRENT_JOBS_PER_USER}" \
    MaxTRESPerUser="gres/neuroncore=${MAX_CORES_PER_USER}" 2>/dev/null || true

  # 7c. Point the account (and thus its child user associations) at student-qos.
  "${SACCTMGR}" -i modify account trn-course set \
    QOS=student-qos DefaultQOS=student-qos 2>/dev/null || true

  # 7d. Each student: ensure the association exists under trn-course, pin it to
  #     student-qos, and set the per-student core-hours budget on the assoc.
  jq -r '.[].username' "${ROSTER_JSON}" | while read -r USERNAME; do
    "${SACCTMGR}" -i add user "${USERNAME}" \
      Account=trn-course DefaultAccount=trn-course 2>/dev/null || true
    "${SACCTMGR}" -i modify user name="${USERNAME}" account=trn-course set \
      QOS=student-qos DefaultQOS=student-qos GrpTRESMins="${BUDGET_TRESMINS}" 2>/dev/null || true
  done
fi

echo "[trn-course] head-node-setup done at $(date -u)"
