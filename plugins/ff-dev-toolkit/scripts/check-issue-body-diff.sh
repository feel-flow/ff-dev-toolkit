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

# ff-dev-toolkit-script-root-guard:start
# plugin root 固定ガード（script 側）。同じ停止を skill 本文の契約節も述べているが、
# ホストが実行部だけを解決済み絶対 path として注入し契約節が本文から落ちた経路では、
# 散文のガードはちょうどそのとき手元に無い（防御が守ろうとしている失敗と、防御が
# 失われる条件が同じ）。実行部と同じファイルへ置くことで、契約を読んでいない consumer
# でも止まる。**候補は探しに行かない** — cache / marketplace / 旧インストール領域の
# 走査も version 名の並べ替えによる選び直しもしない。それが本ガードの防ごうとしている
# 失敗そのもので、探索を足すと防御が防御対象を踏む。渡された handoff を canonical 化
# して自分の実体位置と比べるだけにする。handoff が 1 つも無い直接起動（端末・テスト・
# CI の pin 実行）は止めない — 比較対象が無い状態を不一致とみなすと、正規の直接起動が
# 全部止まる。
#
# 到達性は呼び出し側とセットで成り立つ。host は plugin root を Bash tool の環境へ
# export せず、実行部テキストへ解決済みの値を差し込むだけなので、handoff を運ぶのが
# skill 本文の resolver だけだと「本文が落ちた」ちょうどそのときに handoff も消え、
# ガードは比較対象なしで素通しになる。そこで固定 root 経由の実行部は
# `FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/<名>"`
# の形にして handoff を**同じ 1 行へ**載せる。実行するスクリプトの path だけを別領域へ
# 書き換える事故は、この 1 行の中の不一致として検出できる。
#
# 判定不能は素通しではなく停止に倒す（fail-closed）。更新中の部分的な消失では、
# 判定材料（別 plugin かどうかを言う manifest）そのものが壊れた領域の内側にある。
#
# 外部コマンドを使わない。PATH が壊れた環境はこのガードが最後の砦になる場面そのもので、
# dirname / grep / sed に依存すると「自分の位置を判定できないまま素通し」になる。
# その代わり builtin 側の環境依存を自分で閉じる: path の canonical 化はすべて
# `CDPATH= cd -P --` で行う。`cd` は CDPATH が効くと**別のdirectoryへ移動したうえで
# 移動先を stdout へ出す**ので、export された CDPATH に同名の subdirectory があると
# 相対起動（`bash scripts/<名>`）で自分の位置を取り違え、コマンド置換も 2 行になる。
# 「止めない」と明文で約束している端末・テスト・CI の直接起動が、正規の handoff 付き
# でも止まっていた。各 script の複製は byte 一致で、tests/plugin-root-contract が固定する。
ff_script_root_guard_manifest_field() { # <plugin.json> <キー> → 値をstdoutへ / 読めなければ非0
  # JSON を「文字列の外 / 中」に分けて走査し、**root object 直下（ネスト深さ 1）のキー**
  # だけを返す。行単位に最初の `"<キー>"` を拾う形だと、`author` のような入れ子 object が
  # top-level の `name` より前にある manifest で `author.name` を掴み、別 plugin と誤読して
  # 照合ごと飛ばす（= fail-open）。同じ判定を docs-template の resolver fence の awk も
  # 「`{` 直後の name marker」として要求しており、厳しさを揃える。fence と違って version も
  # 読むので「最初のキー」ではなく「深さ 1 のキー」に寄せる。
  local file="$1" key="$2" line="" rest="" seg="" tmp="" acc=""
  local depth=0 instr=0 expect=0 last="" bs=0
  # symlink・非通常ファイル・読めないものは「確認できない」に倒す（除外の根拠にしない）。
  [ -f "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    rest="$line"
    while [ -n "$rest" ]; do
      if [ "$instr" -eq 1 ]; then
        case "$rest" in
          *'"'*) seg="${rest%%'"'*}"; rest="${rest#*'"'}" ;;
          *) acc="${acc}${rest}"; rest=""; continue ;;
        esac
        # 直前が奇数個の backslash なら、その `"` は escape されていて文字列は続く。
        tmp="$seg"; bs=0
        while [ "${tmp%\\}" != "$tmp" ]; do bs=$((bs + 1)); tmp="${tmp%\\}"; done
        acc="${acc}${seg}"
        if [ $((bs % 2)) -eq 1 ]; then acc="${acc}\""; continue; fi
        instr=0
        if [ "$expect" -eq 1 ]; then printf '%s' "$acc"; return 0; fi
        last="$acc"; acc=""
        continue
      fi
      case "$rest" in
        *'"'*) seg="${rest%%'"'*}"; rest="${rest#*'"'}"; instr=1; acc="" ;;
        *) seg="$rest"; rest="" ;;
      esac
      # 深さは文字列の外に出た構造文字だけで数える（値の中の括弧に釣られない）。
      tmp="$seg"
      while [ "${tmp#*'{'}" != "$tmp" ]; do depth=$((depth + 1)); tmp="${tmp#*'{'}"; done
      tmp="$seg"
      while [ "${tmp#*'['}" != "$tmp" ]; do depth=$((depth + 1)); tmp="${tmp#*'['}"; done
      tmp="$seg"
      while [ "${tmp#*'}'}" != "$tmp" ]; do depth=$((depth - 1)); tmp="${tmp#*'}'}"; done
      tmp="$seg"
      while [ "${tmp#*']'}" != "$tmp" ]; do depth=$((depth - 1)); tmp="${tmp#*']'}"; done
      case "$seg" in
        *:*) if [ "$depth" -eq 1 ] && [ -n "$last" ] && [ "$last" = "$key" ]; then expect=1; fi ;;
      esac
      # 値が object / array なら、次に閉じる文字列はその中身であって値ではない。
      case "$seg" in
        *'{'*|*'['*|*,*) expect=0 ;;
      esac
      last=""
    done
  done < "$file"
  return 1
}
ff_assert_script_plugin_root() {
  local self="${1:-}" dir="" root="" var="" value="" canonical="" used="" skipped="" other="" version="" quiet=0
  [ -n "$self" ] || { echo "❌ 起動したスクリプトの実体位置を取得できません" >&2; return 1; }
  case "$self" in */*) dir="${self%/*}" ;; *) dir="." ;; esac
  dir="$(CDPATH= cd -P -- "$dir" 2>/dev/null && pwd -P)" || dir=""
  [ -n "$dir" ] || { echo "❌ 起動したスクリプトのdirectoryを解決できません: ${self}" >&2; return 1; }
  root="$(CDPATH= cd -P -- "${dir}/.." 2>/dev/null && pwd -P)" || root=""
  [ -n "$root" ] || { echo "❌ 自分のplugin rootを解決できません: ${dir}" >&2; return 1; }
  self="${dir}/${self##*/}"
  # スクリプト自身がsymlinkなら止める。親directoryしかcanonical化しないと、期待root内の
  # symlinkから別checkoutの実体を実行でき、「実体位置とhandoffの照合」の前提が崩れる。
  if [ -L "$self" ]; then
    {
      echo "❌ ff-dev-toolkit更新後にこのskillを再呼び出してください（起動したスクリプトがsymlinkです）"
      echo "   起動したスクリプト: ${self}"
      echo "   symlinkは期待rootの内側から別領域の実体を指せるため、実体位置の照合が成立しません。"
      echo "   別のインストール領域へ切り替えて実行しないこと — version混在と未リリースWIPの実行になります。"
      echo "   cacheや別checkoutを探さず、実体のパスで起動してください。"
    } >&2
    return 1
  fi
  for var in FF_DEV_TOOLKIT_ROOT CLAUDE_PLUGIN_ROOT GROK_PLUGIN_ROOT; do
    eval "value=\${${var}:-}"
    [ -n "$value" ] || continue
    canonical="$(CDPATH= cd -P -- "$value" 2>/dev/null && pwd -P)" || canonical=""
    # 正規形は plugin root だが、scripts/ を直接指す綴りも正規に受理されている
    # （templates/codex-review.sh の canonical_toolkit_root が両方を受ける）。同じ実体を
    # 指している限り一致として扱う。
    if [ -n "$canonical" ] && { [ "$canonical" = "$root" ] || [ "$canonical" = "$dir" ]; }; then
      [ -n "$used" ] || used="$var"
      continue
    fi
    # 実在する別 plugin の root は我々への handoff ではない（別 plugin 経由の正規呼び出し
    # まで殺さない）。ただし除外できるのは「manifestが通常ファイルとして読めて、名前が別だと
    # 確認できた」ときだけにする。消えているroot も、読めないmanifest も、誰のものか判定
    # できない点は同じ。
    other=""
    if [ -n "$canonical" ]; then
      other="$(ff_script_root_guard_manifest_field "${canonical}/.claude-plugin/plugin.json" name)" || other=""
    fi
    if [ -n "$other" ] && [ "$other" != "ff-dev-toolkit" ]; then
      skipped="${skipped:+${skipped} }${var}=別plugin(${other})"
      continue
    fi
    {
      echo "❌ ff-dev-toolkit更新後にこのskillを再呼び出してください（plugin rootが固定値と一致しません）"
      echo "   起動したスクリプト: ${self}"
      echo "   このスクリプトのplugin root: ${root}"
      echo "   hostが渡したroot（${var}）: ${value}"
      if [ -z "$canonical" ]; then
        echo "   不一致の内容: 指しているdirectoryが実在しません（plugin rootが消えています）"
      elif [ -z "$other" ]; then
        echo "   不一致の内容: 指す先のplugin manifestを読めず、誰のrootか判定できません（判定不能は停止に倒します）"
      else
        echo "   不一致の内容: このスクリプトは別のインストール領域の実体です"
      fi
      echo "   別のインストール領域へ切り替えて実行しないこと — version混在と未リリースWIPの実行になります。"
      echo "   cacheや別checkoutを探さず、pluginを再導入してからskillを呼び直してください。"
    } >&2
    return 1
  done
  # provenance（実体 path と version の 1 行）は「想定外の場所から起動された」ことを
  # agent にもログを読む人にも見せて診断コストを下げる。照合を飛ばした handoff も理由付きで
  # 出す — 渡っていた事実を「なし・直接起動」と報告すると、診断価値を損ない事実とも食い違う。
  # 出力そのものが契約になっている script（成功時は無出力・stderr を混ぜない等）では情報行が
  # 契約違反になるので、その basename だけを**この block 内の allowlist**で抑止する。
  # 外から env で抑止できる形にすると allowlist が実効的な制約にならないので、環境変数では
  # 抑止できない。抑止できるのは provenance だけで、停止の判定と案内は抑止できない。
  case "${self##*/}" in
    check-merge-freshness.sh|check-plugin-versions.sh) quiet=1 ;;
  esac
  if [ "$quiet" -ne 1 ]; then
    version="$(ff_script_root_guard_manifest_field "${root}/.claude-plugin/plugin.json" version)" || version=""
    echo "ℹ️  ff-dev-toolkit ${version:-version不明} — 実行実体: ${self}（handoff: ${used:-なし・直接起動}${skipped:+ / 照合対象外: ${skipped}}）" >&2
  fi
  return 0
}
ff_assert_script_plugin_root "${BASH_SOURCE[0]}" || exit 2
# ff-dev-toolkit-script-root-guard:end
# 中断コードは本スクリプトの契約の 2（検査が成立しない）。ガードの停止も検査不成立なので
# 同じ扱いにする。1（許可範囲外の変更）へ寄せると「違反を見つけた」と誤読される。

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
