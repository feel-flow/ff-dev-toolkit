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
| review | `security-analysis` | gemini-cli（issue #783 で削除） |
| explore | `tech-debt-assessment` | gemini-cli（同上） |
| explore | `pattern-discovery` | gemini-cli（同上） |
| implement | `migration` | codex-cli |

追加ではなく移設なのは、分散プランが CLI ごとに所有観点を実行するためです。既定で有効な 2 つの CLI が同じ観点を共有すると、同じ対象を二重にレビューして課金します。

### フォールバック時の動作

Grok CLI が**未インストール**の場合、担当パースペクティブはプラン構築時に `codex-cli` へ再分配されます（旧代替の `gemini-cli` は issue #783 で削除されたため付け替え）。再分配先も未インストールなら、そこで止めずに**さらに次の代替を辿ります**。対応表の経路が尽きた場合は、**対応表に無い CLI でも、導入済みのものから選び直します**（そのときのプラン出力は `last-resort — configured chain exhausted` と表示され、コスト帯も併記されます）。一段で打ち切ると、単一 CLI 構成の利用者で観点が黙って落ちるためです。ただし従量課金の CLI は最後の砦としても選びません — 利用者が求めていない課金が発生するためです。

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

### docker.sock が symlink の macOS で read-only が起動拒否される

症状（grok 1.0.30、2026-09-14 実測）:

```text
$ grok --sandbox read-only inspect
warning: sandbox could not be applied: runtime-socket deny resolution failed: could not resolve runtime-socket deny path /var/run/docker.sock: endpoint is a symlink
error: could not apply the 'read-only' sandbox profile; see the warning above for the cause. Refusing to start with its protections missing.
```

Docker Desktop の macOS 既定配置では `/var/run/docker.sock` が `~/.docker/run/docker.sock` への symlink です。`restrict_network = true` を持つプロファイル（組み込みの `read-only` / `strict`）は、起動時にコンテナランタイムのソケット（docker / podman / containerd）への deny を張り、その path を実体解決する際に symlink を拒否します。**`workspace` は `restrict_network = false` なので同じ機械で起動する**ため、オーケストレーション配下では implement だけが動き review / explore が常に `INCOMPLETE` になります。

**採ってはいけない回避**: review を `workspace` で走らせること。レーンは動きますが、CWD への書き込みを許した別の保証の実行になります（`multi-review` が依拠する「read-only サンドボックスで書き込みを失敗させる」が黙って外れる）。アダプタは `MULTI_AGENT_GROK_READONLY_PROFILE=workspace` を名前の時点で拒否します。

