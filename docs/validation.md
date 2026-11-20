# Validation

How to prove each requirement. Run every command from the repository root.

## Automated (scripts/validate.sh)

```bash
scripts/validate.sh
```

Runs against the live environment (needs AWS credentials, `terraform`, `jq`), prints PASS/FAIL per check and exits non-zero on any failure. Requirement 1 is the apply itself (see [R1](#r1-reproducibility)).

- **R2. Private network, no public IPs, egress only where intended.** No instance or network interface has a public IP except the NAT gateway; the isolated route table has no `0.0.0.0/0` route; the dev security group has no inbound rules; the dev box is `Online` in SSM; the dev box's public egress IP equals the NAT gateway's.
- **R3. Dev environment.** `/home` is a separate volume (label `devhome`); the tooling (git, docker, terraform, aws, node, tmux, jq) is installed.
- **R4. Private container app.** The ALB is `internal`; `app_url` returns 200 from the dev box (egress tier to isolated tier); it is *not* reachable from your machine; running task ENIs have no public IP.

## R1 reproducibility

`terraform apply` from a clean checkout (see the [README](../README.md#4-run-it)), then:

```bash
terraform -chdir=envs/dev plan -detailed-exitcode
```

Expect `No changes.` and exit code `0`.

## R3 persistence proof

```bash
export AWS_REGION=$(terraform -chdir=envs/dev output -raw region)
ID=$(terraform -chdir=envs/dev output -raw dev_instance_id)
$(terraform -chdir=envs/dev output -raw ssm_command)
#   echo "persisted $(date)" > ~/proof.txt
#   pip3 install --user httpie && ~/.local/bin/http --version
aws ec2 stop-instances --instance-ids "$ID" && aws ec2 wait instance-stopped --instance-ids "$ID"
aws ec2 start-instances --instance-ids "$ID" && aws ec2 wait instance-status-ok --instance-ids "$ID"
# reconnect: cat ~/proof.txt && ~/.local/bin/http --version   -> both still there
```

Then prove the volume outlives the instance:

```bash
terraform -chdir=envs/dev apply -replace=module.dev_env.aws_instance.dev -auto-approve
# reconnect with the new ssm_command: cat ~/proof.txt   -> still there
```

## R4 redeploy and failed-build safety

By hand: get the URL on your machine with `terraform -chdir=envs/dev output -raw app_url`, then run `curl -i <url>` inside an SSM session on the dev box.

Redeploy after a source change (new tag, new task definition, rolling update):

```bash
echo '# rebuild marker' >> app/Dockerfile
terraform -chdir=envs/dev apply -auto-approve && terraform -chdir=envs/dev output image_uri   # new tag
git checkout app/Dockerfile
terraform -chdir=envs/dev apply -auto-approve    # back to the committed tag; the build reports SKIPPED (tag exists)
```

Failed build leaves the running service untouched:

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

Still no inbound ports: the SSH stream rides the outbound SSM channel.

## Offline tests

No AWS calls. CI (`.github/workflows/ci.yml`) runs the same checks on every pull request and on pushes to main.

```bash
for m in network dev_env app_service; do (cd modules/$m && terraform init -backend=false && terraform test); done
(cd envs/dev && terraform init -backend=false && terraform test)     # whole stack, mocked providers
python3 -m pytest modules/app_build/lambda                           # trigger Lambda unit tests (needs pytest)
terraform fmt -check -recursive && bash -n scripts/validate.sh
```

The module tests assert that subnets never assign public IPs, tier CIDRs do not collide, the instance is private with IMDSv2 and a separate encrypted home volume, the dev security group has no ingress, the ALB is internal, tasks get no public IP, and the service auto-scales between 2 and 4 tasks on CPU. Test runs: 3 (network), 3 (dev_env), 4 (app_service) and 1 (stack).

## Live results

Recorded after the first apply.
