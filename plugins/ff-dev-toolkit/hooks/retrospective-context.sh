#!/usr/bin/env bash
#
# Inject the automatic retrospective contract before response generation.
# The Stop hook remains a fallback when the model misses this context.

MODE="${RETROSPECTIVE_MODE:-}"
MODE="${MODE//[[:space:]]/}"

case "$MODE" in
  [Oo][Ff][Ff]|0|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]|[Nn][Oo][Nn][Ee]|[Dd][Ii][Ss][Aa][Bb][Ll][Ee][Dd])
    exit 0
    ;;
  [Aa][Ss][Kk])
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"RETROSPECTIVE_MODE=ask. Before producing the final response, apply ff-dev-toolkit:retrospective. If the user already approved the retrospective for this completed task, run it now; otherwise ask whether to run it. If this turn is not a task closeout, include exactly: 振り返り: 今回は作業完了前のため対象外. Do not wait for the Stop hook. The retrospective is read-only; do not edit files or create issues without user approval."}}'
    exit 0
    ;;
esac

printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"Before producing the final response, run ff-dev-toolkit:retrospective automatically. If this turn completes the user requested work, inspect only events measured in this session and include the retrospective result. If this is a clarification, approval wait, external-state wait, or unfinished work, include exactly: 振り返り: 今回は作業完了前のため対象外. Do not wait for the Stop hook. The retrospective is read-only; do not edit files or create issues without user approval."}}'

exit 0
