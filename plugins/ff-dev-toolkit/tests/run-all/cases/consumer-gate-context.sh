# shellcheck shell=bash
# Real cases source -> real tracked scanner. Do not replace git or the detector with a stub.
EXITCODE_CONTEXT_CASES=0
_ec_context_tmp="$(mktemp -d "${TMPDIR:-/tmp}/ff-consumer-context.XXXXXX")"
mkdir -p "$_ec_context_tmp/tests/run-all/cases" "$_ec_context_tmp/tests/lib"
cp "$SCRIPT_DIR/cases/exit-code-guard.sh" "$_ec_context_tmp/tests/run-all/cases/"
cp "$SCRIPT_DIR/../lib/exit-code-guard.sh" "$_ec_context_tmp/tests/lib/"
: > "$_ec_context_tmp/consumer.sh"
git -C "$_ec_context_tmp" -c init.defaultBranch=main init -q .
git -C "$_ec_context_tmp" add -- consumer.sh
# The child sources the actual shared cases, which perform their own isolated self-tests before the live scan.
cat > "$_ec_context_tmp/source-case.sh" <<'CHILD'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$1/tests/run-all"
mode="$2"
case "$mode" in
  unset) unset FF_EXIT_CODE_GUARD_GATES ;;
  empty) FF_EXIT_CODE_GUARD_GATES=; export FF_EXIT_CODE_GUARD_GATES ;;
  blank) FF_EXIT_CODE_GUARD_GATES=$'\n \t\r\n'; export FF_EXIT_CODE_GUARD_GATES ;;
  multi|multi-safe) FF_EXIT_CODE_GUARD_GATES=$'\npnpm validate:app\nnpm run ci:local\n\n'; export FF_EXIT_CODE_GUARD_GATES ;;
  unexported) FF_EXIT_CODE_GUARD_GATES='npm run ci:local'; export -n FF_EXIT_CODE_GUARD_GATES ;;
  export-unset) unset FF_EXIT_CODE_GUARD_GATES; export FF_EXIT_CODE_GUARD_GATES ;;
  *) exit 2 ;;
esac
before="$(declare -p FF_EXIT_CODE_GUARD_GATES 2>/dev/null)" || before=UNSET
PASS=0
FAIL=0
ok() { PASS=$((PASS+1)); }
bad() { printf 'CASE_BAD=%s\n' "$1"; FAIL=$((FAIL+1)); }
. "$SCRIPT_DIR/cases/exit-code-guard.sh"
after="$(declare -p FF_EXIT_CODE_GUARD_GATES 2>/dev/null)" || after=UNSET
if [ "$before" = "$after" ]; then printf 'STATE_RESTORED=yes\n'; else printf 'STATE_RESTORED=no before=[%s] after=[%s]\n' "$before" "$after"; fi
collection_nonempty=0
if [ "$EXITCODE_CONSUMER_CASES" -gt 0 ]; then collection_nonempty=1; fi
printf 'REAL_SCAN=%s\nREAL_RC=%s\nSELFTEST=%s\nCONSUMER_CASES=%s\nCOLLECTION_NONEMPTY=%s\nCASE_FAILURES=%s\n' "${EXITCODE_SUMMARY:-MISSING}" "${EXITCODE_RC:-MISSING}" "$EXITCODE_SELFTEST_OK" "$EXITCODE_CONSUMER_CASES" "$collection_nonempty" "$FAIL"
exit "$FAIL"
CHILD
_ec_context_modes=(unset empty blank multi multi-safe unexported export-unset)
for _ec_context_mode in "${_ec_context_modes[@]:-}"; do
  [ -n "$_ec_context_mode" ] || continue
  if [ "$_ec_context_mode" = multi-safe ]; then
    printf '%s\n' '#!/usr/bin/env bash' 'npm run ci:local > log; rc=$?; tail log; exit $rc' > "$_ec_context_tmp/consumer.sh"
  else
    printf '%s\n' '#!/usr/bin/env bash' 'npm run ci:local > log; tail log' > "$_ec_context_tmp/consumer.sh"
  fi
  _ec_context_rc=0
  _ec_context_out="$(env -u FF_EXIT_CODE_GUARD_GATES bash "$_ec_context_tmp/source-case.sh" "$_ec_context_tmp" "$_ec_context_mode" 2>&1)" || _ec_context_rc=$?
  _ec_context_expected=0
  [ "$_ec_context_mode" = multi ] && _ec_context_expected=1
  _ec_context_valid=1
  case "$_ec_context_out" in *'STATE_RESTORED=yes'*'SELFTEST=1'*'COLLECTION_NONEMPTY=1'*) : ;; *) _ec_context_valid=0 ;; esac
  if [ "$_ec_context_expected" -eq 1 ]; then
    case "$_ec_context_out" in *consumer.sh*gate-exit-swallowed*'REAL_SCAN=EXIT_CODE_RESULT=hits SCANNED=1 HITS=1 ERRORS=0'*'REAL_RC=1'*'CASE_FAILURES=1'*) : ;; *) _ec_context_valid=0 ;; esac
  else
    case "$_ec_context_out" in *'REAL_SCAN=EXIT_CODE_RESULT=ok SCANNED=1 HITS=0 ERRORS=0'*'REAL_RC=0'*'CASE_FAILURES=0'*) : ;; *) _ec_context_valid=0 ;; esac
  fi
  if [ "$_ec_context_rc" -eq "$_ec_context_expected" ] && [ "$_ec_context_valid" -eq 1 ]; then
    ok "consumer設定を隔離後に復元し実tracked走査へ渡す: $_ec_context_mode"
  else
    bad "consumer設定の復元/実走査が不正: $_ec_context_mode rc=$_ec_context_rc out=[$_ec_context_out]"
  fi
  EXITCODE_CONTEXT_CASES=$((EXITCODE_CONTEXT_CASES+1))
done
rm -rf "$_ec_context_tmp"
