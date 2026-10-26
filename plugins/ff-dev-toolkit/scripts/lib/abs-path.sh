#!/usr/bin/env bash
# 絶対パスの判定（source 専用。シェルのオプションを変えない）。
#
# ff_path_is_absolute PATH
#   rc 0 = このホストで絶対パス / rc 1 = それ以外（相対・空）。
#   `/` 始まりは常に絶対。MSYS（Windows の Git Bash）/ Cygwin のホストだけ、ドライブ文字の後に
#   区切りがある形（C:/x・C:\x）も絶対とする — git やホストのファイル編集機能がこの形を返すので、
#   `/` 始まりだけで判定すると拒否するか cwd などへ誤って連結する（ACE-2027-1。Issue `#2334` /
#   `#2367`）。それ以外の OS では C:/x は cwd からの相対パスなので従来どおり相対。区切りの無い
#   C:x は MSYS でも相対（ドライブの現在ディレクトリからの相対）。
#
# 呼び出し側（--github-input の受け口・ace-pending.sh・knowledge-commit.sh・workflow-doctor.sh・
# guard-merge-closing-keyword.sh・adapter-common-git.sh）はこの関数だけで判定し、`/` 始まりの
# 独自判定を持たない（tests/github-input-precheck が照合する）。

ff_path_is_absolute() {
  case "$1" in /*) return 0 ;; esac
  case "${OSTYPE:-}" in
    msys* | cygwin*)
      case "$1" in [A-Za-z]:/* | [A-Za-z]:\\*) return 0 ;; esac
      ;;
  esac
  return 1
}
