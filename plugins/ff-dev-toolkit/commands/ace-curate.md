---
description: マージ済み PR から知見を抽出し ACE Playbook（docs/08-knowledge/）へ構造化エントリとして追記する
argument-hint: [PR番号]
---

# /ace-curate — ACE サイクル実行（Playbook 増分更新）

マージ後・cleanup 後に PR から知見を抽出し、ACE Playbook に構造化エントリとして追記します。

## 前提

- git リポジトリで作業中であること
- マージ済み（cleanup 済み）の PR が存在すること（直近マージの PR が対象）
- `docs/08-knowledge/PLAYBOOK.md` が存在すること（`/ace-setup` で作成。エントリ本体は Category 別に `docs/08-knowledge/playbook/<category>.md` へ分割されている。PLAYBOOK.md 自体は索引 + 運用ルールのみ）
- 現在のブランチがデフォルト統合ブランチ（`develop` / `main` 等。以下 `<default-branch>`、`git symbolic-ref --short refs/remotes/origin/HEAD` で確認できる。`origin/<branch>` 形式で返る）であること（または ACE 専用 `chore/ace-from-pr-<PR番号>` ブランチ）
- **実行タイミング**: マージ後・cleanup 後（`<default-branch>` で実行）

## 引数

- `$ARGUMENTS` — 対象のPR番号（省略時は直近マージのPRを自動検出）

## 手順

### 1. 対象PRの特定

引数でPR番号が指定されていない場合、最近マージされた PR を自動検出します:

```bash
# 直近マージされた merged 状態の PR を取得（マージ後なので state=merged）
gh pr list --state merged --limit 20 --json number,title,body,url,mergedAt --jq 'sort_by(.mergedAt) | last'
```

指定されている場合:

```bash
gh pr view $ARGUMENTS --json number,title,body,url,comments,reviews
```

### 2. Phase 1: Generate（知見抽出）

対象PRの以下の情報を収集します:

- `gh pr diff $PR_NUMBER` でコード変更を確認
- `gh pr view $PR_NUMBER --json body,comments,reviews` で PR body（implementation-notes.md の転記を含む）とレビューコメントを確認
- 関連 Issue の内容を確認

収集した情報から、以下の観点で知見候補を抽出:

1. **コーディングパターン**: 採用した設計判断とその理由
2. **テスト戦略**: テストの書き方で得た教訓
3. **セキュリティ**: 脆弱性対策の知見
4. **パフォーマンス**: 最適化のヒント
5. **アーキテクチャ**: 構造上の決定事項
6. **プロセス**: ワークフロー・ツール活用の改善点

### 3. Phase 2: Reflect（評価・分類）

各知見候補について評価します:

- [ ] 再現性が「中」以上か？（低→スキップ）
- [ ] 影響度が「中」以上か？（低→スキップ）
- [ ] 汎用的すぎないか？（プロジェクト固有の文脈が含まれているか？）

次に、既存 Playbook エントリとの照合を行います:

- `docs/08-knowledge/PLAYBOOK.md` の索引テーブル全体（タイトル列）を眺め、知見候補と似たタイトルが**他カテゴリにもないか**を確認する（分割後は近縁エントリが別カテゴリへ分類されている場合がある）
- 候補カテゴリおよび似たタイトルが見つかったカテゴリの `docs/08-knowledge/playbook/<category>.md` を読み込み、各知見候補と既存エントリの重複・矛盾を確認

照合結果に応じたアクション:

- **重複**: 既存エントリの `Helpful` カウンターを +1
- **矛盾**: 既存エントリの Status を `deprecated` に変更 → 新エントリ作成
- **新規**: Phase 3 へ進む
- **低価値**: 記録しない

**Reuse 記録の反映（照合とは独立に実施）**: PR body（implementation-notes の転記）とコミット件名・本文に「参照して役立った」と記録された既存 ACE ID（git-workflow ステップ3 の着手前参照ゲートで記録されたもの）があれば、該当エントリの `Helpful` を +1 する。記録が無ければ何もしない。これを行わないと、実装者が残した Reuse 記録が Helpful カウンターに届かず静かに捨てられる。

### 4. Phase 3: Curate（増分更新）

#### 4-a. エントリIDの採番

