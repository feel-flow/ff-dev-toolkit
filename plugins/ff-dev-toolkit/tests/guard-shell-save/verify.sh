#!/usr/bin/env bash
# 空振り検出: Writeのno-read fallbackを拒否へ戻す変異は構文0の後、外部の正常Write/提案全文ruleの針が赤（rc=1）。正常対照93件pass（2026-10-29実測）。
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
#   E. 保存前を読めない Edit の縮退検査（Issue `#2560`）: 作業ディレクトリ（project）の外の `.sh` は
#      ファイルを読まず old_string → new_string の断片で検査し、違反なしは systemMessage の 1 行付きで
#      通し、違反は deny する。断片の外へ続く行継続は判定不能。結果がファイルの中身に依存しない
#   T. Windows の `%TEMP%` の下を project にした Edit（祖先の ACL で境界が read-unverifiable を返す経路。
#      Windows 以外では skip）
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
# 空振り検出: 一時領域へ写す ASDD ゲートから scripts/asdd/（設定の検証本体）の複製を外すと、写したゲートの判定が rc=2（判定不能）になり D3a の 2 件と D4b の 1 件が赤（2026-09-28 実測、bundle `#1808`。D3 の drain 検査だけでは判定不能の分岐と無効の分岐を区別できない）。
# 空振り検出: 保存後の組み立て（Issue `#2357`。2026-10-26 に WSL で実測、変異なしは 74 件緑）。旧実装（`%%` / `#` の切り出し）へ戻す → R5 の 1 件赤、切り出しを 1 文字ずらす → F14・M4 の 2 件赤、二分探索の向きを取り違える → F7・F10 ほか 6 件赤、探索の上限を 1 文字手前に取り違える → F19 の 1 件赤、timeout を 10 秒へ戻す → R4 の 1 件赤。
# 空振り検出: consumer保存回帰の集合を0件へ替えると、実ケースのfocused集合境界が1件赤・rc=1。正常は4/0、共有検出器への宣言受渡しを外す単独変異は宣言あり危険形だけ1件赤・rc=1（構文はいずれも0、2026-10-22）。
# 空振り検出: 現行正常対照88/0。認可rootを全filesystemへ広げるとleaf/parentの2針、診断をraw行へ戻すとinternalのJSON/stderrの2針、privacy集合の空化でcensusの1針が赤。3変異とも構文0の後suite rc=1を確認（2026-10-29、私有workspaceと文字列検査追加後に再実測）。
# 空振り検出: 保存前の読み取りの stderr を 2>/dev/null へ戻す変異で C6b だけが赤（suite rc=1、他 93 件成功。2026-10-29 WSL 実測、Issue `#2461`）。
# 空振り検出: 縮退検査（Issue `#2560`。2026-10-31 に Windows の Git Bash で実測、変異なしは 122 件緑）。FF_GUARD_SHELL_SAVE_TARGET で差し替えた hook に対し、場所の拒否を縮退させない → E1〜E8・E11・E12・T1〜T4・P-leaf・P-parent の 27 件赤、全拒否を縮退させる → C6・C6b・E10・E13 赤、場所の行が無い read-unverifiable も縮退させる → E10 赤、継承宣言を外す → E2〜E4 赤、断片の CR を残す → E3b 赤、通した回の注記を消す → E1・E5・E7・E8・E11・E12・T3・P-leaf ほか 13 件赤、行継続の判定を外す → E6〜E6d 赤、パイプ・論理演算子の行継続だけを外す → E6b〜E6d 赤、develop の旧 hook → E1〜E8・E11・E12・T1〜T4・P-write ほか 28 件赤（D4 は差し替えた実体の隣に ASDD ゲートが無いため、M5・M6 は自前の変異のアンカーが消えるため、差し替え時は赤）。
# 空振り検出: 針が当たらない入力（Issue `#2560`）。%TEMP% の祖先の ACL で read-unverifiable を再現できない環境の T1 は ok に数えず skip と名指しし、境界の種別の行の書式が変わる（大文字など）と種別を読めず E13 のとおり判定不能の deny になる（緑へ倒さない）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="${FF_GUARD_SHELL_SAVE_TARGET:-$PLUGIN_ROOT/hooks/guard-shell-save.sh}"
# 差し替え口（変異の probe 用）は分離より前に読む — 分離名簿へ偶然入っても消えないように。
LIB_SRC="${FF_GUARD_SHELL_SAVE_LIB_DIR:-$PLUGIN_ROOT/tests/lib}"
# ホスト環境の解除変数・テストシーム（hook 実装とその参照先が読む FF_* / CLAUDE_*）を
# 先頭で 1 回落とす。ケース固有の `NAME=v bash "$TARGET"` はこの後に代入として届く（Issue `#1808`）。
# shellcheck source=../lib/adapter-env-isolation.sh
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"
isolate_hook_env "FF_SHELL_SAVE_ACK" "$PLUGIN_ROOT/hooks/guard-shell-save.sh"
# shellcheck source=../lib/asdd-gate-drain.sh
. "$SCRIPT_DIR/../lib/asdd-gate-drain.sh"
# shellcheck source=../lib/crlf-jq-shim.sh
. "$SCRIPT_DIR/../lib/crlf-jq-shim.sh"
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

case "$(uname -s 2>/dev/null)" in
  MSYS* | MINGW* | CYGWIN*) ON_WINDOWS=1 ;;
  *) ON_WINDOWS=0 ;;
