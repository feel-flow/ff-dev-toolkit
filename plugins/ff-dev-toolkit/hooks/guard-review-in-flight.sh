#!/usr/bin/env bash

#
# レビュー走行中の作業ツリー編集ガード + レビュー起動時の dirty ガード
# （PreToolUse / Edit・Write・MultiEdit・NotebookEdit・Bash・Agent）。
#
# 2 つのトリガーを 1 本の hook に相乗りさせている。守っている失敗は別だが、
# 読む材料（cwd の git リポジトリ）と出力契約（PreToolUse の permissionDecision）が
# 同じで、片方だけ持つ hook を 2 本置くと登録・fail-open 境界・opt-out が二重管理になる。
#
#   A) 走行中ロック: multi-agent.sh が `--task review` の起動時に
#      `<OUTPUT_DIR>/.review-in-flight` を置き、終了時（正常・DISCARDED・タイムアウト・
#      シグナル）に必ず消す。そのファイルがあり、書いた PID が生きている間は
#      編集系ツールと git の書き込み系コマンドを deny する。
#      背景: 走行中にツリーが動くと revision guard が結果を全破棄する。起動バナーは
#      stdout / stderr にしか出ないので、background 起動では誰も読まないまま編集が
#      始まる（同一クラスを 3 回実測）。バナーは人間向け、本 hook は機械向けの層。
#   B) 起動時 dirty ガード: `Agent`（旧名 `Task`）ツールで `subagent_type` が
#      `pr-review-toolkit:` から始まるとき、cwd が dirty なら **ask**（deny ではない）。
#      背景: レビューエージェントは `git diff <base>...HEAD` を見るので、未コミットの
#      修正は「無かったもの」として判定される。判定自体は正しく、静かに歪むのは
#      「その状態で起動できること」なので、止めるのではなく選ばせる。
#   C) サブエージェント経路の走行中ロック（レーン）: ホストのサブエージェントで
#      レビューを起動する経路には `multi-agent.sh` が居ないので、A のロックを誰も
#      書かず、A のガードが 1 度も発火しない。C はその穴を埋める層で、レビュー用
#      サブエージェントの起動を hook 自身が検知し、1 本につき 1 つの**レーン**を
#      `<repo root>/.review-results/.review-in-flight.d/` へ置く。A と同じ出力先の下・
#      同じ key=value 書式・同じ opt-out で読むので、ガード側の判定は A と 1 本化して
#      いる（別系統のロックを新設していない）。
#      **解除は全レーンの終端でのみ起きる**: 1 本が終わってもそのレーンが消えるだけで、
#      残りが 1 本でもあれば deny は続く。「一部のレビュアーが返ってきた」という体感で
#      凍結が解けることを、数える対象を per-lane のファイルにすることで構造的に消す。
#   D) 巡回カウンタ（レビュー巡回の上限）: 同じブランチで異なる HEAD に対するレビュー起動を
#      巡として数え、上限（既定 2 巡）を超える巡の起動を deny する。記録は
#      `<git common dir>/ff-review-rounds/`（出力先の外。レーン置き場の `rm -rf` や `--fresh` の
#      退避で消えない）。**PR 作成前のレビュー（実装途中の起動）も巡を消費する**。使い切ったら
#      `FF_REVIEW_ROUND_ACK=1` で 1 巡ずつ通す。統合ブランチ上・記録が無い / 読めない回は判定不能
#      = 通す + 警告。判定と母集団の正本は tests/lib/review-round-counter.sh のヘッダ
#
# deny と ask を使い分ける理由:
#   - A は「実行させると失うものがある」（数分ぶんのレビューが破棄される）ので
#     抜け道付き deny。同じ PreToolUse の `guard-checkout-restore.sh` /
#     `guard-pr-followup.sh` と同じ形。
#   - B は受け入れ条件が「コミットするか意図的に続行するかを選べる」ことを要求して
#     いるので `permissionDecision: "ask"`。理由文（permissionDecisionReason）は
#     許可プロンプトに出るため、利用者は文面を読んでから決められる。
#
# ロックの探索範囲（既知の限界）:
#   cwd の `git rev-parse --show-toplevel` 配下の **既定の OUTPUT_DIR**
#   （`.review-results/`）だけを見る。`multi-agent.sh --output-dir <other>` で既定から
#   動かした実行のロックは検出できない（黙って素通しになる = fail-open）。hook 入力には
#   走行中の orchestrator の引数が無く、探索を repo 全体へ広げると PreToolUse の
#   timeout（hooks.json の登録値）に見合わないため、既定パスに限る線引きを採る。
#
# 判定の限界（既知）:
#   - PID 再利用: ロックに書かれた PID が別プロセスへ再利用されると、生存判定だけでは
#     走行中と区別できない。緩和として、ロックの `started_epoch` からの経過が
#     FF_REVIEW_LOCK_MAX_AGE_SECONDS（既定 14400 秒 = 4 時間。multi-agent のタスク上限
#     900 秒 × 観点数を十分に超える）を超えたロックは、PID が生きていても stale として
#     扱い、警告だけ出して通す。上限より前に PID が再利用された場合は取りこぼす
#     （deny 側へ倒れるだけで、`rm <ロック>` で即復旧できる）。
#   - git 走査（Bash 分岐）の解析は素朴な空白トークン化で、引用文字列の中までは解かない。
#     `sh -c 'git commit ...'` の内側の git は git 走査では見ないが、Bash 書き込み走査が
#     sh 系の本文を再帰走査して同じ名簿で止める。heredoc 本文は git 走査の対象から外し
#     （データ）、Bash 書き込み走査ではインタプリタの stdin プログラムとして読む。
#   - Bash 書き込み走査（tests/lib/review-write-scan.sh。線引きと限界の正本はそのヘッダ）は
#     ヒューリスティック: インタプリタ（python / node / perl / ruby / awk / sh 系）のプログラム
#     本文はマーカー（`open(…"w")` / `write_text(` 等）で見るので、別名 import
#     （`from os import remove as r`）や動的に組み立てた書き込みは見逃す。語分割は引用符を保つ
#     （tests/lib/review-shell-lex.sh）。`python3 -m MOD` / `eval` / stdin から読むプログラム（`curl … | sh`）
#     は本文が無いので判定不能（走行中は deny 側）。`npm` / `make` 等のビルドツールが書く
#     成果物は対象外
#   - C の対応づけ（`SubagentStart`）は `agent_type` と「まだ対応づいていない最も古い
#     レーン」でしか結べない。隔離起動（レーンを取らない）と非隔離起動が**同じ型で同時に**
#     走っている場合、隔離側が非隔離側のレーンを引き受けうる（解放の本数は保存されるが、
#     どちらの終端でレーンが閉じるかは入れ替わりうる）。
#   - `git status` を読めなかった回は B を無音で通す（fail-open）。C のレーン取得は
#     `git status` より前に済ませてあるので、この fail-open は走行中ガードには波及しない。
#
# 発火しない（誤爆させない）ケース:
#   - ロック不在・ロックの PID が死んでいる（stale。この場合は systemMessage の
#     警告だけを出して**通す** — 消し忘れたロックで以後の全編集を止めない）
#   - Bash で書き込み系でない git（`git status` / `git log` / `git diff` /
#     `git stash list` / `git stash show` / `git restore --staged`（--worktree なし）等）や
#     git 以外のコマンド。コマンド位置に無い git（`echo git commit ...`）も対象外
#   - Bash の heredoc 本文（`<<` / `<<-` のトークン以降、終端行まで）に現れる git。
#     `cat <<'EOF' > notes.md` の本文に `git commit -m x` と書いても deny しない
#   - `git -C <path>` がロックを持つリポジトリ（cwd の toplevel）以外を指す場合
#   - **書き込み先がレビュー対象の指紋に映らない**書き込み。判定面は Bash 経由も
#     編集系ツール（`Edit` / `Write` / `MultiEdit` / `NotebookEdit`）も共通で
#     `tests/lib/review-write-scan.sh` の `target_in_tree`: 作業ツリーの外（scratchpad /
#     `mktemp -d` / `/tmp`）、`.review-results/`、**gitignore 済みのパス**（`tmp/**` /
#     `node_modules/.cache/**`）。ignored を通すのは、結果の破棄を決めるリビジョン指紋
#     （capture_repo_snapshot）が ignored を原理的に見ないため — 止めても守るものが無く、
#     `multi-review` が待ち時間に勧める作業（`gh` の出力を `tmp/` へ受ける形）だけが
#     止まっていた（Issue `#1756`）。判定できない書き込み先は deny 側（コマンド行に限る。既存
#     ファイルの本文の中の判定不能は止めない。線引きの正本は走査ライブラリのヘッダ。Issue `#1760`）
#   - **凍結の対象ツリーの外**への書き込み。レーンはレビュー対象のツリー（prompt が名指す同じ
#     リポジトリの worktree。無ければ cwd のツリー）を `tree=` で持ち、別 worktree のレビューだけが
#     走っている間は cwd のツリーでの書き込み・git 書き込みを止めない（Issue `#1760` の追記。
#     判定は tests/lib/review-lane-scope.sh）。逆に、レビュー対象の worktree を cwd とする
#     セッションは、別 worktree（起動側の cwd）に置かれた自分向けのレーンも数えて止まる（Issue
#     `#1935`）。委譲レビューのレーンは handoff の output-file が
#     レーンより後に書かれた時点で解放する（`--resume` の起動自体を止めない。Issue `#1792`）
#   - `/dev/null` へのリダイレクト、読み取り専用の形（`sed -n` / `-i` の無い `sed` /
#     `python3 -c 'print(1)'` / `node -e 'console.log(1)'` / 書き込みマーカーを含まない
#     heredoc プログラム / マーカー行の書き込み先リテラルがツリー外のプログラム）。走行中ロックの目的は作業ツリーの静止であって下書きの禁止ではない
#     （Issue `#1710` で Bash 経由の書き込み走査を追加。それ以前は Bash 経由の書き込み全般を
#     対象外にしていた）
#   - `Agent` でも `subagent_type` が `pr-review-toolkit:` 以外
#   - gitignore 済みの成果物だけがある状態（判定は `git status --porcelain` の出力有無で、
#     ignored は既定で出力されない）
#   - git リポジトリ外、jq 不在、解析不能な入力
#
# 実測メモ（`Agent` ツールの hook 入力形）:
#   Claude Code の PreToolUse は subagent 起動を `Task` または `Agent` という
#   tool_name で通し、`tool_input` に `subagent_type` / `prompt` / `description` を載せる
#   （https://code.claude.com/docs/en/hooks.md）。名前がハーネスの版で割れるため
#   matcher・本体とも両方を受ける。`subagent_type` が入力に無い版では判定材料が
#   無いので無音で通す（fail-open）。
#
# 実測メモ（C のレーンを開け閉めするイベント / claude 2.1.267 の同梱実装で確認）:
#   hook 入力の共通部は `session_id` / `cwd` / `permission_mode` / `agent_id` / `agent_type`
#   で、各イベントはそこへ固有のキーを足す。**`PreToolUse` の `agent_id` / `agent_type` は
#   「そのツールを呼んでいる側」のもの**で、これから起動するサブエージェントの id ではない
#   （`SubagentStart` が共通部の `agent_id` を新しいサブエージェントの id で上書きする）。
#   したがって取得点（PreToolUse）と解放点（SubagentStop）を `agent_id` で直接は結べない。
#   - 取得: `PreToolUse`（`Agent` / `Task`）。`tool_use_id` / `tool_input.subagent_type` /
#     `tool_input.isolation` を持つ。**レーンを取るかどうかの判定材料はここにしか無い。**
#     同じ `tool_use_id` で再度流れる経路（auto mode の拒否に対して hook が `retry: true`
#     を返す形）があるので、取得は鍵に対して冪等にする。
#   - 対応づけ: `SubagentStart`（`agent_id` / `agent_type`。`tool_use_id` は無い）。
#     ここで既存レーンへ `agent_id` を書き込み、以後の解放を**個体で**対応づける。
#     レーンの新設はしない（isolation / subagent_type が載らないため）。
#   - 解放 1: `SubagentStop`（`agent_id` / `agent_type` を持つ。`tool_name` は無い）。
#     `agent_id` が一致するレーンを 1 本閉じる。**同じ `agent_id` の 2 回目以降は no-op**
#     （`SubagentStop` はサブエージェントが 1 回応答を終えるたびに発火するので、
#     `SendMessage` で継続されたレビュアーは 1 本で複数回終端イベントを出す）。
#     対応づいていないレーンしか無い場合だけ、同型の最も古い 1 本へフォールバックする。
#   - 解放 2: `PermissionDenied`（`tool_name` / `tool_input` / `tool_use_id` を持つ）。
#     **auto mode（分類器）による拒否のときだけ発火する**ので、利用者が手で断った起動は
#     ここへ来ない。したがってこれは best-effort の追加経路であって、唯一の解放経路には
#     しない（未対応づけレーンの短い寿命がその受け皿 = 下の LANE_PENDING_MAX_AGE）。
#   `PostToolUse` は使わない — 背景実行のサブエージェントで「起動時に出るのか完了時に
#   出るのか」がハーネス側で保証されておらず、起動時に出る版では 1 本目の完了を待たずに
#   凍結が解けるため（部分完了で解けないという受け入れ条件に反する）。
#
# レーンを取らないケース（意図的な非適用。ここが「止まらない理由」の正本）:
#   - `tool_input.isolation` が `worktree` の起動。隔離されたレビュアーは親と作業ツリーを
#     共有しないので凍結の前提が無い（git-workflow の「ステップ6」が正本）。ここでレーンを
#     取ると、隔離 worktree の中で変異注入を行うレビュアーが**自分のロックで自分の編集を
#     止める**（自己デッドロック）。
#   - 名簿（FF_REVIEW_SUBAGENT_LOCK_TYPES）に無く、かつ委譲レビューでもない subagent。
#     既定の名簿は pr-review-toolkit の **read-only な**レビュアーだけで、共有ツリーを
#     編集する前提の `code-simplifier` は同じ自己デッドロックを避けるため外してある。
#     名簿が実体（別プラグインのレビュアー群）へ追随しているかは
#     `scripts/check-review-roster-drift.sh` が突き合わせる（実行時は列挙、検査時に照合）。
#     **例外**: `multi-agent.sh --delegate-to-host` の委譲レビューは汎用の subagent_type で
#     起動されるため名簿に載らないが、渡された prompt（マーカーまたは委譲プロンプトのパス）
#     で識別してレーンを取る。名簿へ汎用型を足すとレビュー以外の委譲まで凍結するため。
#   - `Agent` / `Task` の `PreToolUse` が来ない状況（イベントが来なければ何も起きない
#     = fail-open）。
#   - レーン置き場（`.review-results/` とその下の `.review-in-flight.d/`）が symlink である
#     か、物理パスがリポジトリの外を指す場合。走査は上限を超えたレーンを**削除する**ので、
#     検証できない置き場では取得・走査・解放のすべてを行わない（素通し）。
#   - **名簿の型で動いているサブエージェント自身の編集**（deny しない側の非適用）。
#     詳細は本体の「レビュアー自身の編集は止めない」節。
#
# 設計原則:
#   - fail-open: jq 不在・git 外・壊れた stdin・ロック無しでは黙って許可（exit 0・無出力）。
#     ガードとしての取りこぼしは許容し、誤ブロックだけを避ける。**例外は走行中の Bash 書き込み
#     走査**で、書き込み先を判定できない形は deny 側へ倒す（下記「Bash 経由の書き込み走査」。
#     ロックが生きているときだけ払うコストで、ロック無しの経路には及ばない）
#   - ホスト側の打ち切りは fail-open にしない: PreToolUse の登録は `onFailure: "block"` を持つ
#     （Claude Code v2.1.295 以降）。この hook が登録の timeout を超える・起動できない・0 / 2 以外で
#     終わると、ホストは呼び出しを止める。Windows の Git Bash ではロック生存下の判定が 6〜25 秒かかり、
#     旧 timeout の 10 秒を超えた回はホストが判定を捨てて呼び出しを通していた（Issue `#2271`）。
#     したがって **どの経路も明示的な `exit 0` で終える**（判定の fail-open は exit 0 + 無出力で表す）。
#     漏れた 0 以外の終了は EXIT trap（ff_on_exit）が判定不能の systemMessage + exit 0 へ寄せる
#     二重の防御で、trap を張り直すとこの正規化が外れる（trap の定義の注記を参照）
#   - 互換性: bash 3.2（stock macOS）互換。連想配列・readarray・=~ は使わない
#
# 環境変数:
#   FF_REVIEW_LOCK_OVERRIDE=1                     A（走行中ロック）と C（レーン）の deny を解除する。
#                                                 Bash ツール
#                                                 なら対象コマンド（区間）先頭の環境代入としても効く
#                                                 （`FF_REVIEW_LOCK_OVERRIDE=1 git commit ...` /
#                                                 `FF_REVIEW_LOCK_OVERRIDE=1 tee notes.md`）。
#                                                 Edit / Write などの編集系ツールにはコマンド行が
#                                                 無く、hook はセッションの環境変数を継承するだけ
#                                                 なので、そちらは再起動なしには変えられない
#                                                 （tool 非依存の復旧手段は `rm <ロック>`）
#   FF_REVIEW_LOCK_MAX_AGE_SECONDS=<秒>           これより古いロックは PID 生存でも stale（既定 14400）
#   FF_REVIEW_SUBAGENT_LOCK_MAX_AGE_SECONDS=<秒>  **対応づいた**（SubagentStart 済みの）レーンの
#                                                 寿命上限（既定 14400 = A に揃える。導出は本体の
#                                                 LANE_MAX_AGE のコメント）。これを超えたレーンは走査の
#                                                 たびに**自動で削除**され、そのとき systemMessage で
#                                                 回収したことを必ず出す（無出力で凍結を解かない）
#   FF_REVIEW_SUBAGENT_LOCK_PENDING_SECONDS=<秒>  **まだ対応づいていない**レーンの寿命上限（既定 1800）。
#                                                 手で拒否された起動は解放イベントが 1 つも来ないので、
#                                                 その受け皿。手動の回収は `rm -rf -- '<レーン置き場>'`
#                                                 （拒否理由に実パスが出る）
#   FF_REVIEW_SUBAGENT_LOCK_TYPES=<空白区切り>     C がレーンを取る subagent_type のパターン名簿
#                                                 （glob 可。既定は pr-review-toolkit の read-only な
#                                                 レビュアー 5 種）
#   FF_REVIEW_ROUND_LIMIT=<n>                     D（巡回カウンタ）の上限（既定 2、0 で無効）。3 巡目以降の
#                                                 起動を deny する。判定の正本は tests/lib/review-round-counter.sh
#   FF_REVIEW_ROUND_ACK=1                         D の 1 回限りの通過口。Bash は起動コマンドの区間先頭の
#                                                 環境代入、Agent は prompt の行頭の単独行（セッション環境は読まない）
#   FF_DEV_TOOLKIT_SKIP_REVIEW_IN_FLIGHT_GUARD=1  この hook 全体を無効化する。`claude -p` /
#                                                 background / subagent など非対話実行では
#                                                 permissionDecision "ask" が block 相当になるため、
#                                                 レビュー起動を自動化する場面ではこれを設定する

