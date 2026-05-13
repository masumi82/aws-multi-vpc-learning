# OAC 経由 CloudFront のみが S3 を読めるバケットポリシー
# 循環参照を避けるため、Distribution の ARN を Source 条件で参照する
data "aws_iam_policy_document" "s3" {
  statement {
    sid     = "AllowCloudFrontOAC"
    actions = ["s3:GetObject"]
    resources = [
      "${aws_s3_bucket.ui.arn}/*",
    ]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.this.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "ui" {
  bucket = aws_s3_bucket.ui.id
  policy = data.aws_iam_policy_document.s3.json

  depends_on = [
    aws_s3_bucket_public_access_block.ui,
    aws_cloudfront_distribution.this,
  ]
}
