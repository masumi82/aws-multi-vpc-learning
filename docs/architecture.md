# AWS マルチAZ / マルチVPC 構成設計書 (改訂版: Prod/Dev 分離)

> 用途: 個人開発・学習 (検証完了後すぐに削除予定)
> アプリ: シンプル CRUD API + ガントチャート UI (SPA)
> リージョン: `ap-northeast-1` (東京) / 3 AZ (`1a` / `1c` / `1d`)

---

## 1. 全体方針

| 観点 | 採用 |
|---|---|
| VPC 分割方針 | **Prod / Dev の環境分離** (並列・独立、Peering なし) |
| UI 配信 | **S3 + CloudFront** (静的 SPA、Distribution は環境ごと) |
| API 層 | ALB (Internet-facing) → App EC2 (ASG) → Aurora |
| AZ 配置 | 各 VPC とも 3 AZ にサブネット展開 |
| DB | Aurora (MySQL or PostgreSQL) Writer 1 + Reader 2、3 AZ DB Subnet Group |
| ドメイン | Route 53 で `app.example.com` (Prod) / `dev.example.com` (Dev) |
| CloudFront → ALB 経路 | ALB は public だが SG で **CloudFront マネージドプレフィクスリスト** からのみ許可 |

---

## 2. 論理構成 (ASCII)

```
                          ┌──────────────── Route 53 ────────────────┐
                          │ app.example.com         dev.example.com  │
                          └─────────┬───────────────────┬────────────┘
                                    ▼                   ▼
                              CloudFront-Prod    CloudFront-Dev
                              ├── /          : S3-Prod (UI)
                              └── /api/*     : ALB-Prod (origin)
                                                  │
                                                  │ (Dev も同様)
        ┌─────────────────────────────────────────┼──────────────────────────────────────┐
        ▼                                                                                ▼
┌─── VPC-Prod 10.0.0.0/16 ──────────────────┐                ┌─── VPC-Dev 10.1.0.0/16 ──────────────────┐
│ Public Subnet x3 : ALB(Ext) + NAT GW(1a)  │                │ Public Subnet x3 : ALB(Ext) + NAT GW(1a) │
│ App Subnet  x3   : App EC2 (ASG)          │                │ App Subnet  x3   : App EC2 (ASG)         │
│ DB Subnet   x3   : Aurora W + R + R       │                │ DB Subnet   x3   : Aurora W + R + R      │
└───────────────────────────────────────────┘                └──────────────────────────────────────────┘
```

---

## 3. CIDR 計画

### VPC-Prod — `10.0.0.0/16`

| Subnet | AZ | CIDR | 用途 |
|---|---|---|---|
| public-a | 1a | 10.0.0.0/24  | ALB / NAT GW |
| public-c | 1c | 10.0.1.0/24  | ALB |
| public-d | 1d | 10.0.2.0/24  | ALB |
| app-a    | 1a | 10.0.10.0/24 | App EC2 (Private) |
| app-c    | 1c | 10.0.11.0/24 | App EC2 (Private) |
| app-d    | 1d | 10.0.12.0/24 | App EC2 (Private) |
| db-a     | 1a | 10.0.20.0/24 | Aurora (Private) |
| db-c     | 1c | 10.0.21.0/24 | Aurora (Private) |
| db-d     | 1d | 10.0.22.0/24 | Aurora (Private) |

### VPC-Dev — `10.1.0.0/16`

同じレイアウトで第2オクテットを `1` に変更 (10.1.0.0/24 〜 10.1.22.0/24)。

---

## 4. コンポーネント詳細

### 4.1 UI 配信 (環境ごとに 2 セット)

- **S3 バケット**: `app-ui-prod-<ランダム>` / `app-ui-dev-<ランダム>` — Block Public Access 有効、OAC (Origin Access Control) 経由でのみアクセス
- **CloudFront Distribution**:
  - Default Behavior: S3 origin (UI 静的ファイル)、SPA 用に `403/404 → /index.html` のエラーレスポンス設定
  - `/api/*` Behavior: ALB origin (HTTPS only)、`AllViewer` でヘッダ・Cookie 転送
  - WAF (任意): AWS Managed Rule (CommonRuleSet) を attach
- **ACM 証明書**: `us-east-1` で発行 (CloudFront 必須)
- **Route 53**: ALIAS レコードで CloudFront を指す

### 4.2 VPC-Prod / VPC-Dev (構成は同一)

- **Internet Gateway**: Public Subnet にアタッチ
- **ALB (Internet-facing)**: 3 AZ の Public Subnet にまたがる。**SG で CloudFront managed prefix list (`com.amazonaws.global.cloudfront.origin-facing`) からの 443 のみ許可** することでオリジン保護
- **NAT Gateway**: `1a` Public Subnet に 1 台 (コスト優先、SPOF 許容)
- **App EC2 (Auto Scaling Group)**: 3 AZ の App Subnet、最小 2 / 希望 2 / 最大 6 程度
- **Aurora Cluster**:
  - DB Subnet Group: db-a / db-c / db-d
  - Writer × 1 + Reader × 2 を別 AZ に分散
  - インスタンスクラス: 学習用なら `db.t4g.medium` (Aurora MySQL) または Serverless v2 (`0.5 〜 1 ACU`)
- **Route Table**:
  - Public: `0.0.0.0/0` → IGW
  - Private(App): `0.0.0.0/0` → NAT
  - Private(DB): デフォルトルートなし (外部不要)

### 4.3 セキュリティグループ階層

