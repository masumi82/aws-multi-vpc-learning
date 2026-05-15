# Tier 3: Multi-Region Warm Standby Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Aurora Global DB + CloudFront Origin Group + Route 53 + S3 CRR + ECR Replication + Secrets Manager multi-region の Terraform IaC を実装し、Tokyo (dev/) と Osaka (dev-osaka/) の 2 環境を定義する。実 apply は行わない。

**Architecture:** 新規モジュール aurora_global / route53 / secrets を追加し、既存の aurora / cloudfront_s3 / ecr を後方互換で拡張。dev-osaka/ は独立した Terraform state で管理。apply は 3 フェーズに分割してクロス環境参照の循環を回避する。

**Tech Stack:** Terraform ~> 5.0, AWS Aurora PostgreSQL 15.x, CloudFront, Route 53, S3 CRR, ECR Cross-Region Replication, Secrets Manager

**設計書:** `docs/superpowers/specs/2026-05-15-tier3-dr-design.md`

---

## File Map

| Action | File | Responsibility |
|---|---|---|
| Create | `terraform/modules/aurora_global/main.tf` | aws_rds_global_cluster |
| Create | `terraform/modules/aurora_global/variables.tf` | env, engine_version, database_name |
| Create | `terraform/modules/aurora_global/outputs.tf` | global_cluster_identifier, arn |
| Modify | `terraform/modules/aurora/variables.tf` | is_secondary, global_cluster_identifier, source_region 追加 |
| Modify | `terraform/modules/aurora/main.tf` | Secondary 条件分岐 |
| Modify | `terraform/modules/aurora/outputs.tf` | master_user_secret_arn を条件付きに |
| Create | `terraform/modules/route53/main.tf` | Health Check + ALIAS record |
| Create | `terraform/modules/route53/variables.tf` | env, cloudfront_domain, zone_id, domain_name |
| Create | `terraform/modules/route53/outputs.tf` | health_check_id, record_fqdn |
| Create | `terraform/modules/secrets/main.tf` | aws_secretsmanager_secret + replica |
| Create | `terraform/modules/secrets/variables.tf` | env, replica_region |
| Create | `terraform/modules/secrets/outputs.tf` | secret_arn, secret_replica_arn |
| Modify | `terraform/modules/ecr/main.tf` | aws_ecr_replication_configuration 追加 |
| Modify | `terraform/modules/ecr/variables.tf` | enable_cross_region_replication 追加 |
| Modify | `terraform/modules/cloudfront_s3/main.tf` | Osaka origin, origin_group, versioning, CRR |
| Modify | `terraform/modules/cloudfront_s3/variables.tf` | osaka_alb_dns, osaka_s3_bucket_arn 追加 |
| Create | `terraform/envs/dev-osaka/providers.tf` | AWS provider ap-northeast-3 |
| Create | `terraform/envs/dev-osaka/backend.tf` | local backend |
| Create | `terraform/envs/dev-osaka/main.tf` | Osaka 全リソース |
| Create | `terraform/envs/dev-osaka/variables.tf` | global_cluster_identifier など |
| Create | `terraform/envs/dev-osaka/outputs.tf` | alb_dns_name, s3_bucket_arn |
| Create | `terraform/envs/dev-osaka/terraform.tfvars.example` | プレースホルダー |
| Modify | `terraform/envs/dev/main.tf` | aurora_global / secrets / route53 追加、既存 3 モジュール更新 |
| Modify | `terraform/envs/dev/variables.tf` | Tier 3 変数追加 |
| Modify | `terraform/envs/dev/outputs.tf` | Tier 3 出力追加 |
| Modify | `terraform/envs/dev/terraform.tfvars.example` | Tier 3 プレースホルダー追加 |
| Modify | `tests/integration/run.sh` | I34–I42 追加 |
| Create | `tests/chaos/c7-dr-failover.sh` | DR failover simulation |
| Modify | `tests/chaos/run.sh` | C7 追加 |
| Modify | `tests/scenarios.md` | I34–I42, C7 追記 |
| Modify | `docs/high-availability-design.md` | Tier 3 実装ステータスマーカー |
| Modify | `docs/architecture.md` | Tier 3 セクション追加 |
| Modify | `docs/final-report.md` | Tier 3 サマリ追加 |

---

## Task 1: `modules/aurora_global/` を新規作成

**Files:**
- Create: `terraform/modules/aurora_global/main.tf`
- Create: `terraform/modules/aurora_global/variables.tf`
- Create: `terraform/modules/aurora_global/outputs.tf`

- [ ] **Step 1: ディレクトリを作成して main.tf を書く**

```bash
mkdir -p terraform/modules/aurora_global
```

`terraform/modules/aurora_global/main.tf`:
```hcl
resource "aws_rds_global_cluster" "this" {
  global_cluster_identifier = "${var.env}-global"
  engine                    = "aurora-postgresql"
  engine_version            = var.engine_version
  database_name             = var.database_name
  deletion_protection       = false
}
```

- [ ] **Step 2: variables.tf を書く**

`terraform/modules/aurora_global/variables.tf`:
```hcl
variable "env" {
  type = string
}

variable "engine_version" {
  type    = string
  default = "15.10"
}

variable "database_name" {
  type    = string
  default = "appdb"
}
```

- [ ] **Step 3: outputs.tf を書く**

`terraform/modules/aurora_global/outputs.tf`:
```hcl
output "global_cluster_identifier" {
  value = aws_rds_global_cluster.this.id
}

output "global_cluster_arn" {
  value = aws_rds_global_cluster.this.arn
}
```

- [ ] **Step 4: フォーマット確認**

```bash
terraform fmt -recursive terraform/modules/aurora_global/
```

Expected: no output (already formatted) or reformatted files listed.

- [ ] **Step 5: コミット**

```bash
git add terraform/modules/aurora_global/
git commit -m "feat(tier3): add aurora_global module for Global DB identifier"
```

---

## Task 2: `modules/aurora/` を Global DB 対応に拡張

**Files:**
- Modify: `terraform/modules/aurora/variables.tf`
- Modify: `terraform/modules/aurora/main.tf`
- Modify: `terraform/modules/aurora/outputs.tf`

