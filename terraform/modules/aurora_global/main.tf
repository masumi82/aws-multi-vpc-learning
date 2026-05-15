resource "aws_rds_global_cluster" "this" {
  global_cluster_identifier = "${var.env}-global"
  engine                    = "aurora-postgresql"
  engine_version            = var.engine_version
  database_name             = var.database_name
  deletion_protection       = false
  storage_encrypted         = true
}
