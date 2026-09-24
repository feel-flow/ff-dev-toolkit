#!/usr/bin/env bash
#
# mutation-harness.sh — 変異表を作業ツリーの写しへ 1 件ずつ当て、対象 suite の結果を表にする。
#
# 使い方:
#   mutation-harness.sh --table <変異表.tsv> --suite '<suite を実行するコマンド>'
#                       [--root <dir>] [--out <結果.md>] [--work-dir <dir>] [--keep]
#
#   --table     変異表（下記の書式）。`-` は stdin
#   --suite     写しのルートを cwd にして `bash -c` で実行するコマンド。plugin root の handoff
#               （FF_DEV_TOOLKIT_ROOT / CLAUDE_PLUGIN_ROOT / GROK_PLUGIN_ROOT）は写し側へ張り替えて渡す
#               （--root 配下を指していれば写しの同じ位置へ、外を指していれば写しの
#               `plugins/ff-dev-toolkit` へ、それも無ければ外す）。張り替えないと、写しの中の
#               root 固定ガード付きスクリプトが不一致で止まるか、元のファイルを検査して変異を見落とす
#               （例: 'bash plugins/ff-dev-toolkit/tests/guard-review-in-flight/verify.sh'）
#   --root      写しの元（既定: cwd の git toplevel）。git が見えるファイル（tracked + ignore
#               されていない untracked）を作業ツリーの**現在の内容**で写す。ignore 済み
#               （node_modules 等）は写さないので、それに依存する suite は写しでは動かない
#   --out       結果表（Markdown）の書き出し先。省略時は stdout だけ
#   --work-dir  写しを置く親ディレクトリ（既定: ${TMPDIR:-/tmp}）。その下へ一意な子ディレクトリ
#               （`harness.XXXXXX`）を作り、終了時はその子だけを消す（指定先の既存の中身には触れない）。
#               live probe を含む suite はリポジトリ外の通常ディレクトリを指定する（`/tmp` 配下では
#               codex の live probe が偽赤になる）
#   --keep      写しを消さない（赤になった変異の写しを調べるとき）
#
# 何のためにあるか:
#   変異注入の作法（1 検査 1 変異・適用の成否と検査結果を並べる・赤転しなかった変異は検査追加の
#   TODO）の**実行手段**。作法の正本は配布テンプレートの `04-quality/TESTING.md`「変異注入の
#   適用確認」「変異注入の結果の読み方と書き戻し先」で、このスクリプトは規定を持たない（規定を
#   2 本にしない）。手で「退避 → 変異 → suite → 復元」を書くと、置換元が消えた変異が無音の
#   no-op になり「緑のまま」を検出力不足と取り違える。ここでは 1 件ごとに写しを作り直し、
#   適用の前後で対象ファイルの内容ハッシュが変わったことを確かめてから suite を回すので、
#   当たらなかった変異は NOT-APPLIED として赤で止まる。レビューが「緑のまま通る回避形」を
#   報告したら、その形を同じ表へ 1 行足して再実行すれば、修正の検証と PR 本文の証拠表が
#   同時に揃う。
#
# 変異表の書式（タブ区切り 1 行 1 変異。`#` 始まりと空行は読み飛ばす）:
#   <名前> <TAB> <操作> <TAB> <対象パス（--root からの相対）> <TAB> <引数1> <TAB> <引数2> <TAB> <期待>
#   操作:
#     replace      引数1（リテラル）が**ちょうど 1 回**現れることを確かめて引数2へ置き換える
#     replace-all  引数1 が 1 回以上現れることを確かめて全部を引数2へ置き換える
#     delete-line  引数1（リテラル。バックスラッシュもそのまま）を含む行が**ちょうど 1 行**である
#                  ことを確かめて消す（他の行のバイトと末尾改行の有無は変えない）
#     append       対象ファイル（既存）の末尾へ引数1 を 1 行足す（引数2 は `-`）
#     create       対象ファイル（未存在）を引数1 の内容**そのまま**で作る（末尾改行が要るなら
#                  引数1 の末尾に `\n` を書く。引数2 は `-`）
#   期待:
#     red    suite が赤（非 0）になるべき変異（検出力の実測）
#     green  suite が緑のままであるべき入力（誤検知の確認）
#   引数中の `\t` / `\n` / `\\` はタブ / 改行 / バックスラッシュとして読む。空の引数は `-` ではなく
#   空欄（連続したタブ）で書く（replace で引数2 を空にすると「削除」になる）。
#
# 出力: Markdown の結果表（# / 変異 / 操作 / 対象 / 適用 / 期待 / rc / 判定 / suite の要約行）と、
#   最終行の要約 `mutation-harness: <n> 件 / detected <a> / green-ok <b> / SURVIVED <c> /
#   FALSE-POSITIVE <d> / NOT-APPLIED <e>`。要約行は suite の出力の最後の空でない行（160 字で切る）。
#   判定:
#     detected        期待 red で suite が非 0
#     green-ok        期待 green で suite が 0
#     SURVIVED        期待 red なのに suite が 0（その箇所を守る検査が無い = 検査追加の TODO）
#     FALSE-POSITIVE  期待 green なのに suite が非 0
#     NOT-APPLIED     置換元が見つからない・一意でない・適用前後でハッシュが変わらない等
#   変異の前に、変異なしの写しで suite を 1 回回す（対照）。対照が赤なら変異を当てずに止める
#   （赤が変異のせいか元からかを区別できないため）。
#
# 終了コード: 0 = 全件が期待どおり / 1 = SURVIVED・FALSE-POSITIVE・NOT-APPLIED が 1 件以上 /
#   2 = 対照が赤・写しを作れない・変異表が空（0 件）・書式違反 / 3 = plugin root ガードの停止 /
#   64 = 使い方の誤り。
#   変異表が 0 件のときは「全件期待どおり」へ倒さず 2 で止める（空振りを緑にしない）。
#
# 写しの境界: 変異の対象パスは、写しの中のどの要素（対象・祖先ディレクトリ）も symlink であっては
#   ならず、書き込み先の物理パス（`pwd -P`）がその変異の写しの配下であることを確かめてから書く
#   （写しは symlink を symlink のまま写すので、辿ると写しの外 = 元の作業ツリーを書き換えうる）。
#   満たさない変異は NOT-APPLIED。対照（変異なし）も専用の写しで回して捨てる（suite の副作用を
#   変異の写しへ持ち込まない）。
#
# 制約: bash 3.2 互換。外部コマンドは git（写しの対象の列挙と写しの git 化）・tar・cksum・awk・
#   mktemp。対象ファイルはテキストに限る（NUL を含むファイルは扱わない）。
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