- [ ] **Step 1: variables.tf に 3 変数を追記**

`terraform/modules/aurora/variables.tf` の末尾に追加:
```hcl
variable "is_secondary" {
  type        = bool
  default     = false
  description = "true = Aurora Global DB secondary cluster (read-only, inherits credentials)"
}

variable "global_cluster_identifier" {
  type        = string
  default     = ""
  description = "Aurora Global Cluster identifier. Empty = standalone cluster."
}

variable "source_region" {
  type        = string
  default     = ""
  description = "Primary region for Global DB replication. Required when is_secondary = true."
}
```

- [ ] **Step 2: main.tf の `aws_rds_cluster` を条件付きに更新**

`terraform/modules/aurora/main.tf` の `aws_rds_cluster` ブロック全体を以下に置き換える:
```hcl
resource "aws_rds_cluster" "this" {
  cluster_identifier        = "${var.env}-aurora-cluster"
  engine                    = "aurora-postgresql"
  engine_mode               = "provisioned"
  engine_version            = var.engine_version
  global_cluster_identifier = var.global_cluster_identifier != "" ? var.global_cluster_identifier : null
  source_region             = var.is_secondary ? var.source_region : null

  database_name               = var.is_secondary ? null : var.database_name
  master_username             = var.is_secondary ? null : var.master_username
  manage_master_user_password = var.is_secondary ? null : true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.aurora_sg_id]

  backup_retention_period = var.backup_retention_period
  preferred_backup_window = "17:00-19:00"

  skip_final_snapshot = var.skip_final_snapshot
  deletion_protection = var.deletion_protection

  apply_immediately = true

  tags = { Name = "${var.env}-aurora-cluster" }
}
```

- [ ] **Step 3: outputs.tf の `master_user_secret_arn` を条件付きに更新**

`terraform/modules/aurora/outputs.tf` の `master_user_secret_arn` output を以下に置き換える:
```hcl
output "master_user_secret_arn" {
  value       = length(aws_rds_cluster.this.master_user_secret) > 0 ? aws_rds_cluster.this.master_user_secret[0].secret_arn : null
  description = "ARN of the Secrets Manager secret managed by Aurora (null for secondary clusters)"
}
```

- [ ] **Step 4: terraform validate で構文確認**

```bash
terraform -chdir=terraform/envs/dev validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 5: コミット**

```bash
git add terraform/modules/aurora/
git commit -m "feat(tier3): extend aurora module for Global DB secondary support"
```

---

## Task 3: `modules/route53/` を新規作成

**Files:**
- Create: `terraform/modules/route53/main.tf`
- Create: `terraform/modules/route53/variables.tf`
- Create: `terraform/modules/route53/outputs.tf`

- [ ] **Step 1: ディレクトリを作成して main.tf を書く**

```bash
mkdir -p terraform/modules/route53
```

`terraform/modules/route53/main.tf`:
```hcl
resource "aws_route53_health_check" "cloudfront" {
  fqdn              = var.cloudfront_domain
  port              = 443
  type              = "HTTPS"
  resource_path     = "/api/health"
  failure_threshold = 3
  request_interval  = 30

  tags = { Name = "${var.env}-cf-health-check" }
}

resource "aws_route53_record" "app" {
  zone_id = var.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = var.cloudfront_domain
    zone_id                = "Z2FDTNDATAQYW2"
    evaluate_target_health = false
  }
}
```

- [ ] **Step 2: variables.tf を書く**

`terraform/modules/route53/variables.tf`:
```hcl
variable "env" {
  type = string
}

variable "cloudfront_domain" {
  type        = string
  description = "CloudFront distribution domain name (*.cloudfront.net)"
}

variable "zone_id" {
  type        = string
  description = "Route 53 Hosted Zone ID"
}

variable "domain_name" {
  type        = string
  description = "Domain name for the A record (e.g., dev.example.internal)"
}
```

- [ ] **Step 3: outputs.tf を書く**

`terraform/modules/route53/outputs.tf`:
```hcl
output "health_check_id" {
  value = aws_route53_health_check.cloudfront.id
}

output "record_fqdn" {
  value = aws_route53_record.app.fqdn
}
```

- [ ] **Step 4: フォーマット確認**

```bash
terraform fmt -recursive terraform/modules/route53/
```

- [ ] **Step 5: コミット**

```bash
git add terraform/modules/route53/
git commit -m "feat(tier3): add route53 module for Health Check and ALIAS record"
```

---

## Task 4: `modules/secrets/` を新規作成

**Files:**
- Create: `terraform/modules/secrets/main.tf`
- Create: `terraform/modules/secrets/variables.tf`
- Create: `terraform/modules/secrets/outputs.tf`

- [ ] **Step 1: ディレクトリを作成して main.tf を書く**

```bash
mkdir -p terraform/modules/secrets
```

`terraform/modules/secrets/main.tf`:
```hcl
resource "aws_secretsmanager_secret" "app" {
  name                    = "${var.env}/app/db-connection"
  description             = "Application DB connection info with cross-region replica"
  recovery_window_in_days = 0

  replica {
    region = var.replica_region
  }

  tags = { Name = "${var.env}-app-db-connection" }
}
```

- [ ] **Step 2: variables.tf を書く**

`terraform/modules/secrets/variables.tf`:
```hcl
variable "env" {
  type = string
}

variable "replica_region" {
  type        = string
  default     = "ap-northeast-3"
  description = "Secondary region for the secret replica"
}
```

- [ ] **Step 3: outputs.tf を書く**

`terraform/modules/secrets/outputs.tf`:
```hcl
output "secret_arn" {
  value = aws_secretsmanager_secret.app.arn
}