ID は **PRスコープ式** `ACE-<PR番号>-<連番>`（例 `ACE-438-1`、非PR由来は `ACE-i<Issue番号>-<連番>`）。対象 PR の既存 `ACE-<PR番号>-*` を確認し最大連番 +1（既存が無ければ連番 `1`、すなわち `ACE-<PR番号>-1`）。全体の最新 ID は読まない。採番ルールの SSOT は [PLAYBOOK.md §エントリID規則](docs/08-knowledge/PLAYBOOK.md#エントリid規則)。

**採番前ガード（自己修復）** — 採番の前に以下を確認する:

1. 対象 PLAYBOOK.md に「エントリID規則」セクションが存在するか確認する。存在しない場合（旧形式 PLAYBOOK、または plugin 非経由でセットアップされたプロジェクト）は、本プラグイン同梱の `${CLAUDE_PLUGIN_ROOT}/docs-template/08-knowledge/PLAYBOOK.md` の「エントリID規則」をセクションごとコピーして PLAYBOOK.md に追加してから、PRスコープ式で採番する。挿入位置は「運用ルール」セクションの直後（テンプレートと同じ位置）、該当セクションが無い場合は先頭見出し直後とする
2. 既存の ID なしエントリ（`## [Pattern] ...` 形式等）や旧 3 桁エントリは **改名・書き換えしない**（エントリID規則「既存 ID の扱い」に従い共存させる）
3. プロジェクトに旧形式のローカル ACE コマンド（`.claude/commands/ace.md` 等、ID なし採番のもの）が存在する場合は、本コマンド（PRスコープ式）への一本化・旧コマンド撤去をユーザーに提案する（勝手に削除しない）

#### 4-b. playbook/<category>.md への追記 + PLAYBOOK.md 索引の更新

エントリ本体は該当カテゴリの `docs/08-knowledge/playbook/<category>.md` の末尾に追記する（`XXX` は 4-a の PRスコープ式 ID に置換。例 `ace-438-1` / `ACE-438-1`）:

```markdown
<a id="ace-XXX"></a>

### ACE-XXX: [タイトル]

| フィールド | 値           |
| ---------- | ------------ |
| Category   | [カテゴリ]   |
| Origin     | PR #[PR番号] |
| Date       | [今日の日付] |
| Helpful    | 0            |
| Harmful    | 0            |
| Status     | active       |

**Insight**: [知見の本質]

**Context**: [発見した状況]

**Action**: [推奨アクション]
```

該当カテゴリの `playbook/<category>.md` が未作成の場合は新規作成する（`PLAYBOOK.md` §ファイル分割ルールのテンプレートに従う）。

追記後、`docs/08-knowledge/PLAYBOOK.md` の索引テーブル（`## エントリ一覧`）にも 1 行追加する:

```markdown
| ACE-XXX | [タイトル] | [カテゴリ] | [playbook/<category>.md#ace-xxx](./playbook/<category>.md#ace-xxx) |
```

**anchor 命名規則**: 見出し直前に `<a id="ace-XXX"></a>` を 1 行付与（エントリ ID を小文字化、例 `ace-438-1`）。詳細・根拠は SSOT である [PLAYBOOK.md 記述ガイドライン](docs/08-knowledge/PLAYBOOK.md#記述ガイドライン) を参照。

#### 4-c. Frontmatter の更新

- `version` のマイナーバージョンをインクリメント
- `updated` を今日の日付に更新
- `ace_entry_count` をインクリメント（新規エントリ追加時のみ。カウンター更新のみの場合は変更しない）

### 5. コミット

マージ方針の SSOT は [git-workflow.md ステップ10 §運用パターン（マージ方針）](docs/05-operations/deployment/git-workflow.md#ace-merge-policy)（`docs-template/` 全体を導入している場合の参照。無ければ以下の既定に従う）。

**既定（推奨）— デフォルトブランチ直マージ**: `<default-branch>` に直接 commit + push する。

```bash
# 1 回の curate で複数エントリ・複数カテゴリに触れることがあるため、
# 変更した playbook/*.md を全て add する（PLAYBOOK.md の索引更新も対象）
git add docs/08-knowledge/PLAYBOOK.md docs/08-knowledge/playbook/*.md
git status --short  # 意図したファイルのみが含まれるか確認
git commit -m "knowledge: ACE-<PR番号>-<連番> [category] [summary]"
git push origin <default-branch>
```

**任意エスカレーション — chore PR**: 大人数チーム / 知見レビューを残したい場合のみ `chore/ace-from-pr-<PR番号>` ブランチで小さい PR を作成。

```bash
git checkout -b chore/ace-from-pr-<PR番号>
git add docs/08-knowledge/PLAYBOOK.md docs/08-knowledge/playbook/*.md
git status --short  # 意図したファイルのみが含まれるか確認
git commit -m "knowledge: ACE-<PR番号>-<連番> [category] [summary]"
git push -u origin chore/ace-from-pr-<PR番号>
gh pr create --base <default-branch> --title "knowledge: ACE-<PR番号>-<連番> [category]" --body "PR #<PR番号> から知見抽出"
# レビュー後 squash merge → /merge-cleanup
```

> `knowledge:` 付き PLAYBOOK 単独コミットの `<default-branch>` 直 push は意図的フローであり、通常のコード変更に対する「統合ブランチへの直 push 禁止」ルールとは別物として扱う。

### 6. 結果レポート

以下の形式で結果を報告します:

```
## ACE サイクル完了レポート

**対象PR**: #[PR番号] [タイトル]
**抽出知見数**: X 件
**新規エントリ**: ACE-438-1, ACE-438-2
**カウンター更新**: ACE-016 (Helpful +1)
**スキップ**: X 件（低価値）

### 追加エントリ
- ACE-438-1: [タイトル] ([カテゴリ])
- ACE-438-2: [タイトル] ([カテゴリ])
```

## 注意事項

- エントリの追記は **末尾のみ**。既存エントリの本文（Insight/Context/Action）の書き換えは禁止
- 既存エントリの Helpful/Harmful カウンター更新と Status 変更（active → deprecated）は許可
- カウンターの更新は **インクリメントのみ**（減算しない）
- 知見が抽出されない場合（typo修正のみ等）は「知見なし」と報告して終了
- PLAYBOOK.md はカテゴリ別に `playbook/*.md` へ分割済み。肥大化チェックは `scripts/ace/` テンプレート導入済みプロジェクトの場合 `npx --yes tsx scripts/ace/check-category-size.ts docs/08-knowledge/PLAYBOOK.md` で実行できる（npm script として登録してもよい）。このチェックは `playbook/` サブディレクトリを自動検出して索引 + 全サブファイルの総行数・カテゴリ別件数を集計する。`ACE_MAX_PLAYBOOK_LINES`（既定 800）をいずれかのファイルが超えると警告が出る（**警告のみ・追記はブロックしない**）。個別カテゴリファイルが肥大化した場合はさらなる分割・アーカイブを別 Issue で検討する
