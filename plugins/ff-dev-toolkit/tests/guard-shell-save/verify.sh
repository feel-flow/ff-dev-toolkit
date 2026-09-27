#!/usr/bin/env bash
# Runtime contract for the shell save guard hook (Issue `#1801` / OBS-042).
#
# 配布物 hooks/guard-shell-save.sh を stdin JSON（Write / Edit の PreToolUse 入力）で
# 直接駆動し、受け入れ条件の各分岐を固定する:
#   F. 発火（deny）: `.sh` への保存で 3 検出器のいずれかが**保存前に無かった**違反を出す
#      F1 Write + `$VAR` 直後のマルチバイト / F2 Edit + 同 / F3 Write + pipefail 配下の
#      `| grep -q` / F4 Edit で `| grep -q` を足す（`pipefail` の設定行は断片の外 = 保存後の
#      全体を組み立てて走査していることの固定）/ F5 Write + `| tail; echo $?` /
#      F6 Edit + 同 / F7 replace_all の全置換 / F8 deny 本文の案内（直し方・ACK・行番号）
#   N. 非発火（無出力 exit 0）: `${VAR}` 形 / `.sh` 以外 / 対象外ツール / 既存違反の持ち越し・
#      行番号の移動 / Edit ツール自体が失敗する Edit / 壊れた JSON / object でない tool_input /
#      `# pipefail-safe:` の行末除外
#   F9〜F16: 既存違反の複製 / 字義どおりの単一置換 / glob 文字 / 空の old_string / CRLF /
#      pipefail を後から足す Edit / 3 検出器の同時発火 / 検出器テストシームの無効化
#   A. 抜け道: hook の環境の FF_SHELL_SAVE_ACK=1 で通す
#   C. 判定不能は fail-closed（理由付き deny）: 検出器の不在 / awk の失敗 / 検出器出力の
#      解釈不能 / Edit 対象を読めない・NUL を含む / old_string が一致しない / ASDD ヘルパ不在 /
#      deny の JSON を作れない（exit 2）。ただし `.sh` 以外は検出器が壊れていても止めない
#   D. stdin の drain（PATH 空・ASDD ゲートの早期終了経路でも書き手へ EPIPE を返さない）
#   R. hooks.json の PreToolUse（Write|Edit matcher）登録と description の言及
#   M. 変異検出（コピーへ当てる）
#
# 変異検出（2026-09-27 実測。赤転しなかった変異は無し）:
#   `load_lib exit-code-guard.sh exit_code_scan` と `exit_hits` の走査を外したコピーは、
#   F5 と同形の deny が消えて M1 が赤になる。保存前の走査結果を空にした（既存違反も新規と
#   数える）コピーは、N5 と同形の素通しが deny に変わって M2 が赤になる。比較の鍵に行番号を
#   残したコピーは N9（行の移動）が deny になって M3 が赤になり、件数ではなく集合で突き合わせる
#   コピーは F9（既存違反の複製）が素通りになって M4 が赤になる。
# 空振り検出: どの入力にも 0 件を返す検出器スタブ（0 件一致。FF_GUARD_SHELL_SAVE_LIB_DIR で差し替え）を与えると F1〜F16・A2・C2・C8・M2・M3 の 27 件が赤になり、hook の実体が無いパス（対象の不在。FF_GUARD_SHELL_SAVE_TARGET）を与えると冒頭の実在検査で suite が rc=1 になる（実測 2026-09-27）。
#
# run-all-required: no — jq 不在での skip を許容する（兄弟の hook suite と同じ判断）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="${FF_GUARD_SHELL_SAVE_TARGET:-$PLUGIN_ROOT/hooks/guard-shell-save.sh}"
LIB_SRC="${FF_GUARD_SHELL_SAVE_LIB_DIR:-$PLUGIN_ROOT/tests/lib}"
# shellcheck source=../lib/asdd-gate-drain.sh
. "$SCRIPT_DIR/../lib/asdd-gate-drain.sh"
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"

[ -f "$TARGET" ] || { echo "✗ guard-shell-save.sh が見つかりません: ${TARGET}" >&2; exit 1; }
[ -f "$HOOKS_JSON" ] || { echo "✗ hooks.json が見つかりません: ${HOOKS_JSON}" >&2; exit 1; }
for lib in mbcs-guard.sh pipefail-grep-q.sh exit-code-guard.sh; do
  [ -f "$LIB_SRC/$lib" ] || { echo "✗ 検出器 ${lib} が見つかりません: ${LIB_SRC}" >&2; exit 1; }
