variable "name" {
  description = "Prefix for resource names."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  description = "Only source allowed to reach the load balancer."
  type        = string
}

variable "subnet_ids" {
  description = "Isolated-tier subnets for the ALB and the tasks."
  type        = list(string)
}

variable "image_uri" {
  description = "Full image reference including tag."
  type        = string
}

variable "endpoints_ready" {
  description = "Any value only known once the VPC endpoints exist (the endpoints module's `ready` output). Tasks wait on it so they can pull images in the isolated tier."
  type        = string
}

variable "container_port" {
  type    = number
  default = 8080
}

variable "desired_count" {
  type    = number
  default = 2
}

variable "cpu" {
  type    = number
  default = 256
}

variable "memory" {
  type    = number
  default = 512
}

variable "log_retention_days" {
  type    = number
  default = 14
}
