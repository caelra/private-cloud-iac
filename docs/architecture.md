# Architecture

```mermaid
flowchart TB
  dev["Developer laptop<br/>terraform apply · aws ssm start-session"]
  inet(("Internet<br/>packages · base image registry"))
  ssm["AWS Systems Manager<br/>Session Manager"]
  lambda["Build trigger Lambda<br/>outside the VPC, AWS APIs only"]
  ecr[("Private ECR")]
  s3[("S3<br/>build-source bucket · ECR layers")]
  logs["CloudWatch<br/>logs · metrics · dashboard"]
  alarms["CloudWatch alarms"]
  sns["SNS alerts topic"]

  subgraph vpc["VPC 10.20.0.0/16 — no inbound from the internet — no resource has a public IP"]
    igw["Internet gateway<br/>used only by the NAT"]
    nat["Regional NAT gateway<br/>only public address"]
    s3gw["S3 gateway endpoint<br/>on both route tables"]

    subgraph egress["Egress tier — 10.20.0.0/24, 10.20.1.0/24 — 2 AZs — 0.0.0.0/0 → NAT"]
      ec2["Dev EC2<br/>EBS volume at /home"]
      cb["CodeBuild<br/>docker build + push"]
    end

    subgraph isolated["Isolated tier — 10.20.10.0/24, 10.20.11.0/24 — 2 AZs — local route only"]
      alb["Internal ALB :80"]
      ecs["ECS Fargate tasks :8080<br/>hello-app"]
      vpce["Interface endpoints<br/>ecr.api · ecr.dkr · logs"]
    end
  end

  %% Human access: no inbound path, the agent dials out through the NAT
  dev -- "IAM-authenticated session, HTTPS" --> ssm
  ec2 -- "SSM agent, packages: outbound only" --> nat
  nat --> igw
  igw -- "SSM agent channel" --> ssm
  igw -- "outbound only" --> inet

  %% App traffic: egress tier to isolated tier over the VPC local route
  ec2 -- "curl, HTTP :80" --> alb
  alb -- ":8080, ALB security group only" --> ecs

  %% Build: Terraform uploads the source and invokes the trigger
  dev -- "zip of app/" --> s3
  dev -- "aws_lambda_invocation" --> lambda
  lambda -- "StartBuild, wait" --> cb
  cb -- "base image pull" --> nat
  cb -- "source zip" --> s3gw
  cb -- "image push" --> vpce

  %% Runtime pull and logs stay private
  ecs -- "image pull, logs" --> vpce
  ecs -- "image layers" --> s3gw
  s3gw --> s3
  vpce --> ecr
  vpce -- "task logs" --> logs

  %% Monitoring: data path, then alarm path
  vpc -. "metrics, flow logs, build and session logs" .-> logs
  logs -. "metrics evaluated by" .-> alarms
  alarms -- "notify" --> sns
```

The developer laptop runs Terraform and the AWS CLI; it never opens a connection into the VPC. The internet gateway exists only because a NAT gateway requires one, and the only route to it is in the NAT gateway's own AWS-managed route table, not in any subnet's.

## How each private resource is reached

| Resource | Reached by | Path |
|---|---|---|
| Dev EC2 | Developers | SSM Session Manager. The agent opens an outbound connection through the NAT; the instance has no inbound rules |
| App (ALB + tasks) | Anything inside the VPC | Private DNS name of the internal ALB, HTTP :80, security group limited to the VPC CIDR |
| ECS tasks | The ALB only | Security-group reference on :8080 |
| ECR, CloudWatch Logs, S3 | Tasks in the isolated tier, CodeBuild | VPC interface endpoints (`ecr.api`, `ecr.dkr`, `logs`) and the S3 gateway endpoint |
| CodeBuild | The trigger Lambda | CodeBuild `StartBuild` API; the build runs in the egress subnets and pulls its base image through the NAT |
| Trigger Lambda | Terraform | `aws_lambda_invocation` (Lambda Invoke API); the function is not attached to the VPC |
| Internet | Egress tier only | NAT gateway, outbound only |

## Monitoring

Monitoring and alerting is part of the solution: `modules/monitoring` is created by the same `terraform apply` as the resources it watches.

### Approach

- **Where it is defined:** in Terraform, in the same stack, so an environment never exists without its alarms.
- **What to alert on:** symptoms first (app unhealthy or returning errors), then causes (CPU, memory, NAT, build, dev box); only what someone should act on.
- **Where alerts go:** one SNS topic per environment; subscribers (e-mail via `alert_email` today, chat or on-call later) attach without touching the alarms.
- **What is kept:** logs for every component with retention set in code, plus VPC flow logs and SSM session logs for security review.
- **How it is managed:** thresholds, retention and the alert address are variables; nothing is configured by hand.

### What is built

- **8 alarms** to the `<name>-alerts` SNS topic: unhealthy targets, target 5xx, healthy targets below 2, ECS CPU and memory above 80%, dev box status check, NAT port-allocation errors, failed builds.
- **Dashboard** (`dashboard_name` output): requests and errors, p95 latency, CPU and memory, NAT traffic, alarm state.
- **Logs:** app, build, trigger Lambda and VPC flow logs with 14-day retention; SSM session logs with 30 days.

Container Insights is off because AWS re-creates its log group after a destroy, which breaks the next apply.

### At larger scale

Alarms would come from shared module defaults per service and feed one central account (CloudWatch cross-account observability, Prometheus/Grafana or Datadog). Alerts would route by severity and ownership through an on-call tool and be tied to SLOs rather than fixed thresholds. Flow and session logs would go to a central log account with longer retention.

## Scaling

The stateless ECS service auto-scales between 2 and 4 tasks to hold average CPU near 60%; the minimum of two keeps one task per AZ.

## Modules

- `network`: VPC, both tiers in two AZs, regional NAT and internet gateway, route tables, flow logs.
- `endpoints`: `ecr.api`, `ecr.dkr`, `logs` interface endpoints and the S3 gateway endpoint.
- `dev_env`: private dev EC2 (AL2023 arm64, IMDSv2), encrypted `/home` volume, IAM role, logged SSM session document.
- `app_build`: private ECR, source bucket, CodeBuild project and the trigger Lambda that builds during apply.
- `app_service`: ECS cluster and Fargate service, internal ALB, security groups, auto-scaling.
- `monitoring`: SNS topic, alarms, dashboard.
- `bootstrap/`: one-time stack with local state that creates the state bucket.
- `envs/dev/`: root stack that wires the modules, S3 backend, default tags and the stack test.
