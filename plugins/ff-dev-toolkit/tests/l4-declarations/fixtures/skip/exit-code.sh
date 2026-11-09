# shellcheck shell=bash
# 鍵 exit-code: hooks/guard-exit-code.sh（PreToolUse(Bash)）。止める効果 = deny。
# 入力: 全件ゲートの出力をパイプで tail に渡す（元処理の rc を失う）呼び出し。
fx_owners='hooks/guard-exit-code.sh'
fx_setup() { fx_bash_input 'bash plugins/ff-dev-toolkit/tests/run-all.sh 2>&1 | tail -20' "$fx_wk" > "$fx_wk/in.json"; }
fx_run() { fx_hook hooks/guard-exit-code.sh; }
fx_judge() { fx_judge_deny; }
