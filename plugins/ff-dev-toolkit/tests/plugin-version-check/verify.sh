#!/usr/bin/env bash
# 実ユーザー登録・ネットワークを使わない3層検査。macOS /bin/bash 3.2 でも同じ入口を実行。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SUT="$PLUGIN_ROOT/scripts/check-plugin-versions.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/plugin-version-test.XXXXXX")"
FF_REACHED_END=0
cleanup() {
  local rc=$?
  rm -rf "$WORK"
  if [ "$FF_REACHED_END" != 1 ] && [ "$rc" = 0 ]; then exit 1; fi
  exit "$rc"
}
trap cleanup EXIT
PASS=0
check() {
  if jq -e "$2" "$WORK/report.json" >/dev/null; then
    PASS=$((PASS + 1)); printf '✓ %s\n' "$1"
  else printf '✗ %s\n' "$1" >&2; cat "$WORK/report.json" >&2; exit 1; fi
}
mkdir -p "$WORK/bin" "$WORK/config/plugins" "$WORK/sessions"
cp "$SCRIPT_DIR/gh" "$WORK/bin/gh"
chmod +x "$WORK/bin/gh"
export FF_VERSION_FIXTURE="$WORK"
export PATH="$WORK/bin:$PATH"
SHA_OLD=1111111111111111111111111111111111111111
SHA_LAST=2222222222222222222222222222222222222222
SHA_NEW=3333333333333333333333333333333333333333
jq -n '{catalog:{source:{source:"github",repo:"example/catalog"}}, private:{source:{source:"git",url:"https://github.com/example/private.git"}}}' > "$WORK/config/plugins/known_marketplaces.json"
jq -n --arg old "$SHA_OLD" --arg newer "$SHA_NEW" --arg same "$SHA_LAST" '{version:2,plugins:{
  "old@catalog":[{scope:"user",version:"0.9.9"},{scope:"project",projectPath:"/example",version:"0.10.0"}],
  "ahead@catalog":[{scope:"user",version:"2.0.0"}],
  "pre@catalog":[{scope:"user",version:"1.0.0-rc.9"}],
  "behind@catalog":[{scope:"user",version:"unknown",gitCommitSha:$old}],
  "newer@catalog":[{scope:"user",version:"unknown",gitCommitSha:$newer}],
  "same@catalog":[{scope:"user",version:"unknown",gitCommitSha:$same}],
  "missing@catalog":[{scope:"user",version:"unknown"}],
  "denied@private":[{scope:"user",version:"1.0.0"}],
  "remote@catalog":[{scope:"user",version:"1.0.0"}],
  "bad@catalog":[{scope:"user",version:"garbage"}],
  "npm@catalog":[{scope:"user",version:"1.0.0"}]
}}' > "$WORK/config/plugins/installed_plugins.json"
jq -n --arg old "$SHA_OLD" --arg newer "$SHA_NEW" --arg last "$SHA_LAST" '{
  "repos/example/catalog/contents/.claude-plugin/marketplace.json":{plugins:(
    (["old","ahead","pre","behind","newer","same","missing","bad","desktop-only"]|map({name:.,source:("./plugins/"+.)}))
    + [{name:"remote",source:{source:"git-subdir",url:"git@github.com:example/external.git",path:"tools/plugin",ref:"stable"}},
       {name:"npm",source:{source:"npm",package:"example"}}])},
  "repos/example/catalog/contents/plugins/old/.claude-plugin/plugin.json":{name:"old",version:"0.10.0"},
  "repos/example/catalog/contents/plugins/ahead/.claude-plugin/plugin.json":{name:"ahead",version:"1.0.0"},
  "repos/example/catalog/contents/plugins/pre/.claude-plugin/plugin.json":{name:"pre",version:"1.0.0-rc.10"},
  "repos/example/catalog/contents/plugins/bad/.claude-plugin/plugin.json":{name:"bad",version:"1.0.0"},
  "repos/example/catalog/contents/plugins/desktop-only/.claude-plugin/plugin.json":{name:"desktop-only",version:"2.0.0"},
  "repos/example/catalog/contents/plugins/behind/.claude-plugin/plugin.json":{name:"behind"},
  "repos/example/catalog/contents/plugins/newer/.claude-plugin/plugin.json":{name:"newer"},
  "repos/example/catalog/contents/plugins/same/.claude-plugin/plugin.json":{name:"same"},
  "repos/example/catalog/contents/plugins/missing/.claude-plugin/plugin.json":{name:"missing"},
  "repos/example/external/contents/tools/plugin/.claude-plugin/plugin.json|ref=stable":{name:"remote",version:"1.1.0"},
  "repos/example/catalog/commits?per_page=1&path=plugins%2Fbehind":[{sha:$last}],
  "repos/example/catalog/commits?per_page=1&path=plugins%2Fnewer":[{sha:$last}],
  "repos/example/catalog/commits?per_page=1&path=plugins%2Fsame":[{sha:$last}],
  ("repos/example/catalog/compare/"+$last+"..."+$old):{status:"behind",behind_by:4},
  ("repos/example/catalog/compare/"+$last+"..."+$newer):{status:"ahead",behind_by:0},
  ("repos/example/catalog/compare/"+$last+"..."+$last):{status:"identical",behind_by:0}
}' > "$WORK/responses.json"
for session in 'session A' 'session B'; do
  rpm="$WORK/sessions/$session/sub/rpm"
  mkdir -p "$rpm/plugin_old/.claude-plugin" "$rpm/plugin_server/.claude-plugin"
  jq -n '{plugins:[{id:"plugin_old",name:"old",marketplaceName:"catalog",updatedAt:"2099-01-01"},
    {id:"plugin_server",name:"desktop-only",marketplaceName:"catalog"}]}' > "$rpm/manifest.json"
  jq -n '{name:"old",version:"0.1.0"}' > "$rpm/plugin_old/.claude-plugin/plugin.json"
  jq -n '{name:"desktop-only",version:"1.0.0"}' > "$rpm/plugin_server/.claude-plugin/plugin.json"
