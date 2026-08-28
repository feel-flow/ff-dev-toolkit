---
name: ace-refine
description: ACE Playbook を定期整理する（stale エントリのアーカイブ・長大エントリの圧縮・重複統合・PATTERNS 昇格）。dry-run → ユーザー承認 → 適用の3フェーズで、原文はアーカイブへ verbatim 保全する
---

# /ace-refine — ACE Playbook の grow-and-refine（定期整理）

`/ace-curate` が「増やす（grow）」を担うのに対し、本スキルは「整える（refine）」を担います。肥大化した Playbook から検索ノイズを取り除き、実証済みの知見を蒸留します。**通常の curate は append-only のまま**であり、既存エントリ本文の書き換えは本スキル実行中のみ許可されます（原文アーカイブ保全が条件）。

## プラグインルートの固定（必須）

<!-- ff-dev-toolkit-plugin-root-contract:start -->
同梱resourceを参照する前に `FF_DEV_TOOLKIT_ROOT` を**一度だけ**解決し、実行中は変更しない。

- Claude Codeでは、その呼び出しでホストが渡した `${CLAUDE_PLUGIN_ROOT}` を使う
- Codexなど他ホストでは、実際に読み込んだこの `SKILL.md` の絶対パスから `../..` を解決する

解決後は同じ絶対パスだけを使い、cache / marketplace / 旧インストール領域を走査して選ばない。
version sortによる版の選び直しや、sidecarを使った別実体への切替も行わない。
解決済みrootまたは必要resourceが消失・不整合になった場合は、別versionへfallbackせず
「ff-dev-toolkit更新後にこのskillを再呼び出してください」と案内して停止する。
<!-- ff-dev-toolkit-plugin-root-contract:end -->

## 前提

- `docs/08-knowledge/PLAYBOOK.md` が存在すること（`/ace-setup` で作成済み）
- 現在のブランチがデフォルト統合ブランチ（`develop` / `main` 等。以下 `<default-branch>`）であること
- ワークツリーがクリーンであること（`git status --short` が空）
- **実行タイミング**: 月次メンテナンス、`check-category-size` の件数ゲートがブロックしたとき、refine 目安（既定 130 件）の警告、またはエントリ密度の警告（行数が導出上限を超過）が出たとき

## 引数

- `$ARGUMENTS` — 対象カテゴリ名（例 `tooling`）または `--all`。省略時は Phase R1 のレポートから候補件数の多いカテゴリを提示してユーザーに選んでもらう

## 閾値（環境変数）

| 環境変数 | 既定 | 意味 |
| --- | --- | --- |
| `ACE_REUSE_STALE_DAYS` | 30 | active エントリを stale とみなす日数。**作成からの経過と最終 git 参照からの経過の両方**に適用される。作成日側にも効くため、**Playbook の運用開始からこの日数が経つまで候補は 0 件**になる（ADR-033）。なお本スキルの Archive 候補は `helpful === 0` の積集合まで絞った**実施可能件数**であり、`ace-reuse-report` が報告する候補数（母数）とは一致しない |
| `ACE_MAX_ENTRY_LINES` | 15 | 1 エントリの行数バジェット（anchor 行〜終端 `---`）。例外宣言付きは 2 倍（30）。`check-category-size` のファイル行数上限もこの値から導出される（`ヘッダ行数 + 件数 × (本値 + 1)` — ADR-019） |
| `ACE_PROMOTE_HELPFUL_MIN` | 5 | この Helpful 以上で PATTERNS.md への昇格候補 |
| `ACE_PATTERNS_PATH` | `docs/03-implementation/PATTERNS.md` | 昇格先（レイアウトが異なる場合のみ上書き） |

## 手順

### Phase R1: 候補算出（dry-run）

**このフェーズでは一切ファイルを書き換えない。**

