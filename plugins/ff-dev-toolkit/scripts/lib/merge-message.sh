#!/usr/bin/env bash
# Source-only merge-message helpers. Callers choose fail-open or fail-closed for rc 2.
# Sets REFS_RAW/CLOSES_RAW/CLOSES_UNION/REFS_ONLY; emits no stdout.
ff_merge_issue_sets() { # <owner/repo> <PR body> <API closing refs> <checker keyword lines>
  local TARGET_REPO="$1" PR_BODY="$2" API_CLOSES_TOKENS="$3" EXTRACT_RC KEYWORDS_PATTERN
  KEYWORDS_PATTERN="$(printf '%s\n' "$4" | LC_ALL=C awk '
    NF { if ($0 !~ /^[a-z]+$/) exit 2; s = s (n++ ? "|" : "") $0 }
    END { if (!n) exit 2; print s }
  ')" || return 2
  # 拾う綴りは Ref / Refs のみ（大文字小文字は問わない。コロンが続く形も可）。`関連 #N` や
  # 裸の `#N` は拾わない。awk の現在行を $(0) と書くのは、裸のドル記号 + 0 が skill 読み込み時の
  # 引数展開で PR 番号へ置換された実測（本文から定数文字列に化けて抽出 0 件で素通り）の名残で、
  # script 側でも同じ形を保つ（awk では $ は演算子なので $(0) は現在行と完全に同義）。
  REFS_RAW="$(set -o pipefail
    printf '%s\n' "${PR_BODY}" | awk '
      {
        line = $(0)
        while (match(line, /(^|[^A-Za-z])[Rr][Ee][Ff][Ss]?[ \t:]*([A-Za-z0-9._-]+\/[A-Za-z0-9._-]+)?#[0-9]+/)) {
          token = substr(line, RSTART, RLENGTH)
          sub(/^([^A-Za-z])?[Rr][Ee][Ff][Ss]?[ \t:]*/, "", token)
          print token
          line = substr(line, RSTART + RLENGTH)
        }
      }' | sort -u)"
  EXTRACT_RC=$?
  [[ "${EXTRACT_RC}" -eq 0 ]] || return 2
  # 本文からの closing keyword 抽出。拾う綴りは GitHub の closing keyword 9 語（大文字小文字は
  # 問わない。コロンが続く形も可）。語中一致（hotfix の fix、enclose の close、auto_fix の fix）は
  # (^|[^a-z0-9_]) で除外する。Refs / 関連 / 裸の #N は拾わない。
  CLOSES_RAW="$(set -o pipefail
    LC_ALL=C
    printf '%s\n' "${PR_BODY}" | awk -v keywords="$KEYWORDS_PATTERN" '
      {
        line = tolower($(0))
        while (match(line, "(^|[^a-z0-9_])(" keywords ")[ \t:]*([a-z0-9._-]+/[a-z0-9._-]+)?#[0-9]+")) {
          token = substr(line, RSTART, RLENGTH)
          sub("^([^a-z0-9_])?(" keywords ")[ \t:]*", "", token)
          print token
          line = substr(line, RSTART + RLENGTH)
        }
      }' | sort -u)"
  EXTRACT_RC=$?
  [[ "${EXTRACT_RC}" -eq 0 ]] || return 2
  # 裸の #N を現在のリポジトリで修飾し、API 由来と本文由来を 1 件に畳む。
  # 集合キーは小文字化して畳む（GitHub の owner/repo は大小を区別しない）。
  CLOSES_UNION="$(set -o pipefail
    LC_ALL=C
    printf '%s\n' "${API_CLOSES_TOKENS}" "${CLOSES_RAW}" \
    | awk -v repo="${TARGET_REPO}" '
        NF {
          token = tolower($(0))
          repo_l = tolower(repo)
          if (token ~ /^#[0-9]+$/) token = repo_l token
          print token
        }
      ' | sort -u)"
  EXTRACT_RC=$?
  [[ "${EXTRACT_RC}" -eq 0 ]] || return 2
  # Refs のうち Closes 和集合に含まれないもの（同じ Issue を二重に照合しない）。
  # closing 集合は -v に載せない（awk -v は改行を保持しない実装がある）。C 行を先に流す。
  REFS_ONLY="$(set -o pipefail
    LC_ALL=C
    {
      printf '%s\n' "${CLOSES_UNION}" | awk 'NF{print "C\t" $(0)}'
      printf '%s\n' "${REFS_RAW}" | awk -v repo="${TARGET_REPO}" '
        NF {
          token = tolower($(0))
          repo_l = tolower(repo)
          if (token ~ /^#[0-9]+$/) token = repo_l token
          print "R\t" token
        }
      '
    } | awk -F'\t' '
      $1 == "C" { seen[$2] = 1; next }
      $1 == "R" && !($2 in seen) { print $2 }
    ' | sort -u)"
  EXTRACT_RC=$?
  [[ "${EXTRACT_RC}" -eq 0 ]] || return 2

  return 0
}

# Byte-transparent single-quote escaping; sentinel preserves trailing LF through command substitution.
ff_merge_quote() { local s; s="$(printf '%sX' "$1" | sed "s/'/'\\\\''/g")" || return 1; printf "'%s'" "${s%X}"; }

ff_merge_emit() { # <PR> <repo URL> <head> <have message> <subject> <body> [delete flag] [tail] [squash|merge]
  local quoted_target_repo quoted_merge_subject="" quoted_merge_body="" method="${9:-squash}"
  case "$method" in squash|merge) ;; *) return 2 ;; esac
  quoted_target_repo="$(ff_merge_quote "$2")" || return 2
  if [ "$4" -eq 1 ]; then
    [ -n "$5" ] || return 2
    quoted_merge_subject="$(ff_merge_quote "$5")" && quoted_merge_body="$(ff_merge_quote "$6")" || return 2
  fi
  echo "MERGE_COMMAND_BEGIN"
  if [ "$4" -eq 1 ]; then
    printf 'gh pr merge %s --repo %s --%s --match-head-commit %s%s \\\n  --subject %s \\\n  --body %s%s\n' "$1" "$quoted_target_repo" "$method" "$3" "${7:-}" "$quoted_merge_subject" "$quoted_merge_body" "${8:-}"
  else
    printf 'gh pr merge %s --repo %s --%s --match-head-commit %s%s%s\n' "$1" "$quoted_target_repo" "$method" "$3" "${7:-}" "${8:-}"
  fi
  echo "MERGE_COMMAND_END"
}

# Prefix every physical line, so tabs within message text cannot become an origin field.
ff_merge_surface() { printf '%s\n' "$2" | LC_ALL=C awk -v origin="$1" '{print origin "\t" $0}'; }
