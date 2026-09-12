---
name: multi-implement
description: 複数の AI CLI を並列実行して実装タスクを分担する（結果はステージングディレクトリ経由・ユーザー承認後に適用）
---

# /multi-implement — 複数AIによる並列実装

4つのAI CLI（Claude Code / Codex / Copilot / Grok）を並列実行し、異なる観点から実装タスクを分担します。

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

- `$ARGUMENTS` — 実装タスクの説明（必須）+ multi-agent.sh に渡すオプション
  - 例: `新しいバリデーション関数を追加`
  - 例: `ユーザー認証ミドルウェアのリファクタリング --cli claude-code --cli codex-cli`
  - 例: `テストコードの拡充 --include-diff`（現在の差分も含める）
  - 全オプションは `FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-agent.sh" --help` で確認できます

## 手順

### 1. 引数の解析

`$ARGUMENTS` の最初の部分（`--` で始まらない部分）を実装タスクの説明として取得します。
残りのオプションは multi-agent.sh に渡します。

### 2. プラン確認（--dry-run）

まず実行プランを表示し、ユーザーに確認を求めます:

```bash
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-agent.sh" --task implement --description "<タスク説明>" --dry-run $OPTIONS
```

出力を確認し、以下をユーザーに報告:

- 検出されたCLI一覧（✅/❌）
- 各CLIに割り当てられたパースペクティブ（実装/テスト/ドキュメント/リファクタ/マイグレーション）
- モード・戦略・タイムアウト設定

ユーザーに「このプランで実行してよいか」を確認してください。

**注意**: サンドボックスを適用できない環境では、Grok の行に「この環境では sandbox を適用できません」という警告が出ることがあります（プランからは外れませんが、その CLI は未実行になります）。判定の範囲と限界は multi-review スキルの「プラン確認（--dry-run）」節を参照してください。

### 3. 実装実行

ユーザーが承認したら、実装を実行します:

```bash
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-agent.sh" --task implement --description "<タスク説明>" $OPTIONS
```

**`<タスク説明>` の標準文言**: `--description` はそのまま各 CLI への `## Task Description` に載る（`scripts/adapters/adapter-common.sh` の `build_prompt`）。ここに「指示からの逸脱は根拠（実測・grep・一次情報）つきで報告してよい。盲従して欠陥を作り込まない」に相当する一文を常置する。オーケストレータ（このスキルを実行する側）が混入させた設計仕様の誤りを実装 agent が実測で検出・自己訂正できるようにするため（OBS-056）。

