#!/usr/bin/env bash
#
# mutation-harness: 変異ハーネス（scripts/mutation-harness.sh）の恒久検査。
#
# 一時ディレクトリの fixture リポジトリ（target.txt と小さな検査スクリプト）に対してハーネスを
# 実際に回し、次を固定する:
#   A. 変異表が空（空・コメントだけ）は exit 2 で止め、写しも suite も作らない
#   B. 対照（変異なしの写し）が赤なら変異を当てずに exit 2
#   C. 判定 5 種（detected / green-ok / SURVIVED / FALSE-POSITIVE / NOT-APPLIED）と要約行、
#      期待外れが 1 件でもあれば exit 1 / 全件期待どおりなら exit 0 / 使い方の誤りは exit 64
#   D. 作業領域: --work-dir 配下の一意な子ディレクトリだけを作って消す（既存の `pristine` /
#      `case-*` に触れない）。--keep はその子を残す
#   E. 写しの境界: 対象・祖先が symlink の変異（replace / create）は NOT-APPLIED で、写しの外
#      （symlink の指す先）を書き換えない
#   F. 対照は専用の写しで回して捨てる（成功しつつファイルを書き換える suite の副作用が変異へ混ざらない）
#   G. 引数の末尾の `\n` を保持する（コマンド置換で落ちると適用前後のハッシュが同じになる）
#   H. plugin root の handoff（FF_DEV_TOOLKIT_ROOT）を写し側へ張り替える（推奨コマンドと同じ環境で、
#      写しの中の root 固定ガード付きスクリプトが止まらず、写しの変異を検査する）
#   I. delete-line は他の行のバイト・末尾改行の有無を保ち、バックスラッシュ入りの目印をそのまま探す
#   J. create は引数 1 をそのまま書く（改行を足さない）
#
# run-all-required: no — git / 一時領域が無い環境の skip を許容する（一時領域依存 suite と同じ扱い）
# 空振り検出: ハーネスの最後の判定（`N_SURV` / `N_FP` / `N_NA` のどれかが 1 件以上なら exit 1）を消して常に exit 0 にする変異を入れると (C) の「期待外れが 1 件でもあれば exit 1」が赤になり、変異表 0 件の停止（2 箇所の `die "変異表に変異が 1 件もありません…"`）を消すと (A)「コメントだけの変異表は exit 2」が赤になる（2026-09-24 実測。空の入力・期待外れを緑へ倒さないことの実測）。
# 変異検出（2026-09-24 実測）: 作業領域・写しの境界・対照・末尾改行を直す前のハーネスへ差し替えると (D) 2 件・(E)・(F)・(G) の 5 件が赤。
# 変異検出（2 巡目の fix。2026-09-24 実測）: handoff の張り替え・delete-line / create のバイト保持を直す前のハーネスへ差し替えると (H)・(I)・(J) の 3 件が赤。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HARNESS="$PLUGIN_ROOT/scripts/mutation-harness.sh"
# shellcheck source=../lib/git-fixture.sh
. "$SCRIPT_DIR/../lib/git-fixture.sh"

[ -f "$HARNESS" ] || { echo "✗ mutation-harness.sh が見つかりません: $HARNESS" >&2; exit 1; }
if ! command -v git >/dev/null 2>&1; then
  echo "○ skip: git が見つからないためスキップ（mutation-harness は未検査のままです）"
  exit 0
fi
# mktemp の stderr は捨てない（失敗の理由を skip 行へ出す）。rc 0 でも -d を確かめる。
if _mh_tmp="$(mktemp -d 2>&1)" && [ -d "$_mh_tmp" ]; then
  TMP="$(cd "$_mh_tmp" && pwd -P)"
else
  echo "○ skip: 一時ディレクトリを作れないためスキップ（mutation-harness は未検査のままです）"
  printf '  mktemp: %s\n' "$_mh_tmp"
  exit 0
fi
# 途中で落ちた回を緑に見せない: 最終行のセンチネルに到達していなければ trap で赤にする。
REACHED_END=0
_mh_cleanup() {
  rm -rf "$TMP"
  if [ "$REACHED_END" -ne 1 ]; then
    echo "✗ mutation-harness: スイートが最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
}
trap _mh_cleanup EXIT

