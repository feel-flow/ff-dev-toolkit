# CLAUDE.md

## 🚨 MANDATORY: Read MASTER.md First

作業やコード生成の前に、必ず `docs/MASTER.md` を最初に読むこと（境界1）。
関連する仕様には MASTER.md の索引（各 `docs/NN-*` へのリンク）から到達すること
（Use the MASTER.md index to reach the relevant specification for your task）（境界2）。

## Project Overview

- **プロジェクト名**: TaskFlow
- **目的**: 小規模チーム向けのタスク管理 SaaS
- **対象ユーザー**: 5〜30 名のプロダクトチーム

## Architecture

- Clean Architecture / Repository パターン
- 詳細は `docs/02-design/ARCHITECTURE.md` を参照

## Coding Standards

- TypeScript strict、`any` 型禁止（`unknown` か適切な型）
- マジックナンバー禁止（名前付き定数に抽出）
- エラーハンドリングは Result パターン
- 関数は 30 行以内
- 詳細は `docs/03-implementation/PATTERNS.md` を参照

## Build Commands

- `npm run dev` — 開発サーバ
- `npm run test` — テスト
- `npm run lint` — Lint

## Development Workflow

- Issue 起票 → ブランチ → 実装 → セルフレビュー → PR → マージ
- コミットは `<type>: #<issue> <subject>`

## 🚨 Information Verification Protocol

情報が不足している場合は推測せず、必ず確認を求めること（境界3）。

### Required Confirmations

- プロジェクト名、対象ユーザー、主要機能
- 技術スタック（DB 種別、認証方式、API 形式 等）
- パフォーマンス・セキュリティ要件

### Confirmation Format

```
⚠️ 情報不足により確認が必要です

【必須確認事項】
1. [項目名]: [何が不明か]
   - 理由: [なぜ確認が必要か]
   - 推奨: [推奨される選択肢]

【次のステップ】
上記を確認後、「[確認された情報]で進めてください」と指示してください。
```

詳細は `docs/MASTER.md` の「情報不足時の必須確認プロトコル」を参照。
