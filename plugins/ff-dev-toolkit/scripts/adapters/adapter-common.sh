#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────
# adapter-common.sh — Multi-CLI Agent: Shared Utilities
# ────────────────────────────────────────────────────────────
# Usage: source this file from any CLI adapter
#   source "$(dirname "$0")/adapter-common.sh"
# ────────────────────────────────────────────────────────────

# Note: Do NOT set -euo pipefail here. This file is source'd by adapters
# which have their own set -euo pipefail. Setting it here would cause
# return 1 in functions to kill the sourcing process under set -e.

# ── Constants ──
readonly SEVERITY_CRITICAL="Critical"
readonly SEVERITY_WARNING="Warning"
readonly SEVERITY_SUGGESTION="Suggestion"
readonly SEVERITY_INFO="Info"

# ── CLI Detection ──

# Check if a CLI command is available
# Usage: cli_available "claude"
cli_available() {
  command -v "$1" &>/dev/null
}

# ── Git Helpers ──

# Detect the repository default branch (origin/HEAD), falling back to "develop".
# Returns a ref usable with `git diff <ref>...HEAD`: prefers the local branch,
# and falls back to the remote-tracking ref when no local branch exists (clones).
detect_base_branch() {
  local b
  b="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)"
  if [[ -z "$b" ]]; then b="develop"; fi
  if git rev-parse --verify --quiet "refs/heads/${b}" >/dev/null; then
    echo "$b"
  elif git rev-parse --verify --quiet "refs/remotes/origin/${b}" >/dev/null; then
    echo "origin/${b}"
  else
    echo "$b"
  fi
}

# Get changed files (staged + unstaged) relative to a base branch
# Usage: get_changed_files "develop"
get_changed_files() {
  local base_branch="${1:-$(detect_base_branch)}"
  if git diff --name-only "${base_branch}...HEAD" 2>/dev/null; then
    return 0
  fi
  echo "WARNING: Could not diff against '${base_branch}', falling back to HEAD diff." >&2
  if git diff --name-only HEAD 2>/dev/null; then
    return 0
  fi
  echo "ERROR: Failed to get changed files. Are you in a git repository with commits?" >&2
  return 1
}

# Get the diff content for review
# Usage: get_diff_content "develop"
get_diff_content() {
  local base_branch="${1:-$(detect_base_branch)}"
  if git diff "${base_branch}...HEAD" 2>/dev/null; then
    return 0
  fi
  echo "WARNING: Could not diff against '${base_branch}', falling back to HEAD diff." >&2
  if git diff HEAD 2>/dev/null; then
    return 0
  fi
  echo "ERROR: Failed to get diff content. Are you in a git repository with commits?" >&2
  return 1
}

# ── Perspective Loading ──

# Read a perspective file and return its content
# Usage: load_perspective "scripts/perspectives/code-review.md"
load_perspective() {
  local perspective_file="$1"
  if [[ ! -f "$perspective_file" ]]; then
    echo "ERROR: Perspective file not found: $perspective_file" >&2
    return 1
  fi
  cat "$perspective_file"
}

# ── Prompt Builder ──

# Build a prompt from perspective + context (task-type aware)
# Usage: build_prompt "scripts/perspectives/code-review.md" "develop" "file1.ts file2.ts"
# Task-type is read from TASK_TYPE variable (default: review)
# Description is read from DESCRIPTION variable (for explore/implement)
build_prompt() {
  local perspective_file="$1"
  local base_branch="${2:-$(detect_base_branch)}"
  local changed_files="${3:-}"
  local task_type="${TASK_TYPE:-review}"
  local description="${DESCRIPTION:-}"

  local perspective_content
  if ! perspective_content="$(load_perspective "$perspective_file")"; then
    return 1
  fi

  # Task-type specific preamble and context
  local preamble=""
  local context_section=""

  case "$task_type" in
    review)
      preamble="You are a code review agent. Follow the perspective instructions below to analyze the code changes."

      local diff_content
      if ! diff_content="$(get_diff_content "$base_branch")"; then
        echo "ERROR: aborting prompt build — no diff content available." >&2
        return 1
      fi

      local files_section=""
      if [[ -n "$changed_files" ]]; then
        files_section="
## Changed Files
${changed_files}
"
      fi

      context_section="${files_section}
