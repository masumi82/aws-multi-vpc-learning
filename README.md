# aws-multi-vpc-learning

> 個人学習用に **AWS のマルチ VPC / マルチ AZ / HA 構成 を Terraform で構築 → テスト → 削除** までを 1 サイクル回す教材。

`Tier 0` (最小冗長) から `Tier 1` (Auto Scaling + 監視 + 単一 AZ 障害耐性) まで段階的に実装し、**カオステストで自動復旧の挙動を実体で観察** できるようになっています。

---

## 🎯 この教材で身につくこと

| 領域 | スキル |
|---|---|
| ネットワーク | VPC / Subnet / IGW / NAT GW / Route Table / Security Group |
| ロードバランシング | ALB + Target Group + Listener (Fargate IP target) |
| コンテナ | ECS on Fargate + IAM Role 分離 (Execution / Task) + ECS Exec |
| データベース | Aurora PostgreSQL Multi-AZ + Secrets Manager 連携 |
| CDN / 静的配信 | S3 + CloudFront + OAC + SPA フォールバック |
| 監視 / HA | CloudWatch Alarm + SNS + Application Auto Scaling |
| IaC | Terraform モジュール設計 (`modules/` + `envs/{dev,prod}/`) |
| 検証 | 4 層テスト (Static / Integration / E2E / **Chaos**) |
| エンジニアリング | コスト管理 / リソース削除 / SPOF 分析 |

---

## 🏗 アーキテクチャ概要

```
[User]
  ↓ Route 53 (任意)
[CloudFront-Prod]              [CloudFront-Dev]
  ├ / → S3-Prod (UI)             ├ / → S3-Dev (UI)
  └ /api/* → ALB-Prod            └ /api/* → ALB-Dev
       ↓                              ↓
   VPC-Prod 10.0.0.0/16          VPC-Dev 10.1.0.0/16
   ├ Public×3 (ALB, NAT)         ├ Public×3 (ALB, NAT)
   ├ App×3 (Fargate ASG)         ├ App×3 (Fargate ASG)
   └ DB×3 (Aurora W+R+R)         └ DB×3 (Aurora W+R)
```

詳細図: [`docs/architecture.puml`](./docs/architecture.puml) (PlantUML)
冗長性強化版 (Tier 3 Multi-Region): [`docs/architecture-ha-tier3.puml`](./docs/architecture-ha-tier3.puml)

---

## ⚠️ コスト警告 (必読)

| 環境 | 24h 稼働の概算 |
|---|---|
| dev (Tier 0 寄り) | **~\$11/日** (~\$335/月) |
| prod (Tier 1 full) | **~\$18/日** (~\$540/月) |
| 両方フル稼働 | **~\$29/日** (~\$875/月) |

- 時間課金: ALB / NAT Gateway / EIP / Aurora / CloudFront
- **検証完了後は必ず `terraform destroy`** で削除
- 削除順を間違えると課金継続 → [`docs/cleanup-checklist.md`](./docs/cleanup-checklist.md) 参照
- 1 時間程度の検証なら **\$1〜2** で済む

---

## 📁 ディレクトリ構成

```
.
├── README.md                            このファイル
├── docs/
│   ├── architecture.md                  設計書 (CIDR / SG / コスト)
│   ├── architecture.puml                構成図 (PlantUML)
│   ├── high-availability-design.md      Tier 0-5 冗長化ロードマップ
│   ├── architecture-ha-tier3.puml       マルチリージョン DR 図
│   ├── cleanup-checklist.md             削除順チェックリスト
│   ├── final-report.md                  プロジェクトレポート
│   └── learning-dialogue.md             生徒と先生の対話で振り返り
├── terraform/
│   ├── modules/                         (8 モジュール)
│   │   ├── network/                     VPC・Subnet・NAT (1 or 3 切替)
│   │   ├── security_groups/             3 SG + CloudFront PL 連携
│   │   ├── ecr/                         ECR + lifecycle
│   │   ├── alb/                         ALB (target_type=ip)
│   │   ├── ecs/                         Cluster + TaskDef + Service + Auto Scaling
│   │   ├── aurora/                      Aurora PG Cluster (Writer + N Reader)
│   │   ├── cloudfront_s3/               S3 + OAC + CloudFront
│   │   └── monitoring/                  SNS + 5 CloudWatch Alarms
│   └── envs/
│       ├── dev/                         開発環境 (10.1.0.0/16)
│       └── prod/                        本番環境 (10.0.0.0/16, Tier 1 full)
└── tests/                               4 層テストスイート
    ├── scenarios.md                     全 47 シナリオ定義
    ├── run-all.sh                       オーケストレーター
    ├── static/                          (5 シナリオ) fmt / validate / 機密漏洩
    ├── integration/                     (27 シナリオ) AWS CLI でリソース実体検証
    ├── e2e/                             (7 シナリオ) Playwright で HTTP 検証
    └── chaos/                           (5 シナリオ) 障害注入で HA 動的検証
```

