variable "env" {
  type = string
}

variable "repo_name" {
  type        = string
  default     = "app"
  description = "Repository base name (will be prefixed with env)"
}

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
