#!/usr/bin/env bash
#
# mcp-vitest: 同梱 spec-docs MCP サーバーの vitest スイートを run-all.sh へ配線する。
#
# 背景 (Issue #217): MCP の vitest（indexer / utils / server / transport-errors）は
# `npm test` の手動実行でしか走らず、run-all.sh の suite からも CI（存在しない）
# からも呼ばれていなかった。SDK バンプ等の回帰が「誰かが手で叩くまで」隠れる。
#
# 実行は `vitest run` のみで build を含めない（npm test は build で dist/ に書き
# 込むため read-only 契約に反する）。テストはコミット済み dist/index.js を実プロセス
# 起動して検証する — dist が src と一致していることは mcp-dist-gate suite が別途
# 保証するので、この分担で「stale な dist をテストして green」は成立しない。
#
# node_modules が無い環境では検証本体を実行できないため、run-all.sh の契約
# どおり行頭 `○ skip` を出して exit 0 する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MCP_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)/mcp"

if [[ ! -d "$MCP_DIR/node_modules" ]]; then
  echo "○ skip: $MCP_DIR/node_modules が無いためスキップ（本 suite の検査は1件も実行されていません。cd mcp && npm install で有効化）"
  exit 0
fi
if [[ ! -x "$MCP_DIR/node_modules/.bin/vitest" ]]; then
  echo "✗ node_modules はあるが vitest が無い（npm install が不完全）: $MCP_DIR/node_modules/.bin/vitest" >&2
  exit 1
fi
if [[ ! -f "$MCP_DIR/dist/index.js" ]]; then
  echo "✗ コミット済み dist が存在しない（server/transport テストの前提）: $MCP_DIR/dist/index.js" >&2
  exit 1
fi

# 一時領域が書き込み不可の環境では vitest 自体が一時ディレクトリ作成で落ちる
# （検証本体を環境都合で実行できない）ため、契約どおり丸ごと skip する。
# mktemp はテンプレート形式で呼ぶ（BSD/GNU/busybox すべてで有効。`-t <prefix>` は
# GNU では XXXXXX 必須のためエラーになり、移植性バグを環境都合と誤帰属させる）。
if ! PROBE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mcp-vitest.XXXXXX" 2>/dev/null)"; then
  echo "○ skip: 一時ディレクトリを作成できないためスキップ（本 suite の検査は1件も実行されていません。書き込み可能な環境で再実行してください）"
  exit 0
fi
rm -rf "$PROBE_DIR"

# 事後条件の基準線: dist/ の状態を実行前に記録し、実行後は「変化」だけを検査する
# （絶対判定だと開発者の作業中変更を本 suite の書き込みと誤帰属する）。git status の
# 状態分類は dirty なファイルへの上書きを見逃すため、内容ハッシュで比較する。
dist_state() {
  (cd "$MCP_DIR" && find dist -type f 2>/dev/null | LC_ALL=C sort | xargs shasum -a 256 2>/dev/null) || true
}
STATE_BEFORE="$(dist_state)"

# 出力は丸ごと受けてから判定する（vitest の exit code に加えて、成功サマリー行の
# 実在も確認する fail-closed。exit 0 + 0 tests のような縮退を green にしない）。
set +e
OUTPUT="$(cd "$MCP_DIR" && ./node_modules/.bin/vitest run 2>&1)"
RC=$?
set -e

SUMMARY="$(printf '%s\n' "$OUTPUT" | grep -E '^[[:space:]]*Tests[[:space:]]' || true)"

if [[ $RC -ne 0 ]]; then
  echo "✗ mcp vitest が失敗した (exit $RC)" >&2
  # 診断の抽出は awk 1 段で行う（grep|head は pipefail 下で「該当なしの rc=1」や
  # head 早期終了の SIGPIPE により、後続の案内と exit 1 へ到達しなくなる）。
  printf '%s\n' "$OUTPUT" | awk '/×|✗|FAIL|AssertionError|Error:/ { print; if (++n == 20) exit }' >&2 || true
  echo "  再現: cd plugins/ff-dev-toolkit/mcp && npm test" >&2
  exit 1
fi

case "$SUMMARY" in
  *passed*)
    : ;;
  *)
    echo "✗ vitest は exit 0 だが成功サマリー行が見つからない（検査 0 件の縮退を疑う）" >&2
    printf '%s\n' "$OUTPUT" | tail -10 >&2
    exit 1
    ;;
esac
case "$SUMMARY" in
  *failed*)
    echo "✗ vitest サマリーに failed が含まれる: $SUMMARY" >&2
    exit 1
    ;;
esac

# 事後条件: dist/ を書き換えていない（vitest run は build を含まないため
# 本来書き込まない。書き込まれたら構成が変わった合図）。
STATE_AFTER="$(dist_state)"
if [[ "$STATE_AFTER" != "$STATE_BEFORE" ]]; then
  echo "✗ 本 suite の実行が dist/ を書き換えた（read-only 契約違反）" >&2
  exit 1
fi

echo "✓ mcp-vitest verify:${SUMMARY# }"
