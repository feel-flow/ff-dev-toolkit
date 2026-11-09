# shellcheck shell=bash
# 鍵 zsh-expansion: owner は 2 つ。hooks/guard-zsh-glob.sh（PreToolUse(Bash)）と、その hook が呼ぶ判定
# tests/lib/zsh-expansion-guard.sh。止める効果 = どちらも deny。
# 入力: ホストのシェルが zsh（SHELL=/bin/zsh）で、未引用の equals 展開 `echo ===`。
# 2 つを同じ入力で別々に起動し、両方止まれば STOP、両方素通しなら PASS、食い違えば ERROR。
fx_owners='hooks/guard-zsh-glob.sh tests/lib/zsh-expansion-guard.sh'
fx_setup() { fx_bash_input 'echo ===' "$fx_wk" > "$fx_wk/in.json"; }
fx_run() {
  SHELL=/bin/zsh fx_hook tests/lib/zsh-expansion-guard.sh
  mv "$fx_wk/out" "$fx_wk/out.lib" && mv "$fx_wk/rc" "$fx_wk/rc.lib" || return 1
  SHELL=/bin/zsh fx_hook hooks/guard-zsh-glob.sh
}
fx_judge() {
  local fx_a fx_b
  fx_a="$(fx_judge_deny)"
  fx_b="$(fx_rc "$fx_wk/rc.lib")/$(fx_decision "$fx_wk/out.lib")"
  case "${fx_a%% *}:${fx_b}" in
    STOP:0/deny) echo "STOP hook と判定の両方が deny" ;;
    PASS:0/deny) echo "ERROR hook は素通しなのに判定は deny" ;;
    PASS:0/*) echo "PASS hook と判定の両方が素通し（判定 ${fx_b}）" ;;
    *) echo "ERROR hook: ${fx_a} / 判定 rc/decision: ${fx_b}" ;;
  esac
}
