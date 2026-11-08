#!/usr/bin/env bash
# 部分 skip の書式と、捕捉した子の skip 行の中継。
# 空振り検出: 走査対象のディレクトリが無いとき (対象不在) と、読める対象ファイルが 0 件のとき (空振り) が赤になる。列 0 の部分 skip・識別子付きの丸印・成功行に紛れた見送り・中継の無い捕捉・列 0 を親へ写す中継を許す変異は赤になる。
# 空振り検出: OS 別プロファイルが無い・空・不正な行、静的照合の対象が空、理由の固定句が無い場合は赤。Linux と macOS の欄を交換する変異は対照が赤になる。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=../lib/skip-line-contract.sh
. "$SCRIPT_DIR/../lib/skip-line-contract.sh"
# shellcheck source=../lib/relay-skip-lines.sh
. "$SCRIPT_DIR/../lib/relay-skip-lines.sh"

PASS=0
FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

circle="$(printf '\342\227\213')"

if tmp="$(mktemp -d "${TMPDIR:-/tmp}/ff-skip-line.XXXXXX")" && [[ -d "$tmp" && ! -L "$tmp" ]]; then
  WORK="$tmp"
else
  echo "✗ 一時ディレクトリを作成できない" >&2
  exit 1
fi
# 途中死が rc=0 に化けるのを防ぐ末尾到達センチネル（run-all case 12）。
# 素の rm -rf トラップは途中死の exit code を握り潰す。
REACHED_END=0
cleanup() {
  local rc=$?
  rm -rf -- "$WORK"
  if [[ "$REACHED_END" -ne 1 && "$rc" -eq 0 ]]; then
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

# 合成入力ではテンプレートの @C@ を丸印へ置換する。
emit() {
  mkdir -p "$(dirname "$1")"
  sed "s/@C@/${circle}/g" >"$1"
}

expect_hit() {
  local root="$1" needle="$2" label="$3" out rc=0
  out="$(ff_skip_line_scan_tree "$root" 2>&1)" || rc=$?
  if [[ "$rc" -ne 0 && "$out" == *"$needle"* ]]; then
    ok "$label"
  else
    bad "$label (rc=${rc})"
    printf '%s\n' "$out" >&2
  fi
}

expect_clean() {
  local root="$1" label="$2" out rc=0
  out="$(ff_skip_line_scan_tree "$root" 2>&1)" || rc=$?
  if [[ "$rc" -eq 0 && -z "$out" ]]; then
    ok "$label"
  else
    bad "$label (rc=${rc})"
    printf '%s\n' "$out" >&2
  fi
}

expect_hit "/no/such/skip-line-root-$$" ":0: missing" "走査根が無いと赤"

unread="$WORK/unread/plugins/p/tests/a.sh"
emit "$unread" <<'EOF'
true
EOF
if [[ -r "$unread" ]]; then
  chmod 000 "$unread" || true
fi
if [[ -r "$unread" ]]; then
  echo "  ○ skip: root では読めないファイルを作れない"
else
  expect_hit "$WORK/unread" ":0: unreadable" "読めないファイルは赤"
fi
chmod 644 "$unread" 2>/dev/null || true

mkdir -p "$WORK/empty/plugins/p/tests"
printf 'note\n' >"$WORK/empty/plugins/p/tests/readme.txt"
expect_hit "$WORK/empty" ":0: empty" "読める対象ファイルが 0 件の走査は赤"

emit "$WORK/clean/plugins/p/tests/good.sh" <<'EOF'
echo "  @C@ skip: kept"
printf '%s\n' "  @C@ skip: printf"
echo "@C@ skip: whole"
exit 0
cat >"$out" <<'STUB'
echo "@C@ skip: inside stub"
    echo "    @C@ skip: four spaces"
STUB
echo "@C@ skip: redirected" >"$log"
bash child.sh >"$cap"
ff_relay_captured_skips "$cap"
ok "done $(tail -n 1 "$cap")"
echo "@C@ checks skipped: 1"
echo "@C@ skipped: none"
echo "@C@ 案内: next"
echo "@C@ FF_GATE_RECORD=1"
echo "  @C@ info: note"
echo "  @C@ marketplace.json is present"
echo "  @C@ ${name}: status"
ok "later @C@ is not a skip marker"
EOF
emit "$WORK/clean/plugins/p/tests/good.py" <<'EOF'
print('@C@ skip: public manifest')
sys.exit(0)
EOF
expect_clean "$WORK/clean" "正準の部分 skip・suite 全体の skip・heredoc・リダイレクト・中継あり・状態行は赤にしない"

emit "$WORK/col0/plugins/p/tests/bad.sh" <<'EOF'
echo "@C@ skip: continues"
echo still running
EOF
expect_hit "$WORK/col0" "column0-partial" "列 0 の部分 skip は赤"

emit "$WORK/ident-static/plugins/p/tests/bad.sh" <<'EOF'
echo "  @C@ E5: not a skip line"
EOF
expect_hit "$WORK/ident-static" "noncanonical" "識別子の無い非正準の丸印は赤"

emit "$WORK/ident-dyn/plugins/p/tests/bad.sh" <<'EOF'
echo "  @C@ ${id}: jq 不在のため未検証"
EOF
expect_hit "$WORK/ident-dyn" "noncanonical" "動的ラベルの未検証は赤"

emit "$WORK/ident-untested/plugins/p/tests/bad.sh" <<'EOF'
echo "  @C@ ${id}: 未検査"
EOF
expect_hit "$WORK/ident-untested" "noncanonical" "動的ラベルの未検査は赤"

emit "$WORK/ident-absent/plugins/p/tests/bad.sh" <<'EOF'
echo "  @C@ ${id}: 不在のため"
EOF
expect_hit "$WORK/ident-absent" "noncanonical" "動的ラベルの不在のためは赤"

emit "$WORK/ident-word/plugins/p/tests/bad.sh" <<'EOF'
echo "  @C@ ${id}: スキップ"
EOF
expect_hit "$WORK/ident-word" "noncanonical" "動的ラベルのスキップは赤"

emit "$WORK/hide/plugins/p/tests/bad.sh" <<'EOF'
ok "@C@ yq 不在のためスキップ"
EOF
expect_hit "$WORK/hide" "ok-hides-skip" "成功行に紛れた見送りは赤"

emit "$WORK/relay/plugins/p/tests/bad.sh" <<'EOF'
bash child.sh >"$cap"
ok "done $(tail -n 1 "$cap")"
EOF
expect_hit "$WORK/relay" "capture-no-relay" "中継の無い捕捉は赤"

out=""
rc=0
out="$(ff_relay_captured_skips "$WORK/missing-capture" 2>&1)" || rc=$?
if [[ "$rc" -ne 0 && -z "$out" ]]; then
  ok "中継対象のファイルが無いときは失敗する"
else
  bad "中継対象が無いときの戻り値 (rc=${rc})"
fi
emit "$WORK/child.out" <<'EOF'
plain
  @C@ skip: from child
@C@ skip
not a skip
EOF
out="$(ff_relay_captured_skips "$WORK/child.out")"
if [[ "$out" == "  ${circle} skip: from child" ]]; then
  ok "子の字下げした skip 行だけを中継する"
else
  bad "中継した行が想定と違う"
  printf '%s\n' "$out" >&2
fi

emit "$WORK/then-echo/plugins/p/tests/bad.sh" <<'EOF'
if [ ! -r "$f" ]; then echo "  @C@ E5: 読めない"; fi
EOF
expect_hit "$WORK/then-echo" "noncanonical" "then の直後の非正準の丸印は赤"

emit "$WORK/else-echo/plugins/p/tests/bad.sh" <<'EOF'
if true; then true; else echo "  @C@ E5: else"; fi
EOF
expect_hit "$WORK/else-echo" "noncanonical" "else の直後の非正準の丸印は赤"

emit "$WORK/do-echo/plugins/p/tests/bad.sh" <<'EOF'
while false; do echo "  @C@ E5: loop"; done
EOF
expect_hit "$WORK/do-echo" "noncanonical" "do の直後の非正準の丸印は赤"

emit "$WORK/case-echo/plugins/p/tests/bad.sh" <<'EOF'
case "$x" in
msys*) echo "  @C@ E5: case" ;;
esac
EOF
expect_hit "$WORK/case-echo" "noncanonical" "case 腕の echo の非正準の丸印は赤"

