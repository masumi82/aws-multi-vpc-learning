output "health_check_id" {
  value = aws_route53_health_check.cloudfront.id
}

output "record_fqdn" {
  value = aws_route53_record.app.fqdn
}
