#!/usr/bin/env bash
# ============================================================================
# knowledge-lookup.sh — ACE Playbook と振り返り観測台帳の両方を 1 回で引く読み出し器
# ============================================================================
#
# 観測台帳（docs/08-knowledge/OBSERVATIONS.md）は `/retrospective` が育てる書き込み専用の
# store になっていた（Issue `#1778`）。ACE Playbook には「着手前の Playbook 参照」という読み出しの
# 導線が在るのに、台帳には無く、同じセッションで ACE の知見は作業中に届き、台帳の同じ主張
# （OBS-012）は振り返りの事後にしか突き合わされなかった。同じ主張が 10 回記録されている
# エントリは、記録が働いていることと、その記録が作業へ届いていないことを同時に示す。
#
# 本スクリプトは 2 つの store を同じキーワードで引き、**状態で切り分けて**返す。混ぜて返さない
# のは、ACE と観測で粒度・寿命・状態が違うから — `promoted`（対策 Issue が既に在る）や
# `mitigated`（対策が別の場所に定義済み）を「未対策の落とし穴」として実装判断へ混入させない。
#
# モード:
#   キーワード検索      knowledge-lookup.sh [オプション] <キーワード>...
#                       knowledge-lookup.sh [オプション] --impl <実装語>... --class <作業クラス語>...
#                       両 store のエントリ本文（見出し・メタ行・本文・観測メモ）に、いずれかの
#                       キーワードが大文字小文字を無視して含まれるエントリを返す（OR）。
#                       `--all` で全キーワードを含むエントリだけに絞る（AND）。
#                       型付き形式（`--impl` / `--class`）の特徴:
#                       - `--impl` と `--class` の両方を渡すと、系統ごとに結果を分けて出力し、各系統の
#                         節の最後に `RECORD impl ...` と `RECORD class ...` を出し、全体の末尾に
#                         `SUMMARY` を 1 行出す（`--format text` 時は `=== 系統: 実装語（--impl） ===` /
#                         `=== 系統: 作業クラス語（--class） ===` で区切る）。
#                       - 片軸だけが指定された場合（もう一方が未指定または空文字・空白のみ）は stderr へ
#                         警告を出し、1 回の `RECORD ace=... obs=...` 末尾へ `impl=未指定` / `class=未指定` を添える。
#                       - 型付き形式かつ `--format text` で Playbook が読めた回は、class 側（または単軸の
#                         唯一の節）の `RECORD` 直前に Playbook タイトル由来の「作業クラス語の候補」節を出力する（抽出が 0 件なら出さない）。
#                       - `--impl` / `--class` は `-` 始まりの引数をオプション境界とみなして値収集を終えるため、
#                         ハイフン始まりの語を検索したいときは従来どおり位置引数形式（`-- <語>`）を使う。
#   語ごとの検索        knowledge-lookup.sh [オプション] --each -- <キーワード>...
#                       渡した語を 1 語ずつ別々に引き、1 回の起動で語の数だけ結果の節と
#                       `RECORD each ace=... obs=... keyword=<語>` を渡した順に出す（語は行の最後の欄。最初の
#                       ` keyword=` から行末までが語で、空白を含む語もそのまま載る）。tsv では、その語の行が
#                       先に並び、その語の `RECORD each` が節の終わりになる（0 件の語は RECORD だけ）。全体の末尾の
#                       `SUMMARY` は語をまたいだ重複なしの件数と `each_keywords=<語数>` を持つ。起動の固定費
#                       （境界の検査・store の読み取り）を語の数だけ払わないための入口で、多数の候補語を既存知見と
#                       照合する `/ace-curate` の重複照合が使う（Issue `#2921`）。語は `--` の後ろへ置く（`-` で
#                       始まる語やオプションと同じ綴りの語を、オプションとして読ませない）。空白だけの語は数えず、
#                       改行・復帰・タブを含む語は受けない。`--impl` / `--class`・`--all` とは併用できない。
#   promoted 突き合わせ knowledge-lookup.sh --promoted-open [オプション]
#                       台帳の `Status | promoted` エントリのうち、リンク先 Issue が open のものを
#                       列挙する（`/retrospective` 観察チェックリスト第 0 項の入力）。state を
#                       確認できなかった参照は隠さず `未確認` として列挙する（fail-closed）。
#   配置の解決         knowledge-lookup.sh --resolve-playbook [--with-index-mode] [--root <dir>] [--playbook <path>]
#                       ACE Playbook の実配置だけを解決し、`ACE_PLAYBOOK=` / `ACE_PLAYBOOK_REL=` /
#                       `ACE_PLAYBOOK_SOURCE=` / `ACE_PLAYBOOK_STATE=` の 4 行を出す（0 = 確定 /
#                       2 = 不在・曖昧・読み取り失敗）。/ace-curate・/ace-refine の「配置先の解決」が
#                       この出力を読む — キーワード検索と同じ関数で解決するので、規則が食い違わない。
#                       --with-index-mode は検証済みの ACE_INDEX_MODE=inline|omit を追加する。
#   台帳の全件出力     knowledge-lookup.sh --ledger-dump [--root <dir>] [--ledger <path>]
#                       観測台帳の全エントリ（`archived` を含む）を 1 行 1 エントリの TSV で出す。列は
#                       `id / status / kind / count / first / last / issue / location / title / text`
#                       （text はエントリのブロック全体。行の区切りは RS〈0x1e〉、タブは空白へ置換）。末尾に
#                       `SUMMARY ledger=<相対パス> entries=<n> state=<ok|empty>` を出す。Issue の state は
#                       引かない（gh を使わない）。台帳の定期整理（scripts/observation-refine.sh）が候補を
#                       算出する入力で、台帳の解決・読み取り境界・見出しの認識を本スクリプトと共有する
#                       （別の読み出し器を作ると、フェンス内の記入例の扱いや書式変更の検出が片側だけ変わる）。
#                       台帳が無い・曖昧・読めない・見出しを 1 件も認識できない回は 2。
#
# オプション:
#   --root <dir>        対象リポジトリのルート（既定: cwd から git rev-parse --show-toplevel、無ければ cwd）
#   --playbook <path>   ACE Playbook の索引ファイル。省略時は ACE_PLAYBOOK_PATH → 記録済み配置
#                       （AGENTS.md・CLAUDE.md・docs/MASTER.md に書かれた PLAYBOOK.md のパス）→
#                       <root>/docs/08-knowledge/PLAYBOOK.md → <root> 配下の探索（候補が 1 件だけなら
#                       採る。docs-template/ は探索だけから外す）の順で解決する（resolve_playbook）
#   --ledger <path>     観測台帳（既定: <root>/docs/08-knowledge/OBSERVATIONS.md。探索の規則は同上）
#   --all               キーワードを AND で照合する（既定は OR）
#   --include-archived  ACE の playbook/archive/（と _archive/）配下と、台帳の `archived` エントリも返す
#   --offline           gh を使わない（promoted の Issue state は全件 `未確認` になる）
#   --impl <語>...      実装語（触るファイル・機能・コマンド等）を 1 語以上指定する（位置引数と併用不可）
#   --class <語>...     作業クラス語（何をする作業かを表す名詞）を 1 語以上指定する（位置引数と併用不可）
#   --format text|tsv   出力形式（既定 text。tsv は 1 行 1 エントリの機械可読）
#
# 出力（text）: store ごとに状態のグループで並べる。見出しは `== <store> ==`、グループは
#   `-- <状態ラベル> --`、エントリは `<ID>  <title>` に続けてメタ 1 行。各節の終わりに記録用の
#   `RECORD ace=<ID,... | 0 件 | Playbook なし | 読み取り失敗（理由）> obs=<同>`（型付き両系統時は
#   `RECORD impl ...` と `RECORD class ...` を系統ごとに 1 行ずつ）、全体の末尾に
#   `SUMMARY ace=<n> obs=<n> ...` を出す。RECORD 行は git-workflow「着手前の Playbook 参照」の
#   記録の契約（ヒット ID / 0 件 / 不在 / 読み取り失敗 の 4 種）にそのまま転記できる。
# 出力（tsv）: `store<TAB>id<TAB>status<TAB>meta<TAB>title<TAB>location`（6 列。promoted の Issue state は
#   meta 列の `Issue=owner/repo#N(open)` に含める。独立列にしない）
#
# 未反映（ADR-083）: 反映の設定（docs/08-knowledge/knowledge-delivery.conf）が mode=batch のときだけ、
#   手元の追跡 ref origin/<staging> の Playbook と台帳も引き、base へ未反映の新規・更新を「未反映」節
#   （TSV の status は unreflected）で返す。RECORD へ unreflected=… を足す。設定が無ければ出力は従来どおり。
#   本体は lib/knowledge-lookup-unreflected.sh。
# 状態ラベル（台帳）: active=未対策（蓄積中） / promoted=対策 Issue あり（open / closed / 未確認）/
#   mitigated=対策済み（所在は Issue 列） / archived=休眠、または統合元（Issue 列が統合先を指す）。
# 状態ラベル（ACE）: active / deprecated / archived（archive 配下。--include-archived 時のみ）。
#
# 読み取り境界が root（かその祖先）を、場所を名指して止めた回の標準エラーは、停止文の共通形 3 行
# （止めた層: 環境 / 止めた規則: knowledge-read-boundary / 次の一手: 同じ検査を通る置き場へ worktree を作る
# コマンド。置き場が検査を通らない・git リポジトリでない・commit が無い回は置き場の条件だけ）で終わる
# （Issue `#2648`。root_stop_guide）。
# 終了コード: 0 = 検索を実施した（0 件ヒットを含む）/ 1 = 引数エラー / 2 = 検索不成立
#   （両 store とも不在、または在るのに読めない・エントリ見出しを 1 件も認識できない）。
#   片方の store だけ不在の回は 0 で終わり、RECORD 行に `Playbook なし` / `台帳なし` を出す —
#   git-workflow の記録の契約が「不在は記録して標準手順を続行する」と定めているため。
#   両方無い回だけ 2 にするのは、「検索を実施した」と記録できる対象が 1 つも無いから。
#   3 = plugin root ガードの停止（handoff と実体位置の不一致・消えた root）。2 は「検索不成立」の
#   判定結果なので、ガードの停止を 2 で返すと「実行された」と誤読される。
#
# 依存: bash 3.2 以降、awk、find。gh は promoted の Issue state 確認にだけ使う（無ければ `未確認`）。
# 書き込みは一時ファイルだけ（read-only）。
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

usage() {
  cat >&2 <<'USAGE'
使い方:
  knowledge-lookup.sh [--root DIR] [--playbook PATH] [--ledger PATH] [--all]
                      [--include-archived] [--offline] [--github-input INDEX_ABS] [--format text|tsv] <キーワード>...
  knowledge-lookup.sh [--root DIR] [--playbook PATH] [--ledger PATH] [--all]
                      [--include-archived] [--offline] [--github-input INDEX_ABS] [--format text|tsv]
                      [--impl <実装語>...] [--class <作業クラス語>...]
  knowledge-lookup.sh [--root DIR] [--playbook PATH] [--ledger PATH]
                      [--include-archived] [--offline] [--github-input INDEX_ABS] [--format text|tsv] --each -- <キーワード>...
  knowledge-lookup.sh --promoted-open [--root DIR] [--ledger PATH] [--offline] [--format text|tsv]
  knowledge-lookup.sh --resolve-playbook [--with-index-mode] [--root DIR] [--playbook PATH]
  knowledge-lookup.sh --ledger-dump [--root DIR] [--ledger PATH]
USAGE
}

