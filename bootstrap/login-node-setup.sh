#!/bin/bash
# login-node-setup.sh
#
# EC2 launch UserData for a STANDALONE AWS PCS login node (Phase 1 + Phase 3 of
# the PCS variant; see ../docs/design.md). Runs at FIRST BOOT as root via
# cloud-init. scripts/deploy-login-node.sh substitutes the placeholders at the
# top of this file (via sed on a temp copy, NOT this source) and hands the
# rendered script to `aws ec2 run-instances --user-data`.
#
# On AWS PCS the Slurm controller (slurmctld + slurmdbd) runs in a
# service-owned account, so there is NO head node the course kit owns. This
# login node is a self-managed EC2 that JOINS the managed cluster's Slurm as a
# submit host, giving students somewhere to `ssh` in and `sbatch`, and giving
# us somewhere to run `sacctmgr`.
#
# This reproduces the AWS-documented "standalone login node" flow:
#   https://docs.aws.amazon.com/pcs/latest/userguide/working-with_login-nodes_standalone.html
#   Step 3 (install Slurm):  .../working-with_ami_custom_install-slurm.html
#   Step 4 (store secret):   .../working-with_login-nodes_standalone_get-secret.html
#   Step 5 (configure sackd):.../working-with_login-nodes_standalone_configure-connection.html
# It is NOT yet live-validated on a real PCS cluster (see ../docs/design.md
# "OPEN ITEMS"). Content on AWS PCS behavior was summarized from AWS
# documentation and rephrased for compliance with licensing restrictions.
#
# Sections:
#   1. (optional) Mount EFS at /shared (amazon-efs-utils preferred; nfs4 fallback).
#   2. Install Slurm via the AWS PCS Slurm installer (idempotent; the PCS sample
#      AMI usually already ships it under /opt/aws/pcs/scheduler/slurm-<ver>/).
#   3. Retrieve + store the cluster auth secret to /etc/slurm/slurm.key.
#   4. Configure + start the `sackd` service (joins the managed slurmctld).
#   5. Harden IMDS (multiuser box — block non-root/non-slurm users from the
#      instance-profile credentials).
#   6. Create per-student POSIX users from the roster (SSH access + homes on /shared).
#   7. (Phase 3) sacctmgr: per-student QoS with MaxWall + MaxJobsPerUser ONLY.
#
# Idempotent: safe to re-run.

set -euo pipefail

# =============================================================================
# Placeholders — EMPTY/SAFE DEFAULTS so this file is valid standalone. The
# deploy script (scripts/deploy-login-node.sh) rewrites each of these lines
# in a rendered temp copy via `sed -e 's|^VAR=.*|VAR="value"|'` before base64
# UserData submission. Keep them as single, line-anchored assignments with no
# trailing inline comments so the sed anchors stay unambiguous.
# =============================================================================
PCS_SECRET_ARN=""
SLURMCTLD_IP=""
SLURMCTLD_PORT="6817"
AWS_REGION=""
STAGING_BUCKET=""
STUDENT_COUNT=""
EFS_FS_ID=""
MAX_WALL_TIME="1-00:00:00"
MAX_CONCURRENT_JOBS_PER_USER="8"
SLURM_VERSION="25.11"

# The AWS PCS Slurm installer lays Slurm down under this fixed path, keyed by
# the major.minor release line (e.g. slurm-25.11 even for a 25.11.7 build).
# sackd, sacctmgr and sinfo all live beneath it.
SLURM_DIR="/opt/aws/pcs/scheduler/slurm-${SLURM_VERSION}"
export PATH="${SLURM_DIR}/bin:${SLURM_DIR}/sbin:${PATH}"

export DEBIAN_FRONTEND=noninteractive

