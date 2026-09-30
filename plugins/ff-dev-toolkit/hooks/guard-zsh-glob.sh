#!/usr/bin/env bash

#
# zsh で必ず NOMATCH になる未引用 glob（`--flag=<glob>` 形）を実行前に止めるガード
# （PreToolUse / Bash、Issue `#1774` / 公開 https://github.com/feel-flow/ff-dev-toolkit/issues/118。導入先の観測台帳
# hearing-realtime OBS-135 — Count 21 / jbta-hp OBS-028）。
#
# ## なぜ呼び出し面に置くのか
#
# zsh は既定で `NOMATCH` が有効なので、マッチ 0 件の未引用 glob を含むコマンドは
# **実行されない**（実測: `zsh -fc 'echo --a=*; echo after'` は rc=1 で after も出ない。
# Claude Code の Bash ツールと同じ `eval` 経由でも、その呼び出しの残りは走らない）。`grep -rn x docs --include=*.md` の `--include=*.md` は語全体が
# 1 つの glob として評価され、「`--include=` で始まるファイル名」を探しにいくので、
# cwd に `.md` があってもなくても 0 件になる（`--include=` で始まる名前のファイルが実在しない限り
# **必ず**。そういう名前のファイルは通常の作業ツリーに無い）（bash は 0 件の glob を語のまま
# 残すので通る）。手前のコマンドだけが走った状態で中断されるので、走査が静かに欠ける。
#
# 導入先は追跡ファイルの静的検査を実測して「入れない」と決着している（真陽性 0）—
# この壊れ方は zsh で実行される Bash ツール呼び出しに固有で、追跡下の shell スクリプトは
# bash / sh で書かれているからである。届くのは Bash ツールへ渡す文字列そのもので、
# そこは PreToolUse の担当範囲になる。文言（CLAUDE.md の規律）での対策は導入先で 6 回以上
# 再発しており上限に達している。
#
# ## 判定規則はこの hook に置かない
#
# どの語を NOMATCH と断定するかの述語・glob として評価されない文脈（引用・展開結果・
# `case` パターン・`[[ ]]`・`noglob`・コメント）の扱いは、共有ヘルパ
# `tests/lib/zsh-glob-nomatch.sh` が正本（OBS-225: 判定本体を最初から共有ライブラリへ
# 置く）。この hook が持つのは入力の取り出し・ホスト判定・抜け道・deny 文だけである。
# 述語は `-` で始まる語の `=` より右に未引用の `*` / `?` / `[` がある形だけに絞っており、
# cwd の状態に依存しないので呼び出し文字列だけで真陽性と断定できる。一般のパス glob
# （`ls *.md`）は cwd 次第でマッチするので対象に入れない。
#
# ## 発火条件（zsh ホストだけ）
#
# Bash ツールを動かすシェルが zsh のときだけ発火する。判定は Claude Code がシェルを
# 選ぶのと同じ入力 — `CLAUDE_CODE_SHELL`（明示の上書き）、無ければ `SHELL` — の basename。
# bash ホスト（Linux の既定・Windows の Git Bash）では同じ記法が正しく動くので発火させない。
# どちらも未設定・zsh / bash 以外のときも発火させない（ホストのシェルを知らないまま
# 止めると、正しく動くコマンドを止める側へ倒れる）。
#
# ## 針が当たらない入力の既定（TESTING.md の同名節）
#
# fail-open（無音 exit 0）にする面 — 判定の対象外であることが入力から確定している:
#   - Bash 以外のツール / 空のコマンド / JSON でない入力（jq の rc=5）
#   - zsh ホストでない / `jq` 不在（コマンド本文を取り出せず、候補かどうかも決められない）
#   - 生の入力に `=` と glob 文字（`*` `?` `[`）が 1 つも無い（候補でない）
#
# fail-closed（理由付き deny）にする面 — **候補コマンドに限る**。判定を完了できないのに
# 通すと、守ろうとしている失敗（コマンド全体が走らない）をそのまま通す:
#   - ASDD ゲートが検証不能を返す（`.asdd/config.json` があるのに node が無い等。無効の rc 3 は素通し）
#   - 引用・展開が閉じないまま入力が終わる（判定ヘルパの rc 4。走査が途中で止まっている）
#   - 判定ヘルパ・heredoc 除去ヘルパのファイルが無い / 読めない / source に失敗する /
#     関数が無い
#   - どちらかの awk が非 0 で終わる（不在 127・破損）
#   - jq のフィルタ実行が parse 以外で失敗する
# 候補に限るのは、ヘルパが壊れた瞬間に**すべての** Bash 呼び出しが止まって復旧作業が
# できなくなるのを避けるため（guard-exit-code.sh と同じ面の切り方）。
#
# heredoc 本文はデータとして走査対象から落とす（`tests/lib/heredoc-strip.sh`。未終端の
# rc 3 は `<<` の誤検出とみなし、本文除去前の生コマンドを走査する）。
#
# ## 出力チャネルと抜け道
#
# glob / equals は `permissionDecision: "deny"`、scalar は systemMessage の警告で返す。
# systemMessage はエージェントへ届かないので、同じ hook を PostToolUse（Bash）にも登録し、
# scalar だけを `hookSpecificOutput.additionalContext` で実行後に返す（止めない）。
# 追加検出の契約は tests/lib/zsh-expansion-guard.sh。deny の JSON を組み立てる jq が失敗したら黙って許可に
# 落とさず、exit 2 + stderr のブロック経路へ落とす。
#   - この呼び出しだけ通す: Bash ツールへ渡すコマンドの**先頭の語**を環境代入 `FF_ZSH_GLOB_ACK=1`
#     にする（前に別の環境代入・文があると無効。引用値の中や途中の文に現れるだけでも無効）。
#     効く単位は Bash ツールの 1 呼び出しで、先頭に置けば改行で続く文にも効く（guard-exit-code.sh
#     の ACK と同じ単位。意図の表明であって文単位の許可ではない）。
#     `setopt nonomatch` 済みのシェルや、その名前のファイルが実在する場合の誤検知用
#   - ガードごと止める: 環境変数 `FF_DEV_TOOLKIT_SKIP_ZSH_GLOB_GUARD=1`
#
# ## 既知の限界（素通しする形）
#
#   - 一般のパス glob（`ls *.md` / `ls a*.ts b*.mts`）— 述語の対象外（上記）
#   - `$name:修飾子`。未引用 scalar と equals は zsh-expansion-guard.sh へ委ねる。
#   - 変数やコマンド置換の結果として組み立てられる語（`$flag` の中身は見えない）
#   - `nonomatch` / `null_glob` を設定済みのシェル（誤検知側。ACK で 1 手で通る）
#   - 区切り語を引用しない heredoc（`<<EOF`）の本文に書いた `$(…)` の中のコマンド。zsh は
#     その中身を実行時に glob するが、heredoc 本文はデータとして丸ごと落としている
#     （`tests/lib/heredoc-strip.sh` は区切り語の引用の有無を返さない）
#
# 互換性: bash 3.2（stock macOS）。連想配列・readarray を使わない。
# 環境変数:
#   FF_DEV_TOOLKIT_SKIP_ZSH_GLOB_GUARD=1  追加の equals/scalar 検出も含む全体を無効化する

