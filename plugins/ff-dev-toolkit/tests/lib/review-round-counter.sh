#!/usr/bin/env bash
#
# レビューの **巡回カウンタ**（レビュー巡回の上限）。2 つの入口から source する共有ライブラリ:
#   - hooks/guard-review-in-flight.sh（Claude Code の PreToolUse。`hooks/../tests/lib/` から。
#     `review-write-scan.sh` と同じ配置で、hook 本体の行数を分割閾値の内側に保つため判定はここに置く）
#   - scripts/multi-agent.sh の review 本体（全ホスト共通の起動経路。`multi-review.sh` 経由も直接起動も
#     ここを通るので、plugin hook が発火しないホストでも同じ上限が効く）
#
# 目的: 同じブランチ（= 同じ PR）でレビューを何巡回したかを数え、上限（既定 2 巡）を超える巡の
# **起動**を止める。「2 巡目の fix の後にもう 1 巡回す」を散文の規範ではなく機械のゲートで止め、
# 残件を `/out-of-scope-issue` の bundle 統合へ流す案内を出す。
#
# 記録の置き場: `<git common dir>/ff-review-rounds/<ブランチの鍵>.tsv`
#   （`git rev-parse --git-common-dir` の配下。worktree 間で共有されるので、実装と仕上げで
#   worktree が違っても数え直さない。レビュー出力先 `.review-results/` の外に置くのは、
#   凍結の復旧手順（レーン置き場の `rm -rf`）と `multi-agent.sh --fresh` の退避が出力先を
#   丸ごと動かしても巡の記録が消えないようにするため）
#
# 巡の数え方（1 巡 = 1 つの HEAD に対するレビュー起動のまとまり）:
#   - 起動時の HEAD（コミット SHA）を記録する。**記録済みの HEAD で起動した回は同じ巡**
#     （並列起動の 2 本目以降・`--resume`・委譲レビューのホスト側起動・部分再検証の再実行、
#     hook と multi-agent.sh の二重の判定は巡を増やさない）。記録に無い HEAD で起動した回が
#     次の巡になる。fix を commit してから起動するのが規定なので、「fix の後のレビュー」は
#     HEAD の変化で数えられる
#   - 数えるのはブランチ単位（`git symbolic-ref --short HEAD`）で、**異なる HEAD の個数**
#     （行数ではない。並列起動が同じ巡を 2 行書いても 1 巡）
#   - **PR 作成前のレビュー（実装途中の proactive な起動）も巡を消費する**。印で区別はしない。
#     使い切った後に PR のレビューを回す必要があれば、下の通過口で 1 巡ずつ通す
#
# 母集団（巡に数える起動）:
#   - agent（hook だけ）: hook がレーンを取る対象と同じ集合（名簿の型 / 委譲レビューの prompt）。
#     `isolation: "worktree"` の隔離起動も**数える**（凍結の対象外なのは作業ツリーを共有しない
#     からで、巡であることは変わらない）
#   - bash（hook）: コマンド位置にある `multi-review.sh` / `codex-review.sh` / `multi-agent.sh`。
#     区間先頭の環境代入・ラッパー（`env` / `command` / `nohup` / `time` / `exec` / `nice` /
#     `timeout` / `gtimeout`。数値・期間の引数は読み飛ばす）・制御の接頭辞（`if` / `!` / `while` /
#     `until` / `then` / `do` / `else` / `elif`）・`bash` / `sh` / `zsh` 経由を剥がして判定する。
#     行継続（行末の `\`）は 1 行へつなぐ
#   - script（multi-agent.sh の review 本体）: 自分の引数で同じ判定をする
#   数えない: `--dry-run` / `--print-reviewers` / `--set-reviewers` / `--help` / `--list-perspectives` /
#   `--print-toolkit-root` / `--staged`（commit 前の index レビューで PR の巡ではない）、
#   `--task` が review 以外（`multi-agent.sh` の既定の task は review なので、`--task` 無しは数える）、
#   `grep … multi-review.sh` のようにコマンド位置に無い言及
#
# 判定不能（fail-soft = 通す + 警告。0 巡と見なして黙って通さない）:
#   - 記録ファイルが無い（初回の巡、または記録が消えた — 区別できない）: 通し、警告を出し、
#     この起動が通れば 1 巡目として記録する
#   - 記録ファイルが読めない・書式が壊れている・symlink: 通し、警告を出す。記録は書き換えない
#     （作り直しは利用者が `rm` する。黙って 1 巡目から数え直さない）
#   - detached HEAD / HEAD を読めない / 記録の置き場を検証・作成できない: 通し、警告を出す
#   - **統合ブランチ**（`develop` / `main` / リモートの既定ブランチ）の上: PR の巡ではないので
#     通し、警告を出す（記録しない。数えると PR をまたいで 1 本に数え、別の PR のレビューを止める）
#
# 記録する時点: 判定（deny かどうか）は起動の前に行い、記録は起動が通ると決まってから
# （`ff_review_round_commit`）。hook は deny で終わる回は記録しない。ask（dirty 検査の確認）で
# 終わる回は**仮記録**する（`ff_review_round_commit_provisional`。利用者が許可して起動した回を
# 数え損ねない）。起動が拒否されて `PermissionDenied` が来たら、同じ鍵の仮記録を取り消す
# （`ff_review_round_cancel`）。
#
# 1 回限りの通過口（既存ガードの `FF_*_ACK=1` と同じ形）:
#   - bash（hook）: 起動コマンドの区間先頭の環境代入 `FF_REVIEW_ROUND_ACK=1`
#   - agent（hook）: prompt の行頭が `FF_REVIEW_ROUND_ACK=1` だけの 1 行
#   - script: 自分のプロセス環境の `FF_REVIEW_ROUND_ACK=1`（起動コマンドの先頭の環境代入がここへ
#     届く。hook は Claude Code のセッション環境を読まないが、script はプロセス環境しか材料が無い）
#   通した巡も記録するので、次の HEAD で起動すると再び止まる（通過はその 1 巡だけ）。
#
# 残件数の受け口（重複 finding の畳み込み）:
#   deny 文に残件数を載せる。読むのは記録と同じ置き場の `<鍵>.residual`（`raw=<n>` /
#   `folded=<n>` の key=value）。`FF_JEV_MODE=on` かつ `folded=` があれば畳み込み後の件数を、
#   それ以外は `raw=` を使う。`off`（既定）では `folded=` を**読まない**ので、畳み込みの有無で
#   deny 文は 1 バイトも変わらない。
#   residual の書き手は畳み込み側。無い間は生の件数（書き手が居なければ残件の行を出さない）。
#
# 環境変数:
#   FF_REVIEW_ROUND_LIMIT=<n>   巡の上限（既定 2。0 でゲートを無効化 = 数えず記録もしない。
#                               数値でない値は既定へ倒す）
#   FF_JEV_MODE=on|off          残件数に畳み込み後の件数を使うか（上記）
#
# 前提: agent 経路は hook 側で定義済みの `is_review_lock_type` / `is_delegated_review_prompt` と
# 変数 `input` を使う（hook の中でだけ動く）。bash / script 経路と記録の読み書きはこのファイルで
# 閉じている。bash 3.2 互換（連想配列・mapfile・=~ を使わない）。

