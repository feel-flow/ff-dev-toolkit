#!/usr/bin/env bash
#
# /pre-commit-check 手順 8 の lib 由来の先行検査を隔離 git fixture で直接叩く。
#   - 実行ビット検査（tests/lib/exec-bit-guard.sh の exec_bit_scan。Issue `#1741` / bundle `#1758` / OBS-206）
#   - 公開対象の changelog 断片検査（tests/lib/changelog-fragment-guard.sh の changelog_fragment_scan。
#     bundle `#1913` / OBS-099）。suite 名は歴史的経緯で exec-bit のまま（新規 suite を作らず同じ
#     「手順 8 の lib を fixture で固定する」枠へ載せる）
#
# 実行ビット検査:
#   1. staged の新規 tests/<suite>/verify.sh が 100644 → rc=1、パスを名指し
#   2. 同じファイルを 100755 で stage し直す → rc=0、`exec-bit: ok 1`
#   3. staged の新規 hooks/<名>.sh が 100644 → rc=1、パスを名指し / 100755 → rc=0
#   4. commit 済みの verify.sh を 100755 → 100644 へ mode 変更して stage → rc=1
#   5. 違反と適合が混在 → rc=1、違反だけを名指しし適合側を名指ししない
#   6. 対象外（tests/lib/*.sh・suite 配下の fixture の verify.sh・他プラグインの
#      verify.sh）だけが 100644 で staged → rc=0、`exec-bit: none`（ok とは報告しない）
#   7. staged が空 → rc=0、`exec-bit: none`（ok とは報告しない）
#   8. リポジトリではないディレクトリ → rc=2、「実行ビット未検査」
#   9. git diff --cached --raw が失敗する（PATH 先頭の stub）→ rc=2、「実行ビット未検査」
#  10. raw 出力の書式が想定と違う（stub が NUL 区切りでない別書式を返す）→ rc=2、「実行ビット未検査」
#  11. `"` を含むパスの hooks/*.sh が 100644（git が引用符で囲む形）→ rc=1、生のパスで名指し
#  12. diff.relative=true の設定下でサブディレクトリを REPO に渡す → rc=1（全パスを見る）
#  13. commit 済み symlink の hooks/*.sh を 100644 の通常ファイルへ置換（種別変更 T）→ rc=1
#  14. 未解決の衝突（U）がある → rc=2、「実行ビット未検査」
#  15. git が rc=0 のまま stderr に警告を出す → 判定材料へ混ぜず rc=0（ok 1）
#
# changelog 断片検査（公開対象 = fixture の scripts/sync-dev-toolkit-to-public.sh --list-targets stub。
# 除外集合の真実源 scripts/check-release-required.sh / scripts/release-dev-toolkit.sh は実物を複写）:
#  F1. 公開対象を staged で変更し断片なし → rc=1、先頭パスと件数を名指し / F1c. 2 件なら件数 2
#  F1b. 公開ファイルの削除だけ → rc=1
#  F2. 同じ状態へ断片を stage → rc=0（ok 1）
#  F3. 断片を前の commit で足し、次の commit で公開対象だけを stage → rc=0（merge-base 以降の追加を数える）
#  F4. base に既に在る他 PR の断片だけ → rc=1 / F4b. 既定ブランチが分岐点以降に消費した断片を branch 側の
#      追加と数えない（base = merge-base）/ F4c. base の断片の修正（M）は数えない / F4d. 既定ブランチの先端に在る断片は数えない
#  F5. 公開対象外（docs/・scripts/・他プラグイン）だけ → rc=0、`changelog-fragment: none`
#  F6. --list-targets の 2 本目の prefix（oss/ff-dev-toolkit）だけ → rc=1
#  F7. 公開対象一覧の真実源が無い・非 0・空 → rc=2「断片未検査」
#  F9. origin/HEAD を解決できない: 断片なし → rc=2 / staged の断片あり → rc=0
#  F10. 断片の削除 + 公開 CHANGELOG + 準備対象（リリース準備）→ consumed / CHANGELOG 無しの削除（F10b）・
#       削除なし（F10c / F10e）・準備対象外の公開変更の混入（F10d）→ rc=1
#  F11. changelog.d/README.md・下位ディレクトリの .md は断片として数えない
#  F12. リポジトリ外 → rc=2 / diff.relative=true のサブディレクトリから呼んでも rc=1
#  F13. 公開対象・断片削除（D）・断片追加（A）の各 git diff が失敗する（PATH 先頭の stub）→ rc=2「断片未検査」
#  F14. check-release-required.sh の META_ALLOWLIST だけ・公開 CHANGELOG だけ（footer 追従）→ none /
#       META_ALLOWLIST の真実源が無ければ除外しない（rc=1）
#  L. 配置判定 frag_layout: 真実源 2 本が在る → run / リポジトリ直下に scripts/ も docs/ も無い（公開 checkout）→ skip /
#     scripts/ はあるが真実源が無い・docs/ だけ・真実源が 1 本欠け → broken（F0 で赤。skip へ倒さない）。Issue `#1938`
#  F-ran. リポジトリ直下に scripts/ が在るのに F 系を最後まで実行しなかった回は赤
#
# 空振り検出: staged に対象が 1 件も無い入力（検査 6・7）を与えると ok ではなく none を返し、判定材料の取得失敗・リポジトリ外・NUL 区切りでない出力・未解決の衝突（検査 8・9・10・14）を与えると rc=2 の「実行ビット未検査」になる（none の緑へ倒さない）。none を ok 0 と報告する変異で (6)(7) が、NUL で終端しない断片を読み飛ばす変異で (10) が赤になる。
# 変異検出: 対象判定から verify.sh のパターンを外すと (1)(2)(4)(12)(15) が赤になる。
# 変異検出: 対象判定から hooks のパターンを外すと (3a)(3b)(5)(11)(13) が赤になる。
# 変異検出: 100755 との比較を常に適合へ倒すと (1)(3a)(4)(5)(11)(12)(13) が赤になる。
# 変異検出: git diff の失敗を `|| true` で握り潰すと (9) が赤になる（理由文まで照合する）。
# 変異検出: rev-parse の前段確認を消すと (8) が赤になる（git diff 側の失敗でも rc=2 には倒れるので、理由文まで照合する）。
# 変異検出: -z を外すと (1)〜(6)(11)〜(15) が赤になる。--no-relative を外すと (12) が、--diff-filter から T を外すと (13) が、U を外すと (14) が、stderr を判定材料へ合流させる（2>&1）と (15) が赤になる。
# 変異検出: NUL で終端しない末尾の断片を拾う `|| [ -n "$meta" ]` を外すと (10) が赤になる。
# 空振り検出: changelog 断片検査は、staged に数える公開対象が無い入力（F5・F14a・F14b）で ok ではなく none を返し、公開対象一覧の真実源が無い・非 0・空（F7）、比較 base を解決できず断片も無い（F9a）、リポジトリ外（F12a）、各 git diff の失敗（F13 / F13-D / F13-A）では rc=2 の「断片未検査」になる（none の緑へも違反の赤へも倒さない）。none を ok 0 と報告する変異で (F5)(F14a)(F14b) が、空一覧を none へ倒す変異で (F7-empty) が、base 不明を違反へ倒す変異で (F9a) が赤になる（2026-09-28 実測）。
# 変異検出: 比較 base を外す（staged の追加だけ）と (F3) が、base を既定ブランチの先端（rev-parse）にすると (F4b) が、先端に在る断片の除外を外すと (F4d) が、README.md の除外・下位ディレクトリの除外を外すと (F11) が赤になる。--diff-filter=A を AM にしても先端除外が既存断片を落とすので F4c は緑のまま（F13-A の stub 照合だけが赤）。
# 変異検出: 3 本の git diff の失敗をそれぞれ `|| true` で握り潰すと (F13)(F13-D)(F13-A) が、--list-targets の先頭 prefix だけを使うと (F6)(F10a)(F14c) が、公開パスの --diff-filter から D を外すと (F1b) が、件数を 1 に固定すると (F1c) が赤になる。
# 変異検出: consumed の条件から公開 CHANGELOG を外すと (F10b) が、断片削除 1 件以上を外すと (F10e) が、準備対象外の混入を許すと (F10d) が、META_ALLOWLIST の除外を無効にすると (F14a) が、公開 CHANGELOG を数える側へ戻すと (F10a)(F10c)(F14b) が赤になる。
# 空振り検出: 公開 checkout（リポジトリ直下の scripts/ も docs/ も無い。公開同期は plugins/ff-dev-toolkit 配下だけ）では F 系をインデント付き ○ skip で飛ばし exec-bit 節と L は実行する。scripts/ が在るのに skip する変異（実呼び出しを常に skip）で (F-ran) が、scripts/ を見ず docs/ だけで skip を判定する変異で (L-layout-run)(L-layout-nodocs-scripts)(L-layout-partial) が、broken を skip へ倒す変異で (L-layout-nodocs-scripts)(L-layout-docs-only)(L-layout-partial) が赤になる（2026-09-28 実測。Issue `#1938`）。
# 変異検出: リポジトリルートの解決をやめ REPO をそのまま使うと (F12b) が赤になる。--no-relative は root へ -C する実装では冗長な防御で、外しても赤にならない（針はルート解決側の F12b が持つ）。
#
# 一時領域と git が無い環境では skip せず赤で止める（本 suite の検出力は fixture にしか無い）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../lib/git-fixture.sh
. "$TESTS_DIR/lib/git-fixture.sh"
# shellcheck source=../lib/exec-bit-guard.sh
. "$TESTS_DIR/lib/exec-bit-guard.sh"
# shellcheck source=../lib/changelog-fragment-guard.sh
. "$TESTS_DIR/lib/changelog-fragment-guard.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

