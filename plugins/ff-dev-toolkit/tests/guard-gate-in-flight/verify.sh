#!/usr/bin/env bash
# 全件ゲート走行中の作業ツリー編集・書き込みガード（hooks/guard-gate-in-flight.sh）の契約検証。
# 実装・マーカー書込・共有判定 lib・Bash/Edit 系書き込み走査・抜け道・fail-closed・public-layout 連動を固定する。
#
# 空振り検出: mutation-harness で 5 件すべて detected・SURVIVED 0・未変異対照 88 件 pass（edit-live-bypass=13 fail / bash-git-write-bypass=4 fail / dead-pid-no-reclaim=rc1 / symlink-deleted=2 fail / missing-lib-fail-open=1 fail）。
#
# run-all-required: no — jq / git 不在での skip を許容する

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$ROOT/hooks/guard-gate-in-flight.sh"
RUN_ALL="$ROOT/tests/run-all.sh"
PUBLIC_LAYOUT="$ROOT/tests/public-layout/verify.sh"

# shellcheck source=../lib/adapter-env-isolation.sh
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"
isolate_hook_env "FF_DEV_TOOLKIT_SKIP FF_GATE_IN_FLIGHT_ACK FF_REVIEW_LOCK_ACK" "$TARGET"
unset FF_GATE_IN_FLIGHT_ACK FF_REVIEW_LOCK_ACK

if ! command -v jq >/dev/null 2>&1; then
  echo "○ skip: jq が無いためスキップ（検査は 1 件も実行していません）"
  exit 0
fi
if ! command -v git >/dev/null 2>&1; then
  echo "○ skip: git が無いためスキップ（検査は 1 件も実行していません）"
  exit 0
fi

[ -s "$TARGET" ] || { echo "✗ hook missing: $TARGET" >&2; exit 1; }
[ -s "$ROOT/tests/lib/gate-in-flight.sh" ] || { echo "✗ gate-in-flight lib missing" >&2; exit 1; }
[ -s "$ROOT/tests/lib/review-write-scan.sh" ] || { echo "✗ review-write-scan lib missing" >&2; exit 1; }

# shellcheck source=../lib/git-fixture.sh
. "$SCRIPT_DIR/../lib/git-fixture.sh"
# shellcheck source=../lib/gate-in-flight.sh
. "$SCRIPT_DIR/../lib/gate-in-flight.sh"

WORK_RAW="$(mktemp -d "${TMPDIR:-/tmp}/ff-gate-guard.XXXXXX")"
WORK="$(cd -P "$WORK_RAW" && pwd -P)"
PL_CACHE=""
SL_PIDS=""
REACHED_END=0
PASS=0
FAIL=0

