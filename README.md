# Trainium Course Cluster

Open-source infrastructure kit for running NKI kernel assignments on a shared
AWS Trainium Slurm cluster. Instructor provides a student count and a
pre-purchased ML Capacity Block; the kit provisions the cluster, generates
per-student POSIX accounts, and returns a manifest. Students SSH into the head
node and submit jobs with `sbatch`.

Implements the design in [`PRD.md`](./PRD.md) (V0 scope).

## What this is (and isn't)

- Shared Slurm cluster: 1 head node + N static Trainium compute nodes, backed
  by an EC2 Capacity Block. Compute nodes are pinned to the block's AZ.
- Per-student POSIX accounts on the head node with consistent UIDs on all
  compute nodes. Per-student home + work dirs on EFS.
- Manual `sbatch` submission workflow with NeuronCore-level `gres` so multiple
  small kernel jobs share one Trn2 node.
- **Not** an autograder or submission portal — grading is manual for V0.
- **Not** a multi-node distributed training setup — single-node kernel work only.
- **Not** long-lived — the cluster lives inside the capacity block window and
  auto-tears-down at the end. Student work on EFS survives.

## Repo layout

```
trainium-course-cluster/
  README.md                      you are here
  docs/
    architecture.md              concrete AWS resources per PRD component
    inputs.md                    every parameter, its default, and its blast radius
    security.md                  security posture + Trainium multi-tenant caveat
    open-questions-answered.md   research resolving the PRD's open questions
  infra/
    parent-stack.yaml            CFN: VPC, EFS, Secrets, Manifest custom resource
    pcluster-config.yaml         ParallelCluster cluster config (template)
    budget.yaml                  monthly budget + kill-switch (adapted from trainium-class/)
    auto-teardown.yaml           end-of-block teardown automation
  lambda/
    student_manifest/            custom resource: generates POSIX users + SSH keys
  bootstrap/
    head-node-setup.sh           OnNodeConfigured for head: users, dirs, homes
    compute-node-setup.sh        OnNodeConfigured for compute: neuron group, gres.conf, user sync
  slurm/
    slurm.conf.d/                CustomSlurmSettingsIncludeFile source: GresTypes + node gres
    job-templates/               sbatch templates students copy
  harness/
    test_kernel.py               reference-vs-student correctness check
    profile_kernel.py            neuron-profile capture wrapper
  scripts/
    deploy.sh                    parent stack + pcluster create + verify
    teardown.sh                  ordered teardown
    fetch-manifest.sh            pulls the TA-facing manifest from stack outputs
    verify-cluster.sh            post-deploy smoke tests
  student-runbook.md             one-page student guide
```

## Quick start (instructor)

Prereqs: AWS CLI, `pcluster` CLI (3.9+), Python 3.10+, an active MLCB for
`trn2.3xlarge` in `sa-east-1` (São Paulo). Melbourne (`ap-southeast-4`) is
where `trn2.3xlarge` MLCBs are also sold but **ParallelCluster does not
support that region** — use São Paulo for this stack. See
`docs/inputs.md#region` for the full supported list.

```bash
# 1. From the account with an active MLCB, note the reservation id + AZ:
aws ec2 describe-capacity-reservations \
  --filters Name=instance-type,Values=trn2.3xlarge Name=state,Values=active \
  --query 'CapacityReservations[].{Id:CapacityReservationId,AZ:AvailabilityZone,Count:TotalInstanceCount}' \
  --region sa-east-1

# 2. Deploy:
./scripts/deploy.sh \
  --cluster-name fall26-nki \
  --capacity-reservation-id cr-XXXXXXXX \
  --availability-zone sa-east-1a \
  --region sa-east-1 \
  --student-count 20 \
  --ssh-allowed-cidr 10.20.0.0/16 \
  --alert-email you@your.org \
  --admin-ssh-key-name my-admin-key

# 3. Fetch the TA manifest (usernames + private-key ARNs):
./scripts/fetch-manifest.sh --cluster-name fall26-nki --region sa-east-1 --pretty > manifest.json

# 4. Post-deploy sanity check:
./scripts/verify-cluster.sh --cluster-name fall26-nki --region sa-east-1 \
  --admin-key-path ~/.ssh/my-admin-key.pem
```

Give each student their row from the manifest privately. They follow
`student-runbook.md`.

## Cluster lifecycle

- Cluster stays up for the entire capacity block window (static compute; no
  scale-up latency).
- Nightly cron warns of forgotten jobs but does NOT stop the compute fleet
  (the block is prepaid, so nothing is saved by stopping mid-block).
- At MLCB end, `auto-teardown.yaml` deletes the ParallelCluster and parent
  stacks. EFS is retained by default so student work persists.
- Manual teardown: `./scripts/teardown.sh` (idempotent).

## References

- PRD: [`PRD.md`](./PRD.md)
- ParallelCluster + Capacity Blocks: [docs.aws.amazon.com/parallelcluster](https://docs.aws.amazon.com/parallelcluster/latest/ug/launch-instances-capacity-blocks.html)
- Neuron device security model: [awsdocs-neuron.readthedocs-hosted.com](https://awsdocs-neuron.readthedocs-hosted.com/en/latest/about-neuron/security.html)
- Multi-user Slurm on PC template: [awsome-distributed-ai](https://awslabs.github.io/awsome-distributed-ai/posts/slurm-qos-on-parallelcluster/)
