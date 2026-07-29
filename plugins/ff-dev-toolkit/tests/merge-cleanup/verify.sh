#!/usr/bin/env bash
#
# merge-cleanup.sh の破壊的経路の回帰テスト。
#
# 一時 git リポジトリ（bare origin + clone）と mock gh で以下を検証する:
#   1. 対象 PR のリモートブランチが削除される（OID 一致）
#   2. 取り残し: (名前, OID) 一致のマージ済みブランチは削除される
#   3. 取り残し: 名前一致でも OID 不一致（マージ後 push あり）は削除されない
#   4. 取り残し: open PR の head として再利用中は削除されない
#   5. 取り残し: 保護ブランチ（release/*）は照合一致でも削除されない
#   6. dirty worktree 付き [gone] ブランチは保護され、終了コードが 2（PARTIAL）になる
#   7. 未マージの固有コミットを持つ [gone] ブランチ（手動リモート削除由来）は -D されない
#   8. 対象 PR が MERGED でない場合、破壊的処理の前に exit 1 で中断する
#   9. base を保持する別 worktree が dirty なら変更せず exit 1 で中断する
#  10. base を保持する別 worktree が clean なら、worktree と ignored file を残したまま
#      detached へ退避し、呼び出し元が最新 base ブランチへ復帰する
#  11. 対象 PR のリモートブランチが既に無い場合は、lease 拒否と誤判定しない
#  12. 対象 PR のリモートブランチが別 OID で存在する場合は、lease 拒否として保護する
#  13. lease 拒否後の ref 再取得に失敗した場合は fail-closed で停止する
#  14. lease 拒否後の ref が期待 OID のままなら、原因不明として fail-closed で停止する
#  15. ref 再取得が成功し stderr に警告だけ出ても、空の stdout を存在と誤判定しない
#
# 書き込み不可の環境（read-only チェックアウト等）では skip して成功扱いにする。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$PLUGIN_ROOT/scripts/merge-cleanup.sh"

[ -f "$TARGET" ] || { echo "✗ merge-cleanup.sh が見つかりません: $TARGET" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "✗ jq が必要です" >&2; exit 1; }

if ! TMP="$(mktemp -d 2>/dev/null)"; then
  echo "○ skip: 一時ディレクトリを作成できない環境（read-only）のためスキップ"
  exit 0
