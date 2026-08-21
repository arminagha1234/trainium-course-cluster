# Trainium Course Cluster User Guide

This guide covers day-to-day use of the Trainium Course Cluster for the three
roles involved in a course: the admin who owns the AWS account and capacity, the
instructor or TA who runs the cluster and the roster, and the students who write
and run kernels. For the project overview and architecture, see the
[`README.md`](./README.md).

## Roles at a glance

- Admin: provisions capacity (a trn2 ML Capacity Block or on-demand trn1 quota),
  owns cost guardrails, and holds the AWS credentials used to deploy.
- Instructor or TA: runs `deploy-pcs.sh` and `deploy-login-node.sh`, authors
  assignments under `/shared/assignments`, hands out student credentials, sets
  per-student limits, monitors usage, and tears the cluster down at the end.
- Student: SSHes to the login node, edits kernel code in a personal directory,
  submits jobs with `sbatch`, and reads results and profiles.

## Part 1: Instructor and TA guide

### 1. Prerequisites

- AWS CLI v2 (with the `pcs` subcommands), plus `jq` and `base64` on your path.
- Credentials for the target account with permissions to create `ec2`, `iam`,
  `ssm`, `pcs`, and `efs` resources. For the Capacity Block path the deploying
  identity also needs `ec2:DescribeCapacityReservations`, and PCS itself needs
  `ec2:DescribeCapacityBlocks` and `ec2:DescribeCapacityBlockStatus`.
- Capacity, one of:
  - a trn2 ML Capacity Block (note its reservation id and AZ), or
  - on-demand trn1 quota in `us-east-1` or `us-west-2`.
- A VPC and a subnet in the compute AZ. Compute nodes need outbound internet to
  install the Neuron SDK, so use a public subnet (with an internet gateway) or a
  private subnet with a NAT gateway.

### 2. Deploy the cluster

Run `scripts/deploy-pcs.sh` with the purchase option that matches your capacity.
Use `--dry-run` first to validate inputs without creating anything.

On-demand trn1:

```bash
./scripts/deploy-pcs.sh \
  --cluster-name fall26-nki \
  --region us-west-2 \
  --purchase-option ONDEMAND \
  --subnet-id subnet-xxxxxxxx \
  --vpc-id vpc-xxxxxxxx \
  --compute-instance-type trn1.2xlarge \
  --compute-node-count 2 \
  --student-count 20 \
  --alert-email you@your.org
```

trn2 ML Capacity Block (find the reservation id and AZ first):

```bash
aws ec2 describe-capacity-reservations \
  --filters Name=instance-type,Values=trn2.3xlarge Name=state,Values=active \
  --query 'CapacityReservations[].{Id:CapacityReservationId,AZ:AvailabilityZone,Count:TotalInstanceCount}' \
  --region us-east-2

./scripts/deploy-pcs.sh \
  --cluster-name fall26-nki \
  --region us-east-2 \
  --purchase-option CAPACITY_BLOCK \
  --capacity-reservation-id cr-xxxxxxxx \
  --availability-zone us-east-2b \
  --subnet-id subnet-xxxxxxxx \
  --vpc-id vpc-xxxxxxxx \
  --compute-instance-type trn2.3xlarge \
  --compute-node-count 1 \
  --student-count 20 \
  --alert-email you@your.org
```

The script is idempotent (safe to re-run) and waits for each PCS resource to
reach ACTIVE. When it finishes it prints a summary banner with the cluster id,
node group id, queue name, and EFS filesystem id. Note that each compute node
then spends roughly ten minutes installing the Neuron SDK on first boot; the
node group reaches ACTIVE before that install completes, so give it a few
minutes before submitting the first job. See "Verify the compute nodes" below.

Notes:
- On-demand does not need `--capacity-reservation-id` or `--availability-zone`;
  the AZ is derived from the subnet.
- If your AWS CLI predates PCS managed accounting, the deploy prints a warning
  and creates the cluster without accounting. Jobs still run; per-student QoS
  enforcement is unavailable until the CLI is upgraded.

### 3. Verify the compute nodes (optional but recommended)

Compute nodes are managed by SSM (the role carries `AmazonSSMManagedInstanceCore`),
so you can check the Neuron install without SSH. Find the instances and run a
check:

```bash
aws ec2 describe-instances \
  --filters Name=instance-type,Values=trn1.2xlarge Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].InstanceId' --output text --region us-west-2

aws ssm send-command --region us-west-2 \
  --instance-ids i-xxxxxxxxxxxx \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["cloud-init status","/opt/aws/neuron/bin/neuron-ls","mountpoint /shared"]'
```

A healthy node reports `cloud-init status: done`, a `neuron-ls` device table,
and `/shared is a mountpoint`. Retrieve output with
`aws ssm get-command-invocation --command-id <id> --instance-id <id>`.

### 4. Add the login node

PCS has no head node, so students need a login node to SSH into and submit from.
Once the cluster is ACTIVE, run:

