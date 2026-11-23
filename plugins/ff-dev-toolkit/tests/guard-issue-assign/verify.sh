#!/usr/bin/env bash
# 未アサインの open Issue に対するブランチ作成を実行前に止める。gh は stub で、ネットワークへ出ない。
# 空振り検出: 登録確認は rc=0。hooks.json から guard-issue-assign.sh を外す変異（rc=4）と、issue-assign-scan.sh の ff_issue_assign_judge を allow 固定にする変異（rc=4）のどちらも赤になる（2026-11-21 macOS 実測）。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$ROOT/hooks/guard-issue-assign.sh"
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"
isolate_hook_env "FF_DEV_TOOLKIT_SKIP FF_ISSUE_ASSIGN_ACK" "$TARGET"
unset FF_ISSUE_ASSIGN_ACK
unset GH_HOST
command -v jq >/dev/null || { echo 'jq required' >&2; exit 1; }
[ -s "$TARGET" ] || { echo 'hook missing' >&2; exit 1; }
[ -s "$ROOT/tests/lib/issue-assign-scan.sh" ] || { echo 'scan missing' >&2; exit 1; }
tmp="$(mktemp -d "${TMPDIR:-/tmp}/ia-guard.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"
repo="$tmp/repo"
mkdir -p "$repo" "$tmp/bin"
REACHED_END=0
cleanup() {
  local rc=$?
  rm -rf "$tmp"
  if [ "$REACHED_END" -ne 1 ] && [ "$rc" -eq 0 ]; then rc=1; fi
  exit "$rc"
}
trap cleanup EXIT
PASS=0
# 空白や括弧の直後の番号は公開同期の追加行検査に掛かる。実行時の文字列だけを組む。
h='#'
export STUB_GH_USER_RC=0
export STUB_GH_USER_OUT='tester'
export STUB_GH_HOST_USER_RC=0
export STUB_GH_HOST_USER_OUT='ghes-user'
export STUB_GH_ISSUE_RC=0
export STUB_GH_ISSUE_BODY='{"state":"OPEN","assignees":[],"url":"https://github.com/o/r/issues/9"}'
export STUB_GH_CALLS_FILE="$tmp/gh-calls"
export STUB_GH_PROMPT_FILE="$tmp/gh-prompt"
export STUB_GH_HOST_FILE="$tmp/gh-host"

cat > "$tmp/bin/gh" <<'EOF'
#!/bin/sh
if [ -n "${STUB_GH_CALLS_FILE:-}" ]; then
  printf '%s|%s\n' "$PWD" "$*" >> "$STUB_GH_CALLS_FILE"
fi
if [ -n "${STUB_GH_PROMPT_FILE:-}" ]; then
  printf '%s\n' "${GH_PROMPT_DISABLED-unset}" > "$STUB_GH_PROMPT_FILE"
fi
if [ -n "${STUB_GH_SLEEP:-}" ]; then
  sleep "$STUB_GH_SLEEP"
elif [ -f "$PWD/.stub-sleep" ]; then
  sleep "$(cat "$PWD/.stub-sleep")"
fi
case "${1:-}" in
  api)
    shift
    host="github.com"
    if [ "${1:-}" = "--hostname" ]; then
      host="$2"
      shift 2
    fi
    if [ -n "${STUB_GH_HOST_FILE:-}" ]; then
      printf '%s\n' "$host" > "$STUB_GH_HOST_FILE"
    fi
    if [ "$host" = "github.com" ]; then
      [ "${STUB_GH_USER_RC:-0}" = 0 ] || exit "$STUB_GH_USER_RC"
      printf '%s\n' "${STUB_GH_USER_OUT-tester}"
      exit 0
    else
      if [ -f "$PWD/.stub-host-${host}" ]; then
        cat "$PWD/.stub-host-${host}"
        exit 0
      fi
      [ "${STUB_GH_HOST_USER_RC:-0}" = 0 ] || exit "$STUB_GH_HOST_USER_RC"
      printf '%s\n' "${STUB_GH_HOST_USER_OUT-ghes-user}"
      exit 0
    fi
    ;;
  issue)
    shift
    if [ "${1:-}" = "view" ]; then
      num="$2"
      [ "${STUB_GH_ISSUE_RC:-0}" = 0 ] || exit "$STUB_GH_ISSUE_RC"
      if [ -f "$PWD/.stub-issue-${num}" ]; then
        cat "$PWD/.stub-issue-${num}"
        exit 0
      fi
      printf '%s\n' "${STUB_GH_ISSUE_BODY}"
      exit 0
    fi
    ;;
esac
exit 1
EOF
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

