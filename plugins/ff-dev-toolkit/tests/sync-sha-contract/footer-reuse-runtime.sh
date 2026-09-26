#!/usr/bin/env bash
# public-layout の footer 再利用証明を実 Git 内容と実分類器で検証する（ネットワークなし）。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
. "$SCRIPT_DIR/../lib/git-fixture.sh"
ORCH="${1:?release script required}"
ORCH="$(cd "$(dirname "$ORCH")" && pwd -P)/$(basename "$ORCH")"
REPO_ROOT="$(cd "$(dirname "$ORCH")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/footer-reuse-runtime.XXXXXX")"
[[ -d "$TMP" ]] || { echo '✗ temporary directory unavailable' >&2; exit 1; }
REACHED_END=0
cleanup() {
  local rc=$?
  rm -rf "$TMP"
  if [[ "$REACHED_END" -ne 1 && "$rc" -eq 0 ]]; then rc=1; fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
# 実関数を取り出す。アンカー消失・空抽出は緑へ倒さない。
awk '/^FOOTER_GATE_BASE=/{p=1} /^stage_gate\(\)/{exit} p' "$ORCH" >"$TMP/functions.sh"
grep -q '^footer_gate_reusable()' "$TMP/functions.sh" || { echo '✗ footer proof function missing'; exit 1; }
. "$TMP/functions.sh"
has_line() { [[ $'\n'"$1"$'\n' == *$'\n'"$2"$'\n'* ]]; }
LIMITED_RC=0
limited_gate() { return "$LIMITED_RC"; }
# 分類器の欠落 / 空出力 / 異なる成功状態を模擬する（本番に注入口は設けない）。
PROBE_CLASSIFIER=real
bash() {
  case "$PROBE_CLASSIFIER" in
    missing) return 127 ;;
    empty) return 0 ;;
    identical) echo FULL_GATE_REUSE=IDENTICAL; return 0 ;;
    failed) echo FULL_GATE_REUSE=CHANGELOG_FOOTER_ONLY; return 1 ;;
    *) command bash "$@" ;;
  esac
}
mkdir -p "$TMP/repo/scripts" "$TMP/repo/oss/ff-dev-toolkit"
cp "$REPO_ROOT/scripts/check-full-gate-reuse.sh" "$TMP/repo/scripts/"
ff_git_fixture_init "$TMP/repo" 'Release Test' 'release-test@feelflow.test'
cd "$TMP/repo"
CHANGELOG=oss/ff-dev-toolkit/CHANGELOG.md
FOOTER_REUSE_SCRIPT=scripts/check-full-gate-reuse.sh
printf '%s\n' '# Changelog' '' '## [Unreleased]' '' '- body' '' \
  '[Unreleased]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.1.0...HEAD' \
  '[0.1.0]: https://github.com/feel-flow/ff-dev-toolkit/releases/tag/v0.1.0' >"$CHANGELOG"
printf 'unchanged\n' >payload
# Isolated fixture commits only; no user worktree changes.
git add -A && git commit -qm base
BASE="$(git rev-parse HEAD)"
printf '%s\n' '[0.2.0]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.1.0...v0.2.0' >>"$CHANGELOG"
git add -A && git commit -qm footer
HEAD_OK="$(git rev-parse HEAD)"
BLOB_OK="$(git rev-parse "HEAD:$CHANGELOG")"
FOOTER_GATE_BASE="$BASE"; FOOTER_GATE_HEAD="$HEAD_OK"; FOOTER_GATE_BLOB="$BLOB_OK"
PASS=0; FAIL=0
expect() {
  local want="$1" name="$2" rc=0; shift 2
  "$@" >"$TMP/out" 2>&1 || rc=$?
  if [[ ( "$want" == yes && "$rc" == 0 ) || ( "$want" == no && "$rc" != 0 ) ]]; then
    echo "  ✓ footer proof: $name"; PASS=$((PASS + 1))
  else
    echo "  ✗ footer proof: $name (rc=$rc)"; cat "$TMP/out"; FAIL=$((FAIL + 1))
  fi
}
expect yes 'footer-only direct child with evidence' footer_gate_reusable "$BASE:fast" "$HEAD_OK"
FOOTER_GATE_BASE=''
expect no 'missing process-local evidence' footer_gate_reusable "$BASE:fast" "$HEAD_OK"
FOOTER_GATE_BASE="$BASE"
expect no 'missing success record' footer_gate_reusable '' "$HEAD_OK"
expect no 'unknown success mode' footer_gate_reusable "$BASE:garbage" "$HEAD_OK"
expect no 'different success SHA' footer_gate_reusable "$HEAD_OK:full" "$HEAD_OK"
expect no 'different current HEAD' footer_gate_reusable "$BASE:full" "$BASE"
FOOTER_GATE_BLOB="$BASE"
expect no 'limited-gate blob mismatch' footer_gate_reusable "$BASE:full" "$HEAD_OK"
FOOTER_GATE_BLOB="$BLOB_OK"
for PROBE_CLASSIFIER in missing empty identical failed; do
  expect no "classifier $PROBE_CLASSIFIER" footer_gate_reusable "$BASE:full" "$HEAD_OK"
