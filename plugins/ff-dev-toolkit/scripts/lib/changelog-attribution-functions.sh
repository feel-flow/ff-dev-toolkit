#!/usr/bin/env bash
# Shared token extraction and candidate order for pre-release and public-tag gates.
# No side effects when sourced; bash 3.2 compatible.
# Candidate order is contractual: first path present in either tree wins.
changelog_path_candidates() {
  printf '%s\n' "$1" "plugins/ff-dev-toolkit/$1" "plugins/ff-dev-toolkit/${1#./}"
}

# Only slash-containing backticks; exclude commands, flags, URLs and placeholders.
extract_paths() {
  # $1 = body text. stdout = one path per line, unique order-preserving.
  # awk の /.../ 区切りは class 内の / を終端と誤認するため、文字列マッチを使う。
  printf '%s' "$1" | awk '
    {
      s = $0
      while (match(s, /`[^`]+`/)) {
        tok = substr(s, RSTART + 1, RLENGTH - 2)
        s = substr(s, RSTART + RLENGTH)
        if (tok ~ /[[:space:]]/) continue
        if (tok ~ /^-/) continue
        if (tok ~ /^\//) continue
        if (tok ~ /^https?:/) continue
        if (tok ~ /[<>]/) continue
        if (index(tok, "/") == 0) continue
        if (tok !~ "^[A-Za-z0-9_./@+-]+$") continue
        if (!(tok in seen)) {
          seen[tok] = 1
          print tok
        }
      }
    }
  '
}
