# ff-dev-toolkit 公開面（Public Surface）

このファイルは、ff-dev-toolkit が**互換性を約束する対象**（契約）と、**予告なく変えてよい実装詳細**（内部）の境界の正本です。導入先から読めるように配布物へ同梱しています。

対象は 5 系統 — Skills の起動名 / Hooks / 導入先に配置されるパス / 環境変数 `FF_*` / `FF_` で始まらない環境変数。いずれも「契約」と「内部」を区別して列挙します。

## 契約と内部

| 区分 | 意味 | 変えたときの扱い |
| --- | --- | --- |
| **契約** | 導入先が名前で依存できる要素 | 削除・改名・意味の変更は**破壊的変更**。CHANGELOG の `### 破壊的変更` 節へ記録する |
| **内部** | 実装詳細。スクリプト内のローカル変数、テストハーネスの注入口、配布物どうしの受け渡し値 | 予告なく変えてよい。破壊的変更として記録しない |

1.0.0 より前（0.x）の版では、ここで言う「破壊的変更」は**記録の規約**で、破壊的変更を含む版も minor で上げます。1.0.0 以降は**バージョン番号の規約**にもなり、契約の破壊的変更を含む版で major を上げます（内部の変更では major を上げません）。1.0.0 以降に契約の要素を削除する（改名で旧名を消す場合を含む）ときは、最低 1 つ前のマイナー版で CHANGELOG の `### 変更` 節に「次の major で削除予定」と予告し、予告した版では旧名の受け入れを残します。予告なしには削除しません。1.0.0 を宣言してよい条件は、開発元リポジトリのアーキテクチャ決定記録（ADR）に置いてあります。

## 網羅の定義（`FF_*`）

`FF_*` の母集団は、配布物に現れる `FF_` で始まる大文字・数字・アンダースコアの語です。

- 走査対象: `plugins/ff-dev-toolkit/` 配下と、公開リポジトリのルートへ同期される `oss/ff-dev-toolkit/` 配下
- 走査対象から外すもの: 本ファイル自身（自分で自分を正当化しないため）と `oss/ff-dev-toolkit/CHANGELOG.md`（過去の版の記録に残る、すでに存在しない名前を母集団へ持ち込まないため）
- 語の切り出しは純粋に字句的です。そのため `FF_MULTI_AGENT` / `FF_TIMEOUT` のように**環境変数名の接頭辞**として書かれた語も母集団に入ります。これらは内部に分類しています
- `FF_` で始まらない環境変数は字句では境界を引けないため、母集団の決め方が別です。「公開面 5」を参照してください

**母集団のすべてが下の 4-1 か 4-2 のどちらかに載っていること**は機械検査が担保します（未分類 0 件）。

## `FF_*` の判定規則

次の 2 つを**両方**満たす名前だけが契約です。

1. **公開されている** — 公開 README、`plugins/ff-dev-toolkit/mcp/README.md`、`plugins/ff-dev-toolkit/docs-template/` 配下、`plugins/ff-dev-toolkit/skills/*/SKILL.md` のいずれかに現れる
2. **配布実行物が読む** — `plugins/ff-dev-toolkit/hooks/`、`plugins/ff-dev-toolkit/scripts/`、`plugins/ff-dev-toolkit/mcp/src/`、`plugins/ff-dev-toolkit/tests/run-all.sh` のいずれかに現れる

**この連言は機械検査がそのまま実行します** — 4-1 の集合は「1 の集合 ∩ 2 の集合」と一致していなければ赤になります。したがって片方だけのものは内部であり、例外を個別に足すことはできません。

片方だけになるのは次の 2 種類です。いずれも、こちら側の改名で導入先の資産が壊れないため内部です。

- **導入先がコピーして所有するスニペット**の中だけで完結する名前（CI ワークフロー例・hook の bootstrap 例で使う `FF_DEV_TOOLKIT_REF` / `FF_REVIEW_OUTPUT` / `FF_TOOLKIT_MANIFEST` / `FF_TOOLKIT_SCRIPTS` / `FF_TOOLKIT_SIDECAR`）
- **AI host が渡すだけで配布実行物が読まない値**（`FF_DEV_TOOLKIT_PROJECT_ROOT` / `FF_DEV_TOOLKIT_ROOT_SOURCE`）。前者は `SKILL.md` の fence が CWD と突き合わせる値、後者は診断用の provenance で、配布文書自身が「resource 選択や fallback の分岐には使わない」と述べています。値の受け渡しを指示する `SKILL.md` は配布物と同じコミットで配られるため、改名は導入先の資産に波及しません

契約を増やしたいときは、**先に 1 と 2 を満たす形にしてから**この一覧へ足してください。文書化していない名前も、配布実行物が読まない名前も、契約になりません。

## 公開面 1: Skills

起動名（`/ff-dev-toolkit:<name>` / `$ff-dev-toolkit:<name>` / 自然文発火）はすべて契約です。内部扱いの skill はありません。

- `ace-curate`
- `ace-refine`
- `ace-setup`
- `asdd-init`
- `asdd-work`
- `assess-impact`
- `check-plugin-versions`
- `close-issue`
- `create-issue`
- `gh-auth-doctor`
- `harness-review`
- `init-docs`
- `knowledge-lookup`
- `merge-cleanup`
- `multi-explore`
- `multi-implement`
- `multi-review`
- `observation-refine`
- `out-of-scope-issue`
- `pre-commit-check`
- `refine-issue`
- `removal-sweep`
- `retrospective`
- `setup-ai-config`
- `setup-github-labels`
- `spec-driven`
- `sweep-orphan-transcripts`
- `validate-docs`
- `workflow-doctor`

## 公開面 2: Hooks

### 2-1. 契約（`hooks/hooks.json` が登録する入口）

導入先のセッションで発火する入口です。削除・改名・**発火イベントの変更**は破壊的変更です。そのため一覧は `発火イベント :: matcher :: 実体` の三つ組で持ちます（matcher を持たないイベントは `-`）。実体のファイル名だけを並べると、同じ実体を別イベントへ付け替える変更が集合として不変になり、検査が素通りします。

- `PermissionDenied :: - :: hooks/guard-review-in-flight.sh`
- `PostToolUse :: Bash :: hooks/guard-zsh-glob.sh`
- `PostToolUse :: Bash :: hooks/warn-missing-ff-effort.sh`
- `PreToolUse :: Bash :: hooks/guard-background-cwd.sh`
- `PreToolUse :: Bash :: hooks/guard-checkout-restore.sh`
- `PreToolUse :: Bash :: hooks/guard-credential-output.sh`
- `PreToolUse :: Bash :: hooks/guard-effort-actual.sh`
- `PreToolUse :: Bash :: hooks/guard-merge-closing-keyword.sh`
- `PreToolUse :: Bash :: hooks/guard-exit-code.sh`
- `PreToolUse :: Bash :: hooks/guard-issue-labels.sh`
- `PreToolUse :: Bash :: hooks/guard-literal-write.sh`
- `PreToolUse :: Bash :: hooks/guard-long-gate-background.sh`
- `PreToolUse :: Bash :: hooks/guard-pr-followup.sh`
- `PreToolUse :: Bash :: hooks/guard-sub-issue-id.sh`
- `PreToolUse :: Bash :: hooks/guard-wsl-shell.sh`
- `PreToolUse :: Bash :: hooks/guard-zsh-glob.sh`
- `PreToolUse :: Bash :: hooks/record-effort-wallclock.sh`
- `PreToolUse :: Bash :: hooks/run-bash-hooks.sh`
- `PreToolUse :: Edit|Write|MultiEdit|NotebookEdit|Bash|Agent|Task|TaskStop :: hooks/guard-review-in-flight.sh`
- `PreToolUse :: Read|Skill :: hooks/record-instruction-bytes.sh`
- `PreToolUse :: Write|Edit :: hooks/guard-shell-save.sh`
- `PreToolUse :: ^mcp__(github|plugin_github_github)__(create_pull_request|update_pull_request)$ :: hooks/guard-pr-followup.sh`
- `PreToolUse :: ^mcp__(github|plugin_github_github)__issue_write$ :: hooks/guard-issue-labels.sh`
- `PreToolUse :: ^mcp__(github|plugin_github_github)__merge_pull_request$ :: hooks/guard-effort-actual.sh`
- `PreToolUse :: ^mcp__(github|plugin_github_github)__sub_issue_write$ :: hooks/guard-sub-issue-id.sh`
- `SessionStart :: * :: hooks/auto-update-marketplace.sh`
- `SessionStart :: * :: hooks/check-review-roster-drift.sh`
- `SessionStart :: * :: hooks/check-skill-drift.sh`
- `SessionStart :: * :: hooks/check-update.sh`
- `Stop :: - :: hooks/decision-tree.sh`
- `Stop :: - :: hooks/retrospective-stop.sh`
- `SubagentStart :: - :: hooks/guard-review-in-flight.sh`
- `SubagentStop :: - :: hooks/guard-review-in-flight.sh`
- `UserPromptSubmit :: - :: hooks/decision-tree.sh`
- `UserPromptSubmit :: - :: hooks/retrospective-context.sh`

