#!/usr/bin/env bash
# tests/l4-declarations の検出力の実測（合成した root への変異注入。ADR-087）。
# 空振り検出: 実測の材料（tests/l4-declarations/verify.sh・名簿・共通関数）の不在は冒頭で rc 1、無変異の合成 root が緑にならない回（共通関数を常に rc 1 の写しへ替えた）は陽性の対照が赤で rc 1（2026-11-09 macOS / Bash 3.2.57 実測）。sed / awk の変異は適用を確かめ、当たらない回は「変異が当たらない」で赤にする。
#
# 合成 root は実物の名簿（scripts/lib/l4-declarations.tsv）と共通関数・表の道具（tests/l4-declarations/fixtures/lib.sh）を
# そのまま写し、名簿の各行から owner の stub（第 1 引数のプラグイン root から共通関数を読み、stdin の 1 語で行を選ぶ。
# kind=skip は `ff_l4_skipped '<鍵>' '<旧名>' [nonempty]` の 1 行で抜けなければ deny、kind=ack は FF_<鍵>_ACK の前置を
# 通し、別名を持つ ACK は旧名の前置と hook の環境の旧名で注記を出して通す）、振る舞いの表の合成の fixture、
# PUBLIC-SURFACE（4-1 / 4-2-2 / 4-3 / §破壊的変更の記録）、oss README の鍵の表、plugin.json、試験の隔離の 2 ファイル
# （印の間の unset だけ）、旧名を書いてよい docs の対照を作る。まず無変異の合成 root で verify.sh が rc 0・✗ 0 件に
# なること（陽性の対照）を確かめ、次に変異を 1 件ずつ当てて、rc が 0 でないことと、狙った検査番号の ✗ が出ることを
# 両方要求する（別の検査の赤を検出に数えない）。変異ごとに合成 root を写し直し、verify.sh の起動は 4 本ずつ並べる。
#
# skip 経路は持たない（一時領域を作れない・jq / git が無いときは赤）。bash 3.2 互換。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_PLUGIN="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$SRC_PLUGIN/tests/l4-declarations/verify.sh"
SRC_TSV="$SRC_PLUGIN/scripts/lib/l4-declarations.tsv"
SRC_LIB="$SRC_PLUGIN/scripts/lib/l4-declarations.sh"
SRC_FXLIB="$SRC_PLUGIN/tests/l4-declarations/fixtures/lib.sh"
BASH_BIN="${BASH:-bash}"

PASS=0
FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

for f in "$TARGET" "$SRC_TSV" "$SRC_LIB" "$SRC_FXLIB"; do
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

# 合成の名前は実行時に組む（`FF_` で始まる新しい綴りを字句で書くと、公開面の母集団へ入る）。
NP=FF
ack_name() { printf '%s_%s_ACK\n' "$NP" "$(printf '%s' "$1" | tr 'abcdefghijklmnopqrstuvwxyz-' 'ABCDEFGHIJKLMNOPQRSTUVWXYZ_')"; }

# 名簿のデータ行（見出しとコメントを除く）
rows() { awk -F'\t' '/^#/ || NF == 0 { next } !h { h = 1; next } { print }' "$SRC_TSV"; }

BASE="$WORK/base"
BP="$BASE/plugins/ff-dev-toolkit"
BFX="$BP/tests/l4-declarations/fixtures"
mkdir -p "$BP/scripts/lib" "$BP/hooks" "$BP/tests/lib" "$BP/tests/stop-block-contract" "$BP/.claude-plugin" "$BASE/oss/ff-dev-toolkit" \
  "$BFX/skip" "$BFX/ack" "$BFX/notice" "$BASE/docs/02-design" "$BASE/docs/04-quality/jev-lang-ab"
