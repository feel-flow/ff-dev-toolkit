#!/usr/bin/env bash
#
# changed-select — 部分ゲート（FF_RUN_ALL_CHANGED）の選択を受け持つ tests/changed-select/select.sh と、
# 試算の道具 simulate.sh を検査する（Issue `#3006`。親 `#2989`）。
# 空振り検出: 宣言を 1 件も読めない実体（本 suite の宣言行の削除・宣言の書式変更）を与えると L1 が赤、git の無い木・suite のファイルが 0 件の tests・追跡下のファイルが 0 件の木を与えると C8 が終了コード 2 を返さなければ赤になる。照合の行のファイルが空・読めない・宣言のある suite の行が 0 件の回は simulate.sh --expect が終了コード 2 を返して L2 が赤になる（0 件は S15 で実測）。
#
# 変異検出: 2026-11-25。本 suite の宣言行の削除（L1）・宣言の書式名の変更（D1〜D3 ほか 21 件）・
# 判定不能の 2 経路を終了コード 0 へ変える（C8）・check で宣言の行を字面の走査へ戻す（C5）・接尾辞の解決を
# 外す（C9）・完全一致より先に接尾辞で当てる（C1）の 7 変異がいずれも赤。derive で宣言の行を走査へ戻す変異は
# 観測できない等価変異（宣言のある suite は字面の根拠を使わない）。レビュー対応の 7 変異も赤: pipefail を外す
# （U6）・名前の辺を source の行だけへ戻す（U1 の hook・t2b・t6）・実行ファイルを中継する（U1 の t7・t8）・
# 共有 lib でない変更も起点にする（U8）・試算の判定を切り捨てた百分率で比べる（S5）・変数のディレクトリに
# 続く名前の規則を外す（C11）・ファイル名だけの語を tests 配下すべてで交差させない（D9）。2 巡目の 4 変異も赤:
# lib の直下だけを共有 lib とする（U9）・source の行の末尾コメントを残す（C14）・プラグインの外の同名へ
# 広げない（C13）・閾値を 10 進数へ正規化しない（S10）。--expect の 9 変異も赤（2026-11-25）: 改行で終わらない
# 最終行を読まない（S20）・それに加えて行数の突き合わせを外す（S20）・モードを前方一致で受ける（S21）・読めない
# ファイルを宣言なしへ倒す（S25）・照合 0 件の判定不能を外す（S15）・宣言の有無で絞らない（S11）・漏れを終了
# コード 0 にする（S12）・プラグインルート相対に接頭辞を付けない（S23）・同じパスでもランナーを回し直す（S24）・
# 選んだ件数と suite の行の数の突き合わせを外す（S26）。
#
# 判定の正本は select.sh の先頭コメント、運用は docs/04-quality/TESTING.md「変更ベースの部分ゲート」。
#
#   D0〜D9. derive: 依存を宣言した suite は宣言のパターン（`*` は 1 成分・`**` は成分またぎ・末尾 `/` は
#       ディレクトリ・`/` 始まりはリポジトリ相対）と自分のディレクトリでだけ選ばれ、字面の照合をやめる。
#       宣言の無い suite は従来どおり字面で選ぶ。パターンの無い宣言は fail-safe で常に選ぶ。ファイル名だけの
#       語はランナーと共有 lib の変更とは交差し、ほかの suite のディレクトリの変更とは交差しない
#   U1〜U9. users: 変わった共有 lib（lib/ 配下。深さは問わない）の名前にコメント以外の行で（推移的に）触れるファイルを tests・hooks・
#       scripts から集める（`if source`・for で回す名前・変数経由・lib を経由した中継も拾う）。コメントの言及・
#       fixtures・プラグインの外は拾わず、実行ファイル（hook・suite の入口）は中継にしない。共有 lib でない
#       実行ファイルの変更は逆引きしない。走査の失敗・値の無いオプションは終了コード 2
#   X1. scan: derive と check が読む suite のファイルの集合
#   C1〜C14. check: 宣言と実際の参照の食い違い（宣言に無い参照・1 つに決まらない名前の参照・source して
#       いない lib〔行末のコメントは source に数えない〕・実体に当たらない宣言・古い run-all-not-depends・
#       パターンの無い宣言・depends の無い not-depends）を赤にし、判定できない木は終了コード 2。別の基点から
#       書いたファイル形の語は接尾辞で当たる実体すべてを、リポジトリ相対とプラグイン相対の両方にある語は
#       両方を、変数経由の名前はプラグインの中（無ければリポジトリ全体）の同名を要求する
#   L1. 実体（このリポジトリ）の宣言が check を通り、宣言が 1 件以上読める
#   L2. 選択の漏れの回帰検査: data/census-878.tsv（Issue `#878` の census）と data/expect-not-relayed.tsv
#       （利用側の逆引きが中継しない依存の代表。照合は suite の字面に名前が出る間しか検出しない）のうち、宣言の
#       ある suite の行が実体のランナーの選択で選ばれる（simulate.sh --expect）。公開リポジトリの配置（oss/ 階層が
#       無い）では、宣言と照合の行が指す開発元のファイルが無いので、L1・L2 を登録済みの理由で skip する
#   S1〜S10. simulate.sh の引数検査・判定不能・評価データの形式と、代役のランナーでの集計（全件比・端数を
#       切り捨てない閾値・先頭が 0 の閾値・件数の突き合わせ・全件へ倒れた PR・ランナーの失敗）
#   S11〜S26. simulate.sh --expect: 宣言のある suite の行だけを照合・漏れの名指し・全件へ倒れる変更（理由を
#       添える）・古い行（プラグインルート相対と / 始まり）・照合 0 件・未登録の suite・列の欠け・ランナーの
#       失敗・閾値のオプションとの併用・改行で終わらない最終行・崩れたモード（`mode=fullish`）・変更パスの
#       解決（プラグインルート相対は接頭辞を付け、/ 始まりはそのまま）・同じパスの使い回し・読めない suite の
#       ファイル・選んだ件数と suite の行の数の食い違い
#
# 依存の宣言（本 suite 自身）: L1 は全 suite のスクリプトと、リポジトリ全体の追跡下のファイル名を読む。
# どこのファイルの追加・削除でも結果が変わりうるので、全体を宣言する（L2 は、宣言のある suite の行の変更
# パスの数だけランナーを試算モードで回す。2026-11-25 時点で 8 回、1 回およそ 5 秒）。開発元のリポジトリルートの
# ファイルを前提にするので、公開リポジトリの suite セットからは外している（公開 workflow の EXCLUDED_SSOT_SUITES）。
# run-all-depends: /**
#
# 実装上の制約: macOS 標準の bash 3.2 で動くこと。ネットワークは使わない。
# fixture の中身は heredoc で書かない（行頭が `#` の行が本 suite 自身の宣言として読まれる）。

set -uo pipefail

# 呼び出し元から継いだ git の場所の指定を外す（git の hook の中などで GIT_DIR が立っていると、
# fixture への `git -C <一時ディレクトリ>` が元のリポジトリを操作する）。外す名前は tests/lib/git-fixture.sh の
# ff_git_fixture_unset_env と同じ
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
for _v in $(compgen -v GIT_CONFIG_ 2>/dev/null || true); do
  case "$_v" in GIT_CONFIG_KEY_*|GIT_CONFIG_VALUE_*) unset "$_v" ;; esac
