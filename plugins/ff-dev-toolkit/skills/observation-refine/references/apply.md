# 適用の書式（/observation-refine Phase 3）

本線 `SKILL.md` の Phase 3 で、承認された操作を台帳へ当てるときに読む。どの操作も「メタ行の値を変える」と「エントリ末尾の観測メモへ 1 行足す」の 2 つだけで構成する。足す行は必ず次の形で始める（`check` はこの書き出しで状態移行の行を見分ける。再発の計上と混ざらないよう、`/retrospective` の[状態移行の記録](../../retrospective/references/promotion.md)と同じ語を使う）:

```text
- YYYY-MM-DD: 状態移行（再発ではない）。
```

日付は適用した日。行は既存の観測メモの最後の行の直後へ足し、空行を足さない。台帳の Markdown へ script で文字列パッチを当てる場合は [Markdown 文字列パッチ規律](../../../docs-template/05-operations/deployment/markdown-patch-discipline.md)に従う。

## 既存 Issue への紐付け

| 行 | 変更 |
| --- | --- |
| `Status` | `active` → `promoted` |
| `Issue` | `なし` → `owner/repo#N`（リポジトリ修飾を省かない。複数あれば ` / ` で並べる） |
| `Count` / `First` / `Last` | 変えない |

```text
- YYYY-MM-DD: 状態移行（再発ではない）。既存 Issue owner/repo#N（open）へ紐付けた。一致の根拠: [同じ事象と判定した理由を 1 文]（/observation-refine）
```

Issue が closed なら括弧内を `closed` と書く。対策の反映まで確かめて `mitigated` にするのは本スキルの操作ではなく、`/retrospective` の完了照合である。closed へ紐付けたエントリは、本線の「整理の後に渡すもの」で同じセッションのうちに完了照合へ渡す。

## 同じ主張の統合

統合先（残す側）と統合元（畳む側）の両方を書き換える。統合元の観測メモは**統合元に残す**（統合先へ写さない・動かさない）。

統合先:

| 行 | 変更 |
| --- | --- |
| `Count` | 統合先と統合元の `Count` の合計 |
| `First` | 統合先と統合元のうち最も古い日付 |
| `Last` | 統合先と統合元のうち最も新しい日付 |
| `Status` / `Issue` | 変えない |

```text
- YYYY-MM-DD: 状態移行（再発ではない）。OBS-NNN（Count 2）を統合し Count 1 → 3。同じ主張と判定した理由: [取るアクションが同一である理由を 1 文]（/observation-refine）
```

統合元:

| 行 | 変更 |
| --- | --- |
| `Status` | `active` → `archived` |
| `Issue` | `なし` → `doc:docs/08-knowledge/OBSERVATIONS.md#obs-nnn`（統合先の anchor。台帳の配置が既定と違うときはそのリポジトリ相対パス） |
| `Count` / `First` / `Last` | 変えない（統合前の値を履歴として残す） |

```text
- YYYY-MM-DD: 状態移行（再発ではない）。OBS-MMM へ統合した（Count 2 は統合先へ合算済み）（/observation-refine）
```

- 統合先の行には、統合元の ID と「統合」の語を必ず入れる（`check` が統合元ごとに照合する）
- 1 つの統合先へ複数の統合元を畳むときは、統合先の行を 1 行にまとめ、統合元の ID をすべて書く
- 統合先が `archived` になる連鎖は作らない。統合元を別の統合の統合先にしない。過去の整理で統合先になったエントリも統合元にしない（そのエントリを指す既存の統合元が連鎖になる。`check` は、既存の統合元が指す先が `archived` になる適用も違反にする）
- 統合元と統合先の `Kind` は同じであること（`check` が照合する）
- 統合先のエントリに anchor 行（`<a id="obs-nnn"></a>`）が無い台帳でも、`Issue` 列の書式は同じにする。`check` と `/retrospective` は `#obs-nnn` を ID として読む（anchor 行は足さない — 足すと状態移行以外の追記になる。リンクとしては辿れないので、統合先の ID を観測メモにも書いておく）
- 台帳の配置が既定と違うリポジトリでは、`check` へ `--ledger-rel <リポジトリ相対パス>` を渡す

