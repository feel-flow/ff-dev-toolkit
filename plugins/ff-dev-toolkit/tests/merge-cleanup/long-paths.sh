#!/usr/bin/env bash
# Windows の 260 文字を超えるパスを持つ worktree の削除経路を、独立した git fixture で照合する（Issue `#2479`）。
# OSTYPE は BASH_ENV のファイルで差し替える（bash は起動時に OSTYPE を設定し直すので、環境変数では渡せない）。
# msys では git -c core.longpaths=true worktree remove で消し、サマリーにその方法を名指しする。
# 他の OS では従来どおり git worktree remove だけを呼び、名指しを出さない。
# ignored の node_modules にはリンクを 1 つ置き、worktree remove を呼んだ時点で worktree に残るリンクの数を記録する。
# msys では先にリンクだけを外しているので 0、他の OS では従来どおり外さないので 1（Issue `#2557`）。
# msys でリンクを外せない・確かめられない回（check-ignore の失敗、status.showUntrackedFiles=no で隠れた
# 未追跡のリンク）は、worktree remove を呼ばずに止まり、worktree を残すことも見る。
# 実物のジャンクションを git がたどる回は windows-junctions.sh が Windows の実機で見る。
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
# リンクの数え上げに失敗した回は印の行が 1 本増えるので、合格値の 0 にはならない
cat > "$LONG_TMP/bin/git" <<'GIT'
#!/usr/bin/env bash
case " $* " in
  *' worktree remove '*)
    printf '%s\n' "$*" >> "$LONG_CALLS"
    { find "${!#}" -type l || echo 'find-failed'; } | awk 'END { print NR + 0 }' >> "$LONG_LINKS"
    ;;
  *' check-ignore '*)
    if [ -n "${LONG_CHECK_IGNORE_RC:-}" ]; then exit "$LONG_CHECK_IGNORE_RC"; fi
    ;;
esac
exec "$LONG_REAL_GIT" "$@"
GIT
chmod +x "$LONG_TMP/bin/gh" "$LONG_TMP/bin/git"

dir_link() { # <link> <target>。実行している OS で作れるディレクトリのリンク（Git Bash の ln -s は既定で複製する）
  case "$OSTYPE" in
    msys* | cygwin*) MSYS_NO_PATHCONV=1 cmd /c mklink /J "$(cygpath -w "$1")" "$(cygpath -w "$2")" > /dev/null 2>&1 || true ;;
    *) ln -s "$2" "$1" ;;
  esac
  # 作れなかった回を緑へ倒さない（リンクの数の照合が当たらなくなる）
  [ -L "$1" ] || { echo "✗ long paths: could not create a directory link: $1 -> $2" >&2; exit 1; }
}

long_fixture() { # <dir>。wt / wt_listed を設定する
  local dir="$1"
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
  # Windows の git は登録を C:/… の綴りで返す。/tmp/… のままでは照合が当たらず「未登録」に倒れる。
  # macOS は /var を /private/var へ解決して登録する。論理パスのままでは照合が外れる。
  wt_listed="$wt"
  if command -v cygpath > /dev/null 2>&1; then
    wt_listed="$(cygpath -m "$wt")"
  else
    wt_listed="$(CDPATH= cd -P -- "$wt" && pwd -P)"
  fi
  git -C "$dir/main" worktree list --porcelain | grep -xF "worktree $wt_listed" > /dev/null || {
    echo "✗ long paths ($dir): the registration check does not match the fixture worktree: $wt_listed" >&2; exit 1
  }
  mkdir -p "$wt/node_modules" "$dir/outside"
  printf 'keep\n' > "$dir/outside/keep.txt"
  dir_link "$wt/node_modules/linked" "$dir/outside"
}

long_run() { # <dir> <ostype> → rc。追加の環境は呼び出し側が export する
  printf 'OSTYPE=%s\n' "$2" > "$1/ostype.env"
  : > "$1/calls.log"
  : > "$1/links.log"
  (cd "$1/main"
    unset FF_DEV_TOOLKIT_ROOT CLAUDE_PLUGIN_ROOT GROK_PLUGIN_ROOT
    LONG_CALLS="$1/calls.log" LONG_LINKS="$1/links.log" BASH_ENV="$1/ostype.env" FF_MERGE_CLEANUP_TRANSCRIPTS=off \
      PATH="$LONG_TMP/bin:$PATH" bash "$TARGET" 1) > "$1/run.log" 2>&1
}

