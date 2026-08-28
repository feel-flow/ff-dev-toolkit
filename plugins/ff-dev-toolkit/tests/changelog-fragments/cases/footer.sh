# shellcheck shell=bash
FOOTER_FIX="$TMP/footer-policy"
mkdir -p "$FOOTER_FIX/scripts" "$FOOTER_FIX/oss/ff-dev-toolkit"
cp "$REPO_ROOT/scripts/check-full-gate-reuse.sh" "$FOOTER_FIX/scripts/check-full-gate-reuse.sh"
git -C "$FOOTER_FIX" init -q
git -C "$FOOTER_FIX" config user.email footer@example.com
git -C "$FOOTER_FIX" config user.name footer-test
printf '%s\n' '# Changelog' '' '## [Unreleased]' '' '[Unreleased]: https://github.com/feel-flow/ff-dev-toolkit/compare/v1.0.0...HEAD' > "$FOOTER_FIX/oss/ff-dev-toolkit/CHANGELOG.md"
git -C "$FOOTER_FIX" add -A && git -C "$FOOTER_FIX" commit -qm baseline
footer_base="$(git -C "$FOOTER_FIX" rev-parse HEAD)"
printf '%s\n' '[1.0.0]: https://github.com/feel-flow/ff-dev-toolkit/releases/tag/v1.0.0' >> "$FOOTER_FIX/oss/ff-dev-toolkit/CHANGELOG.md"
git -C "$FOOTER_FIX" add -A && git -C "$FOOTER_FIX" commit -qm footer
set +e
footer_fixture_out="$(bash "$FOOTER_FIX/scripts/check-full-gate-reuse.sh" --green-sha "$footer_base" 2>&1)"
footer_fixture_rc=$?
set -e
if [[ "$footer_fixture_rc" -eq 0 && "$footer_fixture_out" == *"FULL_GATE_REUSE=CHANGELOG_FOOTER_ONLY"* ]]; then ok "比較リンク footer-only PR は直編集禁止の例外"; else bad "footer-only fixture を通常直編集と誤判定"; fi
FOOTER_HELPER="$REPO_ROOT/scripts/update-dev-toolkit-changelog-footer.sh"
if [[ -x "$FOOTER_HELPER" ]] && grep -Fq 'update-dev-toolkit-changelog-footer.sh --public-checkout' "$REPO_ROOT/.claude/skills/sync-dev-toolkit/SKILL.md"; then ok "footer writer は実行可能 helper へ一本化"; else bad "footer writer が分割 shell の手作業に戻っている"; fi

FOOTER_ROOT="$TMP/footer-writer"
FOOTER_PUBLIC_SEED="$TMP/footer-public-seed"
FOOTER_PUBLIC_BARE="$TMP/footer-public-origin.git"
FOOTER_PUBLIC="$TMP/footer-public"
FOOTER_FAKE_BIN="$TMP/footer-bin"
mkdir -p "$FOOTER_ROOT/scripts/lib" "$FOOTER_ROOT/changelog.d" "$FOOTER_ROOT/oss/ff-dev-toolkit" "$FOOTER_PUBLIC_SEED" "$FOOTER_FAKE_BIN"
git -C "$FOOTER_ROOT" init -q
cp "$TARGET" "$FOOTER_ROOT/scripts/materialize-dev-toolkit-changelog.sh"
cp "$TARGET_LIB" "$FOOTER_ROOT/scripts/lib/changelog-fragment-functions.sh"
cp "$TARGET_TX_LIB" "$FOOTER_ROOT/scripts/lib/changelog-transaction-functions.sh"
cp "$TARGET_EXACT_LINK_LIB" "$FOOTER_ROOT/scripts/lib/exact-link-functions.sh"
cp "$FOOTER_HELPER" "$FOOTER_ROOT/scripts/update-dev-toolkit-changelog-footer.sh"
chmod +x "$FOOTER_ROOT/scripts/"*.sh
printf '%s\n' '# fragments' > "$FOOTER_ROOT/changelog.d/README.md"
write_changelog "$FOOTER_ROOT/oss/ff-dev-toolkit/CHANGELOG.md"
git -C "$FOOTER_PUBLIC_SEED" init -q
git -C "$FOOTER_PUBLIC_SEED" config user.email footer@example.com
git -C "$FOOTER_PUBLIC_SEED" config user.name footer-test
printf '%s\n' '# public' > "$FOOTER_PUBLIC_SEED/README.md"
git -C "$FOOTER_PUBLIC_SEED" add -A
git -C "$FOOTER_PUBLIC_SEED" commit -qm v1
git -C "$FOOTER_PUBLIC_SEED" tag v1.0.0
printf '%s\n' 'next' >> "$FOOTER_PUBLIC_SEED/README.md"
git -C "$FOOTER_PUBLIC_SEED" commit -qam v1.1
git -C "$FOOTER_PUBLIC_SEED" tag v1.1.0
git -C "$FOOTER_PUBLIC_SEED" tag v0.9.4
git -C "$FOOTER_PUBLIC_SEED" tag v0.10.1
git -C "$FOOTER_PUBLIC_SEED" tag v1.0.0-rc.1
git -C "$FOOTER_PUBLIC_SEED" tag v2.0.0-rc.1
git clone -q --bare "$FOOTER_PUBLIC_SEED" "$FOOTER_PUBLIC_BARE"
git clone -q "$FOOTER_PUBLIC_BARE" "$FOOTER_PUBLIC"
git -C "$FOOTER_PUBLIC" remote set-url origin https://github.com/feel-flow/ff-dev-toolkit.git
git -C "$FOOTER_PUBLIC" config url."$FOOTER_PUBLIC_BARE".insteadOf https://github.com/feel-flow/ff-dev-toolkit.git
export FF_CHANGELOG_TEST_REMOTE="$FOOTER_PUBLIC_BARE"
cp "$SCRIPT_DIR/fixtures/bin/footer-git" "$FOOTER_FAKE_BIN/git"
cp "$SCRIPT_DIR/fixtures/bin/footer-awk" "$FOOTER_FAKE_BIN/awk"
chmod +x "$FOOTER_FAKE_BIN/git" "$FOOTER_FAKE_BIN/awk"
FOOTER_REAL_GIT="$(command -v git)"
FOOTER_REAL_AWK="$(command -v awk)"
run_footer_helper() {
  PATH="$FOOTER_FAKE_BIN:$PATH" FAKE_FOOTER_REAL_GIT="$FOOTER_REAL_GIT" FAKE_FOOTER_REAL_AWK="$FOOTER_REAL_AWK" bash "$FOOTER_ROOT/scripts/update-dev-toolkit-changelog-footer.sh" "$@"
}