# fail-open のため set -e / set -u は使わない。

# 異常終了を onFailure: block へ漏らさない（設計原則「ホスト側の打ち切りは fail-open にしない」の対）。
# 0 以外で抜けた回はガード自身の不具合として、判定不能を systemMessage で知らせてから exit 0 で通す。
# 止めるのはホスト側の打ち切り（timeout）と起動失敗だけにする — ガードの不具合 1 つで全 OS の全呼び出しを
# 止めないための手当て（Issue `#2271`）。黙って通さないのは、凍結の素通りに気づく手段を残すため。
# 巡回カウンタの後始末（review_round_finish）もこの 1 本の EXIT trap から呼ぶ。trap を張り直すと、
# 後から張った方がこの正規化を上書きするため。emit_* は出力の後に exit 0 するので、0 以外でここへ
# 来るのはまだ何も出力していない回だけで、出す JSON は 1 本に収まる。
ROUND_FINISH_ARMED=0
ff_on_exit() {
  local rc=$? note=""
  if [ "$rc" -eq 0 ]; then
    [ "$ROUND_FINISH_ARMED" -eq 1 ] && review_round_finish
    return 0
  fi
  if [ "$ROUND_FINISH_ARMED" -eq 1 ] && [ "${ROUND_NOTE_DONE:-0}" -ne 1 ]; then
    review_round_commit
    [ -n "${ROUND_NOTE:-}" ] && note="${ROUND_NOTE}
"
  fi
  note="${note}⚠️ ff-dev-toolkit guard（レビュー走行中）: ガードが判定の途中で異常終了しました（rc=${rc}）。判定できなかったので、この呼び出しは止めずに通します。レビューの走行中なら、完了の通知が出るまで編集・commit を控えてください。"
  jq -n --arg m "$note" '{systemMessage: $m}' 2>/dev/null \
    || printf '{"systemMessage":"ff-dev-toolkit guard: abnormal exit (rc=%s); the call was passed without a decision"}\n' "$rc"
  exit 0
}
trap ff_on_exit EXIT

