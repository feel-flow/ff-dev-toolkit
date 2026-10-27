# Claude Code Issue 計測 PoC

macOS / Linux の Python 3 標準ライブラリと Claude Code を使う、明示実行型のローカル PoC。
既存の wallclock / instruction-bytes / gate / review 記録と ff-effort は変更しない。
通常の対話セッションを後から走査せず、このコマンドで新規起動した作業だけを測る。

## 観測契約

| 項目 | 観測元・意味 | 制約 |
| --- | --- | --- |
| Issue / セッション / 成果 | 明示したリポジトリ（owner/name）と Issue 番号、生成した session UUID、任意の成果 URL | 1実行=1Issue。複数PRはURLを追記できる。親子spanは作らず、最上位CLIだけを記録 |
| CLI経過秒 | Python の monotonic によるプロセス実行時間 | 起動・ツール・API・待機を含む。AI稼働時間ではない |
| CLI区間の延べ/重複除去/全体経過 | UTC epoch の開始終了区間。和/区間和集合/最初から最後まで | 同一マシンでの比較。時計飛びは欠測。間の空白を待ち・人間時間へ分類しない |
| duration_ms / duration_api_ms | Claude Code の result JSON の報告値 | API延べ時間はAI稼働の和集合ではない。子APIを別途足さない |
| トークン | usage の input/output/cache creation/cache read のみ | 非負整数。欠落は null。モデル名は modelUsage のキーだけ |
| コスト USD | total_cost_usd | CLI側推定額。サブスク費用の按分・請求実額ではない |
| 人間介入/真のAI稼働/待ち/請求実額 | unavailable | ツール外の設計・相談・レビューも未観測。経過秒から差し引いて推定しない |

公式資料（2026-10-27 確認）:
[headless JSON とセッション累積コスト](https://code.claude.com/docs/en/headless)、
[CLI 引数](https://code.claude.com/docs/en/cli-reference)、
[SDK result の型](https://platform.claude.com/docs/en/agent-sdk/typescript)、
[コストが推定額である理由](https://code.claude.com/docs/en/costs)。
公式 result に時間フィールドはあるが、完全な稼働/待ちspanはない。
再開時の累積値の二重計上を避け、PoC は新規 session UUID のみを起動する。
将来の製品版で形が変わった場合も、未知の値をゼロへ変換しない。

## 開始・停止・保存先

実行例（パスはインストール済みプラグインの実際の配置に合わせる）:

```bash
python3 plugins/ff-dev-toolkit/scripts/measurement/claude-measure.py run \
  --repo example/project --issue 1676 --timeout 180 < task.txt
python3 plugins/ff-dev-toolkit/scripts/measurement/claude-measure.py report \
  --repo example/project --issue 1676
```

実行しなければ記録しない。常駐プロセス・自動hook・送信機能はない。
Ctrl-C / timeout は子プロセス群を停止し、終了記録に中断を残す。SIGKILL 等で終了記録が
無い場合は report が incomplete と表示し、now で勝手に閉じない。
既定保存先は `~/.local/state/ff-dev-toolkit/claude-measurement/`。
`--store` で明示変更できる。run UUID ごとのディレクトリを mode 0700、JSON を0600で作る。
停止後も記録を残す。不要な記録は利用者がこの専用保存先を削除できる。

プロンプトは stdin からメモリ上へ読み、結果 JSON もメモリ上で処理する。
子CLIの stderr は端末へそのまま渡して診断可能にするが、記録器ストアへ保存しない。
保存は allowlist のメタデータ・数値だけ。prompt / result / tool_input / source / stderr / transcript
を保存するオプションは提供しない。CLI は `--no-session-persistence` で起動する。
CLI 自身の通信、組織のログ設定、利用者が設定したhookによる保存はこの記録器の管理外。
保存先にはリポジトリ識別子・session ID・成果 URL が含まれるので共有前に確認する。
stdout は成果本文だけを返すため、リダイレクトした場合は利用者が本文を保存することになる。

`--model` の省略時は CLI の設定に従う。`--claude` は使用する実行ファイル、
`--timeout` は秒（既定300）、`--max-turns` は既定5。安全に小さく検証するため
ツールは Read / Glob / Grep のみに限定し、MCP は空の明示設定だけを使用する。
書き込みを伴う開発の全面計測は本 PoC の対象外。認証と通常のホスト設定は既存 CLI に従う。
制御した読み取り試行には `--safe-mode` を指定でき、指定の有無を記録する。
このモードは CLI のカスタムhook・プラグイン・CLAUDE.md等を無効化するため、通常実行とは
測定条件が異なる。通常モードでは Stop hook が追加ターンを開始することがあり、result が
依頼した成果を表すとは限らない。CLIの成功と成果の受け入れを別々に確認する。
report はモード別集計をしない。条件比較では `--store` を分け、個別 record の
`safe_mode` を確認する。版確認中の中断は記録開始前なので実行記録を作らない。

## 集計・成果リンク・異常

```bash
python3 plugins/ff-dev-toolkit/scripts/measurement/claude-measure.py link \
  --run RUN_UUID --url https://github.com/example/project/pull/123
```

link はローカル記録へ URL を追加するだけ。外部へ投稿しない。
report は同じ repo/Issue の全実行を読み、重複区間を除く。繰り返しても書き戻し・加算しない。
セッション識別子が一致する公式 result だけを受け入れ、誤った型・負数・非有限数は欠測にする。
1実行でも項目が欠測なら、その項目の全体合計は null、missing 件数を出す。
中断実行の区間は「プロセスがいた区間」として算出できるが、利用量・コストは結果が
得られなければ欠測。開始だけの実行があれば全体時間は null、終了済み区間は observed として併記。
壊れた JSON / 不正スキーマを読み飛ばして完全な集計にせず、report 自体を非0で止める。
不正な記録は安全な理由と run UUID を診断へ出す。ストア直下の `.DS_Store` 等も
想定外の入力として停止するので、専用ストアに別ファイルを置かない。
時計飛び等で終了epochが欠けた実行は `interval_missing` に数える。
空ストアも null と件数0で表し、実測ゼロとは区別する。
失敗・権限拒否・max-turns・JSON不正は成功として報告せず、終了コード非0と状態を残す。

テスト: `bash plugins/ff-dev-toolkit/tests/claude-measurement/verify.sh`。
合成fixtureと実CLIタスクの証拠は分け、実測にCLI版・モデル・条件・成果URLを添える。