esac
# Windows の `%TEMP%` は祖先に本人以外が書ける ACE を持つことがあり、そこへ WORK（認可された project）を
# 置くと境界が project 自体を read-unverifiable で拒否して、project 内の判定を測る節がすべて縮退側へ
# 倒れる。境界と同じ移し先の規則（ff_knowledge_job_directory: TMPDIR が検査を通らなければ toolkit の
# 状態ディレクトリへ移す）で置き場を決める。`%TEMP%` の経路そのものは T 節が別に測る（Issue `#2560`）。
_ff_win_err="${TMPDIR:-/tmp}/ff-guard-shell-save-err.$$"
if [ "$ON_WINDOWS" -eq 1 ] \
  && _ff_mktemp_out="$(bash -c '. "$1" && ff_knowledge_job_directory ff-guard-shell-save' _ "$PLUGIN_ROOT/scripts/lib/knowledge-read-boundary.sh" 2>"$_ff_win_err")" \
  && [ -d "$_ff_mktemp_out" ]; then
  rm -f "$_ff_win_err"
  TEST_TMP="$_ff_mktemp_out"
elif [ "$ON_WINDOWS" -eq 1 ]; then
  # 境界の診断（止めた場所・SID）を理由として出す
  echo "✗ 一時ディレクトリを作成できません: $(cat "$_ff_win_err" 2>/dev/null)" >&2
  rm -f "$_ff_win_err"
  exit 1
elif [ "$ON_WINDOWS" -eq 0 ] && _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/ff-guard-shell-save.XXXXXX" 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  TEST_TMP="$_ff_mktemp_out"
else
  echo "✗ 一時ディレクトリを作成できません: ${_ff_mktemp_out}" >&2
  exit 1
fi
REACHED_END=0
WIN_TEMP_DIR=""
cleanup() {
  local rc=$?
  chmod -R u+rwX "$TEST_TMP" 2>/dev/null || true
  rm -rf "$TEST_TMP"
  if [ -n "$WIN_TEMP_DIR" ]; then rm -rf "$WIN_TEMP_DIR"; fi
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
  mkdir -p "$dir/hooks" "$dir/tests/lib" "$dir/scripts/lib"
  cp "$hook" "$dir/hooks/guard-shell-save.sh"
  cp "$PLUGIN_ROOT/scripts/lib/knowledge-read-boundary.sh" "$PLUGIN_ROOT/scripts/lib/knowledge-read-acl.ps1" "$dir/scripts/lib/"
  # ASDD の判定本体（scripts/asdd/）まで写す。hooks/ の 2 本だけでは判定が常に rc=2 になる。
  ff_asdd_copy_gate "$dir"
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
  OUT="$(cd "$WORK" && printf '%s' "$json" | env "$@" bash "$hook" 2>/dev/null)" || RC=$?
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
# 縮退検査で通した回: deny ではなく、systemMessage の 1 行で縮退を残す（Issue `#2560`）。
assert_degraded_pass() { # <label>
  local msg
  msg="$(printf '%s' "$OUT" | jq -r '.systemMessage // empty' 2>/dev/null || true)"
  case "$RC:$DECISION:$msg" in
    0::*縮退検査*)
      case "$msg" in
        *"$nl"*) bad "$1: 縮退の注記が 1 行でない: [${msg}]" ;;
        *) ok "$1" ;;
      esac ;;
    *) bad "$1: exit=${RC} decision=[${DECISION}] out=[${OUT}]" ;;
  esac
}
# 縮退検査で止めた回: 判定不能の deny ではなく、縮退の注記と規則名を本文に持つ deny（修正前の hook の
# 判定不能の deny と区別する）。
assert_degraded_fire() { # <label> <rule>
  case "$RC:$DECISION:$REASON" in
    *判定不能*) bad "$1: 縮退検査ではなく判定不能の deny: [${REASON}]" ;;
    0:deny:*縮退検査*"$2"*) ok "$1" ;;
    *) bad "$1: exit=${RC} decision=[${DECISION}] reason=[${REASON}]" ;;
  esac
}
nl='
'

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
  *'4:mbcs'*'5:mbcs'*) ok "F7: replace_allの2箇所が固定ruleと保存後の行番号で報告される" ;;
  *) bad "F7: replace_all の 2 箇所が報告されない: [${REASON}]" ;;
esac

run_json "$HOOK" "$(edit_json "$EXISTING" 'PLACEHOLDER' "$MB_BAD")"
assert_fire "F9: 既存違反と同じ綴りの行を複製する Edit も deny（件数で突き合わせる）"
CAPTURE_PLUGIN="$TEST_TMP/capture-plugin"
make_plugin "$CAPTURE_PLUGIN" "$LIB_SRC"
sed 's/^mbcs_scan()/ff_test_original_mbcs_scan()/' "$LIB_SRC/mbcs-guard.sh" > "$CAPTURE_PLUGIN/tests/lib/mbcs-guard.sh"
cat "$SCRIPT_DIR/fixtures/capture-mbcs.sh" >> "$CAPTURE_PLUGIN/tests/lib/mbcs-guard.sh"
CAPTURE_FILE="$TEST_TMP/private-scan-inputs"
: > "$CAPTURE_FILE"
CAPTURE_EXPECTED_AFTER="$TEST_TMP/private-expected-after"
printf '%s\n' '#!/usr/bin/env bash' 'set -o pipefail' "$MB_BAD" 'echo "$NEW'"${FW}"'" # a&b' 'PLACEHOLDER' > "$CAPTURE_EXPECTED_AFTER"
capture_before=""; capture_after=""
IFS= read -r -d '' capture_before < "$EXISTING" || true
IFS= read -r -d '' capture_after < "$CAPTURE_EXPECTED_AFTER" || true
printf '%s\000%s\000' "$capture_before" "$capture_after" > "$TEST_TMP/private-expected-inputs"
run_json "$CAPTURE_PLUGIN/hooks/guard-shell-save.sh" "$(edit_json "$EXISTING" 'PLACEHOLDER' 'echo "$NEW'"${FW}"'" # a&b')" "FF_TEST_SHELL_CAPTURE=$CAPTURE_FILE"
case "$REASON" in
  *'4:mbcs'*)
    case "$REASON" in
      *'5:mbcs'*) bad "F10: replace_all=falseなのに2箇所目まで置換された" ;;
      *)
        if cmp -s "$CAPTURE_FILE" "$TEST_TMP/private-expected-inputs"; then
          ok "F10: private before/after oracleで単一置換とliteral &を確認（公開診断は固定ruleのみ）"
        else bad "F10: private before/after bytesが独立expectedと異なる"; fi ;;
    esac ;;
  *) bad "F10: 字義どおりの単一置換になっていない: [${REASON}]" ;;
