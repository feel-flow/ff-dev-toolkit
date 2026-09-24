---
name: ace-curate
description: マージ済み PR または指定資料から根拠付きの業務・開発知見を抽出し ACE Playbook（docs/08-knowledge/）へ構造化エントリとして追記する
---

# /ace-curate — ACE サイクル実行（Playbook 増分更新）

## ASDD 2.0 設定がある場合

最初に[共通設定契約](../asdd-init/references/configuration.md)を読み、`scripts/asdd/config.mjs` の `loadConfig(root)` で対象プロジェクトの `.asdd/config.json` を検証する。以下の従来手順より、合意済みの文書構成・機能スイッチ・ワークフローを優先する。設定なしは従来互換、不正設定は自動処理を止めて診断する。

`features.ace=false` のとき、ワークフローからの自動実行・Playbook作成・収集・整理を行わない。ユーザーがACEを明示依頼した場合は依頼範囲で実行するが、永続設定を勝手に変更しない。完了後の振り返りも `features.retrospective` が有効な場合だけ自動実行する。

マージ後・cleanup 後に PR から知見を抽出し ACE Playbook へ追記する。判断は本文が持ち、固定手順（claim・stage・commit・保護判定・push・PR 経由）は同梱 `scripts/finish.sh knowledge-commit` が実行する。規則の全文は [references/curate.md](references/curate.md)。

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

既存の ACE 配置記録と `ACE_PLAYBOOK_PATH` から実在する PLAYBOOK を解決する（規則は [references/curate.md](references/curate.md)「配置先の解決」）。以降の `docs/08-knowledge/PLAYBOOK.md`、`docs/08-knowledge/playbook/` は**既定配置の例**で、独自配置では全パスを実配置へ置換してから実行する。

## 前提と引数

- PR経路はマージ済みの PR、資料単独経路は `--source` と `--issue` の両方。`docs/08-knowledge/PLAYBOOK.md` が存在し、現在のブランチが `<default-branch>` または `chore/ace-from-*`。実行はマージ後・cleanup 後
- `$ARGUMENTS` — `[PR番号] [--source <資料パスまたはURL>]... [--issue <番号>]`。無指定なら最新マージ済みPR。資料単独はsourceとissueが必須。不正な入力は変更前に拒否し、資料は明示指定範囲だけを読み、取得失敗は未確認として報告する。ドメイン知識の正本は [ACE ドメイン知識契約](../../docs-template/05-operations/deployment/ace-domain.md)
- sourceは1要素のままACE_ARGS配列へ設定し `$ARGUMENTS` をevalしない。入力検証は同梱 `ace-curate-input.ts`（ACE_MODE / PR_NUMBER / ISSUE_NUMBER を出す。exit 2なら変更しない）:

```bash
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/ace-run-ts.sh" "${FF_DEV_TOOLKIT_ROOT}/docs-template/scripts/ace/ace-curate-input.ts" "${ACE_ARGS[@]}"
```

## 手順

### 1. 対象PRの特定

資料単独は `gh issue view <Issue番号>` で存在確認し PR 取得を省く。無指定なら `gh pr list --state merged --limit 20 --json number,title,url,mergedAt --jq 'sort_by(.mergedAt) | last'`、指定があれば `gh pr view "$PR_NUMBER" --json number,state,mergedAt` で state=MERGED を確認する。以降の値を一度だけ固定する: `ACE_ID_PREFIX="ACE-${PR_NUMBER}"` / `ACE_BRANCH="chore/ace-from-pr-${PR_NUMBER}"` / `ACE_ORIGIN="PR #${PR_NUMBER}"`（資料単独は `ACE-i${ISSUE_NUMBER}` / `chore/ace-from-issue-${ISSUE_NUMBER}` / `Issue #${ISSUE_NUMBER}`）。

### 2. Phase 1: Generate（知見抽出 — サブエージェント委譲が既定）

