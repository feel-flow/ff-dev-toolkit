#!/usr/bin/env bash
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
    process.stdout.write(input.stop_hook_active || retrospectiveDone ? "active" : "first");
  } catch (_) {
    process.exit(2);
  }
});
' 2>/dev/null)" || exit 0

if [ "$HOOK_STATE" != "first" ]; then
  exit 0
fi

case "$MODE" in
  [Aa][Ss][Kk])
  printf '%s\n' '{"decision":"block","reason":"RETROSPECTIVE_MODE=ask. Before stopping, check whether the user already approved the retrospective for this completed task. If approved, run the ff-dev-toolkit:retrospective skill now; otherwise ask whether to run it. Do not ask again after the retrospective result is already present. If this turn is not a task closeout, report: 振り返り: 今回は作業完了前のため対象外","systemMessage":"Automatic retrospective check before stop"}'
  exit 0
  ;;
esac

printf '%s\n' '{"decision":"block","reason":"Before stopping, run the ff-dev-toolkit:retrospective skill now. If this turn completes the user requested work, inspect only events measured in this session and include the retrospective result in the final response. If this is a clarification, approval wait, external-state wait, or unfinished work, do not invent proposals; report exactly: 振り返り: 今回は作業完了前のため対象外. The retrospective is read-only: do not edit files or create issues without user approval.","systemMessage":"Automatic retrospective before stop"}'

exit 0
