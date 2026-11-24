# Design decisions

Every significant choice, the alternatives considered, and what it costs. The
[README](../README.md) has the short version; the
[architecture diagram](architecture.md) shows how the pieces connect.

## Decisions

| # | Choice | Why | Alternative rejected | Tradeoff |
|---|---|---|---|---|
| 1 | AWS | Strongest platform for the author; the exercise allows any | Other clouds | Uses AWS-specific services and the IAM model; moving to GCP or Azure means re-implementing the modules |
| 2 | `egress` and `isolated` tiers, each in 2 AZs | An ALB needs two AZs, and two AZs is the realistic shape | Single AZ | Roughly double the subnets and endpoint ENIs |
| 3 | Regional NAT gateway, no public subnet | One NAT spans AZs, so the VPC needs no public subnet at all | Zonal NAT in a public subnet (classic); NAT instance | Newer feature; a NAT gateway still needs an internet gateway to exist (see [exceptions](#exceptions-and-production-fixes)) |
| 4 | SSM Session Manager for human access | IAM auth, no inbound ports, session logging, port forwarding, Remote-SSH via ProxyCommand | Bastion host (public IP); Client VPN (cost, certificates); EC2 Instance Connect Endpoint (SSH only, weaker audit) | Needs AWS CLI and the Session Manager plugin on the developer machine |
| 5 | Dev box reaches SSM through the NAT | Saves about $22/month per AZ (about $44 for this two-AZ stack) of `ssm`, `ssmmessages`, `ec2messages` endpoints | Interface endpoints for those three services | SSM traffic leaves via the NAT public IP. Endpoints are the production hardening step |
| 6 | EC2 AL2023 arm64 `t4g.small`, IMDSv2 required, separate encrypted gp3 volume at `/home`, tooling by cloud-init (Terraform from the pinned HashiCorp release zip, `dev_env` variable `terraform_version`, not a yum repo) | Simple persistent-disk story: `/home` outlives the instance | Cloud9 (closed to new customers); WorkSpaces (heavy, slow); devcontainer on Fargate (no simple persistent disk) | `/home` survives stop/start and instance replacement but not `terraform destroy` |
| 7 | ECS Fargate | Container runtime with no nodes to manage | EKS (control plane for one container); App Runner (awkward private ingress); Lambda (not a container runtime in spirit) | Fargate costs more per vCPU than EC2 capacity |
| 8 | App in the isolated tier | Proves the tier is usable with no internet route | App in the egress tier | Needs VPC endpoints (`ecr.api`, `ecr.dkr`, `logs`, S3 gateway) for pull and logs |
| 9 | Internal ALB, HTTP :80, security group allows the VPC CIDR only; tasks accept :8080 only from the ALB security group | Health-checked stable endpoint with ALB metrics | Service Connect / Cloud Map (no ALB metrics or health-checked endpoint) | HTTP inside the VPC. HTTPS with a private CA is the production step |
| 10 | CodeBuild in the egress subnets (privileged), source is a zip of `app/` uploaded to S3 by Terraform | Build runs in AWS, so the applying machine needs no Docker and there is no arm64/amd64 mismatch | Local Docker provider | Extra moving parts: S3 object, CodeBuild project, Lambda |
| 11 | `aws_lambda_invocation` starts the build and waits for it | Apply stays pure Terraform, no AWS CLI `local-exec` | `local-exec` with the AWS CLI | The Lambda is a small piece of code to maintain; it runs outside the VPC |
| 12 | Image tag is the first 12 chars of the `app/` source hash; ECR tags are immutable | Traceable, and a changed source always makes a new task definition | `latest` | Unchanged source never invokes the build again; `SKIPPED` appears only when the source reverts to a tag already in ECR |
| 13 | Private ECR, scan on push, lifecycle keeps last 10 images, `force_delete` | The isolated tier cannot pull a public image at runtime, and the app is freshly built | Pulling the public image directly | `force_delete` removes images on destroy |
| 14 | Separate `bootstrap/` stack creates a versioned, encrypted, public-access-blocked state bucket; the main stack uses the S3 backend with `use_lockfile`, configured with `-backend-config` flags read from the bootstrap outputs | Shared remote state with S3-native locking, no DynamoDB, no account-specific value committed | DynamoDB lock table (older pattern); local state only | One extra one-time step, and the bootstrap stack itself uses local state |
| 15 | One tag set on every taggable resource through provider `default_tags` (`Project`, `Environment`, `ManagedBy`; the bootstrap stack uses `Environment = "shared"`), propagated to Fargate tasks, plus an `aws_resourcegroups_group` filtered on `Project` | One console view of everything, including the state bucket | None | Tag-based grouping only covers taggable resources: AWS-managed ENIs, the dashboard and IAM inline policies have no tags |
| 16 | `monitoring` module: 8 alarms to an SNS topic, VPC flow logs, Container Insights, SSM session logs, one dashboard | Covers symptoms first (app health) and then causes (NAT, build, dev box) | Prometheus/Grafana or Datadog | Fine for one environment; see [Monitoring](architecture.md#monitoring) for scale |
| 17 | Readiness inputs instead of module-level `depends_on`: `app_service` takes `endpoints_ready`; `app_build` takes both `egress_ready` (NAT route) and `endpoints_ready` (VPC endpoints) | Module-level `depends_on` defers every data source in the module to apply time, which makes names and ARNs unknown and forces replacements on unrelated network changes | `depends_on` on the module blocks | Each module needs one extra input |
| 18 | CodeBuild queue ≤ 5 min + build ≤ 9 min < 15-minute trigger Lambda; the trigger retries IAM-propagation `AccessDenied` errors with backoff and restarts a build once if it fails before the BUILD phase | The first build always ends before the Lambda does, so a retry cannot start a second build that collides on the immutable tag; a clean first apply survives IAM propagation and transient provisioning failures | Default 60-minute build timeout, no retries | A slow legitimate build over 9 minutes, or a queue over 5, fails. A restarted build can outlive the Lambda; the apply then fails, and the next apply reports `SKIPPED` once the image exists |
| 19 | ECS target-tracking auto-scaling on average CPU (60%), min 2 (one task per AZ), max 4; `desired_count` is ignored after create so apply does not fight the scaler | The tier is stateless, so tasks are interchangeable and scale horizontally; two tasks survive an AZ loss | `ALBRequestCountPerTarget` tracking; scheduled scaling | CPU lags for I/O-bound apps, so request-count tracking would react sooner there |
| 20 | CI (GitHub Actions) runs only offline checks on every pull request and on pushes to main: `fmt`, `init -backend=false` and `validate` in all 8 directories, `terraform test`, the Lambda unit tests, `bash -n` | Catches breakage with no cloud credentials | Plan and apply in CI | Nothing is proven against AWS. A plan/apply job authenticating with OIDC is the production step |
| 21 | The build starts only after the NAT route and the VPC endpoints exist, and the buildspec retries the ECR login up to 4 times, 15 s apart | On the first real apply the first build failed in PRE_BUILD: `docker login` to ECR timed out in the minutes-old VPC. The trigger's restart-once (row 18) started a second build, which succeeded, so the apply passed, but a first build should not depend on a retry | Rely on the trigger's restart alone | A slow-to-warm network adds up to 45 s to a build. The exact cause (endpoint warm-up or the regional NAT expanding into the AZ) was not isolated; the fix covers both |

Backend configuration: the README passes the bucket and region as
`-backend-config` flags read from `terraform -chdir=bootstrap output`. A team
that prefers a file can copy `envs/dev/backend.hcl.example` to `backend.hcl`
and run `terraform init -backend-config=backend.hcl` instead.

## Exceptions and production fixes

- **Internet gateway exists only for the NAT.** Any NAT gateway requires one. No subnet route table points at it, so nothing is reachable from the internet. The only route to it (`0.0.0.0/0`) is in the route table AWS creates for the regional NAT gateway and associates with the gateway itself, not with any subnet; a subnet is public only if its own route table routes to an internet gateway. *Production:* the same; this is how AWS NAT works.
- **No NAT-only public subnet** because the regional NAT gateway needs none. If the regional mode were unavailable, the zonal fallback would need a small public subnet.
- **HTTP inside the VPC** between clients and the internal ALB, and between the ALB and tasks. No TLS certificate is provisioned. *Production:* HTTPS listener with a certificate from AWS Private CA.
- **SSM traffic leaves through the NAT** (no `ssm`/`ssmmessages`/`ec2messages` endpoints), to save cost. *Production:* add those three interface endpoints so the dev box needs no internet path for access.
- **Session logging** applies only to sessions that use the custom session document. A plain `start-session` uses account defaults. *Production:* set the account-level Session Manager preferences (`SSM-SessionManagerRunShell`) and deny `ssm:StartSession` without the logged document in IAM.
- **Trigger Lambda runs outside the VPC** in AWS-managed networking and only calls the CodeBuild and ECR APIs. It reaches nothing inside the VPC. *Production:* acceptable; or attach it to the egress subnets if policy requires all compute in the VPC.
- **Bootstrap stack uses local state.** It creates the bucket that remote state needs, so it cannot use that bucket. Its state file is small and recoverable; losing it means importing one bucket. *Production:* create the state bucket once per organisation (account vending or a platform stack) and keep its state there.
- **`/home` survives stop/start and instance replacement but not `terraform destroy`.** There is no snapshot or backup. *Production:* AWS Backup or a Data Lifecycle Manager snapshot policy on the home volume.
- **`force_delete` on ECR and `force_destroy` on the build-source bucket** so destroy always succeeds. The state bucket gets `force_destroy` only when `allow_destroy = true`. *Production:* turn these off.
- **Image is built and run as linux/amd64** for Fargate. It is not meant to run on the arm64 dev box (`t4g.small`), which has no emulation set up. *Production:* multi-arch build, or Fargate on Graviton to match the dev box.
- **Applied and verified once from zero** in the review account (see [Live results](validation.md#live-results)). [Verified at first apply](#verified-at-first-apply) gives the outcome of each item flagged before that run, and what is still unverified.
- Default region `us-east-1`; a single environment (`dev`).

## Considered and not applicable

- **Cache tier:** not applicable because there is no data to cache. It would be ElastiCache in the isolated tier, in front of the data tier.
- **CDN:** not applicable because the app is internal and serves no public static content. It would go in front of a public ALB or S3 origin.
- **Database, replication and sharding:** not applicable because the app is stateless and has no data. It would be a Multi-AZ managed database in a third, data subnet tier.
- **Message queue:** not applicable because there is no async work. It would be SQS between the app and a worker service.
- **Multi-region:** not applicable because this is a single-region exercise. It would be a second stack in another region behind DNS failover.

## Verified at first apply

Flagged before the first real run (2026-11-23); outcome of each:

- **NAT interface-type filter** in `validate.sh`: works (the NAT ENIs are excluded and the check passes).
- **Fargate ENI description match** (`*ecs*`) in `validate.sh`: works (task ENIs are found and checked).
- **Regional NAT** with `availability_mode = "regional"`: created first time and provisioned a public IP in each of the two AZs in use.
- **Second plan on the regional NAT**: `No changes.` (exit 0); the `availability_zone_address` read-back does not diff.
- **Pinned `terraform_version`** (1.17.2): downloads and installs on the dev box from the release zip.
- **Root volume tags**: the root (30 GB) and home (20 GB) volumes both carry the project tags.
- **Container Insights and task tags**: the log group is the Terraform-managed one (14-day retention), and Fargate tasks carry the propagated tags.
- **First build in a new VPC**: failed once on the ECR login and recovered by the trigger's restart; fixed by row 21.

### Still unverified

- NAT metrics under `AWS/NATGateway` with the `NatGatewayId` dimension: the alarm exists and is OK, but it treats missing data as not breaching, so OK does not prove the metric is published.
- An interactive session with the custom session document appearing in the session log group (only `send-command` was used).
- VS Code Remote-SSH over SSM.
- The `alert_email` subscription and delivery.
- Behaviour under load (auto-scaling events).

## Cost

Rough cost while running is on the order of $5 to $8 per day, mostly the NAT gateway, three interface endpoints across two AZs, the ALB and two small Fargate tasks. This is an estimate from list prices, not a measurement. The dev box can be stopped between uses; the home volume keeps its data.

## Inputs and outputs

Variables in `envs/dev`: `region`, `project`, `environment`, `vpc_cidr`, `dev_instance_type`, `alert_email` (optional; subscribes an address to the alerts topic, and AWS sends a confirmation e-mail). Every variable has a default; `envs/dev/terraform.tfvars.example` shows them.

Variables in `bootstrap`: `region`, `project`, `allow_destroy` (default `false`; set `true` only to tear down the state bucket).

Outputs of `envs/dev`: `region`, `vpc_id`, `isolated_route_table_id`, `dev_instance_id`, `ssm_command`, `alb_dns_name`, `app_url`, `image_uri`, `dashboard_name`, `resource_group`.
