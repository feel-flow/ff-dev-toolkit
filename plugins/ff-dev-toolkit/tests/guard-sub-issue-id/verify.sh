#!/usr/bin/env bash
# Runtime contract for the sub-issue integer-field guard hook (OBS-052).
#
# 配布物 hooks/guard-sub-issue-id.sh を stdin JSON で直接駆動し、受け入れ条件の
# 各分岐を固定する:
#   1. コマンド位置の `gh api ... -f sub_issue_id=` は実行前に deny
#   2. `-F sub_issue_id=`（型付き）は素通し
#   3. 同じ API の `-f after_id=` / `-f before_id=` も deny
#   4. 案内された抜け道（FF_SUB_ISSUE_ID_ACK=1 の前置 / skip env）で通る
#   5. GraphQL の `-f query=` や REST の `-f base=<branch>` は数字でもキーが
#      違うので素通し（対象を -f 全般へ広げない判断の固定）
#   6. コマンド位置に無い gh（echo の文字列）は素通し
#   7. deny 文面自体が `-F` / ヘルパ / ACK 抜け道を案内する（ACE-1076-1）
#
# あわせて hooks.json の PreToolUse（Bash matcher）登録を静的照合する。
#
# 変異検出（2026-09-15 実測。赤転しなかった変異は無し）:
#   `is_integer_id_key` の sub_issue_id 分岐を外したコピーは、AC1 の deny が
#   消え、本番と同じ「-f sub_issue_id= は deny」検査を赤にする。
#   deny 理由文から `scripts/link-sub-issues.sh` を消したコピーは、抜け道案内
#   の検査を赤にする。
#
# run-all-required: no — jq 不在での skip を許容する（一時領域依存 suite の必須判断で名簿へ載せなかった側）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$PLUGIN_ROOT/hooks/guard-sub-issue-id.sh"
# shellcheck source=../lib/asdd-gate-drain.sh
. "$SCRIPT_DIR/../lib/asdd-gate-drain.sh"
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"

[ -f "$TARGET" ] || { echo "✗ guard-sub-issue-id.sh が見つかりません: $TARGET" >&2; exit 1; }
[ -f "$HOOKS_JSON" ] || { echo "✗ hooks.json が見つかりません: $HOOKS_JSON" >&2; exit 1; }
if ! command -v jq >/dev/null 2>&1; then
  echo "○ skip: jq が見つからないためスキップ（guard-sub-issue-id は未検査のままです）"
  exit 0
fi

if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/ff-guard-sub-issue.XXXXXX" 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
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
    echo "✗ guard-sub-issue-id: 最後まで到達しませんでした" >&2
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

