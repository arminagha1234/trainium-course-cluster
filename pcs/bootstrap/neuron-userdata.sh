#!/bin/bash
# neuron-userdata.sh
#
# EC2 launch-template UserData for AWS PCS trn2 compute nodes. Runs at FIRST
# BOOT as root via cloud-init (cloud-init executes a `#!`-prefixed user-data
# blob as a shell script). scripts/deploy-pcs.sh base64-encodes this file into
# the launch template's UserData field.
#
# Purpose: install the PUBLIC AWS Neuron SDK (driver + runtime + collectives +
# tools) and a shared torch-neuronx venv, directly from the public Neuron
# apt/pip repositories:
#   https://apt.repos.neuron.amazonaws.com
#   https://pip.repos.neuron.amazonaws.com
#
# This is ADAPTED from the ParallelCluster kit's bootstrap/compute-node-setup.sh
# (its Neuron-install section). Beyond installing the Neuron stack it also mounts
# the shared EFS filesystem at /shared (Phase 4 — see the EFS section near the
# end; the fs id + region are injected by deploy-pcs.sh). It deliberately does
# NOT include the other ParallelCluster-specific parts:
#   * no /shared roster sync — there is no roster here; per-student POSIX users
#     are a login-node follow-up (see ../docs/design.md). The /shared MOUNT and
#     the {home,work,assignments,etc} skeleton ARE created here; only the roster
#     sync is deferred.
#   * no Slurm gres.conf write / NodeName edit / slurmd restart — NeuronCore
#     GRES wiring on PCS is an open item (see ../docs/design.md).
#   * no ParallelCluster OnNodeConfigured assumptions (no /opt/slurm/etc/pcluster
#     partition confs, no PC cookbook).
#
# On AWS PCS, the PCS agent baked into the PCS AMI handles Slurm registration
# (slurmd config, controller join, node naming). This script only needs to make
# the Neuron stack present and the devices accessible; PCS does the rest.
#
# Target platform (Neuron SDK 2.x): Ubuntu 24.04 (VERSION_CODENAME=noble),
# Python 3.12, PyTorch 2.9. NKI ships inside neuronx-cc as neuronxcc.nki.
# Neuron CLI tools install under /opt/aws/neuron/bin.
#
# Idempotent: if the shared venv already imports torch_neuronx, the slow
# SDK/venv install is skipped; the apt/keyring, group, udev, and EFS /shared
# mount steps are all safe to repeat (the mount is skipped when already present).

set -euo pipefail

LOG=/var/log/trn-course-pcs-neuron-userdata.log
# cloud-init already tees user-data output to /var/log/cloud-init-output.log;
# we ALSO keep our own log for easy grepping.
exec > >(tee -a "$LOG") 2>&1
echo "[trn-course-pcs] neuron-userdata starting at $(date -u)"
echo "[trn-course-pcs] hostname=$(hostname)"

export DEBIAN_FRONTEND=noninteractive
NEURON_VENV=/opt/aws_neuronx_venv_pytorch

# deploy-pcs.sh injects these two values into a RENDERED copy of this file
# (via sed) before base64-ing it into the launch template. Left empty here so
# the script stays valid/testable standalone; empty => the EFS mount is skipped.
EFS_FS_ID=""
EFS_REGION=""

# ---------------------------------------------------------------------------
# retry <max> <label> <cmd...> — run <cmd> up to <max> times with linear
# backoff. Every network op (apt update/install, pip) is wrapped so a transient
# repo/network hiccup does not fail node bring-up on the first try.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Idempotency: if the shared venv already imports torch_neuronx, the SDK + venv
# are already installed — skip straight to the (cheap) device-access setup.
# ---------------------------------------------------------------------------
if [[ -x "${NEURON_VENV}/bin/python" ]] && "${NEURON_VENV}/bin/python" -c "import torch_neuronx" >/dev/null 2>&1; then
  echo "[trn-course-pcs] Neuron SDK + torch-neuronx already present at ${NEURON_VENV}; skipping install"
else
  echo "[trn-course-pcs] installing public Neuron SDK + torch-neuronx"

  # --- Neuron apt repo via signed-by keyring --------------------------------
  # apt-key is removed on Ubuntu 24.04, so use the keyring method. The apt
  # suite is the running release's codename (VERSION_CODENAME, e.g. noble).
  . /etc/os-release
  install -d -m 0755 /usr/share/keyrings
  retry 5 "fetch Neuron GPG key" bash -c 'set -o pipefail; curl -fsSL https://apt.repos.neuron.amazonaws.com/GPG-PUB-KEY-AMAZON-AWS-NEURON.PUB | gpg --dearmor -o /usr/share/keyrings/neuron-keyring.gpg' \
    || { echo "[trn-course-pcs] FATAL: could not install the Neuron apt GPG key" >&2; exit 1; }
  cat >/etc/apt/sources.list.d/neuron.list <<EOF
