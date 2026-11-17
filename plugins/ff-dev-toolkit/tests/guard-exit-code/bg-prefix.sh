#!/usr/bin/env bash
# Issue `#2672`: 背景実行（run_in_background）のゲート起動で、1 行目が代入（`SP=<dir>` /
# `FF_DEV_TOOLKIT_ROOT="<path>"`）や `cd <dir>` / `cd <dir> || exit 2`、heredoc でスクリプトを書く
# 行でも、末尾で `rc=$?; …; exit $rc` まで終了コードを伝播している本文を、hooks/guard-exit-code.sh が
# 止めないことを固定する。verify.sh の末尾から呼ばれ、単独でも回せる。
#
# fixture は観測台帳（docs/08-knowledge/OBSERVATIONS.md）の OBS-460・OBS-468・OBS-475・OBS-484 に
# 記録された本文の形（パスは匿名化）。OBS-475 の Count 4（1 行目が素の `cd <worktree>` の本文と、
# 1 行目が `FF_DEV_TOOLKIT_ROOT="<path>"` の本文）を含む。fire-review-*.txt は PR のレビューで
# 別モデル 2 本が独立に示した偽の緑（検査の rc を後続の sed / build / rm が奪う形、コマンド置換の代入）。
# ただし fire-review-subst-multi-assign.txt は Issue `#2683` の退行の形（代入を並べた 1 文 `out=$(cmd) rc=$?`）で、
# Issue `#2672` を扱った別 PR のレビューで実測した。そのバッククォート版 fire-review-subst-multi-assign-backtick.txt は、
# Issue `#2683` の PR のセルフレビューで、伏せられていないバッククォートの判定に検査が無いと分かって足した。
#
#   BP. pass-*.txt: hook は止めない。素の exit_code_scan も、背景実行の判定
#       （ff_exit_code_any_launch=1 の exit_code_scan）も 0 件 — hook と判定の正本が一致する
#   BF. fire-*.txt: 同じ形から末尾の `exit $rc` を落とした本文などは従来どおり止める。期待値は
#       fixtures/bg-prefix/expect.tsv。検出した形はゲートの起動行で、代入行・cd 行ではない。
#       hook の検出（タグ・行）は背景実行の判定の最初の 1 件と一致する。ゲートが名簿のゲート
#       （`bash …/run-all.sh`）なら素の exit_code_scan とも一致する（same）。名簿外のゲート
#       （wsl.exe 経由・multi-review.sh・npm test）は、背景実行だけが名簿外の起動も主体にする設計
#       （Issue `#2540`）なので素の exit_code_scan は 0 件のまま（zero）— 差は恒久的なもので、AC の回避ではない
#   BM. 変異検出: 背景実行の判定を元に戻すと BP / BF が赤になる
#
# 空振り検出: fixture の集合が空（ディレクトリが無い・pass が 11 件未満・expect.tsv の行が fire-*.txt の
# 数と合わない）なら赤。OBS 4 件と Count 4 の 2 本が pass の集合に無ければ赤。
# 変異検出（2026-11-07 Windows Git Bash 再実測。Issue `#2683` の fixture を含む）: 検出器を Issue `#2672` の
# 修正前の版へ差し替えたツリーでこの suite を回すと 62 件失敗（rc=1）— OBS と mkdir の BP 12 件すべてを、
# OBS の記録どおり代入行・cd 行・準備の行を名指しして止める。Issue `#2683` の修正前の版では 9 件失敗
# （代入を並べた 1 文の 2 形の BF 6 件と、照合先の行が無い BM5〜BM7 の 3 件）。
# 内蔵の変異は、BM1（起動から外す判定と引き継ぎを両方無効にする = 修正前の判定）で BP 12 件が deny、
# BM2（起動から外す判定だけを無効にする）で OBS の BP 11 件が deny（mkdir は引き継ぎで通ったまま）、
# BM3（準備の行からの引き継ぎだけを無効にする）で heredoc と mkdir の 2 件が deny（素の cd は通ったまま）、
# BM4（どの起動も準備とみなす）で BF の 6 件がゲートの起動行を示さなくなり、BM5（コマンド置換の代入を
# 起動に数える判定を消す）で BF の 5 件が素通しになり、BM6（置換の判定を strip_prefix の後に残った代入の
# 値だけへ戻す = Issue `#2683` の修正前）で代入を並べた 1 文の 2 件だけが、BM7（伏せられていない
# バッククォートの判定だけを消す）でそのバッククォート版の 1 件だけが素通しになることを、それぞれ
# 反転の集合として照合する。pass-subst-multi-assign-exit.txt（同じ 1 文の rc を exit まで伝播する本文）は
# OBS の本文ではないので BM_ALL_PASS に入れず、BP の照合だけを受ける（Issue `#2683`）。
#
# Issue `#2813`（導入先の観測台帳 OBS-237 Count 3）: 2 行目以降の準備の行 `<cmd> || exit N` と、ゲートの
# 前後に置いた表示だけの行（`git status --short <file>` / `tail -n 15 <log>`）を名指して止めていた本文
# pass-prep-or-exit-build-e2e.txt（2026-11-16 に止められた本文そのもの）と、同じ穴の隣接形 —
# `export` ⏎ `[ -d "$ROOT" ] || exit 9`（2026-10-30 の本文の形）・`mkdir` ⏎ `cd <dir> || exit 2`・
# `cp` ⏎ `git status --short`・1 行目の `set -uo pipefail` — を pass に置く。fire は同じ本文から `exit $rc` を
# 落とした形（名簿外の pnpm と名簿の run-all.sh の 2 本。後者は素の exit_code_scan とも一致する）、
# `|| exit 0` で準備の失敗を握り潰す形、準備の rc を起動の無い行越しに待って `$?` の読み・単位の終端で落とす
# 形と、PR のレビュー（codex-cli と主担当側）が示した偽の緑 7 形（fire-review-*: サブシェルの中の exit・
# `&&` の後続区間のパイプ・ラッパ越しの exit・cd の後の `rc=$?` を準備の rc として読む 2 形・`cat a b > c`・
# heredoc の cat）、4 巡目の 1 形（fire-review5-*: 引数の予約語が深さを打ち消す）、5 巡目の `time {` と同じ類の
# coproc・先頭の `!`（fire-review6-*）、6 巡目の `trap 'exit 0' EXIT` の後（fire-review7-*）と、2 巡目のレビュー（codex-cli）が示した 3 形（fire-review2-*: 複数行のサブシェル・cd の後の
# `[ $? -eq 0 ] || exit 1`・引数のファイルへ書く tee）、その後の再点検でブロック越しに漏れた 3 形（fire-review3-*: パイプに
# 繋いだグループ・パイプに繋いだ while の本体・`&` に繋いだグループ）を受けて、fail-fast の例外を平坦な行に絞った。
# pass-prep-stderr-display.txt は `tail … 2>/dev/null` / `git status 2>&1` を表示のまま数えることを固定する。
# これら新しい pass は OBS の本文ではないので BM_ALL_PASS に入れない。
#   BM1 は Issue `#2813` の fail-fast の判定（failfast_tail）も併せて無効にする — `cd <dir> || exit 2` の
#   本文（pass-obs468-cd-exit-review.txt）は、cd を起動に数えても fail-fast の形として通るようになった。
#   BM2（起動から外す判定だけを無効にする）ではこの 1 件が deny へ倒れなくなったことを、反転しない側
#   として照合する。BM4 では tail が起動でなくなったので、fire-handover-tail-after-gate.txt は「どの起動も
#   準備とみなす」変異でもゲートの起動行を示したまま（反転しない側として照合する）。
#   BM8〜BM23 は規則を 1 つずつ外し、BM_2813_PASS / BM_2813_FIRE の反転の集合を期待と照合する（bm_expect）:
#   fail-fast の判定・exit 0 の除外・表示だけの区間・起動の無い行越しの引き継ぎ・状態 3（`$?` の持ち越しとの
#   区別）・set などの組み込み・状態 3 の `$?` の判定・同じ行のブロックの除外・ゲートの直後の `||`・ラッパ越しの
#   exit の除外・ファイルへ書く形の除外・複数行のブロックの除外・状態 3 で起動の区間が読む `$?`・tee の除外・
#   stderr の向け先の扱い・ブロックの印に数える予約語・波括弧（BM26）・区間の先頭の `!`（BM27 / BM28）。印は語の
#   位置を見ずに多めに取る（5 巡目の `time {` を受けて命令の位置の読み分けをやめたので、旧 BM25 は無い）。
#   ブロックは深さを数えず「単位の中で一度でも印が出た行以降は例外にしない」（blk_ever）で扱うので、深さの
#   規則を外す変異（旧 BM19 / BM24）は無い。case の分岐のパターンの形は run-all の静的 self-test が固定する。
# 変異検出（2026-11-16 macOS 実測）: 検出器を Issue `#2813` の修正前（origin/develop 607494bc）へ差し替えた
# ツリーでは、新しい pass が deny（Issue の本文は準備の行を名指す）、exit $rc を欠いた fire が準備・表示の行を
# 名指し、変異 BM8〜BM28 の照合先の行が無いので赤になる（件数は verify.sh の空振り検出の行）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$PLUGIN_ROOT/hooks/guard-exit-code.sh"
DETECTOR="$PLUGIN_ROOT/tests/lib/exit-code-guard.sh"
FIXTURES="$SCRIPT_DIR/fixtures/bg-prefix"
# shellcheck source=../lib/adapter-env-isolation.sh
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"
isolate_hook_env "FF_DEV_TOOLKIT_SKIP" "$TARGET"
[ -f "$TARGET" ] || { echo "✗ guard-exit-code.sh が見つかりません: $TARGET" >&2; exit 1; }
[ -f "$DETECTOR" ] || { echo "✗ 検出器が見つかりません: $DETECTOR" >&2; exit 1; }
[ -d "$FIXTURES" ] || { echo "✗ fixture のディレクトリが見つかりません: $FIXTURES" >&2; exit 1; }
if ! command -v jq >/dev/null 2>&1; then
  echo "○ skip: jq が見つからないためスキップ（bg-prefix は未検査のままです）"
  exit 0
