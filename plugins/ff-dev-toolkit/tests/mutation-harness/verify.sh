#!/usr/bin/env bash
#
# mutation-harness: 変異ハーネス（scripts/mutation-harness.sh）の恒久検査。
#
# 一時ディレクトリの fixture リポジトリ（target.txt と小さな検査スクリプト）に対してハーネスを
# 実際に回し、次を固定する:
#   A. 変異表が空（空・コメントだけ）は exit 2 で止め、写しも suite も作らない
#   B. 対照（変異なしの写し）が赤なら変異を当てずに exit 2。失敗行（✗ 行の先頭最大 10 行＋超過件数、
#      ✗ 行が無ければ出力末尾）と要約行を stderr に出す
#   C. 判定 5 種（detected / green-ok / SURVIVED / FALSE-POSITIVE / NOT-APPLIED）と要約行、
#      期待外れが 1 件でもあれば exit 1 / 全件期待どおりなら exit 0 / 使い方の誤りは exit 64
#   D. 作業領域: --work-dir 配下の一意な子ディレクトリだけを作って消す（既存の `pristine` /
#      `case-*` に触れない）。--keep はその子を残す
#   E. 写しの境界: 対象・祖先が symlink の変異（replace / create）は NOT-APPLIED で、写しの外
#      （symlink の指す先）を書き換えない
#   F. 対照は専用の写しで回して捨てる（成功しつつファイルを書き換える suite の副作用が変異へ混ざらない）
#   G. 引数の末尾の `\n` を保持する（コマンド置換で落ちると適用前後のハッシュが同じになる）
#   H. plugin root の handoff（FF_DEV_TOOLKIT_ROOT 等）は既定で suite へ継承せず外す（起動ガード付き
#      suite が env -u 無しで緑になる）。--remap-plugin-root 指定時だけ写し側へ張り替え、写しの中の
#      root 固定ガード付きスクリプトが止まらず変異を検査する
#   I. delete-line は他の行のバイト・末尾改行の有無を保ち、バックスラッシュ入りの目印をそのまま探す
#   J. create は引数 1 をそのまま書く（改行を足さない）
#
# run-all-required: no — git / 一時領域が無い環境の skip を許容する（一時領域依存 suite と同じ扱い）
# 空振り検出: ハーネスの最後の判定（`N_SURV` / `N_FP` / `N_NA` のどれかが 1 件以上なら exit 1）を消して常に exit 0 にする変異を入れると (C) の「期待外れが 1 件でもあれば exit 1」が赤になり、変異表 0 件の停止（2 箇所の `die "変異表に変異が 1 件もありません…"`）を消すと (A)「コメントだけの変異表は exit 2」が赤になる（2026-09-24 実測。空の入力・期待外れを緑へ倒さないことの実測）。
# 変異検出（2026-09-24 実測）: 作業領域・写しの境界・対照・末尾改行を直す前のハーネスへ差し替えると (D) 2 件・(E)・(F)・(G) の 5 件が赤。
# 変異検出（2 巡目の fix。2026-09-24 実測）: handoff の張り替え・delete-line / create のバイト保持を直す前のハーネスへ差し替えると (H)・(I)・(J) の 3 件が赤。
# 変異検出（2026-11-22 macOS 実測、対照失敗診断と handoff 非継承）: mutation-harness.sh の対照失敗診断呼び出し削除・行頭 ✗ 判定を行中一致へ戻す・末尾要約単独 ✗ の出力末尾フォールバック無効化・既定の handoff 非継承を常時張り替えへ戻す・`--remap-plugin-root` フラグ削除・`FF_DEV_TOOLKIT_SKILL_FILE` の unset 削除の 6 変異がすべて rc=1（detected 6）、無害コメント追記 1 件のみ rc=0（green-ok 1 / SURVIVED 0 / FALSE-POSITIVE 0 / NOT-APPLIED 0、対照 27 checks passed）。
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
[ -z "${FF_DEV_TOOLKIT_SKILL_FILE:-}" ] || { echo "skill file leaked"; exit 3; }
grep -q '^alpha$' "$FF_DEV_TOOLKIT_ROOT/../target.txt"
PROBE
# (H1) handoff 4 変数の非継承を検査する模型（run-all.sh 本体の起動ガードは FF_DEV_TOOLKIT_ROOT を監視するが、
#      ここでは既定で外す 4 変数すべてが suite へ継承されないことをまとめて固定する）
cat > "$REPO/guard-suite.sh" <<'GUARD'
for v in FF_DEV_TOOLKIT_ROOT CLAUDE_PLUGIN_ROOT GROK_PLUGIN_ROOT FF_DEV_TOOLKIT_SKILL_FILE; do
  eval "val=\${${v}:-}"
  if [ -n "$val" ]; then
    echo "✗ 起動環境: ${v} が継承されています" >&2
    exit 3
  fi