read-only の抽出用 subagent があれば [references/extract-prompt.md](references/extract-prompt.md) のテンプレートで委譲し、**知見候補の要約だけを親へ返す**（探索型は使わず、無ければ fallback へ）。応答が空・途中終了、5 項目や必須 3 欄を欠く場合は、その応答を成功として扱わず、下の fallback（メイン収集）で抽出をやり直します。domain確認の欠落・未実施もfallback対象です。domainが評価済みで必須欄が揃っている場合だけ「候補: 0 件」の明示報告は成功です。subagent が無いホストでは、従来どおりメインで対象PRの以下の情報を収集し、同じ 7 観点で知見候補を抽出します: `gh pr diff $PR_NUMBER` / `gh pr view $PR_NUMBER --json body,comments,reviews` / 関連 Issue と資料。fallbackでもdomain確認を必ず記録する。

### 3. Phase 2: Reflect（評価・分類）

**domainの判定を先行する**: コード/テストだけならunverified、正式資料か確認者の承認があればconfirmed、矛盾はconflictingと両側の根拠を記録し、既存仕様や既存ACEを自動deprecatedにしない。Distilled-Toは収集時には付けない。評価ゲート: 再現性・影響度が「中」以上か（低→スキップ）/ **新規性があるか？**（「**読者が取る実行可能なアクションが既存エントリと同一か**」。同一なら `Helpful` +1 のみ。domainは主体・条件・例外・確認状態が違えば同一としない）/ **抽象度の下限を満たすか？**（固有名なしで書けるなら 1 段上げてから新規性を判定。上げすぎたら棄却）/ **一回性のインシデント叙述は Playbook に書かない**（TROUBLESHOOTING / runbook へ）。

`FF_JEV_MODE=on` のときだけ新規性バーを Jev（`scripts/jev/jev-decide.sh novelty`）へ先に投げてよい。照合: PLAYBOOK.md の索引で似たタイトルが**他カテゴリにもないか**を確認し、近縁カテゴリの `playbook/<category>.md` を読む。**重複** → `Helpful` +1 / **矛盾（非domain）** → 既存を `deprecated` にして新エントリ / **新規** → Phase 3。**Reuse 記録の反映**: PR body の「参照して役立った」既存 ACE ID があれば `Helpful` を +1（候補 0 件でも行う）。

### 4. Phase 3: Curate（増分更新）

#### 4-a. エントリIDの採番

**PRスコープ式** `ACE-<PR番号>-<連番>`（資料単独は `ACE-i<Issue番号>-<連番>`）。既存 `ACE_ID_PREFIX-*` の最大連番 +1（無ければ `1`）。PLAYBOOK.md に「エントリID規則」節が無ければ同梱テンプレートから節ごとコピーする。既存の ID なし・旧連番エントリは改名しない。

#### 4-b-0. 追記前にブロック上限の超過を予測する（必須・停止点）

curate は増やす操作しか持たず、ブロックゲート（`check-category-size` の exit 1）に当たっても自分では直せない（`/ace-refine` の承認必須は正しく、変えない）。したがって**超える前に止める** — この節が 4-b より前にあること自体が停止点。

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
case "${SIZE_RC}" in
  0) ;;
  1) printf '%s\n' "${SIZE_OUT}" >&2; echo "ブロック上限を超過済み。追記せず停止" >&2; exit 1 ;;
  *) printf '%s\n' "${SIZE_OUT}" >&2; echo "件数ゲート不成立（rc=${SIZE_RC}）。超過なしと読み替えず停止" >&2; exit 1 ;;