```bash
./scripts/deploy-login-node.sh \
  --cluster-name fall26-nki \
  --region us-west-2 \
  --vpc-id vpc-xxxxxxxx \
  --subnet-id subnet-xxxxxxxx \
  --ssh-allowed-cidr 203.0.113.0/24 \
  --key-name my-ssh-key \
  --efs-id fs-xxxxxxxx \
  --staging-bucket my-bootstrap-bucket
```

This launches a standalone EC2 login node, joins it to the managed Slurm
controller via `sackd`, mounts the same EFS at `/shared`, creates the
per-student POSIX users, and applies per-student wall-time and concurrent-job
QoS via `sacctmgr`. `--ssh-allowed-cidr` restricts SSH to your course network
(never use an open range). Status: the `sackd` join is validated live; the
per-student user and QoS steps are implemented but should be validated on your
own cluster before a class, and QoS enforcement needs managed accounting (a
recent AWS CLI).

### 5. Give students access

Each student gets a POSIX account (for example `student01`), a home directory at
`/shared/home/<user>`, and a work directory at `/shared/work/<user>`. Per-student
SSH keys are generated and stored in AWS Secrets Manager; distribute each
student their private key and the login node's address privately, and keep the
slot-to-name mapping out of band.

Status: the roster automation (the `student_manifest` Lambda that emits a
TA-facing manifest) is implemented in the kit but not yet wired into the PCS
flow. In the interim the login node creates the accounts from its bootstrap;
confirm the accounts and keys on your cluster before handing them out.

### 6. Author an assignment

Assignments live under `/shared/assignments/<name>` and follow a simple
contract. Start from the provided example:

```bash
cp -r harness/example-assignment /shared/assignments/scale_by_two
```

Each assignment directory contains:

- `reference.py`: the correct implementation (TA-owned, not shown to students).
- `student.py`: where the student writes their NKI kernel.
- `inputs.py`: generates the test input tensors.
- `tolerance.json`: optional tolerance override (defaults to `rtol=1e-3`,
  `atol=1e-5`).

Both `reference.py` and `student.py` must expose a callable named `kernel` with
the signature implied by `inputs.py`. The harness runs the student kernel
against the reference and writes a `result.json` whose `correctness.passed`
boolean is the grade signal; timing is informational in V0.

### 7. Monitor usage and set limits

From the login node:

- `sinfo` shows node and partition state.
- `squeue` shows queued and running jobs (`squeue --me` for your own).
- `sacct` shows completed-job accounting (requires managed accounting).

Per-student limits (wall-time, concurrent jobs) are set with `sacctmgr` by the
login-node bootstrap and enforced only when the cluster was created with managed
accounting. Per-NeuronCore or core-hours budgets are not available on PCS
because `neuroncore` is not a Slurm GRES there.

### 8. Autograding (optional)

`autograder/` contains a Gradescope autograder that SSHes to the login node and
submits each grading run with `sbatch --constraint=neuron`, reusing the harness
and its `result.json` schema. The only secret in the Gradescope image is a
scoped SSH key to a low-privilege `autograder` account (no AWS credentials). See
[`autograder/README.md`](./autograder/README.md) for setup and the 70/30
correctness/performance split.

### 9. Tear down

There is no teardown script in this kit yet, so delete resources in dependency
order. EFS is retained by default so student work survives.

```bash
R=us-west-2; C=<cluster-id>
aws pcs delete-queue --region $R --cluster-identifier $C --queue-identifier nki
aws pcs delete-compute-node-group --region $R --cluster-identifier $C --compute-node-group-identifier <cng-id>
aws pcs delete-cluster --region $R --cluster-identifier $C
# then the login node (terminate the EC2 instance), launch template, security
# group, and the AWSPCS IAM role + instance profile.
# EFS (fs-xxxx) is intentionally left in place; delete it only when you no
# longer need the student work it holds.
```

Terminate the login node EC2 instance separately. Confirm the compute instances
have terminated (they are managed by the node group and should stop when it is
deleted) so they stop billing.

## Part 2: Student guide

### 1. Connect

Your instructor gives you a username, a private SSH key, and the login node's
address. PCS has no head node, so the login node is where you log in and submit
jobs.

```bash
ssh -i student01.pem student01@<login-node-address>
```

You land in your home directory, `/shared/home/<you>`.

### 2. Your workspace

- `/shared/home/<you>`: your home directory.
- `/shared/work/<you>`: where your job outputs and logs are written.
- `/shared/assignments`: read-only starter code and references from your TA.

Copy an assignment into your own space to edit it:

```bash
cp -r /shared/assignments/scale_by_two ~/scale_by_two
cd ~/scale_by_two
```

### 3. Activate the Neuron environment (important)

The Neuron SDK and `torch-neuronx` live in a shared virtual environment. Always
activate it before running Python by hand, so the Neuron tools are on your path:

```bash
source /opt/aws_neuronx_venv_pytorch/bin/activate
```

If you call the venv's Python without activating (for example
`/opt/aws_neuronx_venv_pytorch/bin/python`), `import torch_neuronx` fails looking
for `libneuronpjrt-path`. Activating the environment fixes this. The job
template does this for you, so this matters mainly for interactive checks.

