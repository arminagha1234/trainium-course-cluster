---
type: prd
title: Trainium Course Cluster (Automated Slurm Infra for Student Kernel Assignments)
audience: public repo (Build on Trainium course infrastructure)
author: John Gray (grayjh)
created: 2026-08-14
status: draft v0
---

# Trainium Course Cluster - Product Requirements (V0)

## Summary

A reusable, open-source infrastructure kit that stands up a centralized Slurm
cluster on AWS Trainium for a class of students to complete NKI kernel
assignments. An instructor or TA supplies a small set of inputs (student count,
compute instance type, and a pre-purchased ML Capacity Block); the kit
provisions the cluster, creates per-student login accounts, and returns a
manifest the TA maps to real students. Students SSH in, edit their kernel code
in a per-student working directory, and submit jobs to Trainium nodes with
`sbatch`. Each student's runs are logged under their own folder.

## Goals

- One-command stand-up of a Slurm cluster on Trainium backed by a pre-purchased
  ML Capacity Block (MLCB).
- Automated creation of N isolated student login accounts from a single
  `StudentCount` input, returned as a TA-facing manifest.
- Manual `sbatch` submission workflow with per-student working and log
  directories on a shared filesystem.
- Core-level sharing of Trainium devices so multiple small kernel jobs run
  concurrently on one instance.
- Clean teardown at the end of the capacity block, with student data preserved
  independently of the cluster lifecycle.

## Non-Goals (V0)

- No automated submission portal or autograder (manual `sbatch` only; grading
  harness is provided as scripts, not a service).
- No multi-node / EFA distributed training (kernel assignments are single-node).
- No Native PyTorch beta stack (V0 uses the public released Neuron SDK).
- No matching production MFU or performance SLAs.
- No long-lived cluster; the cluster lives for the capacity block window only.

## Personas

- Student: has an SSH key and a login on the head node. Edits kernel code,
  submits `sbatch` jobs, inspects logs and profiles under their own directory.
  No sudo, no direct compute-node access.
- TA / Instructor: runs stand-up and teardown, receives the account manifest,
  maps slots to students, sets per-student limits, and monitors utilization and
  who ran what.
- Admin (repo operator): owns the AWS account, the MLCB, and the AMI; owns cost
  guardrails and security posture.

## User Stories

- As a TA, I provide a student count and an MLCB id and get back a running
  cluster plus a manifest of usernames and private keys to hand out.
- As a student, I SSH to the head node, land in my own home directory, clone or
  copy my assignment, and run `sbatch run.sh` to execute my kernel on Trainium.
- As a student, I read my job's stdout, correctness result, and profile output
  from my per-student log directory.
- As a TA, I can see each student's job history and Trainium-hours used, and cap
  a student's concurrent jobs and wall time.
- As an admin, the cluster tears down at the end of the capacity block and the
  student work on shared storage survives.

## Architecture

### Provisioning model

A parent CloudFormation template provisions the account-level scaffolding and
invokes AWS ParallelCluster for the cluster itself:

- CloudFormation owns: VPC, subnets, security groups, the shared filesystem, IAM
  roles, a key/manifest generator (custom resource), and cost/teardown
  automation.
- ParallelCluster owns: Slurm control plane and daemons, munge auth, compute
  fleet lifecycle, Neuron `gres` registration, and filesystem mounts on head and
  compute nodes.

Rationale: ParallelCluster is purpose-built for Slurm on Trainium and already
handles Neuron `gres`, capacity-reservation targeting, and scale behavior that
would otherwise be hand-rolled and maintained in raw templates. It is itself
CloudFormation underneath, so wrapping it keeps a single-stack UX.

### Topology

- Head / login node: non-Trainium instance (for example `m6i` / `c6i`), always
  on for the block window. Hosts `slurmctld`, student login shells, and the
  shared filesystem mount. Only ingress point.
- Compute fleet: `trn2.3xlarge` default (1 Neuron device, 4 NeuronCores, 96 GB
  HBM; source: `.kiro/steering/beta-setup-log.md`), parameterized by instance
  type. Placed in private subnets, pinned to the MLCB and its AZ.
- Static nodes for the block window (capacity is paid for regardless, so keep
  nodes up to avoid scale-up latency and maximize student access).

### MLCB lifecycle constraints

