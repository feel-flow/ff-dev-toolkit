#!/usr/bin/env bash
# 部分 skip の書式と、捕捉した子の skip 行の中継。公開配置の合成実行（public-layout）が suite 全体の skip を許容名簿へ足す判定。
# 空振り検出: 走査対象のディレクトリが無いとき (対象不在) と、読める対象ファイルが 0 件のとき (空振り) が赤になる。列 0 の部分 skip・識別子付きの丸印・成功行に紛れた見送り・中継の無い捕捉・列 0 を親へ写す中継を許す変異は赤になる。
# 空振り検出: OS 別プロファイルが無い・空・不正な行、静的照合の対象が空、理由の固定句が無い場合は赤。Linux と macOS の欄を交換する変異は対照が赤になる。
# 空振り検出: --check の停止で停止文の lib をサブシェルの外でも読ませると、先頭で exit する lib の写しのケースが赤（2026-11-08 macOS / Bash 3.2.57 実測。64/1。Issue `#2712`）。
# 空振り検出: 公開配置の合成実行の suite skip の許容（public-layout/resident-skip-allow.sh）は、判定・public-layout・実物の suite・公開 workflow のいずれかが無い回と、workflow の許容名簿の代入が 0 件か 2 件以上の回を赤にする。写しの木に 1 つずつ当てた変異はすべて赤（2026-11-10 macOS / Bash 3.2.57 実測。無変異は 77 件 pass）: 列 0 の鍵を外す・skip の印を見ない（部分 skip で許容）、単体実行の rc を見ない、前回の値を持ち越す、suite の不在・ログを書けない回を起動へ進める、判定の不在、実物の suite の理由句の改稿、public-layout が値を渡さない・設定時だけ渡す・step の後で判定する、workflow の許容名簿を元へ戻す・既定へ suite を足す・env: やインラインで値を設定する・2 つ目の代入を足す、workflow の不在。
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

# 写しはプラグインの配置（tests/lib と scripts/lib）を保つ。停止文の共通形（scripts/lib/stop-block.sh）を
# 実際の相対パスで読ませるため（Issue `#2712`）。
mkdir -p "$WORK/bin" "$WORK/profile/tests/lib" "$WORK/profile/scripts/lib"
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

# --check の停止は出力の末尾を停止文の共通形の 3 行で終え、表の stop: ヒントを 3 行目の次の一手へ載せる。
# 次の一手は 1 行だけ（行ごとのヒントと二重にしない。Issue `#2712`）
stop_tail_case() { # <checker> <expected 規則行> <expected 次の一手の部分>
  local result rc=0 n
  result="$(PATH="$WORK/bin:$PATH" OS_CASE_HOST=Linux bash "$1" --check "$WORK/gate-output")" || rc=$?
  n="$(printf '%s\n' "$result" | grep -c '次の一手: ' || true)"
  [[ "$rc" -eq 1 && "$n" -eq 1 ]] || return 1
  [[ "$(printf '%s\n' "$result" | tail -n 3 | sed -n 1p)" == '止めた層: 方針' ]] || return 1
  [[ "$(printf '%s\n' "$result" | tail -n 2 | sed -n 1p)" == "$2"* ]] || return 1
  [[ "$(printf '%s\n' "$result" | tail -n 1)" == "次の一手: "*"$3"* ]]
}
if stop_tail_case "$profile" '止めた規則: partial-skip-policy（tests/lib/release-skip-profile.tsv）— ' 'bubblewrap を入れて'; then
  ok "--check の停止は末尾 3 行が停止文の共通形（方針 / partial-skip-policy）で、次の一手 1 行に表のヒントが入る"
else
  bad "--check の停止の末尾 3 行が停止文の共通形でない・次の一手が 1 行でない"
fi

# 表にあるがヒントの無い stop 行（素の stop）と、表に無い行（未分類）は次の一手で別の案内にする。
# 素の stop を「表を確認し検査を書き直す」へ混ぜると、表どおりの停止に表の書き換えを勧めてしまう。
emit "$WORK/gate-output-bare" <<'EOF'
  @C@ skip: 起動回数の上限は Windows と Linux でだけ固定する検査のため未実行
  @C@ skip: bwrap が無いため sandbox 上の経路判定は未検査
EOF
emit "$WORK/gate-output-bare-unknown" <<'EOF'
  @C@ skip: 起動回数の上限は Windows と Linux でだけ固定する検査のため未実行
  @C@ skip: novel builtin reason for the next-step split
