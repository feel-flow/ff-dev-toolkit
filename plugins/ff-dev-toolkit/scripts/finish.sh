#!/usr/bin/env bash
#
# finish.sh — PR の尾（/close-issue → マージ → /merge-cleanup → /ace-curate → /retrospective）の
# 固定手順を 1 本の script へ寄せる。判断（AC の達成判定・知見の抽出・件名規約の確認）は
# skill 本文に残し、機械で決まる部分だけをここで実行して `KEY=値` で報告する。
#
# 使い方:
#   finish.sh precheck <PR番号> [--subject <件名> --body <本文>] [--gate-record <記録のパス>]
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
#      読み、書き戻し用の値（wall-clock / 読み込みバイト / レビュー巡回数 / ゲート分 / 変更クラス）を出す
#   4. checks の有無で分岐する: statusCheckRollup が非空なら `gh pr checks --watch --fail-fast`
#      で完了と成功を待つ。watch の非 0 後は checks の実値を読み直し、失敗があれば rc 1、
#      未完了なら上限付きで再待機、判定不能なら rc 2。空なら待たず、報告文言だけを出す
#   4b. PR のレビュースレッド（inline コメント。自動レビュー bot の指摘を含む）を GraphQL
#      `reviewThreads` で全件読み、**返信の無いスレッド**（未 resolve で、起点の author 以外の投稿が
#      無く、起点が PR 作者でないもの）を列挙する。1 件でもあれば手順 7 で止める（`PRECHECK=blocked`。
#      判定は「返信があるか」だけで内容は見ない — 指摘への判定は人 / エージェントが返信で残す）。
#      取得できない・応答を解釈できない回はスレッド 0 件へ倒さず rc 2（未返信の有無は未確定）。
#      bot の指摘は PR 作成から十数分後に届くので、この読み取りは checks の待機の後（マージ直前）に置く
#   5. 照合直前に PR を読み直し、判定に使った全フィールド（先端・本文・タイトル・コミット・
#      closingIssuesReferences・ファイル・checks の有無ほか）を初回と比べる。差があれば rc 1 で
#      止め、precheck を最初から再実行させる。一致すればリモート先端（headRefOid）をゲート実測の
#      記録と照合する
#      （scripts/check-merge-freshness.sh --fetch）。0 = 一致 / 1 = 不一致（止める）/
#      2 = 判定不能（止めないが REASON / ACTION を報告へ載せる）/ 3 = 検査不成立（止める）。
#      `--gate-record <パス>` を渡した回は、別 checkout（WSL の clone など）で回したゲートの記録を
#      `--record <パス> --record-from-other-checkout` で照合する（記録のブランチ名だけを照合から外し、
#      一致の報告に記録のパスとブランチを添える）。パスが読めなければ gh を呼ぶ前に rc 2 で
#      名指しして止まり、既定の記録へは戻さない
#   6. 判定不能のとき全件ゲートを回し直すべきかを出す（RERUN_FULL_GATE）。記録が部分実行で
#      checks が全件成功した回だけ `no`。「汚れた木で測った」「記録が無い」は checks が成功して
#      いても `yes`。それ以外の理由は `see-action`（ACTION に従う）
#   7. merge コマンドを生成する（2 の抵触で止める回・worktree の一覧が取れない回は生成しない）。
#      base ブランチまたは head ブランチが別の worktree に保持されていれば `--delete-branch` を
#      付けず、取得済み TARGET_REPO を --repo に固定した merge と削除を `&& bash -c …` で繋ぐ（merge が
#      失敗した回に削除だけが走らない）。削除は同一リポジトリの PR に限り
#      （fork の PR は `HEAD_DELETE=skipped-fork`）、照合した先端 OID を lease に載せる
#      （生成時に固定した consumer root で exact ref を照会する。既に無ければ成功、別 OID なら
#      保全し、一致する ref だけを lease 付きで削除する。削除拒否後も再照会し、自動削除との
#      race を不在として扱う。通信失敗・応答不正・期待 OID が残る削除失敗は非 0）。
#      `SKIP_SIMPLE_GIT_HOOKS=1 HUSKY=0` はコード変更を運ばない削除 push だけに付け、consumer の
#      simple-git-hooks / husky のフルゲートを起動しない。削除本文はコマンドへ埋め込み、マージ後の
#      plugin 更新・除去に依存しない（merge-cleanup.sh と同じ lease 方針。公開 ff-dev-toolkit#137）
#      merge 対象は取得済みの完全な repository URL を --repo へ固定する。gh v2.102.0 は明示した
#      --repo の下でローカルの切替・削除を行わないため、後始末は /merge-cleanup へ委譲する。
#      保持 worktree の互換経路と明示的な OID lease は維持する。件名・本文は単引用で包み、`printf '%q'` は使わない
#      （非 UTF-8 ロケールで日本語を壊す）
#
# precheck の出力（stdout、`KEY=値` は行頭一致。複数値のキーは行を繰り返す）:
#   PR_NUMBER= PR_STATE= PR_IS_DRAFT= PR_HEAD_REF= PR_HEAD_OID= PR_BASE_REF= PR_TITLE=
#   TARGET_REPO=owner/repo
#   CLOSES=owner/repo#N（繰り返し） REFS=owner/repo#N（繰り返し） AUTO_CLOSE_UNRELIABLE=0|1
#   PR_COMMITS_SOURCE=git|api|unavailable  PR_COMMITS=<短縮 hash> <件名>（繰り返し。`git log --format='%h %s'
#     origin/<base>..<head>` と同じ行・同じ順。/close-issue 完了報告の「主要コミット」欄へ貼る。自分で書かない）
#   KEYWORD_GATE=none|ok|conflict-title|conflict-commit  KEYWORD_INSPECTED=<行数>
#   KEYWORD_CONFLICT=<origin>\t<issue>\t<text> / KEYWORD_SUGGEST=…（抵触があるとき）
#   MERGE_MESSAGE_GATE=not-required|required|ok|conflict
#   EFFORT_<N>_<key>=<値>（effort-report.sh --issue-metrics の kv をそのまま）
#   EFFORT_<N>_change_class=docs-only|small|other
#   CHECKS=none|passed|failed|unavailable  CHECKS_REPORT=<報告へ貼る文言>
#   REVIEW_THREADS_SOURCE=graphql|unavailable  REVIEW_THREADS=<総数>  REVIEW_THREADS_UNANSWERED=<件数>（後 2 つは graphql のとき。
#     unavailable の回は rc 2 で止まり、ページ上限・cursor 空・hasNextPage 不明の回も SOURCE=unavailable + rc 2）
#   REVIEW_THREAD=<id>\t<path>:<line>\t<起点の author>\t<current|outdated>\t<本文の先頭 60 字>（未返信ごとに繰り返し。
#     id は GraphQL の PullRequestReviewThread ノード ID で、返信は addPullRequestReviewThreadReply へ渡す）
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
#      渡す squash メッセージの抵触 / Refs 群があるのに --subject と --body が無い / 返信の無い
#      レビュースレッドがある）。理由と次の一手を stderr へ
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
#   呼ばず unknown。classic の保護は PR 必須・必須チェック・push 制限・署名必須・読み取り専用のどれかが
#   あるときだけ protected、force push の禁止だけなら `classic=protected-no-pr` で rulesets の判定へ）、push は直 push の
#   固定手順（detached HEAD なら `HEAD:<default>`、push 出力の `-> <default>` 照合、保護ルールで
#   拒否されたら exit 3 + KNOWLEDGE_PUSH=protected）、pr は PR 経由（ブランチ作成 → push → gh pr
#   create → default 開始時だけ local default を origin へ戻す。既存知見ブランチ開始時は default を変更しない）。
#   KNOWLEDGE_DEFAULT_RESTORE は成功時 ok|skipped、復帰失敗時 failed。push と pr はどちらも、ブランチ作成・push より前に
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
#   （`KNOWLEDGE_PR=scope-mismatch`。ブランチを作らず push しない）。pr は default 開始時の復帰が
#   失敗した回を 1 にし、残存 ref と復帰手順を出す。
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

