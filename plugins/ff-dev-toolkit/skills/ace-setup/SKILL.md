---
name: ace-setup
description: プロジェクトに ACE (Agentic Context Engineering) フレームワークを対話形式でセットアップする
---

# /ace-setup — ACE フレームワーク セットアップ

プロジェクトに ACE (Agentic Context Engineering) フレームワークをセットアップします。
対話形式で配置先やAIツールの設定を確認しながら進めます。テンプレートはすべて本プラグインに同梱されており、ネットワークアクセスは不要です。

## プラグインルートの固定（必須）

<!-- ff-dev-toolkit-plugin-root-contract:start -->
同梱resourceを参照する前に `FF_DEV_TOOLKIT_ROOT` を**一度だけ**解決し、実行中は変更しない。

- Claude Codeでは、その呼び出しでホストが渡した `${CLAUDE_PLUGIN_ROOT}` を使う
- Codexなど他ホストでは、実際に読み込んだこの `SKILL.md` の絶対パスを `FF_DEV_TOOLKIT_SKILL_FILE` として固定し、そこから `../..` を解決する

このskillを実行するAI hostは、Bash tool呼び出しを組み立てるとき、skill loaderが返した実値で `FF_DEV_TOOLKIT_SKILL_FILE="<このSKILL.mdの絶対パス>"; export FF_DEV_TOOLKIT_SKILL_FILE` を実行し、同じshell script bodyでresourceを呼び出す。placeholderのまま実行したり、cache pathを推測して埋めたりしない。
plugin内ドキュメントの正本は、読み込んだこの `SKILL.md` のdirectoryを基準にした [plugin root固定契約](../../docs-template/05-operations/deployment/multi-cli-review-orchestration.md#ff-dev-toolkit-plugin-root-prerequisite) である。consumerへコピーされた `docs/` や物理CWDを基準に解決しない。
review系resource（`setup-multi-agent.sh` / `multi-agent.sh` / `multi-review.sh`）を直接呼ぶhostだけが、同節のresolver + guard fence全体を読み、handoff設定・guard・resource呼び出しを同じshell script bodyで実行する。そのhostはtask workspace repository rootも `FF_DEV_TOOLKIT_PROJECT_ROOT` として同じBash tool呼び出しへ渡し、現在の物理CWDおよび `git rev-parse --show-toplevel` と一致することを実行前に確認する。review以外のresourceはこのreview専用guardを実行せず、固定したroot配下で各skillが指定するresourceだけを呼出直前に検証する。以下のBash例は、同じtool bodyで固定済みrootを使うcommand断片として扱う。

解決後は同じ絶対パスだけを使い、cache / marketplace / 旧インストール領域を走査して選ばない。
version sortによる版の選び直しや、sidecarを使った別実体への切替も行わない。
解決済みrootまたは必要resourceが消失・不整合になった場合は、別versionへfallbackせず
「ff-dev-toolkit更新後にこのskillを再呼び出してください」と案内して停止する。
<!-- ff-dev-toolkit-plugin-root-contract:end -->

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

1. **PLAYBOOK.md** — `${FF_DEV_TOOLKIT_ROOT}/docs-template/08-knowledge/PLAYBOOK.md` をコピーし、以下を調整:
   - エントリ一覧セクション内のサンプルエントリ（`ACE-000-*`）は索引テーブルごと削除し、空の状態にする。**「`ACE-000-*` は書き方の見本」と説明している引用ブロックも併せて削除する**（配置後のプロジェクトには該当エントリが無いため）
   - Frontmatter の `owner` をユーザーのプロジェクト情報で置換する
   - Frontmatter の `created` / `updated` を今日の日付、`ace_entry_count` を `0`、`version` を `1.0.0` にする
   - Changelog セクションは `[1.0.0]` の初版のみ残す
   - エントリ本体のカテゴリ別分割ファイル（`playbook/<category>.md`）は最初のエントリ追記時に `/ace-curate` が作成するため、この時点では作らなくてよい
2. **ace-cycle.md** — `${FF_DEV_TOOLKIT_ROOT}/docs-template/05-operations/deployment/ace-cycle.md` をそのままコピーする

### Step 3-b: 形式ゲートの allowlist 初期化（既存プロジェクトのみ）

**新規プロジェクト（Step 3 で同梱テンプレートから PLAYBOOK.md を作成した場合）はこの手順を飛ばす。** エントリが 0 件なので `legacy-format-allowlist.txt` は不要で、「allowlist 不在 = strict」が正しい既定である。

既存の PLAYBOOK.md を引き継ぐプロジェクト（Step 1 で (a) 中止を選び、形式ゲートだけを後から導入する場合を含む）に旧テーブル形式（`| フィールド | 値 |` ヘッダ + Insight/Context/Action ブロック）のエントリが残っているときは、**導入時に 1 回だけ**次を実行して allowlist を初期化する。手作業で ID を抽出して列挙しない:

```bash
# 次の 2 つのうち 1 本だけを実行する
# (1) scripts/ace/check-entry-format.ts を配置済みの場合
npx --yes tsx scripts/ace/check-entry-format.ts --init-allowlist docs/08-knowledge/PLAYBOOK.md
# (2) 配置していない場合はプラグイン同梱のテンプレートを直接叩く（インストール不要）
bash "${FF_DEV_TOOLKIT_ROOT}/scripts/ace-run-ts.sh" "${FF_DEV_TOOLKIT_ROOT}/docs-template/scripts/ace/check-entry-format.ts" --init-allowlist docs/08-knowledge/PLAYBOOK.md
```

- 記録されるのは**導入時点で旧形式だったエントリの ID だけ**（正準フォーマットのエントリは記録しない）。旧形式が 0 件ならファイル自体を作らない
- 既存 allowlist は上書きしない。ID 集合が一致すれば書き込まず成功し（冪等 — 再実行の差分はゼロ）、一致しなければ差分を表示して exit 1 で止まる
- **初期化後に足した旧形式の新規追記は自動追加されない**（形式ゲートが exit 1 で拒否する）。allowlist は既存エントリの読み取り互換のためのものであり、新規追記の抜け道ではない
- exit 2（未閉コードフェンス・エントリ見出しとして認識されない `### ACE-` 行）は**何も書き込まずに**止まる。ID 集合がずれるためで、指摘された箇所を直してから再実行する
- 初期化後は形式ゲート本体（`--init-allowlist` なしの実行）が exit 0 になることを確認する

### Step 4: AIツール固有の設定

ユーザーに対象 AI ツールを確認する（複数選択可）:

- **(a) Claude Code** — `/ace-curate` コマンドは**本プラグインが提供するため追加設定は不要**（プロジェクトへのコマンドコピーも不要）。PLAYBOOK.md の配置先を Step 2 でデフォルトから変更した場合のみ、その旨を CLAUDE.md に記録するよう案内する
- **(b) GitHub Copilot** — `.github/copilot-instructions.md` に ACE 運用ルールを追記
- **(c) Codex / その他の AI エージェント** — `AGENTS.md` に ACE 運用ルールを追記

(b)〜(c) の指示ファイルへ追記する ACE 運用ルールは、配置済みの `docs/05-operations/deployment/ace-cycle.md`（3フェーズ手順）と PLAYBOOK.md の「運用ルール」「エントリID規則」セクションを要約して生成する。最低限含めるもの:

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
| 指示ファイル（選択ツール） | .github/copilot-instructions.md / AGENTS.md | 追記     |

## 次のステップ

1. PRマージ・cleanup 後に ACE サイクルを実行してみましょう:
   - Claude Code: `/ace-curate` コマンドを実行
   - Copilot / Codex 等: 指示ファイルの ACE 運用ルールに従い「ACEサイクルを実行してください」と指示
```

### （任意）ACE autonomous テンプレートの案内

ユーザーが **マージ後の ACE を subagent + worktree で自動化**したい場合のみ、`${FF_DEV_TOOLKIT_ROOT}/docs-template/05-operations/deployment/ace-autonomous.md` と `${FF_DEV_TOOLKIT_ROOT}/docs-template/scripts/ace/` をコピー先の目安とともに案内する。feature flag（`ACE_SUBAGENT_ENABLED` 等）は**デフォルト無効**で開始することを必ず伝える。

## 参考（任意参照）

- ACE フレームワークの理論的背景・詳細ガイド: <https://github.com/feel-flow/ai-spec-driven-development/blob/develop/docs/ACE_FRAMEWORK.md> / <https://github.com/feel-flow/ai-spec-driven-development/blob/develop/docs/ACE_SETUP.md>（本コマンドは同梱テンプレートのみで完結するため、参照は必須ではない）

## 注意事項

- 既存ファイルがある場合は上書きせず、ユーザーに確認すること
- 配置先ディレクトリが存在しない場合は自動作成すること
- `/ace-curate` は本プラグインが提供するため、コマンドのコピーは不要（Playbook はプロジェクトの `docs/08-knowledge/PLAYBOOK.md` に配置する）