FOOTER_UNTRUSTED="$TMP/footer-untrusted"
git clone -q "$FOOTER_PUBLIC_BARE" "$FOOTER_UNTRUSTED"
set +e
footer_untrusted_out="$(run_footer_helper --public-checkout "$FOOTER_UNTRUSTED" 2>&1)"
footer_untrusted_rc=$?
set -e
if [[ "$footer_untrusted_rc" -eq 1 && "$footer_untrusted_out" == *"feel-flow/ff-dev-toolkit ではありません"* ]]; then ok "footer helper は任意 origin の tag を信頼しない"; else bad "footer helper が任意 checkout の tag を信頼"; fi
footer_valid_origins=(
  https://github.com/feel-flow/ff-dev-toolkit
  https://github.com/feel-flow/ff-dev-toolkit.git
  git@github.com:feel-flow/ff-dev-toolkit.git
  ssh://git@github.com/feel-flow/ff-dev-toolkit.git
)
footer_origin_formats_ok=1
for footer_valid_origin in "${footer_valid_origins[@]}"; do
  git -C "$FOOTER_PUBLIC" remote set-url origin "$footer_valid_origin"
  run_footer_helper --public-checkout "$FOOTER_PUBLIC" >/dev/null 2>&1 || footer_origin_formats_ok=0
done
git -C "$FOOTER_PUBLIC" remote set-url origin https://github.com/feel-flow/ff-dev-toolkit.git
if [[ "$footer_origin_formats_ok" -eq 1 ]]; then ok "footer helper は正規 origin 4形式を受理"; else bad "footer helper が正規 origin 形式を誤拒否"; fi
footer_isolation_marker="$TMP/footer-git-isolation"
FAKE_FOOTER_ISOLATION_MARKER="$footer_isolation_marker" run_footer_helper --public-checkout "$FOOTER_PUBLIC" >/dev/null 2>&1
if [[ -f "$footer_isolation_marker" ]]; then ok "公式タグ取得は repository-local Git 設定から隔離"; else bad "公式タグ取得が local insteadOf の影響を受ける"; fi
FOOTER_NO_ORIGIN="$TMP/footer-no-origin"
mkdir -p "$FOOTER_NO_ORIGIN"
git -C "$FOOTER_NO_ORIGIN" init -q
if ! footer_no_origin_out="$(run_footer_helper --public-checkout "$FOOTER_NO_ORIGIN" 2>&1)" && [[ "$footer_no_origin_out" == *"origin URL"* ]]; then ok "footer helper は origin 不在を明示拒否"; else bad "footer helper が origin 不在を許可"; fi

footer_lock_marker="$TMP/footer-lock-marker"
footer_release_marker="$TMP/footer-release-marker"
FAKE_FOOTER_LOCK_MARKER="$footer_lock_marker" FAKE_FOOTER_RELEASE_MARKER="$footer_release_marker" \
  PATH="$FOOTER_FAKE_BIN:$PATH" FAKE_FOOTER_REAL_GIT="$FOOTER_REAL_GIT" bash "$FOOTER_ROOT/scripts/update-dev-toolkit-changelog-footer.sh" --public-checkout "$FOOTER_PUBLIC" > "$TMP/footer-helper.out" 2>&1 &
