# shellcheck shell=bash
# 鍵 default-branch-commit: hooks/guard-default-branch-commit.sh（PreToolUse(Bash)）。止める効果 = deny。
# 入力は既定ブランチ上の git commit。origin/HEAD は main を指し、件名は knowledge: でも release: でもない。
fx_owners='hooks/guard-default-branch-commit.sh'
fx_setup() {
  fx_git_repo "$fx_wk" || return 1
  git -C "$fx_wk" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main || return 1
  fx_bash_input "git commit -m 'feat: x'" "$fx_wk" > "$fx_wk/in.json"
}
fx_run() { fx_hook hooks/guard-default-branch-commit.sh; }
fx_judge() { fx_judge_deny; }
