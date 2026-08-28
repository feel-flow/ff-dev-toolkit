# shellcheck shell=bash
printf '%s\n' '- concurrent source' > "$FRAGMENTS/90.changed.concurrent-source.md"
FAKE_CMP_MUTATE=1 run_contract "$FIX" --write
if [[ "$RC" -eq 2 && "$OUT" == *"比較中に集約入力が変更"* && -f "$FRAGMENTS/90.changed.concurrent-source.md" && "$(tail -1 "$CHANGELOG")" == "external concurrent edit" ]]; then ok "cmp 中の外部変更を上書きせず断片を復元"; else bad "fingerprint 後の外部変更を上書き"; fi
mv "$FIX/before-concurrent-edit.md" "$CHANGELOG"
rm -f "$FRAGMENTS/90.changed.concurrent-source.md"

printf '%s\n' '- pre-mv race source' > "$FRAGMENTS/90.changed.pre-mv-race.md"
cp "$CHANGELOG" "$FIX/before-pre-mv-race.md"
FAKE_MV_ATOMIC_RACE=1 run_contract "$FIX" --write
if [[ "$RC" -eq 2 && "$OUT" == *"退避直前に外部置換を検出"* && -f "$FRAGMENTS/90.changed.pre-mv-race.md" && "$(cat "$CHANGELOG")" == "external pre-mv replacement" ]]; then ok "inode 確認後・退避前の外部 atomic replacement を保持"; else bad "退避前の外部 atomic replacement を消失"; fi
mv "$FIX/before-pre-mv-race.md" "$CHANGELOG"
rm -f "$FIX/oss/ff-dev-toolkit"/.ff-changelog-input.*
rmdir "$FRAGMENTS/.ff-changelog.lock"
rm -f "$FRAGMENTS/90.changed.pre-mv-race.md"

printf '%s\n' '- dangling destination race source' > "$FRAGMENTS/91.changed.dangling-race.md"
FAKE_LN_DANGLING_RACE=1 run_contract "$FIX" --write
dangling_old=("$FIX/oss/ff-dev-toolkit"/.ff-changelog-old.*)
if [[ "$RC" -eq 2 && -L "$CHANGELOG" && -f "${dangling_old[0]}" && -d "$FRAGMENTS/.ff-changelog.lock" ]]; then ok "dangling symlink の install 競合を空き path と誤認しない"; else bad "dangling symlink を rollback で上書き"; fi
rm -f "$CHANGELOG"; mv "${dangling_old[0]}" "$CHANGELOG"; rmdir "$FRAGMENTS/.ff-changelog.lock"; rm -f "$FRAGMENTS/91.changed.dangling-race.md"

printf '%s\n' '- directory destination race source' > "$FRAGMENTS/91.changed.directory-race.md"
FAKE_LINK_DIRECTORY_RACE=1 run_contract "$FIX" --write
directory_old=("$FIX/oss/ff-dev-toolkit"/.ff-changelog-old.*)
if [[ "$RC" -eq 2 && -d "$CHANGELOG" && -z "$(find "$CHANGELOG" -mindepth 1 -maxdepth 1 -print -quit)" && -f "${directory_old[0]}" ]]; then ok "CHANGELOG install は directory destination の内側へ link を作らない"; else bad "CHANGELOG install が directory destination を追跡"; fi
rmdir "$CHANGELOG"; mv "${directory_old[0]}" "$CHANGELOG"; rmdir "$FRAGMENTS/.ff-changelog.lock"; rm -f "$FRAGMENTS/91.changed.directory-race.md"

printf '%s\n' '- install failure source' > "$FRAGMENTS/91.changed.install-failure.md"
FAKE_LN_FAIL_CHANGELOG=1 run_contract "$FIX" --write
if [[ "$RC" -eq 2 && "$OUT" == *"install できません"* && -f "$FRAGMENTS/91.changed.install-failure.md" && -f "$CHANGELOG" ]]; then ok "CHANGELOG install 失敗時は旧本体と断片を復元"; else bad "CHANGELOG install 失敗で入力を喪失"; fi
rm "$FRAGMENTS/91.changed.install-failure.md"

