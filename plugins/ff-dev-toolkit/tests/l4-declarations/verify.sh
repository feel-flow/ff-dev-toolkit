#!/usr/bin/env bash
# L4 宣言（利用者が書く SKIP / ACK）の名簿 scripts/lib/l4-declarations.tsv と、実装・公開文書・試験の隔離の照合（ADR-087）。
# 空振り検出: tests/l4-declarations-selftest の合成 root への変異で 1 件ずつ実測した（2026-11-10 macOS / Bash 3.2.57。無変異の合成 root と、plugin.json の version を 1.1.0 にした写しは rc 0・✗ 0 件。selftest の所要は macOS で約 30〜45 秒）: 名簿の不在・0 行（見出しとコメントだけ）・0 バイト・列の数の違い・空の欄は N0 で rc 1、owner の実体の不在・legacy 列に旧名を書き戻す・remove_after に版を書く・legacy_value_rule に廃止した eq1 を書く・retired-stop を kind=ack の行に書く・副作用系の鍵の retired-stop を外す・副作用の無い鍵に retired-stop を書くは N1、名簿から 1 行消す・hook の鍵の文字列を変える・鍵を変数で渡すは N2、retired-stop の鍵の呼び出しから 'retired-stop' を外す・それ以外の鍵に足す・第 2 引数に旧名のリテラルを書く・第 3 引数（nonempty）を足す・第 2 引数を変数で渡す・.claude/hooks/ の呼び出しで retired-stop でない鍵に 'retired-stop' を足すは N3、PUBLIC-SURFACE 4-3 から 1 行消す・4-3 の節が無いは N4、README の鍵の表から 1 行消す・oss/ff-dev-toolkit/ があるのに README が無い・公開同期の配置の root の README.md から鍵を 1 行消すは N5（陽性の対照は公開同期の配置で root の README.md を読む）、名簿に無い ACK の名前は N6、hooks/・tests/lib/（行末にコメントを持つ行）・.claude/hooks/ の非コメント行に旧名の形を書き戻す・走査先の hooks/ が無い（走査の空振り）・走査先に読めないファイルがある（grep の rc 2）は N7（陽性の対照は hook のコメント行の旧名の形）、stop-block-contract / isolate_hook_env の unset を 1 つ消す・印を消す・印の間で名前をコメントへ移す・旧名の列挙を消す・旧名の列挙をコメントにするは N9、読み込み行から [ -r ] を外す・変数経由で 2 行に分けて読む・引用の無い path で読む・決まった形の後ろへ確かめない読み込みを繋ぐ・決まった形を行末のコメントに書くだけ・読み込み行を全部消す（1 件も無い）は N13、共通関数へコマンド置換を足すは U2、値の文法の許す文字の検査を外す・空の要素（,,）の検査を外す・covers を外す・旧名の検出を値 1 のときだけへ倒す・第 2 引数なしでも旧名で止める・末尾の _GUARD を外さない・注記を置かない・source 時の注記の初期化を外す・旧名から導いた鍵と呼び出しの鍵の照合を外す・注記の代入を鍵の照合より前へ動かす・空の値の変数も旧名として数える・retired-stop で止めた回に旧名を記録しない・呼び出しごとに旧名の記録を空へ戻さないは U1、新しい鍵を読まない stub・打ち間違いでも素通しする stub・ガードが旧名で素通しする stub・副作用系の stub が旧名で止まらない・名簿の鍵に fixture が無い・名簿に無い鍵の fixture・fx_owners の違い・owner を起動しない fixture・判定が常に素通しの fixture は N10、通知から停止文の 1 行を外す・通知を systemMessage だけに出す・副作用系の文を外す・通知の fixture が無い・値 0 のガードの旧名でもガードを止める置き換えを勧める・副作用系の鍵を動かすなら旧名を外すだけでよいを添えない・旧名だけの回に更新通知と L4 宣言の文を並べないは N12、停止文の共通形が 次の一手 へ注記を添えない・注記が FF_DEV_TOOLKIT_SKIP=<鍵> を名指さないは N14 が赤（表の外を狙う変異は表の fixture を外した写しで測る）。
# run-all-required: yes — 名簿と実装・公開文書の一致を見るのはこの suite だけで、skip 経路は持たないが、将来 skip 経路が生えても黙って消えてはならない
#
# 使い方: verify.sh [--root <リポジトリ root>]
#   --root は selftest（tests/l4-declarations-selftest）が合成した root を渡す口。既定はこのファイルから
#   4 つ上（リポジトリ root）。公開 checkout（公開同期の配置）では oss/ff-dev-toolkit/ の中身が root へ展開される
#   ので、公開 README は root の README.md になる（oss/ff-dev-toolkit/ が無い root では root の README.md を読む）。
#
# 旧名（`#2735` で撤去した内部の別名）はこの suite にも書かない。試す旧名は鍵から組む（接頭辞 FF_DEV_TOOLKIT_SKIP_ +
# 鍵を大文字・_ 区切りにしたもの。末尾の _GUARD は付けた形と付けない形の両方を試す。共通関数はどちらの形からも
# 同じ鍵を導く）。
#
# 検査（どれも名指しの ✗ で数え、最後に 1 件でもあれば rc 1）:
#   N0 名簿の前提: 不在・読めない・0 バイト・見出し行の違い・列の数（タブ区切り 7 列）・空の欄・データ行 0 件は
#      検査不成立として、ここで rc 1 で終える（以後の照合は名簿を読めたことを前提にする）
#   N1 名簿の形: kind（skip / ack）・鍵の綴り（小文字のケバブ）・(key, kind) の重複・legacy と remove_after は
#      全行 `-`（別名は撤去した）・legacy_value_rule は `-` か retired-stop（retired-stop は kind=skip の行だけで、
#      その鍵の集合は副作用を持つ 4 鍵 auto-update / codex-auto-update / decision-tree / effort-metrics と一致）・
#      covers の参照先・owner の実在
#   N2 呼び出しの鍵: hooks/・scripts/・tests/lib/・.claude/hooks/ の `ff_l4_skipped '<鍵>' …` の第 1 引数のリテラルの集合が、
#      名簿の kind=skip の鍵の集合と一致する（片方にだけある鍵を両方向とも名指す）。鍵を変数で渡す呼び出しも赤
#   N3 呼び出しの第 2 引数: legacy_value_rule=retired-stop の鍵は `'retired-stop'` を、それ以外は第 2 引数なしを
#      書く。それ以外の第 2 引数（旧名のリテラルなど）・変数で渡す第 2 引数・第 3 引数は赤
#   N4 PUBLIC-SURFACE の「### 4-3.」の表の鍵（先頭セル）の集合 = 名簿の kind=skip の鍵の集合
#   N5 公開 README（開発元は oss/ff-dev-toolkit/README.md、公開同期の配置は root の README.md）の鍵の表（見出しの先頭セルが `鍵` の表。データ行の先頭セル）の集合 = 同上
#   N6 配布実行物（hooks/・scripts/・tests/lib/・tests/run-all.sh・mcp/src/）にある `FF_<…>_ACK` の名前が、どれも
#      名簿の kind=ack の鍵から作る名前（FF_ + 鍵を大文字・`_` 区切りにしたもの + _ACK）にある（1 件も無いのも赤）
#   N7 旧名の書き戻し: hooks/・scripts/・tests/lib/・.claude/hooks/・tests/run-all.sh・mcp/src/ の非コメント行に、
#      FF_DEV_TOOLKIT_SKIP_ の後ろへ英大文字か数字が続く名前のリテラルが無い（旧名を書き戻す回帰を止める。名簿を見ない
#      字句の針）。走査先の hooks/ か scripts/ が無い・走査したファイルが 0 件・読めないファイルがある（grep の rc 2）は
#      検査不成立の赤
#   N9 試験の隔離: tests/stop-block-contract/verify.sh と tests/lib/adapter-env-isolation.sh の印
#      （`l4-default-unset:begin` 〜 `:end`）の間に、FF_DEV_TOOLKIT_SKIP と名簿の kind=ack の名前が全部あり、
#      FF_DEV_TOOLKIT_SKIP_ で始まる名前の列挙（`${!FF_DEV_TOOLKIT_SKIP_@}` か `${!FF_DEV_TOOLKIT_SKIP_*}`）がある
#   U1 共通関数の終了コードと注記と、retired-stop で止めた旧名の記録（ff_l4_retired_stop_name）の表（/bin/bash が
#      あればそれで、無ければこの suite の bash で）
#   U2 宣言も旧名も無い 1 回の呼び出しが子プロセスを起こさない（xtrace の跡がどれも [0] の段で、
#      コマンドがどれも組み込み・予約語・関数・代入）。PATH を空にしても rc 1 で戻る
#   U3 共通関数に連想配列と正規表現の照合が無い（`declare -A` / `=~` が 0 件）
#   N10 振る舞いの表（kind=skip）: 名簿の鍵ごとに fixtures/skip/<鍵>.sh で owner を実際に起動し、宣言なし=止める /
#      FF_DEV_TOOLKIT_SKIP=<鍵>=素通し / FF_DEV_TOOLKIT_SKIP=<鍵>-guard（打ち間違い）=止める。旧名は、
#      legacy_value_rule が `-` の鍵は 2 つの形 =1 のどちらでも止める（旧名では素通ししない）、retired-stop の鍵は
#      _GUARD なし =0 と _GUARD 付き =1 で素通し（副作用を止める）・空の値では止める。名簿の鍵に fixture が無い・
#      名簿に無い鍵の fixture がある・fx_owners が名簿の owner 列と違う・owner を fx_owners の外で使っていない・
#      判定が STOP / PASS で始まらないは赤
#   N12 SessionStart の L4 宣言の通知（fixtures/notice/update-check.sh。systemMessage と additionalContext の両方を見る）:
#      mixed = 副作用系の鍵 auto-update の旧名=0・ガードの鍵 exit-code の旧名=1・FF_DEV_TOOLKIT_SKIP=update-check,<名簿に
#        無い鍵>: 2 種類の文（安全のため止めている / 読まなくなった）・置き換え・旧名・未知の鍵・停止文の 3 行があり、
#        次の一手は exit-code を置き換えに入れ（値 1）、auto-update を動かすなら旧名を外すだけでよいと添える。更新チェックは
#        止まったまま
#      retired-only（AC2）= auto-update の旧名=0 だけ: 更新チェックが走り、更新通知（📦）と同じ systemMessage に安全のため
#        止めている文と FF_DEV_TOOLKIT_SKIP=auto-update が並ぶ
#      guard0 = exit-code の旧名=0 と FF_DEV_TOOLKIT_SKIP=update-check: 次の一手は旧名を外すだけを案内し、exit-code を
#        止める置き換えを勧めない
#   N14 止まった回の注記（AC1）: ガードの鍵 exit-code の旧名=1 だけを置いて fixtures/skip/exit-code.sh を起動すると
#      deny され、permissionDecisionReason の 次の一手 の行が FF_DEV_TOOLKIT_SKIP=exit-code と旧名を含む。旧名を
#      置かない回の 次の一手 の行には旧名の注記が無い
#      表の fixture は両側（止める / 素通し）を自分で示すので、針の当たらない fixture（常に素通し・常に deny）は
#      表の行が赤にする。起動は 1 回ごとに env -i の新しい bash（fixtures/lib.sh のヘッダ）で、利用者の環境の宣言を混ぜない
#   N13 共通関数の読み込みの形: hooks/・scripts/・tests/lib/・.claude/hooks/ で l4-declarations.sh の名前を書いた
#      非コメント行は、どれも `{ [ -r "<lib>" ] && . "<lib>"; } 2>/dev/null || …` の 1 行の形にする（bash 3.2 は
#      set -e の下で `.` の失敗が `||` の中でも致命。変数へ入れて別の行で読む形も赤）。該当の行が 0 件も赤
#
# bash 3.2 互換（連想配列・`=~` を使わない）。外部コマンド: awk / grep / sed / sort / comm / jq（表の owner は
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
SBC="$PLUGIN/tests/stop-block-contract/verify.sh"
AEI="$PLUGIN/tests/lib/adapter-env-isolation.sh"
SURFACE_LIB="$SCRIPT_DIR/../lib/public-surface.sh"
TSV_HEADER="key	kind	owner	covers	legacy	legacy_value_rule	remove_after"
# legacy_value_rule=retired-stop の鍵の集合（ADR-087 / `#2735`。副作用を持つ 4 鍵。旧名を見つけたら止める側へ倒す）
RETIRED_STOP_KEYS="auto-update codex-auto-update decision-tree effort-metrics"

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
command -v git >/dev/null 2>&1 || { echo "✗ l4-declarations: git が無い（振る舞いの表の fixture が一時リポジトリを作れない。skip にしない）" >&2; exit 1; }
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
# 鍵 → 英大文字・_ 区切り
upper_snake() { printf '%s' "$1" | tr 'abcdefghijklmnopqrstuvwxyz-' 'ABCDEFGHIJKLMNOPQRSTUVWXYZ_'; }
# 鍵 → ACK の名前（FF_ + 大文字・_ 区切り + _ACK）
ack_name() { printf 'FF_%s_ACK\n' "$(upper_snake "$1")"; }
# 鍵 → 撤去した旧名の形（第 2 引数 guard で末尾に _GUARD を付ける）。旧名をこの suite に字句で書かないための組み立て
retired_name() { printf 'FF_DEV_TOOLKIT_SKIP_%s%s\n' "$(upper_snake "$1")" "${2:+_GUARD}"; }

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
SKIP_KEYS="" ACK_KEYS="" ALL_KEYS="" STOP_KEYS=""
i=0
while [ "$i" -lt "$N_ROWS" ]; do
  case "${R_KIND[$i]}" in
    skip)
      SKIP_KEYS="$SKIP_KEYS ${R_KEY[$i]}"
      [ "${R_RULE[$i]}" != "retired-stop" ] || STOP_KEYS="$STOP_KEYS ${R_KEY[$i]}"
      ;;
    ack) ACK_KEYS="$ACK_KEYS ${R_KEY[$i]}" ;;
  esac
  in_set "${R_KEY[$i]}" "$ALL_KEYS" || ALL_KEYS="$ALL_KEYS ${R_KEY[$i]}"
  i=$((i + 1))
