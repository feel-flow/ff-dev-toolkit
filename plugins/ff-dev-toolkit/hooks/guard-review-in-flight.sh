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
#   10 秒 timeout に見合わないため、既定パスに限る線引きを採る。
#
# 判定の限界（既知）:
#   - PID 再利用: ロックに書かれた PID が別プロセスへ再利用されると、生存判定だけでは
#     走行中と区別できない。緩和として、ロックの `started_epoch` からの経過が
#     FF_REVIEW_LOCK_MAX_AGE_SECONDS（既定 14400 秒 = 4 時間。multi-agent のタスク上限
#     900 秒 × 観点数を十分に超える）を超えたロックは、PID が生きていても stale として
#     扱い、警告だけ出して通す。上限より前に PID が再利用された場合は取りこぼす
#     （deny 側へ倒れるだけで、`rm <ロック>` で即復旧できる）。
#   - Bash コマンドの解析は素朴な空白トークン化で、引用文字列の中までは解かない
#     （`sh -c 'git commit ...'` のような形は判定が曖昧になる）。heredoc 本文だけは
#     明示的に判定対象から外している。
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
#   - Bash 経由の書き込み全般（`sed -i` / リダイレクト / `cp` / `mv` / `rm` / `tee` /
#     `python -c` 等）。これは意図的な線引きで、拡張しない — scratchpad への書き出しなど
#     偽陽性が多く、bypass ハーネスの常用経路（レビュー待ちの下書き作成など）ごと
#     止めてしまう。git の書き込み系サブコマンドと編集系ツールだけを対象にする
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
#     共有しないので凍結の前提が無い（git-workflow の「ステップ5」が正本）。ここでレーンを
#     取ると、隔離 worktree の中で変異注入を行うレビュアーが**自分のロックで自分の編集を
#     止める**（自己デッドロック）。
#   - 名簿（FF_REVIEW_SUBAGENT_LOCK_TYPES）に無い subagent。既定は pr-review-toolkit の
#     **read-only な**レビュアーだけで、共有ツリーを編集する前提の `code-simplifier` は
#     同じ自己デッドロックを避けるため名簿から外してある。
#   - `Agent` / `Task` の `PreToolUse` が来ない状況（イベントが来なければ何も起きない
#     = fail-open）。
#   - レーン置き場（`.review-results/` とその下の `.review-in-flight.d/`）が symlink である
#     か、物理パスがリポジトリの外を指す場合。走査は上限を超えたレーンを**削除する**ので、
#     検証できない置き場では取得・走査・解放のすべてを行わない（素通し）。
#   - **名簿の型で動いているサブエージェント自身の編集**（deny しない側の非適用）。
#     詳細は本体の「レビュアー自身の編集は止めない」節。
#
# 設計原則:
#   - fail-open: 解析不能・jq 不在・git 外・壊れた stdin では黙って許可
#     （exit 0・無出力）。ガードとしての取りこぼしは許容し、誤ブロックだけを避ける
#   - 互換性: bash 3.2（stock macOS）互換。連想配列・readarray・=~ は使わない
#
# 環境変数:
#   FF_REVIEW_LOCK_OVERRIDE=1                     A（走行中ロック）と C（レーン）の deny を解除する。
#                                                 Bash ツール
#                                                 なら対象 git コマンド先頭の環境代入としても効く
#                                                 （`FF_REVIEW_LOCK_OVERRIDE=1 git commit ...`）。
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
#   FF_DEV_TOOLKIT_SKIP_REVIEW_IN_FLIGHT_GUARD=1  この hook 全体を無効化する。`claude -p` /
#                                                 background / subagent など非対話実行では
#                                                 permissionDecision "ask" が block 相当になるため、
#                                                 レビュー起動を自動化する場面ではこれを設定する

# fail-open のため set -e / set -u は使わない。

# stdin は bash 組み込みの read で読み切る（外部コマンドに依存しない）。`cat` だと PATH が
# 空・壊れた環境で command not found → stdin 未読のまま exit 0 となり、書き手（ホスト）が
# EPIPE / SIGPIPE を受ける（既存 2 ガードと同じ修正）。opt-out も
# stdin を読み切ってから抜ける。-d '' は EOF で非 0 を返すが input には内容が入っている。
input=""
IFS= read -r -d '' input || true

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
[ -d "$CWD" ] || CWD="$(pwd)"

command -v git >/dev/null 2>&1 || exit 0
ROOT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -n "$ROOT" ] && [ -d "$ROOT" ] || exit 0

emit_deny() { # <reason>
  jq -n --arg reason "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}' 2>/dev/null
  exit 0
}

