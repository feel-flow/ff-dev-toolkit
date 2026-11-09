#!/usr/bin/env bash
# L4 宣言（利用者が書く SKIP / ACK）の名簿 scripts/lib/l4-declarations.tsv と、実装・公開文書・試験の隔離の照合（ADR-087）。
# 空振り検出: tests/l4-declarations-selftest の合成 root への変異で 1 件ずつ実測した（2026-11-09 macOS / Bash 3.2.57。無変異の合成 root は rc 0・✗ 0 件）: 名簿の不在・0 行（見出しとコメントだけ）・0 バイト・列の数の違い・空の欄は N0 で rc 1、名簿から 1 行消す・hook の鍵の文字列を変える・鍵を変数で渡すは N2、第 2 引数の旧名の違い・nonempty の欠落は N3（合成 root の呼び出しは単引用の 'nonempty' で書き、陽性の対照が緑であることで単引用の認識も固定する）、owner の実体の不在は N1、PUBLIC-SURFACE 4-3 から 1 行消す・4-3 の節が無いは N4、README の鍵の表から 1 行消すは N5、README に旧名を 1 つ足す・PUBLIC-SURFACE の許可した節の外の旧名・hook のコメント行の旧名・ACK の別名の行から新しい名前を外す・SKIP の旧名を ACK の名前と同じ行に書くは N7（陽性の対照は ACK の別名 3 組を新しい名前と同じ行で読む）、skip-legacy を同じ鍵の kind=skip の旧名が無い行に書くは N1、案内文に新しい名前と旧名を並べて書く・ff_l4_skipped の語がある行で呼び出しの引数の外に旧名を書くは N7（陽性の対照は ACK の別名の case の選択肢・値の判定・_note の注記の 3 形）、scripts/ の読み込み行から [ -r ] を外す・変数経由で 2 行に分けて読む・引用の無い path で読む・決まった形の後ろへ確かめない読み込みを同じ行に繋ぐ・決まった形を行末のコメントに書くだけ・読み込み行を全部消す（1 件も無い）は N13、oss/ff-dev-toolkit/ があるのに README が無い・公開同期の配置の root の README.md から鍵を 1 行消すは N5（陽性の対照は公開同期の配置で root の README.md を読む）、.gitignore で走査を名簿に届かなくする（走査の空振り）は N7、docs/ の Markdown の Changelog 節より前・Changelog 節の後ろの「## 」節に旧名を書くは N7（陽性の対照は Changelog 節の中と docs/04-quality/jev-lang-ab/ の旧名）、新しい鍵を読まない stub（呼び出しの間だけ FF_DEV_TOOLKIT_SKIP を空にする）・打ち間違いでも素通しする stub・旧名を読まない stub・nonempty を外す（旧名=0 の行）・名簿の鍵に fixture が無い・名簿に無い鍵の fixture・fx_owners の違い・owner を起動しない fixture・判定が常に素通しの fixture は N10、旧名の注記を出さない ACK の stub・新しい名前の前置を読まない ACK の stub・ACK の別名を持つ鍵に fixture が無い・別名を持たない鍵の fixture は N11、通知から停止文の 1 行を外す・通知を systemMessage だけに出す・通知の fixture が無いは N12（陽性の対照は合成の owner の stub と合成の fixture で表の全行が期待どおり。表の外を狙う変異は表の fixture を外した写しで測る。selftest の所要は macOS で約 17 秒）、名簿に無い ACK の名前は N6、version を 1.1.0 にするは N8、stop-block-contract / isolate_hook_env の unset を 1 つ消す・印を消す・印の間で名前をコメントへ移すは N9、legacy 列を全部空にするは残存の走査より先に N7（legacy 列の集合が空）、共通関数へコマンド置換を足すは U2、旧名の判定を空でなければへ倒す・値の文法の許す文字の検査を外す・空の要素（,,）の検査を外す・covers を外すは U1 が赤。
# run-all-required: yes — 名簿と実装・公開文書の一致を見るのはこの suite だけで、skip 経路は持たないが、将来 skip 経路が生えても黙って消えてはならない
#
# 使い方: verify.sh [--root <リポジトリ root>]
#   --root は selftest（tests/l4-declarations-selftest）が合成した root を渡す口。既定はこのファイルから
#   4 つ上（リポジトリ root）。公開 checkout（公開同期の配置）では oss/ff-dev-toolkit/ の中身が root へ展開される
#   ので、公開 README は root の README.md になる（oss/ff-dev-toolkit/ が無い root では root の README.md を読む）。
#
# 検査（どれも名指しの ✗ で数え、最後に 1 件でもあれば rc 1）:
#   N0 名簿の前提: 不在・読めない・0 バイト・見出し行の違い・列の数（タブ区切り 7 列）・空の欄・データ行 0 件は
#      検査不成立として、ここで rc 1 で終える（以後の照合は名簿を読めたことを前提にする）
#   N1 名簿の形: kind（skip / ack）・鍵の綴り（小文字のケバブ）・(key, kind) の重複・旧名の形と重複・
#      legacy_value_rule（旧名があれば eq1 / nonempty、無ければ -）・remove_after（x.y.z）・covers の参照先・
#      owner の実在
#   N2 呼び出しの鍵: hooks/・scripts/・tests/lib/ の `ff_l4_skipped '<鍵>' …` の第 1 引数のリテラルの集合が、
#      名簿の kind=skip の鍵の集合と一致する（片方にだけある鍵を両方向とも名指す）。鍵を変数で渡す呼び出しも赤
#   N3 呼び出しの旧名: 第 2 引数が名簿の legacy 列と一致し、第 3 引数 nonempty の有無が legacy_value_rule と一致する
#   N4 PUBLIC-SURFACE の「### 4-3.」の表の鍵（先頭セル）の集合 = 名簿の kind=skip の鍵の集合
#   N5 公開 README（開発元は oss/ff-dev-toolkit/README.md、公開同期の配置は root の README.md）の鍵の表（見出しの先頭セルが `鍵` の表。データ行の先頭セル）の集合 = 同上
#   N6 配布実行物（hooks/・scripts/・tests/lib/・tests/run-all.sh・mcp/src/）にある `FF_<…>_ACK` の名前が、どれも
#      名簿の kind=ack の鍵から作る名前（FF_ + 鍵を大文字・`_` 区切りにしたもの + _ACK）にある（1 件も無いのも赤）
#   N7 旧名の残存: 名簿の legacy 列の集合が空なら、残存を数える前に赤。走査が名簿に 1 件も当たらない（届いていない）のも赤。空でなければ、リポジトリの作業ツリー
#      （.gitignore を除く）で旧名が許可した場所の外に現れたら赤。許可した場所は下の allowed_path / allowed_line と、
#      PUBLIC-SURFACE の 4-2-2・§破壊的変更の記録、docs/ の Markdown の「## Changelog」節（次の「## 」見出しの前まで）
#   N8 期限: plugin.json の version が remove_after 以上なのに legacy 列に旧名が残る行があれば赤
#   N9 試験の隔離: tests/stop-block-contract/verify.sh と tests/lib/adapter-env-isolation.sh の印
#      （`l4-default-unset:begin` 〜 `:end`）の間に、FF_DEV_TOOLKIT_SKIP と名簿の kind=ack の名前が全部ある
#   U1 共通関数の終了コードの表（/bin/bash があればそれで、無ければこの suite の bash で）
#   U2 両方とも未設定の 1 回の呼び出しが子プロセスを起こさない（xtrace の跡がどれも [0] の段で、
#      コマンドがどれも組み込み・予約語・関数・代入）。PATH を空にしても rc 1 で戻る
#   U3 共通関数に連想配列と正規表現の照合が無い（`declare -A` / `=~` が 0 件）
#   N10 振る舞いの表（kind=skip）: 名簿の鍵ごとに fixtures/skip/<鍵>.sh で owner を実際に起動し、宣言なし=止める /
#      FF_DEV_TOOLKIT_SKIP=<鍵>=素通し / 旧名=1=素通し（legacy_value_rule=nonempty は旧名=0 も素通し）/
#      FF_DEV_TOOLKIT_SKIP=<鍵>-guard（打ち間違い）=止める。名簿の鍵に fixture が無い・名簿に無い鍵の fixture がある・
#      fx_owners が名簿の owner 列と違う・owner を fx_owners の外で使っていない・判定が STOP / PASS で始まらないは赤
#   N11 ACK の別名の表: kind=ack の legacy と skip-legacy を持つ鍵ごとに fixtures/ack/<鍵>.sh の前置の形（fx_forms）×
#      新しい名前=通って additionalContext に注記なし / 旧名=通って additionalContext に旧名と新しい名前 / 前置なし=deny
#   N12 SessionStart の L4 宣言の通知: 鍵 update-check の旧名=1 と名簿に無い鍵を置いて fixtures/notice/update-check.sh を
#      起動し、systemMessage と additionalContext の両方に置き換え（FF_DEV_TOOLKIT_SKIP=update-check）・未知の鍵・旧名・
#      停止文の 3 行があり、更新チェックは止まったまま
#      表の fixture は 4 通りの両側（止める / 素通し）を自分で示すので、針の当たらない fixture（常に素通し・常に deny）は
#      表の行が赤にする。起動は 1 回ごとに env -i の新しい bash（fixtures/lib.sh のヘッダ）で、利用者の環境の宣言を混ぜない
#   N13 共通関数の読み込みの形: hooks/・scripts/・tests/lib/・.claude/hooks/ で l4-declarations.sh の名前を書いた
#      非コメント行は、どれも `{ [ -r "<lib>" ] && . "<lib>"; } 2>/dev/null || …` の 1 行の形にする（bash 3.2 は
#      set -e の下で `.` の失敗が `||` の中でも致命。変数へ入れて別の行で読む形も赤）。該当の行が 0 件も赤
#
# bash 3.2 互換（連想配列・`=~` を使わない）。外部コマンド: awk / grep / sed / sort / comm / git / jq（表の owner は
# それぞれの fixture が要るもの: git / jq / find など。ネットワークは使わない）。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || { echo "✗ l4-declarations: --root に値がありません" >&2; exit 2; }
      ROOT="$(cd "$2" 2>/dev/null && pwd)" || { echo "✗ l4-declarations: --root を解決できません: $2" >&2; exit 2; }
      shift 2 ;;
    *) echo "✗ l4-declarations: 未知の引数: $1" >&2; exit 2 ;;
  esac
