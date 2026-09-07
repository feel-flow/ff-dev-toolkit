#!/usr/bin/env bash
#
# repository root の live ACE Playbook に、形式・frontmatter・archive リンク/アンカー・
# refine 結果不変条件・カテゴリ件数のゲートを適用する。
#
# 件数ゲート（check-category-size）は Issue #869 で追加した。それまで本 suite は
# 共有 import のために transpile だけして**実行していなかった**ため、ブロック上限の
# 超過が run-all に一度も現れず、唯一の発火点が `/ace-curate` の手動実行だった
# （= 無関係な PR のワークフロー末尾で初めて赤くなる）。ADR-033 決定 4 は本 suite が
# 既に実行している前提で「発火機構は新設しない」と書いていたので、その前提を実装側で
# 満たす（ADR-041 決定 2）。
# docs-template の fixture だけが緑でも live docs の drift は守れないため、run-all から
# 実際の docs/08-knowledge/ を読み取る（Issue #441 / #492）。
#
# run-all-required: no — live docs 不在は正当な適用外。ゲートの検出力は live-ace-gates-selftest が必須名簿側で担保する

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
KNOWLEDGE_DIR="$REPO_ROOT/docs/08-knowledge"
PLAYBOOK="$KNOWLEDGE_DIR/PLAYBOOK.md"
ACE_SCRIPTS="$REPO_ROOT/scripts/ace"
ESBUILD_BIN="$PLUGIN_ROOT/mcp/node_modules/.bin/esbuild"

# 公開配布物など live docs 自体を含まない checkout では適用対象外。run-all はこの
# 明示 marker を pass と数えず skip として可視化する。
if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
  echo "○ skip: docs/08-knowledge が存在しないため live ACE ゲートは適用対象外です"
  exit 0
fi

# 以下は**実在検査**であってゲートの一覧ではない。entry として起動するのは 5 本
# （check-entry-format / sync-playbook-frontmatter / check-archive-links /
# check-refine-invariants / check-category-size）で、ace-reuse-report と
# ace-refine-report は他スクリプトの共有 import 専用である（どちらも閾値超過で
# 非 0 を返す経路を持たないレポート器なので、実行しないのが正しい）。
# 「リストに載っているから実行されている」という読み方が ADR-033 決定 4 の誤りを生んだ。
for file in \
  "$PLAYBOOK" \
  "$ACE_SCRIPTS/check-category-size.ts" \
  "$ACE_SCRIPTS/ace-domain.ts" \
  "$ACE_SCRIPTS/check-entry-format.ts" \
  "$ACE_SCRIPTS/sync-playbook-frontmatter.ts" \
  "$ACE_SCRIPTS/check-archive-links.ts" \
  "$ACE_SCRIPTS/check-refine-invariants.ts" \
  "$ACE_SCRIPTS/ace-reuse-report.ts" \
  "$ACE_SCRIPTS/ace-refine-report.ts"; do
  if [[ ! -s "$file" ]]; then
    echo "✗ live ACE ゲートの検査対象が存在しないか空です: $file" >&2
    exit 1
  fi
done

if ! command -v node >/dev/null 2>&1; then
  echo "✗ docs/08-knowledge は存在しますが、live ACE ゲートに必要な node がありません" >&2
  exit 1
fi
if [[ ! -x "$ESBUILD_BIN" ]]; then
  echo "✗ docs/08-knowledge は存在しますが、live ACE ゲートに必要な esbuild がありません: $ESBUILD_BIN" >&2
  echo "  plugins/ff-dev-toolkit/mcp で npm ci を実行してください" >&2
  exit 1
fi

# mktemp の診断を捨てると不正 TMPDIR と read-only を区別できないため、成功時のパスと
# 失敗時の理由を同じ変数へ受ける。
# rc=0 でも -d を検査する — 2>&1 の合流は「成功 + stderr 警告」の環境で変数へ
# 警告文が混入し、以後の処理が原因不明の失敗に化けるため。
if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/live-ace-gates.XXXXXX" 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  BUNDLE_DIR="$_ff_mktemp_out"
else
  echo "✗ docs/08-knowledge は存在しますが、一時ディレクトリを作成できず live ACE ゲートを実行できません" >&2
  printf '  mktemp: %s\n' "$_ff_mktemp_out" >&2
  exit 1
fi
cleanup() {
  local rc=$?
  rm -rf "$BUNDLE_DIR"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
BUNDLE_REAL="$(cd "$BUNDLE_DIR" && pwd -P)"

# tsx をネットワーク取得せず、同梱 esbuild で TypeScript を ESM へ変換する。
# bundle すると依存側の import.meta.url も entry CLI の URL になり、依存モジュールの
# direct-execution 判定が誤発火するため、ファイルを別々に出力する。既存 import の
# extensionless / `.js` 両方を満たすよう共有モジュールだけ 2 名で配置する。
printf '{"type":"module"}\n' >"$BUNDLE_DIR/package.json"
transpile_shared() {
  local src="$1"
  local dest="$BUNDLE_DIR/$(basename "$src" .ts)"
  "$ESBUILD_BIN" "$src" --platform=node --format=esm --log-level=error --outfile="$dest"
  cp "$dest" "$dest.js"
}
transpile_shared "$ACE_SCRIPTS/check-category-size.ts"
transpile_shared "$ACE_SCRIPTS/ace-domain.ts"
transpile_shared "$ACE_SCRIPTS/ace-reuse-report.ts"
transpile_shared "$ACE_SCRIPTS/ace-refine-report.ts"
transpile_shared "$ACE_SCRIPTS/check-archive-links.ts"
"$ESBUILD_BIN" "$ACE_SCRIPTS/check-entry-format.ts" \
  --platform=node --format=esm --log-level=error \
  --outfile="$BUNDLE_DIR/check-entry-format.mjs"
"$ESBUILD_BIN" "$ACE_SCRIPTS/sync-playbook-frontmatter.ts" \
  --platform=node --format=esm --log-level=error \
  --outfile="$BUNDLE_DIR/sync-playbook-frontmatter.mjs"
"$ESBUILD_BIN" "$ACE_SCRIPTS/check-refine-invariants.ts" \
  --platform=node --format=esm --log-level=error \
  --outfile="$BUNDLE_DIR/check-refine-invariants.mjs"

echo "== live ACE entry format =="
node "$BUNDLE_REAL/check-entry-format.mjs" "$PLAYBOOK"
echo "✓ live ACE の新規旧形式エントリは 0 件"

echo
echo "== live ACE frontmatter sync =="
node "$BUNDLE_REAL/sync-playbook-frontmatter.mjs" "$PLAYBOOK" --check
echo "✓ live ACE の entry count / version / changeImpact は同期済み"

echo
echo "== live ACE archive links / anchors =="
node "$BUNDLE_REAL/check-archive-links" "$PLAYBOOK"
echo "✓ live ACE の archive リンク注記と <a id> 一意性"

echo
echo "== live ACE refine invariants =="
node "$BUNDLE_REAL/check-refine-invariants.mjs" "$PLAYBOOK"
echo "✓ live ACE の refine 結果不変条件"

echo
echo "== live ACE category size =="
# 共有モジュールとして transpile 済みの extensionless 版をそのまま entry にする
# （check-archive-links と同じ形）。entry として起動したときだけ direct-execution
# guard が main() を回すので、import 経路の判定は変わらない。
node "$BUNDLE_REAL/check-category-size" "$PLAYBOOK"
echo "✓ live ACE のカテゴリ件数はブロック上限内"
