# マージ直前のゲート — checks の分岐とゲート実測鮮度（`finish.sh precheck` の出力の読み方）

`/close-issue` 手順 7 の詳細。判定そのものは `scripts/finish.sh precheck` が行い（実体は `scripts/check-merge-freshness.sh` と `gh pr checks`）、本文は `FRESH_STATUS` / `RERUN_FULL_GATE` で分岐するだけを持つ。`FRESH_STATUS=2`（判定不能）が出た回、または分岐の根拠を確かめたい回に読む。

<!--1d51d61fe9bb3156-->
MCP: 取得値: MCP の同じ PR の title/body/全 commits/closingIssuesReferences/statusCheckRollup と全 threads。形式: 完全 raw JSON と checks-retry attempt / after-checks cursor / 別取得 after-threads。渡し先: finish.sh precheck --github-input /absolute/index.json の同じ実行へ渡す。checks 取得不能を [] にしない。不足時: MCP 必須不足は operation / field / page を示して停止。

### 2. closing keyword 抵触検査の分岐（Refs 運用の Issue がある場合）

`gh pr view --json closingIssuesReferences` は PR 本文しか見ない（コミットメッセージは見ない）ため、`Refs #N` を本文に書いた PR でもコミット件名の `fix: #N` でマージ時に Issue が閉じる。検出されるのは **closing keyword と Issue 参照が隣接している場合のみ**（「どこかに keyword、どこかに番号」で判定すると、ほぼ全ての PR で発火してゲートが無視されるようになる）。2a と 2b の両方が要るのは、コミット件名・本文は**書き換えられない**からで、2a だけを条件にするとコミット由来の抵触は改題では解消できず永久に赤になる。

<!--f18ccdd463e3c0b5-->
MCP: 取得値: MCP の同じ PR の title/body/全 commits/closingIssuesReferences/statusCheckRollup と全 threads。形式: 完全 raw JSON と checks-retry attempt / after-checks cursor / 別取得 after-threads。渡し先: finish.sh precheck --github-input /absolute/index.json の同じ実行へ渡す。checks 取得不能を [] にしない。不足時: MCP 必須不足は operation / field / page を示して停止。

#### 2a. 供給源のスキャン

**抵触があった場合、既定のマージ経路（`--subject` / `--body` を省略する形）は安全ではない。** origin ごとの対応:

| origin | 対応 |
| --- | --- |
| `title` のみ（`KEYWORD_GATE=conflict-title`） | `gh pr edit "${PR_NUMBER}" --title "<Issue 参照を含まない件名>"` で改題し、**手順 1 から再実行する**（script は rc 1 で止まる） |
| `commit:<sha>` / `commit-body:<sha>` を含む（`conflict-commit`） | コミットは書き換えられない。2a では止めず、マージ時に `--subject` / `--body` を明示して 2b の結果をマージの条件にする。`KEYWORD_SUGGEST` は改題案または本文の書き換え案 |

<!--20fa0af72bb9582a-->
MCP: 取得値: MCP のPR title/headRefOid。形式: 新 title 原文の構造化引数。渡し先: update_pull_request.title → fresh GET → precheck。不足時: MCP 必須不足は operation / field / page を示して停止。

**2a の抵触で無条件に停止しない**のはこのためで、script は `NON_TITLE_CONFLICTS`（title 以外の抵触数）で分岐する。`KEYWORD_INSPECTED` は実際に検査した行数で、完了報告へ転記する（上流の commits が切り詰められていれば script が検査不成立で止まる）。

#### 2b. 実際に渡す squash メッセージの検査（マージの条件）

`--subject` と `--body` を両方明示した squash merge のメッセージは**その 2 つだけで決まる**（コミットメッセージは畳み込まれない。実測で確認済み）。片方でも省略すると、リポジトリ設定（`squash_merge_commit_title` / `squash_merge_commit_message`）に応じて PR タイトルやコミットメッセージが供給源になる。だから Refs 運用では抵触の有無に関わらず両方明示が既定で、`--subject` / `--body` を渡さなければ script は `MERGE_MESSAGE_GATE=required` で止まる。検査を通った文字列は script が `MERGE_COMMAND` へ引用して載せる — **文字列を打ち直さずそのまま手順 7 へ持ち越す**（`--subject` のコピペこそが実際の再発経路。人が打ち直した時点で、そこが検査とマージの間の継ぎ目になり 2b は何も保証しなくなる）。