TABLE=""
SUITE=""
ROOT=""
OUT=""
WORK=""
KEEP=0

usage() {
  sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}
die_usage() { echo "✗ mutation-harness: $1" >&2; usage >&2; exit 64; }
die() { echo "✗ mutation-harness: $1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --table) [ $# -ge 2 ] || die_usage "--table に値がありません"; TABLE="$2"; shift 2 ;;
    --suite) [ $# -ge 2 ] || die_usage "--suite に値がありません"; SUITE="$2"; shift 2 ;;
    --root) [ $# -ge 2 ] || die_usage "--root に値がありません"; ROOT="$2"; shift 2 ;;
    --out) [ $# -ge 2 ] || die_usage "--out に値がありません"; OUT="$2"; shift 2 ;;
    --work-dir) [ $# -ge 2 ] || die_usage "--work-dir に値がありません"; WORK="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) die_usage "未知の引数: $1" ;;
  esac
done
[ -n "$TABLE" ] || die_usage "--table が必要です"
[ -n "$SUITE" ] || die_usage "--suite が必要です"

if [ -z "$ROOT" ]; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "--root を省略するときは git リポジトリの中で実行してください"
fi
[ -d "$ROOT" ] || die "--root がディレクトリではありません: $ROOT"
ROOT="$(cd "$ROOT" && pwd -P)"

TABLE_TEXT=""
if [ "$TABLE" = "-" ]; then
  TABLE_TEXT="$(cat)"
else
  [ -r "$TABLE" ] || die "変異表を読めません: $TABLE"
  TABLE_TEXT="$(cat "$TABLE")"
fi
# 写しを作る前に 0 件を止める（対照の suite を無駄に回さない）。
if ! printf '%s\n' "$TABLE_TEXT" | awk '!/^[[:space:]]*$/ && !/^#/ { found = 1 } END { exit found ? 0 : 1 }'; then
  die "変異表に変異が 1 件もありません（空・コメントだけ）。0 件を「全件期待どおり」へ倒しません"
fi

# 作業領域は常に自分で作った一意な子ディレクトリ。cleanup はそこだけを消す（--work-dir の
# 既存の中身・並走する別のハーネスの領域には触れない）。
WORK_PARENT="${WORK:-${TMPDIR:-/tmp}}"
mkdir -p "$WORK_PARENT" 2>/dev/null || die "作業ディレクトリの親を作れません: $WORK_PARENT"
WORK="$(mktemp -d "${WORK_PARENT%/}/harness.XXXXXX")" || die "作業ディレクトリを作れません: $WORK_PARENT"
WORK="$(cd "$WORK" && pwd -P)" || die "作業ディレクトリを解決できません"
cleanup() {
  if [ "$KEEP" -eq 0 ]; then
    rm -rf "$WORK" 2>/dev/null
  else
    echo "ℹ️  mutation-harness: 写しを残しました: $WORK" >&2
  fi
  return 0
}
trap cleanup EXIT

unescape() { # <文字列>  \t \n \\ を展開（それ以外はそのまま）
  printf '%s' "$1" | awk 'BEGIN { RS = "\001" } {
    out = ""; s = $0; n = length(s)
    for (i = 1; i <= n; i++) {
      c = substr(s, i, 1)
      if (c == "\\" && i < n) {
        d = substr(s, i + 1, 1)
        if (d == "t") { out = out "\t"; i++; continue }
        if (d == "n") { out = out "\n"; i++; continue }
        if (d == "\\") { out = out "\\"; i++; continue }
      }
      out = out c
    }
    printf "%s", out
  }'
}

