# shellcheck shell=bash
# 鍵 wsl-shell: hooks/guard-wsl-shell.sh（PreToolUse(Bash)）。止める効果 = deny。
# 入力: Windows の Git Bash（環境の OSTYPE=msys。bash は環境の OSTYPE を上書きしない）で
# `wsl -- bash -c 'echo $x'`。wsl は起動しない（判定はコマンド文字列だけ）。
fx_owners='hooks/guard-wsl-shell.sh'
fx_setup() {
  # shellcheck disable=SC2016 # $x は展開しないリテラル（hook が見る形）
  fx_bash_input "wsl -- bash -c 'echo \$x'" "$fx_wk" > "$fx_wk/in.json"
}
fx_run() { OSTYPE=msys fx_hook hooks/guard-wsl-shell.sh; }
fx_judge() { fx_judge_deny; }
