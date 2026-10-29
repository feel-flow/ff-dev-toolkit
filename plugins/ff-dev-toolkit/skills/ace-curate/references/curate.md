# `/ace-curate` の詳細規則（Phase 2 の根拠・共有値の確定前ガード・索引の列順・Jev）

本線は判断点と実行部だけを持つ。次の条件に当たったときにここを読む: 独自配置の PLAYBOOK を扱う / 抽象度の下限で迷う / 新規性判定を Jev へ投げる（`FF_JEV_MODE=on`）/ 4-b で共有値を確定する / 索引の列順が雛形と違う PLAYBOOK に追記する / 同梱 TypeScript ゲートの runner を差し替える / コミット経路（保護判定・commitlint・non-fast-forward・chore PR）を確かめる。

## 配置先の解決（最初に実施）

解決は同梱 `scripts/knowledge-lookup.sh --resolve-playbook` に任せ、規則を手で再現しない（規則の正本は同スクリプトの `resolve_playbook`。`/knowledge-lookup` の着手前参照と同じ関数で、片方だけ直って食い違うことを構造で防ぐ）。順は `ACE_PLAYBOOK_PATH` → 記録済み配置（root の AGENTS.md / CLAUDE.md / `docs/MASTER.md` に書かれた `PLAYBOOK.md` のパスのうち実在するもの）→ 既定 `docs/08-knowledge/PLAYBOOK.md` → root 配下の探索（`docs-template/` は探索からだけ外す）。出力は `ACE_PLAYBOOK=`（絶対パス）/ `ACE_PLAYBOOK_REL=`（root 相対。root の外なら空）/ `ACE_PLAYBOOK_SOURCE=` / `ACE_PLAYBOOK_STATE=` の 4 行。`STATE=ambiguous`（記録の矛盾、既定パスに実体があるのに記録が別を指す、探索の複数候補）と `absent` は変更前に報告して止める。`ACE_PLAYBOOK_REL` が空（repo 外）・symlink で repo 外へ出る配置は編集しない。独自配置では前提確認・検索・採番・全ゲート引数・`add` のパス・frontmatter・version claim の document と claim パス・索引相対リンクをすべて解決した配置へ置換してから実行する。固定パスをそのまま実行して第二の Playbook を作らない。ゲート引数は明示した実配置を使い、環境変数を既定引数で上書きしない。

## curate 側のハードルール（`/ace-refine` との分担）

- エントリの追記は**末尾のみ**。既存エントリの本文（新形式の本文 / 旧形式の Insight/Context/Action）の書き換えは禁止
- **既存エントリの要約・アーカイブ・統合は `/ace-refine` のみが行う**（本スキルは grow 専用。refine 側は dry-run → ユーザー承認 → 原文アーカイブ保全付きで行う）
- 4-e の行数バジェット自己チェック（必須・ブロッキング）: 各エントリのブロック行数は 15 行以内（例外マーカー付きでも 30 行以内）を追記前に自分で数える。超えるなら本文を削ってから追記する
- 形式ゲートが赤なら、追記したエントリをコンパクト正準フォーマットへ書き直す。`legacy-format-allowlist.txt` に新規 ID を足して通すことはしない（allowlist は既存エントリの読み取り互換のためのものであり、新規追記の抜け道ではない）

## 同梱 TypeScript ゲートの runner（4-b-0 / 4-f）

4-f の「`scripts/ace/<同名>` が実在」はファイルごとに確かめる。別の npm script が指す配下（例: Playbook を `docs-template/` に置くリポジトリの `docs-template/scripts/ace/`）にスクリプトが一部あっても、同期検証・形式ゲートのスクリプトが同居しているとは限らない。推測で起動すると `ERR_MODULE_NOT_FOUND` で 1 往復する。

同梱テンプレートを叩く経路で `npx --yes tsx` を直接書かない。root package に `tsx` binary が無い workspace 環境では `tsx: command not found` でゲートに到達できず、手作業照合へ戻る動きが実測で起きた。`ace-run-ts.sh` は候補を**実際に起動して**確かめながら次の順で解決する — `FF_ACE_TS_RUNNER`（明示指定。`pnpm --filter <pkg> exec tsx` のような複数語も可） → PATH の `tsx` → 上位ディレクトリを含む `node_modules/.bin/tsx` → `pnpm` / `yarn` の `exec` → `npx --yes tsx`。どれも起動できなければ exit 3 で停止する（黙って手作業へ戻さない）。

## 抽象度の下限（第 2 の関門・ADR-047）

同一性で落ちなかった候補には、**書く前に**抽象度の下限を当てる。判定は「**適用条件が固有名なしで書けるか**」。本文（タイトル・適用条件・アクション）の固有名（Issue/PR 番号・ファイルパス・特定コマンド/API/スクリプト名）を 1 つずつ「別の名前へ置き換えても主張とアクションが成立するか」で試し、成立するものは 1 段上の性質へ書き直す（固有名は**例示として**残してよい）。1 段上げた形で既存エントリと同一のアクションになるなら、そこで `Helpful` +1 へ落ちる — このバーが無いと、同じ性質の次の事象が「取るアクションが違う」と判定されて新規追加され続ける。

