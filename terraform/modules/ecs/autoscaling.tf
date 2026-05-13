# Application Auto Scaling for ECS Service
# autoscaling_enabled = true でのみ作成 (Tier 1 HA)

resource "aws_appautoscaling_target" "ecs" {
  count = var.autoscaling_enabled ? 1 : 0

  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.app.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.min_capacity
  max_capacity       = var.max_capacity

  depends_on = [aws_ecs_service.app]
}

# CPU 使用率に基づく Target Tracking Scaling
resource "aws_appautoscaling_policy" "cpu" {
  count = var.autoscaling_enabled ? 1 : 0

  name               = "${var.env}-ecs-cpu-target"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.ecs[0].service_namespace
  resource_id        = aws_appautoscaling_target.ecs[0].resource_id
  scalable_dimension = aws_appautoscaling_target.ecs[0].scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value = var.cpu_target_value

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }

    scale_in_cooldown  = 300 # 5 分かけて縮退 (急縮退を防ぐ)
    scale_out_cooldown = 60  # 1 分で拡張可 (急増にすぐ反応)
  }
}
