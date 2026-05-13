data "aws_region" "current" {}

resource "aws_ecs_cluster" "this" {
  name = "${var.env}-app"

  setting {
    name  = "containerInsights"
    value = "disabled" # 学習用コスト最適化
  }

  tags = { Name = "${var.env}-app" }
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name = aws_ecs_cluster.this.name

  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 1
  }
}

# ============================================================
# Task Definition
# ============================================================
resource "aws_ecs_task_definition" "app" {
  family                   = "${var.env}-app"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.cpu
  memory                   = var.memory

  execution_role_arn = aws_iam_role.execution.arn
  task_role_arn      = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = "app"
      image     = var.container_image
      essential = true

      portMappings = [
        {
          containerPort = var.container_port
          protocol      = "tcp"
        }
      ]

      environment = [
        { name = "ENV", value = var.env },
        { name = "DB_HOST", value = var.aurora_endpoint },
        { name = "DB_NAME", value = var.aurora_database_name },
      ]

      # Aurora Secrets Manager から username/password を注入
      # シークレットの中身: {"username":"...","password":"...","engine":"...","host":"...","port":5432,"dbname":"..."}
      secrets = [
        { name = "DB_USERNAME", valueFrom = "${var.aurora_secret_arn}:username::" },
        { name = "DB_PASSWORD", valueFrom = "${var.aurora_secret_arn}:password::" },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.app.name
          awslogs-region        = data.aws_region.current.name
          awslogs-stream-prefix = "app"
        }
      }
    }
  ])

  tags = { Name = "${var.env}-app" }
}

# ============================================================
# Service
# ============================================================
resource "aws_ecs_service" "app" {
  name             = "${var.env}-app"
  cluster          = aws_ecs_cluster.this.id
  task_definition  = aws_ecs_task_definition.app.arn
  desired_count    = var.desired_count
  launch_type      = "FARGATE"
  platform_version = "LATEST"

  enable_execute_command = var.enable_execute_command

  network_configuration {
    subnets          = var.app_subnet_ids
    security_groups  = [var.app_sg_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = "app"
    container_port   = var.container_port
  }

  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  # autoscaling_enabled = true の場合、Auto Scaling が desired_count を制御するため
  # Terraform は変更を無視する (drift 防止)
  lifecycle {
    ignore_changes = [desired_count]
  }

  depends_on = [aws_iam_role_policy.execution_secrets]

  tags = { Name = "${var.env}-app" }
}
