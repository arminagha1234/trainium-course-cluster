# Student Runbook

One-pager for the Trainium Course Cluster. Keep in your home directory as
`~/RUNBOOK.md`. If your login already includes this file, it was placed there
by the head-node bootstrap.

## Getting in

Your TA gave you three things, all privately:

- A **username** like `student01`
- A **Secrets Manager ARN** where your SSH private key lives
- A **head node hostname** or IP

Fetch your key (only needed once):

```
aws secretsmanager get-secret-value \
  --region <region> --secret-id <arn> \
  --query SecretString --output text > student01.pem
chmod 600 student01.pem
```

Then SSH in:

```
ssh -i student01.pem student01@<head-node-hostname>
```

If SSH times out, you are likely outside the SSH-allowed CIDR. Ask your TA.

## Your directories

- `~` (home) — persists across cluster teardown. Edit code here.
- `/shared/work/$USER/<job-name>/<jobid>/` — where every job's outputs land.
- `/shared/assignments/` — TA-populated, read-only. Copy an assignment into
  your home to work on it.

## Submitting a job

Copy the assignment you want to work on into your home, edit `student.py`,
then submit:

```
cp -r /shared/assignments/scale_by_two ~/
cd ~/scale_by_two
sbatch ~/run.sh
```

- Default job requests 1 NeuronCore (4 concurrent jobs fit on one node).
- Multi-core variant: `sbatch ~/run-multi-core.sh` (grabs all 4 cores on a node).

Check status:

```
squeue -u $USER           # your jobs
sinfo -p nki              # partition + node state
scontrol show job <id>    # verbose details for one job
```

Cancel a job:

```
scancel <jobid>
```

## Reading your results

Every job writes to `/shared/work/$USER/<job-name>/<jobid>/`. The important
files:

- `stdout.log` — everything the harness printed
- `stderr.log` — errors + banners (`neuron-ls` output lives here)
- `result.json` — pass/fail + timing + environment
- `profile/` — NEFF + NTFF pair from `neuron-profile`, plus metadata.json

Quick pass/fail check:

```
jq '.correctness.passed, .correctness.notes, .timing.student_ms_median' \
    /shared/work/$USER/*/<jobid>/result.json
```

To inspect a profile locally:

```
scp -i student01.pem \
  student01@<head>:/shared/work/$USER/<job>/<jobid>/profile/* .
neuron-profile view --neff *.neff --ntff *.ntff
```

## The assignment contract

An assignment lives in a directory with these files:

| File | Who writes it | Purpose |
|------|---------------|---------|
| `reference.py` | TA | Ground-truth `kernel(...)` |
| `student.py`   | You | Your NKI kernel implementing the same op |
| `inputs.py`    | TA | Generates the test inputs (deterministic) |
| `tolerance.json` | TA | `{"rtol": 1e-3, "atol": 1e-5}` |

Both `reference.py` and `student.py` must expose:

```python
def kernel(*args, **kwargs) -> torch.Tensor:
    ...
```

The harness (`~/harness/test_kernel.py`) calls both with `inputs.make_inputs()`,
compares outputs, times each, and writes `result.json`.

Fast local iteration (no queue wait, no profile):

```
SKIP_PROFILE=1 sbatch ~/run.sh
```

Or run outside Slurm on the head node just for a syntax check:

```
python3 ~/harness/test_kernel.py --assignment-dir . --output-dir /tmp/o
cat /tmp/o/result.json | jq .correctness
```

## Etiquette

- **The cluster is shared.** 4 cores per node, N total across the class. Long
  runs block other students. Default job time cap is 30 min.
- **Kill your own runaway jobs.** `scancel <jobid>` costs nothing.
- **Do not share your SSH key.** Rotate via your TA if you leaked it.
- **The compute nodes are not a secure sandbox.** Peers on the same node can
  in principle read the physical memory holding your kernel state. Don't
  put credentials or private data into an NKI job. This is documented in
  `docs/security.md#trainium-multi-tenant-caveat`.

## When something is broken

Order of things to check:

1. `squeue -u $USER` — is my job stuck pending?
   - `NODELIST(REASON) = (Resources)` → cluster busy; wait.
   - `NODELIST(REASON) = (BeginTime)` → your job was preempted; will re-run.
   - `NODELIST(REASON) = (AssocGrpGRES)` → you've hit a per-user cap.
2. `scontrol show job <id>` — was the job Slurm-rejected? Look at `Reason`.
3. `tail /shared/work/$USER/<job>/<id>/stderr.log` — usually where the real
   error lives.
4. `cat /shared/work/$USER/<job>/<id>/result.json | jq .correctness.notes` —
   what did the harness think went wrong?
5. If none of the above: paste `stderr.log` in the class Slack channel.
   TAs will look.

## Reference

- NKI docs: https://awsdocs-neuron.readthedocs-hosted.com/en/latest/nki/
- `neuron-profile view` output help: `neuron-profile view --help`
- Slurm sbatch options: `man sbatch` on the head node
