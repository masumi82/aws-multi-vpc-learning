# Chaos Engineering Tests

> Tier 1 HA の **動的挙動** を検証する。
> 既存の Integration テスト (静的・存在確認) と対をなす **動的・障害注入テスト**。

## 前提

- `terraform apply` が完了し、Service が安定稼働している
- `aws ecs execute-command` (Session Manager Plugin) がローカルで動作する (C3 のみ必須)
- 検証コストは別途発生 (デフォルト所要 ~20 分で約 \$0.50)

## シナリオ一覧

| ID | スクリプト | 検証 | 所要 | 副作用 |
|---|---|---|---|---|
| C1 | `c1-kill-task.sh` | タスク 1 個強制停止 → 自動補充 | 3 分 | 一時的に running < desired |
| C2 | `c2-aurora-failover.sh` | Aurora Writer failover | 3 分 | 約 30 秒の DB 接続切断 |
| C3 | `c3-cpu-load.sh` | ECS Exec で CPU 負荷 → Auto Scaling | 10 分 | CPU 100%、タスク数増加 |
| C4 | `c4-alarm-fire.sh` | `set-alarm-state` で Alarm 発火 | 3 分 | SNS 通知発行 |
| C5 | `c5-az-failure.sh` | 特定 AZ の全タスク停止 | 5 分 | 該当 AZ 一時的に 0 task |

## 使い方

```bash
# 単一テスト
TF_ENV=dev ./tests/chaos/run.sh c1

# まとめて (C1+C2+C4。C3 と C5 は時間かかるので別途)
TF_ENV=dev ./tests/chaos/run.sh all

# prod で AZ 障害シミュレーション
TF_ENV=prod TARGET_AZ=ap-northeast-1c ./tests/chaos/run.sh c5
```

## 各シナリオの詳細

### C1: ECS task self-heal
**目的**: ECS Service の **deployment + auto-replacement** が機能していることを確認

- 1 タスクを `stop-task` で強制停止
- Service が新タスクを起動し、`runningCount` が `desiredCount` に戻るまでの時間を計測
- Tier 0 でも動作するが、Tier 1 では特に **Auto Scaling との競合** が起きないことも確認できる

期待: 60-120 秒以内に復旧

### C2: Aurora forced failover
**目的**: Multi-AZ Aurora の **自動 failover** 機能を確認

- `failover-db-cluster` で Writer を強制切替
- 新 Writer は別の Reader インスタンスから昇格
- **Writer Endpoint は変わらない** (DNS 透過)

期待: 30 秒以内に新 Writer が available 状態

注意: 進行中のトランザクションは失敗する (アプリのリトライ設計が必要)

### C3: Auto Scaling under load
**目的**: Application Auto Scaling の **target tracking** が機能することを確認

- `ECS Exec` でコンテナに入り `yes > /dev/null` を 4 並列で起動 → CPU 100%
- CPU > 70% (target) を 2 分以上維持 → Auto Scaling が +1 task
- 6 分間負荷をかけ続けて拡張を観測

期待: `desired_count` が初期値より増える

注意: nginx:stable のコンテナに stress-ng は無いので `yes` で代用。本物の API なら別の方法 (HTTP リクエスト負荷) も検討

### C4: Alarm fire
**目的**: CloudWatch Alarm + SNS の **通知パス**が機能することを確認

- `set-alarm-state` で `ecs-cpu-high` Alarm を強制的に `ALARM` 状態に
- SNS topic が email subscribe されていれば通知が届く
- 実メトリクスは正常なので、約 30 秒後に `OK` に自動復帰

期待: 状態遷移確認 + (subscribe 済みなら) email 着信

### C5: AZ failure simulation
**目的**: AZ 単位の障害でも残り 2 AZ で稼働継続することを確認

- 特定 AZ (デフォルト 1a) の全タスクを `stop-task`
- 残 AZ で Service が動き続けることを確認
- Auto Scaling / Deployment が補充タスクを **同じ AZ または別 AZ に分散配置**

期待: 5 分以内に元の `desired_count` に復帰。新タスクが 3 AZ に均等分散

prod (desired=3, NAT/AZ ごと) での実行を推奨。dev (desired=1) では意味が薄い。

## 失敗時のトラブルシュート

| シナリオ | 失敗パターン | 対処 |
|---|---|---|
| C1 | 60s 経っても補充されない | `aws ecs describe-services` の events を確認、IAM 権限 / TaskDef エラー |
| C2 | failover が `available` まで行かない | Aurora の状態が `failing-over` で詰まる場合あり、`pending-maintenance-action` も確認 |
| C3 | スケールアウトしない | `application-autoscaling describe-scaling-policies` で target_value 確認、CPU 計測の 5 分間平均が target を超えているか確認 |
| C3 | ECS Exec エラー | Session Manager Plugin インストール: `curl https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb -o /tmp/smp.deb && sudo dpkg -i /tmp/smp.deb` |
| C4 | 通知が届かない | SNS subscription が confirmed か (初回 email 確認必須)、`alert_email` 変数を設定して再 apply |
| C5 | 一部 AZ にタスクが寄る | Service の `placementStrategy` 確認、デフォルトは spread。`capacity_provider_strategy` を見直し |

## クリーンアップ

カオステスト後は **状態が散らかる** ことがあるので、確認:

```bash
# サービス安定確認
aws ecs describe-services --cluster $(terraform -chdir=terraform/envs/dev output -raw ecs_cluster_name) \
  --services $(terraform -chdir=terraform/envs/dev output -raw ecs_service_name) \
  --query 'services[0].[runningCount,desiredCount,deployments[0].rolloutState]'

# Auto Scaling 余分なタスクの縮退待ち (~10 分)
```