done
if ! command -v jq >/dev/null 2>&1; then
  echo "○ skip: jq が見つからないためスキップ（guard-shell-save は未検査のままです）"
  exit 0
fi

if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/ff-guard-shell-save.XXXXXX" 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  TEST_TMP="$_ff_mktemp_out"
else
  echo "✗ 一時ディレクトリを作成できません: ${_ff_mktemp_out}" >&2
  exit 1
fi
REACHED_END=0
cleanup() {
  local rc=$?
  chmod -R u+rwX "$TEST_TMP" 2>/dev/null || true
  rm -rf "$TEST_TMP"
  if [ "$REACHED_END" -ne 1 ] && [ "$rc" -eq 0 ]; then
    echo "✗ guard-shell-save: 最後まで到達しませんでした" >&2
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

PASS=0
FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# 検査対象の hook を「隣に検出器を置いた」配置へ写す。hook は ../tests/lib から検出器を読み、
# 同じ directory から ASDD ゲートを source するので、その形のまま一時領域へ組む。
# <dir> <lib-dir|""> — lib-dir が空なら検出器を置かない（判定不能の経路）。
make_plugin() { # <dir> <lib-dir> [hook-file]
  local dir="$1" libs="$2" hook="${3:-$TARGET}"
  mkdir -p "$dir/hooks" "$dir/tests/lib"
  cp "$hook" "$dir/hooks/guard-shell-save.sh"
  cp "$PLUGIN_ROOT/hooks/asdd-hook-gate.sh" "$PLUGIN_ROOT/hooks/asdd-feature.mjs" "$dir/hooks/"
  if [ -n "$libs" ]; then
    cp "$libs/mbcs-guard.sh" "$libs/pipefail-grep-q.sh" "$libs/exit-code-guard.sh" "$dir/tests/lib/"
  fi
}
PLUG="$TEST_TMP/plug"
make_plugin "$PLUG" "$LIB_SRC"
HOOK="$PLUG/hooks/guard-shell-save.sh"
WORK="$TEST_TMP/work"
mkdir -p "$WORK/tests/x" "$WORK/scripts"

# 全角の閉じ括弧（U+FF09）。このファイル自体が検出器の走査対象なので、違反の綴りは
# 実行時に組み立てる（`$VAR` の直後へ直書きしない）。
FW="$(printf '\357\274\211')"
MB_BAD='echo "$VAR'"${FW}"'"'
MB_GOOD='echo "${VAR}'"${FW}"'"'
# 同じく、パイプ下流の quiet grep の綴りも実行時に組み立てる（tests/run-all/verify.sh の横断検査が
# このファイル自体の生の綴りを拾うため）。
GQ='grep -'"q"
PF_BAD='if printf "%s" "$s" | '"${GQ}"' needle; then :; fi'
EC_BAD='npm test 2>&1 | tail -1; echo "EXIT=$?"'

OUT=""
RC=0
DECISION=""
REASON=""

_decode() {
  DECISION="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)"
  REASON="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || true)"
}

run_json() { # <hook> <json> [NAME=VALUE ...]
  local hook="$1" json="$2"
  shift 2
  RC=0
  OUT="$(printf '%s' "$json" | env "$@" bash "$hook" 2>/dev/null)" || RC=$?
  _decode
}

write_json() { # <path> <content> [tool]
  jq -n --arg p "$1" --arg c "$2" --arg t "${3:-Write}" \
    '{tool_name: $t, tool_input: {file_path: $p, content: $c}, hook_event_name: "PreToolUse"}'
}
edit_json() { # <path> <old> <new> [replace_all]
  jq -n --arg p "$1" --arg o "$2" --arg n "$3" --argjson r "${4:-false}" \
    '{tool_name: "Edit", tool_input: {file_path: $p, old_string: $o, new_string: $n, replace_all: $r}, hook_event_name: "PreToolUse"}'
}

assert_fire() { # <label>
  if [ "$RC" -eq 0 ] && [ "$DECISION" = "deny" ]; then
    ok "$1"
  else
    bad "$1: exit=${RC} decision=[${DECISION}] out=[${OUT}]"
  fi
}
assert_pass() { # <label>
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    ok "$1"
  else
    bad "$1: exit=${RC} out=[${OUT}]"
  fi
}
assert_unavailable() { # <label>
  case "$REASON" in
    *判定不能*)
      if [ "$RC" -eq 0 ] && [ "$DECISION" = "deny" ]; then ok "$1"; return; fi ;;
  esac
  bad "$1: exit=${RC} decision=[${DECISION}] reason=[${REASON}]"
}

