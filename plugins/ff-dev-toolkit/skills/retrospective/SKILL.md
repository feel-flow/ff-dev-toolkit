---
name: retrospective
description: ワークフローチェーンの末尾（/merge-cleanup → /ace-curate の後）で毎回セッション振り返りを実施し、プロセス・ツール・スキルのメタ知見（手戻り・無駄時間・Keep・過剰動作）を観測台帳へ記録して、閾値に到達した再発から改善提案を最大 3 件出す。「振り返り」「retrospective」「セッション振り返り」「プロセス改善の提案」と言われたとき、または PR を伴わない作業の締めにも単独で使用。実測した観測が無ければ 1 行報告で終了する。
---

# /retrospective — セッション振り返り（観測の記録とプロセス・ツール改善の提案）

## ASDD 2.0 設定がある場合

最初に[共通設定契約](../asdd-init/references/configuration.md)を読み、`scripts/asdd/config.mjs` の `loadConfig(root)` で対象プロジェクトの `.asdd/config.json` を検証する。以下の従来手順より、合意済みの文書構成・機能スイッチ・ワークフローを優先する。設定なしは従来互換、不正設定は自動処理を止めて診断する。

`features.retrospective=false` のとき、ワークフローからの自動実行・起動の催促・「対象外」などの定型報告を行わない。ユーザーがこの振り返りを明示依頼した場合だけ、設定を変えず単発実行する。以下の「毎回」は設定なし、または自動振り返りを選んだ場合に限る。

作業セッションの締めに、そのセッションで**実際に起きた**ことを KPT の観点で振り返る — Problem（手戻り・無駄時間・過剰動作）と Keep（定着させる価値のある成功パターン）を観測として拾い、観測台帳へ記録する。Issue を起票するのは原則として台帳の閾値に到達した再発だけで、次回同じ作業が速く・正確になる改善を提案する。振り返り自体は read-only・低コストなので確認を挟まず毎回実施し、ノイズは台帳の閾値と提案側の閾値で絞る。

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

## 位置づけ — ACE との責務分離

| | 対象 | 出力先 |
| --- | --- | --- |
| `/ace-curate` | コード・設計・運用のプロジェクト知見 | ACE Playbook |
| `/retrospective`（本スキル） | プロセス/ツール/スキルのメタ知見（手戻り・無駄時間・Keep・過剰動作） | 作業中リポジトリの観測台帳への記録 → 閾値到達で Issue 昇格（既定は承認を待たずに起票。`RETROSPECTIVE_FILING=ask` で承認待ち） |

- ワークフローチェーンの末尾に位置する: `/merge-cleanup` → `/ace-curate` → `/retrospective`
- **別スキル**として独立しているため、PR を伴わない作業（調査・ドキュメント整理・障害対応など）の後にも単独で呼べる
- プロジェクト固有のコード知見が見つかった場合は本スキルで扱わず、`/ace-curate`（または ACE Playbook への追記）へ回す

## 実行ポリシー

- **毎回実施・問いかけなし**: チェーン末尾に到達したら「振り返りを実施しますか？」と確認せずそのまま実施する（ノンストップフロー整合。起票も既定では確認を挟まない — [references/filing.md](references/filing.md)「承認と起票」）
- **read-only**: 振り返り工程ではファイル編集・コミット・Issue 作成を行わない（記録・起票は振り返りを終えてからの別工程）。書き込みが発生するのは、観測台帳への定型記録（作業中リポジトリでの台帳の作成・エントリ追記・Count 更新・[旧経路 Issue の取り込み](references/legacy-intake.md)。下記「観測の記録」）と、既存確認を完了した提案を起票する段（既定は承認を待たない。`RETROSPECTIVE_FILING=ask` のときだけユーザー承認後）だけ
- **ノイズ対策は台帳の閾値と提案の閾値で行う**（下記）。実施頻度で絞らない
- **冒頭で入口規範の逆戻りを検査する**: `FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/workflow-doctor.sh" --root "$(git rev-parse --show-toplevel)" --offline` を回し、FAIL があれば観察チェックリストの 4（構造対策の余地）の観測として拾う（正本は `/workflow-doctor`。read-only なので実行ポリシーに反しない）

