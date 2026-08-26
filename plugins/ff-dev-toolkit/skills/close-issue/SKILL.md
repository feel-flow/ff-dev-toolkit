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

## プラグインルートの固定（必須）

<!-- ff-dev-toolkit-plugin-root-contract:start -->
同梱resourceを参照する前に `FF_DEV_TOOLKIT_ROOT` を**一度だけ**解決し、実行中は変更しない。

- Claude Codeでは、その呼び出しでホストが渡した `${CLAUDE_PLUGIN_ROOT}` を使う
- Codexなど他ホストでは、実際に読み込んだこの `SKILL.md` の絶対パスから `../..` を解決する

解決後は同じ絶対パスだけを使い、cache / marketplace / 旧インストール領域を走査して選ばない。
version sortによる版の選び直しや、sidecarを使った別実体への切替も行わない。
解決済みrootまたは必要resourceが消失・不整合になった場合は、別versionへfallbackせず
「ff-dev-toolkit更新後にこのskillを再呼び出してください」と案内して停止する。
<!-- ff-dev-toolkit-plugin-root-contract:end -->

## 前提

- git リポジトリで作業中であること
- 対象 PR が open であること（Draft のままでも実行はエラーにせず警告のみとするが、レビュー対応完了後・マージ直前の実行を想定）
- 実装変更がコミット済み + push 済みであること（AC 照合は push 済みの diff を対象とする）
- **実行タイミング**: レビュー対応完了後（Draft PR 運用時は `gh pr ready` の後）・`gh pr merge --squash` の前

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
# awk の現在行を $(0) と書くのは、裸のドル記号 + 0 がスキル読み込み時の引数展開で
# PR 番号へ置換され、走査対象が PR 本文から定数文字列に化けるため（実測: #776。
# 抽出 0 件でも EXTRACT_RC は 0 なので手順 2 の検査が丸ごとスキップされる fail-open）。
# awk では $ は演算子なので $(0) は現在行と完全に同義。
set +e
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

検査を通った `MERGE_SUBJECT` / `MERGE_BODY` は、**文字列を打ち直さずそのまま手順 7 へ持ち越す**（`--subject` のコピペこそが実際の再発経路だった）。

**merge コマンドの組み立ては手順 7 で行う。** ここで先に組み立てないのは、`--match-head-commit` へ渡してよい先端が「鮮度照合を通った値」に限られ、それが確定するのが手順 7 だからである（ここで組み立てると、未達 AC の修正ループで fix commit を積んだ回に古い先端が残り、照合を通ってもマージが拒否される）。

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

**未達 AC が大きい場合も先送りしない**: 現 Issue の AC はスコープ外発見ではない。解消が PR の想定規模を大きく超えても、自動で別 Issue へ移して「対象外」にせず、マージを停止してユーザーに仕様変更の判断を求める。ユーザーが現 Issue のスコープ変更を明示し、Issue 本文の AC がその決定に合わせて更新された場合だけ「対象外」として再照合する。実装中に見つかった独立した発見は AC と分離し、[スコープ外発見の三分岐](../../docs-template/05-operations/deployment/workflow-principles.md)へ渡す。

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

### 7. ゲート実測鮮度の照合（マージ直前）

ローカルで回した検証スイートの結果は、**その時点の特定コミットに対する実測**です。実測とマージのあいだにリモートが進んでいると、squash merge は**未実測のコミットまで畳み込む**ため、ゲートを回した意味が消えます。実測では、cloud セッションが作成した PR をローカルの worktree で引き取って作業しているあいだに、**同じセッションが同じブランチへ別方向の修正を push していた**（気付いたのは push が non-fast-forward で拒否されたとき）。

手順 8 で渡す `--match-head-commit` とは**守る窓が違います**:

| 検査 | 守る窓 |
| --- | --- |
| `--match-head-commit` | **AC 照合の後**に追加 push された内容がマージへ混入すること |
| 本手順の鮮度照合 | **ゲート実測の後**にリモートが先行していたこと。`headRefOid` はそのドリフトの後に読まれるので、`--match-head-commit` からは見えない |

