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
