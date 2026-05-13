#!/usr/bin/env bash
# Static tests (apply 前に常時実行可能・AWS 認証情報不要)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TF_ROOT="$ROOT/terraform"
PASS=0
FAIL=0
SKIP=0

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'

check() {
  local id="$1" desc="$2" rc="$3"
  if [ "$rc" -eq 0 ]; then
    printf "${GREEN}PASS${NC} %-4s %s\n" "$id" "$desc"
    PASS=$((PASS+1))
  else
    printf "${RED}FAIL${NC} %-4s %s\n" "$id" "$desc"
    FAIL=$((FAIL+1))
  fi
}

skip() {
  local id="$1" desc="$2" reason="$3"
  printf "${YELLOW}SKIP${NC} %-4s %s  (%s)\n" "$id" "$desc" "$reason"
  SKIP=$((SKIP+1))
}

echo "==== Static Tests ===="

# ----- S1: terraform fmt -recursive -check -----
(cd "$TF_ROOT" && terraform fmt -recursive -check >/dev/null 2>&1)
check S1 "terraform fmt -recursive -check" $?

# ----- S2: terraform validate envs/dev -----
(cd "$TF_ROOT/envs/dev" && terraform init -backend=false -input=false >/dev/null 2>&1 && terraform validate >/dev/null 2>&1)
check S2 "terraform validate (envs/dev)" $?

# ----- S3: terraform validate envs/prod -----
(cd "$TF_ROOT/envs/prod" && terraform init -backend=false -input=false >/dev/null 2>&1 && terraform validate >/dev/null 2>&1)
check S3 "terraform validate (envs/prod)" $?

# ----- S4: 平文 secret/password が含まれていない -----
# manage_master_user_password = true / master_user_secret / master_username 等は除外
LEAKS=$(grep -RIn --include='*.tf' \
  -E '(password|secret)[[:space:]]*=[[:space:]]*"[^"]+"' \
  "$TF_ROOT" 2>/dev/null \
  | grep -v 'manage_master_user_password' \
  | grep -v 'master_user_secret' \
  | grep -v 'aurora_secret_arn' \
  | grep -v 'master_username' \
  || true)
if [ -z "$LEAKS" ]; then
  check S4 "No plain secret/password literal in *.tf" 0
else
  check S4 "No plain secret/password literal in *.tf" 1
  echo "$LEAKS" | sed 's/^/        /'
fi

# ----- S5: .gitignore に terraform state / tfvars 除外 -----
GITIGNORE="$ROOT/.gitignore"
if grep -q 'terraform.tfstate' "$GITIGNORE" && grep -q 'terraform.tfvars' "$GITIGNORE"; then
  check S5 ".gitignore excludes tfstate & tfvars" 0
else
  check S5 ".gitignore excludes tfstate & tfvars" 1
fi

# ----- S6: optional security scanners -----
if command -v tflint >/dev/null 2>&1; then
  (cd "$TF_ROOT" && tflint --recursive >/dev/null 2>&1)
  check S6a "tflint" $?
else
  skip S6a "tflint" "not installed"
fi

if command -v tfsec >/dev/null 2>&1; then
  tfsec "$TF_ROOT" --soft-fail >/dev/null 2>&1
  check S6b "tfsec" $?
else
  skip S6b "tfsec" "not installed"
fi

if command -v checkov >/dev/null 2>&1; then
  checkov -d "$TF_ROOT" --quiet --compact >/dev/null 2>&1
  check S6c "checkov" $?
else
  skip S6c "checkov" "not installed"
fi

echo "==== Static Result: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${YELLOW}${SKIP} skipped${NC} ===="
[ "$FAIL" -eq 0 ]
