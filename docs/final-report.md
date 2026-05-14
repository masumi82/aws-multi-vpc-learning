# AWS マルチ VPC 構成 学習レポート

**実施日**: 2026-05-13
**用途**: 個人開発・学習 (検証完了後に削除済み)
**リージョン**: `ap-northeast-1` (Tokyo) / 3 AZ (`1a` / `1c` / `1d`)

---

## 1. 目的と要件

| 項目 | 確定事項 |
|---|---|
| ゴール | AWS のマルチ AZ・マルチ VPC 構成を実物で構築し、テストで動作検証する |
| AZ 数 | 3 (`ap-northeast-1a` / `1c` / `1d`) |
| VPC 数 | 2 (**Prod / Dev 分離**、Peering なし) |
| ロードバランサー | 各 VPC に 1 つ (Internet-facing ALB) |
| DB | **Aurora PostgreSQL 15** マルチ AZ (Writer 1 + Reader N) |
| アプリ | シンプル CRUD API + ガントチャート UI (SPA 想定) |
| UI 配信 | **S3 + CloudFront** (環境ごとに Distribution) |
| App 層 | **ECS on Fargate** (EC2 ASG から学習途中で変更) |
| IaC | **Terraform** (ローカル State) |
| ライフサイクル | 検証完了後に即削除 |

---

## 2. 最終アーキテクチャ

```
[User]
  ↓ Route 53 (任意)
[CloudFront-Prod]              [CloudFront-Dev]
  ├ / → S3-Prod (UI)             ├ / → S3-Dev (UI)
  └ /api/* → ALB-Prod            └ /api/* → ALB-Dev
       ↓                              ↓
   VPC-Prod 10.0.0.0/16          VPC-Dev 10.1.0.0/16
   ├ Public×3 (ALB, NAT)         ├ Public×3 (ALB, NAT)
   ├ App×3 (Fargate)             ├ App×3 (Fargate)
   └ DB×3 (Aurora W+R+R)         └ DB×3 (Aurora W+R)
```

詳細は `docs/architecture.md` / `docs/architecture.puml` 参照。

### 設計上の重要選択

| 選択 | 採用 | 理由 |
|---|---|---|
| VPC 分割方針 | Prod / Dev 並列 (独立) | UI 配信が S3+CloudFront に変わり、Web 層 VPC が不要になったため |
| App 層コンピュート | ECS Fargate | サーバーレス、CRUD API に最適 |
| Aurora パスワード | `manage_master_user_password = true` | Secrets Manager 自動管理、手動 secret 不要 |
| CloudFront → ALB | HTTP オリジン (Option A) | 独自ドメイン/ACM/us-east-1 alias を持ち込まず学習スコープを絞る |
| NAT GW 配置 | `1a` のみ 1 台 | コスト最適化。本番なら各 AZ 配置 |
| ALB の SG | CloudFront managed prefix list のみ許可 | ALB 直接アクセスを SG レベルで遮断 |
| 初期コンテナ | `public.ecr.aws/nginx/nginx:stable` | ECR が空でも apply 可能、本物の API は後段で push |

---

## 3. 構築結果

### 3.1 リソース構成 (dev 環境で実構築)

- **`terraform apply` 結果**: 60 リソース追加・所要 ~25 分
- **`terraform destroy` 結果**: 60 リソース全削除完了

### 3.2 実体のエンドポイント (削除済み・形式のみ記録)

```
CloudFront:  https://<distribution-id>.cloudfront.net
ALB:         dev-alb-<id>.ap-northeast-1.elb.amazonaws.com
S3 Bucket:   app-ui-dev-<suffix>
ECR:         <account-id>.dkr.ecr.ap-northeast-1.amazonaws.com/dev-app
VPC:         vpc-<id>
Aurora:      dev-aurora-cluster.cluster-<id>.ap-northeast-1.rds.amazonaws.com
```

