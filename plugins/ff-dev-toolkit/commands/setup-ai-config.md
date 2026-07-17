---
description: プロジェクトの docs/ を基に AI 開発ツール向け設定ファイル（CLAUDE.md / AGENTS.md / .cursor/rules/*.mdc / copilot-instructions.md）を生成し、Multi-CLI エージェントをセットアップする
---

# /setup-ai-config — AI開発ツール設定ファイル生成

プロジェクトの `docs/` を基に、各AI開発ツール向けの設定ファイルを生成します。

## 対象ツール

| ツール | 生成ファイル | 配置場所 |
|--------|-------------|---------|
| Claude Code | `CLAUDE.md` | プロジェクトルート |
| Codex CLI / 汎用エージェント | `AGENTS.md`（[agents.md](https://agents.md) 標準） | プロジェクトルート |
| Cursor | `.cursor/rules/spec-driven.mdc`（既定・現行 Project Rules 形式） | `.cursor/rules/` |
| GitHub Copilot | `.github/copilot-instructions.md` | `.github/` |

> **Cursor の出力形式**: 既定は現行の Project Rules 形式（`.cursor/rules/*.mdc`, `alwaysApply: true`）。Legacy の単一ファイル `.cursorrules`（プロジェクトルート）は後方互換のための**明示的な互換オプション**として選べる（手順4参照）。

## 標準への入口（全ツール共通の境界）

生成する4ファイル（CLAUDE.md / AGENTS.md / Cursor ルール / copilot-instructions.md）は、ツールを問わず **同じ意味の「標準への入口」** を必ず含めます。各ツール固有のフォーマットで表現は変わっても、次の3つの境界を**等価に**生成してください。

1. **MASTER 先行参照** — 作業やコード生成の前に、必ず `docs/MASTER.md` を最初に読む（*Read MASTER.md First*）
2. **索引からの到達** — MASTER.md の索引（各 `docs/NN-*` へのリンク）から、着手するタスクに関連する仕様へ到達する（*Use the MASTER.md index to reach the relevant specification*）
3. **確認プロトコル** — 情報が不足している場合は推測で埋めず、必ず確認を求める（*Information Verification Protocol*）

> 生成物がこの3境界を等価に含むことは、`plugins/ff-dev-toolkit/tests/setup-ai-config/` の期待生成物 fixture と `verify.sh` で検証する。

## 手順

### 1. 既存ドキュメントの読み取り

以下のファイルを読み取り、プロジェクト情報を抽出します:

- `docs/MASTER.md` — プロジェクト識別、技術スタック、ルール
- `docs/01-context/PROJECT.md` または `docs/01-business/PROJECT.md` — 要件
- `docs/02-design/ARCHITECTURE.md` — アーキテクチャ
- `docs/03-implementation/PATTERNS.md` — コーディング規約

ファイルが見つからない場合は、ユーザーに情報を確認してください。

### 2. 生成するツールの選択

AskUserQuestion を使用して、どのツール向けの設定を生成するか確認します:

- **Claude Code (CLAUDE.md)** — 推奨
- **Codex CLI / 汎用エージェント (AGENTS.md)**
- **Cursor (.cursor/rules/spec-driven.mdc)** — Legacy `.cursorrules` は明示的に希望した場合のみの互換オプション
- **GitHub Copilot (.github/copilot-instructions.md)**
- **すべて**

### 3. CLAUDE.md の生成

以下のセクションを含む `CLAUDE.md` を生成します:

```markdown
# CLAUDE.md

## 🚨 MANDATORY: Read MASTER.md First
作業やコード生成の前に、必ず `docs/MASTER.md` を最初に読むこと（境界1）。
関連する仕様には MASTER.md の索引（各 `docs/NN-*` へのリンク）から到達する
（Use the MASTER.md index to reach the relevant specification for your task）（境界2）。

## Project Overview
[docs/MASTER.md から抽出]

## Architecture
[docs/02-design/ARCHITECTURE.md から要約]

## Coding Standards
[docs/03-implementation/PATTERNS.md から抽出]
- 命名規則
- エラーハンドリング方針
- マジックナンバー禁止ルール

## Build Commands
[プロジェクトの package.json / Makefile 等から検出]

## Development Workflow
[docs/05-operations/ から抽出、なければデフォルト]

## 🚨 Information Verification Protocol
情報が不足している場合は推測せず、必ず確認を求めること（境界3）。
[MASTER.md の確認プロトコルをそのまま含める]
```

### 4. Cursor 設定の生成（既定: Project Rules `.cursor/rules/*.mdc`）

**既定は現行の Project Rules 形式**（`.cursor/rules/spec-driven.mdc`）で生成します。Cursor は `.cursor/rules/` 配下の `*.mdc`（拡張子 `.md` は Project Rules として認識されず無視される）を Project Rules として扱い、`alwaysApply: true` を付けると Always ルールとしてエージェント/チャットのモデルコンテキストに常時含まれます。

以下の構造で `.cursor/rules/spec-driven.mdc` を生成します（先頭に YAML フロントマターが必要）:

```markdown
---
description: AI仕様駆動開発の標準ルール（MASTER 先行参照・索引からの到達・確認プロトコル）
alwaysApply: true
---

# Project Rules (Spec-Driven Development)

## 🚨 MANDATORY: Read MASTER.md First
コード生成の前に必ず `docs/MASTER.md` を最初に読む（境界1）。
関連仕様には MASTER.md の索引から到達する
（Use the MASTER.md index to reach the relevant specification）（境界2）。

## Coding Standards
[PATTERNS.md からの抽出]
- Never use magic numbers — extract to named constants

## Architecture
[ARCHITECTURE.md からの要約]

## Git Workflow (Mandatory)
[docs/05-operations/deployment/git-workflow.md から要約（存在する場合。なければ汎用の Git ワークフロー原則を記載）]
- Issue 起票から着手し、ブランチ → 実装 → セルフレビュー → PR → マージの順で進める
- ブランチ命名規約とコミットメッセージ形式を守る
- PR にはセルフレビュー結果・テスト結果・Issue リンク（例: `Closes #123`）を含める

## Out-of-Scope Issues
- スコープ外の問題は即座に Issue を起票し、現行タスクは継続する（スコープ拡大はしない）

## 🚨 Information Verification Protocol
情報が不足している場合は推測せず、必ず確認を求める（境界3）。
[MASTER.md の確認プロトコルを含める]
```

#### Legacy 互換オプション: `.cursorrules`（明示的に選んだ場合のみ）

古い Cursor / 単一ファイル運用のための**後方互換**として、プロジェクトルートの `.cursorrules`（フロントマター無し）も生成できます。ユーザーが Legacy 形式を明示的に希望した場合のみ生成し、上記 `.cursor/rules/spec-driven.mdc` と**同じ3境界**（MASTER 先行参照 / 索引からの到達 / 確認プロトコル）を等価に含めます。既定は `.cursor/rules/*.mdc` であり、Legacy 形式との併用は推奨しません（重複適用を避ける）。なお `.cursorrules` は Cursor の Agent モードでは無視されることがあるため、確実な適用のためにも現行 `.cursor/rules/*.mdc` を推奨します。

### 5. copilot-instructions.md の生成

以下の構造で `.github/copilot-instructions.md` を生成します。**他の3ファイル（CLAUDE.md / AGENTS.md / Cursor ルール）と同じ3境界**（MASTER 先行参照・索引からの到達・確認プロトコル）を必ず含めます:

```markdown
# GitHub Copilot Instructions

## 🚨 MANDATORY: Read MASTER.md First
Before generating any code suggestions, you MUST read `docs/MASTER.md` first（境界1）.
Use the MASTER.md index to reach the relevant specification for your task（境界2）.

## Project Overview
[PROJECT.md からの要約]

## Technology Stack
[MASTER.md からの技術スタック]

## Coding Standards
[PATTERNS.md からの抽出]

## Key Architecture Decisions
[ARCHITECTURE.md からの要約]

## 🚨 Information Verification Protocol
When information is missing, DO NOT make assumptions — always ask for confirmation（境界3）.
[MASTER.md の確認プロトコルを含める]

## Reference Documents
- docs/MASTER.md — Central coordination document (read this first)
- docs/01-context/PROJECT.md — Project vision and requirements
- [その他のドキュメントリンク]
```

### 6. AGENTS.md の生成（Codex CLI / 汎用エージェント共通）

`AGENTS.md` は [agents.md](https://agents.md) 標準に沿った**クロスエージェントの共通入口**で、Codex CLI をはじめ多くの AI コーディングエージェントが参照します。プロジェクトルートに生成し、**他の3ツールと同じ3境界**（MASTER 先行参照・索引からの到達・確認プロトコル）を必ず含めます。詳細は複製せず正本（`docs/MASTER.md` 等）を参照する薄い入口として構成します:

```markdown
# AGENTS.md

Codex CLI / 汎用 AI エージェント共通の開発ガイド（[agents.md](https://agents.md) 標準）。
詳細は複製せず、正本（`docs/MASTER.md` 等）を参照する。

## 🚨 MANDATORY: Read MASTER.md First
作業やコード生成の前に、必ず `docs/MASTER.md` を最初に読む（境界1）。
関連仕様には MASTER.md の索引から到達する
（Use the MASTER.md index to reach the relevant specification）（境界2）。

## Project Overview
[docs/MASTER.md から抽出：プロジェクト識別・目的・対象ユーザー]

## Tech Stack
[docs/MASTER.md からの技術スタック]

## Build & Test Commands
[package.json / Makefile 等から検出]

## Coding Style
[docs/03-implementation/PATTERNS.md から抽出]
- Never use magic numbers — extract to named constants

## Commit & PR Guidelines
- Issue 起票 → ブランチ → 実装 → セルフレビュー → PR → マージ
- コミットは `<type>: #<issue> <subject>`

## 🚨 Information Verification Protocol
情報が不足している場合は推測せず、必ず確認を求める（境界3）。
[MASTER.md の確認プロトコルを含める]

## Tool-Specific Config
- Claude Code: `CLAUDE.md`
- Cursor: `.cursor/rules/*.mdc`（Legacy `.cursorrules`）
- GitHub Copilot: `.github/copilot-instructions.md`
```

### 7. Multi-CLI Agent Orchestrator のセットアップ

セットアップスクリプトを実行して、Multi-CLI Agent Orchestrator（review / explore / implement の3タスク）を構成します:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup-multi-agent.sh"
```

このスクリプトが行うこと:
- yq（YAMLパーサー）の確認・インストール
- 5つのAI CLI（Claude Code / Codex / Copilot / Gemini / Cursor）の検出
- 未インストールCLIのインストールガイド表示
- `multi-agent.sh --dry-run` による動作確認

セットアップ完了後、以下で利用できます（いずれも本プラグイン同梱）:
- Claude Code: `/multi-review` / `/multi-explore` / `/multi-implement`
- ターミナル: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/multi-agent.sh" --task <review|explore|implement>`

設定のカスタマイズ: プロジェクト側に `.claude/agent-config.yaml` を置くとプラグイン同梱のデフォルト設定より優先される（環境変数 `MULTI_AGENT_CONFIG=<path>` または `--config <path>` でも上書き可）。

### 8. 完了報告

生成したファイルの一覧と、各ファイルの要約を表示してください。
Multi-CLI Agent Orchestrator のセットアップ結果も含めて報告してください。

### 9. （任意）ACE autonomous テンプレートの案内

ユーザーが **ACE ナレッジキャプチャの autonomous 化**（post-merge → subagent → worktree）に関心を示した場合、または Multi-CLI / Git 運用の文脈で自動化を聞かれた場合のみ、AskUserQuestion で希望を確認する。

- **オプション例**: 「案内する」/「スキップ」
- **案内する**を選んだ場合: `${CLAUDE_PLUGIN_ROOT}/docs-template/05-operations/deployment/ace-autonomous.md`、`${CLAUDE_PLUGIN_ROOT}/docs-template/scripts/ace/`、`${CLAUDE_PLUGIN_ROOT}/docs-template/.claude/agents/ace-capture.md` テンプレのコピー先、環境変数（`ACE_SUBAGENT_ENABLED` / `ACE_SUBAGENT_AUTO_MERGE` / `ACE_GARDEN_WALL_PATHS`）の **明示 opt-in** を説明する。

## 重要ルール

- 既存ファイルがある場合は上書き前に必ず確認すること
- docs/ の内容を正確に反映すること（推測で情報を追加しない）
- 生成する4ファイル（CLAUDE.md / AGENTS.md / Cursor ルール / copilot-instructions.md）には、ツールを問わず「標準への入口」3境界（**MASTER 先行参照 / 索引からの到達 / 情報不足時の確認プロトコル**）を等価に含めること（CLAUDE.md だけの要件ではない）
- Cursor は現行 Project Rules 形式（`.cursor/rules/*.mdc`, `alwaysApply: true`）を既定とし、Legacy `.cursorrules` はユーザーが明示的に希望した場合のみの互換オプションとすること
- 各ツール固有のフォーマットや慣習に従うこと
- 生成後、ファイルの内容をユーザーに確認してもらうこと
- 生成物が3境界を等価に含むことは `plugins/ff-dev-toolkit/tests/setup-ai-config/verify.sh` で検証できる
