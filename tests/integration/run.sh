#!/usr/bin/env bash
# Integration tests (terraform apply 後に実行)
# 環境変数 TF_ENV=dev|prod で対象環境を切替
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TF_ENV="${TF_ENV:-dev}"
TF_DIR="$ROOT/terraform/envs/$TF_ENV"
REGION="${AWS_REGION:-ap-northeast-1}"
PASS=0; FAIL=0

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'

assert() {
  local id="$1" desc="$2" cond="$3" actual="${4:-}"
  if eval "$cond"; then
    printf "${GREEN}PASS${NC} %-4s %s\n" "$id" "$desc"
    PASS=$((PASS+1))
  else
    printf "${RED}FAIL${NC} %-4s %s  (actual: %s)\n" "$id" "$desc" "$actual"
    FAIL=$((FAIL+1))
  fi
}

if [ ! -f "$TF_DIR/terraform.tfstate" ]; then
  echo "ERROR: $TF_DIR/terraform.tfstate not found. Run 'terraform apply' in $TF_DIR first."
  exit 2
fi

echo "==== Integration Tests (env=$TF_ENV, region=$REGION) ===="

# --- terraform output から各種 ID を取得 ---
out() { terraform -chdir="$TF_DIR" output -raw "$1" 2>/dev/null; }

VPC_ID=$(out vpc_id)
ALB_DNS=$(out alb_dns_name)
CF_DOMAIN=$(out cloudfront_domain_name)
CF_ID=$(out cloudfront_distribution_id)
S3_BUCKET=$(out s3_bucket_name)
CLUSTER=$(out ecs_cluster_name)
AURORA_EP=$(out aurora_cluster_endpoint)

[ -z "$VPC_ID" ] && { echo "ERROR: vpc_id output not found"; exit 2; }

# Expected values (env による Tier 1 差分対応)
case "$TF_ENV" in
  dev)
    EXPECTED_CIDR="10.1.0.0/16"
    EXPECTED_READERS=1
    EXPECTED_DESIRED=1
    EXPECTED_NAT_COUNT=1
    EXPECTED_RT_COUNT=3    # public + app(1) + db
    ;;
  prod)
    EXPECTED_CIDR="10.0.0.0/16"
    EXPECTED_READERS=3
    EXPECTED_DESIRED=3
    EXPECTED_NAT_COUNT=3   # Tier 1: per-AZ
    EXPECTED_RT_COUNT=5    # public + app(3) + db
    ;;
  *)    echo "Unknown TF_ENV=$TF_ENV"; exit 2 ;;
esac

# ===================================================
# Network
# ===================================================
VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --region "$REGION" \
  --query 'Vpcs[0].CidrBlock' --output text 2>/dev/null)
assert I1 "VPC CIDR matches ($EXPECTED_CIDR)" "[ '$VPC_CIDR' = '$EXPECTED_CIDR' ]" "$VPC_CIDR"