REAL_GIT="$(command -v git 2>/dev/null || true)"
if [ -z "$REAL_GIT" ]; then
  echo "✗ precommit-exec-bit: git が見つかりません（fixture を作れないので判定できません）" >&2
  exit 1
fi
if _mktemp_out="$(mktemp -d 2>&1)" && [ -d "$_mktemp_out" ]; then
  TMP="$_mktemp_out"
else
  echo "✗ precommit-exec-bit: 一時ディレクトリを作成できません: ${_mktemp_out}" >&2
  exit 1
fi
# 途中死を沈黙させない。`set -u` 等で死んだとき、トラップ突入時の $? は 0 になるため、
# 「rc=0 なのに最後まで到達していない」を中断として扱う（素の rm -rf トラップは
# 途中死を rc=0 に上書きする。run-all/verify.sh case 12）。
FF_REACHED_END=0
_exit_guard() {
  _rc=$?
  rm -rf "$TMP"
  if [ "$_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ precommit-exec-bit: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_rc"
}
trap _exit_guard EXIT

echo "== /pre-commit-check 実行ビット検査（exec_bit_scan） =="

# run_scan <repo> → OUT / ERR / RC を設定する（set -e 下でも非 0 を受ける）
run_scan() {
  RC=0
  OUT="$(exec_bit_scan "$1" 2>"$TMP/err")" || RC=$?
  ERR="$(cat "$TMP/err")"
}

# new_repo <name> → 初期 commit 済みの fixture を作ってパスを返す
new_repo() {
  local dir="$TMP/$1"
  ff_git_fixture_init "$dir" >/dev/null || { echo "✗ fixture を初期化できません: $dir" >&2; exit 1; }
  : > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" commit -q -m init
  printf '%s' "$dir"
}

SUITE_PATH='plugins/ff-dev-toolkit/tests/newsuite/verify.sh'
HOOK_PATH='plugins/ff-dev-toolkit/hooks/new-hook.sh'

# ---- 1 / 2 -------------------------------------------------------------------
R="$(new_repo r1)"
mkdir -p "$R/plugins/ff-dev-toolkit/tests/newsuite"
printf '#!/usr/bin/env bash\n' > "$R/$SUITE_PATH"
chmod 644 "$R/$SUITE_PATH"
git -C "$R" add "$SUITE_PATH"
run_scan "$R"
if [ "$RC" -eq 1 ] && [ "$OUT" = "${SUITE_PATH}: 100644（実行ビットなし）" ]; then
  ok "1. 新規 verify.sh が 100644 なら rc=1 でパスを名指しする"
else
  bad "1. 新規 verify.sh 100644 の判定が違います（rc=${RC} / out=${OUT} / err=${ERR}）"
fi
chmod 755 "$R/$SUITE_PATH"
git -C "$R" add "$SUITE_PATH"
run_scan "$R"
if [ "$RC" -eq 0 ] && [ "$OUT" = "exec-bit: ok 1" ]; then
  ok "2. 同じファイルを 100755 で stage し直すと rc=0（ok 1）"
else
  bad "2. 100755 の判定が違います（rc=${RC} / out=${OUT} / err=${ERR}）"
fi

# ---- 3 -----------------------------------------------------------------------
R="$(new_repo r3)"
mkdir -p "$R/plugins/ff-dev-toolkit/hooks"
printf '#!/usr/bin/env bash\n' > "$R/$HOOK_PATH"
chmod 644 "$R/$HOOK_PATH"
git -C "$R" add "$HOOK_PATH"
run_scan "$R"
if [ "$RC" -eq 1 ] && [ "$OUT" = "${HOOK_PATH}: 100644（実行ビットなし）" ]; then
  ok "3a. 新規 hooks/*.sh が 100644 なら rc=1 でパスを名指しする"
else
  bad "3a. 新規 hook 100644 の判定が違います（rc=${RC} / out=${OUT} / err=${ERR}）"
fi
chmod 755 "$R/$HOOK_PATH"
git -C "$R" add "$HOOK_PATH"
run_scan "$R"
if [ "$RC" -eq 0 ] && [ "$OUT" = "exec-bit: ok 1" ]; then
  ok "3b. hooks/*.sh が 100755 なら rc=0"
else
  bad "3b. hook 100755 の判定が違います（rc=${RC} / out=${OUT} / err=${ERR}）"
fi

# ---- 4 -----------------------------------------------------------------------
R="$(new_repo r4)"
mkdir -p "$R/plugins/ff-dev-toolkit/tests/newsuite"
printf '#!/usr/bin/env bash\n' > "$R/$SUITE_PATH"
chmod 755 "$R/$SUITE_PATH"
git -C "$R" add "$SUITE_PATH"
git -C "$R" commit -q -m add-suite
git -C "$R" update-index --chmod=-x "$SUITE_PATH"
run_scan "$R"
if [ "$RC" -eq 1 ] && [ "$OUT" = "${SUITE_PATH}: 100644（実行ビットなし）" ]; then
  ok "4. 100755 → 100644 の mode 変更（中身は同じ）も rc=1 で名指しする"
else
  bad "4. mode 変更の判定が違います（rc=${RC} / out=${OUT} / err=${ERR}）"
fi

# ---- 5 -----------------------------------------------------------------------
R="$(new_repo r5)"
mkdir -p "$R/plugins/ff-dev-toolkit/tests/newsuite" "$R/plugins/ff-dev-toolkit/hooks"
printf '#!/usr/bin/env bash\n' > "$R/$SUITE_PATH"
printf '#!/usr/bin/env bash\n' > "$R/$HOOK_PATH"
chmod 755 "$R/$SUITE_PATH"
chmod 644 "$R/$HOOK_PATH"
git -C "$R" add "$SUITE_PATH" "$HOOK_PATH"
run_scan "$R"
if [ "$RC" -eq 1 ] && [ "$OUT" = "${HOOK_PATH}: 100644（実行ビットなし）" ]; then
  ok "5. 違反と適合が混在すると rc=1 で違反だけを名指しする"
else
  bad "5. 混在の判定が違います（rc=${RC} / out=${OUT} / err=${ERR}）"
fi

# ---- 6 -----------------------------------------------------------------------
R="$(new_repo r6)"
for p in plugins/ff-dev-toolkit/tests/lib/helper.sh \
         plugins/ff-dev-toolkit/tests/run-all/fixtures/not-executable/verify.sh \
         plugins/other-plugin/tests/somesuite/verify.sh; do
  mkdir -p "$R/$(dirname "$p")"
  printf '#!/usr/bin/env bash\n' > "$R/$p"
  chmod 644 "$R/$p"
  git -C "$R" add "$p"
done
run_scan "$R"
if [ "$RC" -eq 0 ] && [ "$OUT" = "exec-bit: none" ]; then
  ok "6. 対象外（tests/lib・suite 配下の fixture・他プラグイン）だけなら none（ok とは報告しない）"
else
  bad "6. 対象外だけの判定が違います（rc=${RC} / out=${OUT} / err=${ERR}）"
fi

# ---- 7 -----------------------------------------------------------------------
R="$(new_repo r7)"
run_scan "$R"
if [ "$RC" -eq 0 ] && [ "$OUT" = "exec-bit: none" ]; then
  ok "7. staged が空なら none（ok とは報告しない）"
else
  bad "7. staged 空の判定が違います（rc=${RC} / out=${OUT} / err=${ERR}）"
fi

# ---- 8 -----------------------------------------------------------------------
mkdir -p "$TMP/not-a-repo"
# 上位ディレクトリの .git を拾わないよう、探索の天井を一時領域に置く
RC=0
OUT="$(GIT_CEILING_DIRECTORIES="$TMP" exec_bit_scan "$TMP/not-a-repo" 2>"$TMP/err")" || RC=$?
ERR="$(cat "$TMP/err")"
case "$ERR" in
  *"実行ビット未検査: git リポジトリとして読めません"*) err_hit=1 ;;
  *) err_hit=0 ;;
