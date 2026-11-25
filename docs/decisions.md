# Design decisions

Each significant choice, the alternative rejected, and what it costs.

## Decisions

| # | Choice | Why | Alternative rejected | Tradeoff |
|---|---|---|---|---|
| 1 | AWS | Strongest platform for the author | GCP, Azure | Moving clouds means re-implementing the modules |
| 2 | `egress` and `isolated` tiers, each in 2 AZs | An ALB needs two AZs | Single AZ | Double the subnets and endpoint ENIs |
| 3 | Regional NAT gateway, no public subnet | One NAT spans AZs | Zonal NAT in a public subnet; NAT instance | Still needs an internet gateway ([exceptions](../README.md#8-where-the-design-bends-a-requirement)) |
| 4 | SSM Session Manager for human access | IAM auth, no inbound ports, logging, Remote-SSH | Bastion (public IP); Client VPN; EC2 Instance Connect Endpoint | Needs the CLI and Session Manager plugin locally |
| 5 | Dev box reaches SSM through the NAT | Saves about $44/month of endpoints | `ssm`, `ssmmessages`, `ec2messages` endpoints | SSM traffic leaves via the NAT |
| 6 | EC2 `t4g.small` with a separate encrypted `/home` volume, tooling by cloud-init | `/home` outlives the instance | Cloud9; WorkSpaces; devcontainer on Fargate | `/home` does not survive `terraform destroy` |
| 7 | ECS Fargate | No nodes or control plane; one reliable apply ([README](../README.md#how-the-app-is-built-and-deployed-requirement-4)) | EKS; App Runner; Lambda | Costs more per vCPU than EC2 |
| 8 | App in the isolated tier | Proves a tier with no internet route works | App in the egress tier | Needs VPC endpoints for pull and logs |
| 9 | Internal ALB on :80 (VPC CIDR only); tasks accept :8080 from the ALB only | Health-checked endpoint with metrics | Service Connect / Cloud Map | HTTP inside the VPC |
| 10 | CodeBuild in the egress subnets builds a zip of `app/` | No local Docker, no arm64/amd64 mismatch | Local Docker provider | More moving parts |
| 11 | `aws_lambda_invocation` starts the build and waits | Apply stays pure Terraform | `local-exec` with the AWS CLI | A small Lambda to maintain |
| 12 | Image tag from the `app/` source hash; immutable ECR tags | Traceable; a source change means a new task definition | `latest` | Reverted source skips the build |
| 13 | Private ECR, scan on push, keep last 10 images | The isolated tier cannot pull public images | Pulling the public image | `force_delete` removes images on destroy |
| 14 | Bootstrap stack for the state bucket; S3 backend with `use_lockfile` | Remote state, native locking, no committed account values | DynamoDB lock table; local state | One extra one-time step |
| 15 | Provider `default_tags` plus a resource group on `Project` | One view of everything | None | Untaggable resources are not listed |
| 16 | `monitoring` module: 8 alarms, SNS, flow logs, session logs, dashboard | Symptoms first, then causes | Prometheus/Grafana; Datadog | Per-environment; see [Monitoring](architecture.md#monitoring) |
| 17 | Readiness inputs instead of module `depends_on` | Module `depends_on` defers data sources and forces replacements | `depends_on` on modules | One extra input per module |
| 18 | Build timeouts below the 15-min Lambda limit; retries IAM errors, restarts once before BUILD | No duplicate build; survives IAM propagation | 60-min default, no retries | Builds over 9 minutes fail |
| 19 | CPU target tracking at 60%, 2 to 4 tasks | Stateless tier; survives an AZ loss | Request-count tracking; scheduled | CPU lags for I/O-bound apps |
| 20 | CI runs offline checks only | No cloud credentials needed | Plan and apply in CI | Nothing proven against AWS in CI |
| 21 | Build waits for NAT route and endpoints; buildspec retries ECR login | First build's ECR login timed out in a minutes-old VPC | Rely on the trigger's restart | Up to 45 s added on a slow network |
| 22 | Container Insights off; min-capacity alarm uses ALB `HealthyHostCount` | AWS re-created its log group after destroy | Delete the group by hand | No task-level metrics |

No cache, CDN, database, queue or multi-region was built because one stateless internal service has no data, public content or async work.

## Cost

Running cost is an estimated $5–8 per day from list prices, mostly the NAT gateway, three interface endpoints across two AZs, the ALB and two small Fargate tasks. The dev box can be stopped between uses; its home volume keeps the data.
