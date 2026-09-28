# shellcheck shell=bash
# case 35: パイプ終端の終了コード誤読の再混入ガード（検出器の実装は tests/lib/exit-code-guard.sh）
#
# verify.sh から source される（ok / bad / SCRIPT_DIR を共有）。verify.sh 本体が ADR-057 の
# 再判断ライン（4,000 行）を超えたため、別の契約（run-all ランナーではなく終了コード検出器）を
# 検査するこの塊を cases ファイルへ切り出した（Issue `#1805`。ADR-057 決定 2 / ADR-052 の
# 「単一 suite + 機能別 cases ファイル」）。検査の順序・件数は切り出し前と同じ（source する位置を
# 元の case 35 の位置に置く）。変異検出の実測は verify.sh ヘッダの case 35 の節。

echo "== case 35: パイプ終端の終了コード誤読の再混入ガード =="

# `cmd | head -20; echo "EXIT=$?"` は head の終了コードを読むため、非 0 で終わった実行が
# EXIT=0 として観測される（OBS-003 / ACE-259-3）。散文の警告は「手順に fence として書かれた
# コマンド」にしか届かず、同じ skill 実行中でも fence 外でアドホックに叩いた瞬間に同じ穴が
# 開いた（4 回目・Issue `#1156`）。読み手が該当コマンドを叩く瞬間に散文を思い出すことへ依存
# しない形にするため、違反の形そのものを静的に縛る。実装の正本は tests/lib/exit-code-guard.sh。

# shellcheck source=../../lib/exit-code-guard.sh
. "$SCRIPT_DIR/../lib/exit-code-guard.sh"

