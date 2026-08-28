#!/usr/bin/env bash
# shellcheck shell=bash

printf '%s\n' '- signal source' > "$FRAGMENTS/8.changed.signal-source.md"
FAKE_SORT_SIGNAL=1 run_contract "$FIX" --write
if [[ "$RC" -eq 130 && -f "$FRAGMENTS/8.changed.signal-source.md" && ! -e "$FRAGMENTS/.ff-changelog.lock" ]]; then ok "signal 中断時も断片を復元して lock を解放"; else bad "signal 中断で断片または lock の復旧に失敗"; fi
rm -f "$FRAGMENTS/8.changed.signal-source.md"
printf '%s\n' '- validated snapshot source' > "$FRAGMENTS/9.changed.snapshot-source.md"
FAKE_GH_MUTATE_FRAGMENT="$FRAGMENTS/.ff-changelog.lock/9.changed.snapshot-source.md" run_contract "$FIX" --write
if [[ "$RC" -eq 2 && "$OUT" == *"未検証内容を集約せず停止"* && -f "$FRAGMENTS/9.changed.snapshot-source.md" ]] && ! grep -Fq 'external mutation' "$CHANGELOG"; then ok "検証後に staging 断片が変わっても未検証内容を集約しない"; else bad "検証後に変更された staging 内容を CHANGELOG へ混入"; fi
rm -f "$FRAGMENTS/9.changed.snapshot-source.md"
FAKE_MV_FAIL_SECOND_STAGE=1 FAKE_MV_STAGE_COUNT_FILE="$TMP/stage-count" run_contract "$FIX" --write
if [[ "$RC" -eq 2 && "$OUT" == *"second staging move failure"* && ! -e "$FRAGMENTS/.ff-changelog.lock" && -f "$FRAGMENTS/10.added.feature-a.md" && -f "$FRAGMENTS/60.security.feature-f.md" ]]; then ok "2件目の staging mv 失敗後に全断片を復元"; else bad "staging 途中失敗で断片または lock を残す"; fi
FAKE_CP_FAIL_SECOND_SNAPSHOT=1 FAKE_CP_COUNT_FILE="$TMP/cp-count" run_contract "$FIX" --write
if [[ "$RC" -eq 2 && "$OUT" == *"second snapshot copy failure"* && ! -e "$FRAGMENTS/.ff-changelog.lock" && -f "$FRAGMENTS/10.added.feature-a.md" && -f "$FRAGMENTS/60.security.feature-f.md" ]]; then ok "2件目の snapshot cp 失敗後に全断片を復元"; else bad "snapshot 途中失敗で断片または lock を残す"; fi
SNAPSHOT_RACE_FIX="$TMP/snapshot-symlink-race"
make_fixture "$SNAPSHOT_RACE_FIX"
printf '%s\n' '- snapshot regular source' > "$SNAPSHOT_RACE_FIX/changelog.d/12.changed.snapshot-race.md"
printf '%s\n' '- external snapshot content' > "$SNAPSHOT_RACE_FIX/external-snapshot-target.md"
FAKE_CP_SWAP_STAGED_SYMLINK=1 FAKE_CP_SWAP_TARGET="$SNAPSHOT_RACE_FIX/external-snapshot-target.md" run_contract "$SNAPSHOT_RACE_FIX" --write
if [[ "$RC" -eq 2 && "$OUT" == *"snapshot 作成中に staging 断片の file type が変化"* ]] && ! grep -Fq 'external snapshot content' "$SNAPSHOT_RACE_FIX/oss/ff-dev-toolkit/CHANGELOG.md"; then ok "snapshot cp 中の staged symlink 置換を集約しない"; else bad "snapshot cp が差し替え symlink の内容を集約"; fi
FAKE_MV_FAIL_SECOND_CONSUME=1 FAKE_MV_CONSUME_COUNT_FILE="$TMP/consume-count" run_contract "$FIX" --write
if [[ "$RC" -eq 2 && "$OUT" == *"second consume move failure"* && ! -e "$FRAGMENTS/.ff-changelog.lock" && -f "$FRAGMENTS/10.added.feature-a.md" && -f "$FRAGMENTS/60.security.feature-f.md" ]]; then ok "2件目の consume mv 失敗後に全断片と旧本体を復元"; else bad "consume 途中失敗で入力を喪失"; fi
FAKE_LN_FAIL_RETAINED=1 run_contract "$FIX" --write
if [[ "$RC" -eq 2 && "$OUT" == *"retained hard link failure"* && ! -e "$FRAGMENTS/.ff-changelog.lock" && -f "$FRAGMENTS/10.added.feature-a.md" ]]; then ok "retained hard link 失敗後に全入力を復元"; else bad "retained link 失敗で入力を喪失"; fi
FAKE_LN_FAIL_RECOVERY=1 run_contract "$FIX" --write
if [[ "$RC" -eq 2 && "$OUT" == *"recovery hard link failure"* && ! -e "$FRAGMENTS/.ff-changelog.lock" && -f "$FRAGMENTS/10.added.feature-a.md" ]]; then ok "recovery hard link 失敗後に全入力を復元"; else bad "recovery link 失敗で入力を喪失"; fi

for race_kind in input retained recovery; do
  RACE_FIX="$TMP/${race_kind}-link-directory-race"
  make_fixture "$RACE_FIX"
  printf '%s\n' "- ${race_kind} link race source" > "$RACE_FIX/changelog.d/13.changed.${race_kind}-link-race.md"
  case "$race_kind" in
    input) FAKE_PERL_INPUT_DIRECTORY_RACE=1 run_contract "$RACE_FIX" --write ;;
    retained) FAKE_PERL_RETAINED_DIRECTORY_RACE=1 run_contract "$RACE_FIX" --write ;;
    recovery) FAKE_PERL_RECOVERY_DIRECTORY_RACE=1 run_contract "$RACE_FIX" --write ;;
  esac
  if [[ "$RC" -eq 2 && -f "$RACE_FIX/changelog.d/13.changed.${race_kind}-link-race.md" ]] && ! grep -Fq "${race_kind} link race source" "$RACE_FIX/oss/ff-dev-toolkit/CHANGELOG.md"; then ok "${race_kind} hard-link 宛先 directory 競合を上書きしない"; else bad "${race_kind} hard-link 宛先 directory 競合で入力を喪失"; fi
done

RETAINED_SIGNAL_FIX="$TMP/retained-link-signal"
make_fixture "$RETAINED_SIGNAL_FIX"
printf '%s\n' '- retained link signal source' > "$RETAINED_SIGNAL_FIX/changelog.d/14.changed.retained-link-signal.md"
before_retained_signal="$(cksum "$RETAINED_SIGNAL_FIX/oss/ff-dev-toolkit/CHANGELOG.md")"
FAKE_PERL_RETAINED_SIGNAL=1 run_contract "$RETAINED_SIGNAL_FIX" --write
if [[ "$RC" -eq 130 && "$(cksum "$RETAINED_SIGNAL_FIX/oss/ff-dev-toolkit/CHANGELOG.md")" == "$before_retained_signal" && -f "$RETAINED_SIGNAL_FIX/changelog.d/14.changed.retained-link-signal.md" && ! -e "$RETAINED_SIGNAL_FIX/changelog.d/.ff-changelog.lock" ]]; then ok "retained hard-link 直後の signal でも入力を復元"; else bad "retained hard-link signal で入力を喪失"; fi
