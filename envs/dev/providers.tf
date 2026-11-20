provider "aws" {
  region = var.region

  # One tag set on every resource: this is the cleanup and cost boundary.
  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
