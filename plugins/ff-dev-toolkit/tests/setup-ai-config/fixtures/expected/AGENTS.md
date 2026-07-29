# AGENTS.md — TaskFlow

Codex CLI / 汎用 AI エージェント共通の開発ガイド（[agents.md](https://agents.md) 標準）。
詳細は複製せず、正本（`docs/MASTER.md` 等）を参照する。

## 🚨 MANDATORY: Read MASTER.md First

作業やコード生成の前に、必ず `docs/MASTER.md` を最初に読む（境界1）。
関連仕様には MASTER.md の索引（各 `docs/NN-*` へのリンク）から到達する
（Use the MASTER.md index to reach the relevant specification）（境界2）。

## Project Overview

- TaskFlow — 小規模チーム向けのタスク管理 SaaS
- 対象ユーザー: 5〜30 名のプロダクトチーム

## Tech Stack

- TypeScript (strict) / React 18 / Node.js 22 / Express
- PostgreSQL / JWT 認証

## Build & Test Commands

- `npm run dev` — 開発サーバ
- `npm run test` — テスト
- `npm run lint` — Lint

## Coding Style

- `any` 型禁止（`unknown` か適切な型）
- Never use magic numbers — extract to named constants
- エラーハンドリングは Result パターン
- 関数は 30 行以内
- 詳細は `docs/03-implementation/PATTERNS.md`

## Commit & PR Guidelines

- Issue 起票 → ブランチ → 実装 → セルフレビュー → PR → マージ
- コミットは `<type>: #<issue> <subject>`
- PR に Issue リンク（例: `Closes #123`）を含める

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

情報が不足している場合は推測せず、必ず確認を求める（境界3）。
詳細は `docs/MASTER.md` の「情報不足時の必須確認プロトコル」を参照。

## Tool-Specific Config

- Claude Code: `CLAUDE.md`
- Cursor: `.cursor/rules/*.mdc`（Legacy `.cursorrules`）
- GitHub Copilot: `.github/copilot-instructions.md`