```
Internet (User)
   │ HTTPS 443
   ▼
CloudFront (CFront managed origin-facing prefix list)
   │ HTTPS 443
   ▼
[SG-ALB]     ← prefix list pl-xxxxxxxx (CloudFront origin-facing)
   │ 8080
   ▼
[SG-App]     ← SG-ALB
   │ 3306 or 5432
   ▼
[SG-Aurora]  ← SG-App
```

| SG | Inbound 許可元 | Port |
|---|---|---|
| SG-ALB-Prod / Dev | CloudFront prefix list | 443 |
| SG-App-Prod / Dev | SG-ALB-同環境 | 8080 |
| SG-Aurora-Prod / Dev | SG-App-同環境 | 3306 (or 5432) |

> ⚠️ Prod と Dev の SG は **別 SG として作成** (環境間で混在しないように)

---

## 5. 高可用性

- ALB は 3 AZ にまたがる (subnet 3 つ指定)
- ASG の `VPC Zone Identifier` に App Subnet 3 AZ を指定 → 障害時に他 AZ で起動
- Aurora Writer 障害 → 約 30 秒で Reader が昇格しフェイルオーバー
- ⚠️ **NAT GW のみ単一 AZ (SPOF)** — `1a` 障害時は App の外向き通信 (パッケージ更新・外部 API) が停止する

---

## 6. 検証後の削除順 (重要)

時間課金が発生するリソースを以下の順で削除する。
`docs/cleanup-checklist.md` も参照。

1. CloudFront Distribution (Disable → Delete、Disable に 10–15 分かかる)
2. ALB (Prod / Dev)
3. NAT Gateway (Prod / Dev) ← **EIP も解放しないと課金継続**
4. Aurora クラスタ (削除保護を外してから、最終スナップショットを取るか聞かれる)
5. EC2 ASG → EC2 インスタンス
6. ElasticIP (NAT に紐付いていたもの)
7. S3 バケット (バケット内のオブジェクトを先に削除)
8. VPC (Subnet / RouteTable / IGW / VPC Endpoint / SG をクリーンアップしてから削除)
9. Route 53 ホストゾーン (使い回さないなら)
10. ACM 証明書 (CloudFront 紐付けが外れてから削除可)

---

## 7. 月額コスト目安 (24h 稼働時、東京リージョン)

| リソース | 単価 | 1環境 (Prod) | 2環境 (Prod+Dev) |
|---|---|---|---|
| ALB | $0.0243/h + LCU | ~$20 | ~$40 |
| NAT Gateway | $0.062/h + データ転送 | ~$45 | ~$90 |
| EC2 (t3.small × 3) | $0.0272/h × 3 | ~$60 | ~$120 |
| Aurora (db.t4g.medium × 3) | $0.113/h × 3 | ~$245 | ~$490 |
| CloudFront / S3 | ほぼ無料枠 | ~$1 | ~$1 |
| **合計 (概算)** |  | **~$370/月** | **~$740/月** |

> ⚠️ 検証時間が短ければ時間按分で済むが、**1日放置で $25 程度** 消える。確認後は即削除推奨。
> コスト圧縮するなら Aurora Serverless v2 (ACU 0.5 〜) や db.t4g.small への変更、Reader を 1 つに減らす等を検討。

---

## 8. 構成図

`docs/architecture.puml` を参照。

---

## 9. Tier 2 セキュリティ強化 (2026-05-14 追加)

詳細は `docs/high-availability-design.md` §4 を参照。本ベース構成に加え、以下を IaC で実装。

| Component | スコープ | env デフォルト | 役割 |
|---|---|---|---|
| **WAFv2 Web ACL** (`modules/waf`) | CloudFront (us-east-1) | prod=ON / dev=OFF | OWASP Top 10 + Bot + Rate Limiting (2000 req/5min/IP) |
| **GuardDuty Detector** | リージョン (ap-northeast-1) | prod=ON / dev=ON | 異常検知 (Crypto / Malware / Anomalous API) |
| **VPC Flow Logs** | VPC | prod=ON / dev=ON | 全トラフィックを CloudWatch Logs に出力 |
| **KMS CMK** | リージョン | prod=ON / dev=OFF | Flow Logs / SNS Topic の暗号化に使用 |

- 制約: WAF (CLOUDFRONT scope) は **us-east-1 に作成必須** のため、prod/dev の `providers.tf` に `aws.us_east_1` alias を追加。
- WAF Managed Rule Groups:
  - `AWSManagedRulesCommonRuleSet`
  - `AWSManagedRulesKnownBadInputsRuleSet`
  - `AWSManagedRulesAmazonIpReputationList`
- 検証: Integration tests I28-I33、Chaos test C6 (SQLi/XSS payload で 403 を確認)。

---

## 10. Tier 3 セキュリティと DR 強化 (2026-05-15 実装)

### Multi-Region Warm Standby

| コンポーネント | 実装 |
|---|---|
| Aurora Global DB | `modules/aurora_global` + `modules/aurora` (is_secondary 拡張) |
| CloudFront Origin Group | `modules/cloudfront_s3` (動的 origin + origin_group) |
| S3 Cross-Region Replication | `modules/cloudfront_s3` (versioning + CRR IAM + config) |
| Route 53 Health Check + ALIAS | `modules/route53` (新規) |
| ECR Cross-Region Replication | `modules/ecr` (account-level replication config) |
| Secrets Manager Multi-Region | `modules/secrets` (新規、replica) |
| Osaka 環境 | `envs/dev-osaka` (ap-northeast-3、Warm Standby 最小構成) |

Apply order: `envs/dev` Phase1 → `envs/dev-osaka` → `envs/dev` Phase3
