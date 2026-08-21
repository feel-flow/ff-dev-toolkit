---
name: close-issue
description: マージ直前に PR が閉じる Issue の受け入れ条件（AC）を照合し、チェックボックス更新 + 完了報告コメントを投稿する（AC 照合ゲート）
---

# /close-issue — Issue クローズ前の AC 照合ゲート

`gh pr ready` の後・`gh pr merge` の**前**に実行し、PR が閉じる Issue の受け入れ条件（AC）を照合します。Issue がまだ open のうちに検証記録を残すことで、「AC 未検証のまま無言で自動クローズされる」問題を防ぎます。

対象は 2 種類あります:

| 運用          | PR 本文の参照   | マージ後の Issue      | このコマンドの役割                                            |
| ------------- | --------------- | --------------------- | ------------------------------------------------------------- |
| **Closes 運用** | `Closes #N`     | 閉じてよい            | AC 照合 → チェックボックス更新 → 完了報告                     |
| **Refs 運用**   | `Refs #N` のみ  | **open のまま維持する** | 上記に加え、squash メッセージが Issue を閉じないことを検査（手順 2） |

Refs 運用は、post-merge 検証（staging 実機確認・外部 ops など）が AC に残る Issue で使います。

起票時の `/create-issue`（GWT + DoD 起票）と対になり、Issue のライフサイクル両端で仕様が検証される構造を作ります。

## 前提

- git リポジトリで作業中であること
- 対象 PR が open であること（Draft のままでも実行はエラーにせず警告のみとするが、レビュー対応完了後・マージ直前の実行を想定）
- 実装変更がコミット済み + push 済みであること（AC 照合は push 済みの diff を対象とする）
- **実行タイミング**: レビュー対応完了後（Draft PR 運用時は `gh pr ready` の後）・`gh pr merge --squash` の前
- 同梱スクリプトを実行する前に `FF_DEV_TOOLKIT_ROOT` を解決する。Claude Code では `${CLAUDE_PLUGIN_ROOT}` を使い、Codex など他ホストでは読み込んだこの `SKILL.md` の絶対パスから `../..` を解決する（未定義のまま実行するとルート直下の存在しないパスを叩き、終了コード 127 になる）

## 引数

- `$ARGUMENTS` — 対象の PR 番号（省略時は現在のブランチに紐づく PR を自動検出）

## 手順

### 1. 対象 Issue の自動検出

PR の Issue 参照から、対象 Issue を取得します:

```bash
# PR番号指定時（省略時は番号なしで実行し、現在のブランチの PR を対象にする）
gh pr view $ARGUMENTS --json number,state,isDraft,headRefName,headRefOid,title,body,closingIssuesReferences,commits
```

- 以降、検出した PR 番号を `$PR_NUMBER`、各 Issue の URL を `$ISSUE_URL` と表記する
- **ブランチガード（必須）**: `git branch --show-current` が `headRefName` と一致しない場合は、未達 AC の修正ループで**誤ったブランチに commit する事故を防ぐため**、`gh pr checkout $PR_NUMBER` で PR のブランチに切り替えてから続行する（切り替えできない場合は停止して報告）
- `closingIssuesReferences` の各要素からは **Issue の URL を保持**し、以降の `gh issue view / edit / comment` には番号ではなく `$ISSUE_URL` を渡す（`Fixes owner/repo#100` 形式のクロスリポジトリ参照で、同番号の別 Issue を誤更新しないため）
- 対象 Issue を次の 2 群に分類する:
  - **Closes 運用の Issue** = `closingIssuesReferences` に現れる Issue（マージで閉じてよい）
  - **Refs 運用の Issue** = PR 本文の `Refs` 参照のうち、`closingIssuesReferences` に**含まれない**もの（open のまま維持する）
- **`closingIssuesReferences` が空でも、`Refs` 参照があれば終了しない**。この API が見るのは **PR 本文だけ**で、コミットメッセージは見ない（コミット件名に `fix: #N` があっても空配列を返し、それでもマージで Issue は閉じる — 実測済み）。空を理由に打ち切ると、いちばん守りたい Refs 運用の PR が無検査で通る

