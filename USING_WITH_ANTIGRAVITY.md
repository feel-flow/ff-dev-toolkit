# Google Antigravity で ff-dev-toolkit を使う

このガイドでは、[Google Antigravity](https://antigravity.google/)（Antigravity IDE / Antigravity 2.0 / `agy` CLI）へ `ff-dev-toolkit` のスキル・`spec-docs` MCP サーバー・hooks を導入し、日次の自動更新まで含めて運用する手順を説明します。

## 1. 前提条件

- **Google Antigravity**（プラグイン読込先 `~/.gemini/config/plugins/` を使用）
- **bash**（macOS / Linux / WSL。Windows は Git Bash ではなく WSL 環境を推奨）
- **jq**（`plugin.json` / `mcp_config.json` / `hooks.json` / 同期状態ファイルの生成・検証に必須）
- **git**（`--repo` による管理クローン作成と自動更新に使用）
- **Node.js >= 22**（`spec-docs` MCP サーバーおよび `retrospective-chain-tail.mjs` が利用）

## 2. 導入手順（自動更新に対応した推奨構成）

### ステップ 1: 管理クローン経由で `ff-dev-toolkit` を展開する

`--repo feel-flow/ff-dev-toolkit` を指定すると、専用の管理クローン（既定 `${FF_DEV_TOOLKIT_STATE_DIR:-$HOME/.config/ff-dev-toolkit}/antigravity/repos/feel-flow__ff-dev-toolkit`）へ取得し、`~/.gemini/config/plugins/ff-dev-toolkit/` へ以下を展開します:

- `plugin.json`（Antigravity 対応メタデータのみ）
- `skills`（管理クローンの `plugins/ff-dev-toolkit/skills/` への symlink。スキル本体を複製しません）
- `mcp_config.json`（バンドル済み `plugins/ff-dev-toolkit/mcp/dist/index.js` を実体物理パスで指す `ff-dev-toolkit-spec-docs` 設定）

初回は `feel-flow/ff-dev-toolkit` を一度手元で取得して実行するか、導入先リポジトリ/手元クローンから次のように実行します:

```bash
# 例: 管理クローン方式で導入（対象プロジェクトの SPEC_DOCS_PROJECT_ROOT も設定）
bash plugins/ff-dev-toolkit/scripts/antigravity/sync-plugins.sh \
  --repo feel-flow/ff-dev-toolkit \
  --project-root /path/to/your-project
```

> リポジトリ直下の `.claude-plugin/marketplace.json`（`./plugins/ff-dev-toolkit`）を `sync-plugins.sh --repo` が検出し、`--clone-dir`（既定の上記パス）へ取得・追従して `ff-dev-toolkit` を展開します。フォーク等でルート直下に `.claude-plugin/plugin.json` と `skills/` を直接置く単一プラグイン構成にも対応しています。

### ステップ 2: hooks と日次自動更新を有効化する

安全ガード・自動振り返り・SessionStart の自動更新を Antigravity でも効かせる場合は、`sync-hooks.sh` を管理クローン側に対して実行します:

```bash
bash "${HOME}/.config/ff-dev-toolkit/antigravity/repos/feel-flow__ff-dev-toolkit/plugins/ff-dev-toolkit/scripts/antigravity/sync-hooks.sh"
```

これで `~/.gemini/config/plugins/ff-dev-toolkit/hooks.json` が生成され、双方向シム `plugins/ff-dev-toolkit/scripts/antigravity/hook-shim.sh` 経由で以下が動作します:

- **PreToolUse / PostToolUse**: Bash / ファイル操作ガード、レビュー走行中ロック等（`--on-failure block` 設定は fail-closed で継承）
- **PreInvocation / Stop**: 1 ターン目の振り返り事前注入および Antigravity `transcript.jsonl` 連携の実行漏れ防止
- **SessionStart（日次自動更新）**: `auto-update-marketplace.sh` を `--async` でデタッチ起動し、セッション開始を止めずにバックグラウンドで日次の更新を実行

> hooks を展開しない場合、自動振り返りは発火しないため、完了時に `/retrospective`（または振り返り依頼）を明示してください。

### ステップ 3: 整合確認（`--check`）

展開が最新かつリンク切れがないかをいつでもオフラインで確認できます（最新なら終了コード 0、差分があれば終了コード 1）:

```bash
bash "${HOME}/.config/ff-dev-toolkit/antigravity/repos/feel-flow__ff-dev-toolkit/plugins/ff-dev-toolkit/scripts/antigravity/sync-plugins.sh" \
  --repo feel-flow/ff-dev-toolkit \
  --project-root /path/to/your-project \
  --check

bash "${HOME}/.config/ff-dev-toolkit/antigravity/repos/feel-flow__ff-dev-toolkit/plugins/ff-dev-toolkit/scripts/antigravity/sync-hooks.sh" \
  --check
```

導入後は Antigravity を再起動（または新しいセッションを開始）して読み込みを反映してください。

## 3. 自動更新の仕組みと手動実行

### SessionStart 自動更新の挙動

`sync-hooks.sh` で `hooks.json` を展開すると、`SessionStart` 時に `hook-shim.sh --async` が即座に `{}` を返してバックグラウンドへ切り離し、`plugins/ff-dev-toolkit/scripts/antigravity/auto-update.sh --hook` を呼び出します。

- **1 日 1 回・fail-silent**: 日付単位の atomic スタンプで同日 2 回目以降は即終了し、オフライン時でもセッション起動を妨げません。
- **同期元と設定の保持**: `sync-plugins.sh` が同期先（`--out-dir`）・同期元・`--project-root` を `${FF_DEV_TOOLKIT_STATE_DIR:-$HOME/.config/ff-dev-toolkit}/antigravity/sync-state.json` へ記録するため、更新時も `SPEC_DOCS_PROJECT_ROOT` や選択プラグイン設定が維持されます。
- **hooks 更新のオプトイン境界**: 既に `hooks.json` が導入されている環境では、当該プラグイン所有元の管理クローン・チェックアウトに対してだけ hooks も自動で再展開します（未導入環境へ勝手に hook を追加したり、無関係なソースで上書きしません）。
- **作業中チェックアウトの保護**: Git ソースが **clean な既定ブランチ**でない場合（未コミット変更・feature ブランチ・detached HEAD・rebase 中）は、リモート更新も出力先への再同期もスキップします。

### 自動更新を止める（L4 宣言）

SessionStart での自動更新だけを無効化する場合は環境変数を設定します:

```bash
export FF_DEV_TOOLKIT_SKIP=auto-update
```

### 手動で即時更新する

```bash
# 全同期先の最新化を実行
bash "${HOME}/.config/ff-dev-toolkit/antigravity/repos/feel-flow__ff-dev-toolkit/plugins/ff-dev-toolkit/scripts/antigravity/auto-update.sh"

# 変更を加えずに予定処理を確認
bash "${HOME}/.config/ff-dev-toolkit/antigravity/repos/feel-flow__ff-dev-toolkit/plugins/ff-dev-toolkit/scripts/antigravity/auto-update.sh" --dry-run

# 日次スタンプを無視してフックモード相当をテスト実行
bash "${HOME}/.config/ff-dev-toolkit/antigravity/repos/feel-flow__ff-dev-toolkit/plugins/ff-dev-toolkit/scripts/antigravity/auto-update.sh" --hook --force
```

## 4. ローカルチェックアウト・他プラグインとの併用

### 手元のチェックアウトを直接展開する

開発中やフォーク先のローカルチェックアウトをそのまま展開したい場合は、チェックアウト直下から次のように実行します（引数省略時は同梱の `plugins/ff-dev-toolkit` を `--plugin-root` として展開します）:

```bash
bash plugins/ff-dev-toolkit/scripts/antigravity/sync-plugins.sh --project-root /path/to/your-project
bash plugins/ff-dev-toolkit/scripts/antigravity/sync-hooks.sh
```

検証後に管理クローン運用へ戻す場合は、セクション 2 の `--repo feel-flow/ff-dev-toolkit` と管理クローン側 `sync-hooks.sh` を再実行してください。

別の GitHub リポジトリやローカルプラグインも同じ `~/.gemini/config/plugins/` へ `--repo` や `--plugin-root` で追加でき、`sync-state.json` は出力先ごとに別ソースとして保持するため互いに上書きされません（同一プラグイン名を別ソースから展開した場合のみ新しいソースへ切り替わります）。

### アンインストール（削除手順）

Antigravity から `ff-dev-toolkit` を外す場合は、展開先のバンドルディレクトリ（`skills` は symlink なのでソース側ファイルは消えません）と状態ファイル・管理クローンを削除します:

```bash
# hooks のみを無効化する場合
rm -f -- "${HOME}/.gemini/config/plugins/ff-dev-toolkit/hooks.json"

# プラグイン自体を完全に外す場合
rm -rf -- "${HOME}/.gemini/config/plugins/ff-dev-toolkit"
rm -rf -- "${HOME}/.config/ff-dev-toolkit/antigravity/repos/feel-flow__ff-dev-toolkit"
# 必要に応じて "${HOME}/.config/ff-dev-toolkit/antigravity/sync-state.json" を削除または対象エントリを整理
```

（削除済み出力先ディレクトリは `auto-update.sh` によって自動再作成されません。）

## 5. 制限・トラブルシューティング

- **`SubagentStart` / `SubagentStop` / `PermissionDenied`**: Antigravity の `hooks.json` スキーマに存在しないため展開時にスキップされます。`manage_subagents(kill)` は `TaskStop` へ変換されます。
- **`PostToolUse` の `additionalContext`**: Antigravity の `PostToolUse` は `{}` のみ受理するため、`hook-shim.sh` は `{}` を返します（ブロック系は `PreToolUse` が担います）。
- **`AGENTS.md` サイズ制限**: Antigravity はワークスペースの指示文書合計が **24,000 bytes** を超えると切り詰めます。`AGENTS.md` は薄い入口に保ち、詳細仕様は参照ファイルへ分離してください。
- **`出力先の skills が symlink ではない実体` エラー**: 古い手動コピーが残っている場合は `~/.gemini/config/plugins/ff-dev-toolkit/skills` を確認・削除してから `sync-plugins.sh` を再実行してください。
