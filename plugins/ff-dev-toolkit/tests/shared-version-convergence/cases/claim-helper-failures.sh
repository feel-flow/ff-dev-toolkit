# shellcheck shell=bash
echo "== claim helper failure atomicity =="
CLAIM_FAILURE="$TMP/claim-failure"
CLAIM_FAKE_BIN="$TMP/claim-fake-bin"
CLAIM_REAL_MV="$(command -v mv)"
CLAIM_REAL_LN="$(command -v ln)"
CLAIM_REAL_RM="$(command -v rm)"
CLAIM_REAL_MKTEMP="$(command -v mktemp)"
mkdir -p "$CLAIM_FAILURE/docs" "$CLAIM_FAILURE/.version-claims" "$CLAIM_FAKE_BIN"
cp "$SCRIPT_DIR/fixtures/bin/mv" "$SCRIPT_DIR/fixtures/bin/ln" "$SCRIPT_DIR/fixtures/bin/perl" "$SCRIPT_DIR/fixtures/bin/rm" "$SCRIPT_DIR/fixtures/bin/mktemp" "$CLAIM_FAKE_BIN/"
chmod +x "$CLAIM_FAKE_BIN/mv" "$CLAIM_FAKE_BIN/ln" "$CLAIM_FAKE_BIN/perl" "$CLAIM_FAKE_BIN/rm" "$CLAIM_FAKE_BIN/mktemp"
ff_git_fixture_init "$CLAIM_FAILURE" "claims-test" "claims@example.com"
printf '%s\n' '---' 'version: "1.0.0"' '---' '# Claim failure' > "$CLAIM_FAILURE/docs/TEST.md"
printf '%s\n' '# claims' > "$CLAIM_FAILURE/.version-claims/README.md"
git -C "$CLAIM_FAILURE" add -A && git -C "$CLAIM_FAILURE" commit -qm baseline
printf '%s\n' '' 'first change' >> "$CLAIM_FAILURE/docs/TEST.md"
(cd "$CLAIM_FAILURE" && "$CLAIM_HELPER" --base HEAD --document docs/TEST.md) >/dev/null
claim_before_failure="$(cksum "$CLAIM_FAILURE/.version-claims/docs/TEST.md.claim")"
claim_before_digest="$(cksum < "$CLAIM_FAILURE/.version-claims/docs/TEST.md.claim")"
signal_claim="$CLAIM_FAILURE/.version-claims/docs/TEST.md.claim"
printf '%s\n' 'second change' >> "$CLAIM_FAILURE/docs/TEST.md"
if claim_snapshot_dir_out="$(cd "$CLAIM_FAILURE" && PATH="$CLAIM_FAKE_BIN:$PATH" FAKE_CLAIM_SNAPSHOT_DIRECTORY_RACE=1 "$CLAIM_HELPER" --base HEAD --document docs/TEST.md 2>&1)"; then claim_snapshot_dir_rc=0; else claim_snapshot_dir_rc=$?; fi
claim_snapshot_dirs=("$CLAIM_FAILURE/.version-claims"/.version-claim-snapshot.*)
if [[ "$claim_snapshot_dir_rc" -eq 2 && -d "${claim_snapshot_dirs[0]}" && -z "$(find "${claim_snapshot_dirs[0]}" -mindepth 1 -maxdepth 1 -print -quit)" && "$(cksum "$signal_claim")" == "$claim_before_failure" ]]; then ok "claim snapshot は directory 宛先競合の内部へ link しない"; else bad "claim snapshot が directory 宛先を追跡"; printf '%s\n' "$claim_snapshot_dir_out" | sed 's/^/    | /' >&2; fi
rmdir "${claim_snapshot_dirs[0]}"
if claim_mv_out="$(cd "$CLAIM_FAILURE" && PATH="$CLAIM_FAKE_BIN:$PATH" FAKE_CLAIM_MV_FAIL=1 FAKE_CLAIM_REAL_MV="$CLAIM_REAL_MV" "$CLAIM_HELPER" --base HEAD --document docs/TEST.md 2>&1)"; then claim_mv_rc=0; else claim_mv_rc=$?; fi
if [[ "$claim_mv_rc" -eq 2 && "$(cksum "$CLAIM_FAILURE/.version-claims/docs/TEST.md.claim")" == "$claim_before_failure" && "$claim_mv_out" == *"退避できません"* ]]; then ok "claim 保存失敗は既存 claim を byte 不変で保全"; else bad "claim 保存失敗で既存 claim を破損"; printf '%s\n' "$claim_mv_out" | sed 's/^/    | /' >&2; fi
printf '%s\n' 'install failure change' >> "$CLAIM_FAILURE/docs/TEST.md"
if claim_ln_fail_out="$(cd "$CLAIM_FAILURE" && PATH="$CLAIM_FAKE_BIN:$PATH" FAKE_CLAIM_LN_FAIL_INSTALL=1 FAKE_CLAIM_REAL_LN="$CLAIM_REAL_LN" "$CLAIM_HELPER" --base HEAD --document docs/TEST.md 2>&1)"; then claim_ln_fail_rc=0; else claim_ln_fail_rc=$?; fi
if [[ "$claim_ln_fail_rc" -eq 2 && "$(cksum "$signal_claim")" == "$claim_before_failure" && "$claim_ln_fail_out" == *"上書き禁止で保存できません"* ]]; then ok "claim install 失敗は旧 claim を byte 不変で復元"; else bad "claim install 失敗で旧 claim を喪失"; fi
printf '%s\n' 'concurrent claim change' >> "$CLAIM_FAILURE/docs/TEST.md"
if claim_create_out="$(cd "$CLAIM_FAILURE" && PATH="$CLAIM_FAKE_BIN:$PATH" FAKE_CLAIM_LN_CREATE_EXTERNAL=1 FAKE_CLAIM_REAL_LN="$CLAIM_REAL_LN" "$CLAIM_HELPER" --base HEAD --document docs/TEST.md 2>&1)"; then claim_create_rc=0; else claim_create_rc=$?; fi
claim_old_backups=("$CLAIM_FAILURE/.version-claims"/.version-claim-old.*)
if [[ "$claim_create_rc" -eq 2 && "$(cat "$signal_claim")" == "external=concurrent-claim" && -f "${claim_old_backups[0]}" ]] && [[ "$(cksum < "${claim_old_backups[0]}")" == "$claim_before_digest" ]]; then ok "claim install 直前の同時作成は外部 claim と旧 claim を保全"; else bad "claim 同時作成で外部または旧 claim を喪失"; printf '    | rc=%s current=%s old=%s expected=%s\n' "$claim_create_rc" "$(cat "$signal_claim" 2>/dev/null || true)" "$(cksum < "${claim_old_backups[0]}" 2>/dev/null || true)" "$claim_before_digest" >&2; printf '%s\n' "$claim_create_out" | sed 's/^/    | /' >&2; fi
rm -f "$signal_claim" "${claim_old_backups[@]}" "$CLAIM_FAILURE/.version-claims"/.version-claim-snapshot.*
if (cd "$CLAIM_FAILURE" && "$CLAIM_HELPER" --base HEAD --document docs/TEST.md) >/dev/null; then ok "claim install 競合後の再実行は正確な3行へ収束"; else bad "claim install 競合後に再実行しても収束しない"; fi
printf '%s\n' 'dangling claim race change' >> "$CLAIM_FAILURE/docs/TEST.md"
if claim_dangling_out="$(cd "$CLAIM_FAILURE" && PATH="$CLAIM_FAKE_BIN:$PATH" FAKE_CLAIM_LN_CREATE_DANGLING=1 FAKE_CLAIM_REAL_LN="$CLAIM_REAL_LN" "$CLAIM_HELPER" --base HEAD --document docs/TEST.md 2>&1)"; then claim_dangling_rc=0; else claim_dangling_rc=$?; fi
dangling_old=("$CLAIM_FAILURE/.version-claims"/.version-claim-old.*)
if [[ "$claim_dangling_rc" -eq 2 && -L "$signal_claim" && -f "${dangling_old[0]}" ]]; then ok "dangling symlink の同時作成を空き path と誤認しない"; else bad "dangling symlink を rollback で上書き"; fi
rm -f "$signal_claim" "${dangling_old[@]}" "$CLAIM_FAILURE/.version-claims"/.version-claim-snapshot.*
(cd "$CLAIM_FAILURE" && "$CLAIM_HELPER" --base HEAD --document docs/TEST.md) >/dev/null
printf '%s\n' 'directory claim race change' >> "$CLAIM_FAILURE/docs/TEST.md"
if claim_directory_out="$(cd "$CLAIM_FAILURE" && PATH="$CLAIM_FAKE_BIN:$PATH" FAKE_CLAIM_LINK_DIRECTORY_RACE=1 "$CLAIM_HELPER" --base HEAD --document docs/TEST.md 2>&1)"; then claim_directory_rc=0; else claim_directory_rc=$?; fi
directory_claim_old=("$CLAIM_FAILURE/.version-claims"/.version-claim-old.*)
if [[ "$claim_directory_rc" -eq 2 && -d "$signal_claim" && -z "$(find "$signal_claim" -mindepth 1 -maxdepth 1 -print -quit)" && -f "${directory_claim_old[0]}" ]]; then ok "claim install は directory destination の内側へ link を作らない"; else bad "claim install が directory destination を追跡"; printf '%s\n' "$claim_directory_out" | sed 's/^/    | /' >&2; fi
rmdir "$signal_claim"; mv "${directory_claim_old[0]}" "$signal_claim"; rm -f "$CLAIM_FAILURE/.version-claims"/.version-claim-snapshot.* "$CLAIM_FAILURE/.version-claims"/.version-claim.*
printf '%s\n' 'finalize race change' >> "$CLAIM_FAILURE/docs/TEST.md"
if claim_finalize_out="$(cd "$CLAIM_FAILURE" && PATH="$CLAIM_FAKE_BIN:$PATH" FAKE_CLAIM_RM_REPLACE_CURRENT=1 FAKE_CLAIM_CURRENT="$signal_claim" FAKE_CLAIM_REAL_RM="$CLAIM_REAL_RM" "$CLAIM_HELPER" --base HEAD --document docs/TEST.md 2>&1)"; then claim_finalize_rc=0; else claim_finalize_rc=$?; fi
finalize_generated=("$CLAIM_FAILURE/.version-claims"/.version-claim.*)
if [[ "$claim_finalize_rc" -eq 2 && "$(cat "$signal_claim")" == "external=finalize-race" && -f "${finalize_generated[0]}" ]] && grep -Fqx 'document=docs/TEST.md' "${finalize_generated[0]}"; then ok "claim 最終検証後の外部置換でも生成済み claim を保持"; else bad "claim cleanup race を成功扱いまたは生成結果を喪失"; printf '    | rc=%s current=%s generated=%s\n' "$claim_finalize_rc" "$(cat "$signal_claim" 2>/dev/null || true)" "${finalize_generated[0]}" >&2; printf '%s\n' "$claim_finalize_out" | sed 's/^/    | /' >&2; fi
rm -f "$signal_claim" "${finalize_generated[@]}" "$CLAIM_FAILURE/.version-claims"/.version-claim-snapshot.* "$CLAIM_FAILURE/.version-claims"/.version-claim-old.*
(cd "$CLAIM_FAILURE" && "$CLAIM_HELPER" --base HEAD --document docs/TEST.md) >/dev/null
printf '%s\n' 'cleanup document race change' >> "$CLAIM_FAILURE/docs/TEST.md"
if claim_cleanup_doc_out="$(cd "$CLAIM_FAILURE" && PATH="$CLAIM_FAKE_BIN:$PATH" FAKE_CLAIM_RM_MUTATE_DOC=1 FAKE_CLAIM_CURRENT="$signal_claim" FAKE_CLAIM_DOCUMENT="$CLAIM_FAILURE/docs/TEST.md" FAKE_CLAIM_REAL_RM="$CLAIM_REAL_RM" "$CLAIM_HELPER" --base HEAD --document docs/TEST.md 2>&1)"; then claim_cleanup_doc_rc=0; else claim_cleanup_doc_rc=$?; fi
if [[ "$claim_cleanup_doc_rc" -eq 2 && "$claim_cleanup_doc_out" == *"旧 claim 削除中の外部変更"* && "$(tail -1 "$CLAIM_FAILURE/docs/TEST.md")" == "external cleanup document change" ]]; then ok "claim cleanup 中の document TOCTOU を拒否"; else bad "claim cleanup 中の stale document を成功扱い"; printf '%s\n' "$claim_cleanup_doc_out" | sed 's/^/    | /' >&2; fi
"$CLAIM_REAL_RM" -f "$CLAIM_FAILURE/.version-claims"/.version-claim.*
(cd "$CLAIM_FAILURE" && "$CLAIM_HELPER" --base HEAD --document docs/TEST.md) >/dev/null
printf '%s\n' 'third change' >> "$CLAIM_FAILURE/docs/TEST.md"
if claim_signal_out="$(cd "$CLAIM_FAILURE" && PATH="$CLAIM_FAKE_BIN:$PATH" FAKE_CLAIM_MV_SIGNAL=1 FAKE_CLAIM_SIGNAL_MARKER="$TMP/claim-signal-marker" FAKE_CLAIM_REAL_MV="$CLAIM_REAL_MV" "$CLAIM_HELPER" --base HEAD --document docs/TEST.md 2>&1)"; then claim_signal_rc=0; else claim_signal_rc=$?; fi
claim_temps=("$CLAIM_FAILURE/.version-claims"/.version-claim.*)
signal_claim="$CLAIM_FAILURE/.version-claims/docs/TEST.md.claim"
if [[ "$claim_signal_rc" -eq 130 && ! -e "${claim_temps[0]}" && "$claim_signal_out" == *"signal"* && "$(wc -l < "$signal_claim" | tr -d ' ')" -eq 3 ]] && grep -Fqx 'document=docs/TEST.md' "$signal_claim" && grep -Eq '^version=[0-9]+\.[0-9]+\.[0-9]+$' "$signal_claim" && grep -Eq '^change=[0-9a-f]{40,64}$' "$signal_claim"; then ok "claim rename 直後の signal は完全な3行だけを残して中断"; else bad "claim signal 中断で temp または不完全 claim を残す"; printf '    | rc=%s temp=%s claim=%s\n' "$claim_signal_rc" "${claim_temps[0]}" "$(cat "$signal_claim" 2>/dev/null || true)" >&2; printf '%s\n' "$claim_signal_out" | sed 's/^/    | /' >&2; fi
if (cd "$CLAIM_FAILURE" && "$CLAIM_HELPER" --base HEAD --document docs/TEST.md) >/dev/null && [[ "$(wc -l < "$signal_claim" | tr -d ' ')" -eq 3 ]]; then ok "claim signal 中断後の再実行は正確な3行へ冪等収束"; else bad "claim signal 中断後に再実行しても収束しない"; fi
printf '%s\n' 'post-install signal change' >> "$CLAIM_FAILURE/docs/TEST.md"
if post_install_signal_out="$(cd "$CLAIM_FAILURE" && PATH="$CLAIM_FAKE_BIN:$PATH" FAKE_CLAIM_LN_SIGNAL_AFTER_INSTALL=1 FAKE_CLAIM_REAL_LN="$CLAIM_REAL_LN" "$CLAIM_HELPER" --base HEAD --document docs/TEST.md 2>&1)"; then post_install_signal_rc=0; else post_install_signal_rc=$?; fi
post_install_old=("$CLAIM_FAILURE/.version-claims"/.version-claim-old.*)
post_install_incomplete=0
for post_install_candidate in "$signal_claim" "${post_install_old[@]}"; do
  [[ -e "$post_install_candidate" || -L "$post_install_candidate" ]] || continue
  if [[ ! -f "$post_install_candidate" || -L "$post_install_candidate" || "$(wc -l < "$post_install_candidate" | tr -d ' ')" -ne 3 ]] ||
     ! grep -Fqx 'document=docs/TEST.md' "$post_install_candidate" ||
     ! grep -Eq '^version=[0-9]+\.[0-9]+\.[0-9]+$' "$post_install_candidate" ||
     ! grep -Eq '^change=[0-9a-f]{40,64}$' "$post_install_candidate"; then post_install_incomplete=1; fi
