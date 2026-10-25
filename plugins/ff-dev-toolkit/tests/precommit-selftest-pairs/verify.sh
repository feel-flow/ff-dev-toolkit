#!/usr/bin/env bash
# staged git fixture で対の選択・単体実行・結果を検証する。実ネットワーク不要。
# 空振り検出: lib 不在/空/取得失敗は赤。接尾辞を -invalid へ変えた変異は paired case が赤、コメント追加は緑。
# run-all-required: yes — 対の実行・失敗判定の唯一の回帰。SKIP 文字列は負例 fixture であり本 suite は skip しない。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS="${SCRIPT_DIR%/*}"
LIB="${1:-$TESTS/lib/precommit-selftest-pairs.sh}"
[ -s "$LIB" ] || { echo 'selftest pairs lib 不在/空' >&2; exit 1; }
# shellcheck source=../lib/git-fixture.sh
. "$TESTS/lib/git-fixture.sh"
TMP="$(mktemp -d)"
REACHED_END=0
cleanup() {
  local rc=$?
  rm -rf "$TMP"
  if [ "$REACHED_END" -ne 1 ] && [ "$rc" -eq 0 ]; then rc=1; fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '✗ %s\n' "$1"; }
new_repo() { ff_git_fixture_init "$TMP/$1" >/dev/null; R="$TMP/$1"; }
consumer() {
  mkdir -p "$R/plugins/ff-dev-toolkit/tests/$1"
  printf '#!/usr/bin/env bash\nexit 91\n' >"$R/plugins/ff-dev-toolkit/tests/$1/verify.sh"
  git -C "$R" add .
}
pair() {
  consumer "$1"
  mkdir -p "$R/plugins/ff-dev-toolkit/tests/$1-selftest"
  printf '#!/usr/bin/env bash\nprintf "ran\\n" >> "$PROOF"\nexit %s\n' "${2:-0}" >"$R/plugins/ff-dev-toolkit/tests/$1-selftest/verify.sh"
  git -C "$R" add .
}
run() {
  RC=0
  PROOF="$TMP/proof" bash -c '. "$1"; declare -F selftest_pairs_scan >/dev/null || exit 2; selftest_pairs_scan "$2"' check "$LIB" "$R" >"$TMP/out" 2>"$TMP/err" || RC=$?
  OUT="$(cat "$TMP/out")"; ERR="$(cat "$TMP/err")"
}
has() { [[ "$OUT" == *"$1"* ]]; }

new_repo green; pair 'a quote'
run
if [ "$RC" -eq 0 ] && has 'selftest-pairs: ok 1' && has 'selftest result: PASS' && has 'selftest command: bash ' && [ "$(cat "$TMP/proof")" = ran ]; then
  ok '対だけを名指し・実行し、quoted コマンドと成功結果を残す'
else bad '対だけを名指し・実行し、quoted コマンドと成功結果を残す'; fi
pair beta 7
run
if [ "$RC" -eq 1 ] && has 'FAIL rc=7' && has 'selftest result: PASS' && ! has 'selftest-pairs: ok'; then
  ok '複数の対はすべて実行し、赤を成功にしない'
else bad '複数の対はすべて実行し、赤を成功にしない'; fi

new_repo none; consumer orphan-selftest
consumer 'nested/fixtures'
mkdir -p "$R/plugins/ff-dev-toolkit/tests/lib"
printf '# source only\n' >"$R/plugins/ff-dev-toolkit/tests/lib/helper.sh"
git -C "$R" add .
run
if [ "$RC" -eq 0 ] && [ "$OUT" = 'selftest-pairs: none' ]; then ok '対なし・単独 selftest・fixture・lib は対象なし'; else bad '対なし・単独 selftest・fixture・lib は対象なし'; fi
new_repo empty; run
if [ "$RC" -eq 0 ] && [ "$OUT" = 'selftest-pairs: none' ]; then ok '空 index は対象なし'; else bad '空 index は対象なし'; fi

new_repo literal; pair alpha
git -C "$R" -c core.hooksPath=/dev/null commit -qm baseline
consumer 'a*'
run
if [ "$RC" -eq 0 ] && [ "$OUT" = 'selftest-pairs: none' ]; then ok 'glob を含む名前を別 suite の対へ展開しない'; else bad 'glob を含む名前を別 suite の対へ展開しない'; fi
pair 'b[1]'
run
if [ "$RC" -eq 0 ] && has 'selftest-pairs: ok 1' && has 'b[1]-selftest/verify.sh'; then ok 'glob を含む実在する対も literal path で実行'; else bad 'glob を含む実在する対も literal path で実行'; fi