### 2c. 返信の無いレビュースレッド（自動レビュー bot の inline を含む）

`/multi-review` → `/close-issue` → `gh pr merge` のチェーンは、PR に付いた自動レビュー bot（GitHub の Codex connector 等）の inline コメントをどこでも読まなかった。bot は PR 作成・push の数分〜十数分後にレビューを付け、`/multi-review` とは別の指摘を出すので、読まずにマージすると P1 が未反映のまま残り、follow-up の 1 サイクル（起票 → PR → レビュー → マージ）が増える（導入先で 3 回実測。気づいたのはいずれもマージ後の `/ace-curate` の報告）。

<!--e3ebf611fcb7a6e4-->
分類: 非操作: 過去のレビュー読込漏れの説明。MCP merge 指示ではなく、次の thread 照合を省略しない理由

script は checks の待機の**後**（マージ直前）に GraphQL `reviewThreads` を全ページ読み、**未返信のスレッド**を列挙する。早すぎる確認の 0 件を「指摘なし」と読まないため、読む時点はここに固定する（PR 作成直後に読み直さない）。

| 出力 | 意味 |
| --- | --- |
| `REVIEW_THREADS_SOURCE=graphql / unavailable` | 読めたか。`unavailable` は取得失敗・解釈不能・ページ上限（50 ページ）・cursor 空・`hasNextPage` 不明で、rc 2（**スレッド 0 件へ倒さない**。未返信の有無は未確定。この回は総数・件数の行も出ない） |
| `REVIEW_THREADS=<総数>` / `REVIEW_THREADS_UNANSWERED=<件数>` | 総数と未返信の件数 |
| `REVIEW_THREAD=<id>\t<path>:<line>\t<起点の author>\t<current\|outdated>\t<本文の先頭 60 字>` | 未返信 1 件につき 1 行。`<id>` は GraphQL の `PullRequestReviewThread` ノード ID（`PRRT_…`）で、REST の `pulls/<n>/comments/<id>/replies` には渡せない（そちらはコメントの数値 id） |

**未返信** = 未 resolve で、**起点の author 以外の投稿が 1 件も無く**（bot 自身の追記だけでは返信にならない）、起点が PR 作者でないスレッド。返信済み・resolve 済み・作者自身のメモは数えない（PR 作者を読めなかった回は作者除外を行わない。コメントが 100 件を超えるスレッドは読めていない側に返信がありうるので数えない）。`outdated`（指摘した行のコードがその後変わった）も返信が無ければ数える — コードが変わっても指摘は消えない。判定は「返信があるか」だけで**内容は見ない**: 指摘の当否は人 / エージェントがスレッドへの返信で残す（この PR で直す / follow-up Issue の番号 / 退ける理由）。

1 件でもあれば手順 7 で `PRECHECK=blocked`（rc 1）になり merge コマンドは出ない（squash メッセージの抵触など先着の停止理由があれば併記される。鮮度不一致で先に止まる回も `PRECHECK=blocked` と未返信の次の一手を併記する）。次の一手は各スレッドへ返信するか resolve してから `finish.sh precheck` を再実行する。返信は `REVIEW_THREAD=` の `<id>` をそのまま GraphQL の mutation へ渡す（`docs-template/05-operations/deployment/git-workflow.md` のスレッド返信と同じ形）:

```bash
gh api graphql -f query='mutation($id: ID!, $body: String!) { addPullRequestReviewThreadReply(input: { pullRequestReviewThreadId: $id, body: $body }) { comment { id } } }' \
  -f id='<REVIEW_THREAD の id>' -f body='この PR で直す: <commit> / follow-up: owner/repo#N / 退ける理由: …'
```

<!--ee62232a835b14f7-->
MCP: 取得値: MCP のthread node ID / 判定 body、または実取得した数値 top-level comment ID。形式: GraphQL thread reply の id/body または REST comment_id/body。渡し先: 同じ thread への返信と fresh replies → precheck。ID の推測変換は禁止。不足時: MCP 必須不足は operation / field / page を示して停止。

返信で「この PR で直す」を選んだ回は fix commit を積むので、手順 4 と同じく手順 1 から回し直す（鮮度記録も動く）。