printf '%s\n' '- install signal source' > "$FRAGMENTS/91.changed.install-signal.md"
before_install_signal="$(cksum "$CHANGELOG")"
FAKE_LN_INSTALL_SIGNAL=1 run_contract "$FIX" --write
if [[ "$RC" -eq 130 && "$(cksum "$CHANGELOG")" == "$before_install_signal" && -f "$FRAGMENTS/91.changed.install-signal.md" && ! -e "$FRAGMENTS/.ff-changelog.lock" ]]; then ok "CHANGELOG install 直後の signal でも旧本体と断片を復元"; else bad "install signal で CHANGELOG または断片を復旧できない"; fi
rm -f "$FRAGMENTS/91.changed.install-signal.md"

printf '%s\n' '- old inode race source' > "$FRAGMENTS/91.changed.old-inode-race.md"
FAKE_LN_MUTATE_OLD=1 FAKE_LN_OLD_DIR="$FIX/oss/ff-dev-toolkit" run_contract "$FIX" --write
if [[ "$RC" -eq 2 && "$OUT" == *"旧本体への外部編集"* && -f "$FRAGMENTS/91.changed.old-inode-race.md" && "$(tail -1 "$CHANGELOG")" == "external old inode edit" ]]; then ok "退避後の旧 inode への in-place 編集を検出して復元"; else bad "旧 inode への外部編集を上書き"; fi
rm -f "$FRAGMENTS/91.changed.old-inode-race.md"

printf '%s\n' '- consume signal source' > "$FRAGMENTS/91.changed.consume-signal.md"
before_consume_signal="$(cksum "$CHANGELOG")"
FAKE_MV_CONSUME_SIGNAL=1 run_contract "$FIX" --write
if [[ "$RC" -eq 130 && "$(cksum "$CHANGELOG")" == "$before_consume_signal" && -f "$FRAGMENTS/91.changed.consume-signal.md" && ! -e "$FRAGMENTS/.ff-changelog.lock" ]]; then ok "断片 consume rename 直後の signal でも旧本体と断片を復元"; else bad "consume signal で CHANGELOG または断片を復旧できない"; fi
rm -f "$FRAGMENTS/91.changed.consume-signal.md"

printf '%s\n' '- atomic race source' > "$FRAGMENTS/92.changed.atomic-race.md"
cp "$CHANGELOG" "$FIX/before-atomic-race.md"
FAKE_LN_ATOMIC_RACE=1 run_contract "$FIX" --write
if [[ "$RC" -eq 2 && "$OUT" == *"外部置換を検出"* && -f "$FRAGMENTS/92.changed.atomic-race.md" && "$(cat "$CHANGELOG")" == "external atomic replacement" && -d "$FRAGMENTS/.ff-changelog.lock" ]]; then ok "install 窓の外部 atomic replacement を上書きせず復旧証跡を保持"; else bad "install 窓の外部 atomic replacement を上書き"; fi
rm "$CHANGELOG"
old_backup=("$FIX/oss/ff-dev-toolkit"/.ff-changelog-old.*)
if [[ "${#old_backup[@]}" -eq 1 && -f "${old_backup[0]}" ]]; then mv "${old_backup[0]}" "$CHANGELOG"; else bad "atomic race 後の旧 CHANGELOG backup が一意でない"; fi
rmdir "$FRAGMENTS/.ff-changelog.lock"
rm -f "$FRAGMENTS/92.changed.atomic-race.md" "$FIX/before-atomic-race.md"