統合で `archived` にしたエントリは、`Issue` 列が台帳自身の anchor を指す。そのエントリと同じ主張が再発したときの扱い（統合先へ計上する）は [`/retrospective` の ledger.md](../../retrospective/references/ledger.md) が定める。

## stale の archive

| 行 | 変更 |
| --- | --- |
| `Status` | `active` → `archived` |
| `Issue` / `Count` / `First` / `Last` | 変えない |

```text
- YYYY-MM-DD: 状態移行（再発ではない）。archived（Last から 212 日再発なし。基準は 180 日・Count 1 以下）（/observation-refine）
```

経過日数と基準は dry-run の出力の値を書く。再発したら `/retrospective` が `active` へ戻す。

## Keep の定着判定

| 行 | 変更 |
| --- | --- |
| `Status` | `active` → `mitigated` |
| `Issue` | `なし` → 対策の所在（`skill:<スキル名>` / `doc:<path>#<アンカー>` / `owner/repo#N`。複数あれば ` / ` で並べる） |
| `Count` / `First` / `Last` | 変えない |

```text
- YYYY-MM-DD: 状態移行（再発ではない）。定着済み: skill:create-issue の「工数の推定」節が同じ手順を規定している（ff-dev-toolkit 1.2.0 で確認）（/observation-refine）
```

所在の書式は [`/retrospective` の `mitigated`](../../retrospective/references/promotion.md)が正本で、ここで別の形を作らない（別リポジトリの所在にリポジトリ名を添える規定も同文書に従う）。参照先の節・path が実在することを grep で確かめてから書き、確かめた対象（リポジトリの SHA、またはインストール済みプラグインの版）を観測メモへ残す。

## 照合で止まったとき

| `NG` の理由 | 直し方 |
| --- | --- |
| 適用前の行が適用後に見つからない | 既存の行を消したか書き換えた。`git diff` で該当行を元へ戻し、変更をメタ行と足した 1 行だけにする |
| 足された行が状態移行の観測メモではない | 書き出しを上の形に直す。再発の計上（`Count` +1）を混ぜていないか確かめる — 再発の記録は `/retrospective` の操作 |
| 状態・Issue 列が変わったのに観測メモが足されていない | 移行の根拠の行を足す |
| 統合先の Count / First / Last が一致しない | 統合元の値を合算・最小・最大で取り直す |
| 統合先に、この統合元を名指す観測メモが無い | 統合先の行へ統合元の ID を書く |
| Issue 列が埋まった active は整理の対象外 | `active` なのに `Issue` 列に参照が在るエントリを動かそうとした。そのエントリの変更をすべて戻す（既存の参照を上書きしない。`Status` の食い違いは `/retrospective` の状態移行で直す） |
| Status が…のまま Issue 列だけが変わっている | `Issue` 列を変える操作は必ず `Status` の移行を伴う。`Status` の書き換え漏れか、対象外のエントリへの書き込み |
| archived で Issue 列を変えられるのは統合元だけ | stale の archive は `Issue` 列を変えない。統合元なら値を台帳自身の統合先 anchor にする |
| 整理が扱う移行は active からだけ | `promoted` / `mitigated` / `archived` のエントリの状態は動かさない（完了照合・再発は `/retrospective` の操作） |
| 整理が mitigated にするのは Kind が keep のエントリだけ | problem を定着扱いにしない。対策の規定が在る problem は、閾値に届いたときの昇格見送りで扱う |
| 状態移行の観測メモを足したのに、メタ行が何も変わっていない | メモだけ足して `Status` / `Issue` を書き換えていない。適用の残りを当てる |
| Count が 1 以上の整数ではない | 合算の式や単位を書かず、数字だけを書く |
| 既存の統合元が指す統合先が archived になった | 過去の統合先を今回の統合元にした。その統合を取り消し、過去の統合先を残す側にする |
| 適用前のメタ行を読めない／元からの書式不備 | 適用の誤りではない。該当エントリの書式を先に直して commit し、dry-run からやり直す |
