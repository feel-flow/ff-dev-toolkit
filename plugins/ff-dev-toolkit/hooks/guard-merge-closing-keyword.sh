#!/usr/bin/env bash
# Bash-only squash closing-keyword guard. The checker is the sole keyword detector.
# Unknown shell values/cwd/input, queue and delayed auto merge pass with a reason.
# gh's server preview is a snapshot, not an atomic guarantee of the future message.
# Perl is optional: without it bounded gh calls cannot run, so inspection is reported skipped.
# Each gh call has 1 second; at most 4 calls leave time for bounded parsing in the 10-second child.
# Local optional-inspection bounds: command/message 8 KiB, response 64 KiB, 32 Refs, 4 sanitize passes.
# No eval, repo settings changes, issue writes, or MCP handling.
input=""
IFS= read -r -d '' input || true
# Size bounds count bytes without changing the message bytes.
export LC_ALL=C
[ "${FF_DEV_TOOLKIT_SKIP_MERGE_CLOSING_GUARD:-0}" = 1 ] && exit 0
case "$input" in *gh*|*'\u'*) ;; *) exit 0 ;; esac
case "$input" in *merge*|*'\u'*) ;; *) exit 0 ;; esac
# ASDD is decided before dependency diagnostics: a disabled optional hook stays silent.
if ! . "${BASH_SOURCE[0]%/*}/asdd-hook-gate.sh"; then
  printf '%s\n' '{"systemMessage":"merge closing guard: ASDD helperを読めないため未検査です。","hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"ASDD helperを読めないため検査を省略しました。"}}'
  exit 0
fi
asdd_hook_enabled hooks; asdd_rc=$?
case "$asdd_rc" in
  0) ;;
  3) exit 0 ;;
  *) printf '%s\n' '{"systemMessage":"merge closing guard: ASDD設定を検証できないため未検査です。","hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"ASDD設定を検証できないため検査を省略しました。"}}'; exit 0 ;;
esac
if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' '{"systemMessage":"ff-dev-toolkit merge closing guard: jq が無いため検査を省略しました。","hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"jq が無いため squash closing keyword を検査せず通しました。"}}'
  exit 0
fi
MC_NOTES=""
mc_note() { MC_NOTES="${MC_NOTES}${MC_NOTES:+
}$1"; }
mc_finish() {
  [ -n "$MC_NOTES" ] || exit 0
  printf '%s' "ff-dev-toolkit merge closing guard: $MC_NOTES" | jq -Rs '{systemMessage:.,hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:.}}'
  exit 0
}
tool="$(printf '%s' "$input" | jq -er '.tool_name | strings' 2>/dev/null)" || { mc_note '入力JSONを読めないため検査を省略しました。'; mc_finish; }
[ "$tool" = Bash ] || exit 0
cmd="$(printf '%s' "$input" | jq -er '.tool_input.command | strings' 2>/dev/null)" || { mc_note 'Bash commandを読めないため検査を省略しました。'; mc_finish; }
case "$cmd" in *gh*merge*) ;; *) exit 0 ;; esac
[ "${#cmd}" -le 8192 ] || { mc_note 'commandが8KiB上限を超えるため未検査です。finish.sh precheckで確認してください。'; mc_finish; }
case "$cmd" in *$'\001'*) mc_note '内部区切りを含むshell値のため検査を省略しました。'; mc_finish ;; esac
plugin_root="${BASH_SOURCE[0]%/*}/.."
for helper in "$plugin_root/tests/lib/review-shell-lex.sh" "$plugin_root/scripts/lib/merge-message.sh"; do
  if [ ! -r "$helper" ] || [ ! -s "$helper" ] || ! . "$helper"; then
    mc_note '判定helperを読めないため検査を省略しました。'; mc_finish
  fi
done
for fn in ff_lex_code ff_lex_tokens ff_lex_segments ff_merge_issue_sets ff_merge_quote ff_merge_emit ff_merge_surface; do
  [ "$(type -t "$fn")" = function ] || { mc_note '判定helperの関数が無いため検査を省略しました。'; mc_finish; }