# gh の JSON と子プロセスの機械出力へ ANSI を混ぜない。NO_COLOR は保持する。
# このプロセスでだけ外すので、呼び出し元の色設定は変えない。
unset FORCE_COLOR CLICOLOR_FORCE CLICOLOR

usage() {
  cat >&2 <<'USAGE'
Usage: finish.sh precheck <PR番号> [--subject <件名> --body <本文>] [--gate-record <記録のパス>]
       finish.sh cleanup [--dry-run] <PR番号>
       finish.sh knowledge-commit add [--claim <文書>] --source ace|obs --id <ID> --summary <要約> [--category <c>] [--type <t>] -- <path>...
       finish.sh knowledge-commit commit [--type <t>] [--force]
       finish.sh knowledge-commit status | discard | probe | push
       finish.sh knowledge-commit pr --branch <名> --title <件名> [--body <本文>]
File input: precheck / cleanup / knowledge-commit accept --github-input <absolute index.json>
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
# 同梱スクリプトを exec する直前に、shebang 行だけを読む。検査を別ファイルへ委譲しない
# （委譲先自身が CRLF だと、止める前に壊れる）。対象は起動せず、ファイルも書き換えない。
# 呼び出しは現在のシェルに置く（パイプラインやコマンド置換の中だと exit が親に届かない）。
# knowledge-commit.sh の同名関数と本文を揃える。
assert_bundled_shebang_lf() {
  local target="${1:-}" shown="${1:-}" shebang_line=""
  if [ -z "$shown" ]; then
    shown="（パスが無い）"
  fi
  if [ -z "$target" ] || [ ! -f "$target" ] || [ ! -r "$target" ]; then
    printf '%s\n' "check-shebang-cr: ${shown} を読めません。shebang 行の検査が成立しません" >&2
    exit 2
  fi
  IFS= read -r shebang_line <"$target" || true
  case "$shebang_line" in
    *$'\r'*)
      printf '%s\n' "check-shebang-cr: ${target} の shebang 行に CR があります。index から LF で checkout し直すか、autocrlf の効かない worktree で実行してください" >&2
      exit 2
      ;;
  esac
}
is_pr_number() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; return 0; }

