# shellcheck shell=bash
# release-runtime.sh の既存fixture内で gate の環境分離と部分会計拒否を検査する。
release_gate_mode_cases() {
  local state_file="$SSOT/.git/ff-release-state" mode receipt before_runs before_layout before_ssot before_public output
  local -a setting
  echo '-- release: selected gate mode is isolated from inherited selectors --'
  rm -f "$STATE/health.bad"
  before_ssot="$(git -C "$SSOT_ORIGIN" rev-parse develop)"
  before_public="$(git -C "$PUB_ORIGIN" rev-parse main)"
  for mode in changed fast-off fast-on full conflicting; do
    setting=()
    case "$mode" in
      changed) setting=(FF_RUN_ALL_CHANGED=HEAD~1) ;;
      fast-off) setting=(FF_RUN_ALL_FAST=0) ;;
      fast-on) setting=(FF_RUN_ALL_FAST=1) ;;
      full) setting=(FF_RUN_ALL_FULL=1) ;;
      conflicting) setting=(FF_RUN_ALL_CHANGED=HEAD~1 FF_RUN_ALL_FULL=1 FF_RUN_ALL_FAST=1) ;;
    esac
    rm -f "$state_file"; : >"$STATE/runall-env.log"
    before_runs="$(count_runall)"
    # run_orchのFULL除去を通らず、実際の親環境として全モード変数を本体へ渡す。
    RC=0
    OUT="$("$ENV_BIN" -u FF_RUN_ALL_FULL -u FF_RUN_ALL_FAST -u FF_RUN_ALL_CHANGED -u FF_RUN_ALL_NESTED \
      "${setting[@]}" bash "$SSOT/scripts/release-dev-toolkit.sh" --public "$PUB" --only gate 2>&1)" || RC=$?
    receipt="$(cat "$state_file" 2>/dev/null || true)"
    if [[ "$RC" -eq 0 && "$(count_runall)" -eq $((before_runs + 1)) ]] \
      && grep -qx 'full=<unset> fast=<unset> changed=<unset> nested=<unset> argc=0' "$STATE/runall-env.log" \
      && [[ "$receipt" == *"GATE_OK=$(git -C "$SSOT" rev-parse HEAD):fast"* ]]; then
      ok "inherited ${mode}: runs the default fast list with an actual matching receipt"
    else bad "inherited ${mode}: changed gate scope or lost the successful fast control"; dump; fi
  done
  : >"$STATE/health.bad"; rm -f "$state_file"; : >"$STATE/runall-env.log"
  FF_RUN_ALL_CHANGED=HEAD~1 FF_RUN_ALL_FAST=1 run_orch --only gate
  if [[ "$RC" -eq 0 ]] && grep -qx 'full=1 fast=<unset> changed=<unset> nested=<unset> argc=0' "$STATE/runall-env.log" \
    && grep -qF "GATE_OK=$(git -C "$SSOT" rev-parse HEAD):full" "$state_file"; then
    ok 'unhealthy weekly CI: inherited selectors do not narrow the explicit full gate'
  else bad 'unhealthy weekly CI: full gate mode does not match its receipt'; dump; fi
  rm -f "$STATE/health.bad" "$state_file"; : >"$STATE/runall-env.log"
  FF_RUN_ALL_NESTED=1 FF_RUN_ALL_CHANGED=HEAD~1 run_orch --only gate
  receipt="$(cat "$state_file" 2>/dev/null || true)"
  if [[ "$RC" -eq 1 && "$receipt" != *'GATE_OK='* ]] && has 'nested default list rejected' \
    && grep -qF 'nested=1 argc=0' "$STATE/runall-env.log"; then
    ok 'nested invocation keeps its stop guard and does not record GATE_OK'
  else bad 'nested invocation silently cleared the stop guard'; dump; fi
  for mode in green stale; do
    printf '%s\n' "$mode" >"$STATE/runall.partial"; rm -f "$state_file"
    before_layout="$(wc -l <"$STATE/public-layout.log")"
    FF_RUN_ALL_CHANGED=HEAD~1 run_orch --only gate
    receipt="$(cat "$state_file" 2>/dev/null || true)"
    if [[ "$RC" -eq 1 && "$receipt" != *'GATE_OK='* && "$(wc -l <"$STATE/public-layout.log")" -eq "$before_layout" ]] \
      && has 'run-all が部分実行'; then
      ok "partial ${mode}: rejected before freshness recovery, public-layout or GATE_OK"
    else bad "partial ${mode}: accepted incomplete accounting or missed the rejection path"; dump; fi
  done
  rm -f "$STATE/runall.partial" "$state_file"
  # stage側のguardとは独立に、鮮度の分類器そのものも部分会計を受け取らない。
  cat >"$STATE/partial-stale.out" <<'OUT'
suites: total=3 run=3 passed=1 failed=2 skipped=0 not-run=0
checks-skipped: total=0 suites=0
✗ failed: changelog-fragments shared-version-convergence
✗ stale (base が先行しているための赤を含む): changelog-fragments shared-version-convergence
OUT
  output="$(. "$SSOT/scripts/lib/release-gate-advance-functions.sh"; stale_only_suites "$STATE/partial-stale.out"; printf '%s|%s' "$STALE_SUITES" "$STALE_SUMMARY")"
  if [[ "$output" == 'changelog-fragments shared-version-convergence|suites: total=3 '* ]]; then
    ok 'freshness classifier accepts complete non-partial accounting control'
  else bad 'freshness classifier control did not reach the expected suites'; fi
  printf 'suites: selected=3 registered=4\n' >>"$STATE/partial-stale.out"
  output="$(. "$SSOT/scripts/lib/release-gate-advance-functions.sh"; stale_only_suites "$STATE/partial-stale.out"; printf '%s|%s' "$STALE_SUITES" "$STALE_SUMMARY")"
  if [[ "$output" == '|' ]]; then ok 'freshness classifier clears suites and summary for partial accounting'; else bad 'freshness classifier promoted partial accounting'; fi
  # 実際のneutral前進と名指し再検査も親のCHANGED/FASTから分離する。
  : >"$STATE/runall-env.log"; rm -f "$STATE/recheck.log"
  printf 'neutral\n' >"$STATE/runall.advance"
  FF_RUN_ALL_CHANGED=HEAD~1 FF_RUN_ALL_FAST=1 run_orch --only gate
  if [[ "$RC" -eq 0 ]] && grep -qx 'full=<unset> fast=<unset> changed=<unset> nested=<unset> argc=2' "$STATE/runall-env.log" \
    && grep -qx 'recheck 0 plugins/ff-dev-toolkit/tests/changelog-fragments/verify.sh plugins/ff-dev-toolkit/tests/shared-version-convergence/verify.sh' "$STATE/recheck.log"; then
    ok 'freshness recovery explicitly rechecks its suites without inherited selectors'
  else bad 'freshness recovery kept inherited selectors or missed the recheck'; dump; fi
  if [[ "$(git -C "$PUB_ORIGIN" rev-parse main)" == "$before_public" ]] \
    && git -C "$SSOT_ORIGIN" merge-base --is-ancestor "$before_ssot" develop; then
    ok 'mode cases preserve public origin and only allow the explicit neutral fixture advance'
  else bad 'mode cases changed public origin or rewrote SSOT history'; fi
  RELEASE_GATE_MODE_REACHED=1
}
