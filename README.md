# aws-multi-vpc-learning

> 個人学習用に **AWS のマルチ VPC / マルチ AZ / マルチリージョン HA 構成 を Terraform で構築 → テスト → 削除** までを 1 サイクル回す教材。

`Tier 0` (最小冗長) から `Tier 3` (Multi-Region Warm Standby DR) まで段階的に実装し、**カオステストで自動復旧・DR 切替の挙動を実体で観察** できるようになっています。

---

## 🎯 この教材で身につくこと

| 領域 | スキル |
|---|---|
| ネットワーク | VPC / Subnet / IGW / NAT GW / Route Table / Security Group |
| ロードバランシング | ALB + Target Group + Listener (Fargate IP target) |
| コンテナ | ECS on Fargate + IAM Role 分離 (Execution / Task) + ECS Exec |
| データベース | Aurora PostgreSQL Multi-AZ + Aurora Global DB (Multi-Region) |
| CDN / 静的配信 | S3 + CloudFront + OAC + Origin Group (DR Failover) + SPA フォールバック |
| セキュリティ | WAFv2 / GuardDuty / VPC Flow Logs / KMS CMK / Secrets Manager |
| DR / 可用性 | Aurora Global DB レプリケーション / CloudFront Origin Group Failover / S3 CRR |
| IaC | Terraform モジュール設計 (`modules/` + `envs/{dev,dev-osaka,prod}/`) |
| 検証 | 4 層テスト (Static / Integration / E2E / **Chaos**) |
| エンジニアリング | コスト管理 / リソース削除 / SPOF 分析 / AWS API 制約調査 |

---

## 🏗 アーキテクチャ概要

### Tier 1〜2（単一リージョン）

```
[User]
  ↓
[CloudFront-Dev]
  ├ / → S3-Dev (UI)
  └ /api/* → ALB-Dev
       ↓
   VPC-Dev (ap-northeast-1, 10.1.0.0/16)
   ├ Public×3 (ALB, NAT)
   ├ App×3    (Fargate + Auto Scaling)
   └ DB×3     (Aurora Writer + Reader)
       Tier 2: WAFv2, GuardDuty, VPC Flow Logs, KMS CMK
```

### Tier 3（Multi-Region Warm Standby）

```
[User]
  ↓
[CloudFront]
  ├ / → S3-Tokyo (Primary)
  └ /api/* → Origin Group
                 ├ Primary  : ALB-Tokyo  (ap-northeast-1)
                 └ Failover : ALB-Osaka  (ap-northeast-3)

ap-northeast-1 (Tokyo)          ap-northeast-3 (Osaka)
VPC-Dev 10.1.0.0/16             VPC-Dev-Osaka 10.3.0.0/16
├ Aurora Writer (Primary)  →→→  ├ Aurora Reader (Secondary)
│   Global DB: dev-global             SynchronizationStatus: connected
├ ECS Fargate                   ├ ECS Fargate
└ S3 (source)              →→→  └ S3 (CRR destination)
ECR ap-northeast-1         →→→  ECR ap-northeast-3 (replication)
Secrets Manager            →→→  Secrets Manager (replica)
```

詳細図: [`docs/architecture.puml`](./docs/architecture.puml) (PlantUML)  
マルチリージョン DR 図: [`docs/architecture-ha-tier3.puml`](./docs/architecture-ha-tier3.puml)  
HA ロードマップ: [`docs/high-availability-design.md`](./docs/high-availability-design.md)  
Tier 3 設計書: [`docs/superpowers/specs/2026-05-15-tier3-dr-design.md`](./docs/superpowers/specs/2026-05-15-tier3-dr-design.md)

---

## ⚠️ コスト警告 (必読)

| 環境 | 24h 稼働の概算 |
|---|---|
| dev (Tier 1+2) | **~\$11/日** |
| dev + dev-osaka (Tier 3) | **~\$25/日** (Aurora r5.large × 2 が支配的) |
| prod (Tier 1 full) | **~\$18/日** |

- **Aurora Global DB は `db.t*` 系インスタンスが使用不可** → 最小は `db.r5.large`
- 時間課金: ALB / NAT Gateway / EIP / Aurora / CloudFront
- **検証完了後は必ず `terraform destroy`** で削除（dev-osaka → dev の順）
- 1〜2 時間の検証なら **\$1〜2** で済む

---

## 📁 ディレクトリ構成

