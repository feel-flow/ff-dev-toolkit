# shellcheck shell=bash
# 鍵 review-in-flight: hooks/guard-review-in-flight.sh（PreToolUse）。止める効果 = deny。
# 入力: レビュー走行中ロック（生存中の pid）があるリポジトリでの Edit。巡回上限の判定は
# FF_REVIEW_ROUND_LIMIT=0 で外す（ロックの deny だけを見る）。
fx_owners='hooks/guard-review-in-flight.sh'
fx_setup() {
  fx_lock_repo "$fx_wk/repo" || return 1
  jq -nc --arg d "$fx_wk/repo" '{hook_event_name: "PreToolUse", tool_name: "Edit", cwd: $d, session_id: "l4-table",
    tool_input: {file_path: ($d + "/README.md"), old_string: "x", new_string: "y"}}' > "$fx_wk/in.json"
}
fx_run() { FF_REVIEW_ROUND_LIMIT=0 fx_hook hooks/guard-review-in-flight.sh; }
fx_judge() { fx_judge_deny; }
