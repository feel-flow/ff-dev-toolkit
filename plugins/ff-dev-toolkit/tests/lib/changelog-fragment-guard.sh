#!/usr/bin/env bash
#
# 公開対象を変更したのに changelog.d/ 断片が無い状態を commit 前に名指しする（bundle `#1913` /
# OBS-099）。
#
# 公開対象（`scripts/sync-dev-toolkit-to-public.sh --list-targets` が返す prefix の配下）を
# 触った PR は、同梱 tests の fixture だけの修正でも断片を 1 つ足す（changelog.d/README.md）。
# 付け忘れは同期手順 R（scripts/check-release-required.sh）の `CHANGELOG_MISSING` で初めて
# 止まり、断片を後付けする準備 PR とリリース 1 周分が増える（OBS-099 Count 3）。
# `/pre-commit-check` 手順 8 がこの関数を呼び、commit 前に同じ欠落を赤にする。
#
# 公開関数:
#   changelog_fragment_scan [REPO]
#     REPO（既定: カレントディレクトリ）のリポジトリルートで次を判定する。
#       1. 公開対象の prefix は `<root>/scripts/sync-dev-toolkit-to-public.sh --list-targets`
#          から取る（手書きの一覧を持たない。check-release-required.sh / check-added-bare-refs.sh
#          と同じ真実源）
#       2. staged（ACDMRT。公開ファイルの削除も公開面の変更）のうち公開対象の配下にあるパスを
#          数える。次は数えない（同期手順 R が断片を要求しないもの）:
#            - check-release-required.sh の `META_ALLOWLIST`（告知不要のメタ変更。配列を
#              同スクリプトから読み、ここへ複製しない。読めなければ空として扱う = 厳しい側）
#            - 公開 CHANGELOG（release-dev-toolkit.sh の `CHANGELOG=`）。共有 CHANGELOG は
#              リリース準備と footer 追従だけが書く（通常 PR は断片へ書く）
#          数えるパスが 0 件なら対象なし
#       3. 断片として数えるのは、比較 base から index までの差分で**追加（A）**された
#          `changelog.d/<名>.md`（`changelog.d/README.md` と下位ディレクトリは数えない）。
#          比較 base は merge-base(origin/HEAD の指す既定ブランチ, HEAD)。同じ PR の前の
#          commit で足した断片も数える（2 コミット目以降のレビュー対応 commit を赤にしない）。
#          既定ブランチの先端に在る断片（他 PR の未消費断片。origin/HEAD が古い・別ブランチを
#          指していて merge-base が PR の分岐点より古くなった回も含む）は数えない
#       4. 比較 base を解決できない（origin/HEAD が無い・HEAD が無い・merge-base が取れない）
#          回は staged の追加だけを見る。そこにも断片が無ければ「違反」とは言い切れないので
#          判定不能（rc=2）へ倒す
#       5. リリース準備の定型コミット（断片の消費）: staged に断片の削除（D）があり、公開
#          CHANGELOG が staged で、残りの公開パスが release-dev-toolkit.sh の準備対象
#          （`PLUGIN_JSON=` / `AGENT_CONFIG=`）だけなら、断片を集約した回として対象外
#          （`changelog-fragment: consumed <N>`）にする。準備対象を読めなければこの扱いをしない
#       6. 3. で数えた断片の帰属照合（Issue `#2127` / OBS-221）: 断片の staged 内容（index）が
#          backtick で参照する path を公開側最新タグと照合し、同一内容（今回変えていない path）なら
#          違反にする。判定本体は plugins/ff-dev-toolkit/scripts/lib/changelog-attribution-functions.sh
#          の changelog_attribution_scan（リリース時の ATTRIBUTION_DRIFT と同じ 1 箇所）を
#          dirty_exempt=2 で呼ぶ — staged で変えた path と、HEAD の object が公開タグと違う path
#          （同じ PR の前の commit や、未リリースの他 PR で変えたもの）は変更済みとして扱う。作業ツリー
#          だけの編集は commit に入らないので変更済みとしない。最新タグは公開リポジトリ
#          （FF_RELEASE_CHECK_PUBLIC_URL、既定 https://github.com/feel-flow/ff-dev-toolkit.git）の
#          ls-remote で決め、公開側 clone（FF_RELEASE_CHECK_PUBLIC、既定 ~/GitHub/FEEL-FLOW/ff-dev-toolkit）
#          がそのタグを持てば clone で、無ければそのタグだけを一時 bare repo へ depth 1 で取って照合する。
#          公開リポジトリへ届かない回だけ clone の最新タグで照合する。どちらも引けない・helper を
#          読めない回は判定不能（rc=2）へ倒す。断片に path 形の参照が無ければ取得しない
#       7. 同branchの断片がHEADにあり、その確定集合を1件もstageしていない後続公開変更には
#          stderrへ読み直しWARNと全断片のindex本文を出す。正常stdout/rc0を変えず、取得失敗はrc2
#
# 出力と終了コード:
#   rc=0  stdout `changelog-fragment: ok <N>`        公開対象の変更に対し断片 N 件（1 以上）。帰属照合も通過
#                                                    （照合した相手、または照合不要の旨は stderr の `帰属検査:` 行）
#                                                    後続の公開変更で断片をstageしなければstderrにWARN/全index本文
#   rc=0  stdout `changelog-fragment: none`          staged に数える公開対象の変更が無い（「違反なし」ではなく「対象なし」）
#   rc=0  stdout `changelog-fragment: consumed <N>`  断片を集約するリリース準備の回（N は削除した断片数）
#   rc=1  stdout `公開対象を変更したのに changelog.d/ 断片がありません: <先頭パス>（公開対象 <M> 件）`
#   rc=1  stdout `ATTRIBUTION_PATH=<token> -> <公開 path> (v<tag> と同一 object)` 行と
#         `✗ <断片>: 前版 v<tag> と同一内容の path を backtick で参照している（…）` 行（帰属違反）
#   rc=2  stderr `断片未検査: <理由>`   判定材料を取得できない。緑とも違反なしとも報告しない
#         （リポジトリではない・公開対象一覧を取得できない / 空・git が失敗した・
#         比較 base を解決できず staged にも断片が無い・一時領域を作れない・
#         帰属照合の helper を読めない・公開側最新タグを clone からも公開リポジトリからも引けない）

