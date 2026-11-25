#!/usr/bin/env bash
# Runtime contract for the zsh unquoted-glob NOMATCH guard hook (Issue `#1774`).
#
# 配布物 hooks/guard-zsh-glob.sh を stdin JSON で直接駆動し、受け入れ条件の各分岐を固定する:
#   F. zsh ホストで `--flag=<未引用 glob>`・URL のクエリ文字列の形（`a.md?ref=main`。Issue `#2138`）を含む呼び出しは
#      実行前に deny し、書き換え案を出す（Q: クエリ形の案は語全体の引用で、意味が変わる語には出さない）
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
#   P. PostToolUse（Bash）: 同じ判定の未引用 scalar を additionalContext でエージェントへ返し、止めない
#   X. equals / scalar expansion（Issue `#1942`）: `===` の equals 展開（not found）による中断と未引用 scalar の単語分割差を判定し、
#      zsh が無いホストでは実シェルでの確認だけを Z 系と同じ検査単位の skip にする（suite 全体の skip にしない）
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
# 空振り検出: 判定ヘルパが存在しない配置（対象の不在）・走査の awk が失敗する（FF_ZSH_GLOB_AWK=false）・関数が無い（名前だけ残って中身が変わる）のいずれを与えても、候補コマンドは無音の素通しではなく判定不能の deny になり C1〜C3 が赤→緑を分ける（どの入力にも 0 件を返すヘルパでは F 系 32 形がすべて素通しになり赤になる。M4。引用が閉じないまま終わる入力（未終端）は走査未完了の rc 4 として C6 が判定不能の deny を要求する。実測 2026-09-27）。
#
# 空振り検出: expansion の不在・関数欠落・awk失敗は判定不能、空出力変異は陽性対照で赤。
# 空振り検出: PostToolUse は実行済みなので判定器不在・走査失敗（FF_ZSH_GLOB_AWK=false）・JSON でない入力のどれでも止めず（fail-soft）、判定器不在と走査失敗は `$` を含む呼び出しに限り「未検査 / 判定不能」を additionalContext で返して検出 0 件と区別する（P4）。scalar 判定を消した scanner の変異は PostToolUse の陽性対照を黙らせる（P5）。
# run-all-required: no — jq 不在での skip を許容する（兄弟の hook suite と同じ判断。suite 全体の skip 経路は jq 不在だけで、zsh 不在は Z / X 系の検査単位 skip）
# 空振り検出: 入力書き換え（Issue `#2255`）は rewrite.sh が持つ。書き換えヘルパ関数の不在・走査失敗は deny へ戻ることを要求し、案を出さない hook は陽性の書き換え検査で赤になる（2026-10-25 実測）。
# 変異検出: Issue `#2181` の scalar-list を従来scalarへ戻すと、一覧引数の陽性対照がdenyを失い赤（2026-10-17実測）。
# 変異検出: Issue `#2138` のクエリ文字列の判定（check_query）を無効化すると、F 系・Q 系のクエリ形の検査が計 13 件赤になる（Z 系は実 zsh の性質なので緑のまま）。hook の前置フィルタからクエリ形（`?` の後ろの `=`）を外しても同じ 13 件が赤になり、直後の `&` の除外を外すと Q2 が赤になる（2026-10-26 実測）。
# 変異検出: typeset 系（export / typeset / local …）の `NAME=value` 引数の除外を外すと N22・N23 が、`builtin` / `command` 前置での除外の解除を外すと F26・F27 が、引用したコマンド名での解除を外すと F28・F29 が、左辺（`=` まで）を引用・エスケープした代入引数での解除を外すと F30〜F32 が、空の引用を含む語の書き換え案の除外を外すと Q2 が赤になる。hook の前置フィルタを `?` の後ろのどこかの `=` へ広げると C1q' が赤になる（2026-10-26 実測）。
# 空振り検出: クエリ形の素通し（引用済み・`ls a?.md`・エスケープ・代入値・`$?`・case パターン）は ZP 系が実際の zsh で NOMATCH にならないことを測り、`a?.md` が一致するファイル（ab.md）を置いた cwd で一般の ? glob を止めないことを固定する（2026-10-26 実測）。
# 空振り検出: RF（rm -f の未引用 glob。公開 https://github.com/feel-flow/ff-dev-toolkit/issues/165）は、走査の awk が失敗する（RF-C1）・ヘルパに ff_zsh_rm_force_scan が無い（RF-C2。名前だけ残って中身が変わる形）・引用が閉じないまま終わる（RF-C3。走査の rc 4）のどれでも rm の候補を判定不能の deny にし、glob 文字の無い rm -f はヘルパが壊れていても素通しにする（RF-C1'）。生の入力の "permission_mode" の綴りでは候補にせず、jq が壊れていても rm を含まない呼び出しは素通しにする（RF-C4。2026-11-25 Windows Git Bash 実測）。
# 変異検出: RF の判定ヘルパの -f の条件を外す（RF-M1）・glob 修飾子 (N) の読み取りを外す（RF-M2）・setopt null_glob の読み取りを外す（RF-M3）・-i の除外を外す（RF-M4）と、それぞれ RFP15 / RFP6 / RFP7 / RFP5 と同形の呼び出しが rm の検出の deny（判定不能ではない）になり、N を含む修飾子だけを数えない条件を外す（RF-M7）・サブシェル / 置換を閉じたら setopt の効き目を戻す行を外す（RF-M8 / RF-M9）・--interactive=never を対話と読む（RF-M10）・並べ替えの oN を NULL_GLOB と読む（RF-M11）・語の終わりの条件を外す（RF-M12）と RF の x*(.) / 閉じた後の rm / --interactive=never / x*(oN) / 語の途中の (N) の呼び出しが素通しになり、生の入力（JSON）の改行 \n の直後の rm を数えない（RF-M13）と行頭に rm がある複数行の呼び出しが素通しになり、hook の rm の deny を外す（RF-M5）・rm の前置フィルタを閉じる（RF-M6）と RF1 と同形の呼び出しが素通しになる（2026-11-25 Windows Git Bash 実測。RZ 系の実 zsh の測定は zsh 5.9 / WSL）。
#
# 依存の宣言（変更ベースの部分ゲートが、この suite を選ぶ変更）:
# run-all-depends: hooks/guard-zsh-glob.sh hooks/run-bash-hooks.sh hooks/guard-exit-code.sh hooks/guard-background-cwd.sh
# run-all-depends: hooks/asdd-hook-gate.sh hooks/asdd-feature.mjs scripts/asdd/config.mjs hooks/hooks.json
# run-all-depends: tests/lib/zsh-*.sh tests/lib/heredoc-strip*.sh scripts/lib/l4-declarations.*
# run-all-depends: tests/lib/adapter-env-isolation.sh tests/lib/asdd-gate-drain.sh
# run-all-not-depends: /.claude/settings.json 説明の言及（利用者のホームの設定ファイルの env の話で、リポジトリの設定は読まない）
# run-all-not-depends: tests/guard-background-cwd/verify.sh 説明の言及（別 suite が固定する範囲の案内）
# run-all-not-depends: tests/run-all.sh hook に判定させるコマンド文字列の中の名前（ランナーは実行しない）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$PLUGIN_ROOT/hooks/guard-zsh-glob.sh"
# ホスト環境の解除変数・テストシーム（hook 実装とその参照先が読む FF_* / CLAUDE_*）を
# 先頭で 1 回落とす。ケース固有の `NAME=v bash "$TARGET"` はこの後に代入として届く（Issue `#1808`）。
# shellcheck source=../lib/adapter-env-isolation.sh
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"
isolate_hook_env "FF_DEV_TOOLKIT_SKIP" "$TARGET"
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
unset CLAUDE_CODE_SHELL FF_ZSH_GLOB_ACK FF_DEV_TOOLKIT_SKIP FF_ZSH_GLOB_AWK CLAUDECODE CLAUDE_PROJECT_DIR GROK_PLUGIN_ROOT
# 既存 glob の契約を単独検査し、追加検出は X 節で有効化する。
export FF_DEV_TOOLKIT_SKIP=zsh-expansion

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
  'gh api repos/o/r/contents/a.md?ref=main --jq .content'
  'gh api repos/o/r/git/trees/v0.154.1?recursive=1; echo after'
  'gh api repos/{owner}/{repo}/pulls?state=open&per_page=1'
  'echo x && printf %s https://example.invalid/a?per_page=100'
  'builtin export U=a.md?ref=main'
  'command export U=a.md?ref=main'
  '"export" U=a.md?ref=main'
  '\export U=a.md?ref=main'
  'export "U"=a.md?ref=main'
  'export \U=a.md?ref=main'
  'export U""=a.md?ref=main'
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
  'gh api "repos/o/r/contents/a.md?ref=main" --jq .content'
  'ls a?.md'
  'ls a?.md *.md'
  'echo a\?ref=main'
  'X=a.md?ref=main; echo "$X"'
  'echo "${x:-a?b=c}" $?=1'
  'case a?b=c in ?ref=*) :;; *) echo n;; esac'
  'export U=a.md?ref=main; typeset -g V=a?b=c; echo "$U$V"'
  'if true; then local W=a?b=c 2>/dev/null; fi'
  'export U="a"?ref=main'
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
for needle in 'FF_ZSH_GLOB_ACK=1' 'FF_DEV_TOOLKIT_SKIP=zsh-glob' "bash <<'EOF'" 'no matches found' 'zsh-glob-nomatch.sh'; do
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

