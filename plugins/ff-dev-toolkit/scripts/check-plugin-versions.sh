#!/usr/bin/env bash
# GitHub / Claude Code registry / Desktop snapshot の読み取り専用検査。bash 3.2 対応。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SESSIONS_DIR="$HOME/Library/Application Support/Claude/local-agent-mode-sessions"
FORMAT=text
CATALOG_COMPLETE=1
usage() {
  echo 'Usage: check-plugin-versions.sh [--config-dir PATH] [--sessions-dir PATH] [--json]'
  echo 'Exit: 0=検査完了（更新ありを含む）, 2=確認不可あり, 1=起動不能/不正引数'
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config-dir|--sessions-dir)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { usage >&2; exit 1; }
      if [ "$1" = --config-dir ]; then CONFIG_DIR="$2"; else SESSIONS_DIR="$2"; fi
      shift 2 ;;
    --json) FORMAT=json; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done
for dependency in jq gh; do
  command -v "$dependency" >/dev/null 2>&1 || { echo "必要なコマンドがありません: $dependency" >&2; exit 1; }
done
[ -r "$SCRIPT_DIR/lib/plugin-versions.jq" ] || { echo '判定ライブラリがありません' >&2; exit 1; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/plugin-versions.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
printf '{}\n' > "$WORK/cache.json"
: > "$WORK/results.jsonl"
: > "$WORK/catalog.jsonl"
: > "$WORK/notes.jsonl"

jql() { jq -L "$SCRIPT_DIR/lib" "$@"; }
field() { jq -r "$2 // empty" <<< "$1"; }
note() { jq -cn --arg text "$1" '$text' >> "$WORK/notes.jsonl"; }
emit() {
  local detail="${3:-}"
  [ -n "$detail" ] || detail='{}'
  jq -cn --argjson row "$ROW" --arg status "$1" --arg reason "$2" \
    --argjson detail "$detail" '$row + $detail + {status:$status,reason:$reason}' >> "$WORK/results.jsonl"
}

# 同一リクエストを実行内だけで共有する。失敗もキャッシュし、部分失敗で残りを止めない。
api() {
  local endpoint="$1" ref="${2:-}" key cached target
  key="$endpoint|$ref"
  cached="$(jq -r --arg key "$key" '.[$key] // empty' "$WORK/cache.json")"
  if [ -n "$cached" ]; then [ -f "$cached.ok" ] && printf '%s\n' "$cached"; return; fi
  target="$WORK/api-$(jq length "$WORK/cache.json").json"
  jq --arg key "$key" --arg target "$target" '. + {($key):$target}' "$WORK/cache.json" > "$WORK/cache-next.json"
  mv "$WORK/cache-next.json" "$WORK/cache.json"
  local args=(api --hostname github.com --method GET -H 'Accept: application/vnd.github.raw+json' "$endpoint")
  [ -z "$ref" ] || args+=(-f "ref=$ref")
  if gh "${args[@]}" > "$target" 2> "$WORK/api-error" && jq -e 'type == "object" or type == "array"' "$target" >/dev/null 2>&1; then
    : > "$target.ok"
    printf '%s\n' "$target"
  else return 1; fi
}

location() {
  local source="$1" directory origin prefix
  if [ "$(field "$source" '.source')" = directory ]; then
    directory="$(field "$source" '.path')"
    [ -n "$directory" ] && [ -d "$directory" ] || return 1
    # 本来の source directory 以外へ fallback しない。
    origin="$(git -C "$directory" remote get-url origin 2>/dev/null)" || return 1
    prefix="$(git -C "$directory" rev-parse --show-prefix 2>/dev/null)" || return 1
    jql -cn --arg url "$origin" --arg prefix "$prefix" \
      'include "plugin-versions"; {repo:($url|github_repo),path:($prefix|relative_path),ref:""}' 2>/dev/null
  else
    jql -cn --argjson source "$source" 'include "plugin-versions"; $source|source_location({}; "")' 2>/dev/null
  fi
}

build_catalog() {
  local entry market source loc repo ref path manifest plugin resolved
  while IFS= read -r entry; do
    market="$(field "$entry" '.key')"
    source="$(jq -ec '.value | objects | .source | objects' <<< "$entry")" || { CATALOG_COMPLETE=0; continue; }
    if ! loc="$(location "$source")"; then CATALOG_COMPLETE=0; continue; fi
    repo="$(field "$loc" '.repo')"; ref="$(field "$loc" '.ref')"; path="$(field "$loc" '.path')"
    [ -z "$path" ] || path="$path/"
    path="$(jq -rn --arg p "${path}.claude-plugin/marketplace.json" '$p|split("/")|map(@uri)|join("/")')"
    if ! manifest="$(api "repos/$repo/contents/$path" "$ref")"; then CATALOG_COMPLETE=0; continue; fi
    if ! jq -e '.plugins | type == "array"' "$manifest" >/dev/null 2>&1; then CATALOG_COMPLETE=0; continue; fi
    if ! jq -e '.plugins | all(.[]; type == "object" and (.name|type == "string" and length > 0))' "$manifest" >/dev/null 2>&1; then
      CATALOG_COMPLETE=0
    fi
    jq -c '.plugins[] | objects | select(.name|type == "string" and length > 0)' "$manifest" > "$WORK/plugins.jsonl"
    while IFS= read -r plugin; do
      if resolved="$(jql -cn --argjson p "$plugin" --argjson parent "$loc" --slurpfile m "$manifest" \
        'include "plugin-versions"; $p.source | source_location($parent; ($m[0].metadata.pluginRoot // ""))' 2>/dev/null)"; then
        jq -cn --arg market "$market" --argjson plugin "$plugin" --argjson loc "$resolved" \
          '{marketplace:$market,name:$plugin.name,location:$loc}' >> "$WORK/catalog.jsonl"
      else
        jq -cn --arg market "$market" --argjson plugin "$plugin" \
          '{marketplace:$market,name:$plugin.name,location:null}' >> "$WORK/catalog.jsonl"
      fi
    done < "$WORK/plugins.jsonl"
  done < "$WORK/market-entries.jsonl"
  jq -s '.' "$WORK/catalog.jsonl" > "$WORK/catalog.json"
}

check_row() {
  local name market candidates loc repo path ref remote version installed comparison sha commits last compare behind detail
  name="$(field "$ROW" '.plugin')"; market="$(field "$ROW" '.marketplace')"
  if [ -z "$market" ] && [ "$CATALOG_COMPLETE" != 1 ]; then
    emit unknown 'marketplace 一覧に取得不能・不正な登録があり、名前だけでは一意性を確認できません'; return
  fi
  candidates="$(jq -c --arg name "$name" --arg market "$market" \
    '[.[] | select(.name == $name and ($market == "" or .marketplace == $market))]' "$WORK/catalog.json")"
  if [ "$(jq length <<< "$candidates")" != 1 ]; then emit unknown '参照先を一意に解決できません（登録・権限・marketplace を確認）'; return; fi
  loc="$(jq -c '.[0].location' <<< "$candidates")"
  if [ "$loc" = null ]; then emit unknown '非対応の plugin source'; return; fi
  repo="$(field "$loc" '.repo')"; path="$(field "$loc" '.path')"; ref="$(field "$loc" '.ref')"
  ROW="$(jq -c --argjson loc "$loc" '. + {source:$loc}' <<< "$ROW")"
  local manifest_path="${path:+$path/}.claude-plugin/plugin.json"
  manifest_path="$(jq -rn --arg p "$manifest_path" '$p|split("/")|map(@uri)|join("/")')"
  if ! remote="$(api "repos/$repo/contents/$manifest_path" "$ref")"; then emit unknown 'GitHub plugin.json を取得できません'; return; fi
  if ! jq -e --arg name "$name" 'type == "object" and .name == $name' "$remote" >/dev/null 2>&1; then
    emit unknown 'GitHub plugin.json の形式または名前が不一致'; return
  fi
  if ! jq -e '.version == null or (.version|type == "string" and length > 0)' "$remote" >/dev/null 2>&1; then
    emit unknown 'GitHub version 宣言の形式が不正'; return
  fi
  version="$(jq -r '.version // empty' "$remote")"
  installed="$(field "$ROW" '.installedVersion')"
  if [ -n "$version" ]; then
    comparison="$(jql -cn --arg a "$installed" --arg b "$version" 'include "plugin-versions"; semver_compare($a;$b)')"
    detail="$(jq -cn --arg version "$version" '{latestVersion:$version,method:"semver"}')"
    case "$comparison" in
      -1) emit outdated '参照版より古いバージョン' "$detail" ;;
      0) emit current '参照版と同じバージョン' "$detail" ;;
      1) emit ahead 'ローカルのバージョンが参照版より先行' "$detail" ;;
      *) emit unknown 'バージョンが不足または SemVer として比較不能' "$detail" ;;
    esac
    return
  fi
  sha="$(field "$ROW" '.installedSha')"
  if ! [[ "$sha" =~ ^[0-9a-fA-F]{40}$ ]]; then emit unknown 'version 宣言がなく installed gitCommitSha も不足'; return; fi
  local endpoint="repos/$repo/commits?per_page=1"
  [ -z "$path" ] || endpoint="$endpoint&path=$(jq -rn --arg p "$path" '$p|@uri')"
  [ -z "$ref" ] || endpoint="$endpoint&sha=$(jq -rn --arg r "$ref" '$r|@uri')"
  if ! commits="$(api "$endpoint")"; then emit unknown '対象ディレクトリの最終変更を取得できません'; return; fi
  if ! last="$(jq -er 'if type == "array" then .[0] | objects | .sha | strings else empty end' "$commits" 2>/dev/null)"; then
    emit unknown '最終変更 SHA が不正'; return
  fi
  if ! [[ "$last" =~ ^[0-9a-fA-F]{40}$ ]]; then emit unknown '最終変更 SHA が不正'; return; fi
  if ! compare="$(api "repos/$repo/compare/$last...$sha")"; then emit unknown 'commit の祖先関係を確認できません'; return; fi
  if ! jq -e '(.behind_by | type == "number" and . >= 0 and floor == .) and
      (.status == "ahead" or .status == "behind" or .status == "identical" or .status == "diverged")' "$compare" >/dev/null 2>&1; then
    emit unknown 'compare 応答が不正'; return
  fi
  behind="$(jq '.behind_by' "$compare")"
  detail="$(jq -cn --arg last "$last" --argjson behind "$behind" '{latestSha:$last,behindBy:$behind,method:"ancestry"}')"
  if [ "$behind" -gt 0 ]; then emit outdated 'behind_by > 0' "$detail"; else emit current 'behind_by = 0（SHA の相違だけでは更新ありにしない）' "$detail"; fi
}

