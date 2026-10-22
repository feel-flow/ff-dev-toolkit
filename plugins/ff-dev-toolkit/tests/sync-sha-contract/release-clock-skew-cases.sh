# shellcheck shell=bash
# Source-only deterministic cases for the real release marker library copied by release-runtime.
release_clock_skew_case() { # <expected> <started> <pid> <host> <label>
  local expected="$1" started="$2" pid="$3" host="$4" label="$5" out rc=0
  if ! printf 'token=clock-skew\npid=%s\nhost=%s\nstarted=%s\nversion=x\n' \
    "$pid" "$host" "$started" >"$CLOCK_SKEW_MARKER/info"; then
    printf 'clock-skew fixtureを書けません\n' >&2
    return 1
  fi
  out="$(
    date() {
      if [ "$#" -eq 1 ] && [ "$1" = '+%s' ]; then printf '%s\n' "$CLOCK_SKEW_NOW"; else command date "$@"; fi
    }
    ff_release_marker_state "$CLOCK_SKEW_MARKER"
  )" || rc=$?
  if [ "$rc" -eq 0 ] && [ "$out" = "$expected" ]; then
    ok "clock-skew: $label"
  else
    bad "clock-skew: $label (rc=$rc expected=$expected out=[$out])"
  fi
  RELEASE_CLOCK_SKEW_CASES=$((RELEASE_CLOCK_SKEW_CASES + 1))
}

release_clock_skew_matrix() {
  local remote_host="${CLOCK_SKEW_HOST}.other"
  release_clock_skew_case live "$CLOCK_SKEW_NOW" "$$" "$CLOCK_SKEW_HOST" 'same host: age=0' || return 1
  release_clock_skew_case live "$((CLOCK_SKEW_NOW + 3))" "$$" "$CLOCK_SKEW_HOST" 'same host: future +3s' || return 1
  release_clock_skew_case live "$((CLOCK_SKEW_NOW + 300))" "$$" "$CLOCK_SKEW_HOST" 'same host: future +300s boundary' || return 1
  release_clock_skew_case stale "$((CLOCK_SKEW_NOW + 301))" "$$" "$CLOCK_SKEW_HOST" 'same host: future +301s' || return 1
  release_clock_skew_case live "$((CLOCK_SKEW_NOW - FF_RELEASE_IN_FLIGHT_MAX_AGE))" "$$" "$CLOCK_SKEW_HOST" 'same host: age=max boundary' || return 1
  release_clock_skew_case stale "$((CLOCK_SKEW_NOW - FF_RELEASE_IN_FLIGHT_MAX_AGE - 1))" "$$" "$CLOCK_SKEW_HOST" 'same host: age=max+1' || return 1
  release_clock_skew_case stale "$((CLOCK_SKEW_NOW + 3))" "$CLOCK_SKEW_DEAD_PID" "$CLOCK_SKEW_HOST" 'dead pid: future +3s' || return 1
  release_clock_skew_case stale "$CLOCK_SKEW_NOW" "$CLOCK_SKEW_DEAD_PID" "$CLOCK_SKEW_HOST" 'dead pid: age=0' || return 1
  release_clock_skew_case live "$CLOCK_SKEW_NOW" invalid "$remote_host" 'other host: age=0 ignores local pid' || return 1
  release_clock_skew_case live "$((CLOCK_SKEW_NOW + 3))" invalid "$remote_host" 'other host: future +3s' || return 1
  release_clock_skew_case live "$((CLOCK_SKEW_NOW + 300))" invalid "$remote_host" 'other host: future +300s boundary' || return 1
  release_clock_skew_case stale "$((CLOCK_SKEW_NOW + 301))" invalid "$remote_host" 'other host: future +301s' || return 1
  release_clock_skew_case live "$((CLOCK_SKEW_NOW - FF_RELEASE_IN_FLIGHT_MAX_AGE))" invalid "$remote_host" 'other host: age=max boundary' || return 1
  release_clock_skew_case stale "$((CLOCK_SKEW_NOW - FF_RELEASE_IN_FLIGHT_MAX_AGE - 1))" invalid "$remote_host" 'other host: age=max+1' || return 1
  release_clock_skew_case stale "$CLOCK_SKEW_NOW" '' "$CLOCK_SKEW_HOST" 'same host: missing pid' || return 1
  release_clock_skew_case stale "$CLOCK_SKEW_NOW" invalid "$CLOCK_SKEW_HOST" 'same host: invalid pid' || return 1
  release_clock_skew_case stale '' "$$" "$CLOCK_SKEW_HOST" 'missing started' || return 1
  release_clock_skew_case stale invalid "$$" "$CLOCK_SKEW_HOST" 'invalid started' || return 1
}

release_clock_skew_cases() { # <real lib> <fixture marker> <waited dead pid>
  local CLOCK_SKEW_LIB="$1" CLOCK_SKEW_MARKER="$2" CLOCK_SKEW_DEAD_PID="$3"
  local CLOCK_SKEW_NOW=1000000 CLOCK_SKEW_HOST
  local FF_RELEASE_IN_FLIGHT_MAX_AGE=600
  if [ ! -f "$CLOCK_SKEW_LIB" ] || [ ! -r "$CLOCK_SKEW_LIB" ] || [ ! -s "$CLOCK_SKEW_LIB" ]; then
    printf 'clock-skew libが無い/読めない/空です: %s\n' "$CLOCK_SKEW_LIB" >&2
    return 1
  fi
  # shellcheck source=../../../../scripts/lib/release-in-flight-functions.sh
  . "$CLOCK_SKEW_LIB" || return 1
  if [ "$(type -t ff_release_marker_state)" != function ]; then
    printf 'clock-skew判定関数がありません\n' >&2
    return 1
  fi
  CLOCK_SKEW_HOST="$(hostname)" || return 1
  mkdir -p "$CLOCK_SKEW_MARKER" || return 1
  if kill -0 "$CLOCK_SKEW_DEAD_PID" 2>/dev/null; then
    printf 'clock-skewのdead pid対照が生きています\n' >&2
    return 1
  fi
  release_clock_skew_matrix
}
