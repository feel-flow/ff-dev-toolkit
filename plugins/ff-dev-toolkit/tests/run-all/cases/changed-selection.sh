# shellcheck shell=bash
# RUN_OUT / RUN_RC は source 元の verify.sh の expect_* が読む（このファイル単体では未使用に見える）
# shellcheck disable=SC2034
# case 47: 変更ベースの部分ゲート（FF_RUN_ALL_CHANGED。ADR-062）
#
# verify.sh から source される（ok / bad / expect_* / RUN_OUT / RUN_RC / RUNNER / TESTS_DIR を共有）。
# verify.sh 本体が 4,000 行を超えているため、新しいケース群は cases ファイルへ置く（ADR-057 決定 2）。
#
# 既定一覧の形でしか効かないので、case 39 と同じく SCRIPTS / REQUIRED_SUITES /
# MISS_PROBE_BASELINE を fixture の suite へ差し替えた複製ランナーを**隔離した一時 git
# リポジトリ**へ置く。配置は実物と同じくプラグインルートをリポジトリの下（plugins/ff）に置き、
# base コミットから 1 コミット進めた木で FF_RUN_ALL_CHANGED=<base> を回して、選択・根拠・
# 全件への倒れ方・記録を観測する。
#
# fixture の suite（プラグインルート = plugins/ff）:
#   chg-docs-probe     … docs/alpha.md と docs/delta.md を参照する
#   chg-script-probe   … scripts/beta.sh を参照する
#   chg-required-probe … docs/gamma.md を参照する（必須名簿の材料だけを持つ）
#   chg-tree-probe     … プラグインルートそのもの（plugins/ff）だけを参照する（ツリー全体の走査を模す）
#
# 変異検出（手動で撃った結果は ADR-062 を導入した PR の本文）:
#   - chg-docs-probe の fixture から docs/alpha.md の参照行を消すと、47-A の「選ばれる」側が赤
#     （参照の字面から導出していることの実測。対応表を持たないので、参照を消した suite は選択から漏れる）
#   - ff_changed_select の契約面照合を外すと 47-E の全件マーカーが名簿の全要素で赤
#   - 交差 0 件の分岐で `suites: selected=0` を出さないと 47-B が赤
#   - 祖先ディレクトリの token を捨てると 47-I が赤

echo ""
echo "== case 47: 変更ベースの部分ゲート（FF_RUN_ALL_CHANGED）=="

if ! command -v git >/dev/null 2>&1; then
  echo "  ○ skip: git が無いため変更ベースの部分ゲートの実測をスキップ（case 47 の検査は 1 件も実行していません）"
else
_chg_fx="$(mktemp -d "${TMPDIR:-/tmp}/ff-run-all-changed.XXXXXX" 2>/dev/null)" || _chg_fx=""
if [ -z "$_chg_fx" ] || [ ! -d "$_chg_fx" ]; then
  bad "case 47: 一時領域を作成できず、変更ベースの部分ゲートを実測できません"
else
_chg_repo="$_chg_fx/repo"
_chg_plug="$_chg_repo/plugins/ff"
_chg_rec="$_chg_fx/gate-record"
mkdir -p "$_chg_plug/tests/chg-docs-probe" "$_chg_plug/tests/chg-script-probe" \
  "$_chg_plug/tests/chg-required-probe" "$_chg_plug/tests/chg-tree-probe" "$_chg_plug/tests/lib" \
  "$_chg_plug/docs" "$_chg_plug/scripts" "$_chg_repo/other"

cat > "$_chg_plug/tests/chg-docs-probe/verify.sh" <<'PROBE'
#!/usr/bin/env bash
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ALPHA="$ROOT/docs/alpha.md"
DELTA="$ROOT/docs/delta.md"
echo "CHG-DOCS-PROBE-EXECUTED"
echo "CHG-DOCS-PROBE-ENV=${FF_RUN_ALL_CHANGED:-unset}"
exit 0
PROBE
cat > "$_chg_plug/tests/chg-script-probe/verify.sh" <<'PROBE'
#!/usr/bin/env bash
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BETA="$ROOT/scripts/beta.sh"
echo "CHG-SCRIPT-PROBE-EXECUTED"
exit 0
PROBE
# REQUIRED_SUITES を空にすると bash 3.2 の set -u で落ちるので 1 件残す（case 39 と同じ理由）。
cat > "$_chg_plug/tests/chg-required-probe/verify.sh" <<'PROBE'
#!/usr/bin/env bash
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GAMMA="$ROOT/docs/gamma.md"
if false; then
  echo "○ skip: 名簿掲載の材料（この分岐は実行されない）"
  exit 0
