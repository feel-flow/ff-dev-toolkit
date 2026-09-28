#!/usr/bin/env bash
# Runtime contract for the literal-write guard hook (Issue `#1787` / 導入先 OBS-130).
#
# 配布物 hooks/guard-literal-write.sh を stdin JSON で直接駆動し、受け入れ条件の各分岐を固定する:
#   F. シェルの値が別言語のプログラムへ届かず、ファイル本文が無音で変わる形を実行前に deny する
#      （真陽性 3 形: perl -i / node -e / heredoc → インタプリタ。ほかに ${NAME}・継続行・前段の
#      コマンド・制御構文・bash -c / bash <<'EOF' の入れ子・引用しない heredoc の \$）
#   N. 陰性: エスケープ済み（`\$NAME` の形）・二重引用符でシェルが展開する形・export / 前置代入 /
#      set -a 済み・Perl 組み込み変数・-i の無い perl・python・スクリプトファイル・Write ツール
#      （と同じ効果の引用付き heredoc）・引数や PR 本文の中の綴り・コメント
#   A. 抜け道（先頭の FF_LITERAL_WRITE_ACK=1 / skip env）で通る。先頭以外の ACK は無効
#   C. 判定不能: 候補コマンドで判定ヘルパを読めない・走査が失敗する・引用や heredoc が閉じない・
#      入れ子が深すぎるときは理由付き deny（fail-closed）、候補でないコマンドは素通し
#   O. JSON でない入力・jq 不在・Bash 以外は素通し（fail-open）
#   D. stdin の drain（opt-out・ASDD ゲートの早期終了経路を含む）
#   R. hooks.json の集約入口への登録
#   P. 述語が真陽性とした形は、実際に走らせると本文が意図と違う値になる（perl / node 実行）
#   M. 変異検出
#
# 変異検出: 判定ヘルパの述語 A の呼び出し（if (inplace) rule_a(...)）を消したコピーは F1 と同形の perl -i を素通しし、F の検査が赤になる（M1。実測 2026-09-28）。
# 変異検出: 述語 A のエスケープ判定（奇数個の \ を読み飛ばす行）を消したコピーは N1（`\$SCRIPT_DIR` の形）を deny し、N の検査が赤になる（M2）。
# 変異検出: 述語 B の export 除外（!(nm in exported)）を消したコピーは N8（代入の後の export）を deny し、N の検査が赤になる（M3）。
# 変異検出: 述語 B の前置代入除外（!(nm in pref)）を消したコピーは N20（代入済みの名前の前置代入）を deny し、N の検査が赤になる（M5）。
# 変異検出: 二重引用符の中の $ を展開として読む分岐を消したコピーは N2（"s/x/$REPO/"）を deny し、N の検査が赤になる（M6）。
# 変異検出: node の heredoc をプログラムとして読む行を消したコピーは F11（heredoc → node）を素通しし、F の検査が赤になる（M7）。
# 変異検出: hook の ACK 分岐を無効化したコピーは A1 を deny し、hook の走査 rc 4 を素通しへ変えたコピーは C5 を素通しする（M8 / M9）。
# 変異検出: 入れ子シェルの値を取るオプション（-euo pipefail）の読み飛ばしを消すと F20、完了印（E 行）の照合を消すと C2'、親の未 export の名前の引き継ぎを消すと F30 が素通しになる（M10〜M12）。入れ子の上限を 1 段下げると F40（上限ちょうどの 3 段）が判定不能になる（M13。いずれもセルフレビュー対応後に実測 2026-09-28）。
# 空振り検出: 判定ヘルパが存在しない配置（対象の不在）・走査の awk が失敗する（FF_LITERAL_WRITE_AWK=false）・awk が何も出さずに 0 で終わる（FF_LITERAL_WRITE_AWK=true。完了印が無い）・関数が無い（名前だけ残って中身が変わる）のいずれを与えても、候補コマンドは無音の素通しではなく判定不能の deny になり C1〜C3 が赤→緑を分ける。どの入力にも 0 件を返すヘルパでは F 系がすべて素通しになり M4 が赤を要求する。引用・heredoc が閉じない入力（未終端）と入れ子が 3 段を超える入力は走査未完了の rc 4 として C5〜C7 が判定不能の deny を要求する（実測 2026-09-28）。
#
# run-all-required: no — jq 不在での skip を許容する（兄弟の hook suite と同じ判断）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$PLUGIN_ROOT/hooks/guard-literal-write.sh"
# ホスト環境の解除変数・テストシーム（hook 実装とその参照先が読む FF_* / CLAUDE_*）を
# 先頭で 1 回落とす。ケース固有の `NAME=v bash "$TARGET"` はこの後に代入として届く（Issue `#1808`）。
# shellcheck source=../lib/adapter-env-isolation.sh
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"
isolate_hook_env "FF_DEV_TOOLKIT_SKIP_LITERAL_WRITE_GUARD" "$TARGET"
SCAN_LIB="$PLUGIN_ROOT/tests/lib/literal-write-scan.sh"
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"
# shellcheck source=../lib/asdd-gate-drain.sh
. "$SCRIPT_DIR/../lib/asdd-gate-drain.sh"

