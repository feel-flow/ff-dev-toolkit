# MASTER.md — TaskFlow

> このプロジェクトの中心となる調整ドキュメント。**作業前に必ず最初に読むこと。**
> 関連仕様へは、下の「ドキュメント索引」から到達する。

## プロジェクト識別

- **プロジェクト名**: TaskFlow
- **目的**: 小規模チーム向けのタスク管理 SaaS
- **対象ユーザー**: 5〜30 名のプロダクトチーム

## 技術スタック

- 言語: TypeScript (strict)
- フロントエンド: React 18
- バックエンド: Node.js 22 / Express
- データベース: PostgreSQL
- 認証: JWT

## アーキテクチャ

- Clean Architecture / Repository パターン
- 詳細は `docs/02-design/ARCHITECTURE.md`

## コーディングルール

- `any` 型禁止（`unknown` か適切な型を使う）
- マジックナンバー禁止（名前付き定数に抽出する）
- エラーハンドリングは Result パターン
- 関数は 30 行以内
- 詳細は `docs/03-implementation/PATTERNS.md`

## ビルド・テストコマンド

- `npm run dev` — 開発サーバ
- `npm run test` — テスト
- `npm run lint` — Lint

## Git ワークフロー

- Issue 起票 → ブランチ → 実装 → セルフレビュー → PR → マージ
- コミットは `<type>: #<issue> <subject>`
- PR に Issue リンク（例: `Closes #123`）を含める

## ドキュメント索引

| 領域 | ファイル |
|------|----------|
| 要件・ビジョン | `docs/01-context/PROJECT.md` |
| アーキテクチャ | `docs/02-design/ARCHITECTURE.md` |
| 実装パターン | `docs/03-implementation/PATTERNS.md` |
| テスト戦略 | `docs/04-quality/TESTING.md` |
| デプロイ | `docs/05-operations/DEPLOYMENT.md` |

## 情報不足時の必須確認プロトコル

情報が不足している場合は推測で埋めず、必ず確認を求めること。

### 必須確認事項

- プロジェクト名、対象ユーザー、主要機能
- 技術スタック（DB 種別、認証方式、API 形式 等）
- パフォーマンス・セキュリティ要件

### 確認の出力形式

```
⚠️ 情報不足により確認が必要です

【必須確認事項】
1. [項目名]: [何が不明か]
   - 理由: [なぜ確認が必要か]
   - 推奨: [推奨される選択肢]

【次のステップ】
上記を確認後、「[確認された情報]で進めてください」と指示してください。
```
