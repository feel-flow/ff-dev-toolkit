#!/usr/bin/env bash
# Optional plugin hooks respect the nearest project ASDD configuration.
# No stdin consumption here, so a hook that reads its payload after the gate
# still receives it complete. The gate does NOT drain either: every disabled
# path below ends in a caller-side exit 0, so a hook that owns a stdin payload
# must read it BEFORE calling this helper. Otherwise the writing host is left
# with an unread pipe and takes EPIPE / SIGPIPE.
asdd_hook_enabled() {
  local feature="$1" root="${PWD}" parent gate
  while :; do
    if [ -e "$root/.asdd/config.json" ] || [ -L "$root/.asdd/config.json" ] || [ -L "$root/.asdd" ]; then
      if ! command -v node >/dev/null 2>&1; then
        echo 'ff-dev-toolkit: ASDD 設定を検証できないため任意Hookを停止しました（Node.js が必要です）' >&2
        return 1
      fi
      gate="${BASH_SOURCE[0]%/*}/asdd-feature.mjs"
      node "$gate" "$root" "$feature"
      return $?
    fi
    # Do not inherit another repository's policy through a parent directory.
    [ -e "$root/.git" ] && return 0
    parent="${root%/*}"
    [ -n "$parent" ] || parent=/
    [ "$root" = "$parent" ] && return 0
    root="$parent"
  done
}