fi
echo "CHG-REQUIRED-PROBE-EXECUTED"
exit 0
PROBE
cat > "$_chg_plug/tests/chg-tree-probe/verify.sh" <<'PROBE'
#!/usr/bin/env bash
REPO_ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
TREE="$REPO_ROOT/plugins/ff"
echo "CHG-TREE-PROBE-EXECUTED"
exit 0
PROBE
chmod +x "$_chg_plug/tests/chg-docs-probe/verify.sh" "$_chg_plug/tests/chg-script-probe/verify.sh" \
  "$_chg_plug/tests/chg-required-probe/verify.sh" "$_chg_plug/tests/chg-tree-probe/verify.sh"
printf 'alpha\n' > "$_chg_plug/docs/alpha.md"
printf 'delta\n' > "$_chg_plug/docs/delta.md"
printf 'gamma\n' > "$_chg_plug/docs/gamma.md"
printf '#!/usr/bin/env bash\n' > "$_chg_plug/scripts/beta.sh"
printf 'unrelated\n' > "$_chg_repo/other/unrelated.txt"
printf '# lib\n' > "$_chg_plug/tests/lib/helper.sh"
cp "$TESTS_DIR/../scripts/record-gate-head.sh" "$_chg_plug/scripts/record-gate-head.sh"
awk '
  /^  SCRIPTS=\($/ {
    print
    print "    \"$SCRIPT_DIR/chg-docs-probe/verify.sh\""
    print "    \"$SCRIPT_DIR/chg-script-probe/verify.sh\""
    print "    \"$SCRIPT_DIR/chg-required-probe/verify.sh\""
    print "    \"$SCRIPT_DIR/chg-tree-probe/verify.sh\""
    in_scripts = 1
    next
  }
  in_scripts && /^  \)$/ { in_scripts = 0; print; next }
  in_scripts { next }
  /^REQUIRED_SUITES=\($/ { print; print "  chg-required-probe"; in_required = 1; next }
  in_required && /^\)$/ { in_required = 0; print; next }
  in_required { next }
  /^MISS_PROBE_BASELINE=\($/ {
    print
    print "  chg-docs-probe"
    print "  chg-script-probe"
    print "  chg-required-probe"
    print "  chg-tree-probe"
    in_baseline = 1
    next
  }
  in_baseline && /^\)$/ { in_baseline = 0; print; next }
  in_baseline { next }
  { print }
' "$RUNNER" > "$_chg_plug/tests/run-all.sh"
[ "$(grep -c '^  chg-tree-probe$' "$_chg_plug/tests/run-all.sh")" -eq 1 ] \
  || bad "case 47: 複製ランナーの名簿差し替えが適用されていない（見出し行の改稿で awk が空振り）"

# 契約面の名簿は実装（run-all.sh の配列）から読む。ここへ書き写すと、名簿へ足した要素が
# 検査されないまま残る（47-E が名簿の全要素を 1 つずつ当てる）。
_chg_list() { # <配列名>
  awk -v head="^$1=\\\\($" '
    $0 ~ head { on = 1; next }
    on && /^\)$/ { exit }
    on && match($0, /"[^"]+"/) { print substr($0, RSTART + 1, RLENGTH - 2) }
  ' "$RUNNER"
}
_chg_plugin_list="$(_chg_list CHANGED_FULL_PLUGIN_PATHS)"
_chg_repo_list="$(_chg_list CHANGED_FULL_REPO_PATHS)"

_chg_git() { git -c commit.gpgsign=false -c user.email=t@example.invalid -c user.name=T -c init.defaultBranch=main -C "$_chg_repo" "$@"; }
_chg_setup_rc=0
_chg_git init -q . >/dev/null 2>&1 || _chg_setup_rc=1
_chg_git add -A >/dev/null 2>&1 || _chg_setup_rc=1
_chg_git commit -qm base >/dev/null 2>&1 || _chg_setup_rc=1
_chg_base="$(_chg_git rev-parse HEAD 2>/dev/null)" || _chg_setup_rc=1
if [ "$_chg_setup_rc" -ne 0 ] || [ -z "$_chg_base" ]; then
  bad "case 47: fixture の git リポジトリを組めません（以降の検査は成立していません）"
