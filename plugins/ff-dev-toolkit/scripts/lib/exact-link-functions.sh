#!/usr/bin/env bash
# destination を directory と解釈しない link(2) で、既存 path を上書きせず hard link を作る。

exact_link_no_replace() {
  [[ $# -eq 2 ]] || { echo "exact_link_no_replace: source と destination が必要です" >&2; return 2; }
  command -v perl >/dev/null 2>&1 || { echo "exact_link_no_replace: perl が見つかりません" >&2; return 2; }
  perl -e 'use strict; use warnings; link($ARGV[0], $ARGV[1]) or die "$!\n";' "$1" "$2"
}
