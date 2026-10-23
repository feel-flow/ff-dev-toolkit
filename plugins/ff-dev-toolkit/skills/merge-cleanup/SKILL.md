---
name: merge-cleanup
description: "PR マージ後のクリーンアップを一括実行（base ブランチ復帰 / fetch --prune / リモートブランチ削除 / [gone] ブランチ削除 / 関連 worktree 削除 / worktree トランスクリプトのアーカイブ回収 / リモート取り残しのガード付き自動削除。未コミット変更ガードはパス除外を指定できる）"
allowed-tools: ["Bash"]
---

# /merge-cleanup — PR マージ後のクリーンアップ一括実行

## ASDD 2.0 設定がある場合

最初に[共通設定契約](../asdd-init/references/configuration.md)を読み、`scripts/asdd/config.mjs` の `loadConfig(root)` で対象プロジェクトの `.asdd/config.json` を検証する。以下の従来手順より、合意済みの文書構成・機能スイッチ・ワークフローを優先する。設定なしは従来互換、不正設定は自動処理を止めて診断する。

合意した確認方法だけを適用する。未合意の推奨をゲートにせず、無効にした ACE・振り返り・複数AIレビューをチェーンへ足さない。

Git Workflow のマージ後クリーンアップを 1 コマンドで実施する project-agnostic な実装。実体は同梱 `scripts/merge-cleanup.sh`（全ステップが 1 プロセスで走り、途中結果が最終サマリーまで正しく引き継がれる）で、`scripts/finish.sh cleanup` が PR の実在と gh の到達を確かめてから委譲する。本文が持つのは呼び出しと、終了コード・サマリーの読み方（判断点）だけ。挙動の全文は `merge-cleanup.sh` のヘッダにある。

