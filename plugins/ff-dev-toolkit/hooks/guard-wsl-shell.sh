#!/usr/bin/env bash
#
# Windows の Git Bash から `wsl` / `wsl.exe` を起動するときの事前展開事故 2 種を実行前に止めるガード
# （PreToolUse / Bash、Issue `#2341` / `#2688`。観測台帳 OBS-353 / OBS-327）。
#
# ## なぜ止めるのか
#
# 1. `wsl-shell`: `wsl.exe` は `--exec` を付けない限り、引数を連結して WSL 側の既定シェルへ渡し直す。
#    Git Bash 側で単一引用符にした `$変数` / `$?` も `bash -c` へ届く前に既定シェルで展開され、
#    空文字や誤った値のまま動く。正しい形は `wsl.exe --exec sh -c '<スクリプト>' sh <引数>`（ACE-2269-3）か、
#    スクリプトファイルを `MSYS_NO_PATHCONV=1 wsl.exe -- bash /mnt/c/…/script.sh` で起動する形。
# 2. `wsl-pathconv`: Git Bash（MSYS）は native exe（`wsl` / `wsl.exe`）への `/` 始まり POSIX パスや
#    `--flag=/…` / `VAR=/…` 引数を `--exec` の有無に関係なく `C:/Program Files/Git/…` へ書き換え、
#    WSL 側で rc 127 で即終了する。先頭に `MSYS_NO_PATHCONV=1`（または該当 `MSYS2_ARG_CONV_EXCL`）を置く。
#
# ## 判定規則はこの hook に置かない
#
# どの区間を止めるかの述語は共有ヘルパ `tests/lib/wsl-shell-scan.sh` が正本（字句解析は
# `tests/lib/review-shell-lex.sh`）。この hook が持つのは入力の取り出し・ホスト判定・抜け道・
# 停止文の組み立て（`scripts/lib/stop-block.sh`、Issue `#2712`）だけ。
#
# ## 発火条件（Windows の Git Bash だけ）
#
# `scripts/lib/wsl-notice.sh` の `ff_host_is_msys` が真のときだけ判定する（Issue `#2713`）。
# Linux / macOS では何もしない（WSL の中から interop で `wsl.exe` を呼ぶ形は対象外）。
#
# ## 針が当たらない入力の既定（TESTING.md の同名節）
#
# fail-open（無音 exit 0）にする面 — 判定の対象外であることが入力から確定している:
#   - MSYS / Cygwin でない（`wsl-notice.sh` 不在時も含む） / Bash 以外のツール / 空コマンド / 非 JSON / jq 不在
#   - `wsl` と対象文字（`$` または `/`、`wsl-pathconv` 無効/ACK 時は `$` のみ）を両方含む候補でない
#   - ASDD の hooks 無効設定（rc 3）
#   - ASDD の判定 helper（`hooks/asdd-hook-gate.sh`）を source できない（stderr に知らせて通す。兄弟ガードと同じ）
#
# fail-closed（理由付き deny）にする面 — **候補コマンドに限る**:
#   - ASDD ゲートが検証不能を返す
#   - 判定ヘルパ・字句解析ヘルパが無い / 読めない / source に失敗する / 関数が無い
#   - 判定ヘルパが非 0 で終わる（引用符の未終端・awk の失敗）
#
# ## 抜け道
#
#   - 今回の呼び出しだけ通す: 先頭へ `FF_WSL_SHELL_ACK=1`（全体）または `FF_WSL_PATHCONV_ACK=1`（パス変換のみ）
#   - ガードごと止める: `FF_DEV_TOOLKIT_SKIP=wsl-shell`（covers で `wsl-pathconv` も止める）または `FF_DEV_TOOLKIT_SKIP=wsl-pathconv`
#
# stdin は早期 return より前に読み切る（ACE-1331-1）。

input=""
IFS= read -r -d '' input || true

if ! source "${BASH_SOURCE[0]%/*}/asdd-hook-gate.sh"; then
  echo 'ff-dev-toolkit: ASDD Hook helper is unavailable; optional hook skipped' >&2
  exit 0
fi
asdd_hook_enabled hooks
asdd_rc=$?
[ "$asdd_rc" -eq 3 ] && exit 0

wsl_lib="${BASH_SOURCE[0]%/*}/../scripts/lib/wsl-notice.sh"
# shellcheck source=../scripts/lib/wsl-notice.sh
[ -f "$wsl_lib" ] && [ -r "$wsl_lib" ] && . "$wsl_lib" 2>/dev/null || exit 0
declare -F ff_host_is_msys >/dev/null 2>&1 || exit 0
ff_host_is_msys "${OSTYPE:-}" || exit 0

