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

# WAFv2 for CloudFront は scope=CLOUDFRONT のため us-east-1 必須
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Environment = local.env
      Project     = "aws-sekei"
      ManagedBy   = "Terraform"
    }
  }
}