`^mcp__` で始まる 4 本は、GitHub MCP の同じ操作（PR のマージ・Issue の起票・sub-issue の追加・PR の作成 / 更新）に Bash 経路と同じガードを当てる Claude Code 向けの登録で、ガードごとに 1 本ずつ別の matcher を持つ（PR の作成 / 更新の 2 ツールは 1 本を共有。Codex / grok では MCP 呼び出しの `tool_name` と発火が未実測のため保証しない）。

Bash 専用の14実体は `hooks/run-bash-hooks.sh` が同一イベント内で並行実行する。`hooks.json` の command 引数へ各実体を明記し、上記のイベント・matcher・判定契約を維持する。ホストへの起動登録は1本になり、警告を全件結合し、拒否を確認・許可より優先する。

子の処理枠は10秒（Windows の Git Bash＝MSYS / Cygwin ではプロセス起動が重いため25秒）、親の登録枠は集約の余裕を含め30秒とする。時間切れの子と不正な出力は診断して除外し、完了した他の判定を残す。時間切れの診断行は stderr に出し、終了コード2以外の回は同じ文面を集約 JSON の `systemMessage` と `hookSpecificOutput.additionalContext` へ1回ずつ足す（拒否時の未実行注記と同じく、ホストが届ける JSON に載せて黙って捨てない。終了コード2の回は stderr の診断行だけで届け、JSON へは重ねない）。時間切れだけでは新たな拒否にしない。集約自体の環境エラーは新たな拒否にせず、子の終了コード2だけをブロックとして伝播する。終了コード2と他の拒否が重なる場合は、他の拒否理由も stderr へ残す。

拒否したとき（`deny` を返した子がある、または子が終了コード2で止めた）は、理由文の末尾に「この呼び出しは 1 つも実行されておらず、前段で作るつもりだったファイル・書き込みも存在しない。生成とガードに当たる反映を別の呼び出しに分けて再実行する」旨の1行を1回だけ足す。JSON の拒否では `permissionDecisionReason` の最終行、終了コード2では stderr の最終行に置く。確認・許可・警告だけのときは足さない。

### 2-2. 内部（入口から呼ばれる実装）

`hooks.json` に登録されておらず、上の入口や ASDD の設定から呼ばれる実装です。直接呼ぶ前提の要素ではないため、予告なく変わります。

- `hooks/asdd-feature.mjs`
- `hooks/asdd-hook-gate.sh`
- `hooks/retrospective-chain-tail.mjs`
- `hooks/private-session-log.py`

## 公開面 3: 導入先に配置されるパス

導入先のリポジトリの**決め打ちのパス**に置かれ、配布物の手順やスクリプトがそのパスを名前で指すものです。パスが変わると導入先の規約（`bash scripts/codex-review.sh` など）や toolkit 側の読み取りが壊れるため契約に含めます。中身の更新は破壊的変更ではありません。

置く主体は一様ではありません — 配布スクリプトが置くもの、skill が生成するもの、**利用者が任意で置き toolkit が在れば読むもの**が混ざります。列に明記します。

| パス（導入先から見た相対パス） | 置く主体 | 役割 |
| --- | --- | --- |
| `scripts/codex-review.sh` | `scripts/setup-multi-agent.sh` が配置する | クロスモデルレビューの入口シム（単一ファイル配布） |
| `<解決済みPLAYBOOKの親>/PENDING_CANDIDATES.md` | `/ace-curate` が容量停止時に生成する | 採用前候補の永続store。通常ACEの件数へ混ぜず、lookupがpendingとして検索する。不在時は未作成のまま |
| `scripts/.ff-dev-toolkit-root` | `scripts/setup-multi-agent.sh` が配置する | シムがオーケストレータを解決するためのサイドカー（Git 管理しない） |
| `.claude/agent-config.yaml` | **利用者が任意で置く**（`scripts/setup-multi-agent.sh` はファイルを置かない。既定のままなら不要で、変えたいキーがあるときだけそのキーを書いた最小のファイルを置くよう案内する） | レビュー担当・CLI 構成のプロジェクト上書き。在れば同梱の既定より優先して読まれる |
| `docs/MASTER.md` | `init-docs` / `asdd-init` が生成する | 仕様文書の入口。`validate-docs` が名前で参照する |
| `docs/01-context/PROJECT.md` | 同上 | コア文書 |
| `docs/02-design/ARCHITECTURE.md` | 同上 | コア文書 |
| `docs/03-implementation/CONVENTIONS.md` | 同上 | コア文書 |
| `docs/04-quality/TESTING.md` | 同上 | コア文書 |
| `docs/05-operations/DEPLOYMENT.md` | 同上 | コア文書 |
| `docs/06-reference/DECISIONS.md` | 同上 | コア文書 |
| `docs/08-knowledge/PLAYBOOK.md` | `init-docs` / `ace-setup` が生成する | ACE のナレッジ台帳の入口 |
| `docs/08-knowledge/playbook/` | `ace-setup` が生成する | カテゴリ別台帳の置き場 |
| `docs/08-knowledge/knowledge-delivery.conf` | **利用者が任意で置く**（無ければマージごと = 既定。default branch にコミットした値だけを読む） | 知見の反映モード（`mode=per-merge` / `batch`・`staging_branch`・`warn_after_days`）。`batch` では `knowledge-commit` が知見を `staging_branch`（既定 `knowledge/staging`）へ書き、`flush` が base へ反映する（使い捨てブランチは `knowledge/flush-*`） |

**内部（配置はされるが、パスを固定しない）**:

- `docs/` の初期セットのうちコア文書以外（`01-context/CONSTRAINTS.md` / `02-design/DOMAIN.md` / `02-design/API.md` / `02-design/DATABASE.md` / `03-implementation/PATTERNS.md` / `03-implementation/INTEGRATIONS.md` / `03-implementation/DECISION_TREE.md` / `03-implementation/FALLBACK.md` / `03-implementation/ERRORS.md` / `04-quality/VALIDATION.md` / `06-reference/GLOSSARY.md` / `07-project-management/ROADMAP.md` / `07-project-management/TASKS.md` / `07-project-management/RISKS.md`）— 生成後は導入先の資産で、toolkit は名前で固定しません
- `scripts/ace/` の検査スクリプト — 配置は任意で、未配置なら同梱ランナー経由で同じ検査を実行します。したがって導入先が依存する固定パスではありません