# 宣言の判定は共通関数 scripts/lib/l4-declarations.sh（ADR-087）。読めないときは止めない側に倒す。
# shellcheck source=../scripts/lib/l4-declarations.sh
{ [ -r "${BASH_SOURCE[0]%/*}/../scripts/lib/l4-declarations.sh" ] && . "${BASH_SOURCE[0]%/*}/../scripts/lib/l4-declarations.sh"; } 2>/dev/null || ff_l4_skipped() { return 1; }
if ff_l4_skipped 'wsl-shell'; then exit 0; fi
ff_wsl_pathconv_skipped=0
if ff_l4_skipped 'wsl-pathconv'; then ff_wsl_pathconv_skipped=1; fi

case "$input" in *[wW][sS][lL]*) ;; *) exit 0 ;; esac
if [ "$ff_wsl_pathconv_skipped" -eq 1 ]; then
  case "$input" in *'$'*) ;; *) exit 0 ;; esac
else
  case "$input" in *'$'* | */*) ;; *) exit 0 ;; esac
fi
command -v jq >/dev/null 2>&1 || exit 0

# 停止文の共通形（末尾 3 行。scripts/lib/stop-block.sh / Issue `#2712`）。deny するときだけ読む。
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
    printf 'ff-dev-toolkit guard-wsl-shell: deny の JSON を組み立てられませんでした（jq rc=%s）。exit 2 でブロックします。\n' "$rc" >&2
    printf '%s\n' "$reason" >&2
    exit 2
  fi
  printf '%s\n' "$out"
  exit 0
}

deny_unavailable() { # <理由>
  deny "⚠️ ff-dev-toolkit guard（WSL シェル・パス変換）: **判定不能**のため停止しました（${1}）。
無効化: FF_DEV_TOOLKIT_SKIP=wsl-shell。" \
    wsl-shell-unavailable tests/lib/wsl-shell-scan.sh \
    "WSL ガード候補の走査を完了できないため、判定不能として止めました" \
    "プラグインを復旧するか引用符・構文を直して再実行する（恒久無効化が必要な場合のみ環境変数 FF_DEV_TOOLKIT_SKIP=wsl-shell）"
}

deny_shell() {
  deny "⚠️ ff-dev-toolkit guard（WSL シェル本文の \$ 展開）: wsl から bash / sh を -c で起動し、本文に \$ が残っています。この Bash 呼び出しは未実行です。
wsl.exe は --exec を付けない限り引数を連結して WSL 側の既定シェルで解釈し直すので、単一引用符の中の \$変数 や \$? も bash / sh へ届く前に展開されます（空文字や誤った値のまま動き、失敗が成功に見えます）。
次のどちらかへ書き換えてください:
  - wsl.exe --exec sh -c '<スクリプト>' sh <引数>（--exec はシェルを介さず argv をそのまま渡す。値は \$1 で受ける）
  - スクリプトをファイルへ書き、MSYS_NO_PATHCONV=1 wsl.exe -- bash /mnt/c/…/script.sh で起動する
誤検知の場合だけ、wsl 区間先頭へ FF_WSL_SHELL_ACK=1 を付けられます。
ガード全体の無効化: FF_DEV_TOOLKIT_SKIP=wsl-shell。" \
    wsl-shell tests/lib/wsl-shell-scan.sh \
    "wsl から bash / sh を -c で起動する本文に \$ が残るため、--exec 無しでは WSL 既定シェルが先に展開して壊れます" \
    "wsl.exe --exec sh -c '<スクリプト>' sh <引数> か MSYS_NO_PATHCONV=1 wsl.exe -- bash /mnt/c/…/script.sh へ書き換える（誤検知のみ wsl 区間先頭に FF_WSL_SHELL_ACK=1）"
}

deny_pathconv() {
  deny "⚠️ ff-dev-toolkit guard（MSYS の POSIX パス変換）: wsl / wsl.exe への引数に MSYS_NO_PATHCONV=1 無しの / 始まり POSIX パスが含まれています。この Bash 呼び出しは未実行です。
Git Bash（MSYS）は native exe（wsl.exe 等）へ渡す / 始まり引数を --exec の有無に関係なく C:/Program Files/Git/… へ書き換えるため、WSL 側で rc 127 になります。
wsl 区間先頭へ MSYS_NO_PATHCONV=1（複合コマンド全体へ効かせる場合は先行 export MSYS_NO_PATHCONV=1;、または対象引数を覆う MSYS2_ARG_CONV_EXCL）を付けて再実行してください:
  - MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu --exec bash /mnt/c/…/script.sh
誤検知の場合だけ、wsl 区間先頭へ FF_WSL_PATHCONV_ACK=1（または FF_WSL_SHELL_ACK=1）を付けられます。
無効化: FF_DEV_TOOLKIT_SKIP=wsl-pathconv（全体は wsl-shell）。" \
    wsl-pathconv tests/lib/wsl-shell-scan.sh \
    "Git Bash から wsl / wsl.exe へ / 始まりの POSIX パス引数を渡すと、--exec でも MSYS が Windows 側パスへ書き換えて rc 127 で壊れます" \
    "wsl 区間先頭へ MSYS_NO_PATHCONV=1 を付けて再実行する（例: MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu --exec bash /mnt/c/…/script.sh。誤検知のみ wsl 区間先頭に FF_WSL_PATHCONV_ACK=1）"
}

deny_both() {
  deny "⚠️ ff-dev-toolkit guard（WSL シェル本文 + MSYS パス変換）: wsl の -c 本文に \$ が残り、さらに MSYS_NO_PATHCONV=1 無しの / 始まり POSIX パス引数も含まれています。この Bash 呼び出しは未実行です。
- --exec 無しの -c 本文では \$変数 / \$? が WSL 既定シェルに先食いされ、さらに / 始まり引数は MSYS が Windows パスへ書き換えます。
次のどちらかで両方を解消してください:
  - MSYS_NO_PATHCONV=1 wsl.exe --exec sh -c '<スクリプト>' sh <引数>
  - スクリプトをファイルへ書き、MSYS_NO_PATHCONV=1 wsl.exe -- bash /mnt/c/…/script.sh で起動する
誤検知の場合だけ、wsl 区間先頭へ FF_WSL_SHELL_ACK=1 を付けられます。
ガード全体の無効化: FF_DEV_TOOLKIT_SKIP=wsl-shell。" \
    wsl-shell tests/lib/wsl-shell-scan.sh \
    "wsl の -c 本文に \$ が残り、さらに MSYS_NO_PATHCONV=1 無しの / 始まり POSIX パス引数も含むため二重の事前展開で壊れます" \
    "MSYS_NO_PATHCONV=1 を wsl 区間先頭へ前置し --exec sh -c かスクリプトファイル経由へ書き換える（誤検知のみ wsl 区間先頭に FF_WSL_SHELL_ACK=1）"
}

rc=0
cmd="$(printf '%s' "$input" | jq -r 'select(type == "object" and .tool_name == "Bash") | .tool_input.command | select(type == "string")' 2>/dev/null)" || rc=$?
cmd="${cmd//$'\r'/}"
[ "$rc" -eq 5 ] && exit 0
[ "$rc" -eq 0 ] || deny_unavailable '入力の解析失敗。toolkit を復旧してください'
[ -n "$cmd" ] || exit 0
case "$cmd" in *[wW][sS][lL]*) ;; *) exit 0 ;; esac

if [ "$ff_wsl_pathconv_skipped" -eq 1 ]; then
  case "$cmd" in *'$'*) ;; *) exit 0 ;; esac
else
  case "$cmd" in *'$'* | */*) ;; *) exit 0 ;; esac
