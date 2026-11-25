# Bucket and region are passed at init (-backend-config), so no account-specific
# value is committed. See the README.
terraform {
  backend "s3" {
    key          = "envs/dev/terraform.tfstate"
    encrypt      = true
    use_lockfile = true # S3-native state locking; no DynamoDB table needed
  }
}
