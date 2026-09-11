#!/usr/bin/env bash
# GitHub / Claude Code registry / Desktop snapshot の読み取り専用検査。bash 3.2 対応。
set -euo pipefail

# provenance の 1 行は、ガード block 内の basename allowlist で抑止している。本スクリプトの
# 出力は JSON / 集計行で、stderr は「異常があったときだけ出る」ことを呼び出し側が前提に
# している。停止の判定と案内は抑止されない。
# ff-dev-toolkit-script-root-guard:start
# plugin root 固定ガード（script 側）。同じ停止を skill 本文の契約節も述べているが、
# ホストが実行部だけを解決済み絶対 path として注入し契約節が本文から落ちた経路では、
# 散文のガードはちょうどそのとき手元に無い（防御が守ろうとしている失敗と、防御が
# 失われる条件が同じ）。実行部と同じファイルへ置くことで、契約を読んでいない consumer
# でも止まる。**候補は探しに行かない** — cache / marketplace / 旧インストール領域の
# 走査も version 名の並べ替えによる選び直しもしない。それが本ガードの防ごうとしている
# 失敗そのもので、探索を足すと防御が防御対象を踏む。渡された handoff を canonical 化
# して自分の実体位置と比べるだけにする。handoff が 1 つも無い直接起動（端末・テスト・
# CI の pin 実行）は止めない — 比較対象が無い状態を不一致とみなすと、正規の直接起動が
# 全部止まる。
#
# 到達性は呼び出し側とセットで成り立つ。host は plugin root を Bash tool の環境へ
# export せず、実行部テキストへ解決済みの値を差し込むだけなので、handoff を運ぶのが
# skill 本文の resolver だけだと「本文が落ちた」ちょうどそのときに handoff も消え、
# ガードは比較対象なしで素通しになる。そこで固定 root 経由の実行部は
# `FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/<名>"`
# の形にして handoff を**同じ 1 行へ**載せる。実行するスクリプトの path だけを別領域へ
# 書き換える事故は、この 1 行の中の不一致として検出できる。
#
# 判定不能は素通しではなく停止に倒す（fail-closed）。更新中の部分的な消失では、
# 判定材料（別 plugin かどうかを言う manifest）そのものが壊れた領域の内側にある。
#
# 外部コマンドを使わない。PATH が壊れた環境はこのガードが最後の砦になる場面そのもので、
# dirname / grep / sed に依存すると「自分の位置を判定できないまま素通し」になる。
# その代わり builtin 側の環境依存を自分で閉じる: path の canonical 化はすべて
# `CDPATH= cd -P --` で行う。`cd` は CDPATH が効くと**別のdirectoryへ移動したうえで
# 移動先を stdout へ出す**ので、export された CDPATH に同名の subdirectory があると
# 相対起動（`bash scripts/<名>`）で自分の位置を取り違え、コマンド置換も 2 行になる。
# 「止めない」と明文で約束している端末・テスト・CI の直接起動が、正規の handoff 付き
# でも止まっていた。各 script の複製は byte 一致で、tests/plugin-root-contract が固定する。
ff_script_root_guard_manifest_field() { # <plugin.json> <キー> → 値をstdoutへ / 読めなければ非0
  # JSON を「文字列の外 / 中」に分けて走査し、**root object 直下（ネスト深さ 1）のキー**
  # だけを返す。行単位に最初の `"<キー>"` を拾う形だと、`author` のような入れ子 object が
  # top-level の `name` より前にある manifest で `author.name` を掴み、別 plugin と誤読して
  # 照合ごと飛ばす（= fail-open）。同じ判定を docs-template の resolver fence の awk も
  # 「`{` 直後の name marker」として要求しており、厳しさを揃える。fence と違って version も
  # 読むので「最初のキー」ではなく「深さ 1 のキー」に寄せる。
  local file="$1" key="$2" line="" rest="" seg="" tmp="" acc=""
  local depth=0 instr=0 expect=0 last="" bs=0
  # symlink・非通常ファイル・読めないものは「確認できない」に倒す（除外の根拠にしない）。
  [ -f "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    rest="$line"
    while [ -n "$rest" ]; do
      if [ "$instr" -eq 1 ]; then
        case "$rest" in
          *'"'*) seg="${rest%%'"'*}"; rest="${rest#*'"'}" ;;
          *) acc="${acc}${rest}"; rest=""; continue ;;
        esac
        # 直前が奇数個の backslash なら、その `"` は escape されていて文字列は続く。
        tmp="$seg"; bs=0
        while [ "${tmp%\\}" != "$tmp" ]; do bs=$((bs + 1)); tmp="${tmp%\\}"; done
        acc="${acc}${seg}"
        if [ $((bs % 2)) -eq 1 ]; then acc="${acc}\""; continue; fi
        instr=0
        if [ "$expect" -eq 1 ]; then printf '%s' "$acc"; return 0; fi
        last="$acc"; acc=""
        continue
      fi
      case "$rest" in
        *'"'*) seg="${rest%%'"'*}"; rest="${rest#*'"'}"; instr=1; acc="" ;;
        *) seg="$rest"; rest="" ;;
      esac
      # 深さは文字列の外に出た構造文字だけで数える（値の中の括弧に釣られない）。
      tmp="$seg"
      while [ "${tmp#*'{'}" != "$tmp" ]; do depth=$((depth + 1)); tmp="${tmp#*'{'}"; done
      tmp="$seg"
      while [ "${tmp#*'['}" != "$tmp" ]; do depth=$((depth + 1)); tmp="${tmp#*'['}"; done
      tmp="$seg"
      while [ "${tmp#*'}'}" != "$tmp" ]; do depth=$((depth - 1)); tmp="${tmp#*'}'}"; done
      tmp="$seg"
      while [ "${tmp#*']'}" != "$tmp" ]; do depth=$((depth - 1)); tmp="${tmp#*']'}"; done
      case "$seg" in
        *:*) if [ "$depth" -eq 1 ] && [ -n "$last" ] && [ "$last" = "$key" ]; then expect=1; fi ;;
      esac
      # 値が object / array なら、次に閉じる文字列はその中身であって値ではない。
      case "$seg" in
        *'{'*|*'['*|*,*) expect=0 ;;
      esac
      last=""
    done
  done < "$file"
  return 1
}
ff_assert_script_plugin_root() {
  local self="${1:-}" dir="" root="" var="" value="" canonical="" used="" skipped="" other="" version="" quiet=0
  [ -n "$self" ] || { echo "❌ 起動したスクリプトの実体位置を取得できません" >&2; return 1; }
  case "$self" in */*) dir="${self%/*}" ;; *) dir="." ;; esac
  dir="$(CDPATH= cd -P -- "$dir" 2>/dev/null && pwd -P)" || dir=""
  [ -n "$dir" ] || { echo "❌ 起動したスクリプトのdirectoryを解決できません: ${self}" >&2; return 1; }
  root="$(CDPATH= cd -P -- "${dir}/.." 2>/dev/null && pwd -P)" || root=""
  [ -n "$root" ] || { echo "❌ 自分のplugin rootを解決できません: ${dir}" >&2; return 1; }
  self="${dir}/${self##*/}"
  # スクリプト自身がsymlinkなら止める。親directoryしかcanonical化しないと、期待root内の
  # symlinkから別checkoutの実体を実行でき、「実体位置とhandoffの照合」の前提が崩れる。
  if [ -L "$self" ]; then
    {
      echo "❌ ff-dev-toolkit更新後にこのskillを再呼び出してください（起動したスクリプトがsymlinkです）"
      echo "   起動したスクリプト: ${self}"
      echo "   symlinkは期待rootの内側から別領域の実体を指せるため、実体位置の照合が成立しません。"
      echo "   別のインストール領域へ切り替えて実行しないこと — version混在と未リリースWIPの実行になります。"
      echo "   cacheや別checkoutを探さず、実体のパスで起動してください。"
    } >&2
    return 1
  fi
  for var in FF_DEV_TOOLKIT_ROOT CLAUDE_PLUGIN_ROOT GROK_PLUGIN_ROOT; do
    eval "value=\${${var}:-}"
    [ -n "$value" ] || continue
    canonical="$(CDPATH= cd -P -- "$value" 2>/dev/null && pwd -P)" || canonical=""
    # 正規形は plugin root だが、scripts/ を直接指す綴りも正規に受理されている
    # （templates/codex-review.sh の canonical_toolkit_root が両方を受ける）。同じ実体を
    # 指している限り一致として扱う。
    if [ -n "$canonical" ] && { [ "$canonical" = "$root" ] || [ "$canonical" = "$dir" ]; }; then
      [ -n "$used" ] || used="$var"
      continue
    fi
    # 実在する別 plugin の root は我々への handoff ではない（別 plugin 経由の正規呼び出し
    # まで殺さない）。ただし除外できるのは「manifestが通常ファイルとして読めて、名前が別だと
    # 確認できた」ときだけにする。消えているroot も、読めないmanifest も、誰のものか判定
    # できない点は同じ。
    other=""
    if [ -n "$canonical" ]; then
      other="$(ff_script_root_guard_manifest_field "${canonical}/.claude-plugin/plugin.json" name)" || other=""
    fi
    if [ -n "$other" ] && [ "$other" != "ff-dev-toolkit" ]; then
      skipped="${skipped:+${skipped} }${var}=別plugin(${other})"
      continue
    fi
    {
      echo "❌ ff-dev-toolkit更新後にこのskillを再呼び出してください（plugin rootが固定値と一致しません）"
      echo "   起動したスクリプト: ${self}"
      echo "   このスクリプトのplugin root: ${root}"
      echo "   hostが渡したroot（${var}）: ${value}"
      if [ -z "$canonical" ]; then
        echo "   不一致の内容: 指しているdirectoryが実在しません（plugin rootが消えています）"
      elif [ -z "$other" ]; then
        echo "   不一致の内容: 指す先のplugin manifestを読めず、誰のrootか判定できません（判定不能は停止に倒します）"
      else
        echo "   不一致の内容: このスクリプトは別のインストール領域の実体です"
      fi
      echo "   別のインストール領域へ切り替えて実行しないこと — version混在と未リリースWIPの実行になります。"
      echo "   cacheや別checkoutを探さず、pluginを再導入してからskillを呼び直してください。"
    } >&2
    return 1
  done
  # provenance（実体 path と version の 1 行）は「想定外の場所から起動された」ことを
  # agent にもログを読む人にも見せて診断コストを下げる。照合を飛ばした handoff も理由付きで
  # 出す — 渡っていた事実を「なし・直接起動」と報告すると、診断価値を損ない事実とも食い違う。
  # 出力そのものが契約になっている script（成功時は無出力・stderr を混ぜない等）では情報行が
  # 契約違反になるので、その basename だけを**この block 内の allowlist**で抑止する。
  # 外から env で抑止できる形にすると allowlist が実効的な制約にならないので、環境変数では
  # 抑止できない。抑止できるのは provenance だけで、停止の判定と案内は抑止できない。
  case "${self##*/}" in
    check-merge-freshness.sh|check-plugin-versions.sh) quiet=1 ;;
  esac
  if [ "$quiet" -ne 1 ]; then
    version="$(ff_script_root_guard_manifest_field "${root}/.claude-plugin/plugin.json" version)" || version=""
    echo "ℹ️  ff-dev-toolkit ${version:-version不明} — 実行実体: ${self}（handoff: ${used:-なし・直接起動}${skipped:+ / 照合対象外: ${skipped}}）" >&2
  fi
  return 0
}
ff_assert_script_plugin_root "${BASH_SOURCE[0]}" || exit 1
# ff-dev-toolkit-script-root-guard:end
# 中断コードが契約既定の 2 ではなく 1 なのは、本スクリプトの 2 が「確認不可が残った」
# という判定結果だから。ガードの停止は判定ではなく中断なので 1 を使う。

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
