---
name: ace-curate
description: マージ済み PR または指定資料から根拠付きの業務・開発知見を抽出し ACE Playbook（docs/08-knowledge/）へ構造化エントリとして追記する
---

# /ace-curate — ACE サイクル実行（Playbook 増分更新）

GitHub MCP の raw-file 入力は[共通契約](references/curate.md#github-file-input)に従う。

## ASDD 2.0 設定がある場合

最初に[共通設定契約](../asdd-init/references/configuration.md)を読み、`scripts/asdd/config.mjs` の `loadConfig(root)` で対象プロジェクトの `.asdd/config.json` を検証する。以下の従来手順より、合意済みの文書構成・機能スイッチ・ワークフローを優先する。設定なしは従来互換、不正設定は自動処理を止めて診断する。

`features.ace=false` のとき、ワークフローからの自動実行・Playbook作成・収集・整理を行わない。ユーザーがACEを明示依頼した場合は依頼範囲で実行するが、永続設定を勝手に変更しない。完了後の振り返りも `features.retrospective` が有効な場合だけ自動実行する。

知見を ACE Playbook へ追記する。固定手順は同梱 `scripts/finish.sh knowledge-commit`。全文は [references/curate.md](references/curate.md)。

**domainは通常curateの標準収集対象です。** 引数なし・PR番号のみでも他の知見と同時に評価し、opt-inを要求しません。根拠がある未確認知識もunverifiedで収集し、確認済みになるまで収集自体を待たせません。

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

`/knowledge-lookup` と同じ resolver で解く（規則: [curate.md](references/curate.md)）:

```bash
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/knowledge-lookup.sh" --resolve-playbook
```

`ACE_PLAYBOOK_STATE=ok` 以外は変更前に止めて報告する。以降の `docs/08-knowledge/` 配下は**既定配置の例**で、`ACE_PLAYBOOK_REL` が違えば置換する。

## 前提と引数

- PRはマージ済み、資料単独は `--source` と `--issue` の両方。`docs/08-knowledge/PLAYBOOK.md` が存在し、ブランチは `<default-branch>` / `chore/ace-from-*` または最新origin/defaultのdetached（[手順](references/curate.md#worktreeセッションからの知見記録)）。cleanup後に実行
- `$ARGUMENTS` — `[PR番号] [--source <資料パスまたはURL>]... [--issue <番号>]`。資料単独はsourceとissue必須。不正入力は変更前に拒否。資料は指定範囲のみ、取得失敗は未確認。domain正本: [ACE ドメイン知識契約](../../docs-template/05-operations/deployment/ace-domain.md)
- sourceはACE_ARGSの1要素にし `$ARGUMENTS` をevalしない。検証: `ace-curate-input.ts`（ACE_MODE / PR_NUMBER / ISSUE_NUMBER を出す。exit 2なら変更しない）:

```bash
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/ace-run-ts.sh" "${FF_DEV_TOOLKIT_ROOT}/docs-template/scripts/ace/ace-curate-input.ts" "${ACE_ARGS[@]}"
```

## 手順

### 1. 対象PRの特定

資料単独は `gh issue view <Issue番号>` で存在確認し PR 取得を省く。無指定なら `gh pr list --state merged --limit 20 --json number,title,url,mergedAt --jq 'sort_by(.mergedAt) | last'`、指定があれば `gh pr view "$PR_NUMBER" --json number,state,mergedAt` で state=MERGED を確認する。以降の値を一度だけ固定する: `ACE_ID_PREFIX="ACE-${PR_NUMBER}"` / `ACE_BRANCH="chore/ace-from-pr-${PR_NUMBER}"` / `ACE_ORIGIN="PR #${PR_NUMBER}"`（資料単独は `ACE-i${ISSUE_NUMBER}` / `chore/ace-from-issue-${ISSUE_NUMBER}` / `Issue #${ISSUE_NUMBER}`）。

<!--1b0bbdaa3ef899b7-->
MCP: 取得値: MCP の Issue number/url、merged PR number/title/url/mergedAt/state。形式: repo固定JSON、mergedAt順。渡し先: PR_NUMBER/ISSUE_NUMBER と ACE_ID_PREFIX/ACE_BRANCH/ACE_ORIGIN。不足時: MCP必須不足は停止。

### 2. Phase 1: Generate（知見抽出 — サブエージェント委譲が既定）

read-only の抽出用 subagent があれば [references/extract-prompt.md](references/extract-prompt.md) のテンプレートで委譲し、**知見候補の要約だけを親へ返す**（探索型は使わず、無ければ fallback へ）。応答が空・途中終了、5 項目や必須 3 欄を欠く場合は、その応答を成功として扱わず、下の fallback（メイン収集）で抽出をやり直します。domain確認の欠落・未実施もfallback対象です。domainが評価済みで必須欄が揃っている場合だけ「候補: 0 件」の明示報告は成功です。subagent が無いホストでは、従来どおりメインで対象PRの以下の情報を収集し、同じ 7 観点で知見候補を抽出します: `gh pr diff $PR_NUMBER` / `gh pr view $PR_NUMBER --json body,comments,reviews` / 関連 Issue と資料。fallbackでもdomain確認を必ず記録する。

<!--680ad0bced68c632-->
MCP: 取得値: MCP の PR diff/body/全comments/reviews と関連Issue本文。形式: diff text/JSON を scratch保存。渡し先: read-only 抽出者へ原文（write禁止、domain確認必須）。不足時: MCP必須不足は停止。

### 3. Phase 2: Reflect（評価・分類）

[保留候補の再評価](references/pending.md)を読む。解決済みPLAYBOOKと同階層の `PENDING_CANDIDATES.md` を確認し、新規PRの候補が0件でも保留を同じ新規性ゲートへ掛け直す。保留は採用済みACEとして扱わない。

**domainの判定を先行する**: コード/テストだけならunverified、正式資料か確認者の承認があればconfirmed、矛盾はconflictingと両側の根拠を記録し、既存仕様や既存ACEを自動deprecatedにしない。Distilled-Toは収集時には付けない。評価ゲート: 再現性・影響度が「中」以上か（低→スキップ）/ **新規性があるか？**（「**読者が取る実行可能なアクションが既存エントリと同一か**」。同一なら `Helpful` +1 のみ。domainは主体・条件・例外・確認状態が違えば同一としない）/ **抽象度の下限を満たすか？**（固有名なしで書けるなら 1 段上げてから新規性を判定。上げすぎたら棄却）/ **一回性のインシデント叙述は Playbook に書かない**（TROUBLESHOOTING / runbook へ）。

`FF_JEV_MODE=on` の候補は [triage](references/curate.md#triage) で先に選別する。`off` は従来経路・出力とバイト同一。照合: PLAYBOOK.md の索引で似たタイトルが**他カテゴリにもないか**を確認し、近縁カテゴリの `playbook/<category>.md` を読む。**重複** → `Helpful` +1 / **矛盾（非domain）** → 既存を `deprecated` にして新エントリ / **新規** → Phase 3。**Reuse 記録の反映**: PR body の「参照して役立った」既存 ACE ID があれば `Helpful` を +1（候補 0 件でも行う）。

### 4. Phase 3: Curate（増分更新）

#### 4-a. エントリIDの採番

**PRスコープ式** `ACE-<PR番号>-<連番>`（資料は `ACE-i<Issue番号>-<連番>`）。[採番規則](references/curate.md#エントリidの採番)を読む。

#### 4-b-0. 追記前にブロック上限の超過を予測する（必須・停止点）

`/ace-curate` は追加のみ。整理に必要な `/ace-refine` の承認必須は正しく、変えないため超える前に止める。

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

**rc を `|| true` で捨てない**。読むのは `<カテゴリ>: <件数>` と `ブロック上限: <N> 件/カテゴリ` の 2 行だけ（警告行を上限の取得元にしない — 読めなかった回が「超過なし」に化ける。`ブロック上限:` 行が無ければ停止）。追記先ごとに `現在の件数 + 今回の追記数` を求め、**ブロック上限を超えるなら追記せず、その時点で停止する**。停止時は超過するカテゴリと件数・**先に必要な refine の範囲**・承認後に `/ace-refine` → `/ace-curate` の順で実行することを提示する。**「フォローアップとして記録した」で完了にしない**。

通常の追記を止めたまま[保留候補の保存](references/pending.md)で全未処理候補を同じcommitへ含める。停止カテゴリ・予定総数・report実パス・rcをtool本文へ渡す。検査不成立では保存せず、全カテゴリ容量内は書かない。

#### 4-b. playbook/category.md への追記 + PLAYBOOK.md 索引の更新

[Changelog規則](references/curate.md#changelog-layout)に従う。

**共有値の確定前ガード**: [curate.md](references/curate.md) の clean tree → fetch → 祖先検査を通す（失敗は停止）。

[エントリの正準フォーマット](references/curate.md#エントリの正準フォーマット)に従う。メタ4行は各行の行頭に置く。

domainでは同梱契約の4行形式でEvidence / Verification / Distill-Toを必ず追記する。追記後、PLAYBOOK.md の索引にも 1 行加える — **列順はその PLAYBOOK の索引ヘッダ行から決める**（references/curate.md）。索引行はタイトルのみ。

#### 4-c / 4-d / 4-e. Frontmatter・Changelog・行数バジェット

[更新規則](references/curate.md#history-update-rules)に従う。`ace_entry_count` は merged tree の live エントリ実数から再計算。Helpful は 1 行 1 ID。行数例外は `ace-line-budget-exception` で明示する。

#### 4-f. 同期検証（必須）

プロジェクトのACE運用文書を優先し、無ければ[同期検証のfallback](references/curate.md#同期検証のfallback)を実行する。Frontmatter同期と `check-entry-format` を各1本、exit 0になるまで直す。同梱runnerは `ace-run-ts.sh`（不在はexit 3）、allowlistへ新規IDを足して通さない。

#### 4-g. 完了報告の契約（機械的検証が非 0 なら「停止」）

4-b-0 / 4-f の機械的検証が**非 0 を返したまま「完了」と報告しない**（4-e（行数バジェット）はこの列挙に入れない — 警告だけで終了コードを動かさない）。非 0 が残るなら報告は**停止**であり、どの検証が非 0 か・解消に必要な操作を名指しする（放置すると `live-ace-gates` が赤）。

容量停止と保存成功を分け、保存成功時は「保留 N 件（置き場の実パス）」を出す。追記が止まったまま通常curateの完了とは呼ばない。

### 5. コミット

**既定（推奨）— デフォルトブランチ直マージ**: 保護されていない default branch にのみ適用。**保護判定（必須・直 push を試す前に行う）**は `probe`。既存知見ブランチは PR 経由へ。判定・commitlint・保留合流は [references/curate.md](references/curate.md)。script での追記は [Markdown 文字列パッチ規律](../../docs-template/05-operations/deployment/markdown-patch-discipline.md)に従う。

MCP raw の利用時は下の各 knowledge-commit 呼出しに同じ `--github-input /absolute/index.json` を付ける（取得形と PLAN / read-back は [curate.md](references/curate.md#github-file-input)）。

```bash
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/check-shebang-cr.sh" || exit $?
commit_type="knowledge"
probe_out="$(FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/finish.sh" knowledge-commit probe)" || { echo "保護判定が成立しない（rc=$?）。停止" >&2; exit 1; }
case "$probe_out" in *"protection=protected"*) protected=1 ;; *) protected=0 ;; esac
ACE_KNOWLEDGE_PATHS=(docs/08-knowledge/PLAYBOOK.md)
. "${FF_DEV_TOOLKIT_ROOT}/scripts/lib/playbook-changelog-functions.sh" || exit 2
ACE_CHANGELOG_FILE="$(ff_playbook_changelog_select docs/08-knowledge/PLAYBOOK.md)" || { printf '%s\n' "$ACE_CHANGELOG_FILE" >&2; exit 2; }
ACE_CHANGELOG_REL="$(git -C "${ACE_CHANGELOG_FILE%/*}" rev-parse --show-prefix)${ACE_CHANGELOG_FILE##*/}" || exit 2
if [[ "$ACE_CHANGELOG_REL" != docs/08-knowledge/PLAYBOOK.md ]] && { ! git diff --quiet HEAD -- "$ACE_CHANGELOG_REL" || ! git ls-files --error-unmatch -- "$ACE_CHANGELOG_REL" >/dev/null 2>&1; }; then
  ACE_KNOWLEDGE_PATHS+=("$ACE_CHANGELOG_REL")
fi
while IFS= read -r kpath; do ACE_KNOWLEDGE_PATHS+=("$kpath"); done < <(git ls-files -mo --exclude-standard docs/08-knowledge/playbook)
if [ -f docs/08-knowledge/PENDING_CANDIDATES.md ]; then ACE_KNOWLEDGE_PATHS+=(docs/08-knowledge/PENDING_CANDIDATES.md); fi
ACE_CLAIM_ARGS=()
if ! git diff --quiet HEAD -- docs/08-knowledge/PLAYBOOK.md; then ACE_CLAIM_ARGS=(--claim docs/08-knowledge/PLAYBOOK.md); fi
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/finish.sh" knowledge-commit add ${ACE_CLAIM_ARGS[@]+"${ACE_CLAIM_ARGS[@]}"} --source ace --id "${ACE_ID}" --summary "${ACE_SUMMARY}" --category "<category[, category...]>" --type "${commit_type}" -- "${ACE_KNOWLEDGE_PATHS[@]}" || exit 1
ace_defer="${ACE_DEFER_TO_RETRO:-0}"   # 事前注入 hook が 1 を指示した回だけ add で止め /retrospective へ合流
if [[ "$ace_defer" == 1 ]]; then echo "commit と push は /retrospective の書き込みへ合流させます"; exit 0; fi
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/finish.sh" knowledge-commit commit --type "${commit_type}" || exit 1
current_branch="$(git branch --show-current)" || exit 1
if [[ "$current_branch" == chore/ace-from-* ]]; then ACE_BRANCH="$current_branch"; protected=1; fi
if [[ "$protected" == 1 ]]; then push_rc=3; else FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/finish.sh" knowledge-commit push; push_rc=$?; fi
case "$push_rc" in
  0) : ;;
  3) FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/finish.sh" knowledge-commit pr --branch "$ACE_BRANCH" --title "${commit_type}: ${ACE_ID} ${ACE_SUMMARY}" --body "${ACE_ORIGIN} から知見抽出" || exit 1 ;;  # 保護 → PR 経由
  *) echo "push 失敗（rc=${push_rc}。non-fast-forward なら references/curate.md の再試行へ）" >&2; exit 1 ;;
esac
```

`KNOWLEDGE_CI=` が未完了なら待ち、`failure` なら revert ではなく ACE コミットを前進で直して push し直す。**任意エスカレーション — chore PR**（**default branch が保護されている場合はこの経路が必須**）の新規ブランチは references/curate.md の fence で即 commit する。既存知見ブランチの保留は同じブランチで `/retrospective` へ渡す。`knowledge:` 付き PLAYBOOK 単独コミットの `<default-branch>` 直 push は意図的フローであり、直 push 禁止ルールとは別物。

### 6. 結果レポートと次のステップ

[結果レポート](references/curate.md#結果レポート)に従い、domain は評価済み（候補N件）/ 未実施（理由）、source の取得 / 未確認、登録 / push / CI を分けて報告する。ACE 完了後、ワークフローチェーンの末尾として `/retrospective` を実行する（`/merge-cleanup` → `/ace-curate` → `/retrospective`）。メタ知見は ACE Playbook ではなく `/retrospective` の提案経路で扱う。

## 注意事項

追記は**末尾のみ**、既存本文の書き換えは禁止（整理は `/ace-refine`）。Helpful/Harmful は**インクリメントのみ**。候補0でもReuse反映し、「知見なし」と報告。
