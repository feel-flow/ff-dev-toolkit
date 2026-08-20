#!/usr/bin/env bash
# Runtime contract for hooks/retrospective-stop.sh (Issue #583).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$PLUGIN_ROOT/hooks/retrospective-stop.sh"
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"
SKILL="$PLUGIN_ROOT/skills/retrospective/SKILL.md"

[ -f "$TARGET" ] || { echo "✗ retrospective-stop.sh が見つかりません: $TARGET" >&2; exit 1; }
[ -f "$HOOKS_JSON" ] || { echo "✗ hooks.json が見つかりません: $HOOKS_JSON" >&2; exit 1; }
[ -f "$SKILL" ] || { echo "✗ retrospective/SKILL.md が見つかりません: $SKILL" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "✗ jq が必要です" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "✗ node が必要です（継続 JSON の生成に使用）" >&2; exit 1; }
if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/ff-retrospective-stop.XXXXXX" 2>&1)"; then
  TEST_TMP="$_ff_mktemp_out"
else
  echo "✗ 一時ディレクトリを作成できません: $_ff_mktemp_out" >&2
  exit 1
fi
REACHED_END=0
cleanup() {
  local rc=$?
  rm -rf "$TEST_TMP"
  if [ "$REACHED_END" -ne 1 ] && [ "$rc" -eq 0 ]; then
    echo "✗ retrospective Stop hook: 最後まで到達しませんでした" >&2
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

PASS=0
FAIL=0
OUT=""
ERR=""
REASON=""
RC=0

ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

run_hook() {
  local input="$1" mode="${2-__unset__}" test_path="${3-$PATH}"
  local errfile="$TEST_TMP/stderr"
  RC=0
  if [ "$mode" = "__unset__" ]; then
    OUT="$(printf '%s' "$input" | env -u RETROSPECTIVE_MODE PATH="$test_path" /bin/bash "$TARGET" 2>"$errfile")" || RC=$?
  else
    OUT="$(printf '%s' "$input" | env RETROSPECTIVE_MODE="$mode" PATH="$test_path" /bin/bash "$TARGET" 2>"$errfile")" || RC=$?
  fi
  ERR="$(cat "$errfile" 2>/dev/null || true)"
  REASON="$(printf '%s' "$OUT" | jq -r '.reason // empty' 2>/dev/null || true)"
  rm -f "$errfile"
}

assert_silent_success() {
  local label="$1"
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ]; then
    ok "$label"
  else
    bad "$label: exit=$RC output=[$OUT] stderr=[$ERR]"
  fi
}

echo "== retrospective Stop hook =="

FIRST_INPUT='{"hook_event_name":"Stop","session_id":"s1","turn_id":"t1","stop_hook_active":false}'
ACTIVE_INPUT='{"hook_event_name":"Stop","session_id":"s1","turn_id":"t1","stop_hook_active":true}'
DONE_INPUT='{"hook_event_name":"Stop","session_id":"s1","turn_id":"t2","stop_hook_active":false,"last_assistant_message":"振り返り: 改善候補なし"}'

run_hook "$FIRST_INPUT"
if [ "$RC" -eq 0 ] && [ -z "$ERR" ] && [ -n "$OUT" ] \
  && printf '%s' "$OUT" | jq -e . >/dev/null 2>&1 \
  && [ "$(printf '%s' "$OUT" | jq -r '.decision')" = "block" ] \
  && [ -n "$REASON" ] \
  && [ "$(printf '%s' "$OUT" | jq -r '.systemMessage')" = "Automatic retrospective before stop" ]; then
  ok "初回 Stop は単一の継続 JSON を返す"
else
  bad "初回 Stop の出力契約が不正: exit=$RC output=[$OUT] stderr=[$ERR]"
fi
if printf '%s' "$REASON" | grep -F 'ff-dev-toolkit:retrospective' >/dev/null \
  && printf '%s' "$REASON" | grep -F '振り返り: 今回は作業完了前のため対象外' >/dev/null \
  && printf '%s' "$REASON" | grep -F 'do not edit files or create issues' >/dev/null; then
  ok "継続理由がスキル・未完了境界・read-only 境界を含む"
