#!/usr/bin/env bash
#
# live-ace-gates の検出力を隔離 fixture への mutation で実測する（Issue #441）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
SOURCE_VERIFY="$PLUGIN_ROOT/tests/live-ace-gates/verify.sh"
SOURCE_SCRIPTS="$REPO_ROOT/scripts/ace"
SOURCE_NODE_MODULES="$PLUGIN_ROOT/mcp/node_modules"

for file in \
  "$SOURCE_VERIFY" \
  "$SOURCE_SCRIPTS/check-category-size.ts" \
  "$SOURCE_SCRIPTS/check-entry-format.ts" \
  "$SOURCE_SCRIPTS/sync-playbook-frontmatter.ts"; do
  if [[ ! -s "$file" ]]; then
    echo "✗ live-ace-gates-selftest の入力が存在しないか空です: $file" >&2
    exit 1
  fi
done

if ! command -v node >/dev/null 2>&1; then
  echo "○ skip: node が無いため live-ace-gates-selftest を実行できません（検査は1件も実行されていません）"
  exit 0
fi
if ! command -v perl >/dev/null 2>&1; then
  echo "○ skip: perl が無いため live-ace-gates-selftest の mutation を実行できません（検査は1件も実行されていません）"
  exit 0
fi
if [[ ! -x "$SOURCE_NODE_MODULES/.bin/esbuild" ]]; then
  echo "○ skip: esbuild が無いため live-ace-gates-selftest を実行できません（検査は1件も実行されていません）"
  exit 0
fi
# mktemp の診断を捨てると不正 TMPDIR と read-only を区別できないため、成功時のパスと
# 失敗時の理由を同じ変数へ受ける。
if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/live-ace-gates-selftest.XXXXXX" 2>&1)"; then
  FIXTURE_ROOT="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できないため live-ace-gates-selftest を実行できません（検査は1件も実行されていません）"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  exit 0
fi

REACHED_END=0
cleanup() {
  local rc=$?
  rm -rf "$FIXTURE_ROOT"
  if [[ "$REACHED_END" -ne 1 && "$rc" -eq 0 ]]; then
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

FIXTURE_REPO="$FIXTURE_ROOT/repo"
FIXTURE_PLUGIN="$FIXTURE_REPO/plugins/ff-dev-toolkit"
FIXTURE_KNOWLEDGE="$FIXTURE_REPO/docs/08-knowledge"
FIXTURE_PLAYBOOK="$FIXTURE_KNOWLEDGE/PLAYBOOK.md"
mkdir -p \
  "$FIXTURE_PLUGIN/tests/live-ace-gates" \
  "$FIXTURE_PLUGIN/mcp" \
  "$FIXTURE_REPO/scripts/ace" \
  "$FIXTURE_KNOWLEDGE"
cp "$SOURCE_VERIFY" "$FIXTURE_PLUGIN/tests/live-ace-gates/verify.sh"
chmod +x "$FIXTURE_PLUGIN/tests/live-ace-gates/verify.sh"
ln -s "$SOURCE_NODE_MODULES" "$FIXTURE_PLUGIN/mcp/node_modules"
cp "$SOURCE_SCRIPTS/check-category-size.ts" "$FIXTURE_REPO/scripts/ace/"
cp "$SOURCE_SCRIPTS/check-entry-format.ts" "$FIXTURE_REPO/scripts/ace/"
cp "$SOURCE_SCRIPTS/sync-playbook-frontmatter.ts" "$FIXTURE_REPO/scripts/ace/"

cat >"$FIXTURE_PLAYBOOK" <<'EOF'
---
title: "PLAYBOOK"
version: "1.0.0"
status: "draft"
owner: "@fixture"
created: "2026-08-12"
updated: "2026-08-12"
changeImpact: low
ace_entry_count: 1
---

# ACE Playbook

### ACE-900-1: 正準 fixture

| Category | process | Origin | fixture |
| Date | 2026-08-12 |
| Helpful | 0 | Harmful | 0 |
| Status | active |

正準形式の本文。

## Changelog

### [1.0.0] - 2026-08-12
EOF
cp "$FIXTURE_PLAYBOOK" "$FIXTURE_ROOT/baseline-playbook.md"

PASS=0
FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }
run_gate() {
  set +e
  GATE_OUTPUT="$(bash "$FIXTURE_PLUGIN/tests/live-ace-gates/verify.sh" 2>&1)"
  GATE_RC=$?
  set -e
}

echo "== live-ace-gates self-test =="

run_gate
if [[ "$GATE_RC" -eq 0 ]] && [[ "$GATE_OUTPUT" == *"live ACE の新規旧形式エントリは 0 件"* ]] && [[ "$GATE_OUTPUT" == *"live ACE の entry count / version / changeImpact は同期済み"* ]]; then
  ok "正常 fixture で形式・frontmatter の両ゲートが通る"
else
  bad "正常 fixture が通らない（rc=${GATE_RC}）"
  printf '%s\n' "$GATE_OUTPUT" >&2
fi

cat >>"$FIXTURE_PLAYBOOK" <<'EOF'

### ACE-900-2: 旧形式 mutation

| フィールド | 値 |
| --- | --- |
| Category | process |
| Date | 2026-08-12 |
| Helpful | 0 |
| Harmful | 0 |
| Status | active |

### Insight

旧形式を注入する。
EOF
run_gate
if [[ "$GATE_RC" -ne 0 ]] && [[ "$GATE_OUTPUT" == *"ACE-900-2"* ]]; then
  ok "allowlist 外の旧形式エントリを ID 付きで拒否する"
else
  bad "旧形式 mutation を ID 付きで拒否できない（rc=${GATE_RC}）"
  printf '%s\n' "$GATE_OUTPUT" >&2
fi

cp "$FIXTURE_ROOT/baseline-playbook.md" "$FIXTURE_PLAYBOOK"
perl -0pi -e 's/ace_entry_count: 1/ace_entry_count: 2/' "$FIXTURE_PLAYBOOK"
run_gate
if [[ "$GATE_RC" -ne 0 ]] && [[ "$GATE_OUTPUT" == *"ace_entry_count がドリフト"* ]]; then
  ok "frontmatter の entry count drift を拒否する"
else
  bad "frontmatter drift mutation を拒否できない（rc=${GATE_RC}）"
  printf '%s\n' "$GATE_OUTPUT" >&2
fi

mv "$FIXTURE_KNOWLEDGE" "$FIXTURE_REPO/docs/08-knowledge.absent"
run_gate
if [[ "$GATE_RC" -eq 0 ]] && [[ "$GATE_OUTPUT" == ○\ skip:* ]]; then
  ok "docs/08-knowledge 不在は明示 skip + exit 0 になる"
else
  bad "docs/08-knowledge 不在の適用外境界が不正（rc=${GATE_RC}）"
  printf '%s\n' "$GATE_OUTPUT" >&2
fi

echo
if [[ "$FAIL" -gt 0 ]]; then
  echo "✗ live-ace-gates self-test: $FAIL 件失敗（$PASS 件成功）" >&2
  REACHED_END=1
  exit 1
fi
echo "✓ live-ace-gates self-test: 全 $PASS 件 pass"
REACHED_END=1
