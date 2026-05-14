# ============================================================
# AWS WAFv2 Web ACL (CloudFront scope)
# NOTE: scope = "CLOUDFRONT" のリソースは us-east-1 リージョン
#       に作成する必要がある。呼び出し側で provider alias を渡す。
# ============================================================

resource "aws_wafv2_web_acl" "this" {
  name        = "${var.env}-cloudfront-acl"
  description = "WAF for ${var.env} CloudFront distribution"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # ---------- 1. AWS Managed: Common Rule Set (OWASP-like) ----------
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.env}-common-rule-set"
      sampled_requests_enabled   = true
    }
  }

  # ---------- 2. AWS Managed: Known Bad Inputs ----------
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.env}-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  # ---------- 3. AWS Managed: Amazon IP Reputation List ----------
  rule {
    name     = "AWSManagedRulesAmazonIpReputationList"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.env}-amazon-ip-reputation"
      sampled_requests_enabled   = true
    }
  }

  # ---------- 4. Rate-based Rule (5min で N req 超過は block) ----------
  rule {
    name     = "RateLimit"
    priority = 10

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.rate_limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.env}-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.env}-cloudfront-acl"
    sampled_requests_enabled   = true
  }

  tags = { Name = "${var.env}-cloudfront-acl" }
}
