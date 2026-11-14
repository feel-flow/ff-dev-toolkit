#!/usr/bin/env bash
# Issue `#2255`: zsh の nomatch glob・equals 展開ガードの入力書き換え（Issue `#2182` と同じ契約）を固定する。
# 陽性: 一意な書き換え案だけの呼び出しは deny せず updatedInput を返し、全 tool_input を保持し、
#       書き換え後が zsh で実際に走る。nomatch と equals が同居しても 1 案にまとまる。
# 陰性: 案の無い語・同じ綴りが判定対象外にもある・heredoc・一覧 scalar・未対応ホスト・
#       集約入口で別ガードが deny / 書き換え競合する形は従来の deny を保つ。
# 空振り検出: 書き換えヘルパ関数（ff_zsh_equals_fix_scan）の不在では書き換えずに deny へ戻ることを R9 が要求し
#   （走査 awk の失敗は try_rewrite より手前の判定不能 deny で止まり、書き換えへ届かないことを同じ R9 が固定する）、案を出さない（常に deny する）hook では陽性の R1〜R3 が赤になる。
# 変異検出: try_rewrite の出現回数照合を外すと R5（単一引用の中の同じ綴り。再走査では見えない）が、ホスト判定を外すと R7 が赤になる（2026-10-25 実測）。
# 変異検出: Issue `#2138` のクエリ形の判定を無効化すると R1q が、直後の `&` の除外を外すと R5 のクエリ形が赤になる（2026-10-26 実測）。
# 変異検出: Issue `#2491` の単語分割の判定（split_on=1）を消した hook は R10 を書き換えず警告だけに戻り、前置の認識（zsh-expansion-guard.sh の ff_zsh_word_split_prefixed）を消すと PostToolUse が前置済みの呼び出しにも scalar を返す。どちらも R15 が suite の中でコピーへ当てて赤を確かめる（2026-11-02 Windows Git Bash 実測）。permission_mode の条件を外すと R16 の default が前置され（R15b）、ACK のときに書き換え全体を諦める旧形へ戻すと R17 の glob の引用が deny へ戻る（R15c。レビュー 1 巡目の対応後に実測）。
# 変異検出: 共有定義が空のときに前置をやめる分岐を外すと、定義ファイルが無いコピーの R10e は「付けました」を禁じる検査で赤になる（rc=1）。同じ分岐を return 1 にすると、その R10e の引用後コマンドが空になり赤になる（rc=1。2026-11-09 実測）。
# 変異検出: CR の除外を外すと R3c が、保留した equals の deny を EXIT trap で出す経路を外すと R5 の equals 系が赤になる（2026-10-25 レビュー対応後に実測）。
# 空振り検出: Issue `#2616` の通知の頻度は、session_id が無い・記録のキーに使えない（`../` `/` 空白）・記録を作れない（置き場がファイル）回を
#   「毎回出す」側に固定する（R20e）。出し済みの判定が常に真になる hook は R1 から赤、判定不能の通知まで絞る hook は R20f が赤になる。
# 変異検出: Issue `#2616` の notice_first を常に「出す」へ / 常に「出し済み」へ、集約入口の採用の一文を無条件に、deny に同居する scalar 警告・
#   PostToolUse の検出・引用の書き換えの通知をそれぞれ絞らない形へ、判定不能の通知も絞る形へ、agent_id の検査を外す・記録のキーから
#   agent_id を外す形へ、集約入口が届かなかった回の記録を消さない・deny でも届いたと数える形へ変えた 10 変異が、どれも R20 で赤になる。
#   無変異の対照は緑（2026-11-04 WSL・zsh あり実測）。
# 変異検出: Issue `#2614` より前の cwd ガード（cd を含まない呼び出しへ systemMessage の警告を出す版）を当てると R19 の 3 つ目が赤になる（2026-11-04 実測）。
# 変異検出: Issue `#2756` の修飾子の置換案を一覧へ入れない hook（mod_fix を空にする）は R21a が、同じ語の 2 回目を
#   飛ばす判定（mod_listed）を消した hook は出現数の照合で書き換えを諦めて R21c が赤になる（2026-11-11 macOS・zsh あり実測）。
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd -P)"
target="${ZSH_REWRITE_TARGET_OVERRIDE:-$root/hooks/guard-zsh-glob.sh}"
batch="$root/hooks/run-bash-hooks.sh"
exit_guard="$root/hooks/guard-exit-code.sh"
tmp="$(mktemp -d /tmp/ff-zsh-rewrite-test.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
unset ff_bash_hooks_revalidated CLAUDECODE CLAUDE_PROJECT_DIR GROK_PLUGIN_ROOT CLAUDE_CODE_SHELL \
  FF_ZSH_GLOB_ACK FF_DEV_TOOLKIT_SKIP FF_ZSH_GLOB_AWK
# FF_DEV_TOOLKIT_SKIP_ で始まる撤去した旧名（`#2735`）も全部落とす（残っていると停止文に注記が足される）。
for _l4_v in "${!FF_DEV_TOOLKIT_SKIP_@}"; do unset "$_l4_v"; done
pass=0
check() { if "$@"; then pass=$((pass+1)); else echo "FAIL zsh rewrite: $*" >&2; exit 1; fi; }
# PM: hook 入力の permission_mode（空なら付けない）。単語分割の前置（Issue `#2491`）は bypassPermissions のときだけ。
PM=""
payload() { jq -nc --arg c "$1" --arg pm "$PM" '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c,timeout:123,description:"fixture"}} + (if $pm != "" then {permission_mode:$pm} else {} end)'; }
# run <command> [env...] — 書き換えに対応した Claude hook 環境の zsh ホストで hook を直接駆動する。
run() { local c="$1"; shift; payload "$c" | env SHELL=/bin/zsh CLAUDECODE=1 CLAUDE_PROJECT_DIR="$tmp" "$@" bash "$target"; }
# Windows の jq.exe は値の中の改行も \r\n で出すので、複数行の書き換えを比べる前に CR を落とす（Issue `#2017`）。
# 書き換えの本体が CR を持たないことは R3c（CR を含む入力は書き換えない）が別に固定している。
rewritten() { jq -r '.hookSpecificOutput.updatedInput.command // empty' <<< "$1" | tr -d '\r'; }
is_rewrite() { jq -e '.hookSpecificOutput.updatedInput != null and .hookSpecificOutput.permissionDecision == null and (.hookSpecificOutput.additionalContext | contains("引用"))' <<< "$1" >/dev/null; }
is_deny() { jq -e '.hookSpecificOutput.permissionDecision == "deny" and .hookSpecificOutput.updatedInput == null' <<< "$1" >/dev/null; }