## Code Changes (git diff)

${diff_content}"
      ;;

    explore)
      preamble="You are a codebase exploration agent. Follow the perspective instructions below to analyze the codebase. Do NOT modify any files — this is a read-only exploration task."

      if [[ -n "$description" ]]; then
        context_section="
## Exploration Target

${description}"
      fi
      ;;

    implement)
      preamble="You are an implementation agent. Follow the perspective instructions below to generate code. Output all generated files to the staging directory — do NOT write directly to the working tree."

      if [[ -n "$description" ]]; then
        context_section="
## Task Description

${description}"
      fi

      # Optionally include diff for implement tasks
      if [[ "${INCLUDE_DIFF:-false}" == "true" ]]; then
        local diff_content
        diff_content="$(get_diff_content "$base_branch")"
        context_section="${context_section}

## Current Changes (git diff)

${diff_content}"
      fi
      ;;

    *)
      preamble="You are an AI agent. Follow the perspective instructions below."
      ;;
  esac

  cat <<PROMPT
${preamble}

${perspective_content}

${context_section}

---

Analyze the above according to your role and output your findings in the specified Output Template format.
PROMPT
}

# ── Output Helpers ──

# Write review output with a standard header
# Usage: write_output "output.md" "Claude Code" "code-review" "review content..." [status]
# status: complete (default) | incomplete — recorded in the header so a consumer
# can tell a finished result from one salvaged off a failed run.
write_output() {
  local output_file="$1"
  local cli_name="$2"
  local perspective_name="$3"
  local content="$4"
  local status="${5:-complete}"

  mkdir -p "$(dirname "$output_file")"

  local task_type="${TASK_TYPE:-review}"
  # bash 3.2 compatible capitalization (no ${var^} operator)
  local task_label
  task_label="$(echo "$task_type" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')"

  cat > "$output_file" <<OUTPUT
<!-- Multi-CLI ${task_label} Result -->
<!-- CLI: ${cli_name} -->
<!-- Perspective: ${perspective_name} -->
<!-- Task Type: ${task_type} -->
<!-- Status: ${status} -->
<!-- Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ") -->

${content}
OUTPUT

  if [[ "$status" == "complete" ]]; then
    echo "✅ ${task_label} saved: ${output_file}" >&2
  else
    echo "⚠️  Incomplete ${task_type} saved: ${output_file}" >&2
  fi
}

# ── Timeout Wrapper ──

# Exit status meaning "the wall-clock limit fired", matching timeout(1)'s 124.
readonly TIMEOUT_EXIT_CODE=124
# 128+SIGKILL: the command was SIGKILLed without our deadline having fired.
readonly SIGKILL_EXIT_CODE=137
# This wrapper itself could not run the command (temp file unavailable, etc).
# Distinct from any status the command could return, so an orchestrator fault is
# never filed against the CLI.
readonly ORCHESTRATOR_ERROR_EXIT_CODE=125
# Seconds between the deadline's SIGTERM and the SIGKILL that follows it.
# Overridable so the regression suite can exercise the escalation quickly.
TIMEOUT_KILL_GRACE="${FF_TIMEOUT_KILL_GRACE:-10}"
readonly TIMEOUT_KILL_GRACE

# ── Out-of-band Failure Reason ──
# An exit status is a single channel, and 124/125 are only *conventionally* free:
# a CLI that exits 124 or 125 on its own would be filed as "the deadline fired" or
# "the orchestrator broke" and handed the matching wrong remedy. run_with_timeout
# knows which it was (it holds the marker), so it records the reason here and
# callers read it instead of inferring from the number.
#
# Why a file and not a variable: run_with_timeout runs inside `result=$(...)`, and
# anything it assigns dies with that subshell. `$$` stays the invoking shell's pid
# in a subshell, so both sides derive the same path with no argument to thread
# through — and separate adapter processes get separate files.
timeout_reason_file() {
  echo "${TMPDIR:-/tmp}/ff-run-with-timeout-reason.$$"
}

# timeout | orchestrator-error | command
record_timeout_reason() {
  printf '%s' "$1" >"$(timeout_reason_file)" 2>/dev/null || true
}

