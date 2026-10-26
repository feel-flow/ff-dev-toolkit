#!/usr/bin/env bash
# Isolated file-provider helper tests. Optional args: helper path, fixture directory.
# These overrides let miss/mutation probes run without editing the live source.
# 空振り検出: helper不在/不可読/空/名前のみ、fixture不在/不可読/書式変更/case集合[]・親子途中終了の10針でrc1を実測。
# 変異検出: 一意性/scope/phase/position/JSON構文/false-null/raw/last/PLAN待機/CRLF等の単独11変異は全てrc1。
# 空振り検出: ドライブ文字の形（Issue `#2334`。2026-10-26 に WSL で実測、変異なしは 56 pass）。MSYS の分岐を外す → 6 件赤、OS を問わずドライブ文字を受け付ける → 4 件赤、body の解決を `/` 始まりだけに戻す → 1 件赤、index のディレクトリを OS を問わず `\` でも切る → 1 件赤、MSYS でも `\` で切らない → 1 件赤。表の行数が 11 でない回も赤（表の読み落としを緑へ倒さない）。Windows の Git Bash では受理側（`pwd -W` の実パス）も緑。`\` 入りファイル名のケースは実ホストが POSIX のときだけ走る（MSYS では `\` が区切りになり fixture を作れない。2 巡目のレビューで指摘）。Windows では既存ケースの body も `jq.exe` への引数変換で `C:/…` になるので、修正前は「読めない body」「途中で失敗する読み取り」が連結の誤りで偶然緑・大きな body の 2 件が赤だったのが、修正後は大きな body が緑になり、chmod / 関数差し替えが効かない前 2 件が赤になる（stderr/globals の CRLF 10 件は新旧とも赤）。
set -euo pipefail

SELF_DIR="$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd -P)" || exit 1
ROOT="$(CDPATH='' cd -P -- "$SELF_DIR/../.." && pwd -P)" || exit 1
PASS=0; FAIL=0
ok() { printf '  ✓ %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  ✗ %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

if [ "${1:-}" != --worker ]; then
  TARGET="${1:-$ROOT/scripts/lib/github-input.sh}"
  FIX="${2:-$SELF_DIR/fixtures}"
  for dep in bash env jq cat mktemp rm cmp awk dirname chmod mkdir; do
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
  for dep in jq cat mktemp rm cmp awk dirname chmod mkdir; do
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

# Drive-letter paths are absolute only on Git Bash (MSYS / Cygwin) hosts. OSTYPE is the switch,
# so the table runs both host kinds on any OS; restore the real value afterwards.
if ! declare -F github_input_is_absolute >/dev/null; then bad 'github_input_is_absolute missing'; fi
real_ostype="${OSTYPE:-}"
ABS_CASES=0
while IFS='|' read -r ostype path want; do
  ABS_CASES=$((ABS_CASES + 1))
  OSTYPE="$ostype"
  if github_input_is_absolute "$path"; then got=0; else got=1; fi
  OSTYPE="$real_ostype"
  if [ "$got" = "$want" ]; then ok "absolute rule $ostype $path -> $want"; else bad "absolute rule $ostype $path -> $got (want $want)"; fi
done <<'CASES'
linux-gnu|/abs/x|0
linux-gnu|C:/x|1
darwin23|D:\x|1
linux-gnu|rel/x|1
msys|C:/x|0
msys|c:\x|0
cygwin|D:/x|0
msys|/c/x|0
msys|C:x|1
msys|rel/x|1
msys||1
CASES
[ "$ABS_CASES" -eq 11 ] || bad "absolute rule table read $ABS_CASES rows"
# A drive-letter body is used as is on MSYS and joined to the index directory elsewhere.
drive_body='C:/ff-github-input-drive/absent.json'
jq --arg body "$drive_body" '.responses[0].body=$body' "$TMP/index.json" >"$TMP/drive-index.json" || exit 1
for ostype in msys linux-gnu; do
  OSTYPE="$ostype"
  if github_file_read "$TMP/drive-index.json" sample.read "$FIX/scope.json" initial "$FIX/position.json" \
    >"$TMP/out" 2>"$TMP/err"; then rc=0; else rc=$?; fi
  OSTYPE="$real_ostype"
  if [ "$ostype" = msys ]; then want_path="$drive_body"; else want_path="$TMP/$drive_body"; fi
  if [ "$rc" -eq 2 ] && [ ! -s "$TMP/out" ] \
    && [ "$(cat "$TMP/err")" = "github-input: sample.read body: unreadable, empty or missing file: $want_path" ]; then
    ok "drive-letter body resolves as $want_path on $ostype"
  else bad "drive-letter body on $ostype rc=$rc err=$(cat "$TMP/err")"; fi
done
OSTYPE=linux-gnu
if github_file_read 'C:/ff-github-input-drive/index.json' sample.read "$FIX/scope.json" initial "$FIX/position.json" \
  >"$TMP/out" 2>"$TMP/err"; then rc=0; else rc=$?; fi
OSTYPE="$real_ostype"
if [ "$rc" -eq 64 ] && [ ! -s "$TMP/out" ]; then ok 'drive-letter index stays relative off MSYS'; else bad "drive-letter index off MSYS rc=$rc"; fi
# Acceptance: on MSYS a drive-letter index is read like a / index, in both separator forms, and
# its relative body resolves next to it. On a real MSYS host the paths are $TMP's own C:/ name;
# elsewhere the drive name is simulated under the cwd ($TMP): C:/gi-drive is a directory named
# "C:", and the backslash form is a directory and an index whose names contain \ literally.
# Cygwin's pwd has no -W and the worker has no cygpath, so a real Cygwin host skips these cases.
drive_forms='fwd bs'
case "$real_ostype" in
  msys*) drive_fwd="$(cd "$TMP" && pwd -W)/gi-drive"; fs_prefix='' ;;
  cygwin*) drive_fwd=''; fs_prefix=''; drive_forms=''
    printf '  ○ skip: MSYS drive-letter acceptance needs pwd -W (real host is Cygwin)\n' ;;
  *) drive_fwd='C:/gi-drive'; fs_prefix="$TMP/" ;;
