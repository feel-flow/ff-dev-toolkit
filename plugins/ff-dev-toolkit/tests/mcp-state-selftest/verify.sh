#!/usr/bin/env bash
#
# Issue #386: mcp-dist-gate / mcp-vitest の dist_state と mcp-typecheck の
# tree_state が fail-closed であり続けることを、隔離 fixture への mutation で固定する。
#
# 2 本の dist_state wrapper は byte 比較する。両者は同じ引数で共通 helper を呼ぶだけの
# 意図的に同一な境界なので、振る舞いを二重実行するよりも「片方だけの変更」を最小の
# 差分で検出できる。共通 helper 自体の検出力は下の 5 条件で別途実測する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
HELPER="$TESTS_DIR/lib/tree-state.sh"
DIST_GATE="$TESTS_DIR/mcp-dist-gate/verify.sh"
VITEST_GATE="$TESTS_DIR/mcp-vitest/verify.sh"
TYPECHECK_GATE="$TESTS_DIR/mcp-typecheck/verify.sh"

for required in "$HELPER" "$DIST_GATE" "$VITEST_GATE" "$TYPECHECK_GATE"; do
  if [[ ! -f "$required" ]]; then
    echo "✗ mcp-state-selftest: 必要なファイルがありません: $required" >&2
    exit 1
  fi
done

# shellcheck source=../lib/tree-state.sh
. "$HELPER"

if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/mcp-state-selftest.XXXXXX" 2>&1)"; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できないため mcp state mutation self-test をスキップ（検査は1件も実行されていません）"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  exit 0
fi
REACHED_END=0
cleanup() {
  local rc=$?
  rm -rf "$TMP"
  if [[ $rc -eq 0 && $REACHED_END -ne 1 ]]; then
    echo "✗ mcp-state-selftest: 最後まで到達しませんでした" >&2
    exit 1
  fi
  exit "$rc"
}
trap cleanup EXIT

PASS=0
FAIL=0
ok() {
  echo "✓ $1"
  PASS=$((PASS + 1))
}
bad() {
  echo "✗ $1" >&2
  FAIL=$((FAIL + 1))
}

expect_failure() {
  local label="$1"
  shift
  if "$@" >"$TMP/last.out" 2>"$TMP/last.err"; then
    bad "$label: mutation が exit 0 になった"
    sed 's/^/  stdout: /' "$TMP/last.out" >&2
    sed 's/^/  stderr: /' "$TMP/last.err" >&2
  else
    ok "$label"
  fi
}

extract_function() {
  local file="$1"
  local name="$2"
  awk -v signature="$name() {" '
    $0 == signature { capture = 1 }
    capture { print }
    capture && $0 == "}" { exit }
  ' "$file"
}

# 空白を含む root とファイル名を fixture に使う。`xargs cksum` 等へ退行すると
# この取得が失敗し selftest 全体が red になる。
ROOT="$TMP/root with spaces"
mkdir -p "$ROOT/dist"
printf 'alpha\n' >"$ROOT/dist/index.js"
printf 'space\n' >"$ROOT/dist/file with spaces.js"
if BASELINE="$(ff_tree_state "$ROOT" dist)" &&
  grep -Fq 'dist/file with spaces.js' <<<"$BASELINE"; then
  ok "空白パスを分割せず状態取得できる"
else
  bad "空白パスの状態取得に失敗した"
fi

# 内容の変化が状態へ反映されることも固定する。失敗を非 0 にするだけでなく、
# read-only 事後比較が実際に変更を検出できることの positive test。
printf 'alpha changed\n' >"$ROOT/dist/index.js"
if CHANGED="$(ff_tree_state "$ROOT" dist)" && [[ "$CHANGED" != "$BASELINE" ]]; then
  ok "ファイル内容の変更で状態が変わる"
else
  bad "ファイル内容の変更を状態差分として検出できない"
fi
printf 'alpha\n' >"$ROOT/dist/index.js"

# mutation 1: cksum が非 0。pipeline の末尾 sort だけを見て緑にしないこと。
FAIL_BIN="$TMP/fail-bin"
mkdir -p "$FAIL_BIN"
printf '%s\n' '#!/usr/bin/env bash' 'exit 7' >"$FAIL_BIN/cksum"
chmod +x "$FAIL_BIN/cksum"
hash_command_fails() (
  PATH="$FAIL_BIN:$PATH"
  export PATH
  ff_tree_state "$ROOT" dist
)
expect_failure "cksum 非 0 を fail-closed で検出する" hash_command_fails

# mutation 2 / 3: 対象欠落と通常ファイル 0 件を空の基準線として受理しないこと。
expect_failure "対象ディレクトリ欠落を検出する" ff_tree_state "$ROOT" missing-dist
mkdir -p "$ROOT/empty-dist"
expect_failure "通常ファイル 0 件を検出する" ff_tree_state "$ROOT" empty-dist

# mutation 4: 実行前取得は成功し、実行後取得だけ cksum が失敗するケース。
# helper の非 0 伝播に加え、前後取得を行う最小 consumer が後半の失敗で red に
# なることを固定する。実 gate の consumer 構造は下の静的境界検査で別途固定する。
FLAKY_BIN="$TMP/flaky-bin"
mkdir -p "$FLAKY_BIN"
REAL_CKSUM="$(command -v cksum)"
cat >"$FLAKY_BIN/cksum" <<'SH'
#!/usr/bin/env bash
count=0
if [[ -f "$FF_CKSUM_COUNT" ]]; then
  count="$(cat "$FF_CKSUM_COUNT")"