done
snapshot() {
  find "$WORK/config" "$WORK/sessions" -type f -exec cksum {} \; | sort
}
snapshot > "$WORK/before"
run() {
  local target="${1:-$SUT}" interpreter="${2:-bash}"
  RC=0
  "$interpreter" "$target" --config-dir "$WORK/config" --sessions-dir "$WORK/sessions" --json > "$WORK/report.json" 2> "$WORK/stderr" || RC=$?
  [ ! -s "$WORK/stderr" ] || { cat "$WORK/stderr" >&2; exit 1; }
}
run
[ "$RC" = 2 ] || { echo "partial result must exit 2: $RC" >&2; exit 1; }
check '複数 scope と session を全部集計' '.summary.total == 16 and .summary.total == (.results|length) and ([.summary.outdated,.summary.current,.summary.ahead,.summary.unknown]|add)==.summary.total'
check 'SemVer 0.9.9 -> 0.10.0' 'any(.results[]; .plugin=="old" and .scope=="user" and .status=="outdated" and .latestVersion=="0.10.0" and .installedVersion=="0.9.9")'
check 'scope 別の同版' 'any(.results[]; .plugin=="old" and .scope=="project" and .status=="current")'
check 'ローカル先行は更新扱いしない' 'any(.results[]; .plugin=="ahead" and .status=="ahead")'
check 'SemVer prerelease 数値比較' 'any(.results[]; .plugin=="pre" and .status=="outdated")'
check 'behind_by > 0' 'any(.results[]; .plugin=="behind" and .status=="outdated" and .behindBy==4)'
check '異なる SHA でも installed が後なら最新' 'any(.results[]; .plugin=="newer" and .status=="current" and .behindBy==0 and .installedSha!=.latestSha)'
check '同一 SHA は最新' 'any(.results[]; .plugin=="same" and .status=="current")'
check 'GitHub source の ref と subdir を保持' 'any(.results[]; .plugin=="remote" and .status=="outdated" and .source.ref=="stable" and .source.path=="tools/plugin")'
check '権限不足・SHA 不足・不正版・非対応 source は確認不可' '[.results[]|select(.status=="unknown")|.plugin]|sort == ["bad","denied","missing","npm"]'
check 'Desktop 2 session を別々に報告' '[.results[]|select(.layer=="desktop" and .plugin=="old")|.session]|unique|length==2'
check 'ローカル未登録の Desktop plugin も報告' '[.results[]|select(.layer=="desktop" and .plugin=="desktop-only" and .status=="outdated")]|length==2'
check 'Desktop 再登録・新セッションの案内' 'all(.results[]|select(.layer=="desktop" and .status=="outdated"); .action|contains("ローカル更新では解消できません") and contains("再登録") and contains("新しいセッション"))'
grep -F "compare/$SHA_LAST...$SHA_NEW" "$WORK/calls" >/dev/null || exit 1
PASS=$((PASS + 1)); echo '✓ 最新対照が compare API へ到達（ACE-924-2）'
snapshot > "$WORK/after"
cmp "$WORK/before" "$WORK/after"
PASS=$((PASS + 1)); echo '✓ 入力ファイルを変更していない'
[ "$(grep -Fc 'repos/example/catalog/contents/.claude-plugin/marketplace.json' "$WORK/calls")" = 1 ] || exit 1
PASS=$((PASS + 1)); echo '✓ 実行内の API キャッシュ'