1. 候補算出スクリプトを実行する:

   ```bash
   # プロジェクトに scripts/ace/ が導入済みの場合
   npx --yes tsx scripts/ace/ace-refine-report.ts docs/08-knowledge/PLAYBOOK.md
   # 未導入の場合はプラグイン同梱のテンプレートを直接使う
   npx --yes tsx "${FF_DEV_TOOLKIT_ROOT}/docs-template/scripts/ace/ace-refine-report.ts" docs/08-knowledge/PLAYBOOK.md
   ```

   レポートは (1) Archive 候補（helpful=0 かつ stale）、(2) 行数バジェット超過（行数降順 = 圧縮効果の大きい順）、(3) PATTERNS.md 昇格候補、を列挙する。

   **非ゼロ終了で止まったら R2 へ進まない。** スクリプトはレポートが不完全になる条件（主なものはエントリ 0 件 / 閉じていないコードフェンス / 行数計測で見失ったエントリ）を検出したとき、候補一覧を一切出さずに終了する。stderr が名指しした対象（ファイル、またはエントリ ID）を修正してから再実行すること。**候補 0 件の正常レポートと、レポートが出ていない状態を混同しない** — 前者は「整理対象なし」だが、後者は「まだ何も測れていない」であり、そのまま R2 の承認ゲートへ進むと空の候補一覧を「整理完了」として扱ってしまう。

2. **近似重複の抽出（LLM 判断）**: `docs/08-knowledge/PLAYBOOK.md` の索引テーブル全体（タイトル列）を読み、意味的に重なるエントリ対を抽出する。判定基準は「**読者が取る実行可能なアクションが同一か**」。同一なら統合候補、アクションが異なる（例: 診断方法と恒久対策、順方向と逆方向の使い分け）なら統合しない。

3. `$ARGUMENTS` でカテゴリ指定がある場合は、候補をそのカテゴリに絞り込む。

### Phase R2: 承認ゲート

dry-run レポート全文と近似重複の抽出結果を、操作種別ごと（アーカイブ / 圧縮 / 統合 / 昇格）に件数と対象 ID を添えて提示し、**ユーザーの承認を得る**。ユーザーは操作種別単位・エントリ単位で取捨できる。

**dry-run レポートの提示とユーザー承認より前に、いかなるファイルも書き換えない。**

### Phase R3: 適用

承認された操作を適用する**前**に、R2 の承認対象を作った base が最新か確認する。R3-a〜R3-d の書き込み後に clean tree を要求してはならない。

```bash
default_ref="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD)" || {
  echo "origin/HEAD を解決できません（git remote set-head origin -a を実行してください）" >&2
  exit 1
}
[[ "$default_ref" == origin/* ]] || { echo "default branch ref が不正です: $default_ref" >&2; exit 1; }
default_branch="${default_ref#origin/}"
[[ -z "$(git status --porcelain --untracked-files=all)" ]] || {
  echo "ACE refine 適用前に作業ツリーを clean にしてください" >&2
  exit 1
}
if ! git fetch origin "+refs/heads/${default_branch}:refs/remotes/origin/${default_branch}" >/dev/null 2>&1; then
  echo "origin/${default_branch} を取得できません（stale 値で版を確定しない。認証・通信・remote 設定を確認）" >&2
  exit 1
fi
git rev-parse --verify --quiet "refs/remotes/origin/${default_branch}" >/dev/null || {
  echo "remote-tracking ref を解決できません: origin/${default_branch}" >&2
  exit 1
}
git merge-base --is-ancestor "origin/${default_branch}" HEAD || {
  echo "origin/${default_branch} が先行しています。取り込んで R2 の承認対象を作り直してください" >&2
  exit 1
}
```

fetch 失敗・ref 解決不能・diverge は stale 値へ fallback せず停止する。remote が先行していれば取り込み、dry-run と R2 の承認対象差分から作り直す。確認後、承認された操作のみを以下の順で適用する。

#### R3-0. archive へ追記する前の共通規則（保全済み ID の分岐・一意性検証）

R3-a / R3-b / R3-c はいずれも live のブロックを `playbook/archive/<category>.md` へ運ぶ。archive は append 型なので、**対象 ID が既に保全済みのことがある** — 過去の圧縮（R3-b）は原文を archive へ残したまま live に要約を置くため、live と archive の双方に同じ ID が在るのは compact の正常な状態である。ここへ手順どおり verbatim コピーを足すと同一 `<a id>` が 2 つでき、**アンカーは先勝ち**なので後から足したブロックへは到達できない（着地だけが静かに分裂する）。同型は ACE Playbook の **ACE-490-2**（append 型 archive への保全検証は「存在」でなく「一意」で書く）が記録している。

