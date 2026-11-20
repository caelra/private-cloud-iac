variable "name" {
  description = "Prefix for resource names."
  type        = string
}

variable "alert_email" {
  description = "Optional e-mail subscribed to the alerts topic. Empty disables the subscription."
  type        = string
  default     = ""
}

variable "alb_arn_suffix" {
  type = string
}

variable "target_group_arn_suffix" {
  type = string
}

variable "ecs_cluster_name" {
  type = string
}

variable "ecs_service_name" {
  type = string
}

variable "ecs_desired_count" {
  type = number
}

variable "dev_instance_id" {
  type = string
}

variable "nat_gateway_id" {
  type = string
}

variable "codebuild_project_name" {
  type = string
}
