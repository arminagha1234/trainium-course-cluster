#!/usr/bin/env bash
#SBATCH --job-name=nki-kernel
#SBATCH --partition=nki
#SBATCH --constraint=neuron
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --time=00:30:00
#SBATCH --output=/shared/work/%u/%x/%j/stdout.log
#SBATCH --error=/shared/work/%u/%x/%j/stderr.log
#
# Trainium Course Cluster (AWS PCS variant): default kernel-assignment sbatch
# template. Copy this into your assignment directory and edit ASSIGNMENT below.
#
# ============================================================================
# PCS NeuronCore selection — READ THIS (differs from the ParallelCluster kit).
# On AWS PCS the NeuronCore is exposed to Slurm as a node **Feature**
# (`neuron,neuroncores<N>`, set at the compute node group by deploy-pcs.sh),
# NOT as a Slurm GRES. So you select a Trainium node with:
#       #SBATCH --constraint=neuron
# and you do NOT request per-core gres (there is no `--gres=neuroncore:N` on
# PCS — `Gres` is not in the PCS custom-settings allow-list). CONSEQUENCE: the
# per-core sharing / isolation the ParallelCluster variant offers is NOT
# available here. Selection is NODE-LEVEL: a job placed on a Trainium node can
# see ALL of that node's NeuronCores. If you need the whole node to yourself
# (no other jobs sharing it), add:
#       #SBATCH --exclusive
# To pin to a specific shape you may also constrain on the count feature, e.g.
# `--constraint=neuroncores16` (trn2.48xlarge) or `--constraint=neuroncores4`
# (trn2.3xlarge). See ../docs/design.md Phase 2 for why Gres is unavailable on
# PCS.
# ============================================================================
#
# Usage from your home dir:
#   cd /shared/assignments/<name>       # or your own working copy in ~/work
#   sbatch $HOME/run.sh
#
# The output directory is derived from the sbatch %x (job name) and %j (job id):
#   /shared/work/$USER/<job-name>/<job-id>/{stdout.log,stderr.log,result.json,profile/}
#
# The harness under $HOME/harness/ (populated by the login-node bootstrap)
# handles correctness + profile capture. This wrapper just prepares the
# environment and dispatches.

set -euo pipefail

# ---- User-editable section ----------------------------------------------
# Point to the assignment directory that contains reference.py + student.py.
# By default we assume the current working directory is that directory.
ASSIGNMENT_DIR="${ASSIGNMENT_DIR:-$PWD}"

# Skip the profile capture step? Set SKIP_PROFILE=1 when iterating on
# correctness only (profile capture adds ~30s per run).
SKIP_PROFILE="${SKIP_PROFILE:-0}"
# --------------------------------------------------------------------------

JOB_OUT="/shared/work/${USER}/${SLURM_JOB_NAME}/${SLURM_JOB_ID}"
PROFILE_DIR="${JOB_OUT}/profile"
mkdir -p "${JOB_OUT}" "${PROFILE_DIR}"

# Locate the harness (installed by the login-node bootstrap under ~/harness/)
HARNESS_DIR="${HARNESS_DIR:-$HOME/harness}"
if [[ ! -d "${HARNESS_DIR}" ]]; then
  echo "harness directory ${HARNESS_DIR} not found" >&2
  echo "expected ~/harness/{test_kernel.py,profile_kernel.py,result_writer.py}" >&2
  exit 2
fi

# Activate the shared Neuron venv (created by the compute-node bootstrap,
# bootstrap/neuron-userdata.sh, at a fixed path). If it's missing, fall back to
# system python.
if [[ -f /opt/aws_neuronx_venv_pytorch/bin/activate ]]; then
  # shellcheck disable=SC1091
  source /opt/aws_neuronx_venv_pytorch/bin/activate
fi

# On PCS there is NO neuron GRES plugin (Gres is not in the PCS allow-list), so
# Slurm does NOT set NEURON_RT_VISIBLE_CORES and does NOT fence off individual
# NeuronCores: a job placed on the node can see ALL of the node's NeuronCores
# (selection is node-level, via --constraint=neuron; add --exclusive if you need
# the node to yourself). We still log the value so a job that sets it explicitly
# stays diagnosable.
echo "NEURON_RT_VISIBLE_CORES=${NEURON_RT_VISIBLE_CORES:-<unset; PCS node-level selection, all cores visible>}"

# Print system info to stderr so it appears alongside the error log.
{
  echo "=== job start $(date -u) ==="
  echo "user=${USER} node=$(hostname) jobid=${SLURM_JOB_ID}"
  echo "assignment_dir=${ASSIGNMENT_DIR}"
  echo "output_dir=${JOB_OUT}"
  echo "selection=--constraint=neuron (PCS node Feature; no per-core gres)"
  neuron-ls 2>/dev/null || echo "neuron-ls unavailable"
} >&2

# ---- Correctness test ----------------------------------------------------
echo ">>> running correctness test"
python3 "${HARNESS_DIR}/test_kernel.py" \
  --assignment-dir "${ASSIGNMENT_DIR}" \
  --output-dir "${JOB_OUT}"

TEST_RESULT=$?
if (( TEST_RESULT != 0 )); then
  echo "test_kernel.py exited ${TEST_RESULT}; skipping profile capture" >&2
  exit "${TEST_RESULT}"
fi

# ---- Profile capture -----------------------------------------------------
if [[ "${SKIP_PROFILE}" != "1" ]]; then
  echo ">>> capturing profile"
  python3 "${HARNESS_DIR}/profile_kernel.py" \
    --assignment-dir "${ASSIGNMENT_DIR}" \
    --profile-dir "${PROFILE_DIR}" \
    || echo "profile capture failed (non-fatal)" >&2
else
  echo ">>> SKIP_PROFILE=1, skipping profile capture"
fi

echo "=== job end $(date -u) ==="