# gh の失敗を「PR 不在」と「gh 不通（認証・通信・その他）」へ分けて名指しする
gh_pr_view_or_die() { # <PR番号> <--json フィールド> → stdout に JSON
  local pr="$1" fields="$2" out err rc
  if [[ -n "${github_input:-}" ]]; then
    local op=finish.precheck.pr phase="${3:-initial}" raw="$github_tmp/pr-$pr-${3:-initial}.json"
    [[ "$fields" != state ]] || op=finish.cleanup.state
    jq -n --arg repository "$github_repository" --argjson pr "$pr" '{repository:$repository,pr:$pr}' >"$github_tmp/scope.json" || exit 2
    github_file_read "$github_input" "$op" "$github_tmp/scope.json" "$phase" "$github_tmp/position.json" >"$raw" || exit 2
    if [[ "$fields" == state ]]; then
      finish_file_require "$raw" "$op" '.state | type == "string" and length > 0' state || exit 2
    else
      finish_file_pr "$raw" "$pr" || exit 2
    fi
    cat "$raw"; return $?
  fi
  err="$(mktemp)" || die_env "一時ファイルを作れません" "TMPDIR を書ける場所へ向けて再実行する"
  out="$(gh pr view "$pr" --json "$fields" 2>"$err")"; rc=$?
  if [[ "$rc" -ne 0 ]]; then
    local text
    text="$(cat "$err")"; rm -f "$err"
    case "$text" in
      *"Unknown JSON field"*)
        # 古い gh が field を知らない回は、どの実行ファイルが答えたかを出す（WSL の PATH 上の古い
        # gh を、利用者が別の gh と取り違えないため。Issue `#2212` / OBS-376）
        local gh_path gh_ver
        gh_path="$(command -v gh 2>/dev/null)" || gh_path=""
        gh_ver="$(gh --version 2>&1 | head -n 1)" || gh_ver=""
        die_env "gh が PR #${pr} の JSON field を知りません（gh: ${text}）。使った gh: ${gh_path:-パスを解決できません}（gh --version: ${gh_ver:-版を読めません}）" "この gh を JSON field に対応する新しい版へ替えるか、新しい版の gh が git を読める作業ツリーで再実行する。実際に選ばれる gh は type -a gh で確かめる（WSL の bash は gh.exe を gh として選ばない）" ;;
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
# shellcheck source=lib/merge-message.sh
. "$self_dir/lib/merge-message.sh" || { echo "merge-message helper を読めません" >&2; exit 2; }
q() { ff_merge_quote "$@"; }

