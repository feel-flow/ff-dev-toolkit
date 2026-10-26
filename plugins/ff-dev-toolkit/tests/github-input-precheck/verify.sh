#!/usr/bin/env bash
# gh/file acquisition parity; no network, real writes only to disposable Git fixtures.
# 空振り検出: 2026-10-22 macOSで17種を実測。case不在/読めない/空集合/書式変更/名前だけ残す、source不在/空/名前だけ残す、helper読めない、MCP fixture不在、親/worker早期exit0、scalar抽出0、ready集合0は全てrc1。
# 空振り検出: scratchのsource写しで最終PR phaseをinitialへ戻す・必須field検査を迂回する・次thread cursorを捨てる変異も全てrc1。正常8 goldenは6面bytes一致。抽出0/重複の負対照は完全なready出力を起点にする。
# Optional arguments: plugin root, case manifest, evidence directory.
# run-all-required: yes — 必須raw不足の停止とgh/file6面一致を検証し、取得失敗を成功へ倒さない
# 空振り検出: 2026-10-23 R1で明示incomplete/non200 guardの逆変異は4件だけ赤、attemptを常時1へ戻す逆変異もCheckRun/StatusContextの成功・失敗4件だけ赤。正常69件・ready8件はrc0。
# 空振り検出: 2026-10-23 R2はCheckRunを空conclusion/IN_PROGRESS→SUCCESSまたはFAILURE/COMPLETEDで測定。正常69件rc0、attempt常時1の逆変異は4件だけ赤。
# 空振り検出: 2026-10-26（Issue `#2367`）WSL で正常 82 件。ace-pending.sh を独自の `/` 判定へ戻す → 1 件赤（各箇所の照合表 7 行。行数が 7 でない回・表の箇所のファイルが無い回も赤）。
# 空振り検出: 2026-10-26（Issue `#2334`）WSL で正常 74 件。共有判定が OS を問わずドライブ文字を受け付ける → 1 件赤、finish.sh を独自の `/` 判定へ戻す → 1 件赤、link-sub-issues.sh の判定を外す → 3 件赤。

set -euo pipefail
SELF="$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd -P)" || exit 1
if [ "${1:-}" != --worker ]; then
  PLUGIN="${1:-$(CDPATH='' cd -P -- "$SELF/../.." && pwd -P)}"
  CASES="${2:-$SELF/fixtures/cases.json}"
  TMP="$(mktemp -d)" || exit 1
  parent_completed=0
  parent_cleanup() {
    local rc=$?
    rm -rf "$TMP" || rc=1
    if [ "$parent_completed" -ne 1 ] && [ "$rc" -eq 0 ]; then
      echo 'github-input-precheck: parent incomplete' >&2; rc=1
    fi
    exit "$rc"
  }
  trap parent_cleanup EXIT
  mkdir "$TMP/bin"
  for tool in bash sh env git jq awk grep sed head tail cut tr cat dirname basename mktemp rm wc sort uname date tee cp mv chmod mkdir rmdir sleep cmp comm uniq find du tar gzip stat readlink; do
    real="$(command -v "$tool")" || exit 1
    printf '#!/bin/bash\nexec %q "$@"\n' "$real" >"$TMP/bin/$tool"
    chmod +x "$TMP/bin/$tool"
  done
  bash_real="$(command -v bash)"
  env -i PATH="$TMP/bin" TMPDIR="$TMP" LC_ALL=C GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_ALLOW_PROTOCOL=file CLAUDE_CONFIG_DIR="$TMP/claude" \
    "$bash_real" "$SELF/verify.sh" --worker "$PLUGIN" "$CASES" "$TMP" "${3:-}"
  [ -s "$TMP/completed" ] || { echo 'github-input-precheck: worker incomplete' >&2; exit 1; }
  parent_completed=1
  exit 0
fi
PLUGIN="$2"; CASES="$3"; TMP="$4"; EVIDENCE="${5:-}"
PASS=0; FAIL=0; READY=0
ok() { printf '  ✓ %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  ✗ %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
for file in scripts/finish.sh scripts/lib/finish-precheck.sh scripts/lib/abs-path.sh scripts/lib/github-input.sh scripts/lib/merge-message.sh scripts/link-sub-issues.sh scripts/merge-cleanup.sh tests/lib/git-fixture.sh; do
  [ -s "$PLUGIN/$file" ] && [ -r "$PLUGIN/$file" ] || { bad "source missing/unreadable/empty: $file"; exit 1; }
done
if ! jq -e 'type == "array" and length > 0 and (map(.name) | unique | length) == length and
  any(.[]; .refs==true) and any(.[]; .separate==true) and any(.[]; .separate==false) and
  any(.[]; .thread_kind=="replied") and any(.[]; .thread_kind=="nullable-replied") and
  any(.[]; .refs==true and .separate==true) and any(.[]; .checks==true) and any(.[]; .pages==true) and any(.[]; .fork==true) and all(.[];
  (.name | type == "string" and test("^[A-Za-z0-9_-]+$")) and (.refs | type == "boolean") and (.separate | type == "boolean") and
  (.checks | type == "boolean") and (.pages | type == "boolean") and (.fork | type == "boolean") and
  ((.thread_kind // "empty") | . == "empty" or . == "replied" or . == "nullable-replied"))' "$CASES" >/dev/null; then
  bad 'nonempty readable case collection required'; exit 1
fi
# shellcheck source=../lib/git-fixture.sh
. "$PLUGIN/tests/lib/git-fixture.sh"
# shellcheck source=../../scripts/lib/github-input.sh
. "$PLUGIN/scripts/lib/github-input.sh"
git() { printf '%s\n' "$utility_origin"; }
for transport in scp ssh https http local query; do
  utility_expected=https://github.example.test/owner/repo
  case "$transport" in
    scp) utility_origin=git@github.example.test:owner/repo.git ;;
    ssh) utility_origin=ssh://git@github.example.test/owner/repo.git ;;
    https) utility_origin=https://github.example.test:8443/owner/repo.git; utility_expected=https://github.example.test:8443/owner/repo ;;
    http) utility_origin=http://github.example.test/owner/repo/; utility_expected=http://github.example.test/owner/repo ;;
    local) utility_origin=/tmp/local.git; utility_expected=unavailable ;;
    query) utility_origin="https://github.example.test/owner/repo?x"; utility_expected=unavailable ;;
  esac
  if utility_out="$(_github_input_repository 2>"$TMP/utility.err")"; then utility_rc=0; else utility_rc=$?; fi
  if { [ "$utility_expected" = unavailable ] && [ "$utility_rc" -eq 2 ]; } || { [ "$utility_expected" != unavailable ] && [ "$utility_rc" -eq 0 ] && [ "$utility_out" = "$utility_expected" ]; }; then
    ok "Git-anchored repository utility: $transport"
  else bad "Git-anchored repository utility: $transport"; fi