printf '%s\n' '- consume race source' > "$FRAGMENTS/93.changed.consume-race.md"
FAKE_MV_CONSUME_RACE=1 FAKE_MV_CHANGELOG="$CHANGELOG" run_contract "$FIX" --write
if [[ "$RC" -eq 2 && "$OUT" == *"断片消費中"* && -f "$FRAGMENTS/93.changed.consume-race.md" && "$(cat "$CHANGELOG")" == "external consume replacement" && -d "$FRAGMENTS/.ff-changelog.lock" ]]; then ok "断片消費窓の外部置換を検出して断片 backup を復元"; else bad "断片消費窓の外部置換で偽成功または断片喪失"; fi
rm "$CHANGELOG"
old_backup=("$FIX/oss/ff-dev-toolkit"/.ff-changelog-old.*)
if [[ "${#old_backup[@]}" -eq 1 && -f "${old_backup[0]}" ]]; then mv "${old_backup[0]}" "$CHANGELOG"; else bad "consume race 後の旧 CHANGELOG backup が一意でない"; fi
rmdir "$FRAGMENTS/.ff-changelog.lock"
rm -f "$FRAGMENTS/93.changed.consume-race.md"

printf '%s\n' '- post-consume race source' > "$FRAGMENTS/93.changed.post-consume-race.md"
FAKE_RM_CHANGELOG_RACE=1 FAKE_RM_CHANGELOG="$CHANGELOG" FAKE_RM_RACE_MARKER="$TMP/rm-race-marker" run_contract "$FIX" --write
if [[ "$RC" -eq 2 && "$OUT" == *"断片削除後"* && -f "$FRAGMENTS/93.changed.post-consume-race.md" && "$(cat "$CHANGELOG")" == "external post-consume replacement" && -d "$FRAGMENTS/.ff-changelog.lock" ]]; then ok "復旧コピー保持中の外部置換を削除後検証で検出"; else bad "断片削除後の外部置換で偽成功または断片喪失"; fi
rm "$CHANGELOG"
old_backup=("$FIX/oss/ff-dev-toolkit"/.ff-changelog-old.*)
if [[ "${#old_backup[@]}" -eq 1 && -f "${old_backup[0]}" ]]; then mv "${old_backup[0]}" "$CHANGELOG"; else bad "post-consume race 後の旧 CHANGELOG backup が一意でない"; fi
rmdir "$FRAGMENTS/.ff-changelog.lock"
rm -f "$FRAGMENTS/93.changed.post-consume-race.md"

printf '%s\n' '- late old inode race source' > "$FRAGMENTS/93.changed.late-old-inode-race.md"
FAKE_RM_MUTATE_OLD=1 FAKE_RM_OLD_DIR="$FIX/oss/ff-dev-toolkit" FAKE_RM_OLD_MARKER="$TMP/rm-old-marker" run_contract "$FIX" --write
if [[ "$RC" -eq 2 && "$OUT" == *"旧 inode"* && -f "$FRAGMENTS/93.changed.late-old-inode-race.md" && "$(tail -1 "$CHANGELOG")" == "external late old inode edit" && ! -e "$FRAGMENTS/.ff-changelog.lock" ]]; then ok "断片削除中の旧 inode 編集も最終検証で検出して復元"; else bad "最終検証前の旧 inode 編集を消失"; fi
rm -f "$FRAGMENTS/93.changed.late-old-inode-race.md"

printf '%s\n' '- final old inode race source' > "$FRAGMENTS/93.changed.final-old-inode-race.md"
FAKE_RM_MUTATE_FINAL_OLD=1 run_contract "$FIX" --write
final_old_snapshots=("$FIX/oss/ff-dev-toolkit"/.ff-changelog-input.*)
if [[ "$RC" -eq 2 && "$OUT" == *"旧本体削除中の外部編集"* && -f "${final_old_snapshots[0]}" ]] && grep -Fqx 'external final old inode edit' "${final_old_snapshots[0]}"; then ok "確定直前の旧 inode 遅延書き込みを snapshot に保全"; else bad "確定直前の旧 inode 遅延書き込みを消失"; fi
rm -f "${final_old_snapshots[@]}"
[[ ! -d "$FRAGMENTS/.ff-changelog.lock" ]] || /bin/rmdir "$FRAGMENTS/.ff-changelog.lock"
rm -f "$FRAGMENTS/93.changed.final-old-inode-race.md"

