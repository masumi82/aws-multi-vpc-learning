output "alb_arn" {
  value = aws_lb.this.arn
}

output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "alb_zone_id" {
  value = aws_lb.this.zone_id
}

output "alb_arn_suffix" {
  value       = aws_lb.this.arn_suffix
  description = "ARN suffix used as dimension in CloudWatch metrics"
}

output "target_group_arn" {
  value = aws_lb_target_group.this.arn
}

output "target_group_arn_suffix" {
  value       = aws_lb_target_group.this.arn_suffix
  description = "TG ARN suffix used as dimension in CloudWatch metrics"
}

output "listener_arn" {
  value = aws_lb_listener.http.arn
}