esac
# F17 / F18: 保存後の組み立ては先頭一致の位置を二分探索で求める（Issue `#2357`）。位置の数え方が
# バイトと文字で食い違うと、マルチバイトの行より後ろの置換がずれて行番号か綴りが変わる。
MBPRE="$WORK/scripts/mbpre.sh"
printf '%s\n' '#!/usr/bin/env bash' 'set -o pipefail' '# 日本語のコメント行（全角）' 'PLACEHOLDER' 'echo tail' > "$MBPRE"
run_json "$HOOK" "$(edit_json "$MBPRE" 'PLACEHOLDER' "$MB_BAD")"
case "$DECISION:$REASON" in
  deny:*"4:mbcs"*) ok "F17: マルチバイトの行より後ろの置換も開始行と固定ruleを報告する" ;;
  *) bad "F17: マルチバイトの行より後ろの置換がずれた: decision=[${DECISION}] reason=[${REASON}]" ;;
esac
# 大きな .sh（約 13 万字・25 万バイト。Windows の Git Bash で旧実装が timeout を超えた大きさの桁）の
# 末尾付近への置換の正しさを見る。所要時間は測らない（Linux では旧実装も速い。性能の退行は R5 が見る）。
BIG="$WORK/scripts/big.sh"
{
  printf '%s\n' '#!/usr/bin/env bash' 'set -o pipefail'
  i=0
  while [ "$i" -lt 4000 ]; do printf '# 長いファイルの行 %s（全角を含む）PLACEHOLDE\n' "$i"; i=$((i + 1)); done
  printf '%s\n' 'PLACEHOLDER' 'echo tail'
} > "$BIG"
BIG_LINE=$((4000 + 3))
run_json "$HOOK" "$(edit_json "$BIG" 'PLACEHOLDER' "$MB_BAD")"
case "$DECISION:$REASON" in
  deny:*"${BIG_LINE}:mbcs"*) ok "F18: 大きな .sh でも正しい置換位置の行と固定ruleでdeny" ;;
  *) bad "F18: 大きな .sh の置換が誤った: decision=[${DECISION}] reason=[${REASON:0:300}]" ;;
esac
# F19: old_string がファイルの最後のバイトで終わる（末尾に改行が無い）とき。二分探索が上限（全体の長さ）で
# 収束する側の境界で、1 文字ずれると末尾の綴りが欠けるか残る。
TAILF="$WORK/scripts/tail.sh"
printf '%s\n%s\n%s' '#!/usr/bin/env bash' 'set -o pipefail' 'PLACEHOLDER' > "$TAILF"
run_json "$HOOK" "$(edit_json "$TAILF" 'PLACEHOLDER' "$MB_BAD")"
case "$DECISION:$REASON" in
  deny:*"3:mbcs"*) ok "F19: 末尾に改行の無い最後の行への置換も、行番号と固定ruleを報告" ;;
  *) bad "F19: 末尾の置換がずれた: decision=[${DECISION}] reason=[${REASON}]" ;;
esac
GLOB="$WORK/scripts/glob.sh"
printf '%s\n' '#!/usr/bin/env bash' 'x=[*]' 'x=a' > "$GLOB"
run_json "$HOOK" "$(edit_json "$GLOB" 'x=[*]' "$MB_BAD")"
case "$REASON" in
  *'2:mbcs'*) ok "F11: glob 文字を含む old_string も字義どおりに一致させる" ;;
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
n_mb="$(printf '%s\n' "$REASON" | grep -c '^    | [0-9]*:mbcs$' || true)"
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
  *'2:mbcs'*) ok "F8: deny本文がソース行を含めず開始行と固定ruleを示す" ;;
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