cp "$SRC_TSV" "$BP/scripts/lib/l4-declarations.tsv"
cp "$SRC_LIB" "$BP/scripts/lib/l4-declarations.sh"
cp "$SRC_FXLIB" "$BFX/lib.sh"
# owner の stub: 第 1 引数のプラグイン root から共通関数を読み、stdin の 1 語で行を選ぶ。
#   skip:<鍵>   その鍵の ff_l4_skipped で止まれば exit 0（素通し）、止まらなければ末尾の deny
#   <名前>=1 …  ACK の前置（新しい名前は通す・旧名は注記を出して通す）、hookenv は hook の環境の ACK
#   notice      鍵 update-check の旧名で止まった回に L4 宣言の通知（置き換え・未知の鍵・停止文の 3 行）を出す
stub_head() { printf '%s\n' '#!/usr/bin/env bash' '{ [ -r "$1/scripts/lib/l4-declarations.sh" ] && . "$1/scripts/lib/l4-declarations.sh"; } 2>/dev/null || ff_l4_skipped() { return 1; }' 'ff_in=""' "IFS= read -r -d '' ff_in || true"; }
OWNERS=""
SKIPS="" ACKS="" LEGACIES="" ALIAS_ACKS=""
while IFS=$'\t' read -r k kind owner _ legacy rule _; do
  first="${owner%%,*}"
  for o in $(printf '%s' "$owner" | tr ',' ' '); do
    mkdir -p "$(dirname "$BP/$o")"
    if [ ! -f "$BP/$o" ]; then stub_head > "$BP/$o"; OWNERS="$OWNERS $o"; fi
  done
  if [ "$kind" = "skip" ]; then
    SKIPS="$SKIPS $k"
    call="if ff_l4_skipped '${k}'"
    if [ "$legacy" != "-" ]; then
      call="$call '${legacy}'"
      [ "$rule" = "nonempty" ] && call="$call 'nonempty'"
    fi
    for o in $(printf '%s' "$owner" | tr ',' ' '); do
      printf '%s\n' "case \"\${ff_in-}\" in skip:${k}) ${call}; then exit 0; fi ;; esac" >> "$BP/$o"
    done
    # 合成の fixture: owner を全部同じ入力で起動し、全部 deny なら STOP、全部素通しなら PASS（変異 1 件ごとに
    # 表を 1 周するので、判定は組み込みだけで行い jq / grep を起動しない）
    {
      printf '%s\n' '# shellcheck shell=bash' "fx_owners='$(printf '%s' "$owner" | tr ',' ' ')'" \
        "fx_setup() { printf 'skip:%s' '${k}' > \"\$fx_wk/in\"; }" \
        'fx_one() { local o r; o="$(/bin/bash "$fx_plugin/$1" "$fx_plugin" < "$fx_wk/in" 2> /dev/null)"; r=$?; case "${r}:${o}" in 0:*deny*) fx_s=$((fx_s + 1)) ;; 0:*) fx_p=$((fx_p + 1)) ;; *) fx_e=$((fx_e + 1)) ;; esac; }'
      printf '%s' 'fx_run() { fx_s=0 fx_p=0 fx_e=0;'
      for o in $(printf '%s' "$owner" | tr ',' ' '); do printf ' fx_one %s;' "'$o'"; done
      printf '%s\n' ' }' \
        'fx_judge() { if [ "$fx_e" -eq 0 ] && [ "$fx_p" -eq 0 ] && [ "$fx_s" -gt 0 ]; then echo "STOP 全部 deny"; elif [ "$fx_e" -eq 0 ] && [ "$fx_s" -eq 0 ] && [ "$fx_p" -gt 0 ]; then echo "PASS 全部素通し"; else echo "ERROR 食い違い（STOP ${fx_s} / PASS ${fx_p} / rc≠0 ${fx_e}）"; fi; }'
    } > "$BFX/skip/${k}.sh"
  else
    an="$(ack_name "$k")"
    ACKS="$ACKS $an"
    alias_lg=""
    if [ "$legacy" != "-" ]; then
      alias_lg="$legacy"
    elif [ "$rule" = "skip-legacy" ]; then
      alias_lg="$(awk -F'\t' -v k="$k" '$1 == k && $2 == "skip" { print $5 }' "$SRC_TSV")"
    fi
    if [ -n "$alias_lg" ]; then
      ALIAS_ACKS="$ALIAS_ACKS $k"
      note="{\"hookSpecificOutput\":{\"additionalContext\":\"旧名 ${alias_lg}=1 を読みました。新しい名前は ${an}=1 です\"}}"
      # 実物の hook と同じ 3 つの形で旧名を読む（N7 の (b) が許す形: case の選択肢・値の判定・_note の注記）
      nv="ff_$(printf '%s' "$k" | tr '-' '_')_note"
      {
        printf '%s\n' "${nv}='${note}'"
        printf '%s\n' "case \"\${ff_in-}\" in ${an}=1* | ${alias_lg}=1*) ff_ack=1; case \"\${ff_in-}\" in ${an}=1*) : ;; *) printf '%s\n' \"\$${nv}\"; exit 0 ;; esac ;; esac"
        printf '%s\n' "if [ \"\${ff_in-}\" = hookenv ] && { [ \"\${${an}:-0}\" = \"1\" ] || [ \"\${${alias_lg}:-0}\" = \"1\" ]; }; then [ \"\${${an}:-0}\" = \"1\" ] || printf '%s\n' \"\$${nv}\"; exit 0; fi"
      } >> "$BP/$first"
      {
        printf '%s\n' '# shellcheck shell=bash' "fx_owners='${first}'" "fx_forms='prefix hookenv'" 'fx_setup() { :; }' \
          'fx_input() { if [ "$1" = hookenv ]; then printf hookenv > "$fx_wk/in.json"; else printf "%scmd" "${fx_ack_prefix-}" > "$fx_wk/in.json"; fi; }' \
          "fx_run() { /bin/bash \"\$fx_plugin/${first}\" \"\$fx_plugin\" < \"\$fx_wk/in.json\" > \"\$fx_wk/out\" 2> \"\$fx_wk/err\"; echo \"\$?\" > \"\$fx_wk/rc\"; }"
      } > "$BFX/ack/${k}.sh"
    else
      printf '%s\n' "case \"\${ff_in-}\" in ${an}=1*) ff_ack=1 ;; esac" >> "$BP/$first"
    fi
  fi
  [ "$legacy" = "-" ] || LEGACIES="$LEGACIES $legacy"