RR_VERDICT="pass"
RR_NOTE=""
RR_REASON=""
RR_ACK=0
RR_PENDING_FILE=""
RR_PENDING_ROUND=""
RR_PENDING_HEAD=""

RR_HEADER="# ff-review-rounds v1"

rr_limit() {
  local l="${FF_REVIEW_ROUND_LIMIT:-2}"
  case "$l" in
    '' | *[!0-9]*) l=2 ;;
  esac
  printf '%s' "$l"
}

rr_sanitize() { # <文字列> → ファイル名に使える形（記号を含む名前はハッシュ付きで一意にする）
  local stripped hashed
  stripped="$(printf '%s' "$1" | tr -dc 'A-Za-z0-9_-' 2>/dev/null)"
  [ "$stripped" = "$1" ] && { printf '%s' "$stripped"; return 0; }
  hashed="$(printf '%s' "$1" | cksum 2>/dev/null | awk '{ print $1 "-" $2 }' 2>/dev/null)"
  case "$hashed" in
    [0-9]*) printf '%s-x%s' "$stripped" "$hashed" ;;
    *) : ;;
  esac
}

rr_shq() { # <文字列> → シェルの単一引用語
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# 起動スクリプトより後ろの引数列が、巡に数える起動か（rc 0 = 数える）。
rr_args_are_launch() { # <引数...>
  local a prev="" task=""
  for a in "$@"; do
    # 素朴なトークン化で付いてくる引用符・閉じ括弧を落とす（`"explore"` / `--print-toolkit-root)"` 等）
    a="${a#[\"\']}"
    a="${a%%[\)\"\']*}"
    case "$a" in
      --dry-run | --print-reviewers | --set-reviewers | --set-reviewers=* | --help | -h | --staged \
        | --list-perspectives | --print-toolkit-root | --print-toolkit-root=*) return 1 ;;
      --task=*) task="${a#--task=}" ;;
    esac
    [ "$prev" = "--task" ] && task="$a"
    prev="$a"
  done
  # multi-agent.sh の既定の task は review。`--task` が review 以外のときだけ外す
  case "$task" in
    '' | review) return 0 ;;
  esac
  return 1
}

