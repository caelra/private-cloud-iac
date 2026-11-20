# Private platform on AWS (Terraform)

Terraform that builds a private AWS network, a persistent cloud dev environment reached without any public IP, and a container app built from source and served only inside the VPC. One `terraform apply` creates everything, including the image build.

- Architecture diagram, traffic direction and how each private resource is reached: [docs/architecture.md](docs/architecture.md)
- Every design choice with alternatives and tradeoffs: [docs/decisions.md](docs/decisions.md)
- Manual proofs and offline tests: [docs/validation.md](docs/validation.md)

## 1. Provider and design

**Provider:** AWS. **Architecture:** own design. One VPC, two subnet tiers in two AZs:

- **Egress** tier (dev box, CodeBuild): `0.0.0.0/0` routes to a regional NAT gateway, outbound only.
- **Isolated** tier (internal ALB, ECS Fargate tasks, VPC endpoints): local route only, no internet route at all.
- No resource has a public IP. The only public address is the NAT gateway's.
- The stateless app tier auto-scales between 2 and 4 Fargate tasks on CPU.

The egress tier reaches the isolated tier privately over the VPC local route (dev box → internal ALB). The reverse direction is possible at the route level, but security groups allow only what is needed.

### Private access (Requirement 2): SSM Session Manager

Developers reach the dev box with SSM Session Manager: IAM authentication, no inbound ports (the agent dials out), session logging to CloudWatch, and port forwarding and VS Code Remote-SSH over the same channel. Rejected: a bastion host (needs a public IP), Client VPN (cost and certificate management), EC2 Instance Connect Endpoint (SSH only, weaker audit trail).

### How the app is built and deployed (Requirement 4)

Terraform zips `app/` (a Dockerfile on the sample `hello-app` image) and uploads it to S3, then invokes a Lambda that runs a CodeBuild build in the egress tier and waits for it. CodeBuild pushes the image to a private ECR repository with an immutable tag taken from the source hash. An ECS Fargate service in the isolated tier, behind an internal ALB, pulls that image through VPC endpoints, and the apply waits for the service to reach steady state. Fargate over EKS: one container does not justify a control plane and nodes, and the private result is the same.

Every design choice, with alternatives and tradeoffs: [docs/decisions.md](docs/decisions.md).

## 2. Repository layout

```
bootstrap/            one-time stack: remote state bucket (local state)
envs/dev/             root stack: wires the modules, backend, outputs, stack test
modules/              network, endpoints, dev_env, app_build, app_service, monitoring
                      (what each module does: docs/architecture.md#modules)
app/Dockerfile        the sample app image (hello-app, :8080)
scripts/validate.sh   live checks for each requirement
docs/                 architecture diagram, decisions, validation
```

## 3. Prerequisites

- Terraform >= 1.10 and AWS credentials that can create the resources. The region comes from the `region` variable (default `us-east-1`); set `AWS_REGION` to match for manual `aws` commands (`scripts/validate.sh` sets it itself). No local Docker: CodeBuild builds the image.
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

The bootstrap stack keeps local state on purpose: it creates the bucket that remote state needs, so it cannot store its state there. Every variable has a default; see `envs/dev/terraform.tfvars.example`. Apply time is to be measured at first apply; the slow steps are the NAT gateway, the image build and the ECS service reaching steady state.

