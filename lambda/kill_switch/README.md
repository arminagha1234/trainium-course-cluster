# kill_switch Lambda

Cost containment kill-switch for the Trainium Course Cluster (design divergence
D13; Requirement 20). Subscribed to the budget stack's dedicated kill-switch SNS
topic in `infra/budget.yaml`, which the `AWS::Budgets::Budget` publishes to when
tracked class spend crosses **90%** of the monthly cap.

## What it does

Stops running EC2 instances tagged `Class=<ClassTag>` **except** any instance
also tagged `AutoStop=false`.

The ParallelCluster fleet (head node + compute nodes) is tagged
`AutoStop: 'false'` at the cluster level in `infra/pcluster-config.yaml`, so
ParallelCluster propagates that tag to every fleet instance. Sparing those
instances means the kill-switch:

- **never stops the prepaid MLCB compute fleet** (Requirement 20.4) -- stopping
  it saves nothing because the reservation is prepaid; and
- **never interrupts an active student session** (Requirement 20.5) -- the head
  node and the compute nodes running student Slurm jobs are all part of that
  `AutoStop=false` fleet.

Any *other* class-tagged instance (a genuinely runaway, non-cluster resource)
has no `AutoStop=false` tag and is still stopped, so the switch remains an
effective containment backstop that stops only class-tagged resources
(Requirement 20.3).

Defense in depth: the Lambda's IAM role in `infra/budget.yaml` scopes
`ec2:StopInstances` with an `ec2:ResourceTag/Class == <ClassTag>` condition, so
even a logic bug here can only ever stop class-tagged instances.

## Environment variables (set by the CFN template)

| Variable            | Purpose                                          |
|---------------------|--------------------------------------------------|
| `CLASS_TAG`         | `Class=` tag value identifying course resources  |
| `AWS_TARGET_REGION` | Region for the EC2 client (echoes `AWS::Region`) |

## Packaging

Packaged and uploaded exactly like `lambda/auto_teardown` / `lambda/student_manifest`
-- zip the directory contents (excluding `README.md`, `*.pyc`, `__pycache__/`) to
the per-cluster bootstrap bucket, then pass the location to the budget stack via
the `LambdaCodeBucket` / `LambdaCodeKey` parameters. `scripts/deploy.sh` does
this before deploying `infra/budget.yaml`.

The handler entry point is `handler.lambda_handler`.
