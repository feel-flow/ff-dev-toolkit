---
name: close-issue
description: マージ直前に PR が閉じる Issue の受け入れ条件（AC）を照合し、チェックボックス更新 + 完了報告コメントを投稿する（AC 照合ゲート）
---

# /close-issue — Issue クローズ前の AC 照合ゲート

## ASDD 2.0 設定がある場合

最初に[共通設定契約](../asdd-init/references/configuration.md)を読み、`scripts/asdd/config.mjs` の `loadConfig(root)` で対象プロジェクトの `.asdd/config.json` を検証する。以下の従来手順より、合意済みの文書構成・機能スイッチ・ワークフローを優先する。設定なしは従来互換、不正設定は自動処理を止めて診断する。

合意した確認方法だけを適用する。カバレッジ80%、Result pattern、strict、定数化などの推奨を未合意のゲートにしない。ACE・振り返り・複数AIレビューの無効設定を尊重し、チェーン末尾にも追加しない。市民開発のIssue中心運用では、既存の組織ルールを保ちつつ、未採用のPR・7文書を必須化しない。

PR 作成後・`gh pr merge` の**前**に実行し、PR が閉じる Issue の受け入れ条件（AC）を照合する。固定手順（対象 Issue の検出・closing keyword 抵触検査・工数の実測・checks の分岐・ゲート実測鮮度・merge コマンド生成）は同梱 `scripts/finish.sh precheck` が実行する。

| 運用 | PR 本文 | マージ後の Issue | 役割 |
| --- | --- | --- | --- |
| **Closes 運用** | `Closes #N` | 閉じてよい | AC 照合 → チェックボックス更新 → 完了報告 |
| **Refs 運用** | `Refs #N` のみ | **open のまま維持** | 上記 + squash メッセージが閉じないことの検査（手順 2）。post-merge 検証が残る Issue 用 |

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

## 手順

### 1. 固定手順の実行（対象 Issue の検出 + 前提の検査）

```bash
PR_NUMBER="${PR_NUMBER:?PR 番号を先に設定すること}"
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/finish.sh" precheck "${PR_NUMBER}"
```

終了コード **0 = マージへ進める** / **1 = 止める**（理由と次の一手が stderr） / **2 = 判定不能・検査不成立**（PR 不在 / gh 不通 / 鮮度の判定不能。名指しされた項目と復帰手段に従う。鮮度は手順 7）。出力（`KEY=値`）の読み方:

- **ブランチガード（必須）**: `git branch --show-current` が `PR_HEAD_REF` と違えば `gh pr checkout $PR_NUMBER` で切り替えてから続行する（できなければ停止）
- 対象 Issue は `CLOSES=owner/repo#N`（**Closes 運用** = `closingIssuesReferences` ∪ 本文の closing keyword）と `REFS=owner/repo#N`（**Refs 運用** = 本文の `Ref` / `Refs` のうち Closes 群に無いもの）。以降の `gh issue` には番号ではなく URL を渡す（同番号の別リポジトリ Issue を誤更新しない）
- `closingIssuesReferences` は **PR 本文だけ**を見る（件名の `fix: #N` はマージで閉じるのに API に出ない）。空を理由に打ち切ると Refs 運用の PR が無検査で通る。拾う綴りは `Ref` / `Refs` のみ（`関連 #N` や裸の `#N` は拾わない）
- 両群とも空（`PRECHECK=no-target`）なら「参照から検出できる対象 Issue はありません」と報告して終了する。**「この PR は Issue を閉じません」とは報告しない**（件名経由のクローズは検出の範囲外）。`AUTO_CLOSE_UNRELIABLE=1`（本文に keyword があるのに API が空）は照合を続行し、手順 8 で手動クローズを案内する
- 複数 Issue は Issue ごとに手順 3〜6 を繰り返す。`bundle`（子を全件 1 PR で束ねる着手単位）は sub-issues 全件（`gh api --paginate repos/<owner>/<repo>/issues/<n>/sub_issues --jq '.[].number'`）へ照合を広げ、PR 本文の `Closes` に子と bundle が全部並んでいるかを検査する

### 2. closing keyword 抵触検査（Refs 運用の Issue がある場合）