footer_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -e "$footer_lock_marker" ]] && break; sleep 0.05; done
run_contract "$FOOTER_ROOT" --write
if [[ "$RC" -eq 2 && "$OUT" == *"集約が実行中"* && -d "$FOOTER_ROOT/changelog.d/.ff-changelog.lock" ]]; then ok "footer 編集中は materialize を実 lock で停止"; else bad "footer helper の lock が編集窓を覆わない"; fi
: > "$footer_release_marker"
set +e
wait "$footer_pid"
footer_rc=$?
set -e
if [[ "$footer_rc" -eq 0 && ! -e "$FOOTER_ROOT/changelog.d/.ff-changelog.lock" ]] && grep -Fqx '[Unreleased]: https://github.com/feel-flow/ff-dev-toolkit/compare/v1.1.0...HEAD' "$FOOTER_ROOT/oss/ff-dev-toolkit/CHANGELOG.md" && grep -Fqx '[1.1.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v1.0.0...v1.1.0' "$FOOTER_ROOT/oss/ff-dev-toolkit/CHANGELOG.md"; then ok "footer helper は公開タグへ収束して lock を解放"; else bad "footer helper の収束または lock 解放に失敗"; fi
if grep -Fqx '[1.0.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.10.1...v1.0.0' "$FOOTER_ROOT/oss/ff-dev-toolkit/CHANGELOG.md"; then ok "footer helper は SemVer を数値順で整列"; else bad "footer helper が version を辞書順で整列"; fi
if ! grep -Fq 'rc.1]:' "$FOOTER_ROOT/oss/ff-dev-toolkit/CHANGELOG.md"; then ok "footer helper は prerelease tag を比較 footer から除外"; else bad "footer helper が prerelease tag を stable 扱い"; fi

cp "$FOOTER_ROOT/oss/ff-dev-toolkit/CHANGELOG.md" "$TMP/footer-before-cmp0-race.md"
if footer_cmp0_race_out="$(PATH="$FOOTER_FAKE_BIN:$TEST_BIN:$PATH" FAKE_FOOTER_REAL_GIT="$(command -v git)" FAKE_CMP_REPLACE_AFTER=1 FAKE_CMP_REPLACE_TARGET="$FOOTER_ROOT/oss/ff-dev-toolkit/CHANGELOG.md" bash "$FOOTER_ROOT/scripts/update-dev-toolkit-changelog-footer.sh" --public-checkout "$FOOTER_PUBLIC" 2>&1)"; then footer_cmp0_race_rc=0; else footer_cmp0_race_rc=$?; fi
if [[ "$footer_cmp0_race_rc" -eq 2 && "$footer_cmp0_race_out" == *"比較中の CHANGELOG 外部置換"* && "$(cat "$FOOTER_ROOT/oss/ff-dev-toolkit/CHANGELOG.md")" == "external footer cmp replacement" ]]; then ok "footer 変更なし経路も cmp 後の外部置換を検出"; else bad "footer 変更なし経路が外部置換を成功扱い"; fi
mv "$TMP/footer-before-cmp0-race.md" "$FOOTER_ROOT/oss/ff-dev-toolkit/CHANGELOG.md"

cp "$FOOTER_ROOT/oss/ff-dev-toolkit/CHANGELOG.md" "$TMP/footer-valid.md"
printf '%s\n' '本文が footer 後に残る' >> "$FOOTER_ROOT/oss/ff-dev-toolkit/CHANGELOG.md"
before_bad_footer="$(cksum "$FOOTER_ROOT/oss/ff-dev-toolkit/CHANGELOG.md")"
set +e
bad_footer_out="$(run_footer_helper --public-checkout "$FOOTER_PUBLIC" 2>&1)"
bad_footer_rc=$?
set -e
if [[ "$bad_footer_rc" -eq 1 && "$bad_footer_out" == *"footer 開始後"* && "$(cksum "$FOOTER_ROOT/oss/ff-dev-toolkit/CHANGELOG.md")" == "$before_bad_footer" ]]; then ok "footer 後の本文を byte 不変で拒否"; else bad "footer helper が footer 後の本文を切り捨て"; fi
mv "$TMP/footer-valid.md" "$FOOTER_ROOT/oss/ff-dev-toolkit/CHANGELOG.md"
cp "$FOOTER_ROOT/oss/ff-dev-toolkit/CHANGELOG.md" "$TMP/footer-valid.md"
printf '%s\n' '[Unreleased]: https://github.com/feel-flow/ff-dev-toolkit/compare/v1.1.0...HEAD' >> "$FOOTER_ROOT/oss/ff-dev-toolkit/CHANGELOG.md"
before_duplicate_footer="$(cksum "$FOOTER_ROOT/oss/ff-dev-toolkit/CHANGELOG.md")"
set +e
duplicate_footer_out="$(run_footer_helper --public-checkout "$FOOTER_PUBLIC" 2>&1)"
duplicate_footer_rc=$?
set -e
if [[ "$duplicate_footer_rc" -eq 1 && "$duplicate_footer_out" == *"label が重複"* && "$(cksum "$FOOTER_ROOT/oss/ff-dev-toolkit/CHANGELOG.md")" == "$before_duplicate_footer" ]]; then ok "重複 footer label を byte 不変で拒否"; else bad "footer helper が重複 label を黙って修復"; fi
mv "$TMP/footer-valid.md" "$FOOTER_ROOT/oss/ff-dev-toolkit/CHANGELOG.md"