# R1 nomatch: 書き換え案どおりに引用し、command 以外のフィールドを保持する。
out="$(run 'grep -rn foo --include=*.md .')"
check is_rewrite "$out"
check test "$(rewritten "$out")" = 'grep -rn foo --include="*.md" .'
check test "$(jq -r '.hookSpecificOutput.updatedInput.timeout' <<< "$out")" = 123
check test "$(jq -r '.hookSpecificOutput.updatedInput.description' <<< "$out")" = fixture
# R1q クエリ文字列の形（Issue `#2138`）: 語全体を引用する。単独の brace（gh の {owner}）は残す。
out="$(run 'gh api repos/o/r/contents/a.md?ref=main --jq .content')"
check is_rewrite "$out"
check test "$(rewritten "$out")" = 'gh api "repos/o/r/contents/a.md?ref=main" --jq .content'
out="$(run 'gh api repos/{owner}/{repo}/git/trees/v1?recursive=1')"
check test "$(rewritten "$out")" = 'gh api "repos/{owner}/{repo}/git/trees/v1?recursive=1"'
# 直後が `&&`（単独の `&` ではない）なら語の区切りなので書き換える。
out="$(run 'echo a?x=1&& echo b')"
check test "$(rewritten "$out")" = 'echo "a?x=1"&& echo b'
# R2 equals: = だけの語を引用する。
out="$(run 'echo ====')"
check is_rewrite "$out"
check test "$(rewritten "$out")" = 'echo "===="'
# R3 同居: nomatch 複数と equals が 1 つの updatedInput にまとまる（集約入口の競合扱いにしない）。
out="$(run 'grep -rn foo --include=*.md --include=*.ts --include=*.js --include=*.sh --include=*.json --include=*.yml .; echo ======')"
check is_rewrite "$out"
check test "$(rewritten "$out")" = 'grep -rn foo --include="*.md" --include="*.ts" --include="*.js" --include="*.sh" --include="*.json" --include="*.yml" .; echo "======"'
# R3b 同じ語の複数出現はすべて引用する。未引用 scalar の警告と同居しても出力は 1 つの JSON にまとまる。
out="$(run 'grep -rn foo --include=*.md docs; grep -rn bar --include=*.md tests')"
check test "$(rewritten "$out")" = 'grep -rn foo --include="*.md" docs; grep -rn bar --include="*.md" tests'
out="$(run 'grep -rn foo --include=*.md $X')"
check is_rewrite "$out"
check jq -se 'length == 1 and (.[0].systemMessage | contains("単語分割"))' <<< "$out" >/dev/null
# permission_mode が無い（既定）なら単語分割は前置せず、引用の書き換えだけを返して scalar は警告に残す。
check test "$(rewritten "$out")" = 'grep -rn foo --include="*.md" $X'
# bypassPermissions なら、引用の書き換えと単語分割の前置（Issue `#2491`）が 1 つの updatedInput にまとまる。
out="$(PM=bypassPermissions run 'grep -rn foo --include=*.md $X')"
check test "$(rewritten "$out")" = 'setopt SH_WORD_SPLIT; grep -rn foo --include="*.md" $X'
# R3c 元のコマンドに CR がある回は書き換えない（判定用に CR を落とした文字列を実行入力へ戻さない）。
out="$(run "$(printf 'printf %%s "a\rb"; grep --include=*.md .')")"
check is_deny "$out"
# R4 書き換え後が zsh で実際に走る（zsh が無い環境は skip を明示する。無音の緑にしない）。
if command -v zsh >/dev/null 2>&1; then
  mkdir -p "$tmp/tree"; printf 'foo\n' > "$tmp/tree/a.md"; printf 'foo\n' > "$tmp/tree/b.txt"
  out="$(run "grep -rl foo --include=*.md $tmp/tree; echo ====")"
  zout="$(zsh -fc "$(rewritten "$out")" 2>&1)"
  check test "$zout" = "$(printf '%s\n%s' "$tmp/tree/a.md" '====')"
  # クエリ文字列の形の書き換え（単独の brace を残す）も zsh で実際に走る（Issue `#2138`）。
  out="$(run 'printf "%s\n" repos/{owner}/r?ref=main; echo ====')"
  zout="$(zsh -fc "$(rewritten "$out")" 2>&1)"
  check test "$zout" = "$(printf '%s\n%s' 'repos/{owner}/r?ref=main' '====')"
else
  echo "SKIP R4: zsh が無いため書き換え後の実行を確認できません" >&2
fi
# R5 陰性: 案の無い語・同じ綴りが引用の中にもある・意図的でありうる =cmd・equals の綴りが重なる・heredoc・一覧 scalar・
#   直後に & が続く / 列挙の brace を含むクエリ形。
for cmd in 'grep --include=$X* .' 'echo "--include=*.md" --include=*.md' "echo '--include=*.md' --include=*.md" '=ls -la' '[ a == b ]; echo ====' \
  "$(printf 'cat <<EOF\nx\nEOF\ngrep --include=*.md .')" 'grep --include=*.md . "--include=*.md"' \
  'curl https://example.invalid/a?x=1&y=2' 'echo a?x=1{b,c}' 'echo a?x=1 "a?x=1"'; do
  out="$(run "$cmd")"
  check is_deny "$out"
done
# R6 抜け道は従来どおり無出力で通す。
out="$(run 'FF_ZSH_GLOB_ACK=1 grep --include=*.md .')"
check test -z "$out"
# R7 未対応ホストは従来の deny（CLAUDECODE なし・model あり・grok root あり・bash ホストは無出力）。
out="$(payload 'echo ====' | env SHELL=/bin/zsh CLAUDE_PROJECT_DIR="$tmp" bash "$target")"
check is_deny "$out"
out="$(payload 'grep --include=*.md .' | jq -c '.model="codex"' | env SHELL=/bin/zsh CLAUDECODE=1 CLAUDE_PROJECT_DIR="$tmp" bash "$target")"
check is_deny "$out"
out="$(run 'grep --include=*.md .' GROK_PLUGIN_ROOT="$tmp")"
check is_deny "$out"
out="$(payload 'grep --include=*.md .' | env SHELL=/bin/bash CLAUDECODE=1 CLAUDE_PROJECT_DIR="$tmp" bash "$target")"
check test -z "$out"
# R8 集約入口: 全ガード再検査を通った書き換えを採用し、別ガードの deny / ask と書き換え競合は保持する。
bat() { payload "$1" | env SHELL=/bin/zsh CLAUDECODE=1 CLAUDE_PROJECT_DIR="$tmp" bash "$batch" "${@:2}"; }
out="$(bat 'grep -rn foo --include=*.md .; echo ====' "$exit_guard" "$target")"
check jq -e '.hookSpecificOutput.updatedInput.command == "grep -rn foo --include=\"*.md\" .; echo \"====\"" and .hookSpecificOutput.updatedInput.timeout == 123 and (.hookSpecificOutput.additionalContext | contains("採用しました"))' <<< "$out" >/dev/null
for decision in deny ask; do
  jq -nc --arg d "$decision" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:"other-guard"}}' > "$tmp/verdict.json"
  printf '#!/usr/bin/env bash\ncat >/dev/null\ncat %q\n' "$tmp/verdict.json" > "$tmp/verdict.sh"
  out="$(bat 'echo ====' "$target" "$tmp/verdict.sh")"
  check test "$(jq -r '.hookSpecificOutput.permissionDecision' <<< "$out")" = "$decision"