1. archive へ書く前に、対象 ID の既存出現数を数える:

   ```bash
   grep -c "^### <ID>:" docs/08-knowledge/playbook/archive/<category>.md
   ```

   アーカイブファイル自体が無ければ **0 件（未保全）** として扱う（`grep -c` は対象ファイルが無いと何も出さずに非ゼロ終了する。判定に使うのは出力の件数だけで、終了コードを「一致 0 件」と読み替えないこと — ファイル不在は R3-a step 1 の新規作成へ進む合図である）。

2. 件数で分岐する:

   - **0 件（未保全）** — 各ステップの手順どおり原文ブロックを verbatim でコピーし、見出し直後へ provenance 行を挿入する。
   - **1 件（保全済み）** — **既に保全済みの ID へ原文を再コピーしない**。archive の既存ブロックへ今回の操作の provenance 行だけを追記し（R3-a なら `> Archived:`、R3-b なら `> Compacted:`、R3-c なら `> Merged into:` と `Status` 変更）、live 側だけを撤去する。原文は既に保全済みなので、verbatim 保全の契約はこの分岐でも満たされる。
   - **2 件以上** — 既に分裂している。**2 件以上なら live に触れず中断する**（先に重複を畳む。live を消してから気付くと巻き戻しになる）。

3. **保全検証は「存在（≥1）」ではなく「一意（=1）」で行う**。存在だけを見る検証が防げるのは書き込み失敗だけで、重複していても真を返すため分裂した archive を緑のまま通す（重複を検出するのは R3-e 最後の `check-archive-links` で、そこまで進むと live からの削除は済んでおり巻き戻しになる）。live 側を触ってよいのは count が**ちょうど 1** のときだけである。

#### R3-a. stale エントリのアーカイブ

1. アーカイブ先 `docs/08-knowledge/playbook/archive/<category>.md` が無ければ新規作成する:

   ```markdown
   # PLAYBOOK Archive — <カテゴリの日本語ラベル> (<category>)

   > **Parent**: [PLAYBOOK.md](../../PLAYBOOK.md) — アーカイブ済みエントリの保管場所。
   > `playbook/archive/` 配下は `ace_entry_count`・カテゴリ件数ゲート・reuse 集計の対象外。
   > 参照リンクが切れていた場合はこのディレクトリを ID で grep して探す。
   >
   > **保全本文内の相対リンクは live 基準**: 各エントリ本文は原文を verbatim 保全しているため、本文中の `./<category>.md#ace-xxx` は `playbook/` 直下を指す live 側のリンクである。このディレクトリから辿ると (a) ファイルが存在しない、(b) anchor が無い、(c) **live ではなくアーカイブ済みの複製に着地する**（リンクチェッカーには映らない）のいずれかになる。本文内リンクを辿るときは `../<category>.md#ace-xxx` に読み替えるか、[PLAYBOOK.md の索引テーブル](../../PLAYBOOK.md#エントリ一覧) から live を引くこと。

   ---
   ```

   **保全本文内の相対リンクは書き換えない**（verbatim 保全が優先）。原文が live 側で持っていた `./<category>.md#ace-xxx` は、archive へ運ばれた時点で基準がずれるが、**書き換えれば verbatim 保全という契約そのものが壊れる**。したがって唯一 actionable な対応は上記の冒頭注記であり、注記は**必須**（`./` リンクを 1 件でも含むファイルでは省略できない）。この注記の存在は機械ゲートで強制される（下記 step 6 / R3-e）。着地先が archived copy になるケースを列挙する検査は採用しない — 検出できても verbatim 保全の下では直せないため、レポートが増えるだけになる。

