#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────
# multi-agent.sh — Multi-CLI Agent Orchestrator
# ────────────────────────────────────────────────────────────
# Orchestrates 5 AI CLIs (Claude Code, Codex, Copilot, Gemini, Cursor)
# for review, explore, and implement tasks using tool-agnostic perspectives.
#
# NOTE: Copilot CLI is metered (premium requests) — excluded from the
# default review lineup. Opt in explicitly with --cli copilot-cli.
#
# Compatible with bash 3.2+ (macOS default).
#
# Usage:
#   bash scripts/multi-agent.sh --task <type> [options]
#
# Options:
#   --task <type>           review | explore | implement (default: review)
#   --description <text>    Task description (required for explore/implement)
#   --config <path>         Config file (default: $MULTI_AGENT_CONFIG > <project>/.claude/agent-config.yaml > plugin-bundled agent-config.yaml)
#   --mode <mode>           distributed | cross-model
#   --strategy <strategy>   balanced | minimize_cost | maximize_quality
#   --cli <name>            Run only this CLI (repeatable)
#   --perspective <name>    Run only this perspective (repeatable). In distributed
#                           mode, only its owning CLI remains unless --cli is also
#                           explicit; use --mode cross-model for model comparison.
#   --parallel              Parallel execution (default)
#   --sequential            Sequential execution
#   --output-dir <dir>      Output directory (auto-detected by task type)
#   --base <branch>         Base branch for diff (default: auto-detect from origin/HEAD, fallback: develop)
#   --include-diff          Include diff in implement prompts
#   --dry-run               Show plan without executing
#   --timeout <seconds>     Timeout per CLI (default: review 900 / explore 600 / implement 900)
#   --help                  Show this help
#
# Fallback semantics (two different things — do not confuse them):
#   Plan-time (automatic):  a CLI that is NOT INSTALLED has its perspectives
#                           reassigned to the `fallback:` CLI in agent-config.yaml
#                           while the plan is built.
#   Runtime (never automatic): a CLI that IS installed but then fails or times out
#                           is NOT retried on another CLI. The task is reported as
#                           failed and the run exits non-zero.
#   Why runtime fallback is deliberately absent: this tool exists to get several
#   *different* models onto the same diff, so silently swapping the model changes
#   what was actually reviewed while the report still shows the perspective as
#   covered; the configured substitute can also be a costlier tier (codex-cli →
#   claude-code is standard → premium) that the user never asked to pay for; and
#   a retry after a timeout spends a second full budget on the same slow work.
#   Re-run the substitute yourself with --cli when you want it — the failure
#   summary prints a ready-to-run command for each failed task, matched to why it
#   failed (a longer limit is only offered when a limit is what ran out).
#
# Perspective resolution:
#   --perspective alone filters the distributed ownership registry and can shrink
#   a review plan to one CLI. The plan reports installed CLIs excluded this way
#   and warns when the remaining review has a single point of failure.
#   A single --cli <name> + single --perspective <name> is an explicit pairing
#   and runs that perspective on that CLI even when the registry assigns it
#   elsewhere. Explicit CLIs are not replaced by a cost strategy. Repeatable
#   multi-value filters retain registry ownership. A requested perspective must
#   exist for the selected task; invalid names are rejected before dry-run.
#
# Entry Points:
#   Terminal:     bash scripts/multi-agent.sh --task review
#   Claude Code:  /multi-review, /multi-explore, /multi-implement
#   CI/CD:        See docs-template/05-operations/deployment/multi-cli-review-orchestration.md
#
# See: docs-template/05-operations/deployment/multi-cli-review-orchestration.md
# ────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# REPO_ROOT is the *target project* root (diff target and output dirs).
# This script may live inside an installed plugin, so the script location
# must not be used to locate the project. Run from inside the project repo.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
IN_GIT_REPO=true
if [[ -z "$REPO_ROOT" ]]; then
  IN_GIT_REPO=false
  REPO_ROOT="$(pwd)"
  echo "⚠️  Not inside a git repository — using current directory as project root: ${REPO_ROOT}" >&2
fi

# ── All known CLI names ──
ALL_CLIS="claude-code codex-cli copilot-cli gemini-cli cursor-cli"

# ── Lookup Functions (bash 3.2 compatible — no associative arrays) ──

get_cli_command() {
  case "$1" in
    claude-code) echo "claude" ;;
    codex-cli)   echo "codex" ;;
    copilot-cli) echo "copilot" ;;
    gemini-cli)  echo "gemini" ;;
    cursor-cli)  echo "cursor-agent" ;;
    *) echo "" ;;
  esac
}

get_cli_adapter() {
  case "$1" in
    claude-code) echo "${SCRIPT_DIR}/adapters/claude-code-adapter.sh" ;;
    codex-cli)   echo "${SCRIPT_DIR}/adapters/codex-cli-adapter.sh" ;;
    copilot-cli) echo "${SCRIPT_DIR}/adapters/copilot-cli-adapter.sh" ;;
    gemini-cli)  echo "${SCRIPT_DIR}/adapters/gemini-cli-adapter.sh" ;;
    cursor-cli)  echo "${SCRIPT_DIR}/adapters/cursor-cli-adapter.sh" ;;
    *) echo "" ;;
  esac
}

# ── Task-type aware perspective mappings ──

get_cli_perspectives_review() {
  case "$1" in
    claude-code) echo "type-design-analysis" ;;
    codex-cli)   echo "code-review error-handler-hunt test-analysis" ;;
    copilot-cli) echo "test-analysis comment-analysis" ;;  # metered — runs ONLY with explicit --cli copilot-cli (see build_distributed_plan)
    gemini-cli)  echo "security-analysis comment-analysis" ;;
    cursor-cli)  echo "code-simplification" ;;
    *) echo "" ;;
  esac
}

get_cli_perspectives_explore() {
  case "$1" in
    claude-code) echo "architecture-analysis" ;;
    codex-cli)   echo "dependency-mapping" ;;
    copilot-cli) echo "api-surface-analysis" ;;
    gemini-cli)  echo "tech-debt-assessment" ;;
    cursor-cli)  echo "pattern-discovery" ;;
    *) echo "" ;;
  esac
}

get_cli_perspectives_implement() {
  case "$1" in
    claude-code) echo "feature-implementation" ;;
    codex-cli)   echo "refactoring" ;;
    copilot-cli) echo "test-writing" ;;
    gemini-cli)  echo "documentation" ;;
    cursor-cli)  echo "migration" ;;
    *) echo "" ;;
  esac
}

get_cli_perspectives() {
  local cli_name="$1"
  case "$TASK_TYPE" in
    review)    get_cli_perspectives_review "$cli_name" ;;
    explore)   get_cli_perspectives_explore "$cli_name" ;;
    implement) get_cli_perspectives_implement "$cli_name" ;;
    *)         get_cli_perspectives_review "$cli_name" ;;
  esac
}