# sync 後は plugin が repository root に来る。社内ファイルを持たない構成で実行する。
mkdir -p "$WORK/public/scripts/lib"
cp "$SUT" "$WORK/public/scripts/"
cp "$PLUGIN_ROOT/scripts/lib/plugin-versions.jq" "$WORK/public/scripts/lib/"
cp "$WORK/report.json" "$WORK/expected.json"
run "$WORK/public/scripts/check-plugin-versions.sh" /bin/bash
[ "$RC" = 2 ] && cmp "$WORK/expected.json" "$WORK/report.json" || exit 1
PASS=$((PASS + 1)); echo '✓ 公開 root layout と /bin/bash で同じ結果'

# Windows の Git Bash（MSYS）は native の jq.exe へ渡す引数のうち "/" を Windows パスへ書き換える
# （jq -rn '"/"' が C:/Program Files/Git/ を出す）。その書き換えを再現するシムを PATH 先頭へ置き、
# jq プログラムの引数へ "/" を書いた退行を Linux / macOS でも赤にする（Issue `#2019`）。
# シムが再現するのは "/" のリテラルと単独の / の引数だけで、MSYS の規則全体は模倣しない。
# "/x" のような形まで書き換えると、fixture の projectPath:"/example" を含む --argjson まで変わって
# 誤って赤になる（実物の MSYS はこの JSON を書き換えない）。
# 実物の jq はシムの作成時に解決する（実行時に PATH から引くとシム自身を呼んで再帰する）。
mkdir -p "$WORK/msys-bin"
{
  printf '#!/usr/bin/env bash\nREAL_JQ=%q\nMSYS_CALLS=%q\n' "$(command -v jq)" "$WORK/msys-calls"
  cat <<'SHIM'
printf 'call\n' >> "$MSYS_CALLS"
q='"/"'; r='"C:/Program Files/Git/"'
args=()
for a in "$@"; do
  [ "$a" = / ] && a='C:/Program Files/Git/'
  args+=("${a//"$q"/$r}")
done
exec "$REAL_JQ" "${args[@]}"
SHIM
} > "$WORK/msys-bin/jq"
chmod +x "$WORK/msys-bin/jq"
# シムが書き換えていなければ、この検査は何も測っていない（リテラルと単独の / の両方を確かめる）
[ "$("$WORK/msys-bin/jq" -rn '"/"')" = 'C:/Program Files/Git/' ] || { echo 'msys jq shim does not rewrite "/"' >&2; exit 1; }
[ "$("$WORK/msys-bin/jq" -rn --arg s / '$s')" = 'C:/Program Files/Git/' ] || { echo 'msys jq shim does not rewrite a lone /' >&2; exit 1; }
: > "$WORK/msys-calls"
SAVED_PATH="$PATH"
PATH="$WORK/msys-bin:$PATH"
run
PATH="$SAVED_PATH"
# SUT が PATH を固定したり jq を絶対パスで呼んだりすると、シムを通らないまま緑になる。通った証拠を残す
[ -s "$WORK/msys-calls" ] || { echo 'SUT が MSYS シムの jq を一度も呼んでいない（検査が空振りしている）' >&2; exit 1; }
[ "$RC" = 2 ] && cmp "$WORK/expected.json" "$WORK/report.json" || { echo 'MSYS の引数変換の下で結果が変わった' >&2; exit 1; }
PASS=$((PASS + 1)); echo '✓ MSYS の引数変換（"/" の書き換え）の下でも同じ結果'