# クエリ文字列の形（Issue `#2138`）: 語全体を引用する案を出す。引用しても意味が変わる・直らない語には出さない。
run_hook 'gh api repos/o/r/contents/a.md?ref=main --jq .content'
case "$REASON" in
  *'"repos/o/r/contents/a.md?ref=main"'*) ok "Q1: クエリ文字列の形は語全体を引用した書き換え案を出す" ;;
  *) bad "Q1: クエリ文字列の形の書き換え案が無い: [$REASON]" ;;
esac
for c in 'curl -s https://example.invalid/a?x=1&y=2' 'echo a?x=1{b,c}' 'echo ~/a?x=1' 'echo a?x=$v' 'export U""=a?x=1'; do
  run_hook "$c"
  case "$DECISION:$REASON" in
    deny:*'書き換え案は出していません'*) ok "Q2: 引用すると意味が変わる・直らないクエリ形には書き換え案を出さない [$c]" ;;
    *) bad "Q2: 書き換え案を出さない形の案内が無い: exit=$RC out=[$OUT] [$c]" ;;
  esac
done

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
run_hook 'grep -rn "x" docs --include=*.md' FF_DEV_TOOLKIT_SKIP=zsh-glob
assert_pass "FF_DEV_TOOLKIT_SKIP=zsh-glob で無効化できる"
run_hook 'grep -rn "x" docs --include=*.md' FF_DEV_TOOLKIT_SKIP=zsh-globs
assert_fire "FF_DEV_TOOLKIT_SKIP の鍵の打ち間違い（zsh-globs）では止まったまま"
run_hook 'FF_ZSH_GLOB_ACK=1 gh api repos/o/r/contents/a.md?ref=main --jq .content'
assert_pass "クエリ文字列の形（Issue \`#2138\`）も先頭の FF_ZSH_GLOB_ACK=1 で通る"
run_hook 'gh api repos/o/r/contents/a.md?ref=main --jq .content' FF_DEV_TOOLKIT_SKIP=zsh-glob
assert_pass "クエリ文字列の形も FF_DEV_TOOLKIT_SKIP=zsh-glob で通る"

