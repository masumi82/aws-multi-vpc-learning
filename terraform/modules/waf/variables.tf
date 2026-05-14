variable "env" {
  type = string
}

variable "rate_limit" {
  type        = number
  default     = 2000
  description = "Max requests per 5 min per source IP. Above = block."
}
