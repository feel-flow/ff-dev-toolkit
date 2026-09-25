# ff-dev-toolkit 公開面（Public Surface）

このファイルは、ff-dev-toolkit が**互換性を約束する対象**（契約）と、**予告なく変えてよい実装詳細**（内部）の境界の正本です。導入先から読めるように配布物へ同梱しています。

対象は 4 系統 — Skills の起動名 / Hooks / 導入先に配置されるパス / 環境変数 `FF_*`。いずれも「契約」と「内部」を区別して列挙します。

## 契約と内部

| 区分 | 意味 | 変えたときの扱い |
| --- | --- | --- |
| **契約** | 導入先が名前で依存できる要素 | 削除・改名・意味の変更は**破壊的変更**。CHANGELOG の `### 破壊的変更` 節へ記録する |
| **内部** | 実装詳細。スクリプト内のローカル変数、テストハーネスの注入口、配布物どうしの受け渡し値 | 予告なく変えてよい。破壊的変更として記録しない |

1.0.0 より前のため、ここで言う「破壊的変更」は**記録の規約**であってバージョン番号の規約ではありません。1.0.0 を宣言してよい条件は、開発元リポジトリのアーキテクチャ決定記録（ADR）に置いてあります。

## 網羅の定義（`FF_*`）

`FF_*` の母集団は、配布物に現れる `FF_` で始まる大文字・数字・アンダースコアの語です。

- 走査対象: `plugins/ff-dev-toolkit/` 配下と、公開リポジトリのルートへ同期される `oss/ff-dev-toolkit/` 配下
- 走査対象から外すもの: 本ファイル自身（自分で自分を正当化しないため）と `oss/ff-dev-toolkit/CHANGELOG.md`（過去の版の記録に残る、すでに存在しない名前を母集団へ持ち込まないため）
- 語の切り出しは純粋に字句的です。そのため `FF_MULTI_AGENT` / `FF_TIMEOUT` のように**環境変数名の接頭辞**として書かれた語も母集団に入ります。これらは内部に分類しています
- **本版の列挙対象は `FF_*` だけ**です。`FF_` で始まらない環境変数（`RETROSPECTIVE_MODE` / `MULTI_AGENT_CONFIG` / `MULTI_AGENT_BASE_BRANCH` など）は**未分類**で、この一覧に載っていないことは「内部である」ことを意味しません。**契約とも見なさない**でください。分類の拡張は別途扱います

**母集団のすべてが下の 4-1 か 4-2 のどちらかに載っていること**は機械検査が担保します（未分類 0 件）。

## `FF_*` の判定規則

次の 2 つを**両方**満たす名前だけが契約です。

1. **公開されている** — 公開 README、`plugins/ff-dev-toolkit/docs-template/` 配下、`plugins/ff-dev-toolkit/skills/*/SKILL.md` のいずれかに現れる
2. **配布実行物が読む** — `plugins/ff-dev-toolkit/hooks/`、`plugins/ff-dev-toolkit/scripts/`、`plugins/ff-dev-toolkit/tests/run-all.sh` のいずれかに現れる

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
- `harness-review`
- `init-docs`
- `knowledge-lookup`
- `merge-cleanup`
- `multi-explore`
- `multi-implement`
- `multi-review`
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
- `PreToolUse :: Bash :: hooks/guard-background-cwd.sh`
- `PreToolUse :: Bash :: hooks/guard-checkout-restore.sh`
- `PreToolUse :: Bash :: hooks/guard-effort-actual.sh`
- `PreToolUse :: Bash :: hooks/guard-exit-code.sh`
- `PreToolUse :: Bash :: hooks/guard-issue-labels.sh`
- `PreToolUse :: Bash :: hooks/guard-long-gate-background.sh`
- `PreToolUse :: Bash :: hooks/guard-pr-followup.sh`
- `PreToolUse :: Bash :: hooks/guard-sub-issue-id.sh`
- `PreToolUse :: Bash :: hooks/record-effort-wallclock.sh`
- `PreToolUse :: Edit|Write|MultiEdit|NotebookEdit|Bash|Agent|Task :: hooks/guard-review-in-flight.sh`
- `PreToolUse :: Read|Skill :: hooks/record-instruction-bytes.sh`
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