`Refs` 参照の抽出は**機械的に行う**。目視で拾うと、拾い漏れがそのまま「検査対象なしで緑」になる:

```bash
PR_NUMBER="${PR_NUMBER:?PR 番号を先に設定すること}"

PR_BODY="$(gh pr view "${PR_NUMBER}" --json body --jq '.body')" \
  || { echo "❌ PR 本文の取得に失敗（検査は成立していない）" >&2; exit 2; }

# 抽出に grep を使わないのは、終了コードの意味論に依存させないため。grep は
# 「不一致=1 / エラー=2」だが、grep が別実装へ差し替えられている環境ではエラーでも
# 1 を返すことがあり、`rc<=1 なら正常` という判定が **fail-open へ反転する**（実測）。
# awk は不一致でも 0 を返すので、rc!=0 は本物の失敗だけを意味する。
# pipefail をサブシェルで有効にするのは、既定では最終段（sort）の終了コードしか
# 見えず、awk の異常終了が「参照 0 件」に化けて検査全体を素通りさせるため。
set +e
REFS_RAW="$(set -o pipefail
  printf '%s\n' "${PR_BODY}" | awk '
    {
      line = $0
      while (match(line, /(^|[^A-Za-z])[Rr][Ee][Ff][Ss]?[ \t:]*([A-Za-z0-9._-]+\/[A-Za-z0-9._-]+)?#[0-9]+/)) {
        token = substr(line, RSTART, RLENGTH)
        sub(/^([^A-Za-z])?[Rr][Ee][Ff][Ss]?[ \t:]*/, "", token)
        print token
        line = substr(line, RSTART + RLENGTH)
      }
    }' | sort -u)"
EXTRACT_RC=$?
set -e
[[ "${EXTRACT_RC}" -eq 0 ]] || { echo "❌ Refs 参照の抽出に失敗（検査は成立していない）" >&2; exit 2; }
```

- **拾う綴りは `Ref` / `Refs` のみ**（大文字小文字は問わない。`Refs:` のようにコロンが続く形も可）。`関連 #N` や裸の `#N` は拾わないので、**Refs 運用では必ずこの綴りを使う**。別の書き方をすると手順 2 の検査が起動せず、ゲートが空振りする
- 両群とも空の場合: 「参照から検出できる対象 Issue はありません」と報告して終了する（エラーにしない）。**「この PR は Issue を閉じません」とは報告しない** — 参照が無いことは閉じないことを意味しない（件名経由のクローズはこの検出の範囲外）
- **複数 Issue** が含まれる場合: 各 Issue に対して手順 3〜6 を独立して繰り返す

### 2. closing keyword 抵触検査（Refs 運用の Issue がある場合）

GitHub の closing keyword は PR 本文だけでなく **squash commit のメッセージ**も走査します。`fix: #123 …` という Conventional Commits の自然な件名がそのまま closing keyword（`fix #123`）として解釈されるため、`Refs #123` を本文に書いた PR でも Issue が閉じます。検出する closing keyword は次の 9 語で、`fix:` のように**コロンが挟まる形も一致します**:

`close` / `closes` / `closed` / `fix` / `fixes` / `fixed` / `resolve` / `resolves` / `resolved`

検出されるのは **closing keyword と Issue 参照が隣接している場合のみ**です。`chore: 検査を追加する。fixes は 9 語ある（#123 参照）` のように keyword と番号が同居しているだけのものは抵触ではありません（「どこかに keyword、どこかに番号」で判定すると、ほぼ全ての PR で発火してゲートが無視されるようになる）。

検査は 2 段階で行います:

| | 検査対象 | 位置づけ |
| --- | --- | --- |
| **2a** | PR タイトル + 全コミットの件名と本文 | **供給源のスキャン**。何が危険かを洗い出す |
| **2b** | 実際に `gh pr merge` へ渡す `--subject` と `--body` | **権威ある検査**。これが通ることがマージの条件 |

2b が権威なのは、`--subject` と `--body` を両方明示した squash merge のメッセージが**その 2 つだけで決まる**ためです（コミットメッセージは畳み込まれない。実測で確認済み）。逆に片方でも省略すると、リポジトリ設定（`squash_merge_commit_title` / `squash_merge_commit_message`）に応じて PR タイトルやコミットメッセージが供給源になります。

