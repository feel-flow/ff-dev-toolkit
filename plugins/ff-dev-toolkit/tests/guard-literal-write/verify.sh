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
#   DF / DN / DP. 述語 D（Issue `#2450`）: インタプリタへ引用付き heredoc で渡すプログラムの二重バックスラッシュの
#      回避形行列（deny / allow）と、解釈の前後の値の差の実測（python3）
#   PF / PN / PP. 述語 P（Issue `#2496`）: pwsh / powershell の -Command の二重引用符の中のバッククォートの
#      回避形行列（deny / allow）と、二重引用符・単一引用符の実測（pwsh / powershell が在れば）
#   QF / QN / QP. 述語 Q（Issue `#2651`）: コマンド行の引数の二重バックスラッシュの引用の種類ごとの行列（deny / allow）と、
#      \\ を \ に縮めた形と元の形を bash で実行した出力の差（止める形は変わり、止めない形は変わらない）
#
# 変異検出: 述語 D の判定を空にする（M14）・引用付き heredoc の原文を残さない（M15）と DF1 が素通しになり、python の escape 文字の絞り込みを外すと DN2 が deny になる（M19）。述語 P の検出を消す（M16）・hook の前置フィルタから pwsh を外す（M18）と PF1 が素通しになり、PowerShell の単一引用符を読み飛ばさないと PN1 が deny になる（M17。いずれも実測 2026-11-02 Windows Git Bash）。
# 変異検出: 述語 Q（Issue `#2651`）: 単一引用符の中の \\ を見ない（M25）・hook の前置フィルタから二重バックスラッシュを外す（M29）と QF1 が素通しになり、入れ子の走査にも Q を当てる（M26）と QN11、二重引用符の中で次の文字を見ずに止める（M27）と QN1、Claude Code 以外のホストで Q を落とさない（M28）と QN14 が deny になり、前置判定の二重バックスラッシュをホストで絞らない（M30）と QC1 が判定不能の deny になる。D の M22 は、前置判定がホストで絞るようになったので、perl と $ で候補になる DN17 を入力にする（実測 2026-11-06 WSL）。
# 空振り検出: 述語 Q の q_hit の定義を消して呼び出しだけ残すと awk が失敗し、二重バックスラッシュを含む候補が判定不能の deny になって 15 件赤（QF1 は「検出ではなく判定不能」で赤。WSL の awk で測った）。Q 行の綴りを変えて中継（ff_literal_write_scan_all）が拾わない形にすると QF 系が素通しになって 21 件赤。hook の前置判定を生の入力の 2 本（1 本の \ ）へ戻すと、Windows の cwd を持つ呼び出しがすべて jq へ進み、壊れた jq で QN15 が判定不能の deny になって赤。正常は 252/0（2026-11-06 WSL 実測）。
# 変異検出: パイプの送り側を記録しない（M20）と DF19、/dev/stdin をスクリプト引数として読まない（M23）と DF20、二重引用符の中の部分式を追わない（M21）と PF15 が素通しになり、Claude Code 以外のホストで述語 D を落とす分岐を消す（M22）と DN13 が、CLAUDECODE だけで Claude Code と決める（M24。レビュー 2 巡目）と DN15 が deny になる（レビュー 1 巡目の対応後に実測 2026-11-02）。
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

# run_on <hook> <command> [NAME=VALUE ...] — RUN_EXTRA（JSON オブジェクト）を入力へ足せる（例: {"model":"codex"}）
run_on() {
  local hook="$1" cmd="$2" json extra="${RUN_EXTRA:-}"
  shift 2
  [ -n "$extra" ] || extra='{}'
  json="$(jq -n --arg c "$cmd" --arg d "$TEST_TMP" --argjson x "$extra" \
    '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d, hook_event_name: "PreToolUse"} + $x')"
  RC=0
  OUT="$(printf '%s' "$json" | env -u GROK_PLUGIN_ROOT "$@" bash "$hook" 2>/dev/null)" || RC=$?
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
json_c8="$(jq -n --arg c "${FIRE_CASES[0]}" '{tool_name: "Bash", tool_input: {command: $c}}')"
RC=0
OUT="$(cd "$ASDD_NONODE" && printf '%s' "$json_c8" | env PATH="$TEST_TMP/jq-only-bin" "$BASH" "$TARGET" 2>/dev/null)" || RC=$?
DECISION="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)"
REASON="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || true)"
case "$DECISION:$REASON" in
  deny:*'asdd_hook_enabled rc=1。'*) ok "C8: ASDD 設定を検証できない（config あり・node 不在）回は候補コマンドを判定不能の deny にする" ;;
  *) bad "C8: ASDD 検証不能が素通しになった: exit=$RC out=[$OUT]" ;;
esac
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

