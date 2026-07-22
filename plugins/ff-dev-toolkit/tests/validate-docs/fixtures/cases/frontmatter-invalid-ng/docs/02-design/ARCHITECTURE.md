---
title: "ARCHITECTURE"
version: "0.5.0"
status: "Draft"
owner: "@nimbus-team"
created: "2026-06-01"
updated: "2026-07-22"
changeImpact: "HIGH"
---

# ARCHITECTURE.md — Nimbus

## システム構成

Cloudflare Workers 上のスケジュールジョブ + 外部予報 API。通知は Slack Webhook で送る。

```
[Cron Trigger] --> [Worker] --SDK--> [予報 API]
                        |--Webhook--> [Slack]
```

## 技術スタック

- 言語: TypeScript 5.4
- ランタイム: Cloudflare Workers (workerd 2026-06)
- 予報 API: OpenWeather One Call API 3.0

## コンポーネント設計

- `src/scheduler.ts`: Cron ハンドラ・通知編成
- `src/forecast.ts`: 予報 API クライアント・フォールバック

## 設計判断記録（ADR）

- ADR-001: Workers Cron を採用（常駐サーバー不要でコスト最小のため）
