# 判定例（/out-of-scope-issue）

`/out-of-scope-issue` の SKILL.md「1. 判定（順序を変えない）」で A / B / YAGNI の境界に迷ったときに読む。判定の規則そのものの正本は SKILL.md 側で、ここは規則を当てた例だけを置く。

## 例 1: 別関数規模の重複 → B（Issue 化）

入力:
> 既存の `parseConfig` に約 60 行の重複ロジックを発見。共通ヘルパー抽出が望ましい（code-simplifier 指摘）

判定: B（10 行超 / 別関数規模 / 設計判断含む）→ Issue 化

出力:
```
Issue created: #1234 — refactor: parseConfig の重複ロジックを共通ヘルパーへ抽出
URL: https://github.com/owner/repo/issues/1234
```

## 例 2: docstring の typo → A（インライン）

入力:
> `formatDate` の docstring に typo「fomart」を発見

判定: A（typo・1 行。B の上書き条件に該当なし）→ インライン修正

出力:
> スコープ外だが docstring の typo (1 行) なので同 PR で修正します。

## 例 3: 触っていない近傍の設定ファイル → A（インライン）

入力:
> setup スクリプトが生成する 2 ファイルが `.gitignore` に載っておらず、`git add -A` で誤コミットされうる（レビュー指摘）。`.gitignore` は今回の PR では触っていない

判定: A（実装 7 行・近傍の設定ファイル・仕様判断不要。「触っていないファイル」だが B の上書き条件をどれも示せない）→ インライン修正

出力:
> スコープ外だが .gitignore への 7 行追加（近傍設定ファイル・仕様判断不要）なので同 PR で対応します。

## 例 4: 同一 PR の近接テーマ 2 件 → B を 1 Issue に束ねる

入力:
> 同一 PR のレビューで「エラーパスのテスト不足（独立 fixture が必要）」「同じ suite の timeout 値の見直し（負荷計測が必要）」の 2 件を発見

判定: どちらも B（独立検証が必要 — 新しい fixture・負荷計測環境の構築が要り、既存 suite への検査追加では足りない）で、同じ test suite というテーマが近接 → SKILL.md §3.1b により 1 つのフォローアップ Issue に束ねる

出力:
```
Issue created: #1240 — test: {suite 名} のエラーパス fixture 追加と timeout 実測見直し
URL: https://github.com/owner/repo/issues/1240
```

## 例 5: 将来に備えた抽象化 → YAGNI

入力:
> 将来別の永続化方式へ変える可能性に備えて、未使用の Repository 抽象化を追加したい

判定: YAGNI（現在の利用者・切替計画・受け入れ条件がない）→ 対応も Issue 化もしない

出力:
> YAGNI（理由: 現時点の利用者影響・切替計画・受け入れ条件がない）のため、対応・Issue 化はしません。

## 例 6: 既存 Issue と同じ完了条件 → 統合

入力:
> `PR #88` で認証エラー時の監査ログ不足を発見。既存 `Issue #72` の AC に同じ認証エラー経路が含まれる

判定: B（独立検証が必要）かつ既存 Issue と同じ完了条件 → 新規 Issue は作らず `#72` に統合（手順は [consolidation.md](consolidation.md)）

出力:
```
Consolidated into Issue #72 — fix: 認証エラー時の監査ログを補完する
URL: https://github.com/owner/repo/issues/72
```
