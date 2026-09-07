#!/usr/bin/env bash
# Runtime contract for the uncommitted-change checkout/restore guard hook (Issue #673).
#
# 配布物 hooks/guard-checkout-restore.sh を fixture の git リポジトリ + stdin JSON で
# 直接駆動し、発火（deny + 代替手段の案内）と非発火（ブランチ切り替え・clean/untracked・
# --staged 単独・バイパス・opt-out・fail-open 経路)の両側を固定する。あわせて
# hooks.json の PreToolUse 登録を静的照合する。
#
# run-all-required: no — jq / git 不在での skip を許容する（一時領域依存 suite の必須判断で名簿へ載せなかった側）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$PLUGIN_ROOT/hooks/guard-checkout-restore.sh"
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"

[ -f "$TARGET" ] || { echo "✗ guard-checkout-restore.sh が見つかりません: $TARGET" >&2; exit 1; }
[ -f "$HOOKS_JSON" ] || { echo "✗ hooks.json が見つかりません: $HOOKS_JSON" >&2; exit 1; }
if ! command -v jq >/dev/null 2>&1; then
  echo "○ skip: jq が見つからないためスキップ（guard-checkout-restore は未検査のままです）"
  exit 0
fi
if ! command -v git >/dev/null 2>&1; then
  echo "○ skip: git が見つからないためスキップ（guard-checkout-restore は未検査のままです）"
  exit 0
fi

# rc=0 でも -d を検査する — 2>&1 の合流は「成功 + stderr 警告」の環境で変数へ
# 警告文が混入し、以後の処理が原因不明の失敗に化けるため。
if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/ff-guard-checkout.XXXXXX" 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
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
    echo "✗ guard-checkout-restore: 最後まで到達しませんでした" >&2
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

# ---- fixture: dirty / clean / untracked / staged を持つ git リポジトリ ----
REPO="$TEST_TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main 2>/dev/null || git -C "$REPO" init -q
git -C "$REPO" config user.email guard@test
git -C "$REPO" config user.name guard-test
printf 'a\n' > "$REPO/dirty.txt"
printf 'b\n' > "$REPO/clean.txt"
mkdir -p "$REPO/sub"
printf 'c\n' > "$REPO/sub/deep.txt"
git -C "$REPO" add .
git -C "$REPO" commit -qm init
git -C "$REPO" branch feature
printf 'modified\n' >> "$REPO/dirty.txt"
printf 'deep-mod\n' >> "$REPO/sub/deep.txt"
printf 'untracked\n' > "$REPO/untracked.txt"
printf 's\n' > "$REPO/stagedfile.txt"
git -C "$REPO" add stagedfile.txt
# `-` 始まりの実ファイル（`--` 後のパスとして保護対象）
printf 'd\n' > "$REPO/--dash.txt"
git -C "$REPO" add -- ./--dash.txt
git -C "$REPO" commit -qm dash
printf 'dash-mod\n' >> "$REPO/--dash.txt"
# dirty ファイルと同名のローカルブランチ（曖昧引数はブランチ切り替え扱い）
printf 'a\n' > "$REPO/ambig.txt"
git -C "$REPO" add ambig.txt
git -C "$REPO" commit -qm ambig
git -C "$REPO" branch ambig.txt
printf 'ambig-mod\n' >> "$REPO/ambig.txt"

OUT=""
RC=0
DECISION=""
REASON=""

run_hook() { # <command> [cwd] [env NAME=VALUE]
  local cmd="$1" cwd="${2:-$REPO}" extra_env="${3:-}"
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

echo "guard-checkout-restore: 発火側（dirty なパスへの復元）"
run_hook 'git checkout -- dirty.txt'
assert_fire "git checkout -- <dirty> は deny"
run_hook 'git checkout dirty.txt'
assert_fire "git checkout <dirty>（-- なし）は deny"
run_hook 'git restore dirty.txt'
assert_fire "git restore <dirty> は deny"
run_hook 'git checkout HEAD -- dirty.txt'
assert_fire "git checkout <ref> -- <dirty> は deny"
run_hook 'git checkout .'
assert_fire "git checkout .（dirty を含む）は deny"
run_hook 'git restore --staged --worktree dirty.txt'
assert_fire "git restore --staged --worktree は deny"
run_hook 'git restore sub/deep.txt'
assert_fire "サブディレクトリの dirty も deny"
run_hook "git -C $REPO restore dirty.txt" "$TEST_TMP"
assert_fire "git -C <dir> は dirty 判定も <dir> で行う"
run_hook 'git restore -- --dash.txt'
assert_fire "-- 後の - 始まりファイルも保護する"
run_hook 'git checkout -- ambig.txt'
assert_fire "-- 付きなら同名ブランチがあってもパス復元として deny"
run_hook 'echo FF_DISCARD_UNCOMMITTED=1 && git restore dirty.txt'
assert_fire "別セグメントの FF_DISCARD_UNCOMMITTED=1 文字列ではバイパスされない"

echo "guard-checkout-restore: 警告文の契約（代替手段とバイパスを利用者へ案内する）"
run_hook 'git restore dirty.txt'
case "$REASON" in
  *"git stash push"*) ok "警告文が git stash push を案内する" ;;
  *) bad "警告文に git stash push が無い: [$REASON]" ;;