done
ACK_NAMES=""
for k in $ACK_KEYS; do ACK_NAMES="$ACK_NAMES $(ack_name "$k")"; done
echo "  ℹ️  名簿: ${N_ROWS} 行（kind=skip $(printf '%s\n' $SKIP_KEYS | grep -c .) / kind=ack $(printf '%s\n' $ACK_KEYS | grep -c .) / retired-stop $(printf '%s\n' $STOP_KEYS | grep -c .)）"

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
  [ "$lg" = "-" ] || n1_bad="$n1_bad / ${k}/${kind}: legacy が - でない（${lg}。別名は撤去した）"
  [ "$ra" = "-" ] || n1_bad="$n1_bad / ${k}/${kind}: remove_after が - でない（${ra}。別名が無いので期限も無い）"
  case "$rule" in
    -) : ;;
    retired-stop) [ "$kind" = "skip" ] || n1_bad="$n1_bad / ${k}: retired-stop は kind=skip の行だけに書く" ;;
    *) n1_bad="$n1_bad / ${k}/${kind}: legacy_value_rule が - / retired-stop でない（${rule}）" ;;
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
n1_stop_missing="$(set_minus "$RETIRED_STOP_KEYS" "$STOP_KEYS")" n1_stop_extra="$(set_minus "$STOP_KEYS" "$RETIRED_STOP_KEYS")"
[ -z "$n1_stop_missing$n1_stop_extra" ] || n1_bad="$n1_bad / retired-stop の鍵の集合が副作用を持つ 4 鍵（${RETIRED_STOP_KEYS}）と違う（無い: ${n1_stop_missing:-なし} / 余分: ${n1_stop_extra:-なし}）"
if [ -z "$SKIP_KEYS" ]; then n1_bad="$n1_bad / kind=skip の行が 0 件"; fi
if [ -z "$ACK_KEYS" ]; then n1_bad="$n1_bad / kind=ack の行が 0 件"; fi
if [ -z "$n1_bad" ]; then ok "N1: 名簿の形（kind・鍵の綴り・重複・legacy / remove_after は全行 -・retired-stop は副作用の 4 鍵・covers・owner）"; else bad "N1: 名簿の形の違反${n1_bad}"; fi