echo "guard-zsh-glob: C 判定不能（候補コマンドに限り fail-closed）"
make_tree() { # <dir>
  mkdir -p "$1/hooks" "$1/tests/lib" "$1/scripts/lib"
  cp "$TARGET" "$PLUGIN_ROOT/hooks/asdd-hook-gate.sh" "$PLUGIN_ROOT/hooks/asdd-feature.mjs" "$1/hooks/"
  cp "$PLUGIN_ROOT/tests/lib/zsh-expansion-guard.sh" "$PLUGIN_ROOT/tests/lib/heredoc-strip.sh" "$SCAN_LIB" \
    "$PLUGIN_ROOT/tests/lib/zsh-word-split-prefix.sh" "$1/tests/lib/"
  # 宣言の共通関数と名簿（配布物と同じ配置。無いと suite 全体の FF_DEV_TOOLKIT_SKIP=zsh-expansion が写しで効かない）
  cp "$PLUGIN_ROOT/scripts/lib/l4-declarations.sh" "$PLUGIN_ROOT/scripts/lib/l4-declarations.tsv" "$1/scripts/lib/"
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
# クエリ文字列の形（Issue `#2138`）も同じ fail-closed の面に入り、`?` の直後が `key=` でない形は候補にしない
run_on "$NOLIB/hooks/guard-zsh-glob.sh" 'gh api repos/o/r/contents/a.md?ref=main'
assert_unavailable "C1q: 判定ヘルパが無い配置ではクエリ文字列の形も判定不能の deny にする"
run_hook 'gh api repos/o/r/contents/a.md?ref=main' FF_ZSH_GLOB_AWK=false
assert_unavailable "C2q: 走査の awk が失敗したらクエリ文字列の形も判定不能の deny にする"
run_on "$NOLIB/hooks/guard-zsh-glob.sh" 'rc=$?; [ "$rc" = 0 ] && ls a?.md'
assert_pass "C1q': ? の直後が key= でない（rc=\$? や一般の ? glob）コマンドはヘルパが無くても素通し"
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
json_c7="$(jq -n '{tool_name: "Bash", tool_input: {command: "grep -rn x --include=*.md ."}}')"
RC=0
OUT="$(cd "$ASDD_NONODE" && printf '%s' "$json_c7" | env SHELL=/bin/zsh PATH="$TEST_TMP/jq-only-bin" "$BASH" "$TARGET" 2>/dev/null)" || RC=$?
DECISION="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)"
REASON="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || true)"
case "$DECISION:$REASON" in
  deny:*'asdd_hook_enabled rc=1。'*) ok "C7: ASDD 設定を検証できない（config あり・node 不在）回は候補コマンドを判定不能の deny にする" ;;
  *) bad "C7: ASDD 検証不能が素通しになった: exit=$RC out=[$OUT]" ;;
esac

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
OUT="$(printf '%s' "$BIG_PAYLOAD" | env SHELL=/bin/zsh FF_DEV_TOOLKIT_SKIP=zsh-glob PATH=/nonexistent /bin/bash "$TARGET" 2>/dev/null)" || RC=$?
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
if grep -q '^#.*FF_ZSH_GLOB_ACK' "$TARGET" && grep -q '^#.*FF_ZSH_EXPANSION_ACK' "$TARGET"; then
  ok "guard-zsh-glob.sh のヘッダが zsh glob / expansion ガードと抜け道に言及する"
else
  bad "guard-zsh-glob.sh のヘッダに FF_ZSH_GLOB_ACK / FF_ZSH_EXPANSION_ACK の記述が無い"
fi

# RF: `rm -f` のオペランドの未引用 glob（公開 https://github.com/feel-flow/ff-dev-toolkit/issues/165）。`=` を含まない形なので
# glob の前置フィルタとは別の候補で入り、書き換え案は語の引用ではなく zsh の glob 修飾子 (N) にする。
echo "guard-zsh-glob: RF rm -f の未引用 glob"
RF_FIRE_CASES=(
  'rm -f dir/x-*.json && echo ok'
  'rm -rf build/* tmp/a?.log'
  'rm dir/*.json -f'
  'rm --force x*'
  '/bin/rm -f x*'
  '"rm" -f x*'
  'echo "$(rm -f x*)"'
  'rm -f -- -x*'
  'rm -f x[0-9].log; echo after'
  'rm -f build/*.o(.) && make'
  'rm -f a(b)*.log'
  'rm -f *.(js|ts)'
  'rm -rf --interactive=never nomatch-*.x'
  '(setopt null_glob; rm -f a*); rm -f b* && echo ok'
  'echo "$(setopt null_glob; rm -f a*)"; rm -f b*'
  'rm -f zz*(oN)'
  'rm -f zz*(^N)'
  'rm -f a(N)b*.log'
  $'cd /tmp\nrm -f d/x-*.json && echo ok'
  $'mkdir -p d\n\trm -f d/x-*.json && echo ok'
)
RF_PASS_CASES=(
  "rm -f 'dir/x-*.json' && echo ok"
  'noglob rm -f dir/x-*.json'
  'rm dir/x-*.json'
  'ls *.md'
  'rm -fi x*'
  'rm -f dir/x-*.json(N) && echo ok'
  '(setopt null_glob; rm -f dir/x-*.json) && echo ok'
  'unsetopt nomatch; rm -f dir/x-*.json'
  "find dir -maxdepth 1 -name 'x-*.json' -delete"
  'git rm -f x*'
  'sudo rm -f x*'
  'rm -f x\*.json'
  'perform -f x*'
  'rm -f build.log'
  'rm -v dir/x-*.conf'
  'rm -f x*(.N) && echo ok'
  'rm -f --interactive=always x*'
)
rf_i=0
for c in "${RF_FIRE_CASES[@]}"; do
  rf_i=$((rf_i + 1))
  run_hook "$c"
  assert_fire "RF${rf_i}: zsh ホストで rm -f の未引用 glob は実行前に deny [$c]"
