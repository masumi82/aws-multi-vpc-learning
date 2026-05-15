variable "env" {
  type = string
}

variable "cloudfront_domain" {
  type        = string
  description = "CloudFront distribution domain name (*.cloudfront.net)"
}

variable "zone_id" {
  type        = string
  description = "Route 53 Hosted Zone ID"
}

variable "domain_name" {
  type        = string
  description = "Domain name for the A record (e.g., dev.example.internal)"
}
