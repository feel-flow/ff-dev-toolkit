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
  "$SOURCE_SCRIPTS/sync-playbook-frontmatter.ts" \
  "$SOURCE_SCRIPTS/check-archive-links.ts" \
  "$SOURCE_SCRIPTS/check-refine-invariants.ts" \
  "$SOURCE_SCRIPTS/ace-reuse-report.ts" \
  "$SOURCE_SCRIPTS/ace-refine-report.ts"; do
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
cp "$SOURCE_SCRIPTS/check-archive-links.ts" "$FIXTURE_REPO/scripts/ace/"
cp "$SOURCE_SCRIPTS/check-refine-invariants.ts" "$FIXTURE_REPO/scripts/ace/"
cp "$SOURCE_SCRIPTS/ace-reuse-report.ts" "$FIXTURE_REPO/scripts/ace/"
cp "$SOURCE_SCRIPTS/ace-refine-report.ts" "$FIXTURE_REPO/scripts/ace/"

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
if [[ "$GATE_RC" -eq 0 ]] && [[ "$GATE_OUTPUT" == *"live ACE の新規旧形式エントリは 0 件"* ]] && [[ "$GATE_OUTPUT" == *"live ACE の entry count / version / changeImpact は同期済み"* ]] && [[ "$GATE_OUTPUT" == *"live ACE の archive リンク注記と <a id> 一意性"* ]] && [[ "$GATE_OUTPUT" == *"live ACE の refine 結果不変条件"* ]]; then
  ok "正常 fixture で形式・frontmatter・archive・refine の各ゲートが通る"
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

