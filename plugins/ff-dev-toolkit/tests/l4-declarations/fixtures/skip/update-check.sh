# shellcheck shell=bash
# 鍵 update-check: hooks/check-update.sh（SessionStart）。止める効果 = 更新チェック（キャッシュの作成と
# ls-remote）と更新通知（systemMessage の 📦）。
# 入力: ローカルの bare リポジトリに v99.0.0 のタグを置き、取得先をそこへ向ける。キャッシュは作業ディレクトリの中。
# 撤去した旧名の回と鍵の打ち間違いの回は L4 宣言の通知も出るので、判定は 📦 とキャッシュで見る（systemMessage の有無では見ない）。
fx_owners='hooks/check-update.sh'
fx_setup() {
  fx_git_repo "$fx_wk/work" || return 1
  git init -q --bare "$fx_wk/origin.git" && git -C "$fx_wk/work" tag v99.0.0 && git -C "$fx_wk/work" push -q "$fx_wk/origin.git" HEAD:main --tags || return 1
  fx_session_start
}
fx_run() {
  FF_DEV_TOOLKIT_UPDATE_REPO_URL="$fx_wk/origin.git" FF_DEV_TOOLKIT_UPDATE_CACHE_DIR="$fx_wk/cache" fx_hook hooks/check-update.sh
}
fx_judge() {
  local fx_r fx_s fx_c=なし
  fx_r="$(fx_rc)"
  [ "$fx_r" = 0 ] || { echo "ERROR rc=${fx_r}"; return 0; }
  fx_s="$(jq -r '.systemMessage // ""' < "$fx_wk/out" 2>/dev/null)"
  [ -e "$fx_wk/cache/update-check" ] && fx_c=あり
  case "$fx_s" in
    *"📦"*) echo "STOP 更新通知あり・キャッシュ ${fx_c}" ;;
    *) [ "$fx_c" = なし ] || { echo "ERROR 更新通知は無いのにキャッシュを作った"; return 0; }
       echo "PASS 更新通知なし・キャッシュなし" ;;
  esac
}
