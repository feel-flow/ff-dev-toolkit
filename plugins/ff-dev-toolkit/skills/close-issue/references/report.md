

```markdown
## 完了報告（PR #<PR番号>）

### 何が問題で、どう解決したか（1〜3 段落）

### AC 検証結果

| AC | 判定 | 根拠 |
| --- | --- | --- |
| Given ... When... Then | ✅ 達成 | [該当ファイル・テスト・検証コマンド] / 測った対象: [AC が指す対象] |
| ... | ➖ 対象外 | [理由と別 Issue 番号（あれば）] |
| DoD: staging で ... | ⏳ post-merge 検証待ち | [マージ後に実測する手順と、閉じてよい条件] |

### 工数実績

（references/effort.md の節。ブロックが無い Issue では節ごと省略）

### 参照

- PR: #<PR番号> / 主要コミット: <手順 1 の PR_COMMITS をそのまま貼る>
```



```markdown
## /close-issue 完了

- 対象 Issue: #46（達成 6 / 未達 0 / 対象外 0）
- チェックボックス更新: ✅ / 完了報告コメント: ✅
- 工数記録: ✅ AI 予定 4.8h → 実績 11.2h（乖離率 2.33・閾値超過）／ブロック不在の場合は「ブロック不在のためスキップ」
- closing keyword 抵触検査: 対象なし（Closes 運用）
- CI checks: <手順 7 の CHECKS_REPORT をそのまま貼る>
- ゲート実測鮮度: <手順 7 の FRESH_REPORT をそのまま貼る>
- 照合時の head SHA: <PR_HEAD_OID> / 主要コミット: <手順 7 の PR_COMMITS をそのまま貼る>

→ マージに進めます:

    <finish.sh precheck が出力した MERGE_COMMAND をそのまま貼る>

→ マージ直後に read-back（Closes 運用は CLOSED、Refs 運用は OPEN のままを実測する）:

    gh issue view 46 --json state
```

<!--02bb806c45eed6d5-->
MCP: 取得値: MCP で同じ PR の merged / result SHA と各 Issue の state を fresh 取得。形式: repository / number を固定した PR / Issue JSON。渡し先: 完了報告へ実値を渡し、期待と違えば update_issue の state=open/closed と state_reason を明示して復旧し再後読する。不足時: 必須の MCP 能力 / 値が欠ければ操作名と項目を示して停止。
