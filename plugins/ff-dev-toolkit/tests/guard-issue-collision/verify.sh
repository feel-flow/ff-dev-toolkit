#!/usr/bin/env bash
# 同じ Issue のブランチ作成と PR 作成を実行前に止める。git と gh は stub で、ネットワークへ出ない。
# 空振り検出: hook 不在は赤。判定関数を allow 固定にした写しでは陽性の拒否が消えて赤。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$ROOT/hooks/guard-issue-collision.sh"
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"
isolate_hook_env "FF_DEV_TOOLKIT_SKIP FF_ISSUE_COLLISION_ACK" "$TARGET"
unset FF_ISSUE_COLLISION_ACK
command -v jq >/dev/null || { echo 'jq required' >&2; exit 1; }
[ -s "$TARGET" ] || { echo 'hook missing' >&2; exit 1; }
[ -s "$ROOT/tests/lib/issue-collision-scan.sh" ] || { echo 'scan missing' >&2; exit 1; }
tmp="$(mktemp -d "${TMPDIR:-/tmp}/ic-guard.XXXXXX")"
# TMPDIR が / で終わると mktemp の結果に // が入り、gh 側の作業ディレクトリ（正規化済み）との比較が食い違う
tmp="$(cd "$tmp" && pwd)"
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
export STUB_LS=$'abc\trefs/heads/feature/#9-other\ndef\trefs/heads/feature/#9-mine\n'
export STUB_HEAD='feature/#9-mine'
export STUB_GH_RC=0
export STUB_GH_BODY='[]'
export STUB_PWD_FILE="$tmp/pwd"
export STUB_PROMPT_FILE="$tmp/prompt"
cat > "$tmp/bin/git" <<'EOF'
#!/bin/sh
dir=""
while [ $# -gt 0 ]; do
  case "$1" in
    -C) dir="$2"; shift 2; continue ;;
    *) break ;;
  esac
done
case "$*" in
  *ls-remote*)
    printf '%s\n' "${GIT_TERMINAL_PROMPT-unset}" > "$STUB_PROMPT_FILE"
    [ "${STUB_LS_RC:-0}" = 0 ] || exit "$STUB_LS_RC"
    # 作業ディレクトリごとのリモート一覧（<dir>/.stub-ls）があればそれを返す
    if [ -n "$dir" ] && [ -f "$dir/.stub-ls" ]; then cat "$dir/.stub-ls"; exit 0; fi
    printf '%s' "$STUB_LS"; exit 0 ;;
  *symbolic-ref*)
    # 作業ディレクトリごとの HEAD（<dir>/.stub-head）があればそれを返す
    if [ -n "$dir" ] && [ -f "$dir/.stub-head" ]; then cat "$dir/.stub-head"; else printf '%s\n' "$STUB_HEAD"; fi
    exit 0 ;;
esac
exit 0
EOF
cat > "$tmp/bin/gh" <<'EOF'
#!/bin/sh
printf '%s\n' "$PWD" > "$STUB_PWD_FILE"
if [ "$STUB_GH_RC" != 0 ]; then
  exit "$STUB_GH_RC"
fi
if [ -n "${STUB_GH_SLEEP:-}" ]; then
  sleep "$STUB_GH_SLEEP"
fi
printf '%s\n' "$STUB_GH_BODY"
exit 0
EOF
chmod +x "$tmp/bin/git" "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

run() { # <command> [<hook>]
  local hook="${2:-$TARGET}"
  OUT="$(jq -nc --arg c "$1" --arg d "$repo" \
    '{tool_name:"Bash",hook_event_name:"PreToolUse",tool_input:{command:$c},cwd:$d}' | bash "$hook")"
}
deny_expected() {
  run "$2" "${3:-$TARGET}"
  printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
  PASS=$((PASS + 1))
  printf 'ok deny %s\n' "$1"
}
allow_expected() {
  run "$2" "${3:-$TARGET}"
  [ -z "$OUT" ]
  PASS=$((PASS + 1))
  printf 'ok allow %s\n' "$1"
}
note_expected() {
  run "$2"
  printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null && {
    echo "note case denied: $1" >&2
    exit 1
  }
  printf '%s' "$OUT" | jq -e '(.systemMessage | type == "string") and (.hookSpecificOutput.additionalContext | type == "string") and (.hookSpecificOutput | has("permissionDecision") | not)' >/dev/null
  PASS=$((PASS + 1))
  printf 'ok note %s\n' "$1"
}

