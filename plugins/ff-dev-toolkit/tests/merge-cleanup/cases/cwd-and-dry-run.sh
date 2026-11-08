# shellcheck shell=bash
# pipefail-inherited: verify.sh が set -euo pipefail の下で source する
# 項目 45・46: linked worktree からの起動と dry-run / --help
#
# verify.sh から source される（ok / bad / TMP / TARGET / MOCK / PLUGIN_ROOT / SCRIPT_DIR を共有）。
# 読む順序は verify.sh の一覧が正本で、前の cases の fixture と関数を後ろの cases が使う（Issue `#2697`）。

# ---- 45. (Issue: linked worktree cwd) 対象 PR 自身の worktree からの起動 -------
#
# gh pr merge を PR の worktree で実行した直後、同じシェルで cleanup を呼ぶ動線。
# この cwd では掃除対象の worktree 自身を削除できず、base 復帰のために main tree を
# detached HEAD へ退避することになるため、破壊的処理の前に案内して中断する。

echo ""
echo "== (linked worktree cwd) 対象 PR 自身の worktree からの起動 =="

# 前段の状態に依存しないよう、呼び出し元 worktree を detach して develop を空ける
git -C "$CALLER" switch -q --detach
git -C "$BASE_OWNER" switch -q develop
git -C "$BASE_OWNER" fetch -q --prune origin
git -C "$BASE_OWNER" pull -q --ff-only origin develop

OWN_BRANCH='feature/#60-own-worktree'
OWN_WT="$TMP/wt-60"
git -C "$BASE_OWNER" branch -q "$OWN_BRANCH" develop
OID_OWN60="$(git -C "$BASE_OWNER" rev-parse "$OWN_BRANCH")"
git -C "$BASE_OWNER" push -q --no-verify -u origin "$OWN_BRANCH"
git -C "$BASE_OWNER" worktree add -q "$OWN_WT" "$OWN_BRANCH"

cat > "$MOCK/pr_view_60.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "$OWN_BRANCH",
  "headRefOid": "$OID_OWN60",
  "baseRefName": "develop",
  "title": "started from the PR own worktree",
  "isCrossRepository": false
}
JSON

jq --arg oid "$OID_OWN60" --arg name "$OWN_BRANCH" \
  '. + [{"headRefName": $name, "headRefOid": $oid, "isCrossRepository": false}]' \
  "$MOCK/pr_list_merged.json" > "$TMP/pr_list_merged.60.json"
mv "$TMP/pr_list_merged.60.json" "$MOCK/pr_list_merged.json"

# 45.1 対象 PR の worktree を cwd にした起動は、破壊的処理の前に案内して中断する
set +e
( cd "$OWN_WT" && PATH="$MOCK:$PATH" bash "$TARGET" 60 ) > "$TMP/run-own-wt.log" 2>&1
EXIT_OWN_WT=$?
set -e
if [ "$EXIT_OWN_WT" -eq 1 ] \
  && grep -qF "cd $CALLER && bash $TARGET 60" "$TMP/run-own-wt.log" \
  && grep -qF "$OWN_WT" "$TMP/run-own-wt.log" \
  && ! grep -q "マージ後 Cleanup 結果" "$TMP/run-own-wt.log" \
  && remote_has "$OWN_BRANCH" \
  && git -C "$BASE_OWNER" show-ref -q "refs/heads/$OWN_BRANCH" \
  && [ -d "$OWN_WT" ] \
  && [ "$(git -C "$OWN_WT" branch --show-current)" = "$OWN_BRANCH" ] \
  && [ "$(git -C "$BASE_OWNER" branch --show-current)" = "develop" ]; then
  ok "対象 PR の worktree からの起動は main tree を案内して中断し、何も削除しない"
else
  bad "対象 PR の worktree からの起動が期待どおりでない (exit=${EXIT_OWN_WT})"
fi

# 45.2 main tree からの起動は従来どおり完走し、対象 worktree ごと掃除する
set +e
( cd "$CALLER" && PATH="$MOCK:$PATH" bash "$TARGET" 60 ) > "$TMP/run-own-main.log" 2>&1
EXIT_OWN_MAIN=$?
set -e
if exit_is_complete "$EXIT_OWN_MAIN" \
  && grep -q "マージ後 Cleanup 結果" "$TMP/run-own-main.log" \
  && ! grep -q "対象 PR のワークツリーを cwd にして実行しています" "$TMP/run-own-main.log" \
  && ! remote_has "$OWN_BRANCH" \
  && ! git -C "$BASE_OWNER" show-ref -q "refs/heads/$OWN_BRANCH" \
  && [ ! -d "$OWN_WT" ]; then
  ok "main tree からの起動は従来どおり完走し、対象 worktree とブランチを削除する"
else
  bad "main tree からの起動が期待どおりでない (exit=${EXIT_OWN_MAIN})"
fi

# 45.3 main tree が bare で、cd 先として案内できるパスが取れない構成
#
# `git worktree list --porcelain` の先頭レコードが `bare` の場合、main tree のパスは
# cd 先にできない。ここで「案内できない = 検出しなかったことにする」と、掃除対象の
# worktree 自身を消せないまま黙って破壊的処理へ進む。案内の有無と中断の可否は別。
BARE_BRANCH='feature/#61-bare-main'
BARE_MAIN="$TMP/bare-main.git"
BARE_WT="$TMP/wt-61"
git -C "$BASE_OWNER" branch -q "$BARE_BRANCH" develop
OID_BARE61="$(git -C "$BASE_OWNER" rev-parse "$BARE_BRANCH")"
git -C "$BASE_OWNER" push -q --no-verify -u origin "$BARE_BRANCH"
git clone -q --bare "$TMP/origin.git" "$BARE_MAIN"
git -C "$BARE_MAIN" worktree add -q "$BARE_WT" "$BARE_BRANCH"

