# Multi-CLI Agent Orchestration

## 概要

5つのAI CLI（Claude Code / Codex / Copilot / Gemini / Cursor）を統一オーケストレーターで並列実行し、**Review（レビュー）** / **Explore（探索）** / **Implement（実装）** の3タスクタイプを実行する仕組み。

> **Note**: GitHub Copilot CLI は従量課金へ移行したため、**Review タスクの既定ラインナップから除外**しています（`--cli copilot-cli` でオプトイン）。Explore / Implement では引き続き既定で使用します。

## アーキテクチャ

```
multi-agent.sh --task review|explore|implement [options]
  ↓
  adapter-common.sh (タスクタイプ対応の prompt 構築)
  ↓
  各 CLI adapter (タスクタイプ対応の sandbox/permissions)
  ↓
  perspectives/{task}/*.md (タスク別プロンプトテンプレート)
```

### コンポーネント

| コンポーネント      | 説明                                                 |
| ------------------- | ---------------------------------------------------- |
| `multi-agent.sh`    | 統一オーケストレーター                               |
| `multi-review.sh`   | 後方互換ラッパー（→ multi-agent.sh --task review）   |
| `adapter-common.sh` | 共通ユーティリティ（prompt構築、出力、タイムアウト） |
| `*-adapter.sh`      | CLI固有の薄いラッパー（5つ）                         |
| `perspectives/`     | タスクタイプ別プロンプトテンプレート                 |
| `agent-config.yaml` | 設定ファイル（v2.0）                                 |

## タスクタイプ

### Review（レビュー）

コード変更を分析し、問題を検出する read-only タスク。

| Perspective          | デフォルトCLI | 内容                   |
| -------------------- | ------------- | ---------------------- |
| type-design-analysis | claude-code   | 型設計分析             |
| code-review          | codex-cli     | コードレビュー         |
| error-handler-hunt   | codex-cli     | エラーハンドリング検出 |
| test-analysis        | codex-cli     | テスト分析             |
| comment-analysis     | gemini-cli    | コメント分析           |
| security-analysis    | gemini-cli    | セキュリティ分析       |
| code-simplification  | cursor-cli    | コード簡素化           |

### Explore（探索）

コードベースを分析し、構造やパターンを可視化する read-only タスク。

| Perspective           | デフォルトCLI | 内容                   |
| --------------------- | ------------- | ---------------------- |
| architecture-analysis | claude-code   | アーキテクチャ構造分析 |
| dependency-mapping    | codex-cli     | 依存関係マッピング     |
| api-surface-analysis  | copilot-cli   | API サーフェス分析     |
| tech-debt-assessment  | gemini-cli    | 技術的負債評価         |
| pattern-discovery     | cursor-cli    | パターン検出           |

### Implement（実装）

コード生成・変更をステージングディレクトリに出力するタスク。

| Perspective            | デフォルトCLI | 内容             |
| ---------------------- | ------------- | ---------------- |
| feature-implementation | claude-code   | コア実装         |
| refactoring            | codex-cli     | リファクタリング |
| test-writing           | copilot-cli   | テスト生成       |
| documentation          | gemini-cli    | ドキュメント生成 |
| migration              | cursor-cli    | マイグレーション |

## 使い方

### CLI から

```bash
# Review
bash scripts/multi-agent.sh --task review --dry-run
bash scripts/multi-agent.sh --task review

# Explore
bash scripts/multi-agent.sh --task explore --description "認証フローの調査" --dry-run
bash scripts/multi-agent.sh --task explore --description "認証フローの調査"

# Implement
bash scripts/multi-agent.sh --task implement --description "バリデーション追加" --dry-run
bash scripts/multi-agent.sh --task implement --description "バリデーション追加"

# 後方互換
bash scripts/multi-review.sh --dry-run
```

### Claude Code スラッシュコマンド

```
/multi-review
/multi-explore 認証フローの調査
/multi-implement バリデーション関数の追加
```

### オプション