# Desktop セッションの既定の置き場（--sessions-dir なし）。OS の分岐は bash 組み込みの OSTYPE で決まり、
# 環境変数では偽装できない（bash が起動時に設定し直す）。BASH_ENV のファイルは OSTYPE の初期化の後に
# 読まれるので、そこで代入して Windows / macOS / Linux の分岐をどのホストでも通す（Issue `#2034`）。
for os in msys linux-gnu darwin23; do printf 'OSTYPE=%s\n' "$os" > "$WORK/benv-$os"; done
# 継ぎ目が効いていなければ、以下の検査は何も測っていない
[ "$(BASH_ENV="$WORK/benv-msys" bash -c 'printf %s "$OSTYPE"')" = msys ] || { echo 'BASH_ENV で OSTYPE を差し替えられない' >&2; exit 1; }
desktop_rows() { jq -c '[.results[]|select(.layer=="desktop")|{plugin,session,status}]|sort' "$1"; }
desktop_rows "$WORK/expected.json" > "$WORK/desktop-expected"
[ "$(jq length "$WORK/desktop-expected")" = 4 ] || { echo 'Desktop の基準行が 4 件ではない' >&2; exit 1; }
run_default() { # os appdata localappdata home
  RC=0
  env BASH_ENV="$WORK/benv-$1" APPDATA="$2" LOCALAPPDATA="$3" HOME="$4" \
    bash "$SUT" --config-dir "$WORK/config" --json > "$WORK/report.json" 2> "$WORK/stderr" || RC=$?
  [ ! -s "$WORK/stderr" ] || { cat "$WORK/stderr" >&2; exit 1; }
  [ "$RC" = 2 ] || { echo "既定の置き場の検査が exit 2 で終わらない: $RC" >&2; exit 1; }
}
same_desktop() { # 検査結果があるのに「保存先なし」を注記する退行（実在しない候補を除かない）も赤にする
  if [ "$(desktop_rows "$WORK/report.json")" = "$(cat "$WORK/desktop-expected")" ] \
    && jq -e '[.notes[]|select(contains("保存先なし"))]|length==0' "$WORK/report.json" >/dev/null; then
    PASS=$((PASS + 1)); printf '✓ %s\n' "$1"
  else printf '✗ %s\n' "$1" >&2; desktop_rows "$WORK/report.json" >&2; exit 1; fi
}
sessions_copy() { mkdir -p "$1"; cp -R "$WORK/sessions/." "$1/"; }
W="$WORK/win"
# Windows の通常版: %APPDATA%\Claude だけにある
sessions_copy "$W/c1/Roaming/Claude/local-agent-mode-sessions"
mkdir -p "$W/c1/Local"
run_default msys "$W/c1/Roaming" "$W/c1/Local" "$W/nohome"
same_desktop 'Windows: %APPDATA% の置き場を既定で検査'
# MSIX 版をアプリの外から見た形: LocalCache の下だけにある
mkdir -p "$W/c2/Roaming"
sessions_copy "$W/c2/Local/Packages/Claude_test/LocalCache/Roaming/Claude/local-agent-mode-sessions"
run_default msys "$W/c2/Roaming" "$W/c2/Local" "$W/nohome"
same_desktop 'Windows: MSIX 版の LocalCache の置き場を既定で検査'
# MSIX 版をアプリの中から見た形: 2 つの候補が同じディレクトリの別名（綴りも違う）
sessions_copy "$W/c3/Local/Packages/Claude_test/LocalCache/Roaming/Claude/local-agent-mode-sessions"
run_default msys "$W/c3/Local/Packages/Claude_test/LocalCache/./Roaming" "$W/c3/Local" "$W/nohome"
same_desktop 'Windows: 同じ実体の 2 つの候補は 1 回だけ数える'
# 別々の実体がどちらも在る（インストール形態を切り替えた後など）: 両方を検査する
mkdir -p "$W/c4/Roaming/Claude/local-agent-mode-sessions" "$W/c4/Local/Packages/Claude_test/LocalCache/Roaming/Claude/local-agent-mode-sessions"
cp -R "$WORK/sessions/session A" "$W/c4/Roaming/Claude/local-agent-mode-sessions/"
cp -R "$WORK/sessions/session B" "$W/c4/Local/Packages/Claude_test/LocalCache/Roaming/Claude/local-agent-mode-sessions/"
run_default msys "$W/c4/Roaming" "$W/c4/Local" "$W/nohome"
same_desktop 'Windows: 別々の実体はどちらも検査する'
# 置き場そのものが symlink（Windows ではジャンクション）でも中を検査する。find の既定は起点の symlink を
# 辿らないので、-H が無いと注記も出さずに 0 件で終わる。Git Bash の ln -s は既定でコピーを作るので mklink /J を使う
c5_real="$W/c5/Local/Packages/Claude_test/LocalCache/Roaming/Claude/local-agent-mode-sessions"
c5_link="$W/c5/Roaming/Claude/local-agent-mode-sessions"
sessions_copy "$c5_real"
mkdir -p "$W/c5/Roaming/Claude"
case "${OSTYPE:-}" in
  msys* | cygwin*)
    # MSYS は native の exe へ渡す /J を Windows のパスへ書き換えるので、変換を止めて渡す
    MSYS_NO_PATHCONV=1 cmd /c mklink /J "$(cygpath -w "$c5_link")" "$(cygpath -w "$c5_real")" >/dev/null 2>&1 \
      || { echo 'mklink /J でジャンクションを作れない（この検査は何も測っていない）' >&2; exit 1; } ;;
  *) ln -s "$c5_real" "$c5_link" ;;
