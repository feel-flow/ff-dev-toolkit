#!/usr/bin/env bash
#
# check-closing-keywords.sh — Refs 運用 Issue に対する closing keyword 抵触検査
#
# 使い方:
#   check-closing-keywords.sh --refs-issue <ISSUE> [--refs-issue <ISSUE> ...] \
#                             [--closes-issue <ISSUE> ...] [--repo <owner/repo>]
#   check-closing-keywords.sh --list-keywords
#
#   <ISSUE> は `123` / `#123` / `owner/repo#123` のいずれか。**参照されている形の
#   まま渡すこと**。一致対象は「同じ Issue を指す表記すべて」で、次のように決まる:
#     - 裸の番号 → `#123` と `<--repo の値>#123`
#     - `owner/repo#123` で owner/repo が --repo と同じ → 上と同じ（裸の `#123` も
#       同じ Issue を閉じるため、修飾を必須にすると見逃す）
#     - `owner/repo#123` で owner/repo が --repo と違う → 完全修飾形のみ
#       （その PR のリポジトリでの裸の `#123` は別の Issue なので抵触ではない）
#
#   検査対象のテキストは stdin から 1 行 1 件で渡す。各行の形式は
#   `<origin><TAB><text>`（例: `title<TAB>fix: #373 …`）。TAB が無い行は
#   origin を `-` として扱う。origin は報告にそのまま載るラベルで、
#   検査結果には影響しない。
#
# 何を検査するか:
#   squash merge のメッセージに closing keyword が Issue 参照と**隣接**して現れると、
#   PR 本文を `Refs #N` にしても Issue はマージ時に閉じる。`gh pr view --json
#   closingIssuesReferences` は PR 本文しか見ない（コミットメッセージは見ない）ため、この経路は
#   「閉じない」と報告しながら閉じる。
#
#   隣接一致だけを見るのが要点。`chore: #360 … (#368)` のように keyword と
#   Issue 番号が同じ行に居るだけの通常のコミット件名は抵触ではない。「keyword が
#   どこかにあり、かつ #N がどこかにある」で検出すると、ほぼ全ての PR で発火して
#   ゲートが無視されるようになる。
#
#   本スクリプトは渡されたテキストしか見ない。「何を渡すか」（供給源のスキャンか、
#   実際に渡す squash メッセージか）は呼び出し側の責務で、skills/close-issue/
#   SKILL.md の手順 2 がその両方を定義している。
#
# 既知の限界（検出しない参照形式）:
#   GitHub は `GH-123` 形式と Issue の完全 URL も closing reference として解釈するが、
#   本スクリプトは `#123` / `owner/repo#123` しか見ない。Conventional Commits の件名に
#   これらが現れる頻度は低いため対象外としている。**件名にこの 2 形式を書かないこと**
#   （書くとゲートが緑を返したままマージで閉じる）。
#
# 対象 Issue の指定:
#   --refs-issue   open のまま維持したい Issue（検査対象）。閉じたら事故
#   --closes-issue 意図して閉じる Issue（検査対象外。明示することで、同じ PR が
#                  両方の Issue を扱う場合に取り違えを防ぐ）
#   同じ Issue を両方に渡した場合は意図が矛盾しているため使い方の誤りとして止める。
#
# 終了コード:
#   0 = 抵触なし（--refs-issue が 0 件のときもここ。従来どおりの Closes 運用）
#   1 = 抵触あり
#   2 = 使い方の誤り / 検査が成立しない（fail-closed）
#   上記以外の非 0（コマンド不在の 127 など）も**検査不成立**として扱うこと。
#   呼び出し側は `0` と `1` 以外をすべて停止側へ倒す。
#
# 出力:
#   stdout … 機械可読の結果行のみ（TAB 区切り）
#             INSPECTED<TAB>実際に検査した行数（常に 1 行出る）
#             CONFLICT <TAB>origin<TAB>issue<TAB>抵触したテキスト
#             SUGGEST  <TAB>origin<TAB>issue<TAB>Issue 参照を除いた機械的な改題案
#   stderr … 人間向けの説明・エラー
#
#   INSPECTED を必ず返すのは、「検査対象が渡っていない」と「検査して抵触が無い」を
#   呼び出し側が区別できるようにするため。0 行なら本スクリプト自身が exit 2 で止める。
#
# 実装上の制約:
#   - macOS 標準の bash 3.2 で動くこと（連想配列・`${var,,}` を使わない）
#   - 大文字小文字の吸収は `LC_ALL=C awk` の tolower() で行う。ロケール依存を
#     避けつつ、対話シェルで grep が別実装へ差し替わっている環境にも依存しない

