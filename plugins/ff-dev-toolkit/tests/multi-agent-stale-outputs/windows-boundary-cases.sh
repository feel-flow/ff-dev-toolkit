#!/usr/bin/env bash
# Host spelling tests use a stub converter and synthetic local paths. They do
# not verify real drive mounts or UNC access. Real Windows ACLs are checked only by
# the last case of run_windows_acl_cases, and only on Windows.
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
  # These cases check spellings only. The synthetic msys host has no ACL helper,
  # so it accepts every directory; run_windows_acl_cases checks the ACL dispatch.
  ff_knowledge_windows_acl() { return 0; }
  ff_knowledge_storage() { return 0; }
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
  unset -f ff_knowledge_windows_acl ff_knowledge_storage
}

# Issue `#2478`: on Windows the output boundary takes its verdict from the ACL helper of
# the knowledge read boundary, never from the POSIX mode that Git Bash reports as 755.
run_windows_acl_cases() {
  local dir="$TMP/windows-acl" calls="$TMP/windows-acl.calls" repo_real rc
  mkdir -p "$dir/root" "$dir/sub"
  chmod 755 "$dir/root" "$dir/sub"
  # Without the helper (the review-lane hook never loads it) nothing is trusted.
  if ( unset -f ff_knowledge_windows_acl ff_knowledge_storage
       OSTYPE=msys ff_review_output_private "$dir/root" true ) 2> "$TMP/windows-acl-unloaded.err"; then
    bad 'Windows private check trusted the POSIX mode without the ACL helper'
  elif grep -qF 'the ACL helper is not loaded' "$TMP/windows-acl-unloaded.err"; then
    ok 'Windows private check refuses, naming the missing ACL helper, when it is not loaded'
  else bad 'Windows private check refused without naming the missing ACL helper'; fi
  : > "$calls"
  if ( ff_knowledge_windows_acl() { printf '%s %s\n' "$1" "$2" >> "$calls"; return 0; }
       OSTYPE=msys ff_review_output_private "$dir/root" true && OSTYPE=msys ff_review_output_private "$dir/sub"
     ) && [[ "$(cat "$calls")" == "private ${dir}/root"$'\n'"inspect ${dir}/sub" ]]; then
    ok 'Windows root asks the strict private ACL check and a subdirectory the no-write check; the 755 mode is not used'
  else bad "Windows private check did not dispatch to the ACL helper as expected: $(tr '\n' ';' < "$calls")"; fi
  # A refusal that names a place is an ACL verdict; one that names nothing means the
  # helper gave no verdict, and must not send the user looking for access entries.
  if ( ff_knowledge_windows_acl() { printf 'knowledge-read: read-unverifiable\nknowledge-read: 止めた場所: C:/x — stub\n' >&2; return 2; }
       OSTYPE=msys ff_review_output_private "$dir/root" true ) 2> "$TMP/windows-acl-refused.err"; then
    bad 'Windows private check accepted a directory the ACL helper refused'
  elif grep -qF 'does not keep this directory private (named above)' "$TMP/windows-acl-refused.err" \
       && grep -qF '止めた場所: C:/x' "$TMP/windows-acl-refused.err"; then
    ok 'Windows private check refuses what the ACL helper refuses, keeping the named place'
  else bad 'Windows private refusal did not name the ACL verdict'; fi
  if ( ff_knowledge_windows_acl() { printf 'knowledge-read: read-unverifiable\n' >&2; return 2; }
       OSTYPE=msys ff_review_output_private "$dir/root" true ) 2> "$TMP/windows-acl-silent.err"; then
    bad 'Windows private check accepted a directory the ACL helper could not judge'
  elif grep -qF 'could not be verified' "$TMP/windows-acl-silent.err" \
       && ! grep -qF 'does not keep this directory private' "$TMP/windows-acl-silent.err"; then
    ok 'Windows private check says the ACL could not be verified when the helper names no place'
  else bad 'Windows private check reported an ACL verdict the helper never gave'; fi
  : > "$calls"
  if ( ff_knowledge_storage() { printf 'storage %s %s\n' "$1" "$2" >> "$calls"; printf 'knowledge-read: 止めた場所: C:/y — stub\n' >&2; return 2; }
       OSTYPE=msys ff_review_output_ancestors "$dir/root/leaf" ) 2> "$TMP/windows-acl-ancestors.err"; then
    bad 'Windows ancestor check accepted a chain the ACL helper refused'
  elif grep -qxF "storage ${dir}/root dir" "$calls" && grep -qF 'an ancestor is not owned' "$TMP/windows-acl-ancestors.err"; then
    ok 'Windows ancestors are checked from the parent up by the knowledge read boundary'
  else bad "Windows ancestor check did not ask the knowledge read boundary for the parent chain: $(tr '\n' ';' < "$calls")"; fi
  : > "$calls"
  repo_real="$(cd "$REPO" && pwd -P)"
  if ( cd "$REPO"
       ff_knowledge_windows_acl() { printf '%s %s\n' "$1" "$2" >> "$calls"; return 0; }
       ff_knowledge_storage() { return 0; }
       chmod() { printf 'chmod %s\n' "$*" >> "$calls"; command chmod "$@"; }
       OSTYPE=msys ff_review_output_prepare "$REPO" windows-acl-out false review
     ) > "$TMP/windows-acl-prepare.out" 2> "$TMP/windows-acl-prepare.err" \
     && grep -qxF "private-staging ${repo_real}/windows-acl-out" "$calls" && ! grep -q '^chmod ' "$calls"; then
    ok 'Windows makes a new output root private through the ACL helper (private-staging), not chmod 700'
  else bad "Windows new output root was not made private through the ACL helper: $(tr '\n' ';' < "$calls")"; fi
  : > "$calls"
  ( ff_knowledge_windows_acl() { printf 'called\n' >> "$calls"; return 0; }
    ff_knowledge_storage() { printf 'called\n' >> "$calls"; return 0; }
    OSTYPE=linux-gnu ff_review_output_private "$dir/sub" || :
    OSTYPE=linux-gnu ff_review_output_ancestors "$dir/sub/leaf" || : ) > /dev/null 2>&1
  if [[ ! -s "$calls" ]]; then ok 'POSIX keeps the mode check and never consults the Windows ACL helper'
  else bad 'POSIX consulted the Windows ACL helper'; fi
  case "$(uname -s 2>/dev/null)" in
    MSYS* | MINGW* | CYGWIN*) ;;
    *) echo '  ○ skip: 実 ACL helper の回は Windows の Git Bash でだけ成立する検査のため未実行（上の振り分けは stub で確かめた）'; return 0 ;;
  esac
  # Real helper: a private-staged root passes; a granted read for Users fails the
  # strict root check (named as access, not write) and still passes the no-write
  # check that non-root directories get.
  rc=0
  ( . "$PLUGIN_ROOT/scripts/lib/knowledge-read-boundary.sh"
    trap ff_knowledge_acl_service_stop EXIT
    [[ "${ff_knowledge_acl_state:-}" == on ]] || exit 3
    mkdir "$dir/real"
    ff_review_output_windows_acl private-staging "$dir/real" || exit 4
    ff_review_output_private "$dir/real" true || exit 5
    MSYS2_ARG_CONV_EXCL='*' icacls "$(cygpath -w "$dir/real")" /grant '*S-1-5-32-545:(R)' > /dev/null || exit 6
    if ff_review_output_private "$dir/real" true; then exit 7; fi
    ff_review_output_private "$dir/real" || exit 8
  ) > "$TMP/windows-acl-real.log" 2>&1 || rc=$?
  if [[ "$rc" -eq 0 ]] && grep -qF 'アクセスできる（S-1-5-32-545）' "$TMP/windows-acl-real.log"; then
    ok 'real Windows ACL: a private-staged root passes, a read grant for Users is refused as access by SID, the non-root no-write check allows reads'
  else bad "real Windows ACL case failed (rc=${rc}): $(tr '\n' ';' < "$TMP/windows-acl-real.log")"; fi
}
