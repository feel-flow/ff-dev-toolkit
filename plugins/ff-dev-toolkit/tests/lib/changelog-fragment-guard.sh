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
#
# 出力と終了コード:
#   rc=0  stdout `changelog-fragment: ok <N>`        公開対象の変更に対し断片 N 件（1 以上）
#   rc=0  stdout `changelog-fragment: none`          staged に数える公開対象の変更が無い（「違反なし」ではなく「対象なし」）
#   rc=0  stdout `changelog-fragment: consumed <N>`  断片を集約するリリース準備の回（N は削除した断片数）
#   rc=1  stdout `公開対象を変更したのに changelog.d/ 断片がありません: <先頭パス>（公開対象 <M> 件）`
#   rc=2  stderr `断片未検査: <理由>`   判定材料を取得できない。緑とも違反なしとも報告しない
#         （リポジトリではない・公開対象一覧を取得できない / 空・git が失敗した・
#         比較 base を解決できず staged にも断片が無い・一時領域を作れない）

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
  done <"$tmp/add"
  rm -rf "$tmp"
  if [ "$frag" -gt 0 ]; then
    echo "changelog-fragment: ok ${frag}"
    return 0
  fi
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