run() { # <command> [<hook>] [<cwd>]
  local hook="${2:-$TARGET}" cwd_arg="${3-$repo}"
  OUT="$(jq -nc --arg c "$1" --arg d "$cwd_arg" \
    '{tool_name:"Bash",hook_event_name:"PreToolUse",tool_input:{command:$c},cwd:$d}' | bash "$hook")"
}
deny_expected() {
  run "$2" "${3:-$TARGET}" "${4-$repo}"
  printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
  PASS=$((PASS + 1))
  printf 'ok deny %s\n' "$1"
}
allow_expected() {
  run "$2" "${3:-$TARGET}" "${4-$repo}"
  [ -z "$OUT" ]
  PASS=$((PASS + 1))
  printf 'ok allow %s\n' "$1"
}
note_expected() {
  run "$2" "${3:-$TARGET}" "${4-$repo}"
  printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null && {
    echo "note case denied: $1" >&2
    exit 1
  }
  printf '%s' "$OUT" | jq -e '(.systemMessage | type == "string") and (.hookSpecificOutput.additionalContext | type == "string") and (.hookSpecificOutput | has("permissionDecision") | not)' >/dev/null
  PASS=$((PASS + 1))
  printf 'ok note %s\n' "$1"
}

# ---- 1. Positives (deny) ----------------------------------------------------------------
deny_expected switch "git switch -c 'feature/${h}9-new'"
reason="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
case "$reason" in
  *'この Bash 呼び出しは未実行です'*"Issue ${h}9"*'gh api --hostname "github.com" --method POST "repos/o/r/issues/9/assignees" --field "assignees[]=tester"'*'FF_ISSUE_ASSIGN_ACK=1'*'FF_DEV_TOOLKIT_SKIP=issue-assign'*'止めた層: ガード'*'止めた規則: issue-assign'*'tests/lib/issue-assign-scan.sh'*'次の一手:'*) ;;
  *) echo "reason missing required lines: $reason" >&2; exit 1 ;;
esac
# 停止文末尾 3 行の形と単一の 次の一手 行を確認
[ "$(printf '%s\n' "$reason" | tail -n 3 | sed -n '1p' | grep -c '^止めた層: ガード$')" -eq 1 ]
[ "$(printf '%s\n' "$reason" | tail -n 3 | sed -n '2p' | grep -c '^止めた規則: issue-assign')" -eq 1 ]
[ "$(printf '%s\n' "$reason" | grep -c '^次の一手: ')" -eq 1 ]
# gh 照会は GH_PROMPT_DISABLED=1 で対話待ちしない
[ "$(cat "$STUB_GH_PROMPT_FILE")" = 1 ] || { echo 'gh ran without GH_PROMPT_DISABLED=1' >&2; exit 1; }
PASS=$((PASS + 2))

deny_expected switch-C "git switch -C 'feature/${h}9-new'"
deny_expected switch-create "git switch --create 'feature/${h}9-new'"
deny_expected switch-force-create "git switch --force-create='feature/${h}9-new'"
deny_expected switch-orphan "git switch --orphan 'feature/${h}9-new'"
deny_expected switch-attached "git switch -cfeature/${h}9-new"
deny_expected checkout-b "git checkout -b 'feature/${h}9-new'"
deny_expected checkout-B "git checkout -B 'feature/${h}9-new'"
deny_expected checkout-orphan "git checkout --orphan 'feature/${h}9-new'"
deny_expected checkout-attached "git checkout -bfeature/${h}9-new"
deny_expected worktree-b "git worktree add -b 'feature/${h}9-new' '$tmp/wt'"
deny_expected worktree-B "git worktree add '$tmp/wt' -B 'feature/${h}9-new'"
repo2="$tmp/repo2"
mkdir -p "$repo2"
deny_expected git-C-worktree "git -C '$repo2' worktree add -b 'feature/${h}9-new' '$tmp/wt'"
deny_expected subshell "(git switch -c 'feature/${h}9-new')"
deny_expected sudo "sudo git checkout -b 'feature/${h}9-new'"
deny_expected timeoutw "timeout 5 git switch -c 'feature/${h}9-new'"
deny_expected codex-branch "git switch -c 'codex/9-x'"
deny_expected claude-branch "git switch -c 'claude/issue-9-x'"

# 別ユーザーだけにアサイン済みの open Issue は自分未アサインとして deny
export STUB_GH_ISSUE_BODY='{"state":"OPEN","assignees":[{"login":"other"}],"url":"https://github.com/o/r/issues/9"}'
deny_expected assigned-other "git switch -c 'feature/${h}9-new'"

# 2 リポジトリ: 1 件目は自分アサイン済み、2 件目（番号 10）は未アサイン -> 2 件目の番号だけを出して deny
repo_a="$tmp/repo_a"
repo_b="$tmp/repo_b"
mkdir -p "$repo_a" "$repo_b"
printf '%s\n' '{"state":"OPEN","assignees":[{"login":"tester"}],"url":"https://github.com/o/a/issues/9"}' > "$repo_a/.stub-issue-9"
printf '%s\n' '{"state":"OPEN","assignees":[],"url":"https://github.com/o/b/issues/10"}' > "$repo_b/.stub-issue-10"
deny_expected two-repos "cd '$repo_a' && git switch -c 'feature/${h}9-a'; cd '$repo_b' && git switch -c 'feature/${h}10-b'"
two_reason="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
case "$two_reason" in
  *"Issue ${h}10"*) ;;
  *) echo "second repo missing in reason: $two_reason" >&2; exit 1 ;;
