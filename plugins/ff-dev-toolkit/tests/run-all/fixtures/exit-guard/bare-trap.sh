#!/usr/bin/env bash
# fixture: 素の `trap 'rm -rf ...' EXIT` を case 12 の構造検査へ与える対照。
# Bash の版によって終了コードの挙動が異なるため、実行結果ではなく静的に検出する。
set -euo pipefail
W="/tmp/ff-exit-guard-probe.$$"
mkdir -p "$W"
trap 'rm -rf "$W"' EXIT
: "${__ff_undefined_probe}"
echo "unreachable"
