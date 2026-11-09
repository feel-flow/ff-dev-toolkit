#!/usr/bin/env bash
# Issue `#2136`: 検索パスの無い rg（ripgrep）が非 TTY の標準入力を読み続けて無言で止まる形を、
# hooks/guard-exit-code.sh（判定は tests/lib/rg-stdin-scan.sh）が実行前に止めることを固定する。
# verify.sh の末尾から呼ばれ、単独でも回せる。
#
#   RF / RN. 回避形の deny / allow 行列（TESTING.md「コマンド文字列ガードの回避形行列」の軸）
#   RA. 抜け道（先頭に並ぶ代入の FF_RG_STDIN_ACK=1）と、先頭以外・引用値の中の ACK
#   RC. 判定不能（ヘルパ不在・awk 失敗・完了印なし・未終端）は rg の起動語を含む呼び出しに限り deny
#   RP. 性質の実測（rg と timeout があれば: 開いたままのパイプを標準入力にすると検索パス無しは返らない）
#   RM. 変異検出
#
# 空振り検出: 判定ヘルパの不在（対象の不在）・awk の失敗（FF_RG_STDIN_AWK=false）・awk が何も出さずに 0 で終わる（FF_RG_STDIN_AWK=true。完了印が無い）・関数が無い（名前だけ残って中身が変わる）のいずれでも、rg の起動語を含む呼び出しは素通しではなく判定不能の deny になり RC1〜RC4 が要求する。常に 0 件を返すヘルパでは RF 系がすべて素通しになり RM1 が赤を要求する（実測 2026-11-02 Windows Git Bash）。
# 変異検出: パイプの受け側・標準入力のリダイレクトの除外（pin / rin の return）を消すと RN の受け側・リダイレクトの行が deny になり（RM2）、hook の前置フィルタから rg を外すと RF2 が素通しになり（RM3）、生の入力（JSON）で改行の escape（\n）の後ろを区切りに数えないと改行の後ろの rg が素通しになる（RM4。いずれも実測 2026-11-02）。command -v / -V の除外を消すと RN の command -v rg jq が（RM5）、パターンの無い rg の除外を消すと RN の rg（引数なし）が deny になる（RM6。レビュー 1 巡目の対応後に実測）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$PLUGIN_ROOT/hooks/guard-exit-code.sh"
# shellcheck source=../lib/adapter-env-isolation.sh
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"
isolate_hook_env "FF_DEV_TOOLKIT_SKIP" "$TARGET"
RG_LIB="$PLUGIN_ROOT/tests/lib/rg-stdin-scan.sh"
[ -f "$TARGET" ] || { echo "✗ guard-exit-code.sh が見つかりません: $TARGET" >&2; exit 1; }
[ -f "$RG_LIB" ] || { echo "✗ rg-stdin-scan.sh が見つかりません: $RG_LIB" >&2; exit 1; }
if ! command -v jq >/dev/null 2>&1; then
  echo "○ skip: jq が見つからないためスキップ（rg-stdin は未検査のままです）"
  exit 0
fi
unset FF_RG_STDIN_ACK FF_RG_STDIN_AWK FF_EXIT_CODE_ACK FF_TIMEOUT_ACK FF_UNBOUNDED_WAIT_ACK

if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/ff-rg-stdin.XXXXXX" 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
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
    echo "✗ rg-stdin: 最後まで到達しませんでした" >&2
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
OUT=""
RC=0
DECISION=""
REASON=""

run_on() { # <hook> <command> [NAME=VALUE ...]
  local hook="$1" cmd="$2" json
  shift 2
  json="$(jq -n --arg c "$cmd" --arg d "$TEST_TMP" \
    '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d, hook_event_name: "PreToolUse"}')"
  RC=0
  OUT="$(printf '%s' "$json" | env "$@" bash "$hook" 2>/dev/null)" || RC=$?
  DECISION="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)"
  REASON="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || true)"
}
run_hook() { run_on "$TARGET" "$@"; }
assert_fire() { # <label>
  if [ "$RC" -eq 0 ] && [ "$DECISION" = deny ]; then
    case "$REASON" in
      *'rg の標準入力待ち'*'判定不能'*) bad "$1: 検出ではなく判定不能で止まった: [$REASON]" ;;
      *'rg の標準入力待ち'*) ok "$1" ;;
      *) bad "$1: rg ではない理由で止まった: [$REASON]" ;;
    esac
  else
    bad "$1: exit=$RC decision=[$DECISION] out=[$OUT]"
  fi
}
assert_pass() { # <label>
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "$1"; else bad "$1: exit=$RC out=[$OUT]"; fi
}
assert_unavailable() { # <label>
  if [ "$RC" -eq 0 ] && [ "$DECISION" = deny ]; then
    case "$REASON" in
      *'rg の標準入力待ち'*'判定不能'*) ok "$1" ;;
      *) bad "$1: deny だが rg の判定不能の理由になっていない: [$REASON]" ;;
    esac
  else
    bad "$1: exit=$RC decision=[$DECISION] out=[$OUT]"
  fi
}