ROOT=""
PLAYBOOK=""
LEDGER=""
MATCH_ALL=0
INCLUDE_ARCHIVED=0
OFFLINE=0
GITHUB_INPUT=""
FORMAT="text"
MODE="search"
WITH_INDEX_MODE=0
USE_TYPED_ARGS=0
EACH=0
EACH_KEYWORD=""
IMPL_KEYWORDS=()
CLASS_KEYWORDS=()
POSITIONAL_KEYWORDS=()
KEYWORDS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || { usage; exit 1; }; ROOT="$2"; shift 2 ;;
    --playbook) [ $# -ge 2 ] || { usage; exit 1; }; PLAYBOOK="$2"; shift 2 ;;
    --ledger) [ $# -ge 2 ] || { usage; exit 1; }; LEDGER="$2"; shift 2 ;;
    --all) MATCH_ALL=1; shift ;;
    --each) EACH=1; shift ;;
    --include-archived) INCLUDE_ARCHIVED=1; shift ;;
    --offline) OFFLINE=1; shift ;;
    --github-input) [ $# -ge 2 ] || { usage; exit 1; }; [ -n "$2" ] || { echo "--github-input requires a non-empty index path" >&2; exit 2; }; GITHUB_INPUT="$2"; shift 2 ;;
    --format) [ $# -ge 2 ] || { usage; exit 1; }; FORMAT="$2"; shift 2 ;;
    --impl)
      USE_TYPED_ARGS=1
      shift
      _impl_count=0
      while [ $# -gt 0 ]; do
        case "$1" in
          --|-*) break ;;
          *)
            if [ -n "${1//[[:space:]]/}" ]; then
              IMPL_KEYWORDS+=("$1")
            fi
            _impl_count=$((_impl_count + 1))
            shift
            ;;
        esac
      done
      if [ "$_impl_count" -eq 0 ]; then
        printf '%s\n' '--impl には 1 つ以上のキーワードが必要です' >&2
        usage
        exit 1
      fi
      ;;
    --class)
      USE_TYPED_ARGS=1
      shift
      _class_count=0
      while [ $# -gt 0 ]; do
        case "$1" in
          --|-*) break ;;
          *)
            if [ -n "${1//[[:space:]]/}" ]; then
              CLASS_KEYWORDS+=("$1")
            fi
            _class_count=$((_class_count + 1))
            shift
            ;;
        esac
      done
      if [ "$_class_count" -eq 0 ]; then
        printf '%s\n' '--class には 1 つ以上のキーワードが必要です' >&2
        usage
        exit 1
      fi
      ;;
    --promoted-open) MODE="promoted-open"; shift ;;
    --resolve-playbook) MODE="resolve-playbook"; shift ;;
    --ledger-dump) MODE="ledger-dump"; shift ;;
    --with-index-mode) WITH_INDEX_MODE=1; shift ;;
    -h|--help) usage; exit 1 ;;
    --) shift; while [ $# -gt 0 ]; do POSITIONAL_KEYWORDS+=("$1"); shift; done ;;
    -*) printf '未知のオプション: %s\n' "$1" >&2; usage; exit 1 ;;
    *) POSITIONAL_KEYWORDS+=("$1"); shift ;;
  esac
done

case "${FORMAT}" in text|tsv) ;; *) printf -- '--format は text か tsv: %s\n' "${FORMAT}" >&2; exit 1 ;; esac
if [ "$WITH_INDEX_MODE" -eq 1 ] && [ "$MODE" != resolve-playbook ]; then
  printf '%s\n' '--with-index-mode には --resolve-playbook が必要です' >&2
  exit 1
fi
if [ "$USE_TYPED_ARGS" -eq 1 ]; then
  if [ "${#POSITIONAL_KEYWORDS[@]}" -gt 0 ]; then
    printf '%s\n' '--impl / --class と位置引数のキーワードは併用できません' >&2
    exit 1
  fi
  if [ "${MODE}" != "search" ]; then
    printf -- '--%s は --impl / --class と併用できません\n' "${MODE}" >&2
    exit 1
  fi
  KEYWORDS=(${IMPL_KEYWORDS[@]+"${IMPL_KEYWORDS[@]}"} ${CLASS_KEYWORDS[@]+"${CLASS_KEYWORDS[@]}"})
else
  KEYWORDS=(${POSITIONAL_KEYWORDS[@]+"${POSITIONAL_KEYWORDS[@]}"})
fi
if [ "$EACH" -eq 1 ]; then
  # 語ごとの検索（Issue `#2921`）: 1 語 = 1 節。系統別・AND とは組み合わせない（どちらも複数語を 1 つの照合へ束ねる指定）。
  if [ "$USE_TYPED_ARGS" -eq 1 ]; then
    printf '%s\n' '--each は --impl / --class と併用できません（語ごとに引く語は位置引数で渡す）' >&2
    exit 1
  fi
  if [ "${MODE}" != "search" ]; then
    printf -- '--%s は --each と併用できません\n' "${MODE}" >&2
    exit 1
  fi
  if [ "$MATCH_ALL" -eq 1 ]; then
    printf '%s\n' '--each は --all と併用できません（1 語ずつ引くので、全語を含む絞り込みは成り立たない）' >&2
    exit 1
  fi
  KEYWORDS=()
  for _kw in ${POSITIONAL_KEYWORDS[@]+"${POSITIONAL_KEYWORDS[@]}"}; do
    [ -n "${_kw//[[:space:]]/}" ] || continue
    # RECORD 行の最後の欄へそのまま載せるので、行と列を壊す改行・復帰・タブを含む語は受けない
    # （文字クラスはロケールで範囲が変わるので、3 文字を名指す）。
    case "$_kw" in
      *$'\n'* | *$'\r'* | *$'\t'*) printf '%s\n' '--each の語に改行・復帰・タブは使えません' >&2; exit 1 ;;
    esac
    KEYWORDS+=("$_kw")
  done
fi
if [ "${MODE}" = "search" ] && [ "${#KEYWORDS[@]}" -eq 0 ]; then
  printf '%s\n' "キーワードが 1 つも指定されていません（--promoted-open / --ledger-dump 以外はキーワードが必須）" >&2
  usage
  exit 1
fi
if [ "${MODE}" != "search" ] && [ "${#KEYWORDS[@]}" -gt 0 ]; then
  printf -- '--%s はキーワードを取りません\n' "${MODE}" >&2
  exit 1
fi

# ── 一時領域（read-only 契約: ここ以外へ書かない） ──────────────────────────
knowledge_reader="${BASH_SOURCE[0]%/*}/lib/knowledge-read-boundary.sh"
[ -f "$knowledge_reader" ] && [ ! -L "$knowledge_reader" ] || exit 2
. "$knowledge_reader"
# All derived text is private before the first source snapshot is created.
if ! TMP="$(ff_knowledge_job_directory knowledge-lookup)" || [ ! -d "${TMP}" ]; then
  printf '一時ディレクトリを作成できません（上の knowledge-read: 行が理由）\n' >&2
  exit 2
fi
trap 'rm -rf "${TMP}"' EXIT
# ── 読み取る対象（root とその祖先）の検査と、止めたときの次の一手（Issue `#2648`） ────────
# 境界が場所を名指して止めた回（Windows の ACL の判定）は、境界の出力をそのまま通したうえで、
# 同じ検査を通る場所へ worktree を作る手順を停止文の共通形（scripts/lib/stop-block.sh）で足す。
# 境界は緩めない: 止めた場所からは読まず、案内する置き場も同じ検査を通ったときだけ名指す。
# 場所の名指しが無い拒否（解決できない root・POSIX の判定など）には何も足さない。
ROOT_GIVEN="$ROOT"
shell_word() { # <text> -> POSIX シェルの 1 語（単一引用符で囲む）
  local text="$1" out="" quote="'"
  while [ "${text#*"$quote"}" != "$text" ]; do
    out="${out}${text%%"$quote"*}'\\''"; text="${text#*"$quote"}"
  done
  printf "'%s'" "${out}${text}"
}
root_stop_guide() { # <root の検査の stderr を写したファイル>
  local refusal="$1" line place="" start top="" head="" base="" safe="" probe name target="" count=1 next lib block sub="" place_word="その worktree"
  while IFS= read -r line; do
    case "$line" in
      'knowledge-read: 止めた場所: '*' — '*) place="${line#knowledge-read: 止めた場所: }"; place="${place% — *}" ;;
    esac
  done <"$refusal"
  [ -n "$place" ] || return 0
  next="本人・管理者・SYSTEM だけが変更できるフォルダーへ対象のリポジトリの worktree（または写し）を置き、そこを cwd（--root）にして同じ操作をやり直す"
  # git へ渡す綴りは境界の ff_knowledge_native_path に任せる（引用符を含む POSIX 綴りは Git Bash が変換しない）。
  start="$(ff_knowledge_canonical_dir "${ROOT_GIVEN:-.}" 2>/dev/null)" && start="$(ff_knowledge_native_path "$start")" || start=""
  [ -z "$start" ] || top="$(git -C "$start" rev-parse --show-toplevel 2>/dev/null)" || top=""
  [ -z "$top" ] || head="$(git -C "$start" rev-parse --verify -q 'HEAD^{commit}' 2>/dev/null)" || head=""
  # --root がリポジトリの下位ディレクトリなら、worktree の中の同じ下位ディレクトリを指す（cwd から解いた回の root は最上位）。
  [ -z "$head" ] || [ -z "$ROOT_GIVEN" ] || sub="$(git -C "$start" rev-parse --show-prefix 2>/dev/null)" || sub=""
  [ -z "${sub%/}" ] || place_word="その worktree の下の $(shell_word "${sub%/}")"
  [ -z "${HOME:-}${FF_DEV_TOOLKIT_STATE_DIR:-}" ] || base="${FF_DEV_TOOLKIT_STATE_DIR:-${HOME:-}/.config/ff-dev-toolkit}"
  case "$base" in /* | [A-Za-z]:[/\\]*) ;; *) base="" ;; esac
  [ -z "$head" ] || [ -z "$base" ] || safe="$(ff_knowledge_lexical_path "${base}/wt" 2>/dev/null)" || safe=""
  if [ -n "$safe" ]; then
    # まだ無い置き場は、いちばん近い実在の祖先で確かめる（ここでは作らない。read-only 契約）。
    probe="$safe"
    while [ ! -d "$probe" ] && [ "$probe" != / ]; do probe="${probe%/*}"; [ -n "$probe" ] || probe=/; done
    if probe="$(ff_knowledge_canonical_dir "$probe")" && ff_knowledge_storage "$probe" dir \
      && probe="$(ff_knowledge_native_path "$safe")"; then
      safe="$probe"; name="${top##*/}"; target="${safe}/${name}"
      # 同じ名前の別物（この commit を持たない場所）は使わず、番号を付けた隣を選ぶ。フォルダーだけ消されて登録が
      # 残った前の worktree は、下の add -f が上書きする（-f が無いと git は missing but already registered で断る）。
      while [ -e "$target" ] || [ -L "$target" ]; do
        if [ -d "$target" ] && [ ! -L "$target" ] && git -C "$target" cat-file -e "${head}^{commit}" 2>/dev/null; then break; fi
        count=$((count + 1)); target="${safe}/${name}-${count}"
        [ "$count" -le 9 ] || { target=""; break; }
      done
    else
      printf 'knowledge-read: 既定の置き場 %s も同じ検査を通りません（上の行が理由）\n' "$safe" >&2
    fi
  fi
  if [ -n "$target" ] && [ -d "$target" ]; then
    next="git -C $(shell_word "$target") switch --detach ${head} を実行し（前に作った worktree を同じ commit へ合わせる）、${place_word} を cwd（--root）にして同じ操作をやり直す（/ace-curate・/retrospective の書き込みも同じ worktree で続ける）"
  elif [ -n "$target" ]; then
    next="git -C $(shell_word "$start") worktree add -f --detach $(shell_word "$target") ${head} を実行し、${place_word} を cwd（--root）にして同じ操作をやり直す（コミット済みの内容だけが写る。/ace-curate・/retrospective の書き込みも同じ worktree で続ける。不要になったら git worktree remove）"
  fi
  lib="${BASH_SOURCE[0]%/*}/lib/stop-block.sh"
  # shellcheck source=lib/stop-block.sh
  block="$([ -f "$lib" ] && [ -r "$lib" ] && . "$lib" 2>/dev/null && declare -F ff_stop_block >/dev/null 2>&1 \
    && ff_stop_block 環境 knowledge-read-boundary scripts/lib/knowledge-read-boundary.sh \
      "読み取る対象の祖先 ${place} が読み取り境界の検査を通らないため、知見を読んでいません（境界は緩めません）" "$next")" || :
  if [ -z "$block" ]; then
    block="止めた層: 環境