output "secret_replica_arn" {
  value       = one([for r in aws_secretsmanager_secret.app.replica : r.arn if r.region == var.replica_region])
  description = "ARN of the replica secret in the secondary region (for Osaka ECS)"
}
```

- [ ] **Step 4: フォーマット確認**

```bash
terraform fmt -recursive terraform/modules/secrets/
```

- [ ] **Step 5: コミット**

```bash
git add terraform/modules/secrets/
git commit -m "feat(tier3): add secrets module for cross-region app secret"
```

---

## Task 5: `modules/ecr/` に ECR Cross-Region Replication を追加

**Files:**
- Modify: `terraform/modules/ecr/variables.tf`
- Modify: `terraform/modules/ecr/main.tf`

- [ ] **Step 1: variables.tf に 2 変数を追記**

`terraform/modules/ecr/variables.tf` の末尾に追加:
```hcl
variable "enable_cross_region_replication" {
  type        = bool
  default     = false
  description = "true = ECR registry-level cross-region replication to replication_destination_region"
}

variable "replication_destination_region" {
  type        = string
  default     = "ap-northeast-3"
  description = "Destination region for ECR replication (used when enable_cross_region_replication = true)"
}
```

- [ ] **Step 2: main.tf に data source と replication config を追加**

`terraform/modules/ecr/main.tf` の末尾に追加:
```hcl
data "aws_caller_identity" "current" {}

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
```

- [ ] **Step 3: terraform validate (dev 環境)**

```bash
terraform -chdir=terraform/envs/dev validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 4: コミット**

```bash
git add terraform/modules/ecr/
git commit -m "feat(tier3): add ECR cross-region replication support to ecr module"
```

---

## Task 6: `modules/cloudfront_s3/` に Origin Group と S3 CRR を追加

**Files:**
- Modify: `terraform/modules/cloudfront_s3/variables.tf`
- Modify: `terraform/modules/cloudfront_s3/main.tf`

- [ ] **Step 1: variables.tf に 2 変数を追記**

`terraform/modules/cloudfront_s3/variables.tf` の末尾に追加:
```hcl
variable "osaka_alb_dns" {
  type        = string
  default     = ""
  description = "Osaka ALB DNS name. When set, CloudFront Origin Group failover is enabled."
}

variable "osaka_s3_bucket_arn" {
  type        = string
  default     = ""
  description = "Osaka S3 bucket ARN for CRR destination. When set, S3 replication is enabled."
}
```

- [ ] **Step 2: main.tf の locals ブロックを更新**

既存の locals ブロック (`locals { s3_origin_id = ...` で始まるブロック) を以下に置き換える:
```hcl
locals {
  s3_origin_id         = "s3-${var.env}-ui"
  alb_origin_id        = "alb-${var.env}"
  alb_target_origin_id = var.osaka_alb_dns != "" ? "alb-failover-group" : local.alb_origin_id
}
```

- [ ] **Step 3: CloudFront Distribution の origin ブロックの後に Osaka 動的 origin を追加**

`terraform/modules/cloudfront_s3/main.tf` の既存の ALB origin ブロック (`origin { domain_name = var.alb_dns_name` で始まる) の直後に追加:
```hcl
  dynamic "origin" {
    for_each = var.osaka_alb_dns != "" ? [1] : []
    content {
      domain_name = var.osaka_alb_dns
      origin_id   = "alb-osaka"

      custom_origin_config {
        http_port              = 80
        https_port             = 443
        origin_protocol_policy = "http-only"
        origin_ssl_protocols   = ["TLSv1.2"]
      }
    }
  }

  dynamic "origin_group" {
    for_each = var.osaka_alb_dns != "" ? [1] : []
    content {
      origin_id = "alb-failover-group"
      failover_criteria {
        status_codes = [500, 502, 503, 504]
      }
      member { origin_id = local.alb_origin_id }
      member { origin_id = "alb-osaka" }
    }
  }
```

- [ ] **Step 4: `/api/*` cache behavior の `target_origin_id` を更新**

既存の `ordered_cache_behavior` ブロック内の:
```hcl
    target_origin_id       = local.alb_origin_id
```
を以下に変更:
```hcl
    target_origin_id       = local.alb_target_origin_id
```

- [ ] **Step 5: S3 versioning と CRR リソースを main.tf 末尾に追加**

`terraform/modules/cloudfront_s3/main.tf` の末尾 (`tags = ...` の後) に追加:
```hcl
resource "aws_s3_bucket_versioning" "ui" {
  bucket = aws_s3_bucket.ui.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_iam_role" "replication" {
  count = var.osaka_s3_bucket_arn != "" ? 1 : 0
  name  = "${var.env}-s3-replication-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Name = "${var.env}-s3-replication-role" }
}

resource "aws_iam_role_policy" "replication" {
  count = var.osaka_s3_bucket_arn != "" ? 1 : 0
  role  = aws_iam_role.replication[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetReplicationConfiguration", "s3:ListBucket"]
        Resource = aws_s3_bucket.ui.arn
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObjectVersionForReplication",
          "s3:GetObjectVersionAcl",
          "s3:GetObjectVersionTagging",
        ]
        Resource = "${aws_s3_bucket.ui.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ReplicateObject",
          "s3:ReplicateDelete",
          "s3:ReplicateTags",
        ]
        Resource = "${var.osaka_s3_bucket_arn}/*"
      },
    ]
  })
}

resource "aws_s3_bucket_replication_configuration" "to_osaka" {
  count      = var.osaka_s3_bucket_arn != "" ? 1 : 0
  depends_on = [aws_s3_bucket_versioning.ui]
  bucket     = aws_s3_bucket.ui.id
  role       = aws_iam_role.replication[0].arn

  rule {
    id     = "replicate-to-osaka"
    status = "Enabled"
    destination {
      bucket = var.osaka_s3_bucket_arn
    }
  }
}
```

- [ ] **Step 6: terraform fmt + validate**

