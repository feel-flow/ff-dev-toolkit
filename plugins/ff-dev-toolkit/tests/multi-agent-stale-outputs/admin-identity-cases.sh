#!/usr/bin/env bash
# Physical identity controls also cover case-insensitive filesystems without
# pretending that every Windows directory is case-insensitive.
# pipefail-inherited: verify.sh runs under set -euo pipefail.
run_admin_identity_cases() {
  local mode rc destination alias_root
  if ff_review_output_admin_identity "$REPO/.git/." "$REPO/.git" "$REPO/.git" >"$TMP/admin-same.out" 2>&1; then
    bad 'physical Git metadata identity was accepted under another spelling'
  else ok 'physical Git metadata identity rejects equivalent existing paths'; fi
  if ff_review_output_admin_identity "$REPO" "$REPO/.git" "$REPO/.git" true >"$TMP/admin-parent.out" 2>&1; then
    bad 'physical Git metadata ancestor was accepted'
  else ok 'physical Git metadata ancestors are refused'; fi
  mkdir -p "$REPO/identity-control"
  if ff_review_output_admin_identity "$REPO/identity-control" "$REPO/.git" "$REPO/.git" >"$TMP/admin-control.out" 2>&1; then
    ok 'an unrelated physical directory remains eligible'
  else bad 'physical metadata control rejected an unrelated directory'; fi
  if [[ "$REPO/.GIT" -ef "$REPO/.git" ]]; then
    for mode in ordinary fresh archive-only; do
      destination="$REPO/.GIT/objects/case-boundary-$mode"
      rc=0
      case "$mode" in
        ordinary) run_review "$TMP/admin-case-$mode.log" --output-dir "$destination" || rc=$? ;;
        fresh) run_review "$TMP/admin-case-$mode.log" --output-dir "$destination" --fresh || rc=$? ;;
        archive-only) ( cd "$REPO"; run_isolated PATH="$STUB:$PATH" bash "$MULTI_AGENT" --task review --base develop --archive-only --output-dir "$destination" ) >"$TMP/admin-case-$mode.log" 2>&1 || rc=$? ;;
      esac
      if [[ "$rc" != 0 && ! -e "$REPO/.git/objects/case-boundary-$mode" ]] \
         && grep -q 'Git administrative' "$TMP/admin-case-$mode.log"; then
        ok "filesystem case alias refuses before creating a missing Git child: $mode"
      else bad "filesystem case alias entered Git metadata: $mode"; fi
    done
    alias_root="${REPO%/*}/REPO"
    if [[ "$alias_root" -ef "$REPO" ]]; then
      if run_review "$TMP/admin-case-root.log" --output-dir "$alias_root" \
         || ! grep -q 'repository root' "$TMP/admin-case-root.log"; then
        bad 'case alias of the repository root was accepted/misclassified'
      else ok 'case alias of the repository root refuses by physical identity'; fi
    fi
  else
    echo '  ○ case-alias branch unavailable on this filesystem; physical identity controls above ran'
    if ff_review_output_prepare "$REPO" "$REPO/.GIT/valid-distinct-output" false review >"$TMP/admin-distinct.out" 2>&1; then
      ok 'a physically distinct uppercase directory is not rejected by case folding'
    else bad 'a physically distinct uppercase directory was rejected'; fi
  fi
}