PASS=0
FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# fixture: target.txt（alpha / beta）と、alpha 行があれば緑になる検査
REPO="$TMP/repo"
OUTSIDE="$TMP/outside"
mkdir -p "$OUTSIDE/dir"
printf 'outside\n' > "$OUTSIDE/file.txt"
printf 'outside\n' > "$OUTSIDE/dir/f.txt"
ff_git_fixture_init "$REPO" >/dev/null || { echo "✗ fixture リポジトリを作れません" >&2; exit 1; }
printf 'alpha\nbeta\n' > "$REPO/target.txt"
printf 'other\n' > "$REPO/other.txt"
printf '%s\n' 'grep -q "^alpha$" target.txt' > "$REPO/check.sh"
ln -s "$OUTSIDE/dir" "$REPO/link-dir"
# (H) root 固定ガード付きスクリプトの模型: handoff が自分の plugin root と一致しなければ止まり、
# 検査対象を handoff 経由で読む
mkdir -p "$REPO/plugin/.claude-plugin" "$REPO/plugin/scripts"
printf '{"name": "fixture-plugin", "version": "0.0.0"}\n' > "$REPO/plugin/.claude-plugin/plugin.json"
cat > "$REPO/plugin/scripts/probe.sh" <<'PROBE'
self="$(cd "$(dirname "$0")/.." && pwd -P)"
[ "$(cd "${FF_DEV_TOOLKIT_ROOT:-/nonexistent}" 2>/dev/null && pwd -P)" = "$self" ] || { echo "root mismatch"; exit 3; }
grep -q '^alpha$' "$FF_DEV_TOOLKIT_ROOT/../target.txt"
PROBE
# (I) バックスラッシュ入りの行・目印と、末尾改行の無い最終行
printf 'keep \\ back\nMARK\\x line\nlast-no-newline' > "$REPO/bs.txt"
printf 'keep \\ back\nlast-no-newline' > "$REPO/bs.expected"
ln -s "$OUTSIDE/file.txt" "$REPO/link-file"
git -C "$REPO" add -A >/dev/null 2>&1
git -C "$REPO" -c commit.gpgsign=false commit -q -m fixture >/dev/null 2>&1

WORKP="$TMP/work"
mkdir -p "$WORKP"

run_harness() { # <変異表ファイル> <suite> [追加引数...]
  local table="$1" suite="$2"
  shift 2
  RC=0
  OUT="$(env -u FF_DEV_TOOLKIT_ROOT -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT \
    bash "$HARNESS" --root "$REPO" --table "$table" --suite "$suite" --work-dir "$WORKP" "$@" 2>"$TMP/err")" || RC=$?
  ERR="$(cat "$TMP/err")"
}
T() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$@"; }
leftover() { # 作業領域に残った harness.* の数
  local n=0 d
  for d in "$WORKP"/harness.*; do [ -e "$d" ] && n=$((n + 1)); done
  printf '%s' "$n"
}

echo "mutation-harness: (A) 変異表が空"
printf '# comment only\n\n' > "$TMP/empty.tsv"
run_harness "$TMP/empty.tsv" 'bash check.sh'
case "$ERR" in
  *'変異が 1 件もありません'*) [ "$RC" -eq 2 ] && ok "(A) コメントだけの変異表は exit 2（0 件を全件期待どおりへ倒さない）" || bad "(A) 空の変異表の rc: $RC" ;;
  *) bad "(A) 空の変異表で止まらない: rc=$RC err=[$ERR]" ;;
esac
[ "$(leftover)" = "0" ] && ok "(A) 空の変異表では作業領域を作らない" || bad "(A) 空の変異表で作業領域が残った"

echo "mutation-harness: (B) 対照が赤"
T ok replace target.txt alpha gamma red > "$TMP/one.tsv"
run_harness "$TMP/one.tsv" 'false'
case "$ERR" in
  *'対照'*'赤'*) [ "$RC" -eq 2 ] && ok "(B) 対照が赤なら変異を当てずに exit 2" || bad "(B) 対照赤の rc: $RC" ;;
  *) bad "(B) 対照が赤でも止まらない: rc=$RC err=[$ERR]" ;;