done < <(rows)
LG_UC="$(awk -F'\t' '$1 == "update-check" && $2 == "skip" { print $5 }' "$SRC_TSV")"
OW_UC="$(awk -F'\t' '$1 == "update-check" && $2 == "skip" { print $3 }' "$SRC_TSV")"
# 鍵 update-check の owner の stub に L4 宣言の通知の行を足し、合成の通知の fixture を置く。通知の文の旧名は、
# 実物の hook と同じく名簿から読む（呼び出しの引数の外に旧名を字句で書くと N7 が赤にする）
printf '%s\n' "ff_uc_lg=\"\$(awk -F'\\t' '\$1 == \"update-check\" && \$2 == \"skip\" { print \$5 }' \"\$1/scripts/lib/l4-declarations.tsv\")\"" >> "$BP/$OW_UC"
printf '%s\n' "case \"\${ff_in-}\" in notice) if ff_l4_skipped 'update-check' '${LG_UC}'; then jq -nc --arg m \"旧名 \${ff_uc_lg} は内部の別名です。置き換え: FF_DEV_TOOLKIT_SKIP=update-check ・鍵 \${FF_DEV_TOOLKIT_SKIP-} は名簿にありません 止めた層: 宣言 止めた規則: l4-declarations/unknown-key 次の一手: 書き換える\" '{systemMessage: \$m, hookSpecificOutput: {hookEventName: \"SessionStart\", additionalContext: \$m}}'; exit 0; fi ;; esac" >> "$BP/$OW_UC"
{
  printf '%s\n' '# shellcheck shell=bash' "fx_owners='${OW_UC}'" "fx_setup() { printf notice > \"\$fx_wk/in\"; }" \
    "fx_run() { /bin/bash \"\$fx_plugin/${OW_UC}\" \"\$fx_plugin\" < \"\$fx_wk/in\" > \"\$fx_wk/out\" 2> \"\$fx_wk/err\"; echo \"\$?\" > \"\$fx_wk/rc\"; }" \
    'fx_judge() { if [ "$(fx_decision)" = deny ]; then echo "STOP 止まっていない"; else echo "PASS 止まったまま"; fi; }'
} > "$BFX/notice/update-check.sh"
# どの stub も、選ばれた行で抜けなければ ACK を見てから deny する
for o in $OWNERS; do
  printf '%s\n' '[ "${ff_ack-}" != 1 ] || exit 0' "printf '%s\n' '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\"}}'" 'exit 0' >> "$BP/$o"
