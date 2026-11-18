#!/usr/bin/env bash
# [gone] ローカルブランチの祖先判定（古い OID で残った未変更ブランチの削除と、
# 非祖先・取得不能・複数 PR・fork PR・linked worktree 保持時の保護）を
# 独立した git fixture で実測する。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-$SCRIPT_DIR/../../scripts/merge-cleanup.sh}"
[ -f "$TARGET" ] || { echo '✗ gone-ancestor: script missing' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo '✗ gone-ancestor: jq missing' >&2; exit 1; }

# shellcheck source=../lib/git-fixture.sh
. "$SCRIPT_DIR/../lib/git-fixture.sh"

TMP_GA="$(mktemp -d)"
TMP_GA="$(cd "$TMP_GA" && pwd -P)"
trap 'rm -rf "$TMP_GA"' EXIT

REAL_GIT_GA="$(command -v git)"
mkdir -p "$TMP_GA/bin" "$TMP_GA/projects" "$TMP_GA/archives"

git init -q --bare "$TMP_GA/origin.git"
git clone -q "$TMP_GA/origin.git" "$TMP_GA/repo" 2>/dev/null
ff_git_fixture_init "$TMP_GA/repo"
git -C "$TMP_GA/repo" switch -qc develop
printf 'base\n' > "$TMP_GA/repo/base.txt"
git -C "$TMP_GA/repo" add base.txt
git -C "$TMP_GA/repo" commit -qm "init base"
git -C "$TMP_GA/repo" push -qu origin develop
BASE_OID="$(git -C "$TMP_GA/repo" rev-parse HEAD)"

git clone -q "$TMP_GA/origin.git" "$TMP_GA/other" 2>/dev/null
ff_git_fixture_init "$TMP_GA/other"
git -C "$TMP_GA/other" switch -q develop

# origin.git に存在しない commit OID（取得失敗・判定不能ケース用）を別の孤立リポジトリで作る
git init -q "$TMP_GA/scratch"
ff_git_fixture_init "$TMP_GA/scratch"
git -C "$TMP_GA/scratch" switch -qc develop
printf 'unreachable commit\n' > "$TMP_GA/scratch/unreachable.txt"
git -C "$TMP_GA/scratch" add unreachable.txt
git -C "$TMP_GA/scratch" commit -qm "commit never pushed to origin"
OID_UNREACHABLE_HEAD="$(git -C "$TMP_GA/scratch" rev-parse HEAD)"

# ---- 1. ローカル祖先（PR head commit が手元オブジェクト DB にある） ----
git -C "$TMP_GA/repo" switch -qc fix/anc-local develop
printf 'anc-local-1\n' > "$TMP_GA/repo/anc_local.txt"
git -C "$TMP_GA/repo" add anc_local.txt
git -C "$TMP_GA/repo" commit -qm "anc-local commit 1"
OID_ANC_LOCAL_OLD="$(git -C "$TMP_GA/repo" rev-parse HEAD)"
printf 'anc-local-2\n' >> "$TMP_GA/repo/anc_local.txt"
git -C "$TMP_GA/repo" add anc_local.txt
git -C "$TMP_GA/repo" commit -qm "anc-local commit 2 (in local objdb)"
OID_ANC_LOCAL_HEAD="$(git -C "$TMP_GA/repo" rev-parse HEAD)"
git -C "$TMP_GA/repo" push -qu origin fix/anc-local
git -C "$TMP_GA/repo" reset --hard -q "$OID_ANC_LOCAL_OLD"
git -C "$TMP_GA/repo" switch -q develop
git -C "$TMP_GA/repo" push -q origin --delete fix/anc-local