# 発火させる形（RF。各行はそのまま Bash ツールへ渡るコマンド文字列）
FIRE_CASES=(
  "rg -n 'pattern' --hidden -g '!node_modules'"
  'rg foo'
  'cd /tmp && rg foo'
  'true; rg foo'
  'true & rg foo'
  'x=$(rg -l foo)'
  'echo "$(rg foo)"'
  'echo `rg foo`'
  'diff <(rg foo) b'
  'rg -e foo'
  'rg --regexp=foo'
  'FOO=1 rg foo'
  'env FOO=1 rg foo'
  'command rg foo'
  'timeout 5 rg foo'
  'nice -n 5 rg foo'
  './vendor/bin/rg foo'
  $'true;\trg foo'
  $'echo a\nrg foo'
  'rg.exe foo'
  '"rg" foo'
  '\rg foo'
  $'rg \\\n  foo'
  'rg -tpy foo'
  "rg -g '*.md' foo"
  "rg --glob '*.md' foo"
  'rg -A 3 foo'
  'rg foo 2</dev/null'
  'rg foo >out.txt 2>&1'
  $'cat <<\'EOF\'\nrg foo .\nEOF\nrg bar'
  'if true; then rg foo; fi'
  'rg foo # FF_RG_STDIN_ACK=1'
)
# 素通しさせる形（RN）
PASS_CASES=(
  'rg foo .'
  'rg -n foo src docs'
  'rg -e foo src'
  'rg -e foo -e bar .'
  'rg -- -foo .'
  'rg --glob=*.md foo .'
  'echo x | rg foo'
  'echo x |& rg foo'
  'echo x | (rg foo)'
  'rg foo </dev/null'
  'rg foo 0</dev/null'
  "rg foo <<< 'abc'"
  $'rg foo <<\'EOF\'\nabc\nEOF'
  'rg --files'
  "rg --files -g '*.md'"
  'rg --type-list'
  'rg --version'
  'rg -V'
  'rg -h'
  'rg foo -'
  'echo rg foo'
  'grep -r rg .'
  'git merge rg'
  '# rg foo'
  "echo 'rg foo'"
  "git commit -m 'rg foo'"
  'xargs rg foo'
  'merge foo; args bar'
  # command -v / -V は名前の照会で rg を起動しない
  'command -v rg >/dev/null || echo missing'
  'if command -v rg >/dev/null 2>&1; then rg -n foo .; fi'
  'command -V rg'
  'command -pv rg'
  'command -v rg jq >/dev/null || echo missing'
  # パターンの無い rg は rc=2 で即座に終わり標準入力を読まない（ripgrep 14.1.1 で実測）
  'rg'
  'rg -n --hidden'
)

echo "rg-stdin: RF 発火（検索パスの無い rg）"
i=0
for c in "${FIRE_CASES[@]}"; do
  i=$((i + 1))
  run_hook "$c"
  assert_fire "RF${i}: deny [$(printf '%s' "$c" | tr '\n' ' ')]"
done
run_hook "${FIRE_CASES[0]}"
for needle in ' .' '</dev/null' 'FF_RG_STDIN_ACK=1' 'OBS-028' "rg -n pattern --hidden -g !node_modules"; do
  case "$REASON" in
    *"$needle"*) ok "RF1 の停止文が [$needle] を含む" ;;
    *) bad "RF1 の停止文に [$needle] が無い: [$REASON]" ;;
  esac
done

echo "rg-stdin: RN 素通し（検索パスあり・標準入力を受け取る・入力を読まない動作・rg の起動ではない）"
i=0
for c in "${PASS_CASES[@]}"; do
  i=$((i + 1))
  run_hook "$c"
  assert_pass "RN${i}: 素通し [$(printf '%s' "$c" | tr '\n' ' ')]"
done

echo "rg-stdin: RA 抜け道"
run_hook 'FF_RG_STDIN_ACK=1 rg foo'
assert_pass 'RA1: 先頭の FF_RG_STDIN_ACK=1 で通る'
run_hook 'LC_ALL=C FF_RG_STDIN_ACK=1 rg foo'
assert_pass 'RA2: 先頭に並ぶ代入のどれでもよい（FF_TIMEOUT_ACK と同じ単位）'
run_hook 'echo FF_RG_STDIN_ACK=1; rg foo'
assert_fire 'RA3: 先頭以外（別コマンドの引数）の ACK は無効'
run_hook "A='x FF_RG_STDIN_ACK=1'; rg foo"
assert_fire 'RA4: 引用値の中の ACK は無効'
run_hook 'FF_EXIT_CODE_ACK=1 rg foo'
assert_fire 'RA5: 別の検査の ACK（FF_EXIT_CODE_ACK）では通らない'