done
# 旧名を書いてよい場所の対照（docs/ の Markdown の Changelog 節と、過去の実験の記録）
LG_ZSH0="$(awk -F'\t' '$1 == "zsh-glob" && $2 == "skip" { print $5 }' "$SRC_TSV")"
printf '%s\n' '# 設計' '' '本文。' '' '## Changelog' '' '### [1.0.0]' '' "- 旧名 ${LG_ZSH0} を別名にした" > "$BASE/docs/02-design/x.md"
printf '%s\n' "{\"src\": \"${LG_ZSH0}=1\"}" > "$BASE/docs/04-quality/jev-lang-ab/x.json"
{
  printf '%s\n' '# 公開面' '' '## 公開面 4: 環境変数' '' '### 4-1. 契約' '' '- `FF_DEV_TOOLKIT_SKIP`'
  for a in $ACKS; do printf '%s\n' "- \`${a}\`"; done
  printf '%s\n' '' '### 4-2. 内部' '' '#### 4-2-1. tests の中だけ' '' '#### 4-2-2. 配布実行物・配布文書に現れるもの' ''
  printf '%s\n' '##### 互換の別名（remove_after 1.1.0）' ''
  for l in $LEGACIES; do printf '%s\n' "- \`${l}\`"; done
  printf '%s\n' '' '### 4-3. L4 宣言の鍵' '' '| 鍵 | 種別 | 担当する実体 | 包含 | 旧名 |' '| --- | --- | --- | --- | --- |'
  for k in $SKIPS; do printf '%s\n' "| \`${k}\` | skip | - | - | - |"; done
  printf '%s\n' '' '## 公開面 5: 環境変数（接頭辞の無いもの）' '' '## 破壊的変更の記録' '' '| 旧名 | 新しい書き方 |' '| --- | --- |'
  for l in $LEGACIES; do printf '%s\n' "| \`${l}\` | - |"; done
  printf '%s\n' '' '## この一覧を守る機械検査' ''
} > "$BP/PUBLIC-SURFACE.md"
{
  printf '%s\n' '# ff-dev-toolkit' '' '## 止める宣言' '' '| 鍵 | 止めるもの |' '| --- | --- |'
  for k in $SKIPS; do printf '%s\n' "| \`${k}\` | - |"; done
  printf '%s\n' '' '終わり。'
} > "$BASE/oss/ff-dev-toolkit/README.md"
printf '%s\n' '{' '  "name": "ff-dev-toolkit",' '  "version": "0.181.0"' '}' > "$BP/.claude-plugin/plugin.json"
for iso in "$BP/tests/stop-block-contract/verify.sh" "$BP/tests/lib/adapter-env-isolation.sh"; do
  {
    printf '%s\n' '#!/usr/bin/env bash' '# l4-default-unset:begin' "unset FF_DEV_TOOLKIT_SKIP \\"
    for a in $ACKS; do printf '%s\n' "  ${a} \\"; done
    printf '%s\n' '  2>/dev/null || true' '# l4-default-unset:end'
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
  FS="$FIX/plugins/ff-dev-toolkit/PUBLIC-SURFACE.md"
  FR="$FIX/oss/ff-dev-toolkit/README.md"
  FH="$FIX/plugins/ff-dev-toolkit/hooks/guard-zsh-glob.sh"
  FA="$FIX/plugins/ff-dev-toolkit/hooks/auto-update-marketplace.sh"
  FRV="$FIX/plugins/ff-dev-toolkit/hooks/guard-review-in-flight.sh"
  FIL="$FIX/plugins/ff-dev-toolkit/hooks/guard-issue-labels.sh"
  FCU="$FIX/plugins/ff-dev-toolkit/hooks/check-update.sh"
  FXD="$FIX/plugins/ff-dev-toolkit/tests/l4-declarations/fixtures"
  FDOC="$FIX/docs/02-design/x.md"
  LOG="$FIX.log"
}
# WITH_TABLE=0 の変異は表の fixture（skip / ack / notice）を外した写しで測る（狙いが表の外の検査で、表の起動は
# 判定に要らない。外した写しでは N10〜N12 も赤になるが、判定は狙った検査番号の ✗ で行うので検出に数えない）
WITH_TABLE=1
fresh() {
  M_N=$((M_N + 1)); FIX="$WORK/m${M_N}"; rm -rf -- "$FIX" && cp -R "$BASE" "$FIX"; set_paths
  [ "$WITH_TABLE" = 1 ] || rm -rf -- "$FXD/skip" "$FXD/ack" "$FXD/notice"
}
run_target() { RC=0; "$BASH_BIN" "$TARGET" --root "$FIX" > "$LOG" 2>&1 || RC=$?; }
count() { grep -cF -- "$1" "$LOG" || true; }
# ファイルを awk で書き換える（適用されなければ赤）。$1=ファイル $2=awk プログラム
rewrite() {
  local f="$1" prog="$2"
  awk -F'\t' -v OFS='\t' "$prog" "$f" > "$f.new" && mv "$f.new" "$f"
}
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
    # 検査番号は `:` まで含めて数える（`✗ N1` が `✗ N10:` 〜 `✗ N13:` にも当たり、表を外した写しでは常に赤の
    # N10〜N12 を N1 の検出に数えてしまうため）。verify.sh の bad はどれも `<番号>: …` の形
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
  ok "無変異の合成 root は rc 0・✗ 0 件（✓ ${p_ok} 件）"
else
  bad "無変異の合成 root が緑にならない（rc ${RC}・✓ ${p_ok:-0}・✗ ${p_bad:-0}）。以後の赤は検出に数えられない"
  sed 's/^/      | /' "$LOG" | head -n 60 >&2
fi

LG_ZSH="$(awk -F'\t' '$1 == "zsh-glob" && $2 == "skip" { print $5 }' "$SRC_TSV")"

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