EOF
bare_result="$(PATH="$WORK/bin:$PATH" OS_CASE_HOST=Linux bash "$profile" --check "$WORK/gate-output-bare")" && bare_rc=0 || bare_rc=$?
bare_next="$(printf '%s\n' "$bare_result" | tail -n 1)"
if [[ "$bare_rc" -eq 1 && "$(printf '%s\n' "$bare_result" | grep -c '次の一手: ' || true)" -eq 1 &&
  "$bare_next" == '次の一手: '*'bubblewrap を入れて'*'表の stop 行に当たった検査を回せる環境を整えて再実行する'* &&
  "$bare_next" != *'許容表に無い行'* ]]; then
  ok "素の stop 行とヒント付きの行が並ぶと、次の一手 1 行にヒントと「検査を回せる環境を整える」が入り、未分類の案内は出ない"
else
  bad "素の stop 行の次の一手が未分類の案内と分かれていない: rc=$bare_rc out=[$bare_result]"
fi
bare_result="$(PATH="$WORK/bin:$PATH" OS_CASE_HOST=Linux bash "$profile" --check "$WORK/gate-output-bare-unknown")" && bare_rc=0 || bare_rc=$?
bare_next="$(printf '%s\n' "$bare_result" | tail -n 1)"
if [[ "$bare_rc" -eq 1 && "$(printf '%s\n' "$bare_result" | grep -c '次の一手: ' || true)" -eq 1 &&
  "$bare_next" == '次の一手: 表の stop 行に当たった検査を回せる環境を整えて再実行する'*' / 許容表に無い行は表を確認し検査を書き直す（ADR-084 決定 4'* ]]; then
  ok "素の stop 行と未分類の行が並ぶと、次の一手 1 行に 2 つの案内を分けて並べる"
else
  bad "素の stop 行と未分類の行の次の一手が分かれていない: rc=$bare_rc out=[$bare_result]"
fi

cp "$profile" "$WORK/profile/tests/lib/"
cp "$SCRIPT_DIR/../../scripts/lib/stop-block.sh" "$WORK/profile/scripts/lib/"
mutant="$WORK/profile/tests/lib/release-skip-profile.sh"
table="$WORK/profile/tests/lib/release-skip-profile.tsv"
rm -f "$WORK/profile/scripts/lib/stop-block.sh"
cp "$SCRIPT_DIR/../lib/release-skip-profile.tsv" "$table"
if stop_tail_case "$mutant" '止めた規則: stop-block-unavailable（scripts/lib/stop-block.sh）— ' 'bubblewrap を入れて'; then
  ok "停止文の共通形を読めない写しも rc 1 で止まり、stop-block-unavailable の 3 行に表のヒントを残す"
else
  bad "停止文の共通形を読めない写しの停止が契約と異なる（rc 1・stop-block-unavailable・ヒントの保持）"
fi
# 先頭で exit する lib も同じ 3 行で止まる（lib をサブシェルの外で読むと --check ごと rc 0 で終わり、
# 許可されない部分 skip が合格へ化ける。Issue `#2712`）
{ printf '%s\n' 'exit 0'; cat "$SCRIPT_DIR/../../scripts/lib/stop-block.sh"; } >"$WORK/profile/scripts/lib/stop-block.sh"
if stop_tail_case "$mutant" '止めた規則: stop-block-unavailable（scripts/lib/stop-block.sh）— ' 'bubblewrap を入れて'; then
  ok "先頭で exit する停止文の lib でも rc 1 で止まり（rc 0 の素通しにならない）、stop-block-unavailable の 3 行に表のヒントを残す"
else
  bad "先頭で exit する停止文の lib で --check の停止が契約と異なる（rc 1・stop-block-unavailable・ヒントの保持）"
fi
cp "$SCRIPT_DIR/../../scripts/lib/stop-block.sh" "$WORK/profile/scripts/lib/"
rm -f "$table"
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

# ── 公開配置の合成実行での suite skip の許容（tests/public-layout/resident-skip-allow.sh） ──
# public-layout は公開 workflow の step の前に knowledge-lookup-resident-acl を単体で回し、suite 自身が列 0 に
# 出す suite 全体の skip の理由行（常駐 helper の経路を持たない）を見た回だけ、その suite を step の skip
# 許容名簿へ足す。別の理由の skip・字下げした部分 skip・実際に回った回は許容せず、赤い単体実行は止める。
# step 側は FF_PUBLIC_LAYOUT_ALLOWED_SKIP_SUITES が設定されたときだけ名前を足し、公開側の CI は設定しない。
# 19 分の public-layout 全体を回さずに、判定は stub の suite で、step 側は workflow の実物で固定する。
resident_lib="$SCRIPT_DIR/../public-layout/resident-skip-allow.sh"
resident_layout="$SCRIPT_DIR/../public-layout/verify.sh"
resident_real="$SCRIPT_DIR/../knowledge-lookup-resident-acl/verify.sh"
resident_ready=1
for f in "$resident_lib" "$resident_layout" "$resident_real"; do
  if [[ ! -f "$f" ]]; then
    bad "公開配置の suite skip の許容: 検査対象がありません: $f"
    resident_ready=0
  fi