hash_of() { # <file> → 内容ハッシュ（無ければ "absent"）
  if [ -f "$1" ]; then cksum < "$1" | awk '{ print $1 "-" $2 }'; else printf 'absent'; fi
}

# 写しの元を 1 回だけ作る（git が見えるファイル・作業ツリーの現在の内容）。写しは git リポジトリに
# しておく — suite が git を読む（rev-parse / diff）ことがあるため。
PRISTINE="$WORK/pristine"
mkdir -p "$PRISTINE" || die "写しを作れません: $PRISTINE"
(
  cd "$ROOT" || exit 1
  git ls-files -z --cached --others --exclude-standard \
    | while IFS= read -r -d '' f; do if [ -f "$f" ] || [ -L "$f" ]; then printf '%s\0' "$f"; fi; done \
    | tar -c --null -T - -f - 2>/dev/null
) | (cd "$PRISTINE" && tar -x -f - 2>/dev/null) || die "写しを作れません（tar）: $ROOT → $PRISTINE"
[ -n "$(ls -A "$PRISTINE" 2>/dev/null)" ] || die "写しが空です（git が見えるファイルが 0 件）: $ROOT"
(
  # 自動 gc / maintenance を止める: commit 直後に背景で loose object を pack されると、
  # 直後の `cp -R` が消えていく object を追いかけて失敗する（実測）。
  cd "$PRISTINE" \
    && git init -q \
    && git config gc.auto 0 \
    && git config maintenance.auto false \
    && git -c user.name=mutation-harness -c user.email=mutation-harness@example.invalid -c commit.gpgsign=false \
      add -A >/dev/null 2>&1 \
    && git -c user.name=mutation-harness -c user.email=mutation-harness@example.invalid -c commit.gpgsign=false \
      commit -q -m "mutation-harness pristine" >/dev/null 2>&1
) || die "写しを git リポジトリにできません: $PRISTINE"

