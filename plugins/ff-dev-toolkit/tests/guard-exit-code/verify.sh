#!/usr/bin/env bash
# Runtime contract for the exit-code misread guard hook (observation ledger OBS-003, Count 7).
#
# 配布物 hooks/guard-exit-code.sh を stdin JSON で直接駆動し、受け入れ条件の各分岐を
# 固定する:
#   1. ゲート起動が診断で終端する形（実測された事故形）は実行前に deny し、
#      `rc=$?` → `exit $rc` の伝播形を**実値で**案内する
#   2. 診断で終端しない呼び出し（単体起動・`&&` 連結・推奨形）は無音で素通し（偽陽性なし）
#   3. 検出器が既に持つ除外形（入力供給パイプ・単一引用符の中の同型・引数として触るだけ）
#      は止めない
#   4. 判定できないときは素通しさせず、判定不能である旨を出して deny（fail-closed）。
#      ただし fail-closed の面は**候補コマンドに限る**（検出器が壊れても無関係な
#      Bash 呼び出しは止まらない ＝ 復旧作業が可能なままである）
#
# あわせて、この hook が**判定を複製していない**ことを構造的に固定する。判定を差し替え
# 可能な検出器スタブへ向けたコピーで、hook の verdict がスタブの出力にそのまま追随する
# ことを実測する。**ただしゲート名簿の綴りだけは hook 側にも写しがある**（候補の前置
# フィルタは検出器を source する前に走るため）。その綴りが検出器と一致していることは
# 静的照合で固定する — 一致が崩れると、足したゲート名は前置フィルタで無音 exit 0 に
# なり、走査面だけが静かに欠ける（セルフレビューで 3 者が独立に指摘した形）。
#
# 変異検出（2026-09-16 実測。赤転しなかった変異は無し）:
#   - fail-closed 分岐を `exit 0` へ倒したコピーは AC4 の deny 検査を赤にする
#   - heredoc 本文の読み飛ばしを無効化した共有ヘルパ（tests/lib/heredoc-strip.sh）の
#     コピーは「PR 本文は素通し」を赤にする
#   - ACK 抜け道の分岐を消したコピーは抜け道検査を赤にする
#   - 候補の前置フィルタを常に真にしたコピーは「検出器が壊れても非候補は素通し」を赤にする
#   - 未終端 heredoc の検出（共有ヘルパの awk END）を消したコピーは「引用符の中の << で
#     以降の行を捨てない」検査を赤にする
#   - ASDD ゲートの rc 読みを `|| exit 0` へ戻したコピーは「検証不能 × 候補は deny」を赤にする
#   （共有ヘルパを置かない / 中身を空にしたコピーの deny は変異ではなく AC4 の直接検査）
#   - 実値案の安全条件（区切りがちょうど 1 個）を外したコピーは「曖昧なら一般形」を赤にする
#
# run-all-required: no — jq 不在での skip を許容する（jq が無いと hook 自身が fail-open で
# 何もしないため、検査対象の振る舞いが存在しない）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$PLUGIN_ROOT/hooks/guard-exit-code.sh"
DETECTOR="$PLUGIN_ROOT/tests/lib/exit-code-guard.sh"
HELPER="$PLUGIN_ROOT/tests/lib/heredoc-strip.sh"
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"
# shellcheck source=../lib/asdd-gate-drain.sh
. "$SCRIPT_DIR/../lib/asdd-gate-drain.sh"

[ -f "$TARGET" ] || { echo "✗ guard-exit-code.sh が見つかりません: $TARGET" >&2; exit 1; }
[ -f "$DETECTOR" ] || { echo "✗ 検出器が見つかりません: $DETECTOR" >&2; exit 1; }
[ -f "$HELPER" ] || { echo "✗ heredoc 除去ヘルパが見つかりません: $HELPER" >&2; exit 1; }
[ -f "$HOOKS_JSON" ] || { echo "✗ hooks.json が見つかりません: $HOOKS_JSON" >&2; exit 1; }
if ! command -v jq >/dev/null 2>&1; then
  echo "○ skip: jq が見つからないためスキップ（guard-exit-code は未検査のままです）"
  exit 0
fi
JQ_BIN="$(command -v jq)"

if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/ff-guard-exit-code.XXXXXX" 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
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
    echo "✗ guard-exit-code: 最後まで到達しませんでした" >&2
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

# 検査で使うゲート綴り。検出器の名簿は basename が `run-all.sh` であることだけを見る。
GATE='bash /repo/plugins/ff-dev-toolkit/tests/run-all.sh'
# 一般形（実値案を出せないときのプレースホルダ）。hook 側の文言と一致させる。
GENERIC='<測りたいコマンド> > <ログ> 2>&1'

OUT=""
ERR=""
RC=0
DECISION=""
EVENT=""
REASON=""

run_hook_on() { # <hook-file> <command> [env NAME=VALUE]...
  local hook="$1" cmd="$2"
  shift 2
  local json
  json="$(jq -n --arg c "$cmd" --arg d "$TEST_TMP" \
    '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d, hook_event_name: "PreToolUse"}')"
  RC=0
  local errfile="$TEST_TMP/.stderr"
  if [ "$#" -gt 0 ]; then
    OUT="$(printf '%s' "$json" | env "$@" bash "$hook" 2>"$errfile")" || RC=$?
  else
    OUT="$(printf '%s' "$json" | bash "$hook" 2>"$errfile")" || RC=$?
  fi
  ERR="$(cat "$errfile" 2>/dev/null || true)"
  DECISION="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)"
  EVENT="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName // empty' 2>/dev/null || true)"
  REASON="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || true)"
}

run_hook() { # <command> [env NAME=VALUE]...
  local cmd="$1"
  shift
  run_hook_on "$TARGET" "$cmd" "$@"
}

