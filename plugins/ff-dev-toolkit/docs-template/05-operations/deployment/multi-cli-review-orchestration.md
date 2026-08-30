# Multi-CLI Review Orchestration

> **Parent**: [DEPLOYMENT.md](../DEPLOYMENT.md) | [ai-tools-integration.md](./ai-tools-integration.md)

## 概要

複数のAI CLI（Claude Code、Codex、Copilot、Grok）をレビュワーとしてオーケストレーションし、設定駆動で統一的に管理する運用ガイドです。

**目的**: 各CLIの得意分野とコスト特性を活かし、高品質かつコスト効率の良いコードレビューを実現する

> **標準レビュー体制**: 一次レビューは Claude Code（pr-review-toolkit）、クロスモデルレビューは Codex CLI の2本柱が標準です。GitHub Copilot（Copilot CLI / Copilot code review）は従量課金への移行に伴い**既定のレビューラインナップから除外**しました（アダプタは残置、`--cli copilot-cli` でオプトイン可能）。

---

## 目次

- [ff-dev-toolkit plugin root の固定（必須）](#ff-dev-toolkit-plugin-root-prerequisite)
- [アーキテクチャ](#アーキテクチャ)
- [前提条件](#前提条件)
- [セットアップ](#セットアップ)
- [設定カスタマイズ](#設定カスタマイズ)
- [ワークフロー統合](#ワークフロー統合)
- [運用コマンド](#運用コマンド)
- [トラブルシューティング](#トラブルシューティング)

---

<a id="ff-dev-toolkit-plugin-root-prerequisite"></a>

## ff-dev-toolkit plugin root の固定（必須）

この文書は消費プロジェクトへコピーされる一方、`setup-multi-agent.sh` / `multi-agent.sh` / `multi-review.sh` は plugin 同梱物のままで、消費プロジェクトの `scripts/` へはコピーされない。Claude Code ではその呼び出しでホストが渡した `${CLAUDE_PLUGIN_ROOT}`、Codex など他ホストでは実際に読み込んだ ff-dev-toolkit skill の絶対 `SKILL.md` パスを `FF_DEV_TOOLKIT_SKILL_FILE` として渡し、その `../..` を、1回の Bash tool 呼び出し / shell script body 中の `FF_DEV_TOOLKIT_ROOT` として一度だけ固定する。この変数名と handoff は各 ff-dev-toolkit skill の root 契約にも定義する。review / explore / implement のどの入口でも、別の skill を探さず、その呼び出しで読み込んだ実体を使う。

handoff の producer は skill を実行する AI host である。Claude Code は plugin skill 呼び出しの `${CLAUDE_PLUGIN_ROOT}` を同じ Bash tool body へ渡す。Codex など、skill loader が読み込んだファイルの絶対パスを返す host は、Bash tool body の先頭で `FF_DEV_TOOLKIT_SKILL_FILE="<skill loader が返したこの SKILL.md の絶対パス>"; export FF_DEV_TOOLKIT_SKILL_FILE` の placeholder を実値へ置換する。review / explore / implement resource を直接呼ぶ host は、task の workspace repository root も `FF_DEV_TOOLKIT_PROJECT_ROOT="<AI host の task workspace repository root>"; export FF_DEV_TOOLKIT_PROJECT_ROOT` の実値として渡し、下の fence と後続コマンドを続ける。単独ターミナルの利用者が cache path や別 repository を推測してこれらの値を手書きしてはならない。

キャッシュ全体を探索したり、version 名を並べ替えて別版へ切り替えたりしない。次の resolver + guard を、以下に続く直接実行例より前に同じ shell へ読み込む。Claude Code / Codex の host は、上記の値をこの fence の実行環境へ渡すこと。初回 setup は読み込み済み skill を持つ Claude Code / Codex の host セッションからだけ実行する。単独ターミナルで setup 前の状態から plugin を探索する手順は提供しない。setup 後の単独ターミナルは Codex-only 互換シムを使い、固定版の pair / distributed review は skill を再呼び出して実行する。machine-local sidecar の手動 source は対話ターミナル向けに提供せず、後述の永続 hook の handoff にだけ使う。root が未設定、または更新で resource が消えた場合は別版へフォールバックせず status 2 を返す。

このresolver + guard fenceの対象は、ここから直接呼ぶreview系3 resourceと、Git Workflowの手動検査から呼ぶ `check-closing-keywords.sh` である。消費プロジェクトへ配置済みの後方互換 `scripts/codex-review.sh` はこの契約の例外で、`FF_DEV_TOOLKIT_ROOT` 未指定時は Codex cache → Claude cache の semantic version 最大を sidecar より先に選ぶ（Issue #623 の互換動作）。そのため plugin 更新直後は、端末の互換シムが新 cache、pre-push が更新前の sidecar を使う状態がある。固定版の pair / distributed review にはシムを使わず、更新後は setup をすぐ再実行して hook の sidecar も同じ版へ更新する。Codex-only の旧入口として使う場合はシム側の診断と再セットアップ案内に従う。

```bash
ff_canonical_toolkit_root() {
  local candidate="$1"
  (cd -P -- "$candidate" 2>/dev/null && pwd -P)
}

ff_toolkit_handoff_error() {
  unset FF_DEV_TOOLKIT_ROOT FF_DEV_TOOLKIT_ROOT_SOURCE
  printf 'ff-dev-toolkitのhandoffを再構成してください（%s）\n' "$1" >&2
  return 2
}

ff_has_toolkit_manifest_marker() {
  awk '
    BEGIN { after_open = 0; matched = 0 }
    !after_open && /^[[:space:]]*{[[:space:]]*$/ { after_open = 1; next }
    after_open && /^[[:space:]]*$/ { next }
    after_open && /^[[:space:]]*"name"[[:space:]]*:[[:space:]]*"ff-dev-toolkit"[[:space:]]*,[[:space:]]*$/ {
      matched = 1
      exit
    }
    after_open { exit }
    END { if (!matched) exit 1 }
  ' "$1"
}

ff_require_toolkit_root() {
  local host_root="" skill_root="" fixed_root=""
  local skill_dir="" skills_dir="" plugin_manifest=""
  local resource resource_path resource_error
  case "${CLAUDE_PLUGIN_ROOT:-}" in
    /*)
      host_root="$(ff_canonical_toolkit_root "$CLAUDE_PLUGIN_ROOT")" || {
        ff_toolkit_handoff_error "Claude plugin rootを正規化できません"
        return "$?"
      }
      ;;
    "") ;;
    *)
      ff_toolkit_handoff_error "Claude plugin rootが絶対pathではありません"
      return "$?"
      ;;
  esac
  if [ -n "${FF_DEV_TOOLKIT_SKILL_FILE:-}" ]; then
    case "$FF_DEV_TOOLKIT_SKILL_FILE" in
      /*) ;;
      *)
        ff_toolkit_handoff_error "読み込み済みSKILL.mdが絶対pathではありません"
        return "$?"
        ;;
    esac
    if [ ! -f "$FF_DEV_TOOLKIT_SKILL_FILE" ] || [ -L "$FF_DEV_TOOLKIT_SKILL_FILE" ]; then
      ff_toolkit_handoff_error "読み込み済みSKILL.mdが通常ファイルではないかsymlinkです"
      return "$?"
    fi
    skill_dir="$(dirname "$FF_DEV_TOOLKIT_SKILL_FILE")"
    skills_dir="$(dirname "$skill_dir")"
    if [ "$(basename "$FF_DEV_TOOLKIT_SKILL_FILE")" != SKILL.md ] \
      || [ "$(basename "$skills_dir")" != skills ]; then
      ff_toolkit_handoff_error "読み込み済みファイルが<plugin-root>/skills/<skill>/SKILL.md形式ではありません"
      return "$?"
    fi
    skill_root="$(cd "$skills_dir/.." && pwd -P)" || {
      ff_toolkit_handoff_error "SKILL.mdからplugin rootを解決できません"
      return "$?"
    }
    if [ -n "$host_root" ] && [ "$host_root" != "$skill_root" ]; then
      ff_toolkit_handoff_error "hostのplugin rootが一致しません"
      return "$?"
    fi
    host_root="$skill_root"
  fi
  if [ -n "${FF_DEV_TOOLKIT_ROOT:-}" ]; then
    case "$FF_DEV_TOOLKIT_ROOT" in
      /*) ;;
      *)
        ff_toolkit_handoff_error "固定rootが絶対pathではありません"
        return "$?"
        ;;
    esac
    fixed_root="$(ff_canonical_toolkit_root "$FF_DEV_TOOLKIT_ROOT")" || {
      ff_toolkit_handoff_error "固定rootを正規化できません"
      return "$?"
    }
  fi
  if [ -z "$host_root" ]; then
    ff_toolkit_handoff_error "読み込み元を解決できません"
    return "$?"
  fi
  if [ -n "$fixed_root" ] && [ "$fixed_root" != "$host_root" ]; then
    ff_toolkit_handoff_error "固定rootがhostの実体と一致しません"
    return "$?"
  fi
  if [ ! -d "${host_root}/scripts" ] || [ -L "${host_root}/scripts" ]; then
    ff_toolkit_handoff_error "scripts directoryが通常directoryではないかsymlinkです"
    return "$?"
  fi
  plugin_manifest="${host_root}/.claude-plugin/plugin.json"
  if [ -L "${host_root}/.claude-plugin" ] \
    || [ ! -f "$plugin_manifest" ] || [ -L "$plugin_manifest" ] \
    || [ ! -r "$plugin_manifest" ] || [ ! -s "$plugin_manifest" ] \
    || ! ff_has_toolkit_manifest_marker "$plugin_manifest"; then
    ff_toolkit_handoff_error "ff-dev-toolkitのmanifest name markerを確認できません"
    return "$?"
  fi
  for resource in setup-multi-agent.sh multi-agent.sh multi-review.sh check-closing-keywords.sh; do
    resource_path="${host_root}/scripts/${resource}"
    resource_error=""
    if [ ! -f "$resource_path" ]; then
      resource_error="regular fileではありません"
    elif [ -L "$resource_path" ]; then
      resource_error="symlinkは許可されません"
    elif [ ! -r "$resource_path" ]; then
      resource_error="読み取れません"
    elif [ ! -s "$resource_path" ]; then
      resource_error="0バイトです"
    fi
    if [ -n "$resource_error" ]; then
      ff_toolkit_handoff_error "resourceを解決できません: ${resource_path} (${resource_error})"
      return "$?"
    fi
  done
  # 候補とresourceが全て正常だと確定してから、rootと診断用の出自を同時に公開する。
  # 失敗候補をsource元に残さず、更新後の再呼び出しで復旧できるようにする。
  FF_DEV_TOOLKIT_ROOT="$host_root"
  FF_DEV_TOOLKIT_ROOT_SOURCE=host
  export FF_DEV_TOOLKIT_ROOT FF_DEV_TOOLKIT_ROOT_SOURCE
}

ff_require_consumer_root() {
  local expected_root actual_root git_root
  case "${FF_DEV_TOOLKIT_PROJECT_ROOT:-}" in
    /*) ;;
    "")
      printf 'AI hostからFF_DEV_TOOLKIT_PROJECT_ROOTを渡してreview入口を再実行してください（consumer repository root handoffが未設定です）\n' >&2
      return 2
      ;;
    *)
      printf 'AI hostからFF_DEV_TOOLKIT_PROJECT_ROOTを絶対pathで渡してreview入口を再実行してください（consumer repository root handoffが絶対pathではありません）\n' >&2
      return 2
      ;;
  esac
  expected_root="$(cd -P -- "$FF_DEV_TOOLKIT_PROJECT_ROOT" 2>/dev/null && pwd -P)" || {
    printf 'review対象をtask workspace repository rootで再実行してください（consumer repository rootを正規化できません）\n' >&2
    return 2
  }
  actual_root="$(pwd -P)" || {
    printf 'review対象をtask workspace repository rootで再実行してください（現在の作業directoryを正規化できません）\n' >&2
    return 2
  }
  git_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    printf 'review対象をtask workspace repository rootで再実行してください（consumer repositoryを解決できません）\n' >&2
    return 2
  }
  git_root="$(cd -P -- "$git_root" 2>/dev/null && pwd -P)" || {
    printf 'review対象をtask workspace repository rootで再実行してください（consumer repositoryを正規化できません）\n' >&2
    return 2
  }
  if [ "$actual_root" != "$expected_root" ] || [ "$git_root" != "$expected_root" ]; then
    printf 'review対象をtask workspace repository rootで再実行してください（review対象がhostのtask workspace repository rootと一致しません）\n' >&2
    return 2
  fi
}

ff_require_toolkit_root
```

この fence 自体が resolver 本体であり、`./resolver.sh` という別ファイルは作らない。AI host は fence 全体と後続コマンドを同じ shell script body として実行する。fence 末尾の呼び出しは `exit` ではなく関数の status 2 を返す。`set -e` 下で実行する場合は fence の直前で一時的に `set +e`、直後に `ff_root_rc=$?` とし、元がerrexit有効だった場合だけ `set -e` へ戻す。status 0 を確認した同じ shell でのみ後続の直接実行例へ進む。

すべての直接実行例は、レビュー対象である**消費プロジェクトの repository root**で実行する。`ff_require_consumer_root` は host が渡した task workspace repository root、現在の物理 CWD、`git rev-parse --show-toplevel` の3値が一致する場合だけ通す。plugin script は絶対 path で起動できるため、この照合が無いと別 repository や repository 外で実行しても path error にはならず、その CWD を対象にしてしまう。

guard は bundled manifest の先頭 `name` marker、通常 directory の `scripts/`、各 resource の `-f/-r/-s` と非 symlink を要求する。manifest marker は誤った plugin root の混入を検出する配布構造チェックであり、JSON 全体の妥当性検証や暗号学的な真正性確認ではない。すべて `bash` へ明示的に渡す入口なので実行 bit は前提にしない。欠落・空ファイル・symlink・marker 不一致は cache を手修正せず、plugin を再導入してから skill / setup を再実行する。

`FF_DEV_TOOLKIT_ROOT_SOURCE` は診断時にhandoff経路を識別するためのprovenanceであり、resource選択やfallbackの分岐には使わない。

長期運用する hook / CI は skill 呼び出しとは別のタイミング・プロセスで動くため、skill セッション中だけの環境変数に依存しない。上の対話用 resolver fence は呼ばず、後述する各例の自己完結 bootstrap + resource guard を使う。hook では setup が生成した machine-local sidecar を handoff として使い、toolkit 更新後に setup を再実行して明示的に差し替える。sidecar は Git 管理せず、versioned cache を探索・選択する設定として手書きしない。対話ターミナルではこの sidecar スニペットを source せず、固定版レビューは skill から再実行する。CI は project が pin して配置した実体を `FF_DEV_TOOLKIT_ROOT_SOURCE=ci` とともに固定する。

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
ff_require_toolkit_root && ff_require_consumer_root && bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh" --mode cross-model --cli codex-cli
# scripts/codex-review.sh は multi-agent.sh へ委譲するシムとして同梱される
# 生成シムはCodex-only互換入口であり、このcross-model実行とはmode・担当範囲が異なる
```

commit 前の対話実行で staged index だけをレビューする場合は次を使う。pre-commit hook に組み込む場合は、[Husky pre-push フックとの統合](#husky-pre-push-フックとの統合)と同じ sidecar 復元・resource guard を先に置く。

```bash
ff_require_toolkit_root && ff_require_consumer_root && bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh" --staged
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
                    │  │  agent-config.yaml    │  │
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
2. **設定読み込み** → `--config`、`$MULTI_AGENT_CONFIG`、project `.claude/agent-config.yaml`、plugin `agent-config.yaml` の順で設定を取得。plugin `agent-config.yaml` が欠落した旧配布物だけは、同じplugin rootの非推奨 `review-config.yaml` を互換fallbackとして読む
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
  - Homebrew が無い場合: 同梱の `bash "${FF_DEV_TOOLKIT_ROOT}/scripts/setup-multi-agent.sh"` が [mikefarah/yq](https://github.com/mikefarah/yq) の GitHub release から公式バイナリを導入する（`curl` または `wget` が必要。配置先は既定で `~/.local/bin`。PATH に無い場合は shell profile へ追加する）
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

### Step 1: plugin resource の確認

```bash
# 上の resolver + guard を通した同じ shell で実行する。
ff_require_toolkit_root && echo "ff-dev-toolkit plugin resources: OK"
```

### Step 2: 設定ファイルのカスタマイズ

消費プロジェクトの `.claude/agent-config.yaml` を環境に合わせて編集します。初期設定が必要な場合は `${FF_DEV_TOOLKIT_ROOT}/scripts/agent-config.yaml` を雛形として使います。

> **Note**: 現行の `multi-agent.sh` が project config から読み込むのは `version` / `mode` / `parallel` / `review.*` と、`version: "2.0"` のときだけ `tasks.<task>.{mode,cost_strategy,timeout,output_dir}`。`version` が `2.0` でない場合は v1 形式としてトップレベルの `cost_strategy` / `timeout` / `output_dir` を読む。`agents` / `fallback` は配布側レジストリの写しであり、消費プロジェクトで変更しても実行へ反映されない。パースペクティブ割り当てを変える場合は plugin 側の変更として提案し、cache を直接編集しない。

```yaml
version: "2.0"
mode: distributed
parallel: true

tasks:
  review:
    cost_strategy: balanced
```

CLI名・cost tier・perspective・fallback の対応表は plugin 同梱設定を参照する。これらを変更する場合は `multi-agent.sh` の実行時レジストリと配布mirrorを同じ plugin PRで更新し、消費プロジェクト設定へは複製しない。

### Step 3: 動作確認

```bash
# 利用可能なCLIと設定を表示
ff_require_toolkit_root && ff_require_consumer_root && bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh" --dry-run

# 特定のCLIだけでテスト
ff_require_toolkit_root && ff_require_consumer_root && bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh" --cli codex-cli --perspective test-analysis
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

> **Note**: 以下は設定例です。先に読み込み済み skill の root から同梱 `setup-multi-agent.sh` を実行して `scripts/.ff-dev-toolkit-root` を生成し、`.husky/pre-push` ファイルを手動で作成してください。sidecar はマシン固有なので Git へコミットせず、消費プロジェクトの `.gitignore` へ `scripts/.ff-dev-toolkit-root` を追加して `git check-ignore scripts/.ff-dev-toolkit-root` で確認します。plugin 更新で記録先が消えた場合は、別 version を自動選択せず push を status 2 で止めるため、更新後の skill から setup を再実行します。

```bash
# .husky/pre-push（手動作成が必要）
#!/bin/sh
. "$(dirname "$0")/_/husky.sh"

# setup が記録した plugin の scripts/ 絶対pathから、別プロセスでも同じrootを復元する。
# versioned cache を探索して「最新」へ切り替えない。
FF_TOOLKIT_SCRIPTS=""
FF_TOOLKIT_SIDECAR=scripts/.ff-dev-toolkit-root
if [ -L "$FF_TOOLKIT_SIDECAR" ]; then
  echo "ff-dev-toolkit更新後にsetup-multi-agent.shを再実行してください（sidecar symlinkは許可されません）" >&2
  exit 2
fi
sidecar_tracked_rc=0
git ls-files --error-unmatch -- "$FF_TOOLKIT_SIDECAR" >/dev/null 2>&1 || sidecar_tracked_rc=$?
case "$sidecar_tracked_rc" in
  0) echo "ff-dev-toolkitのsidecarをGit管理から外してsetup-multi-agent.shを再実行してください" >&2; exit 2 ;;
  1) ;;
  *) echo "ff-dev-toolkitのsidecarがGit管理下か検査できません" >&2; exit 2 ;;
esac
if [ ! -r "$FF_TOOLKIT_SIDECAR" ] \
  || ! IFS= read -r FF_TOOLKIT_SCRIPTS < "$FF_TOOLKIT_SIDECAR"; then
  echo "ff-dev-toolkit更新後にsetup-multi-agent.shを再実行してください（sidecarを読み込めません）" >&2
  exit 2
fi
case "$FF_TOOLKIT_SCRIPTS" in
  /*/scripts) FF_DEV_TOOLKIT_ROOT="${FF_TOOLKIT_SCRIPTS%/scripts}" ;;
  *)
    echo "ff-dev-toolkit更新後にsetup-multi-agent.shを再実行してください（固定rootを解決できません）" >&2
    exit 2
    ;;
esac
if [ -L "$FF_TOOLKIT_SCRIPTS" ]; then
  echo "ff-dev-toolkit更新後にsetup-multi-agent.shを再実行してください（scripts symlinkは許可されません）" >&2
  exit 2
fi
FF_TOOLKIT_MANIFEST="${FF_TOOLKIT_SCRIPTS%/scripts}/.claude-plugin/plugin.json"
if [ -L "${FF_TOOLKIT_SCRIPTS%/scripts}/.claude-plugin" ] \
  || [ ! -f "$FF_TOOLKIT_MANIFEST" ] || [ -L "$FF_TOOLKIT_MANIFEST" ] \
  || [ ! -r "$FF_TOOLKIT_MANIFEST" ] || [ ! -s "$FF_TOOLKIT_MANIFEST" ] \
  || ! awk '
    BEGIN { after_open = 0; matched = 0 }
    !after_open && /^[[:space:]]*{[[:space:]]*$/ { after_open = 1; next }
    after_open && /^[[:space:]]*$/ { next }
    after_open && /^[[:space:]]*"name"[[:space:]]*:[[:space:]]*"ff-dev-toolkit"[[:space:]]*,[[:space:]]*$/ { matched = 1; exit }
    after_open { exit }
    END { if (!matched) exit 1 }
  ' "$FF_TOOLKIT_MANIFEST"; then
  echo "ff-dev-toolkit更新後にsetup-multi-agent.shを再実行してください（manifest name markerを確認できません）" >&2
  exit 2
fi
FF_DEV_TOOLKIT_ROOT_SOURCE=sidecar
export FF_DEV_TOOLKIT_ROOT FF_DEV_TOOLKIT_ROOT_SOURCE
for resource in setup-multi-agent.sh multi-agent.sh multi-review.sh; do
  if [ ! -f "${FF_DEV_TOOLKIT_ROOT}/scripts/${resource}" ] \
    || [ -L "${FF_DEV_TOOLKIT_ROOT}/scripts/${resource}" ] \
    || [ ! -r "${FF_DEV_TOOLKIT_ROOT}/scripts/${resource}" ] \
    || [ ! -s "${FF_DEV_TOOLKIT_ROOT}/scripts/${resource}" ]; then
    echo "ff-dev-toolkit更新後にsetup-multi-agent.shを再実行してください（resourceを解決できません）" >&2
    exit 2
  fi
done

# Multi-CLI レビュー（定額CLIのみ、高速）
# 終了コードを捨てないこと: レビューが 1 本でも失敗・タイムアウトすると非 0 になる
if ! FF_REVIEW_OUTPUT="$(mktemp -d "${TMPDIR:-/tmp}/ff-pre-push-review.XXXXXX")"; then
  echo "❌ 今回のレビュー専用出力先を作成できませんでした。" >&2
  exit 1
fi
REVIEW_REPORT="${FF_REVIEW_OUTPUT}/integrated-report.md"
if ! bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh" \
  --output-dir "$FF_REVIEW_OUTPUT" \
  --strategy minimize_cost \
  --cli grok-cli \
  --sequential; then
  echo "❌ レビューを完走できませんでした（失敗 or タイムアウト）。"
  echo "   未完了のレビューは「指摘なし」ではなく「未確認」です。ゲートとしては通せません。"
  echo "   出力先: $FF_REVIEW_OUTPUT"
  exit 1
fi

# 今回の専用出力先にある統合レポートだけを検査する。固定pathを読むと、今回の
# review が新しいレポートを生成しなかった場合に前回の成功レポートを誤読できる。
if [ ! -s "$REVIEW_REPORT" ]; then
  echo "❌ 統合レポートがありません。未生成は「指摘なし」ではなく「未確認」です。"
  echo "   出力先: $FF_REVIEW_OUTPUT"
  exit 1
fi

# 未完了の節が残っていればブロック（打ち切られたレビューは CRITICAL_BLOCK を
# 出さないので、CRITICAL_BLOCK だけを見るゲートは「空振り」を pass と読む）
grep_rc=0
grep -q "INCOMPLETE" "$REVIEW_REPORT" || grep_rc=$?
case "$grep_rc" in
  0)
    echo "❌ 未完了のレビュー結果が含まれています。再実行するか、対象を絞ってください。"
    echo "   レポート: $REVIEW_REPORT"
    exit 1
    ;;
  1) ;;
  *)
    echo "❌ 統合レポートのINCOMPLETE検査に失敗しました（grep status ${grep_rc}）。" >&2
    echo "   出力先: $FF_REVIEW_OUTPUT" >&2
    exit 1
    ;;
esac

# Critical があればプッシュをブロック（マーカー**全文**の固定文字列一致にする。
# 裸の CRITICAL_BLOCK への部分一致にしないこと — 連結されるレビュー本文が
# Verdict 語彙やマーカーの引用として同じ文字列を含むと、非ブロック観点だけの
# 実行でも誤発火し、観点別段階化が無効になる）
grep_rc=0
grep -qF -- '<!-- CRITICAL_BLOCK -->' "$REVIEW_REPORT" || grep_rc=$?
case "$grep_rc" in
  0)
    echo "❌ Critical issues found. Fix before pushing."
    echo "   レポート: $REVIEW_REPORT"
    exit 1
    ;;
  1) ;;
  *)
    echo "❌ 統合レポートのCritical検査に失敗しました（grep status ${grep_rc}）。" >&2
    echo "   出力先: $FF_REVIEW_OUTPUT" >&2
    exit 1
    ;;
esac
# Warning / Suggestion も対応判断と監査に必要なので、成功時も今回の専用出力を保全する。
echo "✅ レビュー完了。出力先: $FF_REVIEW_OUTPUT"
```

専用出力には差分やレビュー本文が含まれ得る。OS管理の一時領域なので永続保存は保証されず、確認後は表示された今回の絶対pathだけを削除する。別の一時directoryや固定pathをまとめて消さない。

> ⚠️ **ゲートを書くときの注意**: `bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh"` の終了コードを捨てて `CRITICAL_BLOCK` の有無だけで判定すると、レビューが 1 件も完走しなかった実行が「Critical なし = 合格」として通ります。これは Issue #152 の失敗モードがそのまま一層外側に出た形です。**終了コードと `INCOMPLETE` の両方**を見てください。

#### CRITICAL_BLOCK の観点別段階化

`<!-- CRITICAL_BLOCK -->` を立てるのは**ブロック観点**（既定では非ブロック名簿に載っていないすべての観点。同梱観点では code-review / security-analysis / error-handler-hunt / comprehensive-review）の Critical だけです。**非ブロック観点**（既定: comment-analysis / test-analysis / type-design-analysis / code-simplification）の Critical は、レポート本文には従来どおり Critical として現れますが、マーカーとしては `<!-- CRITICAL_NONBLOCK -->` の注記になり、それ単独では push ゲートを再発火させません（修正必須である点は変わりません — 次回の通常レビューまたは部分再検証で確認します）。

- 名簿は「格下げする観点」の列挙（denylist）です。載っていない観点 — 将来追加される観点や名簿の typo を含む — は従来どおりブロックします（fail closed）
- 上書きは env `MULTI_AGENT_CRITICAL_NONBLOCK_PERSPECTIVES`（空白またはカンマ区切り。**空文字の明示指定 = 全観点ブロック（旧挙動）**）> プロジェクト設定 `.claude/agent-config.yaml` の `review.critical_nonblock_perspectives`（1 文字列）> 既定、の順で解決されます
- ゲート側の判定は**マーカー全文**の固定文字列一致（`grep -qF -- '<!-- CRITICAL_BLOCK -->'`、上のゲート例）が正です。裸の `CRITICAL_BLOCK` への部分一致は使わないでください — 連結されるレビュー本文には Verdict 語彙やマーカーの引用として同じ文字列が現れうるため、非ブロック観点だけの実行でも誤発火します。なお本文がマーカー行そのものを逐語で引用した場合は全文一致でも発火します（誤ブロック側 = 安全側の残余）。`CRITICAL_NONBLOCK` のマーカー名・注記本文はどちらの判定式にも掛からない形が保たれており、`tests/multi-agent-critical-marker/` が固定しています

### fix ループの部分再検証（--reviewers 限定再実行）

全観点のフルレビューを 1 度通過した後の fix commit は、多くの場合、単一観点の指摘（例: comment-analysis の文言修正、error-handler-hunt の診断メッセージ改善）に閉じている。そのような fix の再検証は、修正が影響する観点だけの**部分再検証**でよい。fix のたびにフルゲート（全観点）を回し直すのは、時間とコストを消費するだけでなく、無関係な観点が毎回新しい低重要度の指摘を拾って fix ループが収束しなくなる原因にもなる。

```bash
# 例: comment-analysis の指摘だけを直した fix の再検証
ff_require_toolkit_root && ff_require_consumer_root && bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh" --perspective comment-analysis

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

commit pin、fork 境界、resource 検証を含む完全な workflow 例は、[Multi-CLI Review CI](./multi-cli-review-ci.md) を参照する。

---

## 運用コマンド

### 基本操作

```bash
# デフォルト実行（全CLI、分散モード）
ff_require_toolkit_root && ff_require_consumer_root && bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh"

# コスト最小化
ff_require_toolkit_root && ff_require_consumer_root && bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh" --strategy minimize_cost

# 品質最大化（リリース前）
ff_require_toolkit_root && ff_require_consumer_root && bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh" --strategy maximize_quality

# クロスモデル比較
ff_require_toolkit_root && ff_require_consumer_root && bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh" --mode cross-model --perspective code-review
```

### 特定CLI/パースペクティブのみ

```bash
# Claude + Codex だけ（標準の2本柱）
ff_require_toolkit_root && ff_require_consumer_root && bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh" --cli claude-code --cli codex-cli

# セキュリティ分析だけ
ff_require_toolkit_root && ff_require_consumer_root && bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh" --perspective security-analysis
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
ff_require_toolkit_root && ff_require_consumer_root && bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh" --cli claude-code --cli grok-cli
```

### タイムアウト

既定はレビュー 900 秒/CLI です（explore 600 秒・implement 900 秒）。CLI が先に応答すればその時点で次へ進むため、上限を大きく取っても速い CLI の待ち時間は増えません。上書きは `--timeout` で行います：

```bash
# 上限を延ばす（既定: 900秒）
ff_require_toolkit_root && ff_require_consumer_root && bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh" --timeout 1800

# 短く切り上げる（例: 手早く様子を見たいとき）
ff_require_toolkit_root && ff_require_consumer_root && bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh" --timeout 180
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
ff_require_toolkit_root && ff_require_consumer_root && bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-agent.sh" --task review --resume --timeout 1800

# 例: 代替 CLI を自分の判断で明示実行
ff_require_toolkit_root && ff_require_consumer_root && bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-agent.sh" --task review --cli claude-code --perspective code-review
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
