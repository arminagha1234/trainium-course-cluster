# Trainium Course Cluster (AWS PCS)

An infrastructure kit that stands up a shared Trainium Slurm cluster for NKI
kernel assignments on **AWS Parallel Computing Service (PCS)**, backed by a
pre-purchased ML Capacity Block (CB). PCS provides a managed Slurm controller,
so this kit hands PCS a launch template + IAM + networking and PCS owns the
scheduler lifecycle. It implements the design in [`PRD.md`](./PRD.md).

The `harness/` (correctness + profiling) and `lambda/`
(`student_manifest`, `kill_switch`, `auto_teardown`) directories are shared
components consumed by this kit; see
[Shared components](#shared-components-harness-and-lambda).

> **Status: proven core + Phases 1–4 implemented; the login-node join (Phase 1)
> and the NeuronCore-gres finding (Phase 2) are now validated on live hardware.**
> `scripts/deploy-pcs.sh` reproduces the proven core (security group → AWSPCS
> IAM role → PCS AMI → launch template → PCS cluster → compute node group →
> queue) and now also provisions **EFS `/shared`** and the Phase-2 node
> `Features` + cluster `AccountingStorageEnforce`. A standalone **login node**
> (`scripts/deploy-login-node.sh` + `bootstrap/login-node-setup.sh`) adds
> student SSH, **per-student POSIX users**, and **wall-time + concurrent-job
> QoS** via `sacctmgr` — rounding out Phases 1–4. A live run (sa-east-1, cluster
> `pcs-trn2-cb-test`, node `trn2cb-1` = `trn2.3xlarge` on an ML Capacity Block)
> confirmed the **login node joins the managed Slurm controller via `sackd`**
> (after which `sinfo`/`scontrol` query the controller) and that the
> **PCS-managed node reports `Gres=(null)`** — empirically proving there is no
> per-core NeuronCore scheduling on PCS. **Phase 3** (per-student QoS; needs a
> cluster created with managed accounting) and **Phase 4** (EFS `/shared`) are
> implemented but **not yet exercised on a live cluster.** One limitation is
> structural, not merely unproven, and is now **confirmed live**: **`neuroncore`
> cannot be a Slurm GRES on PCS** (it is in neither custom-settings allow-list,
> and the live node advertises no gres), so there is **no per-core scheduling and
> no per-core / core-hours budget** — students select whole nodes with
> `--constraint=neuron`, and limits are wall-time + job-count only. See
> [`docs/design.md`](./docs/design.md) "PHASE STATUS" (Phase 2) for details.

## The proven result

The load-bearing question for this variant was whether PCS would launch a
Trainium instance from an **ML Capacity Block** at all — the PCS documentation
lists Capacity Blocks as being for P-family GPU instances (P6/P5/P4d), with no
mention of Trn. It was validated empirically via the AWS CLI:

- **Instance `i-04fdfe05274edb571`** came up as a **`trn2.3xlarge`**
- with **`InstanceLifecycle=capacity-block`**
- drawing from the Trainium ML Capacity Block **`cr-0e168cd22e5919f69`**
- under **AWS PCS management** (PCS-tagged, launched by the PCS compute node
  group via the custom launch template).

So the trn2-on-a-Capacity-Block-via-PCS path works in practice. `deploy-pcs.sh`
codifies the exact sequence and field values that produced that result.

## ⚠️ Caveat: works, but officially unsupported

AWS PCS documentation for Capacity Blocks describes the feature in terms of
**P6 / P5 / P4d** GPU instances and does not list Trainium (`trn`) types. The
result above shows trn2 **does** work, but you are outside the documented
support matrix:

- AWS could change PCS's Capacity Block handling in a way that breaks trn2
  without it being a "regression" against documented behavior.
- Support may decline to engage on trn2-on-PCS-CB issues.
- **No per-NeuronCore scheduling on PCS.** `neuroncore` can't be a Slurm GRES
  on PCS — it is in neither the CNG nor the cluster custom-settings allow-list —
  so there is **no per-core scheduling** and **no per-core / core-hours
  budget**. This is now **confirmed on a live PCS trn2 node**: `scontrol show
  node trn2cb-1` reports **`Gres=(null)`** (the managed node advertises no gres,
  with no autodetect fallback), so it is not merely inferred from the docs.
  Nodes are selected whole with `--constraint=neuron` (use `--exclusive` for
  isolation), and per-student limits are wall-time + concurrent-job-count only.
  A course that needs multiple students sharing one node at NeuronCore
  granularity is not achievable on PCS today. See
  [`docs/design.md`](./docs/design.md) "PHASE STATUS" (Phase 2).
- Treat this as **"works but officially unsupported."** Validate again on your
  own account/region before relying on it for a live class.

## How to deploy

Prereqs: AWS CLI v2 (with the `pcs` commands), `jq`, `base64`, an active trn2
ML Capacity Block, and a private subnet in the CB's AZ. The deploying identity
needs the usual `ec2`/`iam`/`ssm`/`pcs` create permissions plus
`ec2:DescribeCapacityReservations` (PCS itself additionally needs
`ec2:DescribeCapacityBlocks` and `ec2:DescribeCapacityBlockStatus` — see
`docs/design.md`).

```bash
# 1. Find the Capacity Block id + AZ:
aws ec2 describe-capacity-reservations \
  --filters Name=instance-type,Values=trn2.3xlarge Name=state,Values=active \
  --query 'CapacityReservations[].{Id:CapacityReservationId,AZ:AvailabilityZone,Count:TotalInstanceCount}' \
  --region us-east-2

# 2. Deploy (validation first; the script waits for each PCS resource to reach ACTIVE):
./scripts/deploy-pcs.sh \
  --cluster-name fall26-nki-pcs \
  --region us-east-2 \
  --capacity-reservation-id cr-0e168cd22e5919f69 \
  --availability-zone us-east-2b \
  --subnet-id subnet-xxxxxxxx \
  --vpc-id vpc-xxxxxxxx \
  --compute-instance-type trn2.3xlarge \
  --compute-node-count 1 \
  --student-count 20 \
  --alert-email you@your.org

# Tip: add --dry-run to run all validation (region + Capacity Block + subnet AZ)
# and stop before creating any resources.
```

What the script creates, in order:

1. **Security group** — self-referencing (all traffic within itself) + all
   egress. This is the SG shape PCS requires for the cluster ENI.
2. **IAM role + instance profile** — the role **name starts with `AWSPCS`**
   (PCS rejects a non-`AWSPCS` role with "The role ARN is invalid"). Trusts
   `ec2.amazonaws.com`; carries `AWSPCSComputeNodePolicy`,
   `AmazonSSMManagedInstanceCore`, `AmazonS3ReadOnlyAccess`, and
   `CloudWatchAgentServerPolicy`.
3. **PCS AMI** — resolved from SSM
   (`/aws/service/pcs/ami/dlami-base-ubuntu2404/x86_64/latest/ami-id`).
4. **Launch template** — `InstanceMarketOptions.MarketType=capacity-block`,
   `CapacityReservationSpecification` → the CB, the SG, and base64 UserData =
   [`bootstrap/neuron-userdata.sh`](./bootstrap/neuron-userdata.sh) (the Neuron
   SDK + `torch-neuronx` install).
5. **PCS cluster** — Slurm **25.11** (24.11 is EOL), size `SMALL`, managed
   accounting (`accounting mode STANDARD`).
6. **PCS compute node group** — `purchaseOption=CAPACITY_BLOCK`, the custom
   launch template, the `AWSPCS` instance profile, static scaling, subnet in
   the CB AZ.
7. **PCS queue `nki`** — the Slurm partition students submit to
   (queue == partition).

`deploy-pcs.sh` now also creates an **EFS filesystem + mount target** on the
cluster SG and injects its id into the compute UserData (pass an existing one
with `--efs-id` to skip creation), and applies the Phase-2 settings (node
`Features=neuron,neuroncoresN` on the CNG and `AccountingStorageEnforce` on the
cluster). `infra/pcs.yaml` is a best-effort CloudFormation mirror of these
resources (now including EFS). It is **not** deploy-validated — the proven path
is the CLI script. See its header for the schema caveats.

### Then: the login node (student SSH + per-student accounting)

PCS has no head node, so students need a **login node** to `ssh` into and
`sbatch` from. Once the cluster is `ACTIVE`, run `scripts/deploy-login-node.sh`
(Phase 1 + Phase 3):

```bash
./scripts/deploy-login-node.sh \
  --cluster-name fall26-nki-pcs \
  --region us-east-2 \
  --vpc-id vpc-xxxxxxxx \
  --subnet-id subnet-xxxxxxxx \
  --ssh-allowed-cidr 203.0.113.0/24 \
  --key-name my-ssh-key \
  --efs-id fs-xxxxxxxx \
  --staging-bucket my-bootstrap-bucket
```

This launches a standalone EC2 instance in the cluster VPC/subnet, attaches it
to the cluster SG, joins it to the managed cluster as a submit host via `sackd`,
mounts the same EFS at `/shared`, creates the per-student POSIX users, and runs
`sacctmgr` for the per-student wall-time + concurrent-job QoS. `--ssh-allowed-cidr`
restricts TCP/22 to the course network (never an open range), and the box
hardens IMDS (IMDSv2 + an iptables owner-match rule) because students get shells
on it. Students then SSH to the login node and submit with
**`sbatch --constraint=neuron`** — not `--gres=neuroncore:N`, which does not
schedule on PCS (see the caveat above and `docs/design.md` "PHASE STATUS"
Phase 2). The **`sackd` join was validated live** (sa-east-1; the login node
reached the managed controller and `sinfo`/`scontrol` worked); the per-student
users + `sacctmgr` QoS steps are **implemented but not yet exercised end-to-end**
(that needs a cluster created with managed accounting — see `docs/design.md`
Phase 3). The deploy script was **hardened after live testing**: it stages
`login-node-setup.sh` to S3 and boots from a tiny fetch-and-run UserData (the
rendered setup script is ~24 KB, over EC2's 16 KB user-data limit), and its
`run-instances` retries on the IAM instance-profile propagation race.

## Repo layout

```
trainium-course-cluster/
  README.md                    you are here
  PRD.md                       product requirements (V0)
  scripts/
    deploy-pcs.sh              proven core + EFS + Phase-2 Features/accounting (aws ec2 + iam + ssm + pcs + efs)
    deploy-login-node.sh       Phase 1+3: standalone sackd login node (student SSH, POSIX users, sacctmgr)
  bootstrap/
    neuron-userdata.sh         compute UserData: public Neuron SDK + torch-neuronx; mounts EFS /shared
    login-node-setup.sh        login-node config: sackd join, per-student users, IMDS hardening, sacctmgr
  slurm/
    job-templates/
      run.sh                   PCS job template (#SBATCH --constraint=neuron, not --gres)
  autograder/                  Gradescope autograder: ssh+sbatch to the shared cluster, reuse the kit harness
    run_autograder             entrypoint (ssh login node -> sbatch grade_job.sbatch -> pull result.json)
    grade_job.sbatch           the Slurm job (runs harness/test_kernel.py on a trn2 node)
    run_tests.py               gradescope-utils runner -> results.json
    tests/                     correctness (70) + performance (30) + leaderboard, from result.json
    setup.sh / requirements.txt image build + deps
  infra/
    pcs.yaml                   CloudFormation mirror incl. EFS (best-effort; not deploy-validated)
  docs/
    design.md                  design + PHASE STATUS (login node, GRES, accounting, EFS)
  harness/                     shared: correctness (test_kernel.py) + profiling (profile_kernel.py) + result schema + example assignment
  lambda/                      shared: student_manifest (POSIX users + keys + TA manifest), kill_switch (budget), auto_teardown (end-of-block)
```

## Autograding (Gradescope)

`autograder/` adds an optional Gradescope autograder for this variant. Rather
than booting a Trainium instance per submission, it SSHes to the **PCS login
node** and `sbatch --constraint=neuron`s each grading run onto the
already-running shared trn2 fleet, reusing the kit harness and its `result.json`
schema. The only secret baked into the Gradescope image is a **scoped SSH key**
to a low-privilege `autograder` login-node user that may `sbatch` — **no AWS
credentials**. See [`autograder/README.md`](./autograder/README.md) for operator
setup, the 70/30 correctness/performance breakdown, and the honest
not-yet-run-on-Gradescope status.

## Shared components (`harness/` and `lambda/`)

The cluster control plane is PCS-specific, but two directories are
control-plane-agnostic and are consumed as-is:

- **Lambdas** — `lambda/student_manifest` (per-student POSIX users + SSH
  keypairs + TA manifest), `lambda/kill_switch` (budget kill-switch), and
  `lambda/auto_teardown` (end-of-block teardown).
- **Harness** — `harness/` (`test_kernel.py`, `profile_kernel.py`,
  `result_writer.py`, and the example assignment) for correctness + profiling.

The Slurm job template ships in `slurm/job-templates/run.sh` and selects nodes
with `--constraint=neuron` (not `--gres=neuroncore:N`, which does not schedule
on PCS — see the caveat above and `docs/design.md` "PHASE STATUS" Phase 2). It
sources the shared `/opt/aws_neuronx_venv_pytorch` venv that
`neuron-userdata.sh` builds.

Phases 1–4 wire the login node (student SSH + per-student POSIX users +
`sacctmgr` QoS), EFS `/shared`, and wall-time / job-count accounting into the
PCS deploy — all **implemented but not yet live-validated**. Still open (not yet
wired): the `student_manifest` Lambda as the roster source, and the
`kill_switch` / `auto_teardown` budget + end-of-block teardown stacks. See
[`docs/design.md`](./docs/design.md) "PHASE STATUS" for status per phase.

## References

- AWS PCS Capacity Blocks: [docs.aws.amazon.com/pcs — Using Amazon EC2 Capacity Blocks for ML with AWS PCS](https://docs.aws.amazon.com/pcs/latest/userguide/capacity-blocks.html)
- AWS PCS managed accounting: [docs.aws.amazon.com/pcs — Slurm accounting](https://docs.aws.amazon.com/pcs/latest/userguide/slurm-accounting.html)
- AWS PCS IAM instance profiles: [docs.aws.amazon.com/pcs — IAM instance profiles](https://docs.aws.amazon.com/pcs/latest/userguide/security-instance-profiles.html)
- Product requirements: [`PRD.md`](./PRD.md)

<!-- Content on AWS PCS behavior was summarized from AWS documentation and rephrased for compliance with licensing restrictions. -->
