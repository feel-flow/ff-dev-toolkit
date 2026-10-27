#!/usr/bin/env bash
#
# review-route.sh — 決定木の根（decision-tree/route.sh）の答えを、レビューのレーン構成と
# 完了報告の 1 行へ写す（変更クラス別のレーン数）。判定は根に任せ、ここでは再実装しない（写像だけを
# 持つ）。REVIEW_ROUTE は multi-review.sh の `--route` へ渡すとレーン構成に反映される。
#
# 使い方:
#   review-route.sh [route.sh の引数...]    … 引数なしは `--git`（cwd の差分。--base で基点を指定）
#   例: review-route.sh --git --base origin/develop
#       review-route.sh --files docs/a.md --lines 12
#
# 出力（stdout。行頭一致で機械可読）:
#   route.sh の DT_* 行をそのまま通したうえで、次の 4 行を足す:
#   REVIEW_ROUTE=fast|full|none
#   REVIEW_LANES=parent-read+codex:1 | codex:1+claude:4 | host
#       fast … 親（オーケストレータ）が diff を直読し、Codex を 1 レーンだけ起動する（Claude の
#              4 観点は起動しない）
#       full … 現行の 5 レーン（Codex 1 + Claude 4 観点）
#       none … レーン構成をホストが判定する（判定理由を完了報告へ 1 行で添える）
#   REVIEW_REQUIRED_PERSPECTIVES=comma-separated admission coverage (none: empty)
#   REVIEW_REPORT_LINE=経路: <route>（根拠: <理由> / <N> 行）
#       <理由> は DT_REASON の写像（docs-only → docs のみ / small-diff → 小さい差分 /
#       contract-change:<path> → 契約 path <path> / implementation → 実装変更 / no-files → 変更 0 件 /
#       jev-* → Jev の判定・失敗 / error:* → 判定不能）。行数が取れない回は「行数不明」
#   続けて、セキュリティに関わる変更の専用ゲート（規定の正本は docs-template の self-review.md
#   「レビュー担当の選択と利用制限時の継続」の専用セキュリティゲート項）を出す:
#   REVIEW_SECURITY_SENSITIVE=yes|no|unknown   … 根の DT_SECURITY（設定を読めない回は unknown）
#   REVIEW_SECURITY_EVIDENCE=<path>            … yes の根拠（1 行 1 path）
#   REVIEW_PRIMARY_HOST=claude-code|grok-cli|unknown … CLAUDECODE=1 / GROK_AGENT から判定（両方・
#       どちらも無い回は unknown。Codex を判定する手段は無いので unknown になる）
#   REVIEW_SECURITY_BASE_CHECK=match|mismatch|no-origin-head|unchecked
#       /security-review は origin/HEAD を基点に固定するので、差分モードの base と照合する
#       （--files / --files-from は base を持たないので unchecked）
#   REVIEW_SECURITY_GATE=security-review|unverified|unsupported|off|none
#       security-review … 主担当 claude-code が通常のレビューに加えて /security-review を実行する
#       unverified      … 主担当 claude-code だが基点（指すコミット）が食い違う / origin/HEAD が無い、または
#                         決定木のルータが無く何も判定できない。走らせず未確認と記録する
#       unsupported     … 主担当が claude-code 以外。専用ゲートは未対応として記録する（省略しない）
#       off             … security_review=off（判定は出すが専用ゲートを起動しない）
#       none            … 該当なし（unknown は no へ倒さず、yes と同じくゲートの対象にする）
#   REVIEW_SECURITY_REPORT_LINE=専用セキュリティゲート: …   … PR の Self-Review 欄へ転記する判定の 1 行
#
# 設定（フィールド単位に env > プロジェクト設定 > 既定。プロジェクト設定は MULTI_AGENT_CONFIG、
# 無ければ <repo>/.claude/agent-config.yaml の review 配下。ユーザー設定の層は持たない — path の
# パターンはリポジトリごとの事実なので、利用者単位で共有する意味が無い）:
#   MULTI_AGENT_SECURITY_GLOB       / review.security_glob       … security-glob の既定を置き換える
#   MULTI_AGENT_SECURITY_GLOB_EXTRA / review.security_glob_extra … security-glob へ追加する
#   MULTI_AGENT_SECURITY_REVIEW     / review.security_review     … auto（既定）| off
#   パターンは空白区切りの 1 文字列（YAML リストは不可）。env を空で設定した回は未設定として下位層へ
#   落ちる。設定を読めない回（MULTI_AGENT_CONFIG で明示したファイルが無い・読めない・yq が無い・
#   文字列でない / 空の値・未知の値・review 配下以外に 1 つでも置かれた security_* キー）は該当なしへ
#   倒さず REVIEW_SECURITY_SENSITIVE=unknown と理由を出す。
#
# 終了コード: route.sh と同じ（0 = 判定した〈none を含む〉/ 2 = 判定不能 / 64 = 使い方の誤り）と、
#   3 = plugin root ガードの停止（2 は判定不能に使っているので別の番号にする）。
#   2 のときも REVIEW_ROUTE=none を出す（黙って full / fast へ倒さない）。
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
ff_assert_script_plugin_root "${BASH_SOURCE[0]}" || exit 3
# ff-dev-toolkit-script-root-guard:end