done
grep -q '^alpha$' target.txt
GUARD
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
# ✗ 行を 12 行＋要約 1 行（計 13 行の ✗）出す suite: 先頭 10 行と超過 3 行の省略表示・要約行が stderr に含まれる
cat > "$REPO/fail-x.sh" <<'FAILX'
echo "  ✓ pass-1"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  echo "  ✗ fail-reason-${i}" >&2
done
echo "✗ fail-x: 12 件失敗" >&2
exit 1
FAILX
git -C "$REPO" add fail-x.sh >/dev/null 2>&1
git -C "$REPO" -c commit.gpgsign=false commit -q -m add-fail-x >/dev/null 2>&1
run_harness "$TMP/one.tsv" 'bash fail-x.sh'
if [ "$RC" -eq 2 ] \
  && grep -qF -- '失敗行（✗）:' "$TMP/err" \
  && grep -qF -- '✗ fail-reason-1' "$TMP/err" \
  && grep -qF -- '✗ fail-reason-10' "$TMP/err" \
  && ! grep -qF -- '✗ fail-reason-11' "$TMP/err" \
  && grep -qF -- 'ほか 3 行' "$TMP/err" \
  && grep -qF -- '要約行: ✗ fail-x: 12 件失敗' "$TMP/err"; then
  ok "(B2) 対照が赤のとき suite の ✗ 行（先頭 10 行＋省略件数）と要約行を stderr に出す"
else
  bad "(B2) 対照赤の ✗ 行出力が期待と違う: rc=$RC err=[$ERR]"
fi
# ✗ を含まない失敗出力でも出力末尾が stderr に含まれる
run_harness "$TMP/one.tsv" 'printf "step1\nplain-error-cause\n"; exit 3'
if [ "$RC" -eq 2 ] \
  && grep -qF -- '出力末尾:' "$TMP/err" \
  && grep -qF -- 'plain-error-cause' "$TMP/err"; then
  ok "(B3) 対照が ✗ なしで赤のとき出力末尾を stderr に出す"
else
  bad "(B3) ✗ なし対照赤の出力末尾が期待と違う: rc=$RC err=[$ERR]"
fi
# 行中に ✗ を含む成功行（✓ fixture mentions ✗）は失敗行へ誤分類せず出力末尾へフォールバックする
run_harness "$TMP/one.tsv" 'printf "  ✓ fixture mentions ✗\ninput file missing\ncleanup finished\n"; exit 1'
if [ "$RC" -eq 2 ] \
  && ! grep -qF -- '失敗行（✗）:' "$TMP/err" \
  && grep -qF -- '出力末尾:' "$TMP/err" \
  && grep -qF -- 'input file missing' "$TMP/err"; then
  ok "(B4) 行中に ✗ を含む成功行を失敗行と誤分類せず出力末尾で本来の原因を出す"
else
  bad "(B4) 行中 ✗ の誤分類防止が効いていない: rc=$RC err=[$ERR]"
fi
# 境界: ちょうど 10 行の ✗（省略行なし・CRLF 除去）と、完全空ログ（失敗行も出力末尾も出ない）
run_harness "$TMP/one.tsv" 'for i in 1 2 3 4 5 6 7 8 9 10; do printf "  ✗ crlf-fail-%s\r\n" "$i"; done; exit 1'
if [ "$RC" -eq 2 ] \
  && grep -qF -- '失敗行（✗）:' "$TMP/err" \
  && grep -qF -- '✗ crlf-fail-10' "$TMP/err" \
  && ! grep -qF -- 'ほか ' "$TMP/err"; then
  ok "(B5) ✗ がちょうど 10 行（CRLF 付き）のとき全 10 行を出し省略行を出さない"
else
  bad "(B5) 10 行境界/CRLF の出力が期待と違う: rc=$RC err=[$ERR]"
fi
run_harness "$TMP/one.tsv" 'exit 1'
if [ "$RC" -eq 2 ] \
  && ! grep -qF -- '失敗行（✗）:' "$TMP/err" \
  && ! grep -qF -- '出力末尾:' "$TMP/err" \
  && grep -qF -- '要約行:' "$TMP/err"; then
  ok "(B6) 空ログで赤のときは失敗行も出力末尾も出さず要約行のみで exit 2"
