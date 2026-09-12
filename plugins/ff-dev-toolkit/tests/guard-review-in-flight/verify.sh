#!/usr/bin/env bash
# Runtime contract for the review in-flight / dirty guard hook.
#
# 配布物 hooks/guard-review-in-flight.sh を stdin JSON で直接駆動し、2 つの受け入れ条件を
# 固定する。
#   A) 走行中ロック: `.review-results/.review-in-flight` があり PID 生存中は編集系ツールと
#      git 書き込みコマンドを deny / FF_REVIEW_LOCK_OVERRIDE=1 で通る / ロック無しは無音 /
#      stale PID は警告のみ（deny しない）/ 上限より古いロックは PID 生存でも警告のみ /
#      heredoc 本文・別リポジトリの `git -C`・read-only な git は誤爆しない
#   B) 起動時 dirty: `Agent`（`Task`）+ `subagent_type` が `pr-review-toolkit:` + dirty で
#      permissionDecision "ask" / clean は無音 / gitignore 済み成果物だけなら無音
# あわせて hooks.json への登録を静的照合する。
#
# hook ごとに suite を分ける既存慣行（guard-checkout-restore / guard-pr-followup /
# guard-background-cwd）に合わせて 1 本立てる。
#
# run-all-required: no — jq / git 不在での skip を許容する（一時領域依存 suite の必須判断で名簿へ載せなかった側。既存の Bash ガード suite と同じ扱い）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$PLUGIN_ROOT/hooks/guard-review-in-flight.sh"
# ASDD ゲートが早期終了する経路でも stdin を読み切ることを測る共有ヘルパー
# shellcheck source=../lib/asdd-gate-drain.sh
. "$SCRIPT_DIR/../lib/asdd-gate-drain.sh"
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"
MULTI_AGENT="$PLUGIN_ROOT/scripts/multi-agent.sh"

[ -f "$TARGET" ] || { echo "✗ guard-review-in-flight.sh が見つかりません: $TARGET" >&2; exit 1; }
[ -f "$HOOKS_JSON" ] || { echo "✗ hooks.json が見つかりません: $HOOKS_JSON" >&2; exit 1; }
[ -f "$MULTI_AGENT" ] || { echo "✗ multi-agent.sh が見つかりません: $MULTI_AGENT" >&2; exit 1; }
if ! command -v jq >/dev/null 2>&1; then
  echo "○ skip: jq が見つからないためスキップ（guard-review-in-flight は未検査のままです）"
  exit 0
fi
if ! command -v git >/dev/null 2>&1; then
  echo "○ skip: git が見つからないためスキップ（guard-review-in-flight は未検査のままです）"
  exit 0
fi

# fixture リポジトリの identity を呼び出し元へ漏らさない
# shellcheck source=../lib/git-fixture.sh
. "$SCRIPT_DIR/../lib/git-fixture.sh"

# rc=0 でも -d を検査する — 2>&1 の合流は「成功 + stderr 警告」の環境で変数へ
# 警告文が混入し、以後の処理が原因不明の失敗に化けるため。
if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/ff-guard-rif.XXXXXX" 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  # 物理パスへ正規化する（macOS の $TMPDIR は /var → /private/var の symlink で、
  # git rev-parse --show-toplevel が返す root と文字列比較できなくなる）
  TEST_TMP="$(cd "$_ff_mktemp_out" && pwd -P)"
else
  echo "○ skip: 一時ディレクトリを作成できません（guard-review-in-flight は未検査のままです）: $_ff_mktemp_out"
  exit 0
