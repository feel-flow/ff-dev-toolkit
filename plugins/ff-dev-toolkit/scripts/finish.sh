#!/usr/bin/env bash
#
# finish.sh — PR の尾（/close-issue → マージ → /merge-cleanup → /ace-curate → /retrospective）の
# 固定手順を 1 本の script へ寄せる。判断（AC の達成判定・知見の抽出・件名規約の確認）は
# skill 本文に残し、機械で決まる部分だけをここで実行して `KEY=値` で報告する。
#
# 使い方:
#   finish.sh precheck <PR番号> [--subject <件名> --body <本文>]
#   finish.sh cleanup [--dry-run] <PR番号>
#   finish.sh knowledge-commit add    [--claim <文書>] <knowledge-commit.sh add の引数>
#   finish.sh knowledge-commit commit [--type <type>] [--force]
#   finish.sh knowledge-commit status | discard
#   finish.sh knowledge-commit probe
#   finish.sh knowledge-commit push
#   finish.sh knowledge-commit pr --branch <名> --title <件名> [--body <本文>]
#
# precheck（/close-issue 手順 2 と手順 7 の機械部分。マージ直前にもう一度実行する）:
#   1. PR を読む（gh）。対象 Issue を Closes 群（closingIssuesReferences ∪ 本文の closing
#      keyword）と Refs 群（本文の Ref / Refs のうち Closes に無いもの）へ分ける。両群とも空なら
#      PRECHECK=no-target を出して rc 0 で終わる（checks・鮮度照合・merge コマンド生成へ進まない）
#   2. Refs 群があれば closing keyword 抵触検査（scripts/check-closing-keywords.sh）を
#      供給源（PR タイトル + 全コミットの件名と本文）へ当て、`--subject` / `--body` が
#      渡された回は実際に渡す squash メッセージにも当てる（これがマージの条件）
#   3. Closes 群の各 Issue について hook の実測記録（scripts/effort-report.sh --issue-metrics）を
#      読み、書き戻し用の値（wall-clock / 読み込みバイト / 変更クラス）を出す
#   4. checks の有無で分岐する: statusCheckRollup が非空なら `gh pr checks --watch --fail-fast`
#      で完了と成功を待つ（失敗なら止まる。非 0 のうち API に到達できない回は check の失敗ではなく
#      gh 不通として rc 2）。空なら待たず、報告文言だけを出す
#   5. 照合直前に PR を読み直し、判定に使った全フィールド（先端・本文・タイトル・コミット・
#      closingIssuesReferences・ファイル・checks の有無ほか）を初回と比べる。差があれば rc 1 で
#      止め、precheck を最初から再実行させる。一致すればリモート先端（headRefOid）をゲート実測の
#      記録と照合する
#      （scripts/check-merge-freshness.sh --fetch）。0 = 一致 / 1 = 不一致（止める）/
#      2 = 判定不能（止めないが REASON / ACTION を報告へ載せる）/ 3 = 検査不成立（止める）
#   6. 判定不能のとき全件ゲートを回し直すべきかを出す（RERUN_FULL_GATE）。記録が部分実行で
#      checks が全件成功した回だけ `no`。「汚れた木で測った」「記録が無い」は checks が成功して
#      いても `yes`。それ以外の理由は `see-action`（ACTION に従う）
#   7. merge コマンドを生成する（2 の抵触で止める回・worktree の一覧が取れない回は生成しない）。
#      base ブランチまたは head ブランチが別の worktree に保持されていれば `--delete-branch` を
#      付けず、リモートブランチ削除を `gh pr merge … && git push …` の 1 コマンドで添える（merge が
#      失敗した回に削除だけが走らない）。削除は同一リポジトリの PR に限り
#      （fork の PR は `HEAD_DELETE=skipped-fork`）、照合した先端 OID を lease に載せる
#      （`git push origin --force-with-lease=refs/heads/<head>:<OID> :refs/heads/<head>`。
#      マージ後に同名ブランチが再利用されていればサーバー側で拒否される）
#      （`gh pr merge --delete-branch` は成功後にローカルで base へ切り替えようとして失敗し、
#      リモートブランチ削除まで到達しない）。件名・本文は単引用で包み、`printf '%q'` は使わない
#      （非 UTF-8 ロケールで日本語を壊す）
#
# precheck の出力（stdout、`KEY=値` は行頭一致。複数値のキーは行を繰り返す）:
#   PR_NUMBER= PR_STATE= PR_IS_DRAFT= PR_HEAD_REF= PR_HEAD_OID= PR_BASE_REF= PR_TITLE=
#   TARGET_REPO=owner/repo
#   CLOSES=owner/repo#N（繰り返し） REFS=owner/repo#N（繰り返し） AUTO_CLOSE_UNRELIABLE=0|1
#   KEYWORD_GATE=none|ok|conflict-title|conflict-commit  KEYWORD_INSPECTED=<行数>
#   KEYWORD_CONFLICT=<origin>\t<issue>\t<text> / KEYWORD_SUGGEST=…（抵触があるとき）
#   MERGE_MESSAGE_GATE=not-required|required|ok|conflict
#   EFFORT_<N>_<key>=<値>（effort-report.sh --issue-metrics の kv をそのまま）
#   EFFORT_<N>_change_class=docs-only|small|other
#   CHECKS=none|passed|failed|unavailable  CHECKS_REPORT=<報告へ貼る文言>
#   PR_SNAPSHOT=unchanged|changed  PR_SNAPSHOT_DIFF=<差のあったフィールド名,…>（changed のとき）
#   FRESH_STATUS=0|2  FRESH_REPORT=<報告へ貼る文言>  FRESH_REASON= FRESH_ACTION=（2 のとき）
#   RERUN_FULL_GATE=no|yes|see-action  RERUN_REASON=
#   BASE_HELD_BY=<path> HEAD_HELD_BY=<path>（別 worktree が保持しているとき）
#   DELETE_BRANCH_MODE=delete-branch|separate-push  HEAD_DELETE=lease|skipped-fork（separate-push のとき）
#   MERGE_COMMAND_BEGIN … MERGE_COMMAND_END（そのまま実行できる形。書き写さずに貼る）
#   PRECHECK=ready|undetermined|blocked|no-target
#
# 終了コード（precheck）:
#   0  マージへ進める（FRESH_STATUS=0、または 2 でも RERUN_FULL_GATE=no）
#   0  対象 Issue が無い（PRECHECK=no-target。以降の判定を行わない）
#   1  止める（checks 失敗 / 判定の途中で PR が変わった / 鮮度不一致 / 改題で消せる抵触 / 実際に
#      渡す squash メッセージの抵触 / Refs 群があるのに --subject と --body が無い）。理由と次の一手を stderr へ
#   2  判定不能・検査不成立（PR 不在 / gh 不通（checks の取得を含む）/ jq 不在 / 鮮度照合の検査不成立、および
#      FRESH_STATUS=2 で RERUN_FULL_GATE が no でない回）。判定できなかった項目を名指しし、
#      復帰手段（何を直して再実行するか）を stderr へ出す。後者は MERGE_COMMAND も出す —
#      記録の仕組みを持たないプロジェクトでは判定不能が常態で、止めるかどうかは skill 側の判断
#
# cleanup: PR の実在と gh の到達を確かめてから scripts/merge-cleanup.sh へ委譲する（終了コードは
#   委譲先のまま: 0 完了 / 1 中断 / 2 PARTIAL）。未コミット変更ガードの除外指定
#   FF_MERGE_CLEANUP_IGNORE_PATHS ほか同じ接頭辞の変数は環境変数のまま委譲先へ届く。
#
# knowledge-commit: 共通の書き込み口 scripts/knowledge-commit.sh（add / commit / status / discard。
#   fixture identity ガード内蔵）を呼ぶ。`add --claim <文書>` は `.version-claims/` を持つリポジトリで
#   claim を再生成し、記録パスへ claim を足してから検証（scripts/check-version-claims.sh）する。
#   probe は default branch の保護判定（`protection=protected|unprotected|unknown`。gh が無ければ API を
#   呼ばず unknown）、push は直 push の
#   固定手順（detached HEAD なら `HEAD:<default>`、push 出力の `-> <default>` 照合、保護ルールで
#   拒否されたら exit 3 + KNOWLEDGE_PUSH=protected）、pr は PR 経由（ブランチ作成 → push → gh pr
#   create → ローカル default branch を origin へ戻す）。push と pr はどちらも、ブランチ作成・push より前に
#   origin/<default>..HEAD が knowledge コミット 1 つだけであることを確かめる（送信範囲ガード）。
#   add は `--` より後だけを pathspec として扱い、`--claim` の検証で stage するのは文書・claim・
#   明示 pathspec に限る（オプションの値を path と取り違えない）。add は default branch（または detached
#   HEAD）上なら副作用の前に origin/<default> を fetch して祖先確認を行い、ローカルが遅れていれば
#   復帰手段（git rebase --autostash origin/<default>）つきで止まる（fetch できなければ判定不能で止まる）。
#
# 終了コード（cleanup / knowledge-commit）:
#   委譲先の終了コードをそのまま返す。cleanup の委譲前の前提崩れ（PR 不在 / gh 不通 / 委譲先の
#   不在）は 1（委譲先の PARTIAL = 2 と重ねない）。knowledge-commit の前提崩れは 2。
#   knowledge-commit push は 0 成功 / 1 拒否（non-fast-forward・保護以外の拒否・未到達）/
#   2 送信範囲が knowledge コミット単独でない（`KNOWLEDGE_PUSH=scope-mismatch`。無関係な未 push
#   コミットを一緒に送らない）/ 3 保護ルールによる拒否。pr も送信範囲が単独でなければ 2
#   （`KNOWLEDGE_PR=scope-mismatch`。ブランチを作らず push しない）。pr はローカル default branch を origin へ
#   戻せない回（別 worktree が保持している等）を 1 にし、残存 ref と復帰手順を出す。
#
# 実装上の制約: macOS 標準の bash 3.2 で動くこと（連想配列・readarray を使わない）。
# 抽出に grep を使わない（別実装ではエラーでも 1 を返し `rc<=1 なら正常` が fail-open へ反転する）。
# awk は不一致でも 0 を返すので rc!=0 が本物の失敗だけを意味する。

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
Usage: finish.sh precheck <PR番号> [--subject <件名> --body <本文>]
       finish.sh cleanup [--dry-run] <PR番号>
       finish.sh knowledge-commit add [--claim <文書>] --source ace|obs --id <ID> --summary <要約> [--category <c>] [--type <t>] -- <path>...
       finish.sh knowledge-commit commit [--type <t>] [--force]
       finish.sh knowledge-commit status | discard | probe | push
       finish.sh knowledge-commit pr --branch <名> --title <件名> [--body <本文>]
