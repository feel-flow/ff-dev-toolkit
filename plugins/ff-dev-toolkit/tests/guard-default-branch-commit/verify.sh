#!/usr/bin/env bash
# 既定ブランチ上の git commit を実行前に止める。入力は文字列だけで、git commit は実行しない。
# 空振り検出: hook 不在は赤。判定関数を allow 固定にした写しでは陽性の拒否が消えて赤。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$ROOT/hooks/guard-default-branch-commit.sh"
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"
. "$SCRIPT_DIR/../lib/git-fixture.sh"
isolate_hook_env "FF_DEV_TOOLKIT_SKIP FF_DEFAULT_BRANCH_COMMIT_ACK" "$TARGET"
unset FF_DEFAULT_BRANCH_COMMIT_ACK
command -v jq >/dev/null || { echo 'jq required' >&2; exit 1; }
[ -s "$TARGET" ] || { echo 'hook missing' >&2; exit 1; }
[ -s "$ROOT/tests/lib/default-branch-commit-scan.sh" ] || { echo 'scan missing' >&2; exit 1; }
tmp="$(mktemp -d "${TMPDIR:-/tmp}/dbc-guard.XXXXXX")"
repo="$tmp/repo"
REACHED_END=0
cleanup() {
  local rc=$?
  rm -rf "$tmp"
  if [ "$REACHED_END" -ne 1 ] && [ "$rc" -eq 0 ]; then rc=1; fi
  exit "$rc"
}
trap cleanup EXIT
PASS=0
ff_git_fixture_init "$repo"
git -C "$repo" symbolic-ref HEAD refs/heads/develop
git -C "$repo" commit -q --allow-empty -m init
git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop

run() { # <command> [<cwd>] [<hook>]
  local cwd="${2:-$repo}" hook="${3:-$TARGET}"
  OUT="$(jq -nc --arg c "$1" --arg d "$cwd" \
    '{tool_name:"Bash",hook_event_name:"PreToolUse",tool_input:{command:$c},cwd:$d}' | bash "$hook")"
}
deny_expected() {
  run "$2" "${3:-$repo}" "${4:-$TARGET}"
  printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
  PASS=$((PASS + 1))
  printf 'ok deny %s\n' "$1"
}
allow_expected() {
  run "$2" "${3:-$repo}" "${4:-$TARGET}"
  [ -z "$OUT" ]
  PASS=$((PASS + 1))
  printf 'ok allow %s\n' "$1"
}

deny_expected plain "git commit -m 'feat: x'"
reason="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
case "$reason" in
  *'現在ブランチが develop'*'git reflog -5'*'knowledge:'*'release:'*'FF_DEFAULT_BRANCH_COMMIT_ACK=1'*'FF_DEV_TOOLKIT_SKIP=default-branch-commit'*'止めた層: ガード'*'止めた規則: default-branch-commit'*'tests/lib/default-branch-commit-scan.sh'*'次の一手:'*) ;;
  *) echo "reason missing required lines: $reason" >&2; exit 1 ;;
esac
PASS=$((PASS + 1))

deny_expected capital "git commit -m 'Knowledge: x'"
deny_expected filemsg "git commit -F '$tmp/missing-msg'"
printf 'feat: from file\n' > "$tmp/msg"
deny_expected dashF "git commit -F '$tmp/msg'"
deny_expected amend "git commit --amend"
deny_expected amendm "git commit --amend -m 'feat: amend'"
deny_expected dashC "git -C '$repo' commit -m 'feat: y'" /tmp
deny_expected second "FF_DEFAULT_BRANCH_COMMIT_ACK=1 true; git commit -m 'feat: x'"
deny_expected exportack "export FF_DEFAULT_BRANCH_COMMIT_ACK=1; git commit -m 'feat: x'"
deny_expected timeoutw "timeout 5 git commit -m 'feat: x'"
deny_expected firstpara "git commit -m 'feat: a' -m 'knowledge: b'"
deny_expected unclosed "git commit -m 'feat"
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecisionReason | contains("判定不能")' >/dev/null
PASS=$((PASS + 1))

