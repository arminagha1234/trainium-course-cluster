# Testing the Manifest Lambda

The `Custom::StudentManifest` handler (`lambda/student_manifest/handler.py`)
provisions per-student SSH keypairs, Secrets Manager secrets, and the S3
roster/manifest during parent-stack creation. It is tested in three tiers.

Tiers 1 and 2 run **offline under `moto`** — fast, no AWS account, no cost.
Tier 3 runs against **real AWS** and exists for one reason: **`moto` emulates
the AWS API surface but does not evaluate IAM policies.** A Lambda role that is
missing an action (or scoped too tightly) still passes every `moto` test,
because `moto` never returns `AccessDenied`. The only way to prove the
`ManifestLambdaRole` in `infra/parent-stack.yaml` grants *exactly* what the
handler calls is to run those calls against real AWS with the real role.

## Test tiers at a glance

| Tier | What it checks | Where it lives | Touches AWS? |
|------|----------------|----------------|--------------|
| 1 | Handler logic + lifecycle (Create / no-op Update / replace Update / Delete / `StudentCount` validation) | `lambda/student_manifest/test_handler.py` | No (`moto`) |
| 2 | Property-based invariants over `StudentCount ∈ [1,500]` (cardinality, slot/UID bijection, key-only-in-Secrets-Manager, idempotence) | `lambda/student_manifest/test_handler.py` | No (`moto` + `hypothesis`) |
| 3 | **IAM authorization** — the role permits every call the handler makes, and no broader | This document | **Yes** |

## Tiers 1 & 2 — offline (`moto`)

These are the fast inner loop. Run them on every change to `handler.py`:

```
cd trainium-course-cluster/lambda/student_manifest
python -m pytest test_handler.py -v
```

- **Tier 1** exercises the full CloudFormation custom-resource lifecycle
  against `moto`'s emulated EC2 / Secrets Manager / S3: it asserts the correct
  number of secrets and their naming pattern, the OpenSSH-PEM secret bodies, the
  roster/manifest schema in S3, that no ephemeral EC2 keypair is left behind,
  that a no-op Update preserves the physical resource id while a changed Update
  replaces it, that Delete sweeps every `trn-course-<cluster>-*` secret plus the
  S3 objects, and that out-of-range `StudentCount` yields a `FAILED` response.
- **Tier 2** is the natural home for the property-based invariants (design
  properties P1–P7): generate random `StudentCount` across `[1,500]` (plus
  out-of-range values) and assert the invariants hold for every input.

**What Tiers 1 & 2 cannot catch:** because `moto` does not enforce IAM, a
handler call that the real `ManifestLambdaRole` is not allowed to make will
still succeed here. That failure mode is Tier 3's job.

## The permission contract Tier 3 verifies

Tier 3 confirms the `KeyPairAndSecretsAndS3` inline policy on
`ManifestLambdaRole` (in `infra/parent-stack.yaml`) matches, one-for-one, the
API calls in `handler.py`. Every row below must be **allowed**; nothing broader
should be. This table is the checklist to work through.

| Handler call (`handler.py`) | IAM action | Resource / scope granted in `parent-stack.yaml` |
|------------------------------|-----------|--------------------------------------------------|
| `ec2.create_key_pair(... TagSpecifications=[...])` | `ec2:CreateKeyPair` | `*` |
| ↳ tag-on-create | `ec2:CreateTags` | `*`, `Condition: ec2:CreateAction = CreateKeyPair` |
| `ec2.describe_key_pairs(... IncludePublicKey=True)` | `ec2:DescribeKeyPairs` | `*` |
| `ec2.delete_key_pair(...)` (stale cleanup + post-capture) | `ec2:DeleteKeyPair` | `*` |
| `secrets.create_secret(... Tags=...)` | `secretsmanager:CreateSecret` + `secretsmanager:TagResource` | `secret:trn-course-<cluster>-*` |
| `secrets.put_secret_value(...)` | `secretsmanager:PutSecretValue` | `secret:trn-course-<cluster>-*` |
| `secrets.tag_resource(...)` | `secretsmanager:TagResource` | `secret:trn-course-<cluster>-*` |
| (contract / DescribeSecret path) | `secretsmanager:DescribeSecret` | `secret:trn-course-<cluster>-*` |
| `secrets.delete_secret(... ForceDeleteWithoutRecovery=True)` | `secretsmanager:DeleteSecret` | `secret:trn-course-<cluster>-*` |
| `secrets.list_secrets(Filters=[name prefix])` | `secretsmanager:ListSecrets` | `*` (AWS does **not** support resource-level scoping on this action; the prefix filter is applied client-side) |
| `s3.put_object(... Tagging=...)` | `s3:PutObject` + `s3:PutObjectTagging` | staging bucket `arn:aws:s3:::<bucket>` and `/*` |
| `s3.get_object(...)` | `s3:GetObject` | staging bucket `/*` |
| `s3.delete_object(...)` | `s3:DeleteObject` | staging bucket `/*` |
| (idempotence / list checks) | `s3:ListBucket` | staging bucket `arn:aws:s3:::<bucket>` |