cleanup() {
  local rc=$? pid=""
  for pid in $SL_PIDS; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  [ -n "$PL_CACHE" ] && rm -rf -- "$PL_CACHE" 2>/dev/null || true
  rm -rf -- "$WORK" 2>/dev/null || true
  if [ "$REACHED_END" -ne 1 ] && [ "$rc" -eq 0 ]; then
    echo "✗ guard-gate-in-flight: 最後まで到達しませんでした（途中で中断）" >&2
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT

ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

R1="$WORK/r1"
ff_git_fixture_init "$R1" "gate-guard" "gate-guard@example.invalid"
git -C "$R1" symbolic-ref HEAD refs/heads/main
printf '#!/usr/bin/env bash\necho hello\n' > "$R1/tracked.sh"
printf 'ignored.log\n' > "$R1/.gitignore"
git -C "$R1" add tracked.sh .gitignore
git -C "$R1" commit -qm "init"
mkdir -p "$R1/.review-results" "$R1/sub"
R1_GD="$(git -C "$R1" rev-parse --absolute-git-dir)"
R1_MDIR="$(ff_gate_marker_dir "$R1_GD")"

R1_LINK="$WORK/r1-link"
ln -s "$R1" "$R1_LINK"

R1_WT="$WORK/r1-wt"
git -C "$R1" worktree add -q -b wt-branch "$R1_WT"
printf 'wt\n' > "$R1_WT/wt.txt"
git -C "$R1_WT" add wt.txt
git -C "$R1_WT" commit -qm "wt init"

R2="$WORK/r2"
ff_git_fixture_init "$R2" "gate-guard" "gate-guard@example.invalid"
git -C "$R2" symbolic-ref HEAD refs/heads/main
printf 'other\n' > "$R2/other.txt"
git -C "$R2" add other.txt
git -C "$R2" commit -qm "r2 init"

OUTSIDE="$WORK/outside"
mkdir -p "$OUTSIDE"

mk_edit_json() { # <tool> <cwd> <path>
  if [ "$1" = "NotebookEdit" ]; then
    jq -nc --arg t "$1" --arg d "$2" --arg p "$3" \
      '{hook_event_name:"PreToolUse",tool_name:$t,cwd:$d,tool_input:{notebook_path:$p,new_source:"x"}}'
  elif [ "$1" = "Write" ]; then
    jq -nc --arg t "$1" --arg d "$2" --arg p "$3" \
      '{hook_event_name:"PreToolUse",tool_name:$t,cwd:$d,tool_input:{file_path:$p,content:"x"}}'
  else
    jq -nc --arg t "$1" --arg d "$2" --arg p "$3" \
      '{hook_event_name:"PreToolUse",tool_name:$t,cwd:$d,tool_input:{file_path:$p,old_string:"a",new_string:"b"}}'
  fi
}

mk_bash_json() { # <cwd> <command>
  jq -nc --arg d "$1" --arg c "$2" \
    '{hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$d,tool_input:{command:$c}}'
}

run_hook() { # <json> [<hook>]
  local json="$1" hk="${2:-$TARGET}"
  OUT="$(printf '%s' "$json" | bash "$hk")"
  RC=$?
}

expect_allow() { # <label> <json> [<hook>]
  run_hook "$2" "${3:-$TARGET}"
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    ok "$1"
  else
    bad "$1 — 通過期待だが rc=${RC} out=${OUT}"
  fi
}

expect_deny() { # <label> <json> <expect_ack:0|1> [<hook>]
  local dec="" reason="" next_line=""
  run_hook "$2" "${4:-$TARGET}"
  dec="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // ""' 2>/dev/null || true)"
  reason="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null || true)"
  next_line="$(printf '%s\n' "$reason" | tail -n 1)"
  if [ "$RC" -ne 0 ] || [ "$dec" != "deny" ]; then
    bad "$1 — deny 期待だが rc=${RC} decision=${dec} out=${OUT}"
    return 0
  fi
  case "$reason" in
    *'止めた層: ガード'*'止めた規則: gate-in-flight（tests/lib/gate-in-flight.sh）'*) : ;;
    *)
      bad "$1 — 停止文 3 行または規則名が不正: [$reason]"
      return 0
      ;;
  esac
  if [ "$3" -eq 1 ]; then
    case "$next_line" in
      *FF_GATE_IN_FLIGHT_ACK=1*) ok "$1" ;;
      *) bad "$1 — Bash の次の一手に FF_GATE_IN_FLIGHT_ACK=1 が無い: [$next_line]" ;;
    esac
  else
    case "$next_line" in
      *FF_GATE_IN_FLIGHT_ACK=1*) bad "$1 — Edit 系の次の一手に FF_GATE_IN_FLIGHT_ACK=1 を混ぜている: [$next_line]" ;;
      *) ok "$1" ;;
    esac
  fi
}

echo "== G1: マーカー不在時はすべて通過 =="
expect_allow "G1: Edit は通る" "$(mk_edit_json Edit "$R1" "$R1/tracked.sh")"
expect_allow "G1: Write は通る" "$(mk_edit_json Write "$R1" "$R1/new.sh")"
expect_allow "G1: MultiEdit は通る" "$(mk_edit_json MultiEdit "$R1" "$R1/tracked.sh")"
expect_allow "G1: NotebookEdit は通る" "$(mk_edit_json NotebookEdit "$R1" "$R1/nb.ipynb")"
expect_allow "G1: Bash (redirect) は通る" "$(mk_bash_json "$R1" "echo x > \"$R1/tracked.sh\"")"
expect_allow "G1: Bash (git commit) は通る" "$(mk_bash_json "$R1" "git commit -m x")"

