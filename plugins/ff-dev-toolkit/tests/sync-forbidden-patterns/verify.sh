#!/usr/bin/env bash
#
# sync-forbidden-patterns: 公開対象の禁止パターン検査を run-all から常時走らせる。
#
# 背景: 検査は公開同期を実行したときにしか走らず、同期は承認制で頻度が低い。
# 違反が develop に潜伏し、全 suite が緑のまま後の dry-run で初めて検出された。
# 発火しないゲートは無いのと同じ期間がある。
#
# 固定する契約:
#   - 公開対象の作業ツリーに禁止パターンを 1 件混入した隔離 dir を
#     --check-only --scan-dir すると、内容は file:line、ファイル名は相対パスで
#     名指しして非 0 で終わる
#   - 違反のない現状の公開対象作業ツリーは --check-only（target 不要）でクリアする
#   - パターン一覧の単一の真実源は同期スクリプトの配列。本 suite は配列を
#     持たない。スクリプト複製へ新しいパターンを足すと検出され、元スクリプト
#     では検出されないことで「更新後の一覧が使われる」を実測する
#   - 同期スクリプトや公開対象ディレクトリが無い checkout では ○ skip
#   - 一時領域を作れない場合も ○ skip（変異 fixture 用。live 検査の前に判定する）
#   - --check-only の live 分岐（--scan-dir なし）は、スクリプト配置先の
#     PUBLIC_TARGETS 作業ツリーを見る。隔離の偽リポジトリで配線を実測する
#
# 本ファイルは公開同期対象。禁止パターンのリテラルを隣接して書かないこと
# （隔離 fixture へ実行時に組み立てて流す。再現性のために実パスを戻すと
# 公開同期が止まる）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
SYNC="${REPO_ROOT:+$REPO_ROOT/scripts/sync-dev-toolkit-to-public.sh}"

if [[ -z "$REPO_ROOT" || ! -f "$SYNC" ]]; then
  echo "○ skip: 同期スクリプトが無いチェックアウトのためスキップ（本 suite は SSOT リポジトリ専用の検査です）"
  FF_REACHED_END=1
  exit 0
fi

if ! targets="$("$SYNC" --list-targets)"; then
  echo "✗ --list-targets が失敗しました（スクリプトは存在するので検査不能は skip にしない）" >&2
  exit 1
fi
if [[ -z "$targets" ]]; then
  echo "✗ --list-targets の出力が空です（公開対象一覧の真実源が空なら検査は成立していない）" >&2
  exit 1
fi

while IFS= read -r t; do
  [[ -n "$t" ]] || continue
  if [[ ! -d "$REPO_ROOT/$t" ]]; then
    echo "○ skip: 公開対象ディレクトリが揃っていないチェックアウトのためスキップ"
    FF_REACHED_END=1
    exit 0
  fi
done <<<"$targets"

if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/sync-forbidden-patterns.XXXXXX" 2>&1)"; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できない環境（read-only）のためスキップ"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  FF_REACHED_END=1
  exit 0
fi

FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$TMP"
  if [[ "$_ff_rc" -eq 0 && "$FF_REACHED_END" -ne 1 ]]; then
    echo "✗ sync-forbidden-patterns: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# 旧公開パスを実行時に組み立てる。本ファイルへ隣接リテラルで書かない。
retired_path="$(printf '%s%s' 'plugins/' 'dev-toolkit')"

run_check() {
  bash "$SYNC" --check-only "$@"
}

expect_clear() {
  local label="$1" out rc
  shift
  set +e
  out="$("$@" 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -eq 0 && "$out" == *"禁止パターン検査: クリア"* ]]; then
    ok "$label"
  else
    bad "$label (rc=${rc})"
    printf '%s\n' "$out" | sed 's/^/    | /' >&2
  fi
}

