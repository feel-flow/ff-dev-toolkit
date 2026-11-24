---
name: retrospective
description: ワークフローチェーン末尾（既定 /merge-cleanup → /retrospective。B/C 知見がある PR だけ前に /ace-curate）で毎回振り返りを実施し、プロセス・ツール・スキルのメタ知見（手戻り・無駄時間・Keep・過剰動作）を観測台帳へ記録して、閾値到達の再発から改善提案を最大 3 件出す。「振り返り」「retrospective」「セッション振り返り」「プロセス改善の提案」と言われたとき、または PR を伴わない作業の締めにも単独で使用。
---

# /retrospective — セッション振り返り（観測の記録と改善提案）

GitHub MCP の raw-file 入力は[共通契約](../ace-curate/references/curate.md#github-file-input)に従う。

## ASDD 2.0 設定がある場合

最初に[共通設定契約](../asdd-init/references/configuration.md)を読み、`scripts/asdd/config.mjs` の `loadConfig(root)` で `.asdd/config.json` を検証し、合意済みの構成・機能スイッチを優先する（未設定は従来互換、不正設定は停止して診断）。`features.retrospective=false` では自動実行・催促・対象外報告を行わない（明示依頼時は設定を変えず単発実行）。

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

## 位置づけと実行ポリシー

- **責務分離**: 既定チェーンの末尾に位置する: `/merge-cleanup` → `/retrospective`（`/ace-curate` は A〜D で B / C の候補がある PR だけ挟む）。コード知見は本スキルで扱わず、`/ace-curate`（または ACE Playbook への追記）へ回す（PR なしでも単独実行可）。
- **毎回実施・問いかけなし**: チェーン末尾に到達したら確認せず実施する。振り返り工程ではファイル編集・コミット・Issue 作成を行わない。書き込みが発生するのは、観測台帳への定型記録と、既存確認・送信境界を通過した提案の起票・旧経路 Issue の処理だけ（承認境界は [references/filing.md](references/filing.md#外部公開の承認境界全モード共通)）。
- **入口規範検査**: 冒頭で `FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/workflow-doctor.sh" --root "$(git rev-parse --show-toplevel)" --offline` を実行し、FAIL はチェックリスト 4 に記録。

### 条件付きで読む references

| 読む条件 | ファイル | 内容 |
| --- | --- | --- |
| 提案が 1 件以上ある（閾値到達・特急レーン・台帳へ書き込めないリポジトリでの提案） | [references/filing.md](references/filing.md) | 既存確認・承認と起票・出力形式 |
| 閾値到達エントリの昇格先を決める・`promoted` / `mitigated` のエントリへ再発を記録する・昇格を見送る・発行済み Issue の対策完了を照合する | [references/promotion.md](references/promotion.md) | 状態遷移・再発 |
| `ff-effort` ブロックを持つ Issue がこのセッションでマージされた、または前回の集計から `ff-effort` 付き Issue が増えた | [references/effort.md](references/effort.md) | 乖離の記録帯・集計 |
| SSOT リポジトリで実行する（旧版が起票した `[observation]` Issue の残件は同ファイル手順 1 の検索で確かめる） | [references/legacy-intake.md](references/legacy-intake.md) | 旧経路の取り込み |
| hook を変更する・自動発火の挙動を確かめる・入れ子の非対話起動を組む | [references/auto-trigger.md](references/auto-trigger.md) | 自動発火規則 |
| 台帳記録・knowledge 保留の回収・base 先行・Count の確認 | [references/ledger.md](references/ledger.md) | 照合・保留合流・送信・Count・時間損失 |

## ask / off モード（保険）

**振り返りに入る前に、必ず最初にモードを判定する**: (1) 利用者が本スキルを明示指定した → 環境変数に関係なく実施する（引数 `ask` のみ確認式）、(2) Stop fallback は継続プロンプトに従う、(3) それ以外は環境変数を実測する:

```bash
printenv RETROSPECTIVE_MODE
```

出力が `ask` なら ask モード、`off` または上記の別名なら自動発火のみ無効（別名: `0`/`false`/`no`/`none`/`disabled`）。**off モード**: 事前注入と Stop fallback はどちらも動作せず、明示指定のみ実行。`RETROSPECTIVE_FILING`（`ask` で起票承認待ち）は独立スイッチ。

判定直後に `finish.sh knowledge-commit status` の `KNOWLEDGE_PENDING=` を確認し、1 以上なら振り返りを実施しない回（off モード・ask で断られた回）でも `commit` → 送信を行う（[ledger.md](references/ledger.md#保留の合流と送信経路)）。実施回は下の `commit` が観測台帳と 1 コミットに畳む。

## 自動発火（事前注入 + Stop fallback）

`hooks/retrospective-context.sh` が UserPromptSubmit の `additionalContext` として契約を注入する。発火条件はワークフローチェーンの末尾に到達したターンであること（`/merge-cleanup` / `/ace-curate` / `gh pr merge` / 明示指定を実行したターン。詳細: [references/auto-trigger.md](references/auto-trigger.md)）。

<!--36a95c0d9c6b5768-->
分類: 非操作: 発火条件の説明で merge 指示ではない。MCP 経路完了時も明示 /retrospective で進む

1. このターンがチェーン末尾に到達した → 振り返りを実施し最終応答へ含める
2. チェーン末尾ではない → 振り返りについて何も書かない（Stop hook が継続要求した回のみ `振り返り: 今回は作業完了前のため対象外` と報告）
3. Stop fallback 受信時は指示どおり応答を出し直す。自分で hook を再実行したり marker を作ったりしない

## 観察チェックリスト

0. **promoted × open の突き合わせ（台帳の読み戻し）** — 観測前に照合し、再発・**発行済み Issue の完了照合**（closed 含む）は [promotion.md](references/promotion.md) へ:

   ```bash
   FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT:?プラグインルートを先に解決すること}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/knowledge-lookup.sh" --root "$(git rev-parse --show-toplevel)" --promoted-open
   # MCP raw は同じ --github-input /absolute/index.json を付ける（不足は未確認、offlineは読まない）
   ```

1. 品質ゲートの重複・競合
2. レビュー指摘 → fix の手戻り（指示不足で防げたもの）
3. stale 生成物・キャッシュ誤読
4. エラー復旧の回り道
5. 待ち時間の活用漏れ
6. **再現価値のある成功パターン（Keep）**
7. **過剰動作**（不要な発火・確認・重複検証）
8. 見積もりの当否（`ff-effort` 付き Issue マージ時は [references/effort.md](references/effort.md) の記録帯で 3 方向判定）
9. 参照の効果 — [正本](../../docs-template/05-operations/deployment/git-workflow.md#着手前の-playbook-参照ace-reuse)で二系統・新クラス移行前の再検索・適用／見落としを点検する。

## 観測の記録 — 観測台帳（起票の前段バッファ）

実測（Problem / Keep）は直接起票せず、まず**観測台帳**へ記録する。台帳は**作業中のリポジトリ**の `docs/08-knowledge/OBSERVATIONS.md`。

### 台帳は引く store でもある（読み出し経路）

作成時は報告に「読み側の配線は `/ace-setup` Step 4」を添える。

### 記録の前に base の先行を照合する

**記録手順 0 より前に照合する。** [references/ledger.md](references/ledger.md) の照合フェンス（clean → 明示 refspec fetch → 祖先検査。失敗は停止）を通し、先行時は取り込んでから記録を作り直す（`git pull --ff-only origin <default-branch>` で取り込む。`--force` / `--force-with-lease` で先行セッションを上書きしない、`--rebase` / merge で取り込まない。OBS ID は**取り込んだ後の**台帳の最大連番 +1 で採番する）。台帳自身に未コミットの変更があって止まった回は**復帰可能**である。復帰できないまま停止した場合は台帳へ書かず報告に残す（**ただし「提案の閾値」は通常どおり適用する**）。保留中の知見ブランチは維持する。

### 記録手順

上「記録の前に base の先行を照合する」のフェンスを通してから手順 0 へ入る。

0. `docs/08-knowledge/OBSERVATIONS.md` 不在時は `${FF_DEV_TOOLKIT_ROOT}/docs-template/08-knowledge/OBSERVATIONS.md` をコピーして作成する（書込不可 repo は報告のみ）
1. 台帳を grep して同一主張を確認（`FF_JEV_MODE=on` は [triage](references/ledger.md#triage) を先行実行）
2. 既存あり → `Count` +1・`Last` 更新・観測メモ 1 行追記（**1 行 = 1 回**・**同一セッション・同一エントリは 1 回**・**既存エントリは遡及しない**。`archived` 再発は `active` 復帰、`mitigated` は [references/promotion.md](references/promotion.md)）
3. 既存なし → 冒頭定義の形式で末尾追記（script 追記は [Markdown 文字列パッチ規律](../../docs-template/05-operations/deployment/markdown-patch-discipline.md)）
4. Keep は定着価値のある成功パターンのみ `Kind: keep`（アクションに繋がらない Keep は記録しない）、Problem は「X すると Y の手戻りが起きる → Z せよ」形式、機微情報は引用しない

### 書き込み（定型コミット）

```bash
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/check-shebang-cr.sh" || exit $?
```

`FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/finish.sh" knowledge-commit add --source obs --id <OBS-ID> --summary <要約> -- docs/08-knowledge/OBSERVATIONS.md` → `commit`（`git commit -- docs/08-knowledge/OBSERVATIONS.md` でパス固定、`/ace-curate` の保留があれば同じ `commit` が両方を 1 コミット（`knowledge: ACE-… / OBS-…`）に畳む）→ 送信（default / detached は `push`、知見ブランチは `pr`。[ledger.md](references/ledger.md#保留の合流と送信経路)）。

- push の non-fast-forward 拒否時は **記録手順 0 から記録内容を作り直す**（検出点は上の照合）。**ローカルに未 push のコミットがある回は、それらも同じ push で統合ブランチへ送られる**ため事前確認する。直 push 不可 repo はそのリポジトリで ACE Playbook の直コミットに使っている経路（PR 化等）に揃える。**台帳へ書き込めないリポジトリ**は記録せず報告に残す。

### 昇格閾値と特急レーン

**昇格閾値の判定対象は `Status` が `active` のエントリに限る**。`Count` が**累計 3 回**に到達し、対応 Issue が未リンク（`Issue | なし`）なら昇格提案（[references/filing.md](references/filing.md)、起票後 `promoted` 化、`Kind: keep` は定着提案）。昇格の判定と提案は、台帳を更新したリポジトリで同セッション内に行う。データ破壊・広範な作業停止・セキュリティは**特急レーン**で閾値待たずに提案可（見送りは `mitigated`）。

## 提案の閾値と出力形式

提案として出すのは、台帳を経由した昇格・定着・特急・単発の提案と、台帳へ書き込めないリポジトリでの起票で以下を満たすものだけ:

- **実測に限る**: このセッションで実測した手戻り・無駄時間、または台帳に実測として積まれた観測履歴だけを根拠にする。一般論・仮説だけの提案は禁止
- **最大 3 件**。3 件を超える候補がある場合は効果の大きい順に絞る。閾値未達の観測は出さない（台帳へ書き込めないリポジトリと ledger.md の単発提案だけがこの限定の対象外）
- 各提案に起票先 repo・期待効果・既存確認・付与予定ラベルを添える
- **提示する前に** [references/filing.md](references/filing.md) の「起票前の既存確認」を実施し、起票先 repo の既存 Issue 検索まで済ませてから提示する。
- **規則を足す提案には消す規則か強制する仕組みを添える**（[promotion.md](references/promotion.md)）
- **機微情報を提案本文へ引用しない**

該当する候補が無ければ、次の 1 行だけで終了する:

```text
振り返り: 改善候補なし
```

書式（6 欄 + `起票:` 行）は [references/filing.md](references/filing.md)。`RETROSPECTIVE_FILING=ask` または外部公開の承認境界で承認待ちのときは `起票:` 行の代わりに `承認いただければ起票します。` で終え、承認後に結果を報告する（記録のみは [filing.md](references/filing.md#記録だけの報告)）。