# ---- N2 / N3: 呼び出し ------------------------------------------------------------
# 1 行に書いた `ff_l4_skipped <鍵> [<第 2 引数>] [<第 3 引数>]` を字句で拾う。コメント行（先頭が #）・関数の
# 定義（直後が `(`）・`declare -F` / `type` / `command -v` の後ろに置いた名前は呼び出しに数えない。引数は
# `;` / `)` で終わる語か、制御の語（then・&&・||・リダイレクト）の手前で終わる。
CALLS="$WORK/calls.tsv"
: > "$CALLS"
for d in "$PLUGIN/hooks" "$PLUGIN/scripts" "$PLUGIN/tests/lib" "$ROOT/.claude/hooks"; do
  [ -d "$d" ] || continue
  grep -rnI 'ff_l4_skipped' "$d" 2>/dev/null | { grep -vF "${LIB}:" || true; } >> "$CALLS.raw" || true
done
[ -f "$CALLS.raw" ] || : > "$CALLS.raw"
awk '
  function ctl(w) { return w ~ /^(&&|\|\||\||;|then|>|<|2>)/ }
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
      k = ""; a2 = ""; a3 = ""; ended = 0
      if (m >= 1) { k = a[1]; if (k ~ /[;)]+$/) { ended = 1; gsub(/[;)]+$/, "", k) } }
      if (!ended && m >= 2 && !ctl(a[2])) { a2 = a[2]; if (a2 ~ /[;)]+$/) { ended = 1; gsub(/[;)]+$/, "", a2) } } else ended = 1
      if (!ended && m >= 3 && !ctl(a[3])) { a3 = a[3]; gsub(/[;)]+$/, "", a3) }
      printf "%s\t%s\t%s\t%s\t%s\n", path, line, (k == "" ? "-" : k), (a2 == "" ? "-" : a2), (a3 == "" ? "-" : a3)
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
while IFS=$'\t' read -r cpath cline ckey carg2 carg3; do
  [ -n "$cpath" ] || continue
  rel="${cpath#"$ROOT"/}:${cline}"
  if ! k="$(unquote "$ckey")"; then n2_var="$n2_var ${rel}"; continue; fi
  case "$k" in
    '' | - | *[!abcdefghijklmnopqrstuvwxyz0123456789-]*) n2_shape="$n2_shape ${rel}（${ckey}）"; continue ;;
  esac
  in_set "$k" "$call_keys" || call_keys="$call_keys $k"
  # N3: 第 2 引数は名簿の legacy_value_rule と一致する（retired-stop か、なし）。第 3 引数は書かない
  want_rule="" i=0
  while [ "$i" -lt "$N_ROWS" ]; do
    if [ "${R_KEY[$i]}" = "$k" ] && [ "${R_KIND[$i]}" = "skip" ]; then want_rule="${R_RULE[$i]}"; break; fi
    i=$((i + 1))
  done
  [ -n "$want_rule" ] || continue # 名簿に無い鍵は N2 が名指す
  [ "$carg3" = "-" ] || n3_bad="$n3_bad / ${rel}: 鍵 ${k} の呼び出しに第 3 引数がある（${carg3}。nonempty は廃止した）"
  if [ "$carg2" = "-" ]; then
    got="-"
  elif ! got="$(unquote "$carg2")"; then
    n3_bad="$n3_bad / ${rel}: 第 2 引数を変数で渡している（${carg2}）"; continue
  fi
  case "$got" in
    - | retired-stop) : ;;
    *) n3_bad="$n3_bad / ${rel}: 鍵 ${k} の第 2 引数が retired-stop でない（${got}。旧名は書かない）"; continue ;;
  esac
  if [ "$want_rule" = "retired-stop" ] && [ "$got" != "retired-stop" ]; then
    n3_bad="$n3_bad / ${rel}: 鍵 ${k} は legacy_value_rule=retired-stop なのに第 2 引数 'retired-stop' が無い"
  elif [ "$want_rule" != "retired-stop" ] && [ "$got" = "retired-stop" ]; then
    n3_bad="$n3_bad / ${rel}: 鍵 ${k} は legacy_value_rule=${want_rule} なのに第 2 引数 'retired-stop' がある"
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
if [ -z "$n3_bad" ]; then ok "N3: 呼び出しの第 2 引数が名簿の legacy_value_rule と一致（retired-stop の鍵だけ 'retired-stop'。第 3 引数なし）"; else bad "N3: 呼び出しの第 2 引数の不一致${n3_bad}"; fi

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

