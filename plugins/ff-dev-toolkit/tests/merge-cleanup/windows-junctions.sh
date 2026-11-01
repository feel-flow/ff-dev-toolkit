#!/usr/bin/env bash
# Windows のジャンクションを置いた worktree の削除を、実物のジャンクションで照合する（Issue `#2557`）。
# Windows の git は worktree remove の途中でジャンクションをたどるので、修正前は次の 2 つが起きた。
#   - ignored の下にある、worktree の外を指すジャンクションの参照先の中身が消える
#   - pnpm と同じ形の node_modules（同じ worktree の中を指すジャンクションの格子）で「Directory not empty」になる
# ここでは、参照先（とその中のリンク）が残ること、pnpm と同じ形の worktree が実体まで消えること、
# 確認の後に足された ignored でないジャンクションは git の拒否で残ること（TOCTOU の安全網）を見る。
# ジャンクションは Windows でしか作れないので、他の OS では理由つきの部分 skip にする。
# 同じ削除の順序（リンクを外してから git に消させる）は、long-paths.sh が全 OS で呼び出し時点のリンク数として見る。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-$SCRIPT_DIR/../../scripts/merge-cleanup.sh}"
[ -f "$TARGET" ] || { echo '✗ windows junctions: script missing' >&2; exit 1; }
case "${OSTYPE:-}" in
  msys* | cygwin*) ;;
  *)
    echo '  ○ skip: Windows の Git Bash でだけ成立する検査のため未実行（merge-cleanup のジャンクションの削除。順序は long-paths.sh が全 OS で見る）'
    exit 0
    ;;
esac
# shellcheck source=../lib/git-fixture.sh
. "$SCRIPT_DIR/../lib/git-fixture.sh"
JUNC_TMP="$(mktemp -d)"
# rm はジャンクションをリンクとして外し、参照先へは降りない
trap 'rm -rf "$JUNC_TMP"' EXIT
mkdir -p "$JUNC_TMP/bin"

junction() { # <link> <target>
  MSYS_NO_PATHCONV=1 cmd /c mklink /J "$(cygpath -w "$1")" "$(cygpath -w "$2")" > /dev/null 2>&1 || true
  # 作れなかった回を緑へ倒さない（針が当たらない入力は赤）
  [ -L "$1" ] || { echo "✗ windows junctions: could not create a junction: $1 -> $2" >&2; exit 1; }
}
export -f junction

cat > "$JUNC_TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
if [ "$1 $2" = 'pr view' ]; then
  printf '{"headRefName":"feature/finished","headRefOid":"%s","state":"MERGED","baseRefName":"develop","title":"fixture","isCrossRepository":false}\n' "$JUNC_OID"
elif [[ " $* " = *' --state merged '* ]]; then
  printf '[{"headRefName":"feature/finished","headRefOid":"%s","isCrossRepository":false,"baseRefName":"develop"}]\n' "$JUNC_OID"
else
  printf '[]\n'
fi
GH
JUNC_REAL_GIT="$(command -v git)"
export JUNC_REAL_GIT
# JUNC_INJECT が空でなければ、リンクの判定の直前（clean の確認の後）に ignored でないジャンクションを足す
cat > "$JUNC_TMP/bin/git" <<'GIT'
#!/usr/bin/env bash
case " $* " in
  *' check-ignore '*)
    if [ -n "${JUNC_INJECT:-}" ] && [ ! -e "$JUNC_INJECT" ]; then junction "$JUNC_INJECT" "$JUNC_INJECT_TARGET"; fi
    ;;
esac
exec "$JUNC_REAL_GIT" "$@"
GIT
chmod +x "$JUNC_TMP/bin/gh" "$JUNC_TMP/bin/git"

fail() { # <case> <message> <log>
  echo "✗ windows junctions ($1): $2" >&2
  cat "$3" >&2
  exit 1
}

