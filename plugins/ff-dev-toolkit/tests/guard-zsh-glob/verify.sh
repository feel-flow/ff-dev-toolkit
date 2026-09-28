#!/usr/bin/env bash
# Runtime contract for the zsh unquoted-glob NOMATCH guard hook (Issue `#1774`).
#
# 配布物 hooks/guard-zsh-glob.sh を stdin JSON で直接駆動し、受け入れ条件の各分岐を固定する:
#   F. zsh ホストで `--flag=<未引用 glob>` を含む呼び出しは実行前に deny し、書き換え案を出す
#   N. 引用済み・エスケープ済み・一般のパス glob・glob として評価されない文脈は素通し
#   H. bash ホスト（SHELL / CLAUDE_CODE_SHELL で判定）では発火しない
#   A. 抜け道（先頭の FF_ZSH_GLOB_ACK=1 / skip env）で通る。先頭以外の ACK は無効
#   C. 候補コマンドで判定ヘルパを読めない・走査が失敗するときは理由付き deny（fail-closed）、
#      候補でないコマンドはヘルパが壊れていても素通し（面を候補に限る）
#   O. JSON でない入力・jq 不在・Bash 以外は素通し（fail-open）
#   D. stdin の drain（opt-out・ASDD ゲートの早期終了経路を含む）
#   R. hooks.json の集約入口への登録
#   Z. zsh 固有: 述語が真陽性と断定した形は実際に zsh で NOMATCH になり、書き換え案は通る。
#      素通しさせる形は zsh で NOMATCH にならない（zsh が無いホストでは skip）
#   M. 変異検出
#
# 変異検出: hook のホスト判定（zsh | zsh-*) の分岐）を bash にも当たるよう書き換えたコピーは AC4（bash ホストでは発火しない）と同形の検査を赤にする（M1）。
# 変異検出: 判定ヘルパの `case` パターン除外（cs[d] == 3 の語を読み飛ばす行）を消したコピーは N 系の case パターン検査と同形の検査を赤にする（M2）。
# 変異検出: 判定ヘルパの glob 文字から `[` を外したコピーは F の `--jq=.[0].name` と同形の検査を赤にする（M3）。
# 変異検出: hook の ACK 分岐（FF_ZSH_GLOB_ACK=1 で exit 0）を無効化すると A 系 2 件と C5 が赤になる（実測 2026-09-27。以下 4 行も同日に suite 外から本体へ注入して測った）。
# 変異検出: heredoc 除去を外して生コマンドを走査させると N13（heredoc 本文）と PR 本文 heredoc の検査が赤になる。
# 変異検出: 判定ヘルパの noglob / [[ ]] / コメントの除外をそれぞれ消すと、対応する N 系の検査が 1 件ずつ赤になる。
# 変異検出: hook の走査 rc の判定（非 0 を判定不能の deny へ倒す行）を外すと C2 が赤になる。
# 変異検出: 判定ヘルパの未終端検出（END の exit 4）を外すと C6 が赤になる（セルフレビュー対応後に実測。以下 4 行も同じ）。
# 変異検出: `${…}` / `$((…))` の中の二重引用の入れ子読みを外すと F13 が「判定不能で止まった」として赤になる。
# 変異検出: `${…}` / `$((…))` の中の `$(…)` の入れ子読みを外すと F14・F15 が赤になる。
# 変異検出: 書き換え案の brace 除外を外すと brace の検査が赤になり、hook の ASDD 検証不能の deny を外すと C7 が赤になる。
# 変異検出: 判定ヘルパの `;` での noglob 解除・`]]` での [[ 解除・`esac` での case 解除をそれぞれ外すと、後続を持つ F 系（noglob / [[ / case の後ろの grep）が赤になる（テスト網羅レビュー対応後に実測）。
# 変異検出: hook の未終端 heredoc（rc 3）を素通しへ変えると C9、deny JSON 失敗時の exit 2 を exit 0 へ変えると C10 が赤になる。
# 変異検出: 判定ヘルパの case の入れ子の復元（case_close で積んだ状態へ戻す）を cs=0 に戻すと N6（入れ子の case の外側パターン）が赤になる（クロスモデルレビュー対応後に実測）。
# 空振り検出: 判定ヘルパが存在しない配置（対象の不在）・走査の awk が失敗する（FF_ZSH_GLOB_AWK=false）・関数が無い（名前だけ残って中身が変わる）のいずれを与えても、候補コマンドは無音の素通しではなく判定不能の deny になり C1〜C3 が赤→緑を分ける（どの入力にも 0 件を返すヘルパでは F 系 21 形がすべて素通しになり赤になる。M4。引用が閉じないまま終わる入力（未終端）は走査未完了の rc 4 として C6 が判定不能の deny を要求する。実測 2026-09-27）。
#
# 空振り検出: expansion の不在・関数欠落・awk失敗は判定不能、空出力変異は陽性対照で赤。
# run-all-required: no — jq 不在での skip を許容する（兄弟の hook suite と同じ判断）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$PLUGIN_ROOT/hooks/guard-zsh-glob.sh"
# ホスト環境の解除変数・テストシーム（hook 実装とその参照先が読む FF_* / CLAUDE_*）を
# 先頭で 1 回落とす。ケース固有の `NAME=v bash "$TARGET"` はこの後に代入として届く（Issue `#1808`）。
# shellcheck source=../lib/adapter-env-isolation.sh
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"
isolate_hook_env "FF_DEV_TOOLKIT_SKIP_ZSH_GLOB_GUARD" "$TARGET"
SCAN_LIB="$PLUGIN_ROOT/tests/lib/zsh-glob-nomatch.sh"
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"
# shellcheck source=../lib/asdd-gate-drain.sh
. "$SCRIPT_DIR/../lib/asdd-gate-drain.sh"

