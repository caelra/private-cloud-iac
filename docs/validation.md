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

First real run, 2026-11-23, AWS us-east-1 in the review account, Terraform 1.17.2, AWS provider 6.73.0.

| What was run | Result | Time |
|---|---|---|
| `terraform -chdir=bootstrap apply` | 5 resources created | |
| `terraform -chdir=envs/dev apply` from zero | 83 resources created, succeeded on the first attempt (see the build note below) | 7 min 30 s |
| `scripts/validate.sh` | 12/12 PASS: no instance public IP; no ENI public IP except the NAT; isolated route table has no default route; dev SG has no inbound rules; dev box Online in SSM; egress via the NAT public IP; `/home` separate volume; tooling bootstrapped; ALB internal; app 200 from inside; not reachable from outside; tasks have no public IP | |
| Second `terraform -chdir=envs/dev plan -detailed-exitcode` | `No changes.`, exit 0, including the regional NAT gateway | |
| Regional NAT gateway | Created with `availability_mode = "regional"`; a public IP in each of the two AZs. AWS attaches its own route table to the gateway (no subnet associations) with `0.0.0.0/0` → internet gateway; no subnet route table points at the internet gateway | |
| Dev box | cloud-init finished; Terraform 1.17.2 (pinned zip), Docker 25, git, node 18, aws-cli, tmux, jq present; root (30 GB) and home (20 GB) volumes tagged | |
| [R3 persistence](#r3-persistence-proof): stop/start | `~/proof.txt` and the `pip --user` package (`ruff`) still there | |
| R3 persistence: `-replace` of the instance | Both still there; the home volume detached and reattached cleanly | 95 s |
| [Redeploy](#r4-redeploy-and-failed-build-safety): comment appended to `app/Dockerfile` | New image tag built and rolled out | 203 s |
| Redeploy: revert | No new build (trigger returned `SKIPPED`, tag already in ECR); rollout back to the committed tag | 190 s |
| Failed build: non-existent base image | Apply fails at `aws_lambda_invocation.build` with `CodeBuild build … ended with status FAILED`; the service kept returning 200 on the previous task definition | 73 s |
| Tags, scaling, monitoring | ECS tasks carry the project tags; scaling target min 2 / max 4; Container Insights log group is the Terraform-managed one (14-day retention); all 8 alarms created and OK, except `build-failed`, which went to ALARM after the failed build as intended | |

Build note: on this first apply the first CodeBuild build failed in PRE_BUILD because `docker login` to ECR timed out in the minutes-old VPC. The trigger's restart-once started a second build, which succeeded, so the apply passed. The build now also waits for the VPC endpoints and retries the login (see [decision 21](decisions.md#decisions)).

Clean-room rebuild after the build fix: PENDING

Not verified live: an interactive session with the custom session document appearing in the session log, VS Code Remote-SSH, the alert e-mail subscription, and behaviour under load (see [Still unverified](decisions.md#still-unverified)).