[ -f "$TARGET" ] || { echo "✗ guard-literal-write.sh が見つかりません: $TARGET" >&2; exit 1; }
[ -f "$SCAN_LIB" ] || { echo "✗ literal-write-scan.sh が見つかりません: $SCAN_LIB" >&2; exit 1; }
[ -f "$HOOKS_JSON" ] || { echo "✗ hooks.json が見つかりません: $HOOKS_JSON" >&2; exit 1; }
if ! command -v jq >/dev/null 2>&1; then
  echo "○ skip: jq が見つからないためスキップ（guard-literal-write は未検査のままです）"
  exit 0
fi

# 利用者の環境（抜け道・opt-out・差し替え口・検査で使う変数名）を引き継いで偽緑 / 偽赤にしない。
unset FF_LITERAL_WRITE_ACK FF_DEV_TOOLKIT_SKIP_LITERAL_WRITE_GUARD FF_LITERAL_WRITE_AWK ROW REPO FF_LW_PRESET

if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/ff-guard-literal-write.XXXXXX" 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
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
    echo "✗ guard-literal-write: 最後まで到達しませんでした" >&2
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

# run_on <hook> <command> [NAME=VALUE ...]
run_on() {
  local hook="$1" cmd="$2" json
  shift 2
  json="$(jq -n --arg c "$cmd" --arg d "$TEST_TMP" \
    '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d, hook_event_name: "PreToolUse"}')"
  RC=0
  OUT="$(printf '%s' "$json" | env "$@" bash "$hook" 2>/dev/null)" || RC=$?
  DECISION="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)"
  REASON="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || true)"
}
run_hook() { run_on "$TARGET" "$@"; }

assert_fire() { # <label>
  if [ "$RC" -eq 0 ] && [ "$DECISION" = "deny" ]; then
    case "$REASON" in
      *判定不能*) bad "$1: 検出ではなく判定不能で止まった: [$REASON]" ;;
      *) ok "$1" ;;
    esac
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

# 発火させる形（F 系と M4 で共有する）。各行はそのまま Bash ツールへ渡るコマンド文字列。
FIRE_CASES=(
  # F1〜F5: 述語 A（perl -i の単一引用符プログラムに入ったシェル変数の綴り）
  $'perl -pi -e \'s{^cp a}{cp "$SCRIPT_DIR/lib/log.sh"}\' t.sh'
  $'perl -0777 -pi -e \'s/npm_called x/npm_called "$REPO"/\' t.sh'
  $'perl -pi -e \'s/x/${REPO}/\' f'
  $'cd /tmp && perl -pi.bak -e \'s/x/$REPO/\' f'
  $'perl -pi \\\n  -e \'s/x/$REPO/\' f'
  # F6〜F8: 述語 B の perl（export せずに代入した名前を $ENV{…} で読む）
  $'ROW=\'| a | b |\'; perl -i -pe \'BEGIN{$r=$ENV{ROW}} $_ .= "$r\\n" if /x/\' MASTER.md'
  $'declare ROW=abc; perl -i -pe \'$_ .= $ENV{ROW}\' f'
  $'ROW=a; perl -i -pe "\\$_ .= \\$ENV{\'ROW\'}" f'
  # F9〜F11: 述語 B の node（-e / 二重引用符 / heredoc）
  $'ROW=abc; node -e \'require("fs").writeFileSync("out.md", process.env.ROW)\''
  $'ROW=a; node -e "require(\'fs\').writeFileSync(\'o\', process.env[\'ROW\'])"'
  $'ROW=abc\nnode - <<\'EOF\'\nrequire(\'fs\').writeFileSync(\'out.md\', process.env["ROW"])\nEOF'
  # F12〜F13: heredoc → perl（引用付き / 引用しない区切り語の \$）
  $'perl -pi - f <<\'EOF\'\ns/x/$REPO/\nEOF'
  $'perl -pi - f <<EOF\ns/x/\\$REPO/\nEOF'
  # F14〜F16: 入れ子（bash -c / bash <<'EOF' / sh -c）
  $'bash -c "perl -pi -e \'s/x/\\$REPO/\' f"'
  $'bash -e <<\'EOF\'\nset -u\nperl -pi -e \'s/x/$REPO/\' f\nEOF'
  $'sh -c \'ROW=1; node -e "console.log(process.env.ROW)" > out.txt\''
  # F17〜F19: 制御構文・サブシェル・パイプの中
  $'if true; then perl -pi -e \'s/x/$REPO/\' f; fi'
  $'( perl -pi -e \'s/x/$REPO/\' f )'
  $'X=1 && env FOO=1 perl -pi -e \'s/x/$REPO/\' f | cat'
  # F20〜F25: 入れ子シェルの値を取るオプション・前置コマンドの値を取るオプション（レビューで見つけた回避形）
  $'bash -euo pipefail -c "perl -pi -e \'s/x/\\$REPO/\' f"'
  $'bash -o errexit -c \'N=1; perl -e "print \\$ENV{N}" > o\''
  $'nice -n 5 perl -pi -e \'s/x/$REPO/\' f'
  $'env -u FOO perl -pi -e \'s/x/$REPO/\' f'
  $'timeout -s KILL 5 perl -pi -e \'s/x/$REPO/\' f'
  $'perl -I lib -pi -e \'s/x/$REPO/\' f'
  # F26〜F29: 代入と export の順序（set -a は後の代入だけ・set +a で解除・export -n）と node -p -e
  $'ROW=a; set -a; perl -i -pe \'$_=$ENV{ROW}\' f'
  $'set -a; set +a; ROW=a; perl -i -pe \'$_=$ENV{ROW}\' f'
  $'ROW=a; export -n ROW; perl -i -pe \'$_=$ENV{ROW}\' f'
  $'ROW=a; node -p -e \'process.env.ROW\' > o'
  # F30: 親で export せずに代入した名前を入れ子のシェルの中で読む
  $'N=1; bash -c \'perl -i -pe "\\$_ = \\$ENV{N}" f\''
  # F31〜F38: 単独の & ・ANSI-C 引用のプログラム・<<- の heredoc・複数の -e・node --eval の 2 形・
  #          引用したコマンド名・bash -lc
  $'perl -pi -e \'s/x/$REPO/\' f &'
  $'true & perl -pi -e \'s/x/$REPO/\' f'
  $'perl -pi -e $\'s/x/$REPO/\' f'
  $'perl -pi - f <<-\'EOF\'\n\ts/x/$REPO/\n\tEOF'
  $'perl -pi -e \'s/a/b/\' -e \'s/x/$REPO/\' f'
  $'ROW=a; node --eval=\'process.env.ROW\' > o'
  $'"perl" -pi -e \'s/x/$REPO/\' f'
  $'bash -lc "perl -pi -e \'s/x/\\$REPO/\' f"'
  # F39: 算術コマンドの << の後ろ（シフト演算子を heredoc と読まない）
  $'(( y = 1 << 2 ))\nperl -pi -e \'s/x/$REPO/\' f'
  # F40: 入れ子 3 段（上限ちょうど。判定不能ではなく検出で止まる）
  $'bash <<\'A\'\nbash <<\'B\'\nbash -c \'perl -pi -e "s/x/\\$REPO/" f\'\nB\nA'
)