# Explicit file acquisition is separate from the unchanged gh calls below.
github_input=""; github_tmp=""; github_repository=""
finish_file_init() {
  [[ -n "$github_input" ]] || return 0
  need_bundled lib/github-input.sh
  assert_bundled_shebang_lf "$self_dir/lib/github-input.sh"
  # shellcheck source=lib/github-input.sh
  . "$self_dir/lib/github-input.sh" || exit 2
  [[ "$github_input" == /* ]] || { _github_input_error index '--github-input must be absolute'; exit 2; }
  if [[ "${1:-required}" == optional ]]; then
    github_repository="$(_github_input_repository 2>/dev/null)" || github_repository=""
  else
    github_repository="$(_github_input_repository)" || exit 2
  fi
  github_tmp="$(mktemp -d)" || exit 2
  trap 'rm -rf "$github_tmp"' EXIT
  printf '{}\n' >"$github_tmp/position.json"
}
finish_file_require() { # raw / operation / predicate / field
  if ! jq -e "$3" "$1" >/dev/null; then
    _github_input_error "$2" "required field/page: $4"; return 2
  fi
}
finish_file_pr() {
  local raw="$1" pr="$2" field
  for field in number state isDraft headRefName headRefOid baseRefName title body closingIssuesReferences commits statusCheckRollup additions deletions files isCrossRepository; do
    finish_file_require "$raw" finish.precheck.pr "has(\"$field\")" "$field" || return 2
  done
  finish_file_require "$raw" finish.precheck.pr ".number == $pr" number || return 2
  for field in state headRefName headRefOid baseRefName title body; do
    finish_file_require "$raw" finish.precheck.pr ".$field | type == \"string\"" "$field" || return 2
  done
  for field in state headRefName baseRefName; do
    finish_file_require "$raw" finish.precheck.pr ".$field | length > 0" "$field" || return 2
  done
  finish_file_require "$raw" finish.precheck.pr '.headRefOid | test("^[0-9a-fA-F]{40}$")' headRefOid || return 2
  finish_file_require "$raw" finish.precheck.pr '(.isDraft | type == "boolean") and (.isCrossRepository | type == "boolean")' isDraft/isCrossRepository || return 2
  finish_file_require "$raw" finish.precheck.pr '(.closingIssuesReferences | type == "array") and all(.closingIssuesReferences[]; .url | type == "string")' closingIssuesReferences || return 2
  finish_file_require "$raw" finish.precheck.pr '(.commits | type == "array") and all(.commits[]; (.oid | type == "string") and (.messageHeadline | type == "string") and (.messageBody | type == "string"))' commits || return 2
  finish_file_require "$raw" finish.precheck.pr '(.files | type == "array") and all(.files[]; .path | type == "string")' files || return 2
  finish_file_require "$raw" finish.precheck.pr '(.statusCheckRollup | type == "array") and (.additions | type == "number") and (.deletions | type == "number")' statusCheckRollup/additions/deletions || return 2
}

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

# ── cleanup ────────────────────────────────────────────────────────────────────
cmd_cleanup() {
  local dry=() PR_NUMBER=""
  # 委譲前の前提崩れ（未実行）を委譲先の PARTIAL（一部実行済み。rc 2）と重ねない
  DIE_ENV_RC=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry=(--dry-run); shift ;;
      --github-input) [[ $# -ge 2 && -n "$2" ]] || usage; github_input="$2"; shift 2 ;;
      -h|--help) usage ;;
      -*) echo "✗ 不明な引数: $1" >&2; usage ;;
      *) [[ -z "$PR_NUMBER" ]] || usage; PR_NUMBER="$1"; shift ;;
    esac
  done
  is_pr_number "$PR_NUMBER" || die_env "PR 番号が数字ではありません: ${PR_NUMBER:-（空）}" "finish.sh cleanup <マージ済み PR 番号> の形で渡す"
  [[ -n "$github_input" ]] || need_cmd gh "gh をインストールして gh auth login を済ませる"
  need_cmd jq "jq をインストールする"
  need_repo
  finish_file_init
  need_bundled merge-cleanup.sh
  local pr_json pr_state
  pr_json="$(gh_pr_view_or_die "$PR_NUMBER" state cleanup-state)" || exit $?
  pr_state="$(printf '%s' "$pr_json" | jq -r '.state // ""')"
  echo "CLEANUP_PR=${PR_NUMBER}"
  echo "CLEANUP_PR_STATE=${pr_state}"
  # MERGED でない PR は委譲先が破壊的処理の前に中断する（番号の打ち間違い対策。判定は 1 箇所に置く）
  assert_bundled_shebang_lf "${plugin_root}/scripts/merge-cleanup.sh"
  local file_args=()
  [[ -z "$github_input" ]] || file_args=(--github-input "$github_input")
  FF_DEV_TOOLKIT_ROOT="${plugin_root}" bash "${plugin_root}/scripts/merge-cleanup.sh" ${dry[@]+"${dry[@]}"} ${file_args[@]+"${file_args[@]}"} "$PR_NUMBER"
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

kc_file_probe() {
  local default_branch owner_repo="" protection="unknown" classic="unknown" rulesets="unknown" classic_out
  default_branch="$(kc_default_branch)" || return 2
  if [[ -n "$github_repository" ]] && jq -n --arg repository "$github_repository" '{repository:$repository}' >"$github_tmp/scope.json" \
    && github_file_read "$github_input" knowledge.repo "$github_tmp/scope.json" probe "$github_tmp/position.json" >"$github_tmp/repo.json" 2>/dev/null \
    && jq -e --arg expected "${github_repository#*://*/}" '.nameWithOwner == $expected' "$github_tmp/repo.json" >/dev/null; then
    owner_repo="$(jq -r .nameWithOwner "$github_tmp/repo.json")"
  fi
  if [[ -n "$owner_repo" ]] && jq -n --arg repository "$github_repository" --arg branch "$default_branch" '{repository:$repository,branch:$branch}' >"$github_tmp/scope.json"; then
    # The direct call preserves a recognized HTTP status; error text is not a status.
    if github_file_read "$github_input" knowledge.classic-protection "$github_tmp/scope.json" probe "$github_tmp/position.json" >"$github_tmp/classic.json" 2>/dev/null; then
      if [[ "$GITHUB_INPUT_HTTP_STATUS" == 404 ]]; then
        classic="none"
      elif [[ "$GITHUB_INPUT_HTTP_STATUS" == 200 ]] && jq -e '
        type == "object" and has("required_pull_request_reviews") and has("required_status_checks") and has("restrictions") and
        all(.required_pull_request_reviews, .required_status_checks, .restrictions; . == null or type == "object") and
        (.required_signatures.enabled | type == "boolean") and (.lock_branch.enabled | type == "boolean")
      ' "$github_tmp/classic.json" >/dev/null; then
        classic_out="$(jq -r '([.required_pull_request_reviews, .required_status_checks, .restrictions] | any(. != null)) or (.required_signatures.enabled // false) or (.lock_branch.enabled // false)' "$github_tmp/classic.json")"
        case "$classic_out" in true) classic="protected" ;; false) classic="protected-no-pr" ;; esac
      fi
    fi
    if [[ "$classic" != protected ]] \
      && github_file_read "$github_input" knowledge.rulesets "$github_tmp/scope.json" probe "$github_tmp/position.json" >"$github_tmp/rules.json" 2>/dev/null \
      && [[ "$GITHUB_INPUT_LAST" == true && ( -z "$GITHUB_INPUT_HTTP_STATUS" || "$GITHUB_INPUT_HTTP_STATUS" == 200 ) ]] \
      && jq -e 'type == "array" and all(.[]; .type | type == "string")' "$github_tmp/rules.json" >/dev/null; then
      if jq -e 'any(.[]; .type == "pull_request")' "$github_tmp/rules.json" >/dev/null; then rulesets="protected"; else rulesets="none"; fi
    fi
    if [[ "$classic" == protected || "$rulesets" == protected ]]; then
      protection="protected"
    elif [[ ( "$classic" == none || "$classic" == protected-no-pr ) && "$rulesets" == none ]]; then
      protection="unprotected"
    fi
  fi
  echo "protection=${protection} (default_branch=${default_branch}, classic=${classic}, rulesets=${rulesets})"
}

