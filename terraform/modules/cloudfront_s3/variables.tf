variable "env" {
  type = string
}

variable "alb_dns_name" {
  type = string
}

variable "price_class" {
  type    = string
  default = "PriceClass_200"
}

variable "web_acl_arn" {
  type        = string
  default     = null
  description = "Optional WAFv2 Web ACL ARN (CLOUDFRONT scope). null = no WAF."
}

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