esac
case "$two_reason" in
  *"Issue ${h}9"*) echo "assigned issue from first repo leaked into deny: $two_reason" >&2; exit 1 ;;
esac
PASS=$((PASS + 1))

# プロセス環境の FF_ISSUE_ASSIGN_ACK=1 では通さない
export STUB_GH_ISSUE_BODY='{"state":"OPEN","assignees":[],"url":"https://github.com/o/r/issues/9"}'
OUT="$(jq -nc --arg c "git switch -c 'feature/${h}9-new'" --arg d "$repo" \
  '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' | FF_ISSUE_ASSIGN_ACK=1 bash "$TARGET")"
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
PASS=$((PASS + 1))
printf 'ok process-env ack still denies\n'

# 撤去済み旧名が環境にあるときも deny し、次の一手 に移行注記を添える
retired_var="FF_DEV_TOOLKIT_SKIP_""ISSUE_ASSIGN_GUARD"
OUT="$(jq -nc --arg c "git switch -c 'feature/${h}9-new'" --arg d "$repo" \
  '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' | env "${retired_var}=1" bash "$TARGET")"
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
retired_reason="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
case "$retired_reason" in
  *"旧名 ${retired_var} は読まなくなりました"*"FF_DEV_TOOLKIT_SKIP=issue-assign"*) ;;
  *) echo "retired env note missing: $retired_reason" >&2; exit 1 ;;
esac
PASS=$((PASS + 1))
printf 'ok retired-env note\n'

# ---- 2. Negatives (allow) ---------------------------------------------------------------
export STUB_GH_ISSUE_BODY='{"state":"OPEN","assignees":[{"login":"tester"}],"url":"https://github.com/o/r/issues/9"}'
allow_expected assigned-self "git switch -c 'feature/${h}9-new'"

export STUB_GH_ISSUE_BODY='{"state":"OPEN","assignees":[{"login":"Tester"}],"url":"https://github.com/o/r/issues/9"}'
allow_expected assigned-case "git switch -c 'feature/${h}9-new'"

export STUB_GH_ISSUE_BODY='{"state":"CLOSED","assignees":[],"url":"https://github.com/o/r/issues/9"}'
allow_expected closed-unassigned "git switch -c 'feature/${h}9-new'"

export STUB_GH_ISSUE_BODY='{"state":"OPEN","assignees":[],"url":"https://github.com/o/r/issues/9"}'
: > "$STUB_GH_CALLS_FILE"
allow_expected non-issue-404 "git switch -c 'fix/404-page'"
allow_expected non-issue-chore "git switch -c 'chore/cleanup'"
allow_expected non-create-switch "git switch develop"
allow_expected non-create-checkout "git checkout main"
allow_expected non-create-wt-list "git worktree list"
allow_expected non-create-wt-existing "git worktree add '$tmp/wt' 'feature/${h}9-existing'"
[ ! -s "$STUB_GH_CALLS_FILE" ] || { echo "gh should not run for non-issue / non-create: $(cat "$STUB_GH_CALLS_FILE")" >&2; exit 1; }
PASS=$((PASS + 1))

# 同じ呼び出しの先行自己アサインは免除
allow_expected preassign-me "gh issue edit 9 --add-assignee @me && git switch -c 'feature/${h}9-new'"
allow_expected preassign-login "gh issue edit 9 --add-assignee tester && git switch -c 'feature/${h}9-new'"
allow_expected preassign-api "gh api --hostname github.com --method POST repos/o/r/issues/9/assignees --field 'assignees[]=tester' && git checkout -b 'feature/${h}9-new'"
printf '%s\n' '{"state":"OPEN","assignees":[],"url":"https://github.com/o/r/issues/9"}' > "$repo2/.stub-issue-9"
allow_expected preassign-api-crossdir "gh api --method POST repos/o/r/issues/9/assignees --field 'assignees[]=tester' && git -C '$repo2' switch -c 'feature/${h}9-new'"
allow_expected preassign-api-dynrepo "gh api --method POST \"repos/\$OWNER/\$REPO/issues/9/assignees\" --field 'assignees[]=tester' && git switch -c 'feature/${h}9-new'"

# 区間先頭の FF_ISSUE_ASSIGN_ACK=1 は通す
allow_expected ack-prefix "FF_ISSUE_ASSIGN_ACK=1 git switch -c 'feature/${h}9-new'"

# FF_DEV_TOOLKIT_SKIP=issue-assign はガード全体を無効化
OUT="$(jq -nc --arg c "git switch -c 'feature/${h}9-new'" --arg d "$repo" \
  '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' | FF_DEV_TOOLKIT_SKIP=issue-assign bash "$TARGET")"
[ -z "$OUT" ]
PASS=$((PASS + 1))
printf 'ok skip\n'

# 非 JSON・Bash 以外は無言で通す
OUT="$(printf 'not json' | bash "$TARGET")"
[ -z "$OUT" ]
OUT="$(jq -nc --arg c "git switch -c 'feature/${h}9-new'" '{tool_name:"Read",tool_input:{command:$c}}' | bash "$TARGET")"
[ -z "$OUT" ]
PASS=$((PASS + 2))
printf 'ok non-json and non-bash\n'

