---
name: multi-explore
description: 複数の AI CLI を並列実行し、異なる観点からコードベースを探索・分析する（read-only）
---

# /multi-explore — 複数AIによるコードベース探索

5つのAI CLI（Claude Code / Codex / Copilot / Gemini / Grok）を並列実行し、異なる観点からコードベースを探索・分析します。

## プラグインルートの解決

同梱スクリプトを実行する前に `FF_DEV_TOOLKIT_ROOT` を解決する。Claude Code では `${CLAUDE_PLUGIN_ROOT}` を使い、Codex など他ホストでは読み込んだこの `SKILL.md` の絶対パスから `../..` を解決する。以下の `${FF_DEV_TOOLKIT_ROOT}` はその絶対パスを指す。バージョン別 cache を探索して選ばない。

## 前提

- git リポジトリで作業中であること
- 本プラグイン同梱の `${FF_DEV_TOOLKIT_ROOT}/scripts/multi-agent.sh` を使用する
- 少なくとも1つのAI CLIがインストールされていること
- Mike Farah `yq` v4 がインストールされていること（Homebrew があれば `brew install yq`、無ければ同梱 `setup-multi-agent.sh` が GitHub release から導入。distro の `apt`/`yum` パッケージ `yq` は別実装のことがあり非対応）

## 引数

- `$ARGUMENTS` — 探索対象の説明（必須）+ multi-agent.sh に渡すオプション
  - 例: `認証フローの仕組みを調査`
  - 例: `プロジェクト構造の概要 --cli codex-cli`（特定CLIのみ）
  - 例: `API エンドポイントの一覧 --strategy minimize_cost`（コスト最小化）
  - 全オプションは `bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-agent.sh" --help` で確認できます

## 手順

### 1. 引数の解析

`$ARGUMENTS` の最初の部分（`--` で始まらない部分）を探索対象の説明として取得します。
残りのオプションは multi-agent.sh に渡します。

### 2. プラン確認（--dry-run）

まず実行プランを表示し、ユーザーに確認を求めます:

```bash
bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-agent.sh" --task explore --description "<探索対象>" --dry-run $OPTIONS
```

出力を確認し、以下をユーザーに報告:

- 検出されたCLI一覧（✅/❌）
- 各CLIに割り当てられたパースペクティブ
- モード・戦略・タイムアウト設定

ユーザーに「このプランで実行してよいか」を確認してください。

### 3. 探索実行

ユーザーが承認したら、実際の探索を実行します:

```bash
bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-agent.sh" --task explore --description "<探索対象>" $OPTIONS
```

**注意**: explore タスクは read-only です。コードの変更は行いません。

実行中は進捗状況を監視し、完了を待ちます。

### 4. 結果分析と統合レポート

探索結果は `.explore-results/` ディレクトリに出力されます。

#### 4-1. 結果ファイルの読み込み

```bash
cat .explore-results/integrated-report.md
ls -la .explore-results/
```

#### 4-2. カテゴリ別統合

複数CLIの結果をカテゴリ別にまとめます:

```markdown
## Multi-CLI Explore 統合レポート

### アーキテクチャ分析
- [CLI名] 発見事項の説明

### 依存関係マッピング
- [CLI名] 発見事項の説明

### パターン検出
- [CLI名] 発見事項の説明

### クロスモデル検出（複数CLIが一致）
- [CLI-A, CLI-B] 発見事項（信頼度: 高）

### Summary
| CLI | Perspective | 主要発見事項数 |
|-----|------------|--------------|
| claude-code | architecture-analysis | X |
| codex-cli | dependency-mapping | X |
| ... | ... | ... |
```

#### 4-3. 信頼度評価

複数のCLIが同じ発見をしている場合、信頼度を「高」として報告します。
1つのCLIのみの発見は信頼度「中」として報告します。

## 重要ルール

- ステップ2の dry-run 確認なしにステップ3を実行しないこと
- 探索は read-only — コードの変更は一切行わないこと
- 結果は `.explore-results/` に保存され、後から参照できます
- 設定のカスタマイズ: プロジェクト側に `.claude/agent-config.yaml` を置くとプラグイン同梱のデフォルト設定より優先される（環境変数 `MULTI_AGENT_CONFIG=<path>` または `--config <path>` でも上書き可。読み取りは `yq` 依存で、無い環境では設定ファイルは読まれず既定値で動く）。ただし**実際に読まれるのは `version` / `mode` / `parallel` / `review.main` / `review.sub` と、`version: "2.0"` のときだけ `tasks.<task>.{mode,cost_strategy,timeout,output_dir}` である**（`version` が `2.0` でない場合は v1 形式とみなされ、トップレベルの `cost_strategy` / `timeout` / `output_dir` が読まれる — `version` を書き忘れると `tasks.*` が黙って無視されるので注意）。`agents:` と `fallback:` はどのバージョンでも読まれず、人が読むための対応表にすぎない。実行時のレジストリの正本は `scripts/multi-agent.sh` の `get_cli_*` 関数
