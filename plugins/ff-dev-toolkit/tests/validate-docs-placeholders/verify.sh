#!/usr/bin/env bash
#
# /validate-docs §4 のプレースホルダー免除区分（閉じたフェンス / 閉じた HTML
# コメント / 同一行内のインラインコードスパン）と、閉じ忘れを除外区間にしない
# fail-closed を fixture で固定する（Issue #518）。
#
# 走査は tests/lib/docs-scan.sh のマスクを使う。同じ走査を 3 本書くと片方だけ
# 直される drift が検出漏れになるため、Frontmatter / 件数ドリフトと共有する。
#
# 判定そのものは LLM を伴わない。トークン残存数をマスク前後で数える。
# ACE-86-2: here-string / heredoc を使わない。
#
# 使い方: bash plugins/ff-dev-toolkit/tests/validate-docs-placeholders/verify.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
FIXTURES="$SCRIPT_DIR/fixtures"
MASTER="$REPO_ROOT/docs/MASTER.md"
LIB="${FF_DOCS_SCAN_LIB:-$TESTS_DIR/lib/docs-scan.sh}"
TOKEN="PH-EXEMPT-TOKEN"

# shellcheck source=../lib/docs-scan.sh
. "$LIB"

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

count_token() {
  awk -v t="$TOKEN" 'BEGIN { n = 0 } { n += gsub(t, "") } END { print n + 0 }'
}

scan_masked() {
  ff_docs_mask_spans "$1" | ff_docs_mask_inline_spans
}

expect_counts() {
  local name="$1" file="$2" raw_want="$3" masked_want="$4"
  local raw_got masked_got
  if [[ ! -f "$file" ]]; then
    bad "$name: fixture が無い ($file)"
    return
  fi
  raw_got="$(count_token < "$file")"
  if [[ "$raw_got" -eq "$raw_want" ]]; then
    ok "$name: マスク前 ${raw_got} 件"
  else
    bad "$name: マスク前のトークン数が ${raw_got}（期待 ${raw_want}）。fixture が壊れている"
    return
  fi
  masked_got="$(scan_masked "$file" | count_token)"
  if [[ "$masked_got" -eq "$masked_want" ]]; then
    ok "$name: マスク後 ${masked_got} 件（期待 ${masked_want}）"
  else
    bad "$name: マスク後のトークン数が ${masked_got}（期待 ${masked_want}）"
  fi
}

echo "== validate-docs-placeholders =="
echo "lib    : $LIB"
echo

if [[ ! -f "$LIB" ]]; then
  echo "✗ docs-scan.sh が見つからない: $LIB" >&2
  exit 1
fi
if ! type ff_docs_mask_spans >/dev/null 2>&1; then
  echo "✗ ff_docs_mask_spans が定義されていない" >&2
  exit 1
fi
if ! type ff_docs_mask_inline_spans >/dev/null 2>&1; then
  echo "✗ ff_docs_mask_inline_spans が定義されていない（同一行内のインラインコードスパン免除が未実装）" >&2
  exit 1
fi

echo "## fixture（AC-2 / AC-3）"
# AC-2: 閉じたフェンス / コメント / インラインは除外、表セルと本文は残る。
# 閉じた区間の後ろと同一行コメント前の本文も残る（除外の overrun を 2 件一致で隠さない）。
#   raw 8 = body + table + fence + comment + inline + after + same-line body + same-line comment
#   masked 4 = body + table + after + same-line body
expect_counts "closed-spans" "$FIXTURES/closed-spans.md" 8 4
# AC-3: 閉じ忘れは除外区間にならない。開始行の本文も残る。
expect_counts "unclosed-fence" "$FIXTURES/unclosed-fence.md" 3 3
expect_counts "unclosed-comment" "$FIXTURES/unclosed-comment.md" 3 3
# 閉じ忘れの後ろにある閉じたフェンスは、通常どおり除外される
expect_counts "unclosed-then-closed" "$FIXTURES/unclosed-then-closed.md" 2 1
echo

echo "## MASTER.md の参照（SSOT はスキル側）"
if [[ ! -f "$MASTER" ]]; then
  echo "  ℹ docs/MASTER.md が無いため SSOT 参照ピンはスキップ（公開 checkout）"
else
  # Changelog は当時の記録なので、負のピン（旧文言の残存）は本文だけを見る。
  master_body="$(awk '/^## Changelog$/{exit} {print}' "$MASTER")"
  case "$master_body" in
    *'検出対象と免除区分の正本は `/validate-docs` §4'*) ok "MASTER.md が §4 を正本として参照する" ;;
    *) bad "MASTER.md が §4 を正本として参照する — 本文に見つかりません" ;;
  esac
  case "$master_body" in
    *'条文に除外規則が無い'*) bad "MASTER.md 本文に旧「条文に除外規則が無い」が残っている" ;;
    *) ok "MASTER.md 本文から旧「条文に除外規則が無い」を除去済み" ;;
  esac
  case "$master_body" in
    *'条文には無い本リポジトリの運用判断'*) bad "MASTER.md 本文に旧「条文には無い本リポジトリの運用判断」が残っている" ;;
    *) ok "MASTER.md 本文から旧「運用判断」注記を除去済み" ;;
  esac
fi
echo

if [[ "$FAIL" -ne 0 ]]; then
  echo "結果: FAIL — ${FAIL} 件（pass ${PASS}）"
  exit 1
fi
echo "結果: PASS — ${PASS} 件"
exit 0
