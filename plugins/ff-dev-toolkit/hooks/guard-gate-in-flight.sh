#!/usr/bin/env bash
#
# 全件ゲート（tests/run-all.sh・単体起動の tests/public-layout/verify.sh）走行中の
# 作業ツリー編集・書き込みガード（PreToolUse / Edit・Write・MultiEdit・NotebookEdit・Bash）。
#
# 全件ゲートの走行中に作業ツリーを書き換えると、実行中の bash スクリプトのオフセットずれや
# dirty 検出・hook 壊れでその回が無効になる。対象作業ツリー（または単体 public-layout 実行元）の
# 走行中マーカー（<git-dir>/ff-dev-toolkit/run-all-in-flight/<PID>）の生存を共有ライブラリ
# tests/lib/gate-in-flight.sh（ff_gate_marker_status）で判定し、生存中なら作業ツリー内
# （.review-results/ と gitignore 済みを除く）への編集・Bash 経由書き込み・git 書き込みを
# 抜け道付きの deny で止める。死んだ PID・再利用 PID の残骸は掃除して通す。
#
# ツリー外（scratchpad / tmp 等）・出力先（.review-results/）・gitignore 済み・別 worktree は止めない。
# 抜け道:
#   - Bash: 対象コマンド区間の先頭に FF_GATE_IN_FLIGHT_ACK=1 を付ける（プロセス環境の値は読まない）
#   - 編集系ツール（Edit / Write / MultiEdit / NotebookEdit）: hook のプロセス環境に FF_GATE_IN_FLIGHT_ACK=1
#   - ガード全体の無効化: FF_DEV_TOOLKIT_SKIP=gate-in-flight
#
# fail-open 契約（通常経路）: jq 不在・git 外・壊れた stdin・マーカー無しは無音 exit 0。
# 候補呼び出しで判定・走査ライブラリが読めない/壊れている場合は fail-closed（deny）。
# 互換性: bash 3.2（stock macOS）互換。連想配列・readarray・=~・生の環境分岐は使わない。

ff_on_exit() {
  local rc=$?
  [ "$rc" -eq 0 ] && return 0
  jq -n --arg m "⚠️ ff-dev-toolkit guard（全件ゲート走行中）: ガードが判定の途中で異常終了しました（rc=${rc}）。判定できなかったので、この呼び出しは止めずに通します。全件ゲートの走行中なら、完了まで編集・commit を控えてください。" '{systemMessage: $m}' 2>/dev/null \
    || printf '{"systemMessage":"ff-dev-toolkit guard (gate-in-flight): abnormal exit (rc=%s); passed without a decision"}\n' "$rc"
  exit 0
}
trap ff_on_exit EXIT

input=""
IFS= read -r -d '' input || true

if ! source "${BASH_SOURCE[0]%/*}/asdd-hook-gate.sh"; then
  echo 'ff-dev-toolkit: ASDD Hook helper is unavailable; optional hook skipped' >&2
  exit 0
fi
asdd_hook_enabled hooks || exit 0

# shellcheck source=../scripts/lib/l4-declarations.sh
{ [ -r "${BASH_SOURCE[0]%/*}/../scripts/lib/l4-declarations.sh" ] && . "${BASH_SOURCE[0]%/*}/../scripts/lib/l4-declarations.sh"; } 2>/dev/null || ff_l4_skipped() { return 1; }
if ff_l4_skipped 'gate-in-flight'; then exit 0; fi

command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

EVENT=""
tool=""
CWD=""
_tool_edit_path=""
_tool_cmd=""
_jq_ok=0
while IFS= read -r -d '' EVENT \
  && IFS= read -r -d '' tool \
  && IFS= read -r -d '' CWD \
  && IFS= read -r -d '' _tool_edit_path \
  && IFS= read -r -d '' _tool_cmd; do
  _jq_ok=1
  break
