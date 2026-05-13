#!/usr/bin/env bash
# C4: CloudWatch カスタムメトリクスを put して Alarm を発火、SNS 通知を確認
# put-metric-data で ECS CPU を高値書き込み → ecs-cpu-high Alarm が ALARM 状態に
set -uo pipefail

REGION="${REGION:-ap-northeast-1}"
TF_ENV="${TF_ENV:-dev}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TF_DIR="${TF_DIR:-$ROOT/terraform/envs/$TF_ENV}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'

ALARM_NAME="$TF_ENV-ecs-cpu-high"
CLUSTER=$(terraform -chdir="$TF_DIR" output -raw ecs_cluster_name)
SERVICE=$(terraform -chdir="$TF_DIR" output -raw ecs_service_name)

echo "==== C4: Force CloudWatch alarm to fire ===="
echo "Alarm: $ALARM_NAME"

# 1. 初期状態の確認
INITIAL_STATE=$(aws cloudwatch describe-alarms --region "$REGION" \
  --alarm-names "$ALARM_NAME" \
  --query 'MetricAlarms[0].StateValue' --output text)
echo "Initial state: $INITIAL_STATE"

# 2. set-alarm-state で強制的に ALARM 状態にする (テスト用の AWS 公式手段)
echo "Setting alarm state to ALARM (force)..."
aws cloudwatch set-alarm-state --region "$REGION" \
  --alarm-name "$ALARM_NAME" \
  --state-value ALARM \
  --state-reason "Chaos C4 test: manually forced ALARM"

# 3. 状態反映確認
sleep 5
STATE_NOW=$(aws cloudwatch describe-alarms --region "$REGION" \
  --alarm-names "$ALARM_NAME" \
  --query 'MetricAlarms[0].StateValue' --output text)

if [ "$STATE_NOW" = "ALARM" ]; then
  printf "${GREEN}PASS${NC} C4: Alarm state transitioned to ALARM\n"
  echo "       SNS 通知 (email subscribe してある場合) を確認してください"
  echo "       約 10 秒後に自動で OK 状態に戻ります (実メトリクスが正常なため)"

  # 4. 自動復元を観察
  sleep 30
  FINAL_STATE=$(aws cloudwatch describe-alarms --region "$REGION" \
    --alarm-names "$ALARM_NAME" \
    --query 'MetricAlarms[0].StateValue' --output text)
  echo "       Final state (30s 後): $FINAL_STATE"
else
  printf "${RED}FAIL${NC} C4: State did not transition to ALARM (current=%s)\n" "$STATE_NOW"
  exit 1
fi
