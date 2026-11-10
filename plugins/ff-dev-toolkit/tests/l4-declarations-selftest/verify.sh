#!/usr/bin/env bash
# tests/l4-declarations の検出力の実測（合成した root への変異注入。ADR-087 / `#2735`）。
# 空振り検出: 実測の材料（tests/l4-declarations/verify.sh・名簿・共通関数・停止文の共通形）の不在は冒頭で rc 1、無変異の合成 root が緑にならない回（共通関数を常に rc 1 の写しへ替えた）は陽性の対照が赤で rc 1（2026-11-10 macOS / Bash 3.2.57 実測）。sed / awk の変異は適用を確かめ、当たらない回は「変異が当たらない」で赤にする。
#
# 合成 root は実物の名簿（scripts/lib/l4-declarations.tsv）と共通関数・停止文の共通形（scripts/lib/stop-block.sh）・
# 表の道具（tests/l4-declarations/fixtures/lib.sh）をそのまま写し、名簿の各行から owner の stub（第 1 引数のプラグイン
# root から共通関数を読み、stdin の 1 語で行を選ぶ。kind=skip は `ff_l4_skipped '<鍵>' ['retired-stop']` の 1 行で
# 抜けなければ、停止文の共通形の 3 行を理由に持つ deny を出す。kind=ack は FF_<鍵>_ACK の前置を通す）、振る舞いの表の
# 合成の fixture、SessionStart の通知の stub（環境の旧名から鍵を導いて 2 種類の文を出す）、PUBLIC-SURFACE（4-1 / 4-2 /
# 4-3）、oss README の鍵の表、試験の隔離の 2 ファイル（印の間の unset と旧名の列挙だけ）を作る。まず無変異の合成 root で
# verify.sh が rc 0・✗ 0 件になること（陽性の対照）を確かめ、次に変異を 1 件ずつ当てて、rc が 0 でないことと、狙った
# 検査番号の ✗ が出ることを両方要求する（別の検査の赤を検出に数えない）。変異ごとに合成 root を写し直し、verify.sh の
# 起動は 4 本ずつ並べる。
#
# skip 経路は持たない（一時領域を作れない・jq / git が無いときは赤）。bash 3.2 互換。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_PLUGIN="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$SRC_PLUGIN/tests/l4-declarations/verify.sh"
SRC_TSV="$SRC_PLUGIN/scripts/lib/l4-declarations.tsv"
SRC_LIB="$SRC_PLUGIN/scripts/lib/l4-declarations.sh"
SRC_SB="$SRC_PLUGIN/scripts/lib/stop-block.sh"
SRC_FXLIB="$SRC_PLUGIN/tests/l4-declarations/fixtures/lib.sh"
BASH_BIN="${BASH:-bash}"

PASS=0
FAIL=0
SKIP=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

for f in "$TARGET" "$SRC_TSV" "$SRC_LIB" "$SRC_SB" "$SRC_FXLIB"; do
  if [ ! -f "$f" ] || [ ! -r "$f" ] || [ ! -s "$f" ]; then
    echo "✗ l4-declarations-selftest: 実測の材料が無いか読めないか 0 バイト（検査不成立）: $f" >&2
    exit 1
  fi
done
command -v jq >/dev/null 2>&1 || { echo "✗ l4-declarations-selftest: jq が無い（skip にしない）" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "✗ l4-declarations-selftest: git が無い（skip にしない）" >&2; exit 1; }

if WORK="$(mktemp -d "${TMPDIR:-/tmp}/ff-l4-selftest.XXXXXX")" && [ -d "$WORK" ] && [ ! -L "$WORK" ]; then
  :
else
  echo "✗ l4-declarations-selftest: 一時ディレクトリを作成できない（検査不成立）" >&2
  exit 1