2. **R3-0 の分岐に従う**。未保全（0 件）なら対象エントリのブロック全体（anchor 行〜終端 `---`）を **verbatim で**アーカイブファイル末尾へコピーし、エントリ見出しの直後に理由ヘッダを挿入する:

   ```markdown
   > Archived: YYYY-MM-DD / 理由: helpful=0・<N>日以上参照なし（/ace-refine）
   ```

   保全済み（1 件）なら**原文を再コピーせず**、archive の既存ブロックの provenance 行の並びへ同じ `> Archived:` 行だけを追記し、理由欄に保全の出所を添える（例: `原文は 2026-07-31 の圧縮で保全済み`）。過去の圧縮で原文が archive にあり live には要約が残っているエントリは、すべてこちらに当たる。

3. **アーカイブ書き込みの検証（必須）**: 当該 ID の見出しがアーカイブ先に**ちょうど 1 件**あることを確認してから live 側を削除する:

   ```bash
   [ "$(grep -c "^### <ID>:" docs/08-knowledge/playbook/archive/<category>.md)" -eq 1 ]
   ```

   0 件（書き込み失敗）でも 2 件以上（重複）でも live 側に触れず中断する。存在だけを見る形（`grep -q`）へ戻さない — 検証そのものが無いと書き込み失敗時に R3-e の全ゲートが green のままエントリが消失し（count は live 実数へ「修正」され、archive はゲート対象外のため）、存在だけの検証では重複が緑で通って着地が分裂したまま live が消える。

4. live 側（`playbook/<category>.md`）から当該ブロックを削除し、`PLAYBOOK.md` の索引テーブルから当該行を削除する。
5. `docs/` 配下をアーカイブした ID で grep し、`playbook/<category>.md#ace-x` 形式のリンクを `playbook/archive/<category>.md#ace-x` へ書き換える（アーカイブ先でも anchor は保持されるため着地は保たれる）。**書き換え対象は「archive されたエントリを指すリンク」だけで、「archive された本文の中にあるリンク」は step 1 のとおり触らない。**
6. 既存のアーカイブファイルへ追記した場合、そのファイル冒頭に step 1 の「保全本文内の相対リンクは live 基準」注記があるか確認し、無ければ追加する（注記の導入前に作られたファイルが該当する）。

#### R3-b. 長大エントリの圧縮

1. **先に**原文ブロック全体をアーカイブファイル末尾へ verbatim でコピーし、見出し直後に理由ヘッダを挿入する。圧縮操作には 2 種類あり、**実際に行った操作に対応する変種を使う**（規定文を選ぶ判定条件は「live 側の本文文字列が原文と逐語同一かどうか」。1 文字でも変えたら (a)、メタ表の再整形だけで本文を触っていないなら (b)）:

   ```markdown
   > Compacted: YYYY-MM-DD（live 側を要約済み。本文の原文は本エントリが正）
   ```

   ```markdown
   > Compacted: YYYY-MM-DD（live 側はメタ表のみ正準フォーマットへ再整形。本文は逐語同一で無改変。本エントリが原文）
   ```

   - **(a) 第 1 変種**（`live 側を要約済み`）: 本文を意味保存要約した場合。
   - **(b) 第 2 変種**（`メタ表のみ正準フォーマットへ再整形`）: 旧テーブル形式のメタ表 8 行を正準 4 行へ再整形しただけで、本文は逐語同一の場合。**このとき第 1 変種を使うと「要約済み」が虚偽になる**（archive は監査記録なので、実際にしていない操作を記録してはいけない）。
   - **接頭辞 `Compacted:` は両変種で共通**にする。archive を `Compacted:` で grep する運用が既にあるため、再整形専用の別接頭辞（`Reformatted:` 等）を作ると圧縮履歴が 2 系統に分裂して追跡できなくなる。
   - 本文の一部を要約し、かつメタ表も再整形した場合は (a) を使う（要約が含まれる以上「要約済み」は真）。

