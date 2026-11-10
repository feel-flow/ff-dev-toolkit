#!/usr/bin/env bash
# 単語分割の書き換えが先頭へ付ける `setopt SH_WORD_SPLIT; ` を、終了コードガードが
# 起動と読まずに判定することを固定する。verify.sh の末尾から呼ばれ、単独でも回せる。
#
# fixture の本文は字面を直書きする。共有定義 `FF_ZSH_WORD_SPLIT_PREFIX` の値から
# 組み立てない。定義の値から組むと、定義を変える変異が fixture ごと動き、検査が緑のまま残る。
# 近い別の文（`setopt shwordsplit; `。末尾の空白は同じで、オプション名だけ違う）は剥がさない。
# 剥がす対象を広げたとき、隣の形まで通る退行をこの fixture が赤にする。
#
#   ZP. pass-*.txt: 終了コードを `exit $rc` まで伝播する背景起動は hook が止めない。
#       字面の前置きを外した本文を exit_code_scan しても、素・背景実行とも 0 件
#       （hook は判定を足していない）
#   ZF. fire-*.txt: 伝播を欠いた本文は `gate-exit-dropped` で止まり、名指しはゲートの
#       起動行。近い別の文で始まる伝播本文は、その先頭行を名指して止まる（剥がさない）
#   ZM. 共有定義を別の文へ変える前のコピーは、伝播する fixture を止めない。変えたコピーは
#       `gate-exit-dropped` で止め、名指しは fixture の先頭行（deny だけだと、コピーの欠落も緑になる）
#
# 空振り検出: fixture のディレクトリが無い、pass が 2 件未満、expect.tsv の行が
# fire-*.txt の数と合わない、pass と fire-dropped の本文が字面 `setopt SH_WORD_SPLIT; ` を
# 持たない、fire-near-shwordsplit がその字面を含む、または本文が共有定義の変数名を含むなら赤。
# 変異の前提: fixture は定義を参照せず字面を持つ。定義を変えても fixture の字面は残るので、
# hook が定義を読んでいるときだけ剥がしが外れ、伝播する本文を止める。字面を定義の展開へ
# 替えた fixture では、この変異は検出器の退行ではない空振りになる。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$PLUGIN_ROOT/hooks/guard-exit-code.sh"
DETECTOR="$PLUGIN_ROOT/tests/lib/exit-code-guard.sh"
PREFIX_LIB="$PLUGIN_ROOT/tests/lib/zsh-word-split-prefix.sh"
FIXTURES="$SCRIPT_DIR/fixtures/zsh-prefix"
# 検査が比較に使う字面。共有定義から読まない（上の注記）。
LITERAL='setopt SH_WORD_SPLIT; '
# shellcheck source=../lib/adapter-env-isolation.sh
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"
isolate_hook_env "FF_DEV_TOOLKIT_SKIP" "$TARGET"
[ -f "$TARGET" ] || { echo "✗ guard-exit-code.sh が見つかりません: $TARGET" >&2; exit 1; }
[ -f "$DETECTOR" ] || { echo "✗ 検出器が見つかりません: $DETECTOR" >&2; exit 1; }
[ -d "$FIXTURES" ] || { echo "✗ fixture のディレクトリが見つかりません: $FIXTURES" >&2; exit 1; }
if ! command -v jq >/dev/null 2>&1; then
  echo "○ skip: jq が見つからないためスキップ（zsh-prefix は未検査のままです）"
  exit 0
fi
unset FF_EXIT_CODE_ACK FF_EXIT_CODE_GUARD_GATES ff_exit_code_any_launch FF_ZSH_WORD_SPLIT_PREFIX

if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/ff-zsh-prefix.XXXXXX" 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
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
    echo "✗ zsh-prefix: 最後まで到達しませんでした" >&2
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

# 字面の前置きが 1 行目の先頭にあるときだけ、その 1 つを外した本文を書く。
# 定義の値は見ない。無い・違う文はそのまま。
body_without_literal() { # <fixture> <dst>
  local first rest
  IFS= read -r first <"$1" || first=""
  case "$first" in
    "$LITERAL"*) first="${first#"$LITERAL"}" ;;
  esac
  {
    printf '%s\n' "$first"
    tail -n +2 "$1"
  } >"$2"
}

