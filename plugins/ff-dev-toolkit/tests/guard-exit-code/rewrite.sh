#!/usr/bin/env bash
# 公開 `#138` / Issue `#2182`: 提案・実行・集約の境界を固定する。
# 空振り検出: helper不在/空出力は陽性で赤、競合/再検査失敗/別field変更はdeny。
# 空振り検出: tail の後続付き書き換えを外すと、実ガードの採用と左右の終了コードを測るケースが赤になる。
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd -P)"
target="$root/hooks/guard-exit-code.sh"
batch="$root/hooks/run-bash-hooks.sh"
tmp="$(mktemp -d /tmp/ff-rewrite-test.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
unset ff_bash_hooks_revalidated CLAUDECODE CLAUDE_PROJECT_DIR GROK_PLUGIN_ROOT
pass=0
check() { if "$@"; then pass=$((pass+1)); else echo "FAIL rewrite: $*" >&2; exit 1; fi; }
cat > "$tmp/fail" <<'SH'
#!/usr/bin/env bash
printf 'stdout\nstderr\n' >&2
exit 7
SH
chmod +x "$tmp/fail"
original="$tmp/fail | tail -1; echo \"rc=\${PIPESTATUS[0]}\""
json="$(jq -nc --arg c "$original" '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c,timeout:123,description:"fixture"}}')"
run() { printf '%s' "$json" | env CLAUDECODE=1 CLAUDE_PROJECT_DIR="$tmp" "$@"; }
out="$(run bash "$target")"
check test "$(jq -r '.hookSpecificOutput.updatedInput.timeout' <<< "$out")" = 123
check test "$(jq -r '.hookSpecificOutput.updatedInput.description' <<< "$out")" = fixture
check jq -e '.hookSpecificOutput.permissionDecision == null and (.hookSpecificOutput.additionalContext | length > 0)' <<< "$out"
command="$(jq -r '.hookSpecificOutput.updatedInput.command' <<< "$out")"
rc=0
bash -c "$command" > "$tmp/executed.log" || rc=$?
check test "$rc" -eq 7
check test "$(tail -1 "$tmp/executed.log")" = rc=7
check test "$(head -1 "$tmp/executed.log")" = stderr
# 対応未確認ホストは元のdenyを保つ。
out="$(printf '%s' "$json" | bash "$target")"
check jq -e '.hookSpecificOutput.permissionDecision == "deny" and .hookSpecificOutput.updatedInput == null' <<< "$out"
out="$(run env GROK_PLUGIN_ROOT="$tmp" bash "$target")"
check jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<< "$out"
out="$(jq '.model="codex"' <<< "$json" | env CLAUDECODE=1 CLAUDE_PROJECT_DIR="$tmp" bash "$target")"
check jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<< "$out"
for cmd in 'printf x | tail -1 | cat; echo rc=$?' 'f() { true | tail -1; return "${PIPESTATUS[0]}"; }; f' 'cd /tmp && true | tail -1; echo rc=$?' 'printf "$SECRET" | tail -1; echo rc=$?'; do
  next="$(jq --arg c "$cmd" '.tool_input.command=$c' <<< "$json")"
  out="$(printf '%s' "$next" | env CLAUDECODE=1 CLAUDE_PROJECT_DIR="$tmp" bash "$target")"
  check jq -e '.hookSpecificOutput.permissionDecision == "deny" and .hookSpecificOutput.updatedInput == null' <<< "$out"
done
out="$(run bash "$batch" "$target")"
check jq -e '.hookSpecificOutput.updatedInput.command != null and .hookSpecificOutput.permissionDecision == null and (.hookSpecificOutput.additionalContext|contains("採用しました"))' <<< "$out"
# 再検査で初めてdenyするガード。入力を実行せずシリアライズで確認。
cat > "$tmp/recheck.sh" <<'SH'
#!/usr/bin/env bash
input="$(cat)"
case "$(jq -r '.tool_input.command' <<< "$input")" in
  bash*) jq -n '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"rechecked-deny"}}' ;;