closing keyword は **squash commit のメッセージ**も走査されるので、`fix: #123 …` という件名で `Refs #123` の PR でも Issue が閉じる。検出語は `close` / `closes` / `closed` / `fix` / `fixes` / `fixed` / `resolve` / `resolves` / `resolved` の 9 語で、`fix:` のようにコロンが挟まる形も一致します。実体は `scripts/check-closing-keywords.sh`（根拠と分岐は [references/merge-gate.md](references/merge-gate.md)）:

| | 検査対象 | 出力 | 位置づけ |
| --- | --- | --- | --- |
| **2a** | PR タイトル + 全コミットの件名と本文 | `KEYWORD_GATE=ok / conflict-title / conflict-commit`、`KEYWORD_INSPECTED`（完了報告へ転記。自分で数えない） | 供給源のスキャン |
| **2b** | 実際に `gh pr merge` へ渡す `--subject` と `--body` | `MERGE_MESSAGE_GATE=ok / conflict / required` | **権威ある検査**。通ることがマージの条件 |

- `conflict-title`: `gh pr edit "${PR_NUMBER}" --title "<Issue 参照を含まない件名>"` で改題して**手順 1 から再実行**（script は rc 1 で止まる）
- `conflict-commit`: コミットは書き換えられないので 2a では止めず、`KEYWORD_SUGGEST` を参考に件名・本文を決めて 2b をマージの条件にする。Refs 運用では抵触が無くても両方明示が既定:

```bash
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/finish.sh" precheck "${PR_NUMBER}" \
  --subject "fix: 誤クローズを防ぐ検査を追加する (#${PR_NUMBER})" \
  --body "Refs #${REFS_ISSUE}

post-merge 検証が残るため Issue は open のまま維持する。"
```

`MERGE_MESSAGE_GATE=ok` の文字列は script が `MERGE_COMMAND` へ引用して載せる。**文字列を打ち直さずそのまま手順 7 へ持ち越す**（コピペこそが実際の再発経路）。Refs 群が 0 件なら 2a・2b は走らない。

### 3. AC 照合（判断）

`gh issue view "$ISSUE_URL" --json title,body` / `gh pr diff "$PR_NUMBER"` / `gh pr view "$PR_NUMBER" --json body,statusCheckRollup,reviewDecision` を突き合わせる。

- **Issue 本文は全文取得する**（`head` / `tail` で切らない。AC / DoD は末尾に多く、切ると「検査対象なしで緑」になる）
- 「テストがパスすること」系の DoD は diff だけで達成と判定せず、checks かテストコマンドの**実行結果**を根拠にする。**根拠が取得できない項目は「未達」扱い**

| 判定 | 意味 |
| --- | --- |
| **達成** | AC を満たす変更・検証結果が PR に含まれている |
| **未達** | AC を満たす変更が確認できない |
| **対象外** | 仕様が変わった等、この PR では扱わない項目 |
| **post-merge 検証待ち** | **Refs 運用の Issue に限る**。マージ後にしか実測できない AC。チェックせず、マージは止めず、閉じる条件を完了報告に書く |

**「未達」と「AC が実装より古い」を区別する**（fix commit で前提値が置き換わったのに Issue が旧値なら AC を実装に合わせて更新して再照合。意図を変えるなら手順 4 の停止条件）。AC が無い Issue は照合をスキップして手順 6 へ。詳細は [references/ac-judgement.md](references/ac-judgement.md)。

### 4. 未達 AC の解消（自動修正ループ）

未達 AC を満たす実装・テストを追加して fix commit を push し（直前に `git status --short` とメッセージの主張を突き合わせる）、**手順 1 に戻る**。停止してユーザーに確認するのは AC の達成に**仕様変更が必要**な場合だけ。**未達 AC が大きくても先送りしない**: 現 Issue の AC はスコープ外発見ではない。別 Issue へ移して「対象外」にせず、マージを停止して仕様変更の判断を求める。独立した発見だけを [スコープ外発見の三分岐](../../docs-template/05-operations/deployment/workflow-principles.md)へ渡す。

### 5. Issue 本文の更新（チェックボックス + 工数実績）

本文への書き込みは**この 1 回にまとめる**。

#### 5a. 工数実績の算出（`ff-effort` ブロックがある場合）

