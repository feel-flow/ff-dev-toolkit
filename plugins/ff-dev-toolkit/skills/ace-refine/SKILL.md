---
name: ace-refine
description: ACE Playbook を定期整理する（stale エントリのアーカイブ・長大エントリの圧縮・重複統合・PATTERNS 昇格）。dry-run → ユーザー承認 → 適用の3フェーズで、原文はアーカイブへ verbatim 保全する
---

# /ace-refine — ACE Playbook の grow-and-refine（定期整理）

## ASDD 2.0 設定がある場合

最初に[共通設定契約](../asdd-init/references/configuration.md)を読み、`scripts/asdd/config.mjs` の `loadConfig(root)` で対象プロジェクトの `.asdd/config.json` を検証する。以下の従来手順より、合意済みの文書構成・機能スイッチ・ワークフローを優先する。設定なしは従来互換、不正設定は自動処理を止めて診断する。

`features.ace=false` のとき、ワークフローからの自動実行・Playbook作成・収集・整理を行わない。ユーザーがACEを明示依頼した場合は依頼範囲で実行するが、永続設定を勝手に変更しない。完了後の振り返りも `features.retrospective` が有効な場合だけ自動実行する。

`/ace-curate`（grow）に対する refine を担う（既存本文の書き換えはこのスキルだけに許す）。

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

## 配置先・前提・引数・閾値

- 配置先（最初に解決）: `ACE_PLAYBOOK_PATH` → AGENTS.md / CLAUDE.md / docs 索引の配置記録 → 既定 `docs/08-knowledge/PLAYBOOK.md` の順（矛盾は変更前に報告、repo 外の配置は編集しない）。以降のパスは既定配置の例で、独自配置ではゲート引数・git add・claim も置換する
- 前提: PLAYBOOK がある・default branch（`<default-branch>`）上・clean tree。契機は月次か `check-category-size` のブロック・警告
- `$ARGUMENTS`: `domain [--confirm-pr <PR番号> --entry <ACE ID>]` / カテゴリ名 / `--all`。省略時は R1 の候補が多いカテゴリを提示する。**`domain` のときは [references/domain.md](references/domain.md) を読む**
- 閾値の環境変数と既定値は [scripts/ace/README.md](../../docs-template/scripts/ace/README.md)「ace-refine-report.ts の実行」の表。`ACE_REUSE_STALE_DAYS` は作成からの経過にも効くため、**運用開始からこの日数が経つまで Archive 候補は 0 件**（ADR-033）。候補は `helpful === 0` との積集合なので `ace-reuse-report` の候補数と一致しない

## 手順

### Phase R1: 候補算出（dry-run）

**このフェーズでは一切ファイルを書き換えない。** 出力の読み方は [scripts/ace/README.md](../../docs-template/scripts/ace/README.md) の各スクリプトの節。

1. 候補算出（上は scripts/ace/ 導入済み、下は未導入。1 行だけ実行する）:

   ```bash
   npx --yes tsx scripts/ace/ace-refine-report.ts docs/08-knowledge/PLAYBOOK.md
   FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/ace-run-ts.sh" "${FF_DEV_TOOLKIT_ROOT}/docs-template/scripts/ace/ace-refine-report.ts" docs/08-knowledge/PLAYBOOK.md
   ```

   - **(2) の除外枠は R3-a の対象にしない**（統合先なので、外すと統合元の着地が切れ、`check-refine-invariants` が拒否する）
   - **非 0 終了は候補 0 件ではなく「まだ何も測れていない」**。stderr の対象を直して再実行し、R2 へ進まない

1b. 抽象度レポート（ADR-047。1 と同じく 1 行だけ）:

   ```bash
   npx --yes tsx scripts/ace/ace-abstraction-report.ts docs/08-knowledge/PLAYBOOK.md
   FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/ace-run-ts.sh" "${FF_DEV_TOOLKIT_ROOT}/docs-template/scripts/ace/ace-abstraction-report.ts" docs/08-knowledge/PLAYBOOK.md
   ```

   **(4)「組にできなかった候補対」は 0 が正常**（0 以外はレポートのバグとして報告）。legacy（旧テーブル形式）の候補は R3-b へ回す。日本語だけで共通する組は機械シグナルに出ないので、手順 2 は省かない。

