# Architecture

```mermaid
flowchart TB
  dev[Developer laptop]
  inet((Internet))
  ssm[AWS Systems Manager<br/>Session Manager]

  subgraph vpc["VPC 10.20.0.0/16 — no resource has a public IP"]
    nat[Regional NAT gateway<br/>only public address]

    subgraph egress["Egress tier — 2 AZs — 0.0.0.0/0 → NAT"]
      ec2[Dev EC2<br/>EBS volume at /home]
      cb[CodeBuild<br/>docker build + push]
    end

    subgraph isolated["Isolated tier — 2 AZs — local route only"]
      alb[Internal ALB :80]
      ecs[ECS Fargate tasks :8080<br/>hello-app]
      vpce[VPC endpoints<br/>ecr.api · ecr.dkr · logs · S3 gateway]
    end
  end

  ecr[(ECR)]
  cw[CloudWatch<br/>logs · alarms · dashboard]
  sns[SNS alerts]

  dev -- "IAM-authenticated session, HTTPS" --> ssm
  ec2 -. "agent dials out via NAT" .-> ssm
  ec2 -- "curl, private" --> alb --> ecs
  egress -- "outbound only" --> nat --> inet
  cb -- push --> ecr
  ecs -- "pull + logs" --> vpce --> ecr
  vpce --> cw --> sns
```

Not drawn: the trigger Lambda that starts the CodeBuild build runs outside the
VPC and only calls the CodeBuild and ECR APIs. The internet gateway exists only
because a NAT gateway requires one; no route table points at it.

## How each private resource is reached

| Resource | Reached by | Path |
|---|---|---|
| Dev EC2 | Developers | SSM Session Manager. The agent opens an outbound connection; the instance has no inbound rules |
| App (ALB + tasks) | Anything inside the VPC | Private DNS name of the internal ALB, HTTP :80, security group limited to the VPC CIDR |
| ECS tasks | The ALB only | Security-group reference on :8080 |
| ECR, CloudWatch Logs, S3 | Tasks in the isolated tier | VPC interface and gateway endpoints |
| Internet | Egress tier only | NAT gateway, outbound only |
