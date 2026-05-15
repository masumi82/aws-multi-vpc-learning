# テストシナリオ一覧

> AWS マルチ VPC 構成 (Prod/Dev 分離 + S3+CloudFront + ECS Fargate + Aurora) の
> 動作検証用シナリオ。3 層で構成 (Static / Integration / E2E)。

## 全体方針

| Layer | 対象 | 実行タイミング | デプロイ要否 | コスト |
|---|---|---|---|---|
| **Static** | コードの構文・規約・機密漏洩 | コミット前・CI | 不要 | 0 |
| **Integration** | AWS リソースが定義通り作成されたか | `terraform apply` 後 | 必要 | 課金中 |
| **E2E** | エンドユーザー視点で機能するか | `terraform apply` 後・Distribution Deployed 後 | 必要 | 課金中 |

実行手順:
```bash
./tests/run-all.sh static       # apply 前
./tests/run-all.sh integration  # apply 後
./tests/run-all.sh e2e          # apply 後 + index.html 配置後
./tests/run-all.sh all          # 全部
```

`integration` / `e2e` は env 変数 `TF_ENV=dev|prod` で対象環境を切り替え。

---

## Static (S1-S6)

| ID | シナリオ | 期待結果 | 自動化 |
|---|---|---|---|
| S1 | `terraform fmt -recursive -check` | 差分なし (exit 0) | ✓ |
| S2 | `terraform validate` を envs/dev で実行 | Success | ✓ |
| S3 | `terraform validate` を envs/prod で実行 | Success | ✓ |
| S4 | コード内に平文の secret/password 値が無い | grep ヒット 0 | ✓ |
| S5 | `.gitignore` が `terraform.tfstate` / `*.tfvars` を除外 | パターン存在 | ✓ |
| S6 | (任意) tflint / tfsec / checkov | exit 0 (ツール未導入時はスキップ) | △ |

---

## Integration (I1-I22)

AWS CLI ベース。`terraform output` で取得した値を `aws` コマンドで突き合わせる。

### Network (I1-I5)
| ID | シナリオ | 期待結果 |
|---|---|---|
| I1 | VPC が存在し CIDR が変数通り | `dev=10.1.0.0/16` or `prod=10.0.0.0/16` |
| I2 | Subnet が 9 個存在 (public×3, app×3, db×3) | 各 Tier に 3 つ |
| I3 | IGW が VPC に attach | `aws ec2 describe-internet-gateways` |
| I4 | NAT GW が `1a` Public Subnet に 1 台、EIP が 1 つ | state=available |
| I5 | Route Table 3 種類が存在し、各 RT が 3 Subnet に associate | public→IGW, app→NAT, db→ローカルのみ |

### Security Groups (I6-I8)
| ID | シナリオ | 期待結果 |
|---|---|---|
| I6 | SG-ALB の Ingress に CloudFront Prefix List ID が含まれる、Port 80 | 1 ルール |
| I7 | SG-App の Ingress は SG-ALB のみ参照、Port 80 | 1 ルール |
| I8 | SG-Aurora の Ingress は SG-App のみ参照、Port 5432 | 1 ルール |

### ALB (I9-I11)
| ID | シナリオ | 期待結果 |
|---|---|---|
| I9 | ALB が `internet-facing` で state=active | 3 AZ に subnet 配置 |
| I10 | TG が `target_type=ip` | Fargate 必須 |
| I11 | Listener:80 が TG へ forward | DefaultAction=forward |

### ECS (I12-I15)
| ID | シナリオ | 期待結果 |
|---|---|---|
| I12 | Cluster が ACTIVE | `aws ecs describe-clusters` |
| I13 | Service desired_count = running_count | env 値と一致 |
| I14 | TG の Target が全て healthy | `aws elbv2 describe-target-health` |
| I15 | ECS Exec で `/bin/sh` が起動できる (smoke) | exit code 0 |

### Aurora (I16-I19)
| ID | シナリオ | 期待結果 |
|---|---|---|
| I16 | Cluster status が `available` | `aws rds describe-db-clusters` |
| I17 | Instance 数が `1 + reader_count` | env 値と一致 |
| I18 | Secrets Manager に Aurora 管理 secret が存在 | `aws secretsmanager describe-secret` |
| I19 | クラスタ Endpoint が DNS 解決可能 | `dig` または `getent hosts` |

### CloudFront / S3 (I20-I22)
| ID | シナリオ | 期待結果 |
|---|---|---|
| I20 | S3 バケット Block Public Access が ON | 4 つの設定が全て true |
| I21 | CloudFront Distribution status=Deployed, enabled=true | `aws cloudfront get-distribution` |
| I22 | バケットポリシーに `cloudfront.amazonaws.com` の `aws:SourceArn` 条件あり | jq でパース確認 |

### Tier 1 HA: Auto Scaling + Monitoring (I23-I27)
| ID | シナリオ | 期待結果 |
|---|---|---|
| I23 | SNS アラート用 Topic 存在 | `${env}-alerts` |
| I24 | CloudWatch Alarm が 5 個以上存在 | ECS CPU / ALB 5xx / TG Unhealthy / Aurora CPU / Aurora Memory |
| I25 | ECS Service に Application Auto Scaling Target が登録 | scalable_dimension=DesiredCount |
| I26 | Auto Scaling Target Tracking ポリシー登録 | CPU 70% target |
| I27 | (prod のみ) App Route Table が AZ ごとに 3 つ存在 | NAT per AZ の証跡 |

### Tier 2 セキュリティ強化 (I28-I33)
有効化フラグ (`enable_waf` / `enable_guardduty` / `enable_flow_logs` / `enable_kms_cmk`) が
false の場合は該当アサーションを SKIP する。

