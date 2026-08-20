#!/usr/bin/env bash
# setup.sh — Gradescope image build step.
#
# Gradescope runs this ONCE when it builds the autograder container image (not
# per submission — that is run_autograder). It only needs to install what
# run_autograder and run_tests.py use at grade time:
#   * python3 + pip           — to run run_tests.py
#   * openssh-client          — ssh/scp to the PCS login node
#   * gradescope-utils         — the grading decorators + JSON runner
#
# Note there is NO awscli here on purpose: the autograder never calls AWS. It
# reaches the cluster only over SSH to the login node, so the single secret in
# the image is the scoped SSH key, not AWS credentials.
#
# !!! OPERATOR — TWO THINGS THIS SCRIPT CANNOT DO FOR YOU !!!
#   1. Place the scoped login-node SSH private key in the image as
#      autograder_key.pem (it is zipped into /autograder/source/ alongside these
#      files). This is the key for the low-privilege `autograder` user on the
#      login node that is allowed to `sbatch`. Do NOT bake in AWS keys.
#   2. Set LOGIN_NODE_HOST (and, if you changed them, LOGIN_NODE_USER /
#      ASSIGNMENT / PERF threshold) in run_autograder.
# See README.md for the full checklist.

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y python3 python3-pip openssh-client

pip3 install -r /autograder/source/requirements.txt

echo "[setup] autograder image dependencies installed"