scan_first() { # <file> <static|bg>
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

echo "zsh-prefix: fixture の集合（空振り検出）"
if [ "${#PASS_FILES[@]}" -ge 2 ]; then ok "pass の fixture が ${#PASS_FILES[@]} 件ある"; else bad "pass の fixture が少ない（${#PASS_FILES[@]} 件）"; fi
if [ "$FIRE_N" -gt 0 ] && [ "$FIRE_N" = "$EXPECT_N" ]; then
  ok "fire の fixture ${FIRE_N} 件すべてに expect.tsv の期待値がある"
else
  bad "fire の fixture（${FIRE_N} 件）と expect.tsv の行（${EXPECT_N:-0} 件）が合わない"
fi
for f in ${PASS_FILES[@]+"${PASS_FILES[@]}"} "$FIXTURES/fire-dropped.txt"; do
  name="${f##*/}"
  if grep -F -q "$LITERAL" "$f"; then
    ok "$name: 共有定義の字面を本文に持つ"
  else
    bad "$name: 共有定義の字面が本文に無い（定義の値から組むと変異が空振りになる）"
  fi
  if grep -F -q 'FF_ZSH_WORD_SPLIT_PREFIX' "$f"; then
    bad "$name: 本文が共有定義の変数名を含む"
  else
    ok "$name: 本文は共有定義の変数を参照しない"
  fi
done
if grep -F -q "$LITERAL" "$FIXTURES/fire-near-shwordsplit.txt"; then
  bad "fire-near-shwordsplit.txt: 共有定義の字面を含んでいる（剥がす対象と区別できない）"
else
  ok "fire-near-shwordsplit.txt: 共有定義の字面を含まない"
fi

echo "zsh-prefix: ZP — 伝播している本文は止めない（字面を外した本文の判定と一致する）"
for f in ${PASS_FILES[@]+"${PASS_FILES[@]}"}; do
  name="${f##*/}"
  run_bg_on "$TARGET" "$f"
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "$name: hook は止めない"; else bad "$name: hook が止めた: exit=$RC tag=[$HOOK_TAG] line=[$HOOK_LINE]"; fi
  body_without_literal "$f" "$TEST_TMP/body.txt"
  s="$(scan_first "$TEST_TMP/body.txt" static)"
  b="$(scan_first "$TEST_TMP/body.txt" bg)"
  if [ -z "$s" ] && [ -z "$b" ]; then
    ok "$name: 字面を外した本文の exit_code_scan は素・背景実行とも 0 件"
  else
    bad "$name: 字面を外した本文を exit_code_scan が当てた: 素=[$s] 背景=[$b]"
  fi
done

echo "zsh-prefix: ZF — 伝播を欠いた本文はゲートの起動行で止め、近い別の文は剥がさない"
while IFS="$(printf '\t')" read -r name tag line; do
  case "$name" in '#'*|'') continue ;; esac
  f="$FIXTURES/$name"
  [ -f "$f" ] || { bad "$name: fixture がありません"; continue; }
  run_bg_on "$TARGET" "$f"
  if [ "$RC" -eq 0 ] && [ "$DECISION" = deny ] && [ "$HOOK_TAG" = "$tag" ]; then
    ok "$name: hook は $tag で止める"
  else
    bad "$name: hook の判定が違う: exit=$RC decision=[$DECISION] tag=[$HOOK_TAG] line=[$HOOK_LINE]"
  fi
  if [ "$HOOK_LINE" = "$line" ]; then
    ok "$name: 検出した形は期待した行"
  else
    bad "$name: 検出した形が違う: [$HOOK_LINE]（期待: [$line]）"
  fi
  body_without_literal "$f" "$TEST_TMP/body.txt"
  b="$(scan_first "$TEST_TMP/body.txt" bg)"
  if [ "$b" = "$HOOK_TAG	$HOOK_LINE" ]; then
    ok "$name: hook と、字面を外した本文の背景実行の exit_code_scan が一致する"
  else
    bad "$name: hook と字面を外した本文の exit_code_scan が食い違う: hook=[$HOOK_TAG	$HOOK_LINE] scan=[$b]"
  fi
