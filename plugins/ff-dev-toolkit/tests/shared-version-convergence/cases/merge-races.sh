# shellcheck shell=bash
echo "== PR merge race uses a document claim sentinel =="
PR_SEED="$TMP/pr-seed"
PR_BARE="$TMP/pr-origin.git"
mkdir -p "$PR_SEED/docs" "$PR_SEED/.version-claims/docs"
ff_git_fixture_init "$PR_SEED" "version-test" "version@example.com"
printf '%s\n' '---' 'version: "1.0.0"' '---' '# Doc' '' '## A' '' '- base-a' '' '## B' '' '- base-b' > "$PR_SEED/docs/TEST.md"
printf '%s\n' '# claims' > "$PR_SEED/.version-claims/README.md"
printf '%s\n' 'document=docs/TEST.md' 'version=1.0.0' 'change=baseline' > "$PR_SEED/.version-claims/docs/TEST.md.claim"
git -C "$PR_SEED" add -A
git -C "$PR_SEED" commit -qm baseline
git -C "$PR_SEED" branch -M develop
git clone -q --bare "$PR_SEED" "$PR_BARE"

for name in pr-a pr-b; do
  git clone -q "$PR_BARE" "$TMP/$name"
  ff_git_fixture_init "$TMP/$name" "version-test" "version@example.com"
  git -C "$TMP/$name" switch -qc "$name"
done
sed -i.bak '/- base-a/a\
- change-a' "$TMP/pr-a/docs/TEST.md" && rm "$TMP/pr-a/docs/TEST.md.bak"
git -C "$TMP/pr-a" add -A
git -C "$TMP/pr-a" commit -qm pr-a-content
sed -i.bak 's/version: "1.0.0"/version: "1.1.0"/' "$TMP/pr-a/docs/TEST.md" && rm "$TMP/pr-a/docs/TEST.md.bak"
(cd "$TMP/pr-a" && "$CLAIM_HELPER" --base origin/develop --document docs/TEST.md) >/dev/null
pr_a_change="$(sed -n 's/^change=//p' "$TMP/pr-a/.version-claims/docs/TEST.md.claim")"
git -C "$TMP/pr-a" add -A
git -C "$TMP/pr-a" commit -qm pr-a-claim
if grep -Fqx "change=$pr_a_change" "$TMP/pr-a/.version-claims/docs/TEST.md.claim"; then ok "複数 commit でも default branch/current blob 基準の累積 hash"; else bad "claim が最後の commit だけを表す"; fi

sed -i.bak 's/version: "1.0.0"/version: "1.1.0"/' "$TMP/pr-b/docs/TEST.md" && rm "$TMP/pr-b/docs/TEST.md.bak"
sed -i.bak '/- base-b/a\
- change-b' "$TMP/pr-b/docs/TEST.md" && rm "$TMP/pr-b/docs/TEST.md.bak"
(cd "$TMP/pr-b" && "$CLAIM_HELPER" --base origin/develop --document docs/TEST.md) >/dev/null
pr_b_change="$(sed -n 's/^change=//p' "$TMP/pr-b/.version-claims/docs/TEST.md.claim")"
git -C "$TMP/pr-b" add -A
git -C "$TMP/pr-b" commit -qm pr-b

