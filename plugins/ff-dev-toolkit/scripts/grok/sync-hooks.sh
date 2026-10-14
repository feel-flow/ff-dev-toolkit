#!/usr/bin/env bash
# grok CLI 向けに ff-dev-toolkit の hooks/hooks.json を global hook ファイルへ展開する（Issue `#2116`）。
#
# grok は plugin の hooks を `event: "(plugin)"` として認識するだけで発火させない。一方
# `${GROK_HOME:-~/.grok}/hooks/*.json`（Claude 互換の matcher 形式）は常に読み込んで発火する。
# 本スクリプトは hooks.json を写し、
#   - 各 handler の command 先頭に hook-shim.sh（tool_name 正規化）を挟み、
#   - handler の env に CLAUDE_PLUGIN_ROOT（plugin の実パス）を足して
# `<GROK_HOME>/hooks/ff-dev-toolkit.json` へ書く。command 中の `${CLAUDE_PLUGIN_ROOT}` は
# 実パスへ書き換えず、実行時に env から展開させる（実パスに `$` などシェルの特殊文字が
# 含まれても、command がシェル構文として再解釈されない）。plugin を更新したら再実行する
# （書き込むのは実パスなので、旧版のディレクトリが消えると hook が失敗する）。
#
# 使い方: sync-hooks.sh [--plugin-root <dir>] [--out <file>] [--check]
#   --plugin-root  既定はこのスクリプトの 2 階層上（同梱位置）
#   --out          既定は ${GROK_HOME:-$HOME/.grok}/hooks/ff-dev-toolkit.json
#   --check        書かずに、出力が最新なら 0・差分があれば 1 で終わる
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT="${GROK_HOME:-$HOME/.grok}/hooks/ff-dev-toolkit.json"
CHECK=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --plugin-root) PLUGIN_ROOT="${2:?--plugin-root に値が要ります}"; shift 2 ;;
    --out) OUT="${2:?--out に値が要ります}"; shift 2 ;;
    --check) CHECK=1; shift ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "✗ 不明な引数: $1" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "✗ jq が必要です" >&2; exit 1; }
PLUGIN_ROOT="$(cd "$PLUGIN_ROOT" 2>/dev/null && pwd)" || { echo "✗ plugin root が見つかりません" >&2; exit 1; }
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"
SHIM="$PLUGIN_ROOT/scripts/grok/hook-shim.sh"
[ -f "$HOOKS_JSON" ] || { echo "✗ hooks.json が見つかりません: $HOOKS_JSON" >&2; exit 1; }
[ -f "$SHIM" ] || { echo "✗ hook-shim.sh が見つかりません: $SHIM" >&2; exit 1; }

rendered="$(jq --arg root "$PLUGIN_ROOT" --arg shim "$SHIM" '
  .hooks |= with_entries(.value |= map(
    .hooks |= map(
      if .type == "command" and (.command | type) == "string" then
        .command = ("bash " + ($shim | @sh) + " " + .command)
        | .env = (.env // {}) + {"CLAUDE_PLUGIN_ROOT": $root}
      else . end)))
  | {hooks: .hooks}
' "$HOOKS_JSON")" || { echo "✗ hooks.json を展開できません: $HOOKS_JSON" >&2; exit 1; }

if [ "$CHECK" -eq 1 ]; then
  if [ -f "$OUT" ] && [ "$(jq -S . "$OUT" 2>/dev/null)" = "$(printf '%s' "$rendered" | jq -S .)" ]; then
    echo "✓ 最新: $OUT"; exit 0
  fi
  echo "✗ 未同期: ${OUT}（bash ${0} を実行してください）" >&2; exit 1
fi

mkdir -p "$(dirname "$OUT")"
tmp="$(mktemp "$OUT.XXXXXX")"
printf '%s\n' "$rendered" > "$tmp"
mv "$tmp" "$OUT"
echo "✓ 書き込み: $OUT"
echo "  plugin root: $PLUGIN_ROOT"
echo "  events: $(printf '%s' "$rendered" | jq -r '.hooks | keys | join(", ")')"
