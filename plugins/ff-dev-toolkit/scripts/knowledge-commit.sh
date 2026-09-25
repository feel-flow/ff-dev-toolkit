#!/usr/bin/env bash
#
# knowledge コミットの共通書き込み口（/ace-curate の Playbook 追記と /retrospective の
# 観測台帳追記が使う）。同じセッションで両方が書いた回は 1 つのコミットへ畳み、片方だけの
# 回は従来と同じ件名の単独コミットを作る。
#
# 使い方:
#   knowledge-commit.sh add --source ace|obs --id <ID>（繰り返し可） --summary <要約> [--category <c>] [--type <commit type>] -- <path>...
#   knowledge-commit.sh commit [--type <commit type>] [--force]
#   knowledge-commit.sh status
#   knowledge-commit.sh discard
#   knowledge-commit.sh freshness
#
#   add     書いたファイルを stage し、エントリ（ID・要約・カテゴリ・パス）を保留記録へ足す。
#           コミットはしない。同じ source と ID の再 add は記録を増やさない（冪等）。default branch
#           （または detached HEAD）上では先頭で origin/<default> を fetch し、ローカルが遅れていれば
#           stage せずに復帰手段つきで止まる（fetch できなければ判定不能として止まる）。
#   commit  保留記録を 1 コミットへまとめる（`--force` で上の鮮度検査を省く）。件名はエントリ 1 件なら
#           `<type>: <ID> <要約>`（従来形）、2 件以上なら `<type>: <ID> / <ID> …` で、
#           要約は本文へ 1 行ずつ置く。カテゴリは本文の `Categories:` 行へ置く（件名には並べない）。
#           commit は保留記録のパスへ固定する（`git commit -- <path>…`。索引に載った無関係な
#           変更を巻き込まない）。push はしない — push と保護ブランチの扱いは呼び出し側の手順が持つ。
#           保留記録が無ければ何もせず `KNOWLEDGE_COMMIT=none` を出して 0 で終わる。
#   status  保留記録を表示する（`KNOWLEDGE_PENDING=<件数>`・記録したブランチと基点・各エントリ）。
#   discard 保留記録を捨てる（stage 済みの変更は残すので、要らなければ `git restore --staged` で外す）。
#   freshness add の先頭と同じ default branch の鮮度検査だけを行う（`KNOWLEDGE_FRESHNESS=ok`。add の前に
#           別のファイルを stage する呼び出し側が、副作用より前に確かめる）。
#
# 保留記録は最初の add のときのブランチ・HEAD（基点）・時刻を持つ。commit はブランチが違う・基点が
# 今の HEAD の祖先でない・12 時間を超えた保留を拒否する（中断した別セッションの古い追記を今回の
# 追記と 1 コミットへ誤って畳まない）。`add` も既存の保留が同じ条件で古ければ足さずに止まる（古い
# 保留へ今回の追記を混ぜない）。`status` で確かめ、今回のものなら `commit --force`、古いものなら
# `discard` する。セッションを識別する token は持たない — ブランチ・基点・時刻の 3 点で中断した別
# セッションの保留を区別でき、token はホストごとに受け渡す経路が無いため。
#
# 内容の固定: `add` は stage した時点の各パスの blob hash を記録し、`commit` は作業ツリーの内容が
# 記録と一致するときだけ commit する（`git commit -- <path>` は作業ツリーの内容を commit するので、
# `add` の後に同じファイルへ入った別の編集を吸い込まない）。変わっていれば `add` し直す。
# commit type: `add --type` で記録した type を `commit` が引き継ぐ（`/ace-curate` が commitlint に
# 合わせて決めた type を、合流先の `/retrospective` が既定の knowledge で上書きしない）。
# `commit --type` の明示が最優先。
#
# 保留記録は作業ツリーの git ディレクトリ配下（`ff-knowledge-pending`）に置く。作業ツリーの
# 内容ではないのでコミットにも公開にも出ない。worktree ごとに別の記録になる。
#
# commit の直前に、実効の git identity が検査用の合成 identity（user.name=fixture /
# user.email=*@example.invalid）でないことを確かめる（lib/commit-identity-functions.sh）。
# Claude Code の PreToolUse ガードは script の内側の commit と他ホストの経路には届かないため。
#
# 出力（stdout、`KEY=値` は行頭一致）:
#   add:    KNOWLEDGE_PENDING=<件数>
#   commit: KNOWLEDGE_COMMIT=<sha>|none / KNOWLEDGE_SUBJECT=<件名> / KNOWLEDGE_ENTRIES=<件数>
#   status: KNOWLEDGE_PENDING=<件数> / KNOWLEDGE_PENDING_BRANCH= / KNOWLEDGE_PENDING_BASE= と `  <source> <ID> <要約>` 行
#   discard: KNOWLEDGE_DISCARDED=<件数>
#
# 終了コード:
#   0  成功（保留記録が無い commit を含む）
#   1  止めるべき状態（合成 identity・commit の失敗・保留記録の破損・default branch が origin より遅れて
#      いる add）。保留記録は残す
#   2  使い方の誤り・環境不備（git 管理外・パスがリポジトリ外 / 不在・lib 不在・origin/<default> を
#      fetch / 解決できない add）
#
# 実装上の制約: macOS 標準の bash 3.2 で動くこと（連想配列・readarray を使わない）。

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

