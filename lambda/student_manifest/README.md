# Student Manifest Lambda

CloudFormation custom resource invoked from `infra/parent-stack.yaml` as
`Custom::StudentManifest`. Generates SSH keypairs, stores private material
in Secrets Manager, publishes the roster to S3 (for head + compute bootstrap
consumption), and returns the TA-facing manifest as the `ManifestJson`
resource data attribute.

## Packaging

`scripts/deploy.sh` zips this directory and uploads to
`s3://<staging-bucket>/lambda/student_manifest.zip`. The parent stack
references the zip via `ManifestLambdaCodeBucket` + `ManifestLambdaCodeKey`
parameters.

Dependencies: none beyond the Python 3.12 Lambda runtime and its shipped
boto3. We deliberately do not depend on `cryptography` — key generation goes
through the EC2 API instead. See `handler.py` `_generate_keypair` for the
rationale.

## Test locally

```
cd trainium-course-cluster/lambda/student_manifest
python -m pytest test_handler.py -v
```

The moto-based unit tests cover Create / Update no-op / Update replace /
Delete / validation edge cases. They exercise the full boto3 call graph
without touching real AWS (the offline test tier).

**Known gap**: moto emulates the AWS API surface but does NOT enforce IAM
authorization. Missing IAM permissions on the Lambda role are only visible
when you run against real AWS. Keep a real-AWS IAM validation run in the test
cycle before shipping to catch these. The Lambda's current required permissions (as of
last real-AWS validation on 2026-08-14):

- `ec2:CreateKeyPair`, `ec2:DescribeKeyPairs`, `ec2:DeleteKeyPair`
- `ec2:CreateTags` (scoped to `ec2:CreateAction=CreateKeyPair`)
- `secretsmanager:CreateSecret`, `PutSecretValue`, `DescribeSecret`,
  `DeleteSecret`, `TagResource` (scoped to `trn-course-<cluster>-*`)
- `secretsmanager:ListSecrets` (must be unscoped; AWS doesn't support
  resource-level scoping on this action)
- `s3:PutObject`, `s3:PutObjectTagging`, `s3:GetObject`, `s3:DeleteObject`,
  `s3:ListBucket` (scoped to the staging bucket)

## Behaviour summary

| Event | Action |
|-------|--------|
| Create | Provision N keys + secrets + roster + manifest. Emit `ManifestJson` data attr. |
| Update, no diff | No-op; re-emit last-known manifest from S3. |
| Update, StudentCount or Revision changed | Provision fresh; new PhysicalResourceId; CFN issues DELETE on old id. |
| Delete | Force-delete all cluster secrets and S3 roster+manifest objects. |

## Secret naming

`trn-course-<cluster-name>-<username>-key`

`Delete` sweeps by this prefix. This means running two clusters with the
same name in the same account will collide — but two clusters with the same
name is already blocked by ParallelCluster.

## Physical resource id

`trn-course-manifest-<cluster>-n<N>-<revision>`

Deterministic, so genuine no-op Updates are recognized (same id returned) and
StudentCount/Revision changes force replacement (new id → CFN Delete+Create).