rm -f "$footer_lock_marker" "$footer_release_marker"
before_footer_signal="$(cksum "$FOOTER_ROOT/oss/ff-dev-toolkit/CHANGELOG.md")"
FAKE_FOOTER_LOCK_MARKER="$footer_lock_marker" FAKE_FOOTER_RELEASE_MARKER="$footer_release_marker" \
  PATH="$FOOTER_FAKE_BIN:$PATH" FAKE_FOOTER_REAL_GIT="$FOOTER_REAL_GIT" bash "$FOOTER_ROOT/scripts/update-dev-toolkit-changelog-footer.sh" --public-checkout "$FOOTER_PUBLIC" > "$TMP/footer-signal.out" 2>&1 &
footer_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -e "$footer_lock_marker" ]] && break; sleep 0.05; done
kill -TERM "$footer_pid"
: > "$footer_release_marker"
set +e
wait "$footer_pid"
footer_signal_rc=$?
set -e
if [[ "$footer_signal_rc" -eq 130 && "$(cksum "$FOOTER_ROOT/oss/ff-dev-toolkit/CHANGELOG.md")" == "$before_footer_signal" && ! -e "$FOOTER_ROOT/changelog.d/.ff-changelog.lock" ]]; then ok "footer helper は signal 中断でも本文を保全して lock を解放"; else bad "footer helper の signal 復旧に失敗"; fi
if grep -Fq 'signal により CHANGELOG footer 更新を中断' "$TMP/footer-signal.out"; then ok "footer helper は signal 中断を診断"; else bad "footer helper が signal を無言で終了"; fi

FOOTER_CHANGELOG="$FOOTER_ROOT/oss/ff-dev-toolkit/CHANGELOG.md"
write_changelog "$FOOTER_CHANGELOG"
before_footer_failure="$(cksum "$FOOTER_CHANGELOG")"
set +e
footer_early_signal_out="$(PATH="$FOOTER_FAKE_BIN:$TEST_BIN:$PATH" FAKE_FOOTER_REAL_GIT="$(command -v git)" FAKE_MKDIR_SIGNAL=1 bash "$FOOTER_ROOT/scripts/update-dev-toolkit-changelog-footer.sh" --public-checkout "$FOOTER_PUBLIC" 2>&1)"
footer_early_signal_rc=$?
set -e
if [[ "$footer_early_signal_rc" -eq 130 && "$footer_early_signal_out" == *"signal により"* && ! -e "$FOOTER_ROOT/changelog.d/.ff-changelog.lock" ]]; then ok "footer は lock mkdir 直後の signal でも stale lock を残さない"; else bad "footer の lock 取得直後 signal で stale lock が残る"; fi
mkdir "$FOOTER_ROOT/changelog.d/.ff-changelog.lock"
if footer_unowned_signal_out="$(PATH="$FOOTER_FAKE_BIN:$TEST_BIN:$PATH" FAKE_FOOTER_REAL_GIT="$(command -v git)" FAKE_MKDIR_SIGNAL=1 bash "$FOOTER_ROOT/scripts/update-dev-toolkit-changelog-footer.sh" --public-checkout "$FOOTER_PUBLIC" 2>&1)"; then footer_unowned_signal_rc=0; else footer_unowned_signal_rc=$?; fi
if [[ "$footer_unowned_signal_rc" -eq 130 && -d "$FOOTER_ROOT/changelog.d/.ff-changelog.lock" ]]; then ok "footer は取得前 signal で他 process の lock を削除しない"; else bad "footer が未所有 lock を signal 復旧で削除"; fi
rmdir "$FOOTER_ROOT/changelog.d/.ff-changelog.lock"
set +e
footer_cmp_out="$(PATH="$FOOTER_FAKE_BIN:$TEST_BIN:$PATH" FAKE_FOOTER_REAL_GIT="$(command -v git)" FAKE_CMP_FAIL=1 bash "$FOOTER_ROOT/scripts/update-dev-toolkit-changelog-footer.sh" --public-checkout "$FOOTER_PUBLIC" 2>&1)"
footer_cmp_rc=$?
set -e
if [[ "$footer_cmp_rc" -eq 2 && "$footer_cmp_out" == *"cmp exit=2"* && "$(cksum "$FOOTER_CHANGELOG")" == "$before_footer_failure" ]]; then ok "footer cmp 障害は旧本体を保全して検査不能"; else bad "footer cmp 障害を差分ありと誤診"; fi

if footer_awk_out="$(FAKE_FOOTER_AWK_FAIL=1 run_footer_helper --public-checkout "$FOOTER_PUBLIC" 2>&1)"; then footer_awk_rc=0; else footer_awk_rc=$?; fi
if [[ "$footer_awk_rc" -eq 2 && "$footer_awk_out" == *"awk exit=9"* && "$(cksum "$FOOTER_CHANGELOG")" == "$before_footer_failure" ]]; then ok "footer awk 障害を contract 違反でなく検査不能に分類"; else bad "footer awk 障害を入力違反と誤診"; printf '%s\n' "$footer_awk_out" | sed 's/^/    | /' >&2; fi

