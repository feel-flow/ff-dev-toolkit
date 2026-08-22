#!/usr/bin/env bash
#
# Issue #351: 行数バジェット例外の運用条件が PLAYBOOK の SSOT、live、README の
# 参照、見本エントリの間で drift しないことを静的に固定する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
TEMPLATE_PLAYBOOK="$PLUGIN_ROOT/docs-template/08-knowledge/PLAYBOOK.md"
LIVE_PLAYBOOK="$REPO_ROOT/docs/08-knowledge/PLAYBOOK.md"
TEMPLATE_README="$PLUGIN_ROOT/docs-template/scripts/ace/README.md"
LIVE_README="$REPO_ROOT/scripts/ace/README.md"
SEED_ENTRY="$PLUGIN_ROOT/docs-template/08-knowledge/playbook/testing.md"
CHECK_SIZE_CODE="$PLUGIN_ROOT/docs-template/scripts/ace/check-category-size.ts"
REFINE_CODE="$PLUGIN_ROOT/docs-template/scripts/ace/ace-refine-report.ts"

for required in "$TEMPLATE_PLAYBOOK" "$LIVE_PLAYBOOK" "$TEMPLATE_README" \
  "$LIVE_README" "$SEED_ENTRY" "$CHECK_SIZE_CODE" "$REFINE_CODE"; do
  if [[ ! -s "$required" ]]; then
    echo "✗ ace-line-budget-docs: 検査対象が存在しないか空です: $required" >&2
    exit 1
  fi
done

# 実行検査数の侵食ガード（TESTING.md の EXPECTED_CHECKS 方針）。針を 1 本消しても
# 残りが緑のまま「全 N 件 pass」で通るため、総数を別途固定する。検査を増減したときの
# 更新箇所は 2 つ: ok / bad を増減させた箇所（RULE_NEEDLES / SEED_NEEDLES の増減を
# 含む）と、この宣言。検査対象が欠けるランは上の必須ファイル検査が exit 1 するため、
# ここには到達しない。
EXPECTED_CHECKS=27

PASS=0
FAIL=0
ok() {
  echo "  ✓ $1"
  PASS=$((PASS + 1))
}
bad() {
  echo "  ✗ $1" >&2
  FAIL=$((FAIL + 1))
}

contains() {
  local file="$1" needle="$2" label="$3"
  if grep -Fq -- "$needle" "$file"; then
    ok "$label"
  else
    bad "${label} — ${file} に見つかりません: ${needle}"
  fi
}

line_number() {
  local file="$1" needle="$2"
  awk -v needle="$needle" 'index($0, needle) == 1 { print NR; exit }' "$file"
}

extract_rule_block() {
  awk '
    $0 == "#### 行数バジェット例外の有効条件" { capture = 1 }
    capture && /^###[#]* / && $0 != "#### 行数バジェット例外の有効条件" { exit }
    capture { print }
  ' "$1"
}

extract_seed_entry() {
  awk '
    /^### ACE-000-3:/ { capture = 1 }
    capture { print }
    capture && /^---$/ { exit }
  ' "$1"
}

echo "== PLAYBOOK の運用 SSOT =="

TEMPLATE_RULES="$(extract_rule_block "$TEMPLATE_PLAYBOOK")"
LIVE_RULES="$(extract_rule_block "$LIVE_PLAYBOOK")"
if [[ -n "$TEMPLATE_RULES" ]]; then
  ok "docs-template に行数バジェット例外の条件ブロックがある"
else
  bad "docs-template の条件ブロックを抽出できない"
fi
if [[ -n "$LIVE_RULES" ]]; then
  ok "live に行数バジェット例外の条件ブロックがある"
else
  bad "live の条件ブロックを抽出できない"
fi
if [[ -n "$TEMPLATE_RULES" && "$TEMPLATE_RULES" == "$LIVE_RULES" ]]; then
  ok "docs-template / live の条件ブロックが byte 一致する"
else
  bad "docs-template / live の条件ブロックに drift がある"
fi

for playbook in "$TEMPLATE_PLAYBOOK" "$LIVE_PLAYBOOK"; do
  ops_line="$(line_number "$playbook" "### 運用ルール")"
  rules_line="$(line_number "$playbook" "#### 行数バジェット例外の有効条件")"
  id_line="$(line_number "$playbook" "### エントリID規則")"
  if [[ -n "$ops_line" && -n "$rules_line" && -n "$id_line" &&
    $ops_line -lt $rules_line && $rules_line -lt $id_line ]]; then
    ok "$(basename "$playbook") の条件ブロックは §運用ルール配下にある"
  else
    bad "$(basename "$playbook") の条件ブロックが §運用ルール配下にない"
  fi
