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

## 🚨 Information Verification Protocol

情報が不足している場合は推測せず、必ず確認を求める（境界3）。
詳細は `docs/MASTER.md` の「情報不足時の必須確認プロトコル」を参照。

## Tool-Specific Config

- Claude Code: `CLAUDE.md`
- Cursor: `.cursor/rules/*.mdc`（Legacy `.cursorrules`）
- GitHub Copilot: `.github/copilot-instructions.md`
