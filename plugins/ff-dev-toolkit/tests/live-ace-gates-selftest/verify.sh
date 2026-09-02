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
# 閾値つまみは利用者の正規の設定なので、export された環境でこの suite を走らせるのは
# 正しい使い方である。既定配線を測るケースが呼び出し元の値に乗ると、実装の退行が無くても
# 赤くなる（ACE-379-1: 「env 未設定」を前提にする suite は前提を仮定せず `env -u` で**作る**）。
# `env` は `-u` 除去を先に・`NAME=VALUE` 代入を後に適用するので、ケース固有の上書きと共存する。
ACE_ENV_UNSET=(
  -u ACE_MAX_ENTRIES_PER_CATEGORY
  -u ACE_WARN_ENTRIES_PER_CATEGORY
  -u ACE_MAX_ENTRY_LINES
  -u ACE_MAX_PLAYBOOK_LINES
)
run_gate() {
  set +e
  GATE_OUTPUT="$(env "${ACE_ENV_UNSET[@]}" bash "$FIXTURE_PLUGIN/tests/live-ace-gates/verify.sh" 2>&1)"
  GATE_RC=$?
  set -e
}

echo "== live-ace-gates self-test =="

run_gate
if [[ "$GATE_RC" -eq 0 ]] && [[ "$GATE_OUTPUT" == *"live ACE の新規旧形式エントリは 0 件"* ]] && [[ "$GATE_OUTPUT" == *"live ACE の entry count / version / changeImpact は同期済み"* ]] && [[ "$GATE_OUTPUT" == *"live ACE の archive リンク注記と <a id> 一意性"* ]] && [[ "$GATE_OUTPUT" == *"live ACE の refine 結果不変条件"* ]] && [[ "$GATE_OUTPUT" == *"live ACE のカテゴリ件数はブロック上限内"* ]]; then
  ok "正常 fixture で形式・frontmatter・archive・refine・件数の各ゲートが通る"
else
  bad "正常 fixture が通らない（rc=${GATE_RC}）"
  printf '%s\n' "$GATE_OUTPUT" >&2
fi

# Issue #869: 件数ゲートは長らく transpile されるだけで実行されておらず、ブロック上限の
# 超過が run-all に現れなかった。成功マーカーの追加だけでは「実行されている」ことしか
# 示せない（rc を握り潰す配線でも緑のまま）ので、**赤に振れること**を対で測る。
# 上限を env で 1 へ落とせば fixture を肥大させずに境界を越えられる。
# **検出力はこの赤ケースだけに乗っている。** 成功マーカー `✓ live ACE のカテゴリ件数は…`
# は node 起動とは別の echo なので、実行行を消しても正常系アサートと対照は緑のまま通る。
# 「3 つとも同じマーカーを見ているから 1 つに畳める」と読んで赤ケースを外すと、本 PR が
# 足した検出力が丸ごと消える。
run_gate_max_one() {
  set +e
  GATE_OUTPUT="$(env "${ACE_ENV_UNSET[@]}" ACE_MAX_ENTRIES_PER_CATEGORY=1 bash "$FIXTURE_PLUGIN/tests/live-ace-gates/verify.sh" 2>&1)"
  GATE_RC=$?
  set -e
}

cp "$FIXTURE_ROOT/baseline-playbook.md" "$FIXTURE_PLAYBOOK"
cat >>"$FIXTURE_PLAYBOOK" <<'EOF'

### ACE-900-3: 件数ゲート用の 2 件目

| Category | process | Origin | fixture |
| Date | 2026-08-12 |
| Helpful | 0 | Harmful | 0 |
| Status | active |

正準形式の本文。
EOF
perl -0pi -e 's/ace_entry_count: 1/ace_entry_count: 2/' "$FIXTURE_PLAYBOOK"
if ! grep -q '^### ACE-900-3:' "$FIXTURE_PLAYBOOK"; then
  bad "件数ゲート用の 2 件目を注入できていない（検査が成立しない）"
else
  # 「変化はあるが正しい」対照を先に置く。既定上限のままなら 2 件は超過ではないので
  # 緑であるべきで、これが赤いと以降の赤は閾値ではなく別の理由（形式・frontmatter）に
  # なる（ACE-725-1）。
  run_gate
  if [[ "$GATE_RC" -eq 0 ]] && [[ "$GATE_OUTPUT" == *"live ACE のカテゴリ件数はブロック上限内"* ]]; then
    ok "既定上限では 2 件の fixture が件数ゲートを通る（対照）"
  else
    bad "対照が緑にならない（rc=${GATE_RC}）"
    printf '%s\n' "$GATE_OUTPUT" >&2
  fi

  run_gate_max_one
  if [[ "$GATE_RC" -ne 0 ]] && [[ "$GATE_OUTPUT" == *"閾値超過カテゴリ"* ]] && [[ "$GATE_OUTPUT" == *"process (2 > 1)"* ]]; then
    ok "ブロック上限の超過を suite の rc へ伝播する（件数ゲートが実行されている証跡）"
  else
    bad "ブロック上限の超過が suite を赤にしない（rc=${GATE_RC}）"
    printf '%s\n' "$GATE_OUTPUT" >&2
  fi