# ---- 2. リモートのみの祖先（別作業環境で先へ進み、呼び出し元には PR head が無い） ----
git -C "$TMP_GA/repo" switch -qc fix/anc-fetch develop
printf 'anc-fetch-1\n' > "$TMP_GA/repo/anc_fetch.txt"
git -C "$TMP_GA/repo" add anc_fetch.txt
git -C "$TMP_GA/repo" commit -qm "anc-fetch commit 1 (caller stops here)"
git -C "$TMP_GA/repo" push -qu origin fix/anc-fetch
git -C "$TMP_GA/repo" switch -q develop

git -C "$TMP_GA/other" fetch -q origin
git -C "$TMP_GA/other" switch -qc fix/anc-fetch --track origin/fix/anc-fetch
printf 'anc-fetch-2\n' > "$TMP_GA/other/anc_fetch_extra.txt"
git -C "$TMP_GA/other" add anc_fetch_extra.txt
git -C "$TMP_GA/other" commit -qm "anc-fetch commit 2 (pushed from other clone)"
OID_ANC_FETCH_HEAD="$(git -C "$TMP_GA/other" rev-parse HEAD)"
git -C "$TMP_GA/other" push -q origin fix/anc-fetch
git -C "$TMP_GA/origin.git" update-ref refs/pull/20/head "$OID_ANC_FETCH_HEAD"
git -C "$TMP_GA/other" switch -q develop
git -C "$TMP_GA/other" merge --squash -q fix/anc-fetch >/dev/null
git -C "$TMP_GA/other" commit -qm "squash merge fix/anc-fetch and fix/anc-local"
git -C "$TMP_GA/other" push -q origin develop
git -C "$TMP_GA/other" push -q origin --delete fix/anc-fetch

git -C "$TMP_GA/repo" fetch --prune -q origin
git -C "$TMP_GA/repo" pull --ff-only -q origin develop

# ---- 3. 同一名 PR が複数あり、ローカル OID がそのうち片方と完全一致（従来保護の維持） ----
git -C "$TMP_GA/repo" switch -qc fix/dup-exact develop
printf 'dup-exact\n' > "$TMP_GA/repo/dup_exact.txt"
git -C "$TMP_GA/repo" add dup_exact.txt
git -C "$TMP_GA/repo" commit -qm "dup-exact commit"
OID_DUP_EXACT_1="$(git -C "$TMP_GA/repo" rev-parse HEAD)"
printf 'dup-exact-other\n' >> "$TMP_GA/repo/dup_exact.txt"
git -C "$TMP_GA/repo" add dup_exact.txt
git -C "$TMP_GA/repo" commit -qm "dup-exact commit 2"
OID_DUP_EXACT_2="$(git -C "$TMP_GA/repo" rev-parse HEAD)"
git -C "$TMP_GA/repo" push -qu origin fix/dup-exact
git -C "$TMP_GA/repo" reset --hard -q "$OID_DUP_EXACT_1"
git -C "$TMP_GA/repo" switch -q develop
git -C "$TMP_GA/repo" push -q origin --delete fix/dup-exact

# ---- 4. 非祖先（PR に入っていない固有コミットをローカルに持つ） ----
git -C "$TMP_GA/repo" switch -qc fix/non-anc "$BASE_OID"
printf 'non-anc-local\n' > "$TMP_GA/repo/non_anc.txt"
git -C "$TMP_GA/repo" add non_anc.txt
git -C "$TMP_GA/repo" commit -qm "local unmerged commit"
git -C "$TMP_GA/repo" push -qu origin fix/non-anc
git -C "$TMP_GA/repo" switch -q develop
git -C "$TMP_GA/repo" push -q origin --delete fix/non-anc
OID_NON_ANC_HEAD="$(printf 'merged non-anc PR\n' | git -C "$TMP_GA/repo" commit-tree "${BASE_OID}^{tree}" -p "$BASE_OID")"