done
PLUGIN="$ROOT/plugins/ff-dev-toolkit"
TSV="$PLUGIN/scripts/lib/l4-declarations.tsv"
LIB="$PLUGIN/scripts/lib/l4-declarations.sh"
SURFACE_DOC="$PLUGIN/PUBLIC-SURFACE.md"
# 公開 README: 開発元の配置は oss/ff-dev-toolkit/README.md、公開同期の配置（oss/ の中身が root へ展開される）は
# root の README.md。oss/ff-dev-toolkit/ があるのにその README が無い回は、root へ倒さず N5 の赤にする
if [ -d "$ROOT/oss/ff-dev-toolkit" ]; then
  OSS_README="$ROOT/oss/ff-dev-toolkit/README.md" OSS_README_REL="oss/ff-dev-toolkit/README.md"
else
  OSS_README="$ROOT/README.md" OSS_README_REL="README.md（公開同期の配置）"
fi
PLUGIN_JSON="$PLUGIN/.claude-plugin/plugin.json"
SBC="$PLUGIN/tests/stop-block-contract/verify.sh"
AEI="$PLUGIN/tests/lib/adapter-env-isolation.sh"
SURFACE_LIB="$SCRIPT_DIR/../lib/public-surface.sh"
TSV_HEADER="key	kind	owner	covers	legacy	legacy_value_rule	remove_after"

PASS=0
FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

if WORK="$(mktemp -d "${TMPDIR:-/tmp}/ff-l4-declarations.XXXXXX")" && [ -d "$WORK" ] && [ ! -L "$WORK" ]; then
  :
else
  echo "✗ l4-declarations: 一時ディレクトリを作成できない（検査不成立）" >&2
  exit 1
fi
REACHED_END=0
cleanup() {
  local rc=$? ff_jobs ff_tree
  # 表の worker（b_bg の背景ジョブ）が残っていれば、worker の中で走っている fixture の bash まで止めて待つ。
  # 走ったまま消すと、fixture の mkdir -p が作業ディレクトリを作り直し、一時領域に残る（pid だけへ送られた
  # シグナルで落ちた回）。子孫は ps の pid / ppid から辿り、ps がその形で出せない環境では worker だけを止める
  ff_jobs="$(jobs -p)"
  if [ -n "$ff_jobs" ]; then
    # shellcheck disable=SC2086 # pid の一覧を語に割る
    ff_tree="$(ps -A -o pid= -o ppid= 2>/dev/null | awk -v roots=" $(printf '%s ' $ff_jobs)" '
      { p[NR] = $1; pp[NR] = $2; n = NR }
      END {
        set = roots
        do { changed = 0
          for (i = 1; i <= n; i++) if (index(set, " " pp[i] " ") && !index(set, " " p[i] " ")) { set = set p[i] " "; changed = 1 }
        } while (changed)
        print set
      }')"
    [ -n "${ff_tree// /}" ] || ff_tree="$ff_jobs"
    # shellcheck disable=SC2086 # pid の一覧を語に割る
    kill $ff_tree 2>/dev/null
    wait 2>/dev/null
  fi
  rm -rf -- "$WORK"
  if [ "$REACHED_END" -ne 1 ] && [ "$rc" -eq 0 ]; then rc=1; fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

command -v jq >/dev/null 2>&1 || { echo "✗ l4-declarations: jq が無い（ADR-084 決定 2 の必須ツール。skip にしない）" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "✗ l4-declarations: git が無い（旧名の残存を走査できない。skip にしない）" >&2; exit 1; }
if [ ! -f "$SURFACE_LIB" ] || [ ! -r "$SURFACE_LIB" ]; then
  echo "✗ l4-declarations: 公開面の共有実装が無い: $SURFACE_LIB" >&2
  exit 1
fi
# shellcheck source=../lib/public-surface.sh
. "$SURFACE_LIB"

# 空白区切りの集合に語があるか
in_set() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }
# 改行区切りの集合 2 つの差（$1 にあって $2 に無いもの）を空白区切りで出す
set_minus() {
  comm -23 <(printf '%s\n' $1 | LC_ALL=C sort -u) <(printf '%s\n' $2 | LC_ALL=C sort -u) | sed '/^$/d' | tr '\n' ' ' | sed 's/ *$//'
}
# x.y.z（後ろの -pre 等は無視）を比べる。$1 >= $2 なら rc 0
version_ge() {
  local a b a1 a2 a3 b1 b2 b3
  a="${1%%-*}" b="${2%%-*}"
  a1="${a%%.*}" a="${a#*.}" a2="${a%%.*}" a3="${a#*.}"
  b1="${b%%.*}" b="${b#*.}" b2="${b%%.*}" b3="${b#*.}"
  a1="${a1:-0}" a2="${a2:-0}" a3="${a3:-0}" b1="${b1:-0}" b2="${b2:-0}" b3="${b3:-0}"
  [ "$a1" -gt "$b1" ] && return 0
  [ "$a1" -lt "$b1" ] && return 1
  [ "$a2" -gt "$b2" ] && return 0
  [ "$a2" -lt "$b2" ] && return 1
  [ "$a3" -ge "$b3" ]
}
# 鍵 → ACK の名前（FF_ + 大文字・_ 区切り + _ACK）
ack_name() { printf 'FF_%s_ACK\n' "$(printf '%s' "$1" | tr 'abcdefghijklmnopqrstuvwxyz-' 'ABCDEFGHIJKLMNOPQRSTUVWXYZ_')"; }

echo "== l4-declarations =="

# ---- N0: 名簿の前提 -------------------------------------------------------------
if [ ! -f "$TSV" ] || [ ! -r "$TSV" ] || [ ! -s "$TSV" ]; then
  bad "N0: 名簿が無いか読めないか 0 バイト（検査不成立）: ${TSV#"$ROOT"/}"
  exit 1
fi
n0_header="$(awk '!/^#/ && NF > 0 { print; exit }' "$TSV")"
if [ "$n0_header" != "$TSV_HEADER" ]; then
  bad "N0: 名簿の見出し行が列 key / kind / owner / covers / legacy / legacy_value_rule / remove_after（タブ区切り）でない: ${n0_header:-（無し）}"
  exit 1
fi
n0_shape="$(awk -F'\t' '
  /^#/ || NF == 0 { next }
  !seen_header { seen_header = 1; next }
  { rows++ }
  NF != 7 { printf "%d 行目: 列が %d（7 列でない）\n", NR, NF; next }
  { for (i = 1; i <= 7; i++) if ($i == "" || $i ~ /[ ]/) { printf "%d 行目: %d 列目が空か空白を含む（空の欄は - と書く）\n", NR, i; next } }
  END { if (rows == 0) print "データ行が 0 件" }
' "$TSV")"
if [ -n "$n0_shape" ]; then
  bad "N0: 名簿の書式違反（検査不成立）: $(printf '%s' "$n0_shape" | tr '\n' ';')"
  exit 1
fi
ok "N0: 名簿を読める（見出し 1 行・タブ区切り 7 列・空の欄なし・データ行 1 件以上）"

# 名簿を並列の配列へ（bash 3.2 の添字配列）
R_KEY=() R_KIND=() R_OWNER=() R_COVERS=() R_LEGACY=() R_RULE=() R_RA=()
n0_first=1
while IFS=$'\t' read -r c1 c2 c3 c4 c5 c6 c7; do
  case "$c1" in '' | '#'*) continue ;; esac
  if [ "$n0_first" -eq 1 ]; then n0_first=0; continue; fi
  R_KEY+=("$c1") R_KIND+=("$c2") R_OWNER+=("$c3") R_COVERS+=("$c4") R_LEGACY+=("$c5") R_RULE+=("$c6") R_RA+=("$c7")
done < "$TSV"
N_ROWS="${#R_KEY[@]}"
SKIP_KEYS="" ACK_KEYS="" ALL_KEYS="" LEGACY_SET=""
i=0
while [ "$i" -lt "$N_ROWS" ]; do
  case "${R_KIND[$i]}" in
    skip) SKIP_KEYS="$SKIP_KEYS ${R_KEY[$i]}" ;;
    ack) ACK_KEYS="$ACK_KEYS ${R_KEY[$i]}" ;;
  esac
  in_set "${R_KEY[$i]}" "$ALL_KEYS" || ALL_KEYS="$ALL_KEYS ${R_KEY[$i]}"
  [ "${R_LEGACY[$i]}" = "-" ] || LEGACY_SET="$LEGACY_SET ${R_LEGACY[$i]}"
  i=$((i + 1))