**ブロックが無ければこの手順を丸ごとスキップし、「工数記録: ブロック不在のためスキップ」の 1 行を手順 8 の完了報告に残す。** マージは止めない（fail-open。ブロックが無い Issue ではブロックを新設せず、遡及付与を強制しない）。ブロックがあれば [references/effort.md](references/effort.md) の規則どおりに書き戻す（hook の実測 `EFFORT_<Issue番号>_*` を並記し、`(unmeasured)` は 0 にしない）。

#### 5b. 本文の書き換えと送信

script で文字列パッチを当てる場合は [Markdown 文字列パッチ規律](../../docs-template/05-operations/deployment/markdown-patch-discipline.md)に従う。達成した AC は **Markdown タスクリスト記法の checked state（`- [ ]` → `- [x]`）**で書き換える（`☑` 等はタスクとして認識されない）:

```bash
gh issue view "$ISSUE_URL" --json body,updatedAt   # 1) body を /tmp/issue-body-"${ISSUE_NUMBER}".md と同 .orig.md へ保存
# 2) 達成と判定した AC の行だけを "- [ ]" → "- [x]" へ個別に置換（sed 等の一括置換は禁止）
# 3) 機械判定（目視しない）: 変更行は (a) チェックボックス行 か (b) ff-effort:begin / end 行の間だけ。
#    マーカー行の変更・削除は違反。パスと Issue 番号は :? で fail-closed
JUDGE="${FF_DEV_TOOLKIT_ROOT:?プラグインルートを先に解決すること}/scripts/check-issue-body-diff.sh"
ISSUE_NUMBER="${ISSUE_NUMBER:?Issue 番号を先に設定すること}"
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "$JUDGE" "/tmp/issue-body-${ISSUE_NUMBER}.orig.md" "/tmp/issue-body-${ISSUE_NUMBER}.md"
case $? in
  0) : ;;  # 許可範囲内。4) の送信へ進む
  1) echo "✗ 許可範囲外の変更。送信せず 2) の書き換えをやり直す" >&2; exit 1 ;;
  2) echo "✗ 検査が成立していない（マーカー構成の破損・baseline の異常）。送信しない" >&2; exit 2 ;;
  *) echo "✗ 上記以外の終了コード = 判定器を起動できていない。検査は成立していないので送信しない" >&2; exit 2 ;;
esac
# 4) 送信直前に updatedAt を再取得し、1) から変化していなければ送信（変化していたら 1) から）
gh issue edit "$ISSUE_URL" --body-file "/tmp/issue-body-${ISSUE_NUMBER}.md"
```

更新するのは**チェックボックスと `ff-effort` ブロックの中身のみ**（例外は手順 3 の「AC が実装より古い」と手順 4 のスコープ変更）。「対象外」「post-merge 検証待ち」はチェックしない。

### 6. 完了報告コメントの投稿

**日本語**で `--body-file` 投稿する。冒頭の識別マーカー `<!-- close-issue-report:PR-<PR番号> -->` を持つ既存コメントがあれば更新して重複を防ぐ:

```bash
gh issue comment "$ISSUE_URL" --body-file "/tmp/close-issue-report-${ISSUE_NUMBER}.md"
```

```markdown
## 完了報告（PR #<PR番号>）

### 何が問題で、どう解決したか（1〜3 段落）

### AC 検証結果

| AC | 判定 | 根拠 |
| --- | --- | --- |
| Given ... When... Then | ✅ 達成 | [該当ファイル・テスト・検証コマンド] |
| ... | ➖ 対象外 | [理由と別 Issue 番号（あれば）] |
| DoD: staging で ... | ⏳ post-merge 検証待ち | [マージ後に実測する手順と、閉じてよい条件] |

### 工数実績

（references/effort.md の節。ブロックが無い Issue では節ごと省略）

### 参照

- PR: #<PR番号> / 主要コミット: <hash> <件名>
```

乖離率が帯の外（`0.71` 未満 / `1.40` 超）なら「乖離の原因」は必須（帯の正本は references/effort.md）。AC 記載なしは照合をスキップした旨と実装サマリを、post-merge 検証待ちがあれば「マージ後も open のまま維持する」ことと閉じる手順を書く。

### 7. ゲート実測鮮度の照合（マージ直前）

