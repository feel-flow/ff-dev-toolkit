#!/usr/bin/env bash
# Credential display guard: all inputs are literal commands; none are executed.
# 空振り検出: hook/scanner/hooks.json 不在は suite が赤。scanner の不在・空・固定 clear 化・不正構文と登録削除をコピーで実測し、候補の拒否または陽性照合の赤を要求する。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$ROOT/hooks/guard-credential-output.sh"
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"
isolate_hook_env "FF_DEV_TOOLKIT_SKIP_CREDENTIAL_OUTPUT_GUARD" "$TARGET"
unset FF_CREDENTIAL_OUTPUT_ACK
command -v jq >/dev/null || { echo 'jq required' >&2; exit 1; }
for file in "$TARGET" "$ROOT/tests/lib/credential-output-scan.awk" "$ROOT/hooks/hooks.json"; do
  [ -s "$file" ] || { echo 'required guard resource missing' >&2; exit 1; }
done
tmp="$(mktemp -d "${TMPDIR:-/tmp}/credential-guard.XXXXXX")"
REACHED_END=0
cleanup() {
  local rc=$?
  rm -rf "$tmp"
  if [ "$REACHED_END" -ne 1 ] && [ "$rc" -eq 0 ]; then rc=1; fi
  exit "$rc"
}
trap cleanup EXIT
PASS=0
payload() { jq -nc --arg c "$1" --arg cwd "$tmp" '{tool_name:"Bash",hook_event_name:"PreToolUse",tool_input:{command:$c},cwd:$cwd}'; }
run() { OUT="$(payload "$1" | bash "${2:-$TARGET}")"; }
deny_expected() {
  run "$1" "${2:-$TARGET}"
  printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
  PASS=$((PASS+1))
}
allow_expected() { run "$1"; [ -z "$OUT" ]; PASS=$((PASS+1)); }
for file in '~/.npmrc' '~/.netrc' '~/.pypirc' '~/.aws/credentials' '~/.docker/config.json' '~/.config/gh/hosts.yml' '~/.pnpmrc' '~/.config/pnpm/rc' '$PNPM_HOME/rc' '$XDG_CONFIG_HOME/pnpm/rc' '~/.git-credentials' '~/.NPMRC'; do
  deny_expected "cat $file"
done
for cmd in \
  'cat ~/.npmrc | grep -v token' \
  'grep -vi token ~/.npmrc' \
  'grep -vf ~/.npmrc README.md' \
  'grep -n registry ~/.npmrc' \
  'rg -n registry ~/.npmrc' \
  'grep -e registry "$HOME/.npmrc"' \
  'grep -f ~/.npmrc README.md' \
  'grep --file=$HOME/.npmrc README.md' \
  'sed -n "1,20p" ${HOME}/.npmrc' \
  'awk "{print}" /tmp/example/.netrc' \
  'less -- ~/.npmrc' \
  'head -n 3 ~/.npmrc' \
  'tail -10 ~/.npmrc' \
  'cut -d= -f1 ~/.npmrc' \
  'cat ~/.npmrc | cut -d= -f1' \
  "sed 's/=.*//' ~/.netrc" \
  'jq . ~/.docker/config.json' \
  'command /bin/cat "$HOME"/.npmrc' \
  'env LC_ALL=C cat ~/.npmrc' \
  'sudo -u example cat ~/.npmrc' \
  'cat < ~/.npmrc' \
  'cat "/tmp/日本語/.npmrc"' \
  'cat /tmp/日本語/.npmrc' \
  '< ~/.npmrc' \
  '< ~/.npmrc | grep token' \
  '2>/dev/null cat ~/.npmrc' \
  '2>&1 cat ~/.npmrc' \
  'cat <<< "$(< ~/.npmrc)"' \
  'cat ~/.n"p"mrc' \
  "cat ~/.n'p'mrc" \
  'cat ~/.np\mrc' \
  'timeout 5 cat ~/.npmrc' \
  'timeout --signal TERM --kill-after 3s 5s cat ~/.npmrc' \
  '< ~/.npmrc cat' \
  'cat ~/.aws//credentials' \
  'cat ~/.aws/./credentials' \
  'echo `cat ~/.npmrc`' \
  'grep registry < ~/.npmrc' \
  'cat /tmp/.npmrc > /tmp/redacted' \
  "bash -lc 'cat ~/.npmrc'" \
  'printf "%s" "$(cat ~/.npmrc)"' \
  'if true; then cat ~/.npmrc; fi' \
  'FF_CREDENTIAL_OUTPUT_ACK=0 cat ~/.npmrc' \
  'echo FF_CREDENTIAL_OUTPUT_ACK=1; cat ~/.npmrc'; do
  deny_expected "$cmd"
  case "$OUT" in *判定不能*) echo 'positive case was not scanned' >&2; exit 1 ;; esac