# stdin は bash 組み込みの read で読み切る（外部コマンドに依存しない）。`cat` だと PATH が
# 空・壊れた環境で command not found → stdin 未読のまま exit 0 となり、書き手（ホスト）が
# EPIPE / SIGPIPE を受ける（既存 2 ガードと同じ修正）。opt-out も
# stdin を読み切ってから抜ける。-d '' は EOF で非 0 を返すが input には内容が入っている。
#
# bash 5 以降は -N でまとめて読む。-d '' はパイプから 1 バイトずつ読むので、プロセスの重い
# Windows（Git Bash の bash 5）では 300KB の Write で読み取りだけに 1 秒以上かかり、レビュー走行中の
# 判定と合わせて当時の登録 timeout（10 秒）を超えると、大きな Write が凍結を素通りしていた（Issue `#2020`）。
# -N は指定した文字数か EOF まで読むので、1 MiB ずつ EOF まで繰り返す（最後の端数は EOF で非 0 が
# 返っても変数に入る）。-N は 4.1 からで、4.x には -N の不具合（4.3 で修正）と多バイト文字の途中切れ
# （5.0 で修正）があるので、5 未満（macOS の 3.2 を含む）は従来どおり -d '' で読む。
input=""
if [ "${BASH_VERSINFO[0]:-3}" -ge 5 ]; then
  _ff_chunk=""
  while IFS= read -r -N 1048576 _ff_chunk; do
    input="$input$_ff_chunk"
  done
  input="$input$_ff_chunk"
  unset _ff_chunk
else
  IFS= read -r -d '' input || true