比較の材料には **API の値（`headRefOid`）を照合直前に読み直して使う**。`git fetch` + `git rev-parse origin/<branch>` を比較に使ってはいけない — remote-tracking ref は前回 fetch 時点のスナップショットで、fetch を忘れた回・失敗した回に「古い先端 == 古い実測対象」で一致してしまい、いちばん守りたい経路で fail-open します。`--fetch` は**関係の分類**（祖先か / 未 push か / 分岐か）にだけ使います。

実測対象は自己申告ではなく**記録**から取ります。`scripts/record-gate-head.sh` がゲートの通過時に HEAD・作業ツリーの汚れ・モードを書き、`tests/run-all.sh` は既定一覧の実行でも明示引数の実行でもこれを呼びます。ただし**明示引数の実行は `STATUS=partial`（部分実行）として記録されます** — 名指しした suite しか回っていない記録は、リモート先端と一致していても全件緑へは昇格せず、判定不能（exit 2）として報告されます（マージは止まりません）。

**例外: 同じコミットに全件緑（`STATUS=pass`）の記録が既にあるときは、部分実行で上書きしません** — その記録は残り、照合は従来どおり一致（exit 0）を返します。`pass@X` は `partial@X` の上位互換の証拠なので、同じ X のまま名指し実行を 1 本足しただけで exit 0 が exit 2 へ変わるのは、安全側への寄与がゼロの情報の純減だからです。**全件ゲートを回した後にレビュー対応で名指し suite を 1 本回す、という並びでは exit 2 にならない**のが正しい挙動です（先端が動いていれば記録のコミットも変わるので、この例外は「同じコミット」でしか効きません）。赤い実行（`STATUS=fail`）は同じコミットでも従来どおり前回の緑を無効化します。

```bash
PR_NUMBER="${PR_NUMBER:?PR 番号を先に設定すること}"
# 照合直前に読み直す（手順 1 からの経過中にリモートが進んでいる可能性がある）。
# remote-tracking ref ではなく API の値を使い、**ここで得た値を手順 8 の
# --match-head-commit へそのまま渡す**（照合した先端とマージする先端を同じにする）
REMOTE_HEAD="$(gh pr view "${PR_NUMBER}" --json headRefOid --jq .headRefOid)" \
  || { echo "❌ リモート先端を取得できません（検査は成立していない）" >&2; exit 2; }
FRESHNESS="${FF_DEV_TOOLKIT_ROOT:?プラグインルートを先に解決すること}/scripts/check-merge-freshness.sh"

set +e
FRESH_OUT="$(bash "${FRESHNESS}" --remote-head "${REMOTE_HEAD}" --fetch)"
FRESH_STATUS=$?
set -e

case "${FRESH_STATUS}" in
  0)
    # 一致。無出力のままマージへ進む（常時ノイズにしない）。
    # 報告には実測の素性（ゲート名・モード）も載せる — 高速モードの記録を
    # 「全件実行で通した」と読ませないため（モードは合否には使わない）
    FRESH_RECORD="$(bash "${FRESHNESS}" --print-record || true)"
    FRESH_GATE="$(printf '%s\n' "${FRESH_RECORD}" | sed -n 's/^GATE=//p')"
    FRESH_MODE="$(printf '%s\n' "${FRESH_RECORD}" | sed -n 's/^MODE=//p')"
    FRESH_RESULT="$(printf '%s\n' "${FRESH_RECORD}" | sed -n 's/^RESULT=//p')"
    FRESH_REPORT="✅ 一致（${FRESH_GATE:-ゲート不明} / モード ${FRESH_MODE:-不明} / ${FRESH_RESULT:-結果不明}）"
    ;;
  1)
    printf '%s\n' "${FRESH_OUT}" >&2
    echo "❌ リモート先端がゲート実測対象と一致しません。取り込んで測り直すこと" >&2
    exit 1
    ;;
  2)
    # 判定不能（記録が無い / 汚れた木で測った / 記録が部分実行である / 記録の内容を信頼できない）。
    # マージは止めないが、REASON と ACTION を**両方**そのまま完了報告へ載せる（黙って素通りさせない）。
    # ACTION だけにしないのは、部分実行の ACTION が「上に名指しした suite で…」と REASON を指すため。
    # REASON を落とすと、報告の中で指す先が消えて「何を検証したのか」が読み手に届かない
    printf '%s\n' "${FRESH_OUT}"
    FRESH_REASON="$(printf '%s\n' "${FRESH_OUT}" | sed -n 's/^REASON=//p')"
    FRESH_ACTION="$(printf '%s\n' "${FRESH_OUT}" | sed -n 's/^ACTION=//p')"
    FRESH_REPORT="⚠️ 判定不能 — ${FRESH_REASON} / 次の一手: ${FRESH_ACTION}"
    ;;
  *)
    printf '%s\n' "${FRESH_OUT}" >&2
    echo "❌ 鮮度照合が成立していません（status=${FRESH_STATUS}）。一致として扱わず停止する" >&2
    exit 2
    ;;
esac
```