USAGE
  exit 2
}

# 判定不能・前提崩れ: 何を判定できなかったかを名指しし、復帰手段を添えて止める。rc は 2
# （cleanup だけは委譲先の PARTIAL = 2 と重ねないため DIE_ENV_RC=1 にする）
DIE_ENV_RC=2
die_env() { # <名指し> <復帰手段>
  {
    echo "✗ 判定不能: $1"
    echo "  復帰: $2"
  } >&2
  exit "$DIE_ENV_RC"
}
# 止める判定（検査は成立し、結果がマージを許さない）
die_stop() { # <理由> <次の一手>
  {
    echo "✗ 止める: $1"
    echo "  次の一手: $2"
  } >&2
  exit 1
}

self_dir="$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || die_env "script の配置を解決できません" "実体のパスで起動し直す"
plugin_root="$(CDPATH='' cd -P -- "$self_dir/.." && pwd -P)" || die_env "plugin root を解決できません" "実体のパスで起動し直す"

need_cmd() { # <コマンド> <復帰手段>
  command -v "$1" >/dev/null 2>&1 || die_env "$1 が見つかりません（PATH: ${PATH}）" "$2"
}
need_repo() {
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || die_env "git リポジトリの外です（cwd: ${PWD}）" "対象リポジトリの作業ツリーへ移動して再実行する"
  repo_root="$(CDPATH='' cd -P -- "$repo_root" && pwd -P)" || die_env "リポジトリルートを解決できません" "作業ツリーの実体パスで再実行する"
}
need_bundled() { # <scripts/ からの相対パス>
  [[ -f "$plugin_root/scripts/$1" && ! -L "$plugin_root/scripts/$1" ]] \
    || die_env "同梱 script が無いか symlink です: ${plugin_root}/scripts/$1" "ff-dev-toolkit を再導入してから skill を呼び直す（cache や別 checkout を探さない）"
}
is_pr_number() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; return 0; }

# gh の失敗を「PR 不在」と「gh 不通（認証・通信・その他）」へ分けて名指しする
gh_pr_view_or_die() { # <PR番号> <--json フィールド> → stdout に JSON
  local pr="$1" fields="$2" out err rc
  err="$(mktemp)" || die_env "一時ファイルを作れません" "TMPDIR を書ける場所へ向けて再実行する"
  out="$(gh pr view "$pr" --json "$fields" 2>"$err")"; rc=$?
  if [[ "$rc" -ne 0 ]]; then
    local text
    text="$(cat "$err")"; rm -f "$err"
    case "$text" in
      *"Could not resolve to a PullRequest"*|*"no pull requests found"*|*"not found"*|*"Not Found"*)
        die_env "PR #${pr} が見つかりません（gh: ${text})" "番号を確かめて再実行する（PR 番号省略時は現在のブランチの PR を対象にする skill 側の検出を使う）" ;;
      *)
        die_env "gh で PR #${pr} を読めません（gh 不通: ${text})" "gh auth status で認証を確かめ、ネットワーク・GH_HOST を確認してから再実行する" ;;
    esac
  fi
  rm -f "$err"
  printf '%s' "$out"
}

# 単引用で包み、内側の単引用だけを '\'' へ逃がす（バイト透過なので日本語が壊れない）。
# printf '%q' は使わない — 現在のロケールで文字境界を解釈するため、非 UTF-8 ロケール
# （コンソール codepage 932 / LC_ALL=C）では日本語が生バイトと $'\NNN' の混在になり、
# 出力全体が不正な UTF-8 になる（実測）。末尾の X は $(...) が落とす末尾改行の保全用。
# sed が使えない環境（PATH 破損など）では `|| return 1` で失敗を伝播する。これが無いと
# 空の '' を返して rc=0 で成功し、件名・本文を失った merge コマンドを黙って出す（実測）。
q() { local s; s="$(printf '%sX' "$1" | sed "s/'/'\\\\''/g")" || return 1; printf "'%s'" "${s%X}"; }

