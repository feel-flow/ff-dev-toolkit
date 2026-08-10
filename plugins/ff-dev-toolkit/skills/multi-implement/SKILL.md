---
name: multi-implement
description: 複数の AI CLI を並列実行して実装タスクを分担する（結果はステージングディレクトリ経由・ユーザー承認後に適用）
---

# /multi-implement — 複数AIによる並列実装

5つのAI CLI（Claude Code / Codex / Copilot / Gemini / Grok）を並列実行し、異なる観点から実装タスクを分担します。

## プラグインルートの解決

同梱スクリプトを実行する前に `FF_DEV_TOOLKIT_ROOT` を解決する。Claude Code では `${CLAUDE_PLUGIN_ROOT}` を使い、Codex など他ホストでは読み込んだこの `SKILL.md` の絶対パスから `../..` を解決する。以下の `${FF_DEV_TOOLKIT_ROOT}` はその絶対パスを指す。バージョン別 cache を探索して選ばない。

## 前提

- git リポジトリで作業中であること
- 本プラグイン同梱の `${FF_DEV_TOOLKIT_ROOT}/scripts/multi-agent.sh` を使用する
- 少なくとも1つのAI CLIがインストールされていること
- Mike Farah `yq` v4 がインストールされていること（Homebrew があれば `brew install yq`、無ければ同梱 `setup-multi-agent.sh` が GitHub release から導入。distro の `apt`/`yum` パッケージ `yq` は別実装のことがあり非対応）

## 引数

- `$ARGUMENTS` — 実装タスクの説明（必須）+ multi-agent.sh に渡すオプション
  - 例: `新しいバリデーション関数を追加`
  - 例: `ユーザー認証ミドルウェアのリファクタリング --cli claude-code --cli codex-cli`
  - 例: `テストコードの拡充 --include-diff`（現在の差分も含める）
  - 全オプションは `bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-agent.sh" --help` で確認できます

## 手順

### 1. 引数の解析

`$ARGUMENTS` の最初の部分（`--` で始まらない部分）を実装タスクの説明として取得します。
残りのオプションは multi-agent.sh に渡します。

### 2. プラン確認（--dry-run）

まず実行プランを表示し、ユーザーに確認を求めます:

```bash
bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-agent.sh" --task implement --description "<タスク説明>" --dry-run $OPTIONS
```

出力を確認し、以下をユーザーに報告:

- 検出されたCLI一覧（✅/❌）
- 各CLIに割り当てられたパースペクティブ（実装/テスト/ドキュメント/リファクタ/マイグレーション）
- モード・戦略・タイムアウト設定

ユーザーに「このプランで実行してよいか」を確認してください。

### 3. 実装実行

ユーザーが承認したら、実装を実行します:

```bash
bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-agent.sh" --task implement --description "<タスク説明>" $OPTIONS
```

**重要**: 実装結果は `.implement-results/` ステージングディレクトリに出力されます。
ワーキングツリーには直接書き込みません。内訳は 2 種類です:

| パス | 中身 |
|---|---|
| `.implement-results/<cli>/<perspective>.md` | 各タスクの実装レポート（説明・方針・差分の解説） |
| `.implement-results/<cli>/files/<perspective>/` | **生成されたファイル本体**（staging）。この実パスがプロンプトで各 CLI に明示されます |

staging が (CLI, 観点) 単位なのは、同じ CLI に複数の観点が乗るプラン（CLI が 1 つしか
導入されていない場合や fallback 時）でタスクが並列に走り、同名ファイルを上書きし合う
のを防ぐためです。

掃除されるのは**今回の実行プランに含まれるタスクの staging だけ**です。`--cli` や
`--perspective` で対象を絞った場合、プランに入らなかったタスクの `files/` には前回の
成果が残ります。統合レポートは各セクションに実パスと実測ファイル数を書くので、
ツリー全体を眺めるのではなくレポートのセクションを読んでください。

実行中は進捗状況を監視し、完了を待ちます。

### 4. 結果分析と適用承認

#### 4-1. 結果ファイルの読み込み

```bash
cat .implement-results/integrated-report.md
ls -la .implement-results/
```

#### 4-2. 統合レポートの出力

以下の形式でユーザーに報告します:

```markdown
## Multi-CLI Implement 統合レポート

### 実装成果物
| CLI | Perspective | 生成ファイル | ステータス |
|-----|------------|-------------|----------|
| claude-code | feature-implementation | src/... | 新規作成 |
| codex-cli | refactoring | src/... | 変更 |
| copilot-cli | test-writing | tests/... | 新規作成 |
| gemini-cli | documentation | docs/... | 新規作成 |

### 競合チェック
- 同一ファイルを複数CLIが変更している場合は警告

### 適用推奨順序
1. コア実装 (feature-implementation)
2. リファクタリング (refactoring)
3. テスト (test-writing)
4. ドキュメント (documentation)
5. マイグレーション (migration)
```

#### 4-3. ワーキングツリーへの適用

ユーザーに適用の承認を求めます:

- 各CLIの結果を個別に確認
- 競合がある場合は手動マージの提案
- 承認された成果物のみをワーキングツリーに適用

適用後:

```bash
git diff  # 適用内容の確認
```

## 重要ルール

- ステップ2の dry-run 確認なしにステップ3を実行しないこと
- 実装結果はステージングディレクトリに出力 — ワーキングツリーに直接書き込まない
- ワーキングツリーへの適用前にユーザー承認を得ること
- 結果は `.implement-results/` に保存され、後から参照できます（生成ファイル本体は `<cli>/files/<perspective>/`）
- **生成ファイルを探すときは統合レポートのセクションに書かれた実パスを使う** — ツリーを直接 `find` すると、今回の実行プランに入らなかったタスクの前回分を混ぜて読むことになります
- staging の実パスは orchestrator が解決して各 CLI のプロンプトに明示する。アダプタを直接叩く場合は `--staging-dir` を明示しない限り渡らず、その場合は `--inline-output` を付けて「ファイルを書かず内容を応答へインライン出力する」モードを明示的に選ぶ（無指定の implement は fail-loud で落ちる — 渡し忘れを静かに退避モードへ落とさないため）
- 設定のカスタマイズ: プロジェクト側に `.claude/agent-config.yaml` を置くとプラグイン同梱のデフォルト設定より優先される（環境変数 `MULTI_AGENT_CONFIG=<path>` または `--config <path>` でも上書き可。読み取りは `yq` 依存で、無い環境では設定ファイルは読まれず既定値で動く）。ただし**実際に読まれるのは `version` / `mode` / `parallel` / `review.main` / `review.sub` と、`version: "2.0"` のときだけ `tasks.<task>.{mode,cost_strategy,timeout,output_dir}` である**（`version` が `2.0` でない場合は v1 形式とみなされ、トップレベルの `cost_strategy` / `timeout` / `output_dir` が読まれる — `version` を書き忘れると `tasks.*` が黙って無視されるので注意）。`agents:` と `fallback:` はどのバージョンでも読まれず、人が読むための対応表にすぎない。実行時のレジストリの正本は `scripts/multi-agent.sh` の `get_cli_*` 関数
