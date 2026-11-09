#!/usr/bin/env bash
# 停止文の共通形（scripts/lib/stop-block.sh。ADR-084 決定 6 / Issue `#2712`）の契約検査。
# 空振り検出: stop-block.sh が無い・読めない・0 バイトのとき、関数 ff_stop_block を定義しないとき、採用名簿と実体（ff_stop_block を層の語で呼ぶ配布物）の集合が一致しないとき（名簿の縮小・実体の 0 件を含む）、hook の deny 出力が JSON でない・deny でない・理由が空のときは「形に合う」と数えず検査不成立の赤にする。写しで測った: lib の不在 / 読めない / 0 バイト / 関数なしはいずれも冒頭で rc 1、名簿から 1 行消す・guard-literal-write.sh / run-all.sh の呼び出しを消すと R1 が赤、guard-exit-code.sh の deny を `{}` にすると E2・E5 が赤（2026-11-08 macOS / Bash 3.2.57 実測）。
# 変異検出: run-bash-hooks.sh の未実行の注記を理由文の先頭から外すと E4、guard-literal-write.sh の停止文を理由文の前へ置くと E1・E5 が赤（2026-11-08 macOS / Bash 3.2.57 実測）。
# 空振り検出: 写しで測った（2026-11-08 macOS / Bash 3.2.57）: guard-review-in-flight.sh の先頭文の `）: ` から空白を消すと E6 の 2 件、Edit の次の一手へ走行中ロックの ACK の前置（この実測は改名前の名前で行った）を戻すと E6（Edit）、集約 jq の sort_by を外すと E4b、guard-literal-write.sh の lib の source をサブシェルの外へ戻すと E7（guard-literal-write.sh）が赤。走行中ロックの fixture を作れない回は E6 を検査不成立の赤にする。
#
# 検査:
#   U. 単体: 正確な 3 行（AC の文字列そのもの）・語彙外の層 / 空欄 / 改行入りの欄 / kebab-case でない rule-id は
#      stop-block-invalid の 3 行で rc 2・PATH が空でも動く（外部コマンドを起動しない）・`○ skip` で始まる行を出さない
#   R. 採用名簿: 配布物のうち ff_stop_block を層の語で呼ぶファイルの集合が名簿と一致する（縮んでも増えても赤）
#   E. 端から端: 3 hook を deny させる最小入力で permissionDecisionReason の末尾 3 行が形に合い、先頭の
#      `⚠️ ff-dev-toolkit guard（…）:` は変わらない / run-bash-hooks.sh 経由の 2 deny で未実行の注記がブロック群の前に
#      あり、最後の 3 行が形に合う / 停止文を持たない採用外の hook の deny が混ざっても最後の 3 行は停止文（E4b）/
#      stop-block.sh を消した写し（E5）・先頭で exit する写し（E7）では各 hook が stop-block-unavailable の 3 行で deny する /
#      走行中ロックの fixture で Edit と Bash を止めた review-in-flight の deny は先頭文 `…作業ツリー編集の抑止）: ` を保ち、
#      次の一手は Bash だけが FF_REVIEW_LOCK_ACK=1 を含む（E6）
#
# ゲート側の採用（release-skip-profile.sh --check・run-all.sh の必須 skip・リリースの stop()）は既存 suite に
# 1 件ずつ置く（skip-line-contract / tests/run-all/cases/startup-guards.sh / sync-sha-contract/release-runtime.sh）。
# skip 経路は持たない（jq は ADR-084 決定 2 の必須ツール。無ければ赤）。bash 3.2 互換。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PLUGIN_ROOT/scripts/lib/stop-block.sh"
BASH_BIN="${BASH:-bash}"