**Status:** not applied yet. The code is validated and tested offline with mocked providers; the items to check on the first real run are in [docs/decisions.md](docs/decisions.md#confirm-at-first-apply).

## 5. Connect to the dev box

```bash
$(terraform -chdir=envs/dev output -raw ssm_command)
```

This opens a logged shell as `ec2-user` in `/home/ec2-user`. For VS Code Remote-SSH over SSM, see [docs/validation.md](docs/validation.md#vs-code-remote-ssh-over-ssm).

## 6. Validate each requirement

```bash
scripts/validate.sh    # live checks, PASS/FAIL per check, non-zero exit on any failure
```

- **R1, Terraform only:** a clean `apply`, then `terraform -chdir=envs/dev plan -detailed-exitcode` reports `No changes.`
- **R2, no public IPs:** the script finds no public IP except the NAT's, no default route in the isolated tier, no inbound rules on the dev box, the dev box online in SSM, and its egress IP equal to the NAT's.
- **R3, dev environment:** the script finds `/home` on a separate volume and the tooling installed; the stop/start and replace proofs show files and packages survive.
- **R4, private app:** the script finds the ALB internal, the app returning 200 from the dev box but unreachable from your machine, and no public IP on task ENIs.

Manual proofs (persistence, redeploy, failed build) and the offline test suite: [docs/validation.md](docs/validation.md). CI runs the offline checks on every pull request and on pushes to main.

## 7. Monitoring and alerting

Treated as part of the solution: `modules/monitoring` is created by the same apply. Eight CloudWatch alarms (app symptoms first, then NAT, build and dev box) notify an SNS topic; set `alert_email` to receive them. One dashboard, Container Insights, VPC flow logs and SSM session logs cover the rest. The approach (where it is defined, what to alert on, where alerts go, how it is managed) and how it would change at scale: [docs/architecture.md](docs/architecture.md#monitoring).

## 8. Where the design bends a requirement

| Exception | Requirement | Why | Production fix |
|---|---|---|---|
| An internet gateway exists, used only by the NAT | R2 | AWS NAT gateways require one | None needed; no route table points at it |
| One-time bootstrap stack with local state | R1 | It creates the state bucket | Org-level state bucket from a platform stack |
| HTTP, not HTTPS, inside the VPC | R4 | No certificate provisioned | HTTPS listener with AWS Private CA |
| Dev box SSM traffic leaves via the NAT | R2, R3 | Saves about $22/month per AZ (about $44 here) of endpoints | `ssm`, `ssmmessages`, `ec2messages` endpoints |
| `/home` survives stop/start and replacement, not destroy | R3 | No snapshot or backup | DLM or AWS Backup snapshots |
| Only sessions using the custom document are logged | R2 | Plain `start-session` uses account defaults | Account-level session preferences, IAM enforcement |
| Trigger Lambda runs outside the VPC | R2 | It only calls AWS APIs | Attach it to the egress subnets if policy requires |
| `force_delete` on ECR, `force_destroy` on the build-source bucket | R1 | Clean teardown | Turn both off |
| Image is amd64; the dev box is arm64 | R4 | CodeBuild builds x86_64 for Fargate X86_64; base image not guaranteed multi-arch; Graviton dev box is cheaper | Multi-arch build, or Fargate on Graviton |
| Isolated → egress connections are blocked by security groups | R2 | Least privilege; the route exists and egress → isolated is proven by the curl | Add a specific rule when a flow needs it |

Longer explanations and production fixes: [docs/decisions.md](docs/decisions.md#exceptions-and-production-fixes).

## 9. Cleanup and cost

```bash
terraform -chdir=envs/dev destroy
terraform -chdir=bootstrap apply -var allow_destroy=true     # lets Terraform delete the versioned state bucket
terraform -chdir=bootstrap destroy -var allow_destroy=true
```

Every taggable resource carries the tags `Project`, `Environment` and `ManagedBy`. The resource group named by the `resource_group` output lists everything with `Project=quadsci-exercise`, including the state bucket. Not everything can be tagged: AWS-managed ENIs (endpoints, ALB, NAT, tasks, CodeBuild) are untagged but deleted with their parents, and the dashboard and IAM inline policies do not support tags. `terraform destroy` in `envs/dev` removes the environment; the bootstrap destroy removes the state bucket.

Cost: ≈ $5–8/day estimate, mostly NAT, interface endpoints and the ALB. Details in [docs/decisions.md](docs/decisions.md#cost).