esac
```

**rc を `|| true` で捨てない**。読むのは `<カテゴリ>: <件数>` と `ブロック上限: <N> 件/カテゴリ` の 2 行だけ（警告行を上限の取得元にしない — 読めなかった回が「超過なし」に化ける。`ブロック上限:` 行が無ければ停止）。追記先ごとに `現在の件数 + 今回の追記数` を求め、**ブロック上限を超えるなら追記せず、その時点で停止する**。停止時は超過するカテゴリと件数・**先に必要な refine の範囲**・承認後に `/ace-refine` → `/ace-curate` の順で実行することを提示する。**「フォローアップとして記録した」で完了にしない**。

#### 4-b. playbook/category.md への追記 + PLAYBOOK.md 索引の更新

**共有値の確定前ガード**: `version` / `ace_entry_count` / Changelog は着手時のローカル値から決めず、references/curate.md のフェンス（clean tree → fetch → 祖先検査。失敗は停止）を通す。エントリ本体は `playbook/<category>.md` 末尾へ**コンパクト正準フォーマット**で追記する（メタ 4 行は各行の行頭 — パーサ互換条件）:

```markdown
<a id="ace-XXX"></a>

### ACE-XXX: [検索可能な主張 1 文のタイトル]

| Category | [カテゴリ] | Origin | PR #[PR番号] |
| Date | [今日の日付] |
| Helpful | 0 | Harmful | 0 |
| Status | active |

[本文 2〜4 文。1 文目 = 知見の本質。非自明な適用条件が 1 文。推奨アクションで締める。手順の列挙・叙述は書かない]

---
```

domainでは同梱契約の4行形式でEvidence / Verification / Distill-Toを必ず追記する。追記後、PLAYBOOK.md の索引にも 1 行加える — **列順はその PLAYBOOK の索引ヘッダ行から決める**（references/curate.md）。索引行はタイトルのみ。

#### 4-c / 4-d / 4-e. Frontmatter・Changelog・行数バジェット

`version` は新規エントリ追加で **minor +1**（カウンター更新のみは不変）、`updated` を今日へ、`changeImpact` は `medium`。`ace_entry_count` は merged tree の live エントリ実数から再計算する。Changelog は `## Changelog` 先頭へ当該版のブロック（version を上げたのに Changelog が空、を禁止）。各エントリのブロック行数は **15 行以内**（`<!-- ace-line-budget-exception: 理由 -->` 付きでも **30 行以内**）を自分で数える。

#### 4-f. 同期検証（必須）

SSOT はプロジェクトの ACE 運用文書（例 `docs/05-operations/deployment/ace-cycle.md`）で、以下は無い場合の fallback。同期検証・形式ゲートそれぞれ、**プロジェクトの状態に合う 1 本だけを実行する**:

```bash
# 同期検証 — 1 本だけ: (1) npm script 登録済み / (2) scripts/ace/ あり / (3) 無ければ同梱
npm run ace:check-playbook-frontmatter
npx --yes tsx scripts/ace/sync-playbook-frontmatter.ts docs/08-knowledge/PLAYBOOK.md --check
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/ace-run-ts.sh" "${FF_DEV_TOOLKIT_ROOT}/docs-template/scripts/ace/sync-playbook-frontmatter.ts" docs/08-knowledge/PLAYBOOK.md --check

# 形式ゲート（旧テーブル形式でないこと）— 1 本だけ: (1) scripts/ace/ あり / (2) 無ければ同梱
npx --yes tsx scripts/ace/check-entry-format.ts docs/08-knowledge/PLAYBOOK.md
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/ace-run-ts.sh" "${FF_DEV_TOOLKIT_ROOT}/docs-template/scripts/ace/check-entry-format.ts" docs/08-knowledge/PLAYBOOK.md
```

同梱を叩く経路で `npx --yes tsx` を直接書かない（`ace-run-ts.sh` は runner が無ければ **exit 3 で停止**）。exit 0 になるまで直す（形式ゲートが赤なら正準フォーマットへ。allowlist に新規 ID を足さない）。

#### 4-g. 完了報告の契約（機械的検証が非 0 なら「停止」）

4-b-0 / 4-f の機械的検証が**非 0 を返したまま「完了」と報告しない**（4-e（行数バジェット）はこの列挙に入れない — 警告だけで終了コードを動かさない）。非 0 が残るなら報告は**停止**であり、どの検証が非 0 か・解消に必要な操作を名指しする（放置すると default ブランチの `live-ace-gates` が赤になる）。

### 5. コミット