# ---- 述語 D / P（Issue `#2450` / `#2496`）の回避形行列 -------------------------------------
# 各ケースは引用付き heredoc から読むので、suite のシェルはバックスラッシュ・バッククォートを解釈しない
# （OBS-324。このファイルは Write / Edit で書き、保存バイトを od -c で確かめてある）。
# 軸（TESTING.md「コマンド文字列ガードの回避形行列」）: 引用（heredoc の区切り語の引用の 3 形・引用しない形 /
# PowerShell の二重引用符・単一引用符・ヒアストリング 2 形）、文脈を決める語の変形（引用したコマンド名・パス付き・
# .exe・大文字・env 前置・-Command の短縮形・値を取るオプション）、区切りと構文（&& / ; / 単独 & / 継続行 /
# 入れ子の bash <<'EOF' と bash -c / データ行きの heredoc / コメント / 引数の中）、免除語（本文の中の ACK・先頭の ACK）。
# case パターンと [[ ]] の軸は、どちらもインタプリタ・pwsh の起動位置にならないので置かない。
# LW_ENV: hook へ渡す環境（述語 D は Claude Code のホストだけで発火するので D の節は CLAUDECODE=1 を渡す）
LW_ENV=()
lw_fire() { # <label>  (stdin: コマンド文字列)
  run_hook "$(cat)" ${LW_ENV[@]+"${LW_ENV[@]}"}
  assert_fire "$1"
}
lw_pass() { # <label>  (stdin: コマンド文字列)
  run_hook "$(cat)" ${LW_ENV[@]+"${LW_ENV[@]}"}
  assert_pass "$1"
}

echo "guard-literal-write: D 述語（インタプリタへ引用付き heredoc で渡すプログラムの二重バックスラッシュ）"
LW_ENV=(CLAUDECODE=1)
D_FIRE_PY="$(cat <<'CASE'
python3 - <<'PY'
open('f', 'w').write('a\\nb')
PY
CASE
)"
run_hook "$D_FIRE_PY" CLAUDECODE=1
assert_fire "DF1: python3 - <<'PY' の本文の \\\\n（確証した真陽性と同形）"
for needle in 'python' 'OBS-324' 'Write / Edit' 'リテラル書き込みの既定経路' 'FF_LITERAL_WRITE_ACK=1'; do
  case "$REASON" in
    *"$needle"*) ok "DF1 の停止文が [$needle] を含む" ;;
    *) bad "DF1 の停止文に [$needle] が無い: [$REASON]" ;;
  esac
done
lw_fire 'DF2: 区切り語を二重引用符で引用した heredoc（<<"PY"）の \\0' <<'CASE'
python - f <<"PY"
x = 'a\\0b'
PY
CASE
lw_fire 'DF3: 区切り語をバックスラッシュで引用した heredoc（<<\PY）の \\000' <<'CASE'
python3 - <<\PY
x = '\\000'
PY
CASE
lw_fire 'DF4: node - へ渡す heredoc の \\t' <<'CASE'
node - <<'EOF'
require('fs').writeFileSync('o', 'a\\tb')
EOF
CASE
lw_fire 'DF5: スクリプト引数の無い node へ渡す heredoc の \\x41' <<'CASE'
node <<'EOF'
const s = 'a\\x41'
EOF
CASE
lw_fire 'DF6: perl - へ渡す heredoc' <<'CASE'
perl - <<'EOF'
print "a\\nb"
EOF
CASE
lw_fire 'DF7: ruby - へ渡す heredoc' <<'CASE'
ruby - <<'RB'
puts 'a\\nb'
RB
CASE
lw_fire 'DF8: Windows の py ランチャー（py -3 -）' <<'CASE'
py -3 - <<'PY'
x = '\\n'
PY
CASE
lw_fire 'DF9: パス付き・.exe 付きのコマンド名' <<'CASE'
/c/Python311/python3.11.exe - <<'PY'
x = '\\n'
PY
CASE
lw_fire 'DF10: 引用したコマンド名（"python3"）' <<'CASE'
"python3" - <<'PY'
x = '\\n'
PY
CASE
lw_fire 'DF11: env 前置・値を取るオプション（-X utf8）・- の後ろのスクリプト引数' <<'CASE'
env PYTHONUTF8=1 python3 -X utf8 - "$ROOT" <<'PY'
x = '\\n'
PY
CASE
lw_fire 'DF12: 先行コマンド（&&）の後ろ' <<'CASE'
cd /tmp && python3 - <<'PY'
x = '\\n'
PY
CASE
lw_fire 'DF13: 単独の & の後ろ' <<'CASE'
true & python3 - <<'PY'
x = '\\n'
PY
CASE
lw_fire 'DF14: 継続行で分けた起動' <<'CASE'
python3 \
  - <<'PY'
x = '\\n'
PY
CASE
lw_fire "DF15: 入れ子の bash <<'EOF' の中の python heredoc" <<'CASE'
bash <<'EOF'
python3 - <<'PY'
x = '\\n'
PY
EOF
CASE
lw_fire 'DF16: タブを剥がす heredoc（<<-）' <<'CASE'
python3 - <<-'PY'
	x = '\\n'
	PY
