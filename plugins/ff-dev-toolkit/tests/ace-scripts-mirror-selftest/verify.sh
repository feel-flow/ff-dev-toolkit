#!/usr/bin/env bash
#
# ace-scripts-mirror gate の検出力を隔離 fixture への mutation で実測する（Issue #338）。
# 作業ツリーは変更せず、README 差分・fail-closed・byte drift・片側ファイル・
# 安全でないファイル名・既知 consumer の構築式迂回・単一源迂回を独立に撃つ。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SOURCE_VERIFY="$PLUGIN_ROOT/tests/ace-scripts-mirror/verify.sh"
SOURCE_SSOT="$PLUGIN_ROOT/docs-template/scripts/ace"

if ! command -v perl >/dev/null 2>&1; then
  echo "○ skip: perl が見つからないため ace-scripts-mirror の mutation self-test をスキップ（検査は1件も実行されていません）"
  exit 0
fi

if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/ace-scripts-mirror-selftest.XXXXXX" 2>&1)"; then
  TMP="$(cd "$_ff_mktemp_out" && pwd)"
  TMP_PARENT="$(cd "${TMPDIR:-/tmp}" && pwd)"
else
  echo "○ skip: 書き込み可能な一時領域を作れないため ace-scripts-mirror の mutation self-test をスキップ（検査は1件も実行されていません）"
  exit 0
fi

case "$TMP" in
  "$TMP_PARENT"/ace-scripts-mirror-selftest.*) ;;
  *)
    echo "✗ mktemp が想定外のパスを返しました: $TMP" >&2
    exit 1
    ;;
esac

FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$TMP"
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ ace-scripts-mirror-selftest: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

assert_contains() { # <label> <haystack> <needle>
  local label="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) ok "$label" ;;
    *)
      bad "${label}（期待する診断が無い: ${needle}）"
      printf '    gate output: %s\n' "$haystack" >&2
      ;;
  esac
}

