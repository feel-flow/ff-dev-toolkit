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
for want in pass-obs460- pass-obs468- pass-obs475- pass-obs484- pass-obs475-bare-cd.txt pass-obs475-ff-root-assign.txt; do
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
    "$PLUGIN_ROOT/tests/lib/exit-code-rewrite.sh" "$PLUGIN_ROOT/tests/lib/rg-stdin-scan.sh" "$1/tests/lib/"
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

# BM1: 背景実行の判定を修正前へ戻す（代入・cd・exit を起動から外す判定と、準備の行から後続の
# 起動への引き継ぎを無効にする）。OBS の pass の本文がすべて deny へ倒れる
M="$TEST_TMP/bm1"
if make_mutant "$M" "$EXCL_AWK $HANDOVER_AWK { print }"; then
  # shellcheck disable=SC2086 # 名前の列を語に割る
  got="$(flipped "$M/hooks/guard-exit-code.sh" pass $BM_ALL_PASS)"
  if [ "$got" = " $BM_ALL_PASS" ]; then ok "BM1: 背景実行の判定を修正前へ戻すと、OBS-460 / 468 / 475 / 484 と mkdir の pass の本文 12 件がすべて deny へ倒れる"
  else bad "BM1: 修正前へ戻しても deny へ倒れたのは [${got# }] だけ"; fi
fi
# BM2: 起動から外す判定だけを無効にする。代入・素の cd の行は準備の行ではないので後続の起動へ
# 引き継がれず、OBS-468 / 475 / 484 の本文も、cd <dir> || exit 2 の本文（同じ行の握り潰し）も止まる
M="$TEST_TMP/bm2"
if make_mutant "$M" "$EXCL_AWK { print }"; then
  BM2_PASS="pass-obs460-assign-wsl-gate.txt pass-obs460-cd-exit-heredoc.txt pass-obs468-assign-wsl.txt pass-obs468-cd-exit-review.txt pass-obs468-assign-precommit.txt pass-obs475-assign-run-all.txt pass-obs475-cd-exit-root-review.txt pass-obs475-assign-echo-cat.txt pass-obs475-bare-cd.txt pass-obs475-ff-root-assign.txt pass-obs484-assign-npm-run-all.txt"
  # shellcheck disable=SC2086 # 名前の列を語に割る
  got="$(flipped "$M/hooks/guard-exit-code.sh" pass $BM2_PASS pass-prep-mkdir.txt)"
  if [ "$got" = " $BM2_PASS" ]; then
    ok "BM2: 代入・cd・exit を起動に数えると OBS の pass 11 件が deny へ倒れ、mkdir の準備の行は引き継ぎで通ったまま"
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
# コマンドが奪う形を素通しする（レビューで別モデル 2 本が指摘した偽の緑）
M="$TEST_TMP/bm4"
if make_mutant "$M" 'index($0, "!is_prep_launch(segs[i])) g_prep = 0") { next } { print }'; then
  BM4_FIRE="fire-review-sed-after-test.txt fire-review-build-after-test.txt fire-review-rm-after-test.txt fire-handover-grep-after-gate.txt fire-handover-tail-after-gate.txt fire-named-gate-overwritten.txt"
  # shellcheck disable=SC2086 # 名前の列を語に割る
  got="$(flipped "$M/hooks/guard-exit-code.sh" fire $BM4_FIRE)"
  if [ "$got" = " $BM4_FIRE" ]; then
    ok "BM4: どの起動も準備とみなすと、検査・run-all.sh の rc を後続の sed / build / rm / grep / tail が奪う 6 件でゲートの起動行を示さなくなる"
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

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ bg-prefix: ${FAIL} 件失敗（成功 ${PASS} 件）" >&2
  REACHED_END=1
  exit 1
fi
echo "✅ bg-prefix: all ${PASS} checks passed"
REACHED_END=1
exit 0
