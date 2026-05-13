# awslogs ドライバが CreateLogGroup を要求するのを避けるため、
# Terraform で先に LogGroup を作成しておく。
resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.env}-app"
  retention_in_days = var.log_retention_days

  tags = { Name = "/ecs/${var.env}-app" }
}