# ---- N7: 旧名の書き戻し ------------------------------------------------------------
# 名簿を見ない字句の針。FF_DEV_TOOLKIT_SKIP_ の後ろへ英大文字か数字が続く名前（撤去した旧名の形）を、実行物の
# 非コメント行に書かない。共通関数と通知が使う接頭辞の列挙（${!FF_DEV_TOOLKIT_SKIP_@}）や接頭辞を外す展開は、
# 後ろが英大文字でも数字でもないので当たらない。行末のコメントに書いた名前も非コメント行として数える（赤に倒す）。
# 走査先は N6 と同じ配布実行物（hooks/・scripts/・tests/lib/・tests/run-all.sh・mcp/src/）に、配布外の .claude/hooks/ を
# 足したもの。読めないファイル（grep の rc 2）は、そのファイルの 0 件を主張できないので検査不成立にする。
n7_re='FF_DEV_TOOLKIT_SKIP_[A-Z0-9]'
n7_dirs=() n7_bad=""
for n7_d in "$PLUGIN/hooks" "$PLUGIN/scripts"; do
  [ -d "$n7_d" ] || n7_bad="$n7_bad / 走査先 ${n7_d#"$ROOT"/} が無い（検査不成立）"
done
for n7_d in "$PLUGIN/hooks" "$PLUGIN/scripts" "$PLUGIN/tests/lib" "$PLUGIN/tests/run-all.sh" "$PLUGIN/mcp/src" "$ROOT/.claude/hooks"; do
  [ -e "$n7_d" ] && n7_dirs+=("$n7_d")
