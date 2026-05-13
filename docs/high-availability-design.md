# 冗長性強化設計書

> 既存構成 (`docs/architecture.md`) を **Tier 0** とし、5 段階で冗長性を強化する設計案。
> リージョン: Primary `ap-northeast-1` (Tokyo) / Secondary `ap-northeast-3` (Osaka)
> 用途: 学習・実務設計検討の両用

---

## 1. 現状の SPOF (Tier 0) 棚卸し

既存の構成で実は **単一障害点 (SPOF)** が残っている箇所:

| 箇所 | 影響範囲 | 学習用での許容 |
|---|---|---|
| **NAT Gateway が 1a のみ** | 1a 障害で App の外向き通信 (ECR/SSM/Secrets) 全停止 | ✓ (コスト優先) |
| **シングルリージョン** | ap-northeast-1 障害でサービス全停止 | ✓ (DR 練習対象外) |
| **CloudFront → 単一 ALB** | ALB 障害でフロント全停止 (リージョン障害と同義) | ✓ |
| **Aurora 単一クラスタ** | Aurora 障害 / リージョン障害で DB アクセス停止 | ✓ |
| **S3 単一バケット** | バケット削除事故やリージョン障害でコンテンツ消失 | ✓ |
| **DNS フェイルオーバー無** | Route 53 なし、自動切替なし | ✓ |
| **ECS タスク数 固定** | 負荷スパイクで遅延 / 一斉障害で復旧遅い | ✓ |
| **WAF / Shield 無** | DDoS / SQL Injection 等の攻撃に無防備 | ✓ |
| **ログ・監視最小限** | 障害検知が遅れる | ✓ |

→ 個人学習スコープでは全て **許容済み**。本書は「**もし冗長性を上げるとしたら**」の設計案。

---

## 2. 強化ロードマップ (5 Tier)

| Tier | 名前 | 主目的 | 月額差分 (dev1環境) | RPO | RTO |
|---|---|---|---|---|---|
| **0** | 現状 | 学習 / 最小コスト | $0 (base ~$330) | N/A | N/A |
| **1** | Within-Region フル冗長 | 単一 AZ 障害対応 | **+$120** | 1 分 | 5 分 |
| **2** | 防御層強化 | DDoS / 攻撃耐性 | **+$50** | 1 分 | 5 分 |
| **3** | Multi-Region Warm Standby | リージョン障害対応 (DR) | **+$280** | 1 分 | 15 分 |
| **4** | Multi-Region Active-Active | 災害ゼロ・低レイテンシ | **+$500** | 1 分 | 数秒 |
| **5** | エンタープライズ (Cell + Multi-Account) | 障害分離 + コンプライアンス | **+$1,000+** | 1 分 | 数秒 |

> 月額は dev 環境ベース。Prod も同等構成にする場合は約 2 倍。

---

## 3. Tier 1: Within-Region フル冗長

**目的**: 単一 AZ 障害 (例: 1a 全断) でもサービス継続。

### 変更点

| Component | Before (Tier 0) | After (Tier 1) |
|---|---|---|
| NAT Gateway | 1a のみ 1 台 | **各 AZ に 1 台 (合計 3)** |
| NAT 用 EIP | 1 個 | 3 個 |
| Route Table (App) | 1 個・全 AZ で同じ NAT 参照 | **AZ ごとに 1 個・同 AZ の NAT を参照** |
| Aurora Reader | 2 台 | **3 台 (各 AZ に 1 台)** |
| ECS desired_count | 2 | **3 (各 AZ に分散) + Auto Scaling 有効** |
| ALB cross_zone_load_balancing | デフォルト無効 | **有効** (一部 TG タイプはデフォルト有効) |
| CloudWatch Alarm | なし | **ECS CPU / ALB 5xx / Aurora CPU で SNS 通知** |
| ECS Auto Scaling Target Tracking | なし | **CPU 70% で +1 task** |

### 新規追加 Terraform リソース

```
modules/network: aws_eip × 3, aws_nat_gateway × 3, aws_route_table × 3
modules/aurora:  reader_count = 3
modules/ecs:     aws_appautoscaling_target + aws_appautoscaling_policy
modules/monitoring (新規): aws_sns_topic + aws_cloudwatch_metric_alarm × 5
modules/alb:     cross_zone_load_balancing = true
```

