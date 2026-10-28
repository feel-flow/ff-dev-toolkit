#!/usr/bin/env bash
# guard-review-in-flight.sh の構成ファイル: レーン・ロック・dirty の判定。
#
# hooks/guard-review-in-flight.sh が、ツール種別の分岐の直前に 1 回 source する。
# 読めないときは入口が permissionDecision deny を返す（許可側へ倒さない）。
# 本文は分割前の連続した行。ここへ set を足さない。
# 隣の tests/lib を指すパスだけ、このファイル基準へ直した（分割前は hook 基準の ../tests/lib だった）。
# 末尾の _ff_review_in_flight_judge_loaded は読み込み完了の印。
# 呼び出し元の hook は set -e を使わない。source の失敗は入口が自分で見る。

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
# hookとorchestratorは同じ所有markerを使う。hookが先に起動しても、未標識の非空rootを
# 作って後続のorchestratorへ引き渡さない。正本helperが無い回はレーンを触らない。
_ff_lane_scope_lib="${BASH_SOURCE[0]%/*}/review-lane-scope.sh"
_ff_lane_boundary_loaded=0
_ff_lane_output_prepared=0
_ff_review_lane_scope_loaded=0
if [ ! -L "$_ff_lane_scope_lib" ] && [ -f "$_ff_lane_scope_lib" ] && [ -r "$_ff_lane_scope_lib" ]; then
  _ff_lane_scope_last="$(awk 'NF { l = $0 } END { print l }' "$_ff_lane_scope_lib" 2>/dev/null)" || _ff_lane_scope_last=""
  if [ "$_ff_lane_scope_last" = '_ff_review_lane_scope_loaded=1' ]; then
    # shellcheck source=review-lane-scope.sh
    if . "$_ff_lane_scope_lib" \
      && [ "${_ff_review_lane_scope_loaded:-0}" -eq 1 ] \
      && [ "$(type -t ff_lane_visit_records 2>/dev/null)" = function ] \
      && [ "$(type -t ff_lane_record_limit 2>/dev/null)" = function ] \
      && [ "$(type -t ff_lane_body_field 2>/dev/null)" = function ] \
      && [ "$(type -t ff_lane_claim_body_is_valid 2>/dev/null)" = function ] \
      && [ "$(type -t ff_lane_foreign_record 2>/dev/null)" = function ] \
      && [ "$(type -t ff_lane_foreign_live 2>/dev/null)" = function ] \
      && [ "$(type -t ff_lane_infer_trees 2>/dev/null)" = function ]; then
      _ff_lane_boundary_loaded=1
    fi
  fi