done
if [[ "$resident_ready" -eq 1 ]]; then
  # shellcheck source=../public-layout/resident-skip-allow.sh
  . "$resident_lib"
  if [[ "$ff_public_layout_resident_suite" != knowledge-lookup-resident-acl || -z "$ff_public_layout_resident_reason" ]] ||
    ! declare -F ff_public_layout_resident_skip_allow >/dev/null; then
    bad "公開配置の suite skip の許容: 判定の suite 名・理由句・関数を読めない"
    resident_ready=0
  fi
fi
resident_case() { # <case 名> <期待 rc> <期待する許容名簿の値> <stdout に期待する部分（空なら stdout が空）> [stderr に期待する部分]。stub 本文は stdin
  local name="$1" want_rc="$2" want_allowed="$3" want_out="$4" want_err="${5:-}" root out err rc=0
  root="$WORK/resident/$name/plugins/ff-dev-toolkit"
  if [[ "$name" != missing ]]; then
    emit "$root/tests/${ff_public_layout_resident_suite}/verify.sh"
  else
    mkdir -p "$root/tests"
  fi
  # 前回の値を持ち越さないことも見る
  ff_public_layout_resident_allowed="stale-$name"
  ff_public_layout_resident_skip_allow "$root" "$WORK/resident/$name.log" \
    >"$WORK/resident/$name.out" 2>"$WORK/resident/$name.err" || rc=$?
  out="$(cat "$WORK/resident/$name.out")"
  err="$(cat "$WORK/resident/$name.err")"
  if [[ "$rc" -ne "$want_rc" || "$ff_public_layout_resident_allowed" != "$want_allowed" ]]; then
    printf '    | rc=%s allowed=[%s] out=[%s] err=[%s]\n' "$rc" "$ff_public_layout_resident_allowed" "$out" "$err" >&2
    return 1
  fi
  if [[ -z "$want_out" ]]; then
    [[ -z "$out" ]] || { printf '    | stdout が空でない: [%s]\n' "$out" >&2; return 1; }
  else
    [[ "$out" == *"$want_out"* ]] || { printf '    | stdout に [%s] が無い: [%s]\n' "$want_out" "$out" >&2; return 1; }
  fi
  if [[ "$want_rc" -ne 0 ]]; then
    [[ "$err" == *"${ff_public_layout_resident_suite}"* ]] || { printf '    | 赤の理由が suite を名指さない: [%s]\n' "$err" >&2; return 1; }
  fi
  if [[ -n "$want_err" ]]; then
    [[ "$err" == *"$want_err"* ]] || { printf '    | stderr に [%s] が無い: [%s]\n' "$want_err" "$err" >&2; return 1; }
  fi
  return 0
}
if [[ "$resident_ready" -eq 1 ]]; then
  mkdir -p "$WORK/resident"
  resident_notice="起動 shell が常駐 helper の経路を持たないため ${ff_public_layout_resident_suite} の suite skip を許容した"
  if resident_case reason 0 "$ff_public_layout_resident_suite" "$resident_notice" <<'EOF'
echo "== knowledge-lookup-resident-acl: stub =="
echo "@C@ skip: 起動 shell（PATH の bash 3.2.57(1)-release）に常駐機能が無く常駐 helper の経路を持たないため、W6 / W7 / W16 の suite を実行しません（検査は 1 件も実行されていません）"
exit 0
EOF
  then
    ok "理由行つきの suite skip（rc 0）は許容名簿へ suite 名を足し、許容した旨と suite 名を 1 行出す"
  else
    bad "理由行つきの suite skip を許容しない、または許容した旨・suite 名を出さない"
  fi
  if resident_case other-reason 0 "" "" <<'EOF'
