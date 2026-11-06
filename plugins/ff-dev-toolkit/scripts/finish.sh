#!/usr/bin/env bash
#
# finish.sh — PR の尾（/close-issue → マージ → /merge-cleanup → /ace-curate → /retrospective）の
# 固定手順を 1 本の script へ寄せる。判断（AC の達成判定・知見の抽出・件名規約の確認）は
# skill 本文に残し、機械で決まる部分だけをここで実行して `KEY=値` で報告する。
#
# 使い方:
#   finish.sh precheck <PR番号> [--subject <件名> --body <本文>] [--gate-record <記録のパス>] [--merge-method squash|merge] [--ack-unchecked <owner/repo#N>] [--ack-post-merge <owner/repo#N> --ack-post-merge-reason <理由>]
#   finish.sh cleanup [--dry-run] [--verbose] <PR番号>
#   finish.sh knowledge-commit add    [--claim <文書>] [--ace-playbook <PLAYBOOK>] <knowledge-commit.sh add の引数>
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
#      渡された回は実際に渡す squash メッセージにも当てる（これがマージの条件）。
#      `--merge-method merge`（merge commit 方式。develop の履歴を残す main への release など）では
#      各コミットがそのまま base へ載るため、コミット由来の抵触（conflict-commit）は 2b で解消できず
#      止める。--subject / --body は merge commit の件名・本文として同じく検査する
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
#      checks が全件成功した回、または部分実行が `COVERS_DIFF` で PR の base と一致し
#      導入先の判定で差分を覆っている回は `no`（リリース前・契約面の変更時は除く。
#      script は rc 0 を返すので、その除外は skill 側の判断）。印が無い・base が違う部分実行は
#      checks の裏付けが無いとき `yes`（checks が全件成功した印なしの部分実行は `no`）。
#      「汚れた木で測った」「記録が無い」は checks が成功していても `yes`。head が一致し
#      clean で同一ブランチの `STATUS=unverified` は `see-action` で、再実行は案内しない
#      （汚れた木・別ブランチは、その前の判定不能のまま）。それ以外の理由も
#      `see-action`（ACTION に従う）
#   7. merge コマンドを生成する（2 の抵触で止める回・worktree の一覧が取れない回は生成しない）。
#      方式は `--merge-method`（squash / merge。省略時は squash）で、`--squash` / `--merge` の
#      どちらかだけを載せる。不正値・空値・2 回目の指定は gh を呼ぶ前に rc 2 で拒否する。
#      base ブランチまたは head ブランチが別の worktree に保持されていれば `--delete-branch` を
#      付けず、取得済み TARGET_REPO を --repo に固定した merge と削除を `&& bash -c …` で繋ぐ（merge が
#      失敗した回に削除だけが走らない）。削除は同一リポジトリの PR に限り
#      （fork の PR は `HEAD_DELETE=skipped-fork`）、照合した先端 OID を lease に載せる
#      （生成時に固定した consumer root で exact ref を照会する。既に無ければ成功、別 OID なら
#      保全し、一致する ref だけを lease 付きで削除する。削除拒否後も再照会し、自動削除との
#      race を不在として扱う。通信失敗・応答不正・期待 OID が残る削除失敗は非 0）。
#      `SKIP_SIMPLE_GIT_HOOKS=1 HUSKY=0` はコード変更を運ばない削除 push だけに付け、consumer の
#      simple-git-hooks / husky のフルゲートを起動しない。`FF_DELETE_PUSH_SKIP_HOOKS=0` の回は
#      生成する削除本文からこの代入を外し、consumer の hook を残す（未設定と 1 は従来どおり）。
#      `FF_MERGE_DELETE_SEPARATE=1` の回は worktree の保持を見ず、MERGE_COMMAND を gh pr merge
#      だけにする（`--delete-branch` も削除の尾も付けない）。0 と 1 以外は PR を読む前に rc 2。
#      削除本文はコマンドへ埋め込み、マージ後の
#      plugin 更新・除去に依存しない（merge-cleanup.sh と同じ lease 方針。公開 ff-dev-toolkit#137）
#      merge 対象は取得済みの完全な repository URL を --repo へ固定する。gh v2.102.0 は明示した
#      --repo の下でローカルの切替・削除を行わないため、後始末は /merge-cleanup へ委譲する。
#      保持 worktree の互換経路と明示的な OID lease は維持する。件名・本文は単引用で包み、`printf '%q'` は使わない
#      （非 UTF-8 ロケールで日本語を壊す）
#
# precheck の出力（stdout、`KEY=値` は行頭一致。複数値のキーは行を繰り返す）:
#   PR_NUMBER= PR_STATE= PR_IS_DRAFT= PR_HEAD_REF= PR_HEAD_OID= PR_BASE_REF= PR_TITLE=
#   TARGET_REPO=owner/repo  MERGE_METHOD=squash|merge
#   CLOSES=owner/repo#N（繰り返し） REFS=owner/repo#N（繰り返し） AUTO_CLOSE_UNRELIABLE=0|1
#   AC_UNCHECKED=owner/repo#N<TAB>行（Closes 対象の本文にある未チェック。繰り返し）
#   AC_UNCHECKED_COUNT=<件数>（Closes 対象があるとき） AC_ACKED=owner/repo#N（--ack-unchecked を渡したとき）
#   POST_MERGE_ACKED=owner/repo#N<TAB>理由（--ack-post-merge を渡したとき。繰り返し）
#   以下 4 つは FF_POST_MERGE_TERMS と FF_POST_MERGE_PATHS を設定した導入先だけ（未設定なら 1 行も出ない）:
#   POST_MERGE_PATH=<パス>（FF_POST_MERGE_PATHS に一致した変更ファイル。繰り返し）
#   POST_MERGE_HIT=owner/repo#N<TAB>body|report<TAB>行（語に一致した行。ack しても消えない。繰り返し）
#   POST_MERGE_HIT_COUNT=<件数>（パスが一致して判定した回）
#   POST_MERGE_GATE=no-closes|no-path|clear|acked|blocked
#   PR_COMMITS_SOURCE=git|api|unavailable  PR_COMMITS=<短縮 hash> <件名>（繰り返し。`git log --format='%h %s'
#     origin/<base>..<head>` と同じ行・同じ順。/close-issue 完了報告の「主要コミット」欄へ貼る。自分で書かない）
#   KEYWORD_GATE=none|ok|conflict-title|conflict-commit  KEYWORD_INSPECTED=<行数>
#   KEYWORD_CONFLICT=<origin>\t<issue>\t<text> / KEYWORD_SUGGEST=…（抵触があるとき）
#   MERGE_MESSAGE_GATE=not-required|required|ok|conflict
#   EFFORT_<N>_<key>=<値>（effort-report.sh --issue-metrics の kv をそのまま）
#   EFFORT_<N>_measured_on=<M>（PR のブランチの Issue M が Closes にあり、N に自分の実測が 1 つも無いとき。
#     N の 4 指標は出さない。N に実測があれば従来どおり EFFORT_<N>_<key> を出す）
#   EFFORT_<N>_change_class=docs-only|small|other（決定木の根の判定から導く）
#   CHECKS=none|passed|failed|unavailable  CHECKS_REPORT=<報告へ貼る文言>
#   REVIEW_THREADS_SOURCE=graphql|unavailable  REVIEW_THREADS=<総数>  REVIEW_THREADS_UNANSWERED=<件数>（後 2 つは graphql のとき。
#     unavailable の回は rc 2 で止まり、ページ上限・cursor 空・hasNextPage 不明の回も SOURCE=unavailable + rc 2）
#   REVIEW_THREAD=<id>\t<path>:<line>\t<起点の author>\t<current|outdated>\t<本文の先頭 60 字>（未返信ごとに繰り返し。
#     id は GraphQL の PullRequestReviewThread ノード ID で、返信は addPullRequestReviewThreadReply へ渡す）
#   PR_SNAPSHOT=unchanged|changed  PR_SNAPSHOT_DIFF=<差のあったフィールド名,…>（changed のとき）
#   FRESH_STATUS=0|2  FRESH_REPORT=<報告へ貼る文言>  FRESH_REASON= FRESH_ACTION=（2 のとき）
#   RERUN_FULL_GATE=no|yes|see-action  RERUN_REASON=
#   BASE_HELD_BY=<path> HEAD_HELD_BY=<path>（別 worktree が保持しているとき）
#   DELETE_BRANCH_MODE=delete-branch|separate-push|separate-consumer  HEAD_DELETE=lease|skipped-fork（separate-push のとき）
#   DELETE_BRANCH_NOTE=（separate-consumer のとき。削除を付けない理由）
#   DELETE_PUSH_HOOKS=skipped|kept（lease の削除尾があるとき。kept はフック回避を外した生成）
#   MERGE_COMMAND_BEGIN … MERGE_COMMAND_END（そのまま実行できる形。書き写さずに貼る）
#   PRECHECK=ready|undetermined|blocked|no-target
#
# 終了コード（precheck）:
#   0  マージへ進める（FRESH_STATUS=0、または 2 でも RERUN_FULL_GATE=no）
#   0  対象 Issue が無い（PRECHECK=no-target。以降の判定を行わない）
#   1  止める（checks 失敗 / 判定の途中で PR が変わった / 鮮度不一致 / 改題で消せる抵触 / 実際に
#      渡す squash メッセージの抵触 / Refs 群があるのに --subject と --body が無い / merge commit 方式で
#      コミットが Refs 運用の Issue を閉じる / 返信の無いレビュースレッドがある / Closes 対象の本文に
#      未チェックの受け入れ条件が残り、その Issue が --ack-unchecked されていない / 設定したパスを含む PR の
#      Closes 対象の本文か完了報告に設定した語の行があり、その Issue が --ack-post-merge されていない）。理由と次の一手を stderr へ
#   2  判定不能・検査不成立（`--merge-method` の不正値・空値・重複（PR を読む前）/ PR 不在 / gh 不通（checks の取得を含む）/
#      jq 不在 / 鮮度照合の検査不成立、および
#      FRESH_STATUS=2 で RERUN_FULL_GATE が no でない回）。判定できなかった項目を名指しし、
#      復帰手段（何を直して再実行するか）を stderr へ出す。後者は MERGE_COMMAND も出す —
#      記録の仕組みを持たないプロジェクトでは判定不能が常態で、止めるかどうかは skill 側の判断
#
# cleanup: PR の実在と gh の到達を確かめてから scripts/merge-cleanup.sh へ委譲する（終了コードは
#   委譲先のまま: 0 完了 / 1 中断 / 2 PARTIAL）。未コミット変更ガードの除外指定
#   FF_MERGE_CLEANUP_IGNORE_PATHS ほか同じ接頭辞の変数は環境変数のまま委譲先へ届く。
#   委譲先の全文は作業ツリーの外（FF_DEV_TOOLKIT_STATE_DIR、未設定なら ~/.config/ff-dev-toolkit。
#   HOME も未設定なら ${TMPDIR:-/tmp}/ff-dev-toolkit）のログへ書き、stdout には
#   「## マージ後 Cleanup 結果」以降と CLEANUP_LOG / CLEANUP_RC を出す。
#   その見出しが無い回は全文を素通しする。--verbose は全文も出す。ログを置けなければ委譲前に rc 1。
#
# knowledge-commit: 共通の書き込み口 scripts/knowledge-commit.sh（add / commit / status / discard。
#   fixture identity ガード内蔵）を呼ぶ。`add --claim <文書>` は `.version-claims/` を持つリポジトリで
#   claim を再生成し、記録パスへ claim を足してから検証（scripts/check-version-claims.sh）する。
#   `add --ace-playbook <PLAYBOOK>` は /ace-curate の記録パス（PLAYBOOK・選択した Changelog・playbook/ の
#   変更と未追跡・PENDING_CANDIDATES.md）を列挙し、PLAYBOOK が HEAD から変わっていれば --claim を足す
#   （スキル本文で bash 専用 lib を source させないため。Issue `#2454`）。
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
Usage: finish.sh precheck <PR番号> [--subject <件名> --body <本文>] [--gate-record <記録のパス>] [--merge-method squash|merge] [--ack-unchecked <owner/repo#N>] [--ack-post-merge <owner/repo#N> --ack-post-merge-reason <理由>]
       finish.sh cleanup [--dry-run] [--verbose] <PR番号>
       finish.sh knowledge-commit add [--claim <文書>] [--ace-playbook <PLAYBOOK>] --source ace|obs --id <ID> --summary <要約> [--category <c>] [--type <t>] -- <path>...
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
# 復旧コマンドの案内（ブランチ名・refspec）は ff_shell_argv で 1 語ずつ引用してから出す
# shellcheck source=lib/shell-quote.sh
. "$self_dir/lib/shell-quote.sh" || { echo "shell-quote helper を読めません" >&2; exit 2; }
q() { ff_merge_quote "$@"; }

# Explicit file acquisition is separate from the unchanged gh calls below.
github_input=""; github_tmp=""; github_repository=""
finish_file_init() {
  [[ -n "$github_input" ]] || return 0
  need_bundled lib/abs-path.sh
  assert_bundled_shebang_lf "$self_dir/lib/abs-path.sh"
  need_bundled lib/github-input.sh
  assert_bundled_shebang_lf "$self_dir/lib/github-input.sh"
  # shellcheck source=lib/github-input.sh
  . "$self_dir/lib/github-input.sh" || exit 2
  github_input_is_absolute "$github_input" || { _github_input_error index '--github-input must be absolute'; exit 2; }
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
  local dry=() PR_NUMBER="" verbose=0
  # 委譲前の前提崩れ（未実行）を委譲先の PARTIAL（一部実行済み。rc 2）と重ねない
  DIE_ENV_RC=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry=(--dry-run); shift ;;
      --verbose) verbose=1; shift ;;
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
  # 全文は作業ツリーの外へ残す。置けないまま委譲すると、失敗の本文がどこにも残らない。
  # set -u でも HOME 未設定を unbound にしない。既定は XDG。HOME も無い最小環境は TMPDIR。
  local state_dir=""
  if [[ -n ${FF_DEV_TOOLKIT_STATE_DIR:-} ]]; then
    state_dir="${FF_DEV_TOOLKIT_STATE_DIR}"
  elif [[ -n ${HOME:-} ]]; then
    state_dir="${HOME}/.config/ff-dev-toolkit"
  else
    state_dir="${TMPDIR:-/tmp}/ff-dev-toolkit"
  fi
  local log_dir="${state_dir}/logs" log_phys="" log_file=""
  if ! mkdir -p -- "$log_dir"; then
    die_env "cleanup のログディレクトリを作成できません: ${log_dir}" "FF_DEV_TOOLKIT_STATE_DIR を書ける場所へ向けて再実行する"
  fi
  log_phys="$(CDPATH='' cd -P -- "$log_dir" && pwd -P)" || die_env "cleanup のログディレクトリを解決できません: ${log_dir}" "FF_DEV_TOOLKIT_STATE_DIR を実在するディレクトリへ向けて再実行する"
  case "$log_phys" in
    "$repo_root"|"$repo_root"/*)
      die_env "cleanup のログがリポジトリ内です: ${log_phys}" "FF_DEV_TOOLKIT_STATE_DIR をリポジトリの外へ向けて再実行する"
      ;;
  esac
  log_file="$(mktemp "${log_phys}/finish-cleanup.XXXXXX")" || die_env "cleanup のログファイルを作成できません: ${log_phys}" "FF_DEV_TOOLKIT_STATE_DIR を書ける場所へ向けて再実行する"
  # MERGED でない PR は委譲先が破壊的処理の前に中断する（番号の打ち間違い対策。判定は 1 箇所に置く）
  assert_bundled_shebang_lf "${plugin_root}/scripts/merge-cleanup.sh"
  local file_args=() rc=0
  [[ -z "$github_input" ]] || file_args=(--github-input "$github_input")
  FF_DEV_TOOLKIT_ROOT="${plugin_root}" bash "${plugin_root}/scripts/merge-cleanup.sh" ${dry[@]+"${dry[@]}"} ${file_args[@]+"${file_args[@]}"} "$PR_NUMBER" >"$log_file" 2>&1 || rc=$?
  # 成功時だけ要約する。失敗の回と、要約が見出しより前の警告を参照する回は全文を出す。
  local summary_file="${log_file}.summary" show_full=0
  if [[ "$verbose" -eq 1 || "$rc" -ne 0 ]]; then
    show_full=1
  elif ! awk 'index($0, "## マージ後 Cleanup 結果") == 1 { found = 1 } found { print } END { exit found ? 0 : 1 }' "$log_file" >"$summary_file"; then
    show_full=1
  elif awk 'index($0, "上の警告") { found = 1 } END { exit found ? 0 : 1 }' "$summary_file"; then
    show_full=1
  fi
  if [[ "$show_full" -eq 1 ]]; then
    cat "$log_file"
  else
    cat "$summary_file"
  fi
  rm -f -- "$summary_file"
  echo "CLEANUP_LOG=${log_file}"
  echo "CLEANUP_RC=${rc}"
  return "$rc"
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
    post_merge_lib="$plugin_root/scripts/lib/finish-precheck-post-merge.sh"
    need_bundled lib/finish-precheck-post-merge.sh
    assert_bundled_shebang_lf "$post_merge_lib"
    _finish_precheck_post_merge_loaded=0
    # shellcheck source=lib/finish-precheck-post-merge.sh
    . "$post_merge_lib" || die_env "precheck 構成ファイルを読み込めません" "ff-dev-toolkit を再導入してから skill を呼び直す"
    [[ "$_finish_precheck_post_merge_loaded" == "1" ]] || die_env "precheck 構成ファイルの読み込みが完了していません" "ff-dev-toolkit を再導入してから skill を呼び直す"
    unset _finish_precheck_loading _finish_precheck_loaded _finish_precheck_post_merge_loaded
    cmd_precheck "$@" ;;
  cleanup) cmd_cleanup "$@" ;;
  knowledge-commit)
    kc_lib="$plugin_root/scripts/lib/finish-knowledge-commit-functions.sh"
    need_bundled lib/finish-knowledge-commit-functions.sh
    assert_bundled_shebang_lf "$kc_lib"
    kc_dir="$(CDPATH='' cd -P -- "$(dirname -- "$kc_lib")" && pwd -P)" || die_env "knowledge-commit 構成ファイルの配置を解決できません" "実体のパスで起動し直す"
    kc_real="${kc_dir}/$(basename -- "$kc_lib")"
    [[ -f "$kc_real" && ! -L "$kc_real" ]] || die_env "knowledge-commit 構成ファイルが無いか symlink です: ${kc_real}" "ff-dev-toolkit を再導入してから skill を呼び直す"
    _finish_kc_loading=1; _finish_kc_loaded=0
    # shellcheck source=lib/finish-knowledge-commit-functions.sh
    . "$kc_real" || die_env "knowledge-commit 構成ファイルを読み込めません" "ff-dev-toolkit を再導入してから skill を呼び直す"
    [[ "$_finish_kc_loaded" == "1" ]] || die_env "knowledge-commit 構成ファイルの読み込みが完了していません" "ff-dev-toolkit を再導入してから skill を呼び直す"
    unset _finish_kc_loading _finish_kc_loaded
    cmd_knowledge_commit "$@" ;;
  -h|--help) usage ;;
  *) echo "✗ 不明なサブコマンド: $cmd" >&2; usage ;;
esac
