#!/usr/bin/env bash
# Checks each exercise requirement against the live environment.
# Usage: scripts/validate.sh   (needs AWS credentials, terraform, jq)
set -euo pipefail

cd "$(dirname "$0")/../envs/dev"

out() { terraform output -raw "$1"; }

export AWS_REGION AWS_DEFAULT_REGION
AWS_REGION=$(out region)
AWS_DEFAULT_REGION=$AWS_REGION
VPC=$(out vpc_id)
INSTANCE=$(out dev_instance_id)
ALB_DNS=$(out alb_dns_name)
APP_URL=$(out app_url)
ISOLATED_RT=$(out isolated_route_table_id)

FAILED=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAILED=1; }
check() { # check "<description>" "<actual>" "<expected>"
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got: '$2', want: '$3')"; fi
}

# Runs a shell command on the dev box through SSM and prints its stdout.
# Never fails the script: problems go to stderr so the caller's check reports FAIL.
run_on_dev() {
  local id status
  if ! id=$(aws ssm send-command \
    --instance-ids "$INSTANCE" \
    --document-name AWS-RunShellScript \
    --parameters "$(jq -cn --arg c "$1" '{commands: [$c]}')" \
    --query Command.CommandId --output text); then
    echo "run_on_dev: send-command failed for $INSTANCE" >&2
    return 0
  fi
  aws ssm wait command-executed --command-id "$id" --instance-id "$INSTANCE" 2>/dev/null || true
  status=$(aws ssm get-command-invocation --command-id "$id" --instance-id "$INSTANCE" \
    --query Status --output text || true)
  if [ "$status" != "Success" ]; then
    echo "run_on_dev: command status $status" >&2
  fi
  aws ssm get-command-invocation --command-id "$id" --instance-id "$INSTANCE" \
    --query StandardOutputContent --output text || true
}

echo "== Requirement 2: no public IPs, network layout =="

check "no EC2 instance in the VPC has a public IP" \
  "$(aws ec2 describe-instances --filters "Name=vpc-id,Values=$VPC" \
      --query 'length(Reservations[].Instances[?PublicIpAddress!=`null`][])' --output text)" "0"

check "no network interface has a public IP except the NAT gateway" \
  "$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC" \
      --query 'length(NetworkInterfaces[?Association.PublicIp!=`null` && InterfaceType!=`nat_gateway`])' --output text)" "0"

check "isolated route table has no default route" \
  "$(aws ec2 describe-route-tables --route-table-ids "$ISOLATED_RT" \
      --query 'length(RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`])' --output text)" "0"

check "dev security group has no inbound rules" \
  "$(aws ec2 describe-instances --instance-ids "$INSTANCE" \
      --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text \
      | xargs -I{} aws ec2 describe-security-groups --group-ids {} \
          --query 'length(SecurityGroups[0].IpPermissions)' --output text)" "0"

check "dev box is managed by SSM (private access path works)" \
  "$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$INSTANCE" \
      --query 'InstanceInformationList[0].PingStatus' --output text)" "Online"

EGRESS_IP=$(run_on_dev "curl -s -m 10 https://checkip.amazonaws.com" | tr -d '[:space:]')
NAT_IPS=$(aws ec2 describe-nat-gateways \
  --filter "Name=vpc-id,Values=$VPC" "Name=state,Values=available" \
  --query 'NatGateways[].NatGatewayAddresses[].PublicIp' --output text) || true
if [ -n "$EGRESS_IP" ] && [[ " $(echo "$NAT_IPS" | tr -s '[:space:]' ' ') " == *" $EGRESS_IP "* ]]; then
  pass "egress tier reaches the internet through the NAT ($EGRESS_IP)"
else
  fail "egress tier reaches the internet through the NAT (got: '$EGRESS_IP', want one of: '$NAT_IPS')"
fi

echo "== Requirement 3: dev environment =="

check "/home is a separate volume" \
  "$(run_on_dev "findmnt -no LABEL /home" | tr -d '[:space:]')" "devhome"

check "dev tooling was bootstrapped" \
  "$(run_on_dev "command -v git docker terraform aws node tmux jq >/dev/null && echo ok" | tr -d '[:space:]')" "ok"

echo "== Requirement 4: private container app =="

check "load balancer is internal" \
  "$(aws elbv2 describe-load-balancers \
      --query "LoadBalancers[?DNSName=='$ALB_DNS'].Scheme | [0]" --output text)" "internal"

check "app returns 200 from inside the VPC (egress tier -> isolated tier)" \
  "$(run_on_dev "curl -s -o /dev/null -m 10 -w '%{http_code}' $APP_URL" | tr -d '[:space:]')" "200"

if curl -s -o /dev/null -m 5 "$APP_URL" 2>/dev/null; then
  fail "app is reachable from this machine, outside the VPC"
else
  pass "app is not reachable from outside the VPC"
fi

TASK_ENI_FILTERS=("Name=vpc-id,Values=$VPC" "Name=interface-type,Values=interface" "Name=description,Values=*ecs*")
TASK_ENIS=$(aws ec2 describe-network-interfaces --filters "${TASK_ENI_FILTERS[@]}" \
  --query 'length(NetworkInterfaces)' --output text) || TASK_ENIS="0"
if [ "$TASK_ENIS" = "0" ]; then
  fail "no running ECS task ENIs found"
else
  check "running tasks have no public IP" \
    "$(aws ec2 describe-network-interfaces --filters "${TASK_ENI_FILTERS[@]}" \
        --query 'length(NetworkInterfaces[?Association.PublicIp!=`null`])' --output text)" "0"
fi

echo
if [ "$FAILED" -eq 0 ]; then echo "All checks passed."; else echo "Some checks failed."; exit 1; fi
