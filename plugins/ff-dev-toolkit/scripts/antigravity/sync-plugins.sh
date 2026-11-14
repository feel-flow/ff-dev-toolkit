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
#   sync-plugins.sh [--plugin-root <dir> | --marketplace-root <dir>] [--plugin <name> ...]
#                   [--out-dir <dir>] [--project-root <dir>] [--check]
#   --plugin-root <dir>       単一プラグインのルート（既定: 同梱 ff-dev-toolkit）
#   --marketplace-root <dir>  .claude-plugin/marketplace.json からローカルプラグインを一括展開
#   --plugin <name>           --marketplace-root 時に展開対象を名前で絞る（複数回指定可）
#   --out-dir <dir>           出力先ディレクトリ（既定: ~/.gemini/config/plugins）
#   --project-root <dir>      spec-docs MCP の SPEC_DOCS_PROJECT_ROOT に設定するディレクトリ
#   --check                   書き込まずに最新（0）/ 未同期・不整合（1）を検査する
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd -P)"
DEFAULT_PLUGIN_ROOT="$(CDPATH='' cd -P -- "$SCRIPT_DIR/../.." && pwd -P)"

PLUGIN_ROOT=""
MARKETPLACE_ROOT=""
OUT_DIR=""
PROJECT_ROOT=""
CHECK=0
SELECTED_PLUGINS=()

usage() {
  sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'
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

if [ -n "$PLUGIN_ROOT" ] && [ -n "$MARKETPLACE_ROOT" ]; then
  echo "✗ --plugin-root と --marketplace-root は同時に指定できません" >&2
  exit 2
fi

if [ -z "$MARKETPLACE_ROOT" ] && [ "${#SELECTED_PLUGINS[@]}" -gt 0 ]; then
  echo "✗ --plugin は --marketplace-root と組み合わせて指定してください" >&2
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

write_atomic() {
  local target="$1" content="$2" dir tmp
  dir="$(dirname -- "$target")" || return 1
  mkdir -p "$dir" || return 1
  tmp="$(mktemp "$target.XXXXXX")" || return 1
  if ! printf '%s\n' "$content" > "$tmp" || ! mv "$tmp" "$target"; then
    rm -f "$tmp" 2>/dev/null || true
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

    resolved_files="$(jq -r --arg root "$src_dir" '
      [.mcpServers[]? |
        ((if (.command? | type) == "string" then [.command] else [] end) +
         (if (.args? | type) == "array" then [.args[]? | select(type == "string")] else [] end))[]
        | select(startswith("${CLAUDE_PLUGIN_ROOT}/"))
        | split("${CLAUDE_PLUGIN_ROOT}") | join($root)
      ] | .[]' "$src_dir/.mcp.json" 2>/dev/null)" || {
      echo "✗ .mcp.json の参照パスを解決できません: $src_dir/.mcp.json" >&2
      return 1
    }

    if [ -n "$resolved_files" ]; then
      while IFS= read -r rf || [ -n "$rf" ]; do
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

  if [ -e "$dest_dir/skills" ] && [ ! -L "$dest_dir/skills" ]; then
    echo "✗ 出力先の skills が symlink ではない実体（ディレクトリ/ファイル）のため中止します: $dest_dir/skills" >&2
    return 1
  fi

  if [ "$CHECK" -eq 1 ]; then
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

  mkdir -p "$dest_dir" || return 1
  write_atomic "$dest_dir/plugin.json" "$rendered_plugin" || return 1

  if [ "$has_skills" -eq 1 ]; then
    rm -f "$dest_dir/skills" || return 1
    ln -s "$src_dir/skills" "$dest_dir/skills" || return 1
  elif [ -L "$dest_dir/skills" ]; then
    rm -f "$dest_dir/skills" || return 1
  fi

  if [ "$has_mcp" -eq 1 ]; then
    write_atomic "$dest_dir/mcp_config.json" "$rendered_mcp" || return 1
  elif [ -L "$dest_dir/mcp_config.json" ] || [ -e "$dest_dir/mcp_config.json" ]; then
    rm -f "$dest_dir/mcp_config.json" || return 1
  fi

  echo "✓ 同期完了: $plugin_name -> $dest_dir"
  return 0
}

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
  exit 0
fi

TARGET_PLUGIN_ROOT="${PLUGIN_ROOT:-$DEFAULT_PLUGIN_ROOT}"
sync_one_plugin "$TARGET_PLUGIN_ROOT"
