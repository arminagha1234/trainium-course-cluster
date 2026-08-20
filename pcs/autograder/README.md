# PCS/Slurm-native Gradescope autograder

A Gradescope autograder for the AWS PCS variant of the Trainium Course Cluster
kit. Instead of booting a fresh Trainium instance per submission, it submits
each grading run onto the **already-running shared PCS cluster** and reuses the
kit's harness. It grades NKI kernel assignments (the `scale_by_two` example
ships with the kit; any assignment under `/shared/assignments/<name>` that
follows the harness contract works).

> **Status — honest note.** This wires together documented, individually-proven
> pieces (the kit harness, the PCS login node's `sbatch` path, the `result.json`
> schema), but it has **not** been run end to end on Gradescope against a live
> cluster yet. Validate on your own account/region before a graded assignment.
> The pieces it depends on have their own validation status in
> [`../docs/design.md`](../docs/design.md) (the login-node `sackd` join and the
> `--constraint=neuron` selection are proven live; per-student QoS and EFS are
> implemented but not yet live-exercised).

## The concept

Per submission, `run_autograder`:

1. SSHes to the **PCS login node** (stood up by
   [`../scripts/deploy-login-node.sh`](../scripts/deploy-login-node.sh)),
2. makes a unique run dir on the cluster's shared FS and stages the TA
   assignment (`reference.py` + optional `inputs.py` / `tolerance.json`) plus
   the student's uploaded `student.py` into it,
3. `sbatch --constraint=neuron`s [`grade_job.sbatch`](./grade_job.sbatch) onto
   the shared trn2 fleet, which runs the kit harness
   ([`../../harness/test_kernel.py`](../../harness/test_kernel.py)),
4. polls `squeue` until the job finishes (or `JOB_TIMEOUT` elapses), then scps
   the harness's `result.json` back into the image,
5. runs [`run_tests.py`](./run_tests.py), which turns that `result.json` into
   Gradescope's `results.json`.

This adapts the well-known per-instance pattern (a Gradescope container that
boots a fresh `trn1` per submission via boto3, SSHes in, runs a tester, then
terminates the instance). We target a shared cluster instead — see
"Improvements" below.

## The one secret: a scoped SSH key (NOT AWS keys)

The only credential baked into the Gradescope image is an **SSH private key**
(`autograder_key.pem`) for a **low-privilege `autograder` user** on the login
node — an account that can `sbatch`/`squeue`/`scancel` and write under
`/shared/autograder/`, and little else. There are **no AWS credentials** in the
image; the autograder never calls the AWS API. If the key leaks, the blast
radius is "can submit Slurm jobs as a low-priv user on one login node" — not
your AWS account.

Harden the `autograder` account on the login node accordingly: give it a
locked password (key-only login), no `sudo`, and ideally a restricted set of
allowed commands. It only needs to reach the cluster's Slurm client tools and
`/shared/autograder/`.

## Prerequisites (on the cluster side)

1. A running PCS cluster from [`../scripts/deploy-pcs.sh`](../scripts/deploy-pcs.sh)
   with the **`nki` queue/partition** and compute nodes tagged with the
   `neuron` feature (so `--constraint=neuron` schedules).
2. A **login node** from [`../scripts/deploy-login-node.sh`](../scripts/deploy-login-node.sh),
   reachable over SSH from wherever Gradescope runs (the login SG's TCP/22
   ingress must allow it — Gradescope's egress IPs are not fixed, so operators
   typically run this against a login node reachable from the grading network).
3. The kit **harness staged to `/shared/harness`** (`test_kernel.py`,
   `result_writer.py`, and, if you profile, `profile_kernel.py`).
4. TA **assignment dirs under `/shared/assignments/<name>`**, each with a
   `reference.py` (and optional `inputs.py` / `tolerance.json`) following the
   harness contract in [`../../harness/example-assignment/`](../../harness/example-assignment/).
5. A low-privilege **`autograder` login-node user** whose public key is
   installed in its `~/.ssh/authorized_keys`, matching the private
   `autograder_key.pem` you bake into the image.

## Configure `run_autograder`

Edit the config block at the top of [`run_autograder`](./run_autograder):