done

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TESTS_DIR="$(cd "$SUITE_DIR/.." && pwd -P)"
SEL="$SUITE_DIR/select.sh"
SIM="$SUITE_DIR/simulate.sh"
FAIL=0
PASS=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ff-changed-select-verify.XXXXXX")" || {
  echo "✗ changed-select: 一時領域を作れません" >&2
  exit 1
}
# 途中で死んだ回（set -u の未定義参照など）を rc=0 の pass にしない。最後まで到達した印が無ければ赤にする
FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$WORK"
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ changed-select: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

for _cmd in git awk find; do
  command -v "$_cmd" >/dev/null 2>&1 || { echo "✗ changed-select: ${_cmd} が無いので検査できません（判定不能）" >&2; exit 1; }
done
[ -r "$SEL" ] || { echo "✗ changed-select: select.sh を読めません: ${SEL}" >&2; exit 1; }

has() { # <haystack> <固定文字列>
  case "$1" in *"$2"*) return 0 ;; esac
  return 1
}

oneline() { printf '%s' "$1" | tr '\n' '|'; }

fx_write() { # <ルート> <ルート相対パス> <行>...
  mkdir -p "$(dirname "$1/$2")" || return 1
  local root="$1" rel="$2"
  shift 2
  printf '%s\n' "$@" > "$root/$rel"
}

# ── scan ──────────────────────────────────────────────────────────────────
echo "== scan"
FXS="$WORK/scan"
fx_write "$FXS" tests/a/verify.sh 'true'
fx_write "$FXS" tests/a/fx-helper.py 'pass'
fx_write "$FXS" tests/a/fx-notes.md 'n'
fx_write "$FXS" tests/a/fixtures/fx-fixture.sh 'true'
fx_write "$FXS" tests/a/node_modules/fx-mod.js 'x'
fx_write "$FXS" tests/lib/fx-shared.sh 'true'
fx_write "$FXS" tests/fx-runner.sh 'true'
OUT="$(bash "$SEL" scan "$FXS/tests" 2>"$WORK/err" | sed "s#^$FXS/tests/##" | LC_ALL=C sort | tr '\n' ' ')"
if [ "$OUT" = "a/fx-helper.py a/verify.sh " ]; then
  ok "X1: scan は suite 配下のスクリプトだけを返す（共有 lib・fixtures・node_modules・tests 直下・文書を除く）"
else
  bad "X1: scan の集合が違う（${OUT}）"
fi

# ── derive ────────────────────────────────────────────────────────────────
echo "== derive"
FXD="$WORK/derive"
fx_write "$FXD" plugins/ff/tests/alpha/verify.sh \
  'cat "$ROOT/docs/fx-guide.md"'
fx_write "$FXD" plugins/ff/tests/beta/verify.sh \
  '# run-all-depends: docs/fx-guide.md' \
  'cat "$ROOT/docs/fx-guide.md"' \
  'echo "docs/fx-other.md の名前を出すだけ"'
fx_write "$FXD" plugins/ff/tests/kappa/verify.sh \
  'echo "docs/fx-other.md の名前を出すだけ"'
fx_write "$FXD" plugins/ff/tests/gamma/verify.sh \
  '# run-all-depends: /fx-top.md skills/*/SKILL.md' \
  'true'
fx_write "$FXD" plugins/ff/tests/delta/verify.sh \
  '# run-all-depends: scripts/**' \
  'true'
fx_write "$FXD" plugins/ff/tests/eps/verify.sh \
  '# run-all-depends:' \
  'true'
fx_write "$FXD" plugins/ff/tests/zeta/verify.sh \
  '# run-all-depends: docs/sub/' \
  '# run-all-depends: docs/a+b.md' \
  'true'
fx_write "$FXD" plugins/ff/tests/lam/verify.sh \
  'bash "$TESTS/fx-runner.sh"' \
  'echo fx-shared.sh'

derive_run() { # <変更パス>...  FXD の全 suite を走査して OUT / RC に受ける
  local files
  files="$(printf '%s\n' "$@")"
  OUT="$(FF_CHG_FILES="$files" FF_CHG_TESTS_PREFIX="plugins/ff/tests/" FF_CHG_TESTS_DIR="$FXD/plugins/ff/tests" \
    FF_CHG_PLUGIN_PREFIX="plugins/ff/" bash "$SEL" derive "$FXD"/plugins/ff/tests/*/verify.sh 2>"$WORK/err")"
  RC=$?
}
sel() { # <ラベル> <suite> [<根拠に含む固定文字列>]
  local line
  line="$(printf '%s\n' "$OUT" | awk -F'\t' -v s="$2" '$1 == "S" && $2 == s')"
  if [ "$RC" -ne 0 ] || [ -z "$line" ]; then
    bad "$1: ${2} が選ばれない（rc=${RC}。出力: $(oneline "$OUT")）"
    return
  fi
  if [ -n "${3-}" ] && ! has "$line" "$3"; then
    bad "$1: ${2} の根拠に「${3}」が無い（${line}）"
    return
  fi
  ok "$1: ${2} を選ぶ"
}
rej() { # <ラベル> <suite>
  if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | awk -F'\t' -v s="$2" '$1 == "R" && $2 == s { f = 1 } END { exit !f }'; then
    ok "$1: ${2} を選ばない"
  else
    bad "$1: ${2} を選ばない、にならない（rc=${RC}。出力: $(oneline "$OUT")）"
  fi
}

if FF_CHG_FILES="x" bash "$SEL" derive >/dev/null 2>&1; then
  bad "D0: 走査するファイルが 0 件なのに終了コード 0"
else
  ok "D0: 走査するファイルが 0 件なら非 0"
fi

derive_run plugins/ff/docs/fx-guide.md
n_lines="$(printf '%s\n' "$OUT" | awk 'NF > 0' | wc -l | tr -d ' ')"
if [ "$n_lines" = 8 ]; then ok "D1: 走査した 8 suite がそれぞれ 1 行ずつ出る"; else bad "D1: 出力の行数が 8 でない（${n_lines}: $(oneline "$OUT")）"; fi
sel D1 alpha "docs/fx-guide.md"
sel D1 beta "plugins/ff/docs/fx-guide.md ← 宣言 docs/fx-guide.md"
sel D1 eps "fail-safe"
rej D1 gamma
rej D1 delta
rej D1 zeta

# 宣言した suite は字面の照合をやめる（同じ行を持つ宣言なしの kappa は選ばれる）
derive_run plugins/ff/docs/fx-other.md
rej D2 beta
sel D2 kappa "docs/fx-other.md"
rej D2 alpha

derive_run fx-top.md
sel D3 gamma "fx-top.md ← 宣言 /fx-top.md"
derive_run plugins/ff/fx-top.md
rej D3 gamma

derive_run plugins/ff/skills/one/SKILL.md
sel D4 gamma "宣言 skills/*/SKILL.md"
derive_run plugins/ff/skills/one/deep/SKILL.md
rej D4 gamma

derive_run plugins/ff/scripts/lib/deep/fx-x.sh
sel D5 delta "宣言 scripts/**"
derive_run plugins/ff/scriptsx/fx-x.sh
rej D5 delta

derive_run plugins/ff/docs/sub/a/fx-b.md
sel D6 zeta "宣言 docs/sub/"
derive_run plugins/ff/docs/subx.md
rej D6 zeta

derive_run plugins/ff/docs/a+b.md
sel D7 zeta "宣言 docs/a+b.md"
derive_run plugins/ff/docs/aab.md
rej D7 zeta

