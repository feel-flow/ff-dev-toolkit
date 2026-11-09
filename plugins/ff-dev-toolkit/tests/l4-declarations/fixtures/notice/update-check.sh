# shellcheck shell=bash
# SessionStart の L4 宣言の通知: hooks/check-update.sh。表は環境に鍵 update-check の旧名=1 と
# FF_DEV_TOOLKIT_SKIP=<名簿に無い鍵> を置いて起動し、systemMessage と additionalContext の文言を見る。
# fx_judge は更新チェックが止まったまま（PASS = 更新通知もキャッシュも無い）かを返す。更新の取得先は
# v99.0.0 のタグを持つローカルの bare リポジトリ（止まっていなければ 📦 とキャッシュが出る）。
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
  local fx_r fx_s
  fx_r="$(fx_rc)"
  [ "$fx_r" = 0 ] || { echo "ERROR rc=${fx_r}"; return 0; }
  fx_s="$(jq -r '.systemMessage // ""' < "$fx_wk/out" 2>/dev/null)"
  case "$fx_s" in *"📦"*) echo "STOP 更新通知が出た"; return 0 ;; esac
  if [ -e "$fx_wk/cache/update-check" ]; then echo "STOP 更新チェックのキャッシュを作った"; else echo "PASS 更新チェックは止まったまま"; fi
}