# 同じ共有検出器を使う保存時のconsumer宣言。実内容のdeclared/undeclared/safeを固定する。
CONSUMER_SAVE_CASES=0
consumer_save_cases() {
  run_json "$HOOK" "$(write_json "$WORK/scripts/consumer.sh" 'make ci > log; tail log')" 'FF_EXIT_CODE_GUARD_GATES=make ci'
  assert_fire "consumer宣言ありの危険形を保存時もdenyする"
  CONSUMER_SAVE_CASES=$((CONSUMER_SAVE_CASES + 1))
  run_json "$HOOK" "$(write_json "$WORK/scripts/consumer.sh" 'make ci > log; tail log')"
  assert_pass "consumer宣言なしの同じ保存内容は既定互換"
  CONSUMER_SAVE_CASES=$((CONSUMER_SAVE_CASES + 1))
  run_json "$HOOK" "$(write_json "$WORK/scripts/consumer.sh" 'make ci > log; rc=$?; tail log; exit $rc')" 'FF_EXIT_CODE_GUARD_GATES=make ci'
  assert_pass "consumer宣言ありでもrc伝播する保存内容はallowする"
  CONSUMER_SAVE_CASES=$((CONSUMER_SAVE_CASES + 1))
}
consumer_save_cases
if [ "$CONSUMER_SAVE_CASES" -gt 0 ]; then ok "consumer saveのケース集合は空でない"; else bad "consumer saveのケース集合が空"; fi

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
# 名前を nul.sh にしない。Windows では NUL が予約デバイス名で、境界の ACL 照合（PowerShell）が
# パスを解決できず read-unverifiable（場所の拒否）を返し、NUL を含む中身の拒否を測れなくなる。
NULF="$WORK/scripts/with-nul-byte.sh"
printf '#!/usr/bin/env bash\n\000PLACEHOLDER\n' > "$NULF"
run_json "$HOOK" "$(edit_json "$NULF" '#!/usr/bin/env bash' '#!/bin/bash')"
assert_unavailable "C6: NUL を含み全体を読めない Edit 対象は判定不能の deny"
# 境界の拒否理由（knowledge-read: 行）を捨てず deny の理由へ載せる。Windows で止めた祖先と SID を
# 利用者が知る唯一の経路なので、2>/dev/null へ戻すとここが赤になる（Issue `#2461`）
case "$REASON" in
  # Windows では TMPDIR の移し先の案内行が種別の行より前に入るので、種別の位置は固定しない
  *'境界の診断: '*'knowledge-read: incomplete-input'*) ok "C6b: 判定不能の deny の理由に境界の診断（NUL で読み切れない knowledge-read: incomplete-input）を載せる" ;;
  *) bad "C6b: 境界の診断が deny の理由に無い: reason=[${REASON}]" ;;
esac
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
  # D3 / D5 が測る分岐の裏取り: 一時領域へ写した hook のゲートが、fixture の設定を
  # 判定不能（rc=2）ではなく無効（rc=3）/ 有効（rc=0）と読めていること（Issue `#1808` の追記）。
  ff_asdd_gate_rc "$PLUG" "$ASDD_OFF" hooks
  if [ "$FF_ASDD_GATE_RC" -eq 3 ]; then
    ok "D3a: 写した hook の ASDD ゲートが features.hooks=false を無効（rc=3）と判定する"
  else
    bad "D3a: 写した hook の ASDD ゲートが features.hooks=false を rc=${FF_ASDD_GATE_RC} と判定（3 以外。2 なら scripts/asdd/ を写していない）"
  fi
  ff_asdd_gate_rc "$PLUG" "$ASDD_ON" hooks
  if [ "$FF_ASDD_GATE_RC" -eq 0 ]; then
    ok "D3a: 写した hook の ASDD ゲートが features.hooks=true を有効（rc=0）と判定する"
  else
    bad "D3a: 写した hook の ASDD ゲートが features.hooks=true を rc=${FF_ASDD_GATE_RC} と判定（0 以外）"
  fi
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
  # 同じ入力を一時領域へ写した hook で測る。ゲートが判定不能（rc=2）のままなら .sh は
  # 判定不能の deny になるので、ここが緑であること自体が写しの ASDD 分岐が生きている証拠。
  RC=0
  OUT="$(cd "$ASDD_OFF" && printf '%s' "$ASDD_SH" | bash "$HOOK" 2>/dev/null)" || RC=$?
  _decode
  assert_pass "D4b: 写した hook でも features.hooks=false なら .sh の保存を素通し（無効分岐を実際に通る）"
else
  echo "  ○ skip: node が無いため features.hooks=false 経路は未検査（guard-shell-save の ASDD ゲート無効判定）"
fi
if [ "$ON_WINDOWS" -eq 1 ]; then
  # 最小 PATH へ symlink した MSYS の exe は msys-2.0.dll を見つけられず rc=127 で起動しない。
  echo "  ○ skip: Windows（Git Bash）では最小 PATH へ置いた bash.exe 等が msys-2.0.dll を見つけられず起動しないため、D5（node 不在の ASDD 検証不能）は未検査（POSIX で検査する）"
else
  NODELESS="$TEST_TMP/nodeless-bin"
  mkdir -p "$NODELESS"
  for t in jq bash awk wc cat; do
    tp="$(command -v "$t" 2>/dev/null)" && ln -s "$tp" "$NODELESS/$t"
  done
  RC=0
  OUT="$(cd "$ASDD_ON" && printf '%s' "$(write_json "$WORK/tests/x/verify.sh" "$MB_GOOD")" | PATH="$NODELESS" bash "$HOOK" 2>/dev/null)" || RC=$?
  _decode
  assert_unavailable "D5: .asdd 設定あり + node 不在（検証不能）での .sh 保存は判定不能の deny"
fi
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
# R4: Windows の Git Bash で 21 万字の .sh への Edit が約 7 秒かかる（高速化後）。timeout は負荷時の
# 伸びを見込んで 30 秒以上にする（10 秒では deny が捨てられて違反が保存されていた。Issue `#2357`）。
# onFailure: block は付けない — 走査はファイルの長さに比例するので、30 秒を超える巨大な .sh では Edit 自体が
# 締め出される。その代わり 30 秒を超えた回は従来どおりホストが判定を捨てて通す（残余。HOST-PARITY §3）。
SS_TIMEOUT="$(jq -r '[.hooks.PreToolUse[] | select(.matcher == "Write|Edit") | .hooks[]
    | select(.command | contains("hooks/guard-shell-save.sh")) | .timeout] | if length == 1 then (.[0] // "") else "" end' "$HOOKS_JSON" 2>/dev/null || true)"
case "$SS_TIMEOUT" in
  '' | *[!0-9]*) bad "R4: guard-shell-save の timeout を数値で読めない: [${SS_TIMEOUT}]" ;;
  *) if [ "$SS_TIMEOUT" -ge 30 ]; then ok "R4: guard-shell-save の timeout が 30 秒以上（${SS_TIMEOUT}）"; else bad "R4: guard-shell-save の timeout が 30 秒未満（${SS_TIMEOUT}）"; fi ;;