# fail-open の面を持つため set -e / set -u は使わない。

# stdin は bash 組み込みの read で読み切る（外部コマンドに依存しない）。opt-out や
# 早期終了の経路でも読み切ってから抜け、書き手（ホスト）に EPIPE / SIGPIPE を返さない。
input=""
IFS= read -r -d '' input || true

# ASDD ゲートは drain より後に置く（ゲートの早期終了で stdin 未読のまま抜けないため）。
if ! source "${BASH_SOURCE[0]%/*}/asdd-hook-gate.sh"; then
  echo 'ff-dev-toolkit: ASDD Hook helper is unavailable; optional hook skipped' >&2
  exit 0
fi
# rc を読む（`|| exit 0` にしない）。共有ヘルパの契約は 0=有効 / 3=無効 / それ以外=検証不能。
# 無効は無音で通し、検証不能は候補コマンドに限り下で fail-closed へ倒す（guard-exit-code.sh と
# 同じ扱い。Issue `#1684`）。
asdd_hook_enabled hooks
asdd_rc=$?
asdd_unverifiable=0
case "$asdd_rc" in
  0) : ;;
  3) exit 0 ;;
  *) asdd_unverifiable=1 ;;
esac

[ "${FF_DEV_TOOLKIT_SKIP_ZSH_GLOB_GUARD:-0}" = "1" ] && exit 0

# ---- ホスト判定（zsh のときだけ） -----------------------------------------------
host_shell="${CLAUDE_CODE_SHELL:-${SHELL:-}}"
case "${host_shell##*/}" in
  zsh | zsh-*) : ;;
  *) exit 0 ;;
esac