check_installed() {
  local registry="$CONFIG_DIR/plugins/installed_plugins.json" entry
  ROW='{"layer":"local","plugin":"(registry)"}'
  if ! jq -e 'type == "object" and (.plugins|type == "object")' "$registry" >/dev/null 2>&1; then
    emit unknown 'installed_plugins.json がありません、または不正です'; return
  fi
  jq -c '.plugins|to_entries[]' "$registry" > "$WORK/installed-entries.jsonl"
  while IFS= read -r entry; do
    ROW="$(jq -c '{layer:"local",plugin:(.key|split("@")[0]),marketplace:(.key|split("@")[1] // "")}' <<< "$entry")"
    if ! jq -e '.value|type == "array" and length > 0 and all(.[]; type == "object")' <<< "$entry" >/dev/null 2>&1; then
      emit unknown 'インストール登録の形式が不正'; continue
    fi
    jq -c --argjson row "$ROW" '.value[] | $row + {scope:(.scope // "unknown"),projectPath:(.projectPath // ""),
      installedVersion:(.version // ""),installedSha:(.gitCommitSha // "")}' <<< "$entry" > "$WORK/installed-rows.jsonl"
    while IFS= read -r ROW; do check_row; done < "$WORK/installed-rows.jsonl"
  done < "$WORK/installed-entries.jsonl"
}

check_desktop() {
  local rpm manifest file entry id name market version sha session
  if [ ! -e "$SESSIONS_DIR" ]; then note 'Desktop セッション保存先なし（検査対象なし）'; return; fi
  ROW='{"layer":"desktop","plugin":"(sessions)"}'
  if [ ! -d "$SESSIONS_DIR" ]; then emit unknown 'Desktop セッション保存先がディレクトリではありません'; return; fi
  if ! find "$SESSIONS_DIR" -type d -name rpm -print0 > "$WORK/rpms" 2> "$WORK/scan-error"; then emit unknown 'Desktop セッション走査に失敗（一部のみ検査）'; fi
  while IFS= read -r -d '' rpm; do
    session="${rpm#"$SESSIONS_DIR"/}"; session="${session%/rpm}"
    manifest="$rpm/manifest.json"
    ROW="$(jq -cn --arg session "$session" '{layer:"desktop",plugin:"(manifest)",session:$session}')"
    if ! jq -e '.plugins|type == "array" and all(.[]; type == "object")' "$manifest" >/dev/null 2>&1; then
      emit unknown 'Desktop manifest がありません、または不正です'
      printf '[]\n' > "$WORK/desktop-manifest.json"
    else jq '.plugins' "$manifest" > "$WORK/desktop-manifest.json"; fi
    # manifest に載らない実体も検査する。逆に実体のない登録も確認不可として残す。
    : > "$WORK/desktop-files.jsonl"
    if ! find "$rpm" -mindepth 3 -maxdepth 3 -type f -path '*/plugin_*/.claude-plugin/plugin.json' -print0 > "$WORK/snapshot-paths" 2> "$WORK/scan-error"; then
      emit unknown 'Desktop plugin 実体の走査に失敗（一部のみ検査）'
    fi
    while IFS= read -r -d '' file; do
      id="${file%/.claude-plugin/plugin.json}"; id="${id##*/}"
      jq -cn --arg id "$id" --arg file "$file" '{id:$id,file:$file}' >> "$WORK/desktop-files.jsonl"
    done < "$WORK/snapshot-paths"
    jq -cs --slurpfile m "$WORK/desktop-manifest.json" \
      '. + [$m[0][]|{id,name,marketplaceName}] | group_by(.id) | .[] | add' "$WORK/desktop-files.jsonl" > "$WORK/desktop-entries.jsonl"
    while IFS= read -r entry; do
      id="$(field "$entry" '.id')"; file="$(field "$entry" '.file')"
      name="$(field "$entry" '.name')"; market="$(field "$entry" '.marketplaceName')"
      ROW="$(jq -cn --arg name "${name:-$id}" --arg market "$market" --arg session "$session" --arg id "$id" \
        '{layer:"desktop",plugin:$name,marketplace:$market,session:$session,snapshot:$id}')"
      if [ ! -f "$file" ] || ! jq -e 'type == "object" and (.name|type == "string" and length > 0)' "$file" >/dev/null 2>&1; then
        emit unknown 'Desktop plugin.json がありません、または不正です'; continue
      fi
      if [ -n "$name" ] && [ "$name" != "$(jq -r .name "$file")" ]; then emit unknown 'Desktop manifest と実体の名前が不一致'; continue; fi
      ROW="$(jq -c --argjson row "$ROW" '$row + {plugin:.name,installedVersion:(.version // ""),installedSha:(.gitCommitSha // "")}' "$file")"
      check_row
    done < "$WORK/desktop-entries.jsonl"
  done < "$WORK/rpms"
}

ROW='{"layer":"registry","plugin":"(marketplaces)"}'
if jq -e 'type == "object"' "$CONFIG_DIR/plugins/known_marketplaces.json" >/dev/null 2>&1; then
  jq -c 'to_entries[]' "$CONFIG_DIR/plugins/known_marketplaces.json" > "$WORK/market-entries.jsonl"
else
  CATALOG_COMPLETE=0
  emit unknown 'known_marketplaces.json がありません、または不正です'
  : > "$WORK/market-entries.jsonl"
fi
build_catalog
check_installed
check_desktop
jq -s --slurpfile notes "$WORK/notes.jsonl" '
  map(if .layer == "desktop" and .status == "outdated" then . + {action:"ローカル更新では解消できません。Desktop でプラグインを再登録し、新しいセッションで再検査してください。"} else . end)
  | {results:., summary:{total:length,outdated:map(select(.status=="outdated"))|length,
      current:map(select(.status=="current"))|length,ahead:map(select(.status=="ahead"))|length,
      unknown:map(select(.status=="unknown"))|length},notes:$notes}' "$WORK/results.jsonl" > "$WORK/report.json"
if [ "$FORMAT" = json ]; then cat "$WORK/report.json"; else
  jq -r '.results[] | [.layer, .plugin, (.marketplace // "-"), (.session // .scope // "-"),
    ({outdated:"更新あり",current:"最新",ahead:"ローカル先行",unknown:"確認不可"}[.status]),
    (if .method=="ancestry" then .installedSha else (.installedVersion // "-") end), (.latestVersion // .latestSha // "-"),
    .reason, (.action // ""), ((.source // {})|tostring)]
    | map(if type == "object" or type == "array" then tojson else . end) | @tsv' "$WORK/report.json"
  jq -r '.summary|"集計: 合計=\(.total) 更新あり=\(.outdated) 最新=\(.current) ローカル先行=\(.ahead) 確認不可=\(.unknown)"' "$WORK/report.json"
  jq -r '.notes[]' "$WORK/report.json"
fi
[ "$(jq '.summary.unknown' "$WORK/report.json")" -eq 0 ] || exit 2
