#!/usr/bin/env bash
#
# 同じ Issue のブランチ作成と PR 作成を実行前に止めるガード（PreToolUse / Bash）。
#
# open PR が同じ Issue を閉じている、またはリモートに */#N-* のブランチがあるとき、
# git switch -c / git checkout -b / git worktree add -b と、その Issue を閉じる gh pr create を止める。
# 判定は tests/lib/issue-collision-scan.sh（同じ呼び出しの cd などの追跡は tests/lib/shell-cwd-track.sh）。
# この hook は停止文と通知だけを持つ。
#
# 照会が失敗した・打ち切られた・コマンドを読み切れないときは止めません。
# 実在を確認できた側があれば、もう片方が失敗しても止めます。
# PR 作成では、リモートの一致が現在ブランチ自身だけのときは止めません。
#
# jq が無い、JSON でない、Bash 以外、候補でないコマンドは黙って通します。
#
# 抜け道:
#   - 今回の区間だけ通す: 区間先頭の FF_ISSUE_COLLISION_ACK=1
#   - ガードごと止める: FF_DEV_TOOLKIT_SKIP=issue-collision
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
if ff_l4_skipped 'issue-collision'; then exit 0; fi

case "$input" in
  *switch*|*checkout*|*worktree*|*'pr create'*|*'pr new'*) ;;
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
    printf 'ff-dev-toolkit guard-issue-collision: deny の JSON を組み立てられませんでした（jq rc=%s）。exit 2 でブロックします。\n' "$rc" >&2
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

deny_collision() { # <詳細>
  deny "⚠️ ff-dev-toolkit guard（同じ Issue のブランチと PR）: 同じ Issue を閉じる open PR、または同じ番号のリモートブランチが見つかりました。この Bash 呼び出しは未実行です。
${1}
別の作業が同じ Issue を進めている可能性があります。見つかった PR とブランチを確かめてから、続けるなら区間先頭へ FF_ISSUE_COLLISION_ACK=1 を付けて再実行してください。
ガード全体の無効化: FF_DEV_TOOLKIT_SKIP=issue-collision。" \
    issue-collision tests/lib/issue-collision-scan.sh \
    "同じ Issue を閉じる open PR、または同じ番号のリモートブランチが既にあるため、ブランチ作成または PR 作成を止めました" \
    "見つかった PR 番号とリモートブランチ名を確かめる。続けるときはその区間の先頭へ FF_ISSUE_COLLISION_ACK=1 を付ける（無効化は FF_DEV_TOOLKIT_SKIP=issue-collision）"
}

rc=0
cmd="$(printf '%s' "$input" | jq -r 'select(type == "object" and .tool_name == "Bash") | .tool_input.command | select(type == "string")' 2>/dev/null)" || rc=$?
cwd="$(printf '%s' "$input" | jq -r 'if (.cwd | type) == "string" then .cwd else "" end' 2>/dev/null)" || cwd=""
cmd="${cmd//$'\r'/}"
[ "$rc" -eq 0 ] || exit 0
[ -n "$cmd" ] || exit 0
case "$cmd" in
  *switch*|*checkout*|*worktree*|*'pr create'*|*'pr new'*) ;;
  *) exit 0 ;;
esac

if [ "$asdd_rc" -ne 0 ]; then
  note "ℹ️ ff-dev-toolkit guard（同じ Issue のブランチと PR）: ASDD 設定を検証できないため、照会せずに通しました。"
fi

lib_dir="${BASH_SOURCE[0]%/*}/../tests/lib"
for helper in "$lib_dir/review-shell-lex.sh" "$lib_dir/shell-cwd-track.sh" "$lib_dir/issue-collision-scan.sh"; do
  # shellcheck disable=SC1090
  if [ ! -r "$helper" ] || [ ! -s "$helper" ] || ! . "$helper"; then
    note "ℹ️ ff-dev-toolkit guard（同じ Issue のブランチと PR）: 判定ヘルパを読めないため、照会せずに通しました。"
  fi
done
for fn in ff_lex_code ff_lex_segments ff_lex_tokens ff_lex_bodies ff_cwd_init ff_cwd_track ff_cwd_expand ff_issue_collision_judge; do
  [ "$(type -t "$fn")" = function ] || note "ℹ️ ff-dev-toolkit guard（同じ Issue のブランチと PR）: 判定関数が無いため、照会せずに通しました。"
done

result="$(ff_issue_collision_judge "$cmd" "$cwd")" || note "ℹ️ ff-dev-toolkit guard（同じ Issue のブランチと PR）: 判定が異常終了したため、照会せずに通しました。"
line="${result%%$'\n'*}"
rest="${result#*$'\n'}"
case "$line" in
  allow) exit 0 ;;
  note) note "ℹ️ ff-dev-toolkit guard（同じ Issue のブランチと PR）: ${rest%%$'\n'*}" ;;
  deny)
    detail=""
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      case "$row" in
        'issue '*) detail="${detail}Issue #${row#issue }
" ;;
        'pr '*) detail="${detail}open PR #${row#pr }
" ;;
        'branch '*) detail="${detail}リモートブランチ ${row#branch }
" ;;
        'side pr-query-failed') detail="${detail}PR の照会は失敗しましたが、ブランチの実在は確認できました。
" ;;
        'side branch-query-failed') detail="${detail}ブランチの照会は失敗しましたが、PR の実在は確認できました。
" ;;
      esac
    done <<EOF
$rest
EOF
    [ -n "$detail" ] || detail="一致の詳細を取り出せませんでした。"
    deny_collision "$detail" ;;
  *) note "ℹ️ ff-dev-toolkit guard（同じ Issue のブランチと PR）: 走査結果を解釈できないため、止めずに通しました。" ;;
esac