long_case() { # <ostype> <deep:true|false>
  local ostype="$1" deep="$2" dir="$LONG_TMP/$1" wt wt_listed calls links log segment i note
  long_fixture "$dir"
  if [ "$deep" = true ]; then
    # ignored の node_modules だけを深くする。worktree は clean のまま（削除の判定は変わらない）
    segment="$wt/node_modules"
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do segment="$segment/package-name-segment-$i"; done
    mkdir -p "$segment"
    printf 'x\n' > "$segment/index.js"
  fi
  calls="$dir/calls.log"; links="$dir/links.log"; log="$dir/run.log"
  long_run "$dir" "$ostype" || {
    echo "✗ long paths ($ostype): merge-cleanup failed" >&2; cat "$log" >&2; exit 1
  }
  if [ -e "$wt" ] || git -C "$dir/main" worktree list --porcelain | grep -xF "worktree $wt_listed" > /dev/null; then
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
      [ "$(cat "$links")" = 0 ] && [ -f "$dir/outside/keep.txt" ] || {
        echo "✗ long paths ($ostype): the ignored link was still in the worktree when git removed it (links: $(cat "$links"))" >&2
        cat "$log" >&2; exit 1
      }
      ;;
    *)
      grep -q '^worktree remove ' "$calls" \
        && ! grep -qF "$note" "$log" || {
        echo "✗ long paths ($ostype): the removal path changed outside Windows" >&2
        cat "$calls" "$log" >&2; exit 1
      }
      [ "$(cat "$links")" = 1 ] || {
        echo "✗ long paths ($ostype): links were removed before git outside Windows (links: $(cat "$links"))" >&2
        cat "$log" >&2; exit 1
      }
      ;;
  esac
}

long_stop_case() { # <mode:check-ignore-fails|hidden-untracked>。msys で、削除へ進まずに止まる回
  local mode="$1" dir="$LONG_TMP/stop-$1" wt wt_listed needle
  long_fixture "$dir"
  case "$mode" in
    check-ignore-fails)
      needle='リンクが ignored かを判定できませんでした（git check-ignore rc=128）'
      export LONG_CHECK_IGNORE_RC=128
      ;;
    hidden-untracked)
      needle='追跡していないリンクが残っています'
      git -C "$dir/main" config status.showUntrackedFiles no
      dir_link "$wt/stray" "$dir/outside"
      # 前提: 未追跡のリンクが clean の確認に出ない（出るなら、この回は既存の dirty 判定を見ているだけになる）
      [ -z "$(git -C "$wt" status --porcelain)" ] || {
        echo "✗ long paths (stop $mode): the untracked link is not hidden from git status" >&2; exit 1
      }
      ;;
  esac
  long_run "$dir" msys || true
  unset LONG_CHECK_IGNORE_RC
  [ -d "$wt" ] && git -C "$dir/main" worktree list --porcelain | grep -xF "worktree $wt_listed" > /dev/null || {
    echo "✗ long paths (stop $mode): the worktree was removed" >&2; cat "$dir/run.log" >&2; exit 1
  }
  [ "$(awk 'END { print NR + 0 }' "$dir/calls.log")" -eq 0 ] || {
    echo "✗ long paths (stop $mode): git worktree remove was called" >&2; cat "$dir/calls.log" >&2; exit 1
  }
  grep -qF "$needle" "$dir/run.log" && grep -qF 'worktree 削除に失敗' "$dir/run.log" \
    && [ -f "$dir/outside/keep.txt" ] || {
    echo "✗ long paths (stop $mode): the stop was not reported, or the link target lost keep.txt" >&2
    cat "$dir/run.log" >&2; exit 1
  }
}

# msys の回は深いパスも置く。Windows の実機ではこれが 260 文字を超え、設定が無いと実体が残る。
long_case msys true
long_case linux-gnu false
long_stop_case check-ignore-fails
long_stop_case hidden-untracked
printf '✓ long paths: msys unlinks ignored links and removes with core.longpaths and names it, and stops before git when it cannot; other OSes keep git worktree remove\n'