echo "== G2: 生存マーカー（ff_gate_marker_write）中は R1 内書き込みを deny =="
MARKER_FILE="$(ff_gate_marker_write "$R1_GD" "tests/run-all.sh" "$R1")"
[ -f "$MARKER_FILE" ] && [ -f "${MARKER_FILE}.meta" ] || { bad "G2: marker 作成失敗"; exit 1; }

expect_deny "G2: Edit（絶対パス）を deny" "$(mk_edit_json Edit "$R1" "$R1/tracked.sh")" 0
expect_deny "G2: Edit（相対パス）を deny" "$(mk_edit_json Edit "$R1" "tracked.sh")" 0
expect_deny "G2: Edit（symlink 親ディレクトリ経由）を deny" "$(mk_edit_json Edit "$R1" "$R1_LINK/tracked.sh")" 0
expect_deny "G2: Edit（sub/.. 経由）を deny" "$(mk_edit_json Edit "$R1" "$R1/sub/../tracked.sh")" 0
expect_deny "G2: Write（新規ファイル）を deny" "$(mk_edit_json Write "$R1" "$R1/new.sh")" 0
expect_deny "G2: MultiEdit を deny" "$(mk_edit_json MultiEdit "$R1" "$R1/tracked.sh")" 0
expect_deny "G2: NotebookEdit を deny" "$(mk_edit_json NotebookEdit "$R1" "$R1/nb.ipynb")" 0

for bash_case in \
  "redirect|echo x > tracked.sh" \
  "tee|printf x | tee tracked.sh" \
  "sed-i|sed -i.bak 's/hello/bye/' tracked.sh" \
  "cp|cp /dev/null new.txt" \
  "mv|mv tracked.sh moved.sh" \
  "rm|rm tracked.sh" \
  "python-write|python3 -c 'open(\"py.out\",\"w\").write(\"x\")'" \
  "git-add|git add tracked.sh" \
  "git-commit|git commit -m x" \
  "git-checkout|git checkout -- tracked.sh" \
  "git-switch|git switch -c feat" \
  "git-reset|git reset --hard" \
  "git-stash|git stash" \
  "git-clean|git clean -fd" \
  "git-clean-nodryrun|git clean -n --no-dry-run" \
  "git-cherry-pick|git cherry-pick HEAD" \
  "git-rebase|git rebase main" \
  "git-merge|git merge main"; do
  name="${bash_case%%|*}"
  cmd="${bash_case#*|}"
  expect_deny "G2: Bash (${name}) を deny" "$(mk_bash_json "$R1" "$cmd")" 1
done

expect_deny "G2: ツリー外 cwd から cd で R1 へ書き込む形を deny" \
  "$(mk_bash_json "$OUTSIDE" "cd \"$R1\" && echo x > tracked.sh")" 1
expect_deny "G2: ツリー外 cwd から引用セミコロン付き cd で R1 git commit を deny" \
  "$(mk_bash_json "$OUTSIDE" "cd \"$R1\"; git commit -m q")" 1
expect_deny "G2: ツリー外 cwd から ../r1 相対移動で R1 git commit を deny" \
  "$(mk_bash_json "$OUTSIDE" "cd ../r1 && git commit -m q")" 1
expect_deny "G2: 親 work dir から r1/tracked.sh 相対書き込みを deny" \
  "$(mk_bash_json "$WORK" "printf '%s\\n' changed > r1/tracked.sh")" 1
expect_deny "G2: 親 work dir から相対ディレクトリ git -C r1 add を deny" \
  "$(mk_bash_json "$WORK" "git -C r1 add tracked.sh")" 1
