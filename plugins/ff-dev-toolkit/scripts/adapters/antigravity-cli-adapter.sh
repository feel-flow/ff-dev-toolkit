#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────
# antigravity-cli-adapter.sh — Multi-CLI Agent: Google Antigravity CLI Adapter
# ────────────────────────────────────────────────────────────
# Usage: ./antigravity-cli-adapter.sh <perspective-file> <output-file> [options]
#
# Options:
#   --changed-files <files>   Comma-separated list of changed files
#   --base <branch>           Base branch for diff (default: auto-detect from origin/HEAD, fallback: develop)
#   --staged                  Review only staged changes (mutually exclusive with --base)
#   --timeout <seconds>       Timeout in seconds (default: 900; the orchestrator always passes this explicitly)
#   --task-type <type>        review | explore | implement (default: review)
#   --description <text>      Task description (for explore/implement)
#   --delegate-dir <dir>      Host delegation (review only, Issue `#2118`): when this CLI is the host,
#                             hand the prompt to the host's own subagent instead of starting the CLI
#                             (--delegate-to-host=antigravity-cli; see adapter-common.sh run_host_delegation_or_continue).
#   --staging-dir <dir>       Absolute, existing, writable dir the agent writes generated
#                             files into (implement only; the orchestrator always passes it)
#   --inline-output           implement without a staging dir: the CLI reports file contents
#                             inline instead of writing them. An implement run with neither
#                             this nor --staging-dir is rejected (a dropped path must not
#                             silently degrade into inline mode)
#
# Requires: agy (Google Antigravity CLI, headless mode `-p "" --input-format text`)
# Cost tier: Metered (excluded from default lineup; opt in via --cli antigravity-cli
#            or --delegate-to-host=antigravity-cli)
# ────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/adapter-common.sh"
source "${SCRIPT_DIR}/../lib/antigravity-cli-readonly-boundary.sh"

readonly CLI_NAME="Google Antigravity CLI"
readonly CLI_COMMAND="agy"
readonly CLI_LANE="antigravity-cli"
# ホスト委譲の受理を opt-in する: このレーンを、同じホスト（Antigravity IDE の subagent / 同一ホスト構成）で
# 走らせる経路（--delegate-to-host=antigravity-cli）。adapter-common.sh の parse_adapter_args が検査する
# shellcheck disable=SC2034 # adapter-common.sh（source 先）が読む
ADAPTER_SUPPORTS_DELEGATION=true

# ── 起動前のレーン確認（--precheck。Issue `#2044`。入口は adapter-common-cli.sh）──
# agy CLI には残量・認証を非対話で照会する統一ステータス副コマンドが無いため能力は none。
# --precheck は常に unknown を返し、通常どおり起動する。
# shellcheck disable=SC2034 # adapter-common-cli.sh（source 先）の handle_adapter_precheck_request が読む
readonly ADAPTER_PRECHECK_CAPABILITY="none"
handle_adapter_precheck_request "$@"

# ── Parse Arguments ──

parse_adapter_args "$@"

# ── Preflight ──

# 委譲経路（--delegate-dir）は CLI を起動しないので導入を要求しない（Issue `#2118`）
if [[ -z "${DELEGATE_DIR:-}" ]] && ! cli_available "$CLI_COMMAND"; then
  echo "ERROR: ${CLI_NAME} (${CLI_COMMAND}) is not installed or not authenticated." >&2
  echo "Install Google Antigravity CLI (agy) and verify with: agy --version" >&2
  exit 1
fi

perspective_name="$(basename "$PERSPECTIVE_FILE" .md)"

# ── Host Delegation Allowlist ──

get_allowed_tools() {
  if [[ "${TASK_TYPE:-review}" == "implement" && "${INLINE_OUTPUT:-false}" != "true" ]]; then
    echo 'read_file,write_file,edit_file,grep,list_dir'
    return
  fi
  echo 'read_file,grep,list_dir'
}

# ── Build Prompt ──

if ! prompt="$(build_prompt "$PERSPECTIVE_FILE" "$BASE_BRANCH" "$CHANGED_FILES")"; then
  fail_orchestrator_error "$perspective_name" \
    "cannot build the ${TASK_TYPE:-review} prompt (perspective missing, empty diff, or load failure)."
fi

# ── Host Delegation (if --delegate-dir was given) ──

# CLI を起動する前の位置（"🔍 Running ..." より前）で委譲し、起動していないログを残さない。
run_host_delegation_or_continue "$CLI_LANE" "$CLI_NAME" "$perspective_name" "$prompt" "$(get_allowed_tools)"

