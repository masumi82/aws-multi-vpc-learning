#!/usr/bin/env bash
# C6: WAFv2 Managed Rule のブロック検証
# CloudFront 経由で SQLi/XSS の典型ペイロードを送り、403 で blocked されることを確認する。
# 前提: enable_waf=true で apply 済 (prod 環境想定)
set -uo pipefail

REGION="${REGION:-ap-northeast-1}"
TF_ENV="${TF_ENV:-prod}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TF_DIR="${TF_DIR:-$ROOT/terraform/envs/$TF_ENV}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'

WAF_ARN=$(terraform -chdir="$TF_DIR" output -raw waf_web_acl_arn 2>/dev/null || echo "")
if [ -z "$WAF_ARN" ] || [ "$WAF_ARN" = "null" ]; then
  echo "SKIP C6: WAF not enabled in $TF_ENV (waf_web_acl_arn output is null)"
  exit 0
fi

CF_DOMAIN=$(terraform -chdir="$TF_DIR" output -raw cloudfront_domain_name)
TARGET="https://${CF_DOMAIN}/api/items"

echo "==== C6: WAF Managed Rule Block Verification ===="
echo "Target: $TARGET"
echo "WAF:    $WAF_ARN"
echo ""

PASS=0; FAIL=0

# ----- Test 1: SQL Injection 典型 payload -----
PAYLOAD_SQLI="?id=1%27%20OR%20%271%27%3D%271"   # ' OR '1'='1
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${TARGET}${PAYLOAD_SQLI}" \
  -H "User-Agent: chaos-c6-sqli" --max-time 10)
echo "  SQLi payload → HTTP $STATUS"
if [ "$STATUS" = "403" ]; then
  printf "  ${GREEN}PASS${NC} C6.1 SQLi blocked by WAF (403)\n"
  PASS=$((PASS+1))
else
  printf "  ${YELLOW}WARN${NC} C6.1 SQLi NOT blocked (status=%s). WAF may need warm-up or rule needs tuning.\n" "$STATUS"
  FAIL=$((FAIL+1))
fi

# ----- Test 2: XSS 典型 payload -----
PAYLOAD_XSS="?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E"   # <script>alert(1)</script>
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${TARGET}${PAYLOAD_XSS}" \
  -H "User-Agent: chaos-c6-xss" --max-time 10)
echo "  XSS payload → HTTP $STATUS"
if [ "$STATUS" = "403" ]; then
  printf "  ${GREEN}PASS${NC} C6.2 XSS blocked by WAF (403)\n"
  PASS=$((PASS+1))
else
  printf "  ${YELLOW}WARN${NC} C6.2 XSS NOT blocked (status=%s).\n" "$STATUS"
  FAIL=$((FAIL+1))
fi

# ----- Test 3: 正常リクエスト (200 or 4xx 以外を許容、403 でないこと) -----
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${TARGET}" \
  -H "User-Agent: chaos-c6-normal" --max-time 10)
echo "  Normal request → HTTP $STATUS"
if [ "$STATUS" != "403" ]; then
  printf "  ${GREEN}PASS${NC} C6.3 Normal request NOT blocked (status=%s)\n" "$STATUS"
  PASS=$((PASS+1))
else
  printf "  ${RED}FAIL${NC} C6.3 Normal request blocked by WAF — over-broad rule\n"
  FAIL=$((FAIL+1))
fi

# ----- Sampled Requests を WAF console から取得して block を視覚化 -----
echo ""
echo "Recent sampled requests from WAF:"
aws wafv2 get-sampled-requests --region us-east-1 \
  --web-acl-arn "$WAF_ARN" \
  --rule-metric-name "${TF_ENV}-common-rule-set" \
  --scope CLOUDFRONT \
  --time-window "StartTime=$(date -u -d '5 minutes ago' +%s),EndTime=$(date -u +%s)" \
  --max-items 5 \
  --query 'SampledRequests[*].[Action,Request.URI,Request.Method]' \
  --output table 2>/dev/null || echo "  (sampled requests unavailable — WAF may be too new)"

echo ""
echo "==== C6 Result: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed/warn${NC} ===="
[ "$FAIL" -eq 0 ]