fi
unset FF_EXIT_CODE_ACK FF_EXIT_CODE_GUARD_GATES ff_exit_code_any_launch

if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/ff-bg-prefix.XXXXXX" 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
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
    echo "✗ bg-prefix: 最後まで到達しませんでした" >&2
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
HOOK_TAG=""
HOOK_LINE=""

# fixture の本文を run_in_background の Bash 呼び出しとして hook に通す。
run_bg_on() { # <hook> <fixture>
  local hook="$1" file="$2" json
  json="$(jq -n --rawfile c "$file" --arg d "$TEST_TMP" \
    '{tool_name: "Bash", tool_input: {command: $c, run_in_background: true}, cwd: $d, hook_event_name: "PreToolUse"}')"
  RC=0
  OUT="$(printf '%s' "$json" | bash "$hook" 2>/dev/null)" || RC=$?
  DECISION="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)"
  REASON="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || true)"
  HOOK_TAG="$(printf '%s\n' "$REASON" | sed -n 's/^.*検出タグ `\([a-z-]*\)`.*$/\1/p' | head -1)"
  HOOK_LINE="$(printf '%s\n' "$REASON" | awk '/^検出した形（実値）:$/ { getline; sub(/^  /, ""); print; exit }')"
}

# 判定の正本の最初の 1 件を「タグ<TAB>論理行」で返す（行番号は heredoc を落とすかどうかで
# ずれるので比べない）。第 2 引数が bg なら背景実行の判定（hook が使う方）。
scan_first() { # <fixture> <static|bg>
  (
    # shellcheck source=../lib/exit-code-guard.sh
    . "$DETECTOR"
    if [ "$2" = bg ]; then export ff_exit_code_any_launch=1; fi
    exit_code_scan <"$1"
  ) | awk 'NR == 1 { sub(/^[0-9]+:/, ""); t = $0; sub(/:.*$/, "", t); l = $0; sub(/^[^:]*:/, "", l); printf "%s\t%s\n", t, l }'
}