get_cli_fallback() {
  case "$1" in
    claude-code) echo "codex-cli" ;;
    codex-cli)   echo "claude-code" ;;
    copilot-cli) echo "codex-cli" ;;
    gemini-cli)  echo "codex-cli" ;;
    cursor-cli)  echo "codex-cli" ;;
    *) echo "" ;;
  esac
}

# ── Model-Selection Env Passthrough ──
# モデル選択の env は「インラインで前置して 1 回だけ効かせる」形（multi-review の
# SKILL.md の例もそれ）なので、元コマンドが終わると消える。再実行コマンドをそのまま
# 出すと、貼り付けた人は既定のモデル / プロファイルで走ることになり、失敗した構成の
# 再現にならない。
#
# 前置は**その行の CLI に効くものだけ**にする。全部まとめて前置すると、代替 CLI を
# 案内する行にも無関係な env が乗り、実際には使われない設定を使うかのように読める。
get_cli_model_env_vars() {
  case "$1" in
    claude-code) echo "MULTI_AGENT_MODEL_CLAUDE_CODE" ;;
    codex-cli)   echo "MULTI_AGENT_MODEL_CODEX_CLI MULTI_AGENT_CODEX_PROFILE" ;;
    copilot-cli) echo "MULTI_AGENT_MODEL_COPILOT_CLI" ;;
    gemini-cli)  echo "MULTI_AGENT_MODEL_GEMINI_CLI" ;;
    cursor-cli)  echo "MULTI_AGENT_MODEL_CURSOR_CLI" ;;
    *) echo "" ;;
  esac
}

# 設定されている env だけを `VAR=値 ` の形で連結して返す（無ければ空文字）。
# codex でモデルとプロファイルが両方設定されている場合はアダプタが実行前に拒否するが、
# ここでは両方そのまま前置する — 再実行は「失敗した構成の忠実な再現」であるべきで、
# 片方を黙って落とすと、直したはずの「上書きが静かに消える」問題に戻る。利用者が
# どちらを残すべきかはアダプタのエラーメッセージが明示している。
model_env_prefix() {
  local cli="$1" var prefix=""
  for var in $(get_cli_model_env_vars "$cli"); do
    if [[ -n "${!var:-}" ]]; then
      prefix="${prefix}${var}=$(printf '%q' "${!var}") "
    fi
  done
  printf '%s' "$prefix"
}

get_cli_cost_tier() {
  case "$1" in
    claude-code) echo "premium" ;;
    codex-cli)   echo "standard" ;;
    copilot-cli) echo "metered" ;;
    gemini-cli)  echo "free-tier" ;;
    cursor-cli)  echo "flat-rate" ;;
    *) echo "unknown" ;;
  esac
}

# ── Task-type defaults ──

get_default_output_dir() {
  case "$1" in
    review)    echo "${REPO_ROOT}/.review-results" ;;
    explore)   echo "${REPO_ROOT}/.explore-results" ;;
    implement) echo "${REPO_ROOT}/.implement-results" ;;
    *)         echo "${REPO_ROOT}/.review-results" ;;
  esac
}

# ── Task-type default timeouts (seconds) ──
# SSOT for the defaults. Every copy of these numbers must agree, and
# tests/multi-agent-timeout/verify.sh gates all of them:
#   - these constants
#   - the --timeout line in this file's header (rendered verbatim as --help)
#   - scripts/agent-config.yaml (tasks.*.timeout)
#   - adapters/adapter-common.sh's REVIEW_TIMEOUT default, for a direct adapter run
#   - the user-facing docs (skills/multi-review/SKILL.md + two docs-template pages)
#
# Review is 900s because 300s did not fit reality: a Codex `exec` review of a
# medium diff (3 files, +881/-14) was still working when the limit fired, so the
# task produced nothing at all (issue #152). Measured after the fix, four runs of
# that same review completed in 299-373s — straddling the old default, so the same
# shape of diff used to succeed or fail by chance. 900s is ~2.4x the longest
# measurement, and matches implement. A generous limit is close to free now that run_with_timeout returns as
# soon as the CLI answers; before that fix, on hosts without timeout(1) (stock
# macOS), every run paid the full limit regardless, which is why raising this
# number used to be unaffordable.
readonly DEFAULT_TIMEOUT_REVIEW=900
readonly DEFAULT_TIMEOUT_EXPLORE=600
readonly DEFAULT_TIMEOUT_IMPLEMENT=900

get_default_timeout() {
  case "$1" in
    review)    echo "$DEFAULT_TIMEOUT_REVIEW" ;;
    explore)   echo "$DEFAULT_TIMEOUT_EXPLORE" ;;
    implement) echo "$DEFAULT_TIMEOUT_IMPLEMENT" ;;
    *)         echo "$DEFAULT_TIMEOUT_REVIEW" ;;
  esac
}

# ── Per-CLI Timeout Caps ──
# Some CLIs cannot be given the full budget. Cursor's --print mode has a known
# non-interactive hang, so it is capped so one CLI cannot sit on the whole run.
#
# The cap lives HERE, not only in the adapter, because the orchestrator is what
# reports and advises about timeouts. When the adapter capped silently, a
# cursor-cli task that stopped at 120s was logged as "Timed out after 900s" and
# the printed remedy was `--timeout 1800` — which the adapter clamped straight
# back to 120, so following the advice changed nothing. Empty means no cap.
# cursor-cli-adapter.sh keeps the same cap for direct invocation; the two values
# are gated against each other by tests/multi-agent-timeout/verify.sh.
#
# Test seam: FF_CURSOR_TIMEOUT_CAP lowers the cap. Without it the *application* of
# the cap (capping, reporting the capped number, advising that --timeout cannot
# extend it) is untestable — pinning it behaviourally would cost a 120s hang, so
# the suite only checked that the two constants matched. Same seam shape as
# FF_TIMEOUT_KILL_GRACE in adapters/adapter-common.sh.
readonly CURSOR_TIMEOUT_CAP="${FF_CURSOR_TIMEOUT_CAP:-120}"

get_cli_timeout_cap() {
  case "$1" in
    cursor-cli) echo "$CURSOR_TIMEOUT_CAP" ;;
    *)          echo "" ;;
  esac
}

# The limit that will actually apply to this CLI.
get_effective_timeout() {
  local cap
  cap="$(get_cli_timeout_cap "$1")"
  if [[ -n "$cap" && "$TIMEOUT" -gt "$cap" ]]; then
    echo "$cap"
  else
    echo "$TIMEOUT"
  fi
}

get_default_strategy() {
  case "$1" in
    review)    echo "balanced" ;;
    explore)   echo "minimize_cost" ;;
    implement) echo "maximize_quality" ;;
    *)         echo "balanced" ;;
  esac
}

get_task_emoji() {
  case "$1" in
    review)    echo "🔍" ;;
    explore)   echo "🔭" ;;
    implement) echo "🛠️" ;;
    *)         echo "🔍" ;;
  esac
}

