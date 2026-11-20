variable "name" {
  description = "Prefix for resource names."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
}

variable "az_count" {
  description = "Number of availability zones to span."
  type        = number
  default     = 2
}

variable "flow_log_retention_days" {
  description = "Retention for VPC flow logs."
  type        = number
  default     = 14
}
