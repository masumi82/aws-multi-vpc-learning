resource "aws_ecr_repository" "this" {
  name                 = "${var.env}-${var.repo_name}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # 学習用: untagged image が残っていても destroy 可

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = { Name = "${var.env}-${var.repo_name}" }
}

resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images older than 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      }
    ]
  })
}

data "aws_caller_identity" "current" {}

# IMPORTANT: aws_ecr_replication_configuration is an account-level singleton.
# Setting this in dev/ will affect ALL ECR repositories in the account.
# If using this in multiple environments, only enable in one (e.g., dev/).
# See: https://docs.aws.amazon.com/AmazonECR/latest/userguide/replication.html
resource "aws_ecr_replication_configuration" "this" {
  count = var.enable_cross_region_replication ? 1 : 0

  replication_configuration {
    rule {
      destination {
        region      = var.replication_destination_region
        registry_id = data.aws_caller_identity.current.account_id
      }
    }
  }
}
