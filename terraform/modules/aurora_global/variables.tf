variable "env" {
  type = string
}

variable "source_db_cluster_identifier" {
  type        = string
  description = "ARN of the primary Aurora cluster to use as the global cluster source"
}
