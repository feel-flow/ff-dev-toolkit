#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────
# gemini-cli-adapter.sh — Multi-CLI Agent: Gemini CLI Adapter
# ────────────────────────────────────────────────────────────
# Usage: ./gemini-cli-adapter.sh <perspective-file> <output-file> [options]
#
# Options:
#   --changed-files <files>   Comma-separated list of changed files
#   --base <branch>           Base branch for diff (default: auto-detect from origin/HEAD, fallback: develop)
#   --timeout <seconds>       Timeout in seconds (default: 900; the orchestrator always passes this explicitly)
#   --task-type <type>        review | explore | implement (default: review)
#   --description <text>      Task description (for explore/implement)
#
# Requires: gemini (npm i -g @google/gemini-cli)
# Cost tier: Free-tier (generous free quota)
#   Google login: 60 RPM / 1,000 RPD
#   Free API key: 10 RPM / 250 RPD
# ────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/adapter-common.sh"

readonly CLI_NAME="Gemini CLI"
readonly CLI_COMMAND="gemini"

# ── Preflight ──

if ! cli_available "$CLI_COMMAND"; then
  echo "ERROR: ${CLI_NAME} (${CLI_COMMAND}) is not installed." >&2
  echo "Install: npm install -g @google/gemini-cli" >&2
  exit 1
fi

# ── Parse Arguments ──

parse_adapter_args "$@"

# ── Build Prompt ──

prompt="$(build_prompt "$PERSPECTIVE_FILE" "$BASE_BRANCH" "$CHANGED_FILES")"

# ── Execute Task ──

echo "🔍 Running ${CLI_NAME} ${TASK_TYPE:-review}..." >&2
echo "   Perspective: $(basename "$PERSPECTIVE_FILE" .md)" >&2
echo "   Task type: ${TASK_TYPE:-review}" >&2
echo "   Timeout: ${TIMEOUT}s" >&2

# Gemini CLI: -p for prompt, --output-format text for parseable output
# Task-type specific sandbox: review/explore use --sandbox (read-only),
# implement omits --sandbox to allow output generation
get_gemini_sandbox_flag() {
  case "${TASK_TYPE:-review}" in
    review|explore) echo "--sandbox" ;;
    implement)      echo "" ;;
    *)              echo "--sandbox" ;;
  esac
}

sandbox_flag="$(get_gemini_sandbox_flag)"
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
  "$CLI_COMMAND" -p "$prompt" \
    $sandbox_flag \
    --output-format text \
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
