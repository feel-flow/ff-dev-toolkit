---
title: "ARCHITECTURE"
version: "1.0.0"
status: "approved"
owner: "@ledger-team"
created: "2026-06-01"
updated: "2026-07-22"
changeImpact: "low"
---

# ARCHITECTURE.md — Ledger

## システム構成

単一バイナリのデスクトップアプリ。ローカル SQLite にデータを保存する。

```
[Svelte UI] <--IPC--> [Go コア] <--SQL--> [SQLite]
```

## 技術スタック

- 言語: Go 1.22
- フロントエンド: Svelte 4.2
- データベース: SQLite 3.45

## コンポーネント設計

- `internal/usecase/`: 収支記録・集計ロジック
- `internal/storage/`: SQLite アクセス

## 設計判断記録（ADR）

- ADR-001: SQLite を採用（オフラインファースト要件のため）