usage() {
  cat >&2 <<'USAGE'
Usage: knowledge-commit.sh add --source ace|obs --id <ID> --summary <summary> [--category <c>] [--type <commit type>] -- <path>...
       knowledge-commit.sh status
       knowledge-commit.sh commit [--type <commit type>] [--force]
       knowledge-commit.sh discard
       knowledge-commit.sh freshness
USAGE
  exit 2
}

die_env() { echo "✗ $1" >&2; exit 2; }
die_stop() { echo "✗ $1" >&2; exit 1; }

self_dir="$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || die_env "script の配置を解決できません"
identity_lib="$self_dir/lib/commit-identity-functions.sh"
[[ -f "$identity_lib" && ! -L "$identity_lib" ]] || die_env "identity 判定 lib が無いか symlink です: $identity_lib"
# shellcheck source=lib/commit-identity-functions.sh
. "$identity_lib"

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || die_env "git リポジトリの中で実行してください（cwd: ${PWD}）"
repo_root="$(CDPATH='' cd -P -- "$repo_root" && pwd -P)" || die_env "リポジトリルートを解決できません"
git_dir="$(git rev-parse --absolute-git-dir 2>/dev/null)" || die_env "git ディレクトリを解決できません"
pending="$git_dir/ff-knowledge-pending"

# 保留記録の 1 行は `M<TAB>branch<TAB>base HEAD<TAB>epoch`（先頭 1 行）・`E<TAB>source<TAB>id<TAB>summary<TAB>categories`・
# `P<TAB>path<TAB>blob hash`・`T<TAB>commit type`。
# 値にタブ・改行を許さないので、分割はタブだけで決まる。
has_bad_chars() { case "$1" in *$'\t'*|*$'\n'*|*$'\r'*) return 0 ;; esac; return 1; }
entry_count() { awk -F '\t' '$1=="E" {n++} END {print n+0}' "$pending"; }
meta_field() { awk -F '\t' -v i="$1" '$1=="M" { print $i; exit }' "$pending"; }
current_branch() { git -C "$repo_root" symbolic-ref -q --short HEAD || echo "(detached)"; }
PENDING_MAX_AGE=43200
# 保留の鮮度（別ブランチ・別の基点・古い保留）。問題があれば理由を stdout へ出す（無ければ空）
pending_stale_reason() {
  local m_branch m_base m_epoch
  m_branch="$(meta_field 2)"; m_base="$(meta_field 3)"; m_epoch="$(meta_field 4)"
  if [[ -z "$m_branch" || -z "$m_base" || -z "$m_epoch" ]]; then
    echo "保留記録にブランチ・基点・時刻の記録が無い"
  elif [[ "$m_branch" != "$(current_branch)" ]]; then
    echo "保留はブランチ ${m_branch} で記録された（今は $(current_branch)）"
  elif ! git -C "$repo_root" merge-base --is-ancestor "$m_base" HEAD 2>/dev/null; then
    echo "保留の基点 ${m_base:0:12} が今の HEAD の祖先でない"
  elif [[ ! "$m_epoch" =~ ^[0-9]+$ ]] || [[ $(( $(date +%s) - m_epoch )) -gt "$PENDING_MAX_AGE" ]]; then
    echo "保留が $(( PENDING_MAX_AGE / 3600 )) 時間より前に記録された"
  fi
}
# default branch の鮮度（add の先頭）。knowledge コミットは default branch へ直 push する（保護されていれば
# そこから PR ブランチを切る）ので、ローカルが origin/<default> より遅れたまま add すると、commit まで進んで
# から push が non-fast-forward で拒否される（PR を続けて curate する回に毎回起きた）。default branch 上
# （merge-cleanup が退避した detached HEAD を含む）の add だけを対象に、fetch と祖先確認を行う。origin
# remote の無いリポジトリ（ローカル専用・検査用の一時 repo）は直 push の経路が無いので確かめない。
# fetch できない回は遅れを判定できないので、黙って進まず名指しで止める。
assert_default_branch_fresh() {
  local default_ref default branch fetch_err behind
  git -C "$repo_root" remote get-url origin >/dev/null 2>&1 || return 0
  # origin/HEAD の無い clone（git init + remote add 等）でも PR ブランチの add を止めないよう、remote の
  # HEAD を問い合わせて default branch を補う。どちらでも解決できない回だけ名指しで止める
  default_ref="$(git -C "$repo_root" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)" || default_ref=""
  if [[ -n "$default_ref" ]]; then
    default="${default_ref#origin/}"
  else
    default="$(git -C "$repo_root" ls-remote --symref origin HEAD 2>/dev/null | awk '$1 == "ref:" && $3 == "HEAD" { sub(/^refs\/heads\//, "", $2); print $2; exit }')"
    [[ -n "$default" ]] \
      || die_env "origin/HEAD を解決できず（remote の HEAD も問い合わせられない）、default branch が遅れていないか確かめられない — git remote set-head origin --auto を実行してから add し直す"
  fi
  branch="$(current_branch)"
  [[ "$branch" == "$default" || "$branch" == "(detached)" ]] || return 0
  fetch_err="$(git -C "$repo_root" fetch -q origin "+refs/heads/${default}:refs/remotes/origin/${default}" 2>&1)" \
    || die_env "origin/${default} を取得できず、ローカルが遅れていないか判定できない（${fetch_err%%$'\n'*}）— 通信・認証を直してから add し直す（遅れを確かめないまま stage しない）"
  if ! git -C "$repo_root" merge-base --is-ancestor "refs/remotes/origin/${default}" HEAD; then
    behind="$(git -C "$repo_root" rev-list --count "HEAD..refs/remotes/origin/${default}" 2>/dev/null)" || behind="?"
    die_stop "ローカルの ${branch} が origin/${default} より ${behind} コミット遅れている — このまま add → commit → push すると push が non-fast-forward で拒否される。git rebase --autostash origin/${default} で取り込んでから add し直す（書いた知見の編集は autostash が退避して戻す。衝突したら解消してから）"
  fi
}