expect_deny "G2: 未作成2階層サブディレクトリ配下への新規書き込みを deny" \
  "$(mk_bash_json "$OUTSIDE" "mkdir -p \"$R1/newdir/sub\" && echo x > \"$R1/newdir/sub/f.txt\"")" 1
expect_deny "G2: ツリー外 cwd から python3 open(\"R1/...\") を deny" \
  "$(mk_bash_json "$OUTSIDE" "python3 -c 'open(\"$R1/tracked.sh\",\"w\").write(\"x\")'")" 1
expect_deny "G2: ツリー外 cwd から git -C R1 commit を deny" \
  "$(mk_bash_json "$OUTSIDE" "git -C \"$R1\" commit -m x")" 1
ln -s "$R1/tracked.sh" "$R1/.review-results/escape.sh"
expect_deny "G2: .review-results 配下から tracked.sh への symlink Write を deny" \
  "$(mk_edit_json Write "$R1" "$R1/.review-results/escape.sh")" 0
rm -f "$R1/.review-results/escape.sh"
ln -s "$R1/tracked.sh" "$OUTSIDE/escape.sh"
expect_deny "G2: ツリー外から tracked.sh への symlink Write を deny" \
  "$(mk_edit_json Write "$OUTSIDE" "$OUTSIDE/escape.sh")" 0
rm -f "$OUTSIDE/escape.sh"

ff_gate_marker_remove "$MARKER_FILE"
sleep 30 &
LIVE_PID=$!
SL_PIDS="$SL_PIDS $LIVE_PID"
LIVE_START="$(ff_gate_ps_lstart "$LIVE_PID" || true)"
[ -n "$LIVE_START" ] || { bad "G2: sleep の lstart を取得できない"; exit 1; }
LIVE_MARKER="$R1_MDIR/$LIVE_PID"
printf '%s\n' "$LIVE_START" > "$LIVE_MARKER"
printf 'label=tests/run-all.sh\ntree=%s\n' "$R1" > "${LIVE_MARKER}.meta"
expect_deny "G2: 独立別 PID マーカーで Edit を deny" "$(mk_edit_json Edit "$R1" "$R1/tracked.sh")" 0
expect_deny "G2: 独立別 PID マーカーで Bash を deny" "$(mk_bash_json "$R1" "git commit -m x")" 1

echo "== G3: 読み取り専用・除外パス・別 worktree・別リポジトリは通過 =="
for ro_cmd in \
  "git status" \
  "git diff" \
  "git log -1" \
  "git clean -nd" \
  "git clean --no-dry-run -nd" \
  "ls -la" \
  "cat tracked.sh" \
  "grep hello tracked.sh" \
  "bash -n tracked.sh"; do
  expect_allow "G3: 読み取り専用 Bash (${ro_cmd}) は通る" "$(mk_bash_json "$R1" "$ro_cmd")"
done

expect_allow "G3: ツリー外 Edit は通る" "$(mk_edit_json Edit "$R1" "$OUTSIDE/note.txt")"
expect_allow "G3: ツリー外 Bash write は通る" "$(mk_bash_json "$R1" "echo x > \"$OUTSIDE/note.txt\"")"
expect_allow "G3: .review-results/ Edit は通る" "$(mk_edit_json Edit "$R1" "$R1/.review-results/out.md")"
expect_allow "G3: .review-results/ Write は通る" "$(mk_edit_json Write "$R1" "$R1/.review-results/out.md")"
expect_allow "G3: .review-results/ Bash write は通る" "$(mk_bash_json "$R1" "echo x > \"$R1/.review-results/out.md\"")"
expect_allow "G3: gitignore 済み Edit は通る" "$(mk_edit_json Edit "$R1" "$R1/ignored.log")"
expect_allow "G3: gitignore 済み Bash write は通る" "$(mk_bash_json "$R1" "echo x > \"$R1/ignored.log\"")"
expect_allow "G3: マーカーの無い linked worktree Edit は通る" "$(mk_edit_json Edit "$R1_WT" "$R1_WT/wt.txt")"
expect_allow "G3: マーカーの無い linked worktree Bash write は通る" "$(mk_bash_json "$R1_WT" "echo x > \"$R1_WT/wt.txt\"")"
expect_allow "G3: マーカーの無い linked worktree git commit は通る" "$(mk_bash_json "$R1_WT" "git commit -m wt")"
expect_allow "G3: 別リポジトリ Edit は通る" "$(mk_edit_json Edit "$R2" "$R2/other.txt")"
expect_allow "G3: 別リポジトリ Bash git commit は通る" "$(mk_bash_json "$R2" "git commit -m other")"

