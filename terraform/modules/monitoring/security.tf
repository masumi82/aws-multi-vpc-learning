# ============================================================
# Tier 2 セキュリティ拡張: GuardDuty / VPC Flow Logs / KMS CMK
# enable_* フラグでオプトイン制御 (デフォルト全 false で後方互換)
# ============================================================

data "aws_caller_identity" "current" {
  count = var.enable_flow_logs || var.enable_kms_cmk ? 1 : 0
}

data "aws_region" "current" {
  count = var.enable_flow_logs ? 1 : 0
}

# ------------------------------------------------------------
# GuardDuty (リージョン Detector)
# ------------------------------------------------------------
resource "aws_guardduty_detector" "this" {
  count = var.enable_guardduty ? 1 : 0

  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"

  tags = { Name = "${var.env}-guardduty" }
}

# ------------------------------------------------------------
# KMS Customer Managed Key (Logs / SNS 共用)
# ------------------------------------------------------------
resource "aws_kms_key" "logs" {
  count = var.enable_kms_cmk ? 1 : 0

  description             = "${var.env} CMK for CloudWatch Logs / SNS"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRoot"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current[0].account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid    = "AllowCloudWatchLogs"
        Effect = "Allow"
        Principal = {
          Service = "logs.${data.aws_region.current[0].name}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt*",
          "kms:Decrypt*",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:Describe*",
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${data.aws_region.current[0].name}:${data.aws_caller_identity.current[0].account_id}:log-group:/aws/vpc/${var.env}-flow-logs"
          }
        }
      },
      {
        Sid    = "AllowSNS"
        Effect = "Allow"
        Principal = {
          Service = "sns.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
        ]
        Resource = "*"
      },
    ]
  })

  tags = { Name = "${var.env}-logs-cmk" }
}

resource "aws_kms_alias" "logs" {
  count = var.enable_kms_cmk ? 1 : 0

  name          = "alias/${var.env}-logs-cmk"
  target_key_id = aws_kms_key.logs[0].key_id
}

# ------------------------------------------------------------
# VPC Flow Logs (CloudWatch Logs 出力)
# ------------------------------------------------------------
resource "aws_cloudwatch_log_group" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name              = "/aws/vpc/${var.env}-flow-logs"
  retention_in_days = var.flow_logs_retention_days
  kms_key_id        = var.enable_kms_cmk ? aws_kms_key.logs[0].arn : null

  tags = { Name = "${var.env}-flow-logs" }
}

resource "aws_iam_role" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name = "${var.env}-flow-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Name = "${var.env}-flow-logs-role" }
}

resource "aws_iam_role_policy" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name = "${var.env}-flow-logs-policy"
  role = aws_iam_role.flow_logs[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
      ]
      Resource = "${aws_cloudwatch_log_group.flow_logs[0].arn}:*"
    }]
  })
}

resource "aws_flow_log" "vpc" {
  count = var.enable_flow_logs ? 1 : 0

  vpc_id          = var.vpc_id
  traffic_type    = "ALL"
  log_destination = aws_cloudwatch_log_group.flow_logs[0].arn
  iam_role_arn    = aws_iam_role.flow_logs[0].arn

  tags = { Name = "${var.env}-vpc-flow-logs" }
}
