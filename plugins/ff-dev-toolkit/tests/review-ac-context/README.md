# Review AC context

実 wrapper／orchestrator／adapter を実行し、gh とモデル CLI は fixture に置き換える。
`bash verify.sh` で、明示優先・全レーン・取得不足・gh/file・長文・resume／ホスト委譲回収を検証する。
本文の argv 化は adapter 起動時の引数を観測し、32KB を超える引数を拒否する fixture でも検出する。
これは Windows 実機検証ではない。case 不在／空でも完了 marker がなければ赤にする。

## GitHub MCP の入力

ホストが取得した raw file と、既存 github-input の version 1 index を使う。新しい API client は作らない。
操作・scope・phase・position と必須 field は同梱運用ガイド「Issue の AC を自動で事前投入する」が正本。
PR の body／番号／URL／head branch と API closing refs の URL 集合が必要で、手動リンクも落とさない。
MCP の `fetch_issue` は `structuredContent.issue.issue_number` を `number`、`body`／`url` を同名へ写せる。

2026-10-24 にこのホストの `fetch_pr` で既存の PR を読んだ応答は、`pull_request.head` はあるが
`closingIssuesReferences` を含まなかった。この応答だけから完全な closing refs を証明できない。
不足を `[]` へ補わず、必要な一次情報を返す既存能力がなければ `review.ac.pr` の取得不足として表示し、
任意 context なしで続行する。fixture の gh-shaped raw と同値であることは、MCP-only 完走の証明ではない。