write_changelog "$FOOTER_CHANGELOG"
if footer_dangling_out="$(PATH="$FOOTER_FAKE_BIN:$TEST_BIN:$PATH" FAKE_FOOTER_REAL_GIT="$(command -v git)" FAKE_LN_DANGLING_RACE=1 bash "$FOOTER_ROOT/scripts/update-dev-toolkit-changelog-footer.sh" --public-checkout "$FOOTER_PUBLIC" 2>&1)"; then footer_dangling_rc=0; else footer_dangling_rc=$?; fi
footer_dangling_old=("$FOOTER_ROOT/oss/ff-dev-toolkit"/.ff-changelog-footer-old.*)
if [[ "$footer_dangling_rc" -eq 2 && -L "$FOOTER_CHANGELOG" && -f "${footer_dangling_old[0]}" ]]; then ok "footer も dangling symlink の install 競合を保持"; else bad "footer rollback が dangling symlink を上書き"; printf '    | rc=%s symlink=%s old=%s\n' "$footer_dangling_rc" "$([[ -L "$FOOTER_CHANGELOG" ]] && echo yes || echo no)" "${footer_dangling_old[0]}" >&2; printf '%s\n' "$footer_dangling_out" | sed 's/^/    | /' >&2; fi
rm -f "$FOOTER_CHANGELOG"; [[ ! -f "${footer_dangling_old[0]}" ]] || mv "${footer_dangling_old[0]}" "$FOOTER_CHANGELOG"; [[ ! -d "$FOOTER_ROOT/changelog.d/.ff-changelog.lock" ]] || /bin/rmdir "$FOOTER_ROOT/changelog.d/.ff-changelog.lock"

if footer_directory_out="$(PATH="$FOOTER_FAKE_BIN:$TEST_BIN:$PATH" FAKE_FOOTER_REAL_GIT="$(command -v git)" FAKE_LINK_DIRECTORY_RACE=1 bash "$FOOTER_ROOT/scripts/update-dev-toolkit-changelog-footer.sh" --public-checkout "$FOOTER_PUBLIC" 2>&1)"; then footer_directory_rc=0; else footer_directory_rc=$?; fi
footer_directory_old=("$FOOTER_ROOT/oss/ff-dev-toolkit"/.ff-changelog-footer-old.*)
if [[ "$footer_directory_rc" -eq 2 && -d "$FOOTER_CHANGELOG" && -z "$(find "$FOOTER_CHANGELOG" -mindepth 1 -maxdepth 1 -print -quit)" && -f "${footer_directory_old[0]}" ]]; then ok "footer install は directory destination の内側へ link を作らない"; else bad "footer install が directory destination を追跡"; printf '%s\n' "$footer_directory_out" | sed 's/^/    | /' >&2; fi
rmdir "$FOOTER_CHANGELOG"; mv "${footer_directory_old[0]}" "$FOOTER_CHANGELOG"; [[ ! -d "$FOOTER_ROOT/changelog.d/.ff-changelog.lock" ]] || /bin/rmdir "$FOOTER_ROOT/changelog.d/.ff-changelog.lock"

set +e
footer_install_out="$(PATH="$FOOTER_FAKE_BIN:$TEST_BIN:$PATH" FAKE_FOOTER_REAL_GIT="$(command -v git)" FAKE_LN_FAIL_CHANGELOG=1 bash "$FOOTER_ROOT/scripts/update-dev-toolkit-changelog-footer.sh" --public-checkout "$FOOTER_PUBLIC" 2>&1)"
footer_install_rc=$?
set -e
if [[ "$footer_install_rc" -eq 2 && "$footer_install_out" == *"install できません"* && "$(cksum "$FOOTER_CHANGELOG")" == "$before_footer_failure" && ! -e "$FOOTER_ROOT/changelog.d/.ff-changelog.lock" ]]; then ok "footer install 失敗は旧本体と lock を復旧"; else bad "footer install 失敗で旧本体を喪失"; fi

set +e
footer_install_signal_out="$(PATH="$FOOTER_FAKE_BIN:$TEST_BIN:$PATH" FAKE_FOOTER_REAL_GIT="$(command -v git)" FAKE_LN_INSTALL_SIGNAL=1 bash "$FOOTER_ROOT/scripts/update-dev-toolkit-changelog-footer.sh" --public-checkout "$FOOTER_PUBLIC" 2>&1)"
footer_install_signal_rc=$?
set -e
if [[ "$footer_install_signal_rc" -eq 130 && "$footer_install_signal_out" == *"signal により"* && "$(cksum "$FOOTER_CHANGELOG")" == "$before_footer_failure" && ! -e "$FOOTER_ROOT/changelog.d/.ff-changelog.lock" ]]; then ok "footer install 直後の signal でも旧本体を復旧"; else bad "footer install signal で旧本体を喪失"; fi

