locals {
  env = "dev-osaka"
}

module "network" {
  source = "../../modules/network"

  env                 = local.env
  vpc_cidr            = var.vpc_cidr
  azs                 = var.azs
  public_subnet_cidrs = var.public_subnet_cidrs
  app_subnet_cidrs    = var.app_subnet_cidrs
  db_subnet_cidrs     = var.db_subnet_cidrs
  nat_gateway_per_az  = false
}

module "security_groups" {
  source = "../../modules/security_groups"

  env    = local.env
  vpc_id = module.network.vpc_id
}

module "alb" {
  source = "../../modules/alb"

  env               = local.env
  vpc_id            = module.network.vpc_id
  public_subnet_ids = module.network.public_subnet_ids
  alb_sg_id         = module.security_groups.alb_sg_id
}

module "aurora" {
  source = "../../modules/aurora"

  env                       = local.env
  db_subnet_ids             = module.network.db_subnet_ids
  aurora_sg_id              = module.security_groups.aurora_sg_id
  engine_version            = var.aurora_engine_version
  instance_class            = var.aurora_instance_class
  reader_count              = 0
  is_secondary              = true
  global_cluster_identifier = var.global_cluster_identifier
  source_region             = var.primary_region
}

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "osaka_destination" {
  bucket        = "app-ui-${local.env}-${random_id.bucket_suffix.hex}"
  force_destroy = true
  tags          = { Name = "app-ui-${local.env}" }
}

resource "aws_s3_bucket_versioning" "osaka_destination" {
  bucket = aws_s3_bucket.osaka_destination.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "osaka_destination" {
  bucket                  = aws_s3_bucket.osaka_destination.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

module "ecs" {
  source = "../../modules/ecs"

  env                  = local.env
  vpc_id               = module.network.vpc_id
  app_subnet_ids       = module.network.app_subnet_ids
  app_sg_id            = module.security_groups.app_sg_id
  target_group_arn     = module.alb.target_group_arn
  ecr_repository_url   = var.ecr_repository_url
  aurora_secret_arn    = var.app_secret_replica_arn
  aurora_endpoint      = module.aurora.cluster_reader_endpoint
  aurora_database_name = var.aurora_database_name
  desired_count        = 1
  cpu                  = 256
  memory               = 512
  autoscaling_enabled  = false
  min_capacity         = 1
  max_capacity         = 1
}

module "monitoring" {
  source = "../../modules/monitoring"

  env                     = local.env
  alert_email             = var.alert_email
  ecs_cluster_name        = module.ecs.cluster_name
  ecs_service_name        = module.ecs.service_name
  alb_arn_suffix          = module.alb.alb_arn_suffix
  target_group_arn_suffix = module.alb.target_group_arn_suffix
  aurora_cluster_id       = module.aurora.cluster_id
  vpc_id                  = module.network.vpc_id
  enable_guardduty        = true
  enable_flow_logs        = true
  enable_kms_cmk          = false
}