emit_ask() { # <reason>
  jq -n --arg reason "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "ask", permissionDecisionReason: $reason}}' 2>/dev/null
  exit 0
}

emit_message() { # <text>
  jq -n --arg m "$1" '{systemMessage: $m}' 2>/dev/null
  exit 0
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

# 復旧案内に出すパスは、そのまま貼って実行できる形にする。単一引用で包み、内側の
# 引用符も壊れない形へ落とす（リポジトリのパスに空白・glob・引用符が入りうる）。
shq() { # <文字列> → シェルの単一引用語
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# レーン置き場の物理パス検査。`.review-results/` やレーン置き場が**外部を指す symlink**
# だと、走査（= 上限超過レーンの削除）がリポジトリ外のファイルを消しうる。symlink を拒否し、
# 物理パスが ROOT 配下であることを確かめるまで C は一切動かさない（取らない・数えない・
# 消さない）。検査に失敗しても**起動は止めない** — C は追加の防御層という位置づけなので、
# 安全に記帳できないときは素通しへ倒す。
LANE_SAFE=0
lane_dir_is_safe() {
  local out_dir root_phys phys
  out_dir="${ROOT}/${OUTPUT_DIR_NAME}"
  [ -L "$out_dir" ] && return 1
  [ -L "$LANE_DIR" ] && return 1
  root_phys="$(cd "$ROOT" 2>/dev/null && pwd -P 2>/dev/null)" || return 1
  [ -n "$root_phys" ] || return 1
  if [ -e "$out_dir" ]; then
    [ -d "$out_dir" ] || return 1
    phys="$(cd "$out_dir" 2>/dev/null && pwd -P 2>/dev/null)" || return 1
    case "$phys" in
      "$root_phys"/*) : ;;
      *) return 1 ;;
    esac
  fi
  if [ -e "$LANE_DIR" ]; then
    [ -d "$LANE_DIR" ] || return 1
    phys="$(cd "$LANE_DIR" 2>/dev/null && pwd -P 2>/dev/null)" || return 1
    case "$phys" in
      "$root_phys"/*) : ;;
      *) return 1 ;;
    esac
  fi
  return 0
}
lane_dir_is_safe && LANE_SAFE=1

lane_field() { # <レーンのパス> <キー>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1
}

sanitize_id() { # <文字列> → ファイル名に使える形
  printf '%s' "$1" | tr -dc 'A-Za-z0-9_-' 2>/dev/null
}

is_review_lock_type() { # <subagent_type>
  [ -n "$1" ] || return 1
  set -f
  for _pat in $REVIEW_LOCK_TYPES; do
    # shellcheck disable=SC2254 # 名簿は glob パターン（意図的に展開する。glob は set -f で抑止済み）
    case "$1" in
      $_pat)
        set +f
        return 0
        ;;
    esac
  done
  set +f
  return 1
}

# レーン名の鍵。`tool_use_id` は PreToolUse と PermissionDenied の両方に載るので、
# 起動と「起動しなかった」を同じ鍵で対応づけられる。無い版のハーネスでは
# tool_input の内容から決定的な鍵を作る。
lane_key() {
  local k
  k="$(printf '%s' "$input" | jq -r '.tool_use_id // ""' 2>/dev/null | tr -dc 'A-Za-z0-9_-' 2>/dev/null)"
  if [ -n "$k" ]; then
    printf '%s' "$k"
    return 0
  fi
  k="$(printf '%s' "$input" \
    | jq -r '(.tool_input // {}) | [(.subagent_type // ""), (.description // ""), (.prompt // "")] | @json' 2>/dev/null \
    | cksum 2>/dev/null | awk '{ print "h" $1 "-" $2 }' 2>/dev/null)"
  case "$k" in
    h[0-9]*) printf '%s' "$k" ;;
    *) : ;;
  esac
}

# ── C) レーンの取得・対応づけ・解放・走査 ─────────────────────────────────
LANE_LIVE=0
LANE_SUMMARY=""
LANE_RECLAIMED=0

acquire_lane() { # <subagent_type>
  local key head_sha now f tmp existing lane_body
  [ "$LANE_SAFE" -eq 1 ] || return 0
  key="$(lane_key)"
  [ -n "$key" ] || return 0
  mkdir -p "$LANE_DIR" 2>/dev/null || return 0
  # mkdir 後にもう一度見る（作った先が symlink 越しでないこと）。
  lane_dir_is_safe || return 0
  # **鍵に対して冪等**にする。ハーネスには同じ `tool_use_id` で PreToolUse をもう一度流す
  # 再試行経路がある（auto mode の拒否に対して hook が `retry: true` を返す形）。冪等で
  # ないと 1 回の起動で 2 本開き、解放イベント 1 回では 1 本しか閉じずに残りが寿命まで
  # 凍結を維持する。
  for existing in "$LANE_DIR/$key".*.lane; do
    [ -f "$existing" ] && return 0
  done
  now="$(date -u +%s 2>/dev/null)"
  case "$now" in
    '' | *[!0-9]*) return 0 ;;
  esac
  head_sha="$(git -C "$ROOT" rev-parse --short=12 HEAD 2>/dev/null)"
  [ -n "$head_sha" ] || head_sha="n/a"
  f="${LANE_DIR}/${key}.${now}.$$.lane"
  tmp="${f}.tmp.$$"
  # 書けなくても起動は止めない（A と同じく、これは追加の防御層）。
  # `pid` ではなく `writer_pid` なのは意味が違うため: A の `pid` は「その PID が生きている
  # 間はロックが生きている」の判定材料だが、hook はすぐ死ぬ短命プロセスなので、レーンの
  # 生存判定には使えない（使うと即 stale になりガードが 1 度も効かない）。レーンの生死は
  # 「ファイルが在るか」と「経過が上限内か」だけで決める。
  # `agent_id` は空で置き、`SubagentStart` が来た時点で書き込む（以後の解放はその id で
  # 対応づける）。最終パスへ直接書かず、同一ディレクトリの一時ファイルへ書き切ってから
  # rename で公開する — 並行する走査が書込み途中のレーン（`started_epoch` 未書込み）を
  # 不正とみなして削除するのを防ぐ。
  lane_body="$(printf 'writer_pid=%s\ntask=%s\nhead=%s\nstarted=%s\nstarted_epoch=%s\nperspectives=%s\nagent_id=' \
    "$$" "subagent-review" "$head_sha" "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" "$now" "$1")"
  printf '%s\n' "$lane_body" > "$tmp" 2>/dev/null || {
    # 置き場が外から消された場合の 1 回だけの作り直し。
    mkdir -p "$LANE_DIR" 2>/dev/null
    printf '%s\n' "$lane_body" > "$tmp" 2>/dev/null || {
      rm -f "$tmp" 2>/dev/null
      return 0
    }
  }
  mv "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}

# `SubagentStart` で agent_id をレーンへ書き込む（対応づけ）。ここでレーンを**新設はしない** —
# レーンを取るかどうかの判定材料（`isolation` / `subagent_type`）は `PreToolUse` にしか無く、
# `SubagentStart` のペイロードには載らないため（claude 2.1.267 の同梱実装で確認）。
adopt_lane() { # <agent_id（sanitize 済み）> <agent_type>
  local f t a e best best_e body tmp claimed tries
  [ "$LANE_SAFE" -eq 1 ] || return 0
  [ -n "$1" ] || return 0
  [ -n "$2" ] || return 0
  [ -d "$LANE_DIR" ] || return 0
  tries=0
  while [ "$tries" -lt 5 ]; do
    tries=$((tries + 1))
    best=""
    best_e=""
    for f in "$LANE_DIR"/*.lane; do
      [ -f "$f" ] || continue
      t="$(lane_field "$f" perspectives)"
      [ "$t" = "$2" ] || continue
      a="$(lane_field "$f" agent_id)"
      [ -z "$a" ] || continue
      e="$(lane_field "$f" started_epoch)"
      case "$e" in
        '' | *[!0-9]*) e=0 ;;
      esac
      if [ -z "$best" ] || [ "$e" -lt "$best_e" ]; then
        best="$f"
        best_e="$e"
      fi
    done
    [ -n "$best" ] || return 0
    # 中身を先に作ってから rename 2 回で差し替える（レーンが見えない窓を rename 1 回ぶんに
    # 縮める）。claim の rename に負けた側は再走査して別のレーンを取る。
    body="$(sed 's/^agent_id=.*$/agent_id='"$1"'/' "$best" 2>/dev/null)"
    [ -n "$body" ] || return 0
    tmp="${best}.tmp.$$"
    printf '%s\n' "$body" > "$tmp" 2>/dev/null || {
      rm -f "$tmp" 2>/dev/null
      return 0
    }
    claimed="${best}.claim.$$"
    if ! mv "$best" "$claimed" 2>/dev/null; then
      rm -f "$tmp" 2>/dev/null
      continue
    fi
    mv "$tmp" "$best" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    rm -f "$claimed" 2>/dev/null
    return 0
  done
  return 0
}

lane_tombstone() { # <パス（空なら何もしない）>
  local now
  [ -n "$1" ] || return 0
  now="$(date -u +%s 2>/dev/null)"
  case "$now" in
    '' | *[!0-9]*) now=0 ;;
  esac
  printf 'started_epoch=%s\n' "$now" > "$1" 2>/dev/null || true
  return 0
}

# `SubagentStop` の解放。**agent_id で対応づける**のが本体で、同型の最古 1 本という
# 弱い対応づけは「対応づいていないレーンしか無い」場合のフォールバックにだけ残す。
release_lane_by_agent() { # <agent_id> <agent_type>
  local id type f a t e best best_e claimed tomb tries
  [ "$LANE_SAFE" -eq 1 ] || return 0
  type="$2"
  [ -n "$type" ] || return 0
  [ -d "$LANE_DIR" ] || return 0
  id="$(sanitize_id "$1")"
  tomb=""
  if [ -n "$id" ]; then
    tomb="${LANE_DIR}/.done.${id}"
    # **同じ agent_id の 2 回目以降は no-op**。`SubagentStop` はサブエージェントが 1 回
    # 応答を終えるたびに発火するので、`SendMessage` で継続された 1 本のレビュアーが
    # 複数回終端イベントを出す。これが無いと、その 1 本がまだ走っている別のレビュアーの
    # レーンまで削り、部分完了で凍結が解ける。
    [ -f "$tomb" ] && return 0
  fi
  tries=0
  while [ "$tries" -lt 5 ]; do
    tries=$((tries + 1))
    best=""
    best_e=""
    # 1) agent_id が一致するレーン（`SubagentStart` で対応づけ済み）
    if [ -n "$id" ]; then
      for f in "$LANE_DIR"/*.lane; do
        [ -f "$f" ] || continue
        a="$(lane_field "$f" agent_id)"
        [ "$a" = "$id" ] || continue
        best="$f"
        break
      done
    fi
    # 2) 対応づいていないレーンだけを、同型の最も古い 1 本として引き受ける
    #    （`SubagentStart` を出さない版・対応づけの取りこぼし用のフォールバック）。
    #    対応づけ済みのレーンは**決して奪わない** — 走行中の別レビュアーのぶんだから。
    if [ -z "$best" ]; then
      for f in "$LANE_DIR"/*.lane; do
        [ -f "$f" ] || continue
        t="$(lane_field "$f" perspectives)"
        [ "$t" = "$type" ] || continue
        a="$(lane_field "$f" agent_id)"
        [ -z "$a" ] || continue
        e="$(lane_field "$f" started_epoch)"
        case "$e" in
          '' | *[!0-9]*) e=0 ;;
        esac
        if [ -z "$best" ] || [ "$e" -lt "$best_e" ]; then
          best="$f"
          best_e="$e"
        fi
      done
    fi
    [ -n "$best" ] || break
    # 「選択 → 削除」を rename で直列化する。同型の `SubagentStop` が同時に来ても
    # 同じレーンを 2 回は取れない（負けた側は再走査して別のレーンを取る）。
    claimed="${best}.claim.$$"
    mv "$best" "$claimed" 2>/dev/null || continue
    rm -f "$claimed" 2>/dev/null
    lane_tombstone "$tomb"
    break
  done
  return 0
}

# 鍵が一致し、かつ**まだ対応づいていない**レーンを 1 本だけ閉じる（`PermissionDenied` 用）。
# 対応づけ済み = サブエージェントは実際に起動しているので、拒否イベントで閉じてはいけない。
release_lane_by_key() {
  local key f a found claimed tries
  [ "$LANE_SAFE" -eq 1 ] || return 0
  key="$(lane_key)"
  [ -n "$key" ] || return 0
  [ -d "$LANE_DIR" ] || return 0
  tries=0
  while [ "$tries" -lt 5 ]; do
    tries=$((tries + 1))
    found=""
    for f in "$LANE_DIR/$key".*.lane; do
      [ -f "$f" ] || continue
      a="$(lane_field "$f" agent_id)"
      [ -z "$a" ] || continue
      found="$f"
      break
    done
    [ -n "$found" ] || break
    claimed="${found}.claim.$$"
    mv "$found" "$claimed" 2>/dev/null || continue
    rm -f "$claimed" 2>/dev/null
    break
  done
  return 0
}

# 走行中のレーンを数える。上限より古い（または未来へ大きくずれた）レーンはその場で
# 削除する — 解放イベントを取りこぼしても凍結が永続しないための出口。**回収したことは
# 黙って済ませない**（LANE_RECLAIMED を立て、呼び出し側が systemMessage を出す）。
scan_lanes() {
  local f e t a now age limit
  [ "$LANE_SAFE" -eq 1 ] || return 0
  [ -d "$LANE_DIR" ] || return 0
  now="$(date -u +%s 2>/dev/null)"
  case "$now" in
    '' | *[!0-9]*) return 0 ;;
  esac
  for f in "$LANE_DIR"/*.lane; do
    [ -f "$f" ] || continue
    e="$(lane_field "$f" started_epoch)"
    case "$e" in
      '' | *[!0-9]*)
        rm -f "$f" 2>/dev/null
        LANE_RECLAIMED=$((LANE_RECLAIMED + 1))
        continue
        ;;
    esac
    a="$(lane_field "$f" agent_id)"
    limit="$LANE_MAX_AGE"
    if [ -z "$a" ] && [ "$LANE_PENDING_MAX_AGE" -lt "$LANE_MAX_AGE" ]; then
      limit="$LANE_PENDING_MAX_AGE"
    fi
    age=$((now - e))
    if [ "$age" -gt "$limit" ] || [ "$age" -lt -300 ]; then
      rm -f "$f" 2>/dev/null
      LANE_RECLAIMED=$((LANE_RECLAIMED + 1))
      continue
    fi
    t="$(lane_field "$f" perspectives)"
    LANE_LIVE=$((LANE_LIVE + 1))
    LANE_SUMMARY="${LANE_SUMMARY}  - ${t:-unknown}（経過 ${age} 秒${a:+ / 対応づけ済み}）
"
  done
  # 中断された claim / tmp と、解放済み agent_id の記録も同じ上限で片づける。
  # `started_epoch` が読めないものは**残す** — 書込み途中の tmp を消すと、書き手の
  # rename が失敗してレーンが 1 本も立たなくなる（atomic publish が壊れる）。
  for f in "$LANE_DIR"/*.claim.* "$LANE_DIR"/*.tmp.* "$LANE_DIR"/.done.*; do
    [ -f "$f" ] || continue
    e="$(lane_field "$f" started_epoch)"
    case "$e" in
      '' | *[!0-9]*) continue ;;
    esac
    [ "$((now - e))" -gt "$LANE_MAX_AGE" ] && rm -f "$f" 2>/dev/null
  done
  # **空になっても LANE_DIR は rmdir しない。** 消すと、同時に走る acquire_lane が
  # mkdir 済みのはずの置き場を失い、一時ファイルを作れずにレーンを落とす（同時取得を
  # 走らせて実測した）。空ディレクトリは git の追跡対象にならず、dirty 判定からも
  # pathspec で外してあるので、残しておく害は無い。
  return 0
}

# ── C の対応づけ / 解放イベント（ここで終わる入口。permissionDecision は出さない） ──
if [ "$EVENT" = "SubagentStart" ]; then
  agent_type="$(printf '%s' "$input" | jq -r '.agent_type // ""' 2>/dev/null)"
  agent_id="$(printf '%s' "$input" | jq -r '.agent_id // ""' 2>/dev/null)"
  is_review_lock_type "$agent_type" && adopt_lane "$(sanitize_id "$agent_id")" "$agent_type"
  exit 0
fi

if [ "$EVENT" = "SubagentStop" ]; then
  agent_type="$(printf '%s' "$input" | jq -r '.agent_type // ""' 2>/dev/null)"
  agent_id="$(printf '%s' "$input" | jq -r '.agent_id // ""' 2>/dev/null)"
  # 名簿外のサブエージェントはレーンを取っていないので、閉じるものも無い。
  is_review_lock_type "$agent_type" && release_lane_by_agent "$agent_id" "$agent_type"
  exit 0
fi

if [ "$EVENT" = "PermissionDenied" ]; then
  case "$tool" in
    Agent | Task) : ;;
    *) exit 0 ;;
  esac
  subagent_denied="$(printf '%s' "$input" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null)"
  is_review_lock_type "$subagent_denied" && release_lane_by_key
  exit 0
fi

# 読み取り側（A・B・C の判定）は PreToolUse だけが使う。

lock_field() { # <key>
  sed -n "s/^$1=//p" "$LOCK" 2>/dev/null | head -n 1
}

lock_pid=""
lock_head=""
lock_started=""
lock_started_epoch=""
lock_task=""
lock_perspectives=""
lock_elapsed_seconds=""
lock_live=0          # 1 = 走行中とみなす
lock_stale_reason="" # 非空 = ロックはあるが走行中とみなさない理由

LOCK_MAX_AGE="${FF_REVIEW_LOCK_MAX_AGE_SECONDS:-14400}"
case "$LOCK_MAX_AGE" in
  '' | *[!0-9]*) LOCK_MAX_AGE=14400 ;;
esac

if [ -f "$LOCK" ]; then
  lock_pid="$(lock_field pid)"
  lock_head="$(lock_field head)"
  lock_started="$(lock_field started)"
  lock_started_epoch="$(lock_field started_epoch)"
  lock_task="$(lock_field task)"
  lock_perspectives="$(lock_field perspectives)"
  # PID を読めないロックは判定材料が無い（fail-open）
  case "$lock_pid" in
    '' | *[!0-9]*) lock_pid="" ;;
  esac
  if [ -n "$lock_pid" ]; then
    now_epoch="$(date -u +%s 2>/dev/null)"
    case "$lock_started_epoch" in
      '' | *[!0-9]*) : ;;
      *)
        case "$now_epoch" in
          '' | *[!0-9]*) : ;;
          *) lock_elapsed_seconds="$((now_epoch - lock_started_epoch))" ;;
        esac
        ;;
    esac
    if ! kill -0 "$lock_pid" 2>/dev/null; then
      lock_stale_reason="PID ${lock_pid} は生存していません"
    elif [ -n "$lock_elapsed_seconds" ] && [ "$lock_elapsed_seconds" -gt "$LOCK_MAX_AGE" ]; then
      # PID 再利用対策: 走行が終わったあとに PID が別プロセスへ再利用されると kill -0 は
      # 通ってしまう。上限より古いロックは「走行中ではない」側へ倒す（警告のみ）。
      lock_stale_reason="開始から ${lock_elapsed_seconds} 秒が経過しています（上限 ${LOCK_MAX_AGE} 秒。PID ${lock_pid} は生存していますが、再利用された PID の可能性があります）"
    else
      lock_live=1
    fi
  fi
fi

# C のレーンを数える（A のロックを読んだあと・B の判定より前）。ここで数えた本数は
# 「この呼び出しより前に開いたレーン」だけで、下で自分が取るレーンは含まない。
scan_lanes

# ── B) レビューエージェント起動時の dirty ガード（+ C のレーン取得） ────────
if [ "$tool" = "Agent" ] || [ "$tool" = "Task" ]; then
  subagent="$(printf '%s' "$input" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null)" || exit 0
  # 入力に subagent_type が無い版のハーネスは判定材料が無い（fail-open）
  [ -n "$subagent" ] || exit 0
  isolation="$(printf '%s' "$input" | jq -r '.tool_input.isolation // ""' 2>/dev/null)"
  # C) レーンの取得は**何よりも先**に置く。この hook の timeout は 10 秒で、`git status` は
  # 大きい・遅いリポジトリでそれを使い切りうる。取得より先に status を読むと、timeout した
  # 回はレーンを 1 本も作らないままレビューが起動してしまう（ガードが最初から居ない）。
  # 取得は数え上げ（scan_lanes）より後なので、自分の記帳を自分で数えることにはならない。
  if is_review_lock_type "$subagent"; then
    case "$isolation" in
      # 隔離起動のレビュアーは親と作業ツリーを共有しないので凍結の対象外
      # （加えて、隔離 worktree 内で変異注入を行うレビュアーの自己デッドロックを避ける）
      worktree) : ;;
      *) acquire_lane "$subagent" ;;
    esac
  fi
  case "$subagent" in
    pr-review-toolkit:*) : ;;
    *) exit 0 ;;
  esac
  # ignored な成果物は porcelain の出力に出ないので、そのまま判定に使える。
  # レビュー出力先（C のレーン置き場を含む）だけは pathspec で外す — 外さないと
  # hook 自身が置いたレーンで dirty が立ち、以後の起動が毎回 ask になる（自分の記帳で
  # 自分のガードを誤爆させる形）。除外の線引きは multi-agent.sh の凍結スナップショットが
  # 出力先を監視から外しているのと同じで、利用者が出力先を gitignore しているかに依らない。
  dirty=""
  dirty_rc=0
  dirty="$(git -C "$ROOT" status --porcelain -- . ":(exclude)${OUTPUT_DIR_NAME}" 2>/dev/null)" || dirty_rc=1
  # `git status` が読めなかった回は **fail-open**（無音で通す）。B が守っているのは
  # 「dirty かどうかを利用者に見せて選ばせる」ことなので、dirty かどうかを読めないまま
  # ask を出すと、判定材料が無い確認を毎回押し付けることになる。C のレーンは上で既に
  # 取ってあるので、この fail-open は走行中ガードの効きには影響しない。
  [ "$dirty_rc" -eq 0 ] || exit 0
  [ -n "$dirty" ] || exit 0
  changed="$(printf '%s\n' "$dirty" | grep -c . 2>/dev/null | tr -d '[:space:]')"
  case "$changed" in
    '' | *[!0-9]*) changed="?" ;;
  esac
  # 走行中なら「今まさに別のレビューが走っている」ことを先頭で伝える。dirty かどうかより
  # 優先度が高い情報で、これを知らずに 2 本目を起動すると 1 本目の待ち時間が無駄になる。
  lock_note=""
  if [ "$lock_live" -eq 1 ]; then
    lock_note="⏳ レビュー走行中です（${lock_task:-review} / 開始 SHA ${lock_head:-n/a} / 経過 ${lock_elapsed_seconds:-不明} 秒）。この起動は走行中の実行とは別物です。
"
  fi
  if [ "$LANE_LIVE" -gt 0 ]; then
    lock_note="${lock_note}⏳ ホストのサブエージェントによるレビューが ${LANE_LIVE} 本走行中です（未終端のレーン）。
"
  fi
  emit_ask "${lock_note}⚠️ ff-dev-toolkit guard（レビュー起動時の dirty 検査）: 作業ツリーに未コミットの変更が ${changed} 件あります（${ROOT}）。
レビューエージェントは git diff <base>...HEAD を見るので、未コミットの修正は無いものとして扱われます。1 回転目の指摘に対応した fix が未コミットのままだと、その指摘は「未解消」と判定され、解消済みかどうかの確認に 1 往復ぶん余計にかかります。
先にコミットしてから起動するか、この状態で起動するのが意図どおりならそのまま続行してください（レビュー待ち時間の使い方は multi-review スキルの「レビュー待ち時間の使い方」節を参照）。
このガードを止める場合は環境変数 FF_DEV_TOOLKIT_SKIP_REVIEW_IN_FLIGHT_GUARD=1 を設定します。"
fi

# ── A / C) 走行中ロック（orchestrator のロックと、サブエージェントのレーン） ──
# レビュアー自身の編集は、自分のレーンで止めない。名簿の型はハーネスの agent 一覧上
# 「全ツール」を持ち、編集系の判定にパス条件が無いので、この除外が無いとレビュアーの
# scratchpad への一時ファイル書き出しが**自分の起動で開いたレーン**に deny される。しかも
# 拒否理由はレーン置き場の `rm -rf` を案内するので、凍結の抜け道を凍結の対象者へ手渡す形に
# なる（`rm` は Bash 側の deny 対象外）。呼び出し元の `agent_type` は PreToolUse の
# ペイロードに載る（claude 2.1.267 の同梱実装で確認: hook 入力の共通部が
# `agent_id` / `agent_type` を持ち、`PreToolUse` はそこへ tool 情報を足した形）。
caller_agent_type="$(printf '%s' "$input" | jq -r '.agent_type // ""' 2>/dev/null)"
is_review_lock_type "$caller_agent_type" && exit 0

# 走行中とみなせる材料が 1 つも無ければ従来どおり無音で通す。stale なロックが残って
# いるだけの場合と、この呼び出しでレーンを回収した場合は、下で警告のみを出す経路へ進む。
if [ "$lock_live" -ne 1 ] && [ "$LANE_LIVE" -eq 0 ] && [ -z "$lock_stale_reason" ] \
  && [ "$LANE_RECLAIMED" -eq 0 ]; then
  exit 0
fi

# 対象ツールの絞り込み（ロックがあるときだけ払うコスト）
case "$tool" in
  Edit | Write | MultiEdit | NotebookEdit) : ;;
  Bash)
    cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)" || exit 0
    [ -n "$cmd" ] || exit 0
    case "$cmd" in
      *git*) : ;;
      *) exit 0 ;;
    esac
    # heredoc 本文（`<<` / `<<-` のトークン以降、終端行まで）は実行されるコマンドでは
    # なくデータなので、判定対象から落とす。`cat <<'EOF' > notes.md` の本文に
    # `git commit -m x` と書いただけで deny すると、レビュー待ちのメモ書きが止まる。
    # 解析に失敗したら元のコマンドへ倒す（deny 側だが復旧手段は deny 文に出る）。
    code_only="$(printf '%s\n' "$cmd" | awk '
      function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
      BEGIN {
        q = sprintf("%c", 39)
        re = "<<-?[ \t]*(\"[^\"]*\"|" q "[^" q "]*" q "|[A-Za-z_][A-Za-z0-9_]*)"
        nd = 0
      }
      {
        if (nd > 0) {
          if (trim($0) == d[1]) { for (i = 1; i < nd; i++) d[i] = d[i + 1]; nd-- }
          next
        }
        scan = $0
        gsub(/<<</, "___", scan) # here-string は heredoc ではない（長さを保つ置換）
        pos = 1
        while (match(substr(scan, pos), re)) {
          st = pos + RSTART - 1
          tok = substr(scan, st, RLENGTH)
          sub(/^<<-?[ \t]*/, "", tok)
          gsub("[\"" q "]", "", tok)
          nd++
          d[nd] = tok
          pos = st + RLENGTH
        }
        print
      }
    ' 2>/dev/null)" || code_only="$cmd"
    [ -n "$code_only" ] || exit 0
    case "$code_only" in
      *git*) : ;;
      *) exit 0 ;;
    esac
    # git が「コマンド位置」にあり、かつ書き込み系サブコマンドを取る形だけを対象に
    # する（`echo git commit ...` のような文字列出力は対象外）。連結演算子で分割し、
    # 先頭の環境代入・ラッパー・git のグローバルオプションを剥がしてから判定する。
    # 分割過多は「git がコマンド位置に来ず非発火」に倒れるだけで誤ブロックにならない。
    is_write_git=0
    cmd_override=0
    segments="$(printf '%s\n' "$code_only" | awk '{ gsub(/&&|\|\||;|\|/, "\n"); print }')"
    while IFS= read -r seg; do
      [ -n "$seg" ] || continue
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
      gitdir="$CWD"
      while [ "$i" -lt "$n" ]; do
        case "${toks[$i]}" in
          -C)
            i=$((i + 1))
            if [ "$i" -lt "$n" ]; then
              cdir="${toks[$i]}"
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
                ?*) gitdir="$gitdir/$cdir" ;;
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
      if [ "$gitdir" != "$CWD" ]; then
        [ -d "$gitdir" ] || continue
        seg_root="$(git -C "$gitdir" rev-parse --show-toplevel 2>/dev/null)" || continue
        [ "$seg_root" = "$ROOT" ] || continue
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
    [ "$is_write_git" -eq 1 ] || exit 0
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
if [ -n "$lock_stale_reason" ]; then
  deny_head="${deny_head}（あわせて、走行中とみなせない古いロックが残っています: ${lock_stale_reason}）
