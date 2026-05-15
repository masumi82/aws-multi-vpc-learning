locals {
  env = "dev"
}

module "network" {
  source = "../../modules/network"

  env                 = local.env
  vpc_cidr            = var.vpc_cidr
  azs                 = var.azs
  public_subnet_cidrs = var.public_subnet_cidrs
  app_subnet_cidrs    = var.app_subnet_cidrs
  db_subnet_cidrs     = var.db_subnet_cidrs
  nat_gateway_per_az  = var.nat_gateway_per_az
}

module "security_groups" {
  source = "../../modules/security_groups"

  env    = local.env
  vpc_id = module.network.vpc_id
}

module "ecr" {
  source = "../../modules/ecr"

  env                             = local.env
  repo_name                       = "app"
  enable_cross_region_replication = var.enable_ecr_replication
  replication_destination_region  = "ap-northeast-3"
}

# Aurora is created standalone first; aurora_global is created FROM aurora.
# AWS then sets global_cluster_identifier on aurora automatically (lifecycle ignore_changes).
module "aurora" {
  source = "../../modules/aurora"

  env           = local.env
  db_subnet_ids = module.network.db_subnet_ids
  aurora_sg_id  = module.security_groups.aurora_sg_id
  engine_version = var.aurora_engine_version
  instance_class = var.aurora_instance_class
  reader_count   = var.aurora_reader_count
  database_name  = var.aurora_database_name
}

module "aurora_global" {
  source = "../../modules/aurora_global"

  env                          = local.env
  source_db_cluster_identifier = module.aurora.cluster_arn
}

module "alb" {
  source = "../../modules/alb"

  env               = local.env
  vpc_id            = module.network.vpc_id
  public_subnet_ids = module.network.public_subnet_ids
  alb_sg_id         = module.security_groups.alb_sg_id
}

module "ecs" {
  source = "../../modules/ecs"

  env                  = local.env
  vpc_id               = module.network.vpc_id
  app_subnet_ids       = module.network.app_subnet_ids
  app_sg_id            = module.security_groups.app_sg_id
  target_group_arn     = module.alb.target_group_arn
  ecr_repository_url   = module.ecr.repository_url
  aurora_secret_arn    = module.secrets.secret_arn
  aurora_endpoint      = module.aurora.cluster_endpoint
  aurora_database_name = module.aurora.database_name
  desired_count        = var.ecs_desired_count
  cpu                  = var.ecs_cpu
  memory               = var.ecs_memory
  autoscaling_enabled  = var.ecs_autoscaling_enabled
  min_capacity         = var.ecs_min_capacity
  max_capacity         = var.ecs_max_capacity
}

module "waf" {
  source = "../../modules/waf"
  count  = var.enable_waf ? 1 : 0

  providers = {
    aws = aws.us_east_1
  }

  env        = local.env
  rate_limit = var.waf_rate_limit
}

module "cloudfront_s3" {
  source = "../../modules/cloudfront_s3"

  env                 = local.env
  alb_dns_name        = module.alb.alb_dns_name
  web_acl_arn         = var.enable_waf ? module.waf[0].web_acl_arn : null
  osaka_alb_dns       = var.osaka_alb_dns
  osaka_s3_bucket_arn = var.osaka_s3_bucket_arn
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

  # Tier 2
  vpc_id           = module.network.vpc_id
  enable_guardduty = var.enable_guardduty
  enable_flow_logs = var.enable_flow_logs
  enable_kms_cmk   = var.enable_kms_cmk
}

module "secrets" {
  source = "../../modules/secrets"

  env            = local.env
  replica_region = "ap-northeast-3"
}

module "route53" {
  count  = var.enable_route53 ? 1 : 0
  source = "../../modules/route53"

  env               = local.env
  cloudfront_domain = module.cloudfront_s3.cloudfront_domain_name
  zone_id           = var.route53_zone_id
  domain_name       = var.domain_name
}
