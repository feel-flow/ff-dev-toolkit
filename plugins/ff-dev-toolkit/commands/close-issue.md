---
description: マージ直前に PR が閉じる Issue の受け入れ条件（AC）を照合し、チェックボックス更新 + 完了報告コメントを投稿する（AC 照合ゲート）
argument-hint: [PR番号]
---

# /close-issue — Issue クローズ前の AC 照合ゲート

`gh pr ready` の後・`gh pr merge` の**前**に実行し、PR の `Closes #N` で閉じられる Issue の受け入れ条件（AC）を照合します。Issue がまだ open のうちに検証記録を残すことで、「AC 未検証のまま無言で自動クローズされる」問題を防ぎます。

起票時の `/create-issue`（GWT + DoD 起票）と対になり、Issue のライフサイクル両端で仕様が検証される構造を作ります。

## 前提

- git リポジトリで作業中であること
- 対象 PR が open であること（Draft のままでも実行はエラーにせず警告のみとするが、レビュー対応完了後・マージ直前の実行を想定）
- 実装変更がコミット済み + push 済みであること（AC 照合は push 済みの diff を対象とする）
- **実行タイミング**: レビュー対応完了後（Draft PR 運用時は `gh pr ready` の後）・`gh pr merge --squash` の前

## 引数

- `$ARGUMENTS` — 対象の PR 番号（省略時は現在のブランチに紐づく PR を自動検出）

## 手順

### 1. 対象 Issue の自動検出

PR の `Closes #N` 参照から、クローズ対象の Issue を取得します:

```bash
# PR番号指定時（省略時は番号なしで実行し、現在のブランチの PR を対象にする）
gh pr view $ARGUMENTS --json number,state,isDraft,headRefName,headRefOid,closingIssuesReferences
```

- 以降、検出した PR 番号を `$PR_NUMBER`、各 Issue の URL を `$ISSUE_URL` と表記する
- **ブランチガード（必須）**: `git branch --show-current` が `headRefName` と一致しない場合は、未達 AC の修正ループで**誤ったブランチに commit する事故を防ぐため**、`gh pr checkout $PR_NUMBER` で PR のブランチに切り替えてから続行する（切り替えできない場合は停止して報告）
- `closingIssuesReferences` の各要素からは **Issue の URL を保持**し、以降の `gh issue view / edit / comment` には番号ではなく `$ISSUE_URL` を渡す（`Fixes owner/repo#100` 形式のクロスリポジトリ参照で、同番号の別 Issue を誤更新しないため）
- `closingIssuesReferences` が**空**の場合: 「この PR は Issue を閉じません」と報告して終了する（エラーにしない）
- **複数 Issue** が含まれる場合: 各 Issue に対して手順 2〜5 を独立して繰り返す

### 2. AC 照合

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

| 判定       | 意味                                                             |
| ---------- | ---------------------------------------------------------------- |
| **達成**   | AC を満たす変更・検証結果が PR に含まれている                    |
| **未達**   | AC を満たす変更が確認できない                                    |
| **対象外** | 実装過程で仕様が変わった等、この PR では扱わないことになった項目 |

**AC が記載されていない Issue** の場合: 照合をスキップして手順 5 に進み、実装サマリコメントのみ投稿する（コメント内に「AC 記載なし」を明記）。

### 3. 未達 AC の解消（自動修正ループ）

未達の AC がある場合、マージを進めずにその場で解消します:

1. 未達 AC を満たす実装・テストを追加する
2. fix commit を作成して push する
3. 手順 2 に戻って再照合する（全 AC が達成 or 対象外になるまで繰り返す）

**停止してユーザーに確認するのは次の場合のみ**:

- AC の達成に**仕様変更が必要**で、実装では解消できない（Issue の要件自体を変える判断が必要）

**スコープ外に膨らむ場合**: 未達 AC の解消が PR のスコープを大きく超える場合は、別 Issue を起票（`gh issue create`）して当該 AC を「対象外」とし、完了報告コメントに別 Issue 番号を明記して続行する。

