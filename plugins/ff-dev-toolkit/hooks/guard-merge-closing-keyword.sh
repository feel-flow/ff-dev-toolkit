#!/usr/bin/env bash
# Bash-only squash closing-keyword guard. The checker is the sole keyword detector.
# An executed gh pr merge whose subject cannot be resolved stops. Echo, heredoc,
# comments, and the same words inside one argument stay allowed. Queue, delayed auto merge, fetch failure, and missing
# tools still pass with a reason.
# gh's server preview is a snapshot, not an atomic guarantee of the future message.
# Perl is optional: without it bounded gh calls cannot run, so inspection is reported skipped.
# Each gh call has 1 second (the shared 5-second window never cuts the four 1-second calls); at most 4 calls leave time for bounded
# parsing in the 10-second child. On MSYS / Cygwin (Windows Git Bash) gh alone takes about 0.9 s and the
# whole hook about 8.5 s, so a call gets 3 seconds, all calls share 8 seconds, and run-bash-hooks.sh
# gives the child 25 seconds (Issue `#2377`). Worst case there: gh waits at most 8 s in total (elapsed time
# is rounded up, and calls cut at their alarm count their alarm even if the wall clock steps back; a step
# back during a call that completes is not corrected), plus about 6.5 s of parsing measured with full
# inspection, about 14.5 s < 25 s. The shared window counts from the first gh call.
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
# 0 when this segment executes gh pr merge. A quote is a word boundary, so the
# same words inside one argument are not a merge. Lex failure is 1 (the outer
# lexer already fail-opens on unreadable shell).
mc_merge_scan_script() {
  local script_segments script_raw script_seg
  script_segments="$(ff_lex_segments "$1")" || return 0
  while [ -n "$script_segments" ]; do
    script_raw="${script_segments%%$'\001'*}"
    case "$script_segments" in
      *$'\001'*) script_segments="${script_segments#*$'\001'}" ;;
      *) break ;;
    esac
    script_seg="${script_raw#?}"
    [ -n "$script_seg" ] || continue
    if mc_merge_scan "$script_seg"; then
      return 0
    fi
  done
  return 1
}
mc_merge_scan() {
  local scan_rc
  MC_MERGE_DEPTH=$((${MC_MERGE_DEPTH:-0}+1))
  if [ "$MC_MERGE_DEPTH" -gt 4 ]; then
    MC_MERGE_DEPTH=$((MC_MERGE_DEPTH-1))
    return 0
  fi
  mc_merge_scan_body "$1"
  scan_rc=$?
  MC_MERGE_DEPTH=$((MC_MERGE_DEPTH-1))
  return "$scan_rc"
}
mc_merge_scan_body() {
  local scan_tokens scan_stream scan_raw scan_word scan_mode scan_redo scan_key
  local scan_consume=0 scan_resume="" scan_arm="" scan_after=""
  scan_tokens="$(ff_lex_tokens "$1")" || return 1
  scan_stream="$scan_tokens"
  scan_mode="cmd"
  while [ -n "$scan_stream" ]; do
    case "$scan_stream" in
      *$'\001'*) scan_raw="${scan_stream%%$'\001'*}"; scan_stream="${scan_stream#*$'\001'}" ;;
      *) return 1 ;;
    esac
    if [ "$scan_consume" -eq 1 ]; then
      scan_consume=0
      [ -n "$scan_resume" ] && scan_mode="$scan_resume"
      scan_resume=""
      continue
    fi
    # Grouping tokens are syntax. A quoted brace is a different raw token.
    case "$scan_raw" in
      "{"|"("|"}"|")") continue ;;
    esac
    if ! mc_literal_var "$scan_raw"; then
      if [ "$scan_arm" = shellc ]; then return 0; fi
      scan_arm=""
      scan_mode="uncertain"
      [ "$scan_after" = pr ] || scan_after="unresolved"
      continue
    fi
    mc_chomp_var
    scan_word="$MC_LITERAL"
    if [ -n "$scan_arm" ]; then
      scan_mode="$scan_arm"
      scan_arm=""
    fi
    scan_redo=1
    while [ "$scan_redo" -eq 1 ]; do
      scan_redo=0
      case "$scan_mode" in
        cmd)
          case "$scan_word" in
            *=*) ;;
            builtin|"{"|"("|"}"|")"|!|if|then|else|do) ;;
            command) scan_mode="command" ;;
            env) scan_mode="env" ;;
            exec) scan_mode="exec" ;;
            sudo) scan_mode="sudo" ;;
            nohup) scan_mode="nohup" ;;
            time) scan_mode="timew" ;;
            nice) scan_mode="nice" ;;
            timeout) scan_mode="timeout" ;;
            bash|sh) scan_mode="shell" ;;
            cd|pushd|popd|export|unset|echo|printf|:) return 1 ;;
            gh|*/gh) scan_mode="gh" ;;
            *) return 1 ;;
          esac ;;
        command)
          case "$scan_word" in
            --) scan_mode="cmd" ;;
            -*)
              scan_key="${scan_word#-}"
              case "$scan_key" in
                *v*|*V*) return 1 ;;
                *[!pPvV]*) scan_mode="uncertain"; scan_after="unresolved"; scan_redo=1 ;;
                *) ;;
              esac ;;
            *) scan_mode="cmd"; scan_redo=1 ;;
          esac ;;
        env)
          case "$scan_word" in
            -u|--unset) scan_consume=1; scan_resume="env" ;;
            --unset=*|-i|--ignore-environment|-0|-v) ;;
            --) scan_mode="cmd" ;;
            *=*) ;;
            -*) scan_mode="uncertain"; scan_after="unresolved"; scan_redo=1 ;;
            *) scan_mode="cmd"; scan_redo=1 ;;
          esac ;;
        exec)
          case "$scan_word" in
            -a) scan_consume=1; scan_resume="exec" ;;
            -c|-l|-cl|-lc) ;;
            --) scan_mode="cmd" ;;
            -*) scan_mode="uncertain"; scan_after="unresolved"; scan_redo=1 ;;
            *) scan_mode="cmd"; scan_redo=1 ;;
          esac ;;
        sudo)
          case "$scan_word" in
            --) scan_mode="cmd" ;;
            -u|-g|-p|-C|-D|-R|-T|--user|--group|--prompt|--close-from|--chdir|--role|--other-user|--command-timeout|--chroot) scan_consume=1; scan_resume="sudo" ;;
            --*=*) ;;
            -*) ;;
            *) scan_mode="cmd"; scan_redo=1 ;;
          esac ;;
        nohup|timew)
          case "$scan_word" in
            --) scan_mode="cmd" ;;
            -*) ;;
            *) scan_mode="cmd"; scan_redo=1 ;;
          esac ;;
        nice)
          case "$scan_word" in
            -n|--adjustment) scan_consume=1; scan_resume="nice" ;;
            --adjustment=*) ;;
            --) scan_mode="cmd" ;;
            -*) ;;
            *) scan_mode="cmd"; scan_redo=1 ;;
          esac ;;
        timeout)
          case "$scan_word" in
            --) scan_arm="timeoutdur" ;;
            -k|--kill-after|-s|--signal) scan_consume=1; scan_resume="timeout" ;;
            --kill-after=*|--signal=*) ;;
            -*) ;;
            *) scan_mode="cmd" ;;
          esac ;;
        timeoutdur) scan_mode="cmd" ;;
        shell)
          case "$scan_word" in
            -c) scan_arm="shellc" ;;
            --) scan_mode="cmd" ;;
            -o|--rcfile|-O|--init-file) scan_consume=1; scan_resume="shell" ;;
            --*) ;;
            -*[c]*) scan_arm="shellc" ;;
            -*) ;;
            *) return 1 ;;
          esac ;;
        shellc)
          mc_merge_scan_script "$scan_word"
          return $? ;;
        gh)
          case "$scan_word" in
            pr) scan_mode="ghpr" ;;
            --) scan_arm="gh" ;;
            --repo|-R|--hostname) scan_consume=1; scan_resume="gh" ;;
            --repo=*|-R?*|--hostname=*) ;;
            -*) scan_mode="ghseek" ;;
            *) return 1 ;;
          esac ;;
        ghpr)
          [ "$scan_word" = merge ] && return 0
          return 1 ;;
        ghseek)
          case "$scan_word" in
            pr) scan_mode="ghpr" ;;
            *) ;;
          esac ;;
        uncertain)
          case "$scan_word" in
            gh|*/gh) scan_after="gh" ;;
            pr)
              if [ "$scan_after" = gh ] || [ "$scan_after" = unresolved ]; then scan_after="pr"; else scan_after=""; fi ;;
            merge)
              [ "$scan_after" = pr ] && return 0
              scan_after="" ;;
            *) scan_after="" ;;
          esac ;;
        *) return 1 ;;
      esac
    done
  done
  return 1
}
mc_is_pr_merge_text() {
  if [ -z "${MC_MERGE_CACHED:-}" ]; then
    if mc_merge_scan "$1"; then MC_MERGE_CACHED=merge; else MC_MERGE_CACHED=other; fi
  fi
  [ "$MC_MERGE_CACHED" = merge ]
}
MC_STOP_REASON=""
# ack is local to mc_inspect. Bash dynamic scope lets the same-segment ACK stay allow.
mc_stop() {
  if [ "${ack:-0}" -eq 1 ]; then
    mc_note '同じmergeの前置FF_MERGE_CLOSING_ACK=1により検査を省略しました。'
    return 0
  fi
  [ -n "$MC_STOP_REASON" ] || MC_STOP_REASON="$1"
}
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
for helper in "$plugin_root/tests/lib/review-shell-lex.sh" "$plugin_root/scripts/lib/merge-message.sh" "$plugin_root/scripts/lib/abs-path.sh"; do
  if [ ! -r "$helper" ] || [ ! -s "$helper" ] || ! . "$helper"; then
    mc_note '判定helperを読めないため検査を省略しました。'; mc_finish
  fi