cat > "$MOCK/pr_view_61.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "$BARE_BRANCH",
  "headRefOid": "$OID_BARE61",
  "baseRefName": "develop",
  "title": "started from a linked worktree of a bare main repository",
  "isCrossRepository": false
}
JSON

set +e
( cd "$BARE_WT" && PATH="$MOCK:$PATH" bash "$TARGET" 61 ) > "$TMP/run-bare-main.log" 2>&1
EXIT_BARE_MAIN=$?
set -e
if [ "$EXIT_BARE_MAIN" -eq 1 ] \
  && grep -q "対象 PR のワークツリーを cwd にして実行しています" "$TMP/run-bare-main.log" \
  && grep -q "原因:" "$TMP/run-bare-main.log" \
  && grep -q "対処:" "$TMP/run-bare-main.log" \
  && ! grep -q " && bash " "$TMP/run-bare-main.log" \
  && ! grep -q "マージ後 Cleanup 結果" "$TMP/run-bare-main.log" \
  && remote_has "$BARE_BRANCH" \
  && [ -d "$BARE_WT" ] \
  && [ "$(git -C "$BARE_WT" branch --show-current)" = "$BARE_BRANCH" ]; then
  ok "main tree が bare でパスを案内できない場合も、素通しせず原因と対処を示して中断する"
else
  bad "bare main + linked worktree からの起動が期待どおりでない (exit=${EXIT_BARE_MAIN})"
fi

# 45.4 空白を含む main tree のパスを、そのまま貼って実行できる形で案内する
#
# 案内文の目視一致だけだと未引用でも「読める」ので回帰を素通しする。実際に shell へ
# 解釈させ、cd 先とスクリプトパスが元の値へ復元されることまで見る。
SPACE_MAIN="$TMP/main tree with space"
SPACE_BRANCH='feature/#62-space-path'
SPACE_WT="$TMP/wt-62"
git -C "$BASE_OWNER" branch -q "$SPACE_BRANCH" develop
OID_SPACE62="$(git -C "$BASE_OWNER" rev-parse "$SPACE_BRANCH")"
git -C "$BASE_OWNER" push -q --no-verify -u origin "$SPACE_BRANCH"
git clone -q "$TMP/origin.git" "$SPACE_MAIN"
git -C "$SPACE_MAIN" branch -q "$SPACE_BRANCH" "origin/$SPACE_BRANCH"
git -C "$SPACE_MAIN" worktree add -q "$SPACE_WT" "$SPACE_BRANCH"

cat > "$MOCK/pr_view_62.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "$SPACE_BRANCH",
  "headRefOid": "$OID_SPACE62",
  "baseRefName": "develop",
  "title": "the main worktree path contains spaces",
  "isCrossRepository": false
}
JSON

set +e
( cd "$SPACE_WT" && PATH="$MOCK:$PATH" bash "$TARGET" 62 ) > "$TMP/run-space-main.log" 2>&1
EXIT_SPACE_MAIN=$?
set -e

RERUN_LINE="$(sed -n 's/^  cd //p' "$TMP/run-space-main.log" | head -1)"
: > "$TMP/rerun-argv.txt"
set +e
(
  # eval 経由でのみ呼ばれるため shellcheck からは未使用に見える
  # shellcheck disable=SC2329
  cd()   { printf 'cd=%s\n'     "$1" >> "$TMP/rerun-argv.txt"; }
  # shellcheck disable=SC2329
  bash() { printf 'script=%s\n' "$1" >> "$TMP/rerun-argv.txt"
           printf 'arg=%s\n'    "$2" >> "$TMP/rerun-argv.txt"; }
  eval "cd ${RERUN_LINE}"
) >/dev/null 2>&1
set -e
# 期待値の cd 先は symlink 解決後のパスで持つ（macOS の $TMPDIR は /var -> /private/var
# の symlink で、git worktree list が返すのは解決後の側）。ここを生の $TMP のままに
# すると、引用の有無と関係なく毎回落ちる。
SPACE_MAIN_REAL="$(cd "$SPACE_MAIN" && pwd -P)"
printf 'cd=%s\nscript=%s\narg=%s\n' "$SPACE_MAIN_REAL" "$TARGET" 62 > "$TMP/rerun-argv.expected"

if [ "$EXIT_SPACE_MAIN" -eq 1 ] \
  && [ -n "$RERUN_LINE" ] \
  && cmp -s "$TMP/rerun-argv.txt" "$TMP/rerun-argv.expected" \
  && remote_has "$SPACE_BRANCH" \
  && [ -d "$SPACE_WT" ]; then
  ok "空白を含む main tree のパスも、貼って実行すれば同じパスへ解決する形で案内する"
else
  bad "空白入り main tree パスの案内が期待どおりでない (exit=${EXIT_SPACE_MAIN})"
fi

# ---- 46. (dry-run / --help) 破壊的処理を伴わない確認手段 -----------------------
#
# 破壊的ツールに無害な確認手段が無いと、「ガードが発火するところだけを見たい」検証者が
# ツールの全副作用を引き受けることになる（本件の発見元は、その結果として開発中の
# worktree が実際に削除された実測）。--dry-run の契約は「判定は実行時と同じ、副作用だけ
# が無い」で、--help は PR 番号として解釈されない。
#
# ここでは呼び出し元を detached、base (develop) を別 worktree が保持、という構成にする。
# 通常実行はこの構成で「呼び出し元を develop へ switch し、base 保持 worktree を detach
# する」ので、dry-run がそれを見送ったことを状態の差として観測できる。
#
# fixture は「dry-run の予告が実行時の削除より少なくなる」壊れ方を観測できる形にする:
#   - 対象 PR の head をローカルブランチ + worktree として残す
#     （実行時は 削除 → prune → [gone] → worktree ごと削除、と連鎖する）
#   - origin から既に消えているが追跡 ref だけ残っているブランチ + worktree
#     （実行時は Step 3 の fetch --prune で [gone] になり worktree ごと消える）
#   - 呼び出し元の HEAD を base の先端より前に置く
#     （実行時の `git branch -d` は switch / pull 後の HEAD で判定するため、
#       現在の HEAD を基準にすると dry-run だけ判定が食い違う）
#   - マージ後に同名ブランチが再利用された head / origin 側が既に消えている head
#     （どちらも実行時には削除されないので、予告に出してはいけない）