# 検出器の自己検証（空振りの fail-closed）。probe は単一引用符でくくる — 検出器は引用符の中を
# 伏せてから判定するので、この verify.sh 自身が probe を違反として検出することはない（case 11 の
# ACE-307-3 と同じ配慮）。PIPESTATUS の照合も単一引用符の中は伏せた版に当たるので同じ。
EXITCODE_PROBE_HEAD='bash verify.sh 2>&1 | head -20; echo "EXIT=$?"'
EXITCODE_PROBE_TAIL='bash verify.sh 2>&1 | tail -20; echo "EXIT=$?"'
EXITCODE_PROBE_NEXT='bash verify.sh 2>&1 | tail -20'
EXITCODE_PROBE_NEXT="${EXITCODE_PROBE_NEXT}
RC=\$?"
EXITCODE_PROBE_IF='bash verify.sh 2>&1 | tail -5'
EXITCODE_PROBE_IF="${EXITCODE_PROBE_IF}
if [ \$? -ne 0 ]; then echo ng; fi"
EXITCODE_PROBE_COMMENT='bash verify.sh 2>&1 | tail -20'
EXITCODE_PROBE_COMMENT="${EXITCODE_PROBE_COMMENT}
# rc check
RC=\$?"
EXITCODE_PROBE_GOOD='bash verify.sh >"$OUT" 2>&1 && RC=0 || RC=$?'
EXITCODE_PROBE_FEED='printf %s x | bash "$0" >/dev/null 2>&1 || rc=$?'
EXITCODE_PROBE_PS='st=("${PIPESTATUS[@]}")'
# ゲート起動が診断で終端する形（起動したプロセスの rc が診断のものになる）。`$?` の読み方は
# 正しくても、外側（background 実行の完了通知・CI ステップ）が「赤いゲートを緑」と断定する。
EXITCODE_PROBE_GATE_ECHO='FF_RUN_ALL_FULL=1 bash tests/run-all.sh > run-all.log 2>&1; echo "EXIT=$?"'
EXITCODE_PROBE_GATE_TAIL='bash plugins/ff-dev-toolkit/tests/run-all.sh 2>&1 | tail -20'
# 握り潰す形（実測: rc=7 のゲートを包むと全体が 0 になる）。
EXITCODE_PROBE_GATE_OR='bash tests/run-all.sh > log 2>&1 || echo FAILED'
EXITCODE_PROBE_GATE_PIPE_AND='bash tests/run-all.sh 2>&1 | tail -20 && echo done'
EXITCODE_PROBE_GATE_SEMI_AND='bash tests/run-all.sh > log 2>&1; echo A && echo B'
EXITCODE_PROBE_GATE_TRUE='bash tests/run-all.sh > log 2>&1 || true'
EXITCODE_PROBE_GATE_EXIT0='bash tests/run-all.sh > log 2>&1; exit 0'
EXITCODE_PROBE_GATE_BARE_TAIL='bash tests/run-all.sh > log 2>&1; tail -25 log'
EXITCODE_PROBE_GATE_EXITQ='bash tests/run-all.sh > log 2>&1; echo "EXIT=$?"; exit $?'
EXITCODE_PROBE_GATE_TIMEOUT='timeout 600 bash tests/run-all.sh > log 2>&1; echo "EXIT=$?"'
EXITCODE_PROBE_GATE_NOHUP='nohup bash tests/run-all.sh > log 2>&1; echo hi'
EXITCODE_PROBE_GATE_FEEDPIPE='printf x | bash tests/run-all.sh; echo "EXIT=$?"'
EXITCODE_PROBE_GATE_DIRECT='./tests/run-all.sh > log 2>&1; echo done'
EXITCODE_PROBE_GATE_SH='sh tests/run-all.sh > log 2>&1; echo done'
# Issue `#1683`: 単独 `&` の background 起動（`a & b` の rc は b のもの）・グループ実行・
# 末尾区間が環境代入で始まる形。いずれも実測で素通ししていた（hook 側の既知の限界）。
EXITCODE_PROBE_GATE_AMP='bash tests/run-all.sh > log 2>&1 & echo started'
EXITCODE_PROBE_GATE_BRACE='{ bash tests/run-all.sh > log 2>&1; }; echo done'
EXITCODE_PROBE_GATE_SUBSHELL='( bash tests/run-all.sh > log 2>&1 ); echo done'
EXITCODE_PROBE_GATE_ENVTAIL='bash tests/run-all.sh > log 2>&1; FOO=1 echo done'
EXITCODE_PROBE_GATE_WRAPTAIL='bash tests/run-all.sh > log 2>&1; command tail -5 log'
EXITCODE_PROBE_GATE_BRACE_TAIL='bash tests/run-all.sh > log 2>&1; { echo done; }'
# rc が残る形 / 起動ではない形（誤検出すると直しようのない赤になる）。
EXITCODE_PROBE_GATE_AND='bash tests/run-all.sh > log 2>&1 && echo OK'
EXITCODE_PROBE_GATE_OK='bash tests/run-all.sh > log 2>&1; rc=$?; echo "EXIT=$rc"; exit $rc'
EXITCODE_PROBE_GATE_EXITQ_OK='bash tests/run-all.sh > log 2>&1; exit $?'
EXITCODE_PROBE_GATE_SOLO='bash plugins/ff-dev-toolkit/tests/run-all.sh > run-all.log 2>&1'
EXITCODE_PROBE_GATE_READ='cat plugins/ff-dev-toolkit/tests/run-all.sh | head -20'
EXITCODE_PROBE_GATE_JQ='bash tests/run-all.sh 2>&1 | jq -R .'
EXITCODE_PROBE_GATE_ASSIGN='RUNNER=tests/run-all.sh; echo "$RUNNER"'
EXITCODE_PROBE_GATE_SUFFIX='bash tools/prerun-all.sh > log 2>&1; echo "EXIT=$?"'
# `&` を区切り子にしても、リダイレクトの `&`（`2>&1` / `>&2` / `&>`）とゲートを含まない行の
# `&` は赤にならない。グループ実行も終端が診断でなければ rc は残る。
EXITCODE_PROBE_GATE_REDIR_AMP='bash tests/run-all.sh >&2 2>&1'
EXITCODE_PROBE_GATE_AMP_NOGATE='git -C x log &'
EXITCODE_PROBE_GATE_BRACE_SOLO='{ bash tests/run-all.sh > log 2>&1; }'
EXITCODE_PROBE_GATE_SUBSHELL_AND='( bash tests/run-all.sh > log 2>&1 ) && echo OK'
# Issue `#1748`: 論理行をまたぐ持ち越し。推奨形から `exit $rc` の 1 語を落とした形（改行区切り）と、
# その偽陽性クラス 2 つ（二重引用符内 `$(…)` の入れ子・複数行にまたがる引用文字列）。
EXITCODE_PROBE_GATE_DROPPED='nohup bash tests/run-all.sh > log 2>&1'
EXITCODE_PROBE_GATE_DROPPED="${EXITCODE_PROBE_GATE_DROPPED}
rc=\$?
echo \"EXIT=\$rc\""
EXITCODE_PROBE_GATE_DROPPED_OK="${EXITCODE_PROBE_GATE_DROPPED}
exit \$rc"
EXITCODE_PROBE_GATE_NESTED_SUBST='run_hook "$(payload '"'"'git commit -m "x; bash tests/run-all.sh が要る"'"'"' general-purpose false "")"'
EXITCODE_PROBE_GATE_NESTED_SUBST="${EXITCODE_PROBE_GATE_NESTED_SUBST}
assert_silent \"(4L-1)\""
EXITCODE_PROBE_GATE_MULTILINE_QUOTE="jq -n --arg c 'cat > note.md <<EOF
  bash plugins/ff-dev-toolkit/tests/run-all.sh
EOF
git status --short' '{a: 1}'
echo next"
EXITCODE_PROBE_GATE_BLOCK_CLOSE="run_gate() {
  bash tests/run-all.sh > log 2>&1
}
run_gate; rc=\$?; exit \$rc"
EXITCODE_PROBE_GATE_CONSECUTIVE="bash tests/run-all.sh > log 2>&1
bash tests/run-all.sh > log 2>&1"
# 偽陰性側の対（クロスモデルレビューの指摘）: heredoc 本文の対にならない引用符が後続の実行行を
# 伏せない / 閉じない引用符の結合は 20 物理行で打ち切られ、その先の違反は見える。
EXITCODE_PROBE_GATE_HEREDOC_APOS="cat <<'EOF' > note.md
Don't panic
EOF
bash tests/run-all.sh > log 2>&1; echo done"
EXITCODE_PROBE_GATE_LONG_OPEN_QUOTE="echo 'open"
_ec_i=0
while [ "$_ec_i" -lt 24 ]; do
  EXITCODE_PROBE_GATE_LONG_OPEN_QUOTE="${EXITCODE_PROBE_GATE_LONG_OPEN_QUOTE}
