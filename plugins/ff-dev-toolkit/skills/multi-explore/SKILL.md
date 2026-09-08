---
name: multi-explore
description: 複数の AI CLI を並列実行し、異なる観点からコードベースを探索・分析する（read-only）
---

# /multi-explore — 複数AIによるコードベース探索

4つのAI CLI（Claude Code / Codex / Copilot / Grok）を並列実行し、異なる観点からコードベースを探索・分析します。

## 実行前の effort 選択

[作業別 effort の選択](../../docs-template/05-operations/deployment/effort-selection.md) を読み、明示設定を維持したうえで、その呼び出しの effort と理由を決める。CLI 起動とネイティブ委譲の指定手段・確認境界も同文書を正本とする。

## プラグインルートの固定（必須）

<!-- ff-dev-toolkit-plugin-root-contract:start -->
同梱resourceを参照する前に `FF_DEV_TOOLKIT_ROOT` を**一度だけ**解決し、実行中は変更しない。

- Claude Codeでは、その呼び出しでホストが渡した `${CLAUDE_PLUGIN_ROOT}` を使う
- grok CLIでは、Bash tool 環境の `${GROK_PLUGIN_ROOT}` があればそれを使う（skill 経路では未設定が普通なので、次項の `FF_DEV_TOOLKIT_SKILL_FILE` を渡す）
- Codexなど他ホストでは、実際に読み込んだこの `SKILL.md` の絶対パスを `FF_DEV_TOOLKIT_SKILL_FILE` として固定し、そこから `../..` を解決する

このskillを実行するAI hostは、Bash tool呼び出しを組み立てるとき、skill loaderが返した実値で `FF_DEV_TOOLKIT_SKILL_FILE="<このSKILL.mdの絶対パス>"; export FF_DEV_TOOLKIT_SKILL_FILE` を実行し、同じshell script bodyでresourceを呼び出す。placeholderのまま実行したり、cache pathを推測して埋めたりしない。
plugin内ドキュメントの正本は、読み込んだこの `SKILL.md` のdirectoryを基準にした [plugin root固定契約](../../docs-template/05-operations/deployment/multi-cli-review-orchestration.md#ff-dev-toolkit-plugin-root-prerequisite) である。consumerへコピーされた `docs/` や物理CWDを基準に解決しない。
review系resource（`setup-multi-agent.sh` / `multi-agent.sh` / `multi-review.sh`）を直接呼ぶhostだけが、同節のresolver + guard fence全体を読み、handoff設定・guard・resource呼び出しを同じshell script bodyで実行する。そのhostはtask workspace repository rootも `FF_DEV_TOOLKIT_PROJECT_ROOT` として同じBash tool呼び出しへ渡し、現在の物理CWDおよび `git rev-parse --show-toplevel` と一致することを実行前に確認する。review以外のresourceはこのreview専用guardを実行せず、固定したroot配下で各skillが指定するresourceだけを呼出直前に検証する。以下のBash例は、同じtool bodyで固定済みrootを使うcommand断片として扱う。

解決後は同じ絶対パスだけを使い、cache / marketplace / 旧インストール領域を走査して選ばない。
version sortによる版の選び直しや、sidecarを使った別実体への切替も行わない。
解決済みrootまたは必要resourceが消失・不整合になった場合は、別versionへfallbackせず
「ff-dev-toolkit更新後にこのskillを再呼び出してください」と案内して停止する。
<!-- ff-dev-toolkit-plugin-root-contract:end -->

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

**注意**: サンドボックスを適用できない環境では、Grok の行に「この環境では sandbox を適用できません」という警告が出ることがあります（プランからは外れませんが、その CLI は未実行になります）。判定の範囲と限界は multi-review スキルの「プラン確認（--dry-run）」節を参照してください。

### 3. 探索実行

ユーザーが承認したら、実際の探索を実行します:

```bash
bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-agent.sh" --task explore --description "<探索対象>" $OPTIONS
```

**注意**: explore タスクは read-only です。コードの変更は行いません。

実行中は進捗状況を監視し、完了を待ちます。background で起動して完了を待つ場合は、foreground の `sleep` や自作の待機ループで空回りせず、Monitor（無ければ `until` ループの background bash）を armed してから停止し、完了通知で再開します。

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
- 設定のカスタマイズ: プロジェクト側に `.claude/agent-config.yaml` を置くとプラグイン同梱のデフォルト設定より優先される。**どのキーが実際に読まれるか**の正本は [Multi-CLI Agent Orchestration の「実際に読まれるキー」](../../docs-template/05-operations/deployment/multi-cli-agent-orchestration.md#実際に読まれるキー)（説明をここへ複製しない）
