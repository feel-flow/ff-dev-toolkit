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
# GitHub MCP 経路（sub_issue_write）も同じ suite で固定する: 実測したツール名を 2 つのサーバー名の形
# （mcp__github__ / mcp__plugin_github_github__）で駆動し、文字列で渡した sub_issue_id / after_id の deny と数値の素通し・hook の環境変数で読む抜け道・
# gh が PATH に無くても判定すること（型は tool_input だけで決まる）・針が当たらない入力（判定表にないツール名・名簿にないサーバー・
# tool_input の欠落 / 型違い）を素通しではなく理由付きの systemMessage にすること・hooks.json の MCP matcher を
# Claude Code と同じアンカー無し正規表現として照合すること（tests/lib/github-mcp-fixture.sh）。
# 空振り検出: MCP の振り分け（`*mcp__*` の case）を無効にすると MCP 入力が素通しへ倒れて 18 件が赤、サーバー名簿からプラグイン同梱の形を落とすと 5 件が赤、jq 不在の通知を無音にすると 1 件が赤（2026-10-19 実測）。
# 変異検出: 文字列型の判定を外すと 10 件、hooks.json の matcher から末尾の `$` を外すと近い名前（sub_issue_writes）に当たって 2 件、matcher の server 区間に名簿にない候補を足すと 1 件、通知から additionalContext を外すと 6 件、gh を外す fixture が bash を残さないと Linux 配置の再現で 1 件が赤（2026-10-19 実測）。
#
# run-all-required: no — jq 不在での skip を許容する（一時領域依存 suite の必須判断で名簿へ載せなかった側）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$PLUGIN_ROOT/hooks/guard-sub-issue-id.sh"
# ホスト環境の解除変数・テストシーム（hook 実装とその参照先が読む FF_* / CLAUDE_*）を
# 先頭で 1 回落とす。ケース固有の `NAME=v bash "$TARGET"` はこの後に代入として届く（Issue `#1808`）。
# shellcheck source=../lib/adapter-env-isolation.sh
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"
isolate_hook_env "FF_DEV_TOOLKIT_SKIP_SUB_ISSUE_ID_GUARD" "$TARGET"
# shellcheck source=../lib/asdd-gate-drain.sh
. "$SCRIPT_DIR/../lib/asdd-gate-drain.sh"
# shellcheck source=../lib/github-mcp-fixture.sh
. "$SCRIPT_DIR/../lib/github-mcp-fixture.sh"
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

echo "guard-sub-issue-id: GitHub MCP 経路（sub_issue_write）"
# 実測したツール名（GitHub 公式リモート MCP の tools/list）を 2 つのサーバー名の形で駆動する。
# fixture の cwd は /tmp（`gh` / `-f` を含まない）なので、MCP 分岐を Bash 用の前置フィルタより
# 後ろへ動かすと、下の deny 検査はすべて素通しへ倒れて赤になる。
MESSAGE=""
run_mcp() { ff_mcp_run "$TARGET" "$@"; }
MCP_ADD='{"method":"add","owner":"acme","repo":"widgets","issue_number":10,"sub_issue_id":"5307014088"}'
run_mcp mcp__plugin_github_github__sub_issue_write "$MCP_ADD"
assert_fire "AC3: プラグイン同梱サーバーの sub_issue_write へ sub_issue_id を文字列で渡すと deny"
MCP_REASON="$REASON"
case "$REASON" in
  *'`sub_issue_id`'*'JSON の数値'*) ok "AC3: deny 文がフィールド名と「JSON の数値で渡す（MCP の整数型指定）」を案内する" ;;
  *) bad "AC3: 数値で渡す案内が無い: [$REASON]" ;;
esac
case "$REASON" in
  *'scripts/link-sub-issues.sh'*) ok "AC3: deny 文が link-sub-issues.sh を案内する" ;;
  *) bad "AC3: link-sub-issues.sh の案内が無い: [$REASON]" ;;