expect_hit() {
  local label="$1" needle="$2" out rc
  shift 2
  set +e
  out="$("$@" 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -ne 0 && "$out" == *"$needle"* ]]; then
    ok "$label"
  else
    bad "$label (rc=${rc})"
    printf '%s\n' "$out" | sed 's/^/    | /' >&2
  fi
}

expect_fail() {
  local label="$1" needle="$2" out rc
  shift 2
  set +e
  out="$("$@" 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -ne 0 && "$out" == *"$needle"* ]]; then
    ok "$label"
  else
    bad "$label (rc=${rc})"
    printf '%s\n' "$out" | sed 's/^/    | /' >&2
  fi
}

echo "sync-forbidden-patterns verify:"

# --- 1. 現状の公開対象作業ツリーはクリア（--target なしで検査できること） ----
expect_clear "現状の公開対象作業ツリーは --check-only でクリアする" run_check

# --- 2. 違反のない隔離 dir は pass ------------------------------------------
mkdir -p "$TMP/clean"
printf '%s\n' 'safe content' > "$TMP/clean/ok.md"
: > "$TMP/clean/empty.txt"
expect_clear "違反のない隔離 dir は --scan-dir でクリアする（空ファイル含む）" \
  run_check --scan-dir "$TMP/clean"

mkdir -p "$TMP/empty"
expect_clear "空の --scan-dir はクリアする" run_check --scan-dir "$TMP/empty"

# --- 3. 内容への混入をファイルと行で名指しする（変異） ------------------------
mkdir -p "$TMP/content"
printf '%s\n' 'safe line 1' 'safe line 2' "$retired_path" > "$TMP/content/note.md"
expect_hit "内容の混入をファイルと行で名指しして非 0 にする" "note.md:3" \
  run_check --scan-dir "$TMP/content"

# --- 4. ファイル名への混入を名指しする（変異） --------------------------------
mkdir -p "$TMP/name/${retired_path}"
printf '%s\n' 'safe' > "$TMP/name/${retired_path}/x.txt"
expect_hit "ファイル名の混入をパスで名指しして非 0 にする" "$retired_path" \
  run_check --scan-dir "$TMP/name"