止めた規則: stop-block-unavailable（scripts/lib/stop-block.sh）— 停止文の共通形を読み込めません（元の規則: knowledge-read-boundary）
次の一手: ff-dev-toolkit を更新・再インストールして scripts/lib/stop-block.sh を復旧する"
  fi
  printf '%s\n' "$block" >&2
}
root_rc=0
if [ -z "$ROOT" ]; then ROOT="$(ff_knowledge_project_context 2>"${TMP}/root-refusal")" || root_rc=$?
else ROOT="$(ff_knowledge_canonical_dir "$ROOT" 2>"${TMP}/root-refusal")" || root_rc=$?
fi
if [ "$root_rc" -eq 0 ]; then ff_knowledge_storage "$ROOT" dir 2>>"${TMP}/root-refusal" || root_rc=$?; fi
[ ! -s "${TMP}/root-refusal" ] || cat "${TMP}/root-refusal" >&2
if [ "$root_rc" -ne 0 ]; then
  root_stop_guide "${TMP}/root-refusal"
  exit 2
fi
: >"${TMP}/read-cache"
# A snapshot is reused only for the same spelling, authority and mode, and only while
# the file still resolves to the same place with the same metadata. A miss is
# authorized in full by the snapshot itself; its sidecar (the authorized path and the
# metadata it was read under) keys the cache without another stat, which costs about
# 0.1 s on Git Bash (Issue `#2477`). A file whose metadata changed since an earlier
# read, under any key, is refused.
accepted_snapshot() { # <logical input> <independent authority> [root|file]
  local input="$1" authority="$2" mode="${3:-root}" canonical stamp snapshot
  local c_input c_authority c_mode c_canonical c_stamp c_snapshot
  while IFS="${TAB}" read -r c_input c_authority c_mode c_canonical c_stamp c_snapshot; do
    [ "$c_input" = "$input" ] && [ "$c_authority" = "$authority" ] && [ "$c_mode" = "$mode" ] || continue
    canonical="$(ff_knowledge_canonical_file "$input")" || return 2
    [ "$canonical" = "$c_canonical" ] || break
    stamp="$(ff_knowledge_meta "$canonical")" || return 2
    [ "$stamp" = "$c_stamp" ] || { ff_knowledge_refuse input-changed; return 2; }
    printf '%s\n' "$c_snapshot"
    return 0
  done <"${TMP}/read-cache"
  snapshot="$(ff_knowledge_snapshot "$input" "$authority" "$TMP" "$mode")" || return 2
  IFS="${TAB}" read -r canonical stamp <"${snapshot%/*}/source" || { ff_knowledge_refuse read-unverifiable; return 2; }
  [ -n "$canonical" ] && [ -n "$stamp" ] || { ff_knowledge_refuse read-unverifiable; return 2; }
  while IFS="${TAB}" read -r c_input c_authority c_mode c_canonical c_stamp c_snapshot; do
    [ "$c_canonical" != "$canonical" ] || [ "$c_stamp" = "$stamp" ] || { ff_knowledge_refuse input-changed; return 2; }
  done <"${TMP}/read-cache"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$input" "$authority" "$mode" "$canonical" "$stamp" "$snapshot" >>"${TMP}/read-cache"
  printf '%s\n' "$snapshot"
}
ACE_AUTHORITY="$ROOT"
OBS_AUTHORITY="$ROOT"; OBS_AUTHORITY_MODE=root
snapshot_store_input() {
  case "$1" in
    "$OBS_FILE") accepted_snapshot "$1" "$OBS_AUTHORITY" "$OBS_AUTHORITY_MODE" ;;
    *) accepted_snapshot "$1" "$ACE_AUTHORITY" ;;
  esac
}

# ── store の実配置を確定する処理（lib へ分離。最終行の完了印を source の前に照合する） ────
store_lib="${BASH_SOURCE[0]%/*}/lib/knowledge-lookup-store.sh"
if [ -L "$store_lib" ] || [ ! -f "$store_lib" ] || [ ! -r "$store_lib" ] \
  || [ "$(tail -n 1 "$store_lib")" != "# knowledge-lookup-store-end" ]; then
  printf 'store 解決の関数を読めません: %s\n' "$store_lib" >&2
  exit 2
fi
# shellcheck source=lib/knowledge-lookup-store.sh
. "$store_lib"

# 各 store の状態: ok / absent / ambiguous / unreadable / noentry
TAB="$(printf '\t')"
ACE_STATE="absent"; ACE_INDEX=""; ACE_SOURCE=""
OBS_STATE="absent"; OBS_FILE=""
if [ "${MODE}" = "search" ] || [ "${MODE}" = "resolve-playbook" ]; then
  if ACE_RESOLVED="$(resolve_playbook)"; then
    ACE_STATE="ok"
    ACE_SOURCE="${ACE_RESOLVED%%"${TAB}"*}"
    ACE_INDEX="${ACE_RESOLVED#*"${TAB}"}"
  else
    case $? in 3) ACE_STATE="ambiguous" ;; 1) ACE_STATE="absent" ;; *) ACE_STATE="unreadable" ;; esac
  fi
fi
# 明示指定・既定パスが存在しても読めなければ「読み取り失敗」（未導入へ吸収しない）
if [ "${ACE_STATE}" = "ok" ] && { [ ! -f "${ACE_INDEX}" ] || [ ! -r "${ACE_INDEX}" ]; }; then ACE_STATE="unreadable"; fi
ACE_OPERATOR_FILE="$ACE_INDEX"
# 検索・解決のどちらへ分かれる前にも、ディレクトリを cd -P で実体化した絶対パスへ揃える。
# `ACE_PLAYBOOK_PATH=PLAYBOOK.md` のようなファイル名だけの指定を相対のまま持つと、検索側の
# `${ACE_INDEX%/*}` がファイル名自身を返し、カテゴリファイル（playbook/）の探索先を取り違える。
# ファイル名（symlink ならリンク自身の名前）は変えない。
if [ "${ACE_STATE}" = "ok" ]; then
  case "$ACE_INDEX" in */*) ace_parent="${ACE_INDEX%/*}"; [ -n "$ace_parent" ] || ace_parent=/ ;; *) ace_parent=. ;; esac
  ace_dir="$(ff_knowledge_canonical_dir "$ace_parent" 2>/dev/null)" || ace_dir=""
  if [ -n "${ace_dir}" ]; then ACE_INDEX="${ace_dir}/${ACE_INDEX##*/}"; else ACE_STATE="unreadable"; fi
fi
if [ "${ACE_STATE}" = "ok" ]; then
  case "$ACE_SOURCE" in
    explicit|env)
      if ff_knowledge_project_operand "$ACE_OPERATOR_FILE" "$ROOT"; then :
      else
        operand_rc=$?
        if [ "$operand_rc" -eq 1 ]; then
          ace_selected="$(ff_knowledge_canonical_file "$ACE_INDEX")" || ACE_STATE=unreadable
          if [ "$ACE_STATE" = ok ]; then ACE_AUTHORITY="${ace_selected%/*}"; fi
        else ACE_STATE=unreadable
        fi
      fi
      ;;
  esac
  if [ "$ACE_STATE" = ok ]; then
    ff_knowledge_authorize "$ACE_INDEX" "$ACE_AUTHORITY" >/dev/null || ACE_STATE=unreadable
  fi
fi

# 索引省略の宣言は PLAYBOOK.md 冒頭の frontmatter のトップレベルに限定する。
# 値をシェルで評価しない。未宣言の既存 Playbook は inline のまま扱う。
read_ace_index_settings() {
  local snapshot
  snapshot="$(accepted_snapshot "$ACE_INDEX" "$ACE_AUTHORITY")" || return 2
  LC_ALL=C awk '
    { sub(/\r$/, "") }
    NR == 1 { if ($0 != "---") exit; next }
    /^---[ \t]*$/ { closed = 1; exit }
    /^ace_index_mode[ \t]*:/ {
      mode_keys++
      if ($0 ~ /^ace_index_mode:[ \t]+omit[ \t]*$/) omit = 1
    }
    /^ace_entry_count[ \t]*:/ {
      count_keys++
      if ($0 ~ /^ace_entry_count:[ \t]*(0|"0"|\0470\047)[ \t]*$/) zero = 1
    }
    END {
      if (mode_keys > 0 && (!closed || mode_keys != 1 || !omit)) exit 2
      printf "%s:%s\n", (omit ? "omit" : "inline"), (closed && count_keys == 1 && zero ? "zero" : "unknown")
    }
  ' "$snapshot"
}

ACE_INDEX_MODE=""
ACE_DECLARED_COUNT="unknown"
if [ "$ACE_STATE" = ok ] && { [ "$MODE" = search ] || [ "$WITH_INDEX_MODE" -eq 1 ]; }; then
  if ace_index_settings="$(read_ace_index_settings)"; then
    ACE_INDEX_MODE="${ace_index_settings%:*}"
    ACE_DECLARED_COUNT="${ace_index_settings#*:}"
    # find は symlink のディレクトリを辿らない。省略時は入口を実ディレクトリに限定し、
    # 壊れた配置を「走査したが本文ゼロ」と読み替えない。
    ace_categories="${ACE_INDEX%/*}/playbook"
    if [ "$ACE_INDEX_MODE" = omit ] &&
      { [ -L "$ace_categories" ] || { [ -e "$ace_categories" ] && [ ! -d "$ace_categories" ]; }; }; then
      ACE_STATE="unreadable"
      ACE_INDEX_MODE=""
      printf 'ACE Playbook のカテゴリパスが実ディレクトリではありません: %s\n' "$ace_categories" >&2
    fi
  else
    ACE_STATE="index-invalid"
    printf 'ACE Playbook の索引設定を読めません: %s (ace_index_mode)\n' "$ACE_INDEX" >&2
  fi
fi

# ── --resolve-playbook: 解決結果だけを出して終える ───────────────────────────
# /ace-curate・/ace-refine が「配置先の解決」で読む契約。KEY=VALUE の 4 行を必ず出す。
# --with-index-mode の回だけ、配置と同じスナップショットで確定した索引方式の行を足す。
# STATE が ok 以外の回も 4 行を出す: absent / ambiguous では ACE_PLAYBOOK は空、unreadable では
# 名指しされたパス（読めなかった対象の報告用）。成否は STATE と終了コードで読む
# （0 = 確定 / 2 = 不在・曖昧・読み取り失敗）。
# ACE_PLAYBOOK_REL は実体が root の内側にあると確かめられたときだけ出す。編集してよいかの判定を
# REL に一本化するため、パスは相対・絶対を問わずディレクトリを cd -P で実体化してから root と
# 比べる（`/repo/../shared/…` や `/tmp` ↔ `/private/tmp` の表記差で内外を取り違えない）。
# ファイル自体が symlink なら 1 段だけ辿り、その実体も root 内のときだけ REL を出す。
if [ "${MODE}" = "resolve-playbook" ]; then
  ace_rel=""
  if [ "${ACE_STATE}" = "ok" ]; then
    ace_dir="${ACE_INDEX%/*}"
    if [ -n "${ace_dir}" ]; then
      ace_abs="${ACE_INDEX}"
      ace_real="${ace_abs}"
      if [ -L "${ace_abs}" ]; then
        ace_link="$(readlink -- "${ace_abs}" 2>/dev/null)" || ace_link=""
        case "${ace_link}" in "") ace_real="" ;; /*) ace_real="${ace_link}" ;; *) ace_real="${ace_dir}/${ace_link}" ;; esac
        if [ -n "${ace_real}" ]; then
          ace_real_dir="$(CDPATH= cd -P -- "$(dirname -- "${ace_real}")" 2>/dev/null && pwd -P)" || ace_real_dir=""
          ace_real="${ace_real_dir:+${ace_real_dir}/${ace_real##*/}}"
          # 多段の symlink は辿らない（実体を確かめられないので repo 外と同じく REL を出さない）
          if [ -z "${ace_real_dir}" ] || [ -L "${ace_real}" ]; then ace_real=""; fi
        fi
      fi
      case "${ace_abs}" in
        "${ROOT}/"*) case "${ace_real}" in "${ROOT}/"*) ace_rel="${ace_abs#"${ROOT}"/}" ;; esac ;;
      esac
      ACE_INDEX="${ace_abs}"
    fi
  fi
  printf 'ACE_PLAYBOOK=%s\n' "${ACE_INDEX}"
  printf 'ACE_PLAYBOOK_REL=%s\n' "${ace_rel}"
  printf 'ACE_PLAYBOOK_SOURCE=%s\n' "${ACE_SOURCE}"
  printf 'ACE_PLAYBOOK_STATE=%s\n' "${ACE_STATE}"
  if [ "$WITH_INDEX_MODE" -eq 1 ]; then printf 'ACE_INDEX_MODE=%s\n' "$ACE_INDEX_MODE"; fi
  [ "${ACE_STATE}" = "ok" ] && exit 0
  exit 2
