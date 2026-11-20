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

variable "source_dir" {
  description = "Directory containing the Dockerfile."
  type        = string
}

variable "log_retention_days" {
  type    = number
  default = 14
}