# ---- 5. 取得失敗（PR head を手元で参照できず origin にも無い）+ 引用文字入りブランチ ----
# shellcheck disable=SC2016 # $(...) と `...` は ref 名の一部（展開しない）
GA_QUOTE_BRANCH="q/ga-unreach-'"'$(touch${IFS}ga-sent)'"'"'`true`;x'
git check-ref-format "refs/heads/${GA_QUOTE_BRANCH}" || { echo '✗ invalid quote ref' >&2; exit 1; }
for b in fix/anc-unreachable "$GA_QUOTE_BRANCH"; do
  git -C "$TMP_GA/repo" switch -qc "$b" "$BASE_OID"
  printf '%s\n' "$b" > "$TMP_GA/repo/unreach.txt"
  git -C "$TMP_GA/repo" add unreach.txt
  git -C "$TMP_GA/repo" commit -qm "branch with unreachable PR head"
  git -C "$TMP_GA/repo" push -qu origin "$b"
  git -C "$TMP_GA/repo" switch -q develop
  git -C "$TMP_GA/repo" push -q origin --delete "$b"
done

# ---- 6. 同名の MERGED PR が複数ある場合の祖先 OID（完全一致のみ許可・緩和しない） ----
git -C "$TMP_GA/repo" switch -qc fix/dup-anc "$BASE_OID"
printf 'dup-anc-1\n' > "$TMP_GA/repo/dup_anc.txt"
git -C "$TMP_GA/repo" add dup_anc.txt
git -C "$TMP_GA/repo" commit -qm "dup-anc local ancestor commit"
OID_DUP_ANC_LOCAL="$(git -C "$TMP_GA/repo" rev-parse HEAD)"
printf 'dup-anc-2\n' >> "$TMP_GA/repo/dup_anc.txt"
git -C "$TMP_GA/repo" add dup_anc.txt
git -C "$TMP_GA/repo" commit -qm "dup-anc PR 2 head"
OID_DUP_ANC_P2="$(git -C "$TMP_GA/repo" rev-parse HEAD)"
git -C "$TMP_GA/repo" push -qu origin fix/dup-anc
git -C "$TMP_GA/repo" reset --hard -q "$OID_DUP_ANC_LOCAL"
git -C "$TMP_GA/repo" switch -q develop
git -C "$TMP_GA/repo" push -q origin --delete fix/dup-anc
# PR 1 / PR 2 とも OID_DUP_ANC_LOCAL の子孫にし、複数 PR を許可する変異ではどちらを採っても削除へ倒れるようにする
OID_DUP_ANC_P1="$(printf 'dup-anc PR 1\n' | git -C "$TMP_GA/repo" commit-tree "${OID_DUP_ANC_LOCAL}^{tree}" -p "$OID_DUP_ANC_LOCAL")"

# ---- 7. fork PR（isCrossRepository=true）の祖先 OID（保護） ----
git -C "$TMP_GA/repo" switch -qc fix/fork-anc "$BASE_OID"
printf 'fork-anc-1\n' > "$TMP_GA/repo/fork_anc.txt"
git -C "$TMP_GA/repo" add fork_anc.txt
git -C "$TMP_GA/repo" commit -qm "fork-anc commit 1"
OID_FORK_ANC_LOCAL="$(git -C "$TMP_GA/repo" rev-parse HEAD)"
printf 'fork-anc-2\n' >> "$TMP_GA/repo/fork_anc.txt"
git -C "$TMP_GA/repo" add fork_anc.txt
git -C "$TMP_GA/repo" commit -qm "fork-anc PR head"
OID_FORK_ANC_HEAD="$(git -C "$TMP_GA/repo" rev-parse HEAD)"
git -C "$TMP_GA/repo" push -qu origin fix/fork-anc
git -C "$TMP_GA/repo" reset --hard -q "$OID_FORK_ANC_LOCAL"
git -C "$TMP_GA/repo" switch -q develop
git -C "$TMP_GA/repo" push -q origin --delete fix/fork-anc

