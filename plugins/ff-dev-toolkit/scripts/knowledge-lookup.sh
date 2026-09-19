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
#                       両 store のエントリ本文（見出し・メタ行・本文・観測メモ）に、いずれかの
#                       キーワードが大文字小文字を無視して含まれるエントリを返す（OR）。
#                       `--all` で全キーワードを含むエントリだけに絞る（AND）。
#   promoted 突き合わせ knowledge-lookup.sh --promoted-open [オプション]
#                       台帳の `Status | promoted` エントリのうち、リンク先 Issue が open のものを
#                       列挙する（`/retrospective` 観察チェックリスト第 0 項の入力）。state を
#                       確認できなかった参照は隠さず `未確認` として列挙する（fail-closed）。
#
# オプション:
#   --root <dir>        対象リポジトリのルート（既定: cwd から git rev-parse --show-toplevel、無ければ cwd）
#   --playbook <path>   ACE Playbook の索引ファイル（既定: <root>/docs/08-knowledge/PLAYBOOK.md。
#                       無ければ <root> 配下の PLAYBOOK.md を探索し、候補が 1 件だけならそれを採る）
#   --ledger <path>     観測台帳（既定: <root>/docs/08-knowledge/OBSERVATIONS.md。探索の規則は同上）
#   --all               キーワードを AND で照合する（既定は OR）
#   --include-archived  ACE の playbook/archive/ 配下と、台帳の `archived` エントリも返す
#   --offline           gh を使わない（promoted の Issue state は全件 `未確認` になる）
#   --format text|tsv   出力形式（既定 text。tsv は 1 行 1 エントリの機械可読）
#
# 出力（text）: store ごとに状態のグループで並べる。見出しは `== <store> ==`、グループは
#   `-- <状態ラベル> --`、エントリは `<ID>  <title>` に続けてメタ 1 行。末尾に記録用の 1 行
#   `RECORD ace=<ID,... | 0 件 | Playbook なし | 読み取り失敗（理由）> obs=<同>` と
#   `SUMMARY ace=<n> obs=<n> ...` を出す。RECORD 行は git-workflow「着手前の Playbook 参照」の
#   記録の契約（ヒット ID / 0 件 / 不在 / 読み取り失敗 の 4 種）にそのまま転記できる。
# 出力（tsv）: `store<TAB>id<TAB>status<TAB>meta<TAB>title<TAB>location`（6 列。promoted の Issue state は
#   meta 列の `Issue=owner/repo#N(open)` に含める。独立列にしない）
#
# 状態ラベル（台帳）: active=未対策（蓄積中） / promoted=対策 Issue あり（open / closed / 未確認）/
#   mitigated=対策済み（所在は Issue 列） / archived=休眠。
# 状態ラベル（ACE）: active / deprecated / archived（archive 配下。--include-archived 時のみ）。
#
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
                      [--include-archived] [--offline] [--format text|tsv] <キーワード>...
  knowledge-lookup.sh --promoted-open [--root DIR] [--ledger PATH] [--offline] [--format text|tsv]
USAGE
}

ROOT=""
PLAYBOOK=""
LEDGER=""
MATCH_ALL=0
INCLUDE_ARCHIVED=0
OFFLINE=0
FORMAT="text"
MODE="search"
KEYWORDS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || { usage; exit 1; }; ROOT="$2"; shift 2 ;;
    --playbook) [ $# -ge 2 ] || { usage; exit 1; }; PLAYBOOK="$2"; shift 2 ;;
    --ledger) [ $# -ge 2 ] || { usage; exit 1; }; LEDGER="$2"; shift 2 ;;
    --all) MATCH_ALL=1; shift ;;
    --include-archived) INCLUDE_ARCHIVED=1; shift ;;
    --offline) OFFLINE=1; shift ;;
    --format) [ $# -ge 2 ] || { usage; exit 1; }; FORMAT="$2"; shift 2 ;;
    --promoted-open) MODE="promoted-open"; shift ;;
    -h|--help) usage; exit 1 ;;
    --) shift; while [ $# -gt 0 ]; do KEYWORDS+=("$1"); shift; done ;;
    -*) printf '未知のオプション: %s\n' "$1" >&2; usage; exit 1 ;;
    *) KEYWORDS+=("$1"); shift ;;
  esac
