#!/usr/bin/env bash
# aws-to-terraform: 既存AWS環境をTerraformコードに変換するエージェント
# 使い方: ./run.sh [オプション]

set -euo pipefail

# ===== デフォルト値 =====
REGION="${AWS_DEFAULT_REGION:-ap-northeast-1}"
PROFILE="${AWS_PROFILE:-default}"
OUTPUT_DIR="./output"
RESOURCE_FILTER=""
MAX_FIX_ATTEMPTS=10
INTERACTIVE=true
SKIP_SCAN=false
SKIP_GENERATE=false
SKIP_IMPORT=false

# ===== カラー出力 =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${RESET} $*"; }
log_success() { echo -e "${GREEN}[✓]${RESET} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
log_error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
log_phase()   { echo -e "\n${BOLD}${CYAN}$*${RESET}"; echo -e "${CYAN}$(printf '=%.0s' {1..60})${RESET}"; }

# ===== ヘルプ =====
usage() {
  cat <<EOF
${BOLD}aws-to-terraform${RESET} - 既存AWS環境をTerraformコードに変換するエージェント

${BOLD}使い方:${RESET}
  $0 [オプション]

${BOLD}オプション:${RESET}
  -r, --region REGION         AWSリージョン (デフォルト: ap-northeast-1)
  -p, --profile PROFILE       AWSプロファイル (デフォルト: default)
  -o, --output DIR            出力先ディレクトリ (デフォルト: ./output)
  -f, --filter CATEGORY       スキャン対象カテゴリ (例: networking,compute)
                              指定可能: networking,compute,storage,database,iam,
                                       load_balancing,serverless,container,dns,cdn
  -m, --max-attempts N        ドリフト修正の最大試行回数 (デフォルト: 10)
  --skip-scan                 スキャンをスキップ (既存のスキャン結果を使用)
  --skip-generate             コード生成をスキップ (既存のTFコードを使用)
  --skip-import               importをスキップ (既存のstateを使用)
  --non-interactive           非インタラクティブモードで実行
  -h, --help                  このヘルプを表示

${BOLD}例:${RESET}
  # フル実行 (全リソース)
  $0 --region ap-northeast-1 --profile myprofile

  # ネットワークリソースのみ
  $0 --region us-east-1 --filter networking,compute

  # スキャン済みの結果からTFコード生成のみ
  $0 --skip-scan

  # 既存TFコードでimportから再実行
  $0 --skip-scan --skip-generate

${BOLD}前提条件:${RESET}
  - AWS CLI がインストール・設定済み
  - Terraform >= 1.5.0 がインストール済み
  - jq がインストール済み
  - Claude Code CLI (claude) がインストール済み

EOF
  exit 0
}

# ===== 引数パース =====
while [[ $# -gt 0 ]]; do
  case $1 in
    -r|--region)       REGION="$2";          shift 2 ;;
    -p|--profile)      PROFILE="$2";         shift 2 ;;
    -o|--output)       OUTPUT_DIR="$2";      shift 2 ;;
    -f|--filter)       RESOURCE_FILTER="$2"; shift 2 ;;
    -m|--max-attempts) MAX_FIX_ATTEMPTS="$2"; shift 2 ;;
    --skip-scan)       SKIP_SCAN=true;       shift ;;
    --skip-generate)   SKIP_GENERATE=true;   shift ;;
    --skip-import)     SKIP_IMPORT=true;     shift ;;
    --non-interactive) INTERACTIVE=false;    shift ;;
    -h|--help)         usage ;;
    *)                 log_error "不明なオプション: $1"; usage ;;
  esac
done

