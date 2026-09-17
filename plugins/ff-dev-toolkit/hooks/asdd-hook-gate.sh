#!/usr/bin/env bash
# Optional plugin hooks respect the nearest project ASDD configuration.
# No stdin consumption here, so a hook that reads its payload after the gate
# still receives it complete. The gate does NOT drain either: every disabled
# path below ends in a caller-side exit 0, so a hook that owns a stdin payload
# must read it BEFORE calling this helper. Otherwise the writing host is left
# with an unread pipe and takes EPIPE / SIGPIPE.
#
# stdin contract for every hook registered in hooks/hooks.json (3 cases):
#
#   (a) Hooks that drain: read stdin with the bash builtin BEFORE this gate,
#       before any opt-out branch, and before any other early exit 0. `cat` is
#       not used: on a broken or empty PATH it fails with command-not-found and
#       the hook exits 0 with stdin unread, which is the very hole the drain
#       closes. An UNBOUNDED read (`read -r -d ''` with no `-t`) has no
#       termination guarantee of its own: it returns only at EOF, so a host that
#       leaves stdin open — an interactive terminal, or a pipe opened and never
#       written — hangs the hook until the host's own timeout kills it, and that
#       kill costs the hook its whole budget (measured: 6 s and still waiting,
#       against 0.1 s for the same hooks before the drain existed). Use the
#       unbounded form only where the host is known to close stdin; otherwise
#       take (c).
#
#   (b) Hooks that do not drain: NOT ALLOWED. Every registered hook drains,
#       including SessionStart, whose payload is small today. The alternative —
#       exempting events whose payload is "small enough" — is a denylist: it
#       admits every hook added later without anyone noticing, and it rests on a
#       host-side size the plugin does not control. Measured cost of draining a
#       small payload with the builtin read is not observable; measured cost of
#       NOT draining is the writer taking SIGPIPE once the payload passes the
#       pipe buffer (65536 bytes on Darwin 25.6). A uniform rule is also the only
#       form a static check can enforce over hooks.json (tests/lib/hook-stdin-drain.sh).
#
#   (c) Hooks that drain with a bound: allowed, and the bound MUST be derived
#       from the hook's own registered timeout (see retrospective-context.sh,
#       which splits a 5 s budget into a 2 s input stage and a 2 s discard stage).
#       A payload that does not fit inside the bound is NOT read to EOF, and the
#       writer can still take EPIPE — that residue is accepted, because removing
#       the bound does not remove it: a hook that waits past its timeout is
#       killed by the host, and the kill hands the writer the same EPIPE while
#       also costing the hook's entire budget. What the bound buys is that the
#       hook always terminates on a host that opens the pipe and never writes.
#       Bounded hooks must therefore keep the bound below their registered
#       timeout, not raise it to chase completeness — and below what is left of
#       that timeout after the hook's own work (check-skill-drift.sh spends a
#       measured 3.9 s of its 5 s budget before the payload matters, so its bound
#       is 1 s, not the 2 s the other two use).
#
#       This "derive the bound from the timeout" rule is a norm, not a checked
#       one: tests/lib/hook-stdin-drain.sh accepts any `-t <value>` without
#       comparing it against hooks.json. A bound that outgrows its timeout is
#       caught by review, not by the gate.
# Return-code contract (Issue `#1684`). "Disabled" and "cannot verify" are
# distinct outcomes, and callers that care must read the value, not just the
# truthiness:
#
#   0  enabled  — no ASDD config up to the nearest .git, or config says on
#   3  disabled — .asdd/config.json exists and features.hooks (or the named
#                 feature) is false. Intentional, silent pass-through.
#   1  cannot verify — .asdd/config.json exists but `node` is not on PATH
#   2  cannot verify — node ran but the config could not be loaded/validated
#                      (asdd-feature.mjs exit 2)
#   anything else — cannot verify (node itself failed in an unexpected way)
#
# `asdd_hook_enabled hooks || exit 0` folds 3 and the "cannot verify" values
# into one silent pass-through. That is the intended shape for fail-open hooks
# (the only thing lost is a warning). A hook with a fail-closed contract must
# read the value and treat everything other than 0 / 3 as undecidable:
#
#   asdd_hook_enabled hooks
#   asdd_rc=$?
#   case "$asdd_rc" in 0) ;; 3) exit 0 ;; *) <stop, as undecidable> ;; esac
#
# The rc 1 path (this helper) and the rc 2 path (asdd-feature.mjs) print a
# diagnostic to stderr; an unexpected node failure ("anything else") does not.
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