done
unset -f git
WORK="$TMP/work"; URL=https://github.example.test/owner/repo
ff_git_fixture_init "$WORK" || exit 1
g() { git -c commit.gpgsign=false "$@"; }
g -C "$WORK" symbolic-ref HEAD refs/heads/develop
printf 'seed\n' >"$WORK/seed"
g -C "$WORK" add seed; g -C "$WORK" commit -qm seed
g init -q --bare "$TMP/origin.git"
g -C "$WORK" remote add origin "$URL"
g -C "$WORK" config "url.$TMP/origin.git.insteadOf" "$URL"
g -C "$WORK" push -q origin develop
g -C "$WORK" switch -qc 'feature/#7-file'
printf 'feature\n' >"$WORK/feature"
g -C "$WORK" add feature; g -C "$WORK" commit -qm 'work'
g -C "$WORK" push -qu origin 'feature/#7-file'
g -C "$WORK" remote set-head origin develop
OID="$(g -C "$WORK" rev-parse HEAD)"
printf '{"nameWithOwner":"owner/repo","url":"%s"}\n' "$URL" >"$TMP/repo.json"
printf '{}\n' >"$TMP/position.json"
cat >"$TMP/bin/gh" <<'GH'
#!/bin/bash
t="$(dirname "$0")/.."
printf '%s\n' "$*" >>"$t/gh-calls"
[ "$(cat "$t/mode")" != file ] || { echo 'gh leaked in file mode' >&2; exit 97; }
case "$1 $2" in
  'pr view') cat "$t/pr.json" ;;
  'repo view') cat "$t/repo.json" ;;
  'pr checks') exit 0 ;;
  'api graphql') case "$*" in *after=*) cat "$t/threads2.json" ;; *) cat "$t/threads1.json" ;; esac ;;
  *) echo 'unexpected gh call' >&2; exit 98 ;;