write_refine_fixture() {
  local knowledge="$FIXTURE_KNOWLEDGE"
  mkdir -p "$knowledge/playbook/archive" "$FIXTURE_REPO/docs/03-implementation"
  cat >"$FIXTURE_PLAYBOOK" <<'EOF'
---
title: "PLAYBOOK"
version: "1.0.0"
status: "draft"
owner: "@fixture"
created: "2026-08-12"
updated: "2026-08-12"
changeImpact: low
ace_entry_count: 2
---

# ACE Playbook

## エントリ一覧

| エントリID | タイトル | Category | 参照先 |
| ---------- | -------- | -------- | ------ |
| ACE-41-3   | 並列委任 | process | [playbook/process.md#ace-41-3](./playbook/process.md#ace-41-3) |
| ACE-404-2  | trap | testing | [playbook/testing.md#ace-404-2](./playbook/testing.md#ace-404-2) |

## Changelog

### [1.0.0] - 2026-08-12

#### 整理（/ace-refine）

- Merged: ACE-430-1 → ACE-404-2
- Compacted: ACE-41-3
- Promoted: ACE-72-2
EOF
  cat >"$knowledge/playbook/process.md" <<'EOF'
### ACE-41-3: 並列委任

| Category | process | Origin | PR #41 |
| Date | 2026-07-07 |
| Helpful | 4 | Harmful | 0 |
| Status | active |

複数ファイルを機械的にコピーすると一部だけ完了する。
EOF
  cat >"$knowledge/playbook/testing.md" <<'EOF'
### ACE-404-2: trap

| Category | testing | Origin | PR #404 |
| Date | 2026-08-12 |
| Helpful | 2 | Harmful | 0 |
| Status | active |

終了ステータスの保存では直らない。
EOF
  cat >"$knowledge/playbook/archive/process.md" <<'EOF'
# PLAYBOOK Archive — process (process)

> **Parent**: [PLAYBOOK.md](../../PLAYBOOK.md) — 保管場所。
> **保全本文内の相対リンクは live 基準**: 読み替え。

---

### ACE-41-3: 並列委任

> Compacted: 2026-08-14（live 側はメタ表のみ正準フォーマットへ再整形。本文は逐語同一で無改変。本エントリが原文）

| フィールド | 値 |
| --- | --- |
| Category | process |
| Origin | PR #41 |
| Date | 2026-07-07 |
| Helpful | 4 |
| Harmful | 0 |
| Status | active |

複数ファイルを機械的にコピーすると一部だけ完了する。
EOF
  cat >"$knowledge/playbook/archive/testing.md" <<'EOF'
# PLAYBOOK Archive — testing (testing)

> **Parent**: [PLAYBOOK.md](../../PLAYBOOK.md) — 保管場所。
> **保全本文内の相対リンクは live 基準**: 読み替え。

---

### ACE-430-1: trap source

> Merged into: [ACE-404-2](../testing.md#ace-404-2)（2026-08-14 /ace-refine）

| Category | testing | Origin | PR #430 |
| Date | 2026-08-12 |
| Helpful | 1 | Harmful | 0 |
| Status | merged |

トラップ最終コマンドの成功が rc を上書きする。
EOF
  cat >"$FIXTURE_REPO/docs/03-implementation/PATTERNS.md" <<'EOF'
## 13. 実証済みパターン（ACE 昇格）

### hook の fail-open

恒久異常は通知したうえで exit 0 にする。

出典: [ACE-72-2](../08-knowledge/playbook/tooling.md#ace-72-2)
EOF
}

echo
echo "== refine / archive mutation =="

write_refine_fixture
run_gate
if [[ "$GATE_RC" -eq 0 ]] && [[ "$GATE_OUTPUT" == *"live ACE の refine 結果不変条件"* ]]; then
  ok "健全な refine fixture が通る"
else
  bad "健全な refine fixture が通らない（rc=${GATE_RC}）"
  printf '%s\n' "$GATE_OUTPUT" >&2
fi

perl -0pi -e 's/> \*\*保全本文内の相対リンクは live 基準\*\*: 読み替え。/> 注記を消した。/' \
  "$FIXTURE_KNOWLEDGE/playbook/archive/process.md"
# 注記削除を検出するには ./ リンクが 1 件以上必要
printf '\n本文 [ACE-41-3](./process.md#ace-41-3)。\n' >>"$FIXTURE_KNOWLEDGE/playbook/archive/process.md"
run_gate
if [[ "$GATE_RC" -ne 0 ]] && [[ "$GATE_OUTPUT" == *"保全本文内の相対リンクは live 基準"* || "$GATE_OUTPUT" == *"冒頭注記"* ]]; then
  ok "archive 冒頭注記の削除を非 0 で検出する"
else
  bad "注記削除 mutation を拒否できない（rc=${GATE_RC}）"
  printf '%s\n' "$GATE_OUTPUT" >&2
fi

write_refine_fixture
printf '\n> **保全本文内の相対リンクは live 基準**: 本文に書いた。\n本文 [ACE-41-3](./process.md#ace-41-3)。\n' \
  >>"$FIXTURE_KNOWLEDGE/playbook/archive/process.md"
perl -0pi -e 's/> \*\*保全本文内の相対リンクは live 基準\*\*: 読み替え。/> Parent からは外した。/' \
  "$FIXTURE_KNOWLEDGE/playbook/archive/process.md"
run_gate
if [[ "$GATE_RC" -ne 0 ]]; then
  ok "Parent ブロック外の注記マーカーでは通さない"
else
  bad "Parent ブロック外の注記を通してしまった（rc=${GATE_RC}）"
  printf '%s\n' "$GATE_OUTPUT" >&2
fi

write_refine_fixture
cat >>"$FIXTURE_KNOWLEDGE/playbook/archive/testing.md" <<'EOF'

<a id="ace-430-1"></a>

### ACE-430-1: 重複アンカー
EOF
# 見出しが 2 件になると refine 側も一意性違反になるが、アンカー重複は archive-links が先に名指しする
printf '\n<a id="ace-430-1"></a>\n' >>"$FIXTURE_KNOWLEDGE/playbook/archive/testing.md"
run_gate
if [[ "$GATE_RC" -ne 0 ]] && [[ "$GATE_OUTPUT" == *"ace-430-1"* ]]; then
  ok "archive 内の重複 <a id> を検出する"
else
  bad "重複アンカー mutation を拒否できない（rc=${GATE_RC}）"
  printf '%s\n' "$GATE_OUTPUT" >&2
fi

write_refine_fixture
perl -0pi -e 's/一部だけ完了する。/要約して壊した。/' "$FIXTURE_KNOWLEDGE/playbook/process.md"
run_gate
if [[ "$GATE_RC" -ne 0 ]] && [[ "$GATE_OUTPUT" == *"ACE-41-3"* ]]; then
  ok "compact 本文の食い違いを検出する"
else
  bad "compact 本文 mutation を拒否できない（rc=${GATE_RC}）"
  printf '%s\n' "$GATE_OUTPUT" >&2
fi

write_refine_fixture
cat >>"$FIXTURE_KNOWLEDGE/playbook/testing.md" <<'EOF'

### ACE-430-1: 統合元が live に残存

| Category | testing | Origin | PR #430 |
| Date | 2026-08-12 |
| Helpful | 1 | Harmful | 0 |
| Status | active |

残存。
EOF
# ace_entry_count は 3 になるが frontmatter は 2 のままなので frontmatter ゲートが先に赤くなる。
# 件数を合わせて merge 退役検査だけを見る。
perl -0pi -e 's/ace_entry_count: 2/ace_entry_count: 3/' "$FIXTURE_PLAYBOOK"
run_gate
if [[ "$GATE_RC" -ne 0 ]] && [[ "$GATE_OUTPUT" == *"ACE-430-1"* ]]; then
  ok "merge 統合元の live 残存を検出する"
else
  bad "merge 残存 mutation を拒否できない（rc=${GATE_RC}）"
  printf '%s\n' "$GATE_OUTPUT" >&2
fi

write_refine_fixture
cat >"$FIXTURE_REPO/docs/03-implementation/PATTERNS.md" <<'EOF'
## 13. 実証済みパターン（ACE 昇格）

- 該当なし

## Changelog

- ACE-72-2 を蒸留昇格
EOF
run_gate
if [[ "$GATE_RC" -ne 0 ]] && [[ "$GATE_OUTPUT" == *"ACE-72-2"* ]]; then
  ok "Changelog だけの昇格言及を収載と誤判定しない"
else
  bad "promote Changelog-only mutation を拒否できない（rc=${GATE_RC}）"
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