else

# base から 1 コミット進めた木を作る。引数は木を変える sh 断片（fixture リポジトリのルートを cwd に
# して評価する）。前の場面の変更は base へ戻してから当てる。
_chg_step() { # <説明> <sh 断片>
  _chg_git reset -q --hard "$_chg_base" >/dev/null 2>&1
  _chg_git clean -qfd >/dev/null 2>&1
  (cd "$_chg_repo" && sh -c "$2") >/dev/null 2>&1 \
    || bad "case 47: 場面の変更を当てられない: $1"
  _chg_git add -A >/dev/null 2>&1
  _chg_git commit -qm "$1" >/dev/null 2>&1 || bad "case 47: 場面の変更をコミットできない: $1"
}
# 複製ランナーを引数なしで回す。モード変数と ALLOW_SKIP は常に落とし、呼び出し側が "$@" で与える。
# 同梱 MCP の依存ガードは外す（契約面の mcp/package.json を置く場面で、依存の無い fixture が
# 起動前に止まらないように）。
_chg_run() {
  rm -f "$_chg_rec"
  if RUN_OUT="$(env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL -u FF_RUN_ALL_CHANGED \
    -u FF_RUN_ALL_ALLOW_SKIP -u FF_RUN_ALL_ALLOW_DIRTY "$@" FF_RUN_ALL_ALLOW_MISSING_MCP_DEPS=1 \
    FF_RUN_ALL_JOBS=1 FF_GATE_RECORD_FILE="$_chg_rec" bash "$_chg_plug/tests/run-all.sh" 2>&1)"; then RUN_RC=0; else RUN_RC=$?; fi
}
_chg_rec_has() { # <行> <検査名>
  if [ -f "$_chg_rec" ] && [ "$(grep -cxF -- "$1" "$_chg_rec")" -gt 0 ]; then ok "$2"; else bad "$2 — 記録に「$1」が無い"; fi
}

# 47-A: 参照されたファイルの変更 → それを参照する suite を選び、根拠を出す（プラグインルートを
# 参照する chg-tree-probe はプラグイン配下のすべての変更で選ばれる）
_chg_step "alpha を変える" "printf 'alpha2\\n' > plugins/ff/docs/alpha.md"
_chg_run FF_RUN_ALL_CHANGED="$_chg_base"
expect_rc 0 "47-A: 変更ベースの選択の実行が rc=0"
expect_has '^🎯 変更ベースの選択: base=' "47-A: 部分実行であることを実行の入口で名乗る"
expect_has '^suites: selected=2 registered=4$' "47-A: 選択件数と登録件数をサマリーへ出す"
expect_has '^🎯   chg-docs-probe ← plugins/ff/docs/alpha.md ← ' "47-A: 選んだ suite の根拠（変更パスと参照 token）を出す"
expect_has '^CHG-DOCS-PROBE-EXECUTED$' "47-A: docs/alpha.md を参照する suite が選ばれて実行される"
expect_lacks '^CHG-SCRIPT-PROBE-EXECUTED$' "47-A: 参照していない suite は実行しない"
expect_has '^CHG-DOCS-PROBE-ENV=unset$' "47-A: 選択の指定は suite へ継承させない（入れ子の run-all へ外側の選択が漏れない）"
expect_lacks '^🔎 全件実行' "47-A: 部分実行に全件マーカーを出さない"
expect_lacks '^All ff-dev-toolkit fixture checks passed\.$' "47-A: 部分実行は全体 pass を名乗らない"
_chg_rec_has 'STATUS=partial' "47-A: 鮮度記録は部分実行（partial）として書かれる"
_chg_rec_has 'MODE=changed' "47-A: 鮮度記録のモードは changed"
_chg_rec_has 'SUITES=chg-docs-probe chg-tree-probe' "47-A: 鮮度記録に通った suite だけを残す"

# 47-B: 交差 0 件 → suite は回さず、登録照合（メタ検査）だけを実行したことを selected=0 で明示する
_chg_step "無関係なファイルを変える" "printf 'x\\n' > other/unrelated.txt"
_chg_run FF_RUN_ALL_CHANGED="$_chg_base"
expect_rc 0 "47-B: 交差 0 件でも登録照合が通れば rc=0"
expect_has '^suites: selected=0 registered=4$' "47-B: 交差 0 件は suites: selected=0 を出す（空集合を全部通ったと読ませない）"
expect_has '^suites: total=0 run=0 passed=0 failed=0 skipped=0 not-run=0$' "47-B: サマリー行は 0 件のまま出る（未到達と区別できる）"
expect_has '既定 suite 一覧の登録漏れなし' "47-B: メタ検査（登録照合）は実行される"
expect_has '登録照合（メタ検査）だけ' "47-B: 何を実行したかを最終行で言う"
expect_lacks 'PROBE-EXECUTED$' "47-B: suite は 1 つも実行しない"