### コスト内訳 (dev 1 環境追加分)

| 項目 | 単価 | 月額追加 |
|---|---|---|
| NAT Gateway × 2 (追加分) | $0.062/h × 2 | +$90 |
| Aurora Reader × 1 追加 | $0.113/h | +$80 (db.t4g.medium) → **t4g.small に変更で +$40** |
| CloudWatch Alarm × 5 | $0.10/月 × 5 | +$0.5 |
| SNS 通知 | ほぼ無料枠 | +$0 |
| **合計** | | **+$120/月** |

### 効果

- ✅ 1a 障害時、1c / 1d の App + NAT で継続稼働
- ✅ Aurora Writer 自動フェイルオーバー (30 秒) + Reader 2 台で読み継続
- ✅ ECS 自動的に AZ 分散維持

---

## 4. Tier 2: 防御層強化

**目的**: 外部攻撃耐性 / 観測性向上。冗長性ではないが、可用性に直結する。

### 追加コンポーネント

| Component | 役割 | 月額 |
|---|---|---|
| **AWS WAF v2** (CloudFront 紐付け) | OWASP Top 10 / Bot / Rate Limiting | $5 + $1/100 万 req |
| **AWS Shield Standard** | DDoS L3/L4 (自動有効) | 無料 |
| **AWS Shield Advanced** (任意) | L7 DDoS + 24/7 サポート + DDRT | $3,000/月 (学習スコープ外) |
| **VPC Flow Logs** (CloudWatch) | ネットワーク証跡 | $2-5 |
| **GuardDuty** | 異常検知 (マルウェア・暗号通貨マイニング 等) | $30 (検証期間限定なら無料枠あり) |
| **KMS Customer Managed Key** | Aurora / S3 / Logs の暗号化キーを自己管理 | $1 + $0.03/10k 操作 |
| **Secrets Manager Rotation** | DB パスワード自動ローテーション | $0.4/月 |

### WAF Managed Rules (推奨)

- `AWSManagedRulesCommonRuleSet` — XSS / SQLi / LFI
- `AWSManagedRulesKnownBadInputsRuleSet`
- `AWSManagedRulesAmazonIpReputationList`
- 自前: Rate-based Rule (5 分間 2000 リクエストで block)

### 新規追加 Terraform リソース

```
modules/waf (新規):
  aws_wafv2_web_acl + Managed Rule Group + Rate-based Rule
  aws_wafv2_web_acl_association (CloudFront に紐付け)

modules/monitoring (拡張):
  aws_flow_log (VPC Flow Logs)
  aws_guardduty_detector
  aws_kms_key + aws_kms_alias
```

---

## 5. Tier 3: Multi-Region Warm Standby (DR)

**目的**: リージョン全体障害 (極めて稀だが過去事例あり) でもサービス継続。

### 構成

```
Primary:   ap-northeast-1 (Tokyo)   ← 通常時 100% トラフィック
Secondary: ap-northeast-3 (Osaka)   ← Warm Standby (Aurora Global Reader + ECS 最小台数)
```

### 追加コンポーネント

| Component | 採用 |
|---|---|
| **Aurora Global Database** | Primary cluster + Secondary read-only cluster (Osaka)、レプリケーション遅延 < 1 秒 |
| **CloudFront Origin Group** | Primary = Tokyo ALB / Secondary = Osaka ALB、5xx で自動 failover |
| **Route 53 Health Check + Failover Routing** | CloudFront ドメインを ALIAS、ヘルスチェック失敗で Secondary に切替 |
| **S3 Cross-Region Replication (CRR)** | Tokyo S3 → Osaka S3、データ消失耐性 |
| **ECR Cross-Region Replication** | コンテナイメージを両 region で利用可能に |
| **Secrets Manager Multi-Region Secret** | DB パスワードを両 region 同期 |

### Pilot Light vs Warm Standby

- **Pilot Light**: Secondary は最小限 (Aurora Reader だけ常時、ECS は 0)。failover 時に ECS を起動 (5 分追加)
- **Warm Standby (採用)**: Secondary も ECS 1 task 常時起動。failover 即座 (15 分 RTO)

### コスト内訳 (Warm Standby)