esac
GH
chmod +x "$TMP/bin/gh"
save_case() {
  [ -n "$EVIDENCE" ] || return 0
  case "$EVIDENCE" in /*) ;; *) bad 'evidence directory must be absolute'; return 1 ;; esac
  mkdir -p "$EVIDENCE/$1"
  printf '%s\n' "$TMP" >"$EVIDENCE/$1/original-input-root.txt"
  local file
  for file in pr.json final.json threads1.json threads2.json thread-bad.json repo.json index.json base-index.json bad.json nonempty-thread.json body message extractor-baseline \
    gh.out gh.err gh.rc gh.argv0 gh.gh-calls file.out file.err file.rc file.argv0 file.gh-calls \
    negative.out negative.err negative.rc negative.argv0 negative.gh-calls \
    retry-first.json retry-next.json refs-after full-open-truth.json cleanup.json merged.json link-index.json membership.json child.json empty.json after.json plan.json gate-saved gate-old; do
    if [ -f "$TMP/$file" ]; then
      if [ -r "$TMP/$file" ]; then cp "$TMP/$file" "$EVIDENCE/$1/$file"
      else printf '%s: unreadable to suite process\n' "$file" >>"$EVIDENCE/$1/unreadable-inputs.txt"; fi
    fi
  done
}
run() { # mode / output prefix / script / arguments
  local mode="$1" prefix="$2" script="$3"; shift 3
  printf '%s\n' "$mode" >"$TMP/mode"; : >"$TMP/gh-calls"
  printf '%s\0' bash "$script" "$@" >"$TMP/$prefix.argv0"
  if (cd "$WORK"; bash "$script" "$@") >"$TMP/$prefix.out" 2>"$TMP/$prefix.err"; then RC=0; else RC=$?; fi
  printf '%s\n' "$RC" >"$TMP/$prefix.rc"
  cp "$TMP/gh-calls" "$TMP/$prefix.gh-calls"
  if [ "$mode" = file ] && [ -s "$TMP/gh-calls" ]; then bad "$prefix: gh call leak"; fi
}
index_base() {
  jq -n --arg repository "$URL" --arg dir "$TMP" '{version:1,responses:[
    {operation:"finish.precheck.pr",scope:{repository:$repository,pr:7},phase:"initial",body:($dir+"/pr.json")},
    {operation:"finish.precheck.pr",scope:{repository:$repository,pr:7},phase:"after-threads",body:($dir+"/pr.json")},
    {operation:"finish.precheck.repo",scope:{repository:$repository},phase:"initial",body:($dir+"/repo.json")},
    {operation:"finish.precheck.threads",scope:{repository:$repository,pr:7,first:100,comments_first:100},phase:"after-checks",body:($dir+"/threads1.json")},
    {operation:"finish.precheck.checks-retry",scope:{repository:$repository,pr:7},phase:"checks-retry",attempt:1,body:($dir+"/pr.json")}
  ]}' >"$TMP/index.json"
}
extract() { # output / destination prefix: require exactly the five lines and whole block
  local key n=0
  for key in PRECHECK KEYWORD_GATE MERGE_MESSAGE_GATE FRESH_STATUS REVIEW_THREADS_UNANSWERED; do
    n=$((n + 1))
    awk -v key="$key=" 'index($0,key)==1 { print; n++ } END { if(n!=1) exit 1 }' "$1" >"$2.$key" || return 1
  done
  [ "$n" -eq 5 ] || return 1
  awk '$0=="MERGE_COMMAND_BEGIN" { b++; inside=1 } inside { print }
    $0=="MERGE_COMMAND_END" { e++; inside=0 } END { if(b!=1 || e!=1 || inside) exit 1 }' "$1" >"$2.MERGE_COMMAND" || return 1
  [ -s "$2.MERGE_COMMAND" ]
}
printf "日本語 ' 引用\n末尾\n\nX" >"$TMP/message"
MERGE_BODY="$(cat "$TMP/message")"; MERGE_BODY="${MERGE_BODY%X}"
awk 'BEGIN { for(i=0;i<160000;i++) printf "x"; print "" }' >"$TMP/large"
jq -r '.[] | [.name,.refs,.separate,.checks,.pages,.fork,(.thread_kind // "empty")] | @tsv' "$CASES" >"$TMP/cases"
COUNT=0
while IFS=$'\t' read -r name refs separate checks pages fork thread_kind; do
  COUNT=$((COUNT + 1)); args=()
  if [ "$refs" = true ]; then
    printf 'Refs #%s\n' 9 >"$TMP/body"; cat "$TMP/large" >>"$TMP/body"
    args=(--subject "日本語 ' 件名" --body "$MERGE_BODY")
  else printf 'Closes #%s\n' 7 >"$TMP/body"; fi
  jq -n --arg head "$OID" --rawfile body "$TMP/body" --argjson checks "$checks" --argjson cross "$fork" '{
    number:7,state:"OPEN",isDraft:false,headRefName:"feature/#7-file",headRefOid:$head,baseRefName:"develop",
    isCrossRepository:$cross,title:"work",body:$body,closingIssuesReferences:[],
    commits:[{oid:$head,messageHeadline:"work",messageBody:""}],
    statusCheckRollup:(if $checks then [{name:"gate",conclusion:"SUCCESS"}] else [] end),
    additions:20,deletions:0,files:[{path:"feature"}]}' >"$TMP/pr.json"
  jq -n --argjson pages "$pages" '{data:{repository:{pullRequest:{author:{login:"author"},reviewThreads:{
    nodes:[],pageInfo:{hasNextPage:$pages,endCursor:(if $pages then "next" else null end)}}}}}}' >"$TMP/threads1.json"
  if [ "$thread_kind" != empty ]; then
    jq --arg kind "$thread_kind" --rawfile body "$TMP/large" '
      .data.repository.pullRequest |= (
        .author=(if $kind=="nullable-replied" then null else {login:"author"} end) |
        .reviewThreads.nodes=[{id:"replied-thread",isResolved:false,isOutdated:false,comments:{totalCount:2,nodes:[
          {author:(if $kind=="nullable-replied" then null else {login:"reviewer"} end),body:$body,
            path:(if $kind=="nullable-replied" then null else "feature" end),
            line:(if $kind=="nullable-replied" then null else 1 end),
            originalLine:(if $kind=="nullable-replied" then null else 1 end)},
          {author:{login:"author"},body:"修正しました。日本語と引用 \u0027",path:null,line:null,originalLine:null}]} }])' \
      "$TMP/threads1.json" >"$TMP/next"; mv "$TMP/next" "$TMP/threads1.json"
  fi
  jq '.data.repository.pullRequest.reviewThreads.pageInfo={hasNextPage:false,endCursor:null}' "$TMP/threads1.json" >"$TMP/threads2.json"
  index_base
  if [ "$pages" = true ]; then
    jq --arg body "$TMP/threads2.json" '.responses += [(.responses[3] | .cursor="next" | .body=$body)]' "$TMP/index.json" >"$TMP/next"; mv "$TMP/next" "$TMP/index.json"
  fi
  if [ "$separate" = true ]; then g -C "$WORK" worktree add -q "$TMP/base-holder" develop; fi
  (cd "$WORK"; bash "$PLUGIN/scripts/record-gate-head.sh" --gate tests/run-all.sh --status pass --mode fixture) >/dev/null 2>&1
  run gh gh "$PLUGIN/scripts/finish.sh" precheck 7 ${args[@]+"${args[@]}"}; gh_rc="$RC"
  run file file "$PLUGIN/scripts/finish.sh" precheck 7 --github-input "$TMP/index.json" ${args[@]+"${args[@]}"}
  if [ "$gh_rc" -eq 0 ] && [ "$RC" -eq 0 ] && extract "$TMP/gh.out" "$TMP/gh" && extract "$TMP/file.out" "$TMP/file"; then
    same=1
    for key in PRECHECK KEYWORD_GATE MERGE_MESSAGE_GATE FRESH_STATUS REVIEW_THREADS_UNANSWERED MERGE_COMMAND; do
      cmp -s "$TMP/gh.$key" "$TMP/file.$key" || same=0
    done
    if [ "$same" -eq 1 ] && grep -qxF 'PRECHECK=ready' "$TMP/file.out"; then READY=$((READY + 1)); cp "$TMP/file.out" "$TMP/extractor-baseline"; ok "six exact byte surfaces: $name"; else bad "six surfaces differ: $name"; fi
  else bad "ready/extraction failed: $name gh=$gh_rc file=$RC"; cat "$TMP/file.err" >&2; fi
  if [ "$separate" = true ]; then g -C "$WORK" worktree remove "$TMP/base-holder"; fi
  save_case "$name"
done <"$TMP/cases"
[ "$COUNT" -gt 0 ] && [ "$READY" -eq "$COUNT" ] || { bad 'ready coverage zero/incomplete'; exit 1; }

# Last golden is a ready nonempty nullable thread, without checks and with one complete page.
index_base
cp "$TMP/index.json" "$TMP/base-index.json"
negative() { # name / wanted rc / index / diagnostic needle
  run file negative "$PLUGIN/scripts/finish.sh" precheck 7 --github-input "$3"
  if [ "$RC" -eq "$2" ] && ! grep -qxF MERGE_COMMAND_BEGIN "$TMP/negative.out" && { grep -F "$4" "$TMP/negative.err" >/dev/null || grep -F "$4" "$TMP/negative.out" >/dev/null; }; then ok "$1"; else bad "$1 rc=$RC"; cat "$TMP/negative.err" >&2; fi
  save_case "$1"
}
# Keep legal nulls in raw; only missing fields fail closed in the new file branch.
cp "$TMP/threads1.json" "$TMP/nonempty-thread.json"
for field in author body path line originalLine; do
  jq --arg field "$field" 'del(.data.repository.pullRequest.reviewThreads.nodes[0].comments.nodes[0][$field])' "$TMP/nonempty-thread.json" >"$TMP/thread-bad.json"
  jq --arg body "$TMP/thread-bad.json" '(.responses[] | select(.operation=="finish.precheck.threads") | .body)=$body' "$TMP/base-index.json" >"$TMP/bad.json"
  negative "nonempty-thread-missing-$field" 2 "$TMP/bad.json" "$field"
done
negative missing-index 2 "$TMP/missing" finish.precheck.pr
printf '{' >"$TMP/bad.json"; negative bad-index 2 "$TMP/bad.json" finish.precheck.pr
jq '.responses=[]' "$TMP/base-index.json" >"$TMP/bad.json"; negative empty-responses 2 "$TMP/bad.json" finish.precheck.pr
jq '.responses += [.responses[0]]' "$TMP/base-index.json" >"$TMP/bad.json"; negative duplicate 2 "$TMP/bad.json" finish.precheck.pr
jq '(.responses[].scope.repository)="https://other.example/owner/repo"' "$TMP/base-index.json" >"$TMP/bad.json"; negative wrong-host 2 "$TMP/bad.json" finish.precheck.pr
jq '(.responses[] | select(.operation=="finish.precheck.pr") | .scope.pr)=8' "$TMP/base-index.json" >"$TMP/bad.json"; negative wrong-pr 2 "$TMP/bad.json" finish.precheck.pr
jq '.number=8' "$TMP/pr.json" >"$TMP/final.json"
jq --arg body "$TMP/final.json" '(.responses[] | select(.phase=="initial") | .body)=$body' "$TMP/base-index.json" >"$TMP/bad.json"; negative wrong-payload-pr 2 "$TMP/bad.json" number
jq 'del(.headRefOid)' "$TMP/pr.json" >"$TMP/final.json"
jq --arg body "$TMP/final.json" '(.responses[] | select(.phase=="after-threads") | .body)=$body' "$TMP/base-index.json" >"$TMP/bad.json"; negative final-head-missing 2 "$TMP/bad.json" headRefOid
jq '.headRefOid="0000000000000000000000000000000000000000"' "$TMP/pr.json" >"$TMP/final.json"; negative final-snapshot-changed 1 "$TMP/bad.json" PR_SNAPSHOT=changed
jq '.data.repository.pullRequest.reviewThreads.pageInfo={hasNextPage:true,endCursor:"missing"}' "$TMP/threads1.json" >"$TMP/thread-bad.json"
jq --arg body "$TMP/thread-bad.json" '(.responses[] | select(.operation=="finish.precheck.threads") | .body)=$body' "$TMP/base-index.json" >"$TMP/bad.json"; negative thread-next-page-missing 2 "$TMP/bad.json" finish.precheck.threads
jq '.data.repository.pullRequest.reviewThreads.pageInfo={hasNextPage:true,endCursor:null}' "$TMP/threads1.json" >"$TMP/thread-bad.json"; negative thread-cursor-missing 2 "$TMP/bad.json" cursor
for field in closingIssuesReferences commits statusCheckRollup files isDraft; do
  jq --arg field "$field" 'del(.[$field])' "$TMP/pr.json" >"$TMP/final.json"
  jq --arg body "$TMP/final.json" '(.responses[] | select(.phase=="initial") | .body)=$body' "$TMP/base-index.json" >"$TMP/bad.json"
  negative "mandatory-$field" 2 "$TMP/bad.json" "$field"
done
# REST/MCP count fields do not supply GraphQL closing refs, commit array or rollup.
MCP_RAW="${CASES%/*}/mcp-pr-partial.json"
[ -r "$MCP_RAW" ] && [ -s "$MCP_RAW" ] || { bad 'MCP mapping fixture missing/unreadable'; exit 1; }
jq --arg head "$OID" '.head.sha=$head | {number,state:(.state | ascii_upcase),isDraft:.draft,headRefName:.head.ref,headRefOid:.head.sha,
  baseRefName:.base.ref,isCrossRepository:(.head.repo.id!=.base.repo.id),title,body,additions,deletions}' "$MCP_RAW" >"$TMP/final.json"
jq --arg body "$TMP/final.json" '(.responses[] | select(.phase=="initial") | .body)=$body' "$TMP/base-index.json" >"$TMP/bad.json"
negative mcp-mapping-does-not-invent-missing-fields 2 "$TMP/bad.json" closingIssuesReferences
cp "$TMP/base-index.json" "$TMP/bad.json"; chmod 000 "$TMP/bad.json"; negative unreadable-index 2 "$TMP/bad.json" finish.precheck.pr; chmod 600 "$TMP/bad.json"
: >"$TMP/final.json"
jq --arg body "$TMP/final.json" '(.responses[] | select(.phase=="after-threads") | .body)=$body' "$TMP/base-index.json" >"$TMP/bad.json"; negative empty-final-body 2 "$TMP/bad.json" finish.precheck.pr
jq '.statusCheckRollup=[{name:"gate",state:"PENDING"}]' "$TMP/pr.json" >"$TMP/next"; mv "$TMP/next" "$TMP/pr.json"
jq '.responses += [(.responses[] | select(.operation=="finish.precheck.checks-retry") | .attempt=2),(.responses[] | select(.operation=="finish.precheck.checks-retry") | .attempt=3)]' "$TMP/base-index.json" >"$TMP/bad.json"
negative pending-max-three 2 "$TMP/bad.json" CHECKS=unavailable
# Distinct attempts exercise the consumer's position, not just helper selection.
for shape in check-run status-context; do
  for outcome in SUCCESS FAILURE; do
    if [ "$shape" = check-run ]; then
      printf '{"statusCheckRollup":[{"__typename":"CheckRun","name":"gate","conclusion":"","status":"IN_PROGRESS"}]}\n' >"$TMP/retry-first.json"
      jq --arg outcome "$outcome" '.statusCheckRollup[0] |= (.conclusion=$outcome | .status="COMPLETED")' "$TMP/retry-first.json" >"$TMP/retry-next.json"
    else
      printf '{"statusCheckRollup":[{"__typename":"StatusContext","context":"gate","state":"PENDING"}]}\n' >"$TMP/retry-first.json"
      jq --arg outcome "$outcome" '.statusCheckRollup[0].state=$outcome' "$TMP/retry-first.json" >"$TMP/retry-next.json"
    fi
    jq --arg first "$TMP/retry-first.json" --arg next "$TMP/retry-next.json" '
      (.responses[] | select(.operation=="finish.precheck.checks-retry") | .body)=$first |
      .responses += [(.responses[] | select(.operation=="finish.precheck.checks-retry") | .attempt=2 | .body=$next)]' "$TMP/base-index.json" >"$TMP/bad.json"
    run file file "$PLUGIN/scripts/finish.sh" precheck 7 --github-input "$TMP/bad.json"
    if [ "$outcome" = SUCCESS ]; then
      if [ "$RC" -eq 0 ] && grep -qxF 'CHECKS=passed' "$TMP/file.out" && grep -qxF 'PRECHECK=ready' "$TMP/file.out" && extract "$TMP/file.out" "$TMP/retry-extracted"; then ok "retry attempt1 pending -> attempt2 success: $shape"; else bad "retry success: $shape rc=$RC"; fi
    elif [ "$RC" -eq 1 ] && grep -qxF 'CHECKS=failed' "$TMP/file.out" && ! grep -q '^MERGE_COMMAND_BEGIN$' "$TMP/file.out" && ! grep -q '^PRECHECK=ready$' "$TMP/file.out"; then ok "retry attempt1 pending -> attempt2 failure: $shape"; else bad "retry failure: $shape rc=$RC"; fi
    save_case "retry-$shape-$outcome"
  done
done
jq '.statusCheckRollup=[]' "$TMP/pr.json" >"$TMP/next"; mv "$TMP/next" "$TMP/pr.json"
jq '.data.repository.pullRequest.reviewThreads.nodes=[{id:"thread",isResolved:false,isOutdated:false,comments:{totalCount:1,nodes:[{author:{login:"reviewer"},body:"直して",path:"feature",line:1,originalLine:1}]}}]' "$TMP/threads1.json" >"$TMP/thread-bad.json"
jq --arg body "$TMP/thread-bad.json" '(.responses[] | select(.operation=="finish.precheck.threads") | .body)=$body' "$TMP/base-index.json" >"$TMP/bad.json"; negative unanswered-thread 1 "$TMP/bad.json" REVIEW_THREADS_UNANSWERED=1
gate="$WORK/.git/ff-dev-toolkit/gate-record"
cp "$gate" "$TMP/gate-saved"
BASE_OID="$(g -C "$WORK" rev-parse origin/develop)"
sed "s/^COMMIT=.*/COMMIT=$BASE_OID/" "$gate" >"$TMP/gate-old"; cp "$TMP/gate-old" "$gate"
negative gate-head-mismatch 1 "$TMP/base-index.json" FRESH_STATUS=1
cp "$TMP/gate-saved" "$gate"

# Cleanup required identity is separate from deletion guard evidence; no real deletion.
jq '.state="MERGED" | .isCrossRepository=false' "$TMP/pr.json" >"$TMP/cleanup.json"
jq '[{headRefName,headRefOid,isCrossRepository,baseRefName}]' "$TMP/cleanup.json" >"$TMP/merged.json"
printf '[]\n' >"$TMP/empty.json"
jq -n --arg repository "$URL" --arg dir "$TMP" '{version:1,responses:[
 {operation:"finish.cleanup.state",scope:{repository:$repository,pr:7},phase:"cleanup-state",body:($dir+"/cleanup.json")},
 {operation:"cleanup.pr",scope:{repository:$repository,pr:7},phase:"cleanup-pr",body:($dir+"/cleanup.json")},
 {operation:"cleanup.merged-list",scope:{repository:$repository,state:"merged",limit:1000},phase:"cleanup-guards",body:($dir+"/merged.json")},
 {operation:"cleanup.open-list",scope:{repository:$repository,state:"open",limit:1000},phase:"cleanup-guards",body:($dir+"/empty.json")}
]}' >"$TMP/index.json"
run file file "$PLUGIN/scripts/finish.sh" cleanup --dry-run 7 --github-input "$TMP/index.json"
if [ "$RC" -eq 0 ] && grep -qxF 'CLEANUP_RC=0' "$TMP/file.out"; then ok 'finish cleanup context reaches real delegate'; else bad "cleanup context rc=$RC"; cat "$TMP/file.err" >&2; fi
save_case cleanup-context
cp "$TMP/cleanup.json" "$TMP/cleanup-saved"
for field in state headRefName baseRefName; do
  jq --arg field "$field" 'del(.[$field])' "$TMP/cleanup-saved" >"$TMP/cleanup.json"
  run file file "$PLUGIN/scripts/merge-cleanup.sh" --dry-run 7 --github-input "$TMP/index.json"
  if [ "$RC" -eq 2 ] && grep -F "$field" "$TMP/file.err" >/dev/null; then ok "cleanup mandatory $field"; else bad "cleanup mandatory $field rc=$RC"; fi
  save_case "cleanup-missing-$field"