derive_run plugins/ff/tests/beta/fx-data.txt
sel D8 beta "suite 自身のディレクトリ"
rej D8 gamma

# ファイル名だけの語（変数のディレクトリに続く名前を含む）は、ランナー（tests 直下）と共有 lib（tests/lib）の
# 変更とは交差し、ほかの suite のディレクトリの変更とは交差しない
derive_run plugins/ff/tests/fx-runner.sh
sel D9 lam "fx-runner.sh"
derive_run plugins/ff/tests/lib/fx-shared.sh
sel D9 lam "fx-shared.sh"
derive_run plugins/ff/tests/kappa/fx-runner.sh
rej D9 lam
sel D9 kappa "suite 自身のディレクトリ"

# ── users ─────────────────────────────────────────────────────────────────
echo "== users"
FXU="$WORK/users"
fx_write "$FXU" plugins/ff/scripts/lib/fx-base.sh 'fx_base() { :; }'
fx_write "$FXU" plugins/ff/scripts/lib/fx-mid.sh '. "$(dirname "${BASH_SOURCE[0]}")/fx-base.sh"'
fx_write "$FXU" plugins/ff/tests/t1/verify.sh \
  'ROOT=x' \
  '  source "$ROOT/scripts/lib/fx-mid.sh"'
fx_write "$FXU" plugins/ff/hooks/fx-hook.sh \
  'MID_LIB="$ROOT/scripts/lib/fx-mid.sh"' \
  '[ -r "$MID_LIB" ] && . "$MID_LIB"'
fx_write "$FXU" plugins/ff/tests/t2/verify.sh 'true' '  # fx-base.sh の説明だけ（コメントの言及は数えない）'
fx_write "$FXU" plugins/ff/tests/t2b/verify.sh 'echo "fx-base.sh の名前に触れる行（多く回す側へ数える）"'
fx_write "$FXU" plugins/ff/tests/t3/fixtures/fx-copy.sh '. "./fx-base.sh"'
fx_write "$FXU" plugins/ff/tests/t4/verify.sh 'echo shellcheck-directive-only' '  # shellcheck source=../../scripts/lib/fx-base.sh'
fx_write "$FXU" plugins/ff/tests/t5/verify.sh \
  'LIB_DIR="$ROOT/scripts/lib"' \
  'if source "$LIB_DIR/fx-base.sh"; then :; fi'
fx_write "$FXU" plugins/ff/tests/t6/verify.sh \
  'for lib in fx-base.sh; do' \
  '  . "$ROOT/scripts/lib/$lib"' \
  'done'
fx_write "$FXU" plugins/ff/tests/t7/verify.sh 'bash "$OTHER/verify.sh"'
fx_write "$FXU" plugins/ff/tests/t8/verify.sh 'bash "$ROOT/hooks/fx-hook.sh"'
fx_write "$FXU" plugins/ff/tests/lib/inner/fx-inner.sh 'fx_inner() { :; }'
fx_write "$FXU" plugins/ff/tests/lib/fx-outer.sh '. "$(dirname "${BASH_SOURCE[0]}")/inner/fx-inner.sh"'
fx_write "$FXU" plugins/ff/tests/t9/verify.sh '. "$ROOT/tests/lib/fx-outer.sh"'
fx_write "$FXU" plugins/ff/scripts/lib/fx-cyc1.sh '. "$(dirname "$0")/fx-cyc2.sh"'
fx_write "$FXU" plugins/ff/scripts/lib/fx-cyc2.sh '. "$(dirname "$0")/fx-cyc1.sh"'
fx_write "$FXU" other/fx-outside.sh '. fx-base.sh'

users_run() { # <変更パス>...
  printf '%s\n' "$@" > "$WORK/users-in"
  OUT="$(bash "$SEL" users --root "$FXU" --plugin-prefix plugins/ff/ < "$WORK/users-in" 2>"$WORK/err")"
  RC=$?
}
user_has() { # <ラベル> <利用側のパス> <元の変更パス>
  if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | awk -F'\t' -v u="$2" -v o="$3" '$1 == u && $2 == o { f = 1 } END { exit !f }'; then
    ok "$1: ${2} を拾う"
  else
    bad "$1: ${2} を拾わない（rc=${RC}。出力: $(oneline "$OUT")）"
  fi
}
user_lacks() { # <ラベル> <利用側のパス>
  if [ "$RC" -eq 0 ] && ! printf '%s\n' "$OUT" | awk -F'\t' -v u="$2" '$1 == u { f = 1 } END { exit !f }'; then
    ok "$1: ${2} を拾わない"
  else
    bad "$1: ${2} を拾った・失敗した（rc=${RC}。出力: $(oneline "$OUT")）"
  fi
}

BASE=plugins/ff/scripts/lib/fx-base.sh
users_run "$BASE"
user_has U1 plugins/ff/scripts/lib/fx-mid.sh "$BASE"
user_has U1 plugins/ff/tests/t1/verify.sh "$BASE"
user_has U1 plugins/ff/hooks/fx-hook.sh "$BASE"
user_has U1 plugins/ff/tests/t4/verify.sh "$BASE"
user_has U1 plugins/ff/tests/t2b/verify.sh "$BASE"
user_has U1 plugins/ff/tests/t5/verify.sh "$BASE"
user_has U1 plugins/ff/tests/t6/verify.sh "$BASE"
# 実行ファイル（hook）は利用側として返すが中継しない（hook を実行する t8 は、hook を変更一覧へ足した導出が字面で拾う）
user_lacks U1 plugins/ff/tests/t8/verify.sh
user_lacks U1 plugins/ff/tests/t2/verify.sh
user_lacks U1 plugins/ff/tests/t3/fixtures/fx-copy.sh
user_lacks U1 plugins/ff/tests/t7/verify.sh
user_lacks U1 other/fx-outside.sh

users_run plugins/ff/docs/fx-x.md
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "U2: シェル以外の変更は利用側を返さない"; else bad "U2: シェル以外の変更で rc=${RC} / 出力 $(oneline "$OUT")"; fi
users_run other/fx-base.sh
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "U3: プラグインの外の変更は利用側を返さない"; else bad "U3: プラグインの外の変更で rc=${RC} / 出力 $(oneline "$OUT")"; fi
users_run plugins/ff/hooks/fx-hook.sh
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "U8: 共有 lib でない実行ファイルの変更は逆引きしない（導出の字面に任せる）"; else bad "U8: 実行ファイルの変更で rc=${RC} / 出力 $(oneline "$OUT")"; fi
# lib のサブディレクトリの lib も起点と中継にする（ランナーが全件の名簿から外す範囲と揃える）
users_run plugins/ff/tests/lib/inner/fx-inner.sh
user_has U9 plugins/ff/tests/lib/fx-outer.sh plugins/ff/tests/lib/inner/fx-inner.sh
user_has U9 plugins/ff/tests/t9/verify.sh plugins/ff/tests/lib/inner/fx-inner.sh
users_run plugins/ff/scripts/lib/fx-cyc1.sh
user_has U4 plugins/ff/scripts/lib/fx-cyc2.sh plugins/ff/scripts/lib/fx-cyc1.sh
if bash "$SEL" users --root "$WORK/fx-no-such-root" --plugin-prefix plugins/ff/ < /dev/null >/dev/null 2>&1; then
  bad "U5: 読めない --root で終了コード 0"
else
  ok "U5: 読めない --root なら非 0"