[ -f "$TARGET" ] || { echo "✗ guard-zsh-glob.sh が見つかりません: $TARGET" >&2; exit 1; }
[ -f "$SCAN_LIB" ] || { echo "✗ zsh-glob-nomatch.sh が見つかりません: $SCAN_LIB" >&2; exit 1; }
[ -f "$HOOKS_JSON" ] || { echo "✗ hooks.json が見つかりません: $HOOKS_JSON" >&2; exit 1; }
if ! command -v jq >/dev/null 2>&1; then
  echo "○ skip: jq が見つからないためスキップ（guard-zsh-glob は未検査のままです）"
  exit 0
fi

# 利用者の環境（ホストのシェル・抜け道・opt-out）を引き継いで偽緑 / 偽赤にしない。
unset CLAUDE_CODE_SHELL FF_ZSH_GLOB_ACK FF_DEV_TOOLKIT_SKIP_ZSH_GLOB_GUARD FF_ZSH_GLOB_AWK
# 既存 glob の契約を単独検査し、追加検出は X 節で有効化する。
export FF_DEV_TOOLKIT_SKIP_ZSH_EXPANSION_GUARD=1

if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/ff-guard-zsh-glob.XXXXXX" 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  TEST_TMP="$_ff_mktemp_out"
else
  echo "✗ 一時ディレクトリを作成できません: $_ff_mktemp_out" >&2
  exit 1
fi
REACHED_END=0
cleanup() {
  local rc=$?
  rm -rf "$TEST_TMP"
  if [ "$REACHED_END" -ne 1 ] && [ "$rc" -eq 0 ]; then
    echo "✗ guard-zsh-glob: 最後まで到達しませんでした" >&2
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

OUT=""
RC=0
DECISION=""
REASON=""

# run_on <hook> <command> [NAME=VALUE ...]（既定のホストは SHELL=/bin/zsh）
run_on() {
  local hook="$1" cmd="$2" json
  shift 2
  json="$(jq -n --arg c "$cmd" --arg d "$TEST_TMP" \
    '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d, hook_event_name: "PreToolUse"}')"
  RC=0
  OUT="$(printf '%s' "$json" | env SHELL=/bin/zsh "$@" bash "$hook" 2>/dev/null)" || RC=$?
  DECISION="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)"
  REASON="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || true)"
}
run_hook() { run_on "$TARGET" "$@"; }

assert_fire() { # <label>
  if [ "$RC" -eq 0 ] && [ "$DECISION" = "deny" ]; then
    ok "$1"
  else
    bad "$1: exit=$RC decision=[$DECISION] out=[$OUT]"
  fi
}
assert_pass() { # <label>
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    ok "$1"
  else
    bad "$1: exit=$RC out=[$OUT]"
  fi
}
assert_unavailable() { # <label>
  if [ "$RC" -eq 0 ] && [ "$DECISION" = "deny" ]; then
    case "$REASON" in
      *判定不能*) ok "$1" ;;
      *) bad "$1: deny だが判定不能の理由になっていない: [$REASON]" ;;
    esac
  else
    bad "$1: exit=$RC decision=[$DECISION] out=[$OUT]"
  fi
}

# 発火させる形（F 系と Z 系で共有する。zsh で必ず NOMATCH になるはずの形）
FIRE_CASES=(
  'grep -rn "x" docs --include=*.md'
  'grep -rn x . --include=*.md | grep -v __tests__'
  'out=$(grep -rn x . --include=*.ts | head -1)'
  'echo "$(grep -rn x . --include=*.ts)"'
  'true && grep -c x . --include=*.sh'
  'gh api repos/acme/widgets --jq=.[0].name'
  'rg --glob=*.{ts,tsx} x .'
  'grep x "--include"=*.md .'
  'ext=m; grep x . --include=*.$ext'
  'grep --include=*.md x \
  .'
  '(cd . && grep --include=*.md x .)'
  'for f in --a=*; do :; done'
  'echo ${x:-"}"}; grep -rn x --include=*.md .'
  'echo ${x:-$(grep -rln x --include=*.md .)}'
  'echo $(( $(grep -rc x --include=*.md . | wc -l) + 1 ))'
  'noglob echo a; grep --include=*.md x .'
  '[[ -n x ]] && grep --include=*.md x .'
  'case a in a) :;; esac; grep --include=*.md x .'
  'case x in x) case y in y) :;; esac;; esac; grep --include=*.md x .'
  'echo `grep --include=*.md x .`'
  'cat <(grep --include=*.md x .)'
)
# 素通しさせる形のうち、zsh で実際に実行が成立する形（Z 系で NOMATCH にならないことも実測する）
PASS_CASES=(
  'grep -rn "x" docs --include="*.md"'
  "grep -rn x docs --include='*.md'"
  'grep -rn x docs --include=\*.md'
  'ls *.md'
  'case --a=b in --include=*) echo y;; --a=?) echo z;; esac'
  'case x in x) case y in y) :;; esac;; --a=*) :;; esac'
  '[[ --a=b == --a=* ]] && echo ok'
  'noglob grep -c --include=*.md x .'
  'git --version # grep --include=*.md'
  'echo "use --include=*.md"'
  "echo \$'--a=*'"
  'FOO=*.md; echo "$FOO"'
  'git log -1 --pretty=format:%h --since=2.weeks'
  'cat <<EOF
grep --include=*.md x .
EOF'
)