# 既存ファイル（Edit の対象）。pipefail の設定行を持ち、既存違反を 1 件含む。
EXISTING="$WORK/scripts/existing.sh"
printf '%s\n' '#!/usr/bin/env bash' 'set -o pipefail' "$MB_BAD" 'PLACEHOLDER' 'PLACEHOLDER' > "$EXISTING"
CLEAN="$WORK/scripts/clean.sh"
printf '%s\n' '#!/usr/bin/env bash' 'set -o pipefail' 'PLACEHOLDER' > "$CLEAN"

echo "guard-shell-save: 発火側（F）"
run_json "$HOOK" "$(write_json "$WORK/tests/x/verify.sh" "$(printf '%s\n' '#!/usr/bin/env bash' "$MB_BAD")")"
assert_fire "F1: Write で \$VAR 直後のマルチバイトを含む verify.sh は deny"
run_json "$HOOK" "$(edit_json "$CLEAN" 'PLACEHOLDER' "$MB_BAD")"
assert_fire "F2: 既存ファイルへの 1 行追記（Edit）でも \$VAR 直後のマルチバイトは deny"
run_json "$HOOK" "$(write_json "$WORK/scripts/pf.sh" "$(printf '%s\n' '#!/usr/bin/env bash' 'set -o pipefail' "$PF_BAD")")"
assert_fire "F3: Write で pipefail 配下のパイプ下流の quiet grep は deny"
run_json "$HOOK" "$(edit_json "$CLEAN" 'PLACEHOLDER' "$PF_BAD")"
assert_fire "F4: Edit の断片に pipefail が無くても、保存後の全体でパイプ下流の quiet grep を見て deny"
run_json "$HOOK" "$(write_json "$WORK/scripts/ec.sh" "$(printf '%s\n' '#!/usr/bin/env bash' "$EC_BAD")")"
assert_fire "F5: Write で | tail の直後の \$? 読みは deny"
run_json "$HOOK" "$(edit_json "$CLEAN" 'PLACEHOLDER' "$EC_BAD")"
assert_fire "F6: Edit で | tail の直後の \$? 読みは deny"
run_json "$HOOK" "$(edit_json "$EXISTING" 'PLACEHOLDER' 'echo "$NEW'"${FW}"'"' true)"
assert_fire "F7: replace_all の全置換で入る違反も deny"
F7_REASON="$REASON"
case "$F7_REASON" in
  *'4:echo "$NEW'*'5:echo "$NEW'*) ok "F7: replace_all の 2 箇所がどちらも保存後の行番号付きで報告される" ;;
  *) bad "F7: replace_all の 2 箇所が報告されない: [${REASON}]" ;;
esac

run_json "$HOOK" "$(edit_json "$EXISTING" 'PLACEHOLDER' "$MB_BAD")"
assert_fire "F9: 既存違反と同じ綴りの行を複製する Edit も deny（件数で突き合わせる）"
run_json "$HOOK" "$(edit_json "$EXISTING" 'PLACEHOLDER' 'echo "$NEW'"${FW}"'" # a&b')"
case "$REASON" in
  *'4:echo "$NEW'*'a&b'*)
    case "$REASON" in
      *'5:echo "$NEW'*) bad "F10: replace_all=false なのに 2 箇所目まで置換された: [${REASON}]" ;;
      *) ok "F10: replace_all=false は先頭 1 箇所だけを字義どおり（& を展開せず）置換する" ;;
    esac ;;
  *) bad "F10: 字義どおりの単一置換になっていない: [${REASON}]" ;;
esac
GLOB="$WORK/scripts/glob.sh"
printf '%s\n' '#!/usr/bin/env bash' 'x=[*]' 'x=a' > "$GLOB"
run_json "$HOOK" "$(edit_json "$GLOB" 'x=[*]' "$MB_BAD")"
case "$REASON" in
  *'2:echo "$VAR'*) ok "F11: glob 文字を含む old_string も字義どおりに一致させる" ;;
  *) bad "F11: glob 文字を含む old_string の置換位置が違う: [${REASON}]" ;;
