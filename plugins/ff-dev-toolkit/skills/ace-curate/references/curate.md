# `/ace-curate` の詳細規則（Phase 2 の根拠・共有値の確定前ガード・索引の列順・Jev）

本線は判断点と実行部だけを持つ。次の条件に当たったときにここを読む: 独自配置の PLAYBOOK を扱う / 抽象度の下限で迷う / 新規性判定を Jev へ投げる（`FF_JEV_MODE=on`）/ 4-b で共有値を確定する / 索引の列順が雛形と違う PLAYBOOK に追記する / 同梱 TypeScript ゲートの runner を差し替える / コミット経路（保護判定・commitlint・non-fast-forward・chore PR）を確かめる。

## 配置先の解決（最初に実施）

既存 AGENTS.md / CLAUDE.md / docs 索引の ACE 配置記録と `ACE_PLAYBOOK_PATH` から、実在する PLAYBOOK を解決する。明示環境変数があればそれを優先し、なければ記録済み配置、記録がない場合だけ `docs/08-knowledge/PLAYBOOK.md` を使う。記録が矛盾する場合は変更前に報告する。repo 外・symlink で repo 外へ出る配置は編集しない。独自配置では前提確認・検索・採番・全ゲート引数・`add` のパス・frontmatter・version claim の document と claim パス・索引相対リンクをすべて解決した配置へ置換してから実行する。固定パスをそのまま実行して第二の Playbook を作らない。ゲート引数は明示した実配置を使い、環境変数を既定引数で上書きしない。

## curate 側のハードルール（`/ace-refine` との分担）

- エントリの追記は**末尾のみ**。既存エントリの本文（新形式の本文 / 旧形式の Insight/Context/Action）の書き換えは禁止
- **既存エントリの要約・アーカイブ・統合は `/ace-refine` のみが行う**（本スキルは grow 専用。refine 側は dry-run → ユーザー承認 → 原文アーカイブ保全付きで行う）
- 4-e の行数バジェット自己チェック（必須・ブロッキング）: 各エントリのブロック行数は 15 行以内（例外マーカー付きでも 30 行以内）を追記前に自分で数える。超えるなら本文を削ってから追記する
- 形式ゲートが赤なら、追記したエントリをコンパクト正準フォーマットへ書き直す。`legacy-format-allowlist.txt` に新規 ID を足して通すことはしない（allowlist は既存エントリの読み取り互換のためのものであり、新規追記の抜け道ではない）

## 同梱 TypeScript ゲートの runner（4-b-0 / 4-f）

同梱テンプレートを叩く経路で `npx --yes tsx` を直接書かない。root package に `tsx` binary が無い workspace 環境では `tsx: command not found` でゲートに到達できず、手作業照合へ戻る動きが実測で起きた。`ace-run-ts.sh` は候補を**実際に起動して**確かめながら次の順で解決する — `FF_ACE_TS_RUNNER`（明示指定。`pnpm --filter <pkg> exec tsx` のような複数語も可） → PATH の `tsx` → 上位ディレクトリを含む `node_modules/.bin/tsx` → `pnpm` / `yarn` の `exec` → `npx --yes tsx`。どれも起動できなければ exit 3 で停止する（黙って手作業へ戻さない）。

## 抽象度の下限（第 2 の関門・ADR-047）

同一性で落ちなかった候補には、**書く前に**抽象度の下限を当てる。判定は「**適用条件が固有名なしで書けるか**」。本文（タイトル・適用条件・アクション）の固有名（Issue/PR 番号・ファイルパス・特定コマンド/API/スクリプト名）を 1 つずつ「別の名前へ置き換えても主張とアクションが成立するか」で試し、成立するものは 1 段上の性質へ書き直す（固有名は**例示として**残してよい）。1 段上げた形で既存エントリと同一のアクションになるなら、そこで `Helpful` +1 へ落ちる — このバーが無いと、同じ性質の次の事象が「取るアクションが違う」と判定されて新規追加され続ける。

**上げすぎたら棄却する**: 新規性バーを逆向きに使い、上位主張から**元の候補と既存エントリそれぞれのアクションが再導出できるか**を確かめる。できないなら抽象化を棄却して元の粒度で書く。固有名がアクションの本体である類型（プラットフォーム実装差 / 特定 CLI の usage と実挙動の乖離 / 言語ランタイム仕様 / 診断メッセージと原因の対応表 / 既に 1 段上の主張）は抽象化しない。判定材料と類型の詳細は PLAYBOOK §運用ルール「抽象度の下限と棄却基準」。

