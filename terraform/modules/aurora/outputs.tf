output "cluster_id" {
  value = aws_rds_cluster.this.id
}

output "cluster_endpoint" {
  value       = aws_rds_cluster.this.endpoint
  description = "Writer endpoint"
}

output "cluster_reader_endpoint" {
  value       = aws_rds_cluster.this.reader_endpoint
  description = "Reader endpoint (load balanced across readers)"
}

output "cluster_port" {
  value = aws_rds_cluster.this.port
}

output "database_name" {
  value = aws_rds_cluster.this.database_name
}

output "master_username" {
  value = aws_rds_cluster.this.master_username
}

# Aurora が Secrets Manager に自動生成したシークレットの ARN
# (ECS Execution/TaskRole から GetSecretValue で取得する)
output "master_user_secret_arn" {
  value       = length(aws_rds_cluster.this.master_user_secret) > 0 ? aws_rds_cluster.this.master_user_secret[0].secret_arn : null
  description = "ARN of the Secrets Manager secret managed by Aurora (null for secondary clusters)"
}
