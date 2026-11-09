# shellcheck shell=bash
# 鍵 background-cwd: hooks/guard-background-cwd.sh（PreToolUse(Bash)）。止める効果 = deny。
# 入力: linked worktree を持つリポジトリで、run_in_background の `cd docs && npm test`（先頭が相対パスの cd）。
fx_owners='hooks/guard-background-cwd.sh'
fx_setup() {
  fx_git_repo "$fx_wk/repo" && mkdir -p "$fx_wk/repo/docs" || return 1
  git -C "$fx_wk/repo" worktree add -q -b linked "$fx_wk/linked" || return 1
  fx_bash_input 'cd docs && npm test' "$fx_wk/repo" '{"run_in_background": true}' > "$fx_wk/in.json"
}
fx_run() { fx_hook hooks/guard-background-cwd.sh; }
fx_judge() { fx_judge_deny; }
