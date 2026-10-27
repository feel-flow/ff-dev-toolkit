#!/usr/bin/env bash
# Only synthetic remotes are returned; no transport command is executed.
case "$*" in
  "remote get-url origin")
    echo "${PROBE_TEST_REMOTE:?}"
    ;;
  "ls-remote --exit-code origin HEAD")
    echo "fatal: ${PROBE_TEST_REMOTE:?} SYNTHETIC_ERROR" >&2
    exit 128
    ;;
  *) exec "${PROBE_TEST_REAL_GIT:?}" "$@" ;;
esac