LOG=/var/log/trn-course-pcs-login-setup.log
# cloud-init also tees UserData output to /var/log/cloud-init-output.log; we
# keep our own log for easy grepping.
exec > >(tee -a "$LOG") 2>&1
echo "[trn-course-pcs] login-node-setup starting at $(date -u)"
echo "[trn-course-pcs] hostname=$(hostname) region=${AWS_REGION} slurmctld=${SLURMCTLD_IP}:${SLURMCTLD_PORT} students=${STUDENT_COUNT:-<unset>}"

# -----------------------------------------------------------------------------
# retry <max> <label> <cmd...> — run <cmd> up to <max> times with linear
# backoff. Every network op (apt, curl, aws) is wrapped so a transient hiccup
# does not fail node bring-up on the first try. (Same helper shape as
# ../bootstrap/neuron-userdata.sh.)
# -----------------------------------------------------------------------------
retry() {
  local max="$1" label="$2"; shift 2
  local attempt=1
  while true; do
    if "$@"; then
      return 0
    fi
    if (( attempt >= max )); then
      echo "[trn-course-pcs] ERROR: '${label}' failed after ${max} attempts" >&2
      return 1
    fi
    echo "[trn-course-pcs] WARN: '${label}' failed (attempt ${attempt}/${max}); retrying in $(( attempt * 10 ))s..." >&2
    sleep $(( attempt * 10 ))
    (( attempt++ ))
  done
}

# -----------------------------------------------------------------------------
# 0. Prereqs
# -----------------------------------------------------------------------------
command -v aws >/dev/null 2>&1 || { echo "[trn-course-pcs] FATAL: aws CLI not present on the AMI" >&2; exit 1; }
if ! command -v jq >/dev/null 2>&1; then
  retry 5 "apt-get update (jq)" apt-get update || true
  retry 5 "install jq" apt-get install -y jq || { echo "[trn-course-pcs] FATAL: could not install jq" >&2; exit 1; }
fi

# -----------------------------------------------------------------------------
# 1. (optional) Mount EFS at /shared
# -----------------------------------------------------------------------------
# Only when --efs-id was supplied. Mirrors the compute-side EFS approach:
# amazon-efs-utils (adds TLS in-transit) preferred, plain nfs4 as a fallback,
# with an fstab entry so it survives reboot. Non-fatal: a login node without
# /shared can still provide SSH + sacctmgr; students just have no shared home.
# When EFS_FS_ID is empty we assume /shared is provided by Phase-4 EFS or is
# otherwise already mounted (the roster is then read from /shared/etc).
mount_shared_efs() {
  install -d -m 0755 /shared
  if mountpoint -q /shared; then
    echo "[trn-course-pcs] /shared already mounted; skipping EFS mount"
    return 0
  fi
  local efs_dns="${EFS_FS_ID}.efs.${AWS_REGION}.amazonaws.com"

  if ! command -v mount.efs >/dev/null 2>&1; then
    retry 3 "apt-get update (efs-utils)" apt-get update || true
    retry 3 "install amazon-efs-utils" apt-get install -y amazon-efs-utils || true
  fi

  if command -v mount.efs >/dev/null 2>&1; then
    grep -qE "[[:space:]]/shared[[:space:]]" /etc/fstab || \
      echo "${EFS_FS_ID}:/ /shared efs _netdev,tls 0 0" >> /etc/fstab
    mount /shared 2>/dev/null || mount -t efs -o tls "${EFS_FS_ID}:/" /shared || true
  else
    # nfs4 fallback (no in-transit TLS): needs nfs-common + the EFS mount-target DNS.
    retry 3 "install nfs-common" apt-get install -y nfs-common || true
    grep -qE "[[:space:]]/shared[[:space:]]" /etc/fstab || \
      echo "${efs_dns}:/ /shared nfs4 nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,_netdev 0 0" >> /etc/fstab
    mount /shared 2>/dev/null || mount -t nfs4 -o nfsvers=4.1 "${efs_dns}:/" /shared || true
  fi

  if mountpoint -q /shared; then
    echo "[trn-course-pcs] /shared mounted (efs=${EFS_FS_ID})"
  else
    echo "[trn-course-pcs] WARN: /shared did not mount (efs=${EFS_FS_ID}); continuing without it" >&2
  fi
  return 0
}

