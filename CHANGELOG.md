# Changelog

本ファイルは [ff-dev-toolkit](https://github.com/feel-flow/ff-dev-toolkit) のバージョンごとの変更履歴です。

形式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に沿います。バージョン番号は [Semantic Versioning](https://semver.org/lang/ja/) に従い、正本は `plugins/ff-dev-toolkit/.claude-plugin/plugin.json` の `version` です。

## 運用

- 公開物（Skills / Commands / docs-template / scripts / MCP 等）を変えて `plugin.json` の version を bump するとき、**同じ変更で本ファイルの対応節を更新する**
- 未公開の作業中変更は `[Unreleased]` に積み、version bump 時にバージョン節へ移す
- 各 `## [x.y.z]` は **plugin.json の version 境界**を記録する。公開 Git タグは同期タイミングにより一部の版を飛ばすことがあるが、CHANGELOG は plugin version 単位で残す（飛ばされた版の変更は次に付く公開タグに含まれる）
- 0.1.0〜0.4.0 は公開リポジトリ作成前の内部版の要約である
- 公開同期の禁止パターン（private リポジトリ識別子・秘密情報など）を書かない
- 文末の比較リンクは、公開リポジトリに存在するタグ同士のみを記載する

## [Unreleased]

## [0.10.5] - 2026-07-22

### 追加

- 公開ガイド `USING_WITH_VSCODE_COPILOT.md`（VS Code + GitHub Copilot で AI-SDD を効かせる手順）
- README に「他のツールで使う」節を追加し、上記ガイドへリンク

## [0.10.4] - 2026-07-22

### 変更

- marketplace / `plugin.json` の説明文を、役割の一文＋収録カテゴリ（スキル / ドキュメント運用 / ナレッジ・設定 / マルチAI CLI / MCP）に分けて読みやすくした

## [0.10.3] - 2026-07-22

### 追加

- 公開リポジトリルート向け `CHANGELOG.md` を新設し、0.1.0 から現行までの変更要約を再構成
- 公開 README の「バージョンと書籍からの参照」から CHANGELOG へリンク
- `plugin.json` の version と CHANGELOG 最新リリース見出しの一致を検証する回帰テスト

## [0.10.2] - 2026-07-22

### 変更

- docs-template / SETUP_CURSOR を Cursor 現行 Project Rules（`.cursor/rules/*.mdc`）前提に整理。Legacy `.cursorrules` は後方互換として降格
- MASTER 系ドキュメントの命名例外・参照パスを現行形式に整合

## [0.10.1] - 2026-07-22

### 修正

- docs-template の ADR 例を標準 4 点要件（背景・決定・結果・結果の理由）へ整合

## [0.10.0] - 2026-07-22

### 追加

- `/validate-docs` に Frontmatter スキーマ検証を追加（必須 6 フィールド、version の SemVer、status 値域、changeImpact の小文字値域）
- Frontmatter 不正を検出する fixture と fail-closed 回帰ガード

### 変更

- docs-template および `/init-docs` の `changeImpact` 表記を小文字（`low` / `medium` / `high`）に統一

## [0.9.5] - 2026-07-22

### 追加

- `/validate-docs`・`/assess-impact` 向けプロンプト fixture 回帰テスト（`tests/` と `tests/run-all.sh`）を整備

## [0.9.4] - 2026-07-18

### 変更

- docs-template を上流 AI-SDD リポジトリと丸ごとコピー方式で同期（ACE Playbook 更新、フルオート運用原則、ブランチ命名方針、Node 24 記述、`/close-issue` チェックリスト項目ほか）
- MASTER テンプレの status enum 終端に `deprecated` を反映
- 公開テンプレート内のリポジトリ固有表記を一般名へ揃え、公開同期時の識別子検査に抵触しないようにした

## [0.9.3] - 2026-07-18

### 修正

- `/ace-curate` の ACE Reuse（Helpful）反映入力を PR 本文（implementation-notes 転記）に限定し、1 PR につき +1 の重複加算防止を明記。コミット件名・本文は reuse-report 入力である経路を分離
- `/create-issue` の anchor 規則をすべての ACE ID 形式に一般化し、Issue スコープ式の例を追加

## [0.9.2] - 2026-07-18

### 修正

- git-workflow ステップ 8 のマージ例に、照合済み HEAD SHA を変数へ転記する代入行を追加（未代入のままコマンド例をそのまま実行すると `gh pr merge` が空文字で失敗する穴の解消）

## [0.9.1] - 2026-07-18

### 変更

- docs-template の git-workflow ステップ 8 に、マージ前 AC 照合ゲート（`/close-issue`）を反映
- マージ例に `--match-head-commit` を追加し、照合後 push の未照合マージを防止
- 標準チェックリストに `/close-issue` ゲートとマージ手順を追記

## [0.9.0] - 2026-07-18

### 追加

- `/close-issue` コマンド（マージ直前の AC 照合ゲート: 対象 Issue 自動検出 → 受け入れ条件照合 → チェックボックス更新 + 完了報告コメント）

### 変更

- 公開 README / marketplace の Commands 表記を 12 → 13 に更新

## [0.8.0] - 2026-07-17

### 追加

- `/ace-curate` に ACE エントリ ID 規則セクション欠落時の自己修復ガード（同梱テンプレからコピー）
- `/create-issue` に関連 ACE エントリの Reuse 検索と blob URL 添付
- git-workflow ステップ 3 に着手前 Playbook 参照ゲート（ACE Reuse）

### 変更

- ACE Reuse 記録を `/ace-curate` の Helpful 更新へ接続し、記録が静かに捨てられる断線を解消

## [0.7.0] - 2026-07-16

### 変更

- プラグイン名・ディレクトリ・公開 marketplace・install 表記を `dev-toolkit` から **`ff-dev-toolkit`** へ改名（vendor prefix 統一）
- 公開 README に旧版からの再インストール手順を記載

> **破壊的変更（インストール手順）**: 旧 marketplace / プラグイン名を使っている場合は再インストールが必要です。手順は README を参照してください。

## [0.6.0] - 2026-07-15

### 変更

- MCP サーバー（spec-docs）の Node.js 要求を **>= 22**（開発時は engines と整合する 22.12.0 系）へ引き上げ。Node 18/20 は EOL のためサポート外
- package engines / esbuild target / 公開 README・docs-template 内の Node 記述を統一

## [0.5.0] - 2026-07-11

### 追加

- OSS 公開準備: Apache-2.0 ライセンス、公開用 README / marketplace アセット
- 非公開参照の除去と、公開抽出時の禁止パターン検査（fail-closed）
- spec-docs MCP サーバー（6 ツール: `search` / `extract_section` / `glossary_lookup` / `list_docs` / `spec_lookup` / `spec_search`）の同梱（内部版 0.5.0 で追加済み。本版が公開初回タグ）

## [0.4.0] - 2026-07-07

### 追加

- マルチ AI CLI オーケストレーション用 scripts（`multi-agent.sh` / `multi-review.sh` / adapters / perspectives）
- `/multi-explore` / `/multi-implement` / `/multi-review` / `/setup-ai-config` コマンド

## [0.3.0] - 2026-07-07

### 追加

- AI 仕様駆動開発向け `docs-template/`（コア 7 文書 + 拡張フォルダ）を一本化して同梱
- doc 系コマンド 8 個: `/init-docs` / `/validate-docs` / `/assess-impact` / `/create-issue` / `/refine-issue` / `/pre-commit-check` / `/ace-setup` / `/ace-curate`

### 変更

- `spec-driven` のテンプレ参照を同梱 `docs-template/` へ付け替え

## [0.2.0] - 2026-07-03

### 追加

- `harness-review` スキル（エージェントハーネス設計の 7 観点レビュー、アンチパターンカタログ、fixture）

## [0.1.0] - 2026-07-03

### 追加

- プラグイン初版（当時名称 `dev-toolkit`）
- `spec-driven` スキル（5 ゲート: G0 要件 → G1 仕様 → G2 計画 → G3 実装 → G4 検証）

<!-- 比較リンクは公開リポジトリに存在するタグ同士のみ。plugin version のうち未タグの版は見出しのみ。 -->

[Unreleased]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.10.1...HEAD
[0.10.1]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.9.4...v0.10.1
[0.9.4]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.9.3...v0.9.4
[0.9.3]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.8.0...v0.9.3
[0.8.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.6.0...v0.8.0
[0.6.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/feel-flow/ff-dev-toolkit/releases/tag/v0.5.0