| 項目 | Tokyo (Primary) | Osaka (Secondary) | 合計増分 |
|---|---|---|---|
| Aurora Global Cluster | 既存 | +$80 (Reader 1 台) | +$80 |
| ECS Fargate | 既存 | +$5 (1 task) | +$5 |
| ALB | 既存 | +$20 | +$20 |
| NAT (Tier 1 想定) | 既存 | +$135 | +$135 |
| S3 CRR + ストレージ | 既存 | +$5 | +$5 |
| CloudWatch | 既存 | +$5 | +$5 |
| Route 53 Health Check | $0.50/check | $0.50/check | +$1 |
| Data Transfer (cross-region) | — | $0.09/GB | +$30 |
| **合計** | | | **+$280/月** |

### Failover シナリオ

1. **Tokyo 全停止検知** (Route 53 Health Check 3 回連続失敗 = 60-180 秒)
2. **DNS 切替** (Route 53 が Osaka ALB に向ける)
3. **Aurora Global DB の手動昇格** (Osaka Reader → Writer 昇格) ← 完全自動化されてないので運用 Runbook 必須
4. **ECS Service desired_count を増やす** (Auto Scaling Group が自動 or 手動)
5. **トラフィック再開** (~15 分)

### Aurora Global Database の重要な制約

- ⚠️ **書き込みは Primary cluster のみ** (Secondary は read-only)
- ⚠️ Secondary を Writer に昇格させる = "Detach"、再構築に時間がかかる
- ⚠️ Cross-Region レプリケーション遅延 ~1 秒、ピーク時 ~5 秒。**RPO は 1-5 秒**

---

## 6. Tier 4: Multi-Region Active-Active

**目的**: 両 region がトラフィックを受ける。ユーザー近接で低レイテンシ。

### 構成

```
Tokyo:  通常時 70% トラフィック (日本)
Osaka:  通常時 30% トラフィック (西日本) + Failover backup
```

### 追加変更 (Tier 3 から)

| Component | Tier 3 (Warm) | Tier 4 (Active-Active) |
|---|---|---|
| Route 53 Routing | Failover | **Latency-based Routing** |
| ECS Service (Osaka) | 1 task | **Tokyo と同等の台数** |
| Aurora Writer | Tokyo のみ | Tokyo のみ (制約) / または **Aurora Global Write Forwarding** |
| CloudFront | Origin Group (failover) | **両 Origin が常時 healthy、Origin Group で fallback** |

### 書き込みパスの設計選択

| パターン | 概要 | レイテンシ |
|---|---|---|
| **Write to Primary only** (推奨) | アプリ層で「書き込みは Tokyo Aurora endpoint」 | 大阪→東京 ~10 ms |
| **Aurora Write Forwarding** | Secondary cluster に書き込めるが内部で Primary に転送 | 同上、設定はシンプル |
| **Active-Active DB (DynamoDB Global Tables 等)** | Aurora をやめて DynamoDB に切替 | サブミリ秒 |

### コスト内訳 (Active-Active)

| 項目 | 月額追加 (Tier 3 比) |
|---|---|
| Osaka ECS Auto Scaling 拡張 (3 task 常時) | +$50 |
| Osaka NAT 既存活用 (変更なし) | $0 |
| Osaka Aurora Reader 増 (1→2) | +$80 |
| Data Transfer (両方向トラフィック増) | +$80 |
| Cross-Region Aurora Replication (高頻度) | +$10 |
| **合計** | **Tier 3 + $220 = +$500/月 (Tier 0 比)** |

### 効果

- ✅ **低レイテンシ** (関西ユーザーは Osaka に直接)
- ✅ **障害時即切替** (Route 53 latency-based は自動的に健全 region を選ぶ)
- ✅ **キャパシティ 2 倍** (片 region がフルダウンしても残 region で全トラフィック吸収)

---

## 7. Tier 5: エンタープライズ (参考)

**目的**: 業界規制 / 大企業要件 / 数百万ユーザー級。学習スコープ外だが概念として記載。

| 概念 | 概要 |
|---|---|
| **Multi-Account** | dev / staging / prod を AWS Organizations の別アカウントに分離。Control Tower で統制 |
| **Cell-based Architecture** | サービスを N 個の独立した「セル」に分割、1 セル障害が全体に波及しない |
| **Shuffle Sharding** | ユーザーをランダムなセル組み合わせに割り当て、障害ブラスト半径を縮小 |
| **Service Mesh (App Mesh / Istio)** | サービス間通信の暗号化・観測・トラフィック制御 |
| **Chaos Engineering** (Fault Injection Simulator) | 定期的に障害を意図的に注入して耐性を検証 |

