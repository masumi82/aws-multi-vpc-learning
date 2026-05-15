data "aws_region" "current" {}

resource "aws_secretsmanager_secret" "app" {
  name                    = "${var.env}/app/db-connection"
  description             = "Application DB connection info with cross-region replica"
  recovery_window_in_days = 0

  dynamic "replica" {
    for_each = var.enable_replica ? [var.replica_region] : []
    content {
      region = replica.value
    }
  }

  tags = { Name = "${var.env}-app-db-connection" }
}
