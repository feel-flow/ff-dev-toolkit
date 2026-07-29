# GitHub Copilot Instructions — TaskFlow

## 🚨 MANDATORY: Read MASTER.md First

Before generating any code suggestions, you MUST read `docs/MASTER.md` first（境界1）.
Use the MASTER.md index to reach the relevant specification for your task（境界2）.

## Project Overview

- TaskFlow — 小規模チーム向けのタスク管理 SaaS
- 対象ユーザー: 5〜30 名のプロダクトチーム

## Technology Stack

- TypeScript (strict) / React 18 / Node.js 22 / Express
- PostgreSQL / JWT 認証

## Coding Standards

- No `any` types (use `unknown` or proper types)
- No magic numbers — extract to named constants
- Result pattern for error handling
- Functions under 30 lines
- 詳細は `docs/03-implementation/PATTERNS.md`

## Key Architecture Decisions

- Clean Architecture / Repository パターン
- 詳細は `docs/02-design/ARCHITECTURE.md`

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
- TaskFlow の対象 secret とコマンド: `DATABASE_URL`（PostgreSQL 接続文字列）・JWT 署名鍵が対象。`npm config list -l`（`.npmrc` のトークンを表示）・`psql` の接続文字列を argv に置く実行・`node -e 'console.log(process.env)'` は実行しない

## 🚨 Information Verification Protocol

When information is missing, DO NOT make assumptions — always ask for confirmation（境界3）.

Required confirmations:

- Project name, target users, main features
- Technology stack (database type, auth method, API format, etc.)
- Performance and security requirements

詳細は `docs/MASTER.md` の「情報不足時の必須確認プロトコル」を参照。

## Reference Documents

- `docs/MASTER.md` — Central coordination document (read this first)
- `docs/01-context/PROJECT.md` — Project vision and requirements
- `docs/02-design/ARCHITECTURE.md` — Technical architecture
- `docs/03-implementation/PATTERNS.md` — Implementation patterns
