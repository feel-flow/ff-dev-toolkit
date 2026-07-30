#!/usr/bin/env bash
#
# /ace-refine（grow-and-refine）の契約検査（Issue #223）。
#
# refine は既存エントリ本文の書き換え・削除（アーカイブ移動）を含む唯一の経路であり、
# 安全弁（承認前書き換え禁止・原文 verbatim 保全・ID/anchor 不変・カウンター非減算・
# knowledge: 件名）が SKILL.md から脱落すると、Playbook の監査可能性と reuse 計測が
# 静かに壊れる。本 suite は固定文言 grep でこれらの安全弁を fail-closed で検証する。
# 併せて、ace-curate 側の書き込み時ゲート（行数バジェット・叙述の記録先分離・
# 索引タイトルのみ・refine 専権）と、テンプレート・スクリプトの案内文言も固定する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REFINE_FILE="$PLUGIN_ROOT/skills/ace-refine/SKILL.md"
CURATE_FILE="$PLUGIN_ROOT/skills/ace-curate/SKILL.md"
PLAYBOOK_TEMPLATE="$PLUGIN_ROOT/docs-template/08-knowledge/PLAYBOOK.md"
PATTERNS_TEMPLATE="$PLUGIN_ROOT/docs-template/03-implementation/PATTERNS.md"
ACE_CYCLE_TEMPLATE="$PLUGIN_ROOT/docs-template/05-operations/deployment/ace-cycle.md"
CHECK_SIZE_SCRIPT="$PLUGIN_ROOT/docs-template/scripts/ace/check-category-size.ts"
REFINE_REPORT_SCRIPT="$PLUGIN_ROOT/docs-template/scripts/ace/ace-refine-report.ts"

for f in "$REFINE_FILE" "$CURATE_FILE" "$PLAYBOOK_TEMPLATE" "$PATTERNS_TEMPLATE" \
         "$ACE_CYCLE_TEMPLATE" "$CHECK_SIZE_SCRIPT" "$REFINE_REPORT_SCRIPT"; do
  [ -s "$f" ] || {
    echo "✗ 検査対象が存在しないか空です: $f" >&2
    exit 1
  }
done

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

contains() {
  local file="$1" needle="$2" label="$3"
  if grep -Fq -- "$needle" "$file"; then
    ok "$label"
  else
    bad "${label} — '$needle' が見つかりません（$(basename "$file")）"
  fi
}

echo "== ace-refine ハードルール（安全弁の固定文言） =="

contains "$REFINE_FILE" \
  "dry-run レポートの提示とユーザー承認より前に、いかなるファイルも書き換えない" \
  "承認前書き換え禁止"
contains "$REFINE_FILE" \
  "原文はアーカイブへ verbatim で保全する。保全なしの削除・要約は禁止" \
  "原文 verbatim 保全"
contains "$REFINE_FILE" \
  "エントリ ID と anchor は live・アーカイブの双方で改名しない" \
  "ID・anchor 不変"
contains "$REFINE_FILE" \
  "カウンターは統合時の合算以外変更しない（減算・リセット禁止）" \
  "カウンター非減算"
contains "$REFINE_FILE" \
  "既存エントリ本文の書き換えは本スキル実行中のみ許可（/ace-curate は append-only のまま）" \
  "書き換え許可の refine 限定"
contains "$REFINE_FILE" \
  "コミット件名と PR タイトルは \`knowledge:\` で始める" \
  "knowledge: 件名の強制（reuse 計測の汚染防止）"
contains "$REFINE_FILE" \
  "playbook/archive/<category>.md" \
  "アーカイブ先パスの明示"
contains "$REFINE_FILE" \
  "アーカイブ書き込みの検証（必須）" \
  "アーカイブ write の grep 検証ステップ（文言ルールの機械化）"
contains "$REFINE_FILE" \
  "エントリ保全の一括検証（必須）" \
  "コミット前の全 ID 保全 grep 検証"

echo
echo "== ace-curate 書き込み時ゲート =="

contains "$CURATE_FILE" \
  "一回性のインシデント叙述は Playbook に書かない" \
  "インシデント叙述の記録先分離（TROUBLESHOOTING/runbook）"
contains "$CURATE_FILE" \
  "行数バジェット自己チェック（必須・ブロッキング）" \
  "15 行バジェットの自己チェック"
contains "$CURATE_FILE" \
  "ace-line-budget-exception" \
  "行数バジェット例外マーカーの案内"
contains "$CURATE_FILE" \
  "索引行はタイトルのみ" \
  "索引タイトルのみルール"
contains "$CURATE_FILE" \
  "既存エントリの要約・アーカイブ・統合は \`/ace-refine\` のみが行う" \
  "refine 専権の明示（curate は grow 専用）"
contains "$CURATE_FILE" \
  "| Helpful | 0 | Harmful | 0 |" \
  "コンパクト正準フォーマットのカウンター行（スクリプト互換の行頭パイプ）"
contains "$CURATE_FILE" \
  "既存エントリの本文（新形式の本文 / 旧形式の Insight/Context/Action）の書き換えは禁止" \
  "curate 側の append-only ハードルールが残っている"

echo
echo "== テンプレート（PLAYBOOK / PATTERNS / ace-cycle） =="

contains "$PLAYBOOK_TEMPLATE" \
  "| Helpful | 0 | Harmful | 0 |" \
  "PLAYBOOK テンプレの正準フォーマット"
contains "$PLAYBOOK_TEMPLATE" \
  "playbook/archive/" \
  "PLAYBOOK テンプレの archive 運用ルール"
contains "$PLAYBOOK_TEMPLATE" \
  "ace-line-budget-exception" \
  "PLAYBOOK テンプレの行数バジェット例外"
contains "$PATTERNS_TEMPLATE" \
  "実証済みパターン（ACE 昇格）" \
  "PATTERNS テンプレの昇格先セクション"
contains "$ACE_CYCLE_TEMPLATE" \
  "定期 Refine（grow-and-refine）" \
  "ace-cycle テンプレの Refine 節"

echo
echo "== スクリプト（案内文言・存在） =="

contains "$CHECK_SIZE_SCRIPT" \
  "/ace-refine" \
  "check-category-size の超過時案内が /ace-refine を指す"
contains "$REFINE_REPORT_SCRIPT" \
  "ACE_MAX_ENTRY_LINES" \
  "ace-refine-report の行数バジェット環境変数"
contains "$REFINE_REPORT_SCRIPT" \
  "ACE_PROMOTE_HELPFUL_MIN" \
  "ace-refine-report の昇格閾値環境変数"

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ ace-refine verify: $FAIL 件失敗" >&2
  exit 1
fi
echo "✓ ace-refine verify: 全 $PASS 件 pass"
