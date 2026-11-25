#!/usr/bin/env bash
# merge-cleanup.sh の GraphQL 403 時 REST API フォールバック回帰テスト。
# 引数: $1 = 検査対象の merge-cleanup.sh パス

set -euo pipefail

# 親シェルの plugin root / gh / cleanup 環境変数を隔離（mutant 実行の空振り防止）
unset FF_DEV_TOOLKIT_ROOT CLAUDE_PLUGIN_ROOT GROK_PLUGIN_ROOT GH_HOST GH_REPO \
      FF_MERGE_CLEANUP_IGNORE_PATHS

TARGET="${1:?merge-cleanup.sh のパスが必要です}"
TARGET_DIR="$(cd "$(dirname "$TARGET")" && pwd)"
GH_REST_LIB="${TARGET_DIR}/lib/gh-rest-fallback.sh"

TMP="$(mktemp -d)"
REACHED_END=0
cleanup_tmp() {
  local rc=$?
  rm -rf "$TMP"
  if [ "$rc" -eq 0 ] && [ "$REACHED_END" -ne 1 ]; then
    echo "    ✗ graphql-rest.sh が末尾に到達せず途中終了しました" >&2
    exit 1
  fi
}
trap cleanup_tmp EXIT

PASS=0
FAIL=0
ok()  { echo "    ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "    ✗ $1" >&2; FAIL=$((FAIL + 1)); }

g() { git -c commit.gpgsign=false -c user.email=t@example.com -c user.name=T -c init.defaultBranch=develop "$@"; }

make_world() { # <world_dir> <head_branch>
  local w="$1" branch="$2"
  mkdir -p "$w/bin" "$w/stub" "$w/projects" "$w/archives"
  g init -q --bare "$w/origin.git"
  g clone -q "$w/origin.git" "$w/repo"
  (
    cd "$w/repo"
    printf 'base\n' > base.txt
    g add base.txt
    g commit -qm "chore: init"
    g push -q origin develop
    g checkout -q -b "$branch"
    printf 'feat\n' > feat.txt
    g add feat.txt
    g commit -qm "feat: work"
    g push -q -u origin "$branch"
    # origin URL は GitHub HTTPS 形にしつつ、実通信は insteadOf でローカル bare origin へ送る
    git remote set-url origin "https://github.com/acme/widgets.git"
    git config "url.${w}/origin.git.insteadOf" "https://github.com/acme/widgets.git"
  )
  cat > "$w/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MC_GH_LOG:?}"
if [ "${1:-}" = "api" ]; then
  if [ "${MC_REST_FAIL:-0}" = "1" ]; then
    echo "gh: HTTP 500: rest unavailable" >&2
    exit 1
  fi
  shift 1
  ep=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --hostname) shift 2; continue ;;
      -*) shift; continue ;;
      *) [ -n "$ep" ] || ep="$1"; shift ;;
    esac
  done
  if [ "${MC_REST_OPEN_OVERFLOW:-0}" = "1" ]; then
    case "$ep" in
      repos/*/pulls\?state=open*"&page="*)
        jq -n '[range(0; 100) | {number: (500 + .), state: "open", head: {ref: ("open/overflow-" + tostring)}}]'
        exit 0
        ;;
    esac
  fi
  case "$ep" in
    repos/acme/widgets/pulls/[0-9]*)
      cat "${MC_REST_PR_FILE:?}"
      exit 0
      ;;
    repos/acme/widgets/pulls\?state=closed*"&page=1")
      cat "${MC_REST_MERGED_P1:?}"
      exit 0
      ;;
    repos/acme/widgets/pulls\?state=closed*"&page=2")
      cat "${MC_REST_MERGED_P2:?}"
      exit 0
      ;;
    repos/acme/widgets/pulls\?state=open*"&page=1")
      cat "${MC_REST_OPEN_P1:?}"
      exit 0
      ;;
    *)
      echo "unhandled rest endpoint: $ep" >&2
      exit 1
      ;;
  esac
fi
if [ "${MC_GRAPHQL_403:-0}" = "1" ]; then
  echo "HTTP 403: GitHub GraphQL is not available from Claude Code sessions; use the REST API (gh api repos/{owner}/{repo}/...)" >&2
  exit 1
fi
if [ "${MC_OTHER_ERR:-0}" = "1" ]; then
  echo "error connecting to api.github.com" >&2
  exit 1
fi
case "${1:-} ${2:-}" in
  "pr view") cat "${MC_GQL_PR_FILE:?}" ;;
  "pr list")
    case "$*" in
      *"--state merged"*) cat "${MC_GQL_MERGED_FILE:?}" ;;
      *"--state open"*)   cat "${MC_GQL_OPEN_FILE:?}" ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$w/bin/gh"
}

# ── ケース 1: GraphQL 403 で REST フォールバック完走（same-repo MERGED + 取り残し削除 + open 保護）──
W1="$TMP/w1"
make_world "$W1" "fix/rest-ok"
OID1="$(git -C "$W1/repo" rev-parse HEAD)"
# 取り残しブランチと open PR 再利用ブランチを origin へ追加
(
  cd "$W1/repo"
  g checkout -q develop
  g checkout -q -b "fix/leftover-old"
  printf 'old\n' > old.txt; g add old.txt; g commit -qm "old"; g push -q origin "fix/leftover-old"
  g checkout -q develop
  g checkout -q -b "fix/reused-open"
  printf 'open\n' > open.txt; g add open.txt; g commit -qm "open"; g push -q origin "fix/reused-open"
  g checkout -q "fix/rest-ok"
)
OID_LEFT="$(git -C "$W1/repo" rev-parse refs/heads/fix/leftover-old)"
OID_OPEN="$(git -C "$W1/repo" rev-parse refs/heads/fix/reused-open)"
# develop を進めてマージ済み相当にする（origin/develop へ取り込む）
(
  cd "$W1/repo"
  g checkout -q develop
  g merge -q --no-ff "fix/rest-ok" -m "merge rest-ok"
  g push -q origin develop
  g checkout -q "fix/rest-ok"
)

jq -n --arg oid "$OID1" '{
  number: 101, state: "closed", merged: true, merged_at: "2026-11-20T00:00:00Z", draft: false,
  title: "fix: rest ok", body: "", html_url: "https://github.com/acme/widgets/pull/101",
  head: {ref: "fix/rest-ok", sha: $oid, repo: {id: 10, full_name: "acme/widgets"}},
  base: {ref: "develop", sha: $oid, repo: {id: 10, full_name: "acme/widgets"}}
}' > "$W1/stub/rest-pr.json"

# 1 ページ目に 100 件（未マージ closed PR を混ぜる）と 2 ページ目を用意してページングも検証
jq -n --arg oid1 "$OID1" --arg oido "$OID_OPEN" '
  [
    {number: 101, state: "closed", merged_at: "2026-11-20T00:00:00Z",
     head: {ref: "fix/rest-ok", sha: $oid1, repo: {id: 10, full_name: "acme/widgets"}},
     base: {ref: "develop", sha: $oid1, repo: {id: 10, full_name: "acme/widgets"}}},
    {number: 99, state: "closed", merged_at: null,
     head: {ref: "fix/closed-unmerged", sha: $oido, repo: {id: 10, full_name: "acme/widgets"}},
     base: {ref: "develop", sha: $oid1, repo: {id: 10, full_name: "acme/widgets"}}}
  ] + [range(0; 98) | {
    number: (200 + .), state: "closed", merged_at: null,
    head: {ref: ("closed/unmerged-" + tostring), sha: $oid1, repo: {id: 10, full_name: "acme/widgets"}},
    base: {ref: "develop", sha: $oid1, repo: {id: 10, full_name: "acme/widgets"}}
  }]' > "$W1/stub/rest-merged-p1.json"

# fix/reused-open は origin と同一の OID_OPEN を持たせ、open PR ガードが無いと本当に消える条件にする
jq -n --arg oidl "$OID_LEFT" --arg oido "$OID_OPEN" --arg oid1 "$OID1" '
  [
    {number: 88, state: "closed", merged_at: "2026-11-19T00:00:00Z",
     head: {ref: "fix/leftover-old", sha: $oidl, repo: {id: 10, full_name: "acme/widgets"}},
     base: {ref: "develop", sha: $oid1, repo: {id: 10, full_name: "acme/widgets"}}},
    {number: 89, state: "closed", merged_at: "2026-11-19T00:00:00Z",
     head: {ref: "fix/reused-open", sha: $oido, repo: {id: 10, full_name: "acme/widgets"}},
     base: {ref: "develop", sha: $oid1, repo: {id: 10, full_name: "acme/widgets"}}}
  ]' > "$W1/stub/rest-merged-p2.json"

jq -n '[{number: 102, state: "open", head: {ref: "fix/reused-open"}}]' > "$W1/stub/rest-open-p1.json"

: > "$W1/gh.log"
rc1=0
(
  cd "$W1/repo"
  PATH="$W1/bin:$PATH" \
  FF_MERGE_CLEANUP_PROJECTS_DIR="$W1/projects" \
  FF_MERGE_CLEANUP_TRANSCRIPT_ARCHIVE_DIR="$W1/archives" \
  MC_GH_LOG="$W1/gh.log" \
  MC_GRAPHQL_403=1 \
  MC_REST_PR_FILE="$W1/stub/rest-pr.json" \
  MC_REST_MERGED_P1="$W1/stub/rest-merged-p1.json" \
  MC_REST_MERGED_P2="$W1/stub/rest-merged-p2.json" \
  MC_REST_OPEN_P1="$W1/stub/rest-open-p1.json" \
  bash "$TARGET" 101 >"$W1/out.log" 2>&1
) || rc1=$?
if [ "$rc1" -eq 0 ] \
   && ! git -C "$W1/origin.git" show-ref --verify --quiet refs/heads/fix/rest-ok \
   && ! git -C "$W1/origin.git" show-ref --verify --quiet refs/heads/fix/leftover-old \
   && git -C "$W1/origin.git" show-ref --verify --quiet refs/heads/fix/reused-open \
   && grep -q 'repos/acme/widgets/pulls/101' "$W1/gh.log" \
   && grep -q 'pulls?state=closed&sort=created&direction=desc.*page=2' "$W1/gh.log" \
   && grep -q 'pulls?state=open' "$W1/gh.log"; then
  ok "GraphQL 403 + REST: PR 削除・sort=created 2 ページ目の取り残し削除・同一 OID open PR 保護まで完走する"
else
  bad "GraphQL 403 + REST 完走に失敗 (rc=$rc1)"
  sed 's/^/      | /' "$W1/out.log" >&2
fi

# ── ケース 2: REST で merged=false, merged_at=null, state=closed は CLOSED 扱い（破壊前に中断）──
W2="$TMP/w2"
make_world "$W2" "fix/closed-only"
OID2="$(git -C "$W2/repo" rev-parse HEAD)"
jq -n --arg oid "$OID2" '{
  number: 102, state: "closed", merged: false, merged_at: null, draft: false,
  title: "closed unmerged", body: "", html_url: "https://github.com/acme/widgets/pull/102",
  head: {ref: "fix/closed-only", sha: $oid, repo: {id: 10, full_name: "acme/widgets"}},
  base: {ref: "develop", sha: $oid, repo: {id: 10, full_name: "acme/widgets"}}
}' > "$W2/stub/rest-pr.json"
: > "$W2/gh.log"
rc2=0
(
  cd "$W2/repo"
  PATH="$W2/bin:$PATH" \
  FF_MERGE_CLEANUP_PROJECTS_DIR="$W2/projects" \
  FF_MERGE_CLEANUP_TRANSCRIPT_ARCHIVE_DIR="$W2/archives" \
  MC_GH_LOG="$W2/gh.log" \
  MC_GRAPHQL_403=1 \
  MC_REST_PR_FILE="$W2/stub/rest-pr.json" \
  bash "$TARGET" 102 >"$W2/out.log" 2>&1
) || rc2=$?
if [ "$rc2" -eq 1 ] && grep -q 'CLOSED 状態です（MERGED ではない）' "$W2/out.log" \
   && git -C "$W2/origin.git" show-ref --verify --quiet refs/heads/fix/closed-only; then
  ok "REST 正規化: merged=false の closed PR は CLOSED と判定し破壊的処理前に中断する"
else
  bad "REST 正規化: 未マージ closed PR を正しく中断しなかった (rc=$rc2)"
  sed 's/^/      | /' "$W2/out.log" >&2
fi

# ── ケース 3: head.repo == null（削除済み fork）は isCrossRepository=true（fail-closed で origin ブランチを消さない）──
W3="$TMP/w3"
make_world "$W3" "fix/deleted-fork"
OID3="$(git -C "$W3/repo" rev-parse HEAD)"
(
  cd "$W3/repo"
  g checkout -q develop
  g merge -q --no-ff "fix/deleted-fork" -m "merge fork"
  g push -q origin develop
  g checkout -q develop
)
jq -n --arg oid "$OID3" '{
  number: 103, state: "closed", merged: true, merged_at: "2026-11-20T00:00:00Z", draft: false,
  title: "fork PR", body: "", html_url: "https://github.com/acme/widgets/pull/103",
  head: {ref: "fix/deleted-fork", sha: $oid, repo: null},
  base: {ref: "develop", sha: $oid, repo: {id: 10, full_name: "acme/widgets"}}
}' > "$W3/stub/rest-pr.json"
jq -n '[]' > "$W3/stub/rest-merged-p1.json"
jq -n '[]' > "$W3/stub/rest-open-p1.json"
: > "$W3/gh.log"
rc3=0
(
  cd "$W3/repo"
  PATH="$W3/bin:$PATH" \
  FF_MERGE_CLEANUP_PROJECTS_DIR="$W3/projects" \
  FF_MERGE_CLEANUP_TRANSCRIPT_ARCHIVE_DIR="$W3/archives" \
  MC_GH_LOG="$W3/gh.log" \
  MC_GRAPHQL_403=1 \
  MC_REST_PR_FILE="$W3/stub/rest-pr.json" \
  MC_REST_MERGED_P1="$W3/stub/rest-merged-p1.json" \
  MC_REST_OPEN_P1="$W3/stub/rest-open-p1.json" \
  bash "$TARGET" 103 >"$W3/out.log" 2>&1
) || rc3=$?
if [ "$rc3" -eq 0 ] && grep -q 'fork からの PR です' "$W3/out.log" \
   && git -C "$W3/origin.git" show-ref --verify --quiet refs/heads/fix/deleted-fork; then
  ok "REST 正規化: head.repo が null のときは fail-closed で isCrossRepository=true とし origin ブランチを保護する"
else
  bad "REST 正規化: head.repo=null で origin ブランチを保護できなかった (rc=$rc3)"
  sed 's/^/      | /' "$W3/out.log" >&2
fi

# ── ケース 4: REST も失敗時は --github-input の最小 index JSON 手順を案内して中断 ──
: > "$W2/gh.log"
rc4=0
(
  cd "$W2/repo"
  PATH="$W2/bin:$PATH" \
  FF_MERGE_CLEANUP_PROJECTS_DIR="$W2/projects" \
  FF_MERGE_CLEANUP_TRANSCRIPT_ARCHIVE_DIR="$W2/archives" \
  MC_GH_LOG="$W2/gh.log" \
  MC_GRAPHQL_403=1 \
  MC_REST_FAIL=1 \
  bash "$TARGET" 102 >"$W2/rest-fail.log" 2>&1
) || rc4=$?
if [ "$rc4" -eq 1 ] && grep -qF -- '--github-input' "$W2/rest-fail.log" \
   && grep -qF '"operation":"cleanup.pr"' "$W2/rest-fail.log" \
   && grep -qF 'headRefName/headRefOid/baseRefName/title/isCrossRepository' "$W2/rest-fail.log"; then
  ok "REST も失敗時: --github-input と正規化必須フィールドを含む最小 index JSON 手順を案内して中断する"
else
  bad "REST も失敗時の --github-input 案内が不足 (rc=$rc4)"
  sed 's/^/      | /' "$W2/rest-fail.log" >&2
fi

# ── ケース 5: 非 GraphQL 403 エラーでは REST API を呼ばない（非回帰）──
: > "$W2/gh.log"
rc5=0
(
  cd "$W2/repo"
  PATH="$W2/bin:$PATH" \
  FF_MERGE_CLEANUP_PROJECTS_DIR="$W2/projects" \
  FF_MERGE_CLEANUP_TRANSCRIPT_ARCHIVE_DIR="$W2/archives" \
  MC_GH_LOG="$W2/gh.log" \
  MC_OTHER_ERR=1 \
  bash "$TARGET" 102 >"$W2/other-err.log" 2>&1
) || rc5=$?
if [ "$rc5" -eq 1 ] && ! grep -q '^api ' "$W2/gh.log"; then
  ok "非回帰: 通常の gh 通信エラーでは REST API へフォールバックしない"
else
  bad "非回帰: 通常エラーで不要に REST API を呼んでいる (rc=$rc5)"
fi

# ── ケース 6: open PR 一覧が 10 ページ（1,000 件）上限で打ち切られたら fail-closed（GUARDS_OK=0 で取り残しを消さない）──
W6="$TMP/w6"
make_world "$W6" "fix/rest-overflow"
OID6="$(git -C "$W6/repo" rev-parse HEAD)"
(
  cd "$W6/repo"
  g checkout -q develop
  g checkout -q -b "fix/should-stay-overflow"
  printf 'stay\n' > stay.txt; g add stay.txt; g commit -qm "stay"; g push -q origin "fix/should-stay-overflow"
  g checkout -q develop
  g merge -q --no-ff "fix/rest-overflow" -m "merge overflow"
  g push -q origin develop
  g checkout -q "fix/rest-overflow"
)
OID_STAY="$(git -C "$W6/repo" rev-parse refs/heads/fix/should-stay-overflow)"
jq -n --arg oid "$OID6" '{
  number: 106, state: "closed", merged: true, merged_at: "2026-11-20T00:00:00Z", draft: false,
  title: "overflow test", body: "", html_url: "https://github.com/acme/widgets/pull/106",
  head: {ref: "fix/rest-overflow", sha: $oid, repo: {id: 10, full_name: "acme/widgets"}},
  base: {ref: "develop", sha: $oid, repo: {id: 10, full_name: "acme/widgets"}}
}' > "$W6/stub/rest-pr.json"
jq -n --arg oids "$OID_STAY" --arg oid6 "$OID6" '[{
  number: 95, state: "closed", merged_at: "2026-11-19T00:00:00Z",
  head: {ref: "fix/should-stay-overflow", sha: $oids, repo: {id: 10, full_name: "acme/widgets"}},
  base: {ref: "develop", sha: $oid6, repo: {id: 10, full_name: "acme/widgets"}}
}]' > "$W6/stub/rest-merged-p1.json"
: > "$W6/gh.log"
rc6=0
(
  cd "$W6/repo"
  PATH="$W6/bin:$PATH" \
  FF_MERGE_CLEANUP_PROJECTS_DIR="$W6/projects" \
  FF_MERGE_CLEANUP_TRANSCRIPT_ARCHIVE_DIR="$W6/archives" \
  MC_GH_LOG="$W6/gh.log" \
  MC_GRAPHQL_403=1 \
  MC_REST_OPEN_OVERFLOW=1 \
  MC_REST_PR_FILE="$W6/stub/rest-pr.json" \
  MC_REST_MERGED_P1="$W6/stub/rest-merged-p1.json" \
  bash "$TARGET" 106 >"$W6/out.log" 2>&1
) || rc6=$?
if [ "$rc6" -eq 2 ] \
   && git -C "$W6/origin.git" show-ref --verify --quiet refs/heads/fix/should-stay-overflow \
   && grep -q '完全な一覧を確認できません' "$W6/out.log"; then
  ok "open PR 上限打ち切り: 1,000 件超の open PR 打ち切りを fail-closed（GUARDS_OK=0）で保護し取り残し削除を止める"
else
  bad "open PR 上限打ち切りで取り残しブランチ保護が効かなかった (rc=$rc6)"
  sed 's/^/      | /' "$W6/out.log" >&2
fi

# ── ケース 7: gh-rest-fallback.sh の単体契約（GH_REPO 優先・GH_HOST 非上書き・URL/ポート・403 非誤発火・10 ページ順・連続呼び出し非汚染）──
if bash -c '
  set -euo pipefail
  . "'"$GH_REST_LIB"'"
  # 7a. PR 番号 403 不在の GraphQL 404 に誤発火しない
  if ff_gh_is_graphql_unavailable "GraphQL: Could not resolve to a PullRequest with the number of 403."; then
    echo "FAIL: false positive on PR 403 404" >&2; exit 1
  fi
  if ! ff_gh_is_graphql_unavailable "HTTP 403: GitHub GraphQL is not available from Claude Code sessions; use the REST API"; then
    echo "FAIL: missed GraphQL 403" >&2; exit 1
  fi
  # 7b. GH_REPO は origin より優先される
  GH_REPO="acme/target" ff_gh_resolve_repo "" "'"$W1/repo"'"
  [ "$_ff_gh_resolved_repo" = "acme/target" ] || { echo "FAIL: GH_REPO ignored: $_ff_gh_resolved_repo" >&2; exit 1; }
  unset GH_REPO
  # 7c. github.com 明示リポジトリへ GH_HOST が誤上書きせず、実呼び出しで --hostname github.com を渡す
  GH_HOST="ghes.example.com" ff_gh_resolve_repo "" "'"$W1/repo"'"
  [ -z "$_ff_gh_resolved_host" ] && [ "$_ff_gh_resolved_repo" = "acme/widgets" ] || { echo "FAIL: GH_HOST leaked onto github.com: host=$_ff_gh_resolved_host" >&2; exit 1; }
  gh() { printf "%s\n" "$*"; }
  api_args="$(GH_HOST="ghes.example.com" _ff_gh_api "repos/acme/widgets/pulls/1" /dev/null)"
  [ "$api_args" = "api --hostname github.com repos/acme/widgets/pulls/1" ] || { echo "FAIL: explicit github.com missed --hostname under GH_HOST: $api_args" >&2; exit 1; }
  # owner/repo（ホスト未明示）のときだけ GH_HOST を補完する
  GH_HOST="ghes.example.com" ff_gh_resolve_repo "acme/widgets" "'"$W1/repo"'"
  [ "$_ff_gh_resolved_host" = "ghes.example.com" ] || { echo "FAIL: GH_HOST not applied to bare owner/repo" >&2; exit 1; }
  unset GH_HOST
  # 7g. gh repo set-default (remote.<name>.gh-resolved=base) を origin より優先し、base 不在の gh-resolved は fail-closed
  RDEF="'"$TMP"'/rdef"
  git init -q "$RDEF"
  git -C "$RDEF" remote add origin "https://github.com/forkuser/widgets.git"
  git -C "$RDEF" remote add upstream "https://github.com/acme/upstream-widgets.git"
  git -C "$RDEF" config remote.origin.gh-resolved other
  git -C "$RDEF" config remote.upstream.gh-resolved base
  ff_gh_resolve_repo "" "$RDEF"
  [ "$_ff_gh_resolved_repo" = "acme/upstream-widgets" ] || { echo "FAIL: gh-resolved=base ignored: $_ff_gh_resolved_repo" >&2; exit 1; }
  git -C "$RDEF" config --unset remote.upstream.gh-resolved
  if ff_gh_resolve_repo "" "$RDEF"; then
    echo "FAIL: non-base gh-resolved silently fell back to origin" >&2; exit 1
  fi
  # 7d. ポート付き URL・非 git@ ssh:// URL
  ff_gh_parse_repo_spec "ssh://deploy@github.com:443/acme/widgets.git"
  [ -z "$_ff_gh_resolved_host" ] && [ "$_ff_gh_resolved_repo" = "acme/widgets" ] || { echo "FAIL: ssh port parse failed: host=$_ff_gh_resolved_host repo=$_ff_gh_resolved_repo" >&2; exit 1; }
  ff_gh_parse_repo_spec "https://ghes.example.com:8443/acme/widgets.git"
  [ "$_ff_gh_resolved_host" = "ghes.example.com" ] && [ "$_ff_gh_resolved_repo" = "acme/widgets" ] || { echo "FAIL: https port parse failed: host=$_ff_gh_resolved_host" >&2; exit 1; }
  # 7e. 連続呼び出しで前リポジトリを引き継がない & リポジトリ名 pull の PR URL を解決できる
  gh() {
    if [ "$1" = "api" ]; then
      shift
      while [ "$1" = "--hostname" ]; do shift 2; done
      printf "{\"number\":42,\"state\":\"open\",\"merged\":false,\"merged_at\":null,\"title\":\"%s\",\"head\":{\"ref\":\"b\",\"sha\":\"a\",\"repo\":{\"id\":1}},\"base\":{\"ref\":\"d\",\"sha\":\"b\",\"repo\":{\"id\":1}}}\n" "$1"
      return 0
    fi
    return 1
  }
  out_u="$(ff_gh_rest_pr_view "https://github.com/acme/pull/pull/42" "" "'"$W1/repo"'" "'"$TMP/u.err"'")"
  [ "$(printf "%s" "$out_u" | jq -r .title)" = "repos/acme/pull/pulls/42" ] || { echo "FAIL: repo named pull URL failed: $out_u" >&2; exit 1; }
  out_n="$(ff_gh_rest_pr_view "42" "" "'"$W1/repo"'" "'"$TMP/n.err"'")"
  [ "$(printf "%s" "$out_n" | jq -r .title)" = "repos/acme/widgets/pulls/42" ] || { echo "FAIL: stale repo leaked: $out_n" >&2; exit 1; }
  # 7f. 11 ページ結合で 10 ページ目が 2 ページ目より前に来ない（ゼロ埋めページ順）
  gh() {
    if [ "$1" = "api" ]; then
      local ep="$2" pg="${2##*page=}"
      if [ "$pg" -le 10 ]; then
        jq -n --argjson p "$pg" "[range(0; 100) | {number: (\$p * 1000 + .), state: \"closed\", merged_at: (if . == 0 then \"2026-11-20T00:00:00Z\" else null end), head: {ref: (\"p\" + (\$p | tostring)), sha: \"abc\", repo: {id: 1}}, base: {ref: \"develop\", sha: \"def\", repo: {id: 1}}}]"
      else
        jq -n "[{number: 11000, state: \"closed\", merged_at: \"2026-11-20T00:00:00Z\", head: {ref: \"p11\", sha: \"abc\", repo: {id: 1}}, base: {ref: \"develop\", sha: \"def\", repo: {id: 1}}}]"
      fi
      return 0
    fi
    return 1
  }
  refs="$(ff_gh_rest_pr_list merged 1000 "acme/widgets" "'"$W1/repo"'" "'"$TMP/p11.err"'" | jq -r "[.[].headRefName] | join(\",\")")"
  [ "$refs" = "p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11" ] || { echo "FAIL: page order broken: $refs" >&2; exit 1; }
  # 7h. merged 一覧がページ上限で要求件数未満のまま打ち切られたら fail-closed
  gh() {
    if [ "$1" = "api" ]; then
      jq -n "[range(0; 100) | {number: (100 + .), state: \"closed\", merged_at: (if . == 0 then \"2026-11-20T00:00:00Z\" else null end), head: {ref: \"m\", sha: \"abc\", repo: {id: 1}}, base: {ref: \"develop\", sha: \"def\", repo: {id: 1}}}]"
      return 0
    fi
    return 1
  }
  if ff_gh_rest_pr_list merged 1000 "acme/widgets" "'"$W1/repo"'" "'"$TMP/mtrunc.err"'" >/dev/null; then
    echo "FAIL: truncated merged list under limit returned rc 0" >&2; exit 1
  fi
  grep -q "要求件数" "'"$TMP/mtrunc.err"'" || { echo "FAIL: missing truncation reason" >&2; exit 1; }
' 2>"$TMP/unit7.err"; then
  ok "単体契約: GH_REPO/gh-resolved 優先・GH_HOST 境界・ポート付き URL・リポ名 pull・403 誤発火防止・連続非汚染・11 ページ順・merged 打ち切り fail-closed"
else
  bad "gh-rest-fallback.sh 単体契約が失敗"
  sed 's/^/      | /' "$TMP/unit7.err" >&2
fi

REACHED_END=1
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
