# validate-docs-placeholders

`/validate-docs` §4 のプレースホルダー免除区分を、LLM を介さず fixture のトークン残存数で固定する（Issue #518）。

## 何を検証するか

| ケース | 入力 | マスク後に残るトークン |
| --- | --- | --- |
| `closed-spans.md` | 本文・表セル・閉じたフェンス・閉じた HTML コメント・インライン・閉じた区間の後ろ・同一行コメント | 本文・表・後ろ・同一行本文の 4 件 |
| `unclosed-fence.md` | 閉じ忘れたフェンスの開始行と後ろにトークン | 3 件とも残る（除外区間にしない） |
| `unclosed-comment.md` | 閉じ忘れた HTML コメントの開始行と後ろにトークン | 3 件とも残る |
| `unclosed-then-closed.md` | 閉じ忘れたチルダフェンスの後ろに本文トークン + 閉じたバッククォートフェンス | 本文 1 件だけ残る |

走査は `tests/lib/docs-scan.sh` の `ff_docs_mask_spans`（フェンス / コメント）と `ff_docs_mask_inline_spans`（同一行内の対になったインラインコードスパン）を合成する。

検出力（除外範囲の拡大 / 縮小で red になること）は `tests/validate-docs-placeholders-selftest/` が変異注入で実測する。

## 実行

```bash
bash plugins/ff-dev-toolkit/tests/validate-docs-placeholders/verify.sh
```