fi

# ASDD ゲートはこの drain より後に置く。ゲートの早期終了（.asdd 設定があり node が
# 無い / 当該 feature が無効 / ヘルパ自体が読めない）は exit 0 なので、ゲートを先頭へ
# 置くと stdin 未読のまま抜ける経路ができ、上の drain が守っている EPIPE / SIGPIPE が
# そこから漏れる。ゲート自身は stdin を消費しない（asdd-hook-gate.sh）ので、読み切って
# から呼んでも hook が受け取るペイロードは変わらない。
# ASDD 2.0: disabled optional hooks do not prompt, block, or mutate.
if ! source "${BASH_SOURCE[0]%/*}/asdd-hook-gate.sh"; then
  echo 'ff-dev-toolkit: ASDD Hook helper is unavailable; optional hook skipped' >&2
  exit 0
fi
asdd_hook_enabled hooks || exit 0

[ "${FF_DEV_TOOLKIT_SKIP_REVIEW_IN_FLIGHT_GUARD:-0}" = "1" ] && exit 0

command -v jq >/dev/null 2>&1 || exit 0

tool="$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null)" || exit 0
EVENT="$(printf '%s' "$input" | jq -r '.hook_event_name // ""' 2>/dev/null)"
# イベント名を持たない版のハーネスは、本 hook が元から持っていた唯一の入口へ倒す。
[ -n "$EVENT" ] || EVENT="PreToolUse"
# SubagentStart / SubagentStop は tool_name を持たない（レーンの対応づけ・解放専用の
# 入口）。それ以外の入口は tool 名が判定材料なので、無ければ従来どおり無音で通す。
case "$EVENT" in
  SubagentStart | SubagentStop) : ;;
  *) [ -n "$tool" ] || exit 0 ;;
esac

CWD="$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null)"
# Windows の Claude Code は cwd を `C:\repo` の形で渡す。Git Bash / Cygwin では ROOT（git が返す
# `C:/repo`）と同じ区切りへ寄せる（相対パスを CWD へ繋いだ結果を ROOT と前方一致で比べるため。Issue `#2018`）
case "${OSTYPE:-}:$CWD" in
  msys*:[A-Za-z]:\\* | cygwin*:[A-Za-z]:\\*) CWD="${CWD//\\//}" ;;
esac
[ -d "$CWD" ] || CWD="$(pwd)"

command -v git >/dev/null 2>&1 || exit 0
ROOT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -n "$ROOT" ] && [ -d "$ROOT" ] || exit 0

# D（巡回カウンタ）の警告は、どの出口で終わっても 1 度だけ systemMessage へ載せる。空のときは
# 従来と 1 バイトも変わらない出力にする（`+ {}` は同じ JSON を出す）。巡の記録は「起動が通る」と
# 決まった出口（無音・systemMessage）で書き、deny では書かない。ask（利用者が許可すれば起動する）は
# 仮記録し、拒否されて PermissionDenied が来たら同じ鍵で取り消す。
ROUND_NOTE=""
ROUND_NOTE_DONE=0
ROUND_PENDING=0
emit_deny() { # <reason>
  ROUND_NOTE_DONE=1
  ROUND_PENDING=0
  jq -n --arg reason "$1" --arg rn "$ROUND_NOTE" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}} + (if $rn == "" then {} else {systemMessage: $rn} end)' 2>/dev/null
  exit 0
}

emit_ask() { # <reason>
  review_round_commit provisional
  ROUND_NOTE_DONE=1
  jq -n --arg reason "$1" --arg rn "$ROUND_NOTE" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "ask", permissionDecisionReason: $reason}} + (if $rn == "" then {} else {systemMessage: $rn} end)' 2>/dev/null
  exit 0
}

emit_message() { # <text>
  review_round_commit
  ROUND_NOTE_DONE=1
  jq -n --arg m "$1" --arg rn "$ROUND_NOTE" '{systemMessage: (if $rn == "" then $m else ($rn + "\n" + $m) end)}' 2>/dev/null
  exit 0
}

# D) 巡回カウンタ（判定・母集団・記録の置き場の正本は tests/lib/review-round-counter.sh のヘッダ）。
# 上限を超える巡の起動を deny し、判定不能は警告だけ出して通す。ライブラリを読めない回は、
# レビューの起動と分かっている agent 経路でだけ判定不能を知らせる（bash 経路は起動かどうかを
# ライブラリが決める）。
review_round_gate() { # <agent|bash>
  local lib="${BASH_SOURCE[0]%/*}/../tests/lib/review-round-counter.sh"
  # shellcheck source=../tests/lib/review-round-counter.sh
  if [ -r "$lib" ] && . "$lib" 2>/dev/null && [ "$(type -t ff_review_round_gate 2>/dev/null)" = "function" ]; then
    ff_review_round_gate "$1" || return 0
    [ "$RR_VERDICT" = "deny" ] && emit_deny "$RR_REASON"
    ROUND_NOTE="$RR_NOTE"
    [ -n "$RR_PENDING_FILE" ] && ROUND_PENDING=1
  else
    # ライブラリが無くても、レビューの起動と分かる回は判定不能を知らせる（黙って通さない）。
    # Bash の判定はライブラリに置いてあるので、ここは起動スクリプト名の字面だけを見る最小限の判定。
    local launch=0
    case "$1" in
      agent) launch=1 ;;
      bash)
        case "$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)" in
          *multi-review.sh* | *multi-agent.sh* | *codex-review.sh*) launch=1 ;;
        esac
        ;;
    esac
    [ "$launch" -eq 0 ] || ROUND_NOTE="ℹ️ ff-dev-toolkit guard（レビュー巡回カウンタ）: 巡回カウンタ（${lib}）を読めないため巡を数えられません。判定不能として通します。"
  fi
  if [ -n "$ROUND_NOTE" ] || [ "$ROUND_PENDING" -eq 1 ]; then
    ROUND_FINISH_ARMED=1
  fi
  return 0
}
review_round_commit() { # [provisional]
  [ "$ROUND_PENDING" -eq 1 ] || return 0
  ROUND_PENDING=0
  if [ "${1:-}" = "provisional" ]; then
    ff_review_round_commit_provisional "$(lane_key)" || ROUND_NOTE="$RR_NOTE"
  else
    ff_review_round_commit || ROUND_NOTE="$RR_NOTE"
  fi
}
review_round_finish() { # EXIT trap: 無音の出口で記録し、警告を 1 度だけ出す
  [ "$ROUND_NOTE_DONE" -eq 1 ] && return 0
  review_round_commit
  [ -n "$ROUND_NOTE" ] && jq -n --arg m "$ROUND_NOTE" '{systemMessage: $m}' 2>/dev/null
  return 0
}

# ── ロックの読み取り（A・B・C が使う） ─────────────────────────────────────
LOCK="${ROOT}/.review-results/.review-in-flight"
# C のレーン置き場。A のロックと同じ出力先の下に置くので、探索範囲・opt-out・回収手順は
# A と同じ 1 組で済む（ディレクトリ 1 つの追加であって、別系統のロックではない）。
OUTPUT_DIR_NAME=".review-results"
LANE_DIR="${ROOT}/${OUTPUT_DIR_NAME}/.review-in-flight.d"

# レーンを取る subagent_type の名簿（空白区切り・glob 可）。既定は pr-review-toolkit の
# **read-only な**レビュアーだけにしてある。`code-simplifier` を入れないのは、あれが
# 共有ツリーを編集する前提のエージェントで、自分が置いたレーンで自分の Edit が deny される
# （自己デッドロック）ため。名簿はもう 1 つの役割も持つ: 名簿の型で**動いている**
# サブエージェント自身の編集は deny しない（下の「レビュアー自身は止めない」節）。
REVIEW_LOCK_TYPES="${FF_REVIEW_SUBAGENT_LOCK_TYPES:-pr-review-toolkit:code-reviewer pr-review-toolkit:silent-failure-hunter pr-review-toolkit:pr-test-analyzer pr-review-toolkit:type-design-analyzer pr-review-toolkit:comment-analyzer}"