if [[ -n "${EFS_FS_ID}" ]]; then
  echo "[trn-course-pcs] mounting EFS ${EFS_FS_ID} at /shared"
  mount_shared_efs || echo "[trn-course-pcs] WARN: EFS mount step failed; continuing" >&2
else
  echo "[trn-course-pcs] no EFS_FS_ID supplied; expecting /shared from Phase-4 EFS or a pre-existing mount"
fi

# -----------------------------------------------------------------------------
# 2. Install Slurm via the AWS PCS Slurm installer
# -----------------------------------------------------------------------------
# https://docs.aws.amazon.com/pcs/latest/userguide/working-with_ami_custom_install-slurm.html
# The PCS sample AMI (dlami-base-ubuntu2404) usually already carries a
# PCS-compatible Slurm under ${SLURM_DIR}; if sackd is already present we skip
# the (multi-minute) download + compile. Otherwise we fetch the "latest" stable
# installer tarball for this release line from the regional PCS repo bucket,
# extract it, and run installer.sh -y (it downloads, compiles and installs
# Slurm + its dependencies).
install_slurm() {
  if [[ -x "${SLURM_DIR}/sbin/sackd" ]]; then
    echo "[trn-course-pcs] Slurm already installed at ${SLURM_DIR} (AMI ships it); skipping installer"
    return 0
  fi
  echo "[trn-course-pcs] installing Slurm ${SLURM_VERSION} via the AWS PCS installer"
  local tarball="aws-pcs-slurm-${SLURM_VERSION}-installer-latest.tar.gz"
  local url="https://aws-pcs-repo-${AWS_REGION}.s3.${AWS_REGION}.amazonaws.com/aws-pcs-slurm/${tarball}"
  local workdir="/tmp/aws-pcs-slurm-install"
  install -d -m 0755 "${workdir}"

  retry 5 "download Slurm installer" curl -fsSL "${url}" -o "${workdir}/${tarball}" \
    || { echo "[trn-course-pcs] FATAL: could not download the PCS Slurm installer from ${url}" >&2; return 1; }
  tar -xf "${workdir}/${tarball}" -C "${workdir}" \
    || { echo "[trn-course-pcs] FATAL: could not extract ${tarball}" >&2; return 1; }
  # The tarball extracts to a dir keyed by the release line (patch version dropped).
  local extracted="${workdir}/aws-pcs-slurm-${SLURM_VERSION}-installer"
  [[ -d "${extracted}" ]] || extracted="$(find "${workdir}" -maxdepth 1 -type d -name 'aws-pcs-slurm-*installer*' | head -n1)"
  if [[ -z "${extracted}" || ! -x "${extracted}/installer.sh" ]]; then
    echo "[trn-course-pcs] FATAL: installer.sh not found after extracting ${tarball}" >&2
    return 1
  fi
  ( cd "${extracted}" && ./installer.sh -y ) \
    || { echo "[trn-course-pcs] FATAL: PCS Slurm installer.sh failed" >&2; return 1; }
  echo "[trn-course-pcs] Slurm installed; version file:"
  cat "${SLURM_DIR}/version" 2>/dev/null || true
  return 0
}

if ! install_slurm; then
  echo "[trn-course-pcs] FATAL: Slurm install failed; login node cannot join the cluster" >&2
  exit 1
fi

# Ensure the slurm user + group exist (installer normally creates them; be
# defensive so sackd's User=slurm/Group=slurm and the slurm.key ownership work).
getent group slurm >/dev/null 2>&1 || groupadd -r slurm
id -u slurm >/dev/null 2>&1 || useradd -r -g slurm -d /var/lib/slurm -s /usr/sbin/nologin slurm

