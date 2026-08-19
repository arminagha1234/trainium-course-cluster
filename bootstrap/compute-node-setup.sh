#!/usr/bin/env bash
# compute-node-setup.sh
#
# Runs on each Trn2 compute node during ParallelCluster's OnNodeConfigured
# phase. Executes as root under `set -euo pipefail` (no sudo needed).
#
# ParallelCluster allows exactly ONE OnNodeConfigured script per node, and on
# the compute queue that script is THIS one — there is no separate PC
# install_neuron.sh step. So this script installs the PUBLIC Neuron SDK +
# torch-neuronx itself, directly from the public Neuron apt/pip repositories
# (https://apt.repos.neuron.amazonaws.com, https://pip.repos.neuron.amazonaws.com);
# the compute subnet is private but the parent stack provides NAT egress + an
# S3 gateway endpoint, so those repos are reachable. It then performs the
# group/udev/gres/user setup.
#
# Responsibilities:
#   1. Install the public Neuron SDK from the public Neuron apt repo:
#      aws-neuronx-dkms (driver), -collectives, -runtime-lib, -tools; load the
#      neuron kernel module and confirm the /dev/neuron* device nodes appear.
#   2. Create a shared torch-neuronx venv at /opt/aws_neuronx_venv_pytorch
#      (neuronx-cc + torch-neuronx + torchvision, from the public Neuron pip
#      repo), world-readable so every student can `source` it from a job.
#   3. Create the `neuron` system group.
#   4. Write /etc/udev/rules.d/99-neuron.rules so the /dev/neuron* devices are
#      group-owned by `neuron` with mode 0660 (giving every group member device
#      access), then trigger udev.
#   5. Sync POSIX students from the /shared/etc/passwd.roster (created by
#      head-node-setup.sh). Each student gets:
#        - matching UID
#        - membership in the `neuron` group
#        - NO home directory on the compute node (jobs read/write /shared).
#   6. Write /etc/slurm/gres.conf declaring one neuroncore GRES entry per
#      /dev/neuron<N> device.
#   7. Restart slurmd so it re-registers with the new gres info.
#   8. Install a cron drop-in to re-sync users every 5 minutes (in case the
#      roster changes mid-cluster — e.g. late enrollment).
#
# Args:
#   $1 = staging bucket name  (unused today; kept for parity with head hook)
#   $2 = AWS region           (unused today; kept for parity)
#
# Idempotent: safe to re-run. If the torch-neuronx venv already imports, the
# SDK/venv install is skipped; the apt list/keyring, group, udev, gres, and
# user-sync steps are all safe to repeat.

set -euo pipefail

STAGING_BUCKET="${1:-}"
REGION="${2:-}"

LOG=/var/log/trn-course-compute-setup.log
exec > >(tee -a "$LOG") 2>&1
echo "[trn-course] compute-node-setup starting at $(date -u)"
echo "[trn-course] hostname=$(hostname) bucket=${STAGING_BUCKET} region=${REGION}"

# -----------------------------------------------------------------------------
# 0. Wait for /shared to mount (roster lives there)
# -----------------------------------------------------------------------------
for i in {1..30}; do
  if mountpoint -q /shared; then break; fi
  echo "[trn-course] waiting for /shared to mount..."
  sleep 2
done
if ! mountpoint -q /shared; then
  echo "[trn-course] FATAL: /shared is not a mountpoint after 60s" >&2
  exit 1
fi

# Ensure jq is available
if ! command -v jq >/dev/null; then
  apt-get update -qq && apt-get install -y -qq jq
fi

# -----------------------------------------------------------------------------
# 0b. Install the public Neuron SDK (driver + runtime + collectives + tools)
#     and a shared torch-neuronx venv, from the public Neuron apt/pip repos.
#
#     This runs BEFORE the neuron group / udev / gres sections below because
#     aws-neuronx-dkms is what creates the /dev/neuron* device nodes that those
#     sections chmod/enumerate.
#
#     Target platform (AWS Neuron SDK 2.x): Ubuntu 24.04 (VERSION_CODENAME
#     noble), Python 3.12, PyTorch 2.9. NKI ships inside neuronx-cc as
#     `neuronxcc.nki`. Neuron CLI tools install to /opt/aws/neuron/bin.
#
#     Multi-node note: this is a single-node course, so we do NOT install the
#     EFA driver. A multi-node cluster would additionally need `Efa: Enabled:
#     true` on the queue in infra/pcluster-config.yaml plus the aws-efa-installer
#     on each node. aws-neuronx-collectives is still installed here because it
#     is needed for intra-node multi-core collectives (e.g. run-multi-core.sh).
# -----------------------------------------------------------------------------
NEURON_VENV=/opt/aws_neuronx_venv_pytorch