| ID | シナリオ | 期待結果 |
|---|---|---|
| I28 | WAFv2 Web ACL (CLOUDFRONT scope) が us-east-1 に存在 | name=`${env}-cloudfront-acl` |
| I29 | CloudFront Distribution に WAF が紐付け済 | `WebACLId == waf_web_acl_arn` |
| I30 | GuardDuty Detector が ENABLED | finding publishing frequency 15 分 |
| I31 | VPC Flow Logs が ACTIVE | traffic_type=ALL |
| I32 | KMS CMK のキーローテーションが有効 | rotation_enabled=true |
| I33 | Flow Logs 用 CloudWatch Log Group 存在 | `/aws/vpc/${env}-flow-logs` |
| I34 | Aurora Global Cluster が存在する | dev | Tier 3 |
| I35 | Aurora Primary が global_cluster_identifier を持つ | dev | Tier 3 |
| I36 | Aurora Secondary (Osaka) が global_cluster に参加している | dev-osaka | Tier 3 |
| I37 | CloudFront に Origin Group が設定されている | dev | Tier 3 |
| I38 | /api/* behavior の target_origin_id が alb-failover-group | dev | Tier 3 |
| I39 | Tokyo S3 に replication configuration がある | dev | Tier 3 |
| I40 | Osaka S3 に versioning が有効 | dev-osaka | Tier 3 |
| I41 | ECR Replication に ap-northeast-3 が含まれる | dev | Tier 3 |
| I42 | Route 53 HC が CloudFront ドメインを監視 | dev | Tier 3 |

---

## Chaos (C1-C6) — Tier 1/2 動作検証

実環境に意図的に障害を注入し、自動復旧 / Auto Scaling / Alarm / WAF Block が動くことを確認する。
**実 apply 後にのみ実行可能**。コスト出血が増えるので所要時間を意識すること。

| ID | シナリオ | 期待結果 | 所要 |
|---|---|---|---|
| C1 | ECS タスクを 1 つ強制停止 | サービスが自動的に新タスクを起動し、TG ヘルスチェックが healthy に戻る (60-120 秒) | 3 分 |
| C2 | Aurora Writer を手動 failover | 約 30 秒以内に Reader が Writer に昇格、エンドポイントは変わらない | 3 分 |
| C3 | App コンテナに CPU 負荷を注入 (ECS Exec 経由) | CloudWatch CPU メトリクスが上昇 → Auto Scaling が `desired_count` を増やす | 10 分 |
| C4 | CloudWatch にカスタムメトリクスを put して Alarm を発火 | Alarm 状態が `ALARM` に遷移、SNS 通知発行 | 3 分 |
| C5 | (prod のみ) ECS タスクを特定 AZ で全停止 | 残り 2 AZ で稼働継続、Auto Scaling が AZ 分散を維持 | 5 分 |
| C6 | CloudFront 経由で SQLi/XSS の典型 payload を投げる | WAFv2 Managed Rule が 403 で block、正常 request は通る (Tier 2、`enable_waf=true` のみ) | 3 分 |
| C7 | DR Failover Simulation: Tokyo ECS 停止 → CloudFront Osaka 切替確認 | dev+dev-osaka | Tier 3 |

詳細は `tests/chaos/README.md` を参照。

---

## E2E (E1-E6)

Playwright で CloudFront ドメインに対してブラウザ越しのアサーション。

| ID | シナリオ | 期待結果 |
|---|---|---|
| E1 | `https://<cf>/` に GET | 200, body に `index.html` の内容 (事前に PUT 必要) |
| E2 | `https://<cf>/api/` に GET | 200, Nginx welcome ページ (ALB → Fargate 経由) |
| E3 | `https://<cf>/this-path-does-not-exist` に GET | 200 + index.html body (SPA フォールバック) |
| E4 | `http://<cf>/` に GET | 301/302 で `https://` にリダイレクト |
| E5 | `https://<cf>/api/` で 405/メソッド対応確認 (HEAD, OPTIONS) | HEAD 200, OPTIONS 200 |
| E6 | ALB を直接 IP アクセスしようとしてもタイムアウト | SG が CloudFront PL のみ許可している証跡 |
| E7 | `/api/*` を 20 連続リクエスト → 全 200 + ユニークな X-Amz-Cf-Id | Tier 1: 複数 Fargate タスクで安定応答できる |

---

## テストデータ準備

### index.html (E1/E3 で必須)

```bash
S3_BUCKET=$(terraform -chdir=terraform/envs/${TF_ENV} output -raw s3_bucket_name)
cat > /tmp/index.html <<'EOF'
<!doctype html>
<html><head><meta charset="utf-8"><title>aws-sekei test</title></head>
<body><h1>aws-sekei UI</h1><p data-testid="marker">deployed</p></body></html>
EOF
aws s3 cp /tmp/index.html "s3://$S3_BUCKET/index.html"
```

### CloudFront キャッシュ無効化 (再テスト時に必要)
```bash
DIST_ID=$(terraform -chdir=terraform/envs/${TF_ENV} output -raw cloudfront_distribution_id)
aws cloudfront create-invalidation --distribution-id "$DIST_ID" --paths "/*"
```

---

## 実行マトリクス

| | apply 前 | apply 後 (init 中) | apply 後 (Deployed) | destroy 中 |
|---|---|---|---|---|
| Static | ✅ | ✅ | ✅ | ✅ |
| Integration | ✗ | △ (ECS pending OK) | ✅ | ✗ |
| E2E | ✗ | ✗ | ✅ | ✗ |

> Integration の Aurora 系 (I16-I19) は `terraform apply` が完了していれば OK (apply 完了時点で `available` になっているはず)。
> CloudFront の `status=Deployed` には apply 完了後さらに 5-15 分かかるため、E2E はそれを待ってから実行。
