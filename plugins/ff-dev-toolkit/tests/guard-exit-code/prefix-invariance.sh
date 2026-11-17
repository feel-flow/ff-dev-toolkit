#!/usr/bin/env bash
# Issue `#2832`: 背景実行（run_in_background）の判定が、意味を変えない行を足しても変わらないことを
# 確かめる。verify.sh の末尾から呼ばれ、単独でも回せる。
#
# bg-prefix.sh は導入先で止められた本文を fixture として 1 形ずつ固定する。こちらは期待値表を
# 持たず、「行を足す前と後で判定が同じ」という関係だけを、行の集合 × 本文の集合の組み合わせに当てる。
# 同じ穴の隣接形（Issue `#2672` の後に Issue `#2813` で直した `set -u` / `umask` / `wc -l` /
# `test -d … || exit 2` など）を、報告を待たずに赤にするための検査である。
#
#   PB. 基準: 本文の集合（ゲートの起動 2 種 × 終了コードの扱い 8 種）の判定を期待値と照合する。
#       関係の検査は「全部が止めない」検出器でも成り立つので、基準の止める・止めないをここで固定する
#   PP. 準備の行（代入・cd・mkdir・export など）を本文の前へ 1 つ足しても、検出の一覧（タグと
#       名指す行。行番号は比べない）が変わらない
#   PQ. 準備の行を 2 つ並べて足しても変わらない（2 行目以降の準備の行の引き継ぎ）
#   PD. 終了コードを変数へ受けた後に、表示だけの行（tail / wc / echo など）を足しても変わらない
#   PS. 区切りを改行から `;` へ替えた 1 行の形でも、止める・止めないが変わらない（タグは dropped /
#       swallowed で分かれるので比べない）。区切りを持つ本文 4 種だけが対象
#   PI. 各行を字下げしても変わらない
#   PX. 現行の検出器で判定が変わる形の名簿（下の PINNED_*）は、変わる側として固定する。
#       コマンド置換の代入は、置換の中の起動を数えると検出器が定めている（is_gate_launch のコメント）。
#       `:` / `source` / `.` / `grep` / `sed` / `ls` は、起動から外す語彙（cd・export・set などの組み込みと、
#       is_fmt_word・`git status` の表示の語彙）に入っていないので既定で起動に数える。表示の語でも
#       ファイルへ書く形（`tail … > <file>`）は表示にしない（is_display_only）。名簿の形を通す側へ
#       変えたら、名簿と PREP / SHOW_LINES を同じ変更で動かす。名簿は 2026-11-17 の再現実験で残った形で、
#       判定が変わる形の網羅ではない（たとえば `for … done` などブロックの印を持つ行を `|| exit N` の
#       本文の前へ足すと、fail-fast の例外から外れて止まる）
#   PK. 既知の食い違い: 1 行の `<ゲート>; rc=$?; exit "$rc"`（引用符付き）は、複数行なら止めないのに
#       gate-exit-swallowed で止まる（Issue `#2837`）。直すまでは止まる側として固定し、直したら
#       この固定を外して PS の対象へ戻す
#   PM. 変異検出: 検出器の規則を 1 つ外したコピーで、判定が変わる行の集合を期待と照合する
#
# 空振り検出: 行の集合・本文の集合・検査した件数が下の下限を割る、検出器が無い・読めない、検出器が
# awk の失敗で判定を返さない、行を差し込めず基準と同じ本文を比べている、変異の置換が検出器に
# 当たらない、のいずれも赤。
# 実測（2026-11-17 macOS /bin/bash 3.2）: 検出器の無いツリーへ置くと冒頭の 1 件で rc=1。
# FF_EXIT_CODE_AWK=/usr/bin/false では 46 件失敗（rc=1）。
# 変異検出（同日実測）: このスクリプトを過去の版のツリーへ置いて回すと、Issue `#2672` の修正前
# （84db5538）は 9 件失敗（PP 336 件中 272 件・PQ 336 件中 320 件・PD 42 件中 18 件で検出が変わる）、
# Issue `#2813` の修正前（607494bc）も 9 件失敗（PP 96 件・PQ 138 件・PD 18 件）。どちらも rc=1。
# Issue `#2813` の修正後（5e3f221d）と現在の検出器では 0 件（50 件すべて成功、所要 6〜8 秒）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DETECTOR="$PLUGIN_ROOT/tests/lib/exit-code-guard.sh"
if [ ! -f "$DETECTOR" ] || [ ! -r "$DETECTOR" ]; then
  echo "✗ prefix-invariance: 検出器が無いか読めません: ${DETECTOR}" >&2
  exit 1
