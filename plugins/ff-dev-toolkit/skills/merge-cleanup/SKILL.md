---
name: merge-cleanup
description: "PR マージ後のクリーンアップを一括実行（base ブランチ復帰 / fetch --prune / リモートブランチ削除 / [gone] ブランチ削除 / 関連 worktree 削除 / worktree トランスクリプトのアーカイブ回収 / リモート取り残しのガード付き自動削除。未コミット変更ガードはパス除外を指定できる）"
allowed-tools: ["Bash"]
---

# /merge-cleanup — PR マージ後のクリーンアップ一括実行

## ASDD 2.0 設定がある場合

最初に[共通設定契約](../asdd-init/references/configuration.md)を読み、`scripts/asdd/config.mjs` の `loadConfig(root)` で対象プロジェクトの `.asdd/config.json` を検証する。以下の従来手順より、合意済みの文書構成・機能スイッチ・ワークフローを優先する。設定なしは従来互換、不正設定は自動処理を止めて診断する。

合意した確認方法だけを適用する。カバレッジ80%、Result pattern、strict、定数化などの推奨を未合意のゲートにしない。ACE・振り返り・複数AIレビューの無効設定を尊重し、チェーン末尾にも追加しない。市民開発のIssue中心運用では、既存の組織ルールを保ちつつ、未採用のPR・7文書を必須化しない。

Git Workflow のマージ後クリーンアップを 1 コマンドで実施する project-agnostic な実装。実体は同梱 `scripts/merge-cleanup.sh`（全ステップが 1 プロセスで走り、途中結果が最終サマリーまで正しく引き継がれる）で、`scripts/finish.sh cleanup` が PR の実在と gh の到達を確かめてから委譲する。本文が持つのは呼び出しと、終了コード・サマリーの読み方（判断点）だけ。挙動の全文は `merge-cleanup.sh` のヘッダにある。

## プラグインルートの固定（必須）

<!-- ff-dev-toolkit-plugin-root-contract:start -->
同梱resourceを参照する前に `FF_DEV_TOOLKIT_ROOT` を**一度だけ**解決し、実行中は変更しない。

- Claude Codeでは、その呼び出しでホストが渡した `${CLAUDE_PLUGIN_ROOT}` を使う
- grok CLIでは、Bash tool 環境の `${GROK_PLUGIN_ROOT}` があればそれを使う（skill 経路では未設定が普通なので、次項の `FF_DEV_TOOLKIT_SKILL_FILE` を渡す）
- Codexなど他ホストでは、実際に読み込んだこの `SKILL.md` の絶対パスを `FF_DEV_TOOLKIT_SKILL_FILE` として固定し、そこから `../..` を解決する