done
n7_files=0 n7_hits=0 n7_list="" n7_rc=0
if [ "${#n7_dirs[@]}" -gt 0 ]; then
  n7_files="$(grep -rlI '' "${n7_dirs[@]}" 2>/dev/null | grep -c . || true)"
  grep -rnIE "$n7_re" "${n7_dirs[@]}" > "$WORK/n7.hits" 2> "$WORK/n7.err" || n7_rc=$?
  [ "$n7_rc" -le 1 ] || n7_bad="$n7_bad / 走査が失敗した（grep rc=${n7_rc}。読めないファイルがある。検査不成立）: $(head -n 2 "$WORK/n7.err" | tr '\n' ' ')"
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    hp="${hit%%:*}" hr="${hit#*:}"
    hl="${hr%%:*}" ht="${hr#*:}"
    ht="${ht#"${ht%%[![:space:]]*}"}"
    case "$ht" in '#'*) continue ;; esac
    n7_hits=$((n7_hits + 1))
    [ "$n7_hits" -le 20 ] && n7_list="${n7_list}
      ${hp#"$ROOT"/}:${hl}"
  done < "$WORK/n7.hits"
fi
[ "${n7_files:-0}" -gt 0 ] || n7_bad="$n7_bad / 走査したファイルが 0 件（検査不成立）"
[ "$n7_hits" -eq 0 ] || n7_bad="$n7_bad / 旧名の形の名前を書いた非コメント行が ${n7_hits} 行（先頭 20 行。旧名は読まないので書き戻さない。試すときは鍵から組む）:${n7_list}"
if [ -z "$n7_bad" ]; then ok "N7: 実行物（${n7_files} ファイル）の非コメント行に FF_DEV_TOOLKIT_SKIP_<英大文字・数字> の名前が 0 件"; else bad "N7: 旧名の書き戻しの違反${n7_bad}"; fi

# ---- N9: 試験の隔離の既定の unset ----------------------------------------------------
n9_required="FF_DEV_TOOLKIT_SKIP $ACK_NAMES"
for n9_file in "$SBC" "$AEI"; do
  n9_rel="${n9_file#"$ROOT"/}"
  if [ ! -f "$n9_file" ] || [ ! -r "$n9_file" ]; then bad "N9: ${n9_rel} が無いか読めない"; continue; fi
  n9_marks="$(awk '/l4-default-unset:begin/ { b++ } /l4-default-unset:end/ { e++ } END { printf "%d %d", b, e }' "$n9_file")"
  if [ "$n9_marks" != "1 1" ]; then bad "N9: ${n9_rel} に印 l4-default-unset:begin / :end が 1 組だけある形でない（begin / end の数: ${n9_marks}）"; continue; fi
  n9_body="$(awk '/l4-default-unset:begin/ { s = 1; next } /l4-default-unset:end/ { s = 0 } s { sub(/(^|[ \t])#.*$/, ""); print }' "$n9_file")"
  n9_names="$(printf '%s\n' "$n9_body" | { grep -oE 'FF_[A-Z0-9_]+' || true; } | LC_ALL=C sort -u | tr '\n' ' ')"
  n9_missing="$(set_minus "$n9_required" "$n9_names")"
  n9_enum=0
  case "$n9_body" in *'${!FF_DEV_TOOLKIT_SKIP_@}'* | *'${!FF_DEV_TOOLKIT_SKIP_*}'*) n9_enum=1 ;; esac
  if [ -z "$n9_missing" ] && [ "$n9_enum" -eq 1 ]; then
    ok "N9: ${n9_rel} の既定の unset に FF_DEV_TOOLKIT_SKIP と名簿の ACK（$(printf '%s\n' $ACK_NAMES | grep -c .) 名）と、撤去した旧名の列挙がある"
  else
    [ -z "$n9_missing" ] || bad "N9: ${n9_rel} の既定の unset に無い名前: ${n9_missing}"
    [ "$n9_enum" -eq 1 ] || bad "N9: ${n9_rel} の既定の unset に FF_DEV_TOOLKIT_SKIP_ で始まる名前の列挙（\${!FF_DEV_TOOLKIT_SKIP_@}）が無い（撤去した旧名が環境に残ると、副作用系は止まり停止文に注記が足される）"
  fi
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
ZG_G="$(retired_name zsh-glob guard)" ZG_P="$(retired_name zsh-glob)"
AU_P="$(retired_name auto-update)" AU_G="$(retired_name auto-update guard)"
EC_G="$(retired_name exit-code guard)"
AU_LOWER="FF_DEV_TOOLKIT_SKIP_$(printf '%s' auto-update | tr '-' '_')"
if [ ! -f "$LIB" ] || [ ! -r "$LIB" ] || [ ! -s "$LIB" ]; then
  bad "U1: 共通関数が無いか読めないか 0 バイト: ${LIB#"$ROOT"/}"
elif ! "$UB" -c '. "$1" && declare -F ff_l4_skipped >/dev/null' _ "$LIB" 2>/dev/null; then
  bad "U1: 共通関数を source しても ff_l4_skipped が定義されない"
