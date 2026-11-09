# shellcheck shell=bash
# ACK review-lock: hooks/guard-review-in-flight.sh（区間の先頭の判定と、書き込みの走査の tests/lib/review-write-scan.sh、
# hook の環境の判定）。入力: レビュー走行中ロック（生存中の pid）があるリポジトリ。形は 3 つ:
#   prefix   区間の先頭の前置での `git commit -m x`
#   write    区間の先頭の前置での `tee README.md`（書き込みの走査の経路）
#   hookenv  hook の環境に置いた名前での Edit（編集系のツールにはコマンドの行が無い）
fx_owners='hooks/guard-review-in-flight.sh'
fx_forms='prefix write hookenv'
fx_setup() { fx_lock_repo "$fx_wk/repo"; }
fx_input() {
  case "$1" in
    prefix) fx_bash_input "${fx_ack_prefix-}git commit -m x" "$fx_wk/repo" > "$fx_wk/in.json" ;;
    write) fx_bash_input "${fx_ack_prefix-}tee README.md" "$fx_wk/repo" > "$fx_wk/in.json" ;;
    hookenv)
      jq -nc --arg d "$fx_wk/repo" '{hook_event_name: "PreToolUse", tool_name: "Edit", cwd: $d, session_id: "l4-table",
        tool_input: {file_path: ($d + "/README.md"), old_string: "x", new_string: "y"}}' > "$fx_wk/in.json" ;;
    *) return 1 ;;
  esac
}
fx_run() { FF_REVIEW_ROUND_LIMIT=0 fx_hook hooks/guard-review-in-flight.sh; }