2. **アーカイブ書き込みの検証（必須）**: R3-0 の分岐と一意性検証に従う（保全済みなら原文を再コピーせず、既存ブロックへ今回の `> Compacted:` 行だけを追記する）。アーカイブ先の当該 ID が**ちょうど 1 件**であることを確認してから live 側を書き換える。
3. live 側を PLAYBOOK.md §エントリテンプレートのコンパクト正準フォーマットへ**意味保存で要約**する:
   - **不変**: エントリ ID・anchor・Category・Origin・Date・Helpful・Harmful・Status
   - **本文**: 2〜4 文（知見の本質 → 非自明な適用条件 → 推奨アクション）。原文に無い新しい主張を追加しない。適用条件・反直感的な事実を欠落させない
   - 反直感的な詳細が 15 行に収まらない場合のみ `<!-- ace-line-budget-exception: 理由 -->` を付けて 30 行まで許容する

#### R3-c. 近似重複の統合

1. 残す側 = 総参照数（git 参照 + 相互参照）の多い方。同数なら **古い ID** を残す。
2. 残す側の `Helpful` / `Harmful` に、統合される側のカウンター値を**合算**する。
3. 統合される側はアーカイブファイルへ verbatim でコピーし、見出し直後にポインタを挿入する。**あわせて archive 側のコピーの `Status` を `merged` に変える**:

   ```markdown
   > Merged into: [ACE-YYY](../<category>.md#ace-yyy)（YYYY-MM-DD /ace-refine）
   ```

   - `Status: active` のまま残すと、archive を ID で grep した人には「有効なエントリ」に見える。`> Merged into:` ポインタは人間読者には効くが、**機械的には active と区別できない**。
   - `Status` 変更は `/ace-curate` でも許可されている操作なので、削除禁止・カウンター不変の契約とは衝突しない（変えるのは archive 側のコピーだけで、統合先 = 残す側の Status は触らない）。
   - これは verbatim 保全の唯一の例外である。`Status` 行 1 行のみを `active` → `merged` に変え、本文・ID・anchor・Origin・Date・カウンターは一切変えない（統合された事実は保全すべき原文の一部ではなく、保全後に付与されるメタ情報である）。
   - **保全済み（R3-0 で 1 件）なら原文を再コピーしない**。既存の archive レコードへ `> Merged into:` を追記して `Status` を `merged` に変える。再コピーすると同一 anchor が 2 つでき、先勝ちで後から足した `Status: merged` へは到達できず、先行複製の `active` が生き続ける（ACE-490-2 が同型を記録している）。

4. **アーカイブ書き込みの検証（必須）**: アーカイブ先の統合される側の ID が**ちょうど 1 件**（`grep -c "^### <ID>:"`）であることを確認してから、live 側から当該ブロックを削除する。0 件でも 2 件以上でも live 側に触れず中断する。
5. `docs/` 配下の統合された側 ID へのリンクを、残す側のエントリへ書き換える。索引テーブルから統合された側の行を削除する。
6. 残す側の本文に、統合で吸収した観点が欠けるなら 1 文だけ追記してよい（圧縮ルールと同じ意味保存の範囲内）。

#### R3-d. PATTERNS.md への昇格（蒸留オーバーレイ）

1. 昇格先 `docs/03-implementation/PATTERNS.md` の「実証済みパターン（ACE 昇格）」節へ、以下の形式で追記する。**節見出しは「実証済みパターン（ACE 昇格）」の部分一致で探す**（テンプレートでは `## 14. 実証済みパターン（ACE 昇格）` のように節番号付き — 番号は文書によって異なるため、完全一致で探して重複節を作らない）。節が無ければ節ごと追加する。初回昇格時はプレースホルダ行 `- 該当なし（昇格発生後に追記）` を削除する:

   ```markdown
   ### [パターンを一言で表す見出し]

   [ルール本文 1〜3 行。実装前に読んで即適用できる命令形で書く]

   出典: [ACE-XXX](../08-knowledge/playbook/<category>.md#ace-xxx)
   ```

2. 昇格は**移動ではない**。元エントリは live に `Status: active` のまま残す（カウント意味論も不変）。既に同じ ACE ID が PATTERNS.md に収載済みならスキップする（冪等）。`deprecated` 等の非 active エントリは Helpful が高くても昇格させない（レポートの候補算出も active のみを列挙する）。
3. 昇格を追記したら PATTERNS.md の Frontmatter も更新する: `version` を **minor +1**、`updated` を今日、`changeImpact` を `medium` に設定（無ければ追記）。PATTERNS.md に `## Changelog` セクションがある場合は先頭へ当該版のエントリも追記し、frontmatter の `version` と最新 `### [x.y.z]` の一致を保つ。昇格した文書を Frontmatter / Changelog 未更新のまま残さない。