# Echoes the recorded reason, or "" when it could not be recorded (a broken TMPDIR
# takes the file with it). An empty reason means "fall back to reading the status".
read_timeout_reason() {
  local f
  f="$(timeout_reason_file)"
  [[ -f "$f" ]] || return 0
  cat "$f" 2>/dev/null || true
}

clear_timeout_reason() {
  rm -f "$(timeout_reason_file)" 2>/dev/null || true
}

# Run a command under a wall-clock limit and echo whatever it wrote to stdout.
# Usage: run_with_timeout 900 some_command arg1 arg2
#
# Returns the command's own exit status, $TIMEOUT_EXIT_CODE (124) when the limit
# fired, or $ORCHESTRATOR_ERROR_EXIT_CODE (125) when this wrapper could not run
# the command at all. Output produced before a kill is still echoed, so a caller
# can salvage partial work instead of discarding it.
#
# Why this supervises the child itself instead of delegating to timeout(1):
# timeout(1)'s exit status cannot say *why* the child died. Measured on GNU
# coreutils 9.7, `timeout -k` returns 124 when the child dies on SIGTERM inside
# the grace period but 137 when it had to escalate to SIGKILL — and a bare 137
# also means "something else SIGKILLed the child" (the OS under memory pressure,
# say). One status, two causes, opposite remedies: "allow more time" fixes the
# first and buries the second. The marker file below removes the ambiguity, so
# 124 always means the deadline and 137 always means an external kill. Running
# one implementation everywhere also means the regression suite covers the code
# that actually runs, on every host.
#
# Three independent guards live here. None substitutes for another:
#
#   1. **The child's stdout goes to a temp file**, never the inherited fd, so the
#      child cannot hold the caller's `$(...)` capture pipe open.
#   2. **The watchdog runs in its own process group and is killed as a group.**
#      This is the guard that makes an early-finishing command return early.
#      Killing only the watchdog subshell leaves its in-flight `sleep` alive as an
#      orphan; an orphan that had inherited the capture pipe keeps `$(...)` from
#      closing, so `result=$(run_with_timeout 900 fast_cmd)` blocked for the full
#      900s even though the command answered in 2s — measured, and exactly what
#      the old implementation did on hosts without timeout(1) (stock macOS; hosts
#      that had timeout(1) never stalled). The /dev/null redirect below is a
#      second line of defence on the same failure: verified that with guard 1 in
#      place but the redirect removed, a 2s command under a 12s limit still
#      blocked the full 12s.
#   3. **The child is a process-group leader and signals go to the group.**
#      Signalling only the direct child leaves the CLI's own workers running —
#      and, for a metered CLI, still billing — past the deadline.
#
# For the record, none of the three caused issue #152's *empty* review. That was
# the adapters' failure path discarding already-captured stdout (see
# fail_cli_task). Guard 2's absence is what made raising the default timeout
# unaffordable, and the old bare `1` return is what made targeted advice
# impossible.
#
# Test seam: FF_TIMEOUT_KILL_GRACE shortens the SIGTERM→SIGKILL grace period.
#
# The *reason* for a non-zero status travels out of band, via timeout_reason_file
# below — an exit status is one channel and would otherwise carry two meanings.
run_with_timeout() {
  local timeout_seconds="$1"
  shift

  record_timeout_reason command

  local out_file marker
  if ! out_file="$(mktemp)"; then
    echo "ERROR: run_with_timeout: cannot create a temp file for command output." >&2
    record_timeout_reason orchestrator-error
    return "$ORCHESTRATOR_ERROR_EXIT_CODE"
  fi
  if ! marker="$(mktemp)"; then
    echo "ERROR: run_with_timeout: cannot create a temp file for the timeout marker." >&2
    rm -f "$out_file"
    record_timeout_reason orchestrator-error
    return "$ORCHESTRATOR_ERROR_EXIT_CODE"
  fi

  # Job control makes each background job a process-group leader (pgid == pid),
  # which both guard 2 and guard 3 rely on.
  set -m
  "$@" >"$out_file" &
  local cmd_pid=$!
  (
    sleep "$timeout_seconds"
    # Record the fired deadline BEFORE signalling. Written after the kill, the
    # parent could reap the child and cancel this watchdog before the write
    # landed, and a genuine timeout would be reported as a crash — measured at
    # ~3% of runs (8/240) under CPU contention, returning 143 instead of 124.
    printf 'timeout' >"$marker"
    # Negative pid = process group. Fall back to the lone pid if the child never
    # became a group leader, so a host without job control still gets a timeout
    # rather than none at all.
    kill -TERM -- -"$cmd_pid" 2>/dev/null || kill -TERM "$cmd_pid" 2>/dev/null || true
    sleep "$TIMEOUT_KILL_GRACE"
    kill -KILL -- -"$cmd_pid" 2>/dev/null || kill -KILL "$cmd_pid" 2>/dev/null || true
  ) >/dev/null 2>&1 &
  local watchdog_pid=$!
  set +m

  local rc=0
  wait "$cmd_pid" || rc=$?

  # Kill the watchdog *as a group* so its in-flight `sleep` goes with it (guard 2)
  # instead of idling for the rest of the limit — at a 900s default that is a
  # stray `sleep 900` per task.
  kill -- -"$watchdog_pid" 2>/dev/null || kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true

  # Trust the marker only when the command actually failed. The marker means "the
  # deadline elapsed", which can also happen a hair after a command finished on
  # its own; reclassifying a successful run as a timeout would be worse than the
  # race it fixes. Residual window: a command that fails on its own within
  # milliseconds of the deadline is reported as a timeout — it was about to be
  # killed anyway.
  if [[ "$rc" -ne 0 && -s "$marker" ]]; then
    rc="$TIMEOUT_EXIT_CODE"
    record_timeout_reason timeout
    # `wait` returned as soon as the *direct* child died, and killing the watchdog
    # above cancelled its pending group SIGKILL. A group member that ignores
    # SIGTERM would otherwise outlive the deadline indefinitely, so finish the
    # escalation here: wait out a bounded grace so a well-behaved worker can still
    # flush, then SIGKILL whatever is left. Done in the foreground rather than
    # left to an orphaned watchdog, which would signal a possibly-recycled pgid
    # seconds later. Costs nothing when the group is already empty.
    local waited=0
    while [[ "$waited" -lt "$TIMEOUT_KILL_GRACE" ]] && kill -0 -- -"$cmd_pid" 2>/dev/null; do
      sleep 1
      waited=$((waited + 1))
    done
    kill -KILL -- -"$cmd_pid" 2>/dev/null || true
  fi
  rm -f "$marker"

  cat "$out_file"
  rm -f "$out_file"
  return "$rc"
}