2a と 2b の両方が要るのは、コミット件名・本文は**書き換えられない**からです。2a だけを条件にすると、コミット由来の抵触は改題では解消できず、ゲートが永久に赤のままになります。

#### 2a. 供給源のスキャン

```bash
PR_NUMBER="${PR_NUMBER:?PR 番号を先に設定すること}"
# 手順 1 で抽出した Refs 参照（`#N` または `owner/repo#N`）を、参照された形のまま入れる
REFS_ISSUE="${REFS_ISSUE:?Refs 運用の Issue 参照を先に設定すること}"
GUARD="${FF_DEV_TOOLKIT_ROOT}/scripts/check-closing-keywords.sh"

TARGET_REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
[[ -n "${TARGET_REPO}" ]] \
  || { echo "❌ リポジトリ名を解決できません（検査は成立していない）" >&2; exit 2; }

# パイプで直結すると上流の失敗が最終段の終了コードに隠れる（jq は部分出力して
# から死ぬので、途中まで検査して緑、が成立する）。いったん実体化して確定させる。
SURFACE="$(mktemp)"
gh pr view "${PR_NUMBER}" --json title,commits --jq '
  ("title\t" + .title),
  (.commits[] | ("commit:" + .oid[0:7] + "\t" + .messageHeadline)),
  (.commits[] | select(.messageBody != "")
    | "commit-body:" + .oid[0:7] + "\t" + (.messageBody | gsub("\n"; " ")))
' > "${SURFACE}" \
  || { echo "❌ 検査面の取得に失敗（検査は成立していない）" >&2; exit 2; }

# 取得したコミット数がブランチの実コミット数と一致することを確認する
# （API 側で切り詰められると、落ちた側の `fix: #N` は検査されないまま緑になる）
EXPECTED_COMMITS="$(git rev-list --count "origin/${BASE_BRANCH:-develop}..HEAD")"
ACTUAL_COMMITS="$(gh pr view "${PR_NUMBER}" --json commits --jq '.commits | length')"
[[ "${EXPECTED_COMMITS}" -eq "${ACTUAL_COMMITS}" ]] \
  || { echo "❌ コミット取得が切り詰められています（期待 ${EXPECTED_COMMITS} / 取得 ${ACTUAL_COMMITS}）" >&2; exit 2; }

# --refs-issue は Refs 運用の Issue の数だけ繰り返す。Closes 対象が無い PR では
# --closes-issue の行ごと省略する（値なしで置くと使い方の誤りで停止する）。
# クロスリポジトリの Issue は `owner/repo#N` の形のまま渡すこと。
GATE_OUT="$(mktemp)"
set +e
bash "${GUARD}" --repo "${TARGET_REPO}" --refs-issue "${REFS_ISSUE}" < "${SURFACE}" > "${GATE_OUT}"
GATE_STATUS=$?
set -e
rm -f "${SURFACE}"
cat "${GATE_OUT}"

# 抵触の origin で対応が分かれる。title は改題で消せるが、コミットの件名・本文は
# 書き換えられないので、2b（--subject / --body の明示）だけが解消手段になる。
NON_TITLE_CONFLICTS="$(awk -F'\t' '$1 == "CONFLICT" && $2 != "title" { count++ } END { print count + 0 }' "${GATE_OUT}")"
rm -f "${GATE_OUT}"

case "${GATE_STATUS}" in
  0) echo "GATE_OK: 供給源に抵触なし。2b へ進む" ;;
  1)
    if [[ "${NON_TITLE_CONFLICTS}" -eq 0 ]]; then
      echo "GATE_CONFLICT(title): 改題してから 2a を再実行する" >&2
      exit 1
    fi
    echo "GATE_CONFLICT(commit): 書き換えられない供給源に抵触がある。--subject と --body を明示し、2b の結果をマージの条件にする" >&2
    ;;
  *) echo "GATE_ERROR(status=${GATE_STATUS}): 検査が成立していない。抵触なしとして扱わず停止する" >&2; exit 2 ;;
