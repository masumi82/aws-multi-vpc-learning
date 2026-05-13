output "alb_sg_id" {
  value = aws_security_group.alb.id
}

output "app_sg_id" {
  value = aws_security_group.app.id
}

output "aurora_sg_id" {
  value = aws_security_group.aurora.id
}

output "cloudfront_prefix_list_id" {
  value = data.aws_ec2_managed_prefix_list.cloudfront_origin.id
}