echo "@C@ skip: fixture が見つからないため suite を実行しません（検査は 1 件も実行されていません）"
exit 0
EOF
  then
    ok "別の理由の suite skip は許容しない（許容名簿は空のまま。step の許容名簿の照合で赤になる）"
  else
    bad "別の理由の suite skip を許容した"
  fi
  if resident_case partial 0 "" "" <<'EOF'
echo "  @C@ skip: 常駐 helper の経路を持たないため W6 だけ未実行"
echo "✓ knowledge-lookup-resident-acl verify: 3 件成功"
exit 0
EOF
  then
    ok "理由句を含む字下げした部分 skip の行は鍵にしない（列 0 の suite 全体の skip だけを許容の鍵にする）"
  else
    bad "字下げした部分 skip の行で suite skip を許容した"
  fi
  if resident_case ran 0 "" "" <<'EOF'
echo "  ✓ W6"
echo "✓ knowledge-lookup-resident-acl verify: 4 件成功"
exit 0
EOF
  then
    ok "実際に回った回（skip 行が無い緑）は許容名簿へ何も足さず、何も出さない"
  else
    bad "実際に回った回に許容名簿へ名前を足した、または許容した旨を出した"
  fi
  if resident_case red 1 "" "" <<'EOF'
echo "  ✗ W6: stub red" >&2
exit 1
EOF
  then
    ok "単体実行が赤なら rc 1 で止め、suite を名指す（許容名簿は空）"
  else
    bad "単体実行の赤で止まらない、または suite を名指さない"
  fi
  if resident_case reason-red 1 "" "" <<'EOF'