echo "== G4: ACK 抜け道と SKIP 無効化 =="
expect_allow "G4: Bash 区間先頭の FF_GATE_IN_FLIGHT_ACK=1 は通る" \
  "$(mk_bash_json "$R1" "FF_GATE_IN_FLIGHT_ACK=1 git commit -m ack")"
expect_allow "G4: Bash リダイレクト先頭の FF_GATE_IN_FLIGHT_ACK=1 は通る" \
  "$(mk_bash_json "$R1" "FF_GATE_IN_FLIGHT_ACK=1 echo x > tracked.sh")"
if OUT="$(FF_GATE_IN_FLIGHT_ACK=1 bash "$TARGET" < <(mk_bash_json "$R1" "git commit -m env_ack"))" \
  && [ "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // ""')" = "deny" ]; then
  ok "G4: Bash プロセス環境の FF_GATE_IN_FLIGHT_ACK=1 では通過させない"
else
  bad "G4: Bash がプロセス環境の ACK で通過した: out=[$OUT]"
fi
expect_deny "G4: Bash 第 2 区間に ACK が無ければ deny" \
  "$(mk_bash_json "$R1" "FF_GATE_IN_FLIGHT_ACK=1 echo x > ignored.log; git commit -m x")" 1
expect_deny "G4: ACK 付き git 区間の後ろに未 ACK ファイル書き込みがあれば deny" \
  "$(mk_bash_json "$R1" "FF_GATE_IN_FLIGHT_ACK=1 git add tracked.sh && printf '%s\\n' changed > tracked.sh")" 1
expect_deny "G4: ACK 付き git 区間の後ろに未 ACK git 書き込みがあれば deny" \
  "$(mk_bash_json "$R1" "FF_GATE_IN_FLIGHT_ACK=1 git add tracked.sh && git reset --hard")" 1
if [ -z "$(FF_GATE_IN_FLIGHT_ACK=1 bash "$TARGET" < <(mk_edit_json Edit "$R1" "$R1/tracked.sh"))" ]; then
  ok "G4: Edit は hook プロセス環境の FF_GATE_IN_FLIGHT_ACK=1 で通る"
else
  bad "G4: Edit がプロセス環境 ACK で通らなかった"
fi
if [ -z "$(FF_DEV_TOOLKIT_SKIP=gate-in-flight bash "$TARGET" < <(mk_edit_json Edit "$R1" "$R1/tracked.sh"))" ] \
  && [ -z "$(FF_DEV_TOOLKIT_SKIP=gate-in-flight bash "$TARGET" < <(mk_bash_json "$R1" "git commit -m skip"))" ]; then
  ok "G4: FF_DEV_TOOLKIT_SKIP=gate-in-flight は Edit/Bash とも通す"
else
  bad "G4: SKIP で通らない"
fi

kill "$LIVE_PID" 2>/dev/null || true
wait "$LIVE_PID" 2>/dev/null || true
ff_gate_marker_remove "$LIVE_MARKER"

echo "== G5: 死んだ PID / 再利用 PID の自動回収と共有生存判定の契約 =="
printf 'Thu Jan  1 00:00:00 1970\n' > "$R1_MDIR/999999"
printf 'label=dead\ntree=%s\n' "$R1" > "$R1_MDIR/999999.meta"
expect_allow "G5: 死んだ PID マーカーでは Edit を通す" "$(mk_edit_json Edit "$R1" "$R1/tracked.sh")"
if [ ! -e "$R1_MDIR/999999" ] && [ ! -e "$R1_MDIR/999999.meta" ]; then
  ok "G5: 死んだ PID マーカーと .meta を自動削除した"
