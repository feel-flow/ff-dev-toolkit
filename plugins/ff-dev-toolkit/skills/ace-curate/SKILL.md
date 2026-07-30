---
name: ace-curate
description: マージ済み PR から知見を抽出し ACE Playbook（docs/08-knowledge/）へ構造化エントリとして追記する
---

# /ace-curate — ACE サイクル実行（Playbook 増分更新）

マージ後・cleanup 後に PR から知見を抽出し、ACE Playbook に構造化エントリとして追記します。

## プラグインルートの解決

同梱ファイルを参照する前に `FF_DEV_TOOLKIT_ROOT` を解決する。Claude Code では `${CLAUDE_PLUGIN_ROOT}` を使い、Codex など他ホストでは読み込んだこの `SKILL.md` の絶対パスから `../..` を解決する。以下の `${FF_DEV_TOOLKIT_ROOT}` はその絶対パスを指す。バージョン別 cache を探索して選ばない。

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

**一回性のインシデント叙述は Playbook に書かない**: 特定障害のタイムライン・復旧ログ・環境固有の調査記録は再現性ゲート「低→スキップ」の適用対象であり、Playbook ではなく `docs/08-knowledge/TROUBLESHOOTING.md` や runbook へ記録する。Playbook に残すのは「次に同型の状況で使える主張」だけで、その主張が導かれた個別事象の詳細は記録先を分ける。

次に、既存 Playbook エントリとの照合を行います:

- `docs/08-knowledge/PLAYBOOK.md` の索引テーブル全体（タイトル列）を眺め、知見候補と似たタイトルが**他カテゴリにもないか**を確認する（分割後は近縁エントリが別カテゴリへ分類されている場合がある）
- 候補カテゴリおよび似たタイトルが見つかったカテゴリの `docs/08-knowledge/playbook/<category>.md` を読み込み、各知見候補と既存エントリの重複・矛盾を確認

照合結果に応じたアクション:

- **重複**: 既存エントリの `Helpful` カウンターを +1
- **矛盾**: 既存エントリの Status を `deprecated` に変更 → 新エントリ作成
- **新規**: Phase 3 へ進む
- **低価値**: 記録しない

**Reuse 記録の反映（照合とは独立に実施）**: PR body（implementation-notes の転記）に「参照して役立った」と記録された既存 ACE ID（git-workflow ステップ3 の「着手前の Playbook 参照（ACE Reuse）」で記録されたもの）があれば、該当エントリの `Helpful` を +1 する。同一 ACE ID が複数回現れても 1 PR につき +1（重複出現は加算しない）。コミット件名・本文への記録は再利用計測 `ace-reuse-report` の入力であり、ここでは扱わない（git-workflow ステップ3 の経路分離に従う）。記録が無ければ何もしない。これを行わないと、実装者が残した Reuse 記録が Helpful カウンターに届かず静かに捨てられる。

### 4. Phase 3: Curate（増分更新）

#### 4-a. エントリIDの採番