**時点検査の限界（設計上の受容）**: script が読むのは precheck 実行時点のスレッドで、その後に届いた bot のレビューは次の precheck まで見えない。レビューの「完了」を告げる汎用の信号は無く（bot は PR 作成・push の数分〜十数分後に非同期で付ける）、precheck自体には待つ機構を置かない。fix前の[自動レビューbotの完了確認](../../../docs-template/05-operations/deployment/git-workflow.md#自動レビューbotの完了確認)は別の早期集約手順で、この検査を代替しない。`/close-issue` は checks の待機の後 = マージ直前に 1 回だけ読む位置に固定し、precheck から merge までの間を空けない（fix commit を積んだら手順 1 へ戻るので、そのたびに読み直す）。

#### CI checks の有無による分岐（待つか、ローカルゲートを根拠にするか）

script は対象 PR に checks が登録されているかを先に確認します。**既定は PR トリガーの CI がある形**で、checks の完了と成功がマージの根拠になります。PR トリガーの CI を持たないリポジトリでは `gh pr checks --watch` が `no checks reported` を返して即終了するため、これを CI 通過と早合点してはいけません。`statusCheckRollup` の登録を待つ自作の待機ループは、checks が存在しない repo では永遠に終わりません。

<!--3ae6c2b42c6221d0-->
MCP: 取得値: MCP の同じ PR の title/body/全 commits/closingIssuesReferences/statusCheckRollup と全 threads。形式: 完全 raw JSON と checks-retry attempt / after-checks cursor / 別取得 after-threads。渡し先: finish.sh precheck --github-input /absolute/index.json の同じ実行へ渡す。checks 取得不能を [] にしない。不足時: MCP 必須不足は operation / field / page を示して停止。

- `statusCheckRollup` が**非空**の場合（PR トリガーの CI がある既定の形）は、全 checks の完了と成功を確認してからマージへ進みます。`--watch --fail-fast` で完了を待ち、非 0 なら checks の実値を読み直します。失敗した check があれば `CHECKS=failed` + rc 1 で止め、名前を示します（マージへ進まない）。**checks の成功がマージの根拠で、ローカルの全件ゲートはリリース前（タグ / Release の作成前）と契約面の変更時に限ります** — 通常の PR のローカル検証は部分ゲート（プロジェクトが変更ベースの選択を持つならその実行）で足ります
- `statusCheckRollup` が**空配列**（`null` も同じ扱い）の場合（PR トリガーの CI を持たないリポジトリ）、checks の完了を待たずに次へ進み、`CHECKS_REPORT` の文言（「この PR に登録された checks は無い。マージ可否はローカル全件ゲート + 鮮度照合で判定する」）をそのまま手順 8 の完了報告へ明記します。マージ可否はローカル全件ゲートの実行結果と鮮度照合だけを根拠にします
- `gh pr view` 自体が失敗した場合は、分岐を決められない＝検査が成立していないため停止します（取得失敗を「checks 無し」へ倒さない）
- `gh pr checks` の非 0 は check の失敗だけでなく通信・認証エラーでも返ります。失敗した check がなく未完了なら上限 3 回まで再待機し、checks の成否を確定できないまま上限に達したら `CHECKS=unavailable` + rc 2 で止めます。通信エラーだけを check の失敗として扱いません
- checks の待機を挟むので、script は照合直前に PR を読み直し、判定に使った全フィールド（先端・本文・タイトル・コミット・`closingIssuesReferences`・ファイル・checks の有無ほか）を初回と比べます。差があれば `PR_SNAPSHOT=changed` と `PR_SNAPSHOT_DIFF`（差のあるフィールド名）を出して rc 1 で止まるので、`finish.sh precheck` を**最初から**再実行します（途中の出力を流用しない — 待機中に足された `Refs` や改題は初回の抵触検査を通っていない）

<!--17bbc11ad1f7efc8-->
MCP: 取得値: MCP の同じ PR の title/body/全 commits/closingIssuesReferences/statusCheckRollup と全 threads。形式: 完全 raw JSON と checks-retry attempt / after-checks cursor / 別取得 after-threads。渡し先: finish.sh precheck --github-input /absolute/index.json の同じ実行へ渡す。checks 取得不能を [] にしない。不足時: MCP 必須不足は operation / field / page を示して停止。

#### ゲート実測鮮度そのものの照合

ローカルで回した検証スイートの結果は、**その時点の特定コミットに対する実測**です。実測とマージのあいだにリモートが進んでいると、squash merge は**未実測のコミットまで畳み込む**ため、ゲートを回した意味が消えます（実測: cloud セッションが作成した PR をローカルの worktree で引き取って作業しているあいだに、同じセッションが同じブランチへ別方向の修正を push していた）。

| 検査 | 守る窓 |
| --- | --- |
| `--match-head-commit` | **AC 照合の後**に追加 push された内容がマージへ混入すること |
| 本手順の鮮度照合 | **ゲート実測の後**にリモートが先行していたこと。`headRefOid` はそのドリフトの後に読まれるので、`--match-head-commit` からは見えない |

比較の材料には **API の値（`headRefOid`）を照合直前に読み直して使う**。`git fetch` + `git rev-parse origin/<branch>` を比較に使ってはいけない — remote-tracking ref は前回 fetch 時点のスナップショットで、fetch を忘れた回に「古い先端 == 古い実測対象」で一致してしまう。`--fetch` は関係の分類（祖先か / 未 push か / 分岐か）にだけ使う。

実測対象は自己申告ではなく**記録**から取ります。`scripts/record-gate-head.sh` がゲートの通過時に HEAD・作業ツリーの汚れ・モードを書き、`tests/run-all.sh` は既定一覧の実行でも明示引数の実行でもこれを呼びます。ただし**明示引数の実行は `STATUS=partial`（部分実行）として記録されます** — 名指しした suite しか回っていない記録は、リモート先端と一致していても全件緑へは昇格せず、判定不能（exit 2）として報告されます。**例外: 同じコミットに全件緑（`STATUS=pass`）の記録が既にあるときは、部分実行で上書きしません**（`pass@X` は `partial@X` の上位互換の証拠。全件ゲートの後に名指し 1 本を回す並びは一致のまま）。赤い実行（`STATUS=fail`）は同じコミットでも前回の緑を無効化します。赤の原因がすべて base の先行による鮮度赤（run-all が stale と分類した suite）だけで説明できる回は、記録にその suite 名が残り（`STALE_ONLY_FAILED`）、照合は判定不能のまま「base を取り込み、赤だった suite だけを verify.sh のパスで名指しして回し直す」を案内します — 緑なら部分実行の記録になり、PR の checks が全件成功していればゲート全体を回し直さずに進めます（鮮度の分類は suite 単位の「含む」判定なので、取り込み後の実測を省きません）。

終了コード（`FRESH_STATUS`。個別の原因ではなく終了コードで分岐する）:

- **0 = 一致（無出力）**: `FRESH_REPORT`（`--print-record` のゲート名・モード・結果）を報告へ載せる。高速モードの記録を「全件実行で通した」と読ませない（モードは合否には使わない）
- **1 = 不一致（マージを止める）**: `RELATION` で次の一手が変わる — `ancestor`（実測後にリモートが先行）→ 取り込んで再実測 / `unpushed`（未 push のコミットを測っている）→ push して再実測 / `divergent`（同一ブランチの実測対象と先端が分岐）→ **force-push で押し切らず**相手のコミットの上に自分の変更を積んでから再実測 / `unknown` → fetch の成否を確認し `ACTION` に従う
- **2 = 判定不能（止めないが報告する）**: 原因は増えうる（記録が無い / 別ブランチの記録 / 汚れた木で測った / 直近のゲートが赤い / 記録が部分実行である / 記録の版や内容を解釈できない / 実測対象のコミットが手元に無い）。**2 で止めないのは意図的**です。記録の仕組みを持たないプロジェクトでは判定不能が常態で、そこで無条件にマージを止めると検査ごと迂回されます。**この窓は静かに外れると squash merge に畳み込まれるので、ノイズより見逃しのコストが高い** — だから「黙って緑を返さない」ことを最低線として守り、判定不能は手順 8 の完了報告に必ず載せる（`REASON` と `ACTION` を**両方**。部分実行なら REASON が「何を検証したのか」を名指しし、ACTION がそれを指して次の一手を述べる）
- **3 = 検査不成立（停止する）**

記録の `BRANCH` が現在の名前付きブランチと異なる場合は、コミット照合より前に **`UNDETERMINED`（exit 2）** を返す（別ブランチの古い記録は同一ブランチへの追加 push の証拠ではない。SHA が同一でも一致へ昇格させない）。`BRANCH` が欠落・空・`HEAD`・`(unknown)`、または現在が detached HEAD なら、別ブランチと断定せず従来のコミット照合を行う。

別の checkout（Windows の作業機なら WSL の clone）で全件ゲートを回した回は、`finish.sh precheck <PR番号> --gate-record <その clone の記録のパス>` で記録を明示する。明示した記録に限ってブランチ照合を外し、一致は「`COMMIT` が `headRefOid` と同じ・`STATUS=pass`・`DIRTY=no`・そのコミットが手元に実在」のときだけになる（`COMMIT` が食い違えば `FRESH_STATUS=1` で止まる。読めないパスは rc 2 で名指しして止まり、既定の記録へは戻らない）。記録は WSL 側の `git rev-parse --absolute-git-dir` の下の `ff-dev-toolkit/gate-record` にあり、Git Bash からは `//wsl.localhost/<distro>/home/...` の形で渡す。

鮮度照合が判定不能（`FRESH_STATUS=2`）で、かつ `FRESH_REASON` が「汚れた木で測った / 記録が無い / 記録が部分実行である」のいずれかなら（`RERUN_FULL_GATE=yes`）、clean な作業ツリーで全件ゲートを再実行してから改めて照合します（記録の仕組みを持たないプロジェクトではこの限りではなく、2 でマージを止めない既存規定も変わりません）。**ただし `FRESH_REASON` が「記録が部分実行である」で、かつ checks が非空で全件成功した回に限り、リリース前と契約面の変更時を除き再実行しません**（`RERUN_FULL_GATE=no`） — PR の checks がリモート先端（base へのマージ結果）を実測しており、部分ゲートの記録で判定不能になるのは想定どおりだからです。「汚れた木で測った / 記録が無い」は checks が成功していても従来どおり全件ゲートを再実行します（checks がローカルの検証スイートを回しているとは限らないため）。それ以外の理由は `RERUN_FULL_GATE=see-action`（`FRESH_ACTION` に従う）。

未達 AC の修正ループで fix commit を push した場合、修正前の記録とは不一致になる。**ゲートを回し直してから**マージへ進む。

#### merge コマンドの生成

script が `MERGE_COMMAND_BEGIN` 〜 `MERGE_COMMAND_END` に出す。merge 対象は取得済みのホストを含むリポジトリ URL を引用した `--repo` へ固定し、先端は直前に照合した `REMOTE_HEAD`、件名・本文は 2b が検査した文字列を単引用で包む（`printf '%q'` は非 UTF-8 ロケールで日本語を壊すので使わない）。

`--delete-branch` は base / head が別 worktree に保持されていない回だけ付く。保持されている回は付けず、merge 成功時だけ実行する head 削除本文を `&&` で繋ぐ（`DELETE_BRANCH_MODE=separate-push`・`BASE_HELD_BY` / `HEAD_HELD_BY`・`HEAD_DELETE=lease`。fork は `skipped-fork` で削除を生成しない）。削除は生成元 consumer の exact ref を照会し、不在は成功・別 OID は保全・一致だけ lease 付き削除、拒否後も再照会する。`HEAD_DELETE_RESULT` と非 0 の読み方は [Git Workflow](../../../docs-template/05-operations/deployment/git-workflow.md#ステップ8-マージmerge) に従う。

gh 経路の生成コマンドは書き写さず、そのまま実行する。MCP 経路だけは下の「MCP merge」の6引数への直接対応を使う。削除を別行にすると merge 失敗後にも未マージの head を削除できる。取得済み URL の `--repo` により、実行時の cwd・`GH_REPO`・`GH_HOST`・既定ホストから対象を選び直さない。gh v2.102.0 は明示した `--repo` の下でローカルの切替・削除を行わず、その後始末は `/merge-cleanup` へ委譲する。保持 worktree の separate-push 経路は互換性と明示的な OID lease のために維持する。

<!--4c815179839a3a80-->
MCP: 取得値: MCP の同じ最終 headRefOid と元 subject/body。形式: 既存 merge_pull_request の6引数。渡し先: TARGET_REPO/PR/head/squash/元subject/元body を直接渡し fresh merged/state 後読。shell parse 禁止。不足時: MCP 必須不足は operation / field / page を示して停止。

#### 完了報告の定型文

`AUTO_CLOSE_UNRELIABLE=1`（本文に closing keyword があるのに `closingIssuesReferences` が空）のときは、Closes 運用の報告へ次を**必ず**追加する（省略すると AC 照合だけ通して Issue が open のまま残る）。確認済みの事実と推測を書き分け、因果は断定しない:

```markdown
⚠️ この PR のマージでは Issue が自動クローズされない可能性が高い

確認済みの事実:
- PR 本文に closing keyword がある
- `closingIssuesReferences` は空である（この PR はそれらの Issue を閉じる参照として載っていない）

推測（原因の断定ではない）:
- この PR の base がリポジトリのデフォルトブランチでないことが原因である可能性がある

マージ後に手動クローズすること:

    gh issue close <ISSUE_URL>
```

<!--5ab50942cf679243-->
MCP: 取得値: MCP のfresh PR merged/SHA と Issue state。形式: repo/number 固定 JSON。渡し先: 既存 update_issue.state=closed → fresh state 後読。不足時: MCP 必須不足は operation / field / page を示して停止。

`Closes #N` の自動クローズには 2 経路がある。(1) GitHub がクローズリンクを形成している場合（`closingIssuesReferences` が非空）の、デフォルトブランチへのマージ。(2) コミット / squash メッセージ上の closing keyword — API に現れなくても、そのコミットがデフォルトブランチへ入ると閉じる（手順 2 が守る経路）。本文に keyword があっても API が空なら (1) のリンクが無いので、この PR のマージでは閉じない可能性が高い。空 API を「閉じない」と読まないこと — (2) は残る。


<a id="github-file-input"></a>

## gh / GitHub MCP の raw-file 入力

`finish.sh precheck <PR> --github-input <絶対 index.json>` は、ホストが gh または GitHub MCP で取得して保存した応答を読む。省略時は従来の gh 呼び出し・待機・出力・終了コードを使う。index / raw-body の検査は共通 [github-input.sh](../../../scripts/lib/github-input.sh) が行う。新しい環境変数やネットワーククライアントは設けない。同じ文脈を委譲するときだけ明示した argv を渡す。

<!--6c23002b0eb01246-->
MCP: 取得値: MCP のPR/repo/checks/threads の実フィールド。形式: flat PR / GraphQL thread raw と phase/attempt/cursor の index JSON。渡し先: finish.sh precheck --github-input /absolute/index.json。欠損は推測で補わない。不足時: MCP 必須不足は operation / field / page を示して停止。

index は `{ "version": 1, "responses": [...] }`、各 response は `operation` / `scope` / `phase` / `body`（raw file の絶対パス、または index からの相対パス）を持つ。`--github-input` の index と body の絶対パスは `/` 始まりで、Windows の Git Bash ではホストのファイル編集機能や git が返すドライブ文字の形（`C:/…` / `C:\…`）も絶対パスとして受け付ける（他の OS では `C:/…` は相対パスとして扱い、index は `must be absolute` で止まり、body は index のディレクトリからの相対パスとして解決する）。position の `page` / `cursor` / `attempt` と、`last` / `http_status` は必要な取得だけに付ける。省略と null は別の position である。既定 format は JSON、`format:"text"` は text を扱う consumer だけに使う。一致する response はちょうど 1 件必要で、重複・不在・読めない file・壊れた JSON は rc 2。

対象 repository は、Git に設定された origin URL（transport の `insteadOf` 展開前）から決める。scp / ssh 形式は HTTPS URL へ揃え、ホスト・ポート・owner/repo を保持する。応答本文から対象を選ばず、別ホスト・別 PR の応答は受け入れない。body の raw bytes と `[]` / `false` / `null` を保持し、取得できなかった値を空配列や偽へ補わない。consumer の必須フィールドが無い回は、operation とフィールド・page / cursor を示して rc 2 で止まる。

repository raw の決定的写像は REST `full_name` → `nameWithOwner`、`html_url` → `url`。REST `url` は API URL なので使わない。実取得した両値を完全 origin の host・port・owner/repo と照合して保存する。normalized get_repo にこれらが無ければ raw GET 等で取り、取得不能は必須不足として停止する。

| 操作 | scope / phase / position | 必要な応答と不足時 |
| --- | --- | --- |
| `finish.precheck.pr` | repository / pr、`initial` と `after-threads`、`{}` | `number` / state / head・base / title / body / draft / fork / closing refs / commits / rollup / files / additions / deletions。最初と最後を別取得し、最後の head が欠落すれば rc 2、変われば既存の snapshot 検査で停止する |
| `finish.precheck.repo` | repository、`initial`、`{}` | `nameWithOwner` / `url` を Git の対象と照合する |
| `finish.precheck.checks-retry` | repository / pr、`checks-retry`、`attempt: 1..3` | 非空 checks を再検査する各回の raw rollup。file 入力では watch 成功を代用せず、未取得・解釈不能・3 回後も pending は rc 2 |
| `finish.precheck.threads` | repository / pr / first:100 / comments_first:100、`after-checks`、最初 `{}`、以降 `cursor` | GraphQL `author` / reviewThreads の nodes・各 comments・pageInfo。`hasNextPage=true` は非空 cursor と次の raw page が必須。`author:null`、コメントの path / line / originalLine の null は合法のまま判定する |
| `finish.cleanup.state` / `cleanup.pr` | repository / pr、`cleanup-state` / `cleanup-pr`、`{}` | state、cleanup では head / base と fork 等の同定。必須不足は rc 2。head OID だけが欠けた回は従来の削除保留・PARTIAL を維持する |
| `cleanup.merged-list` / `cleanup.open-list` | repository / state / limit（merged は設定値、既定1000。open は1000）、`cleanup-guards`、`{}` | 現行の削除ガードが使う bounded list。取得不能なら削除を保全し PARTIAL。空を推測しない |
| `link.membership` | repository / parent、`before-link` / `after-link-<child>`、`page:1..` | sub-issues の raw 配列。非終端は `last:false`、終端は `last:true` の空ページで完全性を示す。不足は rc 2 |
| `link.child-id` / `link.write` | repository / child、`before-link-child`、`{}` / repository / parent / child | child の数値 id。未反映なら正確な `sub_issue_id` と必要 read-back を `PLAN:` へ出し rc 2。完全な fresh membership に child が含まれるときだけ反映確認済みとする |

index の phase 名は取得時刻の証明にはならない。ホストは checks 後の全 thread pages と、その後の最終 PR head を実際に取得し、その記録を保持する。golden fixture は同じ Git / HEAD / gate での判定・コマンド bytes の一致を示すもので、MCP-only の live 完走や外部 write の証拠ではない。REST の件数だけで GraphQL の closing refs・commits・rollup を作らず、必要なツール能力が無ければその不足を明記して停止する。

Issue 本文・完了コメントや merge の writer は追加しない。外部 write には正確な操作・対象・引数の計画と、実行後の fresh read-back が必要で、未実施は rc 2 のままとする。`/close-issue` 本文の updatedAt 照合・差分検査・コメント同定と、生成済み merge メッセージ・head の固定は同じく守る。任意取得の失敗は既存の SKIP / 不明 / local 継続、必須取得の不足は停止、という区別を gh と GitHub MCP の両方へ適用する。

<!--f948f0f3bb089c7b-->
分類: 非操作: 入力 adapter と既存 write の責務を説明する。MCP write の計画と fresh read-back を省略する指示ではない


<a id="mcp-merge"></a>

## MCP merge

`command -v gh` が不成立で MCP を使う回も、Closes / Refs とも最初から空でない `MERGE_SUBJECT` と、空文字も可の `MERGE_BODY` 原文を保持し、`finish.sh precheck <PR> --subject "$MERGE_SUBJECT" --body "$MERGE_BODY" --github-input /absolute/index.json` に渡す（body は明示した空文字も可）。gh 経路は生成 block 原文実行のまま。MCP は生成 shell の parse/eval/unquote と件数・tool default/null からの再構成を禁止し、同じ最終 precheck の元値を既存 `merge_pull_request` に直接渡す。Closes の原文が未指定なら、最初の precheck より前に fresh PR title と番号から `<title> (#<PR>)` を件名、fresh PR body 全文を本文として一度だけ確定する。既に明示した原文は変更せず、Refs は2a/2bを通す意図した原文を両方指定する。body が null / 欠落なら空文字へ補わず、明示原文が無ければ停止する。以後は同じ原文を保持し、再取得した PR title/body や tool default/null から merge 引数を作り直さない。Refs の 2a/2b、snapshot、鮮度の停止条件は保持する。

<!--c33108ed26604e1a-->
MCP: 取得値: MCP の同じ最終 headRefOid と元 subject/body。形式: 既存 merge_pull_request の6引数。渡し先: TARGET_REPO/PR/head/squash/元subject/元body を直接渡し fresh merged/state 後読。shell parse 禁止。不足時: MCP 必須不足は operation / field / page を示して停止。

| 既存 tool 引数 | 渡す元値 |
| --- | --- |
| `repository_full_name` | 同じ `TARGET_REPO`。origin の完全 URL の host・port と MCP 接続先の一致を別途確認する。owner/repo だけでは host を表せず、確認不能なら停止 |
| `pr_number` | 同じ入力 PR 番号 |
| `expected_head_sha` | checks → 全 thread pages → 別取得した `after-threads` PR の最終 `headRefOid`。snapshot / freshness の `--remote-head` と同じ実値 |
| `merge_method` | 明示値 `squash` |
| `commit_title` | precheck へ渡した元の `MERGE_SUBJECT` |
| `commit_message` | precheck へ渡した元の `MERGE_BODY`（空文字・引用符・改行・末尾 LF を保持） |

実 write 前に対象と6引数を示し、既存の権限内で実行する。成功応答だけで完了にせず、fresh PR で `merged=true` と結果 SHA、各 Issue で Closes の CLOSED / Refs の OPEN 維持を後読する。`AUTO_CLOSE_UNRELIABLE` の警告・手動復旧・再後読を省略しない。能力 / 必須 raw 不足は operation / field / page を示して停止する。現在の connector の実在 schema 確認は live 完走の証拠ではない。

MCP merge には branch 削除引数が無い。merge 前に固定した canonical `scripts/lib/finish-delete-merged-head.sh` の実体と、consumer root / head branch / expected OID の3引数を使う。**merge 成功と fresh merged read-back 後だけ**、同一 repository の head と確認した対象へ helper を呼ぶ（helper 自身は fork / merge 状態を判定しない）。fork / 不明は保全し、別 OID は `preserved-different-oid`、不在は `already-missing`、一致だけ lease 削除とする。生成 shell の尾部を切り出したり一般 ref-delete API で lease を置換しない。helper / Git が使えなければ削除未実施を明示し、merge / delete / cleanup を別状態で報告する。

### raw と writer の受け渡し

PR は flat な gh JSON の `number,state,isDraft,headRefName,headRefOid,baseRefName,title,body,closingIssuesReferences,commits,statusCheckRollup,additions,deletions,files,isCrossRepository` が全必須。形は `commits:[{oid,messageHeadline,messageBody}]` / `files:[{path}]` / `closingIssuesReferences:[{url}]` である。normalized `get_pr_info` の counts や generic GraphQL envelope はこの形ではない。欠落を推測の空配列や本文から補わず、実取得でこの形を供給できなければ停止する。checks 非空時は実取得した `checks-retry` attempt、次に全 threads の cursor/page、最後に別取得の `after-threads` PR を同じ index に保存する。同じ raw の phase 改名は fresh 取得にならない。

<!--88ead1f007110401-->
MCP: 取得値: MCP のPR/repo/checks/threads の実フィールド。形式: flat PR / GraphQL thread raw と phase/attempt/cursor の index JSON。渡し先: finish.sh precheck --github-input /absolute/index.json。欠損は推測で補わない。不足時: MCP 必須不足は operation / field / page を示して停止。

Issue は同じ repository / number の全文 `body` と `updatedAt`（REST の `updated_at` に対応）を取得して原本保存し、更新直前の fresh 値と照合する。normalized snapshot に時刻が無ければ raw GET 等で取得し、できなければ停止する。許可差分判定後の本文ファイル原文を MCP `update_issue` の body へ渡し、他フィールドは指定しない。全 page のコメントから `<!-- close-issue-report:PR-N -->` を同定し、既存 ID があれば update、無ければ create に報告ファイル原文を渡す。重複 / 不完全一覧は停止し、各 write 後の fresh GET で body 原文一致と対象を確認する。
