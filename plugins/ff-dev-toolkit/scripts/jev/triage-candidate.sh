#!/usr/bin/env bash
# Triage a candidate against live principles (bash 3.2 + jq; never evaluates input).
# Usage: triage-candidate.sh --candidate <text> [--principles <glob>]
#        triage-candidate.sh --overturn <decision-id> [--note <text>]
# FF_PRINCIPLES_GLOB supplies the default glob (* / ** / ? supported).
# No matches/entries: use live docs/08-knowledge/PLAYBOOK.md and linked playbook files.
# stdout: one JSON line then TRIAGE=category|principle_id-or-null|confidence.
# JSON includes top_k, measurement_hint, decision_ids. A human makes the final decision.
# rc 0 adopted; 10 low confidence; 11 unavailable; 12 off; 2 invalid input; 64 config; 69 jq missing.
# Explicit off calls return local hints; callers skip this script entirely when off,
# preserving their previous output byte-for-byte. No network/log writes in off mode.
set -uo pipefail
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
CANDIDATE=""
PATTERN="${FF_PRINCIPLES_GLOB:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --candidate) [ $# -ge 2 ] || { echo 'usage: --candidate <text> [--principles <glob>]' >&2; exit 2; }; CANDIDATE="$2"; shift 2 ;;
    --principles) [ $# -ge 2 ] || { echo 'usage: --principles <glob>' >&2; exit 2; }; PATTERN="$2"; shift 2 ;;
    --overturn) exec bash "$SCRIPT_DIR/jev-decide.sh" "$@" ;;
    -h|--help) echo 'usage: triage-candidate.sh --candidate <text> [--principles <glob>]'; exit 0 ;;
    *) echo 'usage: --candidate <text> [--principles <glob>]' >&2; exit 2 ;;
  esac