esac
case "$REASON" in
  *'hook の環境変数 FF_SUB_ISSUE_ID_ACK=1'*) ok "AC3: 抜け道は同じ変数名を hook の環境変数として案内する（コマンド先頭の環境代入は MCP では付けられない）" ;;
  *) bad "AC3: MCP 経路の抜け道の案内が無い: [$REASON]" ;;
esac
run_hook 'gh api --method POST repos/acme/widgets/issues/10/sub_issues -f sub_issue_id=1'
if [ "${MCP_REASON##*$'\n'}" = "${REASON##*$'\n'}" ] && [ -n "${REASON##*$'\n'}" ]; then
  ok "AC3: ガード無効化の案内行は Bash 経路の deny と同じ文言"
else
  bad "AC3: 末尾の案内行が Bash 経路とずれている: mcp=[${MCP_REASON##*$'\n'}] bash=[${REASON##*$'\n'}]"
fi
run_mcp mcp__github__sub_issue_write "$MCP_ADD"
assert_fire "AC3: 利用者が server キー github で設定したサーバーでも deny"
run_mcp mcp__github__sub_issue_write '{"method":"reprioritize","owner":"acme","repo":"widgets","issue_number":10,"sub_issue_id":5307014088,"after_id":"1"}'
assert_fire "AC3: 同じ API の after_id を文字列で渡しても deny"
case "$REASON" in
  *'`after_id`'*) ok "AC3: deny 文が文字列だったフィールド（after_id）を名指しする" ;;
  *) bad "AC3: after_id を名指ししていない: [$REASON]" ;;
esac
run_mcp mcp__github__sub_issue_write '{"method":"add","owner":"acme","repo":"widgets","issue_number":10,"sub_issue_id":5307014088}'
assert_pass "数値で渡した sub_issue_id は素通し"
run_mcp mcp__github__sub_issue_write '{"method":"reprioritize","owner":"acme","repo":"widgets","issue_number":10,"sub_issue_id":5307014088,"before_id":"2"}'
assert_fire "AC3: 同じ API の before_id を文字列で渡しても deny"
case "$REASON" in
  *'`before_id`'*) ok "AC3: deny 文が文字列だったフィールド（before_id）を名指しする" ;;
  *) bad "AC3: before_id を名指ししていない: [$REASON]" ;;
esac
run_mcp mcp__github__sub_issue_write "$MCP_ADD" FF_SUB_ISSUE_ID_ACK=1
ff_mcp_assert_message "抜け道: hook の環境変数 FF_SUB_ISSUE_ID_ACK=1 で通し、セッション全体に効く抜け道で通したことを毎回知らせる" "FF_SUB_ISSUE_ID_ACK=1"
run_hook 'gh api --method POST repos/acme/widgets/issues/10/sub_issues -f sub_issue_id=1' "$TEST_TMP" 'FF_SUB_ISSUE_ID_ACK=1'
assert_fire "hook の環境変数 FF_SUB_ISSUE_ID_ACK=1 は Bash 経路を通さない（Bash 経路の抜け道はコマンド先頭の環境代入だけ）"
run_mcp mcp__github__sub_issue_write "$MCP_ADD" FF_DEV_TOOLKIT_SKIP_SUB_ISSUE_ID_GUARD=1
assert_pass "FF_DEV_TOOLKIT_SKIP_SUB_ISSUE_ID_GUARD=1 は MCP 経路も止める"
if NOGH_PATH="$(ff_path_without_gh "$TEST_TMP/nogh-bin" jq)"; then
  run_mcp mcp__github__sub_issue_write "$MCP_ADD" PATH="$NOGH_PATH"
  assert_fire "gh が PATH に無くても判定する（型は tool_input だけで決まり、gh を使わない）"
else
  bad "gh だけを外した PATH を作れない（gh が残る・bash が消える）ため、gh 不在の検査が成立しない"