配布物の側のパス（`plugins/ff-dev-toolkit/scripts/` などの同梱物の位置）は、導入先が直接呼ぶ入口だけが契約です。導入先は skill 経由か、上のシム経由で到達します。

GitHub取得のraw file受渡しは明示argv `--github-input` で選び、新しい `FF_*` 設定は増やしません。precheck/link/cleanupのscope・phaseと待機契約は [merge-gate](skills/close-issue/references/merge-gate.md#github-file-input)、knowledge取得のscope・phaseは [knowledge suite](tests/github-input-knowledge/README.md) を参照します。SSOT root の release・release-required・sync-drift・weekly-health 入口も同じ明示入力を持ち、その段別 phase / page / 採用 run log は [release 対応表](tests/github-input-release/README.md) に従います。root の4入口は公開同期対象外で、内部 `--github-phase` は file 入力時の閉集合だけです。内部helperの公開関数は `github_file_read` / `github_file_plan` の2本で、Git文脈の期待repositoryを得るprivate utilityは内部実装です。

## 公開面 4: 環境変数 `FF_*`

### 4-1. 契約

#### プラグイン root と skill の受け渡し（AI host / 導入先 CI が設定し、配布実行物が読む）

- `FF_DEV_TOOLKIT_ROOT`
- `FF_DEV_TOOLKIT_SKILL_FILE`

#### hooks の無効化・承認の抜け道

利用者が書く宣言（L4 宣言）は 2 種類です。鍵の正本は `scripts/lib/l4-declarations.tsv` の名簿で、鍵の一覧は下の 4-3 にあります。

- **止める宣言（SKIP）**: 1 つの変数 `FF_DEV_TOOLKIT_SKIP` に、4-3 の鍵をカンマで並べて書きます（例 `FF_DEV_TOOLKIT_SKIP=zsh-glob,update-check`）。プロセスの環境（ホストの env 設定・shell の rc・CI の環境）に置き、そのセッションの間ずっと効きます。値は小文字・数字・`-` の鍵をカンマで区切った形だけを受け付け、空白区切り・大文字・空の要素・前後のカンマを含む値は、値全体を未設定として扱います（ガードは効いたまま）。すべてを止める鍵（`all`）は置きません
- **1 回だけ通す承認（ACK）**: `FF_` + 鍵を大文字・`_` 区切りにしたもの + `_ACK` の型（例 `FF_ZSH_GLOB_ACK=1`）で、その呼び出しだけを通します。置き場所（コマンドの先頭・区間の先頭・hook のプロセス環境）は ACK ごとに決まっていて、下の各行と各 hook の停止文が示します

- `FF_DEV_TOOLKIT_SKIP`（止める宣言。鍵の一覧と包含は 4-3）
- `FF_DISCARD_UNCOMMITTED_ACK`（`hooks/guard-checkout-restore.sh` で、未コミット変更のあるファイルへの `git checkout` / `git restore` の 1 回だけを通すコマンド先頭の環境代入）
- `FF_EFFORT_ACTUAL_ACK`
- `FF_MERGE_CLOSING_ACK`
- `FF_EXIT_CODE_ACK`
- `FF_TIMEOUT_ACK`（`hooks/guard-exit-code.sh` で、command -v で見つからない timeout / gtimeout の停止だけを通すコマンド先頭の環境代入）
- `FF_UNBOUNDED_WAIT_ACK`（同 hook で、背景実行の上限の無い sleep 待ちの停止だけを通す。until / while の前は独立した文 `FF_UNBOUNDED_WAIT_ACK=1;` とする）
- `FF_RG_STDIN_ACK`（同 hook で、検索パスの無い rg が標準入力を待ち続ける形の停止だけを通すコマンド先頭の環境代入。先頭に並ぶ代入のどれでもよい）
- `FF_CREDENTIAL_OUTPUT_ACK`
- `FF_ISSUE_LABEL_ACK`（`hooks/guard-issue-labels.sh` で、ラベルの欠けた `gh issue create` の 1 回だけを通すコマンド先頭の環境代入。セッションの間ずっと止めるときは鍵 `issue-label`）
- `FF_LITERAL_WRITE_ACK`
- `FF_LONG_GATE_BACKGROUND_ACK`
- `FF_PR_DRAFT_ACK`（`hooks/guard-pr-followup.sh` の Draft PR 検出だけを通すコマンド先頭の環境代入。GitHub MCP 経路では hook の環境変数として読み、セッション全体の GitHub MCP 呼び出しに効く）
- `FF_SHELL_SAVE_ACK`（`hooks/guard-shell-save.sh` の抜け道。Write / Edit にはコマンド先頭の環境代入が無いので、hook のプロセス環境で渡す）
- `FF_SUB_ISSUE_ID_ACK`
- `FF_WSL_SHELL_ACK`
- `FF_ZSH_EXPANSION_ACK`
- `FF_ZSH_GLOB_ACK`
- `FF_REVIEW_LOCK_ACK`（`hooks/guard-review-in-flight.sh` で、レビュー走行中ロックの deny の 1 回だけを通す。Bash では区間の先頭の環境代入、Bash 以外のツールでは hook のプロセス環境で渡す）
- `FF_REVIEW_ROUND_ACK`

#### hooks の閾値・対象

- `FF_EXIT_CODE_GUARD_GATES`（終了コードガードへ追加する導入先ゲート。改行区切りの literal command prefix。hook プロセスの環境へ export する。未設定時は既定互換）

- `FF_DEV_TOOLKIT_STATE_DIR`（工数の実測記録と finish.sh cleanup のログの親。既定 `$HOME/.config/ff-dev-toolkit`）
- `FF_DEV_TOOLKIT_UPDATE_TTL_NOTIFIED`
- `FF_LONG_GATE_FOREGROUND_TIMEOUT_MS`
- `FF_REVIEW_ROUND_LIMIT`（レビュー巡回の上限。既定 2、0 で無効）
- `FF_REVIEW_SUBAGENT_LOCK_MAX_AGE_SECONDS`
- `FF_REVIEW_SUBAGENT_LOCK_PENDING_SECONDS`
- `FF_REVIEW_SUBAGENT_LOCK_TYPES`

#### skill が呼ぶスクリプトの設定

- `FF_ACE_TS_RUNNER`
- `FF_DEV_TOOLKIT_SKIP`（上の節と同じ変数。鍵 `codex-auto-update` で `multi-agent.sh` が dispatch 前に古い codex-cli を自動更新するのを止め、鍵 `commit-identity` で定型コミット（knowledge など）を作るスクリプトが、検査用の合成 git identity のままのコミットを止める判定を外す）
- `FF_JEV_MODE`
- `FF_JEV_POINTS`
- `FF_PRINCIPLES_GLOB`
- `FF_DELETE_PUSH_SKIP_HOOKS`（削除 push のフック回避。未設定と `1` は `SKIP_SIMPLE_GIT_HOOKS=1 HUSKY=0`。`0` は consumer の hook を残す）
- `FF_MERGE_CLEANUP_IGNORE_PATHS`
- `FF_MERGE_CLEANUP_MERGED_PR_LIMIT`
- `FF_MERGE_CLEANUP_PROJECTS_DIR`
- `FF_MERGE_CLEANUP_PROTECT_BRANCHES`
- `FF_MERGE_CLEANUP_TRANSCRIPTS`
- `FF_MERGE_CLEANUP_TRANSCRIPT_ARCHIVE_DIR`
- `FF_MERGE_DELETE_SEPARATE`（`1` のとき `finish.sh precheck` は `gh pr merge` だけを出し、ブランチ削除を付けない。未設定と `0` は従来どおり）
- `FF_MULTI_AGENT_IGNORE_PATHS`
- `FF_MULTI_AGENT_LOAD_PER_CORE`（`multi-agent.sh` がレーン起動前に load average と比べる閾値の係数。閾値は論理コア数 × 係数、既定 10、`0` で負荷判定を無効化）
- `FF_POST_MERGE_PATHS`（`finish.sh precheck` のマージ後工程の判定で見るパス。`:` 区切りの glob。`FF_POST_MERGE_TERMS` と対で設定し、両方未設定なら判定しない）
- `FF_POST_MERGE_TERMS`（同じ判定で見る語。`:` 区切りの文字どおりの部分一致で、英字の大文字小文字は区別しない）
- `FF_SWEEP_ARCHIVE_DIR`
- `FF_SWEEP_PROJECTS_DIR`

#### 全件ゲート

- `FF_RUN_ALL_FULL`

### 4-2. 内部

予告なく改名・削除します。導入先の設定へ書かないでください。

#### 4-2-1. `plugins/ff-dev-toolkit/tests/` の中だけに現れるもの

テストハーネスと fixture の注入口です。全件ゲート `tests/run-all.sh` のスイッチのうち、公開文書に載っていないものもここに含みます。suite が組み立てる fixture の中でしか使われない名前（`FF_FIXTURE_*` など）も、suite のソースが配布物に含まれる以上は母集団に入るため、ここへ載せます。

- `FF_AGENTS_HITS`
- `FF_ALLOW_DISPATCH_BRANCH`
- `FF_AMBIENT_GITHUB_ACTIONS`
- `FF_ASDD_DRAIN_OUT`
- `FF_ASDD_DRAIN_RC`
- `FF_ASDD_GATE_RC`
- `FF_ASDD_SKIP_MARKER`
- `FF_AUTOFIRE_HEADING`
- `FF_BAD_ROOT`
- `FF_BASE_GUARD_STUB_URL`
- `FF_CHANGELOG_PUBLIC_REFERENCES_FILE`
- `FF_CHANGELOG_PUBLIC_TAGS_FILE`
- `FF_CHANGELOG_PUBLIC_TAGS_REPO_URL`
- `FF_CHANGELOG_TEST_REMOTE`
- `FF_CHECK_WEEKLY_RELAX`
- `FF_CHG_FILES`
- `FF_CHG_TESTS_DIR`
- `FF_CHG_TESTS_PREFIX`
- `FF_CKSUM_COUNT`
- `FF_CR`
- `FF_CURL_RC`
- `FF_CURL_SENTINEL`
- `FF_CURSOR_TIMEOUT_CAP`
- `FF_DECOY_LIST`
- `FF_DEV_TOOLKIT_GUARD`
- `FF_DEV_TOOLKIT_SKIP_FIXTURE_GUARD`
- `FF_DOCS_AWK_STRIP_CR`
- `FF_DOCS_CLAIMS`
- `FF_DOCS_GATE_STOP_AFTER`
- `FF_DOCS_NUM_ERE`
- `FF_DOCS_REL`
- `FF_DOCS_GATE_DOCS`
- `FF_DOCS_GATE_RUNTIME_DOCS`
- `FF_DOCS_REPO_ROOT`
- `FF_DOCS_SCAN_LIB`
- `FF_DOCS_TEMPLATE_ROOT`
- `FF_ENTERED_NESTED`
- `FF_EXIT_CODE_AWK`
- `FF_EXIT_CODE_GIT`
- `FF_FIXTURE_CONTRACT`
- `FF_FIXTURE_GHOST`
- `FF_FIXTURE_HALF`
- `FF_FIXTURE_INTERNAL`
- `FF_FIXTURE_KILL_PARENT`
- `FF_FIXTURE_LIB_ONLY`
- `FF_FIXTURE_NEW`
- `FF_FIXTURE_PART`
- `FF_FIXTURE_SEAM`
- `FF_FROM`
- `FF_GATE_RECORD`
- `FF_GATE_START_BRANCH`
- `FF_GATE_START_EPOCH`
- `FF_GATE_START_HEAD`
- `FF_GH_STUB`
- `FF_GOOD_ROOT`
- `FF_GUARD_SCRIPT`
- `FF_GUARD_SHELL_SAVE_LIB_DIR`
- `FF_GUARD_SHELL_SAVE_TARGET`
- `FF_HD_CMD`
- `FF_HEREDOC_AWK`
- `FF_HOST_ROOT`
- `FF_JOBS_CAP`
- `FF_JOBS_LIMIT`
- `FF_LEX_AWK`
- `FF_LITERAL_WRITE_AWK`
- `FF_LW_PRESET`
- `FF_MBCS_AWK`
- `FF_MBCS_GIT`
- `FF_MEDIA_NODE`（公開リリースの隔離 fixture が ff-media-toolkit 実行器を制御するための参照）
- `FF_MEDIA_RENDER`（ff-media-toolkit の実レンダリング opt-in。`sync-sha-contract` がリリース gate の許容表の理由文として参照するだけで、配布物は読まない）
- `FF_MULTI_AGENT`
- `FF_M`
- `FF_NEEDLE`
- `FF_NODE_ROOT_GUARD_QUIET`
- `FF_NODE_TEST_AWK`
- `FF_NODE_TEST_GIT`
- `FF_NO_SUCH_ACK`
- `FF_NOT_IN_HOOK`
- `FF_NPM_LOG`
- `FF_NPM_RC`
- `FF_PARITY_REGISTRY`
- `FF_PIPEFAIL_GREP_Q_AWK`
- `FF_PIPEFAIL_GREP_Q_GIT`
- `FF_PLUGIN_DESC_EXEMPTIONS`
- `FF_PLUGIN_DESC_GREP`
- `FF_PLUGIN_DESC_NON_ENUM`
- `FF_PLUGIN_DESC_ROOT`
- `FF_POLL_INTERVAL`
- `FF_PROBE_LOCALE_CMD`
- `FF_KNOWLEDGE_LOOKUP_PRIVACY_ONLY`（knowledge-lookup suite の独立した変異試験専用。run-all 内では拒否）
- `FF_READ_KEY`（私有snapshot cacheの内部照合と元入力の表示label）
- `FF_READ_LABELS`（私有snapshotと表示用パスの内部対応）
- `FF_READ_STAMP`（私有snapshot cacheの内部metadata照合）
- `FF_TEST_SHELL_CAPTURE`（shell hookの単一置換を私有before/afterで検査する出力先）
- `FF_PUBLIC_LAYOUT_SUITES`
- `FF_RUN_ALL`
- `FF_RUN_PUBLIC_LAYOUT`
- `FF_P`
- `FF_REACHED_END`
- `FF_REAL_CKSUM`
- `FF_RELEASE_CHECK_PUBLIC`
- `FF_RELEASE_CHECK_PUBLIC_URL`（`/pre-commit-check` の断片帰属照合が公開側 clone の無い回に最新タグを引く公開リポジトリの URL。既定は ff-dev-toolkit の公開リポジトリ）
- `FF_RELEASE_GATE_HEAD`（リリースのゲートで鮮度検査に渡す固定済みの SHA）
- `FF_RETRO_PROFILE`
- `FF_RETRO_SELFTEST_JOBS`
- `FF_RG_STDIN_AWK`
- `FF_RUN_ALL_ALLOW_DIRTY`
- `FF_RUN_ALL_ALLOW_MISSING_MCP_DEPS`
- `FF_RUN_ALL_CHANGED`
- `FF_RUN_ALL_CHECK_REGISTRATION`
- `FF_RUN_ALL_DUMP_DECLARATIONS`
- `FF_RUN_ALL_ELAPSED_FIXTURE`
- `FF_RUN_ALL_ELAPSED_RECORD`（並列実行の起動順に使う suite 別経過秒の記録のパス。明示引数の実行はこれを与えたときだけ並べ替える）
- `FF_RUN_ALL_ELAPSED_NEW`（起動順の記録を書き直す awk へ、今回 pass した suite の秒数を渡す内部変数）
- `FF_RUN_ALL_LAUNCH_NAMES`（起動順を組み立てる awk へ suite 名の一覧を渡す内部変数）
- `FF_RUN_ALL_FAST`
- `FF_RELEASE_IN_FLIGHT_MAX_AGE`
- `FF_RUN_ALL_JOBS`
- `FF_RUN_ALL_LOAD_SAMPLE`（起動時負荷の検査用注入口）
- `FF_RUN_ALL_MCP_DIR`
- `FF_RUN_ALL_MCP_NODE_MODULES`
- `FF_RUN_ALL_NESTED`
- `FF_RUN_ALL_PROBE_LOG`
- `FF_RUN_ALL_PROBE_RENDEZVOUS`
- `FF_RUN_ALL_VERIFY_STOP_AFTER_GUARD`（tests/run-all/verify.sh が並走判定の直後で走査を始めず終わる検査用注入口。`1` のときだけ）
- `FF_STARTUP_CORES`（以下はrunnerの起動時観測を保持する内部変数）
- `FF_STARTUP_LOAD`
- `FF_STARTUP_LOAD_PER_CORE`
- `FF_STARTUP_OTHER_GATES`
- `FF_STARTUP_PRESSURE`
- `FF_STARTUP_REPORT`
- `FF_STARTUP_THRESHOLD`
- `FF_SCRIPT_ROOT_GUARD_QUIET`
- `FF_SELFMUT_TARGET`
- `FF_SELF_FINGERPRINT_START`
- `FF_SETUP_APT_GET`
- `FF_SETUP_CURL`
- `FF_SETUP_IS_ROOT`
- `FF_SETUP_LOCALE_CMD`
- `FF_SETUP_NPM`
- `FF_SETUP_OS`
- `FF_SETUP`
- `FF_SHA_RC`
- `FF_SKILLS_DIR`
- `FF_SKILL_COUNT_ROOT`
- `FF_STALE_MARKER`
- `FF_STALE_ROOT`
- `FF_STUB_BODY`
- `FF_STUB_CLAUDE_RC`
- `FF_STUB_CODEX_HELP`
- `FF_STUB_DIR`
- `FF_STUB_FAIL`
- `FF_STUB_GET_FAIL`
- `FF_STUB_GH_MODE`
- `FF_STUB_LABELS_MODE`
- `FF_STUB_LABELS`
- `FF_STUB_OUTPUT_DIR_SENTINEL`
- `FF_STUB_REPORT_FIXTURE`
- `FF_STUB_REPORT_MODE`
- `FF_STUB_REVIEW_RC`
- `FF_STUB_SENTINEL`
- `FF_STUB_SUBJECT`
- `FF_SUITE_OUTPUT`
- `FF_SURFACE_BASE_REF`
- `FF_SYNC_SHA_RELEASE_SCRIPT`
- `FF_SYNC_SHA_SCRIPT`
- `FF_SYNC_SHA_SKILL`
- `FF_TEST_CODEX_COUNT`（委譲レビュー検査の CLI stub 起動数ファイル）
- `FF_DEV_TOOLKIT`（環境変数の隔離で使う字句的接頭辞）
- `FF_TEST`（fixture用環境変数の字句的接頭辞）
- `FF_TEST_CORES`
- `FF_TEST_GATE_ROOT`
- `FF_TEST_PROCESS_MODE`
- `FF_TEST_READY`
- `FF_TEST_RELEASE`
- `FF_TEST_MODEL_SET`
- `FF_TEST_MODEL_UNSET`
- `FF_TEST_MODE`
- `FF_TEST_PATH_PREFIX`
- `FF_TEST_STUB_PAYLOAD`
- `FF_TIMEOUT_REASON_EXIT_TRAP`
- `FF_TIMEOUT`
- `FF_TO`
- `FF_UTF8_LOCALE_CMD`
- `FF_VERSION_FIXTURE`
- `FF_VERIFY_GRAPH`（tests/run-all/verify.sh の並走判定 fixture が ps の成否を選ぶ注入口）
- `FF_VERIFY_REAL_PS`（同じ fixture が祖先の ps に使う実 ps のパス）
- `FF_VERIFY_SLEEPER_PID`（同じ fixture が独立した run-all.sh として見せる PID）
- `FF_WEEKLY_HEALTH_ACCEPT_DISPATCH`
- `FF_WRITE_SCAN_GIT`
- `FF_WRITE_SCAN_GREP`
- `FF_WRITE_SCAN_OD`
- `FF_WRITE_SCAN`
- `FF_X`
- `FF_ZSH_GLOB_AWK`
- `FF_YQ_MODE`

#### 4-2-2. 配布実行物・配布文書に現れるもの

配布スクリプト・hooks のローカル変数、配布物どうしの受け渡し値、導入先がコピーして所有するスニペット内のローカル変数です。

- `FF_BASH_HOOKS_NOTICE_LOG`（集約入口 `hooks/run-bash-hooks.sh` が、`hooks/guard-zsh-glob.sh` がその呼び出しで作った通知の記録を受け取るファイル）
- `FF_CHANGELOG_DIGEST_FILE`
- `FF_CHANGELOG_DIGEST_WIDTH`
- `FF_DEV_TOOLKIT_AUTO_UPDATE_STAMP`
- `FF_DEV_TOOLKIT_PROJECT_ROOT`
- `FF_DEV_TOOLKIT_REF`
- `FF_DEV_TOOLKIT_ROOT_SOURCE`
- `FF_DEV_TOOLKIT_ROSTER_DRIFT_CLAUDE_HOME`
- `FF_DEV_TOOLKIT_ROSTER_DRIFT_HOOK`
- `FF_DEV_TOOLKIT_SKILL_DRIFT_CLAUDE_HOME`
- `FF_DEV_TOOLKIT_SKILL_DRIFT_REPO_ROOT`
- `FF_DEV_TOOLKIT_UPDATE_CACHE_DIR`
- `FF_DEV_TOOLKIT_UPDATE_REPO_URL`
- `FF_DEV_TOOLKIT_UPDATE_TTL_FAIL`
- `FF_DEV_TOOLKIT_UPDATE_TTL_OK`
- `FF_EFFORT_ACTUAL_GUARD_MAX_ISSUES`
- `FF_GATE_RECORD_FILE`
- `FF_JEV`
- `FF_JEV_DECISION_LOG`
- `FF_JEV_ENABLED`
- `FF_JEV_INTERVAL_MS`
- `FF_JEV_MAX_REQUEST_BYTES`
- `FF_JEV_MAX_RETRIES`
- `FF_JEV_MAX_RETRY_AFTER_SECONDS`
- `FF_JEV_MAX_STATE_BYTES`
- `FF_JEV_MIN_CONFIDENCE`（判定点別の上書きは同名 + `_` + 判定点名の大文字）
- `FF_JEV_MIN_CONFIDENCE_DEDUPE`（判定点 dedupe の閾値の上書き。組み込み既定は 0.8）
- `FF_JEV_NOUL_THRESHOLD`
- `FF_JEV_PRICE_PER_MTOK_USD`
- `FF_JEV_RETRY_BASE_SECONDS`
- `FF_MULTI_AGENT_LOAD_SAMPLE`
- `FF_MULTI_AGENT_REVIEW_SERIES_REASON_FILE`
- `FF_PAIRS`
- `FF_PLAYBOOK_CHANGELOG_VERDICT`
- `FF_PLAYBOOK_CHANGELOG_OUTPUT`
- `FF_PUBLIC_LAYOUT_ALLOWED_SKIP_SUITES`（`tests/public-layout/verify.sh` が公開配置の合成実行で公開 workflow `weekly-public-run-all.yml` の step へ渡す、skip 許容名簿へ足す suite 名。公開側の CI は設定しない）
- `FF_REVIEW_LOCK_MAX_AGE_SECONDS`
- `FF_REVIEW_OUTPUT`
- `FF_REVIEW_OUTPUT_SUGGESTING`（出力境界の案内が、案内先の再検査から同じ案内を重ねて出さないための内部フラグ。利用者が設定する値ではない）
- `FF_ROOT_SIDECAR_NAME`
- `FF_ROOT_SIDECAR_PATH`
- `FF_RUN_ALL_ALLOW_SKIP`
- `FF_GROK_PROFILE`（Grok適用イベント検証の内部受渡し）
- `FF_GROK_TREE`（物理checkoutの内部受渡し）
- `FF_GROK_CHECK_GRANTS`（非inline implementとの検査分岐）
- `FF_STALE_BASE`
- `FF_STDIN_BOUND_SECONDS`
- `FF_TIMEOUT_KILL_GRACE`
- `FF_TIMEOUT_REASON_FILE`
- `FF_TOOLKIT_MANIFEST`
- `FF_TOOLKIT_SCRIPTS`
- `FF_TOOLKIT_SIDECAR`
- `FF_ZSH_WORD_SPLIT_PREFIX`（guard-zsh-glob.sh が未引用 scalar の呼び出しの先頭へ付ける文。判定ヘルパと hook の受け渡し値）

##### 撤去した旧名

L4 宣言をまとめる前の個別の名前（旧名）は、内部の別名として読むのをやめました。旧名はこの節にも書きません。配布実行物は、環境にある FF_DEV_TOOLKIT_SKIP_ で始まる変数の名前から 4-3 の鍵を導いて旧名を見つけます（接頭辞と末尾の _GUARD を外し、小文字・`-` 区切りにしたもの）。旧名と新しい書き方の対応は「破壊的変更の記録」にあります。

- **副作用のある 4 鍵**（`auto-update` / `codex-auto-update` / `effort-metrics` / `decision-tree`）: 旧名の値が空でなければ（`0` でも）、その処理を止めます。旧名で止めていた更新や記録が黙って動き出さないための扱いで、期限はありません
- **ほかの 20 鍵**（ガードと通知）: 旧名では止めません。停止文に新しい書き方を添える hook（`hooks/guard-exit-code.sh` / `hooks/guard-literal-write.sh` / `hooks/guard-review-in-flight.sh`）が止めたときは、`次の一手:` の行の末尾に、その旧名を読まなくなったことと `FF_DEV_TOOLKIT_SKIP=<鍵>` を添えます
- **通知**: hooks が発火するホストでは、旧名が環境にあるとセッション開始時（`hooks/check-update.sh`）に毎回、置き換えを通知します
- **ACK の旧名**（4-1 の ACK のうち、L4 宣言をまとめるときに改名した 3 つの前の名前）は読みません。各 hook の deny 文が示す新しい名前で通します

### 4-3. L4 宣言の鍵

`FF_DEV_TOOLKIT_SKIP` に書ける鍵です。すべて契約で、鍵の削除・改名・意味の変更は破壊的変更です。正本は `scripts/lib/l4-declarations.tsv` の名簿で、この表・公開 README の鍵の表・実装の呼び出しとの一致は機械検査が見ます。

- **種別**: 鍵が止めるもの。ガード（停止・警告）/ 通知 / 記録 / 自動更新
- **包含**: その鍵の SKIP で併せて止まる、別の鍵（ACK だけを持つ鍵を含む）。名簿で 1 段だけ辿ります。包含は「担当する実体」の中だけで、別の実行経路には及びません（例: `review-in-flight` は `scripts/multi-agent.sh` の巡回上限を止めない）
- **撤去した旧名**: L4 宣言をまとめる前の名前から接頭辞 `FF_DEV_TOOLKIT_SKIP_` を外した残り。もう読みません（副作用のある 4 鍵だけは、旧名を見つけると止めます。上の「撤去した旧名」）

| 鍵 | 種別 | 担当する実体 | 包含 | 撤去した旧名 |
| --- | --- | --- | --- | --- |
| `auto-update` | 自動更新 | `hooks/auto-update-marketplace.sh` | - | `AUTO_UPDATE` |
| `background-cwd` | ガード | `hooks/guard-background-cwd.sh` | - | `BACKGROUND_CWD_GUARD` |
| `checkout` | ガード | `hooks/guard-checkout-restore.sh` | `discard-uncommitted` | `CHECKOUT_GUARD` |
| `codex-auto-update` | 自動更新 | `scripts/lib/multi-agent-codex-update.sh` | - | `CODEX_AUTO_UPDATE` |
| `commit-identity` | ガード | `scripts/lib/commit-identity-functions.sh` | - | `COMMIT_IDENTITY_GUARD` |
| `credential-output` | ガード | `hooks/guard-credential-output.sh` | - | `CREDENTIAL_OUTPUT_GUARD` |
| `decision-tree` | 記録 | `hooks/decision-tree.sh` | - | `DECISION_TREE` |
| `effort-actual` | ガード | `hooks/guard-effort-actual.sh` | - | `EFFORT_ACTUAL_GUARD` |
| `effort-metrics` | 記録 | `hooks/record-effort-wallclock.sh`・`hooks/record-instruction-bytes.sh`・`scripts/record-gate-minutes.sh` | - | `EFFORT_METRICS` |
| `exit-code` | ガード | `hooks/guard-exit-code.sh` | `timeout`・`unbounded-wait`・`rg-stdin` | `EXIT_CODE_GUARD` |
| `issue-label` | ガード | `hooks/guard-issue-labels.sh` | - | `ISSUE_LABEL_GUARD` |
| `literal-write` | ガード | `hooks/guard-literal-write.sh` | - | `LITERAL_WRITE_GUARD` |
| `long-gate-background` | ガード | `hooks/guard-long-gate-background.sh` | - | `LONG_GATE_BACKGROUND_GUARD` |
| `merge-closing` | ガード | `hooks/guard-merge-closing-keyword.sh` | - | `MERGE_CLOSING_GUARD` |
| `pr-followup` | ガード | `hooks/guard-pr-followup.sh` | `pr-draft` | `PR_FOLLOWUP_GUARD` |
| `review-in-flight` | ガード | `hooks/guard-review-in-flight.sh` | `review-lock`・`review-round` | `REVIEW_IN_FLIGHT_GUARD` |
| `review-roster-check` | 通知 | `hooks/check-review-roster-drift.sh` | - | `REVIEW_ROSTER_CHECK` |
| `skill-drift-check` | 通知 | `hooks/check-skill-drift.sh` | - | `SKILL_DRIFT_CHECK` |
| `sub-issue-id` | ガード | `hooks/guard-sub-issue-id.sh` | - | `SUB_ISSUE_ID_GUARD` |
| `update-check` | 通知 | `hooks/check-update.sh` | - | `UPDATE_CHECK` |
| `wsl-notice` | 通知 | `hooks/check-update.sh` | - | `WSL_NOTICE` |
| `wsl-shell` | ガード | `hooks/guard-wsl-shell.sh` | - | `WSL_SHELL_GUARD` |
| `zsh-expansion` | ガード | `hooks/guard-zsh-glob.sh`・`tests/lib/zsh-expansion-guard.sh` | - | `ZSH_EXPANSION_GUARD` |
| `zsh-glob` | ガード | `hooks/guard-zsh-glob.sh` | `zsh-expansion` | `ZSH_GLOB_GUARD` |

ACK（1 回だけ通す承認）の名前は、鍵から `FF_<鍵を大文字・_ 区切り>_ACK` の型で作ります。ACK だけを持つ鍵（`discard-uncommitted` / `pr-draft` / `review-lock` / `review-round` / `rg-stdin` / `shell-save` / `timeout` / `unbounded-wait`）は SKIP の鍵ではないので、この表に載せません（`FF_DEV_TOOLKIT_SKIP` に書いても効きません）。ACK の一覧は 4-1 にあります。

## 公開面 5: 環境変数（`FF_` で始まらないもの）

`FF_` で始まらない環境変数も、利用者が設定して効かせる値は契約です。分類は `FF_*` と同じ判定規則（公開されている ∧ 配布実行物が読む）を機械で実行して決めます。

### 5-0. 母集団の決め方

`FF_*` と違い、全大文字の語を字句で拾うと、スクリプトのローカル変数や出力行のキー（決定木の DT_ROUTE 行など）が大半を占めて境界になりません。そこで母集団は**この節で宣言した名前の系統**に限ります。

- **接頭辞系統**: 配布物に現れる、次の接頭辞で始まる大文字・数字・アンダースコアの語すべて。系統の中で名前が増えれば、検査が自動で拾います（この節の backtick token が宣言そのものなので、例示には backtick を使わない）
  - `MULTI_AGENT_*`（multi-review / multi-agent の設定）
  - `RETROSPECTIVE_*`（振り返りの起動モード・起票方針）
  - `TYPESAFE_*`（Jev 判定点の API 接続）
  - `SPEC_DOCS_*`（仕様MCPのproject選択と外部docs許可）
- **系統外の単独名**: 利用者が設定する値のうち、上の系統に属さないもの
  - `ACE_DEFER_TO_RETRO`
  - `ACE_GARDEN_WALL_PATHS`
  - `CODEX_MODEL`
  - `CODEX_DEFAULT_REVIEWERS`
  - `CODEX_REASONING_EFFORT`
  - `SKIP_CODEX_REVIEW`

走査対象と除外は `FF_*` の「網羅の定義」と同じです。ホスト・OS・外部 CLI が定義する変数（HOME / TMPDIR / XDG 系 / CLAUDE 系 / GROK 系 / CODEX_HOME など）は本プラグインの公開面ではないので、母集団に含めません。

**利用者が設定する値を新しい接頭辞や単独名で足すときは、先にこの節へ系統か単独名を追加してください。** 宣言の外で足した名前は検査が拾えません（機械検査が及ばない範囲。下記）。

### 5-1. 契約

- `SPEC_DOCS_PROJECT_ROOT`
- `SPEC_DOCS_ALLOWED_DOCS_ROOT`
- `ACE_DEFER_TO_RETRO`
- `CODEX_MODEL`
- `MULTI_AGENT_BASE_BRANCH`
- `MULTI_AGENT_CLAUDE_EFFORT`
- `MULTI_AGENT_CODEX_PROFILE`
- `MULTI_AGENT_CODEX_REASONING_EFFORT`
- `MULTI_AGENT_CONFIG`
- `MULTI_AGENT_CRITICAL_NONBLOCK_PERSPECTIVES`
- `MULTI_AGENT_CROSS_REVIEW`
- `MULTI_AGENT_GROK_READONLY_PROFILE`
- `MULTI_AGENT_LANE_PRECHECK`
- `MULTI_AGENT_LANE_PRECHECK_TIMEOUT`
- `MULTI_AGENT_MODEL`
- `MULTI_AGENT_MODEL_CLAUDE_CODE`
- `MULTI_AGENT_MODEL_CODEX_CLI`
- `MULTI_AGENT_MODEL_COPILOT_CLI`
- `MULTI_AGENT_MODEL_GROK_CLI`
- `MULTI_AGENT_MODEL_ANTIGRAVITY_CLI`
- `MULTI_AGENT_REVIEW_CONFIDENCE_THRESHOLD`
- `MULTI_AGENT_REVIEW_MAIN`
- `MULTI_AGENT_REVIEW_SUB`
- `MULTI_AGENT_SECURITY_GLOB`
- `MULTI_AGENT_SECURITY_GLOB_EXTRA`
- `MULTI_AGENT_SECURITY_REVIEW`
- `RETROSPECTIVE_FILING`
- `RETROSPECTIVE_MODE`
- `SKIP_CODEX_REVIEW`

### 5-2. 内部

予告なく改名・削除します。導入先の設定へ書かないでください。文書の記入例（`MULTI_AGENT_MODEL_EXAMPLE_CLI` など）・テストの注入口・配布文書が案内しない旧名もここに入ります。

なお、**導入先がコピーして所有するスニペットの中だけで読む値**（`ACE_GARDEN_WALL_PATHS` は導入先の `scripts/ace/run-subagent.sh` が読む）も、「`FF_*` の判定規則」の「片方だけになるもの」と同じ理由で内部に分類されます。これは「設定してはいけない」ではなく、「コピーした時点で導入先の資産になり、こちらの改名がその導入先のコピーを壊さない」という意味です。設定の要否はそのスニペットの README に従ってください。この節（5-0〜5-2）の backtick 付きの大文字語は散文の中でも分類の宣言として抽出されるので、一覧に無い名前を例示に使わないでください。

- `ACE_GARDEN_WALL_PATHS`
- `CODEX_DEFAULT_REVIEWERS`
- `CODEX_REASONING_EFFORT`
- `MULTI_AGENT_AC_FIXTURE`
- `MULTI_AGENT_BAD`
- `MULTI_AGENT_EXAMPLE_PROFILE`
- `MULTI_AGENT_MODEL_EXAMPLE_CLI`
- `MULTI_AGENT_MODEL_GEMINI_CL1`
- `MULTI_AGENT_MODEL_GEMINI_CLI`
- `MULTI_AGENT_MODEL_OTHER_CLI`
- `MULTI_AGENT_PARTS`
- `RETROSPECTIVE_DELIVERED`
- `RETROSPECTIVE_DONE`
- `RETROSPECTIVE_OFF`
- `RETROSPECTIVE_TEST_INPUT`
- `TYPESAFE_API_KEY`
- `TYPESAFE_API_KEY_FILE`
- `TYPESAFE_API_URL`
- `TYPESAFE_MODEL`

## 破壊的変更の記録

契約側の要素を削除・改名・意味変更する変更は、CHANGELOG の `### 破壊的変更` 節へ記録します。開発元リポジトリでは `changelog.d/` の断片種別 `breaking` がこの節へ集約されます。節は各版の先頭に置かれるため、版の差分を読むときに最初に目に入ります。

記録には次を書きます。

- 何が契約から消えた・変わったのか（名前を明記する）
- 導入先が何をすれば復旧できるのか（置き換え先、移行手順）

内部の変更はこの節に書きません。

**L4 宣言の統合（ADR-087）**: 止める宣言を 1 変数 `FF_DEV_TOOLKIT_SKIP` の鍵へ、1 回だけ通す承認を `FF_<鍵>_ACK` の型へ揃えました。次の旧名は 4-1 の契約から外れ、内部の別名として 1.0.0 まで読まれました。その後の版で読むのをやめています（副作用のある 4 鍵の旧名は、見つけると止めます。4-2-2 の「撤去した旧名」）。`FF_DEV_TOOLKIT_SKIP_COMMIT_IDENTITY_GUARD` は以前から内部でしたが、鍵 `commit-identity` として契約に上がりました。

| 旧名 | 新しい書き方 |
| --- | --- |
| `FF_DEV_TOOLKIT_SKIP_AUTO_UPDATE=1` | `FF_DEV_TOOLKIT_SKIP=auto-update`（旧名は `=0` でも止まっていた。新しい形は鍵を書いたときだけ止まる） |
| `FF_DEV_TOOLKIT_SKIP_BACKGROUND_CWD_GUARD=1` | `FF_DEV_TOOLKIT_SKIP=background-cwd` |
| `FF_DEV_TOOLKIT_SKIP_CHECKOUT_GUARD=1` | `FF_DEV_TOOLKIT_SKIP=checkout` |
| `FF_DEV_TOOLKIT_SKIP_CODEX_AUTO_UPDATE=1` | `FF_DEV_TOOLKIT_SKIP=codex-auto-update` |
| `FF_DEV_TOOLKIT_SKIP_COMMIT_IDENTITY_GUARD=1` | `FF_DEV_TOOLKIT_SKIP=commit-identity` |
| `FF_DEV_TOOLKIT_SKIP_CREDENTIAL_OUTPUT_GUARD=1` | `FF_DEV_TOOLKIT_SKIP=credential-output` |
| `FF_DEV_TOOLKIT_SKIP_DECISION_TREE=1` | `FF_DEV_TOOLKIT_SKIP=decision-tree` |
| `FF_DEV_TOOLKIT_SKIP_EFFORT_ACTUAL_GUARD=1` | `FF_DEV_TOOLKIT_SKIP=effort-actual` |
| `FF_DEV_TOOLKIT_SKIP_EFFORT_METRICS=1` | `FF_DEV_TOOLKIT_SKIP=effort-metrics` |
| `FF_DEV_TOOLKIT_SKIP_EXIT_CODE_GUARD=1` | `FF_DEV_TOOLKIT_SKIP=exit-code` |
| `FF_DEV_TOOLKIT_SKIP_ISSUE_LABEL_GUARD=1`（環境に置く形） | `FF_DEV_TOOLKIT_SKIP=issue-label` |
| `FF_DEV_TOOLKIT_SKIP_ISSUE_LABEL_GUARD=1`（コマンドの先頭に置く 1 回分の形） | `FF_ISSUE_LABEL_ACK=1` |
| `FF_DEV_TOOLKIT_SKIP_LITERAL_WRITE_GUARD=1` | `FF_DEV_TOOLKIT_SKIP=literal-write` |
| `FF_DEV_TOOLKIT_SKIP_LONG_GATE_BACKGROUND_GUARD=1` | `FF_DEV_TOOLKIT_SKIP=long-gate-background` |
| `FF_DEV_TOOLKIT_SKIP_MERGE_CLOSING_GUARD=1` | `FF_DEV_TOOLKIT_SKIP=merge-closing` |
| `FF_DEV_TOOLKIT_SKIP_PR_FOLLOWUP_GUARD=1` | `FF_DEV_TOOLKIT_SKIP=pr-followup` |
| `FF_DEV_TOOLKIT_SKIP_REVIEW_IN_FLIGHT_GUARD=1` | `FF_DEV_TOOLKIT_SKIP=review-in-flight` |
| `FF_DEV_TOOLKIT_SKIP_REVIEW_ROSTER_CHECK=1` | `FF_DEV_TOOLKIT_SKIP=review-roster-check` |
| `FF_DEV_TOOLKIT_SKIP_SKILL_DRIFT_CHECK=1` | `FF_DEV_TOOLKIT_SKIP=skill-drift-check` |
| `FF_DEV_TOOLKIT_SKIP_SUB_ISSUE_ID_GUARD=1` | `FF_DEV_TOOLKIT_SKIP=sub-issue-id` |
| `FF_DEV_TOOLKIT_SKIP_UPDATE_CHECK=1` | `FF_DEV_TOOLKIT_SKIP=update-check` |
| `FF_DEV_TOOLKIT_SKIP_WSL_NOTICE=1` | `FF_DEV_TOOLKIT_SKIP=wsl-notice` |
| `FF_DEV_TOOLKIT_SKIP_WSL_SHELL_GUARD=1` | `FF_DEV_TOOLKIT_SKIP=wsl-shell` |
| `FF_DEV_TOOLKIT_SKIP_ZSH_EXPANSION_GUARD=1` | `FF_DEV_TOOLKIT_SKIP=zsh-expansion` |
| `FF_DEV_TOOLKIT_SKIP_ZSH_GLOB_GUARD=1` | `FF_DEV_TOOLKIT_SKIP=zsh-glob`（`zsh-expansion` も止まる） |
| `FF_DISCARD_UNCOMMITTED=1` | `FF_DISCARD_UNCOMMITTED_ACK=1` |
| `FF_REVIEW_LOCK_OVERRIDE=1` | `FF_REVIEW_LOCK_ACK=1` |

複数の鍵はカンマで並べます（`FF_DEV_TOOLKIT_SKIP=update-check,wsl-notice`）。SKIP の置き場所（ホストの env 設定・shell の rc・CI の環境）と、ACK の置き場所（コマンドの先頭・区間の先頭・hook のプロセス環境）は旧名のときと同じです。

## この一覧を守る機械検査

開発元リポジトリの回帰ゲートが、本ファイルと実体の集合一致を検査します。

`skill-count-consistency`:

- Skills: 本ファイルの「公開面 1」の集合 = `skills/*/SKILL.md` を持つディレクトリの集合
- Hooks: 「2-1」の三つ組の集合 = `hooks/hooks.json` が登録する `発火イベント :: matcher :: 実体` の集合。「2-2」の集合 = `hooks/` の残りのファイル。あわせて登録された実体がすべて通常ファイルとして在ることも見る（登録だけ残して実体を消す変更を素通りさせない）
- `FF_*` の契約: 「4-1」の集合 = 判定規則の 1 の集合 ∩ 2 の集合。**規則そのものを機械で実行する**ので、公開もされ実行物も読む名前を 4-2 へ入れると赤になる
- `FF_*` の網羅: 「4-1」と「4-2」の和集合 = 網羅の定義で導いた母集団。片側にしか無い名前と、4-1 と 4-2 の両方に載っている名前は赤
- `FF_` で始まらない環境変数: 「5-1」= 判定規則の 1 の集合 ∩ 2 の集合（`FF_*` と同じ規則）、「5-1」と「5-2」の和集合 = 「5-0」が宣言した系統・単独名で導いた母集団、両者が排他。宣言した単独名が配布物から消えると一覧側にだけ残る名前として赤

`changelog-fragments`:

- 契約側の要素（「公開面 1」「2-1」「公開面 3」の表の先頭セル「4-1」「4-3」の表の先頭セル「5-1」）が既定ブランチの本ファイルから**消えている**のに、消えた要素のそれぞれを名指す `breaking` 断片が `changelog.d/` に無ければ赤。削除・改名を一覧と実体から同時に消しても、破壊的変更の記録が無い限り通らない。無関係な `breaking` 断片が 1 つあるだけでは通らない

`l4-declarations`:

- 「4-3」の鍵の集合 = 名簿 `scripts/lib/l4-declarations.tsv` の SKIP の鍵の集合 = 公開 README の鍵の表 = 配布実行物が `ff_l4_skipped` で呼ぶ鍵の集合
- 配布実行物の `FF_<…>_ACK` の名前はどれも名簿の ACK の鍵から作れる
- 配布実行物（hooks・scripts・tests/lib・`.claude/hooks`・`tests/run-all.sh`・`mcp/src`）の非コメント行に、FF_DEV_TOOLKIT_SKIP_ の後ろへ英大文字か数字が続く名前のリテラルが無い（撤去した旧名を書き戻していない。接頭辞だけを書いた列挙は対象外）。副作用のある 4 鍵だけが、名簿と呼び出しの両方で `retired-stop` を持つ

機械検査が及ばない範囲: 「公開面 3」の**内部側**として列挙したパスと、「5-0」で宣言していない系統・単独名の `FF_` で始まらない環境変数。撤去・改名のときは `removal-sweep` スキルのチェックリストで残存参照を走査してください。