fi
# 走査（find）が失敗した回は、欠けた辺のまま成功に見せず終了コード 2（ランナーは全件へ倒す）
mkdir -p "$WORK/bin-badfind"
REAL_FIND="$(command -v find)"
printf '%s\n' '#!/bin/sh' "\"$REAL_FIND\" \"\$@\"" 'exit 1' > "$WORK/bin-badfind/find"
chmod +x "$WORK/bin-badfind/find"
printf '%s\n' "$BASE" > "$WORK/users-in"
if PATH="$WORK/bin-badfind:$PATH" bash "$SEL" users --root "$FXU" --plugin-prefix plugins/ff/ < "$WORK/users-in" >/dev/null 2>&1; then
  RC=0
else
  RC=$?
fi
if [ "$RC" -eq 2 ]; then ok "U6: 走査が失敗した回は終了コード 2"; else bad "U6: 走査が失敗した回の終了コードが ${RC}（2 でない）"; fi

# 値の無いオプションで止まる（無限ループしない）。終わらなければ止めて 124 と数える
run_bounded() { # <秒> <コマンド>...
  local secs="$1" pid i=0
  shift
  "$@" >/dev/null 2>&1 < /dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$i" -ge $((secs * 10)) ]; then
      kill "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      RC=124
      return
    fi
    sleep 0.1
    i=$((i + 1))
  done
  wait "$pid"
  RC=$?
}
run_bounded 10 bash "$SEL" users --root
if [ "$RC" -eq 2 ]; then ok "U7: 値の無い --root は終了コード 2"; else bad "U7: 値の無い --root で rc=${RC}（124 は止まらなかった）"; fi
run_bounded 10 bash "$SEL" check --root "$FXU" --tests-dir
if [ "$RC" -eq 2 ]; then ok "U7: 値の無い --tests-dir は終了コード 2"; else bad "U7: 値の無い --tests-dir で rc=${RC}（124 は止まらなかった）"; fi

# ── check ─────────────────────────────────────────────────────────────────
echo "== check"
ck_new() { # <名前>  git リポジトリの fixture を作って CK に入れる（コミットは要らない: 未追跡も追跡下に数える）
  CK="$WORK/ck-$1"
  mkdir -p "$CK" || return 1
  git -C "$CK" init -q >/dev/null 2>&1 || { bad "check: fixture の git init に失敗（$1）"; return 1; }
  fx_write "$CK" plugins/ff/tests/lib/fx-tl.sh 'fx_tl() { :; }'
  fx_write "$CK" plugins/ff/scripts/lib/fx-sl.sh 'fx_sl() { :; }'
  fx_write "$CK" plugins/ff/docs/fx-guide.md 'g'
  fx_write "$CK" plugins/ff/docs/fx-other.md 'o'
  fx_write "$CK" plugins/ff/docs/fx-uniq.md 'u'
  # 宣言の無い suite は照合の対象外（字面がどれだけ実在ファイルを指しても赤にしない）
  fx_write "$CK" plugins/ff/tests/free/verify.sh 'cat "$ROOT/docs/fx-other.md"' 'echo fx-uniq.md'
}
ck_run() {
  OUT="$(bash "$SEL" check --root "$CK" --tests-dir "$CK/plugins/ff/tests" --plugin-prefix plugins/ff/ 2>"$WORK/err")"
  RC=$?
  ERR="$(cat "$WORK/err")"
}
ck_line() { # <ラベル> <期待する行の先頭（固定文字列）>
  if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | awk -v p="$2" 'index($0, p) == 1 { f = 1 } END { exit !f }'; then
    ok "$1: 「${2}」"
  else
    bad "$1: 「${2}」が出ない（rc=${RC}。出力: $(oneline "$OUT")）"
  fi
}
ck_no_free() { # <ラベル>
  case $'\n'"$OUT" in
    *$'\n✗ free:'*) bad "$1: 宣言の無い suite を赤にした（$(oneline "$OUT")）" ;;
    *) ok "$1: 宣言の無い suite は照合しない" ;;
  esac
}

ck_new clean
fx_write "$CK" plugins/ff/tests/s/fx-own.txt 'own'
# 完全一致（プラグイン相対の tests/lib/fx-tl.sh）がある語は、同じ接尾辞を持つ別の実体を要求しない
fx_write "$CK" plugins/ff/docs-template/tests/lib/fx-tl.sh 'fx_tl() { :; }'
fx_write "$CK" plugins/ff/tests/s/verify.sh \
  '# run-all-depends: docs/fx-guide.md tests/lib/fx-tl.sh' \
  '# run-all-not-depends: docs/fx-other.md 説明のために名前を出すだけ' \
  '. "$ROOT/tests/lib/fx-tl.sh"' \
  'cat "$ROOT/docs/fx-guide.md"' \
  'echo "docs/fx-other.md は読まない"' \
  'ls "$ROOT"/docs/*.md' \
  'cat "$ROOT/tests/s/fx-own.txt"'
ck_run
if [ "$RC" -eq 0 ] && has "$OUT" "changed-select check: declared=1 violations=0"; then
  ok "C1: 宣言・source・外したファイル・glob・自分のディレクトリが揃った suite は通る"
else
  bad "C1: 揃った宣言が通らない（rc=${RC}。出力: $(oneline "$OUT") / $(oneline "$ERR")）"
fi
ck_no_free C1

ck_new unref
fx_write "$CK" plugins/ff/tests/s/verify.sh \
  '# run-all-depends: docs/fx-guide.md' \
  'cat "$ROOT/docs/fx-guide.md"' \
  'cat "$ROOT/docs/fx-other.md"' \
  'echo fx-uniq.md'
ck_run
ck_line C2 "✗ s: 宣言に無い参照: plugins/ff/docs/fx-other.md"
ck_line C2 "✗ s: 宣言に無い参照: plugins/ff/docs/fx-uniq.md"
ck_no_free C2

ck_new unsourced
fx_write "$CK" plugins/ff/tests/s/verify.sh \
  '# run-all-depends: tests/lib/fx-tl.sh scripts/lib/fx-sl.sh' \
  'echo "tests/lib/fx-tl.sh と scripts/lib/fx-sl.sh は名前を出すだけ"'
ck_run
ck_line C3 "✗ s: 宣言した lib を source していない: tests/lib/fx-tl.sh"
ck_line C3 "✗ s: 宣言した lib を source していない: scripts/lib/fx-sl.sh"

ck_new dangling
fx_write "$CK" plugins/ff/tests/s/verify.sh \
  '# run-all-depends: docs/fx-missing.md docs/fx-nope/' \
  'true'
ck_run
ck_line C4 "✗ s: 宣言が実体に当たらない: docs/fx-missing.md"
ck_line C4 "✗ s: 宣言が実体に当たらない: docs/fx-nope/"

# 外したファイルの行そのものは参照に数えない（数えると「参照していない」が成立しない）
ck_new stale
fx_write "$CK" plugins/ff/tests/s/verify.sh \
  '# run-all-depends: docs/fx-guide.md' \
  '# run-all-not-depends: docs/fx-other.md 名前を出すだけ' \
  '# run-all-not-depends: docs/fx-uniq.md' \
  '# run-all-not-depends: docs/fx-ghost.md 名前を出すだけ' \
  'cat "$ROOT/docs/fx-guide.md"' \
  'echo docs/fx-uniq.md'
ck_run
ck_line C5 "✗ s: run-all-not-depends で外したファイルを参照していない: docs/fx-other.md"
ck_line C5 "✗ s: run-all-not-depends に理由が無い: docs/fx-uniq.md"
ck_line C5 "✗ s: run-all-not-depends のファイルが実在しない: docs/fx-ghost.md"