# bash の起動コマンドがレビューの巡を始めるか。区間ごとに判定し、当たった区間の先頭に
# `FF_REVIEW_ROUND_ACK=1` があれば RR_ACK=1。区切りは hook の git 走査と同じ素朴な分割。
rr_bash_is_launch() { # <command>
  local segments seg tok i n is_launch seg_ack
  RR_ACK=0
  is_launch=1
  segments="$(printf '%s\n' "$1" | awk '
    { if (sub(/\\$/, "")) { buf = buf $0 " "; next }
      line = buf $0; buf = ""
      gsub(/&&|\|\||;|\|/, "\n", line); print line }
    END { if (buf != "") print buf }')"
  while IFS= read -r seg; do
    case "$seg" in
      *multi-review.sh* | *multi-agent.sh* | *codex-review.sh*) : ;;
      *) continue ;;
    esac
    set -f
    # shellcheck disable=SC2206 # 素朴な空白トークン化（hook の git 走査と同じ。glob は set -f で抑止）
    local toks=($seg)
    set +f
    n=${#toks[@]}
    i=0
    seg_ack=0
    # 区間先頭の環境代入・ラッパー・制御の接頭辞を剥がす
    while [ "$i" -lt "$n" ]; do
      case "${toks[$i]}" in
        FF_REVIEW_ROUND_ACK=1) seg_ack=1; i=$((i + 1)) ;;
        [A-Za-z_]*=*) i=$((i + 1)) ;;
        '!' | if | elif | then | else | do | while | until | '{' | '(') i=$((i + 1)) ;;
        command | nohup | time | exec | builtin) i=$((i + 1)) ;;
        env)
          # env のオプションだけを消費する。後ろの `NAME=VALUE`（`env FOO=bar bash …`）と
          # `FF_REVIEW_ROUND_ACK=1` は、外側のループの環境代入の分岐がそのまま消費する
          i=$((i + 1))
          while [ "$i" -lt "$n" ]; do
            case "${toks[$i]}" in
              -u | -C | -S) i=$((i + 2)) ;;
              -*) i=$((i + 1)) ;;
              *) break ;;
            esac
          done
          ;;
        nice)
          i=$((i + 1))
          while [ "$i" -lt "$n" ]; do
            case "${toks[$i]}" in
              -n) i=$((i + 2)) ;;
              -n* | --adjustment=* | -[0-9]*) i=$((i + 1)) ;;
              *) break ;;
            esac
          done
          ;;
        timeout | gtimeout)
          i=$((i + 1))
          while [ "$i" -lt "$n" ]; do
            case "${toks[$i]}" in
              -k | -s | --kill-after | --signal) i=$((i + 2)) ;;
              -*) i=$((i + 1)) ;;
              *) break ;;
            esac
          done
          # 期間（`600` / `10m` 等）
          [ "$i" -lt "$n" ] && i=$((i + 1))
          ;;
        *) break ;;
      esac
    done
    [ "$i" -lt "$n" ] || continue
    # `bash` / `sh` / `zsh` 経由なら、そのオプションの次がスクリプト
    case "${toks[$i]}" in
      bash | sh | zsh | */bash | */sh | */zsh)
        i=$((i + 1))
        while [ "$i" -lt "$n" ]; do
          case "${toks[$i]}" in
            -*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        ;;
    esac
    [ "$i" -lt "$n" ] || continue
    tok="${toks[$i]}"
    tok="${tok#\"}"
    tok="${tok%\"}"
    tok="${tok#\'}"
    tok="${tok%\'}"
    case "$tok" in
      multi-review.sh | */multi-review.sh | codex-review.sh | */codex-review.sh | multi-agent.sh | */multi-agent.sh) : ;;
      *) continue ;;
    esac
    rr_args_are_launch "${toks[@]:$((i + 1))}" || continue
    is_launch=0
    [ "$seg_ack" -eq 1 ] && RR_ACK=1
  done <<EOF
