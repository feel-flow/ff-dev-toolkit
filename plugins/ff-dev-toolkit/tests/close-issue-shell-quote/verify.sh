#!/usr/bin/env bash
#
# close-issue-shell-quote: close-issue スキルの merge コマンド生成が
# ロケール非依存の引用を使っていることの回帰検査。
#
# 背景（レビュー CLI 側で実測済み）: `printf '%q'` は**現在のロケールで文字境界を
# 解釈する**ため、非 UTF-8 ロケール（Windows コンソールの codepage 932 / LC_ALL=C）で
# UTF-8 の日本語を渡すと「一部バイトだけ $'\NNN'、残りは生バイト」の混在になり、
# 出力全体が不正な UTF-8 になる。close-issue の手順 7 は同じ形で
# `gh pr merge --subject / --body` を組み立てているので、日本語の PR 件名・本文で
# 同じ壊れ方をする。SKILL.md の bash ブロックは利用者がそのまま実行する手順なので、
# 外部スクリプトの関数に依存せず、ブロック内で完結する単引用エスケープにする。
#
# 検査:
#   1. SKILL.md の bash ブロックから引用関数の定義行を**そのまま抽出**し、
#      LC_ALL=C の下で日本語・単引用・シェルメタ文字・多行・末尾改行を含む
#      文字列を通す。eval で戻した結果が元の文字列とバイト同一であること。
#   2. 生成された引用文字列そのものが valid UTF-8 であること（%q 相当の
#      「生バイトと $'\NNN' の混在」への退行を直接見る）。
#   3. sed が使えない環境（PATH を潰す）で q() が非 0 を返し、空の '' を返さないこと。
#      rc を捨てると「件名・本文を失った merge コマンドを rc=0 で黙って生成する」形に
#      なるため、失敗の伝播そのものを針にする。
#   4. 手順 7 の生成行を抽出し、--subject と --body の**両方**が q() を通ることの pin。
#      片方だけを生展開へ戻す退行は、q() 単体の検査では素通しになる。
#   5. 生成されたコマンド文字列を stub gh で実際に eval し、gh が受け取る
#      --subject / --body が元の MERGE_SUBJECT / MERGE_BODY とバイト同一であること。
#   6. SKILL.md にロケール依存の %q が残っていないこと（形の pin）。1・2 は
#      bash 5 の LC_ALL=C など %q が偶然通る環境がありうるため、形も固定する。
#
# 関数定義を写経せず抽出するのは、写した時点で「SKILL.md の手順を検査した」ことに
# ならず、SKILL.md だけが退行しても緑のままになるため。
#
# 実 gh・ネットワーク・課金は伴わない。一時ディレクトリを作れない環境では skip。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
SKILL="$PLUGIN_ROOT/skills/close-issue/SKILL.md"

[ -f "$SKILL" ] || { echo "✗ 対象ファイルが見つかりません: $SKILL" >&2; exit 1; }

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# ── 1. 引用関数の抽出 ──
QUOTE_FN="$(awk '/^q\(\) \{/ { print; found = 1 } END { exit found ? 0 : 1 }' "$SKILL")" || {
  echo "  ✗ SKILL.md に引用関数 q() の定義行が見つかりません（手順 7 の merge コマンド生成）" >&2
  exit 1
}
ok "SKILL.md の bash ブロック内で引用関数 q() が定義されている"

_ff_mktemp_rc=0
_ff_mktemp_out="$(mktemp -d 2>&1)" || _ff_mktemp_rc=$?
if [ "$_ff_mktemp_rc" -eq 0 ] && [ -d "$_ff_mktemp_out" ]; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できない環境のためスキップ"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  exit 0
fi