run_hook_on() { # <hook-file> <command>
  local hook="$1" cmd="$2" json
  json="$(jq -n --arg c "$cmd" --arg d "$TEST_TMP" \
    '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d, hook_event_name: "PreToolUse"}')"
  RC=0
  OUT="$(printf '%s' "$json" | bash "$hook" 2>/dev/null)" || RC=$?
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

echo "guard-sub-issue-id: AC ケース（発火側）"
run_hook 'gh api --method POST repos/acme/widgets/issues/10/sub_issues -f sub_issue_id=5307014088'
assert_fire "AC1: -f sub_issue_id= の gh api は実行前に deny"
run_hook 'gh api -X POST repos/acme/widgets/issues/10/sub_issues -f sub_issue_id=$id'
assert_fire "値が変数でも -f sub_issue_id= なら deny（フラグの型が問題）"
run_hook 'gh api repos/acme/widgets/issues/10/sub_issues/priority -f after_id=1'
assert_fire "同じ API の -f after_id= も deny"
run_hook 'gh api repos/acme/widgets/issues/10/sub_issues/priority -f before_id=2'
assert_fire "同じ API の -f before_id= も deny"
run_hook 'gh api --method POST repos/acme/widgets/issues/10/sub_issues --raw-field sub_issue_id=5307014088'
assert_fire "--raw-field sub_issue_id= も -f と同じ（文字列送信）"

echo "guard-sub-issue-id: OBS-052 の実形（ループ / コマンド置換 / && の 2 本目）"
run_hook 'for c in 21 22; do gh api --method POST repos/acme/widgets/issues/10/sub_issues -f sub_issue_id=$c; done'
assert_fire "ループ本体の do gh api -f sub_issue_id= は deny"
run_hook 'out=$(gh api --method POST repos/acme/widgets/issues/10/sub_issues -f sub_issue_id=1 2>&1)'
assert_fire 'コマンド置換 out=$(gh api -f sub_issue_id=) は deny'
run_hook 'gh api repos/acme/widgets/issues -f per_page=30 && gh api --method POST repos/acme/widgets/issues/10/sub_issues -f sub_issue_id=1'
assert_fire "先行 gh api があっても 2 本目の -f sub_issue_id= は deny"
run_hook 'FF_SUB_ISSUE_ID_ACK=1 gh api repos/acme/widgets/issues -f per_page=30 && gh api --method POST repos/acme/widgets/issues/10/sub_issues -f sub_issue_id=1'
assert_fire "先行セグメントの ACK は 2 本目の -f sub_issue_id= を許可しない"
run_hook 'if gh api --method POST repos/acme/widgets/issues/10/sub_issues -f sub_issue_id=1; then :; fi'
assert_fire "if gh api -f sub_issue_id= は deny"
run_hook 'while gh api --method POST repos/acme/widgets/issues/10/sub_issues -f sub_issue_id=1; do break; done'
assert_fire "while gh api -f sub_issue_id= は deny"
run_hook 'gh api --method POST repos/acme/widgets/issues/10/sub_issues \
  -f sub_issue_id=1'
assert_fire '行末 \ 継続の次行 -f sub_issue_id= は deny'
run_hook 'gh api --method POST repos/acme/widgets/issues/10/sub_issues --raw-field="sub_issue_id=1"'
assert_fire '--raw-field="sub_issue_id=" 連結引用も deny'
run_hook 'gh api --method POST repos/acme/widgets/issues/10/sub_issues -f"sub_issue_id=1"'
assert_fire '-f"sub_issue_id=" 連結引用も deny'

echo "guard-sub-issue-id: 警告文の契約（対処と抜け道を出力自体に案内する）"
run_hook 'gh api --method POST repos/acme/widgets/issues/10/sub_issues -f sub_issue_id=1'
case "$REASON" in
  *'-F '*) ok "警告文が -F への直し方を案内する" ;;
  *) bad "警告文に -F の案内が無い: [$REASON]" ;;
esac
case "$REASON" in
  *'scripts/link-sub-issues.sh'*) ok "警告文がヘルパ scripts/link-sub-issues.sh を案内する" ;;
  *) bad "警告文にヘルパの案内が無い: [$REASON]" ;;
esac
case "$REASON" in
  *FF_SUB_ISSUE_ID_ACK=1*) ok "警告文が ACK 抜け道を案内する" ;;
  *) bad "警告文に ACK 抜け道の案内が無い: [$REASON]" ;;
esac
case "$REASON" in
  *FF_DEV_TOOLKIT_SKIP_SUB_ISSUE_ID_GUARD=1*) ok "警告文がガード無効化 env を案内する" ;;
  *) bad "警告文に skip env の案内が無い: [$REASON]" ;;
esac