done

case "${FORMAT}" in text|tsv) ;; *) printf -- '--format は text か tsv: %s\n' "${FORMAT}" >&2; exit 1 ;; esac
if [ "${MODE}" = "search" ] && [ "${#KEYWORDS[@]}" -eq 0 ]; then
  printf '%s\n' "キーワードが 1 つも指定されていません（--promoted-open 以外はキーワードが必須）" >&2
  usage
  exit 1
fi
if [ "${MODE}" = "promoted-open" ] && [ "${#KEYWORDS[@]}" -gt 0 ]; then
  printf '%s\n' "--promoted-open はキーワードを取りません" >&2
  exit 1
fi

# ── root の解決 ──────────────────────────────────────────────────────────────
if [ -z "${ROOT}" ]; then
  if ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then :; else ROOT="$(pwd)"; fi
fi
if [ ! -d "${ROOT}" ]; then
  printf 'root が directory ではありません: %s\n' "${ROOT}" >&2
  exit 2
fi
ROOT="$(CDPATH= cd -P -- "${ROOT}" && pwd)"

# ── 一時領域（read-only 契約: ここ以外へ書かない） ──────────────────────────
if ! TMP="$(mktemp -d "${TMPDIR:-/tmp}/knowledge-lookup.XXXXXX" 2>&1)" || [ ! -d "${TMP}" ]; then
  printf '一時ディレクトリを作成できません: %s\n' "${TMP}" >&2
  exit 2
fi
trap 'rm -rf "${TMP}"' EXIT

# ── store の実配置を確定する ─────────────────────────────────────────────────
# 既定パスの不在だけを根拠に「未導入」と結論しない（/retrospective 起票前の既存確認 手順 2 と
# 同じ規則）。root 配下で同名ファイルを探し、候補が 1 件ならそれを採る。複数なら曖昧として
# 採らず、候補を報告する（推測で 1 つを選ばない）。docs-template（配布テンプレート）・oss
# （同期ミラー）・node_modules・.git は候補から外す。
# 戻り値: 0 = 確定（stdout にパス）/ 1 = 不在 / 3 = 曖昧（stderr に候補）
resolve_store() { # <既定の相対パス> <ファイル名> <明示パス>
  local default_rel="$1" fname="$2" explicit="$3" cands="" n=0
  if [ -n "${explicit}" ]; then
    printf '%s\n' "${explicit}"
    return 0
  fi
  if [ -e "${ROOT}/${default_rel}" ]; then
    printf '%s\n' "${ROOT}/${default_rel}"
    return 0
  fi
  cands="$(find "${ROOT}" \( -path '*/node_modules' -o -path '*/.git' -o -path '*/docs-template' -o -path "${ROOT}/oss" \) -prune -o -type f -name "${fname}" -print 2>/dev/null | LC_ALL=C sort)" || cands=""
  if [ -z "${cands}" ]; then
    return 1
  fi
  n="$(printf '%s\n' "${cands}" | awk 'END { print NR }')"
  if [ "${n}" -eq 1 ]; then
    printf '%s\n' "${cands}"
    return 0
  fi
  printf '%s の候補が %s 件あり確定できません（--playbook / --ledger で指定してください）:\n' "${fname}" "${n}" >&2
  printf '%s\n' "${cands}" | sed 's/^/    /' >&2
  return 3
}

# 各 store の状態: ok / absent / ambiguous / unreadable / noentry
ACE_STATE="absent"; ACE_INDEX=""
OBS_STATE="absent"; OBS_FILE=""
if [ "${MODE}" = "search" ]; then
  if ACE_INDEX="$(resolve_store "docs/08-knowledge/PLAYBOOK.md" "PLAYBOOK.md" "${PLAYBOOK}")"; then
    ACE_STATE="ok"
  else
    case $? in 3) ACE_STATE="ambiguous" ;; *) ACE_STATE="absent" ;; esac
  fi
