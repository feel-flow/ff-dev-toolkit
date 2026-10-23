#!/usr/bin/env bash
# Isolated file-provider helper tests. Optional args: helper path, fixture directory.
# These overrides let miss/mutation probes run without editing the live source.
# 空振り検出: helper不在/不可読/空/名前のみ、fixture不在/不可読/書式変更/case集合[]・親子途中終了の10針でrc1を実測。
# 変異検出: 一意性/scope/phase/position/JSON構文/false-null/raw/last/PLAN待機/CRLF等の単独11変異は全てrc1。
set -euo pipefail

SELF_DIR="$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd -P)" || exit 1
ROOT="$(CDPATH='' cd -P -- "$SELF_DIR/../.." && pwd -P)" || exit 1
PASS=0; FAIL=0
ok() { printf '  ✓ %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  ✗ %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

if [ "${1:-}" != --worker ]; then
  TARGET="${1:-$ROOT/scripts/lib/github-input.sh}"
  FIX="${2:-$SELF_DIR/fixtures}"
  for dep in bash env jq cat mktemp rm cmp awk dirname chmod; do
    command -v "$dep" >/dev/null 2>&1 || { echo "missing dependency: $dep" >&2; exit 1; }
  done
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/github-input-suite.XXXXXX")" || exit 1
  REACHED_END=0
  cleanup() {
    local rc=$?
    rm -rf "$TMP" || rc=1
    if [ "$REACHED_END" -ne 1 ] && [ "$rc" -eq 0 ]; then
      echo 'github-input: suite did not reach its assertions' >&2
      rc=1
    fi
    exit "$rc"
  }
  trap cleanup EXIT
  trap 'exit 130' HUP INT TERM
  mkdir "$TMP/bin" || exit 1
  # ACE-2269-7 / ACE-1866-2: no host PATH tail, and forwarding scripts, not copied binaries.
  for dep in jq cat mktemp rm cmp awk dirname chmod; do
    real="$(command -v "$dep")" || exit 1
    printf '#!/bin/bash\nexec %q "$@"\n' "$real" >"$TMP/bin/$dep"
    chmod +x "$TMP/bin/$dep" || exit 1
  done
  bash_path="$(command -v bash)" || exit 1
  env -i PATH="$TMP/bin" TMPDIR="$TMP" LC_ALL=C \
    "$bash_path" "$SELF_DIR/verify.sh" --worker "$TARGET" "$FIX" "$TMP"
  if [ ! -s "$TMP/completed" ]; then
    echo 'github-input: worker did not complete its assertions' >&2
    exit 1
  fi
  REACHED_END=1
  exit 0
fi

TARGET="$2"; FIX="$3"; TMP="$4"
if command -v gh >/dev/null 2>&1; then bad 'gh leaked into isolated PATH'; exit 1; fi
if [ ! -f "$TARGET" ] || [ ! -r "$TARGET" ]; then bad 'helper missing or unreadable'; exit 1; fi
# shellcheck disable=SC1090 # checked optional fixture target
if ! . "$TARGET"; then bad 'helper could not be sourced'; exit 1; fi
if ! declare -F github_file_read >/dev/null || ! declare -F github_file_plan >/dev/null; then
  bad 'helper API missing'; exit 1
fi
# A flag keeps the jq framing probe defined before every jq call (SC2218).
JQ_CRLF_PROBE=0
jq() {
  if [ "$JQ_CRLF_PROBE" -eq 1 ]; then command jq "$@" | awk '{printf "%s\r\n",$0}'
  else command jq "$@"; fi
}
if ! jq -e '
  type == "array" and length > 0 and (map(.name) | unique | length) == length and
  all(.[]; (.name | type == "string") and (.index | type == "string") and
    (.scope | type == "string") and (.phase | type == "string") and
    (.position | type == "string") and (.expected | type == "string") and
    (.rc == 0 or .rc == 2) and (.last | type == "string") and (.http | type == "string"))
' "$FIX/cases.json" >/dev/null 2>"$TMP/manifest.err"; then
  bad 'nonempty, readable case collection required'; exit 1
fi
if ! jq -r '.[] | [.name,.index,.scope,.phase,.position,.expected,(.rc|tostring),.last,.http] | @tsv' \
  "$FIX/cases.json" >"$TMP/cases.tsv"; then bad 'cannot enumerate cases'; exit 1; fi
COUNT=0
# Last/http use explicit sentinel strings so read does not collapse empty TSV columns.
while IFS=$'\t' read -r name index scope phase position expected wanted last http; do
  COUNT=$((COUNT + 1))
  GITHUB_INPUT_LAST=stale; GITHUB_INPUT_HTTP_STATUS=stale
  if github_file_read "$FIX/$index" sample.read "$FIX/$scope" "$phase" "$FIX/$position" \
    >"$TMP/out" 2>"$TMP/err"; then rc=0; else rc=$?; fi
  if [ "$rc" -ne "$wanted" ]; then bad "$name rc=$rc expected=$wanted"; continue; fi
  if ! cmp -s "$TMP/out" "$FIX/$expected"; then bad "$name raw stdout differs"; continue; fi
  if [ "$wanted" -eq 0 ]; then
    [ "$last" != absent ] || last=""
    [ "$http" != absent ] || http=""
    if [ -s "$TMP/err" ] || [ "$GITHUB_INPUT_LAST" != "$last" ] || [ "$GITHUB_INPUT_HTTP_STATUS" != "$http" ]; then
      bad "$name stderr/globals differ"; continue
    fi
  elif [ ! -s "$TMP/err" ] || [ -n "$GITHUB_INPUT_LAST" ] || [ -n "$GITHUB_INPUT_HTTP_STATUS" ]; then
    bad "$name unavailable lacks diagnosis or kept stale globals"; continue
  fi
  ok "$name"
done <"$TMP/cases.tsv"
[ "$COUNT" -gt 0 ] || bad 'case enumeration matched zero rows'

printf '{}\n' >"$TMP/unreadable.json"
jq -n --arg body "$TMP/unreadable.json" --slurpfile scope "$FIX/scope.json" \
  '{version:1,responses:[{operation:"sample.read",scope:$scope[0],phase:"initial",body:$body}]}' >"$TMP/index.json" || exit 1
chmod 000 "$TMP/unreadable.json" || exit 1
if github_file_read "$TMP/index.json" sample.read "$FIX/scope.json" initial "$FIX/position.json" \
  >"$TMP/out" 2>"$TMP/err"; then rc=0; else rc=$?; fi
chmod 600 "$TMP/unreadable.json" || exit 1
if [ "$rc" -eq 2 ] && [ ! -s "$TMP/out" ] && [ -s "$TMP/err" ]; then ok 'unreadable body'; else bad 'unreadable body (requires unprivileged test user)'; fi

# A failed source copy may produce a prefix. It must not become accepted body stdout.
printf '{}\n' >"$TMP/read-failure.json"
jq --arg body "$TMP/read-failure.json" '.responses[0].body=$body' "$TMP/index.json" >"$TMP/fault-index.json" || exit 1
cat() {
  if [ "${1:-}" = "$TMP/read-failure.json" ]; then printf 'partial'; return 1; fi
  command cat "$@"
}
if github_file_read "$TMP/fault-index.json" sample.read "$FIX/scope.json" initial "$FIX/position.json" \
  >"$TMP/out" 2>"$TMP/err"; then rc=0; else rc=$?; fi
unset -f cat
if [ "$rc" -eq 2 ] && [ ! -s "$TMP/out" ] && [ -s "$TMP/err" ]; then ok 'partial source read is unavailable'; else bad 'partial source read'; fi

if github_file_read >"$TMP/out" 2>"$TMP/err"; then rc=0; else rc=$?; fi
if [ "$rc" -eq 64 ] && [ ! -s "$TMP/out" ] && [ -s "$TMP/err" ]; then ok 'read API misuse'; else bad 'read API misuse'; fi
if github_file_read relative.json sample.read "$FIX/scope.json" initial "$FIX/position.json" \
  >"$TMP/out" 2>"$TMP/err"; then rc=0; else rc=$?; fi
if [ "$rc" -eq 64 ] && [ ! -s "$TMP/out" ]; then ok 'absolute index prerequisite'; else bad 'absolute index prerequisite'; fi

# Large string is supplied through files, including Unicode, quotes and trailing LF.
awk 'BEGIN { for (i=0;i<160000;i++) printf "x" }' >"$TMP/large.txt" || exit 1
printf "'日本語\n\n" >>"$TMP/large.txt"
jq --arg body "$TMP/large.txt" '.responses[0].body=$body | .responses[0].format="text"' "$TMP/index.json" >"$TMP/text-index.json" || exit 1
if github_file_read "$TMP/text-index.json" sample.read "$FIX/scope.json" initial "$FIX/position.json" \
  >"$TMP/out" 2>"$TMP/err"; then rc=0; else rc=$?; fi
if [ "$rc" -eq 0 ] && [ ! -s "$TMP/err" ] && cmp -s "$TMP/large.txt" "$TMP/out"; then ok 'large raw text preserves trailing blank line'; else bad 'large raw text'; fi
jq -n --rawfile body "$TMP/large.txt" '{body:$body,title:"引用 '\''"}' >"$TMP/arguments.json" || exit 1
jq --arg body "$TMP/arguments.json" '.responses[0].body=$body' "$TMP/index.json" >"$TMP/large-index.json" || exit 1
if github_file_read "$TMP/large-index.json" sample.read "$FIX/scope.json" initial "$FIX/position.json" \
  >"$TMP/out" 2>"$TMP/err"; then rc=0; else rc=$?; fi
if [ "$rc" -eq 0 ] && [ ! -s "$TMP/err" ] && cmp -s "$TMP/arguments.json" "$TMP/out"; then ok 'large raw JSON via absolute body path'; else bad 'large raw JSON'; fi
if github_file_plan sample.write "$FIX/scope.json" "$TMP/arguments.json" "$FIX/readback.json" \
  >"$TMP/plan" 2>"$TMP/err"; then rc=0; else rc=$?; fi
IFS= read -r line <"$TMP/plan" || line=""
case "$line" in PLAN:*) printf '%s\n' "${line#PLAN:}" >"$TMP/plan.json" ;; *) bad 'PLAN prefix missing'; printf '{}\n' >"$TMP/plan.json" ;; esac
if [ "$rc" -eq 2 ] && [ ! -s "$TMP/err" ] && jq -e \
  --slurpfile scope "$FIX/scope.json" --slurpfile arguments "$TMP/arguments.json" --slurpfile readback "$FIX/readback.json" \
  '. == {operation:"sample.write",scope:$scope[0],arguments:$arguments[0],readback:$readback[0]}' \
  "$TMP/plan.json" >/dev/null && jq -j '.arguments.body' "$TMP/plan.json" >"$TMP/roundtrip" \
  && cmp -s "$TMP/large.txt" "$TMP/roundtrip"; then
  ok 'PLAN pending rc2 / exact file arguments / large Unicode LF roundtrip'