kc_probe() {
  if [[ -n "$github_input" ]]; then kc_file_probe; return $?; fi
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
    # 200 でも直 push を PR 必須にするとは限らない（force push の禁止だけの保護は直 push が通る）。
    # 直 push を止める項目 — required_pull_request_reviews / required_status_checks /
    # restrictions（未設定は応答に現れず jq では null）と、署名必須・読み取り専用
    # （required_signatures / lock_branch は `{enabled: false}` の形で返るので .enabled を読む）—
    # のどれかがあるときだけ protected とし、どれも無ければ protected-no-pr として rulesets の
    # 判定へ進む。中身を読めない回（jq の結果が true / false 以外）は unknown に倒す（既定を試し拒否で切替）。
    classic="unknown"
    classic_out="$(gh api "repos/${owner_repo}/branches/${default_branch}/protection" --jq '([.required_pull_request_reviews, .required_status_checks, .restrictions] | any(. != null)) or (.required_signatures.enabled // false) or (.lock_branch.enabled // false)' 2>&1)" && classic_rc=0 || classic_rc=$?
    if [[ "$classic_rc" -eq 0 ]]; then
      if [[ "$classic_out" == "true" ]]; then
        classic="protected"
      elif [[ "$classic_out" == "false" ]]; then
        classic="protected-no-pr"
      fi
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
    elif [[ ( "$classic" == "none" || "$classic" == "protected-no-pr" ) && "$rulesets" == "none" ]]; then
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
    # classic 保護による拒否全般（GH006 `Protected branch update failed`。必須チェック
    # `Required status check "<名>" is failing` や署名必須もこの行を伴う）と push の制限
    # （`not authorized to push`）による拒否も PR 経由へ寄せる（probe の判定が外れた回の安全網）
    if awk 'index($0, "Changes must be made through a pull request") || index($0, "push declined due to repository rule violations") || index($0, "Protected branch update failed") || index($0, "Required status check") || index($0, "not authorized to push") { f = 1 } END { exit f ? 0 : 1 }' "${push_log}"; then
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
  if [[ -n "$github_input" ]]; then
    if [[ -n "$github_repository" ]] && jq -n --arg repository "$github_repository" --arg branch "$default_branch" --arg sha "$pushed_sha" '{repository:$repository,branch:$branch,limit:5,pushed_sha:$sha}' >"$github_tmp/scope.json" \
      && github_file_read "$github_input" knowledge.ci "$github_tmp/scope.json" after-push "$github_tmp/position.json" >"$github_tmp/ci.json" 2>/dev/null \
      && [[ "$GITHUB_INPUT_LAST" == true && ( -z "$GITHUB_INPUT_HTTP_STATUS" || "$GITHUB_INPUT_HTTP_STATUS" == 200 ) ]] \
      && jq -e 'type == "array" and length <= 5 and all(.[]; has("conclusion") and (.conclusion == null or (.conclusion | type == "string")) and
        (.status | type == "string") and (.workflowName | type == "string") and (.headSha | type == "string" and test("^[0-9a-fA-F]{40}$")))' "$github_tmp/ci.json" >/dev/null; then
      jq -r --arg sha "$pushed_sha" '.[] | "KNOWLEDGE_CI=" + (.workflowName // "?") + "\t" + (.status // "?") + "\t" + (.conclusion // "-") + "\t" + (if .headSha == $sha then "this-push" else "other" end)' "$github_tmp/ci.json" \
        || echo "KNOWLEDGE_CI=(unavailable)"
    else
      echo "KNOWLEDGE_CI=(unavailable)"
    fi
  elif command -v gh >/dev/null 2>&1; then
    gh run list --branch "${default_branch}" --limit 5 --json status,conclusion,workflowName,headSha 2>/dev/null \
      | jq -r --arg sha "$pushed_sha" '.[] | "KNOWLEDGE_CI=" + (.workflowName // "?") + "\t" + (.status // "?") + "\t" + (.conclusion // "-") + "\t" + (if .headSha == $sha then "this-push" else "other" end)' 2>/dev/null \
      || echo "KNOWLEDGE_CI=(unavailable)"
  else
    echo "KNOWLEDGE_CI=(unavailable)"
  fi
  return 0
}