fi
if OBS_FILE="$(resolve_store "docs/08-knowledge/OBSERVATIONS.md" "OBSERVATIONS.md" "${LEDGER}")"; then
  OBS_STATE="ok"
else
  case $? in 3) OBS_STATE="ambiguous" ;; *) OBS_STATE="absent" ;; esac
fi
# 明示指定・既定パスが存在しても読めなければ「読み取り失敗」（未導入へ吸収しない）
if [ "${ACE_STATE}" = "ok" ] && { [ ! -f "${ACE_INDEX}" ] || [ ! -r "${ACE_INDEX}" ]; }; then ACE_STATE="unreadable"; fi
if [ "${OBS_STATE}" = "ok" ] && { [ ! -f "${OBS_FILE}" ] || [ ! -r "${OBS_FILE}" ]; }; then OBS_STATE="unreadable"; fi

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
  awk -v prefix="${prefix}" '
    function flush() {
      if (id != "") { gsub(/\n/, "\036", block); printf "%s\037%s\037%s\037%s\n", id, title, FILENAME_SAVED, block }
      id = ""; title = ""; block = ""
    }
    FNR == 1 { flush(); FILENAME_SAVED = FILENAME; infence = 0 }
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
  ' "$@"
}

# ── 空 store と書式破損の切り分け ───────────────────────────────────────────
# エントリを 1 件も抽出できなかった store について、「テンプレート直後で空」（正常）と
# 「見出し書式が変わって認識できない」（読み取り失敗）を分ける。フェンス外に `## エントリ一覧`
# 見出しがあり、その後にフェンス外の `### ` 見出しが走査対象のどのファイルにも無ければ空。
# フェンス内の記入例は数えない（テンプレートは記入例をフェンスで持つ）。分割配置の category ファイルは
# 自分の `## エントリ一覧` を持つので、索引・本体とも同じ節スコープで数える。
# 戻り値: 0 = 空（正常）/ 1 = 書式破損の疑い
store_is_empty() { # <索引ファイル> <走査対象ファイル...>
  local index="$1"; shift
  awk '/^[[:space:]]*(```|~~~)/ { infence = !infence; next } infence { next } /^## エントリ一覧/ { seen = 1 } END { exit seen ? 0 : 1 }' "${index}" || return 1
  local f
  for f in "$@"; do
    # 見出しを数えるのは `## エントリ一覧` 節の内側だけ（次の `## ` 見出し — Changelog 等 — で節を閉じる。
    # テンプレートの Changelog は `### [版]` 見出しを持つので、節を閉じないと空を書式破損と誤判定する）
    if awk '/^[[:space:]]*(```|~~~)/ { infence = !infence; next } infence { next } /^## / { seen = ($0 ~ /^## エントリ一覧/) } seen && /^### / { found = 1 } END { exit found ? 0 : 1 }' "${f}"; then
      return 1
    fi
  done
  return 0
}