esac
[ -L "$c5_link" ] || { echo '置き場の symlink（ジャンクション）を作れない（この検査は何も測っていない）' >&2; exit 1; }
run_default msys "$W/c5/Roaming" "$W/c5/Local" "$W/nohome"
same_desktop 'Windows: 置き場が symlink（ジャンクション）でも中を検査する'
# どの候補も無い（APPDATA / LOCALAPPDATA が空の環境を含む）: 従来どおり「対象なし」を注記する
run_default msys "" "" "$W/nohome"
check 'Windows: 置き場が無ければ Desktop 対象なしを注記' '([.results[]|select(.layer=="desktop")]|length)==0 and any(.notes[]; contains("保存先なし"))'
# macOS は ~/Library の置き場だけを見る。APPDATA に置き場があっても使わない
# （APPDATA には session A だけの置き場を渡す。macOS が APPDATA を読む退行は 2 行か 6 行になって赤）
sessions_copy "$W/machome/Library/Application Support/Claude/local-agent-mode-sessions"
run_default darwin23 "$W/c4/Roaming" "$W/c1/Local" "$W/machome"
same_desktop 'macOS: ~/Library の置き場だけを既定で検査'
# Linux は従来どおり（Windows の候補を見ない）
run_default linux-gnu "$W/c1/Roaming" "$W/c1/Local" "$W/nohome"
check 'Linux: Windows の置き場を見ず、Desktop 対象なしを注記' '([.results[]|select(.layer=="desktop")]|length)==0 and any(.notes[]; contains("保存先なし"))'

# 不正 compare が「最新」に化けない。成功していた対象と同居させる。
jq --arg key "repos/example/catalog/compare/$SHA_LAST...$SHA_NEW" '.[$key]={status:"ahead"}' "$WORK/responses.json" > "$WORK/next"
mv "$WORK/next" "$WORK/responses.json"
run
check 'compare 必須フィールド欠落は確認不可' 'any(.results[]; .plugin=="newer" and .status=="unknown") and any(.results[]; .plugin=="behind" and .status=="outdated")'

# JSON としては正常でも commits の要素型が壊れている場合、他の結果を失わない。
jq '."repos/example/catalog/commits?per_page=1&path=plugins%2Fbehind"=[42]' "$WORK/responses.json" > "$WORK/next"
mv "$WORK/next" "$WORK/responses.json"
run
[ "$RC" = 2 ] || exit 1
check '不正な commit 要素は確認不可、成功分と集計は残る' 'any(.results[]; .plugin=="behind" and .status=="unknown") and any(.results[]; .plugin=="old" and .status=="outdated") and .summary.total==16'