esac
# R5: 先頭一致の切り出しに長さの二乗で遅くなる形（${…%%"$old"*} / ${…#*"$old"}）を戻さない。
if grep -qE '%%"\$old"\*|#\*"\$old"' "$HOOK"; then
  bad "R5: 保存後の組み立てに二乗で遅くなる切り出し（\${…%%\"\$old\"*} / \${…#*\"\$old\"}）が残っている"
else
  ok "R5: 保存後の組み立ては二乗で遅くなる切り出しを使わない"
fi

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

# ---- Windows の jq.exe（改行を \r\n で出す）でも同じ判定になる（Issue `#2017`）----
# hook は tool_name と file_path を "\n" で連結して `jq -j` で取り出す。修正前は tool_name が
# `Write\r` になって判定対象外へ落ち、fail-closed の設計なのに黙って素通りしていた
# （2026-10-03 に Windows 実機で測定）。シムは hook の呼び出しにだけ PATH で差す。
echo "guard-shell-save: CRLF を出す jq でも同じ判定"
CRLF_BIN="$TEST_TMP/crlf-jq-bin"
crlf_rc=0
ff_crlf_jq_shim "$CRLF_BIN" "$(command -v jq)" || crlf_rc=$?
if [ "$crlf_rc" -eq 2 ]; then
  echo "  ○ skip: perl が無いため CRLF の jq を再現できません（この 2 検査は未実行）"
elif [ "$crlf_rc" -ne 0 ]; then
  bad "CRLF の jq シムを作れませんでした（rc=${crlf_rc}）"
else
  run_json "$HOOK" "$(write_json "$WORK/tests/x/verify.sh" "$(printf '%s\n' '#!/usr/bin/env bash' "$MB_BAD")")" "PATH=$CRLF_BIN:$PATH"
  assert_fire "W1: CRLF の jq でも、Write で \$VAR 直後のマルチバイトを含む verify.sh は deny"
  run_json "$HOOK" "$(write_json "$WORK/tests/x/notes.md" "$MB_BAD")" "PATH=$CRLF_BIN:$PATH"
  assert_pass "W2: CRLF の jq でも、.sh 以外への保存は止めない"
fi

echo "guard-shell-save: 読取り境界と診断の機密非表示"
SHELL_CANARY='ff_shell_read_canary_2432'
READ_SHARED="$TEST_TMP/read-shared"
mkdir -p "$READ_SHARED"
printf '%s\n' '#!/usr/bin/env bash' "SYNTHETIC_KEY=$SHELL_CANARY; $MB_BAD" > "$READ_SHARED/config.sh"
cp "$READ_SHARED/config.sh" "$TEST_TMP/read-protected-before"
ln -s "$READ_SHARED/config.sh" "$WORK/scripts/external-link.sh"
ln -s "$READ_SHARED" "$WORK/linked-dir"
cp "$READ_SHARED/config.sh" "$WORK/scripts/internal-canary.sh"
PRIVACY_CASES=0
PRIVACY_EXPECTED=3
PRIVACY_SET="leaf parent internal"
if [ ! -L "$WORK/scripts/external-link.sh" ] || [ ! -L "$WORK/linked-dir" ]; then
  # Git Bash の既定（MSYS が winsymlinks:nativestrict でない）は ln -s を複製にするので、外へ解決するリンクを作れない。
  echo "  ○ skip: ln -s が symlink を作らない環境（Windows の Git Bash で MSYS=winsymlinks:nativestrict でない等）のため P-leaf / P-parent は未検査"
  PRIVACY_EXPECTED=1
  PRIVACY_SET="internal"
fi
LEAF_OUT=""
for read_case in $PRIVACY_SET; do
  PRIVACY_CASES=$((PRIVACY_CASES + 1))
  case "$read_case" in
    leaf) read_target="$WORK/scripts/external-link.sh" ;;
    parent) read_target="$WORK/linked-dir/config.sh" ;;
    internal) read_target="$WORK/scripts/internal-canary.sh" ;;
  esac
  read_payload="$(edit_json "$read_target" 'SYNTHETIC_KEY' 'RENAMED_KEY')"
  run_json "$HOOK" "$read_payload"
  if [ "$read_case" = internal ]; then
    assert_fire "P-$read_case: 認可内の通常shell診断はdenyを維持"
    case "$REASON" in *'2:mbcs'*) ok "P-internal: 規則と開始行は有用な診断として維持" ;; *) bad "P-internal: 規則/行の診断が欠落" ;; esac
  else
    # 外へ解決するリンクは before-image を読まず、断片（old_string → new_string）だけで判定する（Issue `#2560`）。
    assert_degraded_pass "P-$read_case: 外部へ解決するリンクへの Edit は before-image を読まず断片だけで判定（縮退）"
    [ "$read_case" = leaf ] && LEAF_OUT="$OUT"
  fi
  case "$OUT:$REASON" in *"$SHELL_CANARY"*) bad "P-$read_case: JSON診断へ合成機密値が漏れた" ;; *) ok "P-$read_case: JSON診断に合成機密値なし" ;; esac
  if cmp -s "$read_target" "$TEST_TMP/read-protected-before"; then ok "P-$read_case: 元ファイル不変"; else bad "P-$read_case: 元ファイルが変化"; fi
  RC=0
  ERR="$(cd "$WORK" && printf '%s' "$read_payload" | PATH="$JQ_SHIM:$PATH" bash "$HOOK" 2>&1 >/dev/null)" || RC=$?
  case "$read_case:$RC:$ERR" in
    *"$SHELL_CANARY"*) bad "P-$read_case: stderr fallbackへ合成機密値が漏れた" ;;
    internal:2:*) ok "P-$read_case: JSON生成失敗時もexit2/stderrに合成機密値なし" ;;
    # 縮退の注記は判定ではないので、JSON を作れないときは stderr へ出して止めない
    leaf:0:*縮退検査* | parent:0:*縮退検査*) ok "P-$read_case: JSON生成失敗時も注記をstderrへ残し、合成機密値なし" ;;
    *) bad "P-$read_case: stderr fallback未到達（rc=${RC}）" ;;
  esac