SCRIPT_DIR="$(CDPATH= cd -P -- "$(dirname "$0")" && pwd -P)"
ROUTER="$SCRIPT_DIR/decision-tree/route.sh"

if [ $# -eq 0 ]; then
  set -- --git
fi
case "$1" in
  -h | --help)
    sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac
# ルータが無い回も判定不能（2）として none を出す（黙って full / fast へ倒さない。ヘッダの契約）
if [ ! -f "$ROUTER" ]; then
  echo "✗ review-route: 決定木のルータがありません: $ROUTER" >&2
  echo "REVIEW_ROUTE=none"
  echo "REVIEW_LANES=host"
  echo "REVIEW_REPORT_LINE=経路: none（根拠: 判定不能（決定木のルータがありません） / 行数不明）"
  # 分類も根が持つので出せない。該当なしへ倒さず unknown にする（主担当の判定はしない）
  echo "REVIEW_SECURITY_SENSITIVE=unknown"
  echo "REVIEW_PRIMARY_HOST=unknown"
  echo "REVIEW_SECURITY_BASE_CHECK=unchecked"
  echo "REVIEW_SECURITY_GATE=unverified"
  echo "REVIEW_SECURITY_REPORT_LINE=専用セキュリティゲート: 未確認（判定不能: 決定木のルータがありません）"
  exit 2
fi

# ---- 専用セキュリティゲートの設定（env > プロジェクト設定 > 既定）------------------------
SEC_CONFIG_ERROR=""
SEC_GLOB_VALUE=""; SEC_GLOB_FROM=""
SEC_EXTRA_VALUE=""; SEC_EXTRA_FROM=""
SEC_POLICY=""; SEC_POLICY_FROM=""
[ -z "${MULTI_AGENT_SECURITY_GLOB:-}" ] || { SEC_GLOB_VALUE="$MULTI_AGENT_SECURITY_GLOB"; SEC_GLOB_FROM="env"; }
[ -z "${MULTI_AGENT_SECURITY_GLOB_EXTRA:-}" ] || { SEC_EXTRA_VALUE="$MULTI_AGENT_SECURITY_GLOB_EXTRA"; SEC_EXTRA_FROM="env"; }
[ -z "${MULTI_AGENT_SECURITY_REVIEW:-}" ] || { SEC_POLICY="$MULTI_AGENT_SECURITY_REVIEW"; SEC_POLICY_FROM="env"; }

SEC_CONFIG="${MULTI_AGENT_CONFIG:-}"
SEC_CONFIG_EXPLICIT=0
[ -z "$SEC_CONFIG" ] || SEC_CONFIG_EXPLICIT=1
if [ -z "$SEC_CONFIG" ]; then
  sec_top="$(git rev-parse --show-toplevel 2>/dev/null)" || sec_top=""
  [ -z "$sec_top" ] || SEC_CONFIG="${sec_top}/.claude/agent-config.yaml"
