#!/usr/bin/env bash
# Test-only private before/after oracle; never shipped as the live detector.
mbcs_scan() {
  local captured=""
  IFS= read -r -d '' captured || true
  printf '%s\000' "$captured" >> "${FF_TEST_SHELL_CAPTURE:?private fixture path required}"
  printf '%s' "$captured" | ff_test_original_mbcs_scan
}
