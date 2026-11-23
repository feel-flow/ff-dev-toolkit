#!/usr/bin/env bash
# 空振り検出: 空・別のスキル、異なるホスト実体、別名マニフェスト、空・欠落した記録器、symlink の scripts に対し、pnpm が起動せず exit 2 になることを検査する。
set -euo pipefail

source_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
fixture="$(mktemp -d)"
trap 'status=$?; rm -rf -- "$fixture"; exit "$status"' EXIT
plugin="$fixture/active toolkit"
skill="$plugin/skills/verify-gate"
project="$fixture/consumer project"
mkdir -p "$skill/scripts" "$plugin/scripts/lib" "$plugin/.claude-plugin" "$project" "$fixture/bin"
mkdir -p "$fixture/decoy/repo"
cp "$source_root/skills/verify-gate/SKILL.md" "$skill/SKILL.md"
cp "$source_root/skills/verify-gate/scripts/run.sh" "$skill/scripts/run.sh"
cp "$source_root/scripts/record-gate-head.sh" "$plugin/scripts/record-gate-head.sh"
cp "$source_root/scripts/lib/abs-path.sh" "$plugin/scripts/lib/abs-path.sh"
cp "$source_root/.claude-plugin/plugin.json" "$plugin/.claude-plugin/plugin.json"

cat > "$fixture/bin/pnpm" <<'STUB'
#!/usr/bin/env bash
set -eu
touch "$PNPM_CALLED"
printf '%s\n' "$(pwd -P)" "$FF_DEV_TOOLKIT_ROOT" "$FF_DEV_TOOLKIT_SKILL_FILE" "$@"
if [[ "${FIXTURE_REPLACE_RECORD:-0}" == 1 ]]; then
  cp -- "$FF_GATE_RECORD_FILE" "$FF_GATE_RECORD_FILE.replacement"
  mv -f -- "$FF_GATE_RECORD_FILE.replacement" "$FF_GATE_RECORD_FILE"
fi
exit "${FIXTURE_STATUS:-0}"
STUB
chmod +x "$fixture/bin/pnpm"
export PATH="$fixture/bin:$PATH"
export PNPM_CALLED="$fixture/pnpm-called"
export FF_GATE_RECORD_FILE="$fixture/gate-record"
export FF_DEV_TOOLKIT_SKILL_FILE="$skill/SKILL.md"
export FF_DEV_TOOLKIT_ROOT="$fixture/obsolete toolkit"
unset CLAUDE_PLUGIN_ROOT GROK_PLUGIN_ROOT
cd -- "$project"

physical_project="$(pwd -P)"
physical_plugin="$(cd -- "$plugin" && pwd -P)"
expected="$(printf '%s\n' "$physical_project" "$physical_plugin" "$skill/SKILL.md" verify:gate)"
actual="$(CDPATH="$fixture/decoy" bash "$skill/scripts/run.sh" 2> "$fixture/status")"
test "$actual" = "$expected"
grep -Fx "GATE_RECORD_PATH=$FF_GATE_RECORD_FILE" "$fixture/status"
grep -Fx 'GATE_RECORD_BEFORE=missing' "$fixture/status"
grep -Fx 'GATE_RECORD_START_DIRTY=unverified' "$fixture/status"
test ! -e "$FF_GATE_RECORD_FILE"
host_output="$(env -u FF_DEV_TOOLKIT_SKILL_FILE CLAUDE_PLUGIN_ROOT="$plugin" \
  bash "$skill/scripts/run.sh" 2> "$fixture/status")"
test "$host_output" = "$(printf '%s\n' "$physical_project" "$physical_plugin" "$physical_plugin/skills/verify-gate/SKILL.md" verify:gate)"
FF_GATE_RECORD_FILE='relative record' bash "$skill/scripts/run.sh" > "$fixture/output" 2> "$fixture/status"
grep -Fx "GATE_RECORD_PATH=$physical_project/relative record" "$fixture/status"
OSTYPE=msys FF_GATE_RECORD_FILE='C:/repo/gate-record' bash "$skill/scripts/run.sh" > "$fixture/output" 2> "$fixture/status"
grep -Fx 'GATE_RECORD_PATH=C:/repo/gate-record' "$fixture/status"

expected="$(printf '%s\n' "$expected" --suite diff --suite format)"
printf '%s\n' 'STATUS=pass' > "$FF_GATE_RECORD_FILE"
record_stat() {
  LC_ALL=C TZ=UTC stat -c '%i %y %z' -- "$1" 2>/dev/null ||
    LC_ALL=C TZ=UTC stat -f '%i %.9Fm %.9Fc' -- "$1" 2>/dev/null
}
record_metadata="$(record_stat "$FF_GATE_RECORD_FILE")"
record_checksum="$(cksum < "$FF_GATE_RECORD_FILE")"
status=0
actual="$(CLAUDE_PLUGIN_ROOT="$plugin" GROK_PLUGIN_ROOT="$physical_plugin" FIXTURE_STATUS=37 \
  bash "$skill/scripts/run.sh" --suite diff --suite format 2> "$fixture/status")" || status=$?