done
if [[ "$post_install_signal_rc" -eq 2 && "$post_install_incomplete" -eq 0 && "$post_install_signal_out" == *"signal"* ]]; then ok "claim hard-link install 直後の signal は中断を診断し不完全な claim を残さない"; else bad "claim install 後 signal で不完全な sentinel を残す"; for post_install_candidate in "$signal_claim" "${post_install_old[@]}"; do printf '    | candidate=%s\n' "$post_install_candidate" >&2; sed 's/^/    |   /' "$post_install_candidate" 2>/dev/null >&2 || true; done; printf '%s\n' "$post_install_signal_out" | sed 's/^/    | /' >&2; fi
if (cd "$CLAIM_FAILURE" && "$CLAIM_HELPER" --base HEAD --document docs/TEST.md) >/dev/null; then ok "claim install 後 signal から再実行で冪等収束"; else bad "claim install 後 signal から再実行できない"; fi
printf '%s\n' 'fourth change' >> "$CLAIM_FAILURE/docs/TEST.md"
if claim_verify_out="$(cd "$CLAIM_FAILURE" && PATH="$CLAIM_FAKE_BIN:$PATH" FAKE_CLAIM_LN_APPEND_BLANK=1 FAKE_CLAIM_REAL_LN="$CLAIM_REAL_LN" "$CLAIM_HELPER" --base HEAD --document docs/TEST.md 2>&1)"; then claim_verify_rc=0; else claim_verify_rc=$?; fi
if [[ "$claim_verify_rc" -eq 2 && "$claim_verify_out" == *"最終検証に失敗"* ]]; then ok "claim 末尾の余分な空行も3行完全一致で拒否"; else bad "claim の末尾空行を完全一致検証が見逃す"; fi
if (cd "$CLAIM_FAILURE" && "$CLAIM_HELPER" --base HEAD --document docs/TEST.md) >/dev/null; then ok "claim 末尾改変の検出後に正確な3行へ収束"; else bad "claim 末尾改変後に再実行しても収束しない"; fi
printf '%s\n' 'document race change' >> "$CLAIM_FAILURE/docs/TEST.md"
if claim_doc_race_out="$(cd "$CLAIM_FAILURE" && PATH="$CLAIM_FAKE_BIN:$PATH" FAKE_CLAIM_LN_MUTATE_DOC=1 FAKE_CLAIM_DOCUMENT="$CLAIM_FAILURE/docs/TEST.md" FAKE_CLAIM_REAL_LN="$CLAIM_REAL_LN" "$CLAIM_HELPER" --base HEAD --document docs/TEST.md 2>&1)"; then claim_doc_race_rc=0; else claim_doc_race_rc=$?; fi
if [[ "$claim_doc_race_rc" -eq 2 && "$claim_doc_race_out" == *"document が変更"* ]]; then ok "claim 保存中の document TOCTOU を拒否"; else bad "claim が stale document blob を成功扱い"; fi
if (cd "$CLAIM_FAILURE" && "$CLAIM_HELPER" --base HEAD --document docs/TEST.md) >/dev/null; then ok "document TOCTOU 検出後に最新 blob の claim へ収束"; else bad "document TOCTOU 後に再実行しても収束しない"; fi
printf '%s\n' 'claim replacement race change' >> "$CLAIM_FAILURE/docs/TEST.md"
if claim_replace_out="$(cd "$CLAIM_FAILURE" && PATH="$CLAIM_FAKE_BIN:$PATH" FAKE_CLAIM_MV_REPLACE_SOURCE=1 FAKE_CLAIM_REAL_MV="$CLAIM_REAL_MV" FAKE_CLAIM_REAL_LN="$CLAIM_REAL_LN" "$CLAIM_HELPER" --base HEAD --document docs/TEST.md 2>&1)"; then claim_replace_rc=0; else claim_replace_rc=$?; fi
if [[ "$claim_replace_rc" -eq 2 && "$claim_replace_out" == *"外部置換"* && "$(cat "$signal_claim")" == "external=claim-replacement" ]]; then ok "退避直前の外部 claim を上書きせず停止"; else bad "外部 claim replacement をサイレント上書き"; fi
printf '%s\n' 'fifth change' >> "$CLAIM_FAILURE/docs/TEST.md"
if claim_cleanup_out="$(cd "$CLAIM_FAILURE" && PATH="$CLAIM_FAKE_BIN:$PATH" FAKE_CLAIM_MV_SIGNAL_BEFORE=1 FAKE_CLAIM_SIGNAL_MARKER="$TMP/claim-cleanup-signal-marker" FAKE_CLAIM_REAL_MV="$CLAIM_REAL_MV" FAKE_CLAIM_RM_FAIL=1 FAKE_CLAIM_REAL_RM="$CLAIM_REAL_RM" "$CLAIM_HELPER" --base HEAD --document docs/TEST.md 2>&1)"; then claim_cleanup_rc=0; else claim_cleanup_rc=$?; fi
failed_cleanup_temps=("$CLAIM_FAILURE/.version-claims"/.version-claim.*)
if [[ "$claim_cleanup_rc" -eq 2 && "$claim_cleanup_out" == *"一時ファイルを削除できません"* && -f "${failed_cleanup_temps[0]}" ]]; then ok "claim signal 復旧失敗は temp path を診断して検査不能"; else bad "claim temp 削除失敗を無診断または signal 成功扱い"; fi
"$CLAIM_REAL_RM" -f "${failed_cleanup_temps[@]}"

