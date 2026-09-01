#!/usr/bin/env bash
#
# Issue 本文の更新差分が、許可された範囲に収まっているかを判定する。
#
# /close-issue 手順 5b が本文を送信する前に呼ぶ。もとは「チェックボックス以外の
# 変更がないこと」という散文の規約だったが、工数実績ブロックの書き戻しを許すため
# 条件を緩めた。緩めた安全条件を散文で守ろうとすると守れないので、述語を機械で
# 判定する（発動しないゲートは無いゲートと同じ）。
#
# 判定する述語: 変更行はすべて次のいずれかであること
#   (a) チェックボックスの【状態のみ】が変わった行（"- [ ]" ⇄ "- [x]"）。
#       同じ行のラベル本文が変わっていれば違反
#   (b) ff-effort の begin マーカー行と end マーカー行に【挟まれた】行
# マーカー行そのものの変更・削除、および 1 組ではないマーカー構成（順序逆転・
# 複数組・片側欠落・未閉鎖）は検査不成立として exit 2 で拒否する。
#
# 順序を検査するのが要点。件数の一致は「対応」ではない — end が begin より前に
# ある本文は nb=1/ne=1 で件数は揃うが、begin 以降が EOF まで不可視になり、
# マーカーの【外】にある末尾本文を無制限に編集できてしまう（レビューで実測）。
#
# 実装は「許可領域だけをマスクして一致を見る」方式。許可された変更はマスクで
# 消え、許可されていない変更だけが差分として残る。マーカー行は境界タグへ置換
# するので、変更・削除すればマスク上で必ず区別される。
#
# 使い方: check-issue-body-diff.sh <変更前の本文> <変更後の本文>
#   exit 0 … 許可範囲内
#   exit 1 … 許可範囲外の変更（理由を stderr に出す）
#   exit 2 … 検査が成立しない（マーカー構成の破損・入力の異常・道具の失敗）
#
set -uo pipefail

BEGIN_MARK='<!-- ff-effort:begin -->'
END_MARK='<!-- ff-effort:end -->'

die_unverifiable() { echo "✗ $1（検査は成立していない）" >&2; exit 2; }

if [ $# -ne 2 ]; then
  echo "Usage: check-issue-body-diff.sh <old-body-file> <new-body-file>" >&2
  exit 2
fi

OLD="$1"
NEW="$2"
for f in "$OLD" "$NEW"; do
  [ -f "${f}" ] || die_unverifiable "ファイルが見つかりません: ${f}"
done

# baseline の健全性を検査する。この判定器の比較対象は、検査される側（エージェント）が
# 用意する。先に本文を編集してから baseline へコピーすると 2 ファイルが同一になり、
# 検査は 1 バイトも仕事をしないまま exit 0 を返す。述語だけでなく【述語の入力】にも
# fail-closed が要る。
[ -s "$OLD" ] || die_unverifiable "変更前の本文が空です: ${OLD}"
[ -s "$NEW" ] || die_unverifiable "変更後の本文が空です: ${NEW}"
if cmp -s "$OLD" "$NEW"; then
  die_unverifiable "変更前と変更後が同一です（baseline が編集後のコピーになっていないか確認すること）"
fi

# マーカー構成の健全性。件数ではなく【順序を含む対応】を検査する。
# 認めるのは「0 組」または「begin の後に end が 1 回」だけ。
marker_sanity() { # <file> → 0:健全 1:壊れている
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    {
      line = $(0); sub(/\r$/, "", line)
      if (line == b) {
        if (nb > 0 || ne > 0) exit 1   # 2 組目、または end 先行
        nb++; open = 1
      } else if (line == e) {
        if (open != 1) exit 1          # begin より前、または 2 組目
        ne++; open = 0
      }
    }
    END { if (open == 1) exit 1        # 未閉鎖（begin のみ）
          if (nb != ne) exit 1
          exit 0 }
  ' "$1"
}

for f in "$OLD" "$NEW"; do
  marker_sanity "${f}" \
    || die_unverifiable "ff-effort マーカーの構成が不正です: ${f}（begin の後に end が 1 回、または 0 組であること）"
done

# 許可領域をマスクする。
#   - マーカーに挟まれた本文 → 1 行のタグへ畳む（行数の増減を吸収する）
#   - チェックボックスの状態 → 未チェックへ正規化する（ラベル本文はそのまま残す）
#
# 各行に型タグを付けるのは、本文が畳み込みの目印と同じ文字列を含むときに実ブロックと
# 通常行を取り違える余地を構造的に無くすため（hardening であって、既知の穴の修正では
# ない — タグ無しの実装を突く入力は見つけられなかった）。タグは awk が付けるので
# 本文からは偽装できず、マスクの語彙と利用者の本文が交わらない。
#   L<TAB>… … ブロック外の通常行
#   B / E    … マーカー行（境界そのもの。変更・削除すればタグが消えて必ず差分になる）
#   P        … マーカーに挟まれた本文を畳んだ 1 行
mask() { # <file> → マスク済み本文を stdout
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    {
      line = $(0); sub(/\r$/, "", line)
      if (line == b) { print "B"; print "P"; inblock = 1; next }
      if (line == e) { inblock = 0; print "E"; next }
      if (inblock) next
      if (match(line, /^[ \t]*[-*+] \[[xX]\]/)) {
        head = substr(line, 1, RSTART + RLENGTH - 1)
        rest = substr(line, RSTART + RLENGTH)
        sub(/\[[xX]\]$/, "[ ]", head)
        line = head rest
      }
      print "L\t" line
    }
    END { if (inblock) exit 1 }
  ' "$1"
}

MASKED_OLD="$(mktemp)" || die_unverifiable "一時ファイルを作成できません"
MASKED_NEW="$(mktemp)" || { rm -f "$MASKED_OLD"; die_unverifiable "一時ファイルを作成できません"; }
trap 'rm -f "$MASKED_OLD" "$MASKED_NEW"' EXIT

mask "$OLD" > "$MASKED_OLD" || die_unverifiable "変更前本文のマスクに失敗しました"
mask "$NEW" > "$MASKED_NEW" || die_unverifiable "変更後本文のマスクに失敗しました"

# diff の終了コードは 0=一致 / 1=差分 / 2 以上=ツールの異常。
# 2 以上を「差分あり」に畳むと、道具の故障が「違反」と誤診され、呼び出し側は
# 直しようのない書き換えを繰り返す。三値で分ける。
DIFF_OUT="$(diff -u "$MASKED_OLD" "$MASKED_NEW" 2>&1)"
DIFF_RC=$?
case "$DIFF_RC" in
  0) exit 0 ;;
  1) ;;
  *) printf '%s\n' "$DIFF_OUT" >&2
     die_unverifiable "diff の実行に失敗しました（rc=${DIFF_RC}）" ;;
esac

echo "✗ 許可範囲外の変更が含まれています（チェックボックスの状態変更と、ff-effort マーカーに挟まれた本文だけが許可されます）" >&2
echo "--- 許可領域をマスクしたうえで残った差分 ---" >&2
printf '%s\n' "$DIFF_OUT" >&2
exit 1
