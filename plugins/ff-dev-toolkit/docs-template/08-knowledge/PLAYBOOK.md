---
title: "PLAYBOOK"
version: "1.39.0"
status: "approved"
created: "2026-03-10"
updated: "2026-07-06"
owner: "@fffokazaki"
ace_entry_count: 76
tags: [ace, playbook, knowledge-management]
references:
  - docs/ACE_FRAMEWORK.md
  - docs-template/05-operations/deployment/ace-cycle.md
---

# ACE Playbook

> **Parent**: [BEST_PRACTICES.md](./BEST_PRACTICES.md) | **関連**: [ACE サイクル運用手順](../05-operations/deployment/ace-cycle.md) | [ACE フレームワーク概念](../../docs/ACE_FRAMEWORK.md)

## 概要

### 目的

ACE (Agentic Context Engineering) Playbook は、開発プロセスで得た知見を **AIツールが直接参照できる構造化形式** で蓄積するファイルです。

GitHub Discussions が「人間が読むためのナラティブ（物語的記録）」であるのに対し、Playbook は「AIが参照するための構造化知見（delta方式: 差分のみを末尾追記する更新方式）」として機能します。

### 運用ルール

| ルール                             | 説明                                                                                                                           |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| **末尾追記のみ**                   | エントリは常にファイル末尾に追記。既存エントリの本文（Insight/Context/Action）書き換えは禁止。カウンター更新・Status変更は許可 |
| **カウンターはインクリメントのみ** | Helpful/Harmful は +1 のみ。減算・リセットはしない                                                                             |
| **削除禁止**                       | エントリを物理的に削除しない。不要な場合は `Status: deprecated` に変更                                                         |
| **800行超過時は分割**              | `playbook/` サブディレクトリにカテゴリ別ファイルとして分割                                                                     |
| **Frontmatter更新**                | エントリ追加時に `version`, `updated`, `ace_entry_count` を更新                                                                |
| **コミット規則**                   | `knowledge: ACE-XXX [category] [summary]` 形式で記録                                                                           |

### エントリID規則

ACE エントリ ID は **PRスコープ式** を採用する（このセクションが ID 規則の SSOT）。複数人・複数AIが並行で `/ace-curate` を回しても番号が衝突しないための構造である。

- **形式**: `ACE-<PR番号>-<連番>`（例: `ACE-438-1`, `ACE-438-2`）
- **非PR由来の fallback**: `ACE-i<Issue番号>-<連番>`（例: `ACE-i425-1`）
- **採番**: 同一 PR の既存 `ACE-<PR番号>-*` の最大連番 +1 を連番とする（既存が無ければ連番 `1`、すなわち最初のエントリは `ACE-<PR番号>-1`）。**全体の最新 ID を読む必要がない**ため並行採番でも衝突しない（PR 番号は GitHub が全体一意に採番するため、別 PR = 別 namespace）。
- **連番の範囲**: 1 回の `/ace-curate` で同一 PR から 1〜3 件追記する想定。同一 PR を再 curate する場合は既存の最大連番から継続。
- **既存 ID の扱い**: 旧 `ACE-{連番3桁}` 形式（`ACE-001`〜）のエントリは **改名しない**。旧 3 桁形式と新 PRスコープ式は恒久的に共存する（参照・anchor 互換の維持）。ID にファイル位置の情報は持たせないため、分割後も ID はそのまま維持する。

---

## カテゴリ一覧

| カテゴリ                | 説明                                                 | 例                                   |
| ----------------------- | ---------------------------------------------------- | ------------------------------------ |
| `coding`                | コーディングパターン、言語固有のベストプラクティス   | 型安全性、エラーハンドリング         |
| `architecture`          | 設計判断、構造上の決定事項                           | レイヤー設計、モジュール分割         |
| `testing`               | テスト戦略、テストパターン                           | モック設計、テストデータ管理         |
| `security`              | セキュリティ対策、脆弱性防止                         | 認証、暗号化、入力検証               |
| `performance`           | パフォーマンス最適化                                 | キャッシュ、クエリ最適化             |
| `devops`                | CI/CD、デプロイ、環境構築                            | パイプライン、インフラ設定           |
| `process`               | 開発プロセス、ワークフロー改善                       | レビュー手法、タスク管理             |
| `tooling`               | ツール設定、開発環境                                 | IDE設定、リンター、フォーマッター    |
| `documentation-quality` | ドキュメントの品質・整合性・記法統一                 | anchor整合、表記揺れ、リンク切れ防止 |
| `knowledge-management`  | 知見・Playbook自体の運用・構造化                     | ACE運用ルール、索引設計              |
| `documentation`         | ドキュメント作成・構成（品質観点を除く一般カテゴリ） | 文書構成、README整備                 |

---

## ステータス定義

| ステータス   | 説明                                   | 遷移条件                                                |
| ------------ | -------------------------------------- | ------------------------------------------------------- |
| `active`     | 有効な知見                             | 新規作成時のデフォルト                                  |
| `deprecated` | 非推奨（古い情報、矛盾が発見された等） | Harmful >= 3 かつ Helpful < Harmful、または明示的な判断 |

---

## エントリテンプレート

新しいエントリを追記する際は、以下のテンプレートを使用してください：

```markdown
<a id="ace-XXX"></a>

### ACE-XXX: [タイトル（簡潔で検索しやすい表現）]

| フィールド | 値                                       |
| ---------- | ---------------------------------------- |
| Category   | [カテゴリ一覧](#カテゴリ一覧) のいずれか |
| Origin     | PR #XXX / Issue #YYY                     |
| Date       | YYYY-MM-DD                               |
| Helpful    | 0                                        |
| Harmful    | 0                                        |
| Status     | active                                   |

**Insight**: [知見の本質を1-2文で記述]

**Context**: [この知見が発見された状況・条件を記述]

**Action**: [推奨する具体的なアクション。可能であればコード例も含める]
```

### 記述ガイドライン

