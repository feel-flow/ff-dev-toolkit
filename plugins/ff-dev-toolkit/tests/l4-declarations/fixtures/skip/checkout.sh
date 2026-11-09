# shellcheck shell=bash
# 鍵 checkout: hooks/guard-checkout-restore.sh（PreToolUse(Bash)）。止める効果 = deny。
# 入力: 未コミットの変更がある dirty.txt への `git checkout -- dirty.txt`。
fx_owners='hooks/guard-checkout-restore.sh'
fx_setup() {
  fx_dirty_repo "$fx_wk/repo" || return 1
  fx_bash_input 'git checkout -- dirty.txt' "$fx_wk/repo" > "$fx_wk/in.json"
}
fx_run() { fx_hook hooks/guard-checkout-restore.sh; }
fx_judge() { fx_judge_deny; }