echo "guard-sub-issue-id: AC ケース（非発火側）"
run_hook 'gh api --method POST repos/acme/widgets/issues/10/sub_issues -F sub_issue_id=5307014088'
assert_pass "AC: -F sub_issue_id=（型付き）は素通し"
run_hook "gh api graphql -f query='query { viewer { login } }'"
assert_pass "GraphQL の -f query= は文字列フィールドなので素通し"
run_hook 'gh api -X PATCH repos/acme/widgets/pulls/12 -f base=develop'
assert_pass "REST の -f base=<branch> は文字列フィールドなので素通し"
run_hook 'gh api repos/acme/widgets/issues -f per_page=30 -f state=open'
assert_pass "-f per_page=<数字> は対象キーではないので素通し（-f 全般へ広げない）"
run_hook "echo 'gh api --method POST repos/acme/widgets/issues/10/sub_issues -f sub_issue_id=1'"
assert_pass "コマンド位置に無い gh（echo の文字列）は素通し"
run_hook "gh api graphql -f query='foo && -f sub_issue_id=1'"
assert_pass "引用符内の && と -f sub_issue_id= はコマンド位置ではないので素通し"
run_hook 'gh issue create --title t --body b'
assert_pass "gh issue create は対象外"
run_hook 'FF_SUB_ISSUE_ID_ACK=1 gh api --method POST repos/acme/widgets/issues/10/sub_issues -f sub_issue_id=1'
assert_pass "コマンド先頭の FF_SUB_ISSUE_ID_ACK=1 で通る"
run_hook 'gh api --method POST repos/acme/widgets/issues/10/sub_issues -f sub_issue_id=1' "$TEST_TMP" 'FF_DEV_TOOLKIT_SKIP_SUB_ISSUE_ID_GUARD=1'
assert_pass "FF_DEV_TOOLKIT_SKIP_SUB_ISSUE_ID_GUARD=1 で無効化できる"
run_hook 'echo FF_SUB_ISSUE_ID_ACK=1; gh api --method POST repos/acme/widgets/issues/10/sub_issues -f sub_issue_id=1'
assert_fire "ACK が別コマンドに居るだけでは無効（gh api の直前だけ）"

echo "guard-sub-issue-id: fail-open"
RC=0
OUT="$(printf 'not-json' | bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "壊れた stdin JSON は無出力 exit 0"
else
  bad "壊れた stdin JSON: exit=$RC out=[$OUT]"
fi

echo "guard-sub-issue-id: stdin の drain（fail-open でも書き手に EPIPE を返さない）"
BIG_PAYLOAD="$(jq -n '{tool_name: "Bash", tool_input: {command: "echo ok"}, cwd: "/tmp"}')$(printf '%*s' 200000 '')"
RC=0
OUT="$(printf '%s' "$BIG_PAYLOAD" | PATH="/nonexistent" /bin/bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "PATH 空の環境でも stdin を読み切ってから無出力 exit 0"
else
  bad "PATH 空の drain: exit=$RC out=[$OUT]（rc=141 なら hook が stdin を drain せずに exit している）"
fi
RC=0
OUT="$(printf '%s' "$BIG_PAYLOAD" | FF_DEV_TOOLKIT_SKIP_SUB_ISSUE_ID_GUARD=1 PATH="/nonexistent" /bin/bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "opt-out でも stdin を読み切ってから無出力 exit 0"
else
  bad "opt-out の drain: exit=$RC out=[$OUT]"
fi

echo "guard-sub-issue-id: hooks.json 登録の静的照合"
if jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]
    | select(.command | contains("guard-sub-issue-id.sh"))' "$HOOKS_JSON" >/dev/null 2>&1; then
  ok "hooks.json の PreToolUse（Bash matcher）に登録されている"
else
  bad "hooks.json の PreToolUse（Bash matcher）に guard-sub-issue-id.sh が無い"
fi
DESC="$(jq -r '.description' "$HOOKS_JSON")"
case "$DESC" in
  *sub_issue_id*) ok "hooks.json の description が sub_issue_id ガードに言及する" ;;
  *) bad "hooks.json の description に sub_issue_id の記述が無い" ;;
esac

echo "guard-sub-issue-id: ASDD ゲートの早期終了経路でも stdin を読み切る"
ASDD_ON="$TEST_TMP/asdd-hooks-on"
ASDD_OFF="$TEST_TMP/asdd-hooks-off"
mkdir -p "$ASDD_ON" "$ASDD_OFF"
ff_asdd_fixture "$ASDD_ON" true
ff_asdd_fixture "$ASDD_OFF" false
ASDD_PAYLOAD="$(ff_asdd_big_payload '{"tool_name":"Bash","tool_input":{"command":"echo ok"},"cwd":"/tmp","hook_event_name":"PreToolUse"}')"
ff_asdd_drain_probe "$TARGET" "$ASDD_PAYLOAD" "$ASDD_ON" PATH=/nonexistent
if [ "$FF_ASDD_DRAIN_RC" -eq 0 ] && [ -z "$FF_ASDD_DRAIN_OUT" ]; then
  ok ".asdd 設定あり + node 不在（ゲートが停止）でも stdin を読み切ってから無出力 exit 0"