2. **近似重複・抽象度統合の抽出（LLM 判断）**: 1b の組を優先し索引タイトルで補って、**本文まで読んで**「アクションが同一か」「抽象度を 1 段上げれば同一か」で判定し、上げた主張から元のアクションを再導出できなければ棄却する（[PLAYBOOK.md](../../docs-template/08-knowledge/PLAYBOOK.md)「抽象度の下限と棄却基準（ADR-047）」）。
3. カテゴリ指定があれば候補を絞る。

### Phase R2: 承認ゲート

dry-run レポート全文と抽出結果を操作種別（アーカイブ / 圧縮 / 統合 / 昇格）ごとに件数と ID を添えて提示し、**ユーザーの承認を得る**（種別・エントリ単位で取捨できる）。

**dry-run レポートの提示とユーザー承認より前に、いかなるファイルも書き換えない。**

#### 承認を求める前に base の先行を照合する

承認待ちの窓に並行セッションが同じ default ブランチへ整理をマージすると承認対象が古くなる（実測: 161 件を破棄して 138 件を取り直した。OBS-004）。**レポートを提示する直前に照合する** — ここなら dry-run の作り直しで済み**承認のやり直しが発生しない**。R3 開始時と同じ集合（base の先行 + clean tree）を見る。

```bash
default_ref="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD)" || {
  echo "origin/HEAD を解決できません（git remote set-head origin -a を実行してください）" >&2
  exit 1
}
[[ "$default_ref" == origin/* ]] || { echo "default branch ref が不正です: ${default_ref}" >&2; exit 1; }
default_branch="${default_ref#origin/}"
[[ -z "$(git status --porcelain --untracked-files=all)" ]] || {
  echo "作業ツリーを clean にしてから dry-run をやり直してください" >&2
  exit 1
}
if ! _fetch_err="$(git fetch origin "+refs/heads/${default_branch}:refs/remotes/origin/${default_branch}" 2>&1 >/dev/null)"; then
  _fetch_err="$(sed -E 's#(://)[^/[:space:]]*@#\1***@#g' <<<"${_fetch_err:-（原因は出力されませんでした）}")"
  echo "origin/${default_branch} を取得できません（stale 値で判定しない。認証・通信・remote 設定を確認）: ${_fetch_err}" >&2
  exit 1
fi
git rev-parse --verify --quiet "refs/remotes/origin/${default_branch}" >/dev/null || {
  echo "remote-tracking ref を解決できません: origin/${default_branch}" >&2
  exit 1
}
git merge-base --is-ancestor "origin/${default_branch}" HEAD || {
  echo "origin/${default_branch} が先行しています。取り込んでから dry-run をやり直してください（承認は求めない）" >&2
  exit 1
}
```

非 0 ならレポートを提示せず、利用者が取り込んでから dry-run を作り直す。

> **対象範囲**: `ace-refine` に閉じる。対象は**承認待ちの窓の後段に default ブランチの共有文書への書き込みがある**スキルだけで、`retrospective` は窓を持たず**記録内容を作る前**（同一性判定・`Count`・OBS ID 採番より前）の照合を自前で持つ。

### Phase R3: 適用

**R3 開始の直前に、上の「承認を求める前に base の先行を照合する」の fence をもう一度実行する**（同じ集合）。止まったら承認対象を作り直す。fetch 失敗・diverge は stale 値へ fallback せず停止する。承認の直後に 3 つめの検出点は置かない（窓が縮まらない）。書き込み後に clean tree を要求しない。

**適用後にも 2 度目の先行が起きうる**（claim の content conflict で止まる）。適用済みの成果は**捨てない**（復帰手順は [references/commit.md](references/commit.md)）。