- 終了コード **0 = 一致（無出力）**、**1 = 不一致（マージを止める）**、**2 = 判定不能（止めないが報告する）**、**3 = 検査不成立（停止する）**。部分実行の記録（`STATUS=partial`）は、リモート先端と**一致していても** 2 へ倒れる — 名指しした suite だけを回した記録を全件緑へ昇格させないため
- 判定不能に当たる原因は増えうる（記録が無い / 汚れた木で測った / 直近のゲートが赤い / 記録が部分実行である / 記録の版や内容を解釈できない / 実測対象のコミットが手元に無い）。**個別の原因ではなく `FRESH_STATUS` で分岐する**
- **2 で止めないのは意図的**です。記録の仕組みを持たないプロジェクトでは判定不能が常態で、そこで無条件にマージを止めると検査ごと迂回されます。**この窓は静かに外れると squash merge に畳み込まれるので、ノイズより見逃しのコストが高い** — だから「黙って緑を返さない」ことを最低線として守り、判定不能は手順 8 の完了報告に必ず載せる
- 不一致の `RELATION` で次の一手が変わる: `ancestor`（実測後に自分が push した）→ 取り込んで再実測 / `unpushed`（未 push のコミットを測っている）→ push して再実測 / `divergent`（実測対象と先端が分岐した。別セッションの push に限らず、実測対象がマージ済み・削除済みのブランチ上にある場合もこれになる）→ **force-push で押し切らず**、相手のコミットの上に自分の変更を積んでから再実測
- 未達 AC の修正ループ（手順 4）で fix commit を push した場合、この照合は必ず不一致になる。**ゲートを回し直してから**マージへ進む

照合を通ったら、**merge コマンドをここで組み立てる**。渡す先端は直前に照合した `REMOTE_HEAD` で、件名・本文は手順 2b が検査した変数をそのまま展開する:

```bash
# Refs 運用: 手順 2b が検査した MERGE_SUBJECT / MERGE_BODY を使う
# %q はシェルで安全な引用形へ変換する
printf 'gh pr merge %s --squash --match-head-commit %s \\\n  --subject %q \\\n  --body %q\n' \
  "${PR_NUMBER}" "${REMOTE_HEAD}" "${MERGE_SUBJECT}" "${MERGE_BODY}"

# Closes 運用（Refs 対象が 0 件）: 件名・本文の明示は要らない
# printf 'gh pr merge %s --squash --match-head-commit %s\n' "${PR_NUMBER}" "${REMOTE_HEAD}"
```

- **この出力をそのまま手順 8 の報告へ貼る**。報告に載る merge コマンドは、2b が検査した文字列とこの手順が照合した先端から機械的に導出されたものでなければならない。人手で書き写した時点で、検査は何も保証しなくなる
- `%q` の出力はエスケープが入って読みにくいが、**シェルが解釈した結果は検査した文字列と同一**（多行の本文は `$'\n'` として現れる）。読みやすさのために引用を書き換えないこと — 書き換えた時点で「検査した文字列」ではなくなる

### 8. 完了報告