<!--920bddec85dfa5b0-->
MCP: 取得値: MCP で同じ PR の state / head / base / fork / OID と merged/open 一覧を取得。形式: cleanup-state / cleanup-pr / cleanup-guards の raw JSON を同じ index に保存。渡し先: finish.sh cleanup <PR> --github-input /absolute/index.json へ渡す（jq と Git は必要）。不足時: 必須不足は rc2 で停止、削除 guard の任意不足は SKIP / PARTIAL で保全。gh 専用前提は file 経路には課さない。

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
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/check-shebang-cr.sh" || exit $?
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/finish.sh" cleanup $ARGUMENTS
```

- **前提ツール**: 認証済み `gh` CLI と `jq`（不足していれば冒頭で中断して案内する）。PR 不在・gh 不通は委譲前に **rc 1** で名指しし、復帰手段を出す（黙って 0 で終わらない。委譲先の PARTIAL = rc 2 とは重ねない）
- **`--dry-run`**（`finish.sh cleanup --dry-run <PR>`）: 1 つも削除せず、「実行した場合に削除されるリモートブランチ・ローカルブランチ・worktree・リモート取り残し」を一覧表示して終わる。保護ブランチ・dirty worktree・fail-closed な縮退の判定は通常実行とまったく同じで、dry-run だけ緩まない。見送った prune とリモート削除の連鎖は read-only の `git ls-remote` で予測して一覧へ含める。動作検証・導入先での初回実行など、確認したい 1 点のためにツールの全副作用を引き受けたくない場面で使う
- **実行する cwd**: 対象PRのheadを保持するリンクworktreeでは破壊的処理の前に中断する。他セッションのcheckoutは変更せず、下のworktree手順からswitchなし掃除へ進む。detached HEAD の linked worktree は switch なし掃除モード。main worktree の detached HEAD は通常モードで base へ戻るため、退避先にしない。
- **`disable-model-invocation` は意図的に付けない**。実行部が 1 行なのでフラグはスクリプト直叩きで迂回でき破壊的操作を防げない一方、フルオートチェーンが本スキルの実行を求めているため可用性だけが落ちる（ACE-147-1。回帰防止は `tests/skill-frontmatter/verify.sh`）
- マージ前の base 追随・リベース後の送信は [Git Workflow](../../docs-template/05-operations/deployment/git-workflow.md#base-の取り込みとリベース後の送信) に従う（本スキルが行うマージ済みブランチの削除とは別の手順）

<!--79a18ae02cc1145d-->
MCP: 取得値: MCP で同じ PR の state / head / base / fork / OID と merged/open 一覧を取得。形式: cleanup-state / cleanup-pr / cleanup-guards の raw JSON を同じ index に保存。渡し先: finish.sh cleanup <PR> --github-input /absolute/index.json へ渡す（jq と Git は必要）。不足時: 必須不足は rc2 で停止、削除 guard の任意不足は SKIP / PARTIAL で保全。gh 専用前提は file 経路には課さない。

## スクリプトの処理と環境変数

[処理一覧と環境変数](references/steps.md)を読む。MERGED・same-repo・head OID・open PR 再利用・保護枝・worktree の生存と clean を照合し、削除は exact ref の lease 付き。取得不能は削除保全、意図した SKIP と失敗を分ける。

## 呼び出し元が base でも PR head でもないブランチにいる場合 — switch なし掃除モード

並列セッション運用で主 checkout が他セッションの作業ブランチを保持したまま呼ばれた場合、スクリプトは**ブランチ切り替えを伴わない掃除モード**で続行する: base への復帰・`pull --ff-only` は行わず（最新化は `git fetch origin <base>:<base>` を試み、拒否されたらスキップして報告）、base を保持する worktree は detach も削除もせず報告だけ、リモート削除・`[gone]` 掃除・worktree 削除・トランスクリプト回収・取り残し検証は通常どおり実施する。呼び出し元が dirty でも中断しない（このモードは呼び出し元に一切触れない）。未実施項目はサマリーに名指しで載る（意図的な見送いなので PARTIAL には数えない）。detached HEAD の linked worktree も同モードで両 HEAD を保持する。main worktree の detached HEAD は通常モード。

### worktreeセッションの経路

自分のcleanなworktreeは[手順](references/worktree-session.md)へ進む。他checkoutは変更しない。


## マージ実行時の注意 — base ブランチが他 worktree に保持されている場合

`finish.sh precheck` は base / head を別 worktree が保持する回に、既存の互換経路と明示的な OID lease を保つため `--delete-branch` を外す。merge 対象は取得済みのホストを含む URL の `--repo` へ固定する。gh v2.102.0 はこの経路でローカルの切替・削除を行わず、その後始末は本スキルへ委譲する。生成コマンドは merge 成功後だけ ref を照会し、不在は成功・別 OID は保全・一致は lease 削除となる。削除拒否後も再照会し、照会不能や期待 OID が残る削除失敗は非 0 で終わる。`HEAD_DELETE_RESULT` を merge の成否とは別項目で報告する（[詳細](../../docs-template/05-operations/deployment/git-workflow.md#ステップ8-マージmerge)）。他セッションの worktree は削除せず、保持者のパスと状態を報告して処分はユーザー判断に委ねる。その後は上の switch なし掃除モードで完走できる。

<!--c9b300ab6233b80b-->
MCP: 取得値: MCP で同じ PR の state / head / base / fork / OID と merged/open 一覧を取得。形式: cleanup-state / cleanup-pr / cleanup-guards の raw JSON を同じ index に保存。渡し先: finish.sh cleanup <PR> --github-input /absolute/index.json へ渡す（jq と Git は必要）。不足時: 必須不足は rc2 で停止、削除 guard の任意不足は SKIP / PARTIAL で保全。gh 専用前提は file 経路には課さない。

## `--delete-branch` の部分失敗の読み方とリモート個別削除

過去の `--repo` を明示しない経路では、削除対象の head ブランチ自体が別 worktree に保持されている回に、`gh pr merge --squash --delete-branch` が `failed to delete local branch ... used by worktree at ...` を残して部分的に失敗した。現在の生成コマンドは `--repo` を明示し、gh v2.102.0 のローカル後処理を行わない。マージそのものが失敗したように読めるが、**マージとリモートブランチ削除は別工程であり、そちらは成功していることがある**。判定は出力の文言ではなく実測で行う:

<!--43f5fd66df1119f1-->
分類: 非操作: 過去の部分失敗の説明であり旧 merge コマンドの再実行指示ではない。MCP merge と削除の後読は次の実測手順へ進む

1. `gh pr view <PR番号> --json state --jq .state` が `MERGED` であること
2. `git ls-remote --exit-code --heads origin '<head ブランチ>'` の**終了コード**を見ること。`2` = ref なし（リモートは削除済み）、`0` = ref あり（残存）。**それ以外の終了コードは「判定不能」で、削除済みと読んではいけない**（通信・認証の失敗でも出力は空になる）

<!--1a9171e284ecbb21-->
MCP: 取得値: MCP で同じ PR の state / merged を fresh 取得。形式: PR JSON の MERGED / merged=true と Git の exact ref 実測。渡し先: この手順の merge と削除の別判定へ渡す。MCP merge の成功応答だけで削除完了にしない。不足時: 必須の MCP 能力 / 値が欠ければ操作名と項目を示して停止。

1 と 2 の終了コード `2` を満たせば、ローカルの後始末は本スクリプトに任せる。ref が残る場合も `/merge-cleanup <PR番号>` を使う。対象 PR の head OID を照合し、同名 ref の再利用は保全、一致する場合だけ lease 付きで削除する。照合不能や削除未完了を成功とせず、サマリーの理由から復旧する。

## 終了コードとサマリーの読み方（判断点）

| code | 意味 |
| --- | --- |
| 0 | 完全成功 |
| 1 | 致命的エラーで中断（引数不正 / 環境変数の指定不正 / 呼び出し元または base 所有 worktree の未コミット変更 / switch・pull 失敗 / gh 失敗 / Step 3 の `fetch --prune` 失敗 など）。`finish.sh cleanup` が委譲前に止める前提崩れ（PR 不在 / gh 不通 / 委譲先の不在。未実行）もここ |
| 2 | 完了したが一部失敗あり（PARTIAL）。サマリーの「失敗した項目」を確認して手動対応。**リモートブランチの削除失敗と、その直後の削除反映 `fetch --prune` の失敗はここ**（掃除全体を止めない） |

<!--427082609d0f5cda-->
MCP: 取得値: MCP で同じ PR の state / head / base / fork / OID と merged/open 一覧を取得。形式: cleanup-state / cleanup-pr / cleanup-guards の raw JSON を同じ index に保存。渡し先: finish.sh cleanup <PR> --github-input /absolute/index.json へ渡す（jq と Git は必要）。不足時: 必須不足は rc2 で停止、削除 guard の任意不足は SKIP / PARTIAL で保全。gh 専用前提は file 経路には課さない。

- 0 以外なら、サマリーの失敗項目・中断理由をユーザーに報告し、勝手にリトライや強制削除をしない
- サマリーの「対象 PR のリモートブランチ」（`削除した` / `既に存在しない` / `削除していない（保護 / 要確認）`）は完了報告へそのまま引用する。`headRefOid` を取得できなかった回は削除だけをスキップし（`skipped_oid_unavailable`。Step 7 が照合済み OID で肩代わりできれば `deleted_by_leftover_retry` へ更新）、無条件の `git push origin --delete` は案内しない — `ls-remote` の OID が PR の head だと人間が確認できた場合だけ `--force-with-lease=refs/heads/<head>:<確認済みOID> :refs/heads/<head>` で消し、merge-cleanup を再実行する
- 「スキップした削除候補」は警告文だけで判断せず `git ls-remote --heads origin <branch>` と `git branch --list` の実測で現物を確認する。設定パターンに止められた候補には、照合済み OID を lease に載せた手動削除コマンドと恒久設定の案内が付く
- base を保持していた clean な別 worktree は同じ commit の detached で残る。worktree の削除は clean 確認後でも `.gitignore` 対象のファイル（`.env` 等）は消える
- `/ace-curate <PR番号>` の**前に**実行する。cleanup が完了しないかぎり Git Workflow は終了していない

## 安全原則（スクリプトが保証すること）

保護ブランチはローカル・リモートとも絶対に削除しない／未コミット変更を勝手に消さない／他セッションの作業ブランチを切り替えない・worktree を消さない／ガード情報の取得失敗は fail-closed（「取得失敗 = 削除中止」）／トランスクリプトは推測で消さない（`cwd` 照合 + 検証済みアーカイブ）／失敗を握りつぶさない（PARTIAL）／リモート削除の失敗で掃除全体を止めない（消せなかったことは記録して続行）／削除 push で consumer の simple-git-hooks / husky のフルゲートを起動しない（消えた ref へは削除 push 自体を行わない）。

## プロジェクト固有処理の拡張ポイント（optional）

リポジトリ root に置けば呼ばれる（無くても動く。実行可能でなければスキップして警告）: `.claude/hooks/pre-merge-cleanup.sh`（未コミット変更ガード通過直後・base 復帰の前。失敗すると中断）/ `.claude/hooks/post-branch-cleanup.sh`（`[gone]` ブランチごとの削除直前。`BRANCH` / `WORKTREE_PATH` を渡す。失敗するとそのブランチをスキップ）/ `.claude/hooks/post-merge-cleanup.sh`（最終検証の直後。失敗は警告のみ）。
