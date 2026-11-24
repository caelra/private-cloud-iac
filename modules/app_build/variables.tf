variable "name" {
  description = "Prefix for resource names."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Egress-tier subnets for CodeBuild. The build pulls its base image from the internet."
  type        = list(string)
}

variable "egress_ready" {
  description = "Any value that is only known once the egress route (NAT) exists, e.g. the NAT gateway id. The build waits on it."
  type        = string
}

variable "endpoints_ready" {
  description = "Any value that is only known once the VPC endpoints exist (the endpoints module's `ready` output). The build logs in and pushes to ECR through them."
  type        = string
}

variable "source_dir" {
  description = "Directory containing the Dockerfile."
  type        = string
}

variable "log_retention_days" {
  type    = number
  default = 14
}