### 4. Issue 本文のチェックボックス更新

達成した AC のチェックボックスをチェック済みに更新します。**必ず Markdown タスクリスト記法の checked state（`- [ ]` → `- [x]`）で書き換えること**（`☑` などの文字を挿入すると GitHub 上ではタスクとして認識されない）:

```bash
# 1) 最新 body と updatedAt を取得（Issue 番号を含む一時ファイル名にする）
gh issue view $ISSUE_URL --json body,updatedAt
#    body を /tmp/issue-body-<Issue番号>.md に保存し、updatedAt を控えておく

# 2) 達成と判定した AC の行だけを "- [ ]" → "- [x]" に書き換える
#    （Edit ツール等で該当行を個別に置換する。sed 等での一括置換は
#      未達・対象外の項目まで完了扱いにしてしまうため禁止）

# 3) 書き換え結果を diff し、「チェックボックス以外の変更がない」ことを確認

# 4) 送信直前に updatedAt を再取得し、1) から変化していないことを確認してから送信
#    （変化していたら 1) からやり直す。他者の編集を上書きしないため）
gh issue edit $ISSUE_URL --body-file /tmp/issue-body-<Issue番号>.md
```

- 更新するのは**チェックボックスのみ**。Issue 本文の要件テキスト自体は書き換えない（履歴の追跡性維持）
- 未達のまま「対象外」とした項目はチェックせず、完了報告コメント側で理由を説明する

### 5. 完了報告コメントの投稿

Issue に完了報告コメントを投稿します（**日本語**）。Markdown 表やバッククォートを含むため、`--body` の直接指定ではなく **`--body-file`** を使います:

```bash
# 再実行時の重複投稿を防ぐ: 既存コメントにマーカーがあれば新規投稿せず、そのコメントを更新する
gh issue comment $ISSUE_URL --body-file /tmp/close-issue-report-<Issue番号>.md
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

### 参照

- PR: #<PR番号>
- 主要コミット: <hash> <件名>
```

- AC 記載なしの Issue の場合は「AC 検証結果」の代わりに「この Issue には AC の記載がないため照合をスキップした」旨と実装サマリを記載する

### 6. 完了報告

全対象 Issue の照合・更新・コメントが完了したら、結果を要約して報告し、`gh pr merge --squash` へ進めることを伝えます:

```markdown
## /close-issue 完了

- 対象 Issue: #46（達成 6 / 未達 0 / 対象外 0）
- チェックボックス更新: ✅
- 完了報告コメント: ✅
- 照合時の head SHA: <headRefOid>

→ マージに進めます: gh pr merge <PR番号> --squash --match-head-commit <headRefOid>
```

- **照合時点の `headRefOid` を報告に含め、マージには `--match-head-commit <SHA>` を推奨する**。照合後に PR へ追加 push があった場合、照合済みでない内容がマージされることを防げる（SHA 不一致ならマージが拒否されるので、再度 `/close-issue` を実行する）

## 注意事項

- このコマンドは **Issue をクローズしない**。クローズは従来どおりマージ時の `Closes #N` に任せる（クローズ経路を変えないことで、既存ワークフローとの互換性を保つ）
- `Closes #N` の自動クローズは **PR がリポジトリのデフォルトブランチにマージされたときのみ**発動する。develop がデフォルトブランチでないリポジトリでは、squash merge の時点では Issue は閉じず、デフォルトブランチへの昇格時に閉じる（本コマンドの照合・記録はどちらの構成でも有効）
- 未達 AC を「あとで直す」ためにマージを先行させない。マージゲートとして機能させることがこのコマンドの目的
- 複数 Issue を閉じる PR では、Issue ごとに照合・チェックボックス更新・コメントを独立して行う（1 つの Issue の未達が他の Issue の報告を止めない）