else
  bad "(B6) 空ログ時の出力が期待と違う: rc=$RC err=[$ERR]"
fi
# 要約行だけに ✗ が付く場合は、直前の原因行を含む出力末尾を表示する
run_harness "$TMP/one.tsv" 'printf "input file missing\n✗ suite: 1 件失敗\n"; exit 1'
if [ "$RC" -eq 2 ] \
  && ! grep -qF -- '失敗行（✗）:' "$TMP/err" \
  && grep -qF -- '出力末尾:' "$TMP/err" \
  && grep -qF -- 'input file missing' "$TMP/err" \
  && grep -qF -- '要約行: ✗ suite: 1 件失敗' "$TMP/err"; then
  ok "(B7) ✗ が末尾要約行だけに付く場合は出力末尾を出して直前の原因行を見せる"
else
  bad "(B7) 要約行単独 ✗ のフォールバックが効いていない: rc=$RC err=[$ERR]"
fi

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

echo "mutation-harness: (H) plugin root の handoff の扱い（既定 unset / --remap-plugin-root 明示張り替え）"
T detect replace target.txt alpha gamma red > "$TMP/handoff.tsv"
# (H1) 既定: 親に handoff 4 変数があっても suite へ継承しない（起動ガード付き suite が env -u 無しで緑）
RC=0
OUT="$(FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" GROK_PLUGIN_ROOT="$PLUGIN_ROOT" \
  FF_DEV_TOOLKIT_SKILL_FILE="$PLUGIN_ROOT/skills/close-issue/SKILL.md" \
  bash "$HARNESS" --root "$REPO" --table "$TMP/handoff.tsv" --suite 'bash guard-suite.sh' --work-dir "$WORKP" 2>"$TMP/err")" || RC=$?
case "$OUT" in
  *'**detected**'*) [ "$RC" -eq 0 ] && ok "(H1) 既定では handoff 4 変数を外して実行し、起動ガード付き suite が env -u 無しで緑・変異を検出する" || bad "(H1) rc=$RC out=[$OUT]" ;;
  *) bad "(H1) 既定で handoff が継承されて起動ガードに引っかかった: rc=$RC err=[$(cat "$TMP/err")] out=[$OUT]" ;;
esac
# (H2) --remap-plugin-root 指定: handoff を写し側へ張り替え、写しの中の root 固定ガード付きスクリプトを検査できる（SKILL_FILE は常に外れる）
RC=0
OUT="$(env -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT FF_DEV_TOOLKIT_ROOT="$REPO/plugin" \
  FF_DEV_TOOLKIT_SKILL_FILE="$PLUGIN_ROOT/skills/close-issue/SKILL.md" \
  bash "$HARNESS" --root "$REPO" --table "$TMP/handoff.tsv" --suite 'bash plugin/scripts/probe.sh' --remap-plugin-root --work-dir "$WORKP" 2>"$TMP/err")" || RC=$?
case "$OUT" in
  *'**detected**'*) [ "$RC" -eq 0 ] && ok "(H2) --remap-plugin-root 指定時は handoff を写し側へ張り替え（SKILL_FILE は外し）、対照は緑・写しの変異を検出する" || bad "(H2) rc=$RC out=[$OUT]" ;;
  *) bad "(H2) --remap-plugin-root で張り替えが効かない: rc=$RC err=[$(cat "$TMP/err")] out=[$OUT]" ;;
esac
# (H3) --remap-plugin-root なしで handoff 必須の probe.sh を回すと対照赤（rc=2）かつ原因（root mismatch）が出る
RC=0
OUT="$(env -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT FF_DEV_TOOLKIT_ROOT="$REPO/plugin" \
  bash "$HARNESS" --root "$REPO" --table "$TMP/handoff.tsv" --suite 'bash plugin/scripts/probe.sh' --work-dir "$WORKP" 2>"$TMP/err")" || RC=$?
if [ "$RC" -eq 2 ] && grep -qF -- 'root mismatch' "$TMP/err"; then
  ok "(H3) --remap-plugin-root なしで handoff 必須スクリプトを回すと対照赤（rc=2）で原因（root mismatch）を出す"
else
  bad "(H3) --remap-plugin-root なしの負例が期待と違う: rc=$RC err=[$(cat "$TMP/err")] out=[$OUT]"
fi

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
