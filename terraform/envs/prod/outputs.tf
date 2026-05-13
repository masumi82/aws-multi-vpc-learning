output "vpc_id" {
  value = module.network.vpc_id
}

output "alb_dns_name" {
  value = module.alb.alb_dns_name
}

output "cloudfront_domain_name" {
  value = module.cloudfront_s3.cloudfront_domain_name
}

output "cloudfront_distribution_id" {
  value = module.cloudfront_s3.cloudfront_distribution_id
}

output "s3_bucket_name" {
  value = module.cloudfront_s3.s3_bucket_name
}

output "ecs_cluster_name" {
  value = module.ecs.cluster_name
}

output "ecs_service_name" {
  value = module.ecs.service_name
}

output "ecr_repository_url" {
  value = module.ecr.repository_url
}

output "aurora_cluster_endpoint" {
  value = module.aurora.cluster_endpoint
}

output "aurora_reader_endpoint" {
  value = module.aurora.cluster_reader_endpoint
}

output "aurora_secret_arn" {
  value     = module.aurora.master_user_secret_arn
  sensitive = true
}

output "nat_gateway_count" {
  value = module.network.nat_gateway_count
}

output "sns_alerts_topic_arn" {
  value = module.monitoring.sns_topic_arn
}
