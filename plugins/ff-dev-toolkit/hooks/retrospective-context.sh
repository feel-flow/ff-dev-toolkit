#!/usr/bin/env bash
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

INPUT_TIMEOUT_SECONDS=2
# Bound for the discard stage: once the input bound above has decided the
# answer, the payload still has to be read to EOF so the writer does not take
# EPIPE / SIGPIPE. Derived from the hook's own budget: hooks.json registers this
# hook with timeout 5, so the host kills it at 5 s whatever it is doing, and a
# kill mid-write hands the host the very EPIPE this drain prevents. Reserve 1 s
# for process startup and the work after the drain, which leaves 4 s for stdin;
# the first stage may spend INPUT_TIMEOUT_SECONDS (2) of it, so the discard gets
# the other 2. Measured worst case 2026-09-12 (a host that opens the pipe and
# never writes, so both stages run to their bound): 4.18-4.28 s, against the host's 5.
DRAIN_TIMEOUT_SECONDS=2

# RETROSPECTIVE_MODE is parsed here, before the stdin block, because the kill
# switch decides *who reads stdin*. With the hook disabled there is nothing to
# discriminate, so starting node would be an extra process on every prompt for
# nothing (measured 2026-09-12, min of 5, stdin closed: 0.079 s with the parse
# here against 0.125 s with it below the detector, and 0.28 s against 0.67 s
# with the machine loaded). off is also what a launcher exports for a nested
# non-interactive `claude -p`, so that cost lands once per nested run. The
# `exit 0` for off stays below the ASDD gate, where it has always been; only the
# parse moves up.
MODE="${RETROSPECTIVE_MODE:-}"
MODE="${MODE//[[:space:]]/}"
RETROSPECTIVE_OFF=0
case "$MODE" in
  [Oo][Ff][Ff]|0|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]|[Nn][Oo][Nn][Ee]|[Dd][Ii][Ss][Aa][Bb][Ll][Ee][Dd])
    RETROSPECTIVE_OFF=1
    ;;
esac

# stdin ownership. This block is deliberately ahead of the ASDD gate and of the
# kill switch's own exit: every early exit below is an exit 0, and leaving
# without reading the payload hands the writing host an unread pipe (EPIPE /
# SIGPIPE) once the payload outgrows the pipe buffer. Whoever reads stdin here
# is the hook's only reader.
#
# The prompt field is user-controlled text that can quote these very field
# names, so the discrimination must parse the JSON structurally (a substring
# grep would be spoofable from the prompt). Node.js mirrors the Stop hook's
# runtime dependency; without it the detection is skipped, not the injection.
#
# Node reads the hook's stdin itself and bounds the wait with its own timer.
# A bash `read -t` bound is not used on that path: on piped stdin bash reads
# byte by byte, so a large input (cross-model review embeds full diffs; ~10MB
# is realistic) exhausts the timeout, drops the partial input, and silently
# reverts to injection — reintroducing the #840 symptom with a 2 second
# delay. Node consumes the same input in milliseconds.
#
# The input bound therefore latches the fail-open answer instead of ending the
# read: after it fires the reader stops accumulating (so a slow multi-megabyte
# writer costs no memory) and keeps draining to EOF under DRAIN_TIMEOUT_SECONDS.
# Exiting at the bound would close the pipe under a writer that has not finished
# — or, for a writer that only starts after the bound, under one that has not
# begun.
HOST_STATE="inject"
if [ "$RETROSPECTIVE_OFF" -eq 0 ] && command -v node >/dev/null 2>&1; then
  HOST_STATE="$(node -e '