このskillを実行するAI hostは、Bash tool呼び出しを組み立てるとき、skill loaderが返した実値で `FF_DEV_TOOLKIT_SKILL_FILE="<このSKILL.mdの絶対パス>"; export FF_DEV_TOOLKIT_SKILL_FILE` を実行し、同じshell script bodyでresourceを呼び出す。placeholderのまま実行したり、cache pathを推測して埋めたりしない。
plugin内ドキュメントの正本は、読み込んだこの `SKILL.md` のdirectoryを基準にした [plugin root固定契約](../../docs-template/05-operations/deployment/multi-cli-review-orchestration.md#ff-dev-toolkit-plugin-root-prerequisite) である。consumerへコピーされた `docs/` や物理CWDを基準に解決しない。
review系resource（`setup-multi-agent.sh` / `multi-agent.sh` / `multi-review.sh`）を直接呼ぶhostだけが、同節のresolver + guard fence全体を読み、handoff設定・guard・resource呼び出しを同じshell script bodyで実行する。そのhostはtask workspace repository rootも `FF_DEV_TOOLKIT_PROJECT_ROOT` として同じBash tool呼び出しへ渡し、現在の物理CWDおよび `git rev-parse --show-toplevel` と一致することを実行前に確認する。review以外のresourceはこのreview専用guardを実行せず、固定したroot配下で各skillが指定するresourceだけを呼出直前に検証する。以下のBash例は、同じtool bodyで固定済みrootを使うcommand断片として扱う。

解決後は同じ絶対パスだけを使い、cache / marketplace / 旧インストール領域を走査して選ばない。
version sortによる版の選び直しや、sidecarを使った別実体への切替も行わない。
解決済みrootまたは必要resourceが消失・不整合になった場合は、別versionへfallbackせず
「ff-dev-toolkit更新後にこのskillを再呼び出してください」と案内して停止する。
<!-- ff-dev-toolkit-plugin-root-contract:end -->

<!-- ff-dev-toolkit-plugin-root-guard:start -->
固定したrootが消えた状態で手順を先へ進めないため、同梱resourceを呼ぶBash tool呼び出しの本文冒頭で次のguardを実行する。手順書のguardは実行環境の `set -e` を仮定できないので、`||` の右辺で `false` を返す形ではなくifで構造的に停止する。

```bash
if [ -z "${FF_DEV_TOOLKIT_ROOT:-}" ] || [ ! -d "${FF_DEV_TOOLKIT_ROOT}" ]; then
  echo "ff-dev-toolkit更新後にこのskillを再呼び出してください（plugin rootが解決できません）" >&2
  exit 2
fi
```

<!-- ff-dev-toolkit-plugin-root-guard:end -->

同じ停止は `scripts/merge-cleanup.sh` 自身にも複製してある（自分の実体位置とホストが渡した root が同じ実体を指すことを確認し、食い違えば案内を出して中断する。候補は探索しない。中断コードは 1 で PARTIAL の 2 と区別する）。

## 実行方法

**引数**: `$ARGUMENTS`（マージされた PR 番号、例: `1234`）。**必須** — `delete_branch_on_merge = false` のリポジトリではリモートブランチが残るため、PR 番号から head ref を引いて明示削除する。`bundle`（子 Issue を全件 1 PR で束ねた着手単位）でも渡す番号は**その 1 本の PR**だけ。

```bash
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/finish.sh" cleanup $ARGUMENTS
```

- **前提ツール**: 認証済み `gh` CLI と `jq`（不足していれば冒頭で中断して案内する）。PR 不在・gh 不通は委譲前に **rc 1** で名指しし、復帰手段を出す（黙って 0 で終わらない。委譲先の PARTIAL = rc 2 とは重ねない）
- **`--dry-run`**（`finish.sh cleanup --dry-run <PR>`）: 1 つも削除せず、「実行した場合に削除されるリモートブランチ・ローカルブランチ・worktree・リモート取り残し」を一覧表示して終わる。保護ブランチ・dirty worktree・fail-closed な縮退の判定は通常実行とまったく同じで、dry-run だけ緩まない。見送った prune とリモート削除の連鎖は read-only の `git ls-remote` で予測して一覧へ含める。動作検証・導入先での初回実行など、確認したい 1 点のためにツールの全副作用を引き受けたくない場面で使う
- **実行する cwd**: 対象 PR のブランチを保持する**リンクされた** worktree を cwd にしたまま実行すると、破壊的処理の前に中断する（その cwd では掃除対象自身を削除できないため）。案内には main worktree のパスと再実行コマンドが出る。main worktree から・他セッションの作業ブランチ（下記の掃除モード）・detached HEAD・base 保持からの実行は完走する
- **`disable-model-invocation` は意図的に付けない**。実行部が 1 行なのでフラグはスクリプト直叩きで迂回でき破壊的操作を防げない一方、フルオートチェーンが本スキルの実行を求めているため可用性だけが落ちる（ACE-147-1。回帰防止は `tests/skill-frontmatter/verify.sh`）
- マージ前の base 追随・リベース後の送信は [Git Workflow](../../docs-template/05-operations/deployment/git-workflow.md#base-の取り込みとリベース後の送信) に従う（本スキルが行うマージ済みブランチの削除とは別の手順）

## スクリプトがやること

1. **未コミット変更ガード** — あれば中断してユーザーに分類判断を仰ぐ（`git restore` / `git clean` は実行しない）。常駐ツールが書き続けるパスは `FF_MERGE_CLEANUP_IGNORE_PATHS` で対象外にできる（下記）
2. **対象 PR の情報取得** — state / head / base / headRefOid / fork 判定。**MERGED でなければ破壊的処理の前に中断**（番号の打ち間違い対策）
3. **base ブランチ復帰 + 最新化** — `baseRefName` へ `git switch` し `fetch --prune` + `pull --ff-only`。別 worktree が base を保持していれば、clean のときだけ同じ HEAD の detached へ退避して worktree を残し、dirty なら触らず中断する
4. **対象 PR のリモートブランチ削除** — same-repo かつ open PR で head 再利用されていない場合に `--force-with-lease=<ref>:<期待OID>` で削除（照合と削除の間の push はサーバー側で原子的に拒否 = TOCTOU 対策）。削除 push は `SKIP_SIMPLE_GIT_HOOKS=1` 付き
5. **`[gone]` ローカルブランチ + 関連 worktree の削除** — worktree は clean を確認してから。`-D` は (名前, ローカル OID) が MERGED PR の head と一致する場合のみ。マージ済みと機械確認できたエージェント worktree（`claude agent` ロック + 使い捨てパス `.review-results/` の untracked だけ）は unlock → 個別除去 → force なしの `git worktree remove` で片付ける
6. **削除した worktree のトランスクリプト回収** — jsonl の `cwd` 照合を通ったものだけを検証済み `tar.gz` へアーカイブしてから元を消す（既存の孤児は `/sweep-orphan-transcripts`）
7. **リモート取り残しのガード付き自動削除** — (名前, OID) が MERGED PR の head と一致 / fork 由来でない / 保護ブランチでない / open PR で未使用 の全ガードを通過したものだけ lease 付きで削除。ガード情報の取得に 1 つでも失敗したら削除しない（fail-closed）
8. **最終検証 + 結果サマリー** — 削除 / スキップ / 失敗を分類して報告

## 環境変数

| 変数 | 既定 | 用途 |
| --- | --- | --- |
| `FF_MERGE_CLEANUP_IGNORE_PATHS` | （空） | 未コミット変更ガードの対象外にするパス。`:` 区切りの git pathspec glob（`videos/**:.cache/**`）。効くのは「中断しても何も消えない」ガード（Step 1 / Step 3）だけで、worktree 削除前の clean 確認（Step 5）には効かない。空パターン・前後の空白は中断（fail-closed）。恒常的に dirty なリポジトリでは `.claude/settings.json` の `env` に書く |
| `FF_MERGE_CLEANUP_PROTECT_BRANCHES` | `release/*` | 追加の保護パターン（`:` 区切り glob。`none` で追加なし）。`develop` / `main` / `master` / `staging/*` はハードコードで設定でも外せない。文字クラス `[...]` は未対応で中断 |
| `FF_MERGE_CLEANUP_MERGED_PR_LIMIT` | 1000 | Step 7 の照合上限。上限到達は「これより古い MERGED PR は照合対象外」とログに出る |
| `FF_MERGE_CLEANUP_TRANSCRIPTS` | `archive` | `off` で回収を無効化。それ以外の値はエラーとして報告（黙って無効化しない） |
| `FF_MERGE_CLEANUP_PROJECTS_DIR` / `FF_MERGE_CLEANUP_TRANSCRIPT_ARCHIVE_DIR` | `<config>/projects` / `<config>/transcript-archives` | 走査対象・アーカイブ先の上書き（`<config>` は `CLAUDE_CONFIG_DIR`、未設定なら `~/.claude`） |

## 呼び出し元が base でも PR head でもないブランチにいる場合 — switch なし掃除モード

並列セッション運用で主 checkout が他セッションの作業ブランチを保持したまま呼ばれた場合、スクリプトは**ブランチ切り替えを伴わない掃除モード**で続行する: base への復帰・`pull --ff-only` は行わず（最新化は `git fetch origin <base>:<base>` を試み、拒否されたらスキップして報告）、base を保持する worktree は detach も削除もせず報告だけ、リモート削除・`[gone]` 掃除・worktree 削除・トランスクリプト回収・取り残し検証は通常どおり実施する。呼び出し元が dirty でも中断しない（このモードは呼び出し元に一切触れない）。未実施項目はサマリーに名指しで載る（意図的な見送いなので PARTIAL には数えない）。detached HEAD からの実行は通常モード。

## マージ実行時の注意 — base ブランチが他 worktree に保持されている場合

これは本スクリプトではなく前段の `gh pr merge` の話。`finish.sh precheck` が `git worktree list` で base / head の保持を実測し、保持されていれば `--delete-branch` 無し + `&&` で繋いだ lease 付きリモートブランチ削除（merge 成功時だけ走る）の merge コマンドを生成する（`gh pr merge --squash --delete-branch` はマージ成功後にローカルで base へ切り替えようとして失敗し、**PR はマージ済みなのにリモートブランチ削除まで到達しない**）。他セッションの worktree は削除せず、保持者のパスと状態を報告して処分はユーザー判断に委ねる。完了報告には「リモートブランチを削除したか」を `gh pr merge` の成否とは別項目で明示する（本スクリプトのサマリーも同じ項目を必ず出す）。その後の `/merge-cleanup` は上の switch なし掃除モードで完走できる。

## `--delete-branch` の部分失敗の読み方とリモート個別削除

削除対象の head ブランチ自体が別の worktree でチェックアウトされている場合、`gh pr merge --squash --delete-branch` は `failed to delete local branch ... used by worktree at ...` の 1 行だけを残して部分的に失敗する。マージそのものが失敗したように読めるが、**マージとリモートブランチ削除は別工程であり、そちらは成功していることがある**。判定は出力の文言ではなく実測で行う:

1. `gh pr view <PR番号> --json state --jq .state` が `MERGED` であること
2. `git ls-remote --exit-code --heads origin '<head ブランチ>'` の**終了コード**を見ること。`2` = ref なし（リモートは削除済み）、`0` = ref あり（残存）。**それ以外の終了コードは「判定不能」で、削除済みと読んではいけない**（通信・認証の失敗でも出力は空になる）

1 と 2 の終了コード `2` を満たせば、ローカルブランチ・worktree の後始末は本スクリプトの Step 5 に任せてよい。終了コード `0`（残存）のときだけ個別に削除する。**削除の前に、残っている ref がその PR の head と同一であることを確認する**（マージ後に同名ブランチが再利用されていることがある）:

```bash
REMOTE_OID="$(git ls-remote --heads origin '<head ブランチ>' | cut -f1)"
PR_HEAD_OID="$(gh pr view <PR番号> --json headRefOid --jq .headRefOid)"
[ "$REMOTE_OID" = "$PR_HEAD_OID" ] || { echo "ブランチが再利用されている。削除しない"; exit 1; }
```

一致したら削除する。**ブランチ名に含まれる `#`（Issue/PR 番号を使った命名規則）は `%23` へエンコードする**。素の `#` は URL のフラグメント区切りとして解釈され、`#` 以降が送信対象のパスから欠落した不正な ref 名になるため、`-X DELETE` は 422 で失敗する:

```bash
gh api -X DELETE repos/<owner>/<repo>/git/refs/heads/fix/%23NNNN-<slug>
```

## 終了コードとサマリーの読み方（判断点）

| code | 意味 |
| --- | --- |
| 0 | 完全成功 |
| 1 | 致命的エラーで中断（引数不正 / 環境変数の指定不正 / 呼び出し元または base 所有 worktree の未コミット変更 / switch・pull 失敗 / gh 失敗 / Step 3 の `fetch --prune` 失敗 など）。`finish.sh cleanup` が委譲前に止める前提崩れ（PR 不在 / gh 不通 / 委譲先の不在。未実行）もここ |
| 2 | 完了したが一部失敗あり（PARTIAL）。サマリーの「失敗した項目」を確認して手動対応。**リモートブランチの削除失敗と、その直後の削除反映 `fetch --prune` の失敗はここ**（掃除全体を止めない） |

- 0 以外なら、サマリーの失敗項目・中断理由をユーザーに報告し、勝手にリトライや強制削除をしない
- サマリーの「対象 PR のリモートブランチ」（`削除した` / `既に存在しない` / `削除していない（保護 / 要確認）`）は完了報告へそのまま引用する。`headRefOid` を取得できなかった回は削除だけをスキップし（`skipped_oid_unavailable`。Step 7 が照合済み OID で肩代わりできれば `deleted_by_leftover_retry` へ更新）、無条件の `git push origin --delete` は案内しない — `ls-remote` の OID が PR の head だと人間が確認できた場合だけ `--force-with-lease=refs/heads/<head>:<確認済みOID> :refs/heads/<head>` で消し、merge-cleanup を再実行する
- 「スキップした削除候補」は警告文だけで判断せず `git ls-remote --heads origin <branch>` と `git branch --list` の実測で現物を確認する。設定パターンに止められた候補には、照合済み OID を lease に載せた手動削除コマンドと恒久設定の案内が付く
- base を保持していた clean な別 worktree は同じ commit の detached で残る。worktree の削除は clean 確認後でも `.gitignore` 対象のファイル（`.env` 等）は消える
- `/ace-curate <PR番号>` の**前に**実行する。cleanup が完了しないかぎり Git Workflow は終了していない

## 安全原則（スクリプトが保証すること）

保護ブランチはローカル・リモートとも絶対に削除しない／未コミット変更を勝手に消さない／他セッションの作業ブランチを切り替えない・worktree を消さない／ガード情報の取得失敗は fail-closed（「取得失敗 = 削除中止」）／トランスクリプトは推測で消さない（`cwd` 照合 + 検証済みアーカイブ）／失敗を握りつぶさない（PARTIAL）／リモート削除の失敗で掃除全体を止めない（消せなかったことは記録して続行）／削除 push で consumer の simple-git-hooks フルゲートを起動しない。

## プロジェクト固有処理の拡張ポイント（optional）

リポジトリ root に置けば呼ばれる（無くても動く。実行可能でなければスキップして警告）: `.claude/hooks/pre-merge-cleanup.sh`（未コミット変更ガード通過直後・base 復帰の前。失敗すると中断）/ `.claude/hooks/post-branch-cleanup.sh`（`[gone]` ブランチごとの削除直前。`BRANCH` / `WORKTREE_PATH` を渡す。失敗するとそのブランチをスキップ）/ `.claude/hooks/post-merge-cleanup.sh`（最終検証の直後。失敗は警告のみ）。