else
  bad "G5: 死んだ PID マーカーが残っている"
fi

printf 'Thu Jan  1 00:00:00 1970\n' > "$R1_MDIR/$$"
printf 'label=reused\ntree=%s\n' "$R1" > "$R1_MDIR/$$.meta"
expect_allow "G5: 開始時刻不一致（PID 再利用）では Bash を通す" "$(mk_bash_json "$R1" "git commit -m reused")"
if [ ! -e "$R1_MDIR/$$" ] && [ ! -e "$R1_MDIR/$$.meta" ]; then
  ok "G5: 再利用 PID マーカーと .meta を自動削除した"
else
  bad "G5: 再利用 PID マーカーが残っている"
fi

ln -s /nonexistent "$R1_MDIR/$$"
expect_deny "G5: symlink マーカーは判定不能として安全側に deny" "$(mk_edit_json Edit "$R1" "$R1/tracked.sh")" 0
if [ -L "$R1_MDIR/$$" ]; then
  ok "G5: symlink マーカーを勝手に削除しない"
else
  bad "G5: symlink マーカーが消された"
fi
rm -f "$R1_MDIR/$$"

_g5_saved_mdir="$WORK/g5-real-mdir"
mv "$R1_MDIR" "$_g5_saved_mdir"
ln -s /nonexistent "$R1_MDIR"
expect_deny "G5: symlink 化した run-all-in-flight dir では Edit を fail-closed で deny" "$(mk_edit_json Edit "$R1" "$R1/tracked.sh")" 0
expect_deny "G5: symlink 化した run-all-in-flight dir では Bash 書込を fail-closed で deny" "$(mk_bash_json "$R1" "git commit -m unsafe")" 1
if [ -L "$R1_MDIR" ]; then
  ok "G5: symlink 化した run-all-in-flight dir を削除しない"
else
  bad "G5: symlink 化した run-all-in-flight dir が消された"
fi
rm -f "$R1_MDIR"
mv "$_g5_saved_mdir" "$R1_MDIR"

if grep -qF 'ff_gate_marker_status' "$TARGET" \
  && grep -qF 'tests/lib/gate-in-flight.sh' "$TARGET" \
  && grep -qF 'lib/gate-in-flight.sh' "$RUN_ALL" \
  && grep -qF 'ff_gate_scan_repo_worktree_markers' "$RUN_ALL"; then
  ok "G5: run-all.sh と guard-gate-in-flight.sh が同じ gate-in-flight.sh を共用"
else
  bad "G5: gate-in-flight.sh の共用が欠けている"
fi

echo "== G6: 判定・走査ライブラリ欠損時の fail-closed =="
REPL="$WORK/repl"
mkdir -p "$REPL/hooks" "$REPL/scripts/lib" "$REPL/tests/lib"
cp "$ROOT/hooks/"*.sh "$REPL/hooks/" 2>/dev/null || true
cp "$ROOT/scripts/lib/"*.sh "$ROOT/scripts/lib/"*.tsv "$REPL/scripts/lib/" 2>/dev/null || true
cp "$ROOT/tests/lib/"*.sh "$REPL/tests/lib/" 2>/dev/null || true
rm -f "$REPL/tests/lib/gate-in-flight.sh"
run_hook "$(mk_edit_json Edit "$R1" "$R1/tracked.sh")" "$REPL/hooks/guard-gate-in-flight.sh"
reason_g6="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null || true)"
if [ "$RC" -eq 0 ] \
  && printf '%s' "$OUT" | jq -re '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
  && case "$reason_g6" in *gate-judge-unavailable*) true ;; *) false ;; esac; then
  ok "G6: gate-in-flight.sh 欠損時は git 管理下の Edit を gate-judge-unavailable で deny"
else
  bad "G6: gate-in-flight.sh 欠損時の Edit fail-closed 失敗: [$OUT]"