# ── Defaults ──
TASK_TYPE="review"
DESCRIPTION=""
INCLUDE_DIFF=false
CONFIG_FILE="${MULTI_AGENT_CONFIG:-}"
CONFIG_SOURCE="MULTI_AGENT_CONFIG env"
if [[ -z "$CONFIG_FILE" ]]; then
  if [[ -f "${REPO_ROOT}/.claude/agent-config.yaml" ]]; then
    CONFIG_FILE="${REPO_ROOT}/.claude/agent-config.yaml"
    CONFIG_SOURCE="project override"
  else
    CONFIG_FILE="${SCRIPT_DIR}/agent-config.yaml"
    CONFIG_SOURCE="plugin default"
  fi
fi
MODE="distributed"
STRATEGY=""
PARALLEL=true
OUTPUT_DIR=""
# Whether --output-dir was given, so the retry advice can carry it (the value
# itself is always set later by apply_task_defaults, so it cannot be inferred).
OUTPUT_DIR_EXPLICIT=false
# NOTE: keep this detection in sync with detect_base_branch() in adapters/adapter-common.sh
BASE_BRANCH="${MULTI_AGENT_BASE_BRANCH:-}"
BASE_BRANCH_SOURCE="MULTI_AGENT_BASE_BRANCH env"
if [[ -z "$BASE_BRANCH" ]]; then
  BASE_BRANCH="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)"
  BASE_BRANCH_SOURCE="auto-detected from origin/HEAD"
fi
if [[ -z "$BASE_BRANCH" ]]; then
  BASE_BRANCH="develop"
  BASE_BRANCH_SOURCE="fallback — origin/HEAD not set"
fi
# Prefer the local branch; fall back to the remote-tracking ref when absent (clones)
if ! git rev-parse --verify --quiet "refs/heads/${BASE_BRANCH}" >/dev/null 2>&1; then
  if git rev-parse --verify --quiet "refs/remotes/origin/${BASE_BRANCH}" >/dev/null 2>&1; then
    BASE_BRANCH="origin/${BASE_BRANCH}"
  fi
fi
DRY_RUN=false
TIMEOUT=""

# Space-separated filter lists (bash 3.2 compatible)
CLI_FILTER=""
PERSPECTIVE_FILTER=""

# Detected available CLIs (space-separated)
AVAILABLE_CLIS=""

# Execution plan: CLI_NAME:PERSPECTIVE pairs (newline-separated)
EXECUTION_PLAN=""

# Tasks that failed this run, as "cli/perspective:exit_code" (space-separated).
# Drives the retry advice printed after execution — a bare count leaves the user to
# work out which CLI to re-run and with what, which is exactly the moment they
# reach for a runtime fallback that does not exist. The exit code rides along
# because the right advice depends on it: more time helps a timeout and is useless
# for expired credentials. cli/perspective are validated single path segments and
# cannot contain ':', so the suffix is unambiguous.
FAILED_TASKS=""

# ── Utility ──

list_contains() {
  local list="$1" item="$2"
  for i in $list; do
    [[ "$i" == "$item" ]] && return 0
  done
  return 1
}

# ── Usage ──
show_help() {
  sed -n '/^# Usage:/,/^# See:/{/^# See:/d; s/^# \{0,1\}//; p;}' "$0"
  exit 0
}

# ── Argument Parsing ──
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task)        TASK_TYPE="$2"; shift 2 ;;
      --description) DESCRIPTION="$2"; shift 2 ;;
      --include-diff) INCLUDE_DIFF=true; shift ;;
      --config)      CONFIG_FILE="$2"; CONFIG_SOURCE="--config flag"; shift 2 ;;
      --mode)        MODE="$2"; shift 2 ;;
      --strategy)    STRATEGY="$2"; shift 2 ;;
      --cli)         CLI_FILTER="${CLI_FILTER:+$CLI_FILTER }$2"; shift 2 ;;
      --perspective) PERSPECTIVE_FILTER="${PERSPECTIVE_FILTER:+$PERSPECTIVE_FILTER }$2"; shift 2 ;;
      --parallel)    PARALLEL=true; shift ;;
      --sequential)  PARALLEL=false; shift ;;
      --output-dir)  OUTPUT_DIR="$2"; OUTPUT_DIR_EXPLICIT=true; shift 2 ;;
      --base)        BASE_BRANCH="$2"; BASE_BRANCH_SOURCE="--base flag"; shift 2 ;;
      --dry-run)     DRY_RUN=true; shift ;;
      --timeout)     TIMEOUT="$2"; shift 2 ;;
      --help|-h)     show_help ;;
      *)
        echo "Unknown option: $1" >&2
        echo "Run with --help for usage" >&2
        exit 1
        ;;
    esac
  done

  # Validate task type
  case "$TASK_TYPE" in
    review|explore|implement) ;;
    *)
      echo "ERROR: Invalid task type: '${TASK_TYPE}'. Must be review, explore, or implement." >&2
      exit 1
      ;;
  esac

  # Validate description for explore/implement
  if [[ "$TASK_TYPE" != "review" && -z "$DESCRIPTION" && "$DRY_RUN" == "false" ]]; then
    echo "ERROR: --description is required for ${TASK_TYPE} tasks." >&2
    exit 1
  fi
}

# ── Config Loading (v1/v2 compatible) ──
load_config() {
  # Fall back to review-config.yaml if agent-config.yaml doesn't exist
  if [[ ! -f "$CONFIG_FILE" ]]; then
    # An explicitly requested config that is missing must fail loud — silently
    # substituting defaults would run with settings the user did not choose.
    if [[ "$CONFIG_SOURCE" == "--config flag" || "$CONFIG_SOURCE" == "MULTI_AGENT_CONFIG env" ]]; then
      echo "ERROR: config file not found: $CONFIG_FILE (from ${CONFIG_SOURCE})" >&2
      exit 1
    fi
    local fallback_config="${SCRIPT_DIR}/review-config.yaml"
    if [[ -f "$fallback_config" ]]; then
      echo "ℹ️  Using legacy config: $fallback_config" >&2
      CONFIG_FILE="$fallback_config"
      CONFIG_SOURCE="legacy review-config.yaml"
    else
      echo "⚠️  Config file not found: $CONFIG_FILE (using defaults)" >&2
      return 0
    fi
  fi

  if command -v yq &>/dev/null; then
    if ! yq '.' "$CONFIG_FILE" >/dev/null 2>&1; then
      echo "⚠️  Config file could not be parsed by yq. Using defaults." >&2
      return 0
    fi

    local cfg_val
    cfg_val=$(yq -r '.mode // ""' "$CONFIG_FILE" 2>/dev/null || true)
    [[ -n "$cfg_val" ]] && MODE="$cfg_val"

    cfg_val=$(yq -r '.parallel // ""' "$CONFIG_FILE" 2>/dev/null || true)
    [[ "$cfg_val" == "true" ]] && PARALLEL=true
    [[ "$cfg_val" == "false" ]] && PARALLEL=false

    # v2: task-specific config
    local version
    version=$(yq -r '.version // "1.0"' "$CONFIG_FILE" 2>/dev/null || true)

    if [[ "$version" == "2.0" ]]; then
      # Read task-specific settings
      cfg_val=$(yq -r ".tasks.${TASK_TYPE}.cost_strategy // \"\"" "$CONFIG_FILE" 2>/dev/null || true)
      [[ -n "$cfg_val" && -z "$STRATEGY" ]] && STRATEGY="$cfg_val"

      cfg_val=$(yq -r ".tasks.${TASK_TYPE}.timeout // \"\"" "$CONFIG_FILE" 2>/dev/null || true)
      [[ -n "$cfg_val" && -z "$TIMEOUT" ]] && TIMEOUT="$cfg_val"

      cfg_val=$(yq -r ".tasks.${TASK_TYPE}.output_dir // \"\"" "$CONFIG_FILE" 2>/dev/null || true)
      [[ -n "$cfg_val" && -z "$OUTPUT_DIR" ]] && OUTPUT_DIR="${REPO_ROOT}/${cfg_val}"
    else
      # v1 compatibility
      cfg_val=$(yq -r '.cost_strategy // ""' "$CONFIG_FILE" 2>/dev/null || true)
      [[ -n "$cfg_val" && -z "$STRATEGY" ]] && STRATEGY="$cfg_val"

      cfg_val=$(yq -r '.timeout // ""' "$CONFIG_FILE" 2>/dev/null || true)
      [[ -n "$cfg_val" && -z "$TIMEOUT" ]] && TIMEOUT="$cfg_val"

      cfg_val=$(yq -r '.output_dir // ""' "$CONFIG_FILE" 2>/dev/null || true)
      [[ -n "$cfg_val" && -z "$OUTPUT_DIR" ]] && OUTPUT_DIR="${REPO_ROOT}/${cfg_val}"
    fi
  else
    echo "ℹ️  yq not found — using defaults. Install yq for config file support." >&2
  fi
  return 0  # last &&-list may legitimately be false — don't let set -e kill the script
}