else
  # 表の 1 行: <期待する rc> <環境の代入 …> -- <引数 …>。環境は env -i で表の代入だけにする
  u1_bad="" u1_n=0
  u1_case() {
    local exp="$1" rc=0
    local envs=()
    shift
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    env -i ${envs[@]+"${envs[@]}"} "$UB" -c 'set -u; . "$1"; shift; ff_l4_skipped "$@"' _ "$LIB" "$@" >/dev/null 2>&1 || rc=$?
    u1_n=$((u1_n + 1))
    [ "$rc" -eq "$exp" ] || u1_bad="$u1_bad / [${envs[*]-（宣言なし）}] ff_l4_skipped $* → rc ${rc}（期待 ${exp}）"
  }
  # 注記の表の 1 行: <注記に含むべき語（空なら注記が空であること）> <環境の代入 …> -- <引数 …>
  u1_note() {
    local want="$1" got=""
    local envs=()
    shift
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    got="$(env -i ${envs[@]+"${envs[@]}"} "$UB" -c 'set -u; . "$1"; shift; ff_l4_skipped "$@"; printf "%s" "${ff_l4_retired_note-}"' _ "$LIB" "$@" 2>/dev/null)"
    u1_n=$((u1_n + 1))
    if [ -z "$want" ]; then
      [ -z "$got" ] || u1_bad="$u1_bad / [${envs[*]-（宣言なし）}] ff_l4_skipped $* の注記が空でない（${got}）"
    else
      case "$got" in *"$want"*) : ;; *) u1_bad="$u1_bad / [${envs[*]-（宣言なし）}] ff_l4_skipped $* の注記に「${want}」が無い（${got:-空}）" ;; esac
    fi
  }
  u1_case 0 FF_DEV_TOOLKIT_SKIP=zsh-glob -- zsh-glob
  u1_case 0 FF_DEV_TOOLKIT_SKIP=zsh-glob,update-check -- zsh-glob
  u1_case 1 FF_DEV_TOOLKIT_SKIP=zsh -- zsh-glob
  u1_case 1 FF_DEV_TOOLKIT_SKIP=ZSH_GLOB -- zsh-glob
  u1_case 1 'FF_DEV_TOOLKIT_SKIP=zsh-glob update-check' -- zsh-glob
  u1_case 1 FF_DEV_TOOLKIT_SKIP=zsh-glob, -- zsh-glob
  u1_case 1 FF_DEV_TOOLKIT_SKIP=,zsh-glob -- zsh-glob
  u1_case 1 FF_DEV_TOOLKIT_SKIP=zsh-glob,,update-check -- zsh-glob
  u1_case 1 FF_DEV_TOOLKIT_SKIP=zsh-glob,UPDATE_CHECK -- zsh-glob
  u1_case 1 -- zsh-glob
  u1_case 0 FF_DEV_TOOLKIT_SKIP=zsh-glob -- zsh-expansion
  u1_case 1 FF_DEV_TOOLKIT_SKIP=zsh-expansion -- zsh-glob
  # 旧名: ガード系・通知系（第 2 引数なし）は旧名で止めない
  u1_case 1 "${ZG_G}=1" -- zsh-glob
  u1_case 1 "${ZG_P}=1" -- zsh-glob
  u1_case 1 "${AU_P}=1" -- auto-update
  # 旧名: retired-stop は空でない値で止める（0 でも・_GUARD 付きの形でも）。空の値・別の鍵の旧名・小文字の名前では止めない
  u1_case 0 "${AU_P}=0" -- auto-update retired-stop
  u1_case 0 "${AU_P}=1" -- auto-update retired-stop
  u1_case 0 "${AU_G}=1" -- auto-update retired-stop
  u1_case 1 "${AU_P}=" -- auto-update retired-stop
  u1_case 1 "${EC_G}=1" -- auto-update retired-stop
  u1_case 1 "${AU_LOWER}=1" -- auto-update retired-stop
  u1_case 1 -- auto-update retired-stop
  u1_case 0 FF_DEV_TOOLKIT_SKIP=auto-update -- auto-update retired-stop
  # 注記: 第 2 引数なしで旧名を見つけた回だけ、新しい書き方の 1 行が入る。環境から持ち込んだ同名の値は使わない
  u1_note "FF_DEV_TOOLKIT_SKIP=zsh-glob" "${ZG_G}=1" -- zsh-glob
  u1_note "$ZG_G" "${ZG_G}=1" -- zsh-glob
  u1_note "FF_DEV_TOOLKIT_SKIP=zsh-glob" "${ZG_P}=1" -- zsh-glob
  u1_note "" -- zsh-glob
  u1_note "" "${EC_G}=1" -- zsh-glob
  u1_note "" "${ZG_G}=" -- zsh-glob
  u1_note "" "ff_l4_retired_note=持ち込んだ値" -- zsh-glob
  u1_note "" "${AU_P}=0" -- auto-update retired-stop
  # retired-stop で止めた回だけ、見つけた旧名を ff_l4_retired_stop_name に置く（呼び出しごとに空へ戻す）
  u1_stop() { # <期待する値（空なら空であること）> <環境の代入 …> -- <script>
    local want="$1" got
    local envs=()
    shift
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    got="$(env -i ${envs[@]+"${envs[@]}"} "$UB" -c 'set -u; . "$1"; eval "$2"; printf "%s" "${ff_l4_retired_stop_name-}"' _ "$LIB" "$1" 2>/dev/null)"
    u1_n=$((u1_n + 1))
    [ "$got" = "$want" ] || u1_bad="$u1_bad / [${envs[*]-（宣言なし）}] $1 の後の ff_l4_retired_stop_name が「${got}」（期待「${want}」）"
  }
  u1_stop "$AU_P" "${AU_P}=0" -- 'ff_l4_skipped auto-update retired-stop'
  u1_stop "$AU_G" "${AU_G}=1" -- 'ff_l4_skipped auto-update retired-stop'
  u1_stop "" FF_DEV_TOOLKIT_SKIP=auto-update -- 'ff_l4_skipped auto-update retired-stop'
  u1_stop "" "${ZG_G}=1" -- 'ff_l4_skipped zsh-glob'
  u1_stop "" "${AU_P}=0" -- 'ff_l4_skipped auto-update retired-stop; ff_l4_skipped zsh-glob'
  u1_stop "" "ff_l4_retired_stop_name=持ち込んだ値" -- ':'
  if [ -z "$u1_bad" ]; then ok "U1: 共通関数の終了コードと注記の表（${u1_n} 行。${UB}）"; else bad "U1: 共通関数の終了コードの違反${u1_bad}"; fi

  # U2: 宣言も旧名も無い 1 回の呼び出し
  u2_rc=0
  env -i "$UB" -c \
    '. "$1"; PS4="+[\$BASH_SUBSHELL] "; set -x; ff_l4_skipped zsh-glob; ff_l4_rc=$?; set +x; exit "$ff_l4_rc"' \
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
  env -i PATH="" "$UB" -c \
    '. "$1"; ff_l4_skipped zsh-glob' _ "$LIB" > /dev/null 2> "$WORK/u2.path.err" || u2_rc=$?
  [ "$u2_rc" -eq 1 ] || u2_bad="$u2_bad / PATH を空にした回の rc ${u2_rc}（期待 1）"
  [ ! -s "$WORK/u2.path.err" ] || u2_bad="$u2_bad / PATH を空にした回に stderr: $(head -n 2 "$WORK/u2.path.err" | tr '\n' ' ')"
  if [ -z "$u2_bad" ]; then ok "U2: 宣言も旧名も無い 1 回の呼び出しは子プロセスを起こさない（xtrace ${u2_lines} 行・PATH が空でも rc 1）"; else bad "U2: 宣言も旧名も無い呼び出しの違反${u2_bad}"; fi

  u3_n="$(grep -cE 'declare -A|=~' "$LIB" || true)"
  if [ "${u3_n:-0}" -eq 0 ]; then ok "U3: 共通関数に declare -A / =~ が 0 件"; else bad "U3: 共通関数に declare -A / =~ が ${u3_n} 件"; fi
fi

# ---- N10・N12・N14: 振る舞いの表 ---------------------------------------------------------
# fixture は <プラグイン root>/tests/l4-declarations/fixtures/（selftest の合成 root でも同じ位置）。
# 1 回の起動ごとに env -i で新しい bash を立て、fixtures/lib.sh → fixture の順に source して
# fx_setup → fx_run → fx_judge を呼ぶ。環境は HOME / PATH / LANG / TMPDIR と fx_ で始まる小文字の変数と、
# 表の行が足す宣言だけ（利用者の環境の宣言を表に混ぜない）。
FX_DIR="$PLUGIN/tests/l4-declarations/fixtures"
FX_LIB="$FX_DIR/lib.sh"
# 鍵ごとの worker（その鍵の行を順に起動する）を並べる本数の上限。今の表は 28 本（skip 24・通知 3・注記 1）で
# 1 回に収まり、所要は最も重い worker で決まる
B_PAR=32
B_DIR="$WORK/b"
mkdir -p "$B_DIR/skip" "$B_DIR/notice" "$B_DIR/note" "$B_DIR/res"
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

