---
title: "ARCHITECTURE"
version: "0.1.0"
status: "draft"
owner: "@orbit-team"
created: "2026-06-01"
updated: "2026-07-22"
changeImpact: "medium"
---

# ARCHITECTURE.md — Orbit

## システム構成

SPA フロントエンド + REST API バックエンド + リレーショナル DB の3層構成。

```
[React SPA] --HTTPS--> [Express API] --SQL--> [PostgreSQL]
```

## 技術スタック

- 言語: TypeScript 5.4
- フロントエンド: React 18.2
- バックエンド: Node.js 22.3 / Express 4.19
- データベース: PostgreSQL 16.2

## コンポーネント設計

- `interfaces/`: REST コントローラ
- `usecases/`: アプリケーションロジック
- `infrastructure/`: DB リポジトリ・外部クライアント

## 設計判断記録（ADR）

- ADR-001: Clean Architecture を採用（依存を内向きに限定するため）

## ビジネスルールに関する注記

> 注: タスクの状態遷移ルール（未着手→進行中→完了、完了からの差し戻し可否）と、
> マイルストーン締切超過時の扱いは、現状このコード近辺のコメントと本節に散在している。
> 例: `if (task.status === 'done' && !allowReopen) throw ...`（差し戻し禁止のビジネスルール）。