echo "guard-zsh-glob: F 発火（zsh ホスト）"
run_hook 'grep -rn "x" docs --include=*.md'
assert_fire "AC1: zsh ホストで grep --include=*.md は実行前に deny"
case "$REASON" in
  *'--include="*.md"'*) ok "AC1: 書き換え案 --include=\"*.md\" を出す" ;;
  *) bad "AC1: 書き換え案が無い: [$REASON]" ;;
esac
case "$REASON" in
  *'--include=*.md'*) ok "AC1: 検出した実値を出す" ;;
  *) bad "AC1: 実値が無い: [$REASON]" ;;
esac
fire_i=0
for c in "${FIRE_CASES[@]}"; do
  fire_i=$((fire_i + 1))
  run_hook "$c"
  assert_fire "F${fire_i}: deny [$c]"
  case "$REASON" in
    *判定不能*) bad "F${fire_i}: 検出ではなく判定不能で止まった（走査が途中で外れている）: [$c]" ;;
    *'検出した語'*) ok "F${fire_i}: 検出した語として名指しする [$c]" ;;
    *) bad "F${fire_i}: 検出した語の一覧が無い: [$REASON]" ;;
  esac
done
run_hook 'grep -rn x docs --include=*.md' CLAUDE_CODE_SHELL=/bin/zsh SHELL=/bin/bash
assert_fire "CLAUDE_CODE_SHELL=zsh は SHELL=bash より優先して発火する"
run_hook 'grep -rn x docs --include=*.md' SHELL=/opt/homebrew/bin/zsh
assert_fire "zsh の配置が /bin 以外でも basename で判定して発火する"

echo "guard-zsh-glob: 停止文の契約（対処と抜け道を出力自体に案内する）"
run_hook 'grep -rn x docs --include=*.md'
for needle in 'FF_ZSH_GLOB_ACK=1' 'FF_DEV_TOOLKIT_SKIP_ZSH_GLOB_GUARD=1' "bash <<'EOF'" 'no matches found' 'zsh-glob-nomatch.sh'; do
  case "$REASON" in
    *"$needle"*) ok "停止文が [$needle] を含む" ;;
    *) bad "停止文に [$needle] が無い: [$REASON]" ;;
  esac
done
run_hook 'grep x "--include"=*.md .'
case "$REASON" in
  *'書き換え案は出していません'*) ok "引用を含む語は機械的な書き換え案を出さず、引用の方針だけを案内する" ;;
  *) bad "引用を含む語の案内が無い: [$REASON]" ;;
esac

run_hook 'grep -rn x . --include=*.{md,sh}'
case "$REASON" in
  *'--include="*.{md,sh}"'*) bad "brace を含む語へ = の右側ごと引用する書き換え案を出した（brace 展開が止まり grep が 0 件一致で黙って終わる）: [$REASON]" ;;
  *'書き換え案は出していません'*) ok "brace を含む語は機械的な書き換え案を出さない（brace 展開を壊さない）" ;;
  *) bad "brace を含む語の案内が無い: [$REASON]" ;;
esac

echo "guard-zsh-glob: N 非発火（zsh ホスト）"
pass_i=0
for c in "${PASS_CASES[@]}"; do
  pass_i=$((pass_i + 1))
  run_hook "$c"
  assert_pass "N${pass_i}: 素通し [$c]"
done
run_hook 'git commit -m "--include=*.md を引用する"'
assert_pass "二重引用の散文は素通し"
run_hook "gh pr create --body \"\$(cat <<'EOF'
grep -rn x docs --include=*.md
EOF
)\""
assert_pass "PR 本文の heredoc 本文はデータとして素通し"

echo "guard-zsh-glob: H ホスト判定"
run_hook 'grep -rn "x" docs --include=*.md' SHELL=/bin/bash
assert_pass "AC4: bash ホストでは発火しない"
run_hook 'grep -rn "x" docs --include=*.md' SHELL=/bin/zsh CLAUDE_CODE_SHELL=/bin/bash
assert_pass "CLAUDE_CODE_SHELL=bash は SHELL=zsh より優先して発火しない"
run_hook 'grep -rn "x" docs --include=*.md' SHELL=
assert_pass "ホストのシェルが分からない（SHELL 空）ときは発火しない"

