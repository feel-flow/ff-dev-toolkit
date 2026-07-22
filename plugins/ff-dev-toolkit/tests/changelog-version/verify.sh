#!/usr/bin/env bash
#
# Fail-closed check: plugin.json version must match the newest dated
# release heading in CHANGELOG.md (excludes [Unreleased]).
#
# Layout resolution:
#   SSOT monorepo:  oss/ff-dev-toolkit/CHANGELOG.md
#   Public checkout: CHANGELOG.md at repo root
# Keep this read-only friendly: no temporary files / here-docs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

PLUGIN_JSON="$PLUGIN_ROOT/.claude-plugin/plugin.json"
CHANGELOG=""

if [[ -f "$REPO_ROOT/oss/ff-dev-toolkit/CHANGELOG.md" ]]; then
  CHANGELOG="$REPO_ROOT/oss/ff-dev-toolkit/CHANGELOG.md"
elif [[ -f "$REPO_ROOT/CHANGELOG.md" ]]; then
  CHANGELOG="$REPO_ROOT/CHANGELOG.md"
else
  echo "✗ CHANGELOG.md not found (looked under oss/ff-dev-toolkit/ and repo root)" >&2
  exit 1
fi

if [[ ! -f "$PLUGIN_JSON" ]]; then
  echo "✗ plugin.json not found: $PLUGIN_JSON" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "✗ jq is required" >&2
  exit 1
fi

PLUGIN_VER="$(jq -er '.version | strings | select(length > 0)' "$PLUGIN_JSON")"
if [[ ! "$PLUGIN_VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-].*)?$ ]]; then
  echo "✗ plugin.json version is not SemVer-like: $PLUGIN_VER" >&2
  exit 1
fi

# First dated release heading: ## [x.y.z] - YYYY-MM-DD
CHANGELOG_VER="$(
  grep -E '^## \[[0-9]+\.[0-9]+\.[0-9]+' "$CHANGELOG" | head -n 1 \
    | sed -E 's/^## \[([0-9]+\.[0-9]+\.[0-9]+[^]]*)\].*/\1/'
)"

if [[ -z "$CHANGELOG_VER" ]]; then
  echo "✗ no dated release heading found in $CHANGELOG" >&2
  exit 1
fi

if [[ "$PLUGIN_VER" != "$CHANGELOG_VER" ]]; then
  echo "✗ version mismatch: plugin.json=$PLUGIN_VER CHANGELOG newest=$CHANGELOG_VER" >&2
  echo "  plugin.json: $PLUGIN_JSON" >&2
  echo "  CHANGELOG:   $CHANGELOG" >&2
  exit 1
fi

echo "✓ plugin.json version ($PLUGIN_VER) matches CHANGELOG newest release heading"
echo "  CHANGELOG: $CHANGELOG"