fi

if OBS_FILE="$(resolve_store "docs/08-knowledge/OBSERVATIONS.md" "OBSERVATIONS.md" "${LEDGER}")"; then
  OBS_STATE="ok"
else
  case $? in 3) OBS_STATE="ambiguous" ;; 1) OBS_STATE="absent" ;; *) OBS_STATE="unreadable" ;; esac
fi
if [ "${OBS_STATE}" = "ok" ] && { [ ! -f "${OBS_FILE}" ] || [ ! -r "${OBS_FILE}" ]; }; then OBS_STATE="unreadable"; fi
if [ -n "$LEDGER" ]; then
  if ff_knowledge_project_operand "$LEDGER" "$ROOT"; then :
  else
    operand_rc=$?
    if [ "$operand_rc" -eq 1 ]; then OBS_AUTHORITY="$LEDGER"; OBS_AUTHORITY_MODE=file
    else OBS_STATE=unreadable
    fi
  fi
fi

# ── エントリの切り出し（共通 awk） ───────────────────────────────────────────
# 1 エントリ = `### <PREFIX>-…:` 見出しから、終端 `---` / 次の anchor / 次の見出し / 次の `##`
# の手前まで。見出し・メタ行・本文・観測メモをすべて 1 ブロックとして持つ（キーワード照合の
# 対象）。出力は 1 エントリ 1 行: `id<US>title<US>file<US>flatten(block)`（US = \x1f）。
# メタ行はブロック内に残るので、後段が `| Status | …` 等を取り出す。
# コードフェンス（``` / ~~~）の内側は見出しとして扱わない — 台帳・Playbook のテンプレートは
# 「エントリ形式」節にフェンスで囲った記入例（`### OBS-XXX:` / `### ACE-XXX:`）を持ち、これを
# 実エントリとして返すと架空の観測がヒットし、実見出しが壊れても認識件数が 0 にならない
# （クロスモデルレビューで codex-cli / grok-cli が独立に再現）。フェンス内の行は、開いている
# エントリがあればその本文として残す（例示は本文の一部）。
extract_entries() { # <PREFIX: ACE|OBS> <file>...
  local prefix="$1"; shift
  local input snapshot labels="${TMP}/entry-labels"; local snapshots=()
  : >"$labels"
  for input in "$@"; do
    snapshot="$(snapshot_store_input "$input")" || return 2
    snapshots+=("$snapshot")
    printf '%s\t%s\n' "$snapshot" "$input" >>"$labels"
  done
  [ "${#snapshots[@]}" -gt 0 ] || return 2
  FF_READ_LABELS="$labels" awk -v prefix="${prefix}" '
    BEGIN { while ((getline row < ENVIRON["FF_READ_LABELS"]) > 0) { split(row, parts, "\t"); labels[parts[1]] = parts[2] } close(ENVIRON["FF_READ_LABELS"]) }
    function flush() {
      if (id != "") { gsub(/\n/, "\036", block); printf "%s\037%s\037%s\037%s\n", id, title, FILENAME_SAVED, block }
      id = ""; title = ""; block = ""
    }
    FNR == 1 { flush(); FILENAME_SAVED = labels[FILENAME]; infence = 0 }
    {
      line = $0
      if (line ~ /^[[:space:]]*(```|~~~)/) {
        infence = !infence
        if (id != "") { gsub(/\037/, " ", line); block = block "\n" line }
        next
      }
      if (infence) {
        if (id != "") { gsub(/\037/, " ", line); block = block "\n" line }
        next
      }
      if (line ~ ("^### " prefix "-[0-9A-Za-z-]+:")) {
        flush()
        rest = line; sub(/^### /, "", rest)
        id = rest; sub(/:.*$/, "", id)
        title = rest; sub(/^[^:]*:[[:space:]]*/, "", title)
        block = line
        next
      }
      if (id == "") next
      if (line ~ /^---[[:space:]]*$/ || line ~ /^<a id=/ || line ~ /^## / || line ~ /^### /) { flush(); next }
      gsub(/\037/, " ", line)
      block = block "\n" line
    }
    END { flush() }
  ' "${snapshots[@]}"
}

# ── 空 store と書式破損の切り分け ───────────────────────────────────────────
# エントリを 1 件も抽出できなかった store について、「テンプレート直後で空」（正常）と
# 「見出し書式が変わって認識できない」（読み取り失敗）を分ける。フェンス外に `## エントリ一覧`
# 見出しがあり、その後にフェンス外の `### ` 見出しが走査対象のどのファイルにも無ければ空。
# フェンス内の記入例は数えない（テンプレートは記入例をフェンスで持つ）。分割配置の category ファイルは
# 自分の `## エントリ一覧` を持つので、索引・本体とも同じ節スコープで数える。
# 戻り値: 0 = 空（正常）/ 1 = 書式破損の疑い
store_is_empty() { # <索引方式> <索引ファイル> <走査対象ファイル...>
  local index_mode="$1" index="$2"; shift 2
  if [ "$index_mode" = omit ]; then
    [ "$ACE_DECLARED_COUNT" = zero ] || return 1
  else
    index="$(snapshot_store_input "$index")" || return 1
    awk '/^[[:space:]]*(```|~~~)/ { infence = !infence; next } infence { next } /^## エントリ一覧/ { seen = 1 } END { exit seen ? 0 : 1 }' "${index}" || return 1
  fi
  local f
  for f in "$@"; do
    f="$(snapshot_store_input "$f")" || return 1
    # 見出しを数えるのは `## エントリ一覧` 節の内側だけ（次の `## ` 見出し — Changelog 等 — で節を閉じる。
    # テンプレートの Changelog は `### [版]` 見出しを持つので、節を閉じないと空を書式破損と誤判定する）
    # 省略時は一覧節がなくても、ACE らしい見出し・アンカーの残存を正常空にしない。
    awk -v mode="$index_mode" '
      /^[[:space:]]*(```|~~~)/ {
        if (mode != "omit") { infence = !infence; next }
        line = $0
        sub(/^[[:space:]]*/, "", line)
        match(line, /^(`+|~+)/)
        width = RLENGTH
        marker = substr(line, 1, 1)
        if (!infence) {
          infence = 1
          fence_marker = marker
          fence_width = width
        } else if (marker == fence_marker && width >= fence_width && substr(line, width + 1) ~ /^[[:space:]]*$/) {
          infence = 0
        }
        next
      }
      infence { next }
      /^## / { seen = ($0 ~ /^## エントリ一覧/) }
      seen && /^### / { found = 1 }
      mode == "omit" && (tolower($0) ~ /^[ \t]*##+[ \t]+ace([^[:alnum:]]|$)/ ||
                         tolower($0) ~ /^[ \t]*<a[ \t]+id=["\047]ace-/) { found = 1 }
      END { exit (found || (mode == "omit" && infence)) ? 1 : 0 }
    ' "${f}" || return 1
  done
  return 0
}

# ── ACE Playbook の走査対象 ─────────────────────────────────────────────────
# 索引ファイル自身（単一ファイル配置ではエントリが索引に同居する）+ 同階層 playbook/ 配下の *.md。
# playbook/ 配下はサブディレクトリも辿る（件数ゲート check-category-size の discoverPlaybookSubfiles と
# 同じ範囲）。退避先（名前が archive / _archive のディレクトリ）と . 始まりのディレクトリは
# 深さを問わず辿らない。シンボリックリンクの *.md も拾う（TS 側も種別を問わず拾う）。
# 退避先の *.md は --include-archived のときだけ、同じく深さを問わず加える。
ACE_FILES="${TMP}/ace-files"; : >"${ACE_FILES}"
ACE_ENTRIES="${TMP}/ace-entries"; : >"${ACE_ENTRIES}"
ACE_ARCHIVE_ENTRIES="${TMP}/ace-archive-entries"; : >"${ACE_ARCHIVE_ENTRIES}"
if [ "${ACE_STATE}" = "ok" ]; then
  ace_dir="${ACE_INDEX%/*}"
  printf '%s\n' "${ACE_INDEX}" >>"${ACE_FILES}"
  if [ -d "${ace_dir}/playbook" ]; then
    ff_knowledge_storage "$(ff_knowledge_canonical_dir "${ace_dir}/playbook")" dir || exit 2
    case "$(ff_knowledge_canonical_dir "${ace_dir}/playbook")/" in "$ACE_AUTHORITY/"*) ;; *) ff_knowledge_refuse outside-authority; exit 2 ;; esac
    find "${ace_dir}/playbook" -mindepth 1 -type d \( -name archive -o -name _archive -o -name '.*' \) -prune \
      -o \( -type f -o -type l \) -name '*.md' -print 2>/dev/null | LC_ALL=C sort >>"${ACE_FILES}" || exit 2
  fi
  unreadable=""
  while IFS= read -r f; do
    [ -n "${f}" ] || continue
    if [ ! -r "${f}" ]; then unreadable="${unreadable} ${f}"; fi
  done <"${ACE_FILES}"
  if [ -n "${unreadable}" ]; then
    ACE_STATE="unreadable"
    printf 'ACE Playbook の走査対象に読めないファイルがあります:%s\n' "${unreadable}" >&2
  else
    files=()
    while IFS= read -r f; do [ -n "${f}" ] && files+=("${f}"); done <"${ACE_FILES}"
    extract_entries ACE "${files[@]}" >"${ACE_ENTRIES}" || exit 2
    if [ ! -s "${ACE_ENTRIES}" ]; then
      if store_is_empty "$ACE_INDEX_MODE" "${ACE_INDEX}" "${files[@]}"; then ACE_STATE="empty"; else ACE_STATE="noentry"; fi
    fi
    if [ "${INCLUDE_ARCHIVED}" -eq 1 ]; then
      arch=()
      if [ -d "${ace_dir}/playbook" ]; then
        find "${ace_dir}/playbook" -mindepth 1 -type d -name '.*' -prune \
          -o \( -type f -o -type l \) -name '*.md' \( -path '*/archive/*' -o -path '*/_archive/*' \) -print 2>/dev/null | LC_ALL=C sort >"${TMP}/archive-files" || exit 2
        while IFS= read -r f; do [ -n "${f}" ] && arch+=("${f}"); done <"${TMP}/archive-files"
      fi
      if [ "${#arch[@]}" -gt 0 ]; then
        extract_entries ACE "${arch[@]}" >"${ACE_ARCHIVE_ENTRIES}" || exit 2
      fi
    fi
  fi
fi

# ── 観測台帳の走査 ───────────────────────────────────────────────────────────
OBS_ENTRIES="${TMP}/obs-entries"; : >"${OBS_ENTRIES}"
if [ "${OBS_STATE}" = "ok" ]; then
  extract_entries OBS "${OBS_FILE}" >"${OBS_ENTRIES}" || exit 2
  if [ ! -s "${OBS_ENTRIES}" ]; then
    # 見出しを 1 件も認識できない台帳は「0 件ヒット」ではなく読み取り失敗（書式変更を空振りで
    # 緑にしない）。ただしテンプレート直後の空台帳（エントリ一覧が空）は正常（判定は store_is_empty）。
    if store_is_empty inline "${OBS_FILE}" "${OBS_FILE}"; then
      OBS_STATE="empty"
    else
      OBS_STATE="noentry"
    fi
  fi
fi

# ── 検索不成立の判定 ─────────────────────────────────────────────────────────
searched=0
case "${ACE_STATE}" in ok|empty) searched=1 ;; esac
case "${OBS_STATE}" in ok|empty) searched=1 ;; esac
if [ "${MODE}" = "promoted-open" ] || [ "${MODE}" = "ledger-dump" ]; then
  case "${OBS_STATE}" in
    ok|empty) ;;
    absent) printf '観測台帳がありません（root=%s）。--%s は台帳が必要です\n' "${ROOT}" "${MODE}" >&2; exit 2 ;;
    ambiguous) printf '観測台帳の配置を確定できません（--ledger で指定してください）\n' >&2; exit 2 ;;
    unreadable) printf '観測台帳を読めません: %s\n' "${OBS_FILE}" >&2; exit 2 ;;
    noentry) printf '観測台帳のエントリ見出し（### OBS-NNN:）を 1 件も認識できません（書式変更の可能性）: %s\n' "${OBS_FILE}" >&2; exit 2 ;;
  esac
