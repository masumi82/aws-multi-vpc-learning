variable "env" {
  type = string
}

variable "replica_region" {
  type        = string
  default     = "ap-northeast-3"
  description = "Secondary region for the secret replica"
}

variable "enable_replica" {
  type        = bool
  default     = false
  description = "Whether to create a cross-region replica of the secret"
}