fi
REACHED_END=0
cleanup() {
  local rc=$?
  rm -rf -- "$WORK"
  if [ "$REACHED_END" -ne 1 ] && [ "$rc" -eq 0 ]; then rc=1; fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

# 合成の名前は実行時に組む（`FF_` で始まる新しい綴りを字句で書くと、公開面の母集団へ入る）。撤去した旧名も
# 字句で書かず、鍵から組む（接頭辞 + 鍵を大文字・_ 区切りにしたもの。第 2 引数 guard で末尾に _GUARD）。
NP=FF
upper_snake() { printf '%s' "$1" | tr 'abcdefghijklmnopqrstuvwxyz-' 'ABCDEFGHIJKLMNOPQRSTUVWXYZ_'; }
ack_name() { printf '%s_%s_ACK\n' "$NP" "$(upper_snake "$1")"; }
retired_name() { printf '%s_DEV_TOOLKIT_SKIP_%s%s\n' "$NP" "$(upper_snake "$1")" "${2:+_GUARD}"; }
ZG_G="$(retired_name zsh-glob guard)"

# 名簿のデータ行（見出しとコメントを除く）
rows() { awk -F'\t' '/^#/ || NF == 0 { next } !h { h = 1; next } { print }' "$SRC_TSV"; }

BASE="$WORK/base"
BP="$BASE/plugins/ff-dev-toolkit"
BFX="$BP/tests/l4-declarations/fixtures"
mkdir -p "$BP/scripts/lib" "$BP/hooks" "$BP/tests/lib" "$BP/tests/stop-block-contract" "$BP/.claude-plugin" "$BASE/oss/ff-dev-toolkit" \
  "$BFX/skip" "$BFX/notice"
cp "$SRC_TSV" "$BP/scripts/lib/l4-declarations.tsv"
cp "$SRC_LIB" "$BP/scripts/lib/l4-declarations.sh"
cp "$SRC_SB" "$BP/scripts/lib/stop-block.sh"
cp "$SRC_FXLIB" "$BFX/lib.sh"
# owner の stub: 第 1 引数のプラグイン root から共通関数を読み、stdin の 1 語で行を選ぶ。
#   skip:<鍵>   その鍵の ff_l4_skipped で止まれば exit 0（素通し）、止まらなければ末尾の deny
#   <名前>=1 …  ACK の前置（通す）
#   notice      SessionStart の L4 宣言の通知（環境の旧名から鍵を導いた 2 種類の文・未知の鍵・停止文の 3 行）
stub_head() { printf '%s\n' '#!/usr/bin/env bash' '{ [ -r "$1/scripts/lib/l4-declarations.sh" ] && . "$1/scripts/lib/l4-declarations.sh"; } 2>/dev/null || ff_l4_skipped() { return 1; }' 'ff_in=""' "IFS= read -r -d '' ff_in || true"; }
# どの stub も、選ばれた行で抜けなければ ACK を見てから deny する。理由は停止文の共通形の 3 行で終える（共通形が
# 次の一手 の末尾へ旧名の注記を添えるので、N14 がこの理由を読む）
cat > "$WORK/deny-tail" <<'EOF'
[ "${ff_ack-}" != 1 ] || exit 0
ff_nl='
'
ff_r="合成の stub が止めた"
if [ -r "$1/scripts/lib/stop-block.sh" ] && . "$1/scripts/lib/stop-block.sh" 2>/dev/null; then
  ff_r="${ff_r}${ff_nl}$(ff_stop_block ガード stub-deny hooks/stub.sh 合成の停止 直す)"
fi
ff_r="${ff_r//${ff_nl}/\\n}"
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$ff_r"
exit 0
EOF
# 鍵 update-check の owner に置く通知の行（旧名は環境から列挙し、共通関数 ff_l4_retired_key で鍵を導く）
cat > "$WORK/notice-line" <<'EOF'
if [ "${ff_in-}" = notice ]; then
  ff_lines="" ff_jn='\n' ff_sug="" ff_names="" ff_run="" ff_upd=""
  for ff_n in "${!FF_DEV_TOOLKIT_SKIP_@}"; do
    [ -n "${!ff_n-}" ] || continue
    ff_l4_retired_key "$ff_n" || continue
    ff_names="${ff_names}${ff_names:+, }${ff_n}"
    case " ${ff_stop_keys} " in
      *" ${ff_l4_rk} "*) ff_lines="${ff_lines}・旧名 ${ff_n} を見つけたので、安全のため ${ff_l4_rk} を止めています。置き換え: FF_DEV_TOOLKIT_SKIP=${ff_l4_rk}${ff_jn}"
        ff_sug="${ff_sug}${ff_sug:+,}${ff_l4_rk}" ff_run="${ff_run}${ff_run:+・}${ff_l4_rk}" ;;
      *) ff_lines="${ff_lines}・旧名 ${ff_n} は読まなくなりました（${ff_l4_rk} は効いています）。止めるなら FF_DEV_TOOLKIT_SKIP=${ff_l4_rk}${ff_jn}"
        [ "${!ff_n-}" != 1 ] || ff_sug="${ff_sug}${ff_sug:+,}${ff_l4_rk}" ;;
    esac
  done
  case ",${FF_DEV_TOOLKIT_SKIP-}," in *,update-check,*) ;; *) ff_upd="📦 合成の更新通知${ff_jn}${ff_jn}" ;; esac
  ff_next="次の一手: "
  [ -z "$ff_sug" ] || ff_next="${ff_next}FF_DEV_TOOLKIT_SKIP=${ff_sug} と書く。"
  ff_next="${ff_next}旧名（${ff_names}）は外す"
  [ -z "$ff_run" ] || ff_next="${ff_next}。${ff_run} を動かすなら、FF_DEV_TOOLKIT_SKIP に書かずに旧名を外すだけでよい"
  ff_m="${ff_upd}${ff_lines}・鍵 ${FF_DEV_TOOLKIT_SKIP-} の確認${ff_jn}止めた層: 宣言${ff_jn}止めた規則: l4-declarations/retired-name（scripts/lib/l4-declarations.tsv）— 合成${ff_jn}${ff_next}"
  printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$ff_m" "$ff_m"
  exit 0
fi
EOF
OWNERS=""
SKIPS="" ACKS="" STOPS=""
while IFS=$'\t' read -r k kind owner _ _ rule _; do
  first="${owner%%,*}"
  for o in $(printf '%s' "$owner" | tr ',' ' '); do
    mkdir -p "$(dirname "$BP/$o")"
    if [ ! -f "$BP/$o" ]; then stub_head > "$BP/$o"; OWNERS="$OWNERS $o"; fi
  done
  if [ "$kind" = "skip" ]; then
    SKIPS="$SKIPS $k"
    call="if ff_l4_skipped '${k}'"
    if [ "$rule" = "retired-stop" ]; then call="$call 'retired-stop'"; STOPS="$STOPS $k"; fi
    for o in $(printf '%s' "$owner" | tr ',' ' '); do
      printf '%s\n' "case \"\${ff_in-}\" in skip:${k}) ${call}; then exit 0; fi ;; esac" >> "$BP/$o"
    done
    # 合成の fixture: owner を全部同じ入力で起動し、全部 deny なら STOP、全部素通しなら PASS（変異 1 件ごとに
    # 表を 1 周するので、判定は組み込みだけで行い jq / grep を起動しない）。最後の owner の出力を out に置く（N14）
    {
      printf '%s\n' '# shellcheck shell=bash' "fx_owners='$(printf '%s' "$owner" | tr ',' ' ')'" \
        "fx_setup() { printf 'skip:%s' '${k}' > \"\$fx_wk/in\"; }" \
        'fx_one() { local o r; o="$(/bin/bash "$fx_plugin/$1" "$fx_plugin" < "$fx_wk/in" 2> /dev/null)"; r=$?; printf "%s\n" "$o" > "$fx_wk/out"; case "${r}:${o}" in 0:*deny*) fx_s=$((fx_s + 1)) ;; 0:*) fx_p=$((fx_p + 1)) ;; *) fx_e=$((fx_e + 1)) ;; esac; }'
      printf '%s' 'fx_run() { fx_s=0 fx_p=0 fx_e=0;'
      for o in $(printf '%s' "$owner" | tr ',' ' '); do printf ' fx_one %s;' "'$o'"; done
      printf '%s\n' ' }' \
        'fx_judge() { if [ "$fx_e" -eq 0 ] && [ "$fx_p" -eq 0 ] && [ "$fx_s" -gt 0 ]; then echo "STOP 全部 deny"; elif [ "$fx_e" -eq 0 ] && [ "$fx_s" -eq 0 ] && [ "$fx_p" -gt 0 ]; then echo "PASS 全部素通し"; else echo "ERROR 食い違い（STOP ${fx_s} / PASS ${fx_p} / rc≠0 ${fx_e}）"; fi; }'
    } > "$BFX/skip/${k}.sh"
  else
    an="$(ack_name "$k")"
    ACKS="$ACKS $an"
    printf '%s\n' "case \"\${ff_in-}\" in ${an}=1*) ff_ack=1 ;; esac" >> "$BP/$first"
  fi
