#!/usr/bin/env bash
# Sourced by verify.sh after the existing adapter cases. No real network/key reads.
TRIAGE="$PLUGIN_ROOT/scripts/jev/triage-candidate.sh"
CASES="$PLUGIN_ROOT/scripts/jev/fixtures/triage-cases.jsonl"
PRINCIPLES="$PLUGIN_ROOT/scripts/jev/fixtures/triage-principles.md"
for f in "$TRIAGE" "$CASES" "$PRINCIPLES" "$PLUGIN_ROOT/scripts/jev/triage-registry.jq" \
  "$PLUGIN_ROOT/scripts/jev/questions/invariant.json" "$PLUGIN_ROOT/scripts/jev/questions/one-off-measurement.json"; do
  [ -r "$f" ] || { bad "L target missing: $f"; return 1; }
done
run_triage() {
  local mode="$1"; shift
  OUT="$(cd "${TRIAGE_CWD:-$PWD}" || exit 2
    env -i HOME="$ISO_HOME" PATH="$FAKE/bin:$PATH" TMPDIR="$WORK" FAKE_CURL_DIR="$FAKE" \
    FF_JEV_MODE="$mode" FF_JEV_ENABLED=1 TYPESAFE_API_KEY=test-only FF_JEV_MAX_RETRIES=0 \
    FF_JEV_DECISION_LOG="$WORK/triage-log.jsonl" bash "$TRIAGE" "$@" 2>"$WORK/triage.err")"
  RC=$?
  ERR="$(cat "$WORK/triage.err")"
  TRIAGE_JSON="$(printf '%s\n' "$OUT" | sed -n '1p')"
}
plan_noul() { # sequence number, question id, probability
  printf '200\n' >> "$FAKE/plan"
  jq -cn --arg q "$2" --argjson p "$3" \
    '{model:"jev-1.13.0",answers:{($q):{type:"noul",noul:$p}},usage:{input_tokens:100,output_tokens:5}}' > "$FAKE/body.call.$1"
}
reset_fake
run_triage off --candidate x --principles "$PRINCIPLES"
[ "$RC" -eq 12 ] && [ "$(calls)" -eq 0 ] && [[ "$OUT" == *'TRIAGE=undetermined|null|0'* ]] \
  && ok 'L1 explicit off returns hints without curl' || bad "L1 rc=$RC out=$OUT"
[ ! -f "$WORK/triage-log.jsonl" ] && ok 'L2 off writes no decision log' || bad 'L2 off logged'
# Execute the actual conditional entry fences with a recognizable legacy output.
for skill in ace-curate retrospective; do
  case "$skill" in ace-curate) ref=curate ;; retrospective) ref=ledger ;; esac
  grep -Fq "[triage](references/$ref.md#triage)" "$PLUGIN_ROOT/skills/$skill/SKILL.md" \
    && ok "L3 $skill reaches triage reference" || bad "L3 $skill reference missing"
  awk '/<!-- ff-triage-entry:start -->/{on=1;next} /<!-- ff-triage-entry:end -->/{on=0} on && !/^```/{print}' \
    "$PLUGIN_ROOT/skills/$skill/references/$ref.md" > "$WORK/entry.sh"
  if [ ! -s "$WORK/entry.sh" ]; then bad "L3 $skill entry absent"; continue; fi
  printf '\nprintf "legacy-output\\n"\n' >> "$WORK/entry.sh"
  printf 'legacy-output\n' > "$WORK/legacy"
  env -i HOME="$ISO_HOME" PATH="$FAKE/bin:$PATH" FF_JEV_MODE=off FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" \
    FAKE_CURL_DIR="$FAKE" CANDIDATE=x bash "$WORK/entry.sh" > "$WORK/actual"
  rc=$?
  [ "$rc" -eq 0 ] && cmp -s "$WORK/legacy" "$WORK/actual" && [ "$(calls)" -eq 0 ] \
    && ok "L3 $skill off fence preserves output bytes" || bad "L3 $skill off changed"
  for status in 401 429; do
    reset_fake "$status"
    env -i HOME="$ISO_HOME" PATH="$FAKE/bin:$PATH" TMPDIR="$WORK" FF_JEV_MODE=on FF_JEV_ENABLED=1 \
      FF_JEV_MAX_RETRIES=0 FF_JEV_DECISION_LOG="$WORK/caller-log.jsonl" TYPESAFE_API_KEY=test-only \
      FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" FF_PRINCIPLES_GLOB="$PRINCIPLES" FAKE_CURL_DIR="$FAKE" \
      CANDIDATE=x bash "$WORK/entry.sh" > "$WORK/actual" 2> "$WORK/caller.err"
    rc=$?
    [ "$rc" -eq 0 ] && [ "$(tail -n 1 "$WORK/actual")" = legacy-output ] && \
      grep -q '^TRIAGE=undetermined|null|0$' "$WORK/actual" \
      && ok "L3 $skill HTTP $status continues legacy path" || bad "L3 $skill HTTP $status stopped"
  done
  reset_fake
