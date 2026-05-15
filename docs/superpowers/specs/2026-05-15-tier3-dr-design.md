# Tier 3: Multi-Region Warm Standby — 設計書

**日付**: 2026-05-15  
**フェーズ**: Tier 3 (docs/high-availability-design.md §5 に対応)  
**スコープ**: IaC (Terraform) 実装のみ。実 apply は別タスク。  
**Primary Region**: ap-northeast-1 (Tokyo)  
**Secondary Region**: ap-northeast-3 (Osaka)

---

## 1. 目的と背景

Tier 0〜2 (基本構成・HA・セキュリティ) の実装が完了した。  
Tier 3 はリージョン全体障害 (Tokyo 全断) でも Osaka でサービス継続できる **Warm Standby DR** 構成を IaC として定義する。

- RPO: 1〜5 秒 (Aurora Global DB レプリケーション遅延)
- RTO: 約 15 分 (CloudFront Origin failover + Aurora Promote 手順込み)

---

## 2. 実装コンポーネント一覧

| コンポーネント | 担当モジュール | 区分 |
|---|---|---|
| Aurora Global Cluster (identifier 管理) | `modules/aurora_global/` | NEW |
| Aurora Primary Cluster (Tokyo, global 参加) | `modules/aurora/` (拡張) | EXTEND |
| Aurora Secondary Cluster (Osaka, read-only) | `modules/aurora/` (拡張) | EXTEND |
| CloudFront Origin Group (5xx failover) | `modules/cloudfront_s3/` (拡張) | EXTEND |
| S3 CRR (Tokyo → Osaka, versioning + IAM) | `modules/cloudfront_s3/` (拡張) | EXTEND |
| Route 53 ALIAS + Health Check | `modules/route53/` | NEW |
| ECR Cross-Region Replication | `modules/ecr/` (拡張) | EXTEND |
| Secrets Manager Multi-Region (アプリ用) | `modules/secrets/` | NEW |
| Osaka 環境一式 | `envs/dev-osaka/` | NEW |

---

## 3. ファイル構成

```
terraform/
├── modules/
│   ├── aurora_global/
│   │   ├── main.tf        # aws_rds_global_cluster
│   │   ├── variables.tf   # env, engine_version, database_name
│   │   └── outputs.tf     # global_cluster_identifier, global_cluster_arn
│   ├── aurora/            # 既存モジュール拡張
│   │   └── variables.tf   # 追加: is_secondary (default=false),
│   │                      #        global_cluster_identifier (default=""),
│   │                      #        source_region (default="")
│   ├── cloudfront_s3/     # 既存モジュール拡張
│   │   └── main.tf        # 追加: osaka_alb_dns が設定時に origin_group を動的生成
│   │                      #        /api/* cache behavior の target_origin_id を
│   │                      #        alb-failover-group に変更
│   │                      #        S3 versioning + CRR + IAM role 追加
│   ├── route53/
│   │   ├── main.tf        # aws_route53_health_check (CF endpoint 監視)
│   │   │                  # aws_route53_record ALIAS → CloudFront
│   │   ├── variables.tf
│   │   └── outputs.tf     # health_check_id, record_fqdn
│   ├── ecr/               # 既存モジュール拡張
│   │   └── main.tf        # 追加: aws_ecr_replication_configuration
│   └── secrets/
│       ├── main.tf        # aws_secretsmanager_secret (replica ブロック付き)
│       │                  # ※ Aurora の manage_master_user_password とは別の
│       │                  #    アプリ用 secret (例: API キー等)
│       ├── variables.tf
│       └── outputs.tf
└── envs/
    ├── dev/               # 変更あり
    │   ├── main.tf        # aurora_global モジュール追加
    │   │                  # aurora モジュールに global_cluster_identifier 追加
    │   │                  # cloudfront_s3 に osaka_alb_dns / osaka_s3_arn 追加
    │   │                  # route53 モジュール追加
    │   ├── variables.tf   # osaka_alb_dns, osaka_s3_bucket_arn, domain_name 追加
    │   ├── outputs.tf     # global_cluster_identifier 追加
    │   └── terraform.tfvars.example  # osaka_alb_dns = "" プレースホルダー
    ├── dev-osaka/         # 新規
    │   ├── main.tf        # network(3AZ), alb, ecs, aurora(secondary), monitoring
    │   │                  # + aws_s3_bucket "osaka_destination" (standalone、versioning 有効)
    │   ├── providers.tf   # aws { region = "ap-northeast-3" }
    │   ├── variables.tf   # global_cluster_identifier, primary_region, app_secret_replica_arn
    │   ├── outputs.tf     # alb_dns_name, s3_bucket_arn
    │   └── terraform.tfvars.example
    └── prod/              # 変更なし (共有モジュール拡張変数はすべて default="" or false)
```