PASS_FILES=()
for f in "$FIXTURES"/pass-*.txt; do
  [ -f "$f" ] && PASS_FILES+=("$f")
done
FIRE_N=0
for f in "$FIXTURES"/fire-*.txt; do
  [ -f "$f" ] && FIRE_N=$((FIRE_N + 1))
done
EXPECT_N="$(grep -vc '^#' "$FIXTURES/expect.tsv" 2>/dev/null || true)"

echo "bg-prefix: fixture の集合（空振り検出）"
if [ "${#PASS_FILES[@]}" -ge 11 ]; then ok "pass の fixture が ${#PASS_FILES[@]} 件ある"; else bad "pass の fixture が少ない（${#PASS_FILES[@]} 件）"; fi
if [ "$FIRE_N" -gt 0 ] && [ "$FIRE_N" = "$EXPECT_N" ]; then
  ok "fire の fixture ${FIRE_N} 件すべてに expect.tsv の期待値がある"
else
  bad "fire の fixture（${FIRE_N} 件）と expect.tsv の行（${EXPECT_N:-0} 件）が合わない"
fi
for want in pass-obs460- pass-obs468- pass-obs475- pass-obs484- pass-obs475-bare-cd.txt pass-obs475-ff-root-assign.txt pass-prep-or-exit-build-e2e.txt; do
  # bash 3.2 の set -u は空配列の展開を unbound として落とすので、空なら空文字列へ展開する
  case " ${PASS_FILES[*]+"${PASS_FILES[*]}"} " in
    *"/$want"*) ok "pass の集合に $want がある" ;;
    *) bad "pass の集合に $want が無い" ;;
  esac
done

echo "bg-prefix: BP — 伝播している本文は止めない（hook と判定の正本が一致する）"
for f in ${PASS_FILES[@]+"${PASS_FILES[@]}"}; do
  name="${f##*/}"
  run_bg_on "$TARGET" "$f"
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "$name: hook は止めない"; else bad "$name: hook が止めた: exit=$RC tag=[$HOOK_TAG] line=[$HOOK_LINE]"; fi
  s="$(scan_first "$f" static)"
  b="$(scan_first "$f" bg)"
  if [ -z "$s" ] && [ -z "$b" ]; then
    ok "$name: exit_code_scan は素・背景実行とも 0 件"
  else
    bad "$name: exit_code_scan が当てた: 素=[$s] 背景=[$b]"
  fi
done

echo "bg-prefix: BF — exit \$rc を欠いた本文は止め、ゲートの起動行を示す"
while IFS="$(printf '\t')" read -r name tag st line; do
  case "$name" in '#'*|'') continue ;; esac
  f="$FIXTURES/$name"
  [ -f "$f" ] || { bad "$name: fixture がありません"; continue; }
  run_bg_on "$TARGET" "$f"
  if [ "$RC" -eq 0 ] && [ "$DECISION" = deny ] && [ "$HOOK_TAG" = "$tag" ]; then
    ok "$name: hook は $tag で止める"
  else
    bad "$name: hook の判定が違う: exit=$RC decision=[$DECISION] tag=[$HOOK_TAG]"
  fi
  if [ "$HOOK_LINE" = "$line" ]; then
    ok "$name: 検出した形はゲートの起動行"
  else
    bad "$name: 検出した形が違う: [$HOOK_LINE]（期待: [$line]）"
  fi
  # 期待と違う行を名指したとき、それが代入行・cd 行なら（この Issue の誤検知の形）名前を付けて報告する。
  # 期待そのものが代入（コマンド置換の代入 `result=$(npm test)`）の fixture もあるので、期待と一致した行は見ない
  if [ "$HOOK_LINE" != "$line" ] && grep -Eq '^(cd |[A-Za-z_][A-Za-z0-9_]*=)' <<<"$HOOK_LINE"; then
    bad "$name: 検出した形が代入行・cd 行: [$HOOK_LINE]"
  fi
  b="$(scan_first "$f" bg)"
  if [ "$b" = "$HOOK_TAG	$HOOK_LINE" ]; then
    ok "$name: hook と背景実行の exit_code_scan の検出が一致する"
  else
    bad "$name: hook と背景実行の exit_code_scan が食い違う: hook=[$HOOK_TAG	$HOOK_LINE] scan=[$b]"
  fi
  s="$(scan_first "$f" static)"
  case "$st" in
    same)
      if [ "$s" = "$HOOK_TAG	$HOOK_LINE" ]; then ok "$name: 素の exit_code_scan とも一致する（名簿のゲート）"
      else bad "$name: 素の exit_code_scan と食い違う: hook=[$HOOK_TAG	$HOOK_LINE] scan=[$s]"; fi ;;
    zero)
      if [ -z "$s" ]; then ok "$name: 素の exit_code_scan は 0 件（名簿外のゲート。背景実行だけが主体にする）"
      else bad "$name: 名簿外のゲートなのに素の exit_code_scan が当てた: [$s]"; fi ;;
    *) bad "$name: expect.tsv の静的走査の列が不正: [$st]" ;;
  esac
