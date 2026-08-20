#!/bin/bash
#SBATCH --job-name=scale-by-two
#SBATCH --partition=nki
#SBATCH --constraint=neuron
#SBATCH --nodes=1
#SBATCH --time=00:10:00
#SBATCH --output=%x-%j.out
#SBATCH --error=%x-%j.err
#
# Submit from the PCS login node:  sbatch run.sh
# Selects a Trainium node via the node Feature (--constraint=neuron); PCS has no
# per-core gres (see ../../docs/design.md Phase 2), so we select the whole node.
set -euo pipefail
# The shared Neuron venv built by ../../bootstrap/neuron-userdata.sh:
source /opt/aws_neuronx_venv_pytorch/bin/activate
cd "$(dirname "$(readlink -f "$0")")"
echo "== running scale_by_two on $(hostname) =="
neuron-ls 2>/dev/null || true
python run_example.py