# 素通しさせる形（陰性）
PASS_CASES=(
  # N1: エスケープ済み（\$ は Perl へリテラルの $ として届く）
  $'perl -pi -e \'s{^cp a}{cp "\\$SCRIPT_DIR/lib/log.sh"}\' t.sh'
  # N2: 二重引用符のプログラム（シェルが先に展開する — 意図どおり）
  $'perl -pi -e "s/x/$REPO/" f'
  # N3: Perl 組み込み・パッケージ変数・小文字の変数・キャプチャ
  $'perl -0777 -pi -e \'s/a/$1 $ENV{HOME} $ARGV $_ @ARGV $Foo::Bar $foo ${1}/\' f'
  # N4〜N9: export / 前置代入 / env / set -a / export の後置 / declare -x
  $'export ROW=abc; perl -i -pe \'BEGIN{$r=$ENV{ROW}}\' f'
  $'ROW=abc perl -i -pe \'BEGIN{$r=$ENV{ROW}}\' f'
  $'env ROW=abc perl -i -pe \'BEGIN{$r=$ENV{ROW}}\' f'
  $'set -a; ROW=abc; perl -i -pe \'BEGIN{$r=$ENV{ROW}}\' f'
  $'ROW=abc; export ROW; node -e \'require("fs").writeFileSync("o", process.env.ROW)\''
  $'declare -x ROW=abc; node -e \'console.log(process.env.ROW)\''
  # N10〜N13: 射程の外（python は KeyError で大きな音で落ちる・スクリプトファイル・呼び出しの外の名前・-i の無い perl）
  $'ROW=abc; python3 -c \'import os; open("o","w").write(os.environ["ROW"])\''
  $'ROW=abc; node script.js'
  $'perl -i -pe \'$_ .= $ENV{ROW}\' f'
  $'perl -ne \'print "$REPO"\' f'
  # N14: 引用付き heredoc で本文を置く（Write ツールと同じ効果。本文の綴りはデータ）
  $'cat > note.md <<\'EOF\'\nperl -pi -e \'s/x/$REPO/\' f\nROW=1; node -e \'process.env.ROW\'\nEOF'
  # N15〜N18: 引数・PR 本文・コメントの中の綴り
  $'git commit -m "perl -pi -e \'s/x/$REPO/\' を直す"'
  $'gh pr create --body "$(cat <<\'EOF\'\nperl -pi -e \'s/x/$REPO/\' f -- don\'t\nROW=1; node -e \'process.env.ROW\'\nEOF\n)"'
  $'# perl -pi -e \'s/x/$REPO/\' f\necho ok'
  $'echo \'perl -pi -e s/x/$REPO/ f\''
  # N19: 変数を含まない perl -i
  $'perl -pi -e \'s/x/y/\' "$F"'
  # N20: 代入済みの名前を前置代入でも渡す（SP=$SP python3 … と同じ形）
  $'ROW=abc; ROW="$ROW" perl -i -pe \'BEGIN{$r=$ENV{ROW}}\' f'
  # N21〜N23: 入れ子シェルへ環境で渡す形（前置代入・export 済み）と set -a の後の代入
  $'N=1 bash -c \'perl -i -pe "\\$_ = \\$ENV{N}" f\''
  $'export N=1; bash -c \'perl -i -pe "\\$_ = \\$ENV{N}" f\''
  $'set -a; ROW=a; perl -i -pe \'$_=$ENV{ROW}\' f'
  # N24: 引用しない heredoc の $REPO はシェルが展開する（意図どおり）
  $'perl -pi - f <<EOF\ns/x/$REPO/\nEOF'
  # N25〜N27: 正しい bash を判定不能にしない（$( ) の中のコメントの単引用符・ANSI-C 引用・算術の <<）
  $'x=$(\n  # it\'s a perl $thing\n  echo hi\n)'
  $'echo "$(printf \'%s\' $\'it\\\'s\')"; perl -e 1 "$x"'
  $'echo $(( 1 << 2 )); perl -e 1 "$x"'
)

