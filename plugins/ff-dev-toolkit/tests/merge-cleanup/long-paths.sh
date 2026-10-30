#!/usr/bin/env bash
# Windows の 260 文字を超えるパスを持つ worktree の削除経路を、独立した git fixture で照合する（Issue `#2479`）。
# OSTYPE は BASH_ENV のファイルで差し替える（bash は起動時に OSTYPE を設定し直すので、環境変数では渡せない）。
# msys では git -c core.longpaths=true worktree remove で消し、サマリーにその方法を名指しする。
# 他の OS では従来どおり git worktree remove だけを呼び、名指しを出さない。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-$SCRIPT_DIR/../../scripts/merge-cleanup.sh}"
[ -f "$TARGET" ] || { echo '✗ long paths: script missing' >&2; exit 1; }
# shellcheck source=../lib/git-fixture.sh
. "$SCRIPT_DIR/../lib/git-fixture.sh"
LONG_TMP="$(mktemp -d)"
trap 'rm -rf "$LONG_TMP"' EXIT
mkdir -p "$LONG_TMP/bin"
cat > "$LONG_TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
if [ "$1 $2" = 'pr view' ]; then
  printf '{"headRefName":"feature/finished","headRefOid":"%s","state":"MERGED","baseRefName":"develop","title":"fixture","isCrossRepository":false}\n' "$LONG_OID"
elif [[ " $* " = *' --state merged '* ]]; then
  printf '[{"headRefName":"feature/finished","headRefOid":"%s","isCrossRepository":false,"baseRefName":"develop"}]\n' "$LONG_OID"
else
  printf '[]\n'
fi
GH
LONG_REAL_GIT="$(command -v git)"
export LONG_REAL_GIT
cat > "$LONG_TMP/bin/git" <<'GIT'
#!/usr/bin/env bash
case " $* " in *' worktree remove '*) printf '%s\n' "$*" >> "$LONG_CALLS" ;; esac
exec "$LONG_REAL_GIT" "$@"
GIT
chmod +x "$LONG_TMP/bin/gh" "$LONG_TMP/bin/git"

long_case() { # <ostype> <deep:true|false>
  local ostype="$1" deep="$2" dir="$LONG_TMP/$1" wt calls log segment i note
  git init -q --bare "$dir/origin.git"
  git clone -q "$dir/origin.git" "$dir/main" 2>/dev/null
  ff_git_fixture_init "$dir/main"
  git -C "$dir/main" switch -qc develop
  printf 'node_modules\n' > "$dir/main/.gitignore"
  git -C "$dir/main" add .gitignore
  git -C "$dir/main" commit -qm base
  git -C "$dir/main" push -qu origin develop
  LONG_OID="$(git -C "$dir/main" rev-parse HEAD)"
  export LONG_OID
  git -C "$dir/main" branch feature/finished
  git -C "$dir/main" push -qu origin feature/finished
  wt="$dir/wt"
  git -C "$dir/main" worktree add -q "$wt" feature/finished
  if [ "$deep" = true ]; then
    # ignored の node_modules だけを深くする。worktree は clean のまま（削除の判定は変わらない）
    segment="$wt/node_modules"
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do segment="$segment/package-name-segment-$i"; done
    mkdir -p "$segment"
    printf 'x\n' > "$segment/index.js"
  fi
  printf 'OSTYPE=%s\n' "$ostype" > "$dir/ostype.env"
  calls="$dir/calls.log"; log="$dir/run.log"
  : > "$calls"
  (cd "$dir/main"
    unset FF_DEV_TOOLKIT_ROOT CLAUDE_PLUGIN_ROOT GROK_PLUGIN_ROOT
    LONG_CALLS="$calls" BASH_ENV="$dir/ostype.env" FF_MERGE_CLEANUP_TRANSCRIPTS=off \
      PATH="$LONG_TMP/bin:$PATH" bash "$TARGET" 1) > "$log" 2>&1 || {
    echo "✗ long paths ($ostype): merge-cleanup failed" >&2; cat "$log" >&2; exit 1
  }
  if [ -e "$wt" ] || git -C "$dir/main" worktree list --porcelain | grep -xF "worktree $wt" > /dev/null; then
    echo "✗ long paths ($ostype): worktree was left on disk or registered: $wt" >&2; cat "$log" >&2; exit 1
  fi
  [ "$(awk 'END { print NR + 0 }' "$calls")" -eq 1 ] || {
    echo "✗ long paths ($ostype): expected one worktree remove call" >&2; cat "$calls" >&2; exit 1
  }
  note='git -c core.longpaths=true worktree remove で削除'
  case "$ostype" in
    msys*)
      grep -q '^-c core\.longpaths=true worktree remove ' "$calls" \
        && grep -qF "$note" "$log" || {
        echo "✗ long paths ($ostype): core.longpaths was not used or not named in the summary" >&2
        cat "$calls" "$log" >&2; exit 1
      }
      ;;
    *)
      grep -q '^worktree remove ' "$calls" \
        && ! grep -qF "$note" "$log" || {
        echo "✗ long paths ($ostype): the removal path changed outside Windows" >&2
        cat "$calls" "$log" >&2; exit 1
      }
      ;;
  esac
}

# msys の回は深いパスも置く。Windows の実機ではこれが 260 文字を超え、設定が無いと実体が残る。
long_case msys true
long_case linux-gnu false
printf '✓ long paths: msys removes with core.longpaths and names it; other OSes keep git worktree remove\n'