fi
REACHED_END=0
cleanup() {
  local rc=$?
  cd /
  rm -rf "$TEST_TMP"
  if [ "$REACHED_END" -ne 1 ] && [ "$rc" -eq 0 ]; then
    echo "✗ guard-review-in-flight: 最後まで到達しませんでした" >&2
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

REPO="$TEST_TMP/repo"
ff_git_fixture_init "$REPO" "guard-review-in-flight-test" "test@example.com" \
  || { echo "○ skip: git fixture を作れません（guard-review-in-flight は未検査のままです）"; REACHED_END=1; exit 0; }
git -C "$REPO" config commit.gpgsign false
mkdir -p "$REPO/src"
printf 'base\n' > "$REPO/src/app.txt"
printf '.review-results/\nbuild/\n' > "$REPO/.gitignore"
git -C "$REPO" add -A
git -C "$REPO" commit -qm init

LOCK_DIR="$REPO/.review-results"
LOCK="$LOCK_DIR/.review-in-flight"
mkdir -p "$LOCK_DIR"

# 生存 PID として自分自身を使う（kill -0 が必ず通る）。stale 側は「割り当てられて
# いない PID」を探して使う — 固定値だと環境によっては実在してしまう。
LIVE_PID=$$
DEAD_PID=0
for candidate in 99991 99992 99993 65533 65534; do
  if ! kill -0 "$candidate" 2>/dev/null; then
    DEAD_PID="$candidate"
    break
  fi
done
if [ "$DEAD_PID" -eq 0 ]; then
  echo "○ skip: 生存していない PID を確保できません（guard-review-in-flight は未検査のままです）"
  REACHED_END=1
  exit 0
fi

write_lock() { # <pid> [経過秒（既定 42）]
  printf 'pid=%s\ntask=review\nhead=abcdef1234567890\nstarted=2026-09-10T00:00:00Z\nstarted_epoch=%s\nperspectives=code-review,security\n' \
    "$1" "$(($(date -u +%s) - ${2:-42}))" > "$LOCK"
}
clear_lock() { rm -f "$LOCK"; }

OUT=""
RC=0
MESSAGE=""
DECISION=""
REASON=""

run_hook() { # <json> [env NAME=VALUE]
  local json="$1" extra_env="${2:-}"
  RC=0
  if [ -n "$extra_env" ]; then
    OUT="$(printf '%s' "$json" | env "$extra_env" bash "$TARGET" 2>/dev/null)" || RC=$?
  else
    OUT="$(printf '%s' "$json" | bash "$TARGET" 2>/dev/null)" || RC=$?
  fi
  MESSAGE="$(printf '%s' "$OUT" | jq -r '.systemMessage // empty' 2>/dev/null || true)"
  DECISION="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)"
  REASON="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || true)"
}

edit_json() { jq -n --arg d "$REPO" \
  '{tool_name: "Edit", tool_input: {file_path: "src/app.txt", old_string: "a", new_string: "b"}, cwd: $d, hook_event_name: "PreToolUse"}'; }
bash_json() { jq -n --arg c "$1" --arg d "$REPO" \
  '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d, hook_event_name: "PreToolUse"}'; }
agent_json() { jq -n --arg s "$1" --arg d "$REPO" --arg t "${2:-Agent}" \
  '{tool_name: $t, tool_input: {subagent_type: $s, description: "review", prompt: "review the diff"}, cwd: $d, hook_event_name: "PreToolUse"}'; }

assert_deny() { # <label>
  if [ "$RC" -eq 0 ] && [ "$DECISION" = "deny" ]; then ok "$1"; else bad "$1: exit=$RC decision=[$DECISION] out=[$OUT]"; fi
}
assert_ask() { # <label>
  if [ "$RC" -eq 0 ] && [ "$DECISION" = "ask" ]; then ok "$1"; else bad "$1: exit=$RC decision=[$DECISION] out=[$OUT]"; fi
}
assert_silent() { # <label>
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "$1"; else bad "$1: exit=$RC out=[$OUT]"; fi
}
assert_warn_only() { # <label>
  if [ "$RC" -eq 0 ] && [ -n "$MESSAGE" ] && [ -z "$DECISION" ]; then ok "$1"; else bad "$1: exit=$RC decision=[$DECISION] out=[$OUT]"; fi
}

echo "guard-review-in-flight: (a) ロックあり + PID 生存で編集を止める"
write_lock "$LIVE_PID"
run_hook "$(edit_json)"
assert_deny "(a) Edit が deny される"
case "$REASON" in
  *abcdef1234567890*) ok "(a) 拒否理由が開始 SHA を名指しする" ;;
  *) bad "(a) 拒否理由に開始 SHA が無い: [$REASON]" ;;