# 委譲レビュー（multi-agent.sh --delegate-to-host）の識別マーカー。
# あの経路はオーケストレータが rc=3 で終了し、**ホストが自分のセッションでレビューを走らせる**。
# 起動に使われるのは汎用の `subagent_type` なので名簿には載らず、名簿へ汎用型を足すと
# レビュー以外の委譲まで凍結してしまう。そこで「何の型で起動したか」ではなく
# **何を渡されたか**で識別する: 委譲プロンプトのパス、または handoff がホストへ載せるよう
# 求めるマーカーが `prompt` に在れば、その起動はレビューである。
# マーカーは multi-agent.sh の handoff 文（scripts/lib/multi-agent-report-body.sh の
# print_delegation_handoff）と対。片方だけ変えると識別が静かに外れるので、
# tests/guard-review-in-flight が両者の綴りの一致を検査する。
REVIEW_DELEGATION_MARKER="FF-REVIEW-DELEGATED"

# 対応づいた（SubagentStart で agent_id を書き込んだ）レーンの寿命上限。
# 導出: A の `FF_REVIEW_LOCK_MAX_AGE_SECONDS` と同じ 14400 秒（4 時間）に**揃える**。
# 同じ 1 回のレビューを、外部 CLI 経路（A）とサブエージェント経路（C）のどちらで回すかで
# 凍結が解ける時刻が変わるのは筋が悪く、C だけを短くする積極的な理由が無い。multi-review の
# 1 回転は 5〜25 分なので、どちらの上限も「正当に走っているレビューを途中で解かない」側に
# 十分な余裕がある（上限は取りこぼし回収のための天井であって、想定所要時間ではない）。
LANE_MAX_AGE="${FF_REVIEW_SUBAGENT_LOCK_MAX_AGE_SECONDS:-14400}"
case "$LANE_MAX_AGE" in
  '' | *[!0-9]*) LANE_MAX_AGE=14400 ;;
esac

# まだ対応づいていない（`SubagentStart` が来ていない）レーンの寿命上限。
# 導出: このレーンは「`Agent` の起動が hook を通ったが、サブエージェントがまだ走り始めて
# いない」状態だけを表す。起動が**手動で拒否された**場合、`PermissionDenied` は auto mode の
# 拒否でしか発火しない（claude 2.1.267 の同梱実装で確認）ので解放イベントが 1 つも来ず、
# 上の 14400 秒まで凍結が残ってしまう。取得から `SubagentStart` までに挟まりうる最長の
# 待ちは「利用者が許可プロンプトへ答えるまで」なので、それを十分に超え、かつ multi-review の
# 1 回転上限（25 分）も超える 1800 秒（30 分）を既定にする。`SubagentStart` を出さない版の
# ハーネスでは全レーンがこの上限で回収されるが、1 回転の上限より長いので通常の 1 巡は覆う。
LANE_PENDING_MAX_AGE="${FF_REVIEW_SUBAGENT_LOCK_PENDING_SECONDS:-1800}"
case "$LANE_PENDING_MAX_AGE" in
  '' | *[!0-9]*) LANE_PENDING_MAX_AGE=1800 ;;
esac

# 判定本体は tests/lib/review-in-flight-judge.sh。読めないときは許可せず deny する。
# ロックの有無はここの関数が読むので、読めない回は「ロック無しだから通す」に倒さない。
_ff_judge="${BASH_SOURCE[0]%/*}/../tests/lib/review-in-flight-judge.sh"
_ff_judge_deny() { # <理由>
  emit_deny "⚠️ ff-dev-toolkit guard（レビュー走行中）: 判定ライブラリを読めないため、編集とコマンドを止めます（${1}）。対象: ${_ff_judge}。cache を手で直さず、plugin を更新・再導入してください。"
}
if [ -L "$_ff_judge" ]; then
  _ff_judge_deny "symlink です"
elif [ ! -f "$_ff_judge" ]; then
  _ff_judge_deny "ファイルがありません"
elif [ ! -s "$_ff_judge" ]; then
  _ff_judge_deny "0 バイトです"
elif [ ! -r "$_ff_judge" ]; then
  _ff_judge_deny "読み取れません"
fi
_ff_judge_last="$(awk 'NF { l = $0 } END { print l }' "$_ff_judge" 2>/dev/null)" || _ff_judge_last=""
if [ "$_ff_judge_last" != "_ff_review_in_flight_judge_loaded=1" ]; then
  _ff_judge_deny "末尾まで読めていません（読み込み完了の印ではありません）"
fi
_ff_review_in_flight_judge_loaded=""
# shellcheck source=../tests/lib/review-in-flight-judge.sh
. "$_ff_judge"
if [ "${_ff_review_in_flight_judge_loaded:-}" != "1" ]; then
  _ff_judge_deny "読み込み完了の印がありません"
fi
unset _ff_judge _ff_judge_last
unset -f _ff_judge_deny

CWD_PROTECTED=0
in_protected "$ROOT_PHYS_G" && CWD_PROTECTED=1

# ---- Bash 経由の書き込み走査（Issue `#1710`）---------------------------------------
# 判定の本体は共有ライブラリ tests/lib/review-write-scan.sh（線引き・既知の限界の正本は
# そのヘッダ）。hook 本体の行数を分割閾値の内側に保つため、ここでは呼び出しと deny 文の
# 組み立てだけを持つ。走行中材料があるときだけ読み込む（ロック無しの経路は従来どおり
# 何も読まない）。ライブラリが読めない回は「判定不能」として deny 側へ倒す
# （guard-exit-code.sh の検出器不在と同じ形）。
WRITE_SCAN_LIB="${BASH_SOURCE[0]%/*}/../tests/lib/review-write-scan.sh"