# 同じホスト入口で equals/scalar も検出する。警告は既存 glob の deny と JSON を分断しない。
expansion_warning=""
expansion_helper="${BASH_SOURCE[0]%/*}/../tests/lib/zsh-expansion-guard.sh"

# ---- PostToolUse（Bash）: 未引用 scalar の警告をエージェントの文脈へ届ける ----------------
# PreToolUse の systemMessage は利用者の画面にしか出ずエージェントへ届かない。同じ判定
# （zsh-expansion-guard.sh。判定本体は二重化しない）を実行後に当て、scalar だけを
# hookSpecificOutput.additionalContext で返す。glob / equals の停止は PreToolUse の担当なので
# ここでは走らせない。実行は既に終わっているので、どの失敗経路でも止めない（fail-soft）:
# jq 不在・JSON でない入力・helper の異常終了は無音、helper 不在は `$` を含むコマンドに限り
# 未検査である旨を additionalContext で知らせる。
case "$input" in
  *'"PostToolUse"'*)
    if command -v jq >/dev/null 2>&1 \
      && [ "$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null)" = PostToolUse ]; then
      [ "${FF_DEV_TOOLKIT_SKIP_ZSH_EXPANSION_GUARD:-0}" = 1 ] && exit 0
      if [ -r "$expansion_helper" ]; then
        printf '%s' "$input" | bash "$expansion_helper" 2>/dev/null || true
      else
        post_cmd="$(printf '%s' "$input" | jq -r 'select(.tool_name == "Bash") | .tool_input.command | select(type == "string")' 2>/dev/null)"
        case "$post_cmd" in
          *'$'*) jq -n '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: "zsh 展開ガード: helper が不在で直前の Bash 呼び出しの未引用変数を未検査です。ff-dev-toolkit を更新・復旧してください。"}}' ;;
        esac
      fi
      exit 0
    fi
    ;;
esac
if [ "${FF_DEV_TOOLKIT_SKIP_ZSH_EXPANSION_GUARD:-0}" = 1 ]; then
  :
elif [ -r "$expansion_helper" ]; then
  expansion_rc=0
  expansion_out="$(printf '%s' "$input" | bash "$expansion_helper")" || expansion_rc=$?
  [ "$expansion_rc" -eq 0 ] || exit "$expansion_rc"
  if [ -n "$expansion_out" ]; then
    if printf '%s' "$expansion_out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
      printf '%s\n' "$expansion_out"
      exit 0
    fi
    expansion_warning="$(printf '%s' "$expansion_out" | jq -r '.systemMessage // empty' 2>/dev/null)"
  fi
else
  # helper 不在を検出0と混同しない。scalar-only は停止しない。
  missing_cmd="$(printf '%s' "$input" | jq -r 'select(.tool_name == "Bash") | .tool_input.command | select(type == "string")' 2>/dev/null)"
  case "$missing_cmd" in
    =?* | *' ='?* | *$'\t='?* | *$'\n='?*)
      missing_reason='zsh 展開ガード: 判定不能（helper 不在）。ff-dev-toolkit を更新・復旧するか FF_DEV_TOOLKIT_SKIP_ZSH_EXPANSION_GUARD=1 で無効化してください。'
      jq -n --arg m "$missing_reason" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $m}}' || { printf '%s\n' "$missing_reason" >&2; exit 2; }
      exit 0 ;;
  esac
  case "$missing_cmd" in *'$'*) expansion_warning='zsh 展開ガード: helper が不在で未検査です。ff-dev-toolkit を更新・復旧してください。' ;; esac
fi
emit_expansion_warning() {
  if [ -n "$expansion_warning" ]; then
    jq -n --arg m "$expansion_warning" '{systemMessage: $m}' || printf '%s\n' "$expansion_warning" >&2
  fi
}
trap emit_expansion_warning EXIT

# ---- 安価な前置フィルタ（候補でなければ何も読まずに抜ける） -------------------------
case "$input" in
  *=*) : ;;
  *) exit 0 ;;
esac
case "$input" in
  *'*'* | *'?'* | *'['*) : ;;
  *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

HELPER_DIR="${BASH_SOURCE[0]%/*}/../tests/lib"
HELPER_DIR_SHOWN="$HELPER_DIR"
case "$HELPER_DIR_SHOWN" in
  hooks/../*) HELPER_DIR_SHOWN="${HELPER_DIR_SHOWN#hooks/../}" ;;
  */hooks/../*) HELPER_DIR_SHOWN="${HELPER_DIR_SHOWN%%/hooks/../*}/${HELPER_DIR_SHOWN#*/hooks/../}" ;;