# retry <max> <label> <cmd...> — run <cmd> with up to <max> attempts and an
# incremental (linear) backoff between tries. Every network op below (apt
# update/install, pip) is wrapped in this so a transient repo/network hiccup
# does not fail node bring-up on the first try.
retry() {
  local max="$1" label="$2"; shift 2
  local attempt=1
  while true; do
    if "$@"; then
      return 0
    fi
    if (( attempt >= max )); then
      echo "[trn-course] ERROR: '${label}' failed after ${max} attempts" >&2
      return 1
    fi
    echo "[trn-course] WARN: '${label}' failed (attempt ${attempt}/${max}); retrying in $(( attempt * 10 ))s..." >&2
    sleep $(( attempt * 10 ))
    (( attempt++ ))
  done
}

# Idempotency: if the shared venv already imports torch_neuronx, the SDK + venv
# are already in place — skip the (slow) install entirely on re-run.
if [[ -x "${NEURON_VENV}/bin/python" ]] && "${NEURON_VENV}/bin/python" -c "import torch_neuronx" >/dev/null 2>&1; then
  echo "[trn-course] Neuron SDK + torch-neuronx already present at ${NEURON_VENV}; skipping install"
else
  echo "[trn-course] installing public Neuron SDK + torch-neuronx"

  # --- Neuron apt repo via signed-by keyring --------------------------------
  # apt-key is deprecated/removed on Ubuntu 24.04, so use the keyring method.
  . /etc/os-release
  install -d -m 0755 /usr/share/keyrings
  retry 5 "fetch Neuron GPG key" bash -c 'set -o pipefail; curl -fsSL https://apt.repos.neuron.amazonaws.com/GPG-PUB-KEY-AMAZON-AWS-NEURON.PUB | gpg --dearmor -o /usr/share/keyrings/neuron-keyring.gpg' \
    || { echo "[trn-course] FATAL: could not install the Neuron apt GPG key" >&2; exit 1; }
  cat >/etc/apt/sources.list.d/neuron.list <<EOF
deb [signed-by=/usr/share/keyrings/neuron-keyring.gpg] https://apt.repos.neuron.amazonaws.com ${VERSION_CODENAME} main
EOF
  echo "[trn-course] configured Neuron apt repo for suite '${VERSION_CODENAME}'"

  # --- apt-get update + build prerequisites ---------------------------------
  retry 5 "apt-get update" apt-get update \
    || { echo "[trn-course] FATAL: apt-get update failed" >&2; exit 1; }

  # linux-headers are REQUIRED for the aws-neuronx-dkms kernel module build;
  # python3.12-venv is needed to create the venv; g++ + git per Neuron setup.
  retry 5 "install kernel headers + build deps" \
    apt-get install -y "linux-headers-$(uname -r)" git python3.12-venv g++ \
    || { echo "[trn-course] FATAL: could not install kernel headers / build deps" >&2; exit 1; }

  # Neuron driver + collectives + runtime + tools (all pinned to the 2.x line).
  # These are REQUIRED: a node without them cannot run NKI, so any package that
  # fails after retries fails the whole node (exit non-zero).
  for pkg in aws-neuronx-dkms aws-neuronx-collectives aws-neuronx-runtime-lib aws-neuronx-tools; do
    retry 5 "install ${pkg}" apt-get install -y "${pkg}=2.*" \
      || { echo "[trn-course] FATAL: required Neuron package ${pkg} failed to install" >&2; exit 1; }
  done
  echo "[trn-course] Neuron apt packages installed (CLI tools under /opt/aws/neuron/bin)"

  # --- Load the driver + wait for the device nodes to appear ----------------
  modprobe neuron 2>/dev/null || true
  echo "[trn-course] waiting up to ~60s for /dev/neuron* device nodes..."
  for _ in {1..30}; do
    if compgen -G "/dev/neuron[0-9]*" >/dev/null; then break; fi
    sleep 2
  done
  if compgen -G "/dev/neuron[0-9]*" >/dev/null; then
    echo "[trn-course] /dev/neuron* present: $(compgen -G '/dev/neuron[0-9]*' | tr '\n' ' ')"
  else
    # Not hard-fatal: the gres section (5) below already WARNs when it finds no
    # devices, and the node can still boot for diagnosis.
    echo "[trn-course] WARN: no /dev/neuron* devices after 60s; slurmd gres will be empty." >&2
  fi

  # --- Shared torch-neuronx venv at a FIXED, world-readable path ------------
  # slurm/job-templates/run.sh + run-multi-core.sh source this exact path.
  echo "[trn-course] creating shared Neuron venv at ${NEURON_VENV}"
  python3.12 -m venv "${NEURON_VENV}" \
    || { echo "[trn-course] FATAL: could not create venv ${NEURON_VENV}" >&2; exit 1; }
  retry 5 "pip upgrade" "${NEURON_VENV}/bin/pip" install --upgrade pip \
    || { echo "[trn-course] FATAL: pip upgrade failed in ${NEURON_VENV}" >&2; exit 1; }
  # Point the venv's pip at the public Neuron pip repo (neuronx-cc + torch-neuronx
  # are published there). Written into the venv's own pip config so every install
  # into this venv resolves them.
  "${NEURON_VENV}/bin/pip" config set global.extra-index-url https://pip.repos.neuron.amazonaws.com
  retry 5 "pip install neuronx-cc/torch-neuronx" \
    "${NEURON_VENV}/bin/pip" install "neuronx-cc==2.*" "torch-neuronx==2.9.*" torchvision \
    || { echo "[trn-course] FATAL: could not install neuronx-cc / torch-neuronx into ${NEURON_VENV}" >&2; exit 1; }
  # Make the whole venv world-readable + traversable so every student POSIX
  # user can source it (a+rX = read for files, read+traverse for directories).
  chmod -R a+rX "${NEURON_VENV}"
  echo "[trn-course] Neuron venv ready: source ${NEURON_VENV}/bin/activate"