esac
drive_bs="${drive_fwd//\//\\}"
printf '{"drive":true}\n' >"$TMP/drive-body.json"
for form in $drive_forms; do
  if [ "$form" = fwd ]; then dir="$drive_fwd"; index="$drive_fwd/index.json"; else dir="$drive_bs"; index="$drive_bs\\index.json"; fi
  mkdir -p "$fs_prefix$dir" || exit 1
  cat "$TMP/drive-body.json" >"$fs_prefix$dir/body.json" || exit 1
  jq '.responses[0].body="body.json"' "$TMP/index.json" >"$fs_prefix$index" || exit 1
  if ( cd "$TMP" || exit 1; OSTYPE=msys; github_file_read "$index" sample.read "$FIX/scope.json" initial "$FIX/position.json" ) \
    >"$TMP/out" 2>"$TMP/err"; then rc=0; else rc=$?; fi
  if [ "$rc" -eq 0 ] && [ ! -s "$TMP/err" ] && cmp -s "$TMP/drive-body.json" "$TMP/out"; then
    ok "MSYS reads a drive-letter index ($form) and its relative body"
  else bad "MSYS drive-letter index ($form) rc=$rc err=$(cat "$TMP/err")"; fi
done
# Off MSYS, \ is an ordinary file-name character: the body sits next to an index named a\b.json.
# Only a POSIX file system can hold that name, so a real MSYS / Cygwin host skips this case.
case "$real_ostype" in
  msys* | cygwin*) printf '  ○ skip: a file name containing \\ needs a POSIX file system (real host is %s)\n' "$real_ostype" ;;
  *)
    mkdir -p "$TMP/bs-posix" || exit 1
    cat "$TMP/drive-body.json" >"$TMP/bs-posix/body.json" || exit 1
    jq '.responses[0].body="body.json"' "$TMP/index.json" >"$TMP/bs-posix/a\\b.json" || exit 1
    OSTYPE=linux-gnu
    if github_file_read "$TMP/bs-posix/a\\b.json" sample.read "$FIX/scope.json" initial "$FIX/position.json" \
      >"$TMP/out" 2>"$TMP/err"; then rc=0; else rc=$?; fi
    OSTYPE="$real_ostype"
    if [ "$rc" -eq 0 ] && cmp -s "$TMP/drive-body.json" "$TMP/out"; then ok 'off MSYS a \ in the index name does not split the directory'; else bad "off MSYS backslash index name rc=$rc err=$(cat "$TMP/err")"; fi
    ;;
esac

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
