# PLAYBOOK — テスト (testing)

> **Parent**: [PLAYBOOK.md](../PLAYBOOK.md) — 運用ルール・エントリテンプレート・ID規則・記述ガイドラインは親ファイルの SSOT を参照。
>
> 新規エントリは本ファイル末尾に追記し、[PLAYBOOK.md の索引テーブル](../PLAYBOOK.md#エントリ一覧)にも 1 行追加する。

---

## エントリ一覧

<a id="ace-441-1"></a>

### ACE-441-1: ドキュメントを走査するツールの正規表現を緩めるときは実ファイルで件数検証し、パターンを「実 ID の形」に制約する

| フィールド | 値                   |
| ---------- | -------------------- |
| Category   | testing              |
| Origin     | PR #441 / Issue #440 |
| Related    | ACE-042 / ACE-028    |
| Date       | 2026-05-30           |
| Helpful    | 0                    |
| Harmful    | 0                    |
| Status     | active               |

**Insight**: ドキュメント（PLAYBOOK 等）を走査するスクリプトの見出し検出正規表現を緩めると、その doc 自身が含む **テンプレート/例の placeholder 見出し**（code fence 内の `### ACE-XXX:` 等）まで誤検出しうる。合成 fixture のユニットテストは green でも、実ファイルに対して走らせて初めて件数ズレが露見する。パターンは「拾いたい実体の形」（ID なら数字始まり / `i`＋数字始まり）に制約してテンプレ placeholder を構造的に除外し、緩和後は必ず**本物のファイル**に対して件数を検証する。

**Context**: PR #441 で ACE エントリ ID を PR スコープ式に変える際、`check-category-size.ts` の検出正規表現を `/^### ACE-\d{3,}:/m` → `/^### ACE-[\w-]+:/m` に緩めた。ユニットテスト（合成 fixture）は通ったが、実 PLAYBOOK に `ace:check-playbook-categories` を走らせると総エントリ数が 46→47 になり `coding / architecture / testing / ...` という不自然なカテゴリが出現。原因は緩めた `[\w-]+` がエントリテンプレート（code fence 内）の `### ACE-XXX:` を実エントリとして拾ったこと。旧 `\d{3,}` は `XXX`（非数字）を弾いていたため顕在化していなかった。実装プランの正規表現案が緩すぎた欠陥を、プランの「実ファイル検証」ステップが捕捉した。

**Action**:

1. doc を parse するツールの正規表現を緩めたら、**合成 fixture だけでなく本物のファイルに対して走らせ、件数・カテゴリの妥当性を目視確認する**（プランに「実ファイル検証」ステップを必ず入れる）。
2. パターンは拾いたい実体の形に制約する。ID 検出なら `/^### ACE-(?:\d[\w-]*|i\d[\w-]*):/m`（数字始まり / `i`＋数字始まり）で doc 内のテンプレ placeholder（`ACE-XXX`/`NNN`）を除外。
3. placeholder 除外を回帰テストで固定する（`ACE-XXX` / `ACE-NNN` / `i`＋非数字 `ACE-iabc` を含めて「集計されない」ことを assert）。

---