---

## 🚀 クイックスタート

### 前提

- AWS CLI v2 (認証済み)
- Terraform `>= 1.9.0`
- Node.js (E2E テスト時のみ)
- Docker (PlantUML 描画時のみ)

### 1. Aurora バージョン確認 (必須)

```bash
aws rds describe-db-engine-versions \
  --engine aurora-postgresql --region ap-northeast-1 \
  --query 'DBEngineVersions[?starts_with(EngineVersion, `15.`)].EngineVersion' \
  --output text
```

出力リストに `15.10` が含まれていれば デフォルトのまま OK。
無ければ `terraform/envs/dev/terraform.tfvars` を作って `aurora_engine_version = "15.X"` を指定。

### 2. dev 環境を apply

```bash
cd terraform/envs/dev
terraform init
terraform plan -out=tfplan
terraform apply tfplan       # ~25 分
```

### 3. テスト実行

```bash
cd ../../..

# Static (常時実行可)
./tests/run-all.sh static

# Integration (apply 完了直後 OK)
TF_ENV=dev ./tests/run-all.sh integration

# E2E (CloudFront Deployed 後)
TF_ENV=dev ./tests/run-all.sh e2e

# Chaos (Tier 1 HA 動的検証)
TF_ENV=dev ./tests/run-all.sh chaos c1   # ECS task self-heal (3 分)
TF_ENV=dev ./tests/run-all.sh chaos c2   # Aurora failover (3 分)
TF_ENV=dev ./tests/run-all.sh chaos c4   # Alarm fire (3 分)
```

### 4. ⚠️ 検証完了後の destroy (重要)

時間課金を最速で止める 2 パス削除:

```bash
cd terraform/envs/dev
terraform destroy \
  -target=module.cloudfront_s3 \
  -target=module.ecs \
  -target=module.alb \
  -target=module.aurora \
  -auto-approve
terraform destroy -auto-approve
```

---

## 🧪 テスト結果サンプル (作者環境での実測値)

| Layer | シナリオ数 | 結果 | 備考 |
|---|---|---|---|
| Static | 5 | 5 PASS | fmt / validate (dev+prod) / 機密漏洩 grep |
| Integration | 28 | 28 PASS | (env=dev) 全 AWS リソースが定義通り作成された |
| E2E | 7 | **6 PASS / 1 設計課題検出** | CloudFront SPA+API 同居の落とし穴を検出 |
| Chaos | 3 実行 | 3 PASS | C1: 56 秒で復旧、C2: 38 秒で Aurora 切替、C4: Alarm 発火 |

E2E 1 件の "FAIL" は実装ミスではなく **テストが設計の盲点を正しく検出した結果**。詳細は [`docs/final-report.md §5`](./docs/final-report.md) と [`docs/learning-dialogue.md 第6幕`](./docs/learning-dialogue.md) 参照。

---

## 📚 ドキュメントの読み方

| 目的 | 読むファイル |
|---|---|
| 「何を作るのか」を知る | `docs/architecture.md` |
| 図で全体像を理解 | `docs/architecture.puml` をレンダリング |
| 段階的な HA 設計を学ぶ | `docs/high-availability-design.md` |
| 体系的なサマリー | `docs/final-report.md` |
| なぜそうしたのかの対話 | `docs/learning-dialogue.md` |
| 削除手順 | `docs/cleanup-checklist.md` |
| テストシナリオ一覧 | `tests/scenarios.md` |
| カオステスト詳細 | `tests/chaos/README.md` |

---

## 🛡 セキュリティ・運用注意

- `terraform.tfvars` と `terraform.tfstate` は `.gitignore` 済み
- Aurora パスワードは `manage_master_user_password = true` で AWS Secrets Manager 自動管理
- ALB は CloudFront Managed Prefix List からのみ HTTP 80 を許可 (直接アクセス遮断)
- S3 は Block Public Access ON + OAC 経由のみ
- ECS Exec を有効化済み (デバッグ用、TaskRole に `ssmmessages:*` 4 アクション)

---

## 🔄 段階的な学習パス

1. **Tier 0 動作確認** — `dev` を apply → Integration テストで存在確認 → destroy
2. **Tier 1 動作確認** — Auto Scaling + 監視を加えた状態で Chaos C1/C2/C4 を体験
3. **Tier 2 以降** — `docs/high-availability-design.md` の WAF / Multi-Region 設計を読み、興味があれば追加実装

---

## 📝 ライセンス・注意

- 個人学習用に作成。コードや構成は MIT 相当で自由に参考利用可
- **AWS の請求は利用者の責任で管理**してください
- 実環境への流用前にセキュリティレビューを必ず実施

---

## 🤝 貢献・フィードバック

学習者の視点での感想・改善提案 Welcome です。Issue や PR で。
