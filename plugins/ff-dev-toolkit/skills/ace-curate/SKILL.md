---
name: ace-curate
description: 原則から推論で導けない知見（A〜D の B/C）があるマージ済み PR または指定資料から根拠付き知見を抽出し ACE Playbook（docs/08-knowledge/）へ追記する
---

# /ace-curate — ACE サイクル実行（Playbook 増分更新）

GitHub MCP の raw-file 入力は[共通契約](references/curate.md#github-file-input)に従う。

## ASDD 2.0 設定がある場合

最初に[共通設定契約](../asdd-init/references/configuration.md)を読み、`scripts/asdd/config.mjs` の `loadConfig(root)` で `.asdd/config.json` を検証し、合意済みの構成・機能スイッチを優先する（設定なしは従来互換、不正設定は停止して診断）。`features.ace=false` では自動実行・Playbook 作成・収集を行わない（明示依頼は永続設定を変えず単発実行。振り返りは `features.retrospective` 有効時のみ）。

原則から推論で導けない知見（A〜D の B/C）がある PR のみ実行（既定チェーンは `/merge-cleanup` → `/retrospective`）。固定手順は `scripts/finish.sh knowledge-commit`、詳細は [references/curate.md](references/curate.md)。**domainは通常curateの標準収集対象です。** 根拠がある未確認知識も unverified で収集し、確認済みになるまで収集自体を待たせません。

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

## 配置先の解決（最初に実施）

```bash
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/knowledge-lookup.sh" --resolve-playbook --with-index-mode
```

`ACE_PLAYBOOK_STATE=ok` と [索引方式](references/curate.md#索引方式) を確認し、非 0・repo 外は変更前に停止する。

## 前提と引数

- マージ済み PR または資料単独（`--source` と `--issue` 必須）。cleanup 後に `<default-branch>` / `chore/ace-from-*` または最新 origin/default の detached HEAD で実行する（[手順](references/curate.md#worktreeセッションからの知見記録)、domain 正本: [ACE ドメイン知識契約](../../docs-template/05-operations/deployment/ace-domain.md)）
- `$ARGUMENTS` は `eval` せず `ACE_ARGS` 配列で `ace-curate-input.ts` へ渡して検証する（exit 2 は変更せず停止）:

```bash
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/ace-run-ts.sh" "${FF_DEV_TOOLKIT_ROOT}/docs-template/scripts/ace/ace-curate-input.ts" "${ACE_ARGS[@]}"
```

## 手順

### 1. 対象PRの特定

資料単独は `gh issue view <Issue番号>`、PR は無指定なら `gh pr list --state merged --limit 20 --json number,title,url,mergedAt --jq 'sort_by(.mergedAt) | last'`、指定ありなら `gh pr view "$PR_NUMBER" --json number,state,mergedAt` で `state=MERGED` を確認し、`ACE_ID_PREFIX` / `ACE_BRANCH` / `ACE_ORIGIN` を固定する（PR: `ACE-${PR_NUMBER}` / `chore/ace-from-pr-${PR_NUMBER}` / `PR #${PR_NUMBER}`、資料単独: `ACE-i${ISSUE_NUMBER}` / `chore/ace-from-issue-${ISSUE_NUMBER}` / `Issue #${ISSUE_NUMBER}`）。

<!--fc654007eb9eb55f-->
MCP: 取得値: MCP の Issue number/url、merged PR number/title/url/mergedAt/state。形式: repo固定JSON、mergedAt順。渡し先: PR_NUMBER/ISSUE_NUMBER と ACE_ID_PREFIX/ACE_BRANCH/ACE_ORIGIN。不足時: MCP必須不足は停止。

**編集前の保護判定（必須）**: Playbook 編集前に `probe` を実行し、protected は `ACE_BRANCH`、判定不能は detached HEAD へ移る（MCP raw は `--github-input` を付与）:

```bash
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/check-shebang-cr.sh" || exit $?
probe_out="$(FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/finish.sh" knowledge-commit probe)" || { echo "保護判定が成立しない（rc=$?）。停止" >&2; exit 1; }
echo "$probe_out"
start_branch="$(git branch --show-current)" || exit 1
if [[ "$start_branch" != chore/ace-from-* ]]; then
  case "$probe_out" in
    *"protection=unprotected"*) : ;;
    *"protection=protected"*) git switch -c "$ACE_BRANCH" || { echo "${ACE_BRANCH} を作れない（既存ならそのブランチで再実行。空なら削除）" >&2; exit 1; } ;;
    *) [[ -z "$start_branch" ]] || git switch --detach || exit 1 ;;
  esac
fi
```

### 2. Phase 1: Generate（知見抽出）

read-only の抽出用 subagent があれば [references/extract-prompt.md](references/extract-prompt.md) で委譲し要約のみ受ける（探索型は不使用）。応答が空・途中終了・必須欄欠落の場合はその応答を成功として扱わず、下の fallback（メイン収集）で抽出をやり直します。domain確認の欠落・未実施もfallback対象です。domainが評価済みで必須欄が揃っている場合だけ「候補: 0 件」の明示報告は成功です。subagent が無いホストでは、従来どおりメインで対象PRの以下の情報を収集し、同じ 7 観点で抽出する: `gh pr diff $PR_NUMBER` / `gh pr view $PR_NUMBER --json body,comments,reviews` / 関連 Issue・資料（fallbackでもdomain確認を必ず記録する）。

<!--d90c1de375daed24-->
MCP: 取得値: MCP の PR diff/body/全comments/reviews と関連Issue本文。形式: diff text/JSON を scratch保存。渡し先: read-only 抽出者へ原文（write禁止、domain確認必須）。不足時: MCP必須不足は停止。

### 3. Phase 2: Reflect（評価・分類）

- [保留候補の再評価](references/pending.md): 同階層の `PENDING_CANDIDATES.md` を確認し、新規PRの候補が0件でも保留を同じ新規性ゲートへ掛け直す（保留は採用済み ACE 扱いしない）。
- **domain 先行判定**: コード/テストのみは `unverified`、正式資料/承認は `confirmed`、矛盾は `conflicting`（両側根拠を記録、既存仕様や既存ACEを自動deprecatedにしない、Distilled-Toは収集時には付けない）。
- **評価ゲート**: **A〜D 判定**（[curate.md](references/curate.md#a-d-判定) — A/D は破棄理由つきで落とす、B は記録、C は仕組み強制＋1 行記録）／再現性・影響度中以上／新規性（読者の行動が同一なら `Helpful` +1 のみ）／抽象度下限／**一回性のインシデント叙述は Playbook に書かない**（TROUBLESHOOTING/runbookへ）。
- `FF_JEV_MODE=on` は [triage](references/curate.md#triage) を先行実行（`off` は従来同一）。[索引方式別の照合](references/curate.md#索引方式)で重複（`Helpful` +1）・非 domain 矛盾（既存 `deprecated`＋新規）・新規（Phase 3）に分け、PR 本文の Reuse 記録があれば候補 0 件でも `Helpful` +1 する。

### 4. Phase 3: Curate（増分更新）

#### 4-a. エントリIDの採番

`ACE-<PR番号>-<連番>`（資料単独は `ACE-i<Issue番号>-<連番>`、[採番規則](references/curate.md#エントリidの採番)）。

#### 4-b-0. 追記前にブロック上限の超過を予測する（必須・停止点）

`/ace-curate` は追加のみ（整理は `/ace-refine` の役割で承認必須は正しく、変えない）。超える前に止める:

```bash
# 閾値も件数の数え方も二重に持たない（正本は check-category-size）
if [ -f scripts/ace/check-category-size.ts ]; then
  SIZE_OUT="$(npx --yes tsx scripts/ace/check-category-size.ts docs/08-knowledge/PLAYBOOK.md 2>&1)"
  SIZE_RC=$?
else
  SIZE_OUT="$(FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/ace-run-ts.sh" \
    "${FF_DEV_TOOLKIT_ROOT}/docs-template/scripts/ace/check-category-size.ts" docs/08-knowledge/PLAYBOOK.md 2>&1)"
  SIZE_RC=$?
fi
ACE_CAPACITY_REPORT="$(mktemp "${TMPDIR:-/tmp}/ace-capacity.XXXXXX")" || exit 1
printf '%s\n' "${SIZE_OUT}" | tee "${ACE_CAPACITY_REPORT}" || exit 1
printf 'ACE_CAPACITY_REPORT=%s\nACE_CAPACITY_RC=%s\n' "${ACE_CAPACITY_REPORT}" "${SIZE_RC}"
case "${SIZE_RC}" in
  0) ;;
  1) printf '%s\n' "${SIZE_OUT}" >&2; echo "ブロック上限を超過済み。追記せず停止" >&2; exit 1 ;;
  *) printf '%s\n' "${SIZE_OUT}" >&2; echo "件数ゲート不成立（rc=${SIZE_RC}）。超過なしと読み替えず停止" >&2; exit 1 ;;
esac
```

**rc を `|| true` で捨てない**。読むのは `<カテゴリ>: <件数>` と `ブロック上限: <N> 件/カテゴリ` の 2 行のみ（警告行を上限の取得元にしない — 読めなかった回が「超過なし」に化ける。`ブロック上限:` 不在なら停止）。`現在の件数 + 今回の追記数` が**ブロック上限を超えるなら追記せず、その時点で停止する**（超過カテゴリ・件数・**先に必要な refine の範囲**・`/ace-refine` → `/ace-curate` の順を提示。**「フォローアップとして記録した」で完了にしない**）。

通常の追記を止めたまま[保留候補の保存](references/pending.md)で全未処理候補を同じ commit へ含める（検査不成立では保存せず、全カテゴリ容量内は書かない）。

#### 4-b. playbook/category.md への追記 + PLAYBOOK.md 索引の更新

確定前ガード（clean tree → fetch → 祖先検査）、[Changelog規則](references/curate.md#changelog-layout)、[正準フォーマット](references/curate.md#エントリの正準フォーマット)（メタ 4 行は行頭、domain は Evidence / Verification / Distill-To 必須）、[索引方式](references/curate.md#索引方式)（索引行はタイトルのみ）、[更新規則](references/curate.md#history-update-rules)（`ace_entry_count` は merged tree の live エントリ実数から再計算、Helpful は 1 行 1 ID、行数例外は `ace-line-budget-exception`、frontmatter は保存後導出）に従う。

#### 4-f. 同期検証（必須）

プロジェクトの ACE 運用文書または[同期検証のfallback](references/curate.md#同期検証のfallback)で Frontmatter 同期と `check-entry-format` を各 1 本実行し exit 0 まで直す（同梱 runner は `ace-run-ts.sh`・不在は exit 3、allowlist への新規 ID 追加禁止）。

#### 4-g. 完了報告の契約（機械的検証が非 0 なら「停止」）

4-b-0 / 4-f の機械的検証が**非 0 を返したまま「完了」と報告しない**（4-e（行数バジェット）はこの列挙に入れない）。非 0 が残るなら報告は**停止**であり、該当検証と解消手順を名指しする（放置すると `live-ace-gates` が赤）。容量停止と保留保存成功（「保留 N 件（置き場の実パス）」）は分け、追記停止を通常 curate 完了と呼ばない。

### 5. コミット

**既定（推奨）— デフォルトブランチ直マージ**: 保護されていない default branch にのみ適用。**保護判定（必須・直 push を試す前に行う）**は手順 1 の `probe` で済ませ、現在ブランチで分岐する（MCP raw は `--github-input /absolute/index.json`、script 追記は [Markdown 文字列パッチ規律](../../docs-template/05-operations/deployment/markdown-patch-discipline.md)）。

```bash
commit_type="knowledge"
if [[ "$ACE_MODE" == sources ]]; then origin=(--issue "${ISSUE_NUMBER:?}"); else origin=(--pr "${PR_NUMBER:?}"); fi
protected=0   # 保護判定は手順 1 で済み、保護時は知見ブランチ上にいる
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/finish.sh" knowledge-commit add --ace-playbook docs/08-knowledge/PLAYBOOK.md --source ace --id "${ACE_ID}" --summary "${ACE_SUMMARY}" ${origin[@]+"${origin[@]}"} --category "<category[, category...]>" --type "${commit_type}" || exit 1
ace_defer="${ACE_DEFER_TO_RETRO:-0}"   # 1 を明示した回だけ add で止め /retrospective へ合流
if [[ "$ace_defer" == 1 ]]; then echo "commit と push は /retrospective の書き込みへ合流させます"; exit 0; fi
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/finish.sh" knowledge-commit commit --type "${commit_type}" ${origin[@]+"${origin[@]}"} || exit 1
current_branch="$(git branch --show-current)" || exit 1
if [[ "$current_branch" == chore/ace-from-* ]]; then ACE_BRANCH="$current_branch"; protected=1; fi
if [[ "$protected" == 1 ]]; then push_rc=3; else FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/finish.sh" knowledge-commit push; push_rc=$?; fi
case "$push_rc" in
  0) : ;;
  3) [[ -n "$current_branch" ]] || git switch -c "$ACE_BRANCH" || exit 1
     FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/finish.sh" knowledge-commit pr --branch "$ACE_BRANCH" --title "${commit_type}: ${ACE_ID} ${ACE_SUMMARY}" --body "${ACE_ORIGIN} から知見抽出" || exit 1 ;;  # 保護 → PR 経由
  *) echo "push 失敗（rc=${push_rc}。non-fast-forward なら references/curate.md の再試行へ）" >&2; exit 1 ;;
esac
```

`KNOWLEDGE_CI=` が未完了なら待ち、`failure` なら revert ではなく ACE コミットを前進で直して push し直す。**任意エスカレーション — chore PR**（**default branch が保護されている場合はこの経路が必須**）は [references/curate.md](references/curate.md) に従う。`knowledge:` 付き PLAYBOOK 単独コミットの `<default-branch>` 直 push は意図的フローであり、直 push 禁止とは別物。

### 6. 結果レポートと注意事項

- [結果レポート](references/curate.md#結果レポート)に従い、domain は評価済み（候補N件）/ 未実施（理由）、A/D 破棄理由、source・push・CI を報告する。既定チェーンは `/merge-cleanup` → `/retrospective`（B/C 候補がある PR だけ挟む）。実行後は `/retrospective` へ進む。
- 追記は**末尾のみ**（既存書換え禁止、整理は `/ace-refine`）。Helpful / Harmful は増分のみ。候補 0 でも Reuse 反映し「知見なし」と報告。メタ知見は ACE Playbook ではなく `/retrospective` の提案経路で扱う。