fi
unset FF_EXIT_CODE_ACK FF_EXIT_CODE_GUARD_GATES ff_exit_code_any_launch

if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/ff-prefix-invariance.XXXXXX" 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  TEST_TMP="$_ff_mktemp_out"
else
  echo "✗ 一時ディレクトリを作成できません: ${_ff_mktemp_out}" >&2
  exit 1
fi
REACHED_END=0
cleanup() {
  local rc=$?
  rm -rf "$TEST_TMP"
  if [ "$REACHED_END" -ne 1 ] && [ "$rc" -eq 0 ]; then
    echo "✗ prefix-invariance: 最後まで到達しませんでした" >&2
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

NL='
'
GATES=(
  'bash plugins/ff-dev-toolkit/tests/run-all.sh > /tmp/sp/run.log 2>&1'
  'npm test > /tmp/sp/run.log 2>&1'
)
# 本文の種類。名前 / 期待する基準の判定（名簿のゲート / 名簿外のゲートの順。allow か deny:<タグ>）
BODY_NAMES=(propagate bare or-exit1 echo-status dropped-exit pipe-tail quoted-exit and-echo)
BODY_EXPECT_NAMED=(allow allow allow deny:gate-exit-dropped deny:gate-exit-dropped deny:gate-exit-swallowed allow allow)
BODY_EXPECT_OTHER=(allow allow allow deny:gate-exit-dropped deny:gate-exit-dropped deny:gate-exit-swallowed allow allow)

# 本文を組み立てる。$1 = ゲートの起動、$2 = 種類、$3 = 区切り（nl = 文ごとに改行、semi = 全部を `; ` で
# 繋いだ 1 行）
body_text() {
  local g="$1" kind="$2" s="$NL"
  if [ "$3" = semi ]; then s='; '; fi
  case "$kind" in
    propagate) printf '%s%s%s%s%s%s%s' "$g" "$s" 'rc=$?' "$s" 'echo "EXIT=$rc"' "$s" 'exit $rc' ;;
    bare) printf '%s' "$g" ;;
    or-exit1) printf '%s || exit 1' "$g" ;;
    echo-status) printf '%s%s%s' "$g" "$s" 'echo "EXIT=$?"' ;;
    dropped-exit) printf '%s%s%s%s%s' "$g" "$s" 'rc=$?' "$s" 'echo "EXIT=$rc"' ;;
    pipe-tail) printf '%s | tail -5' "$g" ;;
    quoted-exit) printf '%s%s%s%s%s' "$g" "$s" 'rc=$?' "$s" 'exit "$rc"' ;;
    and-echo) printf '%s && echo ok' "$g" ;;
    *) return 1 ;;
  esac
}
# `rc=$?` を独立した行で受ける本文か（表示の行を足せる位置がある）
body_has_rc_line() {
  case "$1" in propagate | dropped-exit | quoted-exit) return 0 ;; *) return 1 ;; esac
}
# 文の区切りを持つ本文か（`;` の 1 行形が改行の形と別の文字列になる）
body_has_separator() {
  case "$1" in propagate | echo-status | dropped-exit | quoted-exit) return 0 ;; *) return 1 ;; esac
}