# PR の判定に使うフィールドだけを正規化した 1 行 JSON（初回と読み直しの比較用）。checks は待機で
# 結果が変わるので「有無」だけを載せる。
pr_snapshot() { # stdin: gh pr view の JSON → stdout: 正規化した JSON
  jq -cS '{
    state, isDraft, headRefName, headRefOid, baseRefName, isCrossRepository, title, body, additions, deletions,
    closing: ([(.closingIssuesReferences // [])[].url] | sort),
    commits: [(.commits // [])[] | {oid, messageHeadline, messageBody}],
    files: ([(.files // [])[].path] | sort),
    has_checks: ((.statusCheckRollup // []) != [])
  }'
}

# ── precheck ───────────────────────────────────────────────────────────────────
cmd_precheck() {
  local PR_NUMBER="" MERGE_SUBJECT="" MERGE_BODY="" have_subject=0 have_body=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --subject) [[ $# -ge 2 ]] || usage; MERGE_SUBJECT="$2"; have_subject=1; shift 2 ;;
      --body) [[ $# -ge 2 ]] || usage; MERGE_BODY="$2"; have_body=1; shift 2 ;;
      -h|--help) usage ;;
      -*) echo "✗ 不明な引数: $1" >&2; usage ;;
      *) [[ -z "$PR_NUMBER" ]] || usage; PR_NUMBER="$1"; shift ;;
    esac
  done
  is_pr_number "$PR_NUMBER" || die_env "PR 番号が数字ではありません: ${PR_NUMBER:-（空）}" "finish.sh precheck <PR番号> の形で渡す"
  [[ "$have_subject" -eq "$have_body" ]] || die_env "--subject と --body は両方渡す（片方だけだと squash メッセージの供給源がリポジトリ設定へ戻る）" "両方を渡して再実行する"
  need_cmd gh "gh をインストールして gh auth login を済ませる"
  need_cmd jq "jq をインストールする"
  need_repo
  need_bundled check-closing-keywords.sh
  need_bundled check-merge-freshness.sh
  need_bundled effort-report.sh

  local PR_JSON PR_FIELDS="number,state,isDraft,headRefName,headRefOid,baseRefName,title,body,closingIssuesReferences,commits,statusCheckRollup,additions,deletions,files,isCrossRepository"
  PR_JSON="$(gh_pr_view_or_die "$PR_NUMBER" "$PR_FIELDS")" || exit $?
  local pr_state head_ref base_ref head_oid pr_title is_draft is_cross
  pr_state="$(printf '%s' "$PR_JSON" | jq -r '.state // ""')"
  is_draft="$(printf '%s' "$PR_JSON" | jq -r '.isDraft // false')"
  head_ref="$(printf '%s' "$PR_JSON" | jq -r '.headRefName // ""')"
  base_ref="$(printf '%s' "$PR_JSON" | jq -r '.baseRefName // ""')"
  head_oid="$(printf '%s' "$PR_JSON" | jq -r '.headRefOid // ""')"
  pr_title="$(printf '%s' "$PR_JSON" | jq -r '.title // ""')"
  # `//` は false を欠損扱いにするので、null 判定で分ける（同一リポジトリの PR を unknown に落とさない）
  is_cross="$(printf '%s' "$PR_JSON" | jq -r 'if .isCrossRepository == null then "unknown" else (.isCrossRepository | tostring) end')"
  [[ -n "$head_ref" && -n "$base_ref" ]] || die_env "PR #${PR_NUMBER} の head / base ブランチ名を読めません" "gh pr view ${PR_NUMBER} --json headRefName,baseRefName の出力を確かめる"
  printf 'PR_NUMBER=%s\nPR_STATE=%s\nPR_IS_DRAFT=%s\nPR_HEAD_REF=%s\nPR_HEAD_OID=%s\nPR_BASE_REF=%s\nPR_TITLE=%s\n' \
    "$PR_NUMBER" "$pr_state" "$is_draft" "$head_ref" "$head_oid" "$base_ref" "$pr_title"
  [[ "$pr_state" == "OPEN" ]] || echo "⚠️  PR #${PR_NUMBER} は OPEN ではありません（state=${pr_state}）。以降の判定は参考値" >&2

  local TARGET_REPO
  TARGET_REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)"
  [[ -n "$TARGET_REPO" ]] || die_env "リポジトリ名（owner/repo）を解決できません" "gh repo view が通る cwd（origin が GitHub のリポジトリ）で再実行する"
  echo "TARGET_REPO=${TARGET_REPO}"

  # ── 1. 対象 Issue の検出（PR 本文からの抽出は機械で行う。目視で拾わない） ──
  local PR_BODY REFS_RAW CLOSES_RAW API_CLOSES_TOKENS CLOSES_UNION REFS_ONLY EXTRACT_RC
  PR_BODY="$(printf '%s' "$PR_JSON" | jq -r '.body // ""')"
  # 拾う綴りは Ref / Refs のみ（大文字小文字は問わない。コロンが続く形も可）。`関連 #N` や
  # 裸の `#N` は拾わない。awk の現在行を $(0) と書くのは、裸のドル記号 + 0 が skill 読み込み時の
  # 引数展開で PR 番号へ置換された実測（本文から定数文字列に化けて抽出 0 件で素通り）の名残で、
  # script 側でも同じ形を保つ（awk では $ は演算子なので $(0) は現在行と完全に同義）。
  REFS_RAW="$(set -o pipefail
    printf '%s\n' "${PR_BODY}" | awk '
      {
        line = $(0)
        while (match(line, /(^|[^A-Za-z])[Rr][Ee][Ff][Ss]?[ \t:]*([A-Za-z0-9._-]+\/[A-Za-z0-9._-]+)?#[0-9]+/)) {
          token = substr(line, RSTART, RLENGTH)
          sub(/^([^A-Za-z])?[Rr][Ee][Ff][Ss]?[ \t:]*/, "", token)
          print token
          line = substr(line, RSTART + RLENGTH)
        }
      }' | sort -u)"
  EXTRACT_RC=$?
  [[ "${EXTRACT_RC}" -eq 0 ]] || die_env "Refs 参照の抽出に失敗（awk rc=${EXTRACT_RC}）" "awk と sort が PATH に在ることを確かめて再実行する"
  # 本文からの closing keyword 抽出。拾う綴りは GitHub の closing keyword 9 語（大文字小文字は
  # 問わない。コロンが続く形も可）。語中一致（hotfix の fix、enclose の close、auto_fix の fix）は
  # (^|[^a-z0-9_]) で除外する。Refs / 関連 / 裸の #N は拾わない。
  CLOSES_RAW="$(set -o pipefail
    LC_ALL=C
    printf '%s\n' "${PR_BODY}" | awk '
      {
        line = tolower($(0))
        while (match(line, /(^|[^a-z0-9_])(closed|closes|close|fixed|fixes|fix|resolved|resolves|resolve)[ \t:]*([a-z0-9._-]+\/[a-z0-9._-]+)?#[0-9]+/)) {
          token = substr(line, RSTART, RLENGTH)
          sub(/^([^a-z0-9_])?(closed|closes|close|fixed|fixes|fix|resolved|resolves|resolve)[ \t:]*/, "", token)
          print token
          line = substr(line, RSTART + RLENGTH)
        }
      }' | sort -u)"
  EXTRACT_RC=$?
  [[ "${EXTRACT_RC}" -eq 0 ]] || die_env "closing keyword 参照の抽出に失敗（awk rc=${EXTRACT_RC}）" "awk と sort が PATH に在ることを確かめて再実行する"
  # API 由来を owner/repo#N に正規化する。空配列でも jq は 0 件で成功する。
  API_CLOSES_TOKENS="$(printf '%s' "$PR_JSON" | jq -r '
    (.closingIssuesReferences // [])[]
    | (.url | sub("https://github.com/"; "") | sub("/issues/"; "#"))
  ')" || die_env "closingIssuesReferences を正規化できません" "gh pr view ${PR_NUMBER} --json closingIssuesReferences の出力を確かめる"
  # 裸の #N を現在のリポジトリで修飾し、API 由来と本文由来を 1 件に畳む。
  # 集合キーは小文字化して畳む（GitHub の owner/repo は大小を区別しない）。
  CLOSES_UNION="$(set -o pipefail
    LC_ALL=C
    printf '%s\n' "${API_CLOSES_TOKENS}" "${CLOSES_RAW}" \
    | awk -v repo="${TARGET_REPO}" '
        NF {
          token = tolower($(0))
          repo_l = tolower(repo)
          if (token ~ /^#[0-9]+$/) token = repo_l token
          print token
        }
      ' | sort -u)"
  EXTRACT_RC=$?
  [[ "${EXTRACT_RC}" -eq 0 ]] || die_env "Closes 和集合の正規化に失敗（awk rc=${EXTRACT_RC}）" "awk と sort が PATH に在ることを確かめて再実行する"
  # Refs のうち Closes 和集合に含まれないもの（同じ Issue を二重に照合しない）。
  # closing 集合は -v に載せない（awk -v は改行を保持しない実装がある）。C 行を先に流す。
  REFS_ONLY="$(set -o pipefail
    LC_ALL=C
    {
      printf '%s\n' "${CLOSES_UNION}" | awk 'NF{print "C\t" $(0)}'
      printf '%s\n' "${REFS_RAW}" | awk -v repo="${TARGET_REPO}" '
        NF {
          token = tolower($(0))
          repo_l = tolower(repo)
          if (token ~ /^#[0-9]+$/) token = repo_l token
          print "R\t" token
        }
      '
    } | awk -F'\t' '
      $1 == "C" { seen[$2] = 1; next }
      $1 == "R" && !($2 in seen) { print $2 }
    ' | sort -u)"
  EXTRACT_RC=$?
  [[ "${EXTRACT_RC}" -eq 0 ]] || die_env "Refs 差集合の正規化に失敗（awk rc=${EXTRACT_RC}）" "awk と sort が PATH に在ることを確かめて再実行する"

  local tok
  while IFS= read -r tok; do [[ -n "$tok" ]] && printf 'CLOSES=%s\n' "$tok"; done <<<"$CLOSES_UNION"
  while IFS= read -r tok; do [[ -n "$tok" ]] && printf 'REFS=%s\n' "$tok"; done <<<"$REFS_ONLY"
  local api_close_count body_close_count auto_unreliable=0
  api_close_count="$(printf '%s\n' "${API_CLOSES_TOKENS}" | awk 'NF{c++} END{print c+0}')"
  body_close_count="$(printf '%s\n' "${CLOSES_RAW}" | awk 'NF{c++} END{print c+0}')"
  if [[ "$api_close_count" -eq 0 && "$body_close_count" -gt 0 ]]; then auto_unreliable=1; fi
  echo "AUTO_CLOSE_UNRELIABLE=${auto_unreliable}"
  # 両群とも空なら照合する Issue が無い。checks の待機・鮮度照合・merge コマンド生成へ進まない
  # （進めると「対象なし」の PR に ready を出し、貼れば通る merge コマンドまで生成する）
  if [[ -z "$CLOSES_UNION" && -z "$REFS_ONLY" ]]; then
    echo "PRECHECK=no-target"
    echo "ℹ️  参照から検出できる対象 Issue がありません（Closes 群・Refs 群とも空）。checks の待機・鮮度照合・merge コマンド生成は行いません" >&2
    return 0
  fi

  # 関係の分類（鮮度・コミット数）に使う ref を取り込む。失敗しても止めない — 鮮度照合側の
  # --fetch が同じことを試み、取れなければ RELATION=unknown として報告へ出る
  git fetch -q origin "+refs/heads/${base_ref}:refs/remotes/origin/${base_ref}" "+refs/heads/${head_ref}:refs/remotes/origin/${head_ref}" >/dev/null 2>&1 \
    || echo "⚠️  origin から ${base_ref} / ${head_ref} を取り込めませんでした（関係の分類が unknown になりえます）" >&2

  # ── 2. closing keyword 抵触検査（Refs 群があるときだけ） ──
  local GUARD="$plugin_root/scripts/check-closing-keywords.sh"
  local refs_args=() closes_args=() keyword_gate="none" message_gate="not-required" blocked_reason="" blocked_next=""
  while IFS= read -r tok; do [[ -n "$tok" ]] && refs_args+=(--refs-issue "$tok"); done <<<"$REFS_ONLY"
  while IFS= read -r tok; do [[ -n "$tok" ]] && closes_args+=(--closes-issue "$tok"); done <<<"$CLOSES_UNION"
  if [[ ${#refs_args[@]} -gt 0 ]]; then
    local SURFACE GATE_OUT gate_status expected_commits actual_commits NON_TITLE_CONFLICTS
    SURFACE="$(mktemp)" || die_env "一時ファイルを作れません" "TMPDIR を書ける場所へ向けて再実行する"
    # パイプで直結すると上流の失敗が最終段の終了コードに隠れる（jq は部分出力してから死ぬ）。
    # いったん実体化して確定させる。
    printf '%s' "$PR_JSON" | jq -r '
      ("title\t" + .title),
      ((.commits // [])[] | ("commit:" + .oid[0:7] + "\t" + .messageHeadline)),
      ((.commits // [])[] | select(.messageBody != "")
        | "commit-body:" + .oid[0:7] + "\t" + (.messageBody | gsub("\n"; " ")))
    ' >"$SURFACE" || { rm -f "$SURFACE"; die_env "検査面（PR タイトル + コミット）を組み立てられません" "gh pr view ${PR_NUMBER} --json title,commits の出力を確かめる"; }
    # 取得したコミット数がブランチの実コミット数と一致することを確認する
    # （API 側で切り詰められると、落ちた側の `fix: #N` は検査されないまま緑になる）
    actual_commits="$(printf '%s' "$PR_JSON" | jq -r '(.commits // []) | length')"
    expected_commits="$(git rev-list --count "origin/${base_ref}..${head_oid}" 2>/dev/null)" \
      || { rm -f "$SURFACE"; die_env "コミット数を照合できません（origin/${base_ref}..${head_oid} を手元で解決できない）" "git fetch origin ${base_ref} ${head_ref} のうえ再実行する"; }
    [[ "$expected_commits" -eq "$actual_commits" ]] \
      || { rm -f "$SURFACE"; die_env "コミット取得が切り詰められています（期待 ${expected_commits} / 取得 ${actual_commits}）" "PR のコミット数を減らす（squash）か、gh の版を上げてから再実行する"; }
    GATE_OUT="$(mktemp)" || { rm -f "$SURFACE"; die_env "一時ファイルを作れません" "TMPDIR を書ける場所へ向けて再実行する"; }
      FF_DEV_TOOLKIT_ROOT="${plugin_root}" bash "${GUARD}" --repo "${TARGET_REPO}" "${refs_args[@]}" ${closes_args[@]+"${closes_args[@]}"} <"${SURFACE}" >"${GATE_OUT}"
    gate_status=$?
      rm -f "$SURFACE"
    awk -F'\t' '
      $1 == "INSPECTED" { print "KEYWORD_INSPECTED=" $2; next }
      $1 == "CONFLICT" { print "KEYWORD_CONFLICT=" $2 "\t" $3 "\t" $4; next }
      $1 == "SUGGEST" { print "KEYWORD_SUGGEST=" $2 "\t" $3 "\t" $4; next }
    ' "$GATE_OUT"
    NON_TITLE_CONFLICTS="$(awk -F'\t' '$1 == "CONFLICT" && $2 != "title" { count++ } END { print count + 0 }' "$GATE_OUT")"
    rm -f "$GATE_OUT"
    case "$gate_status" in
      0) keyword_gate="ok" ;;
      1)
        if [[ "$NON_TITLE_CONFLICTS" -eq 0 ]]; then
          keyword_gate="conflict-title"
          blocked_reason="PR タイトルが Refs 運用の Issue を閉じる（改題で消せる抵触）"
          blocked_next="gh pr edit ${PR_NUMBER} --title '<Issue 参照を含まない件名>' で改題してから finish.sh precheck を再実行する"
        else
          # コミットの件名・本文は書き換えられない。--subject / --body の明示（下の 2b）だけが解消手段
          keyword_gate="conflict-commit"
        fi ;;
      *) die_env "closing keyword 抵触検査が成立していません（status=${gate_status}）" "scripts/check-closing-keywords.sh を直接実行して原因を確かめる（抵触なしとして扱わない）" ;;
    esac
    echo "KEYWORD_GATE=${keyword_gate}"
    # 2b. 実際に渡す squash メッセージの検査（これがマージの条件）。Refs 運用では両方明示が既定
    if [[ "$have_subject" -eq 1 ]]; then
          printf 'merge-subject\t%s\nmerge-body\t%s\n' "${MERGE_SUBJECT}" "${MERGE_BODY}" \
        | FF_DEV_TOOLKIT_ROOT="${plugin_root}" bash "${GUARD}" --repo "${TARGET_REPO}" "${refs_args[@]}" ${closes_args[@]+"${closes_args[@]}"} >/dev/null
      gate_status=$?
          case "$gate_status" in
        0) message_gate="ok" ;;
        1) message_gate="conflict"
           [[ -n "$blocked_reason" ]] || { blocked_reason="実際に渡す squash メッセージ（--subject / --body）が Refs 運用の Issue を閉じる"; blocked_next="件名・本文から Issue 参照を外して finish.sh precheck を再実行する"; } ;;
        *) die_env "squash メッセージの抵触検査が成立していません（status=${gate_status}）" "scripts/check-closing-keywords.sh を直接実行して原因を確かめる" ;;
      esac
    else
      message_gate="required"
      [[ -n "$blocked_reason" ]] || { blocked_reason="Refs 運用の Issue があるのに --subject / --body が無い（squash メッセージの供給源がリポジトリ設定へ戻り、コミットの fix: #N で閉じうる）"; blocked_next="finish.sh precheck ${PR_NUMBER} --subject '<件名>' --body '<本文>' で実際に渡す文字列を検査する"; }
    fi
  else
    echo "KEYWORD_GATE=none"
  fi
  echo "MERGE_MESSAGE_GATE=${message_gate}"

  # ── 3. 工数の実測（Closes 群の同一リポジトリ Issue） ──
  local change_class repo_l
  change_class="$(printf '%s' "$PR_JSON" | jq -r 'if (((.files // []) | length) > 0 and ([(.files // [])[].path | test("[.]md$")] | all)) then "docs-only" elif ((.additions // 0) + (.deletions // 0)) <= 10 then "small" else "other" end')"
  repo_l="$(printf '%s' "$TARGET_REPO" | tr '[:upper:]' '[:lower:]')"
  while IFS= read -r tok; do
    [[ -n "$tok" ]] || continue
    case "$tok" in
      "${repo_l}#"*)
        local n="${tok#*#}"
        FF_DEV_TOOLKIT_ROOT="${plugin_root}" bash "$plugin_root/scripts/effort-report.sh" --issue-metrics "$n" --repo-dir "$repo_root" 2>/dev/null \
          | awk -v n="$n" -F'=' 'NF >= 2 { key = $1; sub(/^[^=]*=/, ""); print "EFFORT_" n "_" key "=" $0 }' \
          || echo "EFFORT_${n}_wallclock_actual_h=(unmeasured)"
        echo "EFFORT_${n}_change_class=${change_class}" ;;
      *) echo "EFFORT_SKIPPED=${tok}（別リポジトリの Issue。記録は作業中のリポジトリの行だけを読む）" ;;
    esac
  done <<<"$CLOSES_UNION"

  # ── 4. checks の有無で分岐する（待つか、ローカルゲートを根拠にするか） ──
  # PR トリガーの CI を持たないリポジトリでは `gh pr checks --watch` が `no checks reported` で
  # 即終了する。これを CI 通過と早合点しない。既定は PR トリガーの CI がある形で、checks の
  # 完了と成功がマージの根拠になる。取得失敗は「checks 無し」へ倒さず検査不成立。
  local rollup_count checks="none" checks_report checks_out
  rollup_count="$(printf '%s' "$PR_JSON" | jq -r '(.statusCheckRollup // []) | length')"
  if [[ "$rollup_count" == "0" ]]; then
    checks_report="この PR に登録された checks は無い。マージ可否はローカル全件ゲート + 鮮度照合で判定する"
  else
    # checks が在るときだけ待つ（存在するので --watch は必ず終わる）。待機とマージは繋がない
    if checks_out="$(gh pr checks "${PR_NUMBER}" --watch --fail-fast 2>&1)"; then
      checks="passed"
      checks_report="全 checks の完了と成功を確認済み（${rollup_count} 件）"
    else
      printf '%s\n' "${checks_out}" >&2
      # 非 0 は check の失敗だけでなく通信・認証エラーでも返る。API への到達を確かめ直し、
      # 届かなければ check の成否は未確定（失敗として扱わず、gh 不通を名指しする）
      local reach_out
      if ! reach_out="$(gh api rate_limit --jq .rate.remaining 2>&1)"; then
        echo "CHECKS=unavailable"
        die_env "gh pr checks が失敗し、GitHub API にも到達できません（gh 不通: ${reach_out}）。checks の成否は未確定" "gh auth status で認証を確かめ、ネットワーク・GH_HOST を確認してから finish.sh precheck を再実行する（check の失敗として扱わない）"
      fi
      echo "CHECKS=failed"
      die_stop "checks が未完了または失敗（${rollup_count} 件登録）" "赤い check を直して push し、finish.sh precheck を再実行する（マージへ進まない）"
    fi
  fi
  echo "CHECKS=${checks}"
  echo "CHECKS_REPORT=${checks_report}"

  # ── 5. ゲート実測鮮度の照合（マージ直前） ──
  # 照合直前に読み直す — 先端だけでなく PR 全体を（手順 1 からの経過中 — checks の待機を含む — に先端・本文・タイトルが
  # 変わっている可能性がある）。先端だけを読み直すと、待機中に本文へ足された Refs やタイトルの
  # 改題が初回の判定（対象 Issue・抵触検査・工数）をすり抜ける。判定に使った全フィールドを
  # 初回と比べ、差があれば止めて最初からやり直させる（checks の結果は待機で変わるので、
  # 比べるのは checks の有無だけ）。
  # 先端は remote-tracking ref ではなく API の値を使い、ここで得た値を --match-head-commit へそのまま
  # 渡す（照合した先端とマージする先端を同じにする）。remote-tracking ref は前回 fetch 時点の
  # スナップショットなので、fetch を忘れた回に「古い先端 == 古い実測対象」で一致してしまう。
  local PR_JSON_AGAIN snap_before snap_after snap_diff
  PR_JSON_AGAIN="$(gh_pr_view_or_die "$PR_NUMBER" "$PR_FIELDS")" || exit $?
  snap_before="$(pr_snapshot <<<"$PR_JSON")" && snap_after="$(pr_snapshot <<<"$PR_JSON_AGAIN")" \
    && snap_diff="$(jq -rn --argjson a "$snap_before" --argjson b "$snap_after" '[$a | keys[] as $k | select($a[$k] != $b[$k]) | $k] | join(",")')" \
    || die_env "PR の読み直し結果を初回と比べられません（jq）" "gh pr view ${PR_NUMBER} --json ${PR_FIELDS} の出力を確かめる"
  if [[ -n "$snap_diff" ]]; then
    echo "PR_SNAPSHOT=changed"
    echo "PR_SNAPSHOT_DIFF=${snap_diff}"
    die_stop "判定の途中で PR が変わりました（${snap_diff}）。初回の判定（対象 Issue・抵触検査・工数）は変更前の値に基づいています" "finish.sh precheck ${PR_NUMBER} を最初から再実行する（Refs 運用は --subject / --body 付き。途中の出力を流用しない）"
  fi
  echo "PR_SNAPSHOT=unchanged"
  local REMOTE_HEAD FRESHNESS FRESH_OUT FRESH_STATUS FRESH_REPORT FRESH_REASON="" FRESH_ACTION="" FRESH_RECORD
  REMOTE_HEAD="$(printf '%s' "$PR_JSON_AGAIN" | jq -r '.headRefOid // ""')"
  [[ -n "$REMOTE_HEAD" ]] || die_env "リモート先端（headRefOid）が空です" "gh pr view ${PR_NUMBER} --json headRefOid の出力を確かめる"
  FRESHNESS="$plugin_root/scripts/check-merge-freshness.sh"
  FRESH_OUT="$(FF_DEV_TOOLKIT_ROOT="${plugin_root}" bash "${FRESHNESS}" --remote-head "${REMOTE_HEAD}" --fetch)"
  FRESH_STATUS=$?
  case "${FRESH_STATUS}" in
    0)
      # 一致。報告には実測の素性（ゲート名・モード）も載せる — 高速モードの記録を
      # 「全件実行で通した」と読ませないため（モードは合否には使わない）
      FRESH_RECORD="$(FF_DEV_TOOLKIT_ROOT="${plugin_root}" bash "${FRESHNESS}" --print-record 2>/dev/null || true)"
      local fresh_gate fresh_mode fresh_result
      fresh_gate="$(printf '%s\n' "${FRESH_RECORD}" | sed -n 's/^GATE=//p')"
      fresh_mode="$(printf '%s\n' "${FRESH_RECORD}" | sed -n 's/^MODE=//p')"
      fresh_result="$(printf '%s\n' "${FRESH_RECORD}" | sed -n 's/^RESULT=//p')"
      FRESH_REPORT="✅ 一致（${fresh_gate:-ゲート不明} / モード ${fresh_mode:-不明} / ${fresh_result:-結果不明}）"
      ;;
    1)
      printf '%s\n' "${FRESH_OUT}" >&2
      echo "FRESH_STATUS=1"
      echo "✗ 止める: リモート先端がゲート実測対象と一致しません（取り込んで測り直すこと）" >&2
      echo "  次の一手: 上の RELATION / ACTION に従って取り込み（force-push で押し切らない）、ゲートを回し直してから finish.sh precheck を再実行する" >&2
      exit 1
      ;;
    2)
      # 判定不能。止めないが REASON と ACTION を両方そのまま報告へ載せる（黙って素通りさせない）
      FRESH_REASON="$(printf '%s\n' "${FRESH_OUT}" | sed -n 's/^REASON=//p' | head -n 1)"
      FRESH_ACTION="$(printf '%s\n' "${FRESH_OUT}" | sed -n 's/^ACTION=//p' | head -n 1)"
      FRESH_REPORT="⚠️ 判定不能 — ${FRESH_REASON} / 次の一手: ${FRESH_ACTION}"
      ;;
    *)
      printf '%s\n' "${FRESH_OUT}" >&2
      echo "FRESH_STATUS=${FRESH_STATUS}"
      echo "✗ 判定不能: 鮮度照合が成立していません（status=${FRESH_STATUS}）。一致として扱わない" >&2
      echo "  復帰: scripts/check-merge-freshness.sh の使い方エラー・リポジトリの状態を直して再実行する" >&2
      exit 2
      ;;
  esac
  echo "FRESH_STATUS=${FRESH_STATUS}"
  echo "FRESH_REPORT=${FRESH_REPORT}"
  # ── 6. 判定不能のとき全件ゲートを回し直すか ──
  local rerun="" rerun_reason=""
  if [[ "$FRESH_STATUS" -eq 2 ]]; then
    echo "FRESH_REASON=${FRESH_REASON}"
    echo "FRESH_ACTION=${FRESH_ACTION}"
    case "$FRESH_REASON" in
      *"部分実行"*)
        if [[ "$checks" == "passed" ]]; then
          rerun="no"; rerun_reason="記録が部分実行で checks が全件成功（PR の checks がリモート先端を実測している。リリース前・契約面の変更時は除く）"
        else
          rerun="yes"; rerun_reason="記録が部分実行で checks による裏付けが無い"
        fi ;;
      *"汚れていました"*) rerun="yes"; rerun_reason="汚れた木で測った記録（checks が成功していても回し直す）" ;;
      *"記録がありません"*|*"記録先を解決できません"*) rerun="yes"; rerun_reason="実測の記録が無い（checks が成功していても回し直す）" ;;
      *) rerun="see-action"; rerun_reason="FRESH_ACTION に従う（${FRESH_REASON}）" ;;
    esac
    echo "RERUN_FULL_GATE=${rerun}"
    echo "RERUN_REASON=${rerun_reason}"
  fi

  # ── 7. merge コマンドの生成 ──
  # 2 の抵触で止める回は、停止判定より先にコマンドを出さない（出した時点で「貼れば通る」形になる）
  if [[ -n "$blocked_reason" ]]; then
    echo "PRECHECK=blocked"
    die_stop "$blocked_reason" "$blocked_next"
  fi
  # base / head ブランチが別の worktree に保持されていれば --delete-branch を付けない
  # （マージ後にローカルで base へ切り替えられず、リモートブランチ削除まで到達しない）。
  # 一覧が取れない回は保持者 0 とみなさず（fail-open で --delete-branch 付きを出さない）、生成しない
  local wt_list wt_path="" wt_branch="" base_held="" head_held="" line
  wt_list="$(git worktree list --porcelain 2>&1)" \
    || die_env "worktree の一覧を取得できません（git worktree list: ${wt_list}）。保持者を判定できないため merge コマンドを生成しない" "git worktree list --porcelain が通る状態（壊れた worktree は git worktree prune）に直してから finish.sh precheck を再実行する"
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) wt_path="${line#worktree }"; wt_branch="" ;;
      "branch refs/heads/"*)
        wt_branch="${line#branch refs/heads/}"
        [[ "$wt_path" == "$repo_root" ]] && continue
        [[ "$wt_branch" == "$base_ref" ]] && base_held="$wt_path"
        [[ "$wt_branch" == "$head_ref" ]] && head_held="$wt_path" ;;
    esac
  done <<<"$wt_list"
  local DELETE_FLAG=" --delete-branch" delete_mode="delete-branch" head_delete=""
  if [[ -n "$base_held" || -n "$head_held" ]]; then
    DELETE_FLAG=""; delete_mode="separate-push"
    [[ -z "$base_held" ]] || echo "BASE_HELD_BY=${base_held}"
    [[ -z "$head_held" ]] || echo "HEAD_HELD_BY=${head_held}"
    # リモートブランチの削除は同一リポジトリの PR に限る（fork の PR の head は相手のリポジトリにあり、
    # origin の同名ブランチは別物）。削除は照合した先端 OID を lease に載せ、マージ後に同名ブランチが
    # 再利用されていればサーバー側で拒否させる
    if [[ "$is_cross" == "false" ]]; then
      head_delete="lease"
    else
      head_delete="skipped-fork"
      echo "⚠️  head ブランチの削除コマンドは生成しません（isCrossRepository=${is_cross}: fork の PR、または判定不能）" >&2
    fi
    echo "HEAD_DELETE=${head_delete}"
  fi
  echo "DELETE_BRANCH_MODE=${delete_mode}"
  # リモートブランチの削除は merge の成功に条件付ける（`&&` で 1 コマンドにする）。別行にすると
  # merge が失敗（checks 未完了・先端不一致・競合）した回にも削除だけが走り、未マージの PR の
  # head ブランチが消えて PR が閉じる
  local delete_tail=""
  if [[ "$head_delete" == "lease" ]]; then
    q "--force-with-lease=refs/heads/${head_ref}:${REMOTE_HEAD}" >/dev/null && q ":refs/heads/${head_ref}" >/dev/null \
      || die_env "引用に失敗（sed が使えない）。merge コマンドを生成しない" "sed を PATH に戻して再実行する"
    delete_tail="$(printf ' \\\n  && git push origin %s %s' "$(q "--force-with-lease=refs/heads/${head_ref}:${REMOTE_HEAD}")" "$(q ":refs/heads/${head_ref}")")"
  fi
  echo "MERGE_COMMAND_BEGIN"
  if [[ "$have_subject" -eq 1 ]]; then
    # 引数位置の $(...) の失敗は set -e に拾われない（終了ステータスが捨てられる）ため、
    # 生成前に件名・本文の両方を一度通し、q が失敗したらコマンドを出さずに停止する。
    q "${MERGE_SUBJECT}" >/dev/null && q "${MERGE_BODY}" >/dev/null \
      || die_env "引用に失敗（sed が使えない）。merge コマンドを生成しない" "sed を PATH に戻して再実行する"
    printf 'gh pr merge %s --squash --match-head-commit %s%s \\\n  --subject %s \\\n  --body %s%s\n' \
      "${PR_NUMBER}" "${REMOTE_HEAD}" "${DELETE_FLAG:-}" "$(q "${MERGE_SUBJECT}")" "$(q "${MERGE_BODY}")" "${delete_tail:-}"
  else
    printf 'gh pr merge %s --squash --match-head-commit %s%s%s\n' "${PR_NUMBER}" "${REMOTE_HEAD}" "${DELETE_FLAG:-}" "${delete_tail:-}"
  fi
  echo "MERGE_COMMAND_END"

  if [[ "$FRESH_STATUS" -eq 2 && "$rerun" != "no" ]]; then
    echo "PRECHECK=undetermined"
    {
      echo "✗ 判定不能: ゲート実測鮮度を確定できません — ${FRESH_REASON}"
      echo "  復帰: RERUN_FULL_GATE=${rerun}（${rerun_reason}）。記録の仕組みを持つプロジェクトでは clean な木で全件ゲートを回してから finish.sh precheck を再実行する。持たないプロジェクトでは判定不能が常態なので、上の FRESH_REASON / FRESH_ACTION を完了報告へそのまま載せて MERGE_COMMAND で進む（skill 側の判断）"
    } >&2
    exit 2
  fi
  echo "PRECHECK=ready"
  return 0
}

