# レビュー待ちを実装時間に変える手順

本線の「レビュー待ち時間の使い方」が指す詳細。作業ツリーの凍結は守る。通る書き込み先は、作業ツリーの外（scratchpad / `mktemp -d` / `/tmp`）、`.review-results/`、gitignore 済みのパスの 3 つだけ。

1. 修正版は `${FF_DEV_TOOLKIT_STATE_DIR:-$HOME/.config/ff-dev-toolkit}/tmp/<Issue 番号 or エージェント固有 ID>/` 等の永続作業ディレクトリへ丸ごと下書きする（消えても作り直しが要らない使い捨て小片だけなら scratchpad も可）。先に返ったレーンの指摘から作ってよい。全レーンが終端してから `cp` で作業ツリーへ当てる。下書きは Write ツールか、書き込み先がリテラルのパスで書く。python の文字列パッチは、書き込み先がリテラルで無いと deny される。
2. 次の独立した Issue は別 worktree で実装する。レビュー対象ツリーの固定には触れない。書き込み先を判定できない python パッチは、別 worktree 宛てでも deny される。その書き込みにだけ `FF_REVIEW_LOCK_ACK=1` を付ける。適用範囲はその別 worktree だけで、レビュー対象ツリーへの編集には使わない。
3. baseline の全件ゲート（既定の高速モード）は任意。既定はレビュー収束後の最終ゲート 1 回で、baseline が効くのは差分（2 巡目なら前の巡の fix）が検査に掛からない文言だけの小さな修正のときだけ（指摘で HEAD が動けば証拠にならない）。実装・検査・手順を変えた PR の初回のレビューと、既存ロジックを組み替えた fix の後の確認の巡は、指摘が出る見込みの高い巡に数えて並走させない。回す場合は **PR HEAD へ detach した一時 worktree** で回す:
   - 作成先（ignore 済みまたはリポジトリ外、`git worktree add --detach "${FF_DEV_TOOLKIT_STATE_DIR:-$HOME/.config/ff-dev-toolkit}/tmp/<Issue番号>/baseline-wt" HEAD`）へ一時 worktree を作り、必要な依存（`npm ci --prefix <wt>/plugins/ff-dev-toolkit/mcp`）を入れる。
   - `FF_RUN_ALL_WAIT=1 bash <wt>/plugins/ff-dev-toolkit/tests/run-all.sh` で起動する（先行するゲート・`public-layout`・リリースが終わるまで自動待機し、同じマシンでの全件ゲート 1 本制限は守る）。
   - `guard-gate-in-flight` は worktree 単位でロックするため、全レビュー終端後は baseline 完了前でも元の作業ツリーで修正を進め、非 `.sh` 変更はそのまま commit できる。`.sh` を変更した fix 時の `/pre-commit-check` の `bash plugins/ff-dev-toolkit/tests/run-all/verify.sh` も、baseline の完走を待たずに回して commit できる（ランナーの自己検証はゲート間の排他へ参加しない）。baseline の赤はレビュー指摘と合わせて 1 つの fix commit に束ね、HEAD が動いたら最終ゲートは省かない。
   - 指摘 0 件かつ HEAD 不変で baseline が緑のときは、`BASELINE_GD="$(git -C <wt> rev-parse --absolute-git-dir)"` 配下の `"$BASELINE_GD/ff-dev-toolkit/gate-record"` を退避または `finish.sh precheck <PR> --gate-record <path>` へ渡してから、baseline 終了後に `git worktree remove`（必要なら `--force`）と一時ディレクトリ削除で片付ける。
