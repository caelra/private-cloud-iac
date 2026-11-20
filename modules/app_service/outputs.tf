output "alb_dns_name" {
  value = aws_lb.app.dns_name
}

output "app_url" {
  description = "Only resolves to private addresses; reachable from inside the VPC."
  value       = "http://${aws_lb.app.dns_name}"
}

output "alb_arn_suffix" {
  value = aws_lb.app.arn_suffix
}

output "target_group_arn_suffix" {
  value = aws_lb_target_group.app.arn_suffix
}

output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "service_name" {
  value = aws_ecs_service.app.name
}

output "desired_count" {
  value = var.desired_count
}
