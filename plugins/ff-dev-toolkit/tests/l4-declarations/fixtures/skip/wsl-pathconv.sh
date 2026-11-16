# shellcheck shell=bash
# 鍵 wsl-pathconv: hooks/guard-wsl-shell.sh（PreToolUse(Bash)）。止める効果 = deny（wsl-shell が covers で包含）。
# 入力: Windows の Git Bash（OSTYPE=msys）で、MSYS_NO_PATHCONV=1 無しに `/` 始まり POSIX パスを渡す `wsl.exe` 呼び出し。
fx_owners='hooks/guard-wsl-shell.sh'
fx_setup() { fx_bash_input 'wsl.exe -d Ubuntu --exec bash /mnt/c/x/script.sh' "$fx_wk" > "$fx_wk/in.json"; }
fx_run() { OSTYPE=msys fx_hook hooks/guard-wsl-shell.sh; }
fx_judge() { fx_judge_deny; }
