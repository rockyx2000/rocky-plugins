#!/usr/bin/env bash
#
# [aws-to-terraform] terraform apply / terraform destroy を拒否するフック
#
# このプラグインはTerraformコードの生成とimportが目的のため、
# インフラを実際に変更・削除するコマンドは実行させない。

input=$(cat)
tool_name=$(echo "$input" | jq -r '.tool_name' 2>/dev/null || echo "")
command=$(echo "$input" | jq -r '.tool_input.command' 2>/dev/null || echo "")

# Bash 以外は対象外
if [ "$tool_name" != "Bash" ]; then
  exit 0
fi

# コマンドを ; && || で分割して各部分をチェック
check_command_part() {
  local cmd
  cmd=$(echo "$1" | sed 's/^[[:space:]]*//')

  if [[ "$cmd" =~ ^terraform[[:space:]]+apply([[:space:]]|$) ]]; then
    echo "Error: [aws-to-terraform] terraform apply は実行できません。このプラグインはコード生成・import専用です。" >&2
    exit 2
  fi

  if [[ "$cmd" =~ ^terraform[[:space:]]+destroy([[:space:]]|$) ]]; then
    echo "Error: [aws-to-terraform] terraform destroy は実行できません。このプラグインはコード生成・import専用です。" >&2
    exit 2
  fi
}

# コマンド全体をチェック
check_command_part "$command"

# ; && || で分割して各部分もチェック
while IFS= read -r part; do
  [ -z "$(echo "$part" | tr -d '[:space:]')" ] && continue
  check_command_part "$part"
done < <(echo "$command" | tr ';' '\n' | \
         awk '{gsub(/&&|\|\|/, "\n"); print}' | \
         grep -v '^[[:space:]]*$')

exit 0
