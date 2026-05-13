variable "env" {
  type = string
}

variable "db_subnet_ids" {
  type = list(string)
}

variable "aurora_sg_id" {
  type = string
}

variable "engine_version" {
  type    = string
  default = "15.10"
  # 注意: apply 前に必ず以下で現在サポートされているバージョンを確認すること。
  # Aurora は古い minor を順次サポート終了する。
  #   aws rds describe-db-engine-versions \
  #     --engine aurora-postgresql \
  #     --query 'DBEngineVersions[?starts_with(EngineVersion, `15.`)].EngineVersion' \
  #     --output text
  # サポート外バージョンを指定すると apply 時に
  # InvalidParameterCombination で失敗する。
}

variable "instance_class" {
  type    = string
  default = "db.t4g.medium"
}

variable "reader_count" {
  type        = number
  default     = 2
  description = "Number of reader instances (writer is always 1)"
}

variable "database_name" {
  type    = string
  default = "appdb"
}

variable "master_username" {
  type    = string
  default = "appadmin"
}

variable "backup_retention_period" {
  type        = number
  default     = 1
  description = "Backup retention in days. Minimum 1 (0 is not allowed for Aurora)"
}

variable "skip_final_snapshot" {
  type    = bool
  default = true
}

variable "deletion_protection" {
  type    = bool
  default = false
}