CASE
lw_fire 'DF17: 本文の中の ACK の綴りは免除にならない' <<'CASE'
python3 - <<'PY'
# FF_LITERAL_WRITE_ACK=1
x = '\\n'
PY
CASE
lw_pass 'DN1: 引用しない heredoc（<<PY）は bash 自身も \\ を畳むので書き手の意図と届く値が変わらない' <<'CASE'
python3 - <<PY
x = '\\n'
PY
CASE
D_PASS_PY="$(cat <<'CASE'
python3 - <<'PY'
x = '\n'
y = '\\'
z = '\\.'
w = re.compile('^\\s*\\d+')
PY
CASE
)"
run_hook "$D_PASS_PY" CLAUDECODE=1
assert_pass 'DN2: 1 本のバックスラッシュの escape と、英数字が続かない \\ と、python が escape として読まない \\d / \\s は止めない'
lw_fire 'DF18: node は未知の escape（\\d）でもバックスラッシュを落とすので止める（python の DN2 と対照）' <<'CASE'
node - <<'EOF'
const r = new RegExp('^\\d+')
EOF
CASE
lw_pass 'DN3: -c でプログラムを渡したときの heredoc は標準入力のデータ' <<'CASE'
python3 -c 'import sys; sys.stdout.write(sys.stdin.read())' <<'PY'
x = '\\n'
PY
CASE
lw_pass 'DN4: データ行きの heredoc（cat > f.py。Write ツールと同じ効果）' <<'CASE'
cat > f.py <<'PY'
x = '\\n'
PY
CASE
lw_pass "DN5: bash <<'EOF' の本文の printf '\\\\134'（値を文字コードから組み立てる形）" <<'CASE'
bash <<'EOF'
printf '\\134'
EOF
CASE
lw_pass 'DN6: スクリプトファイルを実行するときの heredoc は標準入力のデータ' <<'CASE'
python3 script.py <<'PY'
x = '\\n'
PY
CASE
lw_pass 'DN7: -m のモジュールへ渡す heredoc は標準入力のデータ' <<'CASE'
python3 -m json.tool <<'PY'
{"a": "\\n"}
PY
CASE
lw_pass 'DN8: 引数・コメント・コミットメッセージの中の綴り' <<'CASE'
echo "python3 - <<PY \\n"
# python3 - <<'PY' \\n
git commit -m "python3 - <<'PY' \\n"
CASE
lw_pass 'DN9: 先頭の ACK で通る' <<'CASE'
FF_LITERAL_WRITE_ACK=1 python3 - <<'PY'
x = '\\n'
PY
CASE
D_FIRE_CATPIPE="$(cat <<'CASE'
cat <<'PY' | python3 -
print("a\\nb")
PY
CASE
)"
run_hook "$D_FIRE_CATPIPE" CLAUDECODE=1
assert_fire 'DF19: 引数なしの cat の引用付き heredoc をパイプで受けるインタプリタ（cat <<PY | python3 -）'
D_FIRE_DEVSTDIN="$(cat <<'CASE'
python3 /dev/stdin <<'PY'
print("a\\nb")
PY
CASE
)"
run_hook "$D_FIRE_DEVSTDIN" CLAUDECODE=1
assert_fire 'DF20: スクリプト引数が /dev/stdin のインタプリタへ渡す heredoc'
lw_fire 'DF21: パイプの受け側の node -（cat の heredoc）' <<'CASE'
cat <<'EOF' | node -
console.log('a\\tb')
EOF
CASE
lw_pass 'DN10: パイプの送り側が引数付きの cat（ファイルも読む）は heredoc の本文だけを読む形と断定できないので止めない' <<'CASE'
cat header.py - <<'PY' | python3 -
print("a\\nb")
PY
CASE
lw_pass 'DN11: パイプの受け側がスクリプトファイルを実行する（heredoc は標準入力のデータ）' <<'CASE'
cat <<'PY' | python3 script.py
print("a\\nb")
PY
CASE
lw_pass 'DN12: || の右（パイプではない）のインタプリタは cat の heredoc を受けない' <<'CASE'
cat <<'PY' || python3 -
print("a\\nb")
PY
CASE
run_hook "$D_FIRE_PY" -u CLAUDECODE
assert_pass 'DN13: Claude Code 以外のホスト（CLAUDECODE が無い）では述語 D を発火させない（\\ が縮むのは Claude Code の Bash ツール固有）'
run_hook "$D_FIRE_PY" CLAUDECODE=0
assert_pass 'DN14: CLAUDECODE が 1 以外でも発火させない'
RUN_EXTRA='{"model":"gpt-5"}' run_hook "$D_FIRE_PY" CLAUDECODE=1
assert_pass 'DN15: CLAUDECODE=1 を受け継いだ別ホスト（入力に model がある。Claude Code から起動した codex exec）では発火させない'
run_hook "$D_FIRE_PY" CLAUDECODE=1 GROK_PLUGIN_ROOT=/opt/grok
assert_pass 'DN16: grok root がある環境では CLAUDECODE=1 でも発火させない'
LW_ENV=()

echo "guard-literal-write: Q 述語（コマンド行の引数の二重バックスラッシュ）"
LW_ENV=(CLAUDECODE=1)
Q_FIRE_SQ="$(cat <<'CASE'
printf '%s' 'a\\b'
CASE
)"
run_hook "$Q_FIRE_SQ" CLAUDECODE=1
assert_fire 'QF1: 単一引用符の中の \\（Issue の AC の例。本来 a\\b の値が a\b で届く）'
for needle in '単一引用符の中' 'OBS-324' 'bash <そのファイル>' 'grep -f' 'FF_LITERAL_WRITE_ACK=1'; do
  case "$REASON" in
    *"$needle"*) ok "QF1 の停止文が [$needle] を含む" ;;
    *) bad "QF1 の停止文に [$needle] が無い: [$REASON]" ;;
  esac
