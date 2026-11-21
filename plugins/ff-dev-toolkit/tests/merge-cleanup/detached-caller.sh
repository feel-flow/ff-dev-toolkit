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
git -C "$DETACHED_TMP/main" worktree add -q "$DETACHED_TMP/finished" feature/finished
git -C "$DETACHED_TMP/main" worktree add -qb feature/other "$DETACHED_TMP/other" develop
git -C "$DETACHED_TMP/main" push -qu origin feature/other
git -C "$DETACHED_TMP/main" push -q origin --delete feature/other
printf 'local.log\n' >> "$(git -C "$DETACHED_TMP/main" rev-parse --path-format=absolute --git-path info/exclude)"
printf 'another session\n' > "$DETACHED_TMP/other/local.log"
printf 'target session\n' > "$DETACHED_TMP/finished/local.log"
test -z "$(git -C "$DETACHED_TMP/other" status --porcelain)"
test "$(git -C "$DETACHED_TMP/main" for-each-ref --format='%(upstream:track)' refs/heads/feature/other)" = '[gone]'
# stale な remote-tracking ref も作り、dry-run は仮想 prune、本実行は実 prune を経由させる。
git -C "$DETACHED_TMP/main" update-ref refs/remotes/origin/feature/other "$DETACHED_OID"
cat > "$DETACHED_TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
if [ "$1 $2" = 'pr view' ]; then
  if [ "${DETACHED_PROBE:-}" = different-pr-head ]; then
    printf '{"headRefName":"feature/other","headRefOid":"0000000000000000000000000000000000000000","state":"MERGED","baseRefName":"develop","title":"fixture","isCrossRepository":false}\n'
  else
    printf '{"headRefName":"feature/finished","headRefOid":"%s","state":"MERGED","baseRefName":"develop","title":"fixture","isCrossRepository":false}\n' "$DETACHED_OID"
  fi
elif [[ " $* " = *' --state merged '* ]]; then
  printf '[{"headRefName":"feature/finished","headRefOid":"%s","isCrossRepository":false,"baseRefName":"develop"},{"headRefName":"feature/other","headRefOid":"%s","isCrossRepository":false,"baseRefName":"develop"}]\n' "$DETACHED_OID" "$DETACHED_OID"
elif [ "${DETACHED_PROBE:-}" = open-reuse ] && [[ " $* " = *' --state open '* ]]; then
  printf '[{"headRefName":"feature/other"}]\n'
else
  printf '[]\n'
fi
GH
DETACHED_REAL_GIT="$(command -v git)"
DETACHED_REAL_FIND="$(command -v find)"
export DETACHED_REAL_GIT DETACHED_REAL_FIND DETACHED_TMP
cat > "$DETACHED_TMP/bin/git" <<'GIT'
#!/usr/bin/env bash
if [ "${DETACHED_PROBE:-}" = metadata ] && [ "$1 $2" = 'rev-parse --git-common-dir' ]; then exit 128; fi
if [ "${DETACHED_PROBE:-}" = branch ] && [ "$1 $2" = 'branch --show-current' ]; then exit 128; fi
if [ "$1 $2" = 'worktree remove' ] || [ "$1 $2 $3 $4" = '-c core.longpaths=true worktree remove' ]; then
  case "${DETACHED_PROBE:-}" in
    partial-remove)
      "$DETACHED_REAL_GIT" "$@" || exit 2
      mkdir -- "${!#}" || exit 2
      echo 'fixture: Permission denied after removing files and registration' >&2
      exit 1
      ;;
    unreadable-after)
      : > "$DETACHED_TMP/after-remove"
      echo 'fixture: Permission denied' >&2
      exit 1
      ;;
  esac
fi
exec "$DETACHED_REAL_GIT" "$@"
GIT
cat > "$DETACHED_TMP/bin/find" <<'FIND'
#!/usr/bin/env bash
if [ "${PWD##*/}" = other ] && [ "$*" = '. -mindepth 1 -print0' ]; then
  if [ "${DETACHED_PROBE:-}" = change-head ]; then
    "$DETACHED_REAL_GIT" switch --detach >/dev/null 2>&1 || exit 2
  elif [ "${DETACHED_PROBE:-}" = unreadable-after ] && [ -f "$DETACHED_TMP/after-remove" ]; then
    exit 1
  fi
fi
exec "$DETACHED_REAL_FIND" "$@"
FIND
chmod +x "$DETACHED_TMP/bin/gh" "$DETACHED_TMP/bin/git" "$DETACHED_TMP/bin/find"
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
  if ! grep -qE '対象 PR と個別指定の範囲外のため worktree を保全: .*/other$' "$DETACHED_TMP/$mode.log" \
    || [ "$(cat "$DETACHED_TMP/other/local.log")" != 'another session' ] \
    || [ "$(git -C "$DETACHED_TMP/other" branch --show-current)" != feature/other ]; then
    echo "✗ detached caller: $mode did not protect the other merged worktree" >&2
    cat "$DETACHED_TMP/$mode.log" >&2
    exit 1
  fi