done
# 再検査で初めて deny するガード（書き換え後の綴りにだけ当たる）。
cat > "$tmp/recheck.sh" <<'SH'
#!/usr/bin/env bash
input="$(cat)"
case "$(jq -r '.tool_input.command' <<< "$input")" in
  *'"===="'*) jq -n '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"rechecked-deny"}}' ;;
esac
SH
out="$(bat 'echo ====' "$target" "$tmp/recheck.sh")"
check jq -e '.hookSpecificOutput.permissionDecision == "deny" and .hookSpecificOutput.updatedInput == null and (.hookSpecificOutput.permissionDecisionReason | contains("rechecked-deny"))' <<< "$out" >/dev/null
# 終了コードガードと別々の書き換え案を出す形は競合として止める。
out="$(bat 'printf ok --include=*.md | tail -1; echo rc=$?' "$exit_guard" "$target")"
check is_deny "$out"
# R9 書き換えヘルパ関数の不在は書き換えず従来の deny へ戻る。走査 awk の失敗は書き換えより手前の判定不能 deny で止まる。
cp -R "$root/hooks" "$tmp/hooks"; mkdir -p "$tmp/tests/lib"; cp "$root/tests/lib/"*.sh "$tmp/tests/lib/"
printf '\nunset -f ff_zsh_equals_fix_scan\n' >> "$tmp/tests/lib/zsh-glob-nomatch.sh"
out="$(payload 'grep --include=*.md .' | env SHELL=/bin/zsh CLAUDECODE=1 CLAUDE_PROJECT_DIR="$tmp" bash "$tmp/hooks/guard-zsh-glob.sh")"
check is_deny "$out"
out="$(run 'grep --include=*.md .' FF_ZSH_GLOB_AWK=false)"
check is_deny "$out"
# ---- R10〜R15: 単語分割の前置（Issue `#2491`）の回避形行列 -------------------------------------------
# 軸（TESTING.md「コマンド文字列ガードの回避形行列」）: 未引用の形（$X / ${X} / for の反復 / set -- / $(…) の中 /
# 先行コマンドの後ろ / 継続行 / heredoc を含む呼び出し）、引用・エスケープ（"$X" / '$X' / \$X の 3 形）、展開されない
# 文脈（case の語・[[ ]]・コメント・heredoc の本文）、免除語（このガードの ACK・別のガードの ACK・既に前置した呼び出し）。
split_of() { printf '%s%s' 'setopt SH_WORD_SPLIT; ' "$1"; }
# R10〜R15 は前置が許される permission_mode（bypassPermissions）で測る。他のモードは R16。
PM=bypassPermissions
is_split() { jq -e '.hookSpecificOutput.updatedInput != null and .hookSpecificOutput.permissionDecision == null and (.hookSpecificOutput.additionalContext | contains("単語分割")) and (.systemMessage | contains("SH_WORD_SPLIT"))' <<< "$1" >/dev/null; }
is_warn_only() { jq -e '.hookSpecificOutput == null and (.systemMessage | contains("単語分割"))' <<< "$1" >/dev/null; }
# R10e 共有定義が読めない・空: 前置せず、引用の書き換えは続け、scalar の警告は残す。
# 通知の出し済みが隣の検査へ漏れないよう、呼び出しごとに空のプロジェクトディレクトリを使う。
r10e="$tmp/r10e"
mkdir -p "$r10e/hooks" "$r10e/tests/lib"
cp -R "$root/hooks/." "$r10e/hooks/"
cp "$root/tests/lib/"*.sh "$r10e/tests/lib/"
run_r10e() { # <project-dir> <command>
  payload "$2" | env SHELL=/bin/zsh CLAUDECODE=1 CLAUDE_PROJECT_DIR="$1" bash "$r10e/hooks/guard-zsh-glob.sh"
}
out="$(run_r10e "$tmp/r10e-a" 'grep -rn foo --include=*.md $X')"
check test "$(rewritten "$out")" = 'setopt SH_WORD_SPLIT; grep -rn foo --include="*.md" $X'
rm -f "$r10e/tests/lib/zsh-word-split-prefix.sh"
out="$(run_r10e "$tmp/r10e-b" 'grep -rn foo --include=*.md $X')"
check test "$(rewritten "$out")" = 'grep -rn foo --include="*.md" $X'
check jq -e '.hookSpecificOutput.updatedInput != null and .hookSpecificOutput.permissionDecision == null and (.systemMessage | contains("単語分割")) and (.systemMessage | contains("付けました") | not)' <<< "$out" >/dev/null
printf '%s\n' "FF_ZSH_WORD_SPLIT_PREFIX=''" > "$r10e/tests/lib/zsh-word-split-prefix.sh"
out="$(run_r10e "$tmp/r10e-c" 'grep -rn foo --include=*.md $X')"
check test "$(rewritten "$out")" = 'grep -rn foo --include="*.md" $X'
check jq -e '.hookSpecificOutput.updatedInput != null and .hookSpecificOutput.permissionDecision == null and (.systemMessage | contains("単語分割")) and (.systemMessage | contains("付けました") | not)' <<< "$out" >/dev/null
rm -f "$r10e/tests/lib/zsh-word-split-prefix.sh"
out="$(run_r10e "$tmp/r10e-d" 'echo ${X}')"
check is_warn_only "$out"
# R10 陽性: 未引用 scalar を含む呼び出しは、元のコマンドの先頭へ setopt SH_WORD_SPLIT; を付けた updatedInput になる。
split_fire=(
  'for t in "a b" "c d"; do set -- $t; echo "$1/$2"; done'
  'set -- $LIST; echo "$#"'
  'f() { echo "$#"; }; f $ARGS'
  'echo ${X}'
  'cd /tmp && ls $DIRS'
  'echo "$(ls $X)"'
  $'ls \\\n  $X'
  "$(printf 'for p in "2900 a 14" "2902 b 14"; do set -- $p\n  cat > "$1.md" <<EOF\n$2\nEOF\ndone')"
  "$(printf 'for t in $LIST; do\n  echo "$t"\ndone')"
)
for cmd in "${split_fire[@]}"; do
  out="$(run "$cmd")"
  check is_split "$out"
  check test "$(rewritten "$out")" = "$(split_of "$cmd")"
  check test "$(jq -r '.hookSpecificOutput.updatedInput.timeout' <<< "$out")" = 123
