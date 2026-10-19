#!/usr/bin/env bash
# Runtime contract for the PR follow-up declaration guard hook (Issue #771).
#
# 空振り検出: 対象 hook 不在は赤。見出し除外を外した変異で見出し除外の 4 ケースが赤、本文宣言は deny を維持する。
# 変異検出: 見出し除外を外す変異で見出し除外の 4 ケースが赤（実測）。境界を緩める変異も回帰検査で検出する。
# 配布物 hooks/guard-pr-followup.sh を stdin JSON で直接駆動し、Issue #771 の AC
# 各ケース（マーカーあり参照なし→警告 / 参照あり→非警告 / no-followup 抜け道 /
# 通常本文 / gh pr edit / --body-file・heredoc 経由 / 既知の限界の素通し）を固定する。
# 警告文自体が抜け道（no-followup マーカー）と gh issue create を案内する契約も検査し、
# hooks.json の PreToolUse 登録を静的照合する。
#
# GitHub MCP 経路（create_pull_request / update_pull_request）も同じ suite で固定する: 実測したツール名を 2 つのサーバー名の形
# （mcp__github__ / mcp__plugin_github_github__）で駆動し、draft: true の deny（作成・Draft への戻し）と body のフォローアップ宣言の判定（Bash 経路と同一の deny 文）・hook の環境変数で読む抜け道・
# gh が PATH に無くても判定すること・針が当たらない入力（判定表にないツール名・名簿にないサーバー・
# tool_input の欠落 / 型違い）を素通しではなく理由付きの systemMessage にすること・hooks.json の MCP matcher を
# Claude Code と同じアンカー無し正規表現として照合すること（tests/lib/github-mcp-fixture.sh）。
# 空振り検出: MCP の振り分け（`*mcp__*` の case）を無効にすると MCP 入力が素通しへ倒れて 19 件が赤（2026-10-19 実測）。
# 変異検出: draft: true の判定を常に偽にすると 8 件（2026-10-18 実測）、抜け道で通した通知を無音にすると 1 件が赤（2026-10-19 実測）。
#
# run-all-required: no — jq 不在での skip を許容する（一時領域依存 suite の必須判断で名簿へ載せなかった側）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$PLUGIN_ROOT/hooks/guard-pr-followup.sh"
# ホスト環境の解除変数・テストシーム（hook 実装とその参照先が読む FF_* / CLAUDE_*）を
# 先頭で 1 回落とす。ケース固有の `NAME=v bash "$TARGET"` はこの後に代入として届く（Issue `#1808`）。
# shellcheck source=../lib/adapter-env-isolation.sh
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"
isolate_hook_env "FF_DEV_TOOLKIT_SKIP_PR_FOLLOWUP_GUARD" "$TARGET"
# ASDD ゲートが早期終了する経路でも stdin を読み切ることを測る共有ヘルパー
# shellcheck source=../lib/asdd-gate-drain.sh
. "$SCRIPT_DIR/../lib/asdd-gate-drain.sh"
# shellcheck source=../lib/github-mcp-fixture.sh
. "$SCRIPT_DIR/../lib/github-mcp-fixture.sh"
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"

[ -f "$TARGET" ] || { echo "✗ guard-pr-followup.sh が見つかりません: $TARGET" >&2; exit 1; }
[ -f "$HOOKS_JSON" ] || { echo "✗ hooks.json が見つかりません: $HOOKS_JSON" >&2; exit 1; }
if ! command -v jq >/dev/null 2>&1; then
  echo "○ skip: jq が見つからないためスキップ（guard-pr-followup は未検査のままです）"
  exit 0
fi

# rc=0 でも -d を検査する — 2>&1 の合流は「成功 + stderr 警告」の環境で変数へ
# 警告文が混入し、以後の処理が原因不明の失敗に化けるため。
if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/ff-guard-pr.XXXXXX" 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
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


# 見出しは欄の名前で、本文の宣言とは区別する。参照は見出し内でも有効。
for body in '## スコープ外のインライン修正
- なし' '  ### スコープ外のインライン修正
- 同じ PR で表記を修正' '###### Follow-up
なし'; do
  printf '%s\n' "$body" > "$TEST_TMP/headings.md"
  run_hook "gh pr edit 1 --body-file '$TEST_TMP/headings.md'"
  assert_pass '見出しだけの検出語はフォローアップ宣言に数えない'