esac
SH
out="$(run bash "$batch" "$target" "$tmp/recheck.sh")"
check jq -e '.hookSpecificOutput.permissionDecision=="deny" and .hookSpecificOutput.updatedInput==null and (.hookSpecificOutput.permissionDecisionReason|contains("rechecked-deny")) and (.hookSpecificOutput.additionalContext|contains("採用しました")|not) and (.hookSpecificOutput.additionalContext|contains("書き換えました")|not)' <<< "$out"
for decision in deny ask; do
  jq -nc --arg d "$decision" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:"other-guard"}}' > "$tmp/verdict.json"
  printf '#!/usr/bin/env bash\ncat %q\n' "$tmp/verdict.json" > "$tmp/verdict.sh"
  out="$(run bash "$batch" "$target" "$tmp/verdict.sh")"
  check test "$(jq -r '.hookSpecificOutput.permissionDecision' <<< "$out")" = "$decision"
  if [ "$decision" = deny ]; then
    check jq -e '.hookSpecificOutput.updatedInput==null and (.hookSpecificOutput.additionalContext|contains("採用しました")|not) and (.hookSpecificOutput.additionalContext|contains("書き換えました")|not)' <<< "$out"
  else
    check jq -e '.hookSpecificOutput.updatedInput.command!=null and (.hookSpecificOutput.additionalContext|contains("採用しました"))' <<< "$out"
  fi
done
# 競合・不正書き換え・command以外の変更は、元入力を実行させず停止する。
for update in '{"command":"different"}' '{"command":"different","timeout":1,"description":"fixture"}' '"invalid"'; do
  jq -nc --argjson u "$update" '{hookSpecificOutput:{hookEventName:"PreToolUse",updatedInput:$u,additionalContext:"another rewrite"}}' > "$tmp/verdict.json"
  printf '#!/usr/bin/env bash\ncat %q\n' "$tmp/verdict.json" > "$tmp/verdict.sh"
  out="$(run bash "$batch" "$target" "$tmp/verdict.sh")"
  check jq -e '.hookSpecificOutput.permissionDecision=="deny" and .hookSpecificOutput.updatedInput==null' <<< "$out"
done
# 単独提案を使ってfield比較そのものへ到達する（競合拒否では代用しない）。
jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse",updatedInput:{command:"different",timeout:1,description:"fixture"}}}' > "$tmp/verdict.json"
out="$(run bash "$batch" "$tmp/verdict.sh")"
check jq -e '.hookSpecificOutput.permissionDecision=="deny" and (.hookSpecificOutput.permissionDecisionReason|contains("command 以外"))' <<< "$out"
# 再検査プロセス失敗と、同じ案を再提案するhookも停止する。
cat > "$tmp/recheck-fail.sh" <<'SH'
#!/usr/bin/env bash
input="$(cat)"
case "$(jq -r '.tool_input.command' <<< "$input")" in bash*) exit "$test_recheck_child_rc" ;; esac
SH
for child_rc in 2 7; do
  rc=0
  test_recheck_child_rc="$child_rc" run bash "$batch" "$target" "$tmp/recheck-fail.sh" > "$tmp/recheck-fail.out" 2> "$tmp/recheck-fail.err" || rc=$?
  check test "$rc" -eq 2
  check test ! -s "$tmp/recheck-fail.out"
  check grep -q '再検査が失敗' "$tmp/recheck-fail.err"