elif [ "${searched}" -eq 0 ]; then
  printf '検索不成立: ACE Playbook=%s / 観測台帳=%s（root=%s）\n' "${ACE_STATE}" "${OBS_STATE}" "${ROOT}" >&2
  printf '%s\n' "  どちらの store も検索できませんでした。--root / --playbook / --ledger を確認してください。" >&2
  exit 2
fi

# ── メタの取り出し ──────────────────────────────────────────────────────────
# エントリ一覧（extract_entries の出力）の全エントリについて、ブロック（\036 区切り）から
# `| <key> | <value>` の値を指定キーの順に取り出し、1 エントリ 1 行で返す。awk 1 回で全件を
# 処理し、後段の出力ループ（emit_ace / emit_obs）ではエントリごとに外部プロセスを起動しない。
# Windows の Git Bash（MSYS）ではプロセス起動 1 回が 0.1 秒を超え、エントリごとに値ごとの
# `$(printf | tr | awk)` を起動していた形は、約 350 件の台帳の --promoted-open で 6 分を超えた
# （WSL では同じ処理が 8 秒）。台帳は単調に伸びるので、件数に比例する起動は残さない。
# 値の規則（旧 meta_of と同じ）: 各行を `|` で分けた 2〜NF-1 番目の欄のうち、前後の空白を除いて
# キーと一致した最初の欄の、次の欄の値（前後の空白を除く）。行は文書順に見て最初に一致した
# 行を採る。無ければ空。
# 出力: `id<US>title<US>file<US>anchor<US>値1<US>…<US>値n<US>.`。anchor は id の英小文字化
# （id は英数字とハイフンだけなので tolower と `tr 'A-Z' 'a-z'` は一致する）。末尾の `.` は番兵で、
# 最後の値が空でも read の欄がずれないようにする。
entries_meta() { # <entries file> <key>...
  local file="$1" IFS=' '
  shift
  awk -F '\037' -v keys="$*" '
    BEGIN { nk = split(keys, want, " ") }
    {
      nl = split($4, lines, "\036")
      row = $1 "\037" $2 "\037" $3 "\037" tolower($1)
      for (k = 1; k <= nk; k++) {
        v = ""; found = 0
        for (j = 1; j <= nl && !found; j++) {
          nf = split(lines[j], f, "|")
          for (i = 2; i < nf; i++) {
            name = f[i]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
            if (name == want[k]) { v = f[i + 1]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); found = 1; break }
          }
        }
        row = row "\037" v
      }
      print row "\037."
    }' "${file}"
}

# ── キーワード照合 ──────────────────────────────────────────────────────────
# 大文字小文字を無視した固定文字列の部分一致。ASCII の大小だけを畳む（tolower は ASCII のみ。
# 日本語はそのまま突き合わせる）。OR（既定）/ AND（--all）。
KW_FILE="${TMP}/keywords"; : >"${KW_FILE}"
for kw in ${KEYWORDS[@]+"${KEYWORDS[@]}"}; do printf '%s\n' "${kw}" >>"${KW_FILE}"; done
filter_entries() { # stdin: entries / stdout: matched entries
  awk -F '\037' -v kwfile="${KW_FILE}" -v all="${MATCH_ALL}" '
    BEGIN {
      n = 0
      while ((getline line < kwfile) > 0) { if (line != "") kws[++n] = tolower(line) }
      close(kwfile)
    }
    {
      hay = tolower($4)
      hit = 0; miss = 0
      for (i = 1; i <= n; i++) {
        if (index(hay, kws[i]) > 0) hit++; else miss++
      }
      if ((all == 1 && miss == 0 && n > 0) || (all == 0 && hit > 0)) print
    }'
}

# ── Issue state の解決（promoted / mitigated の Issue 列） ───────────────────
# `owner/repo#N` を repo ごとに集め、open 一覧を 1 回だけ取得する。open 一覧に無い番号は
# closed とみなす（存在しない番号も closed 側に落ちる — open かどうかだけが判断に要るため）。
# gh が無い / 失敗 / 一覧が上限に達した repo は、その repo の参照をすべて `未確認` にする。
# 参照ごとの判定は外部プロセスを起動しない（メタの取り出しの節と同じ理由）。repo ごとの結果は
# 並行配列に持つ（bash 3.2 は連想配列を持たない）。open 番号の集合は ` 1 2 3 ` の形の文字列で、
# 番号は先頭の 0 を落として持つ（旧実装の awk の数値比較 `$1 == n` と同じ一致にする）。
REPO_NAMES=(); REPO_STATES=(); REPO_OPEN=()
OPEN_LIMIT=1000
strip_zeros() { # <数字列> → strip_zeros_result（先頭の 0 を落とす。全部 0 なら 0）
  strip_zeros_result="${1#"${1%%[!0]*}"}"
  [ -n "${strip_zeros_result}" ] || strip_zeros_result=0
}
fetch_open_set() { # <owner/repo> → REPO_NAMES / REPO_STATES（ok|fail）/ REPO_OPEN へ 1 組追記する
  local repo="$1" out="" count=0 n="" set=" " strip_zeros_result=""
  out="${TMP}/open-${repo//\//_}"
  REPO_NAMES+=("${repo}")
  if [ "${OFFLINE}" -eq 1 ] || { [ -z "$GITHUB_INPUT" ] && ! command -v gh >/dev/null 2>&1; }; then
    REPO_STATES+=(fail); REPO_OPEN+=(" ")
    return 0
  fi
  # stdin を閉じる: gh は対話入力を待ちうるため、呼び出し元の read ループの入力を渡さない
  # （ループ側も fd 3 で読むので二重の防御。片方だけでも欠けはしないが、両方外さない）。
  if [ -n "$GITHUB_INPUT" ]; then
    local lib="$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/github-input.sh"
    if [ ! -r "$lib" ] || ! command -v jq >/dev/null 2>&1; then
      REPO_STATES+=(fail); REPO_OPEN+=(" "); return 0
    fi
    . "$lib"
    jq -n --arg repository "https://github.com/$repo" --argjson limit "$OPEN_LIMIT" '{repository:$repository,state:"open",limit:$limit}' >"${out}.scope"
    printf '{}\n' >"${out}.position"
    if ! github_file_read "$GITHUB_INPUT" lookup.open-set "${out}.scope" lookup "${out}.position" >"${out}.raw" 2>"${out}.err" ||
       { [ -n "$GITHUB_INPUT_HTTP_STATUS" ] && [ "$GITHUB_INPUT_HTTP_STATUS" != 200 ]; } ||
       [ "$GITHUB_INPUT_LAST" != true ] ||
       ! jq -e 'type == "array" and all(.[]; (.number | type == "number" and . > 0 and floor == .) and (.pull_request == null))' "${out}.raw" >/dev/null 2>&1; then
      REPO_STATES+=(fail); REPO_OPEN+=(" ")
      printf 'lookup.open-set --repo %s を取得できません（該当参照は 未確認 として扱います）\n' "$repo" >&2
      return 0
    fi
    jq -r '.[].number' "${out}.raw" >"$out"
  elif ! gh issue list --repo "${repo}" --state open --limit "${OPEN_LIMIT}" --json number --jq '.[].number' >"${out}" 2>"${out}.err" </dev/null; then
    local gh_err="" rest_lib="" rest_err=""
    gh_err="$(cat "${out}.err" 2>/dev/null || true)"
    rest_lib="$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/gh-rest-fallback.sh"
    if [ -f "$rest_lib" ] && [ ! -L "$rest_lib" ] && [ -r "$rest_lib" ] \
       && . "$rest_lib" 2>/dev/null \
       && declare -F ff_gh_is_graphql_unavailable >/dev/null 2>&1 \
       && ff_gh_is_graphql_unavailable "$gh_err"; then
      if ! ff_gh_rest_open_issue_numbers "${repo}" "${OPEN_LIMIT}" "${out}" "${out}.rest.err"; then
        rest_err="$(head -n 1 "${out}.rest.err" 2>/dev/null || true)"
        REPO_STATES+=(fail); REPO_OPEN+=(" ")
        printf 'gh issue list --repo %s の GraphQL 利用不可後の REST API フォールバックにも失敗しました（該当参照は 未確認 として扱います）: %s。%s\n' \
          "${repo}" "${rest_err:-不明}" "$(ff_gh_github_input_hint lookup)" >&2
        return 0
      fi
    else
      REPO_STATES+=(fail); REPO_OPEN+=(" ")
      printf 'gh issue list --repo %s に失敗しました（該当参照は 未確認 として扱います）: %s\n' "${repo}" "$(head -n 1 "${out}.err" 2>/dev/null)" >&2
      return 0
    fi
  fi
  count="$(awk 'END { print NR }' "${out}")"
  if [ "${count}" -ge "${OPEN_LIMIT}" ]; then
    REPO_STATES+=(fail); REPO_OPEN+=(" ")
    printf 'gh issue list --repo %s の open 一覧が上限 %s 件に達しました（打ち切りの可能性があるため 未確認 として扱います）\n' "${repo}" "${OPEN_LIMIT}" >&2
    return 0
  fi
  # 各行の最初の欄（前後の空白・CR を除く）を集合へ入れる。数字列でない欄はそのまま持つ。
  while IFS= read -r n || [ -n "${n}" ]; do
    n="${n#"${n%%[![:space:]]*}"}"
    n="${n%%[[:space:]]*}"
    [ -n "${n}" ] || continue
    case "${n}" in *[!0-9]*) ;; *) strip_zeros "${n}"; n="${strip_zeros_result}" ;; esac
    set="${set}${n} "
  done <"${out}"
  REPO_STATES+=(ok); REPO_OPEN+=("${set}")
}
issue_state() { # <owner/repo#N> → issue_state_result へ open|closed|未確認
  local repo="${1%#*}" num="${1##*#}" i=0 idx=-1 strip_zeros_result=""
  while [ "${i}" -lt "${#REPO_NAMES[@]}" ]; do
    if [ "${REPO_NAMES[${i}]}" = "${repo}" ]; then idx="${i}"; break; fi
    i=$((i + 1))
  done
  if [ "${idx}" -lt 0 ]; then
    fetch_open_set "${repo}"
    idx=$((${#REPO_NAMES[@]} - 1))
  fi
  if [ "${REPO_STATES[${idx}]}" != "ok" ]; then issue_state_result="未確認"; return 0; fi
  strip_zeros "${num}"
  case "${REPO_OPEN[${idx}]}" in
    *" ${strip_zeros_result} "*) issue_state_result="open" ;;
    *) issue_state_result="closed" ;;
  esac
}
# Issue 列（` / ` 区切り）の各要素から owner/repo#N だけを抽出し、参照直後へ state を付ける。
# 注記や空白の無い区切りは表示用に残し、gh の repo / number には渡さない。
# `skill:` / `doc:` / `なし` はそのまま。`#N` だけの旧形式（リポジトリ修飾なし）は解決せず `未確認`。
# 要素への分割と前後の空白の除去は bash の組み込みだけで行う（区切りは左から最初の ` / `。
# 空の要素・空白だけの要素は捨てる）。
annotate_refs() { # <Issue 列の値> → annotated_refs / refs_has_open / refs_has_unresolved
  local col="$1" out="" item="" st="" rest="" annotated="" ref="" items="" more=1
  local ref_pattern='[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+'
  local issue_state_result=""
  annotated_refs=""; refs_has_open=0; refs_has_unresolved=0
  [ -n "${col}" ] || return 0
  items="${col}"
  while [ "${more}" -eq 1 ]; do
    case "${items}" in
      *" / "*) item="${items%%" / "*}"; items="${items#*" / "}" ;;
      *) item="${items}"; more=0 ;;
    esac
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [ -n "${item}" ] || continue
    case "${item}" in
      skill:*|doc:*|なし) ;;
      *)
        rest="${item}"; annotated=""
        while [[ "${rest}" =~ ${ref_pattern} ]]; do
          ref="${BASH_REMATCH[0]}"
          issue_state "${ref}"
          st="${issue_state_result}"
          case "${st}" in
            open) refs_has_open=1 ;;
            未確認) refs_has_unresolved=1 ;;
          esac
          annotated="${annotated}${rest%%"${ref}"*}${ref}(${st})"
          rest="${rest#*"${ref}"}"
        done
        if [ -n "${annotated}" ]; then
          item="${annotated}${rest}"
        else
          case "${item}" in
            \#[0-9]*) item="${item}(未確認: リポジトリ修飾なし)"; refs_has_unresolved=1 ;;
          esac
        fi ;;
    esac
    if [ -z "${out}" ]; then out="${item}"; else out="${out} / ${item}"; fi
  done
  annotated_refs="${out}"
}

