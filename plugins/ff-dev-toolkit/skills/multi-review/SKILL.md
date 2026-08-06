---
name: multi-review
description: 複数の AI CLI（Claude Code / Codex / Gemini / Grok、Copilot はオプトイン）を並列実行し、異なる観点からクロスモデルレビューを行う
---

# /multi-review — 複数AIによるクロスモデルレビュー実行

複数のAI CLI（Claude Code / Codex / Gemini / Grok）を並列実行し、異なる観点からコードレビューを実行します。Copilot CLI は従量課金のため既定ラインナップ外です（`--cli copilot-cli` でオプトイン）。

## プラグインルートの解決

同梱スクリプトを実行する前に `FF_DEV_TOOLKIT_ROOT` を解決する。Claude Code では `${CLAUDE_PLUGIN_ROOT}` を使い、Codex など他ホストでは読み込んだこの `SKILL.md` の絶対パスから `../..` を解決する。以下の `${FF_DEV_TOOLKIT_ROOT}` はその絶対パスを指す。バージョン別 cache を探索して選ばない。

## 前提

- git リポジトリで作業中であること
- 本プラグイン同梱の `${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh` を使用する
- 少なくとも1つのAI CLIがインストールされていること（`claude`, `codex`, `copilot`, `gemini`, `grok` のいずれか）
- `yq` がインストールされていること（`brew install yq`）
- 未コミットまたはブランチ上の変更が存在すること

## 引数

- `$ARGUMENTS` — multi-review.sh に渡すオプション（省略時はデフォルト設定で実行）
  - 例: `--cli claude-code --cli codex-cli`（特定CLIのみ）
  - 例: `--strategy minimize_cost`（コスト最小化）
  - 例: `--perspective code-review`（特定パースペクティブのみ）
  - 例: `--mode cross-model --perspective code-review`（クロスモデル比較）
  - 全オプションは `bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh" --help` で確認できます

distributed モードで `--perspective` だけを指定すると、固定レジストリ上でその
perspective を所有する CLI だけがプランに残ります。導入済み CLI が除外された理由は
dry-run に表示され、review が暗黙に単一 CLI へ縮退した場合は警告されます。
同じ perspective を複数モデルで実行するには
`--mode cross-model --perspective <name>` を指定してください。
単一の `--cli <name> --perspective <name>` を両方明示した場合は、その組み合わせを
実行します。複数 CLI / perspective の repeatable 指定は既存の所有レジストリで
絞り込み、全組み合わせの直積にはしません。明示した `--cli` は cost strategy で
別 CLI へ置換されません。未知または review に存在しない perspective は dry-run
でもエラーになります。

## 手順

### 0. レビュワーの確認（未設定なら 1 度だけ聞く）

レビューは **主（メインで使っている CLI）に全観点 + 副にもう 1 つの CLI で総合レビュー 1 本**の 2 段構えで走ります。副が無ければ主のみの単一レビューに縮退します。

まず現在の設定を確認します。

```bash
bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-agent.sh" --task review --print-reviewers
```

**終了コードで分岐します**（出力のマーカー行を `grep -q` で拾う形にしないこと。パイプ入力の `grep -q` は SIGPIPE + `pipefail` で判定が反転します）。

- **exit 0** — 設定済み。ただし出力の `main=` が `available=` に含まれているか確認する（保存済みの CLI が未導入だとレビューは開始できない）。含まれていなければ exit 3 と同じ扱いで選び直してもらう
- **exit 3** — 未設定。以下を行う
- **それ以外（exit 1 など）** — 設定または環境の問題。**先へ進まない。** stderr をそのままユーザーへ提示して停止する。到達しうるのは、保存済みの値が不正な場合、AI CLI が 1 つも導入されていない場合など。CLI 未導入なら stderr にインストール手順が出ている

未設定のときは、出力の `available=` に並ぶ CLI を選択肢として、利用中のホストに構造化質問機能があれば使用し、なければ通常の対話で、主と副を選んでもらいます。

- **主** — メインで使っている CLI。review 観点すべてを担当する
- **副** — もう 1 つ入っている CLI。総合レビューを 1 本だけ担当する（不要なら省略可）

選んでもらったら保存します。以降は聞きません。

```bash
bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-agent.sh" --task review \
  --set-reviewers main=<cli>,sub=<cli>
```

保存するのは **CLI 名だけ**です（`claude-code` / `codex-cli` / `gemini-cli` / `grok-cli` / `copilot-cli`）。どのモデルを使うかは各 CLI 自身の設定に委ねるため、モデル名を渡すと拒否されます。

> **非対話で実行している場合**（CI など）は、この手順を飛ばしてください。レビュワーが未設定でも従来の分散プランで続行し、ブロックしません。

### 1. プラン確認（--dry-run）

まず実行プランを表示し、ユーザーに確認を求めます:

```bash
bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh" --dry-run $ARGUMENTS
```

出力を確認し、以下をユーザーに報告:

- 検出されたCLI一覧（✅/❌）
- 各CLIに割り当てられたパースペクティブ
- モード・戦略・タイムアウト設定

ユーザーに「このプランで実行してよいか」を確認してください。

### 2. レビュー実行

ユーザーが承認したら、実際のレビューを実行します:

```bash
bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh" $ARGUMENTS
```

**注意**: 実行には各CLIの利用コストが発生します（特に premium/standard ティアのCLI）。`--strategy minimize_cost` で固定料金/無料CLIを優先できます。タイムアウトはデフォルト **900秒/CLI** です（旧既定の 5 分では中規模差分の Codex レビューが完走しなかったため引き上げ。`--timeout <秒>` で上書き可）。CLI が早く応答すればその時点で次に進むので、上限を大きく取っても待ち時間は増えません。

実行中は進捗状況を監視し、完了を待ちます。

**CLI が失敗・タイムアウトした場合**: そのタスクは失敗として報告され、**別 CLI での自動再実行（実行時 fallback）は行われません**。打ち切り前に得られた部分出力は `Status: incomplete` 付きの結果ファイルとして保存され、統合レポートにも「INCOMPLETE」と明示されます。**未完了の節は「指摘なし」ではなく「未確認」と読むこと。** 失敗サマリーが「同じ CLI に時間を足す」「設定上の代替 CLI を明示実行する」2 つのコマンドを出力するので、必要なものを選んで再実行します。

### 3. 結果分析と修正提案

レビュー結果は `.review-results/` ディレクトリに出力されます。

#### 3-1. 結果ファイルの読み込み

スクリプトが自動生成する統合レポートをまず読み込みます:

```bash
# スクリプト生成の統合レポートを確認
cat .review-results/integrated-report.md

# 各CLIの個別結果も必要に応じて確認
ls -la .review-results/
```

個別結果ファイルのパス: `.review-results/{cli-name}/{perspective}.md`

#### 3-2. 重大度別の分類

スクリプト生成レポートを基に、PR Review Response Policy に従って分類します:

| 重大度 | 対応 |
| ------ | ---- |
| **Critical** | 必ず修正（確認不要で即対応） |
| **Warning** | 必ず修正（確認不要で即対応） |
| **Suggestion** | 実装が妥当なものは対応（確認不要） |
| **Info/Good Practices** | 確認のみ（対応不要） |

#### 3-3. 重複排除（デデュプリケーション）

複数のCLIが同じ問題を指摘している場合、重複を排除してまとめます。
同じファイル・同じ行番号・同じ種類の指摘は1つにまとめ、検出したCLI名を併記します。

#### 3-4. 統合レポートの出力

以下の形式でユーザーに報告します:

```markdown
## Multi-CLI Review 統合レポート

### Critical Issues (X件)
- [CLI名] ファイル:行番号 — 問題の説明

### Warning Issues (X件)
- [CLI名] ファイル:行番号 — 問題の説明

### Suggestions (X件)
- [CLI名] ファイル:行番号 — 提案内容

### クロスモデル検出（複数CLIが指摘）
- [CLI-A, CLI-B] ファイル:行番号 — 問題の説明（信頼度: 高）

### Summary
| CLI | Critical | Warning | Suggestion | Info |
|-----|----------|---------|------------|------|
| claude-code | X | X | X | X |
| codex-cli | X | X | X | X |
| ... | ... | ... | ... | ... |
```

#### 3-5. 自動修正の実行

PR Review Response Policy に従い、Critical/Warning/妥当な Suggestion を自動修正します:

1. Critical/Warning の修正対象をリストアップ
2. 各問題に対して修正を実施
3. Suggestion は実装が妥当なものを対応（確認不要）
4. 修正内容をユーザーに報告

修正完了後:

```bash
git diff  # 修正内容の確認
```

## 重要ルール

- ステップ1の dry-run 確認なしにステップ2を実行しないこと
- Critical/Warning の自動修正はユーザー確認不要で実行すること（PR Review Response Policy準拠）
- 妥当な Suggestion も確認不要で対応すること
- Info は報告のみで修正しないこと
- CLI **未インストール**の場合は fallback 設定に従って自動再分配されます（プラン構築時のみ）
- distributed モードの `--perspective` は所有 CLI だけを残すため、単一 CLI に縮退しうる。dry-run の除外理由と単一 CLI 警告を確認し、クロスモデル比較が必要なら `--mode cross-model` を使う
- 単一の `--cli` と単一の `--perspective` を両方明示した場合は、レジストリ上の既定割当より利用者の指定を優先する。複数指定は所有レジストリで絞り込む
- インストール済み CLI の**実行時**エラー／タイムアウトは fallback しません。クロスモデル性（どのモデルが実際に見たか）が黙って変わること、代替先のコスト帯が上がりうること、タイムアウト後の再試行が同じ制限時間をもう一度消費することを避けるためです
- `Status: incomplete` / `INCOMPLETE` が付いた節は未完了レビューです。Critical/Warning が無いことを「問題なし」と解釈しないこと
- 結果は `.review-results/` に保存され、後から参照できます
- 設定のカスタマイズ: プロジェクト側に `.claude/agent-config.yaml` を置くとプラグイン同梱のデフォルト設定より優先される（環境変数 `MULTI_AGENT_CONFIG=<path>` または `--config <path>` でも上書き可。読み取りは `yq` 依存で、無い環境では設定ファイルは読まれず既定値で動く）。ただし**実際に読まれるのは `version` / `mode` / `parallel` / `review.main` / `review.sub` と、`version: "2.0"` のときだけ `tasks.<task>.{mode,cost_strategy,timeout,output_dir}` である**（`version` が `2.0` でない場合は v1 形式とみなされ、トップレベルの `cost_strategy` / `timeout` / `output_dir` が読まれる — `version` を書き忘れると `tasks.*` が黙って無視されるので注意）。`agents:` と `fallback:` はどのバージョンでも読まれず、人が読むための対応表にすぎない。実行時のレジストリの正本は `scripts/multi-agent.sh` の `get_cli_*` 関数