# ---- 3. Pre-assign boundaries (deny) ----------------------------------------------------
deny_expected preassign-other "gh issue edit 9 --add-assignee other && git switch -c 'feature/${h}9-new'"
deny_expected preassign-trailing "git switch -c 'feature/${h}9-new' && gh issue edit 9 --add-assignee @me"
deny_expected preassign-or-left "false || gh issue edit 9 --add-assignee @me; git switch -c 'feature/${h}9-new'"
deny_expected preassign-or-right "gh issue edit 9 --add-assignee @me || git switch -c 'feature/${h}9-new'"
deny_expected preassign-if "if false; then gh issue edit 9 --add-assignee @me; fi; git switch -c 'feature/${h}9-new'"
deny_expected preassign-delete "gh api --method DELETE repos/o/r/issues/9/assignees -f 'assignees[]=tester' && git switch -c 'feature/${h}9-new'"
deny_expected preassign-wrong-repo "gh issue edit -R other/repo 9 --add-assignee @me && git switch -c 'feature/${h}9-new'"

# ---- 4. GHES host -----------------------------------------------------------------------
export STUB_GH_USER_RC=1
export STUB_GH_HOST_USER_RC=0
export STUB_GH_HOST_USER_OUT='ghes-user'
export STUB_GH_ISSUE_BODY='{"state":"OPEN","assignees":[],"url":"https://ghe.example.com/org/proj/issues/9"}'
deny_expected ghes-unassigned "git switch -c 'feature/${h}9-new'"
ghes_reason="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
case "$ghes_reason" in
  *'gh api --hostname "ghe.example.com" --method POST "repos/org/proj/issues/9/assignees" --field "assignees[]=ghes-user"'*) ;;
  *) echo "GHES guidance missing: $ghes_reason" >&2; exit 1 ;;
esac
[ "$(cat "$STUB_GH_HOST_FILE")" = "ghe.example.com" ] || { echo "GHES host not queried" >&2; exit 1; }
PASS=$((PASS + 1))

export STUB_GH_ISSUE_BODY='{"state":"OPEN","assignees":[{"login":"ghes-user"}],"url":"https://ghe.example.com/org/proj/issues/9"}'
allow_expected ghes-assigned "git switch -c 'feature/${h}9-new'"
export STUB_GH_USER_RC=0
export STUB_GH_ISSUE_BODY='{"state":"OPEN","assignees":[],"url":"https://github.com/o/r/issues/9"}'

# ---- 5. Fail-open (note) ----------------------------------------------------------------
export STUB_GH_ISSUE_RC=1
note_expected issue-view-fail "git switch -c 'feature/${h}9-new'"
export STUB_GH_ISSUE_RC=0

# gh 不在の PATH
no_gh="$tmp/no-gh"
mkdir -p "$no_gh"
for tool in jq bash cat awk sed grep head tr sort mktemp rm mkdir dirname basename timeout gtimeout env pwd ls printf; do
  tp="$(command -v "$tool" 2>/dev/null || true)"
  if [ -n "$tp" ] && [ -x "$tp" ]; then
    ln -sf "$tp" "$no_gh/$tool"
  fi
done
if PATH="$no_gh" command -v gh >/dev/null 2>&1; then
  echo 'failed to construct gh-less PATH' >&2
  exit 1
fi
OUT="$(jq -nc --arg c "git switch -c 'feature/${h}9-new'" --arg d "$repo" \
  '{tool_name:"Bash",hook_event_name:"PreToolUse",tool_input:{command:$c},cwd:$d}' | PATH="$no_gh" bash "$TARGET")"
printf '%s' "$OUT" | jq -e '(.systemMessage | type == "string") and (.hookSpecificOutput.additionalContext | type == "string") and (.hookSpecificOutput | has("permissionDecision") | not)' >/dev/null
PASS=$((PASS + 1))
printf 'ok note gh-absent\n'

export STUB_GH_ISSUE_BODY='not-json'
note_expected bad-json "git switch -c 'feature/${h}9-new'"

export STUB_GH_ISSUE_BODY='{"state":"OPEN","assignees":null,"url":"https://github.com/o/r/issues/9"}'
note_expected non-array-assignees "git switch -c 'feature/${h}9-new'"

export STUB_GH_USER_OUT=''
export STUB_GH_ISSUE_BODY='{"state":"OPEN","assignees":[],"url":"https://github.com/o/r/issues/9"}'
note_expected empty-login "git switch -c 'feature/${h}9-new'"
export STUB_GH_USER_OUT='tester'

if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  export STUB_GH_SLEEP=5
  note_expected slow-gh "git switch -c 'feature/${h}12-new'"
  unset STUB_GH_SLEEP
else
  printf '  ○ skip: slow-gh（timeout / gtimeout 不在のため時間切れ境界は未検証）\n'
fi