emit "$WORK/case-printf/plugins/p/tests/bad.sh" <<'EOF'
case "$x" in
msys*) printf '%s\n' "  @C@ E5: case" ;;
esac
EOF
expect_hit "$WORK/case-printf" "noncanonical" "case 腕の printf の非正準の丸印は赤"

emit "$WORK/redir-or/plugins/p/tests/bad.sh" <<'EOF'
command -v jq >/dev/null 2>&1 || echo "  @C@ E5: x"
EOF
expect_hit "$WORK/redir-or" "noncanonical" "失敗側の echo は前のリダイレクトで見逃さない"

emit "$WORK/redir-keep/plugins/p/tests/good.sh" <<'EOF'
true; echo "@C@ skip: x" >"$log"
exit 0
EOF
expect_clean "$WORK/redir-keep" "セミコロンの後でファイルへ向けた echo は赤にしない"

emit "$WORK/stderr-live/plugins/p/tests/bad.sh" <<'EOF'
echo "@C@ skip: stderr" >&2
echo still
EOF
expect_hit "$WORK/stderr-live" "column0-partial" "標準エラーへ出した列 0 の部分 skip は赤"

emit "$WORK/merged-live/plugins/p/tests/bad.sh" <<'EOF'
echo "@C@ skip: merged" 2>&1
echo still
EOF
expect_hit "$WORK/merged-live" "column0-partial" "標準出力へ合流した列 0 の部分 skip は赤"

