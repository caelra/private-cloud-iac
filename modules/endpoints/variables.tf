variable "name" {
  description = "Prefix for resource names."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "subnet_ids" {
  description = "Subnets that get interface endpoint ENIs (the isolated tier)."
  type        = list(string)
}

variable "route_table_ids" {
  description = "Route tables that get the S3 gateway endpoint route."
  type        = list(string)
}

variable "interface_services" {
  description = "AWS services reached through interface endpoints. Fargate in a subnet with no internet route needs exactly these plus the S3 gateway."
  type        = list(string)
  default     = ["ecr.api", "ecr.dkr", "logs"]
}