echo "rg-stdin: RC 判定不能（rg の起動語を含む呼び出しに限り fail-closed）"
make_tree() { # <dir>
  mkdir -p "$1/hooks" "$1/tests/lib"
  cp "$TARGET" "$PLUGIN_ROOT/hooks/asdd-hook-gate.sh" "$PLUGIN_ROOT/hooks/asdd-feature.mjs" "$1/hooks/"
  cp "$PLUGIN_ROOT/tests/lib/exit-code-guard.sh" "$PLUGIN_ROOT/tests/lib/heredoc-strip.sh" \
    "$PLUGIN_ROOT/tests/lib/wait-bounds.sh" "$PLUGIN_ROOT/tests/lib/exit-code-rewrite.sh" "$RG_LIB" "$1/tests/lib/"
}
NOLIB="$TEST_TMP/nolib"
make_tree "$NOLIB"
rm -f "$NOLIB/tests/lib/rg-stdin-scan.sh"
run_on "$NOLIB/hooks/guard-exit-code.sh" 'rg foo'
assert_unavailable 'RC1: 判定ヘルパが無い配置では rg の起動を判定不能の deny にする'
run_on "$NOLIB/hooks/guard-exit-code.sh" 'git status --short'
assert_pass "RC1': 判定ヘルパが無くても rg を含まない呼び出しは素通し"
run_on "$NOLIB/hooks/guard-exit-code.sh" 'FF_RG_STDIN_ACK=1 rg foo'
assert_pass "RC1'': 判定不能でも先頭の ACK で通れる（案内した抜け道が効く）"
run_hook 'rg foo' FF_RG_STDIN_AWK=false
assert_unavailable 'RC2: 走査の awk が失敗したら判定不能の deny にする'
run_hook 'rg foo' FF_RG_STDIN_AWK=true
assert_unavailable 'RC3: awk が何も出さずに 0 で終わる（完了印が無い）ときも判定不能の deny にする'
NOFN="$TEST_TMP/nofn"
make_tree "$NOFN"
printf '# 関数定義を失ったヘルパ\n' > "$NOFN/tests/lib/rg-stdin-scan.sh"
run_on "$NOFN/hooks/guard-exit-code.sh" 'rg foo'
assert_unavailable 'RC4: ヘルパに ff_rg_stdin_hits が無いときは判定不能の deny にする'
run_hook "rg 'foo"
assert_unavailable 'RC5: 引用が閉じないまま終わる rg の起動は走査未完了として判定不能の deny にする'
run_hook 'x=$(rg foo'
assert_unavailable 'RC6: 置換が閉じないまま終わる rg の起動も判定不能の deny にする'

echo "rg-stdin: RP 性質の実測（開いたままのパイプを標準入力にした rg）"
if command -v rg >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1 && command -v sleep >/dev/null 2>&1; then
  rp_dir="$TEST_TMP/rp"
  mkdir -p "$rp_dir"
  printf 'nothing here\n' > "$rp_dir/a.txt"
  rc_nopath=0; (cd "$rp_dir" && sleep 4 | timeout 2 rg zzz_rg_stdin_probe >/dev/null 2>&1) || rc_nopath=$?
  rc_path=0; (cd "$rp_dir" && sleep 4 | timeout 2 rg zzz_rg_stdin_probe . >/dev/null 2>&1) || rc_path=$?
  rc_null=0; (cd "$rp_dir" && sleep 4 | timeout 2 rg zzz_rg_stdin_probe </dev/null >/dev/null 2>&1) || rc_null=$?
  if [ "$rc_nopath" = 124 ] && [ "$rc_path" = 1 ] && [ "$rc_null" = 1 ]; then
    ok 'RP1: 検索パス無しは timeout まで返らず（124）、検索パス / </dev/null 付きは一致なし（1）で即座に返る'
  else
    bad "RP1: nopath=$rc_nopath path=$rc_path devnull=$rc_null"
  fi
else
  echo '  ○ skip: rg / timeout が PATH に無いため RP1（実処理系での性質）は未検査'
fi

echo "rg-stdin: RM 変異検出"
MUT="$TEST_TMP/mut"
make_tree "$MUT"
printf 'ff_rg_stdin_hits() { return 0; }\n' > "$MUT/tests/lib/rg-stdin-scan.sh"
m1=0
for c in "${FIRE_CASES[@]}"; do
  run_on "$MUT/hooks/guard-exit-code.sh" "$c"
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then m1=$((m1 + 1)); fi
done
if [ "$m1" -eq "${#FIRE_CASES[@]}" ]; then
  ok "RM1: 常に 0 件を返すヘルパ（0 件一致）では RF 系 ${m1} 件がすべて素通しになり、RF の検査が赤になる"
