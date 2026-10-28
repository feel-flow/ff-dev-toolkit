#!/usr/bin/env bash
# Native OS alias control, with the mutable TMPDIR deliberately pointing elsewhere.
run_native_temp_alias_cases() {
  local area physical system_temp got=''
  case "${OSTYPE:-}" in
    darwin*) ;;
    *) ok 'native /var alias: non-Darwin host (native case not applicable)'; return 0 ;;
  esac
  system_temp="$(getconf DARWIN_USER_TEMP_DIR)" || { bad 'native user temp root is unavailable'; return 0; }
  area="$(mktemp -d "${system_temp%/}/ff-native-output.XXXXXX")" || { bad 'native alias fixture allocation failed'; return 0; }
  if [[ ! -d "$area" || -L "$area" || ! -O "$area" ]]; then
    bad 'native alias fixture is not an owned directory'; return 0
  fi
  physical="$(CDPATH='' cd -P -- "$area" && pwd -P)" || { rm -rf -- "$area"; bad 'native alias fixture cannot resolve'; return 0; }
  case "$physical" in
    /private/var/*) area="${physical#/private}" ;;
    *) rm -rf -- "$area"; bad 'native user temp is outside the standard alias'; return 0 ;;
  esac
  if ! (umask 077; mkdir "$area/alternate" "$area/victim") \
    || ! printf '%s' unchanged > "$area/victim/canary" \
    || ! ln -s "$area/victim" "$area/link"; then
    rm -rf -- "$area"; bad 'native alias fixture setup failed'; return 0
  fi
  if got="$(TMPDIR="$area/alternate" ff_review_output_prepare "$REPO" "$area/output" true review 2>/dev/null)" \
    && [[ "$got" == "$physical/output" && -f "$got/.multi-agent-output-owner" ]]; then
    ok 'native /var output stays usable when TMPDIR changes to another subtree'
  else
    bad 'native /var spelling was rejected after TMPDIR changed'
  fi
  if TMPDIR="$area/alternate" ff_review_output_prepare "$REPO" "$area/link/output" true review >/dev/null 2>&1 \
    || [[ -e "$area/victim/output" || "$(cat "$area/victim/canary")" != unchanged || ! -L "$area/link" ]]; then
    bad 'native alias normalization followed an untrusted output suffix link'
  else
    ok 'native alias recognition still rejects suffix links before changing the victim'
  fi
  rm -rf -- "$area"
}