else
  bad "継続理由の必須境界が不足: $OUT"
fi

run_hook "$ACTIVE_INPUT"
assert_silent_success "stop_hook_active=true は再継続せず終了を許可"

run_hook "$DONE_INPUT"
assert_silent_success "最終応答に振り返り結果があれば secondary guard が終了を許可"

run_hook "$FIRST_INPUT" off
assert_silent_success "RETROSPECTIVE_MODE=off は自動振り返りを無効化"

MODE_ALIASES_OK=1
for mode_alias in OFF " off " 0 false NO none Disabled; do
  run_hook "$FIRST_INPUT" "$mode_alias"
  if [ "$RC" -ne 0 ] || [ -n "$OUT" ] || [ -n "$ERR" ]; then
    MODE_ALIASES_OK=0
  fi
done
if [ "$MODE_ALIASES_OK" -eq 1 ]; then
  ok "off の別名は大文字小文字と空白を無視して自動発火を止める"
else
  bad "off の別名に無効化できない値があります"
fi

run_hook "$FIRST_INPUT" ask
if [ "$RC" -eq 0 ] && [ -z "$ERR" ] && printf '%s' "$OUT" | jq -e '.decision == "block"' >/dev/null 2>&1 \
  && printf '%s' "$REASON" | grep -F 'RETROSPECTIVE_MODE=ask' >/dev/null \
  && printf '%s' "$REASON" | grep -F 'already approved' >/dev/null \
  && [ "$(printf '%s' "$OUT" | jq -r '.systemMessage')" = "Automatic retrospective check before stop" ]; then
  ok "RETROSPECTIVE_MODE=ask は実施前確認の継続を返す"
else
  bad "ask モードの出力契約が不正: exit=$RC output=[$OUT] stderr=[$ERR]"
fi

run_hook "$ACTIVE_INPUT" ASK
assert_silent_success "ask モードの継続中も再入せず終了を許可"

run_hook ''
assert_silent_success "空入力は fail-open"
run_hook '{not-json'
assert_silent_success "不正 JSON は fail-open"
run_hook '{"hook_event_name":"SessionStart","stop_hook_active":false}'
assert_silent_success "別イベントは fail-open"
run_hook '{"hook_event_name":"Stop"}'
assert_silent_success "再入フラグ欠損は fail-open"
run_hook "$FIRST_INPUT" __unset__ /definitely-no-node
if [ "$RC" -eq 0 ] && [ -z "$ERR" ] \
  && printf '%s' "$OUT" | jq -e 'has("decision") | not' >/dev/null 2>&1 \
  && printf '%s' "$OUT" | jq -r '.systemMessage // empty' | grep -F 'Node.js 22' >/dev/null \
  && printf '%s' "$OUT" | jq -r '.systemMessage // empty' | grep -F 'ff-dev-toolkit:retrospective' >/dev/null; then
  ok "Node.js 不在は応答をブロックせず復旧ヒントを通知"
else
  bad "Node.js 不在の fail-open 通知が不正: exit=$RC output=[$OUT] stderr=[$ERR]"
fi

OPEN_FIFO="$TEST_TMP/open-stdin"
mkfifo "$OPEN_FIFO"
(
  exec 3>"$OPEN_FIFO"
  printf '%s' "$FIRST_INPUT" >&3
  sleep 4
) &
WRITER_PID=$!
SECONDS=0
RC=0
OUT="$(env -u RETROSPECTIVE_MODE /bin/bash "$TARGET" <"$OPEN_FIFO" 2>"$TEST_TMP/open-stderr")" || RC=$?
ELAPSED=$SECONDS
kill "$WRITER_PID" >/dev/null 2>&1 || true
wait "$WRITER_PID" 2>/dev/null || true
ERR="$(cat "$TEST_TMP/open-stderr" 2>/dev/null || true)"
if [ "$RC" -eq 0 ] && [ "$ELAPSED" -lt 4 ] && [ -z "$ERR" ]; then
  ok "stdin が閉じられなくても入力上限内に復帰"
