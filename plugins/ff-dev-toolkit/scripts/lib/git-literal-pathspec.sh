#!/usr/bin/env bash
# source 専用。abs-path.sh を先に読み込む。
# global --literal-pathspecs は hook の Git 操作にも伝播するため使わない。
# 呼出元の Git 環境を保持し、filesystem の入力だけを個別に literal にする。
ff_git_literal() {
  local repo="$1"; shift
  local -a options=() paths=() specs=() selected=() directories=()
  local literal icase p absolute parent prefix relative listing actual allowed count i bad top=""
  while [[ $# -gt 0 && "$1" != -- ]]; do options+=("$1"); shift; done
  if [[ $# -eq 0 || ${#options[@]} -eq 0 ]]; then
    echo '✗ literal Git 操作のコマンドまたは path 区切りがありません' >&2; return 2
  fi
  shift
  [[ $# -gt 0 ]] || { echo '✗ literal Git 操作の対象が空です' >&2; return 2; }
  paths=("$@")
  literal="$(git -C "$repo" -c "ff.knowledgeLiteral=${GIT_LITERAL_PATHSPECS:-0}" config --type=bool --get ff.knowledgeLiteral)" || return 2
  icase="$(git -C "$repo" -c "ff.knowledgeIcase=${GIT_ICASE_PATHSPECS:-0}" config --type=bool --get ff.knowledgeIcase)" || return 2
  for p in "${paths[@]}"; do
    [[ -n "$p" ]] || { echo '✗ literal Git 操作の対象パスが空です' >&2; return 2; }
    if [[ "$literal" == true ]]; then specs+=("$p"); continue; fi
    # 絶対パスはリポジトリのルートからの相対へ直してから literal にする。Windows の Git Bash は
    # `/c/…` で始まる引数だけを `C:/…` へ変換し、`:(literal)/c/…` はそのまま git.exe へ渡して
    # 解決できない（Issue `#2449`）。ルートの外・親が無いパスは従来の形のまま git に判定させる。
    # GIT_DIR / GIT_WORK_TREE を export した環境では作業ツリーの外でも同じ toplevel が返るので、
    # 親が作業ツリーの内側であることも確かめる（外のパスをルート直下の同名ファイルへ付け替えない）
    if ff_path_is_absolute "$p" && [[ -d "${p%/*}/" ]]; then
      [[ -n "$top" ]] || top="$(git -C "$repo" rev-parse --show-toplevel)" || return 2
      if [[ "$(git -C "${p%/*}/" rev-parse --is-inside-work-tree 2>/dev/null)" == true ]] \
        && [[ "$(git -C "${p%/*}/" rev-parse --show-toplevel 2>/dev/null)" == "$top" ]] \
        && prefix="$(git -C "${p%/*}/" rev-parse --show-prefix)"; then
        specs+=(":(top,literal)${prefix}${p##*/}"); continue
      fi
    fi
    specs+=(":(literal)$p")
  done
  if [[ "$icase" == true ]]; then
    # Git の global icase は個別 literal にも作用する。別の case 名まで
    # 選ぶ入力は、hook の環境を変更して続行せず、操作前に明示的に止める。
    for p in "${paths[@]}"; do
      if ff_path_is_absolute "$p"; then absolute="$p"; else absolute="$repo/$p"; fi
      if [[ -d "$absolute" ]]; then
        relative="$(git -C "$absolute" rev-parse --show-prefix)" || return 2
        selected+=("${relative%/}"); directories+=(1)
      else
        parent="${absolute%/*}"
        prefix="$(git -C "$parent" rev-parse --show-prefix)" || return 2
        selected+=("${prefix}${absolute##*/}"); directories+=(0)
      fi
    done
    listing="$(mktemp "${TMPDIR:-/tmp}/ff-literal-paths.XXXXXX")" || return 2
    if ! git -C "$repo" ls-files -c -o --exclude-standard -z -- "${specs[@]}" >"$listing"; then
      rm -f -- "$listing"; return 2
    fi
    count=0; bad=0
    while IFS= read -r -d '' actual; do
      count=$((count + 1)); allowed=0
      for ((i=0; i<${#selected[@]}; i++)); do
        relative="${selected[$i]}"
        if [[ "$actual" == "$relative" ]] \
          || { [[ "${directories[$i]}" == 1 ]] && { [[ -z "$relative" ]] || [[ "$actual" == "$relative/"* ]]; }; }; then
          allowed=1; break
        fi
      done
      if [[ "$allowed" -eq 0 ]]; then bad=1; break; fi
    done <"$listing"
    rm -f -- "$listing" || return 2
    if [[ "$count" -eq 0 || "$bad" -ne 0 ]]; then
      echo '✗ Git の icase 設定で literal 対象が空または拡大します。GIT_ICASE_PATHSPECS を外して再実行してください' >&2
      return 2
    fi
  fi
  git -C "$repo" "${options[@]}" -- "${specs[@]}"
}