done
if jq -es 'length >= 12 and ([.[].expected] | unique == ["new_invariant","noise","one_off_measurement","reduces_to"]) and ([group_by(.expected)[] | length] | min >= 3) and
  all(.[]; (.candidate|type=="string" and length>0) and (.source|type=="string" and length>0) and
    (if .expected=="reduces_to" then (.principle_id|type=="string" and length>0) else .principle_id==null end))' "$CASES" >/dev/null; then
  ok 'L4 fixture has four categories with >=3 sourced cases each'
else bad 'L4 fixture contract'; fi
matched=0
total=0
while IFS= read -r row; do
  candidate="$(printf '%s' "$row" | jq -r .candidate)"
  expected="$(printf '%s' "$row" | jq -r .expected)"
  expected_id="$(printf '%s' "$row" | jq -r .principle_id)"
  reset_fake
  if [ "$expected" = reduces_to ]; then plan_noul 1 same_action 0.95
  else
    for n in 1 2 3; do plan_noul "$n" same_action 0.05; done
    if [ "$expected" = new_invariant ]; then plan_noul 4 invariant 0.95
    else
      plan_noul 4 invariant 0.05
      if [ "$expected" = one_off_measurement ]; then plan_noul 5 one_off_measurement 0.95
      else plan_noul 5 one_off_measurement 0.05; fi
    fi
  fi
  run_triage on --candidate "$candidate" --principles "$PRINCIPLES"
  total=$((total + 1))
  if [ "$RC" -eq 0 ] && printf '%s' "$TRIAGE_JSON" | jq -e --arg c "$expected" --arg id "$expected_id" \
    '.category==$c and ((.principle_id|tostring)==$id) and (.confidence > 0.89) and (.decision_ids|length>0)' >/dev/null; then
    matched=$((matched + 1)); ok "L5 $expected ($total)"
  else bad "L5 rc=$RC expected=$expected id=$expected_id out=$OUT err=$ERR"; fi
done < "$CASES"
[ "$total" -ge 12 ] && [ $((matched * 100 / total)) -ge 90 ] && ok "L6 fake routing match $matched/$total" || bad 'L6 routing below 90%'
for status in 401 429; do
  reset_fake "$status"
  run_triage on --candidate '実測 12ms' --principles "$PRINCIPLES"
  [ "$RC" -eq 11 ] && [[ "$OUT" == *'TRIAGE=undetermined|null|0'* ]] && \
    printf '%s' "$TRIAGE_JSON" | jq -e '.measurement_hint and (.top_k|length==3)' >/dev/null \
    && ok "L7 HTTP $status fallback contains principles" || bad "L7 $status rc=$RC out=$OUT"
done
reset_fake
plan_noul 1 same_action 0.65
run_triage on --candidate x --principles "$PRINCIPLES"
[ "$RC" -eq 10 ] && [[ "$OUT" == *'TRIAGE=undetermined|null|0'* ]] && [ "$(calls)" -eq 1 ] \
  && ok 'L8 low confidence stops chain' || bad "L8 rc=$RC out=$OUT"
reset_fake
run_triage on
[ "$RC" -eq 2 ] && [[ "$ERR" == *usage* ]] && [ "$(calls)" -eq 0 ] && ok 'L9 missing candidate is usage' || bad 'L9'
# A consumer fixture, independent of the SSOT Playbook and public checkout layout.
mkdir -p "$WORK/consumer/docs/08-knowledge/playbook"
printf '# Live index\n[entries](playbook/live.md)\n[archive](playbook/archive/old.md)\n' > "$WORK/consumer/docs/08-knowledge/PLAYBOOK.md"
for n in 1 2 3 4 5 6; do printf '### ACE-900-%s: live rule\n| Status | active |\nbody\n' "$n"; done > "$WORK/consumer/docs/08-knowledge/playbook/live.md"
printf '### ACE-800-1: retired\n| Status     | deprecated |\n### ACE-800-2: retired\n| Status\t| archived\t|\n' >> "$WORK/consumer/docs/08-knowledge/playbook/live.md"
TRIAGE_CWD="$WORK/consumer" run_triage off --candidate x --principles "$WORK/no-match/**/*.md"
[ "$RC" -eq 12 ] && [[ "$ERR" == *'live PLAYBOOK.md'* ]] && \
  printf '%s' "$TRIAGE_JSON" | jq -e '[.top_k[].id]==["ACE-900-1","ACE-900-2","ACE-900-3","ACE-900-4","ACE-900-5"]' >/dev/null \
  && ok 'L10 unmatched glob falls back to live playbook' || bad "L10 rc=$RC err=$ERR"
mkdir -p "$WORK/principles/nested"
cp "$PRINCIPLES" "$WORK/principles/nested/p.md"
run_triage off --candidate x --principles "$WORK/principles/**/*.md"
[ "$RC" -eq 12 ] && printf '%s' "$TRIAGE_JSON" | jq -e '.top_k|length==3' >/dev/null \
  && ok 'L11 recursive glob reads principles' || bad 'L11'