# _cfg_array_items <file> <配列名> — `名=(` から `)` までの "..." 要素を 1 行ずつ出す
_cfg_array_items() {
  [ -f "$1" ] || return 0
  awk -v name="$2" '
    $0 ~ "^" name "=\\(" { on = 1; next }
    on && /^\)/ { exit }
    on { if (match($0, /"[^"]*"/)) print substr($0, RSTART + 1, RLENGTH - 2) }
  ' "$1"
}

# _cfg_scalar <file> <変数名> — 行頭の `名="値"` の値を出す
_cfg_scalar() {
  [ -f "$1" ] || return 0
  awk -F'"' -v name="$2" '$0 ~ "^" name "=\"" { print $2; exit }' "$1"
}

# _changelog_fragment_attribution <root> <tmp> — <tmp>/frags（1 行 1 断片のルート相対パス）の
# staged 内容を公開側最新タグと照合する。rc=0 違反なし / 1 違反（stdout に名指し）/ 2 判定不能（stderr）
_changelog_fragment_attribution() {
  local root="$1" tmp="$2" lib clone public url refs remote_tag="" clone_tag="" tag="" src="" path out arc
  local paths reason suspects=0 has_paths=0 n=0
  # 公開リポジトリへの到達が詰まった回に黙って待ち続けない（低速が 30 秒続けば打ち切る）。
  local -a net=(-c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30)
  lib="$root/plugins/ff-dev-toolkit/scripts/lib/changelog-attribution-functions.sh"
  if [ ! -f "$lib" ] || ! . "$lib" || ! declare -F changelog_attribution_scan >/dev/null; then
    echo "断片未検査: 帰属照合の判定 helper を読めません: ${lib}" >&2
    return 2
  fi
  # 断片の本文は commit される index 側から読む（作業ツリーだけの書き換えで通さない）。
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    n=$((n + 1))
    if ! git -C "$root" show ":${path}" >"$tmp/body.${n}" 2>"$tmp/err"; then
      echo "断片未検査: 断片の staged 内容を読めません: ${path}: $(cat "$tmp/err" 2>/dev/null)" >&2
      return 2
    fi
    if ! paths="$(extract_paths "$(cat "$tmp/body.${n}")")"; then
      echo "断片未検査: 断片の path 形の参照を抽出できません: ${path}" >&2
      return 2
    fi
    [ -z "$paths" ] || has_paths=1
  done <"$tmp/frags"
  if [ "$has_paths" -eq 0 ]; then
    echo "帰属検査: 断片 ${n} 件に path 形の参照なし（公開タグを引かない）" >&2
    return 0
  fi
  # 最新タグは公開リポジトリの ls-remote で決める（手元 clone の最終 fetch が古いと、古いタグとの
  # 照合で誤帰属を見逃す）。clone がそのタグを持っていれば clone で照合し、無ければ一時 bare repo へ
  # そのタグだけを depth 1 で取る。公開リポジトリへ届かない回だけ clone の最新タグで照合する。
  clone="${FF_RELEASE_CHECK_PUBLIC:-${HOME:-}/GitHub/FEEL-FLOW/ff-dev-toolkit}"
  url="${FF_RELEASE_CHECK_PUBLIC_URL:-https://github.com/feel-flow/ff-dev-toolkit.git}"
  if git -C "$clone" rev-parse --git-dir >/dev/null 2>&1; then
    clone_tag="$(changelog_latest_semver_tag "$clone" 2>/dev/null)" || clone_tag=""
  fi
  if refs="$(GIT_TERMINAL_PROMPT=0 git "${net[@]}" ls-remote --tags --refs "$url" 2>"$tmp/err")"; then
    remote_tag="$(printf '%s\n' "$refs" | awk '$2 ~ /^refs\/tags\/v[0-9]+\.[0-9]+\.[0-9]+$/ { sub(/^refs\/tags\/v/, "", $2); print $2 }' \
      | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
    if [ -z "$remote_tag" ]; then
      echo "断片未検査: 帰属照合の公開タグを引けません（${url} に SemVer タグがありません）" >&2
      return 2
    fi
    tag="$remote_tag"
    if [ -n "$clone_tag" ] && git -C "$clone" rev-parse -q --verify "refs/tags/v${tag}^{commit}" >/dev/null 2>&1; then
      public="$clone"; src="公開側 clone ${clone}"
    else
      public="$tmp/public.git"
      if ! git init -q --bare "$public" 2>"$tmp/err"; then
        echo "断片未検査: 公開タグ取得用の一時 repo を作れません: $(cat "$tmp/err" 2>/dev/null)" >&2
        return 2
      fi
      if ! GIT_TERMINAL_PROMPT=0 git "${net[@]}" -C "$public" fetch -q --depth 1 --no-tags "$url" \
        "refs/tags/v${tag}:refs/tags/v${tag}" 2>"$tmp/err"; then
        echo "断片未検査: 帰属照合の公開タグ v${tag} を取得できません（${url}）: $(cat "$tmp/err" 2>/dev/null)" >&2
        return 2
      fi
      src="公開リポジトリ ${url}"
    fi
  elif [ -n "$clone_tag" ]; then
    tag="$clone_tag"; public="$clone"
    src="公開側 clone ${clone}（${url} へ届かないため clone の最新タグ。clone が古いと見逃しうる）"
  else
    if [ -d "$clone" ]; then
      reason="公開側 clone ${clone} に SemVer タグが無く"
    else
      reason="公開側 clone ${clone} が無く"
    fi
    echo "断片未検査: 帰属照合の公開タグを引けません（${reason}、${url} の ls-remote が失敗）: $(cat "$tmp/err" 2>/dev/null)" >&2
    return 2
  fi
  n=0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    n=$((n + 1))
    arc=0
    # dirty_exempt=2: staged で変えた path だけを変更済みとして扱う（作業ツリーだけの編集は commit に入らない）。
    out="$(changelog_attribution_scan "$root" "$public" "$tag" "$(cat "$tmp/body.${n}")" 2)" || arc=$?
    case "$arc" in
      0) ;;
      1)
        printf '%s\n' "$out"
        printf '✗ %s: 前版 v%s と同一内容の path を backtick で参照している（誤帰属の疑い。今回変えた path へ書き換えるか、変えていないものは backtick を外して役割名で書く）\n' "$path" "$tag"
        suspects=1 ;;
      *)
        reason="$(printf '%s\n' "$out" | awk '/^ATTRIBUTION_UNAVAILABLE=/ { sub(/^ATTRIBUTION_UNAVAILABLE=/, ""); print; exit }')"
        echo "断片未検査: ${path} の帰属を判定できません — ${reason:-判定 helper が rc=${arc} を返した}" >&2
        return 2 ;;
    esac
  done <"$tmp/frags"
  [ "$suspects" -eq 0 ] || return 1
  echo "帰属検査: 断片 ${n} 件を ${src} の v${tag} と照合（違反なし）" >&2
  return 0
}