fi
[ "$_ff_lane_boundary_loaded" -eq 1 ] || emit_deny '⚠️ ff-dev-toolkit guard: review-lane-scope.sh の完全なclaim対応readerを読み込めないため停止します。pluginを更新・再導入してください。'
lane_prepare_output() {
  if [ "$_ff_lane_output_prepared" -eq 1 ]; then
    ff_review_output_private "${ROOT}/${OUTPUT_DIR_NAME}" true >/dev/null 2>&1
    return $?
  fi
  ff_review_output_prepare "$ROOT" "${ROOT}/${OUTPUT_DIR_NAME}" false review >/dev/null 2>&1 || return 1
  _ff_lane_output_prepared=1
}
# 物理パスの包含判定（レーン置き場の検証と、Bash 書き込み走査の「ツリー内か」が共用する）
phys_dir() { # <dir> → 物理パス（失敗は空）
  (cd "$1" 2>/dev/null && pwd -P 2>/dev/null)
}
path_within() { # <phys> <root_phys>
  local p="$1" r="$2"
  # Windows（NTFS）は大文字小文字を区別しない。pwd -P は打った綴りのまま返すので、Git Bash /
  # Cygwin では小文字へ揃えて比べる（tests/lib/review-write-scan.sh の ws_path_within と同じ。Issue `#2018`）
  case "${OSTYPE:-}" in
    msys* | cygwin*)
      p="$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]')"
      r="$(printf '%s' "$r" | tr '[:upper:]' '[:lower:]')"
      ;;
  esac
  case "$p" in
    "$r" | "$r"/*) return 0 ;;
  esac
  return 1
}
lane_dir_is_safe() {
  local out_dir root_phys phys
  [ "$_ff_lane_boundary_loaded" -eq 1 ] || return 1
  out_dir="${ROOT}/${OUTPUT_DIR_NAME}"
  [ -L "$out_dir" ] && return 1
  [ -L "$LANE_DIR" ] && return 1
  root_phys="$(phys_dir "$ROOT")"
  [ -n "$root_phys" ] || return 1
  if [ -e "$out_dir" ]; then
    [ -d "$out_dir" ] || return 1
    phys="$(phys_dir "$out_dir")"
    [ -n "$phys" ] || return 1
    path_within "$phys" "$root_phys" || return 1
    [ "$phys" != "$root_phys" ] || return 1
    lane_prepare_output || return 1
  fi
  if [ -e "$LANE_DIR" ]; then
    [ -d "$LANE_DIR" ] || return 1
    phys="$(phys_dir "$LANE_DIR")"
    [ -n "$phys" ] || return 1
    path_within "$phys" "$root_phys" || return 1
    [ "$phys" != "$root_phys" ] || return 1
    ff_review_output_private "$LANE_DIR" >/dev/null 2>&1 || return 1
  fi
  return 0
}
lane_dir_is_safe && LANE_SAFE=1

lane_file_is_safe() { # <leaf>。FIFO等は開かずに落とす。
  ff_review_output_regular "$1" >/dev/null 2>&1 && [ -r "$1" ]
}

lane_temp_dir() { # 検証済み置き場内へ排他的な私有namespaceを確保する。
  local work
  lane_dir_is_safe || return 1
  work="$(umask 077; mktemp -d "${LANE_DIR}/.lane-work.XXXXXX" 2>/dev/null)" || return 1
  ff_review_output_private "$work" true >/dev/null 2>&1 || return 1
  printf '%s\n' "$work"
}

lane_field() { # <レーンのパス> <キー>
  lane_file_is_safe "$1" || return 1
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1
}

sanitize_id() { # <文字列> → ファイル名に使える形（衝突しない）
  # 記号を**削るだけ**だと別物が同じ形へ潰れる（`a!` と `a@` がどちらも `a` になる）。
  # 潰れた id で対応づけ・解放を行うと、無関係なサブエージェントの終端が別レーンを
  # 閉じる（= 走行中のレビューで凍結が解ける）。削って形が変わった場合は、元の文字列の
  # ハッシュを添えて一意性を戻す。
  local stripped hashed
  stripped="$(printf '%s' "$1" | tr -dc 'A-Za-z0-9_-' 2>/dev/null)"
  [ "$stripped" = "$1" ] && { printf '%s' "$stripped"; return 0; }
  hashed="$(printf '%s' "$1" | cksum 2>/dev/null | awk '{ print $1 "-" $2 }' 2>/dev/null)"
  case "$hashed" in
    [0-9]*) printf '%s-x%s' "$stripped" "$hashed" ;;
    # ハッシュを作れない環境では、潰れた形を使わずに空を返す（対応づけも解放も行わない
    # ＝ 早く解ける側へ倒さない。レーンは寿命上限で回収される）。
    *) : ;;
  esac
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
is_delegated_review_prompt() { # <prompt 文字列>
  # prompt は利用者・ホストが自由に書ける文字列なので、**部分一致で拾わない**。
  # マーカーの語がただ含まれるだけ（用語集・「レビューするな」という指示文など）で
  # 凍結すると、レビュー以外の委譲が最大 30 分止まる。次の 3 つをすべて要求する:
  #   (a) 行頭が `FF-REVIEW-DELEGATED: ` である行がある（散文中の言及を落とす）
  #   (b) その行が名指すパスが、このリポジトリのレビュー出力先の `.delegated/` 配下の
  #       `.prompt.md` である（出力先の外・別リポジトリの同名パスを落とす）
  #   (c) そのパスが**実在する通常ファイル**である（委譲が現に起きた回に限る）
  # パスだけを載せる書き方は拾わない。自由文字列との衝突を避けられる最小の形が
  # 「行頭アンカー + 実在検査」で、handoff もその形で出す（綴りの一致は suite が固定）。
  local line path prefix
  prefix="${ROOT}/${OUTPUT_DIR_NAME}/"
  while IFS= read -r line; do
    case "$line" in
      "${REVIEW_DELEGATION_MARKER}: "*) : ;;
      *) continue ;;
    esac
    path="${line#"${REVIEW_DELEGATION_MARKER}": }"
    # 前後の空白を落とす（handoff をそのまま貼ると字下げが付きうる）。
    path="${path#"${path%%[![:space:]]*}"}"
    path="${path%"${path##*[![:space:]]}"}"
    case "$path" in
      "${prefix}"*"/.delegated/"*".prompt.md") : ;;
      *) continue ;;
    esac
    [ -f "$path" ] || continue
    return 0
  done <<EOF
$1
EOF
  return 1
}

# tool_input の内容から決定的な鍵を作る。
lane_key() {
  local k
  # 記号を削るだけの正規化は使わない（sanitize_id と同じ潰し衝突が起きる。記号だけが違う
  # 2 つの tool_use_id が同じ鍵へ潰れると、取得の冪等判定が 2 本目を「既に在る」と読んで
  # レーンを 1 本落とし、1 本目の終端で凍結が解ける）。
  k="$(sanitize_id "$(printf '%s' "$input" | jq -r '.tool_use_id // ""' 2>/dev/null)")"
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

# レーンへ足す行（先頭に改行を付けて出す）。<レーンの型>
#   tree=<物理パス>   レビュー対象のツリー（複数可）。prompt が同じリポジトリの worktree を名指し
#                     していればそれ、無ければ cwd のツリー。ライブラリを読めない回も cwd のツリー
#   output_file=<パス> 委譲レビューの結果の書き先（handoff の request レコードの output-file=）
lane_extra_fields() { # <lane_type>
  local trees="" t prompt req of path
  prompt="$(printf '%s' "$input" | jq -r '.tool_input.prompt // ""' 2>/dev/null)" || prompt=""
  prompt="${prompt//$'\r'/}"  # Windows の jq.exe は改行を \r\n で出す（Issue `#2017`）
  if [ "$1" != "delegated-review" ]; then
    trees="$(ff_lane_infer_trees "$ROOT" "$prompt")" || trees=""
  fi
  [ -n "$trees" ] || trees="$(phys_dir "$ROOT")"
  while IFS= read -r t; do
    [ -n "$t" ] && printf '\ntree=%s' "$t"
  done <<EOF
$trees
EOF
  if [ "$1" = "delegated-review" ]; then
    while IFS= read -r path; do
      case "$path" in "${REVIEW_DELEGATION_MARKER}: "*) : ;; *) continue ;; esac
      path="${path#"${REVIEW_DELEGATION_MARKER}": }"
      path="${path#"${path%%[![:space:]]*}"}"
      path="${path%"${path##*[![:space:]]}"}"
      req="${path%.prompt.md}.request"
      of="$(sed -n 's/^output-file=//p' "$req" 2>/dev/null | head -n 1)"
      [ -n "$of" ] && printf '\noutput_file=%s' "$of"
      break
    done <<EOF
$prompt
EOF
  fi
  return 0
}

# ── C) レーンの取得・対応づけ・解放・走査 ─────────────────────────────────
LANE_LIVE=0
LANE_SUMMARY=""
LANE_RECLAIMED=0
LANE_DONE=0   # 委譲レビューの結果が書かれたので解放したレーン数
LANE_TREES="" # 生きているレーンの対象ツリー（物理パス。改行区切り）

acquire_lane() { # <subagent_type>
  local key head_sha now f tmp existing lane_body work
  [ "$LANE_SAFE" -eq 1 ] || return 0
  key="$(lane_key)"
  [ -n "$key" ] || return 0
  lane_prepare_output || return 0
  (umask 077; mkdir -p "$LANE_DIR") 2>/dev/null || return 0
  # mkdir 後にもう一度見る（作った先が symlink 越しでないこと）。
  lane_dir_is_safe || return 0
  # **鍵に対して冪等**にする。ハーネスには同じ `tool_use_id` で PreToolUse をもう一度流す
  # 再試行経路がある（auto mode の拒否に対して hook が `retry: true` を返す形）。冪等で
  # ないと 1 回の起動で 2 本開き、解放イベント 1 回では 1 本しか閉じずに残りが寿命まで
  # 凍結を維持する。
  for existing in "$LANE_DIR/$key".*.lane; do
    # 同じ鍵に特殊なleafが在る回も採用・上書きしない。
    { [ -e "$existing" ] || [ -L "$existing" ]; } && return 0
  done
  now="$(date -u +%s 2>/dev/null)"
  case "$now" in
    '' | *[!0-9]*) return 0 ;;
  esac
  head_sha="$(git -C "$ROOT" rev-parse --short=12 HEAD 2>/dev/null)"
  [ -n "$head_sha" ] || head_sha="n/a"
  f="${LANE_DIR}/${key}.${now}.$$.lane"
  work="$(lane_temp_dir)" || return 0
  [ -d "$work" ] && [ ! -L "$work" ] || return 0
  tmp="$(mktemp "${work}/body.XXXXXX" 2>/dev/null)" || { rmdir "$work" 2>/dev/null; return 0; }
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
  # 対象ツリー（Issue `#1760`。判定は tests/lib/review-lane-scope.sh）と、委譲レビューの結果の
  # 書き先（出現で完了とみなす。Issue `#1792`）を足す。無い行は従来どおり cwd のツリー・寿命で扱う。
  lane_body="${lane_body}$(lane_extra_fields "$1")"
  printf '%s\n' "$lane_body" > "$tmp" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    rmdir "$work" 2>/dev/null
    return 0
  }
  if lane_dir_is_safe && [ ! -e "$f" ] && [ ! -L "$f" ]; then
    mv "$tmp" "$f" 2>/dev/null || true
  fi
  rm -f "$tmp" 2>/dev/null
  rmdir "$work" 2>/dev/null
  return 0
}

# `SubagentStart` で agent_id をレーンへ書き込む（対応づけ）。ここでレーンを**新設はしない** —
# レーンを取るかどうかの判定材料（`isolation` / `subagent_type`）は `PreToolUse` にしか無く、
# `SubagentStart` のペイロードには載らないため（claude 2.1.267 の同梱実装で確認）。
adopt_lane() { # <agent_id（sanitize 済み）> <agent_type>
  local f t a e best best_e body tmp claimed tries work
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
      lane_file_is_safe "$f" || continue
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
    work="$(lane_temp_dir)" || return 0
    [ -d "$work" ] && [ ! -L "$work" ] || return 0
    claimed="${work}/claimed.lane"
    # claim先は排他的なnamespace内。取得後に中身を読むことで、別の採用者が先に
    # 公開したagent_idを古いbodyで上書きする競合も避ける。
    if ! lane_file_is_safe "$best" || ! mv "$best" "$claimed" 2>/dev/null; then
      rmdir "$work" 2>/dev/null
      continue
    fi
    if ! lane_file_is_safe "$claimed" || [ -n "$(lane_field "$claimed" agent_id)" ]; then
      mv "$claimed" "$best" 2>/dev/null || true
      rmdir "$work" 2>/dev/null
      continue
    fi
    body="$(sed 's/^agent_id=.*$/agent_id='"$1"'/' "$claimed" 2>/dev/null)"
    tmp="$(mktemp "${work}/body.XXXXXX" 2>/dev/null)" || {
      mv "$claimed" "$best" 2>/dev/null || true
      rmdir "$work" 2>/dev/null
      return 0
    }
    printf '%s\n' "$body" > "$tmp" 2>/dev/null || {
      rm -f "$tmp" 2>/dev/null
      mv "$claimed" "$best" 2>/dev/null || true
      rmdir "$work" 2>/dev/null
      return 0
    }
    if [ -n "$body" ] && lane_dir_is_safe && [ ! -e "$best" ] && [ ! -L "$best" ] \
      && mv "$tmp" "$best" 2>/dev/null; then
      rm -f "$claimed" 2>/dev/null
    else
      mv "$claimed" "$best" 2>/dev/null || true
    fi
    rm -f "$tmp" 2>/dev/null
    rmdir "$work" 2>/dev/null
    return 0
  done
  return 0
}

lane_tombstone() { # <パス（空なら何もしない）>
  local now work tmp
  [ -n "$1" ] || return 0
  # 既存leafを開かない。dangling linkも-eだけでは見つからない。
  { [ -e "$1" ] || [ -L "$1" ]; } && return 0
  now="$(date -u +%s 2>/dev/null)"
  case "$now" in
    '' | *[!0-9]*) now=0 ;;
  esac
  work="$(lane_temp_dir)" || return 0
  [ -d "$work" ] && [ ! -L "$work" ] || return 0
  tmp="$(mktemp "${work}/body.XXXXXX" 2>/dev/null)" || { rmdir "$work" 2>/dev/null; return 0; }
  if printf 'started_epoch=%s\n' "$now" > "$tmp" 2>/dev/null \
    && lane_dir_is_safe && [ ! -e "$1" ] && [ ! -L "$1" ]; then
    mv "$tmp" "$1" 2>/dev/null || true
  fi
  rm -f "$tmp" 2>/dev/null
  rmdir "$work" 2>/dev/null
  return 0
}

# `SubagentStop` の解放。**agent_id で対応づける**のが本体で、同型の最古 1 本という
# 弱い対応づけは「対応づいていないレーンしか無い」場合のフォールバックにだけ残す。
release_lane_by_agent() { # <agent_id> <agent_type>
  local id type f a t e best best_e claimed tomb tries work
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
    { [ -e "$tomb" ] || [ -L "$tomb" ]; } && return 0
  fi
  tries=0
  while [ "$tries" -lt 5 ]; do
    tries=$((tries + 1))
    best=""
    best_e=""
    # 1) agent_id が一致するレーン（`SubagentStart` で対応づけ済み）
    if [ -n "$id" ]; then
      for f in "$LANE_DIR"/*.lane; do
        lane_file_is_safe "$f" || continue
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
        lane_file_is_safe "$f" || continue
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
    work="$(lane_temp_dir)" || return 0
    [ -d "$work" ] && [ ! -L "$work" ] || return 0
    claimed="${work}/claimed.lane"
    if ! lane_file_is_safe "$best" || ! mv "$best" "$claimed" 2>/dev/null; then
      rmdir "$work" 2>/dev/null
      continue
    fi
    rm -f "$claimed" 2>/dev/null
    rmdir "$work" 2>/dev/null
    lane_tombstone "$tomb"
    break
  done
  return 0
}

# 鍵が一致し、かつ**まだ対応づいていない**レーンを 1 本だけ閉じる（`PermissionDenied` 用）。
# 対応づけ済み = サブエージェントは実際に起動しているので、拒否イベントで閉じてはいけない。
release_lane_by_key() {
  local key f a found claimed tries work
  [ "$LANE_SAFE" -eq 1 ] || return 0
  key="$(lane_key)"
  [ -n "$key" ] || return 0
  [ -d "$LANE_DIR" ] || return 0
  tries=0
  while [ "$tries" -lt 5 ]; do
    tries=$((tries + 1))
    found=""
    for f in "$LANE_DIR/$key".*.lane; do
      lane_file_is_safe "$f" || continue
      a="$(lane_field "$f" agent_id)"
      [ -z "$a" ] || continue
      found="$f"
      break
    done
    [ -n "$found" ] || break
    work="$(lane_temp_dir)" || return 0
    [ -d "$work" ] && [ ! -L "$work" ] || return 0
    claimed="${work}/claimed.lane"
    if ! lane_file_is_safe "$found" || ! mv "$found" "$claimed" 2>/dev/null; then
      rmdir "$work" 2>/dev/null
      continue
    fi
    rm -f "$claimed" 2>/dev/null
    rmdir "$work" 2>/dev/null
    break
  done
  return 0
}

# 走行中のレーンを数える。上限より古い（または未来へ大きくずれた）レーンはその場で
# 削除する — 解放イベントを取りこぼしても凍結が永続しないための出口。**回収したことは
# 黙って済ませない**（LANE_RECLAIMED を立て、呼び出し側が systemMessage を出す）。
lane_remove_public_snapshot() {
  local current
  lane_file_is_safe "$1" || return 1
  current="$(cat "$1" 2>/dev/null)" || return 1
  [ "$current" = "$2" ] || return 1
  rm -f "$1" 2>/dev/null
}

lane_scan_record() { # ff_lane_visit_recordsのローカルcallback。2はbody更新の再走査。
  local f="$1" kind="$2" body="$3" e t a age limit of lt claim_note=''
  if [ "$kind" = unstable ]; then
    LANE_LIVE=$((LANE_LIVE + 1))
    LANE_TREES="${LANE_TREES}$(phys_dir "$ROOT")
"
    LANE_SUMMARY="${LANE_SUMMARY}  - レーンの移動中（記録を安定して読めないため保守的に凍結）
"
    return 0
  fi
  e="$(ff_lane_body_field "$body" started_epoch)"
  case "$e" in
    '' | *[!0-9]*)
      if [ "$kind" = public ]; then
        lane_remove_public_snapshot "$f" "$body" || return 2
        LANE_RECLAIMED=$((LANE_RECLAIMED + 1))
      fi
      return 0 ;;
  esac
  a="$(ff_lane_body_field "$body" agent_id)"
  limit="$(ff_lane_record_limit "$kind" "$a" "$LANE_MAX_AGE" "$LANE_PENDING_MAX_AGE")"
  age=$((lane_scan_now - e))
  if [ "$age" -gt "$limit" ] || [ "$age" -lt -300 ]; then
    if [ "$kind" = public ]; then
      lane_remove_public_snapshot "$f" "$body" || return 2
      LANE_RECLAIMED=$((LANE_RECLAIMED + 1))
    fi
    return 0
  fi
  of="$(ff_lane_body_field "$body" output_file)"
  if [ -n "$of" ] && [ -f "$of" ] && [ "$of" -nt "$f" ]; then
    if [ "$kind" = public ]; then
      lane_remove_public_snapshot "$f" "$body" || return 2
      LANE_DONE=$((LANE_DONE + 1))
    fi
    return 0
  fi
  t="$(ff_lane_body_field "$body" perspectives)"
  lt="$(printf '%s\n' "$body" | sed -n 's/^tree=//p')"
  [ -n "$lt" ] || lt="$(phys_dir "$ROOT")"
  LANE_TREES="${LANE_TREES}${lt}
"
  LANE_LIVE=$((LANE_LIVE + 1))
  [ "$kind" != claim ] || claim_note=' / 採用中claim'
  LANE_SUMMARY="${LANE_SUMMARY}  - ${t:-unknown}（経過 ${age} 秒${a:+ / 対応づけ済み}${claim_note} / 対象 $(printf '%s' "$lt" | tr '\n' ' ')）
"
  return 0
}

scan_lanes() {
  local f e lane_scan_now
  [ "$LANE_SAFE" -eq 1 ] || return 0
  [ -d "$LANE_DIR" ] || return 0
  lane_scan_now="$(date -u +%s 2>/dev/null)"
  case "$lane_scan_now" in
    '' | *[!0-9]*) return 0 ;;
  esac
  ff_lane_visit_records "$LANE_DIR" lane_scan_record 1
  # 中断された claim / tmp と、解放済み agent_id の記録も同じ上限で片づける。
  # `started_epoch` が読めないものは**残す** — 書込み途中の tmp を消すと、書き手の
  # rename が失敗してレーンが 1 本も立たなくなる（atomic publish が壊れる）。
  for f in "$LANE_DIR"/*.claim.* "$LANE_DIR"/*.tmp.* "$LANE_DIR"/.done.*; do
    lane_file_is_safe "$f" || continue
    e="$(lane_field "$f" started_epoch)"
    case "$e" in
      '' | *[!0-9]*) continue ;;
    esac
    [ "$((lane_scan_now - e))" -gt "$LANE_MAX_AGE" ] && rm -f "$f" 2>/dev/null
  done
  # **空になっても LANE_DIR は rmdir しない。** 消すと、同時に走る acquire_lane が
  # mkdir 済みのはずの置き場を失い、一時ファイルを作れずにレーンを落とす（同時取得を
  # 走らせて実測した）。空ディレクトリは git の追跡対象にならず、dirty 判定からも
  # pathspec で外してあるので、残しておく害は無い。
  return 0
}

# ── C の対応づけ / 解放イベント（ここで終わる入口。permissionDecision は出さない） ──
# 対応づけ・解放の経路ごとに、何で絞るかが違う。
#   - `SubagentStart` / `SubagentStop`: 名簿で絞る（従来どおり）。これらは相関 ID を持たず、
#     対応づけは「agent_id 一致」か「同型で対応づいていない最古のレーン」なので、絞りを
#     外すと無関係なサブエージェントの終端が別レーンを閉じうる。委譲レビューのレーンは
#     専用の型名で記帳してあり、どの agent_type とも一致しないので、ここを通らない。
#   - `PermissionDenied`: 名簿で絞らない。委譲レビューは汎用の subagent_type で起動される
#     ため名簿に載らず、絞ると**起動が拒否された委譲レビューのレーンだけが解放されない**。
#     この経路は `tool_use_id`（無ければ tool_input のハッシュ）で対応づくので、型で
#     絞らなくても別レーンを掴まない。
if [ "$EVENT" = "SubagentStart" ]; then
  agent_type="$(printf '%s' "$input" | jq -r '.agent_type // ""' 2>/dev/null)"
  agent_id="$(printf '%s' "$input" | jq -r '.agent_id // ""' 2>/dev/null)"
  is_review_lock_type "$agent_type" && adopt_lane "$(sanitize_id "$agent_id")" "$agent_type"
  exit 0
fi

if [ "$EVENT" = "SubagentStop" ]; then
  agent_type="$(printf '%s' "$input" | jq -r '.agent_type // ""' 2>/dev/null)"
  agent_id="$(printf '%s' "$input" | jq -r '.agent_id // ""' 2>/dev/null)"
  is_review_lock_type "$agent_type" && release_lane_by_agent "$agent_id" "$agent_type"
  exit 0
fi

if [ "$EVENT" = "PermissionDenied" ]; then
  case "$tool" in
    Agent | Task) : ;;
    *) exit 0 ;;
  esac
  release_lane_by_key
  # D) ask で仮記録した巡を取り消す（起動しなかった回に巡を消費させない）
  ROUND_LIB="${BASH_SOURCE[0]%/*}/review-round-counter.sh"
  # shellcheck source=review-round-counter.sh
  if [ -r "$ROUND_LIB" ] && . "$ROUND_LIB" 2>/dev/null && [ "$(type -t ff_review_round_cancel 2>/dev/null)" = "function" ]; then
    ff_review_round_cancel "$ROOT" "$(lane_key)"
  fi
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
# 別 worktree（レビューを起動したセッションの cwd）に置かれ、このツリーを対象とするレーンも数える
# （Issue `#1935`。判定は tests/lib/review-lane-scope.sh。読めない回は従来どおり自分の置き場だけ）。
if [ "$LANE_SAFE" -eq 1 ]; then
  me_phys="$(phys_dir "$ROOT")"
  if [ -n "$me_phys" ] && foreign="$(ff_lane_foreign_live "$ROOT" "$me_phys" "$LANE_MAX_AGE" "$LANE_PENDING_MAX_AGE")"; then
    while IFS='	' read -r ft fa fw; do
      [ -n "$fw" ] || continue
      LANE_LIVE=$((LANE_LIVE + 1))
      LANE_TREES="${LANE_TREES}${me_phys}
"
      LANE_SUMMARY="${LANE_SUMMARY}  - ${ft:-unknown}（経過 ${fa} 秒 / 置き場 ${fw}）
"
    done <<EOF
$foreign
EOF
  fi
fi

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
  lane_target=0
  lane_type="$subagent"
  if is_review_lock_type "$subagent"; then
    lane_target=1
  else
    # 名簿外でも、委譲レビュー（--delegate-to-host）の起動ならレーンを取る。判定材料は
    # prompt だけなので、取れない版のハーネスでは何も起きない（fail-open）。
    agent_prompt="$(printf '%s' "$input" | jq -r '.tool_input.prompt // ""' 2>/dev/null)" || agent_prompt=""
    agent_prompt="${agent_prompt//$'\r'/}"  # Windows の jq.exe は改行を \r\n で出す（Issue `#2017`）
    if [ -n "$agent_prompt" ] && is_delegated_review_prompt "$agent_prompt"; then
      lane_target=1
      # 委譲レビューのレーンは**専用の型名**で記帳する。汎用の subagent_type をそのまま
      # 書くと、無関係な同型サブエージェントの `SubagentStart` / `SubagentStop` が
      # 「同型で対応づいていない最古のレーン」フォールバックでこのレーンを奪い、
      # レビューが走っている最中に凍結が解ける（実測）。この型名はどの agent_type とも
      # 一致しないので、フォールバックの対象にならない。
      # その結果このレーンは agent 系イベントでは解放されない（`SubagentStop` に相関 ID が
      # 無く、汎用型では正しい委譲先を識別できないので、早く解ける側へ倒さない）。
      # 出口は 3 つ: 起動が拒否された回は `PermissionDenied` の同一鍵、正常に終わった回は
      # **委譲結果の回収**（multi-agent.sh の collect_delegated_responses。scripts/lib/multi-agent-execute.sh。回収の到達が
      # 「委譲したレビューは終わった」の宣言）、どちらも来なければ未対応レーンの寿命上限。
      lane_type="delegated-review"
    fi
  fi
  if [ "$lane_target" -eq 1 ]; then
    # 巡の上限はレーンを取る前に判定する（deny した起動にレーンを残さない）。隔離起動も数える。
    review_round_gate agent
    case "$isolation" in
      # 隔離起動のレビュアーは親と作業ツリーを共有しないので凍結の対象外
      # （加えて、隔離 worktree 内で変異注入を行うレビュアーの自己デッドロックを避ける）
      worktree) : ;;
      *) acquire_lane "$lane_type" ;;
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
[ "$tool" = "Bash" ] && review_round_gate bash
is_review_lock_type "$caller_agent_type" && exit 0

# 走行中とみなせる材料が 1 つも無ければ従来どおり無音で通す。stale なロックが残って
# いるだけの場合と、この呼び出しでレーンを回収した場合は、下で警告のみを出す経路へ進む。
if [ "$lock_live" -ne 1 ] && [ "$LANE_LIVE" -eq 0 ] && [ -z "$lock_stale_reason" ] \
  && [ "$LANE_RECLAIMED" -eq 0 ] && [ "$LANE_DONE" -eq 0 ]; then
  exit 0
fi

# 凍結の対象ツリー（Issue `#1760`）。A のロックは cwd のツリー（multi-agent.sh はそのツリーで走る）、
# C のレーンは記録した対象ツリー。書き込み先の包含はこの集合で判定し、cwd のツリーが集合に無い
# （別 worktree のレビューだけが走っている）ときは cwd での git 書き込みも・判定不能な書き込みも
# 止めない。止めるのは対象ツリーを名指しする書き込みだけ。
ROOT_PHYS_G="$(phys_dir "$ROOT")"
[ -n "$ROOT_PHYS_G" ] || ROOT_PHYS_G="$ROOT"
PROTECT_TREES="$(printf '%s\n' "$LANE_TREES" | awk 'NF')"
[ "$lock_live" -eq 1 ] && PROTECT_TREES="${ROOT_PHYS_G}
${PROTECT_TREES}"
# 生きている材料があるのに集合が空（物理パスを引けなかった）なら cwd のツリーへ倒す
if [ -z "$PROTECT_TREES" ] && { [ "$lock_live" -eq 1 ] || [ "$LANE_LIVE" -gt 0 ]; }; then
  PROTECT_TREES="$ROOT_PHYS_G"
fi
within_protected() { # <物理パス> → どれかの対象ツリーの中か
  local t
  [ -n "$1" ] || return 0
  while IFS= read -r t; do
    [ -n "$t" ] && path_within "$1" "$t" && return 0
  done <<EOF
$PROTECT_TREES
EOF
  return 1
}
in_protected() { # <物理パス（ツリーの toplevel）>
  local t
  while IFS= read -r t; do
    [ -n "$t" ] && [ "$t" = "$1" ] && return 0
  done <<EOF
$PROTECT_TREES
EOF
  return 1
}
_ff_review_in_flight_judge_loaded=1
