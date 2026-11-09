# shellcheck shell=bash
# 鍵 commit-identity: scripts/lib/commit-identity-functions.sh の ff_commit_identity_check（knowledge-commit.sh /
# finish.sh / release-dev-toolkit.sh が commit の直前に呼ぶ）。止める効果 = 合成の identity
# （user.email が example.invalid）で rc 1 と復旧手順。
# 入力: local config に合成の identity を置いた一時リポジトリ（fx_git_repo が試験の共通の道具で初期化し、
# その既定の identity が合成の値）。lib を source して関数を 1 回呼ぶ。
# リポジトリ直下に配布外の .claude/hooks/guard-commit-identity.sh がある checkout では、同じ宣言で
# その hook も起動し、lib と食い違えば ERROR にする（公開 checkout には無いので lib だけで判定する）。
fx_owners='scripts/lib/commit-identity-functions.sh'
fx_setup() {
  fx_git_repo "$fx_wk/repo" || return 1
  fx_bash_input 'git commit -m x' "$fx_wk/repo" > "$fx_wk/in.json"
}
fx_run() {
  # shellcheck disable=SC2016 # 子の bash が展開する
  /bin/bash -c '. "$1/scripts/lib/commit-identity-functions.sh" && ff_commit_identity_check "$2"' _ "$fx_plugin" "$fx_wk/repo" \
    > "$fx_wk/out" 2> "$fx_wk/err"
  echo "$?" > "$fx_wk/rc"
  if [ -f "$fx_root/.claude/hooks/guard-commit-identity.sh" ]; then
    GIT_CEILING_DIRECTORIES="$fx_wk" /bin/bash "$fx_root/.claude/hooks/guard-commit-identity.sh" < "$fx_wk/in.json" > "$fx_wk/hook.out" 2> "$fx_wk/hook.err"
  fi
}
fx_judge() {
  local fx_r fx_d=absent
  fx_r="$(fx_rc)"
  [ -f "$fx_wk/hook.out" ] && fx_d="$(fx_decision "$fx_wk/hook.out")"
  case "${fx_r}:${fx_d}" in
    1:deny | 1:absent) echo "STOP lib rc 1・.claude の hook ${fx_d}" ;;
    0:none | 0:allow | 0:absent) echo "PASS lib rc 0・.claude の hook ${fx_d}" ;;
    *) echo "ERROR lib rc ${fx_r}・.claude の hook ${fx_d}（食い違い）" ;;
  esac
}