# ---- 8. linked worktree が保持中の [gone] 祖先 OID（保護） ----
git -C "$TMP_GA/repo" switch -qc fix/wt-anc "$BASE_OID"
printf 'wt-anc-1\n' > "$TMP_GA/repo/wt_anc.txt"
git -C "$TMP_GA/repo" add wt_anc.txt
git -C "$TMP_GA/repo" commit -qm "wt-anc commit 1"
OID_WT_ANC_LOCAL="$(git -C "$TMP_GA/repo" rev-parse HEAD)"
printf 'wt-anc-2\n' >> "$TMP_GA/repo/wt_anc.txt"
git -C "$TMP_GA/repo" add wt_anc.txt
git -C "$TMP_GA/repo" commit -qm "wt-anc PR head"
OID_WT_ANC_HEAD="$(git -C "$TMP_GA/repo" rev-parse HEAD)"
git -C "$TMP_GA/repo" push -qu origin fix/wt-anc
git -C "$TMP_GA/repo" reset --hard -q "$OID_WT_ANC_LOCAL"
git -C "$TMP_GA/repo" switch -q develop
git -C "$TMP_GA/repo" push -q origin --delete fix/wt-anc

# ---- 9. 対象 PR 用ダミー head ----
git -C "$TMP_GA/repo" switch -qc feature/target "$BASE_OID"
git -C "$TMP_GA/repo" push -q origin feature/target
git -C "$TMP_GA/repo" switch -q develop
git -C "$TMP_GA/repo" branch -q -D feature/target
git -C "$TMP_GA/repo" push -q origin --delete feature/target

# Phase B 用にコピーしてから、Phase B 側へ linked worktree を張り、
# Phase A 側（全対象が安全に消えるクリーンシナリオ: exit 0 を検証）からは保護対象ブランチを外す。
cp -R "$TMP_GA/repo" "$TMP_GA/repo-protected"
git -C "$TMP_GA/repo-protected" worktree add -q "$TMP_GA/wt-anc" fix/wt-anc
for drop_b in fix/non-anc fix/anc-unreachable "$GA_QUOTE_BRANCH" fix/dup-anc fix/fork-anc fix/wt-anc; do
  git -C "$TMP_GA/repo" branch -q -D "$drop_b"
done

# repo では OID_ANC_LOCAL_HEAD を手元に持ち、OID_ANC_FETCH_HEAD はまだ持っていないことを事前検証
if ! git -C "$TMP_GA/repo" cat-file -e "${OID_ANC_LOCAL_HEAD}^{commit}" 2>/dev/null; then
  echo '✗ gone-ancestor fixture error: caller repo missing local PR head' >&2
  exit 1
fi
if git -C "$TMP_GA/repo" cat-file -e "${OID_ANC_FETCH_HEAD}^{commit}" 2>/dev/null; then
  echo '✗ gone-ancestor fixture error: caller repo unexpectedly already has remote-only PR head' >&2
  exit 1
fi