### 条件付きで読む references

本文は毎回通る本線だけを持つ。次の条件に当たったときだけ、該当ファイルを読んでから進む。

| 読む条件 | ファイル | 内容 |
| --- | --- | --- |
| 提案が 1 件以上ある（閾値到達・特急レーン・台帳へ書き込めないリポジトリでの提案） | [references/filing.md](references/filing.md) | 起票前の既存確認（必須）・承認と起票 |
| 閾値到達エントリの昇格先を決める・`promoted` / `mitigated` のエントリへ再発を記録する・昇格を見送る | [references/promotion.md](references/promotion.md) | 起票先の分岐・再発時の Issue 対応・`mitigated` と `active` への復帰条件 |
| `ff-effort` ブロックを持つ Issue がこのセッションでマージされた、または前回の集計から `ff-effort` 付き Issue が増えた | [references/effort.md](references/effort.md) | 見積もり乖離の記録帯・集計レポートの実行 |
| SSOT リポジトリで実行する（旧版が起票した `[observation]` Issue の残件は同ファイル手順 1 の検索で確かめる） | [references/legacy-intake.md](references/legacy-intake.md) | 旧経路の残件の取り込み |
| hook を変更する・自動発火の挙動を確かめる・入れ子の非対話起動を組む | [references/auto-trigger.md](references/auto-trigger.md) | 事前注入 / Stop fallback の判定規則とホスト別の挙動 |

## ask / off モード（保険）

毎回実施がノイジーだった場合に、実施前確認式（`ask`）または自動発火の無効化（`off`）へ切り替えられる。`ask` / `off` は環境変数用の値で、`off` は `0` / `false` / `no` / `none` / `disabled` も大文字小文字と空白を無視して受け付ける。**振り返りに入る前に、必ず最初にモードを判定する**:

1. 利用者が本スキルを明示指定した → 環境変数に関係なく実施する（引数 `ask` の場合だけ ask モード）
2. Stop hook から自動発火した → 継続プロンプトに指定されたモードに従う
3. hook 外のチェーンから暗黙に実行する場合は環境変数を実測する（エージェントは env を自動では観測できないため、この確認を省略しない）:

```bash
printenv RETROSPECTIVE_MODE
```

出力が `ask` なら ask モード、`off` または上記の別名なら自動発火のみ無効。未設定（空）・それ以外の値なら既定モード。

- **ask モード**: 実施前に「セッション振り返りを実施しますか？」と確認し、承認された場合のみ実施する
- **off モード**: 事前注入と Stop fallback はどちらも動作せず、本スキルの自動振り返りを実施しない。利用者が明示指定した場合だけ実行する
- **既定モード**: 上記のとおり問いかけなしで毎回実施する

`RETROSPECTIVE_MODE` は**実施**のスイッチで、**起票**のスイッチは `RETROSPECTIVE_FILING`（`ask` で承認待ち式。判定手順と既定の自動起票は [references/filing.md](references/filing.md)「承認と起票」手順 2）。2 つは独立しており、`RETROSPECTIVE_MODE=ask` を設定しても起票は既定の自動のままになる

## 自動発火（事前注入 + Stop fallback）

対応ホストでは `hooks/retrospective-context.sh` が UserPromptSubmit の `additionalContext` として本スキルの実行契約を応答生成前に注入する。利用者が本スキルを明示指定しなくても、最初の応答で次の順に判定する。