# 全 registry 破損でも Desktop は消さない。
printf 'invalid\n' > "$WORK/config/plugins/installed_plugins.json"
run
check 'registry 破損でも Desktop を検査' 'any(.results[]; .plugin=="(registry)" and .status=="unknown") and ([.results[]|select(.layer=="desktop")]|length)==4'

# 別 repository の root plugin・private の成功、directory marketplace source。
mkdir -p "$WORK/checkout"
git -C "$WORK/checkout" init -q
git -C "$WORK/checkout" remote add origin https://github.com/example/catalog.git
jq --arg path "$WORK/checkout" '.catalog.source={source:"directory",path:$path}' "$WORK/config/plugins/known_marketplaces.json" > "$WORK/next"
mv "$WORK/next" "$WORK/config/plugins/known_marketplaces.json"
jq -n '{plugins:{"root@catalog":[{version:"1.0.0"}],"denied@private":[{version:"1.0.0"}]}}' > "$WORK/config/plugins/installed_plugins.json"
jq '."repos/example/catalog/contents/.claude-plugin/marketplace.json".plugins += [{name:"root",source:{source:"github",repo:"example/root"}}]
  | ."repos/example/root/contents/.claude-plugin/plugin.json"={name:"root",version:"1.1.0"}
  | ."repos/example/private/contents/.claude-plugin/marketplace.json"={plugins:[{name:"denied",source:"./"}]}
  | ."repos/example/private/contents/.claude-plugin/plugin.json"={name:"denied",version:"1.1.0"}' "$WORK/responses.json" > "$WORK/next"
mv "$WORK/next" "$WORK/responses.json"
run
[ "$RC" = 0 ] || exit 1
check 'directory source の origin と external root plugin' 'any(.results[]; .plugin=="root" and .status=="outdated" and .source.repo=="example/root" and .source.path=="")'
check '認証済み private source も比較可能' 'any(.results[]; .plugin=="denied" and .status=="outdated")'

# server-only marketplace が未知のとき、別 marketplace の同名から推測しない。
rpm="$WORK/sessions/session A/sub/rpm"
jq '.plugins[0].marketplaceName="server-only"' "$rpm/manifest.json" > "$WORK/next"
mv "$WORK/next" "$rpm/manifest.json"
run
check '未知の marketplace は同名一致へ逃がさない' 'any(.results[]; .layer=="desktop" and .plugin=="old" and .session=="session A/sub" and .status=="unknown")'

# 名前だけが一致する複数 catalog は曖昧。manifest 欠損も実体の検査を続ける。
jq '."repos/example/private/contents/.claude-plugin/marketplace.json".plugins += [{name:"old",source:"./old"}]' "$WORK/responses.json" > "$WORK/next"
mv "$WORK/next" "$WORK/responses.json"
jq 'del(.plugins[0].marketplaceName)' "$rpm/manifest.json" > "$WORK/next"
mv "$WORK/next" "$rpm/manifest.json"
run
check '同名が複数 marketplace にあると確認不可' 'any(.results[]; .layer=="desktop" and .plugin=="old" and .session=="session A/sub" and .status=="unknown")'
cp "$WORK/responses.json" "$WORK/complete-responses.json"
jq 'del(."repos/example/private/contents/.claude-plugin/marketplace.json")' "$WORK/responses.json" > "$WORK/next"
mv "$WORK/next" "$WORK/responses.json"
run
check '取得不能な catalog があると名前だけで一意性を推測しない' 'any(.results[]; .layer=="desktop" and .plugin=="old" and .session=="session A/sub" and .status=="unknown") and any(.results[]; .plugin=="root" and .status=="outdated")'
mv "$WORK/complete-responses.json" "$WORK/responses.json"
printf 'invalid\n' > "$rpm/manifest.json"
run
check '不正 manifest でも実体は列挙する' 'any(.results[]; .plugin=="(manifest)" and .status=="unknown") and any(.results[]; .plugin=="desktop-only" and .session=="session A/sub" and .status=="outdated")'