done
# R10b 一覧値の scalar-list（従来は deny）も前置で解消し、equals の引用と 1 つの書き換えにまとまる。
out="$(run 'A="x y"; echo $A ====')"
check is_split "$out"
check test "$(rewritten "$out")" = 'setopt SH_WORD_SPLIT; A="x y"; echo $A "===="'
# R11 陰性（無出力）: 引用・エスケープした変数、展開されない文脈、既に前置した呼び出し、このガードの ACK。
for cmd in 'echo "$X"' "echo '\$X'" 'echo \$X' 'echo "${X}"' 'case $X in a) echo a ;; esac' '[[ $X == a ]] && echo a' \
  '# ls $X' "$(printf 'cat <<EOF\n$X\nEOF')" 'setopt SH_WORD_SPLIT; set -- $X; echo "$#"' "$(printf 'setopt shwordsplit\nset -- $X')" \
  'FF_ZSH_EXPANSION_ACK=1 set -- $X' 'FF_ZSH_GLOB_ACK=1 set -- $X'; do
  out="$(run "$cmd")"
  check test -z "$out"
done
# R10c 最初の文でない setopt は前置済みと読まない（重ねて前置しても無害なので、前置する側に倒す）。
out="$(run 'echo a; setopt SH_WORD_SPLIT; ls $X')"
check is_split "$out"
# R12 前置しない（従来の警告だけ）: 別のガードの ACK を先頭に持つ（前置すると ACK が先頭の語でなくなる）、
#   入力書き換えに対応しないホスト。equals / scalar の判定ごと止めた回は無出力。
for cmd in 'FF_EXIT_CODE_ACK=1 set -- $X' 'FF_LITERAL_WRITE_ACK=1 echo $X' 'LC_ALL=C FF_TIMEOUT_ACK=1 ls $X'; do
  out="$(run "$cmd")"
  check is_warn_only "$out"
done
out="$(payload 'set -- $X' | env SHELL=/bin/zsh CLAUDE_PROJECT_DIR="$tmp" bash "$target")"
check is_warn_only "$out"
out="$(payload 'set -- $X' | jq -c '.model="codex"' | env SHELL=/bin/zsh CLAUDECODE=1 CLAUDE_PROJECT_DIR="$tmp" bash "$target")"
check is_warn_only "$out"
out="$(run 'set -- $X' FF_DEV_TOOLKIT_SKIP=zsh-expansion)"
check test -z "$out"
# R13 集約入口: 前置した書き換えは全ガードの再検査（さらに書き換えを要求しない）を通って採用され、
#   PostToolUse は前置した呼び出しの scalar を返さない。
out="$(bat 'for t in "a b"; do set -- $t; echo "$1"; done' "$exit_guard" "$target")"
check jq -e --arg c "$(split_of 'for t in "a b"; do set -- $t; echo "$1"; done')" '.hookSpecificOutput.updatedInput.command == $c and .hookSpecificOutput.permissionDecision == null and (.hookSpecificOutput.additionalContext | contains("採用しました"))' <<< "$out" >/dev/null
post() { jq -nc --arg c "$1" '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:$c},tool_response:{}}' | env SHELL=/bin/zsh bash "$target"; }
check test -z "$(post 'setopt SH_WORD_SPLIT; set -- $X')"
out="$(post 'set -- $X')"
check jq -e '.hookSpecificOutput.additionalContext | contains("単語分割")' <<< "$out" >/dev/null
# R14 書き換え後が zsh で bash と同じ分割になる（zsh が無い環境は skip を明示する）。
if command -v zsh >/dev/null 2>&1; then
  cmd='for t in "a b" "c d"; do set -- $t; printf "%s|" "$1"; done'
  out="$(run "$cmd")"
  check test "$(zsh -fc "$(rewritten "$out")" 2>&1)" = 'a|c|'
  check test "$(zsh -fc "$cmd" 2>&1)" = 'a b|c d|'
  check test "$(bash -c "$cmd" 2>&1)" = 'a|c|'
else
  echo "SKIP R14: zsh が無いため前置後の分割を実処理系で確認できません" >&2
fi
# R15 変異: 単語分割の判定（split_on=1）を消した hook は R10 を書き換えず警告だけに戻り、前置の認識を消した
#   zsh-expansion-guard.sh は PostToolUse で前置済みの呼び出しにも scalar を返す（どちらも R10 / R13 の検査が赤になる）。
mut="$tmp/mut2491"
mkdir -p "$mut"
cp -R "$root/hooks" "$mut/hooks"; mkdir -p "$mut/tests/lib"; cp "$root/tests/lib/"*.sh "$mut/tests/lib/"
sed 's/case "$exp_hits" in \*scalar\*) split_on=1 ;; esac/: no split/' "$root/hooks/guard-zsh-glob.sh" > "$mut/hooks/guard-zsh-glob.sh"
check test "$(cmp -s "$root/hooks/guard-zsh-glob.sh" "$mut/hooks/guard-zsh-glob.sh" && echo same || echo mutated)" = mutated
out="$(payload "${split_fire[0]}" | env SHELL=/bin/zsh CLAUDECODE=1 CLAUDE_PROJECT_DIR="$tmp" bash "$mut/hooks/guard-zsh-glob.sh")"
check is_warn_only "$out"
cp "$root/hooks/guard-zsh-glob.sh" "$mut/hooks/guard-zsh-glob.sh"
sed 's/ \&\& ff_zsh_word_split_prefixed "$cmd"; then$/ \&\& false; then/' "$root/tests/lib/zsh-expansion-guard.sh" > "$mut/tests/lib/zsh-expansion-guard.sh"
check test "$(cmp -s "$root/tests/lib/zsh-expansion-guard.sh" "$mut/tests/lib/zsh-expansion-guard.sh" && echo same || echo mutated)" = mutated
out="$(jq -nc '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:"setopt SH_WORD_SPLIT; set -- $X"},tool_response:{}}' | env SHELL=/bin/zsh bash "$mut/hooks/guard-zsh-glob.sh")"
check jq -e '.hookSpecificOutput.additionalContext | contains("単語分割")' <<< "$out" >/dev/null
cp "$root/tests/lib/zsh-expansion-guard.sh" "$mut/tests/lib/zsh-expansion-guard.sh"
# R15b 変異: permission_mode の条件を外した hook は R16 の default を前置してしまう（R16 が赤になる）。
sed 's/elif \[ "$permission_mode" != bypassPermissions \]; then/elif false; then/' "$root/hooks/guard-zsh-glob.sh" > "$mut/hooks/guard-zsh-glob.sh"
check test "$(cmp -s "$root/hooks/guard-zsh-glob.sh" "$mut/hooks/guard-zsh-glob.sh" && echo same || echo mutated)" = mutated
out="$(PM=default payload 'set -- $X' | env SHELL=/bin/zsh CLAUDECODE=1 CLAUDE_PROJECT_DIR="$tmp" bash "$mut/hooks/guard-zsh-glob.sh")"
check is_split "$out"
# R15c 変異: ACK のときに書き換え全体を諦める旧形（return 1）へ戻すと、R17 の glob の引用まで deny へ戻る。
sed 's/case "$cmd" in \*FF_\*_ACK=\*) split_on=0 ;; esac/case "$cmd" in *FF_*_ACK=*) return 1 ;; esac/' "$root/hooks/guard-zsh-glob.sh" > "$mut/hooks/guard-zsh-glob.sh"
check test "$(cmp -s "$root/hooks/guard-zsh-glob.sh" "$mut/hooks/guard-zsh-glob.sh" && echo same || echo mutated)" = mutated
out="$(PM=bypassPermissions payload 'FF_EXIT_CODE_ACK=1 grep -r --include=*.md foo $DIR' | env SHELL=/bin/zsh CLAUDECODE=1 CLAUDE_PROJECT_DIR="$tmp" bash "$mut/hooks/guard-zsh-glob.sh")"
check is_deny "$out"