emit "$WORK/closer-then-exit/plugins/p/tests/bad.sh" <<'EOF'
if a; then
  echo "@C@ skip: x"
fi
exit 0
EOF
expect_hit "$WORK/closer-then-exit" "column0-partial" "ブロックを閉じた後の exit は列 0 の部分 skip を許さない"

emit "$WORK/oneline-if-exit/plugins/p/tests/bad.sh" <<'EOF'
echo "@C@ skip: x"
if b; then exit 0; fi
echo still
EOF
expect_hit "$WORK/oneline-if-exit" "column0-partial" "後続の一行 if の中の exit は suite の終了ではない"

emit "$WORK/oneline-suite/plugins/p/tests/good.sh" <<'EOF'
if true; then echo "@C@ skip: whole"; exit 0; fi
EOF
expect_clean "$WORK/oneline-suite" "同じ行で終了する suite 全体の skip は赤にしない"

emit "$WORK/printf-dq/plugins/p/tests/bad.sh" <<'EOF'
printf "%s\n" "  @C@ E5: root では未検査"
EOF
expect_hit "$WORK/printf-dq" "noncanonical" "二重引用符の printf 書式の非正準は赤"

emit "$WORK/printf-dq-ok/plugins/p/tests/good.sh" <<'EOF'
printf "%s\n" "  @C@ skip: kept"
EOF
expect_clean "$WORK/printf-dq-ok" "二重引用符の printf 書式の正準は赤にしない"

emit "$WORK/bare-partial/plugins/p/tests/bad.sh" <<'EOF'
echo "  @C@ skip"
EOF
expect_hit "$WORK/bare-partial" "noncanonical" "コロンの無い部分 skip は赤"

emit "$WORK/skip-dollar/plugins/p/tests/bad.sh" <<'EOF'
echo "  @C@ skip$reason"
EOF
expect_hit "$WORK/skip-dollar" "noncanonical" "コロンの前で切れる動的な skip は赤"