done
case "$CANDIDATE" in *[!$' \t\r\n']*) ;; *) echo 'usage: --candidate <nonempty text> [--principles <glob>]' >&2; exit 2 ;; esac
MODE="${FF_JEV_MODE:-off}"
case "$MODE" in on|off) ;; *) echo 'triage: FF_JEV_MODE must be on or off' >&2; exit 64 ;; esac
command -v jq >/dev/null 2>&1 || { echo 'triage: jq is required' >&2; exit 69; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/jev-triage.XXXXXX")" || exit 11
trap 'rm -rf "$WORK"' EXIT
REGISTRY="$SCRIPT_DIR/triage-registry.jq"
[ -r "$REGISTRY" ] || { echo 'triage: registry helper missing' >&2; exit 2; }
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"
: > "$WORK/entries.jsonl"
printf '%s' "$CANDIDATE" > "$WORK/candidate"
append_entries() {
  jq -cn -L "$SCRIPT_DIR" --rawfile text "$1" --arg source "$1" --arg kind "$2" \
    'include "triage-registry"; entries($text; $source; $kind)[]' >> "$WORK/entries.jsonl"
}
if [ -n "$PATTERN" ]; then
  case "$PATTERN" in /*) ;; ./*) PATTERN="$PWD/${PATTERN#./}" ;; *) PATTERN="$PWD/$PATTERN" ;; esac
  if [ -f "$PATTERN" ]; then
    append_entries "$PATTERN" principle || exit 2
  else
    prefix="${PATTERN%%[\*\?]*}"
    base="${prefix%/*}"
    [ -n "$base" ] || base=/
    if [ -d "$base" ]; then
      regex="$(jq -nr -L "$SCRIPT_DIR" --arg p "$PATTERN" 'include "triage-registry"; $p | glob_regex')" || exit 2
      find "$base" -type d \( -name .git -o -name node_modules \) -prune -o -type f -name '*.md' -print0 > "$WORK/files" || exit 2
      while IFS= read -r -d '' file; do
        rc=0
        jq -ne --arg p "$file" --arg re "$regex" '$p | test($re)' >/dev/null || rc=$?
        case "$rc" in 0) append_entries "$file" principle || exit 2 ;; 1) ;; *) exit 2 ;; esac
      done < "$WORK/files"
    fi
  fi
fi
if [ ! -s "$WORK/entries.jsonl" ]; then
  echo 'triage: 原則 glob が未指定・一致なし・見出しなしのため live PLAYBOOK.md へ fallback' >&2
  playbook="$ROOT/docs/08-knowledge/PLAYBOOK.md"
  if [ -r "$playbook" ]; then
    append_entries "$playbook" ace || exit 2
    jq -Rrs '[scan("\\]\\((?:\\./)?(playbook/[^)#]+\\.md)(?:#[^)]*)?\\)") | .[0] | select(contains("archive/") | not)] | unique[]' "$playbook" > "$WORK/links" || exit 2
    while IFS= read -r link; do
      case "$link" in *'..'*) echo 'triage: invalid playbook link' >&2; exit 2 ;; esac
      append_entries "${playbook%/*}/$link" ace || exit 2
    done < "$WORK/links"
  fi
fi
jq -sc -L "$SCRIPT_DIR" --rawfile candidate "$WORK/candidate" '
 include "triage-registry";
 if (group_by(.id) | any(.[]; length > 1)) then error("duplicate principle id") else . end |
 ($candidate | tokens) as $a | map(. + {similarity: similarity($a; (.title + "\n" + .body | tokens))}) |
 sort_by(-.similarity, .id, .source) | .[:5]' "$WORK/entries.jsonl" > "$WORK/top.json" || exit 2
HINT="$(jq -nr --rawfile c "$WORK/candidate" '$c | test("[0-9]+(?:\\.[0-9]+)?\\s*(?:ms|s|h|d|%|件|秒|分|時間)|実測|[0-9]{4}-[0-9]{2}-[0-9]{2}")')" || exit 2
IDS='[]'
CONF=1
emit() {
  local category="$1" id="$2" confidence="$3" reason="$4"
  jq -cn --arg category "$category" --arg id "$id" --argjson confidence "$confidence" \
    --arg reason "$reason" --argjson ids "$IDS" --argjson hint "$HINT" --slurpfile top "$WORK/top.json" \
    '{category:$category,principle_id:(if $id == "null" then null else $id end),confidence:$confidence,
      reason:$reason,decision_ids:$ids,measurement_hint:$hint,top_k:$top[0]}' || exit 2
  printf 'TRIAGE=%s|%s|%s\n' "$category" "$id" "$confidence"
}
fallback() { emit undetermined null 0 "$2"; exit "$1"; }
[ "$MODE" = on ] || fallback 12 mode-off
[ "$(jq length "$WORK/top.json")" -gt 0 ] || fallback 11 registry-empty
ask() {
  local question="$1" qid="$2" state="$3" rc=0 answer
  bash "$SCRIPT_DIR/jev-decide.sh" triage --questions "$SCRIPT_DIR/questions/$question.json" \
    --state-file "$state" --fill "CANDIDATE=$WORK/candidate" --json > "$WORK/decision.json" || rc=$?
  case "$rc" in
    0) ;;
    10|11|12) fallback "$rc" "$(jq -r '.reason // "unavailable"' "$WORK/decision.json")" ;;
    *) echo "triage: decision failed (rc=$rc)" >&2; exit "$rc" ;;
  esac
  jq -e --arg q "$qid" '.decision == "adopt" and (.id | type == "string" and length > 0) and
    (.answers[$q] | .type == "noul" and (.value | type == "number") and (.confidence | type == "number"))' \
    "$WORK/decision.json" >/dev/null || fallback 11 bad-decision
  IDS="$(jq -cn --argjson ids "$IDS" --slurpfile d "$WORK/decision.json" '$ids + [$d[0].id]')" || exit 2
  CONF="$(jq -nr --argjson c "$CONF" --arg q "$qid" --slurpfile d "$WORK/decision.json" '[$c,$d[0].answers[$q].confidence] | min')" || exit 2
  answer="$(jq -r --arg q "$qid" '.answers[$q].value >= 0.5' "$WORK/decision.json")" || exit 2
  [ "$answer" = true ]
}
i=0
count="$(jq length "$WORK/top.json")"
while [ "$i" -lt "$count" ]; do
  jq --argjson i "$i" '.[$i] | {id,title,body}' "$WORK/top.json" > "$WORK/state" || exit 2
  if ask same-action same_action "$WORK/state"; then
    id="$(jq -r --argjson i "$i" '.[$i].id' "$WORK/top.json")"
    emit reduces_to "$id" "$CONF" confident; exit 0
  fi
  i=$((i + 1))
done
if ask invariant invariant "$WORK/candidate"; then emit new_invariant null "$CONF" confident; exit 0; fi
if ask one-off-measurement one_off_measurement "$WORK/candidate"; then emit one_off_measurement null "$CONF" confident; exit 0; fi
emit noise null "$CONF" confident
