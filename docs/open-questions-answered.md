# PRD Open Questions — Resolved

The PRD flagged five verification items. This doc records the answers we
found and the design choices we made off them. Kept as a change log so we
can re-answer if the underlying tools shift.

## Q1: ParallelCluster support for MLCB, and the exact pinning config

**Answer: Native support in PC 3.7+.**

Doc: [Launch instances with Capacity Blocks (CB)](https://docs.aws.amazon.com/parallelcluster/latest/ug/launch-instances-capacity-blocks.html).

The required cluster config shape:

```yaml
Scheduling:
  Scheduler: slurm
  SlurmQueues:
    - Name: nki
      CapacityType: CAPACITY_BLOCK
      ComputeResources:
        - Name: nki-trn2
          InstanceType: trn2.3xlarge          # optional; auto-inferred from CR
          MinCount: 4                          # ==  MaxCount, static only
          MaxCount: 4
          CapacityReservationTarget:
            CapacityReservationId: cr-0abc123def456
```

Constraints observed from the docs:
- `MinCount == MaxCount > 0`. Static nodes only. Dynamic allocation is not
  supported with `CAPACITY_BLOCK`.
- InstanceType is optional at the ComputeResource level when
  `CapacityReservationId` is set; PC pulls it from the reservation. We set
  it anyway for readability of the config.
- Cluster creation succeeds before the CB is active. Nodes sit in a Slurm
  reservation (associated with the `slurm` admin user) until the CB start
  time; then they release and accept jobs.
- At CB end, PC returns the nodes to the maintenance reservation. Any
  running jobs are lost — we handle this via `MaxWallTime < remaining CB
  time` guardrails in the deploy script.

**Design choice:** we go native. No custom MLCB targeting logic.

## Q2: NeuronCore-level `gres` — natively exposed, or wire it ourselves?

**Answer: Wire it ourselves. Not natively exposed by PC.**

Sources:
- Neuron ParallelCluster [sample cluster config](https://github.com/aws-neuron/aws-neuron-parallelcluster-samples/blob/master/examples/cluster-configs/trn1-16-nodes-pcluster.md) — does not declare any Neuron gres.
- PC blog on [customizing Slurm settings](https://aws.amazon.com/blogs/hpc/customize-slurm-settings-with-aws-parallelcluster-3-6/): "There are other configuration files associated with Slurm such as gres.conf and cgroup.conf. It's not currently possible to modify them using the AWS ParallelCluster custom Slurm settings mechanism. You can however, use custom bootstrap actions to do so."

So we need two pieces:

1. **`gres.conf` on each compute node** — written by `bootstrap/compute-node-setup.sh`:
   ```
   Name=neuroncore File=/dev/neuron0
   Name=neuroncore File=/dev/neuron1
   Name=neuroncore File=/dev/neuron2
   Name=neuroncore File=/dev/neuron3
   ```
   Bootstrap enumerates `/dev/neuron*` and generates entries, so this is
   robust across trn2.3xlarge → trn2.48xlarge (16 devices) if we ever pivot.

2. **Slurm-side gres declaration** — via `CustomSlurmSettingsIncludeFile`
   pointing to `s3://<staging>/slurm/neuroncore-gres.conf`:
   ```
   GresTypes=neuroncore
   NodeName=nki-st-trn2-3xl-[1-N] Gres=neuroncore:4
   ```
   `deploy.sh` renders `N` from `--compute-node-count` at deploy time.

Students then request cores with:
```
sbatch --gres=neuroncore:1  # 1 core, 4 concurrent per node
sbatch --gres=neuroncore:4  # entire node
```

**Fallback plan** — kept documented but not enabled:
- `OverSubscribe=FORCE:4` on the queue.
- Job wrapper reads `SLURM_JOB_ID` and derives an offset, then sets
  `NEURON_RT_VISIBLE_CORES=<offset>-<offset>` before running the user script.
- Trades scheduling isolation for a simpler config. Only pull the ripcord if
  the gres path hits a PC version bug.

## Q3: `neuron-profile` for non-root users in a core-scoped allocation

**Answer: Works via `neuron` group + udev rule. No special
privileges needed beyond group membership.**

Doc: [Neuron Security Disclosures](https://awsdocs-neuron.readthedocs-hosted.com/en/latest/about-neuron/security.html).

The Neuron team's recommended pattern:
```bash
sudo groupadd -r neuron
sudo usermod -aG neuron <student>
cat >/etc/udev/rules.d/99-neuron.rules <<'EOF'
SUBSYSTEM=="neuron*", KERNEL=="neuron*", GROUP="neuron", MODE="0660"
EOF
sudo udevadm control --reload
sudo udevadm trigger --subsystem-match=neuron
```

After this, `ls -l /dev/neuron*` shows `crw-rw---- 1 root neuron ...`.
Group members can run `neuron-ls`, `neuron-profile`, and Neuron-facing
Python without sudo.

Verified paths:
- `neuron-ls` — lists devices, works as group member.
- `neuron-profile capture` — writes NEFF + NTFF, works as group member.
- Reading `/sys/devices/virtual/neuron_device/*` — some subpaths are
  root-only. `neuron-profile` does not need those for capture.

**IMPORTANT SECURITY CAVEAT** captured from the same doc:
> applications with access to Trainium devices have unrestricted access to
> instance physical memory.

This is documented at length in `docs/security.md`. Short version: co-tenant
students on the same compute node can peer at each other's HBM. Acceptable
for a course; would not be acceptable for a customer-facing multi-tenant
service.

**Design choice:** enable `neuron` group + udev rule in
`bootstrap/compute-node-setup.sh`. Publish the caveat to students in the
runbook so they know NKI is not a secure sandbox.

## Q4: Manifest key delivery — Secrets Manager vs inline bundle

**Answer: Secrets Manager, per-student secret.**

Rationale:
- Stack outputs are stored in CFN metadata unencrypted. Even a "no-echo"
  parameter is retrievable by anyone with CFN read on the stack. That's a
  wider blast radius than "anyone with Secrets Manager read on `trn-course-*`".
- The TA-facing manifest carries the *ARN*, not the material. The TA
  distributes the ARN + a one-liner (`aws secretsmanager get-secret-value
  --secret-id <arn> ...`) to each student, and the student retrieves their
  own key. This gives us audit trail on Secrets Manager, per-secret access
  policies, and rotation.
- Alternative "inline encrypted bundle": nice for offline distribution, but
  the encryption key becomes the new secret you have to distribute. Not a
  net win.

Cost note: 50 secrets × $0.40/mo = $20/mo. Negligible against MLCB spend.

## Q5: Account naming — real names or anonymous slots

**Answer: Anonymous slots (`student01..N`). TA maps to real names out-of-band.**

Rationale:
- Real names on IAM/POSIX identities put PII into the AWS surface. Course
  rosters change; usernames are structural.
- Anonymous slots simplify the manifest schema (see architecture doc) — the
  Lambda just needs `StudentCount`, not a roster CSV.
- The TA maintains a `slot → real name/email` mapping in the course LMS or
  a private spreadsheet. Grading tools read that mapping, not the cluster.

For instructors who insist on named accounts (e.g. for LDAP-integrated
learning systems), a Phase-2 flag `--use-roster <file.csv>` will accept a
`slot,alias,email` CSV. Not V0.

## Also worth answering, not in the PRD

### What SDK version do we pin?

Public released Neuron SDK 2.28 (default DLAMI as of 2026-08). Pinned via
SSM parameter `resolve:ssm:/aws/service/neuron/dlami/pytorch-2.5/latest/ami-id`
which resolves to the current stable Neuron DLAMI at deploy time. Override
with `--neuron-ami-id ami-xxxxx` if the course targets a specific SDK.

Beta 2 / Beta 3 (Native PyTorch) are explicitly out of scope for V0 per the
PRD.

### What triggers auto-teardown?

An EventBridge rule that fires at the MLCB's `EndDateTime`. The rule invokes
a teardown Lambda that runs `pcluster delete-cluster` and then deletes the
parent stack (EFS retained by default).

Fallback: a manual `scripts/teardown.sh` runs the same sequence idempotently.

### What if `pcluster` version drift breaks the deploy mid-course?

Pin the `pcluster` CLI version in `scripts/deploy.sh` (currently `3.9.x`).
Update in-place mid-course only if there is a security fix.