jq -n \
  --arg base "$BASE_OID" \
  --arg anc_local "$OID_ANC_LOCAL_HEAD" \
  --arg anc_fetch "$OID_ANC_FETCH_HEAD" \
  --arg dup_e1 "$OID_DUP_EXACT_1" \
  --arg dup_e2 "$OID_DUP_EXACT_2" \
  --arg non_anc "$OID_NON_ANC_HEAD" \
  --arg unreach "$OID_UNREACHABLE_HEAD" \
  --arg qbranch "$GA_QUOTE_BRANCH" \
  --arg dup_p1 "$OID_DUP_ANC_P1" \
  --arg dup_p2 "$OID_DUP_ANC_P2" \
  --arg fork_anc "$OID_FORK_ANC_HEAD" \
  --arg wt_anc "$OID_WT_ANC_HEAD" \
  '[
    {"headRefName":"feature/target","headRefOid":$base,"isCrossRepository":false,"baseRefName":"develop"},
    {"headRefName":"fix/anc-local","headRefOid":$anc_local,"isCrossRepository":false,"baseRefName":"develop"},
    {"headRefName":"fix/anc-fetch","headRefOid":$anc_fetch,"isCrossRepository":false,"baseRefName":"develop"},
    {"headRefName":"fix/dup-exact","headRefOid":$dup_e1,"isCrossRepository":false,"baseRefName":"develop"},
    {"headRefName":"fix/dup-exact","headRefOid":$dup_e2,"isCrossRepository":false,"baseRefName":"develop"},
    {"headRefName":"fix/non-anc","headRefOid":$non_anc,"isCrossRepository":false,"baseRefName":"develop"},
    {"headRefName":"fix/anc-unreachable","headRefOid":$unreach,"isCrossRepository":false,"baseRefName":"develop"},
    {"headRefName":$qbranch,"headRefOid":$unreach,"isCrossRepository":false,"baseRefName":"develop"},
    {"headRefName":"fix/dup-anc","headRefOid":$dup_p1,"isCrossRepository":false,"baseRefName":"develop"},
    {"headRefName":"fix/dup-anc","headRefOid":$dup_p2,"isCrossRepository":false,"baseRefName":"develop"},
    {"headRefName":"fix/fork-anc","headRefOid":$fork_anc,"isCrossRepository":true,"baseRefName":"develop"},
    {"headRefName":"fix/wt-anc","headRefOid":$wt_anc,"isCrossRepository":false,"baseRefName":"develop"}
  ]' > "$TMP_GA/pr_list_merged.json"

jq -n --arg base "$BASE_OID" '{
  "state":"MERGED",
  "headRefName":"feature/target",
  "headRefOid":$base,
  "baseRefName":"develop",
  "title":"gone ancestor fixture target",
  "isCrossRepository":false
}' > "$TMP_GA/pr_view.json"

cat > "$TMP_GA/bin/gh" <<'GH'
#!/usr/bin/env bash
if [ "${1:-} ${2:-}" = "pr view" ]; then
  cat "$GA_PR_VIEW_JSON"
elif [[ " $* " = *' --state merged '* ]]; then
  cat "$GA_PR_LIST_MERGED_JSON"
else
  printf '[]\n'
fi
GH

cat > "$TMP_GA/bin/git" <<'GIT'
#!/usr/bin/env bash
if [ "${GA_PROBE_MODE:-}" = "mb-error" ] && [ "${1:-}" = "merge-base" ] && [ "${2:-}" = "--is-ancestor" ]; then
  echo "fatal: simulated shallow/missing object for merge-base" >&2
  exit 128
fi
exec "$REAL_GIT_GA" "$@"
GIT
chmod +x "$TMP_GA/bin/gh" "$TMP_GA/bin/git"

export REAL_GIT_GA
export GA_PR_VIEW_JSON="$TMP_GA/pr_view.json"
export GA_PR_LIST_MERGED_JSON="$TMP_GA/pr_list_merged.json"

GA_PASS=0
ga_assert() {
  local msg="$1"
  shift
  if "$@"; then
    GA_PASS=$((GA_PASS + 1))
  else
    echo "✗ gone-ancestor: ${msg}" >&2
    return 1
  fi
}
ga_branch_exists() { git -C "$1" show-ref --verify --quiet "refs/heads/$2"; }
ga_branch_absent() { ! ga_branch_exists "$1" "$2"; }
ga_lacks_commit() { ! git -C "$1" cat-file -e "${2}^{commit}" 2>/dev/null; }
ga_file_lacks_string() { ! grep -qF "$2" "$1"; }

