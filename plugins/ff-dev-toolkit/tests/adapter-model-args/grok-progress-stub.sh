#!/usr/bin/env bash
set -euo pipefail

session=""
review=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session-id) session="$2"; shift ;;
    --prompt-file) review=true; shift ;;
  esac
  shift
done
[[ "$review" == true ]] || exit 0
[[ -n "$session" ]] || exit 70

workspace="$(pwd -P | jq -Rnr 'input | @uri')"
events="$GROK_HOME/sessions/$workspace"
mkdir -p "$events/unrelated-session" "$events/$session"

wait_for_progress() {
  local pattern="$1" log="${2:-$STUB_GROK_PROGRESS_LOG}" deadline=$((SECONDS + 25))
  while [[ "$SECONDS" -lt "$deadline" ]]; do
    if grep -q -F "$pattern" "$log" 2>/dev/null; then return 0; fi
    sleep 0.2
  done
  echo "Expected progress missing while Grok was live: $pattern" >&2
  return 1
}

if [[ "${STUB_GROK_PROGRESS_STALL:-false}" != true && -z "${STUB_GROK_PARSE_MARKER:-}" ]]; then
  printf '%s\n' '{"type":"phase_changed","phase":"streaming_reasoning","ts":"other-session"}' >"$events/unrelated-session/events.jsonl"
  wait_for_progress '進捗イベントを確認できません'
  if grep -q -F '推論中' "$STUB_GROK_PROGRESS_LOG"; then exit 71; fi
fi

printf '%s\n' '{"type":"phase_changed","phase":"streaming_reasoning","ts":"own-session","text":"private-thought"}' >"$events/$session/events.jsonl"
# 追記途中の JSON があっても、直前に完成した行を確認できる。
printf '%s' '{"type":"phase_changed"' >>"$events/$session/events.jsonl"
printf '%s\n' 'stub-cli-stderr' >&2
if [[ -n "${STUB_GROK_PARSE_MARKER:-}" ]]; then
  wait_for_progress 'started' "$STUB_GROK_PARSE_MARKER"
  exit 0
fi
if [[ "${STUB_GROK_PROGRESS_STALL:-false}" == true ]]; then
  exec sleep 60
fi
wait_for_progress '推論中'
wait_for_progress '進捗イベントの更新を待機中'
