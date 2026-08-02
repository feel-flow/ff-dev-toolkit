#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────
# cursor-cli-adapter.sh — Multi-CLI Agent: Cursor CLI Adapter
# ────────────────────────────────────────────────────────────
# Usage: ./cursor-cli-adapter.sh <perspective-file> <output-file> [options]
#
# Options:
#   --changed-files <files>   Comma-separated list of changed files
#   --base <branch>           Base branch for diff (default: auto-detect from origin/HEAD, fallback: develop)
#   --timeout <seconds>       Timeout in seconds (default: 120)
#   --task-type <type>        review | explore | implement (default: review)
#   --description <text>      Task description (for explore/implement)
#
# Requires: cursor-agent (Cursor IDE CLI)
# Cost tier: Flat-rate ($20/month subscription)
#
# ⚠️  Known issue: cursor-agent --print may hang in non-interactive mode, so the
#     timeout is capped at 120s. When run through multi-agent.sh the cap is
#     applied there (get_cli_timeout_cap) so the limit it reports and advises is
#     the one that applies; the cap below is for a direct invocation. Both values
#     are gated against each other by tests/multi-agent-timeout/verify.sh.
#     run_with_timeout enforces the limit with its own supervisor on every host —
#     no coreutils install required.
# ────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/adapter-common.sh"

readonly CLI_NAME="Cursor CLI"
readonly CLI_COMMAND="cursor-agent"

# Shorter default timeout due to known hanging issue.
# FF_CURSOR_TIMEOUT_CAP is the same test seam multi-agent.sh honours, so a test can
# exercise the cap without waiting out the real 120s.
readonly DEFAULT_CURSOR_TIMEOUT="${FF_CURSOR_TIMEOUT_CAP:-120}"

# ── Preflight ──

if ! cli_available "$CLI_COMMAND"; then
  echo "ERROR: ${CLI_NAME} (${CLI_COMMAND}) is not installed." >&2
  echo "Install: Install Cursor IDE and enable CLI access" >&2
  exit 1
fi

# ── Parse Arguments ──

parse_adapter_args "$@"

# Apply shorter timeout for Cursor by default
if [[ "$TIMEOUT" -gt "$DEFAULT_CURSOR_TIMEOUT" ]]; then
  TIMEOUT="$DEFAULT_CURSOR_TIMEOUT"
  echo "⚠️  Cursor CLI timeout capped at ${TIMEOUT}s (known hanging issue)" >&2
fi

# ── Build Prompt ──

prompt="$(build_prompt "$PERSPECTIVE_FILE" "$BASE_BRANCH" "$CHANGED_FILES")"

# ── Execute Task ──

echo "🔍 Running ${CLI_NAME} ${TASK_TYPE:-review}..." >&2
echo "   Perspective: $(basename "$PERSPECTIVE_FILE" .md)" >&2
echo "   Task type: ${TASK_TYPE:-review}" >&2
echo "   Timeout: ${TIMEOUT}s (capped for Cursor)" >&2

# Cursor CLI: --print for non-interactive output
# Same flags for all task types (flat-rate, no sandbox granularity)
perspective_name="$(basename "$PERSPECTIVE_FILE" .md)"
# Guard this mktemp explicitly: under `set -e` a failure here would kill the
# adapter with a bare 1 before run_with_timeout is ever reached, filing a broken
# TMPDIR as "the CLI exited 1" and writing no artifact at all.
stderr_log="$(mktemp 2>/dev/null)" || stderr_log=""
if [[ -z "$stderr_log" ]]; then
  fail_orchestrator_error "$perspective_name" \
    "cannot create a temp file for ${CLI_NAME} stderr (check TMPDIR)."
fi

# 既定は auto（Cursor 側にモデルを選ばせる）。auto はベンダー中立で世代交代しない
# 語なのでラッパーが持ってよい唯一の種類の値であり、具体的なモデル slug を既定値に
# することはしない（ACE-70-2）。MULTI_AGENT_MODEL_CURSOR_CLI で上書きできる。
# 引数不正は呼び出し側（このファイル）のバグ。素の呼び出しだと set -e が bare exit 2 で
# 落とすため、INCOMPLETE 成果物が残らず「CLI が 2 で落ちた」と誤読される。
reset_model_args
add_model_arg --model MULTI_AGENT_MODEL_CURSOR_CLI auto \
  || fail_orchestrator_error "$perspective_name" "add_model_arg の呼び出しが不正です（アダプタ側のバグ）。"
echo_model_args

# ここでは MODEL_ARGS は既定値 auto があるため常に非空だが、他アダプタと展開の
# 書き方を揃える（bash 3.2 では set -u 下の空配列展開が unbound variable になる）。
result=$(run_with_timeout "$TIMEOUT" \
  "$CLI_COMMAND" --print ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} "$prompt" \
  2>"$stderr_log") || {
    # Capture the status first: any command inside this block would overwrite $?.
    rc=$?
    # Ask the out-of-band reason rather than the number: cursor-agent exiting 124
    # on its own is not our deadline firing, and the hang note would misdirect.
    if [[ "$(read_timeout_reason)" == "timeout" ]]; then
      echo "NOTE: ${CLI_NAME} is known to hang in non-interactive mode — a timeout" >&2
      echo "      here may be the hang rather than a genuinely long review." >&2
    fi
    fail_cli_task "$rc" "$stderr_log" "$perspective_name" "$result"
  }
rm -f "$stderr_log"

if [[ -z "$result" ]]; then
  echo "ERROR: ${CLI_NAME} produced no output. The review may have failed silently." >&2
  exit 1
fi

# ── Write Output ──

write_output "$OUTPUT_FILE" "$CLI_NAME" "$perspective_name" "$result"
