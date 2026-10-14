#!/usr/bin/env bash
# grok CLI 向け hook 展開（scripts/grok/sync-hooks.sh）と tool_name 正規化シム
# （scripts/grok/hook-shim.sh）の契約を固定する（Issue `#2116`）。
#
# 一時ディレクトリへ生成し、hooks.json とのイベント集合一致・command が `${CLAUDE_PLUGIN_ROOT}` を
# 実パスへ書き換えず env から展開させること・全 handler のシム経由起動・env の付与・--check の判定・hooks.json 不在時の
# 非 0 終了と既存出力の保全を検査する。シムは grok 名 → Claude 名の写像と素通し経路を
# 検査し、展開後の guard-checkout-restore が grok 形式の入力で deny を返すことまで測る。
#
# run-all-required: no — jq 不在では検証本体を実行できないため suite 全体を skip する
# 空振り検出: hook-shim.sh の写像から run_terminal_command を外すと (4)(5)(9) が赤になる（2026-10-13 実測）。
# 空振り検出: sync-hooks.sh で command 先頭へのシム付与を外すと (3)(9) が、command 中の `${CLAUDE_PLUGIN_ROOT}` を実パスへ書き換えると (2)(10) が赤になる（2026-10-13 実測）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SYNC="$PLUGIN_ROOT/scripts/grok/sync-hooks.sh"
SHIM="$PLUGIN_ROOT/scripts/grok/hook-shim.sh"
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"
# shellcheck source=../lib/adapter-env-isolation.sh
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"
isolate_hook_env "FF_DEV_TOOLKIT_SKIP_CHECKOUT_GUARD" "$PLUGIN_ROOT/hooks/guard-checkout-restore.sh"
# shellcheck source=../lib/git-fixture.sh
. "$SCRIPT_DIR/../lib/git-fixture.sh"

[ -f "$SYNC" ] || { echo "✗ sync-hooks.sh が見つかりません: $SYNC" >&2; exit 1; }
[ -f "$SHIM" ] || { echo "✗ hook-shim.sh が見つかりません: $SHIM" >&2; exit 1; }
[ -f "$HOOKS_JSON" ] || { echo "✗ hooks.json が見つかりません: $HOOKS_JSON" >&2; exit 1; }
if ! command -v jq >/dev/null 2>&1; then
  echo "○ skip: jq が無いため grok-hooks-sync は未検査"
  exit 0
fi

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ✗ $1" >&2; }

