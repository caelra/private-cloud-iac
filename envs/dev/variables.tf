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
  type    = string
  default = "dev"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "dev_instance_type" {
  type    = string
  default = "t4g.small"
}

variable "alert_email" {
  description = "Optional e-mail address for alarm notifications."
  type        = string
  default     = ""
}