# 準備の行: 足しても判定が変わらない集合。最後の 2 形は heredoc でスクリプトを書く行で、
# 終端まである形と、hook が本文と終端を落とした後に検出器へ届く開始行だけの形
PREP=(
  'cd /path/to/repo'
  'cd /path/to/repo || exit 2'
  'SP=/tmp/sp'
  'LOG="$SP/run.log"'
  'A=1 B=2'
  'export FOO=bar'
  'export A=1 B=2'
  'mkdir -p /tmp/sp'
  'mkdir -p /tmp/sp || exit 2'
  'set -u'
  'echo "start"'
  "printf 'start\\n'"
  '# comment'
  ''
  'git status --short'
  'rm -f /tmp/sp/run.log'
  'test -d /tmp/sp || exit 2'
  '[ -d /tmp/sp ] || exit 2'
  'umask 022'
  "cat > /tmp/sp/x.sh <<'EOF'${NL}echo hi${NL}EOF"
  "cat > /tmp/sp/x.sh <<'EOF'"
)
# 表示だけの行: rc を受けた後へ足しても判定が変わらない集合
SHOW_LINES=(
  'tail -n 15 /tmp/sp/run.log'
  'echo "done at $(date)"'
  'wc -l /tmp/sp/run.log'
  '# comment'
  ''
  "printf 'rc=%s\\n' \"\$rc\""
  'cat /tmp/sp/run.log | tail -3'
)
# 現行の検出器で判定が変わる形（PX）。足すと、伝播している本文でもその行を名指して止める
PINNED_PREP=(
  'TS=$(date +%s)'
  'TS=`date +%s`'
  'A=1 B=$(pwd)'
  ': > /tmp/sp/run.log'
  '. ./env.sh'
  'source ./env.sh'
)
PINNED_SHOW=(
  'grep -c FAIL /tmp/sp/run.log'
  "sed -n '1,5p' /tmp/sp/run.log"
  'ls -la /tmp/sp'
  'tail -n 15 /tmp/sp/run.log > /tmp/sp/tail.txt'
)
# 準備の行を 2 つ並べるときの相手（PQ）
CARRIERS=(
  'cd /path/to/repo || exit 2'
  'mkdir -p /tmp/sp'
  'SP=/tmp/sp'
  'echo "start"'
)

V_DEC=""
V_TAG=""
V_LINE=""
V_ALL=""
# 背景実行の判定（hook が使う方）を取る。$1 = 検出器、$2 = 本文。
# V_DEC = allow / deny / error、V_TAG / V_LINE = 最初の 1 件、V_ALL = 全件の「タグ:論理行」
# （行番号と字下げは落とす）。検出器が失敗したら V_DEC=error（判定を返さないことを緑へ倒さない）
verdict() {
  local det="$1" text="$2" out one rest tag line
  V_DEC=""
  V_TAG=""
  V_LINE=""
  V_ALL=""
  if ! out="$(
    # shellcheck source=../lib/exit-code-guard.sh
    . "$det" || exit 97
    export ff_exit_code_any_launch=1
    exit_code_scan <<<"$text"
  )"; then
    V_DEC=error
    return 0
  fi
  if [ -z "$out" ]; then
    V_DEC=allow
    return 0
  fi
  V_DEC=deny
  while IFS= read -r one || [ -n "$one" ]; do
    rest="${one#*:}"
    tag="${rest%%:*}"
    line="${rest#*:}"
    line="${line#"${line%%[![:space:]]*}"}"
    if [ -z "$V_ALL" ]; then
      V_TAG="$tag"
      V_LINE="$line"
    fi
    V_ALL="${V_ALL}${tag}:${line}${NL}"
  done <<<"$out"
}

REL_DETAIL=""
B_DEC=""
B_ALL=""
# 基準の判定を B_* へ取る（同じ基準へ行を足した本文を続けて比べるので、基準は 1 回だけ判定する）
set_base() { # <検出器> <基準の本文>
  verdict "$1" "$2"
  B_DEC="$V_DEC"
  B_ALL="$V_ALL"
}
# 関係を 1 件検査する。比べる範囲は full = 検出の一覧（タグと名指す行）、dec = 止める・止めないだけ。
# 戻り値 0 = 一致
relation_holds() { # <検出器> <行を足した本文> <範囲> — 直前の set_base の基準と比べる
  verdict "$1" "$2"
  REL_DETAIL="基準=[${B_DEC}] 結果=[${V_DEC}:${V_TAG}] 名指し=[${V_LINE}]"
  if [ "$B_DEC" = error ] || [ "$V_DEC" = error ]; then return 1; fi
  if [ "$B_DEC" != "$V_DEC" ]; then return 1; fi
  if [ "$3" = dec ]; then return 0; fi
  if [ "$B_ALL" != "$V_ALL" ]; then return 1; fi
  return 0
}

# 各行を 2 文字下げた本文を返す
indent_text() {
  local line out=""
  while IFS= read -r line || [ -n "$line" ]; do
    out="${out}  ${line}${NL}"
  done <<<"$1"
  printf '%s' "${out%"$NL"}"
}

