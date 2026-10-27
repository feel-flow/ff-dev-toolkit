---
name: close-issue
description: PR のマージ前に Issue の AC を照合し、チェックボックスと報告を更新する。
---

# /close-issue — Issue クローズ前の AC 照合ゲート

## ASDD 2.0 設定がある場合

最初に[共通設定契約](../asdd-init/references/configuration.md)を読み、`scripts/asdd/config.mjs` の `loadConfig(root)` で対象プロジェクトの `.asdd/config.json` を検証する。以下の従来手順より、合意済みの文書構成・機能スイッチ・ワークフローを優先する。設定なしは従来互換、不正設定は自動処理を止めて診断する。

合意した確認方法だけを適用する。未合意の推奨をゲートにせず、無効にした ACE・振り返り・複数AIレビューをチェーンへ足さない。

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

`$ARGUMENTS` は PR 番号（省略時は `gh pr view --json number` で現在のブランチの PR を検出する）。

<!--2e25a7d7f950de06-->
MCP: 取得値: MCPでPR number/headRefName。形式: 一意の PR JSON。渡し先: PR_NUMBER → precheck argv。不足時: MCP 必須不足は停止。

## 手順

### 1. 固定手順の実行（対象 Issue の検出 + 前提の検査）

`command -v gh` 不成立・認証失敗時、MCP raw を[file入力](references/merge-gate.md#github-file-input)へ保存する。必須能力不足は operation/field/page と復帰手段を示し停止。Closes も元 subject / body を最初から保持し、precheck に `--subject "$MERGE_SUBJECT" --body "$MERGE_BODY" --github-input /absolute/index.json` を追加する。Refs 2a/2b・snapshot・鮮度を維持。

<!--2b876499214302f0-->
MCP: 取得値: MCPでPR/repo/checks/threads raw。形式: phase/attempt/cursor 付き index JSON。渡し先: precheck --github-input（subject/body も保持）。不足時: MCP 必須不足は停止。

```bash
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/check-shebang-cr.sh" || exit $?
PR_NUMBER="${PR_NUMBER:?PR 番号を先に設定すること}"
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/finish.sh" precheck "${PR_NUMBER}"
```

終了コード **0 = マージへ進める** / **1 = 止める**（理由と次の一手が stderr） / **2 = 判定不能・検査不成立**（名指しされた項目と復帰手段に従う。鮮度は手順 7）。出力（`KEY=値`）の読み方:

- **ブランチガード（必須）**: `git branch --show-current` が `PR_HEAD_REF` と違えば `gh pr checkout $PR_NUMBER` で切り替えてから続行する（できなければ停止）
- 対象 Issue は `CLOSES=owner/repo#N`（**Closes 運用** = `closingIssuesReferences` ∪ 本文の closing keyword）と `REFS=owner/repo#N`（**Refs 運用** = 本文の `Ref` / `Refs` のうち Closes 群に無いもの）。以降の `gh issue` には URL を渡す（同番号の別リポジトリ Issue を誤更新しない）
- `closingIssuesReferences` は **PR 本文だけ**を見る（件名の `fix: #N` は API 対象外）。空を理由に打ち切ると Refs が無検査になる。拾う綴りは `Ref` / `Refs` のみ（裸の `#N` 等は対象外）
- 両群空（`PRECHECK=no-target`）は「参照から検出できる対象 Issue はありません」と報告して終了。件名経由は検出範囲外なので「Issue を閉じない」と断定しない。`AUTO_CLOSE_UNRELIABLE=1`（本文 keyword あり / API 空）も照合し、手順8で手動クローズを案内する
- 複数 Issue は Issue ごとに手順 3〜6 を繰り返す。`bundle` は sub-issues 全件（`gh api --paginate repos/<owner>/<repo>/issues/<n>/sub_issues --jq '.[].number'`）へ照合を広げ、PR 本文の `Closes` に子と bundle が全部並ぶかを検査する

<!--a7da2ee356b8eaf4-->
MCP: 取得値: MCPでheadRefName/headRefOid と全 sub_issues。形式: PR JSON / 全 page 配列。渡し先: Git fetch/checkout の OID照合と全子のAC/Closes照合。不足時: MCP 必須不足は停止。

### 2. closing keyword 抵触検査（Refs 運用の Issue がある場合）

closing keyword は **squash commit のメッセージ**も走査する。検出語は `close` / `closes` / `closed` / `fix` / `fixes` / `fixed` / `resolve` / `resolves` / `resolved` の9語。`fix:` のようにコロンが挟まる形も一致します。実体は `scripts/check-closing-keywords.sh`（根拠と分岐は [references/merge-gate.md](references/merge-gate.md)）:

| | 検査対象 | 出力 | 位置づけ |
| --- | --- | --- | --- |
| **2a** | PR タイトル + 全コミットの件名と本文 | `KEYWORD_GATE=ok / conflict-title / conflict-commit`、`KEYWORD_INSPECTED`（完了報告へ転記。自分で数えない） | 供給源のスキャン |
| **2b** | 実際に `gh pr merge` へ渡す `--subject` と `--body` | `MERGE_MESSAGE_GATE=ok / conflict / required` | **権威ある検査**。通ることがマージの条件 |

<!--d0a69b3756b57dca-->
MCP: 取得値: MCPで最終 headRefOid と subject/body 原文。形式: merge_pull_request の6引数。渡し先: 手順7のMCP merge（Refs 2a/2b保持）。不足時: MCP 必須不足は停止。

- `conflict-title`: `gh pr edit "${PR_NUMBER}" --title "<Issue 参照を含まない件名>"` で改題して**手順 1 から再実行**（script は rc 1 で止まる）
- `conflict-commit`: コミットは書き換えられないので 2a では止めず、`KEYWORD_SUGGEST` を参考に件名・本文を決めて 2b をマージの条件にする。Refs 運用では抵触が無くても両方明示が既定（起動形は手順 1 と同じ）: `finish.sh precheck "${PR_NUMBER}" --subject "<件名 (#PR)>" --body "Refs #${REFS_ISSUE}（open 維持の理由）"`

<!--bf17a9a045cabba2-->
MCP: 取得値: MCPでPR title/headRefOid。形式: 新 title 原文の構造化引数。渡し先: update_pull_request → fresh後読 → precheck。不足時: MCP 必須不足は停止。

`MERGE_MESSAGE_GATE=ok` の文字列は script が `MERGE_COMMAND` へ引用して載せる。**文字列を打ち直さずそのまま手順 7 へ持ち越す**。Refs 群が 0 件なら 2a・2b は走らない。

### 2c. 未返信のレビュースレッド

script は checks の待機の後に GraphQL `reviewThreads` を全件読み、未 resolve・返信なし・起点が PR 作者でないスレッドを `REVIEW_THREADS_UNANSWERED=<件数>` と `REVIEW_THREAD=` 行で列挙し、1 件でもあれば `PRECHECK=blocked`（rc 1）。**内容は見ない** — 各スレッドへ判定（この PR で直す / follow-up Issue #N / 退ける理由）を返信してから手順 1 へ戻る。取得失敗は rc 2。MCP の返信（thread node ID か実取得した数値 ID。node ID を `comment_id` に推測変換しない）と能力 / ID 不足時の停止は references/merge-gate.md 2c。

### 3. AC 照合（判断）

`gh issue view "$ISSUE_URL" --json title,body` / `gh pr diff "$PR_NUMBER"` / `gh pr view "$PR_NUMBER" --json body,statusCheckRollup,reviewDecision` を突き合わせる。

<!--b39270663527ba9d-->
MCP: 取得値: MCPでIssue title/body と PR diff/rollup/reviewDecision。形式: 全文 JSON / diff text。渡し先: AC の対象と実行結果の照合。不足時: MCP 必須不足は停止。

**Issue 本文は全文取得する**。[AC照合](references/ac-judgement.md)に従う。

- **根拠は AC の指す対象を測っているか**: AC ごとに「根拠が測った対象 = AC が指す対象」を 1 行で書く。「測れない」= 未達（他 AC の達成数で埋めない）。bug の原因を名指しできなければ「原因未確定。次回読めるようにする計測を入れた / 入れていない」を報告する。
- 「未達」と「AC が実装より古い」を区別する。AC 無しは手順6へ。post-merge 検証待ちは Refs のみでチェックしない。

### 4. 未達 AC の解消（自動修正ループ）

未達を実装・検証し fix commit を push → 手順1へ戻る。**現 Issue の AC はスコープ外発見ではない**。別 Issue へ移して「対象外」にしない。実装で満たせず仕様変更が必要な場合だけ停止して判断を求める。独立した発見は [スコープ外発見の三分岐](../../docs-template/05-operations/deployment/workflow-principles.md)へ。

### 5. Issue 本文の更新（チェックボックス + 工数実績）

本文は**この 1 回にまとめる**。

#### 5a. 工数実績の算出（`ff-effort` ブロックがある場合）

ブロックが無い Issue ではブロックを新設せずスキップ（遡及付与せず、マージは止めない）。報告は「工数記録: ブロック不在のためスキップ」。存在時は[規則](references/effort.md)に従い `EFFORT_<Issue番号>_*`を並記、`(unmeasured)`は0にしない。

#### 5b. 本文の書き換えと送信

[Markdown 文字列パッチ規律](../../docs-template/05-operations/deployment/markdown-patch-discipline.md)に従い、達成 AC を `- [ ]` → `- [x]` にする（`☑` 不可）。初回だけ私有領域を確保し W の実値を記録する。5a の確保済み領域も使える。後続呼び出しは実値を W に明示する:

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

更新するのは**チェックボックスと `ff-effort` ブロックの中身のみ**（例外は手順 3 の「AC が実装より古い」と手順 4 のスコープ変更）。対象外・post-merge 検証待ちはチェックしない。

### 6. 完了報告コメントの投稿

**日本語**で `--body-file` 投稿。`<!-- close-issue-report:PR-<PR番号> -->` の既存コメントは更新する。5b の W の実値を明示し、報告を保存してから送信する。固定名から再構築せず、mktemp も再実行しない:

```bash
: "${W:?記録済みWの実値を明示}"
[ -d "$W" ] && [ ! -L "$W" ] || exit 2
gh issue comment "$ISSUE_URL" --body-file "$W/close-issue-report-${ISSUE_NUMBER}.md"
```

<!--1c37202f4ab93c34-->
MCP: 取得値: MCPで全 comments id/body と report marker。形式: 全 page JSON / 報告ファイル原文。渡し先: 一意IDは update_issue_comment、無ければ add_comment_to_issue → fresh一致。不足時: MCP 必須不足は停止。

報告の[テンプレート](references/report.md)を読み、各 AC に `測った対象: [AC が指す対象]` と根拠を書く。主要コミット: <手順 1 の PR_COMMITS をそのまま貼る>。

主要コミット欄は `PR_COMMITS` の行を貼り、**自分で hash を書かない**（`KEYWORD_INSPECTED` と同じ。`PR_COMMITS_SOURCE` が `git` 以外なら併記）。帯外は乖離の原因を書く（references/effort.md）。

### 7. ゲート実測鮮度の照合（マージ直前）

**マージ直前に `finish.sh precheck` をもう一度実行する**。MCP / Refs は同じ subject / body、file は fresh raw を使い、`headRefOid` と記録を照合する（[詳細](references/merge-gate.md)）:

- **`FRESH_STATUS`**: 0 = 一致（`FRESH_REPORT` を報告へ）/ 1 = 不一致（止まる。`RELATION` に従って取り込んでゲートを回し直し、手順 1 へ）/ 2 = 判定不能（止めないが `FRESH_REASON` / `FRESH_ACTION` を**両方**報告へ。**2 で止めないのは意図的** — 記録の仕組みを持たないプロジェクトでは常態）/ 3 = 検査不成立（止める）
- **`RERUN_FULL_GATE`**（判定不能のとき）: `yes` は clean な木で全件ゲートを再実行して手順 1 へ。`no` は進む（**リリース前・契約面の変更時は除く** — script は rc 0 を返すのでここで判断）。`see-action` は `FRESH_ACTION` に従う
- **PR タイトルの件名規約（必須）**: タイトルは squash の件名になり**マージ後に直せない**。規約外なら `gh pr edit "${PR_NUMBER}" --title "<規約に沿った件名>"` で直してから進む（Refs 運用の `--subject` も同じ）

<!--80affbd1cf30b389-->
MCP: 取得値: MCPでPR title/headRefOid。形式: title 原文の構造化引数。渡し先: update_pull_request.title → fresh後読 → precheck。不足時: MCP 必須不足は停止。

gh 経路は `MERGE_COMMAND_BEGIN` 〜 `END` の出力をそのまま実行し、手順 8 へ貼る。**書き写さない**（2b は何も保証しなくなる）。MCP 経路は[同じ最終 precheck の元値を6引数へ渡す契約](references/merge-gate.md#mcp-merge)に従い、生成 shell を parse/eval/unquote せず実行する。base / head を別 worktree が保持する回は、merge 成功後だけ ref を照会し、不在は成功・別 OID は保全・一致は lease 削除となる。`HEAD_DELETE_RESULT` と非 0 の読み方は [Git Workflow](../../docs-template/05-operations/deployment/git-workflow.md#ステップ8-マージmerge) に従う。

<!--2e29cd9d5cca03f5-->
MCP: 取得値: MCPで最終 headRefOid と元 subject/body。形式: merge_pull_request の6引数。渡し先: 同じ TARGET_REPO/PR/squash のMCP merge → fresh merged/state。不足時: MCP 必須不足は停止。

### 8. 完了報告

[完了報告テンプレート](references/report.md)へ Issue の達成数、本文 / コメント更新、工数、keyword、checks を記録する。同じ最終 precheck の値を貼る:

```text
- CI checks: <手順 7 の CHECKS_REPORT をそのまま貼る>
ゲート実測鮮度: <手順 7 の FRESH_REPORT をそのまま貼る>
主要コミット: <手順 7 の PR_COMMITS をそのまま貼る>
<finish.sh precheck が出力した MERGE_COMMAND をそのまま貼る>
```

gh は生成 block、MCP は手順7の元値と6引数を記録。merge/delete/cleanup を分け、直後の `gh issue view 46 --json state` 相当の MCP GET で Closes=CLOSED / Refs=OPEN を照合。未実施は成功にしない。

<!--5a7971ceb51cfd4f-->
MCP: 取得値: MCPでfresh PR merged/SHA と Issue state。形式: repo/number 固定 JSON。渡し先: Closes=CLOSED / Refs=OPEN を照合して報告。不足時: MCP 必須不足は停止。

- Refs 運用は 1 行目に `/ post-merge 検証待ち 1）— **マージ後も open 維持**`、抵触検査に `✅ 2a 抵触なし（INSPECTED 7 行）/ 2b 抵触なし（INSPECTED 2 行）` を書く。`- CI checks: <手順 7 の CHECKS_REPORT をそのまま貼る>` と鮮度の欄は判定不能でも省略しない
- `AUTO_CLOSE_UNRELIABLE=1` なら手動クローズの警告（references/merge-gate.md の定型文）を**必ず**添える。head SHA と merge コマンドは同じ precheck 実行の値にする
- **read-back は検査を追加しても省略しない** — 手順 2 は `GH-N` や完全 URL を見ないので、実際の state だけが最終証拠。期待と違えば `gh issue reopen` / `gh issue close` で復旧し、原因を記録する

<!--0d17730dbfaa8152-->
MCP: 取得値: MCPでfresh PR merged/SHA と Issue state。形式: repo/number 固定 JSON。渡し先: 必要時 update_issue.state で復旧し再後読。不足時: MCP 必須不足は停止。

## 注意事項

- このコマンドは **Issue をクローズしない**（マージ時の `Closes #N` に任せる。Refs 運用の Issue は post-merge 検証を実測した人が閉じる）。自動クローズは (1) クローズリンク (2) squash メッセージの closing keyword の 2 経路で、空 API を「閉じない」と読まない