done
ACK_NAMES=""
for k in $ACK_KEYS; do ACK_NAMES="$ACK_NAMES $(ack_name "$k")"; done
# ACK の別名の組（旧名=新しい名前）: kind=ack の legacy と、skip-legacy の行が指す同じ鍵の kind=skip の旧名
ACK_ALIAS_PAIRS=""
i=0
while [ "$i" -lt "$N_ROWS" ]; do
  if [ "${R_KIND[$i]}" = "ack" ]; then
    if [ "${R_LEGACY[$i]}" != "-" ]; then
      ACK_ALIAS_PAIRS="$ACK_ALIAS_PAIRS ${R_LEGACY[$i]}=$(ack_name "${R_KEY[$i]}")"
    elif [ "${R_RULE[$i]}" = "skip-legacy" ]; then
      j=0
      while [ "$j" -lt "$N_ROWS" ]; do
        if [ "${R_KEY[$j]}" = "${R_KEY[$i]}" ] && [ "${R_KIND[$j]}" = "skip" ] && [ "${R_LEGACY[$j]}" != "-" ]; then
          ACK_ALIAS_PAIRS="$ACK_ALIAS_PAIRS ${R_LEGACY[$j]}=$(ack_name "${R_KEY[$i]}")"
        fi
        j=$((j + 1))
      done
    fi
  fi
  i=$((i + 1))
done
echo "  ℹ️  名簿: ${N_ROWS} 行（kind=skip $(printf '%s\n' $SKIP_KEYS | grep -c .) / kind=ack $(printf '%s\n' $ACK_KEYS | grep -c .) / 旧名 $(printf '%s\n' $LEGACY_SET | grep -c .)）"

# ---- N1: 名簿の形 ---------------------------------------------------------------
n1_bad=""
n1_pairs=""
i=0
while [ "$i" -lt "$N_ROWS" ]; do
  k="${R_KEY[$i]}" kind="${R_KIND[$i]}" lg="${R_LEGACY[$i]}" rule="${R_RULE[$i]}" ra="${R_RA[$i]}"
  case "$kind" in skip | ack) : ;; *) n1_bad="$n1_bad / ${k}: kind が skip / ack でない（${kind}）" ;; esac
  case "$k" in
    *[!abcdefghijklmnopqrstuvwxyz0123456789-]* | -* | *- | *--*) n1_bad="$n1_bad / ${k}: 鍵が小文字のケバブでない" ;;
  esac
  if in_set "${k}/${kind}" "$n1_pairs"; then n1_bad="$n1_bad / ${k}: (key, kind) が重複"; fi
  n1_pairs="$n1_pairs ${k}/${kind}"
  if [ "$lg" = "-" ]; then
    case "$rule" in
      -) : ;;
      skip-legacy)
        [ "$kind" = "ack" ] || n1_bad="$n1_bad / ${k}: skip-legacy は kind=ack の行だけに書く"
        n1_sl="" j=0
        while [ "$j" -lt "$N_ROWS" ]; do
          if [ "${R_KEY[$j]}" = "$k" ] && [ "${R_KIND[$j]}" = "skip" ] && [ "${R_LEGACY[$j]}" != "-" ]; then n1_sl=1; fi
          j=$((j + 1))
        done
        [ -n "$n1_sl" ] || n1_bad="$n1_bad / ${k}: skip-legacy なのに同じ鍵の kind=skip の行に旧名が無い"
        ;;
      *) n1_bad="$n1_bad / ${k}: 旧名が無いのに legacy_value_rule が - / skip-legacy でない（${rule}）" ;;
    esac
  else
    case "$lg" in
      FF_*) case "$lg" in *[!ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_]*) n1_bad="$n1_bad / ${k}: 旧名の形が違う（${lg}）" ;; esac ;;
      *) n1_bad="$n1_bad / ${k}: 旧名が FF_ で始まらない（${lg}）" ;;
    esac
    case "$rule" in eq1 | nonempty) : ;; *) n1_bad="$n1_bad / ${k}: legacy_value_rule が eq1 / nonempty でない（${rule}）" ;; esac
  fi
  case "$ra" in
    [0-9]*.[0-9]*.[0-9]*) case "$ra" in *[!0-9.]*) n1_bad="$n1_bad / ${k}: remove_after が x.y.z でない（${ra}）" ;; esac ;;
    *) n1_bad="$n1_bad / ${k}: remove_after が x.y.z でない（${ra}）" ;;
  esac
  if [ "${R_COVERS[$i]}" != "-" ]; then
    [ "$kind" = "skip" ] || n1_bad="$n1_bad / ${k}: covers は kind=skip の行だけに書く"
    for c in $(printf '%s' "${R_COVERS[$i]}" | tr ',' ' '); do
      in_set "$c" "$ALL_KEYS" || n1_bad="$n1_bad / ${k}: covers の ${c} が名簿に無い"
      [ "$c" != "$k" ] || n1_bad="$n1_bad / ${k}: covers に自分の鍵がある"
    done
  fi
  for o in $(printf '%s' "${R_OWNER[$i]}" | tr ',' ' '); do
    [ -f "$PLUGIN/$o" ] || n1_bad="$n1_bad / ${k}: owner が実在しない（${o}）"
  done
  i=$((i + 1))
done
n1_dup="$(printf '%s\n' $LEGACY_SET | LC_ALL=C sort | uniq -d | tr '\n' ' ' | sed 's/ *$//')"
[ -z "$n1_dup" ] || n1_bad="$n1_bad / 旧名が複数の行にある: ${n1_dup}"
if [ -z "$SKIP_KEYS" ]; then n1_bad="$n1_bad / kind=skip の行が 0 件"; fi
if [ -z "$ACK_KEYS" ]; then n1_bad="$n1_bad / kind=ack の行が 0 件"; fi
if [ -z "$n1_bad" ]; then ok "N1: 名簿の形（kind・鍵の綴り・重複・旧名・値の規則・期限・covers・owner）"; else bad "N1: 名簿の形の違反${n1_bad}"; fi

# ---- N2 / N3: 呼び出し ------------------------------------------------------------
# 1 行に書いた `ff_l4_skipped <鍵> <旧名> [nonempty]` を字句で拾う。コメント行（先頭が #）・関数の定義
# （直後が `(`）・`declare -F` / `type` / `command -v` の後ろに置いた名前は呼び出しに数えない。
CALLS="$WORK/calls.tsv"
: > "$CALLS"
for d in "$PLUGIN/hooks" "$PLUGIN/scripts" "$PLUGIN/tests/lib"; do
  [ -d "$d" ] || continue
  grep -rnI 'ff_l4_skipped' "$d" 2>/dev/null | { grep -vF "${LIB}:" || true; } >> "$CALLS.raw" || true
done
[ -f "$CALLS.raw" ] || : > "$CALLS.raw"
awk -v q="'" '
  {
    # path:line:text（path に : を含まない前提。リポジトリの配布物はこの形）
    p = index($0, ":"); path = substr($0, 1, p - 1); rest = substr($0, p + 1)
    p2 = index(rest, ":"); line = substr(rest, 1, p2 - 1); text = substr(rest, p2 + 1)
    t = text; sub(/^[ \t]+/, "", t)
    if (t ~ /^#/) next
    off = 0
    while ((i = index(substr(text, off + 1), "ff_l4_skipped")) > 0) {
      pos = off + i; off = pos
      pre = (pos > 1) ? substr(text, pos - 1, 1) : ""
      post = substr(text, pos + 13, 1)
      if (pre ~ /[A-Za-z0-9_]/ || post != " " && post != "\t") continue
      before = substr(text, 1, pos - 1); sub(/[ \t]+$/, "", before)
      n = split(before, bw, /[ \t]+/); last = (n > 0) ? bw[n] : ""
      if (last == "-F" || last == "-f" || last == "-v" || last == "type" || last == "unset" || last == "-t") continue
      args = substr(text, pos + 14); sub(/^[ \t]+/, "", args)
      m = split(args, a, /[ \t]+/)
      k = (m >= 1) ? a[1] : ""; lg = (m >= 2) ? a[2] : ""; r = (m >= 3) ? a[3] : ""
      gsub(/[;)]+$/, "", k); gsub(/[;)]+$/, "", lg); gsub(/[;)]+$/, "", r)
      if (lg ~ /^(&&|\|\||;|then|>|<|2>)/) { lg = ""; r = "" }
      if (r != "nonempty" && r != (q "nonempty" q) && r != ("\"nonempty\"")) r = ""
      printf "%s\t%s\t%s\t%s\t%s\n", path, line, (k == "" ? "-" : k), (lg == "" ? "-" : lg), (r == "" ? "-" : r)
    }
  }
