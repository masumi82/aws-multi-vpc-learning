variable "env" {
  type        = string
  description = "Environment name (e.g. prod, dev). Used as prefix for resource names."
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC."
}

variable "azs" {
  type        = list(string)
  description = "Availability Zones to use. Must contain exactly 3 entries."
  validation {
    condition     = length(var.azs) == 3
    error_message = "azs must contain exactly 3 AZs."
  }
}

variable "public_subnet_cidrs" {
  type        = list(string)
  description = "CIDR blocks for 3 public subnets (one per AZ)."
}

variable "app_subnet_cidrs" {
  type        = list(string)
  description = "CIDR blocks for 3 app (private) subnets (one per AZ)."
}

variable "db_subnet_cidrs" {
  type        = list(string)
  description = "CIDR blocks for 3 db (private) subnets (one per AZ)."
}

variable "nat_gateway_per_az" {
  type        = bool
  default     = false
  description = "If true, deploy one NAT Gateway per AZ (3 total) with per-AZ App route tables. Removes the 1a NAT GW SPOF. Tier 1 HA."
}