new_repo suffix; pair nested-selftest
run
if [ "$RC" -eq 0 ] && has 'nested-selftest-selftest/verify.sh' && has 'selftest-pairs: ok 1'; then ok '接尾辞を既に持つ consumer も実在する次の対を選ぶ'; else bad '接尾辞を既に持つ consumer も実在する次の対を選ぶ'; fi

new_repo dirty; pair alpha
printf '# unstaged\n' >>"$R/plugins/ff-dev-toolkit/tests/alpha-selftest/verify.sh"
run
if [ "$RC" -eq 2 ] && [[ "$ERR" == *'index と一致'* ]] && ! has 'selftest result: PASS'; then ok '対の未 stage 編集は未検査'; else bad '対の未 stage 編集は未検査'; fi
git -C "$R" add .
printf '# unstaged consumer\n' >>"$R/plugins/ff-dev-toolkit/tests/alpha/verify.sh"
run
if [ "$RC" -eq 2 ] && ! has 'selftest result: PASS'; then ok 'consumer の未 stage 編集も未検査'; else bad 'consumer の未 stage 編集も未検査'; fi

new_repo deleted; pair alpha
git -C "$R" -c core.hooksPath=/dev/null commit -qm baseline
printf '# staged\n' >>"$R/plugins/ff-dev-toolkit/tests/alpha/verify.sh"
git -C "$R" add -- plugins/ff-dev-toolkit/tests/alpha/verify.sh
rm "$R/plugins/ff-dev-toolkit/tests/alpha-selftest/verify.sh"
run
if [ "$RC" -eq 2 ] && [[ "$ERR" == *'読めません'* ]] && ! has 'selftest-pairs: none' && ! has 'selftest result: PASS'; then ok 'index に残る対の未 stage 削除は未検査'; else bad 'index に残る対の未 stage 削除は未検査'; fi
git -C "$R" add -u
run
if [ "$RC" -eq 0 ] && [ "$OUT" = 'selftest-pairs: none' ]; then ok '対の stage 済み削除は対象なし'; else bad '対の stage 済み削除は対象なし'; fi

new_repo untracked; pair alpha
git -C "$R" rm --cached -q -- plugins/ff-dev-toolkit/tests/alpha-selftest/verify.sh
run
if [ "$RC" -eq 2 ] && ! has 'selftest result: PASS'; then ok '未追跡の対は成功にしない'; else bad '未追跡の対は成功にしない'; fi

new_repo skipped; pair alpha
printf '#!/usr/bin/env bash\necho "○ skip: dependency unavailable"\n' >"$R/plugins/ff-dev-toolkit/tests/alpha-selftest/verify.sh"
git -C "$R" add .
run
if [ "$RC" -eq 2 ] && ! has 'selftest result: PASS'; then ok 'rc0 の SKIP は未検査'; else bad 'rc0 の SKIP は未検査'; fi
printf '#!/usr/bin/env bash\necho "  ○ skip: partial dependency unavailable"\n' >"$R/plugins/ff-dev-toolkit/tests/alpha-selftest/verify.sh"
git -C "$R" add .
run
if [ "$RC" -eq 2 ] && ! has 'selftest result: PASS'; then ok 'commit 前の selftest は部分 SKIP も未検査として残す'; else bad 'commit 前の selftest は部分 SKIP も未検査として残す'; fi

new_repo renamed; pair old
git -C "$R" -c core.hooksPath=/dev/null commit -qm baseline
mkdir -p "$R/plugins/ff-dev-toolkit/tests/new"
git -C "$R" mv plugins/ff-dev-toolkit/tests/old/verify.sh plugins/ff-dev-toolkit/tests/new/verify.sh
pair new
run
if [ "$RC" -eq 0 ] && has 'selftest-pairs: ok 1' && ! has 'old-selftest'; then ok 'rename は移動先を選び、削除された consumer を選ばない'; else bad 'rename は移動先を選び、削除された consumer を選ばない'; fi
git -C "$R" config diff.relative true
R="$R/plugins/ff-dev-toolkit"
run
if [ "$RC" -eq 0 ] && has 'selftest-pairs: ok 1'; then ok 'サブディレクトリと diff.relative 設定でも全パスで判定'; else bad 'サブディレクトリと diff.relative 設定でも全パスで判定'; fi

