# Cursor CLI Reviewer Setup

> **Parent**: [ai-tools-integration.md](./ai-tools-integration.md) | [multi-cli-review-orchestration.md](./multi-cli-review-orchestration.md)

## 概要

Cursor CLIをコードレビューエージェントとして利用するためのセットアップガイドです。Cursor CLIはエディタとの強い連携を持ち、コード簡素化やリファクタリング提案に特に適しています。

**推奨パースペクティブ**: Code Simplification（月額固定料金でコスト気にせず繰り返し実行）

---

## 前提条件

- Cursor エディタ インストール済み
- Cursor Pro サブスクリプション（$20/月、CLI機能利用に必要）

---

## インストール

### Cursor エディタからCLIを有効化

```bash
# Cursor エディタの Command Palette (Cmd+Shift+P) から:
# "Install 'cursor-agent' command in PATH" を実行

# 動作確認
cursor-agent --version
```

### CLI が PATH に通っていない場合

```bash
# macOS
export PATH="$PATH:/Applications/Cursor.app/Contents/Resources/app/bin"

# ~/.zshrc に追加して永続化
echo 'export PATH="$PATH:/Applications/Cursor.app/Contents/Resources/app/bin"' >> ~/.zshrc
```

---

## CLI フラグリファレンス

### レビューに必要なフラグ

| フラグ                 | 説明                                   | 用途                                 |
| ---------------------- | -------------------------------------- | ------------------------------------ |
| `-p` / `--print`       | ヘッドレスモード（非インタラクティブ） | プロンプトはpositional引数として渡す |
| `--model auto`         | モデル自動選択                         | 最適なモデルを自動選択               |
| `--model <name>`       | モデル指定                             | 特定モデルを使用                     |
| `--output-format text` | テキスト出力                           | 人間可読な結果                       |
| `--force`              | 確認なし実行                           | 自動化用                             |

### レビュー実行コマンド例

```bash
# 基本的なコード簡素化レビュー
cursor-agent --print --model auto \
  "以下のdiffをコード簡素化の観点でレビューしてください:
$(git diff --cached)"

# 特定ファイルのレビュー
cursor-agent --print --model auto \
  "Review the following file for simplification opportunities:" \
  < src/services/complex-handler.ts
```

> **ハング対策**: `cursor-agent --print` は非インタラクティブモードでハングする既知の問題があります。アダプタ経由で実行してください（`cursor-cli-adapter.sh` が 120 秒上限を自前で強制する）。stock macOS には `timeout` コマンドが無いため、手元で `timeout 120 cursor-agent ...` とラップする方法は使えません（[multi-cli-review-orchestration.md](./multi-cli-review-orchestration.md) の「Cursor CLI のハング問題」参照）。

---

## Multi-CLI Orchestration での役割

### デフォルト設定

```yaml
# review-config.yaml
agents:
  cursor-cli:
    command: cursor-agent
    cost_tier: flat-rate
    default_perspectives: [code-simplification]
```

### 推奨パースペクティブ

| パースペクティブ        | 適合度     | 理由                                   |
| ----------------------- | ---------- | -------------------------------------- |
| **Code Simplification** | ⭐⭐⭐⭐⭐ | エディタ連携の知見を活かした簡素化提案 |
| Code Review             | ⭐⭐⭐     | 汎用レビューも可能                     |
| Comment Analysis        | ⭐⭐⭐     | コメント品質分析                       |

### フォールバック時の動作

Cursor CLI が**未インストール**の場合、`code-simplification` パースペクティブはプラン構築時に `codex-cli` へ再分配されます。

一方、インストール済みの Cursor CLI が**実行時にハング・タイムアウト・異常終了**した場合は、別 CLI への自動再実行は行いません（実行時 fallback は意図的に持たせていない）。そのタスクは失敗として報告され、失敗サマリーが次の一手を出力します。詳細は [multi-cli-review-orchestration.md](./multi-cli-review-orchestration.md) の「CLI がタイムアウト・異常終了したとき」を参照してください。

---

## 既知の制限事項

### ヘッドレスモードの安定性

> **⚠️ 重要**: Cursor CLI の `--print` / `-p` モードには、プロセスがハングして終了しない既知の問題が報告されています。

**影響**: 非インタラクティブ実行時にプロセスが無期限にハングする可能性

**回避策**:

1. **アダプター経由で実行する**（推奨）:

`scripts/adapters/cursor-cli-adapter.sh` が 120 秒の上限を適用し、`run_with_timeout` が期限到達時にプロセスグループごと停止させます（`timeout(1)` が無いホストでも自前の supervisor が効くので coreutils の導入は不要）。`multi-agent.sh` 経由なら上限は orchestrator 側で適用されるため、ログに出る秒数と提示される再実行コマンドが実際に適用された値と一致します。

打ち切られた場合、それまでに得られた部分出力は `Status: incomplete` ヘッダーと `INCOMPLETE` バナー付きで結果ファイルに保存され、統合レポートでも完了レビューと区別されます。**未完了の節は「指摘なし」ではなく「未確認」と読んでください。**

2. **手元で単発実行する場合**:

```bash
bash scripts/adapters/cursor-cli-adapter.sh \
  scripts/perspectives/review/code-simplification.md \
  .review-results/cursor-cli/code-simplification.md
```

3. **Cursor CLIをスキップして代替CLIを使用**:

```bash
bash scripts/multi-review.sh --cli copilot-cli --perspective code-simplification
```

### 今後のアップデート

Cursor チームはCLIの安定性改善に継続的に取り組んでいます。最新の状態は以下で確認できます：

- Cursor Forum: Bug Reports カテゴリ
- Cursor CLI Changelog

---

## コスト管理

### 月額固定料金

| プラン   | 料金   | CLI利用           |
| -------- | ------ | ----------------- |
| Free     | $0     | 制限あり          |
| Pro      | $20/月 | 無制限            |
| Business | $40/月 | 無制限 + 管理機能 |

**推奨**: Pro プラン（$20/月）で無制限にレビュー実行

### レビューでの消費

月額固定料金のため、実行回数によるコスト増はありません。`minimize_cost` 戦略では、Claude Code の担当観点が Cursor CLI に振り替えられます。

---

## トラブルシューティング

### cursor-agent コマンドが見つからない

```
command not found: cursor-agent
```

**対応**: Cursor エディタの Command Palette から CLI をインストール、または PATH を手動設定

### 認証エラー

```
Error: Not authenticated
```

**対応**: Cursor エディタでログイン済みであることを確認。CLI は エディタのセッションを共有します。

### プロセスがハングする

**対応**: 前述の「既知の制限事項」セクションを参照。`timeout` コマンドの利用を推奨。

---

## 関連ドキュメント

- [multi-cli-review-orchestration.md](./multi-cli-review-orchestration.md) — オーケストレーション運用ガイド
- [REVIEW_AGENT_CREATION_GUIDE.md](../../06-reference/REVIEW_AGENT_CREATION_GUIDE.md) — 汎用レビューエージェント作成ガイド
- [ai-tools-integration.md](./ai-tools-integration.md) — AIツール統合・コスト比較
- [gemini-cli-reviewer.md](./gemini-cli-reviewer.md) — Gemini CLI セットアップ
- [SETUP_CURSOR.md](../../SETUP_CURSOR.md) — Cursor エディタ詳細設定
