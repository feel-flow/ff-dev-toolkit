#!/usr/bin/env bash
# WSL シェル本文ガード（hooks/guard-wsl-shell.sh / tests/lib/wsl-shell-scan.sh）の検査。Issue `#2341`。
# 入力はすべてコマンド文字列の fixture で、wsl も WSL も起動しない。MSYS の分岐は環境変数 OSTYPE で
# 通す（bash は環境の OSTYPE を上書きしない）。
# 空振り検出: hook / 判定 lib / 字句解析 lib / hooks.json の不在は suite が赤。判定 lib の不在・空・固定 clear 化と
# 登録削除をコピーで実測し、候補の判定不能 deny または陽性照合の赤を要求する。
# 変異検出（2026-10-26 WSL 実測。基準 70 件緑）: 判定を固定 clear にすると最初の陽性が赤、`--exec` / `-e` の素通しを外すと
# `--exec` の陰性が赤、hook のホスト判定を外すと linux-gnu のケースが赤、二重引用符の中の `\$` の検出を外すと
# `sh -c "echo \$HOME"` の陽性が赤、hooks.json の登録を外すと登録照合が赤、実行位置の探索から予約語と `timeout` を
# 外すと `for … do wsl …` の陽性が赤（どれも 1 件目で止まる）。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$ROOT/hooks/guard-wsl-shell.sh"
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"
isolate_hook_env "FF_DEV_TOOLKIT_SKIP_WSL_SHELL_GUARD" "$TARGET"
unset FF_WSL_SHELL_ACK
command -v jq >/dev/null || { echo 'jq required' >&2; exit 1; }
for file in "$TARGET" "$ROOT/tests/lib/wsl-shell-scan.sh" "$ROOT/tests/lib/review-shell-lex.sh" "$ROOT/hooks/hooks.json"; do
  [ -s "$file" ] || { echo "required guard resource missing: $file" >&2; exit 1; }
done
tmp="$(mktemp -d "${TMPDIR:-/tmp}/wsl-shell-guard.XXXXXX")"
REACHED_END=0
cleanup() {
  local rc=$?
  rm -rf "$tmp"
  if [ "$REACHED_END" -ne 1 ] && [ "$rc" -eq 0 ]; then rc=1; fi
  exit "$rc"
}
trap cleanup EXIT
PASS=0
fail() { echo "✗ $1" >&2; exit 1; }
payload() { jq -nc --arg c "$1" --arg cwd "$tmp" '{tool_name:"Bash",hook_event_name:"PreToolUse",tool_input:{command:$c},cwd:$cwd}'; }
# 第 2 引数で hook のコピーを、HOST_OSTYPE でホストを差し替える（既定は Windows の Git Bash）
run() { OUT="$(payload "$1" | env OSTYPE="${HOST_OSTYPE:-msys}" bash "${2:-$TARGET}")"; }
is_deny() { printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; }
deny_expected() {
  run "$1" "${2:-$TARGET}"
  is_deny || fail "止めるべき形を通した: $1"
  case "$OUT" in *判定不能*) fail "判定不能ではなく検出で止めるべき形: $1" ;; esac
  PASS=$((PASS+1))
}
unknown_expected() {
  run "$1" "${2:-$TARGET}"
  if is_deny; then
    case "$OUT" in *判定不能*) PASS=$((PASS+1)); return 0 ;; esac
  fi
  fail "判定不能で止めるべき形: $1（${OUT}）"
}
allow_expected() { run "$1"; [ -z "$OUT" ] || fail "通すべき形を止めた: $1（${OUT}）"; PASS=$((PASS+1)); }

# 陽性: $ が WSL 側の既定シェルで展開される形（OBS-353 の実例 3 形を含む）
for cmd in \
  "wsl -d Ubuntu -- bash -c 'x=1; echo \"\$x\"'" \
  "wsl.exe bash -lc 'set -e; d=/tmp/a; git clone u \"\$d\"'" \
  "MSYS2_ARG_CONV_EXCL='*' wsl -d Ubuntu -- bash -c 'run; echo \"rc=\$?\"'" \
  "wsl -d Ubuntu -- sh -c \"echo \\\$HOME\"" \
  "/c/Windows/System32/wsl.exe -- bash -c 'echo \$1'" \
  "cd /tmp && wsl -- bash -c 'echo \$x'" \
  "true; wsl -- bash -c 'echo \$x' | tail -1" \
  "WSL.EXE -- BASH -xc 'echo \$x'" \
  "wsl --shell-type login -- bash -c 'echo \$x'" \
  "wsl -u root --cd /tmp -- /bin/bash -c 'echo \$x'" \
  "wsl -- bash -l -c 'echo \$x'" \
  "wsl -- bash -o pipefail -c 'echo \$x'" \
  "env FOO=1 wsl -- bash -c 'echo \$x'" \
  "wsl -- bash -c \$'echo \$x'" \
  "wsl -- bash -c 'a'\"\\\$b\"" \
  "2>/dev/null wsl -- bash -c 'echo \$x' > out.txt" \
  "wsl -- sh.exe -c 'echo \${x:-d}'" \
  "for d in a; do wsl -- bash -c 'echo \$x'; done" \
  "if wsl -- bash -c 'echo \$x'; then :; fi" \
  "while wsl -- bash -c 'test -n \$x'; do :; done" \
  "( wsl -- bash -c 'echo \$x' )" \
  "{ wsl -- bash -c 'echo \$x'; }" \
  "! wsl -- bash -c 'echo \$x'" \
  "timeout 60 wsl -- bash -c 'echo \$x'" \
  "timeout -k 5 60 wsl -- bash -c 'echo \$x'" \
  "wsl -- bash --rcfile /x -c 'echo \$x'" \
  "true