# _changelog_fragment_recheck <root> <tmp> <base>
# 確定した集合は frags-z（NUL区切り）。stdoutは既存契約のため変更しない。
_changelog_fragment_recheck() {
  local root="$1" tmp="$2" base="$3" path item n=0
  local -a staged=() fragments=()
  [ -n "$base" ] || return 0
  if [ ! -f "$tmp/frags-z" ] || [ ! -r "$tmp/frags-z" ] || [ ! -s "$tmp/frags-z" ]; then
    echo "断片未検査: 読み直す断片集合が無いか空、または読めません" >&2
    return 2
  fi
  path=""
  while IFS= read -r -d '' path; do
    [ -n "$path" ] || { echo "断片未検査: 読み直す断片名が空です" >&2; return 2; }
    fragments+=("$path")
  done <"$tmp/frags-z"
  if [ -n "$path" ] || [ "${#fragments[@]}" -eq 0 ]; then
    echo "断片未検査: 読み直す断片集合がNULで終端していません" >&2
    return 2
  fi
  if ! git -C "$root" diff --cached --name-only -z --no-relative --no-renames \
    --diff-filter=ACDMRT -- 'changelog.d/*.md' >"$tmp/recheck-staged" 2>"$tmp/err"; then
    echo "断片未検査: 読み直し判定のstaged一覧を取得できません" >&2
    return 2
  fi
  path=""
  while IFS= read -r -d '' path; do
    [ -n "$path" ] || { echo "断片未検査: 読み直し判定の一覧に空のパスがあります" >&2; return 2; }
    staged+=("$path")
  done <"$tmp/recheck-staged"
  if [ -n "$path" ]; then
    echo "断片未検査: 読み直し判定の一覧がNULで終端していません" >&2
    return 2
  fi
  for path in ${fragments[@]+"${fragments[@]}"}; do
    for item in ${staged[@]+"${staged[@]}"}; do
      [ "$path" != "$item" ] || return 0
    done
  done
  # baseに無くindexにある確定断片が非stagedならHEADにも同じ本文がある。HEAD一覧は再取得しない。
  # 帰属照合が同じ順で保存したindex本文を再利用し、全件読めてからWARNを出す。
  printf '%s\n' 'WARN changelog-fragment: 今回の公開変更と次の断片が食い違っていないか読み直してください（commit継続可）' >"$tmp/recheck-warning"
  for path in ${fragments[@]+"${fragments[@]}"}; do
    n=$((n + 1))
    if [ ! -f "$tmp/body.$n" ] || [ ! -r "$tmp/body.$n" ]; then
      echo "断片未検査: 読み直す断片の保存済みindex本文を読めません: ${path}" >&2
      return 2
    fi
    printf '\n断片: %s (index)\n' "$path" >>"$tmp/recheck-warning"
    if ! cat "$tmp/body.$n" >>"$tmp/recheck-warning"; then
      echo "断片未検査: 読み直す断片本文を表示できません: ${path}" >&2
      return 2
    fi
  done
  if ! cat "$tmp/recheck-warning" >&2; then
    echo "断片未検査: 読み直しWARNを表示できません" >&2
    return 2
  fi
  return 0
}

