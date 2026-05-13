#!/usr/bin/env bash
# テスト全体のオーケストレーター
# 使い方:
#   ./tests/run-all.sh static                 # apply 前
#   ./tests/run-all.sh integration            # apply 後 (TF_ENV=dev デフォルト)
#   ./tests/run-all.sh e2e                    # apply 後 + index.html 配置
#   ./tests/run-all.sh all                    # 全部
#   TF_ENV=prod ./tests/run-all.sh integration
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-static}"
TF_ENV="${TF_ENV:-dev}"

run_static()       { bash "$ROOT/static/run.sh"; }
run_integration()  { TF_ENV="$TF_ENV" bash "$ROOT/integration/run.sh"; }
run_e2e()          { TF_ENV="$TF_ENV" bash "$ROOT/e2e/run.sh"; }
run_chaos()        { TF_ENV="$TF_ENV" bash "$ROOT/chaos/run.sh" "${2:-all}"; }

case "$TARGET" in
  static)      run_static ;;
  integration) run_integration ;;
  e2e)         run_e2e ;;
  chaos)       run_chaos "$@" ;;
  all)
    run_static
    echo
    run_integration
    echo
    run_e2e
    ;;
  *)
    cat <<EOF
Usage: $0 {static|integration|e2e|chaos|all}

  static       コード品質チェック (apply 不要)
  integration  AWS リソース存在確認 (apply 後)
  e2e          ブラウザ E2E (apply 後 + Deployed 後)
  chaos [c1-c5|all]  Tier 1 HA 動的検証 (障害注入)
  all          static + integration + e2e (chaos は別途実行)

env: TF_ENV=dev|prod (default dev)

例:
  ./tests/run-all.sh static
  TF_ENV=dev ./tests/run-all.sh integration
  TF_ENV=dev ./tests/run-all.sh chaos c1
  TF_ENV=prod ./tests/run-all.sh chaos c5
EOF
    exit 2
    ;;
esac