echo ""
echo "== (dry-run / --help) 破壊的処理を伴わない確認手段 =="

cd "$CALLER"
git switch -q --detach develop
git -C "$BASE_OWNER" switch -q develop

OID_DEVELOP_BEFORE="$(git rev-parse develop)"

# (a) 対象 PR の head。ローカルブランチと worktree を残す
DRY_TARGET='feature/dry-run-target'
git switch -q -c "$DRY_TARGET" develop
echo dry-run-target > dry-run-target.txt
git add dry-run-target.txt
git commit -qm "commit on the dry-run target"
OID_DRY_TARGET="$(git rev-parse HEAD)"
git push -q --no-verify -u origin "$DRY_TARGET"

# (b) マージ後に同名ブランチが再利用された head（origin の OID が PR head と違う）
DRY_REUSED='feature/dry-reused-head'
git switch -q -c "$DRY_REUSED" develop
echo reused > dry-reused.txt
git add dry-reused.txt
git commit -qm "head of the reused PR"
OID_DRY_REUSED="$(git rev-parse HEAD)"
git push -q --no-verify -u origin "$DRY_REUSED"
echo reused-again >> dry-reused.txt
git add dry-reused.txt
git commit -qm "pushed after the merge (branch reused)"
git push -q --no-verify origin "$DRY_REUSED"

# (c) origin 側が既に消えている head
DRY_ALREADY='feature/dry-already-removed'
git switch -q -c "$DRY_ALREADY" develop
echo already > dry-already.txt
git add dry-already.txt
git commit -qm "head of the already-removed PR"
OID_DRY_ALREADY="$(git rev-parse HEAD)"
git push -q --no-verify -u origin "$DRY_ALREADY"
git push -q --no-verify origin --delete "$DRY_ALREADY"

git switch -q --detach "$OID_DEVELOP_BEFORE"
git branch -q -D "$DRY_REUSED" "$DRY_ALREADY"
git worktree add -q "$TMP/wt-dry-chain" "$DRY_TARGET"

# base を 1 コミット進める。呼び出し元は進める前の位置で detached のままにするので、
# 「現在の HEAD」と「実行時に switch / pull した後の HEAD」が別物になる。
echo base-advance > "$BASE_OWNER/base-advance.txt"
git -C "$BASE_OWNER" add base-advance.txt
git -C "$BASE_OWNER" commit -qm "advance develop after the caller detached"
git -C "$BASE_OWNER" push -q --no-verify origin develop

if [ "$(git rev-parse refs/remotes/origin/develop)" = "$(git rev-parse develop)" ] \
  && [ "$(git rev-parse HEAD)" != "$(git rev-parse develop)" ]; then
  ok "fixture: 呼び出し元 HEAD が base の先端より前にある（-d 相当の判定基準の差を観測できる。self-test）"
else
  bad "fixture: 呼び出し元 HEAD と base 先端の差が作れていない — 判定基準の検証が空振りになる"
fi

# (d) [gone] + clean worktree（既に [gone]。通常実行では削除される）
add_clean_gone_worktree 'feature/dry-gone-clean' "$TMP/wt-dry-gone"
# (e) [gone] + dirty worktree（保護。dry-run でも同じ判定になること）
add_clean_gone_worktree 'feature/dry-gone-dirty' "$TMP/wt-dry-dirty"
echo work-in-progress > "$TMP/wt-dry-dirty/wip.txt"
# (f) origin からは消えているが、ローカルの追跡 ref だけが残っている（prune 前の状態）。
#     add_clean_gone_worktree の push --delete は追跡 ref も消すので、書き戻して再現する。
DRY_STALE='feature/dry-stale-upstream'
add_clean_gone_worktree "$DRY_STALE" "$TMP/wt-dry-stale"
git update-ref "refs/remotes/origin/${DRY_STALE}" "$(git rev-parse "refs/heads/${DRY_STALE}")"

if [ "$(git for-each-ref --format='%(upstream:track)' "refs/heads/${DRY_STALE}")" != '[gone]' ] \
  && [ "$(git for-each-ref --format='%(upstream:track)' "refs/heads/${DRY_TARGET}")" != '[gone]' ]; then
  ok "fixture: 連鎖対象の 2 本は今は [gone] ではない（予告が連鎖を予測できているかを観測できる。self-test）"
else
  bad "fixture: 連鎖対象が既に [gone] — 連鎖予告の検証が空振りになる"
fi

# git worktree list が返すのは symlink 解決後のパス（macOS の $TMPDIR は
# /var -> /private/var）。ログとの照合は解決後の綴りで持つ。
WT_GONE_REAL="$(cd "$TMP/wt-dry-gone" && pwd -P)"
WT_DIRTY_REAL="$(cd "$TMP/wt-dry-dirty" && pwd -P)"
WT_CHAIN_REAL="$(cd "$TMP/wt-dry-chain" && pwd -P)"
WT_STALE_REAL="$(cd "$TMP/wt-dry-stale" && pwd -P)"

write_pr_view_json() {
  # $1: 出力先 / $2: head 名 / $3: head OID / $4: タイトル
  cat > "$1" <<JSON
{
  "state": "MERGED",
  "headRefName": "$2",
  "headRefOid": "$3",
  "baseRefName": "develop",
  "title": "$4",
  "isCrossRepository": false
}
JSON
}