done
for fn in ff_lex_code ff_lex_tokens ff_lex_segments ff_merge_issue_sets ff_merge_quote ff_merge_emit ff_merge_surface ff_path_is_absolute; do
  [ "$(type -t "$fn")" = function ] || { mc_note '判定helperの関数が無いため検査を省略しました。'; mc_finish; }
done
# Variable-returning wrapper (MC_LITERAL). A word made only of [A-Za-z0-9_./:=@%+,-] has no quoting,
# escape, expansion or glob, so its literal is the word itself: no awk and no command-substitution
# subshell. Each of those costs about 0.1 s on Windows Git Bash, and plain words are most of a merge
# command (Issue `#2377`). Every other word goes through mc_literal unchanged.
mc_literal_var() {
  case "$1" in
    '' | *[!A-Za-z0-9_./:=@%+,-]*)
      MC_LITERAL="$(mc_literal "$1"; rc=$?; printf X; exit "$rc")" || return
      MC_LITERAL="${MC_LITERAL%X}" ;;
    *) MC_LITERAL="$1" ;;
  esac
}
# Drop trailing newlines from MC_LITERAL in place, as a bare $(...) would.
mc_chomp_var() {
  while [ "${MC_LITERAL%$'\n'}" != "$MC_LITERAL" ]; do MC_LITERAL="${MC_LITERAL%$'\n'}"; done
}
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
case "${OSTYPE:-}" in
  msys* | cygwin*) MC_GH_ALARM=3; MC_GH_BUDGET=8 ;;
  *) MC_GH_ALARM=1; MC_GH_BUDGET=5 ;;