ck_new empty
fx_write "$CK" plugins/ff/tests/s/verify.sh '# run-all-depends:' 'true'
ck_run
ck_line C6 "✗ s: 宣言の行にパターンが無い"

# 違反の件数を数えて出す（要約の行を読む側が件数で判断できること）
if has "$OUT" "changed-select check: declared=1 violations=1"; then ok "C7: 要約の行に宣言数と違反数が出る"; else bad "C7: 要約の行が無い・数が違う（$(oneline "$OUT")）"; fi

# 判定不能は終了コード 2（0 件を「違反なし」へ倒さない）
c8_expect2() { # <ラベル> <説明> <check の引数>...
  local label="$1" what="$2" rc
  shift 2
  if GIT_CEILING_DIRECTORIES="$WORK" bash "$SEL" check "$@" >/dev/null 2>&1; then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -eq 2 ]; then ok "${label}: ${what} → 判定不能（rc=2）"; else bad "${label}: ${what} → rc=${rc}（2 でない）"; fi
}
NOGIT="$WORK/nogit"
fx_write "$NOGIT" plugins/ff/tests/s/verify.sh '# run-all-depends: docs/fx-guide.md' 'true'
c8_expect2 C8 "git の無い木" --root "$NOGIT" --tests-dir "$NOGIT/plugins/ff/tests" --plugin-prefix plugins/ff/
ck_new nosuite
rm -rf "$CK/plugins/ff/tests/free"
c8_expect2 C8 "suite のファイルが 0 件の tests" --root "$CK" --tests-dir "$CK/plugins/ff/tests" --plugin-prefix plugins/ff/
c8_expect2 C8 "実在しない tests" --root "$CK" --tests-dir "$CK/plugins/ff/no-such-tests" --plugin-prefix plugins/ff/
ck_new notracked
fx_write "$CK" .gitignore '*'
c8_expect2 C8 "追跡下のファイルが 0 件の木" --root "$CK" --tests-dir "$CK/plugins/ff/tests" --plugin-prefix plugins/ff/

# 別の基点から書いたファイル形の語（変数 + サブディレクトリ相対）は、成分の境界の接尾辞で当たる実体すべてを
# 要求する（derive の字面の照合はこの語で選んでいたので、宣言へ移すときに落とさない）。ディレクトリの語は要求しない
ck_new suffix
fx_write "$CK" plugins/ff/docs-template/05-ops/fx-deep.md 'd'
fx_write "$CK" docs/05-ops/fx-deep.md 'd'
fx_write "$CK" plugins/ff/tests/s/verify.sh \
  '# run-all-depends: docs/fx-guide.md' \
  'DOCS="$ROOT/docs-template"' \
  'cat "$ROOT/docs/fx-guide.md" "$DOCS/05-ops/fx-deep.md"' \
  'ls "$DOCS/05-ops/"'
ck_run
ck_line C9 "✗ s: 宣言に無い参照: plugins/ff/docs-template/05-ops/fx-deep.md"
ck_line C9 "✗ s: 宣言に無い参照: docs/05-ops/fx-deep.md"
fx_write "$CK" plugins/ff/tests/s/verify.sh \
  '# run-all-depends: docs/fx-guide.md docs-template/05-ops/fx-deep.md /docs/05-ops/fx-deep.md' \
  'DOCS="$ROOT/docs-template"' \
  'cat "$ROOT/docs/fx-guide.md" "$DOCS/05-ops/fx-deep.md"' \
  'ls "$DOCS/05-ops/"'
ck_run
if [ "$RC" -eq 0 ] && has "$OUT" "declared=1 violations=0"; then
  ok "C9: 接尾辞で当たる実体を宣言で覆えば通る（ディレクトリの語は要求しない）"
else
  bad "C9: 接尾辞の実体を覆った宣言が通らない（rc=${RC}。出力: $(oneline "$OUT")）"
fi

# run-all-depends の無い suite の run-all-not-depends は、選択も照合も変えないので赤にする
ck_new notdep-only
fx_write "$CK" plugins/ff/tests/s/verify.sh \
  '# run-all-not-depends: docs/fx-other.md 名前を出すだけ' \
  'echo docs/fx-other.md'
ck_run
ck_line C10 "✗ s: run-all-depends が無いのに run-all-not-depends がある"

# 変数のディレクトリに続くファイル名: プラグインの中で 1 つなら参照として要求し、2 つ以上なら
# どれを使うかを宣言で決めさせる
ck_new varname
fx_write "$CK" plugins/ff/tests/fx-runner.sh 'true'
fx_write "$CK" plugins/ff/docs/a/fx-dup.md 'a'
fx_write "$CK" plugins/ff/docs/b/fx-dup.md 'b'
fx_write "$CK" plugins/ff/tests/s/verify.sh \
  '# run-all-depends: docs/fx-guide.md' \
  'bash "$TESTS/fx-runner.sh"' \
  'cat "$DOCS/fx-dup.md" "$ROOT/docs/fx-guide.md"'
ck_run
ck_line C11 "✗ s: 宣言に無い参照: plugins/ff/tests/fx-runner.sh"
ck_line C11 "✗ s: 1 つに決まらない名前の参照: fx-dup.md（候補 2 件"
fx_write "$CK" plugins/ff/tests/s/verify.sh \
  '# run-all-depends: docs/fx-guide.md tests/fx-runner.sh docs/a/fx-dup.md' \
  'bash "$TESTS/fx-runner.sh"' \
  'cat "$DOCS/fx-dup.md" "$ROOT/docs/fx-guide.md"'
ck_run
if [ "$RC" -eq 0 ] && has "$OUT" "declared=1 violations=0"; then
  ok "C11: 候補のどれか 1 つを宣言で覆えば通る"
else
  bad "C11: 候補を覆った宣言が通らない（rc=${RC}。出力: $(oneline "$OUT")）"
fi

# リポジトリ相対とプラグイン相対の両方に同じ相対パスがあるときは、両方を要求する
ck_new both
fx_write "$CK" scripts/fx-both.sh 'true'
fx_write "$CK" plugins/ff/scripts/fx-both.sh 'true'
fx_write "$CK" plugins/ff/tests/s/verify.sh \
  '# run-all-depends: /scripts/fx-both.sh' \
  'bash scripts/fx-both.sh'
ck_run
ck_line C12 "✗ s: 宣言に無い参照: plugins/ff/scripts/fx-both.sh"

# 変数のディレクトリに続く名前がプラグインの中に無ければ、リポジトリ全体の同名を要求する
ck_new rootscript
fx_write "$CK" scripts/fx-root.sh 'true'
fx_write "$CK" plugins/ff/tests/s/verify.sh \
  '# run-all-depends: docs/fx-guide.md' \
  'cat "$ROOT/docs/fx-guide.md"' \
  'bash "$SCRIPTS/fx-root.sh"'
ck_run
ck_line C13 "✗ s: 宣言に無い参照: scripts/fx-root.sh"

# source の行の末尾のコメントに書いた名前は「source している」に数えない
ck_new trailing
fx_write "$CK" plugins/ff/tests/lib/fx-tl2.sh 'fx_tl2() { :; }'
fx_write "$CK" plugins/ff/tests/s/verify.sh \
  '# run-all-depends: tests/lib/fx-tl.sh tests/lib/fx-tl2.sh' \
  '. "$ROOT/tests/lib/fx-tl.sh"  # fx-tl2.sh は説明だけ'