#### R3-e. 索引・Frontmatter・Changelog の整合

R3 開始前ガードで確定した default branch を基準にする。`.version-claims` contract があるリポジトリでは、**直 push / PR のどちらでも**変更した PLAYBOOK.md / PATTERNS.md ごとに元の階層を保持した `.version-claims/<文書 path>.claim` を `document` / `version` / `change` の3行だけで更新し、同じ最終 commit に含める。version 不変の整理でも文書を変えたら `change` を更新する。同じ文書を同じ base から変えた直 push と PR も claim の同じ行を異なる値へ更新するため、祖先検査後の race を content conflict で停止する。claim の片寄せ・削除では解消せず、最新 base から整理結果・version・集約値・claim を再生成する。

1. **エントリ保全の一括検証（必須）**: R3-a/b/c で live から削除・書き換えした**全 ID** について、`playbook/archive/` 配下に `### <ID>:` 見出しが**ちょうど 1 件**（存在ではなく一意）あることを `grep -c` で確認する。0 件ならコミットせず、欠けたエントリを git から復元して該当操作をやり直す。2 件以上なら着地が分裂しているので、原文を 1 ブロックに畳み provenance 行だけを既存レコードへ寄せてからコミットする。
2. `PLAYBOOK.md` 索引テーブルを再確認する（アーカイブ・統合で削除した行の消し忘れがないか）。索引行は**タイトルのみ**で、説明文を書かない。
3. Frontmatter: `ace_entry_count` を **live エントリ実数**（`playbook/archive/` 配下は数えない）へ更新し、`version` を **minor +1**、`updated` を今日、`changeImpact` を `medium` に設定する（無ければ追記。minor=medium の対応に従う。PLAYBOOK.md の `changeImpact` 更新責任は本スキルと `/ace-curate` にある）。
4. `## Changelog` 先頭へ整理ブロックを追記する:

   ```markdown
   ### [x.y.0] - YYYY-MM-DD

   #### 整理（/ace-refine）

   - Archived: ACE-XXX, ACE-YYY（helpful=0・stale）
   - Compacted: ACE-ZZZ（NN 行 → MM 行）
   - Merged: ACE-AAA → ACE-BBB（カウンター合算）
   - Promoted: ACE-CCC（PATTERNS.md へ蒸留）
   ```

5. 検証ゲートを exit 0 まで回す:

   ```bash
   npm run ace:check-playbook-frontmatter
   # npm script が無い場合:
   # npx --yes tsx path/to/sync-playbook-frontmatter.ts docs/08-knowledge/PLAYBOOK.md --check
   npx --yes tsx scripts/ace/check-category-size.ts docs/08-knowledge/PLAYBOOK.md
   # archive の保全本文内リンクが冒頭注記で担保されているか + <a id> 一意性（Issue #288 穴 2 / #492）
   npx --yes tsx scripts/ace/check-archive-links.ts docs/08-knowledge/PLAYBOOK.md
   # compact 保全・merge 状態遷移・PATTERNS 収載（本文+出典）の結果不変条件（Issue #492）
   npx --yes tsx scripts/ace/check-refine-invariants.ts docs/08-knowledge/PLAYBOOK.md
   # 新規追記が旧テーブル形式でないことの機械検証（Issue #286）
   npx --yes tsx scripts/ace/check-entry-format.ts docs/08-knowledge/PLAYBOOK.md
   ```