' "$CALLS.raw" > "$CALLS"
unquote() { # 単一 / 二重引用を外す。変数・置換を含むなら空文字を返して rc 1
  local v="$1"
  case "$v" in
    \'*\') v="${v#\'}"; v="${v%\'}" ;;
    \"*\") v="${v#\"}"; v="${v%\"}" ;;
  esac
  case "$v" in *'$'* | *'`'* | *\\*) return 1 ;; esac
  printf '%s' "$v"
}
call_keys="" n2_var="" n2_shape="" n3_bad=""
while IFS=$'\t' read -r cpath cline ckey clegacy crule; do
  [ -n "$cpath" ] || continue
  rel="${cpath#"$ROOT"/}:${cline}"
  if ! k="$(unquote "$ckey")"; then n2_var="$n2_var ${rel}"; continue; fi
  case "$k" in
    '' | - | *[!abcdefghijklmnopqrstuvwxyz0123456789-]*) n2_shape="$n2_shape ${rel}（${ckey}）"; continue ;;
  esac
  in_set "$k" "$call_keys" || call_keys="$call_keys $k"
  # N3: 旧名と値の規則
  want_lg="" want_rule=""
  i=0
  while [ "$i" -lt "$N_ROWS" ]; do
    if [ "${R_KEY[$i]}" = "$k" ] && [ "${R_KIND[$i]}" = "skip" ]; then want_lg="${R_LEGACY[$i]}"; want_rule="${R_RULE[$i]}"; break; fi
    i=$((i + 1))
  done
  [ -n "$want_lg" ] || continue # 名簿に無い鍵は N2 が名指す
  if [ "$clegacy" = "-" ]; then
    got_lg="-"
  elif ! got_lg="$(unquote "$clegacy")"; then
    n3_bad="$n3_bad / ${rel}: 旧名を変数で渡している（${clegacy}）"; continue
  fi
  [ "$got_lg" = "$want_lg" ] || n3_bad="$n3_bad / ${rel}: 鍵 ${k} の旧名が ${got_lg}（名簿は ${want_lg}）"
  got_rule="-"
  [ "$crule" = "-" ] || got_rule="nonempty"
  if [ "$want_rule" = "nonempty" ] && [ "$got_rule" != "nonempty" ]; then
    n3_bad="$n3_bad / ${rel}: 鍵 ${k} は legacy_value_rule=nonempty なのに第 3 引数 nonempty が無い"
  elif [ "$want_rule" != "nonempty" ] && [ "$got_rule" = "nonempty" ]; then
    n3_bad="$n3_bad / ${rel}: 鍵 ${k} は legacy_value_rule=${want_rule} なのに第 3 引数 nonempty がある"
  fi
done < "$CALLS"
n2_missing="$(set_minus "$SKIP_KEYS" "$call_keys")"
n2_unknown="$(set_minus "$call_keys" "$SKIP_KEYS")"
n2_msg=""
[ -z "$n2_var" ] || n2_msg="$n2_msg / 鍵を変数で渡している呼び出し:${n2_var}"
[ -z "$n2_shape" ] || n2_msg="$n2_msg / 鍵がリテラルの小文字のケバブでない呼び出し:${n2_shape}"
[ -z "$n2_unknown" ] || n2_msg="$n2_msg / 名簿の kind=skip に無い鍵を呼んでいる: ${n2_unknown}"
[ -z "$n2_missing" ] || n2_msg="$n2_msg / 名簿の kind=skip にあるのに ff_l4_skipped で呼ばれていない鍵: ${n2_missing}"
if [ -z "$n2_msg" ]; then ok "N2: 呼び出しの鍵の集合 = 名簿の kind=skip の鍵の集合（$(printf '%s\n' $call_keys | grep -c .) 件）"; else bad "N2: 呼び出しの鍵と名簿の不一致${n2_msg}"; fi
if [ -z "$n3_bad" ]; then ok "N3: 呼び出しの旧名と値の規則が名簿の legacy / legacy_value_rule と一致"; else bad "N3: 呼び出しの旧名の不一致${n3_bad}"; fi

# ---- N4: PUBLIC-SURFACE 4-3 ------------------------------------------------------
if [ ! -f "$SURFACE_DOC" ] || [ ! -r "$SURFACE_DOC" ]; then
  bad "N4: PUBLIC-SURFACE.md が無いか読めない: ${SURFACE_DOC#"$ROOT"/}"
else
  n4_keys="$(ff_surface_l4_keys "$SURFACE_DOC" | tr '\n' ' ')"
  if [ -z "${n4_keys// /}" ]; then
    bad "N4: PUBLIC-SURFACE.md の「### 4-3.」の表から鍵を 1 件も抽出できない（節が無いか、表の先頭セルが \`<鍵>\` でない）"
  else
    n4_missing="$(set_minus "$SKIP_KEYS" "$n4_keys")" n4_extra="$(set_minus "$n4_keys" "$SKIP_KEYS")"
    if [ -z "$n4_missing$n4_extra" ]; then ok "N4: PUBLIC-SURFACE 4-3 の鍵 = 名簿の kind=skip の鍵"; else bad "N4: PUBLIC-SURFACE 4-3 と名簿の不一致（4-3 に無い: ${n4_missing:-なし} / 名簿に無い: ${n4_extra:-なし}）"; fi
  fi
fi

# ---- N5: oss README の鍵の表 ----------------------------------------------------------
if [ ! -f "$OSS_README" ] || [ ! -r "$OSS_README" ]; then
  bad "N5: ${OSS_README_REL} が無いか読めない"
