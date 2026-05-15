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
  default = "db.r5.large" # t-class not supported for Aurora Global DB
}

variable "aurora_database_name" {
  type    = string
  default = "appdb"
}

variable "alert_email" {
  type    = string
  default = ""
}
