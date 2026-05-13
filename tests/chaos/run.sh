#!/usr/bin/env bash
# Chaos engineering tests for Tier 1 HA verification
# 使い方:
#   TF_ENV=dev ./tests/chaos/run.sh c1            # 単一テスト
#   TF_ENV=dev ./tests/chaos/run.sh all           # C1-C4 (C5 は prod のみ)
#
# 前提: terraform apply 完了済み・Service が安定稼働している状態
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TF_ENV="${TF_ENV:-dev}"
TF_DIR="$ROOT/terraform/envs/$TF_ENV"
REGION="${AWS_REGION:-ap-northeast-1}"
TARGET="${1:-help}"

if [ ! -f "$TF_DIR/terraform.tfstate" ]; then
  echo "ERROR: $TF_DIR/terraform.tfstate not found. Run 'terraform apply' first."
  exit 2
fi

export TF_ENV TF_DIR REGION

case "$TARGET" in
  c1)  bash "$ROOT/tests/chaos/c1-kill-task.sh" ;;
  c2)  bash "$ROOT/tests/chaos/c2-aurora-failover.sh" ;;
  c3)  bash "$ROOT/tests/chaos/c3-cpu-load.sh" ;;
  c4)  bash "$ROOT/tests/chaos/c4-alarm-fire.sh" ;;
  c5)  bash "$ROOT/tests/chaos/c5-az-failure.sh" ;;
  all)
    bash "$ROOT/tests/chaos/c1-kill-task.sh"
    echo
    bash "$ROOT/tests/chaos/c2-aurora-failover.sh"
    echo
    bash "$ROOT/tests/chaos/c4-alarm-fire.sh"
    echo
    echo "Note: C3 (CPU load) と C5 (AZ failure) は時間がかかるため別途実行してください"
    ;;
  help|*)
    cat <<EOF
Usage: TF_ENV=dev $0 {c1|c2|c3|c4|c5|all|help}

  c1   ECS task kill → 自動復旧確認 (3 分)
  c2   Aurora Writer failover → reader 昇格 (3 分)
  c3   ECS CPU 負荷注入 → Auto Scaling (10 分)
  c4   CloudWatch alarm 強制発火 → SNS 通知 (3 分)
  c5   AZ 全タスク停止 → 残 AZ で継続稼働 (5 分・prod 推奨)
  all  c1 + c2 + c4 を順次実行
EOF
    ;;
esac