else
  n5_keys="$(awk '
    /^```/ { fence = !fence; next }
    fence { next }
    /^\|[ \t]*鍵[ \t]*\|/ { intable = 1; next }
    intable && /^\|/ { if (match($0, /^\|[ \t]*`[a-z0-9]+(-[a-z0-9]+)*`/)) { s = substr($0, RSTART, RLENGTH); sub(/^\|[ \t]*`/, "", s); sub(/`$/, "", s); print s } ; next }
    intable { intable = 0 }
  ' "$OSS_README" | LC_ALL=C sort -u | tr '\n' ' ')"
  if [ -z "${n5_keys// /}" ]; then
    bad "N5: ${OSS_README_REL} に鍵の表（見出しの先頭セルが 鍵 の表）が無いか、鍵を 1 件も抽出できない"
  else
    n5_missing="$(set_minus "$SKIP_KEYS" "$n5_keys")" n5_extra="$(set_minus "$n5_keys" "$SKIP_KEYS")"
    if [ -z "$n5_missing$n5_extra" ]; then ok "N5: 公開 README（${OSS_README_REL}）の鍵の表 = 名簿の kind=skip の鍵"; else bad "N5: oss README の鍵の表と名簿の不一致（表に無い: ${n5_missing:-なし} / 名簿に無い: ${n5_extra:-なし}）"; fi
  fi
fi

# ---- N6: ACK の型 ---------------------------------------------------------------
n6_src=()
for d in "$PLUGIN/hooks" "$PLUGIN/scripts" "$PLUGIN/tests/lib" "$PLUGIN/tests/run-all.sh" "$PLUGIN/mcp/src"; do
  [ -e "$d" ] && n6_src+=("$d")
done
n6_found=""
if [ "${#n6_src[@]}" -gt 0 ]; then
  n6_found="$(grep -rhoIE 'FF_[A-Z0-9_]*_ACK[A-Za-z0-9_]*' "${n6_src[@]}" 2>/dev/null | { grep -E '_ACK$' || true; } | LC_ALL=C sort -u | tr '\n' ' ')"
fi
if [ -z "${n6_found// /}" ]; then
  bad "N6: 配布実行物から FF_<…>_ACK の名前を 1 件も拾えない（走査対象が無いか、読めない）"
else
  n6_unknown="$(set_minus "$n6_found" "$ACK_NAMES")"
  if [ -z "$n6_unknown" ]; then ok "N6: 配布実行物の FF_<…>_ACK はどれも名簿の kind=ack にある（$(printf '%s\n' $n6_found | grep -c .) 件）"; else bad "N6: 名簿の kind=ack に無い ACK の名前が配布実行物にある: ${n6_unknown}"; fi
fi

# ---- N7: 旧名の残存 --------------------------------------------------------------
# 許可した場所（リポジトリ root 相対）。子の作業で別名を試す試験を足すときは、ここへ足す。
allowed_path() {
  case "$1" in
    plugins/ff-dev-toolkit/scripts/lib/l4-declarations.tsv | plugins/ff-dev-toolkit/scripts/lib/l4-declarations.sh) return 0 ;;
    CHANGELOG.md | */CHANGELOG.md | changelog.d/*) return 0 ;;
    docs/08-knowledge/* | docs/06-reference/DECISIONS.md) return 0 ;;
    # 過去の実測・実験の記録（書き換えると記録が偽になる）
    .probe/* | docs/04-quality/jev-lang-ab/*) return 0 ;;
    plugins/ff-dev-toolkit/tests/l4-declarations/* | plugins/ff-dev-toolkit/tests/l4-declarations-selftest/*) return 0 ;;
    plugins/ff-media-toolkit/scripts/lib/codex-version.sh | plugins/ff-media-toolkit/tests/codex-update/*) return 0 ;;
  esac
  return 1
}
# 行で許可する場所（hooks/・scripts/・tests/lib/・.claude/hooks/ の非コメント行）。旧名は次の形の中に
# 現れるときだけ許し、その形を取り除いた残りに旧名が 1 つでもあれば許さない（案内文・deny 文に新しい
# 名前と旧名を並べて書く形は、どの形にも当たらないので赤のまま）:
#   (a) ff_l4_skipped の呼び出しの第 2 引数: `ff_l4_skipped '<鍵>' '<旧名>'`
#   (b) ACK の別名（ACK_ALIAS_PAIRS の組）を、同じ行の新しい名前と並べて読む 3 つの形
#       - case の選択肢: `<新しい名前>=1 | <旧名>=1)`（`=1* | <旧名>=1*)` も同じ）
#       - 値の判定: `[ "${<旧名>:-0}" = "1" ]`
#       - 名前が `_note` で終わる変数への代入の中の `旧名 <旧名>=1`（旧名を読んだ回の注記の文）
allowed_line() { # <path> <text>
  local t="$2" s pair lg nw shape
  t="${t#"${t%%[![:space:]]*}"}"
  case "$t" in '#'*) return 1 ;; esac
  case "$1" in
    plugins/ff-dev-toolkit/hooks/* | plugins/ff-dev-toolkit/scripts/* | plugins/ff-dev-toolkit/tests/lib/* | .claude/hooks/*) ;;
    *) return 1 ;;
  esac
  s="$t"
  case "$s" in
    *'ff_l4_skipped '*) s="$(sed -E "s/ff_l4_skipped '[a-z0-9-]+' '(${n7_alt})'//g" <<< "$s")" ;;
  esac
  for pair in $ACK_ALIAS_PAIRS; do
    lg="${pair%%=*}" nw="${pair#*=}"
    case "$s" in *"$nw"*) ;; *) continue ;; esac
    shape="$nw=1 | $lg=1)"; s="${s//"$shape"/}"
    shape="$nw=1* | $lg=1*)"; s="${s//"$shape"/}"
    shape='[ "${'"$lg"':-0}" = "1" ]'; s="${s//"$shape"/}"
    case "$s" in *'_note='*"旧名 $lg=1"*) shape="旧名 $lg=1"; s="${s//"$shape"/}" ;; esac
  done
  [ "$s" != "$t" ] || return 1
  grep -qE "(^|[^A-Za-z0-9_])(${n7_alt})([^A-Za-z0-9_]|\$)" <<< "$s" && return 1
  return 0
}
if [ -z "${LEGACY_SET// /}" ]; then
  bad "N7: 名簿の legacy 列の集合が空（旧名の残存を数える前に赤。別名を撤去したら ADR-087 の手順でこの検査を外す）"
else
  n7_alt="$(printf '%s\n' $LEGACY_SET | LC_ALL=C sort -u | tr '\n' '|' | sed 's/|$//')"
  n7_rc=0
  git -C "$ROOT" grep --no-index --exclude-standard -nIE "(^|[^A-Za-z0-9_])(${n7_alt})([^A-Za-z0-9_]|\$)" > "$WORK/legacy-hits.txt" 2>"$WORK/legacy-hits.err" || n7_rc=$?
  if [ "$n7_rc" -gt 1 ]; then
    bad "N7: 旧名の走査が失敗した（git grep rc=${n7_rc}。検査不成立）: $(head -n 3 "$WORK/legacy-hits.err" | tr '\n' ' ')"
  elif ! grep -qF 'plugins/ff-dev-toolkit/scripts/lib/l4-declarations.tsv:' "$WORK/legacy-hits.txt"; then
    # 名簿は旧名を必ず持つので、名簿に 1 件も当たらない走査は届いていない（.gitignore・git の不調など）。0 件を緑にしない
    bad "N7: 旧名の走査が名簿 scripts/lib/l4-declarations.tsv に 1 件も当たらない（走査の空振り。git grep rc=${n7_rc}。検査不成立）"
  else
    # PUBLIC-SURFACE.md の許可した節（4-2-2 と §破壊的変更の記録）の行番号
    surface_ok_lines=" "
    if [ -f "$SURFACE_DOC" ]; then
      surface_ok_lines=" $(awk '
        /^#### 4-2-2\./ { s = 1; next }
        /^## 破壊的変更の記録/ { s = 1; next }
        /^## / || /^### / || /^#### / { s = 0 }
        s { printf "%d ", NR }
      ' "$SURFACE_DOC")"
    fi
    n7_out=0 n7_list="" n7_cl_file="" n7_cl_from="" n7_cl_to=""
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      hp="${hit%%:*}" hr="${hit#*:}"
      hl="${hr%%:*}" ht="${hr#*:}"
      allowed_path "$hp" && continue
      allowed_line "$hp" "$ht" && continue
      # docs/ の Markdown の「## Changelog」節（次の「## 」見出しの前まで）は過去の版の記録（各 CHANGELOG と同じ扱い）
      case "$hp" in
        docs/*.md)
          if [ "$hp" != "$n7_cl_file" ]; then
            n7_cl_file="$hp"
            n7_cl_from="" n7_cl_to=""
            read -r n7_cl_from n7_cl_to <<< "$(awk '
              /^```/ { fence = !fence }
              fence { next }
              s && /^## / { print s, NR; done = 1; exit }
              !s && /^## Changelog[ \t]*$/ { s = NR }
              END { if (s && !done) print s, 0 }
            ' "$ROOT/$hp" 2>/dev/null)" || true
          fi
          if [ -n "$n7_cl_from" ] && [ "$hl" -gt "$n7_cl_from" ] && { [ "$n7_cl_to" -eq 0 ] || [ "$hl" -lt "$n7_cl_to" ]; }; then continue; fi
          ;;
      esac
      if [ "$hp" = "plugins/ff-dev-toolkit/PUBLIC-SURFACE.md" ]; then
        case "$surface_ok_lines" in *" $hl "*) continue ;; esac
      fi
      n7_out=$((n7_out + 1))
      [ "$n7_out" -le 30 ] && n7_list="${n7_list}
      ${hp}:${hl}"
    done < "$WORK/legacy-hits.txt"
    if [ "$n7_out" -eq 0 ]; then
      ok "N7: 旧名（$(printf '%s\n' $LEGACY_SET | grep -c .) 件）は許可した場所の外に 0 件"
    else
      bad "N7: 旧名が許可した場所の外に ${n7_out} 行ある（先頭 30 行）:${n7_list}"
    fi
  fi
fi

# ---- N8: 期限 -----------------------------------------------------------------
n8_version="$(jq -r '.version // empty' "$PLUGIN_JSON" 2>/dev/null || true)"
case "$n8_version" in
  [0-9]*.[0-9]*.[0-9]*)
    n8_bad=""
    i=0
    while [ "$i" -lt "$N_ROWS" ]; do
      if [ "${R_LEGACY[$i]}" != "-" ] && version_ge "$n8_version" "${R_RA[$i]}"; then
        n8_bad="$n8_bad ${R_KEY[$i]}/${R_KIND[$i]}（${R_LEGACY[$i]}、remove_after ${R_RA[$i]}）"
      fi
      i=$((i + 1))
    done
    if [ -z "$n8_bad" ]; then ok "N8: plugin.json の version ${n8_version} は、旧名が残る行のどの remove_after にも届いていない"; else bad "N8: version ${n8_version} が remove_after 以上なのに旧名が残っている:${n8_bad}"; fi
    ;;
  *) bad "N8: plugin.json の version を読めない（${n8_version:-空}）: ${PLUGIN_JSON#"$ROOT"/}" ;;
esac

# ---- N9: 試験の隔離の既定の unset ----------------------------------------------------
n9_required="FF_DEV_TOOLKIT_SKIP $ACK_NAMES"
for n9_file in "$SBC" "$AEI"; do
  n9_rel="${n9_file#"$ROOT"/}"
  if [ ! -f "$n9_file" ] || [ ! -r "$n9_file" ]; then bad "N9: ${n9_rel} が無いか読めない"; continue; fi
  n9_marks="$(awk '/l4-default-unset:begin/ { b++ } /l4-default-unset:end/ { e++ } END { printf "%d %d", b, e }' "$n9_file")"
  if [ "$n9_marks" != "1 1" ]; then bad "N9: ${n9_rel} に印 l4-default-unset:begin / :end が 1 組だけある形でない（begin / end の数: ${n9_marks}）"; continue; fi
  n9_names="$(awk '/l4-default-unset:begin/ { s = 1; next } /l4-default-unset:end/ { s = 0 } s { sub(/(^|[ \t])#.*$/, ""); print }' "$n9_file" | { grep -oE 'FF_[A-Z0-9_]+' || true; } | LC_ALL=C sort -u | tr '\n' ' ')"
  n9_missing="$(set_minus "$n9_required" "$n9_names")"
  if [ -z "$n9_missing" ]; then ok "N9: ${n9_rel} の既定の unset に FF_DEV_TOOLKIT_SKIP と名簿の ACK（$(printf '%s\n' $ACK_NAMES | grep -c .) 名）が全部ある"; else bad "N9: ${n9_rel} の既定の unset に無い名前: ${n9_missing}"; fi
done

# ---- N13: 共通関数の読み込みの形 ------------------------------------------------------
# macOS の bash 3.2 は set -e の下で `.` が対象を見つけられないと、`||` の中でもシェルを止める（stderr を
# 捨てていると無言の rc 1）。lib を読めない配置で set -e の呼び出し側（multi-agent.sh など）が落ちないよう、
# 読む行は同じ行で先に [ -r ] で確かめる形に揃える。Linux の bash 5 では起きないので振る舞いではなく形で見る。
# 数えるのは、lib の名前 l4-declarations.sh を含む非コメント行の全部（共通関数そのものを除く）。読み込みの形を
# 字句で探すと、変数経由（`L4_LIB=…/l4-declarations.sh` の次の行で `. "$L4_LIB"`）や引用の無い形を見落とすので、
# 名前を書いた行は決まった 1 行の形だけにする（変数へ入れた行も、その形でないので赤）。
n13_dirs=()
for n13_d in "$PLUGIN/hooks" "$PLUGIN/scripts" "$PLUGIN/tests/lib" "$ROOT/.claude/hooks"; do
  [ -d "$n13_d" ] && n13_dirs+=("$n13_d")