**機械では止まらない**: 抽象度の下限は `/ace-curate` を exit 1 で止めるゲートではない（機械シグナル単独の精度は 47%）。候補の提示は `ace-abstraction-report.ts` が行い（候補が何件出ても exit 0）、判定はチェックリストで行う。

このバーが必要な理由: 件数を減らせるのは archive と統合の 2 つだが、**archive の供給は「作成から閾値日数の経過 かつ（git 参照が無い または 最終参照から閾値日数の経過）かつ `helpful === 0`」に限られる**のに対し、流入は curate のたびに発生する。出口の述語が狭い以上、入口で絞らなければブロック上限到達は時間の問題になる。

**新規性バー（件数の入口制御・ADR-033）**: 判定は「読者が取る実行可能なアクションが既存エントリと同一か」で行う。文言や事例が違っても導かれる行動が同じなら、それは新規知見ではなく既存エントリの再確認であり、`Helpful` +1 が正しい記録先である。**追記件数の上限は設けない**。domain では同じアクションでも主体・条件・例外・確認状態が異なれば同一知識としない（確認状態の違いを Helpful 加算で消さない）。

**一回性のインシデント叙述**: 特定障害のタイムライン・復旧ログ・環境固有の調査記録は再現性ゲート「低→スキップ」の適用対象であり、Playbook ではなく `docs/08-knowledge/TROUBLESHOOTING.md` や runbook へ記録する。Playbook に残すのは「次に同型の状況で使える主張」だけ。

## Jev への切替（`FF_JEV_MODE`・既定 off・ADR-059）

新規性バーの判定は `FF_JEV_MODE=on` のときだけ Jev（TypeSafe AI の System One Model）へ先に投げてよい。候補ごとに、照合で読み込むカテゴリ（候補カテゴリ + 似たタイトルが見つかったカテゴリ）の中から、候補と語の重なり（Jaccard 類似度。offline 評価の生成器 `build-ace-eval-sets.ts` の近傍選択と同じ）が大きい順に最大 5 件を近傍エントリとして選び、1 件ずつ state（`id` / `category` / `title` / `body`。日本語のまま）にして次を呼ぶ:

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

fetch が失敗した回は、停止メッセージの末尾へ git が出した原因をそのまま付ける（git の stderr は remote URL を含みうるので、表示の前に `https://user:token@host/` 形の資格情報部だけを `***` へ伏せる）。remote が先行していた場合は**追記前に** `git pull --ff-only`（直 push フロー）または `git rebase origin/<default-branch>`（専用ブランチ）で取り込む。fresh read は同時 read を防がない。直 push の最終境界は手順 5 の non-fast-forward である。

`.version-claims` contract があるリポジトリでは、**直 push / PR のどちらでも** PLAYBOOK.md と同じ commit で `.version-claims/docs/08-knowledge/PLAYBOOK.md.claim` を `document` / `version` / `change` の3行だけへ更新する（手順 5 の `finish.sh knowledge-commit add --claim docs/08-knowledge/PLAYBOOK.md` が `scripts/update-version-claim.sh` で最新 base/current の blob ID から生成し、`scripts/check-version-claims.sh` で検証してから記録パスへ足す）。version 不変のカウンター更新でも `change` は更新するため、直 push と進行中 PR の交差も claim conflict で止まる。祖先検査後に同じ文書の別更新が先行しても、claim の content conflict で停止させ、最新 base から version / `ace_entry_count` / Changelog / claim を再生成する（claim の片寄せ・削除で競合を解消しない）。

## 索引テーブルの列順（4-b）

**列順は雛形からではなく、その PLAYBOOK の索引テーブルのヘッダ行から決める。** 導入先ごとにヘッダの列順が違うため、固定の列順を写すと索引だけが本文と列の意味が食い違う行になる。手順:

1. `## エントリ一覧` 直下の表の**ヘッダ行**を読む（`|` で始まる最初の行。直後が `| --- | ... |` の区切り行）
2. ヘッダの各セルを 4 つの役割へ対応付ける — **ID**: `エントリID` / `ID` / `ACE ID`、**タイトル**: `タイトル` / `Title`、**カテゴリ**: `Category` / `カテゴリ`、**参照先**: `参照先` / `Link` / `リンク`
3. 4 つの値を**ヘッダの出現順どおりに**並べて 1 行を書く。値は ID = `ACE-XXX`、タイトル = 見出しのタイトル、カテゴリ = エントリ本文の `| Category |` 行と**同じ値**、参照先 = `[playbook/<category>.md#ace-xxx](./playbook/<category>.md#ace-xxx)`。対応する列がヘッダに無い役割は値を書かない（列数はヘッダに合わせる）
4. 書いた行のセル数がヘッダのセル数と一致することを確認する。セル内の `|` は `\|` へエスケープする（**インラインコードスパンの中でも要る** — ``` `cmd | head` ``` は列を 1 つ増やす）