done <"$FIXTURES/expect.tsv"

echo "bg-prefix: BM — 背景実行の判定を元に戻す変異で赤になる"
make_tree() { # <dir>
  mkdir -p "$1/hooks" "$1/tests/lib"
  cp "$TARGET" "$PLUGIN_ROOT/hooks/asdd-hook-gate.sh" "$PLUGIN_ROOT/hooks/asdd-feature.mjs" "$1/hooks/"
  cp "$DETECTOR" "$PLUGIN_ROOT/tests/lib/heredoc-strip.sh" "$PLUGIN_ROOT/tests/lib/wait-bounds.sh" \
    "$PLUGIN_ROOT/tests/lib/exit-code-rewrite.sh" "$PLUGIN_ROOT/tests/lib/git-write-chain-scan.sh" \
    "$PLUGIN_ROOT/tests/lib/rg-stdin-scan.sh" "$1/tests/lib/"
}
# 変異を当てたコピーを作る。awk の変換が検出器を 1 行も変えなければ「当たっていない」で赤にする。
make_mutant() { # <dir> <awk program>
  make_tree "$1"
  awk "$2" "$DETECTOR" >"$1/tests/lib/exit-code-guard.sh"
  if cmp -s "$DETECTOR" "$1/tests/lib/exit-code-guard.sh"; then
    bad "変異 ${1##*/} が当たっていない（検出器の対象の行が awk に一致しない）"
    return 1
  fi
}
# 変異で判定が反転した fixture の名前を空白区切りで返す。pass は deny へ倒れたら反転。fire は
# 素通しへ倒れたか、止めても検出した形が expect.tsv のゲートの起動行でなくなったら反転
# （準備の行や tail / grep の行を名指しする停止は、この Issue が直す誤検知そのもの）。
flipped() { # <hook> <pass|fire> <fixture>...
  local hook="$1" kind="$2" out="" f want
  shift 2
  for f in "$@"; do
    run_bg_on "$hook" "$FIXTURES/$f"
    if [ "$kind" = pass ]; then
      [ "$DECISION" = deny ] && out="$out $f"
    else
      want="$(awk -F'\t' -v n="$f" '$1 == n { print $4 }' "$FIXTURES/expect.tsv")"
      if [ "$DECISION" != deny ] || [ "$HOOK_LINE" != "$want" ]; then out="$out $f"; fi
    fi
  done
  printf '%s' "$out"
}
BM_ALL_PASS="pass-obs460-assign-wsl-gate.txt pass-obs460-cd-exit-heredoc.txt pass-obs468-assign-wsl.txt pass-obs468-cd-exit-review.txt pass-obs468-assign-precommit.txt pass-obs475-assign-run-all.txt pass-obs475-cd-exit-root-review.txt pass-obs475-assign-echo-cat.txt pass-obs475-bare-cd.txt pass-obs475-ff-root-assign.txt pass-obs484-assign-npm-run-all.txt pass-prep-mkdir.txt"
# 代入の除外（ブロックの if 行）を if (0) にし、cd / exit 等の除外の行を消す
EXCL_AWK='index($0, "if (w ~ /^[A-Za-z_][A-Za-z0-9_]*=/) {") { print "    if (0) {"; next } index($0, "if (w ~ /^(cd|pushd|popd|export|exit|return)$/) return 0") { next }'
HANDOVER_AWK='index($0, "g_prep && gi > 0) {") { print "    } else if (0) {"; next }'
# fail-fast の判定（`<ゲート> || exit N` を握り潰しと見ない。Issue `#2813`）の呼び出しを消す
FAILFAST_AWK='index($0, "if (failfast_tail(segs, seps, gi, n)) return 0") { next }'

# BM1: 背景実行の判定を修正前へ戻す（代入・cd・exit を起動から外す判定と、準備の行から後続の
# 起動への引き継ぎと、fail-fast の判定を無効にする）。OBS の pass の本文がすべて deny へ倒れる
M="$TEST_TMP/bm1"
if make_mutant "$M" "$EXCL_AWK $HANDOVER_AWK $FAILFAST_AWK { print }"; then
  # shellcheck disable=SC2086 # 名前の列を語に割る
  got="$(flipped "$M/hooks/guard-exit-code.sh" pass $BM_ALL_PASS)"
  if [ "$got" = " $BM_ALL_PASS" ]; then ok "BM1: 背景実行の判定を修正前へ戻すと、OBS-460 / 468 / 475 / 484 と mkdir の pass の本文 12 件がすべて deny へ倒れる"
  else bad "BM1: 修正前へ戻しても deny へ倒れたのは [${got# }] だけ"; fi