done
lw_fire 'QF2: 二重引用符の中で \\ の次が \（Issue の AC の例。パターンの \\r が \r に変わる）' <<'CASE'
grep -iE "x|\\\\r|y" notes.md
CASE
lw_fire 'QF3: 引用の外の \\（本来 a\b の値が ab で届く）' <<'CASE'
printf '%s\n' a\\b
CASE
lw_fire 'QF4: case のパターンの \\（[A-Za-z]:\\* が [A-Za-z]:\* に変わり、絶対パスを相対と判定する）' <<'CASE'
case "$v" in [A-Za-z]:\\*) echo abs ;; *) echo rel ;; esac
CASE
lw_fire 'QF5: 二重引用符の中で \\ の次が $（本来は \ と展開、届くと $ のリテラル）' <<'CASE'
printf '%s\n' "a\\$HOME"
CASE
lw_fire 'QF6: ANSI-C 引用（$ + 単一引用符）の中で \\ の次がエスケープ文字（本来 \n の 2 文字、届くと改行）' <<'CASE'
printf '%s' $'a\\nb'
CASE
lw_fire 'QF7: && の後ろのコマンド・パイプの送り側' <<'CASE'
cd /tmp && grep -c 'a\\b' f.txt | tee n.txt
CASE
# Bash 3.2 は縮んだ末尾の単独 \ を捨て、Bash 5 は残す。
# どの Bash へ渡るかで値が変わる形は、Claude Code では版に依存せず止める。
lw_fire 'QF8: 引用の外の末尾の \\' <<'CASE'
printf '%s' end\\
CASE
lw_pass 'QN1: 二重引用符の中で \\ の次がふつうの文字（"D:\\data" は縮んでも bash が同じ D:\data を作る。Issue の例）' <<'CASE'
printf '%s\n' "D:\\data\\name\\project"
CASE
lw_pass 'QN2: 二重引用符の中の正規表現の \\.（縮んでも \. で同じ）' <<'CASE'
grep -E "foo\\.bar" f.txt
CASE
lw_pass 'QN3: 1 本のバックスラッシュ（縮む対象が無い）' <<'CASE'
printf '%s\n' 'a\b' "c\d" e\ f
CASE
lw_pass 'QN4: ANSI-C 引用（$ + 単一引用符）の中で \\ の次がエスケープ文字でない（\q は縮んでも \q）' <<'CASE'
printf '%s' $'a\\qb'
CASE
lw_pass 'QN6: ヒアドキュメントの本文（Q はコマンド行だけを読む。データ行きの本文は既知の限界）' <<'CASE'
cat > f.sh <<'EOF'
printf '%s' 'a\\b'
EOF
CASE
lw_pass 'QN7: コメントの中' <<'CASE'
ls  # 'a\\b'
CASE
lw_pass 'QN8: 先頭の ACK で通る' <<'CASE'
FF_LITERAL_WRITE_ACK=1 printf '%s' 'a\\b'
CASE
run_hook "$Q_FIRE_SQ" -u CLAUDECODE
assert_pass 'QN9: Claude Code 以外のホスト（CLAUDECODE が無い）では述語 Q を発火させない'
RUN_EXTRA='{"model":"gpt-5"}' run_hook "$Q_FIRE_SQ" CLAUDECODE=1
assert_pass 'QN10: CLAUDECODE=1 を受け継いだ別ホスト（入力に model がある）では発火させない'
# 入れ子の bash の本文は Q の対象外（トップレベルのコマンド行だけを読む）。bash -c "…" の本文は bash が引用を解いた
# 後の値でホストの解釈の前後と対応せず、bash <<'EOF' の本文にはホストの解釈を織り込んで書く形（DN5 の printf '\\134'）がある
Q_NEST_PASS="$(cat <<'CASE'
bash <<'EOF'
printf '%s' 'a\\b'
EOF
CASE
)"
run_hook "$Q_NEST_PASS" CLAUDECODE=1
assert_pass 'QN11: 入れ子の bash の本文の単一引用符の \\（Q はトップレベルのコマンド行だけを読む）'
lw_pass 'QN12: 引用の外で 3 本続いてふつうの文字が来る形（a\\\b は元も縮んだ後も a\b）' <<'CASE'
printf '%s' a\\\b
CASE
lw_pass 'QN13: ANSI-C 引用の中で \\x の後に 16 進の数字が無い形（縮んでも \xg のまま）' <<'CASE'
printf '%s' $'a\\xg'
CASE
# 前置判定は二重バックスラッシュを Claude Code の環境でだけ数える。ほかの理由（perl と $）で候補になった呼び出しの
# D・Q の検出は、後段のホストの絞り込みが落とす（M22 / M28 の入力）
D_HOST_MIX="$(cat <<'CASE'
perl -e 'print 1' "$X"; python3 - <<'PY'
x = '\\n'
PY
CASE
)"
Q_HOST_MIX="$(cat <<'CASE'
perl -e 'print 1' "$X"; printf '%s' 'a\\b'
CASE
)"
run_hook "$D_HOST_MIX" -u CLAUDECODE
assert_pass 'DN17: perl と $ で候補になった呼び出しでも、Claude Code 以外のホストでは述語 D を落とす'
run_hook "$Q_HOST_MIX" -u CLAUDECODE
assert_pass 'QN14: perl と $ で候補になった呼び出しでも、Claude Code 以外のホストでは述語 Q を落とす'
Q_UNTERMINATED="printf '%s' 'a\\\\b"
run_hook "$Q_UNTERMINATED" -u CLAUDECODE
assert_pass 'QC1: Claude Code 以外のホストでは、二重バックスラッシュだけの未終端コマンドを候補にしない（判定不能の deny の面を広げない）'
run_hook "$Q_UNTERMINATED" CLAUDECODE=1
assert_unavailable 'QC2: Claude Code 上では、二重バックスラッシュを含む未終端コマンドを判定不能の deny にする'
mkdir -p "$TEST_TMP/badjq-bin"
printf '#!/bin/sh\nexit 3\n' > "$TEST_TMP/badjq-bin/jq"
chmod +x "$TEST_TMP/badjq-bin/jq"
RUN_EXTRA='{"cwd":"D:\\data\\repo","transcript_path":"D:\\data\\t.jsonl"}' run_hook 'git status --short' CLAUDECODE=1 "PATH=$TEST_TMP/badjq-bin:$PATH"
assert_pass 'QN15: cwd・transcript_path のバックスラッシュ（生の入力で 2 本）だけでは候補にしない（壊れた jq でも素通し。前置判定は 4 本で探す）'
LW_ENV=()

