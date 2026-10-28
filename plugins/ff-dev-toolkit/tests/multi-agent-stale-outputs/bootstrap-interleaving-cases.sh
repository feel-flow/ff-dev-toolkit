#!/usr/bin/env bash
# Deterministically exercise a peer finishing marker + lane creation after this
# invocation observed an empty root but before its initialization rescan.
# pipefail-inherited: verify.sh runs under set -euo pipefail.
run_bootstrap_interleaving_cases() {
  local root
  root="$(cd "$TMP" && pwd -P)/bootstrap-window"
  if (
    injected=false
    ff_review_output_private() {
      [[ -d "$1" && ! -L "$1" && -O "$1" ]] || return 1
      [[ "$(ff_review_output_stat "$1" mode)" == 700 ]] || return 1
      if [[ "$injected" == false && "$1" == "$root" ]]; then
        injected=true
        # A separate invocation uses the real helper implementation; only the
        # observer's private-check timing is controlled by this fixture.
        ( . "$PLUGIN_ROOT/scripts/lib/multi-agent-boundary.sh"
          ff_review_output_prepare "$REPO" "$root" true review >/dev/null \
            && mkdir -m 700 "$root/.review-in-flight.d"
        ) || return 1
      fi
    }
    ff_review_output_prepare "$REPO" "$root" true review
  ) > "$TMP/bootstrap-window.out" 2> "$TMP/bootstrap-window.err" \
     && [[ -d "$root/.review-in-flight.d" && -f "$root/.multi-agent-output-owner" ]]; then
    ok 'empty-root observer accepts a peer completed marker and lane directory'
  else bad 'empty-root observer lost a concurrent first-use lane after valid initialization'; fi
}