esac
if [ "$RC" -eq 2 ] && [ "$err_hit" -eq 1 ] && [ -z "$OUT" ]; then
  ok "8. リポジトリでなければ rc=2 で「実行ビット未検査」と明示する"
else
  bad "8. リポジトリ外の判定が違います（rc=${RC} / out=${OUT} / err=${ERR}）"
fi

# ---- 9 / 10: PATH 先頭の git stub ----------------------------------------------
# stub は diff だけを差し替え、それ以外は解決済みの実 git へ委譲する（PATH から stub を
# 外した絶対パスなので自分自身へ再帰しない）。
write_stub() { # <dir> <mode: fail|garbage>
  mkdir -p "$1"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'for a in "$@"; do\n'
    printf '  if [ "$a" = diff ]; then\n'
    if [ "$2" = fail ]; then
      printf '    echo "fatal: index file corrupt" >&2; exit 128\n'
    else
      printf '    printf "%%s\\n" "A\tplugins/ff-dev-toolkit/tests/newsuite/verify.sh"; exit 0\n'
    fi
    printf '  fi\n'
    printf 'done\n'
    printf 'exec "%s" "$@"\n' "$REAL_GIT"
  } > "$1/git"
  chmod 755 "$1/git"
}

R="$(new_repo r9)"
mkdir -p "$R/plugins/ff-dev-toolkit/tests/newsuite"
printf '#!/usr/bin/env bash\n' > "$R/$SUITE_PATH"
chmod 755 "$R/$SUITE_PATH"
git -C "$R" add "$SUITE_PATH"

write_stub "$TMP/stub-fail" fail
RC=0
OUT="$(PATH="$TMP/stub-fail:$PATH" exec_bit_scan "$R" 2>"$TMP/err")" || RC=$?
ERR="$(cat "$TMP/err")"
case "$ERR" in
  *"実行ビット未検査: git diff --cached --raw が失敗しました"*) err_hit=1 ;;
  *) err_hit=0 ;;
