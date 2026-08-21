#!/usr/bin/env bash
#
# validate-docs-placeholders/verify.sh の検出力検証（Issue #518）。
#
# マスク実装（tests/lib/docs-scan.sh）を隔離コピーへ変異し、除外範囲の拡大 /
# 縮小が親 suite を red にすることを実測する。fixture は親 suite のものを使う。
#
#   G1. 変異なし → 緑（baseline）
#   G2. ff_docs_mask_spans を identity にする（除外の縮小）→ 閉じたフェンス /
#       コメント内のトークンが残って red
#   G3. 未閉鎖フェンスを EOF まで空行化する（除外の拡大）→ 後続本文のトークンが
#       消えて red
#   G4. ff_docs_mask_inline_spans を identity にする（除外の縮小）→ インライン
#       スパン内のトークンが残って red
#   G5. 未閉鎖コメントを EOF まで空行化する（除外の拡大）→ 後続本文のトークンが
#       消えて red
#   G6. 書き込み不可の TMPDIR でも親 suite が完走する（here-doc 不使用）
#
# 親 suite は LLM を使わない機械照合なので、公開 checkout でも fixture だけで走る。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="$TESTS_DIR/validate-docs-placeholders/verify.sh"
LIB_SRC="$TESTS_DIR/lib/docs-scan.sh"

[ -f "$TARGET" ] || { echo "✗ validate-docs-placeholders/verify.sh が見つかりません: $TARGET" >&2; exit 1; }
[ -f "$LIB_SRC" ] || { echo "✗ docs-scan.sh が見つかりません: $LIB_SRC" >&2; exit 1; }

command -v perl >/dev/null 2>&1 || {
  echo "○ skip: perl が無い環境のためスキップ（変異注入に必要）"
  exit 0
}

if _ff_mktemp_out="$(mktemp -d 2>&1)"; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できない環境（read-only）のためスキップ"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  exit 0
fi
FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$TMP"
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ selftest が末尾に到達せず終了しました（中断を緑にしない）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

copy_lib() {
  cp "$LIB_SRC" "$TMP/docs-scan.sh"
}

# $1=ケース名 $2=期待（green / red）$3=赤のとき出力に必要な理由（ERE、省略可）
run_case() {
  local name="$1" expect="$2" why="${3:-}" rc=0
  FF_DOCS_SCAN_LIB="$TMP/docs-scan.sh" bash "$TARGET" > "$TMP/out.log" 2>&1 || rc=$?
  if [ "$expect" = "green" ]; then
    if [ "$rc" -eq 0 ]; then
      ok "$name: 緑（期待どおり）"
    else
      bad "$name: 緑を期待しましたが rc=${rc} で赤でした"
      grep '✗' "$TMP/out.log" | sed 's/^/    /' | head -6 >&2
    fi
    return
  fi
  if [ "$rc" -eq 0 ]; then
    bad "$name: 赤を期待しましたが緑のまま通りました（検出力なし）"
    sed 's/^/    /' "$TMP/out.log" | tail -8 >&2
  elif [ -n "$why" ] && ! grep -qE "$why" "$TMP/out.log"; then
    bad "$name: 赤になりましたが理由が違います（期待: ${why}）"
    grep '✗' "$TMP/out.log" | sed 's/^/    /' | head -6 >&2
  else
    ok "$name: 赤（期待どおり）"
  fi
}

assert_present() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file"; then return 0; fi
  bad "$label: 変異が入っていません（期待: ${needle}）"
  return 1
}

echo "== validate-docs-placeholders-selftest =="
echo "target : $TARGET"
echo

echo "== G1. baseline =="
copy_lib
run_case "G1 baseline（変異なし）" green

echo "== G2. 除外の縮小（mask_spans を identity）=="
copy_lib
printf '\nff_docs_mask_spans() { cat "$1"; }\n' >> "$TMP/docs-scan.sh"
assert_present "$TMP/docs-scan.sh" 'ff_docs_mask_spans() { cat "$1"; }' "G2" || true
run_case "G2 mask_spans を identity" red "closed-spans: マスク後のトークン数が"

echo "== G3. 除外の拡大（未閉鎖フェンスを EOF まで空行化）=="
copy_lib
perl -i -pe 's/if \(close_at == 0\) \{ i\+\+; continue \}/if (close_at == 0) { for (k = i; k <= n; k++) line[k] = ""; break }/' \
  "$TMP/docs-scan.sh"
assert_present "$TMP/docs-scan.sh" 'for (k = i; k <= n; k++) line[k] = ""; break' "G3" || true
run_case "G3 未閉鎖フェンスを EOF まで空行化" red "unclosed-fence: マスク後のトークン数が"

echo "== G4. 除外の縮小（inline spans を identity）=="
copy_lib
printf '\nff_docs_mask_inline_spans() { cat; }\n' >> "$TMP/docs-scan.sh"
assert_present "$TMP/docs-scan.sh" 'ff_docs_mask_inline_spans() { cat; }' "G4" || true
run_case "G4 mask_inline_spans を identity" red "closed-spans: マスク後のトークン数が"

echo "== G5. 除外の拡大（未閉鎖コメントを EOF まで空行化）=="
copy_lib
perl -i -pe 's/if \(close_at == 0\) return i \+ 1/if (close_at == 0) { for (k = i; k <= n; k++) line[k] = ""; return n + 1 }/' \
  "$TMP/docs-scan.sh"
assert_present "$TMP/docs-scan.sh" 'for (k = i; k <= n; k++) line[k] = ""; return n + 1' "G5" || true
run_case "G5 未閉鎖コメントを EOF まで空行化" red "unclosed-comment: マスク後のトークン数が"

echo "== G6. 書き込み不可の TMPDIR でも親 suite が完走する =="
copy_lib
RO_DIR="$TMP/ro"
mkdir -p "$RO_DIR" && chmod 500 "$RO_DIR"
rc=0
TMPDIR="$RO_DIR" FF_DOCS_SCAN_LIB="$TMP/docs-scan.sh" bash "$TARGET" > "$TMP/out.log" 2>&1 || rc=$?
chmod 700 "$RO_DIR"
if [ "$rc" -eq 0 ]; then
  ok "G6 書き込み不可の TMPDIR で親 suite が完走"
else
  bad "G6 書き込み不可の TMPDIR で rc=${rc}（here-doc / here-string が一時ファイルを要求している可能性）"
  sed 's/^/    /' "$TMP/out.log" | tail -8 >&2
fi

echo
if [[ "$FAIL" -ne 0 ]]; then
  echo "結果: FAIL — ${FAIL} 件（pass ${PASS}）"
  FF_REACHED_END=1
  exit 1
fi
echo "結果: PASS — ${PASS} 件"
FF_REACHED_END=1
exit 0
