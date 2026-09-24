# マージ直前のゲート — checks の分岐とゲート実測鮮度（`finish.sh precheck` の出力の読み方）

`/close-issue` 手順 7 の詳細。判定そのものは `scripts/finish.sh precheck` が行い（実体は `scripts/check-merge-freshness.sh` と `gh pr checks`）、本文は `FRESH_STATUS` / `RERUN_FULL_GATE` で分岐するだけを持つ。`FRESH_STATUS=2`（判定不能）が出た回、または分岐の根拠を確かめたい回に読む。

### 2. closing keyword 抵触検査の分岐（Refs 運用の Issue がある場合）

`gh pr view --json closingIssuesReferences` は PR 本文しか見ない（コミットメッセージは見ない）ため、`Refs #N` を本文に書いた PR でもコミット件名の `fix: #N` でマージ時に Issue が閉じる。検出されるのは **closing keyword と Issue 参照が隣接している場合のみ**（「どこかに keyword、どこかに番号」で判定すると、ほぼ全ての PR で発火してゲートが無視されるようになる）。2a と 2b の両方が要るのは、コミット件名・本文は**書き換えられない**からで、2a だけを条件にするとコミット由来の抵触は改題では解消できず永久に赤になる。

#### 2a. 供給源のスキャン

**抵触があった場合、既定のマージ経路（`--subject` / `--body` を省略する形）は安全ではない。** origin ごとの対応:

| origin | 対応 |
| --- | --- |
| `title` のみ（`KEYWORD_GATE=conflict-title`） | `gh pr edit "${PR_NUMBER}" --title "<Issue 参照を含まない件名>"` で改題し、**手順 1 から再実行する**（script は rc 1 で止まる） |
| `commit:<sha>` / `commit-body:<sha>` を含む（`conflict-commit`） | コミットは書き換えられない。2a では止めず、マージ時に `--subject` / `--body` を明示して 2b の結果をマージの条件にする。`KEYWORD_SUGGEST` は改題案または本文の書き換え案 |

**2a の抵触で無条件に停止しない**のはこのためで、script は `NON_TITLE_CONFLICTS`（title 以外の抵触数）で分岐する。`KEYWORD_INSPECTED` は実際に検査した行数で、完了報告へ転記する（上流の commits が切り詰められていれば script が検査不成立で止まる）。

#### 2b. 実際に渡す squash メッセージの検査（マージの条件）

`--subject` と `--body` を両方明示した squash merge のメッセージは**その 2 つだけで決まる**（コミットメッセージは畳み込まれない。実測で確認済み）。片方でも省略すると、リポジトリ設定（`squash_merge_commit_title` / `squash_merge_commit_message`）に応じて PR タイトルやコミットメッセージが供給源になる。だから Refs 運用では抵触の有無に関わらず両方明示が既定で、`--subject` / `--body` を渡さなければ script は `MERGE_MESSAGE_GATE=required` で止まる。検査を通った文字列は script が `MERGE_COMMAND` へ引用して載せる — **文字列を打ち直さずそのまま手順 7 へ持ち越す**（`--subject` のコピペこそが実際の再発経路。人が打ち直した時点で、そこが検査とマージの間の継ぎ目になり 2b は何も保証しなくなる）。

#### CI checks の有無による分岐（待つか、ローカルゲートを根拠にするか）

script は対象 PR に checks が登録されているかを先に確認します。**既定は PR トリガーの CI がある形**で、checks の完了と成功がマージの根拠になります。PR トリガーの CI を持たないリポジトリでは `gh pr checks --watch` が `no checks reported` を返して即終了するため、これを CI 通過と早合点してはいけません。`statusCheckRollup` の登録を待つ自作の待機ループは、checks が存在しない repo では永遠に終わりません。

