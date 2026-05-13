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