**上げすぎたら棄却する**: 新規性バーを逆向きに使い、上位主張から**元の候補と既存エントリそれぞれのアクションが再導出できるか**を確かめる。できないなら抽象化を棄却して元の粒度で書く。固有名がアクションの本体である類型（プラットフォーム実装差 / 特定 CLI の usage と実挙動の乖離 / 言語ランタイム仕様 / 診断メッセージと原因の対応表 / 既に 1 段上の主張）は抽象化しない。判定材料と類型の詳細は PLAYBOOK §運用ルール「抽象度の下限と棄却基準」。

**機械では止まらない**: 抽象度の下限は `/ace-curate` を exit 1 で止めるゲートではない（機械シグナル単独の精度は 47%）。候補の提示は `ace-abstraction-report.ts` が行い（候補が何件出ても exit 0）、判定はチェックリストで行う。

このバーが必要な理由: 件数を減らせるのは archive と統合の 2 つだが、**archive の供給は「作成から閾値日数の経過 かつ（git 参照が無い または 最終参照から閾値日数の経過）かつ `helpful === 0`」に限られる**のに対し、流入は curate のたびに発生する。出口の述語が狭い以上、入口で絞らなければブロック上限到達は時間の問題になる。

**新規性バー（件数の入口制御・ADR-033）**: 判定は「読者が取る実行可能なアクションが既存エントリと同一か」で行う。文言や事例が違っても導かれる行動が同じなら、それは新規知見ではなく既存エントリの再確認であり、`Helpful` +1 が正しい記録先である。**追記件数の上限は設けない**。domain では同じアクションでも主体・条件・例外・確認状態が異なれば同一知識としない（確認状態の違いを Helpful 加算で消さない）。

**一回性のインシデント叙述**: 特定障害のタイムライン・復旧ログ・環境固有の調査記録は再現性ゲート「低→スキップ」の適用対象であり、Playbook ではなく `docs/08-knowledge/TROUBLESHOOTING.md` や runbook へ記録する。Playbook に残すのは「次に同型の状況で使える主張」だけ。

## triage

`FF_JEV_MODE=on` のときだけ、新規性の判定前に次の triage 入口を呼ぶ（`CANDIDATE` は候補 1 件の本文）。原則の glob は `FF_PRINCIPLES_GLOB` で指定し、未指定・一致なしは live Playbook を使う。`off` はこの節が存在しないのと同じで、呼び出さず従来経路の出力をバイト同一に保つ。

<!-- ff-triage-entry:start -->
```bash
if [ "${FF_JEV_MODE:-off}" = on ]; then
  triage_rc=0
  bash "${FF_DEV_TOOLKIT_ROOT}/scripts/jev/triage-candidate.sh" --candidate "$CANDIDATE" || triage_rc=$?
  case "$triage_rc" in 0|10|11|12) ;; *) exit "$triage_rc" ;; esac
fi
```
<!-- ff-triage-entry:end -->

