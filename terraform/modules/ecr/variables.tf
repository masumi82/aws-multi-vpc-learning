variable "env" {
  type = string
}

variable "repo_name" {
  type        = string
  default     = "app"
  description = "Repository base name (will be prefixed with env)"
}
