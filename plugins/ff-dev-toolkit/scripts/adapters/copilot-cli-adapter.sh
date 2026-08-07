#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────
# copilot-cli-adapter.sh — Multi-CLI Agent: Copilot CLI Adapter
# ────────────────────────────────────────────────────────────
# Usage: ./copilot-cli-adapter.sh <perspective-file> <output-file> [options]
#
# Options:
#   --changed-files <files>   Comma-separated list of changed files
#   --base <branch>           Base branch for diff (default: auto-detect from origin/HEAD, fallback: develop)
#   --timeout <seconds>       Timeout in seconds (default: 900; the orchestrator always passes this explicitly)
#   --task-type <type>        review | explore | implement (default: review)
#   --description <text>      Task description (for explore/implement)
#
# Requires: copilot (VS Code GitHub Copilot CLI extension)
# Cost tier: Flat-rate ($10/month subscription)
# ────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/adapter-common.sh"

readonly CLI_NAME="Copilot CLI"
readonly CLI_COMMAND="copilot"

# ── Preflight ──

if ! cli_available "$CLI_COMMAND"; then
  echo "ERROR: ${CLI_NAME} (${CLI_COMMAND}) is not installed." >&2
  echo "Install: Enable GitHub Copilot CLI extension in VS Code" >&2
  exit 1
fi

# ── Parse Arguments ──

parse_adapter_args "$@"

# perspective_name は build_prompt 失敗時の fail_orchestrator_error にも要る。
# build_prompt を mktemp ガードより前に素で呼ぶと set -e が bare exit し、
# INCOMPLETE 成果物が残らない（Issue #267）。
perspective_name="$(basename "$PERSPECTIVE_FILE" .md)"

# ── Build Prompt ──

if ! prompt="$(build_prompt "$PERSPECTIVE_FILE" "$BASE_BRANCH" "$CHANGED_FILES")"; then
  fail_orchestrator_error "$perspective_name" \
    "cannot build the ${TASK_TYPE:-review} prompt (perspective missing, empty diff, or load failure)."
fi

# ── Execute Task ──

echo "🔍 Running ${CLI_NAME} ${TASK_TYPE:-review}..." >&2
echo "   Perspective: ${perspective_name}" >&2
echo "   Task type: ${TASK_TYPE:-review}" >&2
echo "   Timeout: ${TIMEOUT}s" >&2

# Copilot CLI: -p for prompt, --silent suppresses stats
# Same flags for all task types (flat-rate, no sandbox granularity)
# Guard this mktemp explicitly: under `set -e` a failure here would kill the
# adapter with a bare 1 before run_with_timeout is ever reached, filing a broken
# TMPDIR as "the CLI exited 1" and writing no artifact at all.
stderr_log="$(mktemp 2>/dev/null)" || stderr_log=""
if [[ -z "$stderr_log" ]]; then
  fail_orchestrator_error "$perspective_name" \
    "cannot create a temp file for ${CLI_NAME} stderr (check TMPDIR)."
fi

# モデルは既定では指定せず Copilot 側の設定に委譲する（ACE-70-2）。
# MULTI_AGENT_MODEL_COPILOT_CLI が設定されたときだけ --model を渡す
# （Copilot 側の自動選択に任せたい場合は値に auto を指定する）。
# 引数不正は呼び出し側（このファイル）のバグ。素の呼び出しだと set -e が bare exit 2 で
# 落とすため、INCOMPLETE 成果物が残らず「CLI が 2 で落ちた」と誤読される。
reset_model_args
add_model_arg --model MULTI_AGENT_MODEL_COPILOT_CLI \
  || fail_orchestrator_error "$perspective_name" "add_model_arg の呼び出しが不正です（アダプタ側のバグ）。"
echo_model_args

# MODEL_ARGS は空になりうる。bash 3.2 では set -u 下で空配列を "${a[@]}" と
# 展開すると unbound variable で落ちるため ${a[@]+"${a[@]}"} を使う。
result=$(run_with_timeout "$TIMEOUT" \
  "$CLI_COMMAND" -p "$prompt" \
    --silent \
    ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} \
  2>"$stderr_log") || {
    # Capture the status first: any command inside this block would overwrite $?.
    rc=$?
    fail_cli_task "$rc" "$stderr_log" "$perspective_name" "$result"
  }
# exit 0 + 空出力。ここで stderr を先に捨てると「なぜ空だったか」を言う唯一の
# チャネルが消え、成果物も残らない（実測: レート制限の一文が stderr にだけ出て、
# 成果物もログも残らなかった — feel-flow/ff-dev-toolkit#6 の残件）。fail_cli_task
# へ通して、INCOMPLETE 成果物（stderr があれば抜粋つき）を残す。
if [[ -z "$result" ]]; then
  echo "ERROR: ${CLI_NAME} produced no output. The ${TASK_TYPE:-review} may have failed silently." >&2
  # クラッシュではない（0 で終了し、止められてもいない）。既定の reason のままだと
  # 「CLI が status 1 で落ちた／途中で止められた」と報告され、読み手は存在しない
  # クラッシュを追う。実際に見るべきは成果物に残る stderr 抜粋。
  record_timeout_reason empty-output
  fail_cli_task 1 "$stderr_log" "$perspective_name" ""
fi
rm -f "$stderr_log"

# ── Write Output ──

write_output "$OUTPUT_FILE" "$CLI_NAME" "$perspective_name" "$result"