# ---- R16: permission_mode の行列（Critical: 前置は権限判定を変えるので bypassPermissions だけ） -------------
# bypassPermissions 以外（default / plan / acceptEdits / auto / dontAsk / 欠落 / 文字列でない値）は前置せず、
# 修正前と同じ警告（scalar）/ deny（一覧 scalar）に戻す（fail-safe）。大文字小文字違いも一致と読まない。
for pm in default plan acceptEdits auto dontAsk "" bypasspermissions; do
  out="$(PM="$pm" run 'set -- $X')"
  check is_warn_only "$out"
  out="$(PM="$pm" run 'A="x y"; echo $A ====')"
  check is_deny "$out"
done
out="$(payload 'set -- $X' | jq -c '.permission_mode = 1' | env SHELL=/bin/zsh CLAUDECODE=1 CLAUDE_PROJECT_DIR="$tmp" bash "$target")"
check is_warn_only "$out"
out="$(PM=bypassPermissions run 'set -- $X')"
check is_split "$out"
# 前置しないモードでも glob / equals の引用の書き換えは続ける（scalar は前置せずに残す）。
out="$(PM=dontAsk run 'grep -rn foo --include=*.md $X; echo ====')"
check test "$(rewritten "$out")" = 'grep -rn foo --include="*.md" $X; echo "===="'
check jq -e '.hookSpecificOutput.additionalContext | contains("SH_WORD_SPLIT") | not' <<< "$out" >/dev/null
# 集約入口の再投入は permission_mode を落とさない（再検査でも前置済みと読み、さらに書き換えを求めない）。
out="$(PM=bypassPermissions bat 'set -- $X; echo "$#"' "$exit_guard" "$target")"
check jq -e '.hookSpecificOutput.updatedInput.command == "setopt SH_WORD_SPLIT; set -- $X; echo \"$#\"" and (.hookSpecificOutput.additionalContext | contains("採用しました"))' <<< "$out" >/dev/null
out="$(PM=default bat 'set -- $X; echo "$#"' "$exit_guard" "$target")"
check jq -e '.hookSpecificOutput.updatedInput == null and (.systemMessage | contains("単語分割"))' <<< "$out" >/dev/null

# ---- R17: 別のガードの ACK は前置だけを止め、glob / equals の書き換えは続ける ---------------------------------
out="$(PM=bypassPermissions run 'FF_EXIT_CODE_ACK=1 grep -r --include=*.md foo $DIR')"
check test "$(rewritten "$out")" = 'FF_EXIT_CODE_ACK=1 grep -r --include="*.md" foo $DIR'
check jq -e '.hookSpecificOutput.permissionDecision == null and (.systemMessage | contains("単語分割"))' <<< "$out" >/dev/null

# ---- R18: 前置済みの判定（setopt +o / 後ろの unsetopt / no_ の形は有効化と読まない） --------------------------
for cmd in 'setopt +o shwordsplit; set -- $X' 'setopt SH_WORD_SPLIT; unsetopt SH_WORD_SPLIT; set -- $X' \
  'setopt SH_WORD_SPLIT; setopt no_sh_word_split; set -- $X' 'setopt sh_word_split; setopt +o sh_word_split; set -- $X'; do
  out="$(PM=default run "$cmd")"
  check is_warn_only "$out"
done
# 有効化と読めない呼び出しが、この hook の前置した文で始まっていても重ねて前置しない（再検査の無限書き換えを防ぐ）。
out="$(PM=bypassPermissions run 'setopt SH_WORD_SPLIT; unsetopt SH_WORD_SPLIT; set -- $X')"
check is_warn_only "$out"
check test -z "$(PM=default run 'setopt shwordsplit; set -- $X')"
# 無効化の照合は先頭の語が setopt / unsetopt / set の文だけ。引数としてデータに書いた綴りでは前置済みの判定を外さない
# （外すと実際は分割される呼び出しへ事実と違う警告が出る。レビュー 2 巡目）。制御語の後ろの無効化は読む。
for cmd in 'setopt SH_WORD_SPLIT; grep -n unsetopt docs $X' 'setopt SH_WORD_SPLIT; echo no_sh_word_split $X' \
  'setopt SH_WORD_SPLIT; grep -e +o -e shwordsplit $X'; do
  check test -z "$(PM=bypassPermissions run "$cmd")"
done
out="$(PM=default run 'setopt SH_WORD_SPLIT; if true; then unsetopt sh_word_split; fi; set -- $X')"
check is_warn_only "$out"

# ---- R19: 前置後の呼び出しを cwd ガードが誤って止めず、相対 cd は止め続ける（集約入口経由） ---------------------
# cwd ガードが働くのは linked worktree のある repo だけなので、fixture に 1 本足す。ガードの opt-out は
# 利用者の環境（~/.claude/settings.json の env 等）に入っていることがあるので、呼び出しごとに外す。
# git が無い環境だけを skip にする。git があるのに fixture を作れないのは実装かテストの異常なので、
# R19 の 3 検査が消えたまま緑にならないよう失敗にする。
bg_guard="$root/hooks/guard-background-cwd.sh"
wtrepo="$tmp/wtrepo"
mkdir -p "$wtrepo/packages/app"
if ! command -v git >/dev/null 2>&1; then
  echo "SKIP R19: git が無いため cwd ガードとの組み合わせは未検査" >&2
elif ! { git -c init.defaultBranch=main -C "$wtrepo" init --quiet >/dev/null 2>&1 \
  && git -C "$wtrepo" -c user.email=guard@example.invalid -c user.name=guard commit --quiet --allow-empty -m init >/dev/null 2>&1 \
  && git -C "$wtrepo" worktree add --quiet -b r19-linked "$tmp/wtrepo-linked" >/dev/null 2>&1; }; then
  echo "FAIL zsh rewrite: R19 の linked worktree の fixture を作れません（git はあるのに init / commit / worktree add が失敗）" >&2
  exit 1