fi
run_mcp mcp__github__sub_issue_write "$MCP_ADD" PATH=/nonexistent
ff_mcp_assert_message "jq が PATH に無ければ、GitHub MCP の呼び出しを検査しなかったことを知らせて通す" "jq が PATH に無い"
# fixture 自身の検査: Linux の CI では gh と bash が同じ /usr/bin にあり /bin もそこを指す。
# その配置を 1 ディレクトリで再現し、gh だけを外して bash は残せることを確かめる（macOS の
# 開発機では gh と bash が別のディレクトリにあるので、この配置を作らないと崩れても緑のまま）
LINUX_BIN="$TEST_TMP/linux-usr-bin"
mkdir -p "$LINUX_BIN"
for c in bash env sh jq mkdir ln; do
  c_path="$(command -v "$c")" && ln -sf "$c_path" "$LINUX_BIN/$c"
done
printf '#!/bin/sh\nexit 0\n' > "$LINUX_BIN/gh"
chmod +x "$LINUX_BIN/gh"
if SIM_PATH="$(PATH="$LINUX_BIN" ff_path_without_gh "$TEST_TMP/linux-shim" jq)" \
  && ! PATH="$SIM_PATH" command -v gh >/dev/null 2>&1 && PATH="$SIM_PATH" command -v bash >/dev/null 2>&1; then
  run_mcp mcp__github__sub_issue_write "$MCP_ADD" PATH="$SIM_PATH"
  assert_fire "fixture: gh と bash が同じディレクトリにだけ在る配置（Linux の CI）でも、gh だけを外した PATH で hook を動かせる"
else
  bad "fixture: gh と bash が同じディレクトリにだけ在る配置で、gh だけを外した PATH を作れない（bash まで消える）"
fi
echo "guard-sub-issue-id: GitHub MCP 経路の針が当たらない入力（素通しではなく理由付きの systemMessage）"
run_mcp mcp__github__sub_issue_writes "$MCP_ADD"
ff_mcp_assert_message "判定表にないツール名（綴りの揺れ）は理由を出して通す" "判定表"
run_mcp mcp__linear__sub_issue_write "$MCP_ADD"
ff_mcp_assert_message "サーバー名が名簿にないツールは理由を出して通す" "判定表"
run_mcp mcp__github__sub_issue_write '{"method":"add","owner":"acme","repo":"widgets","issue_number":10}'
ff_mcp_assert_message "sub_issue_id の欠落は理由を出して通す" "sub_issue_id"
run_mcp mcp__github__sub_issue_write '{"method":"add","owner":"acme","repo":"widgets","issue_number":10,"sub_issue_id":true}'
ff_mcp_assert_message "数値でも文字列でもない sub_issue_id は理由を出して通す" "sub_issue_id"
run_mcp mcp__github__sub_issue_write '"add"'
ff_mcp_assert_message "オブジェクトでない tool_input は理由を出して通す" "sub_issue_id"
run_hook 'gh api --method POST repos/acme/widgets/issues/10/sub_issues -f sub_issue_id=1 # mcp__github__sub_issue_write'
assert_fire "Bash の呼び出しは文字列に mcp__ を含んでも Bash 経路で判定する"
case "$REASON" in
  *'-F '*) ok "Bash 経路の deny 文（-F の案内）のまま" ;;
  *) bad "Bash の呼び出しが MCP 経路の文言になっている: [$REASON]" ;;
esac

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
case "$DESC" in
  *sub_issue_write*) ok "hooks.json の description が GitHub MCP の sub_issue_write に言及する" ;;
  *) bad "hooks.json の description に GitHub MCP 経路（sub_issue_write）の記述が無い" ;;
esac
while IFS= read -r line; do
  case "$line" in
    OK\ *) ok "MCP matcher: ${line#OK }" ;;
    SKIP\ *) echo "  ○ skip: ${line#SKIP }" ;;
    *) bad "MCP matcher: ${line#NG }" ;;
  esac
done <<EOF
$(ff_github_mcp_matcher_check "$HOOKS_JSON" guard-sub-issue-id.sh sub_issue_write)
EOF

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