allow_expected knowledge "git commit -m 'knowledge: note'"
allow_expected release "git commit -m 'release: 1.2.3'"
allow_expected padded "git commit -m '  knowledge: padded'"
allow_expected heredoc $'git commit -m "$(cat <<EOF\nknowledge: via body\nEOF\n)"'
allow_expected filestdin $'git commit -F - <<\'EOF\'\nknowledge: from stdin\nEOF\n'
allow_expected ack "FF_DEFAULT_BRANCH_COMMIT_ACK=1 git commit -m 'feat: x'"
allow_expected ackquote "FF_DEFAULT_BRANCH_COMMIT_ACK='1' git commit -m 'feat: x'"
allow_expected tree "git commit-tree HEAD"
allow_expected status "git status"
allow_expected echo "echo git commit -m 'feat: x'"

# 短いオプションの束と、値を取らない -u（次の語の -m を値として飲み込まない）
allow_expected untracked "git commit -u -m 'knowledge: u'"
allow_expected untrackedmode "git commit -uno -m 'knowledge: u'"
allow_expected cluster "git commit -am 'knowledge: a'"
allow_expected attached "git commit -m'knowledge: attached'"
deny_expected clusterfeat "git commit -am 'feat: a'"
deny_expected subshell "(git commit -m 'feat: x')"

# 同じ呼び出しの cd / 代入を作業ディレクトリへ当てる（JSON の cwd は呼び出し前の場所）
feat="$tmp/feat"
ff_git_fixture_init "$feat"
git -C "$feat" symbolic-ref HEAD refs/heads/feature/#1-x
git -C "$feat" commit -q --allow-empty -m init
git -C "$feat" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop
allow_expected cdfeature "cd '$feat' && git commit -m 'feat: x'"
allow_expected cdvar "F='$feat'; cd \"\$F\" && git commit -m 'feat: x'"
allow_expected cdexport "export F=$feat && cd \"\${F}\"; git commit -m 'feat: x'"
allow_expected cdunknown "cd \"\$1\" && git commit -m 'feat: x'"
allow_expected cdback "cd - && git commit -m 'feat: x'"
allow_expected dashCunknown "git -C \"\$W\" commit -m 'feat: x'"
deny_expected cddevelop "cd '$repo' && git commit -m 'feat: x'" "$feat"
deny_expected cdvardevelop "R='$repo'; cd \"\$R\"; git commit -m 'feat: x'" "$feat"
deny_expected cdexportdevelop "export R='$repo' && cd \"\${R}\"; git commit -m 'feat: x'" "$feat"
deny_expected cdrelative "cd ../repo && git commit -m 'feat: x'" "$feat"
deny_expected dashCvar "R='$repo'; git -C \"\$R\" commit -m 'feat: x'" "$feat"
deny_expected toplevel "cd \"\$(git rev-parse --show-toplevel)\" && git commit -m 'feat: x'"
# 存在しない行き先の cd は失敗して元の場所（既定ブランチ）に留まる
deny_expected cdmissing "cd '$tmp/no-such-dir'; git commit -m 'feat: x'"
deny_expected cdmissingrel "cd sub; git commit -m 'feat: x'"
# 括弧のサブシェルの cd と popd の後は元の場所へ戻る
deny_expected subshellcd "(cd '$feat' && git status); git commit -m 'feat: x'"
deny_expected pushdpopd "pushd '$feat' && popd && git commit -m 'feat: x'"
allow_expected subshellcommit "(cd '$feat' && git commit -m 'feat: x')"

# 同じ呼び出しで切り替えたブランチで判定する
allow_expected switchcreate "git switch -c 'feature/#9-x' && git commit -m 'feat: x'"
allow_expected checkoutcreate "git checkout -b 'feature/#9-x' && git add -A && git commit -m 'feat: x'"
git -C "$feat" branch develop
deny_expected checkoutdevelop "git checkout develop && git commit -m 'feat: x'" "$feat"
deny_expected switchdevelop "git switch develop; git commit -m 'feat: x'" "$feat"
allow_expected checkoutpath "git checkout -- README && git commit -m 'feat: x'" "$feat"
# 実行されないかもしれない切り替え（条件分岐の中・|| の後ろ・失敗しても続く ; の後ろ）では通さない
deny_expected switchinif "if false; then git switch -c 'feature/#9-x'; fi; git commit -m 'feat: x'"
deny_expected switchor "true || git switch -c 'feature/#9-x' && git commit -m 'feat: x'"
deny_expected switchsemi "git switch -c 'feature/#9-x' || true; git commit -m 'feat: x'"
deny_expected fixupafter "git commit -m 'knowledge: x' --fixup=HEAD"
deny_expected squashafter "git commit -m 'knowledge: x' --squash HEAD"