esac
EMPTYF="$WORK/scripts/empty.sh"
: > "$EMPTYF"
run_json "$HOOK" "$(edit_json "$EMPTYF" '' "$(printf '%s\n' 'set -o pipefail' "$PF_BAD")")"
assert_fire "F12: 空ファイルへの空の old_string（Edit で中身を入れる）も deny"
run_json "$HOOK" "$(edit_json "$WORK/scripts/new-by-edit.sh" '' "$MB_BAD")"
assert_fire "F12: 存在しないファイルへの空の old_string（Edit で新規作成）も deny"
CRLF="$WORK/scripts/crlf.sh"
printf '#!/usr/bin/env bash\r\nPLACEHOLDER\r\n' > "$CRLF"
run_json "$HOOK" "$(edit_json "$CRLF" "$(printf '%s\n%s' '#!/usr/bin/env bash' 'PLACEHOLDER')" "$(printf '%s\n%s' '#!/usr/bin/env bash' "$MB_BAD")")"
assert_fire "F13: CRLF のファイルへ LF の old_string で当てる Edit も CR を除いて照合し deny"
PFLATE="$WORK/scripts/pf-late.sh"
printf '%s\n' '#!/usr/bin/env bash' "$PF_BAD" > "$PFLATE"
run_json "$HOOK" "$(edit_json "$PFLATE" '#!/usr/bin/env bash' "$(printf '%s\n%s' '#!/usr/bin/env bash' 'set -o pipefail')")"
assert_fire "F14: 既存の quiet grep の上へ pipefail を足す Edit（編集行そのものは無違反）も deny"
run_json "$HOOK" "$(write_json "$WORK/scripts/all3.sh" "$(printf '%s\n' '#!/usr/bin/env bash' 'set -o pipefail' "$MB_BAD" "$MB_BAD" "$MB_BAD" "$MB_BAD" "$PF_BAD" "$EC_BAD")")"
n_sections="$(printf '%s\n' "$REASON" | grep -c '^■' || true)"
n_mb="$(printf '%s\n' "$REASON" | grep -c '^    | [0-9]*:echo "\$VAR' || true)"
if [ "$n_sections" -eq 3 ] && [ "$n_mb" -eq 3 ]; then
  ok "F15: 3 検出器が同時に当たると 3 節すべてを出し、各節は先頭 3 件に絞る"
else
  bad "F15: 節=${n_sections}（期待 3）/ mbcs の列挙=${n_mb}（期待 3）: [${REASON}]"
fi
run_json "$HOOK" "$(write_json "$WORK/tests/x/verify.sh" "$(printf '%s\n' '#!/usr/bin/env bash' "$MB_BAD")")" FF_MBCS_AWK=true FF_PIPEFAIL_GREP_Q_AWK=true FF_EXIT_CODE_AWK=true
assert_fire "F16: セッション環境に残った検出器の awk 差し替え（FF_*_AWK=true）では空振りしない"

run_json "$HOOK" "$(write_json "$WORK/tests/x/verify.sh" "$(printf '%s\n' '#!/usr/bin/env bash' "$MB_BAD")")"
case "$REASON" in
  *'${VAR}'*) ok "F8: deny 本文が \${VAR} 形への直し方を案内する" ;;
  *) bad "F8: \${VAR} 形の案内が無い: [${REASON}]" ;;
esac
case "$REASON" in
  *FF_SHELL_SAVE_ACK=1*) ok "F8: deny 本文が抜け道 FF_SHELL_SAVE_ACK=1 を案内する" ;;
  *) bad "F8: 抜け道の案内が無い: [${REASON}]" ;;
esac
case "$REASON" in
  *'2:echo "$VAR'*) ok "F8: deny 本文が違反を保存後の開始行付きの実値で示す" ;;
  *) bad "F8: 違反の実値が無い: [${REASON}]" ;;
esac
run_json "$HOOK" "$(write_json "$WORK/scripts/pf.sh" "$(printf '%s\n' '#!/usr/bin/env bash' 'set -o pipefail' "$PF_BAD")")"
case "$REASON" in
  *'pipefail-safe'*) ok "F8: pipefail の deny 本文が行末除外 # pipefail-safe: を案内する" ;;
  *) bad "F8: pipefail-safe の案内が無い: [${REASON}]" ;;
esac
run_json "$HOOK" "$(write_json "$WORK/scripts/ec.sh" "$(printf '%s\n' '#!/usr/bin/env bash' "$EC_BAD")")"
case "$REASON" in
  *'exit $rc'*) ok "F8: 終了コードの deny 本文が exit \$rc までの伝播を案内する" ;;
  *) bad "F8: exit \$rc の案内が無い: [${REASON}]" ;;
esac