done
for cmd in \
  'npm config get registry' \
  'pnpm config get registry' \
  'git status --short' \
  'cat README.md' \
  '< README.md' \
  'cat docs/npmrc.md' \
  'echo "cat ~/.npmrc"' \
  'echo "設定の例: ~/.npmrc"' \
  'printf "%s" "cat ~/.netrc"' \
  'grep npmrc README.md' \
  'grep -e ~/.npmrc README.md' \
  'sed "s/.npmrc/example/" README.md' \
  'ls -l ~/.npmrc' \
  'test -f ~/.npmrc' \
  'cat README.md > ~/.npmrc' \
  'FF_CREDENTIAL_OUTPUT_ACK=1 cat ~/.npmrc' \
  $'git commit -m "$(cat <<\047EOF\047\nfix: don\047t print config.json\nEOF\n)"' \
  $'gh pr create --body "$(cat <<\047EOF\047\n1) pnpm registry\nEOF\n)"' \
  $'echo "$(cat <<\047EOF\047\n$(cat ~/.npmrc)\nEOF\n)"' \
  '# cat ~/.npmrc' \
  $'cat > /tmp/example <<\047EOF\047\ncat ~/.npmrc\nEOF\n'; do
  allow_expected "$cmd"
done
deny_expected $'bash <<\047EOF\047\ncat ~/.npmrc\nEOF\n'
deny_expected $'cat <<EOF\n$(cat ~/.npmrc)\nEOF\n'
deny_expected $'cat <<ONE <<\047TWO\047\n$(cat ~/.npmrc)\nONE\ndata\nTWO\n'
deny_expected $'echo "$(cat <<\047EOF\047\n1) pnpm registry\nEOF\ncat ~/.npmrc\n)"'
allow_expected $'cat <<\047EOF\047\n$(cat ~/.npmrc)\nEOF\n'
deny_expected 'cat "~/.npmrc'
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecisionReason | contains("判定不能")' >/dev/null

# Secrets in a command must not be echoed, including when parsing fails.
deny_expected 'cat ~/.npmrc; echo CANARY_SECRET_2325'
case "$OUT" in *CANARY_SECRET_2325*|*'cat ~/.npmrc'*|*'cut -d='*) exit 1 ;; esac
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecisionReason | contains("npm config get registry")' >/dev/null
OUT="$(payload 'cat ~/.npmrc' | FF_DEV_TOOLKIT_SKIP_CREDENTIAL_OUTPUT_GUARD=1 bash "$TARGET")"
[ -z "$OUT" ]
OUT="$(printf 'not JSON .npmrc' | bash "$TARGET")"; [ -z "$OUT" ]
OUT="$(jq -nc '{tool_name:"Read",tool_input:{command:"cat ~/.npmrc"}}' | bash "$TARGET")"; [ -z "$OUT" ]
PASS=$((PASS+3))

# Every early exit drains a payload larger than a pipe buffer.
. "$SCRIPT_DIR/../lib/asdd-gate-drain.sh"
big="$(ff_asdd_big_payload "$(payload 'cat ~/.npmrc')")"
ff_asdd_drain_probe "$TARGET" "$big" "$tmp" FF_DEV_TOOLKIT_SKIP_CREDENTIAL_OUTPUT_GUARD=1
[ "$FF_ASDD_DRAIN_RC" -eq 0 ] && [ -z "$FF_ASDD_DRAIN_OUT" ]
mkdir -p "$tmp/no-jq"
ff_asdd_drain_probe "$TARGET" "$big" "$tmp" PATH="$tmp/no-jq"
[ "$FF_ASDD_DRAIN_RC" -eq 0 ] && [ -z "$FF_ASDD_DRAIN_OUT" ]
ff_asdd_fixture "$tmp/off" false
ff_asdd_gate_rc "$ROOT" "$tmp/off" hooks
[ "$FF_ASDD_GATE_RC" -eq 3 ]
ff_asdd_drain_probe "$TARGET" "$big" "$tmp/off"
[ "$FF_ASDD_DRAIN_RC" -eq 0 ] && [ -z "$FF_ASDD_DRAIN_OUT" ]
PASS=$((PASS+3))

registered() { jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command | contains("guard-credential-output.sh"))' "$1" >/dev/null; }
registered "$ROOT/hooks/hooks.json"
jq '(.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command) |= gsub("[^ ]*guard-credential-output.sh[^ ]*"; "")' "$ROOT/hooks/hooks.json" > "$tmp/hooks.json"
if registered "$tmp/hooks.json"; then echo 'registration mutation survived' >&2; exit 1; fi
PASS=$((PASS+2))

mkdir -p "$tmp/plugin/hooks" "$tmp/plugin/tests/lib"
cp "$TARGET" "$ROOT/hooks/asdd-hook-gate.sh" "$tmp/plugin/hooks/"
copy="$tmp/plugin/hooks/guard-credential-output.sh"
scan="$tmp/plugin/tests/lib/credential-output-scan.awk"
deny_expected 'cat ~/.npmrc' "$copy"
: > "$scan"
deny_expected 'cat ~/.npmrc' "$copy"
printf '%s\n' 'BROKEN {' > "$scan"
deny_expected 'cat ~/.npmrc' "$copy"
printf '%s\n' 'END {print "clear"}' > "$scan"
run 'cat ~/.npmrc' "$copy"
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null; then
  echo 'clear mutation did not reach detector' >&2; exit 1
fi
# A constant-clear scanner loses the positive oracle, so the contract check is red.
[ -z "$OUT" ]; PASS=$((PASS+1))
echo "credential-output: all $PASS checks passed"
REACHED_END=1
