#!/usr/bin/env bash
#
# verify.sh — 共有 heredoc 除去ヘルパ tests/lib/heredoc-strip.sh の回帰（Issue `#1682`）
#
# 5 本の PreToolUse Bash ガードが写経していた awk を 1 本化したヘルパの契約を固定する:
#   (1) 正常終端: 本文は落ち、終端行の**直後**の実コマンドは残る。本文は ff_heredoc_bodies で取れる
#   (2) 未終端（引用符の中・算術式の中の `<<`）: rc 3 で**生コマンド**を返す（以降の行を捨てない）
#   (3) awk 失敗（FF_HEREDOC_AWK が実行できない）: rc 非 0 かつ 0/3 以外、stdout は空
#   (4) here-string `<<<` は heredoc ではない
#   (5) 行末 `\` の継続結合 / 同じ行の複数 opener / `<<-` のタブ終端
#
# 空振り検出: ヘルパの実体を消す（source 不能）と冒頭の存在検査が赤になる。FF_HEREDOC_AWK を「何も出さず exit 0 する」stub に差し替えると (1) の「終端行の直後の実コマンドが残る」検査と (2) の「rc 3 で生コマンドを返す」検査が赤になる（2026-09-17 実測）。
#
# 一時領域を使わない（skip 経路なし）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$SCRIPT_DIR/../lib/heredoc-strip.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

echo "== heredoc-strip: 共有 heredoc 除去ヘルパの回帰 =="

if [ ! -f "$LIB" ]; then
  echo "  ✗ ヘルパが見つかりません: $LIB" >&2
  exit 1
fi
# shellcheck source=../lib/heredoc-strip.sh
if ! . "$LIB"; then
  echo "  ✗ ヘルパを source できません: $LIB" >&2
  exit 1
fi
[ "$(type -t ff_heredoc_strip)" = "function" ] || { echo "  ✗ ff_heredoc_strip が定義されていません" >&2; exit 1; }
[ "$(type -t ff_heredoc_bodies)" = "function" ] || { echo "  ✗ ff_heredoc_bodies が定義されていません" >&2; exit 1; }

OUT=""
RC=0
strip() { # <cmd> [NAME=VALUE ...]
  local cmd="$1"
  shift
  RC=0
  if [ "$#" -gt 0 ]; then
    OUT="$(env "$@" bash -c '. "$1"; ff_heredoc_strip "$2"' _ "$LIB" "$cmd")" || RC=$?
  else
    OUT="$(ff_heredoc_strip "$cmd")" || RC=$?
  fi
}
bodies() { # <cmd> [NAME=VALUE ...]
  local cmd="$1"
  shift
  RC=0
  if [ "$#" -gt 0 ]; then
    OUT="$(env "$@" bash -c '. "$1"; ff_heredoc_bodies "$2"' _ "$LIB" "$cmd")" || RC=$?
  else
    OUT="$(ff_heredoc_bodies "$cmd")" || RC=$?
  fi
}

# ---- (0) 写経が戻っていない（5 hook に awk 本体が無く、ヘルパを source している）------------
HOOKS_DIR="$SCRIPT_DIR/../../hooks"
inl=0
src=0
for h in guard-effort-actual guard-issue-labels guard-long-gate-background guard-review-in-flight guard-exit-code; do
  f="$HOOKS_DIR/$h.sh"
  [ -f "$f" ] || { bad "(0) hook が無い: $f"; continue; }
  if grep -q 'gsub(/<<</' "$f" 2>/dev/null; then inl=$((inl + 1)); fi
  if grep -q 'tests/lib/heredoc-strip.sh' "$f" 2>/dev/null; then src=$((src + 1)); fi
done
[ "$inl" -eq 0 ] && ok "(0) 5 hook のどれにも heredoc 除去 awk の写しが残っていない" || bad "(0) awk の写しが hook に戻っている（${inl} 本）"
[ "$src" -eq 5 ] && ok "(0) 5 hook すべてが共有ヘルパを参照している" || bad "(0) ヘルパを参照する hook が ${src} 本（期待 5）"

# ---- (1) 正常終端 -----------------------------------------------------------
NORMAL="gh pr create --body \"\$(cat <<'EOF'
git commit -m x
sed -i s/a/b/ README.md
EOF
)\"; echo after"
strip "$NORMAL"
[ "$RC" -eq 0 ] && ok "(1) 正常終端は rc 0" || bad "(1) 正常終端の rc が $RC"
case "$OUT" in
  *'git commit -m x'* | *'sed -i'*) bad "(1) 本文が落ちていない: [$OUT]" ;;
  *) ok "(1) heredoc 本文は落ちる" ;;
esac
case "$OUT" in
  *'echo after'*) ok "(1) 終端行の直後の実コマンドが残る" ;;
  *) bad "(1) 終端行の直後の実コマンドが消えた: [$OUT]" ;;
esac
case "$OUT" in
  *"cat <<'EOF'"*) ok "(1) opener の行そのものは残る" ;;
  *) bad "(1) opener の行が消えた: [$OUT]" ;;