done
rfp_i=0
for c in "${RF_PASS_CASES[@]}"; do
  rfp_i=$((rfp_i + 1))
  run_hook "$c"
  assert_pass "RFP${rfp_i}: 止めない形は素通し [$c]"
done
run_hook 'rm -f dir/x-*.json && echo ok'
case "$REASON" in
  *'rm -f の未引用 glob'*'dir/x-*.json  →  dir/x-*.json(N)'*'setopt null_glob'*'find '*'FF_ZSH_GLOB_ACK=1'*) ok "RF-R1: 停止文は書き換え案 (N)・サブシェル・find・ACK を案内する" ;;
  *) bad "RF-R1: 停止文に書き換え案・抜け道が揃っていない: [$REASON]" ;;
esac
case "$REASON" in
  *'"dir/x-*.json"'*|*"'dir/x-*.json'"*) bad "RF-R2: rm の glob を引用する案を出している（引用すると何も消さずに成功する）: [$REASON]" ;;
  *) ok "RF-R2: rm の glob を引用する案は出さない" ;;
esac
run_hook 'rm -f "$d"/*.json'
case "$REASON" in
  *'修飾子を付けた案は出していません'*) ok "RF-R3: 展開を含む語には (N) の案を出さない" ;;
  *) bad "RF-R3: 展開を含む語の案の扱いが違う: decision=[$DECISION] reason=[$REASON]" ;;
esac
# 語に続く (…)（交替・修飾子）には (N) を足す案を出さない（`*.(N)(js|ts)` は zsh でも 0 件で失敗する）
run_hook 'rm -f *.(js|ts)'
case "$REASON" in
  *'(N)(js|ts)'*|*'*.(N)'*) bad "RF-R4: 語に続く ( の語へ (N) の案を出した: [$REASON]" ;;
  *'修飾子を付けた案は出していません'*) ok "RF-R4: 語に続けて ( を書いた語には (N) の案を出さない" ;;
  *) bad "RF-R4: 交替の語の扱いが違う: decision=[$DECISION] reason=[$REASON]" ;;
esac
run_hook 'rm -f x* && gh api repos/o/r/contents/a.md?ref=main'
case "$REASON" in
  *'rm -f の未引用 glob'*'URL のクエリ文字列の形'*'repos/o/r/contents/a.md?ref=main'*) ok "RF-R5: 併記するクエリ文字列の形の語も、その形の説明と案で併記する" ;;
  *) bad "RF-R5: 併記の説明がクエリ文字列の形に合わない: [$REASON]" ;;
esac
# 入力の書き換えができる環境（Claude Code）でも、rm の検出がある呼び出しは書き換えずに deny する
# （書き換えは --include= の右側を引用する形で、rm の検出を素通しにしてしまう）
run_hook 'rm -f x* && grep -rn x docs --include=*.md' CLAUDECODE=1 CLAUDE_PROJECT_DIR="$TEST_TMP"
rf_updated="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.updatedInput.command // empty' 2>/dev/null || true)"
if [ "$DECISION" = "deny" ] && [ -z "$rf_updated" ]; then
  case "$REASON" in
    *'rm -f の未引用 glob'*'--include=*.md'*) ok "RF-W1: 書き換え環境でも rm の検出は deny し、同じ呼び出しの = の右側の glob も併記する" ;;
    *) bad "RF-W1: deny の理由に rm と --include の両方が無い: [$REASON]" ;;
  esac
else
  bad "RF-W1: rm の検出がある呼び出しを書き換えた / 通した: decision=[$DECISION] updated=[$rf_updated]"
fi
run_hook 'FF_ZSH_GLOB_ACK=1 rm -f dir/x-*.json && echo ok'
assert_pass "RF-A1: 先頭の FF_ZSH_GLOB_ACK=1 で通る"
run_hook 'rm -f dir/x-*.json && echo ok' FF_DEV_TOOLKIT_SKIP=zsh-glob
assert_pass "RF-A2: FF_DEV_TOOLKIT_SKIP=zsh-glob で通る"
run_hook 'rm -f dir/x-*.json && echo ok' SHELL=/bin/bash
assert_pass "RF-H1: bash ホストでは発火しない"
run_hook "cat <<'EOF'
rm -f x*
EOF"
assert_pass "RF-N1: heredoc 本文の rm -f はデータとして素通し"
run_hook 'rm -f dir/x-*.json' FF_ZSH_GLOB_AWK=false
assert_unavailable "RF-C1: 走査の awk が失敗したら rm の候補も判定不能の deny にする"
run_hook 'rm -f build.log' FF_ZSH_GLOB_AWK=false
assert_pass "RF-C1': glob 文字の無い rm -f はヘルパが壊れていても素通し（候補に限る）"
run_hook 'rm -f x* "unterminated'
assert_unavailable "RF-C3: 引用が閉じないまま終わる rm の候補は判定不能の deny にする（走査の rc 4）"
# 生の入力（JSON）の "permission_mode" などの綴りの rm を候補に数えない。jq が壊れた回に、rm を含まない
# glob の呼び出し（glob の候補でもない形）を判定不能で止めない
mkdir -p "$TEST_TMP/rf-badjq"
printf '#!/bin/sh\nexit 3\n' > "$TEST_TMP/rf-badjq/jq"
chmod +x "$TEST_TMP/rf-badjq/jq"
rf_json="$(jq -n --arg d "$TEST_TMP" '{tool_name: "Bash", tool_input: {command: "ls *.md"}, cwd: $d, hook_event_name: "PreToolUse", permission_mode: "default"}')"
RC=0
OUT="$(printf '%s' "$rf_json" | env SHELL=/bin/zsh PATH="$TEST_TMP/rf-badjq:$PATH" bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "RF-C4: 入力の permission_mode の綴りでは rm の候補にせず、jq が壊れていても rm を含まない呼び出しは素通し"
else
  bad "RF-C4: rm を含まない呼び出しが候補になった: exit=$RC out=[$OUT]"
