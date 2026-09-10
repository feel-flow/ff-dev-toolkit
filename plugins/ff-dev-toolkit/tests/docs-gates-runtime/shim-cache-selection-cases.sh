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
  local stub_codex="$root/stub-codex/codex"

  echo
  echo "== Codex-only互換shimのcache選択 =="
  # シムは委譲の直前で codex の実体を確認し、無ければ降格を名指しして exit 4 で終わる
  # （Issue #1393）。ここで測るのは cache 選択という委譲**前**の関心事なので、codex の
  # 有無から切り離す。stub を渡さないと codex の無いホスト（クラウド）で 3 件が rc=4 で
  # 落ちる（Issue #1427 で実測）。シムは command -v で存在だけを見るので起動はされない。
  mkdir -p "$root/stub-codex"
  printf '%s\n' '#!/usr/bin/env bash' \
    'echo "stub codex must not be invoked by the shim" >&2' 'exit 99' >"$stub_codex"
  chmod +x "$stub_codex"

  # 起動はこのヘルパ経由に限る。各ケースへ直書きすると、ケースを足した人が 1 行落とすだけで
  # 「ローカル（codex あり）は緑・クラウド（codex なし）だけ rc=4 で赤」という見えない退行が
  # 戻る（Phase B がまさにそれだった）。呼び出し元の local 変数を動的スコープで参照する。
  run_shim_cache_case() { # $1: ログの出力先 / 戻り値: シムの rc
    (cd "$consumer" && unset FF_DEV_TOOLKIT_ROOT && \
      CODEX_HOME="$codex_home" CLAUDE_CONFIG_DIR="$claude_home" \
      CODEX_REVIEW_CODEX_BIN="$stub_codex" \
      SHIM_SELECTION_RESULT="$result" bash scripts/codex-review.sh --dry-run) \
      >"$1" 2>&1
  }
  mkdir -p "$consumer/scripts"
  cp "$PLUGIN_ROOT/scripts/templates/codex-review.sh" "$consumer/scripts/codex-review.sh"
  make_shim_cache_candidate "$codex_cache/0.9.0" 0.9.0 codex-0.9.0
  make_shim_cache_candidate "$codex_cache/0.10.0" 0.10.0 codex-0.10.0
  make_shim_cache_candidate "$sidecar_root" 9.9.9 sidecar-9.9.9
  printf '%s\n' "$sidecar_root/scripts" >"$consumer/scripts/.ff-dev-toolkit-root"

  run_shim_cache_case "$root/codex-semver.log" || rc=$?
  if [ "$rc" -eq 0 ] && [ "$(sed -n '1p' "$result")" = codex-0.10.0 ]; then
    ok "shimは辞書順でなくsemantic version最大のCodex cacheをsidecarより先に選ぶ"
  else
    bad "shimのCodex cache semantic-version選択またはsidecar優先順位が退行 (rc=${rc})"
  fi

  make_shim_cache_candidate "$claude_cache/1.0.0" 1.0.0 claude-1.0.0
  rc=0
  run_shim_cache_case "$root/cross-cache-semver.log" || rc=$?
  if [ "$rc" -eq 0 ] && [ "$(sed -n '1p' "$result")" = claude-1.0.0 ]; then
    ok "shimはCodex/Claude cacheを横断してsemantic version最大を選ぶ"
  else
    bad "shimがCodex/Claude cache横断のsemantic version最大を選ばない (rc=${rc})"
  fi

  make_shim_cache_candidate "$codex_cache/1.0.0" 1.0.0 codex-1.0.0
  rc=0
  run_shim_cache_case "$root/cache-tie.log" || rc=$?
  if [ "$rc" -eq 0 ] && [ "$(sed -n '1p' "$result")" = codex-1.0.0 ]; then
    ok "shimは同一versionの両cacheではCodex cacheを優先する"
  else
    bad "shimが同一version時のCodex cache優先順位を保持しない (rc=${rc})"
  fi

  # 起動口の単一化を機械で守る。読めない回を「違反ゼロ」と同じ緑にしないため、対象が
  # 読めることとヘルパ経由の呼び出しが現に在ることを先に確かめる。
  # 見るのは「起動口が 1 箇所きり」という不変条件そのもの。除外リストを持つ形にすると、
  # 検査自身がヘルパ本体を拾う / 除外が実質デッドになる、のどちらかに転びやすい。
  local self="${BASH_SOURCE[0]}" launches=0 uses=0 readable=1
  if [ -r "$self" ]; then
    launches="$(grep -cE 'bash[[:space:]]+scripts/codex-review\.sh' "$self" || true)"
    uses="$(grep -cE '(^|[^_[:alnum:]])run_shim_cache_case[[:space:]]' "$self" || true)"
  else
    readable=0
  fi
  if [ "$readable" -eq 0 ] || [ "${uses:-0}" -lt 2 ]; then
    bad "cache選択の起動口検査が空振りしている (readable=${readable} uses=${uses})"
  elif [ "${launches:-0}" -eq 1 ]; then
    ok "cache選択ケースのシム起動が run_shim_cache_case の 1 箇所に集約されている（stub codex がホスト非依存で届く）"
  else
    bad "シムを起動している行が ${launches} 箇所ある（ヘルパ経由の 1 箇所だけであるべき。直書きは stub の渡し忘れで codex 不在ホストだけ赤くなる）"
    grep -nE 'bash[[:space:]]+scripts/codex-review\.sh' "$self" | sed 's/^/    | /' >&2
  fi
}
