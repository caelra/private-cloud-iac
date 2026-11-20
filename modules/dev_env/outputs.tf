output "instance_id" {
  value = aws_instance.dev.id
}

output "session_document_name" {
  value = aws_ssm_document.session.name
}

output "ssm_command" {
  description = "Command that opens a shell on the dev box."
  value       = "aws ssm start-session --region ${data.aws_region.current.region} --target ${aws_instance.dev.id} --document-name ${aws_ssm_document.session.name}"
}
