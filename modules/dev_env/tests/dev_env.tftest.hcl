mock_provider "aws" {
  override_data {
    target = data.aws_ssm_parameter.al2023
    values = {
      insecure_value = "ami-0123456789abcdef0"
    }
  }

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
  name              = "test"
  vpc_id            = "vpc-0123456789abcdef0"
  subnet_id         = "subnet-0123456789abcdef0"
  availability_zone = "us-east-1a"
  egress_ready      = "nat-0123456789abcdef0"
}

run "instance_is_private_and_hardened" {
  command = plan

  assert {
    condition     = aws_instance.dev.associate_public_ip_address == false
    error_message = "Dev instance must not get a public IP."
  }

  assert {
    condition     = aws_instance.dev.metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 must be required."
  }
}

run "security_group_has_no_ingress" {
  command = plan

  assert {
    condition     = length(aws_security_group.dev.ingress) == 0
    error_message = "Dev security group must not allow any inbound traffic."
  }
}

run "home_volume_is_separate_and_encrypted" {
  command = plan

  assert {
    condition     = aws_ebs_volume.home.encrypted == true
    error_message = "Home volume must be encrypted."
  }
}
