#!/usr/bin/env bash
# zsh の equals 展開を deny、未引用 scalar を警告する。
# 判定本体は既存 lexer を共有する。入力コマンドは評価しない。
# 実値・配列型・setopt の状態は不明なので scalar は決して deny しない。
# heredoc 本文と引用された子シェルのプログラムは対象外。
# FF_DEV_TOOLKIT_SKIP_ZSH_EXPANSION_GUARD=1 で無効化。
# 呼び出し先頭の FF_ZSH_EXPANSION_ACK=1 は今回だけ両方を免除する。
# 出口は入力の hook_event_name で切り替える。PreToolUse は equals を deny、scalar を
# systemMessage（利用者の画面だけに出てエージェントへ届かない）で返す。PostToolUse は
# 同じ判定の scalar を hookSpecificOutput.additionalContext（エージェントの文脈へ届く
# 非停止の経路）で返し、equals は何も返さない（実行済みで止められず、止める判断は
# PreToolUse が済ませている）。判定不能は PostToolUse でも実行を止めず、`$` を含む呼び出しに
# 限り未検査である旨だけを additionalContext で知らせる（fail-soft）。
input=""
IFS= read -r -d '' input || true
[ "${FF_DEV_TOOLKIT_SKIP_ZSH_EXPANSION_GUARD:-0}" != 1 ] || exit 0
host_shell="${CLAUDE_CODE_SHELL:-${SHELL:-}}"
case "${host_shell##*/}" in zsh | zsh-*) ;; *) exit 0 ;; esac
case "$input" in *'='* | *'$'*) ;; *) exit 0 ;; esac
command -v jq >/dev/null 2>&1 || exit 0
cmd="$(printf '%s' "$input" | jq -r 'select(type == "object" and .tool_name == "Bash") | .tool_input.command | select(type == "string")' 2>/dev/null)" || exit 0
[ -n "$cmd" ] || exit 0
hook_event="$(printf '%s' "$input" | jq -r '.hook_event_name // empty | select(type == "string")' 2>/dev/null)" || hook_event=""
ack="$cmd"
while :; do
  case "$ack" in ' '* | $'\t'* | $'\n'*) ack="${ack#?}" ;; *) break ;; esac
done
case "$ack" in 'FF_ZSH_EXPANSION_ACK=1 '* | $'FF_ZSH_EXPANSION_ACK=1\t'*) exit 0 ;; esac

warn() {
  if [ "$hook_event" = PostToolUse ]; then
    jq -n --arg m "$1" \
      '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $m}}' || printf '%s\n' "$1" >&2
  else
    jq -n --arg m "$1" '{systemMessage: $m}' || printf '%s\n' "$1" >&2
  fi
  exit 0
}
deny() {
  local message="$1 コマンドの先頭へ FF_ZSH_EXPANSION_ACK=1 を付けると今回だけ通せます。無効化: FF_DEV_TOOLKIT_SKIP_ZSH_EXPANSION_GUARD=1。"
  jq -n --arg m "$message" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $m}}' && exit 0
  printf '%s\n' "$message" >&2
  exit 2
}
unavailable() {
  # PostToolUse は実行済みなので止めず、`$` を含む呼び出しに限り未検査である旨だけを
  # 文脈へ載せる（`$` を含まない呼び出しには scalar が在り得ないので何も足さない）。
  if [ "$hook_event" = PostToolUse ]; then
    case "$cmd" in
      *'$'*) warn "zsh 展開ガード: 判定不能（$1）。直前の Bash 呼び出しの未引用変数の検査を完了できませんでした。" ;;
      *) exit 0 ;;
    esac
  fi
  # 停止候補が生文字列にも無い scalar-only の入力は、解析失敗でも止めない。
  case "$cmd" in
    =?* | *' ='?* | *$'\t='?* | *$'\n='?*) deny "zsh 展開ガード: 判定不能（$1）。ヘルパを更新・復旧してください。" ;;
    *) warn "zsh 展開ガード: 判定不能（$1）。未引用変数の検査を完了できませんでした。" ;;
  esac
}
if ! source "${BASH_SOURCE[0]%/*}/../../hooks/asdd-hook-gate.sh"; then
  unavailable 'ASDD helper 不在'
fi
asdd_hook_enabled hooks
asdd_rc=$?
case "$asdd_rc" in 3) exit 0 ;; esac
helper_dir="${BASH_SOURCE[0]%/*}"
for helper in heredoc-strip.sh zsh-glob-nomatch.sh; do
  [ -r "$helper_dir/$helper" ] || unavailable "ヘルパ不在: $helper"
  source "$helper_dir/$helper" || unavailable "ヘルパ読込失敗: $helper"
done
for fn in ff_heredoc_strip ff_zsh_expansion_scan; do
  [ "$(type -t "$fn")" = function ] || unavailable "関数不在: $fn"
done
rc=0
code="$(ff_heredoc_strip "$cmd")" || rc=$?
case "$rc" in 0 | 3) ;; *) unavailable 'heredoc 走査未完了' ;; esac
hits="$(ff_zsh_expansion_scan "$code")" || unavailable '引用・展開の走査未完了'
# PostToolUse は scalar だけを見る（equals の停止は PreToolUse の担当で、ここで equals を
# 先に当てると同じ呼び出しの scalar 警告を落とす）。
scalar_prefix=""
if [ "$hook_event" = PostToolUse ]; then
  case "$hits" in *scalar*) hits=scalar ;; *) exit 0 ;; esac
  # 検出した経路だけに付ける（判定不能の通知を検出と取り違えさせない）。
  scalar_prefix='直前の Bash 呼び出しは zsh で実行されたため、未引用の変数が 1 語のまま渡り結果が空振りしている可能性があります。'
fi
if [ "$asdd_rc" -ne 0 ]; then
  case "$hits" in
    *equals*) deny 'zsh 展開ガード: 判定不能（ASDD 設定を検証できない）。.asdd/config.json と node の実行環境を復旧してください。' ;;
    *scalar*) warn 'zsh 展開ガード: ASDD 設定を検証できず未引用変数の検査を完了できませんでした。.asdd/config.json と node の実行環境を復旧してください。' ;;
    *) exit 0 ;;
  esac
fi
case "$hits" in
  *equals*) deny 'zsh の未引用の = 始まりの語はコマンドパス展開となり、not found で後続も実行されない場合があります。echo "===" / [ a "==" b ] のように語を引用してください。意図的な =cmd や NO_EQUALS 設定時は抜け道を使えます。' ;;
  *scalar*) warn "${scalar_prefix}"'zsh の未引用 $VAR / ${VAR} は既定で単語分割されません。空白を含む値を複数引数として渡す意図なら配列と "${args[@]}"、または bash の引用付き heredoc を使ってください。単一引数の意図なら "$VAR" と引用してください。この警告は実値・配列型を判定せず、コマンドを停止しません。' ;;
esac
exit 0
