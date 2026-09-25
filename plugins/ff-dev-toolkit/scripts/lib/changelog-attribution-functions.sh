#!/usr/bin/env bash
# Shared token extraction, candidate order and the attribution scan for the fragment,
# pre-release and public-tag gates.
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

# Newest strict vX.Y.Z tag of a clone, sorted numerically (stock macOS has no sort -V).
# $1 = clone. stdout = X.Y.Z, or empty when the clone has no such tag. Non-zero when tags are unreadable.
changelog_latest_semver_tag() {
  local tags
  tags="$(git -C "$1" tag -l 2>/dev/null)" || return 1
  printf '%s\n' "$tags" | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
    | sed 's/^v//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1 || true
}

# One ls-tree entry as "<oid><TAB><source path>". $1 = ls-tree -r -t output, $2 = public path,
# $3 = 1 for the candidate projection (oss/ff-dev-toolkit/* is the public root, except LICENSE
# copied from the plugin). Empty output means absent; command failures remain distinct (awk reads
# to the end: an early exit would SIGPIPE printf and flip the rc under pipefail).
changelog_tree_entry() {
  local lookup="${2#./}"
  if [[ "$3" == 1 && "${lookup%/}" == LICENSE ]]; then
    lookup="plugins/ff-dev-toolkit/LICENSE"
  fi
  printf '%s\n' "$1" | awk -F '\t' -v p="${lookup%/}" -v project="$3" '
    { path=$2; if(project) sub(/^oss\/ff-dev-toolkit\//,"",path)
      if(path==p) {split($1,a," "); print a[3] "\t" $2} }'
}

# The attribution judgement shared by the release gate (check-release-required: the new version
# section) and the fragment gate (materialize --check: each changelog.d fragment). A path-like
# backtick whose object at the SSOT HEAD equals the latest public tag was not changed by this
# release, so naming it in the new section is a misattribution suspect. Directory markers such as
# .github/ compare tree objects (ls-tree -t).
#   $1 = SSOT root  $2 = public clone  $3 = latest tag (X.Y.Z)  $4 = body text
#   $5 = 1: a path with uncommitted changes in the SSOT working tree counts as changed (the
#        fragment stage is often checked before the change and its fragment are committed)
# stdout: one "ATTRIBUTION_PATH=<token> -> <public path> (v<tag> と同一 object)" per suspect,
#         or a single "ATTRIBUTION_UNAVAILABLE=<reason>" line.
# return: 0 = no suspect / 1 = suspects / 2 = cannot judge (never reported as clean).
changelog_attribution_scan() {
  local root="$1" public="$2" ver="$3" body="$4" dirty_exempt="${5:-0}"
  local paths public_tree candidate_tree token candidate from to from_oid to_oid to_src count=0
  paths="$(extract_paths "$body")" || { echo "ATTRIBUTION_UNAVAILABLE=path-like backtick の抽出に失敗"; return 2; }
  [[ -n "$paths" ]] || return 0
  public_tree="$(git -C "$public" ls-tree -r -t "refs/tags/v${ver}" 2>/dev/null)" \
    || { echo "ATTRIBUTION_UNAVAILABLE=公開タグ v${ver} の tree を取得できない"; return 2; }
  candidate_tree="$(git -C "$root" ls-tree -r -t HEAD -- plugins/ff-dev-toolkit oss/ff-dev-toolkit 2>/dev/null)" \
    || { echo "ATTRIBUTION_UNAVAILABLE=リリース候補 HEAD の tree を取得できない"; return 2; }
  while IFS= read -r token; do
    [[ -n "$token" ]] || continue
    while IFS= read -r candidate; do
      from="$(changelog_tree_entry "$public_tree" "$candidate" 0)" \
        || { echo "ATTRIBUTION_UNAVAILABLE=公開 path の解決に失敗: $token"; return 2; }
      to="$(changelog_tree_entry "$candidate_tree" "$candidate" 1)" \
        || { echo "ATTRIBUTION_UNAVAILABLE=候補 path の解決に失敗: $token"; return 2; }
      from_oid="${from%%$'\t'*}"; to_oid="${to%%$'\t'*}"; to_src="${to#*$'\t'}"
      [[ -n "$from_oid$to_oid" ]] || continue
      if [[ -n "$from_oid" ]]; then
        git -C "$public" cat-file -p "$from_oid" >/dev/null 2>&1 \
          || { echo "ATTRIBUTION_UNAVAILABLE=公開タグの object を読めない: $token"; return 2; }
      fi
      if [[ -n "$to_oid" ]]; then
        git -C "$root" cat-file -p "$to_oid" >/dev/null 2>&1 \
          || { echo "ATTRIBUTION_UNAVAILABLE=候補 HEAD の object を読めない: $token"; return 2; }
      fi
      if [[ -n "$from_oid" && "$from_oid" == "$to_oid" ]]; then
        if [[ "$dirty_exempt" == 1 && -n "$(git -C "$root" status --porcelain -- "$to_src" 2>/dev/null)" ]]; then
          break
        fi
        printf 'ATTRIBUTION_PATH=%s -> %s (v%s と同一 object)\n' "$token" "$candidate" "$ver"
        count=$((count + 1))
      fi
      break
    done < <(changelog_path_candidates "$token")
  done < <(printf '%s\n' "$paths")
  [[ "$count" -eq 0 ]] || return 1
  return 0
}