# ── ACE Playbook の走査対象 ─────────────────────────────────────────────────
# 索引ファイル自身（単一ファイル配置ではエントリが索引に同居する）+ 同階層 playbook/*.md。
# archive/ は --include-archived のときだけ加える。
ACE_FILES="${TMP}/ace-files"; : >"${ACE_FILES}"
ACE_ENTRIES="${TMP}/ace-entries"; : >"${ACE_ENTRIES}"
ACE_ARCHIVE_ENTRIES="${TMP}/ace-archive-entries"; : >"${ACE_ARCHIVE_ENTRIES}"
if [ "${ACE_STATE}" = "ok" ]; then
  ace_dir="${ACE_INDEX%/*}"
  printf '%s\n' "${ACE_INDEX}" >>"${ACE_FILES}"
  if [ -d "${ace_dir}/playbook" ]; then
    find "${ace_dir}/playbook" -maxdepth 1 -type f -name '*.md' 2>/dev/null | LC_ALL=C sort >>"${ACE_FILES}" || true
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
    extract_entries ACE "${files[@]}" >"${ACE_ENTRIES}"
    if [ ! -s "${ACE_ENTRIES}" ]; then
      if store_is_empty "${ACE_INDEX}" "${files[@]}"; then ACE_STATE="empty"; else ACE_STATE="noentry"; fi
    fi
    if [ "${INCLUDE_ARCHIVED}" -eq 1 ] && [ -d "${ace_dir}/playbook/archive" ]; then
      arch=()
      while IFS= read -r f; do [ -n "${f}" ] && arch+=("${f}"); done < <(find "${ace_dir}/playbook/archive" -maxdepth 1 -type f -name '*.md' 2>/dev/null | LC_ALL=C sort)
      if [ "${#arch[@]}" -gt 0 ]; then
        extract_entries ACE "${arch[@]}" >"${ACE_ARCHIVE_ENTRIES}"
      fi
    fi
  fi
fi

