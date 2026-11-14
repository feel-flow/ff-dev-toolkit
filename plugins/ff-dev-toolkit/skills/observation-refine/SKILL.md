---
name: observation-refine
description: Use when the retrospective observation ledger (docs/08-knowledge/OBSERVATIONS.md) has accumulated entries below the promotion threshold and needs periodic tidying. 観測台帳を定期整理する（既存 Issue への紐付け・同じ主張の統合・stale の archive・定着済み Keep の mitigated 化）。dry-run → ユーザー承認 → 適用の 3 フェーズで、観測履歴は消さず状態移行として追記する。「台帳を整理して」「観測台帳の棚卸し」「OBSERVATIONS を整理」「閾値未達の観測を見直して」「observation refine」と言われたときに使用。セッションの振り返りと観測の記録は retrospective、ACE Playbook の整理は ace-refine。
---

# /observation-refine — 観測台帳の定期整理

`/retrospective` は観測を台帳へ積み、`Count` が昇格閾値に達したエントリだけを Issue へ昇格する。閾値に届かないエントリには見直す経路が無く、対応 Issue が既に在っても紐付かず、同じ主張が別エントリへ分かれて `Count` が分散していても合流しない（Issue `#2523`）。本スキルはその側を定期的に整理する。ACE Playbook の `/ace-refine` に当たる、台帳の側の入口である。

## ASDD 2.0 設定がある場合

最初に[共通設定契約](../asdd-init/references/configuration.md)を読み、`scripts/asdd/config.mjs` の `loadConfig(root)` で対象プロジェクトの `.asdd/config.json` を検証する。以下の従来手順より、合意済みの文書構成・機能スイッチ・ワークフローを優先する。設定なしは従来互換、不正設定は自動処理を止めて診断する。

`features.retrospective=false` のとき、ワークフローから本スキルを起動しない。ユーザーが台帳の整理を明示依頼した場合だけ、設定を変えず単発実行する。

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

## 位置づけ

| | 書く | 引く | 整理する |
| --- | --- | --- | --- |
| ACE Playbook | `/ace-curate` | `/knowledge-lookup` | `/ace-refine` |
| 観測台帳 | `/retrospective` | `/knowledge-lookup` | 本スキル |

- **利用者が依頼したときだけ実行する**。ワークフローチェーンには入らず、hook からも発火しない。`/retrospective` は毎回・問いかけなしで観測を積むが、本スキルは既存エントリの状態を書き換えるので、承認を挟む
- 扱うのは 4 つの操作だけ: 既存 Issue への紐付け・同じ主張の統合・stale の archive・Keep の定着判定。昇格（起票）は扱わない — 整理の結果として昇格閾値に届いたエントリは `/retrospective` の昇格判定へ渡す
- 対象は作業中リポジトリの台帳。他リポジトリの台帳は、その整理を依頼されたときだけ書き換える

## Phase 1: dry-run（候補と根拠の算出）