R="$TMP/not-repo"; mkdir -p "$R"; run
if [ "$RC" -eq 2 ] && [ -z "$OUT" ]; then ok 'git 不在位置は未検査'; else bad 'git 不在位置は未検査'; fi
REAL_GIT="$(command -v git)"
mkdir -p "$TMP/bin"
for kind in fail malformed truncated conflict; do
  new_repo "git-$kind"; pair alpha
  {
    printf '#!/usr/bin/env bash\n'
    printf 'for arg in "$@"; do if [ "$arg" = diff ]; then\n'
    case "$kind" in
      fail) printf 'exit 128\n' ;;
      malformed) printf 'printf "changed path\\0"; exit 0\n' ;;
      truncated) printf 'printf ":100644 100644 a b M\\0path"; exit 0\n' ;;
      conflict) printf 'printf ":100644 100644 a b U\\0path\\0"; exit 0\n' ;;
    esac
    printf 'fi; done\nexec "%s" "$@"\n' "$REAL_GIT"
  } >"$TMP/bin/git"
  chmod +x "$TMP/bin/git"
  RC=0
  PATH="$TMP/bin:$PATH" bash -c '. "$1"; selftest_pairs_scan "$2"' check "$LIB" "$R" >"$TMP/out" 2>"$TMP/err" || RC=$?
  if [ "$RC" -eq 2 ] && ! grep -q 'selftest-pairs: none\|selftest result: PASS' "$TMP/out"; then ok "git ${kind} は未検査"; else bad "git ${kind} は未検査"; fi
done

# 対が見つからないときの index 照会失敗を「対象なし」にしない。
new_repo index-fail; consumer alpha
{
  printf '#!/usr/bin/env bash\n'
  printf 'for a in "$@"; do [ "$a" != ls-files ] || exit 128; done\n'
  printf 'exec "%s" "$@"\n' "$REAL_GIT"
} >"$TMP/bin/git"
RC=0
PATH="$TMP/bin:$PATH" bash -c '. "$1"; selftest_pairs_scan "$2"' check "$LIB" "$R" >"$TMP/out" 2>"$TMP/err" || RC=$?
if [ "$RC" -eq 2 ] && ! grep -q 'selftest-pairs: none' "$TMP/out"; then ok '対の index 照会失敗は未検査'; else bad '対の index 照会失敗は未検査'; fi

# 結果を読めなかった回は、grep の「一致なし」と混同しない。
new_repo grep-fail; pair alpha
mkdir -p "$TMP/grep-bin"
printf '#!/usr/bin/env bash\nexit 2\n' >"$TMP/grep-bin/grep"
chmod +x "$TMP/grep-bin/grep"
RC=0
PROOF="$TMP/proof" PATH="$TMP/grep-bin:$PATH" bash -c '. "$1"; selftest_pairs_scan "$2"' check "$LIB" "$R" >"$TMP/out" 2>"$TMP/err" || RC=$?
if [ "$RC" -eq 2 ] && ! grep -q 'selftest result: PASS' "$TMP/out"; then ok '結果の読み取り失敗は未検査'; else bad '結果の読み取り失敗は未検査'; fi

# 同じ Git fixture の helper 選択と、実 runner の高速除外を突き合わせる。
new_repo runner; pair foo; consumer orphan-selftest
FIXTURE_TESTS="$R/plugins/ff-dev-toolkit/tests"
for n in foo foo-selftest orphan-selftest; do
  printf '#!/usr/bin/env bash\necho "executed %s"\n' "$n" >"$FIXTURE_TESTS/$n/verify.sh"
  chmod +x "$FIXTURE_TESTS/$n/verify.sh"
done
git -C "$R" add .
run
HELPER_MATCH=0
if [ "$RC" -eq 0 ] && has 'selftest-pairs: ok 1' && has 'executed foo-selftest' && ! has 'executed orphan-selftest'; then HELPER_MATCH=1; fi
RC=0
env -u FF_DEV_TOOLKIT_ROOT -u FF_RUN_ALL_FULL -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_CHANGED FF_RUN_ALL_FAST=1 FF_GATE_RECORD=0 \
  bash "$TESTS/run-all.sh" "$FIXTURE_TESTS/foo-selftest/verify.sh" "$FIXTURE_TESTS/orphan-selftest/verify.sh" >"$TMP/runner.log" 2>&1 || RC=$?
if [ "$RC" -eq 0 ] && [ "$HELPER_MATCH" -eq 1 ] && grep -q 'executed orphan-selftest' "$TMP/runner.log" && ! grep -q 'executed foo-selftest' "$TMP/runner.log"; then
  ok '実 runner の高速モードと同じ対が除外され、単独 selftest は残る'
else bad '実 runner の高速モードと同じ対が除外され、単独 selftest は残る'; fi

printf 'precommit-selftest-pairs: passed=%s failed=%s\n' "$PASS" "$FAIL"
REACHED_END=1
[ "$FAIL" -eq 0 ]
