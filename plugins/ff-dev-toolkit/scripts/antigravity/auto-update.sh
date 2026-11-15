#!/usr/bin/env bash
# Google Antigravity 向けに同期済みプラグインおよびフックを自動更新する（日次間引き・安全ガード付き）。
#
# 使い方:
#   auto-update.sh [--out <dir>] [--hook] [--force] [--dry-run]
#   --out <dir>   対象のプラグイン出力先ディレクトリ（省略時は同期状態ファイルに登録済みの全出力先）
#   --hook        SessionStart hook モード（日次スタンプで 1 日 1 回に間引き、全経路 fail-silent で exit 0）
#   --force       日次スタンプを無視して強制チェック・更新を実行
#   --dry-run     ファイルや Git クローンを変更せず予定処理のみ表示
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd -P)"
SYNC_PLUGINS="$SCRIPT_DIR/sync-plugins.sh"
SYNC_HOOKS="$SCRIPT_DIR/sync-hooks.sh"

OUT_DIR=""
HOOK_MODE=0
FORCE=0
DRY_RUN=0

usage() {
  awk 'NR > 1 { if (/^#/) { sub(/^# ?/, ""); print } else exit }' "$0"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --out|--out-dir)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "✗ $1 にはディレクトリが必要です" >&2; exit 2; }
      OUT_DIR="$2"
      shift 2
      ;;
    --hook)
      HOOK_MODE=1
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "✗ 不明な引数: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# L4 宣言（ADR-087）。--hook 時だけ自動更新の SKIP / retired-stop を効かせる（手動 CLI 実行は対象外）。
{ [ -r "${BASH_SOURCE[0]%/*}/../lib/l4-declarations.sh" ] && . "${BASH_SOURCE[0]%/*}/../lib/l4-declarations.sh"; } 2>/dev/null || ff_l4_skipped() { return 1; }
if [ "$HOOK_MODE" -eq 1 ]; then
  if ff_l4_skipped 'auto-update' 'retired-stop'; then exit 0; fi
fi
unset FF_DEV_TOOLKIT_AGY_HOOK_EVENT || true

log_info() {
  if [ "$HOOK_MODE" -eq 0 ]; then
    echo "$1"
  fi
}

log_warn() {
  if [ "$HOOK_MODE" -eq 0 ]; then
    echo "$1" >&2
  fi
}

resolve_state_dir() {
  if [ -n "${FF_DEV_TOOLKIT_STATE_DIR:-}" ]; then
    printf '%s' "${FF_DEV_TOOLKIT_STATE_DIR%/}"
    return 0
  fi
  if [ -z "${HOME:-}" ]; then
    return 1
  fi
  printf '%s' "${HOME%/}/.config/ff-dev-toolkit"
}