# --- 5. 配列を更新すると新しいパターンが使われる（二重定義しないことの実測） --
sentinel="ff476sentinelforbidden"
awk -v s="$sentinel" '
  /^FORBIDDEN_PATTERNS=\(/ {
    print
    print "  '\''" s "'\''"
    next
  }
  { print }
' "$SYNC" > "$TMP/mutated.sh"
chmod +x "$TMP/mutated.sh"
mkdir -p "$TMP/sentinel"
printf '%s\n' 'safe line' "$sentinel" > "$TMP/sentinel/s.txt"

expect_hit "配列へ足したパターンを複製スクリプトが検出する" "s.txt:2" \
  bash "$TMP/mutated.sh" --check-only --scan-dir "$TMP/sentinel"
expect_clear "元スクリプトは未登録のセンチネルを検出しない（一覧は配列が真実源）" \
  run_check --scan-dir "$TMP/sentinel"

# --- 6. live 分岐（--scan-dir なし）の配線を偽リポジトリで実測 ---------------
FAKE="$TMP/fake"
mkdir -p "$FAKE/scripts" "$FAKE/plugins/ff-dev-toolkit" "$FAKE/oss/ff-dev-toolkit"
cp "$SYNC" "$FAKE/scripts/sync-dev-toolkit-to-public.sh"
printf '%s\n' 'ok' > "$FAKE/plugins/ff-dev-toolkit/ok.md"
printf '%s\n' 'ok' > "$FAKE/oss/ff-dev-toolkit/ok.md"
expect_clear "偽リポジトリの live --check-only は健全ならクリアする" \
  bash "$FAKE/scripts/sync-dev-toolkit-to-public.sh" --check-only

printf '%s\n' 'safe' 'safe' "$retired_path" > "$FAKE/plugins/ff-dev-toolkit/hit.md"
expect_hit "live --check-only は PUBLIC_TARGETS 作業ツリーの混入を file:line で名指しする" \
  "plugins/ff-dev-toolkit/hit.md:3" \
  bash "$FAKE/scripts/sync-dev-toolkit-to-public.sh" --check-only

# --- 7. symlink / 非空 binary は fail-closed。空ファイルは通す ---------------
mkdir -p "$TMP/link"
printf '%s\n' 'safe' > "$TMP/link/ok.md"
ln -s ok.md "$TMP/link/alias.md"
expect_hit "symlink 混入は相対パスを名指しして非 0 にする" "alias.md" \
  run_check --scan-dir "$TMP/link"

mkdir -p "$TMP/bin"
# grep -rIL . は NUL の前にテキストがあるファイルを binary と見なさない。
# 既存の検出器と同じヒューリスティックに乗るよう、マッチしない非空 binary を置く。
dd if=/dev/urandom of="$TMP/bin/blob.bin" bs=64 count=1 status=none 2>/dev/null \
  || dd if=/dev/urandom of="$TMP/bin/blob.bin" bs=64 count=1 2>/dev/null
expect_hit "非空 binary は検査対象外として非 0 にする" "blob.bin" \
  run_check --scan-dir "$TMP/bin"

# --- 8. 作業ツリー検査は node_modules 配下を見ない --------------------------
mkdir -p "$TMP/nm/node_modules/pkg"
printf '%s\n' "$retired_path" > "$TMP/nm/node_modules/pkg/secret.txt"
printf '%s\n' 'safe' > "$TMP/nm/ok.md"
expect_clear "node_modules 配下の禁止文字列は作業ツリー検査から除外する" \
  run_check --scan-dir "$TMP/nm"

# --- 9. スクリプト不在の checkout は ○ skip --------------------------------
PUB="$TMP/public-checkout"
mkdir -p "$PUB/plugins/ff-dev-toolkit/tests/sync-forbidden-patterns"
cp "$SCRIPT_DIR/verify.sh" "$PUB/plugins/ff-dev-toolkit/tests/sync-forbidden-patterns/verify.sh"
git -C "$PUB" init -q
git -C "$PUB" config user.email selftest@example.com
git -C "$PUB" config user.name sync-forbidden-selftest
set +e
skip_out="$(bash "$PUB/plugins/ff-dev-toolkit/tests/sync-forbidden-patterns/verify.sh" 2>&1)"
skip_rc=$?
set -e
if [[ "$skip_rc" -eq 0 && $'\n'"$skip_out" == *$'\n○ skip'* ]]; then
  ok "同期スクリプトが無い checkout は行頭 ○ skip で exit 0"
else
  bad "スクリプト不在の skip 契約が崩れた (rc=${skip_rc})"
  printf '%s\n' "$skip_out" | sed 's/^/    | /' >&2
fi

# --- 10. 新設フラグの不正組み合わせは説明付きで非 0 --------------------------
expect_fail "--scan-dir 単独は拒否する" "--check-only と一緒" \
  bash "$SYNC" --scan-dir "$TMP/clean"
expect_fail "--check-only と --dry-run は同時に使えない" "--dry-run" \
  bash "$SYNC" --check-only --dry-run
expect_fail "--check-only と --target は同時に使えない" "--target" \
  bash "$SYNC" --check-only --target "$TMP/clean"
expect_fail "存在しない --scan-dir は拒否する" "存在しません" \
  bash "$SYNC" --check-only --scan-dir "$TMP/does-not-exist"

echo
if [[ "$FAIL" -gt 0 ]]; then
  echo "✗ sync-forbidden-patterns verify: ${FAIL} 件 fail / ${PASS} 件 pass" >&2
  FF_REACHED_END=1
  exit 1
fi
echo "✓ sync-forbidden-patterns verify: 全 ${PASS} 件 pass"
FF_REACHED_END=1
exit 0
