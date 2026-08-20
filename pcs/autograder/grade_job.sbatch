#!/bin/bash
#SBATCH --job-name=autograde
#SBATCH --partition=nki
#SBATCH --constraint=neuron
#SBATCH --nodes=1
#SBATCH --time=00:08:00
#SBATCH --output=%x-%j.out
#
# grade_job.sbatch — the Slurm job the autograder submits from the login node.
# Runs on a trn2 compute node in the shared PCS fleet and grades ONE submission
# by invoking the kit harness against a prepared run dir.
#
# PCS node selection — READ THIS (differs from the ParallelCluster kit):
# on AWS PCS the NeuronCore is exposed to Slurm as a node *Feature*
# (`neuron`, set on the compute node group by deploy-pcs.sh), NOT as a Slurm
# GRES. So we select a Trainium node with `--constraint=neuron` above; there is
# no `--gres=neuroncore:N` on PCS (`Gres` is not in the PCS custom-settings
# allow-list). See ../docs/design.md "Phase 2" and slurm/job-templates/run.sh.
# Grading is one-submission-per-node work, so we do not need per-core isolation.
#
# Args (passed by run_autograder):
#   $1 RUN_DIR      shared-FS dir holding reference.py + student.py (+ optional
#                   inputs.py / tolerance.json); also the harness output dir.
#   $2 HARNESS_DIR  kit harness location on the cluster (default /shared/harness).
#
# The harness writes $RUN_DIR/result.json regardless of pass/fail; run_autograder
# scps that back and run_tests.py turns it into a Gradescope score.

set -uo pipefail

RUN_DIR="$1"
HARNESS_DIR="${2:-/shared/harness}"

echo "=== autograde job start $(date -u) ==="
echo "node=$(hostname) jobid=${SLURM_JOB_ID:-local} run_dir=${RUN_DIR} harness=${HARNESS_DIR}"

# Validated Neuron DLAMI venv. The kit's live validation (see ../docs/design.md
# "Live validation") found that a from-scratch / torch-neuronx-less venv let the
# kernel compile and run but return ALL-ZERO output — a false correctness FAIL.
# The graded path therefore relies on the full, matched Neuron install at this
# fixed path (created by bootstrap/neuron-userdata.sh); if it is missing we fall
# back to system python and let the harness report the resulting failure rather
# than silently mis-grading.
if [ -f /opt/aws_neuronx_venv_pytorch/bin/activate ]; then
  # shellcheck disable=SC1091
  source /opt/aws_neuronx_venv_pytorch/bin/activate
  echo "activated Neuron venv: /opt/aws_neuronx_venv_pytorch"
else
  echo "WARN: /opt/aws_neuronx_venv_pytorch not found; using system python (results may be unreliable)" >&2
fi

# Log the device view for debugging a bad grade (non-fatal if the tool is absent).
neuron-ls 2>/dev/null || echo "neuron-ls unavailable"

# Single source of truth: the kit harness imports reference.py + student.py from
# RUN_DIR, compares them, and writes RUN_DIR/result.json in the schema
# run_tests.py expects (harness/result_writer.py). --assignment-dir == --output-dir
# so the result lands next to the inputs.
python3 "${HARNESS_DIR}/test_kernel.py" \
  --assignment-dir "${RUN_DIR}" \
  --output-dir "${RUN_DIR}"
HARNESS_RC=$?

echo "=== autograde job end $(date -u) (harness exit ${HARNESS_RC}) ==="
# Exit non-zero on a fatal harness error (2) so it is visible in squeue/sacct;
# a plain correctness FAIL (1) is still a valid graded outcome, so treat 0/1 as
# job success. result.json carries the authoritative pass/fail either way.
if [ "${HARNESS_RC}" -eq 2 ]; then
  exit 2
fi
exit 0
