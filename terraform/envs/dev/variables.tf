variable "region" {
  type    = string
  default = "ap-northeast-1"
}

variable "azs" {
  type    = list(string)
  default = ["ap-northeast-1a", "ap-northeast-1c", "ap-northeast-1d"]
}

variable "vpc_cidr" {
  type    = string
  default = "10.1.0.0/16"
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.1.0.0/24", "10.1.1.0/24", "10.1.2.0/24"]
}

variable "app_subnet_cidrs" {
  type    = list(string)
  default = ["10.1.10.0/24", "10.1.11.0/24", "10.1.12.0/24"]
}

variable "db_subnet_cidrs" {
  type    = list(string)
  default = ["10.1.20.0/24", "10.1.21.0/24", "10.1.22.0/24"]
}

variable "aurora_engine_version" {
  type        = string
  default     = "15.10"
  description = "Run `aws rds describe-db-engine-versions --engine aurora-postgresql` to verify before apply."
}

variable "aurora_database_name" {
  type    = string
  default = "appdb"
}

variable "aurora_instance_class" {
  type    = string
  default = "db.r5.large" # t-class not supported for Aurora Global DB
}

variable "aurora_reader_count" {
  type    = number
  default = 1
}

variable "ecs_desired_count" {
  type    = number
  default = 1
}

variable "ecs_cpu" {
  type    = number
  default = 256
}

variable "ecs_memory" {
  type    = number
  default = 512
}

# ---------- Tier 1 HA (env ごとに調整) ----------
variable "nat_gateway_per_az" {
  type        = bool
  default     = false # dev はコスト優先で 1a のみ
  description = "true で各 AZ に NAT GW (3 台) を配置 (Tier 1)"
}

variable "ecs_autoscaling_enabled" {
  type    = bool
  default = true
}

variable "ecs_min_capacity" {
  type    = number
  default = 1
}

variable "ecs_max_capacity" {
  type    = number
  default = 3
}

variable "alert_email" {
  type        = string
  default     = ""
  description = "アラート通知先メール (空なら subscription 未作成)"
}

# ---------- Tier 2 セキュリティ強化 (dev はコスト抑制で WAF/CMK は OFF) ----------
variable "enable_waf" {
  type        = bool
  default     = false # dev はコスト抑制
  description = "WAFv2 (CloudFront scope) を有効化"
}

variable "waf_rate_limit" {
  type    = number
  default = 2000
}

variable "enable_guardduty" {
  type    = bool
  default = true # GuardDuty は 30 日 free trial
}

variable "enable_flow_logs" {
  type    = bool
  default = true
}

variable "enable_kms_cmk" {
  type    = bool
  default = false # dev は AWS managed key で十分
}

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
