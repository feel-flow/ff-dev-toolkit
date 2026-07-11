# PLAYBOOK — セキュリティ (security)

> **Parent**: [PLAYBOOK.md](../PLAYBOOK.md) — 運用ルール・エントリテンプレート・ID規則・記述ガイドラインは親ファイルの SSOT を参照。
>
> 新規エントリは本ファイル末尾に追記し、[PLAYBOOK.md の索引テーブル](../PLAYBOOK.md#エントリ一覧)にも 1 行追加する。

---

## エントリ一覧

<a id="ace-464-3"></a>

### ACE-464-3: 複数経路が同じ untrusted トークンを消費するなら消費地点ごとの silent skip でなく入口で一度 fail-loud 検証する

| フィールド | 値         |
| ---------- | ---------- |
| Category   | security   |
| Origin     | PR #464    |
| Date       | 2026-07-03 |
| Helpful    | 1          |
| Harmful    | 0          |
| Status     | active     |

**Insight**: ユーザー由来の識別子（`--cli` / `--perspective` 等）をパスセグメントに使うとき、各消費地点で `is_safe "$x" || continue` と黙ってスキップすると、(a) 不正入力が `"(No results)"` に化けて表面化しない (b) ガードを付け忘れた経路（例: 実行/write 側）が traversal 可能なまま残る。消費前の**単一チェックポイント**（実行・レポートの各入口）で形式＋セグメント安全性を一度だけ検証し、不正は非0で fail-loud に落とせば全経路（write/clear/read）が一括で守られる。

**Context**: `multi-agent.sh` で traversal ガードを read/clear にだけ付け、実行（`run_single_task` の write）経路が無防備だった。さらに各所の silent `continue` が malformed plan（`:` 無しで cli 名と perspective 名が同値化する等）を隠蔽していた。

**Action**: untrusted トークンを複数経路が使うなら、検証を各サイトに散らさず「消費前の単一検証関数」に集約し、不正は skip でなく `error + 非0` で落とす。`cli:perspective` のような複合形式は「区切りの存在」も検証する（区切り無しは両片が同値化して検証をすり抜ける）。関連: [ACE-462-1](./tooling.md#ace-462-1)（不明入力は安全側へ）。

---

<a id="ace-469-1"></a>

### ACE-469-1: opt-in 公開ゲートの fail-safe は構造破壊入力（閉じデリミタ欠落）で破れる — パーサは走査境界を先に確定し、壊れた構造は skip でなく fail-loud に回す

| フィールド | 値         |
| ---------- | ---------- |
| Category   | security   |
| Origin     | PR #469    |
| Related    | ACE-464-3  |
| Date       | 2026-07-03 |
| Helpful    | 0          |
| Harmful    | 0          |
| Status     | active     |

**Insight**: 「フラグ明示時のみ許可（opt-in）」のゲートは値の判定が正しくても、**値を探す走査の境界**が壊れた入力で崩れると突破される。frontmatter パーサが「キーが見つかったら即 return」だと、閉じデリミタ欠落時に走査が本文へ溢れ、本文中の記法例・引用が「明示されたフラグ」として誤認される（= internal 文書が public 判定）。境界（閉じデリミタ）の存在を**先に**確定し、走査をブロック内に限定する。さらに「開始デリミタあり・閉じなし」は構造的破損であり、fail-safe の quiet skip（未指定と同じ扱い）に混ぜると作者ミスが無言で沈むため、typo 値と同じ fail-loud 経路に回す。

**Context**: PR #469 の `sync-to-public.mjs`（visibility: public の文書だけを internal→public 同期）で、初版 `readVisibility` は `visibility:` 行に当たり次第 return していた。閉じ `---` の無いファイルでは本文まで走査され、本文の例文 `visibility: public` で公開されうる欠陥を Toolkit（errors/tests）と Codex が独立に同一箇所として検出。「閉じデリミタ確認 → ブロック内限定走査 → broken は invalidFiles に集約して書き込みゼロで exit 1」に修正した。

**Action**: opt-in ゲートのパーサを書く/レビューするときは「値の許容判定」でなく「**走査がどこで止まるか**」を先に疑う。(a) ブロック境界の存在確認 → (b) 境界内のみ走査 → (c) 境界破損は quiet skip でなく fail-loud、の順で実装し、「閉じデリミタ欠落 + 本文にフラグ例文」の合成フィクスチャで「同期されない/中断する」をテストに固定する。関連: [ACE-464-3](#ace-464-3)（入口で一度 fail-loud 集約）/ [ACE-462-1](./tooling.md#ace-462-1)（想定外入力は安全側へ）。

---

<a id="ace-469-2"></a>

### ACE-469-2: コピーして使う雛形ファイルに opt-in フラグの「許可値」を焼き込まない — 雛形経由で全新規文書が公開既定になる

| フィールド | 値         |
| ---------- | ---------- |
| Category   | security   |
| Origin     | PR #469    |
| Date       | 2026-07-03 |
| Helpful    | 0          |
| Harmful    | 0          |
| Status     | active     |

**Insight**: opt-in 設計（未指定 = 安全側）はファイル単体では正しくても、**「必ずコピーして使え」と案内している雛形**に許可値（`visibility: public` 等)を書くと、コピーの瞬間に全新規文書へ許可が継承され、実質「公開が既定」に反転する。opt-in の安全性は「明示コストが漏れ側にある」ことに依存しており、雛形はそのコストをゼロにしてしまう。一括付与スクリプトで「対象ディレクトリの全ファイル」に機械的にフラグを撒くと、この种の「ファイル自体は公開してよいが、雛形としての性質上フラグを持たせてはいけない」例外を見落とす。

**Context**: PR #469 で docs/specs/ を公開分類とし一括で `visibility: public` を付与した際、`spec-template.md`（ガイドが「spec 作成時は必ずコピー」と指示する雛形）にも付与してしまった。internal リポジトリで雛形から作られる新規 spec（クライアント固有設計が最も書かれる場所）が公開既定になる漏洩リスクとして Codex code-reviewer が Critical 検出。雛形からフラグを削除し、「雛形には含めない。公開したい spec のみ作成後に明示」を FRONTMATTER_GUIDE §5.5 に明文化した。

**Action**: opt-in フラグを既存ファイル群へ一括付与するときは、付与前に「このファイルはコピー元（テンプレート/雛形/サンプル）として案内されていないか」を分類に加える。雛形は許可値を持たせず（キー自体を書かない）、必要なら「作成後に明示せよ」を雛形の案内文とガイドに書く。レビュー観点としては「雛形・スキャフォールド・generator の出力既定値」は opt-in 反転の定番経路として必ず確認する。

---
