# 観測台帳の記録規則（`/retrospective` 本線「観測の記録」の詳細）

本線は照合フェンス・記録手順・書き込み口の呼び出しだけを持つ。Count の数え方に迷う回・base が先行して止まった回・昇格の判定に入る回に読む。

## 記録の前に base の先行を照合する

本線「記録の前に base の先行を照合する」が指す照合フェンス。記録手順 0 より前に通す。

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

台帳は**デフォルト統合ブランチの共有文書**で、`/retrospective` はそこへ直接 commit + push する。並行セッションが先に更新していると、同一性判定・`Count` +1・OBS ID 採番がいずれも古い台帳から決まる。push の non-fast-forward は**最終境界であって検出点ではない**（弾かれた時点で記録内容は作られており、`Count` が二重に増えうる）。台帳から決まる値は `/ace-curate` の「共有値の確定前ガード」と同じく base の先行を見てから決める。fetch 失敗の停止メッセージには git が出した原因を付ける（remote URL の資格情報部だけ `***` へ伏せる）。

> **`/ace-curate` との述語差（意図的）**: clean tree の検査を**台帳のパスへ絞っている**。台帳の書き込みは 1 ファイルの単独コミットで commit を pathspec へ固定しているため、作業ツリー全体の clean を要求すると、作業中に単独実行した振り返りが先行の無い状態でも記録できなくなる。base の先行を見る向きは `/ace-curate` と同一。

**先行していたときの復帰は「取り込んでから記録を作り直す」**（「既存の観測へ `Count` を足す」はその結果であって別の分岐ではない）:

1. `git pull --ff-only` で取り込む。ff できない（diverge している）なら押し切らず停止し、記録できなかった事実を振り返り結果で報告する。`--force` / `--force-with-lease` で先行セッションを上書きしない。`--rebase` / merge で取り込まない — ff-only だけが「取り込んだ後の台帳 = origin の状態」を担保し、作りかけの記録内容がローカルに生き残るのを防ぐ
2. 記録手順 0 からやり直す — 取り込んだ台帳に対して同一性判定を引き直す。並行セッションが同じ主張を既に記録していれば `Count` +1 へ、無ければ新規追記へ落ちる。同じ主張へ新規エントリを起こさず、既に +1 された `Count` へ重ねて +1 もしない
3. 新規追記になる場合、OBS ID は取り込んだ後の台帳の最大連番 +1 で採番する（着手時に決めた連番を持ち越さない）
4. 取り込んで作り直した事実を、記録内容と併せて振り返り結果で報告する

復帰できないまま停止した場合（ff できない・fetch できない・ref を解決できない・default branch を解決できない）は台帳へ書かず、観測を振り返り結果の報告に残す。「提案の閾値」は通常どおり適用する — 台帳はローカルに読めており累計は成立しているので、「台帳へ書き込めないリポジトリ」の閾値の免除は受けない。

#### Count の単位

`Count` は**計上する観測メモ行の累計**である（初回の記録 = 1。累計 3 回 = 計上メモ 3 行目）。昇格閾値の入力そのものなので、行数と事象の多重度を混ぜない。

- **1 行 = 1 回**: 1 行へ「前景で 2 回」のように複数回を畳んでも、その行は 1 回として数える。多重度は行の叙述であり、乗数ではない
- **同一セッション・同一エントリは 1 回**: 1 回の振り返り実行で、同じエントリへ計上する観測は最大 1 行（Count +1）。同じ原因がセッション内で繰り返した場合は 1 行に畳む。この上限は当該振り返りが実測した観測にだけ掛かり、旧経路の Issue 取り込み（[legacy-intake.md](legacy-intake.md)）と、Count を動かさない注記（対策が効いた実測・昇格記録）には掛けない
- **既存エントリは遡及しない**: 過去の `Count` を、行内の「N 回」叙述から足し直したり、同一セッションの反復を遡って減らしたりしない。過去の値は当時の昇格判断の入力であり、後から単位を変えると既に起票した Issue の根拠が動く