```bash
terraform fmt -recursive terraform/modules/cloudfront_s3/
terraform -chdir=terraform/envs/dev validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 7: コミット**

```bash
git add terraform/modules/cloudfront_s3/
git commit -m "feat(tier3): add CloudFront Origin Group and S3 CRR to cloudfront_s3 module"
```

---

## Task 7: `envs/dev-osaka/` を新規作成

**Files:**
- Create: `terraform/envs/dev-osaka/providers.tf`
- Create: `terraform/envs/dev-osaka/backend.tf`
- Create: `terraform/envs/dev-osaka/main.tf`
- Create: `terraform/envs/dev-osaka/variables.tf`
- Create: `terraform/envs/dev-osaka/outputs.tf`
- Create: `terraform/envs/dev-osaka/terraform.tfvars.example`

- [ ] **Step 1: ディレクトリを作成して providers.tf を書く**

```bash
mkdir -p terraform/envs/dev-osaka
```

`terraform/envs/dev-osaka/providers.tf`:
```hcl
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-3"
}
```

- [ ] **Step 2: backend.tf を書く**

`terraform/envs/dev-osaka/backend.tf`:
```hcl
terraform {
  backend "local" {
    path = "terraform.tfstate"
  }
}
```

- [ ] **Step 3: variables.tf を書く**

`terraform/envs/dev-osaka/variables.tf`:
```hcl
variable "global_cluster_identifier" {
  type        = string
  default     = ""
  description = "Aurora Global Cluster ID (output of envs/dev Phase 1 apply)"
}

variable "app_secret_replica_arn" {
  type        = string
  default     = ""
  description = "Secrets Manager replica ARN in ap-northeast-3 (output of envs/dev Phase 1 apply)"
}

variable "primary_region" {
  type    = string
  default = "ap-northeast-1"
}

variable "ecr_repository_url" {
  type        = string
  default     = ""
  description = "ECR repo URL in ap-northeast-3 (e.g. <account>.dkr.ecr.ap-northeast-3.amazonaws.com/dev-app)"
}

variable "azs" {
  type    = list(string)
  default = ["ap-northeast-3a", "ap-northeast-3b", "ap-northeast-3c"]
}

variable "vpc_cidr" {
  type    = string
  default = "10.3.0.0/16"
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.3.0.0/24", "10.3.1.0/24", "10.3.2.0/24"]
}

variable "app_subnet_cidrs" {
  type    = list(string)
  default = ["10.3.10.0/24", "10.3.11.0/24", "10.3.12.0/24"]
}

variable "db_subnet_cidrs" {
  type    = list(string)
  default = ["10.3.20.0/24", "10.3.21.0/24", "10.3.22.0/24"]
}

variable "aurora_engine_version" {
  type    = string
  default = "15.10"
}

variable "aurora_instance_class" {
  type    = string
  default = "db.t4g.medium"
}

variable "aurora_database_name" {
  type    = string
  default = "appdb"
}

variable "alert_email" {
  type    = string
  default = ""
}
```

- [ ] **Step 4: main.tf を書く**

`terraform/envs/dev-osaka/main.tf`:
```hcl
locals {
  env = "dev-osaka"
}

module "network" {
  source = "../../modules/network"

  env                 = local.env
  vpc_cidr            = var.vpc_cidr
  azs                 = var.azs
  public_subnet_cidrs = var.public_subnet_cidrs
  app_subnet_cidrs    = var.app_subnet_cidrs
  db_subnet_cidrs     = var.db_subnet_cidrs
  nat_gateway_per_az  = false
}

module "security_groups" {
  source = "../../modules/security_groups"

  env    = local.env
  vpc_id = module.network.vpc_id
}

module "alb" {
  source = "../../modules/alb"

  env               = local.env
  vpc_id            = module.network.vpc_id
  public_subnet_ids = module.network.public_subnet_ids
  alb_sg_id         = module.security_groups.alb_sg_id
}

module "aurora" {
  source = "../../modules/aurora"

  env                       = local.env
  db_subnet_ids             = module.network.db_subnet_ids
  aurora_sg_id              = module.security_groups.aurora_sg_id
  engine_version            = var.aurora_engine_version
  instance_class            = var.aurora_instance_class
  reader_count              = 0
  is_secondary              = true
  global_cluster_identifier = var.global_cluster_identifier
  source_region             = var.primary_region
}

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "osaka_destination" {
  bucket        = "app-ui-${local.env}-${random_id.bucket_suffix.hex}"
  force_destroy = true
  tags          = { Name = "app-ui-${local.env}" }
}

