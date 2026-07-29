#!/usr/bin/env bash
#
# /ace-curate の knowledge commit 例が commitlint の件名長超過を誘発しないことを
# 固定する回帰検査（Issue #184）。
#
# カテゴリ列挙を件名へ戻すと、利用先リポジトリの header-max-length を超えやすい。
# 既定・PR エスカレーションの両経路で、短い件名 + カテゴリを body に置く契約を
# fail-closed で検証する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMMAND_FILE="$PLUGIN_ROOT/skills/ace-curate/SKILL.md"

[ -s "$COMMAND_FILE" ] || {
  echo "✗ ace-curate.md が存在しないか空です: $COMMAND_FILE" >&2
  exit 1
}

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

expect_fixed_count() {
  local needle="$1" expected="$2" label="$3" count
  count="$(grep -Fc -- "$needle" "$COMMAND_FILE" || true)"
  if [ "$count" -eq "$expected" ]; then
    ok "${label}（$count 件）"
  else
    bad "${label} — expected=$expected actual=$count"
  fi
}

expect_contains() {
  local needle="$1" label="$2"
  if grep -Fq -- "$needle" "$COMMAND_FILE"; then
    ok "$label"
  else
    bad "${label} — '$needle' が見つかりません"
  fi
}

echo "== ace-curate knowledge commit 契約検査 =="

expect_fixed_count \
  '-m "knowledge: ACE-<PR番号>-<連番> <要約>"' \
  2 \
  "既定・PR 両経路の件名がカテゴリ列挙を含まない短い形式"

expect_fixed_count \
  '-m "Categories: <category[, category...]>"' \
  2 \
  "既定・PR 両経路でカテゴリを commit body に記録"

if grep -Eq 'knowledge: ACE-[^"]*\[(category|summary)\]' "$COMMAND_FILE"; then
  bad "旧プレースホルダ [category] / [summary] が knowledge 件名へ再混入しています"
else
  ok "knowledge 件名に旧プレースホルダ [category] / [summary] が無い"
fi

expect_contains \
  "対象リポジトリの commitlint 設定（特に \`header-max-length\`）を確認" \
  "対象リポジトリの commitlint 件名長制約を確認する案内"

expect_contains \
  'カテゴリが複数でも件名には列挙せず、commit body に記録する' \
  "カテゴリを件名へ列挙しない明示"

expect_contains \
  '要約を短くするかコミットを分割する' \
  "要約だけで上限を超える場合の是正案"

expect_fixed_count \
  '--title "knowledge: ACE-<PR番号>-<連番> <要約>"' \
  1 \
  "squash 件名になり得る PR title もカテゴリ列挙を含まない形式"

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ ace-curate commit verify: $FAIL 件失敗" >&2
  exit 1
fi
echo "✓ ace-curate commit verify: 全 $PASS 件 pass"
