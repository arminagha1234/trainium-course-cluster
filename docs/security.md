# Security Posture

## Threat model

Users we trust partially:
- **Students** are enrolled course participants. They can execute arbitrary
  code on compute nodes as their own POSIX user. They should not be able to
  execute code as other students, escalate to root, or reach out of the class
  account.
- **TAs / instructor** have `pcluster` CLI credentials and can SSH to the head
  node as the `ubuntu` sudoer. They can create/delete the cluster and read any
  student's manifest entry.

Users we don't trust:
- Anyone outside `--ssh-allowed-cidr`.
- Any student trying to elevate.

Assets we protect:
- Student SSH private keys (Secrets Manager, KMS-encrypted at rest).
- Student work under `/shared/work/<user>` (POSIX perms 700, per-user).
- The head node itself (single ingress, no `0.0.0.0/0`).
- The AWS account (SCP + IAM boundaries; not part of this stack — pre-existing).

Assets we accept as weakly isolated (see "Trainium multi-tenant caveat" below):
- HBM contents of a running kernel: on a node co-tenanted by multiple
  students, a motivated peer can inspect physical memory.

## Trainium multi-tenant caveat

From the [Neuron security disclosures](https://awsdocs-neuron.readthedocs-hosted.com/en/latest/about-neuron/security.html):

> Trainium hardware is designed to optimize performance for machine learning
> workloads. To deliver high performance, applications with access to Trainium
> devices have unrestricted access to instance physical memory.

**What this means for a shared course cluster:** on a compute node running
jobs from multiple students, those students can (in principle) read each
other's HBM memory and, via the same channel, other regions of instance
physical memory. Slurm cgroup isolation does not extend to the Neuron device.

**Why we accept it for V0:**
- Course context. Students are already expected to submit their own work.
  Peer memory inspection is not the highest-value attack; social/academic
  integrity mechanisms cover this.
- The alternative — exclusive full-node allocation — cuts effective capacity
  by 4× on trn2.3xlarge and blocks the design's core cost efficiency.
- No student is running secrets on Trainium. Weights and kernel code sit on
  EFS and are subject to standard POSIX perms, not device memory.

**When to reconsider:**
- Assignments involve proprietary datasets or credentials that end up on the
  device. Don't do that in a course setting; if unavoidable, switch to
  exclusive allocation (`Scheduling.SlurmQueues[].JobExclusiveAllocation:
  true`) as a hard-mode override.
- Grading policy requires students' work be provably invisible to peers.
  Switch to exclusive allocation with a smaller cohort or larger MLCB.

We publish this caveat in `student-runbook.md` so students understand what is
and isn't isolated.

## Layered controls

### Network

- Head node public IP + SSH port open only to `--ssh-allowed-cidr`. The
  deploy script hard-fails on `0.0.0.0/0`.
- Compute nodes in a private subnet with no public IP. Egress through NAT for
  package pulls; no ingress.
- EFS mount targets in each subnet, security group allows NFS from the head
  and compute SGs only.
- No inbound to compute from students. Students only touch compute via
  `sbatch` on the head node.

### Identity

- Students authenticate to the head node with an ed25519 SSH key generated
  by the manifest Lambda. Keys are ed25519 (256-bit); passphrases are not set
  (delivered via Secrets Manager, which is our confidentiality control).
- Consistent UIDs across head + compute (10001..10000+N). Same student, same
  UID everywhere → POSIX perms behave.
- No sudo. Students cannot install system packages, modify /etc, or elevate.
- No `AllowUsers root` / password auth. `sshd_config` sets
  `PermitRootLogin no`, `PasswordAuthentication no`.

### File permissions

- `/shared/home/<student>` — mode 700, owned by that student.
- `/shared/work/<student>` — mode 700, same.
- `/shared/assignments` — mode 755, owned by root, world-readable, not
  writable. TAs populate over SSH+sudo or by staging into S3 and having the
  head-node bootstrap copy in.
- `/shared/etc/passwd.roster` — mode 644, owned by root. Compute nodes read
  this to sync users.
- Home directories on EFS, not local. Compute nodes see the same student
  homes the head node does — jobs can write to `~/` and the student sees the
  result on next login.

### Neuron device

- `neuron` system group owns `/dev/neuron*` via udev rule, mode 0660.
- Students are added to `neuron` at user creation.
- No student is root, so no student can rewrite the udev rule or modprobe
  a different driver.
- Weakness above (physical memory) is unmitigable without cgroups isolating
  the Neuron device, which the driver does not currently support.

### Secrets

- Student private keys in Secrets Manager, encrypted with an AWS-managed KMS
  key by default. Custom KMS key via `--kms-key-arn`.
- Manifest Lambda has `secretsmanager:CreateSecret` / `PutSecretValue` /
  `DeleteSecret` on secrets named `trn-course-<cluster-name>-*` only.
- TA reads secrets via IAM identity, not by knowing the value. Rotation is
  by re-running the manifest Lambda (destroys and recreates keys — students
  must be re-onboarded).

### Kill-switch and blast radius

- Budget kill-switch stops instances tagged `Class=<nki-tag>` when spend hits
  90% of budget. Scoped IAM policy: `ec2:StopInstances` with tag condition.
- Slurm `MaxTime` on the partition prevents one student from filling the
  queue indefinitely.
- `MaxJobsPerUser` prevents one student from queueing thousands of jobs.

## What this does NOT cover

- The AWS account itself. Assume SCP + IAM guardrails are in place at the
  org level.
- Data classification / handling policy. Course datasets should be non-
  sensitive.
- Auditing at the student-code level. `sacct` records who ran what, but
  student code content is not audited.
- MFA on student SSH sessions. SSH keys only. If your course policy requires
  MFA, switch to SSM Session Manager or bolt on `google-authenticator-pam`.

## Incident response quick actions

- Suspect student behavior: `sudo passwd -l student<N>` on the head node
  disables their login without breaking their pending Slurm jobs. To also
  kill jobs: `scancel -u student<N>`.
- Suspect a compromised key: rotate the specific student's secret and
  re-populate `authorized_keys` (script: `scripts/rotate-student-key.sh`,
  not V0 — do it by hand: create new key, `PutSecretValue`, rewrite the
  student's `~/.ssh/authorized_keys` over SSH+sudo from the head).
- Suspect the head node: `pcluster stop-compute-fleet` freezes compute,
  then rotate the head-node SSH access via SG update. The MLCB keeps its
  slots reserved during a stop.