esac
if [ "$RC" -eq 2 ] && [ "$err_hit" -eq 1 ] && [ -z "$OUT" ]; then
  ok "9. git diff --cached --raw が失敗したら rc=2 で「実行ビット未検査」と明示する"
else
  bad "9. 判定材料の取得失敗の扱いが違います（rc=${RC} / out=${OUT} / err=${ERR}）"
fi

write_stub "$TMP/stub-garbage" garbage
RC=0
OUT="$(PATH="$TMP/stub-garbage:$PATH" exec_bit_scan "$R" 2>"$TMP/err")" || RC=$?
ERR="$(cat "$TMP/err")"
case "$ERR" in
  *"実行ビット未検査: git diff --cached --raw の出力を読めません"*) err_hit=1 ;;
  *) err_hit=0 ;;
esac
if [ "$RC" -eq 2 ] && [ "$err_hit" -eq 1 ]; then
  ok "10. raw 出力の書式が想定と違えば rc=2 で「実行ビット未検査」と明示する（none の緑へ倒さない）"
else
  bad "10. 書式変更の扱いが違います（rc=${RC} / out=${OUT} / err=${ERR}）"
fi

# ---- 11: 引用符で囲まれるパス -----------------------------------------------------
R="$(new_repo r11)"
QPATH='plugins/ff-dev-toolkit/hooks/a"b.sh'
mkdir -p "$R/plugins/ff-dev-toolkit/hooks"
printf '#!/usr/bin/env bash\n' > "$R/$QPATH"
chmod 644 "$R/$QPATH"
git -C "$R" add "$QPATH"
run_scan "$R"
if [ "$RC" -eq 1 ] && [ "$OUT" = "${QPATH}: 100644（実行ビットなし）" ]; then
  ok "11. \" を含むパス（git が引用符で囲む形）も生のパスで名指しする"
else
  bad "11. 引用符パスの判定が違います（rc=${RC} / out=${OUT} / err=${ERR}）"
fi

# ---- 12: diff.relative=true + サブディレクトリ ----------------------------------------
R="$(new_repo r12)"
mkdir -p "$R/plugins/ff-dev-toolkit/tests/newsuite" "$R/docs"
printf '#!/usr/bin/env bash\n' > "$R/$SUITE_PATH"
chmod 644 "$R/$SUITE_PATH"
git -C "$R" add "$SUITE_PATH"
git -C "$R" config --local diff.relative true
run_scan "$R/docs"
if [ "$RC" -eq 1 ] && [ "$OUT" = "${SUITE_PATH}: 100644（実行ビットなし）" ]; then
  ok "12. diff.relative=true でサブディレクトリから呼んでも全パスを見る"
else
  bad "12. diff.relative 下の判定が違います（rc=${RC} / out=${OUT} / err=${ERR}）"
fi

# ---- 13: 種別変更（symlink → 通常ファイル）----------------------------------------
R="$(new_repo r13)"
mkdir -p "$R/plugins/ff-dev-toolkit/hooks"
ln -s ../../../README.md "$R/$HOOK_PATH"
git -C "$R" add "$HOOK_PATH"
git -C "$R" commit -q -m add-link
rm "$R/$HOOK_PATH"
printf '#!/usr/bin/env bash\n' > "$R/$HOOK_PATH"
chmod 644 "$R/$HOOK_PATH"
git -C "$R" add "$HOOK_PATH"
run_scan "$R"
if [ "$RC" -eq 1 ] && [ "$OUT" = "${HOOK_PATH}: 100644（実行ビットなし）" ]; then
  ok "13. symlink を 100644 の通常ファイルへ置換した種別変更（T）も名指しする"
else
  bad "13. 種別変更の判定が違います（rc=${RC} / out=${OUT} / err=${ERR}）"
fi

# ---- 14: 未解決の衝突 ---------------------------------------------------------------
R="$(new_repo r14)"
base_branch="$(git -C "$R" symbolic-ref --short HEAD)"
printf 'a\n' > "$R/conflict.txt"
git -C "$R" add conflict.txt
git -C "$R" commit -q -m base
git -C "$R" checkout -q -b side
printf 'side\n' > "$R/conflict.txt"
git -C "$R" commit -q -am side
git -C "$R" checkout -q "$base_branch"
printf 'main\n' > "$R/conflict.txt"
git -C "$R" commit -q -am main
git -C "$R" merge -q side >/dev/null 2>&1 || true
RC=0
OUT="$(exec_bit_scan "$R" 2>"$TMP/err")" || RC=$?
ERR="$(cat "$TMP/err")"
case "$ERR" in
  *"実行ビット未検査: 未解決の衝突があります"*) err_hit=1 ;;
  *) err_hit=0 ;;
esac
if [ "$RC" -eq 2 ] && [ "$err_hit" -eq 1 ] && [ -z "$OUT" ]; then
  ok "14. 未解決の衝突があれば rc=2 で「実行ビット未検査」と明示する"
else
  bad "14. 衝突時の判定が違います（rc=${RC} / out=${OUT} / err=${ERR}）"
fi

# ---- 15: rc=0 の stderr 警告 ------------------------------------------------------------
mkdir -p "$TMP/stub-warn"
{
  printf '#!/usr/bin/env bash\n'
  printf 'for a in "$@"; do\n'
  printf '  if [ "$a" = diff ]; then echo "warning: exhaustive rename detection was skipped" >&2; fi\n'
  printf 'done\n'
  printf 'exec "%s" "$@"\n' "$REAL_GIT"
} > "$TMP/stub-warn/git"
chmod 755 "$TMP/stub-warn/git"
R="$(new_repo r15)"
mkdir -p "$R/plugins/ff-dev-toolkit/tests/newsuite"
printf '#!/usr/bin/env bash\n' > "$R/$SUITE_PATH"
chmod 755 "$R/$SUITE_PATH"
git -C "$R" add "$SUITE_PATH"
RC=0
OUT="$(PATH="$TMP/stub-warn:$PATH" exec_bit_scan "$R" 2>"$TMP/err")" || RC=$?
ERR="$(cat "$TMP/err")"
if [ "$RC" -eq 0 ] && [ "$OUT" = "exec-bit: ok 1" ]; then
  ok "15. git が rc=0 のまま stderr に出した警告を判定材料へ混ぜない"
else
  bad "15. stderr 警告の扱いが違います（rc=${RC} / out=${OUT} / err=${ERR}）"
