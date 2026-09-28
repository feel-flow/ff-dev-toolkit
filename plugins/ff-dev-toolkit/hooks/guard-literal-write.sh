#!/usr/bin/env bash

#
# シェルの値が別言語のプログラムへ届かず、ファイル本文が**無音で**変わる Bash 呼び出しを
# 実行前に止めるガード（PreToolUse / Bash、Issue `#1787`。導入先 hearing-realtime の観測台帳
# OBS-130 — Count 9）。
#
# ## なぜ呼び出し面に置くのか
#
# OBS-130（「ファイル本文の文字列を、シェル以外の言語のリテラル構文を通して書かない」）は、
# 規律の文言追加（CLAUDE.md の規律・文字列パッチの既定を Python / script file にする等）の
# 後も再発を続けた。ff-dev-toolkit には同じ「知っていて踏む」クラスをゲート側で止めた先例
# （guard-exit-code.sh の `pipestatus`）がある。壊れ方はエージェントがその場で組み立てる
# Bash 呼び出しの文字列に現れるので、PreToolUse の担当範囲になる。
#
# ## 何を止めるか（判定規則はこの hook に置かない）
#
# 述語の正本は共有ヘルパ `tests/lib/literal-write-scan.sh`（OBS-225）。止めるのは、呼び出し
# 文字列だけで「意図と違う本文になる」と断定できる 2 形に限る（Issue `#1787` の AC1 の実測で
# 候補を絞った。構文エラーで大きな音で落ちる型は止めない）:
#   A: `perl -i` の単一引用符プログラムに入ったシェル変数の綴り（`"$REPO"` → Perl 変数として
#      展開されて `""`）
#   B: perl / node が `$ENV{NAME}` / `process.env.NAME` で読む NAME を、同じ呼び出しが
#      export せずに代入している（値が子プロセスへ渡らず空 / undefined）
#
# ## 針が当たらない入力の既定（TESTING.md の同名節）
#
# fail-open（無音 exit 0）にする面 — 判定の対象外であることが入力から確定している:
#   - Bash 以外のツール / 空のコマンド / JSON でない入力（jq の rc=5）
#   - `jq` 不在（コマンド本文を取り出せず、候補かどうかも決められない）
#   - 生の入力が候補でない（`perl` の綴りと `$` の組も、`node` の綴りと `process.env` の組も無い）
#
# fail-closed（理由付き deny）にする面 — **候補コマンドに限る**。判定を完了できないのに
# 通すと、守ろうとしている失敗（無音で本文が変わる）をそのまま通す:
#   - ASDD ゲートが検証不能を返す（無効の rc 3 は素通し）
#   - 判定ヘルパのファイルが無い / 読めない / source に失敗する / 関数が無い
#   - 引用・展開・heredoc が閉じないまま入力が終わる（判定ヘルパの rc 4）
#   - awk が非 0 で終わる（不在 127・破損）
#   - jq のフィルタ実行が parse 以外で失敗する
# 候補に限るのは、ヘルパが壊れた瞬間に**すべての** Bash 呼び出しが止まって復旧作業が
# できなくなるのを避けるため（guard-exit-code.sh / guard-zsh-glob.sh と同じ面の切り方）。
#
# ## 出力チャネルと抜け道
#
# PreToolUse でエージェントに届くのは `permissionDecision: "deny"` の理由文だけなので、
# 抜け道付きの deny で返す。deny の JSON を組み立てる jq が失敗したら黙って許可に
# 落とさず、exit 2 + stderr のブロック経路へ落とす。
#   - この呼び出しだけ通す: Bash ツールへ渡すコマンドの**先頭の語**を環境代入
#     `FF_LITERAL_WRITE_ACK=1` にする（前に別の環境代入・文があると無効。guard-exit-code.sh の
#     ACK と同じ単位 — Bash ツールの 1 呼び出し）。Perl 変数を意図して書いた場合
#     （`$Config` など大文字始まりの Perl 変数）や、呼び出しの外で export 済みの名前の誤検知用
#   - ガードごと止める: 環境変数 `FF_DEV_TOOLKIT_SKIP_LITERAL_WRITE_GUARD=1`
#
# 既知の限界（素通しする形）は判定ヘルパの冒頭にまとめてある。
#
# 互換性: bash 3.2（stock macOS）。連想配列・readarray を使わない。
# 環境変数:
#   FF_DEV_TOOLKIT_SKIP_LITERAL_WRITE_GUARD=1  このガードを無効化する

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
asdd_hook_enabled hooks
asdd_rc=$?
asdd_unverifiable=0
case "$asdd_rc" in
  0) : ;;
  3) exit 0 ;;
  *) asdd_unverifiable=1 ;;
