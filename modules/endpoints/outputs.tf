output "ready" {
  description = "Set once every endpoint exists."
  value       = "ready"
  depends_on  = [aws_vpc_endpoint.interface, aws_vpc_endpoint.s3]
}
