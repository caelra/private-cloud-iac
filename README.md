# Private platform on AWS (Terraform)

Terraform that builds a private AWS network, a persistent cloud dev environment reached without any public IP, and a container app built from source and served only inside the VPC. One `terraform apply` creates everything, including the image build. Details: [architecture diagram](docs/architecture.md) · [design decisions](docs/decisions.md) · [validation](docs/validation.md)

## 1. Provider and design

**Provider:** AWS. **Architecture:** own design. One VPC with two subnet tiers in two AZs; no resource has a public IP, and the only public address is the NAT gateway's.
- **Egress** tier (dev box, CodeBuild): `0.0.0.0/0` routes to a regional NAT gateway, outbound only.
- **Isolated** tier (internal ALB, ECS Fargate tasks, VPC endpoints): local route only, no internet route. The stateless app scales 2–4 tasks on CPU.
- The tiers reach each other privately over the VPC local route (dev box → internal ALB); security groups allow only needed flows.

### Private access (Requirement 2): SSM Session Manager

Developers reach the dev box through SSM Session Manager: IAM authentication, no inbound ports (the agent dials out), sessions logged to CloudWatch, and port forwarding and [VS Code Remote-SSH](docs/validation.md#vs-code-remote-ssh-over-ssm) over the same channel. Rejected: bastion host (public IP), Client VPN (cost, certificates), EC2 Instance Connect Endpoint (SSH only, weaker audit).

### How the app is built and deployed (Requirement 4)

The app (a Dockerfile on the sample `hello-app` image) runs on ECS Fargate in the isolated tier behind an internal ALB. One `terraform apply` builds and deploys it with these services, in flow order:

- **S3:** holds the zip of `app/` that Terraform uploads as the build source.
- **Lambda** (Terraform's `aws_lambda_invocation`): starts the build and waits; a failed build fails the apply.
- **CodeBuild** (egress tier): builds and pushes the image, pulling the base image through the NAT.
- **ECR** (private, immutable tags from the source hash): stores the image.
- **ECS Fargate** (isolated tier, 2–4 tasks): runs it with no public IP and no nodes.
- **Internal ALB:** the only way in, HTTP :80 from inside the VPC, with health checks; the apply waits for steady state.
- **VPC endpoints** (`ecr.api`, `ecr.dkr`, `logs`, S3 gateway): image pull and logs with no internet route.

Why Fargate, not EKS:
- No control plane or nodes to run, patch and upgrade for one stateless container.
- One apply stays reliable: EKS would need the `kubernetes`/`helm` providers configured from the cluster's own outputs in the same apply, fragile on a clean apply and on destroy.
- Terraform outside the VPC cannot reach a private-only EKS API endpoint without a runner in the VPC or a public endpoint (ruled out here).
- The no-internet tier stays small: an internal ALB on EKS needs the AWS Load Balancer Controller (IAM role for service accounts, subnet tags) and more endpoints (`sts`, `ec2`, `elasticloadbalancing`, `eks`); ECS needs only the endpoints already here.

EKS becomes the better choice with many services or a team standardised on Kubernetes; only the runtime module would change; the network, endpoints, ECR and build carry over.

## 2. Repository layout

```
bootstrap/            one-time stack: remote state bucket (local state)
envs/dev/             root stack: wires the modules, backend, outputs, stack test
modules/              network, endpoints, dev_env, app_build, app_service, monitoring (docs/architecture.md#modules)
scripts/validate.sh   live checks for each requirement
```

## 3. Prerequisites

- Terraform >= 1.10 and AWS credentials. No local Docker: CodeBuild builds the image.
- For validation and access: AWS CLI v2, the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html), `jq`.

## 4. Run it

```bash
# From the repository root. One time: create the remote state bucket
terraform -chdir=bootstrap init
terraform -chdir=bootstrap apply

# Every time
terraform -chdir=envs/dev init \
  -backend-config="bucket=$(terraform -chdir=bootstrap output -raw state_bucket)" \
  -backend-config="region=$(terraform -chdir=bootstrap output -raw region)"
terraform -chdir=envs/dev apply
```

The bootstrap stack keeps local state because it creates the bucket remote state needs. Apply takes 7–8 minutes from zero.

**Verified:** applied from zero twice in us-east-1, the second time from a fresh clone: 83 resources, `scripts/validate.sh` 12/12, second plan clean ([live results](docs/validation.md#live-results)).

## 5. Connect to the dev box

```bash
$(terraform -chdir=envs/dev output -raw ssm_command)    # logged shell as ec2-user
```

## 6. Validate each requirement

```bash
scripts/validate.sh    # PASS/FAIL per check, non-zero exit on failure
```

- **R1, Terraform only:** a clean `apply`, then `terraform -chdir=envs/dev plan -detailed-exitcode` reports `No changes.`
- **R2, no public IPs:** none except the NAT's, no default route in the isolated tier, dev box with no inbound rules, online in SSM, egressing via the NAT.
- **R3, dev environment:** `/home` on a separate volume, tooling installed; stop/start and replace proofs show files and packages survive.
- **R4, private app:** ALB internal, 200 from the dev box, unreachable from your machine, no public IP on task ENIs.

Manual proofs and offline tests: [docs/validation.md](docs/validation.md); CI runs the offline checks on pull requests and pushes to main.

## 7. Monitoring and alerting

Part of the solution: the same apply creates `modules/monitoring`. Eight CloudWatch alarms notify an SNS topic (`alert_email` subscribes an address), plus a dashboard, VPC flow logs and SSM session logs. Approach and larger-scale design: [docs/architecture.md](docs/architecture.md#monitoring).

## 8. Where the design bends a requirement

| Exception | Requirement | Why | Production fix |
|---|---|---|---|
| An internet gateway exists, used only by the NAT | R2 | AWS NAT gateways require one | None needed: no subnet route table points at it; the only route to it is in the NAT gateway's own AWS-managed route table |
| One-time bootstrap stack with local state | R1 | It creates the state bucket | Org-level state bucket from a platform stack |
| HTTP, not HTTPS, inside the VPC | R4 | No certificate provisioned | HTTPS listener with AWS Private CA |
| Dev box SSM traffic leaves via the NAT | R2, R3 | Saves about $44/month of endpoints | `ssm`, `ssmmessages`, `ec2messages` endpoints |
| `/home` survives stop/start and replacement, not destroy | R3 | No snapshot or backup | DLM or AWS Backup snapshots |
| Only sessions using the custom session document are logged | R2 | Plain `start-session` uses account defaults | Account-level session preferences, IAM enforcement |
| Trigger Lambda runs outside the VPC | R2 | It only calls AWS APIs | Attach it to the egress subnets |

## 9. Cleanup and cost

```bash
terraform -chdir=envs/dev destroy
terraform -chdir=bootstrap apply -var allow_destroy=true     # allows deleting the versioned state bucket
terraform -chdir=bootstrap destroy -var allow_destroy=true
```

Every taggable resource carries `Project`, `Environment` and `ManagedBy`, and the `resource_group` output names a resource group listing them, including the state bucket. Estimated cost: $5–8/day, mostly NAT, interface endpoints and the ALB ([cost](docs/decisions.md#cost)).