const finish = state => { process.stdout.write(state); process.exit(0); };
let decided = "";
let source = "";
let drainTimer = null;
const latch = () => {
  decided = "inject";
  source = "";
  drainTimer = setTimeout(() => finish(decided), Number(process.argv[2]) * 1000 || 2000);
};
const timer = setTimeout(latch, (Number(process.argv[1]) || 2) * 1000);
process.stdin.setEncoding("utf8");
process.stdin.on("data", chunk => { if (!decided) source += chunk; });
process.stdin.on("error", () => finish(decided || "inject"));
process.stdin.on("end", () => {
  clearTimeout(timer);
  if (drainTimer) clearTimeout(drainTimer);
  if (decided) finish(decided);
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
' "$INPUT_TIMEOUT_SECONDS" "$DRAIN_TIMEOUT_SECONDS" 2>/dev/null)" || HOST_STATE="inject"
else
  # Disabled, or no Node.js. Either way there is nothing to discriminate, so the
  # read is a pure discard — but it still has to happen, which is how this hook
  # used to differ from every other hook in the plugin: they drain with the
  # shell builtin, so a host that writes more than the pipe buffer holds never
  # takes EPIPE / SIGPIPE from them.
  #
  # The builtin is the cheap path (no fork, ~1 ms for a normal payload) and it
  # keeps the disabled hook as fast as it was before this hook owned stdin. It
  # cannot be the only path: the builtin moves a pipe at about 2.9 MB/s
  # (measured 2026-09-12, bash 3.2.57 / macOS: 6 MiB in 2.14 s, 20 MiB in
  # 7.17 s, 40 MiB in 14.31 s), so a payload past roughly 6 MB outlives the
  # bound — and a writer that only starts after the bound is never read at all.
  # When the bound is what ended the read, hand the rest to node, which discards
  # it in milliseconds under its own bound. With no node there is no bounded
  # fast reader available, so the builtin bound is where it stops.
  #
  # SECONDS (whole seconds, a bash builtin) is what separates "the bound ended
  # the read" from "EOF ended it". The return code cannot: bash 3.2 reports a
  # timeout as rc 1 and drops the partial input — the same rc EOF produces
  # (bash 5 reports rc > 128 and keeps it, so neither is portable evidence).
  DRAIN_STARTED=$SECONDS
  IFS= read -r -t "$INPUT_TIMEOUT_SECONDS" -d '' _
  READ_RC=$?
  if [ "$READ_RC" -ne 0 ] && [ "$((SECONDS - DRAIN_STARTED))" -ge "$INPUT_TIMEOUT_SECONDS" ] \
    && command -v node >/dev/null 2>&1; then
    node -e '
const stop = () => process.exit(0);
const timer = setTimeout(stop, Number(process.argv[1]) * 1000 || 2000);
process.stdin.on("data", () => {});
process.stdin.on("error", stop);
process.stdin.on("end", () => { clearTimeout(timer); stop(); });
' "$DRAIN_TIMEOUT_SECONDS" >/dev/null 2>&1 || true
  fi
fi

# The ASDD gate goes AFTER the stdin ownership block above, for the reason
# stated there: the gate's early exits (.asdd config present but node missing /
# this feature disabled / the helper itself unreadable) are all exit 0, so a
# gate placed first would reintroduce the unread-pipe path on every prompt. The
# gate never consumes stdin (asdd-hook-gate.sh), so reading first does not
# change what the gate sees.
# ASDD 2.0: disabled optional hooks do not prompt, block, or mutate.
if ! source "${BASH_SOURCE[0]%/*}/asdd-hook-gate.sh"; then
  echo 'ff-dev-toolkit: ASDD Hook helper is unavailable; optional hook skipped' >&2
  exit 0
fi
asdd_hook_enabled retrospective || exit 0

# The kill switch's exit stays here, below the gate, where it has always been.
# Only the parse of RETROSPECTIVE_MODE moved above the stdin block, because it
# picks the reader there.
if [ "$RETROSPECTIVE_OFF" -eq 1 ]; then
  exit 0
fi

if [ "$HOST_STATE" = "skip" ]; then
  echo 'retrospective-context: skip pre-injection (codex non-interactive: permission_mode=bypassPermissions)' >&2
  exit 0
fi

# Issue #1451: issue filing is governed by the skill section 承認と起票. The default
# files proposals that passed the pre-filing checks without waiting for approval;
# RETROSPECTIVE_FILING=ask restores the approval wait; every other value (unset,
# empty, or anything else) is the default. The injected text says which of the
# two branches is active so the agent does not have to observe the environment.
FILING="${RETROSPECTIVE_FILING:-}"
FILING="${FILING//[[:space:]]/}"
case "$FILING" in
  [Aa][Ss][Kk])
    FILING_CLAUSE='RETROSPECTIVE_FILING=ask: apart from the observation-ledger recording defined by the skill, do not edit files, create issues, or post issue comments without user approval.'
    ;;
  *)
    FILING_CLAUSE='Apart from the observation-ledger recording defined by the skill, do not edit files. Issue filing follows the skill section 承認と起票 (RETROSPECTIVE_FILING is not ask): file the proposals that passed the pre-filing checks without waiting for approval, and report the issue numbers in the retrospective result.'
    ;;
esac

case "$MODE" in
  [Aa][Ss][Kk])
    printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"RETROSPECTIVE_MODE=ask. Before producing the final response, apply ff-dev-toolkit:retrospective. If the user already approved the retrospective for this completed task, run it now; otherwise ask whether to run it. If this turn is not a task closeout, include exactly: 振り返り: 今回は作業完了前のため対象外. Do not wait for the Stop hook. The retrospective inspection is read-only. %s"}}\n' "$FILING_CLAUSE"
    exit 0
    ;;
esac

printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"Before producing the final response, run ff-dev-toolkit:retrospective automatically. If this turn completes the user requested work, inspect only events measured in this session and include the retrospective result. If this is a clarification, approval wait, external-state wait, or unfinished work, include exactly: 振り返り: 今回は作業完了前のため対象外. Do not wait for the Stop hook. The retrospective inspection is read-only. %s"}}\n' "$FILING_CLAUSE"

exit 0
