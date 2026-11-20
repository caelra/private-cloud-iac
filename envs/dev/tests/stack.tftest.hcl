mock_provider "aws" {
  override_data {
    target = module.network.data.aws_availability_zones.available
    values = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }

  override_data {
    target = module.dev_env.data.aws_ssm_parameter.al2023
    values = {
      insecure_value = "ami-0123456789abcdef0"
    }
  }

  override_data {
    target = module.app_build.data.aws_caller_identity.current
    values = {
      account_id = "123456789012"
    }
  }

  override_data {
    target = module.app_build.data.aws_partition.current
    values = {
      partition = "aws"
    }
  }

  override_data {
    target = module.app_build.data.aws_region.current
    values = {
      region = "us-east-1"
    }
  }

  override_data {
    target = module.app_service.data.aws_partition.current
    values = {
      partition = "aws"
    }
  }

  override_data {
    target = module.app_service.data.aws_region.current
    values = {
      region = "us-east-1"
    }
  }

  override_data {
    target = module.dev_env.data.aws_partition.current
    values = {
      partition = "aws"
    }
  }

  override_data {
    target = module.dev_env.data.aws_region.current
    values = {
      region = "us-east-1"
    }
  }

  override_data {
    target = module.endpoints.data.aws_region.current
    values = {
      region = "us-east-1"
    }
  }

  override_data {
    target = module.monitoring.data.aws_region.current
    values = {
      region = "us-east-1"
    }
  }

  override_resource {
    target          = module.app_build.aws_ecr_repository.app
    override_during = plan
    values = {
      repository_url = "123456789012.dkr.ecr.us-east-1.amazonaws.com/test-app"
    }
  }

  # The stack decodes this to build the image URI.
  override_resource {
    target          = module.app_build.aws_lambda_invocation.build
    override_during = plan
    values = {
      result = "{\"status\":\"SUCCEEDED\",\"image_tag\":\"abc123def456\"}"
    }
  }
}

# Child-module resources are not addressable from a root test (only module
# outputs are), so root-level properties are asserted through outputs.
run "app_uses_built_image" {
  command = plan

  assert {
    condition     = strcontains(output.image_uri, ":abc123def456")
    error_message = "The stack must expose the image tag produced by the build."
  }

  assert {
    condition     = startswith(output.app_url, "http://")
    error_message = "app_url must be derived from the ALB DNS name."
  }
}