set -euo pipefail

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

# 検出対象の closing keyword（GitHub が squash メッセージで解釈する 9 語）。
# SKILL.md / git-workflow.md の列挙と一致していることを
# tests/closing-keyword-guard/verify.sh が照合する。
KEYWORDS="close closes closed fix fixes fixed resolve resolves resolved"

usage_error() {
  echo "❌ $*" >&2
  echo "   使い方: check-closing-keywords.sh --refs-issue <N|#N|owner/repo#N> [--closes-issue <N>] [--repo <owner/repo>] < 検査対象テキスト" >&2
  echo "   検査は成立していない。抵触なしとして扱わずに停止すること。" >&2
  exit 2
}

# `123` / `#123` / `owner/repo#123` を受け取り、内部表現へ正規化する。
#   裸の番号     → `#123`
#   完全修飾参照 → `owner/repo#123`
# どの表記を一致対象にするかは awk 側で --repo と突き合わせて決める（ヘッダ参照）。
normalize_issue() {
  local raw="$1"
  case "$raw" in
    */*'#'*)
      local repo_part="${raw%%#*}"
      local number_part="${raw##*#}"
      if [[ ! "$repo_part" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
        usage_error "Issue 参照のリポジトリ部分が owner/repo 形式ではありません: $1"
      fi
      if [[ ! "$number_part" =~ ^[0-9]+$ ]]; then
        usage_error "Issue 番号が数値ではありません: $1"
      fi
      echo "${repo_part}#${number_part}" ;;
    *)
      local number="${raw#\#}"
      if [[ ! "$number" =~ ^[0-9]+$ ]]; then
        usage_error "Issue 番号が数値ではありません: $1"
      fi
      echo "#${number}" ;;
  esac
}

REFS_ISSUES=()
CLOSES_ISSUES=()
REPO=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --refs-issue)
      [[ $# -ge 2 ]] || usage_error "--refs-issue に値がありません"
      REFS_ISSUES+=("$(normalize_issue "$2")"); shift 2 ;;
    --closes-issue)
      [[ $# -ge 2 ]] || usage_error "--closes-issue に値がありません"
      CLOSES_ISSUES+=("$(normalize_issue "$2")"); shift 2 ;;
    --repo)
      [[ $# -ge 2 ]] || usage_error "--repo に値がありません"
      # 空文字を通すと awk 側の修飾子が消え、`owner/repo#N` 形式の検査が**無言で**
      # 対象外になる（守りたい再発事例そのものの形が緑になる）。省略は
      # 「裸の #N だけを見る」という正当なモードなので、空文字だけを弾く。
      [[ -n "$2" ]] || usage_error "--repo が空文字です（リポジトリ名の取得に失敗している。このまま続けると owner/repo#N 形式が無言で検査対象外になる）"
      [[ "$2" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || usage_error "--repo が owner/repo 形式ではありません: $2"
      REPO="$2"; shift 2 ;;
    --list-keywords)
      # 検出語をドキュメント側と機械照合するための口。
      # shellcheck disable=SC2086 # 語分割は意図的（1 語 1 行で出す）
      printf '%s\n' ${KEYWORDS}; exit 0 ;;
    --help|-h)
      # 行域を固定値で切ると、ヘッダを足したときにヘルプが黙って途切れる。
      # 終端は内容（set -euo pipefail の行）から導出する。
      sed -n '2,/^set -euo pipefail$/p' "$0" | sed '$d' >&2; exit 0 ;;
    *)
      usage_error "不明な引数: $1" ;;
  esac
done

# 意図の矛盾（同じ Issue を「閉じる」と「閉じない」の両方に指定）は
# どちらかが書き間違いなので、判定せずに止める。
for refs in ${REFS_ISSUES[@]+"${REFS_ISSUES[@]}"}; do
  for closes in ${CLOSES_ISSUES[@]+"${CLOSES_ISSUES[@]}"}; do
    if [[ "$refs" == "$closes" ]]; then
      usage_error "Issue ${refs} が --refs-issue と --closes-issue の両方に指定されています（意図が矛盾）"
    fi
  done
done

if [[ ${#REFS_ISSUES[@]} -eq 0 ]]; then
  # Closes 運用の PR。閉じてよい Issue しか無いので抵触という概念が無い。
  # stdin は読み切ってから抜ける（読まずに終了すると上流が SIGPIPE で落ちる）。
  # なお引数エラーで抜ける経路は stdin を読まない。呼び出し側はパイプ直結ではなく
  # ファイル・変数経由で渡すこと（SKILL.md 手順 2 がその形を定めている）。
  cat >/dev/null
  echo "ℹ️  Refs 運用の対象 Issue が指定されていないため検査対象なし（従来どおりの Closes 運用）" >&2
  exit 0
fi

# stdin が端末のままだと `cat` が入力待ちで固まる。検査が始まらないまま
# 止まって見えるより、使い方の誤りとして即座に落とす。
if [[ -t 0 ]]; then
  usage_error "検査対象テキストが stdin から渡されていません（端末が接続されています）"
fi

INPUT="$(cat)"

RESULT="$(
  printf '%s\n' "$INPUT" | LC_ALL=C awk \
    -v keywords="$KEYWORDS" \
    -v issues="${REFS_ISSUES[*]}" \
    -v repo="$REPO" '
    BEGIN {
      kw_count = split(keywords, kw, " ")
      kw_pattern = "(" kw[1]
      for (i = 2; i <= kw_count; i++) kw_pattern = kw_pattern "|" kw[i]
      kw_pattern = kw_pattern ")"

      issue_count = split(issues, issue, " ")

      # repo 名に使える記号のうち正規表現で意味を持つのは `.` だけなので、
      # そこだけブラケット式へ逃がす（引数検査で書式は確定済み）。
      repo_lower = escape_dots(tolower(repo))

      for (i = 1; i <= issue_count; i++) {
        target = tolower(issue[i])
        hash = index(target, "#")
        number[i] = substr(target, hash + 1)
        if (hash > 1) {
          target_repo = substr(target, 1, hash - 1)
          if (target_repo == tolower(repo)) {
            # 完全修飾されていても、その PR 自身のリポジトリを指しているなら
            # 裸の `#N` も同じ Issue を閉じる。修飾を必須にすると見逃す。
            qualifier[i] = "(" escape_dots(target_repo) ")?"
          } else {
            # 他リポジトリの Issue。この PR のリポジトリでの裸の `#N` は
            # 別の Issue なので一致させない（修飾子を必須にする）。
            qualifier[i] = escape_dots(target_repo)
          }
          reference[i] = issue[i]
        } else {
          # 裸の番号。`#N` と `<--repo>#N` の両方が同じ Issue を指す。
          qualifier[i] = (repo_lower == "") ? "" : "(" repo_lower ")?"
          reference[i] = "#" number[i]
        }
        pattern[i] = "(^|[^a-z0-9_])" kw_pattern "[[:space:]]*:?[[:space:]]*" \
                     qualifier[i] "#" number[i] "([^0-9]|$)"
      }
    }

    function escape_dots(text) {
      gsub(/\./, "[.]", text)
      return text
    }

    # 元テキストから Issue 参照（直後が数字でないもの）を取り除いた改題案を作る。
    # 一致箇所だけを消す実装は awk に後方参照が無いぶん複雑になるうえ、Refs 運用では
    # 件名に Issue 参照を書かないこと自体が規約なので、同じ参照はすべて落として構わない。
    # 複数の Issue を守る PR では、この改題案は**その 1 件分しか外さない**。
    # 完全修飾で守っている Issue でも、同一リポジトリなら裸の `#N` で書かれている
    # ことがある。修飾形 → 裸の順で 2 回落とす（裸指定なら 2 回目は空振りする）。
    function strip_reference(text, full_ref, number,   out) {
      out = strip_one(text, full_ref)
      return strip_one(out, "#" number)
    }

    function strip_one(text, needle,   out, pos, tail, next_char) {
      out = ""
      while ((pos = index(text, needle)) > 0) {
        tail = substr(text, pos + length(needle))
        next_char = substr(tail, 1, 1)
        if (next_char ~ /^[0-9]$/) {
          # `#3731` のような別 Issue への参照。消さずに読み進める。
          out = out substr(text, 1, pos + length(needle) - 1)
        } else {
          out = out substr(text, 1, pos - 1)
        }
        text = tail
      }
      out = out text
      gsub(/[[:space:]][[:space:]]+/, " ", out)
      sub(/^[[:space:]]+/, "", out)
      sub(/[[:space:]]+$/, "", out)
      return out
    }

    {
      line = $0
      origin = "-"
      text = line
      tab = index(line, "\t")
      if (tab > 0) {
        origin = substr(line, 1, tab - 1)
        text = substr(line, tab + 1)
      }
      # 空白しか無い行は検査面ではない。読み飛ばした行を検査済みに数えると、
      # 上流が切り詰められた入力を「検査して抵触なし」と report できてしまう。
      if (text ~ /^[[:space:]]*$/) next
      inspected++

      lower = tolower(text)
      for (i = 1; i <= issue_count; i++) {
        # 左境界: `hotfix: #12` の `fix` のような語中一致を弾く
        # 右境界: 対象が #12 のとき `#123` を巻き込まない
        if (lower ~ pattern[i]) {
          printf "CONFLICT\t%s\t%s\t%s\n", origin, reference[i], text
          printf "SUGGEST\t%s\t%s\t%s\n", origin, reference[i],
                 strip_reference(text, reference[i], number[i])
        }
      }
    }

    END { printf "INSPECTED\t%d\n", inspected + 0 }
  '
)"

INSPECTED="$(printf '%s\n' "$RESULT" | awk -F'\t' '$1 == "INSPECTED" { print $2 }')"

# 検査対象が 1 行も無いまま「抵触なし」を返すと、検査していない状態が緑として
# 報告される。上流が失敗して部分出力・空出力になった場合もここで捕まえる。
if [[ -z "$INSPECTED" || "$INSPECTED" -eq 0 ]]; then
  usage_error "検査対象の実テキストが 0 行でした（stdin が空、空白のみ、または上流で切り詰められています）"
fi

printf '%s\n' "$RESULT"

CONFLICTS="$(printf '%s\n' "$RESULT" | awk -F'\t' '$1 == "CONFLICT" { count++ } END { print count + 0 }')"

if [[ "$CONFLICTS" -eq 0 ]]; then
  echo "✅ closing keyword の抵触なし（対象 Issue: ${REFS_ISSUES[*]} / 検査 ${INSPECTED} 行）" >&2
  exit 0
fi

{
  echo "❌ closing keyword と Issue 参照の隣接一致を検出しました（検査 ${INSPECTED} 行）"
  echo "   このままマージすると、PR 本文が Refs 参照でも squash メッセージが Issue を閉じます。"
  echo "   Issue 参照を外してから再検査してください（上の SUGGEST 行が機械的な改題案）。"
} >&2

exit 1