else
  bad "stdin 入力上限が機能しない: elapsed=${ELAPSED}s exit=$RC output=[$OUT] stderr=[$ERR]"
fi

# The plugin-root expression is intentionally matched as a literal contract.
# shellcheck disable=SC2016
if jq -e '.hooks.Stop | length == 1' "$HOOKS_JSON" >/dev/null 2>&1 \
  && [ "$(jq -r '.hooks.Stop[0].hooks[0].type' "$HOOKS_JSON")" = "command" ] \
  && [ "$(jq -r '.hooks.Stop[0].hooks[0].timeout' "$HOOKS_JSON")" = "5" ] \
  && jq -r '.hooks.Stop[0].hooks[0].command' "$HOOKS_JSON" | grep -F '${CLAUDE_PLUGIN_ROOT}/hooks/retrospective-stop.sh' >/dev/null; then
  ok "hooks.json が Stop hook を timeout 5 秒で登録"
else
  bad "hooks.json の Stop 登録が不正"
fi

if grep -F 'stop_hook_active' "$TARGET" >/dev/null \
  && ! grep -E '(^|/)(\.retrospective|retrospective-state|retrospective-marker)' "$TARGET" >/dev/null; then
  ok "再入防止はホスト入力を使い marker ファイルを持たない"
else
  bad "再入防止が stop_hook_active の無状態契約から外れた"
fi

INCOMPLETE_REPORT='振り返り: 今回は作業完了前のため対象外'
if grep -F "$INCOMPLETE_REPORT" "$SKILL" >/dev/null \
  && printf '%s' "$FIRST_INPUT" | /bin/bash "$TARGET" | jq -r '.reason // empty' | grep -F "$INCOMPLETE_REPORT" >/dev/null \
  && grep -F '## 自動発火（Stop hook）' "$SKILL" >/dev/null \
  && grep -F '自分で hook を再実行したり marker を作ったりしない' "$SKILL" >/dev/null; then
  ok "未完了報告と自動発火境界が hook / SKILL.md で一致"
else
  bad "hook / SKILL.md の自動発火契約が drift"
fi

FS_ROOT="$TEST_TMP/fs-sandbox"
mkdir -p "$FS_ROOT/home" "$FS_ROOT/cwd" "$FS_ROOT/tmp"
FS_BEFORE="$(cd "$FS_ROOT" && find . -print | sort)"
printf '%s' "$FIRST_INPUT" | env -u RETROSPECTIVE_MODE HOME="$FS_ROOT/home" TMPDIR="$FS_ROOT/tmp" /bin/bash "$TARGET" >/dev/null 2>&1
printf '%s' "$FIRST_INPUT" | env RETROSPECTIVE_MODE=ask HOME="$FS_ROOT/home" TMPDIR="$FS_ROOT/tmp" /bin/bash "$TARGET" >/dev/null 2>&1
printf '%s' "$ACTIVE_INPUT" | env RETROSPECTIVE_MODE=ask HOME="$FS_ROOT/home" TMPDIR="$FS_ROOT/tmp" /bin/bash "$TARGET" >/dev/null 2>&1
printf '%s' "$FIRST_INPUT" | env RETROSPECTIVE_MODE=off HOME="$FS_ROOT/home" TMPDIR="$FS_ROOT/tmp" /bin/bash "$TARGET" >/dev/null 2>&1
FS_AFTER="$(cd "$FS_ROOT" && find . -print | sort)"
if [ "$FS_BEFORE" = "$FS_AFTER" ]; then
  ok "初回・再入・ask・off の実行で filesystem marker を作らない"
else
  bad "hook が filesystem へ副作用を作成"
fi

EXPECTED_CHECKS=18
if [ $((PASS + FAIL)) -ne "$EXPECTED_CHECKS" ]; then
  bad "検査総数が $((PASS + FAIL)) 件（期待 ${EXPECTED_CHECKS} 件）"
fi

if [ "$FAIL" -gt 0 ]; then
  echo "✗ retrospective Stop hook: ${FAIL} 件失敗（${PASS} 件成功）" >&2
  exit 1
fi
REACHED_END=1
echo "✓ retrospective Stop hook: ${PASS} 件すべて成功"