run_ga_cleanup() {
  local repo_dir="$1" log="$2"
  shift 2
  set +e
  (
    cd "$repo_dir"
    # fixture は直接起動経路を検査し、consumer host の handoff を継承しない。
    unset FF_DEV_TOOLKIT_ROOT CLAUDE_PLUGIN_ROOT GROK_PLUGIN_ROOT
    FF_MERGE_CLEANUP_TRANSCRIPTS=off \
      FF_MERGE_CLEANUP_PROJECTS_DIR="$TMP_GA/projects" \
      FF_MERGE_CLEANUP_TRANSCRIPT_ARCHIVE_DIR="$TMP_GA/archives" \
      PATH="$TMP_GA/bin:$PATH" bash "$TARGET" "$@" 1
  ) > "$log" 2>&1
  GA_LAST_RC=$?
  set -e
}

# ---- Phase A: すべて祖先/完全一致の [gone] ブランチだけ（--dry-run と通常実行で exit 0） ----
rm -f "$TMP_GA/repo/.git/FETCH_HEAD"
git -C "$TMP_GA/repo" show-ref > "$TMP_GA/clean-before.refs"
git -C "$TMP_GA/repo" worktree list --porcelain > "$TMP_GA/clean-before.wt"

run_ga_cleanup "$TMP_GA/repo" "$TMP_GA/clean-dry.log" --dry-run
ga_assert "clean dry-run exits 0 (rc=${GA_LAST_RC})" test "$GA_LAST_RC" -eq 0
ga_assert 'clean dry-run predicts fix/anc-local' grep -qF '削除対象のブランチ: fix/anc-local' "$TMP_GA/clean-dry.log"
ga_assert 'clean dry-run predicts fix/anc-fetch' grep -qF '削除対象のブランチ: fix/anc-fetch' "$TMP_GA/clean-dry.log"
ga_assert 'clean dry-run predicts fix/dup-exact' grep -qF '削除対象のブランチ: fix/dup-exact' "$TMP_GA/clean-dry.log"

git -C "$TMP_GA/repo" show-ref > "$TMP_GA/clean-after-dry.refs"
git -C "$TMP_GA/repo" worktree list --porcelain > "$TMP_GA/clean-after-dry.wt"
ga_assert 'dry-run must not modify refs' cmp -s "$TMP_GA/clean-before.refs" "$TMP_GA/clean-after-dry.refs"
ga_assert 'dry-run must not modify worktrees' cmp -s "$TMP_GA/clean-before.wt" "$TMP_GA/clean-after-dry.wt"
ga_assert 'dry-run must not fetch remote PR head into real repo object store' \
  ga_lacks_commit "$TMP_GA/repo" "$OID_ANC_FETCH_HEAD"
ga_assert 'dry-run must not write FETCH_HEAD' test ! -e "$TMP_GA/repo/.git/FETCH_HEAD"

# 呼び出し元環境から MC_DRY_OBJ_DIR が渡されても信用せず、一時領域へ隔離すること
mkdir -p "$TMP_GA/poison-dry-obj/info" "$TMP_GA/poison-dry-obj/pack"
MC_DRY_OBJ_DIR="$TMP_GA/poison-dry-obj" run_ga_cleanup "$TMP_GA/repo" "$TMP_GA/clean-poison-dry.log" --dry-run
ga_assert "poison MC_DRY_OBJ_DIR dry-run still exits 0 (rc=${GA_LAST_RC})" test "$GA_LAST_RC" -eq 0
ga_assert 'poison MC_DRY_OBJ_DIR dry-run still predicts remote ancestor fix/anc-fetch' \
  grep -qF '削除対象のブランチ: fix/anc-fetch' "$TMP_GA/clean-poison-dry.log"
ga_assert 'caller MC_DRY_OBJ_DIR receives no fetched objects' \
  test -z "$(find "$TMP_GA/poison-dry-obj" -type f 2>/dev/null || true)"

run_ga_cleanup "$TMP_GA/repo" "$TMP_GA/clean-real.log"
ga_assert "clean normal run exits 0 instead of PARTIAL (rc=${GA_LAST_RC})" test "$GA_LAST_RC" -eq 0
for b in fix/anc-local fix/anc-fetch fix/dup-exact; do
  ga_assert "must delete ${b} in clean run" ga_branch_absent "$TMP_GA/repo" "$b"
