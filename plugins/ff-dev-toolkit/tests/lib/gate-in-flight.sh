#!/usr/bin/env bash
#
# 全件ゲート（tests/run-all.sh・単体起動の tests/public-layout/verify.sh）の
# 走行中マーカー（<git-dir>/ff-dev-toolkit/run-all-in-flight/<PID>）の書込・生存判定・回収。
#
# tests/run-all.sh の並走早期停止と、PreToolUse ガード hooks/guard-gate-in-flight.sh が
# 同じ関数 ff_gate_marker_status（別名 ff_gate_marker_is_live）で生存を判定し、
# 死んだ PID・再利用 PID の残骸マーカーで止めないための共通ライブラリ。
#
# マーカー形式:
#   <dir>/<PID>       1 行目: `LC_ALL=C TZ=UTC0 ps -o lstart= -p <PID>` の生出力
#                     （tests/effort-contract が抽出する ff_gate_marker_nested 互換のため 1 行に保つ）
#   <dir>/<PID>.meta  任意の補足情報（`label=...` / `tree=...`）
#
# 互換性: bash 3.2（stock macOS）互換。連想配列・readarray・=~・環境分岐は使わない。

ff_gate_marker_dir() { # <git_dir> -> stdout: <git_dir>/ff-dev-toolkit/run-all-in-flight
  local gdir="${1%/}"
  [ -n "$gdir" ] || return 1
  printf '%s/ff-dev-toolkit/run-all-in-flight' "$gdir"
}

ff_gate_phys_dir() {
  (CDPATH='' cd -P -- "$1" 2>/dev/null && pwd -P 2>/dev/null)
}

ff_gate_ps_lstart() { # <pid> -> stdout: UTC lstart 文字列（取得不能なら非 0）
  local pid="${1:-}" out=""
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  out="$(LC_ALL=C TZ=UTC0 ps -o lstart= -p "$pid" 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

ff_gate_marker_meta_field() { # <meta_file> <field>
  local meta="$1" field="$2" line=""
  [ ! -L "$meta" ] && [ -f "$meta" ] && [ -r "$meta" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "${field}="*)
        printf '%s' "${line#"${field}="}"
        return 0
        ;;
    esac
  done < "$meta"
  return 1
}

# マーカー 1 件の生存判定（共有の正本）。
# 引数: <marker_file>
# 戻り値:
#   0 = 生存中（PID が存在し、ps の lstart が 1 行目と一致）
#   1 = 非生存・残骸・消失済み（死んだ PID / 別プロセスへ再利用された PID / 空の壊れた通常ファイル / 走査中に正常終了で消えた通常ファイル。回収してよい）
#   2 = 判定不能（symlink・実在するが読めない・生きた PID に対して ps が lstart を返さない。削除しない）
# 出力変数（rc=0 時）:
#   GATE_MARKER_PID / GATE_MARKER_START / GATE_MARKER_LABEL / GATE_MARKER_TREE
ff_gate_marker_status() { # <marker_file>
  local f="${1:-}" base="" want="" have="" kill_ok=0 kill_err="" meta="" lbl="" tr=""
  GATE_MARKER_PID=""
  GATE_MARKER_START=""
  GATE_MARKER_LABEL=""
  GATE_MARKER_TREE=""

  [ -n "$f" ] || return 1
  if [ -L "$f" ]; then
    return 2
  fi
  [ -f "$f" ] || return 1
  base="${f##*/}"
  case "$base" in
    '' | *[!0-9]*) return 2 ;;
  esac
  if [ ! -r "$f" ]; then
    # 走査〜読み取り間の正常終了でマーカーが消えた（TOCTOU）場合は非生存として扱う
    # symlink や実在するが読めない通常ファイルは fail-closed（return 2）を保つ
    [ -L "$f" ] && return 2
    [ -e "$f" ] || return 1
    return 2
  fi

  if ! IFS= read -r want < "$f" 2>/dev/null; then
    if [ -L "$f" ]; then
      return 2
    fi
    if [ ! -e "$f" ]; then
      return 1
    fi
    if [ ! -r "$f" ]; then
      return 2
    fi
    # 実在して読めるのに read が非 0（末尾改行なし・空ファイル）なら want の値のまま判定を続ける
  fi
  want="${want%"$(printf '\r')"}"

  if kill_err="$(LC_ALL=C kill -0 "$base" 2>&1)"; then
    kill_ok=1
  fi

  if [ "$kill_ok" -eq 1 ]; then
    have="$(ff_gate_ps_lstart "$base" 2>/dev/null || true)"
    if [ -z "$have" ]; then
      # kill -0 〜 ps の間にプロセスが終了した（TOCTOU）場合は再確認して非生存へ逃がす
      if ! kill_err="$(LC_ALL=C kill -0 "$base" 2>&1)"; then
        case "$kill_err" in
          *[Pp]ermission* | *[Pp]ermitted* | *EPERM*) return 2 ;;
          *) return 1 ;;
        esac
      fi
      # プロセスは存在するが ps が lstart を返せない場合は回収せず判定不能に倒す
      return 2
    fi
    # 空または開始時刻不一致は再利用 PID または不完全マーカー（残骸）
    [ -n "$want" ] && [ "$want" = "$have" ] || return 1
  else
    case "$kill_err" in
      *[Pp]ermission* | *[Pp]ermitted* | *EPERM*)
        have="$(ff_gate_ps_lstart "$base" 2>/dev/null || true)"
        if [ -z "$have" ]; then
          if ! kill_err="$(LC_ALL=C kill -0 "$base" 2>&1)"; then
            case "$kill_err" in
              *[Pp]ermission* | *[Pp]ermitted* | *EPERM*) return 2 ;;
              *) return 1 ;;
            esac
          fi
          return 2
        fi
        [ -n "$want" ] && [ "$want" = "$have" ] || return 1
        ;;
      *)
        # kill -0 が ESRCH で失敗したときはカーネル上で PID が存在しないため残骸と確定
        return 1
        ;;
    esac
  fi

  meta="${f}.meta"
  lbl="$(ff_gate_marker_meta_field "$meta" label 2>/dev/null || true)"
  tr="$(ff_gate_marker_meta_field "$meta" tree 2>/dev/null || true)"
  [ -n "$tr" ] && tr="$(ff_gate_phys_dir "$tr" || printf '%s' "$tr")"
  GATE_MARKER_PID="$base"
  GATE_MARKER_START="$want"
  GATE_MARKER_LABEL="${lbl:-tests/run-all.sh}"
  GATE_MARKER_TREE="$tr"
  return 0
}

ff_gate_marker_is_live() { # <marker_file>
  ff_gate_marker_status "${1:-}"
}

ff_gate_pid_in_self_lineage() { # <target_pid> -> 0 if target == self or ancestor of self
  local target="${1:-}" cur="$$" i=0 p=""
  case "$target" in '' | *[!0-9]*) return 1 ;; esac
  [ "$target" = "$cur" ] && return 0
  cur="$PPID"
  while [ "$i" -lt 64 ]; do
    case "$cur" in '' | *[!0-9]*) return 1 ;; esac
    [ "$cur" -gt 1 ] || return 1
    [ "$cur" = "$target" ] && return 0
    p="$(ps -o ppid= -p "$cur" 2>/dev/null | tr -d '[:space:]')" || return 1
    cur="$p"
    i=$((i + 1))
  done
  return 1
}