printf '%s\n' '- final replacement recovery source' > "$FRAGMENTS/93.changed.final-replacement.md"
FAKE_RM_REPLACE_FINAL_CURRENT=1 FAKE_RM_FINAL_MARKER="$TMP/final-replace-marker" FAKE_RM_FINAL_CHANGELOG="$CHANGELOG" run_contract "$FIX" --write
final_generated=("$FIX/oss/ff-dev-toolkit"/.ff-changelog.[A-Za-z0-9]*)
if [[ "$RC" -eq 2 && "$OUT" == *"retained 断片削除中"* && "$(cat "$CHANGELOG")" == "external final replacement" && -f "${final_generated[0]}" ]] && grep -Fq -- '- final replacement recovery source' "${final_generated[0]}"; then ok "最終確定中の外部置換でも集約済み CHANGELOG を保持"; else bad "最終確定中の外部置換で断片と集約結果を喪失"; fi
rm -f "$CHANGELOG"
mv "${final_generated[0]}" "$CHANGELOG"
[[ ! -d "$FRAGMENTS/.ff-changelog.lock" ]] || /bin/rmdir "$FRAGMENTS/.ff-changelog.lock"
rm -f "$FRAGMENTS/93.changed.final-replacement.md"

printf '%s\n' '- committed cleanup signal source' > "$FRAGMENTS/93.changed.committed-signal.md"
FAKE_RM_SIGNAL_RETAINED=1 FAKE_RM_SIGNAL_MARKER="$TMP/retained-signal-marker" run_contract "$FIX" --write
if [[ "$RC" -eq 130 && "$(grep -Fc -- '- committed cleanup signal source' "$CHANGELOG")" -eq 1 && ! -e "$FRAGMENTS/93.changed.committed-signal.md" && ! -e "$FRAGMENTS/.ff-changelog.lock" ]]; then ok "確定後 retained cleanup 中の signal は新 CHANGELOG を維持して収束"; else bad "確定後 signal で更新内容・断片・lock が不整合"; printf '%s\n' "$OUT" | sed 's/^/    | /' >&2; fi

printf '%s\n' '- partial delete one' > "$FRAGMENTS/94.changed.partial-delete-a.md"
printf '%s\n' '- partial delete two' > "$FRAGMENTS/95.changed.partial-delete-b.md"
before_partial_delete="$(cksum "$CHANGELOG")"
FAKE_RM_FAIL_ON_CONSUMED=2 FAKE_RM_COUNT_FILE="$TMP/rm-count" run_contract "$FIX" --write
if [[ "$RC" -eq 2 && "$OUT" == *"consumed delete failure"* && "$(cksum "$CHANGELOG")" == "$before_partial_delete" && -f "$FRAGMENTS/94.changed.partial-delete-a.md" && -f "$FRAGMENTS/95.changed.partial-delete-b.md" ]]; then ok "確定前の consumed 部分削除失敗は旧 CHANGELOG と全断片を復元"; else bad "consumed 部分削除失敗で CHANGELOG 項目と断片を同時喪失"; fi
run_contract "$FIX" --write
if [[ "$RC" -eq 0 && "$OUT" == *"MATERIALIZED=2"* && ! -e "$FRAGMENTS/94.changed.partial-delete-a.md" && ! -e "$FRAGMENTS/95.changed.partial-delete-b.md" ]]; then ok "consumed 部分削除失敗後の再実行が収束"; else bad "consumed 部分削除失敗後に収束しない"; fi

printf '%s\n' '- recovery delete one' > "$FRAGMENTS/97.changed.recovery-delete-a.md"
printf '%s\n' '- recovery delete two' > "$FRAGMENTS/98.changed.recovery-delete-b.md"
before_recovery_delete="$(cksum "$CHANGELOG")"
FAKE_RM_FAIL_ON_RECOVERY=2 FAKE_RM_RECOVERY_COUNT_FILE="$TMP/recovery-rm-count" run_contract "$FIX" --write
if [[ "$RC" -eq 2 && "$OUT" == *"recovery delete failure"* && "$(cksum "$CHANGELOG")" == "$before_recovery_delete" && -f "$FRAGMENTS/97.changed.recovery-delete-a.md" && -f "$FRAGMENTS/98.changed.recovery-delete-b.md" ]]; then ok "確定前の recovery 部分削除失敗は旧 CHANGELOG と全断片を復元"; else bad "recovery 部分削除失敗で CHANGELOG 項目と断片を同時喪失"; fi
run_contract "$FIX" --write
if [[ "$RC" -eq 0 && "$OUT" == *"MATERIALIZED=2"* && ! -e "$FRAGMENTS/97.changed.recovery-delete-a.md" && ! -e "$FRAGMENTS/98.changed.recovery-delete-b.md" ]]; then ok "recovery 部分削除失敗後の再実行が重複なしで収束"; else bad "recovery 部分削除失敗後に収束しない"; fi

