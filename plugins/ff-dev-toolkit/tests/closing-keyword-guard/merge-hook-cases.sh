# shellcheck shell=bash
# Source-only regression layer for the Bash merge guard; every gh response is local.
closing_merge_hook_cases() {
  local tmp hook before count=0
  local issue_no=42 other_issue_no=43 pr_no=7
  local ref="#${issue_no}" other_ref="#${other_issue_no}" pr_ref="#${pr_no}"
  before=$((PASS+FAIL))
  hook="$PLUGIN_ROOT/hooks/guard-merge-closing-keyword.sh"
  for source in "$hook" "$PLUGIN_ROOT/scripts/lib/merge-message.sh" "$PLUGIN_ROOT/tests/lib/review-shell-lex.sh"; do
    if [ ! -r "$source" ] || [ ! -s "$source" ]; then bad 'merge hook: sourceが無い/読めない/空'; return; fi
  done
  tmp="$(mktemp -d)" || { bad 'merge hook: fixtureを作れない'; return; }
  mkdir -p "$tmp/bin" "$tmp/work" "$tmp/other"
  cat >"$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
[ -z "${MC_TEST_CALLS:-}" ] || printf '%s\n' "$*" >>"$MC_TEST_CALLS"
case "${MC_TEST_MODE:-}" in
  capture) printf '%s\000' "$@" >"$MC_TEST_CAPTURE"; exit 0 ;;
  fail) exit 1 ;;
  slow) exec perl -e 'sleep 8' ;;
  delay2) perl -e 'sleep 2' ;;
  partial) printf '%s' '{"data":'; exit 1 ;;
esac
if [ "${MC_TEST_MODE:-}" = context ]; then
  selected="${GH_REPO:-owner/repo}"
  [ "$PWD" != "$MC_TEST_OTHER_CWD" ] || selected=owner/other
  previous=""
  for arg in "$@"; do
    if [ "$previous" = --repo ]; then selected="$arg"; fi
    previous="$arg"
    case "$arg" in id=PR_other) selected=owner/other ;; esac
  done
  if [ "$selected" = owner/other ]; then
    if [ "$1" = pr ]; then printf '%s\n' '{"id":"PR_other","url":"https://github.com/owner/other/pull/7"}'; else cat "$MC_TEST_OTHER_RESPONSE"; fi
  else
    if [ "$1" = pr ]; then printf '%s\n' '{"id":"PR_fixture","url":"https://github.com/owner/repo/pull/7"}'; else cat "$MC_TEST_RESPONSE"; fi
  fi
  exit 0
fi
if [ "$1" = pr ] && [ "$2" = view ]; then
  printf '%s\n' '{"id":"PR_fixture","url":"https://github.com/owner/repo/pull/7"}'
else
  cat "$MC_TEST_RESPONSE"