発火の条件は **ワークフローチェーンの末尾に到達したターンであること**（Issue `#1612`）。チェーン末尾とは、同じターンで次のいずれかを**実行した**ターンを指す: (a) `/merge-cleanup` または `/ace-curate`、(b) コマンド位置の `gh pr merge`、(c) 利用者による `/retrospective` `/merge-cleanup` `/ace-curate` の明示指定。判定するのは**実行**であって成否ではない（失敗した `/merge-cleanup` こそ振り返る価値がある）。PR を伴わない作業の締めと、hook が走らない grok CLI のチェーン末尾では `/retrospective` を明示起動する。

1. このターンがチェーン末尾に到達した → 本文の観察チェックリストに沿って振り返りを実施し、最終応答へ結果を含める
2. チェーン末尾ではない（質問・設計相談・承認待ち・外部状態待ち・作業途中・background task の完了通知）→ **振り返りについて何も書かない**。節も状態行も出さない。Stop hook が判定できずに継続を要求してきたときだけ、提案を作らず `振り返り: 今回は作業完了前のため対象外` と報告する
3. Stop fallback の継続プロンプトを受けたら、その指示に従って最終応答を出し直す。自分で hook を再実行したり marker を作ったりしない

## 観察チェックリスト

セッションのログ・作業履歴を振り返り、以下を確認する:

0. **promoted × open の突き合わせ（台帳の読み戻し）** — 観測を拾う**前**に、台帳の `Status` が `promoted` かつ昇格先 Issue が open のエントリを列挙し、そのセッションの事象と 1 件ずつ突き合わせる。再発していれば記録手順 2（`Count` +1・観測メモ 1 行）に加え、[references/promotion.md](references/promotion.md) が定める promoted 再発時の動作（open → 再発の実測をコメント追記）を発火させる（無いと再発の計上が「実行者が気付くこと」に依存し、`Count` が閾値へ届かなくなる）。列挙は `/knowledge-lookup` の `--promoted-open` で行う（Issue state の確認まで含む。gh が使えない回は state を `未確認` として全 promoted を出す）:

   ```bash
   FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT:?プラグインルートを先に解決すること}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/knowledge-lookup.sh" --root "$(git rev-parse --show-toplevel)" --promoted-open
   ```

   スクリプトへ到達できない回の代替（state は付かないので、列挙した Issue を `gh issue view` で個別に確かめる）:

   ```bash
   sed -n '/^### OBS-/h; /^| Status | promoted/{x;p;}' docs/08-knowledge/OBSERVATIONS.md
   ```

1. **品質ゲートの実行回数と重複・競合** — 同じ品質ゲート（レビュー・検証スイート等）を何度も回していないか。並行ビルド中の作業ツリー変更のような競合が起きていないか
2. **レビュー指摘 → fix の手戻りループ** — そのうちスキル/テンプレの指示不足で防げたものはないか
3. **stale な生成物・キャッシュの誤読** — 前回実行のレビュー結果、`.next/types` 等の古い生成物を読んで誤診しなかったか
4. **ツール/スクリプトのエラーからの復旧に要した回り道** — 構造対策（ゲート化・スクリプト修正・文言追加）の余地はないか
5. **待ち時間の活用漏れ** — バックグラウンド実行中に並行で進められた作業を遊ばせなかったか
6. **再現価値のある成功パターン（Keep）** — このセッションで実測して効いたプロセス/ツールの使い方のうち、スキル・テンプレ・hook へ定着させれば次回以降も再現するものはないか（プロジェクト固有のコード・設計知見はここで拾わず ACE 側へ回す）
7. **過剰動作** — 不要なスキル発火・過剰な確認・同じ検証の回しすぎ・hook の重複動作・過剰な出力など、「足りない」ではなく「やりすぎ」で失った時間はないか（自動化は増える一方で削る力学が働きにくい。削減候補もここで拾う）
8. **見積もりの当否** — `ff-effort` ブロックを持つ Issue がこのセッションでマージされた場合は、[references/effort.md](references/effort.md) の「見積もり乖離の記録帯」で予定と実績の乖離率を判定し、過小・当たり・過大の 3 方向すべてを記録する。それとは独立に、前回の集計から `ff-effort` 付き Issue が増えていれば同ファイルの「集計レポートの実行」を回す

