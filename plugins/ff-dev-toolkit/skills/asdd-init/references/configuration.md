# ASDD 2.0 共通設定契約

実行対象の `.asdd/config.json` を正本とする。読取はプラグイン内 `scripts/asdd/config.mjs` の `loadConfig(root)` を使い、nullは従来環境、例外は不正設定として扱う。設定なしなら明示的な移行まで既存動作を維持する。

## 設定項目

| キー | 内容 |
| --- | --- |
| `schemaVersion` | `1` |
| `project` | `name`・`purpose`・`owner`。不明な事業情報を補完しない |
| `style` | `citizen` / `developer` |
| `stage` | `poc` / `ongoing` |
| `tools` | `claude` / `codex` から選択 |
| `documents` | `MASTER` 必須。`PROJECT`・`DOMAIN`・`ARCHITECTURE`・`PATTERNS`・`TESTING`・`DEPLOYMENT` は必要なものだけ |
| `features` | `ace`・`retrospective`・`multiReview`・`hooks`・`ci` の各boolean。新規は無効から個別に選ぶ |
| `workflow` | `simple` / `standard` / `strict`。既存の組織ルール・ブランチ保護を緩めない |
| `decisions` | `{topic,status,value,reason}` の配列。statusは `fact` / `agreed` / `proposed` / `unresolved` |
| `github` | 未連携はnull。連携時は `repository` (`owner/repo`)、`recordIssues`、`saveHistory`、`allowedPaths`、`branchPolicy` (`direct` / `pull-request`) |

未合意の提案を決定や必須ゲートへ昇格しない。確定事実と合意を区別し、技術候補は確認日・公式URLと選択／見送り理由をvalue・reasonに残す。認証情報や会話全文を設定に保存しない。

現在の履歴保存はIssueへ成果物のコミットを対応付けるため、`saveHistory=true` には `recordIssues=true` と空でない `allowedPaths` が必要。Issue記録だけなら `recordIssues=true` / `saveHistory=false`、外部記録を行わないなら `github=null` または両方falseとする。Issueを使わない履歴保存は現在の試用版では選択できず、不整合な組合せは設定の検証時点でエラーにする。

## 任意機能と優先範囲

- 2.0設定がある場合、以下のスキルに残る従来の一律フローより、選択した文書・機能・ワークフローを優先する。
- `ace=false` ならACE収集・整理・配置を自動で実行しない。`retrospective=false` なら自動実行・起動の催促・最終回答への定型行を出さない。`multiReview=false` なら複数AIレビューを自動起動しない。
- ユーザーがその機能を明示依頼した単発実行は、その依頼の範囲で行える。永続設定を勝手にtrueにせず、不要な再承認も求めない。
- `hooks=false` なら任意のプラグインHookは動かさない。自動振り返りHookは `hooks` と `retrospective` の両方がtrueの場合だけ。環境変数でoffを指定している場合も維持し、環境変数のauto/askでconfigのfalseを復活させない。
- 不正・読取不能な設定では任意機能の自動起動を停止し、非ブロックの診断を一度報告する。従来動作へフォールバックしない。
- 機能フラグは選択を表す。依存導入・ホスト対応・CIの実行確認をせずに「稼働中」と言わない。

## 生成・保存・検証

`asdd-init` のCLIで差分を確認してから合意範囲を適用する。再実行では生成管理情報に記録された状態を照合し、既存の手編集を保持する。日常作業で生成器の管理領域を編集すると次回の整合確認で変更として検出されるため、合意変更は `asdd-init` の再設定で扱う。

最小構成はMASTER内で7観点を必要な粒度で扱う。未選択の文書を不足扱いしない。未決事項の記録と、その決定が必要な作業の完了は別に判定する。初期構築完了は実装・公開完了を意味しない。