fi
# BM2: 起動から外す判定だけを無効にする。代入・素の cd の行は準備の行ではないので後続の起動へ
# 引き継がれず、OBS-468 / 475 / 484 の本文が止まる。1 行目が `cd <dir> || exit 2` だけの本文
# （pass-obs468-cd-exit-review.txt）は、cd を起動に数えても fail-fast の形（Issue `#2813`）として通る
M="$TEST_TMP/bm2"
if make_mutant "$M" "$EXCL_AWK { print }"; then
  BM2_PASS="pass-obs460-assign-wsl-gate.txt pass-obs460-cd-exit-heredoc.txt pass-obs468-assign-wsl.txt pass-obs468-assign-precommit.txt pass-obs475-assign-run-all.txt pass-obs475-cd-exit-root-review.txt pass-obs475-assign-echo-cat.txt pass-obs475-bare-cd.txt pass-obs475-ff-root-assign.txt pass-obs484-assign-npm-run-all.txt"
  # shellcheck disable=SC2086 # 名前の列を語に割る
  got="$(flipped "$M/hooks/guard-exit-code.sh" pass $BM2_PASS pass-obs468-cd-exit-review.txt pass-prep-mkdir.txt)"
  if [ "$got" = " $BM2_PASS" ]; then
    ok "BM2: 代入・cd・exit を起動に数えると OBS の pass 10 件が deny へ倒れ、cd <dir> || exit 2 は fail-fast の形として、mkdir の準備の行は引き継ぎで通ったまま"
  else bad "BM2: 変異で deny へ倒れた集合が違う: [${got# }]"; fi
fi
# BM3: 準備の行から後続の起動への引き継ぎだけを無効にする
M="$TEST_TMP/bm3"
if make_mutant "$M" "$HANDOVER_AWK { print }"; then
  got="$(flipped "$M/hooks/guard-exit-code.sh" pass pass-obs460-cd-exit-heredoc.txt pass-prep-mkdir.txt pass-obs475-bare-cd.txt)"
  if [ "$got" = " pass-obs460-cd-exit-heredoc.txt pass-prep-mkdir.txt" ]; then
    ok "BM3: 引き継ぎを無効にすると、heredoc でスクリプトを書く本文（OBS-460）と mkdir の本文が deny へ倒れ、素の cd の本文は通ったまま"
  else bad "BM3: 引き継ぎを無効にして deny へ倒れた集合が違う: [${got# }]"; fi
fi
# BM4: どの起動も準備の行とみなす（g_prep を 0 にしない）。検査・名簿のゲートの rc を後続の
# コマンドが奪う形を素通しする（レビューで別モデル 2 本が指摘した偽の緑）。tail の行は起動では
# ない（表示だけの区間。Issue `#2813`）ので引き継ぎ先にならず、fire-handover-tail-after-gate.txt は
# この変異でもゲートの起動行を示したまま
M="$TEST_TMP/bm4"
if make_mutant "$M" 'index($0, "!is_prep_launch(segs[i])) g_prep = 0") { next } { print }'; then
  BM4_FIRE="fire-review-sed-after-test.txt fire-review-build-after-test.txt fire-review-rm-after-test.txt fire-handover-grep-after-gate.txt fire-named-gate-overwritten.txt"
  # shellcheck disable=SC2086 # 名前の列を語に割る
  got="$(flipped "$M/hooks/guard-exit-code.sh" fire $BM4_FIRE fire-handover-tail-after-gate.txt)"
  if [ "$got" = " $BM4_FIRE" ]; then
    ok "BM4: どの起動も準備とみなすと、検査・run-all.sh の rc を後続の sed / build / rm / grep が奪う 5 件でゲートの起動行を示さなくなり、表示だけの tail の 1 件はゲートの起動行を示したまま"
  else bad "BM4: 反転したのは [${got# }] だけ"; fi
fi
# BM5〜BM7 が照合するコマンド置換の代入の 5 形（反転の集合はこの順の部分列で比べる）
BM_SUBST_FIRE="fire-review-subst-assign.txt fire-review-subst-prefix.txt fire-review-subst-backtick-dq.txt fire-review-subst-multi-assign.txt fire-review-subst-multi-assign-backtick.txt"
# BM5: コマンド置換の代入を起動に数える判定を消す
M="$TEST_TMP/bm5"
if make_mutant "$M" 'index($0, "if (index(raw, \"`\") || (line_subst") { next } { print }'; then
  # shellcheck disable=SC2086 # 名前の列を語に割る
  got="$(flipped "$M/hooks/guard-exit-code.sh" fire $BM_SUBST_FIRE)"
  if [ "$got" = " $BM_SUBST_FIRE" ]; then ok "BM5: コマンド置換の代入を準備扱いすると、result=\$(npm test) / 前置付き / 二重引用符の中のバッククォート / 代入を並べた 1 文（\$( と素のバッククォート）の rc を落とす 5 形を素通しする"
  else bad "BM5: コマンド置換の判定を消しても反転しない（反転したのは [${got# }]）"; fi