# deny は「実行前に止まる」ことが要件なので、hookEventName まで見る。別イベント名だと
# ホストは permissionDecision を解釈せず、コマンドはそのまま実行される。
assert_fire() { # <label>
  if [ "$RC" -eq 0 ] && [ "$DECISION" = "deny" ] && [ "$EVENT" = "PreToolUse" ]; then
    ok "$1"
  else
    bad "$1: exit=$RC decision=[$DECISION] event=[$EVENT] out=[$OUT]"
  fi
}

assert_pass() { # <label>
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    ok "$1"
  else
    bad "$1: exit=$RC out=[$OUT]"
  fi
}

# 理由文の「終了コードを伝播させる形へ書き換えてください:」直後 2 行（書き換え形ブロック）。
fix_block() {
  printf '%s\n' "$REASON" | awk '
    /^終了コードを伝播させる形へ書き換えてください:$/ { grab = 2; next }
    grab > 0 { print; grab-- }
  '
}

assert_fix_concrete() { # <label> <期待する起動行>
  local got
  got="$(fix_block)"
  case "$got" in
    "  $2"*"rc=\$?; echo \"EXIT=\$rc\"; exit \$rc") ok "$1" ;;
    *) bad "$1: 書き換え形が期待と違う: [$got]" ;;
  esac
}

assert_fix_generic() { # <label>
  local got
  got="$(fix_block)"
  case "$got" in
    *"$GENERIC"*) ok "$1" ;;
    *) bad "$1: 一般形へ落ちていない（曖昧な切り出しを実値として案内している）: [$got]" ;;
  esac
}

# hook のコピーを「hooks/ と tests/lib/ が隣り合う」相対配置で作る。検出器の差し替え・
# 撤去を行う検査はすべてこのコピーの上で行い、配布物の実体には触れない。
make_copy() { # <dir> [detector-body-file|"" で検出器を置かない]
  local dir="$1" det="${2:-}"
  mkdir -p "$dir/hooks" "$dir/tests/lib"
  cp "$TARGET" "$dir/hooks/guard-exit-code.sh"
  cp "$PLUGIN_ROOT/hooks/asdd-hook-gate.sh" "$dir/hooks/"
  cp "$PLUGIN_ROOT/hooks/asdd-feature.mjs" "$dir/hooks/"
  # heredoc 除去ヘルパは hook が `hooks/../tests/lib/` から source する（共有ヘルパ）。
  # 置かないコピーは「ヘルパ不在 = fail-closed」の検査そのものになる。
  cp "$HELPER" "$dir/tests/lib/heredoc-strip.sh"
  if [ -n "$det" ]; then cp "$det" "$dir/tests/lib/exit-code-guard.sh"; fi
  printf '%s' "$dir/hooks/guard-exit-code.sh"
}

echo "guard-exit-code: AC1 — 実測された事故形（ゲート起動が診断で終端する）を deny"
run_hook "FF_RUN_ALL_FULL=1 $GATE > /tmp/runall2.txt 2>&1; echo \"run-all rc=\$?\""
assert_fire "2026-09-15 に実測された形（; echo \"run-all rc=\$?\"）を deny"
run_hook "$GATE 2>&1 | tail -20"
assert_fire "末尾 | tail で終端する形を deny"
run_hook "$GATE > log 2>&1 || true"
assert_fire "|| true で握り潰す形を deny"
run_hook "$GATE > log 2>&1; exit 0"
assert_fire "; exit 0 で握り潰す形を deny"
run_hook "$GATE > log 2>&1; tail -25 log"
assert_fire "裸の tail で終端する形を deny"
run_hook 'npm test 2>&1 | tail -20; echo "EXIT=$?"'
assert_fire "フィルタ終端の直後で \$? を読む形（pipe-exit-read）を deny"
run_hook 'npm test | tee log; echo "${PIPESTATUS[0]}"'
assert_fire "PIPESTATUS 参照（zsh で空へ展開）を deny"

echo "guard-exit-code: AC1 — 案内は実値（検出した形と、伝播させる書き換え形）"
run_hook "FF_RUN_ALL_FULL=1 $GATE > /tmp/runall2.txt 2>&1; echo \"run-all rc=\$?\""
case "$REASON" in
  *"FF_RUN_ALL_FULL=1 $GATE > /tmp/runall2.txt 2>&1"*) ok "理由文が検出した実コマンドを引用する" ;;
  *) bad "理由文に実コマンドが無い: [$REASON]" ;;
esac
assert_fix_concrete "書き換え形が実値（起動部分 + rc 伝播）で出る" "FF_RUN_ALL_FULL=1 $GATE > /tmp/runall2.txt 2>&1"
case "$REASON" in
  *"$GENERIC"*) bad "実値を出せる形なのに一般形のプレースホルダへ退化している: [$REASON]" ;;
  *) ok "実値を出せる形では一般形のプレースホルダを出さない" ;;
esac
case "$REASON" in
  *gate-exit-swallowed*) ok "理由文が検出タグを名指しする" ;;
  *) bad "理由文に検出タグが無い: [$REASON]" ;;
esac
case "$REASON" in
  *FF_EXIT_CODE_ACK=1*) ok "理由文が ACK 抜け道を案内する" ;;
  *) bad "理由文に ACK 抜け道の案内が無い: [$REASON]" ;;
esac
case "$REASON" in
  *FF_DEV_TOOLKIT_SKIP_EXIT_CODE_GUARD=1*) ok "理由文がガード無効化 env を案内する" ;;
  *) bad "理由文に skip env の案内が無い: [$REASON]" ;;