esac
```

- 終了コード **0 = 抵触なし**、**1 = 抵触あり**、**2 = 使い方の誤り / 検査が成立しない**。**`0` と `1` 以外はすべて停止側へ倒す**（コマンド不在の 127 なども検査不成立）
- stdout の `INSPECTED` 行が実際に検査した行数。**この数字を完了報告に転記する**（自分で数えない。上流が切り詰められた場合、`INSPECTED` は期待より小さくなる）
- `--closes-issue` は**矛盾検査専用**で、検出結果は変えない（同じ Issue を `--refs-issue` と両方に渡した場合に停止させるためのもの）
- **抵触があった場合、既定のマージ経路（`--subject` / `--body` を省略する形）は安全ではない**。報告には抵触箇所（`CONFLICT` 行の origin と該当テキスト）と、`SUGGEST` 行の機械的な修正案を含める。origin ごとの対応:

| origin | 対応 |
| --- | --- |
| `title` のみ | `gh pr edit "${PR_NUMBER}" --title "<Issue 参照を含まない件名>"` で改題し、**2a から再実行する**（ここで停止する） |
| `commit:<sha>` を含む | コミット件名は書き換えられない。2a では止めず、マージ時に `--subject` を明示して件名を差し替え、**2b の結果をマージの条件にする** |
| `commit-body:<sha>` を含む | コミット本文も書き換えられない。同じく `--body` を明示して 2b で検証する。`SUGGEST` 行はこの場合「本文の書き換え案」であって改題案ではない |

**2a の抵触で無条件に停止しない**のはこのためです。コミット由来の抵触は改題では消えないので、そこで止めると解消手段が存在しないまま永久に赤になります。止めるのは「改題で消せる抵触（title のみ）」と「検査が成立していない場合」で、コミット由来の抵触は 2b へ委ねます。

#### 2b. 実際に渡す squash メッセージの検査（マージの条件）

2a で `commit:` / `commit-body:` 由来の抵触が 1 件でもあった場合、`--subject` と `--body` の**両方**を明示してマージします。抵触が無い場合でも、`Refs` 運用では両方明示するのが既定です（リポジトリ設定に依存しなくなるため）。

```bash
MERGE_SUBJECT="fix: 誤クローズを防ぐ検査を追加する (#${PR_NUMBER})"
MERGE_BODY="Refs #${REFS_ISSUE}

post-merge 検証が残るため Issue は open のまま維持する。"

set +e
printf 'merge-subject\t%s\nmerge-body\t%s\n' "${MERGE_SUBJECT}" "${MERGE_BODY}" \
  | bash "${GUARD}" --repo "${TARGET_REPO}" --refs-issue "${REFS_ISSUE}"
FINAL_STATUS=$?
set -e
[[ "${FINAL_STATUS}" -eq 0 ]] \
  || { echo "❌ 実際に渡す squash メッセージが Issue を閉じます（status=${FINAL_STATUS}）" >&2; exit 1; }
```

検査を通ったら、**merge コマンドを検査済みの変数から組み立てる**。文字列を打ち直すと、そこが検査とマージの間の継ぎ目になる（`--subject` のコピペこそが実際の再発経路だった）:

```bash
# 検査した変数をそのまま展開する。%q はシェルで安全な引用形へ変換する
printf 'gh pr merge %s --squash --match-head-commit %s \\\n  --subject %q \\\n  --body %q\n' \
  "${PR_NUMBER}" "${HEAD_SHA}" "${MERGE_SUBJECT}" "${MERGE_BODY}"