- **anchor**: 各エントリは見出し直前に `<a id="ace-XXX"></a>` を 1 行付与する。`XXX` は **エントリ ID を小文字化したもの**（新規は `ace-438-1` / `ace-i425-1`、旧エントリは `ace-001`。anchor 部分は常に小文字英数字＋ハイフン）。ファイルレベル参照（サブファイル単体）は常にファイル先頭に着地するため、anchor がなければ個別エントリへの誘導が成立しない。anchor 付与により他ドキュメントから `[ACE-438-1](path/to/playbook/<category>.md#ace-438-1)` 形式で**特定エントリに直接ジャンプ可能**になる。
- **参照リンク形式**: 他ドキュメントから ACE エントリを参照する場合は `[ACE-XXX](path/to/playbook/<category>.md#ace-XXX)` 形式に統一する（`<category>` はそのエントリの Category 値、`XXX` はエントリ ID の接頭辞 `ACE-` / `ace-` を除いた部分。新規は `438-1`、旧は 3 桁 `040`。label は `ACE-438-1`、anchor は `#ace-438-1`）。カテゴリが分からない場合は本ファイルの [索引テーブル](#エントリ一覧) で確認する。`[PLAYBOOK ACE-XXX]` / `[PLAYBOOK.md ACE-XXX]` 等の異なる label は使わない（[ACE-040](./playbook/process.md#ace-040) 語彙統一 / [ACE-024](./playbook/documentation-quality.md#ace-024) 用語衝突防止 の系。Origin: Issue [#425](https://github.com/feel-flow/ai-spec-driven-development/issues/425)）。
- **Insight**: 「何を学んだか」を簡潔に。1-2文。
- **Context**: 「どんな状況で発見したか」を記述。再現条件が明確であるほど価値が高い。
- **Action**: 「次回何をすべきか」を具体的に。コード例があると AIツールが直接適用しやすい。

---

## Helpful / Harmful カウンター運用

### カウンター更新タイミング

| タイミング                                     | 更新内容            |
| ---------------------------------------------- | ------------------- |
| ACE サイクルで既存エントリと重複する知見を発見 | Helpful +1          |
| 既存エントリの知見に従って問題を回避できた     | Helpful +1          |
| 既存エントリの知見に従ったが問題が発生した     | Harmful +1          |
| 既存エントリの内容が古くなっていると判明       | 検討の上 deprecated |

### エントリ品質の目安

| カウンター状態                           | 解釈                                       |
| ---------------------------------------- | ------------------------------------------ |
| `Helpful >= 5`                           | 高品質エントリ。PATTERNS.md への昇格を検討 |
| `Helpful >= 3, Harmful == 0`             | 良質なエントリ                             |
| `Harmful >= 3, Helpful < Harmful`        | deprecated 候補                            |
| `Helpful == 0, Harmful == 0`（90日以上） | 有効性未検証。次回関連タスクで意識的に検証 |

---

## ファイル分割ルール

Playbook が 800 行を超えた場合、以下のように分割する：

```
08-knowledge/
├── PLAYBOOK.md           ← 索引 + 運用ルール
└── playbook/               ← 実際に使用中のカテゴリ（新規カテゴリが増えたら追加）
    ├── process.md
    ├── documentation-quality.md
    ├── tooling.md
    ├── architecture.md
    ├── knowledge-management.md
    ├── security.md
    ├── coding.md
    ├── devops.md
    ├── documentation.md
    └── testing.md
```

分割時の手順：

1. カテゴリ別にエントリをサブファイルに移動
2. PLAYBOOK.md に索引テーブルを残す（エントリID + タイトル + 参照先）
3. 以降の新規追記は該当カテゴリのサブファイルに行う
4. Frontmatter の `ace_entry_count` は全エントリの合計を維持

### 新規カテゴリファイルのテンプレート

既存の `playbook/<category>.md` が無いカテゴリで初めてエントリを追記する場合、以下の内容で新規作成する：

```markdown
# PLAYBOOK — <カテゴリの日本語ラベル> (<category>)

> **Parent**: [PLAYBOOK.md](../PLAYBOOK.md) — 運用ルール・エントリテンプレート・ID規則・記述ガイドラインは親ファイルの SSOT を参照。
>
> 新規エントリは本ファイル末尾に追記し、[PLAYBOOK.md の索引テーブル](../PLAYBOOK.md#エントリ一覧)にも 1 行追加する。

---

## エントリ一覧

<a id="ace-XXX"></a>

### ACE-XXX: [タイトル]

...（以降は上記「エントリテンプレート」節と同じ）
```

作成後は本節冒頭の分割済みファイル一覧（ツリー図）にも追加し、[カテゴリ一覧](#カテゴリ一覧) 表に説明行が無ければ追記する。

---

## エントリ一覧

エントリ本体は Category 別に `playbook/` 配下のファイルへ分割されています。
新規エントリは該当カテゴリの `playbook/<category>.md` 末尾に追記し、下記索引テーブルにも 1 行追加してください。
エントリの記述テンプレートは [エントリテンプレート](#エントリテンプレート) を参照。

| エントリID | タイトル                                                                                                                                                                    | Category              | 参照先                                                                                       |
| ---------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------- | -------------------------------------------------------------------------------------------- |
| ACE-001    | クロスモデルレビューは単一AIモデルでは検出できない問題を発見する                                                                                                            | process               | [playbook/process.md#ace-001](./playbook/process.md#ace-001)                                 |
| ACE-002    | CLIフラグは実機の --help 出力と照合が必須                                                                                                                                   | tooling               | [playbook/tooling.md#ace-002](./playbook/tooling.md#ace-002)                                 |
| ACE-003    | bash スクリプトは macOS デフォルト環境（bash 3.2）でテストする                                                                                                              | devops                | [playbook/devops.md#ace-003](./playbook/devops.md#ace-003)                                   |
| ACE-004    | ドキュメントの動作説明は実装メカニズムと一致させる                                                                                                                          | process               | [playbook/process.md#ace-004](./playbook/process.md#ace-004)                                 |
| ACE-005    | 索引と実体を分離する委譲パターンでAIコンテキスト消費を抑える                                                                                                                | architecture          | [playbook/architecture.md#ace-005](./playbook/architecture.md#ace-005)                       |
| ACE-006    | サンプル付きテンプレファイルには⚠️SAMPLEバナーと固有化手順を必ず併設する                                                                                                    | tooling               | [playbook/tooling.md#ace-006](./playbook/tooling.md#ace-006)                                 |
| ACE-007    | Claude Code skill 内のツール参照は名称・subagent_type を実機 / system prompt で照合する                                                                                     | tooling               | [playbook/tooling.md#ace-007](./playbook/tooling.md#ace-007)                                 |
| ACE-008    | クロスリポジトリ操作する skill は全 gh コマンドに `--repo` 必須・mention は `@<assignee>` を使う                                                                            | tooling               | [playbook/tooling.md#ace-008](./playbook/tooling.md#ace-008)                                 |
| ACE-009    | 長時間 Orchestrator の失敗の真因は upstream Issue spec 曖昧さ — 探索型 refine が必要                                                                                        | process               | [playbook/process.md#ace-009](./playbook/process.md#ace-009)                                 |
| ACE-010    | Issue クローズ前は commit log でなく現在のファイル実体を grep 照合する — silent regression を検出する                                                                       | process               | [playbook/process.md#ace-010](./playbook/process.md#ace-010)                                 |
| ACE-011    | Prettier × markdownlint MD060 衝突は当該テーブルだけに `<!-- prettier-ignore -->` を付与する局所抑制で解く                                                                  | tooling               | [playbook/tooling.md#ace-011](./playbook/tooling.md#ace-011)                                 |
| ACE-012    | PR マージ・push 前は必ず `git status` でブランチを確認する（develop 直 push 事故防止）                                                                                      | process               | [playbook/process.md#ace-012](./playbook/process.md#ace-012)                                 |
| ACE-013    | 並列 reviewer の指摘は古い snapshot 由来の誤検知を含む — 実態 grep で双方向検証する                                                                                         | process               | [playbook/process.md#ace-013](./playbook/process.md#ace-013)                                 |
| ACE-014    | 索引文書は SSOT を子に集約し、自身は誘導と 1 行サマリのみ — 数値の重複は持たない                                                                                            | architecture          | [playbook/architecture.md#ace-014](./playbook/architecture.md#ace-014)                       |
| ACE-015    | 表を導入したら散文の主張を表に対して再読する — 「N 段階」「太字の領域」型の自己矛盾は人手レビューで見落とされる                                                             | documentation-quality | [playbook/documentation-quality.md#ace-015](./playbook/documentation-quality.md#ace-015)     |
| ACE-016    | Markdown の anchor link は label と URL の両方にフラグメントを書く — `\[text#anchor\]\(url\)` 形式は無効                                                                    | documentation-quality | [playbook/documentation-quality.md#ace-016](./playbook/documentation-quality.md#ace-016)     |
| ACE-017    | 並列 review agent は worktree を巻き戻す副作用を持ち得る — `git status` 監視と `git restore --source=HEAD` で復旧する                                                       | process               | [playbook/process.md#ace-017](./playbook/process.md#ace-017)                                 |
| ACE-018    | 横断的な番号・順序変更は着手前に grep で全 SSOT を列挙する                                                                                                                  | documentation-quality | [playbook/documentation-quality.md#ace-018](./playbook/documentation-quality.md#ace-018)     |
| ACE-019    | 既存ルール違反になる新パターンは「例外」として明示的に名乗らせる                                                                                                            | process               | [playbook/process.md#ace-019](./playbook/process.md#ace-019)                                 |
| ACE-020    | 自動コンテンツ生成ツールは自身のマーカー文字列を本文に含むドキュメントを破壊する                                                                                            | tooling               | [playbook/tooling.md#ace-020](./playbook/tooling.md#ace-020)                                 |
| ACE-021    | テンプレ配布リポでは「リポ自身が使うインフラ」と「テンプレ利用者が受け取る成果物」を物理的に分離する                                                                        | architecture          | [playbook/architecture.md#ace-021](./playbook/architecture.md#ace-021)                       |
| ACE-022    | 機能削除時は consumer だけでなく定数・型・ユーティリティも grep して取り残しを防ぐ                                                                                          | process               | [playbook/process.md#ace-022](./playbook/process.md#ace-022)                                 |
| ACE-023    | ドキュメント中の事実主張（PR/Issue 番号・ハッシュ・数値）は執筆時に 1 次情報で照合する                                                                                      | documentation-quality | [playbook/documentation-quality.md#ace-023](./playbook/documentation-quality.md#ace-023)     |
| ACE-024    | SSOT で確立した用語を再利用する前に既存定義との衝突を確認する                                                                                                               | documentation-quality | [playbook/documentation-quality.md#ace-024](./playbook/documentation-quality.md#ace-024)     |
| ACE-025    | スクリプトの「対象範囲」を文書化するときは glob 表現ではなく実装上の対象列挙方式まで踏み込む                                                                                | documentation-quality | [playbook/documentation-quality.md#ace-025](./playbook/documentation-quality.md#ace-025)     |
| ACE-026    | 同名関数が複数ファイルに併存する場合は機能対応表で並列説明する                                                                                                              | documentation-quality | [playbook/documentation-quality.md#ace-026](./playbook/documentation-quality.md#ace-026)     |
| ACE-027    | 配布対象ファイル内の行番号 hard-coded 参照は採用後に即陳腐化するため heading anchor 化する                                                                                  | documentation-quality | [playbook/documentation-quality.md#ace-027](./playbook/documentation-quality.md#ace-027)     |
| ACE-028    | 外部ツールの「現状」仕様を書くときは公式ドキュメントを WebFetch / WebSearch で必ず照合する                                                                                  | documentation-quality | [playbook/documentation-quality.md#ace-028](./playbook/documentation-quality.md#ace-028)     |
| ACE-029    | 外部ツール依存物（shell script の依存コマンド、shebang、インストーラオプション）を文書化するときは実体を読んで列挙する                                                      | documentation-quality | [playbook/documentation-quality.md#ace-029](./playbook/documentation-quality.md#ace-029)     |
| ACE-030    | 対応表で `⚠️` を多用したら判定軸自体が間違っているサイン                                                                                                                    | documentation-quality | [playbook/documentation-quality.md#ace-030](./playbook/documentation-quality.md#ace-030)     |
| ACE-031    | ドキュメントを書くときは配布境界に基づいて「想定読者」を意識する（採用者向け / コントリビューター向け / リポメンテナ向け）                                                  | documentation-quality | [playbook/documentation-quality.md#ace-031](./playbook/documentation-quality.md#ace-031)     |
| ACE-032    | 機能撤去型の改稿後は、残った value 主張・周辺記述・論理連鎖が全て成立しているか改めて読み直す                                                                               | documentation-quality | [playbook/documentation-quality.md#ace-032](./playbook/documentation-quality.md#ace-032)     |
| ACE-033    | 対応表で全行 / 全 cell が uniform になったら、表自体が情報を持っていないサイン                                                                                              | documentation-quality | [playbook/documentation-quality.md#ace-033](./playbook/documentation-quality.md#ace-033)     |
| ACE-034    | 実装中は implementation-notes.md を作業ブランチに並走させて spec 乖離・トレードオフ・判断理由を捕捉する                                                                     | process               | [playbook/process.md#ace-034](./playbook/process.md#ace-034)                                 |
| ACE-035    | 新規 process パターンを Playbook に追加するときは「ドッグフード + advisor / second opinion」で運用上の構造問題を検出する                                                    | process               | [playbook/process.md#ace-035](./playbook/process.md#ace-035)                                 |
| ACE-036    | 外部知見（SNS / ブログ / 社内 wiki）を Playbook に取り込む前に既存 ACE エントリ全件と grep 照合する                                                                         | knowledge-management  | [playbook/knowledge-management.md#ace-036](./playbook/knowledge-management.md#ace-036)       |
| ACE-037    | ACE エントリの新規追加は対応する運用手順（workflow / self-review / ace-cycle）への組み込みを同 PR で済ませる                                                                | knowledge-management  | [playbook/knowledge-management.md#ace-037](./playbook/knowledge-management.md#ace-037)       |
| ACE-038    | 「データ収集待ち」を要求する受入基準でも、ロールバック容易な変更は先行実装 + 試行中ステータス明記でフィードバックループを早める                                             | process               | [playbook/process.md#ace-038](./playbook/process.md#ace-038)                                 |
| ACE-039    | AI プロンプトテンプレに「分析観点リスト」と「分類カテゴリリスト」が並存する場合、新観点追加時はカテゴリ対応を観点側に明記する                                               | tooling               | [playbook/tooling.md#ace-039](./playbook/tooling.md#ace-039)                                 |
| ACE-040    | AI プロンプトテンプレ内で同概念を複数の語で表現すると AI 出力品質が下がる — 一次定義（SSOT）の語彙に統一する                                                                | process               | [playbook/process.md#ace-040](./playbook/process.md#ace-040)                                 |
| ACE-041    | マージ後 cleanup の未追跡ファイルガードに引っかかったら、独立した chore PR で .gitignore 追加して cleanup を継続する                                                        | process               | [playbook/process.md#ace-041](./playbook/process.md#ace-041)                                 |
| ACE-042    | テンプレファイル内の同一概念 placeholder は同一シンボル + 大文字で統一する — `XXX`/`NNN`/`xxx` 混在は AI/人のコピペ後置換漏れによる silent rot を誘発する                   | documentation         | [playbook/documentation.md#ace-042](./playbook/documentation.md#ace-042)                     |
| ACE-043    | 品質ゲート script の chain と文書の「統括内容」記述は drift する — 自然文サマリではなく実体 script 名で列挙する                                                             | documentation-quality | [playbook/documentation-quality.md#ace-043](./playbook/documentation-quality.md#ace-043)     |
| ACE-044    | review 指摘を取り込むスコープは「編集セクション境界」で判定する — 触ったセクション内の隣接 stale は同 PR、別ファイル / 別セクションは別 issue                               | process               | [playbook/process.md#ace-044](./playbook/process.md#ace-044)                                 |
| ACE-045    | 設計文書内の「mirror 付録（実体の参照用コピー）」は本体改稿で silent drift する — mirror を持つなら本体改稿で同期、または mirror を削って外部参照に置換                     | documentation-quality | [playbook/documentation-quality.md#ace-045](./playbook/documentation-quality.md#ace-045)     |
| ACE-046    | PR/Issue body 内の相対リンクは `pull/N/` または `issues/N/` 起点で展開される — リポローカルテンプレでは `blob/HEAD/` 絶対 URL を使い、配布版は plain text にする            | documentation-quality | [playbook/documentation-quality.md#ace-046](./playbook/documentation-quality.md#ace-046)     |
| ACE-441-1  | ドキュメントを走査するツールの正規表現を緩めるときは実ファイルで件数検証し、パターンを「実 ID の形」に制約する                                                              | testing               | [playbook/testing.md#ace-441-1](./playbook/testing.md#ace-441-1)                             |
| ACE-441-2  | pre-commit hook は正式品質ゲート（quality:local）の軽量サブセット — pr-ready 前に必ず full ゲートを回す                                                                     | process               | [playbook/process.md#ace-441-2](./playbook/process.md#ace-441-2)                             |
| ACE-443-1  | framework リポは自テンプレをドッグフードするため知見ベースは `docs-template/` 配下 — AI レビュアーの「docs-template→docs」パス提案は実在確認してから採否を決める            | documentation-quality | [playbook/documentation-quality.md#ace-443-1](./playbook/documentation-quality.md#ace-443-1) |
| ACE-445-1  | Claude 系レビュアーが「既存と整合的だから OK」と全員一致した箇所こそ cross-model レビューの出番 — 同系列の合意は正しさの証明ではない                                        | process               | [playbook/process.md#ace-445-1](./playbook/process.md#ace-445-1)                             |
| ACE-447-1  | 別ドキュメントへの anchor 付きリンクは実見出しの slug と一致させる — label↔URL ミラー（ACE-016）だけでは壊れたアンカーを作りうる                                            | documentation-quality | [playbook/documentation-quality.md#ace-447-1](./playbook/documentation-quality.md#ace-447-1) |
| ACE-447-2  | 配布物（docs-template/）内のリンクは配布ツリー外を指さない — ドッグフード絶対URLの相対化で `../../../` がツリーを脱出する                                                   | documentation-quality | [playbook/documentation-quality.md#ace-447-2](./playbook/documentation-quality.md#ace-447-2) |
| ACE-447-3  | 大規模 doc PR の cross-model レビューは clean verdict に収束しない — ゲートは「Critical 不在＋実 Important 全対応」、green を待ってループしない                             | process               | [playbook/process.md#ace-447-3](./playbook/process.md#ace-447-3)                             |
| ACE-449-1  | `set -e` 下の bash 関数は末尾を `[[ cond ]] && cmd` で終わらせない — cond 偽で関数が非ゼロを返し呼び出し元の errexit がスクリプトを無出力で殺す                             | tooling               | [playbook/tooling.md#ace-449-1](./playbook/tooling.md#ace-449-1)                             |
| ACE-449-2  | 「既定から外す」変更はデータの空化ではなく明示的なゲート条件で実装し、ドキュメントに書いたオプトイン手順はその場で回帰テストに固定する                                      | process               | [playbook/process.md#ace-449-2](./playbook/process.md#ace-449-2)                             |
| ACE-449-3  | 「設定駆動」を謳う config を編集する前に、そのキーが実際にスクリプトから読まれているか確認する — 読まれない飾りキーはハードコードとの同期注記を付ける                       | documentation-quality | [playbook/documentation-quality.md#ace-449-3](./playbook/documentation-quality.md#ace-449-3) |
| ACE-459-1  | git hook 環境から spawn するサブプロセス git は GIT\_\* を除去しないと実リポジトリを破壊する — テストフィクスチャの git init/commit が呼び出し元リポジトリを直撃した        | tooling               | [playbook/tooling.md#ace-459-1](./playbook/tooling.md#ace-459-1)                             |
| ACE-459-2  | linked worktree での並行開発は「メインと同じ」前提が3箇所で破れる — husky 不発・gitignore の symlink すり抜け・共有 config 汚染                                             | process               | [playbook/process.md#ace-459-2](./playbook/process.md#ace-459-2)                             |
| ACE-460-1  | git diff の出力をパスで分類するツールは `--no-renames` を付ける — rename 表記 `{old => new}` は拡張子判定とディレクトリ前方一致の両方をすり抜ける                           | tooling               | [playbook/tooling.md#ace-460-1](./playbook/tooling.md#ace-460-1)                             |
| ACE-462-1  | 安全ゲートをスキップするか判定するループでは、空文字・想定外入力を「危険側」ではなく「安全側（ゲート実行）」に倒す — `case $x in *[!0]*)` は空文字を「全ゼロ」と同一視する  | tooling               | [playbook/tooling.md#ace-462-1](./playbook/tooling.md#ace-462-1)                             |
| ACE-464-1  | 集約レポートの stale 混入は「削除」でなく「読む側を今回の実行計画にスコープ」して断つ                                                                                       | architecture          | [playbook/architecture.md#ace-464-1](./playbook/architecture.md#ace-464-1)                   |
| ACE-464-2  | cross-model レビューが実質的な新指摘を出し続けるなら各指摘を patch せず「設計を疑え」— 停止は「新規 Critical/Important 不在」                                               | process               | [playbook/process.md#ace-464-2](./playbook/process.md#ace-464-2)                             |
| ACE-464-3  | 複数経路が同じ untrusted トークンを消費するなら消費地点ごとの silent skip でなく入口で一度 fail-loud 検証する                                                               | security              | [playbook/security.md#ace-464-3](./playbook/security.md#ace-464-3)                           |
| ACE-465-1  | パース後どこからも読まれないデッドフラグ/デッド設定は「実装 vs 削除」を既定動作との重複と命名スキーマの整合で判定する                                                       | architecture          | [playbook/architecture.md#ace-465-1](./playbook/architecture.md#ace-465-1)                   |
| ACE-465-2  | cross-model が指摘した「互換性破壊」も、修正案が Issue の明示的決定と矛盾するなら盲従せず実害（呼び出し元の実在）を検証して判断する                                         | process               | [playbook/process.md#ace-465-2](./playbook/process.md#ace-465-2)                             |
| ACE-469-1  | opt-in 公開ゲートの fail-safe は構造破壊入力（閉じデリミタ欠落）で破れる — パーサは走査境界を先に確定し、壊れた構造は skip でなく fail-loud に回す                          | security              | [playbook/security.md#ace-469-1](./playbook/security.md#ace-469-1)                           |
| ACE-469-2  | コピーして使う雛形ファイルに opt-in フラグの「許可値」を焼き込まない — 雛形経由で全新規文書が公開既定になる                                                                 | security              | [playbook/security.md#ace-469-2](./playbook/security.md#ace-469-2)                           |
| ACE-2-1    | `file://` で開く自己完結HTMLはロジックを「クラシックスクリプト＋globalThis 代入」で切り出す — ESモジュールは file:// の CORS で起動が壊れる                                 | coding                | [playbook/coding.md#ace-2-1](./playbook/coding.md#ace-2-1)                                   |
| ACE-2-2    | 複数箇所に描画されるコンポーネントの初期化は querySelectorAll＋per-element try/catch で隔離する — 単数 querySelector と無ガード dereference は「1つ壊れると黙って全滅」する | coding                | [playbook/coding.md#ace-2-2](./playbook/coding.md#ace-2-2)                                   |
| ACE-2-3    | 同一ブランチで並行する Claude セッション（特にクラッシュ由来の孤児プロセス）を検知したら、闇雲な kill でなくアプリ完全再起動で一掃する                                      | process               | [playbook/process.md#ace-2-3](./playbook/process.md#ace-2-3)                                 |
| ACE-7-1    | pre-push 品質ゲート起因の修正は、単体 check だけでなく SKIP なしの実 push で完了判定する                                                                                    | process               | [playbook/process.md#ace-7-1](./playbook/process.md#ace-7-1)                                 |
| ACE-12-1   | セルフレビュー指摘の修正は commit してから ready/merge する — Edit ツールはファイルを書き換えるだけで commit しない                                                         | process               | [playbook/process.md#ace-12-1](./playbook/process.md#ace-12-1)                               |
| ACE-12-2   | 派生数値を表示する UI は data-属性のパースを検証し、NaN/0/負値を握りつぶさず警告付きフォールバックする                                                                      | coding                | [playbook/coding.md#ace-12-2](./playbook/coding.md#ace-12-2)                                 |
| ACE-16-1   | ドキュメント分割は、それを参照するスクリプト・手順書のファイルスコープ前提を静かに陳腐化させる                                                                              | documentation-quality | [playbook/documentation-quality.md#ace-16-1](./playbook/documentation-quality.md#ace-16-1)   |
| ACE-16-2   | 単一ファイルの構造化パースを前提にした CLI ツールは、そのファイルが複数ファイルに分割されると誤診断や無警告の空集計に陥る                                                   | coding                | [playbook/coding.md#ace-16-2](./playbook/coding.md#ace-16-2)                                 |
| ACE-16-3   | 大規模 diff の PR 自己レビューでレビュー agent が stall / API 切断した場合、resume を繰り返すより新規 agent へのスコープ限定リランが速い                                    | process               | [playbook/process.md#ace-16-3](./playbook/process.md#ace-16-3)                               |

## Changelog

### [1.39.0] - 2026-07-06

#### 追加

- ACE-16-1: ドキュメント分割は、それを参照するスクリプト・手順書のファイルスコープ前提を静かに陳腐化させる — PR #16（Issue #15）で PLAYBOOK.md を分割した際、Codex CLI が ace-curate.md の重複チェック範囲・git add 例・存在しないテンプレ参照を検出した経験から抽出
- ACE-16-2: 単一ファイルの構造化パースを前提にした CLI ツールは、そのファイルが複数ファイルに分割されると誤診断や無警告の空集計に陥る — check-category-size.ts / ace-reuse-report.ts を playbook/ 分割対応させた際、Toolkit（silent-failure-hunter）が指摘したエラー誤分類・0件サイレント成功のリスクから抽出
- ACE-16-3: 大規模 diff の PR 自己レビューでレビュー agent が stall / API 切断した場合、resume を繰り返すより新規 agent へのスコープ限定リランが速い — PR #16 の自己レビューで Toolkit agent が 2 回連続で stall した際、スコープを絞った新規 agent で解決した経験から抽出

### [1.38.0] - 2026-07-06

#### 変更

- PLAYBOOK.md が 800 行の警告閾値を大幅超過（2392 行 / 73 エントリ）したため、Issue #15（PR #16）で全 73 エントリを Category 別に `playbook/*.md` へ分割。本体は索引テーブル + 運用ルールのみに縮小（612 行）。`check-category-size.ts` / `ace-reuse-report.ts` を分割レイアウト自動検出に対応させた

### [1.37.0] - 2026-07-06

#### 追加

- ACE-12-1: セルフレビュー指摘の修正は commit してから ready/merge する — PR #12 で Edit 修正を commit せずに squash merge してしまい、develop に未反映のまま残った事故（PR #14 で修正）から抽出
- ACE-12-2: 派生数値を表示する UI は data-属性のパースを検証し、NaN/0/負値を握りつぶさず警告付きフォールバックする — PR #12 の Funnel216 で Codex CLI と Toolkit の両方が独立に指摘した silent failure から抽出

### [1.36.0] - 2026-07-03

#### 追加

- ACE-7-1: pre-push 品質ゲート起因の修正は、単体 check だけでなく SKIP なしの実 push で完了判定する — PR #7 / Issue #3 で `INTERNAL.md` 整形崩れを直し、`npx prettier --check INTERNAL.md` / `npm run quality:local` / SKIP なし `git push` まで通した経験から抽出

### [1.35.0] - 2026-07-03

#### 追加

- ACE-2-1: `file://` 自己完結HTMLはロジックをクラシックスクリプト＋globalThis で切り出す（ESモジュールは file:// CORS で起動が壊れる） — PR #2 のスライドデッキで、cart-model を分離テストしつつオフライン起動を保った経験から抽出
- ACE-2-2: 複数箇所に描画されるコンポーネント init は querySelectorAll＋per-element try/catch で隔離（単数 querySelector と無ガード参照は「1つ壊れると黙って全滅」） — PR #2 で silent-failure-hunter が Critical 検出した経験から抽出
- ACE-2-3: 同一ブランチで並行する Claude セッション/孤児プロセスは闇雲な kill でなくアプリ完全再起動で一掃 — PR #2 実装中にクラッシュ由来の孤児が同一ブランチへコミットを積み続けた経験から抽出

### [1.34.0] - 2026-07-03

#### 追加

- ACE-469-1: opt-in 公開ゲートの fail-safe は構造破壊入力（閉じデリミタ欠落）で破れる — PR #469 の sync-to-public.mjs で、frontmatter パーサが閉じデリミタ未確認のまま値を採用し本文走査で internal 文書が公開されうる欠陥を Toolkit + Codex が独立検出した経験から抽出
- ACE-469-2: コピーして使う雛形ファイルに opt-in フラグの許可値を焼き込まない — PR #469 の一括 visibility 付与で spec-template.md に public を書き、雛形コピー経由で新規 spec が公開既定になる漏洩リスクを Codex が Critical 検出した経験から抽出

#### カウンター更新

- ACE-449-2 (Helpful 0→1): FRONTMATTER_GUIDE §5.5 の記法例（インラインコメント）が同期スクリプトを fail させる乖離を検出し、例文をパーサ対応 + 回帰テストで固定した再適用
- ACE-464-3 (Helpful 0→1): sync-to-public.mjs の不正 visibility / 壊れた frontmatter 検証を「1st pass で全分類 → 書き込みゼロで exit 1」の入口 fail-loud 集約として設計した再適用

### [1.33.0] - 2026-07-03

#### 追加

- ACE-465-1: パース後どこからも読まれないデッドフラグ / デッド設定は「実装 vs 削除」を既定動作との重複と命名スキーマの整合で判定する — PR #465 で `multi-agent.sh --delegate-toolkit` を、既定の分散プランと重複し `toolkit_delegation` のキー名も perspective 実体と不一致だったため削除した経験から抽出
- ACE-465-2: cross-model が指摘した「互換性破壊」も、修正案が Issue の明示的決定と矛盾するなら盲従せず実害（呼び出し元の実在）を検証して判断する — PR #465 で Codex のみが breaking change を指摘したが、互換レイヤー案は Issue #451 案2 と矛盾し呼び出し元も実在しないため意図的 breaking change として明記した経験から抽出

#### カウンター更新

- ACE-445-1 (Helpful 4→5): Toolkit 4 観点が pass した breaking change を Codex（cross-model）のみが検出
- ACE-449-3 (Helpful 0→1): `toolkit_delegation` という別の「読まれない飾りキー」を削除して実態と一致させた

### [1.32.0] - 2026-07-03

#### 追加

- ACE-464-1: 集約レポートの stale 混入は「削除」でなく「読む側を今回の実行計画（EXECUTION_PLAN）にスコープ」して断つ — PR #464 で multi-agent.sh のレポートが glob で前回 perspective を混入する問題を、削除ではなくプラン駆動の読み取りに転換して解決した経験から抽出
- ACE-464-2: cross-model レビューが実質的な新指摘を出し続けるなら各指摘を patch せず設計を疑え・停止は「新規 Critical/Important 不在」 — PR #464 で Codex を 9 round 回し、削除ベース設計への指摘が収束せずプラン駆動へピボットして構造的に解消した経験から抽出
- ACE-464-3: 複数経路が同じ untrusted トークンを消費するなら消費地点ごとの silent skip でなく入口で一度 fail-loud 検証する — PR #464 で traversal ガードが read/clear のみで write 経路が無防備＋silent continue が malformed plan を隠蔽していた指摘から抽出

#### カウンター更新

- ACE-001 (Helpful 7→8): Toolkit が pass した設計を Codex が traversal/stale 等で反復検出
- ACE-445-1 (Helpful 3→4): Claude 系 Toolkit 全 pass 箇所を cross-model が指摘
- ACE-447-3 (Helpful 0→1): 9 round の cross-model を「新規 Critical/Important 不在」で停止判断（code PR へ適用）

### [1.31.0] - 2026-07-02

#### 追加

- ACE-462-1: 安全ゲートをスキップするか判定するループでは空文字・想定外入力を安全側（ゲート実行）に倒す — PR #462 で pre-push の削除 push スキップ判定 `case *[!0]*` が空 local_sha を「全ゼロ」と同一視しゲート回避する fail-open を Toolkit silent-failure-hunter が検出した経験から抽出

### [1.30.0] - 2026-07-02

#### 追加

- ACE-459-1: git hook 環境から spawn するサブプロセス git は GIT\_\* を除去しないと実リポジトリを破壊する — PR #459 で worktree からの push 中に pre-push → vitest → テストフィクスチャの git が GIT_DIR を継承し、実ブランチへのコミット混入・core.bare=true 書き換えが発生した経験から抽出
- ACE-459-2: linked worktree での並行開発は「メインと同じ」前提が3箇所で破れる — PR #459 で husky 不発（.husky/\_ untracked）・gitignore の symlink すり抜け・共有 config 汚染を1セッションで全部踏んだ経験から抽出
- ACE-460-1: git diff の出力をパスで分類するツールは --no-renames を付ける — PR #460 の review-level.sh で rename 表記がセンシティブパス判定をすり抜ける実バグを Toolkit pr-test-analyzer が実測検出した経験から抽出

#### 更新

- ACE-445-1（同系列レビュアーの全員一致こそ cross-model の出番）Helpful: 2 → 3 — PR #459 で Claude code-reviewer「指摘なし」の乖離計算バグを Codex が Critical 検出、PR #460 では逆に Codex code-reviewer PASS の rename バグを Claude pr-test-analyzer が検出。cross-model の価値が双方向であることを補強

### [1.29.0] - 2026-07-02

#### 追加

- ACE-449-1: `set -e` 下の bash 関数は末尾を `[[ cond ]] && cmd` で終わらせない — PR #449 で `multi-agent.sh --dry-run` が完全無出力で死ぬ既存バグ（`apply_task_defaults`）を発見・修正し、silent-failure-hunter の水平走査で `load_config` にも同一クラスが残存（実機再現）した経験から抽出
- ACE-449-2: 「既定から外す」変更はデータの空化ではなく明示的なゲート条件で実装し、ドキュメントに書いたオプトイン手順はその場で回帰テストに固定する — PR #449 で Copilot の review perspectives 空化が `--cli copilot-cli` オプトインを無言 no-op にし、Codex cross-model が検出。ゲート実装 + 空プラン exit 1 + 9 テスト固定で解消した経験から抽出
- ACE-449-3: 「設定駆動」を謳う config を編集する前に、そのキーが実際にスクリプトから読まれているか確認する — PR #449 で `agent-config.yaml` の perspectives が実装から一切読まれない飾りキー（実体はスクリプト内ハードコード + `review-config.yaml` は symlink）と判明した経験から抽出

#### 更新

- ACE-445-1（同系列レビュアーの全員一致こそ cross-model の出番）Helpful: 1 → 2 — PR #449 で Claude 系 code-reviewer が「信頼度80以上の問題なし」とした copilot オプトイン no-op を、Codex（gpt-5.4）の code-reviewer / silent-failure-hunter が Critical として独立検出した事例として補強

### [1.28.0] - 2026-06-23

#### 追加

- ACE-447-1: 別ドキュメントへの anchor 付きリンクは実見出しの slug と一致させる — label↔URL ミラー（ACE-016）だけでは壊れたアンカーを作りうる — PR #447 で Issue テンプレの `PATTERNS.md#エラーハンドリング` が実見出し `## 3. エラーハンドリング`（slug `#3-エラーハンドリング`）と不一致でリンク切れになり Codex code-reviewer が検出した経験から抽出
- ACE-447-2: 配布物（docs-template/）内のリンクは配布ツリー外を指さない — ドッグフード絶対URLの相対化で `../../../` がツリーを脱出する — PR #447 で配布側 Issue テンプレの撤退コスト参照が `../../../docs/DESIGN_PRINCIPLES.md` となり「配布物が自己完結しない」と Codex が検出した経験から抽出
- ACE-447-3: 大規模 doc PR の cross-model レビューは clean verdict に収束しない — ゲートは「Critical 不在＋実 Important 全対応」、green を待ってループしない — PR #447 で Codex を3ラウンド回し毎回 REJECTED（Critical=0・doc 整合 nit のみ）だった経験から抽出

#### 更新

- ACE-445-1（同系列レビュアーの全員一致こそ cross-model の出番）Helpful: 0 → 1 — PR #447 で「5 観点」表記が実 6 項目という数え違いが opus 全ブランチレビュー（同系列）を通過した一方、Codex cross-model の comment-analyzer / code-reviewer が独立検出した事例として補強

### [1.27.0] - 2026-06-19

#### 追加

- ACE-445-1: Claude 系レビュアーが「既存と整合的だから OK」と全員一致した箇所こそ cross-model レビューの出番 — 同系列の合意は正しさの証明ではない — PR #445 で subagent task レビュー ×2 + 最終 opus レビューが全員承認し opus は明示的に修正に反対した loose な `Number.parseInt` を、Codex (gpt-5.4) の silent-failure-hunter / code-reviewer が入力検証ギャップ（`"800abc"`→800 等）として検出。共有ヘルパー `parsePositiveIntEnv` に抽出し `/^[0-9]+$/` で厳密化した経験から抽出

#### 更新

- ACE-001（異なる AI モデルは異なるカテゴリの問題を検出）Helpful: 6 → 7 — PR #445 で Claude 系 3 レビュー（subagent task ×2 + opus 最終 whole-branch）が全員 APPROVED した loose parseInt を Codex が単独検出。同系列レビューの全員一致が cross-model の出番を示すシグナルだった事例として補強

### [1.26.0] - 2026-05-30

#### 追加

- ACE-443-1: framework リポは自テンプレをドッグフードするため知見ベースは `docs-template/` 配下 — AI レビュアーの「docs-template→docs」パス提案は実在確認してから採否を決める — PR #443 で Gemini が `.cursorrules`/`AGENTS.md` の `docs-template/...` 参照を `docs/...` に変更提案したが、本リポに `docs/08-knowledge/` が不在でリンク切れになるため `ls` 確認の上で不採用とした経験から抽出

#### 更新

- ACE-018（横断変更は着手前に grep で全 SSOT を列挙）Helpful: 3 → 4 — PR #443 で ACE 採番ポインタを `.cursorrules`/`AGENTS.md` に追加したが repo 自身の `.github/copilot-instructions.md` を取りこぼし、Toolkit code-reviewer が Warning 検出。同セッション内で advisor（#441 で AI_GIT_WORKFLOW/CLAUDE.md）・user（Codex/AGENTS.md）に続く 3 度目の「全サーフェス列挙漏れ」で、着手前 grep 列挙の運用徹底の重要性を再確認
- ACE-016（anchor link は label と URL の両方に書く / explicit anchor で slug 変更耐性）Helpful: 3 → 4 — PR #443 で §4 見出しリネームに伴う inbound link 切れを explicit anchor `<a id="ace-ops-template">` 付与で予防（全角括弧で auto-slug が脆いケース、explicit anchor 適用の 3 例目）。advisor が編集前に予防的指摘
- ACE-014（索引文書は SSOT を子に集約）Helpful: 3 → 4 — PR #443 で採番メカニクスを ACE_SETUP §4 + PLAYBOOK §エントリID規則 の SSOT のみに置き、AGENTS.md/.cursorrules/SETUP\_\* はポインタに統一。grep で新規ポインタファイルへの非重複（DRY）を検証

### [1.25.0] - 2026-05-30

#### 追加

- ACE-441-1: ドキュメントを走査するツールの正規表現を緩めるときは実ファイルで件数検証し、パターンを「実 ID の形」に制約する — PR #441 で ACE 検出正規表現を緩めた際、code fence 内のエントリテンプレ `### ACE-XXX:` を誤検出して実 PLAYBOOK 集計が 46→47 になり、実ファイル検証ステップで捕捉した経験から抽出（PR スコープ式 ID の初適用エントリ）
- ACE-441-2: pre-commit hook は正式品質ゲート（quality:local）の軽量サブセット — pr-ready 前に必ず full ゲートを回す — PR #441 で markdownlint hook は全 commit 0 error だったが `quality:local` の `format:md:check`（prettier）が 3 ファイルで落ちた経験から抽出

#### 更新

- ACE-016（anchor link は label と URL の両方に書く）Helpful: 2 → 3 — PR #441 でマージ方針 SSOT リンク（ace-cycle.md / ace-curate.md / AI_GIT_WORKFLOW.md の「§運用パターン（マージ方針）」）が `#` フラグメント無しのファイルリンクで先頭着地する欠陥を Toolkit comment-analyzer と Copilot が独立検出。全角括弧で auto-slug が脆いため explicit anchor `<a id="ace-merge-policy">` を付与して解消（ACE-016 の explicit anchor 適用の 2 例目）
- ACE-018（横断 grep で SSOT 列挙）Helpful: 2 → 3 — PR #441 でマージ方針反転の残骸スイープを「編集した 5 ファイル」に限定したところ、advisor が AI_GIT_WORKFLOW.md / CLAUDE.md の取りこぼしを検出。元の ACE-012 carve-out が適用された 5 サイトと同じ全集合をリポジトリ全体 grep で列挙すべきだった事例（ACE-018 の指摘構造と完全一致）
- ACE-042（テンプレ placeholder の符号統一）Helpful: 0 → 1 — PR #441 で参照リンク形式の「`XXX` はエントリ ID をそのまま使用。新規は `ace-438-1`」記述が `[ACE-ace-438-1](#ace-ace-438-1)` の接頭辞重複を招くと Gemini が指摘。placeholder `XXX` の置換対象（接頭辞 `ACE-`/`ace-` を除いた部分）を明示して解消

### [1.24.0] - 2026-05-20

#### 更新

- ACE-016（anchor link は label と URL の両方に書く）Helpful: 1 → 2 — PR #438 で `.github/ISSUE_TEMPLATE/bug.md` L32（`[PATTERNS.md#エラーハンドリング](.../PATTERNS.md)`）と `infra.md` L26（`[ARCHITECTURE.md#インフラ](.../ARCHITECTURE.md)`）の「ラベルに `#anchor` を含むのに URL 側にフラグメント欠落」パターンを **Copilot review が「ACE-016 で言及されているパターン」と PLAYBOOK エントリ名を明示引用して指摘** した事例。Gemini Code Assist も独立に同じ 2 箇所 + `feature.md` L22/L23 の placeholder 形 `#該当セクション` を medium 指摘し、AI レビューワー（Copilot/Gemini）が PLAYBOOK を内化して同パターンを継続検出する運用が確立
- ACE-046（PR/Issue body 内の相対リンクは絶対 URL 化）Helpful: 0 → 1 — PR #437（PR テンプレ 4 箇所）と同一の `blob/HEAD/` 絶対 URL 化方針を PR #438 で `.github/ISSUE_TEMPLATE/` 配下 16 箇所に **機械的に再適用** した事例。`grep -rn '\.\./\.\./docs' .github/ISSUE_TEMPLATE/` → 0 件 / `grep -rn 'blob/HEAD/' .github/ISSUE_TEMPLATE/` → 16 件で受け入れ条件を実証ベースで確認し、子 Issue #436 を一発でクローズ。同一知見が複数 PR（#437 と #438）で再利用された事例として補強

### [1.23.0] - 2026-05-20

#### 追加

- ACE-046: PR/Issue body 内の相対リンクは `pull/N/` または `issues/N/` 起点で展開される — リポローカルテンプレでは `blob/HEAD/` 絶対 URL を使い、配布版は plain text にする — PR #437 で `.github/pull_request_template.md` の 4 箇所を絶対 URL 化した経験 + HEAD リクエスト実証データ（`repo/docs/X.md` は 404、`blob/HEAD/docs/X.md` は 200）から抽出

#### 更新

- ACE-001（クロスモデルレビュー）Helpful: 5 → 6 — PR #437 で Toolkit code-reviewer は「Critical/Important なし、承認推奨」だったが Gemini Code Assist が medium 2 件（L39 絶対 URL 化漏れ + L54 リンクテキスト一貫性）を独立検出。Toolkit 単独では catch できない漏れを Gemini が補完した事例で、auto-attach 経路の費用対効果を再確認
- ACE-044（review 指摘スコープを編集セクション境界で判定）Helpful: 1 → 2 — PR #431 で `../docs/` 指摘を「pre-existing で L15/L54 を巻き込む」として別 Issue #430 / #433 系に分割した判定が PR #437 で本格対応として完遂。「別 Issue 化判定 → 後続 PR で纏めて対応」のサイクルが機能した事例として補強

### [1.22.0] - 2026-05-20

#### 追加

- ACE-045: 設計文書内の「mirror 付録（実体の参照用コピー）」は本体改稿で silent drift する — mirror を持つなら本体改稿で同期、または mirror を削って外部参照に置換 — PR #431 で `docs/NO_GITHUB_ACTIONS_MIGRATION_DESIGN.md` 付録 A が本体 PR テンプレ簡略化と drift し Toolkit code-reviewer I1 (88%) が検出した経験から抽出

#### 更新

- ACE-001（クロスモデルレビュー）Helpful: 4 → 5 — PR #431 で Toolkit comment-analyzer (Suggestion 4 件) + Toolkit code-reviewer (Critical C1 + Important I1) + Copilot (3 inline comments) + Gemini Code Assist (org 設定で auto-attach、2 inline comments) の **4 系統が独立検出**。Gemini auto-attach により追加コストなしでレビュースタックが拡張された事例
- ACE-014（索引文書 SSOT 集約）Helpful: 2 → 3 — PR #431 で `quality:local` の chain 列挙を **README + PR テンプレ + 付録 A の 3 箇所**に持っていた SSOT 違反を、`§3.3` 1 箇所に集約 + 他 2 箇所を参照型に整理した事例。Related に [ACE-045](./playbook/documentation-quality.md#ace-045) を追加
- ACE-016（anchor link は label と URL の両方に書く）Helpful: 0 → 1 — PR #431 で `[\`docs/...\` §3.3](../docs/...)`が label に`§3.3`を含むが URL に`#anchor`欠落のパターンを Toolkit code-reviewer C1 (95%) が再検出。fix は`<a id="quality-local-detail"></a>`を §3.3 見出し直前に付与し、参照側を`#quality-local-detail` で固定（PLAYBOOK 外で初適用）。explicit anchor 採用で heading slug 変更（日本語 / コードフェンス / コロン混在）への耐性も獲得
- ACE-044（review 指摘スコープを編集セクション境界で判定）Helpful: 0 → 1 — PR #431 で 2 種類のスコープ判定をドッグフード: (a) Gemini の `../docs/` 相対パス指摘は touched ファイル内 (L28) だが pre-existing で L15/L54 を巻き込むため **spawn task で別 Issue 化**、(b) Appendix A drift は別ファイルだが **「mirror であることが明示」carve-out** で同 PR 内 fix commit に統合（[ACE-045](./playbook/documentation-quality.md#ace-045) Action 2 として運用ルール化）

### [1.21.0] - 2026-05-20

#### 追加

- ACE-043: 品質ゲート script の chain と文書の「統括内容」記述は drift する — 自然文サマリではなく実体 script 名で列挙する — PR #429 で `quality:local` の chain に `build:spec-index` を追加した際、`FRONTMATTER_GUIDE.md §2` 表 / `NO_GITHUB_ACTIONS_MIGRATION_DESIGN.md §3.2-3.3` の自然文サマリ記述が drift しており PR #416 review が pre-existing 誤記として検出 (Issue #417) した経験から抽出
- ACE-044: review 指摘を取り込むスコープは「編集セクション境界」で判定する — 触ったセクション内の隣接 stale は同 PR、別ファイル / 別セクションは別 issue — PR #429 で Toolkit comment-analyzer が同 §3.2-3.3 内の W1 / W2（pre-existing）と README.md:74 / PR テンプレ:28（S2/S3）を検出し、3 段階のスコープ判定で前者を同 PR fix commit、後者を #430 で別対応とした経験から抽出

#### 更新

- ACE-025（スクリプトの対象範囲を実装列挙で書く）Helpful: 0 → 1 — PR #429 で「不在で no-op」のような慣用語ではなく「specs=0 で `dist/spec-index.json` を空索引として書き出し exit 0」と実装挙動を字面で書く事例として補強。Related に [ACE-043](./playbook/documentation-quality.md#ace-043) を追加

### [1.20.0] - 2026-05-20

#### 追加

- ACE-042: テンプレファイル内の同一概念 placeholder は同一シンボル + 大文字で統一する — PR #428 で `<a id="ace-xxx">` / `### ACE-XXX:` / `<a id="ace-NNN">` の 3 種混在を Copilot + Gemini が独立に placeholder rot リスク / 主語曖昧さの異なる切り口で検出した経験から抽出

#### 更新

- ACE-001（クロスモデルレビュー）Helpful: 3 → 4 — PR #428 で Toolkit code-reviewer（Changelog 同期違反 + 表セル幅）/ Toolkit comment-analyzer（SSOT 違反 4 ファイル）/ Copilot（placeholder 符号統一）/ Gemini（主語曖昧さ）の 4 モデルが互いに重ならない構造問題を独立検出
- ACE-014（索引と実体の SSOT 集約）Helpful: 1 → 2 — PR #428 で 2 種類の SSOT 違反を同時検出（(a) 同じ anchor 命名規則を 4 文書に重複、(b) frontmatter `version` を bump して Changelog 項目を追加し忘れた索引-実体の同期漏れ）
- ACE-018（横断 grep で SSOT 列挙）Helpful: 1 → 2 — PR #428 で受入基準 2 文書だけ列挙したが advisor が「実 mutation point である `.claude/commands/ace-curate.md` の anchor テンプレも更新しないと silent rot」と指摘 → enforcement 点列挙が不足していた事例
- ACE-035（ドッグフード + advisor）Helpful: 1 → 2 — PR #428 で着手後 advisor を呼び、(a) ace-curate.md の mutation point ギャップ、(b) implementation-notes 取り扱い、(c) anchor の手動 navigation 検証必要性 の 3 件を pre-substantive で発見

### [1.19.0] - 2026-05-20

#### 追加

- ACE-001〜041 の各エントリ直前に explicit anchor (`<a id="ace-NNN"></a>`) を 41 件付与（Issue #425）
- エントリテンプレート / 記述ガイドラインに anchor 命名規則を追加（小文字 + ハイフン + 3 桁ゼロパディング）
- 他ドキュメントからの ACE 参照を `[ACE-NNN](path/to/PLAYBOOK.md#ace-nnn)` 形式に統一（旧 3 形式を撤去）

### [1.18.0] - 2026-05-20

#### 追加

- ACE-038: 「データ収集待ち」を要求する受入基準でも、ロールバック容易な変更は先行実装 + 試行中ステータス明記でフィードバックループを早める — PR #423 で Issue #421 受入基準（5 PR 運用待ち）を 1 行 diff + 試行中明記の組み合わせで先行実装した経験から抽出
- ACE-039: AI プロンプトテンプレに「分析観点リスト」と「分類カテゴリリスト」が並存する場合、新観点追加時はカテゴリ対応を観点側に明記する — PR #423 で Gemini Code Assist が「観点 7 のカテゴリ対応が L62 リストに無い」と検出した medium 指摘から抽出
- ACE-040: AI プロンプトテンプレ内で同概念を複数の語で表現すると AI 出力品質が下がる — 一次定義（SSOT）の語彙に統一する — PR #423 で「spec 乖離 / 逸脱 / 変更した点」の 3 表記揺れが comment-analyzer S3 で検出された経験から抽出。ACE-024 の dual
- ACE-041: マージ後 cleanup の未追跡ファイルガードに引っかかったら、独立した chore PR で .gitignore 追加して cleanup を継続する — PR #423 cleanup 中に `.codex/config.toml` 未追跡で止まり chore PR #427 で解消した経験から抽出

#### 更新

- ACE-035（ドッグフード + advisor）Helpful: 0 → 1 — PR #423 description で「採用しなかった選択肢（5 PR 待ち）」「ロールバック条件」を明記したことが観点 7 用 raw material のドッグフードとして機能した実例

### [1.17.0] - 2026-05-19

#### 追加

- ACE-035: 新規 process パターンを Playbook に追加するときは「ドッグフード + advisor / second opinion」で運用上の構造問題を検出する — PR #420 でドッグフードした implementation-notes.md の扱い (a) → (b) pivot 経験から抽出。advisor を呼ばずにマージしていたら develop ルートで構造的衝突が起きていた具体例
- ACE-036: 外部知見（SNS / ブログ / 社内 wiki）を Playbook に取り込む前に既存 ACE エントリ全件と grep 照合する — Anthropic エンジニア公開プロンプトを ACE-034 として取り込む際の照合手順から抽出。ACE-018（自リポ横断 grep）と相補的
- ACE-037: ACE エントリの新規追加は対応する運用手順（workflow / self-review / ace-cycle）への組み込みを同 PR で済ませる — PR #420 で Playbook + git-workflow + ace-cycle を同時改稿した経験と Copilot 整合性指摘から抽出

#### 更新

- ACE-001（クロスモデルレビュー）Helpful: 2 → 3 — PR #420 で Copilot（semantic 矛盾検出） + Gemini Code Assist（SSOT 同期検出）の役割分担を観察、別カテゴリ問題が並列レビューで発見された

### [1.16.0] - 2026-05-19

#### 追加

- ACE-034: 実装中は implementation-notes.md を作業ブランチに並走させて spec 乖離・トレードオフ・判断理由を捕捉する — Anthropic エンジニア公開実装プロンプト（"keep a running implementation-notes file with decisions / changes / tradeoffs"）と本リポ Playbook (ACE-001〜033) を grep 照合した結果未抽出と判明。コミット diff に残らない in-flight な判断ログを並走させることで ACE Phase 1 Generate の入力品質を底上げする（ACE-009 / ACE-023 / ACE-032 を補強）

### [1.15.0] - 2026-05-19

#### 追加

- ACE-031: ドキュメントを書くときは配布境界に基づいて「想定読者」を意識する — PR #416 で frontmatter ガイドが「採用者向け」を謳いつつ配布境界 P2 外の MCP サーバーを value 主張として紹介していた事例。配布境界と想定読者の不一致が判明（ACE-021 を補強）
- ACE-032: 機能撤去型の改稿後は、残った value 主張・周辺記述・論理連鎖が全て成立しているか改めて読み直す — PR #416 で MCP value 撤去後に「AI ツールが索引で絞り込む」value 主張だけが宙に浮き、`MCP test` 記述が周辺取り残しになり、`§5.4.2` 「AI 提供用」表現が `§2.1` と矛盾した事例（ACE-022 を補強）
- ACE-033: 対応表で全行 / 全 cell が uniform になったら、表自体が情報を持っていないサイン — PR #416 の §7.1 表が MCP 行撤去後に 5 行中 4 行 ✅ uniform になり情報量が薄くなった事例。共通項を 1 文に集約し差別化情報のみ表にする（ACE-026 / ACE-030 を補強）

#### 更新

- ACE-023: Helpful +1（PR #416 で MCP 関連の事実主張を撤去する際、`mcp/package.json` の依存宣言まで一次情報照合したことで unused `js-yaml` 依存を発見、Issue #418 を起票）
- ACE-029: Helpful +1（PR #416 で MCP value 撤去時に `mcp/src/index.ts` の import 文を実体確認することで `js-yaml` が宣言済みなのに未使用という乖離を検出、Issue #418 として別 Issue 化）

### [1.14.0] - 2026-05-19

#### 追加

- ACE-028: 外部ツールの「現状」仕様を書くときは公式ドキュメントを WebFetch / WebSearch で必ず照合する — PR #414 で Copilot / Codex CLI が MCP 非対応と書いたが、両者とも 2026 年現在対応済み（VS Code Agent mode GA 2025-04 / `codex mcp add`）、Cursor の `.cursorrules` も deprecated と判明。LLM training cutoff 起因の事実誤認を防ぐ（ACE-023 を補強）
- ACE-029: 外部ツール依存物（shell script の依存コマンド、shebang、インストーラオプション）を文書化するときは実体を読んで列挙する — PR #414 で `.husky/pre-commit` の要件を「sh.exe 必要」と書いたが、実体は `grep`/`xargs` も使用しており「sh + coreutils」が正解。Git for Windows のインストーラオプションも「インストールすれば OK」では不十分（ACE-025 を補強）
- ACE-030: 対応表で `⚠️` を多用したら判定軸自体が間違っているサイン — PR #414 で Cursor の MCP を「⚠️ 一部対応」と書いたが、実態は完全実装で判定軸自体が崩壊。判定軸を「対応有無」から「対応方法・条件」に切り替えるのが正解（ACE-026 を補強）

### [1.13.0] - 2026-05-19

#### 追加

- ACE-025: スクリプトの「対象範囲」を文書化するときは glob 表現ではなく実装上の対象列挙方式まで踏み込む — PR #411 で `validate-docs.mjs` の検証対象を「`docs-template/**/*.md`」と glob 表現で書いたが、実装は `CORE_DOCS` 配列で固定 7 ファイル列挙方式だった。Toolkit code-reviewer W1 + Copilot review が独立検出（ACE-023 を補強）
- ACE-026: 同名関数が複数ファイルに併存する場合は機能対応表で並列説明する — PR #411 で `parseFrontMatter` 3 実装（utils.ts / validate-docs.mjs / build-spec-index.mjs）を単数形で一括説明したが、`>-`/`|` 処理・配列構文・ネスト map 等で挙動差があった。Toolkit comment-analyzer が Critical C1/C2 検出、Copilot/gemini も独立指摘
- ACE-027: 配布対象ファイル内の行番号 hard-coded 参照は採用後に即陳腐化するため heading anchor 化する — PR #411 で `docs-template/MASTER.md:147` 等 6 箇所以上の行番号参照を使用。配布対象は採用者のコピー先で確実にズレるため、heading anchor 形式に置換（ACE-016 を補強）

### [1.12.0] - 2026-05-07

#### 追加

- ACE-024: SSOT で確立した用語を再利用する前に既存定義との衝突を確認する — PR #409 で「コア 7 文書 + ルート直下」見出しがフレームワーク既定の「コア 7 文書」（MASTER/PROJECT/ARCHITECTURE/DOMAIN/PATTERNS/TESTING/DEPLOYMENT）と意味衝突。Toolkit comment-analyzer + Copilot が独立に Critical 検出（ACE-014 / ACE-018 を補強）

#### 更新

- ACE-014: Helpful +1（PR #409 で MASTER.md 内 2 箇所の表が drift リスクを生んだため、SSOT を README に集約し片方を pointer 化。索引集約パターンの再確認）
- ACE-018: Helpful +1（PR #409 で「サブフォルダ内ファイルに番号プレフィックスを付けない」ルールを書く際、既存 6 件の違反（best-practices/0X-_, github-copilot/0X-_）を grep で検出すべきだった反省。ルール導入前の SSOT 列挙の重要性が再確認）
- ACE-019: Helpful +1（PR #409 で best-practices/0X-_, github-copilot/0X-_ を「読み順を強く示したい複数パートの分割文書」例外として明示。暗黙の policy split を Toolkit + Copilot が両方 Critical 検出）

### [1.11.0] - 2026-05-07

#### 追加

- ACE-023: ドキュメント中の事実主張（PR/Issue 番号・ハッシュ・数値）は執筆時に 1 次情報で照合する — PR #405 で「PR #311」「-1842 行」と書いた値が実態と乖離（実態: Issue #311 / commit 6ea43f8 直 commit、-1859 行）し Toolkit が Critical 検出。ACE-002 を「事実関係全般」に拡張

### [1.10.0] - 2026-05-07

#### 追加

- ACE-020: 自動コンテンツ生成ツールは自身のマーカー文字列を本文に含むドキュメントを破壊する — `obsidian-sync.mjs` が `## Linked from` を section header と誤認し OBSIDIAN_GUIDE.md を 379→26 行に破壊した再帰汚染バグから抽出
- ACE-021: テンプレ配布リポでは「リポ自身が使うインフラ」と「テンプレ利用者が受け取る成果物」を物理的に分離する — Obsidian インフラを `docs-template/` 配下に置いたことで配布物が Obsidian 前提になった構造的問題から抽出（ACE-005 を補強）
- ACE-022: 機能削除時は consumer だけでなく定数・型・ユーティリティも grep して取り残しを防ぐ — PR #403 で `BACKLINKS_SECTION_*` 定数が dead code として残存、Toolkit code-reviewer が検出（ACE-018 を補強）

### [1.9.0] - 2026-05-06

#### 追加

- ACE-018: 横断的な番号・順序変更は着手前に grep で全 SSOT を列挙する — 想定の 2〜3 倍のファイルに散らばっている
- ACE-019: 既存ルール違反になる新パターンは「例外」として明示的に名乗らせる — 暗黙の policy split は Toolkit/Copilot が Critical として検出する（ACE-012 への carve-out 整備）

### [1.8.0] - 2026-05-06

#### 追加

- ACE-015: 表を導入したら散文の主張を表に対して再読する — 「N 段階」「太字の領域」型の自己矛盾は人手レビューで見落とされる
- ACE-016: Markdown の anchor link は label と URL の両方にフラグメントを書く — `\[text#anchor\]\(url\)` 形式は無効（ACE-013 を補強）
- ACE-017: 並列 review agent は worktree を巻き戻す副作用を持ち得る — `git status` 監視と `git restore --source=HEAD` で復旧する

### [1.7.0] - 2026-05-06

#### 追加

- ACE-012: PR マージ・push 前は必ず `git status` でブランチを確認する（develop 直 push 事故防止）
- ACE-013: 並列 reviewer の指摘は古い snapshot 由来の誤検知を含む — 実態 grep で双方向検証する
- ACE-014: 索引文書は SSOT を子に集約し、自身は誘導と 1 行サマリのみ — 数値の重複は持たない（ACE-005 を補強）

### [1.6.0] - 2026-04-30

#### 追加

- ACE-011: Prettier × markdownlint MD060 衝突は当該テーブルだけに `<!-- prettier-ignore -->` を付与する局所抑制で解く

### [1.5.0] - 2026-04-30

#### 追加

- ACE-010: Issue クローズ前は commit log でなく現在のファイル実体を grep 照合する — silent regression を検出する

### [1.4.0] - 2026-04-26

#### 追加

- ACE-007: Claude Code skill 内のツール参照は名称・subagent_type を実機 / system prompt で照合する
- ACE-008: クロスリポジトリ操作する skill は全 gh コマンドに `--repo` 必須・mention は `@<assignee>` を使う
- ACE-009: 長時間 Orchestrator の失敗の真因は upstream Issue spec 曖昧さ — 探索型 refine が必要

#### 更新

- ACE-001: Helpful +1（PR #374 で 4 reviewer が独立に Critical 検出、クロスモデルレビューの価値再確認）
- ACE-002: Helpful +1（PR #374 で `Task` ツール名 / `gh state` UPPERCASE / `gh` フラグなど実機照合の重要性が再確認）
- ACE-004: Helpful +1（PR #374 で「同じ 4 観点」主張と実装の乖離・Architectural 継続動作と Out-of-Scope の矛盾を検出）

### [1.3.0] - 2026-04-26

#### 追加

- ACE-005: 索引と実体を分離する委譲パターンでAIコンテキスト消費を抑える
- ACE-006: サンプル付きテンプレファイルには⚠️SAMPLEバナーと固有化手順を必ず併設する

### [1.2.0] - 2026-03-18

#### 追加

- ACE-004: ドキュメントの動作説明は実装メカニズムと一致させる

#### 更新

- ACE-001: Helpful +1（PR #350 でクロスモデルレビューの有効性が再確認）
- ACE-002: Helpful +1（コマンド実在確認の重要性が再確認）

### [1.1.0] - 2026-03-10

#### 追加

- ACE-001: クロスモデルレビューの検出パターン差異
- ACE-002: CLIフラグの実機確認必須ルール
- ACE-003: bash 3.2 macOS互換性の知見
- GitHub Discussion #320 にナラティブ版を投稿

### [1.0.0] - YYYY-MM-DD

#### 追加

- 初版作成：Playbook テンプレート、運用ルール、エントリテンプレートを定義
