variable "env" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "app_subnet_ids" {
  type = list(string)
}

variable "app_sg_id" {
  type = string
}

variable "target_group_arn" {
  type = string
}

variable "ecr_repository_url" {
  type        = string
  description = "Used for tagging/output. Initial image uses public nginx."
}

variable "container_image" {
  type        = string
  default     = "public.ecr.aws/nginx/nginx:stable"
  description = "Initial container image. Replace with ECR image after first push."
}

variable "container_port" {
  type    = number
  default = 80
}

variable "cpu" {
  type    = number
  default = 256
}

variable "memory" {
  type    = number
  default = 512
}

variable "desired_count" {
  type    = number
  default = 2
}

variable "autoscaling_enabled" {
  type        = bool
  default     = false
  description = "Enable Application Auto Scaling on the ECS service (Tier 1)"
}

variable "min_capacity" {
  type        = number
  default     = 1
  description = "Auto Scaling min task count (used when autoscaling_enabled = true)"
}

variable "max_capacity" {
  type        = number
  default     = 3
  description = "Auto Scaling max task count (used when autoscaling_enabled = true)"
}

variable "cpu_target_value" {
  type        = number
  default     = 70
  description = "Target CPU utilization (%) for Auto Scaling"
}

variable "aurora_secret_arn" {
  type        = string
  description = "ARN of Aurora master user secret in Secrets Manager"
}

variable "aurora_endpoint" {
  type        = string
  description = "Aurora writer endpoint, injected as env var DB_HOST"
}

variable "aurora_database_name" {
  type    = string
  default = "appdb"
}

variable "log_retention_days" {
  type    = number
  default = 7
}

variable "enable_execute_command" {
  type        = bool
  default     = true
  description = "Enable ECS Exec for debugging"
}
