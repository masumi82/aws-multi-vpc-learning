# Aurora Global DB does not support manage_master_user_password on any member.
# Primary uses a random password; secondary inherits credentials from primary.
resource "random_password" "master" {
  count   = var.is_secondary ? 0 : 1
  length  = 32
  special = false
}

# Encrypted cross-region replicas require an explicit KMS key in the replica region.
data "aws_kms_key" "rds" {
  count  = var.is_secondary ? 1 : 0
  key_id = "alias/aws/rds"
}

resource "aws_db_subnet_group" "this" {
  name        = "${var.env}-aurora-subnet-group"
  description = "DB Subnet Group for ${var.env} Aurora cluster (3 AZ)"
  subnet_ids  = var.db_subnet_ids

  tags = { Name = "${var.env}-aurora-subnet-group" }
}

resource "aws_rds_cluster" "this" {
  cluster_identifier = "${var.env}-aurora-cluster"
  engine             = "aurora-postgresql"
  engine_mode        = "provisioned"
  engine_version     = var.engine_version
  storage_encrypted = true
  kms_key_id        = var.is_secondary ? data.aws_kms_key.rds[0].arn : null

  # Secondary clusters join the global cluster explicitly.
  # Primary clusters join via source_db_cluster_identifier in aurora_global;
  # AWS then sets this attribute automatically (lifecycle ignore_changes below).
  global_cluster_identifier = var.is_secondary ? (var.global_cluster_identifier != "" ? var.global_cluster_identifier : null) : null
  source_region             = var.is_secondary ? var.source_region : null

  database_name   = var.is_secondary ? null : var.database_name
  # Secondary clusters inherit credentials from primary via Global DB replication
  master_username = var.is_secondary ? null : var.master_username
  master_password = var.is_secondary ? null : random_password.master[0].result

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.aurora_sg_id]

  backup_retention_period = var.backup_retention_period
  preferred_backup_window = "17:00-19:00" # UTC = JST 02:00-04:00

  skip_final_snapshot = var.skip_final_snapshot
  deletion_protection = var.deletion_protection

  apply_immediately = true

  tags = { Name = "${var.env}-aurora-cluster" }

  lifecycle {
    # AWS sets this automatically when primary joins global cluster via
    # source_db_cluster_identifier — don't remove it on subsequent plans.
    ignore_changes = [global_cluster_identifier]

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
