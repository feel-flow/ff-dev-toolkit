# shellcheck shell=bash
FOOTER_FIX="$TMP/footer-policy"
mkdir -p "$FOOTER_FIX/scripts" "$FOOTER_FIX/oss/ff-dev-toolkit"
cp "$REPO_ROOT/scripts/check-full-gate-reuse.sh" "$FOOTER_FIX/scripts/check-full-gate-reuse.sh"
ff_git_fixture_init "$FOOTER_FIX" "footer-test" "footer@example.com"
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
ff_git_fixture_init "$FOOTER_PUBLIC_SEED" "footer-test" "footer@example.com"
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
if [[ "$footer_fetch_out" != *"認証ヘルパーが必要"* ]]; then ok "認証以外の tag fetch 障害では認証案内を出さない"; else bad "認証以外の障害に認証案内を出した: $footer_fetch_out"; fi

# 認証失敗（配布リポジトリが Private のとき credential helper が無い。ADR-050 で Public へ戻した後も回帰ガードとして残す）: ハングせず exit 2 + 認証案内 + CHANGELOG 不変
footer_auth_before="$(cat "$FOOTER_CHANGELOG")"
set +e
footer_auth_out="$(PATH="$FOOTER_FAKE_BIN:$PATH" FAKE_FOOTER_REAL_GIT="$(command -v git)" FAKE_FOOTER_LS_REMOTE_AUTH_FAIL=1 bash "$FOOTER_ROOT/scripts/update-dev-toolkit-changelog-footer.sh" --public-checkout "$FOOTER_PUBLIC" 2>&1)"
footer_auth_rc=$?
set -e
if [[ "$footer_auth_rc" -eq 2 && "$footer_auth_out" == *"公開タグ一覧を取得できません"* && "$footer_auth_out" == *"認証ヘルパーが必要"* && "$footer_auth_out" == *"gh auth setup-git"* ]]; then ok "認証失敗は exit 2 で止まり、認証ヘルパーの案内を出す"; else bad "認証失敗の診断が不正: rc=$footer_auth_rc out=$footer_auth_out"; fi
if [[ "$(cat "$FOOTER_CHANGELOG")" == "$footer_auth_before" ]]; then ok "認証失敗時に CHANGELOG を変更しない"; else bad "認証失敗時に CHANGELOG が変わった"; fi

# 認証は通るがアクセス権が無い（Private リポジトリでは 404 "Repository not found" になる形）: 認証案内ではなくアクセス権の案内
set +e
footer_denied_out="$(PATH="$FOOTER_FAKE_BIN:$PATH" FAKE_FOOTER_REAL_GIT="$(command -v git)" FAKE_FOOTER_LS_REMOTE_DENIED=1 bash "$FOOTER_ROOT/scripts/update-dev-toolkit-changelog-footer.sh" --public-checkout "$FOOTER_PUBLIC" 2>&1)"
footer_denied_rc=$?
set -e
if [[ "$footer_denied_rc" -eq 2 && "$footer_denied_out" == *"アクセス権がありません"* && "$footer_denied_out" != *"認証ヘルパーが必要"* ]]; then ok "アクセス権不足は認証案内ではなく org 所属・SSO の確認を促す"; else bad "アクセス権不足の診断が不正: rc=$footer_denied_rc out=$footer_denied_out"; fi

