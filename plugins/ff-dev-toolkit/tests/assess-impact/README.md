# assess-impact 判定規則・fixture 回帰テスト

`/assess-impact`（`plugins/ff-dev-toolkit/commands/assess-impact.md`）の影響度判定規則が、
PR #90 で標準へ整合した状態から drift しないことを検証するための fixture / 回帰テストです（Issue #94）。

## なぜ2層構成か

影響度の判定そのものはプロンプト実行（LLM）を伴うため、シェルだけでは「入力→判定」を再現できません。
そこで検証を**機械照合可能な範囲**に絞り、次の2層で回帰を捕捉します。

| 層 | 何を検証するか | 実行 |
|---|---|---|
| **(A) 生成器の判定規則ドリフト** | コマンド定義（プロンプト本体）が判定規則を今も含むか。規則が削除／別の場所へ移動すると FAIL | `verify.sh`（完全自動） |
| **(B) fixture 自己整合** | 各ケースが入力＋期待（採点者専用）を持ち、期待が**実在の生成器規則へ紐づく**か | `verify.sh`（完全自動） |
| **(C) ブラインド実行** | 入力を実行エージェントへ渡し、出力を期待で採点（判定そのものの検証） | 手動／エージェント |

(A) は ACE-86-1（凍結スナップショットだけでは drift を検出できない＝生成器＝プロンプト本体を検証する）に従い、
判定規則の在処（コマンド定義の**節**）へ構造スコープします。規則を説明文の別の場所へ逃がしても FAIL します。

## 検証する判定規則（PR #90 由来）

`verify.sh` の (A) が、コマンド定義の該当節にこれらの規則が存在することを確認します:

- 3分類（文言修正 / 概念追加 / 概念再定義）
- **LOW/MEDIUM の境界 = 波及の有無**
- **MEDIUM/HIGH の境界 = 既存設計の維持可能性**
- 変更量（行数・文字数・ファイル数）で判定しない
- 複合変更は**最も高い影響度**を全体として採る（最大影響度集約）
- HIGH 判定時: 実装着手前ゲート／ADR の要否判定／移行計画の要否判定

## テストケース（fixtures/cases/）

| ケース | 入力の要旨 | 期待分類 | 期待影響度 | 検証する境界・規則 |
|---|---|---|---|---|
| `ripple-wording-medium` | CI が解釈する文字列の文言修正 | 文言修正 | MEDIUM | 波及ありの文言修正は LOW でなく MEDIUM |
| `plain-wording-low` | 波及しない誤字修正（複数箇所） | 文言修正 | LOW | 変更量（複数箇所）で引き上げない |
| `concept-add-medium` | 後方互換ありのオプショナルパラメータ追加 | 概念追加 | MEDIUM | 既存設計の維持可能性 |
| `concept-redefine-high` | 認証方式の全面切替（後方互換なし） | 概念再定義 | HIGH | 枠組み再設計＋ADR/移行計画/着手前ゲート |
| `composite-max-high` | typo+ログ文言+DBスキーマ移行の混在 | 概念再定義 | HIGH | 最大影響度集約（低影響に紛れさせない） |

各ケースは以下を持ちます:

- `input.md` — 実行エージェントへ渡すサンプル入力（変更概要＋波及に関する事実）
- `expected.md` — **採点者専用**の合格条件。冒頭に「実行エージェントには渡さない」注記あり。
  機械照合フィールド（`- 期待分類:` / `- 期待影響度:` / `- 検証する生成器規則:`）を含む

## ディレクトリ構成

```
tests/assess-impact/
├── README.md                 # このファイル
├── verify.sh                 # (A) 規則ドリフト + (B) fixture 自己整合の機械検証
└── fixtures/
    └── cases/
        ├── ripple-wording-medium/{input,expected}.md
        ├── plain-wording-low/{input,expected}.md
        ├── concept-add-medium/{input,expected}.md
        ├── concept-redefine-high/{input,expected}.md
        └── composite-max-high/{input,expected}.md
```

## 実行方法

```bash
bash plugins/ff-dev-toolkit/tests/assess-impact/verify.sh
```

全 fixture 検証をまとめて実行する場合:

```bash
bash plugins/ff-dev-toolkit/tests/run-all.sh
```

`verify.sh` は read-only 環境でも動作します（here-string / heredoc 不使用、`printf ... | cmd`。ACE-86-2）。
`TMPDIR=/nonexistent bash plugins/ff-dev-toolkit/tests/assess-impact/verify.sh` でも実行できます。

### ブラインド実行（層 C）

1. 対象ケースの `input.md` **のみ**を実行エージェントへ渡す（`expected.md` は渡さない）。
2. `/assess-impact` を実行させる。
3. 出力を `expected.md` の合格条件（期待分類・期待影響度・期待キーワード・過検出/過少判定の禁止）で採点する。

## メンテナンス

- コマンド定義（`assess-impact.md`）の**節番号**や規則の文言を変えたら、
  `verify.sh` の `GENERATOR_RULES`（節の開始/終了 regex・検索文字列）を追随させること。
- 新しいエッジケースを足すときは `fixtures/cases/<name>/` に `input.md` と `expected.md` を追加する。
  `expected.md` には3つの機械照合フィールドを必ず含め、`検証する生成器規則` はコマンド定義に実在する文字列にする
  （実在しないと (B) で FAIL する＝fixture と生成器の乖離検出）。
- 機械照合フィールドは行頭に `- ラベル: 値`（半角コロン+スペース）で書く。全角コロンやインデントはフィールド欠落として扱われる。
- 新規ケースを追加したら `verify.sh` の `REQUIRED_CASES` と `expected_class_for_case` / `expected_impact_for_case` にも期待値を追加する。
- 修正が「本物」か確かめるには、コマンド定義から規則を1つ削って `verify.sh` が FAIL することを確認する（負例テスト）。
