# Trainium Course Cluster (AWS PCS)

An open-source infrastructure kit for running hands-on AWS Trainium coursework,
such as NKI kernel assignments, on a shared Slurm cluster. An instructor
supplies a small set of inputs and pre-purchased capacity; the kit provisions
the cluster, creates per-student login accounts, and returns a roster. Students
SSH in, edit their kernel code, and submit jobs to Trainium nodes with `sbatch`.

The cluster runs on AWS Parallel Computing Service (PCS), which provides a
managed Slurm controller, so the kit hands PCS the networking, IAM, and a
launch template, and PCS owns the scheduler lifecycle. The full requirements
and design rationale are in [`PRD.md`](./PRD.md).

For step-by-step instructions see the [`USER-GUIDE.md`](./USER-GUIDE.md);
this README is the project overview.

## Who this is for

Research and education customers standing up short-lived Trainium clusters for a
class, workshop, bootcamp, or hackathon. There are three roles:

- Admin: owns the AWS account, the capacity, and cost guardrails.
- Instructor or TA: deploys and tears down the cluster, manages the roster, sets
  per-student limits, and monitors usage.
- Student: logs in, writes kernel code, submits jobs, and reads results and
  profiles from a personal working directory.

## What you get

- A managed Slurm control plane via PCS (no head node to operate).
- Trainium compute from either a trn2 ML Capacity Block or on-demand trn1.
- Per-student POSIX accounts with isolated home and work directories on a shared
  EFS filesystem that survives teardown.
- A correctness-and-profiling harness plus a worked example assignment.
- An optional Gradescope autograder.
- One-command deploy, and teardown that preserves student work.

## What it is not

- Not an autograder-by-default or a submission portal (grading is via provided
  scripts; the Gradescope autograder is optional).
- Not a multi-node or EFA distributed-training setup (single-node kernel work).
- Not a long-lived cluster (it lives for the capacity window; EFS persists).

## How it works

The kit provisions two layers. Account scaffolding: a self-referencing security
group, an `AWSPCS`-named IAM role and instance profile, an EFS filesystem for
`/shared`, and an EC2 launch template carrying the Neuron install user-data. The
PCS layer: a managed Slurm cluster, a compute node group backed by the launch
template, and a queue (`nki`) that maps to the Slurm partition students submit
to.

```
  instructor ── deploy-pcs.sh ─┐
                               ├─> PCS cluster (managed Slurm controller)
                               ├─> compute node group ── Trainium nodes (trn2 CB or trn1 on-demand)
                               │        each node: public Neuron SDK + torch-neuronx in a shared venv,
                               │                   EFS mounted at /shared
                               └─> queue "nki"  (partition; select nodes with --constraint=neuron)

  students ── ssh ──> login node ── sbatch ──> queue "nki" ──> Trainium node
                        (per-student accounts; /shared/home + /shared/work on EFS)
```

Compute nodes install the public Neuron SDK and `torch-neuronx` into a shared
virtual environment at `/opt/aws_neuronx_venv_pytorch` and mount EFS at
`/shared`. Because PCS has no head node, a separate login node gives students a
place to `ssh` in and submit from.

## Compute options

The `--purchase-option` flag selects the capacity model:

- `CAPACITY_BLOCK` (default): a trn2 ML Capacity Block. Requires a capacity
  reservation id and a subnet in the reservation's AZ. This is the path that has
  been validated most.
- `ONDEMAND`: on-demand Trainium such as `trn1.2xlarge`, `trn1.32xlarge`, or
  `trn1n.32xlarge`. No Capacity Block is required; the compute AZ is derived from
  the subnet. Supported regions include `us-east-1` and `us-west-2`.

Supported regions: `sa-east-1` and `us-east-2` for trn2 Capacity Blocks;
`us-east-1` and `us-west-2` for on-demand trn1.

## Quick start

On-demand trn1 (no Capacity Block):

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

trn2 ML Capacity Block:

```bash
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

Add `--dry-run` to validate inputs without creating resources. After the
cluster is up, add a login node and hand out accounts; see
[`USER-GUIDE.md`](./USER-GUIDE.md) for the full instructor and student
workflow.

## Repo layout

```
trainium-course-cluster/
  README.md                    project overview (this file)
  USER-GUIDE.md                instructor, TA, and student instructions
  PRD.md                       product requirements (V0)
  scripts/
    deploy-pcs.sh              provision the PCS cluster + compute + EFS
    deploy-login-node.sh       add a login node (student SSH, accounts, QoS)
  bootstrap/
    neuron-userdata.sh         compute-node user-data: Neuron SDK + /shared mount
    login-node-setup.sh        login-node config: sackd join, users, sacctmgr
  slurm/job-templates/run.sh   sbatch template (--constraint=neuron)
  harness/                     correctness + profiling harness, example assignment
  autograder/                  optional Gradescope autograder
  infra/pcs.yaml               CloudFormation mirror of the deploy (best-effort)
  docs/design.md               architecture, phase status, live-validation notes
```

## Current status

Validated live on real hardware:

- On-demand trn1 end to end (`us-west-2`, 2x `trn1.2xlarge`): cluster and node
  group reach ACTIVE, `neuron-ls` sees the device, the shared venv imports
  `torch-neuronx`, a kernel compiles and runs on the NeuronCore, and EFS
  `/shared` mounts with the student directory skeleton.
- PCS on a trn2 ML Capacity Block: the core provisioning path.
- The login node joins the managed Slurm controller via `sackd`.

Implemented but not yet exercised end to end:

- Per-student POSIX accounts and `sacctmgr` per-student QoS (wall-time and
  concurrent-job limits).
- The `student_manifest` roster automation wired into the PCS flow.
- Managed Slurm accounting, which requires a recent AWS CLI; on older CLIs the
  deploy falls back to a cluster without accounting and per-student QoS
  enforcement is unavailable until the CLI is upgraded.

## Limitations

- No per-NeuronCore scheduling on PCS. `neuroncore` cannot be a Slurm GRES on
  PCS, so students select whole nodes with `--constraint=neuron` (use
  `--exclusive` for sole use). Multiple students sharing one node at NeuronCore
  granularity is not available. See [`docs/design.md`](./docs/design.md) Phase 2.
- trn2 on a Capacity Block via PCS works but is outside AWS's documented support
  matrix (the PCS docs list Capacity Blocks for P-family GPUs). Validate on your
  own account before relying on it for a live class.
- On-demand trn1 is validated for the compute path but has not been run at
  full class scale.

## Security posture

- The login node is the only ingress; its SSH is restricted to a CIDR you
  supply (never an open range), and it enforces IMDSv2.
- Compute nodes sit in the cluster VPC on a self-referencing security group.
- Students get no sudo and isolated home and work directories; per-student SSH
  keys are stored in AWS Secrets Manager, not in plaintext outputs.

## Documentation

- [`USER-GUIDE.md`](./USER-GUIDE.md): instructor, TA, and student instructions.
- [`docs/design.md`](./docs/design.md): architecture, phase status, and
  live-validation notes.
- [`PRD.md`](./PRD.md): product requirements.

## References

- AWS PCS Capacity Blocks: https://docs.aws.amazon.com/pcs/latest/userguide/capacity-blocks.html
- AWS PCS Slurm accounting: https://docs.aws.amazon.com/pcs/latest/userguide/slurm-accounting.html
- AWS PCS IAM instance profiles: https://docs.aws.amazon.com/pcs/latest/userguide/security-instance-profiles.html
- AWS Neuron documentation: https://awsdocs-neuron.readthedocs-hosted.com

<!-- AWS PCS and Neuron behavior described here is summarized from AWS documentation. -->
