# ff-dev-toolkit

AI仕様駆動開発（AI-SDD）の公式実装となる Claude Code / Codex プラグイン。ドキュメント初期化から開発進行のゲート管理・影響度評価・クロスモデルレビュー・ナレッジ蓄積までを、Skills / MCP サーバーの組み合わせで統制します。

書籍『AI仕様駆動開発 公式ガイド』第2部（公式実装リファレンス）の対象実装です。方法論そのもの（コア7文書スキーマ・原則）は [ai-spec-driven-development](https://github.com/feel-flow/ai-spec-driven-development) を参照してください。

## インストール

```bash
# マーケットプレイスを登録
claude plugin marketplace add feel-flow/ff-dev-toolkit

# プラグインをインストール
claude plugin install ff-dev-toolkit@ff-dev-toolkit
```

> **⚠️ v0.7.0 で改名しました（旧 `dev-toolkit` → `ff-dev-toolkit`）。** リポジトリ・marketplace・プラグイン名すべてが変わったため、旧版を入れている既存ユーザーは再インストールが必要です:
>
> ```bash
> claude plugin uninstall dev-toolkit@dev-toolkit
> claude plugin marketplace remove dev-toolkit
> claude plugin marketplace add feel-flow/ff-dev-toolkit
> claude plugin install ff-dev-toolkit@ff-dev-toolkit
> ```
>
> Codex CLI / Cowork で利用している場合も同様に、旧プラグインの削除と marketplace の再登録が必要です（手順は各プラットフォームのプラグイン管理 UI / CLI に読み替え）。

### 組織のプラグインディレクトリ（GitHubから同期）で配布する場合

Claude（Web / デスクトップ）の管理画面にある「GitHubから同期」は、**Private / Internal リポジトリのみ**が同期対象です（2026年7月時点。最新の挙動は同ダイアログの注意書きを確認してください）。本リポジトリは Public のため、組織のプラグインディレクトリの同期元として登録できません。

- **個人利用**: 上記の CLI インストールをそのまま使ってください（Public リポジトリのため認証は不要です）
- **組織配布**: 本リポジトリを組織の Private リポジトリとして複製（ミラー）し、そのリポジトリを「GitHubから同期」に指定してください。GitHub では Public リポジトリを Private にフォークできないため、フォークではなく [Import repository](https://github.com/new/import) や `git clone --bare` + `git push --mirror` で複製します。複製後は、本リポジトリの更新を随時ミラーへ反映してください

## 収録内容

### Skills（23）

| スキル | 用途 |
|---|---|
| `spec-driven` | 仕様駆動開発のゲート管理。5ゲート（G0〜G4: 要件→仕様→計画→実装→検証）の通過条件を管理し、ドキュメント先・コード後の開発順序を統制する |
| `harness-review` | エージェントハーネス設計のレビュー。アンチパターンカタログと観点チェックリストに基づく設計評価 |
| `out-of-scope-issue` | スコープ外の発見を `YAGNI（対応も Issue 化もしない）→ 軽微ならインライン修正 → Issue 化` の順で判定。Issue 化前に類似 Issue を検索し、同じ完了条件ならコメントで集約。本文 AC は明示許可と競合確認がある場合だけ最小追記し、独立する場合だけ関連 Issue を作成 |
| `check-plugin-versions` | GitHub・Claude Code 登録・Desktop セッションの版を読み取り専用で照合。更新ありと確認不可を区別する |
| `removal-sweep` | 撤去（機能・設定・UI 要素の削除）PR の残存参照を 3 系統（識別子 / 表示文言 / 構造セレクタ・モック応答）で走査するチェックリスト。E2E がデプロイ済み成果物を指す構成の警告を含む |

以下のワークフロースキルのうち 14 件は v0.15.0 で旧 Commands から Agent Skills 標準へ移行したもので、残りはその後に追加しました（`/ace-refine` は v0.18.0）。Claude Code では `/ff-dev-toolkit:<name>`、Codex では `$ff-dev-toolkit:<name>`、両方で自然文による自動発火を利用できます。

| ワークフロースキル | 用途 |
|---|---|
| `/init-docs` | AI仕様駆動開発のコア7文書 + 拡張フォルダ構造を初期化 |
| `/validate-docs` | ドキュメント構造の検証（必須3文書、残る4文書は未作成なら N/A） |
| `/assess-impact` | 変更の影響度評価 |
| `/create-issue` | 仕様バリデーション付き Issue 作成（種別・優先度ラベルは実在確認のうえ付与） |
| `/refine-issue` | 既存 Issue の仕様精緻化 |
| `/pre-commit-check` | コミット前チェック |
| `/close-issue` | マージ直前の AC 照合ゲート（チェックボックス更新 + 完了報告コメント） |
| `/merge-cleanup` | PR マージ後のクリーンアップ一括実行（base ブランチ復帰・[gone] ブランチ / worktree 削除・リモート取り残しのガード付き自動削除） |
| `/sweep-orphan-transcripts` | 既存の孤児 Claude Code トランスクリプトの一覧・アーカイブ回収（既定 dry-run、`--apply` で実行） |
| `/setup-github-labels` | 推奨ラベル構成の冪等セットアップ（不足分だけ作成・既存ラベルは変更しない・照会を信用できなければ 1 件も作成せず停止） |
| `/ace-setup` | ACE（Agentic Context Engineering）フレームワークのセットアップ |
| `/ace-curate` | マージ済み PR からの知見抽出・プレイブック追記 |
| `/ace-refine` | ACE Playbook の定期整理（stale アーカイブ・長大エントリ圧縮・重複統合）。dry-run → 承認 → 適用の 3 フェーズで原文を保全する |
| `/retrospective` | ワークフローチェーン末尾（`/merge-cleanup` → `/ace-curate` → `/retrospective`）のセッション振り返り。対応ホストでは UserPromptSubmit で応答前に注入し、Stop hook は実行漏れ時だけ継続する（`RETROSPECTIVE_MODE=ask\|off` で制御）。実測した手戻り・無駄時間・Keep・過剰動作を作業中リポジトリの観測台帳（無ければテンプレートから作成）へ記録し、閾値に到達した再発からプロセス/ツール改善を最大 3 件提案（該当なしなら 1 行報告）。起票はユーザー承認後のみ |
| `/setup-ai-config` | AI 開発ツール設定の初期化 |
| `/multi-explore` | マルチAI CLI による並列探索 |
| `/multi-implement` | マルチAI CLI による並列実装 |
| `/multi-review` | マルチAI CLI による並列レビュー |

> **スキル未解決時のフォールバック**: チェーンのスキルが `Unknown skill` で解決できない場合、まず名前を疑う — セッションの利用可能スキル一覧をキーワードで検索して実名を確認し、プレフィックス付き（`<プラグイン名>:<スキル名>`）と無しの両方を試す（両者は別名として共存しうる）。`ListSkills` が返すのは claude.ai 側の別レジストリであり、その空振りを不在の根拠にしない。一覧にも無い場合（インストール済みプラグインが該当スキルの追加より古い）は、プラグインを更新するか、インストール済みプラグインの `skills/<スキル名>/SKILL.md` を直接 Read して手順に従う。それでも解決しない場合は、リポジトリ内の実体（`plugins/<プラグイン名>/skills/<スキル名>/SKILL.md`）とインストール済みプラグインディレクトリの中身を突き合わせる — プラグインが複数ディレクトリへ分割インストールされ、一部スキルが当該セッションのレジストリに載っていないことがある。その場合はリポジトリ側の SKILL.md を読んで手順に従う（スキルが存在しないと結論しない）。

### 旧 Codex standalone copy からの移行

過去の手順で `~/.codex/skills/out-of-scope-issue` をフルコピーしている場合、先に marketplace と plugin を更新し、Codex の新規セッションで `/skills` に `ff-dev-toolkit:out-of-scope-issue` が出ることを確認してください。確認後、旧 standalone copy は drift と重複発火を避けるため削除できます。プラグイン側からユーザー領域を自動削除はしません。

```bash
codex plugin marketplace upgrade ff-dev-toolkit
codex plugin add ff-dev-toolkit@ff-dev-toolkit
```

### MCP サーバー（spec-docs）

対象プロジェクトの `docs/` ツリーを検索・参照する 6 ツール: `search` / `extract_section` / `glossary_lookup` / `list_docs` / `spec_lookup` / `spec_search`

### その他

- `docs-template/` — コア7文書 + 拡張フォルダのテンプレート一式
- `scripts/` — マルチAI CLI オーケストレーション用スクリプト
- `hooks/` — 更新通知・スキル実体ドリフト検査・自動振り返り・Bash ガードのフック（下記）

### プラグインバージョン検査（読み取り専用）

`/ff-dev-toolkit:check-plugin-versions` で、GitHub の `plugin.json` と Claude Code の登録・Claude Desktop の保存済みセッションを比較する。bash 3.2 以降、jq、gh が必要。参照先は `known_marketplaces.json` から解決し、明示 ref/sha は尊重する（固定 ref は default branch の最新を意味しない）。版宣言がない場合は commit の祖先関係で判断し、アクセスできない対象は「確認不可」として残す。更新は実行しない。

Desktop の旧版はローカルの自動更新では解消しないため、Desktop でプラグインを再登録し、新しいセッションで再検査する。保存されたセッションと現在実行中のセッションは区別する。**自己言及の限界**: 古い検査器は自分自身の最新性を保証できない。最新の検査器を使える外部 CLI セッションから Desktop スナップショットを調べる必要がある。既存のリリースタグ更新通知とは独立した検査である。

直接実行する場合は、読み込んだプラグインの `scripts/check-plugin-versions.sh --json` を bash で実行する。終了コード 0 は更新ありを含む検査完了、2 は確認不可を含む部分結果、1 は起動エラー。Codex からも実行できるが、検査対象は Claude の登録形式であり Codex の登録は含まない。

### 更新通知

セッション開始時に本リポジトリの最新リリースタグを確認し、新しいバージョンが公開されていれば通知します（更新コマンドは通知に表示されます）。同じ組み合わせ（使っている版 × 公開されている版）についての通知は 1 日に一度までで、**更新するまで日をまたぐたびに届きます**。更新すれば止まり、さらに新しい版が出れば間隔を待たずに通知します。

- チェック成功の結果は 24 時間キャッシュされます。オフライン時や取得失敗時は何もせず黙ってスキップし（セッション起動を妨げません）、1 時間後に再試行します
- 通知の間隔は環境変数 `FF_DEV_TOOLKIT_UPDATE_TTL_NOTIFIED`（秒・既定 86400）で変更できます。0 を指定すると毎セッション通知します
- 通知を止めたい場合は環境変数 `FF_DEV_TOOLKIT_SKIP_UPDATE_CHECK=1` を設定してください

### マーケットプレイス自動更新

セッション開始時に、登録済みマーケットプレイスの更新（`claude plugin marketplace update` 引数なし）と本プラグイン本体の更新を、バックグラウンド（async）で自動実行します。サードパーティマーケットプレイスは既定では自動更新されないため、この hook を含む版へ一度更新すれば、以降は各自の `autoUpdate` 設定に依存せず最新へ追従します。

- 実行は 1 日 1 回に間引かれます。`claude` CLI が無い環境・オフラインでもセッション起動を妨げません（fail-silent）
- 本体更新の登録 ID（`プラグイン名@marketplace名` 形式）は `claude plugin list` から拾うため、導入経路によるマーケットプレイス登録名の違いを吸収します
- 反映は次回以降のセッション起動時です（Claude Code の仕様）
- 止めたい場合は環境変数 `FF_DEV_TOOLKIT_SKIP_AUTO_UPDATE=1` を設定してください

### スキル実体ドリフト検査

`plugins/<plugin>/skills/` を持つチェックアウト（開発元の marketplace モノレポ）でセッションを開始すると、インストール済みの実体とリポジトリのスキル集合を照合します。配布リポジトリのルート直下 `skills/` レイアウトでは照合対象外として無音です。

- リポジトリにあるスキルがどのインストール実体にも無い場合、またはユニーク version が 2 以上の cache が併存している場合に通知します
- スキル集合が一致し version が 1 種類なら無音です。同一 version の cache と marketplace checkout が並ぶのは通常構成です。version 差だけの 1 実体は上の更新通知に任せます
- インストール実体を 1 つも見つけられないときは「検出不能」と報告し、セッションは止めません
- 古い cache は自動削除しません。`claude plugin marketplace update`（引数なし）→ `claude plugin list` で登録 ID（`プラグイン名@marketplace名` 形式）を確認 → `claude plugin update <確認した ID>` → Claude Code の再起動、の順で追従し、**再起動の後に**通知の古い version ディレクトリだけを手動で削除してください（素の名前を渡すと `Plugin not found` で失敗します）。hook はセッション中ずっと起動時に読み込んだディスク実体を参照するため、再起動より前に削除すると稼働中セッションの hook が壊れます。稼働中の別セッションがロードしている version も削除しないでください。再起動しても既存の会話を再開すると古いスナップショットへ再接続されるため、新しい会話を開始してください。marketplace checkout は消さないでください
- 通知を止めたい場合は環境変数 `FF_DEV_TOOLKIT_SKIP_SKILL_DRIFT_CHECK=1` を設定してください

### 自動振り返り

対応ホストでは、`UserPromptSubmit` hook が `/retrospective` の実行契約を応答前に注入し、通常時は最初の応答内で振り返りを完了する。応答終了時の `Stop` hook は結果が無い実行漏れ時だけ 1 回継続する。継続後はホストの `stop_hook_active` と最終応答の振り返り結果で再入を止めるため、永続 marker は作らない。

- 既定は自動実行。`RETROSPECTIVE_MODE=ask` で実施前確認へ切り替える
- `RETROSPECTIVE_MODE=off` で自動発火を無効にする。`0` / `false` / `no` / `none` / `disabled` も大文字小文字と空白を無視して受け付ける
- Node.js 22 以上が見つからない場合は応答をブロックせず、手動実行と復旧方法を通知する
- 改善提案の Issue 起票は自動化せず、従来どおりユーザー承認後に行う

### Bash ガード（PreToolUse）

プラグインをインストールすると、Bash ツールの実行前に 2 つのガードが自動で有効になる（追加の有効化手順は不要。実体は `hooks/guard-checkout-restore.sh` / `hooks/guard-pr-followup.sh`、登録は `hooks/hooks.json` の `PreToolUse`・`Bash` matcher）。どちらも「実行を許しつつエージェントに警告文を見せる」チャネルが PreToolUse に無いため、**抜け道付きの deny（= その場で対処して再実行できる警告）**として実装している。自身の不具合・解析できないコマンド形では黙って許可に倒れる（fail-open）。

**未コミット変更ガード（`guard-checkout-restore.sh`）** — 未コミット変更のあるファイルへの `git checkout [--] <path>` / `git restore <path>` を検出し、変更消失の前に警告する。警告文は代替手段（`cp` バックアップ / `git stash push -- <file>` → `pop`）を案内する。ブランチ切り替え（`git checkout <branch>` / `git switch`）、clean・untracked なファイルへの復元、`git restore --staged`（worktree 非破壊）では発火しない。

- 意図的に変更を破棄する場合はコマンド先頭に `FF_DISCARD_UNCOMMITTED=1` を付けて再実行する
- 既知の限界: 複合コマンドで `cd` した先の相対パス・空白入りパス・`--pathspec-from-file` は判定できず素通しする（誤ブロックには倒れない）
- 無効化は環境変数 `FF_DEV_TOOLKIT_SKIP_CHECKOUT_GUARD=1`

**PR フォローアップ宣言ガード（`guard-pr-followup.sh`）** — `gh pr create` / `gh pr edit` の PR 本文に「スコープ外」「別Issue」「別対応」「後で対応」「別途」「follow-up」「out of scope」の宣言マーカーがあるのに、Issue 参照（`#<数字>` または GitHub Issue URL）が無い場合に警告する。宣言だけ残して起票しない手戻りを機械的に検出するのが目的で、判定は共起ベースのため誤検出はありうる（だからブロックではなく抜け道付きの警告）。

- 通し方: 先に `gh issue create` で起票して番号を本文へ書く／起票不要の正当な判断は本文に `<!-- no-followup: 理由 -->` を書く
- 判定対象: コマンド文字列全体（heredoc・`--body "..."` を含む）と、hook 実行時点で読める `--body-file <path>` / `-F <path>` の内容
- 既知の限界（判定できず素通しする渡し方）: `--body-file -`（stdin）・プロセス置換・同一コマンド内で生成する一時ファイル・`--fill`・インタラクティブ / web での本文入力
- 無効化は環境変数 `FF_DEV_TOOLKIT_SKIP_PR_FOLLOWUP_GUARD=1`

## 前提

- [Claude Code](https://docs.claude.com/en/docs/claude-code)（プラグインの第一ターゲット。Codex CLI / Claude Cowork / grok CLI / GitHub Copilot CLI も Claude 形式 marketplace 互換で利用可。詳細は下記「他のツールで使う」）
- Perl（共有版 claim と CHANGELOG の不可視 Unicode 検査・exact-path hard link に必要。macOS/多くの Linux に同梱）
- Node.js >= 22（MCP サーバー spec-docs の実行に必要。18/20 は EOL のためサポート外）
- マルチAI CLI オーケストレーション（`/multi-*`）を使う場合のみ: Codex CLI / Grok CLI / Copilot CLI のいずれか（オプション。Copilot CLI は `/multi-review` では従量課金のためオプトイン）

## 他のツールで使う

| 環境 | 利用方法 |
|------|----------|
| Claude Code | 上記「インストール」（第一ターゲット） |
| Codex CLI / Claude Cowork | Claude 形式 marketplace を登録して install（CLI / UI は各製品の手順に読み替え） |
| grok CLI | Claude 形式 marketplace を登録して install（v0.2.118 で実機検証済み）:<br>`grok plugin marketplace add feel-flow/ff-dev-toolkit`<br>`grok plugin install ff-dev-toolkit@feel-flow/ff-dev-toolkit` |
| GitHub Copilot CLI | Claude 形式 marketplace を登録して install（v1.0.75 で実機検証済み）:<br>`copilot plugin marketplace add feel-flow/ff-dev-toolkit`<br>`copilot plugin install ff-dev-toolkit@ff-dev-toolkit`<br>導入したスキルは `copilot skill list` の Plugin skills に並ぶ |
| **VS Code + GitHub Copilot** | marketplace の plugin install は不可（IDE 拡張。上記 Copilot **CLI** とは別経路）。`.github/copilot-instructions.md` と `docs/` で方法論を効かせる → **[USING_WITH_VSCODE_COPILOT.md](./USING_WITH_VSCODE_COPILOT.md)** |

grok / Copilot CLI で確認したのは marketplace 登録 → インストール → コンポーネントの認識まで（2026-08-02 実測。上記コマンドのとおり本リポジトリ `feel-flow/ff-dev-toolkit` から直接導入して確認）。スキルの実行・hooks の発火・MCP サーバーの起動は未検証。

## バージョンと書籍からの参照

書籍からの参照はリリースタグで固定されます。最新の安定版は [Releases](https://github.com/feel-flow/ff-dev-toolkit/releases) を参照してください。

バージョンごとの変更内容は [CHANGELOG.md](./CHANGELOG.md) を参照してください。

## 開発とフィードバック

本リポジトリは FeelFlow 内部リポジトリ（SSOT）からの一方向同期で更新されます。バグ報告・改善要望は本リポジトリの Issue で受け付けます。

## ライセンス

[Apache License 2.0](./LICENSE)

Copyright 2026 FeelFlow Inc.
