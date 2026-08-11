# Review Agent Creation Guide

> **Parent**: [COPILOT_AGENTS.md](./COPILOT_AGENTS.md) | [ai-tools-integration.md](../05-operations/deployment/ai-tools-integration.md)

## 概要

任意のAI CLIツールをレビューエージェントにラップするための汎用ガイドです。特定のCLIに依存しない「レビューエージェントの構成要素」を定義し、複数のAI CLI（Claude Code、Codex、Gemini、Copilot など）を統一的にオーケストレーションするための設計パターンを提供します。

> **Note**: GitHub Copilot CLI は従量課金へ移行したため、レビューの既定ラインナップから除外しています（アダプタは残置、オプトイン利用可）。

**対象読者**: AI CLIツールを活用してコードレビューを自動化・効率化したい開発者

---

## 目次

- [1. Review Agent Anatomy](#1-review-agent-anatomy)
- [2. Perspective Catalog](#2-perspective-catalog)
- [3. Adapter Pattern](#3-adapter-pattern)
- [4. Severity Classification Standard](#4-severity-classification-standard)
- [5. Output Format Standard](#5-output-format-standard)
- [6. Cross-Model Review Pattern](#6-cross-model-review-pattern)
- [7. AI消費分散戦略](#7-ai消費分散戦略)
- [8. Multi-Entry Point](#8-multi-entry-point)
- [9. Integration Checklist](#9-integration-checklist)

---

## 1. Review Agent Anatomy

レビューエージェントは以下の4要素で構成されます：

```
┌─────────────────────────────────────────┐
│           Review Agent                   │
├─────────────────────────────────────────┤
│  1. Perspective（観点）                   │
│     - 何を分析するか                      │
│     - 分析の深度とスコープ                 │
├─────────────────────────────────────────┤
│  2. Severity Model（重大度モデル）         │
│     - Critical / Warning / Suggestion    │
│     - PR Review Response Policy連携      │
├─────────────────────────────────────────┤
│  3. Output Format（出力形式）             │
│     - 統一Markdownテンプレート            │
│     - 機械可読セクション                   │
├─────────────────────────────────────────┤
│  4. CLI Adapter（CLIアダプター）          │
│     - CLI固有のフラグ・実行方法            │
│     - プロンプト注入・結果パース            │
└─────────────────────────────────────────┘
```

### 要素間の関係

1. **Perspective** がエージェントの「何を見るか」を定義
2. **Severity Model** が発見した問題の「重要度」を統一基準で分類
3. **Output Format** が結果の「どう報告するか」を標準化
4. **CLI Adapter** が「どのツールで実行するか」を抽象化

この分離により、同じPerspectiveを異なるCLIで実行でき、結果を統一的に比較・集約できます。

---

## 2. Perspective Catalog

7つの標準パースペクティブを定義します。各パースペクティブはツール非依存のプロンプトとして `scripts/perspectives/` に配置します。

### 一覧

| #   | Perspective              | 分析対象                               | 推奨CLI     | 理由                             |
| --- | ------------------------ | -------------------------------------- | ----------- | -------------------------------- |
| 1   | **Code Review**          | コード品質、ガイドライン準拠、バグ検出 | Codex       | 汎用レビューはGPT系で別視点      |
| 2   | **Error Handler Hunt**   | サイレント失敗、不適切なcatch          | Grok        | 一般レビューと別モデルの目を当てる |
| 3   | **Security Analysis**    | 脆弱性、インジェクション、認証問題     | Gemini      | 無料枠＋長コンテキスト活用       |
| 4   | **Test Analysis**        | テストカバレッジ、エッジケース不足     | Codex       | クロスモデルでテスト網羅性を検証 |
| 5   | **Type Design Analysis** | 型設計、カプセル化、不変性             | Claude Code | 最も高度な判断力が必要           |
| 6   | **Comment Analysis**     | コメント正確性、ドキュメント品質       | Gemini      | 無料枠で繰り返し実行             |
| 7   | **Code Simplification**  | 複雑性削減、リファクタリング提案       | Claude Code | 判断に設計文脈が要る             |

### パースペクティブファイル形式

各ファイルは以下の構造に従います（`scripts/perspectives/{name}.md`）：

```markdown
# Perspective: {Name}

## Role

[エージェントの役割と責任]

## Analysis Focus

[何を分析するか、具体的なチェック項目]

## Severity Classification

[このパースペクティブ固有の重大度基準]

## Output Template

[結果の出力テンプレート]
```

### Claude Code pr-review-toolkit との対応

| Perspective          | pr-review-toolkit サブエージェント | 担当CLI             |
| -------------------- | ---------------------------------- | ------------------- |
| Code Review          | code-reviewer                      | Codex CLI           |
| Error Handler Hunt   | silent-failure-hunter              | Grok CLI            |
| Security Analysis    | _(新規)_                           | Gemini CLI          |
| Test Analysis        | pr-test-analyzer                   | Codex CLI           |
| Type Design Analysis | type-design-analyzer               | Claude Code（据置） |
| Comment Analysis     | comment-analyzer                   | Gemini CLI          |
| Code Simplification  | code-simplifier                    | Claude Code         |

---

## 3. Adapter Pattern

任意のCLIをレビューエージェントにラップするアダプターパターンです。

### 共通インターフェース

```bash
# すべてのアダプターは同じインターフェースを持つ
adapter-{cli}.sh <perspective-file> <output-file> [--changed-files <file-list>]
```

### アダプターの責務

```
┌────────────────────────────────────────────────┐
│              Adapter Layer                      │
├────────────────────────────────────────────────┤
│  1. CLI存在確認    command -v {cli}             │
│  2. プロンプト構築  perspective + diff + context │
│  3. CLI実行        cli -p "..." [flags]         │
│  4. 出力パース     CLI固有の出力 → 統一形式      │
│  5. エラーハンドリング  タイムアウト、失敗時処理  │
└────────────────────────────────────────────────┘
```

### CLI別実行コマンド

| CLI         | コマンド       | 主要フラグ                                                  | 備考                                           |
| ----------- | -------------- | ----------------------------------------------------------- | ---------------------------------------------- |
| Claude Code | `claude`       | `-p "..." --allowed-tools "Read,Grep,Glob,Bash(git diff*)"` | ツール制限で安全性確保                         |
| Codex CLI   | `codex`        | `exec "..." --sandbox read-only`                            | 読み取り専用サンドボックス                     |
| Copilot CLI | `copilot`      | `-p "..." --silent --allow-all-tools`                       | `--silent`でstats出力抑制                      |
| Gemini CLI  | `gemini`       | `-p "..." --sandbox --output-format json`                   | サンドボックス＋JSON出力                       |
| Grok CLI    | `grok`         | `-p "..." --sandbox read-only --output-format plain`        | カーネル強制の read-only プロファイル          |

### アダプター実装の骨格

```bash
#!/usr/bin/env bash
# adapter-{cli}.sh — {CLI Name} Review Adapter

set -euo pipefail

PERSPECTIVE_FILE="$1"
OUTPUT_FILE="$2"
CHANGED_FILES="${3:-}"

# 1. CLI存在確認
if ! command -v {cli} &>/dev/null; then
  echo "ERROR: {cli} is not installed" >&2
  exit 1
fi

# 2. プロンプト構築
PERSPECTIVE_CONTENT=$(cat "$PERSPECTIVE_FILE")
DIFF_CONTENT=$(git diff --cached --diff-filter=ACMR)
PROMPT="$PERSPECTIVE_CONTENT

## Changed Files
$DIFF_CONTENT

## Instructions
Analyze the above changes according to the perspective.
Output in the standard review format."

# 3. CLI実行（CLI別に分岐が必要）
# プロンプトの渡し方は CLI ごとに違う。-p が使えるとは限らないし、意味も同じとは
# 限らないので、新しい CLI を足すときは必ず --help で確かめること。
# 例: claude -p "$PROMPT" / gemini -p "$PROMPT" / copilot -p "$PROMPT"
#     codex exec "$PROMPT"（codex の -p は --profile。プロンプトは positional 引数）
#
# ⚠ **stdin を必ず閉じる（`< /dev/null`）。** codex は stdin が TTY でないと
#   「追加入力」として読みに行き、EOF が来るまで戻らない。stdout には何も出ないので
#   外からはハングと区別がつかない（実測。長時間かけて「CLI が未応答」と誤診した
#   事例がある）。パイプ越しに呼ばれる pre-commit や CI では確実に踏む。
#   なお同梱の multi-agent.sh 経由なら、アダプタ側が閉じているので考えなくてよい —
#   自前ラッパーを書く場合だけの注意点。
#
# 失敗・タイムアウト時は、部分出力の先頭に未完了マーカーを付けて保存してから、
# CLI の終了コードそのままで非 0 終了する。マーカーが無いと、統合レポートの
# INCOMPLETE 検査（pre-push ゲート等）が空回りし、打ち切られたレビューが
# 「指摘なし」として通る（multi-cli-review-orchestration.md のゲート例を参照）。
# 1 行目の `<!-- Status: incomplete -->` は orchestrator（multi-agent.sh）が
# 機械判定するヘッダー契約（最初の空行より前・行頭・完全一致）。実装では
# adapter-common.sh の write_output を使うのが確実
if ! {cli} -p "$PROMPT" {flags} < /dev/null > "$OUTPUT_FILE" 2>&1; then
  rc=$?
  {
    echo "<!-- Status: incomplete -->"
    echo "## INCOMPLETE"
    echo "Status: incomplete — このレビューは完走していない（失敗 or タイムアウト）。以下は打ち切り前の部分出力。"
    echo
    cat "$OUTPUT_FILE"
  } > "${OUTPUT_FILE}.tmp"
  mv "${OUTPUT_FILE}.tmp" "$OUTPUT_FILE"
  exit "$rc"
fi

# 成功終了でも空出力は「完走したレビュー」ではない（認証失敗などを握って
# exit 0 する CLI がある）。空のまま通すと統合時に黙って消える
if [ ! -s "$OUTPUT_FILE" ]; then
  printf '<!-- Status: incomplete -->\n## INCOMPLETE\nStatus: incomplete — CLI は exit 0 だが出力が空（完走ではなく未確認）。\n' > "$OUTPUT_FILE"
  exit 1
fi

# 4. 出力パース（CLI固有の後処理）
# ...
```

### モデル指定は「既定値を持たない」

アダプターに**モデル slug の既定値を持たせてはいけない**。持たせると、その値の SSOT がユーザーの CLI 設定（`~/.codex/config.toml` など）とアダプターの 2 箇所に分裂し、**アダプター側が必ず古くなる**。しかもフラグを無条件に渡す実装だと、ユーザー設定を黙って上書きするうえ、同じ設定ファイル内の関連項目（reasoning effort など）は上書きされないため「古いモデル + 新しい付随設定」という誰も意図していない組み合わせで動く。

正しい形は「**env が設定されている時だけフラグを組み立て、未設定ならフラグ自体を渡さない**」。これで最新追従は CLI 自身の設定が担い、明示指定は env で効き、アダプターのメンテナンスはゼロになる。

```bash
# ❌ 悪い例 — 既定値を持ち、無条件に渡す
CODEX_MODEL="${CODEX_MODEL:-gpt-5.5}"       # ここが必ず古くなる
codex exec -m "$CODEX_MODEL" "$PROMPT"      # ユーザー設定を黙って上書きする

# ✅ 良い例 — env があるときだけフラグを組み立てる
MODEL_ARGS=()
[[ -n "${CODEX_MODEL:-}" ]] && MODEL_ARGS+=(-m "$CODEX_MODEL")
[[ -n "${CODEX_PROFILE:-}" ]] && MODEL_ARGS+=(-p "$CODEX_PROFILE")
codex exec "$PROMPT" ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} < /dev/null
```

注意点:

- **配列を使う**こと。文字列連結 + 非クォート展開だと、値に空白を含むモデル名が複数引数に割れる。この退化は「argv を `<%s>` 区切りで記録する stub」でしか検出できない（空白連結で記録すると、割れても同じ文字列に見える）
- **`${ARR[@]+"${ARR[@]}"}` の形で展開**すること。bash 3.2（macOS 既定）では `set -u` のもとで空配列を `"${ARR[@]}"` と展開すると `unbound variable` で落ちる
- 組み立てをヘルパー関数に切り出す場合、**末尾を `[[ 条件 ]] && 代入` で終わらせない**。条件が偽のとき関数の戻り値が 1 になり、`set -e` のもとで呼び出し側が落ちる。明示的に `return 0` で締めること
- **CLI が「その指定は無効です」と言ってくれるとは限らない**。たとえば codex は存在しないプロファイル名をエラーにせず base config のまま完走する（0.144.5 で実測）。設定が効いていないことを利用者が観測できない場合は、ラッパー側で事前に検証して落とす
- **同じ設定源を 2 つ同時に渡さない**。codex の `-m`（モデル）と `-p`（プロファイル）を併用すると `-m` が勝ち、reasoning effort だけプロファイル由来という不整合な組み合わせになる。排他にするか、片方を拒否する
- アダプターに書いてよいモデル値は「**ベンダー中立で世代交代しない語**」だけ（`auto` など）。具体的な slug は既定値としてもフォールバックとしても持たない
- 同種のアダプターが複数あるなら、着手前に**全部を横断確認**してパターンの不統一を洗い出す（片方だけ直すと次の腐敗が別ファイルで再発する）
- 委譲には代償がある — アダプターの表示が「実際に何を使ったか」を保証できなくなる。表示は「config 由来」と正直に書き、実使用値の記録が要る場合は CLI の出力（多くは stderr の起動バナー）から**観測値**を拾う。仮定を事実として表示しない

各 CLI の「安定した間接参照」は非対称なので、指定するなら slug 直書きより次を優先する:

| CLI | 安定した間接参照 |
| --- | ---------------- |
| Claude Code | `opus` / `sonnet` / `haiku` / `fable` — **最新版を指すエイリアス**なので自己更新する |
| Codex CLI | `-p/--profile <name>` — `~/.codex/<name>.config.toml` を base 設定に重ねる。モデルと reasoning effort を 1 ファイルで束ねられる |
| Copilot CLI | `auto` — ベンダー側に選ばせる |
| Grok CLI | 該当なし（フラグを渡さず CLI 設定へ委譲する） |
| Gemini CLI | 該当なし（フラグを渡さず CLI 設定へ委譲する） |

> 実害の記録: ラッパーが `CODEX_MODEL="${CODEX_MODEL:-gpt-5.4}"` のような既定値を持っていたため、ユーザーの CLI 設定（新しいモデル + `reasoning_effort` の指定）のうちモデルだけが黙って上書きされ、「古いモデル + 新しい付随設定」という誰も意図しない組み合わせでレビューが走っていた。参照実装は ff-dev-toolkit プラグイン側にあり（`scripts/adapters/adapter-common.sh` の `reset_model_args` / `add_model_arg` を全アダプタで共有）、同プラグインの `tests/no-hardcoded-model/`（slug の直書きが無いことの静的検査）と `tests/adapter-model-args/`（環境変数が実際に argv へ届くことの stub CLI 検査。ベンダー中立な既定値の扱いはヘルパー単体で固定している）が機械的に守っている。本テンプレートには含まれないので、コピー先で実装するときは上のパターンに従うこと。

---

## 4. Severity Classification Standard

全アダプター共通の重大度分類です。プロジェクトルートの `CLAUDE.md` に定義された PR Review Response Policy と連携します。

### 重大度レベル

| レベル         | 説明                                                     | 対応ポリシー                       |
| -------------- | -------------------------------------------------------- | ---------------------------------- |
| **Critical**   | セキュリティ脆弱性、データ損失、本番障害の可能性         | 必ず修正（確認不要で即対応）       |
| **Warning**    | バグの可能性、パフォーマンス問題、ベストプラクティス違反 | 必ず修正（確認不要で即対応）       |
| **Suggestion** | コード品質改善、リファクタリング提案                     | 実装が妥当なものは対応（確認不要） |
| **Info**       | 良いプラクティスの確認、参考情報                         | 確認のみ（対応不要）               |

### 信頼度スコア

各問題には信頼度スコア（0-100）を付与：

| スコア範囲 | 意味         | 報告                 |
| ---------- | ------------ | -------------------- |
| 80-100     | 高確度の問題 | 報告する             |
| 50-79      | 中程度の確度 | Suggestion以下で報告 |
| 0-49       | 低確度       | 報告しない           |

---

## 5. Output Format Standard

全アダプターが準拠するMarkdownテンプレートです。

### 統一出力テンプレート

```markdown
## {Perspective Name} Review Results

**Reviewer**: {CLI Name} ({Model Name})
**Date**: {ISO 8601}
**Scope**: {analyzed file count} files

---

### Critical Issues

- [{file}:{line}] {description}
  - **Severity**: Critical
  - **Confidence**: {score}/100
  - **Reason**: {why this is a problem}
  - **Fix**: {recommended fix}

### Warnings

- [{file}:{line}] {description}
  - **Severity**: Warning
  - **Confidence**: {score}/100
  - **Reason**: {reason}
  - **Fix**: {fix}

### Suggestions

- [{file}:{line}] {description}
  - **Severity**: Suggestion
  - **Confidence**: {score}/100
  - **Reason**: {reason}
  - **Fix**: {fix}

### Info / Good Practices

- [{file}:{line}] {description}

---

### Summary

| Severity   | Count   |
| ---------- | ------- |
| Critical   | {n}     |
| Warning    | {n}     |
| Suggestion | {n}     |
| Info       | {n}     |
| **Total**  | **{n}** |

### Verdict

{PASS | NEEDS_WORK | CRITICAL_BLOCK}
```

### 統合レポート

オーケストレーターは各CLIの結果を統合し、以下の形式で出力します：

```markdown
# Multi-CLI Review Report

**Date**: {date}
**Mode**: {distributed | cross-model}
**Strategy**: {balanced | minimize_cost | maximize_quality}

## Reviewers

| CLI   | Perspective   | Verdict   | Issues  |
| ----- | ------------- | --------- | ------- |
| {cli} | {perspective} | {verdict} | {count} |

## Consolidated Issues (Deduplicated)

### Critical ({total})

...

### Warnings ({total})

...

## Final Verdict

{PASS | NEEDS_WORK | CRITICAL_BLOCK}
```

---

## 6. Cross-Model Review Pattern

複数のAIモデルで相互補完するパターンです。

### パターン1: Distributed Review（分散レビュー）

各CLIが異なるパースペクティブを担当し、結果を統合します。

```
┌──────────┐  type-design   ┌──────────────────────┐
│ Claude   │◄──────────────►│ 型設計分析            │
└──────────┘                └──────────────────────┘
┌──────────┐  code-review   ┌──────────────────────┐
│ Codex    │◄──────────────►│ コードレビュー＋テスト │
└──────────┘  +test         └──────────────────────┘
┌──────────┐  security      ┌──────────────────────┐
│ Gemini   │◄──────────────►│ セキュリティ＋コメント │
└──────────┘  +comment      └──────────────────────┘
```

**利点**: 各CLIの得意分野を活かし、コストを最適化
**欠点**: 特定の観点が1つのモデルに依存

### パターン2: Cross-Model Review（クロスモデルレビュー）

全CLIで同じパースペクティブを実行し、結果を比較します。

```
                    code-review
┌──────────┐  ┌──────────┐  ┌──────────┐
│ Claude   │  │ Codex    │  │ Gemini   │
│ 結果A    │  │ 結果B    │  │ 結果C    │
└────┬─────┘  └────┬─────┘  └────┬─────┘
     └──────┬──────┴──────┬──────┘
            │   比較・統合   │
            └──────────────┘
```

**利点**: モデル間の盲点を相互補完、高い網羅性
**欠点**: コストが高い（全CLIでトークン消費）

### 推奨使い方

| 場面             | 推奨パターン                  |
| ---------------- | ----------------------------- |
| 通常の開発       | Distributed（コスト効率優先） |
| 重要なリリース前 | Cross-Model（品質優先）       |
| 新しいCLI導入時  | Cross-Modelで精度検証         |

---

## 7. AI消費分散戦略

### コストティア別の最適配置

```
┌─────────────────────────────────────────────────────────┐
│              AI Provider Cost/Rate Tiers                 │
├───────────┬──────────┬───────────┬───────────────────────┤
│ Tier      │ Provider │ Cost Model│ 適切な用途            │
├───────────┼──────────┼───────────┼───────────────────────┤
│ Premium   │ Claude   │ トークン課金│ 高度な分析（型設計、 │
│           │          │ (高価)     │ アーキテクチャ判断）  │
├───────────┼──────────┼───────────┼───────────────────────┤
│ Standard  │ Codex    │ トークン課金│ コードレビュー、      │
│           │          │ (中程度)   │ エラーハンドリング    │
├───────────┼──────────┼───────────┼───────────────────────┤
│ Metered   │ Copilot  │ 従量課金   │ レビュー既定外        │
│           │          │(premium req)│（オプトインのみ）    │
├───────────┼──────────┼───────────┼───────────────────────┤
│ Free-tier │ Gemini   │ 無料枠大   │ セキュリティスキャン、│
│           │          │            │ ドキュメント分析      │
└───────────┴──────────┴───────────┴───────────────────────┘
```

### 分散戦略

| 戦略                 | 説明                                 | 適用場面                 |
| -------------------- | ------------------------------------ | ------------------------ |
| **balanced**         | コストと品質のバランス（デフォルト） | 通常の開発               |
| **minimize_cost**    | 固定料金/無料CLIを優先               | 予算制約がある場合       |
| **maximize_quality** | 最も高品質なCLIに多く割当            | リリース前の最終レビュー |

### Graceful Degradation（フォールバック）

CLIが未インストールの場合、パースペクティブを他のCLIに再分配します：

```yaml
fallback:
  claude-code: codex-cli # Claude不可 → Codexへ
  codex-cli: claude-code # Codex不可 → Claudeへ（クロスモデル維持）
  copilot-cli: codex-cli # Copilot不可 → Codexへ
  gemini-cli: codex-cli # Gemini不可 → Codexへ
  grok-cli: gemini-cli  # Grok不可 → Gemini（無料枠）へ
```

**フォールバック優先順位の設計思想**:

- 標準の2本柱（Claude / Codex）は相互にフォールバックし、クロスモデル性を維持する
- その他のCLIが不可 → 対応表の次のCLIへ。定額制のCLIは無料枠を先に見る（コスト最小化戦略の意図を保つため）
- **対応表の経路が尽きたら、導入済みのCLIから選び直す**。対応表は相互参照を含むので、経路をたどるだけでは行き止まりが残る（実測: あるCLIだけを導入した構成で 7 観点中 1 つしか計画されなかった）。観点を落とすくらいなら、対応表に無いCLIで見てもらう方がよい
- 従量課金のCLI（Copilot）へは最後の砦としてもフォールバックしない。利用者が求めていない課金が発生するため

**この対応表はプラン構築時（未インストール）専用**:

インストール済みの CLI が**実行時**にエラー・タイムアウトした場合、この表に従って別 CLI で再実行することはしません。そのタスクを失敗として報告し、非 0 で終了します。

- 理由: 同じ差分を別のモデルに見せることがこの仕組みの目的なので、黙って差し替えるとレポート上は観点が埋まって見えるのに実際に見たモデルが変わる。代替先はコスト帯が上がる場合がある（standard → premium）。タイムアウト後の再試行は同じ制限時間をもう一度消費するだけになりやすい。
- 代わりに、打ち切り前の部分出力を `Status: incomplete` 付きで保存し、失敗サマリーが終了コードに応じた再実行コマンドを出力する。新しいエージェントを追加するときも、実行時失敗を握って別 CLI に流す実装は入れないこと。

---

## 8. Multi-Entry Point

オーケストレーターはスタンドアロンbashスクリプトとして実装し、どこからでも呼び出せる設計です。

### エントリーポイント一覧

| 呼び出し元      | 方法             | 例                                                             |
| --------------- | ---------------- | -------------------------------------------------------------- |
| **ターミナル**  | 直接実行         | `bash scripts/multi-review.sh`                                 |
| **Claude Code** | Bash tool / hook | `bash scripts/multi-review.sh`                                 |
| **Copilot CLI** | プロンプト経由   | `copilot -p "bash scripts/multi-review.sh を実行して"`         |
| **CI/CD**       | GitHub Actions   | `- run: bash scripts/multi-review.sh --strategy minimize_cost` |
| **Husky**       | pre-push hook    | `.husky/pre-push` から呼び出し                                 |

### CLI インターフェース

```bash
bash scripts/multi-review.sh [options]
  --config <path>         設定ファイル（デフォルト: scripts/review-config.yaml）
  --mode <distributed|cross-model>
  --strategy <balanced|minimize_cost|maximize_quality>
  --cli <name>            特定CLIのみ実行（複数指定可）
  --perspective <name>    特定パースペクティブのみ
  --parallel              並列実行（デフォルト）
  --sequential            順次実行
  --output-dir <dir>      出力先（デフォルト: .review-results/）
```

### 使用例

```bash
# デフォルト（全CLI、分散モード、balanced戦略）
bash scripts/multi-review.sh

# コスト最小化モード
bash scripts/multi-review.sh --strategy minimize_cost

# 特定CLIのみ（標準の2本柱）
bash scripts/multi-review.sh --cli claude-code --cli codex-cli

# クロスモデル比較
bash scripts/multi-review.sh --mode cross-model --perspective code-review
```

---

## 9. Integration Checklist

新しいAI CLIをレビューエージェントとして追加する手順です。

### Step 1: CLI調査

- [ ] CLIの非インタラクティブ実行フラグを確認（`-p` / `--prompt` 等）
- [ ] サンドボックス/読み取り専用モードの有無を確認
- [ ] 出力形式の制御方法を確認（`--output-format` 等）
- [ ] ツール承認の自動化方法を確認（`--yolo` / `--approval-policy` 等）
- [ ] 既知の制限・バグを確認

### Step 2: アダプター作成

- [ ] `scripts/adapters/adapter-{cli}.sh` を作成
- [ ] 共通インターフェース（`<perspective-file> <output-file> [--changed-files]`）に準拠
- [ ] CLI存在確認（`command -v`）を実装
- [ ] プロンプト構築ロジックを実装
- [ ] 出力パースを実装（CLI固有 → 統一形式）
- [ ] タイムアウト処理を実装
- [ ] 失敗・打ち切り時に部分出力へ未完了マーカー（1 行目に `<!-- Status: incomplete -->`、続けて `## INCOMPLETE` バナー）を付けて保存し、非 0 で終了する処理を実装（無いと orchestrator の機械判定と消費側の INCOMPLETE 検査が空回りする）

### Step 3: 設定追加

- [ ] `scripts/review-config.yaml` に新CLIエントリを追加
- [ ] `cost_tier` を設定
- [ ] `default_perspectives` を設定
- [ ] `fallback` マッピングを更新

### Step 4: ドキュメント更新

- [ ] `ai-tools-integration.md` の比較テーブルに追加
- [ ] CLI固有のセットアップガイドを作成（`{cli}-reviewer.md`）
- [ ] `COPILOT_AGENTS.md` の対応表を更新（該当する場合）

### Step 5: テスト

- [ ] 単体テスト: アダプターが正しく動作するか
- [ ] 統合テスト: オーケストレーターから呼び出せるか
- [ ] フォールバックテスト: CLI未インストール時に再分配されるか

---

## 関連ドキュメント

- [COPILOT_AGENTS.md](./COPILOT_AGENTS.md) — GitHub Copilot エージェント定義
- [ai-tools-integration.md](../05-operations/deployment/ai-tools-integration.md) — AIツール統合ガイド
- [multi-cli-review-orchestration.md](../05-operations/deployment/multi-cli-review-orchestration.md) — オーケストレーション運用ガイド
- [gemini-cli-reviewer.md](../05-operations/deployment/gemini-cli-reviewer.md) — Gemini CLI セットアップ
- [git-workflow.md](../05-operations/deployment/git-workflow.md) — AI駆動Git Workflow
