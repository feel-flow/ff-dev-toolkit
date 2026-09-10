#!/usr/bin/env bash

# ASDD 2.0: disabled optional hooks do not prompt, block, or mutate.
if ! source "${BASH_SOURCE[0]%/*}/asdd-hook-gate.sh"; then
  echo 'ff-dev-toolkit: ASDD Hook helper is unavailable; optional hook skipped' >&2
  exit 0
fi
asdd_hook_enabled retrospective || exit 0
#
# ff-dev-toolkit automatic retrospective Stop hook (Issue #583).
#
# A Stop event is emitted for every assistant response, not only task closeout.
# The continuation prompt therefore asks the agent to distinguish completed work
# from a clarification/waiting turn. The host sets stop_hook_active=true for the
# continuation, which is the recursion guard; this hook intentionally writes no
# marker files.
#
# Parsing/runtime failures are fail-open. A missing Node.js runtime is a
# persistent installation problem, so it emits a non-blocking recovery hint.

INPUT_TIMEOUT_SECONDS=2
HOOK_INPUT=""
# Stop hook hosts normally close stdin after writing one JSON object. Bound the
# read anyway so a non-conforming host cannot hang every assistant response.
IFS= read -r -t "$INPUT_TIMEOUT_SECONDS" -d '' HOOK_INPUT || {
  [ -n "$HOOK_INPUT" ] || exit 0
}

MODE="${RETROSPECTIVE_MODE:-}"
# Bash 3.2 has no ${var,,}; remove whitespace and use explicit case-insensitive
# patterns. The aliases make the only kill switch tolerant of common spellings.
MODE="${MODE//[[:space:]]/}"
case "$MODE" in
  [Oo][Ff][Ff]|0|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]|[Nn][Oo][Nn][Ee]|[Dd][Ii][Ss][Aa][Bb][Ll][Ee][Dd])
    exit 0
    ;;
esac

if ! command -v node >/dev/null 2>&1; then
  printf '%s\n' '{"systemMessage":"ff-dev-toolkit: Node.js が見つからないため自動振り返りをスキップしました。Node.js 22 以上を導入するか、手動で ff-dev-toolkit:retrospective を実行してください。自動発火を無効にする場合は RETROSPECTIVE_MODE=off を設定してください"}'
  exit 0
fi

HOOK_STATE="$(printf '%s' "$HOOK_INPUT" | node -e '
let source = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", chunk => { source += chunk; });
process.stdin.on("end", () => {
  try {
    const input = JSON.parse(source);
    if (input.hook_event_name !== "Stop") process.exit(2);
    if (typeof input.stop_hook_active !== "boolean") process.exit(2);
    const message = typeof input.last_assistant_message === "string"
      ? input.last_assistant_message
      : "";
    const retrospectiveDone = /(^|\n)(振り返り:|## セッション振り返り)/m.test(message);
    // Codex Stop decision:block renders reason as a visible HookPrompt. Codex
    // inputs include model, so rely on UserPromptSubmit pre-injection there and
    // keep this fallback only for hosts such as Claude Code.
    const codexStop = typeof input.model === "string";
    process.stdout.write(input.stop_hook_active || retrospectiveDone || codexStop ? "active" : "first");
  } catch (_) {
    process.exit(2);
  }
});
' 2>/dev/null)" || exit 0

if [ "$HOOK_STATE" != "first" ]; then
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
  printf '{"decision":"block","reason":"RETROSPECTIVE_MODE=ask. Before stopping, check whether the user already approved the retrospective for this completed task. If approved, run the ff-dev-toolkit:retrospective skill now; otherwise ask whether to run it. Do not ask again after the retrospective result is already present. If this turn is not a task closeout, report: 振り返り: 今回は作業完了前のため対象外. %s","systemMessage":"Automatic retrospective check before stop"}\n' "$FILING_CLAUSE"
  exit 0
  ;;
esac

printf '{"decision":"block","reason":"Before stopping, run the ff-dev-toolkit:retrospective skill now. If this turn completes the user requested work, inspect only events measured in this session and include the retrospective result in the final response. If this is a clarification, approval wait, external-state wait, or unfinished work, do not invent proposals; report exactly: 振り返り: 今回は作業完了前のため対象外. The retrospective inspection is read-only. %s","systemMessage":"Automatic retrospective before stop"}\n' "$FILING_CLAUSE"

exit 0