done
printf '%s\n' '## スコープ外のインライン修正' 'スコープ外の件は別 Issue で対応' > "$TEST_TMP/headings.md"
run_hook "gh pr edit 1 --body-file '$TEST_TMP/headings.md'"
assert_fire '見出し下の本物の宣言に参照が無ければ止める'
printf '%s\n' '## 参照 `#123`' 'スコープ外の件は別 Issue で対応' > "$TEST_TMP/headings.md"
run_hook "gh pr edit 1 --body-file '$TEST_TMP/headings.md'"
assert_pass '見出し内の Issue 参照も有効に保つ'


# ATX 見出しでない境界は、本文の宣言として検査する。
for body in '    ## スコープ外の件は別対応' '#スコープ外は別対応' '####### follow-up は別対応'; do
  printf '%s\n' "$body" > "$TEST_TMP/heading-boundaries.md"
  run_hook "gh pr edit 1 --body-file '$TEST_TMP/heading-boundaries.md'"
  assert_fire '見出し対象外の字下げ・空白無し・7個の # は宣言に残す'
done
# 見出し全体を欄名と扱う契約なので、見出し自身に宣言を書いた形も除外される。
printf '%s\n' '### Follow-up: 残りは後で対応' > "$TEST_TMP/heading-boundaries.md"
run_hook "gh pr edit 1 --body-file '$TEST_TMP/heading-boundaries.md'"
assert_pass '見出し自身の宣言も除外する契約を固定する'

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

echo "guard-pr-followup: Draft PR（作成・Draft への戻し）"
run_hook "gh pr create --draft --base develop --title t --body \"$BODY_PLAIN\""
assert_fire "gh pr create --draft（本文は通常）→ Draft として止める"
case "$REASON" in
  *"Draft PR"*FF_PR_DRAFT_ACK=1*"gh pr ready"*) ok "Draft の警告文が契約・抜け道・gh pr ready を案内する" ;;
  *) bad "Draft の警告文に契約・抜け道・gh pr ready の案内が揃わない: [$REASON]" ;;
esac
run_hook 'gh pr create -d --fill'
assert_fire "gh pr create -d（body フラグなし）→ 本文の有無に関係なく止める"
run_hook 'gh pr create --draft=true --fill'
assert_fire "gh pr create --draft=true → 止める"
run_hook 'gh pr ready 12 --undo'
assert_fire "gh pr ready --undo（通常 PR を Draft へ戻す）→ 止める"
run_hook 'env GH_HOST=github.com gh pr create --draft --fill'
assert_fire "env ラッパー越しの gh pr create --draft → 止める"
run_hook 'FF_PR_DRAFT_ACK=1 gh pr create --draft --fill'
assert_pass "先頭の FF_PR_DRAFT_ACK=1 で Draft の検出だけを通す"
run_hook "FF_PR_DRAFT_ACK=1 gh pr create --draft --title t --body \"$BODY_MARKER\""
assert_fire "FF_PR_DRAFT_ACK=1 でもフォローアップ宣言の判定は残る"
run_hook 'gh pr ready 12'
assert_pass "gh pr ready（Draft の解除）は止めない"
run_hook 'gh pr ready 12 && gh pr create --draft --fill'
assert_fire "素の gh pr ready の後段の gh pr create --draft も検査する（最初のセグメントで判定を終えない）"
run_hook "gh pr ready 12 && gh pr create --title t --body \"$BODY_MARKER\""
assert_fire "素の gh pr ready の後段のフォローアップ宣言も検査する"
run_hook 'gh pr create --draft --title "FF_PR_DRAFT_ACK=1" --fill'
assert_fire "引数の中の FF_PR_DRAFT_ACK=1 では Draft を通さない（gh より前の環境代入だけが抜け道）"
run_hook 'env FF_PR_DRAFT_ACK=1 gh pr create --draft --fill'
assert_pass "env ラッパーの環境代入 FF_PR_DRAFT_ACK=1 は抜け道として通す"
run_hook "echo 'gh pr create --draft --fill'"
assert_pass "コマンド位置に無い Draft（echo の文字列）は素通し"
run_hook 'gh pr create --fill' "$TEST_TMP" 'FF_DEV_TOOLKIT_SKIP_PR_FOLLOWUP_GUARD=1'
assert_pass "（対照）無効化した状態の通常 PR は素通し"
run_hook 'gh pr create --draft --fill' "$TEST_TMP" 'FF_DEV_TOOLKIT_SKIP_PR_FOLLOWUP_GUARD=1'
assert_pass "FF_DEV_TOOLKIT_SKIP_PR_FOLLOWUP_GUARD=1 は Draft の検出も止める"