echo "guard-shell-save: 非発火側（N）"
run_json "$HOOK" "$(write_json "$WORK/tests/x/verify.sh" "$(printf '%s\n' '#!/usr/bin/env bash' "$MB_GOOD")")"
assert_pass "N1: \${VAR} 形は素通し"
run_json "$HOOK" "$(write_json "$WORK/tests/x/notes.md" "$MB_BAD")"
assert_pass "N2: .sh 以外（.md）は素通し"
run_json "$HOOK" "$(write_json "$WORK/tests/x/verify.sh.bak" "$MB_BAD")"
assert_pass "N2: .sh で終わらないパス（.sh.bak）は素通し"
run_json "$HOOK" "$(write_json "$WORK/tests/x/verify.sh" "$MB_BAD" MultiEdit)"
assert_pass "N3: 対象外ツール（MultiEdit）は素通し"
run_json "$HOOK" "$(write_json "$WORK/tests/x/verify.sh" "$MB_BAD" Read)"
assert_pass "N3: 対象外ツール（Read）は素通し"
run_json "$HOOK" "$(edit_json "$EXISTING" 'PLACEHOLDER' 'echo ok')"
assert_pass "N5: 既存違反の持ち越し（編集箇所は無違反）は素通し"
run_json "$HOOK" "$(write_json "$EXISTING" "$(cat "$EXISTING")")"
assert_pass "N5: Write で同じ内容を書き直す（既存違反だけ）は素通し"
run_json "$HOOK" "$(edit_json "$WORK/scripts/missing.sh" 'PLACEHOLDER' "$MB_BAD")"
assert_pass "N6: 対象ファイルが無いのに old_string が空でない Edit（ツール自体が失敗する）は素通し"
run_json "$HOOK" "$(edit_json "$CLEAN" '' "$MB_BAD")"
assert_pass "N6: 空でないファイルへの空の old_string（ツール自体が失敗する）は素通し"
# 既存違反より上へ行を挿入する（既存違反の行番号だけが動く）。
run_json "$HOOK" "$(edit_json "$EXISTING" 'set -o pipefail' "$(printf '%s\n%s\n%s' 'set -o pipefail' 'echo a' 'echo b')")"
assert_pass "N9: 既存違反の行番号が動くだけの Edit は素通し（比較の鍵は行番号を含まない）"
run_json "$HOOK" "$(jq -n --arg p "$WORK/tests/x/verify.sh" '{tool_name: "Write", tool_input: "not-an-object", file_path: $p}')"
assert_pass "N10: tool_input が object でない入力は対象外として素通し（実行時エラーで fail-open に紛れない）"
run_json "$HOOK" 'not-json {"file_path":"a.sh"}'
assert_pass "N7: 壊れた stdin JSON は無出力 exit 0"
run_json "$HOOK" "$(write_json "$WORK/scripts/pf.sh" "$(printf '%s\n' '#!/usr/bin/env bash' 'set -o pipefail' "${PF_BAD} # pipefail-safe: 1 行の固定文字列")")"
assert_pass "N8: 行末 # pipefail-safe: の除外は検出器の規定どおり素通し"

echo "guard-shell-save: 抜け道（A）"
run_json "$HOOK" "$(write_json "$WORK/tests/x/verify.sh" "$(printf '%s\n' '#!/usr/bin/env bash' "$MB_BAD")")" FF_SHELL_SAVE_ACK=1
assert_pass "A1: hook の環境の FF_SHELL_SAVE_ACK=1 で通す"
run_json "$HOOK" "$(write_json "$WORK/tests/x/verify.sh" "$(printf '%s\n' '#!/usr/bin/env bash' "$MB_BAD")")" FF_SHELL_SAVE_ACK=0
assert_fire "A2: FF_SHELL_SAVE_ACK=0 は抜け道にならない"

echo "guard-shell-save: 判定不能は fail-closed（C）"
NOLIB="$TEST_TMP/nolib"
make_plugin "$NOLIB" ""
run_json "$NOLIB/hooks/guard-shell-save.sh" "$(write_json "$WORK/tests/x/verify.sh" "$MB_GOOD")"
assert_unavailable "C1: 検出器が無い配置での .sh 保存は判定不能の deny"
run_json "$NOLIB/hooks/guard-shell-save.sh" "$(write_json "$WORK/tests/x/notes.md" "$MB_BAD")"
assert_pass "C1: 検出器が無くても .sh 以外の保存は止めない"
AWK_SHIM="$TEST_TMP/awk-shim"
mkdir -p "$AWK_SHIM"
printf '%s\n' '#!/bin/sh' 'cat >/dev/null 2>&1; exit 2' > "$AWK_SHIM/awk"
chmod +x "$AWK_SHIM/awk"
run_json "$HOOK" "$(write_json "$WORK/tests/x/verify.sh" "$MB_GOOD")" PATH="$AWK_SHIM:$PATH"
assert_unavailable "C2: 走査（awk）の失敗は判定不能の deny"
STUB="$TEST_TMP/stub-garbage"
make_plugin "$STUB" "$LIB_SRC"
printf '%s\n' 'mbcs_scan() { cat >/dev/null; echo "garbage-without-line-number"; }' >> "$STUB/tests/lib/mbcs-guard.sh"
run_json "$STUB/hooks/guard-shell-save.sh" "$(write_json "$WORK/tests/x/verify.sh" "$MB_GOOD")"
assert_unavailable "C3: 検出器の出力を解釈できないときは判定不能の deny"
UNREAD="$WORK/scripts/unreadable.sh"
printf '%s\n' '#!/usr/bin/env bash' 'PLACEHOLDER' > "$UNREAD"
chmod 000 "$UNREAD"
if [ -r "$UNREAD" ]; then
  echo "  ○ skip: 権限を落としても読めるため（root 実行など）C4 は未検査"
