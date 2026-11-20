output "state_bucket" {
  description = "State bucket name for the envs/<env> S3 backend."
  value       = aws_s3_bucket.state.bucket
}

output "region" {
  value = var.region
}
