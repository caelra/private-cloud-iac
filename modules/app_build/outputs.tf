output "image_uri" {
  description = "Image reference. Only resolves after the build for this source hash succeeded."
  value       = "${aws_ecr_repository.app.repository_url}:${jsondecode(aws_lambda_invocation.build.result).image_tag}"
}

output "image_tag" {
  value = local.image_tag
}

output "repository_name" {
  value = aws_ecr_repository.app.name
}

output "codebuild_project_name" {
  value = aws_codebuild_project.app.name
}