done < <(rows)
OW_UC="$(awk -F'\t' '$1 == "update-check" && $2 == "skip" { print $3 }' "$SRC_TSV")"
# shellcheck disable=SC2086 # 空白区切りの鍵の一覧を 1 語へ
printf '%s\n' "ff_stop_keys='$(printf '%s ' $STOPS | sed 's/ $//')'" >> "$BP/$OW_UC"
cat "$WORK/notice-line" >> "$BP/$OW_UC"
{
  printf '%s\n' '# shellcheck shell=bash' "fx_owners='${OW_UC}'" "fx_setup() { printf notice > \"\$fx_wk/in\"; }" \
    "fx_run() { /bin/bash \"\$fx_plugin/${OW_UC}\" \"\$fx_plugin\" < \"\$fx_wk/in\" > \"\$fx_wk/out\" 2> \"\$fx_wk/err\"; echo \"\$?\" > \"\$fx_wk/rc\"; }" \
    'fx_judge() { case "$(jq -r ".systemMessage // \"\"" < "$fx_wk/out" 2>/dev/null)" in *📦*) echo "STOP 更新通知が出た" ;; *) echo "PASS 更新チェックは止まったまま" ;; esac; }'
} > "$BFX/notice/update-check.sh"
for o in $OWNERS; do cat "$WORK/deny-tail" >> "$BP/$o"; done
# 陽性の対照: hook のコメント行に書いた旧名の形は N7 の針に当たらない（コメントは数えない）
FH0="$BP/hooks/guard-zsh-glob.sh"
printf '%s\n' "# 撤去した旧名の例（コメントは N7 の針の外）: ${ZG_G}" >> "$FH0"
{
  printf '%s\n' '# 公開面' '' '## 公開面 4: 環境変数' '' '### 4-1. 契約' '' '- `FF_DEV_TOOLKIT_SKIP`'
  for a in $ACKS; do printf '%s\n' "- \`${a}\`"; done
  printf '%s\n' '' '### 4-2. 内部' '' '#### 4-2-1. tests の中だけ' '' '#### 4-2-2. 配布実行物・配布文書に現れるもの' ''
  printf '%s\n' '' '### 4-3. L4 宣言の鍵' '' '| 鍵 | 種別 | 担当する実体 | 包含 | 旧名 |' '| --- | --- | --- | --- | --- |'
  for k in $SKIPS; do printf '%s\n' "| \`${k}\` | skip | - | - | - |"; done
  printf '%s\n' '' '## 公開面 5: 環境変数（接頭辞の無いもの）' '' '## 破壊的変更の記録' '' '## この一覧を守る機械検査' ''
} > "$BP/PUBLIC-SURFACE.md"
{
  printf '%s\n' '# ff-dev-toolkit' '' '## 止める宣言' '' '| 鍵 | 止めるもの |' '| --- | --- |'
  for k in $SKIPS; do printf '%s\n' "| \`${k}\` | - |"; done
  printf '%s\n' '' '終わり。'
} > "$BASE/oss/ff-dev-toolkit/README.md"
printf '%s\n' '{' '  "name": "ff-dev-toolkit",' '  "version": "1.0.0"' '}' > "$BP/.claude-plugin/plugin.json"
ENUM_LINE='for _l4_v in "${!FF_DEV_TOOLKIT_SKIP_@}"; do unset "$_l4_v"; done'
for iso in "$BP/tests/stop-block-contract/verify.sh" "$BP/tests/lib/adapter-env-isolation.sh"; do
  {
    printf '%s\n' '#!/usr/bin/env bash' '# l4-default-unset:begin' "unset FF_DEV_TOOLKIT_SKIP \\"
    for a in $ACKS; do printf '%s\n' "  ${a} \\"; done
    printf '%s\n' '  2>/dev/null || true' "$ENUM_LINE" '# l4-default-unset:end'
  } > "$iso"
done

# 変異ごとに合成 root を新しく写す（m1, m2, …）。verify.sh の起動は並べて走らせ、判定は最後にまとめて行う
# （振る舞いの表が 1 回ごとに合成の owner を 100 回あまり起動するため）。
M_N=0
M_PAR=4
M_RUNNING=0
P_LABEL=() P_TARGET=() P_WORD=() P_FIX=()
set_paths() {
  FT="$FIX/plugins/ff-dev-toolkit/scripts/lib/l4-declarations.tsv"
  FL="$FIX/plugins/ff-dev-toolkit/scripts/lib/l4-declarations.sh"
  FSB="$FIX/plugins/ff-dev-toolkit/scripts/lib/stop-block.sh"
  FS="$FIX/plugins/ff-dev-toolkit/PUBLIC-SURFACE.md"
  FR="$FIX/oss/ff-dev-toolkit/README.md"
  FH="$FIX/plugins/ff-dev-toolkit/hooks/guard-zsh-glob.sh"
  FA="$FIX/plugins/ff-dev-toolkit/hooks/auto-update-marketplace.sh"
  FCU="$FIX/plugins/ff-dev-toolkit/hooks/check-update.sh"
  FXD="$FIX/plugins/ff-dev-toolkit/tests/l4-declarations/fixtures"
  LOG="$FIX.log"
}
# WITH_TABLE=0 の変異は表の fixture（skip / notice）を外した写しで測る（狙いが表の外の検査で、表の起動は
# 判定に要らない。外した写しでは N10・N12・N14 も赤になるが、判定は狙った検査番号の ✗ で行うので検出に数えない）
WITH_TABLE=1
fresh() {
  M_N=$((M_N + 1)); FIX="$WORK/m${M_N}"; rm -rf -- "$FIX" && cp -R "$BASE" "$FIX"; set_paths
  [ "$WITH_TABLE" = 1 ] || rm -rf -- "$FXD/skip" "$FXD/notice"
}
run_target() { RC=0; "$BASH_BIN" "$TARGET" --root "$FIX" > "$LOG" 2>&1 || RC=$?; }
count() { grep -cF -- "$1" "$LOG" || true; }
# ファイルを awk で書き換える（適用されなければ赤）。$1=ファイル $2=awk プログラム
rewrite() {
  local f="$1" prog="$2"
  awk -F'\t' -v OFS='\t' "$prog" "$f" > "$f.new" && mv "$f.new" "$f"
}
# sed で書き換える（適用は呼び出し側が applied で確かめる）。$1=ファイル $2=sed の式
sedit() { sed "$2" "$1" > "$1.new" && mv "$1.new" "$1"; }
# $1=見出し $2=期待する ✗ の検査番号（例 N2）[$3=出力に含むべき語]。起動だけをここで始め、判定は judge_pending
expect_red() {
  local n="${#P_LABEL[@]}"
  P_LABEL[$n]="$1" P_TARGET[$n]="$2" P_WORD[$n]="${3:-}" P_FIX[$n]="$FIX"
  ( trap - EXIT HUP INT TERM; rc=0; "$BASH_BIN" "$TARGET" --root "$FIX" > "$FIX.log" 2>&1 || rc=$?; echo "$rc" > "$FIX.rc" ) &
  M_RUNNING=$((M_RUNNING + 1))
  if [ "$M_RUNNING" -ge "$M_PAR" ]; then wait; M_RUNNING=0; fi
  return 0
}
judge_pending() {
  local n=0 hits more rc
  wait
  while [ "$n" -lt "${#P_LABEL[@]}" ]; do
    LOG="${P_FIX[$n]}.log"
    rc="$(cat "${P_FIX[$n]}.rc" 2>/dev/null || echo '?')"
    # 検査番号は `:` まで含めて数える（`✗ N1` が `✗ N10:` 〜 `✗ N14:` にも当たり、表を外した写しでは常に赤の
    # N10・N12・N14 を N1 の検出に数えてしまうため）。verify.sh の bad はどれも `<番号>: …` の形
    hits="$(count "✗ ${P_TARGET[$n]}:")"
    more=1
    [ -z "${P_WORD[$n]}" ] || [ "$(count "${P_WORD[$n]}")" -gt 0 ] || more=0
    if [ "$rc" != 0 ] && [ "$rc" != '?' ] && [ "${hits:-0}" -gt 0 ] && [ "$more" -eq 1 ]; then
      ok "${P_LABEL[$n]} → rc ${rc}・✗ ${P_TARGET[$n]}${P_WORD[$n]:+（「${P_WORD[$n]}」）}"
    else
      bad "${P_LABEL[$n]} → rc ${rc}・✗ ${P_TARGET[$n]} の件数 ${hits:-0}${P_WORD[$n]:+・「${P_WORD[$n]}」の有無 $more}（期待: rc≠0 かつ ✗ ${P_TARGET[$n]}）"
      sed 's/^/      | /' "$LOG" | head -n 40 >&2
    fi
    n=$((n + 1))
  done
}
applied() { # $1=ファイル $2=固定文字列 $3=期待する件数の比較（present / absent）
  local n
  n="$(grep -cF -- "$2" "$1" 2>/dev/null || true)"
  if [ "$3" = "present" ]; then [ "${n:-0}" -gt 0 ]; else [ "${n:-0}" -eq 0 ]; fi
}