note_expected unclosed-quote "git switch -c 'feature/${h}9-new"
note_expected unresolvable-cd "cd \"\$UNKNOWN_DIR\" && git switch -c 'feature/${h}9-new'"

# 判定 lib 不在の replica は止めずに note を返す
mkdir -p "$tmp/missing-lib/hooks" "$tmp/missing-lib/tests/lib" "$tmp/missing-lib/scripts/lib"
cp "$TARGET" "$ROOT/hooks/asdd-hook-gate.sh" "$tmp/missing-lib/hooks/"
cp "$ROOT/tests/lib/review-shell-lex.sh" "$ROOT/tests/lib/shell-cwd-track.sh" "$tmp/missing-lib/tests/lib/"
cp "$ROOT/scripts/lib/branch-issue.sh" "$ROOT/scripts/lib/l4-declarations.sh" "$ROOT/scripts/lib/l4-declarations.tsv" "$ROOT/scripts/lib/stop-block.sh" "$tmp/missing-lib/scripts/lib/"
note_expected missing-helper "git switch -c 'feature/${h}9-new'" "$tmp/missing-lib/hooks/guard-issue-assign.sh"

# ---- 6. Antigravity bidirectional shim E2E ----------------------------------------------
export STUB_GH_ISSUE_BODY='{"state":"OPEN","assignees":[],"url":"https://github.com/o/r/issues/9"}'
agy_deny="$(jq -nc --arg repo "$repo" --arg c "git switch -c 'feature/${h}9-new'" '{
  conversationId: "conv-ia",
  workspacePaths: [$repo],
  cwd: $repo,
  toolCall: { name: "run_command", args: { CommandLine: $c, WaitMsBeforeAsync: 5000 } }
}' | bash "$ROOT/scripts/antigravity/hook-shim.sh" --event PreToolUse --plugin-root "$ROOT" -- bash -c 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/run-bash-hooks.sh" "${CLAUDE_PLUGIN_ROOT}/hooks/guard-issue-assign.sh"')"
printf '%s' "$agy_deny" | jq -e --arg h "$h" '.decision == "deny" and ((.reason // "") | contains("Issue " + $h + "9") and contains("止めた層: ガード"))' >/dev/null
PASS=$((PASS + 1))
printf 'ok antigravity shim deny\n'

export STUB_GH_ISSUE_BODY='{"state":"OPEN","assignees":[{"login":"tester"}],"url":"https://github.com/o/r/issues/9"}'
agy_allow="$(jq -nc --arg repo "$repo" --arg c "git switch -c 'feature/${h}9-new'" '{
  conversationId: "conv-ia",
  workspacePaths: [$repo],
  cwd: $repo,
  toolCall: { name: "run_command", args: { CommandLine: $c, WaitMsBeforeAsync: 5000 } }
}' | bash "$ROOT/scripts/antigravity/hook-shim.sh" --event PreToolUse --plugin-root "$ROOT" -- bash -c 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/run-bash-hooks.sh" "${CLAUDE_PLUGIN_ROOT}/hooks/guard-issue-assign.sh"')"
printf '%s' "$agy_allow" | jq -e '.decision == "allow"' >/dev/null
PASS=$((PASS + 1))
printf 'ok antigravity shim allow\n'

# sync-hooks.sh による実展開コマンド（PreToolUse run_command）経由の E2E
bash "$ROOT/scripts/antigravity/sync-hooks.sh" --plugin-root "$ROOT" --out "$tmp/agy-hooks.json" >/dev/null
agy_cmd="$(jq -r '."ff-dev-toolkit".PreToolUse[] | select(.matcher == "run_command") | .hooks[0].command' "$tmp/agy-hooks.json")"
[ -n "$agy_cmd" ] || { echo "sync-hooks failed to emit run_command handler" >&2; exit 1; }
mkdir -p "$tmp/agy-bin"
cat > "$tmp/agy-bin/git" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$tmp/agy-bin/git"

export STUB_GH_ISSUE_BODY='{"state":"OPEN","assignees":[],"url":"https://github.com/o/r/issues/9"}'
agy_sync_deny="$(jq -nc --arg repo "$repo" --arg c "git switch -c 'feature/${h}9-new'" '{
  conversationId: "conv-ia-sync",
  workspacePaths: [$repo],
  cwd: $repo,
  toolCall: { name: "run_command", args: { CommandLine: $c, WaitMsBeforeAsync: 5000 } }
}' | PATH="$tmp/agy-bin:$PATH" sh -c "$agy_cmd")"
printf '%s' "$agy_sync_deny" | jq -e --arg h "$h" '.decision == "deny" and ((.reason // "") | contains("Issue " + $h + "9") and contains("止めた層: ガード"))' >/dev/null
PASS=$((PASS + 1))
printf 'ok antigravity sync-hooks deny\n'

