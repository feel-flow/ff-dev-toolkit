# 観測台帳の記録規則（`/retrospective` 本線「観測の記録」の詳細）

本線は照合フェンス・記録手順・書き込み口の呼び出しだけを持つ。Count の数え方に迷う回・base が先行して止まった回・昇格の判定に入る回・「時間損失の単発提案」の発火条件に当たる回に読む。本線の記録手順 0 で台帳をテンプレートから作成した回は、作成した事実を振り返りの報告に書く。

## 記録の前に base の先行を照合する

本線「記録の前に base の先行を照合する」が指す照合フェンス。記録手順 0 より前に通す。

**先に反映のモードを確かめる**（ADR-083）: フェンスの前に `FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/finish.sh" knowledge-commit target` を実行する。非 0 なら台帳へ書かず、観測を報告に残す。出力が `KNOWLEDGE_DELIVERY=per-merge` なら下のフェンスを通す。`KNOWLEDGE_DELIVERY=batch` なら target が書き込みの起点（最新の base + 未反映の知見）へ移り、`origin/<staging>` の先行も照合済みなので、下のフェンスは通さない。同じセッションで `/ace-curate` が移った後なら、target は移らずに照合だけを行う。batch で先行されて止まったときは、下の「取り込んでから記録を作り直す」の 1. を、表示されるやり直し手順（変更したパスを名指しした退避・戻し・discard・戻り先・target）の印字どおりの実行と読み替える。2.〜4. はそのまま当てはめ、OBS ID は staging を取り込んだ後のツリーの最大連番 +1 で採番する。

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

## 照合の根拠（記録の前に base の先行を見る理由）

台帳は**デフォルト統合ブランチの共有文書**で、`/retrospective` は知見単独コミットを直 push または知見 PR で届ける。並行セッションが先に更新していると、同一性判定・`Count` +1・OBS ID 採番がいずれも古い台帳から決まる。push の non-fast-forward は**最終境界であって検出点ではない**（弾かれた時点で記録内容は作られており、`Count` が二重に増えうる）。台帳から決まる値は `/ace-curate` の「共有値の確定前ガード」と同じく base の先行を見てから決める。fetch 失敗の停止メッセージには git が出した原因を付ける（remote URL の資格情報部だけ `***` へ伏せる）。

> **`/ace-curate` との述語差（意図的）**: clean tree の検査を**台帳のパスへ絞っている**。台帳の書き込みは 1 ファイルの単独コミットで commit を pathspec へ固定しているため、作業ツリー全体の clean を要求すると、作業中に単独実行した振り返りが先行の無い状態でも記録できなくなる。base の先行を見る向きは `/ace-curate` と同一。

**先行していたときの復帰は「取り込んでから記録を作り直す」**（「既存の観測へ `Count` を足す」はその結果であって別の分岐ではない）:

1. `git pull --ff-only origin <default-branch>` で取り込む（detachedでもremote/branchを明示）。ff できない（diverge している）なら押し切らず停止し、記録できなかった事実を振り返り結果で報告する。`--force` / `--force-with-lease` で先行セッションを上書きしない。`--rebase` / merge で取り込まない — ff-only だけが「取り込んだ後の台帳 = origin の状態」を担保し、作りかけの記録内容がローカルに生き残るのを防ぐ
2. 記録手順 0 からやり直す — 取り込んだ台帳に対して同一性判定を引き直す。並行セッションが同じ主張を既に記録していれば `Count` +1 へ、無ければ新規追記へ落ちる。同じ主張へ新規エントリを起こさず、既に +1 された `Count` へ重ねて +1 もしない
3. 新規追記になる場合、OBS ID は取り込んだ後の台帳の最大連番 +1 で採番する（着手時に決めた連番を持ち越さない）
4. 取り込んで作り直した事実を、記録内容と併せて振り返り結果で報告する

