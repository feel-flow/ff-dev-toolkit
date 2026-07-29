# docs-template 実行可能ゲート例の動的回帰テスト

Issue #157 で追加した、Markdown 内の実行可能なシェル例を fixture に対して動かす
回帰テストです。

## 役割分担

- `tests/docs-gates/`: 修正パターンの実在と退行パターンの不在を文字列で固定する、
  一時ファイル不要の文面 drift 検査
- `tests/docs-gates-runtime/`: 対象見出しから `bash` フェンスを抽出し、fixture ごとの
  exit code を実測する意味検査

汎用の Markdown シェル静的解析は行いません。placeholder を含まず、単独実行できると
確認した次の2フェンスだけを対象にします。

1. `automated-code-review.md` の「レビュー厳格度の調整」
2. `multi-cli-review-orchestration.md` の「Husky pre-push フックとの統合」

## 検証ケース

| 対象 | ケース | 期待 |
| --- | --- | --- |
| 判定ロジック | 正常な APPROVED + `Important Issues: None found` | exit 0 |
| 判定ロジック | `INCOMPLETE` マーカー | 非 0 |
| 判定ロジック | 空ファイル | 非 0 |
| 判定ロジック | `Important Issues` 見出し drift（strict mode） | 非 0 |
| 判定ロジック | APPROVED だが `Important Issues` に実指摘あり（strict mode） | 非 0 |
| 判定ロジック | REJECTED 本文中の `APPROVED` 引用 | 非 0 |
| pre-push | 正常なレビュー実行 + 統合レポート | exit 0 |
| pre-push | レビュースクリプト非 0 | 非 0 |
| pre-push | 空の統合レポート | 非 0 |
| pre-push | `INCOMPLETE` を含む統合レポート | 非 0 |
| pre-push | `CRITICAL_BLOCK` を含む統合レポート | 非 0 |

## 実行

```bash
bash plugins/ff-dev-toolkit/tests/docs-gates-runtime/verify.sh
```

`FF_DOCS_GATE_RUNTIME_DOCS` に別の docs-template ルートを渡すと、変異コピーに対して
同じ suite を実行できます。肯定マーカーの行頭アンカーを外す、非空検査を削る、
終了コード検査を削る等の変異が red になることを確認してからゲート契約を変更します。

一時ディレクトリを作れない環境では、検証本体を1件も実行できないため
`run-all.sh` 契約どおり行頭 `○ skip` を出して exit 0 とします。
