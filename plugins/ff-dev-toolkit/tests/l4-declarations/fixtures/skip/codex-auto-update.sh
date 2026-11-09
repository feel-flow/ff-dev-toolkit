# shellcheck shell=bash
# 鍵 codex-auto-update: scripts/lib/multi-agent-codex-update.sh の ensure_codex_cli_current（multi-agent.sh が
# 開始時に source する構成ファイル）。止める効果 = codex-cli の版の確認と自動更新（npm の stub の `install -g`）。
# 入力: multi-agent.sh と同じ set の下で、入口と同じ形で判定 lib を読んでから構成ファイルを source し、plan に
# codex-cli があって委譲しない回として呼ぶ。npm 配置の codex は版 1.1.0、models_cache の client_version は 1.2.0（更新が要る組）。npm の stub は
# 呼び出しを calls に記録し、install -g で版を 1.3.0 へ書き換える。
fx_owners='scripts/lib/multi-agent-codex-update.sh'
fx_setup() {
  local fx_p="$fx_wk/prefix/lib/node_modules/@openai/codex"
  mkdir -p "$fx_p/bin" "$fx_wk/bin" "$fx_wk/codex-home" "$fx_wk/state" || return 1
  printf '%s\n' '{"name":"@openai/codex","version":"1.1.0"}' > "$fx_p/package.json"
  printf '#!/bin/sh\nexit 0\n' > "$fx_p/bin/codex.js"
  chmod +x "$fx_p/bin/codex.js"
  ln -s "$fx_p/bin/codex.js" "$fx_wk/bin/codex"
  printf '%s\n' '{"fetched_at":"2026-09-25T00:00:00Z","client_version":"1.2.0","models":[]}' > "$fx_wk/codex-home/models_cache.json"
  {
    printf '%s\n' '#!/bin/bash' "printf '%s\n' \"\$*\" >> '$fx_wk/calls'" 'case "$*" in'
    printf '%s\n' "  'prefix -g') printf '%s\n' '$fx_wk/prefix' ;;"
    printf '%s\n' "  'install -g @openai/codex@latest') printf '%s\n' '{\"name\":\"@openai/codex\",\"version\":\"1.3.0\"}' > '$fx_p/package.json' ;;"
    printf '%s\n' 'esac' 'exit 0'
  } > "$fx_wk/bin/npm"
  chmod +x "$fx_wk/bin/npm"
}
fx_run() {
  # shellcheck disable=SC2016 # 子の bash が展開する
  PATH="$fx_wk/bin:/usr/bin:/bin" CODEX_HOME="$fx_wk/codex-home" FF_DEV_TOOLKIT_STATE_DIR="$fx_wk/state" \
    /bin/bash -c 'set -euo pipefail
      SCRIPT_DIR="$1/scripts"
      DRY_RUN=false
      plan_lists_cli() { [ "$1" = codex-cli ]; }
      task_is_delegated() { return 1; }
      { [ -r "$SCRIPT_DIR/lib/l4-declarations.sh" ] && . "$SCRIPT_DIR/lib/l4-declarations.sh"; } 2>/dev/null || ff_l4_skipped() { return 1; }
      . "$SCRIPT_DIR/lib/multi-agent-codex-update.sh"
      ensure_codex_cli_current' _ "$fx_plugin" > "$fx_wk/out" 2> "$fx_wk/err"
  echo "$?" > "$fx_wk/rc"
}
fx_judge() {
  if [ -f "$fx_wk/calls" ] && grep -c '^install -g' "$fx_wk/calls" > /dev/null; then
    echo "STOP npm install -g を呼んだ"
  elif grep -c 'version check skipped' "$fx_wk/err" > /dev/null; then
    echo "PASS 更新を呼ばない（version check skipped・rc $(fx_rc)）"
  else
    echo "ERROR 更新を呼ばず skipped も無い（rc $(fx_rc)）: $(head -n 2 "$fx_wk/err" | tr '\n' ' ')"
  fi
}
