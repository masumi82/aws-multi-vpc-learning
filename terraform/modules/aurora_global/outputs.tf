output "global_cluster_identifier" {
  value = aws_rds_global_cluster.this.id
}

output "global_cluster_arn" {
  value = aws_rds_global_cluster.this.arn
}