deny_expected switch "git switch -c 'feature/#9-new'"
reason="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
case "$reason" in
  *'この Bash 呼び出しは未実行です'*"Issue ${h}9"*'feature/#9-other'*'FF_ISSUE_COLLISION_ACK=1'*'FF_DEV_TOOLKIT_SKIP=issue-collision'*'止めた層: ガード'*'止めた規則: issue-collision'*'tests/lib/issue-collision-scan.sh'*'次の一手:'*) ;;
  *) echo "reason missing required lines: $reason" >&2; exit 1 ;;
esac
case "$reason" in
  *'feature/#9-mine'*) ;;
  *) echo 'branch create should still name every matching remote branch' >&2; exit 1 ;;
esac
# リモート照会は認証の対話入力を待たない
[ "$(cat "$STUB_PROMPT_FILE")" = 0 ] || { echo 'ls-remote ran without GIT_TERMINAL_PROMPT=0' >&2; exit 1; }
PASS=$((PASS + 1))

deny_expected checkout "git checkout -b 'feature/#9-new'"
deny_expected attached "git switch -cfeature/#9-new"
deny_expected sudo "sudo git checkout -b 'feature/#9-new'"
deny_expected timeoutw "timeout 5 git switch -c 'feature/#9-new'"
deny_expected create "git switch --create 'feature/#9-new'"
deny_expected worktree "git -C '$repo' worktree add -b 'feature/#9-new' '$tmp/wt' origin/develop"
deny_expected worktreeB "git worktree add '$tmp/wt' -B 'feature/#9-new'"
deny_expected subshell "(git switch -c 'feature/#9-new')"

printf 'Closes %s9\n' "$h" > "$tmp/body"
deny_expected bodyfile "gh pr create --body-file '$tmp/body'"
deny_expected title "gh pr create --title 'Closes ${h}9'"
deny_expected body "gh pr create --body 'Closes ${h}9 and ${h}10'"
# 自分の現在ブランチは PR 作成の一致から外し、別のリモートブランチは残す。
case "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')" in
  *'feature/#9-other'*) ;;
  *) echo 'pr create dropped the other remote branch' >&2; exit 1 ;;
esac
case "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')" in
  *'feature/#9-mine'*) echo 'pr create treated the current branch as a collision' >&2; exit 1 ;;
esac
# 停止文に並べるのは衝突した番号だけ（10 は衝突していない）
case "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')" in
  *"Issue ${h}10"*) echo 'reason listed a number without a collision' >&2; exit 1 ;;
esac
PASS=$((PASS + 1))

# Claude Code が標準で使う heredoc の本文、-b<本文> の束、別名 gh pr new
deny_expected heredocbody "gh pr create --title 'feat: x' --body \"\$(cat <<'EOF'
Closes ${h}9
EOF
)\""
deny_expected attachedbody "gh pr create -b'Closes ${h}9'"
deny_expected prnew "gh pr new --body 'Closes ${h}9'"
deny_expected checkoutlate "git checkout origin/develop -b 'feature/#9-new'"
note_expected fill "gh pr create --fill"

# 自分のブランチ: --head の値、または同じ呼び出しの cd 先の現在ブランチ（HEAD はディレクトリごとの stub）
wt="$tmp/wt"
mkdir -p "$wt"
printf 'feature/#9-mine\n' > "$wt/.stub-head"
export STUB_HEAD='develop'
export STUB_LS=$'abc\trefs/heads/feature/#9-mine\n'
allow_expected headarg "gh pr create --head 'feature/#9-mine' --body 'Closes ${h}9'"
allow_expected cdself "cd '$wt' && gh pr create --body 'Closes ${h}9'"
allow_expected subshellself "(cd '$wt' && gh pr create --body 'Closes ${h}9')"
deny_expected ownbranchfromdevelop "gh pr create --body 'Closes ${h}9'"
note_expected cdunknown "cd \"\$1\" && gh pr create --body 'Closes ${h}9'"
note_expected otherrepo "gh pr create --repo someone/other --body 'Closes ${h}9'"
export STUB_HEAD='feature/#9-mine'
export STUB_LS=$'abc\trefs/heads/feature/#9-other\ndef\trefs/heads/feature/#9-mine\n'
[ "$(cat "$STUB_PWD_FILE")" = "$repo" ]
PASS=$((PASS + 1))
printf 'ok gh ran inside the target repo\n'

