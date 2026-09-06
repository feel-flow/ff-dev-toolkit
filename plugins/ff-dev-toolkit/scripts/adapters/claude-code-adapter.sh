#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────
# claude-code-adapter.sh — Multi-CLI Agent: Claude Code Adapter
# ────────────────────────────────────────────────────────────
# Usage: ./claude-code-adapter.sh <perspective-file> <output-file> [options]
#
# Options:
#   --changed-files <files>   Comma-separated list of changed files
#   --base <branch>           Base branch for diff (default: auto-detect from origin/HEAD, fallback: develop)
#   --staged                  Review only staged changes (mutually exclusive with --base)
#   --timeout <seconds>       Timeout in seconds (default: 900; the orchestrator always passes this explicitly)
#   --task-type <type>        review | explore | implement (default: review)
#   --description <text>      Task description (for explore/implement)
#   --staging-dir <dir>       Absolute, existing, writable dir the agent writes generated
#                             files into (implement only; the orchestrator always passes it)
#   --inline-output           implement without a staging dir: the CLI reports file contents
#                             inline instead of writing them. An implement run with neither
#                             this nor --staging-dir is rejected (a dropped path must not
#                             silently degrade into inline mode)
#
# Requires: claude (npm i -g @anthropic-ai/claude-code)
# Cost tier: Premium (token-based billing)
# ────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/adapter-common.sh"

readonly CLI_NAME="Claude Code"
readonly CLI_COMMAND="claude"

# ── Preflight ──

if ! cli_available "$CLI_COMMAND"; then
  echo "ERROR: ${CLI_NAME} (${CLI_COMMAND}) is not installed." >&2
  echo "Install: npm install -g @anthropic-ai/claude-code" >&2
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

# ── Task-type specific flags ──

get_allowed_tools() {
  if [[ "${TASK_TYPE:-review}" == "implement" && "${INLINE_OUTPUT:-false}" == "true" ]]; then
    echo 'Read,Grep,Glob,Bash(git diff*)'
    return
  fi
  case "${TASK_TYPE:-review}" in
    review)    echo 'Read,Grep,Glob,Bash(git diff*)' ;;
    explore)   echo 'Read,Grep,Glob,Bash(git*),Bash(find*),Bash(ls*)' ;;
    implement) echo 'Read,Grep,Glob,Edit,Write,Bash' ;;
    *)         echo 'Read,Grep,Glob,Bash(git diff*)' ;;
  esac
}

# ── Execute Task ──

echo "🔍 Running ${CLI_NAME} ${TASK_TYPE:-review}..." >&2
echo "   Perspective: ${perspective_name}" >&2
echo "   Task type: ${TASK_TYPE:-review}" >&2
echo "   Timeout: ${TIMEOUT}s" >&2

allowed_tools="$(get_allowed_tools)"
# Guard this mktemp explicitly: under `set -e` a failure here would kill the
# adapter with a bare 1 before run_with_timeout is ever reached, filing a broken
# TMPDIR as "the CLI exited 1" and writing no artifact at all.
stderr_log="$(mktemp 2>/dev/null)" || stderr_log=""
if [[ -z "$stderr_log" ]]; then
  fail_orchestrator_error "$perspective_name" \
    "cannot create a temp file for ${CLI_NAME} stderr (check TMPDIR)."
fi

# モデルは既定では指定せず Claude Code 側の設定に委譲する（ACE-70-2）。
# MULTI_AGENT_MODEL_CLAUDE_CODE が設定されたときだけ --model を渡す。
# 'opus' / 'sonnet' / 'haiku' / 'fable' は最新版を指すエイリアスなので、
# slug 直書きより腐りにくい。
# 引数不正は呼び出し側（このファイル）のバグ。素の呼び出しだと set -e が bare exit 2 で
# 落とすため、INCOMPLETE 成果物が残らず「CLI が 2 で落ちた」と誤読される。他のガード
# （mktemp など）と同じく fail_orchestrator_error で明示的に落とす。
reset_model_args
add_model_arg --model MULTI_AGENT_MODEL_CLAUDE_CODE \
  || fail_orchestrator_error "$perspective_name" "add_model_arg の呼び出しが不正です（アダプタ側のバグ）。"
validate_effort_env claude-code || fail_orchestrator_error "$perspective_name" "invalid Claude effort"
if [[ "${MULTI_AGENT_CLAUDE_EFFORT+x}" == x ]]; then
  MODEL_ARGS+=(--effort "$MULTI_AGENT_CLAUDE_EFFORT")
fi
echo_model_args
echo_effort_setting claude-code

# プロンプトは argv ではなく stdin で渡す（Issue #712: argv 渡しは Windows の
# CreateProcess 上限 ~32KB で exit 126 になる）。`claude -p` は位置引数が無い
# 場合プロンプトを stdin から読む（Claude Code 2.1.235 で実測済み）。
prompt_file="$(materialize_prompt_file "$prompt")" || prompt_file=""
if [[ -z "$prompt_file" ]]; then
  fail_orchestrator_error "$perspective_name" \
    "cannot hand the prompt to the CLI (temp-file write failed, or the prompt is not valid UTF-8 — see the error above)."
fi
_FF_PROMPT_FILE="$prompt_file"

# MODEL_ARGS は空になりうる。bash 3.2 では set -u 下で空配列を "${a[@]}" と
# 展開すると unbound variable で落ちるため ${a[@]+"${a[@]}"} を使う。
result=$(run_with_timeout --stdin-file "$prompt_file" "$TIMEOUT" \
  "$CLI_COMMAND" -p \
    --allowed-tools "$allowed_tools" \
    ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} \
  2>"$stderr_log") || {
    # Capture the status first: any command inside this block would overwrite $?.
    rc=$?
    fail_cli_task "$rc" "$stderr_log" "$perspective_name" "$result"
  }
rm -f "$prompt_file"
_FF_PROMPT_FILE=""
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
# exit 0 + 非空でも、レビュー本文の実体行を 1 行も含まない捕捉結果は complete に
# しない（Issue #893。捕捉されるのは CLI の最終出力のみで、本文が途中ターンに出ると
# 前置き・メタ記述だけが残る）。missing-review-body の INCOMPLETE 成果物へ落とし、
# 捕捉できた出力は保全する。**受理条件の正は adapter-common.sh の review_body_present
# ヘッダ** — このコメントに列挙を複製しない（記述ごとの条件ズレの再発防止）。
if [[ "${TASK_TYPE:-review}" == "review" ]] && ! review_body_present "$result"; then
  echo "ERROR: ${CLI_NAME} output ($(printf '%s' "$result" | wc -c | tr -d '[:space:]') bytes) contains no severity count/zero line, no severity-labeled finding line, and no finding bullet under a severity heading — refusing it as a review result. The review body may have been emitted in an earlier, uncaptured turn." >&2
  record_timeout_reason missing-review-body
  fail_cli_task 1 "$stderr_log" "$perspective_name" "$result"
fi
rm -f "$stderr_log"

# ── Write Output ──

write_output "$OUTPUT_FILE" "$CLI_NAME" "$perspective_name" "$result"