done
cp "$TMP/merged.json" "$TMP/merged-saved"
# Independent factors: dry-run leaves the ref present even if Step6 can recover it.
for factor in oid-only merged-empty-only combined; do
  cp "$TMP/cleanup-saved" "$TMP/cleanup.json"; cp "$TMP/merged-saved" "$TMP/merged.json"
  if [ "$factor" != merged-empty-only ]; then jq 'del(.headRefOid)' "$TMP/cleanup-saved" >"$TMP/cleanup.json"; fi
  if [ "$factor" != oid-only ]; then printf '[]\n' >"$TMP/merged.json"; fi
  run file file "$PLUGIN/scripts/merge-cleanup.sh" --dry-run 7 --github-input "$TMP/index.json"
  if [ "$factor" = merged-empty-only ]; then
    if [ "$RC" -eq 2 ] && grep -F 'would_delete' "$TMP/file.out" >/dev/null && grep -F 'MERGED PR と OID 不一致' "$TMP/file.out" >/dev/null && ! grep -F 'skipped_oid_unavailable' "$TMP/file.out" >/dev/null; then ok 'cleanup valid empty merged list: PR OID permits remote preview, local merged anchor unavailable'; else bad "cleanup merged-empty-only rc=$RC"; fi
  elif [ "$RC" -eq 2 ] && grep -F 'skipped_oid_unavailable' "$TMP/file.out" >/dev/null && grep -F 'headRefOid' "$TMP/file.out" >/dev/null && { [ "$factor" != oid-only ] || grep -F 'リモート取り残し: 1 本' "$TMP/file.out" >/dev/null; }; then ok "cleanup $factor: PR OID absent, dry-run retains pending ref"; else bad "cleanup $factor rc=$RC"; fi
  save_case "cleanup-factor-$factor"
