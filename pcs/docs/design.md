# PCS variant — design

How the Trainium Course Cluster maps from **AWS ParallelCluster** (the parent
kit, `../../`) onto **AWS Parallel Computing Service (PCS)**, and what is not
built yet. Read the parent kit's [`../../docs/architecture.md`](../../docs/architecture.md)
first for the shared concepts (single-AZ VPC, MLCB-backed static compute,
NeuronCore gres, per-student POSIX users, EFS `/shared`).

The headline difference: with ParallelCluster you own the head node and its
`slurmctld`; with PCS the **Slurm controller runs in a service-owned account**
and you hand PCS a launch template + IAM + networking. That moves several
responsibilities (controller lifecycle, node registration) to AWS, but it also
means the things ParallelCluster did *on the head node* (login shells, user
sync, `gres.conf`, `sacctmgr`) no longer have an obvious home — hence the phased
follow-up work below (most now implemented but not yet live-validated, one item
structurally ruled out on PCS, a few still open).

## PC → PCS architecture mapping

| Concern | ParallelCluster kit (`../../`) | AWS PCS variant (this kit) | Status |
|---|---|---|---|
| Scheduler control plane | `slurmctld` on a head node you own | Managed Slurm controller in a PCS service account | Done (managed) |
| Cluster definition | `infra/pcluster-config.yaml` (one file) → `pcluster create-cluster` | `aws pcs create-cluster` + `create-compute-node-group` + `create-queue`; mirrored in `infra/pcs.yaml` | Done |
| Compute provisioning | `SlurmQueues[].ComputeResources[]`, `CapacityType: CAPACITY_BLOCK`, static `MinCount==MaxCount` | `AWS::PCS::ComputeNodeGroup`, `PurchaseOption=CAPACITY_BLOCK`, `ScalingConfiguration` min==max | Done |
| Capacity Block targeting | `CapacityReservationTarget` on the ComputeResource | Launch template `CapacityReservationSpecification` + `InstanceMarketOptions.MarketType=capacity-block` | Done (proven) |
| AMI + Neuron SDK | PC stock AMI + `bootstrap/compute-node-setup.sh` (`OnNodeConfigured`) installs public Neuron SDK | PCS sample AMI (SSM) + `bootstrap/neuron-userdata.sh` (launch-template UserData) installs public Neuron SDK | Done |
| First-boot hook | PC `CustomActions.OnNodeConfigured` | Launch-template UserData (or PCS **node lifecycle actions** for staged scripts) | Done (UserData) |
| Slurm node registration | PC cookbook configures + starts `slurmd` | **PCS agent** baked into the PCS AMI registers the node | Done (managed) |
| Networking | `infra/parent-stack.yaml` builds VPC + subnets + SGs | Caller supplies VPC + private subnet (CB AZ); this kit creates the self-referencing SG | Partial (VPC/subnet reused) |
| Security group shape | Head SG (student SSH) + compute SG + EFS SG | One self-referencing SG (all traffic within itself + all egress) — the shape PCS requires | Done |
| IAM | PC-managed instance roles | This kit creates an **`AWSPCS`-named** role + instance profile with the 4 managed policies | Done |
| Login / student SSH | PC **HeadNode** (login shells + `slurmctld`) | Standalone EC2 **login node** (`scripts/deploy-login-node.sh` + `bootstrap/login-node-setup.sh`) that joins the managed cluster via `sackd` | **Done (Phase 1)** — core join validated live |
| NeuronCore gres | `CustomSlurmSettingsIncludeFile` (GresTypes + NodeName Gres) + `gres.conf` via bootstrap | `Gres` in **neither** PCS allow-list → CNG `Features=neuron,neuroncores<N>` + student `--constraint=neuron` (node-level only; per-core isolation lost) | **Changed (Phase 2)** |
| Per-student limits | Head-node-local MariaDB + `slurmdbd` + `sacctmgr` QoS/associations | PCS **managed accounting** (`Accounting.Mode=STANDARD`) + cluster `AccountingStorageEnforce` + `sacctmgr` on the login node — wall-time + concurrent-jobs only (no per-core / core-hours) | **Done, reduced (Phase 3)** |
| Shared storage `/shared` | PC `SharedStorage: Efs` mounts EFS on every node | EFS filesystem + mount target on the cluster SG, mounted at first boot via UserData; login node mounts the same EFS | **Done (Phase 4)** — not live-validated |
| Per-student users on compute | `head-node-setup.sh` writes roster to EFS; `compute-node-setup.sh` syncs | Login node creates users + publishes `/shared/etc/passwd.roster`; compute-side periodic re-sync is an optional follow-up | **Done (Phase 1)** — re-sync optional |
| Budget / kill-switch / teardown | `infra/budget.yaml`, `infra/auto-teardown.yaml` + Lambdas | **Reuse** parent Lambdas (`../../lambda/kill_switch`, `../../lambda/auto_teardown`); wiring TBD | **Open (reuse)** |
| Student manifest (users + keys) | Parent-stack custom resource (`../../lambda/student_manifest`) | **Reuse** the same Lambda; drive from the login node / a small stack | **Open (reuse)** |
| Correctness/profiling harness | `../../harness/` | **Reuse** as-is (sources the shared Neuron venv) | Done (reuse) |
| Slurm job templates | `../../slurm/job-templates/` | Parent `--gres=neuroncore:N` templates **don't schedule on PCS**; ships its own `slurm/job-templates/run.sh` using `--constraint=neuron` | **Changed (Phase 2)** |

