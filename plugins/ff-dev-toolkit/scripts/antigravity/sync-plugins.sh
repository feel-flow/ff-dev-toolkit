#!/usr/bin/env bash
# Google Antigravity 向けに Claude Code 形式プラグイン（SKILL.md と .mcp.json）を
# ~/.gemini/config/plugins/<name>/ へネイティブ構成で展開する。
#
# ソースツリー（plugins/*）直下に plugin.json を置くと Antigravity の拡張ステージングが
# スキップされるため、ソースは変更せず出力先へ:
#   - plugin.json（Antigravity 対応メタデータのみ。author.email / keywords / license は除外）
#   - skills -> <plugin_src>/skills の symlink（SKILL.md のコピーを作らない）
#   - mcp_config.json（.mcp.json がある場合。${CLAUDE_PLUGIN_ROOT} を実体パスへ展開し、
#     サーバー識別子を <plugin>-<server> へ名前空間化）
# を展開する。.mcp.json の参照先ファイルが不在の場合は書き込み前に失敗する。
#
# 使い方:
#   sync-plugins.sh [--plugin-root <dir> | --marketplace-root <dir> | --repo <owner/repo|url>]
#                   [--clone-dir <dir>] [--plugin <name> ...]
#                   [--out-dir <dir>] [--project-root <dir>] [--check]
#   --plugin-root <dir>       単一プラグインのルート（既定: 同梱 ff-dev-toolkit）
#   --marketplace-root <dir>  .claude-plugin/marketplace.json からローカルプラグインを一括展開
#   --repo <owner/repo|url>   Git リポジトリを管理クローン（--clone-dir）へ取得・更新して展開
#   --clone-dir <dir>         --repo のクローン先（既定: ${FF_DEV_TOOLKIT_STATE_DIR:-~/.config/ff-dev-toolkit}/antigravity/repos/<slug>）
#   --plugin <name>           --marketplace-root またはマーケットプレイス構成の --repo 時に展開対象を絞る（複数回指定可）
#   --out-dir <dir>           出力先ディレクトリ（既定: ~/.gemini/config/plugins）
#   --project-root <dir>      spec-docs MCP の SPEC_DOCS_PROJECT_ROOT に設定するディレクトリ
#   --check                   書き込まず・ネットワークに出ずに最新（0）/ 未同期・不整合（1）を検査する
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd -P)"
DEFAULT_PLUGIN_ROOT="$(CDPATH='' cd -P -- "$SCRIPT_DIR/../.." && pwd -P)"

PLUGIN_ROOT=""
MARKETPLACE_ROOT=""
REPO_SPEC=""
REPO_URL=""
REPO_SLUG=""
CLONE_DIR=""
OUT_DIR=""
PROJECT_ROOT=""
CHECK=0
SELECTED_PLUGINS=()
SYNCED_PLUGIN_NAMES=()

usage() {
  awk 'NR > 1 { if (/^#/) { sub(/^# ?/, ""); print } else exit }' "$0"
}

has_selected_plugin() {
  local target="$1" item
  if [ "${#SELECTED_PLUGINS[@]}" -eq 0 ]; then
    return 0
  fi
  for item in "${SELECTED_PLUGINS[@]}"; do
    if [ "$item" = "$target" ]; then
      return 0
    fi
  done
  return 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --plugin-root)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "✗ --plugin-root にはディレクトリが必要です" >&2; exit 2; }
      PLUGIN_ROOT="$2"
      shift 2
      ;;
    --marketplace-root)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "✗ --marketplace-root にはディレクトリが必要です" >&2; exit 2; }
      MARKETPLACE_ROOT="$2"
      shift 2
      ;;
    --repo)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "✗ --repo には owner/repo または URL が必要です" >&2; exit 2; }
      REPO_SPEC="$2"
      shift 2
      ;;
    --clone-dir)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "✗ --clone-dir にはディレクトリが必要です" >&2; exit 2; }
      CLONE_DIR="$2"
      shift 2
      ;;
    --plugin)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "✗ --plugin にはプラグイン名が必要です" >&2; exit 2; }
      SELECTED_PLUGINS+=("$2")
      shift 2
      ;;
    --out-dir)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "✗ --out-dir にはディレクトリが必要です" >&2; exit 2; }
      OUT_DIR="$2"
      shift 2
      ;;
    --project-root)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "✗ --project-root にはディレクトリが必要です" >&2; exit 2; }
      PROJECT_ROOT="$2"
      shift 2
      ;;
    --check)
      CHECK=1
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

mode_count=0
[ -n "$PLUGIN_ROOT" ] && mode_count=$((mode_count + 1))
[ -n "$MARKETPLACE_ROOT" ] && mode_count=$((mode_count + 1))
[ -n "$REPO_SPEC" ] && mode_count=$((mode_count + 1))
if [ "$mode_count" -gt 1 ]; then
  echo "✗ --plugin-root / --marketplace-root / --repo は同時に指定できません" >&2
  exit 2