write_pr_view_json "$MOCK/pr_view_63.json" "$DRY_TARGET"  "$OID_DRY_TARGET"  "dry-run target PR"
write_pr_view_json "$MOCK/pr_view_64.json" "$DRY_REUSED"  "$OID_DRY_REUSED"  "PR whose head branch was reused after the merge"
write_pr_view_json "$MOCK/pr_view_65.json" "$DRY_ALREADY" "$OID_DRY_ALREADY" "PR whose head branch is already gone from origin"

jq --arg t "$DRY_TARGET"  --arg to "$OID_DRY_TARGET" \
   --arg r "$DRY_REUSED"  --arg ro "$OID_DRY_REUSED" \
   --arg a "$DRY_ALREADY" --arg ao "$OID_DRY_ALREADY" \
  '. + [{"headRefName": $t, "headRefOid": $to, "isCrossRepository": false},
        {"headRefName": $r, "headRefOid": $ro, "isCrossRepository": false},
        {"headRefName": $a, "headRefOid": $ao, "isCrossRepository": false}]' \
  "$MOCK/pr_list_merged.json" > "$TMP/pr_list_merged.dry.json"
mv "$TMP/pr_list_merged.dry.json" "$MOCK/pr_list_merged.json"

repo_state_snapshot() {
  # $1: 出力先。「dry-run の後にリポジトリ状態が不変であること」を実行ログの文言では
  # なく実測で固定するための材料。ブランチ・リモート追跡 ref・origin 上の ref・
  # worktree・両 worktree の HEAD・トランスクリプトとアーカイブをまとめて落とす。
  {
    echo "== local branches =="
    git for-each-ref --format='%(refname) %(objectname) %(upstream:track)' refs/heads/
    echo "== remote-tracking refs =="
    git for-each-ref --format='%(refname) %(objectname)' refs/remotes/
    echo "== origin refs =="
    git ls-remote --heads origin
    echo "== worktrees =="
    git worktree list --porcelain
    echo "== caller HEAD =="
    git rev-parse HEAD
    printf 'branch=%s\n' "$(git branch --show-current)"
    echo "== base owner HEAD =="
    git -C "$BASE_OWNER" rev-parse HEAD
    printf 'branch=%s\n' "$(git -C "$BASE_OWNER" branch --show-current)"
    echo "== transcripts =="
    ls -1 "$FF_MERGE_CLEANUP_PROJECTS_DIR" 2>/dev/null || true
    echo "== archives =="
    ls -1 "$FF_MERGE_CLEANUP_TRANSCRIPT_ARCHIVE_DIR" 2>/dev/null || true
    echo "== dry-run worktree files =="
    ls -1 "$TMP/wt-dry-gone" "$TMP/wt-dry-dirty" "$TMP/wt-dry-chain" "$TMP/wt-dry-stale" 2>/dev/null || true
  } > "$1"
}

guard_verdict_lines() {
  # $1: 実行ログ。ガードの判定行だけを取り出す（削除 push の成否は含めない）。
  # dry-run と通常実行でここが 1 行でも違えば、dry-run だけ判定が緩んでいる。
  grep -E 'skip \(保護ブランチ\)|skip \(設定保護パターン|worktree に未コミット変更があります' "$1" || true
}

predicted_branches() { sed -nE 's/^  ✓ \(dry-run\) 削除対象のブランチ: //p' "$1" | LC_ALL=C sort -u; }
predicted_worktrees() { sed -nE 's/^  ✓ \(dry-run\) 削除対象の worktree: //p' "$1" | LC_ALL=C sort -u; }
deleted_branches()   { sed -nE 's/^  ✓ branch deleted( \([^)]*\))?: //p' "$1" | LC_ALL=C sort -u; }
deleted_worktrees()  { sed -nE 's/^  ✓ worktree removed: //p' "$1" | LC_ALL=C sort -u; }

# 46.1 --help は使い方・破壊的処理の一覧・--dry-run の存在を出し、PR 番号として
#      解釈されない（= gh を一度も呼ばない）
: > "$TMP/gh-calls.log"
set +e
PATH="$MOCK:$PATH" bash "$TARGET" --help > "$TMP/run-help.log" 2>"$TMP/run-help.err"
EXIT_HELP=$?
set -e
if [ "$EXIT_HELP" -eq 0 ] \
  && grep -q '使い方:' "$TMP/run-help.log" \
  && grep -q -- '--dry-run' "$TMP/run-help.log" \
  && grep -q 'このスクリプトが削除するもの' "$TMP/run-help.log" \
  && grep -q 'リモートブランチ' "$TMP/run-help.log" \
  && grep -q 'worktree' "$TMP/run-help.log" \
  && [ ! -s "$TMP/gh-calls.log" ] \
  && ! grep -q 'マージ後 Cleanup 結果' "$TMP/run-help.log"; then
  ok "--help は使い方と破壊的処理の一覧を表示し、PR 番号として解釈しない（gh を呼ばない）"
else
  bad "--help の挙動が期待どおりでない (exit=${EXIT_HELP})"
fi

# 46.1b --help は mktemp と gh / jq の存在確認より前に効く。使い方をいちばん知りたい
#       環境（依存未導入・TMPDIR 書き込み不可）で usage が出ないのが元の壊れ方。
NODEPS_BIN="$TMP/nodeps-bin"
mkdir -p "$NODEPS_BIN"
NODEPS_OK=1
for _c in bash cat mktemp rm; do
  _p="$(command -v "$_c" 2>/dev/null || true)"
  if [ -n "$_p" ]; then ln -sf "$_p" "$NODEPS_BIN/$_c"; else NODEPS_OK=0; fi
