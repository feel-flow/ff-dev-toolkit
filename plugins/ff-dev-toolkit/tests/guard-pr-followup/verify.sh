#!/usr/bin/env bash
# Runtime contract for the PR follow-up declaration guard hook (Issue #771).
#
# 配布物 hooks/guard-pr-followup.sh を stdin JSON で直接駆動し、Issue #771 の AC
# 各ケース（マーカーあり参照なし→警告 / 参照あり→非警告 / no-followup 抜け道 /
# 通常本文 / gh pr edit / --body-file・heredoc 経由 / 既知の限界の素通し）を固定する。
# 警告文自体が抜け道（no-followup マーカー）と gh issue create を案内する契約も検査し、
# hooks.json の PreToolUse 登録を静的照合する。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$PLUGIN_ROOT/hooks/guard-pr-followup.sh"
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"

[ -f "$TARGET" ] || { echo "✗ guard-pr-followup.sh が見つかりません: $TARGET" >&2; exit 1; }
[ -f "$HOOKS_JSON" ] || { echo "✗ hooks.json が見つかりません: $HOOKS_JSON" >&2; exit 1; }
if ! command -v jq >/dev/null 2>&1; then
  echo "○ skip: jq が見つからないためスキップ（guard-pr-followup は未検査のままです）"
  exit 0
fi

if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/ff-guard-pr.XXXXXX" 2>&1)"; then
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
    echo "✗ guard-pr-followup: 最後まで到達しませんでした" >&2
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

PASS=0
FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

OUT=""
RC=0
DECISION=""
REASON=""

run_hook() { # <command> [cwd] [env NAME=VALUE]
  local cmd="$1" cwd="${2:-$TEST_TMP}" extra_env="${3:-}"
  local json
  json="$(jq -n --arg c "$cmd" --arg d "$cwd" \
    '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d, hook_event_name: "PreToolUse"}')"
  RC=0
  if [ -n "$extra_env" ]; then
    OUT="$(printf '%s' "$json" | env "$extra_env" bash "$TARGET" 2>/dev/null)" || RC=$?
  else
    OUT="$(printf '%s' "$json" | bash "$TARGET" 2>/dev/null)" || RC=$?
  fi
  DECISION="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)"
  REASON="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || true)"
}

assert_fire() { # <label>
  if [ "$RC" -eq 0 ] && [ "$DECISION" = "deny" ]; then
    ok "$1"
  else
    bad "$1: exit=$RC decision=[$DECISION] out=[$OUT]"
  fi
}

assert_pass() { # <label>
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    ok "$1"
  else
    bad "$1: exit=$RC out=[$OUT]"
  fi
}

BODY_MARKER='## Summary
残りはスコープ外なので別対応とする。'
BODY_WITH_REF='## Summary
残りはスコープ外なので別対応とする（#228 で追跡）。'
BODY_NO_FOLLOWUP='## Summary
残りはスコープ外なので別対応とする。
<!-- no-followup: 恒久対応は不要と判断（一時ファイルの掃除のみ） -->'
BODY_PLAIN='## Summary
通常の変更内容の説明。
## Test Plan
テスト手順。'
BODY_URL_REF='## Summary
uploads の PDF は本 PR のスコープ外。別途確認する。
https://github.com/example/repo/issues/228'

echo "guard-pr-followup: AC ケース（発火側）"
run_hook "gh pr create --base develop --title t --body \"$BODY_MARKER\""
assert_fire "AC1: スコープ外あり・Issue 参照なしの gh pr create は警告"
run_hook "gh pr edit 123 --body \"$BODY_MARKER\""
assert_fire "AC5: gh pr edit --body での宣言追記も同じ判定"
HD='gh pr create --base develop --title t --body "$(cat <<'"'"'EOF'"'"'
## Summary
残件は後で対応する。
EOF
)"'
run_hook "$HD"
assert_fire "AC6: heredoc（\$(cat <<EOF)）経由の本文も判定できる"
printf '%s\n' "$BODY_MARKER" > "$TEST_TMP/body-marker.md"
printf '%s\n' "$BODY_WITH_REF" > "$TEST_TMP/body-ref.md"
run_hook "gh pr create --title t --body-file $TEST_TMP/body-marker.md"
assert_fire "AC6: --body-file <path>（マーカーのみ）は警告"
run_hook "gh pr create --title t -F $TEST_TMP/body-marker.md"
assert_fire "AC6: -F <path> 短縮形も判定できる"
run_hook "gh pr create --title t --body-file=$TEST_TMP/body-marker.md"
assert_fire "AC6: --body-file=<path> 形も判定できる"
run_hook "gh pr create --title \"feat: #999 t\" --body \"$BODY_MARKER\""
assert_fire "本文以外（--title）の Issue 参照では判定を抑止しない"
run_hook "gh pr create --title t --body \"残件は後で対応する。<!-- no-followup: -->\""
assert_fire "理由の無い no-followup マーカーでは通らない"