fi

if [ -n "$CLONE_DIR" ] && [ -z "$REPO_SPEC" ]; then
  echo "✗ --clone-dir は --repo と組み合わせて指定してください" >&2
  exit 2
fi

if [ -z "$MARKETPLACE_ROOT" ] && [ -z "$REPO_SPEC" ] && [ "${#SELECTED_PLUGINS[@]}" -gt 0 ]; then
  echo "✗ --plugin は --marketplace-root または --repo と組み合わせて指定してください" >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || { echo "✗ jq が必要です" >&2; exit 1; }

if [ -z "$OUT_DIR" ]; then
  if [ -z "${HOME:-}" ]; then
    echo "✗ --out-dir 未指定時は HOME が必要です" >&2
    exit 1
  fi
  OUT_DIR="${HOME}/.gemini/config/plugins"
fi

if [ -n "$PROJECT_ROOT" ]; then
  PROJECT_ROOT="$(CDPATH='' cd -P -- "$PROJECT_ROOT" 2>/dev/null && pwd -P)" || {
    echo "✗ --project-root が見つかりません: $PROJECT_ROOT" >&2
    exit 1
  }
fi

validate_plugin_name() {
  local name="$1"
  case "$name" in
    ''|*[!a-z0-9-]*|-*|*-)
      return 1
      ;;
  esac
  case "$name" in
    [a-z0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

validate_relative_source() {
  local src="$1"
  case "$src" in
    ''|/*|..|../*|*/..|*/../*)
      return 1
      ;;
    ./*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

assert_safe_ancestors() {
  local target="$1" abs_target="$1" home_prefix="" probe=""
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
      echo "✗ 出力・状態パスの親ディレクトリが symlink のため中止します: ${probe}" >&2
      return 1
    fi
    if [ -e "$probe" ] && [ ! -d "$probe" ]; then
      echo "✗ 出力・状態パスの親パスがディレクトリではないため中止します: ${probe}" >&2
      return 1
    fi
    probe="$(dirname -- "$probe")"
  done
  return 0
}

assert_safe_dir_target() {
  local target="$1"
  if [ -L "$target" ]; then
    echo "✗ ディレクトリパスが symlink のため中止します: $target" >&2
    return 1
  fi
  if [ -e "$target" ] && [ ! -d "$target" ]; then
    echo "✗ 出力先がディレクトリではないため中止します: $target" >&2
    return 1
  fi
  assert_safe_ancestors "$target"
}

assert_safe_file_target() {
  local target="$1"
  if [ -L "$target" ] || [ -d "$target" ]; then
    echo "✗ 書き込み先が通常ファイルではない（symlink またはディレクトリ）ため中止します: $target" >&2
    return 1
  fi
  assert_safe_ancestors "$target"
}

write_atomic() {
  local target="$1" content="$2" dir dir_real base tmp=""
  assert_safe_file_target "$target" || return 1
  dir="$(dirname -- "$target")" || return 1
  mkdir -p -- "$dir" || return 1
  dir_real="$(CDPATH='' cd -P -- "$dir" 2>/dev/null && pwd -P)" || return 1
  base="$(basename -- "$target")"
  if [ -L "${dir_real}/${base}" ] || [ -d "${dir_real}/${base}" ]; then
    echo "✗ 書き込み先が通常ファイルではない（symlink またはディレクトリ）ため中止します: ${dir_real}/${base}" >&2
    return 1
  fi
  tmp="$(mktemp -- "${dir_real}/.${base}.tmp.XXXXXX")" || return 1
  if ! printf '%s\n' "$content" > "$tmp" || ! mv -f -- "$tmp" "${dir_real}/${base}"; then
    rm -f -- "$tmp" 2>/dev/null || true
    return 1
  fi
}

json_matches_file() {
  local file="$1" expected="$2" norm_file norm_exp
  [ -f "$file" ] || return 1
  norm_file="$(jq -S . "$file" 2>/dev/null)" || return 1
  norm_exp="$(printf '%s\n' "$expected" | jq -S . 2>/dev/null)" || return 1
  [ "$norm_file" = "$norm_exp" ]
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

normalize_git_url() {
  local u="$1"
  while [ -n "$u" ] && [ "$u" != "${u%/}" ]; do
    u="${u%/}"
  done
  u="${u%.git}"
  printf '%s' "$u"
}

resolve_repo_spec() {
  local spec="$1" owner="" repo_part="" stripped="" sanitized="" h="" host="" repo_sub=""
  case "$spec" in
    ''|-*|*[[:space:]]*)
      echo "✗ 不正な --repo 指定です: $spec" >&2
      return 2
      ;;
  esac
  case "$spec" in
    http://*)
      echo "✗ 平文 http:// は許可されていません（https:// / ssh:// / file:// / git@... または owner/repo を指定してください）: $spec" >&2
      return 2
      ;;
    https://*|ssh://*|file://*)
      REPO_URL="$spec"
      stripped="${spec#*://}"
      if [ "$spec" != "${spec#file://}" ]; then
        case "$stripped" in
          ''|-*)
            echo "✗ 不正な file:// URL です: $spec" >&2
            return 2
            ;;
        esac
      else
        host="${stripped%%/*}"
        [ "$host" != "$stripped" ] || { echo "✗ --repo URL にリポジトリパスがありません: $spec" >&2; return 2; }
        host="${host#*@}"
        case "$host" in
          ''|-*|.)
            echo "✗ 不正なリモートホスト指定です: $spec" >&2
            return 2
            ;;
        esac
      fi
      while [ -n "$stripped" ] && [ "$stripped" != "${stripped%/}" ]; do
        stripped="${stripped%/}"
      done
      stripped="${stripped%.git}"
      ;;
    git@*:*)
      REPO_URL="$spec"
      stripped="${spec#git@}"
      host="${stripped%%:*}"
      repo_sub="${stripped#*:}"
      case "$host" in
        ''|-*|*/*)
          echo "✗ 不正な git@ URL ホスト指定です: $spec" >&2
          return 2
          ;;
      esac
      case "$repo_sub" in
        ''|-*)
          echo "✗ 不正な git@ URL パス指定です: $spec" >&2
          return 2
          ;;
      esac
      stripped="${host}/${repo_sub}"
      while [ -n "$stripped" ] && [ "$stripped" != "${stripped%/}" ]; do
        stripped="${stripped%/}"
      done
      stripped="${stripped%.git}"
      ;;
    *:*|/*)
      echo "✗ --repo は owner/repo または URL（https:// / ssh:// / file:// / git@...）を指定してください: $spec" >&2
      return 2
      ;;
    */*)
      owner="${spec%%/*}"
      repo_part="${spec#*/}"
      repo_part="${repo_part%.git}"
      if [ -z "$owner" ] || [ -z "$repo_part" ] || [ "$repo_part" != "${repo_part#*/}" ]; then
        echo "✗ --repo の owner/repo 形式が不正です: $spec" >&2
        return 2
      fi
      case "$owner" in
        .|..|*[!A-Za-z0-9._-]*)
          echo "✗ --repo の owner 名が不正です: $owner" >&2
          return 2
          ;;
      esac
      case "$repo_part" in
        .|..|*[!A-Za-z0-9._-]*)
          echo "✗ --repo のリポジトリ名が不正です: $repo_part" >&2
          return 2
          ;;
      esac
      REPO_URL="https://github.com/${owner}/${repo_part}.git"
      REPO_SLUG="${owner}__${repo_part}"
      return 0
      ;;
    *)
      echo "✗ --repo は owner/repo または URL（https:// / ssh:// / file:// / git@...）を指定してください: $spec" >&2
      return 2
      ;;
  esac

  sanitized="$(printf '%s' "$stripped" | LC_ALL=C tr -cs 'A-Za-z0-9._-' '_')"
  while :; do
    case "$sanitized" in
      _*) sanitized="${sanitized#_}" ;;
      .*) sanitized="${sanitized#.}" ;;
      *_) sanitized="${sanitized%_}" ;;
      *.) sanitized="${sanitized%.}" ;;
      *) break ;;
    esac
  done
  case "$sanitized" in
    ''|.|..)
      h="$(printf '%s' "$REPO_URL" | cksum | awk '{print $1}')"
      sanitized="repo-${h}"
      ;;
  esac
  if [ "${#sanitized}" -gt 80 ]; then
    h="$(printf '%s' "$REPO_URL" | cksum | awk '{print $1}')"
    sanitized="$(printf '%s' "$sanitized" | LC_ALL=C cut -c1-60)-${h}"
  fi
  REPO_SLUG="$sanitized"
  return 0
}