echo "== l4-declarations-selftest =="

# ---- 陽性の対照 -------------------------------------------------------------------
fresh
run_target
p_ok="$(count '✓')" p_bad="$(count '✗')"
if [ "$RC" -eq 0 ] && [ "${p_bad:-0}" -eq 0 ] && [ "${p_ok:-0}" -gt 0 ]; then
  ok "無変異の合成 root は rc 0・✗ 0 件（✓ ${p_ok} 件。hook のコメント行の旧名の形は N7 に当たらない）"
else
  bad "無変異の合成 root が緑にならない（rc ${RC}・✓ ${p_ok:-0}・✗ ${p_bad:-0}）。以後の赤は検出に数えられない"
  sed 's/^/      | /' "$LOG" | head -n 60 >&2
fi
# AC3: 別名が無いので期限も無い。plugin.json の version を 1.1.0 にしても緑のまま
fresh; sedit "$FIX/plugins/ff-dev-toolkit/.claude-plugin/plugin.json" 's/"version": "1.0.0"/"version": "1.1.0"/'
if applied "$FIX/plugins/ff-dev-toolkit/.claude-plugin/plugin.json" '"1.1.0"' present; then
  run_target
  if [ "$RC" -eq 0 ] && [ "$(count '✗')" -eq 0 ]; then ok "plugin.json の version を 1.1.0 にしても rc 0・✗ 0 件（期限の検査は無い）"; else bad "version 1.1.0 で緑にならない（rc ${RC}・✗ $(count '✗')）"; sed 's/^/      | /' "$LOG" | grep '✗' >&2; fi
else
  bad "変異が当たらない: version を 1.1.0 にする"
fi

# ---- 空振り（名簿の前提）---------------------------------------------------------------
WITH_TABLE=0
fresh; rm -f "$FT"
expect_red "名簿が不在" N0
fresh; rewrite "$FT" '/^#/ || $1 == "key" { print }'
applied "$FT" 'zsh-glob' absent && expect_red "名簿が 0 行（見出しとコメントだけ）" N0 "データ行が 0 件" || bad "変異が当たらない: 名簿を 0 行にする"
fresh; : > "$FT"
expect_red "名簿が 0 バイト" N0
fresh; rewrite "$FT" '!/^#/ && $1 != "key" && !d { d = 1; print $0 "\textra"; next } { print }'
expect_red "名簿の列の数が違う（1 行だけ 8 列）" N0 "7 列でない"
fresh; rewrite "$FT" '!/^#/ && $1 == "wsl-shell" && $2 == "skip" { $5 = ""; } { print }'
expect_red "名簿に空の欄がある" N0 "空か空白"

# ---- 名簿の形（N1）---------------------------------------------------------------------
fresh; rm -f "$FIX/plugins/ff-dev-toolkit/hooks/guard-wsl-shell.sh"
expect_red "owner の実体を消す（hooks/guard-wsl-shell.sh）" N1 "owner が実在しない"
LG_WS="$(retired_name wsl-shell guard)"
fresh; awk -F'\t' -v OFS='\t' -v lg="$LG_WS" '!/^#/ && $1 == "wsl-shell" && $2 == "skip" { $5 = lg } { print }' "$FT" > "$FT.new" && mv "$FT.new" "$FT"
applied "$FT" "$LG_WS" present && expect_red "legacy 列に旧名を書き戻す（wsl-shell）" N1 "legacy が - でない" || bad "変異が当たらない: legacy 列に旧名を書き戻す"
fresh; rewrite "$FT" '!/^#/ && $1 == "zsh-glob" && $2 == "skip" { $7 = "1.1.0" } { print }'
expect_red "remove_after に版を書く（zsh-glob）" N1 "remove_after が - でない"
fresh; rewrite "$FT" '!/^#/ && $1 == "zsh-glob" && $2 == "skip" { $6 = "eq1" } { print }'
expect_red "legacy_value_rule に廃止した値 eq1 を書く（zsh-glob）" N1 "eq1"
fresh; rewrite "$FT" '!/^#/ && $1 == "zsh-glob" && $2 == "ack" { $6 = "retired-stop" } { print }'
expect_red "retired-stop を kind=ack の行に書く（zsh-glob / ack）" N1 "kind=skip の行だけ"
fresh; rewrite "$FT" '!/^#/ && $1 == "auto-update" && $2 == "skip" { $6 = "-" } { print }'
expect_red "副作用系の鍵（auto-update）の retired-stop を外す（集合が 4 鍵と違う）" N1 "retired-stop の鍵の集合"
fresh; rewrite "$FT" '!/^#/ && $1 == "zsh-glob" && $2 == "skip" { $6 = "retired-stop" } { print }'
expect_red "副作用の無い鍵（zsh-glob）に retired-stop を書く（集合が 4 鍵と違う）" N1 "余分: zsh-glob"