exit 0 の分類は人が最終判断し、`reduces_to` は該当原則へ畳む（ACE なら Helpful +1、core 文書なら証跡へ記録しカウンターを新設しない）。`new_invariant` だけを下の評価へ進め、`one_off_measurement` はプロジェクトの evidence 文書へ、`noise` は理由 1 行を残して捨てる。exit 10 / 11 / 12 は出力の `top_k` と `measurement_hint` を参考に従来の判断へ戻る。triage 済み候補を `novelty` へ再送しない（二重走行なし）。判断を覆した場合は出力の `decision_ids` の該当 ID を `triage-candidate.sh --overturn <id> --note <理由>` で記録する。原則の読み方・終了コードは [Jev README](../../../scripts/jev/README.md#知識候補の選別triage) が正本。

## Jev への切替（`FF_JEV_MODE`・既定 off・ADR-059）

triage 未実施の候補に限り、新規性バーの判定は `FF_JEV_MODE=on` のときだけ Jev（TypeSafe AI の System One Model）へ先に投げてよい。候補ごとに、照合で読み込むカテゴリ（候補カテゴリ + 似たタイトルが見つかったカテゴリ）の中から、候補と語の重なり（Jaccard 類似度。offline 評価の生成器 `build-ace-eval-sets.ts` の近傍選択と同じ）が大きい順に最大 5 件を近傍エントリとして選び、1 件ずつ state（`id` / `category` / `title` / `body`。日本語のまま）にして次を呼ぶ:

```bash
# 判定点 novelty。質問 fixture は /retrospective の観測同一性判定と同一ファイル（基準が同じなので文言も 1 つ）
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/jev/jev-decide.sh" novelty \
  --questions "${FF_DEV_TOOLKIT_ROOT}/scripts/jev/questions/same-action.json" \
  --state-file <近傍エントリ JSON> --fill CANDIDATE=<候補の一行要約ファイル>
```

- **exit 0（adopt）のときだけ** Jev の判定を採る: `ANSWER=same_action|noul|<p>|<confidence>` の p ≥ 0.5 なら「重複」（その近傍エントリの `Helpful` +1）、p < 0.5 なら「その近傍とは別アクション」。5 件すべてが別アクションなら新規
- **exit 10 / 11 / 12 は従来どおりチェックリストで判定する**（10 = confidence が閾値未満、11 = Jev の失敗〔無効・キー無し・通信・応答不正・記録先へ書けない〕、12 = `off` または判定点が `FF_JEV_POINTS` に無い）。exit 2 / 64 / 69（入力不正・設定値の誤り・jq 不在）は従来経路へ黙って落とさず、止めて直す。二重走行はしない
- `off`（既定）では**この節は存在しないのと同じ**で、手順・出力・追記件数は従来と同一。`on` にしても Playbook の内容と `knowledge:` コミットの形は変わらず、採用 / fallback の記録は作業ツリーの外（`jev-decide.sh --status` の `JEV_LOG`）にだけ残る（`--summarize` で採用率と帯別件数、`--overturn <id>` で覆した記録）
- 有効化・閾値・判定点の名簿・戻し方の正本は `${FF_DEV_TOOLKIT_ROOT}/scripts/jev/README.md` §切替

## 共有値の確定前ガード（4-b〜4-d の直前）

`version` / `ace_entry_count` / Changelog は、着手時のローカル値から決めない。作業ツリーが clean な状態で default branch を解決し、明示 refspec で remote-tracking ref を更新する。fetch 失敗・ref 解決不能・diverge は stale 値へ fallback せず停止する。

```bash
default_ref="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD)" || {
  echo "origin/HEAD を解決できません（git remote set-head origin -a を実行してください）" >&2
  exit 1
}
[[ "$default_ref" == origin/* ]] || { echo "default branch ref が不正です: $default_ref" >&2; exit 1; }
default_branch="${default_ref#origin/}"
[[ -z "$(git status --porcelain --untracked-files=all)" ]] || { echo "PLAYBOOK 追記前に作業ツリーを clean にしてください" >&2; exit 1; }
if ! _fetch_err="$(git fetch origin "+refs/heads/${default_branch}:refs/remotes/origin/${default_branch}" 2>&1 >/dev/null)"; then
  _fetch_err="$(sed -E 's#(://)[^/[:space:]]*@#\1***@#g' <<<"${_fetch_err:-（原因は出力されませんでした）}")"
  echo "origin/${default_branch} を取得できません（stale 値で版を確定しない。認証・通信・remote 設定を確認）: ${_fetch_err}" >&2
  exit 1
fi
git rev-parse --verify --quiet "refs/remotes/origin/${default_branch}" >/dev/null || {
  echo "remote-tracking ref を解決できません: origin/${default_branch}" >&2
  exit 1
}
git merge-base --is-ancestor "origin/${default_branch}" HEAD || {
  echo "origin/${default_branch} を取り込んでから採番・版確定をやり直してください" >&2
  exit 1
}
```

fetch が失敗した回は、停止メッセージの末尾へ git が出した原因をそのまま付ける（git の stderr は remote URL を含みうるので、表示の前に `https://user:token@host/` 形の資格情報部だけを `***` へ伏せる）。remote が先行していた場合は**追記前に** `git pull --ff-only origin <default-branch>`（直 push フロー。detachedでもremote/branchを明示）または `git rebase origin/<default-branch>`（専用ブランチ）で取り込む。fresh read は同時 read を防がない。直 push の最終境界は手順 5 の non-fast-forward である。

`.version-claims` contract があるリポジトリでは、**直 push / PR のどちらでも** PLAYBOOK.md と同じ commit で `.version-claims/docs/08-knowledge/PLAYBOOK.md.claim` を `document` / `version` / `change` の3行だけへ更新する（手順 5 の `finish.sh knowledge-commit add --claim docs/08-knowledge/PLAYBOOK.md` が `scripts/update-version-claim.sh` で最新 base/current の blob ID から生成し、`scripts/check-version-claims.sh` で検証してから記録パスへ足す）。version 不変のカウンター更新でも `change` は更新するため、直 push と進行中 PR の交差も claim conflict で止まる。祖先検査後に同じ文書の別更新が先行しても、claim の content conflict で停止させ、最新 base から version / `ace_entry_count` / Changelog / claim を再生成する（claim の片寄せ・削除で競合を解消しない）。

## worktreeセッションからの知見記録

`/merge-cleanup <PR番号>` のswitchなし掃除が済んだ自分のworktreeで、**知見を書き始める前**に実施する。他worktreeへ移動せず、そこにあるdefaultや作業ブランチを切り替えない。

1. `git status --porcelain` が空であること、`finish.sh knowledge-commit status` でadd保留が無いことを確認する。未pushの成果は元のブランチへ保持し、先に解決する。保留のあるブランチを切り替えない。
2. `git symbolic-ref --quiet --short refs/remotes/origin/HEAD` から `origin/<default-branch>` を確定する。未設定なら `git remote set-head origin --auto` を実施して再確認し、解決失敗は停止する。PRのbaseをdefaultと決めつけない。
3. `git fetch origin "+refs/heads/<default-branch>:refs/remotes/origin/<default-branch>"` が成功してから、`git switch --detach origin/<default-branch>`。現在のHEADと取得したrefが同じことを実測する。`reset --hard`を使わず、他worktreeのdefaultは動かさない。
4. PR番号を明示して抽出・共有値の鮮度検査・編集・検証を行い、同じdetached HEADで `finish.sh knowledge-commit add` → `commit` → `push` を使う。pushは実装どおり `HEAD:<default-branch>` を送る。素の `git push origin <default-branch>` はローカルbranch refを送るため代用しない。送信SHA・到達・CIを本書の「直 push の実測ガード」で確認する。

追記前にremoteが先行したら、detachedでは `git pull --ff-only origin <default-branch>` とremote/branchを明示して取り込み、採番・版確定からやり直す。knowledgeのadd保留がある場合は同じHEADで先にcommitするか、既存の保留復帰手順を使い、保留を持ったままswitchしない。push後のnon-fast-forwardは後段の再試行規則に従う。

**保護時のPR経路**: `probe` が protected なら知見の add 前に一意の `chore/ace-from-*`（台帳のみは `chore/retro-from-*`）を自分の detached HEAD から `git switch -c` で作り、同じ add・検証・commit を行う。unknown から直 push を試して rc 3 になった場合は、commit を保ったまま一意の知見ブランチを作る。いずれも `finish.sh knowledge-commit pr` へ実際の知見ブランチ名を `--branch` で渡す。**既存知見ブランチ開始時は local default を復帰せず、他 worktree も変更しない**。呼び出す前に fetch 成功と `origin/<default-branch>` が HEAD の祖先であること、`git rev-list --count origin/<default-branch>..HEAD` が 1、差分パスが今回の PLAYBOOK・カテゴリ本文・保留候補・台帳・対応 claim だけ、commit 件名が知見記録であることを実測する。いずれかを満たさなければ送信せず停止する。helper は fetch 後に送信コミット数が 1 であることを再照合する。祖先・対象パス・件名は呼び出す側が確認する。保護判定・commit の対象限定・内容検証・PR のレビューとマージは省略せず、他 worktree の detach を復帰手段にしない。実際の PR 経路と到達状態を報告する。

## 索引テーブルの列順（4-b）

**列順は雛形からではなく、その PLAYBOOK の索引テーブルのヘッダ行から決める。** 導入先ごとにヘッダの列順が違うため、固定の列順を写すと索引だけが本文と列の意味が食い違う行になる。手順:

1. `## エントリ一覧` 直下の表の**ヘッダ行**を読む（`|` で始まる最初の行。直後が `| --- | ... |` の区切り行）
2. ヘッダの各セルを 4 つの役割へ対応付ける — **ID**: `エントリID` / `ID` / `ACE ID`、**タイトル**: `タイトル` / `Title`、**カテゴリ**: `Category` / `カテゴリ`、**参照先**: `参照先` / `Link` / `リンク`
3. 4 つの値を**ヘッダの出現順どおりに**並べて 1 行を書く。値は ID = `ACE-XXX`、タイトル = 見出しのタイトル、カテゴリ = エントリ本文の `| Category |` 行と**同じ値**、参照先 = `[playbook/<category>.md#ace-xxx](./playbook/<category>.md#ace-xxx)`。対応する列がヘッダに無い役割は値を書かない（列数はヘッダに合わせる）
4. 書いた行のセル数がヘッダのセル数と一致することを確認する。セル内の `|` は `\|` へエスケープする（**インラインコードスパンの中でも要る** — ``` `cmd | head` ``` は列を 1 つ増やす）

ヘッダが `| エントリID | タイトル | Category | 参照先 |` なら `| ACE-XXX | [タイトル] | [カテゴリ] | [playbook/<category>.md#ace-xxx](./playbook/<category>.md#ace-xxx) |`、`| ID | Category | Title | Link |` なら `| ACE-XXX | [カテゴリ] | [タイトル] | [playbook/<category>.md#ace-xxx](./playbook/<category>.md#ace-xxx) |`。どの役割にも対応付かない列は既存行の同じ列の形に合わせる。`check-category-size` は索引行のカテゴリ列を本文と突き合わせて食い違い・列数不一致を警告する。

<a id="changelog-layout"></a>

## Changelog 配置と明示対象

従来受理された `ACE-A・ACE-B` の束ねHelpful行で停止したら、同じ理由を各IDの行へ分ける。既存エントリのHelpful値は増減せず、履歴の形式だけを修正する。既存エントリ本文の書換え禁止はこの履歴形式修正を妨げない。

Changelog は有効な本体を優先し、節不在・空スタブなら同階層 `CHANGELOG.md` / `playbook/CHANGELOG.md` の固定候補を確認する。候補複数・不正行・読取不能は停止し、任意リンクを辿らない。採用したファイルのリポジトリ相対の実パスを `ACE_CHANGELOG_REL` に保持し、その形式を維持して追記する。確認済み旧形式は `## v版番号 (日付)`・`- 追加: ACE-ID（分類）`・`- 更新: ACE-ID Helpful +1（理由）` を使い、Helpful は1行1IDにする。今回変更した採用先は手順5で明示対象へ含める。探索は指定外ファイルを暗黙にstageする許可ではない。

<a id="history-update-rules"></a>

## Frontmatter・Changelog・行数

`version` は新規エントリ追加で **minor +1**（カウンター更新のみは不変）、`updated` を今日へ、`changeImpact` は `medium`。`ace_entry_count` は merged tree の live エントリ実数から再計算する。Changelog は手順4-bの採用先・書式の先頭へ当該版のブロック（空を禁止）。正規書式の `#### カウンター更新`・旧書式の `- 更新:` は 1 行 1 ID。各エントリのブロック行数は **15 行以内**（`<!-- ace-line-budget-exception: 理由 -->` 付きでも **30 行以内**）を自分で数える。

## 旧形式との互換

- ヘッダ行・区切り行を持たないメタ 4 行は GitHub 上ではテーブルとして描画されない（AI ファースト文書として意図した仕様。詳細は PLAYBOOK.md §エントリテンプレート）
- 旧テーブル形式（`| フィールド | 値 |` + Insight/Context/Action）のエントリは**読み取り互換として共存**させる。重複時の `Helpful` +1 は、旧形式なら `| Helpful | n |` 行、新形式なら `| Helpful | n | Harmful | m |` 行の n を +1 する
- Changelog の `#### カウンター更新` には **ID ごとに 1 行**を書く（`- ACE-X: Helpful +1（理由）` / `- ACE-X: Helpful +1 ×N（理由）` / `- ACE-X: Helpful +1 — 理由`）。同じ理由でも ID が 3 つなら 3 行にする。複数 ID を `- Helpful +1: ACE-A / ACE-B（理由）` の形へ束ねると Jev の評価セット生成器（`scripts/jev/build-ace-eval-sets.ts` の `parseChangelog`）が exit 2 で止まり、書き込み口の `add` が同じ判定（`scripts/lib/playbook-changelog-functions.sh`）でその行を名指しして止まる。`#### 変更` / `#### 更新` など他の見出しの配下は読まないが、カウンター更新を他の見出しへ逃がさない
- 既存の ID なしエントリ（`## [Pattern] ...` 形式等）や旧連番エントリ（3 桁・4 桁以上とも）は改名・書き換えしない（エントリID規則「既存 ID の扱い」）。採番ルールの SSOT は PLAYBOOK.md §エントリID規則
- 機械同期する場合はプロジェクトの `ace:bump-playbook-frontmatter`（`--write --bump-version`。**minor +1**）。count のみ直すなら `ace:sync-playbook-frontmatter`。`--write` は変更済みなのに `changeImpact` が欠落している場合 `medium` を自動追記する（`/validate-docs` が「変更済みなのに未記録」を赤にするため放置しない）

## コミット（手順 5）の規則

マージ方針の SSOT は [git-workflow.md ステップ10 §運用パターン（マージ方針）](../../../docs-template/05-operations/deployment/git-workflow.md#ace-merge-policy)（`docs-template/` 全体を導入している場合の参照。無ければ以下の既定に従う）。

**保護判定（必須・直 push を試す前に行う）**: `finish.sh knowledge-commit probe` が classic branch protection API（`gh api "repos/${owner_repo}/branches/${default_branch}/protection"`。404 は「classic ルールが無い」を意味するだけで、Rulesets のみで保護されたブランチでも 404 を返す。200 でも直 push を止める `required_pull_request_reviews` / `required_status_checks` / `restrictions` のどれか、または署名必須・読み取り専用（`required_signatures.enabled` / `lock_branch.enabled` が true）があるときだけ protected とし、どれも無ければ（force push の禁止だけ等）`classic=protected-no-pr` として rulesets の判定へ進み、rulesets に `pull_request` type が無い場合のみ `unprotected` になる。署名必須と読み取り専用を含めるのは、どちらも 3 項目が null のまま直 push を GH006 で拒否するため — 含めないと旧判定（200 なら protected）で PR 経由だった保護が直 push の拒否へ退行する）と rulesets API（`gh api "repos/${owner_repo}/rules/branches/${default_branch}"`。直 push を PR 必須にする `pull_request` type の有無だけを見る — `non_fast_forward` 等 direct push を禁止しない type だけなら unprotected）の両方を見て `protection=protected|unprotected|unknown` を出す。`protected` → PR 経由へ / `unprotected` → 既定（直 push） / `unknown`（`gh` 不在・401/403・ネットワーク失敗。保護判定後に設定が変わる TOCTOU の受け皿でもある） → 既定を試し、push が `Changes must be made through a pull request` または `push declined due to repository rule violations` で拒否されたら PR 経由へ切り替える（`finish.sh knowledge-commit push` が同じ文言を検知して rc 3 を返す。classic 保護の拒否全般（`Protected branch update failed`）・必須チェック（`Required status check`）・push の制限（`not authorized to push`）による拒否も、判定が外れた回の安全網として rc 3 に寄せる）。

<!--4bf12dab29f70e8c-->
MCP: 取得値: MCP の repo nameWithOwner と対象 branch の classic protection / rulesets の実応答・HTTP status。形式: 同じ index の phase=probe に knowledge.repo（repository scope）、knowledge.classic-protection / knowledge.rulesets（repository / branch scope）を保存し、404 と 403 を区別する（rulesets の完全取得は last=true）。渡し先: knowledge-commit probe --github-input /absolute/index.json。不足時: 任意照会の不足・不成立は protection=unknown を保ち、既定 push の保護拒否 rc3 で PR 経路へ進む。

**既定（推奨）— デフォルトブランチ直マージ**: 保護されていない default branch にのみ適用。`<default-branch>` に直接 commit + push する。

**コミットメッセージ規約**: コミット前に対象リポジトリの規約を確認する。確認対象は (1) commitlint の `header-max-length` — 件名を上限内に収め、カテゴリが複数でも件名には列挙せず、commit body に記録する。要約だけで上限を超える場合は要約を短くするかコミットを分割する — に加え、(2) **type の許容リスト**。参照先: `commitlint.config.*` / `.commitlintrc*` / `package.json` の `commitlint` キー / husky・simple-git-hooks の `commit-msg` hook。`knowledge` が許容 type に含まれない場合は、プロジェクト規約の type（例 `chore`）へ件名の prefix だけを置き換える（件名の要約・body の `Categories:` 記録はそのまま維持する。例: `chore: ACE-<PR番号>-<連番> <要約>`）。書き込み口は件名を組み立てた直後、stage・保留記録・commit より前にリポジトリの prepare-commit-msg → commit-msg hook（core.hooksPath を反映した `git rev-parse --git-path hooks/<名>`。husky も同じ経路）へ `git commit -m` と同じ順で件名をドライランで通す。元の件名が通れば件名・出力は従来どおり。拒否された既定 `knowledge` は `chore` → `docs` の候補も同じ hook で検証し、Issue が必要ならブランチの `ace-from-pr-N` → PR の closing Issue 先頭、次にブランチ自身の `#N` を解決して `<type>: #<issue> <ID> <要約>` を検証する（`--claim` は version claim 用で PR origin は持たず、ACE-ID・要約の数字も解決元にしない）。選んだ Issue/type は保留へ保存して合流先の commit が引き継ぐ。明示された非 `knowledge` type は置換しない。解決元が無い・どの候補も拒否される場合だけ hook の出力（要求形式）を示して rc 4（`KNOWLEDGE_COMMIT=hook-rejected`）で止まる。`add` の拒否は保留記録を作らない（`--claim` 経由では文書と claim の stage は残る）ので `discard` は要らない — 解決に失敗した場合だけ、表示された規約を確認して `add --type` で再実行するか、書いたパスへ固定した `git commit -m "<規約どおりの件名>" -- <書いたパス>` で手でコミットする（pathspec 無しの `git commit` にしない）。

**文字列パッチと commit の突き合わせ（必須）**: PLAYBOOK・文書への追記を script で当てる場合は [Markdown 文字列パッチ規律](../../../docs-template/05-operations/deployment/markdown-patch-discipline.md)に従い、`add` の前に `git status --short` で意図したファイルのみが変わっていることを述語で突き合わせる。書き込み口は `add` 時の blob hash を記録し、その後に同じファイルへ入った別の編集を commit へ吸い込まない。

**送信範囲ガード**（`finish.sh knowledge-commit push` と `pr` の両方が、ブランチ作成・push より前に行う）: fetch 後の `origin/<default-branch>..HEAD` が knowledge コミット 1 つだけでなければ rc 2（`KNOWLEDGE_PUSH=scope-mismatch` / `KNOWLEDGE_PR=scope-mismatch`）で止め、無関係な未 push コミットを一緒に送らない。コミットの中身は `commit` 側が読み戻す: 記録外のパスが入っていたら（commit 前フックが一時索引へ足した場合など）そのコミットを取り消して `KNOWLEDGE_COMMIT=scope-mismatch` の exit 1 で止まり、保留記録を残す。push へ進まず、フックの設定を直すか記録外のパスを退避（`git stash push --include-untracked -- <記録外のパス>`。未追跡のファイルも退避できる）してから `commit` を再実行する。

**直 push の実測ガード**（`finish.sh knowledge-commit push` が行う）: コミット先ブランチを `git symbolic-ref -q --short HEAD` で実測し、detached HEAD なら refspec を `HEAD:<default-branch>` にする（merge-cleanup の退避などで detached のまま `git push origin <branch>` を打つと、ローカル branch ref が送られ「Everything up-to-date」で成功に見えたまま届かない）。push 出力はファイルへ落として `-> <default-branch>` を照合する（パイプで tee へ流すと終了コードが失われ、rejected 出力を成功と誤読する）。push 後は `gh run list --branch <default-branch> --limit 5 --json status,conclusion,workflowName,headSha` で今 push した SHA の run を見る（直 push は PR 画面に出ないため）。`in_progress` / `queued` は完了を待って再確認し、`failure` なら revert ではなく ACE コミットを前進で直して push し直す。一覧が空の CI 無しリポジトリはそのまま進んでよい。

<!--866666a04b981ccc-->
MCP: 取得値: MCP でpush した SHA の run status / conclusion / workflowName / headSha を取得。形式: knowledge の post-push CI raw を同じ index に保存。渡し先: knowledge-commit push の --github-input へ渡し同じ SHA の完了を判断する。不足時: 任意 CI 不足は unavailable を報告して続行し、成功と読み替えない。

**non-fast-forward で拒否された場合**（保護ルールによる拒否は rc 3 で PR 経由へ自動的に切り替わるため対象外）は、別セッションの更新を検出した正常な競合経路として次を**最大 3 回**繰り返す:

1. 同じ明示 refspec で `origin/<default-branch>` を再取得する（失敗時は停止）
2. remote の版ブロック・エントリ・索引を保全して rebase し、自分のエントリを残す。同じ版番号へ内容を混ぜず、自分の版を remote 最新の次へ繰り上げる
3. `ace_entry_count` を merged tree の live 実数から再同期し、version / Changelog を再生成する
4. **各再試行で** `add --claim docs/08-knowledge/PLAYBOOK.md` からやり直す（claim を最新 base から再生成し、3行完全一致検証を通してから stage する）
5. 手順 4-f の全ゲートを再実行し、commit を amend して `push` を再試行する

3 回で収束しなければ「共有版境界が高頻度更新中」と報告して直列化を求める。`--force` / `--force-with-lease` で先行セッションを上書きしない。

**既存知見ブランチの保留合流**: 本線の前提で許可している既存の `chore/ace-from-*` から実行した回は、新しいブランチを作らない。`ACE_DEFER_TO_RETRO=1` なら add までで止め、保留を同じブランチの `/retrospective` へ渡す。retrospective は OBS add → 共通 commit → 実測現在名を渡した `knowledge-commit pr` で完了する（[送信規則](../../retrospective/references/ledger.md#保留の合流と送信経路)）。保留を持ったまま switch しない。defer が無い回も本線が現在のブランチ名を `ACE_BRANCH` に採り、push を試さず pr へ進む。

**任意エスカレーション — chore PR**: 大人数チーム / 知見レビューを残したい場合のみ、というのが既定の位置づけだが、**default branch が保護されている場合はこの経路が必須**になる。以下は新規専用ブランチの独立 PR 経路で、既存ブランチの保留合流と区別する。手順1で固定した `ACE_BRANCH` で小さい PR を作成する（コミット type は上の許容リスト確認に従う）:

```bash
git checkout -b "$ACE_BRANCH"
commit_type="knowledge"
# playbook/ 配下は変更・追加したファイルだけを渡す（サブディレクトリのカテゴリファイルへの Helpful +1 も拾う。glob の playbook/*.md は直下しか当たらない）
# 既定配置の例。独自配置なら解決済みACE_PLAYBOOK_RELの親へ置換する。
ACE_KNOWLEDGE_PATHS=(docs/08-knowledge/PLAYBOOK.md)
. "${FF_DEV_TOOLKIT_ROOT}/scripts/lib/playbook-changelog-functions.sh" || exit 2
ACE_CHANGELOG_FILE="$(ff_playbook_changelog_select docs/08-knowledge/PLAYBOOK.md)" || { printf '%s\n' "$ACE_CHANGELOG_FILE" >&2; exit 2; }
ACE_CHANGELOG_REL="$(git -C "${ACE_CHANGELOG_FILE%/*}" rev-parse --show-prefix)${ACE_CHANGELOG_FILE##*/}" || exit 2
if [[ "$ACE_CHANGELOG_REL" != docs/08-knowledge/PLAYBOOK.md ]] && { ! git diff --quiet HEAD -- "$ACE_CHANGELOG_REL" || ! git ls-files --error-unmatch -- "$ACE_CHANGELOG_REL" >/dev/null 2>&1; }; then
  ACE_KNOWLEDGE_PATHS+=("$ACE_CHANGELOG_REL")
fi
while IFS= read -r kpath; do ACE_KNOWLEDGE_PATHS+=("$kpath"); done < <(git ls-files -mo --exclude-standard docs/08-knowledge/playbook)
if [ -f docs/08-knowledge/PENDING_CANDIDATES.md ]; then ACE_KNOWLEDGE_PATHS+=(docs/08-knowledge/PENDING_CANDIDATES.md); fi
ACE_CLAIM_ARGS=()
if ! git diff --quiet HEAD -- docs/08-knowledge/PLAYBOOK.md; then ACE_CLAIM_ARGS=(--claim docs/08-knowledge/PLAYBOOK.md); fi
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/finish.sh" knowledge-commit add ${ACE_CLAIM_ARGS[@]+"${ACE_CLAIM_ARGS[@]}"} --source ace --id "${ACE_ID}" --summary "${ACE_SUMMARY}" --category "<category[, category...]>" --type "${commit_type}" -- "${ACE_KNOWLEDGE_PATHS[@]}" || exit 1
# この新規専用 PR 経路は /retrospective へ合流させず、ここで即 commit する
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/finish.sh" knowledge-commit commit --type "${commit_type}" || exit 1
# push -u → upstream の照合 → gh pr create。default 開始時だけ local default を origin へ戻す
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/finish.sh" knowledge-commit pr --branch "$ACE_BRANCH" --title "${commit_type}: ${ACE_ID} ${ACE_SUMMARY}" --body "${ACE_ORIGIN} から知見抽出" || exit 1
# レビュー後 squash merge → /merge-cleanup
```

<!--da64d281c09543c5-->
MCP: 取得値: MCP でPLAN と一致する作成後 PR の head / base / title / body / SHA を取得。形式: knowledge fixture の fresh raw JSON を同じ index に保存。渡し先: knowledge-commit pr --github-input /absolute/index.json へ渡す。PLAN の原文を既存 create_pull_request で実 write 後に再実行する。不足時: 必須の MCP 能力 / 値が欠ければ操作名と項目を示して停止。

> `knowledge:` 付き PLAYBOOK 単独コミットの `<default-branch>` 直 push は意図的フローであり、通常のコード変更に対する「統合ブランチへの直 push 禁止」ルールとは別物として扱う。ただし default branch が保護されているリポジトリではこの経路に到達できない — その場合は保護判定に従い「PR 経由」（必須）を使う。


## GitHub file input

GitHub MCP などの取得済み raw を使う knowledge 操作では `finish.sh knowledge-commit <add|commit|probe|push|pr> --github-input /absolute/index.json` を明示し、各段へ同じ index を渡す。任意の closing Issue / protection / post-push CI が不足しても branch 由来の件名・unknown・CI unavailable を維持する。file の PR 作成は exact head/base/title/body と push 済み SHA の `PLAN` を出し、実 write 後の fresh raw PR が一致するまで rc2 待機で、完了印を出さない。Git push や復帰・clean ガードは通常どおり実行する。写像 fixture と live 取得、実 write/read-back は別に報告する。対応表は [knowledge fixture](../../../tests/github-input-knowledge/README.md)。

GitHub MCP などの raw を使う場合は、`knowledge-lookup.sh` / `workflow-doctor.sh` と `finish.sh knowledge-commit <add|commit|probe|push|pr>` の該当呼び出しへ同じ `--github-input /absolute/index.json` を明示する。任意取得の不足は未確認/SKIP/unknown/CI unavailable のまま続行し、`--offline` は lookup/doctor の file も読まない。knowledge PR の file 経路は実 write 後の fresh raw が exact head/base/title/body・push 済み SHA と一致するまで `PLAN` + rc2 で待機する。工数の集計は `effort-report.sh --repo OWNER/REPO --github-input /absolute/index.json` を使い、既存 `--input <raw-array>` と併用しない。新 index の必須 number/body 不足・別 repo・不正 JSON は operation/field を示して rc2、既存 raw 入力の rc は保持する。[knowledge fixture の対応表](../../../tests/github-input-knowledge/README.md)に写像・取得主体・完備性の確認境界を示す。


## エントリIDの採番

**PRスコープ式** `ACE-<PR番号>-<連番>`（資料単独は `ACE-i<Issue番号>-<連番>`）。既存 `ACE_ID_PREFIX-*` の最大連番 +1（無ければ `1`）。PLAYBOOK.md に「エントリID規則」節が無ければ同梱テンプレートから節ごとコピーする。既存の ID なし・旧連番エントリは改名しない。



## 結果レポート

```
## ACE サイクル完了レポート
**対象PR**: #[PR番号] [タイトル] / **抽出知見数**: X 件 / **新規**: ACE-438-1 / **カウンター更新**: ACE-016 (Helpful +1) / **スキップ**: X 件
**domain**: 評価済み（候補N件）または未実施（理由）/ source の取得済み・未確認 / 反映先未解決
**登録・push・CI**: 別々に報告する
```

**次のステップ**: ACE 完了後、ワークフローチェーンの末尾として `/retrospective` を実行する（`/merge-cleanup` → `/ace-curate` → `/retrospective`）。プロセス/ツール/スキルのメタ知見は ACE Playbook ではなく `/retrospective` の提案経路で扱う。

## エントリの正準フォーマット

```markdown
<a id="ace-XXX"></a>

### ACE-XXX: [検索可能な主張 1 文のタイトル]

| Category | [カテゴリ] | Origin | PR #[PR番号] |
| Date | [今日の日付] |
| Helpful | 0 | Harmful | 0 |
| Status | active |

[本文 2〜4 文。1 文目 = 知見の本質。非自明な適用条件が 1 文。推奨アクションで締める。手順の列挙・叙述は書かない]

---
```

## 同期検証のfallback

SSOT はプロジェクトの ACE 運用文書（例 `docs/05-operations/deployment/ace-cycle.md`）で、以下は無い場合の fallback。同期検証・形式ゲートそれぞれ、**プロジェクトの状態に合う 1 本だけを実行する**:

```bash
# 同期検証 — 1 本だけ: (1) npm script 登録済み / (2) scripts/ace/<同名> が実在 / (3) 無ければ同梱
npm run ace:check-playbook-frontmatter
npx --yes tsx scripts/ace/sync-playbook-frontmatter.ts docs/08-knowledge/PLAYBOOK.md --check
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/ace-run-ts.sh" "${FF_DEV_TOOLKIT_ROOT}/docs-template/scripts/ace/sync-playbook-frontmatter.ts" docs/08-knowledge/PLAYBOOK.md --check

# 形式ゲート（旧テーブル形式でないこと）— 1 本だけ: (1) scripts/ace/<同名> が実在 / (2) 無ければ同梱
npx --yes tsx scripts/ace/check-entry-format.ts docs/08-knowledge/PLAYBOOK.md
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/ace-run-ts.sh" "${FF_DEV_TOOLKIT_ROOT}/docs-template/scripts/ace/check-entry-format.ts" docs/08-knowledge/PLAYBOOK.md
```

同梱を叩く経路で `npx --yes tsx` を直接書かない（`ace-run-ts.sh` は runner が無ければ **exit 3 で停止**）。exit 0 になるまで直す（形式ゲートが赤なら正準フォーマットへ。allowlist に新規 ID を足さない）。
