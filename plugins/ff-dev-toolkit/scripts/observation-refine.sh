#!/usr/bin/env bash
# ============================================================================
# observation-refine.sh — 観測台帳（OBSERVATIONS.md）の定期整理の候補算出と、適用後の照合
# ============================================================================
#
# `/retrospective` は観測を台帳へ積み、`Count` が閾値に達したエントリだけを Issue へ昇格する。
# 閾値に届かないエントリは誰も見直さないまま増え、既に対応 Issue があっても紐付かず、同じ主張が
# 別エントリへ分かれて `Count` が分散していても合流しない（Issue `#2523`）。本スクリプトは
# スキル observation-refine（dry-run → 承認 → 適用）の機械の部分を持つ。台帳は書き換えない。
#
# サブコマンド:
#   report  整理の候補と根拠を出す（dry-run）
#     observation-refine.sh report [--root DIR] [--ledger PATH] [--today YYYY-MM-DD]
#                                  [--stale-days N] [--stale-max-count N]
#                                  [--issues OWNER/REPO=FILE]... [--issues-limit N]
#                                  [--top N] [--min-link-score F] [--min-merge-score F] [--max-pairs N]
#     出力は 5 節: (1) 既存 Issue への紐付け (2) 統合 (3) stale の archive (4) Keep の定着判定
#     (5) 昇格閾値に到達済みで未リンク。末尾に `SUMMARY …` を 1 行出す。
#     メタ行を読めないエントリと、active なのに Issue 列が埋まっているエントリは、どの節にも入れず
#     名指しで別に出す（黙って落とさない）。
#     (3) と母集団は規則で決まる。(1) と (2) の「類似」は候補を絞る信号で、判定ではない
#     （同じ事象か・同じ主張かは、ホストが本文を開いて判定する）。
#   check   適用前後の台帳を照合し、整理が履歴を消していないことを確かめる
#     observation-refine.sh check --before FILE --after FILE [--ledger-rel PATH]
#     違反は `NG <ID>: <理由>` で 1 行ずつ出し、末尾に `CHECK …` を 1 行出す。適用後に昇格閾値へ
#     到達している未リンクの active は `THRESHOLD <ID> …` で出す（違反ではない）。
#
# オプション（report）:
#   --root <dir>            対象リポジトリのルート（既定: cwd のリポジトリ）
#   --ledger <path>         観測台帳（既定と探索の規則は knowledge-lookup.sh と同じ）
#   --today <YYYY-MM-DD>    基準日（既定: 実行日）。stale の経過日数はこの日から数える
#   --stale-days <N>        stale と見なす日数（既定 180。Last からこの日数を超えたもの）
#   --stale-max-count <N>   stale の対象にする Count の上限（既定 1）
#   --issues <repo>=<file>  起票先リポジトリの Issue 一覧（複数可）。1 行 = `番号<TAB>state<TAB>タイトル`。
#                           作り方はスキルの手順が正本（gh / MCP のどちらで取ってもよい）。本スクリプトは
#                           通信しない。渡さなければ (1) は母集団だけを出し、照合は `未確認` と書く。
#                           取得に失敗したリポジトリは省かず、0 行のファイルを渡す（未確認の照合先として
#                           出力に残り、SUMMARY は issues=partial になる。省くと、残りが照合できただけで
#                           issues=ok になる）
#   --issues-limit <N>      一覧を取った上限（既定 5000）。行数がこの値に達した一覧は打ち切りの
#                           可能性があるので `未確認` として扱う（「候補なし」に倒さない）
#   --top <N>               (1) で 1 エントリに出す Issue の上限（既定 3）
#   --min-link-score <F>    (1) の最小スコア（既定 0.30）
#   --min-merge-score <F>   (2) の最小スコア（既定 0.20）
#   --max-pairs <N>         (2) で出す組の上限（既定 30。件数は全数を出す）
#
# 昇格閾値は本スクリプトに書かない。`/retrospective` の SKILL.md（「累計 N 回」）から導出し、
# 導出できなければ 2 で止める（規定の複製を作らない）。
#
# 終了コード:
#   0  report: 候補を算出した（0 件を含む）/ check: 違反なし
#   1  check: 違反あり
#   2  判定不能 — 台帳が無い・曖昧・読めない・エントリ見出しを認識できない・メタ行を 1 件も読めない・
#      同じ ID の見出しが複数ある・Issue 一覧を読めない／書式が不正・昇格閾値を導出できない・
#      基準日を読めない（暦に無い日付を含む）・台帳の出力が途中で切れている
#   3  plugin root ガードの停止
#   64 引数エラー
#
# 依存: bash 3.2 以降、awk。通信しない。書き込みは一時領域だけ（read-only）。
# 日付の差は awk の中で暦日から通算日へ換算して求める — `date -d` / `date -v` は実装ごとに
# 引数が違い、実装で分岐すると環境分岐を増やすことになる（能力層の外では書かない）。
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
  observation-refine.sh report [--root DIR] [--ledger PATH] [--today YYYY-MM-DD]
                               [--stale-days N] [--stale-max-count N]
                               [--issues OWNER/REPO=FILE]... [--issues-limit N]
                               [--top N] [--min-link-score F] [--min-merge-score F] [--max-pairs N]
  observation-refine.sh check --before FILE --after FILE [--ledger-rel PATH]
