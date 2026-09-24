---
name: retrospective
description: ワークフローチェーンの末尾（/merge-cleanup → /ace-curate の後）で毎回セッション振り返りを実施し、プロセス・ツール・スキルのメタ知見（手戻り・無駄時間・Keep・過剰動作）を観測台帳へ記録して、閾値に到達した再発から改善提案を最大 3 件出す。「振り返り」「retrospective」「セッション振り返り」「プロセス改善の提案」と言われたとき、または PR を伴わない作業の締めにも単独で使用。実測した観測が無ければ 1 行報告で終了する。
---

# /retrospective — セッション振り返り（観測の記録とプロセス・ツール改善の提案）

## ASDD 2.0 設定がある場合

最初に[共通設定契約](../asdd-init/references/configuration.md)を読み、`scripts/asdd/config.mjs` の `loadConfig(root)` で対象プロジェクトの `.asdd/config.json` を検証する。以下の従来手順より、合意済みの文書構成・機能スイッチ・ワークフローを優先する。設定なしは従来互換、不正設定は自動処理を止めて診断する。

`features.retrospective=false` のとき、ワークフローからの自動実行・起動の催促・「対象外」などの定型報告を行わない。ユーザーがこの振り返りを明示依頼した場合だけ、設定を変えず単発実行する。以下の「毎回」は設定なし、または自動振り返りを選んだ場合に限る。

セッションで**実際に起きた**ことを KPT の観点で振り返り、Problem（手戻り・無駄時間・過剰動作）と Keep（定着させる価値のある成功パターン）を観測台帳へ記録する。Issue を起票するのは原則として閾値に到達した再発だけ。確認を挟まず毎回実施し、ノイズは台帳と提案側の閾値で絞る。台帳の定型コミットは同梱 `scripts/finish.sh knowledge-commit` が行う。

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

`/ace-curate` はプロジェクト知見を ACE Playbook へ、本スキルはプロセス/ツール/スキルのメタ知見を作業中リポジトリの観測台帳へ記録し、閾値到達で Issue 昇格する。ワークフローチェーンの末尾に位置する: `/merge-cleanup` → `/ace-curate` → `/retrospective`。**別スキル**なので PR を伴わない作業の後にも単独で呼べる。プロジェクト固有のコード知見は本スキルで扱わず、`/ace-curate`（または ACE Playbook への追記）へ回す。

## 実行ポリシー

- **毎回実施・問いかけなし**: チェーン末尾に到達したら確認せずそのまま実施する（起票も既定では確認を挟まない）
- **read-only**: 振り返り工程ではファイル編集・コミット・Issue 作成を行わない。書き込みが発生するのは、観測台帳への定型記録（作成・追記・Count 更新・[旧経路 Issue の取り込み](references/legacy-intake.md)）と、既存確認を完了した提案を起票する段（既定は承認を待たない。`RETROSPECTIVE_FILING=ask` のときだけ承認後）だけ
- **冒頭で入口規範の逆戻りを検査する**: `FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/workflow-doctor.sh" --root "$(git rev-parse --show-toplevel)" --offline` の FAIL はチェックリスト 4 の観測

### 条件付きで読む references

| 読む条件 | ファイル | 内容 |
| --- | --- | --- |
| 提案が 1 件以上ある（閾値到達・特急レーン・台帳へ書き込めないリポジトリでの提案） | [references/filing.md](references/filing.md) | 既存確認・承認と起票・出力形式 |
| 閾値到達エントリの昇格先を決める・`promoted` / `mitigated` のエントリへ再発を記録する・昇格を見送る | [references/promotion.md](references/promotion.md) | 起票先・再発対応・復帰条件 |
| `ff-effort` ブロックを持つ Issue がこのセッションでマージされた、または前回の集計から `ff-effort` 付き Issue が増えた | [references/effort.md](references/effort.md) | 乖離の記録帯・集計 |
| SSOT リポジトリで実行する（旧版が起票した `[observation]` Issue の残件は同ファイル手順 1 の検索で確かめる） | [references/legacy-intake.md](references/legacy-intake.md) | 旧経路の取り込み |
| hook を変更する・自動発火の挙動を確かめる・入れ子の非対話起動を組む | [references/auto-trigger.md](references/auto-trigger.md) | 自動発火の判定規則 |
| 台帳へ記録する（照合フェンスを通す）・base が先行して止まった・Count の数え方に迷う | [references/ledger.md](references/ledger.md) | 照合フェンス・Count の単位・根拠 |

## ask / off モード（保険）

`ask`（実施前確認式）/ `off`（自動発火の無効化。`0` / `false` / `no` / `none` / `disabled` も同義）。**振り返りに入る前に、必ず最初にモードを判定する**: 1. 利用者が本スキルを明示指定した → 環境変数に関係なく実施する（引数 `ask` の場合だけ ask モード）/ 2. Stop hook から自動発火した → 継続プロンプトのモードに従う / 3. それ以外は環境変数を実測する:

```bash
printenv RETROSPECTIVE_MODE
```

