# 共有版の再確定（spec-driven G4 用）

SKILL.md Step 6 の項目 1 で使う。**読むのは、`version` を変更した文書、または `.version-claims/` の対象を変えた回だけ**（該当しない回は読まずに G4 の次の項目へ進む）。並行 PR が同じ文書の version を先に取る競合に対して、最新 default branch から version・Changelog・claim を再確定し、push 済み commit を上書きせずに収束させる手順である。

## 手順

1. G1/G3 の変更と断片を provisional commit にまとめる（まだ push しない）。`git status --porcelain --untracked-files=all` が空になるまで無関係な変更を混ぜず、以後の version / claim 更新はこの commit へ `git commit --amend --no-edit` する
2. `default_ref="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD)"` を解決し、`origin/*` 形式であることを確認して `default_branch="${default_ref#origin/}"` を得る。`git rev-parse --verify --quiet "refs/remotes/origin/${default_branch}"` も通らなければ停止する
3. `git fetch origin "+refs/heads/${default_branch}:refs/remotes/origin/${default_branch}"` で明示 refspec を fetch する。dirty tree・fetch 失敗・ref 解決不能は stale 値へ fallback せず停止する
4. `git merge-base --is-ancestor "origin/${default_branch}" HEAD` が偽なら、先行 tree を rebase / merge で取り込み、remote の版ブロックを保全した現在版から version と Changelog を再生成する
5. `.version-claims/` が存在するリポジトリでは、version を変更した文書、およびリポジトリ固有ルールで version 不変時にも claim を要求する PLAYBOOK / PATTERNS ごとに、同梱 `${FF_DEV_TOOLKIT_ROOT}/scripts/update-version-claim.sh --base "origin/${default_branch}" --document <path>` を実行し、元の階層を保持した `.version-claims/<文書 path>.claim` を `document=<path>` / `version=<version>` / `change=<hash>` の3行だけで更新する。`.version-claims/` が無い利用先ではこの手順だけを省略する。helper は base blob ID（新規時は `ABSENT`）と current blob ID から Git 設定非依存の hash を生成し、symlink 親階層や検査不能を拒否する。文書・Changelog・claim と検証修正を stage し、`${FF_DEV_TOOLKIT_ROOT}/scripts/check-version-claims.sh --root "$(git rev-parse --show-toplevel)"` で index/tree の双方向対応を検査してから provisional commit を amend し、同じ commit に含める
6. 同じ文書の先行 PR が祖先検査後に merge された場合、claim の content conflict を片寄せ・削除で解消せず、最新 base から version / Changelog / claim を再生成する。feature branch 自身への push は default branch の CAS ではなく、merge-ready 前の祖先検査と文書別 claim を PR 経路の境界とする
7. amend 後の commit に対して受け入れ基準を再実行し、**初回 push 前**と merge-ready 直前にも手順2〜4を繰り返す。初回 push 前に remote が動いたら rebase と再生成へ戻る。既に feature branch を push 済みなら公開済み commit を amend / rebase せず、最新 default branch を merge して現在版から再生成した reconciliation commit を追加し、claim と G4 を再実行して通常 push する。再生成と G4 は最大3回とし、収束しなければ直列化を求めて停止する。`--force` / `--force-with-lease` で上書きしない

## 出典

- ADR-038（共有版境界の optimistic retry 契約）。契約の機械検査は `tests/shared-version-convergence/verify.sh`
