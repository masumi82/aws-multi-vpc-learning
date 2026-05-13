#!/usr/bin/env bash
# C1: ECS タスクを 1 つ強制停止して、サービスが自動復旧することを確認
set -uo pipefail

REGION="${REGION:-ap-northeast-1}"
TF_ENV="${TF_ENV:-dev}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TF_DIR="${TF_DIR:-$ROOT/terraform/envs/$TF_ENV}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'

CLUSTER=$(terraform -chdir="$TF_DIR" output -raw ecs_cluster_name)
SERVICE=$(terraform -chdir="$TF_DIR" output -raw ecs_service_name)

echo "==== C1: Kill ECS task → self-heal verification ===="
echo "Cluster=$CLUSTER  Service=$SERVICE"

# 1. 現在の running task 一覧と desired_count を取得
DESIRED=$(aws ecs describe-services --region "$REGION" \
  --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].desiredCount' --output text)
echo "Desired count: $DESIRED"

TASKS=($(aws ecs list-tasks --region "$REGION" \
  --cluster "$CLUSTER" --service-name "$SERVICE" \
  --query 'taskArns[]' --output text))
echo "Current tasks: ${#TASKS[@]}"

if [ "${#TASKS[@]}" -lt 1 ]; then
  echo "${RED}FAIL${NC} no running tasks"; exit 1
fi

VICTIM="${TASKS[0]}"
VICTIM_ID=$(echo "$VICTIM" | rev | cut -d'/' -f1 | rev)
echo "Victim task: $VICTIM_ID"

# 2. タスクを強制停止
echo "Stopping task..."
aws ecs stop-task --region "$REGION" \
  --cluster "$CLUSTER" --task "$VICTIM" \
  --reason "Chaos C1 self-heal test" \
  --query 'task.lastStatus' --output text

# 3. 自動復旧をポーリング (最大 3 分)
START=$(date +%s)
DEADLINE=$((START + 180))
RECOVERED=0

echo "Waiting for self-heal (max 180s)..."
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  sleep 10
  RUNNING=$(aws ecs describe-services --region "$REGION" \
    --cluster "$CLUSTER" --services "$SERVICE" \
    --query 'services[0].runningCount' --output text)
  ELAPSED=$(( $(date +%s) - START ))
  echo "  [$ELAPSED s] running=$RUNNING / desired=$DESIRED"
  if [ "$RUNNING" = "$DESIRED" ]; then
    RECOVERED=1
    break
  fi
done

if [ "$RECOVERED" = "1" ]; then
  printf "${GREEN}PASS${NC} C1: Service recovered to desired=%s in %s s\n" "$DESIRED" "$ELAPSED"
else
  printf "${RED}FAIL${NC} C1: Did not recover in 180s (running=%s / desired=%s)\n" "$RUNNING" "$DESIRED"
  exit 1
fi