done
# Literal-only decoder: quote concatenation (including '\''), backslash escapes,
# and expansion-free double quotes. Shell expansion and unquoted globs are unknown.
mc_literal() {
  printf '%s' "$1" | LC_ALL=C awk '
    { s = s (NR > 1 ? "\n" : "") $0 }
    END {
      q = ""; sq = sprintf("%c",39); out = ""
      for (i=1; i<=length(s); i++) {
        c=substr(s,i,1); nx=substr(s,i+1,1)
        if (q==sq) { if(c==sq) q=""; else out=out c; continue }
        if (q=="\"") {
          if(c=="\"") {q=""; continue}
          if(c=="$" || c=="`") exit 2
          if(c=="\\" && (nx=="$" || nx=="`" || nx=="\"" || nx=="\\" || nx=="\n")) {i++; if(nx!="\n") out=out nx; continue}
          out=out c; continue
        }
        if(c==sq || c=="\"") {q=c; continue}
        if(c=="\\") {if(nx=="") exit 2; i++; if(nx!="\n") out=out nx; continue}
        if(c=="$" || c=="`" || c=="*" || c=="?" || c=="[" || c=="~" || c=="(" || c==")" || c=="{" || c=="}") exit 2
        out=out c
      }
      if(q!="") exit 2
      printf "%s",out
    }'
}
MC_GH_CALLS=0
mc_gh() { # response stays in a variable; a failed/partial response is never inspected.
  MC_RESPONSE=""
  if [ "$MC_GH_CALLS" -ge 4 ]; then mc_note '照会上限（4回）以後のmergeは未検査です。'; return 2; fi
  MC_GH_CALLS=$((MC_GH_CALLS + 1))
  MC_RESPONSE="$(CDPATH='' cd -- "$cwd" 2>/dev/null && perl -e 'alarm 1; exec @ARGV; exit 127' gh "$@" 2>/dev/null)"
  local rc=$?
  if [ "$rc" -ne 0 ]; then mc_note "gh照会が失敗/1秒上限となったため検査を省略しました（rc=${rc}）。"; return 2; fi
  [ -n "$MC_RESPONSE" ] || { mc_note 'gh応答が空のため検査を省略しました。'; return 2; }
  [ "${#MC_RESPONSE}" -le 65536 ] || { mc_note 'gh応答が64KiB上限を超えるため未検査です。finish.sh precheckで確認してください。'; return 2; }
}
# CHECK_OUT identifies effective title/body fields; matching commit origins are displayed separately.
# The checker alone owns conflict semantics.
mc_check() { # <subject> <body>
  local surface="" line origin text commits_line oid headline bodyline
  surface="$(ff_merge_surface title "$1"; ff_merge_surface body "$2")"
  CHECK_OUT="$(printf '%s\n' "$surface" | FF_DEV_TOOLKIT_ROOT="$plugin_root" bash "$checker" --repo "$repo" "${refs_args[@]}" 2>/dev/null)"
  CHECK_RC=$?
  case "$CHECK_RC" in 0|1) ;; *) return 2 ;; esac
  printf '%s' "$CHECK_OUT" | jq -Rse --argjson status "$CHECK_RC" '
    split("\n") | map(select(length>0)) as $lines
    | ($lines | map(select(startswith("CONFLICT\t"))) | length) as $conflicts
    | ($lines | map(select(startswith("SUGGEST\t"))) | length) as $suggests
    | (($lines | map(select(test("^INSPECTED\t[1-9][0-9]*$"))) | length) == 1)
      and (if $status==0 then $conflicts==0 else $conflicts>0 and $suggests==$conflicts end)
  ' >/dev/null 2>&1 || return 2
}
mc_sanitize() { # reuse checker SUGGEST per line/target; recheck the complete candidate.
  local input_text="$1" result rc iteration=0
  case "$input_text" in *[!$' \t\r\n']*) ;; *) MC_SAFE="$input_text"; return 0 ;; esac
  while [ "$iteration" -lt 4 ]; do
    result="$(ff_merge_surface sanitize "$input_text" | FF_DEV_TOOLKIT_ROOT="$plugin_root" bash "$checker" --repo "$repo" "${refs_args[@]}" 2>/dev/null)"; rc=$?
    case "$rc" in
      0) MC_SAFE="$input_text"; return 0 ;;
      1)
        # Apply one target per conflicting line in each pass; preserve all other lines and trailing LF.
        input_text="$(
          { ff_merge_surface R "$result"; ff_merge_surface I "$input_text"; } | LC_ALL=C awk '
            function text(s,j) {for(j=0;j<3;j++) s=substr(s,index(s,"\t")+1);return s}
            substr($0,1,2)=="R\t" {
              record=substr($0,3)
              if(index(record,"CONFLICT\t")==1) old=text(record)
              if(index(record,"SUGGEST\t")==1 && !(old in replacement)) replacement[old]=text(record)
              next
            }
            substr($0,1,2)=="I\t" {line=substr($0,3); print (line in replacement) ? replacement[line] : line}
          '
          rc=$?; printf X; exit "$rc"
        )" || return 2
        input_text="${input_text%X}"; input_text="${input_text%$'\n'}"
        ;;
      *) return 2 ;;
    esac
    iteration=$((iteration + 1))
  done
  return 2
}
mc_inspect() {
  local token stream kind raw n=0 i=0 key t ack=0 selector="" repo_arg="" subject="" body="" body_file="" head_flag="" author=""
  local have_body=0 have_subject=0 squash=0 other_strategy=0 admin=0 auto=0 disable=0 delete_flag="" extra="" positional=0
  local prior="$1" segment="$2" tokens
  tokens="$(ff_lex_tokens "$segment")" || { mc_note '候補の字句解析に失敗したため検査を省略しました。'; return; }
  local context_prefix=1 context_env=0 context_builtin="" context_key
  local context_wrapper="" context_option_arg=0 context_external=0 context_options=0
  local first="${tokens%%$'\001'*}"
  first="$(mc_literal "${first%%=*}")" || { MC_ENV_UNKNOWN=2; mc_note '候補の実行語を確定できないため検査を省略しました。'; return; }
  case "${tokens%%$'\001'*}" in *=*) first="$first=" ;; esac
  case "$first" in gh|*/gh|*=*|env|command|exec|!|if|then|else|do|cd|pushd|popd|export|unset) ;; sudo|nohup|time|nice|timeout|bash|sh|\(*) mc_note 'wrapper/入れ子shellの実行環境が未解決のため検査を省略しました。'; return ;; *) return ;; esac
  local toks=()
  stream="$tokens"
  while [ -n "$stream" ]; do
    case "$stream" in *$'\001'*) raw="${stream%%$'\001'*}"; stream="${stream#*$'\001'}" ;; *) return ;; esac
    # One prefix walk owns executable position; arguments are decoded only after classification.
    if [ "$context_option_arg" -eq 1 ]; then
      context_option_arg=0
      continue
    fi
    if [ -n "$context_builtin" ]; then
      context_key="$(mc_literal "${raw%%=*}")" || { MC_ENV_UNKNOWN=2; return; }
      case "$context_key" in
        GH_REPO) [ "$MC_ENV_UNKNOWN" -ge 1 ] || MC_ENV_UNKNOWN=1 ;;
        GH_*|GITHUB_*|PATH|HOME) MC_ENV_UNKNOWN=2 ;;
      esac
      continue
    fi
    token="$(mc_literal "$raw"; rc=$?; printf X; exit "$rc")" || {
      if [ "$context_prefix" -eq 1 ]; then MC_ENV_UNKNOWN=2; fi
      mc_note '候補に未解決のshell値があるため検査を省略しました。'; return
    }
    token="${token%X}"
    if [ "$context_prefix" -eq 1 ]; then
      case "$context_wrapper" in
        command)
          case "$token" in
            --) context_wrapper=""; context_options=1; continue ;;
            -*)
              context_key="${token#-}"
              case "$context_key" in ''|*[!pVv]*) mc_note '未対応のcommand optionのため検査を省略しました。'; return ;; esac
              # -v/-V describe names; they never execute cd/export or gh.
              case "$context_key" in *v*|*V*) return ;; esac
              context_options=1; continue ;;
            *) context_wrapper="" ;;
          esac ;;
        env)
          case "$token" in
            -u|--unset) context_option_arg=1; context_options=1; continue ;;
            --unset=*|-i|--ignore-environment|-0|-v) context_options=1; continue ;;
            --) context_wrapper=""; context_options=1; continue ;;
            -*) mc_note '未対応のenv optionのため検査を省略しました。'; return ;;
            *) context_wrapper="" ;;
          esac ;;
        exec)
          case "$token" in
            -a) context_option_arg=1; context_options=1; continue ;;
            -c|-l|-cl|-lc) context_options=1; continue ;;
            --) context_wrapper=""; context_options=1; continue ;;
            -*) mc_note '未対応のexec optionのため検査を省略しました。'; return ;;
            *) context_wrapper="" ;;
          esac ;;
      esac
      case "$token" in
        *=*) context_key="${token%%=*}"
          [[ "$context_key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return
          case "$token" in FF_MERGE_CLOSING_ACK=1) ack=1 ;; esac
          case "$context_key" in GH_REPO) [ "$context_env" -ge 1 ] || context_env=1 ;; GH_*|GITHUB_*|PATH|HOME) context_env=2 ;; esac ;;
        env|exec) context_external=1; context_wrapper="$token" ;;
        command) context_wrapper=command ;;
        !|if|then|else|do) ;;
        cd|pushd|popd) [ "$context_external" -eq 1 ] || MC_CWD_UNKNOWN=1; return ;;
        export|unset) [ "$context_external" -eq 0 ] || return; context_builtin="$token" ;;
        gh)
          [ "$context_env" -eq 0 ] || { mc_note 'gh環境を変更する前置代入のため検査を省略しました。'; return; }
          [ "$context_options" -eq 0 ] || { mc_note 'wrapper optionの実行環境が未解決のため検査を省略しました。'; return; }
          context_prefix=0; i=${#toks[@]} ;;
        */gh) mc_note 'path指定ghは照会実体と一致を保証できないため検査を省略しました。'; return ;;
        *) return ;;
      esac
    fi
    toks[${#toks[@]}]="$token"
  done
  [ -z "$context_builtin" ] || return
  if [ "$context_prefix" -eq 1 ]; then
    if [ "$context_external" -eq 0 ] && [ "$context_env" -gt "$MC_ENV_UNKNOWN" ]; then MC_ENV_UNKNOWN="$context_env"; fi
    return
  fi
  n=${#toks[@]}
  i=$((i + 1))
  if [ "${toks[$i]:-}" != pr ] || [ "${toks[$((i+1))]:-}" != merge ]; then
    mc_note 'gh global flag/サブコマンドを確定できないため検査を省略しました。'; return
  fi
  [ "$ack" -eq 1 ] && { mc_note '同じmergeの前置FF_MERGE_CLOSING_ACK=1により検査を省略しました。'; return; }
  i=$((i + 2))
  while [ "$i" -lt "$n" ]; do
    t="${toks[$i]}"
    case "$t" in
      --squash|-s) squash=1 ;;
      --merge|-m|--rebase|-r) other_strategy=1 ;;
      --admin) admin=1; extra="$extra --admin" ;;
      --auto) auto=1; extra="$extra --auto" ;;
      --disable-auto) disable=1 ;;
      --delete-branch|-d) delete_flag=' --delete-branch' ;;
      --repo|-R|--subject|-t|--body|-b|--body-file|-F|--match-head-commit|--author-email)
        i=$((i+1)); [ "$i" -lt "$n" ] || { mc_note 'merge flagの値が無いため検査を省略しました。'; return; }
        case "$t" in --repo|-R) repo_arg="${toks[$i]}" ;; --subject|-t) subject="${toks[$i]}"; have_subject=1 ;; --body|-b) body="${toks[$i]}"; have_body=1 ;; --body-file|-F) body_file="${toks[$i]}" ;; --match-head-commit) head_flag="${toks[$i]}" ;; --author-email) author="${toks[$i]}" ;; esac ;;
      --repo=*|-R?*) repo_arg="${t#*=}"; case "$t" in -R*) repo_arg="${t#-R}" ;; esac ;;
      --subject=*|-t?*) subject="${t#*=}"; case "$t" in -t*) subject="${t#-t}" ;; esac; have_subject=1 ;;
      --body=*|-b?*) body="${t#*=}"; case "$t" in -b*) body="${t#-b}" ;; esac; have_body=1 ;;
      --body-file=*|-F?*) body_file="${t#*=}"; case "$t" in -F*) body_file="${t#-F}" ;; esac ;;
      --match-head-commit=*) head_flag="${t#*=}" ;;
      --author-email=*) author="${t#*=}" ;;
      --) positional=1 ;;
      -*) mc_note '未対応のmerge flagがあるため検査を省略しました。'; return ;;
      *) [ -z "$selector" ] || { mc_note 'PR指定が複数あるため検査を省略しました。'; return; }; selector="$t" ;;
    esac
    i=$((i+1))
  done
  [ "$disable" -eq 1 ] && return
  [ "$squash" -eq 1 ] && [ "$other_strategy" -eq 0 ] || return
  if [ "$MC_CWD_UNKNOWN" -eq 1 ] && [ -z "$repo_arg" ]; then mc_note '先行cwd変更が未解決のため検査を省略しました。'; return; fi
  if [ "$MC_ENV_UNKNOWN" -eq 2 ] || { [ "$MC_ENV_UNKNOWN" -eq 1 ] && [ -z "$repo_arg" ]; }; then mc_note '先行prefix/gh実行環境が未解決のため検査を省略しました。'; return; fi
  if [ -n "$body_file" ]; then
    if [ "$have_body" -eq 1 ] || [ "$body_file" = - ] || [ "$prior" -ne 0 ] || [ "$MC_CWD_UNKNOWN" -ne 0 ]; then mc_note 'body-file/stdin/先行commandの内容を確定できないため検査を省略しました。'; return; fi
    case "$body_file" in /*) ;; *) body_file="$cwd/$body_file" ;; esac
    [ -f "$body_file" ] && [ -r "$body_file" ] || { mc_note 'body-fileを読めないため検査を省略しました。'; return; }
    local file_size
    file_size="$(LC_ALL=C wc -c <"$body_file")" || { mc_note 'body-fileの大きさを確認できないため未検査です。'; return; }
    if ! [[ "$file_size" =~ ^[[:space:]]*[0-9]+[[:space:]]*$ ]] || [ "$file_size" -gt 8192 ]; then
      mc_note 'body-fileが8KiB上限を超える/大きさ不明のため未検査です。finish.sh precheckで確認してください。'; return
    fi
    body="$(cat "$body_file"; rc=$?; printf X; exit "$rc")" || { mc_note 'body-file読取失敗のため検査を省略しました。'; return; }
    body="${body%X}"; have_body=1
  fi
  for dep in gh perl; do command -v "$dep" >/dev/null 2>&1 || { mc_note "$dep が無いため検査を省略しました。"; return; }; done
  local args=(pr view)
  [ -z "$selector" ] || args[${#args[@]}]="$selector"
  [ -z "$repo_arg" ] || args+=(--repo "$repo_arg")
  args+=(--json id,url)
  mc_gh "${args[@]}" || return
  local id url host response
  id="$(printf '%s' "$MC_RESPONSE" | jq -er '.id | strings | select(length>0)' 2>/dev/null)" || { mc_note 'PR idを取得できないため検査を省略しました。'; return; }
  url="$(printf '%s' "$MC_RESPONSE" | jq -er '.url | strings | select(test("^https://[A-Za-z0-9.-]+/[^/]+/[^/]+/pull/[0-9]+$"))' 2>/dev/null)" || { mc_note 'PR URLを取得できないため検査を省略しました。'; return; }
  host="${url#https://}"; host="${host%%/*}"
  mc_gh api graphql --hostname "$host" -f query='query($id:ID!){node(id:$id){...on PullRequest{id number url title body headRefOid mergeStateStatus isMergeQueueEnabled repository{nameWithOwner url} closingIssuesReferences(first:100){totalCount nodes{url}} commits(first:100){totalCount nodes{commit{oid messageHeadline messageBody}}} viewerMergeHeadlineText(mergeType:SQUASH) viewerMergeBodyText(mergeType:SQUASH)}}}' -f "id=$id" || return
  response="$MC_RESPONSE"
  printf '%s' "$response" | jq -e --arg id "$id" --arg url "$url" '
    (.errors // [] | length)==0 and (.data.node | .id==$id and .url==$url and (.number|type)=="number" and (.title|type)=="string" and (.body|type)=="string" and (.headRefOid|test("^[0-9a-fA-F]{40}$")) and (.isMergeQueueEnabled|type)=="boolean" and (.mergeStateStatus|type)=="string" and (.repository.nameWithOwner|test("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$")) and (.repository.url|type)=="string" and (.closingIssuesReferences.nodes|length)==.closingIssuesReferences.totalCount and (.commits.nodes|length)==.commits.totalCount)
  ' >/dev/null 2>&1 || { mc_note 'PR応答が不完全なため検査を省略しました。'; return; }
  local queue state number repo repo_url head pr_body api_closes keywords checker
  queue="$(printf '%s' "$response" | jq -r '.data.node.isMergeQueueEnabled')"
  if [ "$queue" = true ] && [ "$admin" -ne 1 ]; then mc_note 'merge queueではmessage指定が無視されるため検査を省略しました。'; return; fi
  state="$(printf '%s' "$response" | jq -r '.data.node.mergeStateStatus')"
  if [ "$auto" -eq 1 ]; then case "$state" in CLEAN|HAS_HOOKS|UNSTABLE) ;; *) mc_note '将来実行のauto merge messageは確定できないため検査を省略しました。'; return ;; esac; fi
  number="$(printf '%s' "$response" | jq -r '.data.node.number')"
  repo="$(printf '%s' "$response" | jq -r '.data.node.repository.nameWithOwner')"
  repo_url="$(printf '%s' "$response" | jq -r '.data.node.repository.url')"
  head="$(printf '%s' "$response" | jq -r '.data.node.headRefOid')"
  if [ -n "$head_flag" ] && [ "$head_flag" != "$head" ]; then mc_note '指定headとPR headが違うため検査を省略しました。'; return; fi
  pr_body="$(printf '%s' "$response" | jq -r '.data.node.body')"
  api_closes="$(printf '%s' "$response" | jq -er '.data.node.closingIssuesReferences.nodes | map(.url | capture("^https://[^/]+/(?<repo>[^/]+/[^/]+)/issues/(?<n>[0-9]+)$") | .repo+"#"+.n) | join("\n")')" || { mc_note 'Closes参照を読めないため検査を省略しました。'; return; }
  checker="$plugin_root/scripts/check-closing-keywords.sh"
  [ -r "$checker" ] && [ -s "$checker" ] || { mc_note 'checkerを読めないため検査を省略しました。'; return; }
  keywords="$(FF_DEV_TOOLKIT_ROOT="$plugin_root" bash "$checker" --list-keywords 2>/dev/null)" || { mc_note 'keyword一覧を読めないため検査を省略しました。'; return; }
  ff_merge_issue_sets "$repo" "$pr_body" "$api_closes" "$keywords" || { mc_note 'Refs/Closes集合を作れないため検査を省略しました。'; return; }
  [ -n "$REFS_ONLY" ] || return
  local refs_args=() stream_ref="$REFS_ONLY" ref
  while [ -n "$stream_ref" ]; do
    ref="${stream_ref%%$'\n'*}"; case "$stream_ref" in *$'\n'*) stream_ref="${stream_ref#*$'\n'}" ;; *) stream_ref="" ;; esac
    refs_args+=(--refs-issue "$ref")
    [ "${#refs_args[@]}" -le 64 ] || { mc_note 'Refsが32件上限を超えるため未検査です。finish.sh precheckで確認してください。'; return; }
  done
  if [ "$have_subject" -ne 1 ] || [ -z "$subject" ]; then
    subject="$(printf '%s' "$response" | jq -er '.data.node.viewerMergeHeadlineText | strings | select(length>0)')" || { mc_note 'server既定件名を読めないため検査を省略しました。'; return; }
  fi
  if [ "$have_body" -ne 1 ]; then
    body="$(printf '%s' "$response" | jq -er '.data.node.viewerMergeBodyText | strings'; rc=$?; printf X; exit "$rc")" || { mc_note 'server既定本文を読めないため検査を省略しました。'; return; }
    body="${body%X}"; body="${body%$'\n'}"
  fi
  [ $((${#subject}+${#body})) -le 8192 ] || { mc_note '実効messageが8KiB上限を超えるため未検査です。finish.sh precheckで確認してください。'; return; }
  mc_check "$subject" "$body" || { mc_note 'keyword判定が成立しないため検査を省略しました。'; return; }
  [ "$CHECK_RC" -eq 1 ] || return
  local conflict="$CHECK_OUT" safe_subject safe_body recovery origin_sha
  # Match checker-confirmed conflict text to source lines; never call all commits conflicting.
  # Source display is optional: failure must not discard the already known deny.
  origin_sha="$(printf '%s' "$response" | jq -r --arg conflict "$conflict" '
    [$conflict | split("\n")[] | select(startswith("CONFLICT\t")) | split("\t") | .[3:] | join("\t")] as $lines
    | .data.node.commits.nodes[].commit
    | select(any((.messageHeadline + "\n" + .messageBody) | split("\n")[]; . as $line | any($lines[]; . == $line or . == ("* " + $line))))
    | "commit:\(.oid) \(.messageHeadline)"
  ' 2>/dev/null)" || origin_sha=""
  MC_DENY="${MC_DENY}${MC_DENY:+
}PR $url の実効squash messageがRefs対象を閉じます。
$conflict
抵触した実効フィールド（title / body）は上記CONFLICT行。
一致するcommit供給源（取得できた場合のみ）:
$origin_sha
復旧候補の生成に失敗する場合は finish.sh precheck で件名・本文を確認してください。"
  mc_sanitize "$subject" || { mc_note '安全件名を生成できないため手動precheckで確認してください。'; return; }; safe_subject="$MC_SAFE"
  mc_sanitize "$body" || { mc_note '安全本文を生成できないため手動precheckで確認してください。'; return; }; safe_body="$MC_SAFE"
  [ -n "$safe_subject" ] || { mc_note '安全な非空件名を作れないため手動precheckで確認してください。'; return; }
  mc_check "$safe_subject" "$safe_body" || { mc_note '復旧候補の再検査が成立しないため検査を省略しました。'; return; }
  [ "$CHECK_RC" -eq 0 ] || { mc_note '復旧候補に抵触が残るため手動precheckで確認してください。'; return; }
  [ -z "$author" ] || extra="$extra --author-email $(ff_merge_quote "$author")"
  recovery="$(ff_merge_emit "$number" "$repo_url" "$head" 1 "$safe_subject" "$safe_body" "$delete_flag$extra")" || { mc_note '復旧コマンドを引用できないため手動precheckで確認してください。'; return; }
  MC_DENY="$MC_DENY
$recovery"
}
cwd="$(printf '%s' "$input" | jq -er '.cwd | strings | select(length>0)' 2>/dev/null)" || { mc_note 'cwdを取得できないため検査を省略しました。'; mc_finish; }
[ -d "$cwd" ] && [ -r "$cwd" ] || { mc_note 'cwdを読めないため検査を省略しました。'; mc_finish; }
code="$(ff_lex_code "$cmd")" || { mc_note 'shell構文を解析できないため検査を省略しました。'; mc_finish; }
segments="$(ff_lex_segments "$code")" || { mc_note 'shell区間を解析できないため検査を省略しました。'; mc_finish; }
MC_DENY=""; MC_CWD_UNKNOWN=0; MC_ENV_UNKNOWN=0; prior=0
while [ -n "$segments" ]; do
  raw="${segments%%$'\001'*}"; case "$segments" in *$'\001'*) segments="${segments#*$'\001'}" ;; *) break ;; esac
  segment="${raw#?}"
  case "$segment" in *gh*merge*|*cd*|*pushd*|*popd*|*export*|*unset*|*GH_*=*|*GITHUB_*=*|*PATH=*|*HOME=*) mc_inspect "$prior" "$segment" ;; esac
  prior=$((prior+1))
done
if [ -n "$MC_DENY" ]; then
  reason="$MC_DENY
この呼び出し全体は未実行です。復旧commandのsubject/bodyを確認して再実行してください。
迂回: 同じmergeの前置 FF_MERGE_CLOSING_ACK=1、全体無効化 FF_DEV_TOOLKIT_SKIP_MERGE_CLOSING_GUARD=1。
${MC_NOTES}"
  printf '%s' "$reason" | jq -Rs '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:.}}'
  exit 0
fi
mc_finish