Two scoping subtleties Tier 3 should confirm hold on real AWS:

- **`ec2:CreateTags` is intentionally narrow.** It is gated by
  `ec2:CreateAction = CreateKeyPair`, so the role can tag a keypair *only* at
  creation time and cannot tag arbitrary EC2 resources afterward.
- **`secretsmanager:ListSecrets` is intentionally unscoped (`*`).** AWS rejects
  resource-level constraints on `ListSecrets`, so the role lists all secrets and
  the handler filters to the cluster prefix. Do not try to "tighten" this to the
  ARN prefix — it will break `ListSecrets` and the Delete sweep with it.

## Tier 3 — real-AWS IAM validation procedure

Run this in a **non-production / scratch AWS account** before shipping any
change to `handler.py` or to the `ManifestLambdaRole` policy in
`parent-stack.yaml`. Do not run it against a live course account.

### Preconditions

1. A scratch AWS account and admin credentials for it (only to deploy and to
   inspect — the actual permission test runs under the least-privilege role, not
   as admin).
2. The AWS CLI on PATH, configured for the scratch account.
3. A target region. `sa-east-1` matches production; any region the account can
   use is fine for a pure IAM check since no MLCB is involved.
4. Pick a throwaway cluster name and export the shared variables the steps
   below reference:

   ```
   export REGION=sa-east-1
   export CLUSTER=iam-tier3
   ```

### Option A (recommended) — end-to-end `--parent-only` deploy

This is the definitive test. `scripts/deploy.sh --parent-only` provisions the
VPC, EFS, staging bucket, the Lambda, and the `Custom::StudentManifest`
resource **without** requiring an MLCB or a `pcluster create-cluster`. That
means the manifest Lambda runs **under its real `ManifestLambdaRole`, invoked by
the CloudFormation/Lambda service** — the exact identity and call graph
production uses. If any required permission is missing, the custom resource
fails and the stack rolls back. (This is the flow `deploy.sh`'s own comment
refers to as "Tier 3 in the testing plan.")

Ordered steps:

1. **Deploy the parent stack only, with a small student count.** A count of 2–3
   exercises every code path (loop, per-student keypair, secret, roster/manifest
   write) at negligible cost:

   ```
   scripts/deploy.sh \
     --cluster-name "$CLUSTER" \
     --region "$REGION" \
     --student-count 3 \
     --availability-zone "${REGION}a" \
     --ssh-allowed-cidr <your.office.cidr>/32 \
     --alert-email you@example.org \
     --parent-only
   ```

2. **Confirm the stack reached `CREATE_COMPLETE`.** If the manifest Lambda hit
   an `AccessDenied`, the `StudentManifest` custom resource sends a `FAILED`
   response and the stack will be `ROLLBACK_*` instead:

   ```
   aws cloudformation describe-stacks --region "$REGION" \
     --stack-name "${CLUSTER}-parent" \
     --query "Stacks[0].StackStatus" --output text
   ```

3. **If it rolled back, read the resource events to find the failing action.**
   The custom-resource event carries the handler's failure reason:

   ```
   aws cloudformation describe-stack-events --region "$REGION" \
     --stack-name "${CLUSTER}-parent" \
     --query "StackEvents[?ResourceType=='Custom::StudentManifest'].[Timestamp,ResourceStatus,ResourceStatusReason]" \
     --output table
   ```