esac
MC_GH_STARTED=""
# Seconds that calls cut at their alarm have certainly taken. SECONDS follows the wall clock, which can
# step back (observed under load in WSL), so the window takes the larger of the two.
MC_GH_CUT=0
mc_gh() { # response stays in a variable; a failed/partial response is never inspected.
  MC_RESPONSE=""
  if [ "$MC_GH_CALLS" -ge 4 ]; then mc_note '照会上限（4回）以後のmergeは未検査です。'; return 2; fi
  [ -n "$MC_GH_STARTED" ] || MC_GH_STARTED=$SECONDS
  local elapsed=$((SECONDS - MC_GH_STARTED))
  [ "$elapsed" -ge "$MC_GH_CUT" ] || elapsed=$MC_GH_CUT
  local left=$((MC_GH_BUDGET - elapsed - 1)) alarm="$MC_GH_ALARM"
  if [ "$left" -lt 1 ]; then mc_note "gh照会の時間枠（最初の照会から${MC_GH_BUDGET}秒）を使い切ったため、以後のmergeは未検査です。"; return 2; fi
  [ "$left" -ge "$alarm" ] || alarm="$left"
  MC_GH_CALLS=$((MC_GH_CALLS + 1))
  MC_RESPONSE="$(CDPATH='' cd -- "$cwd" 2>/dev/null && perl -e 'alarm shift @ARGV; exec @ARGV; exit 127' "$alarm" gh "$@" 2>/dev/null)"
  local rc=$?
  [ "$rc" -ne 142 ] || MC_GH_CUT=$((MC_GH_CUT + alarm))
  if [ "$rc" -ne 0 ]; then mc_note "gh照会が失敗/${alarm}秒上限となったため検査を省略しました（rc=${rc}）。"; return 2; fi
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
  local have_body=0 have_subject=0 squash=0 other_strategy=0 admin=0 auto=0 disable=0 delete_flag="" extra="" positional=0 unknown=0
  local prior="$1" segment="$2" tokens
  MC_MERGE_CACHED=""
  MC_MERGE_DEPTH=0
  tokens="$(ff_lex_tokens "$segment")" || {
    case "$segment" in
      *" pr merge"|*" pr merge "*) mc_stop '候補の字句解析に失敗したため件名を検査できません。'; return ;;
    esac
    mc_note '候補の字句解析に失敗したため検査を省略しました。'; return
  }
  local context_prefix=1 context_env=0 context_builtin="" context_key
  local context_wrapper="" context_option_arg=0 context_external=0 context_options=0
  local first="${tokens%%$'\001'*}"
  case "$first" in
    "{"|"("|"}"|")") ;;
    *)
      mc_literal_var "${first%%=*}" || {
        MC_ENV_UNKNOWN=2
        if mc_is_pr_merge_text "$segment"; then mc_stop '候補の実行語を確定できないため件名を検査できません。'; return; fi
        mc_note '候補の実行語を確定できないため検査を省略しました。'; return
      }
      mc_chomp_var; first="$MC_LITERAL"
      case "${tokens%%$'\001'*}" in *=*) first="$first=" ;; esac ;;
  esac
  case "$first" in
    gh|*/gh|*=*|env|command|exec|!|if|then|else|do|cd|pushd|popd|export|unset|builtin|"{"|"(") ;;
    sudo|nohup|time|nice|timeout|bash|sh)
      if mc_is_pr_merge_text "$segment"; then mc_stop 'wrapper/入れ子shellの中の gh pr merge は件名を検査できません。'; return; fi
      return ;;
    *) return ;;
  esac
  local toks=()
  stream="$tokens"
  while [ -n "$stream" ]; do
    case "$stream" in *$'\001'*) raw="${stream%%$'\001'*}"; stream="${stream#*$'\001'}" ;; *) return ;; esac
    # Grouping tokens are syntax. A quoted brace is a different raw token and stays an argument.
    case "$raw" in
      "{"|"("|"}"|")") continue ;;
    esac
    # One prefix walk owns executable position; arguments are decoded only after classification.
    if [ "$context_option_arg" -eq 1 ]; then
      context_option_arg=0
      continue
    fi
    if [ -n "$context_builtin" ]; then
      mc_literal_var "${raw%%=*}" || { MC_ENV_UNKNOWN=2; return; }
      mc_chomp_var; context_key="$MC_LITERAL"
      case "$context_key" in
        GH_REPO) [ "$MC_ENV_UNKNOWN" -ge 1 ] || MC_ENV_UNKNOWN=1 ;;
        GH_*|GITHUB_*|PATH|HOME) MC_ENV_UNKNOWN=2 ;;
      esac
      continue
    fi
    mc_literal_var "$raw" || {
      if [ "$context_prefix" -eq 1 ]; then MC_ENV_UNKNOWN=2; fi
      if mc_is_pr_merge_text "$segment"; then mc_stop '候補に未解決のshell値があるため件名を検査できません。'; return; fi
      mc_note '候補に未解決のshell値があるため検査を省略しました。'; return
    }
    token="$MC_LITERAL"
    if [ "$context_prefix" -eq 1 ]; then
      case "$context_wrapper" in
        command)
          case "$token" in
            --) context_wrapper=""; context_options=1; continue ;;
            -*)
              context_key="${token#-}"
              case "$context_key" in ''|*[!pVv]*)
                if mc_is_pr_merge_text "$segment"; then mc_stop '未対応のcommand optionのため件名を検査できません。'; return; fi
                mc_note '未対応のcommand optionのため検査を省略しました。'; return ;;
              esac
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
            -*)
              if mc_is_pr_merge_text "$segment"; then mc_stop '未対応のenv optionのため件名を検査できません。'; return; fi
              mc_note '未対応のenv optionのため検査を省略しました。'; return ;;
            *) context_wrapper="" ;;
          esac ;;
        exec)
          case "$token" in
            -a) context_option_arg=1; context_options=1; continue ;;
            -c|-l|-cl|-lc) context_options=1; continue ;;
            --) context_wrapper=""; context_options=1; continue ;;
            -*)
              if mc_is_pr_merge_text "$segment"; then mc_stop '未対応のexec optionのため件名を検査できません。'; return; fi
              mc_note '未対応のexec optionのため検査を省略しました。'; return ;;
            *) context_wrapper="" ;;
          esac ;;
      esac
      case "$token" in
        *=*) context_key="${token%%=*}"
          [[ "$context_key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
            if mc_is_pr_merge_text "$segment"; then mc_stop '前置代入の名前を確定できないため件名を検査できません。'; return; fi
            return
          }
          case "$token" in FF_MERGE_CLOSING_ACK=1) ack=1 ;; esac
          case "$context_key" in GH_REPO) [ "$context_env" -ge 1 ] || context_env=1 ;; GH_*|GITHUB_*|PATH|HOME) context_env=2 ;; esac ;;
        env|exec) context_external=1; context_wrapper="$token" ;;
        command) context_wrapper=command ;;
        !|if|then|else|do) ;;
        builtin|"{"|"("|"}"|")") continue ;;
        cd|pushd|popd) [ "$context_external" -eq 1 ] || MC_CWD_UNKNOWN=1; return ;;
        export|unset) [ "$context_external" -eq 0 ] || return; context_builtin="$token" ;;
        gh)
          if [ "$context_env" -ne 0 ]; then
            if mc_is_pr_merge_text "$segment"; then mc_stop 'gh環境を変更する前置代入のため件名を検査できません。'; return; fi
            mc_note 'gh環境を変更する前置代入のため検査を省略しました。'; return
          fi
          if [ "$context_options" -ne 0 ]; then
            if mc_is_pr_merge_text "$segment"; then mc_stop 'wrapper optionの実行環境が未解決のため件名を検査できません。'; return; fi
            mc_note 'wrapper optionの実行環境が未解決のため検査を省略しました。'; return
          fi
          context_prefix=0; i=${#toks[@]} ;;
        */gh)
          if mc_is_pr_merge_text "$segment"; then mc_stop 'path指定ghは照会実体と一致を保証できないため件名を検査できません。'; return; fi
          mc_note 'path指定ghは照会実体と一致を保証できないため検査を省略しました。'; return ;;
        sudo|nohup|time|nice|timeout|bash|sh)
          if mc_is_pr_merge_text "$segment"; then mc_stop 'wrapper/入れ子shellの中の gh pr merge は件名を検査できません。'; return; fi
          return ;;
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
    case "${toks[$i]:-}" in
      ""|-*)
        if mc_is_pr_merge_text "$segment"; then mc_stop 'gh global flag/サブコマンドを確定できないため件名を検査できません。'; return; fi
        mc_note 'gh global flag/サブコマンドを確定できないため検査を省略しました。'; return ;;
      *) return ;;
    esac
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
        i=$((i+1)); [ "$i" -lt "$n" ] || { mc_stop 'merge flagの値が無いため件名を検査できません。'; return; }
        case "$t" in --repo|-R) repo_arg="${toks[$i]}" ;; --subject|-t) subject="${toks[$i]}"; have_subject=1 ;; --body|-b) body="${toks[$i]}"; have_body=1 ;; --body-file|-F) body_file="${toks[$i]}" ;; --match-head-commit) head_flag="${toks[$i]}" ;; --author-email) author="${toks[$i]}" ;; esac ;;
      --repo=*|-R?*) repo_arg="${t#*=}"; case "$t" in -R*) repo_arg="${t#-R}" ;; esac ;;
      --subject=*|-t?*) subject="${t#*=}"; case "$t" in -t*) subject="${t#-t}" ;; esac; have_subject=1 ;;
      --body=*|-b?*) body="${t#*=}"; case "$t" in -b*) body="${t#-b}" ;; esac; have_body=1 ;;
      --body-file=*|-F?*) body_file="${t#*=}"; case "$t" in -F*) body_file="${t#-F}" ;; esac ;;
      --match-head-commit=*) head_flag="${t#*=}" ;;
      --author-email=*) author="${t#*=}" ;;
      --) positional=1 ;;
      -*) unknown=1 ;;
      *) [ -z "$selector" ] || { mc_stop 'PR指定が複数あるため件名を検査できません。'; return; }; selector="$t" ;;
    esac
    i=$((i+1))
  done
  [ "$disable" -eq 1 ] && return
  [ "$squash" -eq 1 ] && [ "$other_strategy" -eq 0 ] || return
  if [ "$unknown" -eq 1 ]; then mc_stop '未対応のmerge flagがあるため件名を検査できません。'; return; fi
  if [ "$MC_CWD_UNKNOWN" -eq 1 ] && [ -z "$repo_arg" ]; then mc_stop '先行cwd変更が未解決のため件名を検査できません。'; return; fi
  if [ "$MC_ENV_UNKNOWN" -eq 2 ] || { [ "$MC_ENV_UNKNOWN" -eq 1 ] && [ -z "$repo_arg" ]; }; then mc_stop '先行prefix/gh実行環境が未解決のため件名を検査できません。'; return; fi
  if [ -n "$body_file" ]; then
    if [ "$have_body" -eq 1 ] || [ "$body_file" = - ] || [ "$prior" -ne 0 ] || [ "$MC_CWD_UNKNOWN" -ne 0 ]; then mc_note 'body-file/stdin/先行commandの内容を確定できないため検査を省略しました。'; return; fi
    ff_path_is_absolute "$body_file" || body_file="$cwd/$body_file"  # Windows の C:/… も絶対（Issue `#2367`）
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
if [ -n "$MC_STOP_REASON" ]; then
  reason="$MC_STOP_REASON
この呼び出し全体は未実行です。単独の gh pr merge（先行の cd、未解決の変数、wrapper、global flag を含めない形）へ書き直して再実行してください。
迂回: 同じmergeの前置 FF_MERGE_CLOSING_ACK=1、全体無効化 FF_DEV_TOOLKIT_SKIP_MERGE_CLOSING_GUARD=1。
${MC_NOTES}"
  printf '%s' "$reason" | jq -Rs '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:.}}'
  exit 0
fi
mc_finish