else
  bgpay() { jq -nc --arg c "$1" --arg d "$wtrepo" '{hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$d,permission_mode:"bypassPermissions",tool_input:{command:$c,run_in_background:true,timeout:123,description:"fixture"}}'; }
  bgrun() { bgpay "$1" | env -u FF_DEV_TOOLKIT_SKIP SHELL=/bin/zsh CLAUDECODE=1 CLAUDE_PROJECT_DIR="$tmp" bash "$batch" "$target" "$bg_guard"; }
  no_cwd_text='[(.systemMessage // ""), (.hookSpecificOutput.additionalContext // ""), (.hookSpecificOutput.permissionDecisionReason // "")] | all(contains("Bash の cwd") | not)'
  # 前置された絶対パスの cd は止めず、cwd ガードはどのチャネルにも何も足さない。
  out="$(bgrun "cd $wtrepo/packages/app && ls \$X")"
  check jq -e --arg c "setopt SH_WORD_SPLIT; cd $wtrepo/packages/app && ls \$X" ".hookSpecificOutput.updatedInput.command == \$c and .hookSpecificOutput.permissionDecision == null and ($no_cwd_text)" <<< "$out" >/dev/null
  # 対照: 相対 cd は集約入口でも cwd ガードの deny が残り、書き換えは採用されない（元の入力が
  # deny なので再検査へ進まない）。前置後の形（setopt SH_WORD_SPLIT; cd 相対）を cwd ガードが
  # 読み飛ばして止めることは guard-background-cwd/verify.sh の S1 / S2 / S8 が固定する。
  out="$(bgrun 'cd packages/app && ls $X')"
  check jq -e '.hookSpecificOutput.permissionDecision == "deny" and .hookSpecificOutput.updatedInput == null and (.hookSpecificOutput.permissionDecisionReason | contains("Bash の cwd・拒否"))' <<< "$out" >/dev/null
  # cd を含まない呼び出しには、止めない警告もどのチャネルにも出さない（Issue `#2614`）。
  out="$(bgrun 'npm test $X')"
  check jq -e "($no_cwd_text)" <<< "$out" >/dev/null
fi

# ---- R20: 止めない通知は種類ごとに同じセッションで 1 回だけ（Issue `#2616`） -------------------------------
# 同じ session_id の 2 回目は、利用者の画面へ出る通知（systemMessage・additionalContext）を出さず、deny と
# updatedInput は 1 回目と同じ。session_id が違う・無い・記録を作れない回と、判定不能の通知は毎回出す。
# PreToolUse は集約入口（採用の一文を足す側）を通し、PostToolUse は登録どおり hook を直接駆動する。
nstate="$tmp/notice-state"
spay() { # <command> <session_id（空なら付けない）> <hook_event_name>
  jq -nc --arg c "$1" --arg s "$2" --arg e "$3" --arg pm "$PM" \
    '{hook_event_name:$e,tool_name:"Bash",tool_input:{command:$c,timeout:123,description:"fixture"}} + (if $s != "" then {session_id:$s} else {} end) + (if $pm != "" then {permission_mode:$pm} else {} end)'
}
srun() { # <command> <session_id> [PostToolUse] — 出力が無い回は {} を返す
  local o
  if [ "${3:-}" = PostToolUse ]; then
    o="$(spay "$1" "$2" PostToolUse | env SHELL=/bin/zsh CLAUDECODE=1 CLAUDE_PROJECT_DIR="$tmp" FF_DEV_TOOLKIT_STATE_DIR="${NSTATE:-$nstate}" bash "$target")"
  else
    o="$(spay "$1" "$2" PreToolUse | env SHELL=/bin/zsh CLAUDECODE=1 CLAUDE_PROJECT_DIR="$tmp" FF_DEV_TOOLKIT_STATE_DIR="${NSTATE:-$nstate}" bash "$batch" "$target")"
  fi
  printf '%s\n' "${o:-"{}"}"
}
silent='(has("systemMessage") | not) and (.hookSpecificOutput.additionalContext == null)'
# R14 以降は PM=bypassPermissions のままなので、前置しないモードの検査のために戻す（前置の検査は呼び出しごとに付ける）。
PM=""
# R20a bypassPermissions の単語分割: 1 回目は通知と採用の一文、2 回目は同じ updatedInput だけ。
out1="$(PM=bypassPermissions srun 'ls $X' r20-a)"
out2="$(PM=bypassPermissions srun 'ls $X' r20-a)"
check jq -e '(.systemMessage | contains("SH_WORD_SPLIT")) and (.hookSpecificOutput.additionalContext | contains("採用しました"))' <<< "$out1" >/dev/null
check jq -e "$silent and .hookSpecificOutput.permissionDecision == null" <<< "$out2" >/dev/null
check test "$(rewritten "$out2")" = 'setopt SH_WORD_SPLIT; ls $X'
check test "$(rewritten "$out2")" = "$(rewritten "$out1")"
# R20b 引用の書き換えは単語分割と別の種類: 単語分割を出し済みのセッションでも、初めての引用の通知は出す。
#   引用の通知も出し済みになった後は、別の語の書き換えでも通知を出さず、引用した updatedInput は返す。
out1="$(PM=bypassPermissions srun 'grep -rn foo --include=*.md $X' r20-a)"
check jq -e '(.hookSpecificOutput.additionalContext | contains("引用") and (contains("SH_WORD_SPLIT") | not)) and (has("systemMessage") | not)' <<< "$out1" >/dev/null
check test "$(rewritten "$out1")" = 'setopt SH_WORD_SPLIT; grep -rn foo --include="*.md" $X'
out2="$(PM=bypassPermissions srun 'grep -rn bar --include=*.ts .' r20-a)"
check jq -e "$silent" <<< "$out2" >/dev/null
check test "$(rewritten "$out2")" = 'grep -rn bar --include="*.ts" .'
# R20c 前置しないモードの未引用 scalar: 画面向け（PreToolUse の systemMessage）とエージェント向け
#   （PostToolUse の additionalContext）は別の種類で、それぞれ 1 回だけ出す。
out1="$(srun 'ls $X' r20-c)"
out2="$(srun 'ls $X' r20-c)"
check jq -e '.systemMessage | contains("単語分割されません")' <<< "$out1" >/dev/null
check jq -e "$silent" <<< "$out2" >/dev/null
out1="$(srun 'ls $X' r20-c PostToolUse)"
out2="$(srun 'ls $X' r20-c PostToolUse)"
check jq -e '.hookSpecificOutput.hookEventName == "PostToolUse" and (.hookSpecificOutput.additionalContext | contains("単語分割"))' <<< "$out1" >/dev/null
check jq -e "$silent" <<< "$out2" >/dev/null
# R20d 書き換えられない deny は 2 回目も同じ判定と理由。集約入口は deny で返した回の通知を出し済みに数えないので、
#   同居する scalar 警告も 2 回目に出る。集約入口を通さない単独起動（記録を取り消す側がいない）では 2 回目に落ちる。
out1="$(srun 'grep --include=$X* . $Y' r20-d)"
out2="$(srun 'grep --include=$X* . $Y' r20-d)"
check is_deny "$out1"
check is_deny "$out2"
check test "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "$out2")" = "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "$out1")"
check jq -e 'has("systemMessage")' <<< "$out1" >/dev/null
check jq -e 'has("systemMessage")' <<< "$out2" >/dev/null
check test ! -e "$nstate/notices/r20-d/main/zsh-scalar-screen"
for i in 1 2; do
  out="$(spay 'grep --include=$X* . $Y' r20-d2 PreToolUse | env SHELL=/bin/zsh CLAUDECODE=1 CLAUDE_PROJECT_DIR="$tmp" FF_DEV_TOOLKIT_STATE_DIR="$nstate" bash "$target")"
  check is_deny "$out"
  if [ "$i" -eq 1 ]; then check jq -e 'has("systemMessage")' <<< "$out" >/dev/null; else check jq -e 'has("systemMessage") | not' <<< "$out" >/dev/null; fi