| Variable | What to set it to |
|---|---|
| `LOGIN_NODE_HOST` | the login node's public DNS/IP (from the `deploy-login-node.sh` summary) |
| `LOGIN_NODE_USER` | the low-priv submit user (default `autograder`) |
| `SSH_KEY`         | leave as `/autograder/source/autograder_key.pem` unless you rename the key |
| `ASSIGNMENT`      | the `/shared/assignments/<name>` to grade against (e.g. `scale_by_two`) |
| `SUBMISSION_FILE` | the filename students upload (default `student.py`) |
| `HARNESS_DIR`     | kit harness path on the cluster (default `/shared/harness`) |
| `ASSIGNMENTS_DIR` | TA assignments root (default `/shared/assignments`) |
| `JOB_TIMEOUT`     | seconds to wait for the grading job (default `300`) |

Tune the performance target with `PERF_THRESHOLD_MS` at the top of
[`tests/test_kernel_result.py`](./tests/test_kernel_result.py) (default `5.0`
ms). Pick it per assignment and per instance shape — a `trn2.3xlarge` and a
`trn2.48xlarge` land different medians for the same kernel.

## Build + upload to Gradescope

1. Put the scoped SSH private key in this directory as `autograder_key.pem`
   (do **not** commit it — add it only to the zip you upload).
2. Set `LOGIN_NODE_HOST` in `run_autograder`.
3. Zip the autograder and upload it on your Gradescope assignment's
   "Configure Autograder" page:

   ```bash
   cd pcs/autograder
   zip -r image.zip ./*
   ```

Gradescope runs `setup.sh` once to build the image, then `run_autograder` per
submission. `setup.sh` installs `python3`, `pip`, `openssh-client`, and
`gradescope-utils`.

## Grading breakdown

| Component | Points | How |
|---|---:|---|
| Submitted files | 0 | `student.py` present in the upload (early sanity signal) |
| **Correctness** | **70** | `result.json → correctness.passed`; failure notes surfaced to the student |
| **Performance** | **30** | partial credit on `timing.student_ms_median` vs `PERF_THRESHOLD_MS` (`T`) — full credit at `x <= T`, linear to 0 at `x >= 2T`; only when correctness passes |
| Leaderboard | — | `median_ms`, ascending (lower is better); informational, only when correct |

Performance score: `30 * clamp(1 - max(0, x - T) / T, 0, 1)` where
`x = student_ms_median` and `T = PERF_THRESHOLD_MS`.

## Improvements over the per-instance autograder

Compared with the pattern that launches a fresh Trainium instance per
submission:

- **No per-submission EC2.** Grading runs on the shared cluster you already
  pay for through the ML Capacity Block; there is no per-submission
  launch/terminate, and **Slurm fair-shares** concurrent submissions across the
  fleet instead of racing to spin up instances.
- **No AWS credentials in the Gradescope image.** The only baked-in secret is a
  scoped SSH key to a low-privilege login-node user that may `sbatch` — not AWS
  access keys. Smaller, safer blast radius.
- **Single source of truth.** Grading reuses the kit's
  [`harness/test_kernel.py`](../../harness/test_kernel.py) and its `result.json`
  schema ([`harness/result_writer.py`](../../harness/result_writer.py)) rather
  than a forked tester, so autograder scores match what students see when they
  run the harness themselves.
- **Validated compute environment.** The grading job runs on the same trn2
  nodes and the same Neuron DLAMI venv (`/opt/aws_neuronx_venv_pytorch`) as
  interactive student work, avoiding the "correct kernel, all-zero output on a
  partial Neuron install" trap documented in
  [`../docs/design.md`](../docs/design.md).

## Files

```
autograder/
  run_autograder            Gradescope entrypoint (ssh + sbatch to the cluster)
  grade_job.sbatch          the Slurm job (runs the kit harness on a trn2 node)
  run_tests.py              gradescope-utils runner -> results.json
  requirements.txt          gradescope-utils
  setup.sh                  image build step (python3, pip, openssh-client, deps)
  tests/
    __init__.py
    test_files.py           weight-0 check that student.py was uploaded
    test_kernel_result.py   correctness (70) + performance (30) + leaderboard
  README.md                 you are here
```

Note: `autograder_key.pem` is intentionally NOT in the repo — the operator adds
it to the upload zip.

<!-- Content on AWS PCS / Gradescope behavior was summarized from public docs and rephrased for compliance with licensing restrictions. -->
