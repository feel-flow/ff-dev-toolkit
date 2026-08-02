---
name: setup-ai-config
description: プロジェクトの docs/ を基に AI 開発ツール向け設定ファイル（CLAUDE.md / AGENTS.md / copilot-instructions.md）を生成し、Multi-CLI エージェントをセットアップする
---

# /setup-ai-config — AI開発ツール設定ファイル生成

プロジェクトの `docs/` を基に、各AI開発ツール向けの設定ファイルを生成します。

## プラグインルートの解決

同梱ファイルを参照・実行する前に `FF_DEV_TOOLKIT_ROOT` を解決する。Claude Code では `${CLAUDE_PLUGIN_ROOT}` を使い、Codex など他ホストでは読み込んだこの `SKILL.md` の絶対パスから `../..` を解決する。以下の `${FF_DEV_TOOLKIT_ROOT}` はその絶対パスを指す。バージョン別 cache を探索して選ばない。

## 対象ツール

| ツール | 生成ファイル | 配置場所 |
|--------|-------------|---------|
| Claude Code | `CLAUDE.md` | プロジェクトルート |
| Codex CLI / 汎用エージェント | `AGENTS.md`（[agents.md](https://agents.md) 標準） | プロジェクトルート |
| GitHub Copilot | `.github/copilot-instructions.md` | `.github/` |

## 標準への入口（全ツール共通の境界）

生成する3ファイル（CLAUDE.md / AGENTS.md / copilot-instructions.md）は、ツールを問わず **同じ意味の「標準への入口」** を必ず含めます。各ツール固有のフォーマットで表現は変わっても、次の5つの境界を**等価に**生成してください。

1. **MASTER 先行参照** — 作業やコード生成の前に、必ず `docs/MASTER.md` を最初に読む（*Read MASTER.md First*）
2. **索引からの到達** — MASTER.md の索引（各 `docs/NN-*` へのリンク）から、着手するタスクに関連する仕様へ到達する（*Use the MASTER.md index to reach the relevant specification*）
3. **確認プロトコル** — 情報が不足している場合は推測で埋めず、必ず確認を求める（*Information Verification Protocol*）
4. **スコープ外発見のルーティング** — `YAGNI → インライン修正 → Issue 化` の順で必要性と変更境界を判定する
5. **Secrets 露出防止** — secret を stdout/stderr に出すコマンドを実行しない（*Secrets Exposure Prevention*）。エージェントの出力は永続化されるため、値が一度でも出たら「露出」になる

> 生成物がこの5境界を等価に含むことは、`plugins/ff-dev-toolkit/tests/setup-ai-config/` の期待生成物 fixture と `verify.sh` で検証する。

## 手順

### 1. 既存ドキュメントの読み取り

以下のファイルを読み取り、プロジェクト情報を抽出します:

- `docs/MASTER.md` — プロジェクト識別、技術スタック、ルール
- `docs/01-context/PROJECT.md` または `docs/01-business/PROJECT.md` — 要件
- `docs/02-design/ARCHITECTURE.md` — アーキテクチャ
- `docs/03-implementation/PATTERNS.md` — コーディング規約

ファイルが見つからない場合は、ユーザーに情報を確認してください。

### 2. 生成するツールの選択

利用中のホストに構造化質問機能があれば使用し、なければ通常の対話で、どのツール向けの設定を生成するか確認します:

- **Claude Code (CLAUDE.md)** — 推奨
- **Codex CLI / 汎用エージェント (AGENTS.md)**
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

## Out-of-Scope Finding Routing
- 現 diff の回帰・現 Issue の AC・既存契約・必須品質ゲート・Critical / Warning は分岐前に現 PR で解消する
- 判定順は `YAGNI → インライン修正 → Issue 化`
- 現在の根拠・利用者影響・受け入れ条件がなければ YAGNI とし、対応も Issue 化もしない
- 必要かつ軽微（10 行以内・同一ファイル・仕様判断不要・別モジュール波及なし・独立検証不要・既存契約不変の全条件）なら現 PR で修正する
- 仕様判断・別モジュール・独立検証が必要なら Issue 化ルートへ進む
- Issue 化の前に類似 Issue を検索し、同じ完了条件なら既定はコメントでまとめる。本文 AC は明示許可と競合確認がある場合だけ最小追記する
- 完了条件が独立する場合だけ、既存 Issue と関連付けた新規 Issue を作成する

## 🚨 Secrets Exposure Prevention
- secret を stdout/stderr に出すコマンドを実行しない（境界5）。エージェントの出力（トランスクリプト・ログ・PR コメント）は永続化され、値が一度でも出たら「露出」としてローテーション判断が必要になる
- env ファイル・プロセス環境の全ダンプを禁止（`cat .env*` / `printenv` / `env` / `console.log(process.env)` 等）。個別キーでも値全体を出さない（`printenv KEY` / `echo $KEY` を含む）
- secret を読み込む CLI に `--debug` / `--verbose` を付ける前に、失敗時に何をダンプするかを確認する。不明なら付けない
- 値の診断・ログ出力は prefix（先頭5字）+ length まで
- 露出した場合は隠さず即報告し、露出したキーと範囲を列挙する
- [プロジェクトの技術スタックから、対象となる secret（接続文字列・署名鍵・API キー等）と、それを出力し得る具体的コマンドを検出して列挙する。例示のコマンドはそのまま転記せず、実際に使うスタックのものへ置き換えること（例示: `supabase --debug` / `vercel env pull /dev/stdout` / `gh auth token` / `stripe config --list`）]

## 🚨 Information Verification Protocol
情報が不足している場合は推測せず、必ず確認を求めること（境界3）。
[MASTER.md の確認プロトコルをそのまま含める]
```

### 4. copilot-instructions.md の生成

以下の構造で `.github/copilot-instructions.md` を生成します。**他の2ファイル（CLAUDE.md / AGENTS.md）と同じ5境界**（MASTER 先行参照・索引からの到達・確認プロトコル・スコープ外発見のルーティング・Secrets 露出防止）を必ず含めます:

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

## Out-of-Scope Finding Routing
- 現 diff の回帰・現 Issue の AC・既存契約・必須品質ゲート・Critical / Warning は分岐前に現 PR で解消する
- 判定順は `YAGNI → インライン修正 → Issue 化`
- 現在の根拠・利用者影響・受け入れ条件がなければ YAGNI とし、対応も Issue 化もしない
- 必要かつ軽微（10 行以内・同一ファイル・仕様判断不要・別モジュール波及なし・独立検証不要・既存契約不変の全条件）なら現 PR で修正する
- 仕様判断・別モジュール・独立検証が必要なら Issue 化ルートへ進む
- Issue 化の前に類似 Issue を検索し、同じ完了条件なら既定はコメントでまとめる。本文 AC は明示許可と競合確認がある場合だけ最小追記する
- 完了条件が独立する場合だけ、既存 Issue と関連付けた新規 Issue を作成する

## 🚨 Secrets Exposure Prevention
- secret を stdout/stderr に出すコマンドを実行しない（境界5）。エージェントの出力（トランスクリプト・ログ・PR コメント）は永続化され、値が一度でも出たら「露出」としてローテーション判断が必要になる
- env ファイル・プロセス環境の全ダンプを禁止（`cat .env*` / `printenv` / `env` / `console.log(process.env)` 等）。個別キーでも値全体を出さない（`printenv KEY` / `echo $KEY` を含む）
- secret を読み込む CLI に `--debug` / `--verbose` を付ける前に、失敗時に何をダンプするかを確認する。不明なら付けない
- 値の診断・ログ出力は prefix（先頭5字）+ length まで
- 露出した場合は隠さず即報告し、露出したキーと範囲を列挙する
- [プロジェクトの技術スタックから、対象となる secret（接続文字列・署名鍵・API キー等）と、それを出力し得る具体的コマンドを検出して列挙する。例示のコマンドはそのまま転記せず、実際に使うスタックのものへ置き換えること（例示: `supabase --debug` / `vercel env pull /dev/stdout` / `gh auth token` / `stripe config --list`）]

## 🚨 Information Verification Protocol
When information is missing, DO NOT make assumptions — always ask for confirmation（境界3）.
[MASTER.md の確認プロトコルを含める]

## Reference Documents
- docs/MASTER.md — Central coordination document (read this first)
- docs/01-context/PROJECT.md — Project vision and requirements
- [その他のドキュメントリンク]
```

### 5. AGENTS.md の生成（Codex CLI / 汎用エージェント共通）

`AGENTS.md` は [agents.md](https://agents.md) 標準に沿った**クロスエージェントの共通入口**で、Codex CLI をはじめ多くの AI コーディングエージェントが参照します。プロジェクトルートに生成し、**他の2ツールと同じ5境界**（MASTER 先行参照・索引からの到達・確認プロトコル・スコープ外発見のルーティング・Secrets 露出防止）を必ず含めます。詳細は複製せず正本（`docs/MASTER.md` 等）を参照する薄い入口として構成します:

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

## Out-of-Scope Finding Routing
- 現 diff の回帰・現 Issue の AC・既存契約・必須品質ゲート・Critical / Warning は分岐前に現 PR で解消する
- 判定順は `YAGNI → インライン修正 → Issue 化`
- 現在の根拠・利用者影響・受け入れ条件がなければ YAGNI とし、対応も Issue 化もしない
- 必要かつ軽微（10 行以内・同一ファイル・仕様判断不要・別モジュール波及なし・独立検証不要・既存契約不変の全条件）なら現 PR で修正する
- 仕様判断・別モジュール・独立検証が必要なら Issue 化ルートへ進む
- Issue 化の前に類似 Issue を検索し、同じ完了条件なら既定はコメントでまとめる。本文 AC は明示許可と競合確認がある場合だけ最小追記する
- 完了条件が独立する場合だけ、既存 Issue と関連付けた新規 Issue を作成する

## 🚨 Secrets Exposure Prevention
- secret を stdout/stderr に出すコマンドを実行しない（境界5）。エージェントの出力（トランスクリプト・ログ・PR コメント）は永続化され、値が一度でも出たら「露出」としてローテーション判断が必要になる
- env ファイル・プロセス環境の全ダンプを禁止（`cat .env*` / `printenv` / `env` / `console.log(process.env)` 等）。個別キーでも値全体を出さない（`printenv KEY` / `echo $KEY` を含む）
- secret を読み込む CLI に `--debug` / `--verbose` を付ける前に、失敗時に何をダンプするかを確認する。不明なら付けない
- 値の診断・ログ出力は prefix（先頭5字）+ length まで
- 露出した場合は隠さず即報告し、露出したキーと範囲を列挙する
- [プロジェクトの技術スタックから、対象となる secret（接続文字列・署名鍵・API キー等）と、それを出力し得る具体的コマンドを検出して列挙する。例示のコマンドはそのまま転記せず、実際に使うスタックのものへ置き換えること（例示: `supabase --debug` / `vercel env pull /dev/stdout` / `gh auth token` / `stripe config --list`）]

## 🚨 Information Verification Protocol
情報が不足している場合は推測せず、必ず確認を求める（境界3）。
[MASTER.md の確認プロトコルを含める]

## Tool-Specific Config
- Claude Code: `CLAUDE.md`
- GitHub Copilot: `.github/copilot-instructions.md`
```

### 6. Multi-CLI Agent Orchestrator のセットアップ

セットアップスクリプトを実行して、Multi-CLI Agent Orchestrator（review / explore / implement の3タスク）を構成します:

```bash
bash "${FF_DEV_TOOLKIT_ROOT}/scripts/setup-multi-agent.sh"
```

このスクリプトが行うこと:

- yq（YAMLパーサー）の確認・インストール
- 5つのAI CLI（Claude Code / Codex / Copilot / Gemini / Grok）の検出
- 未インストールCLIのインストールガイド表示
- `multi-agent.sh --dry-run` による動作確認

セットアップ完了後、以下で利用できます（いずれも本プラグイン同梱）:

- Claude Code: `/multi-review` / `/multi-explore` / `/multi-implement`
- ターミナル: `bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-agent.sh" --task <review|explore|implement>`

設定のカスタマイズ: プロジェクト側に `.claude/agent-config.yaml` を置くとプラグイン同梱のデフォルト設定より優先される（環境変数 `MULTI_AGENT_CONFIG=<path>` または `--config <path>` でも上書き可）。

### 7. 完了報告

生成したファイルの一覧と、各ファイルの要約を表示してください。
Multi-CLI Agent Orchestrator のセットアップ結果も含めて報告してください。

### 8. （任意）ACE autonomous テンプレートの案内

ユーザーが **ACE ナレッジキャプチャの autonomous 化**（post-merge → subagent → worktree）に関心を示した場合、または Multi-CLI / Git 運用の文脈で自動化を聞かれた場合のみ、利用中のホストの質問機能または通常の対話で希望を確認する。

- **オプション例**: 「案内する」/「スキップ」
- **案内する**を選んだ場合: `${FF_DEV_TOOLKIT_ROOT}/docs-template/05-operations/deployment/ace-autonomous.md`、`${FF_DEV_TOOLKIT_ROOT}/docs-template/scripts/ace/`、`${FF_DEV_TOOLKIT_ROOT}/docs-template/.claude/agents/ace-capture.md` テンプレのコピー先、環境変数（`ACE_SUBAGENT_ENABLED` / `ACE_SUBAGENT_AUTO_MERGE` / `ACE_GARDEN_WALL_PATHS`）の **明示 opt-in** を説明する。

## 重要ルール

- 既存ファイルがある場合は上書き前に必ず確認すること
- docs/ の内容を正確に反映すること（推測で情報を追加しない）
- 生成する3ファイル（CLAUDE.md / AGENTS.md / copilot-instructions.md）には、ツールを問わず「標準への入口」5境界（**MASTER 先行参照 / 索引からの到達 / 情報不足時の確認プロトコル / スコープ外発見の YAGNI・インライン・Issue 化 / Secrets 露出防止**）を等価に含めること（CLAUDE.md だけの要件ではない）
- 各ツール固有のフォーマットや慣習に従うこと
- 生成後、ファイルの内容をユーザーに確認してもらうこと
- 生成物が5境界を等価に含むことは `plugins/ff-dev-toolkit/tests/setup-ai-config/verify.sh` で検証できる