git clone -q "$PR_BARE" "$TMP/pr-integration"
ff_git_fixture_init "$TMP/pr-integration" "version-test" "version@example.com"
git -C "$TMP/pr-integration" fetch -q "$TMP/pr-a" HEAD:refs/remotes/test/pr-a
git -C "$TMP/pr-integration" fetch -q "$TMP/pr-b" HEAD:refs/remotes/test/pr-b
if git -C "$TMP/pr-integration" merge -q --no-edit refs/remotes/test/pr-a; then ok "先行 PR をマージ"; else bad "先行 PR のマージに失敗"; fi
set +e
PR_B_MERGE_OUT="$(git -C "$TMP/pr-integration" merge --no-edit refs/remotes/test/pr-b 2>&1)"
PR_B_MERGE_RC=$?
set -e
if [[ "$PR_B_MERGE_RC" -ne 0 && "$PR_B_MERGE_OUT" == *".version-claims/docs/TEST.md.claim"* ]]; then ok "後発 PR は claim 競合で停止"; else bad "後発 PR が同じ版のまま自動マージされた"; fi
if unmerged_out="$("$CLAIM_VALIDATOR" --root "$TMP/pr-integration" 2>&1)"; then unmerged_rc=0; else unmerged_rc=$?; fi
if [[ "$unmerged_rc" -eq 2 && "$unmerged_out" == *"unmerged index entry"* ]]; then ok "unmerged index を validator が検査不能で拒否"; else bad "unmerged claim index を validator が許可"; printf '%s\n' "$unmerged_out" | sed 's/^/    | /' >&2; fi
git -C "$TMP/pr-integration" merge --abort
git -C "$TMP/pr-integration" switch -qc pr-b-reconciled
sed -i.bak 's/version: "1.1.0"/version: "1.2.0"/' "$TMP/pr-integration/docs/TEST.md" && rm "$TMP/pr-integration/docs/TEST.md.bak"
sed -i.bak '/- base-b/a\
- change-b' "$TMP/pr-integration/docs/TEST.md" && rm "$TMP/pr-integration/docs/TEST.md.bak"
(cd "$TMP/pr-integration" && "$CLAIM_HELPER" --base develop --document docs/TEST.md) >/dev/null
pr_b_reconciled_change="$(sed -n 's/^change=//p' "$TMP/pr-integration/.version-claims/docs/TEST.md.claim")"
git -C "$TMP/pr-integration" add -A
git -C "$TMP/pr-integration" commit -qm pr-b-reconciled
if git -C "$TMP/pr-integration" switch -q develop && git -C "$TMP/pr-integration" merge -q --no-edit pr-b-reconciled; then ok "最新 tree で再採番した PR は収束"; else bad "再採番した PR がマージできない"; fi
if grep -Fq 'version: "1.2.0"' "$TMP/pr-integration/docs/TEST.md"; then ok "PR 後発版を繰り上げ"; else bad "PR 後発版が繰り上がらない"; fi
if grep -Fq -- '- change-a' "$TMP/pr-integration/docs/TEST.md" && grep -Fq -- '- change-b' "$TMP/pr-integration/docs/TEST.md"; then ok "PR 両方の文書変更を保全"; else bad "PR の文書変更が欠落"; fi
expected_reconciled_claim="$(printf '%s\n' 'document=docs/TEST.md' 'version=1.2.0' "change=$pr_b_reconciled_change")"
actual_reconciled_claim="$(cat "$TMP/pr-integration/.version-claims/docs/TEST.md.claim")"
if [[ "$actual_reconciled_claim" == "$expected_reconciled_claim" ]]; then ok "競合解消後の claim は最新 base 基準の正確な3行"; else bad "競合解消後の claim が stale または schema 違反"; fi

echo "== direct push and PR race share the same claim sentinel =="
CROSS_SEED="$TMP/cross-seed"
CROSS_BARE="$TMP/cross-origin.git"
mkdir -p "$CROSS_SEED/docs" "$CROSS_SEED/.version-claims/docs"
ff_git_fixture_init "$CROSS_SEED" "version-test" "version@example.com"
printf '%s\n' '---' 'version: "1.0.0"' '---' '# Doc' '' '## Direct' '' '- base-direct' '' '## PR' '' '- base-pr' > "$CROSS_SEED/docs/TEST.md"
printf '%s\n' '# claims' > "$CROSS_SEED/.version-claims/README.md"
printf '%s\n' 'document=docs/TEST.md' 'version=1.0.0' 'change=baseline' > "$CROSS_SEED/.version-claims/docs/TEST.md.claim"
git -C "$CROSS_SEED" add -A
git -C "$CROSS_SEED" commit -qm baseline
git -C "$CROSS_SEED" branch -M develop
git clone -q --bare "$CROSS_SEED" "$CROSS_BARE"
for name in cross-direct cross-pr; do
  git clone -q "$CROSS_BARE" "$TMP/$name"
  ff_git_fixture_init "$TMP/$name" "version-test" "version@example.com"
done

