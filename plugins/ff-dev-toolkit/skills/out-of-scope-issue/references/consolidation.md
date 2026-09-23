# 既存 Issue への統合（/out-of-scope-issue）

`/out-of-scope-issue` の SKILL.md「3.1 類似 Issue の検索（新規作成より先）」の類似度表で、既存 Issue・`bundle` へのコメント統合、または既存 Issue 本文への AC 追記を選んだときに読む。候補の検索・fail-closed の扱い・類似度の判定は SKILL.md 側が正本で、以下の `gh issue` 操作にも同じく `--repo "$expected_repo"` を付ける。bundle の sub-issue として新規に起票する場合は [filing.md](filing.md) へ進む。

**統合元・統合先の本文は全文取得する**（`head` / `tail` で切った出力を統合の根拠にしない）。このリポジトリ群の house format では受け入れ条件 / DoD が本文の**末尾**にあり、先頭だけを読むとちょうどその手前で切れる（クローズ済みの統合元は検索の作業セットから外れるため、survivor へ転記し損ねた AC・DoD・参照は気づかれないまま消える）。`gh issue view {number} --repo "$expected_repo" --json body --jq '.body'` をそのまま読むか、一時ファイルへ落として読む。統合元をクローズする前には、**survivor への転記を機械的に確認する** — 転記した見出し・固有記述が `gh issue view {survivor} --repo "$expected_repo" --json body` の取得結果に現れることを `grep -c` 等で実測してからクローズする（「転記した」という主張は survivor 本文の実測で裏を取る）。

既存 Issue への統合は **コメントだけを既定**とする。本文を更新するのは、ユーザーが当該 Issue 本文の変更を明示的に許可し、元の目的・記述を保持したまま今回の AC だけを必要最小限で追記できる場合に限る。進行中 Issue の目的を変える、既存 AC を削る、議論の履歴を本文から消す更新はしない。

本文を更新する場合は、最初に取得した `body` と `updatedAt` を保持し、編集直前に同じ `--repo` で再取得する。どちらかが変わっていたら `gh issue edit` を実行せず、最新状態へ合わせて再判断する。再確認後も書き込み直前の競合を完全には排除できないため、迷った場合はコメントだけに留める。本文更新が不要なら、次の形式のコメントだけでよい:

```text
## 追加でまとめる発見
- 発見元: PR #{current_pr} / {tool 名}
- 内容: {発見内容}
- 既存 AC での扱い: {同じ完了条件に含まれる理由}
```

`gh issue comment {number} --repo "$expected_repo"` / `gh issue edit {number} --repo "$expected_repo"` の終了コードを確認し、成功した操作だけを報告する。失敗時に次の成功形式を返さない。この経路を選んだ場合の戻り値:

```text
Consolidated into Issue #{number} — {title}
URL: {issue_url}
```
