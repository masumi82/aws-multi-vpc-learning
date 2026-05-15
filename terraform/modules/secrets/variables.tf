variable "env" {
  type = string
}

variable "replica_region" {
  type        = string
  default     = "ap-northeast-3"
  description = "Secondary region for the secret replica"
}
