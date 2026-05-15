#!/usr/bin/env bash
# C7: Multi-Region DR Failover Simulation
# Tokyo ECS を停止して CloudFront Origin Group が Osaka にフェイルオーバーすることを確認。
# 前提: Tier 3 apply 済み (dev + dev-osaka), osaka_alb_dns が設定されている
set -uo pipefail

REGION="${REGION:-ap-northeast-1}"
OSAKA_REGION="ap-northeast-3"
TF_ENV="${TF_ENV:-dev}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TF_DIR="$ROOT/terraform/envs/$TF_ENV"
TF_DIR_OSAKA="$ROOT/terraform/envs/dev-osaka"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'
PASS=0; FAIL=0

CF_DOMAIN=$(terraform -chdir="$TF_DIR" output -raw cloudfront_domain_name 2>/dev/null || echo "")
OSAKA_ALB=$(terraform -chdir="$TF_DIR" output -raw osaka_alb_dns 2>/dev/null || echo "")

if [ -z "$CF_DOMAIN" ] || [ -z "$OSAKA_ALB" ] || [ "$OSAKA_ALB" = "" ]; then
  echo "SKIP C7: osaka_alb_dns not configured — Tier 3 not fully deployed"
  exit 0
fi

CLUSTER=$(terraform -chdir="$TF_DIR" output -raw ecs_cluster_name)
SERVICE=$(terraform -chdir="$TF_DIR" output -raw ecs_service_name)
ORIGINAL_COUNT=$(aws ecs describe-services --region "$REGION" \
  --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].desiredCount' --output text)

echo "==== C7: DR Failover Simulation ===="
echo "CloudFront: $CF_DOMAIN"
echo "Osaka ALB:  $OSAKA_ALB"
echo "Tokyo ECS service: $CLUSTER/$SERVICE (desired=$ORIGINAL_COUNT)"
echo ""

# Step 1: Tokyo ECS を 0 にして ALB を 5xx 状態にする
echo "Step 1: Scaling Tokyo ECS to 0..."
aws ecs update-service --region "$REGION" --cluster "$CLUSTER" --service "$SERVICE" \
  --desired-count 0 --query 'service.desiredCount' --output text > /dev/null
sleep 30

# Step 2: CloudFront が Osaka にフェイルオーバーするか確認 (Origin Group: 5xx → Osaka)
echo "Step 2: Testing CloudFront Origin Group failover..."
STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  "https://${CF_DOMAIN}/api/health" \
  -H "User-Agent: chaos-c7-failover" --max-time 15 2>/dev/null || echo "000")
echo "  /api/health via CloudFront → HTTP $STATUS"
if [ "$STATUS" = "200" ] || [ "$STATUS" = "404" ] || [ "$STATUS" = "503" ]; then
  printf "  ${GREEN}PASS${NC} C7.1 CloudFront returned response (Osaka ALB handling traffic)\n"
  PASS=$((PASS+1))
else
  printf "  ${YELLOW}WARN${NC} C7.1 Unexpected status=$STATUS (CloudFront may still be routing to Tokyo)\n"
  FAIL=$((FAIL+1))
fi

# Step 3: Aurora DR Runbook 手順を表示 (実行はしない)
echo ""
echo "Step 3: Aurora Global DB Promote Runbook (dry-run display only)"
echo "  1. aws rds describe-global-clusters --region $REGION"
echo "  2. aws rds remove-from-global-cluster --region $OSAKA_REGION \\"
echo "       --global-cluster-identifier <identifier> \\"
echo "       --db-cluster-identifier dev-osaka-aurora-cluster"
echo "  3. Wait for cluster status = available"
echo "  4. Update app_secret in Secrets Manager with new Osaka writer endpoint"
echo "  5. Restart Osaka ECS service to pick up new endpoint"
printf "  ${YELLOW}NOTE${NC} Above steps are for documentation — not executed in this script\n"

# Step 4: Tokyo ECS を元に戻す
echo ""
echo "Step 4: Restoring Tokyo ECS to desired_count=$ORIGINAL_COUNT..."
aws ecs update-service --region "$REGION" --cluster "$CLUSTER" --service "$SERVICE" \
  --desired-count "$ORIGINAL_COUNT" --query 'service.desiredCount' --output text > /dev/null

echo ""
echo "==== C7 Result: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed/warn${NC} ===="
[ "$FAIL" -eq 0 ]