全対象 Issue の照合・更新・コメントが完了したら、結果を要約して報告し、**そのまま実行できる形の merge コマンド**を提示します。Refs 運用では `--subject` と `--body` を必ず両方明示します（片方でも省略すると、squash メッセージの供給源がリポジトリ設定に応じて PR タイトル・コミットメッセージへ戻る）:

**Closes 運用（従来どおり Issue を閉じる）**:

```markdown
## /close-issue 完了

- 対象 Issue: #46（達成 6 / 未達 0 / 対象外 0）
- チェックボックス更新: ✅
- 完了報告コメント: ✅
- closing keyword 抵触検査: 対象なし（Closes 運用）
- ゲート実測鮮度: <手順 7 の FRESH_REPORT をそのまま貼る>
- 照合時の head SHA: <headRefOid>

→ マージに進めます:

    <手順 7 の printf が出力した gh pr merge コマンドをそのまま貼る>

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
- ゲート実測鮮度: <手順 7 の FRESH_REPORT をそのまま貼る>
- 照合時の head SHA: <headRefOid>

→ マージに進めます（下のコマンドは**手順 7 の末尾で生成したものを貼る**。書き写さない）:

    <手順 7 の printf が出力した gh pr merge コマンドをそのまま貼る>

→ マージ直後に read-back（OPEN のままであることを実測する）:

    gh issue view 46 --json state
```

- **報告に載せる `headRefOid` は手順 7 が照合した値**にする（別に読み直した値を書くと、照合した先端とマージする先端が別物になりうる）。マージには `--match-head-commit <SHA>` を推奨する。照合後に PR へ追加 push があった場合、照合済みでない内容がマージされることを防げる（SHA 不一致ならマージが拒否されるので、再度 `/close-issue` を実行する）
- **報告に載せる merge コマンドは手順 7 が生成したものを貼る**（書き写さない）。`--subject` は PR タイトルのコピペになりやすく、そこに Issue 参照が残っていると `--body "Refs #N"` を守っても件名側で閉じる（この経路が実際の再発事例）。人が文字列を打ち直す時点で、そこが検査とマージの間の継ぎ目になり、2b は何も保証しなくなる
- **ゲート実測鮮度は判定不能でも省略しない**。手順 7 が exit 2 を返した回は `REASON` 行と `ACTION` 行を**両方**そのまま報告へ載せる（部分実行なら REASON が「何を検証したのか」を名指しし、ACTION がそれを指して次の一手を述べる。片方だけでは意味が閉じない）。判定不能を報告から落とすと、この窓は静かに外れたまま squash merge に畳み込まれる
- **検査した行数（`INSPECTED`）は報告に転記する**。自分で数えた件数を書かない — 上流が切り詰められていた場合、その数字だけが食い違いを示す
- **read-back は検査を追加しても省略しない**。手順 2 の検査は既知の形（closing keyword × `#N` / `owner/repo#N`）しか見ず、`GH-N` 形式や Issue の完全 URL は対象外なので、実際の state だけが最終的な証拠になる。期待と違う state だった場合は `gh issue reopen` / `gh issue close` で復旧し、原因を記録する

## 注意事項

- このコマンドは **Issue をクローズしない**。クローズは従来どおりマージ時の `Closes #N` に任せる（クローズ経路を変えないことで、既存ワークフローとの互換性を保つ）
- Refs 運用の Issue についても、このコマンドは**閉じも開きもしない**。やるのは「squash 件名が閉じないことの検査」と「open のまま残す理由の記録」だけで、実際にクローズするのは post-merge 検証を実測した人（またはその実測を行ったセッション）
- `Closes #N` の自動クローズは **PR がリポジトリのデフォルトブランチにマージされたときのみ**発動する。develop がデフォルトブランチでないリポジトリでは、squash merge の時点では Issue は閉じず、デフォルトブランチへの昇格時に閉じる（本コマンドの照合・記録はどちらの構成でも有効）
- 未達 AC を「あとで直す」ためにマージを先行させない。マージゲートとして機能させることがこのコマンドの目的
- 複数 Issue を閉じる PR では、Issue ごとに照合・チェックボックス更新・コメントを独立して行う（1 つの Issue の未達が他の Issue の報告を止めない）
