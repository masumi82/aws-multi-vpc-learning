variable "env" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "app_port" {
  type        = number
  default     = 80
  description = "Container/ALB target port"
}

variable "db_port" {
  type        = number
  default     = 5432
  description = "Aurora PostgreSQL port"
}