**最初に、[`/retrospective` の照合フェンス](../retrospective/references/ledger.md#記録の前に-base-の先行を照合する)（反映のモードの確認を含む）を通す。台帳を読むのはその後である。** まとめるモードでは、このフェンスが止まらずに作業ツリーを書き込みの起点（最新の base + 未反映の知見）へ移す。先に dry-run を作ると、移る前の台帳で候補を決めることになる（未反映の再発で `Count` が増えたエントリを stale と出す）。フェンスが止まったら、取り込んでからここへ戻る。

1. **起票先リポジトリの Issue 一覧を取る**。起票先は[`/retrospective` の起票前の既存確認](../retrospective/references/filing.md)手順 1 と同じ決め方（ツール群の改善なら SSOT、プロジェクト固有の手順なら作業中リポジトリ）なので、両方を取る。一覧はリポジトリごとに 1 ファイル、1 行を `番号<TAB>state<TAB>タイトル` にして、リポジトリの外の一時領域へ置く:

   ```bash
   gh issue list --repo "${ISSUE_REPO}" --state all --limit 5000 --json number,state,title --jq '.[] | [.number, .state, .title] | @tsv' >"${ISSUE_LIST_FILE}"
   ```

   <!--d164851008531e02-->
   MCP: 取得値: MCP で起票先 repository の state=all の Issue 全件の number / state / title を取得（Pull Request は除く）。形式: 1 行を number<TAB>state<TAB>title にした TSV（state は open / closed）で、全 page を取り切ったものだけ保存。渡し先: observation-refine.sh report の --issues OWNER/REPO=FILE へ渡す。不足時: 取得不能・不完全な repository は空のファイルを --issues に渡し、その照合先を 未確認 として出力に残したまま dry-run を続ける。

   非 0 で終わった回の出力は使わず、**そのリポジトリには空のファイルを渡す**（スクリプトは 0 行の一覧を `未確認` として扱い、照合先として出力に残す）。取得できなかったリポジトリを `--issues` から省かない — 省くと未確認の照合先が出力から消え、残りが照合できただけで SUMMARY が `issues=ok` になる。state は大文字・小文字のどちらでも受ける。

2. **候補を算出する**（read-only。台帳は書き換えない）:

   ```bash
   FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/observation-refine.sh" report --root "$(git rev-parse --show-toplevel)" --issues "${ISSUE_REPO}=${ISSUE_LIST_FILE}"
   ```

   - `--issues` は起票先の数だけ繰り返す。`--root` は対象リポジトリのルート（その下の `docs/08-knowledge/OBSERVATIONS.md` を読む）
   - stale の基準は既定で「`Last` から 180 日を超え、かつ `Count` が 1 以下」で、プロジェクトの事情に合わせて `--stale-days` / `--stale-max-count` で変える
   - 基準日は `--today <YYYY-MM-DD>`（既定は実行日）。候補の絞り込みは `--top`（(1) で 1 エントリに出す件数）・`--min-link-score`・`--min-merge-score`・`--max-pairs` で変える。引数の一覧はスクリプト冒頭のコメントが正本
   - **既定から変えた引数は、すべて承認の提示に含める**
   - **非 0 終了は候補 0 件ではなく「まだ何も測れていない」**。stderr の対象を直して再実行し、Phase 2 へ進まない。成否は終了コードで読む（rc 0 の回も、版と実行実体を示す 1 行が stderr に出る）
   - **rc 0 でも SUMMARY の `entries` が実際のエントリ数より明らかに少ない回は、測れていない**。見出しの階層が変わった台帳（全エントリが `####`）や、本文の閉じていないコードフェンスは、読み出し器がエントリを認識できず、件数だけが減る。SUMMARY の `issues` は `ok`（全部照合できた）/ `partial`（一部の一覧が未確認）/ `unverified` / `none` で、`ok` 以外は照合が欠けている

3. **出力の節を読み、機械が決められない分を判定する**。出力の「類似」は語の重なりで候補を絞る信号で、判定ではない。エントリと Issue の本文を開いて、次の基準で採否を決める:

   | 節 | 機械が出すもの | ホストが判定すること | 採ったときの移行 |
   | --- | --- | --- | --- |
   | (1) 既存 Issue への紐付け | `active`・`Issue \| なし` の母集団と、タイトルが似た Issue | 候補の Issue を本文とコメントまで読み、**同じ事象で、その Issue の対策がこの観測の主張を解消する**か | `promoted`。`Issue` 列へ `owner/repo#N`（`Count` に関係なく） |
   | (2) 統合 | 主張が似たエントリの組と合算後の `Count` | **読者が取る実行可能なアクションが同一か**（[`/retrospective` の同一性の基準](../retrospective/references/ledger.md#count-の単位)と同じ） | 統合元を `archived`、統合先の `Count` を合算 |
   | (3) stale の archive | 基準に当たるエントリ（規則で決まる） | 残す理由があるものを外す（例: 年に 1 回しか通らない工程の観測） | `archived` |
   | (4) Keep の定着判定 | `active`・`keep`・`Issue \| なし`・閾値未達の母集団 | その成功パターンが**スキル・テンプレ・hook・手順書へ既に定着しているか**を、定着先の該当箇所を開いて確かめる | `mitigated`。`Issue` 列へ対策の所在 |
   | (5) 昇格閾値に到達済みで未リンク | 該当エントリ | 整理では扱わない | `/retrospective` の昇格判定へ渡す |

   `active` なのに `Issue` 列が埋まっているエントリは、(1)〜(5) のどの節にも入らず「状態と Issue 列が食い違うエントリ」として別に出る（統合の組にも出ない）。整理では動かさず、[`/retrospective` の状態移行](../retrospective/references/promotion.md)で `Status` を直す対象として報告する。

   **(1) 紐付けの基準**

   - 採る候補は本文とコメントまで読む。タイトルだけで無関係と分かる候補は、開かずに落としてよい。「ほか N 件」は、表示された候補に該当が無く、まだ疑いが残るときだけ `--top` を増やして見る
   - **機械の候補は補助で、主はエントリの固有の語（コマンド名・ファイル名・エラー文言）で一覧ファイルを検索すること**。類似はタイトルの語の重なりしか見ないので、対策の Issue より、その挙動を導入した Issue が上位に出やすい。「類似の候補なし」に並ぶエントリも、対応 Issue が無いことの確認ではない
   - 紐付け先にするのは**対策の Issue**だけ。次の 3 つは紐付けない
     - その挙動を導入した Issue（原因の側）
     - 観測の `First` より前に閉じた Issue（対策が在る状態で起きた観測なので、その対策は主張を解消していない。対策後の再発として扱うかは `/retrospective` の再発分岐で決める）
     - 対策が主張の一部にしか届かない Issue。主張の「→」以降のアクションが要らなくなるときだけ採る
   - `Kind` が keep のエントリは、その成功パターンをスキル・手順へ入れる Issue が在るときに紐付ける（無ければ (4) で見る）
   - closed の Issue に一致した場合も `promoted` にする。**closed だけでは `mitigated` にしない** — 対策の反映の確認は「整理の後に渡すもの」で完了照合へ渡す

   **(2) 統合の基準**

   - 統合するのは **`Kind` が同じ**エントリ同士だけ（keep と problem は昇格の先が違う。機械の組も同じ `Kind` 同士だけを出す）
   - 残す側（統合先）は、`promoted` / `mitigated` のエントリがあればそれ、無ければ `Count` の最も多いもの、同数なら最も古い ID。3 件以上を 1 件へ寄せるときも同じ順で 1 件を選ぶ。統合元にできるのは `active` のエントリだけで、**過去の整理で統合先になったエントリ（組の行に「過去の統合先」と出る）は統合元にしない** — そのエントリを指している既存の統合元が、`archived` のエントリを指す連鎖になる。残す側にする
   - 機械の組に出ていなくても、通読して同じアクションだと分かった組は同じ基準で採ってよい。エントリが 100 件に満たない台帳では語の重なりが薄く、既定値では 0 組になりやすい。`--min-merge-score 0.10` で見直し、それでも出ない組は通読で拾う
   - 「採れば合算で昇格閾値に到達」の印は、採った後に何が起きるかの予告で、採否の根拠ではない

   **(4) 定着の基準**

   - 探す範囲は、ツールキットのスキル・docs-template・hook と、作業中リポジトリの手順書（`CLAUDE.md` / `AGENTS.md` / `docs/`）。観測より後に入った規定でもよい
   - 一般的な規定が在るだけでは足りない。**その規定を読んだ人が、Keep の主張と同じ手順を取れる**ときに定着とみなす（主張の中心が固有の内訳・数値・順序で、規定からそれが出てこないなら不採用）
   - 定着を確かめられなければ何もしない（`Count` が閾値に届いたときの定着提案が通常の経路）。母集団は keep だけで、対策の規定が既に在る problem は本スキルでは動かさない（閾値に届いたときの昇格見送りが `mitigated` にする）

   **1 つのエントリが複数の節に当たるとき**は、(2) 統合 → (1) 紐付け → (4) 定着 → (3) stale の順に見て、先に当たった操作を採る。統合元にしたエントリには他の操作を当てない。統合先には紐付け・定着を重ねてよい。stale は、他の操作を当てなかったエントリだけを対象にする。

## Phase 2: 承認ゲート

採った候補を操作の種別ごとに、件数・エントリ ID・移行先（`Status` と `Issue` 列の値）・根拠（Issue 番号と一致の理由 / 同一と判定したアクション / 経過日数 / 定着先の所在）を添えて提示し、**ユーザーの承認を得る**（種別・エントリ単位で取捨できる）。

- 実行した回すべての SUMMARY 行と、既定から変えた引数を示す。出力の全文は、採った候補の根拠になった回のものを付ける
- 不採用の候補は件数だけを示す。迷って落とした候補は、理由を 1 行ずつ添えて別に並べる（承認者が拾い直せるようにする）

**提示とユーザー承認より前に、いかなるファイルも書き換えない。**

承認待ちの窓に並行セッションが台帳を更新すると、承認した対象が古くなる。**提示する直前**に、Phase 1 の冒頭と同じ照合フェンスをもう一度通し、止まったら取り込んでから dry-run を作り直す（承認は求めない）。まとめるモードの 2 度目以降は起点を移さず、照合だけが行われる。

## Phase 3: 適用

**適用の直前に、同じ照合フェンスをもう一度通す**。止まったら承認対象を作り直す。fetch 失敗・diverge は stale 値へ fallback せず停止する。

承認された操作だけを [references/apply.md](references/apply.md) の書式で台帳へ当てる。適用は**状態移行の追記**であって、履歴の編集ではない:

- 変えてよいのはメタ行の `Status` / `Issue`（統合先だけは `Count` / `First` / `Last` も）と、エントリ末尾へ足す `状態移行（再発ではない）` の観測メモ 1 行だけ
- 見出し・anchor・本文・既存の観測メモ・`Kind` は 1 文字も変えない。エントリを消さない・並べ替えない・ID を振り直さない

当てたら、適用前後を照合する（違反が 1 件でもあれば commit しない）:

```bash
git show "HEAD:docs/08-knowledge/OBSERVATIONS.md" >"${LEDGER_BEFORE_FILE}"
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/observation-refine.sh" check --before "${LEDGER_BEFORE_FILE}" --after "$(git rev-parse --show-toplevel)/docs/08-knowledge/OBSERVATIONS.md"
```

`NG` 行が出たら（rc 1）その行が名指す箇所を直して照合し直す。rc 2 は照合できていない。`THRESHOLD` 行は違反ではなく、次節の対象を示す。**rc 0 でも、`CHECK` 行の件数（`promoted` / `mitigated` / `archived_stale` / `merged`）を承認された件数と突き合わせる** — 何も当てていない台帳や、一部しか当てていない台帳も違反 0 件で通る。

書き込みは [`/retrospective` の「書き込み（定型コミット）」節](../retrospective/SKILL.md)の手順をそのまま使う（素の `git commit` を打たない。shebang の検査 → 書き込み口の `knowledge-commit add` → `commit` → 送信。送信の分岐・保留の合流・まとめるモードは [ledger.md](../retrospective/references/ledger.md#保留の合流と送信経路)が正本）。同節との違いは 2 点だけ: `--id` を状態を移したエントリの数だけ繰り返すことと、`--summary` を `台帳の定期整理（紐付け N / 統合 N / archive N / 定着 N）` の形にすること。

### 整理の後に渡すもの

整理が作った状態を放置すると、次の再発まで誰も見ない。次の 2 つを**同じセッションで**渡す:

- **昇格閾値に届いたエントリ**（照合の `THRESHOLD` 行。統合の合算で届いたものを含む）→ `/retrospective` の「昇格閾値と特急レーン」と [filing.md](../retrospective/references/filing.md)。昇格を見送る場合の書き戻しも同節に従う
- **closed の Issue へ紐付けたエントリ** → [`/retrospective` の完了照合](../retrospective/references/promotion.md)。対策の反映を確認できたものは `mitigated` へ移り、確認できないものは `promoted` のまま理由を残す

完了後、操作の種別ごとの件数と ID・否認でスキップした件数・渡した先ごとの ID を報告する。

## ハードルール

- **提示とユーザー承認より前に、いかなるファイルも書き換えない**
- **観測履歴を消さない。状態移行は観測メモの追記で残し、`Count` は統合の合算以外で変えない**
- **`check` の違反が 0 件になるまで commit しない**
- **Issue へのコメント・起票・close は本スキルの操作に含めない**（必要なら `/retrospective` の承認境界に従って別に行う）
- **機械の「類似」だけを根拠に移行しない**。本文を開いて確かめた根拠を観測メモへ書く
- 候補が 1 件も承認されなかった場合は「整理対象なし」と報告して終了する（空コミットを作らない）。**まとめるモードで起点へ移った後は、適用しない回も [ledger.md](../retrospective/references/ledger.md#保留の合流と送信経路) の規定どおり書き込み口の `push` を呼ぶ**（何も送らずに元の場所へ戻り、記録を消す。呼ばないと起点の detached HEAD が残る）

## 終了コード（`observation-refine.sh`）

| rc | 意味 |
| --- | --- |
| 0 | `report`: 候補を算出した（0 件を含む）/ `check`: 違反なし |
| 1 | `check`: 違反あり（`NG` 行が理由） |
| 2 | 判定不能 — 台帳が無い・曖昧・読めない・エントリ見出しを認識できない・メタ行を 1 件も読めない・同じ ID の見出しが複数ある・Issue 一覧を読めない／書式が不正・昇格閾値を導出できない・基準日を読めない |
| 3 | スクリプト側の plugin root ガードの停止。「ff-dev-toolkit更新後にこのskillを再呼び出してください」の案内に従う |
| 64 | 引数エラー |

上の「プラグインルートの固定」のガード（スキル本文の fence）で止まった回の終了コードは 2 で、スクリプトの 2（判定不能）とは別の停止である。案内文（「ff-dev-toolkit更新後に…」）で見分ける。