fi
# 読む設定キーの名簿。キーの所在は yq で文書全体と review 配下の両方を数える — 行頭一致の grep だと
# フロー形式（review: {security_glob_extra: …}）や引用付きキーを見落とし、書いたパターンが黙って効かない
SEC_KEYS="security_glob security_glob_extra security_review"
SEC_KEY_RE='^security_(glob|glob_extra|review)$'
sec_read_key() { # <キー> → stdout: 値（null は空）。rc 1 = 文字列でない
  local tag
  tag="$(yq -r ".review.$1 | tag" "$SEC_CONFIG" 2>/dev/null)" || return 2
  case "$tag" in
    '!!null') return 0 ;;
    '!!str') ;;
    *) return 1 ;;
  esac
  # yq の `//` は false を「無い」扱いにするので使わない（ACE-1608-1）。tag で文字列だけを通している
  yq -r ".review.$1" "$SEC_CONFIG" 2>/dev/null || return 2
}
if [ -n "$SEC_CONFIG" ] && [ ! -e "$SEC_CONFIG" ]; then
  # 既定の置き場が無いのは「設定なし」。明示した設定ファイルが無いのは指定の誤りで、既定へ戻さない
  [ "$SEC_CONFIG_EXPLICIT" -eq 0 ] || SEC_CONFIG_ERROR="MULTI_AGENT_CONFIG の設定ファイルがありません: ${SEC_CONFIG}"
elif [ -n "$SEC_CONFIG" ]; then
  if [ ! -f "$SEC_CONFIG" ] || [ ! -r "$SEC_CONFIG" ]; then
    SEC_CONFIG_ERROR="プロジェクト設定を読めません: ${SEC_CONFIG}"
  elif ! command -v yq >/dev/null 2>&1; then
    # yq が無いと形式を問わずキーを読めない。コメント行以外に名前が現れれば読めないものとして扱う
    # （awk の失敗〈rc 2 以上〉も「キーが無い」と読まない）
    sec_awk_rc=0
    awk '!/^[[:space:]]*#/ && /security_(glob|glob_extra|review)/ { f = 1 } END { exit f ? 0 : 1 }' "$SEC_CONFIG" 2>/dev/null || sec_awk_rc=$?
    case "$sec_awk_rc" in
      0) SEC_CONFIG_ERROR="yq が無いため ${SEC_CONFIG} の security_* キーを読めません" ;;
      1) : ;;
      *) SEC_CONFIG_ERROR="プロジェクト設定の security_* キーを検査できません（awk rc=${sec_awk_rc}）: ${SEC_CONFIG}" ;;
    esac
  else
    sec_all="$(yq -r "[.. | select(tag == \"!!map\") | keys | .[] | select(test(\"${SEC_KEY_RE}\"))] | length" "$SEC_CONFIG" 2>/dev/null)" || sec_all=""
    sec_in_review="$(yq -r "[.review | select(tag == \"!!map\") | keys | .[] | select(test(\"${SEC_KEY_RE}\"))] | length" "$SEC_CONFIG" 2>/dev/null)" || sec_in_review=""
    case "${sec_all}:${sec_in_review}" in
      *[!0-9:]* | :* | *:) SEC_CONFIG_ERROR="${SEC_CONFIG} を yq で読めません" ;;
    esac
    # review 配下以外（tasks.review 等）に 1 つでもあれば置き場の違い。review 配下の別キーと併記されて
    # いても、そのキーは黙って無視されるので通さない
    if [ -z "$SEC_CONFIG_ERROR" ] && [ "$sec_all" != "$sec_in_review" ]; then
      SEC_CONFIG_ERROR="security_* キーが review 配下以外にあります（review.security_glob 等に置く）: ${SEC_CONFIG}"
    fi
    if [ -z "$SEC_CONFIG_ERROR" ] && [ "$sec_in_review" -gt 0 ]; then
      for sec_key in $SEC_KEYS; do
        sec_rc=0
        sec_val="$(sec_read_key "$sec_key")" || sec_rc=$?
        case "$sec_rc" in
          0) ;;
          1) SEC_CONFIG_ERROR="review.${sec_key} が文字列ではありません（空白区切りの 1 文字列で書く）: ${SEC_CONFIG}"; break ;;
          *) SEC_CONFIG_ERROR="${SEC_CONFIG} を yq で読めません"; break ;;
        esac
        # キーはあるが値が空（""）: 書いた意図が読めないので既定へ戻さない
        if [ -z "$sec_val" ]; then
          [ "$(yq -r ".review | has(\"${sec_key}\")" "$SEC_CONFIG" 2>/dev/null)" != "true" ] \
            || { SEC_CONFIG_ERROR="review.${sec_key} が空です: ${SEC_CONFIG}"; break; }
          continue
        fi
        case "$sec_key" in
          security_glob) [ -n "$SEC_GLOB_FROM" ] || { SEC_GLOB_VALUE="$sec_val"; SEC_GLOB_FROM="project config"; } ;;
          security_glob_extra) [ -n "$SEC_EXTRA_FROM" ] || { SEC_EXTRA_VALUE="$sec_val"; SEC_EXTRA_FROM="project config"; } ;;
          security_review) [ -n "$SEC_POLICY_FROM" ] || { SEC_POLICY="$sec_val"; SEC_POLICY_FROM="project config"; } ;;
        esac
      done
    fi
  fi
