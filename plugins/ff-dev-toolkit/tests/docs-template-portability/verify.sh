#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if ! command -v node >/dev/null 2>&1; then
  echo "✗ docs-template-portability: node が必要です" >&2
  exit 1
fi

node "$SCRIPT_DIR/verify.mjs"