fix commit を積んだ回や手順 1 から時間が経った回は、**マージ直前に `finish.sh precheck` をもう一度実行する**（Refs 運用は `--subject` / `--body` 付き）。script が checks の有無で分岐し（非空なら完了と成功を待ち、失敗ならマージへ進まない。空なら `CHECKS_REPORT` を報告へ）、照合直前に読み直した `headRefOid` を記録と照合する。根拠は [references/merge-gate.md](references/merge-gate.md)。判断点:

- **`FRESH_STATUS`**: 0 = 一致（`FRESH_REPORT` を報告へ）/ 1 = 不一致（止まる。`RELATION` に従って取り込んでゲートを回し直し、手順 1 へ）/ 2 = 判定不能（止めないが `FRESH_REASON` / `FRESH_ACTION` を**両方**報告へ。**2 で止めないのは意図的** — 記録の仕組みを持たないプロジェクトでは常態）/ 3 = 検査不成立（止める）
- **`RERUN_FULL_GATE`**（判定不能のとき）: `yes`（汚れた木 / 記録なし / 部分実行で checks の裏付けなし）なら clean な木で全件ゲートを再実行して手順 1 へ。`no`（部分実行 + checks 全件成功）なら進む（**リリース前・契約面の変更時は除き**、その場合は全件ゲートを再実行する — script は rc 0 を返すのでここで判断する）。`see-action` は `FRESH_ACTION` に従う
- **PR タイトルの件名規約（必須）**: タイトルが squash の件名になり**マージ後に直せない**。規約を満たしていなければ `gh pr edit "${PR_NUMBER}" --title "<規約に沿った件名>"` で直してから進む（Refs 運用の `--subject` も同じ）

merge コマンドは script が生成する（`MERGE_COMMAND_BEGIN` 〜 `END`。base / head を別 worktree が保持していれば `--delete-branch` 無し + `&&` で繋いだリモートブランチ削除）。**この出力をそのまま手順 8 の報告へ貼り、書き写さない** — 人が打ち直した時点で 2b は何も保証しなくなる。

### 8. 完了報告

```markdown
## /close-issue 完了

- 対象 Issue: #46（達成 6 / 未達 0 / 対象外 0）
- チェックボックス更新: ✅ / 完了報告コメント: ✅
- 工数記録: ✅ AI 予定 4.8h → 実績 11.2h（乖離率 2.33・閾値超過）／ブロック不在の場合は「ブロック不在のためスキップ」
- closing keyword 抵触検査: 対象なし（Closes 運用）
- CI checks: <手順 7 の CHECKS_REPORT をそのまま貼る>
- ゲート実測鮮度: <手順 7 の FRESH_REPORT をそのまま貼る>
- 照合時の head SHA: <PR_HEAD_OID>

→ マージに進めます:

    <finish.sh precheck が出力した MERGE_COMMAND をそのまま貼る>

→ マージ直後に read-back（Closes 運用は CLOSED、Refs 運用は OPEN のままを実測する）:

    gh issue view 46 --json state
```

- Refs 運用は 1 行目に `/ post-merge 検証待ち 1）— **マージ後も open 維持**`、抵触検査に `✅ 2a 抵触なし（INSPECTED 7 行）/ 2b 抵触なし（INSPECTED 2 行）` を書く。`- CI checks: <手順 7 の CHECKS_REPORT をそのまま貼る>` と鮮度の欄は省略しない（判定不能でも）
- `AUTO_CLOSE_UNRELIABLE=1` なら手動クローズの警告（references/merge-gate.md の定型文）を**必ず**添える。head SHA と merge コマンドは script の同じ実行が出した値にする
- **read-back は検査を追加しても省略しない** — 手順 2 は `GH-N` や完全 URL を見ないので、実際の state だけが最終証拠。期待と違えば `gh issue reopen` / `gh issue close` で復旧し、原因を記録する

## 注意事項

- このコマンドは **Issue をクローズしない**（マージ時の `Closes #N` に任せる。Refs 運用の Issue を閉じるのは post-merge 検証を実測した人）。自動クローズは (1) クローズリンクのマージ (2) squash メッセージの closing keyword の 2 経路で、空 API を「閉じない」と読まない
- 未達 AC を「あとで直す」ためにマージを先行させない
