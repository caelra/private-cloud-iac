data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  partition  = data.aws_partition.current.partition

  # The tag is the source hash: same source, same tag; new source, new deploy.
  image_tag  = substr(data.archive_file.source.output_sha256, 0, 12)
  source_key = "source/${local.image_tag}.zip"
  registry   = split("/", aws_ecr_repository.app.repository_url)[0]
}

# --- Registry -----------------------------------------------------------------

resource "aws_ecr_repository" "app" {
  name                 = "${var.name}-app"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true # exercise environment: allow clean teardown

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

# --- Build source ---------------------------------------------------------------

data "archive_file" "source" {
  type        = "zip"
  source_dir  = var.source_dir
  output_path = "${path.module}/.build/source.zip"
}

resource "aws_s3_bucket" "source" {
  bucket        = "${var.name}-build-source-${local.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "source" {
  bucket                  = aws_s3_bucket.source.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "source" {
  bucket = aws_s3_bucket.source.id
  key    = local.source_key
  source = data.archive_file.source.output_path
  etag   = data.archive_file.source.output_md5
}

# --- CodeBuild --------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "build" {
  name              = "/${var.name}/codebuild"
  retention_in_days = var.log_retention_days
}

resource "aws_security_group" "build" {
  name        = "${var.name}-codebuild"
  description = "CodeBuild: no inbound, outbound anywhere"
  vpc_id      = var.vpc_id

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name}-codebuild" }
}

resource "aws_iam_role" "build" {
  name = "${var.name}-codebuild"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "build" {
  name = "build-and-push"
  role = aws_iam_role.build.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["${aws_cloudwatch_log_group.build.arn}", "${aws_cloudwatch_log_group.build.arn}:*"]
      },
      {
        Sid      = "ReadSource"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion", "s3:GetBucketLocation", "s3:ListBucket"]
        Resource = [aws_s3_bucket.source.arn, "${aws_s3_bucket.source.arn}/*"]
      },
      {
        Sid      = "EcrLogin"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "EcrPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = aws_ecr_repository.app.arn
      },
      {
        Sid    = "VpcNetworking"
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DeleteNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeDhcpOptions",
          "ec2:DescribeVpcs",
        ]
        Resource = "*"
      },
      {
        Sid      = "VpcEniPermission"
        Effect   = "Allow"
        Action   = "ec2:CreateNetworkInterfacePermission"
        Resource = "arn:${local.partition}:ec2:${local.region}:${local.account_id}:network-interface/*"
        Condition = {
          StringEquals = { "ec2:AuthorizedService" = "codebuild.amazonaws.com" }
        }
      },
    ]
  })
}

resource "aws_codebuild_project" "app" {
  name         = "${var.name}-app"
  description  = "Builds app/Dockerfile and pushes to ECR"
  service_role = aws_iam_role.build.arn

  # Minutes. Queue + build (14) must stay under the 15-minute trigger Lambda,
  # otherwise a retry can start a second build that collides on the immutable tag.
  queued_timeout = 5
  build_timeout  = 9

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true # required to run docker build

    environment_variable {
      name  = "REGISTRY"
      value = local.registry
    }

    environment_variable {
      name  = "REPO_URI"
      value = aws_ecr_repository.app.repository_url
    }

    environment_variable {
      name  = "IMAGE_TAG"
      value = local.image_tag
    }
  }

  source {
    type      = "S3"
    location  = "${aws_s3_bucket.source.bucket}/${local.source_key}"
    buildspec = file("${path.module}/buildspec.yml")
  }

  vpc_config {
    vpc_id             = var.vpc_id
    subnets            = var.subnet_ids
    security_group_ids = [aws_security_group.build.id]
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.build.name
    }
  }

  depends_on = [aws_iam_role_policy.build]
}

# --- Trigger: Terraform invokes this Lambda, which runs the build and waits ----

data "archive_file" "trigger" {
  type        = "zip"
  source_file = "${path.module}/lambda/trigger.py"
  output_path = "${path.module}/.build/trigger.zip"
}

resource "aws_cloudwatch_log_group" "trigger" {
  name              = "/aws/lambda/${var.name}-build-trigger"
  retention_in_days = var.log_retention_days
}

resource "aws_iam_role" "trigger" {
  name = "${var.name}-build-trigger"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "trigger" {
  name = "start-and-watch-build"
  role = aws_iam_role.trigger.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["${aws_cloudwatch_log_group.trigger.arn}", "${aws_cloudwatch_log_group.trigger.arn}:*"]
      },
      {
        Effect   = "Allow"
        Action   = ["codebuild:StartBuild", "codebuild:BatchGetBuilds"]
        Resource = aws_codebuild_project.app.arn
      },
      {
        Effect   = "Allow"
        Action   = "ecr:DescribeImages"
        Resource = aws_ecr_repository.app.arn
      },
    ]
  })
}

resource "aws_lambda_function" "trigger" {
  function_name    = "${var.name}-build-trigger"
  role             = aws_iam_role.trigger.arn
  runtime          = "python3.13"
  handler          = "trigger.handler"
  filename         = data.archive_file.trigger.output_path
  source_code_hash = data.archive_file.trigger.output_base64sha256
  timeout          = 900

  depends_on = [aws_cloudwatch_log_group.trigger, aws_iam_role_policy.trigger]
}

# Carries the egress readiness signal (e.g. NAT gateway id) as a dependency edge,
# so the build starts only after the route to the internet exists.
resource "terraform_data" "egress_ready" {
  input = var.egress_ready
}

# Same idea for the VPC endpoints: with private DNS on, ECR resolves to them
# from every subnet, so the build must not start while they are being created.
resource "terraform_data" "endpoints_ready" {
  input = var.endpoints_ready
}

resource "aws_lambda_invocation" "build" {
  function_name = aws_lambda_function.trigger.function_name

  input = jsonencode({
    project    = aws_codebuild_project.app.name
    repository = aws_ecr_repository.app.name
    image_tag  = local.image_tag
  })

  triggers = {
    image_tag = local.image_tag
  }

  depends_on = [aws_s3_object.source, terraform_data.egress_ready, terraform_data.endpoints_ready]
}