fi
RFNOFN="$TEST_TMP/rf-nofn"
make_tree "$RFNOFN"
sed '/^ff_zsh_rm_force_scan() {/,/^}/d' "$SCAN_LIB" > "$RFNOFN/tests/lib/zsh-glob-nomatch.sh"
if grep -q 'ff_zsh_rm_force_scan()' "$RFNOFN/tests/lib/zsh-glob-nomatch.sh"; then
  bad "RF-C2: 関数を除いた写しを作れていない"
else
  run_on "$RFNOFN/hooks/guard-zsh-glob.sh" 'rm -f dir/x-*.json'
  assert_unavailable "RF-C2: ヘルパに ff_zsh_rm_force_scan が無いときは rm の候補を判定不能の deny にする"
fi

echo "guard-zsh-glob: Z zsh 固有（述語の性質を実際の zsh で確かめる）"
if ZSH_BIN="$(command -v zsh 2>/dev/null)" && [ -n "$ZSH_BIN" ]; then
  ZDIR="$TEST_TMP/zsh-cwd"
  mkdir -p "$ZDIR/docs"
  # cwd に .md / .ts / .sh が実在していても NOMATCH になることを測る（cwd 非依存の実測）
  printf 'x\n' > "$ZDIR/docs/a.md"
  printf 'x\n' > "$ZDIR/a.ts"
  printf 'x\n' > "$ZDIR/a.md"
  printf 'x\n' > "$ZDIR/a.sh"
  printf 'x\n' > "$ZDIR/ab.md"  # `ls a?.md`（一般の ? glob）が一致する cwd で素通しを測る
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
  # RF: 0 件の未引用 glob を渡した rm -f は、zsh では rm を実行せず && の後段を止める。書き換え案は通る
  RZ="$TEST_TMP/rf-zsh"
  mkdir -p "$RZ/dir"
  zout="$(cd "$RZ" && "$ZSH_BIN" -f -c 'rm -f dir/x-*.json && echo ok' 2>&1)" || true
  case "$zout" in
    *'no matches found'*ok* | ok) bad "RZ1: rm -f の 0 件の glob で && の後段が走った: [$zout]" ;;
    *'no matches found'*) ok "RZ1: rm -f の 0 件の未引用 glob は zsh で NOMATCH になり && の後段が走らない" ;;
    *) bad "RZ1: zsh で NOMATCH にならない: [$zout]" ;;
  esac
  rz_i=1
  for c in 'rm -f dir/x-*.json(N) && echo ok' '(setopt null_glob; rm -f dir/x-*.json) && echo ok' "find dir -maxdepth 1 -name 'x-*.json' -delete && echo ok"; do
    rz_i=$((rz_i + 1))
    zout="$(cd "$RZ" && "$ZSH_BIN" -f -c "$c" 2>&1)" || true
    if [ "$zout" = ok ]; then ok "RZ${rz_i}: 書き換え案は 0 件でも zsh で成功する [$c]"; else bad "RZ${rz_i}: 書き換え案が zsh で成功しない: [$zout] [$c]"; fi
  done
  printf 'x\n' > "$RZ/dir/x-1.json"
  zout="$(cd "$RZ" && "$ZSH_BIN" -f -c 'rm -f dir/x-*.json(N) && ls dir && echo ok' 2>&1)" || true
  if [ "$zout" = ok ] && [ ! -e "$RZ/dir/x-1.json" ]; then ok "RZ5: 一致がある回は (N) 付きでも消す"; else bad "RZ5: (N) 付きで一致を消せない: [$zout]"; fi
  zout="$(cd "$RZ" && bash -c 'rm -f dir/x-*.json && echo ok' 2>&1)" || true
  if [ "$zout" = ok ]; then ok "RZ6: 同じ rm -f の形は bash では通る（bash ホストで発火させない根拠）"; else bad "RZ6: bash でも失敗した: [$zout]"; fi
  # N を含まない修飾子は 0 件で NOMATCH になる（修飾子付きでも数える根拠。RF の x*(.) の形）
  zout="$(cd "$RZ" && "$ZSH_BIN" -f -c 'rm -f dir/y-*.json(.) && echo ok' 2>&1)" || true
  case "$zout" in
    *'no matches found'*ok* | ok) bad "RZ7: N を含まない修飾子で 0 件なのに && の後段が走った: [$zout]" ;;
    *'no matches found'*) ok "RZ7: N を含まない修飾子（(.)）は 0 件で NOMATCH になる" ;;
    *) bad "RZ7: zsh で NOMATCH にならない: [$zout]" ;;
  esac
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
# RF の変異（公開 165）。写しの各行が実際に変わったことを確かめてから、本番検査と同形の針で見る
rf_mutate() { # <label> <sed 式> <src> <dst>
  sed "$2" "$3" > "$4"
  if cmp -s "$3" "$4"; then bad "$1: 変異注入が空振りした（sed が当たっていない）"; return 1; fi
  return 0
}
cp "$TARGET" "$MUT/hooks/guard-zsh-glob.sh"
# 判定ヘルパの変異は、rm の検出の deny（判定不能の deny ではない）になったことまで見る — sed が awk の構文を
# 壊した写しは判定不能の deny になるので、deny だけでは変異した判定を測ったことにならない
rf_caught() { # <label> <説明>
  case "$DECISION:$REASON" in
    deny:*'rm -f の未引用 glob'*) ok "$1: $2" ;;
    *) bad "$1: 変異が生き残った（または判定不能の deny）: decision=[$DECISION] reason=[$REASON]" ;;
  esac
}
rf_survive_pass() { # <label> <説明>
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "$1: $2"; else bad "$1: 変異が生き残った decision=[$DECISION] reason=[$REASON]"; fi
}
if rf_mutate "RF-M1" 's/if (rmc\[d\] \&\& rmf\[d\] \&\& !rmi\[d\] \&\& !rm_off) {/if (rmc[d] \&\& !rmi[d] \&\& !rm_off) {/' "$SCAN_LIB" "$MUT/tests/lib/zsh-glob-nomatch.sh"; then
  # hook の前置フィルタ（`-` の後ろの `f`）を通る形で、判定ヘルパの -f の条件だけを見る
  run_on "$MUT/hooks/guard-zsh-glob.sh" 'rm -v dir/x-*.conf'
  rf_caught RF-M1 "-f の条件を外した変異は -f の無い rm を deny し、RFP の検査が赤になる"
