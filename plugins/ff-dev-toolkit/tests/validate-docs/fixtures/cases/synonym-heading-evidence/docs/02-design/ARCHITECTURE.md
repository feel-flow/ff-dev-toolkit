---
title: "ARCHITECTURE"
version: "2.1.0"
status: "approved"
owner: "@atlas-team"
created: "2026-06-01"
updated: "2026-07-22"
changeImpact: "high"
---

# ARCHITECTURE.md — Atlas

## システム構成図

エッジキャッシュ + タイル生成サービス + PostGIS の3層。

```
[CDN エッジ] --> [タイル生成 (Rust)] --> [PostGIS]
```

## 技術スタック

- 言語: Rust 1.79
- Web: axum 0.7
- データベース: PostgreSQL 16 + PostGIS 3.4
- インフラ: GCP Cloud Run functions-framework 0.9

## コンポーネント設計

- `crates/tiler/`: タイル生成
- `crates/cache/`: キャッシュ制御

## 設計判断記録（ADR）

- ADR-001: Rust + axum を採用（低レイテンシとメモリ安全のため）
