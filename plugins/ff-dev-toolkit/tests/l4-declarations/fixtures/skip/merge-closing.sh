# shellcheck shell=bash
# 鍵 merge-closing: hooks/guard-merge-closing-keyword.sh（PreToolUse(Bash)）。止める効果 = deny（gh で PR を照会する）。
# 入力: `gh pr merge 7 --squash`。gh の stub は PR を照会する呼び出しに、コミットが Issue を参照するのに
# closing keyword の無い PR の応答を返し、呼び出しを calls に記録する。Issue の番号の印は実行時に組む。
fx_owners='hooks/guard-merge-closing-keyword.sh'
fx_setup() {
  local fx_h='#'
  mkdir -p "$fx_wk/bin" "$fx_wk/work" || return 1
  {
    printf '%s\n' '#!/bin/bash' 'printf "%s\n" "$*" >> "$fx_gh_dir/calls"'
    printf '%s\n' 'if [ "$1" = pr ] && [ "$2" = view ]; then printf "%s\n" '"'"'{"id":"PR_fixture","url":"https://github.com/owner/repo/pull/7"}'"'"'; exit 0; fi'
    printf '%s\n' 'cat "$fx_gh_dir/response.json"'
  } > "$fx_wk/bin/gh"
  chmod +x "$fx_wk/bin/gh"
  jq -nc --arg ref "Refs ${fx_h}42" --arg head "fix: ${fx_h}42 変更" --arg mb "* fix: ${fx_h}42 変更" \
    '{data: {node: {id: "PR_fixture", number: 7, url: "https://github.com/owner/repo/pull/7", title: "安全な変更", body: $ref,
      headRefOid: ("a" * 40), mergeStateStatus: "CLEAN", isMergeQueueEnabled: false,
      repository: {nameWithOwner: "owner/repo", url: "https://github.com/owner/repo"},
      closingIssuesReferences: {totalCount: 0, nodes: []},
      commits: {totalCount: 1, nodes: [{commit: {oid: ("b" * 40), messageHeadline: $head, messageBody: ""}}]},
      viewerMergeHeadlineText: "安全な変更 (PR 7)", viewerMergeBodyText: $mb}}}' > "$fx_wk/response.json"
  fx_bash_input 'gh pr merge 7 --squash' "$fx_wk/work" > "$fx_wk/in.json"
}
fx_run() { fx_gh_dir="$fx_wk" PATH="$fx_wk/bin:$PATH" fx_hook hooks/guard-merge-closing-keyword.sh; }
fx_judge() {
  local fx_j fx_n
  fx_j="$(fx_judge_deny)"
  fx_n="$(fx_lines "$fx_wk/calls")"
  case "$fx_j" in
    PASS*) [ "$fx_n" -eq 0 ] || { echo "ERROR 素通しなのに gh を ${fx_n} 回呼んだ"; return 0; } ;;
  esac
  echo "${fx_j}・gh ${fx_n} 回"
}