PASS=0
FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# 利用者の opt-out / ACK と、書き換え経路へ入る Claude Code の環境を引き継がない（deny を書き換えへ逃がさない）。
# 接頭辞の後ろの `_` を必須にしない（素の FF_DEV_TOOLKIT_SKIP=<鍵>[,<鍵>…] も落とす）。
for _v in $(env | sed -n 's/^\(FF_DEV_TOOLKIT_SKIP[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$_v"; done
# L4 宣言の既定の unset（SKIP の 1 変数と、名簿 scripts/lib/l4-declarations.tsv の kind=ack の全件）。
# 名簿との一致は tests/l4-declarations が印の間の名前で照合する（印と並びを崩さない）。
# l4-default-unset:begin
unset FF_DEV_TOOLKIT_SKIP \
  FF_CREDENTIAL_OUTPUT_ACK FF_DISCARD_UNCOMMITTED_ACK FF_EFFORT_ACTUAL_ACK FF_EXIT_CODE_ACK \
  FF_ISSUE_LABEL_ACK FF_LITERAL_WRITE_ACK FF_LONG_GATE_BACKGROUND_ACK FF_MERGE_CLOSING_ACK \
  FF_PR_DRAFT_ACK FF_REVIEW_LOCK_ACK FF_REVIEW_ROUND_ACK FF_RG_STDIN_ACK FF_SHELL_SAVE_ACK \
  FF_SUB_ISSUE_ID_ACK FF_TIMEOUT_ACK FF_UNBOUNDED_WAIT_ACK FF_WSL_SHELL_ACK FF_ZSH_EXPANSION_ACK \
  FF_ZSH_GLOB_ACK 2>/dev/null || true
# l4-default-unset:end
# 名簿の legacy 列（内部の別名）も落とす。名前は名簿から読む（旧名をこの suite に複製しない）。
if [ -r "$PLUGIN_ROOT/scripts/lib/l4-declarations.tsv" ]; then
  while IFS=$'\t' read -r _k _kind _owner _covers _legacy _rest || [ -n "$_k" ]; do
    case "$_legacy" in FF_[A-Z0-9_]*) unset "$_legacy" 2>/dev/null || true ;; esac
  done < "$PLUGIN_ROOT/scripts/lib/l4-declarations.tsv"
fi
unset CLAUDECODE CLAUDE_PROJECT_DIR GROK_PLUGIN_ROOT FF_BASH_HOOKS_NOTICE_LOG \
  ff_bash_hooks_revalidated FF_EXIT_CODE_GUARD_GATES FF_JEV_MODE 2>/dev/null || true
# 巡回カウンタは E6 の主題（走行中ロック）と直交するので無効にする（ホストの値を引き継がない）。
export FF_REVIEW_ROUND_LIMIT=0
# fixture リポジトリ（E6 の走行中ロック）の identity を呼び出し元へ漏らさない（GIT_DIR 系も中和する）
# shellcheck source=../lib/git-fixture.sh
. "$SCRIPT_DIR/../lib/git-fixture.sh"

if WORK="$(mktemp -d "${TMPDIR:-/tmp}/ff-stop-block.XXXXXX")" && [ -d "$WORK" ] && [ ! -L "$WORK" ]; then
  :
else
  echo "✗ stop-block-contract: 一時ディレクトリを作成できない" >&2
  exit 1
fi
REACHED_END=0
cleanup() {
  local rc=$?
  rm -rf -- "$WORK"
  if [ "$REACHED_END" -ne 1 ] && [ "$rc" -eq 0 ]; then rc=1; fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

command -v jq >/dev/null 2>&1 || { echo "✗ stop-block-contract: jq が無い（ADR-084 決定 2 の必須ツール。skip にしない）" >&2; exit 1; }

# ---- 前提: lib の実在（無い・読めない・0 バイト・関数なしは検査不成立） ----------------------
if [ ! -f "$LIB" ] || [ ! -r "$LIB" ] || [ ! -s "$LIB" ]; then
  echo "✗ stop-block-contract: scripts/lib/stop-block.sh が無いか読めないか 0 バイト（検査不成立）: $LIB" >&2
  exit 1
fi
if ! "$BASH_BIN" -c '. "$1" && declare -F ff_stop_block >/dev/null' _ "$LIB" 2>/dev/null; then
  echo "✗ stop-block-contract: scripts/lib/stop-block.sh を source しても ff_stop_block が定義されない（検査不成立）" >&2
  exit 1
fi

# 末尾 3 行が停止文の形か（1 行目 止めた層: <語> / 2 行目 止めた規則: <id>（<正本>）— <理由> / 3 行目 次の一手: <操作>）。
# 引数: <text> <期待する層> <期待する 2 行目の前方一致> [<3 行目に含むべき部分>]
tail_is_block() {
  local text="$1" layer="$2" rule_prefix="$3" next_part="${4:-}" l1 l2 l3 n
  n="$(printf '%s\n' "$text" | grep -c .)"
  [ "$n" -ge 3 ] || return 1
  l1="$(printf '%s\n' "$text" | tail -n 3 | sed -n 1p)"
  l2="$(printf '%s\n' "$text" | tail -n 3 | sed -n 2p)"
  l3="$(printf '%s\n' "$text" | tail -n 3 | sed -n 3p)"
  [ "$l1" = "止めた層: ${layer}" ] || return 1
  case "$l2" in "$rule_prefix"*'— '?*) : ;; *) return 1 ;; esac
  case "$l2" in '止めた規則: '?*'（'?*'）— '?*) : ;; *) return 1 ;; esac
  case "$l3" in '次の一手: '?*) : ;; *) return 1 ;; esac
  [ -z "$next_part" ] || case "$l3" in *"$next_part"*) : ;; *) return 1 ;; esac
  return 0
}
# 次の一手は 1 行だけ（deny 1 件・入れ子の外側が包み直していない）
single_next() { [ "$(printf '%s\n' "$1" | grep -c '^次の一手: ')" -eq 1 ]; }