echo "guard-literal-write: P 述語（pwsh / powershell の -Command の二重引用符の中のバッククォート）"
P_FIRE_CMD="$(cat <<'CASE'
pwsh -NoProfile -Command '$s = "| 版 | `b2821ed |"; (Get-Content f.md -Raw).Replace($s, "x")'
CASE
)"
run_hook "$P_FIRE_CMD"
assert_fire 'PF1: Markdown のインラインコードを含む二重引用符の置換文字列（導入先 OBS-037 と同形）'
for needle in 'PowerShell' 'OBS-037' "@'" 'ReadAllText' '-File' 'FF_LITERAL_WRITE_ACK=1'; do
  case "$REASON" in
    *"$needle"*) ok "PF1 の停止文が [$needle] を含む" ;;
    *) bad "PF1 の停止文に [$needle] が無い: [$REASON]" ;;
  esac
done
lw_fire 'PF2: -c（-Command の別名）' <<'CASE'
pwsh -c '"a`nb"'
CASE
lw_fire 'PF3: Windows PowerShell の -Command' <<'CASE'
powershell -Command 'Write-Host "x`0y"'
CASE
lw_fire 'PF4: .exe 付き・値を取るオプション（-ExecutionPolicy Bypass）の後ろ' <<'CASE'
pwsh.exe -NoProfile -ExecutionPolicy Bypass -Command '"`t"'
CASE
lw_fire 'PF5: Windows PowerShell の位置引数（-Command として読まれる）' <<'CASE'
powershell 'Write-Host "`e[31m"'
CASE
lw_fire 'PF6: 大文字のコマンド名・パラメーター名' <<'CASE'
PWSH -COMMAND '"`v"'
CASE
lw_fire 'PF7: -Command - へ渡す引用付き heredoc' <<'CASE'
pwsh -Command - <<'EOF'
$a = "x`by"
EOF
CASE
lw_fire 'PF8: 二重引用符のヒアストリング（@"…"@）' <<'CASE'
pwsh -Command '$a = @"
x`ry
"@'
CASE
lw_fire 'PF9: bash の二重引用符の中でエスケープしたバッククォート' <<'CASE'
pwsh -Command "Write-Host \"a\`nb\""
CASE
lw_fire 'PF10: 入れ子の bash -c の中' <<'CASE'
bash -c 'pwsh -c "\"x\`by\""'
CASE
lw_fire 'PF11: 二重引用符の中の "" の後ろ' <<'CASE'
pwsh -Command '"a""`fb"'
CASE
lw_fire 'PF12: env 前置と先行コマンド（&&）の後ろ・-Command の短縮形（-Com）' <<'CASE'
cd /tmp && env A=1 pwsh -Com '"`u{1F600}"'
CASE
lw_fire 'PF13: 引用したコマンド名・空白をエスケープしたパス' <<'CASE'
"pwsh" -c '"`r"'; /c/Program\ Files/PowerShell/7/pwsh -c '"`a"'
CASE
lw_fire 'PF14: 本文の中の ACK の綴りは免除にならない' <<'CASE'
pwsh -c '"`b"  # FF_LITERAL_WRITE_ACK=1'
CASE
lw_pass 'PN1: PowerShell の単一引用符の文字列の中（二重引用符を含んでもリテラル）' <<'CASE'
pwsh -Command 'Write-Host '"'"'say "x`by"'"'"''
CASE
lw_pass "PN2: 単一引用符のヒアストリング（@'…'@）" <<'CASE'
pwsh -Command '$a = @'"'"'
x`by
'"'"'@'
CASE
lw_pass 'PN3: -File で渡すスクリプト（引数は文字列として渡る）' <<'CASE'
pwsh -File script.ps1 '"`b"'
CASE
lw_pass 'PN4: pwsh の位置引数はスクリプトファイル' <<'CASE'
pwsh script.ps1 'x"`b"'
CASE
lw_pass 'PN5: -EncodedCommand' <<'CASE'
pwsh -EncodedCommand ZQBjAGgAbwA=
CASE
lw_pass 'PN6: エスケープ文字でないバッククォート（`` / `" / `$ / `q）' <<'CASE'
pwsh -Command '"a``b"; "a`"b"; "a`$b"; "a`qb"'
CASE
lw_pass 'PN7: 行コメント・ブロックコメントの中' <<'CASE'
pwsh -Command 'Get-Item x # "`b"
<# "`n" #> Get-Item y'
CASE
lw_pass 'PN8: 文字列の外のバッククォート（次の 1 文字をそのまま渡す）' <<'CASE'
pwsh -Command 'Write-Host `b'
CASE
lw_pass 'PN9: 引数・コミットメッセージの中の綴り' <<'CASE'
echo pwsh -c '"`b"'; git commit -m 'pwsh -c "`b"'
CASE
lw_pass 'PN10: 先頭の ACK で通る' <<'CASE'
FF_LITERAL_WRITE_ACK=1 pwsh -c '"`b"'
CASE
P_FIRE_SUB="$(cat <<'CASE'
pwsh -c 'Write-Host "$("`n")"'
CASE
)"
run_hook "$P_FIRE_SUB"
assert_fire 'PF15: 二重引用符の中の部分式 $( … ) の内側の二重引用符の文字列（内側の " で外側を閉じない）'
lw_fire 'PF16: 部分式の後ろに続く外側の文字列' <<'CASE'
pwsh -c 'Write-Host "$(Get-Date) `t done"'
CASE
lw_pass 'PN11: 部分式の中の単一引用符の文字列・部分式の外のエスケープでないバッククォート' <<'CASE'
pwsh -c 'Write-Host "$(Write-Output '"'"'`b'"'"') ``x"'
CASE