```

- **この出力をそのまま手順 7 の報告へ貼る**。報告に載る merge コマンドは、2b が検査した文字列から機械的に導出されたものでなければならない。人手で書き写した時点で、2b は何も保証しなくなる
- `%q` の出力はエスケープが入って読みにくいが、**シェルが解釈した結果は検査した文字列と同一**（多行の本文は `$'\n'` として現れる）。読みやすさのために引用を書き換えないこと — 書き換えた時点で「検査した文字列」ではなくなる
- Refs 運用の Issue が 0 件（従来どおりの `Closes` 運用）の場合、2a・2b とも実行しない。この経路の振る舞いは従来と変わらない

### 3. AC 照合

Issue 本文と PR の変更内容を突き合わせます:

```bash
gh issue view $ISSUE_URL --json title,body
gh pr diff $PR_NUMBER
# 判定根拠の補強: PR body の検証記録・CI/レビュー状態も取得する
gh pr view $PR_NUMBER --json body,statusCheckRollup,reviewDecision
```

- 「テストがパスすること」系の DoD は diff だけで達成と判定せず、`statusCheckRollup` またはプロジェクトのテストコマンド（例: `npm run quality:local`）の**実行結果**を根拠にする
- **根拠が取得できない項目は「未達」扱い**にする（証拠なしで達成と判定しない）

Issue 本文の「受け入れ条件（AC）」（振る舞い Given-When-Then + Definition of Done）の各項目について、PR の diff・テスト結果・PR body の検証記録を根拠に判定します:

| 判定                 | 意味                                                                                       |
| -------------------- | ------------------------------------------------------------------------------------------ |
| **達成**             | AC を満たす変更・検証結果が PR に含まれている                                              |
| **未達**             | AC を満たす変更が確認できない                                                              |
| **対象外**           | 実装過程で仕様が変わった等、この PR では扱わないことになった項目                            |
| **post-merge 検証待ち** | **Refs 運用の Issue に限る**。マージ後にしか実測できない AC（staging 実機確認・外部 ops 等） |

**「未達」と「AC が実装より古い」を区別する**: AC と実装が食い違っている場合、実装が不足している（未達）のか、レビュー対応の fix commit で実装が AC の前提を超えた／変えたのに Issue 側の AC が旧値のまま残っている（AC が古い）のかを先に判定する。後者は実装の手戻りではなく、Issue 本文の該当 AC を実装に合わせて更新（変わった理由を 1 行添える）してから再照合すれば解消する。この経路は**実装が AC の意図（守りたい振る舞い）を満たしたまま、前提値・具体値が置き換わった／強化された場合に限る** — 実装が AC の意図を満たしていないなら未達（手順 4 へ）、AC の意図自体を変える必要があるなら手順 4 の停止条件（仕様変更が必要）としてユーザーに判断を求める。AC を弱める方向の書き換えには使わない。更新は手順 5 と同じ競合確認手順（body / updatedAt の取得 → 該当 AC 行のみ置換 → diff 確認 → 送信直前の updatedAt 再突合）で行い、チェックボックスの状態は保全する。本来はレビュー対応の時点で AC を同時更新しておくのが正（git-workflow の「レビュー対応の原則」）で、ここで検出されるのはその更新漏れである。

**AC が記載されていない Issue** の場合: 照合をスキップして手順 6 に進み、実装サマリコメントのみ投稿する（コメント内に「AC 記載なし」を明記）。

**post-merge 検証待ちの扱い**（Refs 運用の Issue のみ）:

- チェックボックスは**チェックしない**。Issue は open のまま残し、マージ後に実測してから閉じる
- マージは止めない（原理的にマージ前に達成できない AC なので、未達扱いにすると Refs 運用そのものが成立しない）
- 完了報告に「マージ後に何をどう実測すれば閉じられるか」を項目ごとに書く
- Closes 運用の Issue にはこの判定を使わない。post-merge 検証が残るなら、そもそも `Refs` 運用へ切り替える（PR 本文の `Closes` を `Refs` にし、タイトル・コミット件名から `#N` を外す）

### 4. 未達 AC の解消（自動修正ループ）

未達の AC がある場合、マージを進めずにその場で解消します:

1. 未達 AC を満たす実装・テストを追加する
2. fix commit を作成して push する
3. **手順 2 に戻る**（コミットが増えると検査対象の件名も増えるため、closing keyword 抵触検査から再実行する）。全 AC が達成 / 対象外 / post-merge 検証待ちになるまで繰り返す

**停止してユーザーに確認するのは次の場合のみ**:

- AC の達成に**仕様変更が必要**で、実装では解消できない（Issue の要件自体を変える判断が必要）