# ── Failure Reporting ──

# Describe a non-zero CLI exit status in one phrase.
# Usage: describe_cli_failure <rc> <timeout_seconds> [reason]
#
# `reason` is run_with_timeout's out-of-band verdict (see timeout_reason_file):
# "timeout", "orchestrator-error", "command", or "" when it could not be recorded.
# It is consulted first because the status alone is ambiguous — a CLI is free to
# exit 124 or 125 itself, and only the reason separates that from our own verdict.
describe_cli_failure() {
  local rc="$1" timeout_seconds="$2" reason="${3:-}"

  case "$reason" in
    timeout)
      echo "timed out after ${timeout_seconds}s"
      return
      ;;
    orchestrator-error)
      echo "could not be started by this orchestrator (see the error above)"
      return
      ;;
  esac

  # reason == "command" (the CLI decided its own fate) or "" (unrecordable, so fall
  # back to the status). Only reserved-by-convention codes are interpreted here.
  case "$rc" in
    "$SIGKILL_EXIT_CODE")
      # A fired deadline is reported with reason=timeout above, so reaching here
      # with 137 means something *outside* this wrapper SIGKILLed the CLI, most
      # often the OS under memory pressure. Calling that a timeout would tell the
      # user to allow more time, which cannot help and buries the real cause.
      echo "was killed by SIGKILL — not by the time limit (e.g. the OS under memory pressure)"
      ;;
    "$TIMEOUT_EXIT_CODE"|"$ORCHESTRATOR_ERROR_EXIT_CODE")
      if [[ -z "$reason" ]]; then
        # No reason recorded: the number is all there is, so read it the
        # conventional way rather than pretending the CLI chose it.
        if [[ "$rc" -eq "$TIMEOUT_EXIT_CODE" ]]; then
          echo "timed out after ${timeout_seconds}s"
        else
          echo "could not be started by this orchestrator (see the error above)"
        fi
      else
        echo "exited with status ${rc} (the CLI's own status, not a timeout)"
      fi
      ;;
    *)
      echo "exited with status ${rc}"
      ;;
  esac
}

