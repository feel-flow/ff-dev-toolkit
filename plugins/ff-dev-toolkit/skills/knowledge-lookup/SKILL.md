---
name: knowledge-lookup
description: Use when starting implementation or review and the change might hit a known pattern. ACE Playbook と振り返り観測台帳（OBSERVATIONS.md）の両方を同じキーワードで 1 回引き、状態（ACE の active / deprecated / archived、台帳の active / promoted / mitigated / archived）で切り分けて返す。「既知の落とし穴を引いて」「Playbook と台帳を検索して」「knowledge lookup」「着手前の参照」と言われたとき、git-workflow の「着手前の Playbook 参照」を実行するとき、/retrospective が promoted かつ open のエントリを突き合わせるときに使用。書き込みは行わない。
---

# /knowledge-lookup — ACE Playbook と観測台帳を 1 回で引く

観測台帳（`docs/08-knowledge/OBSERVATIONS.md`）は `/retrospective` が育てる store だが、**書くだけでなく引く store** である。ACE Playbook には「着手前の Playbook 参照」という読み出しの導線があるのに、台帳には無かった（Issue `#1778`）。同じセッションで ACE の知見は作業中に届き、台帳の同じ主張は振り返りの事後にしか突き合わされなかった。同じ主張が 10 回記録されているエントリは、記録が働いていることと、その記録が作業へ届いていないことを同時に示す。本スキルはその読み側を配線する。

ACE と観測は粒度・寿命・状態が異なるので、**混ぜて返さない**。`promoted`（対策 Issue が既に在る）や `mitigated`（対策が別の場所に定義済み）を「未対策の落とし穴」として実装判断へ混入させないため、store ごと・状態ごとに分けて提示する。

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

## 実行

必要なものは bash 3.2 以降、awk、find。`gh` は `promoted` / `mitigated` エントリの Issue state 確認にだけ使う（無ければ `未確認` として返す。`--offline` で明示的に使わない）。同梱の `scripts/knowledge-lookup.sh` の実在を確認して実行する。書き込みは一時ファイルだけで、対象リポジトリには何も書かない。

### キーワード検索（実装・レビュー前）

変更対象領域のキーワード（モジュール名・コマンド名・症状の語）を 1 つ以上渡す。既定は OR、`--all` で AND。

```bash
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/knowledge-lookup.sh" --root "$(git rev-parse --show-toplevel)" <キーワード>...
```

出力は store ごと・状態ごとのグループで並ぶ。末尾の `RECORD ace=… obs=…` 行が、git-workflow「着手前の Playbook 参照」が要求する記録（ヒット ID / `0 件` / `Playbook なし` / `読み取り失敗（理由）`）にそのまま転記できる形になっている。台帳側の語は `台帳なし`。

### promoted × open の突き合わせ（`/retrospective` 観察チェックリスト第 0 項）

```bash
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/knowledge-lookup.sh" --root "$(git rev-parse --show-toplevel)" --promoted-open
```

台帳の `Status | promoted` エントリのうち、リンク先 Issue が open のもの（state を確認できなかったものは `未確認` として隠さず含める）を列挙する。振り返りではこの一覧をそのセッションの事象と 1 件ずつ突き合わせる（手順の正本は `/retrospective` の観察チェックリスト第 0 項）。

## 結果の読み方（状態による切り分け）

| store | 状態 | 読み方 |
| --- | --- | --- |
| ACE Playbook | `active` | 有効な知見。適用条件が合えばそのまま従う |
| ACE Playbook | `deprecated` | 適用しない（後続エントリで置き換え済み） |
| ACE Playbook | `archived` | `playbook/archive/` 配下の stale エントリ。`--include-archived` のときだけ出る。参考のみ |
| 観測台帳 | `active` | **未対策**の落とし穴（蓄積中）。回避策はエントリ本文の `→` 以降 |
| 観測台帳 | `promoted` | **対策 Issue あり**。Issue 列の state を見る — `open` は対応中（同じ落とし穴を踏んだら再発コメントの対象）、`closed` は対策済みまたはその後の再発 |
| 観測台帳 | `mitigated` | **対策済み**。対策の所在（`owner/repo#N` / `skill:<名>` / `doc:<path>#<アンカー>`）が Issue 列にある。未対策として扱わない |
| 観測台帳 | `archived` | 休眠（180 日以上再発なし）。`--include-archived` のときだけ出る |

- `promoted` / `mitigated` を「まだ誰も対策していない」と読まないこと。対策があるのに独自の回避策を実装へ持ち込むと、対策の二重化になる
- Issue state が `未確認` の参照は `gh` が使えなかった・失敗した・open 一覧が上限に達したのいずれか。`open` と読み替えず、必要なら `gh issue view` で個別に確かめる
- ヒットした ACE エントリを実装で参照したら、git-workflow の規定どおりコミット本文・`implementation-notes.md` に ACE ID を記録する（`Helpful` カウンターと再利用計測の入力になる）。台帳エントリの参照は Count を動かさない（Count は再発の計上であり、参照の計上ではない）

## 終了コード

| rc | 意味 |
| --- | --- |
| 0 | 検索を実施した（0 件ヒットを含む）。片方の store が無い回も 0（RECORD 行に `Playbook なし` / `台帳なし`）— 不在は記録して標準手順を続行する規定に合わせる |
| 1 | 引数エラー（キーワード無し・未知のオプション） |
| 2 | 検索不成立 — 両 store とも不在、または在るのに読めない・エントリ見出し（`### ACE-…:` / `### OBS-NNN:`）を 1 件も認識できない（書式変更を 0 件ヒットの緑へ倒さない） |
| 3 | plugin root ガードの停止（handoff と実体位置の不一致・消えた root）。「ff-dev-toolkit更新後にこのskillを再呼び出してください」の案内に従う。検索不成立（2）とは別の番号にしてあるので、3 を「検索した結果」と読まない |

store の実配置は既定パス（`docs/08-knowledge/PLAYBOOK.md` / `OBSERVATIONS.md`）の不在だけで「未導入」と結論せず、root 配下を探索して候補が 1 件ならそれを採る。複数候補は曖昧として採らず、`--playbook` / `--ledger` の明示を求める（推測で 1 つを選ばない）。

## 導入先での配線

`/retrospective` が台帳を作成する導入先では、本スキルが読み側の入口になる。配線手順の正本は `/ace-setup` Step 4（`CLAUDE.md` / `AGENTS.md` へ「着手前に `/knowledge-lookup` で ACE Playbook と観測台帳の両方を引く」と、台帳の配置パスを書く）。repo-local の ACE lookup スキルを既に持つ導入先は、そのスキルの探索対象へ台帳を加えるか、本スキルへ寄せる — 引く動作を 2 つ並べない。

## 位置づけ

| | 書く | 引く |
| --- | --- | --- |
| ACE Playbook | `/ace-curate` | 本スキル（git-workflow「着手前の Playbook 参照」の実行手段） |
| 観測台帳 | `/retrospective` | 本スキル（実装・レビュー前のキーワード検索、振り返りの promoted × open 突き合わせ） |