export STUB_GH_ISSUE_BODY='{"state":"OPEN","assignees":[{"login":"tester"}],"url":"https://github.com/o/r/issues/9"}'
agy_sync_allow="$(jq -nc --arg repo "$repo" --arg c "git switch -c 'feature/${h}9-new'" '{
  conversationId: "conv-ia-sync",
  workspacePaths: [$repo],
  cwd: $repo,
  toolCall: { name: "run_command", args: { CommandLine: $c, WaitMsBeforeAsync: 5000 } }
}' | PATH="$tmp/agy-bin:$PATH" sh -c "$agy_cmd")"
printf '%s' "$agy_sync_allow" | jq -e '.decision == "allow"' >/dev/null
PASS=$((PASS + 1))
printf 'ok antigravity sync-hooks allow\n'
export STUB_GH_ISSUE_BODY='{"state":"OPEN","assignees":[],"url":"https://github.com/o/r/issues/9"}'

# ---- 6b. Review coverage cases ----------------------------------------------------------
# --field='...' / -F'...' / 複数 --field / 複数 --add-assignee / -t / {owner}/{repo} / JSON配列 / --input
allow_expected field-eq-singlequote "gh api repos/o/r/issues/9/assignees --field='assignees[]=tester' && git switch -c 'feature/${h}9-new'"
allow_expected f-attached-singlequote "gh api repos/o/r/issues/9/assignees -F'assignees[]=tester' && git switch -c 'feature/${h}9-new'"
allow_expected api-multi-field "gh api repos/o/r/issues/9/assignees -f 'assignees[]=other' -f 'assignees[]=tester' && git switch -c 'feature/${h}9-new'"
allow_expected edit-multi-assignee "gh issue edit 9 --add-assignee other --add-assignee tester && git switch -c 'feature/${h}9-new'"

allow_expected api-json-tester "gh api repos/o/r/issues/9/assignees -F 'assignees:=[\"tester\"]' && git switch -c 'feature/${h}9-new'"
deny_expected api-json-other "gh api repos/o/r/issues/9/assignees -F 'assignees:=[\"other\"]' && git switch -c 'feature/${h}9-new'"
deny_expected api-json-dq-other 'gh api repos/o/r/issues/9/assignees -F "assignees:=[\"other\"]" && git switch -c "feature/'"${h}"'9-new"'
allow_expected api-json-dq-tester 'gh api repos/o/r/issues/9/assignees -F "assignees:=[\"tester\"]" && git switch -c "feature/'"${h}"'9-new"'
deny_expected api-json-dq-subst 'gh api repos/o/r/issues/9/assignees -F "assignees:=[\"$(printf %s other)\"]" && git switch -c "feature/'"${h}"'9-new"'

allow_expected api-template-2arg "gh api -t '{{.url}}' repos/o/r/issues/9/assignees -f 'assignees[]=tester' && git switch -c 'feature/${h}9-new'"
allow_expected api-placeholder-samedir "gh api repos/{owner}/{repo}/issues/9/assignees -f 'assignees[]=tester' && git switch -c 'feature/${h}9-new'"
printf '%s\n' '{"state":"OPEN","assignees":[],"url":"https://github.com/o/r/issues/9"}' > "$repo2/.stub-issue-9"
deny_expected api-placeholder-crossdir "gh api repos/{owner}/{repo}/issues/9/assignees -f 'assignees[]=tester' && git -C '$repo2' switch -c 'feature/${h}9-new'"

printf '{"assignees":["tester"]}\n' > "$tmp/self.json"
printf '{"assignees":["other"]}\n' > "$tmp/other.json"
allow_expected api-input-self "gh api --method POST repos/o/r/issues/9/assignees --input '$tmp/self.json' && git switch -c 'feature/${h}9-new'"
deny_expected api-input-other "gh api --method POST repos/o/r/issues/9/assignees --input '$tmp/other.json' && git switch -c 'feature/${h}9-new'"
deny_expected api-input-missing "gh api --method POST repos/o/r/issues/9/assignees --input /nonexistent && git switch -c 'feature/${h}9-new'"

deny_expected edit-url-other-repo "gh issue edit https://github.com/other/repo/issues/9 --add-assignee @me && git switch -c 'feature/${h}9-new'"

# GHES --hostname 不一致 / 一致
export STUB_GH_USER_RC=1
export STUB_GH_HOST_USER_RC=0
export STUB_GH_HOST_USER_OUT='ghes-user'
export STUB_GH_ISSUE_BODY='{"state":"OPEN","assignees":[],"url":"https://ghe.example.com/org/proj/issues/9"}'
deny_expected api-ghes-wrong-host "gh api --hostname github.com repos/org/proj/issues/9/assignees -f 'assignees[]=ghes-user' && git switch -c 'feature/${h}9-new'"
allow_expected api-ghes-right-host "gh api --hostname ghe.example.com repos/org/proj/issues/9/assignees -f 'assignees[]=ghes-user' && git switch -c 'feature/${h}9-new'"
export STUB_GH_USER_RC=0
export STUB_GH_ISSUE_BODY='{"state":"OPEN","assignees":[],"url":"https://github.com/o/r/issues/9"}'