# 行を rc の行の直後へ差し込んだ本文を返す。$1 = 本文（改行区切り）、$2 = 足す行。
# rc の行が無ければ元の本文をそのまま返す（呼び出し側が差し込めたことを確かめる）
insert_after_rc() {
  local line out="" done_ins=0
  while IFS= read -r line || [ -n "$line" ]; do
    out="${out}${line}${NL}"
    if [ "$done_ins" -eq 0 ] && [ "$line" = 'rc=$?' ]; then
      out="${out}${2}${NL}"
      done_ins=1
    fi
  done <<<"$1"
  printf '%s' "${out%"$NL"}"
}

echo "prefix-invariance: 集合（空振り検出）"
if [ "${#PREP[@]}" -ge 21 ]; then ok "準備の行が ${#PREP[@]} 形ある"; else bad "準備の行が少ない（${#PREP[@]} 形）"; fi
if [ "${#SHOW_LINES[@]}" -ge 7 ]; then ok "表示だけの行が ${#SHOW_LINES[@]} 形ある"; else bad "表示だけの行が少ない（${#SHOW_LINES[@]} 形）"; fi
if [ "${#PINNED_PREP[@]}" -eq 6 ] && [ "${#PINNED_SHOW[@]}" -eq 4 ]; then
  ok "判定が変わる形の名簿が 10 形ある"
else
  bad "判定が変わる形の名簿の件数が違う（準備 ${#PINNED_PREP[@]} / 表示 ${#PINNED_SHOW[@]}）"
fi
if [ "${#GATES[@]}" -eq 2 ] && [ "${#BODY_NAMES[@]}" -eq 8 ] && [ "${#BODY_EXPECT_NAMED[@]}" -eq 8 ] && [ "${#BODY_EXPECT_OTHER[@]}" -eq 8 ]; then
  ok "本文の集合が 16 形ある"
else
  bad "本文の集合の件数が違う（ゲート ${#GATES[@]} / 種類 ${#BODY_NAMES[@]}）"
fi

echo "prefix-invariance: PB — 基準の判定"
gi=0
for g in "${GATES[@]}"; do
  bi=0
  for kind in "${BODY_NAMES[@]}"; do
    if [ "$gi" -eq 0 ]; then want="${BODY_EXPECT_NAMED[$bi]}"; else want="${BODY_EXPECT_OTHER[$bi]}"; fi
    verdict "$DETECTOR" "$(body_text "$g" "$kind" nl)"
    got="$V_DEC"
    if [ "$V_DEC" = deny ]; then got="deny:${V_TAG}"; fi
    if [ "$got" = "$want" ]; then ok "ゲート ${gi} の ${kind}: ${got}"; else bad "ゲート ${gi} の ${kind}: 期待 ${want} / 実際 ${got}"; fi
    bi=$((bi + 1))
  done
  gi=$((gi + 1))
done

# 関係の検査を回し、食い違った件数を数える。1 件ずつは出さず、食い違いだけを名指す
GROUP_N=0
GROUP_BAD=0
check() { # <基準の本文> <行を足した本文> <範囲> <ラベル> — 直前の set_base の基準と比べる
  GROUP_N=$((GROUP_N + 1))
  if [ "$1" = "$2" ]; then
    GROUP_BAD=$((GROUP_BAD + 1))
    echo "    ✗ ${4}: 行を足した本文が基準と同じ（比べていない）" >&2
  elif ! relation_holds "$DETECTOR" "$2" "$3"; then
    GROUP_BAD=$((GROUP_BAD + 1))
    echo "    ✗ ${4}: ${REL_DETAIL}" >&2
  fi
}
close_group() { # <見出し> <件数の下限>
  if [ "$GROUP_N" -lt "$2" ]; then
    bad "${1}: 検査した件数が下限（${2}）を割った（${GROUP_N} 件）"
  elif [ "$GROUP_BAD" -eq 0 ]; then
    ok "${1}: ${GROUP_N} 件すべて、行を足す前と判定が一致する"
  else
    bad "${1}: ${GROUP_N} 件中 ${GROUP_BAD} 件で判定が変わった（上の ✗ 行）"
  fi
  GROUP_N=0
  GROUP_BAD=0
}

echo "prefix-invariance: PP — 準備の行を 1 つ足す"
gi=0
for g in "${GATES[@]}"; do
  for kind in "${BODY_NAMES[@]}"; do
    base="$(body_text "$g" "$kind" nl)"
    set_base "$DETECTOR" "$base"
    for p in "${PREP[@]}"; do
      check "$base" "${p}${NL}${base}" full "ゲート ${gi} の ${kind} の前に [${p%%"$NL"*}]"
    done
  done
  gi=$((gi + 1))
