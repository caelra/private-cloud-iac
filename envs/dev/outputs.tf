output "region" {
  value = var.region
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "isolated_route_table_id" {
  value = module.network.isolated_route_table_id
}

output "dev_instance_id" {
  value = module.dev_env.instance_id
}

output "ssm_command" {
  description = "Open a shell on the dev box."
  value       = module.dev_env.ssm_command
}

output "alb_dns_name" {
  value = module.app_service.alb_dns_name
}

output "app_url" {
  description = "Curl this from the dev box. It is not reachable from outside the VPC."
  value       = module.app_service.app_url
}

output "image_uri" {
  value = module.app_build.image_uri
}

output "dashboard_name" {
  value = module.monitoring.dashboard_name
}

output "resource_group" {
  value = aws_resourcegroups_group.project.name
}
