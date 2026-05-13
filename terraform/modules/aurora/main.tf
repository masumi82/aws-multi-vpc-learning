resource "aws_db_subnet_group" "this" {
  name        = "${var.env}-aurora-subnet-group"
  description = "DB Subnet Group for ${var.env} Aurora cluster (3 AZ)"
  subnet_ids  = var.db_subnet_ids

  tags = { Name = "${var.env}-aurora-subnet-group" }
}

resource "aws_rds_cluster" "this" {
  cluster_identifier = "${var.env}-aurora-cluster"

  engine         = "aurora-postgresql"
  engine_mode    = "provisioned"
  engine_version = var.engine_version

  database_name   = var.database_name
  master_username = var.master_username

  # マスターパスワードは AWS が Secrets Manager 内で自動生成・管理
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.aurora_sg_id]

  backup_retention_period = var.backup_retention_period
  preferred_backup_window = "17:00-19:00" # UTC = JST 02:00-04:00

  skip_final_snapshot = var.skip_final_snapshot
  deletion_protection = var.deletion_protection

  apply_immediately = true

  tags = { Name = "${var.env}-aurora-cluster" }
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