| オプション                | 説明                                    | デフォルト                |
| ------------------------- | --------------------------------------- | ------------------------- |
| `--task`                  | タスクタイプ                            | review                    |
| `--description`           | タスク説明                              | (explore/implementで必須) |
| `--cli <name>`            | 特定CLIのみ実行                         | 全CLI                     |
| `--perspective <name>`    | 特定perspectiveのみ。distributed では所有CLIだけが残る | 全perspective             |
| `--strategy`              | balanced/minimize_cost/maximize_quality（明示 `--cli` は置換しない） | タスク別                  |
| `--mode`                  | distributed/cross-model                 | distributed               |
| `--parallel/--sequential` | 実行方式                                | parallel                  |
| `--include-diff`          | implementにdiffを含める                 | false                     |
| `--dry-run`               | プラン確認のみ                          | false                     |
| `--timeout`               | タイムアウト(秒)                        | タスク別                  |

## タスク別デフォルト設定

| 項目       | Review           | Explore           | Implement           |
| ---------- | ---------------- | ----------------- | ------------------- |
| Strategy   | balanced         | minimize_cost     | maximize_quality    |
| Output Dir | .review-results/ | .explore-results/ | .implement-results/ |
| Timeout    | 900s             | 600s              | 900s                |
| Diff 含む  | Yes              | No                | Optional            |

## 設定 (agent-config.yaml)

v2.0 形式で、タスクタイプ別・エージェント別に設定可能。
v1.0 (review-config.yaml) との後方互換あり。

## Perspective フィルタと単一 CLI 縮退

distributed モードの perspective は CLI ごとの固定レジストリから解決されます。
`--perspective` だけを指定すると、その perspective を所有しない導入済み CLI は
プランから除外されます。review プランが暗黙に単一 CLI へ縮退した場合は、
実行時 fallback が無いことによるゼロカバレッジのリスクと
`--mode cross-model --perspective <name>` の代替を警告します。

単一の `--cli <name> --perspective <name>` を両方明示した場合は、その組み合わせを
利用者の実行意図としてレジストリより優先します。したがって、失敗サマリーが提示する
代替 CLI + 元 perspective の再実行コマンドも空プランになりません。repeatable な
複数 CLI / perspective を指定した場合は、想定外の直積実行を避けるため既存の
所有レジストリで絞り込みます。
同じ perspective を複数モデルで比較する場合は `--mode cross-model` を使用します。
複数 perspective が単一 CLI へ縮退した場合、警告は perspective ごとに独立した
cross-model コマンドを表示します。
明示した `--cli` は利用者の選択を優先し、`minimize_cost` 等の cost strategy で
別 CLI へ置換しません。未知または対象 task に存在しない perspective は、
実行だけでなく dry-run も非 0 で拒否します。

## 安全策

- **Review/Explore**: read-only（コード変更なし）
- **Implement**: ステージングディレクトリ出力（ワーキングツリー直接書き込み禁止）
- **Fallback（プラン構築時のみ）**: CLI未インストール時は自動的に代替CLIへ再分配
- **実行時 fallback は無し**: インストール済み CLI がエラー／タイムアウトしても別 CLI へ振り替えず、失敗として報告して非 0 終了する。クロスモデル性が黙って変わること・代替先のコスト帯が上がりうること・タイムアウト再試行が同じ制限時間を再消費することを避けるため。部分出力は `Status: incomplete` 付きで保存し、統合レポートに `INCOMPLETE` を明示する（未完了の節は「指摘なし」ではなく「未確認」）
- **Cost Strategy**: minimize_cost で premium CLI を flat-rate CLI に自動振り替え

## Perspective 作成ガイド

### 新しい Perspective を追加するには

1. `scripts/perspectives/{task_type}/` に `.md` ファイルを作成
2. 以下のセクション構造に従う:
   - `# Perspective: [名前]`
   - `## Role` — エージェントの役割定義
   - `## Analysis Focus` / `## Implementation Focus` — 分析・実装の焦点
   - `## Output Template` — 出力フォーマット
   - `## Notes` — 注意事項
3. `agent-config.yaml` の該当 agent に perspective を追加
4. `multi-agent.sh` の `get_cli_perspectives_{task_type}()` にマッピング追加

### Perspective 設計原則

- **タスクタイプを意識**: review は read-only、implement はステージング出力
- **出力フォーマット統一**: 統合レポート生成のため、Output Template を標準化
- **CLI 非依存**: 特定 CLI の機能に依存しないプロンプト設計
- **スコープ明確化**: 1 perspective = 1 観点（複数の責務を混ぜない）
