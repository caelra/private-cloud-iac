# Bucket and region come from backend.hcl so no account-specific value is committed:
#   terraform init -backend-config=backend.hcl
terraform {
  backend "s3" {
    key          = "envs/dev/terraform.tfstate"
    encrypt      = true
    use_lockfile = true # S3-native state locking; no DynamoDB table needed
  }
}