done < <(printf '%s' "$input" | jq -sj '
  if length == 1 and (.[0] | type == "object") then
    .[0] | [
      (.hook_event_name // ""),
      (.tool_name // ""),
      (.cwd // ""),
      (.tool_input | if type == "object" then (.file_path // .notebook_path // "") else "" end),
      (.tool_input | if type == "object" then (.command // "") else "" end)
    ] | map(tostring | gsub("\u0000"; "")) | join("\u0000") + "\u0000"
  else empty end
' 2>/dev/null)
[ "$_jq_ok" -eq 1 ] || exit 0
EVENT="${EVENT//$'\r'/}"
tool="${tool//$'\r'/}"
[ -n "$EVENT" ] || EVENT="PreToolUse"
[ "$EVENT" = "PreToolUse" ] || exit 0

case "$tool" in
  Edit | Write | MultiEdit | NotebookEdit | Bash) : ;;
  *) exit 0 ;;
esac

WSL_LIB="${BASH_SOURCE[0]%/*}/../scripts/lib/wsl-notice.sh"
WS_IS_MSYS=0
if [ -r "$WSL_LIB" ] && [ ! -L "$WSL_LIB" ]; then
  # shellcheck source=../scripts/lib/wsl-notice.sh
  . "$WSL_LIB" 2>/dev/null || true
  if declare -F ff_host_is_msys >/dev/null 2>&1 && ff_host_is_msys "${OSTYPE:-}"; then
    WS_IS_MSYS=1
  fi
fi

CWD="${CWD//$'\r'/}"
if [ "$WS_IS_MSYS" -eq 1 ]; then
  case "$CWD" in
    [A-Za-z]:\\*) CWD="${CWD//\\//}" ;;
  esac
fi
[ -d "$CWD" ] || CWD="$(pwd)"

STOP_BLOCK_LIB="${BASH_SOURCE[0]%/*}/../scripts/lib/stop-block.sh"
emit_deny() { # <reason> <rule-id> <正本> <理由 1 行> <次の一手>
  local block="" reason
  block="$([ -f "$STOP_BLOCK_LIB" ] && [ -r "$STOP_BLOCK_LIB" ] && . "$STOP_BLOCK_LIB" 2>/dev/null \
    && declare -F ff_stop_block >/dev/null 2>&1 && ff_stop_block ガード "${2-}" "${3-}" "${4-}" "${5-}")"
  if [ -z "$block" ]; then
    block="止めた層: ガード
止めた規則: stop-block-unavailable（scripts/lib/stop-block.sh）— 停止文の共通形を読み込めません（元の規則: ${2-}）
次の一手: ff-dev-toolkit を更新・再インストールして scripts/lib/stop-block.sh を復旧する"
  fi
  reason="$1
$block"
  jq -n --arg reason "$reason" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}' 2>/dev/null
  exit 0
}

shq() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

GIF_LIB="${BASH_SOURCE[0]%/*}/../tests/lib/gate-in-flight.sh"
WRITE_SCAN_LIB="${BASH_SOURCE[0]%/*}/../tests/lib/review-write-scan.sh"
HEREDOC_HELPER="${BASH_SOURCE[0]%/*}/../tests/lib/heredoc-strip.sh"
OUTPUT_DIR_NAME=".review-results"

load_gif_lib_or_deny() {
  local last=""
  _gif_bad() {
    emit_deny "⚠️ ff-dev-toolkit guard（全件ゲート走行中）: 判定ライブラリを読めないため、編集とコマンドを止めます（${1}）。対象: ${GIF_LIB}。plugin を更新・再導入してください。" \
      gate-judge-unavailable tests/lib/gate-in-flight.sh \
      "全件ゲート走行中の判定ライブラリを読めないため、判定不能として止めた" \
      "ff-dev-toolkit を更新・再導入して tests/lib/gate-in-flight.sh を復旧する"
  }
  if [ -L "$GIF_LIB" ]; then
    _gif_bad "symlink です"
  elif [ ! -f "$GIF_LIB" ]; then
    _gif_bad "ファイルがありません"
  elif [ ! -s "$GIF_LIB" ]; then
    _gif_bad "0 バイトです"
  elif [ ! -r "$GIF_LIB" ]; then
    _gif_bad "読み取れません"
  fi
  last="$(awk 'NF { l = $0 } END { print l }' "$GIF_LIB" 2>/dev/null)" || last=""
  if [ "$last" != "_ff_gate_in_flight_loaded=1" ]; then
    _gif_bad "末尾まで読めていません"
  fi
  _ff_gate_in_flight_loaded=""
  # shellcheck source=../tests/lib/gate-in-flight.sh
  . "$GIF_LIB" 2>/dev/null || _gif_bad "source に失敗しました"
  if [ "${_ff_gate_in_flight_loaded:-}" != "1" ] \
    || [ "$(type -t ff_gate_marker_status 2>/dev/null)" != "function" ] \
    || [ "$(type -t ff_gate_marker_sweep_dir 2>/dev/null)" != "function" ]; then
    _gif_bad "必要な関数が定義されていません"
  fi
  unset -f _gif_bad 2>/dev/null || true
}

format_live_summary() { # <live_lines> <unknown_lines> <marker_dirs>
  local live="$1" unk="$2" summary="" line="" pid="" lbl=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    pid="${line%%:*}"
    lbl="${line#*:}"
    summary="${summary}  - ${lbl}（PID ${pid}）
"
  done <<EOF
$live
EOF
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    pid="${line%%:*}"
    summary="${summary}  - PID ${pid} の状態を確認できません（判定不能のため安全側で抑止: ${line#*:}）
"
  done <<EOF
$unk
EOF
  printf '%s' "$summary"
}

line_in_list() { # <needle> <newline_list>
  local needle="${1:-}" list="${2:-}" _line="" _rest=""
  [ -n "$needle" ] && [ -n "$list" ] || return 1
  case "$list" in
    "$needle") return 0 ;;
    *"$needle"*)
      _rest="$list"
      while [ -n "$_rest" ]; do
        case "$_rest" in
          *$'\n'*) _line="${_rest%%$'\n'*}"; _rest="${_rest#*$'\n'}" ;;
          *) _line="$_rest"; _rest="" ;;
        esac
        [ "$_line" = "$needle" ] && return 0
      done
      ;;
  esac
  return 1
}