fi

# -----------------------------------------------------------------------------
# 1. `neuron` group + udev rule (per Neuron security disclosure guidance)
#    https://awsdocs-neuron.readthedocs-hosted.com/en/latest/about-neuron/security.html
# -----------------------------------------------------------------------------
if ! getent group neuron >/dev/null; then
  groupadd -r neuron
  echo "[trn-course] created neuron group"
fi

UDEV_RULE=/etc/udev/rules.d/99-neuron.rules
cat >"${UDEV_RULE}" <<'RULE'
# Neuron device access control
# Only members of the 'neuron' group can access neuron devices.
SUBSYSTEM=="neuron*", KERNEL=="neuron*", GROUP="neuron", MODE="0660"
RULE

udevadm control --reload
udevadm trigger --subsystem-match=neuron || true

# -----------------------------------------------------------------------------
# 2. User sync from /shared/etc/passwd.roster
# -----------------------------------------------------------------------------
ROSTER=/shared/etc/passwd.roster

# The roster may lag behind the head node's user creation by a few seconds
# on first boot — head runs OnNodeConfigured in parallel with compute. Wait
# up to 5 min.
for i in {1..60}; do
  if [[ -s "${ROSTER}" ]]; then break; fi
  echo "[trn-course] waiting for ${ROSTER}..."
  sleep 5
done
if [[ ! -s "${ROSTER}" ]]; then
  echo "[trn-course] WARN: ${ROSTER} missing after 5 min. Continuing without users; cron sync will pick them up." >&2
fi

sync_users_from_roster() {
  local roster="$1"
  [[ -s "${roster}" ]] || return 0
  jq -c '.[]' "${roster}" | while read -r entry; do
    local username uid_num
    username=$(echo "${entry}" | jq -r '.username')
    uid_num=$(echo "${entry}" | jq -r '.uid')

    if ! [[ "${username}" =~ ^[a-z][a-z0-9_-]{1,31}$ ]]; then continue; fi
    if ! [[ "${uid_num}" =~ ^[0-9]+$ ]] || (( uid_num < 10000 )); then continue; fi

    if ! id -u "${username}" >/dev/null 2>&1; then
      # Match head-node semantics: no home on the compute node (jobs use /shared).
      useradd -M -u "${uid_num}" -d "/shared/home/${username}" -s /bin/bash "${username}"
    fi
    # Always ensure membership in the neuron group (idempotent)
    usermod -aG neuron "${username}" 2>/dev/null || true
  done
}

sync_users_from_roster "${ROSTER}"

# -----------------------------------------------------------------------------
# 3. gres.conf on this compute node
# -----------------------------------------------------------------------------
# Enumerate real Neuron device nodes at /dev/neuron*; write one Name=neuroncore
# entry per device. This is robust across trn2.3xlarge (4) and trn2.48xlarge
# (16) without a redeploy.
GRES_CONF=/etc/slurm/gres.conf
install -d -m 755 /etc/slurm

