output "secret_arn" {
  value = aws_secretsmanager_secret.app.arn
}

output "secret_replica_arn" {
  value       = replace(aws_secretsmanager_secret.app.arn, data.aws_region.current.name, var.replica_region)
  description = "ARN of the replica secret in the secondary region (for Osaka ECS)"
}
