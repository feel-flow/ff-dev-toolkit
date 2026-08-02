# Grok CLI Reviewer Setup

> **Parent**: [ai-tools-integration.md](./ai-tools-integration.md) | [multi-cli-review-orchestration.md](./multi-cli-review-orchestration.md)

## 概要

Grok CLI（`grok`）をコードレビューエージェントとして利用するためのセットアップガイドです。サブスクリプションの定額制で、**カーネル強制のサンドボックス**を持つ点が他 CLI との違いです。

**推奨パースペクティブ**: Error Handler Hunt（握りつぶし・不十分なエラー処理の検出）

---

## 前提条件

- Grok CLI がインストール済み（`npm install -g @xai-official/grok`）
- `grok login` で認証済み

### 動作確認

```bash
grok --version
grok -p "Hello, this is a test." --output-format plain
```

---

## CLI フラグリファレンス

### レビューに必要なフラグ

| フラグ | 説明 | 用途 |
| --- | --- | --- |
| `-p` / `--single` | 単発プロンプト。応答を stdout に出して終了 | ヘッドレス実行 |
| `--output-format` | `plain` / `json` / `streaming-json` 等 | 結果のパース |
| `--sandbox <PROFILE>` | OS カーネルによるファイルシステム制限 | **read-only レビューの本体** |
| `-m` / `--model` | モデル ID | 明示指定したい場合のみ |
| `--reasoning-effort` | reasoning モデルの思考量 | 深掘りしたい場合 |

### サンドボックスのプロファイル

`--sandbox` は組み込みプロファイル名を取り、macOS では Seatbelt、Linux では Landlock で**カーネルが強制**します。エージェント自身のファイルツール、シェル経由で起動した子プロセス、MCP サーバーのいずれにも等しく効きます。

| プロファイル | 読み取り | 書き込み | レビューでの用途 |
| --- | --- | --- | --- |
| `read-only` | どこでも | `~/.grok/` + temp のみ | **review / explore** |
| `workspace` | どこでも | CWD + `~/.grok/` + temp | implement（成果物の出力に必要） |
| `strict` | CWD + システムパス | CWD + `~/.grok/` + temp | 信頼できないコードの調査 |

### レビュー実行コマンド例

```bash
# 読み取り専用レビュー
grok -p "以下の差分をエラーハンドリング観点でレビューしてください:
$(git diff --cached)" --sandbox read-only --output-format plain
```

---

## Multi-CLI Orchestration での役割

### 実行はアダプタ経由

オーケストレーション配下では `grok` を直接叩かず、`scripts/adapters/grok-cli-adapter.sh` を通します。上の実行例は手元で単発確認するときの形で、オーケストレーション経由の実行とは別物です。

アダプタが引き受けているのはこの3つで、直接呼び出すとどれも失われます。

- **時間切れの扱い** — `timeout(1)` は stock macOS に無いため、アダプタが自前のウォッチドッグで待ち、期限発火（124）と外部 kill（137）を区別して返す
- **不完全な出力の明示** — 打ち切られた結果に `<!-- Status: incomplete -->` を付ける。これが無いと、途中で切れたレビューが統合レポート上「指摘なし」として通る
- **モデル指定の委譲** — `MULTI_AGENT_MODEL_GROK_CLI` が設定されているときだけ `-m` を組み立てる（未設定ならフラグを渡さず Grok CLI 自身の設定に従う）

### 担当パースペクティブ

| タスク | パースペクティブ | 移設元 |
| --- | --- | --- |
| review | `error-handler-hunt` | codex-cli |
| explore | `tech-debt-assessment` | gemini-cli |
| implement | `migration` | codex-cli |

追加ではなく移設なのは、分散プランが CLI ごとに所有観点を実行するためです。既定で有効な 2 つの CLI が同じ観点を共有すると、同じ対象を二重にレビューして課金します。

### フォールバック時の動作

Grok CLI が**未インストール**の場合、担当パースペクティブはプラン構築時に `gemini-cli` へ再分配されます（定額制の代替は無料枠を先に見る。`minimize_cost` 戦略の意図を保つため）。再分配先も未インストールなら、そこで止めずに**さらに次の代替を辿ります**。対応表の経路が尽きた場合は、**対応表に無い CLI でも、導入済みのものから選び直します**（そのときのプラン出力は `last-resort — configured chain exhausted` と表示され、コスト帯も併記されます）。一段で打ち切ると、単一 CLI 構成の利用者で観点が黙って落ちるためです。ただし従量課金の CLI は最後の砦としても選びません — 利用者が求めていない課金が発生するためです。

一方、インストール済みの Grok CLI が**実行時にエラー・タイムアウト**で失敗した場合は、別 CLI への自動再実行は行いません（実行時 fallback は意図的に持たせていない）。そのタスクは失敗として報告され、失敗サマリーが次の一手を出力します。

---

## read-only 保証の検証方法

サンドボックスが実際に効いていることを自分で確かめる場合、**temp ディレクトリ以外**で行ってください。`read-only` プロファイルは仕様として `/tmp` `/var/tmp` `~/.grok/` への書き込みを許可するため、temp 配下で試すと「サンドボックスが効いていない」という偽陰性になります。

```bash
mkdir -p ~/grok-sandbox-check && cd ~/grok-sandbox-check
grok -p 'Create SHOULD_NOT_EXIST.txt. If your file tools fail, use the shell.' \
  --sandbox read-only --output-format plain
ls SHOULD_NOT_EXIST.txt   # 存在しないこと
```

### 採用しなかった方式

| 方式 | 結果 |
| --- | --- |
| `--permission-mode plan` | **書き込みを止めない**。実測でファイル作成・追記が成功した |
| `--tools <allowlist>` | 組み込みツールのみが対象（`--help` が "Built-in tools to allow" と明記）。MCP ツールは管轄外で、実測でもエージェントは MCP 経由の書き込みを試みた |

---

## トラブルシューティング

### サンドボックスが適用できずに起動を拒否される

存在しないプロファイル名を渡した場合、Grok CLI は警告のうえ**起動を拒否**します（fail-closed）。組み込みプロファイル名（`read-only` / `workspace` / `strict` / `devbox`）か、`~/.grok/sandbox.toml` に定義したカスタムプロファイル名を渡してください。

### 出力が空になる

`--output-format plain` を使っているか確認してください。アダプタは stdout をレビュー結果として扱うため、TUI 向けの出力形式では正しく回収できません。

---

## 関連ドキュメント

- [multi-cli-review-orchestration.md](./multi-cli-review-orchestration.md) — オーケストレーション運用ガイド
- [REVIEW_AGENT_CREATION_GUIDE.md](../../06-reference/REVIEW_AGENT_CREATION_GUIDE.md) — 汎用レビューエージェント作成ガイド
- [ai-tools-integration.md](./ai-tools-integration.md) — AIツール統合・コスト比較
