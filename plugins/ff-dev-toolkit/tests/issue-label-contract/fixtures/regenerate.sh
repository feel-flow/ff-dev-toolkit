#!/usr/bin/env bash
#
# fixtures/ の契約ファイルを SKILL.md から再生成する（Issue #292）。
#
# 契約テキストの正本は fixtures/ 側であって SKILL.md ではない。だが手で書き写すと
# その瞬間にドリフトするので、**契約を意図的に変えたとき**だけ本スクリプトで
# 再生成する。日常の検査は verify.sh が fixtures/ と両 SKILL.md を突き合わせる。
#
# ⚠️ 再生成は「両方の SKILL.md がすでに正しい」ことを前提にする操作である。
#    片方だけ直した状態で走らせると、その変更が契約として追認され、verify.sh が
#    検出するはずだったドリフトを自ら消してしまう。**先に verify.sh を赤いまま読み、
#    両ファイルを揃えてから**再生成すること。
#
# 使い方: bash plugins/ff-dev-toolkit/tests/issue-label-contract/fixtures/regenerate.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SOURCE="$PLUGIN_ROOT/skills/out-of-scope-issue/SKILL.md"

[ -s "$SOURCE" ] || { echo "✗ 生成元がありません: $SOURCE" >&2; exit 1; }

# shellcheck source=./extract.sh
. "$SCRIPT_DIR/extract.sh"

# ---- 契約ブロック（連続した bash の行列） --------------------------------------
extract_label_block "$SOURCE" > "$SCRIPT_DIR/label-block.txt"
block_lines="$(awk 'END { print NR }' "$SCRIPT_DIR/label-block.txt")"
[ "$block_lines" -gt 0 ] || { echo "✗ 契約ブロックを抽出できませんでした: $SOURCE" >&2; exit 1; }

echo "✓ label-block.txt を再生成しました（${block_lines} 行）"
echo "  次に verify.sh を実行し、両 SKILL.md が新しい契約に一致することを確認してください:"
echo "    bash $PLUGIN_ROOT/tests/issue-label-contract/verify.sh"