esac
case "$REASON" in
  *tests/lib/exit-code-guard.sh*) ok "理由文が判定の正本（検出器）の所在を示す" ;;
  *) bad "理由文に検出器の所在が無い: [$REASON]" ;;
esac
case "$REASON" in
  */hooks/../*) bad "理由文のパスが hooks/../ を畳めていない: [$REASON]" ;;
  *) ok "理由文のパスは hooks/../ を畳んである" ;;
esac

echo "guard-exit-code: AC1 — タグごとに直し方が変わる（汎用文へ退化しない）"
run_hook 'npm test 2>&1 | tail -20; echo "EXIT=$?"'
case "$REASON" in
  *ACE-259-3*) ok "pipe-exit-read はフィルタの rc を読んでいる旨を名指しする" ;;
  *) bad "pipe-exit-read の案内が汎用文へ退化している: [$REASON]" ;;
esac
run_hook 'npm test | tee log; echo "${PIPESTATUS[0]}"'
case "$REASON" in
  *zsh*) ok "pipestatus は zsh で機能しない旨を名指しする" ;;
  *) bad "pipestatus の案内が汎用文へ退化している: [$REASON]" ;;
esac

echo "guard-exit-code: AC1 — 曖昧な切り出しでは実値案を出さない（誤った案内を出さない）"
run_hook "cd /repo && $GATE > log 2>&1; echo done"
assert_fire "cd 前置 + && のゲート起動が診断で終端する形を deny"
assert_fix_concrete "前置の cd と && を保ったまま案内する（ゲートが案内から消えない）" "cd /repo && $GATE > log 2>&1"
run_hook "$GATE > log 2>&1; echo \"done;now \$?\""
assert_fire "引用符の中に区切り子がある形も deny"
assert_fix_generic "引用符の中の ; で切り出しが割れる形は一般形へ落とす"
run_hook "x=1; $GATE > log 2>&1; echo done"
assert_fire "区切りが複数ある形も deny"
assert_fix_generic "区切りが複数ある形は一般形へ落とす（先頭区間を起動と誤認しない）"
run_hook "$GATE 2>&1 | tail -20"
assert_fix_generic "パイプを含む形は一般形へ落とす（ゲートがどの段か決められない）"

echo "guard-exit-code: AC2 — 診断で終端しない呼び出しは素通し（偽陽性なし）"
run_hook "$GATE > /tmp/runall.log 2>&1"
assert_pass "単体起動（rc がそのまま残る）は素通し"
run_hook "$GATE > log 2>&1 && echo OK"
assert_pass "&& 連結は短絡するので素通し"
run_hook "$GATE > log 2>&1; rc=\$?; echo \"EXIT=\$rc\"; exit \$rc"
assert_pass "推奨形（診断を出してから伝播）は素通し"
run_hook "$GATE > log 2>&1; exit \$?"
assert_pass "ゲート直後の exit \$? は伝播するので素通し"
run_hook 'git log --oneline -20 | head -5'
assert_pass "\$? を読まない探索コマンドは素通し"
run_hook 'git ls-files | wc -l'
assert_pass "フィルタ終端でも \$? を読まなければ素通し"
run_hook 'npm test > log 2>&1; echo "rc=$?"'
assert_pass "ゲート名簿外のコマンドはパイプ無しなら素通し（対象をあらゆるコマンドへ広げない）"

echo "guard-exit-code: AC3 — 検出器が既に持つ除外形は止めない"
run_hook 'printf %s x | bash "$0" >/dev/null 2>&1 || rc=$?'
assert_pass "入力供給パイプ（終端が測定対象）は素通し"
run_hook "git commit -m \"docs: $GATE > log; echo rc=\$? を直す\""
assert_pass "二重引用符の中の区切り子・コマンド名（コミットメッセージ）は素通し"
run_hook "gh pr comment 1 --body \"検証: $GATE 2>&1 | tail -20 は誤り\""
assert_pass "二重引用符の中の同型（PR コメント本文）は素通し"
run_hook "git commit -m 'fix: \${PIPESTATUS[0]} の参照をやめる'"
assert_pass "単一引用符の中は散文として伏せられる（PIPESTATUS の言及も素通し）"
run_hook 'git add /repo/plugins/ff-dev-toolkit/tests/run-all.sh && git commit -m x'
assert_pass "ゲートを引数として触るだけ（git add）は素通し"
run_hook 'git diff -- /repo/plugins/ff-dev-toolkit/tests/run-all.sh | head -40'
assert_pass "ゲートを引数として触るだけ（git diff | head）は素通し"
run_hook 'RUNNER=/repo/plugins/ff-dev-toolkit/tests/run-all.sh; echo "$RUNNER"'
assert_pass "代入は起動ではないので素通し"
run_hook 'grep -q x < <(npm test | tail -1); echo "EXIT=$?"'
assert_pass "置換の内側のパイプは終端ではないので素通し"

echo "guard-exit-code: 複数行コマンド（エージェントが実際に投げる形）"
run_hook "cd /repo
$GATE > log 2>&1; echo \"rc=\$?\""
assert_fire "2 行目の事故形も deny（1 行目に紛れて見逃さない）"
run_hook "$GATE > log 2>&1
rc=\$?
echo \"EXIT=\$rc\"
exit \$rc"
assert_pass "推奨形の複数行（rc を取って伝播）は素通し"
run_hook 'npm test 2>&1 | tail -20
echo "EXIT=$?"'
assert_fire "pipe-exit-read は行をまたいでも deny（検出器が prev_pipe を保持する）"

echo "guard-exit-code: heredoc 本文はデータなので走査対象から落とす"
HEREDOC_BODY="gh pr create --base develop --body \"\$(cat <<'EOF'
## Test Plan
$GATE > log 2>&1; echo \"EXIT=\\\$?\"
EOF
)\""
run_hook "$HEREDOC_BODY"
assert_pass "PR 本文（heredoc）へ同型を書く操作は素通し"
run_hook "cat <<'EOF' > /tmp/note.md
$GATE > log 2>&1; echo done
EOF"
assert_pass "ファイルへ同型を書き出す heredoc は素通し"
# 未終端 heredoc（引用符・算術式の中の `<<WORD`）は `<<` の誤検出なので、以降の行を
# 捨てずに heredoc 除去前の生コマンドを走査する。捨てると事故形が無音で通る。
run_hook "git commit -m \"refactor: a << B ordering\"
$GATE > log 2>&1; echo \"rc=\$?\""
assert_fire "引用符の中の << で以降の行を捨てない（2 行目の事故形を deny）"
run_hook "echo \$((1 << n))
$GATE > log 2>&1; echo \"rc=\$?\""
assert_fire "算術式の << でも以降の行を捨てない"

echo "guard-exit-code: 抜け道"
run_hook "FF_EXIT_CODE_ACK=1 $GATE > log 2>&1; echo \"rc=\$?\""
assert_pass "コマンド先頭の FF_EXIT_CODE_ACK=1 で通る"
run_hook "  FF_EXIT_CODE_ACK=1 $GATE > log 2>&1; echo \"rc=\$?\""
assert_pass "先頭の空白があっても ACK は効く"
run_hook "echo FF_EXIT_CODE_ACK=1; $GATE > log 2>&1; echo \"rc=\$?\""
assert_fire "ACK が文字列として現れるだけでは無効（先頭の環境代入に限る）"
run_hook "FF_RUN_ALL_FULL=1 $GATE > log 2>&1; echo \"rc=\$?\"" 'FF_DEV_TOOLKIT_SKIP_EXIT_CODE_GUARD=1'
assert_pass "FF_DEV_TOOLKIT_SKIP_EXIT_CODE_GUARD=1 で無効化できる"

echo "guard-exit-code: AC4 — 判定できないときは fail-closed（候補コマンドに限る）"
FC_NONE="$(make_copy "$TEST_TMP/fc-none")"
run_hook_on "$FC_NONE" "$GATE > log 2>&1; echo \"rc=\$?\""
assert_fire "検出器が無いとき、候補コマンドは deny（素通ししない）"
case "$REASON" in
  *判定不能*) ok "fail-closed の理由文が判定不能である旨を出す" ;;
  *) bad "fail-closed の理由文に判定不能の記述が無い: [$REASON]" ;;
esac
case "$REASON" in
  *FF_EXIT_CODE_ACK=1*) ok "fail-closed の理由文も抜け道を案内する（案内の無い deny は詰まりになる）" ;;
  *) bad "fail-closed の理由文に抜け道の案内が無い: [$REASON]" ;;
esac
run_hook_on "$FC_NONE" 'git log --oneline -20'
assert_pass "検出器が無くても非候補コマンドは素通し（fail-closed の面は候補に限る）"
run_hook_on "$FC_NONE" 'npm run build'
assert_pass "検出器が無くても \$? / PIPESTATUS / ゲート綴りを含まない実行は素通し"

FC_BROKEN="$(make_copy "$TEST_TMP/fc-broken")"
printf 'if [ 1\n' > "$TEST_TMP/fc-broken/tests/lib/exit-code-guard.sh"
run_hook_on "$FC_BROKEN" "$GATE > log 2>&1; echo \"rc=\$?\""
assert_fire "検出器が壊れて source に失敗するとき deny"

FC_EMPTY="$(make_copy "$TEST_TMP/fc-empty")"
printf 'true\n' > "$TEST_TMP/fc-empty/tests/lib/exit-code-guard.sh"
run_hook_on "$FC_EMPTY" "$GATE > log 2>&1; echo \"rc=\$?\""
assert_fire "検出器に exit_code_scan が無いとき deny"

FC_AWK="$(make_copy "$TEST_TMP/fc-awk" "$DETECTOR")"
run_hook_on "$FC_AWK" "$GATE > log 2>&1; echo \"rc=\$?\"" 'FF_EXIT_CODE_AWK=/nonexistent/awk'
assert_fire "検出器の走査（awk）が失敗するとき deny"

# 共有 heredoc 除去ヘルパ（tests/lib/heredoc-strip.sh）が無い・壊れている・awk が失敗する回。
# 前処理はヘルパに移ったので、ヘルパ側の不成立も候補コマンドに限り fail-closed。
FC_NOHELPER="$(make_copy "$TEST_TMP/fc-nohelper" "$DETECTOR")"
rm -f "$TEST_TMP/fc-nohelper/tests/lib/heredoc-strip.sh"
run_hook_on "$FC_NOHELPER" "$GATE > log 2>&1; echo \"rc=\$?\""
assert_fire "heredoc 除去ヘルパが無いとき、候補コマンドは deny（素通ししない）"
case "$REASON" in
  *判定不能*) ok "ヘルパ不在の理由文が判定不能である旨を出す" ;;
  *) bad "ヘルパ不在の理由文に判定不能の記述が無い: [$REASON]" ;;
esac
run_hook_on "$FC_NOHELPER" 'git log --oneline -20'
assert_pass "ヘルパが無くても非候補コマンドは素通し"
FC_BADHELPER="$(make_copy "$TEST_TMP/fc-badhelper" "$DETECTOR")"
printf 'true\n' > "$TEST_TMP/fc-badhelper/tests/lib/heredoc-strip.sh"
run_hook_on "$FC_BADHELPER" "$GATE > log 2>&1; echo \"rc=\$?\""
assert_fire "ヘルパに ff_heredoc_strip が無いとき deny"
run_hook "$GATE > log 2>&1; echo \"rc=\$?\"" 'FF_HEREDOC_AWK=/nonexistent/awk'
assert_fire "heredoc 除去の awk（ヘルパの seam）が失敗するとき deny"
run_hook 'git log --oneline -20' 'FF_HEREDOC_AWK=/nonexistent/awk'
assert_pass "heredoc 除去の awk が失敗しても非候補コマンドは素通し"

# **PATH から awk を落とす**（seam ではなく実環境の awk 不在）。heredoc 除去の awk が
# 先に落ちるので、そこを fail-open にすると検出器側の fail-closed へ到達できない。
NOAWK_BIN="$TEST_TMP/noawk-bin"
mkdir -p "$NOAWK_BIN"
ln -s "$JQ_BIN" "$NOAWK_BIN/jq"
# `env PATH=… bash` は bash 自身も PATH で解決する。落とすのは awk だけなので、
# bash（と hook が読む sh）は明示的に置く。
ln -s /bin/bash "$NOAWK_BIN/bash"
ln -s /bin/sh "$NOAWK_BIN/sh"
run_hook "$GATE > log 2>&1; echo \"rc=\$?\"" "PATH=$NOAWK_BIN"
assert_fire "PATH に awk が無いとき deny（heredoc 除去の失敗を素通しにしない）"
run_hook 'git log --oneline -20' "PATH=$NOAWK_BIN"
assert_pass "PATH に awk が無くても非候補コマンドは素通し"

# 検出器が違反を報告したのに、その出力を `開始行:タグ:論理行` として解釈できない回。
STUB_GARBAGE="$TEST_TMP/stub-garbage.sh"
cat > "$STUB_GARBAGE" <<'STUB'
exit_code_scan() { cat >/dev/null; printf '\n'; printf '   \n'; }
exit_code_scan_bash_blocks() { cat >/dev/null; }
STUB
SD_GARBAGE="$(make_copy "$TEST_TMP/stub-garbage-dir" "$STUB_GARBAGE")"
run_hook_on "$SD_GARBAGE" "$GATE > log 2>&1; echo \"rc=\$?\""
assert_fire "違反ありなのに出力形式を解釈できないとき deny（判定が出ている地点で素通ししない）"

echo "guard-exit-code: deny の JSON を作れないときも黙って許可に落ちない"
JQFAIL_BIN="$TEST_TMP/jqfail-bin"
mkdir -p "$JQFAIL_BIN"
cat > "$JQFAIL_BIN/jq" <<JQSH
#!/bin/sh
# -n（deny の JSON 生成）だけ失敗させ、入力の取り出し（-r）は本物へ委ねる
for a in "\$@"; do
  if [ "\$a" = "-n" ]; then exit 5; fi
done
exec "$JQ_BIN" "\$@"
JQSH
chmod +x "$JQFAIL_BIN/jq"
run_hook "$GATE > log 2>&1; echo \"rc=\$?\"" "PATH=$JQFAIL_BIN:$PATH"
if [ "$RC" -eq 2 ] && [ -z "$OUT" ] && [ -n "$ERR" ]; then
  ok "deny の JSON 生成が失敗したら exit 2 + stderr でブロックする（無出力 exit 0 にしない）"
else
  bad "jq -n 失敗時に許可へ落ちている: exit=$RC out=[$OUT] err=[$ERR]"
fi
case "$ERR" in
  *gate-exit-swallowed*) ok "exit 2 の stderr にも検出タグが載る（エージェントへ届く）" ;;
  *) bad "exit 2 の stderr に検出内容が無い: [$ERR]" ;;
esac

echo "guard-exit-code: 判定を複製していない（verdict は検出器スタブに追随する）"
STUB_HIT="$TEST_TMP/stub-hit.sh"
cat > "$STUB_HIT" <<'STUB'
exit_code_scan() { cat >/dev/null; printf '1:gate-exit-swallowed:<stub>\n'; }
exit_code_scan_bash_blocks() { cat >/dev/null; }
STUB
STUB_MISS="$TEST_TMP/stub-miss.sh"
cat > "$STUB_MISS" <<'STUB'
exit_code_scan() { cat >/dev/null; }
exit_code_scan_bash_blocks() { cat >/dev/null; }
STUB
SD_HIT="$(make_copy "$TEST_TMP/stub-hit-dir" "$STUB_HIT")"
SD_MISS="$(make_copy "$TEST_TMP/stub-miss-dir" "$STUB_MISS")"
# 本番の検出器なら素通しする形（推奨形）でも、スタブが当てれば deny になる。
run_hook_on "$SD_HIT" "$GATE > log 2>&1; rc=\$?; echo \"EXIT=\$rc\"; exit \$rc"
assert_fire "スタブが当てれば推奨形でも deny（hook 側に独自の許可判定が無い）"
# 本番の検出器なら deny する形でも、スタブが 0 件なら素通しになる。
run_hook_on "$SD_MISS" "FF_RUN_ALL_FULL=1 $GATE > log 2>&1; echo \"rc=\$?\""
assert_pass "スタブが 0 件なら事故形でも素通し（hook 側に独自の検出判定が無い）"
# **ただし名簿の綴りだけは前置フィルタに写しがある。** スタブが必ず当てても、綴りを
# 含まないコマンドは検出器へ到達しない。これは既知の設計上の限界なので、挙動として
# 明示的に固定する（下の静的照合が、綴りの不一致を赤にする側を担う）。
run_hook_on "$SD_HIT" 'make verify > log 2>&1; echo done'
assert_pass "前置フィルタの綴りを含まないコマンドは、スタブが当てても検出器へ到達しない（既知の限界）"

echo "guard-exit-code: ゲート名簿の綴りが検出器と hook で一致する"
HOOK_GATE="$(sed -n "s/^GATE_NAME='\(.*\)'\$/\1/p" "$TARGET")"
DET_GATES="$(awk '/^function is_gate_launch/,/^}/' "$DETECTOR" | sed 's/#.*$//' | grep -oE '[A-Za-z0-9_-]+\.sh' | sort -u | tr '\n' ' ')"
if [ -n "$HOOK_GATE" ]; then
  ok "hook が名簿の綴りを 1 箇所（GATE_NAME）に持つ: $HOOK_GATE"
else
  bad "hook から GATE_NAME を読み取れません（前置フィルタの綴りが散っている可能性）"
fi
if [ "$DET_GATES" = "$HOOK_GATE " ]; then
  ok "検出器 is_gate_launch の名簿と hook の GATE_NAME が一致する（検出器へゲートを足したらここが赤くなる）"
else
  bad "名簿が食い違う: 検出器=[$DET_GATES] hook=[$HOOK_GATE]。検出器へゲートを足したら hook の GATE_NAME も直すこと"
fi
if [ "$(grep -c "'$HOOK_GATE'" "$TARGET")" -eq 1 ]; then
  ok "hook 内の名簿リテラルは 1 箇所だけ（前置フィルタは変数を参照する）"
else
  bad "hook 内に名簿リテラルが複数ある（GATE_NAME へ寄せること）"
fi

echo "guard-exit-code: 検出器側で塞いだ形（hook は判定を持たないので検出器に追随する）"
run_hook "$GATE > log 2>&1 & echo started"
assert_fire "& による background 起動（本ガードの主題そのものの形）を deny"
run_hook "{ $GATE > log 2>&1; }; echo done"
assert_fire "{ } グループ実行を deny"
run_hook "( $GATE > log 2>&1 ); echo done"
assert_fire "( ) サブシェル実行を deny"
run_hook "$GATE > log 2>&1; FOO=1 echo done"
assert_fire "末尾区間が環境代入で始まる形を deny"
run_hook "$GATE >&2 2>&1"
assert_pass "リダイレクトの & は区切り子ではない（単体起動は素通し）"
run_hook "( $GATE > log 2>&1 ) && echo OK"
assert_pass "サブシェル実行 + && は短絡するので素通し"

echo "guard-exit-code: 既知の限界（検出器側の判定規則なので、ここでは素通しを固定する）"
run_hook "$GATE > log 2>&1 &"
assert_pass "末尾が裸の & で終わり後続の区間が無い形は素通し（空の末尾区間は診断終端ではない）"
run_hook "$GATE > log 2>&1
echo done"
assert_pass "改行で区切った 2 行目の gate-exit-swallowed は素通し（検出器は論理行ごと）"

echo "guard-exit-code: fail-open（jq 以前・非 Bash・壊れた入力）"
run_hook_on "$TARGET" 'echo ok'
assert_pass "対象外のコマンドは無出力 exit 0"
RC=0
OUT="$(printf 'not-json' | bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "壊れた stdin JSON は無出力 exit 0"
else
  bad "壊れた stdin JSON: exit=$RC out=[$OUT]"
fi
RC=0
OUT="$(jq -n --arg c 'bash /repo/x/run-all.sh > log 2>&1; echo "rc=$?"' \
  '{tool_name: "Read", tool_input: {command: $c}, cwd: "/tmp"}' | bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "tool_name が Bash でなければ素通し"
else
  bad "非 Bash が素通ししない: exit=$RC out=[$OUT]"
fi

echo "guard-exit-code: stdin の drain（fail-open でも書き手に EPIPE を返さない）"
BIG_PAYLOAD="$(jq -n '{tool_name: "Bash", tool_input: {command: "echo ok"}, cwd: "/tmp"}')$(printf '%*s' 200000 '')"
RC=0
OUT="$(printf '%s' "$BIG_PAYLOAD" | PATH="/nonexistent" /bin/bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "PATH 空の環境でも stdin を読み切ってから無出力 exit 0"
else
  bad "PATH 空の drain: exit=$RC out=[$OUT]（rc=141 なら hook が stdin を drain せずに exit している）"
fi
RC=0
OUT="$(printf '%s' "$BIG_PAYLOAD" | FF_DEV_TOOLKIT_SKIP_EXIT_CODE_GUARD=1 PATH="/nonexistent" /bin/bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "opt-out でも stdin を読み切ってから無出力 exit 0"
else
  bad "opt-out の drain: exit=$RC out=[$OUT]"
fi

echo "guard-exit-code: ASDD ゲートの早期終了経路でも stdin を読み切る"
ASDD_ON="$TEST_TMP/asdd-hooks-on"
ASDD_OFF="$TEST_TMP/asdd-hooks-off"
mkdir -p "$ASDD_ON" "$ASDD_OFF"
ff_asdd_fixture "$ASDD_ON" true
ff_asdd_fixture "$ASDD_OFF" false
ASDD_PAYLOAD="$(ff_asdd_big_payload '{"tool_name":"Bash","tool_input":{"command":"echo ok"},"cwd":"/tmp","hook_event_name":"PreToolUse"}')"
ff_asdd_drain_probe "$TARGET" "$ASDD_PAYLOAD" "$ASDD_ON" PATH=/nonexistent
if [ "$FF_ASDD_DRAIN_RC" -eq 0 ] && [ -z "$FF_ASDD_DRAIN_OUT" ]; then
  ok ".asdd 設定あり + node 不在（ゲートが停止）でも stdin を読み切ってから無出力 exit 0"
else
  bad "ASDD ゲート（node 不在）の drain: exit=$FF_ASDD_DRAIN_RC out=[$FF_ASDD_DRAIN_OUT]"
fi
if command -v node >/dev/null 2>&1; then
  ff_asdd_drain_probe "$TARGET" "$ASDD_PAYLOAD" "$ASDD_OFF"
  if [ "$FF_ASDD_DRAIN_RC" -eq 0 ] && [ -z "$FF_ASDD_DRAIN_OUT" ]; then
    ok "features.hooks=false（ゲートが無効と判定）でも stdin を読み切ってから無出力 exit 0"
  else
    bad "ASDD ゲート（feature 無効）の drain: exit=$FF_ASDD_DRAIN_RC out=[$FF_ASDD_DRAIN_OUT]"
  fi
else
  echo "  ○ skip: node が無いため features.hooks=false 経路は未検査（guard-exit-code の ASDD ゲート無効判定）"
fi

echo "guard-exit-code: ASDD ゲートの検証不能は候補コマンドに限り deny（無効は素通し）"
# node だけを PATH から落とす（jq / awk / bash など hook と検出器が使うものは残す）。
NONODE_BIN="$TEST_TMP/nonode-bin"
mkdir -p "$NONODE_BIN"
for _tool in jq awk sed head cat grep tr date; do
  _p="$(command -v "$_tool" 2>/dev/null || true)"
  [ -n "$_p" ] && ln -s "$_p" "$NONODE_BIN/$_tool"
done
ln -s /bin/bash "$NONODE_BIN/bash"
ln -s /bin/sh "$NONODE_BIN/sh"
asdd_probe() { # <cwd> <command> [NAME=VALUE ...]
  local cwd="$1" cmd="$2" json
  shift 2
  json="$(jq -n --arg c "$cmd" --arg d "$cwd" \
    '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d, hook_event_name: "PreToolUse"}')"
  ff_asdd_drain_probe "$TARGET" "$json" "$cwd" "$@"
  RC="$FF_ASDD_DRAIN_RC"
  OUT="$FF_ASDD_DRAIN_OUT"
  DECISION="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)"
  EVENT="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName // empty' 2>/dev/null || true)"
  REASON="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || true)"
}
asdd_probe "$ASDD_ON" "$GATE > log 2>&1; echo \"rc=\$?\"" "PATH=$NONODE_BIN"
assert_fire ".asdd 設定あり + node 不在（検証不能）× 候補コマンドは deny"
case "$REASON" in
  *ASDD*) ok "検証不能の理由文が ASDD ゲートを名指しする" ;;
  *) bad "検証不能の理由文に ASDD の記述が無い: [$REASON]" ;;
esac
asdd_probe "$ASDD_ON" 'git log --oneline -20' "PATH=$NONODE_BIN"
assert_pass ".asdd 設定あり + node 不在でも非候補コマンドは素通し（fail-closed の面は候補に限る）"
# node は在るが設定を読めない（asdd-feature.mjs の例外経路 = rc 2）を node シムで模擬する。
NODE2_BIN="$TEST_TMP/node2-bin"
mkdir -p "$NODE2_BIN"
printf '#!/bin/sh\necho "ff-dev-toolkit: ASDD 設定を検証できないため任意Hookを停止しました" >&2\nexit 2\n' > "$NODE2_BIN/node"
chmod +x "$NODE2_BIN/node"
asdd_probe "$ASDD_ON" "$GATE > log 2>&1; echo \"rc=\$?\"" "PATH=$NODE2_BIN:$PATH"
assert_fire ".asdd 設定あり + 設定を読めない（ゲート rc 2）× 候補コマンドは deny"
if command -v node >/dev/null 2>&1; then
  asdd_probe "$ASDD_OFF" "$GATE > log 2>&1; echo \"rc=\$?\""
  assert_pass "features.hooks=false（無効）× 候補コマンドは従来どおり無音で素通し"
  asdd_probe "$ASDD_ON" "$GATE > log 2>&1; echo \"rc=\$?\""
  assert_fire "features.hooks=true（有効）× 事故形は deny（ゲートを読む形にしても判定は変わらない）"
else
  echo "  ○ skip: node が無いため features.hooks=false / true の経路は未検査"
fi

echo "guard-exit-code: hooks.json 登録の静的照合"
if jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]
    | select(.command | contains("guard-exit-code.sh"))' "$HOOKS_JSON" >/dev/null 2>&1; then
  ok "hooks.json の PreToolUse（Bash matcher）に登録されている"
else
  bad "hooks.json の PreToolUse（Bash matcher）に guard-exit-code.sh が無い"
fi
if jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]
    | select(.command | contains("guard-exit-code.sh")) | select(.timeout == 10)' "$HOOKS_JSON" >/dev/null 2>&1; then
  ok "hooks.json の timeout が兄弟ガードと同じ 10 秒"
else
  bad "hooks.json の guard-exit-code.sh に timeout: 10 が無い"
fi
DESC="$(jq -r '.description' "$HOOKS_JSON")"
case "$DESC" in
  *終了コード*) ok "hooks.json の description が終了コードガードに言及する" ;;
  *) bad "hooks.json の description に終了コードガードの記述が無い" ;;
esac

echo "guard-exit-code: 変異検出（コピーへ当て、本番検査と同形の針が赤になること）"
MUT_DIR="$TEST_TMP/mut"
MUT="$(make_copy "$MUT_DIR" "$DETECTOR")"
# 変異 1: fail-closed を fail-open へ倒す
sed 's/|| deny_unavailable "検出器のファイルが無いか読めません"/|| exit 0/' "$TARGET" > "$MUT"
rm -f "$MUT_DIR/tests/lib/exit-code-guard.sh"
run_hook_on "$MUT" "$GATE > log 2>&1; echo \"rc=\$?\""
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "変異検出: 検出器不在を exit 0 へ倒すと AC4 の deny 検査は赤になる"
else
  bad "fail-closed 除去の変異が deny のまま: decision=[$DECISION]"
fi
cp "$DETECTOR" "$MUT_DIR/tests/lib/exit-code-guard.sh"

# 変異 2: heredoc 本文の読み飛ばしを無効化する（本文をそのまま走査対象へ流す）
cp "$TARGET" "$MUT"
sed 's/if (nd > 0) {/if (nd > 99) {/' "$HELPER" > "$MUT_DIR/tests/lib/heredoc-strip.sh"
run_hook_on "$MUT" "$HEREDOC_BODY"
if [ "$RC" -eq 0 ] && [ "$DECISION" = "deny" ]; then
  ok "変異検出: heredoc 本文の読み飛ばしを外すと PR 本文の素通し検査は赤になる"
else
  bad "heredoc 読み飛ばしを外しても素通しのまま: decision=[$DECISION] out=[$OUT]"
fi
cp "$HELPER" "$MUT_DIR/tests/lib/heredoc-strip.sh"

# 変異 3: ACK 抜け道を消す
sed "s/^  'FF_EXIT_CODE_ACK=1 '\*|'FF_EXIT_CODE_ACK=1\t'\*) exit 0 ;;/  __never_match__) exit 0 ;;/" "$TARGET" > "$MUT"
run_hook_on "$MUT" "FF_EXIT_CODE_ACK=1 $GATE > log 2>&1; echo \"rc=\$?\""
if [ "$RC" -eq 0 ] && [ "$DECISION" = "deny" ]; then
  ok "変異検出: ACK 分岐を消すと抜け道検査は赤になる"
else
  bad "ACK 分岐を消しても素通しのまま: decision=[$DECISION] out=[$OUT]"
fi

# 変異 4: 候補の前置フィルタを常に真にする（fail-closed の面が全 Bash 呼び出しへ広がる）
sed 's/^  \*.\$?.\*|\*PIPESTATUS\*|\*"\$GATE_NAME"\*) : ;;/  *) : ;;/' "$TARGET" > "$MUT"
rm -f "$MUT_DIR/tests/lib/exit-code-guard.sh"
run_hook_on "$MUT" 'git log --oneline -20'
if [ "$RC" -eq 0 ] && [ "$DECISION" = "deny" ]; then
  ok "変異検出: 候補フィルタを常に真にすると「非候補は素通し」検査は赤になる"
else
  bad "候補フィルタを外しても非候補が素通しのまま: decision=[$DECISION] out=[$OUT]"
fi
cp "$DETECTOR" "$MUT_DIR/tests/lib/exit-code-guard.sh"

# 変異 5: 未終端 heredoc の検出（共有ヘルパの awk END）を消す
cp "$TARGET" "$MUT"
sed 's/^    if (nd > 0) exit 3$//' "$HELPER" > "$MUT_DIR/tests/lib/heredoc-strip.sh"
if cmp -s "$HELPER" "$MUT_DIR/tests/lib/heredoc-strip.sh"; then
  bad "変異 5 の注入が空振り（ヘルパの未終端検査行が見つからない）"
fi
run_hook_on "$MUT" "git commit -m \"refactor: a << B ordering\"
$GATE > log 2>&1; echo \"rc=\$?\""
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "変異検出: 未終端 heredoc の検出を消すと 2 行目の事故形が素通しになり、その検査は赤になる"
else
  bad "未終端検出を消しても deny のまま: decision=[$DECISION] out=[$OUT]"
fi
cp "$HELPER" "$MUT_DIR/tests/lib/heredoc-strip.sh"

# 変異 6: ASDD ゲートの rc 読みを `|| exit 0` へ戻す（検証不能を無効と同じに畳む）
MUT_ASDD_DIR="$TEST_TMP/mut-asdd"
MUT_ASDD="$(make_copy "$MUT_ASDD_DIR" "$DETECTOR")"
sed 's/^asdd_hook_enabled hooks$/asdd_hook_enabled hooks || exit 0/' "$TARGET" > "$MUT_ASDD"
if cmp -s "$TARGET" "$MUT_ASDD"; then
  bad "変異 7 の注入が空振り（asdd_hook_enabled hooks の行が見つからない）"
fi
ff_asdd_drain_probe "$MUT_ASDD" "$(jq -n --arg c "$GATE > log 2>&1; echo \"rc=\$?\"" --arg d "$ASDD_ON" \
  '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d, hook_event_name: "PreToolUse"}')" "$ASDD_ON" "PATH=$NONODE_BIN"
if [ "$FF_ASDD_DRAIN_RC" -eq 0 ] && [ -z "$FF_ASDD_DRAIN_OUT" ]; then
  ok "変異検出: rc 読みを || exit 0 へ戻すと「検証不能 × 候補は deny」検査は赤になる"
else
  bad "rc 読みを || exit 0 へ戻しても deny のまま: out=[$FF_ASDD_DRAIN_OUT]"
fi

# 変異 7: 実値案の安全条件（区切りがちょうど 1 個）を外す
sed 's/^\[ "\$sep_n" -eq 1 \] || launch_ok=0$/:/' "$TARGET" > "$MUT"
run_hook_on "$MUT" "x=1; $GATE > log 2>&1; echo done"
MUT_FIX="$(fix_block)"
case "$MUT_FIX" in
  *"$GENERIC"*) bad "安全条件を外しても一般形のまま: [$MUT_FIX]" ;;
  *) ok "変異検出: 安全条件を外すと先頭区間（x=1）を起動として案内し、一般形の検査は赤になる" ;;
esac

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ guard-exit-code: ${FAIL} 件失敗（成功 ${PASS} 件）" >&2
  REACHED_END=1
  exit 1
fi
echo "✅ guard-exit-code: all ${PASS} checks passed"
REACHED_END=1
exit 0