wsl -- bash -c 'echo \$x'" \
  "wsl -- bash \\
  -c 'echo \$x'" \
  "wsl -- bash -c 'echo \$x'"$'\r' \
  "FF_WSL_SHELL_ACK=0 wsl -- bash -c 'echo \$x'" \
  "FF_WSL_SHELL_ACK=10 wsl -- bash -c 'echo \$x'"; do
  deny_expected "$cmd"
done

# 陰性: 展開されない形・wsl を実行しない形。次の 3 つは同じ仕組みで壊れうるが対象外として固定する —
# `"$(cat s.sh)"` / バッククォート（展開結果の `$` は静的に見えない既知の限界）、`bash script.sh '$x'`
# （`-c` 無しの引数は AC の対象外。deny 文は `--exec` を案内する）、`python3 -c`（bash / sh 以外）
for cmd in \
  "wsl.exe --exec sh -c 'echo \"\$1\"' sh hello" \
  "wsl -d Ubuntu -e sh -c 'echo \$x' sh" \
  "wsl --shell-type none sh -c 'echo \$x'" \
  "wsl.exe -- bash /mnt/c/x/script.sh \$HOME" \
  "wsl -- bash -c 'echo plain'" \
  "wsl -- bash -c \"echo \$HOME\"" \
  "wsl -- bash -c \"\$(cat s.sh)\"" \
  "wsl -- bash -c \`cat s.sh\`" \
  "wsl -- bash script.sh '\$x'" \
  "wsl -- python3 -c 'print(\"\$x\")'" \
  "wsl --list --verbose; echo \$?" \
  "echo \"wsl -- bash -c '\$x'\"" \
  "# wsl -- bash -c '\$x'" \
  "cat <<'EOF'
wsl -- bash -c '\$x'
EOF" \
  "grep wsl notes.md '\$x'" \
  "bash -c 'echo \$x' # wsl" \
  "FF_WSL_SHELL_ACK=1 wsl -- bash -c 'echo \$x'" \
  "  FF_WSL_SHELL_ACK=1 wsl -- bash -c 'echo \$x'"; do
  allow_expected "$cmd"
done

# 判定不能: 候補で引用符が閉じない
unknown_expected "wsl -- bash -c 'echo \$x"

# MSYS / Cygwin 以外のホストでは何もしない（AC3）。Cygwin は MSYS と同じく止める
# （空の OSTYPE は Windows では子プロセスへ渡らず bash が msys を入れ直すので、fixture にしない）
for host in linux-gnu darwin23; do
  HOST_OSTYPE="$host" run "wsl -- bash -c 'echo \$x'"
  [ -z "$OUT" ] || fail "MSYS 以外のホスト（${host}）で止めた"
  PASS=$((PASS+1))
done
HOST_OSTYPE=cygwin run "wsl -- bash -c 'echo \$x'"
is_deny || fail 'Cygwin で止めない'
PASS=$((PASS+1))

# 抜け道と対象外の入力
OUT="$(payload "wsl -- bash -c 'echo \$x'" | env OSTYPE=msys FF_DEV_TOOLKIT_SKIP_WSL_SHELL_GUARD=1 bash "$TARGET")"
[ -z "$OUT" ] || fail 'SKIP 変数でガードが止まらない'
OUT="$(printf 'not JSON wsl $x' | env OSTYPE=msys bash "$TARGET")"; [ -z "$OUT" ] || fail '不正 JSON を止めた'
OUT="$(jq -nc '{tool_name:"Read",tool_input:{command:"wsl -- bash -c '"'"'$x'"'"'"}}' | env OSTYPE=msys bash "$TARGET")"
[ -z "$OUT" ] || fail 'Bash 以外のツールを止めた'
PASS=$((PASS+3))