fi
expect_allow "G6: gate-in-flight.sh 欠損でも git 管理外 Edit は通す" \
  "$(mk_edit_json Edit "$OUTSIDE" "$OUTSIDE/note.txt")" "$REPL/hooks/guard-gate-in-flight.sh"

cp "$ROOT/tests/lib/gate-in-flight.sh" "$REPL/tests/lib/gate-in-flight.sh"
rm -f "$REPL/tests/lib/review-write-scan.sh"
MK2="$(ff_gate_marker_write "$R1_GD" "tests/run-all.sh" "$R1")"
run_hook "$(mk_edit_json Edit "$R1" "$R1/tracked.sh")" "$REPL/hooks/guard-gate-in-flight.sh"
dec2="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // ""' 2>/dev/null || true)"
[ "$dec2" = "deny" ] && ok "G6: review-write-scan.sh 欠損 + 生存マーカーで Edit deny" \
  || bad "G6: review-write-scan.sh 欠損 + 生存マーカーで通ってしまった: [$OUT]"
run_hook "$(mk_bash_json "$R1" "git status")" "$REPL/hooks/guard-gate-in-flight.sh"
dec3="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // ""' 2>/dev/null || true)"
[ "$dec3" = "deny" ] && ok "G6: review-write-scan.sh 欠損 + 生存マーカーで Bash deny（fail-closed）" \
  || bad "G6: review-write-scan.sh 欠損 + 生存マーカーで Bash が通った: [$OUT]"
ff_gate_marker_remove "$MK2"

echo "== G7: public-layout/verify.sh の SSOT マーカーと rc=2 伝播 =="
_pl_base_parent="${XDG_CACHE_HOME:-${HOME:-}/.cache}"
_pl_skip=0
case "${_pl_base_parent}/" in
  / | "${TMPDIR:-/none}"* | /tmp/* | /private/tmp/*) _pl_skip=1 ;;
esac
if [ ! -f "$PUBLIC_LAYOUT" ]; then
  bad "G7: public-layout/verify.sh が存在しません: $PUBLIC_LAYOUT"
elif command -v yq >/dev/null 2>&1 && [ -n "${HOME:-}" ] && [ "$_pl_skip" -eq 0 ]; then
  mkdir -p "$_pl_base_parent"
  _pl_mk_rc=0
  _pl_mk_out="$(mktemp -d "${_pl_base_parent}/ff-gate-pl-test.XXXXXX" 2>&1)" || _pl_mk_rc=$?
  if [ "$_pl_mk_rc" -eq 0 ] && [ -n "$_pl_mk_out" ] && [ -d "$_pl_mk_out" ]; then
    PL_CACHE="$_pl_mk_out"
    PL_REPO="$WORK/pl-repo"
    mkdir -p "$PL_REPO/plugins/ff-dev-toolkit/tests/public-layout" \
      "$PL_REPO/plugins/ff-dev-toolkit/tests/lib" \
      "$PL_REPO/plugins/ff-dev-toolkit/mcp/node_modules" \
      "$PL_REPO/scripts"
    cp "$PUBLIC_LAYOUT" "$PL_REPO/plugins/ff-dev-toolkit/tests/public-layout/verify.sh"
    cp "$ROOT/tests/public-layout/resident-skip-allow.sh" "$PL_REPO/plugins/ff-dev-toolkit/tests/public-layout/resident-skip-allow.sh"
    cp "$ROOT/tests/lib/gate-in-flight.sh" "$PL_REPO/plugins/ff-dev-toolkit/tests/lib/gate-in-flight.sh"
    cat > "$PL_REPO/scripts/sync-dev-toolkit-to-public.sh" <<'SYNC'
#!/usr/bin/env bash
set -euo pipefail
tgt=""
while [ $# -gt 0 ]; do
  case "$1" in
    --target) tgt="$2"; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "$tgt/plugins/ff-dev-toolkit/tests/run-all" "$tgt/plugins/ff-dev-toolkit/mcp"
cat > "$tgt/plugins/ff-dev-toolkit/tests/run-all/verify.sh" <<'SUB'
#!/usr/bin/env bash
exit 0
SUB
cat > "$tgt/plugins/ff-dev-toolkit/tests/run-all.sh" <<'RUN'
#!/usr/bin/env bash
mdir="${PL_SSOT_GIT_DIR:?}/ff-dev-toolkit/run-all-in-flight"
found=0
for f in "$mdir"/*; do
  [ -f "$f" ] || continue
  case "${f##*/}" in *[!0-9]*) continue ;; esac
  found=$((found + 1))
