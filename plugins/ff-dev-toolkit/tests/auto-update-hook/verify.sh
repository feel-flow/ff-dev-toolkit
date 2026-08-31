#!/usr/bin/env bash
#
# auto-update-marketplace.sh（Issue #856）の回帰検査。
#
# 固定する契約:
#   - 引数なしの marketplace update（登録名に依存しない）と、plugin list --json
#     から解決した ff-dev-toolkit@… の登録 ID + scope での本体 update（非 TTY 必須の
#     -y 付き）を発行する。他プラグインは更新しない
#   - 同日 2 回目の実行は日付ゲートで間引かれ、claude を一切呼ばない
#     （ゲートは noclobber の atomic create — 並行セッションの二重実行も防ぐ）
#   - 日付が変われば再実行し、古いゲートファイルを掃除する
#   - ゲートを書けない環境では実行せず無出力で exit 0（毎セッション再試行しない）
#   - claude CLI が無い環境では何も書かず exit 0（fail-silent。起動を妨げない）
#   - FF_DEV_TOOLKIT_SKIP_AUTO_UPDATE=1 で無効化できる
#   - claude が失敗しても exit 0（オフライン耐性）
#   - hooks.json に async: true + timeout 付きで登録されている（SessionStart の
#     体感遅延を作らない — AC）
#
# bash 3.2 互換。ネットワークには触らない（claude は記録 stub）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$PLUGIN_ROOT/hooks/auto-update-marketplace.sh"
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"