esac
case "$REASON" in
  *"経過"*) ok "(a) 拒否理由が経過時間を出す" ;;
  *) bad "(a) 拒否理由に経過時間が無い: [$REASON]" ;;
esac
case "$REASON" in
  *FF_REVIEW_LOCK_OVERRIDE*) ok "(a) 拒否理由が解除手段を案内する" ;;
  *) bad "(a) 拒否理由に解除手段が無い: [$REASON]" ;;
esac
# 編集系ツール（Edit / Write）は hook のセッション環境を継承するだけで、環境変数を
# その場で足せない。tool 非依存の復旧手順（ロックの実体を rm する）が先に来ること。
case "$REASON" in
  *"rm ${LOCK}"*) ok "(a) 拒否理由が tool 非依存の復旧手順（rm <ロック>）を出す" ;;
  *) bad "(a) 拒否理由に rm <ロック> が無い: [$REASON]" ;;
esac
case "$REASON" in
  *code-review*) ok "(a) 拒否理由が観点一覧を出す" ;;
  *) bad "(a) 拒否理由に観点一覧が無い: [$REASON]" ;;
esac
run_hook "$(bash_json 'git commit -m "wip"')"
assert_deny "(a) Bash の git commit も deny される"
run_hook "$(bash_json 'git switch develop')"
assert_deny "(a) Bash の git switch も deny される"

echo "guard-review-in-flight: 書き込み系でない Bash は素通しする（誤爆させない）"
run_hook "$(bash_json 'git status --porcelain')"
assert_silent "git status は無音"
run_hook "$(bash_json 'npm test')"
assert_silent "git を含まないコマンドは無音"
run_hook "$(bash_json 'echo git commit -m x')"
assert_silent "コマンド位置に無い git（echo git commit）は無音"

echo "guard-review-in-flight: (b) FF_REVIEW_LOCK_OVERRIDE=1 で通る"
run_hook "$(edit_json)" 'FF_REVIEW_LOCK_OVERRIDE=1'
assert_silent "(b) FF_REVIEW_LOCK_OVERRIDE=1 なら deny しない"
run_hook "$(edit_json)" 'FF_DEV_TOOLKIT_SKIP_REVIEW_IN_FLIGHT_GUARD=1'
assert_silent "hook 全体の opt-out でも deny しない"

echo "guard-review-in-flight: (c) ロック無しで通る"
clear_lock
run_hook "$(edit_json)"
assert_silent "(c) ロックが無ければ無音"
run_hook "$(bash_json 'git commit -m "wip"')"
assert_silent "(c) ロックが無ければ git commit も無音"

echo "guard-review-in-flight: (d) stale PID は警告のみ"
write_lock "$DEAD_PID"
run_hook "$(edit_json)"
assert_warn_only "(d) PID が死んでいれば deny せず警告だけを出す"
case "$MESSAGE" in
  *"$LOCK"*) ok "(d) 警告がロックの実体パスを名指しする" ;;
  *) bad "(d) 警告にロックのパスが無い: [$MESSAGE]" ;;
esac
clear_lock

echo "guard-review-in-flight: (d2) 上限を超えて古いロックは PID 生存でも警告のみ"
# PID 再利用（走行終了後に同じ PID が別プロセスへ割り当てられる）を、ロックが元から
# 持っている started_epoch で緩和する。既定の上限は 14400 秒。
write_lock "$LIVE_PID" 20000
run_hook "$(edit_json)"
assert_warn_only "(d2) 既定上限（14400 秒）より古いロックは deny せず警告だけを出す"
case "$MESSAGE" in
  *20*) ok "(d2) 警告が経過秒を出す" ;;
  *) bad "(d2) 警告に経過秒が無い: [$MESSAGE]" ;;
