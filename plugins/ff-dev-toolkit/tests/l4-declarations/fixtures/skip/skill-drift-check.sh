# shellcheck shell=bash
# 鍵 skill-drift-check: hooks/check-skill-drift.sh（SessionStart）。止める効果 = 通知（systemMessage と
# additionalContext の JSON）。入力: Claude の設定ディレクトリを空にして、インストール実体を 1 つも
# 見つけられない通知の経路を通す（スキルの正本はこのリポジトリ）。
fx_owners='hooks/check-skill-drift.sh'
fx_setup() { mkdir -p "$fx_wk/claude" && fx_session_start; }
fx_run() {
  FF_DEV_TOOLKIT_SKILL_DRIFT_REPO_ROOT="$fx_root" FF_DEV_TOOLKIT_SKILL_DRIFT_CLAUDE_HOME="$fx_wk/claude" \
    fx_hook hooks/check-skill-drift.sh
}
fx_judge() { fx_judge_notice; }
