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
  default = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.0.0/24", "10.0.1.0/24", "10.0.2.0/24"]
}

variable "app_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.10.0/24", "10.0.11.0/24", "10.0.12.0/24"]
}

variable "db_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.20.0/24", "10.0.21.0/24", "10.0.22.0/24"]
}

variable "aurora_engine_version" {
  type        = string
  default     = "15.10"
  description = "Run `aws rds describe-db-engine-versions --engine aurora-postgresql` to verify before apply."
}

variable "aurora_instance_class" {
  type    = string
  default = "db.t4g.medium"
}

variable "aurora_reader_count" {
  type    = number
  default = 3 # Tier 1: 各 AZ に 1 台ずつ
}

variable "ecs_desired_count" {
  type    = number
  default = 3 # Tier 1: 各 AZ に 1 task ずつ
}

variable "ecs_cpu" {
  type    = number
  default = 256
}

variable "ecs_memory" {
  type    = number
  default = 512
}

# ---------- Tier 1 HA (prod は full HA) ----------
variable "nat_gateway_per_az" {
  type        = bool
  default     = true # prod は SPOF 排除のため 3 NAT
  description = "true で各 AZ に NAT GW (3 台) を配置 (Tier 1)"
}

variable "ecs_autoscaling_enabled" {
  type    = bool
  default = true
}

variable "ecs_min_capacity" {
  type    = number
  default = 3 # 各 AZ 1 task 維持
}

variable "ecs_max_capacity" {
  type    = number
  default = 10
}

variable "alert_email" {
  type        = string
  default     = ""
  description = "アラート通知先メール"
}