done
if [ "$PRIVACY_CASES" -eq "$PRIVACY_EXPECTED" ] && [ "$PRIVACY_CASES" -gt 0 ]; then ok "P-census: 実ケース${PRIVACY_CASES}件（${PRIVACY_SET}）を実行"; else bad "P-census: privacy実ケースが空または欠落"; fi
# 判定がファイルの中身に依存しない（中身を当てる手がかりにならない）: 外部ファイルに無い old_string でも同じ出力。
if [ -n "$LEAF_OUT" ]; then
  run_json "$HOOK" "$(edit_json "$WORK/scripts/external-link.sh" 'KEY_NOT_IN_THE_FILE' 'RENAMED_KEY')"
  if [ "$OUT" = "$LEAF_OUT" ]; then ok "P-oracle: 外部ファイルに在る / 無い old_string で出力が同一（中身を読まない）"
  else bad "P-oracle: old_string の有無で出力が変わった: [${OUT}] / [${LEAF_OUT}]"; fi
fi
run_json "$HOOK" "$(write_json "$READ_SHARED/config.sh" 'echo safe')"
assert_pass 'P-write: project外の既存ファイルはbeforeを読まず提案全文を走査して通す'
run_json "$HOOK" "$(write_json "$READ_SHARED/config.sh" "$MB_BAD")"
assert_fire 'P-write: project外でも危険な提案全文はdeny'
case "$REASON" in *'1:mbcs'*) ok 'P-write: 元ファイルの拒否で代用せず提案全文のrule/行を診断' ;; *) bad 'P-write: 提案全文の走査に到達していない' ;; esac
case "$REASON" in *'すべて新規として数えています'*) ok 'P-write: 保存前を読めず全違反を新規と数えたことを deny 本文に残す' ;; *) bad "P-write: 縮退の注記が deny 本文に無い: [${REASON}]" ;; esac
case "$OUT:$REASON" in *"$SHELL_CANARY"*) bad 'P-write: 保存前の合成機密が漏れた' ;; *) ok 'P-write: beforeの値は診断へ出ない' ;; esac
if cmp -s "$READ_SHARED/config.sh" "$TEST_TMP/read-protected-before"; then ok 'P-write: 保存前の外部ファイル不変'; else bad 'P-write: 外部ファイルが変化'; fi

echo "guard-shell-save: 保存前を読めない Edit の縮退検査（E。作業ディレクトリの外）"
# WORK（run_json の cwd = 認可された project）の外。境界は outside-authority で拒否する。
OUTSIDE="$TEST_TMP/outside"
mkdir -p "$OUTSIDE"
OUT_SH="$OUTSIDE/tool.sh"
printf '%s\n' '#!/usr/bin/env bash' 'set -o pipefail' "$MB_BAD" 'PLACEHOLDER' > "$OUT_SH"
run_json "$HOOK" "$(edit_json "$OUT_SH" 'PLACEHOLDER' 'echo ok')"
assert_degraded_pass "E1: 作業ディレクトリの外の .sh へ違反を含まない Edit は止めず、縮退を 1 行残す"
case "$OUT" in *outside-authority*) ok "E1: 縮退の注記が拒否の種別（outside-authority）を示す" ;; *) bad "E1: 注記に拒否の種別が無い: [${OUT}]" ;; esac
E1_OUT="$OUT"
run_json "$HOOK" "$(edit_json "$OUT_SH" 'PLACEHOLDER' "$EC_BAD")"
assert_degraded_fire "E2: 同じ場所への終了コードの握り潰しを含む Edit は縮退検査で deny" exit-code
case "$REASON" in
  *縮退検査*'1:exit-code'*'new_string の中の行'*) ok "E2: deny 本文が縮退と new_string の中の行番号を示す" ;;
  *) bad "E2: deny 本文に縮退・行番号の案内が無い: [${REASON}]" ;;
esac
run_json "$HOOK" "$(edit_json "$OUT_SH" 'PLACEHOLDER' "$PF_BAD")"
assert_degraded_fire "E3: 断片に pipefail の設定行が無くても、pipefail を仮定してパイプ下流の quiet grep を deny" pipefail-grep-q
# E3b: Windows の jq.exe は文字列の中の改行も CRLF で出す。CR が残ると `\` の行継続を検出器が見落とすので、
# CRLF の 2 行に分けた違反でも deny になること（縮退経路は断片の CR を除く）。
run_json "$HOOK" "$(edit_json "$OUT_SH" 'PLACEHOLDER' "$(printf '%s\r\n%s' 'printf "%s" "$v" \' "  | ${GQ} y")")"
assert_degraded_fire "E3b: CRLF の行継続で 2 行に分けたパイプ下流の quiet grep も deny（断片の CR を除く）" pipefail-grep-q
run_json "$HOOK" "$(edit_json "$OUT_SH" 'PLACEHOLDER' "$(printf '%s\n%s' 'echo ok' "$MB_BAD")")"
case "$DECISION:$REASON" in
  deny:*'2:mbcs'*) ok "E4: 断片の 2 行目の違反を、継承宣言の分を引いた new_string の中の行で報告" ;;
  *) bad "E4: 行番号がずれた: decision=[${DECISION}] reason=[${REASON}]" ;;
