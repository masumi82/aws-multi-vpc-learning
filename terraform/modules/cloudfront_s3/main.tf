resource "random_id" "bucket_suffix" {
  byte_length = 4
}

locals {
  bucket_name = "app-ui-${var.env}-${random_id.bucket_suffix.hex}"
}

# ============================================================
# S3 Bucket (UI 静的配信、Block Public Access)
# ============================================================
resource "aws_s3_bucket" "ui" {
  bucket = local.bucket_name

  force_destroy = true # 学習用: 非空バケットでも destroy 可

  tags = { Name = local.bucket_name }
}

resource "aws_s3_bucket_public_access_block" "ui" {
  bucket = aws_s3_bucket.ui.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "ui" {
  bucket = aws_s3_bucket.ui.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# ============================================================
# Origin Access Control (OAC)
# CloudFront → S3 を SigV4 で署名アクセス
# ============================================================
resource "aws_cloudfront_origin_access_control" "ui" {
  name                              = "${var.env}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# ============================================================
# CloudFront Distribution
# ============================================================
locals {
  s3_origin_id         = "s3-${var.env}-ui"
  alb_origin_id        = "alb-${var.env}"
  alb_target_origin_id = var.osaka_alb_dns != "" ? "alb-failover-group" : local.alb_origin_id
}

resource "aws_cloudfront_distribution" "this" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "${var.env} app distribution"
  default_root_object = "index.html"
  price_class         = var.price_class
  web_acl_id          = var.web_acl_arn

  # ---------- Origins ----------
  origin {
    domain_name              = aws_s3_bucket.ui.bucket_regional_domain_name
    origin_id                = local.s3_origin_id
    origin_access_control_id = aws_cloudfront_origin_access_control.ui.id
  }

  origin {
    domain_name = var.alb_dns_name
    origin_id   = local.alb_origin_id

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  dynamic "origin" {
    for_each = var.osaka_alb_dns != "" ? [1] : []
    content {
      domain_name = var.osaka_alb_dns
      origin_id   = "alb-osaka"

      custom_origin_config {
        http_port              = 80
        https_port             = 443
        origin_protocol_policy = "http-only"
        origin_ssl_protocols   = ["TLSv1.2"]
      }
    }
  }

  dynamic "origin_group" {
    for_each = var.osaka_alb_dns != "" ? [1] : []
    content {
      origin_id = "alb-failover-group"
      failover_criteria {
        status_codes = [500, 502, 503, 504]
      }
      member { origin_id = local.alb_origin_id }
      member { origin_id = "alb-osaka" }
    }
  }

  # ---------- Default Behavior: S3 ----------
  default_cache_behavior {
    target_origin_id       = local.s3_origin_id
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # Managed: CachingOptimized
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  # ---------- /api/* Behavior: ALB ----------
  ordered_cache_behavior {
    path_pattern           = "/api/*"
    target_origin_id       = local.alb_target_origin_id
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    compress               = false

    # Managed: CachingDisabled
    cache_policy_id = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"

    # Managed: AllViewerExceptHostHeader
    # (Host ヘッダを ALB に渡さないようにする)
    origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac"
  }

  # ---------- SPA フォールバック ----------
  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 10
  }

  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 10
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = { Name = "${var.env}-distribution" }
}

resource "aws_s3_bucket_versioning" "ui" {
  bucket = aws_s3_bucket.ui.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_iam_role" "replication" {
  count = var.osaka_s3_bucket_arn != "" ? 1 : 0
  name  = "${var.env}-s3-replication-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Name = "${var.env}-s3-replication-role" }
}

resource "aws_iam_role_policy" "replication" {
  count = var.osaka_s3_bucket_arn != "" ? 1 : 0
  role  = aws_iam_role.replication[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetReplicationConfiguration", "s3:ListBucket"]
        Resource = aws_s3_bucket.ui.arn
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObjectVersionForReplication",
          "s3:GetObjectVersionAcl",
          "s3:GetObjectVersionTagging",
        ]
        Resource = "${aws_s3_bucket.ui.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ReplicateObject",
          "s3:ReplicateDelete",
          "s3:ReplicateTags",
        ]
        Resource = "${var.osaka_s3_bucket_arn}/*"
      },
    ]
  })
}

resource "aws_s3_bucket_replication_configuration" "to_osaka" {
  count      = var.osaka_s3_bucket_arn != "" ? 1 : 0
  depends_on = [aws_s3_bucket_versioning.ui]
  bucket     = aws_s3_bucket.ui.id
  role       = aws_iam_role.replication[0].arn

  rule {
    id     = "replicate-to-osaka"
    status = "Enabled"
    destination {
      bucket = var.osaka_s3_bucket_arn
    }
  }
}