done
# 在否の確認は必ず新しいシェルで行う。本 suite は jq を直接呼んでいるため、
# 現在のシェルの command hash に残った実体が PATH の差し替えより優先され、
# 「不在の PATH」を用意できたのに見つかったことになる（実測）。
if [ "$NODEPS_OK" = "1" ] && ! PATH="$NODEPS_BIN" bash -c 'command -v gh' >/dev/null 2>&1 \
  && ! PATH="$NODEPS_BIN" bash -c 'command -v jq' >/dev/null 2>&1; then
  ok "gh / jq を含まない PATH を用意できた（self-test）"
else
  bad "gh / jq 不在の PATH を用意できない — 依存より前かどうかの検証が空振りになる"
fi
set +e
PATH="$NODEPS_BIN" bash "$TARGET" --help > "$TMP/run-help-nodeps.log" 2>&1
EXIT_HELP_NODEPS=$?
TMPDIR="$TMP/no-such-tmpdir" PATH="$MOCK:$PATH" bash "$TARGET" --help > "$TMP/run-help-notmp.log" 2>&1
EXIT_HELP_NOTMP=$?
set -e
if [ "$EXIT_HELP_NODEPS" -eq 0 ] && grep -q '使い方:' "$TMP/run-help-nodeps.log" \
  && [ "$EXIT_HELP_NOTMP" -eq 0 ] && grep -q '使い方:' "$TMP/run-help-notmp.log"; then
  ok "gh / jq 未導入・TMPDIR 書き込み不可でも --help は usage を出して 0 で終わる（解析が依存確認より前）"
else
  bad "依存不在環境で --help が usage を出さない (nodeps=${EXIT_HELP_NODEPS}, notmpdir=${EXIT_HELP_NOTMP})"
  { tail -5 "$TMP/run-help-nodeps.log" | sed 's/^/     /' >&2 || true; }
fi

# 46.2 引数なし（--dry-run だけの場合も含む）は使い方を表示して非 0 で終わる
: > "$TMP/gh-calls.log"
set +e
PATH="$MOCK:$PATH" bash "$TARGET" > "$TMP/run-noargs.log" 2>&1
EXIT_NOARGS=$?
PATH="$MOCK:$PATH" bash "$TARGET" --dry-run > "$TMP/run-dryonly.log" 2>&1
EXIT_DRYONLY=$?
set -e
if [ "$EXIT_NOARGS" -eq 1 ] && [ "$EXIT_DRYONLY" -eq 1 ] \
  && grep -q 'PR 番号を指定してください' "$TMP/run-noargs.log" \
  && grep -q '使い方:' "$TMP/run-noargs.log" \
  && grep -q '使い方:' "$TMP/run-dryonly.log" \
  && [ ! -s "$TMP/gh-calls.log" ]; then
  ok "引数なしは使い方を表示して exit 1 で終わる（--dry-run だけの指定も同じ）"
else
  bad "引数なしの扱いが期待どおりでない (noargs=${EXIT_NOARGS}, dryonly=${EXIT_DRYONLY})"
fi

# 46.3 --dry-run は削除対象を一覧表示し、リポジトリ状態を 1 つも変えない
repo_state_snapshot "$TMP/state-before-dry.txt"
set +e
PATH="$MOCK:$PATH" bash "$TARGET" --dry-run 63 > "$TMP/run-dry-63.log" 2>&1
EXIT_DRY=$?
set -e
repo_state_snapshot "$TMP/state-after-dry.txt"

if exit_is_complete "$EXIT_DRY" \
  && grep -q 'マージ後 Cleanup 結果' "$TMP/run-dry-63.log" \
  && grep -qF "リモートブランチ削除（対象）: ${DRY_TARGET}" "$TMP/run-dry-63.log" \
  && grep -qF '削除対象のブランチ: feature/dry-gone-clean' "$TMP/run-dry-63.log" \
  && grep -qF "削除対象の worktree: ${WT_GONE_REAL}" "$TMP/run-dry-63.log" \
  && grep -qF '✓ (dry-run) 削除対象の取り残し:' "$TMP/run-dry-63.log" \
  && grep -qF 'は Step 4 の削除対象です' "$TMP/run-dry-63.log"; then
  ok "--dry-run は削除対象（リモートブランチ / ローカルブランチ / worktree / 取り残し）を一覧表示する"
else
  bad "--dry-run の一覧表示が期待どおりでない (exit=${EXIT_DRY})"
  { tail -30 "$TMP/run-dry-63.log" | sed 's/^/     /' >&2 || true; }
fi

# 46.3b 見送った prune / リモート削除の**連鎖**も予告に入る。ここが落ちると、
#       dry-run に出ていないブランチ・worktree が実行すると消える（最も危険な壊れ方）。
if grep -qF "削除対象のブランチ: ${DRY_TARGET}" "$TMP/run-dry-63.log" \
  && grep -qF "削除対象の worktree: ${WT_CHAIN_REAL}" "$TMP/run-dry-63.log" \
  && grep -qF "削除対象のブランチ: ${DRY_STALE}" "$TMP/run-dry-63.log" \
  && grep -qF "削除対象の worktree: ${WT_STALE_REAL}" "$TMP/run-dry-63.log" \
  && grep -q '新たに \[gone\] になるブランチを予告へ含めます' "$TMP/run-dry-63.log"; then
  ok "--dry-run は「リモート削除 / prune → 新たに [gone] → その worktree」の連鎖も予告する"
else
  bad "--dry-run が prune 連鎖で消えるブランチ / worktree を予告していない"
  { grep -nE '削除対象|gone' "$TMP/run-dry-63.log" | head -20 | sed 's/^/     /' >&2 || true; }
fi

if cmp -s "$TMP/state-before-dry.txt" "$TMP/state-after-dry.txt"; then
  ok "--dry-run の後もブランチ・worktree・リモート参照が 1 つも変化していない"
else
  bad "--dry-run がリポジトリ状態を変更した"
  { diff "$TMP/state-before-dry.txt" "$TMP/state-after-dry.txt" | head -20 | sed 's/^/     /' >&2 || true; }