# 対象ツールの絞り込み（ロックがあるときだけ払うコスト）
case "$tool" in
  Edit | Write | MultiEdit | NotebookEdit)
    # **レビュー出力先への書き込みは止めない。** ここを止めると、委譲レビュー
    # （--delegate-to-host）が自分の結果ファイルを書けず、自分のレーンで自分を
    # デッドロックさせる（handoff の手順 2 がまさにこのパスへ書く）。線引きは B の
    # dirty 判定が `:(exclude)${OUTPUT_DIR_NAME}` で「作業ツリーではない」と扱って
    # いる領域と同じで、そこへの書き込みはレビュー対象の diff を動かさない。
    # `code-simplifier` を名簿から外したのと同型の自己デッドロック回避。
    # 書き込み先のキーは**ツールごとに違う**。`NotebookEdit` は `file_path` を持たず
    # `notebook_path` を取る（ツール schema で確認）。`file_path` だけを読んでいた頃は
    # `edit_path` が空になり、この下の免除にも `.review-results/` の免除にも一度も
    # 入らなかった（= notebook の書き込みは出力先へでも deny され、委譲レビューが
    # 自分の結果を書けない自己デッドロックが残っていた）。
    edit_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' 2>/dev/null)" || edit_path=""
    # Windows の Claude Code は `C:\repo\x.md` の形で渡す。Git Bash / Cygwin では区切りを / へ寄せ、
    # ドライブ付きを絶対パスとして扱う。寄せないと CWD の後ろへ繋がれてツリー内に化け、ツリー外や
    # `.review-results\` への書き込みまで deny していた（Issue `#2018`）。ツール入力の JSON の値は
    # シェルを通らないので、Bash の語と違ってバックスラッシュはそのまま区切りとして読んでよい
    edit_drive=0
    case "${OSTYPE:-}" in
      msys* | cygwin*)
        case "$edit_path" in
          [A-Za-z]:\\* | [A-Za-z]:/*) edit_path="${edit_path//\\//}"; edit_drive=1 ;;
        esac
        ;;
    esac
    case "$edit_path" in
      /*) : ;;
      ?*) [ "$edit_drive" -eq 1 ] || edit_path="${CWD}/${edit_path}" ;;
    esac
    case "$edit_path" in
      # `..` / `.` を含む未正規化のパスは早抜けさせない（`.review-results/../src/x` がツリー内の
      # 書き込みのまま免除される）。下の resolve_target で物理パスへ解決してから判定する
      */../* | */./* | */.. | */.) : ;;
      "${ROOT}/${OUTPUT_DIR_NAME}/"*) exit 0 ;;
    esac
    # 出力先の外でも、**レビュー対象の指紋に映らない書き込み先**は止めない。判定面は
    # Bash 経由の書き込みと同じ `target_in_tree`（作業ツリー外 / 出力先 / gitignore 済み）
    # を使う — ここに別の線引きを置くと、同じ書き込みがツール経路によって可否が割れる
    # （実測された過剰 deny はまさにその形で、`Write` だけがツリー外の下書きを通さなかった）。
    # ライブラリを読めない回・書き込み先を解決できない回は従来どおり deny 側へ進み、
    # **その理由を deny 文へ載せる**（Bash 経路は同じ失敗に理由を付けているので、
    # 説明までツール経路で揃える）。
    if [ -n "$edit_path" ]; then
      ROOT_PHYS="$(phys_dir "$ROOT")"
      [ -n "$ROOT_PHYS" ] || ROOT_PHYS="$ROOT"
      # ゲートは**実際に呼ぶ関数すべて**に張る。`ff_write_scan_init` の実在だけを見て
      # `! target_in_tree` を判定式にすると、`target_in_tree` を欠いた lib（同期途中の
      # 切り詰め・改名・移設）で `!` が「コマンドが無い（127）」を反転して真にし、
      # 走行中の全編集を無音で許可する。rc は変数へ取り、**1（免除）以外は deny 側**。
      # shellcheck source=../tests/lib/review-write-scan.sh
      if [ -r "$WRITE_SCAN_LIB" ] && . "$WRITE_SCAN_LIB" 2>/dev/null \
        && [ "$(type -t ff_write_scan_init 2>/dev/null)" = "function" ] \
        && [ "$(type -t resolve_target 2>/dev/null)" = "function" ] \
        && [ "$(type -t target_in_tree 2>/dev/null)" = "function" ]; then
        ff_write_scan_init "$ROOT_PHYS" "$(phys_dir "$CWD")" "$OUTPUT_DIR_NAME" "$PROTECT_TREES"
        # ツールの file_path は文字どおりのパス（`$` や `~` をシェルとして展開しない）
        WS_LITERAL_PATHS=1
        resolve_target "$edit_path"
        edit_resolve_rc=$?
        WS_LITERAL_PATHS=0
        if [ "$edit_resolve_rc" -eq 0 ]; then
          target_in_tree "$RESOLVED"
          edit_tit_rc=$?
          if [ "$edit_tit_rc" -eq 1 ]; then
            exit 0
          fi
          if [ "${WS_IGNORE_UNKNOWN:-0}" -eq 1 ]; then
            write_note="この書き込み先が gitignore 済みかを判定できません（git check-ignore rc=${WS_IGNORE_RC:-?}: ${RESOLVED}）。判定できない書き込みは deny 側へ倒します。
"
          fi
        else
          write_note="書き込み先を判定できません（${RESOLVE_WHY:-理由不明}: ${edit_path}）。判定できない書き込みは deny 側へ倒します。
"
        fi
      else
        write_note="書き込み先を判定できません（走査ライブラリ ${WRITE_SCAN_LIB} を読めない、または必要な関数が欠けている）。判定できない書き込みは deny 側へ倒します。