done
ga_assert 'clean normal run does not record fetched PR head in FETCH_HEAD (--no-write-fetch-head)' \
  ga_file_lacks_string "$TMP_GA/repo/.git/FETCH_HEAD" "$OID_ANC_FETCH_HEAD"

# ---- Phase B: 保護対象（非祖先・取得不能・複数 PR 祖先・fork PR 祖先・worktree 保持） ----
# まず通常実行と同じ対象が削除予定/保護されることを --dry-run でも確認
git -C "$TMP_GA/repo-protected" show-ref > "$TMP_GA/prot-before.refs"
git -C "$TMP_GA/repo-protected" worktree list --porcelain > "$TMP_GA/prot-before.wt"
run_ga_cleanup "$TMP_GA/repo-protected" "$TMP_GA/prot-dry.log" --dry-run
ga_assert "protected dry-run exits 2 PARTIAL (rc=${GA_LAST_RC})" test "$GA_LAST_RC" -eq 2
git -C "$TMP_GA/repo-protected" show-ref > "$TMP_GA/prot-after-dry.refs"
git -C "$TMP_GA/repo-protected" worktree list --porcelain > "$TMP_GA/prot-after-dry.wt"
ga_assert 'protected dry-run must not change refs' cmp -s "$TMP_GA/prot-before.refs" "$TMP_GA/prot-after-dry.refs"
ga_assert 'protected dry-run must not change worktrees' cmp -s "$TMP_GA/prot-before.wt" "$TMP_GA/prot-after-dry.wt"
ga_assert 'protected dry-run predicts safe ancestor fix/anc-local' \
  grep -qF '削除対象のブランチ: fix/anc-local' "$TMP_GA/prot-dry.log"
ga_assert 'protected dry-run predicts remote ancestor fix/anc-fetch' \
  grep -qF '削除対象のブランチ: fix/anc-fetch' "$TMP_GA/prot-dry.log"
ga_assert 'protected dry-run predicts exact multi-PR fix/dup-exact' \
  grep -qF '削除対象のブランチ: fix/dup-exact' "$TMP_GA/prot-dry.log"
ga_assert 'protected dry-run names unreachable failure' grep -qE "fix/anc-unreachable: .*取得・参照できず祖先判定不能" "$TMP_GA/prot-dry.log"
ga_assert 'protected dry-run protects non-anc / dup-anc / fork-anc' \
  grep -qF 'fix/non-anc: [gone] だが MERGED PR と OID 不一致' "$TMP_GA/prot-dry.log"
ga_assert 'protected dry-run protects dup-anc' \
  grep -qF 'fix/dup-anc: [gone] だが MERGED PR と OID 不一致' "$TMP_GA/prot-dry.log"
ga_assert 'protected dry-run protects fork-anc' \
  grep -qF 'fix/fork-anc: [gone] だが MERGED PR と OID 不一致' "$TMP_GA/prot-dry.log"
ga_assert 'protected dry-run protects linked worktree holding ancestor' \
  grep -qF 'fix/wt-anc: [gone] だが MERGED PR と OID 不一致のため worktree を保護' "$TMP_GA/prot-dry.log"

run_ga_cleanup "$TMP_GA/repo-protected" "$TMP_GA/prot-real.log"
ga_assert "protected normal run exits 2 PARTIAL (rc=${GA_LAST_RC})" test "$GA_LAST_RC" -eq 2
for b in fix/non-anc fix/anc-unreachable "$GA_QUOTE_BRANCH" fix/dup-anc fix/fork-anc fix/wt-anc; do
  ga_assert "must retain protected branch ${b}" ga_branch_exists "$TMP_GA/repo-protected" "$b"