else bad 'PLAN pending / exact arguments'; fi

# Simulate jq.exe output framing only; this does not claim native Windows execution.
JQ_CRLF_PROBE=1
if github_file_read "$FIX/index.json" sample.read "$FIX/scope.json" page "$FIX/page.json" \
  >"$TMP/out" 2>"$TMP/err"; then rc=0; else rc=$?; fi
if [ "$rc" -eq 0 ] && [ ! -s "$TMP/err" ] && cmp -s "$FIX/raw.json" "$TMP/out" \
  && [ "$GITHUB_INPUT_LAST" = false ] && [ "$GITHUB_INPUT_HTTP_STATUS" = 200 ]; then
  ok 'CRLF jq metadata preserves raw body'
else bad 'CRLF jq metadata'; fi
if github_file_plan sample.write "$FIX/scope.json" "$TMP/arguments.json" "$FIX/readback.json" \
  >"$TMP/crlf-plan" 2>"$TMP/err"; then rc=0; else rc=$?; fi
JQ_CRLF_PROBE=0
if [ "$rc" -eq 2 ] && [ ! -s "$TMP/err" ] && cmp -s "$TMP/plan" "$TMP/crlf-plan"; then
  ok 'CRLF jq PLAN retains LF frame'
else bad 'CRLF jq PLAN'; fi

for invalid in absent.json false.json stream.json malformed.json empty.out; do
  if github_file_plan sample.write "$FIX/scope.json" "$FIX/$invalid" "$FIX/readback.json" \
    >"$TMP/out" 2>"$TMP/err"; then rc=0; else rc=$?; fi
  if [ "$rc" -eq 2 ] && [ ! -s "$TMP/out" ] && [ -s "$TMP/err" ]; then ok "PLAN invalid $invalid"; else bad "PLAN invalid $invalid"; fi
done
if github_file_plan >"$TMP/out" 2>"$TMP/err"; then rc=0; else rc=$?; fi
if [ "$rc" -eq 64 ] && [ ! -s "$TMP/out" ] && [ -s "$TMP/err" ]; then ok 'PLAN API misuse'; else bad 'PLAN API misuse'; fi

printf 'github-input: %s pass / %s fail; cases=%s\n' "$PASS" "$FAIL" "$COUNT"
if [ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]; then
  printf 'complete\n' >"$TMP/completed"
else exit 1; fi