sed -i.bak 's/version: "1.0.0"/version: "1.1.0"/' "$TMP/cross-pr/docs/TEST.md" && rm "$TMP/cross-pr/docs/TEST.md.bak"
sed -i.bak '/- base-pr/a\
- pr-change' "$TMP/cross-pr/docs/TEST.md" && rm "$TMP/cross-pr/docs/TEST.md.bak"
(cd "$TMP/cross-pr" && "$CLAIM_HELPER" --base origin/develop --document docs/TEST.md) >/dev/null
cross_pr_change="$(sed -n 's/^change=//p' "$TMP/cross-pr/.version-claims/docs/TEST.md.claim")"
git -C "$TMP/cross-pr" add -A && git -C "$TMP/cross-pr" commit -qm cross-pr

sed -i.bak '/- base-direct/a\
- direct-change' "$TMP/cross-direct/docs/TEST.md" && rm "$TMP/cross-direct/docs/TEST.md.bak"
(cd "$TMP/cross-direct" && "$CLAIM_HELPER" --base origin/develop --document docs/TEST.md) >/dev/null
cross_direct_change="$(sed -n 's/^change=//p' "$TMP/cross-direct/.version-claims/docs/TEST.md.claim")"
git -C "$TMP/cross-direct" add -A && git -C "$TMP/cross-direct" commit -qm cross-direct
if git -C "$TMP/cross-direct" push -q origin HEAD:develop; then ok "version 不変の直 push も文書と claim を同じ commit で更新"; else bad "claim 付き直 push が失敗"; fi
if [[ "$(git --git-dir="$CROSS_BARE" show develop:.version-claims/docs/TEST.md.claim)" == *"change=$cross_direct_change"* ]]; then ok "直 push 後の default branch claim は blob-pair hash と一致"; else bad "直 push が claim を更新しない"; fi

git clone -q "$CROSS_BARE" "$TMP/cross-integration"
ff_git_fixture_init "$TMP/cross-integration" "version-test" "version@example.com"
git -C "$TMP/cross-integration" fetch -q "$TMP/cross-pr" HEAD:refs/remotes/test/cross-pr
set +e
CROSS_MERGE_OUT="$(git -C "$TMP/cross-integration" merge --no-edit refs/remotes/test/cross-pr 2>&1)"
CROSS_MERGE_RC=$?
set -e
if [[ "$CROSS_MERGE_RC" -ne 0 && "$CROSS_MERGE_OUT" == *".version-claims/docs/TEST.md.claim"* ]]; then ok "直 push と進行中 PR の交差は claim conflict で停止"; else bad "直 push が進行中 PR の claim sentinel を素通り"; fi

echo "== pushed feature branch reconciles without history rewrite =="
FEATURE_SEED="$TMP/feature-seed"
FEATURE_BARE="$TMP/feature-origin.git"
FEATURE_WORK="$TMP/feature-work"
FEATURE_RIVAL="$TMP/feature-rival"
mkdir -p "$FEATURE_SEED/docs" "$FEATURE_SEED/.version-claims/docs"
ff_git_fixture_init "$FEATURE_SEED" "version-test" "version@example.com"
printf '%s\n' '---' 'version: "1.0.0"' '---' '# Feature reconciliation' '' '- baseline' > "$FEATURE_SEED/docs/TEST.md"
printf '%s\n' '# claims' > "$FEATURE_SEED/.version-claims/README.md"
printf '%s\n' 'document=docs/TEST.md' 'version=1.0.0' 'change=baseline' > "$FEATURE_SEED/.version-claims/docs/TEST.md.claim"
git -C "$FEATURE_SEED" add -A && git -C "$FEATURE_SEED" commit -qm baseline
git -C "$FEATURE_SEED" branch -M develop
git clone -q --bare "$FEATURE_SEED" "$FEATURE_BARE"
git -C "$FEATURE_BARE" symbolic-ref HEAD refs/heads/develop
for feature_clone in "$FEATURE_WORK" "$FEATURE_RIVAL"; do
  git clone -q "$FEATURE_BARE" "$feature_clone"
  ff_git_fixture_init "$feature_clone" "version-test" "version@example.com"
done
git -C "$FEATURE_WORK" switch -qc feature
sed -i.bak 's/version: "1.0.0"/version: "1.1.0"/' "$FEATURE_WORK/docs/TEST.md" && rm "$FEATURE_WORK/docs/TEST.md.bak"
printf '%s\n' '- feature change' >> "$FEATURE_WORK/docs/TEST.md"
(cd "$FEATURE_WORK" && "$CLAIM_HELPER" --base origin/develop --document docs/TEST.md) >/dev/null
git -C "$FEATURE_WORK" add -A && git -C "$FEATURE_WORK" commit -qm feature-initial
git -C "$FEATURE_WORK" push -qu origin feature
published_feature_tip="$(git -C "$FEATURE_WORK" rev-parse HEAD)"