esac
case "$REASON" in
  *cp*) ok "警告文が cp バックアップを案内する" ;;
  *) bad "警告文に cp バックアップ案内が無い: [$REASON]" ;;
esac
case "$REASON" in
  *FF_DISCARD_UNCOMMITTED=1*) ok "警告文が意図的破棄のバイパスを案内する" ;;
  *) bad "警告文にバイパス案内が無い: [$REASON]" ;;
esac
case "$REASON" in
  *dirty.txt*) ok "警告文が対象パスを名指しする" ;;
  *) bad "警告文に対象パスが無い: [$REASON]" ;;
esac

echo "guard-checkout-restore: 非発火側（誤爆しない）"
run_hook 'git checkout feature'
assert_pass "ブランチ切り替え git checkout <branch> は素通し"
run_hook 'git checkout -b newbranch'
assert_pass "ブランチ作成 git checkout -b は素通し"
run_hook 'git switch feature'
assert_pass "git switch は素通し"
run_hook 'git checkout -- clean.txt'
assert_pass "clean ファイルへの checkout は素通し"
run_hook 'git restore clean.txt'
assert_pass "clean ファイルへの restore は素通し"
run_hook 'git checkout -- untracked.txt'
assert_pass "untracked（??）への checkout は素通し"
run_hook 'git restore --staged stagedfile.txt'
assert_pass "git restore --staged 単独（worktree 非破壊）は素通し"
run_hook 'git stash push -- dirty.txt'
assert_pass "代替手段 git stash push 自体は素通し"
run_hook 'FF_DISCARD_UNCOMMITTED=1 git checkout -- dirty.txt'
assert_pass "FF_DISCARD_UNCOMMITTED=1 バイパスは素通し"
run_hook 'git status && git diff -- dirty.txt'
assert_pass "checkout/restore を含まない git は素通し"
run_hook 'ls -la'
assert_pass "git 以外のコマンドは素通し"
run_hook 'echo git restore dirty.txt'
assert_pass "コマンド位置に無い git（echo の文字列）は素通し"
run_hook 'git checkout ambig.txt'
assert_pass "dirty と同名のローカルブランチへの checkout（-- なし）は素通し"
run_hook 'git checkout -- dirty.txt' "$TEST_TMP"
assert_pass "git リポジトリ外の cwd は素通し（fail-open）"
run_hook 'git checkout -- dirty.txt' "$REPO" 'FF_DEV_TOOLKIT_SKIP_CHECKOUT_GUARD=1'
assert_pass "FF_DEV_TOOLKIT_SKIP_CHECKOUT_GUARD=1 で無効化できる"

echo "guard-checkout-restore: fail-open（自身の不具合でセッションを壊さない）"
RC=0
OUT="$(printf 'not-json' | bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "壊れた stdin JSON は無出力 exit 0"
else
  bad "壊れた stdin JSON: exit=$RC out=[$OUT]"
fi
RC=0
OUT="$(printf '' | bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "空 stdin は無出力 exit 0"
else
  bad "空 stdin: exit=$RC out=[$OUT]"
fi

echo "guard-checkout-restore: stdin の drain（fail-open でも書き手に EPIPE を返さない）"
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
OUT="$(printf '%s' "$BIG_PAYLOAD" | FF_DEV_TOOLKIT_SKIP_CHECKOUT_GUARD=1 PATH="/nonexistent" /bin/bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "opt-out（FF_DEV_TOOLKIT_SKIP_CHECKOUT_GUARD=1）でも stdin を読み切ってから無出力 exit 0"
else
  bad "opt-out の drain: exit=$RC out=[$OUT]（rc=141 なら opt-out の早期 exit が read より前にある）"
fi

echo "guard-checkout-restore: hooks.json 登録の静的照合"
if jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]
    | select(.command | contains("guard-checkout-restore.sh"))' "$HOOKS_JSON" >/dev/null 2>&1; then
  ok "hooks.json の PreToolUse（Bash matcher）に登録されている"
else
  bad "hooks.json の PreToolUse（Bash matcher）に guard-checkout-restore.sh が無い"
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ guard-checkout-restore: ${FAIL} 件失敗（成功 ${PASS} 件）" >&2
  REACHED_END=1
  exit 1
fi
echo "✅ guard-checkout-restore: all ${PASS} checks passed"
REACHED_END=1
exit 0
