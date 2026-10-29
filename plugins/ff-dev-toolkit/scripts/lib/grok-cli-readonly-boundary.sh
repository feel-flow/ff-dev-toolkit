#!/usr/bin/env bash
# Source-only; Bash 3.2 + awk. Never changes the caller's shell options.

ff_grok_physical_path() (
  local path="$1" suffix="" leaf=""
  [[ "$path" == /* && ! "$path" =~ [[:cntrl:]] ]] || exit 1
  while [[ "$path" != / && "$path" == */ ]]; do path="${path%/}"; done
  while [[ ! -d "$path" ]]; do
    [[ ! -e "$path" && ! -L "$path" ]] || exit 1
    leaf="${path##*/}"
    case "$leaf" in ''|.|..) exit 1 ;; esac
    suffix="/$leaf$suffix"
    path="${path%/*}"; [[ -n "$path" ]] || path=/
  done
  CDPATH= cd -P -- "$path" 2>/dev/null || exit 1
  path="$(pwd -P)" || exit 1
  if [[ "$path" == / && -z "$suffix" ]]; then printf '/\n';
  else printf '%s%s\n' "${path%/}" "$suffix"; fi
)

ff_grok_grant_overlaps() {
  local tree="$1" grant="$2"
  [[ -n "$tree" && -n "$grant" ]] || return 0
  [[ "$tree" != / && "$grant" != / ]] || return 0
  case "$tree/" in "$grant/"*) return 0 ;; esac
  case "$grant/" in "$tree/"*) return 0 ;; esac
  return 1
}

# Check known vendor exceptions before even an inspect process is started.
ff_grok_known_roots_safe() {
  local tree="" root="" physical="" grok_home="$1"
  tree="$(ff_grok_physical_path "$PWD")" || return 2
  [[ -n "$grok_home" ]] || return 2
  for root in /tmp /var/tmp "${TMPDIR:-/tmp}" "$grok_home"; do
    physical="$(ff_grok_physical_path "$root")" || return 2
    ff_grok_grant_overlaps "$tree" "$physical" && return 1
  done
  if [[ "${OSTYPE:-}" == darwin* ]]; then
    for root in /private/tmp /private/var/tmp /private/var/folders; do
      [[ -d "$root" ]] || continue
      physical="$(ff_grok_physical_path "$root")" || return 2
      ff_grok_grant_overlaps "$tree" "$physical" && return 1
    done
  fi
  return 0
}