fi
count=$((count + 1))
printf '%s\n' "$count" >"$FF_CKSUM_COUNT"
if [[ $count -ge 2 ]]; then
  exit 9
fi
exec "$FF_REAL_CKSUM" "$@"
SH
chmod +x "$FLAKY_BIN/cksum"
flaky_state() (
  PATH="$FLAKY_BIN:$PATH"
  FF_CKSUM_COUNT="$TMP/cksum-count"
  FF_REAL_CKSUM="$REAL_CKSUM"
  export PATH FF_CKSUM_COUNT FF_REAL_CKSUM
  ff_tree_state "$ROOT" dist
)
rm -f "$TMP/cksum-count"
read_only_consumer() {
  local before after
  if ! before="$(flaky_state)"; then
    return 1
  fi
  if ! after="$(flaky_state)"; then
    return 1
  fi
  [[ "$after" == "$before" ]]
}
expect_failure "実行後だけの取得失敗で consumer が red になる" read_only_consumer

# mutation 5: node_modules 以下は除外しつつ、tree_state 対象全体は空にしない。
mkdir -p "$ROOT/tree/node_modules/pkg" "$ROOT/tree/src"
printf 'ignored\n' >"$ROOT/tree/node_modules/pkg/index.js"
printf 'tracked\n' >"$ROOT/tree/src/file with spaces.ts"
if TREE_STATE="$(ff_tree_state "$ROOT/tree" . node_modules)" &&
  ! grep -Fq node_modules <<<"$TREE_STATE" &&
  grep -Fq './src/file with spaces.ts' <<<"$TREE_STATE"; then
  ok "tree_state は node_modules を除外し空白パスを保持する"
else
  bad "tree_state の除外境界が壊れている"
fi

DIST_BODY_A="$(extract_function "$DIST_GATE" dist_state)"
DIST_BODY_B="$(extract_function "$VITEST_GATE" dist_state)"
EXPECTED_DIST_BODY='dist_state() {
  ff_tree_state "$MCP_DIR" dist
}'
if [[ -z "$DIST_BODY_A" ]]; then
  bad "mcp-dist-gate から dist_state を抽出できない"
fi
if [[ -z "$DIST_BODY_B" ]]; then
  bad "mcp-vitest から dist_state を抽出できない"
fi
if [[ -n "$DIST_BODY_A" && "$DIST_BODY_A" == "$DIST_BODY_B" ]]; then
  ok "mcp-dist-gate / mcp-vitest の dist_state は byte 一致する"
else
  bad "2 suite の dist_state に drift がある"
fi
if [[ "$DIST_BODY_A" == "$EXPECTED_DIST_BODY" ]]; then
  ok "dist_state は検証済み共通 helper だけを呼ぶ"
else
  bad "dist_state が共通 helper 境界から drift した"
fi
# 実ファイルの片側へ 1 行を注入してから同じ extractor + comparator を通す。
# 単なる `A + suffix != B` の恒真 assertion にせず、抽出境界も含めて実測する。
MUTATED_GATE="$TMP/mcp-vitest-mutated.sh"
awk '
  $0 == "dist_state() {" { print; print "  # one-sided mutation"; next }
  { print }
' "$VITEST_GATE" >"$MUTATED_GATE"
MUTATED_DIST_BODY="$(extract_function "$MUTATED_GATE" dist_state)"
if [[ -n "$MUTATED_DIST_BODY" && "$MUTATED_DIST_BODY" != "$DIST_BODY_A" ]]; then
  ok "実ファイルの片側 mutation を byte drift として検出する"
else
  bad "実ファイルの片側 mutation を byte drift comparator が見逃した"
fi

TREE_BODY="$(extract_function "$TYPECHECK_GATE" tree_state)"
EXPECTED_TREE_BODY='tree_state() {
  ff_tree_state "$MCP_DIR" . node_modules
}'
if [[ "$TREE_BODY" == "$EXPECTED_TREE_BODY" ]]; then
  ok "mcp-typecheck の tree_state も同じ fail-closed helper を使う"
else
  bad "mcp-typecheck の tree_state が共通 helper 境界から drift した"
fi

# helper の事後失敗を実 gate が握りつぶさない consumer 境界。wrapper の byte 比較とは
# 責務が異なるため、3 gate それぞれの正準行を固定して `|| true` 等の drift を赤にする。
for gate_spec in \
  "$DIST_GATE|if ! STATE_AFTER=\"\$(dist_state)\"; then" \
  "$VITEST_GATE|if ! STATE_AFTER=\"\$(dist_state)\"; then" \
  "$TYPECHECK_GATE|if ! STATE_AFTER=\"\$(tree_state)\"; then"; do
  gate="${gate_spec%%|*}"
  expected_guard="${gate_spec#*|}"
  if grep -Fqx "$expected_guard" "$gate"; then
    ok "$(basename "$(dirname "$gate")") は事後取得失敗を握りつぶさない"
  else
    bad "$(basename "$(dirname "$gate")") の事後 fail-closed guard が drift した"
  fi
done

for gate in "$DIST_GATE" "$VITEST_GATE" "$TYPECHECK_GATE"; do
  if grep -Fq '. "$SCRIPT_DIR/../lib/tree-state.sh"' "$gate"; then
    ok "$(basename "$(dirname "$gate")") は共通 helper を source する"
  else
    bad "$(basename "$(dirname "$gate")") が共通 helper を source していない"
  fi
done

if [[ $FAIL -ne 0 ]]; then
  echo "mcp-state-selftest: $FAIL failed, $PASS passed" >&2
  exit 1
fi

REACHED_END=1
echo "mcp-state-selftest: All $PASS tests passed."