fi
STUB
  chmod +x "$tmp/bin/gh"
  local MC_TEST_JQ="$(command -v jq)" MC_TEST_CAT="$(command -v cat)"
  local response="$tmp/response.json" input_file="$tmp/input.json" out="" err="" rc=0 mode=""
  jq -n --arg ref "$ref" --arg pr_ref "$pr_ref" '{data:{node:{id:"PR_fixture",number:7,url:"https://github.com/owner/repo/pull/7",title:"安全な変更",body:"Refs \($ref)",headRefOid:("a"*40),mergeStateStatus:"CLEAN",isMergeQueueEnabled:false,repository:{nameWithOwner:"owner/repo",url:"https://github.com/owner/repo"},closingIssuesReferences:{totalCount:0,nodes:[]},commits:{totalCount:1,nodes:[{commit:{oid:("b"*40),messageHeadline:"fix: \($ref) 変更",messageBody:""}}]},viewerMergeHeadlineText:"安全な変更 (\($pr_ref))",viewerMergeBodyText:"* fix: \($ref) 変更\n"}}}' >"$tmp/base.json"
  cp "$tmp/base.json" "$response"
  mc_test_run() {
    local command="$1"
    "$MC_TEST_JQ" -n --arg c "$command" --arg d "${2:-$tmp/work}" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' >"$input_file"
    rc=0
    : >"$tmp/gh-calls"
    out="$(/usr/bin/env -u FF_DEV_TOOLKIT_ROOT -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT -u FF_DEV_TOOLKIT_SKILL_FILE -u FF_DEV_TOOLKIT_SKIP_MERGE_CLOSING_GUARD -u FF_MERGE_CLOSING_ACK -u GH_REPO PATH="$tmp/bin:$PATH" MC_TEST_MODE="$mode" MC_TEST_RESPONSE="$response" MC_TEST_CALLS="$tmp/gh-calls" MC_TEST_OTHER_RESPONSE="$tmp/other.json" MC_TEST_OTHER_CWD="$tmp/other" /bin/bash "$hook" <"$input_file" 2>"$tmp/stderr")" || rc=$?
    err="$("$MC_TEST_CAT" "$tmp/stderr")"
  }
  mc_test_assert() { # <deny|allow|note|silent> <label>
    count=$((count+1))
    local good=0
    if [ "$rc" -eq 0 ]; then
      case "$1" in
        deny) printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision=="deny" and (.hookSpecificOutput.permissionDecisionReason | contains("FF_MERGE_CLOSING_ACK=1"))' >/dev/null 2>&1 && good=1 ;;
        allow) if [ -z "$out" ]; then good=1; elif printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision!="deny"' >/dev/null 2>&1; then good=1; fi ;;
        note) printf '%s' "$out" | jq -e '(.systemMessage|type)=="string" and (.hookSpecificOutput.additionalContext|type)=="string" and .hookSpecificOutput.permissionDecision!="deny"' >/dev/null 2>&1 && good=1 ;;
        silent) [ -z "$out" ] && good=1 ;;
      esac
    fi
    if [ "$good" -eq 1 ]; then ok "merge hook: $2"; else bad "merge hook: $2 (rc=$rc out=[$out] err=[$err])"; fi
  }
  mc_test_run 'gh pr merge 7 --squash'; mc_test_assert deny '既定本文のcommit closingを拒否'
  if case "$out" in *'commit:bbbbbbbb'*'MERGE_COMMAND_BEGIN'*'--match-head-commit aaaaaaaa'*) true ;; *) false ;; esac; then ok 'merge hook: 供給源と同repo/headの復旧コマンド'; else bad 'merge hook: 供給源/復旧コマンド欠落'; fi
  local recovery
  recovery="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason' | awk '/^MERGE_COMMAND_BEGIN$/ {on=1;next} /^MERGE_COMMAND_END$/ {on=0} on')"
  mc_test_run "$recovery"; mc_test_assert silent '生成した復旧commandを同じhookで再検査'
  local got_subject="" got_body="" arg="" next=""
  if [ -n "$recovery" ] && MC_TEST_MODE=capture MC_TEST_CAPTURE="$tmp/captured" PATH="$tmp/bin:$PATH" /bin/bash -c "$recovery" && [ -r "$tmp/captured" ]; then
    while IFS= read -r -d '' arg; do
      case "$next" in subject) got_subject="$arg"; next="" ;; body) got_body="$arg"; next="" ;; *) case "$arg" in --subject) next=subject ;; --body) next=body ;; esac ;; esac
    done <"$tmp/captured"
    if [ "$got_subject" = "安全な変更 (${pr_ref})" ] && [ "$got_body" = $'* fix: 変更\n' ]; then ok 'merge hook: 復旧subject/bodyの実argv bytes'; else bad 'merge hook: 復旧subject/bodyが検査済み値と違う'; fi
  else bad 'merge hook: 復旧commandのstub実行失敗'; fi
  mc_test_run "gh pr merge 7 --squash --subject \"安全\" --body \"Refs ${ref}\""; mc_test_assert silent 'safe明示両値が供給源より優先'
  jq --arg ref "$ref" --arg other_ref "$other_ref" '.data.node.body="Closes \($ref)"' "$tmp/base.json" >"$response"
  mc_test_run 'gh pr merge 7 --squash'; mc_test_assert silent 'Closesは閉じる意図どおり'
  jq --arg ref "$ref" --arg other_ref "$other_ref" '.data.node.body="Closes \($other_ref)\nRefs \($ref)"' "$tmp/base.json" >"$response"
  mc_test_run 'gh pr merge 7 --squash'; mc_test_assert deny 'Closes混在でRefs側を省略しない'
  jq --arg ref "$ref" --arg other_ref "$other_ref" '.data.node.body="Refs \($ref)\nCloses \($ref)"' "$tmp/base.json" >"$response"
  mc_test_run 'gh pr merge 7 --squash'; mc_test_assert silent '同じIssueのClosesを差集合から除外'
  cp "$tmp/base.json" "$response"
  mode=fail; mc_test_run 'gh pr merge 7 --squash'; mc_test_assert note 'gh失敗を理由付きallow'; mode=""
  mode=partial; mc_test_run 'gh pr merge 7 --squash'; mc_test_assert note '非0の部分JSONを採用しない'; mode=""
  mc_test_run 'gh pr merge 7 --squash --subject "安全"'; mc_test_assert deny 'subjectのみ指定では既定本文を検査'
  jq --arg ref "$ref" --arg other_ref "$other_ref" '.data.node.viewerMergeHeadlineText="fix: \($ref) 危険" | .data.node.viewerMergeBodyText=""' "$tmp/base.json" >"$response"
  mc_test_run "gh pr merge 7 --squash --body \"Refs ${ref}\""; mc_test_assert deny 'bodyのみ指定では既定件名を検査'
  mc_test_run "gh pr merge 7 --squash --subject '' --body 'Refs ${ref}'"; mc_test_assert deny '空subjectは既定件名へ戻る'
  mc_test_run "gh pr merge 7 --squash --subject '安全' --body ''"; mc_test_assert silent '明示空bodyは有効'
  cp "$tmp/base.json" "$response"
  mc_test_run "gh pr merge 7 -s -t '日本語 Bob'\\''s 安全' -b 'Refs ${ref}
