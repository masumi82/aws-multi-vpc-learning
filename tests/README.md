# tests/

AWS マルチ VPC 構成のテストスイート。3 層構成。

## クイックスタート

```bash
chmod +x tests/run-all.sh tests/{static,integration,e2e}/run.sh

# 1. Static (常時、AWS 不要)
./tests/run-all.sh static

# 2. Integration (apply 後)
TF_ENV=dev ./tests/run-all.sh integration

# 3. E2E (apply 後 + CloudFront Deployed 後)
TF_ENV=dev ./tests/run-all.sh e2e

# 4. Chaos (Tier 1 HA + Tier 2 セキュリティ動的検証)
TF_ENV=dev ./tests/run-all.sh chaos c1    # task kill
TF_ENV=dev ./tests/run-all.sh chaos c2    # Aurora failover
TF_ENV=dev ./tests/run-all.sh chaos c3    # Auto Scaling
TF_ENV=dev ./tests/run-all.sh chaos c4    # Alarm fire
TF_ENV=prod ./tests/run-all.sh chaos c5   # AZ failure
TF_ENV=prod ./tests/run-all.sh chaos c6   # WAF block 検証 (Tier 2)
TF_ENV=dev ./tests/run-all.sh chaos all   # C1+C2+C4+C6 まとめて

# 5. 全部 (apply 後)
TF_ENV=dev ./tests/run-all.sh all
```

## レイヤ

| | 内容 | 実行条件 | 所要 |
|---|---|---|---|
| **Static** | `terraform fmt -check` / `terraform validate` / secret 漏洩 grep / `.gitignore` チェック | apply 不要 | 30 秒 |
| **Integration** | AWS CLI でリソース実体の検証 (33 シナリオ・Tier 2 含む) | apply 完了後 | 1-2 分 |
| **E2E** | Playwright で CloudFront URL に対する HTTP 検証 (UI / API / SPA フォールバック / HTTP→HTTPS / ALB 直叩き遮断) | Distribution Deployed 後 | 2-3 分 |
| **Chaos** | 障害注入による動的挙動検証 (Tier 1: タスク復旧 / Aurora failover / Auto Scaling / Alarm / AZ 障害、Tier 2: WAF block) | apply 後・安定稼働中 | 3-10 分/シナリオ |

シナリオ詳細は `scenarios.md` / `chaos/README.md` を参照。

## 環境変数

| 変数 | 既定値 | 用途 |
|---|---|---|
| `TF_ENV` | `dev` | integration/e2e の対象環境 (`dev` or `prod`) |
| `AWS_REGION` | `ap-northeast-1` | integration での AWS CLI 既定リージョン |

## Playwright (E2E)

- 初回実行時に `npm install` + `npx playwright install chromium` が走る
- レポートは `tests/e2e/playwright-report/index.html` に生成
- index.html が S3 に未配置の場合、`e2e/run.sh` が自動で fixture を PUT + CloudFront invalidation

## トラブルシュート

| 症状 | 対処 |
|---|---|
| Integration の I13/I14 が fail (running=0) | Service デプロイ中。`aws ecs describe-services` の events を確認 |
| Integration の I21 が fail (CF status != Deployed) | Distribution 反映待ち。10 分後に再実行 |
| E2E の E1 で marker が見つからない | index.html が S3 に未配置。`e2e/run.sh` が自動 PUT するが、CF キャッシュ TTL 待ち |
| E2E の E2 で 503 が返る | TG ヘルスチェックがまだ通っていない。Integration の I14 を先に確認 |
| Playwright install で失敗 | システム依存 (libnss3 等) の不足。`sudo npx playwright install-deps` を試す |

## オプション: Static で追加できるスキャナー

未インストール時はスキップされる。導入で品質強化:

```bash
# tflint
curl -sL https://raw.githubusercontent.com/terraform-linters/tflint/master/install_linux.sh | bash

# tfsec
go install github.com/aquasecurity/tfsec/cmd/tfsec@latest

# checkov
pip install checkov
```