"
fi
if [ "$LANE_RECLAIMED" -gt 0 ]; then
  deny_head="${deny_head}（あわせて、寿命を過ぎた未終端のレーンを ${LANE_RECLAIMED} 本回収しました）
"
fi

emit_deny "⚠️ ff-dev-toolkit guard（レビュー走行中・作業ツリー編集の抑止）: ${deny_head}走行中に作業ツリーが動くと、実行後のリビジョン検証が結果を**全破棄**します（数分〜十数分ぶんのレビューが失われます）。サブエージェント経路には破棄の機構が無い代わりに、走行中の編集は「レビュー対象と食い違う指摘」を生みます。完了通知が出るまで編集・commit・checkout をしないでください。
待ち時間にできることは multi-review スキルの「レビュー待ち時間の使い方」節を参照してください。
続行する必要がある場合（走行が既に終わっている / 結果の破棄を承知で編集する）:
  1) ツール非依存の復旧: ロックを消す → rm -- $(shq "$LOCK")
     サブエージェントのレーンを消す → rm -rf -- $(shq "$LANE_DIR")
     （どのツールからでも効きます。次のレビュー実行がロックを置き直します。レーンは
     対応づけ済みで ${LANE_MAX_AGE} 秒・未対応づけで ${LANE_PENDING_MAX_AGE} 秒を過ぎると
     走査時に自動で回収されるので、放置しても凍結は永続しません）
  2) Bash ツールで実行するコマンドに限り、対象の git コマンド先頭に環境代入を付ける
     → FF_REVIEW_LOCK_OVERRIDE=1 git ...
     Edit / Write などの編集系ツールにはコマンド行が無く、hook はセッションの環境変数を
     継承するだけなので、この変数はセッションを再起動せずには変えられません。編集系を
     通したいときは 1) を使ってください。
このガードを止める場合は環境変数 FF_DEV_TOOLKIT_SKIP_REVIEW_IN_FLIGHT_GUARD=1 を設定します
（同じくセッション環境。非対話実行での opt-out はこちら）。"