fi
if rf_mutate "RF-M2" 's/if (match(substr(src, i), /if (0 \&\& match(substr(src, i), /' "$SCAN_LIB" "$MUT/tests/lib/zsh-glob-nomatch.sh"; then
  run_on "$MUT/hooks/guard-zsh-glob.sh" 'rm -f dir/x-*.json(N) && echo ok'
  rf_caught RF-M2 "glob 修飾子の読み取りを外した変異は書き換え案 (N) の形を deny し、RFP の検査が赤になる"
fi
if rf_mutate "RF-M3" 's/if (rms\[d\]) rm_opt(w, rms\[d\], d)/if (0) rm_opt(w, rms[d], d)/' "$SCAN_LIB" "$MUT/tests/lib/zsh-glob-nomatch.sh"; then
  run_on "$MUT/hooks/guard-zsh-glob.sh" '(setopt null_glob; rm -f dir/x-*.json) && echo ok'
  rf_caught RF-M3 "setopt null_glob の読み取りを外した変異はサブシェルの書き換え案を deny し、RFP の検査が赤になる"
fi
if rf_mutate "RF-M4" 's/if (rmc\[d\] \&\& rmf\[d\] \&\& !rmi\[d\] \&\& !rm_off) {/if (rmc[d] \&\& rmf[d] \&\& !rm_off) {/' "$SCAN_LIB" "$MUT/tests/lib/zsh-glob-nomatch.sh"; then
  run_on "$MUT/hooks/guard-zsh-glob.sh" 'rm -fi x*'
  rf_caught RF-M4 "-i の除外を外した変異は rm -fi を deny し、RFP の検査が赤になる"
fi
if rf_mutate "RF-M7" 's/    if (c == "N" \&\& prev != "o" \&\& prev != "O" \&\& prev != "^") return 1/    return 1/' "$SCAN_LIB" "$MUT/tests/lib/zsh-glob-nomatch.sh"; then
  run_on "$MUT/hooks/guard-zsh-glob.sh" 'rm -f build/*.o(.) && make'
  rf_survive_pass RF-M7 "N を含む修飾子だけを数えない条件を外した変異は x*(.) の形を素通しにし、RF の検査が赤になる"
fi
if rf_mutate "RF-M11" 's/if (c == "N" \&\& prev != "o" \&\& prev != "O" \&\& prev != "^") return 1/if (c == "N") return 1/' "$SCAN_LIB" "$MUT/tests/lib/zsh-glob-nomatch.sh"; then
  run_on "$MUT/hooks/guard-zsh-glob.sh" 'rm -f zz*(oN)'
  rf_survive_pass RF-M11 "並べ替えの oN を NULL_GLOB と読む変異は x*(oN) の形を素通しにし、RF の検査が赤になる"
fi
if rf_mutate "RF-M12" 's/if ((rm_qn == "" || index(/if ((1 || index(/' "$SCAN_LIB" "$MUT/tests/lib/zsh-glob-nomatch.sh"; then
  run_on "$MUT/hooks/guard-zsh-glob.sh" 'rm -f a(N)b*.log'
  rf_survive_pass RF-M12 "語の終わりの条件を外した変異は語の途中の (N)（グループ）を素通しにし、RF の検査が赤になる"
fi
if rf_mutate "RF-M8" '/if (rm_off \&\& rm_off_d == D \&\& par\[D\] < rm_off_par) rm_off = 0/d' "$SCAN_LIB" "$MUT/tests/lib/zsh-glob-nomatch.sh"; then
  run_on "$MUT/hooks/guard-zsh-glob.sh" '(setopt null_glob; rm -f a*); rm -f b* && echo ok'
  rf_survive_pass RF-M8 "サブシェルを閉じたら setopt の効き目を戻す行を外した変異は、閉じた後の rm を素通しにし、RF の検査が赤になる"
fi
if rf_mutate "RF-M9" '/if (rm_off \&\& rm_off_d > D) rm_off = 0/d' "$SCAN_LIB" "$MUT/tests/lib/zsh-glob-nomatch.sh"; then
  run_on "$MUT/hooks/guard-zsh-glob.sh" 'echo "$(setopt null_glob; rm -f a*)"; rm -f b*'
  rf_survive_pass RF-M9 "置換を閉じたら setopt の効き目を戻す行を外した変異は、置換の後の rm を素通しにし、RF の検査が赤になる"
fi
if rf_mutate "RF-M10" 's/w ~ \/\^--interactive(=(always|once|yes))?\$\//w ~ \/^--interactive\//' "$SCAN_LIB" "$MUT/tests/lib/zsh-glob-nomatch.sh"; then
  run_on "$MUT/hooks/guard-zsh-glob.sh" 'rm -rf --interactive=never nomatch-*.x'
  rf_survive_pass RF-M10 "--interactive=never を対話と読む変異は、その rm を素通しにし、RF の検査が赤になる"
