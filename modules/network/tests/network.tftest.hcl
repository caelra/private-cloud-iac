mock_provider "aws" {
  override_data {
    target = data.aws_availability_zones.available
    values = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }
}

variables {
  name     = "test"
  vpc_cidr = "10.20.0.0/16"
}

run "two_subnets_per_tier" {
  command = plan

  assert {
    condition     = length(aws_subnet.egress) == 2 && length(aws_subnet.isolated) == 2
    error_message = "Expected two egress and two isolated subnets."
  }
}

run "no_subnet_assigns_public_ips" {
  command = plan

  assert {
    condition = alltrue([
      for s in concat(aws_subnet.egress, aws_subnet.isolated) : s.map_public_ip_on_launch == false
    ])
    error_message = "A subnet would auto-assign public IPs."
  }
}

run "tier_cidrs_do_not_collide" {
  command = plan

  assert {
    condition = length(distinct(concat(
      [for s in aws_subnet.egress : s.cidr_block],
      [for s in aws_subnet.isolated : s.cidr_block],
    ))) == 4
    error_message = "Subnet CIDRs overlap."
  }
}
