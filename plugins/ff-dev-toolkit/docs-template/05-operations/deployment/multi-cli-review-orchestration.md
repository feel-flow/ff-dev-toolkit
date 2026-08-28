# Multi-CLI Review Orchestration

> **Parent**: [DEPLOYMENT.md](../DEPLOYMENT.md) | [ai-tools-integration.md](./ai-tools-integration.md)

## 概要

複数のAI CLI（Claude Code、Codex、Copilot、Grok）をレビュワーとしてオーケストレーションし、設定駆動で統一的に管理する運用ガイドです。

**目的**: 各CLIの得意分野とコスト特性を活かし、高品質かつコスト効率の良いコードレビューを実現する

> **標準レビュー体制**: 一次レビューは Claude Code（pr-review-toolkit）、クロスモデルレビューは Codex CLI の2本柱が標準です。GitHub Copilot（Copilot CLI / Copilot code review）は従量課金への移行に伴い**既定のレビューラインナップから除外**しました（アダプタは残置、`--cli copilot-cli` でオプトイン可能）。

---

## 目次

- [アーキテクチャ](#アーキテクチャ)
- [前提条件](#前提条件)
- [セットアップ](#セットアップ)
- [設定カスタマイズ](#設定カスタマイズ)
- [ワークフロー統合](#ワークフロー統合)
- [運用コマンド](#運用コマンド)
- [トラブルシューティング](#トラブルシューティング)

---

## クロスモデルレビュー（推奨パターン）

Multi-CLI の全体オーケストレーションとは別に、**Claude系 + GPT系のデュアルモデルレビュー**を軽量に実行するパターンです。異なるAIモデルの観点でレビュー品質を向上させます。

### Codex CLI 3パターン

| パターン                     | 実行タイミング       | 自動/提案        | 説明                                          |
| ---------------------------- | -------------------- | ---------------- | --------------------------------------------- |
| **Cross-Model Review**       | セルフレビュー時     | 必須（順次実行） | Claude Toolkit + Codex CLI でデュアルレビュー |
| **Parallel Task Suggestion** | 独立サブタスク発見時 | ユーザーに提案   | 並列実行による効率化                          |
| **Second Opinion**           | 設計判断の分岐点     | ユーザーに提案   | アーキテクチャ決定の第二意見                  |

#### Pattern 1: Cross-Model Review（必須・順次実行）

PR Review Toolkit（Claude系）でのセルフレビュー後に続けて実行します。CLAUDE.md のワークフロー指示に基づき、AIツールが Toolkit → Codex CLI の順で実行します。

```bash
# Toolkit レビュー後に実行（プラグイン同梱 multi-review → multi-agent 経由）
bash scripts/multi-review.sh --mode cross-model --cli codex-cli
# scripts/codex-review.sh は multi-agent.sh へ委譲するシムとして同梱される
# （setup-multi-agent.sh が配置する。下の呼び出しと等価）
```

pre-commit で staged index だけをレビューする場合は次を使う。

```bash
bash scripts/multi-review.sh --staged
```

`--staged` は `git diff --cached` だけを各 prompt へ渡し、unstaged / branch 差分は
混ぜない。変更が無ければ CLI を起動せず明示 skip + exit 0 になる。`--base` および
`MULTI_AGENT_BASE_BRANCH` との同時指定はレビュー範囲が曖昧になるため拒否する。

`--base <branch>` の裸のブランチ名は**ローカル ref を先に**見る。ブランチを
`origin/<branch>` の先端から切ったのにローカル base が後退している場合、三点比較の
merge-base がずれ、他ブランチのマージ済みコミットがレビュー diff に混入する。
この形（merge-base の不一致）を検出した場合、review / `--include-diff` の実行では
プラン表示の前に混入件数つきの警告を出す（中断はしない — 意図的にローカル base を
使う運用を壊さないため。`origin/<branch>` の明示指定か、base の pull 最新化で解消）。
なお「pull していないローカル base から切ったブランチ」は behind でも混入ゼロなので
警告しない（behind 数ではなく merge-base を比較する）。

レビュー結果は [PRレビュー対応ポリシー](./review-response-policy.md) に従って対応します。

#### Pattern 2: Parallel Task Suggestion（ユーザーに提案）

独立したサブタスクが複数ある場合、ユーザーに並列実行を提案します。

- 提案例：「テスト追加はCodex CLIに任せて、私はメインロジックを進めますか？」
- AIツールは提案のみ、実行はユーザー判断

#### Pattern 3: Second Opinion（ユーザーに提案）

アーキテクチャ判断や設計の分岐点で、Codex CLIの意見を参考にすることを提案します。

- 提案例：「この設計判断、Codex CLIでもセカンドオピニオン取ってみますか？」
- AIツールは提案のみ、実行はユーザー判断

---

## アーキテクチャ

### 全体構成

```
┌─────────────────────────────────────────────────────────┐
│                   Entry Points                           │
│  Terminal │ Claude Code │ CI/CD │ Husky Hook           │
└─────┬───────────┬──────────┬────────┬────────┬──────────┘
      │           │          │        │        │
      └───────────┴──────────┴────┬───┴────────┘
                                  │
                    ┌─────────────▼──────────────┐
                    │   multi-review.sh           │
                    │   (Orchestrator)            │
                    │                             │
                    │  ┌───────────────────────┐  │
                    │  │  review-config.yaml   │  │
                    │  │  (設定)               │  │
                    │  └───────────────────────┘  │
                    └──────────┬──────────────────┘
                               │
             ┌───────────┬─────┴─────┬───────────┐
             │           │           │           │
        ┌────▼────┐ ┌────▼────┐ ┌────▼────┐ ┌────▼────┐
        │Claude   │ │Codex    │ │Copilot  │ │Grok     │
        │Adapter  │ │Adapter  │ │Adapter  │ │Adapter  │
        └────┬────┘ └────┬────┘ └────┬────┘ └────┬────┘
             │           │           │           │
             ▼           ▼           ▼           ▼
        ┌────────────────────────────────────────────┐
        │          perspectives/*.md                  │
        │  (ツール非依存プロンプト)                     │
        └────────────────────────────────────────────┘
                               │
                    ┌──────────▼──────────────┐
                    │  .review-results/       │
                    │  ├── claude-code/       │
                    │  ├── codex-cli/         │
                    │  ├── copilot-cli/       │
                    │  ├── grok-cli/          │
                    │  └── integrated-report.md│
                    └─────────────────────────┘
```

### データフロー

1. **エントリーポイント** → `multi-review.sh` を呼び出し
2. **設定読み込み** → `review-config.yaml` からCLI設定・戦略を取得
3. **CLI検出** → `command -v` で利用可能なCLIを検出
4. **フォールバック** → 未インストールCLIのパースペクティブを再分配
5. **並列実行** → 各CLIアダプターを並列で実行（flat-rate CLI に複数観点が乗る場合、その CLI 内はレート制限保護のため逐次実行。CLI 間の並列は維持）
6. **結果収集** → `.review-results/{cli-name}/{perspective}.md` に出力（実行開始時に、今回のプランに無い自筆の前回結果を `{cli-name}/previous/` へ退避してから書く。プラン外 CLI のディレクトリは動かさない）
7. **統合レポート** → 重複除去・統合してレポート生成

---

## 前提条件

### 必須

- Bash（**3.2 以上**。stock macOS の `/bin/bash` が 3.2 系であるため、同梱スクリプトは 3.2 互換で書かれている — 連想配列や `${var^^}` は使わない）
- Git（diffの取得に使用）
- 1つ以上のAI CLI

### 対応プラットフォーム

| プラットフォーム | 状態 |
|---|---|
| macOS | 対応（主な開発・検証環境） |
| Linux | 対応 |
| Windows（ネイティブ） | **非対応** |
| Windows（WSL2 / Git Bash） | bash 環境として動作する想定。ただし未検証 |

**Windows がネイティブ非対応なのは、このツールキットが端から端まで bash で書かれているため**。オーケストレータ（`multi-agent.sh`）、各 CLI アダプタ、セットアップ、更新通知フック、スキルが呼び出す実体まで、配布物のシェルスクリプトはすべて `.sh` であり、PowerShell / cmd 版は存在しない。レビューラッパーだけを PowerShell 化しても他が動かないため、部分的な移植は行っていない。

Windows で使う場合は bash が動く環境を用意する:

- **WSL2（推奨）** — Linux ディストリビューションを入れ、**その中に** Git・AI CLI・ツールキットを揃える。アダプタは PATH 経由で CLI を起動するので、CLI が Windows 側にしか入っていないと検出されない
- **Git for Windows の Git Bash** — 軽量だが、AI CLI 側が Windows ネイティブとして振る舞うためパス表記（`C:\...` と `/c/...`）の食い違いが起こりうる

いずれも継続的な検証はしていない。動かない場合は「Windows で動かない」ではなく**どのスクリプトがどう失敗したか**を添えて issue を立てること。ネイティブ対応（PowerShell 版の提供）はツールキット全体の設計判断であり、個別スクリプト単位では扱わない。

### 推奨

- Mike Farah `yq` v4（YAMLパーサー、設定ファイル読み込みに使用）
  - Homebrew がある場合（macOS / Linuxbrew）: `brew install yq`
  - Homebrew が無い場合: 同梱の `bash scripts/setup-multi-agent.sh` が [mikefarah/yq](https://github.com/mikefarah/yq) の GitHub release から公式バイナリを導入する（`curl` または `wget` が必要。配置先は既定で `~/.local/bin`。PATH に無い場合は shell profile へ追加する）
  - **注意**: Ubuntu 等の distro パッケージ（`apt install yq` / `yum install yq`）は別実装のことがあり、本ツールが使う `yq -r` 式や capability probe と互換にならない。パッケージ経由の導入は使わない
- 3つ以上のAI CLIインストール（分散レビューの効果を最大化）

### CLI別インストール状態の確認

```bash
# インストール確認コマンド
command -v claude  && echo "✅ Claude Code" || echo "❌ Claude Code"
command -v codex   && echo "✅ Codex CLI"   || echo "❌ Codex CLI"
command -v copilot && echo "✅ Copilot CLI"  || echo "❌ Copilot CLI"
command -v grok    && echo "✅ Grok CLI"     || echo "❌ Grok CLI"
```

---

## セットアップ

### Step 1: スクリプト配置

```bash
# リポジトリルートから
chmod +x scripts/multi-review.sh
chmod +x scripts/adapters/*.sh
```

### Step 2: 設定ファイルのカスタマイズ

`scripts/review-config.yaml` を環境に合わせて編集します。

> **Note**: 現行の `multi-agent.sh` が config から読み込むのは `mode` / `parallel` / `tasks.*`（cost_strategy / timeout / output_dir）のみで、**パースペクティブ割り当てとフォールバックはスクリプト内（`get_cli_perspectives_review()` 等）にハードコード**されています。割り当てを変更する場合は YAML とスクリプトの両方を同期して編集してください。

```yaml
version: "1.0"
mode: distributed
parallel: true
cost_strategy: balanced

agents:
  claude-code:
    command: claude
    cost_tier: premium
    default_perspectives: [type-design-analysis, comment-analysis]

  codex-cli:
    command: codex
    cost_tier: standard
    default_perspectives: [code-review, test-analysis]

  copilot-cli:
    command: copilot
    cost_tier: metered # 従量課金 — 既定プランには載らない（--cli copilot-cli 明示時のみ実行）
    default_perspectives: [test-analysis, comment-analysis]

  grok-cli:
    command: grok
    cost_tier: flat-rate
    default_perspectives: [error-handler-hunt, security-analysis]

fallback:
  claude-code: codex-cli
  codex-cli: claude-code
  copilot-cli: codex-cli
  grok-cli: codex-cli
```

### Step 3: 動作確認

```bash
# 利用可能なCLIと設定を表示
bash scripts/multi-review.sh --dry-run

# 特定のCLIだけでテスト
bash scripts/multi-review.sh --cli codex-cli --perspective test-analysis
```

---

## 設定カスタマイズ

### コスト戦略

| 戦略               | 説明                       | 推奨場面                 |
| ------------------ | -------------------------- | ------------------------ |
| `balanced`         | コストと品質のバランス     | 通常の開発（デフォルト） |
| `minimize_cost`    | 定額（flat-rate）CLIを優先使用 | 予算制約がある場合       |
| `maximize_quality` | 高品質CLIに多く割当        | リリース前の最終レビュー |

### モード

| モード        | 説明                                              |
| ------------- | ------------------------------------------------- |
| `distributed` | 各CLIが異なるパースペクティブを担当（デフォルト） |
| `cross-model` | 全CLIで同じパースペクティブを実行して比較         |

### よくあるカスタマイズ例

#### 例1: Grok のみで運用（定額）

```yaml
cost_strategy: minimize_cost
agents:
  grok-cli:
    command: grok
    cost_tier: flat-rate
    default_perspectives:
      [security-analysis, code-simplification, type-design-analysis]
```

#### 例2: Claude + Codex のクロスモデル比較

```yaml
mode: cross-model
agents:
  claude-code:
    command: claude
    cost_tier: premium
    default_perspectives: [code-review]
  codex-cli:
    command: codex
    cost_tier: standard
    default_perspectives: [code-review]
```

---

## ワークフロー統合

### Git Workflow への組み込み

[AI駆動Git Workflow](./git-workflow.md) のステップ5（セルフレビュー）に統合します：

```
ステップ3: 実装 & コミット（Implement）
    ↓
ステップ4: テスト・検証（Test）
    ↓
ステップ5: セルフレビュー（Self-Review）
    ├── multi-review.sh（Multi-CLI分散レビュー）
    ├── pr-review-toolkit（Claude Code サブエージェント）
    └── codex review --base develop（Codex クロスモデルレビュー）
    ↓
ステップ6: PR作成
```

### Husky pre-push フックとの統合

> **Note**: 以下は設定例です。`.husky/pre-push` ファイルを手動で作成してください。`scripts/multi-review.sh` の実装後に利用可能です。

```bash
# .husky/pre-push（手動作成が必要）
#!/bin/sh
. "$(dirname "$0")/_/husky.sh"

# Multi-CLI レビュー（定額CLIのみ、高速）
# 終了コードを捨てないこと: レビューが 1 本でも失敗・タイムアウトすると非 0 になる
if ! bash scripts/multi-review.sh \
  --strategy minimize_cost \
  --cli grok-cli \
  --sequential; then
  echo "❌ レビューを完走できませんでした（失敗 or タイムアウト）。"
  echo "   未完了のレビューは「指摘なし」ではなく「未確認」です。ゲートとしては通せません。"
  exit 1
fi

# 統合レポート自体の存在を検査する。`grep ... 2>/dev/null` はファイル不在の
# エラーも隠すため、レポートが生成されなかった実行（出力先の契約ドリフト等）
# では以降の 2 つの grep が両方「不在 = 合格」で素通りしてしまう
if [ ! -s .review-results/integrated-report.md ]; then
  echo "❌ 統合レポートがありません。未生成は「指摘なし」ではなく「未確認」です。"
  exit 1
fi

# 未完了の節が残っていればブロック（打ち切られたレビューは CRITICAL_BLOCK を
# 出さないので、CRITICAL_BLOCK だけを見るゲートは「空振り」を pass と読む）
if grep -q "INCOMPLETE" .review-results/integrated-report.md 2>/dev/null; then
  echo "❌ 未完了のレビュー結果が含まれています。再実行するか、対象を絞ってください。"
  exit 1
fi

# Critical があればプッシュをブロック（マーカー**全文**の固定文字列一致にする。
# 裸の CRITICAL_BLOCK への部分一致にしないこと — 連結されるレビュー本文が
# Verdict 語彙やマーカーの引用として同じ文字列を含むと、非ブロック観点だけの
# 実行でも誤発火し、観点別段階化が無効になる）
if grep -qF -- '<!-- CRITICAL_BLOCK -->' .review-results/integrated-report.md 2>/dev/null; then
  echo "❌ Critical issues found. Fix before pushing."
  exit 1
fi
```

> ⚠️ **ゲートを書くときの注意**: `bash scripts/multi-review.sh` の終了コードを捨てて `CRITICAL_BLOCK` の有無だけで判定すると、レビューが 1 件も完走しなかった実行が「Critical なし = 合格」として通ります。これは Issue #152 の失敗モードがそのまま一層外側に出た形です。**終了コードと `INCOMPLETE` の両方**を見てください。

#### CRITICAL_BLOCK の観点別段階化

`<!-- CRITICAL_BLOCK -->` を立てるのは**ブロック観点**（既定では非ブロック名簿に載っていないすべての観点。同梱観点では code-review / security-analysis / error-handler-hunt / comprehensive-review）の Critical だけです。**非ブロック観点**（既定: comment-analysis / test-analysis / type-design-analysis / code-simplification）の Critical は、レポート本文には従来どおり Critical として現れますが、マーカーとしては `<!-- CRITICAL_NONBLOCK -->` の注記になり、それ単独では push ゲートを再発火させません（修正必須である点は変わりません — 次回の通常レビューまたは部分再検証で確認します）。

- 名簿は「格下げする観点」の列挙（denylist）です。載っていない観点 — 将来追加される観点や名簿の typo を含む — は従来どおりブロックします（fail closed）
- 上書きは env `MULTI_AGENT_CRITICAL_NONBLOCK_PERSPECTIVES`（空白またはカンマ区切り。**空文字の明示指定 = 全観点ブロック（旧挙動）**）> プロジェクト設定 `.claude/agent-config.yaml` の `review.critical_nonblock_perspectives`（1 文字列）> 既定、の順で解決されます
- ゲート側の判定は**マーカー全文**の固定文字列一致（`grep -qF -- '<!-- CRITICAL_BLOCK -->'`、上のゲート例）が正です。裸の `CRITICAL_BLOCK` への部分一致は使わないでください — 連結されるレビュー本文には Verdict 語彙やマーカーの引用として同じ文字列が現れうるため、非ブロック観点だけの実行でも誤発火します。なお本文がマーカー行そのものを逐語で引用した場合は全文一致でも発火します（誤ブロック側 = 安全側の残余）。`CRITICAL_NONBLOCK` のマーカー名・注記本文はどちらの判定式にも掛からない形が保たれており、`tests/multi-agent-critical-marker/` が固定しています

### fix ループの部分再検証（--reviewers 限定再実行）

全観点のフルレビューを 1 度通過した後の fix commit は、多くの場合、単一観点の指摘（例: comment-analysis の文言修正、error-handler-hunt の診断メッセージ改善）に閉じている。そのような fix の再検証は、修正が影響する観点だけの**部分再検証**でよい。fix のたびにフルゲート（全観点）を回し直すのは、時間とコストを消費するだけでなく、無関係な観点が毎回新しい低重要度の指摘を拾って fix ループが収束しなくなる原因にもなる。

```bash
# 例: comment-analysis の指摘だけを直した fix の再検証
bash scripts/multi-review.sh --perspective comment-analysis

# シム（codex-review.sh）経由では --reviewers で同じ限定ができる
bash scripts/codex-review.sh --base develop --reviewers comment-analysis
```

**部分再検証の適用条件（すべて満たすときだけ）**:

1. 同じ PR で全観点のフルレビューを 1 度通過済みである（初回レビューは常にフル実行）
2. fix が単一観点の指摘への対応に閉じている
3. 修正対象がブロック観点（`<!-- CRITICAL_BLOCK -->` を立てる観点。同梱観点では code-review / security-analysis / error-handler-hunt / comprehensive-review）の Critical ではない

**フル再実行が必要な条件（いずれか該当で全観点を回し直す）**:

- ブロック観点の Critical を修正した場合（push ゲートのマーカー解消を、他観点との整合ごと確認する）
- 修正が複数観点の指摘にまたがる場合、または挙動・構造を変える修正（文言・コメントに閉じない変更）の場合
- レビュー対象 diff の土台が変わった場合（base への追随・rebase を含む）

**結果ファイルとマーカーの整合ルール**:

- 統合レポート（`.review-results/integrated-report.md`）は正常にレポート生成へ到達した実行ごとに作り直され、**部分再検証後は再実行した観点だけが載る**。ただし前回レポートに未解消 Critical がある場合、再検証の準備失敗または実行中のリビジョン変更で新レポートを生成できなければ、そのレポートを次回ガードの状態として保持する。前回結果の退避が起きるのは**今回のプランに載っている CLI の配下だけ**（その CLI の自筆でプラン外観点の結果が `{cli}/previous/` へ移る）。プランに載らなかった CLI のディレクトリは**前回結果ごとそのまま残り**、実行ログと統合レポートの「Not part of this run」節で名指しされる — 残っているファイルを今回の結果として読まないこと（[結果の確認](#結果の確認)参照）。部分再検証後のレポートを「全観点の最新判定」として読まないこと — 全観点の通過根拠は、フルレビューを通過した実行のレポートと、その後の部分再検証の積み重ねの**組**で示す
- `<!-- CRITICAL_BLOCK -->` / `<!-- CRITICAL_NONBLOCK -->` を立てた観点は、**必ずその観点を再実行セットに含めて**、マーカーが立たなくなることを実測する。オーケストレータは直前レポートを結果消去前に読み、未解消観点を省く部分再検証を非 0 で拒否する。機械状態は branch / base / staged-or-branch-diff のレビュー系列に紐付け、別系列からの絞り込み付き実行も拒否する。別系列では絞り込みのないフルレビューだけが新しい系列を開始できる。Critical マーカーから観点一覧を復元できない旧レポートは、フルレビューもそのままでは開始できない。内容を確認し、不要な旧レポートを別の場所へ移動または削除してから、絞り込みなしで実行する。レポートの手編集でマーカーを消してはならない
- 未解消観点の再実行は、その観点が正常完了し Critical が消えたときだけ解消とする。CLI 失敗または timeout の場合は前回の未解消分類を統合レポートに保持する。準備段階で中断した場合や、実行中のリビジョン変更で結果を破棄した場合は新レポートを作らず、前回の未解消レポートを保持する
- push ゲート（上の Husky 例）は最新の統合レポートだけを判定するため、部分再検証の結果でもゲートは通過できる。これが健全なのは上の適用条件（フルパス通過済み + 単一観点の fix）が守られている場合だけ — 条件を満たさない部分再検証でゲートを緑にするのはレビューの空洞化であり、行わないこと

### CI/CD（GitHub Actions）での実行

```yaml
# .github/workflows/multi-cli-review.yml
name: Multi-CLI Review
on:
  pull_request:
    branches: [develop, main]

jobs:
  review:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install CLI tools
        run: |
          # 必要なCLIをインストール（各CLI公式ドキュメントで最新手順を確認）
          # Claude Code: https://docs.anthropic.com/en/docs/claude-code
          npm install -g @anthropic-ai/claude-code
          # Codex CLI: https://github.com/openai/codex
          npm install -g @openai/codex
          # Grok CLI
          npm install -g @xai-official/grok
      - name: Run Multi-CLI Review
        run: bash scripts/multi-review.sh --strategy minimize_cost
      - name: Upload results
        # if: always() が無いと、レビューが失敗・タイムアウトした回の成果物
        # （打ち切り前の部分出力）がランナーから出てこない。原因調査に必要なのは
        # まさに失敗した回なので、赤いときこそ回収する
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: review-results
          path: .review-results/
```

---

## 運用コマンド

### 基本操作

```bash
# デフォルト実行（全CLI、分散モード）
bash scripts/multi-review.sh

# コスト最小化
bash scripts/multi-review.sh --strategy minimize_cost

# 品質最大化（リリース前）
bash scripts/multi-review.sh --strategy maximize_quality

# クロスモデル比較
bash scripts/multi-review.sh --mode cross-model --perspective code-review
```

### 特定CLI/パースペクティブのみ

```bash
# Claude + Codex だけ（標準の2本柱）
bash scripts/multi-review.sh --cli claude-code --cli codex-cli

# セキュリティ分析だけ
bash scripts/multi-review.sh --perspective security-analysis
```

### 結果の確認

```bash
# 統合レポートを表示
cat .review-results/integrated-report.md

# 特定CLIの結果を表示
cat .review-results/codex-cli/code-review.md

# Criticalのみフィルタ
grep -A 5 "Critical" .review-results/integrated-report.md
```

**今回の実行プランに載った** `{cli}/` の直下にあるのは、その実行の結果だけ。今回の観点セットに含まれない前回実行の結果は、実行開始時に `{cli}/previous/` へ**退避**される（削除ではない）。したがって `ls .review-results/{cli}/` の結果を今回の指摘として読んでよいのは、**その CLI が今回のプランに載っている場合だけ**。退避が起きた実行は件数と観点名を実行ログで名乗る。

- `previous/` は**その CLI を含む実行のたびに作り直す**（前回の退避分は捨て、件数を名乗る）。「直前の実行が押し出した結果」の置き場であり、過去実行のアーカイブではない
- 退避しないもの（意図的な境界）: 今回の実行プランに載っていない CLI のディレクトリ、orchestrator が書いていない `.md`（1 行目が `<!-- Multi-CLI ... Result -->` でないファイル = 利用者のメモ等。退避物は次の実行で捨てられるため他人のファイルは動かさない）、`{cli}/` 直下の `*.md` 以外、サブディレクトリ（implement の `files/` など）
- 動かさなかった残骸のうち結果ファイルを持つものは、実行ログと統合レポートの「**Not part of this run**」節で名指しする。そこに挙がったものは今回の結果ではない
- `{cli}/` が自分以外を指す（symlink が挟まっている）場合は、指し先が出力ディレクトリの内外どちらでも、**resume の書き戻しも前回結果の削除も行わずに**中断する（検査は破壊操作より前に一括で走る）。内側を指す別名を許すと、2 つの CLI 名が同じ実ディレクトリを共有し、同じ場所から退避しつつ「今回のプラン外」と名指しする矛盾が起きるため。`{cli}/previous` が symlink の場合は指し先を追わず、リンク自体だけを外す

---

## トラブルシューティング

### CLIが見つからない

```
ERROR: codex is not installed
```

**対応**: フォールバック設定に従い、自動的に別のCLIに再分配されます。これは**未インストール時のプラン構築限定**の挙動です。手動で特定CLIをスキップするには：

```bash
bash scripts/multi-review.sh --cli claude-code --cli grok-cli
```

### タイムアウト

既定はレビュー 900 秒/CLI です（explore 600 秒・implement 900 秒）。CLI が先に応答すればその時点で次へ進むため、上限を大きく取っても速い CLI の待ち時間は増えません。上書きは `--timeout` で行います：

```bash
# 上限を延ばす（既定: 900秒）
bash scripts/multi-review.sh --timeout 1800

# 短く切り上げる（例: 手早く様子を見たいとき）
bash scripts/multi-review.sh --timeout 180
```

> `REVIEW_TIMEOUT` 環境変数はアダプタを直叩きする場合の既定値にしか効きません。`multi-review.sh` / `multi-agent.sh` は常に `--timeout` をアダプタへ明示的に渡すため、この経路では無視されます。

### CLI がタイムアウト・異常終了したとき

そのタスクは**失敗として報告され、別 CLI での自動再実行は行われません**（実行時 fallback は意図的に持たせていない）。

- 理由: 同じ差分を別のモデルに見せることがこの仕組みの目的なので、黙って差し替えるとレポート上は観点が埋まって見えるのに実際に見たモデルが変わる。代替先はコスト帯が上がる場合がある（`codex-cli` → `claude-code` は standard → premium）。タイムアウト後の再試行は同じ制限時間をもう一度消費するだけになりやすい。
- 打ち切り前に得られた部分出力は捨てず、`Status: incomplete` 付きの結果ファイルとして保存し、統合レポートにも `INCOMPLETE` バナーを出します。**未完了の節は「指摘なし」ではなく「未確認」と読むこと。**
- 失敗サマリーが 2 つの再実行コマンド（同じ CLI に時間を足す／設定上の代替 CLI を明示実行する）を出力するので、選んで実行します。

同一の task・CLI・base・HEAD・perspective 集合・設定・レビュー diff で未完了観点だけを再実行する場合は `--resume` を使う。成功済み結果は `.review-results/.resume-cache/` から内容 hash を検証して再利用され、欠落・破損・入力不一致は再実行へ倒れる。timeout は identity に含まれないため、失敗後に延長して再開できる。統合レポートの各節には `reused` / `executed` が表示される。

```bash
# 例: 同じ CLI に時間を足して再実行
bash scripts/multi-agent.sh --task review --resume --timeout 1800

# 例: 代替 CLI を自分の判断で明示実行
bash scripts/multi-agent.sh --task review --cli claude-code --perspective code-review
```

### CLI が非インタラクティブモードでハングするとき

`-p` / `--print` 系の非インタラクティブモードでハングする CLI があります（Cursor CLI がそうで、issue #240 でラインナップから外した理由の 1 つ）。

**回避策**:

- 必ずアダプタ経由で実行する。アダプタは自前のウォッチドッグで待つので、`timeout(1)` を持たないホスト（stock macOS）でも期限で打ち切れる。手元で `timeout 120 <cli> ...` とラップする方法は使えない
- その CLI をスキップして別 CLI に振る: `--cli codex-cli` など

### 結果の不整合

Cross-Modelモードで異なるCLIが矛盾する結果を返した場合：

- 信頼度スコアが高い方を優先
- Critical/Warning は両方報告（安全側に倒す）
- Suggestion/Info は重複除去

---

## 関連ドキュメント

- [REVIEW_AGENT_CREATION_GUIDE.md](../../06-reference/REVIEW_AGENT_CREATION_GUIDE.md) — 汎用レビューエージェント作成ガイド
- [ai-tools-integration.md](./ai-tools-integration.md) — AIツール統合・コスト比較
- [git-workflow.md](./git-workflow.md) — AI駆動Git Workflow
- [grok-cli-reviewer.md](./grok-cli-reviewer.md) — Grok CLI セットアップ
- [COPILOT_AGENTS.md](../../06-reference/COPILOT_AGENTS.md) — Copilot エージェント定義（従量課金・オプトイン）