echo "guard-pr-followup: GitHub MCP 経路（create_pull_request / update_pull_request）"
# 実測したツール名（GitHub 公式リモート MCP の tools/list）を 2 つのサーバー名の形で駆動する。
# fixture の cwd は /tmp（`gh` を含まない）なので、MCP 分岐を Bash 用の前置フィルタ（*gh*）より
# 後ろへ動かすと、下の deny 検査はすべて素通しへ倒れて赤になる。
MESSAGE=""
run_mcp() { ff_mcp_run "$TARGET" "$@"; }
mcp_pr_input() { # <追加フィールドの JSON オブジェクト>
  jq -cn --argjson x "$1" '{owner: "acme", repo: "widgets", title: "t", head: "feature/x", base: "develop"} + $x'
}
run_mcp mcp__plugin_github_github__create_pull_request "$(mcp_pr_input '{"draft":true}')"
assert_fire "コメント追記の AC: プラグイン同梱サーバーの create_pull_request で draft: true は deny"
MCP_REASON="$REASON"
case "$REASON" in
  *'create_pull_request（draft: true）'*'hook の環境変数 FF_PR_DRAFT_ACK=1'*) ok "deny 文が対象（draft: true）と、同じ変数名の抜け道を hook の環境変数として案内する" ;;
  *) bad "MCP 経路の Draft の deny 文に対象・抜け道の案内が揃わない: [$REASON]" ;;
esac
run_hook "gh pr create --draft --base develop --title t --body \"$BODY_PLAIN\""
# 1 行目の対象表示と 2 つの選択肢だけが経路で違い、契約の説明・末尾の案内は同じ文言
mcp_head="${MCP_REASON%%$'\n'*}"
bash_head="${REASON%%$'\n'*}"
if [ "${mcp_head#*\` }" = "${bash_head#*\` }" ] && [ "${MCP_REASON#*$'\n  2) '*$'\n'}" = "${REASON#*$'\n  2) '*$'\n'}" ]; then
  ok "Draft の deny 文は Bash 経路と同じ文言（対象の表示と選択肢 1・2 以外）"
else
  bad "Draft の deny 文が Bash 経路とずれている: mcp=[$MCP_REASON] bash=[$REASON]"
fi
run_mcp mcp__github__create_pull_request "$(mcp_pr_input '{"draft":true}')"
assert_fire "server キー github で設定したサーバーの create_pull_request でも draft: true は deny"
run_mcp mcp__github__create_pull_request "$(mcp_pr_input '{"draft":"true"}')"
assert_fire "draft を文字列 \"true\" で渡しても deny"
run_mcp mcp__github__update_pull_request '{"owner":"acme","repo":"widgets","pullNumber":12,"draft":true}'
assert_fire "update_pull_request の draft: true（gh pr ready --undo 相当）は deny"
case "$REASON" in
  *'update_pull_request（draft: true）'*) ok "deny 文が update_pull_request を名指しする" ;;
  *) bad "update_pull_request の名指しが無い: [$REASON]" ;;
esac
run_mcp mcp__github__update_pull_request '{"owner":"acme","repo":"widgets","pullNumber":12,"draft":false}'
assert_pass "update_pull_request の draft: false（Draft の解除）は止めない"
run_mcp mcp__github__create_pull_request "$(mcp_pr_input '{}')"
assert_pass "draft も body も無い create_pull_request は素通し"
run_mcp mcp__github__create_pull_request "$(mcp_pr_input '{"draft":true}')" FF_PR_DRAFT_ACK=1
ff_mcp_assert_message "抜け道: hook の環境変数 FF_PR_DRAFT_ACK=1 で Draft の検出だけを通し、セッション全体に効く抜け道で通したことを毎回知らせる" "FF_PR_DRAFT_ACK=1"
run_mcp mcp__github__create_pull_request "$(mcp_pr_input "$(jq -cn --arg b "$BODY_MARKER" '{draft: true, body: $b}')")" FF_PR_DRAFT_ACK=1
assert_fire "FF_PR_DRAFT_ACK=1 でも本文のフォローアップ宣言の判定は残る"
if [ "$(printf '%s' "$OUT" | jq -s 'length' 2>/dev/null)" = "1" ]; then
  ok "抜け道の通知と deny を同時に出さない（hook の出力は JSON 1 つ）"