done
# R20e 別のセッションは改めて出す。session_id が無い回・記録を作れない回は毎回出す（黙らせる側へ倒さない）。
out1="$(srun 'ls $X' r20-e)"
check jq -e '.systemMessage | contains("単語分割されません")' <<< "$out1" >/dev/null
for i in 1 2; do
  out="$(srun 'ls $X' '')"
  check jq -e '.systemMessage | contains("単語分割されません")' <<< "$out" >/dev/null
done
: > "$tmp/notice-not-a-dir"
for i in 1 2; do
  out="$(NSTATE="$tmp/notice-not-a-dir" srun 'ls $X' r20-f)"
  check jq -e '.systemMessage | contains("単語分割されません")' <<< "$out" >/dev/null
done
for sid in '../r20' 'a/b' 'a b'; do
  out="$(srun 'ls $X' "$sid")"
  check jq -e '.systemMessage | contains("単語分割されません")' <<< "$out" >/dev/null
done
check test ! -e "$nstate/r20"
# R20f 判定不能の通知は出し済みのセッションでも毎回出す（走査 awk の失敗。PreToolUse・PostToolUse とも）。
for i in 1 2; do
  out="$(spay 'ls $X' r20-c PreToolUse | env SHELL=/bin/zsh CLAUDECODE=1 CLAUDE_PROJECT_DIR="$tmp" FF_DEV_TOOLKIT_STATE_DIR="$nstate" FF_ZSH_GLOB_AWK=false bash "$target")"
  check jq -e '.systemMessage | startswith("zsh 展開ガード:")' <<< "$out" >/dev/null
  out="$(spay 'ls $X' r20-c PostToolUse | env SHELL=/bin/zsh CLAUDECODE=1 CLAUDE_PROJECT_DIR="$tmp" FF_DEV_TOOLKIT_STATE_DIR="$nstate" FF_ZSH_GLOB_AWK=false bash "$target")"
  check jq -e '.hookSpecificOutput.additionalContext | startswith("zsh 展開ガード:")' <<< "$out" >/dev/null
done
# R20g 集約入口が通知を deny で返した回（別のガードの deny）は出し済みに数えず、次の呼び出しで改めて出す。
out1="$(spay 'bash tests/run-all.sh $ARGS 2>&1 | tail -20' r20-g PreToolUse | jq -c '.permission_mode = "bypassPermissions"' \
  | env SHELL=/bin/zsh CLAUDECODE=1 CLAUDE_PROJECT_DIR="$tmp" FF_DEV_TOOLKIT_STATE_DIR="$nstate" bash "$batch" "$target" "$exit_guard")"
check jq -e '.hookSpecificOutput.permissionDecision == "deny" and .hookSpecificOutput.updatedInput == null' <<< "$out1" >/dev/null
check test ! -e "$nstate/notices/r20-g/main/zsh-word-split"
out2="$(PM=bypassPermissions srun 'ls $X' r20-g)"
check jq -e '(.systemMessage | contains("SH_WORD_SPLIT")) and .hookSpecificOutput.updatedInput.command == "setopt SH_WORD_SPLIT; ls $X"' <<< "$out2" >/dev/null
check test -d "$nstate/notices/r20-g/main/zsh-word-split"
# R20h サブエージェント（hook 入力の agent_id）は親と別に数える。agent_id を記録のキーに使えない回は毎回出す。
apay() { spay "$1" "$2" "$3" | jq -c --arg a "$4" '.agent_id = $a'; }
for i in 1 2; do
  out="$(apay 'ls $X' r20-c PreToolUse sub-1 | env SHELL=/bin/zsh CLAUDECODE=1 CLAUDE_PROJECT_DIR="$tmp" FF_DEV_TOOLKIT_STATE_DIR="$nstate" bash "$batch" "$target")"
  [ -n "$out" ] || out='{}'
  if [ "$i" -eq 1 ]; then
    check jq -e '.systemMessage | contains("単語分割されません")' <<< "$out" >/dev/null
  else
    check jq -e "$silent" <<< "$out" >/dev/null
  fi
  out="$(apay 'ls $X' r20-c PostToolUse sub-1 | env SHELL=/bin/zsh CLAUDECODE=1 CLAUDE_PROJECT_DIR="$tmp" FF_DEV_TOOLKIT_STATE_DIR="$nstate" bash "$target")"
  [ -n "$out" ] || out='{}'
  if [ "$i" -eq 1 ]; then
    check jq -e '.hookSpecificOutput.additionalContext | contains("単語分割")' <<< "$out" >/dev/null
  else
    check jq -e "$silent" <<< "$out" >/dev/null
  fi
  out="$(apay 'ls $X' r20-c PreToolUse '../x' | env SHELL=/bin/zsh CLAUDECODE=1 CLAUDE_PROJECT_DIR="$tmp" FF_DEV_TOOLKIT_STATE_DIR="$nstate" bash "$batch" "$target")"
  check jq -e '.systemMessage | contains("単語分割されません")' <<< "$out" >/dev/null