fi

if remote_has "$DRY_TARGET" \
  && git show-ref -q "refs/heads/feature/dry-gone-clean" \
  && [ -d "$TMP/wt-dry-gone" ] \
  && [ -d "$TMP/wt-dry-chain" ] \
  && [ -z "$(git branch --show-current)" ] \
  && [ "$(git -C "$BASE_OWNER" branch --show-current)" = "develop" ]; then
  ok "--dry-run は削除対象に挙げたものを実際には消さず、base 復帰のための detach も行わない"
else
  bad "--dry-run が削除・切り替えを実行している"
fi

# 46.4 ガード（保護ブランチ・dirty worktree）の判定が通常実行と同じ
if grep -qF "worktree に未コミット変更があります。削除をスキップします: ${WT_DIRTY_REAL}" "$TMP/run-dry-63.log" \
  && grep -qF 'skip (保護ブランチ): staging/keep' "$TMP/run-dry-63.log"; then
  ok "--dry-run でも dirty worktree と保護ブランチのガードが発火する"
else
  bad "--dry-run のガード発火が期待どおりでない"
fi

# 46.5 fail-closed な縮退（ガード情報の取得失敗）も実行時と同じ判定になる
: > "$TMP/ghfail-merged.enabled"
repo_state_snapshot "$TMP/state-before-failclosed.txt"
set +e
PATH="$MOCK:$PATH" bash "$TARGET" --dry-run 63 > "$TMP/run-dry-failclosed.log" 2>&1
EXIT_DRY_FAILCLOSED=$?
set -e
repo_state_snapshot "$TMP/state-after-failclosed.txt"
rm -f "$TMP/ghfail-merged.enabled"

if [ "$EXIT_DRY_FAILCLOSED" -eq 2 ] \
  && grep -q 'マージ済み PR 一覧の取得に失敗しました（fail-closed で縮退）' "$TMP/run-dry-failclosed.log" \
  && grep -q 'リモートブランチ削除をスキップします（fail-closed）' "$TMP/run-dry-failclosed.log" \
  && grep -q '取り残し検証をスキップします（fail-closed）' "$TMP/run-dry-failclosed.log" \
  && ! grep -qF 'リモートブランチ削除（対象）' "$TMP/run-dry-failclosed.log" \
  && ! grep -qF '削除対象の取り残し' "$TMP/run-dry-failclosed.log" \
  && cmp -s "$TMP/state-before-failclosed.txt" "$TMP/state-after-failclosed.txt"; then
  ok "--dry-run でも fail-closed な縮退は同じで、削除対象として挙げない（判定が緩まない）"
else
  bad "--dry-run の fail-closed 縮退が期待どおりでない (exit=${EXIT_DRY_FAILCLOSED})"
  { tail -20 "$TMP/run-dry-failclosed.log" | sed 's/^/     /' >&2 || true; }
fi

# 46.6 origin 上の ref を確認せずに「実行時は削除する」と書かない。
#      実行時の削除は --force-with-lease で OID を照合するので、再利用された同名
#      ブランチ（OID 不一致）と既に消えた ref は実行しても削除されない。
repo_state_snapshot "$TMP/state-before-verdict.txt"
set +e
PATH="$MOCK:$PATH" bash "$TARGET" --dry-run 64 > "$TMP/run-dry-64.log" 2>&1
EXIT_DRY_REUSED=$?
PATH="$MOCK:$PATH" bash "$TARGET" --dry-run 65 > "$TMP/run-dry-65.log" 2>&1
EXIT_DRY_ALREADY=$?
set -e
repo_state_snapshot "$TMP/state-after-verdict.txt"

if exit_is_complete "$EXIT_DRY_REUSED" \
  && grep -qF "${DRY_REUSED} はマージ後に更新されています" "$TMP/run-dry-64.log" \
  && ! grep -qF "リモートブランチ削除（対象）: ${DRY_REUSED}" "$TMP/run-dry-64.log" \
  && exit_is_complete "$EXIT_DRY_ALREADY" \
  && grep -qF "origin に ${DRY_ALREADY} は既にありません" "$TMP/run-dry-65.log" \
  && ! grep -qF "リモートブランチ削除（対象）: ${DRY_ALREADY}" "$TMP/run-dry-65.log" \
  && cmp -s "$TMP/state-before-verdict.txt" "$TMP/state-after-verdict.txt"; then
  ok "--dry-run は origin の ref を read-only で照合し、OID 不一致 / 既に無い head を削除対象にしない"
else
  bad "--dry-run のリモート ref 照合が期待どおりでない (reused=${EXIT_DRY_REUSED}, already=${EXIT_DRY_ALREADY})"
  { grep -nE 'リモートブランチ|既にありません|更新されています' "$TMP/run-dry-64.log" "$TMP/run-dry-65.log" | head -10 | sed 's/^/     /' >&2 || true; }
fi

# 46.7 変異テスト（すべて dry-run のみ。通常実行の前に走らせて、比較材料を揃える）
stage_cleanup_mutant "$TMP/mutant-chain"
stage_cleanup_mutant "$TMP/mutant-verdict"
stage_cleanup_mutant "$TMP/mutant-baseref"
sed 's|^dry_virtual_prune_gone_branches() {$|dry_virtual_prune_gone_branches() { return 0|' \
  "$TMP/mutant-chain/merge-cleanup.sh" > "$TMP/mutant-chain/merge-cleanup.new"
mv "$TMP/mutant-chain/merge-cleanup.new" "$TMP/mutant-chain/merge-cleanup.sh"
sed 's|^remote_delete_verdict() {$|remote_delete_verdict() { printf "match\\t%s\\n" "$2"; return 0|' \
  "$TMP/mutant-verdict/merge-cleanup.sh" > "$TMP/mutant-verdict/merge-cleanup.new"