# -----------------------------------------------------------------------------
# 3. Retrieve + store the cluster auth secret
# -----------------------------------------------------------------------------
# https://docs.aws.amazon.com/pcs/latest/userguide/working-with_login-nodes_standalone_get-secret.html
# The AWS PCS cluster's shared Slurm auth key is stored (base64) in Secrets
# Manager; sackd reads it from /etc/slurm/slurm.key (0600 slurm:slurm). The
# instance profile grants secretsmanager:GetSecretValue on exactly this ARN.
install -d -m 0755 /etc/slurm
if [[ -n "${PCS_SECRET_ARN}" ]]; then
  retry 5 "fetch+store cluster secret" bash -c "set -o pipefail; aws secretsmanager get-secret-value --region '${AWS_REGION}' --secret-id '${PCS_SECRET_ARN}' --version-stage AWSCURRENT --query SecretString --output text | base64 -d > /etc/slurm/slurm.key" \
    || { echo "[trn-course-pcs] FATAL: could not retrieve/store the cluster secret" >&2; exit 1; }
  chmod 0600 /etc/slurm/slurm.key
  chown slurm:slurm /etc/slurm/slurm.key
  echo "[trn-course-pcs] stored cluster secret to /etc/slurm/slurm.key (0600 slurm:slurm)"
else
  echo "[trn-course-pcs] WARN: PCS_SECRET_ARN is empty; sackd will not be able to authenticate" >&2
fi

# -----------------------------------------------------------------------------
# 4. Configure + start the sackd service
# -----------------------------------------------------------------------------
# https://docs.aws.amazon.com/pcs/latest/userguide/working-with_login-nodes_standalone_configure-connection.html
# sackd (Slurm Auth and Cred Kiosk Daemon) fetches the cluster's Slurm config
# from the controller and provides auth creds so the local sinfo/sbatch/sacctmgr
# talk to the managed slurmctld/slurmdbd. Ubuntu has no /etc/sysconfig by
# default, so create it. The unit follows the AWS-documented sackd.service.
install -d -m 0755 /etc/sysconfig
echo "SACKD_OPTIONS='--conf-server=${SLURMCTLD_IP}:${SLURMCTLD_PORT}'" > /etc/sysconfig/sackd

# NOTE: unquoted heredoc so ${SLURM_DIR} expands now, but the runtime shell
# vars $SACKD_OPTIONS / $MAINPID are escaped so systemd (not this script)
# resolves them.
cat > /etc/systemd/system/sackd.service <<EOF
[Unit]
Description=Slurm auth and cred kiosk daemon
After=network-online.target remote-fs.target
Wants=network-online.target
ConditionPathExists=/etc/sysconfig/sackd

[Service]
Type=notify
EnvironmentFile=/etc/sysconfig/sackd
User=slurm
Group=slurm
RuntimeDirectory=slurm
RuntimeDirectoryMode=0755
ExecStart=${SLURM_DIR}/sbin/sackd --systemd \$SACKD_OPTIONS
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=process
LimitNOFILE=131072
LimitMEMLOCK=infinity
LimitSTACK=infinity

[Install]
WantedBy=multi-user.target
EOF
chown root:root /etc/systemd/system/sackd.service
chmod 0644 /etc/systemd/system/sackd.service

systemctl daemon-reload
if systemctl enable --now sackd 2>/dev/null; then
  echo "[trn-course-pcs] sackd enabled + started (--conf-server=${SLURMCTLD_IP}:${SLURMCTLD_PORT})"
else
  echo "[trn-course-pcs] WARN: sackd did not start cleanly; check 'journalctl -u sackd' and controller reachability" >&2
fi

