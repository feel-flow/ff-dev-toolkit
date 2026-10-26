#!/usr/bin/env bash
# PreToolUse / Bash: prevent known credential-file display before execution.
# Candidate-only fail-closed scanner, optional hook lifecycle matches siblings.
# stdin is drained before any early return (ACE-1331-1).
input=""
IFS= read -r -d '' input || true
if ! source "${BASH_SOURCE[0]%/*}/asdd-hook-gate.sh"; then
  echo 'ff-dev-toolkit: ASDD Hook helper is unavailable; optional hook skipped' >&2
  exit 0
fi
asdd_hook_enabled hooks
asdd_rc=$?
[ "$asdd_rc" -eq 3 ] && exit 0
[ "${FF_DEV_TOOLKIT_SKIP_CREDENTIAL_OUTPUT_GUARD:-0}" = 1 ] && exit 0

candidate_name() {
  case "$1" in
    *[nN][pP][mM][rR][cC]*|*[nN][eE][tT][rR][cC]*|*[pP][yY][pP][iI][rR][cC]*|*[cC][rR][eE][dD][eE][nN][tT][iI][aA][lL][sS]*|*[cC][oO][nN][fF][iI][gG].[jJ][sS][oO][nN]*|*[hH][oO][sS][tT][sS].[yY][mM][lL]*|*[pP][nN][pP][mM]*) return 0 ;;
  esac
  return 1
}
candidate() {
  candidate_name "$1" && return 0
  local probe="$1"
  probe="${probe//\"/}"
  probe="${probe//\'/}"
  probe="${probe//\\/}"
  candidate_name "$probe"
}
candidate "$input" || exit 0
command -v jq >/dev/null 2>&1 || exit 0
deny() {
  local reason out
  reason="認証設定の表示ガード: ${1} この Bash 呼び出しは未実行です。
認証設定の本文を表示せず、npm config get registry のような非秘密キーだけを個別に照会してください。
grep -v による除外やキー名抽出は免除になりません。
誤検知の場合だけ、コマンド先頭に FF_CREDENTIAL_OUTPUT_ACK=1 を付けられます。
ガード全体の無効化: FF_DEV_TOOLKIT_SKIP_CREDENTIAL_OUTPUT_GUARD=1。"
  out="$(jq -nc --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' 2>/dev/null)" || {
    printf '%s\n' "$reason" >&2
    exit 2
  }
  [ -n "$out" ] || { printf '%s\n' "$reason" >&2; exit 2; }
  printf '%s\n' "$out"
  exit 0
}
rc=0
cmd="$(printf '%s' "$input" | jq -r 'select(type == "object" and .tool_name == "Bash") | .tool_input.command | select(type == "string")' 2>/dev/null)" || rc=$?
cmd="${cmd//$'\r'/}"
[ "$rc" -eq 5 ] && exit 0
[ "$rc" -eq 0 ] || deny '判定不能（入力の解析失敗）。toolkit を復旧してください。'
[ -n "$cmd" ] || exit 0
candidate "$cmd" || exit 0
ack="$cmd"
while :; do
  case "$ack" in ' '*|$'\t'*|$'\n'*) ack="${ack#?}" ;; *) break ;; esac
done
case "$ack" in FF_CREDENTIAL_OUTPUT_ACK=1[[:space:]]*) exit 0 ;; esac
[ "$asdd_rc" -eq 0 ] || deny '判定不能（ASDD 設定）。toolkit を復旧してください。'
scanner="${BASH_SOURCE[0]%/*}/../tests/lib/credential-output-scan.awk"
[ -f "$scanner" ] && [ -r "$scanner" ] || deny '判定不能（scanner 不在）。toolkit を復旧してください。'
# Shell punctuation and the protected basenames are ASCII. Byte-oriented awk
# preserves opaque UTF-8 path bytes and avoids BSD awk multibyte substring errors.
result="$(printf '%s\n' "$cmd" | LC_ALL=C awk -f "$scanner" 2>/dev/null)" || deny '判定不能（scanner 失敗）。toolkit を復旧してください。'
case "$result" in
  clear) exit 0 ;;
  blocked) deny '既知の認証設定を表示コマンドの入力に指定しています。' ;;
  *) deny '判定不能（走査未完了）。単純な非秘密キーの個別照会に書き換えてください。' ;;
esac