esac
run_hook "$(edit_json)" 'FF_REVIEW_LOCK_MAX_AGE_SECONDS=30000'
assert_deny "(d2) 上限を伸ばせば同じロックで deny に戻る（判定材料が経過時間であることの裏取り）"
run_hook "$(edit_json)" 'FF_REVIEW_LOCK_MAX_AGE_SECONDS=not-a-number'
assert_warn_only "(d2) 上限が数値でなければ既定 14400 秒へ倒す"
clear_lock

echo "guard-review-in-flight: (d3) heredoc 本文の git は deny しない"
write_lock "$LIVE_PID"
run_hook "$(bash_json "$(printf 'cat <<%sEOF%s > notes.md\ngit commit -m x\nEOF\n' "'" "'")")"
assert_silent "(d3) heredoc 本文の git commit は無音（メモ書きを止めない）"
run_hook "$(bash_json "$(printf 'cat <<-EOF > notes.md\n\tgit commit -m x\nEOF\n' )")"
assert_silent "(d3) <<- 形式の heredoc 本文も無音"
run_hook "$(bash_json "$(printf 'cat <<%sEOF%s > notes.md\ngit commit -m x\nEOF\ngit switch develop\n' "'" "'")")"
assert_deny "(d3) 終端行のあとに戻ったコマンド位置の git は deny される（本文の読み飛ばしが終端で止まる）"
run_hook "$(bash_json 'git commit -m "$(cat <<<hello)"')"
assert_deny "(d3) here-string（<<<）は heredoc として扱わない"

echo "guard-review-in-flight: (d4) 別リポジトリを指す git -C は対象外"
OTHER_REPO="$TEST_TMP/other"
if ff_git_fixture_init "$OTHER_REPO" "guard-review-in-flight-other" "test@example.com"; then
  git -C "$OTHER_REPO" config commit.gpgsign false
  printf 'x\n' > "$OTHER_REPO/f.txt"
  git -C "$OTHER_REPO" add -A
  git -C "$OTHER_REPO" commit -qm init
  run_hook "$(bash_json "git -C $OTHER_REPO commit -m x")"
  assert_silent "(d4) ロックを持つリポジトリ以外を指す git -C は無音"
  run_hook "$(bash_json "git -C $REPO commit -m x")"
  assert_deny "(d4) 同じリポジトリを指す git -C は従来どおり deny"
  run_hook "$(bash_json 'git -C . commit -m x')"
  assert_deny "(d4) 相対の -C は cwd 基準で解決する"
else
  echo "  ○ skip: 2 つ目の git fixture を作れません（(d4) は未検査）"
fi

echo "guard-review-in-flight: (d5) read-only な git は deny しない"
run_hook "$(bash_json 'git stash list')"
assert_silent "(d5) git stash list は無音"
run_hook "$(bash_json 'git stash show -p')"
assert_silent "(d5) git stash show は無音"
run_hook "$(bash_json 'git stash')"
assert_deny "(d5) 引数無しの git stash（= push）は deny"
run_hook "$(bash_json 'git stash push -- src/app.txt')"
assert_deny "(d5) git stash push は deny"
run_hook "$(bash_json 'git restore --staged src/app.txt')"
assert_silent "(d5) git restore --staged（--worktree なし）は index だけなので無音"
run_hook "$(bash_json 'git restore --staged --worktree src/app.txt')"
assert_deny "(d5) --worktree 併用の restore は deny"
run_hook "$(bash_json 'git restore src/app.txt')"
assert_deny "(d5) 素の git restore は deny"