# global の url.*.insteadOf が公開 URL を SSH へ書き換えている: ネットワークへ出る前に診断して停止
set +e
footer_rewrite_out="$(PATH="$FOOTER_FAKE_BIN:$PATH" FAKE_FOOTER_REAL_GIT="$(command -v git)" FAKE_FOOTER_INSTEADOF_REWRITE=1 bash "$FOOTER_ROOT/scripts/update-dev-toolkit-changelog-footer.sh" --public-checkout "$FOOTER_PUBLIC" 2>&1)"
footer_rewrite_rc=$?
set -e
if [[ "$footer_rewrite_rc" -eq 2 && "$footer_rewrite_out" == *"insteadOf が公開 URL を書き換えています"* ]]; then ok "global insteadOf の書き換えを送信前に検出して停止"; else bad "insteadOf の書き換えを検出できない: rc=$footer_rewrite_rc out=$footer_rewrite_out"; fi
# 書き換え先に認証情報（userinfo・query）があっても、拒否の診断へ出さない
set +e
footer_cred_out="$(PATH="$FOOTER_FAKE_BIN:$PATH" FAKE_FOOTER_REAL_GIT="$(command -v git)" FAKE_FOOTER_INSTEADOF_REWRITE=2 bash "$FOOTER_ROOT/scripts/update-dev-toolkit-changelog-footer.sh" --public-checkout "$FOOTER_PUBLIC" 2>&1)"
footer_cred_rc=$?
set -e
if [[ "$footer_cred_rc" -eq 2 && "$footer_cred_out" == *"表示しません"* && "$footer_cred_out" != *SYNTHETIC-* ]]; then ok "認証情報付きの rewrite は拒否し、URL を診断へ出さない"; else bad "認証情報付き rewrite の診断: rc=${footer_cred_rc}（SYNTHETIC の有無: $([[ "$footer_cred_out" == *SYNTHETIC-* ]] && echo あり || echo なし)）"; fi

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
ff_git_fixture_init "$FOOTER_NO_STABLE_SEED" "footer-test" "footer@example.com"
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

if [[ -n "${FF_RELEASE_GATE_HEAD:-}" ]]; then
  if [[ "$FF_RELEASE_GATE_HEAD" =~ ^[0-9a-f]{40}$ && "$(git -C "$REPO_ROOT" rev-parse HEAD)" == "$FF_RELEASE_GATE_HEAD" ]]; then
    default_ref="$FF_RELEASE_GATE_HEAD"
  else
    default_ref=""
  fi
else
  if ! default_ref="$(git -C "$REPO_ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD)"; then
    default_ref=""
  fi
fi
if [[ -z "$default_ref" ]]; then
  bad "origin/HEAD が無く共有 CHANGELOG 判定を開始できない"