fi
# BM6: 置換の判定を strip_prefix の後に残った代入の値だけへ戻す（Issue `#2683` の修正前）。
# 代入を並べた 1 文（`out=$(cmd) rc=$?` と `` out=`cmd` rc=$? ``）だけが素通しへ倒れ、ほかの 3 形は止めたまま
M="$TEST_TMP/bm6"
if make_mutant "$M" 'index($0, "if (index(raw, \"`\") || (line_subst") { print "      v = w; sub(/^[^=]*=/, \"\", v)"; print "      if (index(v, \"`\") || (line_subst && v ~ /___/)) return 1"; next } { print }'; then
  # shellcheck disable=SC2086 # 名前の列を語に割る
  got="$(flipped "$M/hooks/guard-exit-code.sh" fire $BM_SUBST_FIRE)"
  if [ "$got" = " fire-review-subst-multi-assign.txt fire-review-subst-multi-assign-backtick.txt" ]; then ok "BM6: 置換の判定を残った代入の値だけへ戻すと、代入を並べた 1 文の 2 形（\$( と素のバッククォート）だけが素通しになる"
  else bad "BM6: 修正前へ戻して反転したのは [${got# }]（期待は代入を並べた 1 文の 2 形だけ）"; fi
fi
# BM7: 伏せられていないバッククォートを置換とみなす判定（index(raw, "`")）だけを消す。素のバッククォートは
# mask も strip_subst も伏せないので `___` が残らず、代入を並べた 1 文のバッククォート版だけが素通しへ倒れる
# （二重引用符の中のバッククォートは mask が `_` へ伏せるので止めたまま）。fixture のバッククォートの中には
# 空白を置かない — strip_prefix は代入を空白で切って剥がすので、`` out=`bash x.sh` rc=$? `` は残りが代入に
# 見えず汎用の起動判定で止まり、この判定まで届かない（BM5〜BM7 が空の反転で赤になるが、検出器の退行ではない）
M="$TEST_TMP/bm7"
if make_mutant "$M" 'index($0, "if (index(raw, \"`\") || (line_subst") { print "      if (line_subst && raw ~ /___/) return 1"; next } { print }'; then
  # shellcheck disable=SC2086 # 名前の列を語に割る
  got="$(flipped "$M/hooks/guard-exit-code.sh" fire $BM_SUBST_FIRE)"
  if [ "$got" = " fire-review-subst-multi-assign-backtick.txt" ]; then ok "BM7: 素のバッククォートの判定を消すと、out=\`cmd\` rc=\$? の 1 形だけが素通しになる"
  else bad "BM7: 素のバッククォートの判定を消して反転したのは [${got# }]（期待は fire-review-subst-multi-assign-backtick.txt だけ）"; fi
fi
# BM8〜BM28（BM19 / BM24 / BM25 は欠番）が照合する Issue `#2813` の pass 7 形と fire 23 形（反転の集合はこの順の部分列で比べる）
BM_2813_PASS="pass-prep-or-exit-build-e2e.txt pass-prep-test-or-exit.txt pass-prep-mkdir-cd-exit.txt pass-set-pipefail-preface.txt pass-prep-cp-status-gate.txt pass-prep-stderr-display.txt pass-prep-test-bang.txt"
BM_2813_FIRE="fire-prep-or-exit-build-e2e.txt fire-prep-or-exit-run-all.txt fire-prep-or-exit0.txt fire-prep-mkdir-cd-echo.txt fire-prep-mkdir-cd-end.txt fire-review-subshell-or-exit.txt fire-review-and-pipe-or-exit.txt fire-review-wrapper-exit.txt fire-review-capture-after-cd.txt fire-review-recapture-test.txt fire-review-cat-redirect.txt fire-review-heredoc-cat-echo.txt fire-review2-multiline-subshell.txt fire-review2-test-status-after-cd.txt fire-review2-tee-file.txt fire-review3-group-pipe.txt fire-review3-while-pipe.txt fire-review3-group-bg.txt fire-review5-subshell-arg-keyword.txt fire-review6-time-group-pipe.txt fire-review6-coproc.txt fire-review6-bang.txt fire-review7-exit-trap.txt"
# 変異を当てたツリーで、pass と fire の反転の集合が期待どおりかを照合する
bm_expect() { # <名> <変異の awk> <期待する pass の反転> <期待する fire の反転> <成立時の説明>
  local name="$1" prog="$2" want_p="$3" want_f="$4" msg="$5" got_p got_f
  M="$TEST_TMP/$name"
  make_mutant "$M" "$prog" || return 0
  # shellcheck disable=SC2086 # 名前の列を語に割る
  got_p="$(flipped "$M/hooks/guard-exit-code.sh" pass $BM_2813_PASS)"
  # shellcheck disable=SC2086 # 名前の列を語に割る
  got_f="$(flipped "$M/hooks/guard-exit-code.sh" fire $BM_2813_FIRE)"
  if [ "${got_p# }" = "$want_p" ] && [ "${got_f# }" = "$want_f" ]; then ok "${name}: $msg"
  else bad "${name}: 反転した集合が違う: pass=[${got_p# }]（期待 [$want_p]） fire=[${got_f# }]（期待 [$want_f]）"; fi
}
# BM8: fail-fast の判定（failfast_tail）を消す。`git checkout -- <file> || exit 1` と `[ -d "$ROOT" ] || exit 9` が
# 握り潰しへ戻り、pass はその 2 件だけが deny へ倒れ、exit $rc を欠いた 2 本は準備の行を名指す
# （`cd <dir> || exit 2` は cd が起動ではないので、pass-obs468-cd-exit-review.txt も通ったまま）
bm_expect bm8 "$FAILFAST_AWK { print }" \
  "pass-prep-or-exit-build-e2e.txt pass-prep-test-or-exit.txt pass-prep-test-bang.txt" \
  "fire-prep-or-exit-build-e2e.txt fire-prep-or-exit-run-all.txt fire-review2-test-status-after-cd.txt" \
  "fail-fast の判定を消すと、|| exit N の準備の行を持つ pass 3 件が deny へ倒れ、fire 3 件が準備の行・[ \$? … ] || exit 1 の行を名指す"