mv "$TMP/mutant-verdict/merge-cleanup.new" "$TMP/mutant-verdict/merge-cleanup.sh"
sed 's|"\$DRY_MERGED_BASE_REF"|HEAD|g' \
  "$TMP/mutant-baseref/lib/merge-cleanup-local.sh" > "$TMP/mutant-baseref/lib/merge-cleanup-local.new"
mv "$TMP/mutant-baseref/lib/merge-cleanup-local.new" "$TMP/mutant-baseref/lib/merge-cleanup-local.sh"
MUTANT_CHAIN="$TMP/mutant-chain/merge-cleanup.sh"
MUTANT_VERDICT="$TMP/mutant-verdict/merge-cleanup.sh"
MUTANT_BASEREF="$TMP/mutant-baseref/merge-cleanup.sh"
if ! cmp -s "$TARGET" "$MUTANT_CHAIN" && ! cmp -s "$TARGET" "$MUTANT_VERDICT" \
  && ! cmp -s "$PLUGIN_ROOT/scripts/lib/merge-cleanup-local.sh" "$TMP/mutant-baseref/lib/merge-cleanup-local.sh"; then
  ok "mutant 3 種を生成できた（連鎖予告なし / OID 照合なし / -d の基準を現在 HEAD へ。self-test）"
else
  bad "mutant が原本と同一 — 変異テストは何も検証していない"
fi

set +e
PATH="$MOCK:$PATH" bash "$MUTANT_CHAIN"   --dry-run 63 > "$TMP/run-dry-63-mut-chain.log" 2>&1
PATH="$MOCK:$PATH" bash "$MUTANT_BASEREF" --dry-run 63 > "$TMP/run-dry-63-mut-baseref.log" 2>&1
PATH="$MOCK:$PATH" bash "$MUTANT_VERDICT" --dry-run 64 > "$TMP/run-dry-64-mut-verdict.log" 2>&1
PATH="$MOCK:$PATH" bash "$MUTANT_VERDICT" --dry-run 65 > "$TMP/run-dry-65-mut-verdict.log" 2>&1
set -e

if grep -qF "リモートブランチ削除（対象）: ${DRY_REUSED}" "$TMP/run-dry-64-mut-verdict.log" \
  && grep -qF "リモートブランチ削除（対象）: ${DRY_ALREADY}" "$TMP/run-dry-65-mut-verdict.log"; then
  ok "mutant（OID 照合なし）は再利用 / 削除済みの head を過剰予告する = 46.6 が mutant を赤にできる"
else
  bad "mutant（OID 照合なし）の過剰予告が観測できない — 46.6 の検出力は主張できない"
fi

if grep -qF "${DRY_STALE} はマージ済み PR の head と OID 一致しません" "$TMP/run-dry-63-mut-baseref.log" \
  && ! grep -qF "削除対象のブランチ: ${DRY_STALE}" "$TMP/run-dry-63-mut-baseref.log"; then
  ok "mutant（-d の基準を現在 HEAD へ）は base 先端でマージ済みのブランチを予告から落とす = 判定基準の検証が mutant を赤にできる"
else
  bad "mutant（-d の基準を現在 HEAD へ）の退行が観測できない"
  { grep -nE "${DRY_STALE}" "$TMP/run-dry-63-mut-baseref.log" | head -10 | sed 's/^/     /' >&2 || true; }
fi

# 46.8 --dry-run を外した通常実行は従来どおり削除し、終了コード契約も変わらない。
#      あわせて 46.3 の snapshot が「変化を検出できる」ことの self-test にする
#      （検出できない snapshot なら、不変の主張は空振りになる）。
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 63 > "$TMP/run-real-63.log" 2>&1
EXIT_REAL=$?
set -e
repo_state_snapshot "$TMP/state-after-real.txt"

if exit_is_complete "$EXIT_REAL" \
  && ! remote_has "$DRY_TARGET" \
  && ! git show-ref -q "refs/heads/feature/dry-gone-clean" \
  && ! git show-ref -q "refs/heads/${DRY_TARGET}" \
  && ! git show-ref -q "refs/heads/${DRY_STALE}" \
  && [ ! -d "$TMP/wt-dry-gone" ] \
  && [ ! -d "$TMP/wt-dry-chain" ] \
  && [ ! -d "$TMP/wt-dry-stale" ] \
  && [ -d "$TMP/wt-dry-dirty" ] \
  && git show-ref -q "refs/heads/feature/dry-gone-dirty" \
  && ! cmp -s "$TMP/state-before-dry.txt" "$TMP/state-after-real.txt"; then
  ok "通常実行は従来どおり削除し、dry-run では不変だった状態が実際に変わる（snapshot の self-test）"
else
  bad "--dry-run なしの通常実行が期待どおりでない (exit=${EXIT_REAL})"
  { tail -30 "$TMP/run-real-63.log" | sed 's/^/     /' >&2 || true; }
fi

# 46.9 予告は実行時の削除を **1 つも取りこぼしていない**（実測の包含関係）。
#      --dry-run の唯一の価値は「何が壊れるかを先に見せる」ことなので、
#      予告が実際より少ないことが本質的な壊れ方。mutant では包含が破れる。
predicted_branches  "$TMP/run-dry-63.log"  > "$TMP/dry-branches.txt"
predicted_worktrees "$TMP/run-dry-63.log"  > "$TMP/dry-worktrees.txt"
deleted_branches    "$TMP/run-real-63.log" > "$TMP/real-branches.txt"
deleted_worktrees   "$TMP/run-real-63.log" > "$TMP/real-worktrees.txt"
MISSED_BRANCHES="$(LC_ALL=C comm -13 "$TMP/dry-branches.txt" "$TMP/real-branches.txt")"
MISSED_WORKTREES="$(LC_ALL=C comm -13 "$TMP/dry-worktrees.txt" "$TMP/real-worktrees.txt")"
if [ ! -s "$TMP/real-branches.txt" ] || [ ! -s "$TMP/real-worktrees.txt" ]; then
  bad "通常実行のログから削除済みブランチ / worktree を取り出せない — 包含比較が空振りになる"