ID は **PRスコープ式** `ACE-<PR番号>-<連番>`（例 `ACE-438-1`、非PR由来は `ACE-i<Issue番号>-<連番>`）。対象 PR の既存 `ACE-<PR番号>-*` を確認し最大連番 +1（既存が無ければ連番 `1`、すなわち `ACE-<PR番号>-1`）。全体の最新 ID は読まない。採番ルールの SSOT は [PLAYBOOK.md §エントリID規則](docs/08-knowledge/PLAYBOOK.md#エントリid規則)。

**採番前ガード（自己修復）** — 採番の前に以下を確認する:

1. 対象 PLAYBOOK.md に「エントリID規則」セクションが存在するか確認する。存在しない場合（旧形式 PLAYBOOK、または plugin 非経由でセットアップされたプロジェクト）は、本プラグイン同梱の `${FF_DEV_TOOLKIT_ROOT}/docs-template/08-knowledge/PLAYBOOK.md` の「エントリID規則」をセクションごとコピーして PLAYBOOK.md に追加してから、PRスコープ式で採番する。挿入位置は「運用ルール」セクションの直後（テンプレートと同じ位置）、該当セクションが無い場合は先頭見出し直後とする
2. 既存の ID なしエントリ（`## [Pattern] ...` 形式等）や旧 3 桁エントリは **改名・書き換えしない**（エントリID規則「既存 ID の扱い」に従い共存させる）
3. プロジェクトに旧形式のローカル ACE コマンド（`.claude/commands/ace.md` 等、ID なし採番のもの）が存在する場合は、本コマンド（PRスコープ式）への一本化・旧コマンド撤去をユーザーに提案する（勝手に削除しない）

#### 4-b. playbook/category.md への追記 + PLAYBOOK.md 索引の更新

エントリ本体は該当カテゴリの `docs/08-knowledge/playbook/<category>.md` の末尾に、**コンパクト正準フォーマット**で追記する（`XXX` は 4-a の PRスコープ式 ID に置換。例 `ace-438-1` / `ACE-438-1`）:

```markdown
<a id="ace-XXX"></a>

### ACE-XXX: [検索可能な主張 1 文のタイトル]

| Category | [カテゴリ] | Origin | PR #[PR番号] |
| Date | [今日の日付] |
| Helpful | 0 | Harmful | 0 |
| Status | active |

[本文 2〜4 文。1 文目 = 知見の本質。非自明な適用条件が 1 文。推奨アクションで締める。手順の列挙・叙述は書かない — 主張が明確なら詳細手順は読み手（AI）が再導出できる]

---
```

- メタ 4 行は**各行の行頭**に置く（`Category` / `Date` / `Helpful` / `Status` を行頭のパイプ区切りで書くことが `check-category-size` / `ace-reuse-report` のパース互換条件。1 行に畳んだ `H:n | #PR` 形式は集計から漏れるため使わない）
- ヘッダ行・区切り行を持たないため GitHub 上ではテーブルとして描画されない（AI ファースト文書として意図した仕様。詳細は PLAYBOOK.md §エントリテンプレート）
- 旧テーブル形式（`| フィールド | 値 |` + Insight/Context/Action）のエントリは**読み取り互換として共存**させる。新規追記には使わない
- 重複時の `Helpful` +1 は、旧形式なら `| Helpful | n |` 行、新形式なら `| Helpful | n | Harmful | m |` 行の n を +1 する

該当カテゴリの `playbook/<category>.md` が未作成の場合は新規作成する（`PLAYBOOK.md` §ファイル分割ルールのテンプレートに従う）。

追記後、`docs/08-knowledge/PLAYBOOK.md` の索引テーブル（`## エントリ一覧`）にも 1 行追加する:

```markdown
| ACE-XXX | [タイトル] | [カテゴリ] | [playbook/<category>.md#ace-xxx](./playbook/<category>.md#ace-xxx) |
```

**索引行はタイトルのみ**。説明文・複数文・補足プロースを索引テーブルに書かない（索引の肥大は検索面そのものを劣化させる）。

**anchor 命名規則**: 見出し直前に `<a id="ace-XXX"></a>` を 1 行付与（エントリ ID を小文字化、例 `ace-438-1`）。詳細・根拠は SSOT である [PLAYBOOK.md 記述ガイドライン](docs/08-knowledge/PLAYBOOK.md#記述ガイドライン) を参照。

#### 4-c. Frontmatter の更新

`version` の上げ方（semver）:

| 変更内容 | `version` の操作 | 例 |
| -------- | ---------------- | --- |
| **新規エントリ追加**（1 件以上） | **minor +1**し、patch は **0 にリセット** | `1.59.1` → `1.60.0`、`1.60.0` → `1.61.0` |
| **カウンター更新のみ**（Helpful/Harmful、Status 変更のみ） | **変更しない** | `1.60.0` のまま |
| **パッチ上げは使わない** | ACE curate では patch を上げない（過去に `1.59.1` 等が出たのは手順と `--bump-version` の齟齬。本手順が正） | — |

その他:

- `updated` を今日の日付に更新
- `ace_entry_count` をインクリメント（新規エントリ追加時のみ。カウンター更新のみの場合は変更しない）
- 機械同期する場合はプロジェクトの `ace:bump-playbook-frontmatter`（`--write --bump-version`。**minor +1**）。count のみ直すなら `ace:sync-playbook-frontmatter`

#### 4-d. Changelog の更新

`docs/08-knowledge/PLAYBOOK.md` の `## Changelog` セクション**先頭**（最新版の直前）へ、当該版の項目を追記する。**version を上げたのに Changelog が空のまま、を禁止する**（frontmatter の `version` と最新 `### [x.y.z]` は一致必須。`ace:check-playbook-frontmatter` が検証する）。

**新規エントリ追加時**（4-c で minor を上げた版）:

```markdown
### [x.y.0] - YYYY-MM-DD

#### 追加

- ACE-XXX: [タイトル要約]（Issue #N / PR #N）

#### カウンター更新

- ACE-YYY: Helpful +1（[参照した理由の一行]）
```

- `#### カウンター更新` は当該 curate で Helpful/Harmful を動かした場合のみ書く（無ければ見出しごと省略）
- 1 回の curate で追加した全エントリを同じ版ブロックに列挙する

**カウンター更新のみ**（version 不変）:

- 最新版ブロックへ `#### カウンター更新`（無ければ追加）の下に行を追記する。新しい `### [x.y.z]` は作らない

#### 4-e. 行数バジェット自己チェック（必須・ブロッキング）

追記した各エントリのブロック行数（anchor 行〜終端 `---`）を数え、**15 行以内**であることを確認する。超過した場合:

1. まず本文を削る（叙述・手順列挙を主張へ圧縮する）
2. 反直感的な詳細がどうしても必要な場合のみ、本文に `<!-- ace-line-budget-exception: 理由 -->` を 1 行添えて **30 行以内**に収める
3. 30 行でも収まらないなら、それは知見ではなくインシデント叙述の可能性が高い — Phase 2 の記録先分離（TROUBLESHOOTING.md / runbook 行き）を再検討する

#### 4-f. 同期検証（必須）

4-c / 4-d のあと、コミット前に必ず検証する:

```bash
npm run ace:check-playbook-frontmatter
# プロジェクトに npm script が無い場合:
# npx --yes tsx path/to/sync-playbook-frontmatter.ts docs/08-knowledge/PLAYBOOK.md --check
```

- exit 0 になるまで 4-c / 4-d を直す（`ace_entry_count` 不一致・version↔Changelog 不一致の両方をゲートする）
- 通ってから手順 5 のコミットへ進む

### 5. コミット

マージ方針の SSOT は [git-workflow.md ステップ10 §運用パターン（マージ方針）](docs/05-operations/deployment/git-workflow.md#ace-merge-policy)（`docs-template/` 全体を導入している場合の参照。無ければ以下の既定に従う）。

**既定（推奨）— デフォルトブランチ直マージ**: `<default-branch>` に直接 commit + push する。

コミット前に対象リポジトリの commitlint 設定（特に `header-max-length`）を確認し、件名を上限内に収める。カテゴリが複数でも件名には列挙せず、commit body に記録する。要約だけで上限を超える場合は、要約を短くするかコミットを分割する。

```bash
# 1 回の curate で複数エントリ・複数カテゴリに触れることがあるため、
# 変更した playbook/*.md を全て add する（PLAYBOOK.md の索引更新も対象）
git add docs/08-knowledge/PLAYBOOK.md docs/08-knowledge/playbook/*.md
git status --short  # 意図したファイルのみが含まれるか確認
git commit \
  -m "knowledge: ACE-<PR番号>-<連番> <要約>" \
  -m "Categories: <category[, category...]>"
git push origin <default-branch>
```

**任意エスカレーション — chore PR**: 大人数チーム / 知見レビューを残したい場合のみ `chore/ace-from-pr-<PR番号>` ブランチで小さい PR を作成。

```bash
git checkout -b chore/ace-from-pr-<PR番号>
git add docs/08-knowledge/PLAYBOOK.md docs/08-knowledge/playbook/*.md
git status --short  # 意図したファイルのみが含まれるか確認
git commit \
  -m "knowledge: ACE-<PR番号>-<連番> <要約>" \
  -m "Categories: <category[, category...]>"
git push -u origin chore/ace-from-pr-<PR番号>
gh pr create --base <default-branch> --title "knowledge: ACE-<PR番号>-<連番> <要約>" --body "PR #<PR番号> から知見抽出"
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

- エントリの追記は **末尾のみ**。既存エントリの本文（新形式の本文 / 旧形式の Insight/Context/Action）の書き換えは禁止
- **既存エントリの要約・アーカイブ・統合は `/ace-refine` のみが行う**（本スキルは grow 専用。refine 側は dry-run → ユーザー承認 → 原文アーカイブ保全付きで行う）
- 既存エントリの Helpful/Harmful カウンター更新と Status 変更（active → deprecated）は許可
- カウンターの更新は **インクリメントのみ**（減算しない）
- 知見が抽出されない場合（typo修正のみ等）は「知見なし」と報告して終了
- PLAYBOOK.md はカテゴリ別に `playbook/*.md` へ分割済み。肥大化チェックは `scripts/ace/` テンプレート導入済みプロジェクトの場合 `npx --yes tsx scripts/ace/check-category-size.ts docs/08-knowledge/PLAYBOOK.md` で実行できる（npm script として登録してもよい）。このチェックは `playbook/` サブディレクトリを自動検出して索引 + 全サブファイルの総行数・カテゴリ別件数を集計する（`playbook/archive/` 配下は対象外）。`ACE_MAX_PLAYBOOK_LINES`（既定 800）をいずれかのファイルが超えると警告が出る（**警告のみ・追記はブロックしない**）。行数警告・カテゴリ件数超過（130 件）が出た場合は `/ace-refine` で stale アーカイブ・圧縮・統合を実行する（分割だけで凌がない）
