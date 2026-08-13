#!/usr/bin/env bash
#
# リポジトリ全体の tracked Markdown を、ルートの baseline 設定で検査する。
# 対象集合は git ls-files から導出し、glob の dotfile 差・shell 差で検査範囲が動かないようにする。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd -P)"
CONFIG="$REPO_ROOT/.markdownlint.json"
MARKDOWNLINT="$PLUGIN_ROOT/mcp/node_modules/.bin/markdownlint-cli2"

[[ -f "$CONFIG" ]] || {
  echo "✗ markdownlint 設定が見つかりません: $CONFIG" >&2
  exit 1
}
if [[ ! -d "$PLUGIN_ROOT/mcp/node_modules" ]]; then
  echo "○ skip: $PLUGIN_ROOT/mcp/node_modules が無いため repository Markdown lint をスキップ（cd plugins/ff-dev-toolkit/mcp && npm ci で有効化）"
  exit 0
fi
[[ -x "$MARKDOWNLINT" ]] || {
  echo "✗ node_modules はあるが markdownlint-cli2 がありません（npm ci が不完全）: $MARKDOWNLINT" >&2
  exit 1
}

markdown_files=()
while IFS= read -r -d '' file; do
  markdown_files+=("$file")
done < <(git -C "$REPO_ROOT" ls-files -z -- '*.md')

[[ ${#markdown_files[@]} -gt 0 ]] || {
  echo "✗ tracked Markdown が 0 件のため検査が成立しません" >&2
  exit 1
}

if lint_output="$(cd "$REPO_ROOT" && "$MARKDOWNLINT" --config "$CONFIG" "${markdown_files[@]}" 2>&1)"; then
  :
else
  lint_rc=$?
  printf '%s\n' "$lint_output" >&2
  exit "$lint_rc"
fi
echo "✓ repository Markdown lint: tracked ${#markdown_files[@]} files / 0 errors"