reset_fixture() {
  rm -rf "$TMP/repo"
  mkdir -p "$TMP/repo/plugins/ff-dev-toolkit/tests/ace-scripts-mirror" \
    "$TMP/repo/plugins/ff-dev-toolkit/docs-template/scripts/ace" \
    "$TMP/repo/scripts/ace"
  cp "$SOURCE_VERIFY" \
    "$TMP/repo/plugins/ff-dev-toolkit/tests/ace-scripts-mirror/verify.sh"
  cp "$SOURCE_SSOT"/*.ts \
    "$TMP/repo/plugins/ff-dev-toolkit/docs-template/scripts/ace/"
  cp "$SOURCE_SSOT"/*.ts "$TMP/repo/scripts/ace/"
  # baseline から README を意図的に異ならせる。ゲートが対象を広げすぎるとここで赤になる。
  printf '%s\n' 'docs-template README' \
    > "$TMP/repo/plugins/ff-dev-toolkit/docs-template/scripts/ace/README.md"
  printf '%s\n' 'root mirror README' > "$TMP/repo/scripts/ace/README.md"
  FIXTURE_VERIFY="$TMP/repo/plugins/ff-dev-toolkit/tests/ace-scripts-mirror/verify.sh"
  FIXTURE_SSOT="$TMP/repo/plugins/ff-dev-toolkit/docs-template/scripts/ace"
  FIXTURE_MIRROR="$TMP/repo/scripts/ace"
}

run_red() { # <label>
  local label="$1"
  if RUN_OUTPUT="$(/bin/bash "$FIXTURE_VERIFY" 2>&1)"; then
    bad "$label が red にならなかった"
    printf '    gate output: %s\n' "$RUN_OUTPUT" >&2
    return 1
  fi
  ok "$label が非 0 終了"
  return 0
}

remember_file() { MUTATION_BEFORE="$(cksum < "$1")"; }
assert_file_changed() { # <label> <file>
  local label="$1" file="$2" after
  after="$(cksum < "$file")"
  if [ "$MUTATION_BEFORE" != "$after" ]; then
    return 0
  fi
  bad "$label の mutation が対象へ当たりませんでした"
  return 1
}

echo "== ace-scripts-mirror mutation self-test =="

reset_fixture
if RUN_OUTPUT="$(/bin/bash "$FIXTURE_VERIFY" 2>&1)"; then
  assert_contains "README 差分を含む baseline が green" "$RUN_OUTPUT" "非 .ts は契約外"
else
  bad "README 差分を含む baseline が失敗"
  printf '    %s\n' "$RUN_OUTPUT" >&2
fi

reset_fixture
printf '%s\n' 'export {};' > "$FIXTURE_MIRROR/unsafe name.ts"
if run_red "空白入り .ts ファイル名"; then
  assert_contains "安全でないファイル名を分割せず名指し" "$RUN_OUTPUT" "unsafe name.ts"
  assert_contains "安全 token 違反として報告" "$RUN_OUTPUT" "安全な token ではありません"
fi

reset_fixture
rm -rf "$FIXTURE_MIRROR"
if run_red "mirror ディレクトリ欠落"; then
  assert_contains "ディレクトリ欠落を fail-closed で診断" "$RUN_OUTPUT" "ACE scripts ディレクトリが見つかりません"
fi

reset_fixture
rm "$FIXTURE_SSOT"/*.ts "$FIXTURE_MIRROR"/*.ts
if run_red ".ts 一覧が空"; then
  assert_contains "検査 0 件を fail-closed で診断" "$RUN_OUTPUT" ".ts 一覧が空です"
fi

# import は残し、構築式だけをローカル source へ変える。`ACE-` リテラルを含めないため
# ローカル regex ヒューリスティックではなく、構築式のピンだけがこの mutation を受ける。
run_construction_bypass() { # <consumer>
  local consumer="$1" target mutation_ok=1
  reset_fixture
  for target in "$FIXTURE_SSOT/$consumer" "$FIXTURE_MIRROR/$consumer"; do
    remember_file "$target"
    perl -0pi -e 's{entryHeadingSource\("capture-id"\)}{String.raw`^### ([0-9-]+):`}' "$target"
    if ! assert_file_changed "$consumer の構築式迂回" "$target"; then
      mutation_ok=0
    fi
  done
  if [ "$mutation_ok" -ne 1 ]; then
    return
  fi
  if ! cmp -s "$FIXTURE_SSOT/$consumer" "$FIXTURE_MIRROR/$consumer"; then
    bad "$consumer の構築式迂回 fixture が byte-identical ではありません"
  elif run_red "$consumer の共有 import を残した構築式迂回"; then
    assert_contains "$consumer の構築式チェックが単独で検出" "$RUN_OUTPUT" "entryHeadingSource を使う既知の構築式がありません"
  fi
}

run_construction_bypass "ace-refine-report.ts"
run_construction_bypass "ace-reuse-report.ts"
run_construction_bypass "check-entry-format.ts"

reset_fixture
rm "$FIXTURE_SSOT/check-category-size.ts" "$FIXTURE_MIRROR/check-category-size.ts"
if run_red "entryHeadingSource の単一源を両側削除"; then
  assert_contains "単一源の欠落を名指し" "$RUN_OUTPUT" "entryHeadingSource の単一源が見つかりません"
fi

reset_fixture
for target in "$FIXTURE_SSOT/ace-reuse-report.ts" "$FIXTURE_MIRROR/ace-reuse-report.ts"; do
  remember_file "$target"
  perl -0pi -e 's/^export const DEFAULT_STALE_DAYS/const DEFAULT_STALE_DAYS/m' "$target"
  assert_file_changed "DEFAULT_STALE_DAYS の export 除去" "$target" || true
done
if run_red "DEFAULT_STALE_DAYS の export 除去"; then
  assert_contains "stale 日数の export 単一源欠落を名指し" "$RUN_OUTPUT" "DEFAULT_STALE_DAYS の export 単一源がありません"
fi

reset_fixture
for target in "$FIXTURE_SSOT/ace-refine-report.ts" "$FIXTURE_MIRROR/ace-refine-report.ts"; do
  remember_file "$target"
  perl -0pi -e 's/^  DEFAULT_STALE_DAYS,\n//m' "$target"
  assert_file_changed "DEFAULT_STALE_DAYS の共有 import 除去" "$target" || true
done
if run_red "DEFAULT_STALE_DAYS の共有 import 除去"; then
  assert_contains "stale 日数の共有 import 欠落を名指し" "$RUN_OUTPUT" "DEFAULT_STALE_DAYS を ace-reuse-report から import していません"
fi

reset_fixture
for target in "$FIXTURE_SSOT/ace-refine-report.ts" "$FIXTURE_MIRROR/ace-refine-report.ts"; do
  remember_file "$target"
  perl -0pi -e 's/(const WARN_PREFIX = "ace-refine-report";\n)/$1const DEFAULT_STALE_DAYS = 90;\n/' "$target"
  assert_file_changed "DEFAULT_STALE_DAYS のローカル定義再導入" "$target" || true
done
if run_red "DEFAULT_STALE_DAYS のローカル定義再導入"; then
  assert_contains "stale 日数のローカル定義を名指し" "$RUN_OUTPUT" "DEFAULT_STALE_DAYS のローカル定義を検出"
fi

reset_fixture
remember_file "$FIXTURE_MIRROR/check-entry-format.ts"
printf '%s' ' ' >> "$FIXTURE_MIRROR/check-entry-format.ts"
if assert_file_changed "1 byte drift" "$FIXTURE_MIRROR/check-entry-format.ts" && run_red "1 byte drift"; then
  assert_contains "drift 診断が SSOT を名指し" "$RUN_OUTPUT" "$FIXTURE_SSOT/check-entry-format.ts"
  assert_contains "drift 診断が mirror を名指し" "$RUN_OUTPUT" "$FIXTURE_MIRROR/check-entry-format.ts"
fi

reset_fixture
rm "$FIXTURE_MIRROR/check-archive-links.ts"
if run_red "mirror 側のファイル欠落"; then
  assert_contains "欠落ファイルを名指し" "$RUN_OUTPUT" "check-archive-links.ts"
  assert_contains "欠落した側を名指し" "$RUN_OUTPUT" "mirror に無し"
fi

reset_fixture
printf '%s\n' 'export {};' > "$FIXTURE_MIRROR/one-sided.ts"
if run_red "mirror 側だけの新規ファイル"; then
  assert_contains "片側新規ファイルを名指し" "$RUN_OUTPUT" "one-sided.ts"
  assert_contains "存在する側を名指し" "$RUN_OUTPUT" "mirror="
fi

# byte-identical を保ったまま両側の consumer を同じローカル regex へ書き戻す。
# ミラー比較だけでは green なので、import graph / construction gate の検出力を直接測る。
reset_fixture
for target in \
  "$FIXTURE_SSOT/check-entry-format.ts" \
  "$FIXTURE_MIRROR/check-entry-format.ts"; do
  remember_file "$target"
  perl -0pi -e 's/  entryHeadingSource,\n//' "$target"
  perl -0pi -e 's{entryHeadingSource\("capture-id"\)}{String.raw`^### (ACE-i?\\d(?:[\\w-]*\\w)?):`}' "$target"
  assert_file_changed "entryHeadingSource のローカル regex 書き戻し" "$target" || true
done
if ! cmp -s "$FIXTURE_SSOT/check-entry-format.ts" "$FIXTURE_MIRROR/check-entry-format.ts"; then
  bad "単一源迂回 fixture の両ミラーが byte-identical ではありません"
elif run_red "entryHeadingSource の単一源迂回"; then
  assert_contains "共有 import の欠落を名指し" "$RUN_OUTPUT" "entryHeadingSource を check-category-size から import していません"
  assert_contains "ローカル regex を名指し" "$RUN_OUTPUT" "ローカル ACE 見出し regex を検出"
fi

if [ "$FAIL" -gt 0 ]; then
  echo "ace-scripts-mirror-selftest verify: $FAIL 件失敗 / $PASS 件 pass" >&2
  exit 1
fi

echo "ace-scripts-mirror-selftest verify: 全 $PASS 件 pass"
FF_REACHED_END=1
