#!/usr/bin/env bash
#
# read-only suite の事前・事後状態を取得する共通実装。
#
# 呼び出し側の `set -e` / `pipefail` に依存せず、対象欠落・通常ファイル 0 件・
# find / cksum / sort のいずれかの失敗を必ず非 0 にする。通常ファイルは
# `-exec ... {} +` で渡すため、空白を含むパスも引数分割しない。第 3 引数の
# prune_name は単一の find `-name` パターンで、空文字なら除外なし。

ff_tree_state() {
  local root="$1"
  local target="$2"
  local prune_name="${3:-}"

  (
    set -o pipefail
    local file_list

    cd "$root" || exit 1

    if [[ ! -d "$target" ]]; then
      echo "ff_tree_state: 対象ディレクトリが見つかりません: $target" >&2
      exit 1
    fi

    run_find() {
      if [[ -n "$prune_name" ]]; then
        find "$target" -name "$prune_name" -prune -o "$@"
      else
        find "$target" "$@"
      fi
    }

    file_list="$(run_find -type f -print)" || exit 1
    if [[ -z "$file_list" ]]; then
      echo "ff_tree_state: 通常ファイルが 0 件です: $target" >&2
      exit 1
    fi

    run_find -print | LC_ALL=C sort &&
      run_find -type f -exec cksum {} + | LC_ALL=C sort
  )
}