# ── 観測台帳の走査 ───────────────────────────────────────────────────────────
OBS_ENTRIES="${TMP}/obs-entries"; : >"${OBS_ENTRIES}"
if [ "${OBS_STATE}" = "ok" ]; then
  extract_entries OBS "${OBS_FILE}" >"${OBS_ENTRIES}"
  if [ ! -s "${OBS_ENTRIES}" ]; then
    # 見出しを 1 件も認識できない台帳は「0 件ヒット」ではなく読み取り失敗（書式変更を空振りで
    # 緑にしない）。ただしテンプレート直後の空台帳（エントリ一覧が空）は正常（判定は store_is_empty）。
    if store_is_empty "${OBS_FILE}" "${OBS_FILE}"; then
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
if [ "${MODE}" = "promoted-open" ]; then
  case "${OBS_STATE}" in
    ok|empty) ;;
    absent) printf '観測台帳がありません（root=%s）。--promoted-open は台帳が必要です\n' "${ROOT}" >&2; exit 2 ;;
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
# ブロック（\036 区切り）から `| <key> | <value>` の値を返す。無ければ空。
meta_of() { # <block> <key>
  printf '%s' "$1" | tr '\036' '\n' | awk -v key="$2" -F '|' '
    {
      for (i = 2; i < NF; i++) {
        k = $i; gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
        if (k == key) { v = $(i + 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); print v; exit }
      }
    }'
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
STATE_CACHE="${TMP}/issue-state"; : >"${STATE_CACHE}"   # 行: owner/repo#N<TAB>open|closed|未確認
REPO_STATUS="${TMP}/repo-status"; : >"${REPO_STATUS}"   # 行: owner/repo<TAB>ok|fail
OPEN_LIMIT=1000
fetch_open_set() { # <owner/repo> → 一時ファイルへ open 番号を書き、ok/fail を記録
  local repo="$1" out="" count=0
  out="${TMP}/open-$(printf '%s' "${repo}" | tr '/' '_')"
  if [ "${OFFLINE}" -eq 1 ] || ! command -v gh >/dev/null 2>&1; then
    printf '%s\tfail\n' "${repo}" >>"${REPO_STATUS}"
    return 0
  fi
  # stdin を閉じる: gh は対話入力を待ちうるため、呼び出し元の read ループの入力を渡さない
  # （ループ側も fd 3 で読むので二重の防御。片方だけでも欠けはしないが、両方外さない）。
  if ! gh issue list --repo "${repo}" --state open --limit "${OPEN_LIMIT}" --json number --jq '.[].number' >"${out}" 2>"${out}.err" </dev/null; then
    printf '%s\tfail\n' "${repo}" >>"${REPO_STATUS}"
    printf 'gh issue list --repo %s に失敗しました（該当参照は 未確認 として扱います）: %s\n' "${repo}" "$(head -n 1 "${out}.err" 2>/dev/null)" >&2
    return 0
  fi
  count="$(awk 'END { print NR }' "${out}")"
  if [ "${count}" -ge "${OPEN_LIMIT}" ]; then
    printf '%s\tfail\n' "${repo}" >>"${REPO_STATUS}"
    printf 'gh issue list --repo %s の open 一覧が上限 %s 件に達しました（打ち切りの可能性があるため 未確認 として扱います）\n' "${repo}" "${OPEN_LIMIT}" >&2
    return 0
  fi
  printf '%s\tok\n' "${repo}" >>"${REPO_STATUS}"
}
issue_state() { # <owner/repo#N> → open|closed|未確認
  local repo="${1%#*}" num="${1##*#}" status="" out=""
  status="$(awk -F '\t' -v r="${repo}" '$1 == r { print $2; exit }' "${REPO_STATUS}")"
  if [ -z "${status}" ]; then
    fetch_open_set "${repo}"
    status="$(awk -F '\t' -v r="${repo}" '$1 == r { print $2; exit }' "${REPO_STATUS}")"
  fi
  if [ "${status}" != "ok" ]; then printf '未確認\n'; return 0; fi
  out="${TMP}/open-$(printf '%s' "${repo}" | tr '/' '_')"
  if awk -v n="${num}" '$1 == n { found = 1 } END { exit found ? 0 : 1 }' "${out}"; then
    printf 'open\n'
  else
    printf 'closed\n'
  fi
}
# Issue 列（` / ` 区切り）を要素ごとに `ref(state)` へ展開する。owner/repo#N 形だけ state を引く。
# `skill:` / `doc:` / `なし` はそのまま。`#N` だけの旧形式（リポジトリ修飾なし）は解決せず `未確認`。
annotate_refs() { # <Issue 列の値> → "a(open) / b(closed) / skill:x"
  local col="$1" out="" item="" st=""
  [ -n "${col}" ] || { printf '%s' ""; return 0; }
  while IFS= read -r item; do
    item="$(printf '%s' "${item}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "${item}" ] || continue
    case "${item}" in
      */*#[0-9]*)
        st="$(issue_state "${item}")"
        item="${item}(${st})" ;;
      \#[0-9]*) item="${item}(未確認: リポジトリ修飾なし)" ;;
    esac
    if [ -z "${out}" ]; then out="${item}"; else out="${out} / ${item}"; fi
  done < <(printf '%s\n' "${col}" | awk 'BEGIN { RS = " / " } { gsub(/\n/, ""); if ($0 != "") print }')
  printf '%s' "${out}"
}

# ── 出力 ──────────────────────────────────────────────────────────────────────
# 状態ラベル
obs_status_label() {
  case "$1" in
    active) printf '%s' "未対策（active。蓄積中の落とし穴 — 回避策はエントリ本文の → 以降）" ;;
    promoted) printf '%s' "対策 Issue あり（promoted。Issue 列の state を見る: open = 対応中 / closed = 対策済みまたは再発）" ;;
    mitigated) printf '%s' "対策済み（mitigated。対策の所在は Issue 列 — 未対策として扱わない）" ;;
    archived) printf '%s' "休眠（archived。180 日以上再発なし）" ;;
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

emit_ace() { # <entries file> <forced status or ""> → stdout 行を状態別に並べる。副作用: ACE_IDS へ ID を追記
  local file="$1" forced="$2" st="" cat="" helpful="" loc="" anchor="" rel="" id title src block
  local line=""
  [ -s "${file}" ] || return 0
  while IFS=$'\037' read -r id title src block <&3; do
    if [ -n "${forced}" ]; then st="${forced}"; else st="$(meta_of "${block}" Status)"; [ -n "${st}" ] || st="unknown"; fi
    cat="$(meta_of "${block}" Category)"
    helpful="$(meta_of "${block}" Helpful)"
    anchor="$(printf '%s' "${id}" | tr 'A-Z' 'a-z')"
    case "${src}" in "${ROOT}"/*) rel="${src#"${ROOT}"/}" ;; *) rel="${src}" ;; esac
    loc="${rel}#${anchor}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${st}" "${id}" "Category=${cat:-?} Helpful=${helpful:-?}" "${title}" "${loc}" "ace" >>"${TMP}/rows"
    printf '%s\n' "${id}" >>"${TMP}/ace-ids"
  done 3<"${file}"
}
emit_obs() { # <entries file> → 行を追加。副作用: OBS_IDS
  local file="$1" st kind count last issue refs id title src block rel
  [ -s "${file}" ] || return 0
  while IFS=$'\037' read -r id title src block <&3; do
    st="$(meta_of "${block}" Status)"; [ -n "${st}" ] || st="unknown"
    if [ "${INCLUDE_ARCHIVED}" -eq 0 ] && [ "${st}" = "archived" ] && [ "${MODE}" = "search" ]; then continue; fi
    kind="$(meta_of "${block}" Kind)"
    count="$(meta_of "${block}" Count)"
    last="$(meta_of "${block}" Last)"
    issue="$(meta_of "${block}" Issue)"
    refs=""
    case "${st}" in
      promoted|mitigated) refs="$(annotate_refs "${issue}")" ;;
      *) refs="${issue}" ;;
    esac
    case "${src}" in "${ROOT}"/*) rel="${src#"${ROOT}"/}" ;; *) rel="${src}" ;; esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${st}" "${id}" "Kind=${kind:-?} Count=${count:-?} Last=${last:-?} Issue=${refs:-なし}" "${title}" "${rel}#$(printf '%s' "${id}" | tr 'A-Z' 'a-z')" "obs" >>"${TMP}/rows"
    printf '%s\n' "${id}" >>"${TMP}/obs-ids"
  done 3<"${file}"
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

if [ "${MODE}" = "promoted-open" ]; then
  # promoted の全件を state 付きで並べ、open または 未確認 を含むものだけ出す。
  emit_obs "${OBS_ENTRIES}"
  awk -F '\t' 'BEGIN { OFS = "\t" } $6 == "obs" && $1 == "promoted" { print }' "${TMP}/rows" >"${TMP}/promoted"
  awk -F '\t' 'index($3, "(open)") > 0 || index($3, "(未確認") > 0 { print }' "${TMP}/promoted" >"${TMP}/promoted-open"
  total="$(awk 'END { print NR }' "${TMP}/promoted")"
  hit="$(awk 'END { print NR }' "${TMP}/promoted-open")"
  unresolved="$(awk -F '\t' 'index($3, "(未確認") > 0 { c++ } END { print c + 0 }' "${TMP}/promoted")"
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

# ── キーワード検索の出力 ──────────────────────────────────────────────────────
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

ace_n="$(awk 'END { print NR }' "${TMP}/ace-ids")"
obs_n="$(awk 'END { print NR }' "${TMP}/obs-ids")"
kw_desc="$(paste -sd, "${KW_FILE}")"

if [ "${FORMAT}" = "text" ]; then
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
  printf '\n'
else
  print_group ace active x; print_group ace deprecated x; print_group ace archived x; print_group ace unknown x
  print_group obs active x; print_group obs promoted x; print_group obs mitigated x; print_group obs archived x; print_group obs unknown x
fi

printf 'RECORD ace=%s obs=%s\n' "$(record_word "${ACE_STATE}" "${TMP}/ace-ids" "Playbook なし")" "$(record_word "${OBS_STATE}" "${TMP}/obs-ids" "台帳なし")"
printf 'SUMMARY ace=%s obs=%s keywords=%s match=%s include_archived=%s offline=%s ace_state=%s obs_state=%s\n' \
  "${ace_n}" "${obs_n}" "${#KEYWORDS[@]}" "$( [ "${MATCH_ALL}" -eq 1 ] && printf all || printf any )" "${INCLUDE_ARCHIVED}" "${OFFLINE}" "${ACE_STATE}" "${OBS_STATE}"
exit 0
