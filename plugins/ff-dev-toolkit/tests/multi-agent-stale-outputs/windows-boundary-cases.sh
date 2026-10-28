#!/usr/bin/env bash
# Host spelling tests use a stub converter and synthetic local paths. They do
# not verify real Windows ACLs, drive mounts, or UNC access.
# pipefail-inherited: verify.sh runs under set -euo pipefail.
run_windows_boundary_cases() {
  local result original_ostype="${OSTYPE:-}" drive backslash unc
  drive='C:/review-output'
  backslash='C:\review-output'
  unc='\\server\share\out'
  if [[ "$(ff_review_output_lexical_path //server/share/out)" == //server/share/out ]]; then
    ok 'UNC lexical normalization preserves its leading double slash'
  else bad 'UNC leading double slash was lost'; fi
  if [[ "$(OSTYPE=linux ff_review_output_host_path "$drive")" == "$drive" ]]; then
    ok 'POSIX C:/x stays a relative path spelling'
  else bad 'POSIX drive-looking relative path was reinterpreted'; fi
  if [[ "$(OSTYPE=linux ff_review_output_host_path "$backslash")" == "$backslash" ]]; then
    ok 'POSIX backslashes remain literal filename bytes'
  else bad 'POSIX backslash filename bytes were changed'; fi
  if [[ "$(OSTYPE=msys ff_review_output_host_path C:x)" == C:x ]]; then
    ok 'Windows C:x remains relative per the absolute-path contract'
  else bad 'Windows drive-relative C:x became absolute'; fi
  case "$original_ostype" in msys*|cygwin*)
    echo '  ○ skip: stubbed drive mutation controls run only on POSIX hosts; real Windows drives/ACLs and UNC shares remain unverified'
    return 0 ;;
  esac
  for result in "$drive" "$backslash"; do
    if ( cd "$REPO"
      cygpath() { printf 'called\n' >> "$TMP/cygpath.calls"; printf '%s\n' "$TMP/converted-output"; }
      OSTYPE=msys ff_review_output_prepare "$REPO" "$result" true review
    ) > "$TMP/windows-convert.out" 2> "$TMP/windows-convert.err" \
      && [[ "$(cat "$TMP/windows-convert.out")" == "$(cd "$TMP" && pwd -P)/converted-output" ]]; then
      ok "Windows absolute spelling uses the converter rather than cwd concatenation: $result"
    else bad "Windows drive conversion failed: $result"; fi
  done
  if ( cygpath() { printf '%s\n' //server/share/out; }
    [[ "$(OSTYPE=cygwin ff_review_output_host_path "$unc")" == //server/share/out ]]
  ); then ok 'Windows native UNC spelling converts without accessing a share'; else bad 'native UNC spelling was corrupted'; fi
  for result in 'C:\outside\..\victim' 'relative\..\victim'; do
    rm -f "$TMP/traversal-converter-called"
    if ( cd "$REPO" || exit 1
      cygpath() { : > "$TMP/traversal-converter-called"; printf '%s\n' "$TMP/should-not-exist"; }
      OSTYPE=msys ff_review_output_prepare "$REPO" "$result" true review
    ) > "$TMP/windows-traversal.out" 2> "$TMP/windows-traversal.err" \
      || [[ -e "$TMP/traversal-converter-called" || -e "$TMP/should-not-exist" ]]; then
      bad "Windows parent traversal reached conversion/mkdir: $result"
    else ok "Windows parent traversal refuses before converter canonicalization: $result"; fi
  done
  if ( cd "$REPO"; OSTYPE=msys ff_review_output_prepare "$REPO" 'relative\out' false review ) > "$TMP/windows-relative.out" 2> "$TMP/windows-relative.err" \
     && [[ "$(cat "$TMP/windows-relative.out")" == "$(cd "$REPO" && pwd -P)/relative/out" ]]; then
    ok 'Windows relative backslashes are normalized for the actual component walk'
  else bad 'Windows relative separator normalization failed'; fi
  mkdir -p "$TMP/windows-link-target"
  ln -s "$TMP/windows-link-target" "$REPO/windows-link"
  if ( cd "$REPO"; OSTYPE=msys ff_review_output_prepare "$REPO" 'windows-link\uncreated' false review ) > "$TMP/windows-link.out" 2> "$TMP/windows-link.err" \
      || [[ -e "$TMP/windows-link-target/uncreated" ]]; then
    bad 'Windows backslash hid an intermediate symlink from the component walk'
  else ok 'Windows relative intermediate symlink refuses before mkdir'; fi
  rm "$REPO/windows-link"
}