done

RULE_NEEDLES=(
  "1. **エントリブロックの内側に置く**"
  "2. **閉じた HTML コメント span にする**"
  "3. **1 ブロックにつき最大 1 件**"
  "4. **コードとしての例示は数えない** — 同一行内で対になったインラインコードスパン"
)
for needle in "${RULE_NEEDLES[@]}"; do
  if grep -Fq -- "$needle" <<<"$TEMPLATE_RULES"; then
    ok "SSOT ブロックに条件がある: $needle"
  else
    bad "SSOT ブロックに条件がない: $needle"
  fi
done

echo
echo "== README は PLAYBOOK を参照する =="

contains "$TEMPLATE_README" \
  '配置先の `docs/08-knowledge/PLAYBOOK.md#行数バジェット例外の有効条件`' \
  "docs-template README が配置先 PLAYBOOK の SSOT を参照する"
contains "$LIVE_README" \
  "(../../docs/08-knowledge/PLAYBOOK.md#行数バジェット例外の有効条件)" \
  "root README が live PLAYBOOK の SSOT を参照する"
for readme in "$TEMPLATE_README" "$LIVE_README"; do
  contains "$readme" \
    "本 README はスクリプトの実装境界と診断だけを説明します" \
    "$(basename "$readme") が運用SSOTとの責務分離を明記する"
  if grep -Fq "例外宣言として数えるのは、" "$readme"; then
    bad "$(basename "$readme") に旧4条件の重複説明が残っている"
  else
    ok "$(basename "$readme") に旧4条件の重複説明がない"
  fi
done

echo
echo "== 見本 ACE-000-3 と SSOT の整合 =="

SEED_BLOCK="$(extract_seed_entry "$SEED_ENTRY")"
if [[ -n "$SEED_BLOCK" ]]; then
  ok "見本 ACE-000-3 のブロックを抽出できる"
else
  bad "見本 ACE-000-3 のブロックを抽出できない"
fi
SEED_NEEDLES=(
  "エントリブロックの内側"
  "閉じた HTML コメント"
  "1 ブロックにつき 1 件"
  "同一行内のコードスパンや閉じたフェンスの中に書いた例示は宣言として数えない"
  "../PLAYBOOK.md#行数バジェット例外の有効条件"
)
for needle in "${SEED_NEEDLES[@]}"; do
  if grep -Fq -- "$needle" <<<"$SEED_BLOCK"; then
    ok "見本 ACE-000-3: $needle"
  else
    bad "見本 ACE-000-3 に条件がない: $needle"
  fi
done

echo
echo "== PLAYBOOK の条件と実装の結線 =="

contains "$CHECK_SIZE_CODE" \
  'export const BUDGET_EXCEPTION_MARKER = "ace-line-budget-exception";' \
  "例外マーカーの実装 SSOT が文書と一致する"
contains "$CHECK_SIZE_CODE" \
  'export function countBudgetExceptions(content: string): BudgetExceptionTally {' \
  "エントリ内の例外件数を数える実装がある"
contains "$CHECK_SIZE_CODE" \
  'declared += 1;' \
  "1ブロック最大1件の加算がある"
contains "$CHECK_SIZE_CODE" \
  'export function blankCodeRegions(source: string): CodeRegionBlankResult {' \
  "コード領域除外の実装 SSOT がある"
contains "$REFINE_CODE" \
  'BUDGET_EXCEPTION_MARKER,' \
  "refine が例外マーカーの実装 SSOTを import する"
contains "$REFINE_CODE" \
  'blankCodeRegions,' \
  "refine がコード領域除外の実装 SSOTを import する"

# 検査総数の侵食ガード。全検査成功ラン（FAIL=0）に限って完全一致を要求する — 抽出に
# 失敗するランは後続検査を飛ばすことがあり、そのランはこのガード無しですでに赤いため。
if [[ $FAIL -eq 0 && $PASS -ne $EXPECTED_CHECKS ]]; then
  echo "ace-line-budget-docs verify: 実行検査数が ${PASS} 件（期待 ${EXPECTED_CHECKS} 件）— 検査が黙って増減している（増減時は EXPECTED_CHECKS も更新すること）" >&2
  exit 1
fi

if [[ $FAIL -ne 0 ]]; then
  echo "ace-line-budget-docs verify: ${FAIL} 件失敗 / ${PASS} 件 pass" >&2
  exit 1
fi

echo "ace-line-budget-docs verify: 全 ${PASS} 件 pass（検査総数ガード ${EXPECTED_CHECKS} 件と一致）"