done
PROBE_CLASSIFIER=real
LIMITED_RC=1
expect no 'limited-gate failure' footer_gate_reusable "$BASE:full" "$HEAD_OK"
LIMITED_RC=0
printf dirty >>payload
expect no 'dirty tracked input' footer_gate_reusable "$BASE:full" "$HEAD_OK"
git restore payload
printf extra >extra
expect no 'untracked input' footer_gate_reusable "$BASE:full" "$HEAD_OK"
rm extra
# Amend preserves a single parent but alters the checked contents: no names-only proof.
for mutation in body other mode suffix; do
  git reset -q --hard "$HEAD_OK"
  case "$mutation" in
    body) sed 's/- body/- changed body/' "$CHANGELOG" >"$TMP/new"; cp "$TMP/new" "$CHANGELOG" ;;
    other) printf change >>payload ;;
    mode) chmod +x "$CHANGELOG" ;;
    suffix) printf '%s\n' '[0.3.0]: https://github.com/feel-flow/ff-dev-toolkit/releases/tag/v0.3.0 trailing' >>"$CHANGELOG" ;;
  esac
  git add -A && git commit -q --amend --no-edit
  FOOTER_GATE_HEAD="$(git rev-parse HEAD)"; FOOTER_GATE_BLOB="$(git rev-parse "HEAD:$CHANGELOG")"
  expect no "content difference: $mutation" footer_gate_reusable "$BASE:full" "$FOOTER_GATE_HEAD"
done
git reset -q --hard "$HEAD_OK"
git commit -q --allow-empty -m intervening
FOOTER_GATE_HEAD="$(git rev-parse HEAD)"; FOOTER_GATE_BLOB="$BLOB_OK"
expect no 'additional commit invalidates direct-parent proof' footer_gate_reusable "$BASE:full" "$FOOTER_GATE_HEAD"
# 限定ゲート自体も実関数で空出力 / skip / 赤を拒否する。
awk '/^limited_gate\(\)/{p=1} /^FOOTER_COMMITTED=/{exit} p' "$ORCH" >"$TMP/limited.sh"
grep -q '^limited_gate()' "$TMP/limited.sh" || { echo '✗ limited gate function missing'; exit 1; }
. "$TMP/limited.sh"
PUBLIC_TAGS_VERIFY=tags; CONTRACT_VERIFY=contract
LIMITED_OUTPUT='✓ fixture'; LIMITED_EXIT=0
capture() { CAP_FILE="$TMP/captured"; printf '%s' "$LIMITED_OUTPUT" >"$CAP_FILE"; CAP_RC="$LIMITED_EXIT"; }
expect yes 'limited gate green evidence' limited_gate
LIMITED_OUTPUT=''
expect no 'limited gate empty successful output' limited_gate
LIMITED_OUTPUT='✓ fixture
○ skip: fixture'
expect no 'limited gate partial skip' limited_gate
LIMITED_OUTPUT='✓ fixture'; LIMITED_EXIT=1
expect no 'limited gate nonzero with green text' limited_gate
echo "footer-reuse-runtime: pass=$PASS fail=$FAIL"
REACHED_END=1
[[ "$FAIL" -eq 0 ]]
