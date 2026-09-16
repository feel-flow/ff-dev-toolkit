---
name: workflow-doctor
description: Use when checking that a consumer project's entry-point rules (CLAUDE.md / AGENTS.md / .cursor rules / global CLAUDE.md / Stop hooks) do not override the decision order that out-of-scope-issue, retrospective and create-issue implement (YAGNI → inline fix → append to an open bundle → file per bundle). 導入先の入口規範がスキルの判定順と矛盾していないかを read-only で検査し、ずれを重大度付きで報告する（「発見 = 起票」の旧文言、節の必須語、Stop hook の reminder、bundle の受け皿、ラベルの実在、親無し Issue、RETROSPECTIVE_FILING）。「ワークフローを診断して」「スキルが効いているか確認」「workflow doctor」「Issue が増え続ける原因を調べて」と言われたとき、/ace-setup・/setup-ai-config の末尾、/retrospective の冒頭で使用する。
---

# /workflow-doctor — 導入先の入口規範とスキルの判定順の矛盾検査

`/out-of-scope-issue` は **YAGNI → 同 PR インライン → 既存 `bundle` へ追記 → `bundle` 単位で新規** の順で発見を仕分ける設計だが、導入先の入口文書（CLAUDE.md / AGENTS.md / `.cursor/rules` / グローバル CLAUDE.md）や Stop hook が「発見 = 起票」を要求していると、スキルの判定順は入口で上書きされ、細かい Issue が増え続ける。実測（導入先の 1 つ）: 入口文書に `YAGNI` の語が 0 件で「別 Issue 化を口にした時点で必ず起票」「issue化必須」が残り、open Issue 95 件・直近 2 日で 28 件起票・親無し 32 件まで膨らんだ。**スキル側からはこの上書きが見えない**ので、導入先で検査する。

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

## 前提

- 導入先の git リポジトリで作業中であること（`--root` で明示してもよい）
- 4〜6 の検査は認証済み `gh` を使う。無い環境・使いたくない回は `--offline` で SKIP にする（SKIP は緑ではない）
- **read-only**。ファイルを書かず、Issue も作らない。`--fix` は**意図的に持たない** — CLAUDE.md の節を定型文へ自動置換すると導入先の文脈（節の前後・他節からの参照）を壊しうるため、置換案を `FIXTEXT` 行で印字し、適用は人（またはこのスキルを呼んだホスト）が差分を見て行う

## 実行

```bash
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/workflow-doctor.sh" --root "$(git rev-parse --show-toplevel)"
```

オプション: `--global-claude <path>`（既定 `$CLAUDE_CONFIG_DIR/CLAUDE.md`、無ければ `~/.claude/CLAUDE.md`）/ `--settings <path>`（Stop hook を読む settings.json。繰り返し可。既定は `<root>/.claude/settings.json`・`<root>/.claude/settings.local.json`・`$CLAUDE_CONFIG_DIR/settings.json` の 3 件）/ `--offline` / `--repo OWNER/REPO`。

## 検査項目（6 + 1）

| 番号 | 検査 | 見る場所 | ずれの例（導入先で実測） | 重大度 |
| --- | --- | --- | --- | --- |
| 1 | 判定順の矛盾 | CLAUDE.md / AGENTS.md / `.cursor/**`(.md, .mdc) / `.github/copilot-instructions.md` / グローバル CLAUDE.md | 「issue化必須」「口にした時点で必ず起票」「デフォルトは即 Issue 起票」 | FAIL |
| 2 | 節の必須語 | CLAUDE.md「## スコープ外の発見」節 | `YAGNI` / `bundle` の欠落（節が無ければ WARN） | FAIL / WARN |
| 3 | hook の文言 | settings.json（3 件の既定対象）の Stop hook の command 文字列と、それが参照するスクリプト（複数可） | reminder が「STEP3 = gh issue create で即起票」で既存 bundle への追記が無い / command 文字列そのものに旧文言 | FAIL |
| 4 | 起票の受け皿 | `gh issue list --label bundle --state open` | open な bundle が 0 件（統合先が無く新規へ落ちる） | WARN |
| 5 | ラベルの実在 | `gh label list --limit 200` | `bundle` / `epic` / `follow-up` の不在、優先度ラベル（`priority:*` または `P<n>-*`）の不在（`/setup-github-labels` を案内） | WARN |
| 6 | 親無し Issue | open Issue の GraphQL `parent` | parent 無し・`epic` / `bundle` でもない Issue の件数（実測 32 件） | WARN |
| 7 | 環境変数 | `RETROSPECTIVE_FILING` | 未設定なら既定（承認を待たない自動起票）を利用者が把握しているか | INFO |

- 出力は 1 行 1 所見（`<LEVEL>\t<番号>\t<所見>`）。`FIXTEXT` 行は置換案。末尾に `SUMMARY fail=<n> warn=<n> skip=<n>`
- 終了コード: **0** = FAIL 0 件 / **1** = FAIL あり / **2** = 対象（`--root`）を解決できない（検査不成立。緑と読まない）
- 検査 1 の検査語は固定文字列と `.*` だけで書く（多バイトの文字クラスは BSD grep の C ロケールで一致 0 件 = fail-open になる。導入先の実測）。`grep` の rc≥2 は FAIL として報告し「0 件」に畳まない

## 結果の読み方と直し方

- **FAIL 1（旧文言）**: 該当行を、`docs-template/05-operations/deployment/git-workflow.md`「bundle（子を全件 1 PR で束ねる着手単位）」と同じ 4 段（YAGNI → 同 PR インライン → 既存 bundle へ追記 → bundle 単位で新規）へ書き換える。グローバル CLAUDE.md（`$HOME` 配下）はリポジトリ外なので PR ではなく直接編集する。書き換え後は導入先で逆戻り検査を常設する（導入先の例: `scripts/check-out-of-scope-rules.sh` を `ci:local` から呼ぶ）
- **FAIL 3（hook）**: reminder 文を 4 段へ差し替え、最終発話に `YAGNI（理由: …）` があれば 1 サイクル目からブロックしない分岐を足す
- **WARN 4 / 5**: `/setup-github-labels` でラベルを整備し、テーマごとに `create-issue --bundle` で bundle を立てる（棚卸しの手順: テーマごとに bundle を立て、既存の細 Issue を `scripts/link-sub-issues.sh` で子へ付け替え、根拠の無いものは YAGNI コメントで close する）
- **WARN 6**: 親無しの細 Issue を、テーマの bundle の sub-issue へ `scripts/link-sub-issues.sh` で付け替える（`gh api -f sub_issue_id=` を組み立てない）

## 呼び出し元

- `/ace-setup` 手順 7 / `/setup-ai-config` 重要ルール末尾（導入直後に入口規範がスキルと揃っているか。いずれも `--offline`）
- `/retrospective` 実行ポリシー（振り返りの冒頭で逆戻りを検知する。`--offline`）
- 単独: 「Issue が増え続ける」「スキルが効いていない気がする」と感じたとき（gh を使う 4〜6 まで回すのはこの経路）

## 注意事項

- 本スキルは**書かない**（ファイル編集・Issue 作成・ラベル作成をしない）。直すのは呼び出し元
- 検査 1 は「旧文言を廃止した経緯」として逐語引用する文にも当たる（意図した fail-closed）。経緯は `docs/08-knowledge/` の証跡側へ書き、入口文書では逐語引用しない
- 検査 4〜6 の SKIP は「問題なし」ではない。`--offline` で回した回は報告に SKIP を残す
