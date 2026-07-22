---
title: "ARCHITECTURE"
version: "0.2.0"
status: "draft"
owner: "@sprout-dev"
created: "2026-06-01"
updated: "2026-07-22"
changeImpact: "medium"
---

# ARCHITECTURE.md — Sprout

## システム構成

モバイルアプリ + BaaS（Firebase）。ローカルキャッシュでオフライン対応する。

```
[Flutter アプリ] <--SDK--> [Firebase (Firestore / Auth 未使用)]
```

## 技術スタック

- 言語: Dart 3.4
- フレームワーク: Flutter 3.22
- バックエンド: Firebase Firestore API v1

## コンポーネント設計

- `lib/features/`: 機能別ウィジェット + ロジック
- `lib/data/`: Firestore アクセス・ローカルキャッシュ

## 設計判断記録（ADR）

- ADR-001: Firestore を採用（オフライン同期が標準で使えるため）
