#!/usr/bin/env bash
#
# 未アサインの open Issue に対するブランチ作成を実行前に止めるガード（PreToolUse / Bash）。
#
# git switch -c / git checkout -b / git worktree add -b（-C / --create / --force-create / --orphan / -B を含む）
# で作るブランチ名から Issue 番号を抽出し、GitHub 上で open かつ現在の認証ユーザーが担当者に無い場合に止める。
# 判定は tests/lib/issue-assign-scan.sh（字句解析・作業ディレクトリ追跡・ブランチ番号抽出を再利用）。
# この hook は入力の取り出しと停止文・通知だけを持つ。
#
# gh 不在・照会失敗・JSON 異常・タイムアウト・認証ユーザー不明・コマンド読解不能は止めず理由を出す（fail-open）。
#
# jq が無い、JSON でない、Bash 以外、候補でないコマンドは黙って通します。
#
# 抜け道:
#   - 今回の区間だけ通す: 区間先頭の FF_ISSUE_ASSIGN_ACK=1
#   - ガードごと止める: FF_DEV_TOOLKIT_SKIP=issue-assign
# プロセス環境の ACK は見ません。
#
# stdin は早期 return より前に読み切ります。

input=""
IFS= read -r -d '' input || true

if ! source "${BASH_SOURCE[0]%/*}/asdd-hook-gate.sh"; then
  echo 'ff-dev-toolkit: ASDD Hook helper is unavailable; optional hook skipped' >&2
  exit 0
fi
asdd_hook_enabled hooks
asdd_rc=$?
[ "$asdd_rc" -eq 3 ] && exit 0

# shellcheck source=../scripts/lib/l4-declarations.sh
{ [ -r "${BASH_SOURCE[0]%/*}/../scripts/lib/l4-declarations.sh" ] && . "${BASH_SOURCE[0]%/*}/../scripts/lib/l4-declarations.sh"; } 2>/dev/null || ff_l4_skipped() { return 1; }
if ff_l4_skipped 'issue-assign'; then exit 0; fi

case "$input" in
  *switch*|*checkout*|*worktree*) ;;
  *) exit 0 ;;
esac
command -v jq >/dev/null 2>&1 || exit 0

STOP_BLOCK_LIB="${BASH_SOURCE[0]%/*}/../scripts/lib/stop-block.sh"

deny() { # <reason> <rule-id> <正本> <理由 1 行> <次の一手>
  local out rc block="" reason
  # shellcheck source=../scripts/lib/stop-block.sh
  block="$([ -f "$STOP_BLOCK_LIB" ] && [ -r "$STOP_BLOCK_LIB" ] && . "$STOP_BLOCK_LIB" 2>/dev/null \
    && declare -F ff_stop_block >/dev/null 2>&1 && ff_stop_block ガード "${2-}" "${3-}" "${4-}" "${5-}")"
  if [ -z "$block" ]; then
    block="止めた層: ガード
止めた規則: stop-block-unavailable（scripts/lib/stop-block.sh）— 停止文の共通形を読み込めません（元の規則: ${2-}）
次の一手: ff-dev-toolkit を更新・再インストールして scripts/lib/stop-block.sh を復旧する"
  fi
  reason="$1
$block"
  out="$(jq -nc --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' 2>/dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    printf 'ff-dev-toolkit guard-issue-assign: deny の JSON を組み立てられませんでした（jq rc=%s）。exit 2 でブロックします。\n' "$rc" >&2
    printf '%s\n' "$reason" >&2
    exit 2
  fi
  printf '%s\n' "$out"
  exit 0
}

note() { # <本文>
  local out
  out="$(jq -nc --arg m "$1" '{systemMessage:$m,hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$m}}' 2>/dev/null)" || exit 0
  [ -n "$out" ] || exit 0
  printf '%s\n' "$out"
  exit 0
}