# Maximum bytes of CLI stderr copied into the result file. Enough for a stack
# trace or an auth error, small enough that a chatty CLI cannot bury the report.
readonly STDERR_EXCERPT_BYTES=4000

# Record a failed task as an explicitly INCOMPLETE result, then exit non-zero.
# Usage: fail_cli_task <exit_code> <stderr_log> <perspective_name> <partial_output>
# Reads: CLI_NAME, OUTPUT_FILE, TIMEOUT, TASK_TYPE. Does not return.
#
# Writing a file here rather than leaving none keeps whatever the CLI produced
# before it was stopped — issue #152 threw away a full 300s Codex run because the
# failure path discarded already-captured stdout, leaving a report that only said
# the section was missing. This stays fail-loud: the banner marks the result
# incomplete, the header carries `Status: incomplete`, and the non-zero exit keeps
# the orchestrator counting the task as failed.
#
# The stderr excerpt goes into the file too. For a crash the cause is usually
# *only* on stderr ("auth error: token expired"), and echoing it to the
# orchestrator's stream is not enough: in parallel mode that stream is several
# adapters interleaved, and nothing persists it. Salvaging stdout while dropping
# the one channel that says why would miss the point of the salvage.
#
# No runtime fallback is attempted here, by design. See the "Fallback semantics"
# section of scripts/multi-agent.sh for the reasoning.
fail_cli_task() {
  local rc="$1" stderr_log="$2" perspective_name="$3" partial="$4"

  local kind reason
  kind="$(read_timeout_reason)"
  clear_timeout_reason
  reason="$(describe_cli_failure "$rc" "$TIMEOUT" "$kind")"

  # Normalise the status at the process boundary. The orchestrator only sees this
  # number, so a CLI that exited 124/125 by its own choice must not arrive looking
  # like our timeout or our own breakage.
  local exit_rc="$rc"
  case "$kind" in
    timeout)            exit_rc="$TIMEOUT_EXIT_CODE" ;;
    orchestrator-error) exit_rc="$ORCHESTRATOR_ERROR_EXIT_CODE" ;;
    command)
      if [[ "$rc" -eq "$TIMEOUT_EXIT_CODE" || "$rc" -eq "$ORCHESTRATOR_ERROR_EXIT_CODE" ]]; then
        exit_rc=1
      fi
      ;;
  esac

  echo "ERROR: ${CLI_NAME} ${reason}." >&2
  if [[ "$exit_rc" -eq "$TIMEOUT_EXIT_CODE" ]]; then
    echo "       Give it more room with: --timeout $((TIMEOUT * 2))" >&2
  fi

  local stderr_excerpt=""
  if [[ -s "$stderr_log" ]]; then
    echo "--- CLI stderr ---" >&2
    cat "$stderr_log" >&2
    echo "--- end stderr ---" >&2
    stderr_excerpt="$(tail -c "$STDERR_EXCERPT_BYTES" "$stderr_log")"
  fi
  # Guard the empty operand: fail_orchestrator_error calls in with "" (there is no
  # stderr file when creating it is what failed). `rm -f ""` is a no-op on BSD, but
  # rather than depend on every rm(1) agreeing, skip it — if some rm did error here,
  # `set -e` would kill the adapter before it writes the artifact, i.e. exactly the
  # empty-handed failure this function exists to prevent.
  if [[ -n "$stderr_log" ]]; then
    rm -f "$stderr_log"
  fi

  local body
  if [[ -n "$partial" ]]; then
    body="Partial output captured before the CLI was stopped:

${partial}"
  else
    body="No output was captured before the CLI was stopped."
  fi

  if [[ -n "$stderr_excerpt" ]]; then
    body="${body}

### CLI stderr (last $((STDERR_EXCERPT_BYTES / 1000))KB)