# ── Apply task-type defaults (after config + CLI args) ──
apply_task_defaults() {
  [[ -z "$OUTPUT_DIR" ]] && OUTPUT_DIR="$(get_default_output_dir "$TASK_TYPE")"
  [[ -z "$TIMEOUT" ]] && TIMEOUT="$(get_default_timeout "$TASK_TYPE")"
  [[ -z "$STRATEGY" ]] && STRATEGY="$(get_default_strategy "$TASK_TYPE")"
  return 0  # last &&-list may legitimately be false — don't let set -e kill the script
}

# ── CLI Detection ──
detect_available_clis() {
  AVAILABLE_CLIS=""
  local cli_name cmd

  for cli_name in $ALL_CLIS; do
    cmd="$(get_cli_command "$cli_name")"
    if command -v "$cmd" &>/dev/null; then
      AVAILABLE_CLIS="${AVAILABLE_CLIS:+$AVAILABLE_CLIS }$cli_name"
      echo "  ✅ ${cli_name} (${cmd})" >&2
    else
      echo "  ❌ ${cli_name} (${cmd}) — not installed" >&2
    fi
  done

  if [[ -z "$AVAILABLE_CLIS" ]]; then
    echo "" >&2
    echo "ERROR: No AI CLIs are installed. Install at least one:" >&2
    echo "  npm install -g @anthropic-ai/claude-code" >&2
    echo "  npm install -g @openai/codex" >&2
    echo "  npm install -g @google/gemini-cli" >&2
    exit 1
  fi
}

# ── Add to Execution Plan ──
add_to_plan() {
  local cli_name="$1" perspective="$2"
  EXECUTION_PLAN="${EXECUTION_PLAN:+$EXECUTION_PLAN
}${cli_name}:${perspective}"
}

# ── Build Execution Plan (distributed mode) ──
build_distributed_plan() {
  EXECUTION_PLAN=""
  local cli_name perspectives fallback_target

  for cli_name in $ALL_CLIS; do
    perspectives="$(get_cli_perspectives "$cli_name")"
    [[ -z "$perspectives" ]] && continue

    # Copilot CLI is metered — include in review plans only when explicitly requested via --cli
    if [[ "$cli_name" == "copilot-cli" && "$TASK_TYPE" == "review" && -z "$CLI_FILTER" ]]; then
      echo "  ⏭  copilot-cli skipped (metered). Opt in with --cli copilot-cli." >&2
      continue
    fi

    if [[ -n "$CLI_FILTER" ]] && ! list_contains "$CLI_FILTER" "$cli_name"; then
      continue
    fi

    if list_contains "$AVAILABLE_CLIS" "$cli_name"; then
      # When both filters are explicit, the pair is the user's execution intent.
      # This is also the shape printed by failure advice for a substitute CLI:
      # forcing it back through the ownership registry can otherwise produce an
      # empty plan (for example codex-cli + security-analysis).
      if [[ -n "$CLI_FILTER" && "$CLI_FILTER" != *" "* \
            && -n "$PERSPECTIVE_FILTER" && "$PERSPECTIVE_FILTER" != *" "* ]]; then
        for p in $PERSPECTIVE_FILTER; do
          add_to_plan "$cli_name" "$p"
        done
      else
        local matched_perspective=false
        for p in $perspectives; do
          if [[ -n "$PERSPECTIVE_FILTER" ]] && ! list_contains "$PERSPECTIVE_FILTER" "$p"; then
            continue
          fi
          add_to_plan "$cli_name" "$p"
          matched_perspective=true
        done

        # Availability and perspective ownership are different facts. Surface
        # the latter so an installed CLI is not mistaken for missing.
        if [[ -n "$PERSPECTIVE_FILTER" && "$matched_perspective" == "false" ]]; then
          if [[ "$PERSPECTIVE_FILTER" == *" "* ]]; then
            echo "  ⏭  ${cli_name} skipped — owns none of the requested perspectives (${PERSPECTIVE_FILTER})" >&2
          else
            echo "  ⏭  ${cli_name} skipped — owns no '${PERSPECTIVE_FILTER}' perspective" >&2
          fi
          echo "     (has: ${perspectives}). Use --mode cross-model to include it." >&2
        fi
      fi
    else
      fallback_target="$(get_cli_fallback "$cli_name")"
      if [[ -n "$fallback_target" ]] && list_contains "$AVAILABLE_CLIS" "$fallback_target"; then
        if [[ -n "$CLI_FILTER" ]] && ! list_contains "$CLI_FILTER" "$fallback_target"; then
          echo "  ⚠️  ${cli_name}: fallback ${fallback_target} excluded by --cli filter. Skipping." >&2
          continue
        fi
        echo "  ↪ ${cli_name} → ${fallback_target} (fallback — ${cli_name} not installed)" >&2
        for p in $perspectives; do
          if [[ -n "$PERSPECTIVE_FILTER" ]] && ! list_contains "$PERSPECTIVE_FILTER" "$p"; then
            continue
          fi
          add_to_plan "$fallback_target" "$p"
        done
      else
        echo "  ⚠️  ${cli_name}: No fallback available. Skipping: ${perspectives}" >&2
      fi
    fi
  done

  # Apply cost strategy: minimize_cost moves premium → flat-rate
  if [[ "$STRATEGY" == "minimize_cost" && -z "$CLI_FILTER" ]]; then
    local new_plan=""
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      local cli="${entry%%:*}"
      local persp="${entry#*:}"
      if [[ "$cli" == "claude-code" ]] && list_contains "$AVAILABLE_CLIS" "cursor-cli"; then
        echo "  💰 minimize_cost: ${persp}: claude-code → cursor-cli" >&2
        new_plan="${new_plan:+$new_plan
}cursor-cli:${persp}"
      else
        new_plan="${new_plan:+$new_plan
}${entry}"
      fi
    done <<< "$EXECUTION_PLAN"
    EXECUTION_PLAN="$new_plan"
  fi
}