echo "guard-zsh-glob: A 抜け道"
run_hook 'FF_ZSH_GLOB_ACK=1 grep -rn "x" docs --include=*.md'
assert_pass "AC5: コマンド先頭の FF_ZSH_GLOB_ACK=1 で通る"
run_hook 'LC_ALL=C FF_ZSH_GLOB_ACK=1 grep -rn "x" docs --include=*.md'
assert_fire "ACK は呼び出しの先頭の語に限る（前に別の環境代入があると無効。guard-exit-code と同じリテラル判定）"
run_hook 'echo FF_ZSH_GLOB_ACK=1; grep -rn "x" docs --include=*.md'
assert_fire "先頭以外（別コマンドの引数）の ACK は無効"
run_hook 'X=1; FF_ZSH_GLOB_ACK=1 true; grep -rn x --include=*.md .'
assert_fire "前の文の後ろに置いた ACK は無効（先頭の語だけ）"
run_hook 'FF_ZSH_GLOB_ACK=1 true
grep -rn x --include=*.md .'
assert_pass "呼び出しの先頭に置いた ACK は呼び出し全体に効く（単位は Bash ツールの 1 呼び出し）"
run_hook "A='x FF_ZSH_GLOB_ACK=1 y' grep -rn x --include=*.md ."
assert_fire "引用値の中に現れる ACK は無効"
run_hook 'grep -rn "x" docs --include=*.md' FF_DEV_TOOLKIT_SKIP_ZSH_GLOB_GUARD=1
assert_pass "FF_DEV_TOOLKIT_SKIP_ZSH_GLOB_GUARD=1 で無効化できる"

echo "guard-zsh-glob: C 判定不能（候補コマンドに限り fail-closed）"
make_tree() { # <dir>
  mkdir -p "$1/hooks" "$1/tests/lib"
  cp "$TARGET" "$PLUGIN_ROOT/hooks/asdd-hook-gate.sh" "$PLUGIN_ROOT/hooks/asdd-feature.mjs" "$1/hooks/"
  cp "$PLUGIN_ROOT/tests/lib/zsh-expansion-guard.sh" "$PLUGIN_ROOT/tests/lib/heredoc-strip.sh" "$SCAN_LIB" "$1/tests/lib/"
}
NOLIB="$TEST_TMP/nolib"
make_tree "$NOLIB"
rm -f "$NOLIB/tests/lib/zsh-glob-nomatch.sh"
run_on "$NOLIB/hooks/guard-zsh-glob.sh" 'grep -rn x docs --include=*.md'
assert_unavailable "C1: 判定ヘルパが無い配置では候補コマンドを判定不能の deny にする"
run_on "$NOLIB/hooks/guard-zsh-glob.sh" 'git status --short'
assert_pass "C1': 判定ヘルパが無くても候補でないコマンドは素通し（復旧作業を止めない）"
run_hook 'grep -rn x docs --include=*.md' FF_ZSH_GLOB_AWK=false
assert_unavailable "C2: 走査の awk が失敗したら判定不能の deny にする"
NOFN="$TEST_TMP/nofn"
make_tree "$NOFN"
printf '# 関数定義を失ったヘルパ\n' > "$NOFN/tests/lib/zsh-glob-nomatch.sh"
run_on "$NOFN/hooks/guard-zsh-glob.sh" 'grep -rn x docs --include=*.md'
assert_unavailable "C3: ヘルパに ff_zsh_glob_scan が無いときは判定不能の deny にする"
NOHD="$TEST_TMP/nohd"
make_tree "$NOHD"
rm -f "$NOHD/tests/lib/heredoc-strip.sh"
run_on "$NOHD/hooks/guard-zsh-glob.sh" 'grep -rn x docs --include=*.md'
assert_unavailable "C4: heredoc 除去ヘルパが無いときも判定不能の deny にする"
run_on "$NOLIB/hooks/guard-zsh-glob.sh" 'FF_ZSH_GLOB_ACK=1 grep -rn x docs --include=*.md'
assert_pass "C5: 判定不能の状態でも先頭の ACK で通れる（案内した抜け道が効く）"
run_hook 'echo "unterminated; grep -rn x --include=*.md .'
assert_unavailable "C6: 引用が閉じないまま終わる候補コマンドは走査未完了として判定不能の deny にする"
run_hook 'echo "unterminated'
assert_pass "C6': 候補でない（= と glob 文字が無い）未終端コマンドは素通し"
ASDD_NONODE="$TEST_TMP/asdd-nonode"
mkdir -p "$ASDD_NONODE" "$TEST_TMP/jq-only-bin"
ff_asdd_fixture "$ASDD_NONODE" true
ln -s "$(command -v jq)" "$TEST_TMP/jq-only-bin/jq"
if PATH="$TEST_TMP/jq-only-bin:/usr/bin:/bin" command -v node >/dev/null 2>&1; then
  echo "  ○ skip: /usr/bin か /bin に node があるため ASDD 検証不能（node 不在）の経路は未検査"
else
  json_c7="$(jq -n '{tool_name: "Bash", tool_input: {command: "grep -rn x --include=*.md ."}}')"
  RC=0
  OUT="$(cd "$ASDD_NONODE" && printf '%s' "$json_c7" | env SHELL=/bin/zsh PATH="$TEST_TMP/jq-only-bin:/usr/bin:/bin" /bin/bash "$TARGET" 2>/dev/null)" || RC=$?
  DECISION="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)"
  REASON="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || true)"
  case "$DECISION:$REASON" in
    deny:*ASDD*) ok "C7: ASDD 設定を検証できない（config あり・node 不在）回は候補コマンドを判定不能の deny にする" ;;
    *) bad "C7: ASDD 検証不能が素通しになった: exit=$RC out=[$OUT]" ;;
  esac
fi