# ── cleanup ────────────────────────────────────────────────────────────────────
cmd_cleanup() {
  local dry=() PR_NUMBER=""
  # 委譲前の前提崩れ（未実行）を委譲先の PARTIAL（一部実行済み。rc 2）と重ねない
  DIE_ENV_RC=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry=(--dry-run); shift ;;
      -h|--help) usage ;;
      -*) echo "✗ 不明な引数: $1" >&2; usage ;;
      *) [[ -z "$PR_NUMBER" ]] || usage; PR_NUMBER="$1"; shift ;;
    esac
  done
  is_pr_number "$PR_NUMBER" || die_env "PR 番号が数字ではありません: ${PR_NUMBER:-（空）}" "finish.sh cleanup <マージ済み PR 番号> の形で渡す"
  need_cmd gh "gh をインストールして gh auth login を済ませる"
  need_cmd jq "jq をインストールする"
  need_repo
  need_bundled merge-cleanup.sh
  local pr_json pr_state
  pr_json="$(gh_pr_view_or_die "$PR_NUMBER" state)" || exit $?
  pr_state="$(printf '%s' "$pr_json" | jq -r '.state // ""')"
  echo "CLEANUP_PR=${PR_NUMBER}"
  echo "CLEANUP_PR_STATE=${pr_state}"
  # MERGED でない PR は委譲先が破壊的処理の前に中断する（番号の打ち間違い対策。判定は 1 箇所に置く）
  FF_DEV_TOOLKIT_ROOT="${plugin_root}" bash "${plugin_root}/scripts/merge-cleanup.sh" ${dry[@]+"${dry[@]}"} "$PR_NUMBER"
  local rc=$?
  echo "CLEANUP_RC=${rc}"
  return "$rc"
}

