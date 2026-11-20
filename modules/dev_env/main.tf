data "aws_partition" "current" {}

data "aws_region" "current" {}

# Latest Amazon Linux 2023 arm64 AMI, published by AWS as a public parameter.
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

# --- Access: no inbound rules at all. SSM agent dials out. -------------------

resource "aws_security_group" "dev" {
  name        = "${var.name}-dev"
  description = "Dev box: no inbound, outbound anywhere"
  vpc_id      = var.vpc_id

  # Explicit empty set: also removes any inbound rule added outside Terraform.
  ingress = []

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name}-dev" }
}

resource "aws_cloudwatch_log_group" "sessions" {
  name              = "/${var.name}/ssm-sessions"
  retention_in_days = var.session_log_retention_days
}

resource "aws_iam_role" "dev" {
  name = "${var.name}-dev"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.dev.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "ecr_read" {
  role       = aws_iam_role.dev.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy" "session_logs" {
  name = "write-session-logs"
  role = aws_iam_role.dev.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
        Resource = ["${aws_cloudwatch_log_group.sessions.arn}", "${aws_cloudwatch_log_group.sessions.arn}:*"]
      },
      {
        Effect   = "Allow"
        Action   = "logs:DescribeLogGroups"
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_instance_profile" "dev" {
  name = "${var.name}-dev"
  role = aws_iam_role.dev.name
}

# Session preferences: sessions started with this document (--document-name, as the
# ssm_command output does) are logged and land in ec2-user's persistent home.
resource "aws_ssm_document" "session" {
  name            = "${var.name}-dev-session"
  document_type   = "Session"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "1.0"
    description   = "Interactive shell on the dev box as ec2-user, logged to CloudWatch"
    sessionType   = "Standard_Stream"
    inputs = {
      cloudWatchLogGroupName      = aws_cloudwatch_log_group.sessions.name
      cloudWatchEncryptionEnabled = false
      cloudWatchStreamingEnabled  = true
      runAsEnabled                = true
      runAsDefaultUser            = "ec2-user"
      idleSessionTimeout          = "30"
      shellProfile = {
        linux = "cd ~ && exec bash -l"
      }
    }
  })
}

# --- Persistent home volume ---------------------------------------------------

resource "aws_ebs_volume" "home" {
  availability_zone = var.availability_zone
  size              = var.home_volume_size_gb
  type              = "gp3"
  encrypted         = true

  tags = { Name = "${var.name}-dev-home" }
}

# --- Instance -----------------------------------------------------------------

# cloud-init installs packages from the internet; referencing the NAT id here lets
# the instance wait until the route exists without a module-level depends_on.
resource "terraform_data" "egress_ready" {
  input = var.egress_ready
}

resource "aws_instance" "dev" {
  ami                         = data.aws_ssm_parameter.al2023.insecure_value
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.dev.id]
  iam_instance_profile        = aws_iam_instance_profile.dev.name
  associate_public_ip_address = false

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2 # lets containers on the box use the instance role
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size_gb
    encrypted   = true

    # Provider default_tags may not reach the root volume; set a tag explicitly.
    tags = { Name = "${var.name}-dev-root" }
  }

  # The NVMe device name embeds the volume id without its dash.
  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    home_volume_id    = replace(aws_ebs_volume.home.id, "-", "")
    terraform_version = var.terraform_version
  })
  user_data_replace_on_change = true

  tags = { Name = "${var.name}-dev" }

  depends_on = [terraform_data.egress_ready]

  lifecycle {
    # A new AMI release should not replace a developer's machine mid-week.
    ignore_changes = [ami]
  }
}

resource "aws_volume_attachment" "home" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.home.id
  instance_id = aws_instance.dev.id

  # Instance replacement destroys this first; a mounted /home would hang a plain detach.
  stop_instance_before_detaching = true
}