else
  bad "hook の出力が JSON 1 つでない（ホストが読めない）: [$OUT]"
fi
run_hook 'gh pr create --draft --fill' "$TEST_TMP" 'FF_PR_DRAFT_ACK=1'
assert_fire "hook の環境変数 FF_PR_DRAFT_ACK=1 は Bash 経路を通さない（Bash 経路の抜け道はコマンド先頭の環境代入だけ）"
run_mcp mcp__github__create_pull_request "$(mcp_pr_input '{"draft":true}')" FF_DEV_TOOLKIT_SKIP_PR_FOLLOWUP_GUARD=1
assert_pass "FF_DEV_TOOLKIT_SKIP_PR_FOLLOWUP_GUARD=1 は MCP 経路も止める"
if NOGH_PATH="$(ff_path_without_gh "$TEST_TMP/nogh-bin" jq grep sed)"; then
  run_mcp mcp__github__create_pull_request "$(mcp_pr_input '{"draft":true}')" PATH="$NOGH_PATH"
  assert_fire "gh が PATH に無くても Draft を判定する（tool_input だけで決まり、gh を使わない）"
else
  bad "gh だけを外した PATH を作れない（gh が残る・bash が消える）ため、gh 不在の検査が成立しない"
fi
mcp_body_input() { jq -cn --arg b "$1" '{owner: "acme", repo: "widgets", title: "t", head: "feature/x", base: "develop", body: $b}'; }
run_mcp mcp__github__create_pull_request "$(mcp_body_input "$BODY_MARKER")"
assert_fire "body のフォローアップ宣言（Issue 参照なし）は Bash 経路と同じく deny"
MCP_REASON="$REASON"
run_hook "gh pr create --title t --body \"$BODY_MARKER\""
if [ -n "$REASON" ] && [ "$MCP_REASON" = "$REASON" ]; then
  ok "フォローアップ宣言の deny 文は Bash 経路と同一"
else
  bad "フォローアップ宣言の deny 文が Bash 経路と違う: mcp=[$MCP_REASON] bash=[$REASON]"
fi
run_mcp mcp__github__update_pull_request "$(jq -cn --arg b "$BODY_MARKER" '{owner: "acme", repo: "widgets", pullNumber: 12, body: $b}')"
assert_fire "update_pull_request の body（gh pr edit 相当）にも同じ判定を当てる"
run_mcp mcp__github__create_pull_request "$(mcp_body_input "$BODY_WITH_REF")"
assert_pass "body に Issue 参照があれば素通し"
run_mcp mcp__github__create_pull_request "$(mcp_body_input "$BODY_NO_FOLLOWUP")"
assert_pass "body の no-followup マーカーで通る"
run_mcp mcp__github__create_pull_request "$(mcp_body_input "$BODY_PLAIN")"
assert_pass "通常の body は素通し"
echo "guard-pr-followup: GitHub MCP 経路の針が当たらない入力（素通しではなく理由付きの systemMessage）"
run_mcp mcp__github__create_pull_requests "$(mcp_pr_input '{"draft":true}')"
ff_mcp_assert_message "判定表にないツール名（綴りの揺れ）は理由を出して通す" "判定表"
run_mcp mcp__linear__create_pull_request "$(mcp_pr_input '{"draft":true}')"
ff_mcp_assert_message "サーバー名が名簿にないツールは理由を出して通す" "判定表"
run_mcp mcp__github__create_pull_request '"draft"'
ff_mcp_assert_message "オブジェクトでない tool_input は理由を出して通す" "オブジェクト"
run_mcp mcp__github__create_pull_request "$(mcp_pr_input '{"body":123}')"
ff_mcp_assert_message "文字列でない body は理由を出して通す" "文字列でない"
run_mcp mcp__github__create_pull_request "$(mcp_pr_input '{"draft":true}')" PATH=/nonexistent
ff_mcp_assert_message "jq が PATH に無ければ、GitHub MCP の呼び出しを検査しなかったことを知らせて通す" "jq が PATH に無い"
run_hook 'gh pr create --draft --fill # mcp__github__create_pull_request'
assert_fire "Bash の呼び出しは文字列に mcp__ を含んでも Bash 経路で判定する"
case "$REASON" in
  *'`gh pr create --draft`'*) ok "Bash 経路の deny 文（gh pr create --draft の名指し）のまま" ;;
  *) bad "Bash の呼び出しが MCP 経路の文言になっている: [$REASON]" ;;
esac