cp "$PRINCIPLES" "$WORK/principles/p.md"
run_triage off --candidate x --principles "$WORK/principles/*.md"
[ "$RC" -eq 12 ] && printf '%s' "$TRIAGE_JSON" | jq -e '.top_k|length==3' >/dev/null \
  && ok 'L12 one-level glob does not absorb nested files' || bad 'L12'
run_triage off --candidate x --principles "$WORK/principles/**/*.md"
[ "$RC" -eq 2 ] && [ "$(calls)" -eq 0 ] && ok 'L13 duplicate ID rejects ambiguous registry' || bad 'L13'
# Parser examples in fenced code do not turn into live principles.
printf '```markdown\n### P-001: example\n```\n### P-002: live\nbody\n## Other\nnot body\n' > "$WORK/code.md"
run_triage off --candidate x --principles "$WORK/code.md"
[ "$RC" -eq 12 ] && printf '%s' "$TRIAGE_JSON" | jq -e '.top_k|length==1 and .[0].id=="P-002" and (.[0].body|contains("not body")|not)' >/dev/null \
  && ok 'L14 fenced heading excluded and next heading ends body' || bad 'L14'
# Primitive tokenization must agree with the existing generator's Japanese bigrams.
# Direct equality with an explicitly sorted expected set.
jq -ne -L "$PLUGIN_ROOT/scripts/jev" 'include "triage-registry"; ("失敗監査 npm-ci"|tokens)==(["失敗","敗監","監査","npm-ci"]|sort)' >/dev/null \
  && ok 'L15 ASCII words and Japanese bigrams' || bad 'L15'
# Top-k selection is bounded and ties are deterministic.
for n in 6 5 4 3 2 1; do printf '### P-00%s: common\nbody\n' "$n"; done > "$WORK/six.md"
run_triage off --candidate common --principles "$WORK/six.md"
first="$OUT"
run_triage off --candidate common --principles "$WORK/six.md"
[ "$RC" -eq 12 ] && [ "$OUT" = "$first" ] && printf '%s' "$TRIAGE_JSON" | jq -e \
  '[.top_k[].id]==["P-001","P-002","P-003","P-004","P-005"]' >/dev/null \
  && ok 'L16 top five deterministic across ties' || bad 'L16'
reset_fake
OUT="$(env -i HOME="$ISO_HOME" PATH="$FAKE/bin:$PATH" TMPDIR="$WORK" FAKE_CURL_DIR="$FAKE" \
  FF_JEV_MODE=on FF_JEV_ENABLED=1 FF_JEV_POINTS=novelty TYPESAFE_API_KEY=test-only \
  FF_JEV_DECISION_LOG="$WORK/disabled-triage.jsonl" bash "$TRIAGE" --candidate x --principles "$PRINCIPLES" 2>"$WORK/triage.err")"
RC=$?
[ "$RC" -eq 12 ] && [ "$(calls)" -eq 0 ] && [ ! -f "$WORK/disabled-triage.jsonl" ] \
  && ok 'L17 disabled point returns hints without curl or log' || bad 'L17'
reset_fake
plan_noul 1 same_action 0.95
run_triage on --candidate x --principles "$PRINCIPLES"
id="$(printf '%s' "$TRIAGE_JSON" | jq -r '.decision_ids[0]')"
OUT="$(env -i HOME="$ISO_HOME" PATH="$FAKE/bin:$PATH" FF_JEV_DECISION_LOG="$WORK/triage-log.jsonl" \
  FAKE_CURL_DIR="$FAKE" bash "$TRIAGE" --overturn "$id" --note 'human correction' 2>"$WORK/triage.err")"
RC=$?
[ "$RC" -eq 0 ] && [ "$(calls)" -eq 1 ] && jq -se --arg id "$id" \
  'any(.[]; .event=="overturn" and .ref==$id and .note=="human correction")' "$WORK/triage-log.jsonl" >/dev/null \
  && ok 'L18 human overturn recorded without new request' || bad "L18 rc=$RC out=$OUT"
reset_fake
plan_noul 1 same_action 0.15
plan_noul 2 same_action 0.95
run_triage on --candidate x --principles "$PRINCIPLES"
[ "$RC" -eq 0 ] && [ "$(calls)" -eq 2 ] && printf '%s' "$TRIAGE_JSON" | jq -e \
  '.category=="reduces_to" and .principle_id=="P-002" and .confidence>0.6999 and .confidence<0.7001 and (.decision_ids|length==2)' >/dev/null \
  && ok 'L19 second principle matches and retains lowest confidence' || bad "L19 rc=$RC out=$OUT"
reset_fake
run_triage on --candidate x --principles
[ "$RC" -eq 2 ] && [[ "$ERR" == *usage* ]] && [ "$(calls)" -eq 0 ] \
  && ok 'L20 missing principles value has usage without curl' || bad 'L20'
