#!/usr/bin/env bash
# worktree-agent-* の掃除だけを独立した git fixture で実測する。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-$SCRIPT_DIR/../../scripts/merge-cleanup.sh}"
[ -f "$TARGET" ] || { echo '✗ agent branches: script missing' >&2; exit 1; }
# shellcheck source=../lib/git-fixture.sh
. "$SCRIPT_DIR/../lib/git-fixture.sh"
TMP_AGENT="$(mktemp -d)"
trap 'rm -rf "$TMP_AGENT"' EXIT
REAL_GIT_AGENT="$(command -v git)"
mkdir -p "$TMP_AGENT/bin"
git init -q --bare "$TMP_AGENT/origin.git"
git clone -q "$TMP_AGENT/origin.git" "$TMP_AGENT/repo" 2>/dev/null
ff_git_fixture_init "$TMP_AGENT/repo"
git -C "$TMP_AGENT/repo" switch -qc develop
printf 'base\n' > "$TMP_AGENT/repo/base.txt"
git -C "$TMP_AGENT/repo" add base.txt
git -C "$TMP_AGENT/repo" commit -qm base
git -C "$TMP_AGENT/repo" push -qu origin develop
BASE_OID="$(git -C "$TMP_AGENT/repo" rev-parse HEAD)"
# --no-switch mode の HEAD が base 祖先判定へ混ざらないよう、固有 commit を持たせる。
git -C "$TMP_AGENT/repo" switch -qc other-session
printf 'other\n' > "$TMP_AGENT/repo/other.txt"
git -C "$TMP_AGENT/repo" add other.txt
git -C "$TMP_AGENT/repo" commit -qm other
OTHER_OID="$(git -C "$TMP_AGENT/repo" rev-parse HEAD)"
MERGED_OID="$(printf 'squashed\n' | git -C "$TMP_AGENT/repo" commit-tree "${BASE_OID}^{tree}" -p "$BASE_OID")"
WRONG_BASE_OID="$(printf 'wrong base\n' | git -C "$TMP_AGENT/repo" commit-tree "${BASE_OID}^{tree}" -p "$BASE_OID")"
FORK_OID="$(printf 'fork\n' | git -C "$TMP_AGENT/repo" commit-tree "${BASE_OID}^{tree}" -p "$BASE_OID")"
export BASE_OID MERGED_OID WRONG_BASE_OID FORK_OID
cat > "$TMP_AGENT/bin/gh" <<'GH'
#!/usr/bin/env bash
if [ "$1 $2" = 'pr view' ]; then
  printf '{"headRefName":"feature/finished","headRefOid":"%s","state":"MERGED","baseRefName":"develop","title":"fixture","isCrossRepository":false}\n' "$BASE_OID"
elif [[ " $* " = *' --state merged '* ]]; then
  printf '[{"headRefName":"feature/renamed","headRefOid":"%s","isCrossRepository":false,"baseRefName":"develop"},{"headRefName":"feature/elsewhere","headRefOid":"%s","isCrossRepository":false,"baseRefName":"main"},{"headRefName":"feature/fork","headRefOid":"%s","isCrossRepository":true,"baseRefName":"develop"}]\n' "$MERGED_OID" "$WRONG_BASE_OID" "$FORK_OID"
else
  printf '[]\n'
fi
GH
cat > "$TMP_AGENT/bin/git" <<'GIT'
#!/usr/bin/env bash
if [ "${AGENT_PROBE_MODE:-}" = wt-fail ] && [ "$1 $2" = 'worktree list' ]; then exit 128; fi
if [ "${AGENT_PROBE_MODE:-}" = wt-empty ] && [ "$1 $2" = 'worktree list' ]; then exit 0; fi
if [ "${AGENT_PROBE_MODE:-}" = wt-warning ] && [ "$1 $2" = 'worktree list' ]; then
  "$REAL_GIT_AGENT" "$@"
  echo 'warning: incomplete worktree inventory' >&2
  exit 0