echo "guard-literal-write: F 発火（シェルの値が別言語のプログラムへ届かない形）"
fire_i=0
for c in "${FIRE_CASES[@]}"; do
  fire_i=$((fire_i + 1))
  run_hook "$c"
  assert_fire "F${fire_i}: deny [$(printf '%s' "$c" | tr '\n' ' ')]"
done
run_hook 'FF_LW_PRESET=a; perl -i -pe '"'"'$_ = $ENV{FF_LW_PRESET}'"'"' f'
assert_fire "F20: hook の環境に無い名前を export せずに代入して読む形は deny"

echo "guard-literal-write: 停止文の契約（検出箇所・対処・抜け道を出力自体に案内する）"
run_hook "${FIRE_CASES[1]}"
for needle in '$REPO' 'Write / Edit' "cat > <file> <<'EOF'" '\$NAME' 'FF_LITERAL_WRITE_ACK=1' 'FF_DEV_TOOLKIT_SKIP_LITERAL_WRITE_GUARD=1' 'OBS-130' 'literal-write-scan.sh'; do
  case "$REASON" in
    *"$needle"*) ok "述語 A の停止文が [$needle] を含む" ;;
    *) bad "述語 A の停止文に [$needle] が無い: [$REASON]" ;;
  esac
done
run_hook "${FIRE_CASES[5]}"
for needle in 'ROW' 'export NAME=' 'NAME=… perl'; do
  case "$REASON" in
    *"$needle"*) ok "述語 B の停止文が [$needle] を含む" ;;
    *) bad "述語 B の停止文に [$needle] が無い: [$REASON]" ;;
  esac
done

echo "guard-literal-write: N 非発火（陰性）"
pass_i=0
for c in "${PASS_CASES[@]}"; do
  pass_i=$((pass_i + 1))
  run_hook "$c"
  assert_pass "N${pass_i}: 素通し [$(printf '%s' "$c" | tr '\n' ' ')]"
done
run_hook 'FF_LW_PRESET=a; perl -i -pe '"'"'$_ = $ENV{FF_LW_PRESET}'"'"' f' FF_LW_PRESET=x
assert_pass "N21: 既に export 済み（hook の環境にある）名前への代入は環境へ反映されるので素通し"
run_hook 'export -n FF_LW_PRESET; FF_LW_PRESET=a; perl -i -pe '"'"'$_ = $ENV{FF_LW_PRESET}'"'"' f' FF_LW_PRESET=x
assert_fire "F41: hook の環境にある名前でも export -n で属性を外した後の代入は子へ渡らないので deny"
run_hook 'unset FF_LW_PRESET; FF_LW_PRESET=a; perl -i -pe '"'"'$_ = $ENV{FF_LW_PRESET}'"'"' f' FF_LW_PRESET=x
assert_fire "F42: unset した後の代入も export されないので deny（hook の環境にある名前でも）"
JSON_WRITE="$(jq -n --arg c "${FIRE_CASES[0]}" '{tool_name: "Write", tool_input: {file_path: "t.sh", content: $c, command: $c}}')"
RC=0
OUT="$(printf '%s' "$JSON_WRITE" | bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "N22: Write ツール（本文に同じ綴りを含む）は素通し"; else bad "N22: Write ツール: exit=$RC out=[$OUT]"; fi

echo "guard-literal-write: A 抜け道"
run_hook "FF_LITERAL_WRITE_ACK=1 ${FIRE_CASES[0]}"
assert_pass "A1: コマンド先頭の FF_LITERAL_WRITE_ACK=1 で通る"
run_hook "LC_ALL=C FF_LITERAL_WRITE_ACK=1 ${FIRE_CASES[0]}"
assert_fire "A2: ACK は呼び出しの先頭の語に限る（前に別の環境代入があると無効）"
run_hook "echo FF_LITERAL_WRITE_ACK=1; ${FIRE_CASES[0]}"
assert_fire "A3: 先頭以外（別コマンドの引数）の ACK は無効"
run_hook "A='x FF_LITERAL_WRITE_ACK=1 y'; ${FIRE_CASES[0]}"
assert_fire "A4: 引用値の中に現れる ACK は無効"
run_hook "FF_LITERAL_WRITE_ACK=1 true
${FIRE_CASES[0]}"
assert_pass "A5: 呼び出しの先頭に置いた ACK は呼び出し全体に効く（単位は Bash ツールの 1 呼び出し）"
run_hook "${FIRE_CASES[0]}" FF_DEV_TOOLKIT_SKIP_LITERAL_WRITE_GUARD=1
assert_pass "A6: FF_DEV_TOOLKIT_SKIP_LITERAL_WRITE_GUARD=1 で無効化できる"

