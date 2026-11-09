# shellcheck shell=bash
# 鍵 long-gate-background: hooks/guard-long-gate-background.sh（PreToolUse(Bash)）。
# 止める効果 = deny と発火の台帳（TMPDIR の下の ff-dev-toolkit-delegation-guard/）への記録。
# 入力: 委譲先（agent_type=general-purpose）が全件ゲートを run_in_background で起動する。
fx_owners='hooks/guard-long-gate-background.sh'
fx_setup() {
  jq -nc '{tool_name: "Bash", hook_event_name: "PreToolUse", session_id: "sess-1", cwd: "/tmp",
    tool_input: {command: "bash plugins/ff-dev-toolkit/tests/run-all.sh", run_in_background: true},
    agent_type: "general-purpose", agent_id: "agent-x"}' > "$fx_wk/in.json"
}
fx_run() { fx_hook hooks/guard-long-gate-background.sh; }
fx_judge() {
  local fx_j fx_n=0
  fx_j="$(fx_judge_deny)"
  [ -d "$fx_wk/ff-dev-toolkit-delegation-guard" ] && fx_n="$(find "$fx_wk/ff-dev-toolkit-delegation-guard" -type f | grep -c . || true)"
  case "$fx_j" in
    PASS*) [ "$fx_n" -eq 0 ] || { echo "ERROR 素通しなのに台帳を ${fx_n} 件書いた"; return 0; } ;;
  esac
  echo "${fx_j}・台帳 ${fx_n} 件"
}