# 47-C: suite 自身のディレクトリの変更はその suite を選ぶ（スクリプト以外のファイルでも）
_chg_step "suite のディレクトリを変える" "printf 'note\\n' > plugins/ff/tests/chg-script-probe/notes.txt"
_chg_run FF_RUN_ALL_CHANGED="$_chg_base"
expect_rc 0 "47-C: suite 自身のディレクトリの変更の実行が rc=0"
expect_has '^🎯   chg-script-probe ← plugins/ff/tests/chg-script-probe/notes.txt ← suite 自身のディレクトリ$' "47-C: suite 自身のディレクトリの変更でその suite を選ぶ"
expect_lacks '^CHG-DOCS-PROBE-EXECUTED$' "47-C: 参照していない suite は選ばない"

# 47-D: 改名は旧パスでも選ぶ（削除 + 追加として数える）
_chg_step "alpha を改名する" "git mv plugins/ff/docs/alpha.md plugins/ff/docs/alpha-renamed.md"
_chg_run FF_RUN_ALL_CHANGED="$_chg_base"
expect_rc 0 "47-D: 改名の実行が rc=0"
expect_has '^🎯   chg-docs-probe ← plugins/ff/docs/alpha.md ← ' "47-D: 改名元のパスを参照する suite を選ぶ（旧パスを落とさない）"

# 47-E: 契約面に触れたら全件へ倒し、理由を出す。名簿（run-all.sh の 2 配列）の全要素を 1 つずつ
# 変更して確かめる（名簿から読んだ要素が 2 件未満なら空振りとして赤）。
_chg_e_n=0
_chg_e_first=1
for _chg_kind in PLUGIN REPO; do
  if [ "$_chg_kind" = PLUGIN ]; then _chg_elems="$_chg_plugin_list"; _chg_pre="plugins/ff/"; else _chg_elems="$_chg_repo_list"; _chg_pre=""; fi
  while IFS= read -r _chg_e; do
    [ -n "$_chg_e" ] || continue
    _chg_e_n=$((_chg_e_n + 1))
    case "$_chg_e" in
      */) _chg_p="${_chg_pre}${_chg_e}zz-probe.txt" ;;
      *) _chg_p="${_chg_pre}${_chg_e}" ;;
    esac
    _chg_step "契約面 ${_chg_e} を変える" "mkdir -p \"\$(dirname '$_chg_p')\" && printf '# probe\\n' >> '$_chg_p'"
    _chg_run FF_RUN_ALL_CHANGED="$_chg_base"
    expect_rc 0 "47-E: 契約面 ${_chg_e} の変更は全件実行で rc=0"
    expect_has '^🔎 全件実行: 登録されている 4 suite をすべて実行対象にします' "47-E: 契約面 ${_chg_e} の変更は全件実行へ倒れる"
    expect_has "^↪ 変更ベースの選択（FF_RUN_ALL_CHANGED）から全件実行へ倒しました: 契約面に触れる変更: ${_chg_p}（CHANGED_FULL_${_chg_kind}_PATHS の ${_chg_e}）" "47-E: 倒した理由（${_chg_p}）を実行の入口で出す"
    if [ "$_chg_e_first" = 1 ]; then
      _chg_e_first=0
      expect_has "^🎯 変更ベースの選択は全件実行へ倒れた（理由: 契約面に触れる変更: ${_chg_p}" "47-E: 倒した理由をサマリーにも出す"
      expect_lacks '^suites: selected=' "47-E: 全件へ倒した回は部分実行の件数行を出さない"
      _chg_rec_has 'MODE=full' "47-E: 全件へ倒した回の記録は full"
    fi
  done <<CHG_ELEMS
$_chg_elems
CHG_ELEMS
done
if [ "$_chg_e_n" -ge 2 ]; then
  ok "47-E: 契約面の名簿から ${_chg_e_n} 要素を読んで全件へ倒れることを確かめた"