run_git() {
  GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=true GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}" git -c credential.interactive=never "$@"
}

sync_repo_clone() {
  local target_dir="$1" repo_url="$2" check_only="$3"
  local parent_dir canon_dir top_dir actual_url git_dir dirty origin_head default_branch cur_branch

  command -v git >/dev/null 2>&1 || {
    echo "✗ git が必要です" >&2
    return 1
  }

  assert_safe_dir_target "$target_dir" || return 1

  if [ "$check_only" -eq 1 ]; then
    if [ ! -d "$target_dir/.git" ] || [ -L "$target_dir/.git" ]; then
      echo "✗ 管理クローンが見つかりません: $target_dir" >&2
      return 1
    fi
    canon_dir="$(CDPATH='' cd -P -- "$target_dir" 2>/dev/null && pwd -P)" || return 1
    top_dir="$(run_git -C "$canon_dir" rev-parse --show-toplevel 2>/dev/null || true)"
    [ "$top_dir" = "$canon_dir" ] || {
      echo "✗ クローン先が独立した Git リポジトリではありません: $canon_dir" >&2
      return 1
    }
    actual_url="$(run_git -C "$canon_dir" config --get remote.origin.url 2>/dev/null || true)"
    if [ "$(normalize_git_url "$actual_url")" != "$(normalize_git_url "$repo_url")" ]; then
      echo "✗ 管理クローンの origin URL が一致しません: ${actual_url:-<unset>} != $repo_url" >&2
      return 1
    fi
    return 0
  fi

  if [ ! -e "$target_dir" ]; then
    parent_dir="$(dirname -- "$target_dir")"
    mkdir -p -- "$parent_dir" || return 1
    if ! run_git clone -- "$repo_url" "$target_dir"; then
      echo "✗ リポジトリの取得に失敗しました: $repo_url -> $target_dir" >&2
      return 1
    fi
    echo "✓ クローン作成: $repo_url -> $target_dir"
    return 0
  fi

  if [ ! -d "$target_dir" ] || [ ! -d "$target_dir/.git" ] || [ -L "$target_dir/.git" ]; then
    echo "✗ クローン先が Git リポジトリではないため中止します: $target_dir" >&2
    return 1
  fi

  canon_dir="$(CDPATH='' cd -P -- "$target_dir" 2>/dev/null && pwd -P)" || return 1
  top_dir="$(run_git -C "$canon_dir" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ "$top_dir" != "$canon_dir" ]; then
    echo "✗ クローン先が独立した Git リポジトリではありません: $canon_dir" >&2
    return 1
  fi

  actual_url="$(run_git -C "$canon_dir" config --get remote.origin.url 2>/dev/null || true)"
  if [ "$(normalize_git_url "$actual_url")" != "$(normalize_git_url "$repo_url")" ]; then
    echo "✗ 管理クローンの origin URL が一致しません: ${actual_url:-<unset>} != $repo_url" >&2
    return 1
  fi

  git_dir="$(run_git -C "$canon_dir" rev-parse --absolute-git-dir 2>/dev/null || true)"
  if [ -z "$git_dir" ] || [ -e "$git_dir/MERGE_HEAD" ] || [ -e "$git_dir/REBASE_HEAD" ] \
     || [ -e "$git_dir/CHERRY_PICK_HEAD" ] || [ -e "$git_dir/BISECT_LOG" ] \
     || [ -d "$git_dir/rebase-merge" ] || [ -d "$git_dir/rebase-apply" ]; then
    echo "✗ 管理クローンでマージ/リベース等が進行中のため更新できません: $canon_dir" >&2
    return 1
  fi

  dirty="$(run_git -C "$canon_dir" status --porcelain 2>/dev/null || true)"
  if [ -n "$dirty" ]; then
    echo "✗ 管理クローンに未コミット変更があるため更新できません: $canon_dir" >&2
    return 1
  fi

  if ! run_git -C "$canon_dir" fetch --prune --quiet origin; then
    echo "✗ リモートの取得に失敗しました: $canon_dir" >&2
    return 1
  fi

  origin_head="$(run_git -C "$canon_dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [ -z "$origin_head" ]; then
    run_git -C "$canon_dir" remote set-head origin -a >/dev/null 2>&1 || true
    origin_head="$(run_git -C "$canon_dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  fi
  default_branch="${origin_head#origin/}"
  if [ -z "$default_branch" ]; then
    echo "✗ origin の既定ブランチを解決できません: $canon_dir" >&2
    return 1
  fi

  cur_branch="$(run_git -C "$canon_dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [ -z "$cur_branch" ] || [ "$cur_branch" != "$default_branch" ]; then
    echo "✗ 管理クローンが既定ブランチ (${default_branch}) ではないため更新できません (現在: ${cur_branch:-detached}): $canon_dir" >&2
    return 1
  fi

  if ! run_git -C "$canon_dir" merge --ff-only -- "origin/${default_branch}"; then
    echo "✗ fast-forward 更新に失敗しました: $canon_dir (origin/${default_branch})" >&2
    return 1
  fi
  return 0
}