# 途中死を沈黙させない。`set -u` 等で死んだとき、トラップ突入時の $? は 0 になるため、
# 「rc=0 なのに最後まで到達していない」を中断として扱う（素の rm -rf トラップは
# 直前の終了ステータスを rm の rc で上書きし、アサーション 0 件でも緑になる）。
FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$TMP"
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ close-issue-shell-quote: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  if [ "$_ff_rc" -ne 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ close-issue-shell-quote: サマリー前に中断しました (rc=${_ff_rc})" >&2
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

# iconv が無い環境では valid UTF-8 の直接検査だけを落とす（round-trip と形の pin は残す）。
HAVE_ICONV=1
command -v iconv > /dev/null 2>&1 || HAVE_ICONV=0

# ── 2. round-trip（LC_ALL=C） ──
# payload はファイル経由で渡す。$(...) が末尾改行を落とすため、末尾改行を含む
# fixture を素通しできるかがそのまま針になる。
run_roundtrip() {
  local label="$1" payload_file="$2"
  local rc=0 out
  out="$(
    LC_ALL=C bash -c '
      set -euo pipefail
      '"$QUOTE_FN"'
      s="$(cat "$1"; printf X)"; s="${s%X}"
      quoted="$(q "$s")"
      printf "%s" "$quoted" > "$2"
      eval "restored=$quoted"
      printf "%s" "$restored" > "$3"
    ' _ "$payload_file" "$TMP/quoted" "$TMP/restored" 2>&1
  )" || rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "$label — 引用/復元がエラー終了しました (rc=$rc)"
    printf '%s\n' "$out" >&2
    return
  fi
  if cmp -s "$payload_file" "$TMP/restored"; then
    ok "$label — シェルが解釈した結果が元の文字列とバイト同一"
  else
    bad "$label — 復元結果が元の文字列とバイト同一ではありません"
    od -c "$payload_file" | head -5 >&2
    od -c "$TMP/restored" | head -5 >&2
  fi
  if [ "$HAVE_ICONV" -eq 0 ]; then
    echo "  ○ skip: iconv が無いため valid UTF-8 の直接検査をスキップ（${label}）"
  elif iconv -f UTF-8 -t UTF-8 < "$TMP/quoted" > /dev/null 2>&1; then
    ok "$label — 生成された引用文字列が valid UTF-8"
  else
    bad "$label — 生成された引用文字列が valid UTF-8 ではありません（%q 相当の退行）"
    od -c "$TMP/quoted" | head -5 >&2
  fi
}

printf '%s' 'fix: クローズ判定の実測を完了報告へ載せる' > "$TMP/p1"
run_roundtrip "日本語の件名" "$TMP/p1"

printf '%s' 'It'"'"'s $HOME `whoami` "quoted" a|b;c' > "$TMP/p2"
run_roundtrip "単引用とシェルメタ文字" "$TMP/p2"

printf '%s\n' 'Refs: see release notes' '' '- 変更点: 引用をロケール非依存にした' '- 実測: LC_ALL=C で round-trip' > "$TMP/p3"
run_roundtrip "多行の本文（日本語・空行・末尾改行）" "$TMP/p3"

# ── 3. sed が使えないときに q() が失敗を伝播する ──
# `s="$(... | sed ...)"` の rc を捨てると、sed 不在（PATH 破損など）でも空の '' を
# rc=0 で返し、件名・本文を失った merge コマンドを黙って生成してしまう。
SED_RC=0
SED_OUT="$(
  LC_ALL=C bash -c '
    '"$QUOTE_FN"'
    PATH=/nonexistent
    q "クローズ判定"
  ' 2> /dev/null
)" || SED_RC=$?
if [ "$SED_RC" -eq 0 ]; then
  bad "sed が使えない環境で q() が rc=0 で成功しています（失敗が伝播していない）"
  printf '  quoted=[%s]\n' "$SED_OUT" >&2
else
  ok "sed が使えない環境で q() が非 0 を返す (rc=${SED_RC})"
fi
if [ -n "$SED_OUT" ]; then
  bad "sed が使えない環境で q() が値を返しています（空の '' を返すと件名・本文が失われる）"
  printf '  quoted=[%s]\n' "$SED_OUT" >&2
else
  ok "sed が使えない環境で q() は引用結果を返さない"
fi

# ── 4. 生成行（手順 7 の printf）の pin ──
# q() 単体が正しくても、生成側で --subject / --body の片方だけが q を通っていれば
# 元の欠陥（生展開の引用漏れ）が残る。生成行そのものを抽出して両方を pin する。
GEN_BLOCK="$(awk '
  /^printf .gh pr merge / { capture = 1 }
  capture { print; found = 1 }
  capture && !/\\$/ { capture = 0 }
  END { exit found ? 0 : 1 }
' "$SKILL")" || {
  bad "SKILL.md に手順 7 の merge コマンド生成（printf 'gh pr merge ...）が見つかりません"
  GEN_BLOCK=""
}

pin_gen() {
  local needle="$1" label="$2"
  case "$GEN_BLOCK" in
    *"$needle"*) ok "$label" ;;
    *) bad "$label — 生成行に見つかりません: ${needle}" ;;
  esac
}

if [ -n "$GEN_BLOCK" ]; then
  ok "手順 7 の merge コマンド生成行を抽出できた"
  pin_gen '--subject %s' '生成行の --subject が %s（引用済み文字列を受ける形）'
  pin_gen '--body %s' '生成行の --body が %s（引用済み文字列を受ける形）'
  pin_gen '"$(q "${MERGE_SUBJECT}")"' '--subject の値が q() を通っている'
  pin_gen '"$(q "${MERGE_BODY}")"' '--body の値が q() を通っている'
