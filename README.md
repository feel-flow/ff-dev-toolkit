# ff-dev-toolkit

AI仕様駆動開発（AI-SDD）の公式実装となる Claude Code / Codex プラグイン。ドキュメント初期化から開発進行のゲート管理・影響度評価・クロスモデルレビュー・ナレッジ蓄積までを、Skills / MCP サーバーの組み合わせで統制します。

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

### 組織のプラグインディレクトリ（GitHubから同期）で配布する場合

Claude（Web / デスクトップ）の管理画面にある「GitHubから同期」は、**Private / Internal リポジトリのみ**が同期対象です（2026年7月時点。最新の挙動は同ダイアログの注意書きを確認してください）。本リポジトリは Public のため、組織のプラグインディレクトリの同期元として登録できません。

- **個人利用**: 上記の CLI インストールをそのまま使ってください（Public リポジトリでも問題ありません）
- **組織配布**: 本リポジトリを組織の Private リポジトリとして複製（ミラー）し、そのリポジトリを「GitHubから同期」に指定してください。GitHub では Public リポジトリを Private にフォークできないため、フォークではなく [Import repository](https://github.com/new/import) や `git clone --bare` + `git push --mirror` で複製します。複製後は、本リポジトリの更新を随時ミラーへ反映してください

## 収録内容

### Skills（21）

| スキル | 用途 |
|---|---|
| `spec-driven` | 仕様駆動開発のゲート管理。5ゲート（G0〜G4: 要件→仕様→計画→実装→検証）の通過条件を管理し、ドキュメント先・コード後の開発順序を統制する |
| `harness-review` | エージェントハーネス設計のレビュー。アンチパターンカタログと観点チェックリストに基づく設計評価 |
| `out-of-scope-issue` | スコープ外の発見を `YAGNI（対応も Issue 化もしない）→ 軽微ならインライン修正 → Issue 化` の順で判定。Issue 化前に類似 Issue を検索し、同じ完了条件ならコメントで集約。本文 AC は明示許可と競合確認がある場合だけ最小追記し、独立する場合だけ関連 Issue を作成 |

以下のワークフロースキルのうち 14 件は v0.15.0 で旧 Commands から Agent Skills 標準へ移行したもので、残りはその後に追加しました（`/ace-refine` は v0.18.0）。Claude Code では `/ff-dev-toolkit:<name>`、Codex では `$ff-dev-toolkit:<name>`、両方で自然文による自動発火を利用できます。

| ワークフロースキル | 用途 |
|---|---|
| `/init-docs` | AI仕様駆動開発のコア7文書 + 拡張フォルダ構造を初期化 |
| `/validate-docs` | ドキュメント構造の検証（必須3文書、残る4文書は未作成なら N/A） |
| `/assess-impact` | 変更の影響度評価 |
| `/create-issue` | 仕様バリデーション付き Issue 作成（種別・優先度ラベルは実在確認のうえ付与） |
| `/refine-issue` | 既存 Issue の仕様精緻化 |
| `/pre-commit-check` | コミット前チェック |
| `/close-issue` | マージ直前の AC 照合ゲート（チェックボックス更新 + 完了報告コメント） |
| `/merge-cleanup` | PR マージ後のクリーンアップ一括実行（base ブランチ復帰・[gone] ブランチ / worktree 削除・リモート取り残しのガード付き自動削除） |
| `/sweep-orphan-transcripts` | 既存の孤児 Claude Code トランスクリプトの一覧・アーカイブ回収（既定 dry-run、`--apply` で実行） |
| `/setup-github-labels` | 推奨ラベル構成の冪等セットアップ（不足分だけ作成・既存ラベルは変更しない・照会を信用できなければ 1 件も作成せず停止） |
| `/ace-setup` | ACE（Agentic Context Engineering）フレームワークのセットアップ |
| `/ace-curate` | マージ済み PR からの知見抽出・プレイブック追記 |
| `/ace-refine` | ACE Playbook の定期整理（stale アーカイブ・長大エントリ圧縮・重複統合）。dry-run → 承認 → 適用の 3 フェーズで原文を保全する |
| `/retrospective` | ワークフローチェーン末尾（`/merge-cleanup` → `/ace-curate` → `/retrospective`）のセッション振り返り。実測した手戻り・無駄時間からプロセス/ツール改善を最大 3 件提案（該当なしなら 1 行報告）。起票はユーザー承認後のみ |
| `/setup-ai-config` | AI 開発ツール設定の初期化 |
| `/multi-explore` | マルチAI CLI による並列探索 |
| `/multi-implement` | マルチAI CLI による並列実装 |
| `/multi-review` | マルチAI CLI による並列レビュー |

### 旧 Codex standalone copy からの移行

過去の手順で `~/.codex/skills/out-of-scope-issue` をフルコピーしている場合、先に marketplace と plugin を更新し、Codex の新規セッションで `/skills` に `ff-dev-toolkit:out-of-scope-issue` が出ることを確認してください。確認後、旧 standalone copy は drift と重複発火を避けるため削除できます。プラグイン側からユーザー領域を自動削除はしません。

```bash
codex plugin marketplace upgrade ff-dev-toolkit
codex plugin add ff-dev-toolkit@ff-dev-toolkit
```

### MCP サーバー（spec-docs）

対象プロジェクトの `docs/` ツリーを検索・参照する 6 ツール: `search` / `extract_section` / `glossary_lookup` / `list_docs` / `spec_lookup` / `spec_search`

### その他

- `docs-template/` — コア7文書 + 拡張フォルダのテンプレート一式
- `scripts/` — マルチAI CLI オーケストレーション用スクリプト
- `hooks/` — 更新通知フック（下記）

### 更新通知

セッション開始時に本リポジトリの最新リリースタグを確認し、新しいバージョンが公開されていれば通知します（更新コマンドは通知に表示されます）。同じバージョンについての通知は一度だけです。

- チェック成功の結果は 24 時間キャッシュされます。オフライン時や取得失敗時は何もせず黙ってスキップし（セッション起動を妨げません）、1 時間後に再試行します
- 通知を止めたい場合は環境変数 `FF_DEV_TOOLKIT_SKIP_UPDATE_CHECK=1` を設定してください

## 前提

- [Claude Code](https://docs.claude.com/en/docs/claude-code)（プラグインの第一ターゲット。Codex CLI / Claude Cowork / grok CLI / GitHub Copilot CLI も Claude 形式 marketplace 互換で利用可。詳細は下記「他のツールで使う」）
- Node.js >= 22（MCP サーバー spec-docs の実行に必要。18/20 は EOL のためサポート外）
- マルチAI CLI オーケストレーション（`/multi-*`）を使う場合のみ: Codex CLI / Gemini CLI / Copilot CLI のいずれか（オプション。Copilot CLI は `/multi-review` では従量課金のためオプトイン）

## 他のツールで使う

| 環境 | 利用方法 |
|------|----------|
| Claude Code | 上記「インストール」（第一ターゲット） |
| Codex CLI / Claude Cowork | Claude 形式 marketplace を登録して install（CLI / UI は各製品の手順に読み替え） |
| grok CLI | Claude 形式 marketplace を登録して install（v0.2.118 で実機検証済み）:<br>`grok plugin marketplace add feel-flow/ff-dev-toolkit`<br>`grok plugin install ff-dev-toolkit@feel-flow/ff-dev-toolkit` |
| GitHub Copilot CLI | Claude 形式 marketplace を登録して install（v1.0.75 で実機検証済み）:<br>`copilot plugin marketplace add feel-flow/ff-dev-toolkit`<br>`copilot plugin install ff-dev-toolkit@ff-dev-toolkit`<br>導入したスキルは `copilot skill list` の Plugin skills に並ぶ |
| **VS Code + GitHub Copilot** | marketplace の plugin install は不可（IDE 拡張。上記 Copilot **CLI** とは別経路）。`.github/copilot-instructions.md` と `docs/` で方法論を効かせる → **[USING_WITH_VSCODE_COPILOT.md](./USING_WITH_VSCODE_COPILOT.md)** |

grok / Copilot CLI で確認したのは marketplace 登録 → インストール → コンポーネントの認識まで（2026-08-02 実測。上記コマンドのとおり本リポジトリ `feel-flow/ff-dev-toolkit` から直接導入して確認）。スキルの実行・hooks の発火・MCP サーバーの起動は未検証。

## バージョンと書籍からの参照

書籍からの参照はリリースタグで固定されます。最新の安定版は [Releases](https://github.com/feel-flow/ff-dev-toolkit/releases) を参照してください。

バージョンごとの変更内容は [CHANGELOG.md](./CHANGELOG.md) を参照してください。

## 開発とフィードバック

本リポジトリは FeelFlow 内部リポジトリ（SSOT）からの一方向同期で更新されます。バグ報告・改善要望は本リポジトリの Issue で受け付けます。

## ライセンス

[Apache License 2.0](./LICENSE)

Copyright 2026 FeelFlow Inc.
