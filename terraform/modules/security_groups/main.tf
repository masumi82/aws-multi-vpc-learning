locals {
  name_prefix = var.env
}

# ============================================================
# SG-ALB: CloudFront からの 80 を許可
# ============================================================
resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-sg-alb"
  description = "ALB SG. Allow HTTP from CloudFront managed prefix list only."
  vpc_id      = var.vpc_id

  tags = { Name = "${local.name_prefix}-sg-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_cloudfront" {
  security_group_id = aws_security_group.alb.id
  description       = "Allow HTTP from CloudFront origin-facing managed prefix list"
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront_origin.id
  from_port         = var.app_port
  to_port           = var.app_port
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_all" {
  security_group_id = aws_security_group.alb.id
  description       = "Allow all outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ============================================================
# SG-App: SG-ALB からの app_port のみ許可
# ============================================================
resource "aws_security_group" "app" {
  name        = "${local.name_prefix}-sg-app"
  description = "App (Fargate) SG. Allow traffic from SG-ALB only."
  vpc_id      = var.vpc_id

  tags = { Name = "${local.name_prefix}-sg-app" }
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "Allow from ALB SG"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.app_port
  to_port                      = var.app_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app.id
  description       = "Allow all outbound (via NAT GW for ECR/SSM/SecretsManager)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ============================================================
# SG-Aurora: SG-App からの db_port のみ許可
# ============================================================
resource "aws_security_group" "aurora" {
  name        = "${local.name_prefix}-sg-aurora"
  description = "Aurora SG. Allow traffic from SG-App only."
  vpc_id      = var.vpc_id

  tags = { Name = "${local.name_prefix}-sg-aurora" }
}

resource "aws_vpc_security_group_ingress_rule" "aurora_from_app" {
  security_group_id            = aws_security_group.aurora.id
  description                  = "Allow PostgreSQL from App SG"
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = var.db_port
  to_port                      = var.db_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "aurora_all" {
  security_group_id = aws_security_group.aurora.id
  description       = "Allow all outbound (default)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