echo "guard-literal-write: C 判定不能（候補コマンドに限り fail-closed）"
make_tree() { # <dir>
  mkdir -p "$1/hooks" "$1/tests/lib"
  cp "$TARGET" "$PLUGIN_ROOT/hooks/asdd-hook-gate.sh" "$PLUGIN_ROOT/hooks/asdd-feature.mjs" "$1/hooks/"
  cp "$SCAN_LIB" "$1/tests/lib/"
}
NOLIB="$TEST_TMP/nolib"
make_tree "$NOLIB"
rm -f "$NOLIB/tests/lib/literal-write-scan.sh"
run_on "$NOLIB/hooks/guard-literal-write.sh" "${FIRE_CASES[0]}"
assert_unavailable "C1: 判定ヘルパが無い配置では候補コマンドを判定不能の deny にする"
run_on "$NOLIB/hooks/guard-literal-write.sh" 'git status --short'
assert_pass "C1': 判定ヘルパが無くても候補でないコマンドは素通し（復旧作業を止めない）"
run_hook "${FIRE_CASES[0]}" FF_LITERAL_WRITE_AWK=false
assert_unavailable "C2: 走査の awk が失敗したら判定不能の deny にする"
run_hook "${FIRE_CASES[0]}" FF_LITERAL_WRITE_AWK=true
assert_unavailable "C2': awk が何も出さずに 0 で終わる（完了印が無い）ときも判定不能の deny にする"
NOFN="$TEST_TMP/nofn"
make_tree "$NOFN"
printf '# 関数定義を失ったヘルパ\n' > "$NOFN/tests/lib/literal-write-scan.sh"
run_on "$NOFN/hooks/guard-literal-write.sh" "${FIRE_CASES[0]}"
assert_unavailable "C3: ヘルパに ff_literal_write_scan_all が無いときは判定不能の deny にする"
run_on "$NOLIB/hooks/guard-literal-write.sh" "FF_LITERAL_WRITE_ACK=1 ${FIRE_CASES[0]}"
assert_pass "C4: 判定不能の状態でも先頭の ACK で通れる（案内した抜け道が効く）"
run_hook $'echo "unterminated; perl -pi -e \'s/x/$REPO/\' f'
assert_unavailable "C5: 引用が閉じないまま終わる候補コマンドは走査未完了として判定不能の deny にする"
run_hook 'echo "unterminated'
assert_pass "C5': 候補でない（perl / node が無い）未終端コマンドは素通し"
run_hook $'perl -pi - f <<\'EOF\'\ns/x/$REPO/'
assert_unavailable "C6: heredoc が終端しない候補コマンドは判定不能の deny にする"
run_hook $'bash -c "bash -c \\"bash -c \\\\\\"bash -c \'perl -pi -e s/x/y/ \\\\$F\'\\\\\\"\\""'
assert_unavailable "C7: 入れ子の bash -c が 3 段を超える候補コマンドは判定不能の deny にする"
ASDD_NONODE="$TEST_TMP/asdd-nonode"
mkdir -p "$ASDD_NONODE" "$TEST_TMP/jq-only-bin"
ff_asdd_fixture "$ASDD_NONODE" true
ln -s "$(command -v jq)" "$TEST_TMP/jq-only-bin/jq"
if PATH="$TEST_TMP/jq-only-bin:/usr/bin:/bin" command -v node >/dev/null 2>&1; then
  echo "  ○ skip: /usr/bin か /bin に node があるため ASDD 検証不能（node 不在）の経路は未検査"
else
  json_c8="$(jq -n --arg c "${FIRE_CASES[0]}" '{tool_name: "Bash", tool_input: {command: $c}}')"
  RC=0
  OUT="$(cd "$ASDD_NONODE" && printf '%s' "$json_c8" | env PATH="$TEST_TMP/jq-only-bin:/usr/bin:/bin" /bin/bash "$TARGET" 2>/dev/null)" || RC=$?
  DECISION="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)"
  REASON="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || true)"
  case "$DECISION:$REASON" in
    deny:*ASDD*) ok "C8: ASDD 設定を検証できない（config あり・node 不在）回は候補コマンドを判定不能の deny にする" ;;
    *) bad "C8: ASDD 検証不能が素通しになった: exit=$RC out=[$OUT]" ;;
  esac
fi
mkdir -p "$TEST_TMP/jq-fail-n"
REAL_JQ="$(command -v jq)"
{
  printf '#!/bin/bash\n'
  printf 'case " $* " in *" -n "*) exit 1 ;; esac\n'
  printf 'exec "%s" "$@"\n' "$REAL_JQ"
} > "$TEST_TMP/jq-fail-n/jq"
chmod +x "$TEST_TMP/jq-fail-n/jq"
json_c9="$(jq -n --arg c "${FIRE_CASES[1]}" '{tool_name: "Bash", tool_input: {command: $c}}')"
RC=0
ERR="$(printf '%s' "$json_c9" | env PATH="$TEST_TMP/jq-fail-n:$PATH" bash "$TARGET" 2>&1 >/dev/null)" || RC=$?
case "$RC:$ERR" in
  2:*'検出した箇所'*) ok "C9: deny の JSON を組み立てられないときは exit 2 + stderr の理由でブロックする（黙って許可しない）" ;;
  *) bad "C9: jq -n 失敗時の経路: rc=$RC err=[$ERR]" ;;
