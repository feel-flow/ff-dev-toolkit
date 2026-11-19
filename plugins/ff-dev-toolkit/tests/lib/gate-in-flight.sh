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
#   1 = 非生存・残骸（死んだ PID / 別プロセスへ再利用された PID / 空の壊れた通常ファイル。回収してよい）
#   2 = 判定不能（symlink・読めない・生きた PID に対して ps が lstart を返さない。削除しない）
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
  [ -r "$f" ] || return 2

  IFS= read -r want < "$f" 2>/dev/null || true
  want="${want%"$(printf '\r')"}"

  if kill_err="$(LC_ALL=C kill -0 "$base" 2>&1)"; then
    kill_ok=1
  fi

  if [ "$kill_ok" -eq 1 ]; then
    have="$(ff_gate_ps_lstart "$base" 2>/dev/null || true)"
    # プロセスは存在するが ps が lstart を返せない場合は回収せず判定不能に倒す
    [ -n "$have" ] || return 2
    # 空または開始時刻不一致は再利用 PID または不完全マーカー（残骸）
    [ -n "$want" ] && [ "$want" = "$have" ] || return 1
  else
    case "$kill_err" in
      *[Pp]ermission* | *[Pp]ermitted* | *EPERM*)
        have="$(ff_gate_ps_lstart "$base" 2>/dev/null || true)"
        [ -n "$have" ] || return 2
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
  local f="" base="" st=0 tree_val=""
  GATE_LIVE_LINES=""
  GATE_LIVE_PIDS=""
  GATE_LIVE_TREES=""
  GATE_UNKNOWN_LINES=""
  GATE_UNKNOWN_TREES=""
  GATE_RECLAIMED_COUNT=0
  GATE_DIR_UNSAFE=0

  [ -n "$dir" ] || return 0
  [ -n "$fb_tree" ] && fb_tree="$(ff_gate_phys_dir "$fb_tree" || printf '%s' "$fb_tree")"
  if [ -L "$dir" ]; then
    GATE_DIR_UNSAFE=1
    GATE_UNKNOWN_LINES="unsafe-dir:${dir}"
    [ -z "$fb_tree" ] || GATE_UNKNOWN_TREES="$fb_tree"
    return 1
  fi
  [ -e "$dir" ] || return 0
  if [ ! -d "$dir" ]; then
    GATE_DIR_UNSAFE=1
    GATE_UNKNOWN_LINES="unsafe-dir:${dir}"
    [ -z "$fb_tree" ] || GATE_UNKNOWN_TREES="$fb_tree"
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
        tree_val="${GATE_MARKER_TREE:-$fb_tree}"
        if [ -n "$tree_val" ]; then
          GATE_LIVE_TREES="${GATE_LIVE_TREES:+${GATE_LIVE_TREES}
}${tree_val}"
        fi
        ;;
      1)
        rm -f -- "$f" "${f}.meta" 2>/dev/null || true
        GATE_RECLAIMED_COUNT=$((GATE_RECLAIMED_COUNT + 1))
        ;;
      *)
        if [ "$excl" = "1" ] && ff_gate_pid_in_self_lineage "$base"; then
          continue
        fi
        GATE_UNKNOWN_LINES="${GATE_UNKNOWN_LINES:+${GATE_UNKNOWN_LINES}
}${base}:${f}"
        if [ -n "$fb_tree" ]; then
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
# 出力変数: GATE_LIVE_LINES / GATE_LIVE_PIDS / GATE_LIVE_TREES / GATE_UNKNOWN_LINES / GATE_RECLAIMED_COUNT
ff_gate_scan_repo_worktree_markers() { # <repo_dir> [exclude_self_lineage=0]
  local repo_dir="${1:-}" excl="${2:-0}"
  local gdir="" cdir="" mdir="" wt="" wt_root="" gf=""
  local dirs="" all_live="" all_pids="" all_trees="" all_unknown="" all_utrees="" total_reclaimed=0
  GATE_LIVE_LINES=""
  GATE_LIVE_PIDS=""
  GATE_LIVE_TREES=""
  GATE_UNKNOWN_LINES=""
  GATE_UNKNOWN_TREES=""
  GATE_RECLAIMED_COUNT=0
  [ -n "$repo_dir" ] || return 0

  gdir="$(git -C "$repo_dir" rev-parse --absolute-git-dir 2>/dev/null)" || gdir=""
  cdir="$(git -C "$repo_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || cdir=""
  if [ -z "$cdir" ] && [ -n "$gdir" ]; then
    cdir="$gdir"
  fi
  [ -n "$cdir" ] || return 0

  add_dir() {
    local d="$1" t="$2" line=""
    [ -n "$d" ] || return 0
    while IFS= read -r line; do
      [ "${line%%|*}" = "$d" ] && return 0
    done <<EOF
$dirs
EOF
    dirs="${dirs:+${dirs}
}${d}|${t}"
  }

  # main git dir
  if [ -n "$cdir" ]; then
    wt_root=""
    if [ "${cdir##*/}" = ".git" ]; then
      wt_root="$(ff_gate_phys_dir "${cdir%/.git}" || true)"
    fi
    mdir="$(ff_gate_marker_dir "$cdir" || true)"
    add_dir "$mdir" "$wt_root"
  fi
  # current git dir
  if [ -n "$gdir" ]; then
    wt_root="$(git -C "$repo_dir" rev-parse --show-toplevel 2>/dev/null)" || wt_root=""
    [ -n "$wt_root" ] && wt_root="$(ff_gate_phys_dir "$wt_root" || printf '%s' "$wt_root")"
    mdir="$(ff_gate_marker_dir "$gdir" || true)"
    add_dir "$mdir" "$wt_root"
  fi
  # linked worktrees
  if [ -d "${cdir}/worktrees" ]; then
    for wt in "${cdir}/worktrees"/*; do
      [ -d "$wt" ] || continue
      wt_root=""
      if [ -f "$wt/gitdir" ] && [ -r "$wt/gitdir" ]; then
        IFS= read -r gf < "$wt/gitdir" 2>/dev/null || gf=""
        if [ -n "$gf" ]; then
          wt_root="$(ff_gate_phys_dir "${gf%/.git}" || true)"
        fi
      fi
      mdir="$(ff_gate_marker_dir "$wt" || true)"
      add_dir "$mdir" "$wt_root"
    done
  fi

  local entry="" md="" fb="" dir_unsafe=0
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    md="${entry%%|*}"
    fb="${entry#*|}"
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
  done <<EOF
$dirs
EOF
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
  trap - "$sig"
  kill -s "$sig" "$$" 2>/dev/null || exit 1
}

_ff_gate_in_flight_loaded=1