run_hook 'grep -rn x docs --include=*.md' FF_HEREDOC_AWK=false
assert_unavailable "C8: heredoc 除去の awk が失敗したら判定不能の deny にする"
run_hook 'cat <<EOF
grep --include=*.md x .'
case "$DECISION:$REASON" in
  deny:*判定不能*) bad "C9: 未終端 heredoc が判定不能で止まった（生コマンドを走査していない）: [$REASON]" ;;
  deny:*'検出した語'*) ok "C9: 未終端 heredoc（<< の誤検出扱い）は本文除去前の生コマンドを走査して検出する" ;;
  *) bad "C9: 未終端 heredoc の後ろの形を素通しした: exit=$RC out=[$OUT]" ;;
esac
mkdir -p "$TEST_TMP/jq-fail-n"
REAL_JQ="$(command -v jq)"
cat > "$TEST_TMP/jq-fail-n/jq" <<SHIM
#!/bin/bash
case " \$* " in *" -n "*) exit 1 ;; esac
exec "$REAL_JQ" "\$@"
SHIM
chmod +x "$TEST_TMP/jq-fail-n/jq"
json_c10="$(jq -n '{tool_name: "Bash", tool_input: {command: "grep -rn x --include=*.md ."}}')"
RC=0
ERR="$(printf '%s' "$json_c10" | env SHELL=/bin/zsh PATH="$TEST_TMP/jq-fail-n:$PATH" bash "$TARGET" 2>&1 >/dev/null)" || RC=$?
case "$RC:$ERR" in
  2:*'--include=*.md'*) ok "C10: deny の JSON を組み立てられないときは exit 2 + stderr の理由でブロックする（黙って許可しない）" ;;
  *) bad "C10: jq -n 失敗時の経路: rc=$RC err=[$ERR]" ;;
esac

echo "guard-zsh-glob: O fail-open（対象外）"
RC=0
OUT="$(printf 'not-json --include=*.md' | env SHELL=/bin/zsh bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "JSON でない入力は無出力 exit 0"; else bad "JSON でない入力: exit=$RC out=[$OUT]"; fi
JSON_WRITE="$(jq -n '{tool_name: "Write", tool_input: {command: "grep --include=*.md x .", content: "--include=*.md"}}')"
RC=0
OUT="$(printf '%s' "$JSON_WRITE" | env SHELL=/bin/zsh bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "Bash 以外のツールは無出力 exit 0"; else bad "Bash 以外: exit=$RC out=[$OUT]"; fi
JSON_FIRE="$(jq -n '{tool_name: "Bash", tool_input: {command: "grep --include=*.md x ."}}')"
RC=0
OUT="$(printf '%s' "$JSON_FIRE" | env SHELL=/bin/zsh PATH=/nonexistent /bin/bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "jq 不在（候補かどうか決められない）は無出力 exit 0"; else bad "jq 不在: exit=$RC out=[$OUT]"; fi

echo "guard-zsh-glob: D stdin の drain"
BIG_PAYLOAD="$(jq -n '{tool_name: "Bash", tool_input: {command: "echo ok"}, cwd: "/tmp"}')$(printf '%*s' 200000 '')"
RC=0
OUT="$(printf '%s' "$BIG_PAYLOAD" | env SHELL=/bin/zsh PATH=/nonexistent /bin/bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "PATH 空の環境でも stdin を読み切ってから無出力 exit 0"
else
  bad "PATH 空の drain: exit=$RC out=[$OUT]（rc=141 なら hook が stdin を drain せずに exit している）"
fi
RC=0
OUT="$(printf '%s' "$BIG_PAYLOAD" | env SHELL=/bin/zsh FF_DEV_TOOLKIT_SKIP_ZSH_GLOB_GUARD=1 PATH=/nonexistent /bin/bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "opt-out でも stdin を読み切ってから無出力 exit 0"; else bad "opt-out の drain: exit=$RC out=[$OUT]"; fi
ASDD_ON="$TEST_TMP/asdd-hooks-on"
ASDD_OFF="$TEST_TMP/asdd-hooks-off"
mkdir -p "$ASDD_ON" "$ASDD_OFF"
ff_asdd_fixture "$ASDD_ON" true
ff_asdd_fixture "$ASDD_OFF" false
ASDD_PAYLOAD="$(ff_asdd_big_payload '{"tool_name":"Bash","tool_input":{"command":"grep --include=*.md x ."},"cwd":"/tmp","hook_event_name":"PreToolUse"}')"
ff_asdd_drain_probe "$TARGET" "$ASDD_PAYLOAD" "$ASDD_ON" PATH=/nonexistent SHELL=/bin/zsh
if [ "$FF_ASDD_DRAIN_RC" -eq 0 ] && [ -z "$FF_ASDD_DRAIN_OUT" ]; then
  ok ".asdd 設定あり + node 不在（ゲートが停止）でも stdin を読み切ってから無出力 exit 0"
else
  bad "ASDD ゲート（node 不在）の drain: exit=$FF_ASDD_DRAIN_RC out=[$FF_ASDD_DRAIN_OUT]"
