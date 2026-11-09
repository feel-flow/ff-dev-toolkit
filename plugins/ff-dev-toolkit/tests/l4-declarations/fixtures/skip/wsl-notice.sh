# shellcheck shell=bash
# 鍵 wsl-notice: hooks/check-update.sh（SessionStart。判定と文言は能力層 scripts/lib/wsl-notice.sh）。
# 止める効果 = Windows の Git Bash での WSL の案内（systemMessage）と記録 <cache>/wsl-notice。
# 入力: OSTYPE は BASH_ENV のファイルで msys にする（bash は OSTYPE を初期化した後に BASH_ENV を読む）。
# 更新の取得先は実在しないリポジトリで、更新通知は出ない（終わり際の EXIT trap が案内を出す）。
# 旧名の回は L4 宣言の通知にも WSL の綴りが出るので、判定は案内の本文と記録で見る。
fx_owners='hooks/check-update.sh'
fx_setup() { printf 'OSTYPE=msys\n' > "$fx_wk/bashenv-msys" && fx_session_start; }
fx_run() {
  BASH_ENV="$fx_wk/bashenv-msys" FF_DEV_TOOLKIT_UPDATE_REPO_URL="$fx_wk/no-such.git" FF_DEV_TOOLKIT_UPDATE_CACHE_DIR="$fx_wk/cache" \
    fx_hook hooks/check-update.sh
}
fx_judge() {
  local fx_r fx_s fx_c=なし
  fx_r="$(fx_rc)"
  [ "$fx_r" = 0 ] || { echo "ERROR rc=${fx_r}"; return 0; }
  fx_s="$(jq -r '.systemMessage // ""' < "$fx_wk/out" 2>/dev/null)"
  [ -f "$fx_wk/cache/wsl-notice" ] && fx_c=あり
  case "${fx_c}:${fx_s}" in
    あり:*"Windows の Git Bash 上で動いています"*) echo "STOP WSL の案内と記録あり" ;;
    なし:*"Windows の Git Bash 上で動いています"*) echo "ERROR 案内は出たのに記録が無い" ;;
    あり:*) echo "ERROR 案内は無いのに記録がある" ;;
    *) echo "PASS WSL の案内なし・記録なし" ;;
  esac
}
