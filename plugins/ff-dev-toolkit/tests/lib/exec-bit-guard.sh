#!/usr/bin/env bash
#
# staged された suite / hook の実行ビット欠落を commit 前に名指しする（Issue `#1741` /
# bundle `#1758` / OBS-206）。
#
# Write ツールやリダイレクト、`head`/`cat` + `mv` によるファイル全体の再構成で作った
# `.sh` は mode 100644 になる。`tests/run-all.sh` は suite の `verify.sh` に `-x` を
# 起動条件として課すので、実行ビットの無い suite は全件ゲート（約 20 分）の末尾に
# `not run (not executable)` として出るまで誰も気付かない（OBS-206 Count 3）。
# `/pre-commit-check` 手順 8 がこの関数を呼び、commit 前に同じ欠落を赤にする。
#
# 公開関数:
#   exec_bit_scan [REPO]
#     REPO（既定: カレントディレクトリ）の index を読み、staged（ACMR）のうち次の対象の
#     index 側 mode を見る。見るのは作業ツリーの mode ではなく**commit される mode**。
#       plugins/ff-dev-toolkit/tests/<suite>/verify.sh  … run-all.sh の起動条件が -x
#       plugins/ff-dev-toolkit/hooks/<名>.sh
#     `tests/lib/*.sh` は source 前提なので対象外。suite の下の階層（fixture の
#     `tests/<suite>/fixtures/**/verify.sh` 等）も対象外。
#
# 判定材料は `git diff --cached --raw -z`。`--summary` の `create mode` / `mode change`
# 行と同じ index 側 mode を、mode を変えていない修正（M）・種別変更（T。symlink から
# 通常ファイルへの置換など）も含めた全 staged エントリについて出すので、こちらを読む。
# 取りこぼしを作らないための固定オプション:
#   -z             パスを引用符で囲まない（`"` / `\` / TAB / 改行を含むパスも生で届く）
#   --no-relative  `diff.relative=true` の設定下でサブディレクトリから呼ばれても全パスを出す
#   --no-renames   rename 検出を切る（改名は A + D として出る。検出上限の警告も出ない）
# 対象外として数えないもの: 削除（D）と submodule（160000 は対象パスの形にならない）。
# 未解決の衝突（U）が 1 件でもあれば index 側 mode が定まらないので判定不能（rc=2）へ倒す。
#
# 出力と終了コード:
#   rc=0  stdout `exec-bit: ok <N>`    対象 N 件（1 以上）がすべて 100755
#   rc=0  stdout `exec-bit: none`      staged に対象が無い（「違反なし」ではなく「対象なし」）
#   rc=1  stdout `<path>: <mode>（実行ビットなし）` を 1 件 1 行   違反
#   rc=2  stderr `実行ビット未検査: <理由>`   判定材料を取得できない・読めない。
#         緑とも違反なしとも報告しない（git が失敗した・リポジトリではない・
#         raw 出力の書式が想定と違う・未解決の衝突がある・一時領域を作れない）

exec_bit_scan() {
  local repo="${1:-.}" tmp rc=0 meta path mode mode_ok status hit=0 viol=0
  if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    echo "実行ビット未検査: git リポジトリとして読めません: ${repo}" >&2
    return 2
  fi
  if ! tmp="$(mktemp -d 2>/dev/null)" || [ ! -d "$tmp" ]; then
    echo "実行ビット未検査: 一時ディレクトリを作成できません" >&2
    return 2
  fi
  # NUL 区切りは変数へ入らない（bash は NUL を保持できない）ので、stdout はファイルで受ける。
  # stderr は別ファイルへ分け、成功時の警告行を判定材料へ混ぜない。
  git -C "$repo" diff --cached --raw -z --no-abbrev --no-relative --no-renames \
    --diff-filter=ACMRTU >"$tmp/raw" 2>"$tmp/err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "実行ビット未検査: git diff --cached --raw が失敗しました（rc=${rc}）: $(cat "$tmp/err" 2>/dev/null)" >&2
    rm -rf "$tmp"
    return 2
  fi
  # 1 エントリ = `:<旧mode> <新mode> <旧sha> <新sha> <状態>` NUL `<path>` NUL。
  # この形を外れたエントリが 1 件でもあれば書式変更として判定不能へ倒す（読めない
  # エントリを読み飛ばすと、対象を 0 件と数えて none の緑になる）。NUL で終端しない
  # 末尾の断片（-z を解さない出力など）も `|| [ -n … ]` で拾い、書式判定へ回す。
  while IFS= read -r -d '' meta || [ -n "$meta" ]; do
    path=""
    if ! IFS= read -r -d '' path && [ -z "$path" ]; then
      echo "実行ビット未検査: git diff --cached --raw の出力を読めません（パスの欠けたエントリ: ${meta}）" >&2
      rm -rf "$tmp"
      return 2
    fi
    # shellcheck disable=SC2086 # meta は空白区切りの 5 語。語分割がここでの意図
    set -- $meta
    mode="${2:-}"
    status="${5:-}"
    case "$mode" in
      [0-7][0-7][0-7][0-7][0-7][0-7]) mode_ok=1 ;;
      *) mode_ok=0 ;;
    esac
    if [ "$#" -ne 5 ] || [ "${1:0:1}" != ":" ] || [ "$mode_ok" -ne 1 ]; then
      echo "実行ビット未検査: git diff --cached --raw の出力を読めません（想定外のエントリ: ${meta}）" >&2
      rm -rf "$tmp"
      return 2
    fi
    case "$status" in
      U*)
        echo "実行ビット未検査: 未解決の衝突があります（index 側 mode が定まらない）: ${path}" >&2
        rm -rf "$tmp"
        return 2
        ;;
    esac
    case "$path" in
      plugins/ff-dev-toolkit/tests/*/verify.sh)
        case "${path#plugins/ff-dev-toolkit/tests/}" in */*/*) continue ;; esac ;;
      plugins/ff-dev-toolkit/hooks/*.sh)
        case "${path#plugins/ff-dev-toolkit/hooks/}" in */*) continue ;; esac ;;
      *) continue ;;
    esac
    hit=$((hit + 1))
    if [ "$mode" != "100755" ]; then
      viol=$((viol + 1))
      printf '%s: %s（実行ビットなし）\n' "$path" "$mode"
    fi
  done <"$tmp/raw"
  rm -rf "$tmp"
  if [ "$viol" -gt 0 ]; then
    return 1
  fi
  if [ "$hit" -gt 0 ]; then
    echo "exec-bit: ok ${hit}"
  else
    echo "exec-bit: none"
  fi
  return 0
}