# 変異の対象パスが写しの境界の内側か（ヘッダ「写しの境界」）。create の親ディレクトリは作ってから
# 物理パスを確かめる。境界の外なら APPLY_WHY を入れて rc 1。
target_within_case() { # <写しのルート> <相対パス> <create なら 1>
  local dir="$1" rel="$2" create="$3" cur part rest parent phys_dir phys_parent
  cur="$dir"
  rest="$rel"
  while [ -n "$rest" ]; do
    part="${rest%%/*}"
    if [ "$part" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
    [ -n "$part" ] || continue
    cur="$cur/$part"
    if [ -L "$cur" ]; then APPLY_WHY="対象パスの要素が symlink です（${cur#"$dir"/}）"; return 1; fi
  done
  parent="$(dirname "$dir/$rel")"
  if [ "$create" = "1" ]; then
    mkdir -p "$parent" 2>/dev/null || { APPLY_WHY="親ディレクトリを作れません"; return 1; }
  fi
  phys_dir="$(cd "$dir" 2>/dev/null && pwd -P)" || phys_dir=""
  phys_parent="$(cd "$parent" 2>/dev/null && pwd -P)" || phys_parent=""
  if [ -z "$phys_dir" ] || [ -z "$phys_parent" ]; then APPLY_WHY="物理パスを解決できません"; return 1; fi
  case "$phys_parent/" in
    "$phys_dir"/*) return 0 ;;
  esac
  APPLY_WHY="書き込み先の物理パスが写しの外です（${phys_parent}）"
  return 1
}

# plugin root の handoff を写し側へ張り替えた値（ヘッダ --suite）。空 = 外す。
remap_root() { # <写しのルート> <元の値>
  local copy="$1" v="$2" phys
  phys="$(cd "$v" 2>/dev/null && pwd -P)" || phys=""
  if [ -n "$phys" ]; then
    case "$phys/" in
      "$ROOT"/*)
        printf '%s' "${copy}${phys#"$ROOT"}"
        return 0
        ;;
    esac
  fi
  [ -d "$copy/plugins/ff-dev-toolkit" ] && printf '%s' "$copy/plugins/ff-dev-toolkit"
  return 0
}

run_suite() { # <写しのルート> <ログ> → rc
  (
    cd "$1" || exit 1
    for var in FF_DEV_TOOLKIT_ROOT CLAUDE_PLUGIN_ROOT GROK_PLUGIN_ROOT; do
      eval "val=\${${var}:-}"
      [ -n "$val" ] || continue
      val="$(remap_root "$1" "$val")"
      if [ -n "$val" ]; then export "$var=$val"; else unset "$var"; fi
    done
    bash -c "$SUITE"
  ) > "$2" 2>&1
}

summary_line() { # <ログ>
  awk 'NF { last = $0 } END { print last }' "$1" 2>/dev/null | tr '|' '/' | cut -c1-160
}

# 1 件を写しへ適用する。成功で rc 0、失敗で理由を APPLY_WHY に入れて rc 1。
APPLY_WHY=""
apply_mutation() { # <写しのルート> <操作> <対象> <引数1> <引数2>
  local dir="$1" op="$2" rel="$3" a1="$4" a2="$5" f content rest count before after tmp line nl
  APPLY_WHY=""
  case "$rel" in
    '' | /* | ../* | */../* | *\\*) APPLY_WHY="対象パスが不正（空・絶対・.. を含む）"; return 1 ;;
  esac
  case "$op" in
    create) target_within_case "$dir" "$rel" 1 || return 1 ;;
    *) target_within_case "$dir" "$rel" 0 || return 1 ;;
  esac
  f="$dir/$rel"
  before="$(hash_of "$f")"
  case "$op" in
    replace | replace-all | delete-line | append)
      [ -f "$f" ] || { APPLY_WHY="対象ファイルがありません"; return 1; }
      # 末尾の改行を保つため番兵を足して読む
      content="$(cat "$f"; printf 'x')"
      content="${content%x}"
      ;;
    create)
      [ -e "$f" ] && { APPLY_WHY="create の対象が既に在ります"; return 1; }
      ;;
    *) APPLY_WHY="未知の操作: $op"; return 1 ;;
  esac
  case "$op" in
    replace | replace-all)
      [ -n "$a1" ] || { APPLY_WHY="置換元が空です"; return 1; }
      count=0
      rest="$content"
      while :; do
        case "$rest" in
          *"$a1"*) count=$((count + 1)); rest="${rest#*"$a1"}" ;;
          *) break ;;
        esac
      done
      if [ "$count" -eq 0 ]; then APPLY_WHY="置換元が見つかりません（0 回）"; return 1; fi
      if [ "$op" = "replace" ] && [ "$count" -ne 1 ]; then APPLY_WHY="置換元が一意ではありません（${count} 回。replace-all を使うか文脈を足す）"; return 1; fi
      # `${content//"$a1"/"$a2"}` は使わない: bash 3.2 は置換後文字列の引用符を残し、
      # bash 5.2 は引用しない `&` を一致文字列へ展開する。前後の切り出しで組み立てる。
      rest="$content"
      content=""
      while :; do
        case "$rest" in
          *"$a1"*) content="${content}${rest%%"$a1"*}${a2}"; rest="${rest#*"$a1"}" ;;
          *) content="${content}${rest}"; break ;;
        esac
      done
      printf '%s' "$content" > "$f" || { APPLY_WHY="書き込めません"; return 1; }
      ;;
    delete-line)
      [ -n "$a1" ] || { APPLY_WHY="消す行の目印が空です"; return 1; }
      # awk は -v の値のバックスラッシュを解釈し、全行を出し直すと末尾改行の有無も変えうるので、
      # 行を読みながら目印の行だけを落として残りをバイトのまま組み直す
      count=0
      rest=""
      while :; do
        if IFS= read -r line; then
          nl=$'\n'
        elif [ -n "$line" ]; then
          nl=""
        else
          break
        fi
        case "$line" in
          *"$a1"*) count=$((count + 1)) ;;
          *) rest="${rest}${line}${nl}" ;;
        esac
        [ -n "$nl" ] || break
      done < "$f"
      if [ "$count" != "1" ]; then APPLY_WHY="目印を含む行がちょうど 1 行ではありません（${count} 行）"; return 1; fi
      printf '%s' "$rest" > "$f" || { APPLY_WHY="書き込めません"; return 1; }
      ;;
    append)
      case "$content" in
        '' | *$'\n') printf '%s\n' "$a1" >> "$f" ;;
        *) printf '\n%s\n' "$a1" >> "$f" ;;
      esac
      ;;
    create)
      printf '%s' "$a1" > "$f" || { APPLY_WHY="作れません"; return 1; }
      ;;
  esac
  after="$(hash_of "$f")"
  if [ "$before" = "$after" ]; then
    APPLY_WHY="適用の前後で内容ハッシュが変わりません（無音の no-op）"
    return 1
  fi
  return 0
}

ROWS=""
TOTAL=0
N_DET=0
N_GOK=0
N_SURV=0
N_FP=0
N_NA=0

# 対照（変異なし）。写しの元（pristine）では回さず、専用の写しで回して捨てる — 成功しつつ
# ファイルを書き換える suite の副作用が、以後の全変異の写しへ混ざらないようにする。
BASE_LOG="$WORK/baseline.log"
BASE_RC=0
CONTROL="$WORK/control"
cp -R "$PRISTINE" "$CONTROL" || die "対照の写しを作れません: $CONTROL"
run_suite "$CONTROL" "$BASE_LOG" || BASE_RC=$?
[ "$KEEP" -eq 1 ] || rm -rf "$CONTROL"
if [ "$BASE_RC" -ne 0 ]; then
  echo "✗ mutation-harness: 対照（変異なしの写し）で suite が赤です（rc=${BASE_RC}）。変異を当てずに止めます。" >&2
  echo "  要約行: $(summary_line "$BASE_LOG")" >&2
  exit 2
fi
BASE_SUMMARY="$(summary_line "$BASE_LOG")"

LINE_NO=0
while IFS= read -r line || [ -n "$line" ]; do
  LINE_NO=$((LINE_NO + 1))
  case "$line" in
    '' | '#'*) continue ;;
  esac
  nf="$(printf '%s' "$line" | awk -F '\t' '{ print NF }')"
  [ "$nf" = "6" ] || die "変異表 ${LINE_NO} 行目: 列が 6 個ではありません（${nf} 個。区切りはタブ）"
  name="$(printf '%s' "$line" | cut -f1)"
  op="$(printf '%s' "$line" | cut -f2)"
  rel="$(printf '%s' "$line" | cut -f3)"
  # 末尾の改行（`\n`）をコマンド置換に落とさせないよう番兵を付けて受ける
  a1="$(unescape "$(printf '%s' "$line" | cut -f4)"; printf 'x')"
  a1="${a1%x}"
  a2="$(unescape "$(printf '%s' "$line" | cut -f5)"; printf 'x')"
  a2="${a2%x}"
  expect="$(printf '%s' "$line" | cut -f6)"
  case "$expect" in
    red | green) : ;;
    *) die "変異表 ${LINE_NO} 行目: 期待は red か green です（${expect}）" ;;
  esac
  TOTAL=$((TOTAL + 1))
  case_dir="$WORK/case-$TOTAL"
  rm -rf "$case_dir"
  cp -R "$PRISTINE" "$case_dir" || die "写しを作り直せません: $case_dir"
  applied="OK"
  rc="-"
  verdict=""
  summary=""
  if apply_mutation "$case_dir" "$op" "$rel" "$a1" "$a2"; then
    rc=0
    run_suite "$case_dir" "$case_dir.log" || rc=$?
    summary="$(summary_line "$case_dir.log")"
    if [ "$expect" = "red" ]; then
      if [ "$rc" -ne 0 ]; then verdict="detected"; N_DET=$((N_DET + 1)); else verdict="SURVIVED"; N_SURV=$((N_SURV + 1)); fi
    else
      if [ "$rc" -eq 0 ]; then verdict="green-ok"; N_GOK=$((N_GOK + 1)); else verdict="FALSE-POSITIVE"; N_FP=$((N_FP + 1)); fi
    fi
  else
    applied="NG（${APPLY_WHY}）"
    verdict="NOT-APPLIED"
    N_NA=$((N_NA + 1))
  fi
  [ "$KEEP" -eq 1 ] || rm -rf "$case_dir" "$case_dir.log"
  ROWS="${ROWS}| ${TOTAL} | ${name//|//} | ${op} | \`${rel}\` | ${applied//|//} | ${expect} | ${rc} | **${verdict}** | ${summary} |
"
  echo "  [${TOTAL}] ${name}: ${verdict} (rc=${rc})" >&2
done <<EOF
$TABLE_TEXT
EOF

[ "$TOTAL" -gt 0 ] || die "変異表に変異が 1 件もありません（空・コメントだけ）。0 件を「全件期待どおり」へ倒しません"

SUMMARY="mutation-harness: ${TOTAL} 件 / detected ${N_DET} / green-ok ${N_GOK} / SURVIVED ${N_SURV} / FALSE-POSITIVE ${N_FP} / NOT-APPLIED ${N_NA}"
REPORT="| # | 変異 | 操作 | 対象 | 適用 | 期待 | rc | 判定 | suite の要約行 |
|---|---|---|---|---|---|---|---|---|
${ROWS}
対照（変異なし）: rc=0 / ${BASE_SUMMARY}

${SUMMARY}"
printf '%s\n' "$REPORT"
if [ -n "$OUT" ]; then
  printf '%s\n' "$REPORT" > "$OUT" || die "結果表を書き出せません: $OUT"
fi

if [ "$N_SURV" -gt 0 ] || [ "$N_FP" -gt 0 ] || [ "$N_NA" -gt 0 ]; then
  exit 1
fi
exit 0