record_sync_state() {
  local out_dir_canon="$1" src_mode="$2" src_root_canon="$3"
  local state_dir state_agy state_file base_json sel_json synced_json clone_canon=""
  local managed_bool="false" updated_at new_json

  state_dir="$(resolve_state_dir 2>/dev/null || true)"
  [ -n "$state_dir" ] || return 0
  state_agy="${state_dir}/antigravity"
  state_file="${state_agy}/sync-state.json"

  if ! assert_safe_dir_target "$state_dir" 2>/dev/null \
     || ! assert_safe_dir_target "$state_agy" 2>/dev/null \
     || ! assert_safe_file_target "$state_file" 2>/dev/null; then
    echo "⚠️ 同期状態パスが安全でないため保存をスキップします: $state_file" >&2
    return 0
  fi

  if ! mkdir -p -- "$state_agy" 2>/dev/null; then
    echo "⚠️ 同期状態ディレクトリを作成できないため保存をスキップします: $state_agy" >&2
    return 0
  fi

  base_json='{"version":1,"targets":{}}'
  if [ -f "$state_file" ]; then
    if jq -e 'type == "object" and (.targets | type == "object")' "$state_file" >/dev/null 2>&1; then
      base_json="$(cat "$state_file")"
    else
      echo "⚠️ 既存の同期状態ファイルが不正な JSON のため再初期化します: $state_file" >&2
    fi
  fi

  sel_json='[]'
  if [ "${#SELECTED_PLUGINS[@]}" -gt 0 ]; then
    sel_json="$(printf '%s\n' "${SELECTED_PLUGINS[@]}" | jq -R . | jq -s .)"
  fi

  synced_json='[]'
  if [ "${#SYNCED_PLUGIN_NAMES[@]}" -gt 0 ]; then
    synced_json="$(printf '%s\n' "${SYNCED_PLUGIN_NAMES[@]}" | jq -R . | jq -s 'unique')"
  fi

  if [ -n "$REPO_SPEC" ]; then
    managed_bool="true"
    clone_canon="$(CDPATH='' cd -P -- "$CLONE_DIR" 2>/dev/null && pwd -P)" || clone_canon="$CLONE_DIR"
  fi

  updated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  new_json="$(printf '%s\n' "$base_json" | jq \
    --arg out "$out_dir_canon" \
    --arg src "$src_root_canon" \
    --arg mode "$src_mode" \
    --arg repo "$REPO_SPEC" \
    --arg repo_url "$REPO_URL" \
    --arg clone_dir "$clone_canon" \
    --arg proj "$PROJECT_ROOT" \
    --arg now "$updated_at" \
    --argjson managed "$managed_bool" \
    --argjson selected "$sel_json" \
    --argjson synced "$synced_json" \
    '
    .version = 1
    | .targets = (.targets // {})
    | .targets[$out] = (.targets[$out] // {})
    | ((.targets[$out].sources[$src] // {}) |
        if ($repo | length) > 0 then
          {managedClone: true, repo: $repo, repoUrl: $repo_url, cloneDir: $clone_dir}
        elif (.managedClone == true) and ((.cloneDir // "") == $src) and (((.repoUrl // "") | length) > 0) then
          {managedClone: true}
          + (if ((.repo // "") | length) > 0 then {repo: .repo} else {} end)
          + {repoUrl: .repoUrl, cloneDir: .cloneDir}
        else
          {managedClone: $managed}
        end
      ) as $managed_meta
    | .targets[$out].sources = (
        (.targets[$out].sources // {})
        | to_entries
        | map(
            if .key == $src then
              .
            else
              (.value.syncedPlugins // []) as $orig_synced
              | ((.value.syncedPlugins // []) | map(select(. as $p | ($synced | index($p)) == null))) as $rem_synced
              | .value.syncedPlugins = $rem_synced
              | if ($rem_synced | length) == 0 then empty
                else
                  if (($orig_synced | length) > ($rem_synced | length)) then
                    if ((.value.selectedPlugins // []) | length) > 0 then
                      .value.selectedPlugins = ((.value.selectedPlugins // []) | map(select(. as $p | ($synced | index($p)) == null)))
                    else
                      .value.selectedPlugins = $rem_synced
                    end
                  else . end
                  | .
                end
            end
          )
        | from_entries
      )
    | .targets[$out].sources[$src] = (
        {
          mode: $mode,
          sourceRoot: $src,
          selectedPlugins: $selected,
          syncedPlugins: $synced,
          updatedAt: $now
        }
        + $managed_meta
        + (if ($proj | length) > 0 then {projectRoot: $proj} else {} end)
      )
    ' 2>/dev/null)" || {
    echo "⚠️ 同期状態 JSON の生成に失敗したため保存をスキップします: $state_file" >&2
    return 0
  }

  if ! write_atomic "$state_file" "$new_json" 2>/dev/null; then
    echo "⚠️ 同期状態ファイルの書き込みに失敗したため保存をスキップします: $state_file" >&2
  fi
  return 0
}

sync_one_plugin() {
  local raw_src="$1" src_dir manifest plugin_name rendered_plugin rendered_mcp=""
  local has_skills=0 has_mcp=0 dest_dir resolved_files="" rf current_link

  src_dir="$(CDPATH='' cd -P -- "$raw_src" 2>/dev/null && pwd -P)" || {
    echo "✗ プラグインディレクトリが見つかりません: $raw_src" >&2
    return 1
  }
  manifest="$src_dir/.claude-plugin/plugin.json"
  if [ ! -f "$manifest" ]; then
    echo "✗ .claude-plugin/plugin.json が見つかりません: $manifest" >&2
    return 1
  fi

  plugin_name="$(jq -r '.name // empty' "$manifest" 2>/dev/null)" || {
    echo "✗ plugin.json を解析できません: $manifest" >&2
    return 1
  }
  if ! validate_plugin_name "$plugin_name"; then
    echo "✗ プラグイン名が無効です（英小文字・数字・ハイフンのみ）: [${plugin_name}] ($manifest)" >&2
    return 1
  fi

  rendered_plugin="$(jq '
    {
      name: .name,
      description: (.description // ""),
      version: (.version // "")
    }
    + (if (.author | type) == "string" and (.author | length) > 0 then
        {author: .author}
      elif (.author | type) == "object" and ((.author.name // "") | length) > 0 then
        {author: ({name: .author.name} + (if ((.author.url // "") | length) > 0 then {url: .author.url} else {} end))}
      else {} end)
    + (if (.homepage | type) == "string" and (.homepage | length) > 0 then {homepage: .homepage} else {} end)
    + (if .repository != null then {repository: .repository} else {} end)
  ' "$manifest" 2>/dev/null)" || {
    echo "✗ plugin.json の変換に失敗しました: $manifest" >&2
    return 1
  }

  if [ -d "$src_dir/skills" ]; then
    has_skills=1
  fi

  if [ -f "$src_dir/.mcp.json" ]; then
    has_mcp=1
    if ! jq -e '.mcpServers | type == "object"' "$src_dir/.mcp.json" >/dev/null 2>&1; then
      echo "✗ .mcp.json の mcpServers が不正です: $src_dir/.mcp.json" >&2
      return 1
    fi

    if jq -e '
      [.mcpServers[]? |
        ((if (.command? | type) == "string" then [.command] else [] end) +
         (if (.args? | type) == "array" then [.args[]? | select(type == "string")] else [] end))[]
        | select(contains("${CLAUDE_PLUGIN_ROOT}"))
        | select(test("(^|/)\\.\\.(/|$)"))
      ] | length > 0
    ' "$src_dir/.mcp.json" >/dev/null 2>&1; then
      echo "✗ .mcp.json の参照パスにパストラバーサル（..）が含まれています: $src_dir/.mcp.json" >&2
      return 1
    fi

    resolved_files="$(jq -r --arg root "$src_dir" '
      [.mcpServers[]? |
        ((if (.command? | type) == "string" then [.command] else [] end) +
         (if (.args? | type) == "array" then [.args[]? | select(type == "string")] else [] end))[]
        | if startswith("${CLAUDE_PLUGIN_ROOT}/") then .
          elif test("^-[^=]*=\\$\\{CLAUDE_PLUGIN_ROOT\\}/") then sub("^[^=]*="; "")
          else empty end
        | split("${CLAUDE_PLUGIN_ROOT}") | join($root)
      ] | .[]' "$src_dir/.mcp.json" 2>/dev/null)" || {
      echo "✗ .mcp.json の参照パスを解決できません: $src_dir/.mcp.json" >&2
      return 1
    }

    if [ -n "$resolved_files" ]; then
      while IFS= read -r rf || [ -n "$rf" ]; do
        rf="${rf%$'\r'}"
        [ -n "$rf" ] || continue
        if [ ! -f "$rf" ]; then
          echo "✗ .mcp.json の参照先ファイルが見つかりません: $rf" >&2
          return 1
        fi
      done <<EOF
$resolved_files
EOF
    fi

    rendered_mcp="$(jq --arg root "$src_dir" --arg pname "$plugin_name" --arg proj "$PROJECT_ROOT" '
      def subst_root:
        if type == "string" then split("${CLAUDE_PLUGIN_ROOT}") | join($root) else . end;
      {
        mcpServers: (
          .mcpServers | to_entries | map(
            .key as $orig_key
            | .key = ($pname + "-" + $orig_key)
            | .value |= (
                (if has("command") then .command |= subst_root else . end)
                | (if has("args") and (.args | type) == "array" then .args |= map(subst_root) else . end)
                | (if ($proj | length) > 0 and $orig_key == "spec-docs" then
                    .env = ((.env // {}) + {"SPEC_DOCS_PROJECT_ROOT": $proj})
                  else . end)
              )
          ) | from_entries
        )
      }
    ' "$src_dir/.mcp.json" 2>/dev/null)" || {
      echo "✗ mcp_config.json の変換に失敗しました: $src_dir/.mcp.json" >&2
      return 1
    }
  fi

  dest_dir="$OUT_DIR/$plugin_name"
  assert_safe_dir_target "$dest_dir" || return 1

  if [ -e "$dest_dir/skills" ] && [ ! -L "$dest_dir/skills" ]; then
    echo "✗ 出力先の skills が symlink ではない実体（ディレクトリ/ファイル）のため中止します: $dest_dir/skills" >&2
    return 1
  fi

  if [ "$CHECK" -eq 1 ]; then
    if [ -L "$dest_dir/plugin.json" ] || [ -d "$dest_dir/plugin.json" ]; then
      echo "✗ 未同期（plugin.json が通常ファイルではありません）: $dest_dir/plugin.json" >&2
      return 1
    fi
    if ! json_matches_file "$dest_dir/plugin.json" "$rendered_plugin"; then
      echo "✗ 未同期（plugin.json）: $dest_dir/plugin.json" >&2
      return 1
    fi
    if [ "$has_skills" -eq 1 ]; then
      current_link="$(readlink "$dest_dir/skills" 2>/dev/null || true)"
      if [ ! -L "$dest_dir/skills" ] || [ "$current_link" != "$src_dir/skills" ]; then
        echo "✗ 未同期（skills symlink）: $dest_dir/skills" >&2
        return 1
      fi
    elif [ -e "$dest_dir/skills" ] || [ -L "$dest_dir/skills" ]; then
      echo "✗ 未同期（不要な skills が存在）: $dest_dir/skills" >&2
      return 1
    fi
    if [ "$has_mcp" -eq 1 ]; then
      if [ -L "$dest_dir/mcp_config.json" ] || [ -d "$dest_dir/mcp_config.json" ]; then
        echo "✗ 未同期（mcp_config.json が通常ファイルではありません）: $dest_dir/mcp_config.json" >&2
        return 1
      fi
      if ! json_matches_file "$dest_dir/mcp_config.json" "$rendered_mcp"; then
        echo "✗ 未同期（mcp_config.json）: $dest_dir/mcp_config.json" >&2
        return 1
      fi
    elif [ -e "$dest_dir/mcp_config.json" ] || [ -L "$dest_dir/mcp_config.json" ]; then
      echo "✗ 未同期（不要な mcp_config.json が存在）: $dest_dir/mcp_config.json" >&2
      return 1
    fi
    echo "✓ 最新: $plugin_name -> $dest_dir"
    return 0
  fi

  mkdir -p -- "$dest_dir" || return 1
  write_atomic "$dest_dir/plugin.json" "$rendered_plugin" || return 1

  if [ "$has_skills" -eq 1 ]; then
    rm -f -- "$dest_dir/skills" || return 1
    ln -s -- "$src_dir/skills" "$dest_dir/skills" || return 1
  elif [ -L "$dest_dir/skills" ]; then
    rm -f -- "$dest_dir/skills" || return 1
  fi

  if [ "$has_mcp" -eq 1 ]; then
    write_atomic "$dest_dir/mcp_config.json" "$rendered_mcp" || return 1
  elif [ -L "$dest_dir/mcp_config.json" ] || [ -e "$dest_dir/mcp_config.json" ]; then
    rm -f -- "$dest_dir/mcp_config.json" || return 1
  fi

  SYNCED_PLUGIN_NAMES+=("$plugin_name")
  echo "✓ 同期完了: $plugin_name -> $dest_dir"
  return 0
}

assert_safe_dir_target "$OUT_DIR" || exit 1

if [ -n "$REPO_SPEC" ]; then
  resolve_repo_spec "$REPO_SPEC" || exit $?
  if [ -z "$CLONE_DIR" ]; then
    state_dir="$(resolve_state_dir)" || {
      echo "✗ --clone-dir 未指定時は HOME または FF_DEV_TOOLKIT_STATE_DIR が必要です" >&2
      exit 1
    }
    CLONE_DIR="${state_dir}/antigravity/repos/${REPO_SLUG}"
  fi
  sync_repo_clone "$CLONE_DIR" "$REPO_URL" "$CHECK" || exit 1
  CLONE_DIR="$(CDPATH='' cd -P -- "$CLONE_DIR" 2>/dev/null && pwd -P)" || {
    echo "✗ 管理クローンが見つかりません: $CLONE_DIR" >&2
    exit 1
  }
  if [ -f "$CLONE_DIR/.claude-plugin/plugin.json" ] && [ -d "$CLONE_DIR/skills" ]; then
    if [ "${#SELECTED_PLUGINS[@]}" -gt 0 ]; then
      echo "✗ 単一プラグインリポジトリでは --plugin を指定できません: $CLONE_DIR" >&2
      exit 2
    fi
    PLUGIN_ROOT="$CLONE_DIR"
  elif [ -f "$CLONE_DIR/.claude-plugin/marketplace.json" ]; then
    MARKETPLACE_ROOT="$CLONE_DIR"
  else
    echo "✗ プラグイン定義（.claude-plugin/plugin.json + skills/ または .claude-plugin/marketplace.json）が見つかりません: $CLONE_DIR" >&2
    exit 1
  fi
fi

SOURCE_MODE=""
SOURCE_ROOT_CANON=""

if [ -n "$MARKETPLACE_ROOT" ]; then
  MKT_ROOT="$(CDPATH='' cd -P -- "$MARKETPLACE_ROOT" 2>/dev/null && pwd -P)" || {
    echo "✗ --marketplace-root が見つかりません: $MARKETPLACE_ROOT" >&2
    exit 1
  }
  MKT_JSON="$MKT_ROOT/.claude-plugin/marketplace.json"
  if [ ! -f "$MKT_JSON" ]; then
    echo "✗ marketplace.json が見つかりません: $MKT_JSON" >&2
    exit 1
  fi
  if ! jq -e '.plugins | type == "array"' "$MKT_JSON" >/dev/null 2>&1; then
    echo "✗ marketplace.json の plugins 配列が不正です: $MKT_JSON" >&2
    exit 1
  fi

  entries_tsv="$(jq -r '
    .plugins[] |
    [
      (.name // ""),
      (if (.source | type) == "string" then "local" else "external" end),
      (if (.source | type) == "string" then .source else (.source.repo // "") end)
    ] | @tsv
  ' "$MKT_JSON")" || {
    echo "✗ marketplace.json の解析に失敗しました: $MKT_JSON" >&2
    exit 1
  }

  matched_names=()
  attempted_count=0
  stale_or_failed=0

  while IFS="$(printf '\t')" read -r entry_name entry_kind entry_src || [ -n "${entry_name:-}" ]; do
    entry_src="${entry_src%$'\r'}"
    [ -n "${entry_name:-}" ] || continue
    if ! has_selected_plugin "$entry_name"; then
      continue
    fi
    matched_names+=("$entry_name")
    if [ "$entry_kind" != "local" ]; then
      if [ "${#SELECTED_PLUGINS[@]}" -gt 0 ]; then
        echo "✗ 外部ソースのため展開できません: ${entry_name} (${entry_src:-unknown})。対象リポジトリから --plugin-root で同期してください" >&2
        stale_or_failed=1
      else
        echo "ℹ️ 外部ソースのためスキップ: ${entry_name}（${entry_src:-別リポジトリ} から --plugin-root で同期してください）" >&2
      fi
      continue
    fi
    if ! validate_relative_source "$entry_src"; then
      echo "✗ 不正な相対パス source です: ${entry_name} -> [${entry_src}]" >&2
      exit 1
    fi
    if [ "$entry_src" = "./" ]; then
      target_dir="$MKT_ROOT"
    else
      target_dir="$MKT_ROOT/${entry_src#./}"
    fi
    attempted_count=$((attempted_count + 1))
    if ! sync_one_plugin "$target_dir"; then
      stale_or_failed=1
    fi
  done <<EOF
$entries_tsv
EOF

  if [ "${#SELECTED_PLUGINS[@]}" -gt 0 ]; then
    for req_name in "${SELECTED_PLUGINS[@]}"; do
      found_req=0
      if [ "${#matched_names[@]}" -gt 0 ]; then
        for got_name in "${matched_names[@]}"; do
          if [ "$got_name" = "$req_name" ]; then
            found_req=1
            break
          fi
        done
      fi
      if [ "$found_req" -eq 0 ]; then
        echo "✗ 指定されたプラグインが同期されませんでした: $req_name" >&2
        stale_or_failed=1
      fi
    done
  fi

  if [ "$stale_or_failed" -ne 0 ]; then
    exit 1
  fi
  if [ "$attempted_count" -eq 0 ]; then
    echo "✗ 同期対象のプラグインが 0 件でした" >&2
    exit 1
  fi
  SOURCE_MODE="marketplace"
  SOURCE_ROOT_CANON="$MKT_ROOT"
else
  TARGET_PLUGIN_ROOT="${PLUGIN_ROOT:-$DEFAULT_PLUGIN_ROOT}"
  SOURCE_ROOT_CANON="$(CDPATH='' cd -P -- "$TARGET_PLUGIN_ROOT" 2>/dev/null && pwd -P)" || {
    echo "✗ プラグインディレクトリが見つかりません: $TARGET_PLUGIN_ROOT" >&2
    exit 1
  }
  sync_one_plugin "$SOURCE_ROOT_CANON" || exit 1
  SOURCE_MODE="plugin"
fi

if [ "$CHECK" -eq 0 ]; then
  OUT_DIR_CANON="$(CDPATH='' cd -P -- "$OUT_DIR" 2>/dev/null && pwd -P)" || OUT_DIR_CANON="$OUT_DIR"
  record_sync_state "$OUT_DIR_CANON" "$SOURCE_MODE" "$SOURCE_ROOT_CANON"
fi
exit 0
