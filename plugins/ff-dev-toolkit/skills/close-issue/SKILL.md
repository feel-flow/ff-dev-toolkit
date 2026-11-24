---
name: close-issue
description: PR のマージ前に Issue の AC を照合し、チェックボックスと報告を更新する。
---

# /close-issue — Issue クローズ前の AC 照合ゲート

## ASDD 2.0 設定がある場合

最初に[共通設定契約](../asdd-init/references/configuration.md)を読み、`scripts/asdd/config.mjs` の `loadConfig(root)` で `.asdd/config.json` を検証し、合意済みの確認方法のみ適用する（未設定は従来互換、不正設定は停止して診断。無効にした ACE・振り返り・複数 AI レビューはチェーンへ足さない）。

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

`$ARGUMENTS` は PR 番号（省略時は `gh pr view --json number` で検出）。Issue 番号のみの検証完了 close は [prless-close.md](references/prless-close.md) へ。

<!--9d783baf15ce896a-->
MCP: 取得値: MCPでPR number/headRefName。形式: 一意の PR JSON。渡し先: PR_NUMBER → precheck argv。不足時: MCP 必須不足は停止。

## 手順

未チェックなら precheck は 1 回で止まる。その EFFORT 行でチェックと実績を 1 回編集し再実行。

### 1. 固定手順の実行（precheck）