出力が `ask` なら ask モード、`off` または上記の別名なら自動発火のみ無効。未設定・それ以外の値なら既定モード。**off モード**: 事前注入と Stop fallback はどちらも動作せず、明示指定だけ実行する。

**モードを判定した直後に、保留中の knowledge 追記を確かめる**: `finish.sh knowledge-commit status` の `KNOWLEDGE_PENDING=` が 1 以上なら（`/ace-curate` が `add` までで止めた追記）、振り返りを実施しない回（off モード・ask で断られた回）でも `commit` → push を行う。実施する回は下「書き込み」の `commit` が観測台帳と合わせて 1 コミットに畳む。`RETROSPECTIVE_MODE` は**実施**、`RETROSPECTIVE_FILING` は**起票**のスイッチ（`ask` で承認待ち式）で、2 つは独立している。

## 自動発火（事前注入 + Stop fallback）

`hooks/retrospective-context.sh` が UserPromptSubmit の `additionalContext` として実行契約を注入する。発火条件はワークフローチェーンの末尾に到達したターンであること（`/merge-cleanup` / `/ace-curate` / `gh pr merge` / 利用者の明示指定を**実行した**ターン。成否ではない。全文は [references/auto-trigger.md](references/auto-trigger.md)）。

1. このターンがチェーン末尾に到達した → 振り返りを実施し、最終応答へ結果を含める
2. チェーン末尾ではない（質問・承認待ち・作業途中・background task の完了通知）→ **振り返りについて何も書かない**。Stop hook が判定できずに継続を要求してきたときだけ `振り返り: 今回は作業完了前のため対象外` と報告する
3. Stop fallback の継続プロンプトを受けたら、その指示に従って最終応答を出し直す。自分で hook を再実行したり marker を作ったりしない

## 観察チェックリスト

0. **promoted × open の突き合わせ（台帳の読み戻し）** — 観測を拾う**前**に、`Status` が `promoted` かつ昇格先 Issue が open のエントリを列挙し、そのセッションの事象と 1 件ずつ突き合わせる。再発していれば記録手順 2 に加え、[references/promotion.md](references/promotion.md) の promoted 再発時の動作を発火させる:

   ```bash
   FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT:?プラグインルートを先に解決すること}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/knowledge-lookup.sh" --root "$(git rev-parse --show-toplevel)" --promoted-open
   ```

1. **品質ゲートの実行回数と重複・競合** — 回しすぎ、並行ビルド中の作業ツリー変更などの競合
2. **レビュー指摘 → fix の手戻りループ** — スキル/テンプレの指示不足で防げたもの
3. **stale な生成物・キャッシュの誤読**
4. **ツール/スクリプトのエラーからの復旧に要した回り道** — 構造対策の余地
5. **待ち時間の活用漏れ** — 並行で進められた作業
6. **再現価値のある成功パターン（Keep）** — スキル・テンプレ・hook へ定着させれば再現するもの
7. **過剰動作** — 不要なスキル発火・過剰な確認・同じ検証の回しすぎで失った時間
8. **見積もりの当否** — `ff-effort` ブロックを持つ Issue がマージされた場合は [references/effort.md](references/effort.md) の記録帯で乖離率を判定し、3 方向すべてを記録する

## 観測の記録 — 観測台帳（起票の前段バッファ）

拾った実測（Problem / Keep）は Issue として直接起票せず、まず**観測台帳**へ記録する。台帳は**作業中のリポジトリ**の `docs/08-knowledge/OBSERVATIONS.md`。

### 台帳は引く store でもある（読み出し経路）

読み側の入口は着手前の `/knowledge-lookup` と観察チェックリスト第 0 項。台帳を作成したときは報告に「読み側の配線は `/ace-setup` Step 4」を添える。

### 記録の前に base の先行を照合する

並行セッションが先に更新していると同一性判定・`Count`・OBS ID が古い台帳から決まる。**記録手順 0 より前に照合する。** [references/ledger.md](references/ledger.md) の照合フェンス（clean な台帳 → 明示 refspec で fetch → 祖先検査。失敗は stale 値へ fallback せず停止）を通す。先行していたら「取り込んでから記録を作り直す」（`git pull --ff-only` で取り込む。`--force` / `--force-with-lease` で先行セッションを上書きしない。`--rebase` / merge で取り込まない。OBS ID は**取り込んだ後の**台帳の最大連番 +1 で採番する）。台帳自身に未コミットの変更があって止まった回は**復帰可能**である。復帰できないまま停止した場合は台帳へ書かず観測を報告に残す。**ただし「提案の閾値」は通常どおり適用する**。デフォルト統合ブランチ以外に居る回は、記録の前にそのブランチへ戻る。

### 記録手順

上「記録の前に base の先行を照合する」のフェンスを通してから手順 0 へ入る。

