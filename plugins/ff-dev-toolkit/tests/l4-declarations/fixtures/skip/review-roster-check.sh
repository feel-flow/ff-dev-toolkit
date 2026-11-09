# shellcheck shell=bash
# 鍵 review-roster-check: hooks/check-review-roster-drift.sh（SessionStart）。止める効果 = 通知
# （systemMessage と additionalContext の JSON）。入力: 名簿を持つ hook の上書きを実在しないパスにして、
# 突き合わせを始められない「判定不能」の通知の経路を通す。Claude の設定ディレクトリは空。
fx_owners='hooks/check-review-roster-drift.sh'
fx_setup() { mkdir -p "$fx_wk/claude" && fx_session_start; }
fx_run() {
  FF_DEV_TOOLKIT_ROSTER_DRIFT_HOOK="$fx_wk/no-such-hook.sh" FF_DEV_TOOLKIT_ROSTER_DRIFT_CLAUDE_HOME="$fx_wk/claude" \
    fx_hook hooks/check-review-roster-drift.sh
}
fx_judge() { fx_judge_notice; }