USAGE
}

die_usage() { printf '%s\n' "$1" >&2; usage; exit 64; }
is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; return 0; }
is_score() { case "$1" in ''|.|*[!0-9.]*|*.*.*) return 1 ;; esac; return 0; }

SELF_DIR="$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || {
  printf '%s\n' "自分の位置を解決できません" >&2
  exit 2
}
REPORT_AWK="${SELF_DIR}/lib/observation-refine-report.awk"
CHECK_AWK="${SELF_DIR}/lib/observation-refine-check.awk"
LOOKUP="${SELF_DIR}/knowledge-lookup.sh"
BOUNDARY_LIB="${SELF_DIR}/lib/knowledge-read-boundary.sh"
RETRO_SKILL="${SELF_DIR}/../skills/retrospective/SKILL.md"

need_resource() {
  if [ -L "$1" ] || [ ! -f "$1" ] || [ ! -r "$1" ]; then
    printf '同梱 resource を読めません: %s\n' "$1" >&2
    exit 2
  fi
}

# 昇格閾値は /retrospective の SKILL.md が正本。「累計 N 回」の N がちょうど 1 種類のときだけ採る
# （0 種類は規定の欠落・改稿、2 種類以上はどれが閾値か決められない）。
derive_threshold() {
  need_resource "$RETRO_SKILL"
  LC_ALL=C awk '
    {
      s = $0
      while (match(s, /累計 [0-9]+ 回/)) {
        v = substr(s, RSTART, RLENGTH); gsub(/[^0-9]/, "", v)
        if (!(v in seen)) { seen[v] = 1; n++; out = v }
        s = substr(s, RSTART + RLENGTH)
      }
    }
    END { if (n != 1 || out + 0 < 1) exit 1; print out + 0 }
  ' "$RETRO_SKILL"
}

# 一時領域は knowledge-lookup.sh と同じ private な作業ディレクトリに置く（台帳の本文を写すため）。
make_tmp() {
  need_resource "$BOUNDARY_LIB"
  # shellcheck source=lib/knowledge-read-boundary.sh
  . "$BOUNDARY_LIB"
  if ! TMP="$(ff_knowledge_job_directory observation-refine)" || [ ! -d "${TMP}" ]; then
    printf '%s\n' "一時ディレクトリを作成できません（上の knowledge-read: 行が理由）" >&2
    exit 2
  fi
  trap 'rm -rf "${TMP}"' EXIT
}