$segments
EOF
  return "$is_launch"
}

rr_agent_is_launch() {
  local subagent prompt line
  RR_ACK=0
  subagent="$(printf '%s' "$input" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null)"
  prompt="$(printf '%s' "$input" | jq -r '.tool_input.prompt // ""' 2>/dev/null)"
  if ! is_review_lock_type "$subagent"; then
    [ -n "$prompt" ] && is_delegated_review_prompt "$prompt" || return 1
  fi
  while IFS= read -r line; do
    [ "$line" = "FF_REVIEW_ROUND_ACK=1" ] && RR_ACK=1
  done <<EOF
$prompt
EOF
  return 0
}

# 記録を読む。RR_HEADS（改行区切りの異なる HEAD）/ RR_COUNT を設定。書式違反は rc 1。
rr_read() { # <file>
  local out
  [ -r "$1" ] || return 1
  out="$(awk -v hdr="$RR_HEADER" '
    NR == 1 { if ($0 != hdr) { bad = 1; exit } next }
    /^[[:space:]]*$/ { next }
    {
      if (split($0, f, "\t") != 3 || f[1] !~ /^[0-9]+$/ || f[2] !~ /^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]+$/ || f[3] !~ /^[0-9]+$/) { bad = 1; exit }
      if (!(f[2] in seen)) { seen[f[2]] = 1; print f[2] }
    }
    END { if (NR == 0) bad = 1; if (bad) exit 3 }' "$1" 2>/dev/null)" || return 1
  RR_HEADS="$out"
  RR_COUNT=0
  [ -n "$out" ] && RR_COUNT="$(printf '%s\n' "$out" | grep -c . 2>/dev/null | tr -d '[:space:]')"
  case "$RR_COUNT" in
    '' | *[!0-9]*) return 1 ;;
  esac
  return 0
}

rr_append() { # <file> <round> <head>
  local now tmp
  now="$(date -u +%s 2>/dev/null)"
  case "$now" in
    '' | *[!0-9]*) now=0 ;;
  esac
  if [ -e "$1" ]; then
    printf '%s\t%s\t%s\n' "$2" "$3" "$now" >> "$1" 2>/dev/null
    return $?
  fi
  tmp="${1}.tmp.$$"
  { printf '%s\n' "$RR_HEADER"; printf '%s\t%s\t%s\n' "$2" "$3" "$now"; } > "$tmp" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    return 1
  }
  mv "$tmp" "$1" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}

