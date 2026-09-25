# 型付き判定行の規則（multi-review §3-1 の補足）

クロスモデルレビューの重大度は、レビュアーが finding ごとに書く**型付き判定行**だけで決まる。散文の重大度見出し・件数行（`Critical: 0 / Warning: 0 / Suggestion: 0` 等）は読み手のためのもので、受理にも判定にも使わない。仕組みの正本は [multi-cli-review-orchestration.md の「型付き判定の集計」](../../../docs-template/05-operations/deployment/multi-cli-review-orchestration.md#型付き判定の集計)、対応方針は [review-response-policy.md](../../../docs-template/05-operations/deployment/review-response-policy.md#重要度別対応ルール)。

| 規則 | 内容 |
| --- | --- |
| 判定行が必須 | 指摘ごとに `- verdict: severity=critical\|warning\|suggestion\|info failure_scenario=yes\|no confidence=0〜100 [file=…] [line=…]` を 1 行（フェンスの外・強調やバッククォートなし）。指摘ゼロなら `- verdict: none` |
| 判定行が無い報告は INCOMPLETE | 有効な判定行が 1 行も無い報告は、見出しや件数行が揃っていても受理されない（CLI 起動経路は INCOMPLETE 成果物、ホスト委譲は応答を退避して handoff をやり直す）。散文だけの報告には `typed-verdict: <CLI>/<観点>: prose-only review refused (no valid verdict line)` の診断が出る |
| `failure_scenario=no` は 1 段降格 | Critical → Warning、Warning → Suggestion。`CRITICAL_BLOCK` / `CRITICAL_NONBLOCK` は降格後の重大度で決まる |
| confidence の閾値 80 | env `MULTI_AGENT_REVIEW_CONFIDENCE_THRESHOLD` > `.claude/agent-config.yaml` の `review.confidence_threshold` > 既定 80。閾値未満は捨てずに「未確認 › 低信頼の指摘」へ並ぶ（Critical の判定からは外さない） |
| 「未確認」は 2 節 | 「未確認 › 低信頼の指摘」と「未確認 › 未完了の観点」（委譲待ち・失敗・タイムアウト・拒否・スキップ・結果なし）。どちらも「指摘なし」と読まない |
| 崩れた Critical 行は安全側 | 文法を満たさない `verdict` 行が `severity=critical` を名乗ると、判定行としては採らずに Critical ありとして扱う（fail-safe） |

§3-1 の分析サブエージェントは、統合レポートの「型付き判定の集計」節（観点ごとの降格後件数）と各観点の `- verdict:` 行から分類し、2 つの「未確認」節を分けて返す。