cmd="${1:-}"
[[ -n "$cmd" ]] || usage
shift

case "$cmd" in
  add)
    source="" id="" summary="" category="" add_type=""
    paths=() ids=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --source) [[ $# -ge 2 ]] || usage; source="$2"; shift 2 ;;
        --id) [[ $# -ge 2 ]] || usage; ids+=("$2"); shift 2 ;;
        --summary) [[ $# -ge 2 ]] || usage; summary="$2"; shift 2 ;;
        --category) [[ $# -ge 2 ]] || usage; category="${category:+$category, }$2"; shift 2 ;;
        --type) [[ $# -ge 2 ]] || usage; add_type="$2"; shift 2 ;;
        --) shift; while [[ $# -gt 0 ]]; do paths+=("$1"); shift; done ;;
        *) echo "✗ 不明な引数: $1" >&2; usage ;;
      esac
    done
    # --id は繰り返し指定で累積する（複数エントリを 1 コミットへ畳む回に後勝ちで落とさない）
    for v in ${ids[@]+"${ids[@]}"}; do id="${id:+$id / }$v"; done
    case "$source" in
      ace) [[ "$id" == ACE-?* ]] || die_env "--source ace の --id は ACE- で始めてください: ${id:-（空）}" ;;
      obs) [[ "$id" == OBS-?* ]] || die_env "--source obs の --id は OBS- で始めてください: ${id:-（空）}" ;;
      *) die_env "--source は ace か obs です: ${source:-（空）}" ;;
    esac
    for v in ${ids[@]+"${ids[@]}"}; do [[ "$v" == "${id%%-*}"-?* ]] || die_env "--id の接頭辞が揃っていません: $v"; done
    [[ -n "$summary" ]] || die_env "--summary が空です"
    [[ -z "$add_type" || "$add_type" =~ ^[a-z][a-z-]*$ ]] || die_env "--type は英小文字の commit type です: $add_type"
    # default branch の鮮度（直 push の前提）を stage より前に確かめる
    assert_default_branch_fresh
    # 既存の保留が古ければ（中断した別セッションの残り）今回の追記を足さない
    if [[ -s "$pending" ]]; then
      stale="$(pending_stale_reason)"
      [[ -z "$stale" ]] || die_stop "${stale} — 古い保留へ今回の追記を混ぜないため add しない。knowledge-commit.sh status で確かめ、今回のものなら commit --force で先に確定、古いものなら discard してから add し直す"
    fi
    for v in "$id" "$summary" "$category"; do
      ! has_bad_chars "$v" || die_env "ID・要約・カテゴリにタブ・改行は使えません"
    done
    [[ ${#paths[@]} -gt 0 ]] || die_env "-- の後に書いたファイルのパスを 1 つ以上渡してください"
    rel_paths=()
    for p in "${paths[@]}"; do
      ! has_bad_chars "$p" || die_env "パスにタブ・改行は使えません"
      [[ -e "$p" ]] || die_env "パスが存在しません: $p"
      dir="$(CDPATH='' cd -P -- "$(dirname -- "$p")" 2>/dev/null && pwd -P)" || die_env "パスを解決できません: $p"
      abs="$dir/$(basename -- "$p")"
      case "$abs" in
        "$repo_root"/*) rel_paths+=("${abs#"$repo_root"/}") ;;
        *) die_env "パスがリポジトリの外です: $p" ;;
      esac
    done
    git -C "$repo_root" add -- "${rel_paths[@]}" || die_stop "stage できません: ${rel_paths[*]}"
    if [[ ! -s "$pending" ]]; then
      printf 'M\t%s\t%s\t%s\n' "$(current_branch)" "$(git -C "$repo_root" rev-parse HEAD)" "$(date +%s)" >"$pending" \
        || die_stop "保留記録へ書けません: $pending"
    fi
    if [[ -f "$pending" ]] && awk -F '\t' -v s="$source" -v i="$id" '$1=="E" && $2==s && $3==i {f=1} END{exit !f}' "$pending"; then
      echo "ℹ 同じエントリは記録済みです（${source} ${id}）。未記録のパスだけを足します"
    else
      printf 'E\t%s\t%s\t%s\t%s\n' "$source" "$id" "$summary" "$category" >>"$pending" \
        || die_stop "保留記録へ書けません: $pending"
    fi
    for p in "${rel_paths[@]}"; do
      h="$(git -C "$repo_root" hash-object -- "$p")" || die_stop "内容の hash を取れません: $p"
      # 同じパスの再 add は hash を今の内容へ更新する（最後に add した内容を commit する）
      awk -F '\t' -v p="$p" 'BEGIN { OFS = FS } !($1 == "P" && $2 == p)' "$pending" >"$pending.tmp" && mv "$pending.tmp" "$pending" \
        || die_stop "保留記録へ書けません: $pending"
      printf 'P\t%s\t%s\n' "$p" "$h" >>"$pending" || die_stop "保留記録へ書けません: $pending"
    done
    if [[ -n "$add_type" ]]; then
      awk -F '\t' '$1 != "T"' "$pending" >"$pending.tmp" && mv "$pending.tmp" "$pending" && printf 'T\t%s\n' "$add_type" >>"$pending" \
        || die_stop "保留記録へ書けません: $pending"
    fi
    echo "KNOWLEDGE_PENDING=$(entry_count)"
    ;;

  freshness)
    # add の先頭と同じ鮮度検査だけを行う（add の前に claim 等を stage する呼び出し側が、副作用の前に確かめる）
    [[ $# -eq 0 ]] || usage
    assert_default_branch_fresh
    echo "KNOWLEDGE_FRESHNESS=ok"
    ;;

  status)
    [[ $# -eq 0 ]] || usage
    if [[ ! -s "$pending" ]]; then
      echo "KNOWLEDGE_PENDING=0"
      exit 0
    fi
    echo "KNOWLEDGE_PENDING=$(entry_count)"
    echo "KNOWLEDGE_PENDING_BRANCH=$(meta_field 2)"
    echo "KNOWLEDGE_PENDING_BASE=$(meta_field 3)"
    awk -F '\t' '$1=="E" { print "  " $2 " " $3 " " $4 }' "$pending"
    ;;

  discard)
    [[ $# -eq 0 ]] || usage
    n=0
    [[ ! -s "$pending" ]] || n="$(entry_count)"
    if [[ -s "$pending" ]]; then
      echo "捨てる保留のパス（stage は残る。要らなければ git restore --staged -- <path> で外す）:"
      awk -F '\t' '$1=="P" { print "  " $2 }' "$pending"
    fi
    rm -f "$pending" || die_stop "保留記録を消せません: $pending"
    echo "KNOWLEDGE_DISCARDED=$n"
    ;;

  commit)
    type=""
    force=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --type) [[ $# -ge 2 ]] || usage; type="$2"; shift 2 ;;
        --force) force=1; shift ;;
        *) echo "✗ 不明な引数: $1" >&2; usage ;;
      esac
    done
    [[ -z "$type" || "$type" =~ ^[a-z][a-z-]*$ ]] || die_env "--type は英小文字の commit type です: $type"
    if [[ ! -s "$pending" ]]; then
      echo "KNOWLEDGE_COMMIT=none"
      echo "KNOWLEDGE_ENTRIES=0"
      exit 0
    fi
    # 保留記録の破損（不明な行種別・欠けた列）は黙って読み飛ばさない。
    bad="$(awk -F '\t' '!(($1=="M" && NR==1 && NF==4) || ($1=="E" && NF==5) || ($1=="P" && NF==3) || ($1=="T" && NF==2)) {print NR}' "$pending")"
    [[ -z "$bad" ]] || die_stop "保留記録に解釈できない行があります（行: $(printf '%s' "$bad" | tr '\n' ' ')）: $pending"
    # エントリは ace → obs の順、同じ source の中は add の順に並べる。
    entries="$(awk -F '\t' '$1=="E" && $2=="ace"' "$pending"; awk -F '\t' '$1=="E" && $2=="obs"' "$pending")"
    count="$(entry_count)"
    [[ "$count" -gt 0 ]] || die_stop "保留記録にエントリが無くパスだけがあります: $pending"
    # 鮮度: 別ブランチ・別の基点・古い保留を今回の追記と誤って 1 コミットへ畳まない
    if [[ "$force" -eq 0 ]]; then
      stale="$(pending_stale_reason)"
      [[ -z "$stale" ]] || die_stop "${stale} — 中断した別セッションの追記を混ぜないため commit しない。knowledge-commit.sh status で内容を確かめ、今回のものなら commit --force、古いものなら discard する（保留記録は残してある）"
    fi
    commit_paths=()
    while IFS= read -r p; do
      [[ -n "$p" ]] && commit_paths+=("$p")
    done < <(awk -F '\t' '$1=="P" {print $2}' "$pending")
    [[ ${#commit_paths[@]} -gt 0 ]] || die_stop "保留記録にパスがありません: $pending"
    # add の後に同じファイルへ入った別の編集を吸い込まない（作業ツリーの内容が add 時の hash と一致すること）
    while IFS=$'\t' read -r _ p h; do
      [[ -n "$p" ]] || continue
      [[ -f "$repo_root/$p" && "$(git -C "$repo_root" hash-object -- "$p")" == "$h" ]] \
        || die_stop "add の後に ${p} の内容が変わった — 別の編集を commit へ混ぜないため止める。git diff で確かめ、含めるなら同じ add をやり直す（保留記録は残してある）"
    done < <(awk -F '\t' '$1=="P"' "$pending")
    if [[ -z "$type" ]]; then
      type="$(awk -F '\t' '$1=="T" { t = $2 } END { print t }' "$pending")"
      type="${type:-knowledge}"
    fi
    categories="$(printf '%s\n' "$entries" | awk -F '\t' '$5 != "" { s = s (s == "" ? "" : ", ") $5 } END { print s }')"
    if [[ "$count" -eq 1 ]]; then
      subject="$(printf '%s\n' "$entries" | awk -F '\t' -v t="$type" '{print t ": " $3 " " $4}')"
      body=""
    else
      subject="$(printf '%s\n' "$entries" | awk -F '\t' -v t="$type" '{ s = s (NR > 1 ? " / " : "") $3 } END { print t ": " s }')"
      body="$(printf '%s\n' "$entries" | awk -F '\t' '{print "- " $3 " " $4}')"
    fi
    [[ -z "$categories" ]] || body="${body:+$body$'\n\n'}Categories: $categories"
    ff_commit_identity_check "$repo_root" || exit 1
    msg_args=(-m "$subject")
    [[ -z "$body" ]] || msg_args+=(-m "$body")
    if ! git -C "$repo_root" commit "${msg_args[@]}" -- "${commit_paths[@]}"; then
      die_stop "commit に失敗しました（保留記録は残してあります。原因を直して commit を再実行してください）"
    fi
    sha="$(git -C "$repo_root" rev-parse HEAD)" || die_stop "commit 後の HEAD を解決できません"
    rm -f "$pending" || die_stop "commit は完了しましたが保留記録を消せません（二重コミットを防ぐため手で消してください）: $pending"
    echo "KNOWLEDGE_COMMIT=$sha"
    echo "KNOWLEDGE_SUBJECT=$subject"
    echo "KNOWLEDGE_ENTRIES=$count"
    ;;

  -h|--help) usage ;;
  *) echo "✗ 不明なサブコマンド: $cmd" >&2; usage ;;
esac
