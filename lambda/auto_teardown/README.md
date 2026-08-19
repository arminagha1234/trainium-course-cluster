# auto_teardown Lambda

Automated end-of-block teardown for the Trainium Course Cluster (design
divergence D1; Requirement 22). Triggered by a one-time EventBridge Scheduler
schedule defined in `infra/auto-teardown.yaml` that fires at the MLCB
`EndDateTime`.

## What it does

1. Publishes a **start** notification to the parent stack's alerts SNS topic.
2. Deletes the **ParallelCluster** CloudFormation stack and the **budget** stack
   via the CloudFormation API (idempotent: an already-absent stack is treated as
   deleted).
3. Waits, within the Lambda time budget, for those deletes to reach a terminal
   state and publishes a **success**, **failure**, or (if a long delete is still
   running when time runs out) **in progress** notification.

It never touches the **parent stack** or the **EFS filesystem**, so student work
survives whether the teardown succeeds or fails (Requirement 22.2).

## Environment variables (set by the CFN template)

| Variable              | Purpose                                             |
|-----------------------|-----------------------------------------------------|
| `CLUSTER_NAME`        | Cluster id, used in notification text                |
| `CLASS_TAG`           | `Class=` tag value, used in notification text        |
| `PCLUSTER_STACK_NAME` | ParallelCluster stack to delete                      |
| `BUDGET_STACK_NAME`   | Budget stack to delete                               |
| `PARENT_STACK_NAME`   | Parent stack - never deleted; used as a guard        |
| `ALERTS_TOPIC_ARN`    | SNS topic for start/success/failure notifications    |
| `AWS_TARGET_REGION`   | Region for CloudFormation + SNS                      |

## Packaging

Packaged and uploaded exactly like `lambda/student_manifest` - zip the directory
contents (excluding `README.md`, `*.pyc`, `__pycache__/`) to the per-cluster
bootstrap bucket, then pass the location to the stack via `LambdaCodeBucket` /
`LambdaCodeKey`. Wiring this into `scripts/deploy.sh` (packaging + reading the
MLCB `EndDateTime` and deploying `infra/auto-teardown.yaml`) is task 2.2.

The handler entry point is `handler.lambda_handler`.