fi
cp "$SCAN_LIB" "$MUT/tests/lib/zsh-glob-nomatch.sh"
if rf_mutate "RF-M5" 's/^if \[ -n "\$rm_hits" \]; then$/if false; then/' "$TARGET" "$MUT/hooks/guard-zsh-glob.sh"; then
  run_on "$MUT/hooks/guard-zsh-glob.sh" 'rm -f dir/x-*.json && echo ok'
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "RF-M5: rm の deny を外した変異は RF の検査を素通しにして赤にする"; else bad "RF-M5: 変異が生き残った decision=[$DECISION]"; fi
fi
if rf_mutate "RF-M6" 's/^  \[\[ \$cmd =~ \$rm_word_re \]\] || rm_candidate=0$/  rm_candidate=0/' "$TARGET" "$MUT/hooks/guard-zsh-glob.sh"; then
  run_on "$MUT/hooks/guard-zsh-glob.sh" 'rm -f dir/x-*.json && echo ok'
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "RF-M6: rm の前置フィルタを閉じた変異は RF の検査を素通しにして赤にする"; else bad "RF-M6: 変異が生き残った decision=[$DECISION]"; fi
fi
# RF-M13: 生の入力（JSON）の前置フィルタから \n / \t / \r の直後の rm を外す（行頭の rm を持つ複数行の呼び出しが落ちる）
if rf_mutate "RF-M13" 's/^rm_raw_re=.*$/rm_raw_re="$rm_word_re"/' "$TARGET" "$MUT/hooks/guard-zsh-glob.sh"; then
  run_on "$MUT/hooks/guard-zsh-glob.sh" $'cd /tmp\nrm -f d/x-*.json && echo ok'
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "RF-M13: JSON の改行の直後の rm を数えない変異は複数行の RF を素通しにして赤にする"; else bad "RF-M13: 変異が生き残った decision=[$DECISION]"; fi
fi
cp "$TARGET" "$MUT/hooks/guard-zsh-glob.sh"

unset FF_DEV_TOOLKIT_SKIP
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
for c in 'git grep x -- $P' 'set -- $r' '$G commit' 'echo ${P}' 'noglob echo $P' 'echo "$(echo $P)"' 'for p in $P; do echo "$p"; done'; do
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
  run_on "$EXP_TARGET" "$c" FF_DEV_TOOLKIT_SKIP=zsh-expansion
  assert_pass 'skip'
  run_on "$EXP_TARGET" "$c" FF_DEV_TOOLKIT_SKIP=update-check,zsh-glob
  assert_pass 'skip: zsh-glob の宣言は covers で helper（zsh-expansion）も止める'
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
  # 検査単位の skip。行頭（列 0）の `○ skip` は run-all に suite 全体の skip と読まれ、実際に走った
  # X 系の検査が報告から消える（公開週次 CI では許容名簿外の skip として赤。Issue `#2102`）。
  echo '  ○ skip: zsh が無いため X 系の実シェル検証（equals / scalar の zsh での実測）は未検査'
fi

for c in 'echo ===' 'echo $P'; do
  run_on "$TARGET" "$c" FF_DEV_TOOLKIT_SKIP=zsh-glob
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

echo "guard-zsh-glob: P PostToolUse additionalContext（scalar 警告をエージェントへ届ける）"
# run_post <hook> <command> [NAME=VALUE ...] — PostToolUse の入力（tool_response 付き）で駆動する。
run_post() {
  local hook="$1" cmd="$2" json
  shift 2
  json="$(jq -n --arg c "$cmd" --arg d "$TEST_TMP" \
    '{tool_name: "Bash", tool_input: {command: $c}, tool_response: {stdout: "", stderr: ""}, cwd: $d, hook_event_name: "PostToolUse"}')"
  RC=0
  OUT="$(printf '%s' "$json" | env SHELL=/bin/zsh "$@" bash "$hook" 2>/dev/null)" || RC=$?
}
assert_context() { # <label> <needle>
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -se --arg n "$2" 'length == 1 and (.[0] | .hookSpecificOutput.hookEventName == "PostToolUse" and (.hookSpecificOutput.additionalContext | contains($n)) and (has("systemMessage") | not) and (.hookSpecificOutput | has("permissionDecision") | not))' >/dev/null 2>&1; then
    ok "$1"
  else bad "$1: exit=$RC out=[$OUT]"; fi
}
assert_silent() { # <label>
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "$1"; else bad "$1: exit=$RC out=[$OUT]"; fi
}
for c in 'set -- $t' 'P="a b"; git grep x -- $P' 'for t in "a b"; do set -- $t; done' 'echo === $P' 'grep $P --include=*.md'; do
  run_post "$TARGET" "$c"
  assert_context "P1 scalar は実行後に additionalContext で届く（止めない）: $c" '単語分割'
done
for c in 'echo "$P"' 'git status --short' 'echo ===' 'grep -rn x --include=*.md .' "echo '\$P'" $'cat <<\'EOF\'\necho $VAR\nEOF'; do
  run_post "$TARGET" "$c"
  assert_silent "P2 未引用 scalar を含まない呼び出しには何も足さない: $c"
