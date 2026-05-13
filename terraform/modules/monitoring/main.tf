# ============================================================
# SNS Topic for alerts
# ============================================================
resource "aws_sns_topic" "alerts" {
  name = "${var.env}-alerts"

  tags = { Name = "${var.env}-alerts" }
}

# Email を指定した場合のみ subscription を作成 (空文字なら作らない)
resource "aws_sns_topic_subscription" "email" {
  count = var.alert_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ============================================================
# CloudWatch Alarms
# ============================================================

# 1. ECS Service CPU 高負荷
resource "aws_cloudwatch_metric_alarm" "ecs_cpu_high" {
  alarm_name          = "${var.env}-ecs-cpu-high"
  alarm_description   = "ECS service CPU > ${var.ecs_cpu_threshold}% for 10 min"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  period              = 300
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  statistic           = "Average"
  threshold           = var.ecs_cpu_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_service_name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = { Name = "${var.env}-ecs-cpu-high" }
}

# 2. ALB 5xx エラー多発 (サーバ側エラーのみ; 4xx は除外)
resource "aws_cloudwatch_metric_alarm" "alb_5xx_high" {
  alarm_name          = "${var.env}-alb-5xx-high"
  alarm_description   = "ALB target 5xx > ${var.alb_5xx_threshold} / 5 min"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  period              = 300
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  statistic           = "Sum"
  threshold           = var.alb_5xx_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = { Name = "${var.env}-alb-5xx-high" }
}

# 3. TG Unhealthy Host (Fargate タスクが落ちた等)
resource "aws_cloudwatch_metric_alarm" "tg_unhealthy" {
  alarm_name          = "${var.env}-tg-unhealthy"
  alarm_description   = "ALB target group has unhealthy hosts"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  period              = 60
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.target_group_arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = { Name = "${var.env}-tg-unhealthy" }
}

# 4. Aurora Writer CPU 高負荷
resource "aws_cloudwatch_metric_alarm" "aurora_cpu_high" {
  alarm_name          = "${var.env}-aurora-cpu-high"
  alarm_description   = "Aurora cluster CPU > ${var.aurora_cpu_threshold}%"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  period              = 300
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  statistic           = "Average"
  threshold           = var.aurora_cpu_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBClusterIdentifier = var.aurora_cluster_id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = { Name = "${var.env}-aurora-cpu-high" }
}

# 5. Aurora Free Storage 残少 (storage は Aurora は自動拡張だが、メモリは警戒)
resource "aws_cloudwatch_metric_alarm" "aurora_freeable_memory" {
  alarm_name          = "${var.env}-aurora-low-memory"
  alarm_description   = "Aurora freeable memory < 100MB"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  period              = 300
  metric_name         = "FreeableMemory"
  namespace           = "AWS/RDS"
  statistic           = "Average"
  threshold           = 100 * 1024 * 1024 # 100 MB in bytes
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBClusterIdentifier = var.aurora_cluster_id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = { Name = "${var.env}-aurora-low-memory" }
}