echo "guard-review-in-flight: (d6) Bash はコマンド先頭の環境代入でも解除できる"
run_hook "$(bash_json 'FF_REVIEW_LOCK_OVERRIDE=1 git commit -m x')"
assert_silent "(d6) 対象 git コマンド先頭の FF_REVIEW_LOCK_OVERRIDE=1 で通る"
run_hook "$(bash_json 'echo FF_REVIEW_LOCK_OVERRIDE=1 && git commit -m x')"
assert_deny "(d6) 別セグメントに現れるだけの解除指定は効かない"
clear_lock

echo "guard-review-in-flight: (e) Agent + pr-review-toolkit + dirty で確認を出す"
printf 'dirty\n' >> "$REPO/src/app.txt"
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer')"
assert_ask "(e) dirty なら permissionDecision ask"
case "$REASON" in
  *'git diff <base>...HEAD'*) ok "(e) 理由文に「エージェントは git diff <base>...HEAD を見る」が入る" ;;
  *) bad "(e) 理由文に diff の理由が無い: [$REASON]" ;;
esac
case "$REASON" in
  *"レビュー待ち時間の使い方"*) ok "(e) 理由文が待ち時間の使い方の節を参照する" ;;
  *) bad "(e) 理由文に待ち時間の参照が無い: [$REASON]" ;;
esac
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer' 'Task')"
assert_ask "(e) 旧名 Task でも同じ判定になる"
run_hook "$(agent_json 'general-purpose')"
assert_silent "(e) pr-review-toolkit 以外の subagent_type は無音"

echo "guard-review-in-flight: (e2) 走行中なら確認理由の先頭でそれを伝える"
write_lock "$LIVE_PID"
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer')"
assert_ask "(e2) 走行中 + dirty でも確認（ask）のまま"
case "$REASON" in
  "⏳ レビュー走行中です"*) ok "(e2) 理由文の先頭行が走行中であることを言う" ;;
  *) bad "(e2) 理由文の先頭が走行中の告知でない: [$REASON]" ;;
esac
case "$REASON" in
  *abcdef1234567890*) ok "(e2) 走行中の告知が開始 SHA を含む" ;;
  *) bad "(e2) 走行中の告知に開始 SHA が無い: [$REASON]" ;;
esac
case "$REASON" in
  *"経過 4"*) ok "(e2) 走行中の告知が経過秒を含む" ;;
  *) bad "(e2) 走行中の告知に経過秒が無い: [$REASON]" ;;
esac
clear_lock
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer')"
case "$REASON" in
  "⏳"*) bad "(e2) ロックが無いのに走行中の告知が出た: [$REASON]" ;;
  *) ok "(e2) ロックが無ければ走行中の告知は出ない" ;;
esac

echo "guard-review-in-flight: (f) clean なら無警告"
git -C "$REPO" checkout -- src/app.txt
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer')"
assert_silent "(f) clean な作業ツリーでは無音"

echo "guard-review-in-flight: (g) gitignore 済み成果物だけなら発火しない"
mkdir -p "$REPO/build"
printf 'artifact\n' > "$REPO/build/out.txt"
printf 'leftover\n' > "$LOCK_DIR/stale-report.md"
run_hook "$(agent_json 'pr-review-toolkit:code-reviewer')"
assert_silent "(g) gitignore 済みの成果物だけでは無音（判定は git status --porcelain の出力有無）"
rm -f "$LOCK_DIR/stale-report.md"

