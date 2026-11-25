data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs            = slice(data.aws_availability_zones.available.names, 0, var.az_count)
  egress_cidrs   = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i)]
  isolated_cidrs = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, 10 + i)]
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = var.name }
}

# Lock down the default security group so nothing can use it by accident.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${var.name}-default-unused" }
}

# Required for the NAT gateway to reach the internet. No subnet routes to it.
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = var.name }
}

# Regional NAT gateway: spans AZs and needs no public subnet.
# Its address is the only public IP in the stack.
resource "aws_nat_gateway" "this" {
  vpc_id            = aws_vpc.this.id
  availability_mode = "regional"

  tags = { Name = var.name }

  depends_on = [aws_internet_gateway.this]
}

# Egress tier: outbound-only internet through the NAT.

resource "aws_subnet" "egress" {
  count = var.az_count

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.egress_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = { Name = "${var.name}-egress-${local.azs[count.index]}", Tier = "egress" }
}

resource "aws_route_table" "egress" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${var.name}-egress" }
}

resource "aws_route" "egress_default" {
  route_table_id         = aws_route_table.egress.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

resource "aws_route_table_association" "egress" {
  count = var.az_count

  subnet_id      = aws_subnet.egress[count.index].id
  route_table_id = aws_route_table.egress.id
}

# Isolated tier: local route only, no path to the internet.

resource "aws_subnet" "isolated" {
  count = var.az_count

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.isolated_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = { Name = "${var.name}-isolated-${local.azs[count.index]}", Tier = "isolated" }
}

resource "aws_route_table" "isolated" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${var.name}-isolated" }
}

resource "aws_route_table_association" "isolated" {
  count = var.az_count

  subnet_id      = aws_subnet.isolated[count.index].id
  route_table_id = aws_route_table.isolated.id
}

resource "aws_cloudwatch_log_group" "flow" {
  name              = "/${var.name}/vpc-flow-logs"
  retention_in_days = var.flow_log_retention_days
}

resource "aws_iam_role" "flow" {
  name = "${var.name}-vpc-flow-logs"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "flow" {
  name = "write-flow-logs"
  role = aws_iam_role.flow.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
      ]
      Resource = ["${aws_cloudwatch_log_group.flow.arn}", "${aws_cloudwatch_log_group.flow.arn}:*"]
    }]
  })
}

resource "aws_flow_log" "this" {
  vpc_id               = aws_vpc.this.id
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow.arn
  iam_role_arn         = aws_iam_role.flow.arn
}