done
jq -nc --arg c 'printf same' '{hookSpecificOutput:{hookEventName:"PreToolUse",updatedInput:{command:$c,timeout:123,description:"fixture"}}}' > "$tmp/verdict.json"
out="$(run bash "$batch" "$tmp/verdict.sh")"
check jq -e '.hookSpecificOutput.permissionDecision=="deny" and .hookSpecificOutput.updatedInput==null and (.hookSpecificOutput.permissionDecisionReason|contains("さらに書き換え"))' <<< "$out"
# producerのstdinはラッパー本文と分離し、元のデータをそのまま渡す。
next="$(jq --arg c 'cat | tail -1; echo rc=$?' '.tool_input.command=$c' <<< "$json")"
out="$(printf '%s' "$next" | env CLAUDECODE=1 CLAUDE_PROJECT_DIR="$tmp" bash "$target")"
command="$(jq -r '.hookSpecificOutput.updatedInput.command' <<< "$out")"
printf 'feed\n' | bash -c "$command" > "$tmp/stdin.log"
check test "$(cat "$tmp/stdin.log")" = "$(printf 'feed\nrc=0')"
# 生成したコマンドは集約再検査を通してから、安全な fixture コマンドだけを実行する。
next="$(jq --arg c "$tmp/fail 2>&1 | tail -1 && printf reached" '.tool_input.command=$c' <<< "$json")"
out="$(printf '%s' "$next" | env CLAUDECODE=1 CLAUDE_PROJECT_DIR="$tmp" bash "$batch" "$target")"
check jq -e '.hookSpecificOutput.updatedInput.command != null and .hookSpecificOutput.permissionDecision == null and (.hookSpecificOutput.additionalContext|contains("採用しました"))' <<< "$out"
command="$(jq -r '.hookSpecificOutput.updatedInput.command' <<< "$out")"
rc=0
bash -c "$command" > "$tmp/chain.log" || rc=$?
check test "$rc" -eq 7
check test "$(cat "$tmp/chain.log")" = stderr
next="$(jq --arg c 'printf left | tail -n 1 && printf right' '.tool_input.command=$c' <<< "$json")"
out="$(printf '%s' "$next" | env CLAUDECODE=1 CLAUDE_PROJECT_DIR="$tmp" bash "$batch" "$target")"
check jq -e '.hookSpecificOutput.updatedInput.command != null and .hookSpecificOutput.permissionDecision == null' <<< "$out"
command="$(jq -r '.hookSpecificOutput.updatedInput.command' <<< "$out")"
check test "${command##* && }" = 'printf right'
check test "$(bash -c "$command")" = leftright
next="$(jq --arg c 'printf left | tail -1 && false' '.tool_input.command=$c' <<< "$json")"
out="$(printf '%s' "$next" | env CLAUDECODE=1 CLAUDE_PROJECT_DIR="$tmp" bash "$batch" "$target")"
command="$(jq -r '.hookSpecificOutput.updatedInput.command' <<< "$out")"
rc=0
bash -c "$command" > "$tmp/chain.log" || rc=$?
check test "$rc" -eq 1
check test "$(cat "$tmp/chain.log")" = left
# 通常のパイプ同様、子が出力を閉じるまで待ち、明示の結合がない stderr は分けて返す。
cat > "$tmp/delayed" <<'SH'
#!/usr/bin/env bash
printf 'first\n'
printf 'diagnostic\n' >&2
{ sleep 0.3; printf 'last\n'; } &
SH
chmod +x "$tmp/delayed"
next="$(jq --arg c "$tmp/delayed | tail -1 && printf reached" '.tool_input.command=$c' <<< "$json")"
out="$(printf '%s' "$next" | env CLAUDECODE=1 CLAUDE_PROJECT_DIR="$tmp" bash "$batch" "$target")"
check jq -e '.hookSpecificOutput.updatedInput.command != null' <<< "$out"
command="$(jq -r '.hookSpecificOutput.updatedInput.command' <<< "$out")"
bash -c "$command" > "$tmp/chain.log" 2> "$tmp/chain.err"
check test "$(cat "$tmp/chain.log")" = "$(printf 'last\nreached')"
check test "$(cat "$tmp/chain.err")" = diagnostic
mkdir "$tmp/failing-tail"
printf '#!/usr/bin/env bash\nexit 9\n' > "$tmp/failing-tail/tail"
chmod +x "$tmp/failing-tail/tail"
rc=0
PATH="$tmp/failing-tail:$PATH" bash -c "$command" > "$tmp/chain.log" 2> "$tmp/chain.err" || rc=$?
check test "$rc" -eq 9
check test ! -s "$tmp/chain.log"
for cmd in 'printf left | tail -1 && printf next && true' $'cat <<DATA | tail -1 && printf reached\ninput\nDATA'; do
  next="$(jq --arg c "$cmd" '.tool_input.command=$c' <<< "$json")"
  out="$(printf '%s' "$next" | env CLAUDECODE=1 CLAUDE_PROJECT_DIR="$tmp" bash "$batch" "$target")"
  check jq -e '.hookSpecificOutput.permissionDecision == "deny" and .hookSpecificOutput.updatedInput == null' <<< "$out"