fi
if [ "${AGENT_PROBE_MODE:-}" = remote-fail ] && [ "$1" = ls-remote ] && [[ "$*" = *worktree-agent-* ]]; then exit 128; fi
exec "$REAL_GIT_AGENT" "$@"
GIT
chmod +x "$TMP_AGENT/bin/gh" "$TMP_AGENT/bin/git"
export REAL_GIT_AGENT
AGENT_PASS=0
agent_assert() {
  local message="$1"
  shift
  if "$@"; then AGENT_PASS=$((AGENT_PASS + 1)); else echo "✗ agent branches: $message" >&2; exit 1; fi
}
agent_exists() { git -C "$TMP_AGENT/repo" show-ref --verify --quiet "refs/heads/$1"; }
agent_absent() { ! agent_exists "$1"; }
make_agent_ref() { git -C "$TMP_AGENT/repo" branch "$1" "${2:-$BASE_OID}"; }
make_agent_ref worktree-agent-ancestor
make_agent_ref worktree-agent-merged "$MERGED_OID"
make_agent_ref worktree-agent-worktree
make_agent_ref worktree-agent-remote
make_agent_ref worktree-agent-unmerged "$OTHER_OID"
make_agent_ref worktree-agent-wrong-base "$WRONG_BASE_OID"
make_agent_ref worktree-agent-fork "$FORK_OID"
make_agent_ref worktree-agent-protected
make_agent_ref ordinary-orphan
git -C "$TMP_AGENT/repo" push -q origin worktree-agent-remote
git -C "$TMP_AGENT/repo" worktree add -q "$TMP_AGENT/live worktree" worktree-agent-worktree
git -C "$TMP_AGENT/repo" worktree lock --reason 'claude agent worktree' "$TMP_AGENT/live worktree"
run_agent_cleanup() {
  local log="$1"
  shift
  (cd "$TMP_AGENT/repo"
    # fixture は直接起動経路を検査し、consumer host のhandoffを継承しない。
    unset FF_DEV_TOOLKIT_ROOT CLAUDE_PLUGIN_ROOT GROK_PLUGIN_ROOT
    FF_MERGE_CLEANUP_TRANSCRIPTS=off FF_MERGE_CLEANUP_PROTECT_BRANCHES=worktree-agent-protected \
      PATH="$TMP_AGENT/bin:$PATH" bash "$TARGET" "$@" 1) > "$log" 2>&1
}
git -C "$TMP_AGENT/repo" show-ref > "$TMP_AGENT/before.refs"
git -C "$TMP_AGENT/repo" worktree list --porcelain > "$TMP_AGENT/before.worktrees"
agent_assert 'dry-run cleanup failed' run_agent_cleanup "$TMP_AGENT/dry.log" --dry-run
agent_assert 'dry-run must predict ancestor' grep -qF '削除候補のエージェントブランチ: worktree-agent-ancestor' "$TMP_AGENT/dry.log"
agent_assert 'dry-run must predict renamed merged head' grep -qF '削除候補のエージェントブランチ: worktree-agent-merged' "$TMP_AGENT/dry.log"
git -C "$TMP_AGENT/repo" show-ref > "$TMP_AGENT/after.refs"
git -C "$TMP_AGENT/repo" worktree list --porcelain > "$TMP_AGENT/after.worktrees"
agent_assert 'dry-run changed refs' cmp -s "$TMP_AGENT/before.refs" "$TMP_AGENT/after.refs"
agent_assert 'dry-run changed worktrees' cmp -s "$TMP_AGENT/before.worktrees" "$TMP_AGENT/after.worktrees"
agent_assert 'normal cleanup failed' run_agent_cleanup "$TMP_AGENT/real.log"
for branch in ancestor merged; do
  agent_assert "must delete $branch" agent_absent "worktree-agent-$branch"
  agent_assert "must report deleted $branch" grep -qF "エージェントブランチを削除: worktree-agent-$branch" "$TMP_AGENT/real.log"
done
for item in 'worktree:worktree が保持中' 'remote:origin に同名 ref が存在する' 'unmerged:base の祖先ではなく' 'wrong-base:base の祖先ではなく' 'fork:base の祖先ではなく' 'protected:保護ブランチ'; do
  branch="${item%%:*}"
  reason="${item#*:}"
  agent_assert "must retain $branch" agent_exists "worktree-agent-$branch"
  agent_assert "must explain skip $branch" grep -qF "worktree-agent-${branch}: ${reason}" "$TMP_AGENT/real.log"
done
agent_assert 'ordinary orphan changed' agent_exists ordinary-orphan
agent_assert 'live worktree removed' test -d "$TMP_AGENT/live worktree"
git -C "$TMP_AGENT/repo" worktree list --porcelain > "$TMP_AGENT/real.worktrees"
agent_assert 'live worktree lock removed' grep -q '^locked claude agent worktree$' "$TMP_AGENT/real.worktrees"
agent_assert 'skip summary missing' grep -qF 'スキップした削除候補' "$TMP_AGENT/real.log"
# 同じ候補が別の安全境界によって偶然残っただけにならないよう、祖先・孤児 1 本で失敗注入。
for mode in wt-fail wt-empty wt-warning remote-fail; do
  make_agent_ref "worktree-agent-$mode"
  # 既存の最終 worktree 検証も失敗注入を受けるため、全体の rc ではなく削除境界を照合する。
  AGENT_PROBE_MODE="$mode" run_agent_cleanup "$TMP_AGENT/$mode.log" || true
  agent_assert "fail-closed $mode removed candidate" agent_exists "worktree-agent-$mode"
  agent_assert "fail-closed $mode reason missing" grep -qE "worktree-agent-${mode}: .*fail-closed" "$TMP_AGENT/$mode.log"
  git -C "$TMP_AGENT/repo" branch -D "worktree-agent-$mode" >/dev/null
done
printf '✓ agent branch cleanup: %s assertions pass\n' "$AGENT_PASS"