# 条件連鎖・接続子・暗黙クロス dir・ACK 配置
deny_expected chain-false-and-semi "false && gh issue edit 9 --add-assignee @me; git switch -c 'feature/${h}9-new'"
deny_expected chain-or-true-semi "gh issue edit 9 --add-assignee @me || true; git switch -c 'feature/${h}9-new'"
allow_expected chain-true-and "true && gh issue edit 9 --add-assignee @me && git switch -c 'feature/${h}9-new'"

printf '%s\n' '{"state":"OPEN","assignees":[],"url":"https://github.com/o/a/issues/9"}' > "$repo_a/.stub-issue-9"
printf '%s\n' '{"state":"OPEN","assignees":[],"url":"https://github.com/o/b/issues/9"}' > "$repo_b/.stub-issue-9"
deny_expected implicit-crossdir "cd '$repo_a' && gh issue edit 9 --add-assignee @me && git -C '$repo_b' switch -c 'feature/${h}9-b'"
deny_expected ack-not-on-switch "FF_ISSUE_ASSIGN_ACK=1 true && git switch -c 'feature/${h}9-new'"

# 空 .cwd・ASDD 設定エラー
note_expected empty-cwd-note "git switch -c 'feature/${h}9-new'" "$TARGET" ""
deny_expected empty-cwd-git-c "git -C '$repo' switch -c 'feature/${h}9-new'" "$TARGET" ""

mkdir -p "$tmp/asdd-bad/.asdd"
printf '{bad json' > "$tmp/asdd-bad/.asdd/config.json"
OUT="$(cd "$tmp/asdd-bad" && jq -nc --arg c "git switch -c 'feature/${h}9-new'" --arg d "$tmp/asdd-bad" \
  '{tool_name:"Bash",hook_event_name:"PreToolUse",tool_input:{command:$c},cwd:$d}' | bash "$TARGET")"
printf '%s' "$OUT" | jq -e '(.systemMessage | type == "string") and (.hookSpecificOutput.additionalContext | type == "string") and (.hookSpecificOutput | has("permissionDecision") | not)' >/dev/null
PASS=$((PASS + 1))
printf 'ok note asdd-error\n'

# 3 リポ並列照会（1 slow タイムアウト + 1 未アサイン + 1 アサイン済み -> 10 秒未満で deny）
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  repo_s="$tmp/repo_s"
  repo_u="$tmp/repo_u"
  repo_ok="$tmp/repo_ok"
  mkdir -p "$repo_s" "$repo_u" "$repo_ok"
  printf '5\n' > "$repo_s/.stub-sleep"
  printf '%s\n' '{"state":"OPEN","assignees":[],"url":"https://github.com/o/s/issues/13"}' > "$repo_s/.stub-issue-13"
  printf '%s\n' '{"state":"OPEN","assignees":[],"url":"https://github.com/o/u/issues/11"}' > "$repo_u/.stub-issue-11"
  printf '%s\n' '{"state":"OPEN","assignees":[{"login":"tester"}],"url":"https://github.com/o/ok/issues/12"}' > "$repo_ok/.stub-issue-12"
  t_start="$(date +%s)"
  deny_expected parallel-3-repos "git -C '$repo_s' switch -c 'feature/${h}13-s'; git -C '$repo_u' switch -c 'feature/${h}11-u'; git -C '$repo_ok' switch -c 'feature/${h}12-ok'"
  t_end="$(date +%s)"
  p3_elapsed=$((t_end - t_start))
  [ "$p3_elapsed" -lt 10 ] || { echo "parallel 3-repo query took ${p3_elapsed}s (>=10s)" >&2; exit 1; }
  p3_reason="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
  case "$p3_reason" in
    *"Issue ${h}11"*) ;;
    *) echo "unassigned repo missing in parallel deny: $p3_reason" >&2; exit 1 ;;
  esac
  case "$p3_reason" in
    *"Issue ${h}12"*) echo "assigned repo leaked into parallel deny: $p3_reason" >&2; exit 1 ;;
  esac
  PASS=$((PASS + 2))
else
  printf '  ○ skip: parallel-3-repos（timeout / gtimeout 不在のため時間切れ境界は未検証）\n'
fi

# ---- 6c. Round-2 review coverage cases -------------------------------------------------
nl=$'\n'
deny_expected chain-semi "gh issue edit 9 --add-assignee @me; git switch -c 'feature/${h}9-new'"
deny_expected chain-newline "gh issue edit 9 --add-assignee @me${nl}git switch -c 'feature/${h}9-new'"
allow_expected chain-newline-then-and "echo hi${nl}gh issue edit 9 --add-assignee @me && git switch -c 'feature/${h}9-new'"
deny_expected chain-or-true-and "gh issue edit 9 --add-assignee @me || true && git switch -c 'feature/${h}9-new'"
deny_expected chain-negated "! gh issue edit 9 --add-assignee @me && git switch -c 'feature/${h}9-new'"
deny_expected dyn-assignee-edit 'gh issue edit 9 --add-assignee "$(printf %s other)" && git switch -c '\''feature/'"${h}"'9-new'\'''
deny_expected dyn-assignee-api 'gh api --method POST repos/o/r/issues/9/assignees --field "assignees[]=$(printf %s other)" && git switch -c '\''feature/'"${h}"'9-new'\'''