done <"$FIXTURES/expect.tsv"

echo "zsh-prefix: ZM — 共有定義を別の文へ変えると、伝播する本文を先頭行で止める"
make_tree() { # <dir>
  mkdir -p "$1/hooks" "$1/tests/lib"
  cp "$TARGET" "$PLUGIN_ROOT/hooks/asdd-hook-gate.sh" "$PLUGIN_ROOT/hooks/asdd-feature.mjs" "$1/hooks/"
  cp "$DETECTOR" "$PLUGIN_ROOT/tests/lib/heredoc-strip.sh" "$PLUGIN_ROOT/tests/lib/wait-bounds.sh" \
    "$PLUGIN_ROOT/tests/lib/exit-code-rewrite.sh" "$PLUGIN_ROOT/tests/lib/rg-stdin-scan.sh" "$1/tests/lib/"
  if [ -f "$PREFIX_LIB" ]; then cp "$PREFIX_LIB" "$1/tests/lib/zsh-word-split-prefix.sh"; fi
}
first_line() { # <file>
  local line
  IFS= read -r line <"$1" || line=""
  printf '%s' "$line"
}
if [ -f "$PREFIX_LIB" ]; then
  MUT="$TEST_TMP/zm"
  make_tree "$MUT"
  zm_ctrl=0
  for f in ${PASS_FILES[@]+"${PASS_FILES[@]}"}; do
    name="${f##*/}"
    run_bg_on "$MUT/hooks/guard-exit-code.sh" "$f"
    if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
      ok "ZM 対照: $name は変異前のコピーでは止まらない"
    else
      bad "ZM 対照: $name は変異前のコピーが止めた: exit=$RC decision=[$DECISION] tag=[$HOOK_TAG] line=[$HOOK_LINE]"
      zm_ctrl=1
    fi
  done
  if [ "$zm_ctrl" -eq 0 ]; then ok "ZM 対照: コピーそのものは伝播する本文を止めない"; fi
  sed "s/FF_ZSH_WORD_SPLIT_PREFIX='setopt SH_WORD_SPLIT; '/FF_ZSH_WORD_SPLIT_PREFIX='setopt OTHER; '/" \
    "$PREFIX_LIB" >"$MUT/tests/lib/zsh-word-split-prefix.sh"
  if cmp -s "$PREFIX_LIB" "$MUT/tests/lib/zsh-word-split-prefix.sh"; then
    bad "ZM: 共有定義の代入が sed に一致しない"
  else
    ok "ZM: 共有定義を別の文へ変えた"
    zm_fail=0
    for f in ${PASS_FILES[@]+"${PASS_FILES[@]}"}; do
      name="${f##*/}"
      want="$(first_line "$f")"
      run_bg_on "$MUT/hooks/guard-exit-code.sh" "$f"
      if [ "$RC" -eq 0 ] && [ "$DECISION" = deny ] && [ "$HOOK_TAG" = gate-exit-dropped ] && [ "$HOOK_LINE" = "$want" ]; then
        ok "ZM: $name は gate-exit-dropped で先頭行を名指して止まる"
      else
        bad "ZM: $name の変異後が違う: exit=$RC decision=[$DECISION] tag=[$HOOK_TAG] line=[$HOOK_LINE]（期待: [$want]）"
        zm_fail=1
      fi
    done
    if [ "$zm_fail" -eq 0 ]; then ok "ZM: 伝播する fixture は定義の変異で先頭行を名指して止まる"; fi
  fi
else
  bad "ZM: 共有定義のファイルがありません: $PREFIX_LIB"
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ zsh-prefix: ${FAIL} 件失敗（成功 ${PASS} 件）" >&2
  REACHED_END=1
  exit 1
fi
echo "✅ zsh-prefix: all ${PASS} checks passed"
REACHED_END=1
exit 0