resolve_git_meta() { # <dir> -> sets _GM_TOP / _GM_GDIR / _GM_CDIR (returns 0 if git repo, 1 otherwise)
  local dir="${1:-}" rp="" rp_rc=0 _cand_top="" _cand_gd="" _cand_cd=""
  _GM_TOP=""
  _GM_GDIR=""
  _GM_CDIR=""
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  # stdout のみを読み取る（GIT_TRACE=1 等の stderr 混入でパスがずれるのを防ぐ）
  rp="$(git -C "$dir" rev-parse --path-format=absolute --show-toplevel --git-dir --git-common-dir 2>/dev/null)" || rp_rc=$?
  if [ "$rp_rc" -ne 0 ]; then
    return 1
  fi
  case "$rp" in
    *$'\n'*$'\n'*)
      _cand_top="${rp%%$'\n'*}"
      _cand_top="${_cand_top%$'\r'}"
      rp="${rp#*$'\n'}"
      _cand_gd="${rp%%$'\n'*}"
      _cand_gd="${_cand_gd%$'\r'}"
      _cand_cd="${rp#*$'\n'}"
      _cand_cd="${_cand_cd%$'\r'}"
      # ちょうど 3 行かつすべて絶対パスであることを検証する（git 2.31 未満は --path-format=absolute をそのまま出力するためフォールバックへ回す）
      case "$_cand_top" in /* | [A-Za-z]:/*)
        case "$_cand_gd" in /* | [A-Za-z]:/*)
          case "$_cand_cd" in
            *$'\n'*) : ;;
            /* | [A-Za-z]:/*)
              _GM_TOP="$_cand_top"
              _GM_GDIR="$_cand_gd"
              _GM_CDIR="$_cand_cd"
              return 0
              ;;
          esac
        ;; esac
      ;; esac
      ;;
  esac
  _GM_TOP="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)"
  _GM_TOP="${_GM_TOP%$'\r'}"
  [ -n "$_GM_TOP" ] || return 1
  _GM_GDIR="$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null || true)"
  _GM_GDIR="${_GM_GDIR%$'\r'}"
  [ -n "$_GM_GDIR" ] || return 1
  _GM_CDIR="$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  _GM_CDIR="${_GM_CDIR%$'\r'}"
  case "$_GM_CDIR" in
    /* | [A-Za-z]:/*) : ;;
    *) _GM_CDIR="" ;;
  esac
  [ -n "$_GM_CDIR" ] || _GM_CDIR="$_GM_GDIR"
  return 0
}

# 0-fork で <dir> から親へ .git を探索する。
# 戻り値: 0=途中 symlink 無しで .git 発見 (_DG_DIR) / 1=git 外確定 / 2=symlink やパス要素の . / .. を含むため git rev-parse 要
find_dotgit_ancestor() { # <dir>
  local cur="${1%/}" hops=0
  _DG_DIR=""
  [ -n "$cur" ] || cur="/"
  case "$cur" in
    '.' | '..' | './'* | '../'* | *'/./'* | *'/.' | *'/../'* | *'/..') return 2 ;;
  esac
  while [ "$hops" -lt 64 ]; do
    [ -L "$cur" ] && return 2
    if [ -e "${cur}/.git" ]; then
      _DG_DIR="$cur"
      return 0
    fi
    [ "$cur" = "/" ] && return 1
    case "$cur" in
      [A-Za-z]: | [A-Za-z]:/) return 1 ;;
      */*)
        cur="${cur%/*}"
        [ -n "$cur" ] || cur="/"
        ;;
      *) return 2 ;;
    esac
    hops=$((hops + 1))
  done
  return 2
}