# -----------------------------------------------------------------------------
# 5. Harden IMDS access on this MULTIUSER login node
# -----------------------------------------------------------------------------
# !!! SECURITY (AWS multiuser-login-node warning) !!!
# Any user who can reach the Instance Metadata Service (169.254.169.254) can
# borrow THIS instance's IAM role — including re-fetching the cluster secret
# (PCS_SECRET_ARN) and impersonating slurm or other students. Because this box
# hosts many student shell users, we (a) require IMDSv2 with a low hop limit at
# launch (set by deploy-login-node.sh) AND (b) block all non-root / non-slurm
# users from reaching the IMDS IP with an iptables owner-match rule. Root and
# slurm are allowed so this bootstrap and sackd keep working.
harden_imds() {
  if ! command -v iptables >/dev/null 2>&1; then
    retry 3 "install iptables" apt-get install -y iptables || { echo "[trn-course-pcs] WARN: iptables unavailable; cannot harden IMDS" >&2; return 0; }
  fi
  local slurm_uid; slurm_uid="$(id -u slurm 2>/dev/null || echo)"

  # ACCEPT rules are INSERTED at the top (so they always precede the DROP even
  # if a prior partial run appended the DROP first); the DROP is appended. Each
  # is guarded with -C so re-runs are idempotent (no duplicate rules).
  iptables -C OUTPUT -d 169.254.169.254 -m owner --uid-owner 0 -j ACCEPT 2>/dev/null \
    || iptables -I OUTPUT 1 -d 169.254.169.254 -m owner --uid-owner 0 -j ACCEPT
  if [[ -n "${slurm_uid}" ]]; then
    iptables -C OUTPUT -d 169.254.169.254 -m owner --uid-owner "${slurm_uid}" -j ACCEPT 2>/dev/null \
      || iptables -I OUTPUT 2 -d 169.254.169.254 -m owner --uid-owner "${slurm_uid}" -j ACCEPT
  fi
  iptables -C OUTPUT -d 169.254.169.254 -j DROP 2>/dev/null \
    || iptables -A OUTPUT -d 169.254.169.254 -j DROP

  # Best-effort persistence across reboots (restored by netfilter-persistent if
  # installed). Non-fatal if the tooling is absent.
  install -d -m 0755 /etc/iptables
  iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

  # NOTE: the IMDSv6 endpoint (fd00:ec2::254) is not exposed unless the ENI has
  # IPv6; IMDSv2 + hop-limit 2 (set at launch) is the primary control there.
  echo "[trn-course-pcs] IMDS hardened: only uid 0 and slurm(${slurm_uid:-n/a}) may reach 169.254.169.254"
  return 0
}
harden_imds || echo "[trn-course-pcs] WARN: IMDS hardening step failed; review before opening to students" >&2

# -----------------------------------------------------------------------------
# 6. Create per-student POSIX users from the roster
# -----------------------------------------------------------------------------
# Per-student account setup: fetch the roster, useradd -M with a fixed UID and
# home on /shared, install authorized_keys from the roster, publish the
# canonical /shared/etc/passwd.roster, and harden sshd.
# Roster source: s3://${STAGING_BUCKET}/roster/roster.json when a staging bucket
# was given (read via the instance profile's AmazonS3ReadOnlyAccess, as root, so
# the section-5 IMDS rule still permits it); otherwise /shared/etc/passwd.roster
# published by Phase-4 EFS.
ROSTER_JSON=/root/roster.json
if [[ -n "${STAGING_BUCKET}" ]]; then
  echo "[trn-course-pcs] fetching roster from s3://${STAGING_BUCKET}/roster/roster.json"
  retry 5 "download roster.json" aws s3 cp --region "${AWS_REGION}" \
    "s3://${STAGING_BUCKET}/roster/roster.json" "${ROSTER_JSON}" \
    || echo "[trn-course-pcs] WARN: could not fetch roster from S3" >&2
elif [[ -s /shared/etc/passwd.roster ]]; then
  echo "[trn-course-pcs] using roster from /shared/etc/passwd.roster"
  cp /shared/etc/passwd.roster "${ROSTER_JSON}"
else
  echo "[trn-course-pcs] WARN: no roster source (no --staging-bucket and no /shared/etc/passwd.roster); skipping student user creation" >&2
fi