\`\`\`
${stderr_excerpt}
\`\`\`"
  fi

  write_output "$OUTPUT_FILE" "$CLI_NAME" "$perspective_name" \
    "> ⚠️ **INCOMPLETE — ${CLI_NAME} ${reason}.** This is not a finished ${TASK_TYPE:-review}: the CLI never reached its conclusion, so anything it had not gotten to is simply absent — read the gaps as unknown, not as clean.

${body}" \
    "incomplete"

  exit "$exit_rc"
}

# Abort as an orchestrator-side failure, still leaving an INCOMPLETE artifact.
# Usage: fail_orchestrator_error <perspective_name> <what went wrong>
# Reads: CLI_NAME, OUTPUT_FILE, TIMEOUT, TASK_TYPE. Does not return.
#
# Needed for the setup that happens BEFORE run_with_timeout — creating the stderr
# temp file. Under the adapters' `set -e` a failed `mktemp` there killed the
# process with a bare 1, so a broken TMPDIR was filed as "the CLI exited 1" and no
# artifact was written at all: the 125 handling inside run_with_timeout could never
# be reached on the most likely path to it.
fail_orchestrator_error() {
  local perspective_name="$1" what="$2"
  echo "ERROR: ${what}" >&2
  record_timeout_reason orchestrator-error
  fail_cli_task "$ORCHESTRATOR_ERROR_EXIT_CODE" "" "$perspective_name" ""
}

# ── Severity Parsing ──

# Count occurrences of each severity level in a review result file
# Usage: parse_severity_counts "result.md"
parse_severity_counts() {
  local result_file="$1"

  if [[ ! -f "$result_file" ]]; then
    echo "critical=0 warning=0 suggestion=0 info=0"
    return
  fi

  local critical warning suggestion info
  critical=$(grep -ci "critical" "$result_file" 2>/dev/null || echo "0")
  warning=$(grep -ci "warning" "$result_file" 2>/dev/null || echo "0")
  suggestion=$(grep -ci "suggestion" "$result_file" 2>/dev/null || echo "0")
  info=$(grep -ci "info" "$result_file" 2>/dev/null || echo "0")

  echo "critical=${critical} warning=${warning} suggestion=${suggestion} info=${info}"
}

# ── Argument Parsing Helper ──

# Parse common adapter arguments
# Sets: PERSPECTIVE_FILE, OUTPUT_FILE, CHANGED_FILES, BASE_BRANCH, TIMEOUT,
#       TASK_TYPE, DESCRIPTION, INCLUDE_DIFF
# Usage: parse_adapter_args "$@"
parse_adapter_args() {
  PERSPECTIVE_FILE=""
  OUTPUT_FILE=""
  CHANGED_FILES=""
  BASE_BRANCH="$(detect_base_branch)"
  # Standalone default for a direct adapter invocation. Kept in step with
  # multi-agent.sh's DEFAULT_TIMEOUT_REVIEW — an adapter run by hand should not
  # inherit the 300s that issue #152 identified as too short. The orchestrator
  # always passes --timeout explicitly, so this value only applies to direct runs.
  # tests/multi-agent-timeout/verify.sh gates it against that constant.
  TIMEOUT="${REVIEW_TIMEOUT:-900}"
  TASK_TYPE="review"
  DESCRIPTION=""
  INCLUDE_DIFF="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --changed-files)
        CHANGED_FILES="$2"
        shift 2
        ;;
      --base)
        BASE_BRANCH="$2"
        shift 2
        ;;
      --timeout)
        TIMEOUT="$2"
        shift 2
        ;;
      --task-type)
        TASK_TYPE="$2"
        shift 2
        ;;
      --description)
        DESCRIPTION="$2"
        shift 2
        ;;
      --include-diff)
        INCLUDE_DIFF="true"
        shift
        ;;
      *)
        if [[ -z "$PERSPECTIVE_FILE" ]]; then
          PERSPECTIVE_FILE="$1"
        elif [[ -z "$OUTPUT_FILE" ]]; then
          OUTPUT_FILE="$1"
        fi
        shift
        ;;
    esac
  done

  if [[ -z "$PERSPECTIVE_FILE" || -z "$OUTPUT_FILE" ]]; then
    echo "Usage: $(basename "$0") <perspective-file> <output-file> [--changed-files <files>] [--base <branch>] [--timeout <seconds>] [--task-type <review|explore|implement>] [--description <text>]" >&2
    return 1
  fi
}