```
.
├── README.md
├── docs/
│   ├── architecture.md                     設計書 (CIDR / SG / コスト)
│   ├── architecture.puml                   Tier 1+2 構成図 (PlantUML)
│   ├── architecture-ha-tier3.puml          Tier 3 Multi-Region DR 図
│   ├── high-availability-design.md         Tier 0-5 冗長化ロードマップ
│   ├── cleanup-checklist.md                削除順チェックリスト
│   ├── final-report.md                     プロジェクトレポート
│   ├── learning-dialogue.md                生徒と先生の対話で振り返り
│   └── superpowers/specs/
│       └── 2026-05-15-tier3-dr-design.md   Tier 3 詳細設計書
├── terraform/
│   ├── modules/                            (12 モジュール)
│   │   ├── network/                        VPC・Subnet・NAT (1 or 3 AZ 切替)
│   │   ├── security_groups/                3 SG + CloudFront PL 連携
│   │   ├── ecr/                            ECR + lifecycle + クロスリージョンレプリケーション
│   │   ├── alb/                            ALB (target_type=ip)
│   │   ├── ecs/                            Cluster + TaskDef + Service + Auto Scaling
│   │   ├── aurora/                         Aurora PG Cluster (Writer + N Reader / Global DB 対応)
│   │   ├── aurora_global/                  Aurora Global Cluster (source_db_cluster 方式)
│   │   ├── cloudfront_s3/                  S3 + OAC + CloudFront + Origin Group (DR)
│   │   ├── secrets/                        Secrets Manager + クロスリージョンレプリカ
│   │   ├── route53/                        Route 53 HC + ALIAS レコード (オプション)
│   │   ├── waf/                            WAFv2 Managed Rules (us-east-1)
│   │   └── monitoring/                     SNS + CloudWatch Alarms + GuardDuty + Flow Logs
│   └── envs/
│       ├── dev/                            東京環境 (10.1.0.0/16) — Tier 1+2+3 Primary
│       ├── dev-osaka/                      大阪環境 (10.3.0.0/16) — Tier 3 Secondary
│       └── prod/                           本番環境 (10.0.0.0/16, Tier 1 full)
└── tests/
    ├── scenarios.md                        全シナリオ定義 (I1-I42 + C1-C7)
    ├── run-all.sh                          オーケストレーター
    ├── static/                             fmt / validate / 機密漏洩 grep
    ├── integration/                        I1-I42: AWS CLI でリソース実体検証
    ├── e2e/                                Playwright で HTTP 検証
    └── chaos/                              C1-C7: 障害注入 + DR Failover 動的検証
```

---

## 🚀 クイックスタート

### 前提

- AWS CLI v2 (認証済み)
- Terraform `>= 1.5.0`
- Node.js (E2E テスト時のみ)

### Tier 1+2 のみ（東京単一リージョン）

```bash
# 1. Aurora バージョン確認
aws rds describe-db-engine-versions \
  --engine aurora-postgresql --region ap-northeast-1 \
  --query 'DBEngineVersions[?starts_with(EngineVersion, `15.`)].EngineVersion' \
  --output text

# 2. apply
cd terraform/envs/dev
terraform init
terraform apply -auto-approve   # ~25 分

# 3. テスト
cd ../../..
bash tests/integration/run.sh   # I1-I33

# 4. destroy
cd terraform/envs/dev
terraform destroy -auto-approve
```

### Tier 3 Multi-Region（東京 + 大阪）

Aurora Global DB には特定の apply 順序が必要です。

```bash
# Phase 1: Tokyo Primary Aurora + Secrets Manager
cd terraform/envs/dev
terraform apply -target=module.aurora -target=module.secrets -auto-approve

# Phase 1b: Aurora Global Cluster (Primary ARN から作成)
terraform apply -target=module.aurora_global -auto-approve

# Phase 1 の outputs を dev-osaka/terraform.tfvars に記入
terraform output -raw global_cluster_identifier   # → dev-global
terraform output -raw app_secret_replica_arn      # → Osaka の Secrets ARN

# Phase 2: Osaka Secondary (全リソース)
cd ../dev-osaka
# terraform.tfvars に global_cluster_identifier / app_secret_replica_arn / ecr_repository_url を記入
terraform init
terraform apply -auto-approve   # ~10 分

# Phase 3: Tokyo 残りリソース (ECS / ALB / CloudFront / ECR レプリケーション等)
cd ../dev
# terraform.tfvars に osaka_alb_dns / osaka_s3_bucket_arn / enable_ecr_replication=true を記入
terraform apply -auto-approve

# テスト
cd ../../..
bash tests/integration/run.sh   # I1-I42 (Tier 3 テストは -target 環境では一部 SKIP)

# ⚠️ destroy (dev-osaka → dev の順が必須)
cd terraform/envs/dev-osaka && terraform destroy -auto-approve
cd ../dev && terraform destroy -auto-approve
```