# ── knowledge-commit ──────────────────────────────────────────────────────────
kc_default_branch() { # → default branch 名（origin/HEAD から）
  local default_ref
  default_ref="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)" \
    || die_env "origin/HEAD を解決できません" "git remote set-head origin --auto を実行してから再実行する"
  [[ "$default_ref" == origin/* ]] || die_env "origin/HEAD が不正です: ${default_ref}" "git remote set-head origin --auto を実行してから再実行する"
  printf '%s' "${default_ref#origin/}"
}

kc_probe() {
  # gh は任意依存: 無ければ API を呼ばず protection=unknown（既定の直 push を試し、拒否されたら PR 経由）
  command -v gh >/dev/null 2>&1 || echo "ℹ️  gh が無いため保護判定は unknown（既定を試し、push が拒否されたら PR 経由へ）" >&2
  # ff-ace-protection-probe:start
  default_ref="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD)" || { echo "origin/HEAD を解決できません。git remote set-head origin --auto 後に再実行してください" >&2; exit 1; }
  [[ "$default_ref" == origin/* ]] || { echo "origin/HEAD が不正です" >&2; exit 1; }
  default_branch="${default_ref#origin/}"
  owner_repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || owner_repo=""
  protection="unknown"
  if [[ -n "$owner_repo" ]]; then
    # classic branch protection API: 404 は「classic ルールが無い」を意味するだけで、
    # Rulesets のみで保護されたブランチでもここは 404 を返す。404 だけで unprotected を
    # 確定させず、必ず rulesets API も確認してから最終判定する。
    # 代入行を単独の simple command にすると set -e 下で失敗時に次行の $? 取得へ
    # 到達できず無音で中断するため（実測）、代入自体を && / || で分岐させて安全にする。
    classic="unknown"
    classic_out="$(gh api "repos/${owner_repo}/branches/${default_branch}/protection" 2>&1 >/dev/null)" && classic_rc=0 || classic_rc=$?
    if [[ "$classic_rc" -eq 0 ]]; then
      classic="protected"
    elif [[ "$classic_out" == *404* ]]; then
      classic="none"
    fi
    rulesets="unknown"
    if [[ "$classic" != "protected" ]]; then
      # rulesets は non_fast_forward（force push 禁止）・required_signatures 等、直 push
      # 自体は禁止しない type も返す。実際に直 push を PR 必須にする pull_request type の
      # 有無だけを見る（そうしないと force-push 禁止だけの一般的なリポジトリで既定の
      # 直 push が黙って PR 経由へ落ちる）。
      rules_pr_required="$(gh api "repos/${owner_repo}/rules/branches/${default_branch}" --jq 'any(.[]; .type == "pull_request")' 2>/dev/null)" && rules_rc=0 || rules_rc=$?
      if [[ "$rules_rc" -eq 0 ]]; then
        if [[ "$rules_pr_required" == "true" ]]; then
          rulesets="protected"
        else
          rulesets="none"
        fi
      fi
    fi
    if [[ "$classic" == "protected" || "$rulesets" == "protected" ]]; then
      protection="protected"
    elif [[ "$classic" == "none" && "$rulesets" == "none" ]]; then
      protection="unprotected"
    fi
  fi
  echo "protection=${protection} (default_branch=${default_branch}, classic=${classic:-n/a}, rulesets=${rulesets:-n/a})"
  # ff-ace-protection-probe:end
}

# 送信範囲の実測（直 push / PR 経由の共通）: default branch に無関係な未 push コミットがあると、
# 同じ push（PR 経由なら同じ PR ブランチ）で一緒に送られる。fetch 後に origin/<default>..HEAD が
# knowledge コミット 1 つだけであることを、ブランチ作成・push より前に確かめる。直 push は
# fast-forward も要る（PR 経由は origin が先行していても PR 側で取り込めるので要らない）
kc_assert_scope() { # <default branch> <出力キー> <fast-forward 必須: 1|0>
  local d="$1" key="$2" need_ff="$3" remote_tip ahead
  git fetch -q origin "+refs/heads/${d}:refs/remotes/origin/${d}" \
    || die_env "origin/${d} を取得できません（送信範囲を判定できない）" "認証・通信・remote 設定を確かめて finish.sh knowledge-commit を再実行する"
  remote_tip="$(git rev-parse --verify --quiet "refs/remotes/origin/${d}")" \
    || die_env "origin/${d} を解決できません" "git fetch origin ${d} のうえ再実行する"
  if [[ "$need_ff" -eq 1 ]] && ! git merge-base --is-ancestor "$remote_tip" HEAD; then
    echo "${key}=rejected"
    die_stop "origin/${d} が先行しています（non-fast-forward）" "取り込んで記録内容を作り直し、再度 add → commit → push する（--force / --force-with-lease で上書きしない）"
  fi
  ahead="$(git rev-list --count "${remote_tip}..HEAD")" || die_env "送信範囲を数えられません" "git rev-list origin/${d}..HEAD を手で確かめる"
  if [[ "$ahead" -ne 1 ]]; then
    echo "${key}=scope-mismatch"
    die_env "送信範囲が knowledge コミット単独ではありません（origin/${d}..HEAD = ${ahead} コミット: $(git log --format='%h %s' "${remote_tip}..HEAD" | tr '\n' ';')）" "無関係なコミットを退避してから再実行する（git branch <退避名> HEAD~1 → git reset --hard origin/${d} → 知見の add → commit をやり直してから push / pr）。0 件なら送るものが無い（commit ができているか status で確かめる）"
  fi
  return 0
}

kc_push() {
  local default_branch current_branch push_refspec push_log pushed_sha
  default_branch="$(kc_default_branch)" || exit 2
  # コミット先ブランチの実測ガード: merge-cleanup の退避などで detached HEAD のまま
  # `git push origin <branch>` を打つと、ローカル branch ref が送られ「Everything up-to-date」で
  # 成功に見えたまま手元の knowledge コミットが届かない
  current_branch="$(git symbolic-ref -q --short HEAD)" || current_branch=""
  if [[ -z "${current_branch}" ]]; then
    echo "detached HEAD のため push refspec を HEAD:${default_branch} 形式にします" >&2
    push_refspec="HEAD:${default_branch}"
  elif [[ "${current_branch}" != "${default_branch}" ]]; then
    die_env "現在のブランチ ${current_branch} は ${default_branch} ではありません（直 push の前提と不一致）" "git switch ${default_branch} してから再実行するか、PR 経由（finish.sh knowledge-commit pr）へ切り替える"
  else
    push_refspec="${default_branch}"
  fi
  kc_assert_scope "${default_branch}" KNOWLEDGE_PUSH 1
  # push 出力を実測する: 終了コードと出力の両方を見る。パイプで tee へ流すと push の終了コードが
  # 失われ、non-fast-forward の rejected 出力（`-> branch` を含む）を成功と誤読するため、
  # ファイルへ落としてから照合する。「Everything up-to-date」は失敗の兆候（何も送っていない）
  push_log="$(mktemp)" || die_env "一時ファイルを作れません" "TMPDIR を書ける場所へ向けて再実行する"
  if ! git push origin "${push_refspec}" >"${push_log}" 2>&1; then
    cat "${push_log}"
    # 保護判定が unknown だった、または判定後に設定が変わった TOCTOU の受け皿。拒否理由が
    # 保護ルールなら PR 経由へ切り替える（commit はできているので再 stage・再 commit はしない）
    if awk 'index($0, "Changes must be made through a pull request") || index($0, "push declined due to repository rule violations") { f = 1 } END { exit f ? 0 : 1 }' "${push_log}"; then
      rm -f "${push_log}"
      echo "KNOWLEDGE_PUSH=protected"
      echo "✗ push が保護ルールで拒否されました（default branch が保護されています）。finish.sh knowledge-commit pr --branch <名> --title <件名> で PR 経由へ切り替える（commit は残っている）" >&2
      exit 3
    fi
    rm -f "${push_log}"
    echo "KNOWLEDGE_PUSH=rejected"
    echo "✗ push が失敗しました（non-fast-forward なら取り込んで記録内容を作り直し、再度 add → commit → push する）" >&2
    exit 1
  fi
  cat "${push_log}"
  if ! awk -v n="-> ${default_branch}" 'index($0, n) { f = 1 } END { exit f ? 0 : 1 }' "${push_log}"; then
    rm -f "${push_log}"
    echo "KNOWLEDGE_PUSH=not-delivered"
    echo "✗ push 出力に -> ${default_branch} が無く、コミットが届いていません（detached HEAD や参照ずれを疑う）" >&2
    exit 1
  fi
  rm -f "${push_log}"
  pushed_sha="$(git rev-parse HEAD)"
  echo "KNOWLEDGE_PUSH=ok"
  echo "KNOWLEDGE_PUSHED_SHA=${pushed_sha}"
  # 直 push は PR 画面に出ないので、今 push した SHA の CI run を見に行く（headSha が一致する run を
  # 探す。in_progress / queued は完了を待って再確認し、failure なら revert ではなく前進で直す）
  if command -v gh >/dev/null 2>&1; then
    gh run list --branch "${default_branch}" --limit 5 --json status,conclusion,workflowName,headSha 2>/dev/null \
      | jq -r --arg sha "$pushed_sha" '.[] | "KNOWLEDGE_CI=" + (.workflowName // "?") + "\t" + (.status // "?") + "\t" + (.conclusion // "-") + "\t" + (if .headSha == $sha then "this-push" else "other" end)' 2>/dev/null \
      || echo "KNOWLEDGE_CI=(unavailable)"
  else
    echo "KNOWLEDGE_CI=(unavailable)"
  fi
  return 0
}

# ローカル default branch を origin へ戻す（未 push の commit を残したまま誤って再 push しないため）。
# 戻せない回（別 worktree が保持している等）は残存 ref と復帰手順を出して非 0
kc_restore_default() { # <default branch> → 0 / 1
  local out remaining
  if out="$(git branch -f "$1" "origin/$1" 2>&1)"; then return 0; fi
  remaining="$(git rev-parse --verify --quiet "refs/heads/$1")" || remaining="?"
  {
    echo "✗ ローカル $1 を origin/$1 へ戻せません: ${out}"
    echo "  残存: refs/heads/$1 = ${remaining}（未 push の knowledge commit を含みうる。誤って再 push しないこと）"
    echo "  復帰: $1 を保持する worktree（git worktree list）で git switch --detach してから git branch -f $1 origin/$1 を実行する"
  } >&2
  return 1
}

kc_pr() {
  local branch="" title="" body="" default_branch current_branch upstream
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --branch) [[ $# -ge 2 ]] || usage; branch="$2"; shift 2 ;;
      --title) [[ $# -ge 2 ]] || usage; title="$2"; shift 2 ;;
      --body) [[ $# -ge 2 ]] || usage; body="$2"; shift 2 ;;
      *) echo "✗ 不明な引数: $1" >&2; usage ;;
    esac
  done
  [[ -n "$branch" && -n "$title" ]] || usage
  need_cmd gh "gh をインストールして gh auth login を済ませる"
  default_branch="$(kc_default_branch)" || exit 2
  current_branch="$(git symbolic-ref -q --short HEAD)" || current_branch=""
  if [[ "$current_branch" == "$default_branch" || "$current_branch" == "$branch" ]]; then
    # ブランチ作成・push より前に送信範囲を確かめる（無関係なコミットを PR ブランチへ載せない）
    kc_assert_scope "${default_branch}" KNOWLEDGE_PR 0
  fi
  if [[ "$current_branch" == "$default_branch" ]]; then
    # default branch 上に knowledge commit ができている（直 push が保護で拒否された回）。
    # git switch -c が失敗した場合はまだ default branch 上にいるため、branch -f は行わない
    git switch -c "$branch" || die_env "PR 経由ブランチの作成に失敗しました（commit は ${default_branch} 上のまま残っています）" "ブランチ名 ${branch} が既に無いか確かめて再実行する"
  elif [[ "$current_branch" != "$branch" ]]; then
    die_env "現在のブランチ ${current_branch:-（detached）} が ${default_branch} でも ${branch} でもありません" "knowledge commit を作ったブランチ上で再実行する"
  fi
  # ここから下は default branch を離れているため、失敗時も commit は PR ブランチに残る。
  # 誤って再 push しないよう、失敗経路では local default branch を origin へ戻してから exit する
  if ! git push -u origin HEAD; then
    kc_restore_default "${default_branch}"
    die_env "PR 経由ブランチの push に失敗しました（commit は ${branch} に残っています）" "認証・通信を確かめて finish.sh knowledge-commit pr を再実行する"
  fi
  upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)" || upstream=""
  if [[ "$upstream" != "origin/${branch}" ]]; then
    kc_restore_default "${default_branch}"
    die_env "upstream が想定と異なります（期待: origin/${branch} / 実際: ${upstream:-（無し）}）" "git push -u origin ${branch} で upstream を揃えて再実行する"
  fi
  local pr_url
  if ! pr_url="$(gh pr create --base "${default_branch}" --title "${title}" --body "${body:-knowledge の追記}")"; then
    kc_restore_default "${default_branch}"
    die_env "PR 作成に失敗しました（commit は push 済みの ${branch} に残っています）" "gh pr create --base ${default_branch} --head ${branch} を手で実行する"
  fi
  echo "KNOWLEDGE_PR=${pr_url}"
  echo "KNOWLEDGE_PR_BRANCH=${branch}"
  if ! kc_restore_default "${default_branch}"; then
    echo "KNOWLEDGE_DEFAULT_RESTORE=failed"
    exit 1
  fi
  echo "KNOWLEDGE_DEFAULT_RESTORE=ok"
  return 0
}

kc_add() {
  # `--` より前（書き込み口のオプションと値）と後（明示 pathspec）を別配列に分ける。オプションの値
  # （--category docs 等）を path と取り違えて stage しないため
  local claim_docs=() args=() pathspecs=() default_branch doc
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --claim) [[ $# -ge 2 ]] || usage; claim_docs+=("$2"); shift 2 ;;
      --) shift; pathspecs=("$@"); break ;;
      *) args+=("$1"); shift ;;
    esac
  done
  if [[ ${#claim_docs[@]} -gt 0 && -d "$repo_root/.version-claims" ]]; then
    # default branch の鮮度は claim の再生成・stage より前に確かめる（遅れていれば何も変えずに止まる。
    # claim の無い add は書き込み口の add 自身が先頭で同じ検査をする）
    FF_DEV_TOOLKIT_ROOT="${plugin_root}" bash "${plugin_root}/scripts/knowledge-commit.sh" freshness || return $?
    need_bundled update-version-claim.sh
    need_bundled check-version-claims.sh
    default_branch="$(kc_default_branch)" || exit 2
    for doc in "${claim_docs[@]}"; do
      FF_DEV_TOOLKIT_ROOT="${plugin_root}" "${plugin_root}/scripts/update-version-claim.sh" --base "origin/${default_branch}" --document "$doc" \
        || die_env "version claim を再生成できません: ${doc}" "origin/${default_branch} を取り込んでから再実行する"
      [[ -f "$repo_root/.version-claims/${doc}.claim" ]] || die_env "claim が生成されていません: .version-claims/${doc}.claim" "update-version-claim.sh の出力を確かめる"
      pathspecs+=("$repo_root/.version-claims/${doc}.claim")
    done
  fi
  if [[ ${#claim_docs[@]} -gt 0 && -d "$repo_root/.version-claims" ]]; then
    # claim の検証は保留への登録より前に行う（検証が赤のとき、未検証の claim を pending / stage に残さない）。
    # 検証器は文書と claim が index に在ることを要求するので、いったん stage して検証し、赤なら
    # index の該当 entry を元に戻す（登録前に戻すので pending は増えない）
    local -a claim_paths=() ; local p index_before
    for doc in "${claim_docs[@]}"; do claim_paths+=("$doc" ".version-claims/${doc}.claim"); done
    # 明示 pathspec は cwd 相対なので絶対化してから repo root 基準の git へ渡す
    for p in ${pathspecs[@]+"${pathspecs[@]}"}; do
      [[ -e "$p" ]] || continue
      case "$p" in /*) claim_paths+=("$p") ;; *) claim_paths+=("$PWD/$p") ;; esac
    done
    index_before="$(git -C "$repo_root" ls-files --stage -- "${claim_paths[@]}" 2>/dev/null)" || index_before=""
    git -C "$repo_root" add -- "${claim_paths[@]}" || die_env "claim と文書を stage できません" "パスを確かめて再実行する"
    if ! FF_DEV_TOOLKIT_ROOT="${plugin_root}" "${plugin_root}/scripts/check-version-claims.sh" --root "$repo_root"; then
      git -C "$repo_root" reset -q -- "${claim_paths[@]}" 2>/dev/null || true
      [[ -z "$index_before" ]] || printf '%s\n' "$index_before" | git -C "$repo_root" update-index --index-info
      die_stop "version claim の検証が赤です（保留・stage は変更していません）" "claim と文書を直してから finish.sh knowledge-commit add --claim を再実行する"
    fi
  fi
  FF_DEV_TOOLKIT_ROOT="${plugin_root}" bash "${plugin_root}/scripts/knowledge-commit.sh" add ${args[@]+"${args[@]}"} -- ${pathspecs[@]+"${pathspecs[@]}"} || return $?
  return 0
}

cmd_knowledge_commit() {
  local sub="${1:-}"
  [[ -n "$sub" ]] || usage
  shift
  need_repo
  need_bundled knowledge-commit.sh
  case "$sub" in
    add) kc_add "$@" ;;
    commit|status|discard)
      FF_DEV_TOOLKIT_ROOT="${plugin_root}" bash "${plugin_root}/scripts/knowledge-commit.sh" "$sub" "$@" ;;
    probe) [[ $# -eq 0 ]] || usage; kc_probe ;;
    push) [[ $# -eq 0 ]] || usage; kc_push ;;
    pr) kc_pr "$@" ;;
    *) echo "✗ 不明なサブコマンド: knowledge-commit $sub" >&2; usage ;;
  esac
}

cmd="${1:-}"
[[ -n "$cmd" ]] || usage
shift
case "$cmd" in
  precheck) cmd_precheck "$@" ;;
  cleanup) cmd_cleanup "$@" ;;
  knowledge-commit) cmd_knowledge_commit "$@" ;;
  -h|--help) usage ;;
  *) echo "✗ 不明なサブコマンド: $cmd" >&2; usage ;;
esac
