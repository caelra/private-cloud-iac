mock_provider "aws" {
  override_data {
    target = data.aws_partition.current
    values = {
      partition = "aws"
    }
  }

  override_data {
    target = data.aws_region.current
    values = {
      region = "us-east-1"
    }
  }
}

variables {
  name            = "test"
  vpc_id          = "vpc-0123456789abcdef0"
  vpc_cidr        = "10.20.0.0/16"
  subnet_ids      = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
  image_uri       = "123456789012.dkr.ecr.us-east-1.amazonaws.com/test-app:abc123"
  endpoints_ready = "ready"
}

run "load_balancer_is_internal" {
  command = plan

  assert {
    condition     = aws_lb.app.internal == true
    error_message = "ALB must be internal."
  }
}

run "tasks_get_no_public_ip" {
  command = plan

  assert {
    condition     = aws_ecs_service.app.network_configuration[0].assign_public_ip == false
    error_message = "Fargate tasks must not get public IPs."
  }
}

run "alb_only_accepts_vpc_traffic" {
  command = plan

  assert {
    condition     = aws_vpc_security_group_ingress_rule.alb_from_vpc.cidr_ipv4 == "10.20.0.0/16"
    error_message = "ALB ingress must be limited to the VPC CIDR."
  }
}

run "scales_horizontally_on_cpu" {
  command = plan

  assert {
    condition     = aws_appautoscaling_target.app.min_capacity == 2 && aws_appautoscaling_target.app.max_capacity == 4
    error_message = "Auto-scaling must run between 2 and 4 tasks by default."
  }

  assert {
    condition     = aws_appautoscaling_policy.cpu.target_tracking_scaling_policy_configuration[0].target_value == 60
    error_message = "CPU target must default to 60 percent."
  }
}
