# Aurora Global DB does not support manage_master_user_password; use a random
# password instead. Standalone clusters use Secrets Manager managed passwords.
resource "random_password" "master" {
  count   = var.global_cluster_identifier != "" ? 1 : 0
  length  = 32
  special = false
}

resource "aws_db_subnet_group" "this" {
  name        = "${var.env}-aurora-subnet-group"
  description = "DB Subnet Group for ${var.env} Aurora cluster (3 AZ)"
  subnet_ids  = var.db_subnet_ids

  tags = { Name = "${var.env}-aurora-subnet-group" }
}

resource "aws_rds_cluster" "this" {
  cluster_identifier        = "${var.env}-aurora-cluster"
  engine                    = "aurora-postgresql"
  engine_mode               = "provisioned"
  engine_version            = var.engine_version
  storage_encrypted         = true
  global_cluster_identifier = var.global_cluster_identifier != "" ? var.global_cluster_identifier : null
  source_region             = var.is_secondary ? var.source_region : null

  # Global DB defines the DB name at cluster level; member clusters must omit it
  database_name               = var.global_cluster_identifier != "" ? null : var.database_name
  master_username             = var.master_username
  master_password             = var.global_cluster_identifier != "" ? random_password.master[0].result : null
  manage_master_user_password = var.global_cluster_identifier != "" ? null : true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.aurora_sg_id]

  backup_retention_period = var.backup_retention_period
  preferred_backup_window = "17:00-19:00" # UTC = JST 02:00-04:00

  skip_final_snapshot = var.skip_final_snapshot
  deletion_protection = var.deletion_protection

  apply_immediately = true

  tags = { Name = "${var.env}-aurora-cluster" }

  lifecycle {
    precondition {
      condition     = !var.is_secondary || var.source_region != ""
      error_message = "source_region must be set when is_secondary = true."
    }
  }
}

# count = 1 (writer) + reader_count
# index = 0 が writer として昇格する
resource "aws_rds_cluster_instance" "this" {
  count = 1 + var.reader_count

  identifier         = "${var.env}-aurora-${count.index}"
  cluster_identifier = aws_rds_cluster.this.id
  instance_class     = var.instance_class
  engine             = aws_rds_cluster.this.engine
  engine_version     = aws_rds_cluster.this.engine_version

  db_subnet_group_name = aws_db_subnet_group.this.name

  apply_immediately = true

  tags = {
    Name = "${var.env}-aurora-${count.index}"
    Role = count.index == 0 ? "writer" : "reader"
  }
}