elif [[ -z "${FF_RELEASE_GATE_HEAD:-}" && "$default_ref" != origin/* ]]; then
  bad "origin/HEAD が origin/* ではない"
# CI では fetch しない — checkout は特定 SHA に固定されていて rebase という対処が存在せず、
# 走行中（週次 run-all は約 25 分）に default branch が進んだことを理由に赤にしても実害と
# 対応しない。判定入力を job 開始時点の remote-tracking ref に閉じる（check-version-claims.sh
# が CI について既に採っている形と同じ。workflow 側が既定ブランチ checkout の回にその ref を
# checkout SHA へ固定する）。ローカルは従来どおり fetch して最新の base で判定する —
# 作業者には rebase という対処があるので、古い base で緑を出す方が有害。
elif [[ -z "${FF_RELEASE_GATE_HEAD:-}" && "$FF_AMBIENT_GITHUB_ACTIONS" != true ]] \
  && ! git -C "$REPO_ROOT" fetch origin "+refs/heads/${default_ref#origin/}:refs/remotes/origin/${default_ref#origin/}" >/dev/null 2>&1; then
  bad "共有 CHANGELOG 判定前に latest default branch を fetch できない"
elif ! git -C "$REPO_ROOT" rev-parse --verify "${default_ref}^{commit}" >/dev/null 2>&1; then
  bad "共有 CHANGELOG 判定の default branch を解決できない"
elif ! git -C "$REPO_ROOT" merge-base --is-ancestor "$default_ref" HEAD; then
  # 古い base で「通常 PR は共有 CHANGELOG を直接編集しない」を判定すると、base 側で
  # 既に入った編集を自分の変更と読み違える。判定は諦めず、分類だけ鮮度へ寄せる。
  ff_report_stale_base "共有 CHANGELOG の編集判定" "$REPO_ROOT"
  bad "base が先行しているため共有 CHANGELOG 判定が成立しない（鮮度・変更起因ではない）"
else
  # 判定の本体は tests/lib/shared-changelog-judge.sh（リリースの模擬検査の stub も同じ関数を呼ぶ。Issue `#2619`）
  shared_changelog_rc=0
  ff_shared_changelog_judge "$REPO_ROOT" "$default_ref" || shared_changelog_rc=$?
  case "${shared_changelog_rc}:${SHARED_CHANGELOG_VERDICT}" in
    0:unchanged) ok "通常 PR は共有 CHANGELOG を直接編集しない" ;;
    0:release-prep) ok "リリース準備だけが共有 CHANGELOG を編集" ;;
    0:footer-only) ok "比較リンク footer-only PR だけが version 据え置きで CHANGELOG を編集" ;;
    *) bad "通常 PR が共有 CHANGELOG を直接編集" ;;
  esac
fi

# 判定表の固定: 切り出した判定（tests/lib/shared-changelog-judge.sh）を一時リポジトリで 4 分類すべてに当てる。
# 上の live 判定は手元の状態（多くは unchanged）しか通らないので、「version が base と違う / footer-only だけを
# 許す」という判定表そのものはここで固定する。タグ未作成の準備済み版へ同じ版のまま断片を畳む編集
# （version 据え置き）は direct-edit のまま — リリース側は後着断片を新しい版として準備する（Issue `#2619`）。
JUDGE_FIX="$TMP/shared-changelog-judge"
mkdir -p "$JUDGE_FIX/scripts" "$JUDGE_FIX/oss/ff-dev-toolkit" "$JUDGE_FIX/plugins/ff-dev-toolkit/.claude-plugin"
cp "$REPO_ROOT/scripts/check-full-gate-reuse.sh" "$JUDGE_FIX/scripts/check-full-gate-reuse.sh"
ff_git_fixture_init "$JUDGE_FIX" "footer-test" "footer@example.com"
judge_write_version() { printf '{\n  "name": "ff-dev-toolkit",\n  "version": "%s"\n}\n' "$1" > "$JUDGE_FIX/plugins/ff-dev-toolkit/.claude-plugin/plugin.json"; }
judge_write_version 1.1.0
printf '%s\n' '# Changelog' '' '## [Unreleased]' '' '## [1.1.0] - 2026-01-02' '' '### 修正' '' '- 準備した修正' '' \
  '[Unreleased]: https://github.com/feel-flow/ff-dev-toolkit/compare/v1.0.0...HEAD' > "$JUDGE_FIX/oss/ff-dev-toolkit/CHANGELOG.md"
git -C "$JUDGE_FIX" add -A && git -C "$JUDGE_FIX" commit -qm "release: ff-dev-toolkit v1.1.0"
git -C "$JUDGE_FIX" update-ref refs/remotes/origin/develop HEAD
judge_case() { # $1=期待する分類 $2=期待する終了コード $3=見出し
  local rc=0
  ff_shared_changelog_judge "$JUDGE_FIX" origin/develop || rc=$?
  if [[ "$rc" -eq "$2" && "$SHARED_CHANGELOG_VERDICT" == "$1" ]]; then ok "$3"; else bad "$3（rc=${rc} verdict=${SHARED_CHANGELOG_VERDICT:-なし}）"; fi
}
judge_case unchanged 0 "共有 CHANGELOG の判定: base と同じなら unchanged"
# 同じ版のまま準備済みの版節へ断片を畳む編集（version 据え置き・作業ツリーの変更）は直接編集と区別できない
awk '{ print } $0 == "- 準備した修正" { print "- 後着した修正" }' "$JUDGE_FIX/oss/ff-dev-toolkit/CHANGELOG.md" > "$JUDGE_FIX/cl.new" \
  && mv "$JUDGE_FIX/cl.new" "$JUDGE_FIX/oss/ff-dev-toolkit/CHANGELOG.md"
judge_case direct-edit 1 "共有 CHANGELOG の判定: version 据え置きで版節へ項目を足す編集は direct-edit（同じ版への再集約は通らない）"
# 後着断片を新しい版として準備した形（準備済みの版節は残し、version を上げて新しい版節を足す）
git -C "$JUDGE_FIX" checkout -q -- oss/ff-dev-toolkit/CHANGELOG.md
awk '{ print } $0 == "## [Unreleased]" { print ""; print "## [1.1.1] - 2026-01-03"; print ""; print "### 修正"; print ""; print "- 後着した修正" }' \
  "$JUDGE_FIX/oss/ff-dev-toolkit/CHANGELOG.md" > "$JUDGE_FIX/cl.new" && mv "$JUDGE_FIX/cl.new" "$JUDGE_FIX/oss/ff-dev-toolkit/CHANGELOG.md"
judge_write_version 1.1.1
judge_case release-prep 0 "共有 CHANGELOG の判定: version を上げて新しい版節を足す準備は release-prep"
git -C "$JUDGE_FIX" checkout -q -- oss/ff-dev-toolkit/CHANGELOG.md plugins/ff-dev-toolkit/.claude-plugin/plugin.json
printf '%s\n' '[1.0.0]: https://github.com/feel-flow/ff-dev-toolkit/releases/tag/v1.0.0' >> "$JUDGE_FIX/oss/ff-dev-toolkit/CHANGELOG.md"
git -C "$JUDGE_FIX" commit -qam "release: CHANGELOG 比較リンクを v1.0.0 へ追従"
judge_case footer-only 0 "共有 CHANGELOG の判定: 比較リンクの footer だけのコミットは footer-only"
printf '%s\n' '- 通常 PR の直接編集' >> "$JUDGE_FIX/oss/ff-dev-toolkit/CHANGELOG.md"
git -C "$JUDGE_FIX" commit -qam "feat: direct edit"
judge_case direct-edit 1 "共有 CHANGELOG の判定: version 据え置きの本文編集コミットは direct-edit"
rm -f "$JUDGE_FIX/plugins/ff-dev-toolkit/.claude-plugin/plugin.json"
judge_case direct-edit 1 "共有 CHANGELOG の判定: 作業ツリーの plugin.json を読めない回は release-prep にせず direct-edit"

# --- 契約側の要素を消す変更には breaking 断片が要る ---
# 公開面の一覧（PUBLIC-SURFACE.md）と実体を**同時に**消す PR は、skill-count-consistency の
# 集合一致では緑になる（一覧も実体も同じだけ縮むため）。互換性の約束の対象が黙って消えるのは
# まさに破壊的変更なので、base の一覧に在って HEAD の一覧に無い契約要素があるなら、
# changelog.d に breaking 断片を要求する。対象は skill の起動名 / hook の三つ組 /
# 導入先に配置されるパス / 契約側の FF_*（抽出は tests/lib/public-surface.sh と共有）。
#
# base は共有 CHANGELOG の直編集判定と同じ default branch。FF_SURFACE_BASE_REF は
# 変異バッテリー専用の差し替え口で、通常運用では設定しない（他 suite の FF_*_ROOT と同じ扱い）。
SURFACE_LIB="$REPO_ROOT/plugins/ff-dev-toolkit/tests/lib/public-surface.sh"
SURFACE_DOC_REL="plugins/ff-dev-toolkit/PUBLIC-SURFACE.md"
surface_base_ref="${FF_SURFACE_BASE_REF:-${default_ref:-}}"
if [[ ! -f "$SURFACE_LIB" ]]; then
  bad "公開面の共有実装がありません: $SURFACE_LIB"
elif [[ ! -f "$REPO_ROOT/$SURFACE_DOC_REL" ]]; then
  bad "公開面の一覧がありません: $SURFACE_DOC_REL"
elif [[ -z "$surface_base_ref" ]]; then
  bad "base を解決できず契約要素の削除判定が成立しない（fail-closed）"
elif ! git -C "$REPO_ROOT" merge-base --is-ancestor "$surface_base_ref" HEAD 2>/dev/null; then
  bad "base が先行しているため契約要素の削除判定が成立しない（鮮度・変更起因ではない）"
else
  # shellcheck source=../../lib/public-surface.sh
  . "$SURFACE_LIB"
  # 判定の本体（live の判定と下の変異バッテリーが共有する）。
  # $1=base の一覧（空文字なら base に一覧が無い = 削除は起こり得ない） $2=HEAD の一覧 $3=断片のディレクトリ
  # 消えた契約トークンの**それぞれ**を、どれかの breaking 断片が名指していることを要求する
  # （無関係な breaking 断片が 1 件あるだけでは通さない）。名指しの判定は
  # tests/lib/public-surface.sh の ff_surface_token_needle / ff_surface_names_token。
  # rc 0: 消えた要素なし（SURFACE_JUDGE_REMOVED が空）か、全部名指しあり / 1: 名指しの無い要素がある
  # （SURFACE_JUDGE_UNNAMED に列挙）/ 2: HEAD から契約要素を 1 件も抽出できない
  surface_breaking_judge() {
    local base_doc="$1" head_doc="$2" frag_dir="$3" base_set="" head_set token needle
    local frags=()
    SURFACE_JUDGE_REMOVED=""
    SURFACE_JUDGE_UNNAMED=""
    head_set="$(ff_surface_contract_tokens "$head_doc" | LC_ALL=C sort -u)"
    if [[ -n "$base_doc" ]]; then
      base_set="$(ff_surface_contract_tokens "$base_doc" | LC_ALL=C sort -u)"
    fi
    if [[ -n "$base_set" && -z "$head_set" ]]; then
      return 2
    fi
    SURFACE_JUDGE_REMOVED="$(comm -23 <(printf '%s\n' "$base_set") <(printf '%s\n' "$head_set") | sed '/^$/d')"
    [[ -n "$SURFACE_JUDGE_REMOVED" ]] || return 0
    while IFS= read -r token; do
      [[ -n "$token" ]] && frags+=("$token")
    done < <(find "$frag_dir" -maxdepth 1 -type f -name '*.breaking.*.md' 2>/dev/null | LC_ALL=C sort)
    while IFS= read -r token; do
      [[ -n "$token" ]] || continue
      needle="$(ff_surface_token_needle "$token")"
      if ! ff_surface_names_token "$needle" ${frags[@]+"${frags[@]}"}; then
        SURFACE_JUDGE_UNNAMED="${SURFACE_JUDGE_UNNAMED}${SURFACE_JUDGE_UNNAMED:+ }${token}"
      fi
    done <<< "$SURFACE_JUDGE_REMOVED"
    [[ -z "$SURFACE_JUDGE_UNNAMED" ]]
  }
  surface_base_doc="$TMP/base-public-surface.md"
  if ! git -C "$REPO_ROOT" show "${surface_base_ref}:${SURFACE_DOC_REL}" > "$surface_base_doc" 2>/dev/null; then
    # base に一覧が無い（一覧の初版）。削除は起こり得ないので空集合として扱う。
    surface_base_doc=""
  fi
  surface_rc=0
  surface_breaking_judge "$surface_base_doc" "$REPO_ROOT/$SURFACE_DOC_REL" "$REPO_ROOT/changelog.d" || surface_rc=$?
  surface_removed="$(printf '%s\n' "$SURFACE_JUDGE_REMOVED" | tr '\n' ' ' | sed 's/ *$//')"
  case "$surface_rc" in
    2) bad "公開面の一覧から契約要素を 1 件も抽出できません（見出しか書式を変えた場合は本 suite も更新すること）" ;;
    0)
      if [[ -z "$surface_removed" ]]; then
        ok "契約側の要素は base から減っていない"
      else
        ok "契約側の要素の削除・改名を、どれも breaking 断片が名指している（${surface_removed}）"
      fi
      ;;
    *) bad "契約側の要素が base から消えているのに、それを名指す breaking 断片が changelog.d にありません: ${SURFACE_JUDGE_UNNAMED}" ;;
  esac

  # 変異バッテリー: 判定の本体を合成した一覧と断片へ当てる（live の判定は手元の base と HEAD の
  # 1 組しか通らないので、「無関係な breaking 断片では通さない」「4-3 の鍵の削除も契約の削除」は
  # ここで固定する）。
  # 合成の名前は実行時に組む（`FF_` で始まる綴りを字句で書くと、公開面の母集団へ入る）。
  SB_P=FF
  SB_KEEP="${SB_P}_SB_KEEP" SB_GONE="${SB_P}_SB_GONE"
  SB_FIX="$TMP/surface-battery"
  mkdir -p "$SB_FIX/frag"
  sb_doc() { # $1=出力 $2=4-1 に載せる名前（空白区切り） $3=4-3 に載せる鍵（空白区切り）
    local out="$1" n
    {
      printf '%s\n' '# 公開面' '' '## 公開面 4: 環境変数' '' '### 4-1. 契約' ''
      for n in $2; do printf '%s\n' "- \`${n}\`"; done
      printf '%s\n' '' '### 4-2. 内部' '' '#### 4-2-2. 配布実行物' '' "- \`${SB_P}_SB_INTERNAL\`" '' '### 4-3. L4 宣言の鍵' ''
      printf '%s\n' '| 鍵 | 種別 | 担当する実体 | 包含 | 旧名 |' '| --- | --- | --- | --- | --- |'
      for n in $3; do printf '%s\n' "| \`${n}\` | skip | \`hooks/x.sh\` | - | \`${SB_P}_SB_OLD\` |"; done
      printf '%s\n' '' '## 公開面 5: 環境変数（接頭辞の無いもの）' ''
    } > "$out"
  }
  sb_case() { # $1=期待する rc $2=見出し
    local rc=0
    surface_breaking_judge "$SB_FIX/base.md" "$SB_FIX/head.md" "$SB_FIX/frag" || rc=$?
    if [[ "$rc" -eq "$1" ]]; then ok "$2"; else bad "$2（rc=${rc} 未名指し=${SURFACE_JUDGE_UNNAMED:-なし}）"; fi
  }
  sb_doc "$SB_FIX/base.md" "$SB_KEEP $SB_GONE" "zsh-glob exit-code"
  sb_doc "$SB_FIX/head.md" "$SB_KEEP $SB_GONE" "zsh-glob exit-code"
  sb_case 0 "公開面の判定（変異バッテリー）: 契約が減らなければ断片なしで緑"
  sb_doc "$SB_FIX/head.md" "$SB_KEEP" "zsh-glob exit-code"
  printf '%s\n' "- 別の契約 \`${SB_P}_SB_OTHER\` を外した" > "$SB_FIX/frag/1.breaking.unrelated.md"
  sb_case 1 "公開面の判定（変異バッテリー）: 4-1 から契約トークンを 1 つ消し、無関係な breaking 断片だけを置くと赤"
  printf '%s\n' "- 契約 \`${SB_GONE}_X\` を外した（消えた名前の前方一致は名指しに数えない）" > "$SB_FIX/frag/2.breaking.prefix.md"
  sb_case 1 "公開面の判定（変異バッテリー）: 消えた名前を語の一部として含むだけの断片では赤"
  printf '%s\n' "- 契約 \`${SB_GONE}\` を外した" > "$SB_FIX/frag/3.breaking.named.md"
  sb_case 0 "公開面の判定（変異バッテリー）: 消えた契約トークンを breaking 断片が名指せば緑"
  printf '%s\n' "- 契約 \`${SB_GONE}\` を外した" > "$SB_FIX/frag/3.changed.named.md"
  rm -f "$SB_FIX/frag/3.breaking.named.md"
  sb_case 1 "公開面の判定（変異バッテリー）: 名指しが breaking 以外の断片にしか無ければ赤"
  rm -f "$SB_FIX/frag/"*.md
  sb_doc "$SB_FIX/head.md" "$SB_KEEP $SB_GONE" "zsh-glob"
  sb_case 1 "公開面の判定（変異バッテリー）: 4-3 から鍵を 1 つ消す（skip:exit-code）と、断片なしで赤"
  printf '%s\n' '- 鍵 `zsh-glob` の説明を直した' > "$SB_FIX/frag/4.breaking.unrelated-key.md"
  sb_case 1 "公開面の判定（変異バッテリー）: 4-3 から鍵を消し、別の鍵だけを名指す breaking 断片では赤"
  printf '%s\n' '- 鍵 `exit-code` を外した（`=exit-code` の宣言は効かなくなる）' > "$SB_FIX/frag/5.breaking.key.md"
  sb_case 0 "公開面の判定（変異バッテリー）: 消えた鍵を breaking 断片が名指せば緑"
  rm -f "$SB_FIX/frag/"*.md
  printf '%s\n' '# 公開面' '' '## 公開面 1: Skills' '' > "$SB_FIX/head.md"
  sb_case 2 "公開面の判定（変異バッテリー）: HEAD の一覧から契約要素を 1 件も抽出できなければ検査不成立"
fi