sed -i.bak 's/version: "1.0.0"/version: "1.1.0"/' "$FEATURE_RIVAL/docs/TEST.md" && rm "$FEATURE_RIVAL/docs/TEST.md.bak"
printf '%s\n' '- default advance' >> "$FEATURE_RIVAL/docs/TEST.md"
(cd "$FEATURE_RIVAL" && "$CLAIM_HELPER" --base origin/develop --document docs/TEST.md) >/dev/null
git -C "$FEATURE_RIVAL" add -A && git -C "$FEATURE_RIVAL" commit -qm default-advance
git -C "$FEATURE_RIVAL" push -q origin HEAD:develop

git -C "$FEATURE_WORK" fetch -q origin '+refs/heads/develop:refs/remotes/origin/develop'
set +e
git -C "$FEATURE_WORK" merge --no-edit origin/develop >/dev/null 2>&1
feature_merge_rc=$?
set -e
if [[ "$feature_merge_rc" -ne 0 ]]; then
  git -C "$FEATURE_WORK" checkout -q --theirs docs/TEST.md
  printf '%s\n' '- feature change' >> "$FEATURE_WORK/docs/TEST.md"
fi
sed -i.bak 's/version: "1.1.0"/version: "1.2.0"/' "$FEATURE_WORK/docs/TEST.md" && rm "$FEATURE_WORK/docs/TEST.md.bak"
(cd "$FEATURE_WORK" && "$CLAIM_HELPER" --base origin/develop --document docs/TEST.md) >/dev/null
feature_claim="$(cat "$FEATURE_WORK/.version-claims/docs/TEST.md.claim")"
git -C "$FEATURE_WORK" add -A && git -C "$FEATURE_WORK" commit -qm feature-reconciliation
if git -C "$FEATURE_WORK" merge-base --is-ancestor "$published_feature_tip" HEAD; then ok "reconciliation commit は公開済み feature tip の子孫"; else bad "push 済み feature 履歴を改変"; fi
if git -C "$FEATURE_WORK" push -q origin HEAD:feature; then ok "reconciliation commit を force なしの通常 push"; else bad "公開済み feature へ通常 push できない"; fi
if grep -Fq -- '- default advance' "$FEATURE_WORK/docs/TEST.md" && grep -Fq -- '- feature change' "$FEATURE_WORK/docs/TEST.md"; then ok "reconciliation は default と feature の両変更を保全"; else bad "reconciliation で片側の変更を喪失"; fi
feature_base_blob="$(git -C "$FEATURE_WORK" rev-parse origin/develop:docs/TEST.md)"
feature_current_blob="$(git -C "$FEATURE_WORK" hash-object docs/TEST.md)"
feature_change="$(printf '%s\n' "base=$feature_base_blob" "current=$feature_current_blob" | git -C "$FEATURE_WORK" hash-object --stdin)"
if [[ "$feature_claim" == "$(printf '%s\n' 'document=docs/TEST.md' 'version=1.2.0' "change=$feature_change")" ]]; then ok "reconciliation claim は最新 default branch 基準"; else bad "reconciliation が stale base の claim を再利用"; fi

echo "== bounded retry stops after three consecutive CAS conflicts =="
RETRY_SEED="$TMP/retry-seed"
RETRY_BARE="$TMP/retry-origin.git"
RETRY_WORK="$TMP/retry-work"
RETRY_RIVAL="$TMP/retry-rival"
mkdir -p "$RETRY_SEED/docs" "$RETRY_SEED/.version-claims/docs"
ff_git_fixture_init "$RETRY_SEED" "version-test" "version@example.com"
printf '%s\n' '---' 'version: "1.0.0"' '---' '# Retry' '' '- baseline' > "$RETRY_SEED/docs/TEST.md"
printf '%s\n' '# claims' > "$RETRY_SEED/.version-claims/README.md"
printf '%s\n' 'document=docs/TEST.md' 'version=1.0.0' 'change=baseline' > "$RETRY_SEED/.version-claims/docs/TEST.md.claim"
git -C "$RETRY_SEED" add -A
git -C "$RETRY_SEED" commit -qm baseline
git -C "$RETRY_SEED" branch -M develop
git clone -q --bare "$RETRY_SEED" "$RETRY_BARE"
git -C "$RETRY_BARE" symbolic-ref HEAD refs/heads/develop
for retry_clone in "$RETRY_WORK" "$RETRY_RIVAL"; do
  git clone -q "$RETRY_BARE" "$retry_clone"
  ff_git_fixture_init "$retry_clone" "version-test" "version@example.com"