esac

echo "mutation-harness: (C) 判定 5 種・要約行・終了コード"
{
  T detect replace target.txt alpha gamma red
  T miss replace target.txt nope x red
  T survive append other.txt zzz - red
  T falsepos delete-line target.txt alpha - green
  T greenok append other.txt zzz - green
} > "$TMP/mixed.tsv"
run_harness "$TMP/mixed.tsv" 'bash check.sh'
SUMMARY="$(printf '%s\n' "$OUT" | tail -n 1)"
if [ "$SUMMARY" = "mutation-harness: 5 件 / detected 1 / green-ok 1 / SURVIVED 1 / FALSE-POSITIVE 1 / NOT-APPLIED 1" ]; then
  ok "(C) 判定 5 種を 1 件ずつ数えた要約行を最終行に出す"
else
  bad "(C) 要約行が違う: [$SUMMARY]"
fi
[ "$RC" -eq 1 ] && ok "(C) 期待外れが 1 件でもあれば exit 1" || bad "(C) 期待外れがあるのに rc=$RC"
case "$OUT" in
  *'| detect | replace |'*'**detected**'*'| miss | replace |'*'NG（置換元が見つかりません（0 回））'*'**NOT-APPLIED**'*'**SURVIVED**'*'**FALSE-POSITIVE**'*'**green-ok**'*) ok "(C) 結果表に行ごとの適用の成否と判定が並ぶ" ;;
  *) bad "(C) 結果表の行が期待どおりでない: [$OUT]" ;;
esac
{
  T detect replace target.txt alpha gamma red
  T greenok append other.txt zzz - green
} > "$TMP/good.tsv"
run_harness "$TMP/good.tsv" 'bash check.sh' --out "$TMP/result.md"
[ "$RC" -eq 0 ] && ok "(C) 全件期待どおりなら exit 0" || bad "(C) 全件期待どおりで rc=$RC"
if [ -s "$TMP/result.md" ] && [ "$(tail -n 1 "$TMP/result.md")" = "mutation-harness: 2 件 / detected 1 / green-ok 1 / SURVIVED 0 / FALSE-POSITIVE 0 / NOT-APPLIED 0" ]; then
  ok "(C) --out へ同じ結果表を書き出す"
else
  bad "(C) --out の結果表が無い・違う"
fi
RC=0
env -u FF_DEV_TOOLKIT_ROOT -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT bash "$HARNESS" --suite true >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 64 ] && ok "(C) --table が無い使い方の誤りは exit 64" || bad "(C) 使い方の誤りの rc: $RC"

echo "mutation-harness: (D) 作業領域の cleanup"
mkdir -p "$WORKP/pristine" "$WORKP/case-1"
printf 'keep\n' > "$WORKP/pristine/keep.txt"
printf 'keep\n' > "$WORKP/case-1/keep.txt"
run_harness "$TMP/good.tsv" 'bash check.sh'
if [ -f "$WORKP/pristine/keep.txt" ] && [ -f "$WORKP/case-1/keep.txt" ]; then
  ok "(D) --work-dir の既存の pristine / case-* に触れない"
else
  bad "(D) --work-dir の既存の中身を消した"
fi
[ "$(leftover)" = "0" ] && ok "(D) 自分が作った harness.* だけを終了時に消す" || bad "(D) harness.* が残った: $(leftover) 件"
run_harness "$TMP/good.tsv" 'bash check.sh' --keep
[ "$(leftover)" = "1" ] && ok "(D) --keep は作業領域を残す" || bad "(D) --keep で残らない: $(leftover) 件"
rm -rf "$WORKP"/harness.*

echo "mutation-harness: (E) 写しの境界（symlink）"
{
  T via-link-dir replace link-dir/f.txt outside inside red
  T via-link-file replace link-file outside inside red
  T create-via-link create link-dir/new.txt x - red
} > "$TMP/links.tsv"
run_harness "$TMP/links.tsv" 'bash check.sh'
case "$OUT" in
  *'| via-link-dir |'*'symlink'*'**NOT-APPLIED**'*'| via-link-file |'*'symlink'*'**NOT-APPLIED**'*'| create-via-link |'*'symlink'*'**NOT-APPLIED**'*) ok "(E) 対象・祖先が symlink の変異は NOT-APPLIED" ;;
  *) bad "(E) symlink 越しの変異が NOT-APPLIED にならない: [$OUT]" ;;