changelog_fragment_scan() {
  local repo="${1:-.}" root sync targets tmp rc=0 path t hit=0 first="" frag=0 consumed=0 oss_log=0
  local default_ref="" base="" release_script changelog_path plugin_json agent_config allow skip
  local non_prep=0
  local -a spec=() allowlist=()
  if ! root="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || [ -z "$root" ]; then
    echo "断片未検査: git リポジトリとして読めません: ${repo}" >&2
    return 2
  fi
  sync="$root/scripts/sync-dev-toolkit-to-public.sh"
  if [ ! -f "$sync" ]; then
    echo "断片未検査: 公開対象一覧の真実源がありません: ${sync}" >&2
    return 2
  fi
  if ! tmp="$(mktemp -d 2>/dev/null)" || [ ! -d "$tmp" ]; then
    echo "断片未検査: 一時ディレクトリを作成できません" >&2
    return 2
  fi
  # --list-targets はリポジトリルート相対の prefix を返す（cwd をルートへ固定して呼ぶ）。
  if ! targets="$(cd "$root" && bash "$sync" --list-targets 2>"$tmp/err")"; then
    echo "断片未検査: 公開対象一覧を取得できません（--list-targets が失敗）: $(cat "$tmp/err" 2>/dev/null)" >&2
    rm -rf "$tmp"
    return 2
  fi
  while IFS= read -r t; do
    t="${t%/}"
    [ -n "$t" ] || continue
    spec+=("$t")
  done <<EOF
$targets
EOF
  if [ "${#spec[@]}" -eq 0 ]; then
    echo "断片未検査: 公開対象一覧が空です（--list-targets の出力に prefix が 1 件も無い）" >&2
    rm -rf "$tmp"
    return 2
  fi
  # 同期手順 R が断片を要求しないパス（真実源の各スクリプトから読む）。
  while IFS= read -r t; do
    [ -n "$t" ] && allowlist+=("$t")
  done <<EOF
$(_cfg_array_items "$root/scripts/check-release-required.sh" META_ALLOWLIST)
EOF
  release_script="$root/scripts/release-dev-toolkit.sh"
  changelog_path="$(_cfg_scalar "$release_script" CHANGELOG)"
  plugin_json="$(_cfg_scalar "$release_script" PLUGIN_JSON)"
  agent_config="$(_cfg_scalar "$release_script" AGENT_CONFIG)"
  # 公開対象の staged パス。-z で引用符を避け、--no-relative で diff.relative の設定に左右されない。
  git -C "$root" diff --cached --name-only -z --no-relative --no-renames \
    --diff-filter=ACDMRT -- "${spec[@]}" >"$tmp/pub" 2>"$tmp/err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "断片未検査: 公開対象の staged パスを取得できません（rc=${rc}）: $(cat "$tmp/err" 2>/dev/null)" >&2
    rm -rf "$tmp"
    return 2
  fi
  while IFS= read -r -d '' path || [ -n "$path" ]; do
    [ -n "$path" ] || continue
    if [ -n "$changelog_path" ] && [ "$path" = "$changelog_path" ]; then
      oss_log=1
      continue
    fi
    skip=0
    for allow in ${allowlist[@]+"${allowlist[@]}"}; do
      [ "$path" != "$allow" ] || { skip=1; break; }
    done
    [ "$skip" -eq 0 ] || continue
    hit=$((hit + 1))
    [ -n "$first" ] || first="$path"
    if [ -z "$plugin_json" ] || [ -z "$agent_config" ] \
      || { [ "$path" != "$plugin_json" ] && [ "$path" != "$agent_config" ]; }; then
      non_prep=$((non_prep + 1))
    fi
  done <"$tmp/pub"
  if [ "$hit" -eq 0 ]; then
    rm -rf "$tmp"
    echo "changelog-fragment: none"
    return 0
  fi
  # リリース準備（断片の消費）: staged の断片削除 + 公開 CHANGELOG + 準備対象だけ。
  rc=0
  git -C "$root" diff --cached --name-only -z --no-relative --no-renames \
    --diff-filter=D -- 'changelog.d/*.md' >"$tmp/del" 2>"$tmp/err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "断片未検査: staged の断片削除を取得できません（rc=${rc}）: $(cat "$tmp/err" 2>/dev/null)" >&2
    rm -rf "$tmp"
    return 2
  fi
  while IFS= read -r -d '' path || [ -n "$path" ]; do
    case "$path" in
      changelog.d/README.md|changelog.d/*/*) ;;
      changelog.d/*.md) consumed=$((consumed + 1)) ;;
    esac
  done <"$tmp/del"
  if [ "$consumed" -gt 0 ] && [ "$oss_log" -eq 1 ] && [ "$non_prep" -eq 0 ]; then
    rm -rf "$tmp"
    echo "changelog-fragment: consumed ${consumed}"
    return 0
  fi
  # 比較 base。解決できなければ staged の追加だけを見る（base 無しの diff --cached は index 対 HEAD）。
  if default_ref="$(git -C "$root" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)" \
    && [ -n "$default_ref" ]; then
    base="$(git -C "$root" merge-base "$default_ref" HEAD 2>/dev/null)" || base=""
  else
    default_ref=""
  fi
  rc=0
  if [ -n "$base" ]; then
    git -C "$root" diff --cached --name-only -z --no-relative --no-renames \
      --diff-filter=A "$base" -- 'changelog.d/*.md' >"$tmp/add" 2>"$tmp/err" || rc=$?
  else
    git -C "$root" diff --cached --name-only -z --no-relative --no-renames \
      --diff-filter=A -- 'changelog.d/*.md' >"$tmp/add" 2>"$tmp/err" || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    echo "断片未検査: 追加した断片を取得できません（rc=${rc}）: $(cat "$tmp/err" 2>/dev/null)" >&2
    rm -rf "$tmp"
    return 2
  fi
  while IFS= read -r -d '' path || [ -n "$path" ]; do
    case "$path" in
      changelog.d/README.md|changelog.d/*/*) continue ;;
      changelog.d/*.md) ;;
      *) continue ;;
    esac
    # 既定ブランチの先端に既に在る断片は他 PR のもの（merge-base が分岐点より古い回の保険）。
    if [ -n "$default_ref" ] && git -C "$root" cat-file -e "${default_ref}:${path}" 2>/dev/null; then
      continue
    fi
    frag=$((frag + 1))
    printf '%s\n' "$path" >>"$tmp/frags"
    printf '%s\0' "$path" >>"$tmp/frags-z"
  done <"$tmp/add"
  if [ "$frag" -gt 0 ]; then
    rc=0
    _changelog_fragment_attribution "$root" "$tmp" || rc=$?
    if [ "$rc" -eq 0 ]; then
      _changelog_fragment_recheck "$root" "$tmp" "$base" || rc=$?
    fi
    rm -rf "$tmp"
    [ "$rc" -eq 0 ] || return "$rc"
    echo "changelog-fragment: ok ${frag}"
    return 0
  fi
  rm -rf "$tmp"
  if [ -z "$base" ]; then
    if [ -z "$default_ref" ]; then
      echo "断片未検査: origin/HEAD を解決できず比較 base が無く、staged にも断片がありません（公開対象 ${hit} 件。先頭: ${first}）" >&2
    else
      echo "断片未検査: 比較 base（merge-base(${default_ref}, HEAD)）を解決できず、staged にも断片がありません（公開対象 ${hit} 件。先頭: ${first}）" >&2
    fi
    return 2
  fi
  printf '公開対象を変更したのに changelog.d/ 断片がありません: %s（公開対象 %s 件）\n' "$first" "$hit"
  return 1
}
