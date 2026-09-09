#!/usr/bin/env bash

# ASDD 2.0: disabled optional hooks do not prompt, block, or mutate.
if ! source "${BASH_SOURCE[0]%/*}/asdd-hook-gate.sh"; then
  echo 'ff-dev-toolkit: ASDD Hook helper is unavailable; optional hook skipped' >&2
  exit 0
fi
asdd_hook_enabled retrospective || exit 0
#
# Inject the automatic retrospective contract before response generation.
# Claude Code keeps a Stop fallback when the model misses this context. Codex
# Stop is silent because its continuation reason is rendered as visible UI.
#
# Issue #840: non-interactive single-shot runs (codex exec) are tool-style
# invocations whose stdout is the deliverable (cross-model review), so the
# contract must not be injected there. Codex hook inputs always carry `model`
# (Claude Code's UserPromptSubmit input never does), and codex exec forces
# approval policy "never" in headless mode, which reaches hooks as
# permission_mode "bypassPermissions" (interactive Codex TUI reports
# "default"). Both fields together identify the non-interactive Codex path.
# Detection is fail-open toward injection: missing Node.js, unparsable JSON,
# an abnormal detector exit, or any unexpected detector output keep the
# previous always-inject behavior, so interactive sessions never lose the
# retrospective. A skip is not silent: one stderr breadcrumb line records it
# so a future misclassification or host contract change stays observable
# (UserPromptSubmit stderr on exit 0 is not injected into model context).
#
# Nested non-interactive `claude -p` (public ff-dev-toolkit issue 94) is NOT
# detectable here. Measured 2026-09-10, claude 2.1.245 / macOS, by dumping the
# raw UserPromptSubmit stdin of `claude -p "..." --output-format text
# --permission-mode plan --settings <temp>`: the input carries exactly
# session_id, transcript_path, cwd, prompt_id, permission_mode,
# hook_event_name, prompt — no `model`, and no print/headless/output_format
# field of any kind. `permission_mode` only mirrors --permission-mode (measured
# "plan" when passed, and the inherited "bypassPermissions" when omitted), so it
# cannot separate `claude -p` from an interactive session in the same mode. The
# published hooks reference lists no such field either. Absence-based guesses
# (e.g. treating a missing `effort` as headless) would invert the fail-open
# stance and silently kill the retrospective for interactive sessions, so this
# hook keeps injecting. The launcher owns the contract instead: any script that
# shells out to a nested non-interactive `claude -p` whose stdout is the
# deliverable must export RETROSPECTIVE_MODE=off for that child process (see
# skills/retrospective/SKILL.md "自動発火"). Re-measure and revisit this branch
# if a future host adds a headless marker to the input.

MODE="${RETROSPECTIVE_MODE:-}"
MODE="${MODE//[[:space:]]/}"

case "$MODE" in
  [Oo][Ff][Ff]|0|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]|[Nn][Oo][Nn][Ee]|[Dd][Ii][Ss][Aa][Bb][Ll][Ee][Dd])
    exit 0
    ;;
esac

INPUT_TIMEOUT_SECONDS=2

# The prompt field is user-controlled text that can quote these very field
# names, so the discrimination must parse the JSON structurally (a substring
# grep would be spoofable from the prompt). Node.js mirrors the Stop hook's
# runtime dependency; without it the detection is skipped, not the injection.
#
# Node reads the hook's stdin itself and bounds the wait with its own timer.
# A bash `read -t` bound is not used here: on piped stdin bash reads byte by
# byte, so a large input (cross-model review embeds full diffs; ~10MB is
# realistic) exhausts the timeout, drops the partial input, and silently
# reverts to injection — reintroducing the #840 symptom with a 2 second
# delay. Node consumes the same input in milliseconds.
HOST_STATE="inject"
if command -v node >/dev/null 2>&1; then
  HOST_STATE="$(node -e '
const finish = state => { process.stdout.write(state); process.exit(0); };
const timer = setTimeout(() => finish("inject"), (Number(process.argv[1]) || 2) * 1000);
let source = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", chunk => { source += chunk; });
process.stdin.on("error", () => finish("inject"));
process.stdin.on("end", () => {
  clearTimeout(timer);
  try {
    const input = JSON.parse(source);
    const codexHost = typeof input.model === "string" && input.model !== "";
    const nonInteractive = input.hook_event_name === "UserPromptSubmit"
      && input.permission_mode === "bypassPermissions";
    finish(codexHost && nonInteractive ? "skip" : "inject");
  } catch (_) {
    finish("inject");
  }
});
' "$INPUT_TIMEOUT_SECONDS" 2>/dev/null)" || HOST_STATE="inject"
fi

if [ "$HOST_STATE" = "skip" ]; then
  echo 'retrospective-context: skip pre-injection (codex non-interactive: permission_mode=bypassPermissions)' >&2
  exit 0
fi

case "$MODE" in
  [Aa][Ss][Kk])
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"RETROSPECTIVE_MODE=ask. Before producing the final response, apply ff-dev-toolkit:retrospective. If the user already approved the retrospective for this completed task, run it now; otherwise ask whether to run it. If this turn is not a task closeout, include exactly: 振り返り: 今回は作業完了前のため対象外. Do not wait for the Stop hook. The retrospective inspection is read-only; apart from the observation-ledger recording defined by the skill, do not edit files or create issues without user approval."}}'
    exit 0
    ;;
esac

printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"Before producing the final response, run ff-dev-toolkit:retrospective automatically. If this turn completes the user requested work, inspect only events measured in this session and include the retrospective result. If this is a clarification, approval wait, external-state wait, or unfinished work, include exactly: 振り返り: 今回は作業完了前のため対象外. Do not wait for the Stop hook. The retrospective inspection is read-only; apart from the observation-ledger recording defined by the skill, do not edit files or create issues without user approval."}}'

exit 0
