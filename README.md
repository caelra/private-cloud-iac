# Private platform on AWS (Terraform)

Terraform that builds a private network on AWS, a persistent cloud dev environment reached without any public IP, and a container app that is built from source, stored in a private registry and served only inside the VPC. One `terraform apply` creates everything, including the image build.

Architecture diagram, with traffic direction and how each private resource is reached: [docs/architecture.md](docs/architecture.md).

## 1. Provider and design

**Provider:** AWS. **Architecture:** own design (not one of the suggested options), summarised by the table below.

- Two subnet tiers in two AZs. The **egress** tier routes `0.0.0.0/0` to a NAT gateway. The **isolated** tier has only the local route.
- No resource has a public IP. The only public address is the NAT gateway.
- Developers reach the dev box with SSM Session Manager. The app is an internal ALB in front of ECS Fargate tasks in the isolated tier.

| # | Choice | Why | Alternative rejected | Tradeoff |
|---|---|---|---|---|
| 1 | AWS | Strongest platform for the author; the exercise allows any | Other clouds | Uses AWS-specific services and the IAM model; moving to GCP or Azure means re-implementing the modules |
| 2 | `egress` and `isolated` tiers, each in 2 AZs | An ALB needs two AZs, and two AZs is the realistic shape | Single AZ | Roughly double the subnets and endpoint ENIs |
| 3 | Regional NAT gateway, no public subnet | One NAT spans AZs, so the VPC needs no public subnet at all | Zonal NAT in a public subnet (classic); NAT instance | Newer feature; a NAT gateway still needs an internet gateway to exist (see section 8) |
| 4 | SSM Session Manager for human access | IAM auth, no inbound ports, session logging, port forwarding, Remote-SSH via ProxyCommand | Bastion host (public IP); Client VPN (cost, certificates); EC2 Instance Connect Endpoint (SSH only, weaker audit) | Needs AWS CLI and the Session Manager plugin on the developer machine |
| 5 | Dev box reaches SSM through the NAT | Saves about $22/month of `ssm`, `ssmmessages`, `ec2messages` endpoints | Interface endpoints for those three services | SSM traffic leaves via the NAT public IP. Endpoints are the production hardening step |
| 6 | EC2 AL2023 arm64 `t4g.small`, IMDSv2 required, separate encrypted gp3 volume at `/home`, tooling by cloud-init (Terraform from the pinned HashiCorp release zip, `dev_env` variable `terraform_version`, not a yum repo) | Simple persistent-disk story: `/home` outlives the instance | Cloud9 (closed to new customers); WorkSpaces (heavy, slow); devcontainer on Fargate (no simple persistent disk) | `/home` survives stop/start and instance replacement but not `terraform destroy` |
| 7 | ECS Fargate | Container runtime with no nodes to manage | EKS (control plane for one container); App Runner (awkward private ingress); Lambda (not a container runtime in spirit) | Fargate costs more per vCPU than EC2 capacity |
| 8 | App in the isolated tier | Proves the tier is usable with no internet route | App in the egress tier | Needs VPC endpoints (`ecr.api`, `ecr.dkr`, `logs`, S3 gateway) for pull and logs |
| 9 | Internal ALB, HTTP :80, security group allows the VPC CIDR only; tasks accept :8080 only from the ALB security group | Health-checked stable endpoint with ALB metrics | Service Connect / Cloud Map (no ALB metrics or health-checked endpoint) | HTTP inside the VPC. HTTPS with a private CA is the production step |
| 10 | CodeBuild in the egress subnets (privileged), source is a zip of `app/` uploaded to S3 by Terraform | Build runs in AWS, so the applying machine needs no Docker and there is no arm64/amd64 mismatch | Local Docker provider | Extra moving parts: S3 object, CodeBuild project, Lambda |
| 11 | `aws_lambda_invocation` starts the build and waits for it | Apply stays pure Terraform, no AWS CLI `local-exec` | `local-exec` with the AWS CLI | The Lambda is a small piece of code to maintain; it runs outside the VPC |
| 12 | Image tag is the first 12 chars of the `app/` source hash; ECR tags are immutable | Traceable, and a changed source always makes a new task definition | `latest` | Unchanged source never invokes the build again; `SKIPPED` appears only when the source reverts to a tag already in ECR |
| 13 | Private ECR, scan on push, lifecycle keeps last 10 images, `force_delete` | The isolated tier cannot pull a public image at runtime, and the app is freshly built | Pulling the public image directly | `force_delete` removes images on destroy |
| 14 | Separate `bootstrap/` stack creates a versioned, encrypted, public-access-blocked state bucket; the main stack uses the S3 backend with `use_lockfile` | Shared remote state with S3-native locking, no DynamoDB | DynamoDB lock table (older pattern); local state only | One extra one-time step, and the bootstrap stack itself uses local state |
| 15 | Provider `default_tags` (`Project`, `Environment`, `ManagedBy`) plus an `aws_resourcegroups_group` on those tags | One console view of everything | None | Tag-based grouping only covers taggable resources |
| 16 | `monitoring` module: 8 alarms to an SNS topic, VPC flow logs, Container Insights, SSM session logs, one dashboard | Covers symptoms first (app health) and then causes (NAT, build, dev box) | Prometheus/Grafana or Datadog | Fine for one environment; see section 7 for scale |
| 17 | Readiness inputs (`egress_ready`, `endpoints_ready`) instead of module-level `depends_on` | Module-level `depends_on` defers every data source in the module to apply time, which makes names and ARNs unknown and forces replacements on unrelated network changes | `depends_on` on the module blocks | Each module needs one extra input |
| 18 | CodeBuild queue ≤ 5 min + build ≤ 9 min < 15-minute trigger Lambda; the trigger retries IAM-propagation `AccessDenied` errors with backoff and restarts a build once if it fails before the BUILD phase | A build always ends before the Lambda does, so a retry cannot start a second build that collides on the immutable tag; a clean first apply survives IAM propagation and transient provisioning failures | Default 60-minute build timeout, no retries | A slow legitimate build over 9 minutes, or a queue over 5, fails |