# ---- 名簿と実装 -----------------------------------------------------------------------
fresh; rewrite "$FT" '!($1 == "wsl-shell" && $2 == "skip") { print }'
applied "$FT" "$(printf 'wsl-shell\tskip')" absent && expect_red "名簿から 1 行消す（wsl-shell / skip）" N2 "wsl-shell" || bad "変異が当たらない: 名簿から 1 行消す"
fresh; sed "s/ff_l4_skipped 'zsh-glob'/ff_l4_skipped 'zsh-glop'/" "$FH" > "$FH.new" && mv "$FH.new" "$FH"
applied "$FH" "'zsh-glop'" present && expect_red "hook の鍵の文字列を変える（zsh-glob → zsh-glop）" N2 "zsh-glop" || bad "変異が当たらない: hook の鍵の文字列"
fresh; sed "s/ff_l4_skipped 'zsh-glob'/ff_l4_skipped \"\$k\"/" "$FH" > "$FH.new" && mv "$FH.new" "$FH"
applied "$FH" 'ff_l4_skipped "$k"' present && expect_red "鍵を変数で渡す" N2 "変数" || bad "変異が当たらない: 鍵を変数で渡す"
fresh; sed "s/'${LG_ZSH}'/'${LG_ZSH}_X'/" "$FH" > "$FH.new" && mv "$FH.new" "$FH"
applied "$FH" "${LG_ZSH}_X" present && expect_red "第 2 引数の旧名を名簿と違えて書く" N3 || bad "変異が当たらない: 第 2 引数の旧名"
fresh; sed "s/ 'nonempty';/;/" "$FA" > "$FA.new" && mv "$FA.new" "$FA"
applied "$FA" "'nonempty'" absent && expect_red "legacy_value_rule=nonempty の鍵の呼び出しから nonempty を外す" N3 "nonempty" || bad "変異が当たらない: nonempty を外す"
fresh; rm -f "$FIX/plugins/ff-dev-toolkit/hooks/guard-wsl-shell.sh"
expect_red "owner の実体を消す（hooks/guard-wsl-shell.sh）" N1 "owner が実在しない"

# ---- 公開文書 -----------------------------------------------------------------------
fresh; grep -vF '| `wsl-shell` |' "$FS" > "$FS.new" && mv "$FS.new" "$FS"
expect_red "PUBLIC-SURFACE 4-3 から 1 行消す（wsl-shell）" N4 "wsl-shell"
fresh; awk '/^### 4-3\./ { skip = 1 } /^## 公開面 5/ { skip = 0 } !skip' "$FS" > "$FS.new" && mv "$FS.new" "$FS"
expect_red "PUBLIC-SURFACE に 4-3 の節が無い" N4 "1 件も抽出できない"
fresh; grep -vF '| `zsh-glob` |' "$FR" > "$FR.new" && mv "$FR.new" "$FR"
expect_red "oss README の鍵の表から 1 行消す（zsh-glob）" N5 "zsh-glob"
fresh; printf '%s\n' '' "止めるときは ${LG_ZSH}=1 を設定する。" >> "$FR"
expect_red "oss README に旧名を 1 つ足す" N7 "oss/ff-dev-toolkit/README.md"
fresh; awk -v l="$LG_ZSH" '{ print } /^### 4-1\./ { print "- `" l "`" }' "$FS" > "$FS.new" && mv "$FS.new" "$FS"
expect_red "PUBLIC-SURFACE の許可した節（4-2-2 / 破壊的変更の記録）の外に旧名を書く" N7 "PUBLIC-SURFACE.md"
fresh; printf '%s\n' "# 呼び出しの例: ff_l4_skipped 'zsh-glob' '${LG_ZSH}'" >> "$FH"
expect_red "hook のコメント行に旧名を書く（呼び出し行の許可はコメントに及ばない）" N7 "guard-zsh-glob.sh"