done
cp "$TMP/cleanup-saved" "$TMP/cleanup.json"; cp "$TMP/merged-saved" "$TMP/merged.json"
jq '.responses |= map(select(.operation!="cleanup.open-list"))' "$TMP/index.json" >"$TMP/bad.json"
run file file "$PLUGIN/scripts/merge-cleanup.sh" --dry-run 7 --github-input "$TMP/bad.json"
if [ "$RC" -eq 2 ] && grep -F 'fail-closed' "$TMP/file.out" >/dev/null; then ok 'cleanup unavailable open guard preserves assets'; else bad "cleanup open guard rc=$RC"; fi
save_case cleanup-open-guard


# All real deletes below target only this suite's disposable local bare Git.
cp "$TMP/index.json" "$TMP/cleanup-index-saved"
head_name="$(jq -r .headRefName "$TMP/cleanup-saved")"; sibling_name="${head_name}-sibling"
cleanup_cases=0
for scenario in open-incomplete merged-incomplete open-http merged-http complete metadata-omitted unrelated-response oid-recovered; do
  cleanup_cases=$((cleanup_cases + 1))
  g -C "$WORK" switch -q develop
  g -C "$WORK" branch -f "$head_name" "$OID" >/dev/null
  g -C "$WORK" switch -q "$head_name"
  g -C "$WORK" push -q origin "$OID:refs/heads/$head_name" "$OID:refs/heads/$sibling_name"
  cp "$TMP/cleanup-saved" "$TMP/cleanup.json"
  jq --arg sibling "$sibling_name" '. + [ (.[0] | .headRefName=$sibling) ]' "$TMP/merged-saved" >"$TMP/merged.json"
  jq '.responses |= map(.last=true | .http_status=200)' "$TMP/cleanup-index-saved" >"$TMP/index.json"
  case "$scenario" in
    open-incomplete) jq '(.responses[] | select(.operation=="cleanup.open-list") | .last)=false' "$TMP/index.json" >"$TMP/next" ;;
    merged-incomplete) jq '(.responses[] | select(.operation=="cleanup.merged-list") | .last)=false' "$TMP/index.json" >"$TMP/next" ;;
    open-http) jq '(.responses[] | select(.operation=="cleanup.open-list") | .http_status)=503' "$TMP/index.json" >"$TMP/next" ;;
    merged-http) jq '(.responses[] | select(.operation=="cleanup.merged-list") | .http_status)=403' "$TMP/index.json" >"$TMP/next" ;;
    metadata-omitted) jq '.responses |= map(del(.last,.http_status))' "$TMP/index.json" >"$TMP/next" ;;
    unrelated-response) jq '.responses += [(.responses[] | select(.operation=="cleanup.open-list") | .scope.repository="https://other.example/owner/repo" | .last=false | .http_status=503)]' "$TMP/index.json" >"$TMP/next" ;;
    oid-recovered) jq 'del(.headRefOid)' "$TMP/cleanup-saved" >"$TMP/cleanup.json"; cp "$TMP/index.json" "$TMP/next" ;;
    complete) cp "$TMP/index.json" "$TMP/next" ;;
  esac
  mv "$TMP/next" "$TMP/index.json"
  # Incomplete page omits an active head that exists in the fixture's full truth.
  if [ "$scenario" = open-incomplete ]; then
    jq -n --arg head "$head_name" '[{headRefName:$head}]' >"$TMP/full-open-truth.json"
  else printf '[]\n' >"$TMP/full-open-truth.json"; fi
  run file file "$PLUGIN/scripts/merge-cleanup.sh" 7 --github-input "$TMP/index.json"
  target_present=0; sibling_present=0
  if g --git-dir="$TMP/origin.git" show-ref --verify --quiet "refs/heads/$head_name"; then target_present=1; fi
  if g --git-dir="$TMP/origin.git" show-ref --verify --quiet "refs/heads/$sibling_name"; then sibling_present=1; fi
  printf 'target=%s sibling=%s rc=%s\n' "$target_present" "$sibling_present" "$RC" >"$TMP/refs-after"
  case "$scenario" in
    *incomplete|*-http)
      if [ "$RC" -eq 2 ] && [ "$target_present$sibling_present" = 11 ] && grep -F 'skipped_guard_unavailable' "$TMP/file.out" >/dev/null; then ok "cleanup real guard $scenario preserves target+sibling"; else bad "cleanup real guard $scenario deleted/refused incorrectly: target=$target_present sibling=$sibling_present rc=$RC"; fi ;;
    *)
      if [ "$RC" -eq 0 ] && [ "$target_present$sibling_present" = 00 ] && { [ "$scenario" != oid-recovered ] || { grep -F 'headRefOid' "$TMP/file.out" >/dev/null && grep -F 'deleted_by_leftover_retry' "$TMP/file.out" >/dev/null; }; }; then ok "cleanup real $scenario permits safe complete-list deletion/recovery"; else bad "cleanup real $scenario target=$target_present sibling=$sibling_present rc=$RC"; fi ;;
  esac
  save_case "cleanup-real-$scenario"
