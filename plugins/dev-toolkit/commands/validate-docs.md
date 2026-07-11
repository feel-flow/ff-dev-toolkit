---
description: プロジェクトの docs/ がコア7文書要件（存在・セクション・内容・相互リンク）を満たしているか検証する
---

# /validate-docs — AI仕様駆動開発ドキュメント検証

プロジェクトの `docs/` ディレクトリが AI仕様駆動開発のコア7文書要件を満たしているか検証します。

## 検証項目

### 1. 必須ファイルの存在チェック

以下のコア7文書が存在するか確認します:

| # | ファイル | 必須 | 役割 |
|---|---------|------|------|
| 1 | `docs/MASTER.md` | ✅ | 中央管理ハブ |
| 2 | `docs/01-context/PROJECT.md` または `docs/01-business/PROJECT.md` | ✅ | ビジョン・要件 |
| 3 | `docs/02-design/ARCHITECTURE.md` | ✅ | システム設計 |
| 4 | `docs/02-design/DOMAIN.md` または `docs/01-context/DOMAIN.md` | ✅ | ビジネスロジック |
| 5 | `docs/03-implementation/PATTERNS.md` | ✅ | 実装パターン |
| 6 | `docs/04-quality/TESTING.md` または `docs/07-quality/TESTING.md` | ✅ | テスト戦略 |
| 7 | `docs/05-operations/DEPLOYMENT.md` | ✅ | 運用手順 |

**補助ドキュメント**（推奨）:

| ファイル | 推奨 | 役割 |
|---------|------|------|
| `docs/06-reference/GLOSSARY.md` | 推奨 | 用語集 |
| `docs/06-reference/DECISIONS.md` | 推奨 | 設計判断記録 |
| `docs/01-context/CONSTRAINTS.md` | 任意 | 制約条件 |
| `docs/03-implementation/CONVENTIONS.md` | 任意 | 命名・コーディング規約 |

### 2. MASTER.md 必須セクションチェック

MASTER.md に以下のセクションが含まれているか確認します:

- [ ] **プロジェクト識別情報**: プロジェクト名、バージョン、最終更新日
- [ ] **技術スタック要約**: FE/BE/DB/Infra のいずれかが記載
- [ ] **守るべきルール**: 命名規則 or コーディング規約の記載
- [ ] **情報不足時の必須確認プロトコル**: 推論禁止ルールの記載
- [ ] **ドキュメント索引**: 他ドキュメントへのリンク

### 3. 各ドキュメントの内容チェック

各ドキュメントに以下の最低限の内容があるか確認します:

- **空ファイルでないこと**: 各ファイルに10行以上の実質的な内容があること
- **見出し構造**: `##` レベルの見出しが1つ以上あること
- **プレースホルダーの残存**: `[プロジェクト名]` 等のテンプレート由来の角括弧プレースホルダー、frontmatter の `"@your-github-handle"`・`"YYYY-MM-DD"`、`{{` `}}`、`TODO` `TBD` が残っていないこと。ただし `/init-docs` の置換ポリシーで意図的に残される未確定値（`[金額]`・`[SLA値]`・`[x.x.x]` 等、プロジェクト情報では埋まらないもの）は「未確定値プレースホルダー（実装進行に伴い充足予定）」として別枠で報告する

### 4. クロスリファレンスチェック

- MASTER.md からの索引リンクが実際のファイルを指しているか
- 相対パスが正しいか
- **初期セット外テンプレートへの参照は区別する**: リンク切れのうち、**同一相対パスのファイルが `${CLAUDE_PLUGIN_ROOT}/docs-template/` に存在するもの**（例: `GETTING_STARTED*.md`、`05-operations/deployment/` 配下、`08-knowledge/` 等）は「リンク切れ」ではなく「未導入テンプレートへの参照（必要時に dev-toolkit プラグインの docs-template から追加コピー可）」として別枠で報告する。docs-template にも存在しないリンク先だけを真のリンク切れとして報告する

## 出力形式

検証結果を以下の形式で出力してください:

```markdown
## ドキュメント検証結果

### 必須ファイル
- ✅ MASTER.md — 存在 (xxx行)
- ✅ PROJECT.md — 存在 (xxx行)
- ❌ ARCHITECTURE.md — 未作成
- ...

### MASTER.md セクション
- ✅ プロジェクト識別情報
- ❌ 技術スタック要約 — 見つかりません
- ...

### 内容品質
- ⚠️ DOMAIN.md — プレースホルダー残存 (3箇所)
- ⚠️ PATTERNS.md — 内容が少ない (8行)
- ...

### クロスリファレンス
- ✅ 全リンク有効
- ❌ MASTER.md → docs/03-implementation/PATTERNS.md — リンク切れ
- ...

### サマリー
- 必須ファイル: 5/7 ✅
- MASTER.mdセクション: 3/5 ✅
- 全体スコア: 60% — 改善が必要

### 推奨アクション
1. ARCHITECTURE.md を作成してください（`/init-docs` で初期化可能）
2. MASTER.md に技術スタック要約を追加してください
3. ...
```

## 重要ルール

- 番号付きフォルダ名の揺れ（01-context vs 01-business）は許容する
- ファイル名の大文字小文字は区別しない
- docs/ 以外の場所（例: root直下のMASTER.md）にあるファイルも検出する
- 検証結果に基づいた具体的な改善アクションを必ず提示する
