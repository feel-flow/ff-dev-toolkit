# shellcheck shell=bash
# 断片の段階の帰属検査。リリース時の再判定（check-release-required の ATTRIBUTION_DRIFT）と同じ判定を
# --check が断片ごとに行い、前版タグと同一内容の path を backtick で参照する断片を名指しで赤にする
# （リリース時まで持ち越さない）。判定本体は共通 helper（plugins/ff-dev-toolkit/scripts/lib/
# changelog-attribution-functions.sh）で、fixture にはそれを写して使う。

ATTR="$TMP/attribution"
ATTR_PUB="$TMP/attribution-public"
make_fixture "$ATTR"
ff_git_fixture_init "$ATTR" "Attribution Test" "attribution-test@example.com" >/dev/null
mkdir -p "$ATTR/plugins/ff-dev-toolkit/scripts/lib"
cp "$REPO_ROOT/plugins/ff-dev-toolkit/scripts/lib/changelog-attribution-functions.sh" "$ATTR/plugins/ff-dev-toolkit/scripts/lib/"
printf '%s\n' 'stable' >"$ATTR/plugins/ff-dev-toolkit/scripts/stable.sh"
printf '%s\n' 'v1' >"$ATTR/plugins/ff-dev-toolkit/scripts/changed.sh"
git -C "$ATTR" add -A && git -C "$ATTR" commit -qm baseline
# 公開側: 前版タグ v1.0.0 は stable.sh / changed.sh の v1 を持つ
ff_git_fixture_init "$ATTR_PUB" "Attribution Test" "attribution-test@example.com" >/dev/null
mkdir -p "$ATTR_PUB/plugins/ff-dev-toolkit/scripts"
cp "$ATTR/plugins/ff-dev-toolkit/scripts/stable.sh" "$ATTR/plugins/ff-dev-toolkit/scripts/changed.sh" "$ATTR_PUB/plugins/ff-dev-toolkit/scripts/"
git -C "$ATTR_PUB" add -A && git -C "$ATTR_PUB" commit -qm public && git -C "$ATTR_PUB" tag v1.0.0
# 今回の変更は changed.sh だけ
printf '%s\n' 'v2' >"$ATTR/plugins/ff-dev-toolkit/scripts/changed.sh"
git -C "$ATTR" commit -qam change

printf '%s\n' '- 判定を直した（`scripts/changed.sh`）' >"$ATTR/changelog.d/20.fixed.changed.md"
FF_RELEASE_CHECK_PUBLIC="$ATTR_PUB" run_contract "$ATTR" --check
if [[ "$RC" -eq 0 && "$OUT" == *"FRAGMENTS=1"* && "$OUT" != *"ATTRIBUTION_PATH="* ]]; then
  ok "帰属: 今回変えた path だけを参照する断片は通る"
else
  bad "帰属: 今回変えた path の参照を誤帰属と読んだ (rc=$RC)"; printf '%s\n' "$OUT" | sed 's/^/    | /' >&2
fi

printf '%s\n' '- 同梱の判定を使う（`scripts/stable.sh`）' >"$ATTR/changelog.d/21.changed.stable.md"
FF_RELEASE_CHECK_PUBLIC="$ATTR_PUB" run_contract "$ATTR" --check
if [[ "$RC" -eq 1 && "$OUT" == *"ATTRIBUTION_PATH=scripts/stable.sh -> plugins/ff-dev-toolkit/scripts/stable.sh (v1.0.0 と同一 object)"* \
  && "$OUT" == *"changelog.d/21.changed.stable.md: 前版 v1.0.0 と同一内容の path"* && "$OUT" != *"20.fixed.changed.md: 前版"* ]]; then
  ok "帰属: 前版タグと同一内容の path を参照する断片を、リリース前の --check で断片名と path つきの赤にする"
else
  bad "帰属: 前版タグと同一内容の path の参照が断片の段階で赤にならない (rc=$RC)"; printf '%s\n' "$OUT" | sed 's/^/    | /' >&2
fi

printf '%s\n' 'stable (edited)' >"$ATTR/plugins/ff-dev-toolkit/scripts/stable.sh"
FF_RELEASE_CHECK_PUBLIC="$ATTR_PUB" run_contract "$ATTR" --check
if [[ "$RC" -eq 0 && "$OUT" != *"ATTRIBUTION_PATH="* ]]; then
  ok "帰属: 未コミットの変更がある path は変更済みとして扱う（断片と変更を commit 前に検査する回を赤にしない）"
else
  bad "帰属: 作業ツリーで変えた path を誤帰属と読んだ (rc=$RC)"; printf '%s\n' "$OUT" | sed 's/^/    | /' >&2
fi
git -C "$ATTR" checkout -q -- plugins/ff-dev-toolkit/scripts/stable.sh

FF_RELEASE_CHECK_PUBLIC="$TMP/attribution-no-public" run_contract "$ATTR" --check
if [[ "$RC" -eq 0 && "$OUT" == *"公開側 clone が無いため判定しない（$TMP/attribution-no-public"* && "$OUT" != *"ATTRIBUTION_PATH="* ]]; then
  ok "帰属: 公開側 clone が無い環境は判定不能として名指しで警告し、赤にはしない"
else
  bad "帰属: 公開側 clone 不在の扱いが違う (rc=$RC)"; printf '%s\n' "$OUT" | sed 's/^/    | /' >&2
fi
rm -f "$ATTR/changelog.d/20.fixed.changed.md" "$ATTR/changelog.d/21.changed.stable.md"