"
      fi
    fi
    ;;
  Bash)
    cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)" || exit 0
    cmd="${cmd//$'\r'/}"  # Windows の jq.exe は改行を \r\n で出す（Issue `#2017`）
    [ -n "$cmd" ] || exit 0
    # heredoc 本文（`<<` / `<<-` のトークン以降、終端行まで）は実行されるコマンドでは
    # なくデータなので、判定対象から落とす。`cat <<'EOF' > notes.md` の本文に
    # `git commit -m x` と書いただけで deny すると、レビュー待ちのメモ書きが止まる。
    # 判定は共有ヘルパ `tests/lib/heredoc-strip.sh`（正本はヘルパのヘッダ）。ヘルパが
    # 読めない・awk が失敗した・未終端（rc 3）のときは生コマンドで git 走査を続けつつ、
    # Bash 書き込み走査では「判定不能」として扱う（走行中に限る deny 側。復旧手段は
    # deny 文に出る）。
    HEREDOC_HELPER="${BASH_SOURCE[0]%/*}/../tests/lib/heredoc-strip.sh"
    HEREDOC_STATE=unavailable
    HEREDOC_BODIES=""
    # shellcheck source=../tests/lib/heredoc-strip.sh
    if . "$HEREDOC_HELPER" 2>/dev/null; then
      code_only="$(ff_heredoc_strip "$cmd")"
      case $? in
        0) HEREDOC_STATE=ok; HEREDOC_BODIES="$(ff_heredoc_bodies "$cmd" 2>/dev/null)" || HEREDOC_BODIES="" ;;
        3) HEREDOC_STATE=unterminated ;;
        *) code_only="$cmd" ;;
      esac
    else
      code_only="$cmd"
    fi
    [ -n "$code_only" ] || exit 0
    HEREDOC_CODE="$code_only"
    has_git=0
    case "$code_only" in
      *git*) has_git=1 ;;
    esac
    # git が「コマンド位置」にあり、かつ書き込み系サブコマンドを取る形だけを対象に
    # する（`echo git commit ...` のような文字列出力は対象外）。連結演算子で分割し、
    # 先頭の環境代入・ラッパー・git のグローバルオプションを剥がしてから判定する。
    # 分割過多は「git がコマンド位置に来ず非発火」に倒れるだけで誤ブロックにならない。
    is_write_git=0
    cmd_override=0
    segments="$(printf '%s\n' "$code_only" | awk '{ gsub(/&&|\|\||;|\|/, "\n"); print }')"
    [ "$has_git" -eq 1 ] || segments=""
    # 先行区間の `cd <dir>`（`cd <worktree> && git commit`）は後続の git の対象ツリーを動かす。
    # 追わないと、別 worktree での commit を cwd のツリーの commit と読んで止める（Issue `#1760`）。
    git_base="$CWD"
    git_sub_saved=""
    git_restore=0
    while IFS= read -r seg; do
      [ -n "$seg" ] || continue
      # サブシェル `( cd X … )` の cd は閉じ括弧の後ろへ漏らさない
      if [ "$git_restore" -eq 1 ]; then git_base="$git_sub_saved"; git_sub_saved=""; git_restore=0; fi
      case "$seg" in *')' | *') ') [ -n "$git_sub_saved" ] && git_restore=1 ;; esac
      set -f
      # shellcheck disable=SC2206 # 素朴な空白トークン化（意図的。glob は set -f で抑止）
      ctoks=($seg)
      set +f
      case "${ctoks[0]:-}" in '(' | '(cd' | '(pushd') [ -n "$git_sub_saved" ] || git_sub_saved="$git_base" ;; esac
      # `(cd X` / `{ cd X` / `cd -- X` / `cd -P X` / `pushd X`。解決できない行き先（`$VAR` / `-` /
      # 空白を含む引用パス）は「不明」（"?"）として持ち、cwd と取り違えない
      cj=0
      case "${ctoks[0]:-}" in '(' | '{') cj=1 ;; '(cd' | '(pushd') ctoks[0]="${ctoks[0]#(}" ;; esac
      case "${ctoks[$cj]:-}" in
        cd | pushd)
          cj=$((cj + 1))
          while :; do case "${ctoks[$cj]:-}" in -- | -P | -L | -e | -@) cj=$((cj + 1)) ;; *) break ;; esac; done
          cdir="${ctoks[$cj]:-}"
          craw="$cdir"
          cdir="${cdir#[\"\']}"
          cdir="${cdir%[\"\']}"
          if [ -z "$cdir" ] || [ $((cj + 1)) -lt "${#ctoks[@]}" ]; then
            git_base="?"
          else
            case "$cdir" in
              '~' | '~/'*) git_base="${HOME}${cdir#\~}" ;;
              /*) git_base="$cdir" ;;
              # Windows のドライブ付き絶対パス（Git Bash / Cygwin のときだけ。Issue `#2018`）。引用符なしの
              # `C:\x` は bash がバックスラッシュを落として `C:x` へ cd するので、行き先を不明にする
              [A-Za-z]:\\* | [A-Za-z]:/*)
                case "${OSTYPE:-}:$craw" in
                  msys*:[A-Za-z]:/* | cygwin*:[A-Za-z]:/* | msys*:[\"\']* | cygwin*:[\"\']*) git_base="${cdir//\\//}" ;;
                  msys*:* | cygwin*:*) git_base="?" ;;
                  *) [ "$git_base" != "?" ] && git_base="${git_base}/${cdir}" ;;
                esac
                ;;
              -* | *'$'* | '~'* | *'`'*) git_base="?" ;;
              *) [ "$git_base" != "?" ] && git_base="${git_base}/${cdir}" ;;
            esac
            # 行き先が無い cd は失敗し、後続（`;` / `||` の後）は元の cwd で走る。移動した扱いにしない
            [ "$git_base" = "?" ] || [ -d "$git_base" ] || git_base="?"
          fi
          continue
          ;;
      esac
      case "$seg" in
        *git*) : ;;
        *) continue ;;
      esac
      set -f
      # shellcheck disable=SC2206 # 素朴な空白トークン化（意図的。glob は set -f で抑止）
      toks=($seg)
      set +f
      n=${#toks[@]}
      i=0
      seg_override=0
      while [ "$i" -lt "$n" ]; do
        case "${toks[$i]}" in
          # 対象 git コマンド先頭の環境代入としての解除（guard-checkout-restore.sh の
          # FF_DISCARD_UNCOMMITTED と同じ形。Bash ツールで実際に効く唯一の指定方法）
          FF_REVIEW_LOCK_OVERRIDE=1)
            seg_override=1
            i=$((i + 1))
            ;;
          [A-Za-z_]*=*) i=$((i + 1)) ;;
          env | command | sudo | nohup) i=$((i + 1)) ;;
          *) break ;;
        esac
      done
      [ "$i" -lt "$n" ] || continue
      case "${toks[$i]}" in
        git | */git) : ;;
        *) continue ;;
      esac
      i=$((i + 1))
      # -C は「どのリポジトリを触る git か」を決めるので、飛ばさずに解決する
      # （guard-checkout-restore.sh と同じ: 絶対パスはそのまま、相対は hook 入力の cwd 基準）。
      gitdir="$git_base"
      while [ "$i" -lt "$n" ]; do
        case "${toks[$i]}" in
          -C)
            i=$((i + 1))
            if [ "$i" -lt "$n" ]; then
              cdir="${toks[$i]}"
              craw="$cdir"
              case "$cdir" in
                \"*\")
                  cdir="${cdir#\"}"
                  cdir="${cdir%\"}"
                  ;;
                \'*\')
                  cdir="${cdir#\'}"
                  cdir="${cdir%\'}"
                  ;;
              esac
              case "$cdir" in
                /*) gitdir="$cdir" ;;
                # Windows のドライブ付き絶対パス（Git Bash / Cygwin のときだけ。Issue `#2018`）。引用符なしの
                # `C:\x` は bash がバックスラッシュを落とすので、行き先を不明にする
                [A-Za-z]:\\* | [A-Za-z]:/*)
                  case "${OSTYPE:-}:$craw" in
                    msys*:[A-Za-z]:/* | cygwin*:[A-Za-z]:/* | msys*:[\"\']* | cygwin*:[\"\']*) gitdir="${cdir//\\//}" ;;
                    msys*:* | cygwin*:*) gitdir="?" ;;
                    *) [ "$gitdir" = "?" ] || gitdir="$gitdir/$cdir" ;;
                  esac
                  ;;
                ?*) [ "$gitdir" = "?" ] || gitdir="$gitdir/$cdir" ;;
              esac
            fi
            i=$((i + 1))
            ;;
          -c | --git-dir | --work-tree | --namespace | --exec-path) i=$((i + 2)) ;;
          -*) i=$((i + 1)) ;;
          *) break ;;
        esac
      done
      [ "$i" -lt "$n" ] || continue
      # ロックを持つのは cwd の toplevel だけ。別リポジトリ（別 worktree・別 clone）を
      # 指す git はこのレビューの結果を壊さないので対象外。
      # 凍結の対象はツリー単位（Issue `#1760`）: 別 worktree のレビューだけが走っている間は cwd の
      # git 書き込みを止めず、`git -C <対象の worktree>` は止める。
      # 行き先が不明（`cd "$X"` の後）な git は、凍結対象のツリーが 1 つでもあれば止める側。
      # toplevel を引けない回は、そのディレクトリがどれかの対象ツリーの中にあるかで決める。
      if [ "$gitdir" = "?" ]; then
        :
      elif [ "$gitdir" != "$CWD" ]; then
        [ -d "$gitdir" ] || continue
        if seg_root="$(git -C "$gitdir" rev-parse --show-toplevel 2>/dev/null)" && [ -n "$seg_root" ]; then
          seg_root="$(phys_dir "$seg_root")"
          in_protected "$seg_root" || continue
        else
          within_protected "$(phys_dir "$gitdir")" || continue
        fi
      else
        [ "$CWD_PROTECTED" -eq 1 ] || continue
      fi
      case "${toks[$i]}" in
        commit | rebase | checkout | switch | merge | reset | apply | cherry-pick | revert | am | pull) : ;;
        stash)
          # `git stash list` / `git stash show` は read-only（既存 checkout guard の
          # 「worktree に触れない形は発火しない」線引きに倣う）
          j=$((i + 1))
          while [ "$j" -lt "$n" ]; do
            case "${toks[$j]}" in
              -*) j=$((j + 1)) ;;
              *) break ;;
            esac
          done
          if [ "$j" -lt "$n" ]; then
            case "${toks[$j]}" in
              list | show) continue ;;
            esac
          fi
          ;;
        restore)
          # `git restore --staged <path>`（--worktree / -W なし）は index だけを触る
          staged=0
          worktree=0
          j=$((i + 1))
          while [ "$j" -lt "$n" ]; do
            case "${toks[$j]}" in
              --) break ;;
              --staged | -S) staged=1 ;;
              --worktree | -W) worktree=1 ;;
            esac
            j=$((j + 1))
          done
          if [ "$staged" -eq 1 ] && [ "$worktree" -eq 0 ]; then
            continue
          fi
          ;;
        *) continue ;;
      esac
      is_write_git=1
      [ "$seg_override" -eq 1 ] && cmd_override=1
      break
    done <<EOF
$segments
EOF
    # git の書き込みでなければ、Bash 経由のファイル書き込みを走査する（Issue `#1710`）。
    is_write_bash=0
    write_note=""
    if [ "$is_write_git" -ne 1 ]; then
      ROOT_PHYS="$(phys_dir "$ROOT")"
      [ -n "$ROOT_PHYS" ] || ROOT_PHYS="$ROOT"
      write_scan_rc=1
      # shellcheck source=../tests/lib/review-write-scan.sh
      if [ -r "$WRITE_SCAN_LIB" ] && . "$WRITE_SCAN_LIB" 2>/dev/null \
        && [ "$(type -t ff_write_scan 2>/dev/null)" = "function" ]; then
        ff_write_scan_init "$ROOT_PHYS" "$(phys_dir "$CWD")" "$OUTPUT_DIR_NAME" "$PROTECT_TREES"
        ff_write_scan "$cmd" "$HEREDOC_STATE" "$HEREDOC_CODE" "$HEREDOC_BODIES"
        write_scan_rc=$?
      else
        WRITE_REASON="書き込み先を判定できません（走査ライブラリ ${WRITE_SCAN_LIB} を読めない）"
        WRITE_OVERRIDE=0
        write_scan_rc=0
      fi
      if [ "$write_scan_rc" -eq 0 ]; then
        is_write_bash=1
        [ "${WRITE_OVERRIDE:-0}" -eq 1 ] && cmd_override=1
        write_note="このコマンドは${WRITE_REASON}。判定できない書き込みは deny 側へ倒します。
下書き・一時出力は作業ツリーの外（scratchpad や \`mktemp -d\` の一時ディレクトリ）へ書いてください。レビュー出力先 ${ROOT}/${OUTPUT_DIR_NAME}/ への書き込みは止めません。
"
      fi
    fi
    [ "$is_write_git" -eq 1 ] || [ "$is_write_bash" -eq 1 ] || exit 0
    ;;
  *) exit 0 ;;
esac

# 「走行中ではない」と判断した材料は必ず出力する。A の stale ロックも C のレーン回収も、
# 起きているのは「誰にも知らせずに凍結が解ける」ことなので、**無出力で通してはいけない**。
guard_notes=""
if [ -n "$lock_stale_reason" ]; then
  guard_notes="ℹ️ ff-dev-toolkit guard（レビュー走行中ロック）: 走行中とみなせないロックが残っています（${lock_stale_reason}）。
ロックは次のレビュー実行が置き直しますが、気になる場合は削除してください: rm -- $(shq "$LOCK")
"
fi
if [ "$LANE_DONE" -gt 0 ]; then
  guard_notes="${guard_notes}ℹ️ ff-dev-toolkit guard（レビュー走行中レーン）: 委譲レビューの結果（output-file）が書かれたレーンを ${LANE_DONE} 本解放しました。
"
fi
if [ "$LANE_RECLAIMED" -gt 0 ]; then
  guard_notes="${guard_notes}ℹ️ ff-dev-toolkit guard（レビュー走行中レーン）: 寿命を過ぎた未終端のレーンを ${LANE_RECLAIMED} 本回収しました（対応づけ済み ${LANE_MAX_AGE} 秒 / 未対応づけ ${LANE_PENDING_MAX_AGE} 秒）。解放イベントを取りこぼしたレーンの自動回収で、この回収によって凍結が解けています。
レーン置き場: ${LANE_DIR}
"
fi

# PID が死んでいる / 上限より古い場合は stale。消し忘れたロックや再利用された PID で
# 以後の全編集を止めないよう、警告だけ出して通す（deny しない）。
# 生きたロック・レーンがある場合は deny 側が優先なので、警告で打ち切らず下へ進む
# （その場合 guard_notes は拒否理由へ畳み込む）。
if [ "$lock_live" -ne 1 ] && [ "$LANE_LIVE" -eq 0 ] && [ -n "$guard_notes" ]; then
  emit_message "${guard_notes}このコマンドはブロックしません。"
fi

[ "${FF_REVIEW_LOCK_OVERRIDE:-0}" = "1" ] && exit 0
[ "${cmd_override:-0}" = "1" ] && exit 0

elapsed="不明"
[ -n "$lock_elapsed_seconds" ] && elapsed="${lock_elapsed_seconds} 秒"
[ -n "$lock_head" ] || lock_head="n/a"
[ -n "$lock_task" ] || lock_task="review"
[ -n "$lock_started" ] || lock_started="n/a"

deny_head=""
if [ "$lock_live" -eq 1 ]; then
  deny_head="${lock_task} が走行中です（PID ${lock_pid}）。
  開始 SHA: ${lock_head}
  開始時刻: ${lock_started}（経過 ${elapsed}）
  観点:     ${lock_perspectives:-n/a}
"
fi
if [ "$LANE_LIVE" -gt 0 ]; then
  deny_head="${deny_head}ホストのサブエージェントによるレビューが ${LANE_LIVE} 本走行中です（未終端のレーン）。
${LANE_SUMMARY}一部のレビュアーが返ってきただけでは凍結は解けません。残っているレーンが 0 本になるまでこのガードは開きません。
  レーン置き場: ${LANE_DIR}
"
fi
if [ -n "$PROTECT_TREES" ]; then
  deny_head="${deny_head}  凍結の対象ツリー: $(printf '%s\n' "$PROTECT_TREES" | awk 'NF && !seen[$0]++' | tr '\n' ' ')（これらの外への書き込みは止めません）
"
fi
if [ -n "$lock_stale_reason" ]; then
  deny_head="${deny_head}（あわせて、走行中とみなせない古いロックが残っています: ${lock_stale_reason}）
"
fi
if [ "$LANE_RECLAIMED" -gt 0 ]; then
  deny_head="${deny_head}（あわせて、寿命を過ぎた未終端のレーンを ${LANE_RECLAIMED} 本回収しました）
"
fi

emit_deny "⚠️ ff-dev-toolkit guard（レビュー走行中・作業ツリー編集の抑止）: ${deny_head}${write_note:-}走行中に作業ツリーが動くと、実行後のリビジョン検証が結果を**全破棄**します（数分〜十数分ぶんのレビューが失われます）。サブエージェント経路には破棄の機構が無い代わりに、走行中の編集は「レビュー対象と食い違う指摘」を生みます。完了通知が出るまで編集・commit・checkout をしないでください。
待ち時間にできることは multi-review スキルの「レビュー待ち時間の使い方」節を参照してください。
続行する必要がある場合（走行が既に終わっている / 結果の破棄を承知で編集する）:
  1) ツール非依存の復旧: ロックを消す → rm -- $(shq "$LOCK")
     サブエージェントのレーンを消す → rm -rf -- $(shq "$LANE_DIR")
     （どのツールからでも効きます。次のレビュー実行がロックを置き直します。レーンは
     対応づけ済みで ${LANE_MAX_AGE} 秒・未対応づけで ${LANE_PENDING_MAX_AGE} 秒を過ぎると
     走査時に自動で回収されるので、放置しても凍結は永続しません）
  2) Bash ツールで実行するコマンドに限り、対象のコマンド（区間）の先頭に環境代入を付ける
     → FF_REVIEW_LOCK_OVERRIDE=1 git ... / FF_REVIEW_LOCK_OVERRIDE=1 tee ...
     Edit / Write などの編集系ツールにはコマンド行が無く、hook はセッションの環境変数を
     継承するだけなので、この変数はセッションを再起動せずには変えられません。編集系を
     通したいときは 1) を使ってください。
このガードを止める場合は環境変数 FF_DEV_TOOLKIT_SKIP_REVIEW_IN_FLIGHT_GUARD=1 を設定します
（同じくセッション環境。非対話実行での opt-out はこちら）。"