done
[ "$cleanup_cases" -eq 8 ] || bad 'cleanup real metadata matrix empty/drifted'

# Sub-issue writes remain PLAN only until complete fresh membership is supplied.
printf '[{"number":8}]\n' >"$TMP/membership.json"
printf '{"id":12345}\n' >"$TMP/child.json"
jq -n --arg repository "$URL" --arg dir "$TMP" '{version:1,responses:[
 {operation:"link.membership",scope:{repository:$repository,parent:7},phase:"before-link",page:1,last:false,body:($dir+"/membership.json")},
 {operation:"link.membership",scope:{repository:$repository,parent:7},phase:"before-link",page:2,last:true,body:($dir+"/empty.json")},
 {operation:"link.child-id",scope:{repository:$repository,child:8},phase:"before-link-child",body:($dir+"/child.json")}
]}' >"$TMP/link-index.json"
run file file "$PLUGIN/scripts/link-sub-issues.sh" --repo owner/repo --github-input "$TMP/link-index.json" 7 8
if [ "$RC" -eq 0 ] && grep -F 'skip' "$TMP/file.out" >/dev/null; then ok 'link existing complete membership skips'; else bad "link skip rc=$RC"; fi
save_case link-skip
printf '[]\n' >"$TMP/membership.json"
jq '.responses[0].last=true | .responses |= map(select(.page!=2))' "$TMP/link-index.json" >"$TMP/next"; mv "$TMP/next" "$TMP/link-index.json"
run file file "$PLUGIN/scripts/link-sub-issues.sh" --repo owner/repo --github-input "$TMP/link-index.json" 7 8
sed -n 's/^PLAN://p' "$TMP/file.out" >"$TMP/plan.json"
if [ "$RC" -eq 2 ] && jq -e '.operation=="link.write" and .arguments.sub_issue_id==12345 and .scope.parent==7 and .scope.child==8 and .readback.phase=="after-link-8"' "$TMP/plan.json" >/dev/null; then ok 'link exact PLAN rc2 without write/readback'; else bad "link PLAN rc=$RC"; cat "$TMP/file.err" >&2; fi
save_case link-plan
printf '[{"number":8}]\n' >"$TMP/after.json"
jq --arg dir "$TMP" '.responses += [(.responses[0] | .phase="after-link-8" | .last=false | .body=($dir+"/after.json")),(.responses[0] | .phase="after-link-8" | .page=2 | .last=true | .body=($dir+"/empty.json"))]' "$TMP/link-index.json" >"$TMP/next"; mv "$TMP/next" "$TMP/link-index.json"
run file file "$PLUGIN/scripts/link-sub-issues.sh" --repo owner/repo --github-input "$TMP/link-index.json" 7 8
if [ "$RC" -eq 0 ] && grep -F 'read-back verified' "$TMP/file.out" >/dev/null && ! grep -F 'PLAN:' "$TMP/file.out" >/dev/null; then ok 'link fresh complete readback without duplicate write'; else bad "link readback rc=$RC"; cat "$TMP/file.err" >&2; fi
save_case link-readback
printf '[{"number":99}]\n' >"$TMP/after.json"
run file file "$PLUGIN/scripts/link-sub-issues.sh" --repo owner/repo --github-input "$TMP/link-index.json" 7 8
if [ "$RC" -eq 2 ] && ! grep -F 'read-back verified' "$TMP/file.out" >/dev/null && ! grep -F 'done parent=' "$TMP/file.out" >/dev/null; then ok 'link mismatched readback remains pending'; else bad "link mismatched readback rc=$RC"; fi
save_case link-readback-mismatch