ヘッダが `| エントリID | タイトル | Category | 参照先 |` なら `| ACE-XXX | [タイトル] | [カテゴリ] | [playbook/<category>.md#ace-xxx](./playbook/<category>.md#ace-xxx) |`、`| ID | Category | Title | Link |` なら `| ACE-XXX | [カテゴリ] | [タイトル] | [playbook/<category>.md#ace-xxx](./playbook/<category>.md#ace-xxx) |`。どの役割にも対応付かない列は既存行の同じ列の形に合わせる。`check-category-size` は索引行のカテゴリ列を本文と突き合わせて食い違い・列数不一致を警告する。

## 旧形式との互換

- ヘッダ行・区切り行を持たないメタ 4 行は GitHub 上ではテーブルとして描画されない（AI ファースト文書として意図した仕様。詳細は PLAYBOOK.md §エントリテンプレート）
- 旧テーブル形式（`| フィールド | 値 |` + Insight/Context/Action）のエントリは**読み取り互換として共存**させる。重複時の `Helpful` +1 は、旧形式なら `| Helpful | n |` 行、新形式なら `| Helpful | n | Harmful | m |` 行の n を +1 する
- 既存の ID なしエントリ（`## [Pattern] ...` 形式等）や旧連番エントリ（3 桁・4 桁以上とも）は改名・書き換えしない（エントリID規則「既存 ID の扱い」）。採番ルールの SSOT は PLAYBOOK.md §エントリID規則
- 機械同期する場合はプロジェクトの `ace:bump-playbook-frontmatter`（`--write --bump-version`。**minor +1**）。count のみ直すなら `ace:sync-playbook-frontmatter`。`--write` は変更済みなのに `changeImpact` が欠落している場合 `medium` を自動追記する（`/validate-docs` が「変更済みなのに未記録」を赤にするため放置しない）

## コミット（手順 5）の規則