set +e
footer_race_out="$(PATH="$FOOTER_FAKE_BIN:$TEST_BIN:$PATH" FAKE_FOOTER_REAL_GIT="$(command -v git)" FAKE_LN_ATOMIC_RACE=1 bash "$FOOTER_ROOT/scripts/update-dev-toolkit-changelog-footer.sh" --public-checkout "$FOOTER_PUBLIC" 2>&1)"
footer_race_rc=$?
set -e
if [[ "$footer_race_rc" -eq 2 && "$footer_race_out" == *"外部ファイル"* && "$(cat "$FOOTER_CHANGELOG")" == "external atomic replacement" ]]; then ok "footer install 窓の外部 atomic replacement を保持"; else bad "footer install が外部 atomic replacement を上書き"; fi
rm "$FOOTER_CHANGELOG"
footer_old=("$FOOTER_ROOT/oss/ff-dev-toolkit"/.ff-changelog-footer-old.*)
if [[ "${#footer_old[@]}" -eq 1 && -f "${footer_old[0]}" ]]; then mv "${footer_old[0]}" "$FOOTER_CHANGELOG"; ok "footer race 後の旧本体 backup を復旧可能"; else bad "footer race 後の旧本体 backup が一意でない"; fi

write_changelog "$FOOTER_CHANGELOG"
if footer_pre_mv_out="$(PATH="$FOOTER_FAKE_BIN:$TEST_BIN:$PATH" FAKE_FOOTER_REAL_GIT="$FOOTER_REAL_GIT" FAKE_FOOTER_REAL_AWK="$FOOTER_REAL_AWK" FAKE_MV_FOOTER_ATOMIC_RACE=1 bash "$FOOTER_ROOT/scripts/update-dev-toolkit-changelog-footer.sh" --public-checkout "$FOOTER_PUBLIC" 2>&1)"; then footer_pre_mv_rc=0; else footer_pre_mv_rc=$?; fi
footer_pre_mv_snapshots=("$FOOTER_ROOT/oss/ff-dev-toolkit"/.ff-changelog-footer-input.*)
if [[ "$footer_pre_mv_rc" -eq 2 && "$footer_pre_mv_out" == *"退避直前"* && "$(cat "$FOOTER_CHANGELOG")" == "external pre-mv replacement" && -f "${footer_pre_mv_snapshots[0]}" ]]; then ok "footer 退避直前の外部置換で元 snapshot を保持"; else bad "footer 退避直前 race で元 snapshot を喪失"; printf '    | rc=%s changelog=%s snapshot=%s\n' "$footer_pre_mv_rc" "$(cat "$FOOTER_CHANGELOG" 2>/dev/null || true)" "${footer_pre_mv_snapshots[0]}" >&2; printf '%s\n' "$footer_pre_mv_out" | sed 's/^/    | /' >&2; fi
rm -f "${footer_pre_mv_snapshots[@]}"
[[ ! -d "$FOOTER_ROOT/changelog.d/.ff-changelog.lock" ]] || /bin/rmdir "$FOOTER_ROOT/changelog.d/.ff-changelog.lock"

write_changelog "$FOOTER_CHANGELOG"
if footer_late_old_out="$(PATH="$FOOTER_FAKE_BIN:$TEST_BIN:$PATH" FAKE_FOOTER_REAL_GIT="$(command -v git)" FAKE_RM_MUTATE_FOOTER_OLD=1 bash "$FOOTER_ROOT/scripts/update-dev-toolkit-changelog-footer.sh" --public-checkout "$FOOTER_PUBLIC" 2>&1)"; then footer_late_old_rc=0; else footer_late_old_rc=$?; fi
footer_snapshots=("$FOOTER_ROOT/oss/ff-dev-toolkit"/.ff-changelog-footer-input.*)
if [[ "$footer_late_old_rc" -eq 2 && "$footer_late_old_out" == *"旧本体削除中の外部編集"* && -f "${footer_snapshots[0]}" ]] && grep -Fqx 'external footer old inode edit' "${footer_snapshots[0]}"; then ok "footer 確定後の旧 inode 遅延書き込みを検出して snapshot を保持"; else bad "footer が旧 inode 遅延書き込みを消失"; fi
rm -f "${footer_snapshots[@]}"
[[ ! -d "$FOOTER_ROOT/changelog.d/.ff-changelog.lock" ]] || /bin/rmdir "$FOOTER_ROOT/changelog.d/.ff-changelog.lock"

write_changelog "$FOOTER_CHANGELOG"
before_footer_snapshot_race="$(cksum "$FOOTER_CHANGELOG")"
if footer_snapshot_dir_out="$(PATH="$FOOTER_FAKE_BIN:$TEST_BIN:$PATH" FAKE_FOOTER_REAL_GIT="$(command -v git)" FAKE_PERL_INPUT_DIRECTORY_RACE=1 bash "$FOOTER_ROOT/scripts/update-dev-toolkit-changelog-footer.sh" --public-checkout "$FOOTER_PUBLIC" 2>&1)"; then footer_snapshot_dir_rc=0; else footer_snapshot_dir_rc=$?; fi
footer_snapshot_dirs=("$FOOTER_ROOT/oss/ff-dev-toolkit"/.ff-changelog-footer-input.*)
if [[ "$footer_snapshot_dir_rc" -eq 2 && -d "${footer_snapshot_dirs[0]}" && -z "$(find "${footer_snapshot_dirs[0]}" -mindepth 1 -maxdepth 1 -print -quit)" && "$(cksum "$FOOTER_CHANGELOG")" == "$before_footer_snapshot_race" ]]; then ok "footer snapshot は directory 宛先競合の内部へ link しない"; else bad "footer snapshot が directory 宛先を追跡"; printf '%s\n' "$footer_snapshot_dir_out" | sed 's/^/    | /' >&2; fi
rmdir "${footer_snapshot_dirs[0]}"; [[ ! -d "$FOOTER_ROOT/changelog.d/.ff-changelog.lock" ]] || /bin/rmdir "$FOOTER_ROOT/changelog.d/.ff-changelog.lock"