PROTECT_TREES=""
LIVE_SUMMARY=""
MARKER_DIRS_NOTE=""
write_note=""
cmd_override=0

case "$tool" in
  Edit | Write | MultiEdit | NotebookEdit)
    edit_path="$_tool_edit_path"
    edit_path="${edit_path//$'\r'/}"
    edit_drive=0
    if [ "$WS_IS_MSYS" -eq 1 ]; then
      case "$edit_path" in
        [A-Za-z]:\\* | [A-Za-z]:/*) edit_path="${edit_path//\\//}"; edit_drive=1 ;;
      esac
    fi
    case "$edit_path" in
      /*) : ;;
      ?*) [ "$edit_drive" -eq 1 ] || edit_path="${CWD}/${edit_path}" ;;
    esac

    target_probe=""
    probe_target="$edit_path"
    if [ -n "$probe_target" ] && [ -L "$probe_target" ]; then
      _lk_hops=0
      _lk_cur="$probe_target"
      while [ -L "$_lk_cur" ] && [ "$_lk_hops" -lt 32 ]; do
        _lk_dst="$(readlink "$_lk_cur" 2>/dev/null || true)"
        [ -n "$_lk_dst" ] || break
        case "$_lk_dst" in
          /*) _lk_cur="$_lk_dst" ;;
          *)
            _lk_pd="${_lk_cur%/*}"
            [ "$_lk_pd" != "$_lk_cur" ] || _lk_pd="."
            _lk_cur="${_lk_pd}/${_lk_dst}"
            ;;
        esac
        _lk_hops=$((_lk_hops + 1))
      done
      if [ ! -L "$_lk_cur" ] && [ -n "$_lk_cur" ]; then
        probe_target="$_lk_cur"
      else
        probe_target=""
      fi
    fi
    if [ -n "$probe_target" ]; then
      target_probe="$probe_target"
      case "$target_probe" in
        */*) target_probe="${target_probe%/*}"; [ -n "$target_probe" ] || target_probe="/" ;;
        *) target_probe="$CWD" ;;
      esac
      while [ ! -d "$target_probe" ] && [ "$target_probe" != "/" ] && [ "$target_probe" != "." ]; do
        case "$target_probe" in
          [A-Za-z]:) target_probe="${target_probe}/"; break ;;
          */*) target_probe="${target_probe%/*}"; [ -n "$target_probe" ] || target_probe="/" ;;
          *) target_probe="."; break ;;
        esac
      done
    fi
    [ -d "${target_probe:-}" ] || target_probe="$CWD"

    ROOT=""
    TARGET_GIT_DIR=""
    if resolve_git_meta "$target_probe"; then
      ROOT="$_GM_TOP"
      TARGET_GIT_DIR="$_GM_GDIR"
    fi
    if [ -z "$ROOT" ] || [ -z "$TARGET_GIT_DIR" ]; then
      # 親が git 管理外でも、cwd が git 管理内かつ書き込み先判定不能時の確認に備える
      if ! resolve_git_meta "$CWD"; then
        exit 0
      fi
      # edit_path が symlink でなく親を辿って明確に git 外（存在ディレクトリ）なら止めない
      if [ -n "$edit_path" ] && [ ! -L "$edit_path" ] && [ -d "$target_probe" ]; then
        exit 0
      fi
      ROOT="$_GM_TOP"
      TARGET_GIT_DIR="$_GM_GDIR"
      [ -n "$TARGET_GIT_DIR" ] || exit 0
    fi

    load_gif_lib_or_deny
    MARKER_DIR="${TARGET_GIT_DIR%/}/ff-dev-toolkit/run-all-in-flight"
    [ -e "$MARKER_DIR" ] || [ -L "$MARKER_DIR" ] || exit 0
    ROOT_PHYS="$(ff_gate_phys_dir "$ROOT" || printf '%s' "$ROOT")"
    ff_gate_marker_sweep_dir "$MARKER_DIR" 0 "$ROOT_PHYS" >/dev/null 2>&1 || true
    [ -n "$GATE_LIVE_LINES$GATE_UNKNOWN_LINES" ] || [ "${GATE_DIR_UNSAFE:-0}" -eq 1 ] || exit 0

    PROTECT_TREES="$ROOT_PHYS"
    MARKER_DIRS_NOTE="$MARKER_DIR"
    LIVE_SUMMARY="$(format_live_summary "$GATE_LIVE_LINES" "$GATE_UNKNOWN_LINES" "$MARKER_DIR")"

    if [ -n "$edit_path" ]; then
      if [ -r "$WRITE_SCAN_LIB" ] && . "$WRITE_SCAN_LIB" 2>/dev/null \
        && [ "$(type -t ff_write_scan_init 2>/dev/null)" = "function" ] \
        && [ "$(type -t resolve_target 2>/dev/null)" = "function" ] \
        && [ "$(type -t target_in_tree 2>/dev/null)" = "function" ]; then
        CWD_PHYS="$(ff_gate_phys_dir "$CWD" || printf '%s' "$CWD")"
        ff_write_scan_init "$ROOT_PHYS" "$CWD_PHYS" "$OUTPUT_DIR_NAME" "$PROTECT_TREES" FF_GATE_IN_FLIGHT_ACK
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

    if [ "${FF_GATE_IN_FLIGHT_ACK:-0}" = "1" ]; then
      exit 0
    fi
    ;;

  Bash)
    cmd="$_tool_cmd"
    cmd="${cmd//$'\r'/}"
    [ -n "$cmd" ] || exit 0

    CWD_ROOT=""
    ge_tops=()
    ge_gdirs=()
    ge_cdirs=()
    seen_roots=""
    seen_dotgit=""
    seen_cands=""
    if resolve_git_meta "$CWD"; then
      CWD_ROOT="$_GM_TOP"
      ge_tops+=("$_GM_TOP")
      ge_gdirs+=("$_GM_GDIR")
      ge_cdirs+=("$_GM_CDIR")
      seen_roots="$_GM_TOP"
      seen_dotgit="$_GM_TOP"
      # GIT_DIR / GIT_WORK_TREE / GIT_COMMON_DIR が設定されると git はディレクトリ構造と無関係に解決するため 0-fork 探索を使わない
      if [ -z "${GIT_DIR:-}" ] && [ -z "${GIT_WORK_TREE:-}" ] && [ -z "${GIT_COMMON_DIR:-}" ] && find_dotgit_ancestor "$CWD"; then
        if ! line_in_list "$_DG_DIR" "$seen_dotgit"; then
          seen_dotgit="${seen_dotgit}
${_DG_DIR}"
        fi
      fi
    fi

    # cd / git -C / リダイレクト等で別リポジトリ / 別 worktree（絶対・相対・引用/括弧内パス）を指す場合も候補へ加える
    case "$cmd" in
      */* | *..* | *' '* | *$'\t'* | *$'\n'*)
        _cand_norm="${cmd//\"/ }"
        _cand_norm="${_cand_norm//\'/ }"
        _cand_norm="${_cand_norm//\(/ }"
        _cand_norm="${_cand_norm//\)/ }"
        _cand_norm="${_cand_norm//,/ }"
        _cand_norm="${_cand_norm//;/ }"
        _cand_norm="${_cand_norm//=/ }"
        _cand_norm="${_cand_norm//&/ }"
        _cand_norm="${_cand_norm//</ }"
        _cand_norm="${_cand_norm//>/ }"
        _cand_norm="${_cand_norm//|/ }"
        set -f
        for tok in $_cand_norm; do
          [ -n "$tok" ] || continue
          case "$tok" in
            -*) continue ;;
            .. | ../* | */.. | */../* | '~/'* | /* | */*) : ;;
            *) [ -d "${CWD}/${tok}" ] || continue ;;
          esac
          case "$tok" in
            '~/'*) [ -n "${HOME:-}" ] && tok="${HOME}${tok#\~}" ;;
            /*) : ;;
            *) tok="${CWD}/${tok}" ;;
          esac
          probe="$tok"
          while [ -n "$probe" ] && [ ! -d "$probe" ] && [ "$probe" != "/" ]; do
            case "$probe" in
              */*) probe="${probe%/*}"; [ -n "$probe" ] || probe="/" ;;
              *) probe="" ;;
            esac
          done
          [ -n "$probe" ] && [ -d "$probe" ] && [ "$probe" != "/" ] || continue
          probe="${probe%/}"
          [ -n "$probe" ] || continue
          if [ "$probe" = "$CWD" ] || [ "$probe" = "${CWD_ROOT:-}" ]; then
            continue
          fi
          if line_in_list "$probe" "$seen_cands"; then
            continue
          fi
          seen_cands="${seen_cands:+${seen_cands}
}${probe}"

          _resolve_dir=""
          # GIT_DIR / GIT_WORK_TREE / GIT_COMMON_DIR が設定されると git はディレクトリ構造と無関係に解決するため 0-fork 探索を使わない
          if [ -z "${GIT_DIR:-}" ] && [ -z "${GIT_WORK_TREE:-}" ] && [ -z "${GIT_COMMON_DIR:-}" ]; then
            _dg_rc=0
            find_dotgit_ancestor "$probe" || _dg_rc=$?
            case "$_dg_rc" in
              0)
                if line_in_list "$_DG_DIR" "$seen_dotgit"; then
                  continue
                fi
                seen_dotgit="${seen_dotgit:+${seen_dotgit}
}${_DG_DIR}"
                _resolve_dir="$_DG_DIR"
                ;;
              1)
                continue
                ;;
              *)
                _resolve_dir="$probe"
                ;;
            esac
          else
            _resolve_dir="$probe"
          fi

          if resolve_git_meta "$_resolve_dir"; then
            if ! line_in_list "$_GM_TOP" "$seen_roots"; then
              seen_roots="${seen_roots:+${seen_roots}
}${_GM_TOP}"
              ge_tops+=("$_GM_TOP")
              ge_gdirs+=("$_GM_GDIR")
              ge_cdirs+=("$_GM_CDIR")
            fi
          fi
        done
        set +f
        ;;
    esac
    # いずれかの候補が git リポジトリに属するときだけ判定ライブラリを読み、走行中マーカーを調べる
    [ "${#ge_tops[@]}" -gt 0 ] || exit 0

    load_gif_lib_or_deny

    all_trees=""
    all_live=""
    all_unknown=""
    all_unsafe=0
    marker_dirs=""
    scanned_cdirs=""
    _ge_idx=0
    _ge_cnt="${#ge_tops[@]}"
    while [ "$_ge_idx" -lt "$_ge_cnt" ]; do
      r="${ge_tops[$_ge_idx]}"
      gd="${ge_gdirs[$_ge_idx]}"
      cd_dir="${ge_cdirs[$_ge_idx]}"
      _ge_idx=$((_ge_idx + 1))
      [ -n "$r" ] || continue
      [ -n "$gd" ] && marker_dirs="${marker_dirs:+${marker_dirs}
}${gd%/}/ff-dev-toolkit/run-all-in-flight"
      # 同じリポジトリ（同一 git-common-dir）の全 worktree 走査は 1 回だけ実行する
      if [ -n "$cd_dir" ] && line_in_list "$cd_dir" "$scanned_cdirs"; then
        continue
      fi
      [ -n "$cd_dir" ] && scanned_cdirs="${scanned_cdirs:+${scanned_cdirs}
}${cd_dir}"
      ff_gate_scan_repo_worktree_markers "$r" 0 "$gd" "$cd_dir" "$r"
      [ "${GATE_DIR_UNSAFE:-0}" -eq 1 ] && all_unsafe=1
      [ -z "$GATE_LIVE_TREES" ] || all_trees="${all_trees:+${all_trees}
}${GATE_LIVE_TREES}"
      [ -z "$GATE_UNKNOWN_TREES" ] || all_trees="${all_trees:+${all_trees}
}${GATE_UNKNOWN_TREES}"
      [ -z "$GATE_LIVE_LINES" ] || all_live="${all_live:+${all_live}
}${GATE_LIVE_LINES}"
      [ -z "$GATE_UNKNOWN_LINES" ] || all_unknown="${all_unknown:+${all_unknown}
}${GATE_UNKNOWN_LINES}"
    done

    [ -n "$all_live$all_unknown" ] || [ "$all_unsafe" -eq 1 ] || exit 0
    PROTECT_TREES="$(printf '%s\n' "$all_trees" | awk 'NF && !seen[$0]++')"
    if [ -z "$PROTECT_TREES" ] && [ -n "$CWD_ROOT" ]; then
      PROTECT_TREES="$(ff_gate_phys_dir "$CWD_ROOT" || printf '%s' "$CWD_ROOT")"
    fi
    LIVE_SUMMARY="$(format_live_summary "$all_live" "$all_unknown" "$marker_dirs")"
    MARKER_DIRS_NOTE="$(printf '%s\n' "$marker_dirs" | awk 'NF && !seen[$0]++' | tr '\n' ' ')"

    HEREDOC_STATE=unavailable
    HEREDOC_BODIES=""
    if [ -r "$HEREDOC_HELPER" ] && . "$HEREDOC_HELPER" 2>/dev/null; then
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

    ROOT_PHYS=""
    [ -z "$CWD_ROOT" ] || ROOT_PHYS="$(ff_gate_phys_dir "$CWD_ROOT" || printf '%s' "$CWD_ROOT")"
    CWD_PHYS="$(ff_gate_phys_dir "$CWD" || printf '%s' "$CWD")"
    first_tree="${PROTECT_TREES%%