run_report() {
  local root="" ledger="" today="" stale_days=180 stale_max=1 issues_limit=5000
  local top=3 min_link="0.30" min_merge="0.20" max_pairs=30
  local specs=() spec repo file verdict idx=0 rc=0 threshold ledger_label dump_shape
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) [ $# -ge 2 ] || die_usage "--root に値がありません"; root="$2"; shift 2 ;;
      --ledger) [ $# -ge 2 ] || die_usage "--ledger に値がありません"; ledger="$2"; shift 2 ;;
      --today) [ $# -ge 2 ] || die_usage "--today に値がありません"; today="$2"; shift 2 ;;
      --stale-days) [ $# -ge 2 ] && is_uint "$2" || die_usage "--stale-days は 0 以上の整数"; stale_days="$2"; shift 2 ;;
      --stale-max-count) [ $# -ge 2 ] && is_uint "$2" || die_usage "--stale-max-count は 0 以上の整数"; stale_max="$2"; shift 2 ;;
      --issues) [ $# -ge 2 ] || die_usage "--issues に値がありません"; specs+=("$2"); shift 2 ;;
      --issues-limit) [ $# -ge 2 ] && is_uint "$2" && [ "$2" -ge 1 ] || die_usage "--issues-limit は 1 以上の整数"; issues_limit="$2"; shift 2 ;;
      --top) [ $# -ge 2 ] && is_uint "$2" && [ "$2" -ge 1 ] || die_usage "--top は 1 以上の整数"; top="$2"; shift 2 ;;
      --min-link-score) [ $# -ge 2 ] && is_score "$2" || die_usage "--min-link-score は 0 以上の小数"; min_link="$2"; shift 2 ;;
      --min-merge-score) [ $# -ge 2 ] && is_score "$2" || die_usage "--min-merge-score は 0 以上の小数"; min_merge="$2"; shift 2 ;;
      --max-pairs) [ $# -ge 2 ] && is_uint "$2" || die_usage "--max-pairs は 0 以上の整数"; max_pairs="$2"; shift 2 ;;
      -h|--help) usage; exit 64 ;;
      *) die_usage "未知の引数: $1" ;;
    esac
  done
  if [ -z "$today" ]; then
    today="$(date +%Y-%m-%d)" || { printf '%s\n' "実行日を取得できません（--today で指定してください）" >&2; exit 2; }
  fi
  case "$today" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) printf '基準日を読めません（YYYY-MM-DD ではない）: %s\n' "$today" >&2; exit 2 ;;
  esac
  need_resource "$REPORT_AWK"
  need_resource "$LOOKUP"
  threshold="$(derive_threshold)" || {
    printf '昇格閾値を導出できません（%s に「累計 N 回」がちょうど 1 種類あること）\n' "$RETRO_SKILL" >&2
    exit 2
  }
  make_tmp

  # ── 台帳の全件（解決・読み取り境界・見出しの認識は knowledge-lookup.sh と共有する）──────
  local lookup_args=(--ledger-dump)
  [ -z "$root" ] || lookup_args+=(--root "$root")
  [ -z "$ledger" ] || lookup_args+=(--ledger "$ledger")
  bash "$LOOKUP" "${lookup_args[@]}" >"${TMP}/dump.tsv" 2>"${TMP}/dump.err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    cat "${TMP}/dump.err" >&2
    printf '台帳を読み出せません（knowledge-lookup.sh --ledger-dump が rc=%s）\n' "$rc" >&2
    exit 2
  fi
  ledger_label="$(sed -n 's/^SUMMARY ledger=\(.*\) entries=[0-9][0-9]* state=[a-z][a-z]*$/\1/p' "${TMP}/dump.tsv")"
  if [ -z "$ledger_label" ]; then
    printf '%s\n' "台帳の出力に SUMMARY 行がありません（--ledger-dump の書式変更の可能性）" >&2
    exit 2
  fi
  # SUMMARY の件数と、実際に受け取った行数を突き合わせる（途中で切れた出力を、件数の少ない
  # 台帳として読まない）
  dump_shape="$(LC_ALL=C awk '/^SUMMARY / { s = $0; sub(/^.* entries=/, "", s); sub(/ state=.*$/, "", s); declared = s; next } { rows++ } END { printf "%s %d", declared, rows }' "${TMP}/dump.tsv")" || dump_shape=""
  if [ "${dump_shape% *}" != "${dump_shape#* }" ] || [ -z "$dump_shape" ]; then
    printf '台帳の出力の行数が SUMMARY の件数と合いません（entries / 行数 = %s）\n' "${dump_shape:-取得できません}" >&2
    exit 2
  fi

  # ── Issue 一覧（渡されたファイルを検証して写す。通信しない）───────────────────
  : >"${TMP}/manifest"
  for spec in ${specs[@]+"${specs[@]}"}; do
    repo="${spec%%=*}"; file="${spec#*=}"
    if [ "$repo" = "$spec" ] || [ -z "$file" ]; then die_usage "--issues は OWNER/REPO=FILE の形: $spec"; fi
    case "$repo" in
      */*/*|/*|*/|*[!A-Za-z0-9_./-]*) die_usage "--issues のリポジトリ名を読めません: $repo" ;;
      */*) ;;
      *) die_usage "--issues のリポジトリ名を読めません: $repo" ;;
    esac
    if [ ! -f "$file" ] || [ ! -r "$file" ]; then
      printf 'Issue 一覧を読めません: %s\n' "$file" >&2
      exit 2
    fi
    idx=$((idx + 1))
    verdict="$(LC_ALL=C awk -F '\t' -v limit="$issues_limit" -v out="${TMP}/issues-${idx}.tsv" '
      { sub(/\r$/, "") }
      $0 == "" { next }
      {
        rows++
        if (NF < 3 || $1 !~ /^[0-9]+$/ || tolower($2) !~ /^(open|closed)$/) { bad = NR; exit }
        print > out
      }
      END {
        if (bad) print "bad " bad
        else if (rows + 0 == 0) print "empty"
        else if (rows >= limit) print "limit " rows
        else print "ok " rows
      }' "$file")" || { printf 'Issue 一覧を検証できません: %s\n' "$file" >&2; exit 2; }
    case "$verdict" in
      "bad "*)
        printf 'Issue 一覧の %s 行目を読めません（番号<TAB>state<TAB>タイトル の形ではない）: %s\n' "${verdict#bad }" "$file" >&2
        exit 2 ;;
      empty) printf '%s\tunverified\t%s\n' "$repo" "一覧が 0 行（取得失敗と区別できない）" >>"${TMP}/manifest" ;;
      "limit "*) printf '%s\tunverified\t%s\n' "$repo" "一覧が上限 ${issues_limit} 件に達している（打ち切りの可能性）" >>"${TMP}/manifest" ;;
      "ok "*) printf '%s\tok\t%s\n' "$repo" "${TMP}/issues-${idx}.tsv" >>"${TMP}/manifest" ;;
      *) printf 'Issue 一覧を検証できません: %s\n' "$file" >&2; exit 2 ;;
    esac
  done

  rc=0
  LC_ALL=C awk -f "$REPORT_AWK" \
    -v today="$today" -v stale_days="$stale_days" -v stale_max="$stale_max" -v threshold="$threshold" \
    -v top="$top" -v min_link="$min_link" -v min_merge="$min_merge" -v max_pairs="$max_pairs" \
    -v manifest="${TMP}/manifest" -v ledger="$ledger_label" "${TMP}/dump.tsv" || rc=$?
  case "$rc" in 0) ;; *) exit 2 ;; esac
}

run_check() {
  local before="" after="" ledger_rel="docs/08-knowledge/OBSERVATIONS.md" threshold rc=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --before) [ $# -ge 2 ] || die_usage "--before に値がありません"; before="$2"; shift 2 ;;
      --after) [ $# -ge 2 ] || die_usage "--after に値がありません"; after="$2"; shift 2 ;;
      --ledger-rel) [ $# -ge 2 ] || die_usage "--ledger-rel に値がありません"; ledger_rel="$2"; shift 2 ;;
      -h|--help) usage; exit 64 ;;
      *) die_usage "未知の引数: $1" ;;
    esac
  done
  [ -n "$before" ] && [ -n "$after" ] || die_usage "check には --before と --after が必要です"
  case "$ledger_rel" in
    ''|/*|*\\*|*[[:space:]]*) die_usage "--ledger-rel はリポジトリ相対パス（空白・バックスラッシュを含まない）: $ledger_rel" ;;
  esac
  for f in "$before" "$after"; do
    if [ ! -f "$f" ] || [ ! -r "$f" ]; then
      printf '台帳を読めません: %s\n' "$f" >&2
      exit 2
    fi
  done
  need_resource "$CHECK_AWK"
  threshold="$(derive_threshold)" || {
    printf '昇格閾値を導出できません（%s に「累計 N 回」がちょうど 1 種類あること）\n' "$RETRO_SKILL" >&2
    exit 2
  }
  make_tmp
  # awk の -v は値の中のバックスラッシュを解釈するので、利用者のパスは渡さず写しを読む
  cat -- "$before" >"${TMP}/before.md" || { printf '台帳を読めません: %s\n' "$before" >&2; exit 2; }
  cat -- "$after" >"${TMP}/after.md" || { printf '台帳を読めません: %s\n' "$after" >&2; exit 2; }
  LC_ALL=C awk -f "$CHECK_AWK" -v before="${TMP}/before.md" -v after="${TMP}/after.md" \
    -v ledger_rel="$ledger_rel" -v threshold="$threshold" || rc=$?
  case "$rc" in 0|1) exit "$rc" ;; *) exit 2 ;; esac
}

[ $# -ge 1 ] || { usage; exit 64; }
SUBCOMMAND="$1"; shift
case "$SUBCOMMAND" in
  report) run_report "$@" ;;
  check) run_check "$@" ;;
  -h|--help) usage; exit 64 ;;
  *) die_usage "未知のサブコマンド: $SUBCOMMAND" ;;
esac