4. **Read the Lambda logs for the precise `AccessDenied`.** The log group is
   `/aws/lambda/<cluster>-manifest`. The message names the IAM action and the
   ARN that was denied:

   ```
   aws logs tail "/aws/lambda/${CLUSTER}-manifest" --region "$REGION" --since 30m
   ```

5. **On success, spot-check the side effects** the role had to be authorized to
   produce — the secrets under the cluster prefix and the two S3 objects:

   ```
   aws secretsmanager list-secrets --region "$REGION" \
     --filters Key=name,Values="trn-course-${CLUSTER}-" \
     --query "SecretList[].Name" --output text

   STAGING=$(aws cloudformation describe-stacks --region "$REGION" \
     --stack-name "${CLUSTER}-parent" \
     --query "Stacks[0].Outputs[?OutputKey=='StagingBucketName'].OutputValue" \
     --output text)
   aws s3 ls "s3://${STAGING}/roster/"
   ```

6. **Exercise the Delete path**, which needs `ListSecrets`, `DeleteSecret`, and
   `s3:DeleteObject`. Deleting the stack invokes the custom resource's Delete:

   ```
   aws cloudformation delete-stack --region "$REGION" --stack-name "${CLUSTER}-parent"
   aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "${CLUSTER}-parent"
   ```

7. **Confirm the sweep succeeded** — no cluster-prefixed secrets should remain
   (an `AccessDenied` on `DeleteSecret`/`ListSecrets` would leave some behind):

   ```
   aws secretsmanager list-secrets --region "$REGION" \
     --filters Key=name,Values="trn-course-${CLUSTER}-" \
     --query "SecretList[].Name" --output text
   ```

A clean `CREATE_COMPLETE`, populated secrets/objects, and a clean delete-sweep
together prove the role authorizes the full handler call graph. If EFS retention
is on (the default), delete the retained filesystem manually after the test.

### Option B (targeted) — probe the policy directly

Use this to pinpoint a single missing/over-broad permission without a full
deploy, and to run the **negative (scoping) checks** Option A does not cover.

**Trust-policy caveat.** `ManifestLambdaRole`'s trust policy only allows
`lambda.amazonaws.com` to assume it, so you **cannot** `sts:assume-role` it as a
human principal. Two ways around this, scratch account only:

- **B1 — clone the policy onto a test principal (cleanest).** Copy the
  `KeyPairAndSecretsAndS3` statements verbatim from `parent-stack.yaml` into an
  inline policy on a throwaway role/user that trusts *you*, assume that, and run
  the probes below. This tests the policy document — the thing you author —
  without touching the deployed role's trust.
- **B2 — temporarily extend the deployed role's trust** to include your
  principal, assume it, run the probes, then **revert the trust policy.** Only
  do this in the scratch account.

Once you hold credentials for the role (or its clone), run each service group.
Every positive probe must succeed; each negative probe must return
`AccessDeniedException`.

**EC2 keypair (positive):**

```
KP="trn-course-${CLUSTER}-student01-ephemeral"
aws ec2 create-key-pair --region "$REGION" --key-name "$KP" \
  --key-type ed25519 --key-format pem \
  --tag-specifications 'ResourceType=key-pair,Tags=[{Key=Purpose,Value=trn-course-student-keygen-ephemeral}]' \
  --query KeyName --output text
aws ec2 describe-key-pairs --region "$REGION" --key-names "$KP" --include-public-key \
  --query "KeyPairs[0].KeyName" --output text
aws ec2 delete-key-pair --region "$REGION" --key-name "$KP"
```

**Secrets Manager (positive):**

```
SECRET="trn-course-${CLUSTER}-student01-key"
aws secretsmanager create-secret --region "$REGION" --name "$SECRET" \
  --secret-string "not-a-real-key" --tags Key=Cluster,Value="$CLUSTER"
aws secretsmanager put-secret-value --region "$REGION" --secret-id "$SECRET" --secret-string "not-a-real-key-2"
aws secretsmanager describe-secret --region "$REGION" --secret-id "$SECRET" --query ARN --output text
aws secretsmanager list-secrets --region "$REGION" \
  --filters Key=name,Values="trn-course-${CLUSTER}-" --query "SecretList[].Name" --output text
aws secretsmanager delete-secret --region "$REGION" --secret-id "$SECRET" --force-delete-without-recovery
```