---

## 8. RPO / RTO 比較

| Tier | RPO (データ損失許容) | RTO (復旧時間) | 想定対応シナリオ |
|---|---|---|---|
| 0 (現状) | 数時間 (自動バックアップ最古) | 数時間〜半日 | 学習 / 個人開発 |
| 1 | 1 分 (Aurora 自動 failover) | 5 分 | 中小規模 web サービス |
| 2 | 1 分 | 5 分 | 攻撃を受ける可能性のあるサービス |
| 3 | 1-5 秒 (Aurora Global レプリ遅延) | 15 分 | 業務システム / 一般的な enterprise |
| 4 | 1-5 秒 | 数秒〜数十秒 | グローバル B2C / 金融バックエンド |
| 5 | 1 秒未満 | 数秒 | 銀行 / 決済 / 大規模 SaaS |

---

## 9. SPOF 排除チェックリスト

| SPOF | Tier 0 | Tier 1 | Tier 2 | Tier 3 | Tier 4 |
|---|---|---|---|---|---|
| 単一 NAT GW | ❌ | ✅ | ✅ | ✅ | ✅ |
| 単一 AZ ECS タスク | ✅ (3 AZ 分散) | ✅ | ✅ | ✅ | ✅ |
| ECS 容量不足 | ❌ | ✅ (Auto Scaling) | ✅ | ✅ | ✅ |
| Aurora AZ 障害 | ✅ (Multi-AZ Reader) | ✅ | ✅ | ✅ | ✅ |
| DDoS 攻撃 | ❌ | ❌ | ✅ (WAF) | ✅ | ✅ |
| アプリ脆弱性 | ❌ | ❌ | ✅ (WAF + GuardDuty) | ✅ | ✅ |
| リージョン障害 | ❌ | ❌ | ❌ | ✅ (Warm Standby) | ✅ (Active-Active) |
| S3 データ消失 | ❌ | ❌ | ❌ | ✅ (CRR) | ✅ |
| DNS フェイルオーバー無 | ❌ | ❌ | ❌ | ✅ (Route 53 HC) | ✅ |
| アカウント侵害 | ❌ | ❌ | ❌ | ❌ | ✅ (Multi-Account, Tier 5) |

---

## 10. 学習ロードマップ (推奨順序)

各 Tier を **dev 環境で 1 時間ずつ apply → 確認 → destroy** で体験するのが効率的。

| Step | やること | 学習価値 | 所要 |
|---|---|---|---|
| 1 | **Tier 1 を dev に apply** | Auto Scaling / マルチ AZ NAT の挙動を見る | 30 分 |
| 2 | **意図的に 1a の Task を kill** | Auto Scaling が補充するのを観察 | 10 分 |
| 3 | **Tier 2 (WAF) を追加** | WAF rule を curl で叩いて block を確認 | 30 分 |
| 4 | **Tier 3 を別 dev (Osaka) に apply** | Aurora Global Database のレプリケーション遅延を観察 | 1 時間 |
| 5 | **Primary を destroy → Failover を実行** | DR Runbook を実際に叩く | 30 分 |
| 6 | **Tier 4 に拡張** | Route 53 latency routing で実際にレイテンシ差を測定 | 30 分 |
| 7 | **全部 destroy** | コスト止め | 30 分 |

**所要合計**: 約 4 時間 / コスト合計 **約 $20** (テスト時間が短ければ)

---

## 11. Terraform 実装インパクト

各 Tier で必要な変更を要約。すべて既存の `modules/` パターンに沿った追加。

### Tier 1

```hcl
# modules/network/main.tf
resource "aws_eip" "nat" { count = 3 }
resource "aws_nat_gateway" "this" { count = 3, subnet_id = ... }
resource "aws_route_table" "app" { count = 3, route { nat_gateway_id = aws_nat_gateway.this[count.index].id } }

# modules/aurora/variables.tf
variable "reader_count" { default = 3 }   # was 2

# modules/ecs/main.tf
resource "aws_appautoscaling_target" "ecs" { ... }
resource "aws_appautoscaling_policy" "cpu" { ... }

# modules/monitoring/main.tf (NEW)
resource "aws_sns_topic" "alerts" {}
resource "aws_cloudwatch_metric_alarm" "ecs_cpu" {}
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {}
resource "aws_cloudwatch_metric_alarm" "aurora_cpu" {}
```