# ---- 名簿と実装（N2 / N3）---------------------------------------------------------------
fresh; rewrite "$FT" '!($1 == "wsl-shell" && $2 == "skip") { print }'
applied "$FT" "$(printf 'wsl-shell\tskip')" absent && expect_red "名簿から 1 行消す（wsl-shell / skip）" N2 "wsl-shell" || bad "変異が当たらない: 名簿から 1 行消す"
fresh; sedit "$FH" "s/ff_l4_skipped 'zsh-glob'/ff_l4_skipped 'zsh-glop'/"
applied "$FH" "'zsh-glop'" present && expect_red "hook の鍵の文字列を変える（zsh-glob → zsh-glop）" N2 "zsh-glop" || bad "変異が当たらない: hook の鍵の文字列"
fresh; sedit "$FH" "s/ff_l4_skipped 'zsh-glob'/ff_l4_skipped \"\$k\"/"
applied "$FH" 'ff_l4_skipped "$k"' present && expect_red "鍵を変数で渡す" N2 "変数" || bad "変異が当たらない: 鍵を変数で渡す"
fresh; sedit "$FA" "s/ff_l4_skipped 'auto-update' 'retired-stop'/ff_l4_skipped 'auto-update'/"
applied "$FA" "'retired-stop'" absent && expect_red "retired-stop の鍵（auto-update）の呼び出しから 'retired-stop' を外す" N3 "'retired-stop' が無い" || bad "変異が当たらない: 'retired-stop' を外す"
fresh; sedit "$FH" "s/ff_l4_skipped 'zsh-glob';/ff_l4_skipped 'zsh-glob' 'retired-stop';/"
applied "$FH" "ff_l4_skipped 'zsh-glob' 'retired-stop'" present && expect_red "retired-stop でない鍵（zsh-glob）の呼び出しに 'retired-stop' を足す" N3 "'retired-stop' がある" || bad "変異が当たらない: 'retired-stop' を足す"
fresh; sedit "$FH" "s/ff_l4_skipped 'zsh-glob';/ff_l4_skipped 'zsh-glob' '${ZG_G}';/"
applied "$FH" "ff_l4_skipped 'zsh-glob' '${ZG_G}'" present && expect_red "第 2 引数に旧名のリテラルを書く（zsh-glob）" N3 "retired-stop でない" || bad "変異が当たらない: 第 2 引数の旧名"
fresh; sedit "$FA" "s/ff_l4_skipped 'auto-update' 'retired-stop'/ff_l4_skipped 'auto-update' 'retired-stop' 'nonempty'/"
applied "$FA" "'retired-stop' 'nonempty'" present && expect_red "第 3 引数（廃止した nonempty）を足す（auto-update）" N3 "第 3 引数" || bad "変異が当たらない: 第 3 引数"
fresh; sedit "$FA" "s/ff_l4_skipped 'auto-update' 'retired-stop'/ff_l4_skipped 'auto-update' \"\$r\"/"
applied "$FA" "ff_l4_skipped 'auto-update' \"\$r\"" present && expect_red "第 2 引数を変数で渡す（auto-update）" N3 "変数で渡している" || bad "変異が当たらない: 第 2 引数を変数で渡す"

# ---- 公開文書（N4 / N5）-----------------------------------------------------------------
fresh; grep -vF '| `wsl-shell` |' "$FS" > "$FS.new" && mv "$FS.new" "$FS"
expect_red "PUBLIC-SURFACE 4-3 から 1 行消す（wsl-shell）" N4 "wsl-shell"
fresh; awk '/^### 4-3\./ { skip = 1 } /^## 公開面 5/ { skip = 0 } !skip' "$FS" > "$FS.new" && mv "$FS.new" "$FS"
expect_red "PUBLIC-SURFACE に 4-3 の節が無い" N4 "1 件も抽出できない"
fresh; grep -vF '| `zsh-glob` |' "$FR" > "$FR.new" && mv "$FR.new" "$FR"
expect_red "oss README の鍵の表から 1 行消す（zsh-glob）" N5 "zsh-glob"
fresh; rm -f "$FR"
expect_red "oss/ff-dev-toolkit/ があるのに README が無い（root の README.md へ倒さない）" N5 "oss/ff-dev-toolkit/README.md"
fresh; mv "$FR" "$FIX/README.md" && rm -rf -- "$FIX/oss"
run_target
if [ "$(count '✓ N5:')" -gt 0 ] && [ "$(count '✗ N5:')" -eq 0 ]; then
  ok "公開同期の配置（oss/ の中身が root へ展開される）では root の README.md の鍵の表を読む（N5 は緑）"
else
  bad "公開同期の配置で N5 が root の README.md を読めない（✓ N5 $(count '✓ N5:') 件・✗ N5 $(count '✗ N5:') 件）"
  sed 's/^/      | /' "$LOG" | grep 'N5' >&2
fi
fresh; mv "$FR" "$FIX/README.md" && rm -rf -- "$FIX/oss"; grep -vF '| `zsh-glob` |' "$FIX/README.md" > "$FIX/README.md.new" && mv "$FIX/README.md.new" "$FIX/README.md"
expect_red "公開同期の配置の root の README.md の鍵の表から 1 行消す（zsh-glob）" N5 "zsh-glob"

# ---- ACK の型（N6）・旧名の書き戻し（N7）--------------------------------------------------
fresh; printf '%s\n' "case \"\${cmd-}\" in ${NP}_BOGUS_ACK=1*) : ;; esac" >> "$FH"
expect_red "配布実行物に名簿に無い ACK の名前を足す" N6 "_BOGUS_ACK"
fresh; printf '%s\n' "ff_x=\"\${${ZG_G}-}\"" >> "$FH"
expect_red "hooks/ の非コメント行に旧名の形を書き戻す（guard-zsh-glob.sh）" N7 "guard-zsh-glob.sh"
fresh; printf '%s\n' "echo \"止めるなら ${ZG_G}=1\" # 案内" >> "$FIX/plugins/ff-dev-toolkit/tests/lib/zsh-expansion-guard.sh"
expect_red "tests/lib/ の非コメント行（行末にコメントを持つ行）に旧名の形を書き戻す" N7 "zsh-expansion-guard.sh"
fresh; mkdir -p "$FIX/.claude/hooks"; printf '%s\n' '#!/usr/bin/env bash' "[ \"\${$(retired_name commit-identity guard):-0}\" = 1 ] && exit 0" > "$FIX/.claude/hooks/guard-x.sh"
expect_red ".claude/hooks/ の非コメント行に旧名の形を書き戻す" N7 ".claude/hooks/guard-x.sh"
fresh; rm -rf -- "$FIX/plugins/ff-dev-toolkit/hooks"
expect_red "走査先の hooks/ が無い（走査の空振り）" N7 "走査先"
# root は chmod 000 のファイルも読めるので grep が rc 2 にならない（変異が成り立たない）。chmod の後に実際に読めるかでも
# 確かめ、成り立たない実行者ではこの変異だけを理由つきで飛ばし、最後の集計に skip= として数える
fresh; chmod 000 "$FIX/plugins/ff-dev-toolkit/hooks/guard-wsl-shell.sh"
if [ "$(id -u)" -eq 0 ] || [ -r "$FIX/plugins/ff-dev-toolkit/hooks/guard-wsl-shell.sh" ]; then
  echo "  ○ skip: 走査先に読めないファイルがある変異（N7）— この実行者は chmod 000 のファイルも読めるので grep が rc 2 にならず、変異が成り立たない（uid $(id -u)）"
  SKIP=$((SKIP + 1))