done
n13_n=0 n13_bad=""
n13_canon='\{ \[ -r "[^"]*l4-declarations\.sh" \] && \. "[^"]*l4-declarations\.sh"; \} 2>/dev/null'
if [ "${#n13_dirs[@]}" -gt 0 ]; then
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    hp="${hit%%:*}" hr="${hit#*:}"
    hl="${hr%%:*}" ht="${hr#*:}"
    ht="${ht#"${ht%%[![:space:]]*}"}"
    case "$ht" in '#'*) continue ;; esac
    case "$hp" in */scripts/lib/l4-declarations.sh) continue ;; esac
    n13_n=$((n13_n + 1))
    # 決まった形の断片を 1 つ取り除いた残りに lib の名前が残る行（同じ行に確かめない `.` を足した形、決まった形を
    # 行末のコメントに書いただけの形）も赤にする。断片が無い行は、取り除いても変わらないので赤
    n13_rest="$(sed -E "s#${n13_canon}##" <<< "$ht")"
    case "$n13_rest" in
      "$ht" | *l4-declarations.sh*) n13_bad="${n13_bad}
      ${hp#"$ROOT"/}:${hl}" ;;
    esac
  done < <(grep -rnIF --include='*.sh' 'l4-declarations.sh' "${n13_dirs[@]}" 2>/dev/null)
fi
if [ "$n13_n" -eq 0 ]; then
  bad "N13: hooks/・scripts/・tests/lib/・.claude/hooks/ に共通関数 l4-declarations.sh を読む行が 1 件も無い（走査の空振り。検査不成立）"
elif [ -z "$n13_bad" ]; then
  ok "N13: 共通関数を読む ${n13_n} 行は、どれも同じ行で先に [ -r ] で確かめる形"
else
  bad "N13: 共通関数を読む前に [ -r ] で確かめていない行（bash 3.2 で set -e の呼び出し側が、lib を読めない配置で無言の rc 1 になる）。{ [ -r \"<lib>\" ] && . \"<lib>\"; } 2>/dev/null || ff_l4_skipped() { return 1; } の形にする:${n13_bad}"
fi

# ---- U: 共通関数 ----------------------------------------------------------------
UB="${BASH:-bash}"
[ -x /bin/bash ] && UB=/bin/bash
if [ ! -f "$LIB" ] || [ ! -r "$LIB" ] || [ ! -s "$LIB" ]; then
  bad "U1: 共通関数が無いか読めないか 0 バイト: ${LIB#"$ROOT"/}"
elif ! "$UB" -c '. "$1" && declare -F ff_l4_skipped >/dev/null' _ "$LIB" 2>/dev/null; then
  bad "U1: 共通関数を source しても ff_l4_skipped が定義されない"
else
  # 表の 1 行: <期待する rc> <環境の代入 …> -- <引数 …>
  u1_bad=""
  u1_case() {
    local exp="$1" rc=0
    local envs=()
    shift
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    env -u FF_DEV_TOOLKIT_SKIP -u FF_DEV_TOOLKIT_SKIP_ZSH_GLOB_GUARD -u FF_DEV_TOOLKIT_SKIP_ZSH_EXPANSION_GUARD \
      -u FF_DEV_TOOLKIT_SKIP_AUTO_UPDATE ${envs[@]+"${envs[@]}"} \
      "$UB" -c 'set -u; . "$1"; shift; ff_l4_skipped "$@"' _ "$LIB" "$@" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq "$exp" ] || u1_bad="$u1_bad / [${envs[*]-（宣言なし）}] ff_l4_skipped $* → rc ${rc}（期待 ${exp}）"
  }
  u1_case 0 FF_DEV_TOOLKIT_SKIP=zsh-glob -- zsh-glob FF_DEV_TOOLKIT_SKIP_ZSH_GLOB_GUARD
  u1_case 0 FF_DEV_TOOLKIT_SKIP=zsh-glob,update-check -- zsh-glob FF_DEV_TOOLKIT_SKIP_ZSH_GLOB_GUARD
  u1_case 1 FF_DEV_TOOLKIT_SKIP=zsh -- zsh-glob FF_DEV_TOOLKIT_SKIP_ZSH_GLOB_GUARD
  u1_case 1 FF_DEV_TOOLKIT_SKIP=ZSH_GLOB -- zsh-glob FF_DEV_TOOLKIT_SKIP_ZSH_GLOB_GUARD
  u1_case 1 'FF_DEV_TOOLKIT_SKIP=zsh-glob update-check' -- zsh-glob FF_DEV_TOOLKIT_SKIP_ZSH_GLOB_GUARD
  u1_case 1 FF_DEV_TOOLKIT_SKIP=zsh-glob, -- zsh-glob FF_DEV_TOOLKIT_SKIP_ZSH_GLOB_GUARD
  u1_case 1 FF_DEV_TOOLKIT_SKIP=,zsh-glob -- zsh-glob FF_DEV_TOOLKIT_SKIP_ZSH_GLOB_GUARD
  u1_case 1 FF_DEV_TOOLKIT_SKIP=zsh-glob,,update-check -- zsh-glob FF_DEV_TOOLKIT_SKIP_ZSH_GLOB_GUARD
  u1_case 1 FF_DEV_TOOLKIT_SKIP=zsh-glob,UPDATE_CHECK -- zsh-glob FF_DEV_TOOLKIT_SKIP_ZSH_GLOB_GUARD
  u1_case 0 FF_DEV_TOOLKIT_SKIP_ZSH_GLOB_GUARD=1 -- zsh-glob FF_DEV_TOOLKIT_SKIP_ZSH_GLOB_GUARD
  u1_case 1 FF_DEV_TOOLKIT_SKIP_ZSH_GLOB_GUARD=0 -- zsh-glob FF_DEV_TOOLKIT_SKIP_ZSH_GLOB_GUARD
  u1_case 1 -- zsh-glob FF_DEV_TOOLKIT_SKIP_ZSH_GLOB_GUARD
  u1_case 0 FF_DEV_TOOLKIT_SKIP=zsh-glob -- zsh-expansion FF_DEV_TOOLKIT_SKIP_ZSH_EXPANSION_GUARD
  u1_case 1 FF_DEV_TOOLKIT_SKIP=zsh-expansion -- zsh-glob FF_DEV_TOOLKIT_SKIP_ZSH_GLOB_GUARD
  u1_case 0 FF_DEV_TOOLKIT_SKIP_AUTO_UPDATE=0 -- auto-update FF_DEV_TOOLKIT_SKIP_AUTO_UPDATE nonempty
  if [ -z "$u1_bad" ]; then ok "U1: 共通関数の終了コードの表（15 行。${UB}）"; else bad "U1: 共通関数の終了コードの違反${u1_bad}"; fi

  # U2: 両方とも未設定の 1 回の呼び出し
  u2_rc=0
  env -u FF_DEV_TOOLKIT_SKIP -u FF_DEV_TOOLKIT_SKIP_ZSH_GLOB_GUARD "$UB" -c \
    '. "$1"; PS4="+[\$BASH_SUBSHELL] "; set -x; ff_l4_skipped zsh-glob FF_DEV_TOOLKIT_SKIP_ZSH_GLOB_GUARD; ff_l4_rc=$?; set +x; exit "$ff_l4_rc"' \
    _ "$LIB" > /dev/null 2> "$WORK/u2.trace" || u2_rc=$?
  u2_bad=""
  [ "$u2_rc" -eq 1 ] || u2_bad="$u2_bad / rc ${u2_rc}（期待 1）"
  u2_lines=0
  while IFS= read -r tl; do
    case "$tl" in
      '+[0] '*) : ;;
      +*) u2_bad="$u2_bad / 子プロセスの段の跡: ${tl}"; continue ;;
      *) continue ;;
    esac
    u2_lines=$((u2_lines + 1))
    w="${tl#'+[0] '}"
    w="${w%% *}"
    w="${w#\'}" w="${w%\'}"
    case "$w" in
      [A-Za-z_]*=* | ff_l4_* | set) continue ;;
    esac
    case "$(type -t "$w" 2>/dev/null || true)" in
      builtin | keyword) : ;;
      *) u2_bad="$u2_bad / 組み込みでないコマンド: ${w}" ;;
    esac
  done < "$WORK/u2.trace"
  [ "$u2_lines" -gt 0 ] || u2_bad="$u2_bad / xtrace の跡が 0 行（検査不成立）"
  u2_rc=0
  env -u FF_DEV_TOOLKIT_SKIP -u FF_DEV_TOOLKIT_SKIP_ZSH_GLOB_GUARD PATH="" "$UB" -c \
    '. "$1"; ff_l4_skipped zsh-glob FF_DEV_TOOLKIT_SKIP_ZSH_GLOB_GUARD' _ "$LIB" > /dev/null 2> "$WORK/u2.path.err" || u2_rc=$?
  [ "$u2_rc" -eq 1 ] || u2_bad="$u2_bad / PATH を空にした回の rc ${u2_rc}（期待 1）"
  [ ! -s "$WORK/u2.path.err" ] || u2_bad="$u2_bad / PATH を空にした回に stderr: $(head -n 2 "$WORK/u2.path.err" | tr '\n' ' ')"
  if [ -z "$u2_bad" ]; then ok "U2: 両方とも未設定の 1 回の呼び出しは子プロセスを起こさない（xtrace ${u2_lines} 行・PATH が空でも rc 1）"; else bad "U2: 両方とも未設定の呼び出しの違反${u2_bad}"; fi

  u3_n="$(grep -cE 'declare -A|=~' "$LIB" || true)"
  if [ "${u3_n:-0}" -eq 0 ]; then ok "U3: 共通関数に declare -A / =~ が 0 件"; else bad "U3: 共通関数に declare -A / =~ が ${u3_n} 件"; fi