write_changelog "$FOOTER_CHANGELOG"
if footer_final_replace_out="$(PATH="$FOOTER_FAKE_BIN:$TEST_BIN:$PATH" FAKE_FOOTER_REAL_GIT="$FOOTER_REAL_GIT" FAKE_FOOTER_REAL_AWK="$FOOTER_REAL_AWK" FAKE_RM_REPLACE_FOOTER_CURRENT=1 FAKE_RM_FOOTER_CHANGELOG="$FOOTER_CHANGELOG" bash "$FOOTER_ROOT/scripts/update-dev-toolkit-changelog-footer.sh" --public-checkout "$FOOTER_PUBLIC" 2>&1)"; then footer_final_replace_rc=0; else footer_final_replace_rc=$?; fi
footer_generated=("$FOOTER_ROOT/oss/ff-dev-toolkit"/.ff-changelog-footer-new.*)
if [[ "$footer_final_replace_rc" -eq 2 && "$footer_final_replace_out" == *"外部置換"* && "$(cat "$FOOTER_CHANGELOG")" == "external footer final replacement" && -f "${footer_generated[0]}" ]] && grep -Fq '[Unreleased]:' "${footer_generated[0]}"; then ok "footer 確定中の外部置換でも生成結果を保持"; else bad "footer 確定中の外部置換で生成結果を喪失"; printf '    | rc=%s current=%s generated=%s\n' "$footer_final_replace_rc" "$(cat "$FOOTER_CHANGELOG" 2>/dev/null || true)" "${footer_generated[0]}" >&2; printf '%s\n' "$footer_final_replace_out" | sed 's/^/    | /' >&2; fi
if [[ -f "${footer_generated[0]}" ]]; then rm -f "$FOOTER_CHANGELOG"; mv "${footer_generated[0]}" "$FOOTER_CHANGELOG"; else write_changelog "$FOOTER_CHANGELOG"; fi

set +e
footer_fetch_out="$(PATH="$FOOTER_FAKE_BIN:$PATH" FAKE_FOOTER_REAL_GIT="$(command -v git)" FAKE_FOOTER_LS_REMOTE_FAIL=1 bash "$FOOTER_ROOT/scripts/update-dev-toolkit-changelog-footer.sh" --public-checkout "$FOOTER_PUBLIC" 2>&1)"
footer_fetch_rc=$?
set -e
if [[ "$footer_fetch_rc" -eq 2 && "$footer_fetch_out" == *"公開タグ一覧を取得できません"* ]]; then ok "footer tag fetch 障害を検査不能として伝播"; else bad "footer tag fetch 障害を握り潰す"; fi

write_changelog "$FOOTER_CHANGELOG"
if footer_lock_change_out="$(PATH="$FOOTER_FAKE_BIN:$TEST_BIN:$PATH" FAKE_FOOTER_REAL_GIT="$(command -v git)" FAKE_RMDIR_FAIL=1 bash "$FOOTER_ROOT/scripts/update-dev-toolkit-changelog-footer.sh" --public-checkout "$FOOTER_PUBLIC" 2>&1)"; then footer_lock_change_rc=0; else footer_lock_change_rc=$?; fi
if [[ "$footer_lock_change_rc" -eq 2 && "$footer_lock_change_out" == *"lock を解放できません"* && -d "$FOOTER_ROOT/changelog.d/.ff-changelog.lock" ]] && grep -Fq '[Unreleased]:' "$FOOTER_CHANGELOG"; then ok "footer 更新ありの lock 解放失敗を非0で診断"; else bad "footer 更新ありの lock 解放失敗を成功扱い"; fi
/bin/rmdir "$FOOTER_ROOT/changelog.d/.ff-changelog.lock"
before_footer_nochange_lock="$(cksum "$FOOTER_CHANGELOG")"
if footer_lock_nochange_out="$(PATH="$FOOTER_FAKE_BIN:$TEST_BIN:$PATH" FAKE_FOOTER_REAL_GIT="$(command -v git)" FAKE_RMDIR_FAIL=1 bash "$FOOTER_ROOT/scripts/update-dev-toolkit-changelog-footer.sh" --public-checkout "$FOOTER_PUBLIC" 2>&1)"; then footer_lock_nochange_rc=0; else footer_lock_nochange_rc=$?; fi
if [[ "$footer_lock_nochange_rc" -eq 2 && "$footer_lock_nochange_out" == *"lock を解放できません"* && -d "$FOOTER_ROOT/changelog.d/.ff-changelog.lock" && "$(cksum "$FOOTER_CHANGELOG")" == "$before_footer_nochange_lock" ]]; then ok "footer 変更なしの lock 解放失敗を非0で診断"; else bad "footer 変更なしの lock 解放失敗を成功扱い"; fi
/bin/rmdir "$FOOTER_ROOT/changelog.d/.ff-changelog.lock"