## 観測の記録 — 観測台帳（起票の前段バッファ）

チェックリストで拾った実測（Problem / Keep）は、Issue として直接起票せず、まず**観測台帳**へ記録する。台帳は**作業中のリポジトリ**の `docs/08-knowledge/OBSERVATIONS.md`（ACE Playbook と同じ場所。リポジトリごとに 1 つ持つ）。Issue トラッカーを蓄積バッファに使うと一回性の観測まで Issue になり重複起票が構造化するため、Issue は閾値に到達した再発と重大例外だけに絞る。

### 台帳は引く store でもある（読み出し経路）

台帳は本スキルが書く store であると同時に、実装中・レビュー中に引く store である。読み側の入口は、着手前の `/knowledge-lookup`（`active` だけが未対策の落とし穴で、`promoted` / `mitigated` は対策あり。読み方の正本は同スキル）と、振り返りの観察チェックリスト第 0 項の 2 つで、引く手順は本スキルに複製しない。導入先での読み側の配線（`CLAUDE.md` / `AGENTS.md` への記載）は `/ace-setup` Step 4 の責務なので、台帳を作成したときは報告に「読み側の配線は `/ace-setup` Step 4」を添える。

### 記録の前に base の先行を照合する

台帳は**デフォルト統合ブランチの共有文書**で、`/retrospective` はそこへ直接 commit + push する。並行セッションが先に更新していると、同一性判定・`Count` +1・OBS ID 採番がいずれも古い台帳から決まる。push の non-fast-forward は**最終境界であって検出点ではない**（弾かれた時点で記録内容は作られており、`Count` が二重に増えうる）。

**記録手順 0 より前に照合する。** 台帳から決まる値（同一性判定の対象・`Count`・`Last`・OBS ID）は `/ace-curate` の「共有値の確定前ガード」と同じく base の先行を見てから決める。fetch 失敗・ref 解決不能・diverge は stale 値へ fallback せず停止する。

```bash
default_ref="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD)" || {
  echo "origin/HEAD を解決できません（git remote set-head origin -a を実行してください）" >&2
  exit 1
}
[[ "$default_ref" == origin/* ]] || { echo "default branch ref が不正です: $default_ref" >&2; exit 1; }
default_branch="${default_ref#origin/}"
ledger_status="$(git status --porcelain --untracked-files=all -- ":(top)docs/08-knowledge/OBSERVATIONS.md")" || {
  echo "台帳の状態を確認できません（git status が失敗。stale 値で記録内容を決めない）" >&2
  exit 1
}
[[ -z "$ledger_status" ]] || {
  echo "台帳に未コミットの変更があります（記録の前にコミットするか退避してください）" >&2
  exit 1
}
if ! _fetch_err="$(git fetch origin "+refs/heads/${default_branch}:refs/remotes/origin/${default_branch}" 2>&1 >/dev/null)"; then
  _fetch_err="$(sed -E 's#(://)[^/[:space:]]*@#\1***@#g' <<<"${_fetch_err:-（原因は出力されませんでした）}")"
  echo "origin/${default_branch} を取得できません（stale 値で記録内容を決めない。認証・通信・remote 設定を確認）: ${_fetch_err}" >&2
  exit 1
fi
git rev-parse --verify --quiet "refs/remotes/origin/${default_branch}" >/dev/null || {
  echo "remote-tracking ref を解決できません: origin/${default_branch}" >&2
  exit 1
}
git merge-base --is-ancestor "origin/${default_branch}" HEAD || {
  echo "origin/${default_branch} が先行しています。取り込んでから記録をやり直してください" >&2
  exit 1
}
```