ck_run
ck_line C14 "✗ s: 宣言した lib を source していない: tests/lib/fx-tl2.sh"

# ── 実体 ──────────────────────────────────────────────────────────────────
echo "== live"
PLUGIN_DIR="$(cd "$TESTS_DIR/.." && pwd -P)"
if ! REPO="$(git -C "$PLUGIN_DIR" rev-parse --show-toplevel 2>/dev/null)" || [ -z "$REPO" ]; then
  bad "L1: git の作業ツリーの外なので実体を照合できない（判定不能）"
elif [ ! -d "$REPO/oss/ff-dev-toolkit" ]; then
  # 公開リポジトリの配置（ルートは oss/ff-dev-toolkit の中身で、oss/ 階層が無い）では、開発元のリポジトリルートの
  # ファイルを指す宣言と照合の行が実体に当たらないので、L1・L2 は成立しない（公開 workflow でも除外している）
  echo "  ○ skip: L1・L2 は開発元のリポジトリ配置でだけ成立する検査のため未実行（宣言と照合の行が開発元のリポジトリルートのファイルを指す）"
else
  PFX="$(git -C "$PLUGIN_DIR" rev-parse --show-prefix 2>/dev/null)"
  OUT="$(bash "$SEL" check --root "$REPO" --tests-dir "$TESTS_DIR" --plugin-prefix "$PFX" 2>"$WORK/err")"
  RC=$?
  declared="$(printf '%s\n' "$OUT" | sed -n 's/^changed-select check: declared=\([0-9][0-9]*\) violations=.*/\1/p')"
  if [ "$RC" -ne 0 ]; then
    bad "L1: 実体の宣言が check を通らない（rc=${RC}）"
    printf '%s\n' "$OUT" "$(cat "$WORK/err")" | sed 's/^/      /' >&2
  elif [ -z "$declared" ] || [ "$declared" -lt 1 ]; then
    bad "L1: 実体から宣言を 1 件も読めない（本 suite 自身の宣言も読めていない。出力: $(oneline "$OUT")）"
  else
    ok "L1: 実体の宣言 ${declared} 件が check を通る"
  fi
  # L2: 選択の漏れの回帰検査。宣言のある suite の行が、実体のランナーの選択で選ばれる。census-878 は Issue `#878`
  # の census、expect-not-relayed は利用側の逆引きが中継しない（照合も字面で検出しない）依存の代表
  for expect_file in census-878.tsv expect-not-relayed.tsv; do
    if bash "$SIM" --expect "$SUITE_DIR/data/$expect_file" > "$WORK/out" 2> "$WORK/err"; then RC=0; else RC=$?; fi
    OUT="$(cat "$WORK/out")"
    summary="$(printf '%s\n' "$OUT" | sed -n 's/^expect: //p')"
    if [ "$RC" -eq 0 ] && [ -n "$summary" ]; then
      ok "L2: ${expect_file} の行が漏れない（${summary}）"
    else
      bad "L2: ${expect_file} の行が選ばれない、または判定できない（rc=${RC}）"
      printf '%s\n' "$OUT" "$(cat "$WORK/err")" | grep -v '^ok' | sed 's/^/      /' >&2
    fi
  done
fi

# ── simulate.sh ───────────────────────────────────────────────────────────
echo "== simulate"
sim_rc() { # <引数>...  simulate.sh の終了コードだけを RC に受ける（ランナーへ届く前に止まる引数だけを渡す）
  if bash "$SIM" "$@" >/dev/null 2>"$WORK/err"; then RC=0; else RC=$?; fi
  ERR="$(cat "$WORK/err")"
}
sim_rc --limit x
if [ "$RC" -eq 64 ]; then ok "S1: 整数でない --limit は終了コード 64"; else bad "S1: 整数でない --limit で rc=${RC}"; fi
sim_rc --md-only 1
if [ "$RC" -eq 64 ]; then ok "S2: --max-md の無い --md-only は終了コード 64"; else bad "S2: --max-md の無い --md-only で rc=${RC}"; fi
sim_rc --eval "$WORK/no-such-eval.tsv"
if [ "$RC" -eq 2 ] && has "$ERR" "判定不能"; then ok "S3: 読めない評価集合は判定不能（rc=2）"; else bad "S3: 読めない評価集合で rc=${RC}（${ERR}）"; fi
run_bounded 10 bash "$SIM" --limit
if [ "$RC" -eq 64 ]; then ok "S1: 値の無い --limit は終了コード 64"; else bad "S1: 値の無い --limit で rc=${RC}（124 は止まらなかった）"; fi

# 集計: ランナーと登録一覧を差し替え（代役のランナーは決まった select-only の行だけを返す）、全件比・
# 端数を切り捨てない閾値の判定・件数の突き合わせを確かめる。評価集合の SHA はこのリポジトリの、マージで
# ない直近のコミット（マージコミットは変更一覧が空になり、simulate.sh が判定不能で止まる）
SIMD="$WORK/sim"
fx_write "$SIMD" tests/fx-a/verify.sh 'true'
fx_write "$SIMD" tests/fx-b/verify.sh 'true'
chmod +x "$SIMD/tests/fx-a/verify.sh" "$SIMD/tests/fx-b/verify.sh"
fx_write "$SIMD" stub-runner.sh \
  'case "${FX_STUB:-}" in' \
  '  pass) printf "%s\n" "select-only: mode=changed selected=1 registered=2" "select-only: suite=fx-a" ;;' \
  '  mismatch) printf "%s\n" "select-only: mode=changed selected=2 registered=2" "select-only: suite=fx-a" ;;' \
  '  full) printf "%s\n" "select-only: mode=full reason=fx" ;;' \
  '  fullish) printf "%s\n" "select-only: mode=fullish" ;;' \
  '  bypath)' \
  '    printf "%s\n" call >> "$FX_COUNT"' \
  '    if grep -qxF "$FX_WANT" "$FF_RUN_ALL_CHANGED_FILES_FROM"; then' \
  '      printf "%s\n" "select-only: mode=changed selected=1 registered=2" "select-only: suite=$FX_SUITE"' \
  '    else' \
  '      printf "%s\n" "select-only: mode=changed selected=0 registered=2"' \
  '    fi' \
  '    ;;' \
  '  *) exit 3 ;;' \
  'esac'