*}"
    [ -n "$ROOT_PHYS" ] || ROOT_PHYS="$first_tree"

    is_write_git=0
    is_write_bash=0
    if [ -r "$WRITE_SCAN_LIB" ] && . "$WRITE_SCAN_LIB" 2>/dev/null \
      && [ "$(type -t ff_write_scan_init 2>/dev/null)" = "function" ] \
      && [ "$(type -t ff_worktree_git_write_scan 2>/dev/null)" = "function" ] \
      && [ "$(type -t ff_write_scan 2>/dev/null)" = "function" ]; then
      ff_write_scan_init "${CWD_ROOT:+${ROOT_PHYS}}" "$CWD_PHYS" "$OUTPUT_DIR_NAME" "$PROTECT_TREES" FF_GATE_IN_FLIGHT_ACK
      if ff_worktree_git_write_scan "$code_only" "$CWD" "$WS_IS_MSYS" 1; then
        is_write_git=1
        [ "${WRITE_GIT_OVERRIDE:-0}" -eq 1 ] && cmd_override=1
      fi
      if { [ "$is_write_git" -eq 0 ] || [ "${cmd_override:-0}" -eq 1 ]; } \
        && ff_write_scan "$cmd" "$HEREDOC_STATE" "$HEREDOC_CODE" "$HEREDOC_BODIES"; then
        is_write_bash=1
        if [ "${WRITE_OVERRIDE:-0}" -eq 1 ]; then
          [ "$is_write_git" -eq 1 ] || cmd_override=1
        else
          cmd_override=0
        fi
        write_note="このコマンドは${WRITE_REASON}。判定できない書き込みは deny 側へ倒します。
