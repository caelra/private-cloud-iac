variable "name" {
  description = "Prefix for resource names."
  type        = string
}

variable "egress_ready" {
  description = "Any value that is only known once the egress route (NAT) exists, e.g. the NAT gateway id. cloud-init installs packages from the internet, so the instance waits until the NAT route exists."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  description = "Egress-tier subnet for the dev instance."
  type        = string
}

variable "availability_zone" {
  description = "AZ of subnet_id. The home volume must live in the same AZ."
  type        = string
}

variable "instance_type" {
  description = "Graviton instance type for the dev box."
  type        = string
  default     = "t4g.small"
}

variable "root_volume_size_gb" {
  type    = number
  default = 30
}

variable "home_volume_size_gb" {
  description = "Size of the persistent volume mounted at /home."
  type        = number
  default     = 20
}

variable "session_log_retention_days" {
  type    = number
  default = 30
}