done

retry_attempts=0
retry_rejections=0
: > "$TMP/retry-regeneration.log"
while [[ "$retry_attempts" -lt 3 ]]; do
  retry_attempts=$((retry_attempts + 1))
  git -C "$RETRY_WORK" fetch -q origin '+refs/heads/develop:refs/remotes/origin/develop'
  git -C "$RETRY_WORK" reset -q --hard origin/develop
  retry_base="$(git -C "$RETRY_WORK" rev-parse origin/develop)"
  retry_minor="$(sed -n 's/^version: "1\.\([0-9][0-9]*\)\.0"$/\1/p' "$RETRY_WORK/docs/TEST.md")"
  retry_next=$((retry_minor + 1))
  sed -i.bak "s/version: \"1\.${retry_minor}\.0\"/version: \"1\.${retry_next}\.0\"/" "$RETRY_WORK/docs/TEST.md" && rm "$RETRY_WORK/docs/TEST.md.bak"
  printf '%s\n' "- retry-${retry_attempts}" >> "$RETRY_WORK/docs/TEST.md"
  (cd "$RETRY_WORK" && "$CLAIM_HELPER" --base origin/develop --document docs/TEST.md) >/dev/null
  retry_claim="$(sed -n 's/^change=//p' "$RETRY_WORK/.version-claims/docs/TEST.md.claim")"
  printf '%s %s %s\n' "$retry_base" "1.${retry_next}.0" "$retry_claim" >> "$TMP/retry-regeneration.log"
  git -C "$RETRY_WORK" add -A && git -C "$RETRY_WORK" commit -qm "retry-${retry_attempts}"

  git -C "$RETRY_RIVAL" fetch -q origin '+refs/heads/develop:refs/remotes/origin/develop'
  git -C "$RETRY_RIVAL" reset -q --hard origin/develop
  sed -i.bak "s/version: \"1\.${retry_minor}\.0\"/version: \"1\.${retry_next}\.0\"/" "$RETRY_RIVAL/docs/TEST.md" && rm "$RETRY_RIVAL/docs/TEST.md.bak"
  printf '%s\n' "- rival-${retry_attempts}" >> "$RETRY_RIVAL/docs/TEST.md"
  (cd "$RETRY_RIVAL" && "$CLAIM_HELPER" --base origin/develop --document docs/TEST.md) >/dev/null
  git -C "$RETRY_RIVAL" add -A && git -C "$RETRY_RIVAL" commit -qm "rival-${retry_attempts}"
  git -C "$RETRY_RIVAL" push -q origin HEAD:develop

  if git -C "$RETRY_WORK" push origin HEAD:develop >/dev/null 2>&1; then
    bad "連続競合 fixture の後発 push が拒否されない"
    break
  fi
  retry_rejections=$((retry_rejections + 1))
done

if [[ "$retry_attempts" -eq 3 && "$retry_rejections" -eq 3 ]]; then ok "連続 CAS 競合は3回で停止し4回目を送らない"; else bad "bounded retry が3回で停止しない"; fi
if [[ "$(awk '{print $1}' "$TMP/retry-regeneration.log" | sort -u | wc -l | tr -d ' ')" -eq 3 && "$(awk '{print $2}' "$TMP/retry-regeneration.log" | tr '\n' ' ')" == "1.1.0 1.2.0 1.3.0 " ]]; then ok "各 retry は最新 base から version を再計算"; else bad "retry が stale base/version を再利用"; fi
if [[ "$(awk '{print $3}' "$TMP/retry-regeneration.log" | sort -u | wc -l | tr -d ' ')" -eq 3 ]]; then ok "各 retry は claim hash を再生成"; else bad "retry が stale claim を再利用"; fi
