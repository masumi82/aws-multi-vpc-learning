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