# finish.sh / link-sub-issues.sh / merge-cleanup.sh check --github-input themselves before reading
# (the other entry points rely on github_file_read's INDEX_ABS check). They share
# github_input_is_absolute: a relative path, and a drive-letter path on a non-MSYS host, stop with
# rc 2. run() also fails the case if any gh call leaks.
case "${OSTYPE:-}" in msys* | cygwin*) drive_inputs='relative-index.json' ;; *) drive_inputs='relative-index.json C:/ff-github-input-drive/index.json' ;; esac
for bad_input in $drive_inputs; do
  run file entry "$PLUGIN/scripts/finish.sh" precheck 7 --github-input "$bad_input"
  finish_rc="$RC"; finish_err="$(cat "$TMP/entry.err")"
  run file entry "$PLUGIN/scripts/link-sub-issues.sh" --repo owner/repo --github-input "$bad_input" 7 8
  link_rc="$RC"; link_err="$(cat "$TMP/entry.err")"
  run file entry "$PLUGIN/scripts/merge-cleanup.sh" --dry-run 7 --github-input "$bad_input"
  cleanup_rc="$RC"; cleanup_err="$(cat "$TMP/entry.err")"
  case "$finish_rc:$link_rc:$cleanup_rc|$finish_err|$link_err|$cleanup_err" in
    2:2:2\|*'--github-input must be absolute'*\|*'--github-input must be absolute'*\|*'--github-input must be absolute'*)
      ok "entry points reject non-absolute --github-input: $bad_input" ;;
    *) bad "entry points on $bad_input rc=$finish_rc/$link_rc/$cleanup_rc"; printf '%s\n' "$finish_err" "$link_err" "$cleanup_err" >&2 ;;
  esac