fi

# =============================================================================
# 公開対象の changelog 断片（tests/lib/changelog-fragment-guard.sh の changelog_fragment_scan。
# bundle `#1913` / OBS-099）
# =============================================================================
echo
echo "== /pre-commit-check 公開対象の changelog 断片（changelog_fragment_scan） =="

run_frag() {
  RC=0
  OUT="$(changelog_fragment_scan "$1" 2>"$TMP/err")" || RC=$?
  ERR="$(cat "$TMP/err")"
}

# new_pub_repo <name> [targets-mode: ok|fail|empty|absent]
# 公開対象一覧の真実源（scripts/sync-dev-toolkit-to-public.sh --list-targets）を stub で置き、
# origin/HEAD → origin/develop を init commit に向けた fixture を作る（ネットワーク不要）。
new_pub_repo() {
  local dir mode="${2:-ok}"
  dir="$(new_repo "$1")"
  mkdir -p "$dir/scripts" "$dir/changelog.d"
  case "$mode" in
    ok)    printf '#!/usr/bin/env bash\n[ "$1" = --list-targets ] || exit 2\nprintf "%%s\\n" plugins/ff-dev-toolkit oss/ff-dev-toolkit\n' > "$dir/scripts/sync-dev-toolkit-to-public.sh" ;;
    fail)  printf '#!/usr/bin/env bash\nexit 3\n' > "$dir/scripts/sync-dev-toolkit-to-public.sh" ;;
    empty) printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/scripts/sync-dev-toolkit-to-public.sh" ;;
    absent) ;;
  esac
  printf '# fragments\n' > "$dir/changelog.d/README.md"
  # 除外集合の真実源（META_ALLOWLIST / CHANGELOG= / PLUGIN_JSON= / AGENT_CONFIG=）は実物を置く。
  # lib は awk で読むだけで実行しないので、実物の書式が変われば fixture の判定がそのまま赤になる。
  cp "$REPO_SCRIPTS/check-release-required.sh" "$REPO_SCRIPTS/release-dev-toolkit.sh" "$dir/scripts/"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m scaffold
  git -C "$dir" update-ref refs/remotes/origin/develop HEAD
  git -C "$dir" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop
  printf '%s' "$dir"
}

# 除外集合の真実源（scripts/check-release-required.sh / scripts/release-dev-toolkit.sh）は SSOT 限定。
# 公開リポジトリ feel-flow/ff-dev-toolkit へは plugins/ff-dev-toolkit 配下だけが同期され、リポジトリ
# 直下の scripts/ も docs/ も無い（Issue `#1938`。v0.137.0 リリースの gate 段 public-layout で検出）。
# frag_layout <repo-root> → run（両方在る）/ skip（scripts/ も docs/ も無い公開 checkout）/
# broken（開発元の配置なのに真実源が欠けている。skip へ倒さず赤にする）
FRAG_SSOT_SRCS='check-release-required.sh release-dev-toolkit.sh'
frag_layout() {
  local root="$1" f
  if [ ! -d "$root/scripts" ] && [ ! -d "$root/docs" ]; then
    printf 'skip'
    return 0
  fi
  for f in $FRAG_SSOT_SRCS; do
    [ -f "$root/scripts/$f" ] || { printf 'broken'; return 0; }
  done
  printf 'run'
}

# ---- L: 配置判定（frag_layout）を fixture で固定する ------------------------------------------
mkdir -p "$TMP/layout-run/scripts" "$TMP/layout-pub/plugins" "$TMP/layout-nodocs-scripts/scripts" "$TMP/layout-docs-only/docs" "$TMP/layout-partial/scripts"
for f in $FRAG_SSOT_SRCS; do : > "$TMP/layout-run/scripts/$f"; done
: > "$TMP/layout-partial/scripts/check-release-required.sh"
for pair in "run:layout-run" "skip:layout-pub" "broken:layout-nodocs-scripts" "broken:layout-docs-only" "broken:layout-partial"; do
  want="${pair%%:*}"; name="${pair#*:}"
  got="$(frag_layout "$TMP/$name")"
  if [ "$got" = "$want" ]; then
    ok "L-${name}. 配置判定は ${want}"
  else
    bad "L-${name}. 配置判定が違います（want=${want} / got=${got}）"
  fi
done

FRAG_REPO_ROOT="$(cd "$TESTS_DIR/../../.." && pwd)"
REPO_SCRIPTS="$FRAG_REPO_ROOT/scripts"
FRAG_LAYOUT="$(frag_layout "$FRAG_REPO_ROOT")"
FRAG_RAN=0
case "$FRAG_LAYOUT" in
  skip)
    echo "  ○ skip: リポジトリ直下の scripts/ が無い公開 checkout のため changelog 断片検査（F 系）をスキップ（除外集合の真実源 scripts/check-release-required.sh / scripts/release-dev-toolkit.sh は SSOT 限定。この節の検査は 1 件も実行していません）" ;;
  broken)
    bad "F0. 開発元の配置なのに除外集合の真実源（${FRAG_SSOT_SRCS}）が ${REPO_SCRIPTS} に揃っていません（skip へ倒さない）" ;;
esac

if [ "$FRAG_LAYOUT" = run ]; then
PUB_PATH='plugins/ff-dev-toolkit/skills/x/SKILL.md'
FRAG_PATH='changelog.d/1913.fixed.sample.md'

stage_file() { # <repo> <path>
  mkdir -p "$1/$(dirname "$2")"
  printf 'x\n' >> "$1/$2"
  git -C "$1" add "$2"
}

# ---- F1: 公開対象の変更 + 断片なし → rc=1 ------------------------------------------------
R="$(new_pub_repo f1)"
stage_file "$R" "$PUB_PATH"
run_frag "$R"
if [ "$RC" -eq 1 ] && [ "$OUT" = "公開対象を変更したのに changelog.d/ 断片がありません: ${PUB_PATH}（公開対象 1 件）" ]; then
  ok "F1. 公開対象を変更し断片が無ければ rc=1 で先頭パスを名指しする"
else
  bad "F1. 断片欠落の判定が違います（rc=${RC} / out=${OUT} / err=${ERR}）"
fi

stage_file "$R" 'plugins/ff-dev-toolkit/scripts/y.sh'
run_frag "$R"
if [ "$RC" -eq 1 ] && [ "$OUT" = "公開対象を変更したのに changelog.d/ 断片がありません: plugins/ff-dev-toolkit/scripts/y.sh（公開対象 2 件）" ]; then
  ok "F1c. 公開対象 2 件なら件数を 2 と報告する（先頭は git の並び順）"
