# shellcheck shell=bash
# 鍵 decision-tree: hooks/decision-tree.sh（UserPromptSubmit / Stop）。止める効果 = ルータの判定とセッションの記録
# （<state>/metrics/sessions/<session>.route）。
# 入力: Issue 番号付きのブランチ（番号の印は実行時に組む）の一時リポジトリでの UserPromptSubmit。
fx_owners='hooks/decision-tree.sh'
fx_setup() {
  local fx_h='#'
  fx_git_repo "$fx_wk/repo" || return 1
  git -C "$fx_wk/repo" checkout -q -b "feat/${fx_h}4321-fixture" || return 1
  jq -nc --arg d "$fx_wk/repo" '{hook_event_name: "UserPromptSubmit", session_id: "s1", cwd: $d, prompt: "x"}' > "$fx_wk/in.json"
}
fx_run() { FF_DEV_TOOLKIT_STATE_DIR="$fx_wk/state" WORKFLOW_TIER_BASE=main fx_hook hooks/decision-tree.sh; }
fx_judge() {
  local fx_r
  fx_r="$(fx_rc)"
  [ "$fx_r" = 0 ] || { echo "ERROR rc=${fx_r}"; return 0; }
  if [ -f "$fx_wk/state/metrics/sessions/s1.route" ]; then echo "STOP s1.route を書いた"; else echo "PASS s1.route なし"; fi
}