0. **台帳の実在確認と作成**: `docs/08-knowledge/OBSERVATIONS.md` が無ければ `${FF_DEV_TOOLKIT_ROOT}/docs-template/08-knowledge/OBSERVATIONS.md` をコピーして作成する（作成した事実を報告する）。書き込めないリポジトリでは作成せず、観測を報告に残す
1. 台帳を grep し、同じ主張のエントリを探す（同一性は「読者が取る実行可能なアクションが同一か」。`FF_JEV_MODE=on` のときだけ `scripts/jev/jev-decide.sh retro` を先に呼んでよい）
2. **既存エントリあり** → `Count` を +1、`Last` を今日へ、観測メモを 1 行追記（**1 行 = 1 回**・**同一セッション・同一エントリは 1 回**・**既存エントリは遡及しない**）。`archived` の再発は `active` へ戻す。`mitigated` は [references/promotion.md](references/promotion.md) の復帰条件に当たるときだけ戻す
3. **既存エントリなし** → 台帳のエントリ形式（台帳ファイル冒頭に定義）で末尾へ追記する（script で当てるなら [Markdown 文字列パッチ規律](../../docs-template/05-operations/deployment/markdown-patch-discipline.md)に従う）
4. Keep は定着させる価値のある成功パターンだけを `Kind: keep` で記録し、アクションに繋がらない Keep は記録しない。Problem は「X すると Y の手戻りが起きる → Z せよ」の形。機微情報は引用しない

### 書き込み（定型コミット）

台帳へ直接追記し、`knowledge:` prefix の単独コミットとしてデフォルト統合ブランチへ commit + push する（承認は不要だが、記録した内容は振り返り結果で必ず報告する）。commit は共通の書き込み口 — `FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/finish.sh" knowledge-commit add --source obs --id <OBS-ID> --summary <要約> -- docs/08-knowledge/OBSERVATIONS.md` の後に `commit` → `push`（rc 3 は保護ルールで `/ace-curate` 手順 5 と同じく PR 経由へ）。書き込み口は `git commit -- docs/08-knowledge/OBSERVATIONS.md` の形で記録したパスへ固定する。同じセッションで `/ace-curate` が `add` だけで止めた保留があれば、同じ `commit` が両方を 1 コミット（`knowledge: ACE-… / OBS-…`）に畳む。観測を記録しない回でも保留があれば `commit` → `push` を行う。

- push が non-fast-forward で拒否されたら復帰手順へ戻り **記録手順 0 から記録内容を作り直す**（採番し直しだけで再試行しない。検出点は上の照合で、push は最終境界）
- **ローカルに未 push のコミットがある回は、それらも同じ push で統合ブランチへ送られる**。意図しないローカルコミットが無いことを先に確かめる
- 直接 push できないリポジトリでは、そのリポジトリで ACE Playbook の直コミットに使っている経路（PR 化等）に揃える
- **台帳へ書き込めないリポジトリ**（`docs/` を持たない・git 管理外・書き込み権限が無い）: 記録せず、観測を報告に残す

### 昇格閾値と特急レーン

**昇格閾値の判定対象は `Status` が `active` のエントリに限る**。`Count` が**累計 3 回**に到達し、対応 Issue が未リンク（`Issue | なし`）なら Issue 昇格を提案する（[references/filing.md](references/filing.md) に従って起票し、`Status` を `promoted`・`Issue` を `owner/repo#N` へ。`Kind: keep` は**定着提案**）。昇格の判定と提案は、台帳を更新したリポジトリで、その更新と同じセッションで行う。**特急レーン**（データ破壊・広範な作業停止・セキュリティ）は閾値を待たずに提案してよい。発火時の判断は台帳へ書き戻す（見送りは `mitigated`）。

## 提案の閾値（ノイズ対策の本体）

提案として出すのは、台帳を経由した昇格・定着・特急の提案と、台帳へ書き込めないリポジトリでの従来の起票で、以下をすべて満たすものだけ:

- **実測に限る**: このセッションで実測した手戻り・無駄時間、または台帳に実測として積まれた観測履歴だけを根拠にする。一般論・仮説だけの提案は禁止
- **最大 3 件**。3 件を超える候補がある場合は効果の大きい順に絞る。閾値未達の観測は出さない（台帳へ書き込めないリポジトリだけがこの限定の対象外）
- 各提案に **起票先 repo**・**期待効果**・**既存確認**・**付与予定ラベル** を添える
- **提示する前に** [references/filing.md](references/filing.md) の「起票前の既存確認」を実施し、起票先 repo の既存 Issue 検索まで済ませてから提示する。方針に矛盾する Issue があれば方針側の変更提案と明示するか取り下げる
- **機微情報を提案本文へ引用しない**

該当する候補が無ければ、次の 1 行だけで終了する（提案をひねり出さない）:

```text
振り返り: 改善候補なし
```

## 出力形式（提案がある場合）

書式（6 欄 + `起票:` 行。最大 3 件）は [references/filing.md](references/filing.md)「出力形式」。`RETROSPECTIVE_FILING=ask` のときは `起票:` 行の代わりに `承認いただければ起票します。` で終え、承認後に結果を報告する。提案が無く記録だけを行った場合は `振り返り:` で始める 1 行に記録結果を足す（言語タグなしフェンスの例示が正本）:

```
振り返り: 観測記録 OBS-012 (+1, Count 2) / OBS-031 (新規)。改善候補なし
```
