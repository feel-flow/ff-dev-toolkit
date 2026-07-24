#!/usr/bin/env bash
#
# ff-dev-toolkit prompt fixture regression test runner.
# Keep this read-only friendly: do not create temporary files and avoid here-doc / here-string.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SCRIPTS=(
  "$SCRIPT_DIR/changelog-version/verify.sh"
  "$SCRIPT_DIR/setup-ai-config/verify.sh"
  "$SCRIPT_DIR/assess-impact/verify.sh"
  "$SCRIPT_DIR/validate-docs/verify.sh"
  "$SCRIPT_DIR/merge-cleanup/verify.sh"
)

for script in "${SCRIPTS[@]}"; do
  if [[ ! -x "$script" ]]; then
    echo "✗ verify script is missing or not executable: $script" >&2
    exit 1
  fi
  echo "== $(basename "$(dirname "$script")") =="
  bash "$script"
  echo
done

echo "All ff-dev-toolkit fixture checks passed."