復帰できないまま停止した場合（ff できない・fetch できない・ref を解決できない・default branch を解決できない）は台帳へ書かず、観測を振り返り結果の報告に残す。「提案の閾値」は通常どおり適用する — 台帳はローカルに読めており累計は成立しているので、「台帳へ書き込めないリポジトリ」の閾値の免除は受けない。

#### Count の単位

`Count` は**計上する観測メモ行の累計**である（初回の記録 = 1。累計 3 回 = 計上メモ 3 行目）。昇格閾値の入力そのものなので、行数と事象の多重度を混ぜない。

- **1 行 = 1 回**: 1 行へ「前景で 2 回」のように複数回を畳んでも、その行は 1 回として数える。多重度は行の叙述であり、乗数ではない
- **同一セッション・同一エントリは 1 回**: 1 回の振り返り実行で、同じエントリへ計上する観測は最大 1 行（Count +1）。同じ原因がセッション内で繰り返した場合は 1 行に畳む。この上限は当該振り返りが実測した観測にだけ掛かり、旧経路の Issue 取り込み（[legacy-intake.md](legacy-intake.md)）と、Count を動かさない注記（対策が効いた実測・昇格記録）には掛けない
- **既存エントリは遡及しない**: 過去の `Count` を、行内の「N 回」叙述から足し直したり、同一セッションの反復を遡って減らしたりしない。過去の値は当時の昇格判断の入力であり、後から単位を変えると既に起票した Issue の根拠が動く

同一性は「読者が取る実行可能なアクションが同一か」で判定する（ACE の新規性バーと同じ基準。文言や事例が違っても導かれる行動が同じなら同一エントリ）。**Jev への切替（`FF_JEV_MODE`・既定 off・ADR-059）**: `FF_JEV_MODE=on` のときだけ、本線の triage で分類していない候補エントリに限り `scripts/jev/jev-decide.sh retro`（質問は `/ace-curate` の新規性判定と同じ `questions/same-action.json`）を先に呼んでよい。**exit 0 のときだけ**判定を採り（p ≥ 0.5 なら既存へ +1、全候補が p < 0.5 なら新規）、exit 10 / 11 / 12 は自分で判定する（二重走行しない）。exit 2 / 64 / 69 は黙って落とさず止めて直す。正本は `${FF_DEV_TOOLKIT_ROOT}/scripts/jev/README.md` §切替。

`Status` が `archived` のエントリが再発したら `active` へ戻す。**統合元は戻さない** — `Issue` 列が台帳自身の anchor（`doc:<台帳のパス>#obs-nnn`）を指す `archived` は `/observation-refine` が別エントリへ統合したもので、同じ主張の再発は統合先のエントリへ計上する（統合元の `Count` は統合前の履歴で、統合先へ合算済み。統合先の `Count` が自分の計上メモ行より多いのはこの合算の分で、遡って数え直さない）。`mitigated` のエントリは [promotion.md](promotion.md) の元 Issue がある再発分岐／元 Issue がない見送り分の復帰条件で扱う。Keep の振り分け: ツールキットのスキル/テンプレ/hook、またはそのリポジトリの手順・テンプレへ定着させる価値のある成功パターンだけを `Kind: keep` で記録する。重い検証を省けた・軽い代替手段で同等の確度を得られた成功（未変更領域の再検証省略など）も、定着価値のある Keep として拾う。プロジェクト固有のコード・設計知見は台帳に書かず ACE 側へ回す。Problem は「X すると Y の手戻りが起きる → Z せよ」という知見の形で書く。機微情報は台帳エントリ・観測メモ・昇格 Issue 本文へも引用しない。

## triage