done
ga_assert 'must retain linked worktree holding ancestor' test -d "$TMP_GA/wt-anc"
ga_assert 'normal run deletes safe ancestors even alongside retained branches (fix/anc-local)' \
  ga_branch_absent "$TMP_GA/repo-protected" "fix/anc-local"
ga_assert 'normal run deletes remote-fetched ancestor even alongside retained branches (fix/anc-fetch)' \
  ga_branch_absent "$TMP_GA/repo-protected" "fix/anc-fetch"
ga_assert 'normal run deletes dup-exact even alongside retained branches (fix/dup-exact)' \
  ga_branch_absent "$TMP_GA/repo-protected" "fix/dup-exact"
ga_assert 'normal run names unreachable failure' \
  grep -qE "fix/anc-unreachable: .*取得・参照できず祖先判定不能" "$TMP_GA/prot-real.log"

# 取得失敗時の手動削除コマンドがシェルメタ文字を含むブランチ名を 1 語として正しく引用すること
GA_STUB="$TMP_GA/quote-stub"
mkdir -p "$GA_STUB/bin" "$GA_STUB/cwd"
cat > "$GA_STUB/bin/git" <<'STUB'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$GA_STUB_ARGV"
STUB
chmod +x "$GA_STUB/bin/git"
GA_Q_CMD_LINE="$(grep -F "git branch -D" "$TMP_GA/prot-real.log" | grep -F "q/ga-unreach-" | head -1 || true)"
GA_Q_CMD="${GA_Q_CMD_LINE#"${GA_Q_CMD_LINE%%[! ]*}"}"
ga_assert 'manual delete command printed for metacharacter unreachable branch' test -n "$GA_Q_CMD"
rm -f "$GA_STUB/argv" "$GA_STUB/cwd/ga-sent"
(cd "$GA_STUB/cwd" && GA_STUB_ARGV="$GA_STUB/argv" PATH="$GA_STUB/bin:$PATH" bash -c "$GA_Q_CMD") >/dev/null 2>&1 || true
ga_assert 'manual command must not execute embedded shell command' test ! -e "$GA_STUB/cwd/ga-sent"
ga_assert 'manual command passes metacharacter branch name as literal single argv' \
  cmp -s "$GA_STUB/argv" <(printf '%s\0' branch -D "$GA_QUOTE_BRANCH")

# ---- Phase C: merge-base --is-ancestor の 3 値終了コード（rc != 0, 1 は判定不能で保護） ----
git -C "$TMP_GA/repo-protected" branch fix/anc-mb-err "$OID_ANC_LOCAL_OLD"
git -C "$TMP_GA/repo-protected" config branch.fix/anc-mb-err.remote origin
git -C "$TMP_GA/repo-protected" config branch.fix/anc-mb-err.merge refs/heads/fix/anc-mb-err
jq --arg head "$OID_ANC_LOCAL_HEAD" \
  '. + [{"headRefName":"fix/anc-mb-err","headRefOid":$head,"isCrossRepository":false,"baseRefName":"develop"}]' \
  "$TMP_GA/pr_list_merged.json" > "$TMP_GA/pr_list_merged.mb.json"
mv "$TMP_GA/pr_list_merged.mb.json" "$TMP_GA/pr_list_merged.json"

GA_PROBE_MODE=mb-error run_ga_cleanup "$TMP_GA/repo-protected" "$TMP_GA/mb-err.log"
ga_assert "merge-base error run exits 2 (rc=${GA_LAST_RC})" test "$GA_LAST_RC" -eq 2
ga_assert 'merge-base error (rc=128) must retain branch (fail-closed)' \
  ga_branch_exists "$TMP_GA/repo-protected" "fix/anc-mb-err"
ga_assert 'merge-base error must report unreachable/undetermined instead of ancestor or deleted' \
  grep -qE "fix/anc-mb-err: .*取得・参照できず祖先判定不能" "$TMP_GA/mb-err.log"

printf '✓ gone ancestor cleanup: %s assertions pass\n' "${GA_PASS}"
