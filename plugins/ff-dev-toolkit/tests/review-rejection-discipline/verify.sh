#!/usr/bin/env bash
#
# review-rejection-discipline: レビュー指摘を却下するときの検証規律の回帰検査（Issue #655）。
#
# 背景: 却下理由の誤診断（複数要素を同時に変えた再現で「generic だから落ちる」と
# 結論）がコミットメッセージと docblock に固定化され、さらに「提案するな」という
# 指示形で書かれたため、後続レビューの正しい再提案まで拒否される状態が実測された
# （利用側リポジトリの連続 2 PR）。正しい指摘を誤った理由で却下する事故は、
# 修正より発見が遅く、コストが 2 PR 分に膨らむ。
#
# 本 suite は review-response-policy.md（全レビューソース共通の対応 SSOT）の
# 「指摘を却下（スキップ）するとき」節を抽出し、その節スコープで却下 4 要件が
# 番号順に残っていることを固定する（文言が節の外へ散っても別文脈の偶然一致では
# 緑にならない）。義務文の針は句点まで含め、「実測する。」→「実測することが
# 望ましい。」のような義務→推奨の弱体化も検出する。要件の発動条件（技術的制約の
# 主張であるときだけ実測を要求し、設計方針・スコープ判断の却下には要求しない）が
# 消えると、全却下への一律実測要求へ侵食してレビュー速度を落とすため、絞り込み句も
# 針で固定する。消費側は multi-review の「PR Review Response Policy に従い…自動修正
# します」の委譲行 1 本を全文針で見る（分類表をインライン展開している multi-review が
# 採否処理をポリシーへ委譲する記述を保てているか。ポリシー文書へのファイルリンクの
# 有無までは固定しない）。
#
# 外部コマンド・一時領域不要の静的検査。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

REVIEW_POLICY="$PLUGIN_ROOT/docs-template/05-operations/deployment/review-response-policy.md"
MULTI_REVIEW="$PLUGIN_ROOT/skills/multi-review/SKILL.md"

for f in "$REVIEW_POLICY" "$MULTI_REVIEW"; do
  [[ -s "$f" ]] || { echo "✗ 対象ファイルが見つからないか空です: $f" >&2; exit 1; }
done

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file"; then
    ok "$label"
  else
    bad "${label}（不足: ${needle}）"
  fi
}

not_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file"; then
    bad "${label}（旧文言が残存: ${needle}）"
  else
    ok "$label"
  fi
}

echo "== 却下時の検証規律（review-response-policy.md・節スコープ） =="

# 消費側文書が名指しする表示名「PR Review Response Policy」と本ファイルの結びつき。
# H1 が変わると名指しの解決先が失われるため、表示名を含む見出しを固定する。
contains "$REVIEW_POLICY" "# PRレビュー対応ポリシー（Review Response Policy）" \
  "ポリシーの H1 が表示名 Review Response Policy を保持"

# 対象節を抽出し、以降の要件検査は節スコープで行う。ファイル全体への固定文字列
# 検索だと、要件文が別節やコメントへ散っても偶然一致で緑になるため。
SECTION="$(awk '
  index($0, "### 指摘を却下（スキップ）するとき") == 1 { insec = 1; next }
  insec && (/^## / || /^### / || /^---/) { exit }
  insec { print }
' "$REVIEW_POLICY")"

if [[ -n "$SECTION" ]]; then
  ok "「指摘を却下（スキップ）するとき」節を抽出できた（抽出の空振りを緑にしない）"
else
  bad "「指摘を却下（スキップ）するとき」節を抽出できません（見出しの削除・改名）"
fi

# 節スコープの固定文字列検査。義務文は句点まで含めて針にし、「〜する。」→
# 「〜することが望ましい。」のようなサフィックス弱体化も赤くする。
section_contains() {
  local needle="$1" label="$2"
  if [[ "$SECTION" == *"$needle"* ]]; then
    ok "$label"
  else
    bad "${label}（節内に不足: ${needle}）"
  fi
}

section_contains "1 変数ずつ切り分けて実測する。" \
  "技術的制約の却下理由に単変数の実測を要求（義務文）"
section_contains "「提案コードが落ちた」は原因の特定ではない" \
  "提案コードの失敗を原因特定と混同しない"
section_contains "各要素を単独で戻して確かめる" \
  "複数要素を同時に変えた再現の切り分け手順がある"
section_contains "設計方針・スコープ判断による却下は従来どおり理由の記録のみでよい" \
  "実測要求の発動条件が技術的制約の主張に絞られている（レビュー速度の保護）"
section_contains "実測した範囲だけを書く。" \
  "コードコメントには実測範囲のみを残す（義務文）"
section_contains "将来のレビュアーへの指示形（「提案するな」「使うな」）を書かない。" \
  "指示形コメントの禁止（義務文）"
section_contains "指摘の趣旨と、添えられた実装の正しさは別物として扱う。" \
  "趣旨と実装の分離（義務文）"
section_contains "提案コードが通らないことは、指摘そのものが誤りである証拠にならない" \
  "提案コードの失敗が指摘の反証にならないことを明記"

# 番号付き要件の個数と順序。要件の統合・削除・並べ替えで番号列が変わる。
NUM_SEQ="$(printf '%s\n' "$SECTION" | awk '/^[0-9]+\. / { printf "%s", substr($0, 1, index($0, ".") - 1) }')"
if [[ "$NUM_SEQ" == "1234" ]]; then
  ok "番号付き要件が 4 項目・順序どおり（1234）"
else
  bad "番号付き要件の個数または順序が想定と異なります（実測: ${NUM_SEQ:-なし} / 期待: 1234）"
fi

echo
echo "== 対応フローからの導線 =="

contains "$REVIEW_POLICY" "却下時の検証要件は下記「指摘を却下（スキップ）するとき」" \
  "対応フロー図のスキップ分岐が検証要件節へ誘導"
not_contains "$REVIEW_POLICY" "└─ 不適切 → スキップ（理由を記録）" \
  "導線のないスキップ分岐（旧文言）への復元を検出"

echo
echo "== 消費側スキルの委譲行 =="

contains "$MULTI_REVIEW" "PR Review Response Policy に従い、Critical/Warning/妥当な Suggestion を自動修正します" \
  "multi-review が Suggestion の採否処理をポリシーへ委譲する行を保持"

echo
# 検査総数の固定。contains 呼び出しの削除侵食（検査だけが消えて緑のまま通る）を
# 赤くする。針の増減時は EXPECTED_TOTAL も同時に更新すること。
EXPECTED_TOTAL=14
TOTAL=$((PASS + FAIL))
if [[ "$TOTAL" -eq "$EXPECTED_TOTAL" ]]; then
  echo "  ✓ 検査総数が ${EXPECTED_TOTAL} 件（増減時は EXPECTED_TOTAL も更新すること）"
else
  echo "  ✗ 検査総数が想定と異なります（実測: ${TOTAL} / 期待: ${EXPECTED_TOTAL}）" >&2
  FAIL=$((FAIL + 1))
fi

echo
echo "結果: PASS=${PASS} FAIL=${FAIL}"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
echo "✅ review-rejection-discipline: 全 ${TOTAL} 件 pass"
