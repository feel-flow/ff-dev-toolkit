#!/usr/bin/env bash
# ACE候補の容量不足時の保存・再評価後の消し込み（Issue `#2040`）。
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
ff_assert_script_plugin_root "${BASH_SOURCE[0]}" || exit 3
# ff-dev-toolkit-script-root-guard:end
set -euo pipefail

die() { printf 'ACE pending: %s\n' "$2" >&2; exit "$1"; }
command="${1:-}"; [ "$#" -gt 0 ] && shift || :
case "$command" in status|defer|resolve) ;; *) die 1 'status / defer / resolveを指定してください' ;; esac
playbook=""; id=""; category=""; origin=""; title=""; body_file=""
report=""; gate_rc=""; proposed=""; capacity_category=""; decision=""; result=""
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || die 1 'optionの値がありません'
  case "$1" in
    --playbook) playbook="$2" ;; --id) id="$2" ;; --category) category="$2" ;;
    --origin) origin="$2" ;; --title) title="$2" ;; --body-file) body_file="$2" ;;
    --capacity-report) report="$2" ;; --capacity-rc) gate_rc="$2" ;; --proposed) proposed="$2" ;;
    --capacity-category) capacity_category="$2" ;;
    --decision) decision="$2" ;; --result) result="$2" ;;
    *) die 1 "不明なoption: $1" ;;
  esac
  shift 2
