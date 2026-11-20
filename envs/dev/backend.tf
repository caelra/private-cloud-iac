# Bucket and region are passed at init so no account-specific value is committed:
#   terraform init -backend-config="bucket=..." -backend-config="region=..."
# (values from `terraform -chdir=bootstrap output`; see README). Teams that prefer
# a file can copy backend.hcl.example to backend.hcl and pass -backend-config=backend.hcl.
terraform {
  backend "s3" {
    key          = "envs/dev/terraform.tfstate"
    encrypt      = true
    use_lockfile = true # S3-native state locking; no DynamoDB table needed
  }
}