fetch 失敗の停止メッセージには git が出した原因を付ける（remote URL の資格情報部だけ `***` へ伏せる）。原因を振り返り結果・台帳へ転記するときは記録手順 6 の機微情報の規律が重ねて効く。

**先行していたときの復帰は「取り込んでから記録を作り直す」**（「既存の観測へ `Count` を足す」はその結果であって別の分岐ではない。照合点で止まった回は、まだ何も作っていないので手順 0 へ進むだけになる）:

1. `git pull --ff-only` で取り込む。ff できない（diverge している）なら押し切らず停止し、記録できなかった事実を振り返り結果で報告する。`--force` / `--force-with-lease` で先行セッションを上書きしない。`--rebase` / merge で取り込まない — ff-only だけが「取り込んだ後の台帳 = origin の状態」を担保し、作りかけの記録内容がローカルに生き残るのを防ぐ
2. **記録手順 0 からやり直す** — 取り込んだ台帳に対して手順 1 の同一性判定を引き直す。並行セッションが同じ主張を既に記録していれば手順 2（`Count` +1・`Last` 更新・観測メモ 1 行）へ、無ければ手順 3（新規追記）へ落ちる。同じ主張へ新規エントリを起こさず、既に +1 された `Count` へ重ねて +1 もしない（「Count の単位」の上限は、やり直しても 1 回のまま）
3. 新規追記になる場合、OBS ID は**取り込んだ後の**台帳の最大連番 +1 で採番する（着手時に決めた連番を持ち越さない）
4. 取り込んで作り直した事実を、記録内容と併せて振り返り結果で報告する

台帳自身に未コミットの変更があって止まった回は**復帰可能**である。その変更をコミットするか退避してから照合をやり直す（他作業の途中編集を `knowledge:` コミットへ巻き込まないための停止で、障害ではない）。

復帰できないまま停止した場合（ff できない・fetch できない・ref を解決できない・default branch を解決できない）は台帳へ書かず、観測を振り返り結果の報告に残す。**ただし「提案の閾値」は通常どおり適用する** — 台帳はローカルに読めており累計は成立しているので、「台帳へ書き込めないリポジトリ」の閾値の免除は受けない（免除は台帳そのものが持てないリポジトリの規定である）。

デフォルト統合ブランチ以外に居る回は、記録の前にそのブランチへ戻る（直 push は feature ブランチからは成立せず、base が進んでいなければ照合も素通りするため）。

> **`/ace-curate` との述語差（意図的）**: clean tree の検査を**台帳のパスへ絞っている**。台帳の書き込みは 1 ファイルの単独コミットで commit を pathspec へ固定しているため、作業ツリー全体の clean を要求すると、作業中に単独実行した振り返りが先行の無い状態でも記録できなくなる。base の先行を見る向きは `/ace-curate` と同一。

### 記録手順

上「記録の前に base の先行を照合する」のフェンスを通してから手順 0 へ入る。照合を飛ばすと、以下の手順が決める値（同一性判定の対象・`Count`・`Last`・OBS ID）がすべて古い台帳から決まる。