# 残件数（deny 文へ載せる）。空 = 不明。
ff_review_round_residual() { # <記録ファイル>
  local f raw folded
  f="${1%.tsv}.residual"
  [ -r "$f" ] || return 0
  raw="$(sed -n 's/^raw=//p' "$f" 2>/dev/null | head -n 1)"
  folded="$(sed -n 's/^folded=//p' "$f" 2>/dev/null | head -n 1)"
  case "$raw" in '' | *[!0-9]*) raw="" ;; esac
  case "$folded" in '' | *[!0-9]*) folded="" ;; esac
  if [ "${FF_JEV_MODE:-off}" = "on" ] && [ -n "$folded" ]; then
    printf '%s 件（重複 finding の畳み込み後）' "$folded"
  elif [ -n "$raw" ]; then
    printf '%s 件' "$raw"
  fi
}

rr_warn() { # <本文>
  RR_NOTE="ℹ️ ff-dev-toolkit guard（レビュー巡回カウンタ）: $1"
}

# 記録の置き場（`<git common dir>/ff-review-rounds`）。解決できなければ rc 1。
rr_store_dir() { # <repo root>
  local c
  c="$(git -C "$1" rev-parse --git-common-dir 2>/dev/null)" || return 1
  [ -n "$c" ] || return 1
  case "$c" in
    /*) : ;;
    *) c="$1/$c" ;;
  esac
  c="$(cd "$c" 2>/dev/null && pwd -P 2>/dev/null)" || return 1
  [ -n "$c" ] || return 1
  printf '%s/ff-review-rounds' "$c"
}

# 統合ブランチ（develop / main / いずれかのリモートの既定ブランチ）か。
rr_is_integration_branch() { # <repo root> <branch>
  local r d
  case "$2" in
    develop | main) return 0 ;;
  esac
  for r in $(git -C "$1" remote 2>/dev/null); do
    d="$(git -C "$1" symbolic-ref -q --short "refs/remotes/${r}/HEAD" 2>/dev/null)" || continue
    [ "${d#"${r}"/}" = "$2" ] && return 0
  done
  return 1
}

# 判定の本体。起動であることは呼び出し側が確かめてある。RR_VERDICT / RR_NOTE / RR_REASON と、
# 通すときに記録する内容（RR_PENDING_*）を設定する。記録そのものは ff_review_round_commit。
rr_judge() { # <repo root>
  local root="$1" limit branch head key dir file next short residual rounds_list h k
  limit="$(rr_limit)"
  branch="$(git -C "$root" symbolic-ref --short -q HEAD 2>/dev/null)"
  if [ -z "$branch" ]; then
    rr_warn "HEAD がブランチを指していない（detached HEAD）ため、どの PR の巡かを特定できません。判定不能として通します（上限 ${limit} 巡は数えていません）。"
    return 0
  fi
  if rr_is_integration_branch "$root" "$branch"; then
    rr_warn "統合ブランチ ${branch} の上での起動は PR の巡ではないため、巡を数えられません。判定不能として通します（記録しません。PR をまたいで 1 本に数えないため）。PR の巡として数えるには、その PR のブランチで起動してください。"
    return 0
  fi
  head="$(git -C "$root" rev-parse -q --verify HEAD 2>/dev/null)"
  if [ -z "$head" ]; then
    rr_warn "HEAD を読めないため巡を数えられません。判定不能として通します（ブランチ ${branch}）。"
    return 0
  fi
  key="$(rr_sanitize "$branch")"
  dir="$(rr_store_dir "$root")" || dir=""
  if [ -z "$key" ] || [ -z "$dir" ] || [ -L "$dir" ] || ! mkdir -p "$dir" 2>/dev/null || [ -L "$dir" ] || [ ! -d "$dir" ]; then
    rr_warn "巡回の記録の置き場（${dir:-git common dir を解決できません}）を検証・作成できないため巡を数えられません。判定不能として通します（ブランチ ${branch}）。"
    return 0
  fi
  file="${dir}/${key}.tsv"
  short="$(printf '%s' "$head" | cut -c1-12)"
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    RR_PENDING_FILE="$file"
    RR_PENDING_ROUND=1
    RR_PENDING_HEAD="$head"
    rr_warn "ブランチ ${branch} の巡回の記録がありません（この PR で初回のレビューか、記録が消えたかを区別できません）。0 巡とは見なさず判定不能として通し、この起動（HEAD ${short}）が通れば 1 巡目として記録します。上限は ${limit} 巡です。記録: ${file}"
    return 0
  fi
  if [ -L "$file" ] || ! rr_read "$file"; then
    rr_warn "巡回の記録を読めません（書式が壊れている・読み取り権限が無い・symlink）。判定不能として通します（記録は書き換えません）。数え直す場合は記録を消してください: rm -- $(rr_shq "$file")"
    return 0
  fi
  while IFS= read -r h; do
    [ "$h" = "$head" ] && return 0
  done <<EOF
$RR_HEADS
EOF
  next=$((RR_COUNT + 1))
  if [ "$next" -le "$limit" ] || [ "${RR_ACK:-0}" -eq 1 ]; then
    RR_PENDING_FILE="$file"
    RR_PENDING_ROUND="$next"
    RR_PENDING_HEAD="$head"
    return 0
  fi
  rounds_list=""
  k=0
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    k=$((k + 1))
    rounds_list="${rounds_list}  ${k} 巡目: HEAD $(printf '%s' "$h" | cut -c1-12)
"
  done <<EOF
$RR_HEADS
EOF
  residual="$(ff_review_round_residual "$file")"
  RR_VERDICT="deny"
  RR_REASON="⚠️ ff-dev-toolkit guard（レビュー巡回の上限）: ブランチ ${branch} で ${next} 巡目のレビューを起動しようとしています。上限は ${limit} 巡です（${limit} 巡目の fix の後にレビューを重ねない）。
${rounds_list}  今回の起動: HEAD ${short}
${residual:+  残件: ${residual}
}残件はこれ以上の巡で拾わず、/out-of-scope-issue の bundle 統合へ流してください（判定順は YAGNI → 同 PR でインライン修正 → 既存の open bundle へ追記 → bundle 単位で新規起票）。未解消の Critical / Warning がある間はマージしません（解消は修正か記録付き棄却。${limit} 巡目の fix の確認は親の直読と対象 suite の再実行で行い、結果を PR 本文へ残す）。
方針転換などでこの 1 巡だけ通す必要がある場合（通した巡も記録されるので、次の巡でまた止まります）:
  - Bash: 起動コマンドの先頭へ環境代入を付ける → FF_REVIEW_ROUND_ACK=1 bash …/multi-review.sh …
  - Agent / Task: prompt の行頭に FF_REVIEW_ROUND_ACK=1 だけの 1 行を置く（並列に起動する場合は各起動に付ける）
上限の変更は FF_REVIEW_ROUND_LIMIT=<n>（0 でこのゲートを無効化）。記録: ${file}"
  return 0
}

# 通すと決まった起動を記録する。追記できなければ RR_NOTE へ警告を足して rc 1（起動は止めない）。
ff_review_round_commit() {
  local f="$RR_PENDING_FILE" r="$RR_PENDING_ROUND" h="$RR_PENDING_HEAD"
  [ -n "$f" ] || return 0
  RR_PENDING_FILE=""
  if [ -L "$f" ] || ! rr_append "$f" "$r" "$h"; then
    RR_NOTE="${RR_NOTE:+${RR_NOTE}
}ℹ️ ff-dev-toolkit guard（レビュー巡回カウンタ）: 巡回の記録へ追記できませんでした（${f}）。この起動（${r} 巡目）は通しますが、次の巡を数え損ねる可能性があります。"
    return 1
  fi
  return 0
}

# ask の出口用: 記録したうえで、取り消し用の印（`<鍵>.prov.<起動の鍵>`）を残す。印は、この起動が
# 新しい HEAD を足した回だけ置く（既に記録済みの HEAD を取り消すと、別の起動の巡を消すため）。
ff_review_round_commit_provisional() { # <起動の鍵（tool_use_id 由来）>
  local f="$RR_PENDING_FILE" h="$RR_PENDING_HEAD" dir
  [ -n "$f" ] || return 0
  ff_review_round_commit || return 1
  [ -n "$1" ] || return 0
  printf 'head=%s\n' "$h" > "${f%.tsv}.prov.$1" 2>/dev/null || return 0
  # 取り消されなかった古い印（許可されて起動した回）を片付ける
  dir="${f%/*}"
  find "$dir" -maxdepth 1 -name '*.prov.*' -type f -mmin +60 -exec rm -f {} + 2>/dev/null
  return 0
}

# PermissionDenied の入口: 同じ起動の鍵の仮記録を取り消す（その HEAD の行を記録から消す）。
ff_review_round_cancel() { # <repo root> <起動の鍵>
  local dir p f h tmp
  [ -n "$2" ] || return 0
  dir="$(rr_store_dir "$1")" || return 0
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
  for p in "$dir"/*.prov."$2"; do
    [ -f "$p" ] && [ ! -L "$p" ] || continue
    f="${p%.prov.*}.tsv"
    h="$(sed -n 's/^head=//p' "$p" 2>/dev/null | head -n 1)"
    rm -f "$p" 2>/dev/null
    [ -n "$h" ] && [ -f "$f" ] && [ ! -L "$f" ] || continue
    tmp="${f}.tmp.$$"
    if awk -F '\t' -v h="$h" 'NR == 1 || $2 != h' "$f" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    else
      rm -f "$tmp" 2>/dev/null
    fi
  done
  return 0
}

rr_reset() {
  RR_VERDICT="pass"
  RR_NOTE=""
  RR_REASON=""
  RR_PENDING_FILE=""
  RR_PENDING_ROUND=""
  RR_PENDING_HEAD=""
}

# hook の入口。rc 1 = この呼び出しはレビューの起動ではない（何もしない）。rc 0 = 判定した
# （RR_VERDICT が pass / deny、RR_NOTE は警告、RR_REASON は deny 文、RR_PENDING_* は通すときの記録）。
# 前提: hook の変数 `input` / `ROOT`。
ff_review_round_gate() { # <agent|bash>
  local limit cmd
  rr_reset
  limit="$(rr_limit)"
  [ "$limit" -eq 0 ] && return 1
  case "$1" in
    agent) rr_agent_is_launch || return 1 ;;
    bash)
      cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)"
      [ -n "$cmd" ] || return 1
      rr_bash_is_launch "$cmd" || return 1
      ;;
    *) return 1 ;;
  esac
  rr_judge "$ROOT"
  return 0
}

# multi-agent.sh の review 本体の入口（全ホスト共通）。引数は multi-agent.sh が受けた引数。
# rc 0 = 通す（記録済み。警告は stderr）/ rc 1 = 上限超過（deny 文を stderr へ出した）。
# 通過口はプロセス環境の FF_REVIEW_ROUND_ACK=1。cwd の git リポジトリが材料。
ff_review_round_script_gate() { # <引数...>
  local limit root
  rr_reset
  limit="$(rr_limit)"
  [ "$limit" -eq 0 ] && return 0
  rr_args_are_launch "$@" || return 0
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || return 0
  [ -n "$root" ] || return 0
  RR_ACK=0
  [ "${FF_REVIEW_ROUND_ACK:-}" = "1" ] && RR_ACK=1
  rr_judge "$root"
  if [ "$RR_VERDICT" = "deny" ]; then
    printf '%s\n' "$RR_REASON" >&2
    return 1
  fi
  ff_review_round_commit
  [ -z "$RR_NOTE" ] || printf '%s\n' "$RR_NOTE" >&2
  return 0
}
