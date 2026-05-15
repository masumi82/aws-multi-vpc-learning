output "cluster_arn" {
  value       = aws_rds_cluster.this.arn
  description = "ARN used as source_db_cluster_identifier for aws_rds_global_cluster"
}

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