if [[ -s "${ROSTER_JSON}" ]]; then
  STUDENTS_IN_ROSTER=$(jq 'length' "${ROSTER_JSON}" 2>/dev/null || echo 0)
  echo "[trn-course-pcs] roster has ${STUDENTS_IN_ROSTER} students (requested student-count=${STUDENT_COUNT:-<unset>})"

  # Shared skeleton (harmless if /shared is a local dir when EFS is absent).
  install -d -m 755 /shared/home
  install -d -m 755 /shared/work
  install -d -m 755 /shared/assignments
  install -d -m 755 /shared/etc

  # Each roster entry: {username, uid, public_key_openssh}
  jq -c '.[]' "${ROSTER_JSON}" | while read -r entry; do
    USERNAME=$(echo "${entry}" | jq -r '.username')
    UID_NUM=$(echo "${entry}" | jq -r '.uid')
    PUBKEY=$(echo "${entry}" | jq -r '.public_key_openssh')

    if ! [[ "${USERNAME}" =~ ^[a-z][a-z0-9_-]{1,31}$ ]]; then
      echo "[trn-course-pcs] skipping invalid username: ${USERNAME}"; continue
    fi
    if ! [[ "${UID_NUM}" =~ ^[0-9]+$ ]] || (( UID_NUM < 10000 )); then
      echo "[trn-course-pcs] skipping invalid uid: ${UID_NUM}"; continue
    fi

    HOME_DIR="/shared/home/${USERNAME}"
    WORK_DIR="/shared/work/${USERNAME}"

    # Fixed UID + home on /shared. -M avoids copying /etc/skel over EFS here; we
    # seed skel explicitly below only when the home is newly created so re-runs
    # do not clobber student edits.
    if ! id -u "${USERNAME}" >/dev/null 2>&1; then
      useradd -M -u "${UID_NUM}" -d "${HOME_DIR}" -s /bin/bash "${USERNAME}"
      echo "[trn-course-pcs] created user ${USERNAME} (uid=${UID_NUM})"
    else
      echo "[trn-course-pcs] user ${USERNAME} already exists"
    fi

    # Add to the neuron group when present (created on compute nodes by
    # neuron-userdata.sh for /dev/neuron* access). Harmless/no-op if absent here.
    if getent group neuron >/dev/null 2>&1; then
      usermod -aG neuron "${USERNAME}" 2>/dev/null || true
    fi

    if [[ ! -d "${HOME_DIR}" ]]; then
      install -d -m 700 -o "${USERNAME}" -g "${USERNAME}" "${HOME_DIR}"
      (cd /etc/skel && tar cf - .) | (cd "${HOME_DIR}" && tar xf -) 2>/dev/null || true
      chown -R "${USERNAME}:${USERNAME}" "${HOME_DIR}"
    fi
    if [[ ! -d "${WORK_DIR}" ]]; then
      install -d -m 700 -o "${USERNAME}" -g "${USERNAME}" "${WORK_DIR}"
    fi

    # authorized_keys — always overwrite from the roster (source of truth).
    install -d -m 700 -o "${USERNAME}" -g "${USERNAME}" "${HOME_DIR}/.ssh"
    echo "${PUBKEY}" > "${HOME_DIR}/.ssh/authorized_keys"
    chown "${USERNAME}:${USERNAME}" "${HOME_DIR}/.ssh/authorized_keys"
    chmod 600 "${HOME_DIR}/.ssh/authorized_keys"
  done

  # Publish the canonical roster for compute-node sync (mode 644), matching the
  # parent kit's /shared/etc/passwd.roster contract.
  install -m 644 -o root -g root "${ROSTER_JSON}" /shared/etc/passwd.roster
  echo "[trn-course-pcs] published /shared/etc/passwd.roster"
fi

# sshd hardening (idempotent) — this is the student SSH entrypoint, so force
# pubkey-only and no root login. Ubuntu's unit is ssh.service (sshd is an
# alias on some releases); try both.
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
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true

