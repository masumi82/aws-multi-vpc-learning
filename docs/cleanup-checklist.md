# 検証後 削除チェックリスト

> 個人学習のため、検証完了後はすべて削除する。
> **削除順を間違えると依存関係エラーで詰まる**。下記の順番を厳守。
> 時間課金リソース (ALB / NAT / Aurora / EIP) を先に止めるとコスト出血を最小化できる。

---

## Phase 1: 即時の出血止め (最優先・10 分)

時間課金が大きいものから停止する。CloudFront は Disable に時間がかかるので並行で進める。

- [ ] **CloudFront Distribution** を Disable (Prod / Dev)
   - [ ] Console: CloudFront → Distribution → Disable
   - [ ] **Status が Deployed に戻るまで待つ (10〜15 分)** → そのあと Delete
- [ ] **ALB** を削除 (Prod / Dev)
   - [ ] Target Group も併せて削除
- [ ] **NAT Gateway** を削除 (Prod / Dev)
   - [ ] ⚠️ **NAT に紐付いた EIP は別途解放しないと課金継続**
- [ ] **Elastic IP** を Release (NAT 用 / その他)

> ここまでで最大のコスト発生源 (時間あたり \$0.1〜\$0.2) は止まる。

---

## Phase 2: DB と Compute (15 分)

- [ ] **Aurora**
   - [ ] DB クラスタの「**削除保護**」をオフにする (有効化していた場合)
   - [ ] Reader インスタンスを先に削除
   - [ ] Writer インスタンスを削除
   - [ ] DB クラスタを削除 (最終スナップショット取得は学習用なら不要)
   - [ ] DB Subnet Group / DB Cluster Parameter Group を削除
- [ ] **Auto Scaling Group**
   - [ ] 希望容量を 0 に → ASG を削除
- [ ] **EC2 インスタンス** (ASG 経由でないものがあれば手動 Terminate)
- [ ] **Launch Template** を削除

---

## Phase 3: ストレージとエッジ (10 分)

- [ ] **S3 バケット** (Prod UI / Dev UI)
   - [ ] バケット内のオブジェクトをすべて削除 (バージョニング有効ならバージョンも)
   - [ ] バケット削除
- [ ] **CloudFront Distribution** Delete (Phase 1 で Disable 済みのもの)
- [ ] **CloudFront OAC** (Origin Access Control) を削除

---

## Phase 4: ネットワーク (10 分)

各 VPC で以下を順に削除:

- [ ] **VPC Endpoint** (作成していれば)
- [ ] **Route Table** のカスタムルートを削除 → Route Table を削除 (main 以外)
- [ ] **Subnet** を削除 (9 個 × 2 VPC = 18 個)
- [ ] **Internet Gateway** を VPC から Detach → 削除
- [ ] **Security Group** を削除 (default 以外)
- [ ] **Network ACL** を削除 (custom があれば)
- [ ] **VPC** を削除

---

## Phase 5: DNS / 証明書 (5 分)

- [ ] **Route 53**
   - [ ] CloudFront 向け ALIAS レコードを削除
   - [ ] ホストゾーンを削除 (ドメイン使い回さないなら)
- [ ] **ACM 証明書**
   - [ ] CloudFront の紐付けが外れているのを確認
   - [ ] `us-east-1` の証明書を削除
   - [ ] `ap-northeast-1` の証明書 (ALB 用に作っていれば) を削除

---

## Phase 6: 残骸チェック (5 分)

- [ ] **CloudWatch Logs**: ロググループを削除 (`/aws/...` `/app/...`)
- [ ] **IAM**: 作成した Role / Instance Profile / Policy を削除
- [ ] **Secrets Manager / SSM Parameter Store**: DB パスワード等を削除
- [ ] **Key Pair** (EC2 SSH 用に作成したもの)
- [ ] **Cost Explorer** で翌日以降の課金が止まっているか確認

---

## 削除確認コマンド (任意)

```bash
# ALB 残存チェック
aws elbv2 describe-load-balancers --region ap-northeast-1

# NAT GW 残存チェック (deleting / deleted は無視)
aws ec2 describe-nat-gateways --region ap-northeast-1 \
  --filter Name=state,Values=available,pending

# EIP 残存チェック
aws ec2 describe-addresses --region ap-northeast-1

# Aurora クラスタ残存チェック
aws rds describe-db-clusters --region ap-northeast-1

# VPC 残存チェック (default 以外)
aws ec2 describe-vpcs --region ap-northeast-1 \
  --filters Name=isDefault,Values=false
```

---

## 削除し忘れやすいリソース (経験則)

1. **EIP** — NAT を消しても解放されない、$0.005/h で地味に効く
2. **CloudFront** — Disable 後の Delete を忘れがち
3. **ACM (us-east-1)** — リージョン違いで見逃す
4. **CloudWatch Logs** — 保管料金は微量だが残り続ける
5. **S3 のバージョン** — バージョニング有効時は版もすべて消す必要
6. **Aurora の自動バックアップ** — クラスタ削除後も保持期間中は課金
