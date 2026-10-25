#!/usr/bin/env bash
# Source-only precommit guard. Limits and roster stay in their existing suites;
# parse their index versions, never execute a suite or evaluate shell text.
# skill_byte_scan REPO: index blobs, rc 0=ok/none, 1=over limit, 2=unmeasured.

_skill_byte_definitions() {
  local finish="$1" review="$2" file
  for file in "$finish" "$review"; do
    if [ ! -f "$file" ] || [ ! -r "$file" ] || [ ! -s "$file" ]; then
      echo "SKILL容量未検査: 上限定義を読めません: ${file}" >&2
      return 2
    fi
  done
  awk -v finish="$finish" -v review="$review" '
    { sub(/\r$/, "") }
    FILENAME == finish && /^SKILL_BYTE_LIMIT=/ {
      limits++; if ($0 !~ /^SKILL_BYTE_LIMIT=[1-9][0-9]*$/) bad=1
      limit=substr($0, index($0,"=")+1)
    }
    FILENAME == finish && /^SKILL_ROSTER=/ {
      rosters++; if ($0 !~ /^SKILL_ROSTER="[a-z0-9 -]+"$/) bad=1
      roster=substr($0, index($0,"=")+2); sub(/"$/, "", roster)
    }
    FILENAME == review && /^SKILL_MAX_BYTES=/ {
      reviews++; if ($0 !~ /^SKILL_MAX_BYTES=[1-9][0-9]*$/) bad=1
      review_limit=substr($0, index($0,"=")+1)
    }
    END {
      if (bad || limits!=1 || rosters!=1 || reviews!=1 || length(limit)>9 || length(review_limit)>9) exit 2
      n=split(roster,names,/ +/)
      if (n<1) exit 2
      for(i=1;i<=n;i++) {
        name=names[i]
        if(name !~ /^[a-z][a-z0-9-]*$/ || seen[name]++) exit 2
        if(name=="multi-review" && limit!=review_limit) exit 2
      }
      for(i=1;i<=n;i++) print "plugins/ff-dev-toolkit/skills/" names[i] "/SKILL.md\t" limit
      if (!("multi-review" in seen)) print "plugins/ff-dev-toolkit/skills/multi-review/SKILL.md\t" review_limit
    }
  ' "$finish" "$review"
}

skill_byte_scan() (
  set -o pipefail
  local repo="${1:-.}" root tmp tool path mode limit bytes source unmerged hit=0 violations=0
  for tool in git awk wc tr mktemp rm cat; do
    command -v "$tool" >/dev/null 2>&1 || { echo "SKILL容量未検査: ${tool} がありません" >&2; return 2; }
  done
  root="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || { echo "SKILL容量未検査: git rootを解決できません" >&2; return 2; }
  if ! tmp="$(mktemp -d 2>/dev/null)" || [ ! -d "$tmp" ]; then
    echo "SKILL容量未検査: 一時領域を作れません" >&2; return 2
  fi
  trap 'rc=$?; rm -rf "$tmp"; exit "$rc"' EXIT
  for source in finish review-rejection-discipline; do
    path="plugins/ff-dev-toolkit/tests/${source}/verify.sh"
    mode="$(git -C "$root" ls-files --stage -- ":(literal)${path}")" || { echo "SKILL容量未検査: 上限定義のindex modeを読めません: ${path}" >&2; return 2; }
    case "$mode" in 100644\ *|100755\ *) ;; *) echo "SKILL容量未検査: 上限定義のindexが通常ファイルではありません: ${path}" >&2; return 2 ;; esac
    if ! git -C "$root" show ":${path}" >"$tmp/${source}"; then
      echo "SKILL容量未検査: indexの上限定義を読めません: ${path}" >&2; return 2
    fi
  done
  if ! _skill_byte_definitions "$tmp/finish" "$tmp/review-rejection-discipline" >"$tmp/definitions"; then
    echo "SKILL容量未検査: 上限/名簿定義が不在・空・重複・想定書式外です" >&2; return 2
  fi
  if [ ! -s "$tmp/definitions" ]; then
    echo "SKILL容量未検査: 名簿が空です" >&2; return 2
  fi
  unmerged="$(git -C "$root" ls-files --unmerged)" || { echo "SKILL容量未検査: indexの衝突を調べられません" >&2; return 2; }
  if [ -n "$unmerged" ]; then
    echo "SKILL容量未検査: indexに未解決の衝突があります" >&2; return 2
  fi
  if ! git -C "$root" diff --cached --name-only -z --no-relative --no-renames --diff-filter=ACDMRT >"$tmp/paths"; then
    echo "SKILL容量未検査: stagedパスを列挙できません" >&2; return 2
  fi
  while :; do
    path=""
    if IFS= read -r -d '' path; then
      [ -n "$path" ] || { echo "SKILL容量未検査: stagedパスが空です" >&2; return 2; }
    elif [ -n "$path" ]; then
      echo "SKILL容量未検査: stagedパスのNUL終端がありません" >&2; return 2
    else
      break
    fi
    case "$path" in plugins/ff-dev-toolkit/skills/*/SKILL.md) ;; *) continue ;; esac
    # Roster paths contain only portable skill names, not arbitrary shell text.
    limit="$(awk -F '\t' -v path="$path" '$1==path {print $2}' "$tmp/definitions")" || { echo "SKILL容量未検査: 名簿照合に失敗しました" >&2; return 2; }
    [ -n "$limit" ] || continue
    mode="$(git -C "$root" ls-files --stage -- ":(literal)${path}")" || { echo "SKILL容量未検査: index modeを読めません: ${path}" >&2; return 2; }
    case "$mode" in 100644\ *|100755\ *) ;; *) echo "SKILL容量未検査: indexが通常ファイルではありません: ${path}" >&2; return 2 ;; esac
    if ! git -C "$root" show ":${path}" >"$tmp/blob"; then
      echo "SKILL容量未検査: index内容を読めません: ${path}" >&2; return 2
    fi
    bytes="$(LC_ALL=C wc -c <"$tmp/blob")" || { echo "SKILL容量未検査: バイト数を測れません: ${path}" >&2; return 2; }
    bytes="$(printf '%s' "$bytes" | tr -d '[:space:]')" || { echo "SKILL容量未検査: バイト数を読めません: ${path}" >&2; return 2; }
    case "$bytes" in ''|*[!0-9]*) echo "SKILL容量未検査: バイト数が数値ではありません: ${path}" >&2; return 2 ;; esac
    if [ "$bytes" -eq 0 ]; then echo "SKILL容量未検査: index内容が空です: ${path}" >&2; return 2; fi
    hit=$((hit + 1))
    if [ "$bytes" -gt "$limit" ]; then
      printf '%s: %s B > %s B（上限超過）\n' "$path" "$bytes" "$limit"
      violations=$((violations + 1))
    fi
  done <"$tmp/paths"
  [ "$violations" -eq 0 ] || return 1
  if [ "$hit" -gt 0 ]; then echo "skill-byte: ok ${hit}"; else echo "skill-byte: none"; fi
)