esac
bodies "$NORMAL"
[ "$RC" -eq 0 ] || bad "(1) bodies の rc が $RC"
if [ "$OUT" = "git commit -m x
sed -i s/a/b/ README.md" ]; then
  ok "(1) ff_heredoc_bodies は本文だけ（終端行を含まない）を返す"
else
  bad "(1) bodies の内容が違う: [$OUT]"
fi

# ---- (2) 未終端 --------------------------------------------------------------
QUOTED="git commit -m \"refactor: a << B ordering\"
bash verify.sh > log 2>&1; echo \"rc=\$?\""
strip "$QUOTED"
[ "$RC" -eq 3 ] && ok "(2) 引用符の中の << は未終端として rc 3" || bad "(2) 引用符の中の << の rc が ${RC}（期待 3）"
[ "$OUT" = "$QUOTED" ] && ok "(2) rc 3 のとき生コマンドをそのまま返す（2 行目を捨てない）" || bad "(2) rc 3 の stdout が生コマンドではない: [$OUT]"
bodies "$QUOTED"
[ "$RC" -eq 3 ] && [ -z "$OUT" ] && ok "(2) bodies も rc 3 で空" || bad "(2) bodies の rc=$RC out=[$OUT]"
ARITH="echo \$((1 << n))
bash verify.sh > log 2>&1; echo \"rc=\$?\""
strip "$ARITH"
[ "$RC" -eq 3 ] && [ "$OUT" = "$ARITH" ] && ok "(2) 算術式の << も未終端として生コマンドを返す" || bad "(2) 算術式: rc=$RC out=[$OUT]"
# 対照: 同じ 2 行から << を除くと rc 0
CONTROL="git commit -m \"refactor: a B ordering\"
bash verify.sh > log 2>&1; echo \"rc=\$?\""
strip "$CONTROL"
[ "$RC" -eq 0 ] && [ "$OUT" = "$CONTROL" ] && ok "(2) 対照: << の無い 2 行は rc 0 でそのまま" || bad "(2) 対照: rc=$RC out=[$OUT]"

# ---- (3) awk 失敗 ------------------------------------------------------------
strip "$NORMAL" FF_HEREDOC_AWK=/nonexistent/awk
if [ "$RC" -ne 0 ] && [ "$RC" -ne 3 ] && [ -z "$OUT" ]; then
  ok "(3) awk が実行できないとき rc は 0/3 以外（${RC}）で stdout は空"
else
  bad "(3) awk 不在: rc=$RC out=[$OUT]"
fi
bodies "$NORMAL" FF_HEREDOC_AWK=/nonexistent/awk
[ "$RC" -ne 0 ] && [ "$RC" -ne 3 ] && [ -z "$OUT" ] && ok "(3) bodies も同じ契約" || bad "(3) bodies: rc=$RC out=[$OUT]"

# ---- (4) here-string ---------------------------------------------------------
HS='cat <<< "git commit -m x"; git status'
strip "$HS"
[ "$RC" -eq 0 ] && [ "$OUT" = "$HS" ] && ok "(4) here-string は heredoc ではない（rc 0・無変更）" || bad "(4) here-string: rc=$RC out=[$OUT]"

# ---- (5) 継続結合 / 複数 opener / <<- ------------------------------------------
CONT='gh issue create --title x \
  --label bug'
strip "$CONT"
[ "$RC" -eq 0 ] && [ "$OUT" = 'gh issue create --title x   --label bug' ] && ok "(5) 行末 \\ の継続行を 1 行へ結合する" || bad "(5) 継続結合: rc=$RC out=[$OUT]"
ESC='printf x \\
echo y'
strip "$ESC"
[ "$RC" -eq 0 ] && [ "$OUT" = "$ESC" ] && ok "(5) 行末の \\\\（偶数個）は継続ではない" || bad "(5) 偶数 \\\\: rc=$RC out=[$OUT]"
TWO='cat <<A <<B
a1
A
b1
B
echo after'
strip "$TWO"
[ "$RC" -eq 0 ] && [ "$OUT" = 'cat <<A <<B
echo after' ] && ok "(5) 同じ行の複数 opener を順に消化する" || bad "(5) 複数 opener: rc=$RC out=[$OUT]"
bodies "$TWO"
[ "$OUT" = 'a1
b1' ] && ok "(5) 複数 opener の本文を出現順に連結する" || bad "(5) 複数 opener の bodies: [$OUT]"
DASH="cat <<-EOF
	body
	EOF
echo after"
strip "$DASH"
[ "$RC" -eq 0 ] && [ "$OUT" = 'cat <<-EOF
echo after' ] && ok "(5) <<- のタブ字下げ終端を認識する" || bad "(5) <<-: rc=$RC out=[$OUT]"

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ heredoc-strip: ${FAIL} 件失敗（成功 ${PASS} 件）" >&2
  exit 1
fi
echo "✅ heredoc-strip: all ${PASS} checks passed"
