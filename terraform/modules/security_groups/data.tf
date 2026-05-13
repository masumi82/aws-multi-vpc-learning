# CloudFront のオリジン向け Managed Prefix List を取得し、
# ALB SG の ingress 許可元に使う。
# これにより ALB は CloudFront からのみアクセス可能になる。
data "aws_ec2_managed_prefix_list" "cloudfront_origin" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}
