#!/usr/bin/env bash
#
# ace-scripts-vitest: docs-template/scripts/ace の vitest スイートを run-all.sh へ配線する。
#
# 背景 (Issue #223): ace スクリプト群（check-category-size / ace-reuse-report /
# sync-playbook-frontmatter / shell-hooks / ace-refine-report）の vitest は
# 手動実行でしか走らず、run-all.sh の suite から呼ばれていなかった（Issue #217 で
# MCP に対して塞いだのと同型の穴）。コンパクト正準フォーマットのパース互換や
# playbook/archive/ の集計除外はこれらのテストが唯一のロックであり、未配線のままだと
# 回帰が「誰かが手で叩くまで」隠れる。
#
# vitest 本体は mcp/node_modules のものを再利用する（docs-template はテンプレート
# 配布物なので自前の node_modules を持たない）。node_modules が無い環境では
# run-all.sh の契約どおり行頭 `○ skip` を出して exit 0 する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MCP_DIR="$PLUGIN_ROOT/mcp"
ACE_SCRIPTS_DIR="$PLUGIN_ROOT/docs-template/scripts/ace"

[ -d "$ACE_SCRIPTS_DIR" ] || {
  echo "✗ ace スクリプトディレクトリが見つかりません: $ACE_SCRIPTS_DIR" >&2
  exit 1
}

if [[ ! -d "$MCP_DIR/node_modules" ]]; then
  echo "○ skip: $MCP_DIR/node_modules が無いためスキップ（本 suite の検査は1件も実行されていません。cd mcp && npm install で有効化）"
  exit 0
fi
if [[ ! -x "$MCP_DIR/node_modules/.bin/vitest" ]]; then
  echo "✗ node_modules はあるが vitest が無い（npm install が不完全）: $MCP_DIR/node_modules/.bin/vitest" >&2
  exit 1
fi

# 一時領域が書き込み不可の環境では vitest 自体が一時ディレクトリ作成で落ちる
# （検証本体を環境都合で実行できない）ため、契約どおり丸ごと skip する。
# mktemp の stderr を捨てない。捨てると read-only 以外の失敗（TMPDIR が不正な
# パス・quota 超過など）まで「書き込み可能な環境で再実行してください」に
# 誤帰属し、恒常的に壊れた TMPDIR が suite を exit 0 で無効化し続ける。
# 2>&1 で受けると、成功時はパス・失敗時は理由が同じ変数に入る。
if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/ace-scripts-vitest.XXXXXX" 2>&1)"; then
  PROBE_DIR="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できないためスキップ（本 suite の検査は1件も実行されていません。書き込み可能な環境で再実行してください）"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  exit 0
fi
rm -rf "$PROBE_DIR"

# 出力は丸ごと受けてから判定する（vitest の exit code に加えて、成功サマリー行の
# 実在も確認する fail-closed。exit 0 + 0 tests のような縮退を green にしない）。
set +e
OUTPUT="$(cd "$MCP_DIR" && ./node_modules/.bin/vitest run --dir "$ACE_SCRIPTS_DIR" 2>&1)"
RC=$?
set -e

SUMMARY="$(printf '%s\n' "$OUTPUT" | grep -E '^[[:space:]]*Tests[[:space:]]' || true)"

if [[ $RC -ne 0 ]]; then
  printf '%s\n' "$OUTPUT"
  echo "✗ ace-scripts vitest が失敗しました（rc=${RC}）" >&2
  exit 1
fi
# 判定はシェル内の文字列マッチで行い、パイプを使わない（`printf | grep -q` は
# grep の早期終了で printf が SIGPIPE 死し、pipefail の下で判定が反転する）。
if [[ -z "$SUMMARY" || "$SUMMARY" != *passed* ]]; then
  printf '%s\n' "$OUTPUT"
  echo "✗ vitest は exit 0 だが成功サマリー（Tests ... passed）を確認できません" >&2
  exit 1
fi

printf '%s\n' "$SUMMARY" | sed 's/^[[:space:]]*/  ✓ /'
echo "✓ ace-scripts vitest: pass"