fi
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()   { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad()  { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# ---- fixture: bare origin + clone --------------------------------------------

git init --bare -q "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/work"
cd "$TMP/work"
git config user.email "test@example.com"
git config user.name "merge-cleanup-test"
git config commit.gpgsign false

git switch -q -c develop
echo base > README.md
git add README.md
git commit -qm "init"
git push -qu origin develop

new_branch_with_commit() {
  # $1: branch name / $2: file marker。作成後 develop に戻り、コミット OID を出力する
  git switch -q -c "$1" develop
  echo "$2" > "$2.txt"
  git add "$2.txt"
  git commit -qm "commit on $1"
  git rev-parse HEAD
  git push -qu origin "$1"
  git switch -q develop
}

OID_TARGET="$(new_branch_with_commit 'feature/#10-target' target)"
OID_EXACT="$(new_branch_with_commit 'feature/#1-merged-exact' exact)"
OID_OPEN="$(new_branch_with_commit 'feature/#3-open-reuse' openreuse)"
OID_RELEASE="$(new_branch_with_commit 'release/1.0' release)"

# lease 拒否後の再取得で「期待 OID のまま存在」を再現する branch。
OID_SAME="$(git rev-parse develop)"
git branch 'feature/#15-same-oid' "$OID_SAME"
git push -qu origin 'feature/#15-same-oid'
git branch -q -D 'feature/#15-same-oid'

# 名前再利用ケース: マージ済み PR の head OID の後に、さらに push が積まれている
git switch -q -c 'feature/#2-reused' develop
echo reused-merged > reused.txt
git add reused.txt
git commit -qm "merged head of reused"
OID_REUSED_MERGED="$(git rev-parse HEAD)"
echo reused-extra > reused2.txt
git add reused2.txt
git commit -qm "new work pushed after merge"
git push -qu origin 'feature/#2-reused'
git switch -q develop

# 取り残し系はローカルブランチを消してリモートだけ残す（過去のマージ漏れを再現）
git branch -q -D 'feature/#1-merged-exact' 'feature/#2-reused' 'feature/#3-open-reuse' 'release/1.0'

# dirty worktree 付き [gone] ブランチ: リモートを先に消して prune 対象にする
git worktree add -q "$TMP/wt-dirty" 'feature/#10-target' 2>/dev/null || \
  git worktree add -q "$TMP/wt-dirty" 'feature/#10-target'
echo work-in-progress > "$TMP/wt-dirty/wip.txt"

# 未マージの固有コミットを持つ [gone] ブランチ: リモートを手動削除して再現。
# mock の merged list に載せないため、-D エスカレーションのゲートで保護されるべき
git switch -q -c 'feature/#5-unmerged' develop
echo unmerged-work > unmerged.txt
git add unmerged.txt
git commit -qm "unmerged unique commit"
git push -qu origin 'feature/#5-unmerged'
git push -q origin --delete 'feature/#5-unmerged'
git switch -q develop

# ---- mock gh ------------------------------------------------------------------

MOCK="$TMP/mock-bin"
mkdir -p "$MOCK"

cat > "$MOCK/pr_view_10.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#10-target",
  "headRefOid": "$OID_TARGET",
  "baseRefName": "develop",
  "title": "test target PR",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_list_merged.json" <<JSON
[
  {"headRefName": "feature/#10-target", "headRefOid": "$OID_TARGET", "isCrossRepository": false},
  {"headRefName": "feature/#1-merged-exact", "headRefOid": "$OID_EXACT", "isCrossRepository": false},
  {"headRefName": "feature/#2-reused", "headRefOid": "$OID_REUSED_MERGED", "isCrossRepository": false},
  {"headRefName": "feature/#3-open-reuse", "headRefOid": "$OID_OPEN", "isCrossRepository": false},
  {"headRefName": "release/1.0", "headRefOid": "$OID_RELEASE", "isCrossRepository": false}
]
JSON

cat > "$MOCK/pr_list_open.json" <<JSON
[
  {"headRefName": "feature/#3-open-reuse"}
]
JSON

cat > "$MOCK/pr_view_99.json" <<JSON
{
  "state": "OPEN",
  "headRefName": "feature/#99-open",
  "headRefOid": "0000000000000000000000000000000000000000",
  "baseRefName": "develop",
  "title": "still open PR",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_view_11.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#10-target",
  "headRefOid": "$OID_TARGET",
  "baseRefName": "develop",
  "title": "dirty base owner guard",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_view_12.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#12-already-removed",
  "headRefOid": "$OID_TARGET",
  "baseRefName": "develop",
  "title": "already removed remote",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_view_13.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#2-reused",
  "headRefOid": "$OID_REUSED_MERGED",
  "baseRefName": "develop",
  "title": "remote updated after merge",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_view_14.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#14-recheck-fails",
  "headRefOid": "$OID_TARGET",
  "baseRefName": "develop",
  "title": "remote re-check failure",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_view_15.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#15-same-oid",
  "headRefOid": "$OID_SAME",
  "baseRefName": "develop",
  "title": "same oid after lease rejection",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/pr_view_16.json" <<JSON
{
  "state": "MERGED",
  "headRefName": "feature/#16-warning-missing",
  "headRefOid": "$OID_TARGET",
  "baseRefName": "develop",
  "title": "missing ref with stderr warning",
  "isCrossRepository": false
}
JSON

cat > "$MOCK/gh" <<SH
#!/usr/bin/env bash
args="\$*"
case "\$args" in
  "pr view 10 --json"*)   cat "$MOCK/pr_view_10.json" ;;
  "pr view 11 --json"*)   cat "$MOCK/pr_view_11.json" ;;
  "pr view 12 --json"*)   cat "$MOCK/pr_view_12.json" ;;
  "pr view 13 --json"*)   cat "$MOCK/pr_view_13.json" ;;
  "pr view 14 --json"*)   cat "$MOCK/pr_view_14.json" ;;
  "pr view 15 --json"*)   cat "$MOCK/pr_view_15.json" ;;
  "pr view 16 --json"*)   cat "$MOCK/pr_view_16.json" ;;
  "pr view 99 --json"*)   cat "$MOCK/pr_view_99.json" ;;
  *"--state merged"*)     cat "$MOCK/pr_list_merged.json" ;;
  *"--state open"*)       cat "$MOCK/pr_list_open.json" ;;
  *) echo "mock gh: unexpected args: \$args" >&2; exit 1 ;;
esac
SH
chmod +x "$MOCK/gh"

REAL_GIT="$(command -v git)"
cat > "$MOCK/git" <<SH
#!/usr/bin/env bash
if [ "\$*" = "ls-remote --heads origin refs/heads/feature/#14-recheck-fails" ]; then
  echo "simulated remote re-check failure" >&2
  exit 1