M="$TEST_TMP/bm8b"
if make_mutant "$M" "$FAILFAST_AWK { print }"; then
  got="$(flipped "$M/hooks/guard-exit-code.sh" pass pass-obs468-cd-exit-review.txt)"
  if [ -z "$got" ]; then ok "bm8b: fail-fast の判定を消しても cd <dir> || exit 2 の本文は通ったまま（cd は起動ではない）"
  else bad "bm8b: fail-fast の判定を消すと cd <dir> || exit 2 の本文まで deny へ倒れる"; fi
fi
# BM9: `exit 0`（と 256 の倍数）まで fail-fast とみなす。準備の失敗を `|| exit 0` で握り潰す本文だけが素通しになる
bm_expect bm9 'index($0, "return ((v + 0) % 256 != 0)") { print "  return 1"; next } { print }' \
  "" "fire-prep-or-exit0.txt" \
  "exit 0 まで fail-fast とみなすと、|| exit 0 で準備の失敗を握り潰す 1 件だけが素通しになる"
# BM10: 表示だけの区間（git status / tail）を起動へ戻す。Issue の本文と cp ⏎ git status ⏎ ゲートが deny へ倒れ、
# exit $rc を欠いた 2 本はゲートの起動行ではなく git status の行を名指す（この Issue が直す誤検知そのもの）
bm_expect bm10 'index($0, "if (is_display_only(s)) return 0") { next } { print }' \
  "pass-prep-or-exit-build-e2e.txt pass-prep-cp-status-gate.txt pass-prep-stderr-display.txt" \
  "fire-prep-or-exit-build-e2e.txt fire-prep-or-exit-run-all.txt" \
  "表示だけの区間を起動へ戻すと、表示の行を挟む pass 3 件が deny へ倒れ、exit \$rc を欠いた 2 本がゲートの起動行を示さなくなる"
# BM11: 起動の無い行越しに準備の rc を待つ判定（状態 3 への移行）を無効にする
bm_expect bm11 'index($0, "g_prep && gi == 0 && mask(line, 1) !~ /[$][?]/) {") { print "    } else if (0) {"; next } { print }' \
  "pass-prep-mkdir-cd-exit.txt pass-prep-cp-status-gate.txt" "" \
  "起動の無い行越しの引き継ぎを無効にすると、mkdir ⏎ cd ⏎ ゲートと cp ⏎ git status ⏎ ゲートの 2 件だけが deny へ倒れる"
# BM12: 状態 3 を状態 1（`$?` の持ち越し）へ戻す — 単位の終端で報告されず、cd の後の rc=$? を準備の rc として
# 捕獲する（PR のクロスモデルレビューが示した形）
bm_expect bm12 '$0 == "      g_state = 3" { print "      g_state = 1"; next } { print }' \
  "" "fire-prep-mkdir-cd-end.txt fire-review-capture-after-cd.txt fire-review-recapture-test.txt fire-review2-test-status-after-cd.txt" \
  "状態 3 を \$? の持ち越しへ戻すと、mkdir ⏎ cd ⏎ export で終わる本文と、cd の後の \$? を準備の rc として読む 3 本の計 4 件が素通しになる"
# BM13: set などシェルの状態を変える組み込みを起動へ戻す
bm_expect bm13 'index($0, "if (w ~ /^(set|shopt|unset|umask|trap)$/) return 0") { next } { print }' \
  "pass-set-pipefail-preface.txt" "" \
  "set を起動へ戻すと、1 行目が set -uo pipefail の 1 件だけが deny へ倒れる"
# BM14: 状態 3 で `$?` を読む行を落とす判定を消す（`cd` の rc を準備の rc として読む形）
bm_expect bm14 'index($0, "    else if (gi == 0 && mask(line, 1) !~ /[$][?]/) return") { print "    else if (gi == 0) return"; next } { print }' \
  "" "fire-review-recapture-test.txt" \
  "状態 3 の \$? の判定を消すと、cd の後の rc=\$? ⏎ [ … ] || exit 1 ⏎ ゲートの 1 件だけが素通しになる"
# BM15: fail-fast の判定から、単位の中でブロックの印が一度でも出た行以降の除外（blk_ever）を消す
bm_expect bm15 'index($0, "  if (blk_ever) return 0") { next } { print }' \
  "" "fire-review-subshell-or-exit.txt fire-review2-multiline-subshell.txt fire-review3-group-pipe.txt fire-review3-while-pipe.txt fire-review3-group-bg.txt fire-review5-subshell-arg-keyword.txt fire-review6-time-group-pipe.txt fire-review6-coproc.txt fire-review6-bang.txt fire-review7-exit-trap.txt" \
  "ブロックの印の除外を消すと、サブシェル・パイプや & に繋いだグループ・パイプに繋いだ while・time { }・coproc・先頭の !・trap の後の gate || exit 1 の 10 件だけが素通しになる（閉じ括弧が exit に付く形は exit の照合が止める）"