done
run_post "$TARGET" 'set -- $t' SHELL=/bin/bash
assert_silent 'P3 bash ホストでは PostToolUse も無音'
run_post "$TARGET" 'FF_ZSH_EXPANSION_ACK=1 set -- $t'
assert_silent 'P3 先頭の FF_ZSH_EXPANSION_ACK=1 は PostToolUse も免除する'
run_post "$TARGET" 'set -- $t' FF_DEV_TOOLKIT_SKIP=zsh-expansion
assert_silent 'P3 FF_DEV_TOOLKIT_SKIP=zsh-expansion で PostToolUse も無効'
run_post "$TARGET" 'set -- $t' FF_DEV_TOOLKIT_SKIP=zsh-glob
assert_silent 'P3 FF_DEV_TOOLKIT_SKIP=zsh-glob で PostToolUse も無効'
# 空振り（判定器不在・走査失敗・JSON でない入力）は実行を止めない（fail-soft）。
run_post "$TARGET" 'set -- $t'
assert_context 'P1 検出した経路は空振りの可能性を前置する' '空振り'
run_post "$TARGET" 'set -- $t' FF_ZSH_GLOB_AWK=false
assert_context 'P4 走査失敗でも止めず $ を含む呼び出しに未検査を知らせる' '判定不能'
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("空振り") | not' >/dev/null 2>&1; then
  ok 'P4 判定不能の通知は検出したかのような前置を付けない'
else bad "P4 判定不能の通知に検出の前置が付いている: [$OUT]"; fi
for c in 'echo ===' 'git log --format=%H -1'; do
  run_post "$TARGET" "$c" FF_ZSH_GLOB_AWK=false
  assert_silent "P4 走査失敗でも \$ を含まない呼び出しには何も足さない: $c"
done
run_post "$TARGET" "echo 'abc --x=1"
assert_silent 'P4 未終端でも $ を含まない呼び出しには何も足さない'
xdir="$TEST_TMP/post-missing"
make_tree "$xdir"
rm "$xdir/tests/lib/zsh-expansion-guard.sh"
run_post "$xdir/hooks/guard-zsh-glob.sh" 'set -- $t'
assert_context 'P4 判定器不在は $ を含む呼び出しに未検査を知らせる' '未検査'
run_post "$xdir/hooks/guard-zsh-glob.sh" 'git status --short'
assert_silent 'P4 判定器不在でも $ を含まない呼び出しは無音'
RC=0
OUT="$(printf 'not json "PostToolUse"' | env SHELL=/bin/zsh bash "$TARGET" 2>/dev/null)" || RC=$?
assert_silent 'P4 JSON でない入力は無音で通す'
# 判定本体の共有: scanner の scalar 判定を消した変異は PreToolUse と同じく PostToolUse も黙らせる。
xdir="$TEST_TMP/post-mut"
make_tree "$xdir"
sed 's/print "scalar"; return/return/' "$SCAN_LIB" > "$xdir/tests/lib/zsh-glob-nomatch.sh"
run_post "$xdir/hooks/guard-zsh-glob.sh" 'set -- $t'
if [ -z "$OUT" ]; then ok 'P5 scalar 判定を消した変異は PostToolUse の陽性対照を黙らせる（判定を共有している）'; else bad 'P5 PostToolUse が共有判定以外で警告している'; fi
if jq -e '[.hooks.PostToolUse[]? | select(.matcher == "Bash") | .hooks[]?.command | contains("/hooks/guard-zsh-glob.sh")] | any' "$HOOKS_JSON" >/dev/null; then
  ok 'P6 hooks.json の PostToolUse（Bash matcher）に guard-zsh-glob.sh が登録されている'
else bad 'P6 hooks.json の PostToolUse（Bash matcher）に guard-zsh-glob.sh が無い'; fi


# 同じ呼び出しで確定した一覧だけを停止対象にする（公開 `#139` / Issue `#2181`）。
unset FF_DEV_TOOLKIT_SKIP
for list_cmd in 'FILES="a.md b.md"; npx prettier --check $FILES' 'FILES="a.md b.md"; git add ${FILES}' 'P="a b"; git grep x -- $P' 'FILES=$(git diff --name-only); npx eslint $FILES' 'FILES=`git diff --name-only`; git add $FILES'; do
  run_hook "$list_cmd"
  assert_fire 'L1 同じ呼び出しで代入した一覧の未引用引数を停止'
done
for safe_cmd in 'FILES="a.md b.md"; git add "$FILES"' 'FILES="a.md b.md"; git add "${FILES[@]}"' 'FILES="one.md"; git add $FILES' 'git add $FILES' 'FILES="a.md b.md"; FILES=one.md; git add $FILES' 'FILES="a.md b.md" git status; git add $FILES' 'echo "FILES=a b"; git add $FILES' '(FILES="a.md b.md"); git add $FILES' 'FILES="a.md b.md"; bash -c '\''git add $FILES'\'''; do
  run_hook "$safe_cmd"
  if [ "$RC" -eq 0 ] && [ "$DECISION" != deny ]; then ok 'L2 引用・値不明・単一値・別スコープは新しい停止対象外'; else bad "L2 誤停止: $safe_cmd"; fi
done
# ACK は環境変数ではなく、呼び出し先頭の語を契約とする。
run_hook 'FF_ZSH_GLOB_ACK=1 FILES="a.md b.md"; git add $FILES'
if [ "$DECISION" != deny ]; then ok 'L3 共通 ACK で一覧停止を免除'; else bad 'L3 ACK が効かない'; fi
run_hook 'FILES="a.md b.md"; git add $FILES' SHELL=/bin/bash
assert_pass 'L4 bash ホストは一覧停止の対象外'

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ guard-zsh-glob: ${FAIL} 件失敗（成功 ${PASS} 件）" >&2
  REACHED_END=1
  exit 1
fi
if ! bash "$(dirname "$0")/rewrite.sh"; then
  echo "✗ guard-zsh-glob: 入力書き換えの検査（rewrite.sh）が失敗しました" >&2
  REACHED_END=1
  exit 1
fi
echo "✅ guard-zsh-glob: all ${PASS} checks passed"
REACHED_END=1
exit 0