done
close_group "PP" 336

echo "prefix-invariance: PQ — 準備の行を 2 つ並べて足す"
for pair_body in "1 propagate" "0 dropped-exit"; do
  gi="${pair_body%% *}"
  kind="${pair_body#* }"
  base="$(body_text "${GATES[$gi]}" "$kind" nl)"
  set_base "$DETECTOR" "$base"
  for p in "${PREP[@]}"; do
    for c in "${CARRIERS[@]}"; do
      check "$base" "${p}${NL}${c}${NL}${base}" full "ゲート ${gi} の ${kind} の前に [${p%%"$NL"*}] ⏎ [${c}]"
      check "$base" "${c}${NL}${p}${NL}${base}" full "ゲート ${gi} の ${kind} の前に [${c}] ⏎ [${p%%"$NL"*}]"
    done
  done
done
close_group "PQ" 336

echo "prefix-invariance: PD — rc を受けた後に表示だけの行を足す"
gi=0
for g in "${GATES[@]}"; do
  for kind in "${BODY_NAMES[@]}"; do
    if body_has_rc_line "$kind"; then
      base="$(body_text "$g" "$kind" nl)"
      set_base "$DETECTOR" "$base"
      for d in "${SHOW_LINES[@]}"; do
        check "$base" "$(insert_after_rc "$base" "$d")" full "ゲート ${gi} の ${kind} の rc の後に [${d}]"
      done
    fi
  done
  gi=$((gi + 1))
done
close_group "PD" 42

echo "prefix-invariance: PS / PI — 区切りと字下げ"
gi=0
for g in "${GATES[@]}"; do
  for kind in "${BODY_NAMES[@]}"; do
    base="$(body_text "$g" "$kind" nl)"
    set_base "$DETECTOR" "$base"
    # quoted-exit の 1 行形は既知の食い違い（PK）なので、直るまで PS の対象から外す
    if body_has_separator "$kind" && [ "$kind" != quoted-exit ]; then
      check "$base" "$(body_text "$g" "$kind" semi)" dec "ゲート ${gi} の ${kind} の ; 区切りの 1 行形"
    fi
    check "$base" "$(indent_text "$base")" full "ゲート ${gi} の ${kind} の字下げ"
  done
  gi=$((gi + 1))
done
close_group "PS / PI" 22

echo "prefix-invariance: PX — 現行の検出器で判定が変わる形"
gi=0
for g in "${GATES[@]}"; do
  base="$(body_text "$g" propagate nl)"
  for p in "${PINNED_PREP[@]}"; do
    verdict "$DETECTOR" "${p}${NL}${base}"
    if [ "$V_DEC" = deny ] && [ "$V_TAG" = gate-exit-dropped ] && [ "$V_LINE" = "$p" ]; then
      ok "ゲート ${gi}: 準備の位置の [${p}] はその行を名指して止める"
    else
      bad "ゲート ${gi}: 準備の位置の [${p}] の判定が名簿と違う: [${V_DEC}:${V_TAG}] 名指し=[${V_LINE}]（通す側へ変えたなら名簿から PREP へ移す）"
    fi
  done
  for d in "${PINNED_SHOW[@]}"; do
    verdict "$DETECTOR" "$(insert_after_rc "$base" "$d")"
    if [ "$V_DEC" = deny ] && [ "$V_TAG" = gate-exit-dropped ] && [ "$V_LINE" = "$d" ]; then
      ok "ゲート ${gi}: rc の後の [${d}] はその行を名指して止める"
    else
      bad "ゲート ${gi}: rc の後の [${d}] の判定が名簿と違う: [${V_DEC}:${V_TAG}] 名指し=[${V_LINE}]（通す側へ変えたなら名簿から SHOW_LINES へ移す）"
    fi
  done
  gi=$((gi + 1))
done

echo "prefix-invariance: PK — 既知の食い違い"
gi=0
for g in "${GATES[@]}"; do
  verdict "$DETECTOR" "$(body_text "$g" quoted-exit semi)"
  if [ "$V_DEC" = deny ] && [ "$V_TAG" = gate-exit-swallowed ]; then
    ok "ゲート ${gi}: 1 行の rc=\$?; exit \"\$rc\" は gate-exit-swallowed で止まる（既知の誤検知）"
  else
    bad "ゲート ${gi}: 1 行の rc=\$?; exit \"\$rc\" の判定が変わった: [${V_DEC}:${V_TAG}]（直したなら PK を外して PS の対象へ戻す）"
  fi
  gi=$((gi + 1))