**未達 AC が大きい場合も先送りしない**: 現 Issue の AC はスコープ外発見ではない。解消が PR の想定規模を大きく超えても、自動で別 Issue へ移して「対象外」にせず、マージを停止してユーザーに仕様変更の判断を求める。ユーザーが現 Issue のスコープ変更を明示し、Issue 本文の AC がその決定に合わせて更新された場合だけ「対象外」として再照合する。実装中に見つかった独立した発見は AC と分離し、[スコープ外発見の三分岐](../docs-template/05-operations/deployment/workflow-principles.md)へ渡す。

### 5. Issue 本文のチェックボックス更新

達成した AC のチェックボックスをチェック済みに更新します。**必ず Markdown タスクリスト記法の checked state（`- [ ]` → `- [x]`）で書き換えること**（`☑` などの文字を挿入すると GitHub 上ではタスクとして認識されない）:

```bash
# 1) 最新 body と updatedAt を取得（Issue 番号を含む一時ファイル名にする）
gh issue view $ISSUE_URL --json body,updatedAt
#    body を /tmp/issue-body-"${ISSUE_NUMBER}".md に保存し、updatedAt を控えておく

# 2) 達成と判定した AC の行だけを "- [ ]" → "- [x]" に書き換える
#    （利用中のホストが提供するファイル編集機能で該当行を個別に置換する。sed 等での一括置換は
#      未達・対象外の項目まで完了扱いにしてしまうため禁止）

# 3) 書き換え結果を diff し、「チェックボックス以外の変更がない」ことを確認

# 4) 送信直前に updatedAt を再取得し、1) から変化していないことを確認してから送信
#    （変化していたら 1) からやり直す。他者の編集を上書きしないため）
gh issue edit "$ISSUE_URL" --body-file "/tmp/issue-body-${ISSUE_NUMBER}.md"
```

- 更新するのは**チェックボックスのみ**。Issue 本文の要件テキスト自体は書き換えない（履歴の追跡性維持）。例外は、手順 3 の「AC が実装より古い」判定で行う AC 更新と、手順 4 でユーザーがスコープ変更を明示した場合の AC 更新の 2 経路のみ。どちらも変わった理由を 1 行添え、再照合してからこの手順に進む
- 未達のまま「対象外」とした項目、および「post-merge 検証待ち」の項目はチェックせず、完了報告コメント側で理由を説明する

### 6. 完了報告コメントの投稿

Issue に完了報告コメントを投稿します（**日本語**）。Markdown 表やバッククォートを含むため、`--body` の直接指定ではなく **`--body-file`** を使います:

```bash
# 再実行時の重複投稿を防ぐ: 既存コメントにマーカーがあれば新規投稿せず、そのコメントを更新する
gh issue comment "$ISSUE_URL" --body-file "/tmp/close-issue-report-${ISSUE_NUMBER}.md"
```

- コメント冒頭に識別マーカー `<!-- close-issue-report:PR-<PR番号> -->` を含める。再実行時はこのマーカーを持つ既存コメントを検索し、あれば `gh api` で該当コメントを更新（または投稿をスキップ）して重複を防ぐ

コメントに含める内容:

```markdown
## 完了報告（PR #<PR番号>）

### 何が問題で、どう解決したか

[1〜3 段落で: 問題の背景 → 採った解決アプローチ → 結果]

### AC 検証結果

| AC                     | 判定    | 根拠                                 |
| ---------------------- | ------- | ------------------------------------ |
| Given ... When... Then | ✅ 達成 | [該当ファイル・テスト・検証コマンド] |
| DoD: ...               | ✅ 達成 | [根拠]                               |
| ...                    | ➖ 対象外 | [理由と別 Issue 番号（あれば）]      |
| DoD: staging で ...    | ⏳ post-merge 検証待ち | [マージ後に実測する手順と、閉じてよい条件] |

### 参照

- PR: #<PR番号>
- 主要コミット: <hash> <件名>
```

- AC 記載なしの Issue の場合は「AC 検証結果」の代わりに「この Issue には AC の記載がないため照合をスキップした」旨と実装サマリを記載する
- post-merge 検証待ちが 1 件でもある場合は、コメントに「この Issue はマージ後も open のまま維持する」ことと、実測後に閉じる手順を明記する