- Capacity blocks are time-boxed and single-AZ; the cluster exists only inside
  that window. The template must key the compute AZ and subnet to the
  reservation.
- Compute launches require `MarketType=capacity-block` in addition to the
  capacity-reservation target, or `RunInstances` fails with
  `InvalidParameterValue` (source: `.kiro/steering/beta-setup-log.md`).
- Input is the capacity reservation id; V0 assumes the block is already
  purchased and active.

### Core-level device sharing

Kernel assignments are small and iterative and typically use a single
NeuronCore, so a `trn2.3xlarge` (4 cores) can host up to 4 concurrent student
jobs. Requirements:

- Register NeuronCores as a Slurm `gres` so students request cores, not whole
  nodes (for example `sbatch --gres=neuroncore:1`).
- Default job requests 1 core; allow up to 4 for multi-core exercises.
- Verify the `gres` core-granularity behavior against the current ParallelCluster
  Neuron integration (see Open Questions); if per-core `gres` is not natively
  exposed, fall back to `OverSubscribe` on cores plus `NEURON_RT_VISIBLE_CORES`
  pinning in the job wrapper.

## Multi-Tenancy and Account Provisioning

This is the core of "student submissions."

### Identity

- One POSIX user per student on the head node for real isolation and per-student
  Slurm accounting.
- Home directory per student on the shared filesystem; a per-student
  work/log directory (see Storage).
- No sudo; students cannot SSH to compute nodes (submit via `sbatch` only).

### Key and manifest generation

- Input `StudentCount = N` drives creation of N accounts (`student01 ... studentNN`
  or a configurable prefix).
- A Lambda-backed CloudFormation custom resource generates an SSH keypair per
  student, creates the POSIX users, and writes an authorized public key for
  each.
- Private keys are the sensitive output. Store them in AWS Secrets Manager (or a
  restricted S3 prefix), never in stack outputs in plaintext. The manifest
  references retrieval locations, not raw key material, unless the TA explicitly
  opts into an inline bundle.
- The manifest is the TA-facing artifact mapping anonymous slots to credentials;
  the TA maps slots to named students out-of-band.

### Manifest schema (proposed)

```json
{
  "cluster_name": "trn-course-fall26",
  "head_node": { "public_dns": "ec2-...", "ssh_port": 22 },
  "capacity_block_id": "cr-0...",
  "generated_at": "2026-08-14T00:00:00Z",
  "students": [
    {
      "slot": 1,
      "username": "student01",
      "home": "/shared/home/student01",
      "work_dir": "/shared/work/student01",
      "private_key_secret_arn": "arn:aws:secretsmanager:...:student01-key",
      "login_hint": "ssh -i student01.pem student01@<head_public_dns>"
    }
  ]
}
```

### Slurm accounting and limits

- Per-student Slurm association (`sacctmgr`) for fair-share scheduling and usage
  accounting.
- Configurable per-student caps: max wall time per job, max concurrent jobs, max
  cores in use, and optional Trainium-core-hours budget.
- Single partition/queue for V0.

## Submission Workflow (Manual sbatch)

- Students land in their home dir on login and copy or `git clone` the
  assignment into their work dir.
- The repo ships a job template (`run.sh`) that requests cores via `gres`,
  activates the Neuron environment, runs the student kernel, and writes stdout,
  the correctness result, and a profile to the student's log dir.
- Per-assignment harness (provided as scripts, not a service): a correctness
  check against a reference implementation and a `neuron-profile` capture, so
  kernel assignments have a consistent test/measure loop. Pattern reference:
  `documents/krai/test_harness.py` and `documents/krai/profile_harness.py`.
- Log layout: `/shared/work/<student>/<assignment>/<jobid>/` holding
  `stdout.log`, `result.json` (pass/fail plus latency), and the profile artifact.

## Software Environment

- Public released Neuron SDK delivered via a pre-baked custom AMI (parameterized
  AMI id) for reproducibility and fast node boot. AMI build pattern already
  exists in `.kiro/steering/beta-setup-log.md`.
- Toolchain for kernel work: `nki`, `neuronx-cc`, `neuron-profile`, and the
  Neuron runtime. Students access it via a pre-created venv or `module load`.
- Profiling permissions: confirm `neuron-profile` works for a non-root student
  user inside a `gres`-scoped core allocation (see Open Questions).

## Storage Layout

