#!/usr/bin/env bash
# C3: CPU 負荷を ECS Exec 経由でコンテナに注入 → Auto Scaling 拡張を確認
set -uo pipefail

REGION="${REGION:-ap-northeast-1}"
TF_ENV="${TF_ENV:-dev}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TF_DIR="${TF_DIR:-$ROOT/terraform/envs/$TF_ENV}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'

CLUSTER=$(terraform -chdir="$TF_DIR" output -raw ecs_cluster_name)
SERVICE=$(terraform -chdir="$TF_DIR" output -raw ecs_service_name)
DURATION=${LOAD_DURATION:-360} # デフォルト 6 分

echo "==== C3: ECS Auto Scaling under CPU load ===="
echo "Cluster=$CLUSTER  Service=$SERVICE"

# 1. 初期 desired_count を記録
DESIRED_INITIAL=$(aws ecs describe-services --region "$REGION" \
  --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].desiredCount' --output text)
echo "Initial desired_count: $DESIRED_INITIAL"

# 2. nginx は yes コマンドが入ってないので apt 必要、別アプローチ: dd で CPU 負荷
# Fargate コンテナ内で複数プロセス並列起動して CPU を 100% にする
TASK=$(aws ecs list-tasks --region "$REGION" \
  --cluster "$CLUSTER" --service-name "$SERVICE" \
  --query 'taskArns[0]' --output text)
TASK_ID=$(echo "$TASK" | rev | cut -d'/' -f1 | rev)
echo "Target task: $TASK_ID"

# 3. ECS Exec で CPU 負荷起動 (バックグラウンド・$DURATION 秒で自動停止)
echo "${YELLOW}Injecting CPU load for ${DURATION}s via ECS Exec...${NC}"
echo "(Auto Scaling は scale-out cooldown 60s、評価期間 2x60s = 約 2-3 分で反応)"

# nginx:stable には busybox があるので yes >/dev/null で CPU 焼く
# nproc で物理 CPU 数取得して並列起動
LOAD_CMD="(for i in 1 2 3 4; do yes > /dev/null & done; sleep $DURATION; pkill yes; echo done)"

aws ecs execute-command --region "$REGION" \
  --cluster "$CLUSTER" --task "$TASK_ID" --container app \
  --interactive --command "/bin/sh -c \"$LOAD_CMD\"" &
EXEC_PID=$!
echo "ECS Exec PID: $EXEC_PID"

# 4. desired_count の増加をポーリング
START=$(date +%s)
DEADLINE=$((START + DURATION + 120))
SCALED_OUT=0
MAX_OBSERVED=$DESIRED_INITIAL

while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  sleep 30
  DESIRED_NOW=$(aws ecs describe-services --region "$REGION" \
    --cluster "$CLUSTER" --services "$SERVICE" \
    --query 'services[0].desiredCount' --output text)
  CPU=$(aws cloudwatch get-metric-statistics --region "$REGION" \
    --namespace AWS/ECS --metric-name CPUUtilization \
    --dimensions Name=ClusterName,Value="$CLUSTER" Name=ServiceName,Value="$SERVICE" \
    --start-time "$(date -u -d '5 minutes ago' '+%Y-%m-%dT%H:%M:%SZ')" \
    --end-time "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --period 60 --statistics Maximum \
    --query 'Datapoints[-1].Maximum' --output text 2>/dev/null)
  ELAPSED=$(( $(date +%s) - START ))
  echo "  [$ELAPSED s] desired=$DESIRED_NOW  recent CPU max=$CPU"
  if [ "$DESIRED_NOW" -gt "$MAX_OBSERVED" ]; then
    MAX_OBSERVED=$DESIRED_NOW
    SCALED_OUT=1
  fi
done

# ECS Exec の終了待ち
wait $EXEC_PID 2>/dev/null || true

if [ "$SCALED_OUT" = "1" ]; then
  printf "${GREEN}PASS${NC} C3: Auto Scaling fired. Max observed desired_count = %s (initial=%s)\n" "$MAX_OBSERVED" "$DESIRED_INITIAL"
  echo "       Scale-in は約 5 分後に始まる予定。終了時の状態確認:"
  aws ecs describe-services --region "$REGION" --cluster "$CLUSTER" --services "$SERVICE" \
    --query 'services[0].[desiredCount,runningCount]' --output text
else
  printf "${YELLOW}WARN${NC} C3: No scale-out observed. 確認ポイント:\n"
  echo "  - Auto Scaling target が登録されているか (Integration test I25)"
  echo "  - CPU 負荷が実際に上がったか (CloudWatch 数値)"
  echo "  - target_value=70 を超えていない可能性"
  exit 1
fi