else
  expect_red "走査先に読めないファイルがある（hooks/guard-wsl-shell.sh。grep の rc 2）" N7 "走査が失敗"
fi
fresh; mkdir -p "$FIX/.claude/hooks"; printf '%s\n' '#!/usr/bin/env bash' "if ff_l4_skipped 'commit-identity' 'retired-stop'; then exit 0; fi" > "$FIX/.claude/hooks/guard-x.sh"
expect_red ".claude/hooks/ の呼び出しで retired-stop でない鍵（commit-identity）に 'retired-stop' を足す" N3 ".claude/hooks/guard-x.sh"

# ---- 共通関数の読み込みの形（N13）-------------------------------------------------------
FRG_REL="scripts/record-gate-minutes.sh"
fresh; printf '%s\n' '. "$1/scripts/lib/l4-declarations.sh" 2>/dev/null || ff_l4_skipped() { return 1; }' >> "$FIX/plugins/ff-dev-toolkit/${FRG_REL}"
expect_red "scripts/ の共通関数の読み込み行から [ -r ] を外す（${FRG_REL}）" N13 "${FRG_REL}"
fresh; printf '%s\n' 'ff_l4_lib="$1/scripts/lib/l4-declarations.sh"' '. "$ff_l4_lib" 2>/dev/null || ff_l4_skipped() { return 1; }' >> "$FIX/plugins/ff-dev-toolkit/${FRG_REL}"
expect_red "共通関数を変数経由で [ -r ] なしに読む（${FRG_REL}。2 行に分けた形）" N13 "${FRG_REL}"
fresh; printf '%s\n' '. $1/scripts/lib/l4-declarations.sh 2>/dev/null || ff_l4_skipped() { return 1; }' >> "$FIX/plugins/ff-dev-toolkit/${FRG_REL}"
expect_red "共通関数を引用の無い path で [ -r ] なしに読む（${FRG_REL}）" N13 "${FRG_REL}"
fresh; printf '%s\n' '{ [ -r "$1/scripts/lib/l4-declarations.sh" ] && . "$1/scripts/lib/l4-declarations.sh"; } 2>/dev/null || . "$1/alt/l4-declarations.sh" 2>/dev/null || ff_l4_skipped() { return 1; }' >> "$FIX/plugins/ff-dev-toolkit/${FRG_REL}"
expect_red "決まった形の後ろへ確かめない読み込みを同じ行に繋ぐ（${FRG_REL}）" N13 "${FRG_REL}"
fresh; printf '%s\n' '. "$1/scripts/lib/l4-declarations.sh" 2>/dev/null # { [ -r "$1/scripts/lib/l4-declarations.sh" ] && . "$1/scripts/lib/l4-declarations.sh"; } 2>/dev/null' >> "$FIX/plugins/ff-dev-toolkit/${FRG_REL}"
expect_red "決まった形を行末のコメントに書くだけで、実際は確かめずに読む（${FRG_REL}）" N13 "${FRG_REL}"
fresh
grep -rlF 'l4-declarations.sh"' "$FIX/plugins/ff-dev-toolkit/hooks" "$FIX/plugins/ff-dev-toolkit/scripts" "$FIX/plugins/ff-dev-toolkit/tests/lib" 2>/dev/null > "$WORK/n13-files" || true
while IFS= read -r f; do
  case "$f" in */scripts/lib/l4-declarations.*) continue ;; esac
  grep -vF 'l4-declarations.sh"' "$f" > "$f.new"; mv "$f.new" "$f"
done < "$WORK/n13-files"
if [ -s "$WORK/n13-files" ] && ! grep -rqF 'l4-declarations.sh"' "$FIX/plugins/ff-dev-toolkit/hooks" "$FIX/plugins/ff-dev-toolkit/scripts" "$FIX/plugins/ff-dev-toolkit/tests/lib"; then
  expect_red "共通関数を読む行を全部消す（走査の空振り）" N13 "1 件も無い"
else
  bad "変異が当たらない: 共通関数を読む行を全部消す"
fi

# ---- 試験の隔離（N9）--------------------------------------------------------------------
ZA="$(ack_name zsh-glob)"
FSBC="$FIX/plugins/ff-dev-toolkit/tests/stop-block-contract/verify.sh"
fresh; FSBC="$FIX/plugins/ff-dev-toolkit/tests/stop-block-contract/verify.sh"; grep -vF "  ${ZA} \\" "$FSBC" > "$WORK/sbc" && mv "$WORK/sbc" "$FSBC"
expect_red "stop-block-contract の既定の unset から 1 つ消す（${ZA}）" N9 "$ZA"
fresh; FAEI="$FIX/plugins/ff-dev-toolkit/tests/lib/adapter-env-isolation.sh"; grep -vF "  ${ZA} \\" "$FAEI" > "$WORK/aei" && mv "$WORK/aei" "$FAEI"
expect_red "isolate_hook_env の既定の unset から 1 つ消す（${ZA}）" N9 "$ZA"
fresh; FAEI="$FIX/plugins/ff-dev-toolkit/tests/lib/adapter-env-isolation.sh"; awk -v za="$ZA" '/l4-default-unset:begin/ { print; print "# " za; next } $0 == "  " za " \\" { next } { print }' "$FAEI" > "$WORK/aei" && mv "$WORK/aei" "$FAEI"
applied "$FAEI" "  ${ZA} \\" absent && expect_red "isolate_hook_env の印の間で ${ZA} をコメントへ移す（unset されない）" N9 "$ZA" || bad "変異が当たらない: 印の間のコメント化"
fresh; FSBC="$FIX/plugins/ff-dev-toolkit/tests/stop-block-contract/verify.sh"; grep -v 'l4-default-unset:end' "$FSBC" > "$WORK/sbc" && mv "$WORK/sbc" "$FSBC"
expect_red "stop-block-contract の印（:end）を消す" N9 "印"
fresh; FAEI="$FIX/plugins/ff-dev-toolkit/tests/lib/adapter-env-isolation.sh"; grep -vF "$ENUM_LINE" "$FAEI" > "$WORK/aei" && mv "$WORK/aei" "$FAEI"
applied "$FAEI" '${!FF_DEV_TOOLKIT_SKIP_@}' absent && expect_red "isolate_hook_env の印の間から撤去した旧名の列挙を消す" N9 "列挙" || bad "変異が当たらない: 旧名の列挙を消す"
fresh; FSBC="$FIX/plugins/ff-dev-toolkit/tests/stop-block-contract/verify.sh"; sedit "$FSBC" "s/^for _l4_v in/# for _l4_v in/"
applied "$FSBC" '# for _l4_v in' present && expect_red "stop-block-contract の旧名の列挙をコメントにする（unset されない）" N9 "列挙" || bad "変異が当たらない: 旧名の列挙のコメント化"

