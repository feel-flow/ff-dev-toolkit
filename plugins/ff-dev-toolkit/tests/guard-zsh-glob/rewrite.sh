#!/usr/bin/env bash
# Issue `#2255`: zsh の nomatch glob・equals 展開ガードの入力書き換え（Issue `#2182` と同じ契約）を固定する。
# 陽性: 一意な書き換え案だけの呼び出しは deny せず updatedInput を返し、全 tool_input を保持し、
#       書き換え後が zsh で実際に走る。nomatch と equals が同居しても 1 案にまとまる。
# 陰性: 案の無い語・同じ綴りが判定対象外にもある・heredoc・一覧 scalar・未対応ホスト・
#       集約入口で別ガードが deny / 書き換え競合する形は従来の deny を保つ。
# 空振り検出: 書き換えヘルパ関数（ff_zsh_equals_fix_scan）の不在では書き換えずに deny へ戻ることを R9 が要求し
#   （走査 awk の失敗は try_rewrite より手前の判定不能 deny で止まり、書き換えへ届かないことを同じ R9 が固定する）、案を出さない（常に deny する）hook では陽性の R1〜R3 が赤になる。
# 変異検出: try_rewrite の出現回数照合を外すと R5（単一引用の中の同じ綴り。再走査では見えない）が、ホスト判定を外すと R7 が赤になる（2026-10-25 実測）。
# 変異検出: CR の除外を外すと R3c が、保留した equals の deny を EXIT trap で出す経路を外すと R5 の equals 系が赤になる（2026-10-25 レビュー対応後に実測）。
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd -P)"
target="${ZSH_REWRITE_TARGET_OVERRIDE:-$root/hooks/guard-zsh-glob.sh}"
batch="$root/hooks/run-bash-hooks.sh"
exit_guard="$root/hooks/guard-exit-code.sh"
tmp="$(mktemp -d /tmp/ff-zsh-rewrite-test.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
unset ff_bash_hooks_revalidated CLAUDECODE CLAUDE_PROJECT_DIR GROK_PLUGIN_ROOT CLAUDE_CODE_SHELL \
  FF_ZSH_GLOB_ACK FF_DEV_TOOLKIT_SKIP_ZSH_GLOB_GUARD FF_DEV_TOOLKIT_SKIP_ZSH_EXPANSION_GUARD FF_ZSH_GLOB_AWK
pass=0
check() { if "$@"; then pass=$((pass+1)); else echo "FAIL zsh rewrite: $*" >&2; exit 1; fi; }
payload() { jq -nc --arg c "$1" '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c,timeout:123,description:"fixture"}}'; }
# run <command> [env...] — 書き換えに対応した Claude hook 環境の zsh ホストで hook を直接駆動する。
run() { local c="$1"; shift; payload "$c" | env SHELL=/bin/zsh CLAUDECODE=1 CLAUDE_PROJECT_DIR="$tmp" "$@" bash "$target"; }
rewritten() { jq -r '.hookSpecificOutput.updatedInput.command // empty' <<< "$1"; }
is_rewrite() { jq -e '.hookSpecificOutput.updatedInput != null and .hookSpecificOutput.permissionDecision == null and (.hookSpecificOutput.additionalContext | contains("引用"))' <<< "$1" >/dev/null; }
is_deny() { jq -e '.hookSpecificOutput.permissionDecision == "deny" and .hookSpecificOutput.updatedInput == null' <<< "$1" >/dev/null; }

# R1 nomatch: 書き換え案どおりに引用し、command 以外のフィールドを保持する。
out="$(run 'grep -rn foo --include=*.md .')"
check is_rewrite "$out"
check test "$(rewritten "$out")" = 'grep -rn foo --include="*.md" .'
check test "$(jq -r '.hookSpecificOutput.updatedInput.timeout' <<< "$out")" = 123
check test "$(jq -r '.hookSpecificOutput.updatedInput.description' <<< "$out")" = fixture
# R2 equals: = だけの語を引用する。
out="$(run 'echo ====')"
check is_rewrite "$out"
check test "$(rewritten "$out")" = 'echo "===="'
# R3 同居: nomatch 複数と equals が 1 つの updatedInput にまとまる（集約入口の競合扱いにしない）。
out="$(run 'grep -rn foo --include=*.md --include=*.ts --include=*.js --include=*.sh --include=*.json --include=*.yml .; echo ======')"
check is_rewrite "$out"
check test "$(rewritten "$out")" = 'grep -rn foo --include="*.md" --include="*.ts" --include="*.js" --include="*.sh" --include="*.json" --include="*.yml" .; echo "======"'
# R3b 同じ語の複数出現はすべて引用する。未引用 scalar の警告と同居しても出力は 1 つの JSON にまとまる。
out="$(run 'grep -rn foo --include=*.md docs; grep -rn bar --include=*.md tests')"
check test "$(rewritten "$out")" = 'grep -rn foo --include="*.md" docs; grep -rn bar --include="*.md" tests'
out="$(run 'grep -rn foo --include=*.md $X')"
check is_rewrite "$out"
check jq -se 'length == 1 and (.[0].systemMessage | contains("単語分割"))' <<< "$out" >/dev/null
# R3c 元のコマンドに CR がある回は書き換えない（判定用に CR を落とした文字列を実行入力へ戻さない）。
out="$(run "$(printf 'printf %%s "a\rb"; grep --include=*.md .')")"
check is_deny "$out"
# R4 書き換え後が zsh で実際に走る（zsh が無い環境は skip を明示する。無音の緑にしない）。
if command -v zsh >/dev/null 2>&1; then
  mkdir -p "$tmp/tree"; printf 'foo\n' > "$tmp/tree/a.md"; printf 'foo\n' > "$tmp/tree/b.txt"
  out="$(run "grep -rl foo --include=*.md $tmp/tree; echo ====")"
  zout="$(zsh -fc "$(rewritten "$out")" 2>&1)"
  check test "$zout" = "$(printf '%s\n%s' "$tmp/tree/a.md" '====')"