prose line ${_ec_i}"
  _ec_i=$((_ec_i + 1))
done
EXITCODE_PROBE_GATE_LONG_OPEN_QUOTE="${EXITCODE_PROBE_GATE_LONG_OPEN_QUOTE}
bash tests/run-all.sh > log 2>&1; echo done"
EXITCODE_PROBE_GATE_VAR_CONSECUTIVE="bash tests/run-all.sh > log 2>&1
rc=\$?
bash tests/run-all.sh > log 2>&1
exit \$?"
# ゲート起動行の前置区間が持ち越した rc を消費する形（3 回転目: 消費判定をゲート行でも先に行う）。
EXITCODE_PROBE_GATE_STATUS_THEN_GATE="bash tests/run-all.sh > log 2>&1
[ \$? -eq 0 ] && FF_RUN_ALL_FULL=1 bash tests/run-all.sh > log2 2>&1"
EXITCODE_PROBE_GATE_VAR_THEN_GATE="bash tests/run-all.sh > log 2>&1
rc=\$?
[ \"\$rc\" -eq 0 ] && FF_RUN_ALL_FULL=1 bash tests/run-all.sh > log2 2>&1
exit \$?"
EXITCODE_PROBE_GATE_COLLECT3="bash tests/run-all.sh > log 2>&1 || RC=\$?
bash tests/run-all.sh > log 2>&1 || RC=\$?
bash tests/run-all.sh > log 2>&1 || RC=\$?
exit \${RC:-0}"
# 追加回転の指摘: 引数なし exit の伝播 / 保存変数の無条件上書き / `&&` 末尾代入は `$?` の持ち越し。
EXITCODE_PROBE_GATE_BARE_EXIT="bash tests/run-all.sh > log 2>&1
exit"
EXITCODE_PROBE_GATE_PIPE_BARE_EXIT='bash tests/run-all.sh 2>&1 | tail -20; exit'
EXITCODE_PROBE_GATE_ELIF="if [ x = y ]; then
  bash tests/run-all.sh > log 2>&1
elif [ a = b ]; then
  FF_RUN_ALL_FULL=1 bash tests/run-all.sh > log 2>&1
fi
rc=\$?
exit \$rc"
EXITCODE_PROBE_GATE_DONE_REDIR="while read -r x; do
  bash tests/run-all.sh > log 2>&1
done < list
rc=\$?
exit \$rc"
EXITCODE_PROBE_GATE_OVERWRITE_SAMELINE="bash tests/run-all.sh > log 2>&1
rc=\$?
echo \"\$rc\"; rc=0
exit \$rc"
EXITCODE_PROBE_GATE_OVERWRITE="bash tests/run-all.sh > log 2>&1
rc=\$?
rc=0
exit \$rc"
EXITCODE_PROBE_GATE_AND_ASSIGN_TAIL='bash tests/run-all.sh > log 2>&1 && ok=1'
# Issue `#1805`: 同じ論理行の「上書き → 参照」は区間の実行順に判定する（参照が先に追跡を解いて
# 上書きを見逃していた偽陰性）/ 自己参照の再代入は上書きではない / 閉じない引用符が単位の終端まで
# 続いても、20 行打ち切りと同じ再投入で末尾の 19 行以下を個別に解析する。
EXITCODE_PROBE_GATE_OVERWRITE_THEN_EXIT="bash tests/run-all.sh > log 2>&1
rc=\$?
rc=0; exit \$rc"
EXITCODE_PROBE_GATE_SELFREF_THEN_EXIT="bash tests/run-all.sh > log 2>&1
rc=\$?
rc=\${rc:-0}; exit \$rc"
EXITCODE_PROBE_GATE_SHORTCIRCUIT_THEN_EXIT="bash tests/run-all.sh > log 2>&1
rc=\$?
false && rc=0; exit \$rc"
EXITCODE_PROBE_GATE_SHORT_OPEN_QUOTE="echo 'open
prose line
bash tests/run-all.sh > log 2>&1; echo done"
# 再投入した行の中で `<<` が開いて閉じないまま終わる形も、heredoc の再投入を繰り返して解析する。
EXITCODE_PROBE_GATE_OPEN_QUOTE_HEREDOC="echo 'open
cat <<EOF
bash tests/run-all.sh 2>&1 | tail -3"
EXITCODE_FENCE='```'
EXITCODE_PROBE_MD_BASH="${EXITCODE_FENCE}bash
${EXITCODE_PROBE_TAIL}
${EXITCODE_FENCE}"
EXITCODE_PROBE_MD_TEXT="${EXITCODE_FENCE}text
${EXITCODE_PROBE_TAIL}
${EXITCODE_FENCE}"

EXITCODE_SELFTEST_OK=1
exitcode_expect() { # $1: 走査関数 / $2: probe / $3: hit|nohit / $4: 期待タグ（空可） / $5: 成立時の名 / $6: 不成立時の名
  # `_ec_out=$(...)` を素で書くと awk の非 0 が pipefail 経由で代入文の終了コードに乗り、
  # set -e が suite を即終了させる（case 11 の mbcs_expect と同じ理由）。if 形式で受ける。
  local _ec_out _ec_got=nohit _ec_matched=1
  if ! _ec_out="$(printf '%s\n' "$2" | "$1")"; then
    bad "$1 を実行できません（$6）"
    EXITCODE_SELFTEST_OK=0
    return 0
  fi
  [ -n "$_ec_out" ] && _ec_got=hit
  [ "$_ec_got" = "$3" ] || _ec_matched=0
  if [ -n "$4" ]; then
    case "$_ec_out" in
      *":$4:"*) ;;
      *) _ec_matched=0 ;;
    esac
  fi
  if [ "$_ec_matched" -eq 1 ]; then
    ok "$5"
  else
    bad "$6"
    EXITCODE_SELFTEST_OK=0
  fi
}