# -----------------------------------------------------------------------------
# 7. (Phase 3) Per-student Slurm QoS + associations via sacctmgr
# -----------------------------------------------------------------------------
# PCS managed accounting (accounting mode STANDARD, enabled by deploy-pcs.sh)
# stands up slurmdbd in the service-owned account, so sacctmgr run HERE (over
# the sackd-provided config) persists — no local MariaDB is needed (unlike the
# parent ParallelCluster kit's head-node-local DB).
#
# !!! PHASE-2 LIMITATION — NO gres/TRES LIMITS ON PCS !!!
# On AWS PCS, `GresTypes`/`Gres` are NOT in the cluster-level OR compute-node-
# group custom Slurm settings allowlists, so `neuroncore` CANNOT be a Slurm GRES
# or a tracked TRES on PCS. Therefore the student QoS carries MaxWall and
# MaxJobsPerUser ONLY. We deliberately DO NOT set MaxTRESPerUser=gres/neuroncore
# and DO NOT set GrpTRESMins=gres/neuroncore (the parent kit's per-core and
# core-hours caps) — they cannot work here. See ../docs/design.md "Phase 2".
#
# All sacctmgr calls are guarded/non-fatal (|| true) and idempotent (add, then
# modify ... set) so re-runs update limits in place.
SACCTMGR="$(command -v sacctmgr || echo "${SLURM_DIR}/bin/sacctmgr")"

# Give sackd/the controller a moment to become reachable before configuring
# accounting (best-effort; non-fatal).
if command -v sinfo >/dev/null 2>&1 || [[ -x "${SLURM_DIR}/bin/sinfo" ]]; then
  for _ in {1..12}; do
    if sinfo >/dev/null 2>&1; then break; fi
    echo "[trn-course-pcs] waiting for the Slurm controller to become reachable..."
    sleep 5
  done
fi

if [[ -x "${SACCTMGR}" ]]; then
  echo "[trn-course-pcs] configuring student-qos: MaxWall=${MAX_WALL_TIME} MaxJobsPerUser=${MAX_CONCURRENT_JOBS_PER_USER} (NO gres/TRES limits on PCS)"

  # 7a. Account (idempotent).
  "${SACCTMGR}" -i add account trn-course \
    Description="Trainium course students" Organization="course" 2>/dev/null || true

  # 7b. QoS carrying ONLY the PCS-supported per-user caps (wall clock + running
  #     job count). No MaxTRESPerUser / GrpTRESMins — see the Phase-2 note above.
  "${SACCTMGR}" -i add qos student-qos 2>/dev/null || true
  "${SACCTMGR}" -i modify qos student-qos set \
    MaxWall="${MAX_WALL_TIME}" \
    MaxJobsPerUser="${MAX_CONCURRENT_JOBS_PER_USER}" 2>/dev/null || true

  # 7c. Point the account (and thus its child user associations) at student-qos.
  "${SACCTMGR}" -i modify account trn-course set \
    QOS=student-qos DefaultQOS=student-qos 2>/dev/null || true

  # 7d. Each student: ensure the association exists under trn-course and pin it
  #     to student-qos. (No per-student GrpTRESMins core-hours budget — that is
  #     a gres/neuroncore TRES limit, unavailable on PCS.)
  if [[ -s "${ROSTER_JSON}" ]]; then
    jq -r '.[].username' "${ROSTER_JSON}" | while read -r USERNAME; do
      [[ "${USERNAME}" =~ ^[a-z][a-z0-9_-]{1,31}$ ]] || continue
      "${SACCTMGR}" -i add user "${USERNAME}" \
        Account=trn-course DefaultAccount=trn-course 2>/dev/null || true
      "${SACCTMGR}" -i modify user name="${USERNAME}" account=trn-course set \
        QOS=student-qos DefaultQOS=student-qos 2>/dev/null || true
    done
  fi
else
  echo "[trn-course-pcs] WARN: sacctmgr not found at ${SACCTMGR}; skipping per-student QoS (accounting may be off)" >&2
fi

echo "[trn-course-pcs] login-node-setup done at $(date -u)"
echo "[trn-course-pcs] verify from this node with: sinfo   (should list the PCS partitions, e.g. 'nki')"
