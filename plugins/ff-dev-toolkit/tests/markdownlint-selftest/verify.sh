#!/usr/bin/env bash
#
# repository Markdown lint が新規違反を非 0・ファイル名付きで検出することを隔離 fixture で固定する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd -P)"
SOURCE_VERIFY="$PLUGIN_ROOT/tests/markdownlint/verify.sh"
SOURCE_CONFIG="$REPO_ROOT/.markdownlint.json"
SOURCE_PACKAGE_JSON="$PLUGIN_ROOT/mcp/package.json"
SOURCE_PACKAGE_LOCK="$PLUGIN_ROOT/mcp/package-lock.json"
SOURCE_NODE_MODULES="$PLUGIN_ROOT/mcp/node_modules"

if [[ ! -d "$SOURCE_NODE_MODULES" ]]; then
  echo "○ skip: $SOURCE_NODE_MODULES が無いため markdownlint mutation self-test をスキップ（cd plugins/ff-dev-toolkit/mcp && npm ci で有効化）"
  exit 0
fi
[[ -x "$SOURCE_NODE_MODULES/.bin/markdownlint-cli2" ]] || {
  echo "✗ node_modules はあるが markdownlint-cli2 がありません（npm ci が不完全）" >&2
  exit 1
}

if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/markdownlint-selftest.XXXXXX" 2>&1)"; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できないため markdownlint mutation self-test をスキップ（検査は1件も実行されていません）"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  exit 0
fi
FF_REACHED_END=0
cleanup() {
  local rc=$?
  rm -rf "$TMP"
  if [[ "$FF_REACHED_END" -ne 1 ]]; then
    echo "✗ repository Markdown lint self-test: スイートが最後まで到達しませんでした" >&2
    exit 1
  fi
  exit "$rc"
}
trap cleanup EXIT
FIXTURE="$TMP/repo"
mkdir -p "$FIXTURE/plugins/ff-dev-toolkit/tests/markdownlint" "$FIXTURE/plugins/ff-dev-toolkit/mcp"
cp "$SOURCE_VERIFY" "$FIXTURE/plugins/ff-dev-toolkit/tests/markdownlint/verify.sh"
cp "$SOURCE_CONFIG" "$FIXTURE/.markdownlint.json"
cp "$SOURCE_PACKAGE_JSON" "$FIXTURE/plugins/ff-dev-toolkit/mcp/package.json"
cp "$SOURCE_PACKAGE_LOCK" "$FIXTURE/plugins/ff-dev-toolkit/mcp/package-lock.json"
ln -s "$SOURCE_NODE_MODULES" "$FIXTURE/plugins/ff-dev-toolkit/mcp/node_modules"

git -C "$FIXTURE" init -q
git -C "$FIXTURE" config user.email selftest@example.com
git -C "$FIXTURE" config user.name markdownlint-selftest
printf '# Fixture\n' > "$FIXTURE/README.md"
git -C "$FIXTURE" add .
git -C "$FIXTURE" commit -qm baseline

baseline_output="$(bash "$FIXTURE/plugins/ff-dev-toolkit/tests/markdownlint/verify.sh" 2>&1)" || {
  echo "✗ 健全な fixture が失敗しました:" >&2
  printf '%s\n' "$baseline_output" >&2
  exit 1
}
case "$baseline_output" in
  *"tracked 1 files / 0 errors"*) echo "  ✓ 健全な fixture は 1 file / 0 errors" ;;
  *) echo "✗ baseline の件数契約がありません" >&2; printf '%s\n' "$baseline_output" >&2; exit 1 ;;
esac

printf '# Fixture \n' > "$FIXTURE/markdownlint-poison.md"
git -C "$FIXTURE" add markdownlint-poison.md
set +e
poison_output="$(bash "$FIXTURE/plugins/ff-dev-toolkit/tests/markdownlint/verify.sh" 2>&1)"
poison_rc=$?
set -e
[[ "$poison_rc" -ne 0 ]] || {
  echo "✗ Markdown 違反が exit 0 で素通りしました" >&2
  printf '%s\n' "$poison_output" >&2
  exit 1
}
echo "  ✓ Markdown 違反は非 0 終了"
case "$poison_output" in
  *"markdownlint-poison.md:1"*) echo "  ✓ 違反ファイルと行を名指し" ;;
  *) echo "✗ 違反ファイルの名指しがありません" >&2; printf '%s\n' "$poison_output" >&2; exit 1 ;;
esac
case "$poison_output" in
  *"MD009/no-trailing-spaces"*) echo "  ✓ 違反ルールを名指し" ;;
  *) echo "✗ 違反ルールの名指しがありません" >&2; printf '%s\n' "$poison_output" >&2; exit 1 ;;
esac

FF_REACHED_END=1
echo "✓ repository Markdown lint self-test: 全 4 件 pass"
