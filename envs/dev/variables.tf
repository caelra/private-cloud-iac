variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name; used for naming, tagging and the resource group."
  type        = string
  default     = "quadsci-exercise"
}

variable "environment" {
  description = "Environment name; used for naming and the Environment tag."
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "VPC CIDR block; the egress and isolated subnets are carved from it."
  type        = string
  default     = "10.20.0.0/16"
}

variable "dev_instance_type" {
  description = "EC2 instance type for the dev box; must be arm64 (Graviton) to match the AMI and tooling downloads."
  type        = string
  default     = "t4g.small"
}

variable "alert_email" {
  description = "Optional e-mail address for alarm notifications."
  type        = string
  default     = ""
}
