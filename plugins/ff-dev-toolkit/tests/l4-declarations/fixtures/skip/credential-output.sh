# shellcheck shell=bash
# 鍵 credential-output: hooks/guard-credential-output.sh（PreToolUse(Bash)）。止める効果 = deny。
# 入力: `cat ~/.npmrc`（認証情報のファイルを出力へ出す）。ファイルは作らない（判定はコマンド文字列だけ）。
fx_owners='hooks/guard-credential-output.sh'
fx_setup() { fx_bash_input 'cat ~/.npmrc' "$fx_wk" > "$fx_wk/in.json"; }
fx_run() { fx_hook hooks/guard-credential-output.sh; }
fx_judge() { fx_judge_deny; }