echo "guard-review-in-flight: fail-open"
RC=0
OUT="$(printf 'not-json' | bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "壊れた stdin JSON は無出力 exit 0"; else bad "壊れた stdin: exit=$RC out=[$OUT]"; fi
RC=0
OUT="$(printf '' | bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "空の stdin も無出力 exit 0"; else bad "空の stdin: exit=$RC out=[$OUT]"; fi
write_lock "$LIVE_PID"
run_hook "$(jq -n --arg d "$TEST_TMP" '{tool_name: "Edit", tool_input: {file_path: "x"}, cwd: $d, hook_event_name: "PreToolUse"}')"
assert_silent "git リポジトリ外は無音（fail-open）"
printf 'pid=not-a-number\n' > "$LOCK"
run_hook "$(edit_json)"
assert_silent "PID を読めないロックは無音（fail-open）"
# PATH が空・壊れた環境で stdin を drain しないと書き手が EPIPE / SIGPIPE を受ける。
# payload をパイプバッファ（64 KiB）より大きくして、どの OS でも決定的に赤にする。
BIG_PAYLOAD="$(edit_json)$(printf '%*s' 200000 '')"
RC=0
OUT="$(printf '%s' "$BIG_PAYLOAD" | PATH="/nonexistent" /bin/bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "jq が PATH に無い環境は stdin を読み切ったうえで無出力 exit 0（書き手に EPIPE を返さない）"
else
  bad "jq 不在: exit=$RC out=[$OUT]（rc=141 なら hook が stdin を drain せずに exit している）"
fi
clear_lock

echo "guard-review-in-flight: hooks.json 登録の静的照合"
if jq -e '.hooks.PreToolUse[] | select(.matcher | test("Agent")) | .hooks[]
    | select(.command | contains("guard-review-in-flight.sh"))' "$HOOKS_JSON" >/dev/null 2>&1; then
  ok "hooks.json の PreToolUse に guard-review-in-flight.sh が登録されている"
else
  bad "hooks.json の PreToolUse に guard-review-in-flight.sh が無い"
fi
for m in Edit Write MultiEdit NotebookEdit Bash Agent Task; do
  if jq -e --arg m "$m" '.hooks.PreToolUse[] | select(.hooks[]? | .command | contains("guard-review-in-flight.sh")) | select(.matcher | test($m))' "$HOOKS_JSON" >/dev/null 2>&1; then
    ok "matcher が $m を含む"
  else
    bad "matcher に $m が無い"
  fi
done
if jq -e '.description | test("review-in-flight")' "$HOOKS_JSON" >/dev/null 2>&1; then
  ok "hooks.json の description が走行中ロックに言及する"
else
  bad "hooks.json の description に走行中ロックの記述が無い"
fi

echo "guard-review-in-flight: orchestrator 側の契約（ロックの書き出しと必ずの削除）"
if grep -q 'write_run_in_flight' "$MULTI_AGENT" && grep -q 'remove_run_in_flight' "$MULTI_AGENT"; then
  ok "multi-agent.sh がロックの書き出しと削除を持つ"
else
  bad "multi-agent.sh に write_run_in_flight / remove_run_in_flight が無い"
fi
# grep -q はパイプ入力を早期終了するので書き手へ SIGPIPE が飛ぶ（run-all の
# 再混入ガードが禁じている形）。抜き出した本文を変数へ入れてから照合する。
EXIT_TRAP_BODY="$(awk '/^output_lock_exit\(\)/,/^}/' "$MULTI_AGENT")"
case "$EXIT_TRAP_BODY" in
  *remove_run_in_flight*) EXIT_TRAP_CALLS_REMOVE=1 ;;
  *) EXIT_TRAP_CALLS_REMOVE=0 ;;
esac
if [ "$EXIT_TRAP_CALLS_REMOVE" -eq 1 ]; then
  ok "削除が EXIT trap（output_lock_exit）から呼ばれる（3 経路すべてを 1 箇所で締める）"
else
  bad "output_lock_exit が remove_run_in_flight を呼んでいない"
fi

echo "guard-review-in-flight: ASDD ゲートの早期終了経路でも stdin を読み切る"
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
  echo "  ○ skip: node が無いため features.hooks=false 経路は未検査（guard-review-in-flight の ASDD ゲート無効判定）"
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ guard-review-in-flight: ${FAIL} 件失敗（成功 ${PASS} 件）" >&2
  REACHED_END=1
  exit 1
fi
echo "✅ guard-review-in-flight: all ${PASS} checks passed"
REACHED_END=1
exit 0
