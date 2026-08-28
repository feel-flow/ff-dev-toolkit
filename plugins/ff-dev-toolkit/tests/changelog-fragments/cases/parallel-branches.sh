#!/usr/bin/env bash
# shellcheck shell=bash

echo "== parallel branches use distinct paths =="
SEED="$TMP/seed"
BARE="$TMP/origin.git"
mkdir -p "$SEED/changelog.d"
git -C "$SEED" init -q
git -C "$SEED" config user.email fragments@example.com
git -C "$SEED" config user.name fragments-test
printf '%s\n' '# fragments' > "$SEED/changelog.d/README.md"
git -C "$SEED" add -A
git -C "$SEED" commit -qm baseline
git -C "$SEED" branch -M develop
git clone -q --bare "$SEED" "$BARE"

for name in a b; do
  git clone -q "$BARE" "$TMP/$name"
  git -C "$TMP/$name" config user.email fragments@example.com
  git -C "$TMP/$name" config user.name fragments-test
  git -C "$TMP/$name" switch -qc "branch-$name"
done
printf '%s\n' '- first branch' > "$TMP/a/changelog.d/101.changed.feature-a.md"
git -C "$TMP/a" add -A
git -C "$TMP/a" commit -qm branch-a
git -C "$TMP/a" push -q origin HEAD:branch-a
printf '%s\n' '- second branch' > "$TMP/b/changelog.d/101.changed.feature-b.md"
git -C "$TMP/b" add -A
git -C "$TMP/b" commit -qm branch-b
git -C "$TMP/b" push -q origin HEAD:branch-b

git clone -q "$BARE" "$TMP/integration"
git -C "$TMP/integration" config user.email fragments@example.com
git -C "$TMP/integration" config user.name fragments-test
git -C "$TMP/integration" switch -q develop
git -C "$TMP/integration" fetch -q origin branch-a branch-b
if git -C "$TMP/integration" merge -q --no-edit origin/branch-a; then ok "1本目を直列マージ"; else bad "1本目のマージに失敗"; fi
if git -C "$TMP/integration" merge -q --no-edit origin/branch-b; then ok "2本目を競合なしで直列マージ"; else bad "2本目が競合"; fi
if [[ -f "$TMP/integration/changelog.d/101.changed.feature-a.md" && -f "$TMP/integration/changelog.d/101.changed.feature-b.md" ]]; then ok "同一 Issue・種別の両断片が残存"; else bad "片方の断片が欠落"; fi