esac

[ "${FF_DEV_TOOLKIT_SKIP_LITERAL_WRITE_GUARD:-0}" = "1" ] && exit 0

# ---- 安価な前置フィルタ（候補でなければ何も読まずに抜ける） -------------------------
# 候補: perl の綴りと `$` の両方がある（述語 A・B の perl 側）、または node の綴りと
# `process.env` の両方がある（述語 B の node 側。`$` を含まずに成立する）
is_candidate() { # <text>
  case "$1" in
    *perl*) case "$1" in *'$'*) return 0 ;; esac ;;
  esac
  case "$1" in
    *node*) case "$1" in *process.env*) return 0 ;; esac ;;
  esac
  return 1
}
is_candidate "$input" || exit 0

command -v jq >/dev/null 2>&1 || exit 0

HELPER_DIR="${BASH_SOURCE[0]%/*}/../tests/lib"
HELPER_DIR_SHOWN="$HELPER_DIR"
case "$HELPER_DIR_SHOWN" in
  hooks/../*) HELPER_DIR_SHOWN="${HELPER_DIR_SHOWN#hooks/../}" ;;
  */hooks/../*) HELPER_DIR_SHOWN="${HELPER_DIR_SHOWN%%/hooks/../*}/${HELPER_DIR_SHOWN#*/hooks/../}" ;;
esac

deny() { # <reason>
  local out rc
  out="$(jq -n --arg reason "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}' 2>/dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    printf '%s\n' "$1" >&2
    printf 'ff-dev-toolkit guard-literal-write: deny の JSON を組み立てられませんでした（jq rc=%s）。exit 2 でブロックします。\n' "$rc" >&2
    exit 2
  fi
  printf '%s\n' "$out"
  exit 0
}