# ===== 依存関係チェック =====
check_dependencies() {
  log_phase "[事前チェック] 依存関係の確認"

  local missing=()

  command -v aws      >/dev/null 2>&1 || missing+=("aws-cli")
  command -v terraform >/dev/null 2>&1 || missing+=("terraform")
  command -v jq       >/dev/null 2>&1 || missing+=("jq")
  command -v claude   >/dev/null 2>&1 || missing+=("claude (Claude Code CLI)")

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "以下のツールがインストールされていません:"
    for tool in "${missing[@]}"; do
      echo "  - $tool"
    done
    echo ""
    echo "インストール方法:"
    echo "  aws-cli:   https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"
    echo "  terraform: https://developer.hashicorp.com/terraform/downloads"
    echo "  jq:        brew install jq  (macOS) / apt install jq (Ubuntu)"
    echo "  claude:    npm install -g @anthropic-ai/claude-code"
    exit 1
  fi

  log_success "aws-cli:     $(aws --version 2>&1 | head -1)"
  log_success "terraform:   $(terraform version -json 2>/dev/null | jq -r '.terraform_version' 2>/dev/null || terraform version | head -1)"
  log_success "jq:          $(jq --version)"
  log_success "claude:      インストール済み"
  echo ""
}

# ===== AWS認証確認 =====
check_aws_auth() {
  log_info "AWS認証情報を確認中... (profile: $PROFILE)"

  local identity
  if ! identity=$(aws sts get-caller-identity --profile "$PROFILE" --output json 2>&1); then
    log_error "AWS認証に失敗しました:"
    echo "$identity"
    echo ""
    echo "以下を確認してください:"
    echo "  1. AWS CLIが正しく設定されているか: aws configure --profile $PROFILE"
    echo "  2. 環境変数が設定されているか: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY"
    echo "  3. SSO認証が必要な場合: aws sso login --profile $PROFILE"
    exit 1
  fi

  local account region_check
  account=$(echo "$identity" | jq -r '.Account')
  log_success "AWS Account: $account"
  log_success "リージョン:  $REGION"
  log_success "プロファイル: $PROFILE"
  echo ""
}

# ===== ディレクトリ準備 =====
setup_directories() {
  mkdir -p \
    "$OUTPUT_DIR/scan_results" \
    "$OUTPUT_DIR/terraform" \
    "$OUTPUT_DIR/logs"

  # .gitignore作成
  cat > "$OUTPUT_DIR/terraform/.gitignore" <<'GITIGNORE'
# Terraform state files (contains sensitive data)
terraform.tfstate
terraform.tfstate.backup
*.tfstate
*.tfstate.*

# Terraform plan files
*.tfplan
plan.tfplan

# Terraform variable files (may contain secrets)
*.tfvars
*.auto.tfvars
!example.tfvars

# Terraform directories
.terraform/
.terraform.lock.hcl

# Crash logs
crash.log
crash.*.log
GITIGNORE

  log_success "出力ディレクトリを準備しました: $OUTPUT_DIR"
}

# ===== Phase 1: スキャン =====
run_scanner() {
  log_phase "[Phase 1/4] AWSリソーススキャン"

  if [[ "$SKIP_SCAN" == "true" ]]; then
    if [[ -f "$OUTPUT_DIR/scan_results/resources.json" ]]; then
      log_warn "スキャンをスキップ（既存のスキャン結果を使用）"
      local count
      count=$(jq '.summary.total' "$OUTPUT_DIR/scan_results/resources.json")
      log_info "既存スキャン結果: $count リソース"
      return 0
    else
      log_error "スキャン結果が見つかりません: $OUTPUT_DIR/scan_results/resources.json"
      exit 1
    fi
  fi

  log_info "スキャン開始 (region: $REGION, profile: $PROFILE)"
  log_info "スキャン結果の出力先: $OUTPUT_DIR/scan_results/resources.json"
  echo ""

  local scanner_prompt
  scanner_prompt=$(cat agents/01_scanner.md)
  scanner_prompt+="

## 実行パラメーター

- REGION: $REGION
- PROFILE: $PROFILE
- OUTPUT_DIR: $OUTPUT_DIR/scan_results
- REGISTRY_FILE: $(pwd)/scripts/resource_registry.json
- RESOURCE_FILTER: ${RESOURCE_FILTER:-全リソース}

上記パラメーターでAWSリソーススキャンを実行してください。
作業ディレクトリは $(pwd) です。"

  if ! claude --print --dangerously-skip-permissions "$scanner_prompt" \
    2>&1 | tee "$OUTPUT_DIR/logs/scan.log"; then
    log_error "スキャンエージェントでエラーが発生しました"
    log_info "ログ: $OUTPUT_DIR/logs/scan.log"
    exit 1
  fi

  if [[ ! -f "$OUTPUT_DIR/scan_results/resources.json" ]]; then
    log_error "スキャン結果ファイルが生成されませんでした"
    exit 1
  fi

  local count
  count=$(jq '.summary.total' "$OUTPUT_DIR/scan_results/resources.json")
  log_success "スキャン完了: $count リソースを検出"
}