esac

echo "guard-literal-write: O fail-open（対象外）"
RC=0
OUT="$(printf 'not-json perl $REPO' | bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "JSON でない入力は無出力 exit 0"; else bad "JSON でない入力: exit=$RC out=[$OUT]"; fi
JSON_FIRE="$(jq -n --arg c "${FIRE_CASES[0]}" '{tool_name: "Bash", tool_input: {command: $c}}')"
RC=0
OUT="$(printf '%s' "$JSON_FIRE" | env PATH=/nonexistent /bin/bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "jq 不在（候補かどうか決められない）は無出力 exit 0"; else bad "jq 不在: exit=$RC out=[$OUT]"; fi

echo "guard-literal-write: D stdin の drain"
BIG_PAYLOAD="$(jq -n '{tool_name: "Bash", tool_input: {command: "echo ok"}, cwd: "/tmp"}')$(printf '%*s' 200000 '')"
RC=0
OUT="$(printf '%s' "$BIG_PAYLOAD" | env PATH=/nonexistent /bin/bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "PATH 空の環境でも stdin を読み切ってから無出力 exit 0"
else
  bad "PATH 空の drain: exit=$RC out=[$OUT]（rc=141 なら hook が stdin を drain せずに exit している）"
fi
RC=0
OUT="$(printf '%s' "$BIG_PAYLOAD" | env FF_DEV_TOOLKIT_SKIP_LITERAL_WRITE_GUARD=1 PATH=/nonexistent /bin/bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "opt-out でも stdin を読み切ってから無出力 exit 0"; else bad "opt-out の drain: exit=$RC out=[$OUT]"; fi
ASDD_ON="$TEST_TMP/asdd-hooks-on"
ASDD_OFF="$TEST_TMP/asdd-hooks-off"
mkdir -p "$ASDD_ON" "$ASDD_OFF"
ff_asdd_fixture "$ASDD_ON" true
ff_asdd_fixture "$ASDD_OFF" false
ASDD_PAYLOAD="$(ff_asdd_big_payload "$(jq -cn --arg c "${FIRE_CASES[0]}" '{tool_name: "Bash", tool_input: {command: $c}, cwd: "/tmp", hook_event_name: "PreToolUse"}')")"
ff_asdd_drain_probe "$TARGET" "$ASDD_PAYLOAD" "$ASDD_ON" PATH=/nonexistent
if [ "$FF_ASDD_DRAIN_RC" -eq 0 ] && [ -z "$FF_ASDD_DRAIN_OUT" ]; then
  ok ".asdd 設定あり + node 不在（ゲートが停止）でも stdin を読み切ってから無出力 exit 0"
else
  bad "ASDD ゲート（node 不在）の drain: exit=$FF_ASDD_DRAIN_RC out=[$FF_ASDD_DRAIN_OUT]"
fi
if command -v node >/dev/null 2>&1; then
  ff_asdd_drain_probe "$TARGET" "$ASDD_PAYLOAD" "$ASDD_OFF"
  if [ "$FF_ASDD_DRAIN_RC" -eq 0 ] && [ -z "$FF_ASDD_DRAIN_OUT" ]; then
    ok "features.hooks=false（ゲートが無効と判定）でも stdin を読み切ってから無出力 exit 0"
  else
    bad "ASDD ゲート（feature 無効）の drain: exit=$FF_ASDD_DRAIN_RC out=[$FF_ASDD_DRAIN_OUT]"
  fi
else
  echo "  ○ skip: node が無いため features.hooks=false 経路は未検査（guard-literal-write の ASDD ゲート無効判定）"
fi

echo "guard-literal-write: R hooks.json 登録の静的照合"
if jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]
    | select((.command | contains("run-bash-hooks.sh")) and (.command | contains("guard-literal-write.sh")))' "$HOOKS_JSON" >/dev/null 2>&1; then
  ok "hooks.json の PreToolUse（Bash matcher）の集約入口 run-bash-hooks.sh に登録されている"
else
  bad "hooks.json の PreToolUse（Bash matcher）の集約入口に guard-literal-write.sh が無い"
fi
DESC="$(jq -r '.description' "$HOOKS_JSON")"
case "$DESC" in
  *guard-literal-write.sh*FF_LITERAL_WRITE_ACK*) ok "hooks.json の description が literal-write ガードと抜け道に言及する" ;;
  *) bad "hooks.json の description に guard-literal-write.sh / FF_LITERAL_WRITE_ACK の記述が無い" ;;
esac

