output "alb_dns_name" {
  value       = module.alb.alb_dns_name
  description = "Osaka ALB DNS name — set as osaka_alb_dns in envs/dev/terraform.tfvars"
}

output "s3_bucket_arn" {
  value       = aws_s3_bucket.osaka_destination.arn
  description = "Osaka S3 bucket ARN — set as osaka_s3_bucket_arn in envs/dev/terraform.tfvars"
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "ecs_cluster_name" {
  value = module.ecs.cluster_name
}

output "aurora_reader_endpoint" {
  value = module.aurora.cluster_reader_endpoint
}
