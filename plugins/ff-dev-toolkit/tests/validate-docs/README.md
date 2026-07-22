# validate-docs 検証規則・fixture 回帰テスト

`/validate-docs`（`plugins/ff-dev-toolkit/commands/validate-docs.md`）の文書検証規則が、
PR #90 で標準へ整合した状態から drift しないことを検証するための fixture / 回帰テストです（Issue #94）。

## なぜ3層構成か

文書の充足判定そのものはプロンプト実行（LLM）を伴うため、シェルだけでは「docs セット→判定」を再現できません。
そこで検証を**機械照合可能な範囲**に絞り、次の3層で回帰を捕捉します。

| 層 | 何を検証するか | 実行 |
|---|---|---|
| **(A) 生成器の検証規則ドリフト** | コマンド定義（プロンプト本体）が検証規則を今も含むか。規則が削除／別の場所へ移動すると FAIL | `verify.sh`（完全自動） |
| **(B) docs-template / init-docs 互換性** | `/init-docs` がコピーする正規テンプレートと初期化手順が、`/validate-docs` の Frontmatter スキーマ（特に `changeImpact` 小文字値）と矛盾しないか | `verify.sh`（完全自動） |
| **(C) fixture 自己整合** | 各ケースが docs セット＋期待（採点者専用）を持ち、期待が**実在の生成器規則へ紐づく**か | `verify.sh`（完全自動） |
| **(D) ブラインド実行** | docs セットを実行エージェントへ渡し、出力を期待で採点（判定そのものの検証） | 手動／エージェント |

(A) は ACE-86-1（凍結スナップショットだけでは drift を検出できない＝生成器＝プロンプト本体を検証する）に従い、
検証規則の在処（コマンド定義の**節**）へ構造スコープします。規則を説明文の別の場所へ逃がしても FAIL します。
(B) は `/init-docs` → `/validate-docs` の推奨フローが自己矛盾しないための互換性ガードです。

## 検証する判定規則（PR #90 由来）

`verify.sh` の (A) が、コマンド定義の該当節にこれらの規則が存在することを確認します:

- 常時必須は **MASTER・PROJECT・ARCHITECTURE の3文書**、残る4文書は未作成なら N/A
- **N/A にできるのは判断マトリクス上も不要な場合だけ**（必要性の兆候があれば ❌）
- 必要性の兆候の検出（DOMAIN: ビジネスルール散在 / TESTING: テストコード存在 など）
- 必須セクションは**見出し文字列一致でなく内容の責務で判定**し、**充足の根拠（対応見出し+要旨）を出力**する
- 空セクションの状態明記チェック（「該当なし」等があれば ✅、なければ ❌）
- **Frontmatter スキーマチェック**（Issue #93）: 存在する文書の先頭 YAML Frontmatter について、必須6フィールド（title / version / status / owner / created / updated）の充足・version の SemVer 形式・status の値域（draft / review / approved / deprecated）・変更済み文書の changeImpact 記録と小文字（low / medium / high）を検証し、違反は ❌ として最終判定に反映する
- **全体スコア = 充足項目数 ÷ 判定対象項目数**で算出し、**N/A はスコアの分母から除外**する
- **最終判定は ❌ ゼロ**（達成 / 未達）
- 番号付きフォルダ名の揺れ（01-context vs 01-business）を許容

## テストケース（fixtures/cases/）

| ケース | 入力 docs の要旨 | 期待総合判定 | 検証する規則 |
|---|---|---|---|
| `domain-signs-not-na` | 必須3文書のみ。ただし ARCHITECTURE にビジネスルールが散在 | 未達 | 兆候あり未作成は N/A でなく ❌ |
| `empty-section-stated-ok` | DOMAIN「状態遷移」が空だが「該当なし」明記 | 達成 | 状態明記のある空セクションは ✅ |
| `empty-section-unstated-ng` | MASTER「重要な制約」が見出しのみで状態明記なし | 未達 | 状態明記なしの空セクションは ❌ |
| `frontmatter-invalid-ng` | 本文は満たすが Frontmatter に4種の違反（MASTER: 必須フィールド欠落 / PROJECT: version 非SemVer・changeImpact 未記録 / ARCHITECTURE: status 値域外・changeImpact 大文字） | 未達 | Frontmatter スキーマ違反は ❌ として最終判定に反映（Issue #93） |
| `na-clean-pass` | 必須3文書のみ、条件付き4文書は兆候なし未作成 | 達成 | N/A を分母から除外し達成 |
| `score-mixed-denominator` | 技術スタックのバージョン不足（❌）+ 条件付き4文書は N/A | 未達 | ❌ と N/A が混在しても N/A を分母から除外し、最終判定は ❌ ゼロ |
| `synonym-heading-evidence` | 同義見出し＋フォルダ番号揺れ（01-business） | 達成 | 内容の責務で充足判定＋根拠出力 |

各ケースは以下を持ちます:

- `docs/` — 実行エージェントへ渡すサンプルの docs セット（コア文書一式）
- `project-context.md` — 実行エージェントへ `docs/` と一緒に渡す入力。テストコード・CI/CD・本番環境・コードコメントなど docs 外の**事実のみ**を固定し、周辺ワークスペース依存の N/A 判定を防ぐ（`N/A` / `必要` / `未達` などの期待判定ラベルは書かない）
- `expected.md` — **採点者専用**の合格条件。冒頭に「実行エージェントには渡さない」注記あり。
  機械照合フィールド（`- 期待総合判定:` / `- 検証する生成器規則:`）を含む

## ディレクトリ構成

```
tests/validate-docs/
├── README.md                 # このファイル
├── verify.sh                 # (A) 規則ドリフト + (B) テンプレ互換性 + (C) fixture 自己整合の機械検証
└── fixtures/
    └── cases/
        ├── domain-signs-not-na/{docs/…, project-context.md, expected.md}
        ├── empty-section-stated-ok/{docs/…, project-context.md, expected.md}
        ├── empty-section-unstated-ng/{docs/…, project-context.md, expected.md}
        ├── frontmatter-invalid-ng/{docs/…, project-context.md, expected.md}
        ├── na-clean-pass/{docs/…, project-context.md, expected.md}
        ├── score-mixed-denominator/{docs/…, project-context.md, expected.md}
        └── synonym-heading-evidence/{docs/…, project-context.md, expected.md}
```

## 実行方法

```bash
bash plugins/ff-dev-toolkit/tests/validate-docs/verify.sh
```

全 fixture 検証をまとめて実行する場合:

```bash
bash plugins/ff-dev-toolkit/tests/run-all.sh
```

`verify.sh` は read-only 環境でも動作します（here-string / heredoc 不使用、`printf ... | cmd`。ACE-86-2）。
`TMPDIR=/nonexistent bash plugins/ff-dev-toolkit/tests/validate-docs/verify.sh` でも実行できます。

### ブラインド実行（層 D）

1. 対象ケースの `docs/` と `project-context.md` を実行エージェントへ渡す（`expected.md` は渡さない）。
2. その `docs/` と docs 外の事実を対象に `/validate-docs` を実行させる。
3. 出力を `expected.md` の合格条件（期待総合判定・期待キーワード・過剰判定の禁止）で採点する。

## メンテナンス

- コマンド定義（`validate-docs.md`）の**節番号**や規則の文言を変えたら、
  `verify.sh` の `GENERATOR_RULES`（節の開始/終了 regex・検索文字列）を追随させること。
  最終節（重要ルール）は終了 regex に次の level-2 見出し（`^## `）を使う。現在は後続見出しが無いため EOF まで読むが、将来 `##` 節が追加されたらそこで止める。
- `/validate-docs` の Frontmatter 規則を変えたら、`docs-template/` と `/init-docs` の置換ポリシーも同じ標準へ追随させること。`verify.sh` は `docs-template` の frontmatter `changeImpact` が小文字値であること、`MASTER.md` の標準表が `low / medium / high` であること、`/init-docs` が小文字正規化を指示していることを検証する。
- 新しいエッジケースを足すときは `fixtures/cases/<name>/` に `docs/…` と `expected.md` を追加する。
  `expected.md` には2つの機械照合フィールドを必ず含め、`検証する生成器規則` はコマンド定義に実在する文字列にする
  （実在しないと (C) で FAIL する＝fixture と生成器の乖離検出）。
- 条件付き文書の未作成分岐を期待するケースは、`project-context.md` に docs 外の事実（テストコード・CI/CD・本番環境・コードコメント等）を明記し、`verify.sh` の `context_anchors_for_case` と `absent_docs_for_case` にも期待値を追加する。ただし `project-context.md` には期待判定ラベル（`N/A` / `必要` / `未達` など）を書かない。
- 機械照合フィールドは行頭に `- ラベル: 値`（半角コロン+スペース）で書く。全角コロンやインデントはフィールド欠落として扱われる。
- 新規ケースを追加したら `verify.sh` の `REQUIRED_CASES` と `expected_verdict_for_case` にも期待値を追加する。
- 「達成」期待の fixture は、対象エッジケース以外の必須文書・必須セクション・内容品質も満たすこと。無関係な ❌ が混ざると期待総合判定が崩れる。**各コア文書には有効な YAML Frontmatter（必須6フィールド・SemVer version・値域内 status・変更済み文書の changeImpact 記録と小文字値）を付与する**こと。Frontmatter が無い／違反があると Frontmatter スキーマチェックで ❌ になり、対象外のエッジケースを検証する fixture の期待総合判定が崩れる（Issue #93）。Frontmatter 違反そのものを検証したい場合のみ `frontmatter-invalid-ng` のように意図的に違反を仕込み、`project-context.md` の補足で「失敗対象は Frontmatter に限定」と明記する。
- 修正が「本物」か確かめるには、コマンド定義から規則を1つ削って `verify.sh` が FAIL することを確認する（負例テスト）。