esac
if [ "$(cat "$OUTSIDE/file.txt")" = "outside" ] && [ "$(cat "$OUTSIDE/dir/f.txt")" = "outside" ] && [ ! -e "$OUTSIDE/dir/new.txt" ]; then
  ok "(E) 写しの外（symlink の指す先）を書き換えない"
else
  bad "(E) 写しの外が書き換わった"
fi

echo "mutation-harness: (F) 対照の副作用を変異へ持ち込まない"
# 2 回目の実行（前回の副作用 side.txt が残っている写し）で赤になる suite
T greenok append other.txt zzz - green > "$TMP/side.tsv"
run_harness "$TMP/side.tsv" '[ ! -e side.txt ] && : > side.txt'
[ "$RC" -eq 0 ] && ok "(F) 対照を専用の写しで回して捨てる（副作用のある suite で誤検知しない）" || bad "(F) 対照の副作用が変異の写しへ混ざった: rc=$RC out=[$OUT]"

echo "mutation-harness: (G) 引数の末尾の改行"
T trailing-nl replace target.txt 'beta' 'beta\n' red > "$TMP/nl.tsv"
run_harness "$TMP/nl.tsv" 'test "$(grep -c "" target.txt)" -eq 2'
case "$OUT" in
  *'**detected**'*) [ "$RC" -eq 0 ] && ok "(G) 引数の末尾の \\n を保持して適用する" || bad "(G) rc=$RC" ;;
  *) bad "(G) 末尾の改行が落ちた（no-op 扱い）: [$OUT]" ;;
esac

echo "mutation-harness: (H) plugin root の handoff を写し側へ張り替える"
T detect replace target.txt alpha gamma red > "$TMP/handoff.tsv"
RC=0
OUT="$(env -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT FF_DEV_TOOLKIT_ROOT="$REPO/plugin" \
  bash "$HARNESS" --root "$REPO" --table "$TMP/handoff.tsv" --suite 'bash plugin/scripts/probe.sh' --work-dir "$WORKP" 2>"$TMP/err")" || RC=$?
case "$OUT" in
  *'**detected**'*) [ "$RC" -eq 0 ] && ok "(H) handoff を写し側へ張り替え、対照は緑・写しの変異を検出する" || bad "(H) rc=$RC out=[$OUT]" ;;
  *) bad "(H) handoff が元の root を指したまま（対照が止まる / 変異を見落とす）: rc=$RC err=[$(cat "$TMP/err")] out=[$OUT]" ;;
esac

echo "mutation-harness: (I) delete-line のバイト保持"
T delete-bs delete-line bs.txt 'MARK\\x' - red > "$TMP/del.tsv"
run_harness "$TMP/del.tsv" '! cmp -s bs.txt bs.expected'
case "$OUT" in
  *'**detected**'*) [ "$RC" -eq 0 ] && ok "(I) バックスラッシュ入りの目印の行だけを消し、他の行と末尾改行の無さを保つ" || bad "(I) rc=$RC" ;;
  *) bad "(I) delete-line が他のバイトを変えた / 目印を探せない: [$OUT]" ;;
esac

echo "mutation-harness: (J) create は引数をそのまま書く"
T create-exact create new.txt abc - red > "$TMP/create.tsv"
run_harness "$TMP/create.tsv" '! printf abc | cmp -s - new.txt'
case "$OUT" in
  *'**detected**'*) [ "$RC" -eq 0 ] && ok "(J) create は改行を足さずに引数 1 をそのまま書く" || bad "(J) rc=$RC" ;;
  *) bad "(J) create が内容を変えた: [$OUT]" ;;
esac

echo
REACHED_END=1
if [ "$FAIL" -gt 0 ]; then
  echo "✗ mutation-harness: ${FAIL} 件失敗（成功 ${PASS} 件）" >&2
  exit 1
fi
echo "✅ mutation-harness: all ${PASS} checks passed"