# N10: kind=skip の鍵ごとに 宣言なし / 新しい鍵 / 打ち間違い と、旧名の行（legacy_value_rule ごとに 2 行か 3 行）
b_skip_worker() { # <名簿の行の番号>
  local k="${R_KEY[$1]}" rule="${R_RULE[$1]}" m want decl got
  for m in none new typo lg-plain lg-guard lg0-plain lg1-guard lg-empty; do
    decl="" want=STOP
    case "$m" in
      none) : ;;
      new) decl="FF_DEV_TOOLKIT_SKIP=${k}" want=PASS ;;
      typo) decl="FF_DEV_TOOLKIT_SKIP=${k}-guard" ;;
      lg-plain) [ "$rule" = "-" ] || continue; decl="$(retired_name "$k")=1" ;;
      lg-guard) [ "$rule" = "-" ] || continue; decl="$(retired_name "$k" guard)=1" ;;
      lg0-plain) [ "$rule" = retired-stop ] || continue; decl="$(retired_name "$k")=0" want=PASS ;;
      lg1-guard) [ "$rule" = retired-stop ] || continue; decl="$(retired_name "$k" guard)=1" want=PASS ;;
      lg-empty) [ "$rule" = retired-stop ] || continue; decl="$(retired_name "$k")=" ;;
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
  # 行の数: 宣言なし・新しい鍵・打ち間違いの 3 行 + 旧名の行（retired-stop は 3 行、それ以外は 2 行）
  if [ "${R_RULE[$i]}" = retired-stop ]; then b10_expect=$((b10_expect + 6)); else b10_expect=$((b10_expect + 5)); fi
  b_bg "$B_DIR/res/skip.${k}" b_skip_worker "$i"
done
for f in "$FX_DIR"/skip/*.sh; do
  [ -f "$f" ] || continue
  k="${f##*/}" k="${k%.sh}"
  in_set "$k" "$SKIP_KEYS" || b10_bad="$b10_bad / 名簿の kind=skip に無い鍵の fixture: ${f#"$ROOT"/}"
done

# N12: SessionStart の L4 宣言の通知（3 行。旧名は鍵から組む）
B12_KEY=update-check
B12_STOP=auto-update
B12_GUARD=exit-code
B12_UNKNOWN=no-such-key
B12_ROWS="mixed retired-only guard0"
b12_next() { printf '%s\n' "$1" | grep '^次の一手: ' | tail -n 1; } # 欄の最後の 次の一手 の行
b_notice_worker() { # <行> <副作用系の旧名> <ガードの旧名>
  local row="$1" ns="$2" ng="$3" got wk="$B_DIR/notice/$1" field s nx needle miss="" want
  case "$row" in
    mixed) got="$(b_launch "$FX_DIR/notice/${B12_KEY}.sh" "$wk" 'fx_run; fx_judge' "${ns}=0" "${ng}=1" "FF_DEV_TOOLKIT_SKIP=${B12_KEY},${B12_UNKNOWN}")"; want=PASS ;;
    retired-only) got="$(b_launch "$FX_DIR/notice/${B12_KEY}.sh" "$wk" 'fx_run; fx_judge' "${ns}=0")"; want=STOP ;;
    guard0) got="$(b_launch "$FX_DIR/notice/${B12_KEY}.sh" "$wk" 'fx_run; fx_judge' "${ng}=0" "FF_DEV_TOOLKIT_SKIP=${B12_KEY}")"; want=PASS ;;
  esac
  [ "${got%% *}" = "$want" ] || miss="$miss 更新チェックの判定が ${want} でない（${got}）;"
  for field in .systemMessage .hookSpecificOutput.additionalContext; do
    s="$(jq -r "${field} // \"\"" < "$wk/out" 2>/dev/null)" || s=""
    nx="$(b12_next "$s")"
    case "$row" in
      mixed)
        for needle in "旧名 ${ns} を見つけたので、安全のため ${B12_STOP} を止めています" "FF_DEV_TOOLKIT_SKIP=${B12_STOP}" \
          "旧名 ${ng} は読まなくなりました" "FF_DEV_TOOLKIT_SKIP=${B12_GUARD}" "$B12_UNKNOWN" \
          "止めた層: 宣言" "止めた規則: " "次の一手: "; do
          case "$s" in *"$needle"*) : ;; *) miss="$miss ${field} に「${needle}」が無い;" ;; esac
        done
        case "$nx" in *"FF_DEV_TOOLKIT_SKIP="*"${B12_GUARD}"*) : ;; *) miss="$miss ${field} の次の一手が値 1 のガードの旧名の鍵 ${B12_GUARD} を置き換えに入れない（${nx}）;" ;; esac
        case "$nx" in *"${B12_STOP} を動かすなら"*) : ;; *) miss="$miss ${field} の次の一手に「${B12_STOP} を動かすなら」が無い（${nx}）;" ;; esac
        ;;
      retired-only)
        for needle in "旧名 ${ns} を見つけたので、安全のため ${B12_STOP} を止めています" "FF_DEV_TOOLKIT_SKIP=${B12_STOP}"; do
          case "$s" in *"$needle"*) : ;; *) miss="$miss ${field} に「${needle}」が無い;" ;; esac
        done
        if [ "$field" = .systemMessage ]; then case "$s" in *"📦"*) : ;; *) miss="$miss systemMessage に更新通知（📦）と L4 宣言の通知が並ばない;" ;; esac; fi
        ;;
      guard0)
        case "$s" in *"旧名 ${ng} は読まなくなりました"*) : ;; *) miss="$miss ${field} に「旧名 ${ng} は読まなくなりました」が無い;" ;; esac
        case "$nx" in *"旧名（${ng}）は外す"*) : ;; *) miss="$miss ${field} の次の一手が旧名を外す案内でない（${nx}）;" ;; esac
        case "$nx" in *"${B12_GUARD}"*) miss="$miss ${field} の次の一手が値 0 のガードの旧名で ${B12_GUARD} を止める書き換えを勧める（${nx}）;" ;; esac
        ;;
    esac
  done
  if [ -z "$miss" ]; then printf 'ok\tnotice\t%s\n' "$row"; else printf 'ng\tnotice\t%s\t%s\n' "$row" "$miss"; fi
}
b12_bad=""
i="$(b_row "$B12_KEY" skip)" j="$(b_row "$B12_STOP" skip)" jg="$(b_row "$B12_GUARD" skip)"
if [ -z "$i" ]; then
  b12_bad=" / 名簿に鍵 ${B12_KEY} の kind=skip が無い（通知の表を組めない）"
elif [ -z "$j" ] || [ "${R_RULE[$j]}" != retired-stop ]; then
  b12_bad=" / 名簿に鍵 ${B12_STOP} の kind=skip（retired-stop）が無い（通知の表を組めない）"
elif [ -z "$jg" ] || [ "${R_RULE[$jg]}" != "-" ]; then
  b12_bad=" / 名簿に鍵 ${B12_GUARD} の kind=skip（legacy_value_rule -）が無い（通知の表を組めない）"