done
grep -qE '削除対象の worktree: .*/finished$' "$DETACHED_TMP/dry.log"
grep -qF '新たに [gone] になるブランチを予告へ含めます（削除可否は以下で判定します）' "$DETACHED_TMP/dry.log"
test "$(git -C "$DETACHED_TMP/main" for-each-ref --format='%(upstream:track)' refs/heads/feature/other)" = '[gone]'
grep -qE 'worktree removed: .*/finished$' "$DETACHED_TMP/real.log"
test ! -e "$DETACHED_TMP/finished"
grep -E '対象 PR と個別指定の範囲外のため worktree を保全: .*/other$' "$DETACHED_TMP/dry.log" > "$DETACHED_TMP/dry-scope"
grep -E '対象 PR と個別指定の範囲外のため worktree を保全: .*/other$' "$DETACHED_TMP/real.log" > "$DETACHED_TMP/real-scope"
cmp -s "$DETACHED_TMP/dry-scope" "$DETACHED_TMP/real-scope"
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
detached_run "$DETACHED_TMP/explicit-dry.log" --dry-run --worktree-branch feature/other
grep -qE '削除対象の worktree: .*/other$' "$DETACHED_TMP/explicit-dry.log"

for probe in different-pr-head open-reuse; do
  blocked_rc=0
  DETACHED_PROBE="$probe" detached_run "$DETACHED_TMP/$probe.log" --worktree-branch feature/other || blocked_rc=$?
  if [ "$blocked_rc" -ne 2 ] || [ ! -f "$DETACHED_TMP/other/local.log" ]; then
    echo "✗ detached caller: $probe did not protect the worktree" >&2
    cat "$DETACHED_TMP/$probe.log" >&2
    exit 1
  fi
done
grep -qF '指定 PR の同一リポジトリの head と照合できないため worktree を保護' "$DETACHED_TMP/different-pr-head.log"
grep -qF 'open PR がブランチを使っているため worktree を保護' "$DETACHED_TMP/open-reuse.log"

changed_rc=0
DETACHED_PROBE=change-head detached_run "$DETACHED_TMP/changed.log" --worktree-branch feature/other || changed_rc=$?
if [ "$changed_rc" -ne 2 ] || [ ! -f "$DETACHED_TMP/other/local.log" ] \
  || [ -n "$(git -C "$DETACHED_TMP/other" branch --show-current)" ] \
  || ! grep -qF '削除直前に worktree のブランチまたは HEAD が変わったか、照合できません' "$DETACHED_TMP/changed.log"; then
  echo '✗ detached caller: a worktree that changed HEAD during inventory was not protected' >&2
  cat "$DETACHED_TMP/changed.log" >&2
  exit 1
fi
git -C "$DETACHED_TMP/other" switch -q feature/other

unreadable_rc=0
DETACHED_PROBE=unreadable-after detached_run "$DETACHED_TMP/unreadable.log" --worktree-branch feature/other || unreadable_rc=$?
if [ "$unreadable_rc" -ne 2 ] || [ ! -f "$DETACHED_TMP/after-remove" ] || [ ! -f "$DETACHED_TMP/other/local.log" ] \
  || ! grep -qF '削除後のパス一覧を取得できず、worktree 内の消失は確認できません' "$DETACHED_TMP/unreadable.log" \
  || grep -F '件消えています' "$DETACHED_TMP/unreadable.log" >/dev/null; then
  echo '✗ detached caller: unreadable worktree contents were reported as deleted' >&2
  cat "$DETACHED_TMP/unreadable.log" >&2
  exit 1
fi

partial_rc=0
DETACHED_PROBE=partial-remove detached_run "$DETACHED_TMP/partial.log" --worktree-branch feature/other || partial_rc=$?
if [ "$partial_rc" -ne 2 ] || [ ! -d "$DETACHED_TMP/other" ] || [ -e "$DETACHED_TMP/other/local.log" ] \
  || ! grep -qE 'worktree の登録は既に解除されています: .*/other$' "$DETACHED_TMP/partial.log" \
  || ! grep -qF 'worktree 内のパスが 3 件消えています' "$DETACHED_TMP/partial.log"; then
  echo '✗ detached caller: partial removal did not report missing registration and paths' >&2
  cat "$DETACHED_TMP/partial.log" >&2
  exit 1
fi
git -C "$DETACHED_TMP/main" show-ref --verify --quiet refs/heads/feature/other
printf '✓ detached caller: preserves other merged worktrees by default and reports partial removal\n'
