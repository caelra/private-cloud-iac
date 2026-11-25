# Private platform on AWS (Terraform)

Terraform that builds a private AWS network, a persistent cloud dev environment reached without any public IP, and a container app built from source and served only inside the VPC. One `terraform apply` creates everything, including the image build.

Details: [architecture diagram](docs/architecture.md) · [design decisions](docs/decisions.md) · [validation](docs/validation.md)

## 1. Provider and design

**Provider:** AWS. **Architecture:** own design. One VPC, two subnet tiers in two AZs:

- **Egress** tier (dev box, CodeBuild): `0.0.0.0/0` routes to a regional NAT gateway, outbound only.
- **Isolated** tier (internal ALB, ECS Fargate tasks, VPC endpoints): local route only, no internet route at all. The stateless app scales from 2 to 4 tasks on CPU.
- No resource has a public IP. The only public address is the NAT gateway's.
- The tiers reach each other privately over the VPC local route (dev box → internal ALB); security groups allow only needed flows.

### Private access (Requirement 2): SSM Session Manager

Developers reach the dev box with SSM Session Manager: IAM authentication, no inbound ports (the agent dials out), sessions logged to CloudWatch, and port forwarding and VS Code Remote-SSH over the same channel. Rejected: a bastion host (needs a public IP), Client VPN (cost, certificates), EC2 Instance Connect Endpoint (SSH only, weaker audit).

### How the app is built and deployed (Requirement 4)

Terraform uploads a zip of `app/` (a Dockerfile on the sample `hello-app` image) to S3 and invokes a Lambda that runs a CodeBuild build in the egress tier and waits. CodeBuild pushes the image to a private ECR repository with an immutable tag taken from the source hash. An ECS Fargate service in the isolated tier, behind an internal ALB, pulls it through VPC endpoints, and the apply waits for steady state. Fargate over EKS: one container does not justify a control plane and nodes.

## 2. Repository layout

```
bootstrap/            one-time stack: remote state bucket (local state)
envs/dev/             root stack: wires the modules, backend, outputs, stack test
modules/              network, endpoints, dev_env, app_build, app_service, monitoring (docs/architecture.md#modules)
app/Dockerfile        the sample app image (hello-app, :8080)
scripts/validate.sh   live checks for each requirement
```

## 3. Prerequisites

- Terraform >= 1.10 and AWS credentials. No local Docker: CodeBuild builds the image.
- For validation and dev-box access: AWS CLI v2, the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html), `jq`.

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

The bootstrap stack keeps local state because it creates the bucket that remote state needs. Apply takes 7–8 minutes from zero.
**Verified:** applied from zero twice in us-east-1, the second time from a fresh clone: 83 resources, `scripts/validate.sh` 12/12, second plan clean ([live results](docs/validation.md#live-results)).

## 5. Connect to the dev box

```bash
$(terraform -chdir=envs/dev output -raw ssm_command)
```

Opens a logged shell as `ec2-user`; for VS Code Remote-SSH over SSM, see [docs/validation.md](docs/validation.md#vs-code-remote-ssh-over-ssm).

## 6. Validate each requirement

```bash
scripts/validate.sh    # PASS/FAIL per check, non-zero exit on failure
```

- **R1, Terraform only:** a clean `apply`, then `terraform -chdir=envs/dev plan -detailed-exitcode` reports `No changes.`
- **R2, no public IPs:** no public IP except the NAT's, no default route in the isolated tier, no inbound rules on the dev box, dev box online in SSM and egressing via the NAT.
- **R3, dev environment:** `/home` on a separate volume, tooling installed; the stop/start and replace proofs show files and packages survive.
- **R4, private app:** ALB internal, app returns 200 from the dev box but is unreachable from your machine, no public IP on task ENIs.

Manual proofs and offline tests: [docs/validation.md](docs/validation.md); CI runs the offline checks on every pull request and push to main.

## 7. Monitoring and alerting

Part of the solution: `modules/monitoring` is created by the same apply. Eight CloudWatch alarms notify an SNS topic (set `alert_email` to receive them), alongside a dashboard, VPC flow logs and SSM session logs. Approach and how it changes at scale: [docs/architecture.md](docs/architecture.md#monitoring).

## 8. Where the design bends a requirement

| Exception | Requirement | Why | Production fix |
|---|---|---|---|
| An internet gateway exists, used only by the NAT | R2 | AWS NAT gateways require one | None needed: no subnet route table points at it; the only route to it is in the NAT gateway's own AWS-managed route table |
| One-time bootstrap stack with local state | R1 | It creates the state bucket | Org-level state bucket from a platform stack |
| HTTP, not HTTPS, inside the VPC | R4 | No certificate provisioned | HTTPS listener with AWS Private CA |
| Dev box SSM traffic leaves via the NAT | R2, R3 | Saves about $44/month of endpoints | `ssm`, `ssmmessages`, `ec2messages` endpoints |
| `/home` survives stop/start and replacement, not destroy | R3 | No snapshot or backup | DLM or AWS Backup snapshots |
| Only sessions using the custom session document are logged | R2 | Plain `start-session` uses account defaults | Account-level session preferences, IAM enforcement |
| Trigger Lambda runs outside the VPC | R2 | It only calls AWS APIs | Attach it to the egress subnets if policy requires |

## 9. Cleanup and cost

```bash
terraform -chdir=envs/dev destroy
terraform -chdir=bootstrap apply -var allow_destroy=true     # lets Terraform delete the versioned state bucket
terraform -chdir=bootstrap destroy -var allow_destroy=true
```

Every taggable resource carries `Project`, `Environment` and `ManagedBy`, and the resource group named by the `resource_group` output lists them, including the state bucket. Cost is an estimated $5–8/day, mostly NAT, interface endpoints and the ALB ([cost](docs/decisions.md#cost)).