# ── Build Execution Plan (cross-model mode) ──
build_cross_model_plan() {
  EXECUTION_PLAN=""
  local perspective="${PERSPECTIVE_FILTER:-code-review}"
  perspective="${perspective%% *}"

  echo "  🔄 Cross-model mode: all CLIs run '${perspective}'" >&2

  for cli_name in $AVAILABLE_CLIS; do
    if [[ -n "$CLI_FILTER" ]] && ! list_contains "$CLI_FILTER" "$cli_name"; then
      continue
    fi
    # Copilot CLI is metered — include only when explicitly requested via --cli
    if [[ "$cli_name" == "copilot-cli" && -z "$CLI_FILTER" ]]; then
      echo "  ⏭  copilot-cli skipped (metered). Opt in with --cli copilot-cli." >&2
      continue
    fi
    add_to_plan "$cli_name" "$perspective"
  done
}

# ── Validate Requested Perspectives ──
# A dry-run is a plan validation boundary, not only a pretty-printer. Reject an
# unsafe, unknown, or other-task perspective before showing a successful plan;
# otherwise the same command fails only after a real CLI dispatch is attempted.
validate_requested_perspectives() {
  local perspective perspective_file
  for perspective in $PERSPECTIVE_FILTER; do
    if ! is_safe_token "$perspective"; then
      echo "ERROR: unsafe perspective name: '${perspective}'" >&2
      return 1
    fi
    perspective_file="$(resolve_perspective_file "$perspective")"
    if [[ -z "$perspective_file" ]]; then
      echo "ERROR: perspective '${perspective}' does not exist for task '${TASK_TYPE}'." >&2
      return 1
    fi
  done
}

# ── Show Execution Plan ──
show_plan() {
  local emoji
  emoji="$(get_task_emoji "$TASK_TYPE")"

  echo "" >&2
  echo "📋 Execution Plan:" >&2
  echo "   Task: ${TASK_TYPE} ${emoji}" >&2
  echo "   Mode: ${MODE}" >&2
  echo "   Strategy: ${STRATEGY}" >&2
  echo "   Parallel: ${PARALLEL}" >&2
  echo "   Output: ${OUTPUT_DIR}" >&2
  echo "   Base branch: ${BASE_BRANCH} (${BASE_BRANCH_SOURCE})" >&2
  echo "   Config: ${CONFIG_FILE} (${CONFIG_SOURCE})" >&2
  echo "   Timeout: ${TIMEOUT}s per CLI" >&2
  echo "   Runtime fallback: none — a CLI that fails or times out is reported as" >&2
  echo "                     failed, never retried on another model (see --help)" >&2
  if [[ -n "$DESCRIPTION" ]]; then
    echo "   Description: ${DESCRIPTION}" >&2
  fi
  echo "" >&2

  if [[ -z "$EXECUTION_PLAN" ]]; then
    echo "   ⚠️  No CLIs/perspectives to execute." >&2
    return
  fi

  local current_cli=""
  local planned_clis=""
  local planned_cli_count=0
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    local cli="${entry%%:*}"
    local persp="${entry#*:}"
    if ! list_contains "$planned_clis" "$cli"; then
      planned_clis="${planned_clis:+$planned_clis }$cli"
      planned_cli_count=$((planned_cli_count + 1))
    fi
    if [[ "$cli" != "$current_cli" ]]; then
      current_cli="$cli"
      local tier
      tier="$(get_cli_cost_tier "$cli")"
      echo "   ${cli} [${tier}]:" >&2
    fi
    echo "     - ${persp}" >&2
  done <<< "$EXECUTION_PLAN"

  # An explicit --cli is intentionally single-model and should stay quiet.
  # Cross-model mode is already the remedy, so this warning only applies when a
  # distributed review resolved implicitly to one CLI.
  if [[ "$TASK_TYPE" == "review" && "$MODE" == "distributed" \
        && -z "$CLI_FILTER" && "$planned_cli_count" -eq 1 ]]; then
    echo "" >&2
    echo "   ⚠️  Plan resolved to a single CLI (${planned_clis}). A failure or timeout here" >&2
    echo "       means zero review coverage — runtime fallback is deliberately absent." >&2
    if [[ "$PERSPECTIVE_FILTER" == *" "* ]]; then
      echo "       For cross-model coverage, run each perspective separately:" >&2
      local requested_perspective
      for requested_perspective in $PERSPECTIVE_FILTER; do
        echo "         --mode cross-model --perspective ${requested_perspective}" >&2
      done
    else
      echo "       For cross-model coverage: --mode cross-model --perspective ${PERSPECTIVE_FILTER:-code-review}" >&2
    fi
  fi
  echo "" >&2
}

# ── Resolve perspective file path (task-type aware) ──
resolve_perspective_file() {
  local perspective="$1"

  # Try task-type subdirectory first
  local subdir_file="${SCRIPT_DIR}/perspectives/${TASK_TYPE}/${perspective}.md"
  if [[ -f "$subdir_file" ]]; then
    echo "$subdir_file"
    return
  fi

  # Fall back to root perspectives (backward compat)
  local root_file="${SCRIPT_DIR}/perspectives/${perspective}.md"
  if [[ -f "$root_file" ]]; then
    echo "$root_file"
    return
  fi

  echo ""
}

# ── Execute Single Task ──
run_single_task() {
  local cli_name="$1"
  local perspective="$2"

  local adapter
  adapter="$(get_cli_adapter "$cli_name")"

  local perspective_file
  perspective_file="$(resolve_perspective_file "$perspective")"
  local output_file="${OUTPUT_DIR}/${cli_name}/${perspective}.md"

  if [[ -z "$perspective_file" ]]; then
    echo "  ⚠️  Perspective file not found: ${TASK_TYPE}/${perspective}.md" >&2
    return 1
  fi

  if [[ ! -f "$adapter" ]]; then
    echo "  ⚠️  Adapter not found: ${adapter}" >&2
    return 1
  fi

  local extra_args=()
  extra_args+=(--task-type "$TASK_TYPE")
  if [[ -n "$DESCRIPTION" ]]; then
    extra_args+=(--description "$DESCRIPTION")
  fi
  if [[ "$INCLUDE_DIFF" == "true" ]]; then
    extra_args+=(--include-diff)
  fi

  bash "$adapter" "$perspective_file" "$output_file" \
    --base "$BASE_BRANCH" \
    --timeout "$(get_effective_timeout "$cli_name")" \
    "${extra_args[@]}"
}