else
  run_json "$HOOK" "$(edit_json "$UNREAD" 'PLACEHOLDER' 'echo ok')"
  assert_unavailable "C4: Edit 対象を読めないときは判定不能の deny"
fi
chmod 644 "$UNREAD"
run_json "$HOOK" "$(edit_json "$CLEAN" 'NOT-THERE' "$MB_BAD")"
assert_unavailable "C5: CR 除去後も old_string がバイト一致しない Edit は判定不能の deny（引用符の正規化で保存されうる）"
NULF="$WORK/scripts/nul.sh"
printf '#!/usr/bin/env bash\n\000PLACEHOLDER\n' > "$NULF"
run_json "$HOOK" "$(edit_json "$NULF" '#!/usr/bin/env bash' '#!/bin/bash')"
assert_unavailable "C6: NUL を含み全体を読めない Edit 対象は判定不能の deny"
NOGATE="$TEST_TMP/nogate"
make_plugin "$NOGATE" "$LIB_SRC"
rm -f "$NOGATE/hooks/asdd-hook-gate.sh"
run_json "$NOGATE/hooks/guard-shell-save.sh" "$(write_json "$WORK/tests/x/verify.sh" "$MB_GOOD")"
assert_unavailable "C7: ASDD ヘルパが読めないときの .sh 保存は判定不能の deny"
run_json "$NOGATE/hooks/guard-shell-save.sh" "$(write_json "$WORK/tests/x/notes.md" "$MB_BAD")"
assert_pass "C7: ASDD ヘルパが読めなくても .sh 以外は止めない"
JQ_REAL="$(command -v jq)"
JQ_SHIM="$TEST_TMP/jq-shim"
mkdir -p "$JQ_SHIM"
printf '%s\n' '#!/bin/sh' 'for a in "$@"; do [ "$a" = "-n" ] && exit 1; done' "exec \"${JQ_REAL}\" \"\$@\"" > "$JQ_SHIM/jq"
chmod +x "$JQ_SHIM/jq"
RC=0
ERR="$(printf '%s' "$(write_json "$WORK/tests/x/verify.sh" "$(printf '%s\n' '#!/usr/bin/env bash' "$MB_BAD")")" | PATH="$JQ_SHIM:$PATH" bash "$HOOK" 2>&1 >/dev/null)" || RC=$?
case "$RC:$ERR" in
  2:*'$VAR'*) ok "C8: deny の JSON を組み立てられないときは exit 2 + stderr へ落とす（黙って許可しない）" ;;
  *) bad "C8: jq -n 失敗時の経路: exit=${RC} stderr=[${ERR}]" ;;
esac

echo "guard-shell-save: stdin の drain（D）"
BIG_PAYLOAD="$(write_json "$WORK/tests/x/notes.md" 'x')$(printf '%*s' 200000 '')"
RC=0
OUT="$(printf '%s' "$BIG_PAYLOAD" | PATH="/nonexistent" /bin/bash "$HOOK" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "D1: PATH 空の環境でも stdin を読み切ってから無出力 exit 0"
else
  bad "D1: PATH 空の drain: exit=${RC} out=[${OUT}]（rc=141 なら hook が stdin を drain せずに exit している）"