printf '%s\n' '- recovery race changed content' > "$FRAGMENTS/99.changed.recovery-race.md"
before_recovery_race="$(cksum "$CHANGELOG")"
FAKE_RM_RECOVERY_RACE=1 FAKE_RM_RECOVERY_RACE_MARKER="$TMP/recovery-race-marker" FAKE_RM_RECOVERY_CHANGELOG="$CHANGELOG" run_contract "$FIX" --write
if [[ "$RC" -eq 2 && "$OUT" == *"recovery 削除中"* && "$(cat "$CHANGELOG")" == "external recovery replacement" && -f "$FRAGMENTS/99.changed.recovery-race.md" ]]; then ok "recovery 削除中の atomic replacement を検出して断片を復元"; else bad "recovery 削除中の atomic replacement で断片を喪失"; fi
rm "$CHANGELOG"
old_backup=("$FIX/oss/ff-dev-toolkit"/.ff-changelog-old.*)
if [[ "${#old_backup[@]}" -eq 1 && -f "${old_backup[0]}" ]]; then mv "${old_backup[0]}" "$CHANGELOG"; else bad "recovery race 後の旧 CHANGELOG backup が一意でない"; fi
rmdir "$FRAGMENTS/.ff-changelog.lock"
rm -f "$FRAGMENTS/99.changed.recovery-race.md"

printf '%s\n' '- recovery delete one' > "$FRAGMENTS/100.changed.recovery-race-same.md"
rm -f "$TMP/recovery-race-marker"
FAKE_RM_RECOVERY_RACE=1 FAKE_RM_RECOVERY_RACE_MARKER="$TMP/recovery-race-marker" FAKE_RM_RECOVERY_CHANGELOG="$CHANGELOG" run_contract "$FIX" --write
if [[ "$RC" -eq 2 && "$OUT" == *"recovery 削除中"* && "$(cat "$CHANGELOG")" == "external recovery replacement" && -f "$FRAGMENTS/100.changed.recovery-race-same.md" ]]; then ok "cmp=0 の recovery 削除中 race でも断片を復元"; else bad "cmp=0 の recovery 削除中 race で断片を喪失"; fi
rm "$CHANGELOG"
input_backup=("$FIX/oss/ff-dev-toolkit"/.ff-changelog-input.*)
if [[ "${#input_backup[@]}" -eq 1 && -f "${input_backup[0]}" ]]; then mv "${input_backup[0]}" "$CHANGELOG"; else bad "cmp=0 recovery race 後の入力 snapshot が一意でない"; fi
rmdir "$FRAGMENTS/.ff-changelog.lock"
rm -f "$FRAGMENTS/100.changed.recovery-race-same.md"

printf '%s\n' '- consumed rmdir failure' > "$FRAGMENTS/96.changed.consumed-rmdir.md"
FAKE_RMDIR_FAIL_CONSUMED=1 run_contract "$FIX" --write
if [[ "$RC" -eq 2 && "$OUT" == *"consumed directory busy"* && "$(grep -Fc -- '- consumed rmdir failure' "$CHANGELOG")" -eq 1 && ! -e "$FRAGMENTS/96.changed.consumed-rmdir.md" && -d "$FRAGMENTS/.ff-changelog.lock/.consumed" ]]; then ok "確定後の consumed rmdir 失敗でも新 CHANGELOG を維持"; else bad "consumed rmdir 失敗で確定内容をロールバック"; fi
/bin/rmdir "$FRAGMENTS/.ff-changelog.lock/.consumed"
/bin/rmdir "$FRAGMENTS/.ff-changelog.lock"
