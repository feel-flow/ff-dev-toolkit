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
FORMAT_GATE_SCRIPT="$PLUGIN_ROOT/docs-template/scripts/ace/check-entry-format.ts"
LEGACY_ALLOWLIST_TEMPLATE="$PLUGIN_ROOT/docs-template/08-knowledge/legacy-format-allowlist.txt"

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
echo "== archive / provenance 契約の 3 穴（Issue #288） =="

# 穴 1: provenance 注記が「再整形のみ」を表現できず、実際にしていない要約を記録していた。
# 2 変種と判定条件の両方を固定する（片方だけ残ると再び文言の孤島が生まれる）。
contains "$REFINE_FILE" \
  "> Compacted: YYYY-MM-DD（live 側を要約済み。本文の原文は本エントリが正）" \
  "provenance 注記 第1変種（本文を意味保存要約した場合）"
contains "$REFINE_FILE" \
  "> Compacted: YYYY-MM-DD（live 側はメタ表のみ正準フォーマットへ再整形。本文は逐語同一で無改変。本エントリが原文）" \
  "provenance 注記 第2変種（メタ表の再整形のみ・本文は逐語同一）"
contains "$REFINE_FILE" \
  "live 側の本文文字列が原文と逐語同一かどうか" \
  "2 変種の判定条件"
contains "$REFINE_FILE" \
  "provenance 注記は実際に行った操作に対応する変種を使う" \
  "ハードルール: 実際にしていない操作を注記に書かない"

# 穴 2: 保全本文内の相対リンクは verbatim 保全のため書き換えられない。
# 「書き換えない」と「注記が必須」は対で意味を持つ（片方だけでは行動が決まらない）。
contains "$REFINE_FILE" \
  "保全本文内の相対リンクは live 基準" \
  "archive 冒頭注記のテンプレート文言（機械ゲートの判定キー）"
contains "$REFINE_FILE" \
  "保全本文内の相対リンクは書き換えない" \
  "保全本文内リンクの非書き換え契約"
contains "$REFINE_FILE" \
  "check-archive-links" \
  "注記の存在を強制する機械ゲートへの導線"

# 穴 3: 統合された側が archive で active のまま残り、grep した人に有効と誤読される。
contains "$REFINE_FILE" \
  "archive 側のコピーの \`Status\` を \`merged\` に変える" \
  "統合される側の Status を merged にする手順"
contains "$PLAYBOOK_TEMPLATE" \
  "\`merged\`" \
  "PLAYBOOK テンプレの §ステータス定義に merged がある"

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
echo "== エントリ形式ゲート（Issue #286） =="

[ -s "$FORMAT_GATE_SCRIPT" ] || {
  echo "  ✗ 形式ゲートスクリプトが存在しないか空です: $FORMAT_GATE_SCRIPT" >&2
  FAIL=$((FAIL + 1))
}
[ -s "$LEGACY_ALLOWLIST_TEMPLATE" ] || {
  echo "  ✗ allowlist テンプレートが存在しないか空です: $LEGACY_ALLOWLIST_TEMPLATE" >&2
  FAIL=$((FAIL + 1))
}

# 判定軸（allowlist）と fail-closed の設計をスクリプト側で固定する。Date 閾値へ
# 差し替えられると「著者が手で書くフィールド」が判定軸になり偶然通せるようになる。
contains "$FORMAT_GATE_SCRIPT" \
  "legacy-format-allowlist.txt" \
  "判定軸が allowlist ファイルであること"
contains "$FORMAT_GATE_SCRIPT" \
  "fail-open にすると、allowlist を" \
  "allowlist 不在時に strict へ倒す（fail-closed）理由の明示"
contains "$FORMAT_GATE_SCRIPT" \
  "playbook/archive/" \
  "archive を走査対象外にする旨"

# allowlist を新規追記の抜け道にしない、という運用の意図は 3 箇所に複製されている。
# 1 箇所だけ残ると「allowlist に足せば通る」と読まれてゲートが空洞化する。
contains "$CURATE_FILE" \
  "check-entry-format" \
  "curate の同期検証に形式ゲートが配線されている"
contains "$CURATE_FILE" \
  "新規 ID を足して通すことはしない" \
  "curate 側: allowlist を抜け道にしない"
contains "$REFINE_FILE" \
  "check-entry-format" \
  "refine の検証ゲートに形式ゲートが配線されている"
contains "$REFINE_FILE" \
  "正準化した ID を allowlist から削除する" \
  "refine 側: 正準化後の allowlist 掃除手順"
contains "$PLAYBOOK_TEMPLATE" \
  "新規追記のために allowlist へ ID を足さない" \
  "PLAYBOOK テンプレ: allowlist を抜け道にしない"
contains "$LEGACY_ALLOWLIST_TEMPLATE" \
  "新規追記でこのファイルに ID を足さない" \
  "allowlist テンプレ自身に運用ルールが書かれている"

# 配布物の自己整合: docs-template 同梱の playbook シード（全 131 件が旧形式）が
# テンプレート同梱の allowlist で網羅されていること。allowlist を空で配ると、
# 利用者が docs-template をコピーした瞬間に形式ゲートが赤くなる。
# 件数は allowlist / シードの双方を数えて突き合わせる（どちらかに固定値を書かない）。
TEMPLATE_PLAYBOOK_DIR="$PLUGIN_ROOT/docs-template/08-knowledge/playbook"
if [ -d "$TEMPLATE_PLAYBOOK_DIR" ]; then
  SEED_LEGACY_IDS="$(
    for pb in "$TEMPLATE_PLAYBOOK_DIR"/*.md; do
      [ -f "$pb" ] || continue
      awk '
        /^### ACE-/ { if (cur != "") emit(); cur = $2; sub(/:$/, "", cur); legacy = 0 }
        /^\*\*(Insight|Context|Action)\*\*/ { legacy = 1 }
        /^\|[[:space:]]*フィールド[[:space:]]*\|/ { legacy = 1 }
        /^\|[[:space:]:|-]*-{3,}[[:space:]:|-]*\|/ { legacy = 1 }
        END { if (cur != "") emit() }
        function emit() { if (legacy) print cur }
      ' "$pb"
    done | sort -u
  )"
  ALLOWED_IDS="$(grep -E '^ACE-' "$LEGACY_ALLOWLIST_TEMPLATE" 2>/dev/null | sort -u || true)"
  MISSING="$(comm -23 <(printf '%s\n' "$SEED_LEGACY_IDS") <(printf '%s\n' "$ALLOWED_IDS"))"
  SEED_COUNT="$(printf '%s\n' "$SEED_LEGACY_IDS" | grep -c '^ACE-' || true)"
  if [ -n "$MISSING" ]; then
    bad "docs-template のシード旧形式エントリが allowlist に未収載（利用者のコピー直後にゲートが赤くなる）: $(printf '%s' "$MISSING" | tr '\n' ' ')"
  else
    ok "docs-template のシード旧形式 ${SEED_COUNT} 件がすべて allowlist に収載されている"
  fi
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ ace-refine verify: $FAIL 件失敗" >&2
  exit 1
fi
echo "✓ ace-refine verify: 全 $PASS 件 pass"
