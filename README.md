# ff-dev-toolkit

AI仕様駆動開発（AI-SDD）の公式実装となる Claude Code プラグイン。ドキュメント初期化から開発進行のゲート管理・影響度評価・クロスモデルレビュー・ナレッジ蓄積までを、Skills / Commands / MCP サーバーの組み合わせで統制します。

書籍『AI仕様駆動開発 公式ガイド』第2部（公式実装リファレンス）の対象実装です。方法論そのもの（コア7文書スキーマ・原則）は [ai-spec-driven-development](https://github.com/feel-flow/ai-spec-driven-development) を参照してください。

## インストール

```bash
# マーケットプレイスを登録
claude plugin marketplace add feel-flow/ff-dev-toolkit

# プラグインをインストール
claude plugin install ff-dev-toolkit@ff-dev-toolkit
```

> **⚠️ v0.7.0 で改名しました（旧 `dev-toolkit` → `ff-dev-toolkit`）。** リポジトリ・marketplace・プラグイン名すべてが変わったため、旧版を入れている既存ユーザーは再インストールが必要です:
>
> ```bash
> claude plugin uninstall dev-toolkit@dev-toolkit
> claude plugin marketplace remove dev-toolkit
> claude plugin marketplace add feel-flow/ff-dev-toolkit
> claude plugin install ff-dev-toolkit@ff-dev-toolkit
> ```
>
> Codex CLI / Cowork で利用している場合も同様に、旧プラグインの削除と marketplace の再登録が必要です（手順は各プラットフォームのプラグイン管理 UI / CLI に読み替え）。

## 収録内容

### Skills（2）

| スキル | 用途 |
|---|---|
| `spec-driven` | 仕様駆動開発のゲート管理。5ゲート（G0〜G4: 要件→仕様→計画→実装→検証）の通過条件を管理し、ドキュメント先・コード後の開発順序を統制する |
| `harness-review` | エージェントハーネス設計のレビュー。アンチパターンカタログと観点チェックリストに基づく設計評価 |

### Commands（13）

| コマンド | 用途 |
|---|---|
| `/init-docs` | AI仕様駆動開発のコア7文書 + 拡張フォルダ構造を初期化 |
| `/validate-docs` | ドキュメント構造の検証（必須3文書、残る4文書は未作成なら N/A） |
| `/assess-impact` | 変更の影響度評価 |
| `/create-issue` | 仕様バリデーション付き Issue 作成 |
| `/refine-issue` | 既存 Issue の仕様精緻化 |
| `/pre-commit-check` | コミット前チェック |
| `/close-issue` | マージ直前の AC 照合ゲート（チェックボックス更新 + 完了報告コメント） |
| `/ace-setup` | ACE（Agentic Context Engineering）フレームワークのセットアップ |
| `/ace-curate` | マージ済み PR からの知見抽出・プレイブック追記 |
| `/setup-ai-config` | AI 開発ツール設定の初期化 |
| `/multi-explore` | マルチAI CLI による並列探索 |
| `/multi-implement` | マルチAI CLI による並列実装 |
| `/multi-review` | マルチAI CLI による並列レビュー |

### MCP サーバー（spec-docs）

対象プロジェクトの `docs/` ツリーを検索・参照する 6 ツール: `search` / `extract_section` / `glossary_lookup` / `list_docs` / `spec_lookup` / `spec_search`

### その他

- `docs-template/` — コア7文書 + 拡張フォルダのテンプレート一式
- `scripts/` — マルチAI CLI オーケストレーション用スクリプト

## 前提

- [Claude Code](https://docs.claude.com/en/docs/claude-code)（プラグインの第一ターゲット。Codex CLI / Claude Cowork も Claude 形式 marketplace 互換で利用可）
- Node.js >= 22（MCP サーバー spec-docs の実行に必要。18/20 は EOL のためサポート外）
- マルチAI CLI オーケストレーション（`/multi-*`）を使う場合のみ: Codex CLI / Gemini CLI / Copilot CLI / Cursor CLI のいずれか（オプション。Copilot CLI は `/multi-review` では従量課金のためオプトイン）

## 他のツールで使う

| 環境 | 利用方法 |
|------|----------|
| Claude Code | 上記「インストール」（第一ターゲット） |
| Codex CLI / Claude Cowork | Claude 形式 marketplace を登録して install（CLI / UI は各製品の手順に読み替え） |
| **VS Code + GitHub Copilot** | marketplace の plugin install は不可。`.github/copilot-instructions.md` と `docs/` で方法論を効かせる → **[USING_WITH_VSCODE_COPILOT.md](./USING_WITH_VSCODE_COPILOT.md)** |
| Cursor | plugin install は不可。`/setup-ai-config` で Project Rules（`.cursor/rules/*.mdc`）を生成 |

## バージョンと書籍からの参照

書籍からの参照はリリースタグで固定されます。最新の安定版は [Releases](https://github.com/feel-flow/ff-dev-toolkit/releases) を参照してください。

バージョンごとの変更内容は [CHANGELOG.md](./CHANGELOG.md) を参照してください。

## 開発とフィードバック

本リポジトリは FeelFlow 内部リポジトリ（SSOT）からの一方向同期で更新されます。バグ報告・改善要望は本リポジトリの Issue で受け付けます。

## ライセンス

[Apache License 2.0](./LICENSE)

Copyright 2026 FeelFlow Inc.