elif in_set "$B12_UNKNOWN" "$ALL_KEYS"; then
  b12_bad=" / 名簿に無い鍵のつもりの ${B12_UNKNOWN} が名簿にある"
else
  c="$(b_contract "$FX_DIR/notice/${B12_KEY}.sh" "${R_OWNER[$i]}")"
  if [ -n "$c" ]; then
    b12_bad=" / $(printf '%s' "$c" | tr '\n' ' ')"
  else
    for row in $B12_ROWS; do
      b_bg "$B_DIR/res/notice.${row}" b_notice_worker "$row" "$(retired_name "$B12_STOP")" "$(retired_name "$B12_GUARD" guard)"
    done
  fi
fi
for f in "$FX_DIR"/notice/*.sh; do
  [ -f "$f" ] || continue
  [ "${f##*/}" = "${B12_KEY}.sh" ] || b12_bad="$b12_bad / 通知の表に無い fixture: ${f#"$ROOT"/}"
done

# N14: 止まった回の注記（ガードの旧名だけを置く回 / 何も置かない回の deny の 次の一手 の行）
B14_KEY=exit-code
b_note_worker() { # <ガードの旧名>
  local lg="$1" v got wk reason nextl miss=""
  for v in with without; do
    wk="$B_DIR/note/${B14_KEY}.${v}"
    if [ "$v" = with ]; then
      got="$(b_launch "$FX_DIR/skip/${B14_KEY}.sh" "$wk" 'fx_run; fx_judge' "${lg}=1")"
    else
      got="$(b_launch "$FX_DIR/skip/${B14_KEY}.sh" "$wk" 'fx_run; fx_judge')"
    fi
    [ "${got%% *}" = STOP ] || { miss="$miss ${v}: deny されない（${got}）;"; continue; }
    reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason // ""' < "$wk/out" 2>/dev/null)" || reason=""
    nextl="$(printf '%s\n' "$reason" | grep '^次の一手: ' | tail -n 1)"
    [ -n "$nextl" ] || { miss="$miss ${v}: permissionDecisionReason に 次の一手 の行が無い;"; continue; }
    if [ "$v" = with ]; then
      case "$nextl" in *"FF_DEV_TOOLKIT_SKIP=${B14_KEY}"*) : ;; *) miss="$miss with: 次の一手 の行に FF_DEV_TOOLKIT_SKIP=${B14_KEY} が無い（${nextl}）;" ;; esac
      case "$nextl" in *"$lg"*) : ;; *) miss="$miss with: 次の一手 の行に旧名 ${lg} が無い（${nextl}）;" ;; esac
    else
      case "$nextl" in *"$lg"* | *"旧名 "*) miss="$miss without: 旧名を置かない回の 次の一手 の行に注記がある（${nextl}）;" ;; esac
    fi
  done
  if [ -z "$miss" ]; then printf 'ok\tnote\t%s\n' "$B14_KEY"; else printf 'ng\tnote\t%s\t%s\n' "$B14_KEY" "$miss"; fi
}
b14_bad=""
i="$(b_row "$B14_KEY" skip)"
if [ -z "$i" ] || [ "${R_RULE[$i]}" != "-" ]; then
  b14_bad=" / 名簿に鍵 ${B14_KEY} の kind=skip（legacy_value_rule -）が無い（注記の表を組めない）"
else
  c="$(b_contract "$FX_DIR/skip/${B14_KEY}.sh" "${R_OWNER[$i]}")"
  if [ -n "$c" ]; then b14_bad=" / $(printf '%s' "$c" | tr '\n' ' ')"; else b_bg "$B_DIR/res/note" b_note_worker "$(retired_name "$B14_KEY" guard)"; fi
fi
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
if [ -z "$b10_bad" ]; then ok "N10: 振る舞いの表（kind=skip の $(printf '%s\n' $SKIP_KEYS | grep -c .) 鍵 × 宣言なし=止める / 新しい鍵=素通し / 打ち間違い=止める / 旧名=止める（retired-stop の鍵は旧名=素通し・空の値=止める）。計 ${B_OK} 回）"; else bad "N10: 振る舞いの表の違反${b10_bad}"; fi
if [ -z "$b12_bad" ]; then
  b12_files=""
  for row in $B12_ROWS; do b12_files="$b12_files $B_DIR/res/notice.${row}"; done
  # shellcheck disable=SC2086 # 空白区切りの一覧（パスに空白を含まない一時領域）
  b_collect $b12_files
  b_launches=$((b_launches + B_OK))
  if [ "$B_OK" -ne 3 ] || [ -n "$B_NG" ]; then b12_bad="${B_NG:- / 期待どおりの行が ${B_OK} 件（3 行）}"; fi
fi
if [ -z "$b12_bad" ]; then ok "N12: SessionStart の L4 宣言の通知（mixed / retired-only / guard0 の 3 行）: 両方の欄に 2 種類の文・置き換え・未知の鍵・停止文の 3 行があり、置き換えは値 1 のガードの旧名と副作用系の鍵だけ（値 0 のガードの旧名は外すだけ）・旧名だけの回は更新通知と並ぶ"; else bad "N12: L4 宣言の通知の違反${b12_bad}"; fi
if [ -z "$b14_bad" ]; then
  b_collect "$B_DIR/res/note"
  b_launches=$((b_launches + B_OK * 2))
  if [ "$B_OK" -ne 1 ] || [ -n "$B_NG" ]; then b14_bad="${B_NG:- / 期待どおりの行が無い}"; fi
fi
if [ -z "$b14_bad" ]; then ok "N14: ガードの旧名だけを置いた回の ${B14_KEY} の deny は、次の一手 の行が FF_DEV_TOOLKIT_SKIP=${B14_KEY} と旧名を名指す（置かない回は注記なし）"; else bad "N14: 止まった回の注記の違反${b14_bad}"; fi
echo "  ℹ️  振る舞いの表: 期待どおりの起動 ${b_launches} 回・$((b_t1 - b_t0)) 秒（${B_PAR} 本ずつ並べる）"

REACHED_END=1
echo ""
echo "l4-declarations: pass=${PASS} fail=${FAIL}"
[ "$FAIL" -eq 0 ]