fi

# ---- N10〜N12: 振る舞いの表 ----------------------------------------------------------
# fixture は <プラグイン root>/tests/l4-declarations/fixtures/（selftest の合成 root でも同じ位置）。
# 1 回の起動ごとに env -i で新しい bash を立て、fixtures/lib.sh → fixture の順に source して
# fx_setup → fx_run → fx_judge（ACK は fx_input → fx_run）を呼ぶ。環境は HOME / PATH / LANG / TMPDIR と
# fx_ で始まる小文字の変数と、表の行が足す宣言だけ（利用者の環境の宣言を表に混ぜない）。
FX_DIR="$PLUGIN/tests/l4-declarations/fixtures"
FX_LIB="$FX_DIR/lib.sh"
# 鍵ごとの worker（その鍵の行を順に起動する）を並べる本数の上限。今の表は 28 本（skip 24・ack 3・通知 1）で
# 1 回に収まり、所要は最も重い worker（走行中ロックの判定を 9 回起動する ACK review-lock）で決まる
B_PAR=32
B_DIR="$WORK/b"
mkdir -p "$B_DIR/skip" "$B_DIR/ack" "$B_DIR/notice" "$B_DIR/res"
b_t0="$(date +%s)"
b_launches=0
# fixture の 1 回の起動。判定の 1 行目を stdout へ出す（起動できない・判定が無いは ERROR で始まる行）
b_launch() { # <fixture> <作業ディレクトリ> <script> [<NAME=VALUE> …]
  local f="$1" wk="$2" prog="$3" line=""
  shift 3
  [ ! -e "$wk" ] || rm -rf -- "$wk"
  mkdir -p "$wk/home" || { echo "ERROR 作業ディレクトリを作れない"; return 0; }
  # shellcheck disable=SC2016 # 子の bash が展開する
  env -i HOME="$wk/home" PATH="$PATH" LANG="${LANG-}" TMPDIR="$wk" \
    fx_wk="$wk" fx_plugin="$PLUGIN" fx_root="$ROOT" fx_file="$f" fx_lib="$FX_LIB" "$@" \
    "$UB" -c '. "$fx_lib" && . "$fx_file" || { echo "ERROR fixture を読めない"; exit 0; }
      fx_setup > "$fx_wk/setup.log" 2>&1 || { echo "ERROR fx_setup が失敗: $(tail -n 2 "$fx_wk/setup.log" | tr "\n" " ")"; exit 0; }
      '"$prog" < /dev/null > "$wk.judge" 2> "$wk.stderr"
  IFS= read -r line < "$wk.judge" || true
  printf '%s\n' "${line:-ERROR 判定の出力が無い（stderr: $(head -c 160 "$wk.stderr" 2>/dev/null | tr '\n' ' ')）}"
}
# fixture の契約: 実在して読める・fx_owners（単引用のリテラル）が名簿の owner の集合と一致・各 owner を本文で使う
b_contract() { # <fixture> <名簿の owner 列（, 区切り）> → 違反を 1 行ずつ
  local f="$1" want got o
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then echo "fixture が無い（${f#"$ROOT"/}）"; return 0; fi
  want="$(printf '%s' "$2" | tr ',' ' ')"
  got="$(sed -n "s/^fx_owners='\(.*\)'\$/\1/p" "$f" | head -n 1)"
  if [ -z "$got" ]; then echo "fx_owners='…' の行が無い（${f#"$ROOT"/}）"; return 0; fi
  [ -z "$(set_minus "$want" "$got")$(set_minus "$got" "$want")" ] || echo "fx_owners（${got}）が名簿の owner（${want}）と違う"
  for o in $want; do
    [ "$(grep -cF -- "$o" "$f" || true)" -ge 2 ] || echo "owner ${o} を fx_owners の外で使っていない（起動していない）"
  done
}
b_row() { # <鍵> <kind> → 名簿の行の番号（無ければ空）
  local j=0
  while [ "$j" -lt "$N_ROWS" ]; do
    if [ "${R_KEY[$j]}" = "$1" ] && [ "${R_KIND[$j]}" = "$2" ]; then echo "$j"; return 0; fi
    j=$((j + 1))
  done
}
b_bg() { # <結果のファイル> <関数> [<引数> …] — 並べて走らせる（B_PAR 本ずつ）
  local out="$1"
  shift
  ( trap - EXIT HUP INT TERM; "$@" ) > "$out" 2>&1 &
  b_jobs=$((b_jobs + 1))
  if [ "$b_jobs" -ge "$B_PAR" ]; then wait; b_jobs=0; fi
}
b_jobs=0

# N10: kind=skip の鍵ごとに 4 通り（旧名が nonempty なら旧名=0 も）
b_skip_worker() { # <名簿の行の番号>
  local k="${R_KEY[$1]}" lg="${R_LEGACY[$1]}" rule="${R_RULE[$1]}" m want decl got
  for m in none new legacy legacy0 typo; do
    decl="" want=STOP
    case "$m" in
      none) : ;;
      new) decl="FF_DEV_TOOLKIT_SKIP=${k}" want=PASS ;;
      legacy) [ "$lg" != "-" ] || continue; decl="${lg}=1" want=PASS ;;
      legacy0) { [ "$lg" != "-" ] && [ "$rule" = nonempty ]; } || continue; decl="${lg}=0" want=PASS ;;
      typo) decl="FF_DEV_TOOLKIT_SKIP=${k}-guard" ;;
    esac
    got="$(b_launch "$FX_DIR/skip/${k}.sh" "$B_DIR/skip/${k}.${m}" 'fx_run; fx_judge' ${decl:+"$decl"})"
    if [ "${got%% *}" = "$want" ]; then printf 'ok\t%s\t%s\n' "$k" "$m"; else printf 'ng\t%s\t%s\t%s\n' "$k" "$m" "期待 ${want}・実際 ${got}"; fi
  done
}
b10_bad="" b10_expect=0
for k in $SKIP_KEYS; do
  i="$(b_row "$k" skip)"
  c="$(b_contract "$FX_DIR/skip/${k}.sh" "${R_OWNER[$i]}")"
  if [ -n "$c" ]; then b10_bad="$b10_bad / ${k}: $(printf '%s' "$c" | tr '\n' ' ')"; continue; fi
  if in_set "${k}-guard" "$ALL_KEYS"; then b10_bad="$b10_bad / ${k}: 打ち間違いの鍵 ${k}-guard が名簿にある（表の打ち間違いを組み直す）"; continue; fi
  # 行の数: 宣言なし・新しい鍵・打ち間違いの 3 行 + 旧名があれば 1 行 + 旧名が nonempty なら旧名=0 の 1 行
  b10_expect=$((b10_expect + 3))
  if [ "${R_LEGACY[$i]}" != "-" ]; then
    b10_expect=$((b10_expect + 1))
    [ "${R_RULE[$i]}" != nonempty ] || b10_expect=$((b10_expect + 1))
  fi
  b_bg "$B_DIR/res/skip.${k}" b_skip_worker "$i"
done
for f in "$FX_DIR"/skip/*.sh; do
  [ -f "$f" ] || continue
  k="${f##*/}" k="${k%.sh}"
  in_set "$k" "$SKIP_KEYS" || b10_bad="$b10_bad / 名簿の kind=skip に無い鍵の fixture: ${f#"$ROOT"/}"
done