### 2-2. 内部（入口から呼ばれる実装）

`hooks.json` に登録されておらず、上の入口や ASDD の設定から呼ばれる実装です。直接呼ぶ前提の要素ではないため、予告なく変わります。

- `hooks/asdd-feature.mjs`
- `hooks/asdd-hook-gate.sh`
- `hooks/retrospective-chain-tail.mjs`

## 公開面 3: 導入先に配置されるパス

導入先のリポジトリの**決め打ちのパス**に置かれ、配布物の手順やスクリプトがそのパスを名前で指すものです。パスが変わると導入先の規約（`bash scripts/codex-review.sh` など）や toolkit 側の読み取りが壊れるため契約に含めます。中身の更新は破壊的変更ではありません。

置く主体は一様ではありません — 配布スクリプトが置くもの、skill が生成するもの、**利用者が任意で置き toolkit が在れば読むもの**が混ざります。列に明記します。

| パス（導入先から見た相対パス） | 置く主体 | 役割 |
| --- | --- | --- |
| `scripts/codex-review.sh` | `scripts/setup-multi-agent.sh` が配置する | クロスモデルレビューの入口シム（単一ファイル配布） |
| `scripts/.ff-dev-toolkit-root` | `scripts/setup-multi-agent.sh` が配置する | シムがオーケストレータを解決するためのサイドカー（Git 管理しない） |
| `.claude/agent-config.yaml` | **利用者が任意で置く**（`scripts/setup-multi-agent.sh` はコピー手順を表示するだけで、ファイルは置かない） | レビュー担当・CLI 構成のプロジェクト上書き。在れば同梱の既定より優先して読まれる |
| `docs/MASTER.md` | `init-docs` / `asdd-init` が生成する | 仕様文書の入口。`validate-docs` が名前で参照する |
| `docs/01-context/PROJECT.md` | 同上 | コア文書 |
| `docs/02-design/ARCHITECTURE.md` | 同上 | コア文書 |
| `docs/03-implementation/CONVENTIONS.md` | 同上 | コア文書 |
| `docs/04-quality/TESTING.md` | 同上 | コア文書 |
| `docs/05-operations/DEPLOYMENT.md` | 同上 | コア文書 |
| `docs/06-reference/DECISIONS.md` | 同上 | コア文書 |
| `docs/08-knowledge/PLAYBOOK.md` | `ace-setup` が生成する | ACE のナレッジ台帳の入口 |
| `docs/08-knowledge/playbook/` | `ace-setup` が生成する | カテゴリ別台帳の置き場 |

**内部（配置はされるが、パスを固定しない）**:

- `docs/` の初期セットのうちコア文書以外（`01-context/CONSTRAINTS.md` / `02-design/DOMAIN.md` / `02-design/API.md` / `02-design/DATABASE.md` / `03-implementation/PATTERNS.md` / `03-implementation/INTEGRATIONS.md` / `03-implementation/DECISION_TREE.md` / `03-implementation/FALLBACK.md` / `04-quality/VALIDATION.md` / `06-reference/GLOSSARY.md` / `07-project-management/ROADMAP.md` / `07-project-management/TASKS.md` / `07-project-management/RISKS.md`）— 生成後は導入先の資産で、toolkit は名前で固定しません
- `scripts/ace/` の検査スクリプト — 配置は任意で、未配置なら同梱ランナー経由で同じ検査を実行します。したがって導入先が依存する固定パスではありません

配布物の側のパス（`plugins/ff-dev-toolkit/scripts/` などの同梱物の位置）は、導入先が直接呼ぶ入口だけが契約です。導入先は skill 経由か、上のシム経由で到達します。

## 公開面 4: 環境変数 `FF_*`

### 4-1. 契約

#### プラグイン root と skill の受け渡し（AI host / 導入先 CI が設定し、配布実行物が読む）

- `FF_DEV_TOOLKIT_ROOT`
- `FF_DEV_TOOLKIT_SKILL_FILE`

#### hooks の無効化・承認の抜け道