# 各種 JSON 破損と plugin fetch 失敗を、健全な local root と同居させる。
jq '.malformed="not-an-object"' "$WORK/config/plugins/known_marketplaces.json" > "$WORK/next"
mv "$WORK/next" "$WORK/config/plugins/known_marketplaces.json"
jq '."repos/example/catalog/contents/.claude-plugin/marketplace.json".plugins += [42,{name:"nonsense",source:{source:"git",url:"https://evil.example/exfil"}}]
  | del(."repos/example/private/contents/.claude-plugin/plugin.json")' "$WORK/responses.json" > "$WORK/next"
mv "$WORK/next" "$WORK/responses.json"
run
check '不正 source/entry と API 失敗を分離して成功分を残す' 'any(.results[]; .plugin=="denied" and .status=="unknown") and any(.results[]; .plugin=="root" and .status=="outdated")'

# 通常テキストと機械出力は同じ集計。不正引数は起動失敗。
RC=0
bash "$SUT" --config-dir "$WORK/config" --sessions-dir "$WORK/sessions" > "$WORK/text" || RC=$?
[ "$RC" = 2 ] && grep '集計:' "$WORK/text" >/dev/null && grep '確認不可' "$WORK/text" >/dev/null || exit 1
PASS=$((PASS + 1)); echo '✓ 人向け出力にも部分結果と集計'
jq '.plugins["root@catalog"] += [{version:{broken:true},scope:{broken:true}}]' "$WORK/config/plugins/installed_plugins.json" > "$WORK/next"
mv "$WORK/next" "$WORK/config/plugins/installed_plugins.json"
run
[ "$RC" = 2 ] || exit 1
check '非 scalar の version は確認不可、同名の正常登録は継続' 'any(.results[]; .plugin=="root" and .status=="unknown") and any(.results[]; .plugin=="root" and .status=="outdated")'
RC=0
bash "$SUT" --config-dir "$WORK/config" --sessions-dir "$WORK/sessions" > "$WORK/text" || RC=$?
[ "$RC" = 2 ] && grep '集計:' "$WORK/text" >/dev/null && grep 'broken' "$WORK/text" >/dev/null || exit 1
PASS=$((PASS + 1)); echo '✓ 非 scalar の登録値でもテキスト出力が完了'
RC=0
bash "$SUT" --config-dir > "$WORK/text" 2>&1 || RC=$?
[ "$RC" = 1 ] || exit 1
PASS=$((PASS + 1)); echo '✓ 不正引数は exit 1'

# 登録も Desktop もない正当な空集合。検査対象なしを注記する。
printf '{"plugins":{}}\n' > "$WORK/config/plugins/installed_plugins.json"
RC=0
bash "$SUT" --config-dir "$WORK/config" --sessions-dir "$WORK/absent" --json > "$WORK/report.json" || RC=$?
[ "$RC" = 0 ] || exit 1
check '空の登録は件数0、Desktop 対象なしを注記' '.summary.total==0 and (.notes|length)==1'
RC=0
bash "$SUT" --config-dir "$WORK/config" --sessions-dir "$WORK/text" --json > "$WORK/report.json" || RC=$?
[ "$RC" = 2 ] || exit 1
check 'Desktop 保存先の形式不正は対象なしにしない' 'any(.results[]; .plugin=="(sessions)" and .status=="unknown")'

# 本体モジュールの SemVer 境界。build metadata / release / 長い数値 / 無効版。
jq -n -L "$PLUGIN_ROOT/scripts/lib" 'include "plugin-versions";
  [semver_compare("1.0.0+one";"1.0.0+two"),semver_compare("1.0.0-rc.1";"1.0.0"),
   semver_compare("10.0.0";"2.0.0"),semver_compare("1.0.0-alpha";"1.0.0-alpha.1"),
   semver_compare("1.0.0-01";"1.0.0"),semver_compare("1.0.0-12345678901234567890";"1.0.0-12345678901234567891")]
  == [0,-1,1,-1,null,-1]' | grep '^true$' >/dev/null
PASS=$((PASS + 1)); echo '✓ SemVer の境界値'
printf 'plugin-version-check: passed=%s failed=0\n' "$PASS"
FF_REACHED_END=1