esac
run_json "$HOOK" "$(edit_json "$OUT_SH" "$MB_BAD" "$(printf '%s\n%s' "$MB_BAD" 'echo ok')")"
assert_degraded_pass "E5: old_string に在った違反を new_string が持ち越すだけなら通す（件数の突き合わせ）"
for cont_case in 'E6:echo a \' 'E6b:printf x |' 'E6c:true &&  ' 'E6d:false ||'; do
  run_json "$HOOK" "$(edit_json "$OUT_SH" 'PLACEHOLDER' "${cont_case#*:}")"
  case "$RC:$DECISION:$REASON" in
    0:deny:*判定不能*行継続*) ok "${cont_case%%:*}: new_string の末尾が行継続（${cont_case#*:}）なら論理行が断片の外へ続くので判定不能の deny" ;;
    *) bad "${cont_case%%:*}: 行継続（${cont_case#*:}）を判定不能にしない: exit=${RC} decision=[${DECISION}] reason=[${REASON}]" ;;
  esac
done
run_json "$HOOK" "$(edit_json "$OUT_SH" 'PLACEHOLDER' 'echo a \\')"
assert_degraded_pass "E7: 偶数個の \\ で終わる行は行継続ではないので通す"
run_json "$HOOK" "$(edit_json "$OUT_SH" 'PLACEHOLDER' 'echo ok' true)"
assert_degraded_pass "E8: replace_all でも断片の組で判定する"
run_json "$HOOK" "$(edit_json "$OUT_SH" 'NOT-THERE' 'echo ok')"
if [ "$OUT" = "$E1_OUT" ]; then ok "E9: ファイルに無い old_string でも E1 と同じ出力（中身を読まず、一致の有無を漏らさない）"
else bad "E9: old_string の有無で出力が変わった: [${OUT}]"; fi
if cmp -s "$OUT_SH" <(printf '%s\n' '#!/usr/bin/env bash' 'set -o pipefail' "$MB_BAD" 'PLACEHOLDER'); then ok "E: 外のファイルは不変"; else bad "E: 外のファイルが変化"; fi
# E10〜E13: 拒否の種別ごとの分岐を全 OS で通す。写した境界の snapshot を差し替え、project の中の
# ファイルに対して指定した種別（と、種別の行の後の「止めた場所:」の行）で拒否させる。
# read-unverifiable は ACL ヘルパのタイムアウトや開けない権限でも出るので、場所の行を伴うときだけ縮退する。
STUB_READ="$TEST_TMP/stub-read"
make_plugin "$STUB_READ" "$LIB_SRC"
cat >> "$STUB_READ/scripts/lib/knowledge-read-boundary.sh" <<'STUB'
ff_knowledge_snapshot() {
  printf 'knowledge-read: %s\n' "${GUARD_STUB_READ_CODE:-}" >&2
  if [ -n "${GUARD_STUB_READ_PLACE:-}" ]; then printf 'knowledge-read: 止めた場所: %s — test\n' "${GUARD_STUB_READ_PLACE}" >&2; fi
  return 2
}
STUB
STUB_SH="$WORK/scripts/stub-read.sh"
printf '%s\n' '#!/usr/bin/env bash' 'PLACEHOLDER' > "$STUB_SH"
STUB_EDIT="$(edit_json "$STUB_SH" 'PLACEHOLDER' 'echo ok')"
run_json "$STUB_READ/hooks/guard-shell-save.sh" "$STUB_EDIT" GUARD_STUB_READ_CODE=read-unverifiable
assert_unavailable "E10: 場所の行を伴わない read-unverifiable（ACL ヘルパのタイムアウト・開けない権限）は縮退せず判定不能"
run_json "$STUB_READ/hooks/guard-shell-save.sh" "$STUB_EDIT" GUARD_STUB_READ_CODE=read-unverifiable "GUARD_STUB_READ_PLACE=$WORK"
assert_degraded_pass "E11: 種別の行の後に止めた場所が続く read-unverifiable（祖先の ACL）は縮退して通す"
run_json "$STUB_READ/hooks/guard-shell-save.sh" "$(edit_json "$STUB_SH" 'PLACEHOLDER' "$EC_BAD")" GUARD_STUB_READ_CODE=read-unverifiable "GUARD_STUB_READ_PLACE=$WORK"
assert_degraded_fire "E11: 同じ経路で終了コードの握り潰しは縮退検査で deny" exit-code
run_json "$STUB_READ/hooks/guard-shell-save.sh" "$STUB_EDIT" GUARD_STUB_READ_CODE=replaceable-storage
assert_degraded_pass "E12: replaceable-storage（祖先を本人以外が置き換えられる）は縮退して通す"
run_json "$STUB_READ/hooks/guard-shell-save.sh" "$STUB_EDIT" GUARD_STUB_READ_CODE=incomplete-input "GUARD_STUB_READ_PLACE=$WORK"
assert_unavailable "E13: 中身の拒否（incomplete-input）は場所の行があっても縮退しない"
run_json "$STUB_READ/hooks/guard-shell-save.sh" "$STUB_EDIT" GUARD_STUB_READ_CODE=READ-UNVERIFIABLE "GUARD_STUB_READ_PLACE=$WORK"
assert_unavailable "E13: 種別の行の書式が変わる（大文字）と種別を読めず判定不能（緑へ倒さない）"