junc_case() { # <name> <layout:outside|pnpm|inject>
  local name="$1" layout="$2" dir="$JUNC_TMP/$1" wt nm log p q rc=0 registered=0
  git init -q --bare "$dir/origin.git"
  git clone -q "$dir/origin.git" "$dir/main" 2>/dev/null
  ff_git_fixture_init "$dir/main"
  git -C "$dir/main" switch -qc develop
  printf 'node_modules\n' > "$dir/main/.gitignore"
  printf 'readme\n' > "$dir/main/README.md"
  git -C "$dir/main" add .gitignore README.md
  git -C "$dir/main" commit -qm base
  git -C "$dir/main" push -qu origin develop
  JUNC_OID="$(git -C "$dir/main" rev-parse HEAD)"
  export JUNC_OID
  git -C "$dir/main" branch feature/finished
  git -C "$dir/main" push -qu origin feature/finished
  wt="$dir/wt"
  nm="$wt/node_modules"
  git -C "$dir/main" worktree add -q "$wt" feature/finished
  mkdir -p "$nm" "$dir/outside" "$dir/outside-inner"
  printf 'keep\n' > "$dir/outside/keep.txt"
  printf 'keep\n' > "$dir/outside-inner/keep.txt"
  # 参照先の中のリンクは、find がジャンクションの先へ降りないことの針
  junction "$dir/outside/inner" "$dir/outside-inner"
  case "$layout" in
    outside | inject)
      junction "$nm/jlink" "$dir/outside"
      ;;
    pnpm)
      for p in a b c d e f g h; do
        mkdir -p "$nm/.pnpm/$p@1.0.0/node_modules/$p/lib"
        printf '%s\n' "$p" > "$nm/.pnpm/$p@1.0.0/node_modules/$p/lib/index.js"
        junction "$nm/$p" "$nm/.pnpm/$p@1.0.0/node_modules/$p"
      done
      for p in a b c d; do
        for q in e f g h; do junction "$nm/.pnpm/$p@1.0.0/node_modules/$q" "$nm/.pnpm/$q@1.0.0/node_modules/$q"; done
      done
      ;;
  esac
  log="$dir/run.log"
  [ -z "$(git -C "$wt" status --porcelain)" ] || fail "$name" 'fixture worktree is not clean' /dev/null
  # 登録の照合が実行前に当たることを確かめる（当たらない照合は「消えた」を常に緑にする）
  git -C "$dir/main" worktree list --porcelain | grep -xF "worktree $(cygpath -m "$wt")" > /dev/null \
    || fail "$name" 'the registration check does not match the fixture worktree before the run' /dev/null
  (cd "$dir/main"
    unset FF_DEV_TOOLKIT_ROOT CLAUDE_PLUGIN_ROOT GROK_PLUGIN_ROOT
    if [ "$layout" = inject ]; then
      export JUNC_INJECT="$wt/stray" JUNC_INJECT_TARGET="$dir/outside"
    fi
    FF_MERGE_CLEANUP_TRANSCRIPTS=off PATH="$JUNC_TMP/bin:$PATH" bash "$TARGET" 1) > "$log" 2>&1 || rc=$?
  # git は登録を C:/… の綴りで返すので、/tmp/… のままでは一致せず「未登録」に倒れる
  if git -C "$dir/main" worktree list --porcelain | grep -xF "worktree $(cygpath -m "$wt")" > /dev/null; then registered=1; fi
  [ -f "$dir/outside/keep.txt" ] || fail "$name" 'the junction target outside the worktree lost keep.txt' "$log"
  [ -L "$dir/outside/inner" ] && [ -f "$dir/outside-inner/keep.txt" ] \
    || fail "$name" 'a link inside the junction target was removed' "$log"
  case "$layout" in
    outside | pnpm)
      [ "$rc" -eq 0 ] || fail "$name" "merge-cleanup failed (rc=$rc)" "$log"
      if [ -e "$wt" ] || [ "$registered" = 1 ]; then fail "$name" "worktree was left on disk or registered: $wt" "$log"; fi
      ! grep -qF 'Directory not empty' "$log" || fail "$name" 'git stopped with Directory not empty' "$log"
      grep -qF 'git -c core.longpaths=true worktree remove で削除' "$log" \
        || fail "$name" 'the summary does not name the removal method' "$log"
      ;;
    inject)
      [ -d "$wt" ] && [ "$registered" = 1 ] || fail "$name" 'a worktree with a link added after the clean check was removed' "$log"
      grep -qF 'worktree 削除に失敗' "$log" || fail "$name" 'the refusal was not reported as a removal failure' "$log"
      ;;
  esac
}

# JUNC_CASES で回す回を選べる（verify.sh の変異の回が、pnpm の回だけでも赤になることを確かめる）
for junc_name in ${JUNC_CASES:-outside pnpm inject}; do
  case "$junc_name" in
    outside | pnpm | inject) junc_case "$junc_name" "$junc_name" ;;
    *) echo "✗ windows junctions: unknown case: $junc_name" >&2; exit 1 ;;
  esac
done
printf '✓ windows junctions: junction targets survive, a pnpm-shaped worktree is removed, and git still refuses a link added after the clean check\n'