# ── Path-Segment Safety ──
# A CLI / perspective name is used as a single path segment under OUTPUT_DIR.
# Reject anything that is not a plain identifier so a crafted --cli/--perspective
# value (e.g. "../../secret") cannot escape OUTPUT_DIR when we build result paths.
is_safe_token() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] && [[ "$1" != "." && "$1" != ".." ]]
}

# ── Validate Execution Plan ──
# Fail loud (never a silent skip) if any plan entry carries a cli/perspective
# token that is not a safe single path segment. Called once at each consumption
# entry point (execute_tasks, generate_report) BEFORE the plan is used, so a
# crafted --cli/--perspective value cannot reach the execute (write), cleanup, or
# report (read) paths and escape OUTPUT_DIR — and a malformed plan surfaces as an
# error instead of silently collapsing to "(No results found.)".
validate_execution_plan() {
  local entry cli_name persp_name bad=0
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    # Require the exact "cli:perspective" shape. Without a ':', ${entry%%:*} and
    # ${entry#*:} both collapse to the whole string, so a malformed entry would
    # otherwise pass and drive read/delete/write at the wrong path.
    if [[ "$entry" != *:* ]]; then
      echo "ERROR: malformed execution plan entry (expected 'cli:perspective'): '${entry}'" >&2
      bad=1
      continue
    fi
    cli_name="${entry%%:*}"
    persp_name="${entry#*:}"
    if ! is_safe_token "$cli_name" || ! is_safe_token "$persp_name"; then
      echo "ERROR: unsafe token in execution plan entry: '${entry}'" >&2
      bad=1
    fi
  done <<< "$EXECUTION_PLAN"
  [[ "$bad" -eq 0 ]]
}

# ── Clear This Run's Planned Outputs ──
# The report reads ${cli}/${perspective}.md for each plan entry; adapters only
# (over)write that file on success, leaving a prior run's file in place on
# failure/timeout. Deleting exactly this run's own targets up front means a task
# that produces no output leaves NO stale same-name file to be mis-reported as
# current (issue #450) — instead the report surfaces it as "no output". Scoped to
# the plan's own (cli, perspective) targets only; nothing else on disk (other
# CLIs, other perspectives, unrelated user files) is touched. Callers run
# validate_execution_plan first, so every token here is already a safe segment.
clear_planned_outputs() {
  [[ -n "${OUTPUT_DIR:-}" ]] || return 0
  local entry cli_name persp_name
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    cli_name="${entry%%:*}"
    persp_name="${entry#*:}"
    rm -f "${OUTPUT_DIR}/${cli_name}/${persp_name}.md"
  done <<< "$EXECUTION_PLAN"
}

# ── Execute All Tasks ──
execute_tasks() {
  if [[ -z "$EXECUTION_PLAN" ]]; then
    echo "Nothing to execute." >&2
    return 0
  fi

  # Reject a plan with unsafe path segments before writing/deleting anything.
  validate_execution_plan || return 1

  mkdir -p "$OUTPUT_DIR"
  clear_planned_outputs

  local pids=""
  local tasks=""
  local failed=0
  local count=0
  local seen=""
  FAILED_TASKS=""

  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    # Skip a duplicate plan entry so the same cli:perspective is not executed
    # twice (a plan fallback can list it more than once).
    if [[ " $seen " == *" $entry "* ]]; then continue; fi
    seen="$seen $entry"
    local cli="${entry%%:*}"
    local persp="${entry#*:}"

    if [[ "$PARALLEL" == "true" ]]; then
      run_single_task "$cli" "$persp" &
      pids="${pids:+$pids }$!"
      tasks="${tasks:+$tasks|}${cli}/${persp}"
      count=$((count + 1))
    else
      echo "▶ ${cli} → ${persp}" >&2
      # Capture the status rather than testing it inline: the parallel branch
      # distinguishes a fired deadline from a crash, and this path has to give the
      # same diagnosis or the reason depends on which mode you happened to run.
      local task_rc=0
      run_single_task "$cli" "$persp" || task_rc=$?
      if [[ $task_rc -ne 0 ]]; then
        failed=$((failed + 1))
        FAILED_TASKS="${FAILED_TASKS:+$FAILED_TASKS }${cli}/${persp}:${task_rc}"
        report_task_failure "${cli}/${persp}" "$cli" "$task_rc"
      elif [[ ! -f "${OUTPUT_DIR}/${cli}/${persp}.md" ]]; then
        # Adapter reported success but wrote no output — count it as a failure so
        # a silently-empty run shows up in the exit code, not only the report.
        failed=$((failed + 1))
        FAILED_TASKS="${FAILED_TASKS:+$FAILED_TASKS }${cli}/${persp}:0"
        echo "  ❌ No output file: ${cli}/${persp}" >&2
      fi
    fi
  done <<< "$EXECUTION_PLAN"

  # Wait for parallel tasks
  if [[ "$PARALLEL" == "true" && -n "$pids" ]]; then
    echo "⏳ Waiting for ${count} parallel ${TASK_TYPE} tasks..." >&2
    local idx=0
    local exit_code
    set +e
    for pid in $pids; do
      idx=$((idx + 1))
      local task_name
      task_name="$(echo "$tasks" | cut -d'|' -f"$idx")"
      wait "$pid"
      exit_code=$?
      if [[ $exit_code -eq 0 && -f "${OUTPUT_DIR}/${task_name}.md" ]]; then
        echo "  ✅ Done: ${task_name}" >&2
      elif [[ $exit_code -ne 0 ]]; then
        failed=$((failed + 1))
        FAILED_TASKS="${FAILED_TASKS:+$FAILED_TASKS }${task_name}:${exit_code}"
        report_task_failure "$task_name" "${task_name%%/*}" "$exit_code"
      else
        # Success exit but no output file — surface as a failure, not silent OK.
        failed=$((failed + 1))
        FAILED_TASKS="${FAILED_TASKS:+$FAILED_TASKS }${task_name}:0"
        echo "  ❌ No output file: ${task_name}" >&2
      fi
    done
    set -e
  fi

  echo "" >&2
  if [[ $failed -gt 0 ]]; then
    echo "⚠️  ${failed} ${TASK_TYPE} task(s) failed." >&2
    print_failure_advice
    return 1
  else
    echo "✅ All ${TASK_TYPE} tasks completed successfully." >&2
  fi
}

# ── One-Line Failure Diagnosis ──
# Reports the limit that ACTUALLY applied to this CLI, not the run-wide setting:
# a capped CLI (see get_cli_timeout_cap) stops earlier, and naming the run-wide
# number there tells the user a deadline fired that never existed.
# 124 is run_with_timeout's timeout status (see adapters/adapter-common.sh).
report_task_failure() {
  local task_name="$1" cli_name="$2" rc="$3"
  if [[ "$rc" -eq 124 ]]; then
    echo "  ❌ Timed out after $(get_effective_timeout "$cli_name")s: ${task_name}" >&2
  else
    echo "  ❌ Failed: ${task_name} (exit code: ${rc})" >&2
  fi
}