fi
if command -v node >/dev/null 2>&1; then
  ff_asdd_drain_probe "$TARGET" "$ASDD_PAYLOAD" "$ASDD_OFF" SHELL=/bin/zsh
  if [ "$FF_ASDD_DRAIN_RC" -eq 0 ] && [ -z "$FF_ASDD_DRAIN_OUT" ]; then
    ok "features.hooks=false（ゲートが無効と判定）でも stdin を読み切ってから無出力 exit 0"
  else
    bad "ASDD ゲート（feature 無効）の drain: exit=$FF_ASDD_DRAIN_RC out=[$FF_ASDD_DRAIN_OUT]"
  fi
else
  echo "  ○ skip: node が無いため features.hooks=false 経路は未検査（guard-zsh-glob の ASDD ゲート無効判定）"
fi

echo "guard-zsh-glob: R hooks.json 登録の静的照合"
if jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]
    | select((.command | contains("run-bash-hooks.sh")) and (.command | contains("guard-zsh-glob.sh")))' "$HOOKS_JSON" >/dev/null 2>&1; then
  ok "hooks.json の PreToolUse（Bash matcher）の集約入口 run-bash-hooks.sh に登録されている"
else
  bad "hooks.json の PreToolUse（Bash matcher）の集約入口に guard-zsh-glob.sh が無い"
fi
DESC="$(jq -r '.description' "$HOOKS_JSON")"
case "$DESC" in
  *guard-zsh-glob.sh*FF_ZSH_GLOB_ACK*) ok "hooks.json の description が zsh glob ガードと抜け道に言及する" ;;
  *) bad "hooks.json の description に guard-zsh-glob.sh / FF_ZSH_GLOB_ACK の記述が無い" ;;
esac

echo "guard-zsh-glob: Z zsh 固有（述語の性質を実際の zsh で確かめる）"
if ZSH_BIN="$(command -v zsh 2>/dev/null)" && [ -n "$ZSH_BIN" ]; then
  ZDIR="$TEST_TMP/zsh-cwd"
  mkdir -p "$ZDIR/docs"
  # cwd に .md / .ts / .sh が実在していても NOMATCH になることを測る（cwd 非依存の実測）
  printf 'x\n' > "$ZDIR/docs/a.md"
  printf 'x\n' > "$ZDIR/a.ts"
  printf 'x\n' > "$ZDIR/a.md"
  printf 'x\n' > "$ZDIR/a.sh"
  z_i=0
  for c in "${FIRE_CASES[@]}"; do
    z_i=$((z_i + 1))
    zrc=0
    zout="$(cd "$ZDIR" && "$ZSH_BIN" -f -c "$c" 2>&1 >/dev/null)" || zrc=$?
    case "$zout" in
      *'no matches found'*) ok "Z${z_i}: zsh は NOMATCH で実行しない [$c]" ;;
      *) bad "Z${z_i}: 述語が真陽性とした形が zsh で NOMATCH にならない: rc=$zrc err=[$zout] [$c]" ;;
    esac
  done
  zp_i=0
  for c in "${PASS_CASES[@]}"; do
    zp_i=$((zp_i + 1))
    zout="$(cd "$ZDIR" && "$ZSH_BIN" -f -c "$c" 2>&1 >/dev/null)" || true
    case "$zout" in
      *'no matches found'*) bad "ZP${zp_i}: 素通しさせる形が zsh で NOMATCH になった（取りこぼし）: [$c]" ;;
      *) ok "ZP${zp_i}: zsh で NOMATCH にならない [$c]" ;;
    esac
  done
  zout="$(cd "$ZDIR" && "$ZSH_BIN" -f -c 'grep -rn x docs --include="*.md"' 2>&1)" || true
  case "$zout" in
    *'docs/a.md'*) ok "書き換え案（--include=\"*.md\"）は zsh で実行が成立し一致を返す" ;;
    *) bad "書き換え案が zsh で成立しない: [$zout]" ;;
  esac
  zrc=0
  (cd "$ZDIR" && bash -c 'grep -rn x docs --include=*.md' >/dev/null 2>&1) || zrc=$?
  if [ "$zrc" -eq 0 ]; then ok "同じ未引用の形は bash では通る（bash ホストで発火させない根拠）"; else bad "bash でも失敗した: rc=$zrc"; fi
else
  echo "  ○ skip: zsh が無いため Z 系（実際の zsh での NOMATCH 実測）は未検査"
fi

echo "guard-zsh-glob: M 変異検出（コピーへ当て、本番検査と同形の針が赤になること）"
MUT="$TEST_TMP/mut"
make_tree "$MUT"
sed 's/^  zsh | zsh-\*) : ;;$/  zsh | zsh-* | bash) : ;;/' "$TARGET" > "$MUT/hooks/guard-zsh-glob.sh"
run_on "$MUT/hooks/guard-zsh-glob.sh" 'grep -rn "x" docs --include=*.md' SHELL=/bin/bash
if [ "$DECISION" = "deny" ]; then
  ok "M1: ホスト判定を bash へ広げた変異は bash ホストで deny し、H の検査が赤になる"
else
  bad "M1: ホスト判定の変異が効いていない（sed が当たっていない可能性）: decision=[$DECISION]"
fi
cp "$TARGET" "$MUT/hooks/guard-zsh-glob.sh"
sed '/if (cs\[d\] == 3) {/d' "$SCAN_LIB" > "$MUT/tests/lib/zsh-glob-nomatch.sh"
run_on "$MUT/hooks/guard-zsh-glob.sh" 'case --a=b in --include=*) echo y;; esac'
if [ "$DECISION" = "deny" ]; then
  ok "M2: case パターン除外を消した変異は case パターンを deny し、N の検査が赤になる"