同一性は「読者が取る実行可能なアクションが同一か」で判定する（ACE の新規性バーと同じ基準。文言や事例が違っても導かれる行動が同じなら同一エントリ）。**Jev への切替（`FF_JEV_MODE`・既定 off・ADR-059）**: `FF_JEV_MODE=on` のときだけ、候補エントリごとに `scripts/jev/jev-decide.sh retro`（質問は `/ace-curate` の新規性判定と同じ `questions/same-action.json`）を先に呼んでよい。**exit 0 のときだけ**判定を採り（p ≥ 0.5 なら既存へ +1、全候補が p < 0.5 なら新規）、exit 10 / 11 / 12 は自分で判定する（二重走行しない）。exit 2 / 64 / 69 は黙って落とさず止めて直す。正本は `${FF_DEV_TOOLKIT_ROOT}/scripts/jev/README.md` §切替。

`Status` が `archived` のエントリが再発したら `active` へ戻す。`mitigated` のエントリは再発だけでは戻さず、[promotion.md](promotion.md) の「`active` への復帰条件」に当たるときだけ戻す。Keep の振り分け: ツールキットのスキル/テンプレ/hook、またはそのリポジトリの手順・テンプレへ定着させる価値のある成功パターンだけを `Kind: keep` で記録する。プロジェクト固有のコード・設計知見は台帳に書かず ACE 側へ回す。Problem は「X すると Y の手戻りが起きる → Z せよ」という知見の形で書く。機微情報は台帳エントリ・観測メモ・昇格 Issue 本文へも引用しない。

## 書き込み（定型コミット）の根拠

- 台帳の書き込みは `knowledge:` prefix の単独コミット（`/ace-curate` の Playbook 直コミットと同格の定型書き込み。承認は不要だが、記録した内容は振り返り結果で必ず報告する）。書き込み口は `git commit -- docs/08-knowledge/OBSERVATIONS.md` の形で記録したパスへ固定する（`git add` + pathspec 無しの `git commit` にしない — 索引に載った無関係な変更が単独コミットへ紛れ込んで直 push されるのを、この形だけが防ぐ）
- push が non-fast-forward で拒否されたら、上の復帰手順へ戻る — `git pull --ff-only` で取り込み、記録手順 0 から記録内容を作り直す。OBS ID の採番し直しだけで push を再試行しない（照合から push までの間に同じ主張が別セッションで記録されていれば、同一性判定を引き直さない限り重複エントリが残る）
- **ローカルに未 push のコミットがある回は、それらも同じ push で統合ブランチへ送られる**。台帳のコミットを単独に保つのは commit の pathspec だけで、push の粒度はブランチである。デフォルト統合ブランチ上に意図しないローカルコミットが無いことを記録の前に確かめる
- 導入先から SSOT や配布元へ観測を Issue で受け渡す経路（`[observation]` 接頭辞の受け渡し便）は**廃止**した。観測は作業中リポジトリの台帳で閉じ、他リポジトリへ渡すのは閾値到達後の起票だけにする。旧版が残した `[observation]` Issue は、SSOT で実行するときだけ [legacy-intake.md](legacy-intake.md) に従って取り込む
- 台帳の Markdown 本文へ script で文字列パッチを当てる場合は [Markdown 文字列パッチ規律](../../../docs-template/05-operations/deployment/markdown-patch-discipline.md)に従う

## 昇格閾値と特急レーン（根拠）

- 昇格閾値の判定対象は `Status` が `active` のエントリに限る（`promoted` / `archived` / `mitigated` は「これ以上昇格提案を出さない」と決着済みの状態で、決着の理由だけが違う）
- 起票先の分岐・`promoted` / `mitigated` の再発・見送りの書き戻しは [promotion.md](promotion.md)。`Kind: keep` の閾値到達は Issue ではなく**定着提案**（スキル・テンプレへの文言追加・手順化）として出す
- 特急レーン（データ破壊・広範な作業停止・セキュリティ）は閾値を待たずに起票を提案してよい。その場合も台帳へ記録し、提案に特急である理由を明示する。起票の実行は通常の昇格と同じく [filing.md](filing.md)「承認と起票」に従う（重大さの判断は理由の明示で利用者に見せ、起票は close で戻せる可逆操作として扱う）
- 台帳の掃除: `Last` から 180 日を超えて `Count` が 1 のままのエントリは `Status` を `archived` へ変更してよい（定型書き込み）
- **閾値は発火点であり、発火時に取った判断は状態として台帳へ書き戻す。** 放置すると次の到達で同じ判断を一から再演する。昇格を見送った判断は `mitigated` として書き戻す（ACE Playbook の件数上限を統合・抽象化へ回す ADR-047 と同じ原則で、閾値を緩めることでは代替できない）