deb [signed-by=/usr/share/keyrings/neuron-keyring.gpg] https://apt.repos.neuron.amazonaws.com ${VERSION_CODENAME} main
EOF
  echo "[trn-course-pcs] configured Neuron apt repo for suite '${VERSION_CODENAME}'"

  # --- apt-get update + build prerequisites ---------------------------------
  retry 5 "apt-get update" apt-get update \
    || { echo "[trn-course-pcs] FATAL: apt-get update failed" >&2; exit 1; }

  # linux-headers are REQUIRED for the aws-neuronx-dkms kernel module build;
  # python3.12-venv is needed to create the venv; g++ + git per Neuron setup.
  retry 5 "install kernel headers + build deps" \
    apt-get install -y "linux-headers-$(uname -r)" git python3.12-venv g++ \
    || { echo "[trn-course-pcs] FATAL: could not install kernel headers / build deps" >&2; exit 1; }

  # Neuron driver + collectives + runtime + tools (all pinned to the 2.x line).
  # aws-neuronx-collectives is included for intra-node multi-core collectives.
  for pkg in aws-neuronx-dkms aws-neuronx-collectives aws-neuronx-runtime-lib aws-neuronx-tools; do
    retry 5 "install ${pkg}" apt-get install -y "${pkg}=2.*" \
      || { echo "[trn-course-pcs] FATAL: required Neuron package ${pkg} failed to install" >&2; exit 1; }
  done
  echo "[trn-course-pcs] Neuron apt packages installed (CLI tools under /opt/aws/neuron/bin)"

  # --- Load the driver + wait for the device nodes to appear ----------------
  modprobe neuron 2>/dev/null || true
  echo "[trn-course-pcs] waiting up to ~60s for /dev/neuron* device nodes..."
  for _ in {1..30}; do
    if compgen -G "/dev/neuron[0-9]*" >/dev/null; then break; fi
    sleep 2
  done
  if compgen -G "/dev/neuron[0-9]*" >/dev/null; then
    echo "[trn-course-pcs] /dev/neuron* present: $(compgen -G '/dev/neuron[0-9]*' | tr '\n' ' ')"
  else
    echo "[trn-course-pcs] WARN: no /dev/neuron* devices after 60s (driver may attach later)." >&2
  fi

  # --- Shared torch-neuronx venv at a FIXED, world-readable path ------------
  echo "[trn-course-pcs] creating shared Neuron venv at ${NEURON_VENV}"
  python3.12 -m venv "${NEURON_VENV}" \
    || { echo "[trn-course-pcs] FATAL: could not create venv ${NEURON_VENV}" >&2; exit 1; }
  retry 5 "pip upgrade" "${NEURON_VENV}/bin/pip" install --upgrade pip \
    || { echo "[trn-course-pcs] FATAL: pip upgrade failed in ${NEURON_VENV}" >&2; exit 1; }
  # Point the venv's pip at the public Neuron pip repo (neuronx-cc + torch-neuronx
  # are published there), written into the venv's own pip config.
  "${NEURON_VENV}/bin/pip" config set global.extra-index-url https://pip.repos.neuron.amazonaws.com
  retry 5 "pip install neuronx-cc/torch-neuronx" \
    "${NEURON_VENV}/bin/pip" install "neuronx-cc==2.*" "torch-neuronx==2.9.*" torchvision \
    || { echo "[trn-course-pcs] FATAL: could not install neuronx-cc / torch-neuronx into ${NEURON_VENV}" >&2; exit 1; }
  # Make the whole venv world-readable + traversable (a+rX = read for files,
  # read+traverse for directories) so every future student POSIX user can
  # `source ${NEURON_VENV}/bin/activate` from a job.
  chmod -R a+rX "${NEURON_VENV}"
  echo "[trn-course-pcs] Neuron venv ready: source ${NEURON_VENV}/bin/activate"
fi

# ---------------------------------------------------------------------------
# Neuron device access control (Neuron security guidance — NOT PC-specific).
# https://awsdocs-neuron.readthedocs-hosted.com/en/latest/about-neuron/security.html
# Create the `neuron` group + a udev rule so /dev/neuron* are group-owned by
# `neuron` with mode 0660. Student POSIX users are added to this group by the
# login-node follow-up (see ../docs/design.md); creating the group + rule now
# means device access "just works" once those users exist.
# ---------------------------------------------------------------------------
if ! getent group neuron >/dev/null; then
  groupadd -r neuron
  echo "[trn-course-pcs] created neuron group"
fi

cat >/etc/udev/rules.d/99-neuron.rules <<'RULE'
# Neuron device access control
# Only members of the 'neuron' group can access neuron devices.
SUBSYSTEM=="neuron*", KERNEL=="neuron*", GROUP="neuron", MODE="0660"
RULE

udevadm control --reload 2>/dev/null || true
udevadm trigger --subsystem-match=neuron 2>/dev/null || true