test "$status" -eq 37
test "$actual" = "$expected"
grep -Fx "GATE_RECORD_BEFORE=$record_metadata | $record_checksum" "$fixture/status"
test "$(record_stat "$FF_GATE_RECORD_FILE")" = "$record_metadata"
test "$(cksum < "$FF_GATE_RECORD_FILE")" = "$record_checksum"

FIXTURE_REPLACE_RECORD=1 bash "$skill/scripts/run.sh" > "$fixture/output" 2> "$fixture/status"
grep -Fx "GATE_RECORD_BEFORE=$record_metadata | $record_checksum" "$fixture/status"
test "$(record_stat "$FF_GATE_RECORD_FILE")" != "$record_metadata"
test "$(cksum < "$FF_GATE_RECORD_FILE")" = "$record_checksum"

assert_stops() {
  local recorded_status=0
  rm -f -- "$PNPM_CALLED"
  bash "$skill/scripts/run.sh" > "$fixture/output" 2>&1 || recorded_status=$?
  test "$recorded_status" -eq 2
  test ! -e "$PNPM_CALLED"
  grep -F 'このskillを再呼び出してください' "$fixture/output"
}

touch "$fixture/other-SKILL.md"
FF_DEV_TOOLKIT_SKILL_FILE="$fixture/other-SKILL.md" assert_stops
: > "$skill/SKILL.md"
assert_stops
cp "$source_root/skills/verify-gate/SKILL.md" "$skill/SKILL.md"
printf '%s\n' 'exit 0' > "$plugin/scripts/lib/abs-path.sh"
assert_stops
cp "$source_root/scripts/lib/abs-path.sh" "$plugin/scripts/lib/abs-path.sh"
CLAUDE_PLUGIN_ROOT="$fixture/missing-toolkit" assert_stops
GROK_PLUGIN_ROOT="$fixture" assert_stops
mv -- "$plugin/scripts" "$fixture/other-scripts"
ln -s -- "$fixture/other-scripts" "$plugin/scripts"
assert_stops
rm -- "$plugin/scripts"
mv -- "$fixture/other-scripts" "$plugin/scripts"
sed 's/"name": "ff-dev-toolkit"/"name": "another-toolkit"/' \
  "$source_root/.claude-plugin/plugin.json" > "$plugin/.claude-plugin/plugin.json"
assert_stops
printf '{\n  "name": "ff-dev-toolkit",\n' > "$plugin/.claude-plugin/plugin.json"
assert_stops
{
  printf '\357\273\277'
  cat "$source_root/.claude-plugin/plugin.json"
} > "$plugin/.claude-plugin/plugin.json"
assert_stops
cp "$source_root/.claude-plugin/plugin.json" "$plugin/.claude-plugin/plugin.json"
cat > "$plugin/scripts/record-gate-head.sh" <<'STUB'
#!/usr/bin/env bash
[[ "$*" == --print-path ]] || exit 2
printf '%s\n' "$FF_GATE_RECORD_FILE"
STUB
assert_stops
cat > "$plugin/scripts/record-gate-head.sh" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == --print-path ]]; then
  printf '%s\n' "$FF_GATE_RECORD_FILE"
fi
exit 0
STUB
assert_stops
sed '/printf .*RECORD_VERSION=/d' "$source_root/scripts/record-gate-head.sh" > "$plugin/scripts/record-gate-head.sh"
assert_stops
sed '/printf .*DIRTY=/d' "$source_root/scripts/record-gate-head.sh" > "$plugin/scripts/record-gate-head.sh"
assert_stops
sed 's/--porcelain --untracked-files=normal/--porcelain/g' "$source_root/scripts/record-gate-head.sh" > "$plugin/scripts/record-gate-head.sh"
assert_stops
sed '/^  git_dir="\$(git rev-parse/i\
  [[ "$PRINT_PATH" -eq 1 ]] || return 1
' "$source_root/scripts/record-gate-head.sh" > "$plugin/scripts/record-gate-head.sh"
assert_stops
test "$(cksum < "$FF_GATE_RECORD_FILE")" = "$record_checksum"
printf '%s\n' '# obsolete recorder' > "$plugin/scripts/record-gate-head.sh"
assert_stops
: > "$plugin/scripts/record-gate-head.sh"
assert_stops
rm -- "$plugin/scripts/record-gate-head.sh"
assert_stops
echo 'Project quality gate handoff checks passed.'