echo "guard-shell-save: Windows の %TEMP% の下（T）"
if [ "$ON_WINDOWS" -eq 1 ]; then
  win_temp="$(cygpath -u "${TEMP:-}" 2>/dev/null || true)"
  if [ -n "$win_temp" ] && [ -d "$win_temp" ] && WIN_TEMP_DIR="$(mktemp -d "$win_temp/ff-guard-shell-save-temp.XXXXXX")"; then
    mkdir -p "$WIN_TEMP_DIR/proj"
    T_SH="$WIN_TEMP_DIR/proj/scratch.sh"
    printf '%s\n' '#!/usr/bin/env bash' 'set -o pipefail' 'PLACEHOLDER' > "$T_SH"
    run_in() { # <cwd> <json>
      RC=0
      OUT="$(cd "$1" && printf '%s' "$2" | bash "$HOOK" 2>/dev/null)" || RC=$?
      _decode
    }
    # T1 / T2: scratchpad のように %TEMP% の下を作業ディレクトリにした Edit。
    run_in "$WIN_TEMP_DIR/proj" "$(edit_json "$T_SH" 'PLACEHOLDER' 'echo ok')"
    T_ACL=0
    case "$RC:$OUT" in
      0:*read-unverifiable*) T_ACL=1; assert_degraded_pass "T1: %TEMP% の祖先の ACL で読めない .sh への違反なしの Edit は止めず、縮退を残す" ;;
      0:)
        # 止まらないことは確かめたが、ACL の経路は通っていないので ok に数えない（その経路は E11 が stub で見る）
        echo "  ○ skip: この機の %TEMP% は境界の ACL 検査を通るため、T1 の read-unverifiable の経路は未再現（全体を読んで検査し、止まらなかった）" ;;
      *) bad "T1: %TEMP% の下への違反なしの Edit: exit=${RC} out=[${OUT}]" ;;
    esac
    run_in "$WIN_TEMP_DIR/proj" "$(edit_json "$T_SH" 'PLACEHOLDER' "$EC_BAD")"
    if [ "$T_ACL" -eq 1 ]; then
      assert_degraded_fire "T2: %TEMP% の祖先の ACL で読めない .sh への終了コードの握り潰しは縮退検査で deny" exit-code
    else
      assert_fire "T2: %TEMP% の下の .sh への終了コードの握り潰しは deny"
    fi
    # T3 / T4: 作業ディレクトリは別の project で、%TEMP% の下の scratchpad を Edit する（OBS-452 の実測の形）。
    run_json "$HOOK" "$(edit_json "$T_SH" 'PLACEHOLDER' 'echo ok')"
    assert_degraded_pass "T3: 作業ディレクトリの外の %TEMP% の .sh への違反なしの Edit は止めない"
    run_json "$HOOK" "$(edit_json "$T_SH" 'PLACEHOLDER' "$EC_BAD")"
    assert_degraded_fire "T4: 作業ディレクトリの外の %TEMP% の .sh への終了コードの握り潰しは縮退検査で deny" exit-code
  else
    bad "T: %TEMP%（${TEMP:-未設定}）の下に一時ディレクトリを作れない"
  fi
else
  # 理由文はリリースの部分 skip プロファイル（release-skip-profile.tsv）の OS 限定の文言に合わせる。
  # 表に無い理由行は、Windows 以外で回すリリースの gate 段を止める（OBS-434）
  echo "  ○ skip: Windows の Git Bash でだけ成立する検査のため未実行（T 節: %TEMP% の祖先の ACL の経路。作業ディレクトリの外は E 節が見る）"
fi

echo "guard-shell-save: 縮退検査の変異検出（M5 / M6）"
# 変異 5: 場所の拒否を縮退させず、従来どおり判定不能で止める
sed 's/^        outside-authority:\* | replaceable-storage:\* | read-unverifiable:1) degraded=1 ;;$/        __never__) degraded=1 ;;/' "$TARGET" > "$MUT_SRC"
if cmp -s "$TARGET" "$MUT_SRC"; then
  bad "M5: 変異 5 が適用されていない（アンカー不一致）"
else
  MUT5="$TEST_TMP/mut5"
  make_plugin "$MUT5" "$LIB_SRC" "$MUT_SRC"
  run_json "$MUT5/hooks/guard-shell-save.sh" "$(edit_json "$OUT_SH" 'PLACEHOLDER' 'echo ok')"
  if [ "$DECISION" = "deny" ]; then
    ok "M5: 場所の拒否を縮退させないと E1 と同形の Edit が判定不能で止まり、E1 は赤になる"
  else
    bad "M5: 縮退を外しても止まらない: exit=${RC} out=[${OUT}]"
  fi
fi
# 変異 6: 断片の先頭へ pipefail の継承宣言を足さない
sed -e 's/^  before="\${pf_decl}\${nl}\${old}"$/  before="${old}"/' \
    -e 's/^  after="\${pf_decl}\${nl}\${new}"$/  after="${new}"/' "$TARGET" > "$MUT_SRC"
if cmp -s "$TARGET" "$MUT_SRC"; then
  bad "M6: 変異 6 が適用されていない（アンカー不一致）"
else
  MUT6="$TEST_TMP/mut6"
  make_plugin "$MUT6" "$LIB_SRC" "$MUT_SRC"
  run_json "$MUT6/hooks/guard-shell-save.sh" "$(edit_json "$OUT_SH" 'PLACEHOLDER' "$PF_BAD")"
  if [ "$DECISION" != "deny" ]; then
    ok "M6: pipefail の継承宣言を外すと E3 と同形の Edit が素通りし、E3 は赤になる"
  else
    bad "M6: 継承宣言を外しても deny のまま: reason=[${REASON}]"
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