下書き・一時出力は作業ツリーの外（scratchpad や \`mktemp -d\` の一時ディレクトリ）へ書いてください。出力先 ${OUTPUT_DIR_NAME}/ への書き込みは止めません。
"
      fi
    else
      is_write_bash=1
      write_note="書き込み先を判定できません（走査ライブラリ ${WRITE_SCAN_LIB} を読めない、または必要な関数が欠けている）。判定できない書き込みは deny 側へ倒します。
"
    fi

    [ "$is_write_git" -eq 1 ] || [ "$is_write_bash" -eq 1 ] || exit 0
    if [ "${cmd_override:-0}" -eq 1 ]; then
      exit 0
    fi
    ;;
esac

trees_line="$(printf '%s\n' "$PROTECT_TREES" | awk 'NF && !seen[$0]++' | tr '\n' ' ')"
if [ "$tool" = "Bash" ]; then
  gate_next="全件ゲートの完了を待つかゲートを止めてから再実行する。この 1 回だけ通すなら対象コマンド（区間）の先頭へ FF_GATE_IN_FLIGHT_ACK=1 を付ける（無効化は FF_DEV_TOOLKIT_SKIP=gate-in-flight）"
else
  gate_next="全件ゲートの完了を待つかゲートを止めてから再実行する（${tool:-編集系ツール} にはコマンド先頭の解除指定を付けられない。無効化は FF_DEV_TOOLKIT_SKIP=gate-in-flight）"
fi

emit_deny "⚠️ ff-dev-toolkit guard（全件ゲート走行中・作業ツリー編集の抑止）: 全件ゲートが同じ作業ツリーで走行中です:
${LIVE_SUMMARY}  凍結の対象ツリー: ${trees_line}（これらの外・.review-results/・gitignore 済みへの書き込みは止めません）
${write_note:-}全件ゲートの走行中に作業ツリーを編集・checkout・commit すると、実行中の bash の読み取りオフセットずれや途中変更によりゲート結果が無効になります。完了まで編集を控えてください。
待つ・止める方法:
  - 走行中のゲート（tests/run-all.sh / tests/public-layout/verify.sh）の完了を待つ
  - どうしてもすぐ編集するなら、先に該当ゲート（上の PID のプロセスまたは background task）を TaskStop / kill で止めてから作業する
続行する抜け道（完了済み・自己責任で通す場合）:
  1) Bash に限りコマンド（区間）の先頭に環境代入を付ける → FF_GATE_IN_FLIGHT_ACK=1 <コマンド>
     （Edit / Write 等にはコマンド先頭が無いため、hook のプロセス環境に FF_GATE_IN_FLIGHT_ACK=1 を設定します。マーカー置き場: ${MARKER_DIRS_NOTE}）
  2) セッション全体で本ガードを無効化 → FF_DEV_TOOLKIT_SKIP=gate-in-flight" \
  gate-in-flight tests/lib/gate-in-flight.sh \
  "全件ゲートの走行中に作業ツリーへの書き込みを検出した" "$gate_next"