else
  bad "RM1: 0 件ヘルパで素通しになったのは ${m1}/${#FIRE_CASES[@]} 件"
fi
sed 's/^  if (pin\[id\] || rin\[id\]) return$/  pin[id] = pin[id]/' "$RG_LIB" > "$MUT/tests/lib/rg-stdin-scan.sh"
if cmp -s "$RG_LIB" "$MUT/tests/lib/rg-stdin-scan.sh"; then
  bad 'RM2: sed が当たらず変異が注入されていない（針が古い）'
else
  run_on "$MUT/hooks/guard-exit-code.sh" 'echo x | rg foo'
  rm2_pipe="$DECISION"
  run_on "$MUT/hooks/guard-exit-code.sh" 'rg foo </dev/null'
  if [ "$rm2_pipe" = deny ] && [ "$DECISION" = deny ]; then ok 'RM2: 受け側・リダイレクトの除外を消した変異は RN の受け側とリダイレクトを deny し、RN の検査が赤になる'; else bad "RM2: 変異が効いていない: pipe=[$rm2_pipe] redirect=[$DECISION]"; fi
fi
cp "$RG_LIB" "$MUT/tests/lib/rg-stdin-scan.sh"
sed 's/^  \*rg\*) rg_word_candidate /  *NO_SUCH_SPELLING_X*) rg_word_candidate /' "$TARGET" > "$MUT/hooks/guard-exit-code.sh"
if cmp -s "$TARGET" "$MUT/hooks/guard-exit-code.sh"; then
  bad 'RM3: sed が当たらず変異が注入されていない（針が古い）'
else
  run_on "$MUT/hooks/guard-exit-code.sh" "${FIRE_CASES[1]}"
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok 'RM3: hook の前置フィルタから rg を外した変異は RF2 を素通しし、RF の検査が赤になる（前置フィルタも針の一部）'; else bad "RM3: 変異が効いていない: decision=[$DECISION]"; fi
fi
cp "$TARGET" "$MUT/hooks/guard-exit-code.sh"
sed '/if (c == "command" \&\& cw\[id, k\] ~ /d' "$RG_LIB" > "$MUT/tests/lib/rg-stdin-scan.sh"
if cmp -s "$RG_LIB" "$MUT/tests/lib/rg-stdin-scan.sh"; then
  bad 'RM5: sed が当たらず変異が注入されていない（針が古い）'
else
  # 名前 1 つの command -v rg はパターンの無い rg の除外でも通るので、名前を 2 つ照会する形で測る
  run_on "$MUT/hooks/guard-exit-code.sh" 'command -v rg jq >/dev/null || echo missing'
  if [ "$DECISION" = deny ]; then ok 'RM5: command -v の除外を消した変異は RN の command -v rg jq を deny し、RN の検査が赤になる'; else bad "RM5: 変異が効いていない: out=[$OUT]"; fi
fi
sed '/if (!haspat \&\& pos == 0) return$/d' "$RG_LIB" > "$MUT/tests/lib/rg-stdin-scan.sh"
if cmp -s "$RG_LIB" "$MUT/tests/lib/rg-stdin-scan.sh"; then
  bad 'RM6: sed が当たらず変異が注入されていない（針が古い）'
else
  run_on "$MUT/hooks/guard-exit-code.sh" 'rg'
  if [ "$DECISION" = deny ]; then ok 'RM6: パターンの無い rg の除外を消した変異は RN の rg（引数なし）を deny し、RN の検査が赤になる'; else bad "RM6: 変異が効いていない: out=[$OUT]"; fi
fi
cp "$RG_LIB" "$MUT/tests/lib/rg-stdin-scan.sh"
sed 's/|\\\\\[nrt\])rg/)rg/' "$TARGET" > "$MUT/hooks/guard-exit-code.sh"
if cmp -s "$TARGET" "$MUT/hooks/guard-exit-code.sh"; then
  bad 'RM4: sed が当たらず変異が注入されていない（針が古い）'
else
  run_on "$MUT/hooks/guard-exit-code.sh" $'echo a\nrg foo'
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok 'RM4: 生の入力の \n の後ろを区切りに数えない変異は、改行の後ろの rg を素通しし、RF の検査が赤になる'; else bad "RM4: 変異が効いていない: decision=[$DECISION]"; fi
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ rg-stdin: ${FAIL} 件失敗（成功 ${PASS} 件）" >&2
  REACHED_END=1
  exit 1
fi
echo "✅ rg-stdin: all ${PASS} checks passed"
REACHED_END=1
exit 0