# 別のリポジトリで作るブランチの番号は、そのリポジトリへ照会する（最初のリポジトリだけに照会しない）
ra="$tmp/ra"
rb="$tmp/rb"
mkdir -p "$ra" "$rb"
: > "$ra/.stub-ls"
printf 'abc\trefs/heads/feature/#10-existing\n' > "$rb/.stub-ls"
deny_expected tworepos "git -C '$ra' switch -c 'feature/#9-new'; git -C '$rb' switch -c 'feature/#10-new'"
case "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')" in
  *'feature/#10-existing'*) ;;
  *) echo 'second repository was not queried' >&2; exit 1 ;;
esac
PASS=$((PASS + 1))

STUB_GH_BODY="$(printf '[{"number":41,"title":"work","body":"Closes %s9"}]' "$h")"
export STUB_LS=$'abc\trefs/heads/feature/#9-mine\n'
deny_expected prhit "gh pr create --body 'Closes ${h}9'"
case "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')" in
  *"open PR ${h}41"*) ;;
  *) echo 'open PR number missing' >&2; exit 1 ;;
esac
case "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')" in
  *'feature/#9-mine'*) echo 'own branch denied pr create' >&2; exit 1 ;;
esac
PASS=$((PASS + 1))

export STUB_LS=''
export STUB_GH_BODY='[]'
allow_expected clear "git switch -c 'feature/#9-new'"
allow_expected ownpr "gh pr create --body 'Closes ${h}9'"
export STUB_LS=$'abc\trefs/heads/feature/#9-mine\n'
allow_expected ownonly "gh pr create --body 'Closes ${h}9'"
allow_expected noswitch "git switch develop"
allow_expected worktreeexisting "git worktree add '$tmp/wt' 'feature/#9-other'"
allow_expected worktreelist "git worktree list"
allow_expected notkw "gh pr create --title 'feat(${h}9): no close'"
export STUB_LS=$'abc\trefs/heads/feature/#9-other\n'
allow_expected ack "FF_ISSUE_COLLISION_ACK=1 git switch -c 'feature/#9-new'"

OUT="$(jq -nc --arg c "git switch -c 'feature/#9-new'" --arg d "$repo" \
  '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' | FF_ISSUE_COLLISION_ACK=1 bash "$TARGET")"
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
PASS=$((PASS + 1))
printf 'ok process-env ack still denies\n'

OUT="$(jq -nc --arg c "git switch -c 'feature/#9-new'" --arg d "$repo" \
  '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' | FF_DEV_TOOLKIT_SKIP=issue-collision bash "$TARGET")"
[ -z "$OUT" ]
PASS=$((PASS + 1))
printf 'ok skip\n'

export STUB_GH_RC=1
deny_expected ghdown "git switch -c 'feature/#9-new'"
case "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')" in
  *'feature/#9-other'*'PR の照会は失敗'*) ;;
  *) echo "confirmed branch did not deny when gh failed: $(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')" >&2; exit 1 ;;
esac
PASS=$((PASS + 1))
export STUB_LS=''
note_expected ghonly "gh pr create --body 'Closes ${h}9'"
case "$(printf '%s' "$OUT" | jq -r '.systemMessage')" in
  *照会*) ;;
  *) echo 'query failure note missing 照会' >&2; exit 1 ;;
esac
PASS=$((PASS + 1))

export STUB_GH_RC=0
export STUB_GH_BODY='not-json'
note_expected badjson "gh pr create --title 'Closes ${h}9'"
export STUB_GH_BODY='[]'
export STUB_GH_SLEEP=5
note_expected slow "gh pr create --body 'Closes ${h}12'"
unset STUB_GH_SLEEP