'"; mc_test_assert silent '単引用の連結とUnicode/末尾LF'
  mc_test_run 'echo "gh pr merge 7 --squash $VAR"'; mc_test_assert silent '説明文字列はコマンドではない'
  mc_test_run $'cat <<\'DOC\'\ngh pr merge 7 --squash\nDOC'; mc_test_assert silent 'heredoc本文はデータ'
  mc_test_run '# gh pr merge 7 --squash'; mc_test_assert silent 'コメントはデータ'
  mc_test_run 'gh pr merge "$PR" --squash'; mc_test_assert note '未解決変数は推測しない'
  mc_test_run "gh pr merge 7 --squash --subject safe --body fi'x: ${ref} literal'"; mc_test_assert deny '引用を連結したliteral値も検査'
  mc_test_run 'command gh pr merge 7 --squash'; mc_test_assert deny 'command wrapperの実行位置'
  mc_test_run 'env -u GH_TOKEN gh pr merge 7 --squash'; mc_test_assert note 'env optionの未解決環境を通知'
  mc_test_run 'command -p gh pr merge 7 --squash'; mc_test_assert note 'command optionの未解決環境を通知'
  mc_test_run '/another/bin/gh pr merge 7 --squash'; mc_test_assert note '別path ghの照会実体を推測しない'
  mc_test_run 'command -p echo "gh pr merge 7 --squash"'; mc_test_assert silent 'wrapper越しの説明文字列もデータ'
  mc_test_run 'env FF_MERGE_CLOSING_ACK=1 gh pr merge 7 --squash'; mc_test_assert note '同じ実行位置のACK'
  mc_test_run 'echo FF_MERGE_CLOSING_ACK=1; gh pr merge 7 --squash'; mc_test_assert deny '前段echoのACKは無効'
  mc_test_run 'FF_EFFORT_ACTUAL_ACK=1 gh pr merge 7 --squash'; mc_test_assert deny '工数ACKでclosingを免除しない'
  mc_test_run "gh pr merge 7 --squash --subject safe --body \"Refs ${ref}\"; gh pr merge 7 --squash"; mc_test_assert deny '2個目のmergeも検査'
  mc_test_run "gh pr merge 7 --squash --subject safe --body \"Refs ${ref}\"; gh pr merge 7 --squash --subject safe --body \"Refs ${ref}\"; gh pr merge 7 --squash"; mc_test_assert note '上限以後を未検査と通知'
  jq '.data.node.isMergeQueueEnabled=true' "$tmp/base.json" >"$response"
  mc_test_run "gh pr merge 7 --squash --subject safe --body \"Refs ${ref}\""; mc_test_assert note 'queueのmessage無視を通知'
  mc_test_run 'gh pr merge 7 --squash --admin'; mc_test_assert deny 'admin queue bypassは通常message'
  jq '.data.node.mergeStateStatus="BLOCKED"' "$tmp/base.json" >"$response"
  mc_test_run 'gh pr merge 7 --squash --auto'; mc_test_assert note '将来autoの既定を保証しない'
  mc_test_run 'gh pr merge 7 --squash --disable-auto'; mc_test_assert silent 'disable-autoはmergeしない'
  cp "$tmp/base.json" "$response"
  mc_test_run 'gh pr merge 7 --merge'; mc_test_assert silent 'merge戦略はsquash対象外'
  printf 'Refs %s\n' "$ref" >"$tmp/work/body.txt"
  mc_test_run 'gh pr merge 7 --squash --subject safe --body-file body.txt'; mc_test_assert silent '既存regular body-fileをsnapshot読取'
  # Drive-letter body-file (Issue `#2367`): MSYS/Cygwin reads C:/… as absolute, other OSes join it to the
  # hook cwd. The C: directory exists only under the process cwd, so the two rules give deny vs note.
  case "${OSTYPE:-}" in
    msys* | cygwin*) ok 'merge hook: (real MSYS/Cygwin host: C:/… is a real drive, drive body-file cases not run)'; ok 'merge hook: (same — count only)' ;;
    *)
      mkdir -p "$tmp/drive/C:"
      printf 'fix: %s literal\n' "$ref" >"$tmp/drive/C:/body.txt"
      mc_prev_pwd="$PWD"
      cd "$tmp/drive" || return 1
      OSTYPE=msys mc_test_run 'gh pr merge 7 --squash --subject safe --body-file C:/body.txt'; mc_test_assert deny 'MSYSではC:/のbody-fileを絶対パスとして読む'
      OSTYPE=linux-gnu mc_test_run 'gh pr merge 7 --squash --subject safe --body-file C:/body.txt'; mc_test_assert note '他のOSではC:/のbody-fileをcwdへ連結する'
      cd "$mc_prev_pwd" || return 1
      ;;
  esac
  mc_test_run 'touch body.txt; gh pr merge 7 --squash --subject safe --body-file body.txt'; mc_test_assert note '先行生成のbody-fileは不明'
  mc_test_run 'gh pr merge 7 --squash --body-file -'; mc_test_assert note 'stdin bodyは未確定'
  mc_test_run 'cd /tmp && gh pr merge 7 --squash'; mc_test_assert note '先行cwd変更を推測しない'
  # Both repository polarities prevent a safe original PR from hiding an unsafe target,
  # or an unsafe original PR from creating a recovery command for the wrong target.
  local polarity transition context_count=0 transition_count=0 wrapper_count=0 wrapper_case
  mode=context
  for polarity in original-safe original-conflict; do
    context_count=$((context_count+1))
    if [ "$polarity" = original-safe ]; then
      jq '.data.node.body="safe"' "$tmp/base.json" >"$response"
      cp "$tmp/base.json" "$tmp/other.json"
    else
      cp "$tmp/base.json" "$response"
      jq '.data.node.body="safe"' "$tmp/base.json" >"$tmp/other.json"
    fi
    jq '.data.node.id="PR_other" | .data.node.url="https://github.com/owner/other/pull/7" | .data.node.repository={nameWithOwner:"owner/other",url:"https://github.com/owner/other"}' "$tmp/other.json" >"$tmp/other-next.json"
    mv "$tmp/other-next.json" "$tmp/other.json"
    for transition in 'cd "$TARGET"' 'pushd "$TARGET"' 'popd "$COUNT"' 'command cd "$TARGET"' 'export GH_REPO=owner/other' 'export GH_REPO="$TARGET"' 'unset GH_REPO' 'GH_REPO=owner/other' 'GH_REPO="$TARGET"' 'HARMLESS="$VALUE" cd "$TARGET"' 'HARMLESS="$VALUE" export GH_REPO=owner/other' '"$PREFIX" cd "$TARGET"'; do
      transition_count=$((transition_count+1))
      mc_test_run "$transition; gh pr merge 7 --squash"
      mc_test_assert note "$polarity: $transition 後は理由付き未検査"
      if [ ! -s "$tmp/gh-calls" ] && case "$out" in *MERGE_COMMAND_BEGIN*) false ;; *) true ;; esac; then ok "merge hook: $polarity: $transition は元repoを照会/復旧しない"; else bad "merge hook: $polarity: $transition が元repoを照会/復旧した"; fi
    done
    mc_test_run 'gh pr merge 7 --squash --repo owner/other'
    if [ "$polarity" = original-safe ]; then mc_test_assert deny 'context stub: 実対象だけの抵触を識別'; else mc_test_assert silent 'context stub: 元repoだけの抵触は実対象へ混ぜない'; fi
    mc_test_run 'gh pr merge 7 --squash' "$tmp/other"
    if [ "$polarity" = original-safe ]; then mc_test_assert deny 'context stub: 別cwdの実対象だけの抵触を識別'; else mc_test_assert silent 'context stub: 別cwdへ元repo抵触を混ぜない'; fi
    mc_test_run 'export GH_REPO=owner/other; gh pr merge 7 --squash --repo owner/repo'
    if [ "$polarity" = original-safe ]; then mc_test_assert silent '明示repoは先行GH_REPOより優先して安全'; else mc_test_assert deny '明示repoは先行GH_REPOより優先して抵触'; fi
    mc_test_run 'cd "$TARGET"; gh pr merge 7 --squash --repo owner/repo'
    if [ "$polarity" = original-safe ]; then mc_test_assert silent '未解決cwd後も明示repoを検査して安全'; else mc_test_assert deny '未解決cwd後も明示repoを検査して抵触'; fi
    mc_test_run 'HARMLESS="$VALUE" cd "$TARGET"; gh pr merge 7 --squash --repo owner/repo'; mc_test_assert note '未解決prefix後は明示repoでも元環境を推測しない'
    if [ ! -s "$tmp/gh-calls" ]; then ok 'merge hook: 未解決prefix後の明示repoも照会しない'; else bad 'merge hook: 未解決prefix後の明示repoを元環境で照会した'; fi
    mc_test_run 'HARMLESS=value gh pr merge 7 --squash --repo owner/repo'
    if [ "$polarity" = original-safe ]; then mc_test_assert silent '確定した無関係prefixと明示repoは安全'; else mc_test_assert deny '確定した無関係prefixと明示repoも抵触を検査'; fi
    mc_test_run 'HARMLESS=value cd "$TARGET"; gh pr merge 7 --squash --repo owner/repo'
    if [ "$polarity" = original-safe ]; then mc_test_assert silent '確定prefixのcwd変更後も明示repoは安全'; else mc_test_assert deny '確定prefixのcwd変更後も明示repoの抵触を検査'; fi
    mc_test_run 'echo "$VALUE"; gh pr merge 7 --squash --repo owner/repo'
    if [ "$polarity" = original-safe ]; then mc_test_assert silent 'echoの未解決値は後続の明示repoへ混ぜない'; else mc_test_assert deny 'echoの未解決値でも後続明示repoを検査'; fi
    mc_test_run 'export HARMLESS="$VALUE"; gh pr merge 7 --squash --repo owner/repo'
    if [ "$polarity" = original-safe ]; then mc_test_assert silent '無関係exportの未解決値でも明示repoは安全'; else mc_test_assert deny '無関係exportの未解決値でも明示repoを検査'; fi
    # R2 wrapper composition: classify the executable before restoring its arguments.
    for wrapper_case in 'command -p cd "$TARGET"' 'command -- cd "$TARGET"' 'command -p -- cd "$TARGET"' "command -p cd '$tmp/other'" "command -- cd '$tmp/other'" 'command -p pushd "$TARGET"' 'command -- popd "$COUNT"' 'command -p export GH_REPO=owner/other'; do
      wrapper_count=$((wrapper_count+1))
      mc_test_run "$wrapper_case; gh pr merge 7 --squash"; mc_test_assert note "$polarity: wrapper $wrapper_case 後は理由付き未検査"
      if [ ! -s "$tmp/gh-calls" ] && case "$out" in *MERGE_COMMAND_BEGIN*) false ;; *) true ;; esac; then ok "merge hook: $polarity: wrapperは元repoを照会/復旧しない"; else bad "merge hook: $polarity: wrapperが元repoを照会/復旧した"; fi
    done
    for wrapper_case in 'command -p echo "cd $TARGET; gh pr merge 7 --squash"' 'command -- echo "gh pr merge 7 --squash $VALUE"' 'command -v cd "$TARGET"' 'command -V cd "$TARGET"' 'command -pv cd "$TARGET"' 'env -u cd echo "gh pr merge 7 --squash"' 'env -u gh echo "gh pr merge 7 --squash"' 'env -u "$NAME" echo "gh pr merge 7 --squash"' 'env -u GH_REPO cd "$TARGET"' 'env cd "$TARGET"' 'env GH_REPO=owner/other' 'command -v export GH_REPO=owner/other'; do
      wrapper_count=$((wrapper_count+1))
      mc_test_run "$wrapper_case; gh pr merge 7 --squash"
      if [ "$polarity" = original-safe ]; then mc_test_assert silent "$polarity: 非実行/外部wrapperの親文脈は安全"; else mc_test_assert deny "$polarity: 非実行/外部wrapper後の抵触を検査"; fi
    done
    for wrapper_case in 'command -p cd "$TARGET"' 'command -- cd "$TARGET"'; do
      wrapper_count=$((wrapper_count+1))
      mc_test_run "$wrapper_case; gh pr merge 7 --squash --repo owner/other"
      if [ "$polarity" = original-safe ]; then mc_test_assert deny 'wrapper cwd変更後の明示repoだけの抵触を検査'; else mc_test_assert silent 'wrapper cwd変更後も明示repoへ元repo抵触を混ぜない'; fi
      if case "$(cat "$tmp/gh-calls")" in 'pr view 7 --repo owner/other --json id,url'*) true ;; *) false ;; esac; then ok 'merge hook: wrapper後もselectorと明示repoを維持'; else bad 'merge hook: wrapper後のselector/repoが違う'; fi
    done
    for wrapper_case in gh 'command gh'; do
      wrapper_count=$((wrapper_count+1))
      mc_test_run "$wrapper_case pr merge 7 --squash --repo owner/repo"
      if [ "$polarity" = original-safe ]; then mc_test_assert silent '既知selector/通常gh wrapperは安全'; else mc_test_assert deny '既知selector/通常gh wrapperの抵触を検査'; fi
      if case "$(cat "$tmp/gh-calls")" in 'pr view 7 --repo owner/repo --json id,url'*) true ;; *) false ;; esac; then ok 'merge hook: 通常gh/command ghのselectorを維持'; else bad 'merge hook: 通常gh/command ghのselector欠落'; fi
    done
    # R2 wrapper composition end.
  done
  if [ "$context_count" -eq 2 ] && [ "$transition_count" -eq 24 ]; then ok 'merge hook: contextの2極性/24遷移を実走'; else bad 'merge hook: contextの極性/遷移集合が空/欠落'; fi
  if [ "$wrapper_count" -eq 48 ]; then ok 'merge hook: wrapperの2極性48ケースを実走'; else bad 'merge hook: wrapperのcase集合が空/欠落'; fi
  mode=""; cp "$tmp/base.json" "$response"
  for wrapper_case in 'command -v gh pr merge 7 --squash' 'command -V gh pr merge 7 --squash'; do
    mc_test_run "$wrapper_case"; mc_test_assert silent 'command lookupだけならmergeを実行しない'
    if [ ! -s "$tmp/gh-calls" ]; then ok 'merge hook: command lookupはgh照会しない'; else bad 'merge hook: command lookupをmergeと混同'; fi
  done
  mc_test_run 'echo "export GH_REPO=owner/other; cd \"$TARGET\""; gh pr merge 7 --squash'; mc_test_assert deny 'echo内の環境/cwd説明は状態を変えない'
  mc_test_run 'export HARMLESS=value; gh pr merge 7 --squash'; mc_test_assert deny '無関係なexportは検査を妨げない'
  mc_test_run 'export GH_HOST=other.example; gh pr merge 7 --squash --repo owner/repo'; mc_test_assert note 'GH_HOST未確定はowner/repo指定でも未検査'
  jq '.data.node.commits.totalCount=2 | .data.node.commits.nodes += [{commit:{oid:("c"*40),messageHeadline:"safe neighbor",messageBody:""}}]' "$tmp/base.json" >"$response"
  mc_test_run 'gh pr merge 7 --squash'; mc_test_assert deny '複数commit中の抵触を拒否'
  if case "$out" in *commit:cccccccc*) false ;; *commit:bbbbbbbb*) true ;; *) false ;; esac; then ok 'merge hook: 抵触行に一致するcommitだけを供給源表示'; else bad 'merge hook: 非抵触の隣接commitを混同/抵触元欠落'; fi
  jq '.data.node.commits.nodes[0].commit.messageBody={}' "$tmp/base.json" >"$response"
  mc_test_run 'gh pr merge 7 --squash'; mc_test_assert deny '任意の供給源表示が失敗しても既知denyを保つ'
  if case "$out" in *commit:bbbbbbbb*) false ;; *) true ;; esac; then ok 'merge hook: 表示失敗時に供給源を断定しない'; else bad 'merge hook: 表示失敗時の供給源が残った'; fi
  cp "$tmp/base.json" "$response"
  jq 'del(.data.node.isMergeQueueEnabled)' "$tmp/base.json" >"$response"
  mc_test_run 'gh pr merge 7 --squash'; mc_test_assert note 'JSON必須field欠損を通知'
  cp "$tmp/base.json" "$response"
  jq --arg ref "$ref" --arg other_ref "$other_ref" '.data.node.viewerMergeBodyText="fix: \($ref) 一行\nfix: \($ref) 二行\nfix: \($ref) 三行\nfix: \($ref) 四行\n"' "$tmp/base.json" >"$response"
  mc_test_run 'gh pr merge 7 --squash'; mc_test_assert deny '複数行の同一Refs抵触を拒否'
  recovery="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason' | awk '/^MERGE_COMMAND_BEGIN$/ {on=1;next} /^MERGE_COMMAND_END$/ {on=0} on')"
  if [ -n "$recovery" ]; then mc_test_run "$recovery"; mc_test_assert silent '全抵触行をsanitizeした復旧command'; else bad 'merge hook: 複数行の復旧command欠落'; fi
  cp "$tmp/base.json" "$response"
  mc_test_run "$(printf "gh pr merge 7 --squash --subject safe --body 'prefix\tfix: %s 本文'" "$ref")"; mc_test_assert deny '本文内TABを供給源区切りに誤読しない'
  local large_value
  large_value="$(printf '%8500s' x)"
  mc_test_run "gh pr merge 7 --squash --body '$large_value'"; mc_test_assert note '大きなcommandを処理枠前に通知'
  if [ ! -s "$tmp/gh-calls" ]; then ok 'merge hook: 大きなcommandは照会前に戻る'; else bad 'merge hook: command上限が照会に先行しない'; fi
  jq --arg big "$large_value" '.data.node.viewerMergeBodyText=$big' "$tmp/base.json" >"$response"
  mc_test_run 'gh pr merge 7 --squash'; mc_test_assert note '大きなserver messageを通知'
  cp "$tmp/base.json" "$response"
  printf '%s' "$large_value" >"$tmp/work/large-body.txt"
  mc_test_run 'gh pr merge 7 --squash --body-file large-body.txt'; mc_test_assert note '大きなbody-fileを読込前に通知'
  if [ ! -s "$tmp/gh-calls" ]; then ok 'merge hook: 大きなbody-fileは照会前に戻る'; else bad 'merge hook: body-file上限が照会に先行しない'; fi
  jq '.data.node.body=([range(1;35)|"Refs #"+tostring]|join("\n"))' "$tmp/base.json" >"$response"
  mc_test_run 'gh pr merge 7 --squash'; mc_test_assert note 'Refs集合の固定上限を通知'
  jq '.data.node.body=([range(1;7)|"Refs #"+tostring]|join("\n")) | .data.node.viewerMergeBodyText=([range(1;7)|"fix: #"+tostring]|join(" "))' "$tmp/base.json" >"$response"
  mc_test_run 'gh pr merge 7 --squash'; mc_test_assert deny '復旧反復上限でも既知抵触は停止'
  if case "$out" in *MERGE_COMMAND_BEGIN*) false ;; *手動precheck*) true ;; *) false ;; esac; then ok 'merge hook: 反復超過は未検査復旧を出さない'; else bad 'merge hook: 反復上限/手動案内が成立しない'; fi
  jq -n --argjson base "$(cat "$tmp/base.json")" '$base+{padding:("x"*66000)}' >"$response"
  mc_test_run 'gh pr merge 7 --squash'; mc_test_assert note '大きな照会応答を通知'
  cp "$tmp/base.json" "$response"
  local save_path="$PATH"
  mkdir -p "$tmp/no-perl"
  for dep in jq awk sed bash cat; do ln -s "$(command -v "$dep")" "$tmp/no-perl/$dep"; done
  ln -s "$tmp/bin/gh" "$tmp/no-perl/gh"
  PATH="$tmp/no-perl"; mc_test_run 'gh pr merge 7 --squash'; PATH="$save_path"; mc_test_assert note 'Perl不在を理由付きallow'
  local started=$SECONDS
  mode=slow; OSTYPE=linux-gnu mc_test_run 'gh pr merge 7 --squash'; mc_test_assert note 'gh時間上限で10秒前に通知'; mode=""
  if [ $((SECONDS-started)) -lt 4 ]; then ok 'merge hook: slow照会も4秒未満で戻る'; else bad 'merge hook: slow照会上限が成立しない'; fi
  # Windows Git Bash: gh alone takes about 0.9 s, so MSYS / Cygwin get 3 s per call and 8 s from the first
  # call (Issue `#2377`). A 2-second gh is inspected there but cut off elsewhere; an 8-second gh is cut at
  # 3 s, well inside the 25-second MSYS child.
  jq --arg ref "$ref" '.data.node.body="Closes \($ref)"' "$tmp/base.json" >"$response"
  mode=delay2; OSTYPE=msys mc_test_run 'gh pr merge 7 --squash'; mc_test_assert silent 'MSYSでは2秒かかるgh照会も検査する'
  mode=delay2; OSTYPE=cygwin mc_test_run 'gh pr merge 7 --squash'; mc_test_assert silent 'Cygwinでも2秒かかるgh照会を検査する'
  mode=delay2; OSTYPE=linux-gnu mc_test_run 'gh pr merge 7 --squash'; mc_test_assert note '他のOSでは2秒かかるgh照会を1秒で打ち切る'; mode=""
  cp "$tmp/base.json" "$response"
  started=$SECONDS
  mode=slow; OSTYPE=msys mc_test_run 'gh pr merge 7 --squash'; mc_test_assert note 'MSYSでもgh時間上限で通知'; mode=""
  if [ $((SECONDS-started)) -lt 8 ]; then ok 'merge hook: MSYSのslow照会も8秒未満で戻る'; else bad 'merge hook: MSYSのslow照会上限が成立しない'; fi
  # All calls share the window from the first call: four slow merges would take 12 s at 3 s each.
  # The note text is checked because the first cut-off call already yields a (different) note.
  started=$SECONDS
  mode=slow; OSTYPE=msys mc_test_run 'gh pr merge 7 --squash; gh pr merge 7 --squash; gh pr merge 7 --squash; gh pr merge 7 --squash'
  mc_test_assert note 'MSYSでは時間枠を使い切ったら以後を未検査と通知'; mode=""
  case "$out" in *時間枠*) ok 'merge hook: MSYSの通知が時間枠の使い切りを名指しする' ;; *) bad "merge hook: MSYSの時間枠の通知が無い (out=[$out])" ;; esac
  if [ $((SECONDS-started)) -lt 12 ]; then ok 'merge hook: MSYSで遅い照会が続いても照会の時間枠（8秒）と解析の余裕の内に戻る'; else bad 'merge hook: MSYSの全体の時間枠が成立しない'; fi
  if [ "$count" -gt 0 ] && [ $((PASS+FAIL)) -gt "$before" ]; then ok 'merge hook: case集合は空でない'; else bad 'merge hook: case集合が空'; fi
  rm -rf "$tmp"
}
