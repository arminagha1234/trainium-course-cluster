# Architecture

Concrete mapping from the PRD's architecture section to AWS resources.
Read the PRD first (`../PRD.md`) for the
motivation behind these choices. This doc is the "what and where" of the
implementation.

## Provisioning model

Two stacks in strict order:

1. **Parent CFN stack** (`infra/parent-stack.yaml`) — non-cluster scaffolding.
   Owns:
   - VPC (10.42.0.0/16), public subnet for the head node, private subnet for
     compute (pinned to the MLCB's AZ), NAT gateway, IGW.
   - Security groups for head, compute, and EFS.
   - EFS filesystem + mount targets in each subnet.
   - Secrets Manager secrets — one per student — holding their SSH private key.
   - S3 bucket for ParallelCluster staging (bootstrap scripts, slurm.conf
     include file).
   - The **Student Manifest custom resource** (Lambda) that generates SSH
     keypairs, writes public keys to a shared file on S3, private keys to
     Secrets Manager, and outputs the TA-facing manifest.
   - Budget + kill-switch stack (nested; see `infra/budget.yaml`).

2. **ParallelCluster cluster** (`infra/pcluster-config.yaml`) — created by the
   `pcluster create-cluster` CLI, which internally creates its own CFN stack.
   Owns:
   - Head node (m6i.xlarge default): `slurmctld`, `slurmd`, `munge`, sshd,
     mounts EFS, runs `bootstrap/head-node-setup.sh` via
     `HeadNode.CustomActions.OnNodeConfigured`.
   - Compute fleet (trn2.3xlarge, static, count = ComputeNodeCount): `slurmd`,
     neuron drivers + tools, mounts EFS, runs `bootstrap/compute-node-setup.sh`
     via `SlurmQueues[].ComputeResources[].CustomActions.OnNodeConfigured`.
   - Slurm queue `nki` with `CapacityType: CAPACITY_BLOCK`,
     `CapacityReservationTarget.CapacityReservationId = <MLCB>`,
     `MinCount == MaxCount == ComputeNodeCount`.
   - `CustomSlurmSettingsIncludeFile` = `s3://<staging bucket>/slurm/neuroncore-gres.conf`,
     which declares `GresTypes=neuroncore` and per-node `NodeName ... Gres=neuroncore:4`.

Why two stacks: the PC CLI wants its own CFN stack it owns end-to-end. Keeping
the VPC + EFS + manifest + secrets in a parent stack lets us stand them up
first, hand references to PC, and tear PC down without losing student data.

## Topology

```
   Instructor / TA laptop
            │  pcluster CLI + AWS CLI
            ▼
  ┌───────────────────────── Parent CFN stack ─────────────────────────┐
  │                                                                    │
  │   VPC 10.42.0.0/16                                                 │
  │   ┌──────── Public subnet (AZ = <MLCB AZ>) ────────┐               │
  │   │                                                │               │
  │   │      Head node (m6i.xlarge)  ─── slurmctld     │               │
  │   │        │  sshd (student ingress from CIDR)     │               │
  │   │        │  mounts EFS at /shared                │               │
  │   │        │  local users student01..N            │               │
  │   │        │                                       │               │
  │   │        └── students SSH here ──────────────────┼── SshAllowedCidr
  │   │                                                │               │
  │   └────────────────────────────────────────────────┘               │
  │           │ NAT ↔ IGW                                              │
  │   ┌──── Private subnet (same AZ, pinned to MLCB) ─┐                │
  │   │                                                │               │
  │   │   Compute node 1..N (trn2.3xlarge, static)    │               │
  │   │     slurmd, neuronx drivers/tools             │               │
  │   │     neuron group + udev rule                   │               │
  │   │     mounts EFS at /shared                     │               │
  │   │     users student01..N synced from head       │               │
  │   │                                                │               │
  │   └────────────────────────────────────────────────┘               │
  │                                                                    │
  │   EFS filesystem                                                   │
  │     /shared/home/<student>                                         │
  │     /shared/work/<student>/<assignment>/<jobid>/                   │
  │     /shared/assignments (RO, populated by TA)                      │
  │                                                                    │
  │   Secrets Manager: one secret per student holding the private key  │
  │   S3 staging bucket: bootstrap scripts + slurm include file        │
  │                                                                    │
  └────────────────────────────────────────────────────────────────────┘
```

## Component decisions

### Head node

`m6i.xlarge` default (4 vCPU / 16 GiB). Rationale: cheap ($0.192/hr) and
carries `slurmctld` + student login shells fine for a class of 50+. The head
node is not compute — it does not run NKI. Users interact with Neuron only
via `sbatch` onto compute nodes.

Ingress: TCP/22 restricted to `SshAllowedCidr` (required parameter, no
default). The security group has no `0.0.0.0/0` inbound rule.

The head node runs `bootstrap/head-node-setup.sh` which:
1. Creates POSIX users `student01..studentN` with fixed UIDs (10001..10000+N)
   for consistency with compute nodes.
2. Writes authorized public keys into each `~/.ssh/authorized_keys`.
3. Creates `/shared/home/<user>` + `/shared/work/<user>` on EFS.
4. Sets shell + skeleton files (`.bashrc` sourcing a Neuron env module).
5. Writes a shared users file (`/shared/etc/passwd.roster`) that compute
   nodes read on startup and via a cron sync.
6. Registers Slurm associations (`sacctmgr add account trn-class`, `add user
   <student>`) if `EnableSlurmAccounting` is true.

### Compute nodes

`trn2.3xlarge` default (1 Trainium chip = 4 NeuronCores, 96 GB HBM, 8 vCPU,
128 GiB RAM). Static — `MinCount == MaxCount`. Placement pinned to
`AvailabilityZone` parameter, which must match the MLCB.

`CapacityType: CAPACITY_BLOCK` + `CapacityReservationTarget` at the
ComputeResource level. Per the docs, static nodes are required with
CAPACITY_BLOCK. ParallelCluster manages the pre-active and post-expiry
transitions via a Slurm reservation on the "slurm" admin account.

**OS + AMI strategy.** The default image OS is `ubuntu2404` (Ubuntu 24.04 /
`noble`, Python 3.12 — the platform current Neuron SDK 2.x supports). By
default there is no custom AMI: ParallelCluster boots its **stock AMI** for the
selected OS and `bootstrap/compute-node-setup.sh` installs the public Neuron
SDK + `torch-neuronx` at first boot from the public apt/pip repos. An operator
can instead pin a prebuilt Neuron image with `--neuron-ami-id ami-...`, which
`deploy.sh` validates in-region and renders as the PC `Image.CustomAmi`; the
bootstrap install is then idempotently skipped if `torch-neuronx` already
imports.

`bootstrap/compute-node-setup.sh` is the compute queue's single
`OnNodeConfigured` hook (ParallelCluster allows exactly one script per node).
It:
1. Installs the **public Neuron SDK** from the public Neuron apt repo
   (`aws-neuronx-dkms` driver + `aws-neuronx-collectives` + `aws-neuronx-runtime-lib`
   + `aws-neuronx-tools`, all `2.*`) and a shared `torch-neuronx` venv at
   `/opt/aws_neuronx_venv_pytorch` (`neuronx-cc` + `torch-neuronx` +
   `torchvision`) from the public Neuron pip repo, then loads the driver and
   waits for `/dev/neuron*` to appear. The compute subnet is private but has
   NAT egress, so the public repos are reachable.
2. Creates the `neuron` system group if not present.
3. Writes `/etc/udev/rules.d/99-neuron.rules` (subsystem/kernel neuron*, group
   `neuron`, mode 0660) and reloads udev.
4. Syncs users from `/shared/etc/passwd.roster` (`useradd -M -u <uid>
   -G neuron <user>`) so UIDs match the head node.
5. Writes `/etc/slurm/gres.conf` declaring one `neuroncore` resource per
   `/dev/neuron<N>` with the NodeName Slurm sees for this host.
6. Restarts `slurmd` to pick up the new gres.

### NeuronCore gres wiring

Two files, two places.

**On compute nodes** (via bootstrap): `/etc/slurm/gres.conf`
```
Name=neuroncore File=/dev/neuron0
Name=neuroncore File=/dev/neuron1
Name=neuroncore File=/dev/neuron2
Name=neuroncore File=/dev/neuron3
```
Note: `/dev/neuron<idx>` is the Neuron device node — one per NeuronCore on
trn2.3xlarge. If a future instance changes this layout, the bootstrap must
detect it and generate `gres.conf` from `neuron-ls` output.

**On the head node** (via ParallelCluster `CustomSlurmSettingsIncludeFile`):
`slurm/slurm.conf.d/neuroncore-gres.conf`
```
GresTypes=neuroncore
NodeName=nki-st-trn2-3xl-[1-N] Gres=neuroncore:4
```
`N` is templated to `ComputeNodeCount` when the file is uploaded to S3 during
deploy.

Students request cores with:
```
sbatch --gres=neuroncore:1  # 1 core
sbatch --gres=neuroncore:4  # whole node
```

Slurm handles the "up to 4 jobs share one node" case natively via
`SelectType=select/cons_tres` (ParallelCluster default) + gres tracking.

**Fallback plan** if the above breaks in a specific PC version: set
`OverSubscribe=FORCE:4` on the queue and have the job wrapper set
`NEURON_RT_VISIBLE_CORES=<slurm-assigned-index>` from the Slurm job id
modulo 4. Less clean, no scheduling isolation. Kept in
`slurm/slurm.conf.d/oversubscribe-fallback.conf.disabled`.

### Storage

Amazon EFS with elastic throughput mode by default. One filesystem, one mount
target per subnet. Mounted at `/shared` on head + all compute via
`SharedStorage:` in the PC config.

Layout:
- `/shared/home/<student>` — home directory; per-user 700 perms
- `/shared/work/<student>/<assignment>/<jobid>/` — job outputs
- `/shared/assignments` — TA-populated, 755, read-only for students
- `/shared/etc/passwd.roster` — user sync source (owned by root, 644)

EFS is retained by default when the parent stack is deleted (`RetentionPolicy: Retain`).
Instructor can pass `--purge-efs` to teardown to override.

Not FSx for Lustre: kernel assignments are small (short jobs, tiny I/O, no
datasets to speak of). EFS gives us elastic scale without capacity planning
and survives cluster teardown independently.

### Student identity + key generation

The **Student Manifest custom resource** (Lambda) runs during parent stack
creation. On CREATE:
1. Generate `StudentCount` ed25519 SSH keypairs.
2. For each student `i` in 1..N:
   - Create Secrets Manager secret `trn-course-<cluster-name>-student<i>-key`
     containing the private key. Encrypt with KMS.
   - Append the public key to a JSON blob at `s3://<staging>/students.json`
     that head-node bootstrap consumes.
3. Emit a manifest as a stack output (structure below), including Secrets
   Manager ARNs (not key material).

On DELETE: delete all student secrets. Log the deletion timestamps.

Manifest schema (JSON, from stack output `StudentManifest`):
```json
{
  "cluster_name": "trn-course-fall26",
  "head_node_public_dns": "ec2-...",
  "capacity_block_id": "cr-...",
  "region": "ap-southeast-4",
  "availability_zone": "ap-southeast-4a",
  "generated_at": "2026-08-14T00:00:00Z",
  "students": [
    {
      "slot": 1,
      "username": "student01",
      "uid": 10001,
      "home": "/shared/home/student01",
      "work_dir": "/shared/work/student01",
      "private_key_secret_arn": "arn:aws:secretsmanager:...:student01-key",
      "public_key_fingerprint": "SHA256:...",
      "login_hint": "aws secretsmanager get-secret-value --secret-id <arn> --query SecretString --output text > student01.pem && chmod 600 student01.pem && ssh -i student01.pem student01@<head_public_dns>"
    }
  ]
}
```

The TA fetches this with `scripts/fetch-manifest.sh` (which just
`describe-stacks | jq`) and maps slots to named students out-of-band.

### Budget + auto-teardown

`infra/budget.yaml` is a lightly adapted `trainium-class/budget.yaml`. Same
90% kill-switch pattern; the Lambda's `StopInstances` policy is scoped to the
class tag. Since the MLCB is prepaid, this is more of a "runaway EBS / NAT /
Lambda" guard than a Trainium spend guard.

`infra/auto-teardown.yaml` creates an EventBridge rule that fires at the
MLCB's `EndDateTime` and invokes a Lambda that:
1. Runs `pcluster delete-cluster --cluster-name <name>` via a Lambda-embedded
   `pcluster` runtime (or a Step Function orchestration if that gets hairy).
2. Waits for cluster deletion to complete.
3. Deletes the parent stack (except EFS if retained).
4. Notifies the alerts SNS topic.

## What we deliberately did not build for V0

- Automated submission portal / autograder.
- SSM Session Manager access as an SSH alternative (adds IAM complexity for
  little student-facing gain).
- Slurm accounting DB (`Slurmdbd`) via Aurora — the QoS blog uses it, but for
  V0 a single partition with per-user limits doesn't need external accounting.
  Local Slurm accounting is on by default in PC 3.6+.
- Multi-node distributed jobs, EFA, cross-node MPI.
- FSx / S3 data path (kernel workloads don't need it).
- Native PyTorch beta stack — the PRD explicitly excludes this; we ship the
  public released SDK.

## Reference: what PC gives us out of the box

We do not have to write, and should not touch:
- Munge auth key generation and distribution
- Slurm daemon lifecycle (`slurmctld`, `slurmd`, `slurmdbd`)
- Compute fleet scale-up / scale-down (irrelevant for static nodes but PC
  still owns the node lifecycle around MLCB start/end)
- EFS mount unit generation and systemd wiring

Note we DO own the Neuron driver + runtime + `torch-neuronx` install: it is not
provided by PC in this kit. `bootstrap/compute-node-setup.sh` installs it from
the public Neuron apt/pip repos at first boot (see "Compute nodes" above).