## モデル選択

**ラッパーはモデルを選ばない。** どのモデルを使うかは各 CLI 自身の設定に委譲する — `~/.codex/config.toml`、Claude Code のモデル設定、Copilot の `auto` など。ラッパー側に既定のモデル slug を持たせると、その値の SSOT がユーザーの CLI 設定と2重化して必ず古くなり、しかもフラグを無条件に渡す実装だとユーザー設定を黙って上書きする（`docs-template/08-knowledge/playbook/tooling.md` の ACE-70-2 に実害の記録がある）。

明示的に指定したい場合だけ環境変数を使う。**未設定ならフラグ自体が渡らない**ので、指定しない限り CLI 側の設定がそのまま効く。

| 環境変数 | 渡されるフラグ | 対象 |
|---|---|---|
| `MULTI_AGENT_MODEL_CLAUDE_CODE` | `--model` | Claude Code。`opus` / `sonnet` / `haiku` / `fable` は**最新版を指すエイリアス**なので、slug 直書きより腐りにくい |
| `MULTI_AGENT_CODEX_PROFILE` | `-p` | **Codex の推奨経路**。`~/.codex/<name>.config.toml` を base 設定に重ねる |
| `MULTI_AGENT_MODEL_CODEX_CLI` | `-m` | Codex のモデルを単発で指定。`MULTI_AGENT_CODEX_PROFILE` とは併用不可 |
| `MULTI_AGENT_MODEL_COPILOT_CLI` | `--model` | Copilot。`auto` で Copilot 側の自動選択 |
| `MULTI_AGENT_MODEL_GEMINI_CLI` | `-m` | Gemini |
| `MULTI_AGENT_MODEL_GROK_CLI` | `-m` | Grok |

```bash
# Codex を専用プロファイルでレビューさせる（推奨）
#   事前に ~/.codex/review.config.toml へ model と model_reasoning_effort を書いておく
MULTI_AGENT_CODEX_PROFILE=review \
  bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh" $ARGUMENTS
```

Codex は `-m`（単発 slug）より **`--profile` が推奨**。プロファイルはモデルと `model_reasoning_effort` を1つのファイルで束ねられるため、「古いモデル + 新しい reasoning effort」という誰も意図していない組み合わせを避けられる。

ただしその利点が成立するのは `-p` 単独のときだけ。`-m` を併用すると **`-m` のモデルがプロファイルのモデルに勝ち、reasoning effort だけプロファイル由来**になる（codex 0.144.5 で実測）。まさに避けたかった組み合わせなので、**両方を設定した場合はアダプタが実行前に非 0 で落とす**。

> **プロファイル名は実行前に検証される。** codex 自身は存在しないプロファイル名を**エラーにせず、base config のまま完走する**（0.144.5 で実測）。そのままだと名前を打ち間違えたとき「専用プロファイルでレビューさせたつもり」が成立してしまい、成果物からもログからも判別できない。そこでアダプタは `-p` を渡す前に `${CODEX_HOME:-~/.codex}/<name>.config.toml` の存在を確認し、無ければ CLI を起動せずに落とす。**これは意図した fail-loud であってバグではない。**

各アダプタは起動時に、実際に渡すモデル引数を stderr のバナーへ出す（`Model args: ...`、渡さない場合は `(なし — CLI 自身の設定へ委譲)`）。委譲した以上「実際にどのモデルが使われたか」はラッパーには断定できないので、報告するのは**渡した引数だけ**で実使用モデルは名乗らない。それでも、env 名の打ち間違いや未 export は `(なし)` として即座に見えるので、設定したつもりで効いていない事故に気づける。

なお、ラッパーが具体的なモデル slug を持ち込んでいないことは `tests/no-hardcoded-model/verify.sh` が、環境変数が実際に CLI の argv へ届くことは `tests/adapter-model-args/verify.sh` が機械的に検査している。