0. **台帳の実在確認と作成**: `docs/08-knowledge/OBSERVATIONS.md` が無ければ、固定した plugin root の `${FF_DEV_TOOLKIT_ROOT}/docs-template/08-knowledge/OBSERVATIONS.md` をコピーして作成する（`docs/08-knowledge/` が無ければ併せて作る）。作成は定型書き込みで承認不要だが、作成した事実を振り返り結果で報告する。`docs/` が無い・git 管理外・書き込み権限が無いなど台帳をコミットできないリポジトリでは作成せず、観測を振り返り結果の報告に残すだけにする（後述「台帳へ書き込めないリポジトリ」）
1. 台帳を grep し、同じ主張のエントリを探す。同一性は「読者が取る実行可能なアクションが同一か」で判定する（ACE の新規性バーと同じ基準。文言や事例が違っても導かれる行動が同じなら同一エントリ）
   - **Jev への切替（`FF_JEV_MODE`・既定 off・ADR-059）**: `FF_JEV_MODE=on` のときだけ、候補エントリごとに `scripts/jev/jev-decide.sh retro`（質問は `/ace-curate` の新規性判定と同じ `questions/same-action.json`）を先に呼んでよい。**exit 0 のときだけ**判定を採り（p ≥ 0.5 なら手順 2、全候補が p < 0.5 なら手順 3）、exit 10 / 11 / 12 は自分で判定する（二重走行しない）。exit 2 / 64 / 69 は黙って落とさず止めて直す。呼び出し形の正本は `${FF_DEV_TOOLKIT_ROOT}/scripts/jev/README.md` §切替
2. **既存エントリあり** → `Count` を +1、`Last` を今日へ更新し、観測メモを 1 行追記する（単位は下「Count の単位」。`Status` が `archived` のエントリが再発したら `active` へ戻す。`Status` が `mitigated` のエントリは再発だけでは戻さず、[references/promotion.md](references/promotion.md) の「`active` への復帰条件」に当たるときだけ戻す）
3. **既存エントリなし** → 台帳のエントリ形式（台帳ファイル冒頭に定義）で新規エントリを末尾へ追記する
4. Keep の振り分け: ツールキットのスキル/テンプレ/hook、またはそのリポジトリの手順・テンプレへ定着させる価値のある成功パターンだけを `Kind: keep` で記録する。プロジェクト固有のコード・設計知見は台帳に書かず ACE 側へ回し、アクションに繋がらない Keep は記録しない（定着提案にも ACE 知見にも変換できない観測を溜めない）
5. Problem は「X すると Y の手戻りが起きる → Z せよ」という知見の形で書く。`Count` の意味論は下「Count の単位」が正本
6. **機微情報は台帳エントリ・観測メモ・昇格 Issue 本文へも引用しない**（提案本文と同じ規律 — 資格情報・トークン・個人情報・本番ホスト名は値を伏せて事象だけを書く）

#### Count の単位

`Count` は**計上する観測メモ行の累計**である（初回の記録 = 1。累計 3 回 = 計上メモ 3 行目）。昇格閾値の入力そのものなので、行数と事象の多重度を混ぜない。

- **1 行 = 1 回**: 1 行へ「前景で 2 回」のように複数回を畳んでも、その行は 1 回として数える。多重度は行の叙述であり、乗数ではない
- **同一セッション・同一エントリは 1 回**: 1 回の振り返り実行で、同じエントリへ計上する観測は最大 1 行（Count +1）。同じ原因がセッション内で繰り返した場合は 1 行に畳む。この上限は当該振り返りが実測した観測にだけ掛かり、旧経路の Issue 取り込み（[references/legacy-intake.md](references/legacy-intake.md)）と、Count を動かさない注記（対策が効いた実測・昇格記録）には掛けない
- **既存エントリは遡及しない**: 過去の `Count` を、行内の「N 回」叙述から足し直したり、同一セッションの反復を遡って減らしたりしない。過去の値は当時の昇格判断の入力であり、後から単位を変えると既に起票した Issue の根拠が動く

### 書き込み（定型コミット）