echo "stop-block-contract: U 単体"
out="$("$BASH_BIN" -c '. "$1"; ff_stop_block 方針 partial-skip-policy tests/lib/release-skip-profile.tsv "理由" "次"' _ "$LIB")"
rc=$?
expected='止めた層: 方針
止めた規則: partial-skip-policy（tests/lib/release-skip-profile.tsv）— 理由
次の一手: 次'
if [ "$rc" -eq 0 ] && [ "$out" = "$expected" ]; then
  ok "U1: 正確な 3 行を出して rc 0（AC の文字列と一致）"
else
  bad "U1: 3 行の形が違う: rc=$rc out=[$out]"
fi

invalid_case() { # <label> <層> <rule-id> <正本> <理由> <次の一手>
  local label="$1" got rc=0 n
  shift
  got="$("$BASH_BIN" -c '. "$1"; shift; ff_stop_block "$@"' _ "$LIB" "$@")" || rc=$?
  n="$(printf '%s\n' "$got" | grep -c .)"
  if [ "$rc" -eq 2 ] && [ "$n" -eq 3 ] && tail_is_block "$got" ガード '止めた規則: stop-block-invalid（scripts/lib/stop-block.sh）'; then
    ok "$label"
  else
    bad "$label: rc=$rc lines=$n out=[$got]"
  fi
}
invalid_case "U2: 語彙外の層（その他）は stop-block-invalid の 3 行で rc 2" その他 a b c d
invalid_case "U3: rule-id が空なら rc 2" 方針 '' tests/x.tsv 理由 次
invalid_case "U4: 次の一手が空なら rc 2" 方針 rule-a tests/x.tsv 理由 ''
invalid_case "U5: kebab-case でない rule-id（大文字・下線・端のハイフン）は rc 2" ガード Bad_Rule tests/x.tsv 理由 次
invalid_case "U6: 改行を含む理由は 3 行を崩すので rc 2" ガード rule-a tests/x.tsv "$(printf '一行目\n二行目')" 次
invalid_case "U7: 正本が空なら rc 2" ガード rule-a '' 理由 次
out="$("$BASH_BIN" -c '. "$1"; ff_stop_block ガード release-gate/gate scripts/release-dev-toolkit.sh "r" "n"' _ "$LIB")"
rc=$?
if [ "$rc" -eq 0 ] && [ "$(printf '%s\n' "$out" | sed -n 2p)" = '止めた規則: release-gate/gate（scripts/release-dev-toolkit.sh）— r' ]; then
  ok "U8: / で区切った段を持つ rule-id（release-gate/<段>）を受ける"
else
  bad "U8: release-gate/<段> を受けない: rc=$rc out=[$out]"
fi
out="$(env PATH= "$BASH_BIN" -c '. "$1"; ff_stop_block 宣言 ack-declared hooks/x.sh "r" "n"' _ "$LIB" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && tail_is_block "$out" 宣言 '止めた規則: ack-declared（hooks/x.sh）'; then
  ok "U9: PATH が空でも 3 行を組める（外部コマンドを起動しない）"
else
  bad "U9: PATH が空だと組めない: rc=$rc out=[$out]"
fi
case "$(printf '%s\n' "$expected" | grep -c '^[[:space:]]*○ skip')" in
  0) ok "U10: どの行も ○ skip で始めない（run-all の per-check 集計が二重に数えない）" ;;
  *) bad "U10: ○ skip で始まる行がある" ;;
