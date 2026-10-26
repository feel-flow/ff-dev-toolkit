#!/usr/bin/env bash
#
# Windows の Git Bash から `wsl` / `wsl.exe` で WSL 側の `bash` / `sh` を `-c` 付きで起動し、
# 本文に `$` が残る形を実行前に止めるガード（PreToolUse / Bash、Issue `#2341`。観測台帳 OBS-353）。
#
# ## なぜ止めるのか
#
# `wsl.exe` は `--exec` を付けない限り、受け取った引数を連結して WSL 側の既定シェルへ渡し直す。
# Git Bash 側で単一引用符にした `$変数` / `$?` も `bash -c` へ届く前に既定シェルで展開され、
# 空文字や誤った値のまま動く（clone 先が空になる・失敗した検査の rc を 0 と読む）。
# 正しい形は `wsl.exe --exec sh -c '<スクリプト>' sh <引数>`（ACE-2269-3）か、スクリプトを
# ファイルへ書いて `wsl.exe -- bash /mnt/c/…/script.sh` で起動する形。文書だけでは 4 回再発した。
#
# ## 判定規則はこの hook に置かない
#
# どの区間を止めるかの述語は共有ヘルパ `tests/lib/wsl-shell-scan.sh` が正本（字句解析は
# `tests/lib/review-shell-lex.sh`）。この hook が持つのは入力の取り出し・ホスト判定・抜け道・deny 文だけ。
#
# ## 発火条件（Windows の Git Bash だけ）
#
# `OSTYPE` が msys / cygwin のときだけ判定する。Linux / macOS では何もしない（WSL の中から interop で
# `wsl.exe` を呼ぶ形は対象外）。
#
# ## 針が当たらない入力の既定（TESTING.md の同名節）
#
# fail-open（無音 exit 0）にする面 — 判定の対象外であることが入力から確定している:
#   - MSYS / Cygwin でない / Bash 以外のツール / 空のコマンド / JSON でない入力 / jq 不在
#   - 生の入力が `wsl` と `$` を両方とも含むわけではない（どちらかが無ければ候補でない）
#   - ASDD の hooks 無効設定（rc 3）
#   - ASDD の判定 helper（hooks/asdd-hook-gate.sh）を source できない（stderr に知らせて通す。兄弟ガードと同じ）
#
# fail-closed（理由付き deny）にする面 — **候補コマンドに限る**（ヘルパが壊れた瞬間にすべての
# Bash 呼び出しが止まって復旧できなくなるのを避ける。guard-exit-code.sh と同じ面の切り方）:
#   - ASDD ゲートが検証不能を返す
#   - 判定ヘルパ・字句解析ヘルパが無い / 読めない / source に失敗する / 関数が無い
#   - 判定ヘルパが非 0 で終わる（引用符の未終端・awk の失敗）
#
# ## 抜け道
#
#   - この呼び出しだけ通す: コマンドの先頭の語を環境代入 `FF_WSL_SHELL_ACK=1` にする
#   - ガードごと止める: 環境変数 `FF_DEV_TOOLKIT_SKIP_WSL_SHELL_GUARD=1`
#
# stdin は早期 return より前に読み切る（ACE-1331-1）。

input=""
IFS= read -r -d '' input || true
case "${OSTYPE:-}" in msys* | cygwin*) ;; *) exit 0 ;; esac
[ "${FF_DEV_TOOLKIT_SKIP_WSL_SHELL_GUARD:-0}" = 1 ] && exit 0
case "$input" in *[wW][sS][lL]*) ;; *) exit 0 ;; esac
case "$input" in *'$'*) ;; *) exit 0 ;; esac
if ! source "${BASH_SOURCE[0]%/*}/asdd-hook-gate.sh"; then
  echo 'ff-dev-toolkit: ASDD Hook helper is unavailable; optional hook skipped' >&2
  exit 0
fi
asdd_hook_enabled hooks
asdd_rc=$?
[ "$asdd_rc" -eq 3 ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

deny() {
  local reason out
  reason="WSL シェル本文ガード: ${1} この Bash 呼び出しは未実行です。
wsl.exe は --exec を付けない限り引数を連結して WSL 側の既定シェルで解釈し直すので、単一引用符の中の \$変数 や \$? も bash / sh へ届く前に展開されます（空文字や誤った値のまま動き、失敗が成功に見えます）。
次のどちらかへ書き換えてください:
  - wsl.exe --exec sh -c '<スクリプト>' sh <引数>（--exec はシェルを介さず argv をそのまま渡す。値は \$1 で受ける）
  - スクリプトをファイルへ書き、wsl.exe -- bash /mnt/c/…/script.sh で起動する
誤検知の場合だけ、コマンド先頭に FF_WSL_SHELL_ACK=1 を付けられます。
ガード全体の無効化: FF_DEV_TOOLKIT_SKIP_WSL_SHELL_GUARD=1。"
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
case "$cmd" in *[wW][sS][lL]*) ;; *) exit 0 ;; esac
case "$cmd" in *'$'*) ;; *) exit 0 ;; esac
ack="$cmd"
while :; do
  case "$ack" in ' '* | $'\t'* | $'\n'*) ack="${ack#?}" ;; *) break ;; esac
done
case "$ack" in FF_WSL_SHELL_ACK=1[[:space:]]*) exit 0 ;; esac
[ "$asdd_rc" -eq 0 ] || deny '判定不能（ASDD 設定）。toolkit を復旧してください。'

lib_dir="${BASH_SOURCE[0]%/*}/../tests/lib"
for helper in "$lib_dir/review-shell-lex.sh" "$lib_dir/wsl-shell-scan.sh"; do
  if [ ! -r "$helper" ] || [ ! -s "$helper" ] || ! . "$helper"; then
    deny '判定不能（判定ヘルパを読めない）。toolkit を復旧してください。'
  fi
done
for fn in ff_lex_code ff_lex_segments ff_lex_tokens ff_wsl_shell_scan; do
  [ "$(type -t "$fn")" = function ] || deny '判定不能（判定ヘルパの関数が無い）。toolkit を復旧してください。'
done
result="$(ff_wsl_shell_scan "$cmd")" || deny '判定不能（字句解析の失敗・引用符の未終端）。コマンドを確かめてください。'
case "$result" in
  clear) exit 0 ;;
  blocked) deny 'wsl から bash / sh を -c で起動し、本文に $ が残っています。' ;;
  *) deny '判定不能（走査未完了）。toolkit を復旧してください。' ;;
esac