# 引用符付きの --message= / --file= と、変数・heredoc・置換で渡す件名
printf 'knowledge: from file\n' > "$tmp/kmsg"
printf 'knowledge: relative\n' > "$repo/relmsg"
allow_expected messageeq "git commit --message='knowledge: x'"
allow_expected messageeqdq "git commit --message=\"knowledge: x\""
allow_expected fileeq "git commit --file='$tmp/kmsg'"
allow_expected fileabs "git commit -F '$tmp/kmsg'"
allow_expected filerel "git commit -F relmsg"
allow_expected msgvar "M='knowledge: x'; git commit -m \"\$M\""
allow_expected pathspecfirst "git commit relmsg -m 'knowledge: x'"
allow_expected subsprefix "git commit -m \"knowledge: \$(date +%F)\""
deny_expected subsfeat "git commit -m \"feat: \$(date +%F)\""
deny_expected heredocfeat $'git commit -m "$(cat <<\'EOF\'\nfeat: via body\nEOF\n)"'
deny_expected filestdinfeat $'git commit -F - <<\'EOF\'\nfeat: from stdin\nEOF\n'
deny_expected decoyprefix $'cat >/dev/null <<\'EOF\'\nknowledge: decoy\nEOF\ngit commit -m "feat: $(date +%F)"'
deny_expected decoyheredoc $'cat >/dev/null <<\'EOF\'\nknowledge: decoy\nEOF\ngit commit -m "$(cat <<\'EOF2\'\nfeat: real\nEOF2\n)"'
deny_expected decoystdin $'cat >/dev/null <<\'EOF\'\nknowledge: decoy\nEOF\ngit commit -F - <<\'EOF2\'\nfeat: real\nEOF2\n'
deny_expected substonly "git commit -m \"\$(cat msg.txt)\""
deny_expected fixup "git commit --fixup=HEAD -m 'knowledge: x'"

# --amend: メッセージを渡せばその件名、渡さなければ直前のコミットの件名
allow_expected amendknowledge "git commit --amend -m 'knowledge: amended'"
kn="$tmp/kn"
ff_git_fixture_init "$kn"
git -C "$kn" symbolic-ref HEAD refs/heads/develop
git -C "$kn" commit -q --allow-empty -m 'knowledge: base'
git -C "$kn" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop
allow_expected amendnoedit "git commit --amend --no-edit" "$kn"

# git の書き方の違い
deny_expected backslashgit "\\git commit -m 'feat: x'"
# 絶対パスの git（実行はしない入力文字列。システム git の直書き検査に掛からないよう実行時に組む）
ubin='/usr/bin'
deny_expected absgit "${ubin}/git commit -m 'feat: x'"
deny_expected timegit "time git commit -m 'feat: x'"
allow_expected finishscript "bash plugins/ff-dev-toolkit/scripts/finish.sh knowledge-commit commit"

git -C "$repo" checkout -q --detach
allow_expected detached "git commit -m 'feat: x'"
git -C "$repo" checkout -q develop

git -C "$repo" symbolic-ref HEAD refs/heads/feature/#1-x
allow_expected feature "git commit -m 'feat: x'"
git -C "$repo" checkout -q develop

git -C "$repo" symbolic-ref --delete refs/remotes/origin/HEAD
allow_expected nodefault "git commit -m 'feat: x'"
git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop

OUT="$(jq -nc --arg c "git commit -m 'feat: x'" --arg d "$repo" \
  '{tool_name:"Bash",hook_event_name:"PreToolUse",tool_input:{command:$c},cwd:$d}' \
  | FF_DEFAULT_BRANCH_COMMIT_ACK=1 bash "$TARGET")"
[ -n "$OUT" ]
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
PASS=$((PASS + 1))
printf 'ok process-env ack still denies\n'

OUT="$(jq -nc --arg c "git commit -m 'feat: x'" --arg d "$repo" \
  '{tool_name:"Bash",hook_event_name:"PreToolUse",tool_input:{command:$c},cwd:$d}' \
  | FF_DEV_TOOLKIT_SKIP=default-branch-commit bash "$TARGET")"
[ -z "$OUT" ]
PASS=$((PASS + 1))
printf 'ok skip\n'