assert_safe_ancestors() {
  local abs_target="$1" home_prefix="" probe=""
  case "$abs_target" in
    /*) ;;
    *) abs_target="${PWD%/}/${abs_target}" ;;
  esac
  if [ -n "${HOME:-}" ]; then
    home_prefix="${HOME%/}"
  fi
  probe="$(dirname -- "$abs_target")"
  while [ -n "$probe" ] && [ "$probe" != "/" ] && [ "$probe" != "." ]; do
    case "$probe" in
      /tmp|/var|/etc|/private|/Users|/home|/private/tmp|/private/var) break ;;
    esac
    if [ -n "$home_prefix" ] && [ "$probe" = "$home_prefix" ]; then
      break
    fi
    if [ -L "$probe" ]; then
      return 1
    fi
    if [ -e "$probe" ] && [ ! -d "$probe" ]; then
      return 1
    fi
    probe="$(dirname -- "$probe")"
  done
  return 0
}

assert_safe_dir_target() {
  local target="$1"
  [ ! -L "$target" ] || return 1
  if [ -e "$target" ] && [ ! -d "$target" ]; then
    return 1
  fi
  assert_safe_ancestors "$target"
}

assert_safe_file_target() {
  local target="$1"
  [ ! -L "$target" ] && [ ! -d "$target" ] || return 1
  assert_safe_ancestors "$target"
}

normalize_git_url() {
  local u="$1"
  while [ -n "$u" ] && [ "$u" != "${u%/}" ]; do
    u="${u%/}"
  done
  u="${u%.git}"
  printf '%s' "$u"
}

run_git() {
  GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=true GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}" git -c credential.interactive=never "$@"
}

acquire_daily_stamp() {
  local state_dir="$1" stamp_base stamp_dir today stamp_file f
  stamp_base="${FF_DEV_TOOLKIT_AGY_AUTO_UPDATE_STAMP:-${state_dir}/antigravity/auto-update-stamp}"
  stamp_dir="$(dirname -- "$stamp_base")"
  today="$(date '+%Y-%m-%d')" || return 1
  stamp_file="${stamp_base}.${today}"

  assert_safe_dir_target "$stamp_dir" || return 1
  assert_safe_file_target "$stamp_file" || return 1

  if [ "$DRY_RUN" -eq 1 ]; then
    if [ "$FORCE" -eq 0 ] && [ -e "$stamp_file" ]; then
      return 2
    fi
    log_info "dry-run: 日次スタンプを取得 ($stamp_file)"
    return 0
  fi

  mkdir -p -- "$stamp_dir" 2>/dev/null || return 1

  for f in "${stamp_base}".*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    case "$f" in
      "$stamp_file") ;;
      *) [ -L "$f" ] || rm -f -- "$f" 2>/dev/null || true ;;
    esac
  done

  if [ "$FORCE" -eq 1 ]; then
    rm -f -- "$stamp_file" 2>/dev/null || true
    (
      umask 077
      set -C
      : > "$stamp_file"
    ) 2>/dev/null || return 1
    return 0
  fi

  (
    umask 077
    set -C
    : > "$stamp_file"
  ) 2>/dev/null || return 2
  return 0
}

# clean な既定ブランチでのみ remote を --ff-only 更新し、作業中チェックアウトを汚さない。
# 戻り値: 0 = 同期続行可（更新済みまたは非 git / ローカルのみ）, 1 = スキップ（作業中または検証失敗）
prepare_git_source() {
  local src_root="$1" managed_clone="${2:-false}" expected_url="${3:-}" expected_clone_dir="${4:-}"
  local canon_src top_dir canon_clone actual_url git_dir dirty origin_head default_branch cur_branch remotes
  local head_sha origin_sha

  canon_src="$(CDPATH='' cd -P -- "$src_root" 2>/dev/null && pwd -P)" || return 1
  if ! command -v git >/dev/null 2>&1; then
    [ "$managed_clone" = "true" ] && return 1
    return 0
  fi

  top_dir="$(run_git -C "$canon_src" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$top_dir" ]; then
    top_dir="$(CDPATH='' cd -P -- "$top_dir" 2>/dev/null && pwd -P)" || return 1
  fi

  if [ -z "$top_dir" ]; then
    if [ "$managed_clone" = "true" ]; then
      log_warn "⚠️ 管理クローンが Git リポジトリではないためスキップします: $canon_src"
      return 1
    fi
    return 0
  fi

  if [ "$managed_clone" = "true" ]; then
    if [ "$top_dir" != "$canon_src" ]; then
      log_warn "⚠️ 管理クローンがリポジトリ直下ではないためスキップします: $canon_src"
      return 1
    fi
    if [ -n "$expected_clone_dir" ]; then
      canon_clone="$(CDPATH='' cd -P -- "$expected_clone_dir" 2>/dev/null && pwd -P)" || canon_clone="$expected_clone_dir"
      if [ "$canon_clone" != "$canon_src" ]; then
        log_warn "⚠️ 管理クローンパスが同期状態と一致しないためスキップします: $canon_src"
        return 1
      fi
    fi
    actual_url="$(run_git -C "$top_dir" config --get remote.origin.url 2>/dev/null || true)"
    if [ -z "$expected_url" ] || [ "$(normalize_git_url "$actual_url")" != "$(normalize_git_url "$expected_url")" ]; then
      log_warn "⚠️ 管理クローンの origin URL が一致しないためスキップします: $canon_src"
      return 1
    fi
  fi

  git_dir="$(run_git -C "$top_dir" rev-parse --absolute-git-dir 2>/dev/null || true)"
  if [ -z "$git_dir" ] || [ -e "$git_dir/MERGE_HEAD" ] || [ -e "$git_dir/REBASE_HEAD" ] \
     || [ -e "$git_dir/CHERRY_PICK_HEAD" ] || [ -e "$git_dir/BISECT_LOG" ] \
     || [ -d "$git_dir/rebase-merge" ] || [ -d "$git_dir/rebase-apply" ]; then
    log_warn "ℹ️ スキップ（マージ/リベース進行中）: $top_dir"
    return 1
  fi

  dirty="$(run_git -C "$top_dir" status --porcelain 2>/dev/null || true)"
  if [ -n "$dirty" ]; then
    log_warn "ℹ️ スキップ（未コミット変更あり）: $top_dir"
    return 1
  fi

  cur_branch="$(run_git -C "$top_dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [ -z "$cur_branch" ]; then
    log_warn "ℹ️ スキップ（detached HEAD）: $top_dir"
    return 1
  fi

  remotes="$(run_git -C "$top_dir" remote 2>/dev/null || true)"
  case "
$remotes
" in
    *"
origin
"*)
      origin_head="$(run_git -C "$top_dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
      if [ -n "$origin_head" ]; then
        default_branch="${origin_head#origin/}"
        if [ "$cur_branch" != "$default_branch" ]; then
          log_warn "ℹ️ スキップ（既定ブランチ ${default_branch} ではない: ${cur_branch}）: $top_dir"
          return 1
        fi
      fi

      if [ "$DRY_RUN" -eq 1 ]; then
        if [ -z "$origin_head" ]; then
          log_warn "⚠️ origin/HEAD が未解決のためスキップします: $top_dir"
          return 1
        fi
        log_info "dry-run: git -C $top_dir fetch --prune origin && merge --ff-only"
        return 0
      fi

      if run_git -C "$top_dir" fetch --prune --quiet origin 2>/dev/null; then
        origin_head="$(run_git -C "$top_dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
        if [ -z "$origin_head" ]; then
          run_git -C "$top_dir" remote set-head origin -a >/dev/null 2>&1 || true
          origin_head="$(run_git -C "$top_dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
        fi
        if [ -z "$origin_head" ]; then
          log_warn "⚠️ origin の既定ブランチを解決できないためスキップします: $top_dir"
          return 1
        fi
        default_branch="${origin_head#origin/}"
        if [ "$cur_branch" != "$default_branch" ]; then
          log_warn "ℹ️ スキップ（既定ブランチ ${default_branch} ではない: ${cur_branch}）: $top_dir"
          return 1
        fi
        if ! run_git -C "$top_dir" merge --ff-only -- "origin/${default_branch}" >/dev/null 2>&1; then
          log_warn "⚠️ fast-forward できないためスキップします: $top_dir"
          return 1
        fi
      else
        if [ "$managed_clone" = "true" ]; then
          log_warn "⚠️ 管理クローンのリモート取得に失敗したためスキップします: $top_dir"
          return 1
        fi
        if [ -z "$origin_head" ]; then
          log_warn "⚠️ origin/HEAD を検証できないためスキップします: $top_dir"
          return 1
        fi
        default_branch="${origin_head#origin/}"
        head_sha="$(run_git -C "$top_dir" rev-parse HEAD 2>/dev/null || true)"
        origin_sha="$(run_git -C "$top_dir" rev-parse "origin/${default_branch}" 2>/dev/null || true)"
        if [ -z "$head_sha" ] || [ "$head_sha" != "$origin_sha" ]; then
          log_warn "⚠️ オフラインかつ未検証のローカルコミットがあるためスキップします: $top_dir"
          return 1
        fi
      fi
      ;;
    *)
      if [ "$managed_clone" = "true" ]; then
        log_warn "⚠️ 管理クローンに origin リモートがないためスキップします: $top_dir"
        return 1
      fi
      ;;
  esac
  return 0
}

ff_dev_toolkit_selected() {
  local item
  if [ "$#" -eq 0 ]; then
    return 0
  fi
  for item in "$@"; do
    if [ "$item" = "ff-dev-toolkit" ]; then
      return 0
    fi
  done
  return 1
}

resolve_ff_dev_toolkit_root() {
  local out_dir="$1" src_mode="$2" src_root="$3" cand pname
  if [ "$src_mode" = "marketplace" ]; then
    cand="$src_root/plugins/ff-dev-toolkit"
    if [ -d "$cand" ] && [ -f "$cand/.claude-plugin/plugin.json" ]; then
      printf '%s' "$cand"
      return 0
    fi
    cand="$src_root"
  else
    cand="$src_root"
  fi
  if [ -f "$cand/.claude-plugin/plugin.json" ]; then
    pname="$(jq -r '.name // ""' "$cand/.claude-plugin/plugin.json" 2>/dev/null || true)"
    if [ "$pname" = "ff-dev-toolkit" ]; then
      printf '%s' "$cand"
      return 0
    fi
  fi
  return 1
}

sync_one_source() {
  local out_dir="$1" src_mode="$2" src_root="$3" proj_root="$4"
  local managed_clone="$5" repo_url="$6" clone_dir="$7"
  shift 7
  local sel_plugins=("$@")
  local sync_args=() sp ff_root hooks_file skills_link skills_target="" ff_skills_canon="" hooks_owner_ok=0

  if ! assert_safe_dir_target "$out_dir"; then
    log_warn "⚠️ 出力先ディレクトリが安全でないためスキップします: $out_dir"
    return 1
  fi

  if [ ! -d "$src_root" ]; then
    log_warn "⚠️ ソースディレクトリが見つからないためスキップします: $src_root"
    return 0
  fi

  if ! prepare_git_source "$src_root" "$managed_clone" "$repo_url" "$clone_dir"; then
    return 0
  fi

  if [ "$src_mode" = "marketplace" ]; then
    sync_args+=(--marketplace-root "$src_root")
    if [ "${#sel_plugins[@]}" -gt 0 ]; then
      for sp in "${sel_plugins[@]}"; do
        sync_args+=(--plugin "$sp")
      done
    fi
  else
    sync_args+=(--plugin-root "$src_root")
  fi
  sync_args+=(--out-dir "$out_dir")
  if [ -n "$proj_root" ]; then
    sync_args+=(--project-root "$proj_root")
  fi

  if ! bash "$SYNC_PLUGINS" "${sync_args[@]}" --check >/dev/null 2>&1; then
    if [ "$DRY_RUN" -eq 1 ]; then
      log_info "dry-run: bash $SYNC_PLUGINS ${sync_args[*]}"
    else
      if [ "$HOOK_MODE" -eq 1 ]; then
        bash "$SYNC_PLUGINS" "${sync_args[@]}" >/dev/null 2>&1 || true
      else
        bash "$SYNC_PLUGINS" "${sync_args[@]}" || return 1
      fi
    fi
  else
    log_info "✓ プラグイン最新: $src_root -> $out_dir"
  fi

  # hooks.json が既に導入されており、かつこのソースが ff-dev-toolkit の現在の所有元である場合だけ更新追従する
  hooks_file="$out_dir/ff-dev-toolkit/hooks.json"
  if [ -f "$hooks_file" ] && [ ! -L "$hooks_file" ] && [ ! -L "$out_dir/ff-dev-toolkit" ]; then
    if [ "$src_mode" != "marketplace" ] || [ "${#sel_plugins[@]}" -eq 0 ]; then
      hooks_owner_ok=1
    elif ff_dev_toolkit_selected "${sel_plugins[@]}"; then
      hooks_owner_ok=1
    fi
    if [ "$hooks_owner_ok" -eq 1 ]; then
      if ff_root="$(resolve_ff_dev_toolkit_root "$out_dir" "$src_mode" "$src_root" 2>/dev/null)"; then
        skills_link="$out_dir/ff-dev-toolkit/skills"
        if [ -L "$skills_link" ]; then
          skills_target="$(CDPATH='' cd -P -- "$skills_link" 2>/dev/null && pwd -P)" || skills_target=""
        fi
        ff_skills_canon="$(CDPATH='' cd -P -- "$ff_root/skills" 2>/dev/null && pwd -P)" || ff_skills_canon=""
        if [ -n "$skills_target" ] && [ -n "$ff_skills_canon" ] && [ "$skills_target" = "$ff_skills_canon" ]; then
          if [ -x "$SYNC_HOOKS" ] || [ -f "$SYNC_HOOKS" ]; then
            if ! bash "$SYNC_HOOKS" --plugin-root "$ff_root" --out-dir "$out_dir/ff-dev-toolkit" --check >/dev/null 2>&1; then
              if [ "$DRY_RUN" -eq 1 ]; then
                log_info "dry-run: bash $SYNC_HOOKS --plugin-root $ff_root --out-dir $out_dir/ff-dev-toolkit"
              else
                if [ "$HOOK_MODE" -eq 1 ]; then
                  bash "$SYNC_HOOKS" --plugin-root "$ff_root" --out-dir "$out_dir/ff-dev-toolkit" >/dev/null 2>&1 || true
                else
                  bash "$SYNC_HOOKS" --plugin-root "$ff_root" --out-dir "$out_dir/ff-dev-toolkit" || return 1
                fi
              fi
            else
              log_info "✓ フック最新: $ff_root -> $hooks_file"
            fi
          fi
        fi
      fi
    fi
  fi
  return 0
}

process_fallback_out_dir() {
  local out_dir="$1"
  local skills_link skills_dir plugin_src mkt_cand proj_root=""
  [ -d "$out_dir" ] && [ ! -L "$out_dir" ] || return 0
  skills_link="$out_dir/ff-dev-toolkit/skills"
  [ -L "$skills_link" ] || return 0
  skills_dir="$(CDPATH='' cd -P -- "$skills_link" 2>/dev/null && pwd -P)" || return 0
  plugin_src="$(dirname -- "$skills_dir")"
  [ -f "$plugin_src/.claude-plugin/plugin.json" ] || return 0

  if [ -f "$out_dir/ff-dev-toolkit/mcp_config.json" ] && [ ! -L "$out_dir/ff-dev-toolkit/mcp_config.json" ]; then
    proj_root="$(jq -r '.mcpServers["ff-dev-toolkit-spec-docs"].env.SPEC_DOCS_PROJECT_ROOT // empty' "$out_dir/ff-dev-toolkit/mcp_config.json" 2>/dev/null || true)"
  fi

  mkt_cand="$(dirname -- "$(dirname -- "$plugin_src")")"
  if [ -f "$mkt_cand/.claude-plugin/marketplace.json" ]; then
    local installed_plugins=() entry d d_dir
    for d in "$out_dir"/*/skills; do
      [ -L "$d" ] || continue
      d_dir="$(CDPATH='' cd -P -- "$d" 2>/dev/null && pwd -P)" || continue
      case "$d_dir" in
        "$mkt_cand"/plugins/*)
          entry="$(basename -- "$(dirname -- "$d")")"
          installed_plugins+=("$entry")
          ;;
      esac
    done
    if [ "${#installed_plugins[@]}" -gt 1 ]; then
      sync_one_source "$out_dir" "marketplace" "$mkt_cand" "$proj_root" "false" "" "" "${installed_plugins[@]}"
      return $?
    fi
  fi
  sync_one_source "$out_dir" "plugin" "$plugin_src" "$proj_root" "false" "" ""
}

process_target_dir() {
  local state_file="$1" out_key="$2"
  local state_snapshot src_count i src_mode src_root proj_root sel_raw
  local managed_clone repo_url clone_dir
  local sel_plugins=() status=0

  if [ -f "$state_file" ] && assert_safe_file_target "$state_file" \
     && jq -e --arg out "$out_key" '.targets[$out].sources | type == "object" and (length > 0)' "$state_file" >/dev/null 2>&1; then
    state_snapshot="$(cat "$state_file")" || return 1
    src_count="$(printf '%s\n' "$state_snapshot" | jq -r --arg out "$out_key" '.targets[$out].sources | keys | length')"
    i=0
    while [ "$i" -lt "$src_count" ]; do
      src_mode="$(printf '%s\n' "$state_snapshot" | jq -r --arg out "$out_key" --argjson idx "$i" '.targets[$out].sources | to_entries | sort_by(.key) | .[$idx].value.mode // "plugin"')"
      src_root="$(printf '%s\n' "$state_snapshot" | jq -r --arg out "$out_key" --argjson idx "$i" '.targets[$out].sources | to_entries | sort_by(.key) | .[$idx].value.sourceRoot // .[$idx].key')"
      proj_root="$(printf '%s\n' "$state_snapshot" | jq -r --arg out "$out_key" --argjson idx "$i" '.targets[$out].sources | to_entries | sort_by(.key) | .[$idx].value.projectRoot // ""')"
      managed_clone="$(printf '%s\n' "$state_snapshot" | jq -r --arg out "$out_key" --argjson idx "$i" 'if (.targets[$out].sources | to_entries | sort_by(.key) | .[$idx].value.managedClone == true) then "true" else "false" end')"
      repo_url="$(printf '%s\n' "$state_snapshot" | jq -r --arg out "$out_key" --argjson idx "$i" '.targets[$out].sources | to_entries | sort_by(.key) | .[$idx].value.repoUrl // ""')"
      clone_dir="$(printf '%s\n' "$state_snapshot" | jq -r --arg out "$out_key" --argjson idx "$i" '.targets[$out].sources | to_entries | sort_by(.key) | .[$idx].value.cloneDir // ""')"
      sel_plugins=()
      sel_raw="$(printf '%s\n' "$state_snapshot" | jq -r --arg out "$out_key" --argjson idx "$i" '.targets[$out].sources | to_entries | sort_by(.key) | .[$idx].value.selectedPlugins[]? // empty')"
      if [ -n "$sel_raw" ]; then
        while IFS= read -r p_item || [ -n "${p_item:-}" ]; do
          p_item="${p_item%$'\r'}"
          [ -n "$p_item" ] || continue
          sel_plugins+=("$p_item")
        done <<EOF
$sel_raw
EOF
      fi
      if [ "${#sel_plugins[@]}" -gt 0 ]; then
        sync_one_source "$out_key" "$src_mode" "$src_root" "$proj_root" "$managed_clone" "$repo_url" "$clone_dir" "${sel_plugins[@]}" || status=1
      else
        sync_one_source "$out_key" "$src_mode" "$src_root" "$proj_root" "$managed_clone" "$repo_url" "$clone_dir" || status=1
      fi
      i=$((i + 1))
    done
    return "$status"
  fi

  process_fallback_out_dir "$out_key"
}

main() {
  local state_dir="" state_file="" default_out="" canon_out="" t_raw="" stamp_rc=0
  local targets=() OVERALL_RC=0

  command -v jq >/dev/null 2>&1 || {
    if [ "$HOOK_MODE" -eq 1 ]; then
      return 0
    fi
    echo "✗ jq が必要です" >&2
    return 1
  }

  [ -f "$SYNC_PLUGINS" ] || {
    if [ "$HOOK_MODE" -eq 1 ]; then
      return 0
    fi
    echo "✗ sync-plugins.sh が見つかりません: $SYNC_PLUGINS" >&2
    return 1
  }

  state_dir="$(resolve_state_dir 2>/dev/null || true)"
  if [ -z "$state_dir" ] || ! assert_safe_dir_target "$state_dir"; then
    if [ "$HOOK_MODE" -eq 1 ]; then
      return 0
    fi
    echo "✗ 有効な HOME または FF_DEV_TOOLKIT_STATE_DIR が必要です" >&2
    return 1
  fi

  if [ "$HOOK_MODE" -eq 1 ]; then
    stamp_rc=0
    acquire_daily_stamp "$state_dir" || stamp_rc=$?
    if [ "$stamp_rc" -ne 0 ]; then
      return 0
    fi
  fi

  state_file="${state_dir}/antigravity/sync-state.json"

  if [ -n "$OUT_DIR" ]; then
    if ! assert_safe_dir_target "$OUT_DIR"; then
      log_warn "⚠️ 出力先ディレクトリが安全でないためスキップします: $OUT_DIR"
      return 1
    fi
    if [ -d "$OUT_DIR" ]; then
      canon_out="$(CDPATH='' cd -P -- "$OUT_DIR" 2>/dev/null && pwd -P)" || canon_out="$OUT_DIR"
    else
      log_info "ℹ️ 出力先ディレクトリが存在しないためスキップします: $OUT_DIR"
      return 0
    fi
    if [ -f "$state_file" ] && assert_safe_file_target "$state_file" \
       && jq -e --arg out "$canon_out" '.targets[$out].sources | type == "object"' "$state_file" >/dev/null 2>&1; then
      targets+=("$canon_out")
    else
      targets+=("$canon_out")
    fi
  else
    if [ -f "$state_file" ] && assert_safe_file_target "$state_file" \
       && jq -e '.targets | type == "object"' "$state_file" >/dev/null 2>&1; then
      t_raw="$(jq -r '.targets | keys[]?' "$state_file" 2>/dev/null || true)"
      if [ -n "$t_raw" ]; then
        while IFS= read -r t_line || [ -n "${t_line:-}" ]; do
          t_line="${t_line%$'\r'}"
          [ -n "$t_line" ] || continue
          targets+=("$t_line")
        done <<EOF
$t_raw
EOF
      fi
    fi
    if [ "${#targets[@]}" -eq 0 ] && [ -n "${HOME:-}" ]; then
      default_out="${HOME%/}/.gemini/config/plugins"
      if [ -d "$default_out" ] && [ ! -L "$default_out" ]; then
        canon_out="$(CDPATH='' cd -P -- "$default_out" 2>/dev/null && pwd -P)" || canon_out="$default_out"
        targets+=("$canon_out")
      fi
    fi
  fi

  if [ "${#targets[@]}" -eq 0 ]; then
    log_info "ℹ️ 自動更新の対象が見つかりません"
    return 0
  fi

  for t_item in "${targets[@]}"; do
    if [ -L "$t_item" ]; then
      log_warn "⚠️ 出力先ディレクトリが symlink のためスキップします: $t_item"
      OVERALL_RC=1
      continue
    fi
    if [ ! -d "$t_item" ]; then
      log_info "ℹ️ 出力先ディレクトリが存在しないためスキップします: $t_item"
      continue
    fi
    process_target_dir "$state_file" "$t_item" || OVERALL_RC=1
  done
  return "$OVERALL_RC"
}

if [ "$HOOK_MODE" -eq 1 ]; then
  main >/dev/null 2>&1 || true
  exit 0
fi

main