deny_unassigned() { # <詳細>
  deny "⚠️ ff-dev-toolkit guard（着手時の自己アサイン）: ブランチを作成する前に、未アサインの open Issue へ自分を担当者として追加してください。この Bash 呼び出しは未実行です。
${1}紐づく GitHub Project がある場合は Status も着手中の選択肢へ更新してください（docs-template/05-operations/deployment/git-workflow.md「着手時の自己アサイン」）。
誤検知や意図して未アサインのまま進める場合は、区間先頭へ FF_ISSUE_ASSIGN_ACK=1 を付けて再実行してください（プロセス環境は無効）。
ガード全体の無効化: FF_DEV_TOOLKIT_SKIP=issue-assign。" \
    issue-assign tests/lib/issue-assign-scan.sh \
    "未アサインの open Issue に対してブランチを作成しようとしたため、実行前に止めました" \
    "案内の追加専用 API で自己アサインして再実行する（例外時は区間先頭へ FF_ISSUE_ASSIGN_ACK=1、無効化は FF_DEV_TOOLKIT_SKIP=issue-assign）"
}

rc=0
cmd="$(printf '%s' "$input" | jq -r 'select(type == "object" and .tool_name == "Bash") | .tool_input.command | select(type == "string")' 2>/dev/null)" || rc=$?
cwd="$(printf '%s' "$input" | jq -r 'if (.cwd | type) == "string" then .cwd else "" end' 2>/dev/null)" || cwd=""
cmd="${cmd//$'\r'/}"
[ "$rc" -eq 0 ] || exit 0
[ -n "$cmd" ] || exit 0
case "$cmd" in
  *switch*|*checkout*|*worktree*) ;;
  *) exit 0 ;;
esac

if [ "$asdd_rc" -ne 0 ]; then
  note "ℹ️ ff-dev-toolkit guard（着手時の自己アサイン）: ASDD 設定を検証できないため、照会せずに通しました。"
fi

root_dir="${BASH_SOURCE[0]%/*}/.."
for helper in \
  "$root_dir/tests/lib/review-shell-lex.sh" \
  "$root_dir/tests/lib/shell-cwd-track.sh" \
  "$root_dir/scripts/lib/branch-issue.sh" \
  "$root_dir/tests/lib/issue-assign-scan.sh"; do
  # shellcheck disable=SC1090
  if [ ! -r "$helper" ] || [ ! -s "$helper" ] || ! . "$helper"; then
    note "ℹ️ ff-dev-toolkit guard（着手時の自己アサイン）: 判定ヘルパを読めないため、照会せずに通しました。"
  fi
done
for fn in ff_lex_code ff_lex_segments ff_lex_tokens ff_lex_bodies ff_cwd_init ff_cwd_track ff_cwd_expand ff_cwd_unquote ff_branch_issue_parse ff_issue_assign_judge; do
  [ "$(type -t "$fn")" = function ] || note "ℹ️ ff-dev-toolkit guard（着手時の自己アサイン）: 判定関数が無いため、照会せずに通しました。"
done

result="$(ff_issue_assign_judge "$cmd" "$cwd")" || note "ℹ️ ff-dev-toolkit guard（着手時の自己アサイン）: 判定が異常終了したため、照会せずに通しました。"
line="${result%%$'\n'*}"
rest="${result#*$'\n'}"
case "$line" in
  allow) exit 0 ;;
  note) note "ℹ️ ff-dev-toolkit guard（着手時の自己アサイン）: ${rest%%$'\n'*}" ;;
  deny)
    detail=""
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      case "$row" in
        'unassigned '*)
          payload="${row#unassigned }"
          IFS=$'\t' read -r num host owner_repo login <<EOF
$payload
EOF
          if [ -n "$host" ] && [ "$host" != "-" ] && [ -n "$owner_repo" ] && [ "$owner_repo" != "-" ] && [ -n "$login" ]; then
            detail="${detail}- Issue #${num}（未アサイン / 認証ユーザー: ${login}）:
  gh api --hostname \"${host}\" --method POST \"repos/${owner_repo}/issues/${num}/assignees\" --field \"assignees[]=${login}\"
"
          else
            detail="${detail}- Issue #${num}（未アサイン / 認証ユーザー: ${login:-@me}）:
  gh issue edit ${num} --add-assignee @me
"
          fi ;;
      esac
    done <<EOF
$rest
EOF
    [ -n "$detail" ] || detail="- 対象の open Issue へ自己アサインしてください。
"
    deny_unassigned "$detail" ;;
  *) note "ℹ️ ff-dev-toolkit guard（着手時の自己アサイン）: 走査結果を解釈できないため、止めずに通しました。" ;;
esac
