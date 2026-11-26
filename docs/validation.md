# Validation

How to prove each requirement. Run every command from the repository root.

## Automated (scripts/validate.sh)

`scripts/validate.sh` runs 12 checks against the live environment (needs AWS credentials, `terraform`, `jq`); the [README](../README.md#6-validate-each-requirement) lists which requirement each group covers.

## R1 reproducibility

After `terraform apply` from a clean checkout (see the [README](../README.md#4-run-it)), `terraform -chdir=envs/dev plan -detailed-exitcode` reports `No changes.` and exits `0`.

## R3 persistence proof

```bash
export AWS_REGION=$(terraform -chdir=envs/dev output -raw region)
ID=$(terraform -chdir=envs/dev output -raw dev_instance_id)
$(terraform -chdir=envs/dev output -raw ssm_command)
#   echo "persisted $(date)" > ~/proof.txt
#   pip3 install --user ruff && ~/.local/bin/ruff --version
aws ec2 stop-instances --instance-ids "$ID" && aws ec2 wait instance-stopped --instance-ids "$ID"
aws ec2 start-instances --instance-ids "$ID" && aws ec2 wait instance-status-ok --instance-ids "$ID"
# reconnect: cat ~/proof.txt && ~/.local/bin/ruff --version   -> both still there
```

Then prove the volume outlives the instance:

```bash
terraform -chdir=envs/dev apply -replace=module.dev_env.aws_instance.dev -auto-approve
# reconnect with the new ssm_command: cat ~/proof.txt   -> still there
```

## R4 redeploy and failed-build safety

Redeploy after a source change (new tag, new task definition, rolling update):

```bash
echo '# rebuild marker' >> app/Dockerfile
terraform -chdir=envs/dev apply -auto-approve && terraform -chdir=envs/dev output image_uri   # new tag
git checkout app/Dockerfile
terraform -chdir=envs/dev apply -auto-approve    # back to the committed tag; the build reports SKIPPED (tag exists)
```

A failed build leaves the running service untouched:

```bash
printf 'FROM does-not-exist.invalid/nope:0\n' > app/Dockerfile
terraform -chdir=envs/dev apply -auto-approve; echo "exit=$?"   # fails at aws_lambda_invocation.build
git checkout app/Dockerfile
scripts/validate.sh    # still passes
```

## VS Code Remote-SSH over SSM

Add your public key to `~/.ssh/authorized_keys` on the dev box first (it persists on the home volume), then in `~/.ssh/config`:

```
Host quadsci-dev
  HostName <instance-id>
  User ec2-user
  ProxyCommand aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p
```

The SSH stream rides the outbound SSM channel, so there are still no inbound ports (not exercised in the live run).

## Offline tests

No AWS calls; CI (`.github/workflows/ci.yml`) runs the same checks on every pull request and push to main.

```bash
for m in network dev_env app_service; do (cd modules/$m && terraform init -backend=false && terraform test); done
(cd envs/dev && terraform init -backend=false && terraform test)     # whole stack, mocked providers
python3 -m pytest modules/app_build/lambda                           # trigger Lambda unit tests (needs pytest)
terraform fmt -check -recursive && bash -n scripts/validate.sh
```

Test runs: 3 (network), 3 (dev_env), 4 (app_service), 1 (stack).

## Live results

2026-11-23 and 2026-11-25, us-east-1, Terraform 1.17.2, AWS provider 6.73.0.

| Item | Result |
|---|---|
| Apply from zero | 83 resources in 7 min 30 s; from a fresh clone, 7 min 6 s; on 2026-11-25, 7 min 39 s |
| `scripts/validate.sh` | 12/12 PASS on all three |
| Interactive session | Opened with the session document as `ec2-user`; logged to CloudWatch |
| Second plan | `No changes.` |
| `/home` after stop/start | Files and `pip --user` package kept |
| `/home` after instance replacement | Kept; replacement took 95 s |
| Redeploy | New tag rolled out in 203 s |
| Revert | Build skipped, tag already in ECR |
| Failed build | Apply fails in 73 s; the app keeps serving |
| Destroy | 5–6.5 min; nothing left but the state bucket |

Two defects the live run found, both fixed:

- The first build's ECR login timed out in the minutes-old VPC; the build now waits for the endpoints and retries the login ([decision 21](decisions.md#decisions)).
- AWS re-created the Container Insights log group after destroy, which would break the next apply; Container Insights is off ([decision 22](decisions.md#decisions)).

Not exercised live: VS Code Remote-SSH, the alert e-mail, auto-scaling under load.
