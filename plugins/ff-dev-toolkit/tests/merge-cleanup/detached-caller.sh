#!/usr/bin/env bash
# detached linked caller の dry-run と実行を、独立した git fixture で照合する。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-$SCRIPT_DIR/../../scripts/merge-cleanup.sh}"
[ -f "$TARGET" ] || { echo '✗ detached caller: script missing' >&2; exit 1; }
# shellcheck source=../lib/git-fixture.sh
. "$SCRIPT_DIR/../lib/git-fixture.sh"
DETACHED_TMP="$(mktemp -d)"
trap 'rm -rf "$DETACHED_TMP"' EXIT
mkdir -p "$DETACHED_TMP/bin"
git init -q --bare "$DETACHED_TMP/origin.git"
git clone -q "$DETACHED_TMP/origin.git" "$DETACHED_TMP/main" 2>/dev/null
ff_git_fixture_init "$DETACHED_TMP/main"
git -C "$DETACHED_TMP/main" switch -qc develop
printf 'base\n' > "$DETACHED_TMP/main/base.txt"
git -C "$DETACHED_TMP/main" add base.txt
git -C "$DETACHED_TMP/main" commit -qm base
git -C "$DETACHED_TMP/main" push -qu origin develop
DETACHED_OID="$(git -C "$DETACHED_TMP/main" rev-parse HEAD)"
export DETACHED_OID
git -C "$DETACHED_TMP/main" branch feature/finished
git -C "$DETACHED_TMP/main" push -qu origin feature/finished
git -C "$DETACHED_TMP/main" worktree add -q --detach "$DETACHED_TMP/caller" develop
cat > "$DETACHED_TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
if [ "$1 $2" = 'pr view' ]; then
  printf '{"headRefName":"feature/finished","headRefOid":"%s","state":"MERGED","baseRefName":"develop","title":"fixture","isCrossRepository":false}\n' "$DETACHED_OID"
elif [[ " $* " = *' --state merged '* ]]; then
  printf '[{"headRefName":"feature/finished","headRefOid":"%s","isCrossRepository":false,"baseRefName":"develop"}]\n' "$DETACHED_OID"
else
  printf '[]\n'
fi
GH
DETACHED_REAL_GIT="$(command -v git)"
export DETACHED_REAL_GIT
cat > "$DETACHED_TMP/bin/git" <<'GIT'
#!/usr/bin/env bash
if [ "${DETACHED_PROBE:-}" = metadata ] && [ "$1 $2" = 'rev-parse --git-common-dir' ]; then exit 128; fi
if [ "${DETACHED_PROBE:-}" = branch ] && [ "$1 $2" = 'branch --show-current' ]; then exit 128; fi
exec "$DETACHED_REAL_GIT" "$@"
GIT
chmod +x "$DETACHED_TMP/bin/gh" "$DETACHED_TMP/bin/git"
detached_run() {
  local log="$1"
  shift
  (cd "$DETACHED_TMP/caller"
    unset FF_DEV_TOOLKIT_ROOT CLAUDE_PLUGIN_ROOT GROK_PLUGIN_ROOT
    FF_MERGE_CLEANUP_TRANSCRIPTS=off PATH="$DETACHED_TMP/bin:$PATH" bash "$TARGET" "$@" 1) > "$log" 2>&1
}
detached_check() {
  local log="$1"
  [ "$(git -C "$DETACHED_TMP/main" branch --show-current)" = develop ] \
    && [ "$(git -C "$DETACHED_TMP/main" rev-parse HEAD)" = "$DETACHED_OID" ] \
    && [ -z "$(git -C "$DETACHED_TMP/caller" branch --show-current)" ] \
    && [ "$(git -C "$DETACHED_TMP/caller" rev-parse HEAD)" = "$DETACHED_OID" ] \
    && grep -qF 'switch なし掃除モードでの未実施項目' "$log" \
    && grep -qF 'develop への復帰と pull --ff-only' "$log" \
    && ! grep -qF 'switch --detach' "$log" \
    && ! grep -qF 'detached へ退避' "$log"
}
for mode in dry real dirty; do
  if [ "$mode" = dirty ]; then
    printf 'caller scratch\n' > "$DETACHED_TMP/caller/scratch.txt"
    printf 'owner scratch\n' > "$DETACHED_TMP/main/scratch.txt"
  fi
  if [ "$mode" = dry ]; then
    detached_run "$DETACHED_TMP/$mode.log" --dry-run
    git -C "$DETACHED_TMP/main" ls-remote --exit-code origin refs/heads/feature/finished > /dev/null
  else
    detached_run "$DETACHED_TMP/$mode.log"
  fi
  if ! detached_check "$DETACHED_TMP/$mode.log"; then
    echo "✗ detached caller: $mode changed HEAD or failed to report skipped base return" >&2
    cat "$DETACHED_TMP/$mode.log" >&2
    exit 1
  fi
done
[ "$(cat "$DETACHED_TMP/caller/scratch.txt")" = 'caller scratch' ]
[ "$(cat "$DETACHED_TMP/main/scratch.txt")" = 'owner scratch' ]
if git -C "$DETACHED_TMP/main" ls-remote --exit-code origin refs/heads/feature/finished > /dev/null; then
  echo '✗ detached caller: merged remote branch was not cleaned' >&2
  exit 1
fi
for probe in metadata branch; do
  if DETACHED_PROBE="$probe" detached_run "$DETACHED_TMP/$probe.log"; then
    echo "✗ detached caller: $probe failure was accepted" >&2
    exit 1
  fi
  grep -qF 'cleanup を中断します。' "$DETACHED_TMP/$probe.log"
  [ "$(git -C "$DETACHED_TMP/main" branch --show-current)" = develop ]
  [ -z "$(git -C "$DETACHED_TMP/caller" branch --show-current)" ]
done
printf '✓ detached caller: dry-run / clean / dirty preserve both HEADs and clean merged remote\n'