---

## 4. リソース所有権テーブル

| リソース | 所有 env/state | 備考 |
|---|---|---|
| aws_rds_global_cluster | dev/ | Tokyo Primary 管理下 |
| Aurora Primary Cluster (Tokyo) | dev/ | global_cluster_identifier を参照 |
| Aurora Secondary Cluster (Osaka) | dev-osaka/ | source_region = ap-northeast-1 |
| CloudFront Distribution | dev/ | Origin Group に Tokyo+Osaka ALB |
| S3 Tokyo (source) | dev/ | versioning + CRR config 追加 |
| S3 Osaka (destination) | dev-osaka/ | versioning 有効、CRR ターゲット |
| Route 53 Health Check | dev/ | CF エンドポイントを監視 |
| Route 53 ALIAS Record | dev/ | → CloudFront domain |
| ECR Replication Config | dev/ | account-level singleton、import 要検討 |
| Secrets Manager (Tokyo) | dev/ | replica → ap-northeast-3 |
| Osaka ALB / ECS / Network | dev-osaka/ | Warm Standby 最小構成 |

---

## 5. データフローとクロス環境参照

```
┌────────── ap-northeast-1 (Tokyo / envs/dev/) ─────────────────────────┐
│                                                                         │
│  [aurora_global]  aws_rds_global_cluster "dev-global"                  │
│       │ output: global_cluster_identifier ──────────────────────────── │──▶ dev-osaka/tfvars.example
│       ▼                                                                 │
│  [aurora]  Primary Cluster (global_cluster_identifier 参照)             │
│                                                                         │
│  [cloudfront_s3]  CloudFront Distribution                               │
│  ├─ origin[Tokyo ALB]  "alb-dev"                                        │
│  ├─ origin[Osaka ALB]  "alb-dev-osaka"  ← var.osaka_alb_dns            │
│  │       └─ dynamic origin_group "alb-failover-group"                  │
│  │             failover: HTTP 500/502/503/504 で自動切替                │
│  ├─ default_cache_behavior  → S3 (Tokyo)                               │
│  └─ /api/* cache_behavior   → alb-failover-group  ← ★ target 変更     │
│                                                                         │
│  [route53]                                                              │
│  ├─ Health Check → CF domain (HTTPS:443、30秒間隔、3回失敗でアラーム)  │
│  └─ ALIAS Record → CloudFront (DNS 提供のみ、DR failover は CF が担当) │
│                                                                         │
│  [cloudfront_s3 S3 CRR]                                                 │
│  ├─ Tokyo S3 versioning: enabled                                        │
│  ├─ IAM Role for replication                                            │
│  └─ aws_s3_bucket_replication_configuration → Osaka S3 ARN             │
│           (var.osaka_s3_bucket_arn ← dev-osaka/ output)                │
│                                                                         │
│  [ecr]  aws_ecr_replication_configuration → ap-northeast-3             │
│                                                                         │
│  [secrets]  aws_secretsmanager_secret + replica { region = "ap-3" }    │
└─────────────────────────────────────────────────────────────────────────┘

  クロス参照の渡し方 (IaC のみフェーズ: terraform_remote_state は使わない):
  ┌──────────────────────────────────────────────────────────────────────┐
  │ Phase 1: dev/ apply (aurora_global + aurora_primary のみ)            │
  │   → output: global_cluster_identifier, app_secret_replica_arn を控える      │
  │ Phase 2: dev-osaka/tfvars.example に記入 → dev-osaka/ apply         │
  │   → output: alb_dns_name, s3_bucket_arn を控える                    │
  │ Phase 3: dev/tfvars.example に記入 → dev/ apply (CloudFront/R53)    │
  └──────────────────────────────────────────────────────────────────────┘

┌────────── ap-northeast-3 (Osaka / envs/dev-osaka/) ───────────────────┐
│                                                                         │
│  [network]   VPC / Subnet (3 AZ: 3a/3b/3c) / NAT × 3                  │
│              ※ network module は AZ 数 = 3 バリデーション固定のため 3 AZ │
│  [alb]       Osaka ALB                                                  │
│              └─ output: alb_dns_name                                   │
│  [ecs]       desired_count = 1  (Warm Standby 最小構成)                │
│  [aurora]    Secondary Read-only Cluster                                │
│              ├─ is_secondary = true                                     │
│              ├─ global_cluster_identifier = var.global_cluster_id      │
│              ├─ source_region = "ap-northeast-1"                       │
│              └─ master_username / manage_master_user_password は設定不要│
│                 (Global DB から自動継承)                                 │
│  [s3]        aws_s3_bucket "osaka_destination" (standalone resource)    │
│              ├─ versioning: enabled                                     │
│              └─ output: s3_bucket_arn (dev/ CRR config に渡す)         │
│  [ecs]       app_secret_replica_arn = var.app_secret_replica_arn                       │
│              └─ Osaka の Secrets Manager replica ARN を渡す             │
│                 (var.app_secret_replica_arn ← dev/ の secrets module output)   │
│  [monitoring] CloudWatch Alarms / SNS                                   │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 6. 主要モジュール詳細

### 6.1 `modules/aurora_global/main.tf`

```hcl
resource "aws_rds_global_cluster" "this" {
  global_cluster_identifier = "${var.env}-global"
  engine                    = "aurora-postgresql"
  engine_version            = var.engine_version
  database_name             = var.database_name
  deletion_protection       = false
}
```

### 6.2 `modules/aurora/` 拡張変数

```hcl
variable "is_secondary"              { default = false }
variable "global_cluster_identifier" { default = "" }
variable "source_region"             { default = "" }
```

- `is_secondary = true` 時: `global_cluster_identifier` と `source_region` を設定
- Secondary は `master_username` / `manage_master_user_password` を設定しない（Global DB から継承）
- `global_cluster_identifier` は `default = ""` なので prod への影響なし

### 6.3 `modules/cloudfront_s3/` 主な変更点

```hcl
# Osaka ALB が設定されている場合のみ: Osaka ALB origin block を動的追加
dynamic "origin" {
  for_each = var.osaka_alb_dns != "" ? [1] : []
  content {
    domain_name = var.osaka_alb_dns
    origin_id   = "alb-osaka"
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }
}