OUT="$(printf 'not json' | bash "$TARGET")"
[ -z "$OUT" ]
OUT="$(jq -nc '{tool_name:"Read",tool_input:{command:"git commit -m x"}}' | bash "$TARGET")"
[ -z "$OUT" ]
PASS=$((PASS + 2))
printf 'ok non-json and non-bash\n'

. "$SCRIPT_DIR/../lib/asdd-gate-drain.sh"
big="$(ff_asdd_big_payload "$(jq -nc --arg c "git commit -m 'feat: x'" --arg d "$repo" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')")"
ff_asdd_drain_probe "$TARGET" "$big" "$tmp" FF_DEV_TOOLKIT_SKIP=default-branch-commit
[ "$FF_ASDD_DRAIN_RC" -eq 0 ] && [ -z "$FF_ASDD_DRAIN_OUT" ]
mkdir -p "$tmp/no-jq"
ff_asdd_drain_probe "$TARGET" "$big" "$tmp" PATH="$tmp/no-jq"
[ "$FF_ASDD_DRAIN_RC" -eq 0 ] && [ -z "$FF_ASDD_DRAIN_OUT" ]
ff_asdd_fixture "$tmp/off" false
ff_asdd_gate_rc "$ROOT" "$tmp/off" hooks
[ "$FF_ASDD_GATE_RC" -eq 3 ]
ff_asdd_drain_probe "$TARGET" "$big" "$tmp/off"
[ "$FF_ASDD_DRAIN_RC" -eq 0 ] && [ -z "$FF_ASDD_DRAIN_OUT" ]
PASS=$((PASS + 3))
printf 'ok drain\n'

registered() { jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command | contains("guard-default-branch-commit.sh"))' "$1" >/dev/null; }
registered "$ROOT/hooks/hooks.json"
jq '(.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command) |= gsub("[^ ]*guard-default-branch-commit.sh[^ ]*"; "")' "$ROOT/hooks/hooks.json" > "$tmp/hooks.json"
if registered "$tmp/hooks.json"; then echo 'registration mutation survived' >&2; exit 1; fi
PASS=$((PASS + 2))

mkdir -p "$tmp/plugin/hooks" "$tmp/plugin/tests/lib"
cp "$TARGET" "$ROOT/hooks/asdd-hook-gate.sh" "$tmp/plugin/hooks/"
cp "$ROOT/tests/lib/review-shell-lex.sh" "$ROOT/tests/lib/shell-cwd-track.sh" "$ROOT/tests/lib/default-branch-commit-scan.sh" "$tmp/plugin/tests/lib/"
printf '\nff_default_branch_commit_judge() { printf "allow\\n"; return 0; }\n' >> "$tmp/plugin/tests/lib/default-branch-commit-scan.sh"
deny_expected real-still "git commit -m 'feat: x'"
run "git commit -m 'feat: x'" "$repo" "$tmp/plugin/hooks/guard-default-branch-commit.sh"
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null; then
  echo 'allow mutation did not reach detector' >&2
  exit 1
fi
[ -z "$OUT" ]
PASS=$((PASS + 1))
printf 'ok mutation\n'

# 判定 lib・作業ディレクトリ追跡の lib が無いときは、候補コマンドを判定不能として止める
for missing in default-branch-commit-scan.sh shell-cwd-track.sh; do
  rm -rf "$tmp/plugin-missing"
  mkdir -p "$tmp/plugin-missing/hooks" "$tmp/plugin-missing/tests/lib"
  cp "$TARGET" "$ROOT/hooks/asdd-hook-gate.sh" "$tmp/plugin-missing/hooks/"
  cp "$ROOT/tests/lib/review-shell-lex.sh" "$ROOT/tests/lib/shell-cwd-track.sh" "$ROOT/tests/lib/default-branch-commit-scan.sh" "$tmp/plugin-missing/tests/lib/"
  rm -f "$tmp/plugin-missing/tests/lib/$missing"
  run "git commit -m 'feat: x'" "$repo" "$tmp/plugin-missing/hooks/guard-default-branch-commit.sh"
  printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | contains("判定不能"))' >/dev/null \
    || { echo "missing $missing did not fail closed" >&2; exit 1; }
  PASS=$((PASS + 1))
  printf 'ok fail-closed without %s\n' "$missing"
done

echo "default-branch-commit: all $PASS checks passed"
REACHED_END=1