fi
ASDD_ON="$TEST_TMP/asdd-hooks-on"
ASDD_OFF="$TEST_TMP/asdd-hooks-off"
mkdir -p "$ASDD_ON" "$ASDD_OFF"
ff_asdd_fixture "$ASDD_ON" true
ff_asdd_fixture "$ASDD_OFF" false
ASDD_PAYLOAD="$(ff_asdd_big_payload '{"tool_name":"Write","tool_input":{"file_path":"/tmp/notes.md","content":"x"},"hook_event_name":"PreToolUse"}')"
ff_asdd_drain_probe "$HOOK" "$ASDD_PAYLOAD" "$ASDD_ON" PATH=/nonexistent
if [ "$FF_ASDD_DRAIN_RC" -eq 0 ] && [ -z "$FF_ASDD_DRAIN_OUT" ]; then
  ok "D2: .asdd 設定あり + node 不在（ゲートが停止）でも stdin を読み切ってから無出力 exit 0"
else
  bad "D2: ASDD ゲート（node 不在）の drain: exit=${FF_ASDD_DRAIN_RC} out=[${FF_ASDD_DRAIN_OUT}]"
fi
if command -v node >/dev/null 2>&1; then
  ff_asdd_drain_probe "$HOOK" "$ASDD_PAYLOAD" "$ASDD_OFF"
  if [ "$FF_ASDD_DRAIN_RC" -eq 0 ] && [ -z "$FF_ASDD_DRAIN_OUT" ]; then
    ok "D3: features.hooks=false（ゲートが無効と判定）でも stdin を読み切ってから無出力 exit 0"
  else
    bad "D3: ASDD ゲート（feature 無効）の drain: exit=${FF_ASDD_DRAIN_RC} out=[${FF_ASDD_DRAIN_OUT}]"
  fi
  ASDD_SH='{"tool_name":"Write","tool_input":{"file_path":"/tmp/ff-shell-save-asdd.sh","content":"echo \"$VAR\u0029\""},"hook_event_name":"PreToolUse"}'
  RC=0
  # 設定の検証（asdd-feature.mjs）はプラグイン内の scripts/asdd/ を読むので、一時領域の
  # コピーではなく配布物の実体で走らせる。
  OUT="$(cd "$ASDD_OFF" && printf '%s' "$ASDD_SH" | bash "$TARGET" 2>/dev/null)" || RC=$?
  _decode
  assert_pass "D4: features.hooks=false では .sh の保存も素通し"
else
  echo "  ○ skip: node が無いため features.hooks=false 経路は未検査（guard-shell-save の ASDD ゲート無効判定）"
fi
NODELESS="$TEST_TMP/nodeless-bin"
mkdir -p "$NODELESS"
for t in jq bash awk wc cat; do
  tp="$(command -v "$t" 2>/dev/null)" && ln -s "$tp" "$NODELESS/$t"
done
RC=0
OUT="$(cd "$ASDD_ON" && printf '%s' "$(write_json "$WORK/tests/x/verify.sh" "$MB_GOOD")" | PATH="$NODELESS" bash "$HOOK" 2>/dev/null)" || RC=$?
_decode
assert_unavailable "D5: .asdd 設定あり + node 不在（検証不能）での .sh 保存は判定不能の deny"
RC=0
OUT="$(printf '%s' "$(write_json "$WORK/tests/x/verify.sh" "$MB_BAD")" | PATH="/nonexistent" /bin/bash "$HOOK" 2>/dev/null)" || RC=$?
_decode
assert_pass "D6: jq が無い環境では .sh の保存も素通し（対象かどうかを決められない）"

echo "guard-shell-save: hooks.json 登録の静的照合（R）"
if jq -e '.hooks.PreToolUse[] | select(.matcher == "Write|Edit") | .hooks[]
    | select(.command | contains("hooks/guard-shell-save.sh"))' "$HOOKS_JSON" >/dev/null 2>&1; then
  ok "R1: hooks.json の PreToolUse（Write|Edit matcher）に登録されている"
else
  bad "R1: hooks.json の PreToolUse（Write|Edit matcher）に guard-shell-save.sh が無い"
fi
if jq -e '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]
    | select(.command | contains("guard-shell-save.sh"))] | length == 0' "$HOOKS_JSON" >/dev/null 2>&1; then
  ok "R2: Bash 集約層（run-bash-hooks.sh）には載せていない（別 matcher の hook）"
else
  bad "R2: guard-shell-save.sh が Bash matcher に登録されている"
fi
DESC="$(jq -r '.description' "$HOOKS_JSON")"
case "$DESC" in
  *guard-shell-save.sh*FF_SHELL_SAVE_ACK*) ok "R3: hooks.json の description が保存時ガードと抜け道に言及する" ;;
  *) bad "R3: hooks.json の description に guard-shell-save.sh / FF_SHELL_SAVE_ACK の記述が無い" ;;
esac

