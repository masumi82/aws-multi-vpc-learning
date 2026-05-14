output "sns_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "alarm_names" {
  value = [
    aws_cloudwatch_metric_alarm.ecs_cpu_high.alarm_name,
    aws_cloudwatch_metric_alarm.alb_5xx_high.alarm_name,
    aws_cloudwatch_metric_alarm.tg_unhealthy.alarm_name,
    aws_cloudwatch_metric_alarm.aurora_cpu_high.alarm_name,
    aws_cloudwatch_metric_alarm.aurora_freeable_memory.alarm_name,
  ]
}

# ---------- Tier 2 ----------
output "guardduty_detector_id" {
  value = var.enable_guardduty ? aws_guardduty_detector.this[0].id : null
}

output "flow_logs_log_group" {
  value = var.enable_flow_logs ? aws_cloudwatch_log_group.flow_logs[0].name : null
}

output "kms_key_arn" {
  value = var.enable_kms_cmk ? aws_kms_key.logs[0].arn : null
}
