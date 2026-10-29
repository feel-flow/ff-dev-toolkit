#!/usr/bin/env bash
# Issue `#2514`: a pre-boundary (`#2429`) unmarked default root, and sticky shared temp ancestors.
run_legacy_root_cases() {
  local before area got legacy_count

  # Sticky bit: BSD stat %Lp dropped it, so macOS refused every /private/tmp/... output.
  mkdir -p "$TMP/sticky-probe"
  chmod 1777 "$TMP/sticky-probe"
  if [[ "$(ff_review_output_stat "$TMP/sticky-probe" mode)" == 1777 \
        && "$(ff_review_output_stat "$REPO" mode)" != 0* ]]; then
    ok 'mode stat keeps the sticky bit and one spelling on GNU and BSD stat'
  else
    bad "mode stat lost the sticky bit or kept a leading zero: $(ff_review_output_stat "$TMP/sticky-probe" mode)"
  fi
  chmod 700 "$TMP/sticky-probe"

  # The reported case on the real host temp root (/tmp is sticky on Linux and macOS).
  if [[ ! -d /tmp || ! -k /tmp || ! -w /tmp ]]; then
    ok 'host /tmp is not a writable sticky directory; real-host sticky case not applicable'
    ok 'host /tmp is not a writable sticky directory; non-sticky control not applicable'
  elif area="$(mktemp -d /tmp/ff-sticky-output.XXXXXX 2>/dev/null)" && [[ -d "$area" && -O "$area" ]]; then
    if got="$(ff_review_output_prepare "$REPO" "$area/output" true review 2>"$TMP/sticky-host.err")" \
       && [[ -f "$got/.multi-agent-output-owner" ]]; then
      ok 'explicit output under a private dir in sticky /tmp is accepted'
    else
      bad "explicit output under sticky /tmp was refused: $(cat "$TMP/sticky-host.err")"
    fi
    # Control: the same chain without the sticky bit must still be refused.
    if (
      ff_review_output_stat() {
        local result gnu bsd
        case "$2" in mode) gnu=%a; bsd=%Lp ;; uid) gnu=%u; bsd=%u ;; *) return 1 ;; esac
        result="$(stat -c "$gnu" "$1" 2>/dev/null)" || result="$(stat -f "$bsd" "$1" 2>/dev/null)" || return 1
        case "$result" in ''|*[!0-9]*) return 1 ;; esac
        [[ "$2" != mode ]] || result="$(printf '%o' "$((8#$result & 8#777))")"
        printf '%s\n' "$result"
      }
      ff_review_output_prepare "$REPO" "$area/control" true review
    ) >"$TMP/sticky-control.log" 2>&1 || [[ -e "$area/control" ]] \
       || ! grep -q 'ancestor is writable by another user' "$TMP/sticky-control.log"; then
      bad 'writable shared ancestor without the sticky bit was accepted'
    else
      ok 'writable shared ancestor without the sticky bit is still refused'
    fi
    rm -rf -- "$area"
  else
    bad 'sticky /tmp fixture allocation failed'
  fi

  # Pre-boundary default root: unmarked, mode 755, holding an old result.
  rm -rf "$OUT" "$REPO"/.review-results.legacy-*
  mkdir "$OUT"; chmod 755 "$OUT"
  printf 'LEGACY-RESULT\n' > "$OUT/legacy.md"
  if ff_review_output_prepare "$REPO" "$OUT" false review >"$TMP/legacy-hook.log" 2>&1 \
     || [[ "$(cat "$OUT/legacy.md")" != LEGACY-RESULT || -e "$OUT/.multi-agent-output-owner" ]] \
     || ! grep -q 'mv -- ' "$TMP/legacy-hook.log" || ! grep -q -- '--output-dir "$(mktemp -d)/output"' "$TMP/legacy-hook.log"; then
    bad 'standalone prepare (hook path) moved a legacy root or gave no pasteable next step'
  else
    ok 'standalone prepare still refuses a legacy root in place and prints pasteable next steps'
  fi

  if run_review "$TMP/legacy-explicit.log" --output-dir "$OUT" \
     || [[ "$(cat "$OUT/legacy.md")" != LEGACY-RESULT || -e "$OUT/.multi-agent-output-owner" ]] \
     || ! grep -q -- '--output-dir "$(mktemp -d)/output"' "$TMP/legacy-explicit.log"; then
    bad 'explicit --output-dir at a legacy root was moved or adopted'
  else
    ok 'explicit --output-dir at a legacy root is refused without moving it'
  fi

  before="$(count_invocations)"
  if run_review "$TMP/legacy-default.log" \
     && [[ "$(count_invocations)" != "$before" ]] \
     && [[ "$(ff_review_output_stat "$OUT" mode)" == 700 && -f "$OUT/.multi-agent-output-owner" ]] \
     && got="$(find "$OUT" -maxdepth 1 -name '.prev-*-legacy' -type d)" && [[ -n "$got" ]] \
     && [[ "$(cat "$got/legacy.md")" == LEGACY-RESULT && ! -e "$got/.multi-agent-run.lock" ]] \
     && grep -q 'moved it unread' "$TMP/legacy-default.log"; then
    ok 'implicit default legacy root is moved unread under the new private root and the run proceeds'
  else
    bad "implicit default legacy root was not recovered: $(tail -5 "$TMP/legacy-default.log")"
  fi
  legacy_count="$(find "$REPO" -maxdepth 1 -name '.review-results.legacy-*' | wc -l | tr -d ' ')"
  if [[ "$legacy_count" == 0 ]]; then ok 'no set-aside sibling is left beside the default root'
  else bad "set-aside sibling left beside the default root: ${legacy_count}"; fi

  # A marked root that later lost its private mode is not legacy: keep refusing in place.
  chmod 755 "$OUT"
  before="$(count_invocations)"
  if run_review "$TMP/legacy-marked.log" || [[ "$(count_invocations)" != "$before" ]] \
     || [[ ! -f "$OUT/.multi-agent-output-owner" ]] || ! grep -q 'chmod 700 ' "$TMP/legacy-marked.log" \
     || [[ -n "$(find "$REPO" -maxdepth 1 -name '.review-results.legacy-*')" ]]; then
    bad 'marked root with a widened mode was moved or accepted'
  else
    ok 'marked root with a widened mode is refused in place (no recovery)'
  fi
  chmod 700 "$OUT"

  # Exclusions, driven through the orchestrator entry (prepare_output_namespace).
  legacy_ns() { # <log> <output>
    ( REPO_ROOT="$REPO"; TASK_TYPE=review; OUTPUT_DIR_EXPLICIT=false; OUTPUT_DIR="$2"
      get_default_output_dir() { echo "${REPO_ROOT}/.review-results"; }
      prepare_output_namespace ) >"$1" 2>&1
  }
  legacy_plant() { rm -rf "$1"; mkdir "$1"; chmod 755 "$1"; printf 'LEGACY-RESULT\n' > "$1/legacy.md"; }
  no_sibling() { [[ -z "$(find "$REPO" -maxdepth 1 -name "${1##*/}.legacy-*")" ]]; }

  # A project-config output_dir is implicit too, but it is not the built-in default.
  if legacy_ns "$TMP/legacy-git.log" "$REPO/.git" || [[ ! -f "$REPO/.git/HEAD" ]] || ! no_sibling "$REPO/.git"; then
    bad 'config output_dir .git was moved before Git-admin authorization'
  else ok 'config output_dir .git is refused in place (never set aside)'; fi
  legacy_plant "$REPO/reviews"
  if [[ -n "$(ff_review_output_set_aside_legacy "$REPO" "$REPO/reviews" 2>/dev/null)" ]] \
     || [[ "$(cat "$REPO/reviews/legacy.md")" != LEGACY-RESULT ]] || ! no_sibling "$REPO/reviews"; then
    bad 'set-aside accepted a name outside the built-in defaults'
  else ok 'set-aside itself only accepts the built-in default names'; fi
  rm -rf "$REPO/reviews"
  # A config output_dir that happens to use another task's default name is still config.
  legacy_plant "$REPO/.explore-results"
  if legacy_ns "$TMP/legacy-config.log" "$REPO/.explore-results" \
     || [[ "$(cat "$REPO/.explore-results/legacy.md")" != LEGACY-RESULT ]] \
     || [[ -e "$REPO/.explore-results/.multi-agent-output-owner" ]] || ! no_sibling "$REPO/.explore-results"; then
    bad 'project-config output_dir was set aside like the built-in default'
  else ok 'project-config output_dir is refused in place, not set aside'; fi
  rm -rf "$REPO/.explore-results"
  # A project config naming the default path itself is still a project value.
  legacy_plant "$OUT"
  if ( REPO_ROOT="$REPO"; TASK_TYPE=review; OUTPUT_DIR_EXPLICIT=false; OUTPUT_DIR="$OUT"; OUTPUT_DIR_SOURCE="project override"
       get_default_output_dir() { echo "${REPO_ROOT}/.review-results"; }
       prepare_output_namespace ) >"$TMP/legacy-config-default.log" 2>&1 \
     || [[ "$(cat "$OUT/legacy.md")" != LEGACY-RESULT || -e "$OUT/.multi-agent-output-owner" ]] || ! no_sibling "$OUT"; then
    bad 'project config naming the default path was set aside'
  else ok 'project config naming the default path is refused in place'; fi

  # An older run may still be writing: its lock name blocks the move.
  legacy_plant "$OUT"; mkdir "$OUT/.multi-agent-run.lock"
  if legacy_ns "$TMP/legacy-lock.log" "$OUT" || [[ ! -d "$OUT/.multi-agent-run.lock" ]] || ! no_sibling "$OUT"; then
    bad 'legacy root with a live-run lock name was moved'
  else ok 'legacy root holding an older run lock is refused in place'; fi

  # prepare failing after the set-aside puts the root back under its original (ignored) name.
  legacy_plant "$OUT"
  if ( REPO_ROOT="$REPO"; TASK_TYPE=review; OUTPUT_DIR_EXPLICIT=false; OUTPUT_DIR="$OUT"
       get_default_output_dir() { echo "${REPO_ROOT}/.review-results"; }
       ff_review_output_prepare() { return 1; }
       prepare_output_namespace ) >"$TMP/legacy-restore.log" 2>&1 \
     || [[ "$(cat "$OUT/legacy.md")" != LEGACY-RESULT ]] || ! no_sibling "$OUT" \
     || ! grep -q 'put back unread' "$TMP/legacy-restore.log" || [[ -e "$OUT/.multi-agent-run.lock" ]]; then
    bad 'failed prepare left the legacy root under the set-aside sibling'
  else ok 'failed prepare restores the legacy root to its original name'; fi

  # Tracked content stays where Git expects it.
  legacy_plant "$OUT"
  git -C "$REPO" add -f .review-results/legacy.md
  if legacy_ns "$TMP/legacy-tracked.log" "$OUT" || [[ "$(cat "$OUT/legacy.md")" != LEGACY-RESULT ]] || ! no_sibling "$OUT" \
     || [[ -n "$(grep -F 'put back unread' "$TMP/legacy-tracked.log")" ]]; then
    bad 'legacy root with tracked content was moved'
  else ok 'legacy root with tracked content is refused in place'; fi
  git -C "$REPO" rm -q --cached .review-results/legacy.md
}