# ── Retry Advice For Failed Tasks ──
# A failed task is never re-dispatched to another CLI (see "Fallback semantics"
# in the header). That is only a defensible default if the user is handed the
# commands they would otherwise have wanted the tool to run behind their back,
# so print them: same CLI with more time, or the configured substitute — named
# explicitly, with its cost tier, as a choice rather than a surprise.
print_failure_advice() {
  [[ -n "$FAILED_TASKS" ]] || return 0

  # Absolute path, not basename: this script normally lives inside an installed
  # plugin and is invoked from the target project, where no same-named file
  # exists. A bare `bash multi-agent.sh ...` would fail the moment it is pasted.
  # printf %q keeps a path with spaces runnable.
  local self
  self="bash $(printf '%q' "${SCRIPT_DIR}/multi-agent.sh") --task ${TASK_TYPE}"
  # Carry the flags that decide WHAT gets looked at. Dropping --base would retry
  # against a different diff than the run that just failed, which makes the
  # suggested command quietly not-a-retry.
  if [[ "$TASK_TYPE" == "review" || "$INCLUDE_DIFF" == "true" ]]; then
    self="${self} --base $(printf '%q' "$BASE_BRANCH")"
  fi
  if [[ "$INCLUDE_DIFF" == "true" ]]; then
    # Without this the retry builds a prompt with no diff in it — a different task,
    # not a retry of the one that failed.
    self="${self} --include-diff"
  fi
  if [[ "$CONFIG_SOURCE" == "--config flag" || "$CONFIG_SOURCE" == "MULTI_AGENT_CONFIG env" ]]; then
    self="${self} --config $(printf '%q' "$CONFIG_FILE")"
  fi
  if [[ "$OUTPUT_DIR_EXPLICIT" == "true" ]]; then
    self="${self} --output-dir $(printf '%q' "$OUTPUT_DIR")"
  fi
  if [[ -n "$DESCRIPTION" ]]; then
    self="${self} --description $(printf '%q' "$DESCRIPTION")"
  fi

  echo "" >&2
  echo "   No runtime fallback was attempted (by design: swapping the model changes" >&2
  echo "   what got reviewed, and the substitute may bill a costlier tier)." >&2
  echo "   Re-run the failed task(s) yourself:" >&2

  local entry task rc cli persp fb fb_tier cap
  for entry in $FAILED_TASKS; do
    task="${entry%:*}"
    rc="${entry##*:}"
    cli="${task%%/*}"
    persp="${task#*/}"
    echo "" >&2
    # Only a timeout is helped by a longer limit. Offering it for expired
    # credentials or a crash sends the user off to wait twice as long for the
    # identical failure.
    if [[ "$rc" -eq 124 ]]; then
      cap="$(get_cli_timeout_cap "$cli")"
      if [[ -n "$cap" ]]; then
        echo "     ${task} — ${cli} is capped at ${cap}s (known non-interactive hang), so" >&2
        echo "       --timeout cannot extend it. Use a different CLI for this perspective." >&2
      else
        echo "     ${task} — more time on the same CLI:" >&2
        echo "       $(model_env_prefix "$cli")${self} --cli ${cli} --perspective ${persp} --timeout $((TIMEOUT * 2))" >&2
      fi
    else
      echo "     ${task} — failed for a reason more time will not fix; read the CLI" >&2
      echo "       stderr in ${OUTPUT_DIR}/${cli}/${persp}.md, then re-run:" >&2
      echo "       $(model_env_prefix "$cli")${self} --cli ${cli} --perspective ${persp}" >&2
    fi
    fb="$(get_cli_fallback "$cli")"
    if [[ -n "$fb" ]] && list_contains "$AVAILABLE_CLIS" "$fb"; then
      fb_tier="$(get_cli_cost_tier "$fb")"
      echo "     ${task} — or the configured substitute ${fb} [${fb_tier}]:" >&2
      # 代替 CLI の行には代替 CLI に効く env だけを前置する（失敗した CLI の
      # モデル指定を持ち越すと、実際には使われない設定を使うかのように読める）
      echo "       $(model_env_prefix "$fb")${self} --cli ${fb} --perspective ${persp}" >&2
    fi
  done
}

# ── Report Body (shared by review / explore / implement) ──
# Appends one section per plan entry to $1. Returns 0 if at least one section was
# written, 1 if the plan yielded none (the caller prints its own "no results" line).
#
# issue #450: report exactly THIS run's entries by iterating the execution plan
# instead of globbing ${cli}/*.md. A perspective absent from this plan is never
# read. In the normal flow execute_tasks clears each entry's target before
# running (clear_planned_outputs), so a prior run's result — a different
# perspective, or a same-named stale file left by a failed task — does not
# appear as current. The report only reads result files and writes report_file;
# no result file is deleted or modified here, so a shared --output-dir re-run or
# a partial --cli/--perspective run is non-destructive. A planned entry with no
# output file (CLI failure) is surfaced, not silently dropped. Callers must pass
# only validated plan entries — today every caller reaches here via
# generate_report, which runs validate_execution_plan first.
#
# This was three byte-identical copies, one per task type. The incomplete-result
# banner below has to be on every path — a truncated review that reads as a clean
# one is the failure mode issue #152 is about — so there is one copy to change.
append_plan_sections() {
  local report_file="$1"
  local wrote_any=1

  local entry seen=""
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    # Skip a duplicate plan entry so a repeated cli:perspective (e.g. a plan
    # fallback that reassigns a perspective to an already-listed CLI) is not
    # pasted into the report twice.
    if [[ " $seen " == *" $entry "* ]]; then continue; fi
    seen="$seen $entry"
    local cli_name="${entry%%:*}"
    local perspective_name="${entry#*:}"
    local result_file="${OUTPUT_DIR}/${cli_name}/${perspective_name}.md"
    wrote_any=0

    local tier
    tier="$(get_cli_cost_tier "$cli_name")"

    {
      echo ""
      echo "## ${cli_name} — ${perspective_name} [${tier}]"
      echo ""
      if [[ -f "$result_file" ]]; then
        # An adapter marks salvaged partial output with `Status: incomplete`
        # (adapters/adapter-common.sh). Repeat that in the report: without it the
        # section looks like any other and its silence reads as "found nothing"
        # rather than "never got there".
        #
        # Scoped to the header block, because a *complete* review whose body
        # quotes that marker line would otherwise be flagged incomplete — very
        # reachable here, where the tool reviews its own scripts.
        #
        # The scope ends at the first blank line, which is what separates
        # write_output's header from the body. A fixed line count would silently
        # drift the wrong way if the header ever gained a line: the marker would
        # fall outside the window and an incomplete result would read as complete.
        #
        # Done with awk rather than `head | grep -q`: grep's early exit SIGPIPEs
        # head, and under pipefail the pipeline returns 141, flipping a match into
        # a non-match (the inversion class recorded in ACE-149).
        if awk '/^$/ { exit } /^<!-- Status: incomplete -->$/ { found = 1 } END { exit found ? 0 : 1 }' "$result_file"; then
          echo "⚠️ **INCOMPLETE** — the CLI failed or timed out; what follows is partial"
          echo "output salvaged from that run, not a finished ${TASK_TYPE}. Absence of a"
          echo "finding here means unchecked, not clean."
          echo ""
        fi
        cat "$result_file"
      else
        echo "⚠️ No output produced by this task — the CLI failed before writing any"
        echo "result. See the orchestrator log for the reason and the retry command."
      fi
      echo ""
      echo "---"
      echo ""
    } >> "$report_file"
  done <<< "$EXECUTION_PLAN"

  return "$wrote_any"
}