# open PR の取得が 50 件で打ち切られ、一致が無いときは止めずに知らせる
export STUB_LS=''
STUB_GH_BODY="$(jq -nc '[range(1;51) | {number: ., title: "x", body: "y", headRefName: "b"}]')"
export STUB_GH_BODY
note_expected truncated "gh pr create --body 'Closes ${h}9'"
case "$(printf '%s' "$OUT" | jq -r '.systemMessage')" in
  *'50 件で打ち切られ'*) ;;
  *) echo 'truncation note missing' >&2; exit 1 ;;
esac
PASS=$((PASS + 1))

# ブランチの照会が失敗しても、PR の実在を確認できれば止める
export STUB_LS_RC=1
STUB_GH_BODY="$(printf '[{"number":41,"title":"work","body":"Closes %s9","headRefName":"feature/x"}]' "$h")"
export STUB_GH_BODY
deny_expected lsdown "gh pr create --body 'Closes ${h}9'"
case "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')" in
  *"open PR ${h}41"*'ブランチの照会は失敗'*) ;;
  *) echo 'branch query failure side note missing' >&2; exit 1 ;;
esac
PASS=$((PASS + 1))

# 自分のブランチを head に持つ open PR は衝突に数えない
export STUB_LS_RC=0
export STUB_LS=$'abc\trefs/heads/feature/#9-mine\n'
STUB_GH_BODY="$(printf '[{"number":42,"title":"mine","body":"Closes %s9","headRefName":"feature/#9-mine"}]' "$h")"
export STUB_GH_BODY
allow_expected ownpr-head "gh pr create --body 'Closes ${h}9'"
export STUB_GH_BODY='[]'

note_expected unreadable "gh pr create --body-file '$tmp/no-such-body'"
note_expected unclosed "gh pr create --body 'Closes ${h}9"

OUT="$(printf 'not json' | bash "$TARGET")"
[ -z "$OUT" ]
OUT="$(jq -nc '{tool_name:"Read",tool_input:{command:"git switch -c feature/#9-new"}}' | bash "$TARGET")"
[ -z "$OUT" ]
PASS=$((PASS + 2))
printf 'ok non-json and non-bash\n'

. "$SCRIPT_DIR/../lib/asdd-gate-drain.sh"
big="$(ff_asdd_big_payload "$(jq -nc --arg c "git status" --arg d "$repo" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')")"
ff_asdd_drain_probe "$TARGET" "$big" "$tmp" FF_DEV_TOOLKIT_SKIP=issue-collision
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

registered() { jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command | contains("guard-issue-collision.sh"))' "$1" >/dev/null; }
registered "$ROOT/hooks/hooks.json"
jq '(.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command) |= gsub("[^ ]*guard-issue-collision.sh[^ ]*"; "")' "$ROOT/hooks/hooks.json" > "$tmp/hooks.json"
if registered "$tmp/hooks.json"; then echo 'registration mutation survived' >&2; exit 1; fi
PASS=$((PASS + 2))

mkdir -p "$tmp/plugin/hooks" "$tmp/plugin/tests/lib"
cp "$TARGET" "$ROOT/hooks/asdd-hook-gate.sh" "$tmp/plugin/hooks/"
cp "$ROOT/tests/lib/review-shell-lex.sh" "$ROOT/tests/lib/shell-cwd-track.sh" "$ROOT/tests/lib/issue-collision-scan.sh" "$tmp/plugin/tests/lib/"
printf '\nff_issue_collision_judge() { printf "allow\\n"; return 0; }\n' >> "$tmp/plugin/tests/lib/issue-collision-scan.sh"
export STUB_LS=$'abc\trefs/heads/feature/#9-other\n'
export STUB_GH_RC=0
export STUB_GH_BODY='[]'
deny_expected real-still "git switch -c 'feature/#9-new'"
run "git switch -c 'feature/#9-new'" "$tmp/plugin/hooks/guard-issue-collision.sh"
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null; then
  echo 'allow mutation did not reach detector' >&2
  exit 1
fi
[ -z "$OUT" ]
PASS=$((PASS + 1))
printf 'ok mutation\n'

echo "issue-collision: all $PASS checks passed"
REACHED_END=1