elif [ -z "$MISSED_BRANCHES" ] && [ -z "$MISSED_WORKTREES" ]; then
  ok "通常実行が削除したブランチ / worktree は 1 つ残らず --dry-run の予告に載っていた"
else
  bad "--dry-run の予告に載っていないものが通常実行で削除された"
  { printf '%s\n' "$MISSED_BRANCHES" "$MISSED_WORKTREES" | sed 's/^/     /' >&2 || true; }
fi

predicted_branches  "$TMP/run-dry-63-mut-chain.log" > "$TMP/mut-chain-branches.txt"
predicted_worktrees "$TMP/run-dry-63-mut-chain.log" > "$TMP/mut-chain-worktrees.txt"
if [ -n "$(LC_ALL=C comm -13 "$TMP/mut-chain-branches.txt" "$TMP/real-branches.txt")" ] \
  && [ -n "$(LC_ALL=C comm -13 "$TMP/mut-chain-worktrees.txt" "$TMP/real-worktrees.txt")" ]; then
  ok "mutant（連鎖予告なし）では予告が通常実行の削除より少なくなる = 46.9 が mutant を赤にできる"
else
  bad "mutant（連鎖予告なし）の取りこぼしが観測できない — 46.9 の検出力は主張できない"
fi

# 46.10 変異テスト: --help の解析を依存確認の後ろへ戻した mutant は、gh / jq 不在で
#       usage を出さずに落ちる（46.1b の判定が mutant を赤にできる）。
MUTANT_DEPORDER="$TMP/merge-cleanup-mutant-deporder.sh"
awk '
  !moved && /^# ---- Step 0: 引数/ {
    print "WORK_TMP_MUTANT=\"$(mktemp -d)\" || die \"mktemp -d に失敗しました\""
    print "command -v gh >/dev/null 2>&1 || die \"gh CLI が必要です\""
    print "command -v jq >/dev/null 2>&1 || die \"jq が必要です\""
    moved = 1
  }
  { print }
' "$TARGET" > "$MUTANT_DEPORDER"
set +e
PATH="$NODEPS_BIN" bash "$MUTANT_DEPORDER" --help > "$TMP/run-help-nodeps-mutant.log" 2>&1
EXIT_HELP_NODEPS_MUT=$?
set -e
if ! cmp -s "$TARGET" "$MUTANT_DEPORDER" \
  && [ "$EXIT_HELP_NODEPS_MUT" -ne 0 ] \
  && ! grep -q '使い方:' "$TMP/run-help-nodeps-mutant.log"; then
  ok "mutant（依存確認を --help より前へ）は gh 不在で usage を出さず落ちる = 46.1b が mutant を赤にできる"
else
  bad "mutant（依存確認の順序）の退行が観測できない (exit=${EXIT_HELP_NODEPS_MUT})"
fi

guard_verdict_lines "$TMP/run-dry-63.log" > "$TMP/dry-guards.txt"
guard_verdict_lines "$TMP/run-real-63.log" > "$TMP/real-guards.txt"
if [ ! -s "$TMP/dry-guards.txt" ]; then
  bad "dry-run のログからガード判定行を取り出せない — 一致比較が空振りになる"
elif cmp -s "$TMP/dry-guards.txt" "$TMP/real-guards.txt"; then
  ok "--dry-run のガード判定は通常実行と 1 行も違わない（dry-run だけ緩まない）"
else
  bad "--dry-run のガード判定が通常実行と食い違う"
  { diff "$TMP/dry-guards.txt" "$TMP/real-guards.txt" | head -20 | sed 's/^/     /' >&2 || true; }
fi

# 46.9 (公開 ff-dev-toolkit#137) 通常実行の削除前の照合が、dry-run と同じ判定関数
#      （remote_delete_verdict）を通ることの検出力。46.7 の mutant（判定を常に match に
#      する）を --dry-run を外して、head が既に無い PR 65 に走らせる。原本は push せず、
#      mutant は削除 push を実行する — 通常実行が別の判定を持っていれば mutant は通常
#      実行を変えられず、この差は出ない。他の run の前提を崩さないよう suite の最後に置く。
PUSH_LINES_BEFORE_65="$(push_calls_lines)"
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 65 > "$TMP/run-real-65.log" 2>&1
set -e
# 原本の件数は mutant を走らせる前に確定させる（後から数えると mutant の push まで含む）
PUSH_CALLS_65="$(push_calls_for "$DRY_ALREADY" "$PUSH_LINES_BEFORE_65")"
PUSH_LINES_BEFORE_65M="$(push_calls_lines)"
set +e
PATH="$MOCK:$PATH" bash "$MUTANT_VERDICT" 65 > "$TMP/run-real-65-mut-verdict.log" 2>&1
set -e
PUSH_CALLS_65M="$(push_calls_for "$DRY_ALREADY" "$PUSH_LINES_BEFORE_65M")"
if [ "$PUSH_CALLS_65" -eq 0 ] \
  && grep -qF "削除前の照合（git ls-remote）: origin に ${DRY_ALREADY} が無いため" "$TMP/run-real-65.log" \
  && [ "$PUSH_CALLS_65M" -ge 1 ]; then
  ok "通常実行の削除前の照合は dry-run と同じ判定関数を通る（常時 match の mutant だけが消えた ref へ push する）"
else
  bad "通常実行と dry-run の実在判定が同じ関数を通っていない、または mutant の差が観測できない (original=${PUSH_CALLS_65} mutant=${PUSH_CALLS_65M})"
fi

# suite-cases-end: cwd-and-dry-run.sh
