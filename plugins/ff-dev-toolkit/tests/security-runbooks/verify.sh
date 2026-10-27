#!/usr/bin/env bash
# 空振り検出: Docker 節なし・world-write 変異は赤、W 未設定・mktemp/cygpath 失敗は送信前に非0。対象不在・空も赤。
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
test -s "$HERE/security.test.py"
if ! result="$(python3 "$HERE/security.test.py" 2>&1)"; then
  printf '%s\n' "$result" >&2
  exit 1
fi
printf '%s\n' "$result"
grep -Eq '^Ran [1-9][0-9]* tests? in ' <<<"$result"
# A public standalone distribution has no media plugin: count that partial skip.
if [ "$result" != "${result#*OK (skipped=1)}" ]; then
  echo "  ○ skip: separate media plugin is absent from this distribution"
else
  grep -qxF 'OK' <<<"$result"
fi