- `FF_DEV_TOOLKIT_SKIP_AUTO_UPDATE`
- `FF_DEV_TOOLKIT_SKIP_BACKGROUND_CWD_GUARD`
- `FF_DEV_TOOLKIT_SKIP_CHECKOUT_GUARD`
- `FF_DEV_TOOLKIT_SKIP_DECISION_TREE`
- `FF_DEV_TOOLKIT_SKIP_EFFORT_ACTUAL_GUARD`
- `FF_DEV_TOOLKIT_SKIP_EFFORT_METRICS`
- `FF_DEV_TOOLKIT_SKIP_EXIT_CODE_GUARD`
- `FF_DEV_TOOLKIT_SKIP_ISSUE_LABEL_GUARD`
- `FF_DEV_TOOLKIT_SKIP_LONG_GATE_BACKGROUND_GUARD`
- `FF_DEV_TOOLKIT_SKIP_PR_FOLLOWUP_GUARD`
- `FF_DEV_TOOLKIT_SKIP_REVIEW_IN_FLIGHT_GUARD`
- `FF_DEV_TOOLKIT_SKIP_REVIEW_ROSTER_CHECK`
- `FF_DEV_TOOLKIT_SKIP_SKILL_DRIFT_CHECK`
- `FF_DEV_TOOLKIT_SKIP_SUB_ISSUE_ID_GUARD`
- `FF_DEV_TOOLKIT_SKIP_UPDATE_CHECK`
- `FF_DISCARD_UNCOMMITTED`
- `FF_EFFORT_ACTUAL_ACK`
- `FF_EXIT_CODE_ACK`
- `FF_LONG_GATE_BACKGROUND_ACK`
- `FF_SUB_ISSUE_ID_ACK`
- `FF_REVIEW_LOCK_OVERRIDE`
- `FF_REVIEW_ROUND_ACK`

#### hooks の閾値・対象

- `FF_DEV_TOOLKIT_STATE_DIR`（工数の実測記録の置き場の親。既定 `$HOME/.config/ff-dev-toolkit`）
- `FF_DEV_TOOLKIT_UPDATE_TTL_NOTIFIED`
- `FF_LONG_GATE_FOREGROUND_TIMEOUT_MS`
- `FF_REVIEW_ROUND_LIMIT`（レビュー巡回の上限。既定 2、0 で無効）
- `FF_REVIEW_SUBAGENT_LOCK_MAX_AGE_SECONDS`
- `FF_REVIEW_SUBAGENT_LOCK_PENDING_SECONDS`
- `FF_REVIEW_SUBAGENT_LOCK_TYPES`

#### skill が呼ぶスクリプトの設定

- `FF_ACE_TS_RUNNER`
- `FF_JEV_MODE`
- `FF_JEV_POINTS`
- `FF_MERGE_CLEANUP_IGNORE_PATHS`
- `FF_MERGE_CLEANUP_MERGED_PR_LIMIT`
- `FF_MERGE_CLEANUP_PROJECTS_DIR`
- `FF_MERGE_CLEANUP_PROTECT_BRANCHES`
- `FF_MERGE_CLEANUP_TRANSCRIPTS`
- `FF_MERGE_CLEANUP_TRANSCRIPT_ARCHIVE_DIR`
- `FF_MULTI_AGENT_IGNORE_PATHS`
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
- `FF_DEV_TOOLKIT_SKIP_COMMIT_IDENTITY_GUARD`
- `FF_DOCS_AWK_STRIP_CR`
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
- `FF_FIXTURE_NEW`
- `FF_FROM`
- `FF_GATE_RECORD`
- `FF_GATE_START_HEAD`
- `FF_GH_STUB`
- `FF_GOOD_ROOT`
- `FF_GUARD_SCRIPT`
- `FF_HD_CMD`
- `FF_HEREDOC_AWK`
- `FF_HOST_ROOT`
- `FF_JOBS_CAP`
- `FF_JOBS_LIMIT`
- `FF_MBCS_AWK`
- `FF_MBCS_GIT`
- `FF_MULTI_AGENT`
- `FF_M`
- `FF_NEEDLE`
- `FF_NODE_ROOT_GUARD_QUIET`
- `FF_NODE_TEST_AWK`
- `FF_NODE_TEST_GIT`
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
- `FF_P`
- `FF_REACHED_END`
- `FF_REAL_CKSUM`
- `FF_RELEASE_CHECK_PUBLIC`
- `FF_RETRO_SELFTEST_JOBS`
- `FF_RUN_ALL_ALLOW_DIRTY`
- `FF_RUN_ALL_ALLOW_MISSING_MCP_DEPS`
- `FF_RUN_ALL_CHANGED`
- `FF_RUN_ALL_CHECK_REGISTRATION`
- `FF_RUN_ALL_DUMP_DECLARATIONS`
- `FF_RUN_ALL_ELAPSED_FIXTURE`
- `FF_RUN_ALL_FAST`
- `FF_RUN_ALL_JOBS`
- `FF_RUN_ALL_MCP_DIR`
- `FF_RUN_ALL_MCP_NODE_MODULES`
- `FF_RUN_ALL_NESTED`
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
- `FF_WEEKLY_HEALTH_ACCEPT_DISPATCH`
- `FF_WRITE_SCAN_GIT`
- `FF_WRITE_SCAN_GREP`
- `FF_X`
- `FF_YQ_MODE`