fi
cp "$FIXTURE_ROOT/baseline-playbook.md" "$FIXTURE_PLAYBOOK"

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

# Issue #615: `## Changelog` セクションごと消すと version 検証が素通りしていた
# fail-open を、統合層（実ゲート経由）でも固定する。unit test だけだと、CLI の
# 配線を外しても赤くならない。
cp "$FIXTURE_ROOT/baseline-playbook.md" "$FIXTURE_PLAYBOOK"
perl -0pi -e 's/\n## Changelog\n.*\z//s' "$FIXTURE_PLAYBOOK"
if grep -q '^## Changelog' "$FIXTURE_PLAYBOOK"; then
  bad "Changelog 削除 mutation が適用できていない（検査が成立しない）"
else
  run_gate
  if [[ "$GATE_RC" -ne 0 ]] && [[ "$GATE_OUTPUT" == *"\`## Changelog\` セクションがありません"* ]]; then
    ok "## Changelog セクションの消失を専用診断付きで拒否する"
  else
    bad "Changelog 消失 mutation を拒否できない（rc=${GATE_RC}）"
    printf '%s\n' "$GATE_OUTPUT" >&2
  fi
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

# Issue #1031: #1028 が足した archive 分岐（compact 済み → 後日 archive / 統合先が後日
# archive され着地が archive 内へ移る chain）は、live PLAYBOOK に該当形状が 0 件のあいだ
# e2e で一度も実行されない。実データ（docs/08-knowledge/playbook/archive/*.md）の形状 —
# append 型 archive で、保全済み ID には原文を再コピーせず provenance 行だけを重ねる並び
# （ace-refine SKILL.md R3-0 の「1 件（保全済み）」分岐）— を写した fixture をここに置く。
write_archive_chain_fixture() {
  local knowledge="$FIXTURE_KNOWLEDGE"
  mkdir -p "$knowledge/playbook/archive"
  cat >"$FIXTURE_PLAYBOOK" <<'EOF'
---
title: "PLAYBOOK"
version: "1.1.0"
status: "draft"
owner: "@fixture"
created: "2026-08-12"
updated: "2026-08-30"
changeImpact: low
ace_entry_count: 2
---

# ACE Playbook

## エントリ一覧

| エントリID | タイトル | Category | 参照先 |
| ---------- | -------- | -------- | ------ |
| ACE-501-1  | live 残存 | process | [playbook/process.md#ace-501-1](./playbook/process.md#ace-501-1) |
| ACE-502-1  | live 残存 | testing | [playbook/testing.md#ace-502-1](./playbook/testing.md#ace-502-1) |

## Changelog

### [1.1.0] - 2026-08-30

#### 整理（/ace-refine）

- Archived: ACE-500-1（原文は 2026-08-14 の圧縮で保全済み）
- Archived: ACE-404-2（30日以上参照なし）

### [1.0.0] - 2026-08-14

#### 整理（/ace-refine）

- Compacted: ACE-500-1
- Merged: ACE-430-1 → ACE-404-2
EOF
  cat >"$knowledge/playbook/process.md" <<'EOF'
### ACE-501-1: live 残存

| Category | process | Origin | PR #501 |
| Date | 2026-08-12 |
| Helpful | 0 | Harmful | 0 |
| Status | active |

archive 分岐の対照として live に残すエントリ。
EOF
  cat >"$knowledge/playbook/testing.md" <<'EOF'
### ACE-502-1: live 残存

| Category | testing | Origin | PR #502 |
| Date | 2026-08-12 |
| Helpful | 0 | Harmful | 0 |
| Status | active |

archive 分岐の対照として live に残すエントリ。
EOF
  cat >"$knowledge/playbook/archive/process.md" <<'EOF'
# PLAYBOOK Archive — process (process)

> **Parent**: [PLAYBOOK.md](../../PLAYBOOK.md) — 保管場所。
> **保全本文内の相対リンクは live 基準**: 読み替え。

---

<a id="ace-500-1"></a>

### ACE-500-1: 圧縮後に stale となったエントリ

> Compacted: 2026-08-14（live 側を要約済み。本文の原文は本エントリが正）
> Archived: 2026-08-30 / 理由: 30日以上参照なし（原文は 2026-08-14 の圧縮で保全済み。/ace-refine）

| Category | process | Origin | PR #500 |
| Date | 2026-07-07 |
| Helpful | 0 | Harmful | 0 |
| Status | active |

圧縮で live に要約を置いたあと、後日 stale として live 側を撤去した原文。

---
EOF
  cat >"$knowledge/playbook/archive/testing.md" <<'EOF'
# PLAYBOOK Archive — testing (testing)

> **Parent**: [PLAYBOOK.md](../../PLAYBOOK.md) — 保管場所。
> **保全本文内の相対リンクは live 基準**: 読み替え。

---

<a id="ace-430-1"></a>

### ACE-430-1: trap source

> Merged into: [ACE-404-2](#ace-404-2)（2026-08-14 /ace-refine。統合先の後日アーカイブに伴い着地を archive 内へ付け替え）

| Category | testing | Origin | PR #430 |
| Date | 2026-08-12 |
| Helpful | 1 | Harmful | 0 |
| Status | merged |

トラップ最終コマンドの成功が rc を上書きする。

---

<a id="ace-404-2"></a>

### ACE-404-2: trap

> Archived: 2026-08-30 / 理由: 30日以上参照なし（/ace-refine）

| Category | testing | Origin | PR #404 |
| Date | 2026-08-12 |
| Helpful | 1 | Harmful | 0 |
| Status | active |

終了ステータスの保存では直らない。

---
EOF
}

echo
echo "== archive chain（compact 済み → 後日 archive / 統合先の後日 archive）=="

write_archive_chain_fixture
run_gate
if [[ "$GATE_RC" -eq 0 ]] && [[ "$GATE_OUTPUT" == *"live ACE の refine 結果不変条件"* ]] && [[ "$GATE_OUTPUT" == *"Archived 2"* ]]; then
  ok "compact 済み → 後日 archive と、着地が archive 内へ移った merge chain が通る"
else
  bad "archive chain fixture が通らない（rc=${GATE_RC}）"
  printf '%s\n' "$GATE_OUTPUT" >&2
fi

# Changelog の `- Archived:` は compact の live 存続要求を**解除する**記録なので、これを
# 消すと「記録なき消失」に戻って赤くなるべき。緑のままなら解除が無条件に効いている。
write_archive_chain_fixture
perl -0pi -e 's/^- Archived: ACE-500-1[^\n]*\n//m' "$FIXTURE_PLAYBOOK"
if grep -q '^- Archived: ACE-500-1' "$FIXTURE_PLAYBOOK"; then
  bad "Archived 行の削除 mutation が適用できていない（検査が成立しない）"
else
  run_gate
  if [[ "$GATE_RC" -ne 0 ]] && [[ "$GATE_OUTPUT" == *"ACE-500-1"* ]] && [[ "$GATE_OUTPUT" == *"live に見出しが無い"* ]]; then
    ok "Archived 記録を消すと compact の live 消失が再び赤くなる"
  else
    bad "Archived 行削除 mutation を拒否できない（rc=${GATE_RC}）"
    printf '%s\n' "$GATE_OUTPUT" >&2
  fi
fi

# 統合先が archive へ移った後も `Merged into` が live 基準 `../` を指し続けると chain の
# 着地が消えた anchor になる。形だけ正しい live 向け href が赤くなることを実測する。
write_archive_chain_fixture
perl -0pi -e 's{> Merged into: \[ACE-404-2\]\(#ace-404-2\)}{> Merged into: [ACE-404-2](../testing.md#ace-404-2)}' \
  "$FIXTURE_KNOWLEDGE/playbook/archive/testing.md"
if ! grep -q '](\.\./testing\.md#ace-404-2)' "$FIXTURE_KNOWLEDGE/playbook/archive/testing.md"; then
  bad "Merged into href の live 復帰 mutation が適用できていない（検査が成立しない）"
else
  run_gate
  if [[ "$GATE_RC" -ne 0 ]] && [[ "$GATE_OUTPUT" == *"ACE-430-1 → ACE-404-2"* ]] && [[ "$GATE_OUTPUT" == *"統合先が archive 済み"* ]]; then
    ok "archive 済み統合先への href を live 基準へ戻すと赤くなる"
  else
    bad "Merged into href mutation を拒否できない（rc=${GATE_RC}）"
    printf '%s\n' "$GATE_OUTPUT" >&2
  fi
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
