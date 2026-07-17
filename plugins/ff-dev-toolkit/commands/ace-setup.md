---
description: プロジェクトに ACE (Agentic Context Engineering) フレームワークを対話形式でセットアップする
---

# /ace-setup — ACE フレームワーク セットアップ

プロジェクトに ACE (Agentic Context Engineering) フレームワークをセットアップします。
対話形式で配置先やAIツールの設定を確認しながら進めます。テンプレートはすべて本プラグインに同梱されており、ネットワークアクセスは不要です。

## 前提

- git リポジトリで作業中であること
- `docs/` ディレクトリと `docs/MASTER.md` が存在すること（`/init-docs` 済み推奨）

## 手順（対話型セットアップフロー）

### Step 1: 前提確認

以下を自動チェックする:

1. **`docs/` ディレクトリの存在確認** — 存在しない場合: 「`docs/` が見つかりません。先に `/init-docs` を実行してドキュメント構造を初期化してください」と表示し、**セットアップを中止**する
2. **`docs/MASTER.md` の存在確認** — 存在しない場合: 同様に `/init-docs` の実行を推奨し、**セットアップを中止**する
3. **PLAYBOOK.md の既存チェック** — `docs/08-knowledge/PLAYBOOK.md` が既に存在する場合、ユーザーに選択肢を提示:
   - **(a) セットアップを中止** — 既存の PLAYBOOK.md を維持する
   - **(b) バックアップして続行** — 既存ファイルを `PLAYBOOK.md.bak` にリネームして新規作成する

### Step 2: 配置先の確認

ユーザーに以下のデフォルトパスを提示し、変更するか質問する:

| ファイル     | デフォルトパス                               |
| ------------ | -------------------------------------------- |
| PLAYBOOK.md  | `docs/08-knowledge/PLAYBOOK.md`              |
| ace-cycle.md | `docs/05-operations/deployment/ace-cycle.md` |

### Step 3: ファイル配置（同梱テンプレートから）

配置先ディレクトリが存在しない場合は自動作成し、以下を配置する:

1. **PLAYBOOK.md** — `${CLAUDE_PLUGIN_ROOT}/docs-template/08-knowledge/PLAYBOOK.md` をコピーし、以下を調整:
   - エントリ一覧セクション内のサンプルエントリは削除し、空の状態にする
   - Frontmatter の `owner` をユーザーのプロジェクト情報で置換する
   - Frontmatter の `created` / `updated` を今日の日付、`ace_entry_count` を `0`、`version` を `1.0.0` にする
   - Changelog セクションは `[1.0.0]` の初版のみ残す
   - エントリ本体のカテゴリ別分割ファイル（`playbook/<category>.md`）は最初のエントリ追記時に `/ace-curate` が作成するため、この時点では作らなくてよい
2. **ace-cycle.md** — `${CLAUDE_PLUGIN_ROOT}/docs-template/05-operations/deployment/ace-cycle.md` をそのままコピーする

### Step 4: AIツール固有の設定

ユーザーに対象 AI ツールを確認する（複数選択可）:

- **(a) Claude Code** — `/ace-curate` コマンドは**本プラグインが提供するため追加設定は不要**（プロジェクトへのコマンドコピーも不要）。PLAYBOOK.md の配置先を Step 2 でデフォルトから変更した場合のみ、その旨を CLAUDE.md に記録するよう案内する
- **(b) GitHub Copilot** — `.github/copilot-instructions.md` に ACE 運用ルールを追記
- **(c) Cursor** — `.cursorrules` に ACE 運用ルールを追記
- **(d) Codex / その他の AI エージェント** — `AGENTS.md` に ACE 運用ルールを追記

(b)〜(d) の指示ファイルへ追記する ACE 運用ルールは、配置済みの `docs/05-operations/deployment/ace-cycle.md`（3フェーズ手順）と PLAYBOOK.md の「運用ルール」「エントリID規則」セクションを要約して生成する。最低限含めるもの:

- PLAYBOOK.md の配置場所（Step 2 で確定したパス）
- PRマージ後に Generate（知見抽出）→ Reflect（評価・分類・既存照合）→ Curate（増分追記）を実行すること
- 採番は **PRスコープ式**（`ACE-<PR番号>-<連番>`）、末尾追記のみ・既存本文の書き換え禁止、カウンターはインクリメントのみ
- 詳細手順は `docs/05-operations/deployment/ace-cycle.md` を参照すること

既存ファイルの場合は追記前に内容を確認し、`## ACE` 等の ACE 関連セクションが既に存在する場合は**スキップ**する。ファイルが存在しない場合は新規作成する。

### Step 5: 完了確認

以下の形式で配置結果を表示する（「状態」列は実際の結果に応じて 新規作成 / スキップ / バックアップ後作成 / 追記 などを記載）:

```markdown
## ACE セットアップ完了

以下のファイルを配置しました:

| ファイル                   | パス                                                       | 状態     |
| -------------------------- | ---------------------------------------------------------- | -------- |
| PLAYBOOK.md                | docs/08-knowledge/PLAYBOOK.md                              | 新規作成 |
| ace-cycle.md               | docs/05-operations/deployment/ace-cycle.md                 | 新規作成 |
| 指示ファイル（選択ツール） | .github/copilot-instructions.md / .cursorrules / AGENTS.md | 追記     |

## 次のステップ

1. PRマージ・cleanup 後に ACE サイクルを実行してみましょう:
   - Claude Code: `/ace-curate` コマンドを実行
   - Copilot / Cursor / Codex 等: 指示ファイルの ACE 運用ルールに従い「ACEサイクルを実行してください」と指示
```

### （任意）ACE autonomous テンプレートの案内

ユーザーが **マージ後の ACE を subagent + worktree で自動化**したい場合のみ、`${CLAUDE_PLUGIN_ROOT}/docs-template/05-operations/deployment/ace-autonomous.md` と `${CLAUDE_PLUGIN_ROOT}/docs-template/scripts/ace/` をコピー先の目安とともに案内する。feature flag（`ACE_SUBAGENT_ENABLED` 等）は**デフォルト無効**で開始することを必ず伝える。

## 参考（任意参照）

- ACE フレームワークの理論的背景・詳細ガイド: <https://github.com/feel-flow/ai-spec-driven-development/blob/develop/docs/ACE_FRAMEWORK.md> / <https://github.com/feel-flow/ai-spec-driven-development/blob/develop/docs/ACE_SETUP.md>（本コマンドは同梱テンプレートのみで完結するため、参照は必須ではない）

## 注意事項

- 既存ファイルがある場合は上書きせず、ユーザーに確認すること
- 配置先ディレクトリが存在しない場合は自動作成すること
- `/ace-curate` は本プラグインが提供するため、コマンドのコピーは不要（Playbook はプロジェクトの `docs/08-knowledge/PLAYBOOK.md` に配置する）
