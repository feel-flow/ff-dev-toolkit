#!/usr/bin/env bash
# Issue `#2203`: 実 suite の入口で一時領域内の Git ルートを拒否する契約。
# run-all-required: yes — 実 suite の早期停止と物理パス境界を単独で守り、検査不能を skip で通さない。
# 空振り検出: 本体 guard の削除/後置、物理化・CDPATH中和の除去、prefix/同一/ルート境界、TMPDIR/default の除去、空 Git root の成功化は全12変異が赤。入力の不在/空/読取不可とケース集合0件も赤、前後の27ケースは緑（2026-10-24 macOS実測）。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
for required in "$SCRIPT_DIR/cases.py" "$SCRIPT_DIR/../adapter-sandbox-contract/verify.sh" "$SCRIPT_DIR/../lib/git-fixture.sh"; do
  if [ ! -s "$required" ] || [ ! -r "$required" ]; then
    printf '✗ adapter-sandbox-contract-selftest: 必須入力が空・不在・読めません: %s\n' "$required" >&2
    exit 1
  fi
done
python3 -B "$SCRIPT_DIR/cases.py" "$SCRIPT_DIR/../adapter-sandbox-contract/verify.sh" "$SCRIPT_DIR/../lib/git-fixture.sh"