# ===== Phase 2: コード生成 =====
run_generator() {
  log_phase "[Phase 2/4] Terraformコード生成"

  if [[ "$SKIP_GENERATE" == "true" ]]; then
    if ls "$OUTPUT_DIR/terraform/"*.tf >/dev/null 2>&1; then
      log_warn "コード生成をスキップ（既存のTFコードを使用）"
      local count
      count=$(ls "$OUTPUT_DIR/terraform/"*.tf | wc -l | tr -d ' ')
      log_info "既存TFファイル数: $count"
      return 0
    else
      log_error "TFファイルが見つかりません: $OUTPUT_DIR/terraform/*.tf"
      exit 1
    fi
  fi

  log_info "Terraformコードを生成中..."

  local generator_prompt
  generator_prompt=$(cat agents/02_generator.md)
  generator_prompt+="

## 実行パラメーター

- INPUT_FILE: $(pwd)/$OUTPUT_DIR/scan_results/resources.json
- OUTPUT_DIR: $(pwd)/$OUTPUT_DIR/terraform
- REGISTRY_FILE: $(pwd)/scripts/resource_registry.json

上記パラメーターでTerraformコードを生成してください。
作業ディレクトリは $(pwd) です。"

  if ! claude --print --dangerously-skip-permissions "$generator_prompt" \
    2>&1 | tee "$OUTPUT_DIR/logs/generate.log"; then
    log_error "コード生成エージェントでエラーが発生しました"
    log_info "ログ: $OUTPUT_DIR/logs/generate.log"
    exit 1
  fi

  local tf_count
  tf_count=$(ls "$OUTPUT_DIR/terraform/"*.tf 2>/dev/null | wc -l | tr -d ' ')
  log_success "コード生成完了: ${tf_count}個のTFファイルを生成"

  # terraform validate
  log_info "terraform validate を実行中..."
  if ! (cd "$OUTPUT_DIR/terraform" && terraform validate 2>&1); then
    log_warn "terraform validate で警告/エラーがあります（後続フェーズで修正します）"
  else
    log_success "terraform validate: OK"
  fi
}