emit "$WORK/closed-if/plugins/p/tests/bad.sh" <<'EOF'
if true; then echo "@C@ skip: partial"; fi
echo still
exit 0
EOF
expect_hit "$WORK/closed-if" "column0-partial" "同じ行で閉じた分岐の後の exit は suite 全体の skip ではない"

emit "$WORK/or-exit/plugins/p/tests/bad.sh" <<'EOF'
echo "@C@ skip: x"
[ "$F" -eq 0 ] || exit 1
echo still
EOF
expect_hit "$WORK/or-exit" "column0-partial" "条件付きの exit は suite 全体の skip ではない"

emit "$WORK/or-brace-exit/plugins/p/tests/bad.sh" <<'EOF'
echo "@C@ skip: x"
cd "$d" || { echo failed; exit 1; }
echo still
EOF
expect_hit "$WORK/or-brace-exit" "column0-partial" "条件付きの複文 exit は suite 全体の skip ではない"

emit "$WORK/echo-or-exit/plugins/p/tests/bad.sh" <<'EOF'
echo "@C@ skip: partial" || exit 1
echo still
EOF
expect_hit "$WORK/echo-or-exit" "column0-partial" "echo の失敗側の exit は suite 全体の skip ではない"

emit "$WORK/or-brace-skip/plugins/p/tests/good.sh" <<'EOF'
command -v perl >/dev/null 2>&1 || { echo "@C@ skip: perl"; exit 0; }
echo still
EOF
expect_clean "$WORK/or-brace-skip" "失敗したときだけ出して終了する skip は suite 全体の skip"

emit "$WORK/quoted-heredoc/plugins/p/tests/bad.sh" <<'EOF'
run_hook "$(printf "bash -e <<'EOF'\nnpm test\nEOF")"
echo "@C@ skip: partial"
echo still
EOF
expect_hit "$WORK/quoted-heredoc" "column0-partial" "引用の中の heredoc は後続行を隠さない"

emit "$WORK/cont-string/plugins/p/tests/bad.sh" <<'FIXTURE'
MSG="echo 'open
cat <<EOF
inside
EOF
still"
echo "@C@ skip: partial"
echo still
FIXTURE
expect_hit "$WORK/cont-string" "column0-partial" "続きの文字列の中の heredoc は後続行を隠さない"

emit "$WORK/comment-relay/plugins/p/tests/bad.sh" <<'EOF'
bash child.sh >"$cap"
# ff_relay_captured_skips "$cap"
ok "done $(tail -n 1 "$cap")"
EOF
expect_hit "$WORK/comment-relay" "capture-no-relay" "コメントだけの中継は赤"

emit "$WORK/space-redir/plugins/p/tests/bad.sh" <<'EOF'
bash child.sh > "$cap"
ok "done $(tail -n 1 "$cap")"
EOF
expect_hit "$WORK/space-redir" "capture-no-relay" "空白を挟んだリダイレクトの未中継は赤"

emit "$WORK/tail-1/plugins/p/tests/bad.sh" <<'EOF'
child.sh >"$cap"
echo "result $(tail -1 "$cap")"
EOF
expect_hit "$WORK/tail-1" "capture-no-relay" "tail -1 の未中継は赤"

emit "$WORK/env-bash/plugins/p/tests/bad.sh" <<'EOF'
FOO=1 bash child.sh >"$cap"
ok "done $(tail -n 1 "$cap")"
EOF
expect_hit "$WORK/env-bash" "capture-no-relay" "代入を前置した捕捉の未中継は赤"

emit "$WORK/if-bash/plugins/p/tests/bad.sh" <<'EOF'
if bash child.sh >"$cap" 2>&1; then
  ok "done $(tail -n 1 "$cap")"
fi
EOF
expect_hit "$WORK/if-bash" "capture-no-relay" "if の中の捕捉の未中継は赤"