6. **正準化後の allowlist 操作は変種で分岐する**（`check-entry-format` の旧形式判定は field-table-header / table-separator / insight-block の 3 マーカー OR。allowlist から外してよいのは live 本文に 3 マーカーが 1 つも残っていない ID だけ。第 1 変種＝本文要約でも、行頭の **Insight**/**Context**/**Action** が残れば legacy のまま）:

   - **第 1 変種かつ 3 マーカーが全て消えた場合**（完全正準化）: 当該 ID を `docs/08-knowledge/legacy-format-allowlist.txt` から削除する。削除しないと `check-entry-format` が「正準化済みなのに allowlist に残っている」と警告する（警告のみでブロックはしない）。
   - **第 2 変種、または第 1 変種でも insight-block 等が残る場合**（ハイブリッド残置）: 本文の **Insight**/**Context**/**Action** が残るため `insight-block` マーカーで legacy 判定が継続する。**allowlist から削除しない**（削除すると allowlist に無い旧形式として exit 1 でブロックされる）。
   - **R3-a / R3-c で live から消した場合**: 当該 ID を allowlist から削除する（live に無い ID は警告のみ。警告を消すための掃除）。

7. **全編集後に claim を最終生成する**: 索引・Frontmatter・Changelog・allowlist の更新と手順 5 のゲートが完了してから実行し、以後は対象文書を変更しない。各コマンドの失敗、`git diff --quiet` の検査不能、空・非 SemVer の version、書き込み失敗はすべて停止する。`.version-claims` と同じ filesystem 上の一時ファイルを完全生成し、既存 claim を退避してから上書き禁止 hard link で install し、最後に3行完全一致を検証する。競合時は rollback するか復旧用ファイルを保持して停止する。

   ```bash
   if [[ -d .version-claims ]]; then
     [[ -n "${FF_DEV_TOOLKIT_ROOT:-}" && -x "$FF_DEV_TOOLKIT_ROOT/scripts/update-version-claim.sh" ]] || { echo "FF_DEV_TOOLKIT_ROOT の claim helper を解決できません" >&2; exit 1; }
     default_ref="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD)" || { echo "origin/HEAD を解決できません。git remote set-head origin --auto 後に再実行してください" >&2; exit 1; }
     [[ "$default_ref" == origin/* ]] || { echo "origin/HEAD が不正です" >&2; exit 1; }
     default_branch="${default_ref#origin/}"
     for document in docs/08-knowledge/PLAYBOOK.md docs/03-implementation/PATTERNS.md; do
       if git diff --quiet "origin/${default_branch}" -- "$document"; then diff_rc=0; else diff_rc=$?; fi
       case "$diff_rc" in 0) continue ;; 1) ;; *) echo "文書差分を検査できません: $document" >&2; exit 1 ;; esac
       "$FF_DEV_TOOLKIT_ROOT/scripts/update-version-claim.sh" --base "origin/${default_branch}" --document "$document" || exit 1
     done
   fi
   ```

### コミット

**既定 — chore PR**: 本スキルは既存本文の書き換えを含むため、レビュー経路を既定とする。

```bash
git checkout -b chore/ace-refine-<YYYYMMDD>
git add docs/08-knowledge/ docs/03-implementation/PATTERNS.md || { echo "ACE 変更を stage できません" >&2; exit 1; }
if [[ -d .version-claims ]]; then
  if git diff --cached --quiet -- docs/08-knowledge/PLAYBOOK.md; then playbook_diff_rc=0; else playbook_diff_rc=$?; fi
  case "$playbook_diff_rc" in
    0) ;;
    1) [[ -f .version-claims/docs/08-knowledge/PLAYBOOK.md.claim ]] || { echo "PR 経路に PLAYBOOK version claim がありません" >&2; exit 1; }; git add .version-claims/docs/08-knowledge/PLAYBOOK.md.claim || { echo "PLAYBOOK claim を stage できません" >&2; exit 1; } ;;
    *) echo "PLAYBOOK の staged 差分を検査できません" >&2; exit 1 ;;
  esac
  if git diff --cached --quiet -- docs/03-implementation/PATTERNS.md; then patterns_diff_rc=0; else patterns_diff_rc=$?; fi
  case "$patterns_diff_rc" in
    0) ;;
    1) [[ -f .version-claims/docs/03-implementation/PATTERNS.md.claim ]] || { echo "PATTERNS version claim がありません" >&2; exit 1; }; git add .version-claims/docs/03-implementation/PATTERNS.md.claim || { echo "PATTERNS claim を stage できません" >&2; exit 1; } ;;
    *) echo "PATTERNS の staged 差分を検査できません" >&2; exit 1 ;;
  esac
fi
[[ ! -d .version-claims ]] || "$FF_DEV_TOOLKIT_ROOT/scripts/check-version-claims.sh" --root "$(git rev-parse --show-toplevel)" || exit 1
git status --short  # 意図したファイルのみが含まれるか確認
git commit \
  -m "knowledge: ace-refine <YYYY-MM-DD> <要約（例: archive 12 件 / compact 5 件）>" \
  -m "Archived: <ID...>" \
  -m "Compacted: <ID...>" \
  -m "Merged: <ID -> ID ...>" \
  -m "Promoted: <ID...>"
git push -u origin chore/ace-refine-<YYYYMMDD>
gh pr create --base <default-branch> --title "knowledge: ace-refine <YYYY-MM-DD> <要約>" --body "..."
```