fi

# ── 5. 生成行を stub gh で実行して subject/body の round-trip を見る ──
# 形の pin だけでは「q を呼んでいるが結果を使っていない」形を素通しする。生成された
# コマンド文字列を実際に eval し、gh が受け取った引数が元の変数とバイト同一か測る。
mkdir -p "$TMP/bin"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'while [ "$#" -gt 0 ]; do'
  printf '%s\n' '  case "$1" in'
  printf '%s\n' '    --subject) printf "%s" "$2" > "$FF_STUB_SUBJECT"; shift 2 ;;'
  printf '%s\n' '    --body) printf "%s" "$2" > "$FF_STUB_BODY"; shift 2 ;;'
  printf '%s\n' '    *) shift ;;'
  printf '%s\n' '  esac'
  printf '%s\n' 'done'
} > "$TMP/bin/gh"
chmod +x "$TMP/bin/gh"

if [ -n "$GEN_BLOCK" ]; then
  SUBJ_SRC="$TMP/gen_subject_src"
  BODY_SRC="$TMP/gen_body_src"
  printf '%s' "fix: クローズ判定 It's \$HOME \`whoami\` \"q\"" > "$SUBJ_SRC"
  printf '%s\n' 'Refs: see release notes' '' "- It's a test — 日本語 \$HOME" > "$BODY_SRC"

  GEN_RC=0
  GEN_OUT="$(
    FF_STUB_SUBJECT="$TMP/gen_subject_got" \
    FF_STUB_BODY="$TMP/gen_body_got" \
    LC_ALL=C bash -c '
      set -uo pipefail
      PATH="$4:$PATH"
      '"$QUOTE_FN"'
      PR_NUMBER=1270
      REMOTE_HEAD=0123456789abcdef0123456789abcdef01234567
      MERGE_SUBJECT="$(cat "$1"; printf X)"; MERGE_SUBJECT="${MERGE_SUBJECT%X}"
      MERGE_BODY="$(cat "$2"; printf X)"; MERGE_BODY="${MERGE_BODY%X}"
      CMD="$(
        '"$GEN_BLOCK"'
      )"
      printf "%s" "$CMD" > "$3"
      eval "$CMD"
    ' _ "$SUBJ_SRC" "$BODY_SRC" "$TMP/gen_cmd" "$TMP/bin" 2>&1
  )" || GEN_RC=$?

  if [ "$GEN_RC" -ne 0 ]; then
    bad "生成行の実行がエラー終了しました (rc=${GEN_RC})"
    printf '%s\n' "$GEN_OUT" >&2
  else
    if cmp -s "$SUBJ_SRC" "$TMP/gen_subject_got"; then
      ok "生成コマンドを実行した gh が受け取る --subject が元の MERGE_SUBJECT とバイト同一"
    else
      bad "生成コマンドの --subject が元の MERGE_SUBJECT と一致しません"
      od -c "$SUBJ_SRC" | head -5 >&2
      od -c "$TMP/gen_subject_got" 2> /dev/null | head -5 >&2
    fi
    if cmp -s "$BODY_SRC" "$TMP/gen_body_got"; then
      ok "生成コマンドを実行した gh が受け取る --body が元の MERGE_BODY とバイト同一"
    else
      bad "生成コマンドの --body が元の MERGE_BODY と一致しません"
      od -c "$BODY_SRC" | head -5 >&2
      od -c "$TMP/gen_body_got" 2> /dev/null | head -5 >&2
    fi
  fi
fi

# ── 6. 形の pin ──
# 行頭コメント（`#`）は対象外。「%q は使わない」と理由を残す注記まで違反にすると、
# 再発防止の根拠そのものを書けなくなるため。実行される行に %q が戻れば検出する。
OFFENDERS="$(awk '
  { line = $(0); sub(/^[[:space:]]*/, "", line) }
  line ~ /^#/ { next }
  index(line, "%q") { print FNR ": " line }
' "$SKILL")"
if [ -n "$OFFENDERS" ]; then
  bad "SKILL.md の非コメント行にロケール依存の %q が残っています（引用がロケール依存へ戻っている）"
  printf '%s\n' "$OFFENDERS" >&2
else
  ok "SKILL.md の実行される行はロケール依存の %q で引用しない"
fi

echo ""
echo "  pass=$PASS fail=$FAIL"
FF_REACHED_END=1
[ "$FAIL" -eq 0 ] || exit 1
