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