fresh; sed 's/FF_REVIEW_LOCK_ACK=1\* | FF_REVIEW_LOCK_OVERRIDE=1\*)/FF_REVIEW_LOCK_OVERRIDE=1*)/' "$FRV" > "$FRV.new" && mv "$FRV.new" "$FRV"
applied "$FRV" 'FF_REVIEW_LOCK_ACK=1* | ' absent && expect_red "ACK の別名の行から新しい名前を外す（review-lock）" N7 "guard-review-in-flight.sh" || bad "変異が当たらない: ACK の別名の行"
fresh; sed 's/FF_ISSUE_LABEL_ACK=1\* | FF_DEV_TOOLKIT_SKIP_ISSUE_LABEL_GUARD=1\*)/FF_DEV_TOOLKIT_SKIP_ISSUE_LABEL_GUARD=1*)/' "$FIL" > "$FIL.new" && mv "$FIL.new" "$FIL"
applied "$FIL" 'FF_ISSUE_LABEL_ACK=1* | ' absent && expect_red "skip-legacy の別名の行から新しい名前を外す（issue-label）" N7 "guard-issue-labels.sh" || bad "変異が当たらない: skip-legacy の別名の行"
fresh; printf '%s\n' "case \"\${cmd-}\" in ${NP}_ZSH_GLOB_ACK=1* | ${LG_ZSH}=1*) : ;; esac" >> "$FH"
expect_red "SKIP の旧名を ACK の名前と同じ行に書く（別名の組に無い）" N7 "guard-zsh-glob.sh"
fresh; rewrite "$FT" '!/^#/ && $1 == "pr-draft" && $2 == "ack" { $6 = "skip-legacy" } { print }'
expect_red "skip-legacy を同じ鍵の kind=skip の旧名が無い行に書く（pr-draft）" N1 "skip-legacy"
AN_D="$(ack_name discard-uncommitted)"
LG_D="$(awk -F'\t' '$1 == "discard-uncommitted" && $2 == "ack" { print $5 }' "$SRC_TSV")"
OW_D="$(awk -F'\t' '$1 == "discard-uncommitted" && $2 == "ack" { print $3 }' "$SRC_TSV")"
fresh; printf '%s\n' "echo \"コマンド先頭に ${AN_D}=1（または ${LG_D}=1）を付けて再実行する\"" >> "$FIX/plugins/ff-dev-toolkit/${OW_D}"
expect_red "案内文に新しい名前と旧名を並べて書く（discard-uncommitted。別名を読む 3 つの形のどれでもない）" N7 "${OW_D##*/}"
fresh; printf '%s\n' "echo \"ff_l4_skipped で読む旧名 ${LG_ZSH} は内部の別名\"" >> "$FH"
expect_red "ff_l4_skipped の語がある行で、呼び出しの引数の外に旧名を書く" N7 "guard-zsh-glob.sh"

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

# ---- 公開 README の置き場所（N5: 開発元は oss/ff-dev-toolkit/、公開同期の配置は root）---------------
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
fresh; printf '%s\n' 'plugins/' > "$FIX/.gitignore"
expect_red "旧名の走査が名簿に届かない（.gitignore で plugins/ を外す。走査の空振り）" N7 "走査の空振り"
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

# ---- ACK の型・期限・隔離 ---------------------------------------------------------------
fresh; printf '%s\n' "case \"\${cmd-}\" in ${NP}_BOGUS_ACK=1*) : ;; esac" >> "$FH"
expect_red "配布実行物に名簿に無い ACK の名前を足す" N6 "_BOGUS_ACK"
fresh; sed 's/"version": "0.181.0"/"version": "1.1.0"/' "$FIX/plugins/ff-dev-toolkit/.claude-plugin/plugin.json" > "$WORK/pj" && mv "$WORK/pj" "$FIX/plugins/ff-dev-toolkit/.claude-plugin/plugin.json"
expect_red "plugin.json の version を 1.1.0 にする（旧名が残ったまま）" N8 "1.1.0"
ZA="$(ack_name zsh-glob)"
fresh; grep -vF "  ${ZA} \\" "$FIX/plugins/ff-dev-toolkit/tests/stop-block-contract/verify.sh" > "$WORK/sbc" && mv "$WORK/sbc" "$FIX/plugins/ff-dev-toolkit/tests/stop-block-contract/verify.sh"
expect_red "stop-block-contract の既定の unset から 1 つ消す（${ZA}）" N9 "$ZA"
fresh; grep -vF "  ${ZA} \\" "$FIX/plugins/ff-dev-toolkit/tests/lib/adapter-env-isolation.sh" > "$WORK/aei" && mv "$WORK/aei" "$FIX/plugins/ff-dev-toolkit/tests/lib/adapter-env-isolation.sh"
expect_red "isolate_hook_env の既定の unset から 1 つ消す（${ZA}）" N9 "$ZA"
fresh; awk -v za="$ZA" '/l4-default-unset:begin/ { print; print "# " za; next } $0 == "  " za " \\" { next } { print }' "$FIX/plugins/ff-dev-toolkit/tests/lib/adapter-env-isolation.sh" > "$WORK/aei" && mv "$WORK/aei" "$FIX/plugins/ff-dev-toolkit/tests/lib/adapter-env-isolation.sh"
applied "$FIX/plugins/ff-dev-toolkit/tests/lib/adapter-env-isolation.sh" "  ${ZA} \\" absent && expect_red "isolate_hook_env の印の間で ${ZA} をコメントへ移す（unset されない）" N9 "$ZA" || bad "変異が当たらない: 印の間のコメント化"
fresh; grep -v 'l4-default-unset:end' "$FIX/plugins/ff-dev-toolkit/tests/stop-block-contract/verify.sh" > "$WORK/sbc" && mv "$WORK/sbc" "$FIX/plugins/ff-dev-toolkit/tests/stop-block-contract/verify.sh"
expect_red "stop-block-contract の印（:end）を消す" N9 "印"
fresh; rewrite "$FT" '!/^#/ && $1 != "key" { $5 = "-"; $6 = "-" } { print }'
expect_red "legacy 列を全部空にする（残存の検査より先に赤）" N7 "legacy 列の集合が空"