# ---------------------------------------------------------------------------
# NeuronCore -> Slurm exposure (Phase 2). On AWS PCS the NeuronCore is exposed
# to Slurm as a node **Feature** (`neuron,neuroncores<N>`), set at the COMPUTE
# NODE GROUP level by scripts/deploy-pcs.sh (SlurmCustomSettings -> Features),
# NOT as a Slurm GRES. `Gres`/`GresTypes` are in NEITHER the PCS cluster nor CNG
# custom-settings allow-lists, so — unlike the ParallelCluster kit's
# bootstrap/compute-node-setup.sh — this bootstrap intentionally writes NO
# gres.conf (and does no NodeName `Gres=` edit / slurmd restart). Students select
# a Trainium node with `--constraint=neuron`; there is no per-core GRES isolation
# on PCS. The PCS agent baked into the AMI owns Slurm registration. See
# ../docs/design.md Phase 2.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# EFS /shared mount (Phase 4). deploy-pcs.sh injects EFS_FS_ID + EFS_REGION
# (near the top of this file) into a rendered copy before base64-ing it into the
# launch template. With no head node on PCS, this UserData is the ONLY place
# /shared is mounted on a compute node. When EFS_FS_ID is set we mount the
# filesystem at /shared and create the shared skeleton the parent kit expects
# (/shared/{home,work,assignments,etc} — mirrors head-node-setup.sh section 2).
#
# NON-FATAL by design: a node without /shared can still boot for diagnosis, so a
# mount failure logs a loud WARN but does not abort bring-up (matching the
# driver/device tone above). The per-student roster sync is a login-node
# follow-up (see ../docs/design.md); only the mount + skeleton happen here.
# ---------------------------------------------------------------------------
if [[ -n "${EFS_FS_ID}" ]]; then
  echo "[trn-course-pcs] mounting EFS ${EFS_FS_ID} at /shared (region='${EFS_REGION}')"
  mkdir -p /shared

  # apt lists may be stale if the Neuron install above was skipped (e.g. a baked
  # AMI), so refresh them best-effort before pulling the mount helper.
  retry 3 "apt-get update (efs)" apt-get update \
    || echo "[trn-course-pcs] WARN: apt-get update failed; efs mount packages may be missing" >&2

  # Prefer the EFS mount helper (amazon-efs-utils) — it provides the `efs` fstype
  # with in-transit TLS. If that package is unavailable, fall back to nfs-common
  # and a standard NFS 4.1 mount of the EFS DNS name.
  if retry 3 "install amazon-efs-utils" apt-get install -y amazon-efs-utils; then
    FSTAB_LINE="${EFS_FS_ID}:/ /shared efs _netdev,tls 0 0"
    MOUNT_CMD=(mount -t efs -o _netdev,tls "${EFS_FS_ID}:/" /shared)
  else
    echo "[trn-course-pcs] WARN: amazon-efs-utils unavailable; falling back to nfs-common + NFS4.1" >&2
    retry 5 "install nfs-common" apt-get install -y nfs-common \
      || echo "[trn-course-pcs] WARN: could not install nfs-common either; mount will likely fail" >&2
    EFS_DNS="${EFS_FS_ID}.efs.${EFS_REGION}.amazonaws.com"
    FSTAB_LINE="${EFS_DNS}:/ /shared nfs4 nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,_netdev 0 0"
    MOUNT_CMD=(mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,_netdev "${EFS_DNS}:/" /shared)
  fi

  # fstab entry (idempotent) so /shared survives a reboot: only add it if no
  # /shared mount is already declared there.
  if ! grep -qE '[[:space:]]/shared[[:space:]]' /etc/fstab; then
    echo "${FSTAB_LINE}" >> /etc/fstab
    echo "[trn-course-pcs] added /shared entry to /etc/fstab"
  fi

  # Mount idempotently (skip if already a mountpoint). Wrapped in retry so a
  # mount target that is still coming up does not lose the race on first boot.
  if mountpoint -q /shared; then
    echo "[trn-course-pcs] /shared already mounted"
  elif retry 5 "mount /shared" "${MOUNT_CMD[@]}"; then
    echo "[trn-course-pcs] mounted EFS ${EFS_FS_ID} at /shared"
  else
    echo "[trn-course-pcs] WARN: could not mount EFS ${EFS_FS_ID} at /shared; node will boot without shared storage" >&2
  fi

  # Shared skeleton the parent kit expects (mirror head-node-setup.sh section 2).
  # Only when the mount actually succeeded, so we never scaffold onto the local
  # root disk and mask a mount failure.
  if mountpoint -q /shared; then
    install -d -m 755 /shared/home /shared/work /shared/assignments /shared/etc
    echo "[trn-course-pcs] ensured /shared/{home,work,assignments,etc} skeleton"
  fi
else
  echo "[trn-course-pcs] EFS_FS_ID empty; skipping /shared mount"
fi

echo "[trn-course-pcs] neuron-userdata done at $(date -u)"
echo "[trn-course-pcs] NOTE: the PCS agent (baked into the PCS AMI) handles Slurm registration."