承認された操作だけを R3-0 → 操作ごとの手順 → R3-e の順で適用する。**操作ごとの手順は [references/operations.md](references/operations.md) の該当節（R3-a〜R3-d）だけを読む。**

#### R3-0. archive へ追記する前の共通規則（保全済み ID の分岐・一意性検証）

R3-a / b / c は live のブロックを `playbook/archive/<category>.md` へ運ぶ。過去の圧縮で**既に保全済みの ID** へ verbatim コピーを足すと同一 `<a id>` が 2 つでき、**アンカーは先勝ち**なので後のブロックへは到達できない（ACE-490-2）。

1. 書く前に既存出現数を数える（`grep -c` はファイルが無いと何も出さずに非 0 で終わる。終了コードではなく出力の件数で判定し、ファイル不在は 0 件）:

   ```bash
   grep -c "^### <ID>:" docs/08-knowledge/playbook/archive/<category>.md
   ```

2. 件数で分岐する:
   - **0 件** — 原文を verbatim でコピーし、見出し直後へ provenance 行を挿入する
   - **1 件** — **既に保全済みの ID へ原文を再コピーしない**。既存ブロックへ今回の provenance 行だけを追記し、live 側だけを撤去する
   - **2 件以上** — **2 件以上なら live に触れず中断する**（先に重複を畳む）

3. **保全検証は「存在（≥1）」ではなく「一意（=1）」で行う**。存在だけでは重複が通り、R3-e の `check-archive-links` で気付いた時には live の削除が済んでいる。

#### R3-e. 索引・Frontmatter・Changelog の整合

`.version-claims` contract があれば、**直 push / PR のどちらでも**変更した文書ごとの `.version-claims/<文書 path>.claim` を同じ最終 commit に含める。

1. **エントリ保全の一括検証（必須）**: live から削除・書き換えした**全 ID** について、`playbook/archive/` 配下に `### <ID>:` 見出しが**ちょうど 1 件**（存在ではなく一意）あることを `grep -c` で確認する。0 件なら git から復元してやり直し、2 件以上なら 1 ブロックに畳む。
2. 索引からアーカイブ・統合した行が消えているか確かめる。
3. Frontmatter を [ace-cycle.md](../../docs-template/05-operations/deployment/ace-cycle.md)「3. Frontmatter の更新」に従って更新する（`ace_entry_count` は live 実数、refine は `version` minor +1・`changeImpact: medium`）。
4. `## Changelog` 先頭へ整理ブロックを追記する。ID 列の書式は `check-refine-invariants` が検査する（規則の正本は [scripts/ace/README.md](../../docs-template/scripts/ace/README.md)「check-refine-invariants.ts の実行」）。**統合が 0 組なら `- Merged:` の行ごと書かない**（`- Merged: なし` は解析できず exit 1。「なし」を書けるのは他の 3 ラベルだけ）:

   ```markdown
   ### [x.y.0] - YYYY-MM-DD

   #### 整理（/ace-refine）

   - Archived: ACE-XXX, ACE-YYY（helpful=0・stale）
   - Compacted: ACE-ZZZ（NN 行 → MM 行）
   - Merged: ACE-AAA → ACE-BBB（カウンター合算）
   - Promoted: ACE-CCC（PATTERNS.md へ蒸留）
   ```

