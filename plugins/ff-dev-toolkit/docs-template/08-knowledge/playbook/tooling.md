# PLAYBOOK — ツーリング (tooling)

> **Parent**: [PLAYBOOK.md](../PLAYBOOK.md) — 運用ルール・エントリテンプレート・ID規則・記述ガイドラインは親ファイルの SSOT を参照。
>
> 新規エントリは本ファイル末尾に追記し、[PLAYBOOK.md の索引テーブル](../PLAYBOOK.md#エントリ一覧)にも 1 行追加する。

---

## エントリ一覧

<a id="ace-002"></a>

### ACE-002: CLIフラグは実機の --help 出力と照合が必須

| フィールド | 値                   |
| ---------- | -------------------- |
| Category   | tooling              |
| Origin     | PR #316 / Issue #315 |
| Date       | 2026-03-10           |
| Helpful    | 2                    |
| Harmful    | 0                    |
| Status     | active               |

**Insight**: Web検索やAI生成の情報だけでは CLI フラグの正確性は保証されない。`codex -p` は存在せず `codex exec` が正解、Copilot `-s` は sandbox ではなく `--silent`、Cursor `-p` は boolean フラグでプロンプトは positional 引数など、実機確認しなければ分からない差異が多い。

**Context**: Multi-CLI Review ドキュメント作成時に5つのAI CLIのフラグを調査。Web検索とAI生成の情報を信じてドキュメント化したが、セルフレビューと実機テストで複数の誤りが発覚。特に Codex CLI は `-p` フラグが存在しないにもかかわらず、Web上の古い情報では `-p` が使われていた。

**Action**: CLI ツールのフラグを記述する際は、(1) `command --help` で実機確認、(2) 公式リポジトリの README/docs と照合、(3) 可能なら `--dry-run` 等で動作確認、の3ステップを必ず実施する。

---

<a id="ace-006"></a>

### ACE-006: サンプル付きテンプレファイルには⚠️SAMPLEバナーと固有化手順を必ず併設する

| フィールド | 値                   |
| ---------- | -------------------- |
| Category   | tooling              |
| Origin     | PR #369 / Issue #368 |
| Date       | 2026-04-26           |
| Helpful    | 0                    |
| Harmful    | 0                    |
| Status     | active               |

**Insight**: docs-template/ 配下のテンプレで具体例（特定ドメインのパス・名前）を含める場合、採用プロジェクトが固有化を忘れて「サンプルのまま運用される」失敗モードが発生する。冒頭の **⚠️ SAMPLE バナー** と末尾の **「プロジェクト固有化の手順」** セクションをセットで配置することで、採用時の見落としを構造的に防げる。

**Context**: PR #369 の `DECISION_TREE.md` は Web API バックエンドをサンプルドメインとして `infrastructure/clients/` 等の具体的パスを含む構成にした。設計時の失敗モード分析で「Web API サンプルのパスが消えないまま使われる（F1）」「自プロジェクトと合わない分岐が残る（F2）」を識別し、防御策として SAMPLE バナーとプロジェクト固有化手順（コピー → 書き換え → バナー削除 → frontmatter 更新）を明文化。

**Action**: docs-template に具体例（コードパス、ドメイン名、実装名）を含む新規テンプレファイルを追加する際は: (1) ファイル冒頭に `> ⚠️ **SAMPLE — テンプレートです**` 引用ブロックと書き換え案内を配置、(2) 末尾に「プロジェクト固有化の手順」セクション（番号付き手順 + frontmatter の `created/updated/owner` 置換まで含める）を配置、(3) 該当しない分岐・セクションは「**該当セクションごと削除してよい**」と明記、(4) 該当する失敗モード（採用後にサンプルのまま残る等）を仕様書側にリストアップしておく。

---

<a id="ace-007"></a>

### ACE-007: Claude Code skill 内のツール参照は名称・subagent_type を実機 / system prompt で照合する

| フィールド | 値                   |
| ---------- | -------------------- |
| Category   | tooling              |
| Origin     | PR #374 / Issue #373 |
| Date       | 2026-04-26           |
| Helpful    | 0                    |
| Harmful    | 0                    |
| Status     | active               |

**Insight**: Claude Code の skill 定義（`.claude/commands/*.md`）に SubAgent 起動を書く際、ツール名は **`Task`** であり `Agent` ではない。subagent_type も Claude Code 公式の組み込み（`Explore` / `general-purpose` 等）と照合する必要がある。誤った名称を skill に書くと、実行時にモデルが対応するツールを引けず失敗する。

**Context**: PR #374 の `/refine-issue` skill で `Agent ツール（subagent_type: Explore）` と記述したところ、4 つのレビュアー（Toolkit code-reviewer / comment-analyzer、Copilot、Gemini）のうち 3 つが「`Agent` ツールは Claude Code に存在しない、`Task` が正解」と独立して指摘。設計プラン側でも `Task tool` と `Agent(...)` の表記揺れがあった。Claude Code の system prompt で公式 tool 一覧と Available agent types を確認すれば防げる。

**Action**: skill 内で SubAgent / Tool 呼び出しを書く際は、(1) Claude Code の公式 system prompt 内 "Tools available" / "Available agent types" を確認、(2) ツール名 `Task` / `Edit` / `Read` 等を正確に書く、(3) `subagent_type` は組み込み（`general-purpose`, `Explore`, `output-style-setup`, `statusline-setup` 等）+ プロジェクトの `.claude/agents/` 定義を確認、(4) 環境依存の subagent_type（`Explore` 等）は `general-purpose` を fallback として併記する。

---

<a id="ace-008"></a>

### ACE-008: クロスリポジトリ操作する skill は全 gh コマンドに `--repo` 必須・mention は `@<assignee>` を使う

| フィールド | 値                   |
| ---------- | -------------------- |
| Category   | tooling              |
| Origin     | PR #374 / Issue #373 |
| Date       | 2026-04-26           |
| Helpful    | 0                    |
| Harmful    | 0                    |
| Status     | active               |

**Insight**: skill が「クロスリポジトリ対応」を謳う場合、`gh issue view` だけでなく **`gh issue edit` / `gh issue comment` / `gh label create` / `gh issue edit --add-label` の全てに `--repo <owner/repo>` を渡す**必要がある。1 つでも欠けると、別 repo の Issue を更新できないか、現在の repo の同番号 Issue を誤更新する。さらに mention placeholder は `@<owner>` だと GitHub が repo 所有者（organization）と解釈して**組織全体に通知が飛ぶ事故**が起きるため、`@<assignee>` を使う。

**Context**: PR #374 の `/refine-issue` skill 初版で、`gh issue view` には `--repo` を付けていたが後続の edit / comment / label create には付け忘れていた。Copilot と Gemini の両方が「全 gh コマンドに `--repo` を渡せ」を独立して指摘。さらに Gemini が `@<owner>` プレースホルダの誤メンション問題を指摘し、`@<assignee>` への変更を提案。

**Action**: クロスリポジトリ対応 skill を書く際は、(1) skill 冒頭の入力パースで `repo` を確定したら以降の **全** gh サブコマンドに `--repo <owner/repo>` を必須で渡す規約を明示、(2) skill 末尾に「使用する gh CLI コマンド一覧」テーブルを置いて保守者が一覧確認できるようにする、(3) mention placeholder は `@<assignee>` を使い、bot suffix（`[bot]`）は skip する fallback 規則を書く、(4) `gh label create` は `--force` で「不在時 create / 存在時 update」の冪等にする。

---

<a id="ace-011"></a>

### ACE-011: Prettier × markdownlint MD060 衝突は当該テーブルだけに `<!-- prettier-ignore -->` を付与する局所抑制で解く

| フィールド | 値                   |
| ---------- | -------------------- |
| Category   | tooling              |
| Origin     | PR #388 / Issue #386 |
| Date       | 2026-04-30           |
| Helpful    | 0                    |
| Harmful    | 0                    |
| Status     | active               |

**Insight**: Prettier と markdownlint は GFM テーブル整列の判定基準が異なる（Prettier は `string-width` / Unicode 11 emoji 幅、markdownlint MD060 は東アジア幅基準）。絵文字（🛠 など）混在テーブルでは、Prettier が「整列している」と判断する状態で markdownlint MD060 が「整列していない」と判断する、両者を同時に満たす整列が存在しない衝突状態が生じる。設定レベル（`proseWrap` / `printWidth`）で解決しようとしても無理（両者の幅算定アルゴリズム自体の差なので config では合わせられない）。最小スコープの解は当該テーブル直前に `<!-- prettier-ignore -->` を 1 行付与し、markdownlint 側に整列を合わせること。Prettier はその 1 ブロックだけスキップし、他のテーブル / 本文整形は通常通り効く。

**Context**: PR #388 で `prettier@^3.8.3` を Markdown 整形ツールとして導入する際、`docs/NO_GITHUB_ACTIONS_MIGRATION_DESIGN.md` の `🛠 Fixes` を含む 2 つのテーブル（行 47 / 行 151）で Prettier 整形後に MD060 が 3 件 fail する状態を確認。`format:md:check` と `lint:md` を同時に通したいが、`prettier --write` を当てると markdownlint が落ち、markdownlint に合わせると `format:md:check` が落ちる、というデッドロック。`<!-- prettier-ignore -->` を当該テーブルの直前に置き、markdownlint が要求する trailing-space 整列を保持する形で両立を実現。

**Action**: AI エージェントが Markdown lint と Markdown formatter を同居させるリポジトリで作業する際:

1. **Prettier 導入 PR では必ず先に `npm run format:md && npm run lint:md` を順に実行**してデッドロック箇所を洗い出す。後から個別 fix するより、衝突候補を最初に列挙する方が局所抑制スコープを正確に定義できる。
2. **衝突は「絵文字 / 全角記号 / 半角・全角混在」のテーブルセルに集中する**ことを前提に視覚検査する。string-width の Unicode 幅テーブルと markdownlint の幅判定の差は予測不能なので、empirical に当該行を見つけるしかない。
3. **`<!-- prettier-ignore -->` は当該テーブル / コードブロックの直前に 1 行置くだけ**。範囲指定（end コメントなど）は不要で、Prettier は次の単一ノードだけをスキップする。グローバル `.prettierignore` で対象ファイル全体を除外するのは過剰（他の整形が利かなくなる）なので避ける。
4. **PR 本文に「Prettier (string-width 基準) と markdownlint MD060 (異なる幅算定) で衝突する」理由を明記する**。再発時に他の作業者が同じ調査を 0 から繰り返さないため。
5. **`format:md:check` を `quality:local` に組み込む順序は `validate → format:md:check → lint:md`**。整形検査を構文検査の前に置くことで「整形漏れ」と「文法違反」が同時に出ても切り分けやすくなる。

---

<a id="ace-020"></a>

### ACE-020: 自動コンテンツ生成ツールは自身のマーカー文字列を本文に含むドキュメントを破壊する

| フィールド | 値                   |
| ---------- | -------------------- |
| Category   | tooling              |
| Origin     | PR #403 / Issue #402 |
| Related    | -                    |
| Date       | 2026-05-07           |
| Helpful    | 0                    |
| Harmful    | 0                    |
| Status     | active               |

**Insight**: セクションヘッダーを目印にしてファイル末尾を書き換える自動生成ツール（backlinks 自動更新、TOC 自動生成、auto-changelog 等）は、**そのマーカー文字列を本文中に説明として書いているドキュメントを破壊する**。マーカーが「セクション開始位置」と「本文の説明文」の両方の意味で出現するため、ツールは説明文の途中をセクション開始と誤認し、それ以降を全削除する。`tsc` や `npm test` では検出できない（ファイルは valid な markdown のまま）。問題はランタイムにのみ顕在化し、被害は破壊されたファイルが PR に紛れ込んだ後に気づく。

**Context**: 2026-02-12 commit `6ea43f8` (PR #311) で導入された `scripts/obsidian-sync.mjs` は各 markdown 末尾に `## Linked from` セクションを自動生成する設計だった。しかし `docs-template/08-knowledge/OBSIDIAN_GUIDE.md` 自身が「`## Linked from` セクションを自動生成する」と本文で説明しており、自動生成スクリプトはその文字列を section header と誤認して **OBSIDIAN_GUIDE.md を 379 行 → 26 行に破壊**（"各ドキュメント末尾に「" の途中で文章切断）。バグは 2026-05-07 の PR #400 マージ時に post-merge hook 経由で実行されて発覚し、Obsidian 統合全体の撤退判断（PR #403）の決定打となった。約 3 ヶ月間 silent に存在していた。

**Action**: 自動コンテンツ生成ツールを設計する際:

1. **マーカーは本文に出現しえない記法を選ぶ**: HTML コメント形式の sentinel（`<!-- BEGIN_BACKLINKS -->` ... `<!-- END_BACKLINKS -->`）など、説明文として地の文に書くのが不自然な形式を使う。`## Linked from` のような Markdown ヘッダーは本文の説明にも自然に登場するため不適。
2. **mutation 範囲を明示する begin/end ペアを必須にする**: 単一マーカーから「ファイル末尾まで全部置換」型は再帰汚染と相性が悪い。begin/end の両方が揃わないファイルはスキップする。
3. **自分自身の README/GUIDE を exclusion list に入れる**: ツールの動作を説明するドキュメントはそのツールの mutation 対象から外す。ツール側で `OBSIDIAN_GUIDE.md` のような既知ファイルを skip する allowlist/denylist を持つ。
4. **mutating tool は最低限の snapshot test を必ず添える**: 「マーカーを本文中に含むファイル」の golden file を input にして、出力が破壊されないことを assert するテストを最低 1 件入れる。tsc を通っただけでは ship してはいけない。
5. **post-merge / pre-commit など強制実行系に ship する前に dry-run モードを通す**: 自動化に組み込む前に、`--dry-run` で全対象ファイルへの想定変更を出力して目視レビューする。lint フックや husky に直接組み込んだ後はバグの被害が回復しにくい。

---

<a id="ace-039"></a>

### ACE-039: AI プロンプトテンプレに「分析観点リスト」と「分類カテゴリリスト」が並存する場合、新観点追加時はカテゴリ対応を観点側に明記する

| フィールド | 値                |
| ---------- | ----------------- |
| Category   | tooling           |
| Origin     | PR #423           |
| Related    | ACE-014 / ACE-024 |
| Date       | 2026-05-20        |
| Helpful    | 0                 |
| Harmful    | 0                 |
| Status     | active            |

**Insight**: AI プロンプトテンプレで「観点 N 項目 / カテゴリ M 種類」のように 2 つの列挙が並存する場合、新観点を追加するときに対応カテゴリを明記しないと AI が分類に迷う。観点リスト側に「カテゴリは X または Y を推奨」を 1 句書くだけで AI 出力の一貫性が大きく上がる。Gemini Code Assist のような副レビュアーが detect しやすい欠陥でもある。

**Context**: PR #423 で ACE Phase 1 Generate プロンプトに観点 7「判断ログ」を追加したが、L62 のカテゴリリスト（coding/architecture/testing/security/performance/devops/process/tooling）には観点 7 に対応する明示語がなく、Gemini Code Assist が medium priority で「観点 7 をどのカテゴリに分類すべきか不明確 → 推奨カテゴリを観点側に追記せよ」と指摘。fix commit で観点 7 に「カテゴリは `process` または `architecture` を推奨」を追記して解消。

**Action**:

1. **観点リストとカテゴリリストが並存するプロンプトで新観点を追加するときは、観点側に推奨カテゴリを明記する**: 「**観点名**: 説明（カテゴリは X または Y を推奨）」の形式で 1 句
2. **カテゴリリスト自体を観点と 1:1 にできる場合は構造化を優先**: 観点 N 項目とカテゴリ M 種類が異なる軸を持つ場合のみ (1) のパターンを使う
3. **副レビュアー（Gemini Code Assist 等の auto-bot）の medium priority 指摘は無視しない**: Toolkit 一次レビューで見逃すパターンを independent detect する役割を持つ。Critical でなくても「カテゴリ整合」「対応欠落」系の medium は対応すべき

---

<a id="ace-449-1"></a>

### ACE-449-1: `set -e` 下の bash 関数は末尾を `[[ cond ]] && cmd` で終わらせない — cond 偽で関数が非ゼロを返し呼び出し元の errexit がスクリプトを無出力で殺す

| フィールド | 値                   |
| ---------- | -------------------- |
| Category   | tooling              |
| Origin     | PR #449 / Issue #448 |
| Date       | 2026-07-02           |
| Helpful    | 0                    |
| Harmful    | 0                    |
| Status     | active               |

**Insight**: `set -euo pipefail` の下では、`[[ cond ]] && cmd` の失敗は「&&リストの途中」なら errexit を発火しないが、それが**関数の最終文**だと関数の戻り値が非ゼロになり、関数呼び出し（単純コマンド）として errexit が発火してスクリプト全体がバナーすら出さずに死ぬ。「デフォルト値がすでに設定済み」という正常系ほど cond が偽になるため、設定が充実した環境でだけ発症する。しかも同じイディオムはコピペで水平増殖する（本件は `apply_task_defaults` と `load_config` の 2 関数に存在）。

**Context**: PR #449 で `multi-agent.sh --dry-run` が exit 0・完全無出力なことを発見。develop 版でも再現したため自分の変更起因ではない既存バグと切り分けた。原因は `apply_task_defaults` 末尾の `[[ -z "$STRATEGY" ]] && STRATEGY=...` — config が全値を供給する（yq インストール済み + 同梱 config）環境では常に偽 → 関数が 1 を返し即死。`return 0` を追加して修正したが、Claude 系 silent-failure-hunter が同一クラスの残存を疑って走査し、`load_config` にも同パターン（`output_dir` 欠落 config で実機再現）を発見した。

**Action**:

1. `set -e` を使う bash スクリプトでは、関数末尾の `[[ cond ]] && cmd` に `return 0` を続けるか、`if` 文に書き換える。
2. この種のバグを 1 箇所直したら、**同じイディオムを同ファイル・同リポで grep して水平展開を確認**する（`&& .*$` で終わる関数末尾）。
3. ツールが「無出力で正常終了」したら、まず base ブランチで再現確認して既存バグか自変更起因かを切り分けてから直す。

---

<a id="ace-459-1"></a>

### ACE-459-1: git hook 環境から spawn するサブプロセス git は GIT\_\* を除去しないと実リポジトリを破壊する — テストフィクスチャの git init/commit が呼び出し元リポジトリを直撃した

| フィールド | 値                   |
| ---------- | -------------------- |
| Category   | tooling              |
| Origin     | PR #459 / Issue #453 |
| Related    | ACE-449-1            |
| Date       | 2026-07-02           |
| Helpful    | 0                    |
| Harmful    | 0                    |
| Status     | active               |

**Insight**: git は hook（pre-push 等）を実行するとき `GIT_DIR` 等の環境変数を設定する。hook から品質ゲート → テストランナー → テストフィクスチャの git コマンドと継承されると、フィクスチャの `git init` / `checkout -b` / `commit` が **tmpdir ではなく呼び出し元の実リポジトリを対象に実行**される。しかも途中まで成功する（ブランチ作成・コミット混入・`git init` による `core.bare=true` 書き換え）ため、失敗地点のエラーだけ見ても破壊に気付けない。特に linked worktree からの push で発火しやすい（メイン worktree の hook では GIT_DIR が設定されないことがあり、テストが「通っていた」ことは安全の証明にならない）。

**Context**: PR #459 で worktree から push した際、pre-push → quality:local → vitest → review-scripts.test.ts のフィクスチャ git が GIT*DIR を継承。実ブランチに "init" コミットが混入し、`feature/test` ブランチが作成され、メインの `.git/config` が `core.bare=true` に書き換えられた（`git rev-parse --show-toplevel` が全域で失敗する状態）。フィクスチャ env から `GIT*`プレフィックスを全除去する`sanitizedGitEnv()` で修正し、`GIT_DIR` を模擬設定した回帰テストで固定した。

**Action**:

1. テスト・スクリプトからサブプロセス git を spawn するときは、**`GIT_` プレフィックスの環境変数を全除去**した env を渡す（`GIT_CONFIG_GLOBAL=/dev/null` / `GIT_CONFIG_SYSTEM=/dev/null` の再設定もセットで）。
2. パス指定は cwd 依存にせず `git -C <対象ディレクトリ>` で固定する（hook 由来の環境でも対象がすり替わらない）。
3. リポジトリが不可解な壊れ方をしたら（`must be run in a work tree` 等）、`git config --local --list` で `core.bare` / `core.worktree` の汚染を疑う。

---

<a id="ace-460-1"></a>

### ACE-460-1: git diff の出力をパスで分類するツールは `--no-renames` を付ける — rename 表記 `{old => new}` は拡張子判定とディレクトリ前方一致の両方をすり抜ける

| フィールド | 値                   |
| ---------- | -------------------- |
| Category   | tooling              |
| Origin     | PR #460 / Issue #454 |
| Date       | 2026-07-02           |
| Helpful    | 0                    |
| Harmful    | 0                    |
| Status     | active               |

**Insight**: `git diff --numstat` はリネーム検出が有効だと `docs/{old.md => new.md}` 形式のパスを出力する。この表記は `case *.md)` のような拡張子分類にも `^scripts/` のような前方一致にもマッチしないため、パスベースの判定ロジック（レビューレベル判定、センシティブパス検知、対象ファイルフィルタ等）が**リネームを含む変更だけ静かに誤判定**する。特に「センシティブディレクトリへ跨いで移動するリファクタ」が重点レビュー判定を逃れるのは危険側の欠陥。

**Context**: PR #460 の review-level.sh 初版で発生。Toolkit pr-test-analyzer が実測（`git mv docs/old.md docs/new.md` → docs のみなのに code 扱い、`{lib => mcp/src}/util.ts` → Level 3 すり抜け）で検出した。`git diff --numstat --no-renames` に変更（rename が add+delete に分解され素のパスになる。行数は増えるが判定は安全側）し、rename 分類・跨ぎ移動の回帰テストで固定した。

**Action**:

1. `git diff` の出力パスを分類・マッチングするスクリプトでは **`--no-renames` を明示**する（判定の正確性 > 行数の見かけ）。
2. パス判定ツールのテストには「リネームを含む diff」のケースを必ず1本入れる（新規作成だけのフィクスチャでは rename 表記経路を通らない）。

---

<a id="ace-462-1"></a>

### ACE-462-1: 安全ゲートをスキップするか判定するループでは、空文字・想定外入力を「危険側」ではなく「安全側（ゲート実行）」に倒す — `case $x in *[!0]*)` は空文字を「全ゼロ」と同一視する

| フィールド | 値                   |
| ---------- | -------------------- |
| Category   | tooling              |
| Origin     | PR #462 / Issue #461 |
| Related    | ACE-449-1            |
| Date       | 2026-07-02           |
| Helpful    | 0                    |
| Harmful    | 0                    |
| Status     | active               |

**Insight**: 入力を分類して「安全ゲート（品質チェック等）をスキップするか」を決めるコードは、**想定外・欠落入力を必ずゲート実行側（fail-closed）に倒す**べき。特にシェルの `case "$x" in *[!0]*) ...` は「非ゼロ文字を含むか」の判定だが、**空文字列は `*[!0]*` にマッチしない**ため「全ゼロ（＝この文脈では削除＝スキップ）」と同一視され、フィールド欠落・空行がゲート回避（fail-open）を引き起こす。「肯定条件（削除だからスキップ）」だけを書くと、パターンに当てはまらない全入力が暗黙にスキップ側へ流れる。

**Context**: PR #462 で pre-push が「ブランチ削除のみの push（local sha 全ゼロ）は品質ゲートをスキップ」する実装に、Toolkit silent-failure-hunter が「空 `local_sha`（stdin のフィールド欠落・空行）が `*[!0]*` に非マッチ → deletions_only=true のままスキップ」という fail-open を検出（実測再現）。git 標準入力では発火しないが、`"") deletions_only=false` の1行追加で fail-closed に矯正し、フィールド欠落 stdin でゲート実行を検証するテストを追加した。

**Action**:

1. 安全ゲートのスキップ判定は「スキップしてよい条件」を厳密列挙し、それ以外（空・想定外・パース失敗）は**すべてゲート実行側**へ倒す（明示的な `"") ...` / `*) ...` 分岐を書く）。
2. `case ... *[!0]*` のような「否定文字クラス」は空文字を意図せず通すので、空文字ケースを別途明示する。
3. テストは正常系だけでなく「欠落・空・不正フィールド」の入力でゲートが**実行される**ことを1本以上固定する。

---

<a id="ace-24-2"></a>

### ACE-24-2: ビルド成果物（gitignore 対象の dist/）を直接起動する開発タスクは clean checkout で壊れる — build を含む npm script 経由にする

| フィールド | 値                 |
| ---------- | ------------------ |
| Category   | tooling            |
| Origin     | PR #24 / Issue #18 |
| Date       | 2026-07-07         |
| Helpful    | 0                  |
| Harmful    | 0                  |
| Status     | active             |

**Insight**: VSCode task・Makefile ターゲット・npm script などの開発者向けエントリポイントが、コミットされないビルド成果物（`dist/index.js` 等）を `node dist/index.js` のように直接参照すると、(1) clean checkout / 依存インストール直後の環境では成果物が未生成で起動失敗し、(2) ソース更新後もビルドを挟まないため古い成果物を起動する。特に、それまで存在したコミット済みのランタイムファイル（例: `index.mjs`）を削除して成果物参照へ切り替えるリファクタでは、削除前は動いていたぶん見落としやすい。

**Context**: PR #24 で orphan だった `mcp/index.mjs` を削除し、`.vscode/tasks.json` の `MCP: Start (stdio)` を `node index.mjs` から `node dist/index.js` へ書き換えたが、`dist/` は gitignore 対象のため clean 環境で起動失敗する状態だった。Codex code-reviewer が「build 依存がない／stale build 起動の恐れ」と指摘。同ファイルの `MCP: Check` が既に `npm run check`（= `npm run build && node dist/index.js --check`）へ移行済みだったため、`MCP: Start` も `npm run start`（= `npm run build && node dist/index.js`）に揃えて解消した。

**Action**: 開発タスクからビルド成果物を起動する場合は、成果物を直接指すのではなく build を内包した npm script（`start` / `check` 等、`"start": "npm run build && node dist/..."`）を経由させる。同一設定ファイル内に既にその方式のタスクがあれば命名・呼び出し方を揃える。コミット済みランタイムファイルを削除して成果物参照へ切り替える際は、その成果物が gitignore 対象かどうかと clean checkout での存在を必ず確認する。

---

<a id="ace-27-1"></a>

### ACE-27-1: pre-commit の変更ファイル列挙は `git diff --name-only | grep | xargs` ではスペース・非ASCII名を黙って取りこぼし、block を無効化する

| フィールド | 値                 |
| ---------- | ------------------ |
| Category   | tooling            |
| Origin     | PR #27 / Issue #21 |
| Date       | 2026-07-10         |
| Helpful    | 0                  |
| Harmful    | 0                  |
| Status     | active             |

**Insight**: pre-commit で変更ファイルを `git diff --cached --name-only | grep -E '\.md$' | xargs cmd` の素朴なパイプで列挙すると、2 経路でファイルを黙って落とす。(1) `xargs` は空白で単語分割するため `my doc.md` が 2 トークンに割れ「存在しないファイル」として skip される。(2) git 既定の `core.quotepath=true` は非ASCII（日本語・アクセント）パスを `"caf\303\251.md"` と C-quote するため行末が `.md"` になり `grep '\.md$'` に一致せず脱落する。結果、block を強制する検査でも該当ファイルだけ「問題なし」で通過し、保証が黙って成り立たない最悪の壊れ方をする。日本語ファイル名を扱うリポジトリでは実害が大きい。

**Context**: PR #27 で pre-commit に frontmatter/マジックナンバー検査を追加した際、Toolkit silent-failure-hunter が「café.md / スペース入り名は block モードを回避する」と再現付きで指摘（既存の markdownlint 行も同じ素朴パイプだった）。

**Action**: pre-commit の変更ファイル列挙は NUL 区切りで統一する: `git -c core.quotepath=false diff --cached -z --name-only --diff-filter=ACM -- '*.md' | xargs -0 cmd`。`core.quotepath=false`（非ASCII の C-quote 抑止）+ `-z`/`xargs -0`（NUL 区切りでスペース・改行に耐性）+ git pathspec `-- '*.md'`（grep 不要の拡張子フィルタ）の 3 点セット。空入力時は `xargs -0` がコマンドを引数なしで 1 回実行する（macOS/GNU 共通）ため、スクリプト側で「引数 0 件は何もせず exit 0」を保証しておく。

---

<a id="ace-29-1"></a>

### ACE-29-1: lint-staged で warn-only 検査を回すなら `--verbose` は必須 — 既定は成功タスクの stdout を隠し、警告が丸ごと消える

| フィールド | 値                 |
| ---------- | ------------------ |
| Category   | tooling            |
| Origin     | PR #29 / Issue #28 |
| Date       | 2026-07-10         |
| Helpful    | 0                  |
| Harmful    | 0                  |
| Status     | active             |
| Related    | ACE-27-2           |

**Insight**: lint-staged は exit 0 で終わったタスクの stdout を既定で隠す（失敗タスクのみ出力を表示）。warn-only の検査（検出があっても exit 0 で警告だけ出すマジックナンバー検出や frontmatter warn モード）を lint-staged に載せると、`--verbose` を付けない限り警告が一切表示されず、検査は「動いているが誰にも見えない」= 実質無意味になる。block する検査（markdownlint 等）は失敗時に出力されるため気づけるが、warn-only は成功扱いなので沈黙する。

**Context**: PR #29 で pre-commit の手書き列挙（[ACE-27-1](./tooling.md#ace-27-1)）を lint-staged に統一した際、旧フックは `xargs ... || echo warn` で warn-only 出力を明示的にエコーしていた。lint-staged 化で同じ可視性を保つには `npx lint-staged --verbose` が必要と判明。Toolkit silent-failure-hunter も「--verbose が load-bearing」と指摘。

**Action**: lint-staged に warn-only 検査を 1 つでも載せるなら `.husky/pre-commit` を `npx lint-staged --verbose` にする。`--verbose` は全成功タスクの出力を表示するため通常コミットは少し冗長になるが、warn-only の警告を surface する唯一の方法。テストでは「warn 出力に既知の文字列が含まれる」ことを assert して、`--verbose` 欠落の回帰を固定する。

---

<a id="ace-29-2"></a>

### ACE-29-2: devDep を足すときは `engines.node` を満たす major を選ぶ — 「latest」が宣言サポート下限を割ることがある

| フィールド | 値                 |
| ---------- | ------------------ |
| Category   | tooling            |
| Origin     | PR #29 / Issue #28 |
| Date       | 2026-07-10         |
| Helpful    | 0                  |
| Harmful    | 0                  |
| Status     | active             |

**Insight**: 新しい devDependency を `npm install <pkg>` で足すと latest が入るが、latest が project の `engines.node` 下限を割ることがある。lint-staged は 17 が node `>=22.22.1`、16 が `>=20.17`、15 が `>=18.12` を要求する。project が `engines.node: >=20.0.0` を宣言しているなら、15 でないと node 20.0〜20.16 を除外してしまい宣言と矛盾する（16 は `>=20.17` で下限を割る）。ローカルの node が新しいと気づきにくい。

**Context**: PR #29 で lint-staged 導入時、`npm view lint-staged@<major> engines.node` で各 major の node 要件を確認し、`engines.node: >=20.0.0` と完全整合する 15 系（`^15.5.2`）を選定した。

**Action**: devDep 追加前に `npm view <pkg>@<major> engines.node` を major ごとに引き、project の `engines.node` 下限を**完全に包含する**最大の major を選ぶ（「latest」を無条件に採らない）。宣言を引き上げてよい（例 `>=20.17`）なら別判断として明示する。lockfile とローカル node が新しいと CI/他環境で初めて壊れるため、宣言値ベースで選ぶ。

---

<a id="ace-66-1"></a>

### ACE-66-1: インストーラの exit 0 は導入完了ではない — post-install で実バイナリの存在・flavor を再検証し、失敗分岐もテストする

| フィールド | 値                 |
| ---------- | ------------------ |
| Category   | tooling            |
| Origin     | PR #66 / Issue #23 |
| Date       | 2026-07-21         |
| Helpful    | 0                  |
| Harmful    | 0                  |
| Status     | active             |

**Insight**: `install_yq` や `brew install` のような導入ステップが exit 0 を返しても、「期待した実行可能ファイルが PATH 上にあり、期待した実装・バージョンで動く」ことは保証されない。既存の別実装が PATH 前方に残る、インストール先が PATH に無い、パッケージマネージャが別 flavor を入れる、という post-install 失敗は終了コードだけでは検出できないため、導入直後に `command -v` と `--version` 等の実体検証を fail-loud に行う。

**Context**: PR #66 で `setup-multi-agent.sh` に mikefarah 版 `yq` の自動導入と fail-loud 検証を追加した。Codex pr-test-analyzer は「`install_yq` が返っても wrong `yq` が PATH に残る / `yq` が無い」post-install 分岐のテスト不足を指摘。`install_yq` を 0 にスタブした上で、PATH に別実装 yq が残るケース、yq が存在しないケース、install 後に別実装が現れるケースを追加し、終了コードだけを信用して続行する回帰を防いだ。

**Action**: ツール導入処理では、導入関数の成功直後に必ず「(1) `command -v <tool>` が通る、(2) `<tool> --version` 等で期待 flavor / version を満たす、(3) 満たさなければ設定読み取りや後続処理へ進まず return 1」の3点を実装する。テストは install 関数を成功スタブにして、実体不在・wrong flavor・PATH 前方の stale binary の各分岐が fail-loud になることを固定する。

---

<a id="ace-70-2"></a>

### ACE-70-2: CLI ラッパーがモデル・バージョン等の既定値を持つと SSOT が二重化して必ず腐る — 設定機構がある CLI には既定値ごと委譲する

| フィールド | 値                 |
| ---------- | ------------------ |
| Category   | tooling            |
| Origin     | PR #70 / Issue #69 |
| Related    | ACE-014, ACE-36-1  |
| Date       | 2026-07-22         |
| Helpful    | 0                  |
| Harmful    | 0                  |
| Status     | active             |

**Insight**: CLI をラップするスクリプトが「モデル slug」「ランタイムバージョン」のような**世代交代する値**の既定値を持つと、その値の SSOT がユーザーの CLI 設定とラッパーの 2 箇所に分裂し、ラッパー側が必ず古くなる。しかもラッパーがフラグを**無条件に渡す**実装だと、ユーザー設定を黙って上書きするうえ、同じ設定ファイル内の関連項目（例: reasoning effort）は上書きされないため「古いモデル + 新しい付随設定」という誰も意図していない組み合わせで動く。正しい形は「env が設定されている時だけフラグを組み立て、未設定ならフラグ自体を渡さない」。これで最新追従は CLI 設定が担い、明示指定は env で効き、ラッパーのメンテはゼロになる。

**Context**: `scripts/codex-review.sh` は `CODEX_MODEL="${CODEX_MODEL:-gpt-5.4}"` と既定値を持ち `codex exec -m "$CODEX_MODEL"` と常に渡していた。ユーザーの `~/.codex/config.toml` は `model = "gpt-5.6-sol"` / `model_reasoning_effort = "xhigh"` だったため、普段より 2 世代古いモデルに xhigh の reasoning だけが乗った状態でレビューが走っていた。過去に `gpt-5.3` → `gpt-5.4` の手動更新コミットが実在し、腐敗が反復していたことが確認できた。同ディレクトリの `gemini-review.sh` は既に条件付き配列パターンで正しく実装されており、5 本のラッパーのうち 3 本が委譲済み・2 本が固定という不統一だった。

**Action**:

1. ラッパーで外部 CLI を呼ぶとき、その CLI に設定ファイル / プロファイル機構があるなら**既定値を持たない**。`ARGS=(); [ -n "${ENV_VAR:-}" ] && ARGS=("--flag" "$ENV_VAR")` の形にし、未設定時はフラグを渡さない。配列を使うのは値に空白が含まれても 1 引数に保つため。
2. 同種のラッパーが複数あるなら、着手前に全部を横断確認してパターンの不統一を洗い出す（片方だけ直すと次の腐敗が別ファイルで再発する）。
3. 委譲には代償がある — ラッパーの表示が「実際に何を使ったか」を保証できなくなる。表示は「config 由来」と正直に書き、実使用値の記録が要る場合は CLI の出力（多くは stderr の起動バナー）から**観測値**を拾う。仮定を事実として表示しない。