echo "guard-shell-save: 変異検出（コピーへ当て、本番検査と同形の針が赤になること）（M）"
MUT_SRC="$TEST_TMP/mut-src.sh"
# 変異 1: exit-code 検出器を外す
sed -e '/^load_lib exit-code-guard.sh exit_code_scan$/d' \
    -e 's/^exit_hits="\$(new_hits exit_code_scan)" || exit "\$?"$/exit_hits=""/' "$TARGET" > "$MUT_SRC"
if cmp -s "$TARGET" "$MUT_SRC"; then
  bad "M1: 変異 1 が適用されていない（アンカー不一致）"
else
  MUT1="$TEST_TMP/mut1"
  make_plugin "$MUT1" "$LIB_SRC" "$MUT_SRC"
  run_json "$MUT1/hooks/guard-shell-save.sh" "$(write_json "$WORK/scripts/ec.sh" "$(printf '%s\n' '#!/usr/bin/env bash' "$EC_BAD")")"
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    ok "M1: exit-code 検出器を外すと F5 と同形の入力が素通しになり、F5 は赤になる"
  else
    bad "M1: exit-code 検出器を外しても deny のまま: decision=[${DECISION}]"
  fi
fi
# 変異 2: 保存前の走査を空にする（既存違反も新規と数える）
sed 's/^  pre="\$(printf .%s. "\$before" | "\$fn" 2>\/dev\/null)"$/  pre=""/' "$TARGET" > "$MUT_SRC"
if cmp -s "$TARGET" "$MUT_SRC"; then
  bad "M2: 変異 2 が適用されていない（アンカー不一致）"
else
  MUT2="$TEST_TMP/mut2"
  make_plugin "$MUT2" "$LIB_SRC" "$MUT_SRC"
  run_json "$MUT2/hooks/guard-shell-save.sh" "$(edit_json "$EXISTING" 'PLACEHOLDER' 'echo ok')"
  if [ "$DECISION" = "deny" ]; then
    ok "M2: 保存前の走査を消すと既存違反の持ち越しが deny になり、N5 は赤になる"
  else
    bad "M2: 保存前の走査を消しても素通しのまま: exit=${RC} out=[${OUT}]"
  fi
fi

# 変異 3: 比較の鍵に行番号を残す（行の移動を新規と誤認する）
sed 's/^    NR == FNR { if (\$0 != "") { k = \$0; sub(\/\^\[0-9\]+:\/, "", k); seen\[k\]++ }; next }$/    NR == FNR { if ($0 != "") { k = $0; seen[k]++ }; next }/' "$TARGET" > "$MUT_SRC"
if cmp -s "$TARGET" "$MUT_SRC"; then
  bad "M3: 変異 3 が適用されていない（アンカー不一致）"
else
  MUT3="$TEST_TMP/mut3"
  make_plugin "$MUT3" "$LIB_SRC" "$MUT_SRC"
  run_json "$MUT3/hooks/guard-shell-save.sh" "$(edit_json "$EXISTING" 'set -o pipefail' "$(printf '%s\n%s\n%s' 'set -o pipefail' 'echo a' 'echo b')")"
  if [ "$DECISION" = "deny" ]; then
    ok "M3: 比較の鍵に行番号を残すと行の移動が deny になり、N9 は赤になる"
  else
    bad "M3: 行番号を鍵に残しても素通しのまま: exit=${RC} out=[${OUT}]"
  fi
fi
# 変異 4: 件数ではなく集合で突き合わせる（既存違反の複製を見逃す）
sed 's/if (seen\[k\] > 0) { seen\[k\]--; next }; print/if (!(k in seen)) print/' "$TARGET" > "$MUT_SRC"
if cmp -s "$TARGET" "$MUT_SRC"; then
  bad "M4: 変異 4 が適用されていない（アンカー不一致）"
else
  MUT4="$TEST_TMP/mut4"
  make_plugin "$MUT4" "$LIB_SRC" "$MUT_SRC"
  run_json "$MUT4/hooks/guard-shell-save.sh" "$(edit_json "$EXISTING" 'PLACEHOLDER' "$MB_BAD")"
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    ok "M4: 集合で突き合わせると既存違反の複製が素通りになり、F9 は赤になる"
  else
    bad "M4: 集合比較でも deny のまま: decision=[${DECISION}]"
  fi
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ guard-shell-save: ${FAIL} 件失敗（成功 ${PASS} 件）" >&2
  REACHED_END=1
  exit 1
fi
echo "✅ guard-shell-save: all ${PASS} checks passed"
REACHED_END=1
exit 0