else
  bad "47-E: 契約面の名簿を run-all.sh から読めない（${_chg_e_n} 要素。配列の書式変更で検査が空振りしている）"
fi

# 47-F: base を解決できない / 略記 1 の origin/HEAD が無い → 全件へ倒す（黙って 0 件にしない）
_chg_step "alpha を変える（base 解決）" "printf 'alpha3\\n' > plugins/ff/docs/alpha.md"
_chg_run FF_RUN_ALL_CHANGED=no-such-ref
expect_rc 0 "47-F: 解決できない base の実行が rc=0（全件が通る）"
expect_has '^↪ .*base をコミットへ解決できない: no-such-ref' "47-F: 解決できない base は全件へ倒す"
expect_has '^🔎 全件実行' "47-F: 解決できない base の回は全件マーカーを出す"
_chg_run FF_RUN_ALL_CHANGED=1
expect_rc 0 "47-F: origin/HEAD が無い略記 1 の実行が rc=0（全件が通る）"
expect_has '^↪ .*origin/HEAD が未設定' "47-F: 略記 1 で origin/HEAD が無ければ全件へ倒す"
_chg_git update-ref refs/remotes/origin/main "$_chg_base" >/dev/null 2>&1
_chg_git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main >/dev/null 2>&1
_chg_run FF_RUN_ALL_CHANGED=1
expect_rc 0 "47-F: 略記 1 の実行が rc=0"
expect_has '^🎯 変更ベースの選択: base=origin/main' "47-F: 略記 1 は origin/HEAD の指す先を base にする"
expect_has '^suites: selected=2 registered=4$' "47-F: 略記 1 でも同じ選択になる"
_chg_git symbolic-ref --delete refs/remotes/origin/HEAD >/dev/null 2>&1 || true
_chg_git update-ref -d refs/remotes/origin/main >/dev/null 2>&1 || true

# 47-G: FULL / FAST との同時指定・明示引数は既存の矛盾警告と同じ形で扱う
_chg_run FF_RUN_ALL_CHANGED="$_chg_base" FF_RUN_ALL_FULL=1
expect_rc 0 "47-G: FULL=1 との同時指定の実行が rc=0"
expect_has '^⚠️  FF_RUN_ALL_FULL=1 と FF_RUN_ALL_CHANGED が同時に指定されています（矛盾）' "47-G: FULL=1 との同時指定を 1 行警告する"
expect_has '^🔎 全件実行' "47-G: FULL=1 との矛盾は全件実行を採る"
_chg_run FF_RUN_ALL_CHANGED="$_chg_base" FF_RUN_ALL_FAST=1
expect_rc 0 "47-G: FAST=1 との同時指定の実行が rc=0"
expect_has '^⚠️  FF_RUN_ALL_FAST=1 と FF_RUN_ALL_CHANGED が同時に指定されています（矛盾）' "47-G: FAST=1 との同時指定を 1 行警告する"
expect_lacks '^suites: selected=' "47-G: FAST=1 との矛盾は除外の少ない高速モードを採る（部分選択しない）"
if RUN_OUT="$(env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL FF_RUN_ALL_CHANGED="$_chg_base" \
  FF_RUN_ALL_JOBS=1 FF_GATE_RECORD_FILE="$_chg_rec" bash "$_chg_plug/tests/run-all.sh" \
  "$_chg_plug/tests/chg-script-probe/verify.sh" 2>&1)"; then RUN_RC=0; else RUN_RC=$?; fi
expect_rc 0 "47-G: 明示引数の実行が rc=0"
expect_has '^⚠️  FF_RUN_ALL_CHANGED は既定一覧にだけ効きます' "47-G: 明示引数では無視することを 1 行警告する"
expect_has '^CHG-SCRIPT-PROBE-EXECUTED$' "47-G: 明示引数は名指しをそのまま実行する"

# 47-I: ルートの祖先ディレクトリ（プラグインルートそのもの）の token は、その配下のすべての変更と
# 交差する（ツリー全体を走査する suite を選択から落とさない）。
_chg_step "プラグイン直下に新しいファイルを置く" "printf 'new\\n' > plugins/ff/zz-new.txt"
_chg_run FF_RUN_ALL_CHANGED="$_chg_base"
expect_rc 0 "47-I: プラグイン直下の変更の実行が rc=0"
expect_has '^🎯   chg-tree-probe ← plugins/ff/zz-new.txt ← ' "47-I: プラグインルートを参照する suite は配下の変更で選ばれる"
expect_has '^suites: selected=1 registered=4$' "47-I: 祖先 token を持たない suite は選ばない"

