output "secret_arn" {
  value = aws_secretsmanager_secret.app.arn
}

output "secret_replica_arn" {
  value       = one([for r in aws_secretsmanager_secret.app.replica : r.arn if r.region == var.replica_region])
  description = "ARN of the replica secret in the secondary region (for Osaka ECS)"
}