- Shared filesystem: Amazon EFS for V0 (elastic throughput). Mounted on head and
  all compute nodes.
  - `/shared/home/<student>` (home dirs)
  - `/shared/work/<student>` (assignment code and per-job logs)
  - `/shared/assignments` (read-only starter code, references, datasets)
- EFS persists independently of the cluster stack, so student work survives
  teardown at block end.
- Tradeoff noted: EFS is fine for kernel assignments (small code, short jobs,
  light I/O). If a future course does large-dataset or checkpoint-heavy
  training, revisit `FSx for Lustre` or S3 staging (Nafea's documented
  preference is S3 over FSx for large-scale). Out of scope for V0.

## Configurable Inputs

- `StudentCount` (drives account and manifest generation)
- `ComputeInstanceType` (default `trn2.3xlarge`)
- `CapacityReservationId` (the MLCB) and derived AZ/subnet
- `ComputeNodeCount` (tune student:compute ratio)
- `Region`
- `NeuronAmiId` (public SDK, pinned)
- `HeadNodeInstanceType`
- `EfsThroughputMode` and size
- Per-student limits: `MaxWallTime`, `MaxConcurrentJobs`, `MaxCores`
- `SshAllowedCidr` (lock head-node ingress; do not default to `0.0.0.0/0`)
- `UsernamePrefix`

## Outputs

- The account manifest (JSON above), plus a human-readable table for the TA.
- Head node connection details.
- Secrets Manager ARNs (or restricted S3 URIs) for private keys.

## Cost Controls and Lifecycle

- Static compute for the block window; no scale-up latency for students.
- Auto-teardown at capacity-block end (EventBridge on the end time or a scheduled
  stack delete) so the head node does not bill idle after the block.
- CloudWatch billing alarm plus hard Slurm limits so a runaway job cannot burn
  the whole block.
- Teardown preserves EFS (separate stack or retain policy) so student work is
  recoverable.

## Security Posture

- Head node is the only ingress; compute fleet in private subnets.
- No inbound SSH from `0.0.0.0/0`; require `SshAllowedCidr` (course network or
  VPN). Note: the existing bootcamp SG defaults to open SSH, which this kit must
  not repeat.
- Students: no sudo, no compute-node SSH, isolated home/work dirs, per-user keys.
- Private keys never emitted as plaintext stack outputs; stored in Secrets
  Manager / restricted S3.
- Least-privilege IAM for the head node and the provisioning Lambda.

## V0 Scope vs Later

V0 (this PRD):
- ParallelCluster on Trn2 via MLCB, EFS, per-student POSIX + SSH accounts,
  manifest output, core-level `gres`, manual `sbatch`, public SDK, kernel
  harness scripts, auto-teardown.

Later (V1+):
- Automated submission/autograder pipeline (git push or S3 drop triggers `sbatch`,
  auto-scored results).
- SSM access option (no key distribution).
- Multi-node / EFA for distributed exercises.
- Native PyTorch beta stack option.
- FSx / S3 data path for large datasets.
- Leaderboard for kernel performance assignments.

## Open Questions / Verification Items

- Confirm current AWS ParallelCluster support for capacity-block reservations and
  the exact config for pinning compute to an MLCB (version-specific; verify
  against current ParallelCluster docs).
- Confirm ParallelCluster exposes NeuronCore-level `gres`, or whether core-level
  sharing needs `OverSubscribe` plus `NEURON_RT_VISIBLE_CORES` pinning in the job
  wrapper.
- Confirm `neuron-profile` works for a non-root student in a core-scoped
  allocation.
- Decide manifest key-delivery: Secrets Manager ARNs (safer) vs an inline
  encrypted bundle the TA distributes.
- Decide account naming and whether the roster maps to real names in-tool or
  stays anonymous slots the TA maps externally.
- Confirm the public SDK AMI to pin (region-specific AMI id) and the toolchain
  versions for the target assignments.

## References

- `.kiro/steering/beta-setup-log.md` (trn2.3xlarge specs, capacity-block launch
  flag, AMI build pattern)
- `documents/krai/test_harness.py`, `documents/krai/profile_harness.py` (kernel
  correctness + profile harness pattern)
- `.kiro/steering/project-overview.md` (Build on Trainium, academic program
  context)

---
*Note: This PRD is included in-tree so the repo is self-contained. The
"answered" versions of the Open Questions above are in
`docs/open-questions-answered.md`.*