# ── Generate Report (review) ──
generate_review_report() {
  local report_file="${OUTPUT_DIR}/integrated-report.md"

  echo "📝 Generating integrated review report..." >&2

  cat > "$report_file" <<HEADER
# Multi-CLI Review — Integrated Report

**Generated:** $(date -u +"%Y-%m-%dT%H:%M:%SZ")
**Mode:** ${MODE}
**Strategy:** ${STRATEGY}
**Base Branch:** ${BASE_BRANCH}

---

HEADER

  local has_results=true
  append_plan_sections "$report_file" || has_results=false

  if [[ "$has_results" == "false" ]]; then
    echo "(No review results found.)" >> "$report_file"
  fi

  if grep -qE '^\s*-\s*\[.*:.*\]|^CRITICAL:|Critical:\s*[1-9]' "$report_file" 2>/dev/null; then
    echo "" >> "$report_file"
    echo "<!-- CRITICAL_BLOCK -->" >> "$report_file"
    echo "Critical issues detected. Review before proceeding." >> "$report_file"
  fi

  echo "📄 Report: ${report_file}" >&2
}

# ── Generate Report (explore) ──
generate_explore_report() {
  local report_file="${OUTPUT_DIR}/integrated-report.md"

  echo "📝 Generating integrated explore report..." >&2

  cat > "$report_file" <<HEADER
# Multi-CLI Explore — Integrated Report

**Generated:** $(date -u +"%Y-%m-%dT%H:%M:%SZ")
**Description:** ${DESCRIPTION}
**Mode:** ${MODE}
**Strategy:** ${STRATEGY}

---

HEADER

  local has_results=true
  append_plan_sections "$report_file" || has_results=false

  if [[ "$has_results" == "false" ]]; then
    echo "(No explore results found.)" >> "$report_file"
  fi

  echo "📄 Report: ${report_file}" >&2
}

# ── Generate Report (implement) ──
generate_implement_report() {
  local report_file="${OUTPUT_DIR}/integrated-report.md"

  echo "📝 Generating integrated implement report..." >&2

  cat > "$report_file" <<HEADER
# Multi-CLI Implement — Integrated Report

**Generated:** $(date -u +"%Y-%m-%dT%H:%M:%SZ")
**Description:** ${DESCRIPTION}
**Mode:** ${MODE}
**Strategy:** ${STRATEGY}

---

⚠️ **Implementation results are in staging directory.** Review before applying to working tree.

---

HEADER

  local has_results=true
  append_plan_sections "$report_file" || has_results=false

  if [[ "$has_results" == "false" ]]; then
    echo "(No implement results found.)" >> "$report_file"
  fi

  echo "📄 Report: ${report_file}" >&2
}

# ── Generate Report (dispatcher) ──
generate_report() {
  # Reject a plan with unsafe path segments before any builder reads from it.
  validate_execution_plan || return 1
  case "$TASK_TYPE" in
    review)    generate_review_report ;;
    explore)   generate_explore_report ;;
    implement) generate_implement_report ;;
  esac
}

# ── Main ──
main() {
  local emoji

  # Two-pass parsing: extract --config and --task first
  local prev_flag=""
  for arg in "$@"; do
    if [[ "$prev_flag" == "--config" ]]; then
      CONFIG_FILE="$arg"
      CONFIG_SOURCE="--config flag"
      prev_flag=""
      continue
    fi
    if [[ "$prev_flag" == "--task" ]]; then
      TASK_TYPE="$arg"
      prev_flag=""
      continue
    fi
    if [[ "$arg" == "--config" || "$arg" == "--task" ]]; then
      prev_flag="$arg"
    else
      prev_flag=""
    fi
  done

  load_config
  parse_args "$@"
  apply_task_defaults
  validate_requested_perspectives

  emoji="$(get_task_emoji "$TASK_TYPE")"

  echo "${emoji} Multi-CLI Agent Orchestrator — ${TASK_TYPE}" >&2
  echo "================================================" >&2
  echo "" >&2

  echo "🔎 Detecting available CLIs..." >&2
  detect_available_clis

  echo "" >&2
  echo "📊 Building execution plan..." >&2

  if [[ "$MODE" == "cross-model" ]]; then
    build_cross_model_plan
  else
    build_distributed_plan
  fi

  show_plan

  # Validate TIMEOUT
  if ! echo "$TIMEOUT" | grep -qE '^[0-9]+$' || [[ "$TIMEOUT" -eq 0 ]]; then
    echo "ERROR: --timeout must be a positive integer, got: '${TIMEOUT}'" >&2
    exit 1
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "🏁 Dry run complete. No tasks executed." >&2
    exit 0
  fi

  # ── Pre-dispatch safety: never burn CLI quota on a meaningless diff ──
  if [[ "$TASK_TYPE" == "review" || "$INCLUDE_DIFF" == "true" ]]; then
    if [[ "$IN_GIT_REPO" != "true" ]]; then
      echo "ERROR: task '${TASK_TYPE}' diffs against '${BASE_BRANCH}', but the current directory is not inside a git repository." >&2
      exit 1
    fi
    if ! git rev-parse --verify --quiet "${BASE_BRANCH}^{commit}" >/dev/null 2>&1; then
      echo "ERROR: base branch '${BASE_BRANCH}' does not resolve to a commit." >&2
      echo "       Fix: pass --base <branch>, set MULTI_AGENT_BASE_BRANCH, or run: git remote set-head origin -a" >&2
      exit 1
    fi
  fi
  if [[ "$TASK_TYPE" == "review" ]]; then
    if git diff --quiet "${BASE_BRANCH}...HEAD" 2>/dev/null && git diff --quiet HEAD 2>/dev/null; then
      echo "ERROR: nothing to review — branch diff against '${BASE_BRANCH}' and working-tree changes are both empty." >&2
      exit 1
    fi
  fi

  # Fail loudly on an empty plan — never report success when nothing ran
  if [[ -z "$EXECUTION_PLAN" ]]; then
    echo "ERROR: Execution plan is empty — no CLI/perspective matched the given filters." >&2
    echo "       Check --cli / --perspective / --mode combinations." >&2
    exit 1
  fi

  local task_failed=false
  execute_tasks || task_failed=true
  generate_report

  echo "" >&2
  echo "🏁 Done! View results:" >&2
  echo "   cat ${OUTPUT_DIR}/integrated-report.md" >&2

  if [[ "$task_failed" == "true" ]]; then
    exit 1
  fi
}

main "$@"