echo "guard-literal-write: P 述語の性質を実際に走らせて確かめる（本文が意図と違う値になる）"
PDIR="$TEST_TMP/probe"
mkdir -p "$PDIR"
if command -v perl >/dev/null 2>&1; then
  printf 'x\n' > "$PDIR/f"
  (cd "$PDIR" && REPO=/repo bash -c $'perl -pi -e \'s/x/$REPO/\' f') >/dev/null 2>&1 || true
  if [ "$(cat "$PDIR/f")" = "" ]; then
    ok "P1: 単一引用符の perl -i プログラムの \$REPO は、シェルの環境に REPO があっても空文字になる（述語 A の根拠）"
  else
    bad "P1: 述語 A の前提が崩れた（\$REPO が展開された）: [$(cat "$PDIR/f")]"
  fi
  printf 'x\n' > "$PDIR/f"
  (cd "$PDIR" && bash -c $'perl -pi -e \'s/x/\\$REPO/\' f') >/dev/null 2>&1 || true
  if [ "$(cat "$PDIR/f")" = "\$REPO" ]; then ok "P2: エスケープ済みの形はリテラルの \$REPO を書く（N1 の根拠）"; else bad "P2: [$(cat "$PDIR/f")]"; fi
  printf 'x\n' > "$PDIR/f"
  (cd "$PDIR" && bash -c $'ROW=abc; perl -i -pe \'$_ = "[$ENV{ROW}]\\n"\' f') >/dev/null 2>&1 || true
  if [ "$(cat "$PDIR/f")" = "[]" ]; then ok "P3: export せずに代入した ROW は \$ENV{ROW} に届かず空になる（述語 B の根拠）"; else bad "P3: [$(cat "$PDIR/f")]"; fi
  printf 'x\n' > "$PDIR/f"
  (cd "$PDIR" && bash -c $'ROW=abc perl -i -pe \'$_ = "[$ENV{ROW}]\\n"\' f') >/dev/null 2>&1 || true
  if [ "$(cat "$PDIR/f")" = "[abc]" ]; then ok "P4: 前置代入の ROW は \$ENV{ROW} に届く（N5 の根拠）"; else bad "P4: [$(cat "$PDIR/f")]"; fi
else
  echo "  ○ skip: perl が無いため P1〜P4 は未検査"
fi
if command -v node >/dev/null 2>&1; then
  (cd "$PDIR" && bash -c $'ROW=abc; node -e \'require("fs").writeFileSync("n.txt", String(process.env.ROW))\'') >/dev/null 2>&1 || true
  if [ "$(cat "$PDIR/n.txt" 2>/dev/null)" = "undefined" ]; then ok "P5: export せずに代入した ROW は node の process.env.ROW に届かず undefined を書く"; else bad "P5: [$(cat "$PDIR/n.txt" 2>/dev/null)]"; fi
else
  echo "  ○ skip: node が無いため P5 は未検査"
fi

echo "guard-literal-write: M 変異検出（コピーへ当て、本番検査と同形の針が赤になること）"
MUT="$TEST_TMP/mut"
make_tree "$MUT"
mutate_lib() { # <sed-script> <label>
  sed "$1" "$SCAN_LIB" > "$MUT/tests/lib/literal-write-scan.sh"
  if cmp -s "$SCAN_LIB" "$MUT/tests/lib/literal-write-scan.sh"; then
    bad "$2: sed が当たらず変異が注入されていない（針が古い）"
    return 1
  fi
  return 0
}
if mutate_lib '/if (inplace) rule_a(prog\[q\])/d' M1; then
  run_on "$MUT/hooks/guard-literal-write.sh" "${FIRE_CASES[0]}"
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "M1: 述語 A の呼び出しを消した変異は F1 を素通しし、F の検査が赤になる"; else bad "M1: 変異が効いていない: decision=[$DECISION]"; fi
fi
if mutate_lib '/if (bs % 2 == 1) continue$/d' M2; then
  run_on "$MUT/hooks/guard-literal-write.sh" "${PASS_CASES[0]}"
  if [ "$DECISION" = "deny" ]; then ok "M2: 述語 A のエスケープ判定を消した変異は N1 を deny し、N の検査が赤になる"; else bad "M2: 変異が効いていない: out=[$OUT]"; fi
fi
if mutate_lib 's/ \&\& !(nm in exported)//' M3; then
  run_on "$MUT/hooks/guard-literal-write.sh" "${PASS_CASES[7]}"
  if [ "$DECISION" = "deny" ]; then ok "M3: 述語 B の export 除外を消した変異は N8 を deny し、N の検査が赤になる"; else bad "M3: 変異が効いていない: out=[$OUT]"; fi
fi
printf 'ff_literal_write_scan_all() { return 0; }\n' > "$MUT/tests/lib/literal-write-scan.sh"
m4_pass=0
for c in "${FIRE_CASES[@]}"; do
  run_on "$MUT/hooks/guard-literal-write.sh" "$c"
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then m4_pass=$((m4_pass + 1)); fi
done
if [ "$m4_pass" -eq "${#FIRE_CASES[@]}" ]; then
  ok "M4: 常に 0 件を返すヘルパ（0 件一致）では F 系 ${m4_pass} 件がすべて素通しになり、F の検査が赤になる"
else
  bad "M4: 0 件ヘルパで素通しになったのは ${m4_pass}/${#FIRE_CASES[@]} 件"
