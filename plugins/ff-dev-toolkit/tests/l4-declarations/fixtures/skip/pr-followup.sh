# shellcheck shell=bash
# 鍵 pr-followup: hooks/guard-pr-followup.sh（PreToolUse(Bash)）。止める効果 = deny（Draft PR の作成。
# covers の pr-draft も同じ鍵で止まる）。入力: `gh pr create --draft --fill`（外部の CLI は起動しない）。
fx_owners='hooks/guard-pr-followup.sh'
fx_setup() { fx_bash_input 'gh pr create --draft --fill' "$fx_wk" > "$fx_wk/in.json"; }
fx_run() { fx_hook hooks/guard-pr-followup.sh; }
fx_judge() { fx_judge_deny; }