done
check test ! -e "$nstate/notices/x"
# 集約入口の再検査は同じガードをもう 1 度走らせる。通した回の注記は、元の出力と再検査の出力の両方に出るので、
# 採用した書き換えの additionalContext には 1 回だけ残す。注記は、通すたびに同じ 1 行を出す stub の hook で作る
dup_note="dupnote: 通した回の注記"
jq -nc --arg m "$dup_note" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$m}}' > "$tmp/passnote.json"
printf '#!/usr/bin/env bash\ncat >/dev/null\ncat %q\n' "$tmp/passnote.json" > "$tmp/passnote.sh"
out="$(bat 'grep -rn foo --include=*.sh .' "$target" "$tmp/passnote.sh")"
check jq -e --arg n "$dup_note" '.hookSpecificOutput.updatedInput != null and ([.hookSpecificOutput.additionalContext | splits("\n") | select(contains($n))] | length) == 1' <<< "$out" >/dev/null
# ---- R21: 履歴修飾子（Issue `#2756`）: `$name:X` を `${name}:X` へ書き換える -----------------------------------
PM=""
has_upd() { jq -e '.hookSpecificOutput.updatedInput != null' <<< "$1" >/dev/null 2>&1; }
# R21a 陽性（二重引用の中）: refspec の `$db:r` だけを波括弧で閉じ、修飾子の通知を付ける。
out="$(run 'git fetch origin "+refs/heads/$db:refs/remotes/origin/$db"')"
check has_upd "$out"
check test "$(rewritten "$out")" = 'git fetch origin "+refs/heads/${db}:refs/remotes/origin/$db"'
check jq -e '.hookSpecificOutput.permissionDecision == null and (.hookSpecificOutput.additionalContext | contains("修飾子"))' <<< "$out" >/dev/null
# R21b 陽性（未引用）: 未引用 scalar の警告と同居しても 1 つの JSON にまとまる（permission_mode なしは前置しない）。
out="$(run 'cp $src:h/x .')"
check test "$(rewritten "$out")" = 'cp ${src}:h/x .'
check jq -se 'length == 1' <<< "$out" >/dev/null
# R21c 同じ語の複数出現と、コマンド置換・バッククォートの中もすべて書き換える。
out="$(run 'echo "$a:r" "$a:r" $(basename "$f:t") `echo $g:e`')"
check test "$(rewritten "$out")" = 'echo "${a}:r" "${a}:r" $(basename "${f}:t") `echo ${g}:e`'
# R21d glob の引用と同居しても 1 つの updatedInput にまとまり、両方の通知が付く。
out="$(run 'grep -rn "$q:t" --include=*.md .')"
check test "$(rewritten "$out")" = 'grep -rn "${q}:t" --include="*.md" .'
check jq -e '(.hookSpecificOutput.additionalContext | contains("引用")) and (.hookSpecificOutput.additionalContext | contains("修飾子"))' <<< "$out" >/dev/null
# R21e 陰性（書き換えない）: 利用者が明示した波括弧の形、修飾子でない `:` の後ろ、単一引用・`\$` の中、
#   同じ綴りが単一引用の中にもある（出現数が合わない）、heredoc を含む、zsh-expansion の ACK / 無効化。
for c in 'echo "${db}:r" "${db:r}"' 'echo "$host:8080" "$x:-y" "$x:/a"' "echo '\$db:r'" 'echo "\$db:r"' \
  "echo \"\$db:r\" '\$db:r'" 'cat <<EOF
$db:r
EOF
echo "$db:r"' 'FF_ZSH_EXPANSION_ACK=1 echo "$db:r"'; do
  out="$(run "$c")"
  check test -z "$(rewritten "$out")"
done
out="$(run 'echo "$db:r"' FF_DEV_TOOLKIT_SKIP=zsh-expansion)"
check test -z "$out"
# R21e2 陰性を陽性の語と同居させ、前置フィルタではなく awk の判定（修飾子の文字・波括弧・特殊パラメータの直後）で
#   書き換えないことを固定する。`"$$a:r"` は PID の後ろにリテラルが続く形で、書き換えると値が変わる（レビュー指摘）。
out="$(run 'echo "$db:r" "$x:-y" "$x:=y" "$x:/a" "${db:r}" "${db}:r" "$$a:r" "x$$tmp:t" "$host:8080" "$a:&"')"
check test "$(rewritten "$out")" = 'echo "${db}:r" "$x:-y" "$x:=y" "$x:/a" "${db:r}" "${db}:r" "$$a:r" "x$$tmp:t" "$host:8080" "$a:&"'
out="$(run 'echo "$$a:r"')"
check test -z "$(rewritten "$out")"
# R21e2b 特殊パラメータを 2 文字まとめて読んでも、後ろの文字の引用状態はずれない（フラグは 1 文字ぶん）。
#   `$$` の直後の未引用 glob は、二重引用の中の `$$`（今回の変更で退行しかけた形）でも未引用の `$$`（以前からの取りこぼし）でも検出する。
for c in 'grep --include="$$"*.md .' 'grep --include=$$*.md .'; do
  out="$(run "$c")"
  check is_deny "$out"
done
# R21e3 パラメータ展開だけで効く修飾子（`f` / `w`）も書き換える。
out="$(run 'echo "$db:work" $p:foo')"
check test "$(rewritten "$out")" = 'echo "${db}:work" ${p}:foo'
# R21e4 bypassPermissions では単語分割の前置と波括弧の書き換えが 1 つの updatedInput にまとまる。
out="$(PM=bypassPermissions run 'cp $src:h/x .')"
check test "$(rewritten "$out")" = 'setopt SH_WORD_SPLIT; cp ${src}:h/x .'
# R21e5 修飾子の走査関数が無い（古いヘルパ）回は、修飾子だけの呼び出しを無出力で通し、glob の引用は続ける。
mkdir -p "$tmp/r21h/tests/lib"; cp -R "$root/hooks" "$tmp/r21h/hooks"; cp "$root/tests/lib/"*.sh "$tmp/r21h/tests/lib/"
printf '\nunset -f ff_zsh_modifier_fix_scan\n' >> "$tmp/r21h/tests/lib/zsh-glob-nomatch.sh"
out="$(payload 'echo "$db:r"' | env SHELL=/bin/zsh CLAUDECODE=1 CLAUDE_PROJECT_DIR="$tmp" bash "$tmp/r21h/hooks/guard-zsh-glob.sh")"
check test -z "$out"
out="$(payload 'grep "$q:t" --include=*.md .' | env SHELL=/bin/zsh CLAUDECODE=1 CLAUDE_PROJECT_DIR="$tmp" bash "$tmp/r21h/hooks/guard-zsh-glob.sh")"
check test "$(rewritten "$out")" = 'grep "$q:t" --include="*.md" .'
# R21f 未対応ホスト（CLAUDECODE なし）は修飾子だけの呼び出しを従来どおり無出力で通す（deny しない）。
out="$(payload 'echo "$db:r"' | env SHELL=/bin/zsh bash "$target")"
check test -z "$out"
# R21g 書き換え後は zsh で bash と同じ値になる（zsh が無い環境は skip を明示する）。
if command -v zsh >/dev/null 2>&1; then
  cmd='db=develop; printf "%s|" "+refs/heads/$db:refs/x"'
  out="$(run "$cmd")"
  check test "$(zsh -fc "$(rewritten "$out")" 2>&1)" = '+refs/heads/develop:refs/x|'
  check test "$(bash -c "$cmd" 2>&1)" = '+refs/heads/develop:refs/x|'
  check test "$(zsh -fc "$cmd" 2>&1)" = '+refs/heads/developefs/x|'
else
  echo "SKIP R21g: zsh が無いため修飾子の書き換え後の値を実処理系で確認できません" >&2
fi
echo "zsh rewrite: $pass checks passed"