# ---- 共通関数 -----------------------------------------------------------------------
fresh; sed 's/^  ff_l4_list="\${FF_DEV_TOOLKIT_SKIP-}"$/  ff_l4_list="$(printf %s "${FF_DEV_TOOLKIT_SKIP-}")"/' "$FL" > "$FL.new" && mv "$FL.new" "$FL"
applied "$FL" 'ff_l4_list="$(printf' present && expect_red "共通関数の早期に戻る前の経路へコマンド置換を足す" U2 "子プロセスの段" || bad "変異が当たらない: 共通関数へコマンド置換"
fresh; sed 's/\[ "\$ff_l4_val" = "1" \] && return 0/[ -n "$ff_l4_val" ] \&\& return 0/' "$FL" > "$FL.new" && mv "$FL.new" "$FL"
applied "$FL" '[ "$ff_l4_val" = "1" ]' absent && expect_red "旧名の既定の判定を「空でなければ」へ倒す" U1 "=0" || bad "変異が当たらない: 旧名の判定"
fresh; sed 's/\*\[!abcdefghijklmnopqrstuvwxyz0123456789,-\]\* | ,\* | \*, | \*,,\*) return 1 ;;/,* | *, | *,,*) return 1 ;;/' "$FL" > "$FL.new" && mv "$FL.new" "$FL"
applied "$FL" '*[!abcdefghijklmnopqrstuvwxyz0123456789,-]*' absent && expect_red "値の文法の検査（許す文字）を外す" U1 "UPDATE_CHECK" || bad "変異が当たらない: 値の文法"
fresh; sed 's/ | \*,,\*) return 1 ;;/) return 1 ;;/' "$FL" > "$FL.new" && mv "$FL.new" "$FL"
applied "$FL" '*,,*' absent && expect_red "値の文法の検査（空の要素 ,,）を外す" U1 "zsh-glob,,update-check" || bad "変異が当たらない: 空の要素の検査"
fresh; rm -f "$FT.bak"; rewrite "$FT" '!/^#/ && $1 == "zsh-glob" && $2 == "skip" { $4 = "-" } { print }'
expect_red "covers から zsh-expansion を外す" U1 "zsh-expansion"

# ---- 旧名を書いてよい場所（docs/ の Changelog 節）------------------------------------------
fresh; awk -v l="$LG_ZSH" 'NR == 3 { print "旧名 " l " の説明。" } { print }' "$FDOC" > "$FDOC.new" && mv "$FDOC.new" "$FDOC"
expect_red "docs/ の Markdown の Changelog 節より前に旧名を書く" N7 "docs/02-design/x.md"
fresh; printf '%s\n' '' '## 次の節' '' "旧名 ${LG_ZSH} の説明。" >> "$FDOC"
expect_red "docs/ の Markdown の Changelog 節の後ろの「## 」節に旧名を書く" N7 "docs/02-design/x.md"