exitcode_expect exit_code_scan "$EXITCODE_PROBE_HEAD" hit pipe-exit-read \
  "終了コード検出器が \`| head\` の直後の \$? を検出できる（self-test）" \
  "終了コード検出器が \`| head\` の直後の \$? を検出できない — 横断検査は空振りするため実行しない"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_TAIL" hit pipe-exit-read \
  "終了コード検出器が \`| tail\` の直後の \$? を検出できる（self-test）" \
  "終了コード検出器が \`| tail\` の直後の \$? を検出できない"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_NEXT" hit pipe-exit-read \
  "終了コード検出器が直後の行での \$? 読みも検出できる（self-test）" \
  "終了コード検出器が直後の行での \$? 読みを取りこぼす"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_IF" hit pipe-exit-read \
  "終了コード検出器が制御構文での \$? 読み（if [ \$? -ne 0 ]）を検出できる（self-test）" \
  "終了コード検出器が制御構文での \$? 読みを取りこぼす — 代入・echo 以外の読み方が素通りする"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_COMMENT" hit pipe-exit-read \
  "終了コード検出器がコメント行を挟んだ \$? 読みも検出できる（self-test）" \
  "終了コード検出器がコメント行で切れている — \$? はコメントを跨いでも直前のパイプの値のまま"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_PS" hit pipestatus \
  "終了コード検出器が PIPESTATUS 参照を専用タグで報告する（self-test）" \
  "終了コード検出器が PIPESTATUS 参照を報告しない"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GOOD" nohit "" \
  "終了コード検出器がパイプ無しの \`&& RC=0 || RC=\$?\` を誤検出しない（self-test）" \
  "終了コード検出器がパイプ無しの正しい書き方を誤検出する"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_FEED" nohit "" \
  "終了コード検出器が入力供給パイプ（終端が測定対象）を誤検出しない（self-test）" \
  "終了コード検出器が入力供給パイプを誤検出する"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_ECHO" hit gate-exit-swallowed \
  "終了コード検出器が \`; echo\` 終端 を検出できる（self-test）" \
  "終了コード検出器が \`; echo\` 終端 を取りこぼす — 完了通知が赤いゲートを緑と断定する形が素通りする"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_TAIL" hit gate-exit-swallowed \
  "終了コード検出器が \`| tail\` 終端 を検出できる（self-test）" \
  "終了コード検出器が \`| tail\` 終端 を取りこぼす — 区間が 1 つでも成否は落ちる"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_OR" hit gate-exit-swallowed \
  "終了コード検出器が \`|| echo\` 終端 を検出できる（self-test）" \
  "終了コード検出器が \`|| echo\` 終端 を取りこぼす — ゲートが赤いときだけ右辺が走り、その 0 が全体の rc になる"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_PIPE_AND" hit gate-exit-swallowed \
  "終了コード検出器が \`| tail && echo\`（パイプで既に rc が落ちている） を検出できる（self-test）" \
  "終了コード検出器が \`| tail && echo\`（パイプで既に rc が落ちている） を取りこぼす — \`&&\` 例外がパイプ握り潰しまで免除している"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_SEMI_AND" hit gate-exit-swallowed \
  "終了コード検出器が \`; echo A && echo B\`（ゲート以降に \`;\` が混ざる） を検出できる（self-test）" \
  "終了コード検出器が \`; echo A && echo B\`（ゲート以降に \`;\` が混ざる） を取りこぼす — 区切り子を最後の 1 つだけで判定している"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_TRUE" hit gate-exit-swallowed \
  "終了コード検出器が \`|| true\` を検出できる（self-test）" \
  "終了コード検出器が \`|| true\` を取りこぼす — 診断が「抜け道も塞ぐ」と書いているのに実体が抜けている"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_EXIT0" hit gate-exit-swallowed \
  "終了コード検出器が \`; exit 0\` を検出できる（self-test）" \
  "終了コード検出器が \`; exit 0\` を取りこぼす — 赤を消す最短手が素通りする"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_BARE_TAIL" hit gate-exit-swallowed \
  "終了コード検出器が \`; tail -25 log\`（裸の出力整形コマンド） を検出できる（self-test）" \
  "終了コード検出器が \`; tail -25 log\`（裸の出力整形コマンド） を取りこぼす — 終端判定が echo / printf だけに閉じている"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_EXITQ" hit gate-exit-swallowed \
  "終了コード検出器が \`; echo …; exit $?\`（rc を取り忘れた取り違え） を検出できる（self-test）" \
  "終了コード検出器が \`; echo …; exit $?\`（rc を取り忘れた取り違え） を取りこぼす — 規定を読んだ人が最も踏みやすい形が素通りする"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_TIMEOUT" hit gate-exit-swallowed \
  "終了コード検出器が \`timeout\` ラッパ経由の起動 を検出できる（self-test）" \
  "終了コード検出器が \`timeout\` ラッパ経由の起動 を取りこぼす — background 起動の定番形が素通りする"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_NOHUP" hit gate-exit-swallowed \
  "終了コード検出器が \`nohup\` ラッパ経由の起動 を検出できる（self-test）" \
  "終了コード検出器が \`nohup\` ラッパ経由の起動 を取りこぼす — ラッパ前置きを剥がしていない"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_FEEDPIPE" hit gate-exit-swallowed \
  "終了コード検出器が 入力供給パイプ経由の起動 + 診断 を検出できる（self-test）" \
  "終了コード検出器が 入力供給パイプ経由の起動 + 診断 を取りこぼす — パイプの段ごとに起動を見ていない"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_DIRECT" hit gate-exit-swallowed \
  "終了コード検出器が 直接起動（\`./tests/run-all.sh\`） を検出できる（self-test）" \
  "終了コード検出器が 直接起動（\`./tests/run-all.sh\`） を取りこぼす — インタプリタ経由だけを起動と数えている"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_SH" hit gate-exit-swallowed \
  "終了コード検出器が \`sh\` 経由の起動 を検出できる（self-test）" \
  "終了コード検出器が \`sh\` 経由の起動 を取りこぼす — インタプリタ集合が bash だけに縮んでいる"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_AMP" hit gate-exit-swallowed \
  "終了コード検出器が 単独の \`&\` による background 起動（\`& echo started\`） を検出できる（self-test）" \
  "終了コード検出器が 単独の \`&\` による background 起動 を取りこぼす — split_segments が単独の & を区切り子にしていない"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_BRACE" hit gate-exit-swallowed \
  "終了コード検出器が \`{ … }\` のグループ実行 を検出できる（self-test）" \
  "終了コード検出器が \`{ … }\` のグループ実行 を取りこぼす — 先頭語 { を剥がしていない"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_SUBSHELL" hit gate-exit-swallowed \
  "終了コード検出器が \`( … )\` のサブシェル実行 を検出できる（self-test）" \
  "終了コード検出器が \`( … )\` のサブシェル実行 を取りこぼす — 先頭語 ( を剥がしていない"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_ENVTAIL" hit gate-exit-swallowed \
  "終了コード検出器が 末尾区間が環境代入で始まる形（\`FOO=1 echo done\`） を検出できる（self-test）" \
  "終了コード検出器が 末尾区間が環境代入で始まる形 を取りこぼす — is_silent_tail が前置きを剥がしていない"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_WRAPTAIL" hit gate-exit-swallowed \
  "終了コード検出器が 末尾区間がラッパで始まる形（\`command tail -5 log\`） を検出できる（self-test）" \
  "終了コード検出器が 末尾区間がラッパで始まる形 を取りこぼす — is_silent_tail が前置きを剥がしていない"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_BRACE_TAIL" hit gate-exit-swallowed \
  "終了コード検出器が 末尾区間がグループ（\`{ echo done; }\`） を検出できる（self-test）" \
  "終了コード検出器が 末尾区間がグループ を取りこぼす — 閉じ括弧だけの区間を終端と見ている"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_AND" nohit "" \
  "終了コード検出器が \`&& echo\`（短絡するので rc が保たれる） を誤検出しない（self-test）" \
  "終了コード検出器が \`&& echo\`（短絡するので rc が保たれる） を誤検出する — 安全な起動形まで止める直しようのない赤になる"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_OK" nohit "" \
  "終了コード検出器が 伝播まで書いた形（rc を取って exit する形） を誤検出しない（self-test）" \
  "終了コード検出器が 伝播まで書いた形（rc を取って exit する形） を誤検出する — 正しい起動形を誤検出する"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_EXITQ_OK" nohit "" \
  "終了コード検出器が \`; exit $?\`（ゲート直後なので伝播する） を誤検出しない（self-test）" \
  "終了コード検出器が \`; exit $?\`（ゲート直後なので伝播する） を誤検出する — 伝播する形まで赤にする"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_SOLO" nohit "" \
  "終了コード検出器が 単体起動 を誤検出しない（self-test）" \
  "終了コード検出器が 単体起動 を誤検出する — 単体起動を誤検出する"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_READ" nohit "" \
  "終了コード検出器が ゲートを**読むだけ**の参照 を誤検出しない（self-test）" \
  "終了コード検出器が ゲートを**読むだけ**の参照 を誤検出する — 名前の出現だけで赤くする形は運用できない"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_JQ" nohit "" \
  "終了コード検出器が 非フィルタ終端（終端そのものの成否を測りたい形） を誤検出しない（self-test）" \
  "終了コード検出器が 非フィルタ終端（終端そのものの成否を測りたい形） を誤検出する — 出力整形フィルタだけを対象にする境界が壊れている"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_ASSIGN" nohit "" \
  "終了コード検出器が 変数代入（起動ではない） を誤検出しない（self-test）" \
  "終了コード検出器が 変数代入（起動ではない） を誤検出する — 代入を起動と数える"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_SUFFIX" nohit "" \
  "終了コード検出器が 名前が後方一致する別スクリプト を誤検出しない（self-test）" \
  "終了コード検出器が 名前が後方一致する別スクリプト を誤検出する — basename の完全一致で見ていない"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_REDIR_AMP" nohit "" \
  "終了コード検出器が リダイレクトの \`&\`（\`>&2\` / \`2>&1\`） を区切り子と誤認しない（self-test）" \
  "終了コード検出器が リダイレクトの \`&\` を区切り子と誤認する — 単体起動が赤になる"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_AMP_NOGATE" nohit "" \
  "終了コード検出器が ゲートを含まない行の \`&\` を誤検出しない（self-test）" \
  "終了コード検出器が ゲートを含まない行の \`&\` を誤検出する — & を区切り子にしたことで無関係な行が赤になる"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_BRACE_SOLO" nohit "" \
  "終了コード検出器が グループ実行の単体起動（\`{ … }\` で終端） を誤検出しない（self-test）" \
  "終了コード検出器が グループ実行の単体起動 を誤検出する — 閉じ括弧を診断と数えている"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_SUBSHELL_AND" nohit "" \
  "終了コード検出器が サブシェル実行 + \`&& echo OK\` を誤検出しない（self-test）" \
  "終了コード検出器が サブシェル実行 + \`&&\` を誤検出する — 短絡する形まで赤にする"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_DROPPED" hit gate-exit-dropped \
  "終了コード検出器が 改行区切りで exit \$rc を落とした形（nohup 起動 ⏎ rc=\$? ⏎ echo） を検出できる（self-test）" \
  "終了コード検出器が 改行区切りで exit \$rc を落とした形 を取りこぼす — 論理行をまたぐ持ち越しを追っていない（Issue \`#1748\` の regression）"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_DROPPED_OK" nohit "" \
  "終了コード検出器が 改行区切りの推奨形（rc を取って exit \$rc で伝播） を誤検出しない（self-test）" \
  "終了コード検出器が 改行区切りの推奨形 を誤検出する — 規定どおりの書き方が赤になる"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_NESTED_SUBST" nohit "" \
  "終了コード検出器が 二重引用符内 \$(…) に入れ子で現れるゲート綴り を起動と見ない（self-test）" \
  "終了コード検出器が 二重引用符内 \$(…) の入れ子 を起動と誤認する — mask が内側の引用符を外側の閉じと取り違えている"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_MULTILINE_QUOTE" nohit "" \
  "終了コード検出器が 複数行にまたがる引用文字列の中間行 を起動と見ない（self-test）" \
  "終了コード検出器が 複数行にまたがる引用文字列の中間行 を起動と誤認する — 引用符が閉じるまで論理行を結合していない"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_BLOCK_CLOSE" nohit "" \
  "終了コード検出器が ブロックの最終コマンドがゲート（} で閉じる関数本体） を誤検出しない（self-test）" \
  "終了コード検出器が ブロックの閉じ行 を「rc を読まずに実行した行」と数える — 関数本体の暗黙 return が赤になる"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_CONSECUTIVE" hit gate-exit-dropped \
  "終了コード検出器が 連続するゲート起動（1 本目の rc を 2 本目が上書き） を検出できる（self-test）" \
  "終了コード検出器が 連続するゲート起動 を取りこぼす — 新起動で前の持ち越しを黙って捨てている"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_HEREDOC_APOS" hit gate-exit-swallowed \
  "終了コード検出器が heredoc 本文の対にならない引用符の後続行 の事故形を検出できる（self-test）" \
  "終了コード検出器が heredoc 本文の引用符に後続の実行行を伏せられる — 本文を読み飛ばしていない"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_LONG_OPEN_QUOTE" hit gate-exit-swallowed \
  "終了コード検出器が 20 行を超えて閉じない引用符 の先の事故形を検出できる（self-test）" \
  "終了コード検出器が 閉じない引用符で単位終端まで伏せている — 結合の行数上限が効いていない"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_VAR_CONSECUTIVE" hit gate-exit-dropped \
  "終了コード検出器が 変数へ受けた rc を消費しないまま次のゲートを起動する形 を検出できる（self-test）" \
  "終了コード検出器が 変数保存の持ち越しを次のゲート起動で黙って捨てている"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_STATUS_THEN_GATE" nohit "" \
  "終了コード検出器が \$? を読んでから 2 本目を起動する形（fast 緑なら全件） を誤検出しない（self-test）" \
  "終了コード検出器が ゲート行の前置区間の \$? 読み を消費と見ていない — 自然な連続起動が赤になる"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_VAR_THEN_GATE" nohit "" \
  "終了コード検出器が 変数で受けた rc をゲート行の前置区間が消費する形 を誤検出しない（self-test）" \
  "終了コード検出器が ゲート行の前置区間の変数参照 を消費と見ていない"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_COLLECT3" nohit "" \
  "終了コード検出器が 同じ変数への 3 本の条件付き集約 を誤検出しない（self-test）" \
  "終了コード検出器が 同名変数への集約 を 2 本前の取りこぼしと数えている"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_BARE_EXIT" hit gate-exit-dropped \
  "終了コード検出器が ゲート直後の引数なし exit を赤にする（文書化した偽陽性。self-test）" \
  "終了コード検出器が 引数なし exit を伝播と見ている — パイプ段・background の 5 形が無音になる"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_ELIF" nohit "" \
  "終了コード検出器が elif を挟む分岐の最終コマンドがゲート を誤検出しない（self-test）" \
  "終了コード検出器が ブロック境界を行全体の完全一致で見ている — 条件が付く elif を取りこぼす"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_DONE_REDIR" nohit "" \
  "終了コード検出器が リダイレクト付きの done で閉じるループ を誤検出しない（self-test）" \
  "終了コード検出器が ブロック境界を行全体の完全一致で見ている — リダイレクトが付く done を取りこぼす"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_PIPE_BARE_EXIT" hit gate-exit-swallowed \
  "終了コード検出器が パイプ段のゲート + 裸の exit を検出できる（self-test）" \
  "終了コード検出器が パイプ段のゲート + 裸の exit を取りこぼす — 裸の exit が運ぶのはパイプライン全体の rc"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_OVERWRITE_SAMELINE" hit gate-exit-dropped \
  "終了コード検出器が 同じ行の診断参照 + 無条件上書き を検出できる（self-test）" \
  "終了コード検出器が 上書き判定を論理行全体へ当てている — 同居する診断参照で上書きを見逃す"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_OVERWRITE" hit gate-exit-dropped \
  "終了コード検出器が 受けた rc の無条件上書き（rc=0） を検出できる（self-test）" \
  "終了コード検出器が 保存変数の上書き を見逃す — 元の rc が失われた形が緑になる"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_AND_ASSIGN_TAIL" nohit "" \
  "終了コード検出器が && の末尾代入が単位の最終行 を誤検出しない（self-test）" \
  "終了コード検出器が && の末尾代入 を変数の捕獲と数えている — 短絡で rc が残る形が赤になる"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_OVERWRITE_THEN_EXIT" hit gate-exit-dropped \
  "終了コード検出器が 同じ行の上書き → 参照（rc=0; exit \${rc}） を検出できる（self-test）" \
  "終了コード検出器が 同じ行の参照を上書きより先に消費と数えている — 区間の実行順に判定していない（Issue \`#1805\` の regression）"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_SELFREF_THEN_EXIT" nohit "" \
  "終了コード検出器が 自己参照の再代入（rc=\${rc:-0}）を同じ行に含む形 を誤検出しない（self-test）" \
  "終了コード検出器が 自己参照の再代入 を上書きと数えている — 正しい伝播形が赤になる"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_SHORTCIRCUIT_THEN_EXIT" nohit "" \
  "終了コード検出器が 短絡の直後の代入（false && rc=0）の後の参照 を誤検出しない（self-test）" \
  "終了コード検出器が 短絡で実行されないことがある代入 を無条件の上書きと数えている — 正しい伝播形が赤になる"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_SHORT_OPEN_QUOTE" hit gate-exit-swallowed \
  "終了コード検出器が 閉じない引用符の後 19 行以下で終わる入力 の事故形を検出できる（self-test）" \
  "終了コード検出器が 単位終端で引用符結合を再投入していない — 打ち切り経路と終端経路で境界が分かれている（Issue \`#1805\` の regression）"
exitcode_expect exit_code_scan "$EXITCODE_PROBE_GATE_OPEN_QUOTE_HEREDOC" hit gate-exit-swallowed \
  "終了コード検出器が 閉じない引用符の再投入で開いた未終端 heredoc の後続行 も検出できる（self-test）" \
  "終了コード検出器が 再投入で開いた未終端 heredoc を流し直していない — 単位終端の再投入が 1 回で止まっている"
EXITCODE_PROBE_MD_GATE="${EXITCODE_FENCE}bash
${EXITCODE_PROBE_GATE_ECHO}
${EXITCODE_FENCE}"
exitcode_expect exit_code_scan_bash_blocks "$EXITCODE_PROBE_MD_GATE" hit gate-exit-swallowed \
  "終了コード検出器が Markdown フェンス本文でも新タグを検出できる（self-test）" \
  "終了コード検出器が md 経路で新タグを落とす — SKILL.md が主要走査面なので影響が大きい"
exitcode_expect exit_code_scan_bash_blocks "$EXITCODE_PROBE_MD_BASH" hit pipe-exit-read \
  "終了コード検出器が Markdown の bash フェンス本文も検出できる（self-test）" \
  "終了コード検出器が bash フェンス本文を走査できていない"
exitcode_expect exit_code_scan_bash_blocks "$EXITCODE_PROBE_MD_TEXT" nohit "" \
  "終了コード検出器が bash 以外のフェンス本文を走査しない（self-test）" \
  "終了コード検出器が bash 以外のフェンスまで走査している"

# PIPESTATUS の診断が「zsh では機能しない」理由まで言えることを実体で確かめる（AC 3）。
# 文言が消えるとタグだけ出て理由が伝わらない = 直し方の分からない赤になる。
if /usr/bin/grep -qF -- 'zsh では空へ展開されて機能しない' "$SCRIPT_DIR/../lib/exit-code-guard.sh"; then
  ok "PIPESTATUS の診断が zsh で機能しない理由を含む"
else
  bad "PIPESTATUS の診断から zsh の理由が消えている（タグだけでは直し方が分からない）"
fi

# 横断検査が新タグで hits へ倒れること、そのとき**利用者へ届く stderr** が正しい形と抜け道を
# 名指しすることを、隔離した git fixture で実測する。
#
# 実装ファイルへ `grep -qF` を当てる形は採らない — needle が本体コードの無関係な箇所
# （`… || true` など）に当たって vacuous になり、案内行を丸ごと削除しても緑のままだった（実測）。
# 加えてファイル全体を見る形は「案内を stderr からコメントへ移す（＝利用者に届かなくなる）」
# 退行も緑にする。出力を捕まえるなら、届く経路そのものを捕まえる。
if ! command -v git >/dev/null 2>&1; then
  echo "  ○ skip: git が無いため横断検査の hits 経路をスキップ（この検査は 1 件も実行していません）"
else
  _gx_fx="${TMPDIR:-/tmp}/ff-run-all-gate-exit.$$"
  rm -rf "$_gx_fx"
  mkdir -p "$_gx_fx"
  printf '%s\n' '#!/usr/bin/env bash' 'bash tests/run-all.sh > log 2>&1; echo "EXIT=$?"' > "$_gx_fx/violate.sh"
  _gx_git() { git -c commit.gpgsign=false -c user.email=t@example.invalid -c user.name=T -c init.defaultBranch=main "$@"; }
  _gx_setup=0
  _gx_git -C "$_gx_fx" init -q . >/dev/null 2>&1 || _gx_setup=1
  _gx_git -C "$_gx_fx" add -A >/dev/null 2>&1 || _gx_setup=1
  _gx_git -C "$_gx_fx" commit -qm fixture >/dev/null 2>&1 || _gx_setup=1
  if [ "$_gx_setup" -ne 0 ]; then
    bad "横断検査 hits 経路の git fixture を作れない（検査が成立していない）"
  else
    set +e
    _gx_err="$(exit_code_check_tracked "$_gx_fx" 2>&1 >/dev/null)"
    _gx_sum="$(exit_code_check_tracked "$_gx_fx" 2>/dev/null)"
    _gx_rc=$?
    set -e
    case "$_gx_sum" in
      EXIT_CODE_RESULT=hits\ *) ok "横断検査は新タグの違反で hits へ倒れる（サマリー）" ;;
      *) bad "横断検査が新タグの違反を hits にしない（実際: ${_gx_sum}）" ;;
    esac
    if [ "$_gx_rc" -ne 0 ]; then ok "横断検査は違反ありで非 0 を返す"; else bad "横断検査が違反ありでも 0 を返す"; fi
    # 利用者へ届く stderr が、タグ・正しい形・抜け道の 3 点を名指しするか。
    for _gx_needle in \
      'gate-exit-swallowed' \
      'gate-exit-dropped' \
      'RUN_ALL_EXIT=' \
      'exit $rc' \
      '|| true' \
      '&&' ; do
      case "$_gx_err" in
        *"$_gx_needle"*) ok "横断検査の stderr が「${_gx_needle}」を含む" ;;
        *) bad "横断検査の stderr から「${_gx_needle}」が消えている（タグだけでは直し方も抜け道も伝わらない）" ;;
      esac
    done
  fi
  rm -rf "$_gx_fx"
fi

if [ "$EXITCODE_SELFTEST_OK" -eq 1 ]; then
  EXITCODE_REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" || EXITCODE_REPO_ROOT=""
  if [ -z "$EXITCODE_REPO_ROOT" ]; then
    bad "リポジトリルートを解決できない（git rev-parse 失敗）— 横断検査を実行できない"
  else
    # stdout=サマリー1行 / stderr=詳細。成功時は詳細不要、失敗時だけ再実行して詳細を出す。
    set +e
    EXITCODE_SUMMARY="$(exit_code_check_tracked "$EXITCODE_REPO_ROOT" 2>/dev/null)"
    EXITCODE_RC=$?
    set -e
    case "$EXITCODE_SUMMARY" in
      EXIT_CODE_RESULT=ok\ *)
        EXITCODE_SCANNED="$(printf '%s\n' "$EXITCODE_SUMMARY" | sed -E 's/.*SCANNED=([0-9]+).*/\1/')"
        ok "tracked の shell / SKILL.md / docs-template にパイプ終端の終了コード誤読が無い（${EXITCODE_SCANNED} ファイル走査）"
        ;;
      EXIT_CODE_RESULT=hits\ *)
        bad "パイプ終端の終了コードを読む書き方が再混入した"
        exit_code_check_tracked "$EXITCODE_REPO_ROOT" >/dev/null || true
        ;;
      EXIT_CODE_RESULT=error_repo\ *)
        bad "リポジトリルートを解決できない（git rev-parse 失敗）— 横断検査を実行できない"
        ;;
      EXIT_CODE_RESULT=error_list\ *)
        bad "検査対象の tracked ファイル一覧を取得できない（git ls-files 失敗/空）— 0 件の主張はできない"
        ;;
      EXIT_CODE_RESULT=error_scan\ *)
        bad "走査に失敗したファイルがある — そのファイルの 0 件は主張できない"
        exit_code_check_tracked "$EXITCODE_REPO_ROOT" >/dev/null || true
        ;;
      *)
        bad "終了コード横断検査の結果を解釈できない (rc=${EXITCODE_RC}): ${EXITCODE_SUMMARY:-empty}"
        exit_code_check_tracked "$EXITCODE_REPO_ROOT" >/dev/null || true
        ;;
    esac
  fi
fi