else
  bad "F1c. 件数の報告が違います（rc=${RC} / out=${OUT} / err=${ERR}）"
fi

# ---- F1b: 公開ファイルの削除だけでも公開面の変更として数える ----------------------------------------
R1B="$(new_pub_repo f1b)"
stage_file "$R1B" "$PUB_PATH"
git -C "$R1B" commit -q -m add-pub
git -C "$R1B" update-ref refs/remotes/origin/develop HEAD
git -C "$R1B" rm -q "$PUB_PATH"
run_frag "$R1B"
if [ "$RC" -eq 1 ] && [ "$OUT" = "公開対象を変更したのに changelog.d/ 断片がありません: ${PUB_PATH}（公開対象 1 件）" ]; then
  ok "F1b. 公開ファイルの削除だけでも rc=1（削除も公開面の変更）"
else
  bad "F1b. 公開ファイル削除の判定が違います（rc=${RC} / out=${OUT} / err=${ERR}）"
fi

# ---- F2: 同じ変更 + staged の断片 → ok ----------------------------------------------------
stage_file "$R" "$FRAG_PATH"
run_frag "$R"
if [ "$RC" -eq 0 ] && [ "$OUT" = "changelog-fragment: ok 1" ]; then
  ok "F2. 断片を staged に足すと rc=0（ok 1）"
else
  bad "F2. 断片ありの判定が違います（rc=${RC} / out=${OUT} / err=${ERR}）"
fi

# ---- F3: 同じ PR の前の commit で足した断片も数える --------------------------------------------
git -C "$R" commit -q -m first
stage_file "$R" "$PUB_PATH"
run_frag "$R"
if [ "$RC" -eq 0 ] && [ "$OUT" = "changelog-fragment: ok 1" ]; then
  ok "F3. 前の commit で足した断片（merge-base 以降の追加）も数え、2 コミット目を赤にしない"
else
  bad "F3. branch 上の断片の扱いが違います（rc=${RC} / out=${OUT} / err=${ERR}）"
fi

# ---- F4: base に既に在る断片（他 PR の未消費断片）は数えない -------------------------------------
R="$(new_pub_repo f4)"
stage_file "$R" 'changelog.d/1.fixed.other-pr.md'
git -C "$R" commit -q -m other-pr
git -C "$R" update-ref refs/remotes/origin/develop HEAD
stage_file "$R" "$PUB_PATH"
run_frag "$R"
if [ "$RC" -eq 1 ]; then
  ok "F4. base に既に在る他 PR の断片は数えない（rc=1）"
else
  bad "F4. base 側の断片の扱いが違います（rc=${RC} / out=${OUT} / err=${ERR}）"
fi

# ---- F4b: 比較 base は既定ブランチの先端ではなく merge-base -------------------------------------------
# 分岐点に在った断片を既定ブランチが後から消費（削除）しても、branch 側の古い断片を「追加」と数えない
R="$(new_pub_repo f4b)"
stage_file "$R" 'changelog.d/1.fixed.old.md'
git -C "$R" commit -q -m old-fragment
git -C "$R" update-ref refs/remotes/origin/develop HEAD
git -C "$R" checkout -q -b feature
git -C "$R" checkout -q --detach refs/remotes/origin/develop
git -C "$R" rm -q changelog.d/1.fixed.old.md
git -C "$R" commit -q -m consume
git -C "$R" update-ref refs/remotes/origin/develop HEAD
git -C "$R" checkout -q feature
stage_file "$R" "$PUB_PATH"
run_frag "$R"
if [ "$RC" -eq 1 ]; then
  ok "F4b. 既定ブランチが分岐点以降に消費した断片を branch 側の追加と数えない（base = merge-base）"
else
  bad "F4b. 比較 base の取り方が違います（rc=${RC} / out=${OUT} / err=${ERR}）"
fi

# ---- F4c: base に在る他 PR の断片を修正（M）しても数えない ------------------------------------------
R="$(new_pub_repo f4c)"
stage_file "$R" 'changelog.d/1.fixed.other-pr.md'
git -C "$R" commit -q -m other-pr
git -C "$R" update-ref refs/remotes/origin/develop HEAD
stage_file "$R" 'changelog.d/1.fixed.other-pr.md'
stage_file "$R" "$PUB_PATH"
run_frag "$R"
if [ "$RC" -eq 1 ]; then
  ok "F4c. base に在る他 PR の断片の修正（M）は自分の断片として数えない"
else
  bad "F4c. 既存断片の修正の扱いが違います（rc=${RC} / out=${OUT} / err=${ERR}）"
fi

# ---- F4d: 既定ブランチの先端に在る断片は数えない（cherry-pick 等で同じ断片を持つ回）----------------------
R="$(new_pub_repo f4d)"
git -C "$R" checkout -q -b feature
git -C "$R" checkout -q --detach refs/remotes/origin/develop
stage_file "$R" 'changelog.d/1.fixed.landed.md'
git -C "$R" commit -q -m landed
git -C "$R" update-ref refs/remotes/origin/develop HEAD
git -C "$R" checkout -q feature
stage_file "$R" 'changelog.d/1.fixed.landed.md'
stage_file "$R" "$PUB_PATH"
run_frag "$R"
if [ "$RC" -eq 1 ]; then
  ok "F4d. 既定ブランチの先端に既に在る断片は他 PR のものとして数えない"
else
  bad "F4d. 先端に在る断片の扱いが違います（rc=${RC} / out=${OUT} / err=${ERR}）"
fi

# ---- F5: 公開対象外だけ → none --------------------------------------------------------------
R="$(new_pub_repo f5)"
stage_file "$R" 'docs/foo.md'
stage_file "$R" 'scripts/other.sh'
stage_file "$R" 'plugins/other-plugin/skills/y/SKILL.md'
run_frag "$R"
if [ "$RC" -eq 0 ] && [ "$OUT" = "changelog-fragment: none" ]; then
  ok "F5. staged に公開対象が無ければ none（ok とは報告しない）"
else
  bad "F5. 公開対象外だけの判定が違います（rc=${RC} / out=${OUT} / err=${ERR}）"
fi

# ---- F6: 一覧の 2 本目の prefix（oss/ff-dev-toolkit）も公開対象として数える ---------------------------
R="$(new_pub_repo f6)"
stage_file "$R" 'oss/ff-dev-toolkit/docs/guide.md'
run_frag "$R"
if [ "$RC" -eq 1 ] && [ "$OUT" = "公開対象を変更したのに changelog.d/ 断片がありません: oss/ff-dev-toolkit/docs/guide.md（公開対象 1 件）" ]; then
  ok "F6. --list-targets の 2 本目の prefix も公開対象として数える（手書き一覧を持たない）"