fi
if mutate_lib 's/ \&\& !(nm in pref)//' M5; then
  run_on "$MUT/hooks/guard-literal-write.sh" "${PASS_CASES[19]}"
  if [ "$DECISION" = "deny" ]; then ok "M5: 述語 B の前置代入除外を消した変異は N20 を deny し、N の検査が赤になる"; else bad "M5: 変異が効いていない: out=[$OUT]"; fi
fi
if mutate_lib '/if (r) continue; w = w ch; i++; continue }$/s/r = dollar(); if (r < 0) { rc = 4; return } if (r) continue; //' M6; then
  run_on "$MUT/hooks/guard-literal-write.sh" "${PASS_CASES[1]}"
  if [ "$DECISION" = "deny" ]; then ok "M6: 二重引用符の中の \$ を展開として読む分岐を消した変異は N2 を deny し、N の検査が赤になる"; else bad "M6: 変異が効いていない: out=[$OUT]"; fi
fi
if mutate_lib 's/^    if (np == 0 \&\& (script == "" || script == "-") \&\& (id in hbody)) prog\[++np\] = hbody\[id\]$/    np = np/' M7; then
  run_on "$MUT/hooks/guard-literal-write.sh" "${FIRE_CASES[10]}"
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "M7: heredoc をプログラムとして読まない変異は F11（heredoc → node）を素通しし、F の検査が赤になる"; else bad "M7: 変異が効いていない: decision=[$DECISION]"; fi
fi
cp "$SCAN_LIB" "$MUT/tests/lib/literal-write-scan.sh"
sed "s/^  'FF_LITERAL_WRITE_ACK=1 '\\* | /  'FF_NO_SUCH_ACK=1 '* | /" "$TARGET" > "$MUT/hooks/guard-literal-write.sh"
if cmp -s "$TARGET" "$MUT/hooks/guard-literal-write.sh"; then
  bad "M8: sed が当たらず変異が注入されていない（針が古い）"
else
  run_on "$MUT/hooks/guard-literal-write.sh" "FF_LITERAL_WRITE_ACK=1 ${FIRE_CASES[0]}"
  if [ "$DECISION" = "deny" ]; then ok "M8: ACK 分岐を無効化した変異は A1 を deny し、A の検査が赤になる"; else bad "M8: 変異が効いていない: out=[$OUT]"; fi
fi
sed 's/^  4) deny_unavailable .*/  4) exit 0 ;;/' "$TARGET" > "$MUT/hooks/guard-literal-write.sh"
if cmp -s "$TARGET" "$MUT/hooks/guard-literal-write.sh"; then
  bad "M9: sed が当たらず変異が注入されていない（針が古い）"
else
  run_on "$MUT/hooks/guard-literal-write.sh" $'echo "unterminated; perl -pi -e \'s/x/$REPO/\' f'
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "M9: 走査 rc 4 を素通しへ変えた変異は C5 を素通しし、C の検査が赤になる"; else bad "M9: 変異が効いていない: decision=[$DECISION]"; fi
fi

cp "$TARGET" "$MUT/hooks/guard-literal-write.sh"
if mutate_lib '/if ((cw\[id, a\] ~ \/\^\[-+\]\[A-Za-z\]\*\[oO\]\$\//d' M10; then
  run_on "$MUT/hooks/guard-literal-write.sh" "${FIRE_CASES[19]}"
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "M10: 入れ子シェルの値を取るオプションを飛ばさない変異は F20（bash -euo pipefail -c）を素通しし、F の検査が赤になる"; else bad "M10: 変異が効いていない: decision=[$DECISION]"; fi
fi
if mutate_lib '/"\$done_seen" -eq 0 \]; then rc=5; fi$/d' M11; then
  run_on "$MUT/hooks/guard-literal-write.sh" "${FIRE_CASES[0]}" FF_LITERAL_WRITE_AWK=true
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "M11: 完了印の照合を消した変異は C2' を素通しし、C の検査が赤になる"; else bad "M11: 変異が効いていない: decision=[$DECISION]"; fi
fi
if mutate_lib '/if (inh\[k\] != "") assigned\[inh\[k\]\] = 1/d' M12; then
  run_on "$MUT/hooks/guard-literal-write.sh" "${FIRE_CASES[29]}"
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "M12: 親の未 export の名前を子へ引き継がない変異は F30 を素通しし、F の検査が赤になる"; else bad "M12: 変異が効いていない: decision=[$DECISION]"; fi
fi
if mutate_lib 's/"\$depth" -gt 4/"$depth" -gt 3/' M13; then
  run_on "$MUT/hooks/guard-literal-write.sh" "${FIRE_CASES[39]}"
  case "$DECISION:$REASON" in
    deny:*判定不能*) ok "M13: 入れ子の上限を 1 段下げた変異は F40（上限ちょうど）を判定不能にし、F の検査が赤になる" ;;
    *) bad "M13: 変異が効いていない: decision=[$DECISION]" ;;
  esac
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ guard-literal-write: ${FAIL} 件失敗（成功 ${PASS} 件）" >&2
  REACHED_END=1
  exit 1
fi
echo "✅ guard-literal-write: all ${PASS} checks passed"
REACHED_END=1
exit 0