# stdin = this launch's JSONL delta; stdout = verdict. Unknown shapes fail closed.
# JSON escapes for control characters / Unicode escapes are deliberately unknown,
# never interpreted as harmless pathname bytes. Vendor UTF-8 paths remain valid.
ff_grok_readonly_verdict() {
  local profile="$1" tree="$2" records="" grant="" physical=""
  records="$(FF_GROK_PROFILE="$profile" FF_GROK_TREE="$tree" FF_GROK_CHECK_GRANTS="${3:-true}" LC_ALL=C awk '
    function string( c, out, esc) {
      if (substr(rest,1,1) != "\"") { bad=1; return "" }
      rest=substr(rest,2); out=""
      while (length(rest)) {
        c=substr(rest,1,1); rest=substr(rest,2)
        if (c == "\"") return out
        if (c == "\\") {
          esc=substr(rest,1,1); rest=substr(rest,2)
          if (esc != "\\" && esc != "\"" && esc != "/") { bad=1; return "" }
          c=esc
        }
        if (c ~ /[[:cntrl:]]/) { bad=1; return "" }
        out=out c
      }
      bad=1; return ""
    }
    function field(key) {
      if (types[key] != "string") { bad=1; return "" }
      return values[key]
    }
    function json_value(depth, c, key, start) {
      if (depth > 16) { bad=1; return }
      sub(/^[ \t]*/,"",rest); c=substr(rest,1,1)
      if (c == "\"") { value=string(); kind="string"; return }
      if (c == "{" || c == "[") {
        rest=substr(rest,2); sub(/^[ \t]*/,"",rest)
        if (substr(rest,1,1) == (c == "{" ? "}" : "]")) {
          rest=substr(rest,2); kind=(c == "{" ? "object" : "array"); value=""; return
        }
        while (!bad) {
          if (c == "{") {
            key=string(); sub(/^[ \t]*/,"",rest)
            if (bad || substr(rest,1,1) != ":") { bad=1; return }
            rest=substr(rest,2); sub(/^[ \t]*/,"",rest); start=rest
          }
          json_value(depth+1)
          if (c == "{" && depth == 0) {
            if (key in types) { bad=1; return }
            values[key]=value; types[key]=kind
            if (key == "read_write_paths") grant_source=start
          }
          sub(/^[ \t]*/,"",rest)
          if (substr(rest,1,1) == (c == "{" ? "}" : "]")) {
            rest=substr(rest,2); kind=(c == "{" ? "object" : "array"); value=""; return
          }
          if (substr(rest,1,1) != ",") { bad=1; return }
          rest=substr(rest,2); sub(/^[ \t]*/,"",rest)
        }
        return
      }
      if (match(rest,/^(true|false|null)/)) {
        value=substr(rest,1,RLENGTH); rest=substr(rest,RLENGTH+1)
        kind=(value == "null" ? "null" : "boolean"); return
      }
      if (match(rest,/^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?/)) {
        value=substr(rest,1,RLENGTH); rest=substr(rest,RLENGTH+1); kind="number"; return
      }
      bad=1
    }
    /"event_type"[ \t]*:[ \t]*"(ApplyFailed|BypassGranted)"/ { invalid=1 }
    /"event_type"[ \t]*:[ \t]*"ProfileApplied"/ {
      for (key in values) delete values[key]
      for (key in types) delete types[key]
      bad=0; grant_source=""; rest=$0; json_value(0)
      sub(/^[ \t]*/,"",rest)
      if (bad || length(rest) || kind != "object" || field("event_type") != "ProfileApplied") { invalid=1; next }
      workspace=field("workspace")
      if (bad) { invalid=1; next }
      if (workspace != ENVIRON["FF_GROK_TREE"]) next
      seen++
      if (field("profile") != ENVIRON["FF_GROK_PROFILE"] ||
          types["enforced"] != "boolean" || values["enforced"] != "true") { invalid=1; next }
      if (ENVIRON["FF_GROK_CHECK_GRANTS"] != "true") next
      if (types["read_write_paths"] != "array") { grants_unknown=1; next }
      rest=substr(grant_source,2); count=0
      sub(/^[ \t]*/,"",rest)
      while (substr(rest,1,1) != "]" && length(rest)) {
        path=string(); if (bad || path !~ /^\//) { bad=1; break }
        print path; count++; sub(/^[ \t]*/,"",rest)
        if (substr(rest,1,1) == "]") break
        if (substr(rest,1,1) != ",") { bad=1; break }
        rest=substr(rest,2); sub(/^[ \t]*/,"",rest)
        if (substr(rest,1,1) == "]") { bad=1; break }
      }
      if (bad || substr(rest,1,1) != "]" || count == 0) grants_unknown=1
    }
    END {
      if (!seen || invalid) print "@unconfirmed"
      else if (grants_unknown) print "@grants-unknown"
      else print "@confirmed"
    }
  ')" || { printf '%s\n' awk-failed; return; }
  case "$records" in
    @confirmed|*$'\n@confirmed') ;;
    @grants-unknown|*$'\n@grants-unknown') printf '%s\n' grants-unknown; return ;;
    *) printf '%s\n' unconfirmed; return ;;
  esac
  while IFS= read -r grant; do
    [[ "$grant" != @confirmed ]] || continue
    physical="$(ff_grok_physical_path "$grant")" || { printf '%s\n' grants-unknown; return; }
    if ff_grok_grant_overlaps "$tree" "$physical"; then
      printf '%s\n' write-granted; return
    fi
  done < <(printf '%s\n' "$records")
  printf '%s\n' confirmed
}