# BM16: ゲートの直後が `||` という条件を、末尾の区切り子が `||` であることへ緩める（ゲートと `||` の間の別の区間を許す）
bm_expect bm16 'index($0, "  if (n != gi + 1 || seps[gi] != \"||\") return 0") { print "  if (seps[n - 1] != \"||\") return 0"; next } { print }' \
  "" "fire-review-and-pipe-or-exit.txt" \
  "ゲートと || の間の区間を許すと、gate1 && gate2 | tail || exit 1 の 1 件だけが素通しになる"
# BM17: fail-fast の exit の照合を strip_prefix 越しへ戻す（ラッパ越しの exit を通す）
bm_expect bm17 '$0 == "  t = segs[n]" { print "  t = strip_prefix(segs[n])"; next } { print }' \
  "" "fire-review-wrapper-exit.txt" \
  "exit の照合をラッパ越しへ戻すと、|| env exit 1 の 1 件だけが素通しになる"
# BM18: 表示の判定からファイルへ書く形（`>` / heredoc）の除外を消す
bm_expect bm18 'index($0, "if (index(t, \">\") || index(t, \"<<\")) return 0") { next } { print }' \
  "" "fire-review-cat-redirect.txt fire-review-heredoc-cat-echo.txt" \
  "ファイルへ書く形の除外を消すと、cat a b > c と heredoc の cat の 2 件だけが素通しになる"

# BM20: 状態 3 で、起動までの区間が $? を読む行も引き継ぐ（`[ $? -eq 0 ] || exit 1` の `[` へ渡す）
bm_expect bm20 'index($0, "    if (gi > 0 && !q) g_state = 0") { print "    if (gi > 0) g_state = 0"; next } { print }' \
  "" "fire-review2-test-status-after-cd.txt" \
  "起動の区間の \$? の判定を消すと、cd の後の [ \$? -eq 0 ] || exit 1 の 1 件だけが素通しになる"
# BM21: tee を表示へ戻す（引数のファイルへ書く tee の失敗を落とす）
bm_expect bm21 'index($0, "  if (w == \"tee\") return 0") { next } { print }' \
  "" "fire-review2-tee-file.txt" \
  "tee の除外を消すと、tee FILE < in ⏎ echo の 1 件だけが素通しになる"
# BM22: 標準エラー出力の向け先・fd の複製を、ファイルへ書く形として数える（`tail … 2>/dev/null` を主体へ戻す）
bm_expect bm22 'index($0, "  t = s; gsub(/[0-9]*>&[0-9-]+/") { print "  t = s"; next } { print }' \
  "pass-prep-stderr-display.txt" "" \
  "stderr の向け先の扱いを消すと、tail … 2>/dev/null と git status 2>&1 を挟む pass 1 件だけが deny へ倒れる"
# BM23: 予約語をブロックの印に数えない（括弧・波括弧・先頭の `!` だけを印にする）
bm_expect bm23 'index($0, "  for (i = 1; i <= k; i++) if (arr[i] ~ /^(if|then|else|elif|fi|for|while|until|select|do|done|case|esac|function|time|copro[c]|trap)$/) blk_seen = 1") { next } { print }' \
  "" "fire-review3-while-pipe.txt fire-review6-coproc.txt fire-review7-exit-trap.txt" \
  "予約語と trap を印に数えないと、パイプに繋いだ while の本体・coproc・trap 'exit 0' EXIT の後の 3 件だけが素通しになる"
# BM26: 波括弧をブロックの印に数えない（PR のクロスモデルレビュー 5 巡目: `time {` の波括弧を位置の読み違えで取りこぼした）
bm_expect bm26 'index($0, "  blk_seen = (m ~ /[(){}]/)") { print "  blk_seen = (m ~ /[()]/)"; next } { print }' \
  "" "fire-review3-group-pipe.txt fire-review3-group-bg.txt" \
  "波括弧を印に数えないと、パイプや & に繋いだグループの 2 件だけが素通しになる（time { … } は time の語でも止まる）"
# BM27: 区間の先頭の `!`（終了コードの反転）を印に数えない
bm_expect bm27 'index($0, "if (t ~ /^!([[:space:]]|$)/) blk_seen = 1 }") { next } { print }' \
  "" "fire-review6-bang.txt" \
  "先頭の ! を印に数えないと、! git checkout … || exit 1 の 1 件だけが素通しになる"
# BM28: `!` を区間の先頭に限らず印に数える — 偽の緑は開かないが、`[ ! -f x ] || exit 9`（test の演算子）まで止める
bm_expect bm28 'index($0, "if (t ~ /^!([[:space:]]|$)/) blk_seen = 1 }") { sub(/\^!/, "(^|[[:space:]])!"); print; next } { print }' \
  "pass-prep-test-bang.txt" "" \
  "! を区間の先頭に限らず数えると、[ ! -f … ] || exit 9 の pass 1 件だけが deny へ倒れる"
echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ bg-prefix: ${FAIL} 件失敗（成功 ${PASS} 件）" >&2
  REACHED_END=1
  exit 1
fi
echo "✅ bg-prefix: all ${PASS} checks passed"
REACHED_END=1
exit 0
