#!/usr/bin/env bash
# 空振り検出: MASTER.md の「必要時にコピー」節の見出しを全部変えると「節が見つからない」で赤、「からコピー」の指示を全部消すと節の各箇条が「指示を読み取れない」・AI ツール設定ガイドの不在・文書数とリンク数の下限で赤（対象 0 件を違反 0 件の緑にしない。箇条 1 行だけを言い回し違いにしても赤。2026-09-26 実測）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if ! command -v node >/dev/null 2>&1; then
  echo "✗ docs-template-portability: node が必要です" >&2
  exit 1
fi

node "$SCRIPT_DIR/verify.mjs"