### 7. 完了報告

全対象 Issue の照合・更新・コメントが完了したら、結果を要約して報告し、**そのまま実行できる形の merge コマンド**を提示します。Refs 運用では `--subject` と `--body` を必ず両方明示します（片方でも省略すると、squash メッセージの供給源がリポジトリ設定に応じて PR タイトル・コミットメッセージへ戻る）:

**Closes 運用（従来どおり Issue を閉じる）**:

```markdown
## /close-issue 完了

- 対象 Issue: #46（達成 6 / 未達 0 / 対象外 0）
- チェックボックス更新: ✅
- 完了報告コメント: ✅
- closing keyword 抵触検査: 対象なし（Closes 運用）
- 照合時の head SHA: <headRefOid>

→ マージに進めます:

    gh pr merge <PR番号> --squash --match-head-commit <headRefOid>

→ マージ直後に read-back（CLOSED を実測する）:

    gh issue view 46 --json state
```

**Refs 運用（Issue を open のまま維持する）**:

```markdown
## /close-issue 完了

- 対象 Issue: #46（達成 5 / 未達 0 / 対象外 0 / post-merge 検証待ち 1）— **マージ後も open 維持**
- チェックボックス更新: ✅
- 完了報告コメント: ✅
- closing keyword 抵触検査: ✅ 2a 抵触なし（INSPECTED 7 行）/ 2b 抵触なし（INSPECTED 2 行）
- 照合時の head SHA: <headRefOid>

→ マージに進めます（下のコマンドは**手順 2b の末尾で生成したものを貼る**。書き写さない）:

    <手順 2b の printf が出力した gh pr merge コマンドをそのまま貼る>

→ マージ直後に read-back（OPEN のままであることを実測する）:

    gh issue view 46 --json state
```

- **照合時点の `headRefOid` を報告に含め、マージには `--match-head-commit <SHA>` を推奨する**。照合後に PR へ追加 push があった場合、照合済みでない内容がマージされることを防げる（SHA 不一致ならマージが拒否されるので、再度 `/close-issue` を実行する）
- **報告に載せる merge コマンドは手順 2b が生成したものを貼る**（書き写さない）。`--subject` は PR タイトルのコピペになりやすく、そこに Issue 参照が残っていると `--body "Refs #N"` を守っても件名側で閉じる（この経路が実際の再発事例）。人が文字列を打ち直す時点で、そこが検査とマージの間の継ぎ目になり、2b は何も保証しなくなる
- **検査した行数（`INSPECTED`）は報告に転記する**。自分で数えた件数を書かない — 上流が切り詰められていた場合、その数字だけが食い違いを示す
- **read-back は検査を追加しても省略しない**。手順 2 の検査は既知の形（closing keyword × `#N` / `owner/repo#N`）しか見ず、`GH-N` 形式や Issue の完全 URL は対象外なので、実際の state だけが最終的な証拠になる。期待と違う state だった場合は `gh issue reopen` / `gh issue close` で復旧し、原因を記録する

## 注意事項

- このコマンドは **Issue をクローズしない**。クローズは従来どおりマージ時の `Closes #N` に任せる（クローズ経路を変えないことで、既存ワークフローとの互換性を保つ）
- Refs 運用の Issue についても、このコマンドは**閉じも開きもしない**。やるのは「squash 件名が閉じないことの検査」と「open のまま残す理由の記録」だけで、実際にクローズするのは post-merge 検証を実測した人（またはその実測を行ったセッション）
- `Closes #N` の自動クローズは **PR がリポジトリのデフォルトブランチにマージされたときのみ**発動する。develop がデフォルトブランチでないリポジトリでは、squash merge の時点では Issue は閉じず、デフォルトブランチへの昇格時に閉じる（本コマンドの照合・記録はどちらの構成でも有効）
- 未達 AC を「あとで直す」ためにマージを先行させない。マージゲートとして機能させることがこのコマンドの目的
- 複数 Issue を閉じる PR では、Issue ごとに照合・チェックボックス更新・コメントを独立して行う（1 つの Issue の未達が他の Issue の報告を止めない）