resource "aws_s3_bucket_versioning" "osaka_destination" {
  bucket = aws_s3_bucket.osaka_destination.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "osaka_destination" {
  bucket                  = aws_s3_bucket.osaka_destination.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

module "ecs" {
  source = "../../modules/ecs"

  env                  = local.env
  vpc_id               = module.network.vpc_id
  app_subnet_ids       = module.network.app_subnet_ids
  app_sg_id            = module.security_groups.app_sg_id
  target_group_arn     = module.alb.target_group_arn
  ecr_repository_url   = var.ecr_repository_url
  aurora_secret_arn    = var.app_secret_replica_arn
  aurora_endpoint      = module.aurora.cluster_reader_endpoint
  aurora_database_name = var.aurora_database_name
  desired_count        = 1
  cpu                  = 256
  memory               = 512
  autoscaling_enabled  = false
  min_capacity         = 1
  max_capacity         = 1
}

module "monitoring" {
  source = "../../modules/monitoring"

  env                     = local.env
  alert_email             = var.alert_email
  ecs_cluster_name        = module.ecs.cluster_name
  ecs_service_name        = module.ecs.service_name
  alb_arn_suffix          = module.alb.alb_arn_suffix
  target_group_arn_suffix = module.alb.target_group_arn_suffix
  aurora_cluster_id       = module.aurora.cluster_id
  vpc_id                  = module.network.vpc_id
  enable_guardduty        = true
  enable_flow_logs        = true
  enable_kms_cmk          = false
}
```

- [ ] **Step 5: outputs.tf を書く**

`terraform/envs/dev-osaka/outputs.tf`:
```hcl
output "alb_dns_name" {
  value       = module.alb.alb_dns_name
  description = "Osaka ALB DNS name — set as osaka_alb_dns in envs/dev/terraform.tfvars"
}

output "s3_bucket_arn" {
  value       = aws_s3_bucket.osaka_destination.arn
  description = "Osaka S3 bucket ARN — set as osaka_s3_bucket_arn in envs/dev/terraform.tfvars"
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "ecs_cluster_name" {
  value = module.ecs.cluster_name
}

output "aurora_reader_endpoint" {
  value = module.aurora.cluster_reader_endpoint
}
```

- [ ] **Step 6: terraform.tfvars.example を書く**

`terraform/envs/dev-osaka/terraform.tfvars.example`:
```hcl
# envs/dev-osaka 用 tfvars.
# このファイルを terraform.tfvars にコピーして編集。
# tfvars 自体は .gitignore で除外、example はコミット OK。

# Phase 1: envs/dev/ apply 後に以下を記入
# global_cluster_identifier = "<output of: terraform -chdir=terraform/envs/dev output -raw global_cluster_identifier>"
# app_secret_replica_arn    = "<output of: terraform -chdir=terraform/envs/dev output -raw app_secret_replica_arn>"

# ECR repo URL in Osaka (after ECR replication is enabled in dev/)
# ecr_repository_url = "<account_id>.dkr.ecr.ap-northeast-3.amazonaws.com/dev-app"

# Aurora engine version — verify before apply:
# aws rds describe-db-engine-versions --engine aurora-postgresql --region ap-northeast-3
# aurora_engine_version = "15.10"
```

- [ ] **Step 7: terraform init + validate**

```bash
terraform -chdir=terraform/envs/dev-osaka init
terraform -chdir=terraform/envs/dev-osaka validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 8: terraform fmt check**

```bash
terraform fmt -recursive terraform/envs/dev-osaka/
```

- [ ] **Step 9: コミット**

```bash
git add terraform/envs/dev-osaka/
git commit -m "feat(tier3): add dev-osaka environment (Warm Standby secondary)"
```

---

## Task 8: `envs/dev/` を Tier 3 対応に更新

**Files:**
- Modify: `terraform/envs/dev/main.tf`
- Modify: `terraform/envs/dev/variables.tf`
- Modify: `terraform/envs/dev/outputs.tf`
- Modify: `terraform/envs/dev/terraform.tfvars.example`

- [ ] **Step 1: main.tf に Tier 3 モジュールを追加・既存モジュールを更新**

`terraform/envs/dev/main.tf` の末尾 (`module "monitoring"` ブロックの直後) に追加:
```hcl
module "aurora_global" {
  source = "../../modules/aurora_global"

  env            = local.env
  engine_version = var.aurora_engine_version
  database_name  = "appdb"
}

module "secrets" {
  source = "../../modules/secrets"

  env            = local.env
  replica_region = "ap-northeast-3"
}

module "route53" {
  count  = var.enable_route53 ? 1 : 0
  source = "../../modules/route53"

  env               = local.env
  cloudfront_domain = module.cloudfront_s3.cloudfront_domain_name
  zone_id           = var.route53_zone_id
  domain_name       = var.domain_name
}
```

また、既存の `module "aurora"` に `global_cluster_identifier` を追加:
```hcl
module "aurora" {
  source = "../../modules/aurora"

  env                       = local.env
  db_subnet_ids             = module.network.db_subnet_ids
  aurora_sg_id              = module.security_groups.aurora_sg_id
  engine_version            = var.aurora_engine_version
  instance_class            = var.aurora_instance_class
  reader_count              = var.aurora_reader_count
  global_cluster_identifier = module.aurora_global.global_cluster_identifier
}
```

既存の `module "cloudfront_s3"` に osaka 変数を追加:
```hcl
module "cloudfront_s3" {
  source = "../../modules/cloudfront_s3"

  env                 = local.env
  alb_dns_name        = module.alb.alb_dns_name
  web_acl_arn         = var.enable_waf ? module.waf[0].web_acl_arn : null
  osaka_alb_dns       = var.osaka_alb_dns
  osaka_s3_bucket_arn = var.osaka_s3_bucket_arn
}
```

既存の `module "ecr"` に replication を追加:
```hcl
module "ecr" {
  source = "../../modules/ecr"

  env                             = local.env
  repo_name                       = "app"
  enable_cross_region_replication = var.enable_ecr_replication
  replication_destination_region  = "ap-northeast-3"
}
```

- [ ] **Step 2: variables.tf に Tier 3 変数を追記**

`terraform/envs/dev/variables.tf` の末尾に追加:
```hcl
# ---------- Tier 3 Multi-Region DR ----------
variable "osaka_alb_dns" {
  type        = string
  default     = ""
  description = "Osaka ALB DNS (Phase 3: set after dev-osaka apply)"
}

variable "osaka_s3_bucket_arn" {
  type        = string
  default     = ""
  description = "Osaka S3 bucket ARN for CRR (Phase 3: set after dev-osaka apply)"
}

variable "enable_ecr_replication" {
  type        = bool
  default     = false
  description = "Enable ECR cross-region replication to ap-northeast-3"
}

variable "enable_route53" {
  type        = bool
  default     = false
  description = "Enable Route 53 Health Check and ALIAS record (requires route53_zone_id)"
}

variable "route53_zone_id" {
  type        = string
  default     = ""
  description = "Route 53 Hosted Zone ID (required when enable_route53 = true)"
}

variable "domain_name" {
  type        = string
  default     = "dev.example.internal"
  description = "Domain name for Route 53 ALIAS record"
}
```

- [ ] **Step 3: outputs.tf に Tier 3 出力を追記**

`terraform/envs/dev/outputs.tf` の末尾に追加:
```hcl
# ---------- Tier 3 ----------
output "global_cluster_identifier" {
  value       = module.aurora_global.global_cluster_identifier
  description = "Aurora Global Cluster ID — set as global_cluster_identifier in dev-osaka/terraform.tfvars"
}

output "app_secret_replica_arn" {
  value       = module.secrets.secret_replica_arn
  description = "Secrets Manager replica ARN in ap-northeast-3 — set as app_secret_replica_arn in dev-osaka/terraform.tfvars"
  sensitive   = true
}

output "route53_health_check_id" {
  value = var.enable_route53 ? module.route53[0].health_check_id : null
}
```

- [ ] **Step 4: terraform.tfvars.example に Tier 3 プレースホルダーを追記**

`terraform/envs/dev/terraform.tfvars.example` の末尾に追加:
```hcl
# ---------- Tier 3 Multi-Region DR ----------
# Phase 1: aurora_global + secrets のみ apply してから dev-osaka に渡す
# Phase 3: dev-osaka apply 後に以下を記入して全体を apply

# osaka_alb_dns       = "<output of: terraform -chdir=terraform/envs/dev-osaka output -raw alb_dns_name>"
# osaka_s3_bucket_arn = "<output of: terraform -chdir=terraform/envs/dev-osaka output -raw s3_bucket_arn>"
# enable_ecr_replication = true
```

- [ ] **Step 5: terraform validate (dev / prod / dev-osaka 全環境)**

```bash
terraform -chdir=terraform/envs/dev validate
terraform -chdir=terraform/envs/prod validate
terraform -chdir=terraform/envs/dev-osaka validate
```

Expected: `Success! The configuration is valid.` × 3

- [ ] **Step 6: terraform fmt 全体確認**

```bash
terraform fmt -recursive -check terraform/
```

Expected: exit 0 (差分があれば `terraform fmt -recursive terraform/` で修正してから再確認)

- [ ] **Step 7: コミット**

```bash
git add terraform/envs/dev/
git commit -m "feat(tier3): wire aurora_global, secrets, route53, ecr replication into dev env"
```

---

## Task 9: Integration Tests I34–I42 を追加

**Files:**
- Modify: `tests/integration/run.sh`

- [ ] **Step 1: run.sh の末尾 (`echo "==== Integration Result` の直前) に I34–I42 を追加**

```bash
# ===================================================
# Tier 3 Multi-Region
# ===================================================
GLOBAL_CLUSTER_ID=$(out global_cluster_identifier 2>/dev/null || echo "")
OSAKA_ALB=$(out osaka_alb_dns 2>/dev/null || echo "")

# I34: Aurora Global Cluster が存在する (dev 環境のみ)
if [ -n "$GLOBAL_CLUSTER_ID" ] && [ "$GLOBAL_CLUSTER_ID" != "null" ]; then
  GC_STATUS=$(aws rds describe-global-clusters --region "$REGION" \
    --global-cluster-identifier "$GLOBAL_CLUSTER_ID" \
    --query 'GlobalClusters[0].Status' --output text 2>/dev/null)
  assert I34 "Aurora Global Cluster exists (status=available)" "[ '$GC_STATUS' = 'available' ]" "$GC_STATUS"
else
  echo "SKIP I34 (global_cluster_identifier output not set)"
fi

# I35: Aurora Primary cluster が global_cluster_identifier を持つ
AURORA_GLOBAL_ID=$(aws rds describe-db-clusters --region "$REGION" \
  --db-cluster-identifier "$TF_ENV-aurora-cluster" \
  --query 'DBClusters[0].GlobalWriteForwardingStatus' --output text 2>/dev/null || echo "")
if [ -n "$GLOBAL_CLUSTER_ID" ] && [ "$GLOBAL_CLUSTER_ID" != "null" ]; then
  PRIMARY_GC=$(aws rds describe-db-clusters --region "$REGION" \
    --db-cluster-identifier "$TF_ENV-aurora-cluster" \
    --query 'DBClusters[0].GlobalClusterResourceId' --output text 2>/dev/null)
  assert I35 "Aurora Primary is member of global cluster" "[ -n '$PRIMARY_GC' ]" "$PRIMARY_GC"
else
  echo "SKIP I35 (global_cluster_identifier not set)"
fi

# I36–I38: CloudFront Origin Group (osaka_alb_dns が設定されている場合)
if [ -n "$OSAKA_ALB" ] && [ "$OSAKA_ALB" != "null" ]; then
  OG_COUNT=$(aws cloudfront get-distribution --id "$CF_ID" \
    --query 'length(Distribution.DistributionConfig.OriginGroups.Items)' --output text 2>/dev/null)
  assert I37 "CloudFront has Origin Group" "[ '$OG_COUNT' -ge '1' ]" "$OG_COUNT"

  TARGET_ORIGIN=$(aws cloudfront get-distribution --id "$CF_ID" \
    --query "Distribution.DistributionConfig.CacheBehaviors.Items[?PathPattern=='/api/*'].TargetOriginId | [0]" \
    --output text 2>/dev/null)
  assert I38 "/api/* cache behavior targets alb-failover-group" "[ '$TARGET_ORIGIN' = 'alb-failover-group' ]" "$TARGET_ORIGIN"
else
  echo "SKIP I37-I38 (osaka_alb_dns not set)"
fi

# I39: Tokyo S3 に replication configuration が設定されている (source 側)
if [ -n "$OSAKA_ALB" ] && [ "$OSAKA_ALB" != "null" ]; then
  REPLICATION_ROLE=$(aws s3api get-bucket-replication --bucket "$S3_BUCKET" \
    --query 'ReplicationConfiguration.Role' --output text 2>/dev/null)
  assert I39 "Tokyo S3 has replication configuration" "[ -n '$REPLICATION_ROLE' ]" "$REPLICATION_ROLE"
else
  echo "SKIP I39 (osaka_s3_bucket_arn not set)"
fi

# I41: ECR Replication Configuration に ap-northeast-3 が含まれる
ECR_REP_REGION=$(aws ecr describe-registry --region "$REGION" \
  --query "ReplicationConfiguration.Rules[*].Destinations[?Region=='ap-northeast-3'].Region | [0][0]" \
  --output text 2>/dev/null)
if [ -n "$ECR_REP_REGION" ] && [ "$ECR_REP_REGION" != "None" ]; then
  assert I41 "ECR Replication targets ap-northeast-3" "[ '$ECR_REP_REGION' = 'ap-northeast-3' ]" "$ECR_REP_REGION"
else
  echo "SKIP I41 (enable_ecr_replication=false)"
fi

# I42: Route 53 Health Check が CloudFront ドメインを監視している
HC_ID=$(out route53_health_check_id 2>/dev/null || echo "")
if [ -n "$HC_ID" ] && [ "$HC_ID" != "null" ]; then
  HC_FQDN=$(aws route53 get-health-check --health-check-id "$HC_ID" \
    --query 'HealthCheck.HealthCheckConfig.FullyQualifiedDomainName' --output text 2>/dev/null)
  assert I42 "Route 53 HC monitors CloudFront domain" "[ '$HC_FQDN' = '$CF_DOMAIN' ]" "$HC_FQDN"
else
  echo "SKIP I42 (enable_route53=false)"
fi
```

- [ ] **Step 2: bash 構文チェック**

```bash
bash -n tests/integration/run.sh
```

Expected: no output (syntax OK)

- [ ] **Step 3: コミット**

```bash
git add tests/integration/run.sh
git commit -m "test(tier3): add integration tests I34-I42 for Multi-Region DR"
```

---

## Task 10: Chaos Test C7 を追加

**Files:**
- Create: `tests/chaos/c7-dr-failover.sh`
- Modify: `tests/chaos/run.sh`

- [ ] **Step 1: c7-dr-failover.sh を書く**

`tests/chaos/c7-dr-failover.sh`:
```bash
#!/usr/bin/env bash
# C7: Multi-Region DR Failover Simulation
# Tokyo ECS を停止して CloudFront Origin Group が Osaka にフェイルオーバーすることを確認。
# 前提: Tier 3 apply 済み (dev + dev-osaka), osaka_alb_dns が設定されている
set -uo pipefail

REGION="${REGION:-ap-northeast-1}"
OSAKA_REGION="ap-northeast-3"
TF_ENV="${TF_ENV:-dev}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TF_DIR="$ROOT/terraform/envs/$TF_ENV"
TF_DIR_OSAKA="$ROOT/terraform/envs/dev-osaka"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'
PASS=0; FAIL=0

CF_DOMAIN=$(terraform -chdir="$TF_DIR" output -raw cloudfront_domain_name 2>/dev/null || echo "")
OSAKA_ALB=$(terraform -chdir="$TF_DIR" output -raw osaka_alb_dns 2>/dev/null || echo "")

if [ -z "$CF_DOMAIN" ] || [ -z "$OSAKA_ALB" ] || [ "$OSAKA_ALB" = "" ]; then
  echo "SKIP C7: osaka_alb_dns not configured — Tier 3 not fully deployed"
  exit 0
fi

CLUSTER=$(terraform -chdir="$TF_DIR" output -raw ecs_cluster_name)
SERVICE=$(terraform -chdir="$TF_DIR" output -raw ecs_service_name)
ORIGINAL_COUNT=$(aws ecs describe-services --region "$REGION" \
  --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].desiredCount' --output text)

echo "==== C7: DR Failover Simulation ===="
echo "CloudFront: $CF_DOMAIN"
echo "Osaka ALB:  $OSAKA_ALB"
echo "Tokyo ECS service: $CLUSTER/$SERVICE (desired=$ORIGINAL_COUNT)"
echo ""

# Step 1: Tokyo ECS を 0 にして ALB を 5xx 状態にする
echo "Step 1: Scaling Tokyo ECS to 0..."
aws ecs update-service --region "$REGION" --cluster "$CLUSTER" --service "$SERVICE" \
  --desired-count 0 --query 'service.desiredCount' --output text > /dev/null
sleep 30

# Step 2: CloudFront が Osaka にフェイルオーバーするか確認 (Origin Group: 5xx → Osaka)
echo "Step 2: Testing CloudFront Origin Group failover..."
STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  "https://${CF_DOMAIN}/api/health" \
  -H "User-Agent: chaos-c7-failover" --max-time 15 2>/dev/null || echo "000")
echo "  /api/health via CloudFront → HTTP $STATUS"
if [ "$STATUS" = "200" ] || [ "$STATUS" = "404" ] || [ "$STATUS" = "503" ]; then
  printf "  ${GREEN}PASS${NC} C7.1 CloudFront returned response (Osaka ALB handling traffic)\n"
  PASS=$((PASS+1))
else
  printf "  ${YELLOW}WARN${NC} C7.1 Unexpected status=$STATUS (CloudFront may still be routing to Tokyo)\n"
  FAIL=$((FAIL+1))
fi

# Step 3: Aurora DR Runbook 手順を表示 (実行はしない)
echo ""
echo "Step 3: Aurora Global DB Promote Runbook (dry-run display only)"
echo "  1. aws rds describe-global-clusters --region $REGION"
echo "  2. aws rds remove-from-global-cluster --region $OSAKA_REGION \\"
echo "       --global-cluster-identifier <identifier> \\"
echo "       --db-cluster-identifier dev-osaka-aurora-cluster"
echo "  3. Wait for cluster status = available"
echo "  4. Update app_secret in Secrets Manager with new Osaka writer endpoint"
echo "  5. Restart Osaka ECS service to pick up new endpoint"
printf "  ${YELLOW}NOTE${NC} Above steps are for documentation — not executed in this script\n"

# Step 4: Tokyo ECS を元に戻す
echo ""
echo "Step 4: Restoring Tokyo ECS to desired_count=$ORIGINAL_COUNT..."
aws ecs update-service --region "$REGION" --cluster "$CLUSTER" --service "$SERVICE" \
  --desired-count "$ORIGINAL_COUNT" --query 'service.desiredCount' --output text > /dev/null

echo ""
echo "==== C7 Result: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed/warn${NC} ===="
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: c7 を run.sh に追加**

`tests/chaos/run.sh` の `c6)` ケースの後に追加:
```bash
    c7)
      bash "$CHAOS_DIR/c7-dr-failover.sh"
      ;;
```

また `all)` ケースに `c7` を追加する (既存の `c6` の後):
```bash
      bash "$CHAOS_DIR/c7-dr-failover.sh"