# ---- 共通関数（U1 / U2）----------------------------------------------------------------
fresh; sedit "$FL" 's/^  ff_l4_list="\${FF_DEV_TOOLKIT_SKIP-}"$/  ff_l4_list="$(printf %s "${FF_DEV_TOOLKIT_SKIP-}")"/'
applied "$FL" 'ff_l4_list="$(printf' present && expect_red "共通関数の早期に戻る前の経路へコマンド置換を足す" U2 "子プロセスの段" || bad "変異が当たらない: 共通関数へコマンド置換"
fresh; sedit "$FL" 's/\*\[!abcdefghijklmnopqrstuvwxyz0123456789,-\]\* | ,\* | \*, | \*,,\*) return 1 ;;/,* | *, | *,,*) return 1 ;;/'
applied "$FL" '*[!abcdefghijklmnopqrstuvwxyz0123456789,-]*' absent && expect_red "値の文法の検査（許す文字）を外す" U1 "UPDATE_CHECK" || bad "変異が当たらない: 値の文法"
fresh; sedit "$FL" 's/ | \*,,\*) return 1 ;;/) return 1 ;;/'
applied "$FL" '*,,*' absent && expect_red "値の文法の検査（空の要素 ,,）を外す" U1 "zsh-glob,,update-check" || bad "変異が当たらない: 空の要素の検査"
fresh; rewrite "$FT" '!/^#/ && $1 == "zsh-glob" && $2 == "skip" { $4 = "-" } { print }'
expect_red "covers から zsh-expansion を外す" U1 "zsh-expansion"
fresh; sedit "$FL" 's/\[ -n "\${!ff_l4_n-}" \] || continue/[ "${!ff_l4_n-}" = "1" ] || continue/'
applied "$FL" '[ "${!ff_l4_n-}" = "1" ]' present && expect_red "旧名の検出を「値が 1 のときだけ」へ倒す（retired-stop が値 0 で止まらない）" U1 "=0" || bad "変異が当たらない: 旧名の検出の値"
fresh; sedit "$FL" 's/^    if \[ "\$ff_l4_rule" = "retired-stop" \]; then \(.*\); fi$/    \1/'
applied "$FL" 'if [ "$ff_l4_rule" = "retired-stop" ]' absent && expect_red "第 2 引数なしの呼び出しも旧名で止める（ガードが旧名で素通しする）" U1 "zsh-glob" || bad "変異が当たらない: 第 2 引数なしでも旧名で止める"
fresh; sedit "$FL" 's/^  s="\${s%_GUARD}"$/  :/'
applied "$FL" 's="${s%_GUARD}"' absent && expect_red "旧名から鍵を導くときに末尾の _GUARD を外さない" U1 "_GUARD" || bad "変異が当たらない: _GUARD を外さない"
fresh; sedit "$FL" 's/|| ff_l4_retired_note="旧名/|| ff_l4_unused_note="旧名/'
applied "$FL" 'ff_l4_unused_note=' present && expect_red "旧名を見つけた回に注記を置かない" U1 "注記に" || bad "変異が当たらない: 注記を置かない"
fresh; sedit "$FL" 's/^ff_l4_retired_note=""$/:/'
applied "$FL" 'ff_l4_retired_note=""' absent && expect_red "source 時の注記の初期化を外す（環境から持ち込んだ値を使う）" U1 "持ち込んだ値" || bad "変異が当たらない: 注記の初期化"
fresh; sedit "$FL" 's/^    \[ "\$ff_l4_rk" = "\$ff_l4_key" \] || continue$/    :/'
applied "$FL" '[ "$ff_l4_rk" = "$ff_l4_key" ] || continue' absent && expect_red "旧名から導いた鍵と呼び出しの鍵の照合を外す（別の鍵の旧名で止まる）" U1 "auto-update retired-stop" || bad "変異が当たらない: 鍵の照合を外す"
fresh; awk '{ print } index($0, "ff_l4_retired_key \"$ff_l4_n\" || continue") { print "    [ -n \"$ff_l4_retired_note\" ] || ff_l4_retired_note=\"旧名 ${ff_l4_n} は読まなくなりました。ガードごと止めるなら FF_DEV_TOOLKIT_SKIP=${ff_l4_key}\"" }' "$FL" > "$FL.new" && mv "$FL.new" "$FL"
[ "$(grep -c 'ff_l4_retired_note="旧名' "$FL")" -eq 2 ] && expect_red "注記の代入を鍵の照合より前へ動かす（別の鍵の旧名でも注記が入る）" U1 "注記が空でない" || bad "変異が当たらない: 注記の代入を前へ"
fresh; sedit "$FL" 's/^    \[ -n "\${!ff_l4_n-}" \] || continue$/    :/'
applied "$FL" '[ -n "${!ff_l4_n-}" ] || continue' absent && expect_red "空の値の変数も旧名として数える" U1 "=" || bad "変異が当たらない: 空の値を数える"
fresh; sedit "$FL" 's/then ff_l4_retired_stop_name="\$ff_l4_n"; return 0; fi/then return 0; fi/'
applied "$FL" 'ff_l4_retired_stop_name="$ff_l4_n"' absent && expect_red "retired-stop で止めた回に見つけた旧名を記録しない" U1 "ff_l4_retired_stop_name" || bad "変異が当たらない: 旧名を記録しない"
fresh; sedit "$FL" 's/^  ff_l4_retired_stop_name=""$/  :/'
applied "$FL" '  ff_l4_retired_stop_name=""' absent && expect_red "呼び出しごとに旧名の記録を空へ戻さない（前の呼び出しの旧名が残る）" U1 "ff_l4_retired_stop_name" || bad "変異が当たらない: 旧名の記録を空へ戻さない"

# ---- 振る舞いの表（N10: kind=skip）------------------------------------------------------
WITH_TABLE=1
fresh; sedit "$FH" "s/if ff_l4_skipped 'zsh-glob'/if FF_DEV_TOOLKIT_SKIP= ff_l4_skipped 'zsh-glob'/"
applied "$FH" "if FF_DEV_TOOLKIT_SKIP= ff_l4_skipped 'zsh-glob'" present && expect_red "新しい鍵を読まない stub（呼び出しの間だけ FF_DEV_TOOLKIT_SKIP を空にする）" N10 "zsh-glob new" || bad "変異が当たらない: 新しい鍵を読まない stub"
fresh; awk 'NR == 2 { print; print "[ -z \"${FF_DEV_TOOLKIT_SKIP-}\" ] || exit 0"; next } { print }' "$FH" > "$FH.new" && mv "$FH.new" "$FH"
applied "$FH" '[ -z "${FF_DEV_TOOLKIT_SKIP-}" ] || exit 0' present && expect_red "鍵の打ち間違いでも止まる（素通しする）stub" N10 "zsh-glob typo" || bad "変異が当たらない: 打ち間違いでも素通しする stub"
fresh; sedit "$FH" "s/if ff_l4_skipped 'zsh-glob';/if [ -n \"\${${ZG_G}-}\" ] || ff_l4_skipped 'zsh-glob';/"
applied "$FH" "if [ -n \"\${${ZG_G}-}\" ] ||" present && expect_red "ガードが旧名で素通しする stub（旧名を読み続ける）" N10 "zsh-glob lg-guard" || bad "変異が当たらない: 旧名で素通しする stub"
fresh; sedit "$FA" "s/ff_l4_skipped 'auto-update' 'retired-stop'/ff_l4_skipped 'auto-update'/"
applied "$FA" "'retired-stop'" absent && expect_red "副作用系の stub が旧名で止まらない（'retired-stop' を外す）" N10 "auto-update lg0-plain" || bad "変異が当たらない: 'retired-stop' を外す（N10）"
fresh; rm -f "$FXD/skip/zsh-glob.sh"
expect_red "名簿の鍵（zsh-glob）に fixture が無い" N10 "fixture が無い"
fresh; cp "$FXD/skip/wsl-shell.sh" "$FXD/skip/no-such-key.sh"
expect_red "名簿に無い鍵の fixture がある（no-such-key）" N10 "名簿の kind=skip に無い鍵の fixture"
fresh; sedit "$FXD/skip/effort-metrics.sh" "s#^fx_owners='hooks/record-effort-wallclock.sh #fx_owners='#"
applied "$FXD/skip/effort-metrics.sh" "fx_owners='hooks/record-effort-wallclock.sh" absent && expect_red "fixture の fx_owners が名簿の owner と違う（effort-metrics）" N10 "fx_owners" || bad "変異が当たらない: fx_owners"
fresh; sedit "$FXD/skip/effort-metrics.sh" "s# fx_one 'scripts/record-gate-minutes.sh';##"
applied "$FXD/skip/effort-metrics.sh" "fx_one 'scripts/record-gate-minutes.sh'" absent && expect_red "fixture が owner の 1 つを起動しない（effort-metrics）" N10 "起動していない" || bad "変異が当たらない: owner を起動しない fixture"
fresh; printf '%s\n' 'fx_judge() { echo "PASS 常に素通し"; }' >> "$FXD/skip/zsh-glob.sh"
expect_red "fixture の判定が常に素通し（空振りの fixture）" N10 "zsh-glob none"

# ---- 振る舞いの表（N12: 通知 / N14: 止まった回の注記）---------------------------------------
fresh; sedit "$FCU" 's/止めた層: 宣言//'
applied "$FCU" '止めた層: 宣言' absent && expect_red "通知から停止文の 1 行（止めた層）を外す" N12 "止めた層" || bad "変異が当たらない: 通知の停止文"
fresh; sedit "$FCU" 's/"additionalContext":"%s"/"otherContext":"%s"/'
applied "$FCU" '"additionalContext":"%s"' absent && expect_red "通知を systemMessage だけに出す（additionalContext に出さない）" N12 "additionalContext" || bad "変異が当たらない: 通知の additionalContext"
fresh; sedit "$FCU" 's/を見つけたので、安全のため/を見つけたので/'
applied "$FCU" '安全のため' absent && expect_red "通知から副作用系の文（安全のため止めている）を外す" N12 "安全のため" || bad "変異が当たらない: 副作用系の文"
fresh; rm -f "$FXD/notice/update-check.sh"
expect_red "通知の fixture が無い" N12 "fixture が無い"
fresh; sedit "$FCU" 's/\[ "\${!ff_n-}" != 1 \] || ff_sug=/ff_sug=/'
applied "$FCU" '[ "${!ff_n-}" != 1 ] ||' absent && expect_red "値 0 のガードの旧名でも、次の一手がガードを止める置き換えを勧める" N12 "値 0 のガードの旧名" || bad "変異が当たらない: 値 0 の旧名を置き換えに入れる"
fresh; sedit "$FCU" 's/\[ -z "\$ff_run" \] || ff_next=.*$/:/'
applied "$FCU" '[ -z "$ff_run" ] || ff_next=' absent && expect_red "次の一手に「副作用系の鍵を動かすなら旧名を外すだけでよい」を添えない" N12 "を動かすなら" || bad "変異が当たらない: 動かすなら を外す"
fresh; sedit "$FCU" 's/ff_m="\${ff_upd}\${ff_lines}/ff_m="${ff_upd:-${ff_lines}}/'
applied "$FCU" 'ff_m="${ff_upd:-${ff_lines}}' present && expect_red "更新通知を出す回に L4 宣言の文を並べない（旧名だけの回）" N12 "retired-only" || bad "変異が当たらない: 更新通知と並べない"
fresh; sedit "$FSB" 's/^  \[ -z "\$note" \] || next=.*$/  :/'
applied "$FSB" '[ -z "$note" ] || next=' absent && expect_red "停止文の共通形が 次の一手 へ注記を添えない" N14 "with:" || bad "変異が当たらない: 停止文の注記"
fresh; sedit "$FL" 's/ガードごと止めるなら FF_DEV_TOOLKIT_SKIP=\${ff_l4_key}/ガードごと止めるなら新しい鍵を書く/'
applied "$FL" 'FF_DEV_TOOLKIT_SKIP=${ff_l4_key}' absent && expect_red "注記が新しい書き方（FF_DEV_TOOLKIT_SKIP=<鍵>）を名指さない" N14 "FF_DEV_TOOLKIT_SKIP=exit-code が無い" || bad "変異が当たらない: 注記の新しい書き方"

judge_pending

REACHED_END=1
echo ""
echo "l4-declarations-selftest: pass=${PASS} fail=${FAIL} skip=${SKIP}"
[ "$FAIL" -eq 0 ]