done

echo "prefix-invariance: PM — 変異検出"
# 検出器の規則を 1 つ外したコピーを作る。置換が当たらなければ失敗を返す（呼び出し側が赤にする）
mutant() { # <名前> <awk プログラム>
  local out="$TEST_TMP/$1.sh"
  awk "$2" "$DETECTOR" >"$out" 2>/dev/null || return 1
  if cmp -s "$DETECTOR" "$out"; then return 1; fi
  printf '%s' "$out"
}
# 変異した検出器で、判定が変わる行（1 つ足す形。名簿外のゲートの propagate に当てる）の集合を返す
flipped_lines() { # <検出器> <prep|show>
  local det="$1" base text x out=""
  base="$(body_text "${GATES[1]}" propagate nl)"
  set_base "$det" "$base"
  if [ "$2" = prep ]; then
    for x in "${PREP[@]}"; do
      text="${x}${NL}${base}"
      if ! relation_holds "$det" "$text" full; then out="${out}[${x%%"$NL"*}]"; fi
    done
  else
    for x in "${SHOW_LINES[@]}"; do
      text="$(insert_after_rc "$base" "$x")"
      if ! relation_holds "$det" "$text" full; then out="${out}[${x}]"; fi
    done
  fi
  printf '%s' "$out"
}
pm_expect() { # <名前> <awk プログラム> <prep|show> <期待する集合> <説明>
  local m got
  if ! m="$(mutant "$1" "$2")" || [ -z "$m" ]; then
    bad "${1}: 変異の置換が検出器に当たらない（検出器の該当行が変わった）"
    return 0
  fi
  got="$(flipped_lines "$m" "$3")"
  if [ "$got" = "$4" ]; then ok "${1}: ${5}"; else bad "${1}: 判定が変わる行の集合が違う: [${got}]（期待: [${4}]）"; fi
}
# PM1: シェルの状態を変えるだけの組み込みを起動に数える
pm_expect pm1 'index($0, "if (w ~ /^(set|shopt|unset|umask|trap)$/) return 0") { next } { print }' prep \
  '[set -u][umask 022]' \
  "set / umask を起動に数えると、その 2 形だけが判定を変える"
# PM2: 表示だけの区間を起動に数える
pm_expect pm2 'index($0, "if (is_display_only(s)) return 0") { next } { print }' show \
  '[tail -n 15 /tmp/sp/run.log][wc -l /tmp/sp/run.log][cat /tmp/sp/run.log | tail -3]' \
  "表示だけの区間を起動に数えると、tail / wc / cat の 3 形だけが判定を変える"
# PM3: cd / export を起動に数える
pm_expect pm3 'index($0, "if (w ~ /^(cd|pushd|popd|export|exit|return)$/) return 0") { next } { print }' prep \
  '[cd /path/to/repo][export FOO=bar][export A=1 B=2]' \
  "cd / export を起動に数えると、その 3 形だけが判定を変える（cd … || exit 2 は fail-fast の形として通ったまま）"
# PM4: 表示の語がファイルへ書く形を、表示のまま数える
if m4="$(mutant pm4 'index($0, "if (index(t, \">\") || index(t, \"<<\")) return 0") { next } { print }')" && [ -n "$m4" ]; then
  verdict "$m4" "$(insert_after_rc "$(body_text "${GATES[1]}" propagate nl)" "${PINNED_SHOW[3]}")"
  if [ "$V_DEC" = allow ]; then
    ok "pm4: ファイルへ書く形の除外を外すと、名簿の [${PINNED_SHOW[3]}] が素通しになる"
  else
    bad "pm4: ファイルへ書く形の除外を外しても判定が変わらない: [${V_DEC}:${V_TAG}]"
  fi
else
  bad "pm4: 変異の置換が検出器に当たらない（検出器の該当行が変わった）"
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ prefix-invariance: ${FAIL} 件失敗（成功 ${PASS} 件）" >&2
  REACHED_END=1
  exit 1
fi
echo "✅ prefix-invariance: all ${PASS} checks passed"
REACHED_END=1
exit 0