# Read-only 実行では CLI 起動前に実効権限設定を検査し、--mode "" を迂回する自動承認や書込 allow を fail-closed で拒否する。
if [[ "${TASK_TYPE:-review}" != "implement" || "${INLINE_OUTPUT:-false}" == "true" ]]; then
  readonly_status=""
  readonly_rc=0
  readonly_status=$(ff_antigravity_readonly_preflight "$PWD") || readonly_rc=$?
  if [[ $readonly_rc -ne 0 || "$readonly_status" != "confirmed" ]]; then
    fail_orchestrator_error "$perspective_name" "antigravity-cli read-only preflight failed (${readonly_status:-unknown}). Ensure HOME/workspace settings do not set toolPermission to always-proceed/proceed-in-sandbox, allow non-read-only rules in permissions.allow without matching <action>(*) deny/ask, or contain symlinks/invalid JSON."
  fi
fi

# ── Model Selection ──
# ラッパーはモデルを選ばない。MULTI_AGENT_MODEL_ANTIGRAVITY_CLI が設定されているときだけ
# --model を渡し、未設定なら agy 側の設定（settings.json 等）へ委譲する。

reset_model_args
add_model_arg --model MULTI_AGENT_MODEL_ANTIGRAVITY_CLI

# ── Task-type Mode Selection ──
# Headless `agy -p ""` のモード仕様（Google Antigravity CLI modes/headless 一次ドキュメント）:
#   - read-only 経路（review / explore / implement --inline-output）:
#     `--mode ""` を渡すことで、利用者の settings.json が `"agentMode": "auto"` や
#     `"accept-edits"` を持っていても `default`（= `request-review`）へ戻す。headless モードでは
#     承認を求める書き込み・コマンド実行は自動承認されず soft-deny になる。
#     （`--mode` が未指定のときに限り settings.json が読まれるため、空文字の明示が必要）
#   - 書き込み経路（implement with --staging-dir）:
#     `--mode accept-edits --add-dir "$STAGING_DIR"` を渡し、staging ディレクトリへの書き込みを
#     許可する。`--disable-slash-commands` でユーザーカスタム slash command の誤発火を抑止する。
#   - boolean --sandbox を有効化する（実 agy CLI での強制範囲は未実測）。

if [[ "${TASK_TYPE:-review}" == "implement" && "${INLINE_OUTPUT:-false}" != "true" ]]; then
  AGY_MODE_ARGS=(--mode accept-edits --add-dir "$STAGING_DIR")
else
  AGY_MODE_ARGS=(--mode "")
fi

# ── Execute ──

echo "🔍 Running ${CLI_NAME} (${TASK_TYPE}): ${perspective_name} (timeout: ${TIMEOUT}s)..." >&2
echo_model_args

if ! stderr_log="$(mktemp)"; then
  fail_orchestrator_error "$perspective_name" \
    "cannot create a temp file for CLI stderr (check TMPDIR)."
fi
# Pass the full prompt via stdin (`-p "" --input-format text`) so diffs do not hit ARG_MAX (Issue `#712`).
if ! prompt_file="$(materialize_prompt_file "$prompt")"; then
  rm -f "$stderr_log"
  fail_orchestrator_error "$perspective_name" \
    "cannot materialize the prompt into a temp file (check TMPDIR / UTF-8)."
fi
_FF_PROMPT_FILE="$prompt_file"

result=""
rc=0
result=$(run_with_timeout --stdin-file "$prompt_file" "$TIMEOUT" \
  env RETROSPECTIVE_MODE=off "$CLI_COMMAND" \
  -p "" \
  --input-format text \
  --output-format text \
  "${AGY_MODE_ARGS[@]}" \
  --sandbox \
  --disable-slash-commands \
  ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} 2>"$stderr_log") || {
    rc=$?
    fail_cli_task "$rc" "$stderr_log" "$perspective_name" "$result"
  }
rm -f "$prompt_file"
_FF_PROMPT_FILE=""

# Exit 0 with empty stdout still leaves the report silently unreviewed (same gate as other adapters).
if [[ -z "${result//[[:space:]]/}" ]]; then
  record_timeout_reason empty-output
  echo "ERROR: ${CLI_NAME} exited 0 without producing any output." >&2
  fail_cli_task 1 "$stderr_log" "$perspective_name" ""
fi

# Fail loud on review completions that have output without a typed verdict line.
if [[ "${TASK_TYPE:-review}" == "review" ]] && ! review_body_present "$result" "${CLI_NAME}/${perspective_name}"; then
  record_timeout_reason missing-review-body
  echo "ERROR: ${CLI_NAME} exited 0, but its captured output $(review_body_refusal_clause) — refusing it as a review result." >&2
  fail_cli_task 1 "$stderr_log" "$perspective_name" "$result"
fi

rm -f "$stderr_log"

# Write output (fail loudly if the write fails — Issue `#159` pattern).
write_output "$OUTPUT_FILE" "$CLI_NAME" "$perspective_name" "$result" \
  || fail_output_write "$perspective_name" "$OUTPUT_FILE"

echo "✅ Done: ${CLI_NAME} (${perspective_name})" >&2
