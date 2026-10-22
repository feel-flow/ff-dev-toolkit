#!/usr/bin/env bash
# 空振り検出: review-freeze-contract/verify.sh を空にする単独変異で3テストが赤、h2 fixture の対象見出しを消す単独変異で20件が赤（macOS実測）。関数不在・対象0件を成功へ倒さない。 docs-gates/verify.sh を空にすると2テスト、参照代入・count式・例外判定代入を各々消すと各1テストが赤（macOS実測）。
# 日本語の完全一致・集合演算の LC_ALL=C を、実関数と日本語の異なる入力で検証する。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
if ! command -v python3 >/dev/null 2>&1; then
  echo '✗ locale-comparison: python3 が必要です' >&2
  exit 1
fi
PYTHONDONTWRITEBYTECODE=1 python3 "$SCRIPT_DIR/cases.py" "$PLUGIN_ROOT"