echo "@C@ skip: 起動 shell に常駐機能が無く常駐 helper の経路を持たないため、W6 / W7 / W16 の suite を実行しません"
exit 1
EOF
  then
    ok "理由行があっても単体実行の rc が 0 でなければ許容せず止める"
  else
    bad "理由行があれば rc 1 の単体実行でも許容した"
  fi
  if resident_case missing 1 "" "" "がありません" </dev/null; then
    ok "合成配置に suite が無ければ起動せずに rc 1 で止め、不在を名指す（許容名簿は空）"
  else
    bad "suite の不在で止まらない"
  fi
  ff_public_layout_resident_allowed="stale-log"
  if ! ff_public_layout_resident_skip_allow "$WORK/resident/reason/plugins/ff-dev-toolkit" "$WORK/resident/no-such-dir/reason.log" \
    >/dev/null 2>"$WORK/resident/no-log.err" &&
    [[ -z "$ff_public_layout_resident_allowed" ]] && grep -q 'ログを書けません' "$WORK/resident/no-log.err"; then
    ok "単体実行のログを書けなければ suite を起動せずに rc 1 で止める（理由行つきの stub でも許容しない）"
  else
    bad "単体実行のログを書けないのに止まらない、または許容した"
  fi

  # 判定の理由句は実物の suite が列 0 の suite 全体の skip で出す文言から取る（suite 側の改稿で鍵が空振りしない）
  if awk -v reason="$ff_public_layout_resident_reason" -v mark="echo \"${circle} skip:" '
      { line = $0; sub(/^[ \t]+/, "", line) }
      index(line, mark) == 1 && index(line, reason) > 0 { hit++ }
      END { exit (hit == 1 ? 0 : 1) }' "$resident_real"; then
    ok "判定の理由句「${ff_public_layout_resident_reason}」は knowledge-lookup-resident-acl の suite 全体の skip の echo 1 箇所に現れる"
  else
    bad "判定の理由句が knowledge-lookup-resident-acl の suite 全体の skip の echo に 1 箇所で現れない（suite 側の文言と判定がずれた）"
  fi

  # public-layout は step の前に判定を呼び、結果を常に step の環境へ渡す（呼び出し元の値を持ち込まない）
  call_line="$(awk 'index($0, "ff_public_layout_resident_skip_allow \"$PWD\"") > 0 && $0 !~ /^[ \t]*#/ { print NR; exit }' "$resident_layout")"
  # 渡す行は env の代入そのもの（行頭）で、step を起動する行まで行継続で続く（条件つきの展開で包まない）
  pass_line="$(awk '{ line = $0; sub(/^[ \t]+/, "", line) } index(line, "FF_PUBLIC_LAYOUT_ALLOWED_SKIP_SUITES=\"$ff_public_layout_resident_allowed\" ") == 1 { print NR; exit }' "$resident_layout")"
  step_line="$(awk 'index($0, "bash -eo pipefail \"$WORK/run-public.sh\"") > 0 && $0 !~ /^[ \t]*#/ { print NR; exit }' "$resident_layout")"
  pass_chain=0
  if [[ -n "$pass_line" && -n "$step_line" && "$pass_line" -lt "$step_line" ]]; then
    pass_chain="$(awk -v from="$pass_line" -v to="$step_line" 'NR >= from && NR < to && $0 !~ /\\$/ { broken = 1 } END { print (broken ? 0 : 1) }' "$resident_layout")"
  fi
  if [[ -n "$call_line" && -n "$pass_line" && -n "$step_line" && "$call_line" -lt "$pass_line" && "$pass_chain" -eq 1 ]]; then
    ok "public-layout は step の前に判定を呼び、その値を FF_PUBLIC_LAYOUT_ALLOWED_SKIP_SUITES として step の環境へ常に渡す"
  else
    bad "public-layout が step の前に判定を呼んでいない、または値を step の環境へ渡していない（call=${call_line:-なし} pass=${pass_line:-なし} step=${step_line:-なし}）"
  fi

  # 公開 workflow の step 側。開発元では oss/ff-dev-toolkit/ 配下、公開 checkout ではリポジトリ直下にある
  workflow=""
  for f in "$REPO_ROOT/oss/ff-dev-toolkit/.github/workflows/weekly-public-run-all.yml" \
    "$REPO_ROOT/.github/workflows/weekly-public-run-all.yml"; do
    if [[ -f "$f" ]]; then workflow="$f"; break; fi
  done
  if [[ -z "$workflow" ]]; then
    bad "公開 workflow（weekly-public-run-all.yml）が開発元・公開 checkout のどちらの配置にも無い"
  else
    allow_lines="$(awk '/^[ \t]*ALLOWED_SKIP_SUITES=/ { n++; line = $0; sub(/^[ \t]+/, "", line) } END { if (n == 1) print line; else print "count=" n + 0 }' "$workflow")"
    stray="$(awk 'index($0, "FF_PUBLIC_LAYOUT_ALLOWED_SKIP_SUITES") > 0 && $0 !~ /^[ \t]*#/ && $0 !~ /^[ \t]*ALLOWED_SKIP_SUITES=/ { print FNR ": " $0 }' "$workflow")"
    if [[ "$allow_lines" == 'ALLOWED_SKIP_SUITES="changelog-public-tags'* && -z "$stray" ]]; then
      ok "公開 workflow の許容名簿の代入は 1 行だけで、FF_PUBLIC_LAYOUT_ALLOWED_SKIP_SUITES を設定する行（env: / export / 別の代入）を持たない"
    else
      bad "公開 workflow の許容名簿の代入が 1 行でない、または workflow 自身が FF_PUBLIC_LAYOUT_ALLOWED_SKIP_SUITES を設定する（allow=[${allow_lines}] stray=[${stray}]）"
    fi
    # 代入の行そのものを実行して、未設定・空・設定済みの許容名簿を測る
    printf '%s\n%s\n' "$allow_lines" 'printf "%s\n" "$ALLOWED_SKIP_SUITES"' >"$WORK/resident/allow-line.sh"
    allow_unset="$(env -u FF_PUBLIC_LAYOUT_ALLOWED_SKIP_SUITES bash -u "$WORK/resident/allow-line.sh" 2>&1)" || allow_unset="rc=$?"
    allow_empty="$(FF_PUBLIC_LAYOUT_ALLOWED_SKIP_SUITES="" bash -u "$WORK/resident/allow-line.sh" 2>&1)" || allow_empty="rc=$?"
    allow_set="$(FF_PUBLIC_LAYOUT_ALLOWED_SKIP_SUITES="$ff_public_layout_resident_suite" bash -u "$WORK/resident/allow-line.sh" 2>&1)" || allow_set="rc=$?"
    if [[ "$allow_unset" == changelog-public-tags && "$allow_empty" == changelog-public-tags &&
      "$allow_set" == "changelog-public-tags ${ff_public_layout_resident_suite}" ]]; then
      ok "公開 workflow の許容名簿は未設定・空なら changelog-public-tags だけ、設定したときだけ suite 名を足す"
    else
      bad "公開 workflow の許容名簿の既定・追加が契約と異なる（未設定=[${allow_unset}] 空=[${allow_empty}] 設定=[${allow_set}]）"
    fi
  fi
fi

echo
if [[ "$FAIL" -gt 0 ]]; then
  echo "✗ skip-line-contract verify: ${FAIL} 件失敗 / ${PASS} 件成功" >&2
  exit 1
fi
REACHED_END=1
echo "✓ skip-line-contract verify: 全 ${PASS} 件 pass"