PARENT_RACE="$TMP/claim-parent-race"
PARENT_EXTERNAL="$TMP/claim-parent-external"
mkdir -p "$PARENT_RACE/docs" "$PARENT_RACE/.version-claims" "$PARENT_EXTERNAL"
ff_git_fixture_init "$PARENT_RACE" "claims-test" "claims@example.com"
printf '%s\n' '---' 'version: "1.0.0"' '---' '# Parent race' > "$PARENT_RACE/docs/RACE.md"
printf '%s\n' '# claims' > "$PARENT_RACE/.version-claims/README.md"
git -C "$PARENT_RACE" add -A && git -C "$PARENT_RACE" commit -qm baseline
sed -i.bak 's/1.0.0/1.1.0/' "$PARENT_RACE/docs/RACE.md" && rm "$PARENT_RACE/docs/RACE.md.bak"
if parent_race_out="$(cd "$PARENT_RACE" && PATH="$CLAIM_FAKE_BIN:$PATH" FAKE_CLAIM_SWAP_PARENT=1 FAKE_CLAIM_PARENT="$PARENT_RACE/.version-claims/docs" FAKE_CLAIM_EXTERNAL_PARENT="$PARENT_EXTERNAL" FAKE_CLAIM_REAL_MKTEMP="$CLAIM_REAL_MKTEMP" FAKE_CLAIM_RM_FAIL=1 FAKE_CLAIM_REAL_RM="$CLAIM_REAL_RM" "$CLAIM_HELPER" --base HEAD --document docs/RACE.md 2>&1)"; then parent_race_rc=0; else parent_race_rc=$?; fi
if [[ "$parent_race_rc" -eq 2 && "$parent_race_out" == *"親階層が変更"* && ! -e "$PARENT_EXTERNAL/RACE.md.claim" ]]; then ok "claim 親階層の symlink TOCTOU を repository 外へ書かず拒否"; else bad "claim 親 symlink race で repository 外へ書き込み"; fi
if [[ "$parent_race_out" == *"初期化中の claim 一時ファイルを削除できません"* ]]; then ok "初期 cleanup 失敗は temp path と原因を診断"; else bad "初期 cleanup 失敗を無診断で終了"; fi
"$CLAIM_REAL_RM" -f "$PARENT_RACE/.version-claims"/.version-claim.*
rm -f "$PARENT_RACE/.version-claims/docs"
mkdir -p "$PARENT_RACE/.version-claims/docs"
if install_parent_out="$(cd "$PARENT_RACE" && PATH="$CLAIM_FAKE_BIN:$PATH" FAKE_CLAIM_LN_SWAP_PARENT=1 FAKE_CLAIM_PARENT="$PARENT_RACE/.version-claims/docs" FAKE_CLAIM_EXTERNAL_PARENT="$PARENT_EXTERNAL" FAKE_CLAIM_REAL_LN="$CLAIM_REAL_LN" "$CLAIM_HELPER" --base HEAD --document docs/RACE.md 2>&1)"; then install_parent_rc=0; else install_parent_rc=$?; fi
if [[ "$install_parent_rc" -eq 2 && ! -e "$PARENT_EXTERNAL/RACE.md.claim" ]]; then ok "claim install 直前の親 symlink 置換でも repository 外へ書かない"; else bad "claim install 窓の親 symlink race で repository 外へ書き込み"; printf '%s\n' "$install_parent_out" | sed 's/^/    | /' >&2; fi
