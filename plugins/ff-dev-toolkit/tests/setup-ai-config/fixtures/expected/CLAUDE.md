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

## Out-of-Scope Finding Routing

- 現 diff の回帰・現 Issue の AC・既存契約・必須品質ゲート・Critical / Warning は分岐前に現 PR で解消する
- 判定順は `YAGNI → インライン修正 → Issue 化`
- 現在の根拠・利用者影響・受け入れ条件がなければ YAGNI とし、対応も Issue 化もしない
- 必要かつ軽微（10 行以内・同一ファイル・仕様判断不要・別モジュール波及なし・独立検証不要・既存契約不変の全条件）なら現 PR で修正する
- 仕様判断・別モジュール・独立検証が必要なら Issue 化ルートへ進む
- Issue 化の前に類似 Issue を検索し、同じ完了条件なら既定はコメントでまとめる。本文 AC は明示許可と競合確認がある場合だけ最小追記する
- 完了条件が独立する場合だけ、既存 Issue と関連付けた新規 Issue を作成する

## 🚨 Secrets Exposure Prevention

- secret を stdout/stderr に出すコマンドを実行しない（境界5）。エージェントの出力（トランスクリプト・ログ・PR コメント）は永続化され、値が一度でも出たら「露出」としてローテーション判断が必要になる
- env ファイル・プロセス環境の全ダンプを禁止（`cat .env*` / `printenv` / `env` / `console.log(process.env)` 等）。個別キーでも値全体を出さない（`printenv KEY` / `echo $KEY` を含む）
- secret を読み込む CLI に `--debug` / `--verbose` を付ける前に、失敗時に何をダンプするかを確認する。不明なら付けない
- 値の診断・ログ出力は prefix（先頭5字）+ length まで
- 露出した場合は隠さず即報告し、露出したキーと範囲を列挙する
- TaskFlow の対象 secret とコマンド: `DATABASE_URL`（PostgreSQL 接続文字列）・JWT 署名鍵が対象。`npm config list -l`（`.npmrc` のトークンを表示）・`psql` の接続文字列を argv に置く実行・`node -e 'console.log(process.env)'` は実行しない

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
