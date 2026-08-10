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
#   --staging-dir <dir>       Absolute, existing, writable dir the agent writes generated
#                             files into (implement only; the orchestrator always passes it)
#   --inline-output           implement without a staging dir: the CLI reports file contents
#                             inline instead of writing them. An implement run with neither
#                             this nor --staging-dir is rejected (a dropped path must not
#                             silently degrade into inline mode)
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

# perspective_name は build_prompt 失敗時の fail_orchestrator_error にも要る。
# build_prompt を mktemp ガードより前に素で呼ぶと set -e が bare exit し、
# INCOMPLETE 成果物が残らない（Issue #267）。
perspective_name="$(basename "$PERSPECTIVE_FILE" .md)"

# ── Build Prompt ──

if ! prompt="$(build_prompt "$PERSPECTIVE_FILE" "$BASE_BRANCH" "$CHANGED_FILES")"; then
  fail_orchestrator_error "$perspective_name" \
    "cannot build the ${TASK_TYPE:-review} prompt (perspective missing, empty diff, or load failure)."
fi

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
echo "   Perspective: ${perspective_name}" >&2
echo "   Task type: ${TASK_TYPE:-review}" >&2
echo "   Timeout: ${TIMEOUT}s" >&2

sandbox_mode="$(get_sandbox_mode)"
# Guard this mktemp explicitly: under `set -e` a failure here would kill the
# adapter with a bare 1 before run_with_timeout is ever reached, filing a broken
# TMPDIR as "the CLI exited 1" and writing no artifact at all.
stderr_log="$(mktemp 2>/dev/null)" || stderr_log=""
if [[ -z "$stderr_log" ]]; then
  fail_orchestrator_error "$perspective_name" \
    "cannot create a temp file for ${CLI_NAME} stderr (check TMPDIR)."
fi

# モデルは既定では指定せず ~/.codex/config.toml に委譲する（ACE-70-2）。
# 明示指定が要るときは -p（プロファイル）が推奨経路 — プロファイルはモデルと
# model_reasoning_effort を 1 ファイルで束ねられるため、「古いモデル + 新しい
# reasoning effort」という意図しない組み合わせを避けられる。
#
# ただしその利点が成立するのは -p 単独のときだけ。codex 0.144.5 で実測すると
# -m を併用した場合は -m のモデルがプロファイルのモデルに勝ち、reasoning effort
# だけプロファイル由来になる — ACE-70-2 が問題視した組み合わせそのものになる。
# 黙って通すと利用者は「プロファイルで束ねたつもり」のまま不整合な設定で走るので、
# 両方が設定されていたら落とす。
if [[ -n "${MULTI_AGENT_MODEL_CODEX_CLI:-}" && -n "${MULTI_AGENT_CODEX_PROFILE:-}" ]]; then
  fail_orchestrator_error "$perspective_name" \
    "MULTI_AGENT_MODEL_CODEX_CLI と MULTI_AGENT_CODEX_PROFILE は同時に指定できません（-m のモデルがプロファイルのモデルを上書きし、reasoning effort だけプロファイル由来という不整合な組み合わせになります）。どちらか一方にしてください。"
fi

# codex は**存在しないプロファイル名を黙って無視し、base config のまま完走する**
# （0.144.5 で実測）。名前を打ち間違えると「専用プロファイルでレビューさせたつもり」
# のまま既定設定で走り、成果物からもログからも判別できない。ラッパー側で存在を
# 確認して落とす（ACE-70-2 の再発そのものを防ぐ）。
if [[ -n "${MULTI_AGENT_CODEX_PROFILE:-}" ]]; then
  codex_profile_file="${CODEX_HOME:-$HOME/.codex}/${MULTI_AGENT_CODEX_PROFILE}.config.toml"
  if [[ ! -f "$codex_profile_file" ]]; then
    fail_orchestrator_error "$perspective_name" \
      "MULTI_AGENT_CODEX_PROFILE=${MULTI_AGENT_CODEX_PROFILE} に対応する ${codex_profile_file} がありません。codex はプロファイル不在をエラーにせず base config のまま完走するため、ラッパー側で落としています。"
  fi
fi

# 引数不正は呼び出し側（このファイル）のバグ。素の呼び出しだと set -e が bare exit 2 で
# 落とすため、INCOMPLETE 成果物が残らず「CLI が 2 で落ちた」と誤読される。
reset_model_args
add_model_arg -m MULTI_AGENT_MODEL_CODEX_CLI \
  || fail_orchestrator_error "$perspective_name" "add_model_arg の呼び出しが不正です（アダプタ側のバグ）。"
add_model_arg -p MULTI_AGENT_CODEX_PROFILE \
  || fail_orchestrator_error "$perspective_name" "add_model_arg の呼び出しが不正です（アダプタ側のバグ）。"
echo_model_args

# MODEL_ARGS は空になりうる。bash 3.2 では set -u 下で空配列を "${a[@]}" と
# 展開すると unbound variable で落ちるため ${a[@]+"${a[@]}"} を使う。
result=$(run_with_timeout "$TIMEOUT" \
  "$CLI_COMMAND" exec "$prompt" \
    --sandbox "$sandbox_mode" \
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
