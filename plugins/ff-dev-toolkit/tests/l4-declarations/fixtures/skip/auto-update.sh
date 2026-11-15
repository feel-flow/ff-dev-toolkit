# shellcheck shell=bash
# 鍵 auto-update: hooks/auto-update-marketplace.sh（SessionStart）。止める効果 = claude CLI の
# `plugin marketplace update` / `plugin update` の呼び出し（stub の記録 calls）。
# 入力: SessionStart の stdin、PATH の先頭に claude の stub、同日ゲートは作業ディレクトリの中。
# 名簿の legacy_value_rule=retired-stop なので、表は撤去した旧名（=0 と _GUARD 付き =1）の行で素通し（更新を
# 呼ばない）を、空の値の行で止める（更新を呼ぶ）を期待する。
fx_owners='hooks/auto-update-marketplace.sh scripts/antigravity/auto-update.sh'
fx_setup() {
  mkdir -p "$fx_wk/bin" "$fx_wk/stamps" "$fx_wk/agy-out" "$fx_wk/state" "$fx_wk/home" || return 1
  fx_session_start
  printf '%s\n' '#!/bin/bash' 'printf "%s\n" "$*" >> "$fx_calls"' \
    'case "$*" in "plugin list --json") printf "%s\n" '"'"'[{"id":"ff-dev-toolkit@marketplace-a","scope":"user"}]'"'"' ;; esac' \
    'exit 0' > "$fx_wk/bin/claude"
  chmod +x "$fx_wk/bin/claude"
}
fx_run() {
  local agy_rc=0
  fx_calls="$fx_wk/calls" FF_DEV_TOOLKIT_AUTO_UPDATE_STAMP="$fx_wk/stamps/stamp" PATH="$fx_wk/bin:$PATH" \
    fx_hook hooks/auto-update-marketplace.sh || return $?
  FF_DEV_TOOLKIT_AGY_AUTO_UPDATE_STAMP="$fx_wk/stamps/agy-stamp" \
    FF_DEV_TOOLKIT_STATE_DIR="$fx_wk/state" \
    HOME="$fx_wk/home" \
    /bin/bash "$fx_plugin/scripts/antigravity/auto-update.sh" --hook --out "$fx_wk/agy-out" \
    >> "$fx_wk/out" 2>> "$fx_wk/err" || agy_rc=$?
  printf '%s\n' "$agy_rc" > "$fx_wk/agy_rc"
}
fx_judge() {
  local fx_r fx_r2 fx_n fx_stamp=0 f
  fx_r="$(fx_rc)"
  fx_r2="$(cat "$fx_wk/agy_rc" 2>/dev/null || echo 1)"
  fx_n="$(fx_lines "$fx_wk/calls")"
  for f in "$fx_wk/stamps"/agy-stamp.*; do
    [ -e "$f" ] || continue
    fx_stamp=1
    break
  done
  [ "$fx_r" = 0 ] && [ "$fx_r2" = 0 ] || { echo "ERROR rc=${fx_r},${fx_r2}"; return 0; }
  if [ "$fx_n" -gt 0 ] && [ "$fx_stamp" -eq 1 ]; then
    echo "STOP claude を ${fx_n} 回呼び Antigravity スタンプも記録した"
  elif [ "$fx_n" -eq 0 ] && [ "$fx_stamp" -eq 0 ]; then
    echo "PASS claude の呼び出し 0 回・Antigravity スタンプ未記録"
  else
    echo "ERROR オーナー間で停止/実行が不一致 (claude=${fx_n}, agy_stamp=${fx_stamp})"
  fi
}