FOOTER_NO_STABLE_SEED="$TMP/footer-no-stable-seed"
FOOTER_NO_STABLE_BARE="$TMP/footer-no-stable-origin.git"
FOOTER_NO_STABLE="$TMP/footer-no-stable"
mkdir -p "$FOOTER_NO_STABLE_SEED"
git -C "$FOOTER_NO_STABLE_SEED" init -q
git -C "$FOOTER_NO_STABLE_SEED" config user.email footer@example.com
git -C "$FOOTER_NO_STABLE_SEED" config user.name footer-test
printf '%s\n' '# prerelease only' > "$FOOTER_NO_STABLE_SEED/README.md"
git -C "$FOOTER_NO_STABLE_SEED" add -A && git -C "$FOOTER_NO_STABLE_SEED" commit -qm prerelease
git -C "$FOOTER_NO_STABLE_SEED" tag v1.0.0-rc.1
git clone -q --bare "$FOOTER_NO_STABLE_SEED" "$FOOTER_NO_STABLE_BARE"
git clone -q "$FOOTER_NO_STABLE_BARE" "$FOOTER_NO_STABLE"
git -C "$FOOTER_NO_STABLE" remote set-url origin https://github.com/feel-flow/ff-dev-toolkit.git
git -C "$FOOTER_NO_STABLE" config url."$FOOTER_NO_STABLE_BARE".insteadOf https://github.com/feel-flow/ff-dev-toolkit.git
FF_CHANGELOG_TEST_REMOTE="$FOOTER_NO_STABLE_BARE"
set +e
footer_no_stable_out="$(run_footer_helper --public-checkout "$FOOTER_NO_STABLE" 2>&1)"
footer_no_stable_rc=$?
set -e
if [[ "$footer_no_stable_rc" -eq 2 && "$footer_no_stable_out" == *"SemVer タグがありません"* ]]; then ok "footer は stable tag 0 件を明示診断"; else bad "footer が prerelease を stable tag と誤認"; fi
if grep -Fq 'mktemp "$changelog_dir/.ff-changelog-footer-new.' "$FOOTER_HELPER"; then ok "footer 一時ファイルは CHANGELOG と同一 filesystem"; else bad "footer 一時ファイルが別 filesystem に置かれる"; fi
if LIVE_OUT="$(bash "$TARGET" --check 2>&1)" && [[ "$LIVE_OUT" == *"FRAGMENTS="* ]]; then
  ok "live 断片が contract を満たす"
else
  bad "live 断片 contract が失敗"
  printf '%s\n' "$LIVE_OUT" | sed 's/^/    | /' >&2
fi

default_ref="$(git -C "$REPO_ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD)"
default_branch="${default_ref#origin/}"
if ! git -C "$REPO_ROOT" fetch origin "+refs/heads/${default_branch}:refs/remotes/origin/${default_branch}" >/dev/null 2>&1; then
  bad "共有 CHANGELOG 判定前に latest default branch を fetch できない"
elif ! git -C "$REPO_ROOT" rev-parse --verify "${default_ref}^{commit}" >/dev/null 2>&1; then
  bad "共有 CHANGELOG 判定の default branch を解決できない"
elif ! git -C "$REPO_ROOT" merge-base --is-ancestor "$default_ref" HEAD; then
  bad "共有 CHANGELOG 判定前に最新 default branch を取り込んでいない"
elif git -C "$REPO_ROOT" diff --quiet "$default_ref" -- oss/ff-dev-toolkit/CHANGELOG.md; then
  ok "通常 PR は共有 CHANGELOG を直接編集しない"
else
  base_version="$(git -C "$REPO_ROOT" show "$default_ref:plugins/ff-dev-toolkit/.claude-plugin/plugin.json" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  current_version="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$REPO_ROOT/plugins/ff-dev-toolkit/.claude-plugin/plugin.json" | head -1)"
  base_sha="$(git -C "$REPO_ROOT" rev-parse "${default_ref}^{commit}")"
  set +e
  footer_out="$(bash "$REPO_ROOT/scripts/check-full-gate-reuse.sh" --green-sha "$base_sha" 2>&1)"
  footer_rc=$?
  set -e
  if [[ -n "$base_version" && "$current_version" != "$base_version" ]]; then
    ok "リリース準備だけが共有 CHANGELOG を編集"
  elif [[ "$footer_rc" -eq 0 && "$footer_out" == *"FULL_GATE_REUSE=CHANGELOG_FOOTER_ONLY"* ]]; then
    ok "比較リンク footer-only PR だけが version 据え置きで CHANGELOG を編集"
  else
    bad "通常 PR が共有 CHANGELOG を直接編集"
  fi
fi