# Subnets (3 tiers × 3 AZ = 9)
for TIER in public app db; do
  COUNT=$(aws ec2 describe-subnets --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Tier,Values=$TIER" \
    --query 'length(Subnets)' --output text 2>/dev/null)
  assert "I2-$TIER" "$TIER subnet count = 3" "[ '$COUNT' = '3' ]" "$COUNT"
done

# IGW
IGW_VPC=$(aws ec2 describe-internet-gateways --region "$REGION" \
  --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
  --query 'InternetGateways[0].Attachments[0].VpcId' --output text 2>/dev/null)
assert I3 "IGW attached to VPC" "[ '$IGW_VPC' = '$VPC_ID' ]" "$IGW_VPC"

# NAT GW (env で台数が変わる: dev=1, prod=3)
NAT_AVAILABLE_COUNT=$(aws ec2 describe-nat-gateways --region "$REGION" \
  --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available" \
  --query 'length(NatGateways)' --output text 2>/dev/null)
assert I4 "NAT GW count = $EXPECTED_NAT_COUNT (all available)" "[ '$NAT_AVAILABLE_COUNT' = '$EXPECTED_NAT_COUNT' ]" "$NAT_AVAILABLE_COUNT"

# Route Tables (env で数が変わる: dev=3, prod=5)
RT_COUNT=$(aws ec2 describe-route-tables --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=$TF_ENV-rt-*" \
  --query 'length(RouteTables)' --output text 2>/dev/null)
assert I5 "Custom RT count = $EXPECTED_RT_COUNT" "[ '$RT_COUNT' = '$EXPECTED_RT_COUNT' ]" "$RT_COUNT"

# ===================================================
# Security Groups
# ===================================================
SG_ALB=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$TF_ENV-sg-alb" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
SG_APP=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$TF_ENV-sg-app" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)

# I6: SG-ALB の ingress に CloudFront PL が含まれる
ALB_INGRESS_PL=$(aws ec2 describe-security-group-rules --region "$REGION" \
  --filters "Name=group-id,Values=$SG_ALB" \
  --query "SecurityGroupRules[?IsEgress==\`false\` && FromPort==\`80\`].PrefixListId" \
  --output text 2>/dev/null)
assert I6 "SG-ALB ingress 80 references CloudFront PL" "[ -n '$ALB_INGRESS_PL' ]" "$ALB_INGRESS_PL"

# I7: SG-App ingress = SG-ALB ref
APP_INGRESS_SG=$(aws ec2 describe-security-group-rules --region "$REGION" \
  --filters "Name=group-id,Values=$SG_APP" \
  --query "SecurityGroupRules[?IsEgress==\`false\` && FromPort==\`80\`].ReferencedGroupInfo.GroupId" \
  --output text 2>/dev/null)
assert I7 "SG-App ingress 80 references SG-ALB" "[ '$APP_INGRESS_SG' = '$SG_ALB' ]" "$APP_INGRESS_SG"

# I8: SG-Aurora ingress = SG-App ref, port 5432
SG_AURORA=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$TF_ENV-sg-aurora" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
AUR_INGRESS_SG=$(aws ec2 describe-security-group-rules --region "$REGION" \
  --filters "Name=group-id,Values=$SG_AURORA" \
  --query "SecurityGroupRules[?IsEgress==\`false\` && FromPort==\`5432\`].ReferencedGroupInfo.GroupId" \
  --output text 2>/dev/null)
assert I8 "SG-Aurora ingress 5432 references SG-App" "[ '$AUR_INGRESS_SG' = '$SG_APP' ]" "$AUR_INGRESS_SG"

# ===================================================
# ALB
# ===================================================
ALB_ARN=$(aws elbv2 describe-load-balancers --region "$REGION" \
  --names "$TF_ENV-alb" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)
ALB_STATE=$(aws elbv2 describe-load-balancers --region "$REGION" \
  --names "$TF_ENV-alb" --query 'LoadBalancers[0].State.Code' --output text 2>/dev/null)
ALB_SCHEME=$(aws elbv2 describe-load-balancers --region "$REGION" \
  --names "$TF_ENV-alb" --query 'LoadBalancers[0].Scheme' --output text 2>/dev/null)
assert I9 "ALB state=active, scheme=internet-facing" \
  "[ '$ALB_STATE' = 'active' ] && [ '$ALB_SCHEME' = 'internet-facing' ]" "$ALB_STATE/$ALB_SCHEME"

# TG target_type
TG_ARN=$(aws elbv2 describe-target-groups --region "$REGION" \
  --names "$TF_ENV-tg" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)
TG_TYPE=$(aws elbv2 describe-target-groups --region "$REGION" \
  --names "$TF_ENV-tg" --query 'TargetGroups[0].TargetType' --output text 2>/dev/null)
assert I10 "TG target_type=ip" "[ '$TG_TYPE' = 'ip' ]" "$TG_TYPE"

# Listener 80 forward
LISTENER_ACTION=$(aws elbv2 describe-listeners --region "$REGION" \
  --load-balancer-arn "$ALB_ARN" \
  --query 'Listeners[?Port==`80`].DefaultActions[0].Type' --output text 2>/dev/null)
assert I11 "Listener:80 default action=forward" "[ '$LISTENER_ACTION' = 'forward' ]" "$LISTENER_ACTION"

# ===================================================
# ECS
# ===================================================
CLUSTER_STATUS=$(aws ecs describe-clusters --region "$REGION" \
  --clusters "$CLUSTER" --query 'clusters[0].status' --output text 2>/dev/null)
assert I12 "ECS Cluster ACTIVE" "[ '$CLUSTER_STATUS' = 'ACTIVE' ]" "$CLUSTER_STATUS"

SVC_DESIRED=$(aws ecs describe-services --region "$REGION" \
  --cluster "$CLUSTER" --services "$TF_ENV-app" \
  --query 'services[0].desiredCount' --output text 2>/dev/null)
SVC_RUNNING=$(aws ecs describe-services --region "$REGION" \
  --cluster "$CLUSTER" --services "$TF_ENV-app" \
  --query 'services[0].runningCount' --output text 2>/dev/null)
assert I13 "ECS service desired=$EXPECTED_DESIRED, running=$EXPECTED_DESIRED" \
  "[ '$SVC_DESIRED' = '$EXPECTED_DESIRED' ] && [ '$SVC_RUNNING' = '$EXPECTED_DESIRED' ]" "$SVC_DESIRED/$SVC_RUNNING"

# Target health
HEALTHY=$(aws elbv2 describe-target-health --region "$REGION" \
  --target-group-arn "$TG_ARN" \
  --query 'length(TargetHealthDescriptions[?TargetHealth.State==`healthy`])' \
  --output text 2>/dev/null)
assert I14 "TG healthy targets = $EXPECTED_DESIRED" "[ '$HEALTHY' = '$EXPECTED_DESIRED' ]" "$HEALTHY"

# ECS Exec smoke (any task)
TASK=$(aws ecs list-tasks --region "$REGION" --cluster "$CLUSTER" \
  --query 'taskArns[0]' --output text 2>/dev/null)
if [ -n "$TASK" ] && [ "$TASK" != "None" ]; then
  # Just check enableExecuteCommand flag; actual session start needs interactive terminal
  EXEC_ENABLED=$(aws ecs describe-tasks --region "$REGION" --cluster "$CLUSTER" \
    --tasks "$TASK" --query 'tasks[0].enableExecuteCommand' --output text 2>/dev/null)
  assert I15 "ECS Exec enabled on running task" "[ '$EXEC_ENABLED' = 'True' ] || [ '$EXEC_ENABLED' = 'true' ]" "$EXEC_ENABLED"
else
  echo "SKIP I15  no running task found"
fi

# ===================================================
# Aurora
# ===================================================
CLUSTER_ID="$TF_ENV-aurora-cluster"
AURORA_STATUS=$(aws rds describe-db-clusters --region "$REGION" \
  --db-cluster-identifier "$CLUSTER_ID" \
  --query 'DBClusters[0].Status' --output text 2>/dev/null)
assert I16 "Aurora cluster status=available" "[ '$AURORA_STATUS' = 'available' ]" "$AURORA_STATUS"

EXPECTED_INSTANCES=$((1 + EXPECTED_READERS))
INSTANCE_COUNT=$(aws rds describe-db-clusters --region "$REGION" \
  --db-cluster-identifier "$CLUSTER_ID" \
  --query 'length(DBClusters[0].DBClusterMembers)' --output text 2>/dev/null)
assert I17 "Aurora instance count = $EXPECTED_INSTANCES" "[ '$INSTANCE_COUNT' = '$EXPECTED_INSTANCES' ]" "$INSTANCE_COUNT"

SECRET_ARN=$(aws rds describe-db-clusters --region "$REGION" \
  --db-cluster-identifier "$CLUSTER_ID" \
  --query 'DBClusters[0].MasterUserSecret.SecretArn' --output text 2>/dev/null)
SECRET_STATUS=$(aws secretsmanager describe-secret --region "$REGION" \
  --secret-id "$SECRET_ARN" --query 'Name' --output text 2>/dev/null)
assert I18 "Aurora master_user_secret exists in Secrets Manager" "[ -n '$SECRET_STATUS' ]" "$SECRET_STATUS"

DNS_OK=$(getent hosts "$AURORA_EP" >/dev/null 2>&1 && echo yes || echo no)
assert I19 "Aurora endpoint DNS resolvable" "[ '$DNS_OK' = 'yes' ]" "$AURORA_EP"

# ===================================================
# CloudFront / S3
# ===================================================
BPA=$(aws s3api get-public-access-block --bucket "$S3_BUCKET" 2>/dev/null \
  --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,BlockPublicPolicy,IgnorePublicAcls,RestrictPublicBuckets]' \
  --output text)
assert I20 "S3 Block Public Access all = true" "[ '$BPA' = $'True\tTrue\tTrue\tTrue' ]" "$BPA"

CF_STATUS=$(aws cloudfront get-distribution --id "$CF_ID" \
  --query 'Distribution.Status' --output text 2>/dev/null)
CF_ENABLED=$(aws cloudfront get-distribution --id "$CF_ID" \
  --query 'Distribution.DistributionConfig.Enabled' --output text 2>/dev/null)
assert I21 "CloudFront status=Deployed and enabled" \
  "[ '$CF_STATUS' = 'Deployed' ] && { [ '$CF_ENABLED' = 'True' ] || [ '$CF_ENABLED' = 'true' ]; }" "$CF_STATUS/$CF_ENABLED"

# Bucket policy SourceArn condition
SOURCE_ARN=$(aws s3api get-bucket-policy --bucket "$S3_BUCKET" \
  --query 'Policy' --output text 2>/dev/null \
  | jq -r '.Statement[0].Condition.StringEquals."AWS:SourceArn"' 2>/dev/null)
EXPECTED_DIST_ARN=$(aws cloudfront get-distribution --id "$CF_ID" \
  --query 'Distribution.ARN' --output text 2>/dev/null)
assert I22 "S3 bucket policy has aws:SourceArn = Distribution ARN" "[ '$SOURCE_ARN' = '$EXPECTED_DIST_ARN' ]" "$SOURCE_ARN"

# ===================================================
# Tier 1 HA: Auto Scaling + Monitoring
# ===================================================
SNS_TOPIC=$(aws sns list-topics --region "$REGION" \
  --query "Topics[?ends_with(TopicArn, \`:$TF_ENV-alerts\`)].TopicArn" --output text 2>/dev/null)
assert I23 "SNS alerts topic exists" "[ -n '$SNS_TOPIC' ]" "$SNS_TOPIC"

ALARM_COUNT=$(aws cloudwatch describe-alarms --region "$REGION" \
  --alarm-name-prefix "$TF_ENV-" \
  --query 'length(MetricAlarms)' --output text 2>/dev/null)
assert I24 "CloudWatch alarms (>=5) exist" "[ '$ALARM_COUNT' -ge '5' ]" "$ALARM_COUNT"

ASG_TARGET=$(aws application-autoscaling describe-scalable-targets --region "$REGION" \
  --service-namespace ecs \
  --resource-ids "service/$CLUSTER/$TF_ENV-app" \
  --query 'length(ScalableTargets)' --output text 2>/dev/null)
assert I25 "Application Auto Scaling target exists for ECS service" "[ '$ASG_TARGET' = '1' ]" "$ASG_TARGET"

ASG_POLICY=$(aws application-autoscaling describe-scaling-policies --region "$REGION" \
  --service-namespace ecs \
  --resource-id "service/$CLUSTER/$TF_ENV-app" \
  --query 'length(ScalingPolicies)' --output text 2>/dev/null)
assert I26 "Auto Scaling Target Tracking policy exists" "[ '$ASG_POLICY' = '1' ]" "$ASG_POLICY"

# ===================================================
# Tier 1 HA: SPOF 排除確認 (prod のみ)
# ===================================================
if [ "$TF_ENV" = "prod" ]; then
  # 各 AZ に App RT があるか
  APP_RT_COUNT=$(aws ec2 describe-route-tables --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=$TF_ENV-rt-app-*" \
    --query 'length(RouteTables)' --output text 2>/dev/null)
  assert I27 "Per-AZ App Route Tables = 3 (prod Tier 1)" "[ '$APP_RT_COUNT' = '3' ]" "$APP_RT_COUNT"
fi

# ===================================================
# Tier 2: WAF / GuardDuty / Flow Logs / KMS
# WAF/CMK は env により有効/無効が異なるので outputs を見て分岐
# ===================================================
WAF_ARN=$(out waf_web_acl_arn)
GD_DETECTOR=$(out guardduty_detector_id)
FLOW_LG=$(out flow_logs_log_group)
KMS_ARN=$(out kms_logs_key_arn)

# I28: WAF Web ACL (CLOUDFRONT scope, us-east-1) — enable_waf=true 環境のみ
if [ -n "$WAF_ARN" ] && [ "$WAF_ARN" != "null" ]; then
  WAF_NAME=$(aws wafv2 list-web-acls --scope CLOUDFRONT --region us-east-1 \
    --query "WebACLs[?ARN=='$WAF_ARN'].Name | [0]" --output text 2>/dev/null)
  assert I28 "WAFv2 Web ACL exists in us-east-1 (CLOUDFRONT scope)" "[ '$WAF_NAME' = '$TF_ENV-cloudfront-acl' ]" "$WAF_NAME"

  CF_WAF_ID=$(aws cloudfront get-distribution --id "$CF_ID" \
    --query 'Distribution.DistributionConfig.WebACLId' --output text 2>/dev/null)
  assert I29 "CloudFront distribution associated with WAF" "[ '$CF_WAF_ID' = '$WAF_ARN' ]" "$CF_WAF_ID"
else
  echo "SKIP I28-I29 (enable_waf=false)"
fi

# I30: GuardDuty Detector enabled
if [ -n "$GD_DETECTOR" ] && [ "$GD_DETECTOR" != "null" ]; then
  GD_STATUS=$(aws guardduty get-detector --region "$REGION" \
    --detector-id "$GD_DETECTOR" --query 'Status' --output text 2>/dev/null)
  assert I30 "GuardDuty Detector status=ENABLED" "[ '$GD_STATUS' = 'ENABLED' ]" "$GD_STATUS"
else
  echo "SKIP I30 (enable_guardduty=false)"
fi

# I31: VPC Flow Logs active for VPC
if [ -n "$FLOW_LG" ] && [ "$FLOW_LG" != "null" ]; then
  FLOW_STATE=$(aws ec2 describe-flow-logs --region "$REGION" \
    --filter "Name=resource-id,Values=$VPC_ID" \
    --query 'FlowLogs[0].FlowLogStatus' --output text 2>/dev/null)
  assert I31 "VPC Flow Logs status=ACTIVE" "[ '$FLOW_STATE' = 'ACTIVE' ]" "$FLOW_STATE"

  LG_EXISTS=$(aws logs describe-log-groups --region "$REGION" \
    --log-group-name-prefix "$FLOW_LG" \
    --query "logGroups[?logGroupName=='$FLOW_LG'] | length(@)" --output text 2>/dev/null)
  assert I33 "Flow Logs CloudWatch Log Group exists" "[ '$LG_EXISTS' = '1' ]" "$LG_EXISTS"
else
  echo "SKIP I31, I33 (enable_flow_logs=false)"
fi

# I32: KMS CMK key rotation enabled
if [ -n "$KMS_ARN" ] && [ "$KMS_ARN" != "null" ]; then
  KMS_KEY_ID=$(echo "$KMS_ARN" | awk -F'/' '{print $NF}')
  ROTATION=$(aws kms get-key-rotation-status --region "$REGION" \
    --key-id "$KMS_KEY_ID" --query 'KeyRotationEnabled' --output text 2>/dev/null)
  assert I32 "KMS CMK key rotation enabled" "[ '$ROTATION' = 'True' ] || [ '$ROTATION' = 'true' ]" "$ROTATION"
else
  echo "SKIP I32 (enable_kms_cmk=false)"
fi

echo "==== Integration Result: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC} ===="
[ "$FAIL" -eq 0 ]