echo "guard-pr-followup: fail-open"
RC=0
OUT="$(printf 'not-json' | bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "壊れた stdin JSON は無出力 exit 0"
else
  bad "壊れた stdin JSON: exit=$RC out=[$OUT]"
fi

echo "guard-pr-followup: stdin の drain（fail-open でも書き手に EPIPE を返さない）"
# PATH 空の環境では外部コマンド（cat 含む）が無い。hook が stdin を読まずに exit すると
# 書き手（printf / 実運用ではホスト）が SIGPIPE を受け、pipefail 下では rc=141 が観測される
# （Issue #1329）。payload をパイプバッファ（64 KiB）より大きくして drain 漏れを OS に
# 依らず決定的に検出する（末尾の空白は JSON として有効）。
BIG_PAYLOAD="$(jq -n '{tool_name: "Bash", tool_input: {command: "echo ok"}, cwd: "/tmp"}')$(printf '%*s' 200000 '')"
RC=0
OUT="$(printf '%s' "$BIG_PAYLOAD" | PATH="/nonexistent" /bin/bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "PATH 空の環境でも stdin を読み切ってから無出力 exit 0"
else
  bad "PATH 空の drain: exit=$RC out=[$OUT]（rc=141 なら hook が stdin を drain せずに exit している）"
fi
RC=0
OUT="$(printf '%s' "$BIG_PAYLOAD" | FF_DEV_TOOLKIT_SKIP_PR_FOLLOWUP_GUARD=1 PATH="/nonexistent" /bin/bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "opt-out（FF_DEV_TOOLKIT_SKIP_PR_FOLLOWUP_GUARD=1）でも stdin を読み切ってから無出力 exit 0"
else
  bad "opt-out の drain: exit=$RC out=[$OUT]（rc=141 なら opt-out の早期 exit が read より前にある）"
fi

echo "guard-pr-followup: hooks.json 登録の静的照合"
if jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]
    | select(.command | contains("guard-pr-followup.sh"))' "$HOOKS_JSON" >/dev/null 2>&1; then
  ok "hooks.json の PreToolUse（Bash matcher）に登録されている"
else
  bad "hooks.json の PreToolUse（Bash matcher）に guard-pr-followup.sh が無い"
fi
case "$(jq -r '.description' "$HOOKS_JSON")" in
  *create_pull_request*update_pull_request*) ok "hooks.json の description が GitHub MCP の create_pull_request / update_pull_request に言及する" ;;
  *) bad "hooks.json の description に GitHub MCP 経路（create_pull_request / update_pull_request）の記述が無い" ;;
esac
while IFS= read -r line; do
  case "$line" in
    OK\ *) ok "MCP matcher: ${line#OK }" ;;
    SKIP\ *) echo "  ○ skip: ${line#SKIP }" ;;
    *) bad "MCP matcher: ${line#NG }" ;;
  esac
done <<EOF
$(ff_github_mcp_matcher_check "$HOOKS_JSON" guard-pr-followup.sh create_pull_request update_pull_request)
EOF

echo "guard-pr-followup: ASDD ゲートの早期終了経路でも stdin を読み切る"
# 任意 Hook を止めるゲート（hooks/asdd-hook-gate.sh）は stdin を消費しない設計なので、
# 前置きが drain より前にあると「読まずに exit 0」する経路ができ、書き手がその場で
# EPIPE / SIGPIPE を受ける。ゲートが停止する 2 経路を fixture で作って固定する。
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
  bad "ASDD ゲート（node 不在）の drain: exit=$FF_ASDD_DRAIN_RC out=[$FF_ASDD_DRAIN_OUT]（非 0 なら前置きが drain より前にある）"
fi
if command -v node >/dev/null 2>&1; then
  ff_asdd_drain_probe "$TARGET" "$ASDD_PAYLOAD" "$ASDD_OFF"
  if [ "$FF_ASDD_DRAIN_RC" -eq 0 ] && [ -z "$FF_ASDD_DRAIN_OUT" ]; then
    ok "features.hooks=false（ゲートが無効と判定）でも stdin を読み切ってから無出力 exit 0"
  else
    bad "ASDD ゲート（feature 無効）の drain: exit=$FF_ASDD_DRAIN_RC out=[$FF_ASDD_DRAIN_OUT]（非 0 なら前置きが drain より前にある）"
  fi
else
  echo "  ○ skip: node が無いため features.hooks=false 経路は未検査（guard-pr-followup の ASDD ゲート無効判定）"
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