echo "guard-literal-write: D / P の性質を実処理系で確かめる"
if command -v python3 >/dev/null 2>&1; then
  # Bash ツールが \\ を \ に解釈した後の形（1 本の \n）は実改行になり、元の形（\\n）は 2 文字のまま。
  # ホストの解釈そのものは suite の中では起こせないので、解釈の前後の 2 形を python に渡して差を測る。
  d_after="$(python3 - <<'PY'
import sys
sys.stdout.write(str(len('a\nb')))
PY
)"
  d_before="$(python3 - <<'PY'
import sys
sys.stdout.write(str(len('a\\nb')))
PY
)"
  if [ "$d_after" = 3 ] && [ "$d_before" = 4 ]; then
    ok "DP1: 解釈後の '\\n' は 1 文字（実改行）、解釈前の '\\\\n' は 2 文字（述語 D の根拠）"
  else
    bad "DP1: after=[$d_after] before=[$d_before]"
  fi
else
  echo "  ○ skip: python3 が無いため DP1 は未検査"
fi
ps_exe=""
for c in pwsh powershell; do
  if command -v "$c" >/dev/null 2>&1; then ps_exe="$c"; break; fi
done
if [ -n "$ps_exe" ]; then
  p_dq="$("$ps_exe" -NoProfile -Command '[Console]::Out.Write("a`bc")' 2>/dev/null | od -An -tx1 | tr -d ' \n')" || p_dq=""
  p_sq="$("$ps_exe" -NoProfile -Command '[Console]::Out.Write('"'"'a`bc'"'"')' 2>/dev/null | od -An -tx1 | tr -d ' \n')" || p_sq=""
  if [ "$p_dq" = 610863 ] && [ "$p_sq" = 61606263 ]; then
    ok "PP1: ${ps_exe} の二重引用符の \`b はバックスペース（0x08）、単一引用符の中はリテラル（述語 P の根拠）"
  else
    bad "PP1: ${ps_exe}: dq=[$p_dq] sq=[$p_sq]"
  fi
else
  echo "  ○ skip: pwsh / powershell が無いため PP1 は未検査"
fi
# 述語 Q: ホストの解釈（\\ → \）は suite の中では起こせないので、置換で再現した後の形と元の形を bash で実行して
# 出力を比べる。止める形は出力が変わり、止めない形は変わらないこと（述語の根拠）と、hook の判定が揃うことを見る
q_collapse() { # <コマンド文字列（1 行）> → \\ を左から順に \ へ縮めた形（パラメータ展開の置換は bash 3.2 で引用の扱いが違うので sed）
  printf '%s' "$1" | sed 's/\\\\/\\/g'
}
q_out() { # <コマンド文字列> → 実行した出力の 16 進
  bash -c "$1" </dev/null 2>/dev/null | od -An -tx1 | tr -d ' \n'
}
qp_check() { # <label> <changed|same> <want_decision>（stdin: 1 行 1 コマンド）
  local label="$1" want="$2" wantd="$3" qc before after good=1 n=0
  while IFS= read -r qc; do
    [ -n "$qc" ] || continue
    n=$((n + 1))
    before="$(q_out "$qc")" || before="ERR"
    after="$(q_out "$(q_collapse "$qc")")" || after="ERR"
    run_hook "$qc" CLAUDECODE=1
    if [ "$want" = changed ] && [ "$before" != "$after" ] && [ "$DECISION" = "$wantd" ]; then continue; fi
    if [ "$want" = same ] && [ "$before" = "$after" ] && [ "$DECISION" = "$wantd" ]; then continue; fi
    good=0
    bad "${label}: [$qc] 元=[$before] 縮めた後=[$after] decision=[$DECISION]"
  done
  [ "$good" -eq 0 ] || ok "${label}（${n} 形）"
}
qp_check 'QP1: 述語 Q が止める形は、\\ を \ に縮めると bash の出力が変わる' changed deny <<'CASE'
printf '%s' 'a\\b'
printf '%s' a\\b
printf '%s' "a\\\\b"
printf '%s' "a\\$NO_SUCH_VAR_FOR_QP"
printf '%s' $'a\\nb'
printf '%s' $'a\\x41b'
CASE
qp_check 'QP2: 述語 Q が止めない二重バックスラッシュの形は、縮めても bash の出力が変わらない' same "" <<'CASE'
printf '%s' "D:\\data\\name"
printf '%s' "foo\\.bar"
printf '%s' $'a\\qb'
printf '%s' a\\\b
printf '%s' $'a\\xg'
CASE