emit "$WORK/ok-indent/plugins/p/tests/bad.sh" <<'EOF'
ok "  @C@ yq 不在のためスキップ"
EOF
expect_hit "$WORK/ok-indent" "ok-hides-skip" "空白の後に丸印がある成功行は赤"

emit "$WORK/ok-absent/plugins/p/tests/bad.sh" <<'EOF'
ok "（jq 不在のため未検証 — 件数合わせ）"
EOF
expect_hit "$WORK/ok-absent" "ok-hides-skip" "不在のため未検証の成功行は赤"

emit "$WORK/ok-mention/plugins/p/tests/good.sh" <<'EOF'
ok "既存ラベルはスキップされ対象のまま残る"
EOF
expect_clean "$WORK/ok-mention" "振る舞いを述べる成功行は赤にしない"

emit "$WORK/dyn-unrun/plugins/p/tests/bad.sh" <<'EOF'
echo "  @C@ ${id}: 環境のため未実行"
EOF
expect_hit "$WORK/dyn-unrun" "noncanonical" "動的ラベルの未実行は赤"

emit "$WORK/arith/plugins/p/tests/bad.sh" <<'EOF'
x=$((1 << n))
echo "  @C@ E5: after shift"
EOF
expect_hit "$WORK/arith" "noncanonical" "算術シフトの後の非正準は赤"

