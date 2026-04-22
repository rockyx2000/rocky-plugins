#!/usr/bin/env bash
#
# [aws-to-terraform] PostToolUse: 管理者認証情報の検出フック
#
# aws sts get-caller-identity の実行後に出力を解析し、
# ReadOnlyAccess 以外での実行をすべてブロックする。
#
# assumed-role: ARN のロール名で判定
# IAM ユーザー: aws iam API でアタッチされたポリシーを確認（直接 + グループ経由）
#   - Administrator / PowerUser を含むポリシーがあればブロック
#   - ReadOnly を含むポリシーがなければブロック
#   - IAM API 呼び出し失敗時はフェイルセーフでブロック

input=$(cat)
tool_name=$(echo "$input" | jq -r '.tool_name' 2>/dev/null || echo "")
command=$(echo "$input" | jq -r '.tool_input.command' 2>/dev/null || echo "")

# Bash 以外は対象外
if [ "$tool_name" != "Bash" ]; then
  exit 0
fi

# aws sts get-caller-identity 以外はスキップ
if [[ ! "$command" =~ aws[[:space:]]+sts[[:space:]]+get-caller-identity ]]; then
  exit 0
fi

# コマンドの出力から ARN を取得
output=$(echo "$input" | jq -r '.tool_response.output // ""' 2>/dev/null || echo "")
arn=$(echo "$output" | jq -r '.Arn // ""' 2>/dev/null || echo "")

# ARN が取得できない場合はスキップ（エラーは通常のハンドリングに任せる）
[ -z "$arn" ] && exit 0

deny() {
  local msg="$1"
  jq -n \
    --arg msg "$(printf '%b' "$msg")" \
    --arg event "PostToolUse" \
    '{
      hookSpecificOutput: {
        hookEventName: $event,
        permissionDecision: "deny"
      },
      systemMessage: $msg
    }'
  exit 0
}

# ポリシー名リストから admin/readonly を判定するヘルパー
has_admin_policy() {
  echo "$1" | grep -qiE 'Administrator|PowerUser'
}
has_readonly_policy() {
  echo "$1" | grep -qiE 'ReadOnly'
}

# root アカウントチェック
if [[ "$arn" =~ :root$ ]]; then
  deny "[aws-to-terraform] rootアカウントを検出しました。\nARN: ${arn}\n\n安全のため処理を停止します。ReadOnlyAccess ロールを使用してください。"
fi

# assumed-role: ARN のロール名で判定
if [[ "$arn" =~ assumed-role/([^/]+)/ ]]; then
  role_name="${BASH_REMATCH[1]}"

  if [[ "$role_name" =~ [Aa]dministrator || "$role_name" =~ [Pp]ower[Uu]ser ]]; then
    deny "[aws-to-terraform] 管理者権限ロールを検出しました。\nARN: ${arn}\n\n安全のため処理を停止します。ReadOnlyAccess ロールを使用してください。"
  fi

  if [[ ! "$role_name" =~ [Rr]ead[Oo]nly ]]; then
    deny "[aws-to-terraform] ReadOnlyAccess 以外のロールを検出しました。\nARN: ${arn}\n\nこのツールは ReadOnlyAccess ロールでのみ実行できます。"
  fi

  exit 0
fi

# IAM ユーザー: ポリシーを aws iam API で確認
if [[ "$arn" =~ :user/(.+)$ ]]; then
  username="${BASH_REMATCH[1]}"

  # 直接アタッチされたマネージドポリシーを取得
  user_policies=$(aws iam list-attached-user-policies \
    --user-name "$username" \
    --query 'AttachedPolicies[].PolicyName' \
    --output text 2>/dev/null) \
    || deny "[aws-to-terraform] IAM ポリシーの確認に失敗しました（権限不足の可能性）。\nARN: ${arn}\n\n安全のため処理を停止します。"

  # グループ経由のポリシーを取得
  groups=$(aws iam list-groups-for-user \
    --user-name "$username" \
    --query 'Groups[].GroupName' \
    --output text 2>/dev/null) \
    || deny "[aws-to-terraform] グループ情報の確認に失敗しました（権限不足の可能性）。\nARN: ${arn}\n\n安全のため処理を停止します。"

  group_policies=""
  for group in $groups; do
    gp=$(aws iam list-attached-group-policies \
      --group-name "$group" \
      --query 'AttachedPolicies[].PolicyName' \
      --output text 2>/dev/null) \
      || deny "[aws-to-terraform] グループ($group)のポリシー確認に失敗しました。\nARN: ${arn}\n\n安全のため処理を停止します。"
    group_policies="$group_policies $gp"
  done

  all_policies="$user_policies $group_policies"

  if has_admin_policy "$all_policies"; then
    matched=$(echo "$all_policies" | tr ' ' '\n' | grep -iE 'Administrator|PowerUser' | paste -sd ',' -)
    deny "[aws-to-terraform] 管理者権限ポリシーが付与された IAM ユーザーを検出しました。\nARN: ${arn}\n検出ポリシー: ${matched}\n\n安全のため処理を停止します。ReadOnlyAccess ポリシーのみが付与された認証情報を使用してください。"
  fi

  if ! has_readonly_policy "$all_policies"; then
    deny "[aws-to-terraform] ReadOnlyAccess ポリシーが付与されていない IAM ユーザーを検出しました。\nARN: ${arn}\n\nこのツールは ReadOnlyAccess ポリシーが付与された認証情報でのみ実行できます。"
  fi

  exit 0
fi

# root / assumed-role / IAM ユーザー以外（フェデレーション等）はブロック
deny "[aws-to-terraform] 未対応の認証情報タイプを検出しました。\nARN: ${arn}\n\nこのツールは ReadOnlyAccess ロール（assumed-role）または ReadOnlyAccess ポリシーが付与された IAM ユーザーでのみ実行できます。"