esac

deny() { # <reason>
  local out rc
  out="$(jq -n --arg reason "$1" --arg warning "$expansion_warning" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}} + (if $warning != "" then {systemMessage: $warning} else {} end)' 2>/dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    printf '%s\n' "$1" >&2
    printf 'ff-dev-toolkit guard-zsh-glob: deny の JSON を組み立てられませんでした（jq rc=%s）。exit 2 でブロックします。\n' "$rc" >&2
    exit 2
  fi
  expansion_warning=""
  printf '%s\n' "$out"
  exit 0
}

deny_unavailable() { # <理由>
  deny "⚠️ ff-dev-toolkit guard（zsh-nomatch-glob: 未引用 glob の NOMATCH）: **判定不能**のため停止しました（${1}）。
このコマンドは \`-…=\` の右側に glob 文字を含む候補ですが、判定ヘルパ（${HELPER_DIR_SHOWN}/zsh-glob-nomatch.sh / heredoc-strip.sh）で走査を完了できませんでした。判定できないまま通すと、zsh の NOMATCH でコマンド全体が走らない形を素通しします。
対処:
  1) ff-dev-toolkit を更新・再インストールしてヘルパを復旧する
  2) = の右側を引用した形（例: --include=\"*.md\"）で書き直して再実行する
  3) このコマンドに限って通す: コマンドの**先頭**へ環境代入 FF_ZSH_GLOB_ACK=1 を付けて再実行する
  4) ガードごと止める: 環境変数 FF_DEV_TOOLKIT_SKIP_ZSH_GLOB_GUARD=1 を設定する"
}

jq_rc=0
cmd="$(printf '%s' "$input" | jq -r 'if (type == "object") and (.tool_name == "Bash") then ((.tool_input // {}) | if type == "object" then (.command // "") else "" end) else "" end | if type == "string" then . else "" end' 2>/dev/null)" || jq_rc=$?
if [ "$jq_rc" -ne 0 ]; then
  # rc=5 は入力が JSON でない（対象外として素通し）。それ以外はフィルタ自体の失敗。
  [ "$jq_rc" -eq 5 ] && exit 0
  deny_unavailable "コマンド本文の取り出し（jq）が失敗しました（rc=${jq_rc}）"
fi
[ -n "$cmd" ] || exit 0

case "$cmd" in
  *-*=*) : ;;
  *) exit 0 ;;
esac
case "$cmd" in
  *=*'*'* | *=*'?'* | *=*'['*) : ;;
  *) exit 0 ;;
esac

# ---- 抜け道: コマンドの先頭（先頭の空白・タブ・改行だけを剥がす）の FF_ZSH_GLOB_ACK=1 --------
# 先頭の語そのものに限る（guard-exit-code.sh の ACK と同じリテラル判定）。先頭に連なる環境代入を
# 語単位で読み進める形は、`;` を含む語・引用値の中・改行で区切った前の文まで受理してしまう
# （セルフレビューで `X=1; FF_ZSH_GLOB_ACK=1 true; grep …` が通ることを実測した）。
ack_probe="$cmd"
while :; do
  case "$ack_probe" in
    " "* | "	"* | "
"*) ack_probe="${ack_probe#?}" ;;
    *) break ;;
  esac
done
case "$ack_probe" in
  'FF_ZSH_GLOB_ACK=1 '* | 'FF_ZSH_GLOB_ACK=1	'*) exit 0 ;;
esac

# ASDD ゲートが検証不能を返した回は、候補コマンドに限りここで止める（ACK の判定より後 —
# deny 文が案内する「先頭へ FF_ZSH_GLOB_ACK=1」が効く位置）。
if [ "$asdd_unverifiable" -eq 1 ]; then
  deny_unavailable "ASDD 設定を検証できません（asdd_hook_enabled rc=${asdd_rc}。.asdd/config.json があるのに node が無い・設定を読めない等）"
fi

# ---- heredoc 本文を落とす -----------------------------------------------------
HEREDOC_HELPER="$HELPER_DIR/heredoc-strip.sh"
[ -f "$HEREDOC_HELPER" ] && [ -r "$HEREDOC_HELPER" ] || deny_unavailable "heredoc 除去ヘルパのファイルが無いか読めません（${HELPER_DIR_SHOWN}/heredoc-strip.sh）"
# shellcheck source=../tests/lib/heredoc-strip.sh
. "$HEREDOC_HELPER" 2>/dev/null || deny_unavailable "heredoc 除去ヘルパの読み込みに失敗しました"
[ "$(type -t ff_heredoc_strip 2>/dev/null)" = "function" ] || deny_unavailable "heredoc 除去ヘルパに ff_heredoc_strip がありません"
strip_rc=0
code_only="$(ff_heredoc_strip "$cmd")" || strip_rc=$?
case "$strip_rc" in
  0 | 3) : ;;
  *) deny_unavailable "heredoc 除去（awk）が失敗しました（rc=${strip_rc}）" ;;
esac

# ---- 判定（共有ヘルパへ委ねる） ------------------------------------------------
SCAN_HELPER="$HELPER_DIR/zsh-glob-nomatch.sh"
[ -f "$SCAN_HELPER" ] && [ -r "$SCAN_HELPER" ] || deny_unavailable "判定ヘルパのファイルが無いか読めません（${HELPER_DIR_SHOWN}/zsh-glob-nomatch.sh）"
# shellcheck source=../tests/lib/zsh-glob-nomatch.sh
. "$SCAN_HELPER" 2>/dev/null || deny_unavailable "判定ヘルパの読み込みに失敗しました"
[ "$(type -t ff_zsh_glob_scan 2>/dev/null)" = "function" ] || deny_unavailable "判定ヘルパに ff_zsh_glob_scan がありません"
scan_rc=0
hits="$(ff_zsh_glob_scan "$code_only")" || scan_rc=$?
case "$scan_rc" in
  0) : ;;
  4) deny_unavailable "引用・展開（'…' / \"…\" / \${…} / \$(…) / バッククォート）が閉じないまま入力が終わったため、走査を完了できません" ;;
  *) deny_unavailable "判定ヘルパの走査（awk）が失敗しました（rc=${scan_rc}）" ;;
esac
[ -n "$hits" ] || exit 0

# ---- deny 文（検出した実値と書き換え案。最大 5 語） ---------------------------------
tab='	'
listed=""
hit_n=0
while IFS= read -r hit_line; do
  [ -n "$hit_line" ] || continue
  hit_n=$((hit_n + 1))
  [ "$hit_n" -le 5 ] || continue
  hit_word="${hit_line%%"${tab}"*}"
  hit_fix="${hit_line#*"${tab}"}"
  if [ "$hit_fix" = "-" ] || [ "$hit_fix" = "$hit_line" ]; then
    listed="${listed}
  ${hit_word}  →  = の右側を引用する（引用や展開を含む語なので書き換え案は出していません）"
  else
    listed="${listed}
  ${hit_word}  →  ${hit_fix}"
  fi
done <<EOF
$hits
EOF
[ "$hit_n" -le 5 ] || listed="${listed}
  （ほか $((hit_n - 5)) 語）"

deny "⚠️ ff-dev-toolkit guard（zsh-nomatch-glob: 未引用 glob の NOMATCH）: このホストの Bash ツールは zsh で動きます（${host_shell}）。\`-\` で始まる語の \`=\` より右に未引用の glob 文字（\`*\` \`?\` \`[\`）があると、zsh は語全体を「その名前で始まるファイル」を探す glob として評価し、**cwd に \`.md\` などがあっても 0 件**になり（\`--include=\` で始まる名前のファイルが実在しない限り必ず）、\`no matches found\` でその位置から呼び出しが中断されます（その語を含むコマンドと、\`;\` / \`&&\` で続くそれ以降のコマンドは走りません。手前のコマンドは既に走っているので、結果が一部だけ欠けた形になります。\`2>/dev/null\` を付けてもエラーは消えません）。bash では同じ文字列が通るので、bash 前提で書いたコマンドがここでだけ落ちます。
検出した語（実値 → 書き換え案）:${listed}
次のいずれかで再実行してください:
  1) = の右側を引用する（上の書き換え案。例: --include=\"*.md\"）
  2) bash 前提の複数行の手順は、bash <<'EOF' … EOF で bash に渡す
  3) 誤検知の場合（nonomatch を設定済み・その名前のファイルが実在する等）は、コマンドの**先頭**へ環境代入を付けて再実行する: FF_ZSH_GLOB_ACK=1 <コマンド>
このガードを止める場合は環境変数 FF_DEV_TOOLKIT_SKIP_ZSH_GLOB_GUARD=1 を設定します。判定の正本は ${HELPER_DIR_SHOWN}/zsh-glob-nomatch.sh です。"