echo "guard-literal-write: D / P の変異検出"
MUTDP="$TEST_TMP/mutdp"
make_tree "$MUTDP"
mutate_dp() { # <sed-script> <label>
  sed "$1" "$SCAN_LIB" > "$MUTDP/tests/lib/literal-write-scan.sh"
  if cmp -s "$SCAN_LIB" "$MUTDP/tests/lib/literal-write-scan.sh"; then
    bad "$2: sed が当たらず変異が注入されていない（針が古い）"
    return 1
  fi
  return 0
}
if mutate_dp 's/^function rule_d(body, lang,   s) {$/function rule_d(body, lang,   s) { return/' M14; then
  run_on "$MUTDP/hooks/guard-literal-write.sh" "$D_FIRE_PY" CLAUDECODE=1
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "M14: 述語 D の判定を空にした変異は DF1 を素通しし、D の検査が赤になる"; else bad "M14: 変異が効いていない: decision=[$DECISION]"; fi
fi
if mutate_dp '/hraw\[pcmd\[k\]\] = hraw/d' M15; then
  run_on "$MUTDP/hooks/guard-literal-write.sh" "$D_FIRE_PY" CLAUDECODE=1
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "M15: 引用付き heredoc の原文を残さない変異は DF1 を素通しし、D の検査が赤になる"; else bad "M15: 変異が効いていない: decision=[$DECISION]"; fi
fi
if mutate_dp 's/0-7abfnrtvxNuU/0-9A-Za-z/' M19; then
  run_on "$MUTDP/hooks/guard-literal-write.sh" "$D_PASS_PY" CLAUDECODE=1
  if [ "$DECISION" = "deny" ]; then ok "M19: python の escape 文字の絞り込みを外した変異は DN2（\\\\d / \\\\s）を deny し、D の検査が赤になる"; else bad "M19: 変異が効いていない: out=[$OUT]"; fi
fi
if mutate_dp 's/ps_hit(nx);/k = k;/' M16; then
  run_on "$MUTDP/hooks/guard-literal-write.sh" "$P_FIRE_CMD"
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "M16: 述語 P の検出を消した変異は PF1 を素通しし、P の検査が赤になる"; else bad "M16: 変異が効いていない: decision=[$DECISION]"; fi
fi
P_PASS_SQ="$(cat <<'CASE'
pwsh -Command 'Write-Host '"'"'say "x`by"'"'"''
CASE
)"
if mutate_dp '/while (k <= m) { if (substr(p, k, 1) == sq)/d' M17; then
  run_on "$MUTDP/hooks/guard-literal-write.sh" "$P_PASS_SQ"
  if [ "$DECISION" = "deny" ]; then ok "M17: PowerShell の単一引用符を読み飛ばさない変異は PN1 を deny し、P の検査が赤になる"; else bad "M17: 変異が効いていない: out=[$OUT]"; fi
fi
cp "$SCAN_LIB" "$MUTDP/tests/lib/literal-write-scan.sh"
sed 's/^    \*\[Pp\]\[Ww\]\[Ss\]\[Hh\]\* | /    *NO_SUCH_SPELLING_X* | /' "$TARGET" > "$MUTDP/hooks/guard-literal-write.sh"
if cmp -s "$TARGET" "$MUTDP/hooks/guard-literal-write.sh"; then
  bad "M18: sed が当たらず変異が注入されていない（針が古い）"
else
  run_on "$MUTDP/hooks/guard-literal-write.sh" "$P_FIRE_CMD"
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "M18: hook の前置フィルタから pwsh を外した変異は PF1 を素通しし、P の検査が赤になる（前置フィルタも針の一部）"; else bad "M18: 変異が効いていない: decision=[$DECISION]"; fi
fi
sed 's/^if \[ "$d_host" != 1 \]; then$/if false; then/' "$TARGET" > "$MUTDP/hooks/guard-literal-write.sh"
if cmp -s "$TARGET" "$MUTDP/hooks/guard-literal-write.sh"; then
  bad "M22: sed が当たらず変異が注入されていない（針が古い）"
else
  run_on "$MUTDP/hooks/guard-literal-write.sh" "$D_HOST_MIX" -u CLAUDECODE
  if [ "$DECISION" = "deny" ]; then ok "M22: Claude Code 以外のホストで述語 D を落とす分岐を消した変異は DN17 を deny し、D の検査が赤になる"; else bad "M22: 変異が効いていない: out=[$OUT]"; fi
fi
cp "$TARGET" "$MUTDP/hooks/guard-literal-write.sh"
sed 's/^if \[ -n "${GROK_PLUGIN_ROOT:-}" \] || ! printf/if false \&\& ! printf/' "$TARGET" > "$MUTDP/hooks/guard-literal-write.sh"
if cmp -s "$TARGET" "$MUTDP/hooks/guard-literal-write.sh"; then
  bad "M24: sed が当たらず変異が注入されていない（針が古い）"
else
  RUN_EXTRA='{"model":"gpt-5"}' run_on "$MUTDP/hooks/guard-literal-write.sh" "$D_FIRE_PY" CLAUDECODE=1
  if [ "$DECISION" = "deny" ]; then ok "M24: CLAUDECODE だけで Claude Code と決める変異は DN15 を deny し、D の検査が赤になる"; else bad "M24: 変異が効いていない: out=[$OUT]"; fi
