#!/usr/bin/env bash
# Issue #623 由来の Codex-only 互換シムについて、Issue #1011 の文書に残す
# cache semantic-version 選択と sidecar より先という例外契約を動的に固定する。

make_shim_cache_candidate() {
  local root="$1" version="$2" marker="$3"
  mkdir -p "$root/scripts/templates" "$root/.claude-plugin"
  cp "$PLUGIN_ROOT/scripts/templates/codex-review.sh" "$root/scripts/templates/codex-review.sh"
  printf '%s\n' '{' "  \"version\": \"${version}\"" '}' >"$root/.claude-plugin/plugin.json"
  printf 'toolkit_version: "%s"\n' "$version" >"$root/scripts/agent-config.yaml"
  printf '%s\n' '#!/usr/bin/env bash' '# accepts --task review and implement modes' \
    "printf '%s\\n' '$marker' >\"\${SHIM_SELECTION_RESULT:?}\"" \
    >"$root/scripts/multi-agent.sh"
  chmod +x "$root/scripts/multi-agent.sh"
}

run_shim_cache_selection() {
  local root="$TMP_ROOT/shim-cache-selection" consumer="$TMP_ROOT/shim-cache-consumer"
  local codex_home="$root/codex" claude_home="$root/claude" result="$root/result.txt"
  local codex_cache="$codex_home/plugins/cache/marketplace/ff-dev-toolkit"
  local claude_cache="$claude_home/plugins/cache/marketplace/ff-dev-toolkit"
  local sidecar_root="$root/sidecar" rc=0

  echo
  echo "== Codex-only互換shimのcache選択 =="
  mkdir -p "$consumer/scripts"
  cp "$PLUGIN_ROOT/scripts/templates/codex-review.sh" "$consumer/scripts/codex-review.sh"
  make_shim_cache_candidate "$codex_cache/0.9.0" 0.9.0 codex-0.9.0
  make_shim_cache_candidate "$codex_cache/0.10.0" 0.10.0 codex-0.10.0
  make_shim_cache_candidate "$sidecar_root" 9.9.9 sidecar-9.9.9
  printf '%s\n' "$sidecar_root/scripts" >"$consumer/scripts/.ff-dev-toolkit-root"

  (cd "$consumer" && unset FF_DEV_TOOLKIT_ROOT && \
    CODEX_HOME="$codex_home" CLAUDE_CONFIG_DIR="$claude_home" \
    SHIM_SELECTION_RESULT="$result" bash scripts/codex-review.sh --dry-run) \
    >"$root/codex-semver.log" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ] && [ "$(sed -n '1p' "$result")" = codex-0.10.0 ]; then
    ok "shimは辞書順でなくsemantic version最大のCodex cacheをsidecarより先に選ぶ"
  else
    bad "shimのCodex cache semantic-version選択またはsidecar優先順位が退行 (rc=${rc})"
  fi

  make_shim_cache_candidate "$claude_cache/1.0.0" 1.0.0 claude-1.0.0
  rc=0
  (cd "$consumer" && unset FF_DEV_TOOLKIT_ROOT && \
    CODEX_HOME="$codex_home" CLAUDE_CONFIG_DIR="$claude_home" \
    SHIM_SELECTION_RESULT="$result" bash scripts/codex-review.sh --dry-run) \
    >"$root/cross-cache-semver.log" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ] && [ "$(sed -n '1p' "$result")" = claude-1.0.0 ]; then
    ok "shimはCodex/Claude cacheを横断してsemantic version最大を選ぶ"
  else
    bad "shimがCodex/Claude cache横断のsemantic version最大を選ばない (rc=${rc})"
  fi

  make_shim_cache_candidate "$codex_cache/1.0.0" 1.0.0 codex-1.0.0
  rc=0
  (cd "$consumer" && unset FF_DEV_TOOLKIT_ROOT && \
    CODEX_HOME="$codex_home" CLAUDE_CONFIG_DIR="$claude_home" \
    SHIM_SELECTION_RESULT="$result" bash scripts/codex-review.sh --dry-run) \
    >"$root/cache-tie.log" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ] && [ "$(sed -n '1p' "$result")" = codex-1.0.0 ]; then
    ok "shimは同一versionの両cacheではCodex cacheを優先する"
  else
    bad "shimが同一version時のCodex cache優先順位を保持しない (rc=${rc})"
  fi
}