else
  bad "ASDD ゲート（node 不在）の drain: exit=$FF_ASDD_DRAIN_RC out=[$FF_ASDD_DRAIN_OUT]"
fi
if command -v node >/dev/null 2>&1; then
  ff_asdd_drain_probe "$TARGET" "$ASDD_PAYLOAD" "$ASDD_OFF"
  if [ "$FF_ASDD_DRAIN_RC" -eq 0 ] && [ -z "$FF_ASDD_DRAIN_OUT" ]; then
    ok "features.hooks=false（ゲートが無効と判定）でも stdin を読み切ってから無出力 exit 0"
  else
    bad "ASDD ゲート（feature 無効）の drain: exit=$FF_ASDD_DRAIN_RC out=[$FF_ASDD_DRAIN_OUT]"
  fi
else
  echo "  ○ skip: node が無いため features.hooks=false 経路は未検査（guard-sub-issue-id の ASDD ゲート無効判定）"
fi

echo "guard-sub-issue-id: 変異検出（コピーへ当て、本番検査と同形の針が赤になること）"
# コピーは asdd-hook-gate.sh を同じ directory から source するので、ゲート実体も隣へ置く。
cp "$PLUGIN_ROOT/hooks/asdd-hook-gate.sh" "$TEST_TMP/"
cp "$PLUGIN_ROOT/hooks/asdd-feature.mjs" "$TEST_TMP/"
MUT="$TEST_TMP/guard-sub-issue-id.sh"
# 変異 1: sub_issue_id を判定キーから外す
sed 's/sub_issue_id|after_id|before_id/after_id|before_id/' "$TARGET" > "$MUT"
run_hook_on "$MUT" 'gh api --method POST repos/acme/widgets/issues/10/sub_issues -f sub_issue_id=1'
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "変異検出: is_integer_id_key から sub_issue_id を外すと AC1 が素通しになり、deny 検査は赤になる"
else
  bad "sub_issue_id 除外の変異が deny のまま: decision=[$DECISION] out=[$OUT]"
fi
# after_id は残しているので、そちらはまだ deny する
run_hook_on "$MUT" 'gh api repos/acme/widgets/issues/10/sub_issues/priority -f after_id=1'
if [ "$RC" -eq 0 ] && [ "$DECISION" = "deny" ]; then
  ok "変異検出: after_id 分岐は残る（1 キーだけの欠落であり全面無効化ではない）"
else
  bad "after_id まで消えている: decision=[$DECISION]"
fi

# 変異 2: ヘルパ案内を理由文から消す
sed '/scripts\/link-sub-issues.sh/d' "$TARGET" > "$MUT"
run_hook_on "$MUT" 'gh api --method POST repos/acme/widgets/issues/10/sub_issues -f sub_issue_id=1'
case "$REASON" in
  *'scripts/link-sub-issues.sh'*)
    bad "ヘルパ案内削除の変異が効いていない: [$REASON]"
    ;;
  *)
    if [ "$DECISION" = "deny" ]; then
      ok "変異検出: 理由文からヘルパ案内を消すと抜け道案内の検査は赤になる（deny 自体は残る）"
    else
      bad "ヘルパ案内削除で deny まで消えた: decision=[$DECISION]"
    fi
    ;;
esac

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ guard-sub-issue-id: ${FAIL} 件失敗（成功 ${PASS} 件）" >&2
  REACHED_END=1
  exit 1
fi
echo "✅ guard-sub-issue-id: all ${PASS} checks passed"
REACHED_END=1
exit 0
