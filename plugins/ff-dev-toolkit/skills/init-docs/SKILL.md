---
name: init-docs
description: AI仕様駆動開発のコア7文書 + 拡張フォルダ構造をプロジェクトに初期化する
---

# /init-docs — AI仕様駆動開発ドキュメント初期化

プロジェクトに AI仕様駆動開発のコア7文書 + 拡張フォルダ構造をセットアップします。

## プラグインルートの解決

同梱ファイルを参照する前に `FF_DEV_TOOLKIT_ROOT` を解決する。Claude Code では `${CLAUDE_PLUGIN_ROOT}` を使い、Codex など他ホストでは読み込んだこの `SKILL.md` の絶対パスから `../..` を解決する。以下の `${FF_DEV_TOOLKIT_ROOT}` はその絶対パスを指す。バージョン別 cache を探索して選ばない。

## 前提

- このコマンドはターゲットプロジェクトのルートで実行してください
- `docs/` ディレクトリが既に存在する場合は上書きしません（確認を求めます）

## 手順

### 1. ユーザー情報の確認

以下の情報をユーザーに確認してください。利用中のホストに構造化質問機能があれば使用し、なければ通常の対話で確認します:

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

> **補足**: `00-planning/`（企画・PoC テンプレート）と `08-knowledge/`（ACE Playbook）は初期セットに含めない。`00-planning/` は必要になった時点で `${FF_DEV_TOOLKIT_ROOT}/docs-template/00-planning/` からコピーし、`08-knowledge/` は `/ace-setup` が作成する。`03-implementation/DECISION_TREE.md` と `FALLBACK.md` は、`PATTERNS.md`・`MASTER.md` のコード生成ルール・エラーハンドリング方針から無条件に参照されるため初期セットに含める。

### 3. テンプレートの適用

各ファイルの内容は、プラグイン同梱のテンプレートを参照してコピーしてください:

- **テンプレートパス**: `${FF_DEV_TOOLKIT_ROOT}/docs-template/` 配下の対応するファイル

**Frontmatter 規則（仕様文書と補助文書の線引き）**:

- 初期セット 20 ファイルのテンプレートは**すべて** YAML Frontmatter（必須6フィールド: `title` / `version` / `status` / `owner` / `created` / `updated`）と文書末尾の `## Changelog` セクションを持つ（`/validate-docs` の Frontmatter スキーマチェックと整合）。テンプレートを追加・改訂する際もこの規則を維持する。規則は `tests/docs-template-frontmatter/` が fail-closed で検証する
- `changeImpact` は初版では省略し、初回変更時に Frontmatter へ追加する（MASTER.md の文書管理ルール準拠）
- Frontmatter を要求するのは仕様文書（初期セット + 仕様系拡張文書）のみ。補助文書（`GETTING_STARTED*.md`・`SETUP_*.md`・索引/案内系の README・`05-operations/deployment/` 配下の運用ガイド・`setup-guides/` 等）には付与しない — `/validate-docs` の Frontmatter スキーマチェックも補助文書を検査対象外としている。仕様系の雛形群を説明する README（例: `03-implementation/templates/README.md`）が Frontmatter を持つのは例外として許容する
- 文書内のドメイン履歴表（`CONSTRAINTS.md` の制約変更履歴・`ROADMAP.md` のロードマップ変更履歴等）は、文書レベルの `## Changelog` とは別物として併存してよい。ただしテンプレートの例示行に初版以外のエントリを置かない — `/validate-docs` は「更新履歴に初版以外のエントリがある」ことを changeImpact 要求の根拠にするため、初期化直後の文書が誤って ❌ になる

テンプレート内のプレースホルダー（`[プロジェクト名]`、`[システムの全体的な説明と目的]` などの角括弧表記、および frontmatter の `"@your-github-handle"`・`"YYYY-MM-DD"`）はステップ1で確認した情報で置換してください。

**置換ポリシー**:

- ステップ1の情報で埋まるプレースホルダー**だけ**を置換する。それ以外（`[金額]`・`[SLA値]`・ライブラリの `[x.x.x]` 等）は**推測で埋めずプレースホルダーのまま残す**（MASTER.md の「情報不足時の必須確認プロトコル」と同じ原則。残存は `/validate-docs` が検出し、実装が進む中で埋めていく）
- frontmatter の `updated` がテンプレートの具体日付（テンプレート自身の改訂日）になっている場合も**本日日付に更新**する（`created` ≤ `updated` を保つ）
- frontmatter の `version` は `"1.0.0"` にリセットし、Changelog セクションはテンプレートの改訂履歴を削除して `[1.0.0] - <本日日付> 初版作成` の1行にする
- frontmatter に `changeImpact` が存在する場合は、小文字の `low` / `medium` / `high` に正規化する（`/validate-docs` の Frontmatter スキーマチェックと整合させるため、`LOW` / `MEDIUM` / `HIGH` のままコピーしない）
- テンプレートには**初期セット外のファイルへの参照**（`GETTING_STARTED*.md`、`05-operations/deployment/` 配下 等）が含まれる。`PATTERNS.md`・`TESTING.md` 内のこれらへのリンクはリンク切れのまま残ってよい — 必要になった時点で `${FF_DEV_TOOLKIT_ROOT}/docs-template/` の同一相対パスから追加コピーする
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

ユーザーが **マージ後の ACE を subagent + worktree で自動化**したい場合のみ、利用中のホストの質問機能または通常の対話で希望を確認する。

- **オプション例**: 「はい（テンプレートの場所を案内）」/「いいえ（スキップ）」
- **はい**の場合: `${FF_DEV_TOOLKIT_ROOT}/docs-template/05-operations/deployment/ace-autonomous.md` と `${FF_DEV_TOOLKIT_ROOT}/docs-template/scripts/ace/` をコピー先の目安とともに説明する。feature flag（`ACE_SUBAGENT_ENABLED` 等）は **デフォルト無効** で開始することを必ず伝える。
- **いいえ**の場合: 既存の手動 `/ace-curate` 運用で問題ない旨を一言添える。

## 重要ルール

- テンプレートの構造と必須セクションは変更しないこと（例外: ステップ4の索引小節追記）
- ステップ1の情報で埋まるプレースホルダーは必ず実際の値で置換し、埋まらないものは推測で埋めずに残すこと（ステップ3の置換ポリシー参照）
- `MASTER.md` の「情報不足時の必須確認プロトコル」セクションは必ず含めること
- 既存ファイルがある場合は上書きせず、ユーザーに確認すること