台帳を grep し、同じ主張のエントリを探す。`FF_JEV_MODE=on` のときだけ下の triage 入口を先に呼ぶ。`off` はこの節が存在しないのと同じで、呼び出さず従来経路の出力をバイト同一に保つ。exit 0 の分類は人が最終判断する。`reduces_to` の P / ACE ID は OBS ID ではなく、原則への帰着だけで OBS の存在・同一性を確定しない。core 文書の原則なら新 OBS を作らず証跡へ記録する。それ以外は上の同一性基準で台帳を照合し、同じ主張の OBS があれば Count +1、無ければ記録基準を満たす実測だけを原則参照付きの新 OBS として残す。`new_invariant` も同一性判断と記録へ進み、`one_off_measurement` は evidence 文書、`noise` は理由 1 行で破棄する。exit 10 / 11 / 12 は `top_k` と `measurement_hint` を参考に従来の判断へ戻る。triage 済み候補を `retro` へ再送しない。覆した判断は `decision_ids` の該当 ID を `triage-candidate.sh --overturn <id> --note <理由>` で記録する。原則の読み方・終了コードは [Jev README](../../../scripts/jev/README.md#知識候補の選別triage) が正本。

triage 入口（`CANDIDATE` は観測候補 1 件の本文）:

<!-- ff-triage-entry:start -->
```bash
if [ "${FF_JEV_MODE:-off}" = on ]; then
  triage_rc=0
  bash "${FF_DEV_TOOLKIT_ROOT}/scripts/jev/triage-candidate.sh" --candidate "$CANDIDATE" || triage_rc=$?
  case "$triage_rc" in 0|10|11|12) ;; *) exit "$triage_rc" ;; esac
fi
```
<!-- ff-triage-entry:end -->

## 保留の合流と送信経路

MCP raw を使う回は add / commit / probe / push / pr の各 `knowledge-commit` に同じ `--github-input /absolute/index.json` を明示する。subject Issue / protection / pushed-SHA CI は任意不足なら fallback / unknown / unavailable を維持する。PR は PLAN の head/base/title/body と push 済み SHA を既存 create_pull_request に渡し、fresh raw が一致するまで rc2、未作成を完了としない。

モード判定直後に `knowledge-commit status` を読み、保留がある場合は、現在のブランチ名を取得し、取得成功時の空名は `(detached)` として `KNOWLEDGE_PENDING_BRANCH` と照合する。不一致や取得失敗は停止し、**保留を作った同じブランチを維持し、default / detached へ切り替えない**。既存の `chore/ace-from-*` / `chore/retro-from-*` は知見ブランチとして扱う。他の非 default ブランチで保留があれば、切り替えず保留の復帰手順で解決する。保留が無い非 default は、記録前に default へ戻るか [worktree セッションの準備](../../ace-curate/references/curate.md#worktreeセッションからの知見記録)を通す。他 worktree の default を切り替えない。

- 観測を書く回は、同じブランチで照合フェンスを通し、OBS を `add` してから共通の `commit` で ACE と畳む。既存知見ブランチの保留を先に commit して別コミットに分けない。
- 出典 PR を確定している回の `add` / `commit` には、その番号を `--pr <PR番号>` で渡す。PR の代わりに対応する Issue が確定している回は `--issue <Issue番号>` を渡す。入力済みの出典と ACE の保留が同じ作業を指すことを確認してから合流する。
- **観測 0 件・off モード・ask 拒否でも、保留を同じブランチで commit し、同じ送信分岐を使う**。保留も観測も無ければ送信しない。
- **まとめるモードの書き込み中**（target の記録がある。`knowledge-commit status` が `KNOWLEDGE_DELIVERY=batch` を出す）は detached のまま `knowledge-commit push` を使う。push は staging へ送って元の場所へ戻り、base は進めない。`pr` は使わない。**保留も観測も無い回も push を呼ぶ**（何も送らずに元の場所へ戻り、記録を消す。`KNOWLEDGE_PUSH=nothing`）。呼ばないと起点の detached HEAD と記録が残る。
- **default / detached は `knowledge-commit push`**。保護による rc 3 は `/ace-curate` 手順 5 の PR 経路へ進む。detached からは commit を保った知見ブランチを作って `pr` を呼ぶ。他の非 0 は停止して原因を解決する。
- **既存知見ブランチは push を試さず `knowledge-commit pr`**。`knowledge_branch="$(git branch --show-current)"` の成功と `chore/ace-from-*` / `chore/retro-from-*` への一致を確認し、その実測名を `--branch "${knowledge_branch}"` に渡す。title は共通 commit の件名を `git log -1 --format=%s` で実測する（`commit` が返した `KNOWLEDGE_SUBJECT` でもよい）。placeholder を渡さず、body は同一セッションの知見記録であることを示す。既に PR があれば重複作成せず、その到達状態を確認する。
- **既存知見ブランチからの pr は local default と他 worktree を変更しない**。helper の default 復帰は default から知見ブランチを作った回だけ。送信範囲ガード・PR のレビューとマージは省略せず、実際の経路と到達状態を報告する。

## 書き込み（定型コミット）の根拠

- 台帳の書き込みは `knowledge:` prefix の単独コミット（`/ace-curate` の Playbook 直コミットと同格の定型書き込み。承認は不要だが、記録した内容は振り返り結果で必ず報告する）。commit は書き込み口（`finish.sh knowledge-commit commit`）が、記録したパスへ固定した `git commit -- <path>…` で行う（`git add` + pathspec 無しの `git commit` にしない — 索引に載った無関係な変更が単独コミットへ紛れ込んで直 push されるのを、この形だけが防ぐ）。素の `git commit` を自分で打たない — 合成 identity の停止もこの書き込み口の中にあり、素の commit にはどのホストでも掛からない。唯一の例外は下の hook 拒否後の手コミットで、それも記録したパスへ固定した `git commit -m "<件名>" -- <パス>` の形に限る
- 書き込み口は件名を組み立てた直後、stage・保留記録・commit より前にリポジトリの prepare-commit-msg → commit-msg hook へ件名をドライランで通す。元の件名が通れば変更せず、拒否された既定 `knowledge` は `chore` → `docs` も同じ hook で検証する。Issue が必要なら、明示の `--issue` を優先する。指定が無ければブランチの `ace-from-pr-N` の PR（失敗時は別の PR を見ない）、そうでなければ明示の `--pr`、どちらも無く default branch または detached HEAD で `--github-input` が無いときだけ、updatedAt が新しいマージ済みから mergedAt が最大の PR、その後にブランチ自身の `#N` を解決する（出典の PR を照会した回は、照会できて番号が無いときだけ `#N` へ進む。照会の失敗は `KNOWLEDGE_COMMIT=subject-query-failed` の rc 2 で止まる）。PR の番号は closing Issue 先頭 → 本文の `Ref` / `Refs #N` → タイトルの最初の `#N`。候補は type を内側に、裸の参照、末尾の `(#issue)`、末尾の `(Refs #issue)` の順で、裸を受理する hook は括弧付きへ進まない。件名が 100 字（commitlint と同じ数え方）を超えるときだけ選んだ形を保って短縮する（1 件は ID だけにして要約を本文の `- <ID> <要約>` 行へ移す）。選んだ Issue/type は保留へ保存して合流 commit が引き継ぐ（claim が無い OBS 単独経路も同じ。version claim・ID・要約の数字は PR の根拠にしない。詳細は `/ace-curate` の references/curate.md「コミットメッセージ規約」）。rc 2（`KNOWLEDGE_COMMIT=subject-query-failed`）で止まったら、通信・認証を直して再実行するか `--issue` で出典の Issue を明示する（`add` は保留を作らず、`commit` は保留を残す）。`add` / `commit` が rc 4（`KNOWLEDGE_COMMIT=hook-rejected`）で止まったら、解決元が無いか候補を hook が拒否している — `add` の拒否は保留を作らない（`--claim` 経由では文書と claim の stage は残る）ので `discard` は要らない。解決に失敗した場合だけ、表示された規約を確認して `--type` で再実行するか、`git config user.name` / `user.email` が合成 identity でないことを確かめてから `git commit -m "<規約どおりの件名>" -- docs/08-knowledge/OBSERVATIONS.md` で手でコミットする（既定ブランチ上の commit ガードに止められるので、区間先頭へ `FF_DEFAULT_BRANCH_COMMIT_ACK=1` を付ける。扱いの正本は `/ace-curate` の references/curate.md「コミットメッセージ規約」）
- `commit` が記録した Markdown の markdownlint 違反（exit 1）で止まった回は、名指されたファイル（台帳とは限らない。合流した ACE の記録も同じ commit で検査される）を直し、そのファイルを記録した `add` をやり直してから `commit` を再実行する。未検査（exit 2）で止まった回は、stderr の復帰手段を済ませて `commit` だけを再実行する（規則は `/ace-curate` の [コミット（手順 5）の規則](../../ace-curate/references/curate.md#コミット手順-5の規則)の「記録した Markdown の lint」）
- push が non-fast-forward で拒否されたら、上の復帰手順へ戻る — `git pull --ff-only` で取り込み、記録手順 0 から記録内容を作り直す。OBS ID の採番し直しだけで push を再試行しない（照合から push までの間に同じ主張が別セッションで記録されていれば、同一性判定を引き直さない限り重複エントリが残る）
- **ローカルに未 push のコミットがある回は、それらも同じ push で統合ブランチへ送られる**。台帳のコミットを単独に保つのは commit の pathspec だけで、push の粒度はブランチである。デフォルト統合ブランチ上に意図しないローカルコミットが無いことを記録の前に確かめる
- 導入先から SSOT や配布元へ観測を Issue で受け渡す経路（`[observation]` 接頭辞の受け渡し便）は**廃止**した。観測は作業中リポジトリの台帳で閉じ、他リポジトリへ渡すのは閾値到達後の起票だけにする。旧版が残した `[observation]` Issue は、SSOT で実行するときだけ [legacy-intake.md](legacy-intake.md) に従って取り込む
- 台帳の Markdown 本文へ script で文字列パッチを当てる場合は [Markdown 文字列パッチ規律](../../../docs-template/05-operations/deployment/markdown-patch-discipline.md)に従う

## 昇格閾値と特急レーン（根拠）

- 昇格閾値の判定対象は `Status` が `active` のエントリに限る（閾値だけで昇格を再提案しない。元 Issue がある `promoted` / `mitigated` の再発は [promotion.md](promotion.md) の追跡分岐で扱う）
- 起票先の分岐・発行済み Issue の対策完了と旧台帳の移行・`promoted` / `mitigated` の再発・見送りの書き戻しは [promotion.md](promotion.md)。`Kind: keep` の閾値到達は Issue ではなく**定着提案**（スキル・テンプレへの文言追加・手順化）として出す
- 特急レーン（データ破壊・広範な作業停止・セキュリティ）は閾値を待たずに起票を提案してよい。その場合も台帳へ記録し、提案に特急である理由を明示する。起票の実行は通常の昇格と同じく [filing.md](filing.md)「承認と起票」「外部公開の承認境界」に従う（重大さの判断は理由の明示で利用者に見せる）
- 台帳の掃除: 閾値未達のエントリの見直し（既存 Issue への紐付け・同じ主張の統合・stale の archive・Keep の定着判定）は [`/observation-refine`](../../observation-refine/SKILL.md) が dry-run → 承認 → 適用で行う。stale の基準（既定は `Last` から 180 日を超えて `Count` が 1 以下）の正本も同スキルで、振り返りの中では基準に当たるエントリを個別に `archived` へ変えない
- **閾値は発火点であり、発火時に取った判断は状態として台帳へ書き戻す。** 放置すると次の到達で同じ判断を一から再演する。昇格を見送った判断は `mitigated` として書き戻す（ACE Playbook の件数上限を統合・抽象化へ回す ADR-047 と同じ原則で、閾値を緩めることでは代替できない）

## 時間損失の単発提案

1 回のセッションで大きな時間を失っても、初回の観測は `Count` 1 で台帳に積まれるだけで、累計 3 回に達するまで改善に結びつかない。本節は、その 1 回の損失を、防げた地点への改善提案へつなぐ。本線「提案の閾値」の「閾値未達の観測は出さない」の例外は本節の単発提案だけで、提案の上限（最大 3 件）・「実測に限る」・既存確認・承認の扱いは本線と [filing.md](filing.md) のまま変えない。

### 発火条件

次のどれかに当たったら、下の「内訳」と「単発の提案」を行う。どれにも当たらなければ本節の手順は行わない（推測で発火させない）。

- このセッションで実行したレビューの巡が 3 以上
- このセッションで実行した全体ゲートが 3 以上
- 利用者がこのセッションで作業の遅さ・無駄を問うた（「なぜ時間がかかっているのか」「無駄が多い」など）

回数はこのセッションのログ・ゲートの記録・レビュー証跡で、Issue をまたいで数える。`finish.sh precheck` の `EFFORT_<Issue番号>_review_rounds` / `EFFORT_<Issue番号>_gate_runs` は Issue 単位の累計（前のセッションの分を含み、他の Issue の分を含まない）なので、発火の判定に使わない。

### 内訳

発火したら、失った時間を原因ごとに分け、振り返りの結果に 1 原因 1 行で載せる。提案を出さない回も内訳は載せる。

- 各行は原因・回数・実測の分（ゲートの所要・レビューの巡の所要・失敗した起動の往復）を書く。分はログ・ゲートの記録から取り、取れない行は「分は未計測」と書く。推測で分を埋めない
- 1 つの原因から派生した手戻り（直した結果の次の巡・次のゲート）は、その原因の行にまとめる
- 内訳は振り返りの報告に載せるもので、台帳へは各原因を通常の記録手順で記録する（内訳そのものを台帳へ写さない）

### 単発の提案

内訳で最も時間を失った原因が、作業の手前で防げたもの、または重い工程の前提そのものを見直せるものなら、`Count` を待たずに改善を提案する。提案は最大 3 件の枠に含め、他の提案と効果の大きい順に並べる。

- **前提の問い直し（上位視点）**: レビュー巡・全体ゲート・フルスキャン等の重い工程で時間を失ったときは、局所パッチへ進む前に「本当に保証したい不変条件は何か、毎回・全件・同期である必要があるか」を上位視点から問い直し、[promotion.md](promotion.md)「提案の検討順（引き算・代替ファースト）」の順で代替手段を検討する。既存方針（ADR や運用手順）が時間損失の原因なら、[filing.md](filing.md)「起票前の既存確認」の方針矛盾分岐に従い、方針側の変更提案として明示して提示してよい
- **防げた地点**は次のどれかに限る: スキルの手順・点検項目（その作業の前に一度に確かめる一覧など）、ツールの出力（エラー時に通る起動形を示す、止める前に名指しするなど）、ゲート・hook の判定
- 提案の中身は、その地点への変更にする。「次は気をつける」「注意を促す文を足す」だけの提案は出さない
- 原因が作業の手前で防げない（外部サービスの障害・利用者の仕様変更など）ときは提案せず、内訳の行にその旨を書く
- 提案を出したら「時間損失の単発提案」と提案先を、見送ったら理由を、その回の観測メモの行の末尾に書き足す（行を増やさない。「1 行 = 1 回」を保つ）

### 既知の解があったのに失った時間

内訳の原因が、台帳の `promoted` / `mitigated` のエントリ（対策や通る手順が既に書かれているもの）の再発だったときは、[promotion.md](promotion.md) の再発分岐に加えて次を行う。

- 「同型対策は不採用・構造案なし」で閉じる前に、その解を**失敗が起きる地点へ組み込む案**を構造案として検討する（ツールが失敗したときに、台帳にある通る形を出力する・ゲートや hook が止める前に通る形を名指しするなど）。判定と案内を失敗する側へ移す案は、規定文言や参照経路を足す型ではないので、promotion.md の同型の禁止に当たらない。手順書・スキルへ通る形を書き足す案は同型に当たるので、本節を根拠に出さない
- 組み込む案があれば単発の提案として出す。無ければ観測メモに「解の組み込み先なし」と理由を 1 行書く
