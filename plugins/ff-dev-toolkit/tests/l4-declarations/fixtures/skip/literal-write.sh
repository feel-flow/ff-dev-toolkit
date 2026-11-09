# shellcheck shell=bash
# 鍵 literal-write: hooks/guard-literal-write.sh（PreToolUse(Bash)）。止める効果 = deny。
# 入力: perl -pi の置換文字列に変数展開の形（${REPO}）を含むインプレース書き換え。
fx_owners='hooks/guard-literal-write.sh'
fx_setup() {
  printf 'x\n' > "$fx_wk/t.sh"
  # shellcheck disable=SC2016 # ${REPO} は展開しないリテラル（hook が見る形）
  fx_bash_input "perl -pi -e 's/x/\${REPO}/' t.sh" "$fx_wk" > "$fx_wk/in.json"
}
fx_run() { fx_hook hooks/guard-literal-write.sh; }
fx_judge() { fx_judge_deny; }