### Tier 2

```hcl
# modules/waf/main.tf (NEW)
resource "aws_wafv2_web_acl" "cloudfront" {
  scope = "CLOUDFRONT"
  default_action { allow {} }
  rule {
    name = "AWSManagedRulesCommonRuleSet"
    statement { managed_rule_group_statement { name = "AWSManagedRulesCommonRuleSet", vendor_name = "AWS" } }
  }
  rule { name = "RateLimit", ... rate_based_statement { limit = 2000, aggregate_key_type = "IP" } }
}
# us-east-1 provider alias 必須 (CloudFront 紐付け)

resource "aws_flow_log" "vpc" { ... }
resource "aws_guardduty_detector" "this" {}
resource "aws_kms_key" "main" {}
```

### Tier 3

新規 `terraform/envs/dev-osaka/` ディレクトリ + `modules/aurora_global/` (新規)。

```hcl
# modules/aurora_global/main.tf (NEW)
resource "aws_rds_global_cluster" "this" {
  global_cluster_identifier = "app-global"
  engine                    = "aurora-postgresql"
  engine_version            = "15.X"
}

# Primary cluster (Tokyo)
resource "aws_rds_cluster" "primary" {
  global_cluster_identifier = aws_rds_global_cluster.this.id
  ...
}

# Secondary cluster (Osaka, dev-osaka 配下)
resource "aws_rds_cluster" "secondary" {
  global_cluster_identifier = aws_rds_global_cluster.this.id
  source_region             = "ap-northeast-1"
  ...
}

# modules/cloudfront_s3/main.tf を拡張
resource "aws_cloudfront_distribution" "this" {
  origin_group {
    origin_id = "alb-failover-group"
    failover_criteria { status_codes = [500, 502, 503, 504] }
    member { origin_id = local.alb_tokyo_origin_id }
    member { origin_id = local.alb_osaka_origin_id }
  }
  ...
}

resource "aws_route53_health_check" "tokyo" { ... }
resource "aws_route53_record" "primary" { failover_routing_policy { type = "PRIMARY" } ... }
resource "aws_route53_record" "secondary" { failover_routing_policy { type = "SECONDARY" } ... }

# S3 Cross-Region Replication
resource "aws_s3_bucket_replication_configuration" "tokyo_to_osaka" { ... }
```

### Tier 4

Route 53 を **Failover → Latency-based** に変更、Osaka 側の ECS `desired_count` を Tokyo と同じに。

---

## 12. 個人学習用の推奨アプローチ

**全部やる必要はありません**。学習目的に応じて 1-2 個ピックアップで充分価値ある。

### 短時間 (1 時間): Tier 1 のみ
- NAT GW × 3 + Auto Scaling
- 単一 AZ 障害をシミュレートして観察
- 追加コスト +$120/月 / 1 時間検証なら +$0.17

### 中時間 (4 時間): Tier 1 → 3 一気通貫
- マルチ AZ + WAF + マルチ region DR
- Aurora Global Database のレプリケーション遅延を実測
- 追加コスト +$280/月 / 4 時間検証なら +$1.6

### 学習ジャーニー (1 ヶ月): Tier 1 → 5 段階的
- 各 Tier を週末ごとに 1 つ
- 「壊して直す」をひたすら繰り返す
- 追加コスト 1 セッション ~$2、計 ~$20

---

## 13. 図解 (Tier 3 Multi-Region Warm Standby)

`docs/architecture-ha-tier3.puml` に PlantUML 図を別途配置 (本書とセット)。

---

## 14. 次のアクション候補

1. **Tier 1 だけ実装してみる** → 既存 modules への追記のみで完結、学習効率最高
2. **Tier 3 まで設計を起こす** → 本書ベースで Terraform 化、apply で実体験
3. **WAF だけ Tier 2 から先取り** → コスト最小で攻撃耐性体験

最も学習効率が高いのは **Tier 1 → 短時間 destroy → Tier 3 へ拡張 → 即 destroy** のコンボです。