**既定（推奨）— デフォルトブランチ直マージ**: 保護されていない default branch にのみ適用。**保護判定（必須・直 push を試す前に行う）**は `probe`: `protected` → PR 経由 / `unprotected` → 直 push / `unknown` → 既定を試す（拒否は rc 3 で PR 経由へ）。commitlint（`header-max-length`・type 許容リスト）で `knowledge` が非許容なら prefix だけを置き換える。全文は [references/curate.md](references/curate.md)。追記を script で当てるなら [Markdown 文字列パッチ規律](../../docs-template/05-operations/deployment/markdown-patch-discipline.md)に従う。

```bash
commit_type="knowledge"   # commitlint で knowledge が非許容なら chore 等へ（要約・Categories: body は不変）
probe_out="$(FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/finish.sh" knowledge-commit probe)" || { echo "保護判定が成立しない（rc=$?）。停止" >&2; exit 1; }
case "$probe_out" in *"protection=protected"*) protected=1 ;; *) protected=0 ;; esac
# --claim: claim を再生成して同じ commit へ入れる
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/finish.sh" knowledge-commit add --claim docs/08-knowledge/PLAYBOOK.md --source ace --id "${ACE_ID}" --summary "${ACE_SUMMARY}" --category "<category[, category...]>" --type "${commit_type}" -- docs/08-knowledge/PLAYBOOK.md docs/08-knowledge/playbook/*.md || exit 1
ace_defer="${ACE_DEFER_TO_RETRO:-0}"   # 事前注入 hook が 1 を指示した回だけ add で止め /retrospective へ合流
if [[ "$ace_defer" == 1 ]]; then echo "commit と push は /retrospective の書き込みへ合流させます"; exit 0; fi
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/finish.sh" knowledge-commit commit --type "${commit_type}" || exit 1
if [[ "$protected" == 1 ]]; then push_rc=3; else FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/finish.sh" knowledge-commit push; push_rc=$?; fi
case "$push_rc" in
  0) : ;;
  3) FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/finish.sh" knowledge-commit pr --branch "$ACE_BRANCH" --title "${commit_type}: ${ACE_ID} ${ACE_SUMMARY}" --body "${ACE_ORIGIN} から知見抽出" || exit 1 ;;  # 保護 → PR 経由
  *) echo "push 失敗（rc=${push_rc}。non-fast-forward なら references/curate.md の再試行へ）" >&2; exit 1 ;;
esac
```

`KNOWLEDGE_CI=` が未完了なら待ち、`failure` なら revert ではなく ACE コミットを前進で直して push し直す。**任意エスカレーション — chore PR**（**default branch が保護されている場合はこの経路が必須**）は references/curate.md の fence（`git checkout -b "$ACE_BRANCH"` → 同じ `add --claim` → `commit` → `knowledge-commit pr`。`/retrospective` へ合流させない）。`knowledge:` 付き PLAYBOOK 単独コミットの `<default-branch>` 直 push は意図的フローであり、直 push 禁止ルールとは別物。

### 6. 結果レポートと次のステップ

```
## ACE サイクル完了レポート
**対象PR**: #[PR番号] [タイトル] / **抽出知見数**: X 件 / **新規**: ACE-438-1 / **カウンター更新**: ACE-016 (Helpful +1) / **スキップ**: X 件
**domain**: 評価済み（候補N件）または未実施（理由）/ source の取得済み・未確認 / 反映先未解決
**登録・push・CI**: 別々に報告する
```

**次のステップ**: ACE 完了後、ワークフローチェーンの末尾として `/retrospective` を実行する（`/merge-cleanup` → `/ace-curate` → `/retrospective`）。プロセス/ツール/スキルのメタ知見は ACE Playbook ではなく `/retrospective` の提案経路で扱う。

## 注意事項

追記は**末尾のみ**、既存本文の書き換えは禁止（要約・アーカイブ・統合は `/ace-refine`）。Helpful/Harmful は**インクリメントのみ**。知見が無ければ「知見なし」と報告して終了（Reuse 記録の反映は候補 0 件でも実施）。
