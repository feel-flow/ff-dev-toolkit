# PLAYBOOK — プロセス (process)

> **Parent**: [PLAYBOOK.md](../PLAYBOOK.md) — 運用ルール・エントリテンプレート・ID規則・記述ガイドラインは親ファイルの SSOT を参照。
>
> 新規エントリは本ファイル末尾に追記し、[PLAYBOOK.md の索引テーブル](../PLAYBOOK.md#エントリ一覧)にも 1 行追加する。

---

## エントリ一覧

<a id="ace-001"></a>

### ACE-001: クロスモデルレビューは単一AIモデルでは検出できない問題を発見する

| フィールド | 値                |
| ---------- | ----------------- |
| Category   | process           |
| Origin     | PR #316 / PR #319 |
| Date       | 2026-03-10        |
| Helpful    | 8                 |
| Harmful    | 0                 |
| Status     | active            |

**Insight**: 異なるAIモデル（Claude/Codex/Gemini/CodeRabbit）は異なるカテゴリの問題を検出する。単一モデルのレビューでは見落とされる問題が、クロスモデルレビューで発見される。

**Context**: PR #316（ドキュメント）では Claude がnpmパッケージ名の間違いと壊れたリンク、Codex がスクリプト未実装注記の不足、Gemini Bot がパッケージスコープの間違いと無料枠数値の不一致、CodeRabbit が未実装スクリプトの注記不足を検出。PR #319（スクリプト）では Codex が CRITICAL_BLOCK 誤検出バグを発見し、Claude の pr-review-toolkit（code-reviewer + silent-failure-hunter）が stderr 握りつぶし・サイレントフォールバック・空結果の偽成功を検出。いずれも単一モデルでは検出されなかった。

**Action**: PR作成前のセルフレビューでは、`pr-review-toolkit`（Claude系サブエージェント）と `codex review --base develop`（GPT系クロスモデル）の両方を実行する。Bot系レビュー（Gemini Code Assist, CodeRabbit）がある場合はその指摘も確認する。

---

<a id="ace-004"></a>

### ACE-004: ドキュメントの動作説明は実装メカニズムと一致させる

| フィールド | 値         |
| ---------- | ---------- |
| Category   | process    |
| Origin     | PR #350    |
| Date       | 2026-03-18 |
| Helpful    | 1          |
| Harmful    | 0          |
| Status     | active     |

**Insight**: ドキュメントに「自動実行」と記載したが、実際にはCLAUDE.mdの指示に基づいてAIツールが順次実行する仕組みだった。「自動」「手動」「並列」「順次」等の動作表現が実装メカニズムと乖離すると、読者（人間・AI両方）が誤った前提で行動し、トラブルシューティング時に混乱する。

**Context**: PR #350 のレビューでCodeRabbitが「自動実行」表現と`execute_tasks()`の実装（事前計画の一括/順次実行）の不一致を指摘。また`npm run code-review:codex`が`package.json`に未定義であることも発覚。ドキュメント作成時に「こうなるべき」を「こうなっている」として記述してしまうパターン。

**Action**: ドキュメントに動作説明を書く際は、(1) 実装コード/設定ファイルで実際の動作を確認、(2) 記載するコマンドは実在を検証（`package.json`のscripts、`--help`出力等）、(3) 「自動」「手動」等の表現は実装メカニズムに基づいて正確に選択する。

---

<a id="ace-009"></a>

### ACE-009: 長時間 Orchestrator の失敗の真因は upstream Issue spec 曖昧さ — 探索型 refine が必要

| フィールド | 値                   |
| ---------- | -------------------- |
| Category   | process              |
| Origin     | PR #374 / Issue #373 |
| Date       | 2026-04-26           |
| Helpful    | 0                    |
| Harmful    | 0                    |
| Status     | active               |

**Insight**: AI Orchestrator (完遂型 / A 型) で Issue を自動完遂する仕組みが「結構できないものが多い」と感じたとき、真因は **Orchestrator の賢さ不足ではなく、入力 Issue の spec 曖昧さ**であることが多い。曖昧な spec を渡された Orchestrator は推測で穴埋めするしかなく、ハズす。必要なのは「曖昧な Issue → 実行可能な Issue」に研ぎ澄ます探索型 (B 型) skill を upstream に置くこと。

**Context**: 当初は「長時間駆動 Orchestrator + compact 耐性」のアーキテクチャをブレストしていたが、「A 型 Orchestrator の失敗パターン」を深掘りした結果、根本原因が Issue spec 自体の曖昧さに移動。`/create-issue`（新規 Issue ゲート）は既存だったが、既に立った曖昧 Issue を refine する手段がなかった。`/refine-issue` MVP を先に作ってから Orchestrator ループ・司令ファイルを後付けする路線にスコープ変更し、6 観点ブレストで設計を確定。

**Action**: 「AI agent が信頼できない / 完遂率が低い」と感じたら、(1) agent 自体の改善より先に、与えている入力データ (Issue / spec / プロンプト) の品質を疑う、(2) upstream に「入力を磨く skill」を置けないか検討する、(3) ブレストで「真因が一段下のレイヤーにある」可能性を必ず一度は検証する、(4) MVP は upstream の単一 skill に絞り、Orchestrator ループ等は動作確認後に後付けする路線が安全（空回りを高速化するリスクを避ける）。

---

<a id="ace-010"></a>

### ACE-010: Issue クローズ前は commit log でなく現在のファイル実体を grep 照合する — silent regression を検出する

| フィールド | 値                   |
| ---------- | -------------------- |
| Category   | process              |
| Origin     | PR #387 / Issue #360 |
| Date       | 2026-04-30           |
| Helpful    | 0                    |
| Harmful    | 0                    |
| Status     | active               |

**Insight**: Issue が PR で完了したと判断する際、関連 PR の commit message・diff・タイトルだけを根拠に「完了」と決めるのは危険。同じファイルを触る後続 PR が stale-base merge / 衝突解決ミスで silent revert を起こしている可能性があり、commit log を遡るだけでは「現在の develop の実体」を保証できない。今回 Issue #360（MD060 lint 有効化）は PR #384 で完了したと判断して一旦クローズしたが、46 分後にマージされた PR #377（chore: no GitHub Actions）が `.markdownlint.json` に `"MD060": false` を再追加する形で silent revert していた。develop の実体は未達成のまま、再 open と修正 PR #387 が必要になった。

**Context**: Issue #360 / PR #383 / PR #384 / PR #377 が 2026-04-27 数時間以内に同じ config と表整形を並行で触り、AI エージェントが PR #384 の commit メッセージ「MD060 再有効化」を根拠に「Issue #360 は完了」と判断してクローズを実行。Issue #386（後継 Prettier 導入）に着手する直前に develop の `.markdownlint.json` を実際に開いたところ `"MD060": false` が残存していて regression が発覚。`git log -p .markdownlint.json` で追跡すると PR #384 → PR #377 の順で「有効化 → 再無効化」になっていた。

**Action**: AI エージェントが Issue / PR を「完了」として閉じる前に必ず:

1. **受け入れ基準を develop の最新実体に対して検証する** — `git switch develop && git pull --ff-only` の後で `cat path/to/config` または `grep -n target path/to/config` で受け入れ基準が満たされているかを直接確認する。Closes #N が含まれる commit が積まれていることは「実体が達成されている」ことを意味しない。
2. **受け入れ基準が config / lint / format / CI 設定系なら、当該ファイルの直近 N コミットを必ず追う** — `git log -p -10 path/to/config` で関連時期に silent revert がないかチェックする。1 行追加 / 1 行削除の往復は git log で時系列を見ないと発見しにくい。
3. **同領域を触る PR が並行している時期は特に警戒する** — 24h 以内に同 path を触る PR が 2 件以上あり、片方が古い base から派生している場合 stale-base merge による silent regression のリスクが高い。merge 後に必ず実体検証を挟む。
4. **AI エージェントが「クローズ判断」のような shared state 操作を行う前に advisor / 別 agent に検証させる** — 大規模リポジトリで commit メッセージだけで判断するのはハイリスク。

---

<a id="ace-012"></a>

### ACE-012: PR マージ・push 前は必ず `git status` でブランチを確認する（develop 直 push 事故防止）

| フィールド | 値                             |
| ---------- | ------------------------------ |
| Category   | process                        |
| Origin     | PR #391 / PR #393 / Issue #295 |
| Date       | 2026-05-06                     |
| Helpful    | 0                              |
| Harmful    | 0                              |
| Status     | active                         |

**Insight**: バックグラウンドでブランチが切り替わる事象は外部プロセス（他作業者の `gh pr merge`、IDE 拡張、自動化フック等）で発生しうる。**自分のターン内で `git checkout` していないことは、現在のブランチが想定通りである保証にならない**。`git push` の直前には必ず `git branch --show-current` または `git status` の出力を確認する。同様に Issue 着手時は、同 Issue 用の他ブランチや未追跡ファイルが既に存在しないか `git branch | grep -w <issue-number>` および `git status -uall` で確認する習慣を入れる。

**Context**: Issue #295 の作業中、PR #391 がユーザーまたは他プロセスにより突然マージされ、ローカル HEAD が feature branch から develop に自動切り替わった。この切り替わりに気づかず `git push` した結果、レビュー対応コミット（ba391fa）が develop に直接乗り、`Never commit directly to develop` ルールに違反。`git revert ba391fa` + 新 PR #393 で正規化が必要となった。さらに同 Issue の作業着手時にも、別ブランチ `feature/#295-organization-rollout-guide` と未追跡ファイル `06-reference/ORGANIZATION_ROLLOUT.md` が既に存在することに気づかず、無自覚に重複作業を作りかけた。

**Action**: AI エージェントが Git 操作を行う際:

1. **Issue 着手前の確認**: `git branch | grep -w <issue-number>`、`git status -uall` で同 Issue の他ブランチ・未追跡ファイル・進行中の作業がないかチェック。並列作業の発見時はユーザーに統合方針を相談する。
2. **`git push` の直前**: `git branch --show-current` を必ず実行し、想定ブランチと一致するか確認。一致しない場合は push を中止して原因調査。
3. **PR 操作前の状態確認**: `gh pr view <PR>` で他者によるマージ・close を事前確認。マージ済みなら作業内容を新ブランチに分離。
4. **develop / main に直 push してしまった場合**: `git revert <SHA>` で revert commit（変更を打ち消す新規 commit）を作成 → push して直 push 分を無効化、同内容を新ブランチに cherry-pick して正規 PR で再投入する。`git reset --hard` + force push は履歴削除を伴い他協働者に影響するため避ける。
5. **PR ready / merge 操作前**: 直前にもう一度 `git status` でローカルが想定状態か確認。push 済 commit と PR head が一致しているかも `gh pr view <PR> --json headRefOid` で照合する。

---

<a id="ace-013"></a>

### ACE-013: 並列 reviewer の指摘は古い snapshot 由来の誤検知を含む — 実態 grep で双方向検証する

| フィールド | 値                             |
| ---------- | ------------------------------ |
| Category   | process                        |
| Origin     | PR #391 / PR #393 / Issue #295 |
| Date       | 2026-05-06                     |
| Helpful    | 1                              |
| Harmful    | 0                              |
| Status     | active                         |

**Insight**: Toolkit / Copilot / Gemini Code Assist 等の並列レビューでは、**reviewer が PR の特定 commit（多くは初回 push 時点）を見ている都合で、すでに修正済みの内容を Critical として再指摘するノイズ**が混入する。逆に reviewer が実態を正しく見抜いて指摘した場合、**こちらが「修正済み」と思い込んで grep 確認を怠ると本物の Critical を見逃す**。指摘を受け取った瞬間に `grep -n` で実態確認し、**両方向**（false positive / true positive）を切り分ける。これを怠ると、誤検知に基づいて再修正してファイルを破壊するか、本物のバグを残してマージしてしまう。

**Context**: PR #391 で 1500 行残存（C1 / C2）と bash 「上記出力」プレースホルダ（S1）を Toolkit / Copilot / Gemini が並列 Critical として指摘したが、`grep -n "1500" <該当ファイル>` で確認したところすでに修正済みだった（reviewer 側の snapshot が古かった）。スキップ判断で正解。逆に PR #393 では archive-strategy.md に追記した「`archive/README.md` は提供されていない、初回作成する」記述に対し、Toolkit が「実態は PR #391 で雛形として既に追加済み」と Critical 指摘。`ls docs-template/archive/` で確認したところ事実だったため、即修正した。**両ケースとも、grep / ls による実態確認なしで判断していたら誤った PR 状態でマージされていた**。

**Action**: PR レビューを受け取った AI エージェントは:

1. **指摘の真偽は常に grep で検証**: Critical / Important / Suggestion の区別なく、指摘箇所を `grep -n "<キーワード>" <該当ファイル>` で検索。検出されなければ false positive、検出されれば true positive。
2. **false positive の対応**: 修正をスキップし、PR コメントに「該当箇所は commit XXXX で修正済み（reviewer の snapshot が古い可能性）」と返す。**勝手にスキップせず明示する**ことで、後続 reviewer が同じ指摘を繰り返すのを防ぐ。
3. **true positive の対応**: 通常通り fix commit。PR 本文に「実態確認の結果、X は確かに〜」と記録する。
4. **複数 reviewer が同じ箇所を指摘した場合**: snapshot 時刻を `gh pr view --json reviews --jq '.reviews[].submittedAt'` で確認。すべて同時刻に近いなら共通の古い snapshot 由来、ばらついているなら真正のバグの可能性が高い。
5. **逆方向の罠も警戒**: 「Toolkit が指摘していないから OK」と思い込まず、自分の追記内容（特にテンプレート実態に関する主張）は `ls` / `cat` で実物を確認してから書く。**書きながら一度実物を見る**を習慣にする。

---

<a id="ace-017"></a>

### ACE-017: 並列 review agent は worktree を巻き戻す副作用を持ち得る — `git status` 監視と `git restore --source=HEAD` で復旧する

| フィールド | 値                   |
| ---------- | -------------------- |
| Category   | process              |
| Origin     | PR #395 / Issue #296 |
| Date       | 2026-05-06           |
| Helpful    | 0                    |
| Harmful    | 0                    |
| Status     | active               |

**Insight**: main worktree で **複数の review agent を並列起動**した場合、agent が分析過程で `git restore` / `git checkout` 系のコマンドを実行（典型的には「PR 前の状態と diff を見るため」「base branch の内容を確認するため」）し、staged + working tree が **base コミットの状態に巻き戻る**事故が発生し得る。HEAD ポインタと remote push 済みの commit は無事のため、被害はあくまで「working tree が一時的に古くなる」レベルだが、**気付かずに次の編集を始めるとマージ事故**になる。`git restore --source=HEAD --staged --worktree <files>` で即時復旧可能。**並列 review agent 起動直後は必ず `git status --short` で working tree が clean かを確認する**。worktree を別に切る `--worktree` モードで起動できるなら、それが最も安全。

**Context**: PR #395 で Toolkit `code-reviewer` と `comment-analyzer` を並列起動（Agent tool の単一メッセージ複数 tool*use）して review report を受け取った直後、5 ファイル全てが「Modified」かつ index にも staged で **pre-PR 状態（追加した 150 行が消えた状態）**になっていることを system reminder 経由で発見。`git log` 上の HEAD は `6a80bc4`（自分の commit）のままで remote も同じ位置だったため、どこかの agent が `git restore --source=develop --staged --worktree <files>` 相当を実行したと推定。`git restore --source=HEAD --staged --worktree .github/ISSUE_TEMPLATE/feature.md .github/pull_request_template.md docs/AI*\*.md`で即時復旧、その後の review-fix と merge は問題なく進行。**この事故は HEAD/remote が無事だから復旧できたが、もし agent が`git reset --hard` 相当を実行していれば commit ごと失っていた\*\*ため、防止策の優先度は高い。

**Action**: 並列 review agent を起動する際:

1. **起動前に commit + push を完了させる**: HEAD と remote が無事なら最悪 working tree 巻き戻りでも復旧可能。「未コミットのまま review 起動」は避ける。
2. **起動直後の `git status` 監視を習慣化**: 並列 agent の report 受取後は、内容を読む前に **必ず `git status --short` を実行**。staged 修正 (左カラム `M`)・unstaged 修正 (右カラム `M`)・両方 (`MM`) のいずれかが出たら巻き戻しの可能性。
3. **巻き戻りに気付いたら即復旧**: HEAD が無事なら `git restore --source=HEAD --staged --worktree <files>` で working tree と index を HEAD 状態に戻す。`grep` で追加内容（例: 「PR Size Check」「6 観点」）が file に残っているか復旧後検証。
4. **`isolation: "worktree"` モードで起動**: Agent tool 側に `isolation` パラメタがある場合、`worktree` を指定すると agent は隔離された一時 worktree で作業するため、main worktree の状態に副作用を与えない。本 PR の review agent は `isolation` を指定せず main worktree で動かしたが、これは将来的に標準 isolation 化を検討すべき。
5. **`git reset --hard` を含む destructive 操作の禁止周知**: agent prompt に「**`git reset --hard` / `git restore --source=<base>` / `git checkout <base> -- .` は実行禁止。read-only 操作（`git diff`, `git show`, `git log`）に限定する**」と明記する。レビュー目的ならどの操作も destructive 不要。

---

<a id="ace-019"></a>

### ACE-019: 既存ルール違反になる新パターンは「例外」として明示的に名乗らせる

| フィールド | 値                   |
| ---------- | -------------------- |
| Category   | process              |
| Origin     | PR #397 / Issue #396 |
| Related    | ACE-012（修正対象）  |
| Date       | 2026-05-06           |
| Helpful    | 1                    |
| Harmful    | 0                    |
| Status     | active               |

**Insight**: 新しい運用パターンが既存 PLAYBOOK エントリ・グローバルルールに違反する場合、**「これは X の例外として扱う」と該当箇所に明示的に書く**。書かないと暗黙の policy split が生じ、(a) 後続 AI が古いルールを参照して新パターンを「違反」として扱う、(b) Toolkit / Copilot が Critical として指摘する、(c) チームメンバーがどちらを優先するか迷う。Comment-analyzer は「実装は妥当だが既存の禁則と衝突しているのに carve-out が無い」を Critical 指摘として独立検出する精度を持つため、PR レビュー前に自分で見つけて潰すべき。

**Context**: PR #397 で「個人開発（簡易）」パターン（マージ後に develop へ ACE エントリを直接 commit + push）を導入。これは PLAYBOOK ACE-012「Never commit directly to develop」と直接衝突するため、Toolkit comment-analyzer が「ACE-012 を名指しで違反、carve-out が必要」と Critical 指摘。fix commit b75f86d で 5 サイト（CLAUDE.md / AI_GIT_WORKFLOW.md / git-workflow.md / ace-cycle.md / ace-curate.md）に「**ACE-012 の例外として明示**: 通常 develop への直接 commit は禁止だが、(1) PLAYBOOK.md は append-only、(2) 1 サイクル分の知見追加は履歴上独立 commit として読める、(3) `knowledge:` プレフィックスで識別可能 — の 3 条件を満たすため、個人開発（簡易）パターンに限り許容する。3 人以上のリポジトリでは適用しない。」と注記して解消。実装の正当性自体は問題なく、欠けていたのは **「これは違反ではなく例外である」という明示的な naming** だけだった。

**Action**: 新運用パターン・新コーディング規約を導入するときに:

1. **既存 PLAYBOOK / CLAUDE.md / 規約と衝突するか chec先**: 着手前に `grep -rn "<該当キーワード>" docs-template/08-knowledge/ CLAUDE.md ~/.claude/CLAUDE.md` で対立するルールを列挙する。特に "Never X" / "禁止" / "MUST NOT" 表現は要注意。
2. **対立が見つかった場合の選択肢は 3 つ**:
   - **(a) 例外として明示**: 違反箇所に「これは ACE-XXX / CLAUDE.md L<行> の例外である。理由: ...」と明記。最も一般的で安全。
   - **(b) 旧ルールを deprecated 化**: 旧 ACE エントリの Status を `deprecated` にし、新パターンを正規ルールとして昇格。旧コミッタへの周知が必要。
   - **(c) 新パターンを撤回**: 違反コストが exception 注記を上回ると判断したら、新パターンを採用しない。
3. **「明示」のレベルは 3 点セット**: 例外であることの宣言 + 例外を許す**条件**（最低 3 つ）+ 例外が**適用されないケース**（チーム規模・リポ性質などの境界）。3 点揃わないと「言い訳」に見えて信頼されない。
4. **複数サイトに展開する場合は文言を verbatim に揃える**: 例外の説明が文書ごとに微妙に違うと「結局どれが正？」になる。canonical な 1 文を決めて全サイトに同じ文言で貼る（ACE-014 の SSOT 原則を例外説明にも適用）。
5. **Cross-Model Review で取りこぼしを catch する**: 例外を書いたつもりでも文言が弱い・条件が抜けている場合、Toolkit comment-analyzer / Copilot が指摘する。彼らに任せて自分は「全サイトに書いたか」「文言が揃ったか」のチェックに集中する。

---

<a id="ace-022"></a>

### ACE-022: 機能削除時は consumer だけでなく定数・型・ユーティリティも grep して取り残しを防ぐ

| フィールド | 値                   |
| ---------- | -------------------- |
| Category   | process              |
| Origin     | PR #403 / Issue #402 |
| Related    | ACE-018              |
| Date       | 2026-05-07           |
| Helpful    | 0                    |
| Harmful    | 0                    |
| Status     | active               |

**Insight**: 機能を削除する PR では、**機能本体ディレクトリ削除 → consumer 編集 → ビルド OK** で完了したように見えるが、**TypeScript の `tsc` は未使用 export を warning しない**ため、その機能のためだけに作られた定数・型・ユーティリティが他モジュールに孤立して残る。`npm run build` も `npm run check` も pass するので CI では検出されない。手動 grep を「機能名 / 機能専用識別子」で実行しないと dead code として静かに残り続ける。

**Context**: PR #403 で `mcp/src/obsidian/` 配下 5 ソース + `scripts/obsidian-sync.mjs` 等 13 ファイル削除 + 7 ファイル編集を実施。`git grep -i obsidian` で「Obsidian」文字列の取り残しはゼロを確認、`mcp build`/`mcp check`/`quality:local` も全 pass。しかし Toolkit code-reviewer が `mcp/src/constants.ts:21-36` の `BACKLINKS_SECTION_HEADER` と `BACKLINKS_SECTION_TEMPLATE` を **dead code として検出**。これらは削除済み `mcp/src/obsidian/backlinks.ts` でだけ使われていた定数で、ビルドは通るが「完全排除」を謳う PR タイトル・CHANGELOG と矛盾する状態だった。fix commit `8628140` で対応。レビューが無ければ silent regression として残った。

**Action**: 機能削除 PR を作る際:

1. **機能名でなく機能の語彙すべてで grep する**: 「Obsidian」だけでなく、その機能専用の識別子（`BACKLINKS_SECTION_*`、`buildBacklinksMap`、`validateAllLinks` など）も全部 grep キーワードに含める。`git grep -i "<feature_name>\|<feature_specific_constants>\|<feature_function_names>"` を 1 コマンドにする。
2. **削除候補を「本体 / 設定 / 定数 / 型 / 関数 / テスト / ドキュメント」の 7 カテゴリで網羅する**: 機能本体ディレクトリだけ消して終わりにせず、Issue 本文の「削除対象」リストにこの 7 カテゴリを明示し、TodoWrite で 1 つずつ確認する。
3. **「未使用 export 検出」ツールを CI に入れる**: `ts-prune`、`knip`、`unimported` など TypeScript 用の dead code 検出ツールを quality:local に組み込む。一度入れれば類似の取り残しを継続的に防げる。
4. **削除 PR の self-review に「孤立 export チェック」を含める**: PR Review チェックリストに「削除した機能の専用 constants/types/utilities が他モジュールに残っていないか？ `git grep` で確認」項目を追加。Toolkit code-reviewer はこの種の検出が得意なので、必ず通す。
5. **同じモジュール内に定数を置く設計を選ぶ**: 機能専用の定数は `mcp/src/<feature>/constants.ts` のように **機能ディレクトリ配下に閉じ込める**。削除時に親ディレクトリごと消せば取り残しが構造的に発生しなくなる。共通 constants ファイルへの追加は「本当に他機能でも使うか？」を着手前に問う。

---

<a id="ace-034"></a>

### ACE-034: 実装中は implementation-notes.md を作業ブランチに並走させて spec 乖離・トレードオフ・判断理由を捕捉する

| フィールド | 値                                                 |
| ---------- | -------------------------------------------------- |
| Category   | process                                            |
| Origin     | 外部知見（Anthropic エンジニア公開実装プロンプト） |
| Related    | ACE-009 / ACE-023 / ACE-032                        |
| Date       | 2026-05-19                                         |
| Helpful    | 0                                                  |
| Harmful    | 0                                                  |
| Status     | active                                             |

**Insight**: 実装着手から PR 作成までの間、作業ブランチ直下に `implementation-notes.md` を 1 枚並走させ、(1) spec に書かれていなかった判断、(2) spec から変更した点、(3) 取った/捨てた選択肢とその理由（トレードオフ）、(4) レビュアー・ユーザーが知るべきその他情報を逐次記録する。コミット diff とレビューコメントには「why / 捨てた選択肢 / spec との差分」が残らず、ACE Phase 1 Generate の raw material の品質に上限が生じるため、in-flight でしか書けない情報を能動的に残す。

**Context**: Anthropic エンジニアが SNS で公開した実装プロンプト（"implement \<SPEC\> and while you do keep a running implementation-notes.html file (or markdown) with decisions you had to make weren't in the spec, things you had to change, tradeoffs you had to make or anything else I should know"）を契機に、本リポの ACE Playbook (ACE-001 〜 033) と grep 照合し未抽出と確認。本リポの既存 ACE サイクル ([ace-cycle.md](../05-operations/deployment/ace-cycle.md)) は post-merge に `gh pr diff` + レビューコメントを raw material として Generate するが、コミットに残らない判断理由・捨てた選択肢・spec 乖離の文脈は diff には現れない。実際 ACE-032（PR #416 で MCP value 撤去後に §5.4.2 が宙に浮いた）のような「気付いた瞬間に書いておけば反映漏れがなかった」ケースが頻発しており、in-flight な判断ログの欠落が構造的に存在する。

**Action**:

1. **実装着手と同時に作業ブランチ直下に `implementation-notes.md` を作成**: 最低限 4 つの見出しを持つ
   - `## Decisions not in spec`（spec にない判断）
   - `## Changes from spec`（spec から変えた点）
   - `## Tradeoffs`（採った/捨てた選択肢と理由）
   - `## Open questions / TODO`（未決事項）
2. **コミットと一緒に追記**: 「なぜこの選択をしたか」を 1〜3 行で残す。後で書こうとすると確実に忘れる
3. **PR 作成時に PR description に転記または同梱**: レビュアーが「なぜ」を読みやすくなり、レビュー指摘の精度が上がる
4. **ACE Phase 1 Generate の raw material は「PR description（implementation-notes 転記済み）」**: Action 5 でマージ前にファイル自体は削除されるため、ファイル本体ではなく PR description（転記済みの判断ログ）を `gh pr view --json body` で取得して Generate プロンプトに渡す。`gh pr diff` / `gh issue view` / レビューコメントと併せて入力にする（[ace-cycle.md §Phase 1](../05-operations/deployment/ace-cycle.md)）
5. **マージ前にファイルを削除し PR description に統合（推奨）**: squash merge を標準とするリポでは「PR に同梱したまま残す」と squash 後にルート直下に前 PR のファイルが残り、次の feature branch が衝突・上書きする構造問題が起きる（ACE-021 と同型）。pr-ready 直前に (a) 中身を PR description に転記、(b) `git rm implementation-notes.md` で削除、(c) `git commit -m "chore: integrate implementation-notes into PR description"` の 3 ステップで処理する。長期保存したい場合は `notes/<issue-num>.md` 形式で per-PR ファイル化する代替案もあるが（並行 PR で衝突しない）、リポに notes/ が累積するトレードオフがある
6. **スコープ外発見は引き続き Issue 化（[workflow-principles.md 原則2](../05-operations/deployment/workflow-principles.md)）**: implementation-notes は「現 PR の判断ログ」、Issue は「別タスクへの分岐」と役割を分ける（排他ではなく補完）

---

<a id="ace-035"></a>

### ACE-035: 新規 process パターンを Playbook に追加するときは「ドッグフード + advisor / second opinion」で運用上の構造問題を検出する

| フィールド | 値                |
| ---------- | ----------------- |
| Category   | process           |
| Origin     | PR #420           |
| Related    | ACE-021 / ACE-034 |
| Date       | 2026-05-19        |
| Helpful    | 2                 |
| Harmful    | 0                 |
| Status     | active            |

**Insight**: 新しい process パターン（特に「マージ後の振る舞い」を伴うもの）を Playbook に追加する PR では、(1) その PR 自身で当該パターンを実行（ドッグフード）し、(2) advisor / second opinion に「この推奨を本リポで運用したら何が起きるか」を確認させる。初稿の机上判断だけだと、自リポの merge strategy（squash か否か）と矛盾する構造問題を見逃す。

**Context**: PR #420 で ACE-034 Action 5「マージ時の扱い」初稿に「(a) PR に同梱したまま残す」を推奨に設定。advisor がこれを「squash merge 標準のリポでは ACE-021 と同型の構造問題（次 feature branch がルート直下で衝突）を起こす」と指摘し、「(b) マージ前削除 + PR description 統合」に pivot。advisor を呼ばずにマージしていたら、自分の PR でドッグフードした implementation-notes.md が develop ルートに残り、次 PR が確実に衝突した。机上では見落とす運用問題が「ドッグフード + advisor」の組み合わせで検出された具体例。

**Action**:

1. **Playbook 新規エントリの Action / 推奨パターンには「自リポでの運用シミュレーション」段落を必ず通す**: 特に squash merge / rebase merge / merge commit の選択がエントリの推奨と矛盾しないか確認
2. **PR 自身でドッグフード可能なパターンは必ずドッグフードする**: implementation-notes.md / 命名規則 / コミットメッセージ規則など、PR 内で実行できるものは PR 内で 1 回回す
3. **advisor / second opinion を「初稿完成 → quality:local 通過 → commit 前」のタイミングで必ず呼ぶ**: post-commit に呼ぶと修正コストが上がる
4. **構造問題が見つかったら pivot 経緯を implementation-notes.md に記録**: pivot 自体が ACE Phase 1 の raw material になる（ACE-034 と組み合わせる）

---

<a id="ace-038"></a>

### ACE-038: 「データ収集待ち」を要求する受入基準でも、ロールバック容易な変更は先行実装 + 試行中ステータス明記でフィードバックループを早める

| フィールド | 値                |
| ---------- | ----------------- |
| Category   | process           |
| Origin     | PR #423           |
| Related    | ACE-034 / ACE-035 |
| Date       | 2026-05-20        |
| Helpful    | 0                 |
| Harmful    | 0                 |
| Status     | active            |

**Insight**: 受入基準が「N サンプル運用後に判断」を要求する Issue では、(a) 変更が 1〜3 行で revert 容易 / (b) 待たずに動かす方が学習機会が増える、を満たす場合に「先行実装 + 試行中ステータス明示 + ロールバック条件明記」のパターンで前進できる。データを溜める時間も「観点なしで運用したら何が拾えないか」を観察できる時間として活用すべきで、観点ありで運用しながら評価する方が情報密度が高い。

**Context**: Issue #421 の受入基準は「ACE-034 を 5 PR 以上で運用してから判断」だったが、観点追加は 1 行 diff で revert コスト極小、かつ「観点なしで運用すると implementation-notes 由来の raw material が構造的に拾われない」リスクの方が大きいと判断。PR #423 で先に観点 7 を追加 + L57 / Changelog に「試行中: 5 PR で評価」を明記して、ロールバック条件を本文に残した状態でマージ。「待つ間に何が拾えなかったか」のデータも、観点 7 ありで運用しないと取れない構造になっていた。

**Action**:

1. **「データ収集待ち」受入基準を見たら 3 軸で判定する**: (a) 変更の revert コスト（行数・依存）、(b) 「待つ間に何ができないか」のコスト、(c) 試行中ステータスを文書化できるか
2. **revert コスト極小（1〜3 行）+ 試行中明示できる場合は先行実装**: ただし「試行中」「N PR で評価」「ロールバック条件」を**テンプレ本文に書く**（PR description だけだとマージ後にアクセスしづらい）
3. **試行中ステータスは目立つ場所に書く**: 観点 / ルールの末尾括弧（例: `（試行中: [Issue #XXX](...)、5 PR で評価）`）、または独立した「## 試行中」セクション
4. **評価期間後のロールバック判定 Issue を着手時に起票**: 「5 PR 後に評価」follow-up Issue を最初に作っておくと、評価忘れによる定着リスクが下がる（PR #423 では follow-up #424 #425 を同時起票）

---

<a id="ace-040"></a>

### ACE-040: AI プロンプトテンプレ内で同概念を複数の語で表現すると AI 出力品質が下がる — 一次定義（SSOT）の語彙に統一する

| フィールド | 値                |
| ---------- | ----------------- |
| Category   | process           |
| Origin     | PR #423           |
| Related    | ACE-014 / ACE-024 |
| Date       | 2026-05-20        |
| Helpful    | 1                 |
| Harmful    | 0                 |
| Status     | active            |

**Insight**: AI プロンプトテンプレや知見エントリで同概念を 2〜3 の異なる語（例: 「spec 乖離」「spec から逸脱」「spec から変更した点」）で表現すると、AI が「これらは別概念か？」と誤解する余地が生まれ、冗長な分類や category mismatch を引き起こす。**一次定義（最初に登場する場所）を SSOT として扱い、他は同じ語彙を使う**。ACE-024（SSOT 用語の既存定義との衝突確認）の dual: 一度確立した用語が**自リポ内で**徐々に変質するパターン。

**Context**: PR #423 のレビューで comment-analyzer S3 が指摘。元々 PLAYBOOK ACE-034 エントリは「spec から変更した点」「spec にない判断」を正準形として使っていたが、観点 7 ドラフトでは「逸脱」、L35 対象データ表セルでは「乖離」と表記揺れが発生していた。3 箇所で異なる語を使うと AI prompt として渡された時に AI が冗長分類するリスクあり。fix commit で全箇所を ACE-034 の正準語「spec にない判断 / spec から変更した点 / 捨てた選択肢」に統一。

**Action**:

1. **AI プロンプトテンプレ / 知見エントリで複数箇所が同概念に言及する場合、一次定義（SSOT）を grep で特定し、他箇所は同じ語彙を使う**: `grep -rn "<概念名>" docs-template/` で散らばりを確認
2. **新エントリ・新観点を起草するときは既存 SSOT 用語を最初に確認**: 既存 PLAYBOOK エントリの Insight 文 / Action ステップで使われている語彙をピックアップして草稿の語彙を合わせる
3. **レビュー段階で表記揺れが検出されたら、変更箇所だけでなくファイル全体を grep で確認して同 commit で統一する**: 部分修正だとレビュー後に新たな揺れが入る

---

<a id="ace-041"></a>

### ACE-041: マージ後 cleanup の未追跡ファイルガードに引っかかったら、独立した chore PR で .gitignore 追加して cleanup を継続する

| フィールド | 値                |
| ---------- | ----------------- |
| Category   | process           |
| Origin     | PR #423           |
| Related    | ACE-009 / ACE-012 |
| Date       | 2026-05-20        |
| Helpful    | 0                 |
| Harmful    | 0                 |
| Status     | active            |

**Insight**: マージ後 cleanup の `git status --porcelain` ガードでツール設定ファイル（`.codex/`、`.vscode/local.json` 等）に止まった場合、その場で削除や restore せず、独立した chore PR で `.gitignore` 追加するパターンが安全。CLAUDE.md「勝手に git restore / git clean しない」原則を守りつつ cleanup を継続できる。短命の chore PR は Draft + 並列セルフレビューをスキップ可能な「真に trivial な変更」の典型例。

**Context**: PR #423 マージ後の `/merge-cleanup 423` で `.codex/config.toml`（Codex CLI ローカル MCP 設定、`.claude/settings.local.json` と同型）が未追跡で検出され Step 1 ガードに引っかかった。中身を確認しユーザーに 3 択提示 → `.gitignore` 追加を選択 → chore branch `chore/#426-gitignore-codex` 作成 → 3 行追加 commit → 非 Draft PR #427 で直接 ready + merge → PR #423 + #427 の 2 本まとめて cleanup 完遂。

**Action**:

1. **cleanup ガードで未追跡ファイルに止まったら、中身を確認して 3 分類する**: (a) 作業中の commit し損ね → 元ブランチに戻して commit、(b) ツール / 個人設定 → chore PR + .gitignore、(c) ビルド成果物 → .gitignore
2. **ツール設定の chore PR は短命で済ませる**: 1 ファイル 1〜3 行の .gitignore 追加なら Toolkit/Copilot 並列レビューはスキップ可能（PR description に "trivial な .gitignore" と理由を明記）
3. **cleanup 中の chore PR は元 PR と同じ run で merge + cleanup する**: PR 番号を 2 つ持つ cleanup（`gh pr view A` + `gh pr view B` を順番に処理）で 1 cycle 完結
4. **`.gitignore` への追加は既存セクションの末尾**: `# <Tool name>` 見出し + パターン 1 行で、既存パターン（`.claude/settings.local.json` 等）と同じスタイルに合わせる

---

<a id="ace-044"></a>

### ACE-044: review 指摘を取り込むスコープは「編集セクション境界」で判定する — 触ったセクション内の隣接 stale は同 PR、別ファイル / 別セクションは別 issue

| フィールド | 値                          |
| ---------- | --------------------------- |
| Category   | process                     |
| Origin     | PR #429 / Issue #417        |
| Related    | ACE-032 / ACE-037 / ACE-043 |
| Date       | 2026-05-20                  |
| Helpful    | 4                           |
| Harmful    | 0                           |
| Status     | active                      |

**Insight**: Toolkit / Copilot review は編集差分から離れた行も検査するため、本 PR で触っていない pre-existing stale を発見することがある。これを「同 PR で潰す」か「別 issue にする」かは「touch ファイル外 vs ファイル内」だけでは粒度が粗く、**「同セクション (= heading 配下) vs 別セクション」の境界** を判定軸に加えると読み手にとって自然な PR diff になる。同セクション内の隣接 stale を放置すると、`build:spec-index` を追加した PR が「半端な最新化（隣の行は古いまま）」と読まれ、レビュー時の文脈分断を招く。

**Context**: PR #429 で `docs/NO_GITHUB_ACTIONS_MIGRATION_DESIGN.md §3.2-3.3` を編集（`build:spec-index` 追加）。Toolkit comment-analyzer が以下を検出:

- **W1**: 同 §3.2 内 line 89 注記「`package.json` に `format:md` は存在しません」が事実誤認（実態は `format:md` / `format:md:check` の両方が存在）。本 PR では line 89 を触っていなかったが、隣接行（line 86 表の `build:spec-index` 追加）を編集したため「半端な最新化」と読まれる risk。**同 PR で整合**。
- **W2**: 同 §3.3 内 line 94「中身の順序」で `format:md:check` 欠落（pre-existing）。本 PR で同行に `build:spec-index` を**挿入したことで** 「この行を最新版に整えた」と読まれる risk が高まった。**同 PR で 1 トークン追加して整合**。
- **S2/S3**: `README.md:74` / `.github/pull_request_template.md:28` の stale 記述（`quality:local` の chain 列挙）。本 PR では触っていないファイル。**別 issue 化 (#430)**。

3 段階の判定基準が機能した: (1) touch ファイル外 = 別 issue、(2) touch ファイル内かつ別セクション = 状況次第（W1/W2 は同セクションだったので同 PR）、(3) touch セクション内 = 機械的に同 PR で整合。

**Action**:

1. **review 指摘を分類するとき 3 段階で判定**: (a) touch ファイル外 → 別 issue を即起票（CLAUDE.md「『別 Issue』と言ったら即 `gh issue create`」ルール）、(b) touch ファイル内 / 別セクション → 影響範囲と PR スコープを天秤にかける、(c) touch セクション内 → 1 fix commit に束ねて同 PR で機械的に整合
2. **「半端な最新化」を意識的に回避する**: PR で同行や隣接行に変更を加えたら、その行が含まれる説明全体が一致しているかを再走査。`grep -n <ファイル>` で section の境界を確認してから fix commit を切る
3. **別 issue 化したものは fix commit のコメントで明示**: PR コメントで「W1/W2 は本 PR で対応、S2/S3 は #430 で別対応」のように issue 番号を引いてレビュアーの脳内マップを補助する
4. **pre-existing と本 PR 起因を区別する**: コミットメッセージで「W1 (comment-analyzer): pre-existing で本 PR で隣接行を編集したため整合対応」のように **来歴を残す**。これにより後続の review が「なぜこの 1 行も直したのか」を辿れる
5. **本 PR スコープ判定で迷ったら軽量側 (= 範囲内) に倒す**: CLAUDE.md ルール「過剰な issue 分割は PR の流れを止める」と整合。ただし「触っていないファイル」だけは別 issue を例外なく適用する

---

<a id="ace-441-2"></a>

### ACE-441-2: pre-commit hook は正式品質ゲート（quality:local）の軽量サブセット — pr-ready 前に必ず full ゲートを回す

| フィールド | 値                   |
| ---------- | -------------------- |
| Category   | process              |
| Origin     | PR #441 / Issue #440 |
| Related    | ACE-043              |
| Date       | 2026-05-30           |
| Helpful    | 0                    |
| Harmful    | 0                    |
| Status     | active               |

**Insight**: pre-commit hook が通っても、正式品質ゲート（`npm run quality:local`）が落ちうる。hook は速度優先で軽量サブセット（このリポジトリでは markdownlint のみ）しか実行しないため、prettier `--check`・MCP build/check・各テスト・docs 検証・spec-index などの追加チェックは hook を素通りする。**commit が通った＝ゲート通過、と錯覚しない。**

**Context**: PR #441 で、commit 時の pre-commit hook（markdownlint のみ）は全 commit で 0 error だったが、`quality:local` を回すと `format:md:check`（prettier `--check`）が 3 ファイルで未整形を検出して落ちた。markdownlint は通すが prettier 整形は別ルールのため、hook だけを信じて pr-ready にすると CI 相当の `quality:local` で初めて落ちる。

**Action**:

1. **pr-ready の前に必ず `npm run quality:local` を通しで回す**（10 ステップ workflow の Step4）。hook 通過をゲート通過と同一視しない。
2. doc/設定変更を含む PR では特に prettier 整形漏れに注意。`npx prettier --write <変更ファイル>` を pre-ready で一度かける。
3. hook と full ゲートの差分（何が hook に無く full にあるか）を把握しておく。

---

<a id="ace-445-1"></a>

### ACE-445-1: Claude 系レビュアーが「既存と整合的だから OK」と全員一致した箇所こそ cross-model レビューの出番 — 同系列の合意は正しさの証明ではない

| フィールド | 値                   |
| ---------- | -------------------- |
| Category   | process              |
| Origin     | PR #445 / Issue #444 |
| Related    | ACE-001              |
| Date       | 2026-06-19           |
| Helpful    | 5                    |
| Harmful    | 0                    |
| Status     | active               |

**Insight**: 同系列（Claude）の複数レビュアーが borderline な silent-failure を「既存コードとの整合性」を理由に全員一致で承認しても、それは安全の証拠にならない。むしろ「既存と整合的だから OK」という同系列の合意は、cross-model（別系列）レビューが最も価値を出すシグナルである。整合性（consistency）は正しさ（correctness）の証明ではない。

**Context**: PR #445 で env 変数の閾値を `Number.parseInt` で解釈する `parseMaxPlaybookLines` を、既存 `parseMaxPerCategory` を mirror して実装した。subagent-driven の Task レビュー（sonnet）2 回 + 最終 whole-branch レビュー（opus、本セッション最高能力モデル）すべてが APPROVED。opus は `Number.isFinite` の冗長さを「sibling parser との意図的 mirror で、乖離させる方が悪い」と明示的に**修正に反対**した。しかし Codex（gpt-5.4）の silent-failure-hunter と code-reviewer が独立に「`"800abc"`→800、`"1e3"`→1 を無警告で受理する入力検証ギャップ」を Important として検出。共有ヘルパー `parsePositiveIntEnv`（`/^[0-9]+$/` で厳密化）に抽出して両パーサを同時に堅牢化し、乖離ではなく収束で解消した（[ACE-001](#ace-001) を一段具体化した事例）。

**Action**:

1. Claude 系セルフレビュー（`pr-review-toolkit` / subagent-driven の task・final レビュー）が全員 APPROVED でも、**cross-model レビュー（Codex `scripts/codex-review.sh --base develop`）を省略しない**。特に「既存と整合的だから」という理由で borderline を承認した箇所は cross-model に回す価値が高い。
2. 既存 helper を mirror するときは、**mirror 元の欠陥（loose な `parseInt` 等）を継承していないか**疑う。修正は片方だけ直して乖離させるより、共有ヘルパーに抽出して両方同時に堅牢化する。
3. 入力検証は「mirror 元と同じ」ではなく、字面で正しさを担保する（例: `/^[0-9]+$/` で厳密な正の整数のみ受理）。

---

<a id="ace-447-3"></a>

### ACE-447-3: 大規模 doc PR の cross-model レビューは clean verdict に収束しない — ゲートは「Critical 不在＋実 Important 全対応」、green を待ってループしない

| フィールド | 値                   |
| ---------- | -------------------- |
| Category   | process              |
| Origin     | PR #447 / Issue #446 |
| Related    | ACE-445-1, ACE-001   |
| Date       | 2026-06-23           |
| Helpful    | 2                    |
| Harmful    | 0                    |
| Status     | active               |

**Insight**: 多数ファイルのドキュメント PR では、LLM cross-model レビュー（Codex 等）は毎ラウンド新しい言い回し・整合性 nit を出し、REJECTED 判定が green に収束しにくい。マージ可否のゲートは「verdict が PASS になること」ではなく「**Critical がゼロ＋検出された実 Important を全対応したこと**」に置く。clean verdict を待って無限ループしない。ただし cross-model 自体は省略しない（[ACE-445-1](#ace-445-1)）。

**Context**: PR #447（Issue テンプレ刷新、15+ ファイルの Markdown）で Codex を3ラウンド実行し、いずれも REJECTED（Critical=0、毎回 doc 整合の Important を2〜4件検出）。各ラウンドで実指摘を fix commit に束ねて対応し、silent-failure/type/test は2ラウンド目以降安定 PASS、code-reviewer/comment-analyzer は新しい nit を出し続けた。ユーザーの「Critical 指摘がなければマージを止めない」ポリシーに従い、実 Important 全対応・Critical 不在を確認して merge した。

**Action**:

1. cross-model レビューは必ず回す（[ACE-445-1](#ace-445-1)）が、ループ終了条件は「Critical=0 かつ実 Important 全対応」。green verdict は終了条件にしない。
2. 各ラウンドの指摘は「実バグ/不整合」と「誤検知/好みの言い回し」を切り分け、前者のみ fix。誤検知は根拠付きで却下し記録する（例: `#インフラ` は実在見出しに解決＝誤検知）。
3. 収束しない兆候（毎回 Critical=0 で新規 nit のみ）が出たら、ループを打ち切りマージ判断をユーザーに提示する。

---

<a id="ace-449-2"></a>

### ACE-449-2: 「既定から外す」変更はデータの空化ではなく明示的なゲート条件で実装し、ドキュメントに書いたオプトイン手順はその場で回帰テストに固定する

| フィールド | 値                   |
| ---------- | -------------------- |
| Category   | process              |
| Origin     | PR #449 / Issue #448 |
| Related    | ACE-445-1            |
| Date       | 2026-07-02           |
| Helpful    | 1                    |
| Harmful    | 0                    |
| Status     | active               |

**Insight**: 「X を既定から外すがオプトインは残す」という要件を「X の割り当てデータを空にする」で実装すると、除外（既定で動かない）は達成できてもオプトイン経路（明示指定で動く）が一緒に死ぬ。しかも実行系は空プランを exit 0 で完走するため、ドキュメントの案内どおりに実行したユーザーは「動いた」と誤解する三重のサイレント失敗になる。除外は「明示指定がない場合のみスキップ」というゲート条件で表現し、ドキュメントに書いた具体的なコマンド例（オプトイン経路）は同 PR で回帰テストに固定する。

**Context**: PR #449 で Copilot をレビュー既定から外す際、初版は `get_cli_perspectives_review` の copilot 行を空文字にした。Claude 系 code-reviewer は「問題なし」で通過したが、Codex（cross-model）と silent-failure-hunter が独立に「`--cli copilot-cli` 明示でもプランに載らず exit 0」を検出（[ACE-445-1](#ace-445-1) の再演）。perspectives を復元し「review タスクかつ `CLI_FILTER` 空のときのみ skip」のゲートに実装し直し、空実行プランは非 dry-run で exit 1 に変更、`--cli copilot-cli` オプトインを含む 9 テストを `scripts/multi-agent.test.ts` に固定した。

**Action**:

1. 「既定から外す」は割り当てデータの削除ではなく、**プラン構築時のゲート条件**（明示オプトインで素通し）で実装する。
2. ドキュメント・コメントに具体的なオプトインコマンドを書いたら、**その コマンドが動くことを同 PR のテストで検証**する（案内と実装の drift を構造的に防ぐ）。
3. 実行対象が 0 件のプランは警告ではなく **非ゼロ exit** にする — 「何も実行せず成功」はゲート系ツールで最悪のサイレント失敗。

---

<a id="ace-459-2"></a>

### ACE-459-2: linked worktree での並行開発は「メインと同じ」前提が3箇所で破れる — husky 不発・gitignore の symlink すり抜け・共有 config 汚染

| フィールド | 値                   |
| ---------- | -------------------- |
| Category   | process              |
| Origin     | PR #459 / Issue #453 |
| Related    | ACE-459-1            |
| Date       | 2026-07-02           |
| Helpful    | 0                    |
| Harmful    | 0                    |
| Status     | active               |

**Insight**: `git worktree add` で作った作業ツリーはメインと同じに見えて、(a) husky v9 の hooks 実体 `.husky/_` は untracked のため worktree に存在せず **pre-commit / pre-push が無言で発火しない**、(b) `.gitignore` の `node_modules/`（末尾スラッシュ）はディレクトリ限定で **symlink の node_modules を無視せず誤コミットできる**、(c) `.git/config` はメインと共有のため worktree 内での事故（ACE-459-1）が**メイン側にも波及**する。

**Context**: PR #459 を worktree で並行開発した際、(a) により初回 push が品質ゲートなしで通り、`npm run prepare` 実行後に初めて hook が発火。(b) により依存共有用の symlink node_modules がコミットに混入（mode 120000）し amend で除去。(c) は ACE-459-1 の破壊がメインの config に及んだ形で確認。

**Action**:

1. worktree を作ったら最初に `npm run prepare`（husky 再セットアップ）を実行し、hooks が発火することを確認してから作業する。
2. `.gitignore` のディレクトリ除外は末尾スラッシュなし（`node_modules`）にして symlink も無視させる。
3. worktree での `git add -A` 後は `git status --short` で mode 120000（symlink）の混入がないか確認してからコミットする。

---

<a id="ace-464-2"></a>

### ACE-464-2: cross-model レビューが実質的な新指摘を出し続けるなら各指摘を patch せず「設計を疑え」— 停止は「新規 Critical/Important 不在」

| フィールド | 値         |
| ---------- | ---------- |
| Category   | process    |
| Origin     | PR #464    |
| Date       | 2026-07-03 |
| Helpful    | 1          |
| Harmful    | 0          |
| Status     | active     |

**Insight**: cross-model レビューが round を重ねても新しい substantive 指摘（破壊性・silent failure・traversal…）を出し続けるのは、細部の欠陥ではなく approach 自体が間違っているサイン。個別 patch を積み続けるより approach をピボット（削除ベース→プラン駆動）した方が、関連指摘群がまとめて構造的に消える。ループの停止は all-green ではなく「新規の実質 Critical/Important が出ないこと」で判断する（[ACE-447-3](#ace-447-3) の code PR 版）。

**Context**: PR #464 は Codex を 9 round 回した。削除ベース設計への指摘（消しすぎ／残しすぎ）が round をまたいで収束せず、プラン駆動へ設計転換した途端に破壊性/残留/silent 系の指摘が構造的に解消。以降は traversal・重複・境界など細粒度の指摘に収束した。

**Action**: 同一テーマの指摘が 2〜3 round 続いたら「この設計を patch し続けるべきか」を自問し、必要なら実装途中でも approach をピボットする。停止ゲートは「Critical 不在＋実 Important 全対応＋回帰テスト（可能なら mutation で検知力を確認）」。primary（Toolkit）が pass 済みなら green を待って無限ループしない。

---

<a id="ace-465-2"></a>

### ACE-465-2: cross-model が指摘した「互換性破壊」も、修正案が Issue の明示的決定と矛盾するなら盲従せず実害（呼び出し元の実在）を検証して判断する

| フィールド | 値         |
| ---------- | ---------- |
| Category   | process    |
| Origin     | PR #465    |
| Related    | ACE-445-1  |
| Date       | 2026-07-03 |
| Helpful    | 0          |
| Harmful    | 0          |
| Status     | active     |

**Insight**: cross-model レビューは省略しない（[ACE-445-1](#ace-445-1)）が、その指摘を盲従もしない。cross-model が「互換性破壊」等を指摘し提示した修正案が、Issue で明示的に選ばれた方針と正面から矛盾する場合、修正案を鵜呑みにすると決定を覆すことになる。指摘の**妥当な核**（例: breaking change の存在）と**提示された修正案**（例: 互換レイヤーの追加）を分け、核が**実害を持つか**を検証してから対応を決める。実害ゼロ（依存する呼び出し元が実在しない）なら、決定を覆さず「**意図的な breaking change**」として明記するのが正しい対応。

**Context**: PR #465 で Codex code-reviewer が「silent に受理されていた `--delegate-toolkit` を exit 1 化するのは互換性破壊。互換レイヤーを挟むか breaking change として扱え」と指摘（Toolkit 系 4 観点は指摘せず Codex のみ = [ACE-445-1](#ace-445-1) の再演）。互換レイヤー案は Issue #451 が明示的に選んだ案2「未知フラグはエラー」と矛盾し、無効果フラグを警告付きで温存する元のアンチパターンへの逆戻りだった。リポジトリ内で `--delegate-toolkit` を呼ぶ自動化（husky / CI / `.claude/hooks`）が実在しないことを `grep` で検証し、互換レイヤーは採用せず PR 本文に意図的 breaking change として明記した。

**Action**: cross-model の指摘は「妥当な核」と「提示された修正案」を分けて扱う。修正案が Issue / 設計で明示的に決めた方針と矛盾するなら、`receiving-code-review` に沿って実害を検証してから push back する。破壊的変更系の指摘は「その破壊に実際に依存する呼び出し元が存在するか」を `grep` / 検索で確認し、実害ゼロなら方針は維持しつつ意図的 breaking change として PR 本文・commit に明記する。関連: [ACE-445-1](#ace-445-1)（同系列合意より cross-model）/ [ACE-447-3](#ace-447-3)（clean verdict を待たない）。

---

<a id="ace-2-3"></a>

### ACE-2-3: 同一ブランチで並行する Claude セッション（特にクラッシュ由来の孤児プロセス）を検知したら、闇雲な kill でなくアプリ完全再起動で一掃する

| フィールド | 値         |
| ---------- | ---------- |
| Category   | process    |
| Origin     | PR #2      |
| Date       | 2026-07-03 |
| Helpful    | 0          |
| Harmful    | 0          |
| Status     | active     |

**Insight**: 複数の Claude セッション（特にウィンドウのクラッシュで残った autonomous な `claude -p` 孤児プロセス）が同じブランチで動くと、単一ファイルを奪い合い、片方の Write が "modified since read" で弾かれたり、両者のコミットが交互に積まれて履歴が予測不能になる。検知の手掛かりは「自分が作っていないコミット/ファイルの出現」「スクラッチ領域に他者が書いた形跡（新しい mtime）」「`ps` に複数の `claude -p`」「reflog」。復旧はプロセスを個別 kill するより**Claude アプリの完全終了→再起動**が確実（どれが自セッションか区別できず、闇雲な kill は自分を巻き込む）。全てコミット済みなら再起動で失うものはない。

**Context**: PR #2 実装中、クラッシュしたウィンドウの孤児セッションが同一ブランチにコミット（Task 6/7 相当）を積み続け、こちらの Write が拒否される事態になった。プロセス特定が困難だったため闇雲な kill を避け、ユーザーにアプリ再起動を依頼。再起動後に孤児は消え、履歴が線形かつクリーンなこと（`git log --oneline develop..HEAD`）を検証してから続行し、両セッションの作業が1本の履歴に統合されていた。

**Action**: 想定外のコミット/ファイル変更を検知したら (1) 即座に編集・コミットを止める、(2) `git reflog` / `ps` / ファイル mtime で並行実行を確認、(3) プロセスの闇雲な kill はせず（自セッション巻き込み・git 操作中断のリスク）アプリ完全再起動で子セッションを一掃、(4) 再起動後に `git log --oneline develop..HEAD` が線形・クリーンかを検証してから再開する。原則として同一ブランチでの多重セッションは避ける。

---

<a id="ace-7-1"></a>

### ACE-7-1: pre-push 品質ゲート起因の修正は、単体 check だけでなく SKIP なしの実 push で完了判定する

| フィールド | 値               |
| ---------- | ---------------- |
| Category   | process          |
| Origin     | PR #7 / Issue #3 |
| Date       | 2026-07-03       |
| Helpful    | 0                |
| Harmful    | 0                |
| Status     | active           |

**Insight**: pre-push hook が全 `*.md` や広い品質ゲートを走らせるリポジトリでは、個別ファイルの `prettier --check` が通っても「push できる」はまだ証明されていない。特に過去に `SKIP_QUALITY_GATE=1` で回避した問題は、修正後に必ず通常の `git push` 経路を通して、hook と同じ end-to-end 境界で再発しないことを確認する。

**Context**: Issue #3 では develop 由来の `INTERNAL.md` 整形崩れが `.husky/pre-push` の `quality:local`（全 Markdown を含む）で検出され、無関係な feature branch の push まで失敗していた。PR #7 では `INTERNAL.md` を Prettier 整形し、`npx prettier --check INTERNAL.md` と `npm run quality:local` に加えて、`SKIP_QUALITY_GATE` なしの `git push -u origin HEAD` で pre-push hook が通ることを確認してから merge した。

**Action**: pre-push / pre-commit / release hook が原因の修正では、(1) 問題ファイル単体の再現コマンド、(2) hook が呼ぶ正式ゲート、(3) 実際の git 操作（SKIP なし）の3段階を検証する。PR 本文には「SKIP なし push が通った」ことを明記し、過去の回避フラグが残ったまま完了扱いにしない。

---

<a id="ace-12-1"></a>

### ACE-12-1: セルフレビュー指摘の修正は commit してから ready/merge する — Edit ツールはファイルを書き換えるだけで commit しない

| フィールド | 値           |
| ---------- | ------------ |
| Category   | process      |
| Origin     | PR #12 / #14 |
| Date       | 2026-07-06   |
| Helpful    | 0            |
| Harmful    | 0            |
| Status     | active       |

**Insight**: Toolkit / Codex CLI のセルフレビューで指摘を受け、`Edit` ツールでファイルを修正しても、その変更は作業ツリーに存在するだけで **commit されていない**。この状態のまま `gh pr ready` → `gh pr merge --squash` を実行すると、squash merge は「最後に commit された内容」だけを取り込み、未commitの修正は develop に反映されないまま静かに失われる（作業ツリー上には残るため、`git status` を見ない限り気づけない）。ACE-012 が扱う「外部要因でブランチが切り替わる」事故とは異なり、こちらは **自分の操作順序ミス**（修正→commit忘れ→merge）が原因。

**Context**: PR #12（Issue #10）のセルフレビューで Toolkit（code-reviewer/silent-failure-hunter/comment-analyzer）と Codex CLI（5観点）から5件の指摘を受け、`Edit` で全て修正した。しかし `git add && git commit` を挟まずに直接 `gh pr ready` → `gh pr merge --squash` を実行してしまい、squash merge には修正前のコミットのみが取り込まれた。マージ後の `merge-cleanup` 実行中に環境が不安定化し（別プロセス干渉の疑い、ACE-2-3 類似）、その混乱の中で「develop push 済み」「ACE 記録済み」という誤った状態を報告してしまう二次被害も発生。最終的に `origin/develop` を直接 `git show` で確認して未反映を検出し、修正内容を新Issue #13 + 新PR #14 で正しく反映し直した。

**Action**: レビュー指摘対応で `Edit`/`Write` を使ったら、**`gh pr ready` や `gh pr merge` を呼ぶ直前に必ず `git status --porcelain` を実行し、出力が空であることを確認する**。空でなければ先に `git add && git commit && git push` を済ませる。マージ操作は「レビュー指摘に対応した」ことの確認ではなく「その対応が commit 済みである」ことの確認とセットで行う。あわせて、環境が不安定（コマンド出力の乱れ・想定外のブランチ切替・ファイルの自然発生的な差分）を感知したら、その場の bash 出力を鵜呑みにせず `git ls-remote` や `gh pr view --json mergeCommit` など GitHub 側の一次情報で状態を裏取りしてから次の操作に進む。

---

<a id="ace-16-3"></a>

### ACE-16-3: 大規模 diff の PR 自己レビューでレビュー agent が stall / API 切断した場合、resume を繰り返すより新規 agent へのスコープ限定リランが速い

| フィールド | 値                 |
| ---------- | ------------------ |
| Category   | process            |
| Origin     | PR #16 / Issue #15 |
| Date       | 2026-07-06         |
| Helpful    | 0                  |
| Harmful    | 0                  |
| Status     | active             |

**Insight**: pr-review-toolkit のサブエージェントに大きめの diff（20 ファイル、生成ファイル 10 個含む）をフルスコープで投げると、API 接続エラーや 600 秒の stream watchdog タイムアウトで完了しないことがある。SendMessage での再開（resume）は同じ失敗を再度引き起こしやすい。新規 agent を「最もリスクの高い数ファイルに絞り、機械生成済みで検証済みのファイル群は詳細に読み直さなくてよい」と明示してリランすると、短時間で完了する。

**Context**: PR #16 の自己レビューで Toolkit の code-reviewer/silent-failure-hunter を起動したところ、両方とも "Connection closed mid-response" で中断。SendMessage で resume したところ今度は "stream watchdog did not recover"（600 秒無進捗）で 2 件とも failed。同じ観点を新規 agent として起動する際、「TS スクリプト 2 ファイル＋ ace-curate.md の 3 ファイルに絞り、生成された 10 個の playbook/\*.md は 1〜2 個の spot check で十分」と明示したところ、両 agent とも数分で完了し具体的な指摘を返した。

**Action**: レビュー agent が stall または API 由来のエラーで中断したら、まず 1 回は resume を試すが、resume も失敗したら同じ agent への再 resume を繰り返さず、新規 agent を「レビュー対象ファイルを絞る」「機械的に検証済み・生成されたファイルは深く読まなくてよいと明示する」形でリランする。diff が大きい PR（20 ファイル超、生成ファイル多数）の自己レビューでは、最初から高リスクファイルを列挙して agent のスコープを絞ることで、stall の再発を防ぎやすい。

---

<a id="ace-27-4"></a>

### ACE-27-4: cross-model セルフレビューの指摘は一次証拠で検証してから対応する — 誤検知は根拠を添えて据え置く

| フィールド | 値                 |
| ---------- | ------------------ |
| Category   | process            |
| Origin     | PR #27 / Issue #21 |
| Date       | 2026-07-10         |
| Helpful    | 1                  |
| Harmful    | 0                  |
| Status     | active             |

**Insight**: Codex 等の cross-model レビューは有用だが、対象リポジトリの実行環境（テストランナーの変換・慣例）を知らず一般論で「Critical」を出すことがある。全指摘を機械的に修正すると、正しいコードを壊したり意図的な設計（warn-only の exit 0 等）を捻じ曲げたりする。対応は「受け身の同意」でも「無視」でもなく、一次証拠（テストの実通過・既存コードの慣例・実挙動）で真偽を判定し、誤検知は理由を添えて据え置く。実欠陥と設計方針の相違を切り分けることが肝。

**Context**: PR #27 の Codex 再レビューが「ESM の .test.ts で `__dirname` を使うと ReferenceError（Critical）」と指摘したが、vitest はテストへ `__dirname` を注入し、既存 `sync-to-public.test.ts` も同パターンで、実際に全テストが通過していた（一次証拠が指摘と矛盾）。同様に「warn モードで内部エラー時 exit 0」は warn-only 契約に沿う意図的挙動だった。これらは根拠を添えて据え置き、working-tree 制約など有効な指摘のみ対応・追跡(#28)した。

**Action**: cross-model レビューの指摘は PR Review Response Policy で分類する前に、Critical/Important でも「実際に再現するか」を一次証拠で確認する。テストが通る/既存慣例に一致する/実挙動が異なる場合は誤検知として据え置き、判断根拠を PR コメントに残す。修正すべき実欠陥と、設計方針の相違・環境依存の誤検知を切り分ける（receiving-code-review の「performative agreement をしない」規律と同じ）。

---

<a id="ace-34-1"></a>

### ACE-34-1: Git フルオートは push/ready/merge/cleanup/ACE まで含む — 「外向き操作だから」は停止理由にしない

| フィールド | 値                |
| ---------- | ----------------- |
| Category   | process           |
| Origin     | PR #34 / Issue #4 |
| Date       | 2026-07-10        |
| Helpful    | 0                 |
| Harmful    | 0                 |
| Status     | active            |

**Insight**: 「マージまでノンストップ」と書いてあっても、終端が PR 作成まで、または外向き操作（push / Draft PR / ready / merge / cleanup / ACE）が確認対象に見えると、エージェントは各ステップで「進めていいですか？」と止まる。フルオートを効かせるには、(1) 終端を ACE まで明示し、(2) 外向きステップを確認なしで走らせる対象として列挙し、(3) 止めてよい例外だけを限定列挙する、の3点をエージェント向けガイドに書く。

**Context**: Issue #4 / PR #1/#2 で、グローバル CLAUDE.md に「マージまでノンストップ」があっても push・Draft PR・ready・merge のたびに確認が入った。`workflow-principles.md` の原則1は「Issue作成からPR作成まで」と部分終端になっており、CLAUDE.md / AGENTS.md にもフルオート節が無かった。PR #34 で CLAUDE.md / AGENTS.md / workflow-principles / AI_GIT_WORKFLOW を ACE 終端＋例外3種（破壊的操作・致命的仕様不明・安全上の実害）に揃えた。

**Action**: Git ワークフローをエージェントに指示するときは「Issue〜ACE」を終端にし、push / Draft PR / ready / merge / cleanup / ACE を確認なしの連続実行対象として書く。止めてよいのは破壊的・不可逆操作 / 実装続行不能な致命的仕様不明 / 安全上の実害のみ。「外向きだから」「共有リポジトリだから」だけでは止めない。レビュー結果は review-response-policy に従い 1 fix commit で自動対応する。

<a id="ace-35-3"></a>

### ACE-35-3: 挙動不変の外出しリファクタでは「分割前からある console フォールバック」を Critical として直さない — 分割で増えた問題だけを 1 fix に束ねる

| フィールド | 値         |
| ---------- | ---------- |
| Category   | process    |
| Origin     | PR #35     |
| Date       | 2026-07-10 |
| Helpful    | 0          |
| Harmful    | 0          |
| Status     | active     |

**Insight**: silent-failure-hunter 等は、外出し後のファイル全体を見て「`console.error` だけで握りつぶしている」を Critical にしやすい。ただし挙動不変の CSS/JS 抽出では、そのパターンは分割前のインライン JS から移動しただけである。デモ保険として意図された縮退（ログして続行・静的 HTML に金額フォールバック）を、抽出 PR で例外化・再設計するとスコープが膨張する。対応は (1) 分割で新規に生まれた問題（陳腐化したコメント、ロード順ガード、構造テスト）を 1 fix commit に束ねる、(2) 既存パターンは PR 説明で「分割前からのデモ保険」と明示して変更しない。

**Context**: PR #35 で Codex silent-failure-hunter が `deck.js` の CartSim/Funnel/Reoccur 初期化の `console.error` を Critical 4 件として FAIL。Toolkit silent-failure は同コードを「空 catch なし・ログあり・静的 HTML 縮退あり」で Critical/Warning なし。fix commit ではコメント更新・`CartModel` ガード・`deck-assets.test.js` のみ対応し、既存フォールバックは温存した。

**Action**: 純リファクタ（移動・外出し）のレビュー対応では、指摘を「今回の diff で導入/悪化したか」で仕分ける。導入済みの既存縮退は別 Issue 化し、分割 PR ではロード契約・参照切れ・コメント陳腐化など分割由来だけを 1 fix にまとめる。

---

<a id="ace-36-1"></a>

### ACE-36-1: 複数スキルが共有する判定基準は「A が正規ソース」注記だけでは足りない — 物理的な共有ファイルを SSOT にする

| フィールド | 値                 |
| ---------- | ------------------ |
| Category   | process            |
| Origin     | PR #36 / Issue #22 |
| Related    | ACE-014 / ACE-045  |
| Date       | 2026-07-11         |
| Helpful    | 0                  |
| Harmful    | 0                  |
| Status     | active             |

**Insight**: `/create-issue` と `/refine-issue` のように同じ品質ゲートを使うスキルが、片方を「正規ソース」と注記しつつもう片方に別定義を持つと、項目数・語彙・報告フォーマットが必ずドリフトする。注記は意図を伝えるだけで enforcement にならない。判定本体（項目・基準・違反例・報告フォーマット）を `.claude/commands/_shared/` 等の共有ファイル 1 箇所に置き、スキル側は参照と適用タイミングだけを書く。

**Context**: Issue #22 / PR #36 時点で create-issue と refine-issue がそれぞれチェックリストを持ち、Issue 本文では「4 項目 vs 6 項目」と記述されていたが、実体は両者とも 6 項目に成長し、項目の分解（具体性/曖昧語の分離 vs 統合）や refine 専用の「受け入れ条件の明示」が乖離していた。SSOT ファイル `issue-quality-checklist.md` に共通 5 + refine のみ 1 を集約し、両スキルから本体を削除した。

**Action**: 2 つ以上の skill / command が同じ判定表を使うときは、最初から共有ファイルを切り、スキル本文に判定本体を複製しない。「X が正規ソース」コメントは、実体が 1 ファイルであることの確認用に残す。ドリフト疑い時は両スキルの本文 grep でチェックリスト行が残っていないかを見る。

---

<a id="ace-36-3"></a>

### ACE-36-3: 多段スキルの skip 条件は「最後のステップが 0 件」だけでは足りない — 上流ゲートの違反も AND で見る

| フィールド | 値                 |
| ---------- | ------------------ |
| Category   | process            |
| Origin     | PR #36 / Issue #22 |
| Related    | ACE-004            |
| Date       | 2026-07-11         |
| Helpful    | 0                  |
| Harmful    | 0                  |
| Status     | active             |

**Insight**: 手順 4 で品質違反を検出し、手順 5 で SubAgent 探索が 0 件だったとき、「論点 0 件なので階層アクションを skip」と書くと、品質違反の hierarchical 対応（AC 具体化など）が落ちる。多段スキルの skip 条件は「下流の結果が空」ではなく「上流ゲート違反 0 件 AND 下流論点 0 件」のように、処理対象の全入力が空であることを明示する。手順番号の誤記（手順 8 と書いて実体は 9）も skip 誤誘導を増幅する。

**Context**: PR #36 のセルフレビュー（Toolkit code-reviewer）が refine-issue の L112「SubAgent 0 件 → 手順 6・7 skip → 手順 8 完了報告」を検出。完了報告は手順 9 であり、手順 4 の品質違反がある場合でも SubAgent 0 件なら階層処理を飛ばし得る。fix で「品質違反 0 かつ SubAgent 0 のときのみ skip」と明文化した。

**Action**: スキルに「N 件なら次を skip」と書くとき、skip 入力が複数ソース（品質ゲート + 探索 + ラベル等）なら AND 条件で列挙する。手順番号を参照する文は見出し番号と突き合わせてからコミットする。

---

<a id="ace-38-2"></a>

### ACE-38-2: 知見ループは Curate（書く）だけでは回らない — Reuse（読む）導線を Issue 作成時と着手前の二段で明文化する

| フィールド | 値         |
| ---------- | ---------- |
| Category   | process    |
| Origin     | PR #38     |
| Date       | 2026-07-17 |
| Helpful    | 1          |
| Harmful    | 0          |
| Status     | active     |

**Insight**: ナレッジ蓄積は書く側（Generate→Reflect→Curate）を整備しても、ワークフローに「読む」ステップが無ければ参照されない。再利用を「計測するスクリプト」が存在すること自体が、読む側が仕組みでなく偶然に依存しているシグナル。Issue 作成時（関連エントリを本文に添付）と実装着手時（索引検索ゲート）の二段に導線を置くと、Issue 経由でも直接着手でも知見に到達する。

**Context**: PR #38。10 ステップワークフローのステップ3 は MASTER/PATTERNS/TESTING のみ参照を指示し、create-issue も PLAYBOOK に言及なし。ace-setup が Copilot/Cursor/AGENTS へ書き込む ACE ルールも curate（マージ後に書く）専用で、「着手前に読め」はどこにも無かった。

**Action**: ナレッジ蓄積の仕組みを導入・監査するときは、「書く手順」と対で「どのステップで誰が読むか」を workflow 文書と Issue 作成コマンドの両方に明文化する。読んだ事実が計測に届く記録先（コミット件名等）も同時に指定する。

<a id="ace-42-1"></a>

### ACE-42-1: AI の EOL バージョン選定は「最新LTSと書く」だけでは防げない — 選定時のライブ検証義務をセットで定義する

| フィールド | 値         |
| ---------- | ---------- |
| Category   | process    |
| Origin     | PR #42     |
| Date       | 2026-07-17 |
| Helpful    | 1          |
| Harmful    | 0          |
| Status     | active     |

**Insight**: AI がサポート切れバージョンを選ぶ原因は 2 層ある。(1) 選定ルールが仕様に無く学習データ中の頻出バージョンに引っ張られる、(2) ルールを書いても学習カットオフにより AI の「最新 LTS」知識自体が古い。したがって「フルサポート中の最新 LTS をデフォルトとする」というポリシー定義だけでは不十分で、「選定時に公式リリーススケジュールを Web で確認し、確認日と情報源 URL を記録する」検証義務を同じルールセットに含める必要がある。

**Context**: PR #42 / Issue #41。AI ツールが実際に EOL バージョンを選定する事故が起きたため、MASTER.md テンプレートに「バージョン選定ポリシー（LTSデフォルト）」節を新設。ルール定義（LTS デフォルト / EOL 禁止）と検証義務（公式スケジュール確認 + 記録）+ 例外時のユーザー承認 + DECISIONS.md 記録の 2 段構えで設計した。

**Action**: AI に選定を委ねる値（バージョン・モデル名・API 仕様等、時間で陳腐化する知識）にデフォルトルールを定義するときは、「何を選ぶか」と対で「選定時に一次情報をライブ確認し記録する」義務を明文化する。カットオフで陳腐化する知識はルールの静的記述だけでは制御できない。

<a id="ace-45-2"></a>

### ACE-45-2: 下流への port レビューは上流 SSOT の欠陥検出器 — 指摘は即 Issue 還元し、還元 PR の AC を「本文 diff 0」にする

| フィールド | 値         |
| ---------- | ---------- |
| Category   | process    |
| Origin     | PR #45     |
| Date       | 2026-07-17 |
| Helpful    | 3          |
| Harmful    | 0          |
| Status     | active     |

**Insight**: 上流で複数巡レビューを通過した文面でも、下流リポジトリへの port を fresh なクロスモデルレビューにかけると、上流にもそのまま当てはまる欠陥（文言矛盾・空集合ケース）が新たに出る。指摘を「port 固有か / 上流にも当てはまるか」で仕分けて後者を即 Issue 化し、還元 PR では「対象セクションの本文が下流適用版と diff 0」を機械的な受け入れ条件にすると、両リポジトリの drift を検証可能な形で閉じられる。

**Context**: PR #42（3 巡レビュー通過）のポリシーを プラグイン配布側#103 へ反映した際、Codex が上流由来の欠陥 3 件（EOL 例外境界・公式/集約の不整合・Django 空集合）を検出。Issue #43 として即還元し、PR #45 は `sed` でポリシー節を抽出した diff 0 検証を AC にして本文一致を機械的に確認した。プラグイン配布側 ACE-101-1（port レビューの逆流検出）の上流側ミラー。

**Action**: SSOT の文面を他リポジトリへ反映するたびに反映先で独立レビューを回し、上流適用可能な指摘は作業を止めずに `gh issue create` で即還元する。還元 PR の AC は「共有すべき本文の機械的 diff 0」で定義し、目視の同等確認に頼らない。

<a id="ace-47-1"></a>

### ACE-47-1: Issue クローズは検証イベントにする — マージ直前の AC 照合ゲートで GWT+DoD を照合してから閉じる

| フィールド | 値         |
| ---------- | ---------- |
| Category   | process    |
| Origin     | PR #47     |
| Related    | ACE-38-2   |
| Date       | 2026-07-18 |
| Helpful    | 1          |
| Harmful    | 0          |
| Status     | active     |

**Insight**: `Closes #N` の自動クローズは便利だが**検証イベントを持たない** — 起票時に GWT+DoD を書かせても、クローズ時に照合されなければ AC は書きっぱなしで終わる。マージ直前（Issue がまだ open のうち）に AC 照合を挟むと、①未達ならマージを止めて修正に戻れるマージゲートになり、②達成項目のチェックボックス更新 + 完了報告コメントが Issue 本文とタイムラインの両方に検証記録として残り、③起票時（/create-issue）とクローズ時（/close-issue）で Issue のライフサイクル両端が対称に検証される。なお `Closes #N` は**デフォルトブランチへのマージ時のみ**発動するため、develop がデフォルトでない構成ではクローズ時期が昇格までずれる点も設計時に踏まえる。

**Context**: PR #47 / Issue #46 で AC 照合ゲート（/close-issue）を設計・文書化。従来は squash merge と同時に Issue が無言でクローズされ、AC が検証されたかの記録がどこにも残らなかった。ゲートは 10 ステップを増やさず「ステップ8: Merge」の前段として吸収し、コマンド本体は ff-dev-toolkit#4 で実装（PR #47 と ff-dev-toolkit#5 自身で dogfood 済み）。ACE-38-2（Curate だけでは回らない）と同型で、「書く」（起票時の AC）には「照合する」（クローズ時）の対導線が要る。

**Action**: `gh pr ready` の後・`gh pr merge --squash` の前に `/close-issue <PR番号>` を実行する。未達 AC は fix commit → 再照合の自動修正ループで解消し、仕様変更が必要な場合のみ停止。照合時の head SHA を `--match-head-commit` に渡して照合後の push 混入を防ぐ。プラグイン未導入環境では同等の手順（closingIssuesReferences 検出 → AC 判定 → `- [x]` 更新 → 完了報告コメント）を gh コマンドで手動実施する。

<a id="ace-49-1"></a>

### ACE-49-1: 複数リポジトリを跨ぐリレー手順は Playbook 知見止まりにせず、起点リポジトリのスキルへ昇格する

| フィールド | 値         |
| ---------- | ---------- |
| Category   | process    |
| Origin     | PR #49     |
| Related    | ACE-47-1   |
| Date       | 2026-07-18 |
| Helpful    | 0          |
| Harmful    | 0          |
| Status     | active     |

**Insight**: 「どのリポジトリで実装を始めるか」のようなルーティング判断を含む多リポジトリのリレー作業は、ACE エントリとして知見化しても**読まれなければ効かない**。事故（誤った起点での実装、末端ステップの実行忘れ、列挙表記の更新漏れ）を防ぐには、リレーの起点リポジトリにスキルとして固定化し、①判断原則（リポジトリ地図・実装起点）を手順の冒頭に置く、②「対象なし」を正常終了として定義する、③既にスキル化済みの区間は再実装せず接続する、の形に落とす。知見→スキルの昇格判断は「同型の事故・手戻りが実際に発生し、手順が機械的に列挙できるか」で行う。

**Context**: /close-issue の実装が公開ミラー側で始まり backport が必要になった事故（プラグイン配布側 ACE-105-1）を受け、上流 → プラグイン配布側 → 公開 → ローカル配布の 4 区間リレーのうち手作業だった区間②④を PR #49 で `.claude/skills/port-to-plugins/SKILL.md` に固定化した。区間③は既存の sync-dev-toolkit スキル + hooks があったため接続のみとした。本リポジトリの「レビュー指摘 3 回で PATTERNS.md ルール化 + 自動化検討」と同じ昇格構造。

**Action**: リレー型の運用でリポジトリ選択ミス・ステップ実行忘れが発生したら、ACE エントリ追記と同時に「起点リポジトリのスキル化で防げるか」を判定する。スキル化する場合、ルーティング原則を冒頭に置き、対象なし終了・既存スキルへの接続・末端の反映確認（バージョン一致等の機械検証）まで含める。

<a id="ace-61-1"></a>

### ACE-61-1: docs/spec のみの PR でも cross-model review を省略しない

| フィールド | 値         |
| ---------- | ---------- |
| Category   | process    |
| Origin     | PR #61     |
| Related    | ACE-001    |
| Date       | 2026-07-19 |
| Helpful    | 0          |
| Harmful    | 0          |
| Status     | active     |

**Insight**: 変更が docs / spec のみでも cross-model review（Codex 等）を省略しない。単一モデル（自分）が環境要因で得た事実（既存ファイルの有無・件数・依存バージョン）を鵜呑みにした誤りを、別モデルが差分レビューで捕まえる。ACE-001 の「単一 AI モデルが見落とす問題を発見する」は docs/spec 変更でも成立する。

**Context**: グラフ索引実験の spec 移植 PR（#60）で「docs-only だから軽め」と判断しかけたが、Codex が `scripts/ace` の存在誤認・対象コーパス件数の誤認（4→10 ファイル）・`engines.node` と `node:sqlite` の齟齬など実害ある事実誤りを複数検出した。

**Action**: review-level 判定に従い、docs/spec のみの変更でも cross-model review を実施する。特に「既存の有無・件数・パス・依存バージョン」といった事実主張は、review で裏取りする対象として明示的に扱う。

<a id="ace-61-2"></a>

### ACE-61-2: 件数・存在の事実は「実行して得た決定的出力」で裏取りする（単一ツール出力を鵜呑みにしない）

| フィールド | 値         |
| ---------- | ---------- |
| Category   | process    |
| Origin     | PR #61     |
| Date       | 2026-07-19 |
| Helpful    | 0          |
| Harmful    | 0          |
| Status     | active     |

**Insight**: `find` / `grep` / `gh` 等のツール出力は環境要因で欠損・省略されることがある。ファイル数・エントリ数・存在といった事実主張は、単一のツール出力で確定させず、実際に build して走らせた決定的な出力（パーサのカウント等）や API プローブで裏取りする。

**Context**: 本実験のセッションでツール出力が繰り返し欠損し、playbook を 4 ファイルと誤認（実際 10）、エントリ数を 75 と誤認（実際 119）した。最終的に build-graph の `nodes=119` 出力と `gh api` プローブで確定。仕様に「ノード数がテキスト側実数と一致（FR-1）」を置いたことが検出器として機能した。

**Action**: 件数・存在を根拠にする判断では単一ツール出力を確定情報にしない。実行して得た決定的カウントや API で裏取りし、仕様側に「実数と一致」の検証項目を置く。

<a id="ace-63-1"></a>

### ACE-63-1: 運用ルールを導入する PR では同じ PR の作業でルール自体をドッグフーディングする — 実行例が最初の参照実装になる

| フィールド | 値         |
| ---------- | ---------- |
| Category   | process    |
| Origin     | PR #63     |
| Date       | 2026-07-20 |
| Helpful    | 0          |
| Harmful    | 0          |
| Status     | active     |

**Insight**: 新しい運用ルール（記録テンプレート・コメント運用等）を文書に追加するとき、その PR の作業自体にルールを 1 回以上適用すると、テンプレートの実用性・トーン・フルオートとの両立が導入前に実証され、実行例が恒久的な参照実装として Issue/PR に残る。文書だけの導入は「実際に書けるか」を検証せずに出荷することと同じ。

**Context**: PR #63 で「決定事項コメント」運用（4 行テンプレート・報告型・イベント駆動）を導入する際、実装中に発生した 2 つの実決定（implementation-notes.md との住み分け、docs-template ミラー非対称の #64 分離）を新テンプレートで Issue #62 に投稿した。4 項目が実決定で無理なく埋まること・報告型でフローが止まらないことを導入前に確認でき、Issue に最初の実例が残った。

**Action**: 運用ルール・テンプレートを導入する PR では、同 PR の作業中に発生した実イベントへルールを適用して出荷前検証する。適用機会が無かった場合はその旨を PR に明記する。

<a id="ace-70-1"></a>

### ACE-70-1: レビューが収束しない時、指摘が diff のどこに集中しているかを見る — 全部が「依頼外の追加分」なら疑うのは設計ではなくスコープ

| フィールド | 値                            |
| ---------- | ----------------------------- |
| Category   | process                       |
| Origin     | PR #70 / Issue #69            |
| Related    | ACE-464-2, ACE-447-3, ACE-044 |
| Date       | 2026-07-22                    |
| Helpful    | 0                             |
| Harmful    | 0                             |
| Status     | active                        |

**Insight**: cross-model レビューが収束しない時の原因は「設計が間違っている」（[ACE-464-2](#ace-464-2)）だけではない。**依頼されていないコードを PR に足したこと**が原因の場合があり、その診断信号は指摘の「テーマの持続」ではなく **diff 上の分布**にある。依頼された変更に指摘が 0 件で、追加分にすべて集中しているなら、正しい手当ては patch でもピボットでもなく**追加分の切り出し**。指摘に機能追加で応じるとレビュー対象面積が増えるため、足しながら green を待つほど収束は遠のく。切り出し先は多くの場合、同じ根本原因を扱う既存 Issue である（追加機能が必要になった理由＝未修正の根本原因、という関係が成り立つため）。

**Context**: PR #69/#70（`codex-review.sh` のモデル固定を廃し codex config へ委譲）は 1 巡目に Toolkit（code-reviewer）と Codex（5 観点すべて PASS）双方から APPROVED を得た。**レビュアーは指摘が無ければ clean verdict を返す**（収束しなくなったのはレビュアーの設定ではなく対象を増やしたため、という証拠でもある）。その際 silent-failure-hunter が「委譲後は見出しが実モデルを保証しない」と指摘したため stderr バナーから実行モデルを拾う機能を追加したところ、2 巡目 5 件・3 巡目 6 件の指摘が**すべてこの追加機能とそのテスト**に集中し（依頼された委譲部分は 1 巡目以降ゼロ）、テスト行数が 500 行ソフト上限を超える指摘まで誘発した。追加機能が必要な根本原因は「`review-common.sh` が stderr を成功パスで捨てる」であり、これは別 Issue #72 の症状 1（timeout 警告の握り潰し）と同一の根だった。機能を #72 へ移して 1 巡目の形に戻したところループが止まった。

**Action**:

1. レビューが 2 巡目以降も指摘を出し続けたら、指摘を「元の依頼範囲」と「自分が足した分」に仕分ける。後者に偏っていたらスコープ過剰を疑い、追加分を PR から外して別 Issue へ移す。
2. 移す先を探すとき、追加機能が必要になった**根本原因**で既存 Issue を検索する。同じ根の Issue があれば統合し、依存元を先に直す形に組み替える（前借りをやめる）。
3. 停止ゲートは [ACE-447-3](#ace-447-3) / [ACE-464-2](#ace-464-2) と同じく「Critical 不在＋実 Important 全対応」。据え置く指摘は根拠付きで記録する（[ACE-27-4](#ace-27-4)）。切り出した項目は宣言だけで終わらせず、その場で `gh issue create` する（[ACE-044](#ace-044)）。