{
  echo "# Written by trn-course compute-node-setup at $(date -u)"
  for dev in /dev/neuron*; do
    [[ -e "${dev}" ]] || continue
    # Skip the "neuron_control" style pseudo-devices if any; we want the
    # per-core /dev/neuron<idx> nodes.
    if [[ "$(basename "${dev}")" =~ ^neuron[0-9]+$ ]]; then
      echo "Name=neuroncore File=${dev}"
    fi
  done
} > "${GRES_CONF}"

CORE_COUNT=$(grep -c '^Name=neuroncore' "${GRES_CONF}" || echo 0)
if (( CORE_COUNT == 0 )); then
  echo "[trn-course] WARN: no /dev/neuron<N> devices found. slurmd will not advertise neuroncore gres." >&2
else
  echo "[trn-course] wrote ${CORE_COUNT} neuroncore entries to ${GRES_CONF}"
fi

# -----------------------------------------------------------------------------
# 3b. Attach neuroncore GRES to ParallelCluster's own NodeName line (local copy)
# -----------------------------------------------------------------------------
# ParallelCluster owns the compute NodeName line — it generates
# /opt/slurm/etc/pcluster/slurm_parallelcluster_<queue>_partition.conf and
# deny-lists Gres/NodeName for CustomSlurmSettings, so the per-node gres cannot
# be set through the rendered Slurm include. PC is NOT configless, so THIS slurmd
# reads its OWN local config copy; we append `Gres=neuroncore:${CORE_COUNT}` to
# PC's NodeName line(s) here so slurmd's CONFIGURED gres agrees with both the
# controller (head-node-setup.sh does the same) and this node's gres.conf. The
# `systemctl restart slurmd` below then makes slurmd re-read it. Idempotent — the
# `/Gres=neuroncore/!` guard skips lines already carrying the gres on re-runs. If
# no PC partition conf is present (e.g. a configless setup), log and skip: slurmd
# then inherits the gres from the controller's config.
if (( CORE_COUNT > 0 )); then
  shopt -s nullglob
  pc_conf_files=(/opt/slurm/etc/pcluster/slurm_parallelcluster_*partition*.conf)
  shopt -u nullglob
  if (( ${#pc_conf_files[@]} == 0 )); then
    echo "[trn-course] no ParallelCluster partition conf under /opt/slurm/etc/pcluster; skipping NodeName gres attach (slurmd will use the controller's config)"
  else
    for pc_conf in "${pc_conf_files[@]}"; do
      echo "[trn-course] attaching Gres=neuroncore:${CORE_COUNT} to NodeName lines in ${pc_conf}"
      sed -i.bak -E "/^NodeName=/ { /Gres=neuroncore/! s/$/ Gres=neuroncore:${CORE_COUNT}/ }" "${pc_conf}"
    done
  fi
fi

# -----------------------------------------------------------------------------
# 4. Restart slurmd so it re-registers with the new gres
# -----------------------------------------------------------------------------
if systemctl is-active --quiet slurmd; then
  systemctl restart slurmd
  echo "[trn-course] restarted slurmd"
else
  echo "[trn-course] slurmd not yet active; PC will start it and pick up gres.conf"
fi

# -----------------------------------------------------------------------------
# 5. Cron drop-in for periodic roster resync (every 5 min)
# -----------------------------------------------------------------------------
SYNC_SCRIPT=/usr/local/sbin/trn-course-user-sync.sh
cat >"${SYNC_SCRIPT}" <<'SYNC'
#!/usr/bin/env bash
set -euo pipefail
ROSTER=/shared/etc/passwd.roster
[[ -s "${ROSTER}" ]] || exit 0
command -v jq >/dev/null || exit 0
jq -c '.[]' "${ROSTER}" | while read -r entry; do
  username=$(echo "${entry}" | jq -r '.username')
  uid_num=$(echo "${entry}" | jq -r '.uid')
  [[ "${username}" =~ ^[a-z][a-z0-9_-]{1,31}$ ]] || continue
  [[ "${uid_num}" =~ ^[0-9]+$ ]] && (( uid_num >= 10000 )) || continue
  if ! id -u "${username}" >/dev/null 2>&1; then
    useradd -M -u "${uid_num}" -d "/shared/home/${username}" -s /bin/bash "${username}"
  fi
  usermod -aG neuron "${username}" 2>/dev/null || true
done
SYNC
chmod +x "${SYNC_SCRIPT}"

cat >/etc/cron.d/trn-course-user-sync <<'CRON'
# Re-sync students from the shared roster every 5 minutes so late additions
# from the head node reach compute without a redeploy.
*/5 * * * * root /usr/local/sbin/trn-course-user-sync.sh >/var/log/trn-course-user-sync.log 2>&1
CRON

echo "[trn-course] compute-node-setup done at $(date -u)"