# ---- 振る舞いの表（N10: kind=skip）------------------------------------------------------
WITH_TABLE=1
fresh; sed "s/if ff_l4_skipped 'zsh-glob'/if FF_DEV_TOOLKIT_SKIP= ff_l4_skipped 'zsh-glob'/" "$FH" > "$FH.new" && mv "$FH.new" "$FH"
applied "$FH" "if FF_DEV_TOOLKIT_SKIP= ff_l4_skipped 'zsh-glob'" present && expect_red "新しい鍵を読まない stub（呼び出しの間だけ FF_DEV_TOOLKIT_SKIP を空にする）" N10 "zsh-glob new" || bad "変異が当たらない: 新しい鍵を読まない stub"
fresh; awk 'NR == 2 { print; print "[ -z \"${FF_DEV_TOOLKIT_SKIP-}\" ] || exit 0"; next } { print }' "$FH" > "$FH.new" && mv "$FH.new" "$FH"
applied "$FH" '[ -z "${FF_DEV_TOOLKIT_SKIP-}" ] || exit 0' present && expect_red "鍵の打ち間違いでも止まる（素通しする）stub" N10 "zsh-glob typo" || bad "変異が当たらない: 打ち間違いでも素通しする stub"
fresh; sed "s/if ff_l4_skipped 'zsh-glob'/if ${LG_ZSH}= ff_l4_skipped 'zsh-glob'/" "$FH" > "$FH.new" && mv "$FH.new" "$FH"
applied "$FH" "if ${LG_ZSH}= ff_l4_skipped" present && expect_red "旧名を読まない stub（呼び出しの間だけ旧名を空にする）" N10 "zsh-glob legacy" || bad "変異が当たらない: 旧名を読まない stub"
fresh; sed "s/ 'nonempty';/;/" "$FA" > "$FA.new" && mv "$FA.new" "$FA"
applied "$FA" "'nonempty'" absent && expect_red "nonempty の鍵の呼び出しから nonempty を外すと旧名=0 の行も赤" N10 "auto-update legacy0" || bad "変異が当たらない: nonempty を外す（N10）"
fresh; rm -f "$FXD/skip/zsh-glob.sh"
expect_red "名簿の鍵（zsh-glob）に fixture が無い" N10 "fixture が無い"
fresh; cp "$FXD/skip/wsl-shell.sh" "$FXD/skip/no-such-key.sh"
expect_red "名簿に無い鍵の fixture がある（no-such-key）" N10 "名簿の kind=skip に無い鍵の fixture"
fresh; sed "s#^fx_owners='hooks/record-effort-wallclock.sh #fx_owners='#" "$FXD/skip/effort-metrics.sh" > "$WORK/fx" && mv "$WORK/fx" "$FXD/skip/effort-metrics.sh"
applied "$FXD/skip/effort-metrics.sh" "fx_owners='hooks/record-effort-wallclock.sh" absent && expect_red "fixture の fx_owners が名簿の owner と違う（effort-metrics）" N10 "fx_owners" || bad "変異が当たらない: fx_owners"
fresh; sed "s# fx_one 'scripts/record-gate-minutes.sh';##" "$FXD/skip/effort-metrics.sh" > "$WORK/fx" && mv "$WORK/fx" "$FXD/skip/effort-metrics.sh"
applied "$FXD/skip/effort-metrics.sh" "fx_one 'scripts/record-gate-minutes.sh'" absent && expect_red "fixture が owner の 1 つを起動しない（effort-metrics）" N10 "起動していない" || bad "変異が当たらない: owner を起動しない fixture"
fresh; printf '%s\n' 'fx_judge() { echo "PASS 常に素通し"; }' >> "$FXD/skip/zsh-glob.sh"
expect_red "fixture の判定が常に素通し（空振りの fixture）" N10 "zsh-glob none"

# ---- 振る舞いの表（N11: ACK の別名 / N12: 通知）-------------------------------------------
fresh; sed 's/"additionalContext":/"otherContext":/g' "$FRV" > "$FRV.new" && mv "$FRV.new" "$FRV"
applied "$FRV" '"additionalContext":' absent && expect_red "旧名の注記を出さない ACK の stub（review-lock）" N11 "review-lock prefix/legacy" || bad "変異が当たらない: 注記を出さない ACK の stub"
fresh; sed 's/FF_REVIEW_LOCK_ACK=1\* | /FF_REVIEW_LOCK_ACK=9* | /' "$FRV" > "$FRV.new" && mv "$FRV.new" "$FRV"
applied "$FRV" 'FF_REVIEW_LOCK_ACK=9* | ' present && expect_red "新しい名前の前置を読まない ACK の stub（review-lock）" N11 "review-lock prefix/new" || bad "変異が当たらない: 新しい名前を読まない ACK の stub"
fresh; rm -f "$FXD/ack/discard-uncommitted.sh"
expect_red "ACK の別名を持つ鍵（discard-uncommitted）に fixture が無い" N11 "fixture が無い"
fresh; cp "$FXD/ack/review-lock.sh" "$FXD/ack/pr-draft.sh"
expect_red "ACK の別名を持たない鍵の fixture がある（pr-draft）" N11 "名簿の ACK の別名に無い鍵の fixture"
fresh; sed 's/止めた層: 宣言 //' "$FCU" > "$FCU.new" && mv "$FCU.new" "$FCU"
applied "$FCU" '止めた層: 宣言' absent && expect_red "通知から停止文の 1 行（止めた層）を外す" N12 "止めた層" || bad "変異が当たらない: 通知の停止文"
fresh; sed 's/, hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: \$m}//' "$FCU" > "$FCU.new" && mv "$FCU.new" "$FCU"
applied "$FCU" 'additionalContext: $m' absent && expect_red "通知を systemMessage だけに出す（additionalContext に出さない）" N12 "additionalContext" || bad "変異が当たらない: 通知の additionalContext"
fresh; rm -f "$FXD/notice/update-check.sh"
expect_red "通知の fixture が無い" N12 "fixture が無い"

judge_pending

REACHED_END=1
echo ""
echo "l4-declarations-selftest: pass=${PASS} fail=${FAIL}"
[ "$FAIL" -eq 0 ]
