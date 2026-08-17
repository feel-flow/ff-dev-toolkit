#!/usr/bin/env bash
#
# docs-template-frontmatter/verify.sh 自身の検出力検証（Issue #509）。
#
# fixture を mktemp に組み立て、FF_DOCS_TEMPLATE_ROOT で本体を駆動して以下を実測する:
#   G1. 実リポジトリの docs-template をそのまま写した baseline が緑
#   G2. 1 ファイルの Frontmatter を丸ごと除去 → 赤
#   G3. 必須フィールド（owner）を 1 つ除去 → 赤
#   G4. version を SemVer 以外（"1.0"）へ → 赤
#   G5. status を値域外（"published"）へ → 赤
#   G6. changeImpact を大文字（"LOW"）へ → 赤
#   G7. `## Changelog` 見出しを除去 → 赤
#   G8. 初期セットの 1 ファイルを削除 → 赤
#   G9. SKILL.md のツリーにだけ新ファイルを追記（suite 一覧は未更新） → 赤（drift 検出）
#   G10. Frontmatter の閉じ `---` を除去 → 赤
#   G11. SKILL.md のツリーから .md 名を抽出できない書式破損 → 赤（fail-closed）
#
# 変異はすべて ASCII 行への perl / ファイル操作で行う（多バイト文字クラス不使用）。
# 書き込み不可の環境（read-only チェックアウト等）では skip して成功扱いにする。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
TARGET="$TESTS_DIR/docs-template-frontmatter/verify.sh"

[ -f "$TARGET" ] || { echo "✗ docs-template-frontmatter/verify.sh が見つかりません: $TARGET" >&2; exit 1; }

command -v perl >/dev/null 2>&1 || {
  echo "○ skip: perl が無い環境のためスキップ（変異注入に必要）"
  exit 0
}

# mktemp の stderr を捨てない（read-only 以外の失敗まで skip に誤帰属させない）。
if _ff_mktemp_out="$(mktemp -d 2>&1)"; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できない環境（read-only）のためスキップ"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  exit 0
fi
# 途中死を沈黙させない（rc=0 なのに最後まで到達していない場合を中断として扱う）。
FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$TMP"
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ selftest が末尾に到達せず終了しました（中断を緑にしない）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# 初期セット 20 ファイル（本体 suite と同一の一覧）
INITIAL_SET=(
  "MASTER.md"
  "01-context/PROJECT.md"
  "01-context/CONSTRAINTS.md"
  "02-design/ARCHITECTURE.md"
  "02-design/DOMAIN.md"
  "02-design/API.md"
  "02-design/DATABASE.md"
  "03-implementation/PATTERNS.md"
  "03-implementation/CONVENTIONS.md"
  "03-implementation/INTEGRATIONS.md"
  "03-implementation/DECISION_TREE.md"
  "03-implementation/FALLBACK.md"
  "04-quality/TESTING.md"
  "04-quality/VALIDATION.md"
  "05-operations/DEPLOYMENT.md"
  "06-reference/GLOSSARY.md"
  "06-reference/DECISIONS.md"
  "07-project-management/ROADMAP.md"
  "07-project-management/TASKS.md"
  "07-project-management/RISKS.md"
)

# fixture を（再）構築する。実リポジトリの初期セット 20 件と init-docs SKILL.md を
# そのまま写す（baseline が実体と乖離しない）。
make_fixture() {
  rm -rf "$TMP/root"
  mkdir -p "$TMP/root/skills/init-docs"
  local rel dir
  for rel in "${INITIAL_SET[@]}"; do
    dir="$(dirname "$rel")"
    mkdir -p "$TMP/root/docs-template/$dir"
    cp "$PLUGIN_ROOT/docs-template/$rel" "$TMP/root/docs-template/$rel"
  done
  cp "$PLUGIN_ROOT/skills/init-docs/SKILL.md" "$TMP/root/skills/init-docs/SKILL.md"
}

# $1=ケース名 $2=期待（green / red）。本体 suite を fixture で駆動して照合する。
run_case() {
  local name="$1" expect="$2" rc=0
  FF_DOCS_TEMPLATE_ROOT="$TMP/root" bash "$TARGET" > "$TMP/out.log" 2>&1 || rc=$?
  if [ "$expect" = "green" ]; then
    if [ "$rc" -eq 0 ]; then
      ok "$name: 緑（期待どおり）"
    else
      bad "$name: 緑を期待しましたが rc=${rc} で赤でした"
      sed 's/^/    /' "$TMP/out.log" | tail -10 >&2
    fi
  else
    if [ "$rc" -ne 0 ]; then
      ok "$name: 赤（期待どおり）"
    else
      bad "$name: 赤を期待しましたが緑のまま通りました（検出力なし）"
      sed 's/^/    /' "$TMP/out.log" | tail -10 >&2
    fi
  fi
}

