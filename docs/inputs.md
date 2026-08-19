# Inputs Reference

Every parameter the instructor passes to `scripts/deploy.sh` (which
translates them to CFN parameters on `infra/parent-stack.yaml` and jinja-
substitutes them into `infra/pcluster-config.yaml`). Defaults are what the
PRD calls for; blast radius is what breaks if you get it wrong.

## Required

| Parameter | Type | Example | Blast radius if wrong |
|---|---|---|---|
| `--cluster-name` | lowercase, 3-40 chars, `[a-z][a-z0-9-]{2,39}` | `trn-course-fall26` | No default. Must be unique in the region — it names every stack (`<name>-parent`, `<name>-budget`, `<name>-auto-teardown`) and the pcluster; a collision fails the deploy. |
| `--capacity-reservation-id` | string, `cr-...` | `cr-0abc123...` | Compute nodes fail to launch; `pcluster create` succeeds but nodes stay in Slurm reservation. Not required with `--parent-only`. |
| `--availability-zone` | AWS AZ name | `sa-east-1a` | If it does not match the MLCB's AZ, launches fail with "insufficient capacity". `deploy.sh` cross-checks against the reservation and hard-fails on mismatch. |
| `--region` | AWS region | `sa-east-1` | **Only `sa-east-1` and `us-east-2` are accepted** (allow-list; see the "Region" section below). `sa-east-1` is the trn2.3xlarge home; `us-east-2` is accepted for trn2.48xlarge MLCBs. Any other region — including `ap-southeast-4` — is a hard fail before any AWS call, in every mode. |
| `--student-count` | int, 1..500 | `20` | Sets N students; head node is sized fine up to a few hundred. |
| `--ssh-allowed-cidr` | one CIDR, or up to 5 comma-separated CIDRs | `1.2.3.0/24` or `10.20.0.0/16,192.0.2.0/24` | Head-node TCP/22 ingress. **No default, to prevent open SSH.** `0.0.0.0/0` and `::/0` are rejected in *any* range. Use a course VPN or office range; one head-node ingress rule is emitted per range. |
| `--alert-email` | email | `you@your.org` | Budget alerts + kill-switch notifications go here. Requires an SNS confirm-subscription click. |
| `--admin-ssh-key-name` | EC2 keypair name | `course-admin` | The EC2 keypair for the head-node `ubuntu` sudoer; must already exist in the region (`deploy.sh` verifies it). Not required with `--parent-only`. |

## Common overrides

| Parameter | Default | When to change |
|---|---|---|
| `--compute-node-count` | 1 | Match the MLCB's `TotalInstanceCount`. With 4 cores/node, 1 node fits 4 concurrent single-core jobs. |
| `--compute-instance-type` | `trn2.3xlarge` | Only change if the MLCB is for a different Trn2 shape. `trn2.48xlarge` (16 NeuronCores) is single-node teaching that only makes sense at very large class sizes. |
| `--head-instance-type` | `m6i.xlarge` | Bump to `m6i.2xlarge` for 100+ students, or if you notice head-node CPU pressure in CloudWatch. |
| `--username-prefix` | `student` | Change if you want `nki01` etc. Usernames are `<prefix><zero-padded slot>`. |
| `--class-tag` | `nki-2026-fall` | Attached to every resource for cost allocation and used to scope the budget kill-switch. Enable this tag in Billing → Cost Allocation Tags. |
| `--monthly-budget-usd` | 500 | The MLCB cost is prepaid; this budget is for spillover (EBS, NAT, Lambda, small unexpected EC2). Set to ~10% of MLCB cost. |
| `--retain-efs` | `true` | Teardown leaves EFS intact so student work survives. Pass `--retain-efs false` to drop it on teardown. |
| `--dry-run` | (off) | Validate all inputs and print what would be deployed, then exit before any AWS mutation. |

## Per-student Slurm limits

Enforced through a Slurm QoS plus per-student associations. Slurm accounting is
always on: `deploy.sh` provisions a head-node-local MariaDB accounting database
automatically (there is **no** `--enable-slurm-accounting` flag and no external
RDS), and that local accounting is what makes the limits below actually enforce.

| Parameter | Default | Notes |
|---|---|---|
| `--max-wall-time` | `1-00:00:00` | Per-job wall-clock cap (`MaxWall`). Slurm time string: `[days-]HH:MM:SS`, `HH:MM:SS`, `MM:SS`, or a bare minute count. Must resolve to between 1 minute and 7 days. |
| `--max-concurrent-jobs-per-user` | 8 | Max simultaneously running jobs per student (`MaxJobsPerUser`). Integer 1..100. |
| `--max-cores-per-user` | 4 | Max NeuronCores a student can hold at once (`MaxTRESPerUser=gres/neuroncore`). Integer 1..cluster total (`--compute-node-count` × NeuronCores/node). |
| `--core-hours-budget` | 0 | Per-student NeuronCore-hours budget (`GrpTRESMins`). `0` = unlimited. |

## Advanced

