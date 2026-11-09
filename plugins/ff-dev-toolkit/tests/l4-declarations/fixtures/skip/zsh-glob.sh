# shellcheck shell=bash
# 鍵 zsh-glob: hooks/guard-zsh-glob.sh（PreToolUse(Bash)）。止める効果 = deny。
# 入力: ホストのシェルが zsh（SHELL=/bin/zsh）で、未引用の glob を含む `grep -rn x docs --include=*.md`。
fx_owners='hooks/guard-zsh-glob.sh'
fx_setup() { fx_bash_input 'grep -rn x docs --include=*.md' "$fx_wk" > "$fx_wk/in.json"; }
fx_run() { SHELL=/bin/zsh fx_hook hooks/guard-zsh-glob.sh; }
fx_judge() { fx_judge_deny; }