repo_ghes="$tmp/repo_ghes"
mkdir -p "$repo_ghes"
printf '%s\n' '{"state":"OPEN","assignees":[],"url":"https://ghe.example.com/org/proj/issues/9"}' > "$repo_ghes/.stub-issue-9"
deny_expected crossdir-ghes-default-host "gh issue edit -R org/proj 9 --add-assignee @me && git -C '$repo_ghes' switch -c 'feature/${h}9-ghes'"
allow_expected crossdir-ghes-explicit-host "gh issue edit -R ghe.example.com/org/proj 9 --add-assignee @me && git -C '$repo_ghes' switch -c 'feature/${h}9-ghes'"

note_expected git-dir-work-tree "git --git-dir '$repo2/.git' --work-tree '$repo2' switch -c 'feature/${h}9-new'"
note_expected git-dir-eq "git --git-dir='$repo2/.git' --work-tree='$repo2' switch -c 'feature/${h}9-new'"
note_expected env-git-dir "GIT_DIR='$repo2/.git' git switch -c 'feature/${h}9-new'"

export STUB_GH_ISSUE_BODY='{"state":"OPEN","assignees":[{"id":"U_abc"}],"url":"https://github.com/o/r/issues/9"}'
note_expected assignees-missing-login "git switch -c 'feature/${h}9-new'"
export STUB_GH_ISSUE_BODY='{"state":"OPEN","assignees":["tester"],"url":"https://github.com/o/r/issues/9"}'
note_expected assignees-string-element "git switch -c 'feature/${h}9-new'"
export STUB_GH_ISSUE_BODY='{"state":"OPEN","assignees":[],"url":"https://github.com/o/r/issues/9"}'

# ---- 7. Drain probe ---------------------------------------------------------------------
. "$SCRIPT_DIR/../lib/asdd-gate-drain.sh"
big="$(ff_asdd_big_payload "$(jq -nc --arg c "git status" --arg d "$repo" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')")"
ff_asdd_drain_probe "$TARGET" "$big" "$tmp" FF_DEV_TOOLKIT_SKIP=issue-assign
[ "$FF_ASDD_DRAIN_RC" -eq 0 ] && [ -z "$FF_ASDD_DRAIN_OUT" ]
mkdir -p "$tmp/no-jq"
ff_asdd_drain_probe "$TARGET" "$big" "$tmp" PATH="$tmp/no-jq:$tmp/bin"
[ "$FF_ASDD_DRAIN_RC" -eq 0 ] && [ -z "$FF_ASDD_DRAIN_OUT" ]
ff_asdd_fixture "$tmp/off" false
ff_asdd_gate_rc "$ROOT" "$tmp/off" hooks
[ "$FF_ASDD_GATE_RC" -eq 3 ]
ff_asdd_drain_probe "$TARGET" "$big" "$tmp/off"
[ "$FF_ASDD_DRAIN_RC" -eq 0 ] && [ -z "$FF_ASDD_DRAIN_OUT" ]
PASS=$((PASS + 3))
printf 'ok drain\n'

# ---- 8. Registration & mutation probes --------------------------------------------------
registered() { jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command | contains("guard-issue-assign.sh"))' "$1" >/dev/null; }
registered "$ROOT/hooks/hooks.json"
jq '(.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command) |= gsub("[^ ]*guard-issue-assign.sh[^ ]*"; "")' "$ROOT/hooks/hooks.json" > "$tmp/hooks.json"
if registered "$tmp/hooks.json"; then echo 'registration mutation survived' >&2; exit 1; fi
PASS=$((PASS + 2))

mkdir -p "$tmp/plugin/hooks" "$tmp/plugin/tests/lib" "$tmp/plugin/scripts/lib"
cp "$TARGET" "$ROOT/hooks/asdd-hook-gate.sh" "$tmp/plugin/hooks/"
cp "$ROOT/tests/lib/review-shell-lex.sh" "$ROOT/tests/lib/shell-cwd-track.sh" "$ROOT/tests/lib/issue-assign-scan.sh" "$tmp/plugin/tests/lib/"
cp "$ROOT/scripts/lib/branch-issue.sh" "$ROOT/scripts/lib/l4-declarations.sh" "$ROOT/scripts/lib/l4-declarations.tsv" "$ROOT/scripts/lib/stop-block.sh" "$tmp/plugin/scripts/lib/"
printf '\nff_issue_assign_judge() { printf "allow\\n"; return 0; }\n' >> "$tmp/plugin/tests/lib/issue-assign-scan.sh"
deny_expected real-still "git switch -c 'feature/${h}9-new'"
run "git switch -c 'feature/${h}9-new'" "$tmp/plugin/hooks/guard-issue-assign.sh"
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null; then
  echo 'allow mutation did not reach detector' >&2
  exit 1
fi
[ -z "$OUT" ]
PASS=$((PASS + 1))
printf 'ok mutation\n'

echo "issue-assign: all $PASS checks passed"
REACHED_END=1
