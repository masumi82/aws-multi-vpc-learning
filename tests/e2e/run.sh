#!/usr/bin/env bash
# E2E tests (Playwright)
# 環境変数 TF_ENV=dev|prod で対象環境を切替
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TF_ENV="${TF_ENV:-dev}"
TF_DIR="$ROOT/terraform/envs/$TF_ENV"
E2E_DIR="$ROOT/tests/e2e"

if [ ! -f "$TF_DIR/terraform.tfstate" ]; then
  echo "ERROR: $TF_DIR/terraform.tfstate not found. Run 'terraform apply' first."
  exit 2
fi

CLOUDFRONT_DOMAIN=$(terraform -chdir="$TF_DIR" output -raw cloudfront_domain_name 2>/dev/null)
ALB_DNS_NAME=$(terraform -chdir="$TF_DIR" output -raw alb_dns_name 2>/dev/null)
S3_BUCKET=$(terraform -chdir="$TF_DIR" output -raw s3_bucket_name 2>/dev/null)

if [ -z "$CLOUDFRONT_DOMAIN" ]; then
  echo "ERROR: cloudfront_domain_name output not found"
  exit 2
fi

echo "==== E2E: CloudFront=$CLOUDFRONT_DOMAIN ===="

# index.html が無いと E1/E3 が落ちるので、無ければ自動で配置
if ! aws s3api head-object --bucket "$S3_BUCKET" --key index.html >/dev/null 2>&1; then
  echo "index.html not found in s3://$S3_BUCKET — uploading test fixture..."
  TMP=$(mktemp -d)
  cat > "$TMP/index.html" <<'EOF'
<!doctype html>
<html><head><meta charset="utf-8"><title>aws-sekei test</title></head>
<body><h1>aws-sekei UI</h1><p data-testid="marker">deployed</p></body></html>
EOF
  aws s3 cp "$TMP/index.html" "s3://$S3_BUCKET/index.html" --content-type "text/html"
  rm -rf "$TMP"
  # CloudFront キャッシュ invalidation
  CF_ID=$(terraform -chdir="$TF_DIR" output -raw cloudfront_distribution_id 2>/dev/null)
  aws cloudfront create-invalidation --distribution-id "$CF_ID" --paths "/*" >/dev/null
  echo "Waiting 30s for CloudFront invalidation to propagate..."
  sleep 30
fi

# Playwright 依存セットアップ (初回のみ)
cd "$E2E_DIR"
if [ ! -d "node_modules" ]; then
  echo "Installing Playwright..."
  npm install --silent
  npx playwright install chromium --with-deps 2>/dev/null || npx playwright install chromium
fi

export CLOUDFRONT_DOMAIN ALB_DNS_NAME
npx playwright test