**Secrets Manager (negative — proves the prefix scope).** Creating a secret
*outside* the `trn-course-<cluster>-` prefix must be denied:

```
aws secretsmanager create-secret --region "$REGION" \
  --name "not-a-course-secret" --secret-string x   # expect AccessDeniedException
```

**S3 (positive)** against the staging bucket from the deployed stack (`$STAGING`
from Option A step 5, or any bucket the policy scopes to):

```
printf '[]' > /tmp/tier3-probe.json
aws s3api put-object --region "$REGION" --bucket "$STAGING" \
  --key "roster/tier3-probe.json" --body /tmp/tier3-probe.json \
  --tagging "Purpose=trn-course-roster"
aws s3api get-object --region "$REGION" --bucket "$STAGING" \
  --key "roster/tier3-probe.json" /tmp/tier3-probe.out >/dev/null
aws s3api list-objects-v2 --region "$REGION" --bucket "$STAGING" \
  --prefix "roster/" --query "Contents[].Key" --output text
aws s3api delete-object --region "$REGION" --bucket "$STAGING" --key "roster/tier3-probe.json"
```

**S3 (negative — proves the bucket scope).** The same call against a *different*
bucket must be denied.

### Interpreting failures

- An `AccessDeniedException` (Option B) or a stack rollback with a denied action
  in the Lambda logs (Option A) means a statement is **missing or too tight** in
  `ManifestLambdaRole`. Map the denied action back to the table above and add or
  widen the matching statement in `parent-stack.yaml`.
- A **negative** probe that *succeeds* means the policy is **too broad**. Tighten
  the offending statement (the secret prefix, the bucket ARN, or the
  `ec2:CreateAction` condition) and re-run.

### Cleanup

Option A's step 6 deletes the stack and triggers the secret/object sweep. Also:

- Delete any keypairs, secrets, or objects created by Option B's probes (the
  commands above already delete what they create on the happy path; clean up
  leftovers from a partial run).
- If `RetainEfsOnDelete` was `true` (the default), delete the retained EFS
  filesystem left by the parent stack after the test.

# Verifying Neuron on the compute nodes

Separate from the Manifest Lambda tiers above, this checklist confirms that
`bootstrap/compute-node-setup.sh` successfully installed the public Neuron SDK +
`torch-neuronx` on a live compute node. Run it after the cluster reaches
`CREATE_COMPLETE`. SSH to the head node first (`ssh -i <admin-key>.pem
ubuntu@<head-dns>`); the compute node is in the private subnet, so reach it
through the head node (or run the checks via `sbatch`, step (c)).

(a) **The driver + tools see the NeuronCores.** On a compute node,
`neuron-ls` should list the expected NeuronCores for the shape (trn2.3xlarge = 4,
trn2.48xlarge = 16):

```
/opt/aws/neuron/bin/neuron-ls        # or just `neuron-ls` once PATH is set
```

(b) **The shared venv imports `torch-neuronx`.** The venv lives at the fixed
path the job templates source:

```
source /opt/aws_neuronx_venv_pytorch/bin/activate
python -c "import torch, torch_neuronx; print(torch_neuronx.__version__)"
```

This should print a `2.9.*` version with no ImportError. If the file is missing,
the bootstrap's SDK/venv install did not complete — check
`/var/log/trn-course-compute-setup.log` on the node.

(c) **End-to-end through Slurm.** From the head node, submit a trivial job that
runs on the compute node and dumps the NeuronCore inventory, then read the
captured stdout:

```
sbatch --partition=nki --gres=neuroncore:1 --wrap 'neuron-ls'
# once it completes:
cat /shared/work/$USER/*/*/stdout.log   # or the path printed by the template
```

A job that lands on the compute node and prints the NeuronCore table confirms
the driver, tools, gres wiring, and scheduler are all consistent end to end.