# Osaka ALB が設定されている場合のみ: Origin Group を動的生成
dynamic "origin_group" {
  for_each = var.osaka_alb_dns != "" ? [1] : []
  content {
    origin_id = "alb-failover-group"
    failover_criteria { status_codes = [500, 502, 503, 504] }
    member { origin_id = local.alb_origin_id }  # Tokyo (primary)
    member { origin_id = "alb-osaka" }           # Osaka (secondary)
  }
}

# /api/* behavior: osaka_alb_dns が設定されれば origin group を参照
ordered_cache_behavior {
  path_pattern     = "/api/*"
  target_origin_id = var.osaka_alb_dns != "" ? "alb-failover-group" : local.alb_origin_id
  # ... (他のパラメータは既存と同じ)
}

# S3 versioning (CRR の前提条件、常時有効)
resource "aws_s3_bucket_versioning" "ui" {
  bucket = aws_s3_bucket.ui.id
  versioning_configuration { status = "Enabled" }
}

# S3 CRR IAM Role: osaka_s3_bucket_arn が設定されている場合のみ
resource "aws_iam_role" "replication" {
  count = var.osaka_s3_bucket_arn != "" ? 1 : 0
  name  = "${var.env}-s3-replication-role"
  assume_role_policy = jsonencode({
    Statement = [{ Effect = "Allow", Principal = { Service = "s3.amazonaws.com" },
                   Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "replication" {
  count = var.osaka_s3_bucket_arn != "" ? 1 : 0
  role  = aws_iam_role.replication[0].id
  policy = jsonencode({
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetReplicationConfiguration", "s3:ListBucket"]
        Resource = aws_s3_bucket.ui.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObjectVersionForReplication", "s3:GetObjectVersionAcl",
                    "s3:GetObjectVersionTagging"]
        Resource = "${aws_s3_bucket.ui.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ReplicateObject", "s3:ReplicateDelete", "s3:ReplicateTags"]
        Resource = "${var.osaka_s3_bucket_arn}/*"
      }
    ]
  })
}

resource "aws_s3_bucket_replication_configuration" "to_osaka" {
  count      = var.osaka_s3_bucket_arn != "" ? 1 : 0
  depends_on = [aws_s3_bucket_versioning.ui]
  bucket     = aws_s3_bucket.ui.id
  role       = aws_iam_role.replication[0].arn
  rule {
    id     = "replicate-to-osaka"
    status = "Enabled"
    destination { bucket = var.osaka_s3_bucket_arn }
  }
}
```

**新規変数**:
- `osaka_alb_dns` (default = "") — Osaka ALB DNS 名
- `osaka_s3_bucket_arn` (default = "") — Osaka S3 CRR ターゲット ARN

### 6.4 `modules/route53/main.tf` 概要

```hcl
# CloudFront 経由で ALB まで到達するパス /api/health を監視
# CloudFront は Route 53 HC IP を許可済み (CF managed prefix list)
resource "aws_route53_health_check" "cloudfront" {
  fqdn              = var.cloudfront_domain   # *.cloudfront.net
  port              = 443
  type              = "HTTPS"
  resource_path     = "/api/health"   # /api/* → ALB 経路を監視 (S3 経路 / は不可)
  failure_threshold = 3
  request_interval  = 30
}

# ALIAS Record → CloudFront (DR は CF Origin Group が担当)
resource "aws_route53_record" "app" {
  zone_id = var.zone_id
  name    = var.domain_name
  type    = "A"
  alias {
    name                   = var.cloudfront_domain
    zone_id                = "Z2FDTNDATAQYW2"  # CloudFront の固定 hosted zone ID
    evaluate_target_health = false
  }
}
```

**設計上の注意**: Route 53 Failover Routing (PRIMARY/SECONDARY) は使用しない。
DNS failover は CloudFront Origin Group が担当するため、Route 53 は単純な ALIAS + Health Check Monitor として機能する。

### 6.5 `modules/ecr/` ECR Replication

```hcl
resource "aws_ecr_replication_configuration" "this" {
  count = var.enable_cross_region_replication ? 1 : 0
  replication_configuration {
    rule {
      destination {
        region      = "ap-northeast-3"
        registry_id = data.aws_caller_identity.current.account_id
      }
      # repository_filter なし = 全リポジトリを複製
    }
  }
}
```

**注意**: ECR Replication はアカウントレベルの singleton。既存設定がある場合は `terraform import` が必要。  
dev-osaka ECS は ECR 複製済みの `dev-app` リポジトリ (ap-northeast-3) を参照する。`dev-osaka-app` は存在しない。

### 6.6 `modules/secrets/main.tf`

```hcl
# Aurora manage_master_user_password (RDS 管理 secret) は replica 不可のため、
# DB 接続情報を含むアプリ用 secret を dev/ で作成し Osaka にレプリカを配置する。
# Osaka ECS はこの replica ARN (ap-northeast-3) を参照する。
resource "aws_secretsmanager_secret" "app" {
  name = "${var.env}/app/db-connection"
  replica {
    region = "ap-northeast-3"
  }
}

# secret value は apply 後に手動で設定 (or aws_secretsmanager_secret_version で管理)
# 値の例: { "host": "<aurora-writer-endpoint>", "port": "5432", "username": "...", "password": "..." }
```

**Osaka ECS の DB secret 配線**:
- `dev/` の `modules/secrets` が `dev/app/db-connection` を作成し、ap-northeast-3 にレプリカを持つ
- `dev/outputs.tf` に `app_secret_replica_arn` (ap-northeast-3 ARN) を追加
- `dev-osaka/variables.tf` に `app_secret_replica_arn` を追加
- `dev-osaka/` の ECS module に `aurora_secret_arn = var.app_secret_replica_arn` を渡す
- Phase 1 apply 後: secret value に Aurora Primary endpoint を書き込む
- Aurora failover/promote 後: secret value を Osaka endpoint に更新し ECS task を再起動する (既知制約)

---

## 7. 環境設定

### `envs/dev/` 追加変数

| 変数名 | デフォルト値 | 説明 |
|---|---|---|
| `osaka_alb_dns` | `""` | Phase 2 (dev-osaka apply 後) に記入 |
| `osaka_s3_bucket_arn` | `""` | Phase 2 (dev-osaka apply 後) に記入 |
| `domain_name` | `"dev.example.internal"` | Route 53 レコード用ドメイン (学習用) |

### `envs/dev-osaka/` 変数

| 変数名 | デフォルト値 | 説明 |
|---|---|---|
| `global_cluster_identifier` | `""` | Phase 1 (dev apply 後) に記入 |
| `app_secret_replica_arn` | `""` | Phase 1 (dev apply 後) に記入 (Osaka replica ARN) |
| `primary_region` | `"ap-northeast-1"` | Aurora source_region |
| `env` | `"dev-osaka"` | リソース名プレフィックス |
| `azs` | `["ap-northeast-3a", "ap-northeast-3b", "ap-northeast-3c"]` | 3 AZ (module バリデーション対応) |

### tfvars の扱い

- 実値を含む `terraform.tfvars` は `.gitignore` 対象
- コミット対象は `terraform.tfvars.example` (既存運用に準拠)
- Phase 間の受け渡し値は `.example` ファイルにコメントで明記

---

## 8. テスト追加

### Integration Tests (I34〜I42)

| ID | 検証内容 | 対象 env |
|---|---|---|
| I34 | Aurora Global Cluster が存在する | dev |
| I35 | Aurora Primary が global_cluster_identifier を持つ | dev |
| I36 | Aurora Secondary (Osaka) が global_cluster に参加している | dev-osaka |
| I37 | CloudFront に Origin Group (alb-failover-group) が設定されている | dev |
| I38 | `/api/*` behavior の target_origin_id が alb-failover-group である | dev |
| I39 | Tokyo S3 に replication configuration が設定されている (source 側) | dev |
| I40 | Osaka S3 に versioning が有効になっている (destination 側) | dev-osaka |
| I41 | ECR Replication Configuration に ap-northeast-3 が含まれる | dev |
| I42 | Route 53 Health Check が CloudFront ドメインを監視している | dev |

### Chaos Test C7: DR Failover Simulation

```bash
# tests/chaos/c7-dr-failover.sh
# Step 1: Tokyo ECS の desired_count を 0 に設定 (ALB が 5xx を返す状態にする)
# Step 2: CloudFront が Origin Group failover で Osaka ALB に切替わることを確認
#         (curl --resolve で CF ドメインにアクセス、200 が返ること)
# Step 3: Aurora Global DB detach/promote の手順を表示 (Runbook ドリル、実行はしない)
# Step 4: Tokyo ECS の desired_count を元に戻してリストア
```

**シナリオ数**: Tier 2 の 33 → **Tier 3 完了時 42**

---

## 9. apply 順序 (将来の実環境デプロイ時)

```
Phase 1: envs/dev/ — aurora_global + aurora_primary + secrets のみ apply
  │  (terraform apply -target=module.aurora_global -target=module.aurora
  │                   -target=module.secrets)
  └─ output: global_cluster_identifier, app_secret_replica_arn (ap-northeast-3) を記録
             → secrets value に Aurora Primary endpoint を書き込む

Phase 2: envs/dev-osaka/ — 全リソース apply
  ├─ input:  global_cluster_identifier, app_secret_replica_arn (Phase 1 の output)
  └─ output: alb_dns_name, s3_bucket_arn を記録

Phase 3: envs/dev/ — CloudFront Origin Group + Route 53 + S3 CRR apply
  ├─ input:  osaka_alb_dns, osaka_s3_bucket_arn (Phase 2 の output)
  └─ output: cloudfront_domain (Route 53 Health Check に使用)

Aurora Global DB レプリケーション確認:
  └─ SELECT pg_last_xact_replay_timestamp() で Osaka の遅延を確認 (< 1 秒目標)

テスト実行後: terraform destroy の順序は逆 (dev-osaka → dev)
```

---

## 10. 既知の制約・注意事項

| 制約 | 詳細 |
|---|---|
| Aurora 書き込みは Primary のみ | Secondary は read-only。Promote 後は手動で ECS 環境変数 (DB_HOST) と Secrets を更新し ECS task を再起動する必要がある |
| Aurora Promote = Detach | Primary に再統合するには新クラスターの作成が必要 |
| Aurora CRR 遅延 | 通常 < 1 秒、ピーク時 ~5 秒。RPO = 1〜5 秒 |
| CloudFront Origin failover 対象 | GET/HEAD/OPTIONS のみ。**POST/PUT の書き込み API は failover しない** |
| Route 53 TTL | DNS 切替完了まで TTL 秒 (default 300s) かかる。実運用では TTL を事前に短縮推奨 |
| S3 CRR 初回バックフィルなし | CRR は設定後の新規 object のみ対象。既存 object は S3 Batch Replication が別途必要 |
| ECR Replication 初回バックフィルなし | 設定後にプッシュされた image のみ複製。既存 image は手動 push が必要 |
| ECR Replication は account singleton | `aws_ecr_replication_configuration` は 1 アカウントに 1 リソース。既存設定がある場合は `terraform import` 後に管理 |
| Aurora managed secret は replica 不可 | `manage_master_user_password = true` の secret は RDS が管理するため `replica` ブロック追加不可 |
| prod への影響なし (後方互換) | 共有モジュール (aurora/cloudfront_s3/ecr) の拡張変数はすべて `default = ""` または `default = false`。prod の plan/validate に影響を与えない |
| Route 53 Hosted Zone | 実ドメインがない場合はプライベートホストゾーンまたはテスト用ゾーンを使用 |
| local backend での state 間依存 | apply 時は手動で output → tfvars.example のコピーが必要。実務では S3 remote backend + SSM Parameter Store 参照を推奨 |

---

## 11. 完了条件 (Definition of Done)

- [ ] `terraform fmt -recursive -check` が PASS
- [ ] `terraform validate` が dev / dev-osaka / **prod** 全環境で PASS
- [ ] `tests/scenarios.md` に I34〜I42、C7 が追記済み
- [ ] `docs/high-availability-design.md` §5 に実装ステータスマーカーを追加
- [ ] `docs/architecture.md` に Tier 3 セクションを追加
- [ ] `docs/final-report.md` に Tier 3 サマリを追加
- [ ] GitHub に push 済み