emit "$WORK/dollar-hash/plugins/p/tests/bad.sh" <<'EOF'
[ $# -eq 0 ] && echo "  @C@ E5: x"
EOF
expect_hit "$WORK/dollar-hash" "noncanonical" '$# と同じ行の非正準は赤'

emit "$WORK/py-bad/plugins/p/tests/bad.py" <<'EOF'
print("  @C@ E5: x")
EOF
expect_hit "$WORK/py-bad" "noncanonical" "Python の非正準 print は赤"

emit "$WORK/mjs-bad/plugins/p/tests/bad.mjs" <<'EOF'
console.log("  @C@ E5: x")
EOF
expect_hit "$WORK/mjs-bad" "noncanonical" "mjs の非正準 console.log は赤"

profile="$SCRIPT_DIR/../lib/release-skip-profile.sh"
if ff_skip_line_scan_tree "$REPO_ROOT" --reasons >"$WORK/reasons" &&
  bash "$profile" --lint "$WORK/reasons"; then
  ok "実ツリーの部分 skip の書式が正しく、理由を正本で分類できる"
else
  cat "$WORK/reasons"
  bad "部分 skip の静的照合が不成立"
fi

emit "$WORK/profile-source/plugins/p/tests/unknown.sh" <<'EOF'
notify_skip() { echo "  @C@ skip: $1"; }
notify_skip "novel unclassified reason"
echo "  @C@ skip: $DYNAMIC_REASON"
command echo "  @C@ skip: novel command reason"
builtin printf '%s\n' "  @C@ skip: novel builtin reason"
EOF
result=""
if ff_skip_line_scan_tree "$WORK/profile-source" --reasons >"$WORK/reasons" &&
  result="$(bash "$profile" --lint "$WORK/reasons")"; then
  bad "未知または動的な理由が静的照合をすり抜けた"
elif [[ "$result" == *'unknown.sh:2: 未分類の部分 skip: novel unclassified reason'* &&
        "$result" == *'unknown.sh:3: 未分類の部分 skip: $DYNAMIC_REASON'* &&
        "$result" == *'unknown.sh:4: 未分類の部分 skip: novel command reason'* &&
        "$result" == *'unknown.sh:5: 未分類の部分 skip: novel builtin reason'* ]]; then
  ok "新規の固定理由と識別句のない動的理由を、発生元付きで停止する"
else
  bad "未知の理由の停止診断が不正: $result"
fi

mkdir -p "$WORK/bin" "$WORK/profile"
emit "$WORK/bin/uname" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$OS_CASE_HOST"
EOF
chmod +x "$WORK/bin/uname"
emit "$WORK/gate-output" <<'EOF'
  @C@ skip: bwrap が無いため sandbox 上の経路判定は未検査
EOF

profile_case() {
  local checker="$1" os="$2" expected="$3" hint="$4" result rc=0
  result="$(PATH="$WORK/bin:$PATH" OS_CASE_HOST="$os" bash "$checker" --check "$WORK/gate-output")" || rc=$?
  [[ "$rc" -eq "$expected" && "$result" == *"$hint"* ]]
}
if profile_case "$profile" Darwin 0 "" && profile_case "$profile" MSYS_NT-10.0 0 "" &&
  profile_case "$profile" Linux 1 'bubblewrap を入れて' &&
  profile_case "$profile" FreeBSD 2 '対応していない OS'; then
  ok "同じ理由を Windows / macOS で許可し、Linux で案内付き停止、未知 OS で停止する"
else
  bad "OS 別の許可・停止が契約と異なる"
fi

cp "$profile" "$WORK/profile/"
mutant="$WORK/profile/release-skip-profile.sh"
table="$WORK/profile/release-skip-profile.tsv"
if profile_case "$mutant" Linux 2 'プロファイルを読めない'; then
  ok "プロファイル不在は停止する"
else
  bad "プロファイル不在を通した"
fi
: >"$table"
if profile_case "$mutant" Linux 2 'プロファイルが空'; then
  ok "空のプロファイルは停止する"
else
  bad "空のプロファイルを通した"
fi
printf 'invalid\tallow\tallow\n' >"$table"
if profile_case "$mutant" Linux 2 'プロファイルの行が不正'; then
  ok "欄が欠けたプロファイルは停止する"
else
  bad "欄が欠けたプロファイルを通した"
fi
awk -F '\t' 'BEGIN {OFS="\t"} /^\^bwrap が無いため/ {t=$3; $3=$4; $4=t} {print}' \
  "$SCRIPT_DIR/../lib/release-skip-profile.tsv" >"$table"
if ! profile_case "$mutant" Linux 1 'bubblewrap を入れて' &&
  ! profile_case "$mutant" Darwin 0 "" &&
  profile_case "$mutant" Darwin 1 'bubblewrap を入れて'; then
  ok "Linux と macOS の欄を交換する変異を正負の対照で検出する"
else
  bad "OS 欄の交換を検出できない"
fi
emit "$WORK/gate-output" <<'EOF'
  @C@ skip: unrelated: bwrap が無いため sandbox 上の経路判定は未検査
EOF
if profile_case "$profile" Darwin 1 '未分類の部分 skip'; then
  ok "理由の途中に置いた OS 限定の許容句で停止を回避できない"
else
  bad "理由の途中に置いた許容句で停止を回避できる"
fi
printf '%s\t%s\n' 'plugins/other/tests/fake.sh:1' 'bwrap が無いため sandbox 上の経路判定は未検査' >"$WORK/reasons"
if result="$(bash "$profile" --lint "$WORK/reasons")"; then
  bad "固定した OS 限定の理由を別の suite から出せる"
elif [[ "$result" == *'固定した発生元と異なる:'* ]]; then
  ok "OS 限定の理由を別の suite から出すと静的照合で停止する"
else
  bad "固定した発生元と異なる理由の診断が不正"
fi
: >"$WORK/reasons"
if result="$(bash "$profile" --lint "$WORK/reasons")"; then
  bad "空の静的照合を通した"
elif [[ "$result" == *'照合入力が空'* ]]; then
  ok "空の静的照合を停止する"
else
  bad "空の静的照合の停止診断が不正"
fi

echo
if [[ "$FAIL" -gt 0 ]]; then
  echo "✗ skip-line-contract verify: ${FAIL} 件失敗 / ${PASS} 件成功" >&2
  exit 1
fi
REACHED_END=1
echo "✓ skip-line-contract verify: 全 ${PASS} 件 pass"
