#!/usr/bin/env bash
#
# 既定ブランチ上の git commit を実行前に止めるガード（PreToolUse / Bash）。
#
# 別セッションが同じ作業ツリーのブランチを既定ブランチへ戻したまま commit すると、
# 自分の作業が既定ブランチへ載る。判定は tests/lib/default-branch-commit-scan.sh
# （同じ呼び出しの cd などの追跡は tests/lib/shell-cwd-track.sh）。
# この hook は入力の取り出し、抜け道、停止文だけを持つ。
#
# 止めるのは、現在ブランチが refs/remotes/origin/HEAD の指す既定ブランチと一致し、
# 件名の先頭（空白を除いた 1 行目）が knowledge: でも release: でもない git commit。
# HEAD が detached、既定ブランチを確定できない、現在ブランチが違うときは止めない。
# 件名を確定できない commit は、既定ブランチ上では例外と確認できないので止める。
#
# 候補コマンドで判定を完了できないときは止めます（fail-closed）。
# jq が無い、JSON でない、Bash 以外、候補でないコマンドは黙って通します。
#
# 抜け道:
#   - 今回の区間だけ通す: 区間先頭の FF_DEFAULT_BRANCH_COMMIT_ACK=1
#   - ガードごと止める: FF_DEV_TOOLKIT_SKIP=default-branch-commit
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
if ff_l4_skipped 'default-branch-commit'; then exit 0; fi

case "$input" in
  *git*)
    case "$input" in
      *commit*) ;;
      *) exit 0 ;;
    esac ;;
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
    printf 'ff-dev-toolkit guard-default-branch-commit: deny の JSON を組み立てられませんでした（jq rc=%s）。exit 2 でブロックします。\n' "$rc" >&2
    printf '%s\n' "$reason" >&2
    exit 2
  fi
  printf '%s\n' "$out"
  exit 0
}

deny_unavailable() { # <理由>
  deny "⚠️ ff-dev-toolkit guard（既定ブランチ上の commit）: **判定不能**のため停止しました（${1}）。
無効化: FF_DEV_TOOLKIT_SKIP=default-branch-commit。" \
    default-branch-commit-unavailable tests/lib/default-branch-commit-scan.sh \
    "既定ブランチ上の commit かどうかの走査を完了できないため、判定不能として止めました" \
    "プラグインを復旧するか引用符を閉じて再実行する（恒久無効化が必要な場合のみ環境変数 FF_DEV_TOOLKIT_SKIP=default-branch-commit）"
}

deny_commit() { # <既定ブランチ名>
  deny "⚠️ ff-dev-toolkit guard（既定ブランチ上の commit）: 現在ブランチが ${1} です。別セッションが同じ作業ツリーでブランチを切り替えた可能性があります。\`git reflog -5\` で経緯を確かめ、自分のブランチへ戻してから commit してください。この Bash 呼び出しは未実行です。
件名の先頭（空白を除いた 1 行目）が knowledge: または release: の commit だけは通します。
誤検知のときは、その git commit の区間先頭へ FF_DEFAULT_BRANCH_COMMIT_ACK=1 を付けて再実行できます。
ガード全体の無効化: FF_DEV_TOOLKIT_SKIP=default-branch-commit。" \
    default-branch-commit tests/lib/default-branch-commit-scan.sh \
    "現在ブランチが既定ブランチ ${1} のまま git commit しようとしているため、別セッションの切り替えで自分の作業が既定ブランチへ載る前に止めました" \
    "git reflog -5 で経緯を確かめ、自分のブランチへ戻してから commit する（knowledge: と release: の件名、または区間先頭の FF_DEFAULT_BRANCH_COMMIT_ACK=1 だけが例外）"
}

rc=0
cmd="$(printf '%s' "$input" | jq -r 'select(type == "object" and .tool_name == "Bash") | .tool_input.command | select(type == "string")' 2>/dev/null)" || rc=$?
cwd="$(printf '%s' "$input" | jq -r 'if (.cwd | type) == "string" then .cwd else "" end' 2>/dev/null)" || cwd=""
cmd="${cmd//$'\r'/}"
[ "$rc" -eq 0 ] || exit 0
[ -n "$cmd" ] || exit 0
case "$cmd" in
  *git*)
    case "$cmd" in
      *commit*) ;;
      *) exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac

[ "$asdd_rc" -eq 0 ] || deny_unavailable 'ASDD 設定の検証失敗。toolkit を復旧してください'

lib_dir="${BASH_SOURCE[0]%/*}/../tests/lib"
for helper in "$lib_dir/review-shell-lex.sh" "$lib_dir/shell-cwd-track.sh" "$lib_dir/default-branch-commit-scan.sh"; do
  # shellcheck disable=SC1090
  if [ ! -r "$helper" ] || [ ! -s "$helper" ] || ! . "$helper"; then
    deny_unavailable '判定ヘルパを読めない。toolkit を復旧してください'
  fi
done
for fn in ff_lex_code ff_lex_bodies ff_lex_segments ff_lex_tokens ff_cwd_init ff_cwd_track ff_cwd_expand ff_default_branch_commit_judge; do
  [ "$(type -t "$fn")" = function ] || deny_unavailable '判定ヘルパの関数が無い。toolkit を復旧してください'
done

result="$(ff_default_branch_commit_judge "$cmd" "$cwd")" || deny_unavailable '判定ヘルパが異常終了した。toolkit を復旧してください'
line="${result%%$'\n'*}"
rest="${result#*$'\n'}"
case "$line" in
  allow) exit 0 ;;
  deny)
    branch="${rest%%$'\n'*}"
    [ -n "$branch" ] || branch='(不明)'
    deny_commit "$branch" ;;
  unavailable) deny_unavailable "${rest%%$'\n'*}" ;;
  *) deny_unavailable '走査未完了。toolkit を復旧してください' ;;
esac