## PHASE STATUS

The four follow-up phases needed to reach parity with the parent kit now have
implementations in this kit. A live run (2026-08, sa-east-1 — see
"Live validation (2026-08, sa-east-1)" below) has since exercised the **Phase 1
login-node core join** and the **Phase 2 NeuronCore-gres finding** on real PCS
trn2 hardware. The remainder of Phases 1–4 (per-student QoS end-to-end, EFS
`/shared`) was written against the AWS docs and the parent kit's mechanisms but
has **not** yet been exercised on a running PCS cluster. Read each phase's own
status line below for what is proven-live vs. implemented-only.

### Phase 1 — Login node (student SSH + POSIX users + `sacctmgr` host) — IMPLEMENTED — core join VALIDATED LIVE

**Why:** PCS has no head node, so there is nowhere for students to `ssh` in and
`sbatch`, and nowhere to run `sacctmgr`. A login node fills that role.

**What was built:** two new files — `scripts/deploy-login-node.sh` (launches the
login node) and `bootstrap/login-node-setup.sh` (configures it). The login node
is a **standalone EC2 instance** in the cluster VPC/subnet, attached to the
cluster security group, that joins the managed cluster as a submit host via
**`sackd`** (the Slurm auth/config daemon), following the AWS-documented
standalone-login-node flow: the instance is pointed at the managed cluster's
Slurm endpoints and pulls its client config from the PCS controller. TCP/22 is
restricted to the course CIDR (`--ssh-allowed-cidr`, never an open range),
mirroring the parent kit.