done
# head / $? のもう一方の一意形と成功時rc。
next="$(jq --arg c 'printf ok | head -1; echo rc=$?' '.tool_input.command=$c' <<< "$json")"
out="$(printf '%s' "$next" | env CLAUDECODE=1 CLAUDE_PROJECT_DIR="$tmp" bash "$target")"
check jq -e '.hookSpecificOutput.updatedInput.command != null' <<< "$out"
command="$(jq -r '.hookSpecificOutput.updatedInput.command' <<< "$out")"
check bash -c "$command"
# ; で繋いだ一意なパイプ。片方の producer が非 0 なら書き換え後も非 0。
next="$(jq --arg c "$tmp/fail | tail -1; echo \"rc=\${PIPESTATUS[0]}\"; printf ok | head -1; echo rc=\$?" '.tool_input.command=$c' <<< "$json")"
out="$(printf '%s' "$next" | env CLAUDECODE=1 CLAUDE_PROJECT_DIR="$tmp" bash "$target")"
check jq -e '.hookSpecificOutput.updatedInput.command != null and .hookSpecificOutput.permissionDecision == null' <<< "$out"
command="$(jq -r '.hookSpecificOutput.updatedInput.command' <<< "$out")"
rc=0
bash -c "$command" > "$tmp/compound.log" || rc=$?
check test "$rc" -eq 7
check test "$(grep -c 'rc=7' "$tmp/compound.log")" -ge 1
# 両方 0 なら 0。
next="$(jq --arg c 'printf ok | head -1; echo rc=$?; printf ok | tail -1; echo rc=$?' '.tool_input.command=$c' <<< "$json")"
out="$(printf '%s' "$next" | env CLAUDECODE=1 CLAUDE_PROJECT_DIR="$tmp" bash "$target")"
command="$(jq -r '.hookSpecificOutput.updatedInput.command' <<< "$out")"
check bash -c "$command"
# 一意でない区間・関数・サブシェル・背景起動は書き換えない。
for cmd in \
  'printf x | grep -v y; echo rc=$?; printf ok | head -1; echo rc=$?' \
  'f() { printf ok | head -1; echo rc=$?; }; f' \
  '( printf ok ) | head -1; echo rc=$?; printf ok | tail -1; echo rc=$?' \
  'printf ok | head -1; echo rc=$? & printf ok | tail -1; echo rc=$?'
 do
  next="$(jq --arg c "$cmd" '.tool_input.command=$c' <<< "$json")"
  out="$(printf '%s' "$next" | env CLAUDECODE=1 CLAUDE_PROJECT_DIR="$tmp" bash "$target")"
  check jq -e '.hookSpecificOutput.permissionDecision == "deny" and .hookSpecificOutput.updatedInput == null' <<< "$out"
done
# 複合の書き換えも、後段の deny で落ちる。
out="$(run bash "$batch" "$target" "$tmp/recheck.sh")"
check jq -e '.hookSpecificOutput.permissionDecision=="deny"' <<< "$out"
next="$(jq --arg c 'printf ok | head -1; echo rc=$?; printf ok | tail -1; echo rc=$?' '.tool_input.command=$c' <<< "$json")"
out="$(printf '%s' "$next" | env CLAUDECODE=1 CLAUDE_PROJECT_DIR="$tmp" bash "$batch" "$target" "$tmp/recheck.sh")"
check jq -e '.hookSpecificOutput.permissionDecision=="deny" and .hookSpecificOutput.updatedInput==null and (.hookSpecificOutput.additionalContext|contains("採用しました")|not)' <<< "$out"
echo "exit-code rewrite: $pass checks passed"
