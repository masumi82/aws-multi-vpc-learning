variable "env" {
  type = string
}

variable "alert_email" {
  type        = string
  default     = ""
  description = "Email to subscribe to SNS topic. Leave empty to skip subscription. After apply, check inbox and confirm subscription manually."
}

variable "ecs_cluster_name" {
  type = string
}

variable "ecs_service_name" {
  type = string
}

variable "alb_arn_suffix" {
  type        = string
  description = "ALB ARN suffix (last portion). Used for CloudWatch metrics."
}

variable "target_group_arn_suffix" {
  type        = string
  description = "Target Group ARN suffix. Used for CloudWatch metrics."
}

variable "aurora_cluster_id" {
  type = string
}

variable "ecs_cpu_threshold" {
  type    = number
  default = 80
}

variable "alb_5xx_threshold" {
  type    = number
  default = 10
}

variable "aurora_cpu_threshold" {
  type    = number
  default = 80
}