done
for file in scripts/finish.sh scripts/link-sub-issues.sh scripts/merge-cleanup.sh; do
  if grep -qF 'github_input_is_absolute "$github_input"' "$PLUGIN/$file" && ! grep -qE 'github_input" == /\*|github_input" in /\*' "$PLUGIN/$file"; then
    ok "$file uses the shared absolute-path rule"
  else bad "$file keeps its own absolute-path rule"; fi
done
# Issue `#2367`: the rule lives in scripts/lib/abs-path.sh (ff_path_is_absolute). github_input_is_absolute
# delegates to it, and the other path-taking entry points call it instead of a leading-/ check of their own.
# Each row: file | call that must be present | the old leading-/ check that must be gone.
ABS_SITES=0
while IFS='|' read -r file call old; do
  ABS_SITES=$((ABS_SITES + 1))
  if [ ! -s "$PLUGIN/$file" ]; then bad "absolute-path site missing: $file"; continue; fi
  if grep -qF "$call" "$PLUGIN/$file" && ! grep -qF "$old" "$PLUGIN/$file"; then
    ok "$file uses ff_path_is_absolute"
  else bad "$file keeps its own leading-/ absolute-path check (or lost the shared call)"; fi
done <<'SITES'
scripts/lib/github-input.sh|github_input_is_absolute() { ff_path_is_absolute "$1"; }|case "$1" in /*) return 0 ;; esac
scripts/ace-pending.sh|ff_path_is_absolute "$playbook"|case "$playbook" in /*)
scripts/knowledge-commit.sh|ff_path_is_absolute "$p"|case "$p" in /*)
scripts/workflow-doctor.sh|ff_path_is_absolute "$path"|case "$path" in /*)
hooks/guard-merge-closing-keyword.sh|ff_path_is_absolute "$body_file"|case "$body_file" in /*)
scripts/lib/adapter-common-git.sh|ff_path_is_absolute "$staging_dir"|case "$staging_dir" in
scripts/finish.sh|if ff_path_is_absolute "$p"; then claim_paths+=("$p")|case "$p" in /*) claim_paths
SITES
[ "$ABS_SITES" -eq 7 ] || bad "absolute-path site table read $ABS_SITES rows"
if [ -s "$PLUGIN/scripts/lib/abs-path.sh" ] && grep -qF 'ff_path_is_absolute() {' "$PLUGIN/scripts/lib/abs-path.sh"; then
  ok 'scripts/lib/abs-path.sh defines ff_path_is_absolute'
else bad 'scripts/lib/abs-path.sh or ff_path_is_absolute missing'; fi

# Extractor miss controls start from a proven complete ready output.
extract "$TMP/extractor-baseline" "$TMP/extracted" || { bad 'extractor baseline incomplete'; exit 1; }
# No scalar or duplicate scalar, missing/duplicate block.
for fault in scalar-missing scalar-duplicate block-missing block-duplicate; do
  case "$fault" in
    scalar-missing) sed '/^PRECHECK=/d' "$TMP/extractor-baseline" >"$TMP/extract-fault" ;;
    scalar-duplicate) cat "$TMP/extractor-baseline" >"$TMP/extract-fault"; printf 'PRECHECK=ready\n' >>"$TMP/extract-fault" ;;
    block-missing) sed '/^MERGE_COMMAND_BEGIN$/d' "$TMP/extractor-baseline" >"$TMP/extract-fault" ;;
    block-duplicate) cat "$TMP/extractor-baseline" "$TMP/extractor-baseline" >"$TMP/extract-fault" ;;
  esac
  if extract "$TMP/extract-fault" "$TMP/extracted"; then bad "extractor miss: $fault"; else ok "extractor rejects $fault"; fi
done
printf 'github-input-precheck: %s pass / %s fail; ready=%s cases=%s\n' "$PASS" "$FAIL" "$READY" "$COUNT"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ] || exit 1
printf 'complete\n' >"$TMP/completed"
