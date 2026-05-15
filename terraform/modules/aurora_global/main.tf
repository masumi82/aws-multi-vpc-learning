resource "aws_rds_global_cluster" "this" {
  global_cluster_identifier    = "${var.env}-global"
  source_db_cluster_identifier = var.source_db_cluster_identifier
  force_destroy                = true
}
