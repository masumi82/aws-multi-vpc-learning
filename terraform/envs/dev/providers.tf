provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Environment = local.env
      Project     = "aws-sekei"
      ManagedBy   = "Terraform"
    }
  }
}