fi
if [[ "\$*" == push\ --force-with-lease=refs/heads/feature/\#15-same-oid:* ]]; then
  echo "simulated stale info for same OID" >&2
  exit 1
fi
if [[ "\$*" == push\ --force-with-lease=refs/heads/feature/\#16-warning-missing:* ]]; then
  echo "simulated stale info for missing ref" >&2
  exit 1
fi
if [ "\$*" = "ls-remote --heads origin refs/heads/feature/#16-warning-missing" ]; then
  echo "simulated non-fatal warning" >&2
  exit 0
fi
exec "$REAL_GIT" "\$@"
SH
chmod +x "$MOCK/git"

# ---- 実行 ----------------------------------------------------------------------

echo "== merge-cleanup 破壊的経路テスト =="

remote_has() { git ls-remote --heads origin "refs/heads/$1" | grep . >/dev/null; }

# 呼び出し元を detached worktree に移し、元 clone が develop を保持する競合を再現する。
# ignored file は clean 判定に出ないが、退避のために worktree ごと消してはならない。
BASE_OWNER="$(git rev-parse --show-toplevel)"
CALLER="$TMP/wt-caller"
printf '%s\n' '.cleanup-owner-preserved' >> "$BASE_OWNER/.git/info/exclude"
echo preserve-me > "$BASE_OWNER/.cleanup-owner-preserved"
git worktree add -q --detach "$CALLER" develop
cd "$CALLER"

# 未マージ PR: 破壊的処理の前に exit 1 で中断し、リモートに手を付けないこと
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 99 > "$TMP/run-99.log" 2>&1
EXIT_99=$?
set -e
if [ "$EXIT_99" -eq 1 ] && remote_has 'feature/#1-merged-exact'; then
  ok "未マージ PR は破壊的処理前に exit 1 で中断"
else
  bad "未マージ PR の中断が期待どおりでない (exit=$EXIT_99)"
fi

# dirty な base 所有 worktree は detach せず、リモート削除前に停止すること
echo work-in-progress > "$BASE_OWNER/base-owner-dirty.txt"
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 11 > "$TMP/run-11.log" 2>&1
EXIT_11=$?
set -e
if [ "$EXIT_11" -eq 1 ] \
  && [ "$(git -C "$BASE_OWNER" branch --show-current)" = "develop" ] \
  && [ -z "$(git branch --show-current)" ] \
  && remote_has 'feature/#10-target' \
  && grep -q "base ブランチの退避と cleanup を中断" "$TMP/run-11.log"; then
  ok "dirty な base 所有 worktree を変更せず、破壊的処理前に exit 1 で中断"
else
  bad "dirty な base 所有 worktree の保護が期待どおりでない (exit=$EXIT_11)"
fi
rm -f "$BASE_OWNER/base-owner-dirty.txt"

set +e
PATH="$MOCK:$PATH" bash "$TARGET" 10 > "$TMP/run.log" 2>&1
EXIT_CODE=$?
set -e

# 1. 対象 PR のリモートブランチが削除される
if remote_has 'feature/#10-target'; then
  bad "対象 PR のリモートブランチが削除されていない (feature/#10-target)"
else
  ok "対象 PR のリモートブランチを削除 (feature/#10-target)"
fi

# 2. (名前, OID) 一致の取り残しは削除される
if remote_has 'feature/#1-merged-exact'; then
  bad "OID 一致の取り残しが削除されていない (feature/#1-merged-exact)"
else
  ok "OID 一致の取り残しを削除 (feature/#1-merged-exact)"
fi

# 3. OID 不一致（マージ後 push あり）は削除されない
if remote_has 'feature/#2-reused'; then
  ok "OID 不一致の再利用ブランチを保護 (feature/#2-reused)"
else
  bad "マージ後 push のあるブランチが誤削除された (feature/#2-reused)"
fi

# 4. open PR の head は削除されない
if remote_has 'feature/#3-open-reuse'; then
  ok "open PR の head を保護 (feature/#3-open-reuse)"
else
  bad "open PR の head が誤削除された (feature/#3-open-reuse)"
fi

# 5. 保護ブランチは削除されない
if remote_has 'release/1.0'; then
  ok "保護ブランチを保護 (release/1.0)"
else
  bad "保護ブランチが誤削除された (release/1.0)"
fi

# 5.5 未マージの固有コミットを持つ [gone] ブランチは -D されない
if git show-ref -q "refs/heads/feature/#5-unmerged"; then
  ok "未マージ [gone] ブランチを保護 (feature/#5-unmerged)"
else
  bad "未マージの固有コミットを持つ [gone] ブランチが誤削除された (feature/#5-unmerged)"
fi

# 6. dirty worktree と対応ブランチが残っている + PARTIAL 終了
if [ -f "$TMP/wt-dirty/wip.txt" ] && git show-ref -q "refs/heads/feature/#10-target"; then
  ok "dirty worktree と対応 [gone] ブランチを保護"
else
  bad "dirty worktree または対応ブランチが失われた"
fi

if [ "$EXIT_CODE" -eq 2 ]; then
  ok "部分失敗（dirty worktree）で終了コード 2 (PARTIAL)"
else
  bad "終了コードが 2 ではない: $EXIT_CODE"
fi

# 6.5 clean な base 所有 worktree は detached へ退避し、呼び出し元が base へ復帰する。
# ignored file と worktree 自体は残す。
if [ "$(git branch --show-current)" = "develop" ] \
  && [ -z "$(git -C "$BASE_OWNER" branch --show-current)" ] \
  && [ -f "$BASE_OWNER/.cleanup-owner-preserved" ] \
  && git worktree list --porcelain | grep -F "worktree $BASE_OWNER" >/dev/null; then
  ok "clean な base 所有 worktree と ignored file を保ち、呼び出し元を develop へ復帰"
else
  bad "clean な base 所有 worktree の退避または呼び出し元の develop 復帰に失敗"
fi

# 6.6 リモート ref が既に無い場合、`stale info` を lease 拒否と誤表示しない。
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-12.log" 2>&1
EXIT_12=$?
set -e
if [ "$EXIT_12" -eq 2 ] \
  && grep -q "リモートブランチは既に削除されていました" "$TMP/run-12.log" \
  && ! grep -q "マージ後に更新されています" "$TMP/run-12.log"; then
  ok "削除済みリモート branch を already removed と判定"
else
  bad "削除済みリモート branch の判定が期待どおりでない (exit=$EXIT_12)"
fi

# 6.7 ref が別 OID で存在する真の競合は、従来どおり lease 拒否で保護する。
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 13 > "$TMP/run-13.log" 2>&1
EXIT_13=$?
set -e
if [ "$EXIT_13" -eq 2 ] \
  && remote_has 'feature/#2-reused' \
  && grep -q "マージ後に更新されています" "$TMP/run-13.log"; then
  ok "別 OID で存在するリモート branch を lease 拒否として保護"
else
  bad "別 OID リモート branch の lease 保護が期待どおりでない (exit=$EXIT_13)"
fi

# 6.8 ref 再取得が失敗した場合は「削除済み」と推測せず致命的エラーにする。
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 14 > "$TMP/run-14.log" 2>&1
EXIT_14=$?
set -e
if [ "$EXIT_14" -eq 1 ] \
  && grep -q "remote re-check failed" "$TMP/run-14.log" \
  && grep -q "simulated remote re-check failure" "$TMP/run-14.log"; then
  ok "lease 拒否後の ref 再取得失敗を fail-closed で停止"
else
  bad "ref 再取得失敗が fail-closed になっていない (exit=$EXIT_14)"
fi

# 6.9 ref が期待 OID のまま存在する場合は、競合 push と断定せず原因不明で停止する。
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 15 > "$TMP/run-15.log" 2>&1
EXIT_15=$?
set -e
if [ "$EXIT_15" -eq 1 ] \
  && remote_has 'feature/#15-same-oid' \
  && grep -q "remote re-check returned the expected OID" "$TMP/run-15.log" \
  && ! grep -q "マージ後に更新されています" "$TMP/run-15.log"; then
  ok "期待 OID のまま残る ref を原因不明として fail-closed で停止"
else
  bad "期待 OID のまま残る ref の判定が期待どおりでない (exit=$EXIT_15)"
fi

# 6.10 stdout が空なら、成功時の stderr 警告を ref 存在と誤読しない。
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 16 > "$TMP/run-16.log" 2>&1
EXIT_16=$?
set -e
if [ "$EXIT_16" -eq 2 ] \
  && grep -q "リモートブランチは既に削除されていました" "$TMP/run-16.log" \
  && ! grep -q "マージ後に更新されています" "$TMP/run-16.log"; then
  ok "成功時 stderr 警告を ref 存在と誤読せず already removed と判定"
else
  bad "成功時 stderr 警告の分離が期待どおりでない (exit=$EXIT_16)"
fi

# 7. サマリーに失敗項目が列挙されている（状態がサマリーまで届く）
if grep -q "worktree に未コミット変更あり" "$TMP/run.log"; then
  ok "失敗項目がサマリーに列挙される"
else
  bad "失敗項目がサマリーに出ていない"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "✗ merge-cleanup verify: $FAIL 件失敗（詳細: 実行ログ抜粋）" >&2
  tail -40 "$TMP/run.log" >&2
  exit 1
fi
echo "✓ merge-cleanup verify: 全 $PASS 件 pass"
