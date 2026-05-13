#!/usr/bin/env bash
# C5: 特定 AZ の全タスクを停止 → 残 AZ で稼働継続、ASG が AZ 分散を維持
# prod 環境 (desired_count=3, 各 AZ 1 task) で動かすことを想定
set -uo pipefail

REGION="${REGION:-ap-northeast-1}"
TF_ENV="${TF_ENV:-dev}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TF_DIR="${TF_DIR:-$ROOT/terraform/envs/$TF_ENV}"
TARGET_AZ="${TARGET_AZ:-ap-northeast-1a}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'

CLUSTER=$(terraform -chdir="$TF_DIR" output -raw ecs_cluster_name)
SERVICE=$(terraform -chdir="$TF_DIR" output -raw ecs_service_name)

echo "==== C5: Simulate AZ failure by killing all tasks in $TARGET_AZ ===="
echo "Cluster=$CLUSTER  Service=$SERVICE  Target AZ=$TARGET_AZ"

if [ "$TF_ENV" = "dev" ]; then
  printf "${YELLOW}WARN${NC} dev は desired_count が低いため、AZ 障害シミュレーションは prod 推奨\n"
fi

# 1. AZ ごとのタスクを取得
ALL_TASKS=($(aws ecs list-tasks --region "$REGION" \
  --cluster "$CLUSTER" --service-name "$SERVICE" \
  --query 'taskArns[]' --output text))

TARGETS=()
for TASK in "${ALL_TASKS[@]}"; do
  AZ=$(aws ecs describe-tasks --region "$REGION" --cluster "$CLUSTER" --tasks "$TASK" \
    --query 'tasks[0].availabilityZone' --output text 2>/dev/null)
  if [ "$AZ" = "$TARGET_AZ" ]; then
    TARGETS+=("$TASK")
  fi
done

echo "Tasks in $TARGET_AZ: ${#TARGETS[@]}"

if [ "${#TARGETS[@]}" = "0" ]; then
  printf "${YELLOW}SKIP${NC} No tasks running in $TARGET_AZ\n"
  exit 0
fi

# 2. ターゲット AZ のタスクを全停止
for T in "${TARGETS[@]}"; do
  ID=$(echo "$T" | rev | cut -d'/' -f1 | rev)
  echo "Stopping $ID..."
  aws ecs stop-task --region "$REGION" --cluster "$CLUSTER" --task "$T" \
    --reason "Chaos C5 AZ failure simulation" >/dev/null
done

# 3. 復旧をポーリング (最大 5 分)
DESIRED=$(aws ecs describe-services --region "$REGION" --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].desiredCount' --output text)
START=$(date +%s)
DEADLINE=$((START + 300))

while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  sleep 15
  RUNNING=$(aws ecs describe-services --region "$REGION" \
    --cluster "$CLUSTER" --services "$SERVICE" \
    --query 'services[0].runningCount' --output text)
  ELAPSED=$(( $(date +%s) - START ))

  # AZ 分布カウント
  AZS=$(aws ecs list-tasks --region "$REGION" --cluster "$CLUSTER" --service-name "$SERVICE" \
    --query 'taskArns[]' --output text 2>/dev/null | tr '\t' '\n' | \
    while read T; do
      [ -n "$T" ] && aws ecs describe-tasks --region "$REGION" --cluster "$CLUSTER" --tasks "$T" \
        --query 'tasks[0].availabilityZone' --output text 2>/dev/null
    done | sort | uniq -c | tr '\n' ';')
  echo "  [$ELAPSED s] running=$RUNNING/$DESIRED  AZ distribution: $AZS"
  if [ "$RUNNING" = "$DESIRED" ]; then
    printf "${GREEN}PASS${NC} C5: All tasks back to running in %s s. AZ 分散: %s\n" "$ELAPSED" "$AZS"
    exit 0
  fi
done

printf "${RED}FAIL${NC} C5: Did not recover to desired=%s in 300s\n" "$DESIRED"
exit 1