`gh` 不在・認証失敗時は MCP raw を[file 入力](references/merge-gate.md#github-file-input)へ保存し、`--subject "$MERGE_SUBJECT" --body "$MERGE_BODY" --github-input /absolute/index.json` を追加する（必須能力不足は停止、Refs 2a/2b・snapshot・鮮度を維持）。

<!--981b8a521c4cb4e4-->
MCP: 取得値: MCPでPR/repo/checks/threads raw。形式: phase/attempt/cursor 付き index JSON。渡し先: precheck --github-input（subject/body も保持）。不足時: MCP 必須不足は停止。

```bash
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/check-shebang-cr.sh" || exit $?
PR_NUMBER="${PR_NUMBER:?PR 番号を先に設定すること}"
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/finish.sh" precheck "${PR_NUMBER}"
```

rc **0 = 続行または対象なし** / **1 = 停止** / **2 = 判定不能**。出力の要点:

- **ブランチガード（必須）**: `git branch --show-current` ≠ `PR_HEAD_REF` なら `gh pr checkout $PR_NUMBER` で切り替えて続行（不可なら停止）。
- `CLOSES` は `closingIssuesReferences` ∪ 本文の closing keyword（API は PR 本文だけを見る。空を理由に打ち切ると Refs が無検査になる）。`REFS` の拾う綴りは `Ref` / `Refs` のみ（`gh issue` には URL を渡す）。`CLOSES_TEXT_ONLY=` は AC 対象外（[merge-gate.md](references/merge-gate.md)）。
- 両群空で `#N` 候補ありは `PRECHECK=blocked`（PR 本文へ `Refs #N` / `Closes #N` 追記して再実行）。候補なしの `PRECHECK=no-target` は「参照から検出できる対象 Issue はありません」と報告して終了。
- `AUTO_CLOSE_UNRELIABLE=1` も照合し手順 8 で手動クローズを案内。複数 Issue・`bundle` は sub-issue 全件へ手順 3〜6 を実行し、子と bundle が本文の `Closes` か `Refs`（印）に全部並ぶかを見る（[merge-gate.md](references/merge-gate.md)）。

<!--fa8253116ea3ab3b-->
MCP: 取得値: MCPでheadRefName/headRefOid と全 sub_issues。形式: PR JSON / 全 page 配列。渡し先: Git fetch/checkout の OID照合と全子のAC/参照照合。不足時: MCP 必須不足は停止。

### 2. closing keyword 抵触検査（Refs 運用の Issue がある場合）

squash commit メッセージも 9 語（`close`/`closes`/`closed`/`fix`/`fixes`/`fixed`/`resolve`/`resolves`/`resolved`、`fix:` のようにコロンが挟まる形も一致します）で走査する（実体: `scripts/check-closing-keywords.sh`、[merge-gate.md](references/merge-gate.md)）。

| | 対象 | 出力 | 位置づけ |
| --- | --- | --- | --- |
| **2a** | PR タイトル + 全コミットの件名と本文 | `KEYWORD_GATE=ok / conflict-title / conflict-commit`、`KEYWORD_INSPECTED`（報告へ転記） | 供給源スキャン |
| **2b** | 実際に `gh pr merge` へ渡す `--subject` と `--body` | `MERGE_MESSAGE_GATE=ok / conflict / required` | **マージ条件** |

<!--eed9ef3e25198f1a-->
MCP: 取得値: MCPで最終 headRefOid と subject/body 原文。形式: merge_pull_request の6引数。渡し先: 手順7のMCP merge（Refs 2a/2b保持）。不足時: MCP 必須不足は停止。

- `conflict-title`: `gh pr edit "${PR_NUMBER}" --title "<Issue 参照なし件名>"` で改題し手順 1 から再実行。
- `conflict-commit` / Refs 運用既定: `KEYWORD_SUGGEST` を参考に `--subject "<件名 (#PR)>" --body "Refs #${REFS_ISSUE}（open 維持の理由）"` で 2b を通し、`MERGE_COMMAND` を打ち直さず手順 7 へ持ち越す（Refs 0 件なら省略）。

<!--48671cc526a3b596-->
MCP: 取得値: MCPでPR title/headRefOid。形式: 新 title 原文の構造化引数。渡し先: update_pull_request → fresh後読 → precheck。不足時: MCP 必須不足は停止。

- **2c（未返信スレッド）**: `REVIEW_THREADS_UNANSWERED` ≥ 1 は `PRECHECK=blocked`（rc 1）。各スレッドへ判定（直す / follow-up 番号 / 退ける理由）を返信し手順 1 へ戻る（取得失敗は rc 2。[merge-gate.md](references/merge-gate.md)）。

### 3. AC 照合（判断）

`gh issue view "$ISSUE_URL" --json title,body`・`gh pr diff "$PR_NUMBER"`・`gh pr view "$PR_NUMBER" --json body,statusCheckRollup,reviewDecision` を突き合わせる。**Issue 本文は全文取得する**（[AC 照合](references/ac-judgement.md)）。

<!--270e2219bcb22d68-->
MCP: 取得値: MCPでIssue title/body と PR diff/rollup/reviewDecision。形式: 全文 JSON / diff text。渡し先: AC の対象と実行結果の照合。不足時: MCP 必須不足は停止。

- **根拠は AC の指す対象を測っているか**: AC ごとに「根拠が測った対象 = AC が指す対象」を 1 行で書く。「測れない」= 未達（他 AC の達成数で埋めない）。bug 原因未確定なら「原因未確定。次回読めるようにする計測を入れた / 入れていない」を報告する。
- 「未達」と「AC が実装より古い」を区別する。AC なしは手順 6 へ。
- **未達解消（手順 4）**: 未達は実装・検証・fix commit push → 手順 1 へ戻る。**現 Issue の AC はスコープ外発見ではない**（別 Issue 移管禁止。仕様変更が必要な場合のみ停止。独立発見は[三分岐](../../docs-template/05-operations/deployment/workflow-principles.md)へ）。

### 5. Issue 本文の更新（チェックボックス + 工数実績）

本文は**この 1 回にまとめる**（例外は 5b）。

#### 5a. 工数実績の算出（`ff-effort` ブロックがある場合）

ブロックが無い Issue ではブロックを新設せずスキップ（マージは止めない）。報告は「工数記録: ブロック不在のためスキップ」。存在時は[規則](references/effort.md)に従い `EFFORT_<Issue番号>_*` を並記（`(unmeasured)` は 0 にしない）。

#### 5b. 本文の書き換えと送信

[Markdown 文字列パッチ規律](../../docs-template/05-operations/deployment/markdown-patch-discipline.md)に従い達成 AC のみ個別に `- [ ]` → `- [x]`（`☑` 不可）、初回のみ私有領域 W を確保し後続は実値明示:

```bash
: "${W:?記録済みWの実値を明示}"
[ -d "$W" ] && [ ! -L "$W" ] || exit 2
gh issue view "$ISSUE_URL" --json body,updatedAt   # body 全文と時刻を W の .orig.md / 編集 .md へ（書き換えも W）
# 達成行だけ個別に "- [ ]" → "- [x]"（一括禁止）
JUDGE="${FF_DEV_TOOLKIT_ROOT:?プラグインルートを先に解決すること}/scripts/check-issue-body-diff.sh"
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "$JUDGE" "$W/issue-body-${ISSUE_NUMBER}.orig.md" "$W/issue-body-${ISSUE_NUMBER}.md"
case $? in
  0) : ;;
  1) echo "✗ 許可範囲外。送信しない" >&2; exit 1 ;;
  2) echo "✗ 検査不成立。送信しない" >&2; exit 2 ;;
  *) echo "✗ 上記以外 = 判定器未起動。送信しない" >&2; exit 2 ;;
esac
# 直前の fresh updatedAt が同じ場合だけ送信。変化なら再取得から
gh issue edit "$ISSUE_URL" --body-file "$W/issue-body-${ISSUE_NUMBER}.md"
```

<!--4012219f76dd63c0-->
MCP: 取得値: MCPでIssue body/updatedAt（REST updated_at）。形式: 原本 .orig.md / 編集 .md。渡し先: 許可差分・直前時刻照合後 update_issue.body → fresh一致。不足時: MCP 必須不足は停止。

更新するのはチェックボックスと `ff-effort` のみ（例外は手順 3 の「AC が実装より古い」と手順 4 のスコープ変更。チェックと工数の後の[2 回目で送る](references/ac-judgement.md#second-send)）。対象外・post-merge 検証待ちはチェックしない。

### 6. 完了報告コメントの投稿

**日本語**で `--body-file` 投稿する（`<!-- close-issue-report:PR-<PR番号> -->` があれば更新、5b の W の実値を再利用し固定名再構築・mktemp も再実行しない）:

```bash
: "${W:?記録済みWの実値を明示}"
[ -d "$W" ] && [ ! -L "$W" ] || exit 2
gh issue comment "$ISSUE_URL" --body-file "$W/close-issue-report-${ISSUE_NUMBER}.md"
```

<!--1c37202f4ab93c34-->
MCP: 取得値: MCPで全 comments id/body と report marker。形式: 全 page JSON / 報告ファイル原文。渡し先: 一意IDは update_issue_comment、無ければ add_comment_to_issue → fresh一致。不足時: MCP 必須不足は停止。

[テンプレート](references/report.md)に各 AC の `測った対象: [AC が指す対象]` と根拠を書く（主要コミット: <手順 1 の PR_COMMITS をそのまま貼る>）。主要コミット欄は `PR_COMMITS` の行を貼り、**自分で hash を書かない**（`KEYWORD_INSPECTED` と同じ。`PR_COMMITS_SOURCE` が `git` 以外なら併記、帯外は乖離原因を記載）。

### 7. ゲート実測鮮度の照合（マージ直前）

**マージ直前に `finish.sh precheck` を再実行する**（[詳細](references/merge-gate.md)）:

- **`FRESH_STATUS`**: 0 = 一致 / 1 = 不一致（取り込み＋ゲート再実行し手順 1 へ）/ 2 = 判定不能（止めないが `FRESH_REASON` と `FRESH_ACTION` の両方を報告。**2 で止めないのは意図的**）/ 3 = 検査不成立（停止）。
- **`RERUN_FULL_GATE`**: `yes` は全件再実行し手順 1、`no` は checks 全成功または印が base 一致＋導入先判定で覆う（リリース前・実行基盤契約面除く）、`see-action` は `FRESH_ACTION` へ。
- **PR タイトル件名規約（必須）**: squash 件名はマージ後修正不可のため、規約外は `gh pr edit "${PR_NUMBER}" --title "<件名>"` で修正してから進む。

<!--76dcdf137fab83c4-->
MCP: 取得値: MCPでPR title/headRefOid。形式: title 原文の構造化引数。渡し先: update_pull_request.title → fresh後読 → precheck。不足時: MCP 必須不足は停止。

gh 経路は `MERGE_COMMAND_BEGIN`〜`END` を**書き写さない**（2b は何も保証しなくなる）でそのまま**単独の Bash 呼び出しで実行**する（`cd`・リダイレクト・変数・終了コード受け・読み戻しを混ぜず、読み戻しは別呼び出しで行う）。MCP 経路は[6 引数契約](references/merge-gate.md#mcp-merge)、merge commit 規約時は全 precheck に `--merge-method merge`（[方式](references/merge-gate.md#merge-method)）、`HEAD_DELETE_RESULT` と非 0 は [Git Workflow ステップ 8](../../docs-template/05-operations/deployment/git-workflow.md#ステップ8-マージmerge) に従う。

<!--8e5705561c74af25-->
MCP: 取得値: MCPで最終 headRefOid と元 subject/body。形式: merge_pull_request の6引数。渡し先: 同じ TARGET_REPO/PR/方式のMCP merge → fresh merged/state。不足時: MCP 必須不足は停止。

### 8. 完了報告と read-back

[テンプレート](references/report.md)に最終 precheck の値をそのまま貼る:

```text
- CI checks: <手順 7 の CHECKS_REPORT をそのまま貼る>
ゲート実測鮮度: <手順 7 の FRESH_REPORT をそのまま貼る>
主要コミット: <手順 7 の PR_COMMITS をそのまま貼る>
<finish.sh precheck が出力した MERGE_COMMAND をそのまま貼る>
```

merge / delete / cleanup を分けて報告し、マージ直後の `gh issue view 46 --json state` 相当で Closes=CLOSED / Refs=OPEN を照合する（**read-back は検査を追加しても省略しない**。期待と違えば `gh issue reopen` / `gh issue close` で復旧し原因記録）。

<!--ed448197b9c5c1f3-->
MCP: 取得値: MCPでfresh PR merged/SHA と Issue state。形式: repo/number 固定 JSON。渡し先: Closes=CLOSED / Refs=OPEN を照合して報告（必要時 update_issue.state で復旧し再後読）。不足時: MCP 必須不足は停止。

- Refs 運用は 1 行目に `/ post-merge 検証待ち 1）— **マージ後も open 維持**`、抵触検査に `✅ 2a 抵触なし（INSPECTED 7 行）/ 2b 抵触なし（INSPECTED 2 行）` を書く。
- `- CI checks: <手順 7 の CHECKS_REPORT をそのまま貼る>` と鮮度欄は判定不能でも省略しない。`AUTO_CLOSE_UNRELIABLE=1` は手動クローズ警告（[merge-gate.md](references/merge-gate.md)）を必ず添える。通常 PR では手動クローズせずマージ時の `Closes #N` に任せ、空 API を「閉じない」と読まない（PR なし close は [prless-close.md](references/prless-close.md)）。
