# expected: frontmatter-invalid-ng — Frontmatter スキーマ違反は ❌ として最終判定に反映する

> このファイルはブラインドテストの採点者用。fixture（docs/ セット）を処理する実行エージェントには渡さないこと。

<!-- 機械照合フィールド（verify.sh が解析する。`- ラベル: 値` 形式・半角コロン+スペース区切り） -->
- 期待総合判定: 未達
- 検証する生成器規則: Frontmatter スキーマ違反は ❌ として扱い、最終判定（達成 / 未達）に反映する

## 入力の要旨

- 必須3文書（MASTER / PROJECT / ARCHITECTURE）は存在し、本文の必須セクション・内容品質は満たす。
- ただし各コア文書の先頭 YAML Frontmatter に、それぞれ別種のスキーマ違反が仕込まれている:
  - MASTER.md — 必須6フィールドのうち `owner` と `updated` が欠落している。
  - PROJECT.md — `version` が `1.0` で SemVer（`x.y.z`）形式でなく、`created` と `updated` が異なる変更済み文書なのに `changeImpact` が未記録。
  - ARCHITECTURE.md — `status` が値域外（`Draft`）かつ `changeImpact` が大文字（`HIGH`）。
- `project-context.md` により、条件付き4文書は未作成かつ必要性の兆候もないことが固定されている（N/A）。

## 判定規則

- 不合格項目に1件でも該当したら総合 FAIL。
- 各項目は本ファイルの基準のみで判定し、採点者の裁量で基準を追加しない。

## 合格条件（必須）

1. MASTER.md の Frontmatter を **❌（必須フィールド欠落）**として指摘し、欠落フィールド（`owner` / `updated`）を挙げること。
2. PROJECT.md の Frontmatter を **❌（version が SemVer 形式でない・changeImpact 未記録）**として指摘すること。
3. ARCHITECTURE.md の Frontmatter を **❌（status 値域外・changeImpact 大文字）**として指摘すること。
4. **総合判定が「未達」**であること（❌ が残るため。「達成」としたら不合格）。
5. 条件付き4文書は **➖ N/A** として扱い、Frontmatter 違反とは無関係に減点しないこと。

## 期待キーワード（実行結果に含まれるべき語のいずれか）

- `Frontmatter`
- `version` または `SemVer` または `status` または `changeImpact` または `欠落`
- `未達`

## 過剰判定の禁止

- Frontmatter が有効なフィールド（例: MASTER の `title` / `version` / `status`）を違反として誤指摘したら不合格。
- 本文の必須セクション・内容品質・クロスリファレンスを ❌ にしたら不合格（違反は Frontmatter に限定されている）。
- `changeImpact` が存在しない文書でも、初版など変更済みと判断できない文書について「changeImpact 欠落」を指摘したら不合格。