# default 開始時だけローカル default branch を origin へ戻す。
# 既存の知見ブランチからの実行では、default 上の別件の未 push commit を変更しない。
# 戻せない回（別 worktree が保持している等）は残存 ref と復帰手順を出して非 0
kc_restore_default() { # <default branch> <開始 branch> → 0 / 1
  [[ "$2" == "$1" ]] || return 0
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
  [[ -n "$github_input" ]] || need_cmd gh "gh をインストールして gh auth login を済ませる"
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
  # ここから下は失敗時も commit が PR ブランチに残る。
  # default 開始時だけ復帰させる。判定には switch 前の current_branch を使う。
  if ! git push -u origin HEAD; then
    kc_restore_default "${default_branch}" "${current_branch}"
    die_env "PR 経由ブランチの push に失敗しました（commit は ${branch} に残っています）" "認証・通信を確かめて finish.sh knowledge-commit pr を再実行する"
  fi
  upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)" || upstream=""
  if [[ "$upstream" != "origin/${branch}" ]]; then
    kc_restore_default "${default_branch}" "${current_branch}"
    die_env "upstream が想定と異なります（期待: origin/${branch} / 実際: ${upstream:-（無し）}）" "git push -u origin ${branch} で upstream を揃えて再実行する"
  fi
  local pr_url pushed_sha
  if [[ -n "$github_input" ]]; then
    pushed_sha="$(git rev-parse HEAD)" || return 2
    jq -n --arg repository "$github_repository" '{repository:$repository}' >"$github_tmp/scope.json" || return 2
    jq -n --arg head "$branch" --arg base "$default_branch" --arg title "$title" --arg body "${body:-knowledge の追記}" --arg sha "$pushed_sha" \
      '{head:$head,base:$base,title:$title,body:$body,head_sha:$sha}' >"$github_tmp/arguments.json" || return 2
    jq -n --arg repository "$github_repository" --slurpfile a "$github_tmp/arguments.json" \
      '{operation:"knowledge.pr-create",phase:"after-write",expect:{repository:$repository,state:"OPEN",headRefName:$a[0].head,baseRefName:$a[0].base,title:$a[0].title,body:$a[0].body,headRefOid:$a[0].head_sha},returned:["number","url"]}' >"$github_tmp/readback.json" || return 2
    if github_file_read "$github_input" knowledge.pr-create "$github_tmp/scope.json" after-write "$github_tmp/position.json" >"$github_tmp/pr-readback.json" 2>/dev/null \
      && [[ -z "$GITHUB_INPUT_HTTP_STATUS" || "$GITHUB_INPUT_HTTP_STATUS" == 200 ]] \
      && jq -e --arg repository "$github_repository" --slurpfile a "$github_tmp/arguments.json" '
        (.number | type == "number" and . > 0 and floor == .) and
        (.url == ($repository + "/pull/" + (.number | tostring))) and .state == "OPEN" and
        .headRefName == $a[0].head and .baseRefName == $a[0].base and .headRefOid == $a[0].head_sha and
        .title == $a[0].title and .body == $a[0].body
      ' "$github_tmp/pr-readback.json" >/dev/null; then
      pr_url="$(jq -r .url "$github_tmp/pr-readback.json")"
    else
      _github_input_error knowledge.pr-create 'external PR creation and matching fresh read-back required; no completion yet'
      github_file_plan knowledge.pr-create "$github_tmp/scope.json" "$github_tmp/arguments.json" "$github_tmp/readback.json" || true
      if ! kc_restore_default "${default_branch}" "${current_branch}"; then echo "KNOWLEDGE_DEFAULT_RESTORE=failed"; return 1; fi
      return 2
    fi
  elif ! pr_url="$(gh pr create --base "${default_branch}" --title "${title}" --body "${body:-knowledge の追記}")"; then
    kc_restore_default "${default_branch}" "${current_branch}"
    die_env "PR 作成に失敗しました（commit は push 済みの ${branch} に残っています）" "gh pr create --base ${default_branch} --head ${branch} を手で実行する"
  fi
  echo "KNOWLEDGE_PR=${pr_url}"
  echo "KNOWLEDGE_PR_BRANCH=${branch}"
  if ! kc_restore_default "${default_branch}" "${current_branch}"; then
    echo "KNOWLEDGE_DEFAULT_RESTORE=failed"
    exit 1
  fi
  if [[ "$current_branch" == "$default_branch" ]]; then
    echo "KNOWLEDGE_DEFAULT_RESTORE=ok"
  else
    echo "KNOWLEDGE_DEFAULT_RESTORE=skipped"
  fi
  return 0
}