deny_unavailable() { # <理由>
  deny "⚠️ ff-dev-toolkit guard（literal-write: シェルの値が別言語のプログラムへ届かない形）: **判定不能**のため停止しました（${1}）。
このコマンドは perl と \`\$\`、または node と process.env を含む候補ですが、判定ヘルパ（${HELPER_DIR_SHOWN}/literal-write-scan.sh）で走査を完了できませんでした。判定できないまま通すと、ファイル本文が無音で変わる形を素通しします。
対処:
  1) ff-dev-toolkit を更新・再インストールしてヘルパを復旧する
  2) ファイル本文は Write / Edit ツールで直接書く（シェルを経由しない）
  3) このコマンドに限って通す: コマンドの**先頭**へ環境代入 FF_LITERAL_WRITE_ACK=1 を付けて再実行する
  4) ガードごと止める: 環境変数 FF_DEV_TOOLKIT_SKIP_LITERAL_WRITE_GUARD=1 を設定する"
}

jq_rc=0
cmd="$(printf '%s' "$input" | jq -r 'if (type == "object") and (.tool_name == "Bash") then ((.tool_input // {}) | if type == "object" then (.command // "") else "" end) else "" end | if type == "string" then . else "" end' 2>/dev/null)" || jq_rc=$?
if [ "$jq_rc" -ne 0 ]; then
  # rc=5 は入力が JSON でない（対象外として素通し）。それ以外はフィルタ自体の失敗。
  [ "$jq_rc" -eq 5 ] && exit 0
  deny_unavailable "コマンド本文の取り出し（jq）が失敗しました（rc=${jq_rc}）"
fi
[ -n "$cmd" ] || exit 0

is_candidate "$cmd" || exit 0

# ---- 抜け道: コマンドの先頭（先頭の空白・タブ・改行だけを剥がす）の FF_LITERAL_WRITE_ACK=1 ----
# 先頭の語そのものに限る（guard-exit-code.sh / guard-zsh-glob.sh の ACK と同じリテラル判定）。
ack_probe="$cmd"
while :; do
  case "$ack_probe" in
    " "* | "	"* | "
"*) ack_probe="${ack_probe#?}" ;;
    *) break ;;
  esac
done
case "$ack_probe" in
  'FF_LITERAL_WRITE_ACK=1 '* | 'FF_LITERAL_WRITE_ACK=1	'* | 'FF_LITERAL_WRITE_ACK=1
'*) exit 0 ;;
esac

# ASDD ゲートが検証不能を返した回は、候補コマンドに限りここで止める（ACK の判定より後 —
# deny 文が案内する「先頭へ FF_LITERAL_WRITE_ACK=1」が効く位置）。
if [ "$asdd_unverifiable" -eq 1 ]; then
  deny_unavailable "ASDD 設定を検証できません（asdd_hook_enabled rc=${asdd_rc}。.asdd/config.json があるのに node が無い・設定を読めない等）"
fi

# ---- 判定（共有ヘルパへ委ねる） ------------------------------------------------
SCAN_HELPER="$HELPER_DIR/literal-write-scan.sh"
[ -f "$SCAN_HELPER" ] && [ -r "$SCAN_HELPER" ] || deny_unavailable "判定ヘルパのファイルが無いか読めません（${HELPER_DIR_SHOWN}/literal-write-scan.sh）"
# shellcheck source=../tests/lib/literal-write-scan.sh
. "$SCAN_HELPER" 2>/dev/null || deny_unavailable "判定ヘルパの読み込みに失敗しました"
[ "$(type -t ff_literal_write_scan_all 2>/dev/null)" = "function" ] || deny_unavailable "判定ヘルパに ff_literal_write_scan_all がありません"
scan_rc=0
hits="$(ff_literal_write_scan_all "$cmd")" || scan_rc=$?
case "$scan_rc" in
  0) : ;;
  5) deny_unavailable "判定ヘルパの awk が走査の完了印を出さずに終わりました（awk の差し替え・途中終了）" ;;
  4) deny_unavailable "引用・展開・heredoc（'…' / \"…\" / \${…} / \$(…) / バッククォート / <<EOF）が閉じないまま入力が終わったか、入れ子の bash -c が 3 段を超えたため、走査を完了できません" ;;
  *) deny_unavailable "判定ヘルパの走査（awk）が失敗しました（rc=${scan_rc}）" ;;
esac
[ -n "$hits" ] || exit 0

# ---- deny 文（検出した名前と書き換え案。最大 5 件） ---------------------------------
tab='	'
listed=""
hit_n=0
has_a=0
has_b=0
while IFS= read -r hit_line; do
  [ -n "$hit_line" ] || continue
  hit_n=$((hit_n + 1))
  kind="${hit_line%%"${tab}"*}"
  rest="${hit_line#*"${tab}"}"
  name="${rest%%"${tab}"*}"
  lang="${rest#*"${tab}"}"
  case "$kind" in
    A) has_a=1 ;;
    B) has_b=1 ;;
  esac
  [ "$hit_n" -le 5 ] || continue
  case "$kind" in
    A) listed="${listed}
  \$${name}（perl -i のプログラム）→ Perl 変数 \$${name} として展開され、未定義なので空文字になります" ;;
    B) listed="${listed}
  ${name}（${lang} が環境から読む）→ この呼び出しで export せずに代入しているので子プロセスへ渡らず、空 / undefined になります" ;;
  esac
done <<EOF
$hits
EOF
[ "$hit_n" -le 5 ] || listed="${listed}
  （ほか $((hit_n - 5)) 件）"

advice=""
[ "$has_a" -eq 0 ] || advice="${advice}
  - 置換後の本文にシェル変数の値を入れたいなら: 本文を Write / Edit ツールで直接書く。perl に渡すなら export して \$ENV{NAME} で読むか、二重引用符のプログラムにしてシェルに展開させる
  - 本文へ \`\$NAME\` という文字列そのものを書きたいなら: Perl 側で \\\$NAME とエスケープする（単一引用符の中の \\\$ はそのまま perl へ届く）"
[ "$has_b" -eq 0 ] || advice="${advice}
  - 環境経由で渡すなら: 代入を export NAME=… にする、またはコマンドの前置代入（NAME=… perl …）にする"

deny "⚠️ ff-dev-toolkit guard（literal-write: シェルの値が別言語のプログラムへ届かない形）: この Bash 呼び出しは、シェルの変数を別言語（perl / node）のプログラムの中で読もうとしていますが、値がそのプログラムへ届きません。エラーにならずに**ファイル本文が無音で変わります**（空文字の挿入・\`\"\$REPO\"\` → \`\"\"\`。導入先の観測台帳 OBS-130 の再発機序）。
検出した箇所:${listed}
次のいずれかで書き直してください:
  - ファイル本文は Write / Edit ツールで直接書く（シェルも別言語のリテラルも経由しない。最も確実）
  - 新規ファイルや追記は、引用付き heredoc で置く: cat > <file> <<'EOF' … EOF（区切り語を引用すると本文は何も展開されない）${advice}
誤検知の場合（大文字始まりの Perl 変数を意図して書いた・呼び出しの外で export 済み等）は、コマンドの**先頭**へ環境代入を付けて再実行します: FF_LITERAL_WRITE_ACK=1 <コマンド>
このガードを止める場合は環境変数 FF_DEV_TOOLKIT_SKIP_LITERAL_WRITE_GUARD=1 を設定します。判定の正本は ${HELPER_DIR_SHOWN}/literal-write-scan.sh です。"