done
case "$playbook" in /*) ;; *) die 1 '--playbookは絶対pathで指定してください' ;; esac
[ -f "$playbook" ] && [ -r "$playbook" ] || die 2 'PLAYBOOKを読めません'
base="$(CDPATH='' cd -P -- "${playbook%/*}" && pwd -P)" || die 2 '配置先を解決できません'
pending="$base/PENDING_CANDIDATES.md"
script_dir="$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}" && pwd -P)" || die 2 'script配置を解決できません'
library="$script_dir/lib/ace-pending-functions.sh"
[ -f "$library" ] && [ -r "$library" ] && [ ! -L "$library" ] || die 2 '候補parserがありません'
# shellcheck source=lib/ace-pending-functions.sh
. "$library"

status() {
  local count=0
  if [ -e "$pending" ] || [ -L "$pending" ]; then
    ff_ace_pending_validate "$pending" || exit 2
    count="$(ff_ace_pending_count "$pending")" || exit 2
  fi
  printf 'PENDING_FILE=%s\nPENDING_COUNT=%s\n' "$pending" "$count"
}
if [ "$command" = status ]; then status; exit 0; fi
[[ "$id" =~ ^PENDING-(PR|ISSUE)-[1-9][0-9]*-[1-9][0-9]*$ ]] || die 1 '候補IDが不正です'
for value in "$title" "$origin" "$result"; do
  case "$value" in *$'\n'*|*$'\r'*|*$'\t'*|*'|'*) die 1 'metaには改行・tab・縦線を使えません' ;; esac
done
if [ "$command" = defer ]; then
  [[ "$category" =~ ^[a-z][a-z0-9-]*$ ]] || die 1 'Categoryが不正です'
  [[ "$proposed" =~ ^[0-9]+$ ]] || die 1 '--proposedに停止カテゴリの追加予定数を指定してください'
  [ -n "$title" ] && [ -n "$origin" ] || die 1 'タイトルとOriginが必要です'
  [ -f "$body_file" ] && [ -r "$body_file" ] || die 2 '候補本文を読めません'
  awk '/[^[:space:]]/ { found=1 } END { exit found ? 0 : 1 }' "$body_file" || die 2 '候補本文が空です'
  # 実行全体を止めたカテゴリを根拠に、容量内カテゴリの未処理候補も保全する。
  capacity_category="${capacity_category:-$category}"
  [[ "$capacity_category" =~ ^[a-z][a-z0-9-]*$ ]] || die 1 '停止カテゴリが不正です'
  capacity="$(ff_ace_pending_capacity "$report" "$capacity_category" "$proposed" "$gate_rc")" || exit 2
  IFS=' ' read -r current limit <<<"$capacity"
  # 算術はawk側で行う。shell整数の桁あふれを容量内へ読み替えない。
  if awk -v n="$current" -v add="$proposed" -v max="$limit" 'BEGIN { exit (n + add <= max) ? 0 : 1 }'; then
    printf 'PENDING_DEFERRED=0\nPENDING_REASON=capacity-available\n'; exit 0
  fi
else
  case "$decision" in added|reused|rejected) ;; *) die 1 '解決結果added/reused/rejectedが必要です' ;; esac
  [ -n "$result" ] || die 1 '解決先ACE IDまたは棄却理由が必要です'
  if [ "$decision" != rejected ]; then
    # ID文法を別定義せず、既存lookupの実在active ACEとの完全一致で検証する。
    [[ "$result" == ACE-* ]] || die 1 '解決先のACE IDが不正です'
    lookup="$script_dir/knowledge-lookup.sh"
    [ -f "$lookup" ] && [ -r "$lookup" ] && [ ! -L "$lookup" ] || die 2 '解決先ACEを検索できません'
    resolved="$(bash "$lookup" --root "$base" --playbook "$playbook" --offline --format tsv "$result")" || die 2 '解決先ACEの検索が成立しません'
    if ! printf '%s\n' "$resolved" | awk -F '\t' -v id="$result" '$1=="ace" && $2==id && $3=="active" { found=1 } END { exit found ? 0 : 1 }'; then
      die 1 '解決先のactiveなACEがありません（保留を保持します）'
    fi
  fi
fi

lock="$pending.lock"; scratch=""
mkdir -- "$lock" 2>/dev/null || die 2 '別の候補更新が進行中か、配置先へ書けません'
cleanup() { [ -z "$scratch" ] || rm -rf -- "$scratch"; rmdir -- "$lock"; }
trap cleanup EXIT
trap 'exit 2' HUP INT TERM
scratch="$(mktemp -d "$base/.ace-pending.XXXXXX")" || die 2 '一時領域を作れません'
if [ -e "$pending" ] || [ -L "$pending" ]; then
  ff_ace_pending_validate "$pending" || exit 2
  cp -- "$pending" "$scratch/current" || die 2 '既存候補を読み出せません'
else
  [ "$command" = defer ] || die 1 '保留候補がありません'
  printf '<!-- ff-ace-pending:v1 -->\n# ACE 保留候補\n\n## エントリ一覧\n\n' >"$scratch/current"
fi
ff_ace_pending_entry "$scratch/current" "$id" >"$scratch/existing"
if [ "$command" = defer ]; then
  {
    printf '### %s: %s\n| Category | %s |\n| Origin | %s |\n| Status | pending |\n\n' "$id" "$title" "$category" "$origin"
    awk '{ print "> " $0 }' "$body_file"
    printf '\n---\n'
  } >"$scratch/entry"
  if [ -s "$scratch/existing" ]; then
    cmp -s "$scratch/existing" "$scratch/entry" || die 1 '同じ候補IDに異なる内容があります（上書きしません）'
    printf 'PENDING_DEFERRED=0\nPENDING_REASON=already-present\n'; status; exit 0
  fi
  cat "$scratch/current" "$scratch/entry" >"$scratch/next"
else
  [ -s "$scratch/existing" ] || die 1 '指定された候補IDがありません'
  awk -v wanted="$id" '
    /^### / { id = $0; sub(/^### /, "", id); sub(/:.*/, "", id); drop = (id == wanted) }
    !drop { print }
    drop && $0 == "---" { drop = 0 }
  ' "$scratch/current" >"$scratch/next"
fi
ff_ace_pending_validate "$scratch/next" || exit 2
mv -- "$scratch/next" "$pending" || die 2 '候補ファイルを保存できません'
if [ "$command" = defer ]; then printf 'PENDING_DEFERRED=1\n'; else printf 'PENDING_RESOLVED=%s\nPENDING_RESULT=%s\n' "$decision" "$result"; fi
status