**Live validation (sa-east-1, cluster `pcs-trn2-cb-test` / `pcs_4awjpg2se6`):**
the core join was exercised on a live managed PCS cluster. A standalone EC2 in
the cluster's public subnet and cluster security group joined the managed Slurm
controller via `sackd`: it fetched the cluster auth key from Secrets Manager into
`/etc/slurm/slurm.key` (mode `0600`, owner `slurm:slurm`), ran
`sackd --conf-server=<slurmctld ip:port>` as a systemd unit, and reached
`systemctl is-active sackd` = `active` (`sackd ... running`). `sinfo` and
`scontrol show node` then queried the managed controller successfully. The PCS
sample AMI (`dlami-base-ubuntu2404`) already ships Slurm under
`/opt/aws/pcs/scheduler/slurm-25.11/` (also 24.11 and 25.05), the `slurm` user
already exists, and the AWS CLI is present — so the installer step is a no-op
skip exactly as designed. (One benign `sackd` log line: "MessageTimeout is too
high for effective fault-tolerance".) Two bugs in `scripts/deploy-login-node.sh`
surfaced during the run and were fixed: (1) `run-instances` hit an IAM
eventual-consistency error ("Invalid IAM Instance Profile ARN") right after
profile creation — fixed with a retry-with-backoff mirroring `deploy-pcs.sh`'s
CNG create; and (2) the rendered `login-node-setup.sh` is ~24 KB, over EC2's
16 KB user-data limit — fixed by staging the script to S3 and booting from a tiny
fetch-and-run bootstrap UserData (the parent kit's pattern). The `sackd` join
itself was validated by running the setup steps directly on the box via SSM. The
per-student user creation, IMDS hardening, and `sacctmgr` QoS steps were **not**
exercised end-to-end on this cluster (see Phase 3).

**Per-student users:** `login-node-setup.sh` creates the per-student POSIX users
from the roster and publishes `/shared/etc/passwd.roster` on EFS — the same
roster mechanism the parent kit's `head-node-setup.sh` / `compute-node-setup.sh`
use. Student jobs run on the compute node group, so the compute nodes read the
same roster from `/shared`; a compute-side periodic re-sync (a cron like the
parent kit's) remains an optional follow-up.

**Security — this is a multiuser box, so IMDS is hardened.** Students get shells
on the login node, so it enforces **IMDSv2** (token-required) and adds an
**iptables owner-match rule** that blocks every non-root / non-`slurm` user from
reaching the instance-metadata endpoint `169.254.169.254`. That stops a student
from reading the login node's instance-profile credentials. This mitigation is a
deliberate departure from the parent kit's single-tenant head node and should be
re-checked on a live host.

**Design choice — standalone EC2 vs a PCS login CNG.** AWS also supports a
compute node group configured for login nodes (a static CNG whose instances
serve as persistent login hosts, kept inside PCS management). We chose the
**standalone EC2** approach for tighter control over the login host (custom user
sync, IMDS hardening, `sacctmgr`); the PCS-managed-CNG option remains a valid
alternative if you'd rather PCS own the login fleet.

### Phase 2 — NeuronCore GRES attachment — `Gres` unavailable on PCS; `Features` fallback IMPLEMENTED

**Challenge:** on ParallelCluster we set `GresTypes=neuroncore` + a per-node
`Gres=neuroncore:N` (via the Slurm include) and wrote `/etc/slurm/gres.conf`
from the compute bootstrap. On PCS we cannot: `GresTypes` / `Gres` are in
**neither** the CNG-level nor the cluster-level custom Slurm settings
allow-lists (confirmed against the AWS docs):

- **CNG** allow-list = `CpuSpecList`, `Features`, `MemSpecLimit`, `Parameters`
  (Slurm ≥ 25.11), `RealMemory`, `Sockets` (Slurm ≥ 25.11), `Weight` —
  [Slurm custom settings for compute node groups](https://docs.aws.amazon.com/pcs/latest/userguide/slurm-custom-settings-cng.html).
- **Cluster** allow-list = `AccountingStorageEnforce`, `AccountingStorageTRES`,
  and similar accounting/scheduling keys — but **no `Gres*`** —
  [Slurm custom settings for clusters](https://docs.aws.amazon.com/pcs/latest/userguide/slurm-custom-settings-cluster.html).

So the count can't go on the PCS-managed `NodeName` line, and `GresTypes` can't
be registered cluster-wide either. Re-evaluating the four candidate approaches
the design originally listed, against those allow-lists:

1. **Cluster-level `SlurmCustomSettings` for `GresTypes` + `gres.conf` via
   UserData — RULED OUT.** The cluster allow-list (link above) does not include
   `GresTypes` (or any `Gres*`), so the gres type can't be registered with the
   managed controller. Even if `neuron-userdata.sh` wrote a node-local
   `/etc/slurm/gres.conf`, the controller has no `GresTypes` and PCS owns the
   `NodeName` line, so the count would never be advertised.
2. **`Features` (+ `--constraint`) — IMPLEMENTED.** `Features` *is* on the CNG
   allow-list. `deploy-pcs.sh` tags the compute node group with
   `Features=neuron,neuroncoresN` (N=4 for `trn2.3xlarge`, 16 for
   `trn2.48xlarge`) via CNG `SlurmCustomSettings`, and the PCS job template
   (`slurm/job-templates/run.sh`) selects with `--constraint=neuron` instead of
   `--gres`. This gives node-level selection but **no per-core scheduling
   isolation** — the parent kit's "up to 4 jobs share one Trn2 node via per-core
   `gres`" property is **LOST**. Whole-node isolation is available with
   `--exclusive`.
3. **`Parameters` (Slurm ≥ 25.11) — RULED OUT.** `Parameters` is on the CNG
   allow-list, but it is a node option that does not make `neuroncore` a
   schedulable resource; no allow-listed setting carries a gres count, so it is
   not a substitute for `Gres`.
4. **PCS / Neuron gres auto-detection — RULED OUT (confirmed live).** Whether
   the PCS AMI + agent might advertise a `neuroncore` gres automatically for
   Trainium instances (as Slurm's NVML autodetect does for GPUs) was the only
   remaining path to a true per-core `gres`/TRES on PCS. It was checked on a
   **live** PCS Trainium node (`trn2.3xlarge` node `trn2cb-1`, cluster
   `pcs-trn2-cb-test` / `pcs_4awjpg2se6`, sa-east-1): `scontrol show node
   trn2cb-1` reports **`Gres=(null)`** — the PCS-managed node advertises no gres
   at all, and there is no autodetect fallback. So PCS does **not** auto-advertise
   a NeuronCore gres, and per-core NeuronCore scheduling is **impossible** on PCS.
   The same node does report `AvailableFeatures=trn2cb` / `ActiveFeatures=trn2cb`,
   confirming that node **Features are advertised** on PCS — so the `--constraint`
   selection path (approach #2) is the correct, working substitute and node-level
   selection is the ceiling.

**What this means.** PCS runs trn2-on-a-Capacity-Block fine (proven — see the
notes below), but on PCS you **lose per-NeuronCore scheduling granularity**
relative to the ParallelCluster kit — and this is now **empirically confirmed**
on live hardware (`Gres=(null)` on node `trn2cb-1`), not merely inferred from the
allow-lists. Students select whole nodes by feature (`--constraint=neuron`)
rather than requesting individual cores (`--gres=neuroncore:N`); core-level node
sharing is not enforced (use `--exclusive` for whole-node isolation). With
approach #4 now ruled out, node-level selection is the ceiling on PCS: if true
per-core scheduling is required, stay on the ParallelCluster kit (`../../`). And
because `neuroncore` can't be a gres, it can't be a tracked TRES either, which is
what caps the Phase 3 budgets (below).

### Phase 3 — Per-student limits via managed accounting + `sacctmgr` — IMPLEMENTED, reduced (dependency confirmed live; not yet exercised end-to-end)

**Managed accounting (done):** the cluster is created with **managed accounting**
(`Accounting.Mode=STANDARD` in `create-cluster` / `pcs.yaml`), so Slurm
accounting stands up *without* a self-managed MariaDB/RDS — the parent kit had
to run a head-node-local MariaDB for exactly this; PCS gives it to us managed.
`deploy-pcs.sh` also sets cluster `AccountingStorageEnforce=associations,limits,qos`
(via cluster `SlurmCustomSettings` — this key *is* on the cluster allow-list) so
QoS / association limits actually gate submission.

**Enforcement (done, on the login node):** `bootstrap/login-node-setup.sh` runs
`sacctmgr` to create a per-student QoS / association carrying `MaxWall`
(per-job wall-time) and `MaxJobsPerUser` (concurrent-job count), mirroring the
parent kit's `head-node-setup.sh`.

**Live check (dependency confirmed; not yet exercised end-to-end):** on the live
validation cluster — the earlier bare proof cluster, created before accounting
was wired, with `slurmConfiguration.accounting.mode = NONE` and zero queues —
`sacctmgr` returned "You are not running a supported accounting_storage plugin.
Only 'accounting_storage/slurmdbd' is supported." This **confirms the design
dependency**: the per-student QoS chain only works when the cluster is created
with **managed accounting (`accounting mode STANDARD`)**, which `deploy-pcs.sh`
now sets. So Phase 3 is code-correct but is only exercisable on a cluster created
by `deploy-pcs.sh`; it was **not** exercised end-to-end here (this pre-existing
cluster had `accounting.mode=NONE` and no queues).

**Deliberately omitted (not achievable on PCS):** the parent kit's per-core
(`MaxTRESPerUser=gres/neuroncore=...`) and core-hours
(`GrpTRESMins=gres/neuroncore=...`) budgets require `neuroncore` to be a tracked
TRES (`AccountingStorageTRES=gres/neuroncore`), which in turn requires it to be
a Slurm gres. Phase 2 established that `neuroncore` **cannot** be a gres on PCS
(it is in neither allow-list), so these TRES-based limits are **not** enforceable
here — they were left out rather than faked. Only per-job wall-time and
concurrent-job-count limits are enforced.

### Phase 4 — EFS shared storage `/shared` — IMPLEMENTED (not live-validated)

**Why:** students need a shared home + work area, the user roster lives on
shared storage, and the reused harness/job-templates expect `/shared`.

**What was built:**
- `deploy-pcs.sh` creates an **EFS filesystem** and a **single mount target** in
  the cluster subnet, attached to the cluster security group. The
  self-referencing SG already permits NFS (TCP/2049) within itself, so no extra
  ingress rule is needed. The script injects the EFS filesystem id into the
  compute launch-template UserData, and accepts an existing filesystem via the
  optional `--efs-id` flag instead of creating one.
- `bootstrap/neuron-userdata.sh` mounts that EFS at `/shared` on every compute
  node at first boot and creates the `/shared/{home,work,assignments,etc}`
  skeleton — the same `/shared/home/<student>`, `/shared/work/...`,
  `/shared/etc/passwd.roster` layout the parent kit uses, so roster-sync and the
  job templates work unchanged.
- The Phase-1 login node mounts the **same** EFS at `/shared`, so student homes,
  the published `/shared/etc/passwd.roster`, and job I/O line up across the login
  and compute nodes.

`infra/pcs.yaml` mirrors the EFS filesystem + mount target (best-effort; not
deploy-validated). Mounting via a PCS **node lifecycle action** remains a valid
PCS-native alternative to the UserData mount if you'd rather PCS own that step.

### Live validation (2026-08, sa-east-1)

A live run against a real managed PCS cluster (`pcs-trn2-cb-test` /
`pcs_4awjpg2se6`, sa-east-1; compute node `trn2cb-1` = `trn2.3xlarge` on an ML
Capacity Block) exercised the parts of Phases 1–3 that don't require EFS or a
fresh accounting-enabled cluster:

- **Validated live:**
  - **Phase 1 core join** — a standalone EC2 login node in the cluster's public
    subnet and security group joined the managed Slurm controller via `sackd`
    (`systemctl is-active sackd` = `active`), after which `sinfo` and
    `scontrol show node` queried the controller successfully. The PCS sample AMI
    (`dlami-base-ubuntu2404`) already ships Slurm 25.11, so the installer step is
    a no-op skip. Two `scripts/deploy-login-node.sh` bugs were found and fixed
    during the run: an IAM-propagation race on `run-instances` (fixed with
    retry-with-backoff) and a ~24 KB rendered setup script over EC2's 16 KB
    user-data limit (fixed by staging to S3 + a fetch-and-run bootstrap).
  - **Phase 2 gres finding** — `scontrol show node trn2cb-1` → **`Gres=(null)`**,
    empirically proving PCS advertises no NeuronCore gres (approach #4 ruled out).
    `AvailableFeatures` / `ActiveFeatures=trn2cb` were present on the same node,
    confirming the `--constraint` selection path works.
- **Not yet exercised:**
  - **Phase 3 end-to-end** — this cluster had `accounting.mode=NONE`, so
    `sacctmgr` reported no supported `accounting_storage` plugin; the per-student
    QoS chain needs a cluster created by `deploy-pcs.sh` (accounting `STANDARD`).
  - **Phase 4 (EFS `/shared`)** — the validation cluster had no EFS filesystem.
  - Per-student POSIX user creation and IMDS hardening on the login node (the
    Phase 1 follow-on steps beyond the core `sackd` join).

## Notes carried over from the proven run

- The compute node group subnet's **AZ must match the Capacity Block's AZ**;
  `deploy-pcs.sh` validates this before creating anything.
- The instance-profile role **name must start with `AWSPCS`** (or carry the
  `/aws-pcs/` path) or PCS rejects it with "The role ARN is invalid".
- PCS needs `ec2:DescribeCapacityReservations`, `ec2:DescribeCapacityBlocks`,
  and `ec2:DescribeCapacityBlockStatus` to manage a `CAPACITY_BLOCK` node
  group; the deploying identity also needs `ec2:DescribeCapacityReservations`
  for the pre-flight validation.
- Slurm **25.11** is used (24.11 is EOL); `Parameters`/`Sockets` CNG custom
  settings and per-CNG scale-down idle time also require ≥ 25.11.
- **`Gres` / `GresTypes` are in neither PCS custom-settings allow-list** (CNG:
  `CpuSpecList`, `Features`, `MemSpecLimit`, `Parameters`, `RealMemory`,
  `Sockets`, `Weight`; cluster: `AccountingStorageEnforce`,
  `AccountingStorageTRES`, … — no `Gres*`). This is why `neuroncore` can't be a
  gres/TRES on PCS (see Phase 2), so per-core scheduling and core-hours budgets
  from the parent kit do not port; nodes are selected by `Features` /
  `--constraint` instead.
