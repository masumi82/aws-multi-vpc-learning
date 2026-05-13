#!/usr/bin/env bash
# C2: Aurora Writer を強制 failover → Reader が Writer に昇格することを確認
set -uo pipefail

REGION="${REGION:-ap-northeast-1}"
TF_ENV="${TF_ENV:-dev}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TF_DIR="${TF_DIR:-$ROOT/terraform/envs/$TF_ENV}"

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'

CLUSTER_ID="$TF_ENV-aurora-cluster"

echo "==== C2: Aurora forced failover ===="
echo "Cluster: $CLUSTER_ID"

# 1. 現在の Writer インスタンス取得
WRITER_BEFORE=$(aws rds describe-db-clusters --region "$REGION" \
  --db-cluster-identifier "$CLUSTER_ID" \
  --query 'DBClusters[0].DBClusterMembers[?IsClusterWriter==`true`].DBInstanceIdentifier | [0]' \
  --output text)
echo "Writer before: $WRITER_BEFORE"

# 2. Failover 実行
echo "Initiating failover..."
aws rds failover-db-cluster --region "$REGION" \
  --db-cluster-identifier "$CLUSTER_ID" >/dev/null

# 3. Writer 昇格をポーリング (最大 3 分)
START=$(date +%s)
DEADLINE=$((START + 180))
SUCCEEDED=0

while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  sleep 10
  STATUS=$(aws rds describe-db-clusters --region "$REGION" \
    --db-cluster-identifier "$CLUSTER_ID" \
    --query 'DBClusters[0].Status' --output text 2>/dev/null)
  WRITER_NOW=$(aws rds describe-db-clusters --region "$REGION" \
    --db-cluster-identifier "$CLUSTER_ID" \
    --query 'DBClusters[0].DBClusterMembers[?IsClusterWriter==`true`].DBInstanceIdentifier | [0]' \
    --output text 2>/dev/null)
  ELAPSED=$(( $(date +%s) - START ))
  echo "  [$ELAPSED s] status=$STATUS  writer=$WRITER_NOW"
  if [ "$STATUS" = "available" ] && [ -n "$WRITER_NOW" ] && [ "$WRITER_NOW" != "$WRITER_BEFORE" ]; then
    SUCCEEDED=1
    break
  fi
done

if [ "$SUCCEEDED" = "1" ]; then
  printf "${GREEN}PASS${NC} C2: Writer switched %s → %s in %s s\n" "$WRITER_BEFORE" "$WRITER_NOW" "$ELAPSED"
  echo "       Aurora cluster endpoint (no change): $(aws rds describe-db-clusters --region "$REGION" \
    --db-cluster-identifier "$CLUSTER_ID" --query 'DBClusters[0].Endpoint' --output text)"
else
  printf "${RED}FAIL${NC} C2: Failover did not complete in 180s\n"
  exit 1
fi
