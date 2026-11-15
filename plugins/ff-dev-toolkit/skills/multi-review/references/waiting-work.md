# レビュー待ちを実装時間に変える手順

本線の「レビュー待ち時間の使い方」が指す詳細。作業ツリーの凍結は守る。通る書き込み先は、作業ツリーの外（scratchpad / `mktemp -d` / `/tmp`）、`.review-results/`、gitignore 済みのパスの 3 つだけ。

1. 修正版は `${FF_DEV_TOOLKIT_STATE_DIR:-$HOME/.config/ff-dev-toolkit}/tmp/<Issue 番号 or エージェント固有 ID>/` 等の永続作業ディレクトリへ丸ごと下書きする（消えても作り直しが要らない使い捨て小片だけなら scratchpad も可）。先に返ったレーンの指摘から作ってよい。全レーンが終端してから `cp` で作業ツリーへ当てる。下書きは Write ツールか、書き込み先がリテラルのパスで書く。python の文字列パッチは、書き込み先がリテラルで無いと deny される。
2. 次の独立した Issue は別 worktree で実装する。レビュー対象ツリーの固定には触れない。書き込み先を判定できない python パッチは、別 worktree 宛てでも deny される。その書き込みにだけ `FF_REVIEW_LOCK_ACK=1` を付ける。適用範囲はその別 worktree だけで、レビュー対象ツリーへの編集には使わない。