# N11: ACK の別名（kind=ack の legacy と skip-legacy）を持つ鍵ごとに 前置の形 × 新しい名前 / 旧名 / 前置なし
b_ack_worker() { # <鍵> <旧名> <新しい名前>
  local k="$1" lg="$2" nw="$3" f forms form v val got wk rc d ctx hl hn
  f="$FX_DIR/ack/${k}.sh"
  forms="$(sed -n "s/^fx_forms='\(.*\)'\$/\1/p" "$f" | head -n 1)"
  [ -n "$forms" ] || { printf 'ng\t%s\t-\t%s\n' "$k" "fx_forms='…' の行が無い"; return 0; }
  for form in $forms; do
    for v in new legacy none; do
      case "$v" in new) val="${nw}=1" ;; legacy) val="${lg}=1" ;; *) val="" ;; esac
      wk="$B_DIR/ack/${k}.${form}.${v}"
      if [ "$form" = hookenv ]; then
        got="$(b_launch "$f" "$wk" 'fx_input "$fx_form" || { echo "ERROR fx_input が失敗"; exit 0; }; fx_run; echo ran' fx_form="$form" fx_ack_prefix= ${val:+"$val"})"
      else
        got="$(b_launch "$f" "$wk" 'fx_input "$fx_form" || { echo "ERROR fx_input が失敗"; exit 0; }; fx_run; echo ran' fx_form="$form" fx_ack_prefix="${val:+$val }")"
      fi
      if [ "$got" != ran ]; then printf 'ng\t%s\t%s\t%s\n' "$k" "${form}/${v}" "$got"; continue; fi
      rc="$(cat "$wk/rc" 2>/dev/null || echo '?')"
      d=none ctx=""
      if [ -s "$wk/out" ]; then
        d="$(jq -r '.hookSpecificOutput.permissionDecision // "none"' < "$wk/out" 2>/dev/null)" || d=unparsable
        ctx="$(jq -r '.hookSpecificOutput.additionalContext // ""' < "$wk/out" 2>/dev/null)" || ctx=""
      fi
      hl=0 hn=0
      case "$ctx" in *"${lg}=1"*) hl=1 ;; esac
      case "$ctx" in *"${nw}=1"*) hn=1 ;; esac
      case "${v}:${rc}:${d}:${hl}${hn}" in
        new:0:none:0? | new:0:allow:0? | legacy:0:none:11 | legacy:0:allow:11 | none:0:deny:*) printf 'ok\t%s\t%s\n' "$k" "${form}/${v}" ;;
        *) printf 'ng\t%s\t%s\t%s\n' "$k" "${form}/${v}" "rc ${rc}・decision ${d}・additionalContext の旧名 ${hl}/新しい名前 ${hn}（期待: new は通って注記なし / legacy は通って旧名と新しい名前の注記 / none は deny）" ;;
      esac
    done
  done
}
b11_bad="" b11_keys=""
i=0
while [ "$i" -lt "$N_ROWS" ]; do
  if [ "${R_KIND[$i]}" = ack ]; then
    lg=""
    if [ "${R_LEGACY[$i]}" != "-" ]; then
      lg="${R_LEGACY[$i]}"
    elif [ "${R_RULE[$i]}" = skip-legacy ]; then
      j="$(b_row "${R_KEY[$i]}" skip)"
      [ -z "$j" ] || lg="${R_LEGACY[$j]}"
    fi
    if [ -n "$lg" ] && [ "$lg" != "-" ]; then
      k="${R_KEY[$i]}"
      b11_keys="$b11_keys $k"
      c="$(b_contract "$FX_DIR/ack/${k}.sh" "${R_OWNER[$i]}")"
      if [ -n "$c" ]; then b11_bad="$b11_bad / ${k}: $(printf '%s' "$c" | tr '\n' ' ')"; else b_bg "$B_DIR/res/ack.${k}" b_ack_worker "$k" "$lg" "$(ack_name "$k")"; fi
    fi
  fi
  i=$((i + 1))
done
[ -n "$b11_keys" ] || b11_bad="$b11_bad / 名簿に ACK の別名（kind=ack の legacy・skip-legacy）が 1 件も無い（表が空）"
for f in "$FX_DIR"/ack/*.sh; do
  [ -f "$f" ] || continue
  k="${f##*/}" k="${k%.sh}"
  in_set "$k" "$b11_keys" || b11_bad="$b11_bad / 名簿の ACK の別名に無い鍵の fixture: ${f#"$ROOT"/}"
done

# N12: SessionStart の L4 宣言の通知（鍵 update-check の旧名 + 名簿に無い鍵）
B12_KEY=update-check
B12_UNKNOWN=no-such-key
b_notice_worker() { # <旧名>
  local lg="$1" got wk="$B_DIR/notice/$B12_KEY" field s needle miss=""
  got="$(b_launch "$FX_DIR/notice/${B12_KEY}.sh" "$wk" 'fx_run; fx_judge' "${lg}=1" "FF_DEV_TOOLKIT_SKIP=${B12_UNKNOWN}")"
  [ "${got%% *}" = PASS ] || miss="$miss 更新チェックが止まっていない（${got}）"
  for field in .systemMessage .hookSpecificOutput.additionalContext; do
    s="$(jq -r "${field} // \"\"" < "$wk/out" 2>/dev/null)" || s=""
    for needle in "FF_DEV_TOOLKIT_SKIP=${B12_KEY}" "$B12_UNKNOWN" "$lg" "止めた層: 宣言" "止めた規則: " "次の一手: "; do
      case "$s" in *"$needle"*) : ;; *) miss="$miss ${field} に「${needle}」が無い;" ;; esac
    done
  done
  if [ -z "$miss" ]; then printf 'ok\tnotice\t%s\n' "$B12_KEY"; else printf 'ng\tnotice\t%s\t%s\n' "$B12_KEY" "$miss"; fi
}
b12_bad=""
i="$(b_row "$B12_KEY" skip)"
if [ -z "$i" ] || [ "${R_LEGACY[$i]}" = "-" ]; then
  b12_bad=" / 名簿に鍵 ${B12_KEY} の kind=skip の旧名が無い（通知の表を組めない）"
elif in_set "$B12_UNKNOWN" "$ALL_KEYS"; then
  b12_bad=" / 名簿に無い鍵のつもりの ${B12_UNKNOWN} が名簿にある"
else
  c="$(b_contract "$FX_DIR/notice/${B12_KEY}.sh" "${R_OWNER[$i]}")"
  if [ -n "$c" ]; then b12_bad=" / $(printf '%s' "$c" | tr '\n' ' ')"; else b_bg "$B_DIR/res/notice" b_notice_worker "${R_LEGACY[$i]}"; fi
fi
for f in "$FX_DIR"/notice/*.sh; do
  [ -f "$f" ] || continue
  [ "${f##*/}" = "${B12_KEY}.sh" ] || b12_bad="$b12_bad / 通知の表に無い fixture: ${f#"$ROOT"/}"
done
wait

# 集計（結果のファイルの ok / ng の行。起動の途中で落ちた worker は ok の数が足りないので赤）
b_collect() { # <結果のファイル …> → B_OK・B_NG（ng の行を ' / ' でつなぐ）
  local r line
  B_OK=0 B_NG=""
  for r in "$@"; do
    [ -f "$r" ] || { B_NG="$B_NG / 結果が無い: ${r##*/}"; continue; }
    while IFS= read -r line; do
      case "$line" in
        ok$'\t'*) B_OK=$((B_OK + 1)) ;;
        ng$'\t'*) B_NG="$B_NG / $(printf '%s' "${line#ng?}" | tr '\t' ' ')" ;;
        *) B_NG="$B_NG / ${r##*/} の想定外の出力: ${line}" ;;
      esac
    done < "$r"
  done
}
b_t1="$(date +%s)"
b10_files=""
for k in $SKIP_KEYS; do [ -f "$B_DIR/res/skip.${k}" ] && b10_files="$b10_files $B_DIR/res/skip.${k}"; done
# shellcheck disable=SC2086 # 空白区切りの一覧（パスに空白を含まない一時領域）
b_collect $b10_files
b_launches=$((b_launches + B_OK))
[ "$B_OK" -eq "$b10_expect" ] || b10_bad="$b10_bad / 期待どおりの行が ${B_OK} 件（表の行は ${b10_expect} 件）"
b10_bad="$b10_bad$B_NG"
if [ -z "$b10_bad" ]; then ok "N10: 振る舞いの表（kind=skip の $(printf '%s\n' $SKIP_KEYS | grep -c .) 鍵 × 宣言なし=止める / 新しい鍵=素通し / 旧名=素通し / 打ち間違い=止める。計 ${B_OK} 回）"; else bad "N10: 振る舞いの表の違反${b10_bad}"; fi
b11_files=""
for k in $b11_keys; do [ -f "$B_DIR/res/ack.${k}" ] && b11_files="$b11_files $B_DIR/res/ack.${k}"; done
# shellcheck disable=SC2086
b_collect $b11_files
b_launches=$((b_launches + B_OK))
b11_bad="$b11_bad$B_NG"
for k in $b11_keys; do
  [ -f "$B_DIR/res/ack.${k}" ] || continue
  [ "$(grep -c '^ok' "$B_DIR/res/ack.${k}" || true)" -ge 3 ] || b11_bad="$b11_bad / ${k}: 期待どおりの行が 3 件に満たない"
done
if [ -z "$b11_bad" ]; then ok "N11: ACK の別名の表（$(printf '%s\n' $b11_keys | grep -c .) 鍵 × 前置の形 × 新しい名前=通る・注記なし / 旧名=通る・注記あり / 前置なし=止める。計 ${B_OK} 回）"; else bad "N11: ACK の別名の表の違反${b11_bad}"; fi
if [ -z "$b12_bad" ]; then
  b_collect "$B_DIR/res/notice"
  b_launches=$((b_launches + B_OK))
  if [ "$B_OK" -ne 1 ] || [ -n "$B_NG" ]; then b12_bad="${B_NG:- / 期待どおりの行が無い}"; fi
fi
if [ -z "$b12_bad" ]; then ok "N12: SessionStart の L4 宣言の通知（旧名 + 名簿に無い鍵 ${B12_UNKNOWN}）: systemMessage と additionalContext の両方に置き換え・未知の鍵・停止文の 3 行があり、更新チェックは止まったまま"; else bad "N12: L4 宣言の通知の違反${b12_bad}"; fi
echo "  ℹ️  振る舞いの表: 期待どおりの起動 ${b_launches} 回・$((b_t1 - b_t0)) 秒（${B_PAR} 本ずつ並べる）"

REACHED_END=1
echo ""
echo "l4-declarations: pass=${PASS} fail=${FAIL}"
[ "$FAIL" -eq 0 ]