- `statusCheckRollup` が**非空**の場合（PR トリガーの CI がある既定の形）は、全 checks の完了と成功を確認してからマージへ進みます。`--watch --fail-fast` で完了を待ち、失敗（rc 非 0）ならそこで止まります（`CHECKS=failed`。マージへ進まない）。**checks の成功がマージの根拠で、ローカルの全件ゲートはリリース前（タグ / Release の作成前）と契約面の変更時に限ります** — 通常の PR のローカル検証は部分ゲート（プロジェクトが変更ベースの選択を持つならその実行）で足ります
- `statusCheckRollup` が**空配列**（`null` も同じ扱い）の場合（PR トリガーの CI を持たないリポジトリ）、checks の完了を待たずに次へ進み、`CHECKS_REPORT` の文言（「この PR に登録された checks は無い。マージ可否はローカル全件ゲート + 鮮度照合で判定する」）をそのまま手順 8 の完了報告へ明記します。マージ可否はローカル全件ゲートの実行結果と鮮度照合だけを根拠にします
- `gh pr view` 自体が失敗した場合は、分岐を決められない＝検査が成立していないため停止します（取得失敗を「checks 無し」へ倒さない）
- `gh pr checks` の非 0 は check の失敗だけでなく通信・認証エラーでも返ります。script は API への到達（`gh api rate_limit`）を確かめ直し、届かなければ `CHECKS=unavailable` + rc 2（gh 不通を名指し。check の失敗として扱わない）、届けば `CHECKS=failed` + rc 1 です
- checks の待機を挟むので、script は照合直前に PR を読み直し、判定に使った全フィールド（先端・本文・タイトル・コミット・`closingIssuesReferences`・ファイル・checks の有無ほか）を初回と比べます。差があれば `PR_SNAPSHOT=changed` と `PR_SNAPSHOT_DIFF`（差のあるフィールド名）を出して rc 1 で止まるので、`finish.sh precheck` を**最初から**再実行します（途中の出力を流用しない — 待機中に足された `Refs` や改題は初回の抵触検査を通っていない）

#### ゲート実測鮮度そのものの照合

ローカルで回した検証スイートの結果は、**その時点の特定コミットに対する実測**です。実測とマージのあいだにリモートが進んでいると、squash merge は**未実測のコミットまで畳み込む**ため、ゲートを回した意味が消えます（実測: cloud セッションが作成した PR をローカルの worktree で引き取って作業しているあいだに、同じセッションが同じブランチへ別方向の修正を push していた）。

| 検査 | 守る窓 |
| --- | --- |
| `--match-head-commit` | **AC 照合の後**に追加 push された内容がマージへ混入すること |
| 本手順の鮮度照合 | **ゲート実測の後**にリモートが先行していたこと。`headRefOid` はそのドリフトの後に読まれるので、`--match-head-commit` からは見えない |

比較の材料には **API の値（`headRefOid`）を照合直前に読み直して使う**。`git fetch` + `git rev-parse origin/<branch>` を比較に使ってはいけない — remote-tracking ref は前回 fetch 時点のスナップショットで、fetch を忘れた回に「古い先端 == 古い実測対象」で一致してしまう。`--fetch` は関係の分類（祖先か / 未 push か / 分岐か）にだけ使う。

実測対象は自己申告ではなく**記録**から取ります。`scripts/record-gate-head.sh` がゲートの通過時に HEAD・作業ツリーの汚れ・モードを書き、`tests/run-all.sh` は既定一覧の実行でも明示引数の実行でもこれを呼びます。ただし**明示引数の実行は `STATUS=partial`（部分実行）として記録されます** — 名指しした suite しか回っていない記録は、リモート先端と一致していても全件緑へは昇格せず、判定不能（exit 2）として報告されます。**例外: 同じコミットに全件緑（`STATUS=pass`）の記録が既にあるときは、部分実行で上書きしません**（`pass@X` は `partial@X` の上位互換の証拠。全件ゲートの後に名指し 1 本を回す並びは一致のまま）。赤い実行（`STATUS=fail`）は同じコミットでも前回の緑を無効化します。

終了コード（`FRESH_STATUS`。個別の原因ではなく終了コードで分岐する）:

- **0 = 一致（無出力）**: `FRESH_REPORT`（`--print-record` のゲート名・モード・結果）を報告へ載せる。高速モードの記録を「全件実行で通した」と読ませない（モードは合否には使わない）
- **1 = 不一致（マージを止める）**: `RELATION` で次の一手が変わる — `ancestor`（実測後にリモートが先行）→ 取り込んで再実測 / `unpushed`（未 push のコミットを測っている）→ push して再実測 / `divergent`（同一ブランチの実測対象と先端が分岐）→ **force-push で押し切らず**相手のコミットの上に自分の変更を積んでから再実測 / `unknown` → fetch の成否を確認し `ACTION` に従う
- **2 = 判定不能（止めないが報告する）**: 原因は増えうる（記録が無い / 別ブランチの記録 / 汚れた木で測った / 直近のゲートが赤い / 記録が部分実行である / 記録の版や内容を解釈できない / 実測対象のコミットが手元に無い）。**2 で止めないのは意図的**です。記録の仕組みを持たないプロジェクトでは判定不能が常態で、そこで無条件にマージを止めると検査ごと迂回されます。**この窓は静かに外れると squash merge に畳み込まれるので、ノイズより見逃しのコストが高い** — だから「黙って緑を返さない」ことを最低線として守り、判定不能は手順 8 の完了報告に必ず載せる（`REASON` と `ACTION` を**両方**。部分実行なら REASON が「何を検証したのか」を名指しし、ACTION がそれを指して次の一手を述べる）
- **3 = 検査不成立（停止する）**

記録の `BRANCH` が現在の名前付きブランチと異なる場合は、コミット照合より前に **`UNDETERMINED`（exit 2）** を返す（別ブランチの古い記録は同一ブランチへの追加 push の証拠ではない。SHA が同一でも一致へ昇格させない）。`BRANCH` が欠落・空・`HEAD`・`(unknown)`、または現在が detached HEAD なら、別ブランチと断定せず従来のコミット照合を行う。

鮮度照合が判定不能（`FRESH_STATUS=2`）で、かつ `FRESH_REASON` が「汚れた木で測った / 記録が無い / 記録が部分実行である」のいずれかなら（`RERUN_FULL_GATE=yes`）、clean な作業ツリーで全件ゲートを再実行してから改めて照合します（記録の仕組みを持たないプロジェクトではこの限りではなく、2 でマージを止めない既存規定も変わりません）。**ただし `FRESH_REASON` が「記録が部分実行である」で、かつ checks が非空で全件成功した回に限り、リリース前と契約面の変更時を除き再実行しません**（`RERUN_FULL_GATE=no`） — PR の checks がリモート先端（base へのマージ結果）を実測しており、部分ゲートの記録で判定不能になるのは想定どおりだからです。「汚れた木で測った / 記録が無い」は checks が成功していても従来どおり全件ゲートを再実行します（checks がローカルの検証スイートを回しているとは限らないため）。それ以外の理由は `RERUN_FULL_GATE=see-action`（`FRESH_ACTION` に従う）。

未達 AC の修正ループで fix commit を push した場合、修正前の記録とは不一致になる。**ゲートを回し直してから**マージへ進む。

#### merge コマンドの生成

script が `MERGE_COMMAND_BEGIN` 〜 `MERGE_COMMAND_END` に出す。渡す先端は直前に照合した `REMOTE_HEAD`、件名・本文は 2b が検査した文字列を単引用で包んだもの（`printf '%q'` は非 UTF-8 ロケールで日本語を壊すので使わない）。`--delete-branch` は base / head ブランチが別の worktree に保持されていないときだけ付き、保持されている回は付けずに、照合した先端 OID を lease に載せたリモートブランチ削除を `gh pr merge … && git push origin --force-with-lease=refs/heads/<head>:<OID> :refs/heads/<head>` の 1 コマンドで添える（`DELETE_BRANCH_MODE=separate-push`・`BASE_HELD_BY` / `HEAD_HELD_BY`・`HEAD_DELETE=lease`。fork の PR は `skipped-fork` で削除を生成しない）。別行にしないのは、merge が失敗した回（checks 未完了・先端不一致・競合）に削除だけが走ると未マージの PR の head が消えて PR が閉じるため。`gh pr merge --delete-branch` はマージ成功後にローカルで base へ切り替えようとするため、base が他 worktree に保持されていると PR はマージ済みなのにリモートブランチ削除まで到達せず失敗し、エラーは worktree の話しかしない。

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

`Closes #N` の自動クローズには 2 経路がある。(1) GitHub がクローズリンクを形成している場合（`closingIssuesReferences` が非空）の、デフォルトブランチへのマージ。(2) コミット / squash メッセージ上の closing keyword — API に現れなくても、そのコミットがデフォルトブランチへ入ると閉じる（手順 2 が守る経路）。本文に keyword があっても API が空なら (1) のリンクが無いので、この PR のマージでは閉じない可能性が高い。空 API を「閉じない」と読まないこと — (2) は残る。