- 台帳へ直接追記し、`knowledge:` prefix の台帳単独コミットとしてデフォルト統合ブランチへ commit + push する（`/ace-curate` の Playbook 直コミットと同格の定型書き込み。承認は不要だが、記録した内容は振り返り結果で必ず報告する）。コミットは `git commit -- docs/08-knowledge/OBSERVATIONS.md` の形で**台帳の pathspec へ固定する**（`git add` + pathspec 無しの `git commit` にしない — 索引に載った無関係な変更が単独コミットへ紛れ込んで直 push されるのを、この形だけが防ぐ）。デフォルト統合ブランチへ直接 push できないリポジトリ（ブランチ保護・commitlint 等）では、そのリポジトリで ACE Playbook の直コミットに使っている経路（PR 化等）に揃える
- push が non-fast-forward で拒否されたら、上「記録の前に base の先行を照合する」の復帰手順へ戻る — `git pull --ff-only` で取り込み、**記録手順 0 から記録内容を作り直す**。OBS ID の採番し直しだけで push を再試行しない（照合から push までの間に同じ主張が別セッションで記録されていれば、同一性判定を引き直さない限り重複エントリが残る）。これは**最終境界**であって検出点ではない（検出点は上の照合）
- **ローカルに未 push のコミットがある回は、それらも同じ push で統合ブランチへ送られる**。台帳のコミットを単独に保つのは commit の pathspec だけで、push の粒度はブランチである。デフォルト統合ブランチ上に意図しないローカルコミットが無いことを記録の前に確かめる（照合はこの状態を止めない — ローカル先行は base の先行ではないため）
- **台帳へ書き込めないリポジトリ**（`docs/` を持たない・git 管理外・書き込み権限が無い）: 記録せず、観測を振り返り結果の報告に残す。このリポジトリでは閾値の蓄積が働かないため、提案は従来どおり実測ベースで出してよい（「提案の閾値」参照）
- 導入先から SSOT や配布元へ観測を Issue で受け渡す経路（`[observation]` 接頭辞の受け渡し便）は**廃止**した。観測は作業中リポジトリの台帳で閉じ、他リポジトリへ渡すのは閾値到達後の起票だけにする。旧版が残した `[observation]` Issue は、SSOT で実行するときだけ [references/legacy-intake.md](references/legacy-intake.md) に従って取り込む
- 台帳の Markdown 本文へ script で文字列パッチを当てる場合は [Markdown 文字列パッチ規律](../../docs-template/05-operations/deployment/markdown-patch-discipline.md)に従う

### 昇格閾値と特急レーン

- **昇格閾値の判定対象は `Status` が `active` のエントリに限る**（`promoted` / `archived` / `mitigated` は判定に掛けない — いずれも「これ以上昇格提案を出さない」と決着済みの状態で、決着の理由だけが違う）
- エントリの `Count` が**累計 3 回**に到達し、対応 Issue が未リンク（`Issue | なし`）なら、Issue 昇格を提案する（[references/filing.md](references/filing.md) の規定に従って起票し — 既定は承認を待たない — Issue 本文へ台帳の観測履歴を転記、エントリの `Status` を `promoted`・`Issue` をリポジトリ修飾の発行番号 `owner/repo#N` へ更新する）。起票先の分岐・`promoted` / `mitigated` の再発・見送りの書き戻しは [references/promotion.md](references/promotion.md)
- `Kind: keep` の閾値到達は Issue ではなく**定着提案**（スキル・テンプレへの文言追加・手順化）として出す
- 昇格の判定と提案は、台帳を更新したリポジトリで、その更新と同じセッションで行う（台帳の更新と同じセッションで気付ける）
- **特急レーン**: 一回の観測でも重大なもの（データ破壊・広範な作業停止・セキュリティ）は閾値を待たずに起票を提案してよい。その場合も台帳へ記録し、提案に特急である理由を明示する。起票の実行は通常の昇格と同じく [references/filing.md](references/filing.md)「承認と起票」の規定に従う（既定は承認を待たない。重大さの判断は理由の明示で利用者に見せ、起票は close で戻せる可逆操作として扱う）
- 台帳の掃除: `Last` から 180 日を超えて `Count` が 1 のままのエントリは `Status` を `archived` へ変更してよい（定型書き込み）

## 提案の閾値（ノイズ対策の本体）

提案として出すのは、観測台帳を経由した昇格・定着・特急の提案、および台帳へ書き込めないリポジトリでの従来の起票である。いずれも以下をすべて満たすものだけ:

- **実測に限る**: このセッションで実測した手戻り・無駄時間、または台帳に実測として積まれた観測履歴（旧経路からの取り込み分・`Kind: keep` の成功パターンを含む累計）だけを根拠にする。一般論・仮説だけの提案は禁止（「〜かもしれない」「一般的には〜すべき」は出さない）
- **最大 3 件**。3 件を超える候補がある場合は効果の大きい順に絞る
- 閾値未達の観測は提案として出さない。台帳への記録と報告だけで足りる — 台帳がある以上、記録すれば忘れられない（台帳へ書き込めないリポジトリだけがこの限定の対象外で、従来どおり提案してよい）
- 各提案に **起票先 repo** と **期待効果**（何が速く/正確になるか）に加え、**既存確認**（重複していないことの根拠）と **付与予定ラベル** を添える（必須欄の正本は下の出力形式）
- **提示する前に** [references/filing.md](references/filing.md) の「起票前の既存確認」を実施し、起票先 repo の既存 Issue 検索まで済ませてから提示する。ヒットした Issue が提案の方針・制約に矛盾する場合は、追記へ切り替えるだけでは足りない — 方針側の変更提案であることを明示するか、提案そのものを取り下げる
- **機微情報を提案本文へ引用しない**。資格情報・トークン・個人情報・本番ホスト名は、値を伏せて事象だけを記述する

**閾値は発火点であり、発火時に取った判断は状態として台帳へ書き戻す。** 放置すると次の到達で同じ判断を一から再演する。昇格を見送った判断は `mitigated` として書き戻す（ACE Playbook の件数上限を統合・抽象化へ回す ADR-047 と同じ原則で、閾値を緩めることでは代替できない）。

該当する候補が無ければ、次の 1 行だけで終了する（提案をひねり出さない）:

```text
振り返り: 改善候補なし
```

提案する候補は無いが観測の記録・取り込みを行った場合は、この 1 行に記録結果を足して報告する（例は下の出力形式の末尾）。

## 出力形式（提案がある場合）

```text
## セッション振り返り

1. [提案タイトル]
   - 実測: [このセッションで実際に起きたこと（何にどれだけ手戻り/時間を要したか）]
   - 提案: [変更内容（スキル文言追加・ツール修正・ゲート化など）]
   - 既存確認: [何を grep / 検索して重複・方針矛盾なしと判断したか。重複時は追記先への切替を明記]
   - 起票先: [owner/repo]
   - 付与予定ラベル: [type / priority（付与しない場合は「なし」と理由）]
   - 期待効果: [何が速く/正確になるか]

2. ...（最大 3 件）

起票: [owner/repo#N（新規）/ owner/repo#M へ再発コメント追記 / 見送り（理由）— 提案ごとに 1 行]
```

`起票:` 行は既定モード（`RETROSPECTIVE_FILING` 未設定）で、同じ応答内で実行した起票・追記の結果を書く（結果を書かずに提案だけで終えない）。`RETROSPECTIVE_FILING=ask` のときは `起票:` 行の代わりに `承認いただければ起票します。` で終え、承認後に結果を報告する（ask モードでも包括指示の例外で同じ応答内に起票した場合は、既定と同じく `起票:` 行で結果を書く）。

`既存確認:` 欄は [references/filing.md](references/filing.md) の「起票前の既存確認」を実施してから記入する（実施していない提案は提示しない）。昇格提案では、根拠となる台帳エントリの OBS ID と Count を `実測:` 欄へ併記する。

提案が無く観測の記録・取り込みだけを行った場合の報告例（`振り返り:` で始める。契約ゲートが 1 行報告の正本を text フェンスから導出するため、この例示は言語タグなしフェンスに置く）:

```
振り返り: 観測記録 OBS-012 (+1, Count 2) / OBS-031 (新規)。改善候補なし
```
