# shellcheck shell=bash
# 鍵 issue-label: hooks/guard-issue-labels.sh（PreToolUse(Bash)）。止める効果 = deny。
# 入力: ラベルの無い `gh issue create --title t`。gh は tests/guard-issue-labels の stub（label list だけに答える）。
fx_owners='hooks/guard-issue-labels.sh'
fx_setup() { fx_bash_input 'gh issue create --title t' "$fx_wk" > "$fx_wk/in.json"; }
fx_run() { PATH="$fx_plugin/tests/guard-issue-labels/fixtures/bin:$PATH" fx_hook hooks/guard-issue-labels.sh; }
fx_judge() { fx_judge_deny; }