kc_add() {
  # `--` より前（書き込み口のオプションと値）と後（明示 pathspec）を別配列に分ける。オプションの値
  # （--category docs 等）を path と取り違えて stage しないため
  local claim_docs=() args=() pathspecs=() file_args=() default_branch doc
  [[ -z "$github_input" ]] || file_args=(--github-input "$github_input")
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
    assert_bundled_shebang_lf "${plugin_root}/scripts/knowledge-commit.sh"
    FF_DEV_TOOLKIT_ROOT="${plugin_root}" bash "${plugin_root}/scripts/knowledge-commit.sh" freshness || return $?
    need_bundled update-version-claim.sh
    need_bundled check-version-claims.sh
    default_branch="$(kc_default_branch)" || exit 2
    for doc in "${claim_docs[@]}"; do
      assert_bundled_shebang_lf "${plugin_root}/scripts/update-version-claim.sh"
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
    assert_bundled_shebang_lf "${plugin_root}/scripts/check-version-claims.sh"
    if ! FF_DEV_TOOLKIT_ROOT="${plugin_root}" "${plugin_root}/scripts/check-version-claims.sh" --root "$repo_root"; then
      git -C "$repo_root" reset -q -- "${claim_paths[@]}" 2>/dev/null || true
      [[ -z "$index_before" ]] || printf '%s\n' "$index_before" | git -C "$repo_root" update-index --index-info
      die_stop "version claim の検証が赤です（保留・stage は変更していません）" "claim と文書を直してから finish.sh knowledge-commit add --claim を再実行する"
    fi
  fi
  assert_bundled_shebang_lf "${plugin_root}/scripts/knowledge-commit.sh"
  FF_DEV_TOOLKIT_ROOT="${plugin_root}" bash "${plugin_root}/scripts/knowledge-commit.sh" add ${file_args[@]+"${file_args[@]}"} ${args[@]+"${args[@]}"} -- ${pathspecs[@]+"${pathspecs[@]}"} || return $?
  return 0
}