### 4. Check the device

```bash
neuron-ls
python -c "import torch, torch_neuronx; import torch_xla.core.xla_model as xm; \
d = xm.xla_device(); x = torch.ones(8, device=d); print((x+x).sum())"
```

`neuron-ls` should list the Trainium device and its NeuronCores. The small
Python op compiles on first run (this is expected and can take a bit) and then
prints a result computed on the NeuronCore.

### 5. Run the worked example first

`examples/scale_by_two` is a complete "hello, Trainium" kernel. Run it once to
see the whole flow before you tackle a graded stub:

```bash
cd examples/scale_by_two
sbatch run.sh
squeue --me
```

The job stays queued until a Trainium node is free, then runs (usually
seconds). It writes `scale-by-two-<jobid>.out` in the directory you submitted
from; a successful run prints `Correctness passed? True` and a p99 latency in
microseconds. The example teaches the core NKI data-movement pattern: load a
tile from HBM into the on-chip SBUF, compute, store back, and tile any dimension
larger than SBUF's 128-partition limit. See
[`examples/scale_by_two/README.md`](./examples/scale_by_two/README.md).

### 6. Do a graded assignment

A graded assignment gives you a `student.py` stub to fill in. Edit your kernel,
then submit with the shared job template:

```bash
cd ~/scale_by_two          # your working copy
# edit student.py
sbatch $HOME/run.sh
```

Outputs land under `/shared/work/<you>/<job-name>/<job-id>/`:

- `stdout.log` and `stderr.log`: your run's logs.
- `result.json`: the grade signal; `correctness.passed` is true when your
  kernel's output matches the reference within tolerance.
- `profile/`: a `neuron-profile` capture (skipped if you set `SKIP_PROFILE=1`).

Read your result:

```bash
cat /shared/work/$USER/<job-name>/<job-id>/result.json
```

### 7. Selecting a Trainium node

On this cluster you select a whole Trainium node by feature, not per-core:

- `#SBATCH --constraint=neuron` requests any Trainium node (the template sets
  this).
- `#SBATCH --exclusive` gives you the node to yourself (no other jobs sharing
  it).
- `#SBATCH --constraint=neuroncores4` or `neuroncores16` pins to a specific
  shape (`trn2.3xlarge` has 4 NeuronCores, `trn2.48xlarge` has 16, `trn1.2xlarge`
  has 2).

There is no `--gres=neuroncore:N` on this cluster; per-core scheduling is not
available on PCS.

## Part 3: Command quick reference

Instructor:

| Task | Command |
|------|---------|
| Deploy (on-demand trn1) | `./scripts/deploy-pcs.sh --purchase-option ONDEMAND ...` |
| Deploy (trn2 MLCB) | `./scripts/deploy-pcs.sh --purchase-option CAPACITY_BLOCK --capacity-reservation-id cr-... --availability-zone ... ...` |
| Validate only | add `--dry-run` |
| Add login node | `./scripts/deploy-login-node.sh --ssh-allowed-cidr ... --key-name ... --efs-id fs-... ...` |
| Check a node | `aws ssm send-command --document-name AWS-RunShellScript --instance-ids i-... --parameters 'commands=["neuron-ls"]'` |

Student:

| Task | Command |
|------|---------|
| Connect | `ssh -i <key>.pem <user>@<login-node>` |
| Activate Neuron env | `source /opt/aws_neuronx_venv_pytorch/bin/activate` |
| Check device | `neuron-ls` |
| Submit a job | `sbatch $HOME/run.sh` (or `sbatch run.sh` in an example) |
| Watch your jobs | `squeue --me` |
| Read result | `cat /shared/work/$USER/<job>/<jobid>/result.json` |

## Part 4: Troubleshooting

`import torch_neuronx` fails with `libneuronpjrt-path` not found: you called the
venv Python without activating the environment. Run
`source /opt/aws_neuronx_venv_pytorch/bin/activate` first. The job template does
this automatically.

The first run is slow: the Neuron compiler builds a NEFF the first time a graph
runs. This one-time compilation is expected; subsequent runs of the same shape
are fast.

`Correctness passed? False` with all-zero output: the compute node's Neuron
environment is not the full, matched install. A correct result needs the shared
venv at `/opt/aws_neuronx_venv_pytorch` (with `torch-neuronx` and a matched
runtime and `neuronx-cc`), not a partial install. Tell your TA; suspect the
node's environment, not your kernel.

`/shared` is missing or empty on a compute node: the node may still be finishing
its Neuron install (about ten minutes after first boot), or the EFS mount
failed. Re-check with `mountpoint /shared`; if it persists, the TA should review
the node's `/var/log/trn-course-pcs-neuron-userdata.log`.

A job sits in the queue: there may be no free Trainium node, or the constraint
does not match any node. Check `sinfo` for node state and confirm you requested
`--constraint=neuron`.

Cannot SSH to the login node: confirm your source IP is within the
`--ssh-allowed-cidr` the instructor set, and that you are using the correct
private key and username.