# ── 出力 ──────────────────────────────────────────────────────────────────────
# 状態ラベル
obs_status_label() {
  case "$1" in
    active) printf '%s' "未対策（active。蓄積中の落とし穴 — 回避策はエントリ本文の → 以降）" ;;
    promoted) printf '%s' "対策 Issue あり（promoted。Issue 列の state を見る: open = 対応中 / closed = 完了照合前または対策後の再発（最新メモで区別））" ;;
    mitigated) printf '%s' "対策済み（mitigated。元 Issue と所在は Issue 列。最新メモの未解消再発も確認する）" ;;
    archived) printf '%s' "休眠（archived。再発なしで archive 済み、または統合元 — Issue 列が統合先を指す）" ;;
    *) printf '%s' "状態不明（$1）" ;;
  esac
}
ace_status_label() {
  case "$1" in
    active) printf '%s' "有効（active）" ;;
    deprecated) printf '%s' "非推奨（deprecated。適用しない）" ;;
    archived) printf '%s' "アーカイブ（playbook/archive/。stale。参考のみ）" ;;
    *) printf '%s' "状態不明（$1）" ;;
  esac
}

# emit_ace / emit_obs はメタを entries_meta で先に取り出し（awk 1 回）、ループ内では外部プロセスを
# 起動しない。取り出した一覧は入力と同じ一時領域に `<入力>.meta` として置く。
emit_ace() { # <entries file> <forced status or ""> → stdout 行を状態別に並べる。副作用: ACE_IDS へ ID を追記
  local file="$1" forced="$2" st="" cat="" helpful="" loc="" anchor="" rel="" id title src end
  [ -s "${file}" ] || return 0
  entries_meta "${file}" Status Category Helpful >"${file}.meta"
  while IFS=$'\037' read -r id title src anchor st cat helpful end <&3; do
    if [ -n "${forced}" ]; then st="${forced}"; else [ -n "${st}" ] || st="unknown"; fi
    case "${src}" in "${ROOT}"/*) rel="${src#"${ROOT}"/}" ;; *) rel="${src}" ;; esac
    loc="${rel}#${anchor}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${st}" "${id}" "Category=${cat:-?} Helpful=${helpful:-?}" "${title}" "${loc}" "ace" >>"${TMP}/rows"
    printf '%s\n' "${id}" >>"${TMP}/ace-ids"
  done 3<"${file}.meta"
}
emit_obs() { # <entries file> → 行を追加。副作用: OBS_IDS
  local file="$1" st kind count last issue refs id title src anchor rel end
  local annotated_refs refs_has_open refs_has_unresolved
  [ -s "${file}" ] || return 0
  entries_meta "${file}" Status Kind Count Last Issue >"${file}.meta"
  while IFS=$'\037' read -r id title src anchor st kind count last issue end <&3; do
    [ -n "${st}" ] || st="unknown"
    if [ "${INCLUDE_ARCHIVED}" -eq 0 ] && [ "${st}" = "archived" ] && [ "${MODE}" = "search" ]; then continue; fi
    refs=""; refs_has_open=0; refs_has_unresolved=0
    case "${st}" in
      promoted|mitigated) annotate_refs "${issue}"; refs="${annotated_refs}" ;;
      *) refs="${issue}" ;;
    esac
    case "${src}" in "${ROOT}"/*) rel="${src#"${ROOT}"/}" ;; *) rel="${src}" ;; esac
    # 内部列 7/8 に判定用 state を持つ。公開 text / tsv は従来の表示列だけを返す。
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${st}" "${id}" "Kind=${kind:-?} Count=${count:-?} Last=${last:-?} Issue=${refs:-なし}" "${title}" "${rel}#${anchor}" "obs" "${refs_has_open}" "${refs_has_unresolved}" >>"${TMP}/rows"
    printf '%s\n' "${id}" >>"${TMP}/obs-ids"
  done 3<"${file}.meta"
}

: >"${TMP}/rows"; : >"${TMP}/ace-ids"; : >"${TMP}/obs-ids"

print_group() { # <store: ace|obs> <status> <label>
  local store="$1" st="$2" label="$3" n=0
  n="$(awk -F '\t' -v s="${store}" -v st="${st}" '$6 == s && $1 == st { c++ } END { print c + 0 }' "${TMP}/rows")"
  [ "${n}" -gt 0 ] || return 0
  if [ "${FORMAT}" = "tsv" ]; then
    awk -F '\t' -v s="${store}" -v st="${st}" 'BEGIN { OFS = "\t" } $6 == s && $1 == st { print $6, $2, $1, $3, $4, $5 }' "${TMP}/rows"
    return 0
  fi
  printf -- '-- %s: %s 件 --\n' "${label}" "${n}"
  awk -F '\t' -v s="${store}" -v st="${st}" '$6 == s && $1 == st { printf "%s  %s\n      %s  (%s)\n", $2, $4, $3, $5 }' "${TMP}/rows"
}

record_word() { # <state> <ids file> <不在の語>
  local state="$1" ids="$2" absent_word="$3"
  case "${state}" in
    ok|empty)
      if [ -s "${ids}" ]; then paste -sd, "${ids}"; else printf '%s\n' "0 件"; fi ;;
    absent) printf '%s\n' "${absent_word}" ;;
    ambiguous) printf '%s\n' "読み取り失敗（配置が曖昧。--playbook / --ledger で指定）" ;;
    unreadable) printf '%s\n' "読み取り失敗（ファイルを読めない）" ;;
    noentry) printf '%s\n' "読み取り失敗（エントリ見出しを認識できない — 書式変更の可能性）" ;;
    *) printf '%s\n' "読み取り失敗（${state}）" ;;
  esac
}

# ── --ledger-dump: 台帳の全エントリを TSV で出して終える ─────────────────────
# メタは entries_meta（検索・突き合わせと同じ取り出し規則）で先に取り、ブロック本文と行番号で
# 突き合わせる。どちらも OBS_ENTRIES と同じ順・同じ件数で並ぶ。件数や ID が食い違ったら、列が
# ずれた出力を返さず 2 で止める（消費側は列の位置で読む）。
if [ "${MODE}" = "ledger-dump" ]; then
  dump_n=0
  if [ -s "${OBS_ENTRIES}" ]; then
    entries_meta "${OBS_ENTRIES}" Status Kind Count First Last Issue >"${OBS_ENTRIES}.meta"
    awk -F '\037' -v root="${ROOT}/" '
      NR == FNR { meta[FNR] = $0; nmeta = FNR; next }
      {
        if (!(FNR in meta)) { bad = 1; exit }
        n = split(meta[FNR], m, "\037")
        if (n < 11 || m[1] != $1) { bad = 1; exit }
        rel = m[3]; if (index(rel, root) == 1) rel = substr(rel, length(root) + 1)
        text = $4; gsub(/\t/, " ", text)
        for (i = 1; i <= 10; i++) gsub(/\t/, " ", m[i])
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s#%s\t%s\t%s\n", m[1], m[5], m[6], m[7], m[8], m[9], m[10], rel, m[4], m[2], text
        rows++
      }
      END { if (bad || rows != nmeta) exit 2 }
    ' "${OBS_ENTRIES}.meta" "${OBS_ENTRIES}" || {
      printf '観測台帳のメタと本文を突き合わせられません（エントリ件数の不一致）: %s\n' "${OBS_FILE}" >&2
      exit 2
    }
    dump_n="$(awk 'END { print NR }' "${OBS_ENTRIES}")"
  fi
  printf 'SUMMARY ledger=%s entries=%s state=%s\n' "${OBS_FILE#"${ROOT}"/}" "${dump_n}" "${OBS_STATE}"
  exit 0
fi

if [ "${MODE}" = "promoted-open" ]; then
  # promoted を取得した state / 修飾なしの未確認で絞る。表示注記の state は判定に使わない。
  emit_obs "${OBS_ENTRIES}"
  awk -F '\t' 'BEGIN { OFS = "\t" } $6 == "obs" && $1 == "promoted" { print }' "${TMP}/rows" >"${TMP}/promoted"
  awk -F '\t' '$7 == 1 || $8 == 1 { print }' "${TMP}/promoted" >"${TMP}/promoted-open"
  total="$(awk 'END { print NR }' "${TMP}/promoted")"
  hit="$(awk 'END { print NR }' "${TMP}/promoted-open")"
  unresolved="$(awk -F '\t' '$8 == 1 { c++ } END { print c + 0 }' "${TMP}/promoted")"
  if [ "${FORMAT}" = "tsv" ]; then
    awk -F '\t' 'BEGIN { OFS = "\t" } { print $6, $2, $1, $3, $4, $5 }' "${TMP}/promoted-open"
  else
    printf '== 観測台帳 promoted × open の突き合わせ（%s） ==\n' "${OBS_FILE#"${ROOT}"/}"
    if [ "${hit}" -eq 0 ]; then
      printf '%s\n' "（該当なし: promoted ${total} 件のうち open の昇格先を持つものは 0 件）"
    else
      printf '%s\n' "このセッションの事象と 1 件ずつ突き合わせる。再発していれば Count +1 と観測メモに加え、open の Issue へ再発の実測をコメント追記する（/retrospective 昇格閾値と特急レーン）:"
      awk -F '\t' '{ printf "%s  %s\n      %s  (%s)\n", $2, $4, $3, $5 }' "${TMP}/promoted-open"
    fi
  fi
  printf 'SUMMARY promoted=%s open_or_unresolved=%s unresolved=%s offline=%s\n' "${total}" "${hit}" "${unresolved}" "${OFFLINE}"
  if [ "${unresolved}" -gt 0 ] && [ "${OFFLINE}" -eq 0 ]; then
    printf '%s\n' "  ※ state を確認できなかった参照があります。隠していないので、一覧の (未確認) を手で確認してください。" >&2
  fi
  exit 0
fi

# ── 採用前の保留候補・未反映判定・検索実行パス（resolve/promoted-open/ledger-dump には混ぜない） ───
PENDING_FILE=""; PENDING_PRESENT=0; pending_n=0
if [ "${ACE_STATE}" = "ok" ] || [ "${ACE_STATE}" = "empty" ]; then
  PENDING_FILE="${ACE_INDEX%/*}/PENDING_CANDIDATES.md"
  if [ -e "$PENDING_FILE" ] || [ -L "$PENDING_FILE" ]; then
    pending_lib="${BASH_SOURCE[0]%/*}/lib/ace-pending-functions.sh"
    if [ ! -f "$pending_lib" ] || [ ! -r "$pending_lib" ] || [ -L "$pending_lib" ]; then
      printf 'ACE pending: 候補parserを読めません: %s\n' "$pending_lib" >&2
      exit 2
    fi
    # shellcheck source=lib/ace-pending-functions.sh
    . "$pending_lib"
    pending_snapshot="$(snapshot_store_input "$PENDING_FILE")" || exit 2
    ff_ace_pending_validate "$pending_snapshot" || exit 2
    PENDING_PRESENT=1
    extract_entries PENDING "$PENDING_FILE" >"${TMP}/pending-entries" || exit 2
  fi
fi

unreflected_lib="${BASH_SOURCE[0]%/*}/lib/knowledge-lookup-unreflected.sh"
if [ ! -f "$unreflected_lib" ] || [ ! -r "$unreflected_lib" ] || [ -L "$unreflected_lib" ]; then
  printf '未反映の判定 lib を読めません: %s\n' "$unreflected_lib" >&2
  exit 2
fi
# shellcheck source=lib/knowledge-lookup-unreflected.sh
. "$unreflected_lib"

# active な Playbook タイトルから作業クラス語候補を最大 8 件抽出して stdout（text 時）へ出す。
# LC_ALL=C 下で扱うため長さ閾値（全体 8..42B / 左右各 4B 以上 / 補完 4..36B）はバイト基準。
# 第 1 層で `<左>の<右>` 句を頻度順→初出順で採り、8 件に満たない分を第 2 層（非ストップワード短句）で補う。
emit_class_candidates() {
  local existing_kws="" _kw="" class_candidates=""
  [ "$USE_TYPED_ARGS" -eq 1 ] && [ "${FORMAT}" = "text" ] && [ "${ACE_STATE}" = "ok" ] && [ -s "${ACE_ENTRIES}" ] || return 0
  for _kw in ${KEYWORDS[@]+"${KEYWORDS[@]}"}; do
    existing_kws="${existing_kws:+${existing_kws}$'\037'}${_kw}"
  done
  if ! class_candidates="$(KL_CAND_EXISTING_KWS="$existing_kws" LC_ALL=C awk -F '\037' '
    BEGIN {
      len_no = length("の")
      if (ENVIRON["KL_CAND_EXISTING_KWS"] != "") {
        kn = split(ENVIRON["KL_CAND_EXISTING_KWS"], karr, "\037")
        for (ki = 1; ki <= kn; ki++) {
          k = tolower(karr[ki])
          if (k != "") passed[k] = 1
        }
      }
    }
    {
      if ($4 ~ /\|[[:space:]]*Status[[:space:]]*\|[[:space:]]*(deprecated|archived)[[:space:]]*\|/) next
      t = $2
      gsub(/[[:cntrl:]]/, " ", t)
      if (t == "") next
      gsub(/`|、|。|（|）|「|」|『|』|—|–|→|⇒|：|／|・|　|[()\[\],;:|\/]/, "\n", t)
      n = split(t, segs, "\n")
      for (i = 1; i <= n; i++) {
        s = segs[i]
        gsub(/(ときは|場合は|には|では|とは|から|まで|より|ため|ほど|など|だけ|ごと|つつ|ずに|せず|しない|して|した|する|され|させ|ある|ない|なる|へ|を|が|は|に|で|と)/, "\n", s)
        m = split(s, parts, "\n")
        for (j = 1; j <= m; j++) {
          p = parts[j]
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", p)
          while (substr(p, 1, len_no) == "の") p = substr(p, 1 + len_no)
          while (length(p) >= len_no && substr(p, length(p) - len_no + 1) == "の") p = substr(p, 1, length(p) - len_no)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", p)
          if (p == "" || tolower(p) in passed) continue
          pos = index(p, "の")
          if (pos > 1 && length(p) >= 8 && length(p) <= 42) {
            left = substr(p, 1, pos - 1)
            right = substr(p, pos + len_no)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", left)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", right)
            if (length(left) >= 4 && length(right) >= 4 && index(right, "の") == 0 \
                && left !~ /^(こ|そ|あ|ど|この|その|あの|どの|別|同|他|全|各|次|前|後|元|今|自|ここ|そこ|これ|それ|あれ|どれ|どちら|すべて|両方|片方|複数|既存|新規|実際|対象|該当|同じ|別の|他の|前の|次の)$/ \
                && right !~ /^(まま|ほう|方|もの|こと|うち|あいだ|中|上|下|前|後|先|側|分|ぶん|場|行|値|数|点|件|回|度|とき|場合|ため|よう|だけ|ほど|まで|から|より|ほうへ|まま通る|ほうを|一部|全部|全体|中身|末尾|先頭|直前|直後|外側|内側|片側|両方)$/) {
              t1_freq[p]++
              if (!(p in t1_first)) t1_first[p] = ++t1_ord
              continue
            }
          }
          if (length(p) >= 4 && length(p) <= 36 \
              && p !~ /^[[:space:]]*$/ \
              && p !~ /^(こ|そ|あ|ど|この|その|あの|どの|別|同|他|全|各|次|前|後|元|今|自|ここ|そこ|これ|それ|あれ|どれ|どちら|すべて|両方|片方|複数|既存|新規|実際|対象|該当|同じ|別の|他の|前の|次の|まま|ほう|方|もの|こと|ため|場合|とき)$/) {
            t2_freq[p]++
            if (!(p in t2_first)) t2_first[p] = ++t2_ord
          }
        }
      }
    }
    END {
      out = ""
      count = 0
      for (k = 1; k <= 8; k++) {
        best = ""; best_f = 0; best_o = 0
        for (p in t1_freq) {
          if (used[p]) continue
          if (t1_freq[p] > best_f || (t1_freq[p] == best_f && t1_first[p] < best_o)) {
            best = p; best_f = t1_freq[p]; best_o = t1_first[p]
          }
        }
        if (best == "") break
        used[best] = 1
        out = (out == "" ? best : out " / " best)
        count++
      }
      while (count < 8) {
        best = ""; best_f = 0; best_o = 0
        for (p in t2_freq) {
          if (used[p]) continue
          if (t2_freq[p] > best_f || (t2_freq[p] == best_f && t2_first[p] < best_o)) {
            best = p; best_f = t2_freq[p]; best_o = t2_first[p]
          }
        }
        if (best == "") break
        used[best] = 1
        out = (out == "" ? best : out " / " best)
        count++
      }
      if (out != "") printf "%s", out
    }
  ' "${ACE_ENTRIES}" 2>/dev/null)"; then
    printf '%s\n' '警告: 作業クラス語の候補を抽出できませんでした' >&2
    class_candidates=""
  fi
  if [ -n "$class_candidates" ]; then
    printf '\n== 作業クラス語の候補（Playbook タイトル由来） ==\n  %s\n' "$class_candidates"
  fi
}

LAST_PASS_ACE_N=0
LAST_PASS_OBS_N=0
UNREFLECTED_COLLECTED=0
UNREFLECTED_PREFIX=""
: >"${TMP}/ace-ids-union"; : >"${TMP}/obs-ids-union"
: >"${TMP}/pending-ids-union"; : >"${TMP}/unreflected-ids-union"

# 1 系統ぶん（または全体）の検索を実行し、指定形式で出力と RECORD 行を出す。
run_search_pass() {
  local axis_tag="$1" axis_heading="$2" pass_kw_file="$3" show_candidates="$4"
  local id title src anchor cat origin end rel ace_n obs_n kw_desc

  KW_FILE="$pass_kw_file"
  : >"${TMP}/rows"; : >"${TMP}/ace-ids"; : >"${TMP}/obs-ids"; : >"${TMP}/pending-ids"; : >"${TMP}/unreflected-ids"
  pending_n=0

  if [ "$PENDING_PRESENT" -eq 1 ]; then
    filter_entries <"${TMP}/pending-entries" >"${TMP}/pending-hit"
    entries_meta "${TMP}/pending-hit" Category Origin >"${TMP}/pending-meta"
    while IFS=$'\037' read -r id title src anchor cat origin end <&3; do
      case "$src" in "${ROOT}"/*) rel="${src#"${ROOT}"/}" ;; *) rel="$src" ;; esac
      # rows の内部形式は status が末尾。print_group が公開 TSV の第 3 列へ移す。
      printf 'pending\t%s\tCategory=%s Origin=%s\t%s\t%s#%s\tpending\n' \
        "$id" "$cat" "$origin" "$title" "$rel" "$anchor" >>"${TMP}/rows"
      printf '%s\n' "$id" >>"${TMP}/pending-ids"
    done 3<"${TMP}/pending-meta"
    pending_n="$(awk 'END { print NR }' "${TMP}/pending-ids")"
    cat "${TMP}/pending-ids" >>"${TMP}/pending-ids-union"
  fi

  if [ "$UNREFLECTED_COLLECTED" -eq 0 ]; then
    unreflected_collect
    UNREFLECTED_COLLECTED=1
    if [ "$UNREFLECTED_STATE" != off ]; then
      UNREFLECTED_PREFIX="$(git -C "${ROOT}" rev-parse --show-prefix 2>/dev/null)" || UNREFLECTED_PREFIX=""
    fi
  elif [ "$UNREFLECTED_STATE" != off ] && [ "$UNREFLECTED_STATE" != error ] && [ -s "${TMP}/unreflected-ace.refs" ]; then
    unreflected_emit ace "${TMP}/unreflected-root.ace" "${TMP}/unreflected-ace.refs" "${TMP}/unreflected-root" "$UNREFLECTED_PREFIX" Category Helpful
    unreflected_emit obs "${TMP}/unreflected-root.obs" "${TMP}/unreflected-obs.refs" "${TMP}/unreflected-root" "$UNREFLECTED_PREFIX" Kind Count Last
  fi
  [ ! -s "${TMP}/unreflected-ids" ] || cat "${TMP}/unreflected-ids" >>"${TMP}/unreflected-ids-union"

  # live が空（empty）でも archive は引く — 全エントリを archive へ移した Playbook で
  # `--include-archived` が 0 件になるのを避ける（codex-cli のレビュー指摘）。
  if [ "${ACE_STATE}" = "ok" ] || [ "${ACE_STATE}" = "empty" ]; then
    filter_entries <"${ACE_ENTRIES}" >"${TMP}/ace-hit"
    emit_ace "${TMP}/ace-hit" ""
    if [ -s "${ACE_ARCHIVE_ENTRIES}" ]; then
      filter_entries <"${ACE_ARCHIVE_ENTRIES}" >"${TMP}/ace-arch-hit"
      emit_ace "${TMP}/ace-arch-hit" "archived"
    fi
  fi
  if [ "${OBS_STATE}" = "ok" ]; then
    filter_entries <"${OBS_ENTRIES}" >"${TMP}/obs-hit"
    emit_obs "${TMP}/obs-hit"
  fi

  cat "${TMP}/ace-ids" >>"${TMP}/ace-ids-union"
  cat "${TMP}/obs-ids" >>"${TMP}/obs-ids-union"
  ace_n="$(awk 'END { print NR }' "${TMP}/ace-ids")"
  obs_n="$(awk 'END { print NR }' "${TMP}/obs-ids")"
  LAST_PASS_ACE_N="$ace_n"
  LAST_PASS_OBS_N="$obs_n"
  kw_desc="$(paste -sd, "${KW_FILE}")"

  if [ "${FORMAT}" = "text" ]; then
    if [ -n "$axis_heading" ]; then
      printf '%s\n' "$axis_heading"
    fi
    printf '== ACE Playbook（%s） ==\n' "$( [ -n "${ACE_INDEX}" ] && printf '%s' "${ACE_INDEX#"${ROOT}"/}" || printf '%s' "${ACE_STATE}" )"
    case "${ACE_STATE}" in
      ok) if [ "${ace_n}" -eq 0 ]; then printf '（0 件: %s）\n' "${kw_desc}"; fi ;;
      empty) if [ "${ace_n}" -eq 0 ]; then printf '%s\n' "（0 件: Playbook はあるが live エントリが無い）"; fi ;;
      absent) printf '%s\n' "（Playbook なし — ACE 未導入。/ace-setup で配置できる）" ;;
      *) printf '（読み取り失敗: %s）\n' "$(record_word "${ACE_STATE}" /dev/null "")" ;;
    esac
    print_group ace active "$(ace_status_label active)"
    print_group ace deprecated "$(ace_status_label deprecated)"
    print_group ace archived "$(ace_status_label archived)"
    print_group ace unknown "$(ace_status_label unknown)"
    printf '\n== 観測台帳（%s） ==\n' "$( [ -n "${OBS_FILE}" ] && printf '%s' "${OBS_FILE#"${ROOT}"/}" || printf '%s' "${OBS_STATE}" )"
    case "${OBS_STATE}" in
      ok) if [ "${obs_n}" -eq 0 ]; then printf '（0 件: %s）\n' "${kw_desc}"; fi ;;
      empty) printf '%s\n' "（0 件: 台帳はあるがエントリが無い）" ;;
      absent) printf '%s\n' "（台帳なし — /retrospective が初回実行時にテンプレートから作成する）" ;;
      *) printf '（読み取り失敗: %s）\n' "$(record_word "${OBS_STATE}" /dev/null "")" ;;
    esac
    print_group obs active "$(obs_status_label active)"
    print_group obs promoted "$(obs_status_label promoted)"
    print_group obs mitigated "$(obs_status_label mitigated)"
    print_group obs archived "$(obs_status_label archived)"
    print_group obs unknown "$(obs_status_label unknown)"
    if [ "$PENDING_PRESENT" -eq 1 ]; then
      printf '\n== ACE 保留候補（%s） ==\n' "${PENDING_FILE#"${ROOT}"/}"
      if [ "$pending_n" -eq 0 ]; then printf '（0 件: %s）\n' "${kw_desc}"; fi
      print_group pending pending '保留（pending。採用前の候補、有効なACEではない）'
    fi
    unreflected_print_text
    if [ "$show_candidates" -eq 1 ]; then
      emit_class_candidates
    fi
    printf '\n'
  else
    print_group ace active x; print_group ace deprecated x; print_group ace archived x; print_group ace unknown x
    print_group obs active x; print_group obs promoted x; print_group obs mitigated x; print_group obs archived x; print_group obs unknown x
    if [ "$PENDING_PRESENT" -eq 1 ]; then print_group pending pending x; fi
    if [ "$UNREFLECTED_STATE" != off ]; then print_group ace unreflected x; print_group obs unreflected x; fi
  fi

  if [ -n "$axis_tag" ]; then
    printf 'RECORD %s ace=%s obs=%s' "$axis_tag" "$(record_word "${ACE_STATE}" "${TMP}/ace-ids" "Playbook なし")" "$(record_word "${OBS_STATE}" "${TMP}/obs-ids" "台帳なし")"
  else
    printf 'RECORD ace=%s obs=%s' "$(record_word "${ACE_STATE}" "${TMP}/ace-ids" "Playbook なし")" "$(record_word "${OBS_STATE}" "${TMP}/obs-ids" "台帳なし")"
  fi
  if [ "$PENDING_PRESENT" -eq 1 ]; then printf ' pending=%s' "$(record_word ok "${TMP}/pending-ids" '')"; fi
  if [ "$UNREFLECTED_STATE" != off ]; then printf ' unreflected=%s' "$(unreflected_record_word)"; fi
  if [ -z "$axis_tag" ] && [ "$USE_TYPED_ARGS" -eq 1 ]; then
    if [ "${#IMPL_KEYWORDS[@]}" -eq 0 ]; then printf ' impl=未指定'; fi
    if [ "${#CLASS_KEYWORDS[@]}" -eq 0 ]; then printf ' class=未指定'; fi
  fi
  # 語は行の最後の欄に置く（空白を含む語でも、keyword= から行末までが語）。
  if [ "$axis_tag" = each ]; then printf ' keyword=%s' "$EACH_KEYWORD"; fi
  printf '\n'
}

if [ "$USE_TYPED_ARGS" -eq 1 ]; then
  if [ "${#CLASS_KEYWORDS[@]}" -eq 0 ]; then
    printf '%s\n' '警告: 作業クラス語（--class）が未指定です。対象の名前だけで検索すると作業の種類に関する既存知見を見落としやすいため、--class <作業クラス語>... を併記して再検索してください。' >&2
  fi
  if [ "${#IMPL_KEYWORDS[@]}" -eq 0 ]; then
    printf '%s\n' '警告: 実装語（--impl）が未指定です。--impl <実装語>... を併記すると変更対象の固有知見も併せて確認できます。' >&2
  fi
fi

if [ "$USE_TYPED_ARGS" -eq 1 ] && [ "${#IMPL_KEYWORDS[@]}" -gt 0 ] && [ "${#CLASS_KEYWORDS[@]}" -gt 0 ]; then
  : >"${TMP}/kw-impl"
  for _kw in "${IMPL_KEYWORDS[@]}"; do printf '%s\n' "${_kw}" >>"${TMP}/kw-impl"; done
  : >"${TMP}/kw-class"
  for _kw in "${CLASS_KEYWORDS[@]}"; do printf '%s\n' "${_kw}" >>"${TMP}/kw-class"; done

  run_search_pass "impl" "=== 系統: 実装語（--impl） ===" "${TMP}/kw-impl" 0
  impl_ace_n="$LAST_PASS_ACE_N"
  impl_obs_n="$LAST_PASS_OBS_N"

  if [ "${FORMAT}" = "text" ]; then printf '\n'; fi
  run_search_pass "class" "=== 系統: 作業クラス語（--class） ===" "${TMP}/kw-class" 1
  class_ace_n="$LAST_PASS_ACE_N"
  class_obs_n="$LAST_PASS_OBS_N"

  ace_n="$(awk '!seen[$0]++ { c++ } END { print c + 0 }' "${TMP}/ace-ids-union")"
  obs_n="$(awk '!seen[$0]++ { c++ } END { print c + 0 }' "${TMP}/obs-ids-union")"
  pending_n="$(awk '!seen[$0]++ { c++ } END { print c + 0 }' "${TMP}/pending-ids-union")"
  unreflected_union_n="$(awk '!seen[$0]++ { c++ } END { print c + 0 }' "${TMP}/unreflected-ids-union")"

  printf 'SUMMARY ace=%s obs=%s keywords=%s match=%s include_archived=%s offline=%s ace_state=%s obs_state=%s' \
    "${ace_n}" "${obs_n}" "${#KEYWORDS[@]}" "$( [ "${MATCH_ALL}" -eq 1 ] && printf all || printf any )" "${INCLUDE_ARCHIVED}" "${OFFLINE}" "${ACE_STATE}" "${OBS_STATE}"
  if [ "$PENDING_PRESENT" -eq 1 ]; then printf ' pending=%s pending_state=ok' "$pending_n"; fi
  if [ "$UNREFLECTED_STATE" != off ]; then
    printf ' unreflected=%s unreflected_commits=%s unreflected_state=%s' "$unreflected_union_n" "$UNREFLECTED_COMMITS" "$UNREFLECTED_STATE"
  fi
  printf ' impl_keywords=%s class_keywords=%s impl_ace=%s impl_obs=%s class_ace=%s class_obs=%s\n' \
    "${#IMPL_KEYWORDS[@]}" "${#CLASS_KEYWORDS[@]}" "$impl_ace_n" "$impl_obs_n" "$class_ace_n" "$class_obs_n"
elif [ "$EACH" -eq 1 ]; then
  # 語ごとの検索: store の読み取りは上で済んでいるので、語の数だけ回るのは照合と出力だけ。
  each_i=0
  for EACH_KEYWORD in "${KEYWORDS[@]}"; do
    each_i=$((each_i + 1))
    printf '%s\n' "$EACH_KEYWORD" >"${TMP}/kw-each"
    if [ "${FORMAT}" = "text" ] && [ "$each_i" -gt 1 ]; then printf '\n'; fi
    run_search_pass "each" "=== 語: ${EACH_KEYWORD} ===" "${TMP}/kw-each" 0
  done
  ace_n="$(awk '!seen[$0]++ { c++ } END { print c + 0 }' "${TMP}/ace-ids-union")"
  obs_n="$(awk '!seen[$0]++ { c++ } END { print c + 0 }' "${TMP}/obs-ids-union")"
  pending_n="$(awk '!seen[$0]++ { c++ } END { print c + 0 }' "${TMP}/pending-ids-union")"
  unreflected_union_n="$(awk '!seen[$0]++ { c++ } END { print c + 0 }' "${TMP}/unreflected-ids-union")"
  printf 'SUMMARY ace=%s obs=%s keywords=%s match=any include_archived=%s offline=%s ace_state=%s obs_state=%s' \
    "${ace_n}" "${obs_n}" "${#KEYWORDS[@]}" "${INCLUDE_ARCHIVED}" "${OFFLINE}" "${ACE_STATE}" "${OBS_STATE}"
  if [ "$PENDING_PRESENT" -eq 1 ]; then printf ' pending=%s pending_state=ok' "$pending_n"; fi
  if [ "$UNREFLECTED_STATE" != off ]; then
    printf ' unreflected=%s unreflected_commits=%s unreflected_state=%s' "$unreflected_union_n" "$UNREFLECTED_COMMITS" "$UNREFLECTED_STATE"
  fi
  printf ' each_keywords=%s\n' "${#KEYWORDS[@]}"
else
  run_search_pass "" "" "${KW_FILE}" "$USE_TYPED_ARGS"
  ace_n="$LAST_PASS_ACE_N"
  obs_n="$LAST_PASS_OBS_N"
  printf 'SUMMARY ace=%s obs=%s keywords=%s match=%s include_archived=%s offline=%s ace_state=%s obs_state=%s' \
    "${ace_n}" "${obs_n}" "${#KEYWORDS[@]}" "$( [ "${MATCH_ALL}" -eq 1 ] && printf all || printf any )" "${INCLUDE_ARCHIVED}" "${OFFLINE}" "${ACE_STATE}" "${OBS_STATE}"
  if [ "$PENDING_PRESENT" -eq 1 ]; then printf ' pending=%s pending_state=ok' "$pending_n"; fi
  if [ "$UNREFLECTED_STATE" != off ]; then
    printf ' unreflected=%s unreflected_commits=%s unreflected_state=%s' "$(awk 'END { print NR }' "${TMP}/unreflected-ids")" "$UNREFLECTED_COMMITS" "$UNREFLECTED_STATE"
  fi
  if [ "$USE_TYPED_ARGS" -eq 1 ]; then
    printf ' impl_keywords=%s class_keywords=%s' "${#IMPL_KEYWORDS[@]}" "${#CLASS_KEYWORDS[@]}"
  fi
  printf '\n'
fi
exit 0