## 2. Repository layout

```
bootstrap/            one-time stack: remote state bucket (local state)
envs/dev/             root stack: wires the modules, backend, outputs
  backend.hcl.example   copy to backend.hcl and fill in the bucket
  terraform.tfvars.example
  tests/stack.tftest.hcl  whole-stack plan test with mocked providers
modules/
  network/            VPC, two subnet tiers, regional NAT, IGW, flow logs
  endpoints/          ecr.api, ecr.dkr, logs interface endpoints + S3 gateway
  dev_env/            dev EC2, home EBS volume, IAM, SSM session document
  app_build/          ECR, source bucket, CodeBuild, trigger Lambda, buildspec
  app_service/        internal ALB, ECS cluster and Fargate service
  monitoring/         SNS, alarms, dashboard
app/Dockerfile        the sample app image (hello-app, :8080)
scripts/validate.sh   live checks for each requirement
```

## 3. Prerequisites

- Terraform >= 1.10
- AWS credentials with permission to create the resources above. The region comes from the `region` variable (default `us-east-1`); set `AWS_REGION` to match only for manual `aws` CLI commands, since `validate.sh` sets it itself.
- For validation and dev-box access only: AWS CLI v2, the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html), `jq`

No local Docker is needed. The image is built by CodeBuild.

## 4. Run it

```bash
# One time: create the remote state bucket
cd bootstrap
terraform init
terraform apply
terraform output -raw state_bucket      # note the bucket name

# Configure the main stack's backend
cd ../envs/dev
cp backend.hcl.example backend.hcl      # put the bucket name from above in it
cp terraform.tfvars.example terraform.tfvars   # optional; every variable has a default

# Every time
terraform init -backend-config=backend.hcl
terraform apply
```

The bootstrap stack is itself Terraform. It keeps **local state** on purpose: it creates the bucket that remote state needs, so it cannot use that bucket. Its state file is small and recoverable; losing it means importing one bucket.

Apply time will be measured at first apply and added here. The slow steps are the NAT gateway, the CodeBuild image build and the ECS service reaching steady state.

Variables in `envs/dev`: `region`, `project`, `environment`, `vpc_cidr`, `dev_instance_type`, `alert_email` (optional; subscribes an address to the alerts topic, and AWS sends a confirmation e-mail).

Outputs: `region`, `vpc_id`, `isolated_route_table_id`, `dev_instance_id`, `ssm_command`, `alb_dns_name`, `app_url`, `image_uri`, `dashboard_name`, `resource_group`.

## 5. Connect to the dev box

```bash
$(terraform -chdir=envs/dev output -raw ssm_command)
```

Run from the repository root. This runs `aws ssm start-session --target <instance-id> --document-name <name>-dev-session`. The session document opens a shell as `ec2-user` in `/home/ec2-user` and logs the session to CloudWatch.

Optional VS Code Remote-SSH over SSM. Add your public key to `~/.ssh/authorized_keys` on the dev box first (it persists on the home volume), then in `~/.ssh/config`:

```
Host quadsci-dev
  HostName <instance-id>
  User ec2-user
  ProxyCommand aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p
```

Still no inbound ports: the SSH stream rides the outbound SSM channel.

## 6. Validate each requirement

Automated, against the live environment (needs AWS credentials, `terraform`, `jq`; prints PASS/FAIL per check and exits non-zero on any failure):

```bash
scripts/validate.sh
```

It covers requirements 2 to 4 below. Requirement 1 is the apply itself. Manual commands for the rest follow.

**R1. Everything is created by `terraform apply`.** `terraform apply` from a clean checkout, then `terraform -chdir=envs/dev plan -detailed-exitcode`; expect `No changes.` and exit code `0`.

**R2. Private network, no public IPs, egress only where intended.** `validate.sh` checks that no instance or network interface has a public IP except the NAT gateway, that the isolated route table has no `0.0.0.0/0` route, that the dev security group has no inbound rules, that the dev box is `Online` in SSM, and that the dev box's public egress IP equals the NAT gateway's.