# 1 つの run-all-in-flight ディレクトリを走査し、非生存マーカーを掃除して生存一覧を集める。
# 出力変数: GATE_LIVE_LINES（`<pid>:<label>` 改行区切り）/ GATE_LIVE_PIDS / GATE_LIVE_TREES
#           GATE_UNKNOWN_LINES / GATE_RECLAIMED_COUNT / GATE_DIR_UNSAFE
ff_gate_marker_sweep_dir() { # <marker_dir> [exclude_self_lineage=0] [fallback_tree]
  local dir="${1:-}" excl="${2:-0}" fb_tree="${3:-}"
  local f="" base="" st=0 tree_val="" fb_tree_resolved=0
  GATE_LIVE_LINES=""
  GATE_LIVE_PIDS=""
  GATE_LIVE_TREES=""
  GATE_UNKNOWN_LINES=""
  GATE_UNKNOWN_TREES=""
  GATE_RECLAIMED_COUNT=0
  GATE_DIR_UNSAFE=0

  [ -n "$dir" ] || return 0
  if [ -L "$dir" ]; then
    GATE_DIR_UNSAFE=1
    GATE_UNKNOWN_LINES="unsafe-dir:${dir}"
    if [ -n "$fb_tree" ]; then
      fb_tree="$(ff_gate_phys_dir "$fb_tree" || printf '%s' "$fb_tree")"
      GATE_UNKNOWN_TREES="$fb_tree"
    fi
    return 1
  fi
  [ -e "$dir" ] || return 0
  if [ ! -d "$dir" ]; then
    GATE_DIR_UNSAFE=1
    GATE_UNKNOWN_LINES="unsafe-dir:${dir}"
    if [ -n "$fb_tree" ]; then
      fb_tree="$(ff_gate_phys_dir "$fb_tree" || printf '%s' "$fb_tree")"
      GATE_UNKNOWN_TREES="$fb_tree"
    fi
    return 1
  fi

  for f in "$dir"/*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    base="${f##*/}"
    case "$base" in
      '' | *[!0-9]*) continue ;;
    esac
    st=0
    ff_gate_marker_status "$f" || st=$?
    case "$st" in
      0)
        if [ "$excl" = "1" ] && ff_gate_pid_in_self_lineage "$GATE_MARKER_PID"; then
          continue
        fi
        GATE_LIVE_LINES="${GATE_LIVE_LINES:+${GATE_LIVE_LINES}
}${GATE_MARKER_PID}:${GATE_MARKER_LABEL}"
        GATE_LIVE_PIDS="${GATE_LIVE_PIDS:+${GATE_LIVE_PIDS} }${GATE_MARKER_PID}"
        tree_val="$GATE_MARKER_TREE"
        if [ -z "$tree_val" ] && [ -n "$fb_tree" ]; then
          if [ "$fb_tree_resolved" -eq 0 ]; then
            fb_tree="$(ff_gate_phys_dir "$fb_tree" || printf '%s' "$fb_tree")"
            fb_tree_resolved=1
          fi
          tree_val="$fb_tree"
        fi
        if [ -n "$tree_val" ]; then
          GATE_LIVE_TREES="${GATE_LIVE_TREES:+${GATE_LIVE_TREES}
}${tree_val}"
        fi
        ;;
      1)
        # 走査中に他プロセスが消したマーカー（TOCTOU）は本プロセスが回収したわけではないため件数に含めない
        if [ -e "$f" ] || [ -e "${f}.meta" ] || [ -L "${f}.meta" ]; then
          rm -f -- "$f" "${f}.meta" 2>/dev/null || true
          GATE_RECLAIMED_COUNT=$((GATE_RECLAIMED_COUNT + 1))
        fi
        ;;
      *)
        if [ "$excl" = "1" ] && ff_gate_pid_in_self_lineage "$base"; then
          continue
        fi
        GATE_UNKNOWN_LINES="${GATE_UNKNOWN_LINES:+${GATE_UNKNOWN_LINES}
}${base}:${f}"
        if [ -n "$fb_tree" ]; then
          if [ "$fb_tree_resolved" -eq 0 ]; then
            fb_tree="$(ff_gate_phys_dir "$fb_tree" || printf '%s' "$fb_tree")"
            fb_tree_resolved=1
          fi
          GATE_UNKNOWN_TREES="${GATE_UNKNOWN_TREES:+${GATE_UNKNOWN_TREES}
}${fb_tree}"
        fi
        ;;
    esac
  done
  for f in "$dir"/*.meta; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    [ -e "${f%.meta}" ] || rm -f -- "$f" 2>/dev/null || true
  done
  return 0
}

ff_gate_marker_write() { # <git_dir> <label> [tree_root] -> stdout: 書き込んだマーカーパス
  local gdir="${1:-}" label="${2:-tests/run-all.sh}" tree="${3:-}"
  local dir="" start="" tmp="" mtmp=""
  [ -n "$gdir" ] || return 1
  [ -n "$tree" ] && tree="$(ff_gate_phys_dir "$tree" || printf '%s' "$tree")"
  dir="$(ff_gate_marker_dir "$gdir")" || return 1
  [ ! -L "$dir" ] || return 1
  mkdir -p "$dir" 2>/dev/null || return 1
  [ ! -L "$dir" ] && [ -d "$dir" ] || return 1

  ff_gate_marker_sweep_dir "$dir" 0 "$tree" >/dev/null 2>&1 || true

  start="$(ff_gate_ps_lstart "$$" 2>/dev/null)" || return 1
  [ -n "$start" ] || return 1

  tmp="$dir/.tmp.$$"
  mtmp="$dir/.tmp.$$.meta"
  rm -f -- "$tmp" "$mtmp" 2>/dev/null || true
  if printf '%s\n' "$start" > "$tmp" 2>/dev/null && mv -f -- "$tmp" "$dir/$$" 2>/dev/null; then
    if [ -n "$tree" ]; then
      printf 'label=%s\ntree=%s\n' "$label" "$tree" > "$mtmp" 2>/dev/null && mv -f -- "$mtmp" "$dir/$$.meta" 2>/dev/null || rm -f -- "$mtmp" 2>/dev/null || true
    else
      printf 'label=%s\n' "$label" > "$mtmp" 2>/dev/null && mv -f -- "$mtmp" "$dir/$$.meta" 2>/dev/null || rm -f -- "$mtmp" 2>/dev/null || true
    fi
    printf '%s' "$dir/$$"
    return 0
  fi
  rm -f -- "$tmp" "$mtmp" "$dir/$$.meta" 2>/dev/null || true
  return 1
}

ff_gate_marker_remove() { # <marker_file>
  local f="${1:-}"
  [ -n "$f" ] || return 0
  rm -f -- "$f" "${f}.meta" 2>/dev/null || true
}

# リポジトリの全 worktree 配下の run-all-in-flight を走査する。
# 引数: <repo_dir> [exclude_self_lineage=0] [pre_gdir] [pre_cdir] [pre_top]
#   - pre_gdir と pre_cdir の両方が絶対パスで渡された場合のみ冒頭の git rev-parse を省略する。
#     pre_top も同じ rev-parse で得た値を渡すと current git dir 側の git 呼び出しも 0 回にできる（pre_top は検証しない）。
#   - wt_root は論理パスのまま ff_gate_marker_sweep_dir へ渡し、live / unknown / unsafe 発生時だけ遅延で物理パス化する。
# 出力変数: GATE_LIVE_LINES / GATE_LIVE_PIDS / GATE_LIVE_TREES / GATE_UNKNOWN_LINES / GATE_UNKNOWN_TREES
#           GATE_RECLAIMED_COUNT / GATE_DIR_UNSAFE / GATE_SCAN_GIT_DIR / GATE_SCAN_COMMON_DIR / GATE_SCAN_TOP
ff_gate_scan_repo_worktree_markers() { # <repo_dir> [exclude_self_lineage=0] [pre_gdir] [pre_cdir] [pre_top]
  local repo_dir="${1:-}" excl="${2:-0}" gdir="${3:-}" cdir="${4:-}" cur_top="${5:-}"
  local mdir="" wt="" wt_root="" gf="" rp_out="" _cand_top="" _cand_gd="" _cand_cd=""
  local all_live="" all_pids="" all_trees="" all_unknown="" all_utrees="" total_reclaimed=0
  local -a dir_mds=() dir_fbs=()
  GATE_LIVE_LINES=""
  GATE_LIVE_PIDS=""
  GATE_LIVE_TREES=""
  GATE_UNKNOWN_LINES=""
  GATE_UNKNOWN_TREES=""
  GATE_RECLAIMED_COUNT=0
  GATE_DIR_UNSAFE=0
  GATE_SCAN_GIT_DIR=""
  GATE_SCAN_COMMON_DIR=""
  GATE_SCAN_TOP=""
  [ -n "$repo_dir" ] || return 0

  # 事前解決値は絶対パスかつ改行なしであることを検証し、満たさない場合は再解決する
  case "$gdir" in
    /* | [A-Za-z]:/*)
      case "$gdir" in *$'\n'*) gdir="" ;; esac
      ;;
    *) gdir="" ;;
  esac
  case "$cdir" in
    /* | [A-Za-z]:/*)
      case "$cdir" in *$'\n'*) cdir="" ;; esac
      ;;
    *) cdir="" ;;
  esac

  if [ -z "$gdir" ] || [ -z "$cdir" ]; then
    gdir=""
    cdir=""
    if rp_out="$(git -C "$repo_dir" rev-parse --path-format=absolute --show-toplevel --git-dir --git-common-dir 2>/dev/null)"; then
      case "$rp_out" in
        *$'\n'*$'\n'*)
          _cand_top="${rp_out%%$'\n'*}"
          _cand_top="${_cand_top%$'\r'}"
          rp_out="${rp_out#*$'\n'}"
          _cand_gd="${rp_out%%$'\n'*}"
          _cand_gd="${_cand_gd%$'\r'}"
          _cand_cd="${rp_out#*$'\n'}"
          _cand_cd="${_cand_cd%$'\r'}"
          case "$_cand_top" in /* | [A-Za-z]:/*)
            case "$_cand_gd" in /* | [A-Za-z]:/*)
              case "$_cand_cd" in
                *$'\n'*) : ;;
                /* | [A-Za-z]:/*)
                  cur_top="$_cand_top"
                  gdir="$_cand_gd"
                  cdir="$_cand_cd"
                  ;;
              esac
            ;; esac
          ;; esac
          ;;
      esac
    fi
    if [ -z "$gdir" ] || [ -z "$cdir" ]; then
      gdir="$(git -C "$repo_dir" rev-parse --absolute-git-dir 2>/dev/null)" || gdir=""
      gdir="${gdir%$'\r'}"
      cdir="$(git -C "$repo_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || cdir=""
      cdir="${cdir%$'\r'}"
      case "$cdir" in
        /* | [A-Za-z]:/*) : ;;
        *) cdir="" ;;
      esac
      if [ -z "$cdir" ] && [ -n "$gdir" ]; then
        cdir="$gdir"
      fi
      [ -n "$cur_top" ] || cur_top="$(git -C "$repo_dir" rev-parse --show-toplevel 2>/dev/null || true)"
      cur_top="${cur_top%$'\r'}"
    fi
  fi
  [ -n "$cdir" ] || return 0
  GATE_SCAN_GIT_DIR="$gdir"
  GATE_SCAN_COMMON_DIR="$cdir"
  GATE_SCAN_TOP="$cur_top"

  add_dir() {
    local d="$1" t="$2" _existing=""
    [ -n "$d" ] || return 0
    # 存在せず symlink でもないマーカー領域は 0 fork でスキップ（symlink / 壊れたファイルは走査へ渡す）
    [ -e "$d" ] || [ -L "$d" ] || return 0
    for _existing in "${dir_mds[@]+"${dir_mds[@]}"}"; do
      [ "$_existing" = "$d" ] && return 0
    done
    dir_mds+=("$d")
    dir_fbs+=("$t")
  }

  # main git dir
  if [ -n "$cdir" ]; then
    mdir="${cdir%/}/ff-dev-toolkit/run-all-in-flight"
    if [ -e "$mdir" ] || [ -L "$mdir" ]; then
      wt_root=""
      if [ "${cdir##*/}" = ".git" ]; then
        wt_root="${cdir%/.git}"
      fi
      add_dir "$mdir" "$wt_root"
    fi
  fi
  # current git dir
  if [ -n "$gdir" ] && [ "$gdir" != "$cdir" ]; then
    mdir="${gdir%/}/ff-dev-toolkit/run-all-in-flight"
    if [ -e "$mdir" ] || [ -L "$mdir" ]; then
      wt_root="$cur_top"
      [ -n "$wt_root" ] || wt_root="$(git -C "$repo_dir" rev-parse --show-toplevel 2>/dev/null || true)"
      add_dir "$mdir" "$wt_root"
    fi
  fi
  # linked worktrees
  if [ -d "${cdir}/worktrees" ]; then
    for wt in "${cdir}/worktrees"/*; do
      [ -d "$wt" ] || continue
      mdir="${wt%/}/ff-dev-toolkit/run-all-in-flight"
      [ -e "$mdir" ] || [ -L "$mdir" ] || continue
      wt_root=""
      if [ -f "$wt/gitdir" ] && [ -r "$wt/gitdir" ]; then
        IFS= read -r gf < "$wt/gitdir" 2>/dev/null || gf=""
        gf="${gf%$'\r'}"
        if [ -n "$gf" ]; then
          # git worktree add --relative-paths では gitdir が $wt 基準の相対パスになるため絶対化する
          case "$gf" in
            /* | [A-Za-z]:/*) wt_root="${gf%/.git}" ;;
            *) wt_root="${wt%/}/${gf%/.git}" ;;
          esac
        fi
      fi
      add_dir "$mdir" "$wt_root"
    done
  fi

  local _idx=0 _cnt="${#dir_mds[@]}" md="" fb="" dir_unsafe=0
  while [ "$_idx" -lt "$_cnt" ]; do
    md="${dir_mds[$_idx]}"
    fb="${dir_fbs[$_idx]}"
    _idx=$((_idx + 1))
    [ -n "$md" ] || continue
    if ! ff_gate_marker_sweep_dir "$md" "$excl" "$fb" >/dev/null 2>&1; then
      dir_unsafe=1
    fi
    total_reclaimed=$((total_reclaimed + GATE_RECLAIMED_COUNT))
    [ -z "$GATE_LIVE_LINES" ] || all_live="${all_live:+${all_live}
}${GATE_LIVE_LINES}"
    [ -z "$GATE_LIVE_PIDS" ] || all_pids="${all_pids:+${all_pids} }${GATE_LIVE_PIDS}"
    [ -z "$GATE_LIVE_TREES" ] || all_trees="${all_trees:+${all_trees}
}${GATE_LIVE_TREES}"
    [ -z "$GATE_UNKNOWN_LINES" ] || all_unknown="${all_unknown:+${all_unknown}
}${GATE_UNKNOWN_LINES}"
    [ -z "$GATE_UNKNOWN_TREES" ] || all_utrees="${all_utrees:+${all_utrees}
}${GATE_UNKNOWN_TREES}"
  done
  GATE_LIVE_LINES="$all_live"
  GATE_LIVE_PIDS="$all_pids"
  GATE_LIVE_TREES="$all_trees"
  GATE_UNKNOWN_LINES="$all_unknown"
  GATE_UNKNOWN_TREES="$all_utrees"
  GATE_RECLAIMED_COUNT="$total_reclaimed"
  GATE_DIR_UNSAFE="$dir_unsafe"
  unset -f add_dir 2>/dev/null || true
  return 0
}

ff_gate_collect_descendants() { # <root_pid> -> stdout: space-separated descendant PIDs
  local root="${1:-}"
  [ -n "$root" ] || return 0
  ps -eo pid=,ppid= 2>/dev/null | awk -v root="$root" '
    function visit(p,   arr, n, i) {
      if (p in seen) return
      seen[p] = 1
      n = split(children[p], arr, " ")
      for (i = 1; i <= n; i++) {
        if (arr[i] != "" && arr[i] != root && !(arr[i] in seen)) {
          visit(arr[i])
          out = (out ? out " " : "") arr[i]
        }
      }
    }
    NF >= 2 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
      children[$2] = (children[$2] ? children[$2] " " : "") $1
    }
    END {
      visit(root)
      if (out != "") print out
    }
  '
}

ff_gate_signal_cleanup() { # <sig> <marker_file> [root_pid=$$]
  local sig="${1:-TERM}" marker="${2:-}" root="${3:-$$}"
  local desc="" p="" _w=0 _alive=0
  desc="$(ff_gate_collect_descendants "$root" || true)"
  if [ -n "$desc" ]; then
    for p in $desc; do
      kill -s "$sig" "$p" 2>/dev/null || true
    done
    while [ "$_w" -lt 20 ]; do
      _alive=0
      for p in $desc; do
        if kill -0 "$p" 2>/dev/null; then
          _alive=1
          break
        fi
      done
      [ "$_alive" -eq 0 ] && break
      sleep 0.05 2>/dev/null || sleep 1
      _w=$((_w + 1))
    done
  fi
  ff_gate_marker_remove "$marker"
  ff_gate_wait_marker_remove "${GATE_WAIT_MARKER_FILE:-}"
  ff_gate_active_marker_remove "${GATE_ACTIVE_MARKER_FILE:-}"
  if declare -F ff_gate_wait_lock_release >/dev/null 2>&1; then
    ff_gate_wait_lock_release 2>/dev/null || true
  fi
  trap - "$sig"
  kill -s "$sig" "$$" 2>/dev/null || exit 1
}

ff_gate_wait_dir() { # -> stdout: wait state dir
  local d="${FF_RUN_ALL_WAIT_DIR:-}"
  if [ -n "$d" ]; then
    [ "$d" = "/" ] || d="${d%/}"
    printf '%s' "$d"
    return 0
  fi
  if [ -n "${FF_DEV_TOOLKIT_STATE_DIR:-}" ]; then
    d="${FF_DEV_TOOLKIT_STATE_DIR%/}/run-all-wait"
  elif [ -n "${HOME:-}" ]; then
    d="${HOME%/}/.config/ff-dev-toolkit/run-all-wait"
  else
    return 1
  fi
  printf '%s' "$d"
}

ff_gate_wait_dir_safe() { # <wait_dir> -> 0=safe / 1=unsafe(symlink or non-dir)
  local d="${1:-}" sub=""
  [ -n "$d" ] || return 1
  [ ! -L "$d" ] || return 1
  if [ -e "$d" ] && [ ! -d "$d" ]; then
    return 1
  fi
  for sub in waiting active start.lock start-reclaim.lock; do
    [ ! -L "${d}/${sub}" ] || return 1
    if [ -e "${d}/${sub}" ] && [ ! -d "${d}/${sub}" ]; then
      return 1
    fi
  done
  return 0
}

ff_gate_wait_marker_write() { # -> stdout: marker path
  local base="" wdir="" start="" tmp=""
  base="$(ff_gate_wait_dir)" || return 1
  ff_gate_wait_dir_safe "$base" || return 1
  wdir="${base}/waiting"
  mkdir -p "$wdir" 2>/dev/null || return 1
  [ ! -L "$wdir" ] && [ -d "$wdir" ] || return 1
  start="$(ff_gate_ps_lstart "$$" 2>/dev/null)" || return 1
  [ -n "$start" ] || return 1
  tmp="${wdir}/.tmp.$$"
  rm -f -- "$tmp" 2>/dev/null || true
  if printf '%s\n' "$start" > "$tmp" 2>/dev/null && mv -f -- "$tmp" "${wdir}/$$" 2>/dev/null; then
    printf '%s' "${wdir}/$$"
    return 0
  fi
  rm -f -- "$tmp" 2>/dev/null || true
  return 1
}

ff_gate_wait_marker_remove() { # <marker_file>
  local f="${1:-}"
  [ -n "$f" ] || return 0
  rm -f -- "$f" 2>/dev/null || true
}

_ff_gate_exact_pid_is_waiting() { # <pid> -> 0=waiting/<pid> verified, 1=not
  local pid="${1:-}" base="" wdir="" f="" want="" have="" kill_ok=0 kill_err=""
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  base="$(ff_gate_wait_dir 2>/dev/null)" || return 1
  [ ! -L "$base" ] && [ -d "$base" ] || return 1
  wdir="${base}/waiting"
  [ ! -L "$wdir" ] && [ -d "$wdir" ] || return 1
  f="${wdir}/${pid}"
  [ ! -L "$f" ] && [ -f "$f" ] && [ -r "$f" ] || return 1

  IFS= read -r want < "$f" 2>/dev/null || true
  want="${want%"$(printf '\r')"}"

  if kill_err="$(LC_ALL=C kill -0 "$pid" 2>&1)"; then
    kill_ok=1
  fi
  if [ "$kill_ok" -eq 1 ]; then
    have="$(ff_gate_ps_lstart "$pid" 2>/dev/null || true)"
    [ -n "$have" ] || return 1
    if [ -n "$want" ] && [ "$want" = "$have" ]; then
      return 0
    fi
    rm -f -- "$f" 2>/dev/null || true
    return 1
  fi
  case "$kill_err" in
    *[Pp]ermission* | *[Pp]ermitted* | *EPERM*)
      have="$(ff_gate_ps_lstart "$pid" 2>/dev/null || true)"
      [ -n "$have" ] || return 1
      if [ -n "$want" ] && [ "$want" = "$have" ]; then
        return 0
      fi
      rm -f -- "$f" 2>/dev/null || true
      return 1
      ;;
    *)
      rm -f -- "$f" 2>/dev/null || true
      return 1
      ;;
  esac
}

ff_gate_pid_is_waiting() { # <pid> -> 0=waiting process or descendant verified, 1=not waiting
  local pid="${1:-}" cur="" hop=0 seen=" "
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  cur="$pid"
  while [ "$hop" -lt 8 ]; do
    if _ff_gate_exact_pid_is_waiting "$cur"; then
      return 0
    fi
    case "$seen" in *" ${cur} "*) return 1 ;; esac
    seen="${seen}${cur} "
    cur="$(LC_ALL=C ps -o ppid= -p "$cur" 2>/dev/null | tr -d '[:space:]')" || return 1
    case "$cur" in
      '' | 0 | 1 | *[!0-9]*) return 1 ;;
    esac
    hop=$((hop + 1))
  done
  return 1
}

ff_gate_active_marker_write() { # <label> -> stdout: marker path
  local label="${1:-tests/run-all.sh}" base="" adir="" start="" tmp="" mtmp=""
  base="$(ff_gate_wait_dir)" || return 1
  ff_gate_wait_dir_safe "$base" || return 1
  adir="${base}/active"
  mkdir -p "$adir" 2>/dev/null || return 1
  [ ! -L "$adir" ] && [ -d "$adir" ] || return 1

  ff_gate_marker_sweep_dir "$adir" 0 "" >/dev/null 2>&1 || true

  start="$(ff_gate_ps_lstart "$$" 2>/dev/null)" || return 1
  [ -n "$start" ] || return 1

  tmp="${adir}/.tmp.$$"
  mtmp="${adir}/.tmp.$$.meta"
  rm -f -- "$tmp" "$mtmp" 2>/dev/null || true
  if printf '%s\n' "$start" > "$tmp" 2>/dev/null && mv -f -- "$tmp" "${adir}/$$" 2>/dev/null; then
    printf 'label=%s\n' "$label" > "$mtmp" 2>/dev/null && mv -f -- "$mtmp" "${adir}/$$.meta" 2>/dev/null || rm -f -- "$mtmp" 2>/dev/null || true
    printf '%s' "${adir}/$$"
    return 0
  fi
  rm -f -- "$tmp" "$mtmp" "${adir}/$$.meta" 2>/dev/null || true
  return 1
}

ff_gate_active_marker_adopt_self() { # -> stdout: marker path if active/$$ matches current process lstart
  local base="" adir="" f="" want="" have=""
  base="$(ff_gate_wait_dir 2>/dev/null)" || return 1
  ff_gate_wait_dir_safe "$base" || return 1
  adir="${base}/active"
  [ ! -L "$adir" ] && [ -d "$adir" ] || return 1
  f="${adir}/$$"
  [ ! -L "$f" ] && [ -f "$f" ] && [ -r "$f" ] || return 1
  IFS= read -r want < "$f" 2>/dev/null || true
  want="${want%"$(printf '\r')"}"
  have="$(ff_gate_ps_lstart "$$" 2>/dev/null || true)"
  [ -n "$want" ] && [ -n "$have" ] && [ "$want" = "$have" ] || return 1
  printf '%s' "$f"
  return 0
}

ff_gate_active_marker_remove() { # <marker_file>
  ff_gate_marker_remove "${1:-}"
}

ff_gate_scan_wait_active() { # [exclude_self_lineage=1]
  local excl="${1:-1}" base="" adir=""
  GATE_ACTIVE_LIVE_LINES=""
  GATE_ACTIVE_UNKNOWN_LINES=""
  GATE_ACTIVE_DIR_UNSAFE=0

  base="$(ff_gate_wait_dir 2>/dev/null || true)"
  [ -n "$base" ] || return 0
  if ! ff_gate_wait_dir_safe "$base"; then
    GATE_ACTIVE_DIR_UNSAFE=1
    GATE_ACTIVE_UNKNOWN_LINES="unsafe-wait-dir:${base}"
    return 1
  fi
  adir="${base}/active"
  [ -e "$adir" ] || [ -L "$adir" ] || return 0

  if ! ff_gate_marker_sweep_dir "$adir" "$excl" ""; then
    GATE_ACTIVE_DIR_UNSAFE=1
  fi
  GATE_ACTIVE_LIVE_LINES="$GATE_LIVE_LINES"
  GATE_ACTIVE_UNKNOWN_LINES="$GATE_UNKNOWN_LINES"
  return 0
}

ff_gate_scan_release_in_flight() { # <repo_dir> [exclude_self_lineage=1]
  local repo_dir="${1:-}" excl="${2:-1}"
  local common="" rdir="" info="" line="" pid="" host="" started="" ver="" rlstart=""
  local now="" max="" age=0 my_host="" kill_ok=0 kill_err="" have=""
  GATE_RELEASE_LIVE=""
  GATE_RELEASE_UNKNOWN=""

  [ -n "$repo_dir" ] || return 0
  common="$(git -C "$repo_dir" rev-parse --git-common-dir 2>/dev/null || true)"
  [ -n "$common" ] || return 0
  case "$common" in
    /*) : ;;
    *) common="$(CDPATH='' cd -P -- "$repo_dir" 2>/dev/null && CDPATH='' cd -P -- "$common" 2>/dev/null && pwd -P)" || return 0 ;;
  esac
  rdir="${common%/}/ff-release-in-flight"
  if [ -L "$rdir" ]; then
    GATE_RELEASE_UNKNOWN="unsafe-release-marker:${rdir}"
    return 1
  fi
  [ -e "$rdir" ] || return 0
  if [ ! -d "$rdir" ]; then
    GATE_RELEASE_UNKNOWN="unsafe-release-marker:${rdir}"
    return 1
  fi
  if [ -L "${rdir}/info" ]; then
    GATE_RELEASE_UNKNOWN="unsafe-release-marker:${rdir}/info"
    return 1
  fi
  if [ -e "${rdir}/info" ] && [ ! -r "${rdir}/info" ]; then
    GATE_RELEASE_UNKNOWN="unreadable-release-marker:${rdir}/info"
    return 1
  fi
  if [ -f "${rdir}/info" ]; then
    info="$(cat "${rdir}/info" 2>/dev/null || true)"
  fi
  if [ -z "$info" ]; then
    # mkdir 直後から info 配置完了までの 60 秒以内は取得中として扱う（scripts/lib/release-in-flight-functions.sh と同契約）
    if [ -n "$(find "$rdir" -maxdepth 0 -mmin -1 2>/dev/null)" ]; then
      GATE_RELEASE_LIVE="release:acquiring:scripts/release-dev-toolkit.sh"
    fi
    return 0
  fi

  local _info_rest="$info"
  while [ -n "$_info_rest" ]; do
    case "$_info_rest" in
      *$'\n'*) line="${_info_rest%%$'\n'*}"; _info_rest="${_info_rest#*$'\n'}" ;;
      *) line="$_info_rest"; _info_rest="" ;;
    esac
    line="${line%"$(printf '\r')"}"
    case "$line" in
      pid=*) pid="${line#pid=}" ;;
      host=*) host="${line#host=}" ;;
      started=*) started="${line#started=}" ;;
      version=*) ver="${line#version=}" ;;
      lstart=*) rlstart="${line#lstart=}" ;;
    esac
  done

  case "$started" in
    '' | *[!0-9]*) return 0 ;;
  esac
  now="$(date +%s 2>/dev/null || true)"
  case "$now" in
    '' | *[!0-9]*)
      GATE_RELEASE_UNKNOWN="clock-unavailable:${rdir}/info"
      return 1
      ;;
  esac
  max="${FF_RELEASE_IN_FLIGHT_MAX_AGE:-21600}"
  case "$max" in
    '' | *[!0-9]*) max=21600 ;;
  esac
  age=$((now - started))
  # NTP 等の壁時計巻き戻しを 300 秒まで許容し、極端な未来値や期限切れを残骸へ倒す
  if [ "$age" -lt -300 ] || [ "$age" -gt "$max" ]; then
    return 0
  fi

  my_host="$(hostname 2>/dev/null || echo unknown)"
  if [ "$host" = "$my_host" ]; then
    case "$pid" in '' | *[!0-9]*) return 0 ;; esac
    if kill_err="$(LC_ALL=C kill -0 "$pid" 2>&1)"; then
      kill_ok=1
    fi
    if [ "$kill_ok" -eq 0 ]; then
      case "$kill_err" in
        *[Pp]ermission* | *[Pp]ermitted* | *EPERM*) : ;;
        *) return 0 ;;
      esac
    fi
    if [ -n "$rlstart" ]; then
      have="$(ff_gate_ps_lstart "$pid" 2>/dev/null || true)"
      if [ -z "$have" ]; then
        GATE_RELEASE_UNKNOWN="release-lstart-unavailable:${pid}"
        return 1
      fi
      [ "$rlstart" = "$have" ] || return 0
    fi
    if [ "$excl" = "1" ] && ff_gate_pid_in_self_lineage "$pid"; then
      return 0
    fi
    GATE_RELEASE_LIVE="release:${pid}:scripts/release-dev-toolkit.sh (v${ver:-?})"
  else
    GATE_RELEASE_LIVE="release:${pid:-?}@${host:-?}:scripts/release-dev-toolkit.sh (v${ver:-?})"
  fi
  return 0
}

_ff_gate_collapse_candidates() { # <tab-delimited rows: pid\tanc\tscript> <prefix=""> -> emits validated top-most lines
  local rows="${1:-}" prefix="${2:-}"
  local _rest="$rows" _line="" _tab="" pid="" anc="" script="" _r="" _ap="" _anc_hit=0
  local valid_pids=" " _out=""
  [ -n "$rows" ] || return 0
  _tab="$(printf '\t')"
  while [ -n "$_rest" ]; do
    case "$_rest" in
      *$'\n'*) _line="${_rest%%$'\n'*}"; _rest="${_rest#*$'\n'}" ;;
      *) _line="$_rest"; _rest="" ;;
    esac
    [ -n "$_line" ] || continue
    pid="${_line%%"${_tab}"*}"
    [ -n "$pid" ] && valid_pids="${valid_pids}${pid} "
  done
  _rest="$rows"
  while [ -n "$_rest" ]; do
    case "$_rest" in
      *$'\n'*) _line="${_rest%%$'\n'*}"; _rest="${_rest#*$'\n'}" ;;
      *) _line="$_rest"; _rest="" ;;
    esac
    [ -n "$_line" ] || continue
    pid="${_line%%"${_tab}"*}"
    _r="${_line#*"${_tab}"}"
    anc="${_r%%"${_tab}"*}"
    script="${_r#*"${_tab}"}"
    _anc_hit=0
    if [ -n "$anc" ]; then
      local _arest="$anc"
      while [ -n "$_arest" ]; do
        case "$_arest" in
          *,*) _ap="${_arest%%,*}"; _arest="${_arest#*,}" ;;
          *) _ap="$_arest"; _arest="" ;;
        esac
        case "$valid_pids" in
          *" ${_ap} "*) _anc_hit=1; break ;;
        esac
      done
    fi
    [ "$_anc_hit" -eq 0 ] || continue
    _out="${_out:+${_out}
}${prefix}${pid}:${script}"
  done
  printf '%s' "$_out"
}

# NOTE: ff_gate_scan_other_release_procs も同型の runner() / roots 判定を持つ（tests/run-all.sh の
# ff_startup_other_gates は抽出配布用に独立定義）。ここでは -f / lsof cwd と args 再検証を先に済ませた
# 検証済み候補同士だけで祖先畳み込みを行い、未検証ラッパー文字列が真の子候補を隠す退行を防ぐ。
ff_gate_scan_other_public_layout() { # -> sets GATE_OTHER_PUBLIC_LAYOUT, rc 0=ok, 1=ps/unknown failure
  local snapshot="" candidates="" pid="" anc="" script="" recorded="" observed="" cwd_info="" process_cwd="" unavailable=0
  local valid_rows=""
  GATE_OTHER_PUBLIC_LAYOUT=""
  snapshot="$(LC_ALL=C ps -ww -eo pid=,ppid=,args= 2>/dev/null)" || return 1
  candidates="$(printf '%s\n' "$snapshot" | awk -v self="$$" '
    function base(s) { sub(/^.*\//, "", s); return s }
    function is_public_layout(p) { return (p ~ /(^|\/)public-layout\/verify[.]sh$/) }
    function is_run_all(p) { return (base(p) == "run-all.sh") }
    # root モードは外側の run-all.sh も samegate 根に含め、全件ゲート内の兄弟 public-layout 誤停止を防ぐ
    function match_script(p, mode) { return (mode == "root") ? (is_public_layout(p) || is_run_all(p)) : is_public_layout(p) }
    function runner(s, mode, a,n,i,p,b) {
      n=split(s,a,/[[:space:]]+/); b=base(a[1])
      if (match_script(a[1], mode)) return a[1]
      if (b!="bash" && b!="sh") return ""
      for(i=2;i<=n;i++) {
        if(a[i]=="-c" || a[i] ~ /^-[^-]*c/) return ""
        if(a[i]=="-o" || a[i]=="+o" || a[i]=="-O" || a[i]=="+O" || a[i]=="--rcfile" || a[i]=="--init-file") { i++; continue }
        if(a[i]=="--") { i++; break }
        if(a[i] ~ /^[-+]/) continue
        break
      }
      p=a[i]
      if(match_script(p, mode)) return p
      if(p ~ /[.]sh$/) return ""
      for(i++;i<=n;i++) {
        p=p " " a[i]
        if(match_script(p, mode)) return p
        if(a[i] ~ /[.]sh$/) return ""
      }
      return ""
    }
    function ancestor(a,b, i) {
      for(i=0;i<=count && b in parent;i++) {
        if(a==b) return 1
        if(b==0 || parent[b]==b) break
        b=parent[b]
      }
      return 0
    }
    function samegate(a,b, g) {
      for(g in roots) if(ancestor(g,a) && ancestor(g,b)) return 1
      return 0
    }
    NF {
      if($1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ || NF<3) { bad=1; next }
      pid=$1; parent[pid]=$2; count++
      command=$0; sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/, "", command)
      commands[pid]=command
    }
    END {
      if(bad || !(self in parent)) exit 1
      for(pid in commands) {
        if(runner(commands[pid], "root") != "") roots[pid]=1
        paths[pid]=runner(commands[pid], "public")
        if(paths[pid]!="") gates[pid]=1
      }
      for(pid in gates) {
        path=paths[pid]
        if(!ancestor(pid,self) && !ancestor(self,pid) && !samegate(pid,self)) {
          anc=""
          for(g in gates) if(g != pid && ancestor(g, pid)) anc = (anc == "" ? g : anc "," g)
          printf "%s\t%s\t%s\t%s\n",pid,anc,path,commands[pid]
        }
      }
    }
  ')" || return 1
  [ -n "$candidates" ] || return 0
  local _cand_rest="$candidates" _cand_line="" _tab="" _r=""
  _tab="$(printf '\t')"
  while [ -n "$_cand_rest" ]; do
    case "$_cand_rest" in
      *$'\n'*) _cand_line="${_cand_rest%%$'\n'*}"; _cand_rest="${_cand_rest#*$'\n'}" ;;
      *) _cand_line="$_cand_rest"; _cand_rest="" ;;
    esac
    [ -n "$_cand_line" ] || continue
    pid="${_cand_line%%"${_tab}"*}"
    _r="${_cand_line#*"${_tab}"}"
    anc="${_r%%"${_tab}"*}"
    _r="${_r#*"${_tab}"}"
    script="${_r%%"${_tab}"*}"
    recorded="${_r#*"${_tab}"}"
    [ -n "$pid" ] || continue
    case "$script" in
      *' '*)
        case "$script" in
          /*) [ -f "$script" ] || continue ;;
          *)
            if [ -d "/proc/$pid/cwd" ]; then
              [ -f "/proc/$pid/cwd/$script" ] || continue
            else
              cwd_info="$(LC_ALL=C lsof -a -p "$pid" -d cwd -Fn 2>/dev/null)" || { unavailable=1; continue; }
              process_cwd="$(printf '%s\n' "$cwd_info" | awk '/^n\// { sub(/^n/, ""); print; count++ } END { if(count!=1) exit 1 }')" || { unavailable=1; continue; }
              [ -f "$process_cwd/$script" ] || continue
            fi
            ;;
        esac
        ;;
    esac
    if observed="$(LC_ALL=C ps -ww -o args= -p "$pid" 2>/dev/null)"; then
      observed="${observed#"${observed%%[![:space:]]*}"}"
      [ -n "$observed" ] && [ "$observed" = "$recorded" ] || continue
      valid_rows="${valid_rows:+${valid_rows}
}${pid}${_tab}${anc}${_tab}${script}"
    elif kill -0 "$pid" 2>/dev/null; then
      unavailable=1
    fi
  done
  GATE_OTHER_PUBLIC_LAYOUT="$(_ff_gate_collapse_candidates "$valid_rows" "")"
  [ "$unavailable" -eq 0 ]
}

# ff_gate_scan_other_public_layout と同型の祖先チェック（別 clone 上の release-dev-toolkit.sh を検知）
ff_gate_scan_other_release_procs() { # -> sets GATE_OTHER_RELEASE_PROCS, rc 0=ok, 1=ps/unknown failure
  local snapshot="" candidates="" pid="" anc="" script="" recorded="" observed="" cwd_info="" process_cwd="" unavailable=0
  local valid_rows=""
  GATE_OTHER_RELEASE_PROCS=""
  snapshot="$(LC_ALL=C ps -ww -eo pid=,ppid=,args= 2>/dev/null)" || return 1
  candidates="$(printf '%s\n' "$snapshot" | awk -v self="$$" '
    function base(s) { sub(/^.*\//, "", s); return s }
    function is_release(p) { return (base(p) == "release-dev-toolkit.sh") }
    function is_run_all(p) { return (base(p) == "run-all.sh") }
    function match_script(p, mode) { return (mode == "root") ? (is_release(p) || is_run_all(p)) : is_release(p) }
    function runner(s, mode, a,n,i,p,b) {
      n=split(s,a,/[[:space:]]+/); b=base(a[1])
      if (match_script(a[1], mode)) return a[1]
      if (b!="bash" && b!="sh") return ""
      for(i=2;i<=n;i++) {
        if(a[i]=="-c" || a[i] ~ /^-[^-]*c/) return ""
        if(a[i]=="-o" || a[i]=="+o" || a[i]=="-O" || a[i]=="+O" || a[i]=="--rcfile" || a[i]=="--init-file") { i++; continue }
        if(a[i]=="--") { i++; break }
        if(a[i] ~ /^[-+]/) continue
        break
      }
      p=a[i]
      if(match_script(p, mode)) return p
      if(p ~ /[.]sh$/) return ""
      for(i++;i<=n;i++) {
        p=p " " a[i]
        if(match_script(p, mode)) return p
        if(a[i] ~ /[.]sh$/) return ""
      }
      return ""
    }
    function ancestor(a,b, i) {
      for(i=0;i<=count && b in parent;i++) {
        if(a==b) return 1
        if(b==0 || parent[b]==b) break
        b=parent[b]
      }
      return 0
    }
    function samegate(a,b, g) {
      for(g in roots) if(ancestor(g,a) && ancestor(g,b)) return 1
      return 0
    }
    NF {
      if($1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ || NF<3) { bad=1; next }
      pid=$1; parent[pid]=$2; count++
      command=$0; sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/, "", command)
      commands[pid]=command
    }
    END {
      if(bad || !(self in parent)) exit 1
      for(pid in commands) {
        if(runner(commands[pid], "root") != "") roots[pid]=1
        paths[pid]=runner(commands[pid], "rel")
        if(paths[pid]!="") rels[pid]=1
      }
      for(pid in rels) {
        path=paths[pid]
        if(!ancestor(pid,self) && !ancestor(self,pid) && !samegate(pid,self)) {
          anc=""
          for(g in rels) if(g != pid && ancestor(g, pid)) anc = (anc == "" ? g : anc "," g)
          printf "%s\t%s\t%s\t%s\n",pid,anc,path,commands[pid]
        }
      }
    }
  ')" || return 1
  [ -n "$candidates" ] || return 0
  local _cand_rest="$candidates" _cand_line="" _tab="" _r=""
  _tab="$(printf '\t')"
  while [ -n "$_cand_rest" ]; do
    case "$_cand_rest" in
      *$'\n'*) _cand_line="${_cand_rest%%$'\n'*}"; _cand_rest="${_cand_rest#*$'\n'}" ;;
      *) _cand_line="$_cand_rest"; _cand_rest="" ;;
    esac
    [ -n "$_cand_line" ] || continue
    pid="${_cand_line%%"${_tab}"*}"
    _r="${_cand_line#*"${_tab}"}"
    anc="${_r%%"${_tab}"*}"
    _r="${_r#*"${_tab}"}"
    script="${_r%%"${_tab}"*}"
    recorded="${_r#*"${_tab}"}"
    [ -n "$pid" ] || continue
    case "$script" in
      *' '*)
        case "$script" in
          /*) [ -f "$script" ] || continue ;;
          *)
            if [ -d "/proc/$pid/cwd" ]; then
              [ -f "/proc/$pid/cwd/$script" ] || continue
            else
              cwd_info="$(LC_ALL=C lsof -a -p "$pid" -d cwd -Fn 2>/dev/null)" || { unavailable=1; continue; }
              process_cwd="$(printf '%s\n' "$cwd_info" | awk '/^n\// { sub(/^n/, ""); print; count++ } END { if(count!=1) exit 1 }')" || { unavailable=1; continue; }
              [ -f "$process_cwd/$script" ] || continue
            fi
            ;;
        esac
        ;;
    esac
    if observed="$(LC_ALL=C ps -ww -o args= -p "$pid" 2>/dev/null)"; then
      observed="${observed#"${observed%%[![:space:]]*}"}"
      [ -n "$observed" ] && [ "$observed" = "$recorded" ] || continue
      valid_rows="${valid_rows:+${valid_rows}
}${pid}${_tab}${anc}${_tab}${script}"
    elif kill -0 "$pid" 2>/dev/null; then
      unavailable=1
    fi
  done
  GATE_OTHER_RELEASE_PROCS="$(_ff_gate_collapse_candidates "$valid_rows" "release:")"
  [ "$unavailable" -eq 0 ]
}

_ff_gate_lock_write_info() { # <dir> <token>
  local dir="${1:-}" tok="${2:-}" lstart="" now="" tmp=""
  lstart="$(ff_gate_ps_lstart "$$" 2>/dev/null || true)"
  now="$(date +%s 2>/dev/null || echo 0)"
  tmp="${dir}/.info.tmp.${tok}"
  rm -f -- "$tmp" 2>/dev/null || true
  printf 'token=%s\npid=%s\nlstart=%s\nstarted=%s\n' "$tok" "$$" "$lstart" "$now" > "$tmp" 2>/dev/null \
    && mv -f -- "$tmp" "${dir}/info" 2>/dev/null && return 0
  rm -f -- "$tmp" 2>/dev/null || true
  return 1
}

_ff_gate_lock_read_tok() { # <info_file> -> stdout token
  local f="${1:-}" line=""
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%"$(printf '\r')"}"
    case "$line" in token=*) printf '%s' "${line#token=}"; return 0 ;; esac
  done < "$f"
}

_ff_gate_lock_inspect_stale() { # <dir> -> sets _LK_STALE (0/1), _LK_TOK; rc 0=ok, 2=unsafe
  local dir="${1:-}" info="" line="" old_pid="" old_ls="" have="" _lk_err="" _lk_alive=0
  _LK_STALE=0
  _LK_TOK=""
  [ ! -L "$dir" ] && [ -d "$dir" ] && [ ! -L "${dir}/info" ] || return 2
  [ -f "${dir}/info" ] && info="$(cat "${dir}/info" 2>/dev/null || true)"
  if [ -z "$info" ]; then
    # mkdir から info 配置までの 60 秒未満は作成途中とみなして回収しない
    [ -z "$(find "$dir" -maxdepth 0 -mmin -1 2>/dev/null)" ] && _LK_STALE=1
    return 0
  fi
  local _rest="$info"
  while [ -n "$_rest" ]; do
    case "$_rest" in
      *$'\n'*) line="${_rest%%$'\n'*}"; _rest="${_rest#*$'\n'}" ;;
      *) line="$_rest"; _rest="" ;;
    esac
    line="${line%"$(printf '\r')"}"
    case "$line" in
      token=*) _LK_TOK="${line#token=}" ;;
      pid=*) old_pid="${line#pid=}" ;;
      lstart=*) old_ls="${line#lstart=}" ;;
    esac
  done
  case "$old_pid" in
    '' | *[!0-9]*) _LK_STALE=1; return 0 ;;
  esac
  if _lk_err="$(LC_ALL=C kill -0 "$old_pid" 2>&1)"; then
    _lk_alive=1
  else
    case "$_lk_err" in
      *[Pp]ermission* | *[Pp]ermitted* | *EPERM*) _lk_alive=1 ;;
    esac
  fi
  if [ "$_lk_alive" -eq 0 ]; then
    _LK_STALE=1
  elif [ -n "$old_ls" ]; then
    have="$(ff_gate_ps_lstart "$old_pid" 2>/dev/null || true)"
    [ -n "$have" ] && [ "$have" != "$old_ls" ] && _LK_STALE=1
  fi
  return 0
}

_ff_gate_lock_release_dir() { # <dir> <tok>
  local dir="${1:-}" tok="${2:-}" got=""
  [ -n "$dir" ] && [ ! -L "$dir" ] && [ -d "$dir" ] || return 0
  [ -L "${dir}/info" ] && return 0
  got="$(_ff_gate_lock_read_tok "${dir}/info")"
  [ "$got" = "$tok" ] || return 0
  rm -rf -- "$dir" 2>/dev/null || true
}

ff_gate_wait_lock_acquire() { # -> 0=acquired, 1=busy, 2=unsafe/error
  local base="" ldir="" rldir="" token="" rtok="" rmoved="" moved="" got_tok=""
  local _LK_STALE=0 _LK_TOK="" r_attempt=0
  GATE_WAIT_LOCK_DIR=""
  GATE_WAIT_LOCK_TOKEN=""
  GATE_WAIT_RECLAIM_LOCK_DIR=""
  GATE_WAIT_RECLAIM_LOCK_TOKEN=""

  base="$(ff_gate_wait_dir)" || return 2
  ff_gate_wait_dir_safe "$base" || return 2
  mkdir -p "$base" 2>/dev/null || return 2
  [ ! -L "$base" ] && [ -d "$base" ] || return 2
  ldir="${base}/start.lock"
  rldir="${base}/start-reclaim.lock"

  # 無競合の高速経路: start.lock が無ければ reclaim ロックを取らずに直接取得する
  [ ! -L "$ldir" ] || return 2
  if mkdir "$ldir" 2>/dev/null; then
    token="$$.$(date +%s 2>/dev/null || echo 0).${RANDOM:-0}"
    if _ff_gate_lock_write_info "$ldir" "$token"; then
      GATE_WAIT_LOCK_DIR="$ldir"
      GATE_WAIT_LOCK_TOKEN="$token"
      return 0
    fi
    rm -rf -- "$ldir" 2>/dev/null || true
    return 2
  fi
  [ ! -L "$ldir" ] || return 2
  [ -e "$ldir" ] || return 1
  [ -d "$ldir" ] || return 2

  # 残骸回収は start-reclaim.lock で直列化し、A の再取得済みロックを B が mv する 3 者競合を防ぐ
  while [ "$r_attempt" -lt 2 ]; do
    r_attempt=$((r_attempt + 1))
    [ ! -L "$rldir" ] || return 2
    if mkdir "$rldir" 2>/dev/null; then
      rtok="$$.$(date +%s 2>/dev/null || echo 0).${RANDOM:-0}"
      if _ff_gate_lock_write_info "$rldir" "$rtok"; then
        GATE_WAIT_RECLAIM_LOCK_DIR="$rldir"
        GATE_WAIT_RECLAIM_LOCK_TOKEN="$rtok"
        break
      fi
      rm -rf -- "$rldir" 2>/dev/null || true
      return 2
    fi
    [ ! -L "$rldir" ] || return 2
    [ -e "$rldir" ] || continue
    _ff_gate_lock_inspect_stale "$rldir" || return 2
    [ "$_LK_STALE" -eq 1 ] || return 1
    rmoved="${rldir}.reclaim.$$.${RANDOM:-0}"
    mv "$rldir" "$rmoved" 2>/dev/null || return 1
    got_tok="$(_ff_gate_lock_read_tok "${rmoved}/info")"
    if [ "$got_tok" != "$_LK_TOK" ]; then
      [ -e "$rldir" ] || mv "$rmoved" "$rldir" 2>/dev/null || true
      return 1
    fi
    rm -rf -- "$rmoved" 2>/dev/null || true
  done
  [ -n "$GATE_WAIT_RECLAIM_LOCK_DIR" ] || return 1

  # reclaim ロックの中で start.lock を再検査し、取得済みなら直ちに start.lock まで作成してから解放する
  if [ ! -e "$ldir" ] && [ ! -L "$ldir" ]; then
    if mkdir "$ldir" 2>/dev/null; then
      token="$$.$(date +%s 2>/dev/null || echo 0).${RANDOM:-0}"
      if _ff_gate_lock_write_info "$ldir" "$token"; then
        GATE_WAIT_LOCK_DIR="$ldir"
        GATE_WAIT_LOCK_TOKEN="$token"
        _ff_gate_lock_release_dir "$GATE_WAIT_RECLAIM_LOCK_DIR" "$GATE_WAIT_RECLAIM_LOCK_TOKEN"
        GATE_WAIT_RECLAIM_LOCK_DIR=""
        GATE_WAIT_RECLAIM_LOCK_TOKEN=""
        return 0
      fi
      rm -rf -- "$ldir" 2>/dev/null || true
      _ff_gate_lock_release_dir "$GATE_WAIT_RECLAIM_LOCK_DIR" "$GATE_WAIT_RECLAIM_LOCK_TOKEN"
      GATE_WAIT_RECLAIM_LOCK_DIR=""
      GATE_WAIT_RECLAIM_LOCK_TOKEN=""
      return 2
    fi
    _ff_gate_lock_release_dir "$GATE_WAIT_RECLAIM_LOCK_DIR" "$GATE_WAIT_RECLAIM_LOCK_TOKEN"
    GATE_WAIT_RECLAIM_LOCK_DIR=""
    GATE_WAIT_RECLAIM_LOCK_TOKEN=""
    return 1
  fi

  local _lk_rc=0
  _ff_gate_lock_inspect_stale "$ldir" || _lk_rc=$?
  if [ "$_lk_rc" -ne 0 ]; then
    _ff_gate_lock_release_dir "$GATE_WAIT_RECLAIM_LOCK_DIR" "$GATE_WAIT_RECLAIM_LOCK_TOKEN"
    GATE_WAIT_RECLAIM_LOCK_DIR=""
    GATE_WAIT_RECLAIM_LOCK_TOKEN=""
    return 2
  fi
  if [ "$_LK_STALE" -ne 1 ]; then
    _ff_gate_lock_release_dir "$GATE_WAIT_RECLAIM_LOCK_DIR" "$GATE_WAIT_RECLAIM_LOCK_TOKEN"
    GATE_WAIT_RECLAIM_LOCK_DIR=""
    GATE_WAIT_RECLAIM_LOCK_TOKEN=""
    return 1
  fi

  moved="${ldir}.reclaim.$$.${RANDOM:-0}"
  if ! mv "$ldir" "$moved" 2>/dev/null; then
    _ff_gate_lock_release_dir "$GATE_WAIT_RECLAIM_LOCK_DIR" "$GATE_WAIT_RECLAIM_LOCK_TOKEN"
    GATE_WAIT_RECLAIM_LOCK_DIR=""
    GATE_WAIT_RECLAIM_LOCK_TOKEN=""
    return 1
  fi
  got_tok="$(_ff_gate_lock_read_tok "${moved}/info")"
  if [ "$got_tok" != "$_LK_TOK" ]; then
    [ -e "$ldir" ] || mv "$moved" "$ldir" 2>/dev/null || true
    _ff_gate_lock_release_dir "$GATE_WAIT_RECLAIM_LOCK_DIR" "$GATE_WAIT_RECLAIM_LOCK_TOKEN"
    GATE_WAIT_RECLAIM_LOCK_DIR=""
    GATE_WAIT_RECLAIM_LOCK_TOKEN=""
    return 1
  fi
  rm -rf -- "$moved" 2>/dev/null || true

  if mkdir "$ldir" 2>/dev/null; then
    token="$$.$(date +%s 2>/dev/null || echo 0).${RANDOM:-0}"
    if _ff_gate_lock_write_info "$ldir" "$token"; then
      GATE_WAIT_LOCK_DIR="$ldir"
      GATE_WAIT_LOCK_TOKEN="$token"
      _ff_gate_lock_release_dir "$GATE_WAIT_RECLAIM_LOCK_DIR" "$GATE_WAIT_RECLAIM_LOCK_TOKEN"
      GATE_WAIT_RECLAIM_LOCK_DIR=""
      GATE_WAIT_RECLAIM_LOCK_TOKEN=""
      return 0
    fi
    rm -rf -- "$ldir" 2>/dev/null || true
    _ff_gate_lock_release_dir "$GATE_WAIT_RECLAIM_LOCK_DIR" "$GATE_WAIT_RECLAIM_LOCK_TOKEN"
    GATE_WAIT_RECLAIM_LOCK_DIR=""
    GATE_WAIT_RECLAIM_LOCK_TOKEN=""
    return 2
  fi

  _ff_gate_lock_release_dir "$GATE_WAIT_RECLAIM_LOCK_DIR" "$GATE_WAIT_RECLAIM_LOCK_TOKEN"
  GATE_WAIT_RECLAIM_LOCK_DIR=""
  GATE_WAIT_RECLAIM_LOCK_TOKEN=""
  return 1
}

ff_gate_wait_lock_release() {
  local ldir="${GATE_WAIT_LOCK_DIR:-}" tok="${GATE_WAIT_LOCK_TOKEN:-}"
  local rdir="${GATE_WAIT_RECLAIM_LOCK_DIR:-}" rtok="${GATE_WAIT_RECLAIM_LOCK_TOKEN:-}"
  GATE_WAIT_LOCK_DIR=""
  GATE_WAIT_LOCK_TOKEN=""
  GATE_WAIT_RECLAIM_LOCK_DIR=""
  GATE_WAIT_RECLAIM_LOCK_TOKEN=""
  _ff_gate_lock_release_dir "$ldir" "$tok"
  _ff_gate_lock_release_dir "$rdir" "$rtok"
}

ff_gate_parse_wait_config() { # -> sets GATE_WAIT_ENABLED, GATE_WAIT_MAX_SECONDS, GATE_WAIT_POLL_INTERVAL
  local max_val="${FF_RUN_ALL_WAIT_MAX_SECONDS:-}" poll_val="${FF_RUN_ALL_WAIT_POLL_INTERVAL:-}"
  GATE_WAIT_ENABLED=0
  GATE_WAIT_MAX_SECONDS=3600
  GATE_WAIT_POLL_INTERVAL=5

  case "${FF_RUN_ALL_WAIT:-}" in
    1) GATE_WAIT_ENABLED=1 ;;
    "" | 0) GATE_WAIT_ENABLED=0 ;;
    *)
      echo "✗ 判定不能: FF_RUN_ALL_WAIT=\"${FF_RUN_ALL_WAIT}\" は不正です（0 または 1 を指定してください）" >&2
      return 2
      ;;
  esac

  if [ -n "$max_val" ]; then
    case "$max_val" in
      *[!0-9]*)
        echo "✗ 判定不能: FF_RUN_ALL_WAIT_MAX_SECONDS=\"${max_val}\" は不正です（1〜86400 の整数を指定してください）" >&2
        return 2
        ;;
    esac
    # 86400（5 桁）超の長大入力で算術オーバーフローしないよう桁数を先に切る
    if [ "${#max_val}" -gt 5 ]; then
      echo "✗ 判定不能: FF_RUN_ALL_WAIT_MAX_SECONDS=\"${max_val}\" は上限 86400 秒を超えています" >&2
      return 2
    fi
    if [ "$max_val" -lt 1 ] || [ "$max_val" -gt 86400 ]; then
      echo "✗ 判定不能: FF_RUN_ALL_WAIT_MAX_SECONDS=\"${max_val}\" は範囲外です（1〜86400 の整数を指定してください）" >&2
      return 2
    fi
    GATE_WAIT_MAX_SECONDS="$((10#$max_val))"
  fi

  if [ -n "$poll_val" ]; then
    if awk -v x="$poll_val" 'BEGIN { exit !(x ~ /^([0-9]+([.][0-9]+)?|[.][0-9]+)$/ && x + 0 > 0) }' 2>/dev/null; then
      GATE_WAIT_POLL_INTERVAL="$poll_val"
    else
      echo "⚠️  FF_RUN_ALL_WAIT_POLL_INTERVAL=\"${poll_val}\" は解釈できない値です（既定 5 秒で続行します）" >&2
      GATE_WAIT_POLL_INTERVAL=5
    fi
  fi
  return 0
}

_ff_gate_append_blockers() { # <lines> <check_waiting:0|1>
  local _rest="${1:-}" _chk="${2:-1}" _line="" _pid=""
  while [ -n "$_rest" ]; do
    case "$_rest" in
      *$'\n'*) _line="${_rest%%$'\n'*}"; _rest="${_rest#*$'\n'}" ;;
      *) _line="$_rest"; _rest="" ;;
    esac
    [ -n "$_line" ] || continue
    _pid="${_line%%:*}"
    if [ "$_chk" = "1" ] && ff_gate_pid_is_waiting "$_pid"; then
      continue
    fi
    case "$_ff_seen_pids" in *" ${_pid} "*) continue ;; esac
    _ff_seen_pids="${_ff_seen_pids}${_pid} "
    GATE_BLOCKERS="${GATE_BLOCKERS:+${GATE_BLOCKERS}
}${_line}"
  done
}

ff_gate_collect_blockers() { # <repo_dir> <ps_other_gates_raw> <ps_other_gates_rc>
  local repo_dir="${1:-}" ps_raw="${2:-}" ps_rc="${3:-0}"
  local _ff_seen_pids=" "
  GATE_BLOCKERS=""
  GATE_BLOCKER_UNKNOWN=""
  GATE_HAS_BLOCKER=0
  GATE_HAS_UNKNOWN=0

  if [ "$ps_rc" -ne 0 ]; then
    GATE_HAS_UNKNOWN=1
    GATE_BLOCKER_UNKNOWN="${GATE_BLOCKER_UNKNOWN:+${GATE_BLOCKER_UNKNOWN}
}ps:プロセス一覧を取得できません"
  fi
  [ -z "$ps_raw" ] || _ff_gate_append_blockers "$ps_raw" 1

  if [ -n "$repo_dir" ]; then
    ff_gate_scan_repo_worktree_markers "$repo_dir" 1
    if [ "${GATE_DIR_UNSAFE:-0}" -eq 1 ] || [ -n "${GATE_UNKNOWN_LINES:-}" ]; then
      GATE_HAS_UNKNOWN=1
      [ -z "${GATE_UNKNOWN_LINES:-}" ] || GATE_BLOCKER_UNKNOWN="${GATE_BLOCKER_UNKNOWN:+${GATE_BLOCKER_UNKNOWN}
}${GATE_UNKNOWN_LINES}"
    fi
    [ -z "${GATE_LIVE_LINES:-}" ] || _ff_gate_append_blockers "$GATE_LIVE_LINES" 1
  fi

  if ! ff_gate_scan_wait_active 1; then
    GATE_HAS_UNKNOWN=1
    [ -z "${GATE_ACTIVE_UNKNOWN_LINES:-}" ] || GATE_BLOCKER_UNKNOWN="${GATE_BLOCKER_UNKNOWN:+${GATE_BLOCKER_UNKNOWN}
}${GATE_ACTIVE_UNKNOWN_LINES}"
  else
    if [ "${GATE_ACTIVE_DIR_UNSAFE:-0}" -eq 1 ] || [ -n "${GATE_ACTIVE_UNKNOWN_LINES:-}" ]; then
      GATE_HAS_UNKNOWN=1
      [ -z "${GATE_ACTIVE_UNKNOWN_LINES:-}" ] || GATE_BLOCKER_UNKNOWN="${GATE_BLOCKER_UNKNOWN:+${GATE_BLOCKER_UNKNOWN}
}${GATE_ACTIVE_UNKNOWN_LINES}"
    fi
    [ -z "${GATE_ACTIVE_LIVE_LINES:-}" ] || _ff_gate_append_blockers "$GATE_ACTIVE_LIVE_LINES" 0
  fi

  if ! ff_gate_scan_other_public_layout; then
    GATE_HAS_UNKNOWN=1
    GATE_BLOCKER_UNKNOWN="${GATE_BLOCKER_UNKNOWN:+${GATE_BLOCKER_UNKNOWN}
}ps:public-layout のプロセス一覧を取得できません"
  elif [ -n "${GATE_OTHER_PUBLIC_LAYOUT:-}" ]; then
    _ff_gate_append_blockers "$GATE_OTHER_PUBLIC_LAYOUT" 1
  fi

  local _seen_rel_pids=" " _rel_pid=""
  if [ -n "$repo_dir" ]; then
    if ! ff_gate_scan_release_in_flight "$repo_dir" 1; then
      GATE_HAS_UNKNOWN=1
      [ -z "${GATE_RELEASE_UNKNOWN:-}" ] || GATE_BLOCKER_UNKNOWN="${GATE_BLOCKER_UNKNOWN:+${GATE_BLOCKER_UNKNOWN}
}${GATE_RELEASE_UNKNOWN}"
    elif [ -n "${GATE_RELEASE_LIVE:-}" ]; then
      _rel_pid="${GATE_RELEASE_LIVE#release:}"
      _rel_pid="${_rel_pid%%:*}"
      case "$_rel_pid" in
        '' | *[!0-9]*) : ;;
        *) _seen_rel_pids="${_seen_rel_pids}${_rel_pid} " ;;
      esac
      GATE_BLOCKERS="${GATE_BLOCKERS:+${GATE_BLOCKERS}
}${GATE_RELEASE_LIVE}"
    fi
  fi

  if ! ff_gate_scan_other_release_procs; then
    GATE_HAS_UNKNOWN=1
    GATE_BLOCKER_UNKNOWN="${GATE_BLOCKER_UNKNOWN:+${GATE_BLOCKER_UNKNOWN}
}ps:release-dev-toolkit のプロセス一覧を取得できません"
  elif [ -n "${GATE_OTHER_RELEASE_PROCS:-}" ]; then
    local _rel_rest="$GATE_OTHER_RELEASE_PROCS" _rel_line=""
    while [ -n "$_rel_rest" ]; do
      case "$_rel_rest" in
        *$'\n'*) _rel_line="${_rel_rest%%$'\n'*}"; _rel_rest="${_rel_rest#*$'\n'}" ;;
        *) _rel_line="$_rel_rest"; _rel_rest="" ;;
      esac
      [ -n "$_rel_line" ] || continue
      _rel_pid="${_rel_line#release:}"
      _rel_pid="${_rel_pid%%:*}"
      case "$_seen_rel_pids" in *" ${_rel_pid} "*) continue ;; esac
      _seen_rel_pids="${_seen_rel_pids}${_rel_pid} "
      GATE_BLOCKERS="${GATE_BLOCKERS:+${GATE_BLOCKERS}
}${_rel_line}"
    done
  fi

  [ -z "$GATE_BLOCKERS" ] || GATE_HAS_BLOCKER=1
  return 0
}

ff_gate_wait_for_slot() { # <repo_dir> <label> <ps_probe_fn> -> 0=slot acquired, 2=timeout/unknown
  local repo_dir="${1:-}" label="${2:-tests/run-all.sh}" ps_probe_fn="${3:-}"
  local wbase="" start_ts="" deadline=0 now_ts=0 last_report="" ps_out="" ps_rc=0 lock_rc=0 _sleep_sec="" _rem=0
  GATE_DID_WAIT=0
  GATE_WAIT_ELAPSED=0
  GATE_WAIT_TIMEOUT_BLOCKERS=""

  [ -n "$ps_probe_fn" ] || { GATE_BLOCKER_UNKNOWN="ps-probe-fn-missing"; return 2; }
  wbase="$(ff_gate_wait_dir 2>/dev/null || true)"
  if [ -z "$wbase" ] || ! ff_gate_wait_dir_safe "$wbase"; then
    GATE_BLOCKER_UNKNOWN="unsafe-wait-dir:${wbase:-unset}"
    return 2
  fi
  if [ -z "${GATE_WAIT_MARKER_FILE:-}" ] || [ ! -e "$GATE_WAIT_MARKER_FILE" ]; then
    GATE_WAIT_MARKER_FILE="$(ff_gate_wait_marker_write 2>/dev/null || true)"
    if [ -z "$GATE_WAIT_MARKER_FILE" ]; then
      GATE_BLOCKER_UNKNOWN="wait-marker-unavailable:${wbase}"
      return 2
    fi
  fi

  start_ts="$(date +%s 2>/dev/null || true)"
  case "$start_ts" in
    '' | *[!0-9]*)
      ff_gate_wait_marker_remove "${GATE_WAIT_MARKER_FILE:-}"
      GATE_WAIT_MARKER_FILE=""
      GATE_BLOCKER_UNKNOWN="clock-unavailable"
      return 2
      ;;
  esac
  deadline=$((start_ts + GATE_WAIT_MAX_SECONDS))

  while :; do
    ps_out=""; ps_rc=0
    ps_out="$("$ps_probe_fn" 2>/dev/null)" || ps_rc=$?
    ff_gate_collect_blockers "$repo_dir" "$ps_out" "$ps_rc"
    if [ "$GATE_HAS_UNKNOWN" -eq 1 ]; then
      ff_gate_wait_marker_remove "${GATE_WAIT_MARKER_FILE:-}"
      GATE_WAIT_MARKER_FILE=""
      return 2
    fi
    if [ "$GATE_HAS_BLOCKER" -eq 0 ]; then
      # 実際に待機に入った回は、ロック取得前にも期限を再確認し（55-E2）、期限切れ起動を防ぐ
      if [ "$GATE_DID_WAIT" -eq 1 ]; then
        now_ts="$(date +%s 2>/dev/null || printf '%s' "$deadline")"
        if [ "$now_ts" -ge "$deadline" ]; then
          GATE_WAIT_TIMEOUT_BLOCKERS="${last_report:-timeout:待機上限（${GATE_WAIT_MAX_SECONDS} 秒）超過}"
          ff_gate_wait_marker_remove "${GATE_WAIT_MARKER_FILE:-}"
          GATE_WAIT_MARKER_FILE=""
          return 2
        fi
      fi
      lock_rc=0
      ff_gate_wait_lock_acquire || lock_rc=$?
      if [ "$lock_rc" -eq 0 ]; then
        ps_out=""; ps_rc=0
        ps_out="$("$ps_probe_fn" 2>/dev/null)" || ps_rc=$?
        ff_gate_collect_blockers "$repo_dir" "$ps_out" "$ps_rc"
        if [ "$GATE_HAS_UNKNOWN" -eq 1 ]; then
          ff_gate_wait_lock_release
          ff_gate_wait_marker_remove "${GATE_WAIT_MARKER_FILE:-}"
          GATE_WAIT_MARKER_FILE=""
          return 2
        fi
        if [ "$GATE_HAS_BLOCKER" -eq 0 ]; then
          # ロック取得中にも時間経過するため、active 配置直前にもう一度だけ期限を確認する
          if [ "$GATE_DID_WAIT" -eq 1 ]; then
            now_ts="$(date +%s 2>/dev/null || printf '%s' "$deadline")"
            if [ "$now_ts" -ge "$deadline" ]; then
              GATE_WAIT_TIMEOUT_BLOCKERS="${last_report:-timeout:待機上限（${GATE_WAIT_MAX_SECONDS} 秒）超過}"
              ff_gate_wait_lock_release
              ff_gate_wait_marker_remove "${GATE_WAIT_MARKER_FILE:-}"
              GATE_WAIT_MARKER_FILE=""
              return 2
            fi
          fi
          if GATE_ACTIVE_MARKER_FILE="$(ff_gate_active_marker_write "$label" 2>/dev/null)"; then
            ff_gate_wait_marker_remove "${GATE_WAIT_MARKER_FILE:-}"
            GATE_WAIT_MARKER_FILE=""
            ff_gate_wait_lock_release
            now_ts="$(date +%s 2>/dev/null || printf '%s' "$start_ts")"
            GATE_WAIT_ELAPSED=$((now_ts - start_ts))
            return 0
          else
            ff_gate_wait_lock_release
            ff_gate_wait_marker_remove "${GATE_WAIT_MARKER_FILE:-}"
            GATE_WAIT_MARKER_FILE=""
            GATE_BLOCKER_UNKNOWN="active-marker:開始マーカーを作成できません"
            return 2
          fi
        fi
        ff_gate_wait_lock_release
      elif [ "$lock_rc" -eq 2 ]; then
        ff_gate_wait_marker_remove "${GATE_WAIT_MARKER_FILE:-}"
        GATE_WAIT_MARKER_FILE=""
        GATE_BLOCKER_UNKNOWN="wait-lock:開始ロック領域が不正です"
        return 2
      else
        GATE_HAS_BLOCKER=1
        GATE_BLOCKERS="start-lock:別の待機ゲートが開始処理中"
      fi
    fi

    now_ts="$(date +%s 2>/dev/null || printf '%s' "$deadline")"
    if [ "$now_ts" -ge "$deadline" ]; then
      GATE_WAIT_TIMEOUT_BLOCKERS="${GATE_BLOCKERS:-${last_report:-timeout:待機上限（${GATE_WAIT_MAX_SECONDS} 秒）超過}}"
      ff_gate_wait_marker_remove "${GATE_WAIT_MARKER_FILE:-}"
      GATE_WAIT_MARKER_FILE=""
      return 2
    fi

    GATE_DID_WAIT=1
    if [ "$GATE_BLOCKERS" != "$last_report" ]; then
      echo "⏳ 別の全件ゲート／公開検査／リリースの完了を待っています（上限 ${GATE_WAIT_MAX_SECONDS} 秒）:" >&2
      printf '%s\n' "$GATE_BLOCKERS" | sed 's/^/  - /' >&2
      last_report="$GATE_BLOCKERS"
    fi
    _rem=$((deadline - now_ts))
    _sleep_sec="$(awk -v p="$GATE_WAIT_POLL_INTERVAL" -v r="$_rem" 'BEGIN {
      if (r <= 0) printf "1"
      else if (p + 0 > r + 0) printf "%s", r
      else printf "%s", p
    }' 2>/dev/null || printf '%s' "$GATE_WAIT_POLL_INTERVAL")"
    sleep "$_sleep_sec" 2>/dev/null || sleep 1
  done
}

_ff_gate_in_flight_loaded=1