# 47-J: FF_RUN_ALL_CHANGED の `0` と空値は未設定と同じ（quiet に既定の高速モード。FF_RUN_ALL_FULL=0 と
# 同じ規約）。解釈できない値は base として解決を試み、解決できなければ 47-F のとおり全件へ倒れる。
_chg_run
_chg_unset_out="$(printf '%s\n' "$RUN_OUT" | grep -E '^(suites: |⚡|🔎|🎯|↪|⚠️)' || true)"
for _chg_v in 0 ""; do
  _chg_run FF_RUN_ALL_CHANGED="$_chg_v"
  expect_rc 0 "47-J: FF_RUN_ALL_CHANGED='${_chg_v}' の実行が rc=0"
  if [ "$(printf '%s\n' "$RUN_OUT" | grep -E '^(suites: |⚡|🔎|🎯|↪|⚠️)' || true)" = "$_chg_unset_out" ] && [ -n "$_chg_unset_out" ]; then
    ok "47-J: FF_RUN_ALL_CHANGED='${_chg_v}' は未設定と同じ出力（モード行・警告・サマリー）"
  else
    bad "47-J: FF_RUN_ALL_CHANGED='${_chg_v}' が未設定と違う出力になる"
    dump_out
  fi
done

# 47-H: 参照を削った suite は選択から漏れる（対応表を持たない = 字面から導出している負の対照）。
# 参照が 1 つも残らない suite は「関係なし」ではなく常に選ぶ（導出の空振りを緑へ倒さない）。
_chg_git reset -q --hard "$_chg_base" >/dev/null 2>&1
_chg_docs_vs="$_chg_plug/tests/chg-docs-probe/verify.sh"
sed '/^ALPHA=/d' "$_chg_docs_vs" > "$_chg_docs_vs.new" && mv "$_chg_docs_vs.new" "$_chg_docs_vs" && chmod +x "$_chg_docs_vs" \
  || bad "case 47: 47-H の参照削除を当てられない"
_chg_git commit -qam "alpha の参照を削る" >/dev/null 2>&1 || bad "case 47: 47-H の base をコミットできない"
_chg_base_h="$(_chg_git rev-parse HEAD 2>/dev/null)"
printf 'alpha4\n' > "$_chg_plug/docs/alpha.md"
_chg_git commit -qam "alpha を変える（参照削除後）" >/dev/null 2>&1 || bad "case 47: 47-H の変更をコミットできない"
_chg_run FF_RUN_ALL_CHANGED="$_chg_base_h"
expect_rc 0 "47-H: 参照削除後の実行が rc=0"
expect_lacks '^CHG-DOCS-PROBE-EXECUTED$' "47-H: 参照を削った suite は同じ変更でも選ばれない"
expect_has '^suites: selected=1 registered=4$' "47-H: 選ばれるのはプラグインルートを参照する suite だけ"
_chg_git reset -q --hard "$_chg_base_h" >/dev/null 2>&1
sed '/^DELTA=/d' "$_chg_docs_vs" > "$_chg_docs_vs.new" && mv "$_chg_docs_vs.new" "$_chg_docs_vs" && chmod +x "$_chg_docs_vs" \
  || bad "case 47: 47-H の参照削除（2 本目）を当てられない"
_chg_git commit -qam "参照を全部削る" >/dev/null 2>&1 || bad "case 47: 47-H の base（2 本目）をコミットできない"
_chg_base_h2="$(_chg_git rev-parse HEAD 2>/dev/null)"
printf 'y\n' > "$_chg_repo/other/unrelated.txt"
_chg_git commit -qam "無関係な変更（参照 0 本の suite）" >/dev/null 2>&1 || bad "case 47: 47-H の変更（2 本目）をコミットできない"
_chg_run FF_RUN_ALL_CHANGED="$_chg_base_h2"
expect_rc 0 "47-H: 参照 0 本の suite を含む実行が rc=0"
expect_has '^🎯   chg-docs-probe ← 参照パスを 1 つも導出できない（fail-safe で常に選ぶ）$' "47-H: 参照を 1 つも導出できない suite は常に選ぶ"
expect_has '^CHG-DOCS-PROBE-EXECUTED$' "47-H: 参照 0 本の suite は無関係な変更でも実行される"
fi
rm -rf "$_chg_fx"
fi
fi