# 早期 return はすべてパイプ容量より大きい入力を読み切る（ACE-1331-1）
. "$SCRIPT_DIR/../lib/asdd-gate-drain.sh"
big="$(ff_asdd_big_payload "$(payload "wsl -- bash -c 'echo \$x'")")"
ff_asdd_drain_probe "$TARGET" "$big" "$tmp" OSTYPE=msys FF_DEV_TOOLKIT_SKIP_WSL_SHELL_GUARD=1
[ "$FF_ASDD_DRAIN_RC" -eq 0 ] && [ -z "$FF_ASDD_DRAIN_OUT" ] || fail 'SKIP 時に入力を読み切らない'
ff_asdd_drain_probe "$TARGET" "$big" "$tmp" OSTYPE=linux-gnu
[ "$FF_ASDD_DRAIN_RC" -eq 0 ] && [ -z "$FF_ASDD_DRAIN_OUT" ] || fail '非 MSYS で入力を読み切らない'
mkdir -p "$tmp/no-jq"
ff_asdd_drain_probe "$TARGET" "$big" "$tmp" OSTYPE=msys PATH="$tmp/no-jq"
[ "$FF_ASDD_DRAIN_RC" -eq 0 ] && [ -z "$FF_ASDD_DRAIN_OUT" ] || fail 'jq 不在で入力を読み切らない'
ff_asdd_fixture "$tmp/off" false
ff_asdd_gate_rc "$ROOT" "$tmp/off" hooks
[ "$FF_ASDD_GATE_RC" -eq 3 ] || fail 'ASDD の hooks 無効 fixture が rc 3 にならない'
ff_asdd_drain_probe "$TARGET" "$big" "$tmp/off" OSTYPE=msys
[ "$FF_ASDD_DRAIN_RC" -eq 0 ] && [ -z "$FF_ASDD_DRAIN_OUT" ] || fail 'ASDD 無効時に入力を読み切らない'
PASS=$((PASS+4))

# ASDD の設定を検証できない（config あり・node 不在）回は、候補を判定不能の deny にする
mkdir -p "$tmp/asdd-nonode" "$tmp/jq-only-bin"
ff_asdd_fixture "$tmp/asdd-nonode" true
ln -s "$(command -v jq)" "$tmp/jq-only-bin/jq" 2>/dev/null || cp "$(command -v jq)" "$tmp/jq-only-bin/jq"
if PATH="$tmp/jq-only-bin:/usr/bin:/bin" command -v node >/dev/null 2>&1; then
  echo "  ○ skip: /usr/bin か /bin に node があるため ASDD 検証不能（node 不在）の経路は未検査"
else
  OUT="$(cd "$tmp/asdd-nonode" && payload "wsl -- bash -c 'echo \$x'" | env OSTYPE=msys PATH="$tmp/jq-only-bin:/usr/bin:/bin" /bin/bash "$TARGET" 2>/dev/null)" || true
  case "$OUT" in *'"deny"'*ASDD*) PASS=$((PASS+1)) ;; *) fail "ASDD 検証不能で候補を止めない（${OUT}）" ;; esac
fi

# 登録: Bash matcher の集約入口に載っている。削除した写しは照合が落ちる
registered() { jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command | contains("guard-wsl-shell.sh"))' "$1" >/dev/null; }
registered "$ROOT/hooks/hooks.json" || fail 'hooks.json の Bash 集約入口に登録されていない'
jq '(.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command) |= gsub("[^ ]*guard-wsl-shell.sh[^ ]*"; "")' "$ROOT/hooks/hooks.json" > "$tmp/hooks.json"
if registered "$tmp/hooks.json"; then fail '登録削除の変異が照合をすり抜けた'; fi
PASS=$((PASS+2))

# 判定 lib の故障は候補だけを判定不能で止める。固定 clear の写しは陽性照合を失う
mkdir -p "$tmp/plugin/hooks" "$tmp/plugin/tests/lib"
cp "$TARGET" "$ROOT/hooks/asdd-hook-gate.sh" "$tmp/plugin/hooks/"
cp "$ROOT/tests/lib/review-shell-lex.sh" "$ROOT/tests/lib/wsl-shell-scan.sh" "$tmp/plugin/tests/lib/"
copy="$tmp/plugin/hooks/guard-wsl-shell.sh"
scan="$tmp/plugin/tests/lib/wsl-shell-scan.sh"
deny_expected "wsl -- bash -c 'echo \$x'" "$copy"
: > "$scan"
unknown_expected "wsl -- bash -c 'echo \$x'" "$copy"
rm -f "$scan"
unknown_expected "wsl -- bash -c 'echo \$x'" "$copy"
run "wsl -- bash -c 'echo plain'" "$copy"
[ -z "$OUT" ] || fail '判定 lib の故障で候補でない呼び出しまで止めた'
PASS=$((PASS+1))
printf '%s\n' 'ff_wsl_shell_scan() { echo clear; }' > "$scan"
run "wsl -- bash -c 'echo \$x'" "$copy"
# 固定 clear の判定は陽性を失うので、陽性照合（deny_expected）はこの写しで赤になる
if is_deny; then fail '固定 clear の写しが判定へ届いていない'; fi
PASS=$((PASS+1))
# 字句解析 lib の故障も候補だけを判定不能で止める
cp "$ROOT/tests/lib/wsl-shell-scan.sh" "$scan"
lex="$tmp/plugin/tests/lib/review-shell-lex.sh"
: > "$lex"
unknown_expected "wsl -- bash -c 'echo \$x'" "$copy"
printf '%s\n' '# no functions' > "$lex"
unknown_expected "wsl -- bash -c 'echo \$x'" "$copy"
echo "guard-wsl-shell: all $PASS checks passed"
REACHED_END=1