fi
cp "$TARGET" "$MUTDP/hooks/guard-literal-write.sh"
if mutate_dp '/pfrom\[cur\] = pp; i++; continue }$/d' M20; then
  run_on "$MUTDP/hooks/guard-literal-write.sh" "$D_FIRE_CATPIPE" CLAUDECODE=1
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "M20: パイプの送り側を記録しない変異は DF19（cat <<PY | python3 -）を素通しし、D の検査が赤になる"; else bad "M20: 変異が効いていない: decision=[$DECISION]"; fi
fi
if mutate_dp 's/ || script == "\/dev\/stdin") d_stdin(id, lang)$/) d_stdin(id, lang)/' M23; then
  run_on "$MUTDP/hooks/guard-literal-write.sh" "$D_FIRE_DEVSTDIN" CLAUDECODE=1
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "M23: /dev/stdin をスクリプト引数として読まない変異は DF20 を素通しし、D の検査が赤になる"; else bad "M23: 変異が効いていない: decision=[$DECISION]"; fi
fi
if mutate_dp '/if (ch == "\$" \&\& nx == "(") { k = ps_sub(p, k + 2, m); continue }$/d' M21; then
  run_on "$MUTDP/hooks/guard-literal-write.sh" "$P_FIRE_SUB"
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "M21: 二重引用符の中の部分式を追わない変異は PF15 を素通しし、P の検査が赤になる"; else bad "M21: 変異が効いていない: decision=[$DECISION]"; fi
fi
if mutate_dp 's/if (k) q_hit("single", i + k)/if (0) k = k/' M25; then
  run_on "$MUTDP/hooks/guard-literal-write.sh" "$Q_FIRE_SQ" CLAUDECODE=1
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "M25: 単一引用符の中の \\\\ を見ない変異は QF1 を素通しし、Q の検査が赤になる"; else bad "M25: 変異が効いていない: decision=[$DECISION]"; fi
fi
if mutate_dp 's/if \[ "$depth" -gt 1 \]; then nflag=1; fi/nflag=""/' M26; then
  run_on "$MUTDP/hooks/guard-literal-write.sh" "$Q_NEST_PASS" CLAUDECODE=1
  if [ "$DECISION" = "deny" ]; then ok "M26: 入れ子の走査にも述語 Q を当てる変異は QN11 を deny し、Q の検査が赤になる"; else bad "M26: 変異が効いていない: out=[$OUT]"; fi
fi
Q_PASS_DQ="$(cat <<'CASE'
printf '%s\n' "D:\\data\\name\\project"
CASE
)"
if mutate_dp 's/^\( *\)if (nx == "\\\\") { k = substr(src, i + 2, 1); if .* q_hit("double", i) }$/\1if (nx == "\\\\") q_hit("double", i)/' M27; then
  run_on "$MUTDP/hooks/guard-literal-write.sh" "$Q_PASS_DQ" CLAUDECODE=1
  if [ "$DECISION" = "deny" ]; then ok 'M27: 二重引用符の中で次の文字を見ずに止める変異は QN1（"D:\\data"）を deny し、Q の検査が赤になる'; else bad "M27: 変異が効いていない: out=[$OUT]"; fi
fi
cp "$SCAN_LIB" "$MUTDP/tests/lib/literal-write-scan.sh"
sed 's/D"\(.\)"\* | Q"\(.\)"\*) continue ;;/D"\1"*) continue ;;/' "$TARGET" > "$MUTDP/hooks/guard-literal-write.sh"
if cmp -s "$TARGET" "$MUTDP/hooks/guard-literal-write.sh"; then
  bad "M28: sed が当たらず変異が注入されていない（針が古い）"
else
  run_on "$MUTDP/hooks/guard-literal-write.sh" "$Q_HOST_MIX" -u CLAUDECODE
  if [ "$DECISION" = "deny" ]; then ok "M28: Claude Code 以外のホストで述語 Q を落とさない変異は QN14 を deny し、Q の検査が赤になる"; else bad "M28: 変異が効いていない: out=[$OUT]"; fi
fi
sed 's/^is_candidate "\$input" .\{6\} || exit 0$/is_candidate "$input" NO_SUCH_SPELLING_Y || exit 0/' "$TARGET" > "$MUTDP/hooks/guard-literal-write.sh"
if cmp -s "$TARGET" "$MUTDP/hooks/guard-literal-write.sh"; then
  bad "M29: sed が当たらず変異が注入されていない（針が古い）"
else
  run_on "$MUTDP/hooks/guard-literal-write.sh" "$Q_FIRE_SQ" CLAUDECODE=1
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "M29: hook の前置フィルタから二重バックスラッシュを外した変異は QF1 を素通しし、Q の検査が赤になる（前置フィルタも針の一部）"; else bad "M29: 変異が効いていない: decision=[$DECISION]"; fi
fi
sed 's/^if \[ "${CLAUDECODE:-}" = 1 \] && \[ -z "${GROK_PLUGIN_ROOT:-}" \]; then bs_host=1; fi$/bs_host=1/' "$TARGET" > "$MUTDP/hooks/guard-literal-write.sh"
if cmp -s "$TARGET" "$MUTDP/hooks/guard-literal-write.sh"; then
  bad "M30: sed が当たらず変異が注入されていない（針が古い）"
else
  run_on "$MUTDP/hooks/guard-literal-write.sh" "$Q_UNTERMINATED" -u CLAUDECODE
  if [ "$DECISION" = "deny" ]; then ok "M30: 前置判定の二重バックスラッシュをホストで絞らない変異は QC1 を判定不能の deny にし、Q の検査が赤になる"; else bad "M30: 変異が効いていない: out=[$OUT]"; fi
fi
cp "$TARGET" "$MUTDP/hooks/guard-literal-write.sh"

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
if mutate_lib 's/) prog\[++np\] = hbody\[id\]$/) np = np/' M7; then
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
