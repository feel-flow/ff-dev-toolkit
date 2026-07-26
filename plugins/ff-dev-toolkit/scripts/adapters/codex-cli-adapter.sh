#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────
# codex-cli-adapter.sh — Multi-CLI Agent: Codex CLI Adapter
# ────────────────────────────────────────────────────────────
# Usage: ./codex-cli-adapter.sh <perspective-file> <output-file> [options]
#
# Options:
#   --changed-files <files>   Comma-separated list of changed files
#   --base <branch>           Base branch for diff (default: auto-detect from origin/HEAD, fallback: develop)
#   --timeout <seconds>       Timeout in seconds (default: 900; the orchestrator always passes this explicitly)
#   --task-type <type>        review | explore | implement (default: review)
#   --description <text>      Task description (for explore/implement)
#
# Requires: codex (npm i -g @openai/codex)
# Cost tier: Standard (token-based billing)
# ────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/adapter-common.sh"

readonly CLI_NAME="Codex CLI"
readonly CLI_COMMAND="codex"

# ── Preflight ──

if ! cli_available "$CLI_COMMAND"; then
  echo "ERROR: ${CLI_NAME} (${CLI_COMMAND}) is not installed." >&2
  echo "Install: npm install -g @openai/codex" >&2
  exit 1
fi

# ── Parse Arguments ──

parse_adapter_args "$@"

# ── Build Prompt ──

prompt="$(build_prompt "$PERSPECTIVE_FILE" "$BASE_BRANCH" "$CHANGED_FILES")"

# ── Task-type specific sandbox ──

get_sandbox_mode() {
  case "${TASK_TYPE:-review}" in
    review)    echo "read-only" ;;
    explore)   echo "read-only" ;;
    implement) echo "network-off" ;;
    *)         echo "read-only" ;;
  esac
}

# ── Execute Task ──

echo "🔍 Running ${CLI_NAME} ${TASK_TYPE:-review}..." >&2
echo "   Perspective: $(basename "$PERSPECTIVE_FILE" .md)" >&2
echo "   Task type: ${TASK_TYPE:-review}" >&2
echo "   Timeout: ${TIMEOUT}s" >&2

sandbox_mode="$(get_sandbox_mode)"
perspective_name="$(basename "$PERSPECTIVE_FILE" .md)"
# Guard this mktemp explicitly: under `set -e` a failure here would kill the
# adapter with a bare 1 before run_with_timeout is ever reached, filing a broken
# TMPDIR as "the CLI exited 1" and writing no artifact at all.
stderr_log="$(mktemp 2>/dev/null)" || stderr_log=""
if [[ -z "$stderr_log" ]]; then
  fail_orchestrator_error "$perspective_name" \
    "cannot create a temp file for ${CLI_NAME} stderr (check TMPDIR)."
fi

result=$(run_with_timeout "$TIMEOUT" \
  "$CLI_COMMAND" exec "$prompt" \
    --sandbox "$sandbox_mode" \
  2>"$stderr_log") || {
    # Capture the status first: any command inside this block would overwrite $?.
    rc=$?
    fail_cli_task "$rc" "$stderr_log" "$perspective_name" "$result"
  }
rm -f "$stderr_log"

if [[ -z "$result" ]]; then
  echo "ERROR: ${CLI_NAME} produced no output. The review may have failed silently." >&2
  exit 1
fi

# ── Write Output ──

write_output "$OUTPUT_FILE" "$CLI_NAME" "$perspective_name" "$result"