else
  bad "F6. 2 本目の prefix の判定が違います（rc=${RC} / out=${OUT} / err=${ERR}）"
fi

# ---- F7: 公開対象一覧の真実源が無い・失敗・空 → rc=2 ------------------------------------------
for mode in absent fail empty; do
  R="$(new_pub_repo "f7-${mode}" "$mode")"
  stage_file "$R" "$PUB_PATH"
  run_frag "$R"
  case "$ERR" in
    *"断片未検査: "*) err_hit=1 ;;
    *) err_hit=0 ;;
  esac
  if [ "$RC" -eq 2 ] && [ "$err_hit" -eq 1 ] && [ -z "$OUT" ]; then
    ok "F7-${mode}. 公開対象一覧を取れない回（${mode}）は rc=2 で「断片未検査」と明示する"
  else
    bad "F7-${mode}. 公開対象一覧の取得不能の扱いが違います（rc=${RC} / out=${OUT} / err=${ERR}）"
  fi
done

# ---- F9: 比較 base を解決できない ------------------------------------------------------------
R="$(new_pub_repo f9)"
git -C "$R" symbolic-ref --delete refs/remotes/origin/HEAD
stage_file "$R" "$PUB_PATH"
run_frag "$R"
case "$ERR" in
  *"断片未検査: origin/HEAD を解決できず比較 base が無く"*) err_hit=1 ;;
  *) err_hit=0 ;;
esac
if [ "$RC" -eq 2 ] && [ "$err_hit" -eq 1 ] && [ -z "$OUT" ]; then
  ok "F9a. 比較 base を解決できず staged にも断片が無ければ rc=2（違反と言い切らない）"
else
  bad "F9a. base 不明の扱いが違います（rc=${RC} / out=${OUT} / err=${ERR}）"
fi
stage_file "$R" "$FRAG_PATH"
run_frag "$R"
if [ "$RC" -eq 0 ] && [ "$OUT" = "changelog-fragment: ok 1" ]; then
  ok "F9b. 比較 base が無くても staged の断片は数える"
else
  bad "F9b. base 不明時の staged 断片の扱いが違います（rc=${RC} / out=${OUT} / err=${ERR}）"
fi

# ---- F10: リリース準備（断片の消費）------------------------------------------------------------
R="$(new_pub_repo f10)"
stage_file "$R" "$FRAG_PATH"
git -C "$R" commit -q -m add-fragment
git -C "$R" update-ref refs/remotes/origin/develop HEAD
git -C "$R" rm -q "$FRAG_PATH"
stage_file "$R" 'oss/ff-dev-toolkit/CHANGELOG.md'
stage_file "$R" 'plugins/ff-dev-toolkit/.claude-plugin/plugin.json'
run_frag "$R"
if [ "$RC" -eq 0 ] && [ "$OUT" = "changelog-fragment: consumed 1" ]; then
  ok "F10a. 断片の削除 + 公開 CHANGELOG の更新（リリース準備）は consumed として対象外"
else
  bad "F10a. 断片消費の扱いが違います（rc=${RC} / out=${OUT} / err=${ERR}）"
fi
git -C "$R" reset -q -- oss/ff-dev-toolkit/CHANGELOG.md
run_frag "$R"
if [ "$RC" -eq 1 ]; then
  ok "F10b. 公開 CHANGELOG を伴わない断片削除は消費と扱わない（rc=1）"
else
  bad "F10b. CHANGELOG 無しの断片削除の扱いが違います（rc=${RC} / out=${OUT} / err=${ERR}）"
fi

R="$(new_pub_repo f10c)"
stage_file "$R" 'oss/ff-dev-toolkit/CHANGELOG.md'
stage_file "$R" "$PUB_PATH"
run_frag "$R"
if [ "$RC" -eq 1 ] && [ "$OUT" = "公開対象を変更したのに changelog.d/ 断片がありません: ${PUB_PATH}（公開対象 1 件）" ]; then
  ok "F10c. 断片を削除しない回は公開 CHANGELOG があっても消費と扱わない（rc=1）"
else
  bad "F10c. 断片削除なしの扱いが違います（rc=${RC} / out=${OUT} / err=${ERR}）"
fi
R="$(new_pub_repo f10d)"
stage_file "$R" "$FRAG_PATH"
git -C "$R" commit -q -m add-fragment
git -C "$R" update-ref refs/remotes/origin/develop HEAD
git -C "$R" rm -q "$FRAG_PATH"
stage_file "$R" 'oss/ff-dev-toolkit/CHANGELOG.md'
stage_file "$R" 'plugins/ff-dev-toolkit/.claude-plugin/plugin.json'
stage_file "$R" "$PUB_PATH"
run_frag "$R"
if [ "$RC" -eq 1 ]; then
  ok "F10d. 消費に準備対象外の公開変更が混ざれば消費と扱わない（rc=1）"
else
  bad "F10d. 消費への混入の扱いが違います（rc=${RC} / out=${OUT} / err=${ERR}）"
fi

R="$(new_pub_repo f10e)"
stage_file "$R" 'oss/ff-dev-toolkit/CHANGELOG.md'
stage_file "$R" 'plugins/ff-dev-toolkit/.claude-plugin/plugin.json'
run_frag "$R"
if [ "$RC" -eq 1 ] && [ "$OUT" = "公開対象を変更したのに changelog.d/ 断片がありません: plugins/ff-dev-toolkit/.claude-plugin/plugin.json（公開対象 1 件）" ]; then
  ok "F10e. 断片を 1 件も消費しない準備対象（plugin.json）+ 公開 CHANGELOG は消費と扱わない（rc=1）"
else
  bad "F10e. 消費 0 件の扱いが違います（rc=${RC} / out=${OUT} / err=${ERR}）"
fi

# ---- F14: 同期手順 R が断片を要求しないパス（META_ALLOWLIST・公開 CHANGELOG の footer 追従）--------------
R="$(new_pub_repo f14a)"
stage_file "$R" 'oss/ff-dev-toolkit/README.md'
run_frag "$R"
if [ "$RC" -eq 0 ] && [ "$OUT" = "changelog-fragment: none" ]; then
  ok "F14a. check-release-required.sh の META_ALLOWLIST（公開 README）だけなら none"