マージ方針の SSOT は [git-workflow.md ステップ10 §運用パターン（マージ方針）](../../../docs-template/05-operations/deployment/git-workflow.md#ace-merge-policy)（`docs-template/` 全体を導入している場合の参照。無ければ以下の既定に従う）。

**保護判定（必須・直 push を試す前に行う）**: `finish.sh knowledge-commit probe` が classic branch protection API（`gh api "repos/${owner_repo}/branches/${default_branch}/protection"`。404 は「classic ルールが無い」を意味するだけで、Rulesets のみで保護されたブランチでも 404 を返す）と rulesets API（`gh api "repos/${owner_repo}/rules/branches/${default_branch}"`。直 push を PR 必須にする `pull_request` type の有無だけを見る — `non_fast_forward` 等 direct push を禁止しない type だけなら unprotected）の両方を見て `protection=protected|unprotected|unknown` を出す。`protected` → PR 経由へ / `unprotected` → 既定（直 push） / `unknown`（`gh` 不在・401/403・ネットワーク失敗。保護判定後に設定が変わる TOCTOU の受け皿でもある） → 既定を試し、push が `Changes must be made through a pull request` または `push declined due to repository rule violations` で拒否されたら PR 経由へ切り替える（`finish.sh knowledge-commit push` が同じ文言を検知して rc 3 を返す）。

**既定（推奨）— デフォルトブランチ直マージ**: 保護されていない default branch にのみ適用。`<default-branch>` に直接 commit + push する。

**コミットメッセージ規約**: コミット前に対象リポジトリの規約を確認する。確認対象は (1) commitlint の `header-max-length` — 件名を上限内に収め、カテゴリが複数でも件名には列挙せず、commit body に記録する。要約だけで上限を超える場合は要約を短くするかコミットを分割する — に加え、(2) **type の許容リスト**。参照先: `commitlint.config.*` / `.commitlintrc*` / `package.json` の `commitlint` キー / husky・simple-git-hooks の `commit-msg` hook。`knowledge` が許容 type に含まれない場合は、プロジェクト規約の type（例 `chore`）へ件名の prefix だけを置き換える（件名の要約・body の `Categories:` 記録はそのまま維持する。例: `chore: ACE-<PR番号>-<連番> <要約>`）。

**文字列パッチと commit の突き合わせ（必須）**: PLAYBOOK・文書への追記を script で当てる場合は [Markdown 文字列パッチ規律](../../../docs-template/05-operations/deployment/markdown-patch-discipline.md)に従い、`add` の前に `git status --short` で意図したファイルのみが変わっていることを述語で突き合わせる。書き込み口は `add` 時の blob hash を記録し、その後に同じファイルへ入った別の編集を commit へ吸い込まない。

**送信範囲ガード**（`finish.sh knowledge-commit push` と `pr` の両方が、ブランチ作成・push より前に行う）: fetch 後の `origin/<default-branch>..HEAD` が knowledge コミット 1 つだけでなければ rc 2（`KNOWLEDGE_PUSH=scope-mismatch` / `KNOWLEDGE_PR=scope-mismatch`）で止め、無関係な未 push コミットを一緒に送らない。

**直 push の実測ガード**（`finish.sh knowledge-commit push` が行う）: コミット先ブランチを `git symbolic-ref -q --short HEAD` で実測し、detached HEAD なら refspec を `HEAD:<default-branch>` にする（merge-cleanup の退避などで detached のまま `git push origin <branch>` を打つと、ローカル branch ref が送られ「Everything up-to-date」で成功に見えたまま届かない）。push 出力はファイルへ落として `-> <default-branch>` を照合する（パイプで tee へ流すと終了コードが失われ、rejected 出力を成功と誤読する）。push 後は `gh run list --branch <default-branch> --limit 5 --json status,conclusion,workflowName,headSha` で今 push した SHA の run を見る（直 push は PR 画面に出ないため）。`in_progress` / `queued` は完了を待って再確認し、`failure` なら revert ではなく ACE コミットを前進で直して push し直す。一覧が空の CI 無しリポジトリはそのまま進んでよい。

**non-fast-forward で拒否された場合**（保護ルールによる拒否は rc 3 で PR 経由へ自動的に切り替わるため対象外）は、別セッションの更新を検出した正常な競合経路として次を**最大 3 回**繰り返す:

1. 同じ明示 refspec で `origin/<default-branch>` を再取得する（失敗時は停止）
2. remote の版ブロック・エントリ・索引を保全して rebase し、自分のエントリを残す。同じ版番号へ内容を混ぜず、自分の版を remote 最新の次へ繰り上げる
3. `ace_entry_count` を merged tree の live 実数から再同期し、version / Changelog を再生成する
4. **各再試行で** `add --claim docs/08-knowledge/PLAYBOOK.md` からやり直す（claim を最新 base から再生成し、3行完全一致検証を通してから stage する）
5. 手順 4-f の全ゲートを再実行し、commit を amend して `push` を再試行する

3 回で収束しなければ「共有版境界が高頻度更新中」と報告して直列化を求める。`--force` / `--force-with-lease` で先行セッションを上書きしない。

**任意エスカレーション — chore PR**: 大人数チーム / 知見レビューを残したい場合のみ、というのが既定の位置づけだが、**default branch が保護されている場合はこの経路が必須**になる。手順1で固定した `ACE_BRANCH` で小さい PR を作成する（コミット type は上の許容リスト確認に従う）:

```bash
git checkout -b "$ACE_BRANCH"
commit_type="knowledge"
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/finish.sh" knowledge-commit add --claim docs/08-knowledge/PLAYBOOK.md --source ace --id "${ACE_ID}" --summary "${ACE_SUMMARY}" --category "<category[, category...]>" --type "${commit_type}" -- docs/08-knowledge/PLAYBOOK.md docs/08-knowledge/playbook/*.md || exit 1
# PR 経由は別ブランチへの commit なので /retrospective へ合流させず、ここで commit する
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/finish.sh" knowledge-commit commit --type "${commit_type}" || exit 1
# push -u → upstream の照合（origin/${ACE_BRANCH}）→ gh pr create --base <default-branch> → ローカル default branch を origin へ戻す
FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/finish.sh" knowledge-commit pr --branch "$ACE_BRANCH" --title "${commit_type}: ${ACE_ID} ${ACE_SUMMARY}" --body "${ACE_ORIGIN} から知見抽出" || exit 1
# レビュー後 squash merge → /merge-cleanup
```

> `knowledge:` 付き PLAYBOOK 単独コミットの `<default-branch>` 直 push は意図的フローであり、通常のコード変更に対する「統合ブランチへの直 push 禁止」ルールとは別物として扱う。ただし default branch が保護されているリポジトリではこの経路に到達できない — その場合は保護判定に従い「PR 経由」（必須）を使う。
