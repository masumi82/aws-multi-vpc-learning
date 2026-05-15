resource "aws_secretsmanager_secret" "app" {
  name                    = "${var.env}/app/db-connection"
  description             = "Application DB connection info with cross-region replica"
  recovery_window_in_days = 0

  replica {
    region = var.replica_region
  }

  tags = { Name = "${var.env}-app-db-connection" }
}