if HEAD_SHA="$(git -C "$SUITE_DIR" rev-list --no-merges -n 1 HEAD 2>/dev/null)" && [ -n "$HEAD_SHA" ]; then
  printf '%s\t%s\n' "$HEAD_SHA" 1 > "$SIMD/eval.tsv"
  sim_run() { # <代役の振る舞い> <fx-a の秒数> <simulate.sh の引数>...
    local stub="$1" sa="$2"
    shift 2
    printf '%s\t%s\n' fx-a "$sa" fx-b $((1000 - sa)) > "$SIMD/secs.tsv"
    if FX_STUB="$stub" bash "$SIM" --runner "$SIMD/stub-runner.sh" --tests-dir "$SIMD/tests" \
      --eval "$SIMD/eval.tsv" --secs "$SIMD/secs.tsv" "$@" > "$WORK/out" 2> "$WORK/err"; then
      RC=0
    else
      RC=$?
    fi
    OUT="$(cat "$WORK/out")"
    ERR="$(cat "$WORK/err")"
  }
  sim_run pass 201 --md-only 1 --max-md 20
  if [ "$RC" -eq 1 ] && has "$OUT" "上限 20% を超えた: 1=20.1%"; then
    ok "S5: 全件比 20.1% は上限 20% を超えた（端数を切り捨てて通さない）"
  else
    bad "S5: 20.1% で rc=${RC}（$(oneline "$OUT")）"
  fi
  sim_run pass 200 --md-only 1 --max-md 20
  if [ "$RC" -eq 0 ] && has "$OUT" "$(printf '1\t20.0%%\tchanged\t1')"; then ok "S5: ちょうど 20.0% は上限 20% に収まる"; else bad "S5: 20.0% で rc=${RC}（$(oneline "$OUT")）"; fi
  sim_run pass 201 --max-avg 20
  if [ "$RC" -eq 1 ] && has "$OUT" "平均の全件比 20.1% が上限 20% を超えた"; then ok "S6: 平均 20.1% は上限 20% を超えた"; else bad "S6: 平均 20.1% で rc=${RC}（$(oneline "$OUT")）"; fi
  sim_run pass 201 --max-avg 08
  if [ "$RC" -eq 1 ] && has "$OUT" "上限 8% を超えた"; then ok "S10: 先頭が 0 の閾値（08）も 10 進数で比べる"; else bad "S10: --max-avg 08 で rc=${RC}（$(oneline "$OUT") / $(oneline "$ERR")）"; fi
  sim_run mismatch 201
  if [ "$RC" -eq 2 ] && has "$ERR" "選択の件数が合わない"; then ok "S7: 選んだ件数と suite の行の数が合わない回は判定不能"; else bad "S7: 件数の食い違いで rc=${RC}（$(oneline "$ERR")）"; fi
  sim_run full 201
  if [ "$RC" -eq 0 ] && has "$OUT" "$(printf '1\t100.0%%\tfull\t2')"; then ok "S8: 全件へ倒れた PR は全件比 100% で登録一覧の数を数える"; else bad "S8: 全件の回で rc=${RC}（$(oneline "$OUT")）"; fi
  sim_run broken 201
  if [ "$RC" -eq 2 ] && has "$ERR" "選択を返さない"; then ok "S9: ランナーが選択を返さない回は判定不能"; else bad "S9: ランナーの失敗で rc=${RC}（$(oneline "$ERR")）"; fi
else
  bad "S5〜S9: このリポジトリのマージでないコミットを読めない（判定不能）"
fi

# --expect: 宣言のある suite の行だけを照合する（代役のランナーは fx-a だけを選ぶ）。変更パスはこのリポジトリに
# 実在する select.sh をリポジトリルート相対（/ 始まり）で書く — 代役の tests はリポジトリの外にあり、プラグイン
# ルート相対の行はリポジトリルート相対として解決される
if ! live_pfx="$(git -C "$SUITE_DIR" rev-parse --show-prefix 2>/dev/null)" || [ -z "$live_pfx" ]; then
  bad "S11〜S26: このリポジトリの中の select.sh の位置を求められない（判定不能）"
