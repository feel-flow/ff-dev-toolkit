---
description: AI仕様駆動開発のコア7文書 + 拡張フォルダ構造をプロジェクトに初期化する
---

# /init-docs — AI仕様駆動開発ドキュメント初期化

プロジェクトに AI仕様駆動開発のコア7文書 + 拡張フォルダ構造をセットアップします。

## 前提

- このコマンドはターゲットプロジェクトのルートで実行してください
- `docs/` ディレクトリが既に存在する場合は上書きしません（確認を求めます）

## 手順

### 1. ユーザー情報の確認

以下の情報をユーザーに確認してください（AskUserQuestion を使用）:

- **プロジェクト名**: 具体的な名称
- **技術スタック**: FE/BE/DB/Infra
- **プロジェクト概要**: 1-2文の説明
- **オーナー**: frontmatter の `owner` に入れる GitHub ハンドル（未回答の場合は `gh api user --jq .login` で実行者のハンドルを取得してよい）

### 2. ディレクトリ構造の作成

以下の構造を作成します:

```
docs/
├── MASTER.md
├── 01-context/
│   ├── PROJECT.md
│   └── CONSTRAINTS.md
├── 02-design/
│   ├── ARCHITECTURE.md
│   ├── DOMAIN.md
│   ├── API.md
│   └── DATABASE.md
├── 03-implementation/
│   ├── PATTERNS.md
│   ├── CONVENTIONS.md
│   ├── INTEGRATIONS.md
│   ├── DECISION_TREE.md
│   └── FALLBACK.md
├── 04-quality/
│   ├── TESTING.md
│   └── VALIDATION.md
├── 05-operations/
│   └── DEPLOYMENT.md
├── 06-reference/
│   ├── GLOSSARY.md
│   └── DECISIONS.md
└── 07-project-management/
    ├── ROADMAP.md
    ├── TASKS.md
    └── RISKS.md
```

> **補足**: `00-planning/`（企画・PoC テンプレート）と `08-knowledge/`（ACE Playbook）は初期セットに含めない。`00-planning/` は必要になった時点で `${CLAUDE_PLUGIN_ROOT}/docs-template/00-planning/` からコピーし、`08-knowledge/` は `/ace-setup` が作成する。`03-implementation/DECISION_TREE.md` と `FALLBACK.md` は、`PATTERNS.md`・`MASTER.md` のコード生成ルール・エラーハンドリング方針から無条件に参照されるため初期セットに含める。

### 3. テンプレートの適用

各ファイルの内容は、プラグイン同梱のテンプレートを参照してコピーしてください:

- **テンプレートパス**: `${CLAUDE_PLUGIN_ROOT}/docs-template/` 配下の対応するファイル

テンプレート内のプレースホルダー（`[プロジェクト名]`、`[システムの全体的な説明と目的]` などの角括弧表記、および frontmatter の `"@your-github-handle"`・`"YYYY-MM-DD"`）はステップ1で確認した情報で置換してください。

**置換ポリシー**:

- ステップ1の情報で埋まるプレースホルダー**だけ**を置換する。それ以外（`[金額]`・`[SLA値]`・ライブラリの `[x.x.x]` 等）は**推測で埋めずプレースホルダーのまま残す**（MASTER.md の「情報不足時の必須確認プロトコル」と同じ原則。残存は `/validate-docs` が検出し、実装が進む中で埋めていく）
- frontmatter の `updated` がテンプレートの具体日付（テンプレート自身の改訂日）になっている場合も**本日日付に更新**する（`created` ≤ `updated` を保つ）
- frontmatter の `version` は `"1.0.0"` にリセットし、Changelog セクションはテンプレートの改訂履歴を削除して `[1.0.0] - <本日日付> 初版作成` の1行にする
- テンプレートには**初期セット外のファイルへの参照**（`GETTING_STARTED*.md`、`05-operations/deployment/` 配下 等）が含まれる。`PATTERNS.md`・`TESTING.md` 内のこれらへのリンクはリンク切れのまま残ってよい — 必要になった時点で `${CLAUDE_PLUGIN_ROOT}/docs-template/` の同一相対パスから追加コピーする
- `MASTER.md`・`DEPLOYMENT.md` 内の初期セット外参照は角括弧リンクではなく案内テキストとして記述済みのため、そのままコピーしてよい（追加の置換作業は不要）

### 4. MASTER.md のカスタマイズ

MASTER.md は特に重要です。以下を必ず反映してください:

- **プロジェクト識別**: プロジェクト名、バージョン、最終更新日
- **技術スタック要約**: FE/BE/DB/Infra
- **守るべきルール**: 命名規則、エラーハンドリング方針、テスト方針
- **情報不足時の必須確認プロトコル**: そのまま含める（MASTER.md テンプレートの実見出しは「情報不足時の必須確認プロトコル」）
- **ドキュメント索引リンク**: 作成した各ドキュメントへの相対パス。テンプレートの索引が挙げる初期セット内ファイルはコア7文書のみなので、**初期セットのコア7以外の全ファイル（現在13ファイル）へのリンクは「初期セットのその他文書」等の小節として索引に追記する**（この追記は「テンプレート構造を変更しない」ルールの例外として認められる）

### 5. 完了報告

作成したファイル一覧を表示し、次のステップとして `/validate-docs` の実行を推奨してください。あわせて以下を一言添える:

- テンプレート由来のサンプル記述（例: `https://api.example.com/v1`、例示 ADR）はプロジェクト実態と食い違うことがあるため、各文書を実際に使い始めるタイミングで実態に合わせること
- 初期セット外への参照リンク（deployment/ 配下等）は、必要になった時点でプラグインの docs-template から追加コピーできること

### 6. （任意）ACE autonomous テンプレートの案内

ユーザーが **マージ後の ACE を subagent + worktree で自動化**したい場合のみ、AskUserQuestion で希望を確認する。

- **オプション例**: 「はい（テンプレートの場所を案内）」/「いいえ（スキップ）」
- **はい**の場合: `${CLAUDE_PLUGIN_ROOT}/docs-template/05-operations/deployment/ace-autonomous.md` と `${CLAUDE_PLUGIN_ROOT}/docs-template/scripts/ace/` をコピー先の目安とともに説明する。feature flag（`ACE_SUBAGENT_ENABLED` 等）は **デフォルト無効** で開始することを必ず伝える。
- **いいえ**の場合: 既存の手動 `/ace-curate` 運用で問題ない旨を一言添える。

## 重要ルール

- テンプレートの構造と必須セクションは変更しないこと（例外: ステップ4の索引小節追記）
- ステップ1の情報で埋まるプレースホルダーは必ず実際の値で置換し、埋まらないものは推測で埋めずに残すこと（ステップ3の置換ポリシー参照）
- `MASTER.md` の「情報不足時の必須確認プロトコル」セクションは必ず含めること
- 既存ファイルがある場合は上書きせず、ユーザーに確認すること