**R3. Dev environment with persistence.** `validate.sh` checks that `/home` is a separate volume and that the tooling (git, docker, terraform, aws, node, tmux, jq) is installed. Persistence by hand:

```bash
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

**R4. Private container app, built from source.** `validate.sh` checks that the ALB is `internal`, that `app_url` returns 200 from the dev box, that it is *not* reachable from your machine, and that running task ENIs have no public IP. By hand: get the URL on your machine with `terraform -chdir=envs/dev output -raw app_url`, then run `curl -i <url>` inside an SSM session on the dev box.

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

### Testing (offline, no AWS calls)

```bash
for m in network dev_env app_service; do (cd modules/$m && terraform init -backend=false && terraform test); done
(cd envs/dev && terraform init -backend=false && terraform test)     # whole stack, mocked providers
python3 -m pytest modules/app_build/lambda                           # trigger Lambda unit tests (needs pytest)
terraform fmt -check -recursive && bash -n scripts/validate.sh
```

The module tests assert that subnets never assign public IPs, tier CIDRs do not collide, the instance is private with IMDSv2 and a separate encrypted home volume, the dev security group has no ingress, the ALB is internal, and tasks get no public IP. Live results from `scripts/validate.sh` will be recorded after the first apply.

## 7. Monitoring and alerting

Built by `modules/monitoring` and friends:

- **Alarms (8)** to the `<name>-alerts` SNS topic, symptoms first: unhealthy ALB targets, target 5xx, running tasks below desired, ECS CPU and memory above 80%, dev box status check, NAT port-allocation errors, failed CodeBuild builds. Set `alert_email` to receive them.
- **Dashboard** named by the `dashboard_name` output: requests and errors, p95 latency, CPU and memory, NAT traffic, alarm state.
- **Logs:** app, build, trigger Lambda and VPC flow logs (all traffic) in CloudWatch with 14-day retention by default, SSM session logs with 30 days, and Container Insights on the ECS cluster. Only sessions started with the custom session document (what `ssm_command` uses) are logged to the session log group.

At larger scale this would not be per-environment CloudWatch alarms written by hand. Metrics and alarms would be generated from shared module defaults per service and fed to one central account (CloudWatch cross-account observability, or Prometheus/Grafana or Datadog). Alerts would route by severity and ownership through an on-call tool rather than one SNS topic, and alarms would be tied to SLOs (error rate and latency burn) instead of fixed thresholds. Flow logs and session logs would go to a central log account with longer retention.

## 8. Assumptions and exceptions

- **Internet gateway exists only for the NAT.** Any NAT gateway requires one. No route table points at it, so nothing is reachable from the internet.
- **No NAT-only public subnet** because the regional NAT gateway needs none. If the regional mode were unavailable, the zonal fallback would need a small public subnet.
- **HTTP inside the VPC** between clients and the internal ALB, and between the ALB and tasks. No TLS certificate is provisioned.
- **SSM traffic leaves through the NAT** (no `ssm`/`ssmmessages`/`ec2messages` endpoints), to save cost.
- **Session logging** applies only to sessions that use the custom session document. A plain `start-session` uses account defaults.
- **Trigger Lambda runs outside the VPC** in AWS-managed networking and only calls the CodeBuild and ECR APIs.
- **Bootstrap stack uses local state**, as explained in section 4.
- **`/home` survives stop/start and instance replacement but not `terraform destroy`.** There is no snapshot or backup.
- **`force_delete` on ECR and `force_destroy` on the build-source bucket** so destroy always succeeds. Not for production.
- **Image is built and run as linux/amd64** for Fargate. It is not meant to run on the arm64 dev box (`t4g.small`), which has no emulation set up.
- **Items to confirm at first apply:** regional NAT metrics under `AWS/NATGateway` with the `NatGatewayId` dimension, the NAT interface-type filter in `validate.sh`, the Fargate ENI description match (`*ecs*`) in `validate.sh`, that regional NAT auto mode may take minutes to expand into an AZ when the first workloads appear, and that a second plan shows no diff on the regional NAT (`availability_zone_address` read-back). Nothing has been applied yet; these are the places a real run is most likely to need a small fix.
- Default region `us-east-1`; a single environment (`dev`).

## 9. Cost and cleanup

Rough cost while running is on the order of $5 to $8 per day, mostly the NAT gateway, three interface endpoints across two AZs, the ALB and two small Fargate tasks. This is an estimate from list prices, not a measurement. The dev box can be stopped between uses; the home volume keeps its data.

```bash
terraform -chdir=envs/dev destroy
# then the state bucket: S3 console -> bucket -> Empty (it is versioned), then
terraform -chdir=bootstrap destroy
```

Everything is in the resource group named by the `resource_group` output (`quadsci-exercise-dev`) and tagged `Project=quadsci-exercise`, so leftovers are easy to find in the console.