else
  echo "SKIP R4: zsh が無いため書き換え後の実行を確認できません" >&2
fi
# R5 陰性: 案の無い語・同じ綴りが引用の中にもある・意図的でありうる =cmd・equals の綴りが重なる・heredoc・一覧 scalar。
for cmd in 'grep --include=$X* .' 'echo "--include=*.md" --include=*.md' "echo '--include=*.md' --include=*.md" '=ls -la' '[ a == b ]; echo ====' \
  "$(printf 'cat <<EOF\nx\nEOF\ngrep --include=*.md .')" 'A="x y"; echo $A ====' 'grep --include=*.md . "--include=*.md"'; do
  out="$(run "$cmd")"
  check is_deny "$out"
done
# R6 抜け道は従来どおり無出力で通す。
out="$(run 'FF_ZSH_GLOB_ACK=1 grep --include=*.md .')"
check test -z "$out"
# R7 未対応ホストは従来の deny（CLAUDECODE なし・model あり・grok root あり・bash ホストは無出力）。
out="$(payload 'echo ====' | env SHELL=/bin/zsh CLAUDE_PROJECT_DIR="$tmp" bash "$target")"
check is_deny "$out"
out="$(payload 'grep --include=*.md .' | jq -c '.model="codex"' | env SHELL=/bin/zsh CLAUDECODE=1 CLAUDE_PROJECT_DIR="$tmp" bash "$target")"
check is_deny "$out"
out="$(run 'grep --include=*.md .' GROK_PLUGIN_ROOT="$tmp")"
check is_deny "$out"
out="$(payload 'grep --include=*.md .' | env SHELL=/bin/bash CLAUDECODE=1 CLAUDE_PROJECT_DIR="$tmp" bash "$target")"
check test -z "$out"
# R8 集約入口: 全ガード再検査を通った書き換えを採用し、別ガードの deny / ask と書き換え競合は保持する。
bat() { payload "$1" | env SHELL=/bin/zsh CLAUDECODE=1 CLAUDE_PROJECT_DIR="$tmp" bash "$batch" "${@:2}"; }
out="$(bat 'grep -rn foo --include=*.md .; echo ====' "$exit_guard" "$target")"
check jq -e '.hookSpecificOutput.updatedInput.command == "grep -rn foo --include=\"*.md\" .; echo \"====\"" and .hookSpecificOutput.updatedInput.timeout == 123 and (.hookSpecificOutput.additionalContext | contains("採用しました"))' <<< "$out" >/dev/null
for decision in deny ask; do
  jq -nc --arg d "$decision" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:"other-guard"}}' > "$tmp/verdict.json"
  printf '#!/usr/bin/env bash\ncat >/dev/null\ncat %q\n' "$tmp/verdict.json" > "$tmp/verdict.sh"
  out="$(bat 'echo ====' "$target" "$tmp/verdict.sh")"
  check test "$(jq -r '.hookSpecificOutput.permissionDecision' <<< "$out")" = "$decision"
done
# 再検査で初めて deny するガード（書き換え後の綴りにだけ当たる）。
cat > "$tmp/recheck.sh" <<'SH'
#!/usr/bin/env bash
input="$(cat)"
case "$(jq -r '.tool_input.command' <<< "$input")" in
  *'"===="'*) jq -n '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"rechecked-deny"}}' ;;
esac
SH
out="$(bat 'echo ====' "$target" "$tmp/recheck.sh")"
check jq -e '.hookSpecificOutput.permissionDecision == "deny" and .hookSpecificOutput.updatedInput == null and (.hookSpecificOutput.permissionDecisionReason | contains("rechecked-deny"))' <<< "$out" >/dev/null
# 終了コードガードと別々の書き換え案を出す形は競合として止める。
out="$(bat 'printf ok --include=*.md | tail -1; echo rc=$?' "$exit_guard" "$target")"
check is_deny "$out"
# R9 書き換えヘルパ関数の不在は書き換えず従来の deny へ戻る。走査 awk の失敗は書き換えより手前の判定不能 deny で止まる。
cp -R "$root/hooks" "$tmp/hooks"; mkdir -p "$tmp/tests/lib"; cp "$root/tests/lib/"*.sh "$tmp/tests/lib/"
printf '\nunset -f ff_zsh_equals_fix_scan\n' >> "$tmp/tests/lib/zsh-glob-nomatch.sh"
out="$(payload 'grep --include=*.md .' | env SHELL=/bin/zsh CLAUDECODE=1 CLAUDE_PROJECT_DIR="$tmp" bash "$tmp/hooks/guard-zsh-glob.sh")"
check is_deny "$out"
out="$(run 'grep --include=*.md .' FF_ZSH_GLOB_AWK=false)"
check is_deny "$out"
echo "zsh rewrite: $pass checks passed"