echo "guard-pr-followup: 警告文の契約（対処と抜け道を出力自体に案内する）"
run_hook "gh pr create --title t --body \"$BODY_MARKER\""
case "$REASON" in
  *"gh issue create"*) ok "警告文が gh issue create を先に実行すべきことを案内する" ;;
  *) bad "警告文に gh issue create の案内が無い: [$REASON]" ;;
esac
case "$REASON" in
  *no-followup:*) ok "警告文が no-followup 抜け道を案内する" ;;
  *) bad "警告文に no-followup 抜け道の案内が無い: [$REASON]" ;;
esac
case "$REASON" in
  *スコープ外*) ok "警告文が検出マーカーを名指しする" ;;
  *) bad "警告文に検出マーカーが無い: [$REASON]" ;;
esac

echo "guard-pr-followup: AC ケース（非発火側）"
run_hook "gh pr create --base develop --title t --body \"$BODY_WITH_REF\""
assert_pass "AC2: スコープ外 + #228 は警告しない"
run_hook "gh pr create --base develop --title t --body \"$BODY_NO_FOLLOWUP\""
assert_pass "AC3: <!-- no-followup: 理由 --> 抜け道で通る"
run_hook "gh pr create --base develop --title t --body \"$BODY_PLAIN\""
assert_pass "AC4: マーカーを含まない通常本文は警告しない（誤発火しない）"
run_hook "gh pr create --title t --body \"$BODY_URL_REF\""
assert_pass "Issue URL 参照でも通る"
run_hook "gh pr create --title t --body-file $TEST_TMP/body-ref.md"
assert_pass "--body-file（参照あり）は警告しない"

echo "guard-pr-followup: 既知の限界と対象外（素通し）"
run_hook 'cat body.md | gh pr create --title t --body-file -'
assert_pass "--body-file -（stdin）は判定できず素通し（既知の限界）"
run_hook 'gh pr create --fill'
assert_pass "--fill（body フラグなし）は判定できず素通し（既知の限界）"
run_hook 'gh pr view 123'
assert_pass "gh pr view は対象外"
run_hook 'gh issue create --title t --body "スコープ外"'
assert_pass "gh issue create は対象外"
run_hook "echo 'gh pr create --body スコープ外 --title t'"
assert_pass "コマンド位置に無い gh（echo の文字列）は素通し"
run_hook "gh pr create --title t --body \"$BODY_MARKER\"" "$TEST_TMP" 'FF_DEV_TOOLKIT_SKIP_PR_FOLLOWUP_GUARD=1'
assert_pass "FF_DEV_TOOLKIT_SKIP_PR_FOLLOWUP_GUARD=1 で無効化できる"

echo "guard-pr-followup: fail-open"
RC=0
OUT="$(printf 'not-json' | bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "壊れた stdin JSON は無出力 exit 0"
else
  bad "壊れた stdin JSON: exit=$RC out=[$OUT]"
fi

echo "guard-pr-followup: hooks.json 登録の静的照合"
if jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]
    | select(.command | contains("guard-pr-followup.sh"))' "$HOOKS_JSON" >/dev/null 2>&1; then
  ok "hooks.json の PreToolUse（Bash matcher）に登録されている"
else
  bad "hooks.json の PreToolUse（Bash matcher）に guard-pr-followup.sh が無い"
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ guard-pr-followup: ${FAIL} 件失敗（成功 ${PASS} 件）" >&2
  REACHED_END=1
  exit 1
fi
echo "✅ guard-pr-followup: all ${PASS} checks passed"
REACHED_END=1
exit 0
