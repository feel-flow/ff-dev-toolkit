#!/usr/bin/env bash

# ASDD 2.0: disabled optional hooks do not prompt, block, or mutate.
if ! source "${BASH_SOURCE[0]%/*}/asdd-hook-gate.sh"; then
  echo 'ff-dev-toolkit: ASDD Hook helper is unavailable; optional hook skipped' >&2
  exit 0
fi
asdd_hook_enabled hooks || exit 0
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
# 設計原則:
#   - fail-open: 解析不能・jq 不在・git 外・壊れた stdin では黙って許可
#     （exit 0・無出力）。ガードとしての取りこぼしは許容し、誤ブロックだけを避ける
#   - 互換性: bash 3.2（stock macOS）互換。連想配列・readarray・=~ は使わない
#
# 環境変数:
#   FF_REVIEW_LOCK_OVERRIDE=1                     A（走行中ロック）だけを解除する。Bash ツール
#                                                 なら対象 git コマンド先頭の環境代入としても効く
#                                                 （`FF_REVIEW_LOCK_OVERRIDE=1 git commit ...`）。
#                                                 Edit / Write などの編集系ツールにはコマンド行が
#                                                 無く、hook はセッションの環境変数を継承するだけ
#                                                 なので、そちらは再起動なしには変えられない
#                                                 （tool 非依存の復旧手段は `rm <ロック>`）
#   FF_REVIEW_LOCK_MAX_AGE_SECONDS=<秒>           これより古いロックは PID 生存でも stale（既定 14400）
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

[ "${FF_DEV_TOOLKIT_SKIP_REVIEW_IN_FLIGHT_GUARD:-0}" = "1" ] && exit 0

command -v jq >/dev/null 2>&1 || exit 0

tool="$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null)" || exit 0
[ -n "$tool" ] || exit 0

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

# ── ロックの読み取り（A・B の両方が使う） ──────────────────────────────────
LOCK="${ROOT}/.review-results/.review-in-flight"

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

# ── B) レビューエージェント起動時の dirty ガード ────────────────────────────
if [ "$tool" = "Agent" ] || [ "$tool" = "Task" ]; then
  subagent="$(printf '%s' "$input" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null)" || exit 0
  # 入力に subagent_type が無い版のハーネスは判定材料が無い（fail-open）
  [ -n "$subagent" ] || exit 0
  case "$subagent" in
    pr-review-toolkit:*) : ;;
    *) exit 0 ;;
  esac
  # ignored な成果物は porcelain の出力に出ないので、そのまま判定に使える
  dirty="$(git -C "$ROOT" status --porcelain 2>/dev/null)" || exit 0
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
  emit_ask "${lock_note}⚠️ ff-dev-toolkit guard（レビュー起動時の dirty 検査）: 作業ツリーに未コミットの変更が ${changed} 件あります（${ROOT}）。
レビューエージェントは git diff <base>...HEAD を見るので、未コミットの修正は無いものとして扱われます。1 回転目の指摘に対応した fix が未コミットのままだと、その指摘は「未解消」と判定され、解消済みかどうかの確認に 1 往復ぶん余計にかかります。
先にコミットしてから起動するか、この状態で起動するのが意図どおりならそのまま続行してください（レビュー待ち時間の使い方は multi-review スキルの「レビュー待ち時間の使い方」節を参照）。
このガードを止める場合は環境変数 FF_DEV_TOOLKIT_SKIP_REVIEW_IN_FLIGHT_GUARD=1 を設定します。"
fi

# ── A) 走行中ロック ────────────────────────────────────────────────────────
[ -f "$LOCK" ] || exit 0
[ -n "$lock_pid" ] || exit 0

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

# PID が死んでいる / 上限より古い場合は stale。消し忘れたロックや再利用された PID で
# 以後の全編集を止めないよう、警告だけ出して通す（deny しない）。
if [ -n "$lock_stale_reason" ]; then
  emit_message "ℹ️ ff-dev-toolkit guard（レビュー走行中ロック）: 走行中とみなせないロックが残っています（${lock_stale_reason}）。
このコマンドはブロックしません。ロックは次のレビュー実行が置き直しますが、気になる場合は削除してください: ${LOCK}"
fi

[ "${FF_REVIEW_LOCK_OVERRIDE:-0}" = "1" ] && exit 0
[ "${cmd_override:-0}" = "1" ] && exit 0

elapsed="不明"
[ -n "$lock_elapsed_seconds" ] && elapsed="${lock_elapsed_seconds} 秒"
[ -n "$lock_head" ] || lock_head="n/a"
[ -n "$lock_task" ] || lock_task="review"
[ -n "$lock_started" ] || lock_started="n/a"

emit_deny "⚠️ ff-dev-toolkit guard（レビュー走行中・作業ツリー編集の抑止）: ${lock_task} が走行中です（PID ${lock_pid}）。
  開始 SHA: ${lock_head}
  開始時刻: ${lock_started}（経過 ${elapsed}）
  観点:     ${lock_perspectives:-n/a}
走行中に作業ツリーが動くと、実行後のリビジョン検証が結果を**全破棄**します（数分〜十数分ぶんのレビューが失われます）。完了通知が出るまで編集・commit・checkout をしないでください。
待ち時間にできることは multi-review スキルの「レビュー待ち時間の使い方」節を参照してください。
続行する必要がある場合（走行が既に終わっている / 結果の破棄を承知で編集する）:
  1) ツール非依存の復旧: ロックを消す → rm ${LOCK}
     （どのツールからでも効きます。次のレビュー実行がロックを置き直します）
  2) Bash ツールで実行するコマンドに限り、対象の git コマンド先頭に環境代入を付ける
     → FF_REVIEW_LOCK_OVERRIDE=1 git ...
     Edit / Write などの編集系ツールにはコマンド行が無く、hook はセッションの環境変数を
     継承するだけなので、この変数はセッションを再起動せずには変えられません。編集系を
     通したいときは 1) を使ってください。
このガードを止める場合は環境変数 FF_DEV_TOOLKIT_SKIP_REVIEW_IN_FLIGHT_GUARD=1 を設定します
（同じくセッション環境。非対話実行での opt-out はこちら）。"