#### 4-2-2. 配布実行物・配布文書に現れるもの

配布スクリプト・hooks のローカル変数、配布物どうしの受け渡し値、導入先がコピーして所有するスニペット内のローカル変数です。

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
- `FF_JEV_NOUL_THRESHOLD`
- `FF_JEV_PRICE_PER_MTOK_USD`
- `FF_JEV_RETRY_BASE_SECONDS`
- `FF_MULTI_AGENT_REVIEW_SERIES_REASON_FILE`
- `FF_PAIRS`
- `FF_REVIEW_LOCK_MAX_AGE_SECONDS`
- `FF_REVIEW_OUTPUT`
- `FF_ROOT_SIDECAR_NAME`
- `FF_ROOT_SIDECAR_PATH`
- `FF_RUN_ALL_ALLOW_SKIP`
- `FF_SANDBOX_WSDIR`
- `FF_STALE_BASE`
- `FF_STDIN_BOUND_SECONDS`
- `FF_TIMEOUT_KILL_GRACE`
- `FF_TIMEOUT_REASON_FILE`
- `FF_TOOLKIT_MANIFEST`
- `FF_TOOLKIT_SCRIPTS`
- `FF_TOOLKIT_SIDECAR`

## 破壊的変更の記録

契約側の要素を削除・改名・意味変更する変更は、CHANGELOG の `### 破壊的変更` 節へ記録します。開発元リポジトリでは `changelog.d/` の断片種別 `breaking` がこの節へ集約されます。節は各版の先頭に置かれるため、版の差分を読むときに最初に目に入ります。

記録には次を書きます。

- 何が契約から消えた・変わったのか（名前を明記する）
- 導入先が何をすれば復旧できるのか（置き換え先、移行手順）

内部の変更はこの節に書きません。

## この一覧を守る機械検査

開発元リポジトリの回帰ゲートが、本ファイルと実体の集合一致を検査します。

`skill-count-consistency`:

- Skills: 本ファイルの「公開面 1」の集合 = `skills/*/SKILL.md` を持つディレクトリの集合
- Hooks: 「2-1」の三つ組の集合 = `hooks/hooks.json` が登録する `発火イベント :: matcher :: 実体` の集合。「2-2」の集合 = `hooks/` の残りのファイル。あわせて登録された実体がすべて通常ファイルとして在ることも見る（登録だけ残して実体を消す変更を素通りさせない）
- `FF_*` の契約: 「4-1」の集合 = 判定規則の 1 の集合 ∩ 2 の集合。**規則そのものを機械で実行する**ので、公開もされ実行物も読む名前を 4-2 へ入れると赤になる
- `FF_*` の網羅: 「4-1」と「4-2」の和集合 = 網羅の定義で導いた母集団。片側にしか無い名前と、4-1 と 4-2 の両方に載っている名前は赤

`changelog-fragments`:

- 契約側の要素（「公開面 1」「2-1」「公開面 3」の表の先頭セル「4-1」）が既定ブランチの本ファイルから**消えている**のに `changelog.d/` に `breaking` 断片が無ければ赤。削除・改名を一覧と実体から同時に消しても、破壊的変更の記録が無い限り通らない

機械検査が及ばない範囲: 「公開面 3」の**内部側**として列挙したパスと、`FF_` で始まらない環境変数。撤去・改名のときは `removal-sweep` スキルのチェックリストで残存参照を走査してください。
