#!/usr/bin/env bash
#SBATCH --job-name=nki-kernel-multi
#SBATCH --partition=nki
#SBATCH --gres=neuroncore:4
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --time=00:30:00
#SBATCH --output=/shared/work/%u/%x/%j/stdout.log
#SBATCH --error=/shared/work/%u/%x/%j/stderr.log
#
# Trainium Course Cluster: multi-core variant. Requests all 4 NeuronCores on
# one trn2.3xlarge node. Use for assignments that exercise cross-core
# collectives or that need the full HBM.
#
# Otherwise identical to run.sh - just a different gres/cpus request.

set -euo pipefail

ASSIGNMENT_DIR="${ASSIGNMENT_DIR:-$PWD}"
SKIP_PROFILE="${SKIP_PROFILE:-0}"

JOB_OUT="/shared/work/${USER}/${SLURM_JOB_NAME}/${SLURM_JOB_ID}"
PROFILE_DIR="${JOB_OUT}/profile"
mkdir -p "${JOB_OUT}" "${PROFILE_DIR}"

HARNESS_DIR="${HARNESS_DIR:-$HOME/harness}"

if [[ -f /opt/aws_neuronx_venv_pytorch/bin/activate ]]; then
  # shellcheck disable=SC1091
  source /opt/aws_neuronx_venv_pytorch/bin/activate
fi

{
  echo "=== job start $(date -u) ==="
  echo "user=${USER} node=$(hostname) jobid=${SLURM_JOB_ID}"
  echo "assignment_dir=${ASSIGNMENT_DIR}"
  echo "output_dir=${JOB_OUT}"
  echo "NEURON_RT_VISIBLE_CORES=${NEURON_RT_VISIBLE_CORES:-<unset>}"
  neuron-ls 2>/dev/null || echo "neuron-ls unavailable"
} >&2

python3 "${HARNESS_DIR}/test_kernel.py" \
  --assignment-dir "${ASSIGNMENT_DIR}" \
  --output-dir "${JOB_OUT}" || exit $?

if [[ "${SKIP_PROFILE}" != "1" ]]; then
  python3 "${HARNESS_DIR}/profile_kernel.py" \
    --assignment-dir "${ASSIGNMENT_DIR}" \
    --profile-dir "${PROFILE_DIR}" \
    || echo "profile capture failed (non-fatal)" >&2
fi

echo "=== job end $(date -u) ==="