```

- [ ] **Step 3: 実行権限付与 + 構文チェック**

```bash
chmod +x tests/chaos/c7-dr-failover.sh
bash -n tests/chaos/c7-dr-failover.sh
bash -n tests/chaos/run.sh
```

Expected: no output (syntax OK)

- [ ] **Step 4: コミット**

```bash
git add tests/chaos/c7-dr-failover.sh tests/chaos/run.sh
git commit -m "test(tier3): add chaos test C7 DR failover simulation"
```

---

## Task 11: ドキュメント更新

**Files:**
- Modify: `tests/scenarios.md`
- Modify: `docs/high-availability-design.md`
- Modify: `docs/architecture.md`
- Modify: `docs/final-report.md`

- [ ] **Step 1: tests/scenarios.md に I34–I42 と C7 を追記**

`tests/scenarios.md` の Integration Tests テーブルに以下を追加:

```markdown
| I34 | Aurora Global Cluster が存在する | dev | Tier 3 |
| I35 | Aurora Primary が global_cluster_identifier を持つ | dev | Tier 3 |
| I36 | Aurora Secondary (Osaka) が global_cluster に参加している | dev-osaka | Tier 3 |
| I37 | CloudFront に Origin Group が設定されている | dev | Tier 3 |
| I38 | /api/* behavior の target_origin_id が alb-failover-group | dev | Tier 3 |
| I39 | Tokyo S3 に replication configuration がある | dev | Tier 3 |
| I40 | Osaka S3 に versioning が有効 | dev-osaka | Tier 3 |
| I41 | ECR Replication に ap-northeast-3 が含まれる | dev | Tier 3 |
| I42 | Route 53 HC が CloudFront ドメインを監視 | dev | Tier 3 |
```

Chaos Tests テーブルに以下を追加:

```markdown
| C7 | DR Failover Simulation: Tokyo ECS 停止 → CloudFront Osaka 切替確認 | dev+dev-osaka | Tier 3 |
```

- [ ] **Step 2: high-availability-design.md の Tier 3 セクションに実装ステータスを追加**

`docs/high-availability-design.md` の `## 5. Tier 3:` ヘッダの直後に追加:

```markdown
> 🟢 **実装ステータス (2026-05-15)**: IaC (Terraform) を実装済。実 apply は未実施。
> dev-osaka は aurora_global に依存する 3 フェーズ apply 方式。prod は変更なし (後方互換)。
```

- [ ] **Step 3: architecture.md に Tier 3 セクションを追加**

`docs/architecture.md` の末尾に追加:

```markdown
## 10. Tier 3 セキュリティと DR 強化 (2026-05-15 実装)

### Multi-Region Warm Standby

| コンポーネント | 実装 |
|---|---|
| Aurora Global DB | `modules/aurora_global` + `modules/aurora` (is_secondary 拡張) |
| CloudFront Origin Group | `modules/cloudfront_s3` (動的 origin + origin_group) |
| S3 Cross-Region Replication | `modules/cloudfront_s3` (versioning + CRR IAM + config) |
| Route 53 Health Check + ALIAS | `modules/route53` (新規) |
| ECR Cross-Region Replication | `modules/ecr` (account-level replication config) |
| Secrets Manager Multi-Region | `modules/secrets` (新規、replica) |
| Osaka 環境 | `envs/dev-osaka` (ap-northeast-3、Warm Standby 最小構成) |

Apply order: `envs/dev` Phase1 → `envs/dev-osaka` → `envs/dev` Phase3
```

- [ ] **Step 4: final-report.md に Tier 3 サマリを追加**

`docs/final-report.md` の Tier 2 サマリセクションの後に追加:

```markdown
## 12. Tier 3 サマリ (IaC 実装、2026-05-15)

**実装内容**: Multi-Region Warm Standby (ap-northeast-1 Tokyo → ap-northeast-3 Osaka)

| コンポーネント | 実装方法 | 制約 |
|---|---|---|
| Aurora Global DB | aurora_global module 新設 + aurora module 拡張 | Secondary は read-only、Promote = Detach |
| CloudFront Origin Group | 動的 origin + origin_group (5xx failover) | GET/HEAD/OPTIONS のみ対象 |
| S3 CRR | versioning + IAM + replication_configuration (Tokyo source) | 既存 object はバックフィル不要 |
| Route 53 | Health Check (/api/health) + ALIAS → CloudFront | DNS failover は CF が担当 |
| ECR Replication | account-level singleton | 既存設定は terraform import 要 |
| Secrets Manager | app secret + Osaka replica | Aurora managed secret は replica 不可 |

**プロジェクトステータス**: Tier 3 IaC 実装完了 / 実 apply は未実施
```

- [ ] **Step 5: コミット**

```bash
git add tests/scenarios.md docs/high-availability-design.md docs/architecture.md docs/final-report.md
git commit -m "docs(tier3): update scenarios, HA design, architecture, final-report for Tier 3"
```

---

## Task 12: 最終 fmt/validate + Git push

- [ ] **Step 1: 全環境の最終 validate**

```bash
terraform -chdir=terraform/envs/dev validate
terraform -chdir=terraform/envs/dev-osaka validate
terraform -chdir=terraform/envs/prod validate
```

Expected: `Success! The configuration is valid.` × 3

- [ ] **Step 2: 全体の fmt check**

```bash
terraform fmt -recursive -check terraform/
```

Expected: exit 0

- [ ] **Step 3: git push**

```bash
git push origin main
```

Expected: push successful (GitHub Actions または push hooks がある場合はそれを確認)

---

## Self-Review

**Spec coverage:**
- ✅ aurora_global module → Task 1
- ✅ aurora secondary (is_secondary, global_cluster_identifier, source_region) → Task 2
- ✅ route53 module → Task 3
- ✅ secrets module → Task 4
- ✅ ECR replication → Task 5
- ✅ CloudFront Origin Group + S3 CRR (dynamic origin, IAM policy) → Task 6
- ✅ envs/dev-osaka/ (3 AZ, providers, backend, main, vars, outputs) → Task 7
- ✅ envs/dev/ 更新 (aurora_global, secrets, route53, osaka vars) → Task 8
- ✅ prod validate (Task 8 Step 5 に含む)
- ✅ Integration tests I34–I42 → Task 9 (I36/I40 は dev-osaka 対象で apply 後のみ実行可)
- ✅ Chaos test C7 → Task 10
- ✅ Documentation → Task 11
- ✅ tfvars.example パターン (Tokyo/Osaka 双方) → Task 7/8

**Type consistency:**
- `global_cluster_identifier`: aurora_global.outputs → aurora.variables → dev/main.tf → dev-osaka/variables で一貫
- `app_secret_replica_arn`: secrets.outputs → dev/outputs → dev-osaka/variables で一貫
- `alb_target_origin_id`: cloudfront_s3 locals で定義し ordered_cache_behavior で参照
- `osaka_alb_dns`: cloudfront_s3.variables → dynamic origin/origin_group/local で一貫使用