done
printf 'PL_SSOT_MARKERS=%s\n' "$found"
exit "${PL_STUB_RC:-0}"
RUN
chmod +x "$tgt/plugins/ff-dev-toolkit/tests/run-all/verify.sh" "$tgt/plugins/ff-dev-toolkit/tests/run-all.sh"
SYNC
    chmod +x "$PL_REPO/scripts/sync-dev-toolkit-to-public.sh"
    ff_git_fixture_init "$PL_REPO" "pl-test" "pl@example.invalid"
    git -C "$PL_REPO" symbolic-ref HEAD refs/heads/main
    git -C "$PL_REPO" add -A
    git -C "$PL_REPO" commit -qm "pl repo init"
    PL_SSOT_GD="$(git -C "$PL_REPO" rev-parse --absolute-git-dir)"

    pl_rc0=0
    pl_out0="$(env -u GITHUB_ACTIONS XDG_CACHE_HOME="$PL_CACHE" \
      PL_SSOT_GIT_DIR="$PL_SSOT_GD" PL_STUB_RC=0 FF_PUBLIC_LAYOUT_SUITES=run-all \
      bash "$PL_REPO/plugins/ff-dev-toolkit/tests/public-layout/verify.sh" 2>&1)" || pl_rc0=$?
    if [ "$pl_rc0" -eq 0 ] \
      && case "$pl_out0" in *PL_SSOT_MARKERS=1*) true ;; *) false ;; esac \
      && [ -z "$(find "$PL_SSOT_GD/ff-dev-toolkit/run-all-in-flight" -type f 2>/dev/null)" ]; then
      ok "G7: public-layout 走行中は SSOT マーカーを置き、正常終了後は削除する"
    else
      bad "G7: public-layout 正常系の SSOT マーカー挙動が不正 (rc=${pl_rc0}) out=[$pl_out0]"
    fi

    pl_rc2=0
    pl_out2="$(env -u GITHUB_ACTIONS XDG_CACHE_HOME="$PL_CACHE" \
      PL_SSOT_GIT_DIR="$PL_SSOT_GD" PL_STUB_RC=2 FF_PUBLIC_LAYOUT_SUITES=run-all \
      bash "$PL_REPO/plugins/ff-dev-toolkit/tests/public-layout/verify.sh" 2>&1)" || pl_rc2=$?
    if [ "$pl_rc2" -eq 2 ] \
      && case "$pl_out2" in *判定不能*) true ;; *) false ;; esac \
      && [ -z "$(find "$PL_SSOT_GD/ff-dev-toolkit/run-all-in-flight" -type f 2>/dev/null)" ]; then
      ok "G7: public-layout は子の rc=2 を rc=2（判定不能）として伝播し SSOT マーカーを削除する"
    else
      bad "G7: public-layout の rc=2 伝播が不正 (rc=${pl_rc2}) out=[$pl_out2]"
    fi
  else
    bad "G7: キャッシュ検証領域を作成できません (rc=${_pl_mk_rc}: ${_pl_mk_out})"
  fi
else
  echo "ℹ️  G7: yq 不在または HOME キャッシュ配置外の前提のため合成起動を省略"
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ guard-gate-in-flight verify: ${FAIL} 件失敗 / ${PASS} 件成功" >&2
  exit 1
fi
REACHED_END=1
echo "✓ guard-gate-in-flight verify: 全 ${PASS} 件 pass"
