---
title: "ARCHITECTURE"
version: "0.4.0"
status: "review"
owner: "@compass-team"
created: "2026-06-01"
updated: "2026-07-22"
changeImpact: "medium"
---

# ARCHITECTURE.md — Compass

## システム構成

SPA + REST API + PostgreSQL の3層構成。

```
[Vue SPA] --HTTPS--> [Node API] --SQL--> [PostgreSQL]
```

## 技術スタック

- 言語: TypeScript
- フロントエンド: Vue
- バックエンド: Node.js
- データベース: PostgreSQL

## コンポーネント設計

- `interfaces/`: REST コントローラ
- `usecases/`: 決定ログの作成・更新履歴表示
- `infrastructure/`: PostgreSQL リポジトリ

## 設計判断記録（ADR）

- ADR-001: Clean Architecture を採用（依存を内向きに限定するため）