else
  bad "M2: case パターン除外の変異が効いていない: decision=[$DECISION] out=[$OUT]"
fi
sed 's/ || ch == "\[")) {/)) {/' "$SCAN_LIB" > "$MUT/tests/lib/zsh-glob-nomatch.sh"
run_on "$MUT/hooks/guard-zsh-glob.sh" 'gh api repos/acme/widgets --jq=.[0].name'
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "M3: glob 文字から [ を外した変異は --jq=.[0].name を素通しし、F の検査が赤になる"
else
  bad "M3: [ 除外の変異が効いていない: decision=[$DECISION]"
fi
printf 'ff_zsh_glob_scan() { return 0; }\n' > "$MUT/tests/lib/zsh-glob-nomatch.sh"
m4_pass=0
for c in "${FIRE_CASES[@]}"; do
  run_on "$MUT/hooks/guard-zsh-glob.sh" "$c"
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then m4_pass=$((m4_pass + 1)); fi
done
if [ "$m4_pass" -eq "${#FIRE_CASES[@]}" ]; then
  ok "M4: 常に 0 件を返すヘルパ（0 件一致）では F 系 ${m4_pass} 件がすべて素通しになり、F の検査が赤になる"
else
  bad "M4: 0 件ヘルパで素通しになったのは ${m4_pass}/${#FIRE_CASES[@]} 件"
fi

unset FF_DEV_TOOLKIT_SKIP_ZSH_EXPANSION_GUARD
echo "guard-zsh-glob: X equals / scalar expansion"
EXP_TARGET="$PLUGIN_ROOT/tests/lib/zsh-expansion-guard.sh"
[ -r "$EXP_TARGET" ] || { echo 'expansion helper missing/not readable' >&2; exit 1; }
assert_warn() {
  if [ "$RC" -eq 0 ] && [ -z "$DECISION" ] && printf '%s' "$OUT" | jq -e '.systemMessage | contains("単語分割")' >/dev/null; then
    ok "$1"
  else bad "$1: expected warning without deny"; fi
}
for c in 'case === in x) :;; esac' 'echo ===' '[ a == b ]' 'true; echo ===' 'true & echo ===' 'echo "ACK=1"; echo ===' 'X=1 echo ===' 'noglob echo ===' 'echo "$(echo ===)"' 'echo `echo ===`' 'echo =ls' $'echo \\\n==='; do
  run_on "$EXP_TARGET" "$c"
  assert_fire "equals deny: $c"
done
for c in 'echo "a << B ==="' 'echo "==="' "echo '==='" 'echo \===' 'X==1' 'export X==1' '[[ a == b ]]' 'case x in ==) echo y;; esac' '# echo ===' 'bash -c "echo ==="' $'cat <<\'EOF\'\necho === $VAR\nEOF'; do
  run_on "$EXP_TARGET" "$c"
  assert_pass "equals/scalar allow: $c"
done
for c in 'P="a b"; git grep x -- $P' 'set -- $r' '$G commit' 'echo ${P}' 'noglob echo $P' 'echo "$(echo $P)"' 'for p in $P; do echo "$p"; done'; do
  run_on "$EXP_TARGET" "$c"
  assert_warn "scalar warning: $c"
done
for c in 'echo "$P"' "echo '\$P'" 'P=$Q' 'export P=$Q' 'echo ${=P}' 'echo "${args[@]}"' '[[ $P == a ]]' '(( n = $P ))'; do
  run_on "$EXP_TARGET" "$c"
  assert_pass "scalar allow: $c"
done
for c in 'echo ===' 'echo $P'; do
  run_on "$EXP_TARGET" "$c" SHELL=/bin/bash
  assert_pass 'bash host'
  run_on "$EXP_TARGET" "$c" CLAUDE_CODE_SHELL=/bin/bash
  assert_pass 'explicit bash overrides zsh'
  run_on "$EXP_TARGET" "$c" FF_DEV_TOOLKIT_SKIP_ZSH_EXPANSION_GUARD=1
  assert_pass 'skip'
  run_on "$EXP_TARGET" "FF_ZSH_EXPANSION_ACK=1 $c"
  assert_pass 'leading ACK'
done
run_on "$EXP_TARGET" 'echo ===' SHELL=/bin/bash CLAUDE_CODE_SHELL=/bin/zsh
assert_fire 'explicit zsh overrides bash'
for c in 'echo FF_ZSH_EXPANSION_ACK=1; echo ===' 'X=1 FF_ZSH_EXPANSION_ACK=1 echo ===' 'true; FF_ZSH_EXPANSION_ACK=1 echo ==='; do
  run_on "$EXP_TARGET" "$c"
  assert_fire 'embedded ACK not effective'
