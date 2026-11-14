#!/usr/bin/env bash
# Google Antigravity 向けに ff-dev-toolkit の hooks/hooks.json を Antigravity 形式へ展開する。
#
# Antigravity の hooks.json は以下が Claude Code / grok CLI と非対称:
#   - トップレベルは {"ff-dev-toolkit": { ... }}（フック名キーでラップ）
#   - PreToolUse / PostToolUse は [{matcher, hooks:[...]}] だが、
#     SessionStart / PreInvocation（UserPromptSubmit 相当）/ Stop はフラットな handler 配列
#   - PreToolUse / PostToolUse のツール名は Antigravity 名（run_command / write_file / edit_file /
#     read_file / invoke_subagent / manage_subagents / manage_task）
#   - handler に async / onFailure / statusMessage / env を持てず、CLAUDE_PLUGIN_ROOT も自動設定されないため
#     --plugin-root を hook-shim.sh へ渡し、${CLAUDE_PLUGIN_ROOT} は生成時に展開せず実行時環境へ委ねる
#   - SubagentStart / SubagentStop / PermissionDenied は Antigravity hooks.json に存在しないためスキップして明示通知する
#
# 使い方: sync-hooks.sh [--plugin-root <dir>] [--out-dir <dir> | --out <file>] [--check]
#   --plugin-root  既定はこのスクリプトの 2 階層上（同梱位置）
#   --out-dir      出力先ディレクトリ（<dir>/hooks.json に書込。既定: ~/.gemini/config/plugins/ff-dev-toolkit）
#   --out          出力先ファイルパス（--out-dir と併用不可）
#   --check        書き換えず整合確認のみ（一致: 0、差分/欠落: 1）
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd -P)"
DEFAULT_PLUGIN_ROOT="$(CDPATH='' cd -P -- "$SCRIPT_DIR/../.." && pwd -P)"

PLUGIN_ROOT="$DEFAULT_PLUGIN_ROOT"
OUT_DIR=""
OUT_FILE=""
CHECK=0

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --plugin-root)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "✗ --plugin-root に空でない値が要ります" >&2; exit 2; }
      PLUGIN_ROOT="$2"
      shift 2
      ;;
    --out-dir)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "✗ --out-dir に空でない値が要ります" >&2; exit 2; }
      OUT_DIR="$2"
      shift 2
      ;;
    --out)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "✗ --out に空でない値が要ります" >&2; exit 2; }
      OUT_FILE="$2"
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
      echo "✗ 不明な引数です: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -n "$OUT_DIR" ] && [ -n "$OUT_FILE" ]; then
  echo "✗ --out-dir と --out は同時に指定できません" >&2
  exit 2
fi

if [ -z "$OUT_FILE" ]; then
  if [ -z "$OUT_DIR" ]; then
    [ -n "${HOME:-}" ] || { echo "✗ HOME が未設定のため既定の出力先を解決できません" >&2; exit 1; }
    OUT_DIR="${HOME%/}/.gemini/config/plugins/ff-dev-toolkit"
  fi
  OUT_FILE="${OUT_DIR%/}/hooks.json"
fi

command -v jq >/dev/null 2>&1 || { echo "✗ jq が必要です（Antigravity hooks.json の展開に jq を使用します）" >&2; exit 1; }

PLUGIN_ROOT="$(CDPATH='' cd -P -- "$PLUGIN_ROOT" 2>/dev/null && pwd -P)" || {
  echo "✗ --plugin-root が見つかりません: $PLUGIN_ROOT" >&2
  exit 1
}

HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"
SHIM="$PLUGIN_ROOT/scripts/antigravity/hook-shim.sh"

[ -f "$HOOKS_JSON" ] && [ -s "$HOOKS_JSON" ] || { echo "✗ hooks.json が見つからないか空です: $HOOKS_JSON" >&2; exit 1; }
[ -f "$SHIM" ] || { echo "✗ hook-shim.sh が見つかりません: $SHIM" >&2; exit 1; }

