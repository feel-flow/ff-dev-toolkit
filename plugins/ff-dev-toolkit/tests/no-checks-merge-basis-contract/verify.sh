#!/usr/bin/env bash
#
# no-checks-merge-basis-contract: PR トリガーの CI を持たないリポジトリ（本リポジトリを
# 含む）で、checks を待たずローカル全件ゲート + 鮮度照合をマージ根拠にする分岐の
# 回帰検査。
#
# 守っている事故: `gh pr checks --watch` は checks が 1 件も登録されない repo では
# `no checks reported` を返して即終了する。これを CI 通過と早合点すると、CI が
# 一度も走らないまま squash merge が成立する。逆に `statusCheckRollup` の登録を
# 自作の待機ループで待つと、checks が存在しない repo では対象が現れず終わらない。
# 観測台帳 OBS-070 が Count 3 に到達した事例（この分岐を手順として固定していなかった
# ため、実行者が毎回別の待機ループを自作していた）。
#
# 検査対象は 2 文書 2 箇所:
#   - close-issue/SKILL.md 手順 7 の「CI checks の有無による分岐」小節
#     （`statusCheckRollup` 空配列 → checks を待たない分岐と完了報告への明記）
#   - git-workflow.md ステップ8（マージ）の「PR トリガーの CI を持たないリポジトリでの
#     checks 待機」小節（`no checks reported` を CI 通過とみなさない旨と、待機と
#     マージを 1 チェーンに繋がない旨）
#
# 文書全体の grep ではなく節スコープで照合するのは、同じ語が別節（ハードルール節・
# 引用・再掲）へ書き写された時点で「本来在るべき節から消えても緑のまま」通るのを
# 防ぐため（tests/lib/section-scope.sh のヘッダーコメント参照。ACE-810-1 と同型の懸念）。
# 対象節はいずれも bash フェンスを含むため、フェンス追跡を持つ共通ヘルパでなければ節が
# 途中で切れる。
#
# 使い方: bash plugins/ff-dev-toolkit/tests/no-checks-merge-basis-contract/verify.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

SKILL="$PLUGIN_ROOT/skills/close-issue/SKILL.md"
WORKFLOW="$PLUGIN_ROOT/docs-template/05-operations/deployment/git-workflow.md"

# shellcheck source=../lib/section-scope.sh
. "$SCRIPT_DIR/../lib/section-scope.sh"

SKILL_HEADING='#### CI checks の有無による分岐（待つか、ローカルゲートを根拠にするか）'
WORKFLOW_HEADING='#### PR トリガーの CI を持たないリポジトリでの checks 待機'
FRESHNESS_HEADING='#### ゲート実測鮮度そのものの照合'

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

# 完了報告テンプレートは 2 種（Closes 運用 / Refs 運用）あり、片方だけに欄が残る退行を
# 拾うため件数で固定する（merge-freshness の全文 contains と同型 + 出現数の主張）。
file_contains_count() { # <file> <needle> <expected> <label>
  local file="$1" needle="$2" expected="$3" label="$4" actual
  actual="$(grep -cF -- "$needle" "$file" || true)"
  if [[ "$actual" = "$expected" ]]; then
    ok "$label"
  else
    bad "${label}（期待 ${expected} 件 / 実際 ${actual} 件: ${needle}）"
  fi
}

section_contains() {
  local file="$1" heading="$2" needle="$3" label="$4" reason
  if reason="$(section_scope_contains "$file" "$heading" "$needle")"; then
    ok "$label"
  else
    bad "${label}（不足: ${reason}）"
  fi
}

for file in "$SKILL" "$WORKFLOW"; do
  if [[ ! -s "$file" ]]; then
    echo "  ✗ 必須ファイルが無い、または空: $file" >&2
    echo "✗ no-checks-merge-basis-contract verify: 必須ファイル欠落のため中断" >&2
    exit 1
  fi
done
ok "必須ファイルが 2 件とも存在し非空"

echo
echo "-- close-issue/SKILL.md 手順 7: checks 有無の分岐 --"

section_contains "$SKILL" "$SKILL_HEADING" \
  'この PR に登録された checks は無い。マージ可否はローカル全件ゲート + 鮮度照合で判定する' \
  "statusCheckRollup 空配列時の完了報告文言がある"

section_contains "$SKILL" "$SKILL_HEADING" \
  '`statusCheckRollup` が**空配列**（`null` も同じ扱い）の場合、checks の完了を待たずに次へ進み' \
  "空配列時に checks の完了を待たない旨を明記している"

section_contains "$SKILL" "$SKILL_HEADING" \
  '`statusCheckRollup` が**非空**の場合は、従来どおり全 checks の完了と成功を確認してからマージへ' \
  "非空時は従来どおり全 checks の完了・成功確認を維持する旨がある"

section_contains "$SKILL" "$SKILL_HEADING" \
  "gh pr view \"\${PR_NUMBER}\" --json statusCheckRollup" \
  "statusCheckRollup の判定コマンドがある"

section_contains "$SKILL" "$SKILL_HEADING" \
  "(.statusCheckRollup // []) | length" \
  "null を空扱いにする jq 式で件数を取っている"

section_contains "$SKILL" "$SKILL_HEADING" \
  '= "0"' \
  "checks 不在の判定を件数 0 で行っている"

section_contains "$SKILL" "$SKILL_HEADING" \
  '--watch --fail-fast' \
  "非空時は --watch --fail-fast で完了を待つ"

section_contains "$SKILL" "$SKILL_HEADING" \
  'マージへ進まない' \
  "checks 失敗時にマージへ進まない旨がある"

file_contains_count "$SKILL" \
  '- CI checks: <手順 7 の CHECKS_REPORT をそのまま貼る>' 2 \
  "完了報告テンプレート 2 種の両方に CI checks 欄がある"

echo
echo "-- close-issue/SKILL.md 手順 7: 判定不能時の再実行条件 --"

section_contains "$SKILL" "$FRESHNESS_HEADING" \
  '鮮度照合が判定不能（`FRESH_STATUS=2`）で、かつ `FRESH_REASON` が' \
  "判定不能時の全件ゲート再実行が FRESH_REASON 条件付きで書かれている"

echo
echo "-- git-workflow.md ステップ8: no checks reported の扱い --"

section_contains "$WORKFLOW" "$WORKFLOW_HEADING" \
  'no checks reported' \
  "no checks reported の文言がある"

section_contains "$WORKFLOW" "$WORKFLOW_HEADING" \
  'これを **CI 通過とは' \
  "no checks reported を CI 通過とみなさない旨がある"

section_contains "$WORKFLOW" "$WORKFLOW_HEADING" \
  '待機とマージを 1 つのコマンドチェーンに繋がない' \
  "待機とマージを 1 チェーンに繋がない旨がある"

section_contains "$WORKFLOW" "$WORKFLOW_HEADING" \
  'checks が無いと判った場合はローカル全件ゲート + 鮮度照合' \
  "checks が無い場合のマージ根拠（ローカル全件ゲート + 鮮度照合）を明記している"

echo
if [[ "$FAIL" -gt 0 ]]; then
  echo "✗ no-checks-merge-basis-contract verify: $FAIL 件失敗 / $PASS 件成功" >&2
  exit 1
fi

echo "✓ no-checks-merge-basis-contract verify: 全 $PASS 件 pass"