echo "== G1. baseline =="
make_fixture
run_case "G1 実体を写した baseline" green

echo "== G2. Frontmatter 丸ごと除去 =="
make_fixture
close_line="$(awk 'NR > 1 && /^---$/ { print NR; exit }' "$TMP/root/docs-template/02-design/API.md")"
perl -i -ne 'print if $. > '"$close_line" "$TMP/root/docs-template/02-design/API.md"
run_case "G2 API.md の Frontmatter 除去" red

echo "== G3. 必須フィールド除去 =="
make_fixture
perl -i -ne 'print unless /^owner: /' "$TMP/root/docs-template/06-reference/GLOSSARY.md"
run_case "G3 GLOSSARY.md の owner 除去" red

echo "== G4. version 非 SemVer =="
make_fixture
perl -i -pe 's/^version: ".*"$/version: "1.0"/' "$TMP/root/docs-template/07-project-management/RISKS.md"
run_case "G4 RISKS.md の version を 1.0 へ" red

echo "== G5. status 値域外 =="
make_fixture
perl -i -pe 's/^status: ".*"$/status: "published"/' "$TMP/root/docs-template/01-context/CONSTRAINTS.md"
run_case "G5 CONSTRAINTS.md の status を published へ" red

echo "== G6. changeImpact 大文字 =="
make_fixture
perl -i -pe 's/^changeImpact: ".*"$/changeImpact: "LOW"/' "$TMP/root/docs-template/MASTER.md"
run_case "G6 MASTER.md の changeImpact を LOW へ" red

echo "== G7. Changelog 見出し除去 =="
make_fixture
perl -i -pe 's/^## Changelog$/## History/' "$TMP/root/docs-template/04-quality/VALIDATION.md"
run_case "G7 VALIDATION.md の ## Changelog 除去" red

echo "== G8. ファイル削除 =="
make_fixture
rm "$TMP/root/docs-template/03-implementation/CONVENTIONS.md"
run_case "G8 CONVENTIONS.md 削除" red

echo "== G9. SKILL.md ツリーだけに新ファイル追記（drift） =="
make_fixture
# ツリーのフェンス内の MASTER.md 行の直後に ASCII のみの新規行を足す
awk '
  { print }
  /MASTER\.md/ && !done { print "|-- NEWDOC.md"; done = 1 }
' "$TMP/root/skills/init-docs/SKILL.md" > "$TMP/skill.tmp"
mv "$TMP/skill.tmp" "$TMP/root/skills/init-docs/SKILL.md"
run_case "G9 SKILL.md ツリーへ NEWDOC.md 追記" red

echo "== G10. Frontmatter 未閉鎖 =="
make_fixture
close_line="$(awk 'NR > 1 && /^---$/ { print NR; exit }' "$TMP/root/docs-template/02-design/DATABASE.md")"
perl -i -ne 'print unless $. == '"$close_line" "$TMP/root/docs-template/02-design/DATABASE.md"
run_case "G10 DATABASE.md の閉じ --- 除去" red

echo "== G11. ツリー抽出の空振り（fail-closed） =="
make_fixture
# ステップ2 のフェンスを開始直後に閉じ、ツリー本体を抽出不能にする
awk '
  /^### 2\./ { print; step2 = 1; next }
  step2 && /^```/ && !closed { print "```"; print "```"; closed = 1; skipping = 1; next }
  skipping && /^```/ { skipping = 0; next }
  skipping { next }
  { print }
' "$TMP/root/skills/init-docs/SKILL.md" > "$TMP/skill.tmp"
mv "$TMP/skill.tmp" "$TMP/root/skills/init-docs/SKILL.md"
run_case "G11 ツリー抽出 0 件" red

echo ""
echo "結果: pass=${PASS} fail=${FAIL}"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
if [ "$PASS" -eq 0 ]; then
  echo "✗ 検査が 1 件も成立していません" >&2
  exit 1
fi
echo "✅ docs-template-frontmatter-selftest: all checks passed"
FF_REACHED_END=1