**採る回避**: deny を張らせない、read-only 相当のカスタムプロファイルを定義する。deny は `restrict_network` に連動しており（`extends = "workspace"` + `restrict_network = true` でも同じ拒否になる）、`restrict_network` のネットワーク遮断自体は macOS では no-op です（ベンダー文書 `18-sandbox.md`「On macOS network blocking is a no-op」。[Issue #897 の実測](../../../tests/adapter-sandbox-contract/README.md)でも `read-only` の外部 HTTPS は通っていた）。

**この差し替えで失うもの（実測、要認識）**: `restrict_network` が張るコンテナランタイムソケットの deny です。`extends = "read-only"` + `restrict_network = false` のプロファイルで課金走行し、`curl --unix-socket` で `/var/run/docker.sock` とその実体 `~/.docker/run/docker.sock` の両方から Docker API の応答を取得できました。カスタムプロファイルの `deny` に両パスを足しても、symlink 側は塞がる（curl rc=7）一方で実体側への接続は通ります（`deny` は file-read / file-write の規則で、unix socket の connect を止めない）。つまりレビューエージェントが Docker API に到達できる状態で走り、書き込み境界（作業ツリー）だけが保たれます。同じ機械の implement（`workspace`、`restrict_network = false`）は既にこの状態なので新規の後退ではありませんが、review が受け取る diff は信頼できない入力です。アダプタはこの差し替えで走るたびに `⚠️ runtime-socket:` の通知を stderr へ出します（ネットワーク開放の通知と同じ扱い。黙って走らせない）。この露出を受け入れられない環境では差し替えを使わず、従来どおり `exclude_clis` で外してください。

```toml
# ~/.grok/sandbox.toml（<project>/.grok/sandbox.toml でも可。user 側が優先）
[profiles.ff-review-ro]
extends = "read-only"
restrict_network = false
```

```bash
# 単発確認（rc=0 で起動し、ProfileApplied の read_write_paths が ~/.grok と temp 系だけ = 組み込み read-only と同一）
grok --sandbox ff-review-ro inspect </dev/null; echo "rc=$?"
tail -1 ~/.grok/sessions/sandbox-events.jsonl
```

オーケストレーション配下では、[multi-cli-review-orchestration.md](multi-cli-review-orchestration.md) の起動手順の環境に `MULTI_AGENT_GROK_READONLY_PROFILE=ff-review-ro` を加えて dry-run し、grok-cli の項目から「この環境では sandbox を適用できません」の警告が消えることを確認します。差し替わるのは read-only スロット（review / explore / implement `--inline-output`）だけで、通常の implement の `workspace` は不変です。

この機械の既定にするなら、シェルの起動ファイルで `export MULTI_AGENT_GROK_READONLY_PROFILE=ff-review-ro` します。`exclude_clis` / `--exclude-cli` はクロスモデルを 1 本減らす手段なので、この差し替えが成立する環境では使いません。

アダプタ側の fail-closed（名前だけでは中身を保証できないため）:

| 条件 | アダプタの挙動 |
| --- | --- |
| 環境変数が未設定 | 従来どおり `read-only`。`workspace` へ黙って降格する経路は無い |
| `workspace` / `devbox` / `strict` / `off` / `none`、フラグに化ける値 | 起動前に非 0 で拒否（dry-run の probe も `refused-to-start` で報告） |
| カスタム名で実行後、ProfileApplied の `read_write_paths` に作業ツリー・その祖先・その配下・`/` が含まれる（末尾スラッシュは正規化） | **結果を採用しない**（「read-only ではない」と名指し。成果物にも同じ理由が残る）。`extends = "workspace"` や `read_write` で作業ツリーやその一部を足したプロファイルはここで落ちる |
| カスタム名で実行後、`read_write_paths` 配列が無い、または引用文字列として読めない | 確認不能として不採用 |

書き込み境界の実測（grok 1.0.30 / macOS、`ff-review-ro`、temp 外の CWD で課金走行）: CWD への shell 書き込み・`touch`・Write ツールとも `Operation not permitted` で失敗し、`FsViolation` が記録された。`/tmp` への書き込みだけは組み込み `read-only` と同じく許可（仕様）。`read_write_paths` の記録は 0.2.118 時代の組み込み `read-only` の記録（`~/.grok/sandbox-events.jsonl`）と同一で、1.0.30 の `read-only` はこの機械では起動しないため 1.0.30 同士の比較ではない。コマンドと出力は [tests/adapter-sandbox-contract/README.md](../../../tests/adapter-sandbox-contract/README.md) の「カスタム read-only プロファイル（docker.sock symlink 対応）」節。

**この対応が要らない環境**: Linux（docker.sock は通常 symlink ではない）や Docker Desktop 未導入の macOS では組み込み `read-only` がそのまま起動するので、環境変数は設定しません。Linux で `restrict_network = false` にすると子プロセスのネットワーク遮断（seccomp）を実際に失うため、Linux でこの差し替えを既定にはしないでください。

### 出力が空になる

`--output-format plain` を使っているか確認してください。アダプタは stdout をレビュー結果として扱うため、TUI 向けの出力形式では正しく回収できません。

---

## 関連ドキュメント

- [multi-cli-review-orchestration.md](./multi-cli-review-orchestration.md) — オーケストレーション運用ガイド
- [REVIEW_AGENT_CREATION_GUIDE.md](../../06-reference/REVIEW_AGENT_CREATION_GUIDE.md) — 汎用レビューエージェント作成ガイド
- [ai-tools-integration.md](./ai-tools-integration.md) — AIツール統合・コスト比較