> 実際の値はすでに削除済みリソースですが、個人 AWS アカウント情報を含むため形式のみ記録します。

---

## 4. テスト結果

### 4.1 全体スコア: 35 / 36 PASS

| Layer | 件数 | 結果 | 備考 |
|---|---|---|---|
| Static | 5 | 5 PASS | terraform fmt / validate (dev/prod) / secret 漏洩 / .gitignore |
| Integration | 24 | 24 PASS | AWS CLI で全リソース実体検証 |
| E2E (Playwright) | 7 | **6 PASS / 1 想定外動作検出** | CloudFront 経由でブラウザ検証 |

### 4.2 E2E 詳細

| ID | シナリオ | 結果 | エビデンス |
|---|---|---|---|
| E1 | `/` → S3 UI | ✅ | スクショで `aws-sekei UI` 表示確認 |
| E2 | `/api/` → Nginx | ⚠️ | **CloudFront の SPA フォールバックが発火** (詳細は §5) |
| E3 | 存在しないパス → SPA fallback | ✅ | 404→200 で index.html |
| E4 | HTTP → HTTPS | ✅ | network log で 301 → 200 確認 |
| E5a/b | HEAD / OPTIONS | ✅ | メソッド対応 |
| E6 | ALB 直叩きブロック | ✅ | `ERR_EMPTY_RESPONSE` |

全エビデンス: `tests/evidence/2026-05-13/`
詳細シナリオ: `tests/scenarios.md`

---

## 5. 発見した設計課題: SPA + API 混在 Distribution

### 事象

`/api/` を CloudFront 経由で叩くと、Nginx の welcome ではなく **S3 の index.html (200)** が返ってきた。

### 原因

