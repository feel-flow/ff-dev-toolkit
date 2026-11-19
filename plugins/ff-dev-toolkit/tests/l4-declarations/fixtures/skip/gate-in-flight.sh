# shellcheck shell=bash
# 鍵 gate-in-flight: hooks/guard-gate-in-flight.sh（PreToolUse）。止める効果 = deny。
# git_dir 配下の run-all-in-flight/<PID> に生存中の自プロセス $$ を書き、git commit で止める。
fx_owners='hooks/guard-gate-in-flight.sh'
fx_setup() {
  fx_git_repo "$fx_wk/repo" || return 1
  local fx_gd=""
  fx_gd="$(git -C "$fx_wk/repo" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  [ -n "$fx_gd" ] || return 1
  # shellcheck source=../../../../tests/lib/gate-in-flight.sh
  . "$fx_plugin/tests/lib/gate-in-flight.sh" || return 1
  ff_gate_marker_write "$fx_gd" "l4-fixture" "$fx_wk/repo" >/dev/null || return 1
  fx_bash_input "git commit -m x" "$fx_wk/repo" > "$fx_wk/in.json"
}
fx_run() {
  fx_hook hooks/guard-gate-in-flight.sh
}
fx_judge() { fx_judge_deny; }
