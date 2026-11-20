output "state_bucket" {
  description = "Bucket name to put in envs/<env>/backend.hcl."
  value       = aws_s3_bucket.state.bucket
}

output "region" {
  value = var.region
}