cmd_knowledge_commit() {
  local sub="${1:-}"
  [[ -n "$sub" ]] || usage
  shift
  local args=() file_args=()
  # Preserve valued options and the -- path boundary while removing only our flag.
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --) args+=("$@"); break ;;
      --github-input) [[ $# -ge 2 && -n "$2" ]] || usage; github_input="$2"; shift 2 ;;
      --source|--id|--summary|--category|--type|--claim|--branch|--title|--body)
        [[ $# -ge 2 ]] || usage; args+=("$1" "$2"); shift 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  set -- ${args[@]+"${args[@]}"}
  need_repo
  need_bundled knowledge-commit.sh
  if [[ -n "$github_input" ]]; then
    case "$sub" in
      add|commit|probe|push) finish_file_init optional ;;
      pr) finish_file_init ;;
      *) echo "✗ --github-input はこの pure Git サブコマンドには使いません: $sub" >&2; usage ;;
    esac
    [[ "$sub" != commit ]] || file_args=(--github-input "$github_input")
  fi
  case "$sub" in
    add) kc_add "$@" ;;
    commit|status|discard)
      assert_bundled_shebang_lf "${plugin_root}/scripts/knowledge-commit.sh"
      FF_DEV_TOOLKIT_ROOT="${plugin_root}" bash "${plugin_root}/scripts/knowledge-commit.sh" "$sub" ${file_args[@]+"${file_args[@]}"} "$@" ;;
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
  precheck)
    precheck_lib="$plugin_root/scripts/lib/finish-precheck.sh"
    need_bundled lib/finish-precheck.sh
    assert_bundled_shebang_lf "$precheck_lib"
    _finish_precheck_loading=1; _finish_precheck_loaded=0
    # shellcheck source=lib/finish-precheck.sh
    . "$precheck_lib" || die_env "precheck 構成ファイルを読み込めません" "ff-dev-toolkit を再導入してから skill を呼び直す"
    [[ "$_finish_precheck_loaded" == "1" ]] || die_env "precheck 構成ファイルの読み込みが完了していません" "ff-dev-toolkit を再導入してから skill を呼び直す"
    unset _finish_precheck_loading _finish_precheck_loaded
    cmd_precheck "$@" ;;
  cleanup) cmd_cleanup "$@" ;;
  knowledge-commit) cmd_knowledge_commit "$@" ;;
  -h|--help) usage ;;
  *) echo "✗ 不明なサブコマンド: $cmd" >&2; usage ;;
esac
