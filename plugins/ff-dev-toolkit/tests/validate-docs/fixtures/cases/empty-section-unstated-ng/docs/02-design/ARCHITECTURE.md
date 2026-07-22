---
title: "ARCHITECTURE"
version: "0.3.0"
status: "review"
owner: "@beacon-team"
created: "2026-06-01"
updated: "2026-07-22"
changeImpact: "medium"
---

# ARCHITECTURE.md — Beacon

## システム構成

イベント駆動。受信ワーカーがアラートを正規化し、ルーティングエンジンが配信する。

```
[監視系] --Webhook--> [受信API] --Queue--> [ルーティング] --> [通知チャネル]
```

## 技術スタック

- 言語: Python 3.12
- フレームワーク: FastAPI 0.111
- データストア: Redis 7.2
- インフラ: AWS ECS Fargate

## コンポーネント設計

- `app/ingest/`: アラート受信・正規化
- `app/routing/`: 担当者ルーティング
- `app/notify/`: 通知チャネルアダプタ

## 設計判断記録（ADR）

- ADR-001: Redis Streams をキューに採用（軽量・低遅延のため）