```
1. CloudFront `/api/*` Behavior → ALB → Nginx
2. Nginx は `/api/` というパスを知らない → 404 を返す
3. CloudFront の Distribution-wide な custom_error_response
   が「404 → /index.html 200」を発火
4. クライアントは S3 の index.html を 200 で受け取る
```

### curl による証跡

```
x-cache: Error from cloudfront    ← オリジン (Nginx) が 4xx を返した
server:  AmazonS3                  ← S3 origin が応答した
content-length: 165                ← S3 の index.html サイズと一致
```

### この知見の意味

CloudFront の `custom_error_response` は **Behavior 単位ではなく Distribution 単位**で適用される。SPA フォールバックを設定しつつ API も同じ Distribution に同居させると、**API のエラー応答が SPA fallback に隠蔽される**。

### 修正方針 (本回スコープ外)

| 方針 | 概要 |
|---|---|
| CloudFront Function | viewer-response で `/api/*` の error response 書き換えを抑制 |
| Distribution 分離 | UI と API で別 Distribution |
| Nginx 側で対応 | `/api/` でも 200 を返すよう nginx config を変える |
| 本物の API へ差し替え | dummy ではなく Express/FastAPI 等で適切な 404/エラーを返す (本来の運用) |

### 学習価値

**テストが設計の盲点を正しく検出した** という意味で、E2 の FAIL は実装ミスではなく成果。本物の CRUD API を載せる際に必ず解決する必要がある課題。

---

## 6. コスト実績

apply ~ destroy までの稼働時間: **約 1 時間** (検証 + テスト + 撤収)

| リソース | 稼働中の時間単価 (目安) |
|---|---|
| ALB | $0.0243/h |
| NAT Gateway | $0.062/h + データ転送 |
| Fargate Task (256 CPU / 512 MB) | $0.012/h × 1 task |
| Aurora (db.t4g.medium × 2) | $0.226/h |
| CloudFront / S3 | ほぼ無料枠 |
| **合計概算** | **~$0.35/h ≒ $25/日** |

**実際の請求**: 1 時間程度の検証なら **数十円〜100 円程度** で済むはず。AWS Cost Explorer で翌日確認推奨。

削除確認: 全課金リソース 0 件確認済み (NAT/EIP/ALB/Aurora/CloudFront/ECS)。

---

## 7. 成果物一覧

```
aws_sekei/
├── README.md                          プロジェクト全体ガイド (apply/destroy 手順、コスト警告)
├── .gitignore                         Terraform state / tfvars 除外
├── docs/
│   ├── architecture.md                設計書 (CIDR / SG / コスト)
│   ├── architecture.puml              PlantUML 構成図
│   ├── AWS Multi-AZ Multi-VPC Architecture.png  描画済み図
│   ├── cleanup-checklist.md           削除順チェックリスト (Phase 1-6)
│   └── final-report.md                ← 本ファイル
├── terraform/
│   ├── modules/                       (7 モジュール、再利用可能)
│   │   ├── network/
│   │   ├── security_groups/
│   │   ├── ecr/
│   │   ├── alb/
│   │   ├── ecs/
│   │   ├── aurora/
│   │   └── cloudfront_s3/
│   └── envs/
│       ├── dev/                       (10.1.0.0/16, reader=1, desired=1)
│       └── prod/                      (10.0.0.0/16, reader=2, desired=2)
├── tests/
│   ├── README.md
│   ├── scenarios.md                   34 シナリオ定義
│   ├── run-all.sh                     オーケストレーター
│   ├── static/run.sh                  5 シナリオ (apply 不要)
│   ├── integration/run.sh             22 シナリオ (AWS CLI)
│   ├── e2e/                           Playwright (7 シナリオ)
│   │   ├── package.json
│   │   ├── playwright.config.ts
│   │   ├── run.sh
│   │   └── specs/*.spec.ts
│   └── evidence/2026-05-13/           E2E ブラウザ試験エビデンス
│       ├── README.md
│       ├── E1-cloudfront-root/        (PNG + snapshot + network log)
│       ├── E2-api-routing/
│       ├── E3-spa-fallback/
│       ├── E4-http-redirect/
│       └── direct-alb/                (curl ログ + SG ルールダンプ)
└── tasks/
    └── todo.md                        実装中のタスク履歴
```

総ファイル数: **約 55 ファイル** (Terraform 36 + テスト 13 + ドキュメント 6)

---

## 8. 学んだこと (Key Takeaways)

### AWS / インフラ

1. **VPC Peering は transitive routing 非対応** — VPC-B から Peering 経由で VPC-A の NAT は使えない。初期設計で踏みかけた落とし穴
2. **CloudFront の `custom_error_response` は Distribution 単位** — SPA + API 同居時の盲点 (E2 で実証)
3. **CloudFront managed prefix list で SG 制限**ができる — ALB の直接アクセスを構造的に遮断 (E6 で実証)
4. **Aurora `manage_master_user_password`** が Secrets Manager 連携を肩代わりしてくれる — 手動 secret は不要
5. **NAT Gateway / EIP / CloudFront / Aurora** が時間課金の主要因。検証後の即時削除が必須

### Terraform

6. **envs ディレクトリ分離** > workspace — State 分離が物理的に明確で誤 apply を構造防止
7. **`aws_vpc_security_group_ingress_rule` (新形式)** はリプレースが少なくて済む
8. **`force_destroy = true` (S3) / `force_delete = true` (ECR) / `skip_final_snapshot = true` (Aurora)** を最初から付けないと destroy が詰まる
9. **`terraform validate` は構文 OK の保証だけ** — AWS API レベルの制約 (例: 古い Aurora バージョン) は plan/apply で初めて発覚
10. **`.terraform.lock.hcl` はコミット対象** — Provider バージョン固定のため

### テスト設計

11. **Static / Integration / E2E の 3 層** で apply 前/中/後をカバーできる
12. **テストが設計の盲点を発見できる** — E2 の "FAIL" は実装ミスではなく価値ある検出
13. **Playwright MCP** で対話的にエビデンス取得できる — スクショ + snapshot + network log を体系的に保存

---

## 9. 次回再現する場合の手順

```bash
# 1. Aurora バージョン確認 (必須)
aws rds describe-db-engine-versions \
  --engine aurora-postgresql --region ap-northeast-1 \
  --query 'DBEngineVersions[?starts_with(EngineVersion, `15.`)].EngineVersion' \
  --output text

# 2. 必要なら envs/dev/terraform.tfvars に上書き
echo 'aurora_engine_version = "15.X"' > terraform/envs/dev/terraform.tfvars

# 3. apply
cd terraform/envs/dev
terraform init
terraform plan -out=tfplan
terraform apply tfplan        # ~25 分

# 4. テスト
cd ../../..
./tests/run-all.sh static
TF_ENV=dev ./tests/run-all.sh integration
TF_ENV=dev ./tests/run-all.sh e2e

# 5. 即 destroy (2 パス推奨)
cd terraform/envs/dev
terraform destroy -target=module.cloudfront_s3 -target=module.ecs \
  -target=module.alb -target=module.aurora -auto-approve
terraform destroy -auto-approve

# 6. 残骸確認 (このレポートの §3.2 のリソースが 0 件であることを確認)
```

---

## 10. 今後の発展候補

優先度順:

1. **本物の CRUD API** (FastAPI / Express) を ECR に push してデプロイ — E2 課題と合わせて解決
2. **CloudFront Function** で SPA fallback を `/api/*` から除外
3. **独自ドメイン + ACM** (us-east-1 と ap-northeast-1) + Route 53 + WAF
4. **CI/CD** (GitHub Actions で `terraform plan` を PR に自動コメント)
5. **CloudWatch Alarm** + SNS で ECS タスク失敗・Aurora CPU 高負荷を検知
6. **Terraform Cloud / S3+DynamoDB Backend** に State 移行 (チーム運用に向けて)
7. **prod 環境** にも apply して 2 環境同時運用を体験 (現時点では dev のみ実構築)

---

## 11. Tier 2 セキュリティ強化 (2026-05-14 追加・IaC のみ)

Tier 1 撤収後、`docs/high-availability-design.md` §4 に基づき Tier 2 を Terraform で実装した
(実 apply はコスト発生のため未実施)。

### 実装コンポーネント

| Component | 場所 | env デフォルト |
|---|---|---|
| **WAFv2 Web ACL** | `terraform/modules/waf` | prod=ON / dev=OFF (コスト抑制) |
| **GuardDuty Detector** | `terraform/modules/monitoring/security.tf` | prod/dev=ON |
| **VPC Flow Logs** | `terraform/modules/monitoring/security.tf` | prod/dev=ON |
| **KMS CMK** (Logs/SNS 暗号化) | `terraform/modules/monitoring/security.tf` | prod=ON / dev=OFF |

### 設計上のポイント

- WAF (`scope=CLOUDFRONT`) は **us-east-1 必須**: prod/dev の `providers.tf` に
  `aws.us_east_1` alias を追加し、WAF モジュール呼び出し時に `providers = { aws = aws.us_east_1 }` で明示。
- すべての Tier 2 リソースは `enable_*` フラグでオプトイン化、デフォルト false にして後方互換維持。
- WAF Managed Rule: CommonRuleSet + KnownBadInputs + AmazonIpReputationList + Rate-based (2000 req/5min/IP)。

### テスト追加

- Integration I28-I33: WAF / GuardDuty / Flow Logs / KMS の存在・有効性検証 (env フラグで SKIP)。
- Chaos C6: CloudFront 経由で SQLi/XSS payload を投げて 403 ブロックを確認、サンプリングログを表示。
- Static (S1-S3) は両 env で PASS 確認済 (`terraform validate` Success)。

---

**プロジェクトステータス**: ✅ **完了** (構築 → 検証 → 撤収 全工程完了、課金停止確認済み)
+ Tier 2 IaC 実装済 (apply 未実施)