**`<タスク説明>` を組み立てる前のオーケストレータ側の確認義務**: 上記は委譲先（子）が逸脱を報告してよいという子側の規定で、それだけでは親側の確認を代替できない。委譲プロンプトへ載せる事実主張と、委譲先の完了報告を転記する場面の両方に、親（このスキルを実行するオーケストレータ）の一次情報確認が要る。規定と背景の正本は [Multi-CLI Agent Orchestration の「委譲プロンプトへ載せる事実主張の一次情報確認」](../../docs-template/05-operations/deployment/multi-cli-agent-orchestration.md#委譲プロンプトへ載せる事実主張の一次情報確認)（規定はここへ複製しない。この経路に限らず、ホストの Agent / Task ツールで直接起こす委譲を含むエージェントへの委譲すべてが対象）。

**依存プリフライトはこの経路では委譲先に任せない**: この経路は委譲先が worktree を作らず、起動元の作業ツリーをそのまま使う（CLI の CWD はリポジトリの物理ルートへ固定される）。さらに implement のプロンプト契約は staging 配下だけへの書き込みを課すため、作業ツリーの `node_modules` を作る依存インストールは委譲先が実行できない（[Implement の書き込み境界](../../docs-template/05-operations/deployment/multi-cli-agent-orchestration.md#implement-の書き込み境界)）。起動元が依存未インストールの新規 worktree なら、**CLI を起動する前にオーケストレータが依存インストール（例: `npm ci --prefix <この作業ツリー>/<パッケージ定義のあるディレクトリ>`）を済ませる**。済ませずに起動すると、CLI が回すテストも、staging を適用したあとに回すゲートも環境都合で崩れる。委譲プロンプトへ常置する形が要るのは worktree 隔離で起動するホストの subagent 経路で、そちらは下の「重要ルール」が持つ。規定と背景の正本は [Multi-CLI Agent Orchestration の「worktree 委譲の依存プリフライト」](../../docs-template/05-operations/deployment/multi-cli-agent-orchestration.md#worktree-委譲の依存プリフライト)（規定はここへ複製しない）。

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
成果が残ります。残った staging は実行ログ（stderr）と統合レポートの
「Not part of this run」節が `<cli>/files/<perspective>/` の形で名指しします
（ファイル自体には触れません）。統合レポートは各セクションに実パスと実測ファイル数を
書くので、ツリー全体を眺めるのではなくレポートのセクションを読んでください。

実行中は進捗状況を監視し、完了を待ちます。background で起動して完了を待つ場合は、foreground の `sleep` や自作の待機ループで空回りせず、Monitor（無ければ `until` ループの background bash）を armed してから停止し、完了通知で再開します。

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
| codex-cli | documentation | docs/... | 新規作成 |

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
- 長時間・大規模タスクをブランチ上で作業するエージェント（ホストの subagent / worktree 委譲など）へ委譲する場合は、[Multi-CLI Agent Orchestration の「長時間タスクの委譲契約（こまめコミット）」](../../docs-template/05-operations/deployment/multi-cli-agent-orchestration.md#長時間タスクの委譲契約こまめコミット) に従う（契約 3 項目の規定はここへ複製しない）
- ホストの subagent を worktree 隔離で起動して委譲し、その委譲先がゲート・テストを回す場合は、[Multi-CLI Agent Orchestration の「worktree 委譲の依存プリフライト」](../../docs-template/05-operations/deployment/multi-cli-agent-orchestration.md#worktree-委譲の依存プリフライト) に従い、起動プロンプトへ依存インストールのコマンドを実値で常置する。リンクではなくコマンドの実値を書く（起動プロンプトは貼られた先で読まれるので相対リンクは解決しない）（規定はここへ複製しない）
- 委譲先のエージェントが完了報告を返したら、そのエージェントが background で起こした子プロセスの取り残しを確認して回収する。[Multi-CLI Agent Orchestration の「委譲先の完了後に残る background 子プロセス」](../../docs-template/05-operations/deployment/multi-cli-agent-orchestration.md#委譲先の完了後に残る-background-子プロセス) に従う（探し方・検出コマンド・回収手順の正本はすべて同節。規定と検出コマンドの正本はここへ複製しない）
- 委譲先に全件ゲート・依存インストール等の長時間コマンドを回させる場合は、[Multi-CLI Agent Orchestration の「委譲先に長時間コマンドを foreground で待たせる契約」](../../docs-template/05-operations/deployment/multi-cli-agent-orchestration.md#委譲先に長時間コマンドを-foreground-で待たせる契約) に従い、起動プロンプトへ「長時間コマンドは Bash ツールの `timeout` へ `600000`（ミリ秒）を明示して foreground で待つ / background 実行オプション（`run_in_background` 等）を使わない」を実値ごと常置する。実値はリンクで代替しない — 貼られたプロンプトの中では相対リンクが解決せず、正本を読まない委譲先には値が届かない（規定はここへ複製しない。この経路に限らず、ホストの Agent / Task ツールで直接起こす委譲を含むエージェントへの委譲すべてが対象）
- 委譲先へ渡した worktree を回収するときは、[Multi-CLI Agent Orchestration の「生存中の委譲先の worktree を回収しない」](../../docs-template/05-operations/deployment/multi-cli-agent-orchestration.md#生存中の委譲先の-worktree-を回収しない) に従う。未コミット差分 0 件を回収の根拠にせず、成果の確認と生存判定の実測が揃ってから回収する（判定手順の正本は同節。ここへ複製しない）
- 実装結果はステージングディレクトリに出力 — ワーキングツリーに直接書き込まない
- ワーキングツリーへの適用前にユーザー承認を得ること
- 結果は `.implement-results/` に保存され、後から参照できます（生成ファイル本体は `<cli>/files/<perspective>/`）
- **生成ファイルを探すときは統合レポートのセクションに書かれた実パスを使う** — ツリーを直接 `find` すると、今回の実行プランに入らなかったタスクの前回分を混ぜて読むことになります
- staging の実パスは orchestrator が解決して各 CLI のプロンプトに明示する。アダプタを直接叩く場合は `--staging-dir` を明示しない限り渡らず、その場合は `--inline-output` を付けて「ファイルを書かず内容を応答へインライン出力する」モードを明示的に選ぶ（無指定の implement は fail-loud で落ちる — 渡し忘れを静かに退避モードへ落とさないため）
- CLI の CWD（sandbox root）は対象リポジトリの物理ルートへ固定される。サブディレクトリから起動しても変わらず、`output_dir` / `--output-dir` がリポジトリ外へ解決される場合は、書けない staging をプロンプトへ渡す前に拒否する
- `--inline-output` はプロンプトだけの約束ではなく、各 CLI で read-only 相当（sandbox / tool allowlist / permission deny）へ狭める。通常 implement の staging 書き込み権限とは区別する
- 設定のカスタマイズ: プロジェクト側に `.claude/agent-config.yaml` を置くとプラグイン同梱のデフォルト設定より優先される。**どのキーが実際に読まれるか**の正本は [Multi-CLI Agent Orchestration の「実際に読まれるキー」](../../docs-template/05-operations/deployment/multi-cli-agent-orchestration.md#実際に読まれるキー)（説明をここへ複製しない）
