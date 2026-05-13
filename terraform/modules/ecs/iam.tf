data "aws_iam_policy_document" "ecs_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# ============================================================
# Execution Role: ECR pull, CloudWatch Logs, Secrets Manager
# ============================================================
resource "aws_iam_role" "execution" {
  name               = "${var.env}-ecs-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
  tags               = { Name = "${var.env}-ecs-execution-role" }
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Secrets Manager の Aurora シークレット参照を限定して許可
data "aws_iam_policy_document" "execution_secrets" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.aurora_secret_arn]
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  name   = "${var.env}-ecs-execution-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets.json
}

# ============================================================
# Task Role: ECS Exec 用の SSM Messages を許可
# ============================================================
resource "aws_iam_role" "task" {
  name               = "${var.env}-ecs-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
  tags               = { Name = "${var.env}-ecs-task-role" }
}

data "aws_iam_policy_document" "task_exec" {
  statement {
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "task_exec" {
  name   = "${var.env}-ecs-task-exec"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_exec.json
}