esac

echo "stop-block-contract: R 採用名簿"
# 配布物の発生元（プラグイン相対）。リポジトリ直下の scripts/release-dev-toolkit.sh（配布外）は公開 checkout に
# 無いので名簿に入れない（採用は sync-sha-contract/release-runtime.sh が見る）。
ROSTER='hooks/guard-exit-code.sh
hooks/guard-literal-write.sh
hooks/guard-review-in-flight.sh
hooks/run-bash-hooks.sh
tests/lib/release-skip-profile.sh
tests/run-all.sh'
actual=""
for f in "$PLUGIN_ROOT"/hooks/*.sh "$PLUGIN_ROOT"/scripts/*.sh "$PLUGIN_ROOT"/scripts/lib/*.sh \
  "$PLUGIN_ROOT"/tests/run-all.sh "$PLUGIN_ROOT"/tests/lib/*.sh; do
  [ -f "$f" ] || continue
  case "$f" in "$LIB") continue ;; esac
  if grep -Eq 'ff_stop_block (環境|方針|ガード|宣言) ' "$f"; then
    actual="${actual}${f#"$PLUGIN_ROOT"/}
"
  fi
done
actual="$(printf '%s' "$actual" | LC_ALL=C sort)"
if [ -z "$actual" ]; then
  bad "R1: ff_stop_block を呼ぶ配布物が 0 件（走査が空振りしている）"
elif [ "$actual" = "$(printf '%s\n' "$ROSTER" | LC_ALL=C sort)" ]; then
  ok "R1: 採用名簿（$(printf '%s\n' "$ROSTER" | grep -c .) ファイル）と、ff_stop_block を層の語で呼ぶ実体の集合が一致する"
else
  bad "R1: 採用名簿と実体が一致しない — 名簿: [$(printf '%s' "$ROSTER" | tr '\n' ' ')] 実体: [$(printf '%s' "$actual" | tr '\n' ' ')]"
fi

echo "stop-block-contract: E 端から端"
REPO_TOP="$(git -C "$PLUGIN_ROOT" rev-parse --show-toplevel 2>/dev/null)" || REPO_TOP=""
if [ -z "$REPO_TOP" ] || [ ! -d "$REPO_TOP" ]; then
  bad "E0: プラグインの配置が git の作業ツリーに無い（review-in-flight の deny を起こせない。検査不成立）"
  REPO_TOP="$PLUGIN_ROOT"
fi

# hook を 1 本だけ stdin JSON で起動し、deny の理由文を REASON に入れる。JSON でない・deny でない・理由が空は rc 1。
REASON=""
run_deny() { # <hook のパス> <stdin JSON> [<hook の引数>...]
  local hook="$1" json="$2" out rc=0 decision
  shift 2
  REASON=""
  out="$(cd "$REPO_TOP" && printf '%s' "$json" | "$BASH_BIN" "$hook" "$@" 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] || return 1
  decision="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)" || return 1
  [ "$decision" = deny ] || return 1
  REASON="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)" || return 1
  [ -n "$REASON" ]
}
bash_json() { jq -n --arg c "$1" '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}}'; }

# コマンド本文は単一引用符で置く（hook が見るのは文字列そのもの）。
LW_CMD='perl -pi -e '"'"'s/x/${REPO}/'"'"' f'
EC_CMD='npm test | tail -20; echo "EXIT=$?"'
EDIT_JSON="$(jq -n --arg cwd "$REPO_TOP" --arg p "$REPO_TOP/stop-block-contract.probe" \
  '{hook_event_name: "PreToolUse", tool_name: "Edit", cwd: $cwd, tool_input: {file_path: $p, old_string: "a", new_string: "b"}}')"

head_is() { # <text> <先頭行の前方一致>
  case "$(printf '%s\n' "$1" | sed -n 1p)" in "$2"*) return 0 ;; esac
  return 1
}

if run_deny "$PLUGIN_ROOT/hooks/guard-literal-write.sh" "$(bash_json "$LW_CMD")" \
  && head_is "$REASON" '⚠️ ff-dev-toolkit guard（literal-write' \
  && tail_is_block "$REASON" ガード '止めた規則: literal-write（tests/lib/literal-write-scan.sh）' 'FF_LITERAL_WRITE_ACK=1' && single_next "$REASON"; then
  ok "E1: guard-literal-write の deny は先頭文を保ち、末尾 3 行が停止文（ガード / literal-write）"
else
  bad "E1: guard-literal-write の deny の形が違う（JSON でない・deny でない・理由が空を含む）: [$REASON]"
fi
if run_deny "$PLUGIN_ROOT/hooks/guard-exit-code.sh" "$(bash_json "$EC_CMD")" \
  && head_is "$REASON" '⚠️ ff-dev-toolkit guard（終了コードの誤読・握り潰し）' \
  && tail_is_block "$REASON" ガード '止めた規則: exit-code-misread（tests/lib/exit-code-guard.sh）' 'FF_EXIT_CODE_ACK=1' && single_next "$REASON"; then
  ok "E2: guard-exit-code の deny は先頭文を保ち、末尾 3 行が停止文（ガード / exit-code-misread）"
else
  bad "E2: guard-exit-code の deny の形が違う: [$REASON]"
fi

# review-in-flight は、判定ライブラリを欠いた写し（走行中ロックを作らずに deny を起こせる最小の経路）で起こす。
make_replica() { # <dir> <stop-block を置くか 0/1>
  mkdir -p "$1/hooks" "$1/tests/lib" "$1/scripts/lib"
  cp "$PLUGIN_ROOT"/hooks/*.sh "$PLUGIN_ROOT"/hooks/*.mjs "$1/hooks/" 2>/dev/null
  cp "$PLUGIN_ROOT"/tests/lib/*.sh "$1/tests/lib/"
  rm -f "$1/tests/lib/review-in-flight-judge.sh"
  [ "$2" -eq 0 ] || cp "$LIB" "$1/scripts/lib/stop-block.sh"
}
make_replica "$WORK/with-lib" 1
make_replica "$WORK/no-lib" 0
if [ ! -f "$WORK/with-lib/hooks/guard-review-in-flight.sh" ] || [ ! -f "$WORK/no-lib/hooks/guard-exit-code.sh" ] \
  || [ -e "$WORK/no-lib/scripts/lib/stop-block.sh" ]; then
  bad "E0: hook の写しを作れない（検査不成立）"
fi
if run_deny "$WORK/with-lib/hooks/guard-review-in-flight.sh" "$EDIT_JSON" \
  && head_is "$REASON" '⚠️ ff-dev-toolkit guard（レビュー走行中）' \
  && tail_is_block "$REASON" ガード '止めた規則: review-judge-unavailable（tests/lib/review-in-flight-judge.sh）' && single_next "$REASON"; then
  ok "E3: guard-review-in-flight の deny（emit_deny）は先頭文を保ち、末尾 3 行が停止文（ガード）で 1 ブロックだけ"
else
  bad "E3: guard-review-in-flight の deny の形が違う: [$REASON]"
fi
[ "$(printf '%s\n' "$REASON" | grep -c '^止めた層: ')" -eq 1 ] || bad "E3: deny 1 件に停止文が 1 ブロックでない: [$REASON]"

# run-bash-hooks.sh 経由で 2 hook が同時に deny する入力（perl -i のシェル変数 + 出力整形フィルタの直後の $?）
BOTH_CMD='perl -pi -e '"'"'s/x/${REPO}/'"'"' f | tail -1; echo "EXIT=$?"'
NOTE='この呼び出しは 1 つも実行されていません（同じ呼び出しの前段で作るつもりだったファイル・書き込みも存在しません）。生成と、ガードに当たる反映は別の呼び出しに分けて再実行してください。'
if run_deny "$PLUGIN_ROOT/hooks/run-bash-hooks.sh" "$(bash_json "$BOTH_CMD")" \
  "$PLUGIN_ROOT/hooks/guard-exit-code.sh" "$PLUGIN_ROOT/hooks/guard-literal-write.sh"; then
  first_block="$(printf '%s\n' "$REASON" | grep -n '^止めた層: ' | sed -n 1p)"
  first_block="${first_block%%:*}"
  note_line="$(printf '%s\n' "$REASON" | grep -nF "$NOTE" | sed -n 1p)"
  note_line="${note_line%%:*}"
  if [ "$(printf '%s\n' "$REASON" | grep -c '^止めた層: ')" -eq 2 ] && [ -n "$note_line" ] && [ -n "$first_block" ] \
    && [ "$note_line" -lt "$first_block" ] && [ "$(printf '%s\n' "$REASON" | grep -cF "$NOTE")" -eq 1 ] \
    && [ "$(printf '%s\n' "$REASON" | sed -n 1p)" = "$NOTE" ] \
    && tail_is_block "$REASON" ガード '止めた規則: '; then
    ok "E4: 集約入口で 2 deny が並ぶと、未実行の注記がブロック群の前（先頭）に 1 回だけあり、最後の 3 行が停止文"
  else
    bad "E4: 集約入口の並びが違う（注記の位置・ブロック数・末尾）: [$REASON]"
  fi
else
  bad "E4: 集約入口が 2 deny を deny として返さない: [$REASON]"
fi

# 採用外の hook（停止文を持たない deny）が後ろの引数に混ざっても、停止文を持つブロックが最後に並び、
# 理由文の最後の 3 行は停止文のまま（集約 jq の安定ソート。Issue `#2712`）
STUB_HOOK="$WORK/stub-deny.sh"
STUB_REASON='stub guard: 採用外のガードの拒否（停止文なし）'
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' \
  "printf '%s\\n' '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"${STUB_REASON}\"}}'" \
  > "$STUB_HOOK"
if run_deny "$PLUGIN_ROOT/hooks/run-bash-hooks.sh" "$(bash_json "$BOTH_CMD")" \
  "$PLUGIN_ROOT/hooks/guard-exit-code.sh" "$PLUGIN_ROOT/hooks/guard-literal-write.sh" "$STUB_HOOK"; then
  stub_line="$(printf '%s\n' "$REASON" | grep -nF "$STUB_REASON" | sed -n 1p)"
  stub_line="${stub_line%%:*}"
  first_block="$(printf '%s\n' "$REASON" | grep -n '^止めた層: ' | sed -n 1p)"
  first_block="${first_block%%:*}"
  if [ -n "$stub_line" ] && [ -n "$first_block" ] && [ "$(printf '%s\n' "$REASON" | grep -c '^止めた層: ')" -eq 2 ] \
    && [ "$(printf '%s\n' "$REASON" | sed -n 1p)" = "$NOTE" ] \
    && tail_is_block "$REASON" ガード '止めた規則: '; then
    ok "E4b: 停止文の無い deny（採用外の hook）が混ざっても、停止文を持つブロックが最後に並び末尾 3 行が停止文"
  else
    bad "E4b: 採用外の deny が混ざった回の並びが違う（停止文が末尾にない・注記の位置）: [$REASON]"
  fi
else
  bad "E4b: 集約入口が採用外の hook を含む 3 deny を deny として返さない: [$REASON]"
fi

# stop-block.sh を消した写し: 各 hook は stop-block-unavailable の 3 行で deny する（exit 0 で通さない）
for spec in "guard-literal-write.sh|$(bash_json "$LW_CMD")" "guard-exit-code.sh|$(bash_json "$EC_CMD")" \
  "guard-review-in-flight.sh|$EDIT_JSON"; do
  name="${spec%%|*}"
  json="${spec#*|}"
  if run_deny "$WORK/no-lib/hooks/$name" "$json" \
    && tail_is_block "$REASON" ガード '止めた規則: stop-block-unavailable（scripts/lib/stop-block.sh）' 'stop-block.sh を復旧する' && single_next "$REASON"; then
    ok "E5: stop-block.sh の無い写しでも ${name} は stop-block-unavailable の 3 行で deny する"
  else
    bad "E5: stop-block.sh の無い写しで ${name} が deny しない・形が違う: [$REASON]"
  fi
done

# lib の先頭に exit 0 を置いた写し: hook は lib をサブシェルの中でだけ読むので、lib の exit で hook ごと
# 抜けて素通しにならず、stop-block-unavailable の 3 行で deny する
make_replica "$WORK/exit-lib" 1
{ printf '%s\n' 'exit 0'; cat "$LIB"; } > "$WORK/exit-lib/scripts/lib/stop-block.sh"
for spec in "guard-literal-write.sh|$(bash_json "$LW_CMD")" "guard-exit-code.sh|$(bash_json "$EC_CMD")" \
  "guard-review-in-flight.sh|$EDIT_JSON"; do
  name="${spec%%|*}"
  json="${spec#*|}"
  if run_deny "$WORK/exit-lib/hooks/$name" "$json" \
    && tail_is_block "$REASON" ガード '止めた規則: stop-block-unavailable（scripts/lib/stop-block.sh）' 'stop-block.sh を復旧する' && single_next "$REASON"; then
    ok "E7: 先頭で exit する stop-block.sh の写しでも ${name} は素通しせず stop-block-unavailable の 3 行で deny する"
  else
    bad "E7: 先頭で exit する stop-block.sh の写しで ${name} が deny しない・形が違う: [$REASON]"
  fi
done

# 走行中ロック（.review-results/.review-in-flight に生存 PID）を置いた fixture で、通常の review-in-flight の deny を
# Edit と Bash の 2 入力で起こす。先頭文は `…作業ツリー編集の抑止）: ` で始まり、末尾 3 行は review-in-flight の
# 停止文。次の一手は、その呼び出しが実際に通せる形だけを案内する（Bash だけが FF_REVIEW_LOCK_ACK=1 を持つ）
RIF_REPO="$WORK/rif-repo"
RIF_HEAD='⚠️ ff-dev-toolkit guard（レビュー走行中・作業ツリー編集の抑止）: '
if ff_git_fixture_init "$RIF_REPO" "stop-block-contract" "stop-block@example.invalid" \
  && RIF_REPO="$(cd "$RIF_REPO" && pwd -P)" \
  && ( . "$PLUGIN_ROOT/scripts/lib/multi-agent-boundary.sh" \
    && ff_review_output_prepare "$RIF_REPO" "$RIF_REPO/.review-results" false review ) >/dev/null 2>&1 \
  && printf 'pid=%s\ntask=review\nhead=abcdef1234567890\nstarted=2026-11-08T00:00:00Z\nstarted_epoch=%s\nperspectives=code-review\n' \
    "$$" "$(($(date -u +%s) - 42))" > "$RIF_REPO/.review-results/.review-in-flight"; then
  rif_edit="$(jq -n --arg d "$RIF_REPO" \
    '{hook_event_name: "PreToolUse", tool_name: "Edit", cwd: $d, tool_input: {file_path: "a.txt", old_string: "a", new_string: "b"}}')"
  rif_bash="$(jq -n --arg d "$RIF_REPO" \
    '{hook_event_name: "PreToolUse", tool_name: "Bash", cwd: $d, tool_input: {command: "git commit -m x"}}')"
  if run_deny "$PLUGIN_ROOT/hooks/guard-review-in-flight.sh" "$rif_edit" \
    && head_is "$REASON" "$RIF_HEAD" \
    && tail_is_block "$REASON" ガード '止めた規則: review-in-flight（tests/lib/review-in-flight-judge.sh）' && single_next "$REASON" \
    && case "$(printf '%s\n' "$REASON" | tail -n 1)" in *FF_REVIEW_LOCK_ACK=1*) false ;; *) true ;; esac; then
    ok "E6: 走行中ロックで Edit を止めた deny は先頭文（…編集の抑止）: ）を保ち、末尾 3 行が review-in-flight の停止文で、次の一手に FF_REVIEW_LOCK_ACK=1 を含まない"
  else
    bad "E6: 走行中ロックで Edit を止めた deny の形が違う（先頭文・規則・次の一手）: [$REASON]"
  fi
  if run_deny "$PLUGIN_ROOT/hooks/guard-review-in-flight.sh" "$rif_bash" \
    && head_is "$REASON" "$RIF_HEAD" \
    && tail_is_block "$REASON" ガード '止めた規則: review-in-flight（tests/lib/review-in-flight-judge.sh）' 'FF_REVIEW_LOCK_ACK=1' \
    && single_next "$REASON"; then
    ok "E6: 走行中ロックで Bash（git commit）を止めた deny は先頭文を保ち、末尾 3 行が review-in-flight の停止文で、次の一手に FF_REVIEW_LOCK_ACK=1 を含む"
  else
    bad "E6: 走行中ロックで Bash を止めた deny の形が違う（先頭文・規則・次の一手）: [$REASON]"
  fi
else
  bad "E6: 走行中ロックの git fixture を作れない（検査不成立）"
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ stop-block-contract verify: ${FAIL} 件失敗 / ${PASS} 件成功" >&2
  exit 1
fi
REACHED_END=1
echo "✓ stop-block-contract verify: 全 ${PASS} 件 pass"