---

## 🧪 テスト結果サンプル（実測値）

| Layer | シナリオ数 | 結果 | 備考 |
|---|---|---|---|
| Static | 5 | 5 PASS | fmt / validate (dev+prod) / 機密漏洩 grep |
| Integration (Tier 1+2) | 33 | 30 PASS / 3 Expected-FAIL | I13/I14 はアプリイメージ未デプロイで SKIP 相当 |
| Integration (Tier 3) | I34-I42 | I34/I35/I36 PASS | Aurora Global DB 疎通確認済み |
| Chaos | C1/C2/C4 実行 | 3 PASS | C1: 56 秒で ECS 復旧、C2: 38 秒で Aurora 切替 |

---

## 🔍 Aurora Global DB 実装メモ（ハマりどころ）

実装中に発見した AWS API 制約を記録します。

| 制約 | 詳細 |
|---|---|
| **apply 順序が重要** | Primary クラスター → Global Cluster (`source_db_cluster_identifier`) → Secondary の順でないと Osaka が Primary になる |
| **インスタンスクラス** | `db.t*`（バースタブル）は Global DB 非対応。最小 `db.r5.large` |
| **`manage_master_user_password`** | Global DB メンバー（Primary・Secondary 両方）で使用不可 |
| **Secondary クレデンシャル** | `master_username` / `master_password` は Secondary では設定不可（Primary から自動同期） |
| **KMS Key** | 暗号化された Secondary は `kms_key_id` の明示が必須（`alias/aws/rds` data source で取得） |
| **`database_name`** | Global DB メンバーでは設定不可（Global Cluster 定義に含まれる） |
| **CloudFront Origin Group** | `allowed_methods` に POST/PUT/PATCH/DELETE は含められない（Warm Standby は read-only failover） |

---

## 🛡 セキュリティ・運用注意

- `terraform.tfvars` と `terraform.tfstate` は `.gitignore` 済み
- Aurora パスワードは `random_password` リソースで生成（Global DB は `manage_master_user_password` 非対応のため）
- ALB は CloudFront Managed Prefix List からのみ HTTP 80 を許可（直接アクセス遮断）
- S3 は Block Public Access ON + OAC 経由のみ
- ECS Exec を有効化済み（デバッグ用、TaskRole に `ssmmessages:*` 4 アクション）
- Tier 2: WAFv2 (`enable_waf=true`) / GuardDuty / VPC Flow Logs / KMS CMK をオプション変数で制御

---

## 🔄 段階的な学習パス

| ステージ | 内容 | 目安コスト |
|---|---|---|
| **Tier 0** | `dev` apply → Integration テスト → destroy | ~\$0.5 |
| **Tier 1** | Auto Scaling + 監視で Chaos C1/C2/C4 を体験 | ~\$1 |
| **Tier 2** | `enable_waf=true` で WAFv2 / GuardDuty / KMS を体験 | ~\$1 |
| **Tier 3** | Multi-Region DR: 3 フェーズ apply → I34-I36 確認 → destroy | ~\$2 |

---

## 📚 ドキュメントの読み方

| 目的 | 読むファイル |
|---|---|
| 「何を作るのか」を知る | `docs/architecture.md` |
| 図で全体像を理解 | `docs/architecture.puml` をレンダリング |
| 段階的な HA 設計を学ぶ | `docs/high-availability-design.md` |
| Tier 3 DR の詳細設計 | `docs/superpowers/specs/2026-05-15-tier3-dr-design.md` |
| 体系的なサマリー | `docs/final-report.md` |
| なぜそうしたのかの対話 | `docs/learning-dialogue.md` |
| 削除手順 | `docs/cleanup-checklist.md` |
| テストシナリオ一覧 | `tests/scenarios.md` |
| カオステスト詳細 | `tests/chaos/README.md` |

---

## 📝 ライセンス・注意

- 個人学習用に作成。コードや構成は MIT 相当で自由に参考利用可
- **AWS の請求は利用者の責任で管理**してください
- 実環境への流用前にセキュリティレビューを必ず実施

---

## 🤝 貢献・フィードバック

学習者の視点での感想・改善提案 Welcome です。Issue や PR で。