fi

[ "$asdd_rc" -eq 0 ] || deny_unavailable 'ASDD 設定の検証失敗。toolkit を復旧してください'

lib_dir="${BASH_SOURCE[0]%/*}/../tests/lib"
for helper in "$lib_dir/review-shell-lex.sh" "$lib_dir/wsl-shell-scan.sh"; do
  # shellcheck disable=SC1090
  if [ ! -r "$helper" ] || [ ! -s "$helper" ] || ! . "$helper"; then
    deny_unavailable '判定ヘルパを読めない。toolkit を復旧してください'
  fi
done
for fn in ff_lex_code ff_lex_segments ff_lex_tokens ff_wsl_shell_scan; do
  [ "$(type -t "$fn")" = function ] || deny_unavailable '判定ヘルパの関数が無い。toolkit を復旧してください'
done
result="$(ff_wsl_shell_scan "$cmd" 1)" || deny_unavailable '字句解析の失敗・引用符の未終端。コマンドを確かめてください'
case "$result" in
  clear) exit 0 ;;
  shell) deny_shell ;;
  pathconv)
    [ "$ff_wsl_pathconv_skipped" -eq 1 ] && exit 0
    deny_pathconv ;;
  both)
    if [ "$ff_wsl_pathconv_skipped" -eq 1 ]; then
      deny_shell
    else
      deny_both
    fi ;;
  *) deny_unavailable '走査未完了。toolkit を復旧してください' ;;
esac