# ===== Phase 3: terraform import =====
run_importer() {
  log_phase "[Phase 3/4] terraform import"

  if [[ "$SKIP_IMPORT" == "true" ]]; then
    log_warn "terraform importをスキップ（既存のstateを使用）"
    return 0
  fi

  log_info "terraform init を実行中..."
  if ! (cd "$OUTPUT_DIR/terraform" && terraform init -backend=false -input=false 2>&1 | tee "../logs/init.log"); then
    log_error "terraform init に失敗しました"
    log_info "ログ: $OUTPUT_DIR/logs/init.log"
    exit 1
  fi
  log_success "terraform init: OK"

  log_info "terraform import を実行中..."

  local importer_prompt
  importer_prompt=$(cat agents/03_importer.md)
  importer_prompt+="

## 実行パラメーター

- RESOURCES_FILE: $(pwd)/$OUTPUT_DIR/scan_results/resources.json
- TERRAFORM_DIR: $(pwd)/$OUTPUT_DIR/terraform
- REGION: $REGION
- PROFILE: $PROFILE

上記パラメーターで terraform import を実行してください。
terraform コマンドは $OUTPUT_DIR/terraform ディレクトリで実行してください。
import時は -var=\"aws_region=$REGION\" -var=\"aws_profile=$PROFILE\" を付けてください。
作業ディレクトリは $(pwd) です。"

  if ! claude --print --dangerously-skip-permissions "$importer_prompt" \
    2>&1 | tee "$OUTPUT_DIR/logs/import.log"; then
    log_warn "importエージェントで一部エラーが発生しました（続行します）"
    log_info "ログ: $OUTPUT_DIR/logs/import.log"
  fi

  if [[ -f "$OUTPUT_DIR/scan_results/import_results.json" ]]; then
    local succeeded failed
    succeeded=$(jq '.summary.succeeded' "$OUTPUT_DIR/scan_results/import_results.json")
    failed=$(jq '.summary.failed' "$OUTPUT_DIR/scan_results/import_results.json")
    log_success "import完了: 成功 $succeeded 件 / 失敗 $failed 件"
  else
    log_warn "import結果ファイルが生成されませんでした"
  fi
}

# ===== Phase 4: terraform plan & 修正ループ =====
run_plan_and_fix() {
  log_phase "[Phase 4/4] terraform plan & ドリフト修正ループ"

  local attempt=0
  local no_changes=false

  while [[ $attempt -lt $MAX_FIX_ATTEMPTS ]]; do
    attempt=$((attempt + 1))
    log_info "terraform plan を実行中... (試行 $attempt/$MAX_FIX_ATTEMPTS)"

    # terraform plan実行
    local plan_output
    if plan_output=$(cd "$OUTPUT_DIR/terraform" && \
      terraform plan \
        -var="aws_region=$REGION" \
        -var="aws_profile=$PROFILE" \
        -no-color \
        -detailed-exitcode \
        2>&1); then
      # exit code 0: No changes
      echo "$plan_output" > "$OUTPUT_DIR/scan_results/plan_output.txt"
      log_success "terraform plan: No changes! 🎉"
      no_changes=true
      break
    else
      local exit_code=$?
      echo "$plan_output" > "$OUTPUT_DIR/scan_results/plan_output.txt"

      if [[ $exit_code -eq 1 ]]; then
        # エラー
        log_error "terraform plan でエラーが発生しました"
        log_info "ログ: $OUTPUT_DIR/scan_results/plan_output.txt"

        if [[ "$INTERACTIVE" == "true" ]]; then
          echo ""
          read -r -p "エラーを修正して続行しますか? [y/N]: " answer
          [[ "$answer" =~ ^[Yy]$ ]] || break
        else
          break
        fi
      elif [[ $exit_code -eq 2 ]]; then
        # 変更あり
        local change_count
        change_count=$(echo "$plan_output" | grep -c "^  [~+-]" 2>/dev/null || echo "不明")
        log_warn "差分が検出されました (試行 $attempt/$MAX_FIX_ATTEMPTS)"
        log_info "差分をAIが修正中..."

        # Fixer agent起動
        local fixer_prompt
        fixer_prompt=$(cat agents/04_fixer.md)
        fixer_prompt+="

## 実行パラメーター

- PLAN_OUTPUT_FILE: $(pwd)/$OUTPUT_DIR/scan_results/plan_output.txt
- TERRAFORM_DIR: $(pwd)/$OUTPUT_DIR/terraform
- ATTEMPT_NUMBER: $attempt

plan出力を解析してTerraformコードを修正してください。
修正レポートを $OUTPUT_DIR/scan_results/fix_report_attempt_${attempt}.md に保存してください。
作業ディレクトリは $(pwd) です。"

        if ! claude --print --dangerously-skip-permissions "$fixer_prompt" \
          2>&1 | tee "$OUTPUT_DIR/logs/fix_attempt_${attempt}.log"; then
          log_warn "修正エージェントでエラーが発生しました"
        fi

        log_info "修正完了 (試行 $attempt)。再度 terraform plan を実行します..."
      fi
    fi
  done

  if [[ "$no_changes" == "true" ]]; then
    return 0
  else
    log_warn "最大試行回数 ($MAX_FIX_ATTEMPTS) に達しました。手動確認が必要な差分があります。"
    log_info "最後のplan結果: $OUTPUT_DIR/scan_results/plan_output.txt"
    return 1
  fi
}