**例外 — デフォルトブランチ直コミット**: 操作がアーカイブのみ・5 件以下の場合に限り、`/ace-curate` と同様に `<default-branch>` へ直接 commit + push してよい。

直 push でも、上の PR block と同じ claim 生成を commit 前に実行する。`.version-claims` があるのに PLAYBOOK（および変更した PATTERNS）の claim が無い・stale のままなら commit せず停止する。

直 push が non-fast-forward で拒否された場合は、remote の整理結果を保全して最新 tree からレポート・version・`ace_entry_count`・Changelog を再生成する。さらに**各再試行で**上の claim block と同じ claim 生成（既存 claim を退避し、上書き禁止 hard link で install）・3行完全一致検証を最新 base からやり直し、変更した文書の claim を stage してから、全ゲートを再実行して通常 push を**最大 3 回**再試行する。収束しなければ直列化を求めて停止し、force push で上書きしない。

> **コミット件名と PR タイトルは `knowledge:` で始める**（squash 時は PR タイトルが件名になるため両方必須）。`ace-reuse-report` は `knowledge:` 件名のコミットを参照集計から除外する。refine コミットは大量の ACE ID を含むため、この接頭辞が無いと全エントリの git 参照カウントが汚染され、以後の stale 判定が壊れる。

### 結果レポート

```
## ACE refine 完了レポート

**対象**: <カテゴリ or --all>
**Archived**: X 件（ACE-...）
**Compacted**: X 件（合計 NNN 行削減）
**Merged**: X 組
**Promoted**: X 件
**スキップ（ユーザー否認）**: X 件
```

## ハードルール

- **dry-run レポートの提示とユーザー承認より前に、いかなるファイルも書き換えない**
- **原文はアーカイブへ verbatim で保全する。保全なしの削除・要約は禁止**（アーカイブファイルへの writeが確認できるまで live 側を消さない）
- **エントリ ID と anchor は live・アーカイブの双方で改名しない**（外部参照・blob URL の互換維持）
- **archive へ追記する前に既存出現数を数え、保全済み ID には原文を再コピーしない**（保全検証は「存在（≥1）」ではなく「一意（=1）」で行う。R3-0 / ACE-490-2）
- **provenance 注記は実際に行った操作に対応する変種を使う**（本文を要約していないのに「要約済み」と書かない。archive は監査記録である）
- **保全本文内の `./` 相対リンクは書き換えない。代わりに archive ファイル冒頭の「保全本文内の相対リンクは live 基準」注記を必須とする**（`check-archive-links.ts` が強制する）
- **統合される側は archive 側のコピーの `Status` を `merged` に変える**（`active` のまま残すと grep した人に有効なエントリとして誤読される）
- **カウンターは統合時の合算以外変更しない（減算・リセット禁止）**
- **既存エントリ本文の書き換えは本スキル実行中のみ許可（/ace-curate は append-only のまま）**
- **コミット件名と PR タイトルは `knowledge:` で始める**
- 候補が 1 件も承認されなかった場合は「整理対象なし」と報告して終了する（空コミットを作らない）