done
run_on "$EXP_TARGET" 'echo ===' FF_ZSH_GLOB_AWK=false
assert_unavailable 'failed scanner denies equals candidate'
run_on "$EXP_TARGET" 'echo $P' FF_ZSH_GLOB_AWK=false
if [ "$RC" -eq 0 ] && [ -z "$DECISION" ] && [ -n "$OUT" ]; then ok 'scanner failure never denies scalar'; else bad 'scalar failure blocked'; fi
for variant in absent no-function empty; do
  xdir="$TEST_TMP/exp-$variant"
  make_tree "$xdir"
  cp "$EXP_TARGET" "$xdir/tests/lib/"
  case "$variant" in
    absent) rm "$xdir/tests/lib/zsh-glob-nomatch.sh" ;;
    no-function) printf ':\n' > "$xdir/tests/lib/zsh-glob-nomatch.sh" ;;
    empty) printf 'ff_zsh_expansion_scan() { return 0; }\n' > "$xdir/tests/lib/zsh-glob-nomatch.sh" ;;
  esac
  run_on "$xdir/tests/lib/zsh-expansion-guard.sh" 'echo ==='
  if [ "$variant" = empty ]; then
    if [ -z "$OUT" ]; then ok 'empty scanner mutant misses positive control (would turn X red)'; else bad 'empty mutation not applied'; fi
  else assert_unavailable "expansion $variant"; fi
done
xdir="$TEST_TMP/exp-mut"
make_tree "$xdir"
cp "$EXP_TARGET" "$xdir/tests/lib/"
sed 's/print "scalar"; return/return/' "$SCAN_LIB" > "$xdir/tests/lib/zsh-glob-nomatch.sh"
run_on "$xdir/tests/lib/zsh-expansion-guard.sh" 'echo $P'
if [ -z "$OUT" ]; then ok 'scalar removal mutant misses warning control'; else bad 'scalar mutant not applied'; fi
if jq -e '[.hooks.PreToolUse[].hooks[].command | contains("/hooks/guard-zsh-glob.sh")] | any' "$HOOKS_JSON" >/dev/null; then ok 'expansion registered in hooks.json'; else bad 'expansion not registered'; fi
if command -v zsh >/dev/null 2>&1; then
  zrc=0
  zout="$(zsh -fc 'echo ===; echo after' 2>&1)" || zrc=$?
  if [ "$zrc" -ne 0 ] && [[ "$zout" == *'not found'* ]] && [[ "$zout" != *after* ]]; then ok 'actual zsh equals aborts remainder'; else bad 'zsh equals behavior'; fi
  zout="$(zsh -fc 'echo "==="; echo after')"
  if [[ "$zout" == *after* ]]; then ok 'quoting fixes equals'; else bad 'equals rewrite'; fi
  zout="$(zsh -fc 'P="a b"; set -- $P; echo $#')"
  bout="$(bash -c 'P="a b"; set -- $P; echo $#')"
  if [ "$zout" = 1 ] && [ "$bout" = 2 ]; then ok 'actual scalar split differs zsh=1/bash=2'; else bad 'scalar splitting behavior'; fi
else
  echo '○ skip: zsh 不在のため equals/scalar の実シェル検証は未実施'
fi

for c in 'echo ===' 'echo $P'; do
  run_on "$TARGET" "$c" FF_DEV_TOOLKIT_SKIP_ZSH_GLOB_GUARD=1
  assert_pass 'global glob skip disables expansion too'
done
xdir="$TEST_TMP/exp-dispatch-missing"
make_tree "$xdir"
rm "$xdir/tests/lib/zsh-expansion-guard.sh"
run_on "$xdir/hooks/guard-zsh-glob.sh" 'echo ==='
assert_unavailable 'registered expansion helper missing denies equals'
run_on "$xdir/hooks/guard-zsh-glob.sh" 'echo $P'
if [ "$RC" -eq 0 ] && [ -z "$DECISION" ] && printf '%s' "$OUT" | jq -se 'length == 1 and (.[0].systemMessage | length > 0)' >/dev/null; then ok 'missing dispatcher emits one warning'; else bad 'missing dispatcher warning'; fi
xdir="$TEST_TMP/exp-asdd-unknown"
make_tree "$xdir"
printf 'asdd_hook_enabled() { return 2; }\n' > "$xdir/hooks/asdd-hook-gate.sh"
for c in 'echo "a << B ==="' '[ "$x" = y ]' "jq '.a = 1'"; do
  run_on "$xdir/hooks/guard-zsh-glob.sh" "$c"
  assert_pass 'ASDD unknown does not deny quoted equals or single ='
done
run_on "$xdir/hooks/guard-zsh-glob.sh" 'echo ==='
assert_unavailable 'ASDD unknown denies actual equals candidate'
printf 'asdd_hook_enabled() { return 3; }\n' > "$xdir/hooks/asdd-hook-gate.sh"
run_on "$xdir/hooks/guard-zsh-glob.sh" 'echo ==='
assert_pass 'ASDD disabled is silent'
run_on "$TARGET" 'echo $P'
assert_warn 'registered entrypoint emits scalar warning'
run_on "$TARGET" 'echo ==='
assert_fire 'registered entrypoint denies equals'
run_on "$TARGET" 'grep $P --include=*.md'
assert_fire 'registered entrypoint merges glob deny and scalar warning'
if printf '%s' "$OUT" | jq -se 'length == 1 and (.[0].systemMessage | contains("単語分割"))' >/dev/null; then ok 'one JSON includes both channels'; else bad 'multiple JSON or warning lost'; fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ guard-zsh-glob: ${FAIL} 件失敗（成功 ${PASS} 件）" >&2
  REACHED_END=1
  exit 1
fi
echo "✅ guard-zsh-glob: all ${PASS} checks passed"
REACHED_END=1
exit 0
