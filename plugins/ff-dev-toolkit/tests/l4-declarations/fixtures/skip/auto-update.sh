# shellcheck shell=bash
# 鍵 auto-update: hooks/auto-update-marketplace.sh（SessionStart）。止める効果 = claude CLI の
# `plugin marketplace update` / `plugin update` の呼び出し（stub の記録 calls）。
# 入力: SessionStart の stdin、PATH の先頭に claude の stub、同日ゲートは作業ディレクトリの中。
# 旧名は legacy_value_rule=nonempty なので、表は旧名=0 の行も素通しを期待する。
fx_owners='hooks/auto-update-marketplace.sh'
fx_setup() {
  mkdir -p "$fx_wk/bin" "$fx_wk/stamps" || return 1
  fx_session_start
  printf '%s\n' '#!/bin/bash' 'printf "%s\n" "$*" >> "$fx_calls"' \
    'case "$*" in "plugin list --json") printf "%s\n" '"'"'[{"id":"ff-dev-toolkit@marketplace-a","scope":"user"}]'"'"' ;; esac' \
    'exit 0' > "$fx_wk/bin/claude"
  chmod +x "$fx_wk/bin/claude"
}
fx_run() {
  fx_calls="$fx_wk/calls" FF_DEV_TOOLKIT_AUTO_UPDATE_STAMP="$fx_wk/stamps/stamp" PATH="$fx_wk/bin:$PATH" \
    fx_hook hooks/auto-update-marketplace.sh
}
fx_judge() {
  local fx_r fx_n
  fx_r="$(fx_rc)"
  fx_n="$(fx_lines "$fx_wk/calls")"
  [ "$fx_r" = 0 ] || { echo "ERROR rc=${fx_r}"; return 0; }
  if [ "$fx_n" -gt 0 ]; then echo "STOP claude を ${fx_n} 回呼んだ"; else echo "PASS claude の呼び出し 0 回"; fi
}