5. 検証ゲートを exit 0 まで回す。**各ゲートについて、プロジェクトの状態に合う 1 本だけを実行する**（一括実行すると未導入側で必ず失敗する）:

   ```bash
   # 同期検証: npm script / scripts/ace/ 導入済み / 未導入 の 1 本だけ
   npm run ace:check-playbook-frontmatter
   npx --yes tsx scripts/ace/sync-playbook-frontmatter.ts docs/08-knowledge/PLAYBOOK.md --check
   FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/ace-run-ts.sh" "${FF_DEV_TOOLKIT_ROOT}/docs-template/scripts/ace/sync-playbook-frontmatter.ts" docs/08-knowledge/PLAYBOOK.md --check
   # 以下 4 ゲートは各 導入済み / 未導入 の 1 本だけ
   npx --yes tsx scripts/ace/check-category-size.ts docs/08-knowledge/PLAYBOOK.md
   FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/ace-run-ts.sh" "${FF_DEV_TOOLKIT_ROOT}/docs-template/scripts/ace/check-category-size.ts" docs/08-knowledge/PLAYBOOK.md
   npx --yes tsx scripts/ace/check-archive-links.ts docs/08-knowledge/PLAYBOOK.md
   FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/ace-run-ts.sh" "${FF_DEV_TOOLKIT_ROOT}/docs-template/scripts/ace/check-archive-links.ts" docs/08-knowledge/PLAYBOOK.md
   npx --yes tsx scripts/ace/check-refine-invariants.ts docs/08-knowledge/PLAYBOOK.md
   FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/ace-run-ts.sh" "${FF_DEV_TOOLKIT_ROOT}/docs-template/scripts/ace/check-refine-invariants.ts" docs/08-knowledge/PLAYBOOK.md
   npx --yes tsx scripts/ace/check-entry-format.ts docs/08-knowledge/PLAYBOOK.md
   FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/ace-run-ts.sh" "${FF_DEV_TOOLKIT_ROOT}/docs-template/scripts/ace/check-entry-format.ts" docs/08-knowledge/PLAYBOOK.md
   ```

6. **正準化後の allowlist 操作は変種で分岐する**（`check-entry-format` の旧形式判定は 3 マーカーの OR）:
   - 完全正準化（第 1 変種で 3 マーカーが消えた）、または R3-a / R3-c で live から消した: `docs/08-knowledge/legacy-format-allowlist.txt` から当該 ID を削除する
   - ハイブリッド残置（第 2 変種、または行頭の **Insight**/**Context**/**Action** が残る）: `insight-block` マーカーで legacy 判定が継続する。**allowlist から削除しない**（削除すると allowlist に無い旧形式として exit 1 でブロック）

7. **全編集後に claim を最終生成する**: 手順 5 のゲートが exit 0 になってから [references/commit.md](references/commit.md) へ進み、以後は対象文書を変更しない。

### コミット

既定は chore PR（既存本文を書き換えるのでレビューを通す）。**アーカイブのみ・5 件以下なら** `<default-branch>` へ直 push してよい。手順は [references/commit.md](references/commit.md)。

> `knowledge:` 接頭辞が無いと（squash では PR タイトルが件名）、`ace-reuse-report` が参照集計から除けず、大量の ACE ID で git 参照カウントが汚染されて以後の stale 判定が壊れる。

完了後、対象・Changelog の 4 ラベルごとの件数と ID・否認でスキップした件数を報告する。

## ハードルール

- **dry-run レポートの提示とユーザー承認より前に、いかなるファイルも書き換えない**
- **原文はアーカイブへ verbatim で保全する。保全なしの削除・要約は禁止**
- **エントリ ID と anchor は live・アーカイブの双方で改名しない**
- **archive へ追記する前に既存出現数を数え、保全済み ID には原文を再コピーしない**
- **provenance 注記は実際に行った操作に対応する変種を使う**
- **保全本文内の `./` 相対リンクは書き換えない。代わりに archive ファイル冒頭の「保全本文内の相対リンクは live 基準」注記を必須とする**
- **統合される側は archive 側のコピーの `Status` を `merged` に変える**
- **カウンターは統合時の合算以外変更しない（減算・リセット禁止）**
- **既存エントリ本文の書き換えは本スキル実行中のみ許可（/ace-curate は append-only のまま）**
- **コミット件名と PR タイトルは `knowledge:` で始める**
- 候補が 1 件も承認されなかった場合は「整理対象なし」と報告して終了する（空コミットを作らない）