TMP="$(mktemp -d)"
REACHED_END=0
cleanup() {
  local rc=$?
  rm -rf "$TMP"
  if [ "$REACHED_END" -ne 1 ] && [ "$rc" -eq 0 ]; then
    echo "✗ grok-hooks-sync: 最後まで到達しませんでした" >&2
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT
OUT="$TMP/grok/hooks/ff-dev-toolkit.json"

# (1) 生成とイベント集合
if bash "$SYNC" --out "$OUT" >/dev/null 2>&1 && [ -f "$OUT" ] \
  && [ "$(jq -c '.hooks | keys' "$OUT")" = "$(jq -c '.hooks | keys' "$HOOKS_JSON")" ]; then
  ok "(1) hooks.json と同じイベント集合で生成される"
else
  bad "(1) 生成失敗またはイベント集合が不一致"
fi

# (2) command は hooks.json の本体をそのまま保ち（実パスを埋め込まない）、シムの前置きだけが付く
if [ "$(jq -c --arg p "bash '$SHIM' " '[.hooks[][].hooks[] | select(.type == "command") | .command | ltrimstr($p)]' "$OUT" 2>/dev/null)" \
  = "$(jq -c '[.hooks[][].hooks[] | select(.type == "command") | .command]' "$HOOKS_JSON")" ]; then
  ok "(2) command 本体は hooks.json のまま（\${CLAUDE_PLUGIN_ROOT} は実行時に env から展開）"
else
  bad "(2) command 本体が hooks.json と一致しない（実パスの埋め込みなど）"
fi

# (3) 全 command handler がシム経由・handler 数が一致・env 付与
src_n="$(jq '[.hooks[][].hooks[] | select(.type == "command")] | length' "$HOOKS_JSON")"
out_n="$(jq --arg p "bash '$SHIM' " '[.hooks[][].hooks[] | select(.type == "command") | select(.command | startswith($p)) | select(.env.CLAUDE_PLUGIN_ROOT == $root)] | length' --arg root "$PLUGIN_ROOT" "$OUT" 2>/dev/null || echo -1)"
if [ "$src_n" -gt 0 ] && [ "$src_n" = "$out_n" ]; then
  ok "(3) command handler ${src_n} 件すべてがシム経由で起動し env を持つ"
else
  bad "(3) シム経由の handler 数が不一致（元 ${src_n} / 生成 ${out_n}）"
fi

# (4) シムの写像
got="$(printf '{"tool_name":"run_terminal_command","tool_input":{"command":"ls"}}' | bash "$SHIM" jq -r .tool_name)"
[ "$got" = "Bash" ] && ok "(4) run_terminal_command → Bash" || bad "(4) run_terminal_command の写像: [$got]"
# (5) 他の grok 名
got="$(for n in search_replace write read_file run_terminal_command; do printf '{"tool_name":"%s"}' "$n" | bash "$SHIM" jq -r .tool_name; done | tr '\n' ' ')"
[ "$got" = "Edit Write Read Bash " ] && ok "(5) grok 名 → Claude 名の写像" || bad "(5) 写像: [$got]"
# (6) 未知名・tool_name なし・非 JSON は素通し
a="$(printf '{"tool_name":"mcp__x__y"}' | bash "$SHIM" jq -r .tool_name)"
b="$(printf '{"prompt":"hi"}' | bash "$SHIM" jq -c .)"
c="$(printf 'not json' | bash "$SHIM" cat)"
if [ "$a" = "mcp__x__y" ] && [ "$b" = '{"prompt":"hi"}' ] && [ "$c" = "not json" ]; then
  ok "(6) 未知名・tool_name なし・非 JSON は素通し"
else
  bad "(6) 素通し: [$a] [$b] [$c]"
fi

# (7) --check: 最新なら 0、改変後は 1
if bash "$SYNC" --out "$OUT" --check >/dev/null 2>&1; then
  echo '{"hooks":{}}' > "$TMP/stale.json"
  if ! bash "$SYNC" --out "$TMP/stale.json" --check >/dev/null 2>&1; then
    ok "(7) --check は最新で 0・未同期で 1"
  else
    bad "(7) --check が未同期を検出しない"
  fi
else
  bad "(7) --check が最新を 0 と判定しない"
fi

# (8) hooks.json 不在の plugin root では非 0 で、既存出力を壊さない
mkdir -p "$TMP/fake/scripts/grok"
cp "$SHIM" "$TMP/fake/scripts/grok/"
before="$(cat "$OUT")"
if ! bash "$SYNC" --plugin-root "$TMP/fake" --out "$OUT" >/dev/null 2>&1 && [ "$(cat "$OUT")" = "$before" ]; then
  ok "(8) hooks.json 不在で非 0・既存出力は保全"
else
  bad "(8) hooks.json 不在を検出しない、または既存出力を壊した"
fi

# (9) 展開後の PreToolUse handler が grok 形式入力で guard を発火させる
if command -v git >/dev/null 2>&1; then
  repo="$TMP/repo"
  ff_git_fixture_init "$repo" >/dev/null
  echo a > "$repo/a.txt"
  git -C "$repo" add a.txt && git -C "$repo" commit -qm init
  echo b > "$repo/a.txt"
  input="$(jq -nc --arg cwd "$repo" '{hook_event_name:"PreToolUse",tool_name:"run_terminal_command",cwd:$cwd,tool_input:{command:"git checkout -- a.txt"}}')"
  # 生成物の handler を、その env（CLAUDE_PLUGIN_ROOT）だけを与えて起動する（grok と同じ渡し方）
  run_guard() {
    local out="$1" cmd root
    cmd="$(jq -r '.hooks.PreToolUse[].hooks[] | select(.command | contains("guard-checkout-restore.sh")) | .command' "$out" | head -1)"
    root="$(jq -r '.hooks.PreToolUse[].hooks[] | select(.command | contains("guard-checkout-restore.sh")) | .env.CLAUDE_PLUGIN_ROOT // empty' "$out" | head -1)"
    [ -n "$cmd" ] || return 0
    (cd "$repo" && printf '%s' "$input" | env -u CLAUDE_PLUGIN_ROOT CLAUDE_PLUGIN_ROOT="$root" bash -c "$cmd" 2>/dev/null) || true
  }
  res="$(run_guard "$OUT")"
  if printf '%s' "$res" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
    ok "(9) grok 形式（run_terminal_command）の入力で guard-checkout-restore が deny する"
  else
    bad "(9) 展開後の guard が grok 形式入力で発火しない: [$res]"
  fi
  # (10) plugin root のパスにシェルの特殊文字（$）が入っていても同じ hook が起動する
  ln -s "$PLUGIN_ROOT" "$TMP/root\$cache"
  OUT2="$TMP/out-special.json"
  if bash "$SYNC" --plugin-root "$TMP/root\$cache" --out "$OUT2" >/dev/null 2>&1; then
    res="$(run_guard "$OUT2")"
    if printf '%s' "$res" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
      ok "(10) plugin root に \$ を含むパスでも展開後の guard が発火する"
    else
      bad "(10) plugin root に \$ を含むと展開後の guard が起動しない: [$res]"
    fi
  else
    bad "(10) plugin root に \$ を含むパスで生成に失敗した"
  fi
else
  echo "  ○ skip: git が無いため (9)(10) は未検査"
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ grok-hooks-sync: ${FAIL} 件失敗（成功 ${PASS} 件）" >&2
  REACHED_END=1
  exit 1
fi
echo "✅ grok-hooks-sync: all ${PASS} checks passed"
REACHED_END=1
exit 0