fi
case "${SEC_POLICY:-auto}" in
  auto | off) : ;;
  *) [ -n "$SEC_CONFIG_ERROR" ] || SEC_CONFIG_ERROR="security_review は auto か off です（${SEC_POLICY_FROM}: ${SEC_POLICY}）"
     SEC_POLICY="" ;;
esac
# 設定を読めなかった回は無効化（off）も読めていないものとして扱い、ゲートを止めない
# （env の MULTI_AGENT_SECURITY_REVIEW=off も含めて捨てる — どの層の設定が壊れているかを報告行で直させる）
[ -z "$SEC_CONFIG_ERROR" ] || { SEC_POLICY=""; SEC_POLICY_FROM=""; }

ROUTE_ARGS=("$@")
[ -z "$SEC_GLOB_FROM" ] || ROUTE_ARGS+=(--security-glob "$SEC_GLOB_VALUE")
[ -z "$SEC_EXTRA_FROM" ] || ROUTE_ARGS+=(--security-glob-extra "$SEC_EXTRA_VALUE")

RC=0
OUT="$(bash "$ROUTER" "${ROUTE_ARGS[@]}")" || RC=$?
[ "$RC" -eq 64 ] && exit 64
printf '%s\n' "$OUT"

kv() { printf '%s\n' "$OUT" | awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }'; }
route="$(kv DT_ROUTE)"
reason="$(kv DT_REASON)"
lines="$(kv DT_LINES)"
case "$route" in
  fast | full | none) : ;;
  *) route="none"; [ -n "$reason" ] || reason="error:no-route" ;;
esac
[ "$RC" -eq 0 ] || route="none"

case "$reason" in
  docs-only) why="docs のみ" ;;
  small-diff) why="小さい差分" ;;
  contract-change:*) why="契約 path ${reason#contract-change:}" ;;
  implementation) why="実装変更" ;;
  no-files) why="変更 0 件" ;;
  jev-adopt) why="Jev の判定" ;;
  jev-low-confidence) why="Jev の確信度が閾値未満" ;;
  jev-fallback:*) why="Jev を使えない（${reason#jev-fallback:}）" ;;
  error:*) why="判定不能（${reason#error:}）" ;;
  '') why="判定不能（理由なし）" ;;
  *) why="$reason" ;;
esac
case "$lines" in
  '' | '-' | *[!0-9]*) lines_text="行数不明" ;;
  *) lines_text="${lines} 行" ;;
esac

case "$route" in
  fast) lanes="parent-read+codex:1" ;;
  full) lanes="codex:1+claude:4" ;;
  *) lanes="host" ;;
esac
echo "REVIEW_ROUTE=${route}"
echo "REVIEW_LANES=${lanes}"
case "$route" in
  fast) required="comprehensive-review" ;;
  full) required="comprehensive-review,code-review,error-handler-hunt,test-analysis,comment-analysis" ;;
  *) required="" ;;
esac
echo "REVIEW_REQUIRED_PERSPECTIVES=${required}"
echo "REVIEW_REPORT_LINE=経路: ${route}（根拠: ${why} / ${lines_text}）"

# ---- 専用セキュリティゲート ----------------------------------------------------------------
sec="$(kv DT_SECURITY)"
sec_reason="$(kv DT_SECURITY_REASON)"
sec_evidence="$(printf '%s\n' "$OUT" | awk '/^DT_SECURITY_EVIDENCE=/ { sub(/^DT_SECURITY_EVIDENCE=/, ""); print }')"
case "$sec" in
  yes | no) : ;;
  unknown) [ -n "$sec_reason" ] || sec_reason="error:理由なし" ;;
  *) sec="unknown"; sec_reason="error:根が分類を出していません" ;;
esac
if [ -n "$SEC_CONFIG_ERROR" ]; then
  sec="unknown"; sec_reason="error:${SEC_CONFIG_ERROR}"
fi
case "$sec_reason" in
  no-files) sec_why="変更 0 件" ;;
  error:*) sec_why="${sec_reason#error:}" ;;
  *) sec_why="$sec_reason" ;;