if ! jq -e '.hooks | type == "object"' "$HOOKS_JSON" >/dev/null 2>&1; then
  echo "✗ hooks.json の .hooks がオブジェクトではありません: $HOOKS_JSON" >&2
  exit 1
fi

skipped_events="$(jq -r '
  [ .hooks | keys[] | select(. != "SessionStart" and . != "UserPromptSubmit" and . != "PreToolUse" and . != "PostToolUse" and . != "Stop") ]
  | join(", ")
' "$HOOKS_JSON" 2>/dev/null || true)"

skipped_async="$(jq -r '
  [ .hooks
    | to_entries[]
    | select(.key == "SessionStart" or .key == "UserPromptSubmit" or .key == "PreToolUse" or .key == "PostToolUse" or .key == "Stop")
    | .key as $ev
    | (.value // [])[]
    | (.hooks // [])[]
    | select((.type // "") == "command" and (.command | type) == "string" and (.command | length > 0) and ((.async // false) == true))
    | ($ev + ":" + (.command | split(" ") | last | split("/") | last | gsub("[^A-Za-z0-9_.-]"; "")))
  ] | join(", ")
' "$HOOKS_JSON" 2>/dev/null || true)"

rendered="$(jq --arg root "$PLUGIN_ROOT" --arg shim "$SHIM" '
  def wrap_cmd($shim; $proot; $ev; $cmd; $on_fail):
    (
      [ "bash", $shim, "--plugin-root", $proot, "--event", $ev ]
      + (if ($ev == "PreToolUse" and ($on_fail // "") == "block") then [ "--on-failure", "block" ] else [] end)
      + [ "--", "bash", "-c", $cmd ]
    ) | map(@sh) | join(" ");
  def clean_handler($shim; $proot; $ev):
    select((.type // "") == "command" and (.command | type) == "string" and (.command | length > 0) and ((.async // false) != true))
    | { type: "command", command: wrap_cmd($shim; $proot; $ev; .command; (.onFailure // "")) }
      + (if (.timeout | type) == "number" then { timeout: .timeout } else {} end);
  def map_tool_token($tok):
    if $tok == "Bash" then ["run_command"]
    elif $tok == "Write" then ["write_file"]
    elif ($tok == "Edit" or $tok == "MultiEdit" or $tok == "NotebookEdit") then ["edit_file"]
    elif ($tok == "Read" or $tok == "Skill") then ["read_file"]
    elif ($tok == "Agent" or $tok == "Task") then ["invoke_subagent"]
    elif $tok == "TaskStop" then ["manage_subagents", "manage_task"]
    else [$tok]
    end;
  def map_matcher($m):
    if ($m | type) != "string" or ($m | length) == 0 then "*"
    elif ($m | startswith("^")) then $m
    else
      [ ($m | split("|")[] | map_tool_token(.)[]) ]
      | reduce .[] as $item ([]; if index($item) then . else . + [$item] end)
      | join("|")
    end;
  def flat_handlers($arr; $shim; $proot; $ev):
    [ ($arr // [])[] | (.hooks // [])[] | clean_handler($shim; $proot; $ev) ];
  def grouped_handlers($arr; $shim; $proot; $ev):
    [ ($arr // [])[]
      | .matcher as $raw_m
      | [ (.hooks // [])[] | clean_handler($shim; $proot; $ev) ] as $hs
      | select(($hs | length) > 0)
      | { matcher: map_matcher($raw_m), hooks: $hs }
    ];
  {
    "ff-dev-toolkit": (
      {}
      + (flat_handlers(.hooks.SessionStart; $shim; $root; "SessionStart") as $ss | if ($ss | length) > 0 then { SessionStart: $ss } else {} end)
      + (flat_handlers(.hooks.UserPromptSubmit; $shim; $root; "PreInvocation") as $pi | if ($pi | length) > 0 then { PreInvocation: $pi } else {} end)
      + (grouped_handlers(.hooks.PreToolUse; $shim; $root; "PreToolUse") as $pre | if ($pre | length) > 0 then { PreToolUse: $pre } else {} end)
      + (grouped_handlers(.hooks.PostToolUse; $shim; $root; "PostToolUse") as $post | if ($post | length) > 0 then { PostToolUse: $post } else {} end)
      + (flat_handlers(.hooks.Stop; $shim; $root; "Stop") as $st | if ($st | length) > 0 then { Stop: $st } else {} end)
    )
  }
' "$HOOKS_JSON")" || {
  echo "✗ hooks.json の変換に失敗しました: $HOOKS_JSON" >&2
  exit 1
}

handler_count="$(printf '%s' "$rendered" | jq '
  ."ff-dev-toolkit" as $root
  | (
      ($root.SessionStart // [])
      + ($root.PreInvocation // [])
      + ($root.Stop // [])
      + [ ($root.PreToolUse // [])[] | (.hooks // [])[] ]
      + [ ($root.PostToolUse // [])[] | (.hooks // [])[] ]
    ) | length
' 2>/dev/null || echo 0)"

if [ "${handler_count:-0}" -le 0 ]; then
  echo "✗ 展開可能な Antigravity hook handler が 0 件です: $HOOKS_JSON" >&2
  exit 1
fi

assert_safe_target() {
  local target="$1"
  local abs_target="$target"
  local home_prefix=""
  local probe=""
  if [ -L "$target" ] || [ -d "$target" ]; then
    echo "✗ 出力先が通常ファイルではない（symlink またはディレクトリ）ため中止します: ${target}" >&2
    return 1
  fi
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
      /tmp|/var|/etc|/private|/Users|/home) break ;;
    esac
    if [ -n "$home_prefix" ] && [ "$probe" = "$home_prefix" ]; then
      break
    fi
    if [ -L "$probe" ]; then
      echo "✗ 出力先の親ディレクトリが symlink のため中止します: ${probe}" >&2
      return 1
    fi
    if [ -e "$probe" ] && [ ! -d "$probe" ]; then
      echo "✗ 出力先の親パスがディレクトリではないため中止します: ${probe}" >&2
      return 1
    fi
    probe="$(dirname -- "$probe")"
  done
  return 0
}

assert_safe_target "$OUT_FILE" || exit 1

if [ "$CHECK" -eq 1 ]; then
  if [ -f "$OUT_FILE" ]; then
    existing_canon="$(jq -S . "$OUT_FILE" 2>/dev/null)" || existing_canon=""
    rendered_canon="$(printf '%s' "$rendered" | jq -S .)"
    if [ -n "$existing_canon" ] && [ "$existing_canon" = "$rendered_canon" ]; then
      echo "✓ 最新: $OUT_FILE"
      exit 0
    fi
  fi
  echo "✗ 未同期: ${OUT_FILE}（sync-hooks.sh を再実行してください）" >&2
  exit 1
fi

out_parent="$(dirname -- "$OUT_FILE")"
mkdir -p -- "$out_parent"
out_parent_real="$(CDPATH='' cd -P -- "$out_parent" && pwd -P)"
out_base="$(basename -- "$OUT_FILE")"
if [ -L "${out_parent_real}/${out_base}" ] || [ -d "${out_parent_real}/${out_base}" ]; then
  echo "✗ 出力先が通常ファイルではない（symlink またはディレクトリ）ため中止します: ${out_parent_real}/${out_base}" >&2
  exit 1
fi
tmp_file="$(mktemp "${out_parent_real}/.${out_base}.tmp.XXXXXX")"
cleanup() {
  if [ -n "${tmp_file:-}" ] && [ -f "$tmp_file" ]; then
    rm -f -- "$tmp_file"
  fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' HUP INT TERM

printf '%s\n' "$rendered" > "$tmp_file"
mv -f -- "$tmp_file" "${out_parent_real}/${out_base}"

echo "✓ Antigravity hooks 展開完了: $OUT_FILE"
echo "  plugin root: $PLUGIN_ROOT"
echo "  handlers: $handler_count"
if [ -n "$skipped_events" ]; then
  echo "ℹ️ Antigravity 未対応イベントのためスキップ: $skipped_events"
fi
if [ -n "$skipped_async" ]; then
  echo "ℹ️ Antigravity 非同期非対応のためスキップ: $skipped_async"
fi