| Parameter | Default | Notes |
|---|---|---|
| `--neuron-ami-id` | none (stock AMI + bootstrap install) | **Optional.** Pin a specific Neuron AMI, used verbatim as the ParallelCluster `Image.CustomAmi` and validated in-region before cluster creation. When omitted (the default), ParallelCluster boots its stock `--image-os` AMI and the compute bootstrap installs the public Neuron SDK + `torch-neuronx` at first boot from the public apt/pip repos. |
| `--vpc-cidr` | `10.42.0.0/16` | Change on collisions with peered VPCs. |
| `--public-subnet-cidr` | `10.42.0.0/24` | Head-node subnet. |
| `--private-subnet-cidr` | `10.42.1.0/24` | Compute subnet, pinned to `--availability-zone`. |
| `--efs-throughput-mode` | `elastic` | Very cost-sensitive: `bursting` is cheaper for near-idle EFS. |
| `--image-os` | `ubuntu2404` | Base OS for head + compute. Ubuntu 24.04 (`noble`, Python 3.12) is the platform Neuron SDK 2.x supports; `ubuntu2204` is EOL on Neuron. |
| `--repo-dir` | parent of `scripts/` | Point at a different checkout of this kit; `deploy.sh` reads templates, bootstrap scripts, and Lambda code from here. |
| `--parent-only` | (off) | Deploy only the parent stack (VPC, EFS, security groups, staging bucket, Manifest Lambda). Skips the MLCB, pcluster, budget, and auto-teardown steps and their validation. For testing the scaffolding without an MLCB. |

## Not parameterized (deliberately)

- The Slurm scheduler choice. Fixed to Slurm (AWS Batch is not a fit for
  kernel iteration).
- The single partition name (`nki`). One queue, one QoS, one course.
- The number of NeuronCores per Trn2.3xlarge node (`4`). This is a hardware
  fact.
- SSH keypair algorithm — ed25519. RSA compat is not worth the operational
  overhead.

## How `--student-count` interacts with `--compute-node-count`

With `--compute-node-count=1` and `--student-count=20`, you have 20 login
accounts sharing 4 NeuronCores. Concurrency at the Slurm level is 4 single-
core jobs. The other 16 jobs sit in the queue.

This is the intended shape for iterative kernel work — students spend most
of their time editing, not running. The queue wait is a feature, not a bug:
it forces bounded runs and prevents any one student from monopolizing.

For a "burst hour" during a live lab, size up:
- 5-student class: `compute-node-count=1` (4 cores → 4 concurrent)
- 20-student class: `compute-node-count=1` or `2` (accept 5:1 or 2.5:1 queue depth)
- 50-student class: `compute-node-count=3` or `4` (~4:1)

Cost sizing lives in `docs/architecture.md#component-decisions` — MLCB is
prepaid so this is a purchase-time decision, not a live one.

## Validation

`scripts/deploy.sh` validates locally, before any AWS call (these run in every
mode, including `--parent-only`):
- `--region` is `sa-east-1` or `us-east-2` — any other region is a hard fail
- `--cluster-name` matches `[a-z][a-z0-9-]{2,39}`
- `--student-count` is in 1..500 and `--compute-node-count` is a positive integer
- each `--ssh-allowed-cidr` range is a valid CIDR, at most 5 ranges are given, and none is `0.0.0.0/0` or `::/0` (hard fail)
- the per-student limits are in range (wall time 1 min..7 days; concurrent jobs 1..100; cores 1..cluster total; core-hours ≥ 0)

Then, against AWS (skipped under `--parent-only`):
- the MLCB id resolves and its AZ, instance type, and count match the flags (`describe-capacity-reservations`)
- the `--admin-ssh-key-name` keypair exists in the region
- **only when `--neuron-ami-id` is supplied:** that AMI resolves and is `available` in the region (the default stock-AMI path performs no AMI lookup)

The parent CFN template validates on the server side too (e.g. it re-rejects
open SSH ranges), but the local checks give you a fast rejection loop.

## Region

`deploy.sh` accepts two regions: `sa-east-1` and `us-east-2`.

`trn2.3xlarge` MLCBs are sold in `sa-east-1` (São Paulo) and `ap-southeast-4`
(Melbourne); `trn2.48xlarge` MLCBs are used in `us-east-2` (Ohio):

| Region | MLCB support | ParallelCluster support | Accepted by `deploy.sh` |
|---|---|---|---|
| São Paulo (`sa-east-1`) | ✓ (trn2.3xlarge) | ✓ | ✓ |
| Ohio (`us-east-2`) | ✓ (trn2.48xlarge) | ✓ | ✓ |
| Melbourne (`ap-southeast-4`) | ✓ (trn2.3xlarge) | ✗ (not in [PC's supported regions](https://docs.aws.amazon.com/parallelcluster/latest/ug/supported-regions.html)) | ✗ |

**Use `sa-east-1` (trn2.3xlarge) or `us-east-2` (trn2.48xlarge) for this stack.**
`deploy.sh` hard-fails on any other region, including `ap-southeast-4`.

If you already own a Melbourne MLCB and are stuck, options:
1. Sell the block back to AWS (only possible before start time; check current terms).
2. Deploy without ParallelCluster — the raw-EC2 pattern in `trainium-class/` in
   this repo works in Melbourne and does not use PC.
3. Wait for PC to add Melbourne support (no ETA as of 2026-08).