esac

# 主担当ホスト。両方立つ回（片方のホストからもう片方を起動した）は入れ子の向きが分からないので unknown
host="unknown"
if [ "${CLAUDECODE:-}" = "1" ] && [ -z "${GROK_AGENT:-}" ]; then
  host="claude-code"
elif [ -n "${GROK_AGENT:-}" ] && [ "${CLAUDECODE:-}" != "1" ]; then
  host="grok-cli"
fi

# /security-review は比較の基点を origin/HEAD に固定し、基点を引数で受けない（Claude Code の
# commands / errors リファレンス）。差分モードで base が origin/HEAD と食い違うと、マージ済みの別 PR の
# 変更まで対象に入る（または対象が欠ける）ので、走らせずに未確認として記録させる。
# --files / --files-from は base を持たないので照合しない（unchecked。ホストが確かめる）
base_check="unchecked"
sec_base=""
sec_files_mode=0
prev=""
for a in "$@"; do
  case "$a" in --files | --files-from) sec_files_mode=1 ;; esac
  [ "$prev" != "--base" ] || sec_base="$a"
  prev="$a"
done
origin_head=""
if [ "$sec_files_mode" -eq 0 ]; then
  origin_head="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)" || origin_head=""
  [ -n "$sec_base" ] || sec_base="${WORKFLOW_TIER_BASE:-}"
  [ -n "$sec_base" ] || sec_base="$origin_head"
  # 名前ではなく指すコミットで比べる — `--base develop` のローカルが origin/develop より古い回は、
  # 名前が揃っていても /security-review の比較範囲と食い違う
  sec_base_commit="$(git rev-parse --verify --quiet "${sec_base}^{commit}" 2>/dev/null)" || sec_base_commit=""
  origin_head_commit="$(git rev-parse --verify --quiet "${origin_head}^{commit}" 2>/dev/null)" || origin_head_commit=""
  if [ -z "$origin_head" ] || [ -z "$origin_head_commit" ]; then
    base_check="no-origin-head"
  elif [ -n "$sec_base_commit" ] && [ "$sec_base_commit" = "$origin_head_commit" ]; then
    base_check="match"
  else
    base_check="mismatch"
  fi
fi

if [ "$sec" = "no" ]; then
  gate="none"
elif [ "${SEC_POLICY:-auto}" = "off" ]; then
  gate="off"
elif [ "$host" != "claude-code" ]; then
  gate="unsupported"
elif [ "$base_check" = "no-origin-head" ] || [ "$base_check" = "mismatch" ]; then
  gate="unverified"
else
  gate="security-review"
fi

n_evidence="$(printf '%s\n' "$sec_evidence" | awk 'NF { n++ } END { print n + 0 }')"
first_evidence="$(printf '%s\n' "$sec_evidence" | awk 'NF { print; exit }')"
if [ "$sec" = "yes" ]; then
  if [ "$n_evidence" -gt 1 ]; then basis="根拠: ${first_evidence} ほか $((n_evidence - 1)) 件"; else basis="根拠: ${first_evidence}"; fi
else
  basis="判定不能: ${sec_why}"
fi
case "$gate" in
  none) report="対象外（該当変更なし）" ;;
  off) report="無効（security_review=off / ${SEC_POLICY_FROM}。${basis}）" ;;
  security-review) report="/security-review を実行する（${basis}）" ;;
  unverified)
    if [ "$base_check" = "no-origin-head" ]; then
      report="未確認（/security-review の基点 origin/HEAD がありません。${basis}）"
    else
      report="未確認（/security-review の基点 ${origin_head} が base ${sec_base} と食い違います。${basis}）"
    fi ;;
  *) report="未対応（主担当 ${host}。${basis}）" ;;
esac

echo "REVIEW_SECURITY_SENSITIVE=${sec}"
[ -z "$sec_evidence" ] || [ "$sec" != "yes" ] || printf '%s\n' "$sec_evidence" | awk 'NF { print "REVIEW_SECURITY_EVIDENCE=" $0 }'
echo "REVIEW_PRIMARY_HOST=${host}"
echo "REVIEW_SECURITY_BASE_CHECK=${base_check}"
echo "REVIEW_SECURITY_GATE=${gate}"
echo "REVIEW_SECURITY_REPORT_LINE=専用セキュリティゲート: ${report}"
exit "$RC"