else
  bad "F14a. META_ALLOWLIST の扱いが違います（rc=${RC} / out=${OUT} / err=${ERR}）"
fi
R="$(new_pub_repo f14b)"
stage_file "$R" 'oss/ff-dev-toolkit/CHANGELOG.md'
run_frag "$R"
if [ "$RC" -eq 0 ] && [ "$OUT" = "changelog-fragment: none" ]; then
  ok "F14b. 公開 CHANGELOG だけ（footer 追従）なら none"
else
  bad "F14b. 公開 CHANGELOG だけの扱いが違います（rc=${RC} / out=${OUT} / err=${ERR}）"
fi
R="$(new_pub_repo f14c)"
rm "$R/scripts/check-release-required.sh"
git -C "$R" add -A
stage_file "$R" 'oss/ff-dev-toolkit/README.md'
run_frag "$R"
if [ "$RC" -eq 1 ]; then
  ok "F14c. META_ALLOWLIST の真実源を読めなければ除外しない（厳しい側に倒す）"
else
  bad "F14c. 真実源不在の扱いが違います（rc=${RC} / out=${OUT} / err=${ERR}）"
fi

# ---- F11: README.md・下位ディレクトリは断片として数えない ------------------------------------------
R="$(new_pub_repo f11)"
# README.md を base から外し、PR 側で**追加（A）**する形にする（修正 M では数え方の針にならない）
git -C "$R" rm -q changelog.d/README.md
git -C "$R" commit -q -m drop-readme
git -C "$R" update-ref refs/remotes/origin/develop HEAD
stage_file "$R" "$PUB_PATH"
stage_file "$R" 'changelog.d/README.md'
stage_file "$R" 'changelog.d/sub/1913.fixed.nested.md'
run_frag "$R"
if [ "$RC" -eq 1 ]; then
  ok "F11. changelog.d/README.md と下位ディレクトリの .md は断片として数えない"
else
  bad "F11. 断片の数え方が違います（rc=${RC} / out=${OUT} / err=${ERR}）"
fi

# ---- F12: リポジトリ外 / diff.relative 下のサブディレクトリ ------------------------------------------
RC=0
OUT="$(GIT_CEILING_DIRECTORIES="$TMP" changelog_fragment_scan "$TMP/not-a-repo" 2>"$TMP/err")" || RC=$?
ERR="$(cat "$TMP/err")"
case "$ERR" in
  *"断片未検査: git リポジトリとして読めません"*) err_hit=1 ;;
  *) err_hit=0 ;;
esac
if [ "$RC" -eq 2 ] && [ "$err_hit" -eq 1 ] && [ -z "$OUT" ]; then
  ok "F12a. リポジトリでなければ rc=2 で「断片未検査」と明示する"
else
  bad "F12a. リポジトリ外の判定が違います（rc=${RC} / out=${OUT} / err=${ERR}）"
fi
R="$(new_pub_repo f12)"
stage_file "$R" "$PUB_PATH"
mkdir -p "$R/docs"
git -C "$R" config --local diff.relative true
run_frag "$R/docs"
if [ "$RC" -eq 1 ]; then
  ok "F12b. diff.relative=true でサブディレクトリから呼んでも全パスを見る"
else
  bad "F12b. diff.relative 下の判定が違います（rc=${RC} / out=${OUT} / err=${ERR}）"
fi

# ---- F13: git diff が失敗する（PATH 先頭の stub）→ rc=2 ---------------------------------------------
R="$(new_pub_repo f13)"
stage_file "$R" "$PUB_PATH"
RC=0
OUT="$(PATH="$TMP/stub-fail:$PATH" changelog_fragment_scan "$R" 2>"$TMP/err")" || RC=$?
ERR="$(cat "$TMP/err")"
case "$ERR" in
  *"断片未検査: 公開対象の staged パスを取得できません"*) err_hit=1 ;;
  *) err_hit=0 ;;
esac
if [ "$RC" -eq 2 ] && [ "$err_hit" -eq 1 ] && [ -z "$OUT" ]; then
  ok "F13. git diff が失敗したら rc=2 で「断片未検査」と明示する（none の緑へ倒さない）"
else
  bad "F13. 判定材料の取得失敗の扱いが違います（rc=${RC} / out=${OUT} / err=${ERR}）"
fi

# ---- F13b / F13c: 断片削除・断片追加の取得だけが失敗する ------------------------------------------------
write_filter_stub() { # <dir> <失敗させる --diff-filter の値>
  mkdir -p "$1"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'for a in "$@"; do\n'
    printf '  if [ "$a" = "--diff-filter=%s" ]; then echo "fatal: stub" >&2; exit 128; fi\n' "$2"
    printf 'done\n'
    printf 'exec "%s" "$@"\n' "$REAL_GIT"
  } > "$1/git"
  chmod 755 "$1/git"
}
write_filter_stub "$TMP/stub-fail-d" D
write_filter_stub "$TMP/stub-fail-a" A
for pair in "D:staged の断片削除を取得できません:stub-fail-d" "A:追加した断片を取得できません:stub-fail-a"; do
  label="${pair%%:*}"; rest="${pair#*:}"; want="${rest%%:*}"; stub="${rest#*:}"
  RC=0
  OUT="$(PATH="$TMP/${stub}:$PATH" changelog_fragment_scan "$R" 2>"$TMP/err")" || RC=$?
  ERR="$(cat "$TMP/err")"
  case "$ERR" in
    *"断片未検査: ${want}"*) err_hit=1 ;;
    *) err_hit=0 ;;
  esac
  if [ "$RC" -eq 2 ] && [ "$err_hit" -eq 1 ] && [ -z "$OUT" ]; then
    ok "F13-${label}. --diff-filter=${label} の取得失敗も rc=2 で「断片未検査」（断片 0 件の違反へ倒さない）"
  else
    bad "F13-${label}. --diff-filter=${label} の取得失敗の扱いが違います（rc=${RC} / out=${OUT} / err=${ERR}）"
  fi
done
FRAG_RAN=1
fi

# scripts/ が在るのに F 系を最後まで走らせなかった回は赤（skip 条件の取り違えを緑にしない）
if [ -d "$REPO_SCRIPTS" ] && [ "$FRAG_RAN" -ne 1 ]; then
  bad "F-ran. ${REPO_SCRIPTS} が在るのに changelog 断片検査（F 系）が最後まで実行されていません"
fi

echo
echo "precommit-exec-bit: passed=${PASS} failed=${FAIL}"
FF_REACHED_END=1
[ "$FAIL" -eq 0 ]
