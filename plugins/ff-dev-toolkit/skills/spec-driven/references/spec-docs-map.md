# 仕様文書の体系と判断マトリクス（spec-driven 用）

G1 仕様ゲート（SKILL.md Step 3）で使う。**「この変更はどの文書に書くべきか」を迷わず決める**ための地図。文書が未整備のプロジェクトでは `${CLAUDE_PLUGIN_ROOT}/docs-template/` から最小構成で始める。

## 7文書体系（コア）

| 文書 | 役割 | 欠けると AI が迷うこと |
|---|---|---|
| MASTER.md | 索引・地図（何がどこにあるか） | 無関係なコードを参照する |
| PROJECT.md | What / Why（ビジョン・要件・スコープ外） | 要件と違う実装 |
| ARCHITECTURE.md | How（技術選定・バージョン明記・ADR） | 既存と整合しない設計 |
| DOMAIN.md | ビジネスルールの唯一の置き場所 | ルール違反の実装 |
| PATTERNS.md | コードの書き方（規約・パターン） | 一貫性のないコード |
| TESTING.md | 何が正しいか（テスト戦略） | テストの漏れ / 過剰 |
| DEPLOYMENT.md | どう運用するか | 運用できない実装 |

全部を最初に作らない。**新規プロジェクトを立ち上げる場合**の推奨初期セットは MASTER + PROJECT + ARCHITECTURE の3文書で、実装に必要になった時点で DOMAIN / PATTERNS / TESTING を足す。**既存プロジェクトの変更（本スキルの通常ケース）では、変更が影響する文書だけを扱う**（SKILL.md Step 3。体系全体の底上げは別タスク）。テンプレートはプラグイン同梱の `${CLAUDE_PLUGIN_ROOT}/docs-template/` にある（frontmatter はテンプレート本体に組み込み済み。フル整備・検証は `/init-docs`・`/validate-docs` コマンドを使う）。

## 判断マトリクス（変更をどこに書くか）

| 情報の種類 | 置き場所 |
|---|---|
| なぜ作るか / 何を作るか / スコープ外 | PROJECT.md |
| 技術選定・構成・設計判断 | ARCHITECTURE.md |
| ビジネスルール・制約・用語 | DOMAIN.md |
| コードの書き方・パターン | PATTERNS.md |
| テスト戦略・品質基準 | TESTING.md |
| 環境・デプロイ・監視 | DEPLOYMENT.md |

迷ったときの最終基準: **「この情報が変わったとき、誰が気にするか」**（ビジネス側→PROJECT/DOMAIN、開発者→ARCHITECTURE/PATTERNS、運用→DEPLOYMENT）。

迷いやすい例: バリデーションルール→DOMAIN（チェックの実装方法は PATTERNS）/ エラーコード一覧→DOMAIN / 環境変数一覧→DEPLOYMENT / ページネーション実装→PATTERNS（上限値の根拠は DOMAIN）。

## 影響度評価（LOW / MEDIUM / HIGH）

| 影響度 | 例 | G1 での扱い |
|---|---|---|
| LOW | 文言修正・誤字・コメント | 該当文書のみ更新して先へ |
| MEDIUM | フィールド追加・オプション追加・API パラメータ追加 | 関連文書（DOMAIN/TESTING 等)の確認リストを作ってから先へ |
| HIGH | データモデル変更・破壊的変更・ビジネスルールの根本変更 | **一旦停止**。関係者確認・ADR 作成・移行計画の要否を判定してから先へ |

- バージョン更新の目安: LOW=patch / MEDIUM=minor / HIGH=major（frontmatter の version と changeImpact を更新）
- 変更したら文書の frontmatter（updated・version・changeImpact）を更新する

## 生きた仕様の4条件（G1 の前提）

(1) 参照可能（リポジトリ内 Markdown）(2) バージョン管理 (3) 単一の真実（重複・矛盾なし）(4) 機械可読。チャットログ・散在 Wiki に書いた「仕様」は仕様ではない。

## 文書がまだ無いプロジェクトでの振る舞い

- G1 で「対象文書が存在しない」場合、**その場で最小の文書を `${CLAUDE_PLUGIN_ROOT}/docs-template/` の対応テンプレートから起こす**（数行でよい。壮大な整備プロジェクトにしない）
- 既存コードと矛盾する記述を見つけたら、正がどちらかを確認してから書く（推測で仕様を「復元」しない）

## 出典

『AI仕様駆動開発』第2部
- 7文書と最小3文書: 2-2
- 判断マトリクス: 2-4
- 影響度・伝播: 2-5
- 生きた仕様: 2-1
- frontmatter・時限ルール: 2-3
