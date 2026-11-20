variable "region" {
  description = "AWS region for the state bucket."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name, used for naming and tagging."
  type        = string
  default     = "quadsci-exercise"
}
