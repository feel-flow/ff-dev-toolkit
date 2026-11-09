# shellcheck shell=bash
# 鍵 sub-issue-id: hooks/guard-sub-issue-id.sh（PreToolUse(Bash)）。止める効果 = deny（sub-issues API の
# integer の欄を gh api の -f で文字列として送る）。
fx_owners='hooks/guard-sub-issue-id.sh'
fx_setup() { fx_bash_input 'gh api --method POST repos/acme/widgets/issues/10/sub_issues -f sub_issue_id=1' "$fx_wk" > "$fx_wk/in.json"; }
fx_run() { fx_hook hooks/guard-sub-issue-id.sh; }
fx_judge() { fx_judge_deny; }