# ===== 最終レポート =====
print_final_report() {
  local success=$1

  log_phase "=== 変換結果レポート ==="

  echo ""
  if [[ "$success" == "0" ]]; then
    echo -e "${GREEN}${BOLD}✓ No Changes 達成! AWSとTerraformが完全に一致しています。${RESET}"
  else
    echo -e "${YELLOW}${BOLD}⚠ 一部の差分が残っています。手動確認が必要です。${RESET}"
  fi

  echo ""
  echo "生成ファイル:"
  if ls "$OUTPUT_DIR/terraform/"*.tf >/dev/null 2>&1; then
    for f in "$OUTPUT_DIR/terraform/"*.tf; do
      local resource_count
      resource_count=$(grep -c '^resource "' "$f" 2>/dev/null || echo "0")
      echo "  $(basename "$f") ($resource_count リソース)"
    done
  fi

  echo ""
  echo "スキャン結果: $OUTPUT_DIR/scan_results/resources.json"
  echo "Terraformコード: $OUTPUT_DIR/terraform/"

  if [[ -f "$OUTPUT_DIR/scan_results/import_results.json" ]]; then
    echo ""
    echo "import結果:"
    echo "  成功: $(jq '.summary.succeeded' "$OUTPUT_DIR/scan_results/import_results.json") 件"
    echo "  失敗: $(jq '.summary.failed' "$OUTPUT_DIR/scan_results/import_results.json") 件"
  fi

  if [[ "$success" != "0" ]]; then
    echo ""
    echo "残った差分の確認:"
    echo "  cat $OUTPUT_DIR/scan_results/plan_output.txt"
    echo ""
    echo "手動で再実行:"
    echo "  cd $OUTPUT_DIR/terraform"
    echo "  terraform plan -var=\"aws_region=$REGION\" -var=\"aws_profile=$PROFILE\""
  fi

  echo ""
  echo -e "${CYAN}次のステップ:${RESET}"
  echo "  1. $OUTPUT_DIR/terraform/*.tf を確認・カスタマイズ"
  echo "  2. Terraformバックエンド（S3+DynamoDB）を設定"
  echo "  3. terraform plan で最終確認"
  echo "  4. チームのレビューを受けてマージ"
}

# ===== メイン処理 =====
main() {
  echo ""
  echo -e "${BOLD}${CYAN}"
  echo "  ╔═══════════════════════════════════════╗"
  echo "  ║      AWS to Terraform Agent           ║"
  echo "  ║  既存AWS環境を Terraform コードに変換  ║"
  echo "  ╚═══════════════════════════════════════╝"
  echo -e "${RESET}"

  log_info "設定:"
  log_info "  リージョン: $REGION"
  log_info "  プロファイル: $PROFILE"
  log_info "  出力先: $OUTPUT_DIR"
  log_info "  最大修正試行: $MAX_FIX_ATTEMPTS 回"
  [[ -n "$RESOURCE_FILTER" ]] && log_info "  リソースフィルター: $RESOURCE_FILTER"
  echo ""

  check_dependencies
  check_aws_auth
  setup_directories

  run_scanner
  run_generator
  run_importer

  local fix_result=0
  run_plan_and_fix || fix_result=$?

  print_final_report $fix_result

  exit $fix_result
}

# スクリプトが直接実行された場合のみ main を呼ぶ
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main
fi
