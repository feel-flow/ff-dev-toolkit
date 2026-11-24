---
name: merge-cleanup
description: "PR マージ後のクリーンアップを一括実行（base ブランチ復帰 / fetch --prune / リモートブランチ削除 / [gone] ブランチ削除 / 対象 PR の head を保持する worktree の削除 / worktree トランスクリプトのアーカイブ回収 / リモート取り残しのガード付き自動削除。未コミット変更ガードはパス除外を指定できる）"
allowed-tools: ["Bash"]
---

# /merge-cleanup — PR マージ後のクリーンアップ一括実行

## ASDD 2.0 設定がある場合

最初に[共通設定契約](../asdd-init/references/configuration.md)を読み、`scripts/asdd/config.mjs` の `loadConfig(root)` で `.asdd/config.json` を検証し、合意済みの構成・確認方法のみ適用する（未設定は従来互換、不正設定は停止して診断。無効にした ACE・振り返り・複数 AI レビューはチェーンへ足さない）。

実体は `scripts/finish.sh cleanup` → `scripts/merge-cleanup.sh`（挙動全文は `merge-cleanup.sh` ヘッダと [references/steps.md](references/steps.md)）。

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

## 実行方法

**引数**: `$ARGUMENTS` = マージ済み PR 番号（必須。`bundle` もその 1 本の PR 番号のみ）。

```bash
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/check-shebang-cr.sh" || exit $?
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/finish.sh" cleanup $ARGUMENTS
```

- **前提**: 認証済み `gh` と `jq`（PR 不在・gh 不通は委譲前に rc 1）。
- **`--dry-run`**: 削除せず対象候補を一覧表示（判定は通常と同一）。**`--verbose`**: 委譲先の全文ログを出力（通常は `## マージ後 Cleanup 結果` 以降と `CLEANUP_LOG` / `CLEANUP_RC` のみ。ログはツリー外の `FF_DEV_TOOLKIT_STATE_DIR` 配下へ保存）。
- **cwd / worktree**: 対象 PR の head を保持する linked worktree では破壊処理前に中断するため、[worktree 手順](references/worktree-session.md)から switch なし掃除へ進む（他 checkout は変更しない）。detached HEAD の linked worktree は switch なし掃除、main worktree の detached HEAD は通常モードで base へ戻る。
- `disable-model-invocation` は付けない（フルオートチェーンが本スキルを呼ぶため）。マージ前の base 追随は [Git Workflow](../../docs-template/05-operations/deployment/git-workflow.md#base-の取り込みとリベース後の送信)。

<!--a3ce56b66d76ac98-->
MCP: 取得値: MCP で同じ PR の state / head / base / fork / OID と merged/open 一覧を取得。形式: cleanup-state / cleanup-pr / cleanup-guards の raw JSON を同じ index に保存。渡し先: finish.sh cleanup <PR> --github-input /absolute/index.json へ渡す（jq と Git は必要）。不足時: 必須不足は rc2 で停止、削除 guard の任意不足は SKIP / PARTIAL で保全。gh 専用前提は file 経路には課さない。

## 処理とモード（switch なし掃除・worktree 保持時）

- **処理と環境変数**: [references/steps.md](references/steps.md)（MERGED・same-repo・head OID・保護枝・clean 照合、リモート削除は exact ref lease 付き。削除 push は既定 `SKIP_SIMPLE_GIT_HOOKS=1 HUSKY=0`、`FF_DELETE_PUSH_SKIP_HOOKS=0` のみ解除）。
- **switch なし掃除モード**: 呼び出し元が base でも PR head でもないブランチ（または detached の linked worktree）にいる場合、switch・pull せず `git fetch origin <base>:<base>` のみ試行し、リモート削除・`[gone]` 掃除・worktree 削除・トランスクリプト回収・取り残し検証を続行する（dirty でも中断しない）。
- **base / head が他 worktree に保持されている場合**: `finish.sh precheck` は `--delete-branch` を外し、`--repo` URL 固定で merge 後に ref を lease 削除して `HEAD_DELETE_RESULT` を別項目で報告する（[Git Workflow ステップ 8](../../docs-template/05-operations/deployment/git-workflow.md#ステップ8-マージmerge)）。他セッションの worktree は削除せず報告のみ。

## `--delete-branch` の部分失敗の読み方とリモート個別削除

**マージとリモートブランチ削除は別工程であり、そちらは成功していることがある**。判定は出力文言ではなく実測で行う:

1. `gh pr view <PR番号> --json state --jq .state` が `MERGED` であること
2. `git ls-remote --exit-code --heads origin '<head ブランチ>'` の終了コード（`2` = 削除済み、`0` = 残存、**それ以外の終了コードは「判定不能」で、削除済みと読んではいけない**）

<!--9aca91c4666f368d-->
MCP: 取得値: MCP で同じ PR の state / merged を fresh 取得。形式: PR JSON の MERGED / merged=true と Git の exact ref 実測。渡し先: この手順の merge と削除の別判定へ渡す。MCP merge の成功応答だけで削除完了にしない。不足時: 必須の MCP 能力 / 値が欠ければ操作名と項目を示して停止。

1・2 を満たせばローカル後始末は本スクリプトに任せる。ref が残る場合も `/merge-cleanup <PR番号>` を使う。対象 PR の head OID を照合し、同名 ref の再利用は保全、一致する場合だけ lease 付きで削除する。照合不能や削除未完了を成功とせず、サマリーの理由から復旧する。

## 終了コード・サマリーと拡張ポイント

| code | 意味 |
| --- | --- |
| 0 | 完全成功 |
| 1 | 致命的エラーで中断（引数/環境変数不正・未コミット変更・switch/pull/gh/`fetch --prune` 失敗・委譲前前提崩れ） |
| 2 | 一部失敗あり（PARTIAL。リモート削除失敗・直後の `fetch --prune` 失敗を含む） |

- 0 以外は失敗項目を報告し、勝手にリトライ・強制削除しない。サマリーの「対象 PR のリモートブランチ」を報告へ引用し、`skipped_oid_unavailable` 時は無条件の `git push origin --delete` を案内せず人間が OID 確認後に `--force-with-lease` で削除する。
- スキップ候補は `git ls-remote` と `git branch --list` で現物確認する。worktree 削除で `.gitignore` 対象（`.env` 等）も消える。`/retrospective`（および `/ace-curate`）の**前に**実行する。
- **任意フック**（repo root、実行権限なければ警告スキップ）: `.claude/hooks/pre-merge-cleanup.sh`（base 復帰前・失敗で中断）/ `.claude/hooks/post-branch-cleanup.sh`（`[gone]` 削除前、`BRANCH` / `WORKTREE_PATH` 渡し・失敗で当該ブランチをスキップ）/ `.claude/hooks/post-merge-cleanup.sh`（最終検証後・失敗は警告のみ）。