else
  SIMX="$WORK/simx"
  fx_write "$SIMX" tests/fx-a/verify.sh '# run-all-depends: tests/fx-a/' 'true'
  fx_write "$SIMX" tests/fx-b/verify.sh 'true'
  fx_write "$SIMX" tests/fx-c/verify.sh '# run-all-depends: tests/fx-c/' 'true'
  chmod +x "$SIMX/tests/fx-a/verify.sh" "$SIMX/tests/fx-b/verify.sh" "$SIMX/tests/fx-c/verify.sh"
  sim_expect() { # <代役の振る舞い> <行>...
    local stub="$1"
    shift
    printf '%s\n' "$@" > "$SIMX/expect.tsv"
    if FX_STUB="$stub" bash "$SIM" --runner "$SIMD/stub-runner.sh" --tests-dir "$SIMX/tests" \
      --expect "$SIMX/expect.tsv" > "$WORK/out" 2> "$WORK/err"; then
      RC=0
    else
      RC=$?
    fi
    OUT="$(cat "$WORK/out")"
    ERR="$(cat "$WORK/err")"
  }
  live_rel="/${live_pfx}select.sh"
  sim_expect pass "$(printf '%s\t%s\t%s' "$live_rel" fx-a x1)" "$(printf '%s\t%s\t%s' "$live_rel" fx-b x2)"
  if [ "$RC" -eq 0 ] && has "$OUT" "expect: checked=1 skipped=1 miss=0"; then
    ok "S11: 宣言のある suite の行だけを照合し、宣言の無い suite の行は飛ばす"
  else
    bad "S11: rc=${RC}（$(oneline "$OUT") / $(oneline "$ERR")）"
  fi
  sim_expect pass "$(printf '%s\t%s\t%s' "$live_rel" fx-c x3)"
  if [ "$RC" -eq 1 ] && has "$OUT" "$(printf '✗ 漏れ\tfx-c\t')"; then
    ok "S12: 宣言のある suite が選ばれない行は終了コード 1 で suite とパスを名指す"
  else
    bad "S12: 漏れの回で rc=${RC}（$(oneline "$OUT")）"
  fi
  sim_expect full "$(printf '%s\t%s\t%s' "$live_rel" fx-c x4)"
  if [ "$RC" -eq 0 ] && has "$OUT" "全件へ倒れる: fx"; then ok "S13: 全件へ倒れる変更は選ばれたものとして数え、倒れた理由を添える"; else bad "S13: 全件の回で rc=${RC}（$(oneline "$OUT")）"; fi
  sim_expect pass "$(printf '%s\t%s\t%s' tests/changed-select/no-such-file.sh fx-a x5)"
  if [ "$RC" -eq 2 ] && has "$ERR" "実在しない"; then ok "S14: 実在しない変更パスの行（古い行）は判定不能"; else bad "S14: 古い行で rc=${RC}（$(oneline "$ERR")）"; fi
  sim_expect pass "$(printf '%s\t%s\t%s' "$live_rel" fx-b x6)"
  if [ "$RC" -eq 2 ] && has "$ERR" "照合した行が 0 件"; then ok "S15: 照合した行が 0 件の回は判定不能"; else bad "S15: 0 件の回で rc=${RC}（$(oneline "$ERR")）"; fi
  sim_expect pass "$(printf '%s\t%s\t%s' "$live_rel" fx-z x7)"
  if [ "$RC" -eq 2 ] && has "$ERR" "登録に無い"; then ok "S16: 登録に無い suite の行は判定不能"; else bad "S16: 未登録の suite で rc=${RC}（$(oneline "$ERR")）"; fi
  sim_expect pass "$(printf '%s\t%s' "$live_rel" fx-a)"
  if [ "$RC" -eq 2 ] && has "$ERR" "列が欠けている"; then ok "S17: 列の欠けた行は判定不能"; else bad "S17: 列の欠けた行で rc=${RC}（$(oneline "$ERR")）"; fi
  sim_expect broken "$(printf '%s\t%s\t%s' "$live_rel" fx-a x8)"
  if [ "$RC" -eq 2 ] && has "$ERR" "選択を返さない"; then ok "S18: --expect でもランナーが選択を返さない回は判定不能"; else bad "S18: rc=${RC}（$(oneline "$ERR")）"; fi
  sim_rc --expect "$SIMX/expect.tsv" --max-avg 50
  if [ "$RC" -eq 64 ]; then ok "S19: --expect と閾値のオプションは併用しない（64）"; else bad "S19: 併用で rc=${RC}"; fi
  # 改行で終わらない最終行も照合する（read が最終行を落とすと、検証を通った行が照合されないまま緑になる）
  printf '%s\n%s' "$(printf '%s\t%s\t%s' "$live_rel" fx-a x9)" "$(printf '%s\t%s\t%s' "$live_rel" fx-c x10)" > "$SIMX/expect.tsv"
  if FX_STUB=pass bash "$SIM" --runner "$SIMD/stub-runner.sh" --tests-dir "$SIMX/tests" --expect "$SIMX/expect.tsv" \
    > "$WORK/out" 2> "$WORK/err"; then RC=0; else RC=$?; fi
  OUT="$(cat "$WORK/out")"
  if [ "$RC" -eq 1 ] && has "$OUT" "expect: checked=2 skipped=0 miss=1"; then
    ok "S20: 改行で終わらない最終行も読み、照合する"
  else
    bad "S20: 最終行の改行なしで rc=${RC}（$(oneline "$OUT")）"
  fi
  sim_expect fullish "$(printf '%s\t%s\t%s' "$live_rel" fx-a x11)"
  if [ "$RC" -eq 2 ] && has "$ERR" "mode=fullish"; then ok "S21: モードが full / changed のどちらでもない出力は判定不能（前方一致で全件と取り違えない）"; else bad "S21: mode=fullish で rc=${RC}（$(oneline "$OUT") / $(oneline "$ERR")）"; fi
  sim_expect pass "$(printf '%s\t%s\t%s' /no-such-dir/no-such-file.sh fx-a x12)"
  if [ "$RC" -eq 2 ] && has "$ERR" "実在しない"; then ok "S22: リポジトリルート相対の古い行も判定不能（飛ばさない）"; else bad "S22: / 始まりの古い行で rc=${RC}（$(oneline "$OUT") / $(oneline "$ERR")）"; fi
  # 変更パスの解決: 実体の tests（宣言のある changed-select 自身）を登録一覧に使い、代役のランナーは変更一覧が
  # select.sh のリポジトリ相対パスと一致するときだけ選ぶ。プラグインルート相対の行（接頭辞を付ける）と / 始まりの
  # 行（そのまま）が同じパスへ解決され、同じパスが続く 2 行目はランナーを回し直さない
  : > "$WORK/count"
  printf '%s\n' "$(printf '%s\t%s\t%s' tests/changed-select/select.sh changed-select x13)" \
    "$(printf '%s\t%s\t%s' "$live_rel" changed-select x14)" > "$SIMX/expect.tsv"
  if FX_STUB=bypath FX_WANT="${live_rel#/}" FX_SUITE=changed-select FX_COUNT="$WORK/count" \
    bash "$SIM" --runner "$SIMD/stub-runner.sh" --tests-dir "$TESTS_DIR" --expect "$SIMX/expect.tsv" \
    > "$WORK/out" 2> "$WORK/err"; then RC=0; else RC=$?; fi
  OUT="$(cat "$WORK/out")"
  calls="$(grep -c . "$WORK/count")"
  if [ "$RC" -eq 0 ] && has "$OUT" "expect: checked=2 skipped=0 miss=0"; then
    ok "S23: プラグインルート相対の行と / 始まりの行が同じリポジトリ相対パスへ解決される"
  else
    bad "S23: パスの解決で rc=${RC}（$(oneline "$OUT") / $(oneline "$(cat "$WORK/err")")）"
  fi
  if [ "$calls" = 1 ]; then ok "S24: 同じ変更パスが続く行ではランナーを回し直さない"; else bad "S24: ランナーの呼び出し ${calls} 回（1 回のはず）"; fi
  # 読めない suite のファイルを「宣言なし」へ倒さない
  printf '%s\n' "$(printf '%s\t%s\t%s' "$live_rel" fx-a x15)" > "$SIMX/expect.tsv"
  chmod 000 "$SIMX/tests/fx-c/verify.sh"
  if [ -r "$SIMX/tests/fx-c/verify.sh" ]; then
    ok "S25: 読み取り権限を外しても読める実行環境（root 等）なので省略"
  else
    if FX_STUB=pass bash "$SIM" --runner "$SIMD/stub-runner.sh" --tests-dir "$SIMX/tests" --expect "$SIMX/expect.tsv" \
      > "$WORK/out" 2> "$WORK/err"; then RC=0; else RC=$?; fi
    if [ "$RC" -eq 2 ] && has "$(cat "$WORK/err")" "読めない"; then ok "S25: 読めない suite のファイルは判定不能（宣言なしへ倒さない）"; else bad "S25: 読めないファイルで rc=${RC}（$(oneline "$(cat "$WORK/err")")）"; fi
  fi
  chmod 755 "$SIMX/tests/fx-c/verify.sh"
  sim_expect mismatch "$(printf '%s\t%s\t%s' "$live_rel" fx-a x16)"
  if [ "$RC" -eq 2 ] && has "$ERR" "選択の件数が合わない"; then ok "S26: --expect でも選んだ件数と suite の行の数が合わない出力は判定不能"; else bad "S26: 件数の食い違いで rc=${RC}（$(oneline "$OUT") / $(oneline "$ERR")）"; fi
fi

EVAL="$SUITE_DIR/data/eval-set.tsv"
SECS="$SUITE_DIR/data/suite-seconds.tsv"
eval_bad="$(awk -F'\t' '$0 !~ /^#/ && !($1 ~ /^[0-9a-f]+$/ && length($1) == 40 && $2 ~ /^[0-9]+$/ && NF == 2) { print NR }' "$EVAL" 2>/dev/null | head -n 3 | tr '\n' ' ')"
eval_n="$(awk '$0 !~ /^#/ && NF > 0' "$EVAL" 2>/dev/null | wc -l | tr -d ' ')"
if [ -r "$EVAL" ] && [ -z "$eval_bad" ] && [ "${eval_n:-0}" -gt 0 ] \
  && awk -F'\t' '$2 == "2827" { a = 1 } $2 == "2828" { b = 1 } END { exit !(a && b) }' "$EVAL"; then
  ok "S4: 評価集合 ${eval_n} 本が <SHA><TAB><PR 番号> の形で、.md だけの PR（2827 / 2828）を含む"
else
  bad "S4: 評価集合の形が崩れている（不正な行: ${eval_bad:-なし} / 本数: ${eval_n:-0}）"
fi
secs_bad="$(awk -F'\t' '$0 !~ /^#/ && !($1 ~ /^[A-Za-z0-9_.-]+$/ && $2 ~ /^[0-9]+$/ && NF == 2) { print NR }' "$SECS" 2>/dev/null | head -n 3 | tr '\n' ' ')"
secs_n="$(awk '$0 !~ /^#/ && NF > 0' "$SECS" 2>/dev/null | wc -l | tr -d ' ')"
if [ -r "$SECS" ] && [ -z "$secs_bad" ] && [ "${secs_n:-0}" -gt 0 ]; then
  ok "S4: 秒数のスナップショット ${secs_n} 行が <suite><TAB><秒> の形"
else
  bad "S4: 秒数のスナップショットの形が崩れている（不正な行: ${secs_bad:-なし} / 行数: ${secs_n:-0}）"
fi

FF_REACHED_END=1
if [ "$FAIL" -gt 0 ]; then
  echo "✗ changed-select: ${FAIL} 件失敗（通過 ${PASS} 件）" >&2
  exit 1
fi
echo "✓ changed-select: ${PASS} 件すべて通過"