[[ -f "$TARGET" ]] || { echo "✗ hooks/auto-update-marketplace.sh がありません" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "○ skip: jq が無いため auto-update-hook を検証できません（検査は1件も実行されていません）"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/auto-update-hook.XXXXXX")"
REACHED_END=0
cleanup() {
  local rc=$?
  rm -rf "$TMP"
  if [[ "$REACHED_END" -ne 1 && "$rc" -eq 0 ]]; then
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
CALLS="$TMP/claude-calls"
# `plugin list --json` は scope 混在の 2 経路 + 無関係プラグインを返す
# （scope 解決と ID 絞り込みを実測する）。plain の `plugin list` は ID 行のみ
cat > "$STUB_BIN/claude" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CALLS"
if [ "\$1" = "plugin" ] && [ "\$2" = "list" ]; then
  if [ "\${3:-}" = "--json" ]; then
    printf '%s\n' '[{"id":"ff-dev-toolkit@marketplace-a","scope":"user"},{"id":"ff-dev-toolkit@marketplace-b","scope":"project"},{"id":"other-plugin@marketplace-a","scope":"user"}]'
  else
    printf '%s\n' "ff-dev-toolkit@marketplace-a (v0.1.0)" "other-plugin@marketplace-a (v1.0.0)"
  fi
fi
exit "\${FF_STUB_CLAUDE_RC:-0}"
EOF
chmod +x "$STUB_BIN/claude"

STAMP="$TMP/stamps/stamp"
mkdir -p "$TMP/stamps"

run_hook() { # 追加 env は呼び出し側で前置する
  set +e
  OUT="$(FF_DEV_TOOLKIT_AUTO_UPDATE_STAMP="$STAMP" PATH="$STUB_BIN:$PATH" bash "$TARGET" 2>&1)"
  RC=$?
  set -e
}

gate_count() { ls "$TMP/stamps" 2>/dev/null | wc -l | tr -d ' '; }

echo "== auto-update-marketplace =="

# ---- 1. 初回実行: 引数なし marketplace update + JSON 由来の ID/scope で更新 ----
# マーケットプレイス名を引数に取らないこと自体が契約（登録名の変動を吸収し、
# 配布物へ開発元の識別子を埋め込まない — 公開同期の禁止パターン）
: > "$CALLS"
rm -f "$TMP/stamps"/*
run_hook
if [[ "$RC" -eq 0 && -z "$OUT" ]] \
  && grep -qx "plugin marketplace update" "$CALLS" \
  && grep -q -- "plugin update -y --scope user ff-dev-toolkit@marketplace-a" "$CALLS" \
  && grep -q -- "plugin update -y --scope project ff-dev-toolkit@marketplace-b" "$CALLS" \
  && ! grep -q "plugin update.*other-plugin" "$CALLS"; then
  ok "初回実行: 引数なし marketplace update + JSON 由来の ID/scope + -y で本体 update（無出力 / exit 0）"
else
  bad "初回実行の発行内容が不正（rc=${RC} / calls: $(tr '\n' ';' < "$CALLS")）"
fi

# ---- 2. 同日 2 回目は日付ゲートで間引かれる ------------------------------------
: > "$CALLS"
run_hook
if [[ "$RC" -eq 0 && ! -s "$CALLS" ]]; then
  ok "同日 2 回目は日付ゲートで間引かれ claude を呼ばない（atomic create の take-or-skip）"
else
  bad "間引きが効いていない（rc=${RC} / calls: $(tr '\n' ';' < "$CALLS")）"
fi

# ---- 3. 日付が変われば再実行し、古いゲートを掃除する ---------------------------
rm -f "$TMP/stamps"/*
: > "${STAMP}.2000-01-01"
: > "$CALLS"
run_hook
TODAY="$(date +%Y-%m-%d)"
if [[ "$RC" -eq 0 && -s "$CALLS" && -e "${STAMP}.${TODAY}" && ! -e "${STAMP}.2000-01-01" ]]; then
  ok "日付が変われば再実行し、今日のゲートを作って古いゲートを掃除する"
else
  bad "日またぎの再実行 / ゲート更新が不正（rc=${RC} / gates: $(ls "$TMP/stamps" | tr '\n' ';')）"
fi

# ---- 4. ゲートを書けない環境では実行しない（毎セッション再試行しない） ---------
NOTADIR="$TMP/notadir"
: > "$NOTADIR"
: > "$CALLS"
set +e
OUT="$(FF_DEV_TOOLKIT_AUTO_UPDATE_STAMP="$NOTADIR/sub/stamp" PATH="$STUB_BIN:$PATH" bash "$TARGET" 2>&1)"
RC=$?
set -e
if [[ "$RC" -eq 0 && -z "$OUT" && ! -s "$CALLS" ]]; then
  ok "ゲートを書けない環境では無出力 + claude を呼ばず exit 0（間引き契約を保つ）"
else
  bad "書き込み不能時の挙動が不正（rc=${RC} / out=${OUT} / calls: $(tr '\n' ';' < "$CALLS")）"
fi

# ---- 5. claude 不在は fail-silent（ゲートも書かない） --------------------------
rm -f "$TMP/stamps"/*
set +e
OUT="$(FF_DEV_TOOLKIT_AUTO_UPDATE_STAMP="$STAMP" PATH="/usr/bin:/bin" bash "$TARGET" 2>&1)"
RC=$?
set -e
if [[ "$RC" -eq 0 && -z "$OUT" && "$(gate_count)" == "0" ]]; then
  ok "claude CLI 不在なら何も書かず無出力で exit 0（起動を妨げない）"
else
  bad "claude 不在時の挙動が不正（rc=${RC} / out=${OUT} / gates=$(gate_count)）"
fi

# ---- 6. オプトアウト ------------------------------------------------------------
: > "$CALLS"
rm -f "$TMP/stamps"/*
set +e
OUT="$(FF_DEV_TOOLKIT_SKIP_AUTO_UPDATE=1 FF_DEV_TOOLKIT_AUTO_UPDATE_STAMP="$STAMP" PATH="$STUB_BIN:$PATH" bash "$TARGET" 2>&1)"
RC=$?
set -e
if [[ "$RC" -eq 0 && ! -s "$CALLS" && "$(gate_count)" == "0" ]]; then
  ok "FF_DEV_TOOLKIT_SKIP_AUTO_UPDATE=1 で何もしない"
else
  bad "オプトアウトが効かない（rc=${RC}）"
fi

# ---- 7. claude が失敗しても exit 0（オフライン耐性） ---------------------------
rm -f "$TMP/stamps"/*
set +e
OUT="$(FF_STUB_CLAUDE_RC=1 FF_DEV_TOOLKIT_AUTO_UPDATE_STAMP="$STAMP" PATH="$STUB_BIN:$PATH" bash "$TARGET" 2>&1)"
RC=$?
set -e
if [[ "$RC" -eq 0 && -z "$OUT" ]]; then
  ok "claude の失敗（オフライン等）でも無出力で exit 0"
else
  bad "claude 失敗時の挙動が不正（rc=${RC} / out=${OUT}）"
fi

# ---- 8. hooks.json の登録（async + timeout） -----------------------------------
HOOK_ENTRY="$(jq -r '.hooks.SessionStart[0].hooks[] | select(.command | contains("auto-update-marketplace.sh"))' "$HOOKS_JSON" 2>/dev/null)"
if [[ -n "$HOOK_ENTRY" ]] \
  && [[ "$(printf '%s' "$HOOK_ENTRY" | jq -r '.async')" == "true" ]] \
  && [[ "$(printf '%s' "$HOOK_ENTRY" | jq -r '.timeout')" =~ ^[0-9]+$ ]] \
  && printf '%s' "$HOOK_ENTRY" | jq -r '.command' | grep -Fq '${CLAUDE_PLUGIN_ROOT}/hooks/auto-update-marketplace.sh'; then
  ok "hooks.json: SessionStart に async: true + timeout 付きで CLAUDE_PLUGIN_ROOT 経由登録されている"
else
  bad "hooks.json: auto-update-marketplace.sh の登録が不正（async/timeout/経路）"
fi
if [[ -x "$TARGET" ]]; then
  ok "auto-update-marketplace.sh: 実行権限がある"
else
  bad "auto-update-marketplace.sh: 実行権限が無い"
fi

echo
if [[ "$FAIL" -gt 0 ]]; then
  echo "✗ auto-update-hook verify: ${FAIL} 件失敗 / ${PASS} 件成功" >&2
  REACHED_END=1
  exit 1
fi
echo "✓ auto-update-hook verify: 全 ${PASS} 件 pass"
REACHED_END=1
exit 0
