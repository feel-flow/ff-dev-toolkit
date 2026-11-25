# shellcheck shell=bash
# RUN_OUT / RUN_RC は source 元の verify.sh の expect_* が読む（このファイル単体では未使用に見える）
# shellcheck disable=SC2034
# case 47: 変更ベースの部分ゲート（FF_RUN_ALL_CHANGED。ADR-062）
#
# verify.sh から source される（ok / bad / expect_* / RUN_OUT / RUN_RC / RUNNER / TESTS_DIR を共有）。
# 追加時点で verify.sh 本体が 4,000 行を超えていたため、新しいケース群として cases ファイルへ置いた
# （ADR-057 決定 2。その後 Issue `#1805` で case 35 も切り出して本体は 4,000 行未満に戻した）。
#
# 既定一覧の形でしか効かないので、case 39 と同じく SCRIPTS / REQUIRED_SUITES /
# MISS_PROBE_BASELINE を fixture の suite へ差し替えた複製ランナーを**隔離した一時 git
# リポジトリ**へ置く。配置は実物と同じくプラグインルートをリポジトリの下（plugins/ff）に置き、
# base コミットから 1 コミット進めた木で FF_RUN_ALL_CHANGED=<base> を回して、選択・根拠・
# 全件への倒れ方・記録を観測する。
#
# fixture の suite（プラグインルート = plugins/ff）:
#   chg-docs-probe     … docs/alpha.md と docs/delta.md を参照する
#   chg-script-probe   … scripts/beta.sh と scripts/multi-agent.sh を参照する（後者は 47-K の
#                        「構成ファイルの変更を入口の変更として交差させる」規則の対象）
#   chg-required-probe … docs/gamma.md を参照する（必須名簿の材料だけを持つ）
#   chg-tree-probe     … プラグインルートそのもの（plugins/ff）だけを参照する（ツリー全体の走査を模す）
#
# 変異検出（手動で撃った結果は ADR-062 を導入した PR の本文）:
#   - chg-docs-probe の fixture から docs/alpha.md の参照行を消すと、47-A の「選ばれる」側が赤
#     （参照の字面から導出していることの実測。対応表を持たないので、参照を消した suite は選択から漏れる）
#   - ff_changed_select の契約面照合を外すと 47-E の全件マーカーが名簿の全要素で赤
#   - 交差 0 件の分岐で `suites: selected=0` を出さないと 47-B が赤
#   - 祖先ディレクトリの token を捨てると 47-I が赤
#
# 文書契約面と選択に入れない suite（47-M〜47-S。ADR-095）の変異検出は、ランナーの写しへ変異を 1 つずつ当て、このファイル
# だけを回して測る。変異の一覧と実測の件数は verify.sh ヘッダの `# 空振り検出:` 行（case 47-M〜47-S）に
# 置く（件数をここへ書き写さない）。

echo ""
echo "== case 47: 変更ベースの部分ゲート（FF_RUN_ALL_CHANGED）=="

if ! command -v git >/dev/null 2>&1; then
  echo "  ○ skip: git が無いため変更ベースの部分ゲートの実測をスキップ（case 47 の検査は 1 件も実行していません）"
else
_chg_ready=0
if _chg_fx="$(mktemp -d "${TMPDIR:-/tmp}/ff-run-all-changed.XXXXXX" 2>&1)" && [ -d "$_chg_fx" ]; then
  _chg_ready=1
fi
if [ "$_chg_ready" -ne 1 ]; then
  bad "case 47: 一時領域を作成できず、変更ベースの部分ゲートを実測できません（mktemp: ${_chg_fx}）"
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
# 47-T: 鮮度だけの赤を起こす（行頭の鮮度マーカー + 非 0。復旧手段は書かない。ここにパスの字面を
# 書くと参照として導出され、参照 0 本を前提にする 47-H が崩れる）
if [ "${CHG_FORCE_STALE:-}" = 1 ]; then
  echo "✗ 鮮度: base が先行しているため疑似判定が成立しません（変更起因の赤ではありません）" >&2
  exit 1
fi
exit 0
PROBE
cat > "$_chg_plug/tests/chg-script-probe/verify.sh" <<'PROBE'
#!/usr/bin/env bash
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BETA="$ROOT/scripts/beta.sh"
ENTRY="$ROOT/scripts/multi-agent.sh"
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
# 47-U: 必須 suite の環境都合の skip を起こす
if [ "${CHG_FORCE_SKIP:-}" = 1 ]; then
  echo "○ skip: 47-U の疑似的な環境都合"
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
# 選択の CLI（参照の導出・依存の宣言・source の逆引き。Issue `#3006`）。複製ランナーはこれを呼ぶ
mkdir -p "$_chg_plug/tests/changed-select"
cp "$TESTS_DIR/changed-select/select.sh" "$_chg_plug/tests/changed-select/select.sh"
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
  /^CHANGED_DOC_SUITES=\($/ { print; print "  \"chg-required-probe\""; in_bundle = 1; next }
  in_bundle && /^\)$/ { in_bundle = 0; print; next }
  in_bundle { next }
  { print }
' "$RUNNER" > "$_chg_plug/tests/run-all.sh"
[ "$(grep -c '^  chg-tree-probe$' "$_chg_plug/tests/run-all.sh")" -eq 1 ] \
  || bad "case 47: 複製ランナーの名簿差し替えが適用されていない（見出し行の改稿で awk が空振り）"
[ "$(grep -c '^  "chg-required-probe"$' "$_chg_plug/tests/run-all.sh")" -eq 1 ] \
  || bad "case 47: 複製ランナーの文書横断 suite の束の差し替えが適用されていない（CHANGED_DOC_SUITES の書式変更で awk が空振り）"

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
_chg_doc_plugin_list="$(_chg_list CHANGED_DOC_PLUGIN_PATHS)"
_chg_doc_repo_list="$(_chg_list CHANGED_DOC_REPO_PATHS)"
_chg_doc_suites="$(_chg_list CHANGED_DOC_SUITES)"

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
    -u FF_RUN_ALL_ALLOW_SKIP -u FF_RUN_ALL_ALLOW_DIRTY -u FF_RELEASE_GATE_HEAD "$@" FF_RUN_ALL_ALLOW_MISSING_MCP_DEPS=1 \
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
_chg_rec_has "COVERS_DIFF=${_chg_base}" "47-A: 実行基盤の契約面に非該当かつ skip 0 件の pass では解決済み base SHA を COVERS_DIFF に残す（ADR-094）"
expect_lacks '^CHG-REQUIRED-PROBE-EXECUTED$' "47-A: 文書契約面に触れない変更では文書横断 suite の束を足さない（陰性対照）"
expect_lacks '^doc-contract: ' "47-A: 文書契約面に触れない変更では束の件数行を出さない"

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
    expect_has "^↪ 変更ベースの選択（FF_RUN_ALL_CHANGED）から全件実行へ倒しました: 実行基盤の契約面に触れる変更: ${_chg_p}（CHANGED_FULL_${_chg_kind}_PATHS の ${_chg_e}）" "47-E: 倒した理由（${_chg_p}）を実行の入口で出す"
    if [ "$_chg_e_first" = 1 ]; then
      _chg_e_first=0
      expect_has "^🎯 変更ベースの選択は全件実行へ倒れた（理由: 実行基盤の契約面に触れる変更: ${_chg_p}" "47-E: 倒した理由をサマリーにも出す"
      expect_lacks '^suites: selected=' "47-E: 全件へ倒した回は部分実行の件数行を出さない"
      _chg_rec_has 'MODE=full' "47-E: 全件へ倒した回の記録は full"
      _chg_rec_has 'COVERS_DIFF=' "47-E: 全件へ倒した回は COVERS_DIFF を空にする"
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

# 47-K: multi-agent.sh の構成ファイル（scripts/lib/multi-agent-*.sh。ADR-075）の変更は入口
# scripts/multi-agent.sh の変更としても交差し、入口を参照する suite を選ぶ。根拠には実際に
# 変わった構成ファイルを出す。構成ファイルではない scripts/lib の変更は入口として扱わない。
_chg_step "構成ファイルを変える" "mkdir -p plugins/ff/scripts/lib && printf '# part\\n' > plugins/ff/scripts/lib/multi-agent-zz.sh"
_chg_run FF_RUN_ALL_CHANGED="$_chg_base"
expect_rc 0 "47-K: 構成ファイルの変更の実行が rc=0"
expect_has '^🎯   chg-script-probe ← plugins/ff/scripts/lib/multi-agent-zz.sh（multi-agent.sh の構成ファイル。入口の変更として交差） ← ' "47-K: 構成ファイルの変更で入口を参照する suite を選び、変わった構成ファイルを根拠に出す"
expect_has '^CHG-SCRIPT-PROBE-EXECUTED$' "47-K: 入口を参照する suite が実行される"
_chg_step "構成ファイルではない lib を変える" "mkdir -p plugins/ff/scripts/lib && printf '# lib\\n' > plugins/ff/scripts/lib/other-zz.sh"
_chg_run FF_RUN_ALL_CHANGED="$_chg_base"
expect_rc 0 "47-K: 構成ファイルではない lib の変更の実行が rc=0"
expect_lacks '^CHG-SCRIPT-PROBE-EXECUTED$' "47-K: 構成ファイルではない scripts/lib の変更は入口の変更として扱わない"
_chg_step "入口と構成ファイルを同時に変える" "mkdir -p plugins/ff/scripts/lib && printf '# part\\n' > plugins/ff/scripts/lib/multi-agent-zz.sh && printf '# entry\\n' > plugins/ff/scripts/multi-agent.sh"
_chg_run FF_RUN_ALL_CHANGED="$_chg_base"
expect_rc 0 "47-K: 入口と構成ファイルを同時に変えた実行が rc=0"
expect_has '^🎯   chg-script-probe ← plugins/ff/scripts/multi-agent.sh ← ' "47-K: 入口も変わった回は根拠に入口そのものを出す"
expect_lacks '入口の変更として交差' "47-K: 入口も変わった回は構成ファイルの注記を付けない"

# 47-J: FF_RUN_ALL_CHANGED の `0` と空値は未設定と同じ（quiet に既定の高速モード。FF_RUN_ALL_FULL=0 と
# 同じ規約）。解釈できない値は base として解決を試み、解決できなければ 47-F のとおり全件へ倒れる。
_chg_run
_chg_unset_out="$(printf '%s\n' "$RUN_OUT" | grep -E '^(suites: |⚡|🔎|🎯|↪|⚠️)' | sed '/^⚠️  起動時の負荷:/d' || true)"
for _chg_v in 0 ""; do
  _chg_run FF_RUN_ALL_CHANGED="$_chg_v"
  expect_rc 0 "47-J: FF_RUN_ALL_CHANGED='${_chg_v}' の実行が rc=0"
  if [ "$(printf '%s\n' "$RUN_OUT" | grep -E '^(suites: |⚡|🔎|🎯|↪|⚠️)' | sed '/^⚠️  起動時の負荷:/d' || true)" = "$_chg_unset_out" ] && [ -n "$_chg_unset_out" ]; then
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

# 47-L: COVERS_DIFF の fail-closed と check-merge-freshness.sh との結合確認（ADR-094）
# (1) クリーン通過（skip 0 件）の記録を check-merge-freshness.sh へ渡すと、一致する base SHA では
#     DIFF_COVERED=yes を返し、異なる base SHA では DIFF_COVERED=yes を出さない
# (2) 選択された suite のうち 1 件でも suite-level skip を出した回は、pass 扱いでも COVERS_DIFF=
#     を空にする（skip 混入の部分実行で差分被覆を名乗らない）
_chg_git reset -q --hard "$_chg_base" >/dev/null 2>&1
_chg_git clean -qfd >/dev/null 2>&1
_chg_step "alpha を変える（47-L COVERS_DIFF 結合）" "printf 'alpha-l\\n' > plugins/ff/docs/alpha.md"
_chg_run FF_RUN_ALL_CHANGED="$_chg_base"
expect_rc 0 "47-L: クリーン通過の実行が rc=0"
_chg_rec_has "COVERS_DIFF=${_chg_base}" "47-L: クリーン通過の記録に COVERS_DIFF=<base SHA> が書かれる"
_chg_head_l="$(_chg_git rev-parse HEAD 2>/dev/null)"
_chg_fresh_rc=0
_chg_fresh_out="$(cd "$_chg_repo" && env -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT FF_DEV_TOOLKIT_ROOT="$TESTS_DIR/.." bash "$TESTS_DIR/../scripts/check-merge-freshness.sh" \
  --record "$_chg_rec" --remote-head "$_chg_head_l" --base "$_chg_base" 2>&1)" || _chg_fresh_rc=$?
if [ "$_chg_fresh_rc" -eq 2 ] && printf '%s\n' "$_chg_fresh_out" | grep -xF 'DIFF_COVERED=yes' >/dev/null; then
  ok "47-L: 一致する --base での鮮度照合は exit 2 かつ DIFF_COVERED=yes を返す"
else
  bad "47-L: 一致する --base での鮮度照合が期待外（rc=${_chg_fresh_rc}）: ${_chg_fresh_out}"
fi
_chg_other_base="0000000000000000000000000000000000000000"
_chg_fresh_rc2=0
_chg_fresh_out2="$(cd "$_chg_repo" && env -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT FF_DEV_TOOLKIT_ROOT="$TESTS_DIR/.." bash "$TESTS_DIR/../scripts/check-merge-freshness.sh" \
  --record "$_chg_rec" --remote-head "$_chg_head_l" --base "$_chg_other_base" 2>&1)" || _chg_fresh_rc2=$?
if [ "$_chg_fresh_rc2" -eq 2 ] && ! printf '%s\n' "$_chg_fresh_out2" | grep -xF 'DIFF_COVERED=yes' >/dev/null; then
  ok "47-L: 異なる --base での鮮度照合は DIFF_COVERED=yes を返さない（古い base の記録で通さない）"
else
  bad "47-L: 異なる --base での鮮度照合が被覆扱いになった（rc=${_chg_fresh_rc2}）: ${_chg_fresh_out2}"
fi
# skip 混入時の fail-closed: chg-docs-probe が skip を返すよう一時差し替えてコミットし直す
_chg_git reset -q --hard "$_chg_base" >/dev/null 2>&1
cat > "$_chg_plug/tests/chg-docs-probe/verify.sh" <<'PROBE_SKIP'
#!/usr/bin/env bash
# run-all-required: no — 47-L の skip 混入 fail-closed 検査用の任意 suite
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ALPHA="$ROOT/docs/alpha.md"
echo "○ skip: 47-L skip 混入テスト"
exit 0
PROBE_SKIP
chmod +x "$_chg_plug/tests/chg-docs-probe/verify.sh"
printf 'alpha-skip\n' > "$_chg_plug/docs/alpha.md"
_chg_git add -A >/dev/null 2>&1
_chg_git commit -qm "47-L skip 混入" >/dev/null 2>&1 || bad "case 47: 47-L skip 混入をコミットできない"
_chg_run FF_RUN_ALL_CHANGED="$_chg_base"
expect_rc 0 "47-L: 任意 suite の skip 混入自体は rc=0"
_chg_rec_has 'STATUS=partial' "47-L: skip 混入時も記録は partial"
_chg_rec_has 'COVERS_DIFF=' "47-L: skip が 1 件でも混入した部分実行は COVERS_DIFF を空にする（fail-closed）"

# 47-M: 文書契約面（配布テンプレート配下の文書・root の 2 入口）だけの変更は全件へ倒さず、字面の交差に
# 文書横断 suite の束を足して実行し、クリーン通過なら COVERS_DIFF を残す（ADR-095）。名簿
# （run-all.sh の 2 配列）の全要素を 1 つずつ変更して確かめる。fixture の束は chg-required-probe
# 1 件で、この suite は docs/gamma.md しか参照しないので、選ばれるのは束として足された回だけ。
_chg_m_n=0
_chg_m_first=1
for _chg_kind in PLUGIN REPO; do
  if [ "$_chg_kind" = PLUGIN ]; then
    _chg_elems="$_chg_doc_plugin_list"; _chg_pre="plugins/ff/"; _chg_m_sel=2
  else
    _chg_elems="$_chg_doc_repo_list"; _chg_pre=""; _chg_m_sel=1
  fi
  while IFS= read -r _chg_e; do
    [ -n "$_chg_e" ] || continue
    _chg_m_n=$((_chg_m_n + 1))
    case "$_chg_e" in
      */) _chg_p="${_chg_pre}${_chg_e}zz-doc-probe.md" ;;
      *) _chg_p="${_chg_pre}${_chg_e}" ;;
    esac
    _chg_step "文書契約面 ${_chg_e} を変える" "mkdir -p \"\$(dirname '$_chg_p')\" && printf '# probe\\n' >> '$_chg_p'"
    _chg_run FF_RUN_ALL_CHANGED="$_chg_base"
    expect_rc 0 "47-M: 文書契約面 ${_chg_e} だけの変更の実行が rc=0"
    expect_lacks '^🔎 全件実行' "47-M: 文書契約面 ${_chg_e} だけの変更は全件へ倒れない"
    expect_lacks '^↪ 変更ベースの選択' "47-M: 文書契約面 ${_chg_e} だけの変更は全件フォールバックの理由行を出さない"
    expect_has "^🎯 文書契約面に触れる変更: ${_chg_p}（CHANGED_DOC_${_chg_kind}_PATHS の ${_chg_e}） — 全件へは倒さず" "47-M: 文書契約面（${_chg_p}）であることと全件へ倒さないことを実行の入口で名乗る"
    expect_has "^🎯   chg-required-probe ← ${_chg_p}（CHANGED_DOC_${_chg_kind}_PATHS の ${_chg_e}） ← 文書横断 suite の束（CHANGED_DOC_SUITES）\$" "47-M: 束として足した suite の根拠に、文書契約面の変更パスと束を出す（${_chg_e}）"
    expect_has '^CHG-REQUIRED-PROBE-EXECUTED$' "47-M: 字面の交差に無い束の suite が実行される（${_chg_e}）"
    expect_lacks '^CHG-SCRIPT-PROBE-EXECUTED$' "47-M: 束にも交差にも無い suite は実行しない（${_chg_e}）"
    expect_has "^suites: selected=${_chg_m_sel} registered=4\$" "47-M: 選択は字面の交差 + 束（${_chg_e}: ${_chg_m_sel} 件）"
    expect_has '^doc-contract: bundle=1 added=1$' "47-M: 束の件数と、束として足した件数をサマリーへ出す（${_chg_e}）"
    _chg_rec_has 'STATUS=partial' "47-M: 文書契約面 ${_chg_e} の記録は部分実行（partial）"
    _chg_rec_has 'MODE=changed' "47-M: 文書契約面 ${_chg_e} の記録のモードは changed（full へ倒れていない）"
    _chg_rec_has "COVERS_DIFF=${_chg_base}" "47-M: 文書契約面 ${_chg_e} のクリーン通過は解決済み base SHA を COVERS_DIFF に残す"
    if [ "$_chg_m_first" = 1 ]; then
      _chg_m_first=0
      # finish.sh precheck が RERUN_FULL_GATE=no へ倒す入力（DIFF_COVERED=yes）になることを、
      # 鮮度照合の実物で確かめる（precheck 側の分岐は tests/finish が固定する）。
      _chg_head_m="$(_chg_git rev-parse HEAD 2>/dev/null)"
      _chg_fresh_rc=0
      _chg_fresh_out="$(cd "$_chg_repo" && env -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT FF_DEV_TOOLKIT_ROOT="$TESTS_DIR/.." bash "$TESTS_DIR/../scripts/check-merge-freshness.sh" \
        --record "$_chg_rec" --remote-head "$_chg_head_m" --base "$_chg_base" 2>&1)" || _chg_fresh_rc=$?
      if [ "$_chg_fresh_rc" -eq 2 ] && printf '%s\n' "$_chg_fresh_out" | grep -xF 'DIFF_COVERED=yes' >/dev/null; then
        ok "47-M: 文書契約面の記録を鮮度照合へ渡すと exit 2 かつ DIFF_COVERED=yes（precheck が全件の再実行を求めない入力）"
      else
        bad "47-M: 文書契約面の記録での鮮度照合が期待外（rc=${_chg_fresh_rc}）: ${_chg_fresh_out}"
      fi
    fi
  done <<CHG_DOC_ELEMS
$_chg_elems
CHG_DOC_ELEMS
done
if [ "$_chg_m_n" -ge 3 ]; then
  ok "47-M: 文書契約面の名簿から ${_chg_m_n} 要素を読んで、全件へ倒れず束が足されることを確かめた"
else
  bad "47-M: 文書契約面の名簿を run-all.sh から読めない（${_chg_m_n} 要素。配列の書式変更で検査が空振りしている）"
fi

# 47-N: 文書契約面と実行基盤の契約面を同時に変えた回は全件へ倒す。変更一覧の並びで文書が先に
# 来る組（docs-template → hooks）と後に来る組（.github → AGENTS.md）の両方で確かめる
# （文書契約面を見つけた時点で return する変異は、文書が先に来る組だけが赤にする）。
_chg_step "文書契約面と実行基盤の契約面を同時に変える（文書が先）" "mkdir -p plugins/ff/docs-template plugins/ff/hooks && printf '# d\\n' > plugins/ff/docs-template/zz-doc-probe.md && printf '{}\\n' > plugins/ff/hooks/hooks.json"
_chg_run FF_RUN_ALL_CHANGED="$_chg_base"
expect_rc 0 "47-N: 文書 + 実行基盤（文書が先）の実行が rc=0"
expect_has '^🔎 全件実行: 登録されている 4 suite をすべて実行対象にします' "47-N: 文書 + 実行基盤（文書が先）は全件へ倒れる"
expect_has '^↪ 変更ベースの選択（FF_RUN_ALL_CHANGED）から全件実行へ倒しました: 実行基盤の契約面に触れる変更: plugins/ff/hooks/hooks.json（CHANGED_FULL_PLUGIN_PATHS の hooks/hooks.json）' "47-N: 倒した理由に実行基盤側の変更を出す（文書が先）"
expect_lacks '^🎯 文書契約面に触れる変更' "47-N: 全件へ倒した回は文書契約面の部分実行を名乗らない（文書が先）"
expect_lacks '^doc-contract: ' "47-N: 全件へ倒した回は束の件数行を出さない（文書が先）"
expect_lacks "^${FULL_NOTICE_HEAD}" "47-N: 契約面に触れた変更ベースの自動全件では全件モードの用途の注意を出さない（通常 PR の正当な経路）"
_chg_rec_has 'MODE=full' "47-N: 文書 + 実行基盤（文書が先）の記録は full"
_chg_rec_has 'COVERS_DIFF=' "47-N: 文書 + 実行基盤（文書が先）は COVERS_DIFF を空にする"
_chg_step "文書契約面と実行基盤の契約面を同時に変える（実行基盤が先）" "mkdir -p .github/workflows && printf 'name: zz\\n' > .github/workflows/zz-probe.yml && printf '# probe\\n' >> AGENTS.md"
_chg_run FF_RUN_ALL_CHANGED="$_chg_base"
expect_rc 0 "47-N: 文書 + 実行基盤（実行基盤が先）の実行が rc=0"
expect_has '^↪ 変更ベースの選択（FF_RUN_ALL_CHANGED）から全件実行へ倒しました: 実行基盤の契約面に触れる変更: .github/workflows/zz-probe.yml（CHANGED_FULL_REPO_PATHS の .github/workflows/）' "47-N: 文書 + 実行基盤（実行基盤が先）も全件へ倒れる"
_chg_rec_has 'COVERS_DIFF=' "47-N: 文書 + 実行基盤（実行基盤が先）は COVERS_DIFF を空にする"

# 47-R: 文書契約面のディレクトリ要素の配下でも、文書（拡張子の名簿）でないファイルは実行基盤の契約面
# として全件へ倒す。配布テンプレートは実行コードも同梱していて、それを別の suite が import・実行する。
# 文書と同時に変えた回も、文書を先に見つけた後で全件へ倒れる（変更一覧では .md が .ts より先に並ぶ）。
_chg_step "配布テンプレート配下の実行コードだけを変える" "mkdir -p plugins/ff/docs-template/scripts && printf 'export const zz = 1\\n' > plugins/ff/docs-template/scripts/zz-probe.ts"
_chg_run FF_RUN_ALL_CHANGED="$_chg_base"
expect_rc 0 "47-R: 配布テンプレート配下の実行コードだけの変更の実行が rc=0"
expect_has '^🔎 全件実行: 登録されている 4 suite をすべて実行対象にします' "47-R: 配布テンプレート配下でも文書でないファイルは全件へ倒れる"
expect_has '^↪ 変更ベースの選択（FF_RUN_ALL_CHANGED）から全件実行へ倒しました: 実行基盤の契約面に触れる変更: plugins/ff/docs-template/scripts/zz-probe.ts（CHANGED_DOC_PLUGIN_PATHS の docs-template/ の配下だが、CHANGED_DOC_FILE_SUFFIXES の文書ではない）' "47-R: 倒した理由に、文書でないファイルを名指す"
expect_lacks '^🎯 文書契約面に触れる変更' "47-R: 文書でないファイルの変更は文書契約面の部分実行を名乗らない"
_chg_rec_has 'MODE=full' "47-R: 配布テンプレート配下の実行コードの変更の記録は full"
_chg_rec_has 'COVERS_DIFF=' "47-R: 配布テンプレート配下の実行コードの変更は COVERS_DIFF を空にする"
_chg_step "配布テンプレートの文書と実行コードを同時に変える" "mkdir -p plugins/ff/docs-template/scripts && printf '# d\\n' > plugins/ff/docs-template/aa-doc-probe.md && printf 'export const zz = 2\\n' > plugins/ff/docs-template/scripts/zz-probe.ts"
_chg_run FF_RUN_ALL_CHANGED="$_chg_base"
expect_rc 0 "47-R: 文書 + 配布テンプレート配下の実行コードの実行が rc=0"
expect_has '^↪ 変更ベースの選択（FF_RUN_ALL_CHANGED）から全件実行へ倒しました: 実行基盤の契約面に触れる変更: plugins/ff/docs-template/scripts/zz-probe.ts' "47-R: 文書を先に見つけた後でも、文書でないファイルで全件へ倒れる"
_chg_rec_has 'COVERS_DIFF=' "47-R: 文書 + 配布テンプレート配下の実行コードは COVERS_DIFF を空にする"

# 47-O: 束が登録一覧と 1 対 1 に対応しない回（suite の改名・削除・重複・空）は、見つかった分だけで
# 通さず全件へ倒す。複製ランナー自身は実行基盤の契約面なので、束を書き換えた木を新しい base に
# してから文書契約面を変える（47-H と同じ組み方）。
_chg_bundle_case() { # <検査名の見出し> <束の要素（空白区切り。空なら空の束）> <期待する理由の BRE>
  _chg_git reset -q --hard "$_chg_base" >/dev/null 2>&1
  _chg_git clean -qfd >/dev/null 2>&1
  awk -v names="$2" '
    /^CHANGED_DOC_SUITES=\($/ {
      print
      n = split(names, a, " ")
      for (i = 1; i <= n; i++) print "  \"" a[i] "\""
      skip = 1
      next
    }
    skip && /^\)$/ { skip = 0; print; next }
    skip { next }
    { print }
  ' "$_chg_plug/tests/run-all.sh" > "$_chg_plug/tests/run-all.sh.new" \
    && mv "$_chg_plug/tests/run-all.sh.new" "$_chg_plug/tests/run-all.sh" \
    || bad "case 47: $1 の束の差し替えを当てられない"
  _chg_git commit -qam "束を差し替える: $1" >/dev/null 2>&1 || bad "case 47: $1 の base をコミットできない"
  _chg_base_o="$(_chg_git rev-parse HEAD 2>/dev/null)"
  printf '# probe\n' >> "$_chg_repo/AGENTS.md"
  _chg_git add -A >/dev/null 2>&1
  _chg_git commit -qm "文書契約面を変える: $1" >/dev/null 2>&1 || bad "case 47: $1 の変更をコミットできない"
  _chg_run FF_RUN_ALL_CHANGED="$_chg_base_o"
  expect_rc 0 "47-O: $1 の実行が rc=0（全件が通る）"
  expect_has '^🔎 全件実行: 登録されている 4 suite をすべて実行対象にします' "47-O: $1 は全件へ倒れる（見つかった分だけで通さない）"
  expect_has "^↪ 変更ベースの選択（FF_RUN_ALL_CHANGED）から全件実行へ倒しました: $3" "47-O: $1 の倒した理由を出す"
  expect_lacks '^🎯 文書契約面に触れる変更' "47-O: $1 は文書契約面の部分実行を名乗らない"
  _chg_rec_has 'MODE=full' "47-O: $1 の記録は full"
  _chg_rec_has 'COVERS_DIFF=' "47-O: $1 は COVERS_DIFF を空にする"
}
_chg_bundle_case "登録一覧に無い名前を含む束" "chg-required-probe no-such-suite" \
  '文書横断 suite の束（CHANGED_DOC_SUITES）が登録一覧と 1 対 1 に対応しない: no-such-suite — 文書契約面に触れる変更: AGENTS.md'
_chg_bundle_case "同じ名前を 2 回持つ束" "chg-required-probe chg-required-probe" \
  '文書横断 suite の束（CHANGED_DOC_SUITES）が登録一覧と 1 対 1 に対応しない: （件数の不一致） — 文書契約面に触れる変更: AGENTS.md'
_chg_bundle_case "空の束" "" \
  '文書契約面に触れる変更だが、文書横断 suite の束（CHANGED_DOC_SUITES）が空: AGENTS.md'
_chg_git reset -q --hard "$_chg_base" >/dev/null 2>&1

# 47-Q: 束が 2 要素以上で、束の suite が字面の交差でも選ばれる回（実物の束は毎回この形になる）。
# 交差で選ばれた束の suite も「登録一覧に在った」と数えなければ、件数照合が不一致になって文書だけの
# 変更が毎回全件へ倒れる。束 = chg-required-probe（交差しない）+ chg-tree-probe（プラグイン配下の
# 変更と交差する）で、交差の有無が違う 2 つの変更を測る。
_chg_bundle_ok() { # <検査名の見出し> <束の要素（空白区切り）> <変更の sh 断片> <選択件数> <束として足した件数>
  _chg_git reset -q --hard "$_chg_base" >/dev/null 2>&1
  _chg_git clean -qfd >/dev/null 2>&1
  awk -v names="$2" '
    /^CHANGED_DOC_SUITES=\($/ {
      print
      n = split(names, a, " ")
      for (i = 1; i <= n; i++) print "  \"" a[i] "\""
      skip = 1
      next
    }
    skip && /^\)$/ { skip = 0; print; next }
    skip { next }
    { print }
  ' "$_chg_plug/tests/run-all.sh" > "$_chg_plug/tests/run-all.sh.new" \
    && mv "$_chg_plug/tests/run-all.sh.new" "$_chg_plug/tests/run-all.sh" \
    || bad "case 47: $1 の束の差し替えを当てられない"
  _chg_git commit -qam "束を差し替える: $1" >/dev/null 2>&1 || bad "case 47: $1 の base をコミットできない"
  _chg_base_q="$(_chg_git rev-parse HEAD 2>/dev/null)"
  (cd "$_chg_repo" && sh -c "$3") >/dev/null 2>&1 || bad "case 47: $1 の変更を当てられない"
  _chg_git add -A >/dev/null 2>&1
  _chg_git commit -qm "文書契約面を変える: $1" >/dev/null 2>&1 || bad "case 47: $1 の変更をコミットできない"
  _chg_run FF_RUN_ALL_CHANGED="$_chg_base_q"
  expect_rc 0 "47-Q: $1 の実行が rc=0"
  expect_lacks '^🔎 全件実行' "47-Q: $1 は全件へ倒れない（交差で選ばれた束の suite も登録一覧に在ったと数える）"
  expect_has "^suites: selected=$4 registered=4\$" "47-Q: $1 の選択は $4 件"
  expect_has "^doc-contract: bundle=2 added=$5\$" "47-Q: $1 は束 2 件のうち $5 件を束として足す"
  expect_has '^CHG-REQUIRED-PROBE-EXECUTED$' "47-Q: $1 で交差しない束の suite が実行される"
  expect_has '^CHG-TREE-PROBE-EXECUTED$' "47-Q: $1 で束のもう 1 件も実行される"
  _chg_rec_has 'MODE=changed' "47-Q: $1 の記録のモードは changed"
  _chg_rec_has "COVERS_DIFF=${_chg_base_q}" "47-Q: $1 のクリーン通過は COVERS_DIFF を残す"
}
_chg_bundle_ok "束の 1 件が交差でも選ばれる変更" "chg-required-probe chg-tree-probe" \
  "mkdir -p plugins/ff/docs-template && printf '# d\\n' > plugins/ff/docs-template/zz-doc-probe.md" 2 1
_chg_bundle_ok "束のどれも交差しない変更" "chg-required-probe chg-tree-probe" \
  "printf '# probe\\n' >> AGENTS.md" 2 2
_chg_git reset -q --hard "$_chg_base" >/dev/null 2>&1

# 47-S: このランナーからは常に suite ごと skip する suite（CHANGED_NEVER_RUN_SUITES。実物では公開検査）は、
# 字面が交差しても選択に入れない（ADR-095）。選択に残すと skip が必ず 1 件混じり、交差する変更
# （公開検査はプラグインルートを参照するので、プラグイン配下のすべての変更）では COVERS_DIFF が
# 何度回しても付かない。fixture の public-layout はプラグインルートを参照し、実行ビットを付けない —
# 選択に入った回もランナーは起動しない（この名前のスクリプトを実プロセスとして起動すると、同じ
# ホストの別セッションのゲートが公開検査の並走として読むため。選択に入ったことは、根拠の行と
# 未実行の計上で観測する）。登録を足した木を新しい base にしてから変更を当てる（47-O と同じ組み方）。
_chg_git reset -q --hard "$_chg_base" >/dev/null 2>&1
_chg_git clean -qfd >/dev/null 2>&1
mkdir -p "$_chg_plug/tests/public-layout"
cat > "$_chg_plug/tests/public-layout/verify.sh" <<'PROBE'
#!/usr/bin/env bash
# 空振り検出: 47-S の fixture（明示起動の指定が無い回は常に suite ごと skip する suite を模す）
# run-all-required: no — 明示起動の指定が無い回は常に suite ごと skip する（47-S の fixture）
REPO_ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
TREE="$REPO_ROOT/plugins/ff"
if [[ "${FF_RUN_PUBLIC_LAYOUT:-}" != "1" && -z "${FF_PUBLIC_LAYOUT_SUITES:-}" ]]; then
  echo "○ skip: 明示起動する suite です（47-S の fixture。検査は 1 件も実行していません）"
  exit 0
fi
echo "CHG-NEVER-RUN-PROBE-EXECUTED"
exit 0
PROBE
awk '
  { print }
  $0 == "    \"$SCRIPT_DIR/chg-tree-probe/verify.sh\"" { print "    \"$SCRIPT_DIR/public-layout/verify.sh\"" }
' "$_chg_plug/tests/run-all.sh" > "$_chg_plug/tests/run-all.sh.new" \
  && mv "$_chg_plug/tests/run-all.sh.new" "$_chg_plug/tests/run-all.sh" \
  || bad "case 47: 47-S の登録の追加を当てられない"
[ "$(grep -c '^    "\$SCRIPT_DIR/public-layout/verify\.sh"$' "$_chg_plug/tests/run-all.sh")" -eq 1 ] \
  || bad "case 47: 47-S の複製ランナーへ public-layout の登録が入っていない（一覧の書式変更で awk が空振り）"
_chg_git add -A >/dev/null 2>&1
_chg_git commit -qm "47-S: 常に skip する suite を登録する" >/dev/null 2>&1 || bad "case 47: 47-S の base をコミットできない"
_chg_base_s="$(_chg_git rev-parse HEAD 2>/dev/null)"
_chg_s_step() { # <説明> <sh 断片（fixture リポジトリのルートを cwd にして評価する）>
  _chg_git reset -q --hard "$_chg_base_s" >/dev/null 2>&1
  _chg_git clean -qfd >/dev/null 2>&1
  (cd "$_chg_repo" && sh -c "$2") >/dev/null 2>&1 || bad "case 47: 47-S の変更を当てられない: $1"
  _chg_git add -A >/dev/null 2>&1
  _chg_git commit -qm "$1" >/dev/null 2>&1 || bad "case 47: 47-S の変更をコミットできない: $1"
}
# 選択の名簿を差し替えた木を新しい base にする（束は 47-O / 47-Q と同じ書式の配列）。
_chg_s_rebase() { # <説明> <配列名> <要素（空白区切り）>
  _chg_git reset -q --hard "$_chg_base_s" >/dev/null 2>&1
  _chg_git clean -qfd >/dev/null 2>&1
  awk -v head="^$2=\\\\($" -v names="$3" '
    $0 ~ head {
      print
      n = split(names, a, " ")
      for (i = 1; i <= n; i++) print "  \"" a[i] "\""
      skip = 1
      next
    }
    skip && /^\)$/ { skip = 0; print; next }
    skip { next }
    { print }
  ' "$_chg_plug/tests/run-all.sh" > "$_chg_plug/tests/run-all.sh.new" \
    && mv "$_chg_plug/tests/run-all.sh.new" "$_chg_plug/tests/run-all.sh" \
    || bad "case 47: 47-S の名簿の差し替えを当てられない: $1"
  [ "$(awk -v head="^$2=\\\\($" '$0 ~ head { on = 1; next } on && /^\)$/ { exit } on { n++ } END { print n + 0 }' "$_chg_plug/tests/run-all.sh")" -eq "$(printf '%s\n' "$3" | wc -w | tr -d ' ')" ] \
    || bad "case 47: 47-S の名簿の差し替えが入っていない（$2 の書式変更で awk が空振り）: $1"
  _chg_git commit -qam "47-S: $1" >/dev/null 2>&1 || bad "case 47: 47-S の名簿の base をコミットできない: $1"
  _chg_base_s2="$(_chg_git rev-parse HEAD 2>/dev/null)"
}
_chg_s_change() { # <説明> <sh 断片> — 直前の _chg_s_rebase の木へ変更を 1 コミット積む
  (cd "$_chg_repo" && sh -c "$2") >/dev/null 2>&1 || bad "case 47: 47-S の変更を当てられない: $1"
  _chg_git add -A >/dev/null 2>&1
  _chg_git commit -qm "47-S: $1" >/dev/null 2>&1 || bad "case 47: 47-S の変更をコミットできない: $1"
}

# (1) プラグイン配下の変更: 公開検査の fixture は字面が交差するが、選択に入らず、外したことを名乗る。
# skip も未実行も混じらないので COVERS_DIFF が残る（修正前の実物ではここで skipped=1 になり、空の
# ままだった。この fixture は実行ビットが無いので、修正前の形なら not-run=1 になる）。
_chg_s_step "47-S: alpha を変える" "echo alpha-s > plugins/ff/docs/alpha.md"
_chg_run -u FF_RUN_PUBLIC_LAYOUT -u FF_PUBLIC_LAYOUT_SUITES FF_RUN_ALL_CHANGED="$_chg_base_s"
expect_rc 0 "47-S: 常に skip する suite と交差する変更の実行が rc=0"
expect_has '^suites: selected=2 registered=5$' "47-S: 常に skip する suite は選択の件数に入らない"
expect_has '^🎯 選択に入れない suite: public-layout — 選択の条件には当たるが、このランナーからは常に suite ごと skip する' "47-S: 外した suite と理由を実行の入口で名乗る（黙って消さない）"
expect_has '^never-run: excluded=1 (public-layout)$' "47-S: 外した件数と名前をサマリーへ出す"
expect_lacks '^🎯   public-layout ← ' "47-S: 外した suite を選んだ根拠の一覧へ載せない"
expect_has '^suites: total=2 run=2 passed=2 failed=0 skipped=0 not-run=0$' "47-S: 外した回は skip も未実行も 0 件"
_chg_rec_has 'SUITES=chg-docs-probe chg-tree-probe' "47-S: 記録には通った suite だけが残る"
_chg_rec_has "COVERS_DIFF=${_chg_base_s}" "47-S: 常に skip する suite と交差する変更でも、クリーン通過は COVERS_DIFF を残す"

# fixture の公開検査に実行ビットが見えない環境でだけ、選択に残る場面（(2)・(5) の後半）を回す。
# 実行ビットが見える環境（全ファイルが実行可能に見えるファイルシステムなど）では、ランナーがこの名前の
# スクリプトを実プロセスとして起動してしまうので、回さずに赤にする。
_chg_s_noexec=1
if [ -x "$_chg_plug/tests/public-layout/verify.sh" ]; then
  _chg_s_noexec=0
  bad "47-S: fixture の公開検査に実行ビットが見える（選択に残る場面を、実プロセスを起動せずに測れません）"
fi

# (2) 明示起動の指定がある回は、suite が回りうるので選択に残す（2 つの指定のどちらでも）。
# FF_RUN_PUBLIC_LAYOUT は 1 だけが指定で、0 は指定に数えない（suite 側の分岐と同じ読み）。
# 選択に残った fixture は未実行（実行ビットなし）なので、この回は赤で終わり、COVERS_DIFF は付かない。
if [ "$_chg_s_noexec" = 1 ]; then
  for _chg_s_opt in "FF_RUN_PUBLIC_LAYOUT=1" "FF_PUBLIC_LAYOUT_SUITES=some-suite"; do
    _chg_run -u FF_RUN_PUBLIC_LAYOUT -u FF_PUBLIC_LAYOUT_SUITES "$_chg_s_opt" FF_RUN_ALL_CHANGED="$_chg_base_s"
    expect_rc 1 "47-S: 選択に残った fixture が未実行なので rc=1（${_chg_s_opt}）"
    expect_has '^suites: selected=3 registered=5$' "47-S: 明示起動の指定（${_chg_s_opt}）がある回は選択に残す"
    expect_has '^🎯   public-layout ← plugins/ff/docs/alpha.md ← ' "47-S: 明示起動の指定（${_chg_s_opt}）がある回は選んだ根拠を出す"
    expect_lacks '^🎯 選択に入れない suite' "47-S: 明示起動の指定（${_chg_s_opt}）がある回は外したと名乗らない"
    expect_lacks '^never-run: ' "47-S: 明示起動の指定（${_chg_s_opt}）がある回はサマリーにも外した行を出さない"
    expect_lacks '^CHG-NEVER-RUN-PROBE-EXECUTED$' "47-S: fixture の公開検査は起動していない（${_chg_s_opt}。実行ビットが無い）"
    expect_has '^suites: total=3 run=2 passed=2 failed=0 skipped=0 not-run=1$' "47-S: 選択に残った fixture は未実行として数える（${_chg_s_opt}）"
    _chg_rec_has 'STATUS=fail' "47-S: 未実行が混じった回の記録は fail（${_chg_s_opt}）"
    _chg_rec_has 'COVERS_DIFF=' "47-S: 未実行が混じった回は COVERS_DIFF を空にする（${_chg_s_opt}）"
  done
fi
_chg_run -u FF_PUBLIC_LAYOUT_SUITES FF_RUN_PUBLIC_LAYOUT=0 FF_RUN_ALL_CHANGED="$_chg_base_s"
expect_has '^suites: selected=2 registered=5$' "47-S: FF_RUN_PUBLIC_LAYOUT=0 は明示起動の指定に数えない（選択に入れない）"
expect_has '^never-run: excluded=1 (public-layout)$' "47-S: FF_RUN_PUBLIC_LAYOUT=0 の回も外したことをサマリーへ出す"

# (3) 配布テンプレートの文書だけの変更（文書契約面。実物で COVERS_DIFF が付かなかった形）: 束は足され、
# 公開検査は外れ、クリーン通過で COVERS_DIFF が残る。
_chg_s_step "47-S: 配布テンプレートの文書を変える" "mkdir -p plugins/ff/docs-template && echo '# d' > plugins/ff/docs-template/zz-doc-probe.md"
_chg_run -u FF_RUN_PUBLIC_LAYOUT -u FF_PUBLIC_LAYOUT_SUITES FF_RUN_ALL_CHANGED="$_chg_base_s"
expect_rc 0 "47-S: 配布テンプレートの文書だけの変更の実行が rc=0"
expect_has '^🎯 文書契約面に触れる変更: plugins/ff/docs-template/zz-doc-probe.md' "47-S: 配布テンプレートの文書の変更は文書契約面として扱う"
expect_has '^🎯 選択に入れない suite: public-layout — ' "47-S: 文書契約面の回も、常に skip する suite を外したと名乗る"
expect_has '^suites: selected=2 registered=5$' "47-S: 文書契約面の回の選択は、交差 + 束（常に skip する suite を除く）"
expect_has '^doc-contract: bundle=1 added=1$' "47-S: 文書契約面の回の束の件数は変わらない"
_chg_rec_has "COVERS_DIFF=${_chg_base_s}" "47-S: 配布テンプレートの文書だけの変更のクリーン通過は COVERS_DIFF を残す"

# (4) 字面が交差しない変更（root の入口）では、外したと名乗らない（選択の条件に当たった回だけ名乗る）。
_chg_s_step "47-S: root の入口を変える" "echo '# probe' >> AGENTS.md"
_chg_run -u FF_RUN_PUBLIC_LAYOUT -u FF_PUBLIC_LAYOUT_SUITES FF_RUN_ALL_CHANGED="$_chg_base_s"
expect_rc 0 "47-S: 常に skip する suite と交差しない変更の実行が rc=0"
expect_has '^suites: selected=1 registered=5$' "47-S: 交差しない変更の選択は束の 1 件だけ"
expect_lacks '^🎯 選択に入れない suite' "47-S: 交差しない変更では外したと名乗らない"
expect_lacks '^never-run: ' "47-S: 交差しない変更ではサマリーにも外した行を出さない"
_chg_rec_has "COVERS_DIFF=${_chg_base_s}" "47-S: 交差しない変更のクリーン通過も COVERS_DIFF を残す"

# (5) 束の suite が「常に skip する suite」でもある回は、差分を覆ったと記録しない。
# 字面が交差する変更では、外す判定が束の照合より前にあるので、外れた分だけ件数照合が不一致になって
# 全件へ倒れる。字面が交差しない変更では外す判定に当たらず、束として選択に入る — その suite は回らない
# （実物なら skip、この fixture なら未実行）ので、COVERS_DIFF は付かない。どちらも「束を欠いたまま
# 覆ったことにしない」側に倒れる（実物の束と名簿の重なりそのものは 47-P が赤にする）。
_chg_s_rebase "束へ常に skip する suite を入れる" CHANGED_DOC_SUITES "chg-required-probe public-layout"
_chg_s_change "束の差し替え後に配布テンプレートの文書を変える" "mkdir -p plugins/ff/docs-template && echo '# d' > plugins/ff/docs-template/zz-doc-probe.md"
if [ "$_chg_s_noexec" = 1 ]; then
  _chg_run -u FF_RUN_PUBLIC_LAYOUT -u FF_PUBLIC_LAYOUT_SUITES FF_RUN_ALL_CHANGED="$_chg_base_s2"
  expect_rc 1 "47-S: 全件へ倒れた回は、全件の一覧にある fixture が未実行なので rc=1"
  expect_has '^🔎 全件実行: 登録されている 5 suite をすべて実行対象にします' "47-S: 束の suite が常に skip する suite でもあり、字面が交差する回は全件へ倒れる"
  expect_has '^↪ 変更ベースの選択（FF_RUN_ALL_CHANGED）から全件実行へ倒しました: 文書横断 suite の束（CHANGED_DOC_SUITES）が登録一覧と 1 対 1 に対応しない: ' "47-S: 倒した理由に束の不一致を出す"
  # 外した名前の読み手は部分実行の出力だけなので、全件へ倒した回に名乗りが漏れないことを見る
  # （名乗りを部分実行の分岐の外へ出す変更を赤にする）。
  expect_lacks '^🎯 選択に入れない suite' "47-S: 全件へ倒した回は外したと名乗らない（全件の一覧にその suite が残る）"
  expect_lacks '^never-run: ' "47-S: 全件へ倒した回はサマリーにも外した行を出さない"
  _chg_rec_has 'MODE=full' "47-S: 全件へ倒した回の記録は full"
  _chg_rec_has 'COVERS_DIFF=' "47-S: 束の suite が常に skip する suite でもある回（交差する）は COVERS_DIFF を空にする"
fi
_chg_s_rebase "束へ常に skip する suite を入れる（交差しない変更）" CHANGED_DOC_SUITES "chg-required-probe public-layout"
_chg_s_change "束の差し替え後に root の入口を変える" "echo '# probe' >> AGENTS.md"
if [ "$_chg_s_noexec" = 1 ]; then
  _chg_run -u FF_RUN_PUBLIC_LAYOUT -u FF_PUBLIC_LAYOUT_SUITES FF_RUN_ALL_CHANGED="$_chg_base_s2"
  expect_rc 1 "47-S: 束として選択に入った fixture が未実行なので rc=1"
  expect_lacks '^🔎 全件実行' "47-S: 束の suite が常に skip する suite でも、字面が交差しない回は全件へ倒れない"
  expect_has '^🎯   public-layout ← AGENTS.md（CHANGED_DOC_REPO_PATHS の AGENTS.md） ← 文書横断 suite の束（CHANGED_DOC_SUITES）$' "47-S: 字面が交差しない回は、束として選択に入る"
  expect_lacks '^🎯 選択に入れない suite' "47-S: 束として選択に入った回は外したと名乗らない"
  _chg_rec_has 'COVERS_DIFF=' "47-S: 束の suite が常に skip する suite でもある回（交差しない）も COVERS_DIFF を空にする"
fi

# (6) 名簿に名前があっても、「常に skip する」条件を書いていない名前は選択に残す（多く回す側）。
# 名簿へ chg-tree-probe（条件を持たない）を足した木で、選択も外した名前も変わらないことを見る。
_chg_s_rebase "名簿へ条件を持たない名前を足す" CHANGED_NEVER_RUN_SUITES "public-layout chg-tree-probe"
_chg_s_change "名簿の差し替え後に alpha を変える" "echo alpha-s6 > plugins/ff/docs/alpha.md"
_chg_run -u FF_RUN_PUBLIC_LAYOUT -u FF_PUBLIC_LAYOUT_SUITES FF_RUN_ALL_CHANGED="$_chg_base_s2"
expect_rc 0 "47-S: 名簿へ条件を持たない名前を足した回の実行が rc=0"
expect_has '^suites: selected=2 registered=5$' "47-S: 条件を書いていない名前は名簿に在っても選択に残る"
expect_has '^CHG-TREE-PROBE-EXECUTED$' "47-S: 条件を書いていない名前の suite は実行される"
expect_has '^never-run: excluded=1 (public-layout)$' "47-S: 外すのは条件を書いた名前だけ"
_chg_git reset -q --hard "$_chg_base" >/dev/null 2>&1
_chg_git clean -qfd >/dev/null 2>&1

# 47-T / 47-U: 変更ベースの部分ゲートの回が赤・必須 skip で終わったとき、通しで回し直す案内は同じ
# FF_RUN_ALL_CHANGED の指定を写す（Issue `#3004`）。FAST_MODE=0 から全件の前置（FF_RUN_ALL_FULL=1）へ
# 化けると、通常 PR の再実行が全件モードへ上がり、全件モードの用途の注意と自分で食い違う。
_chg_step "47-T: alpha を変える" "printf 'alpha-t\\n' > plugins/ff/docs/alpha.md"
_chg_run FF_RUN_ALL_CHANGED="$_chg_base" CHG_FORCE_STALE=1
expect_rc nz "47-T: 鮮度だけの赤で終わった変更ベースの実行が非 0"
_chg_t_full="$(printf '%s\n' "$RUN_OUT" | awk 'f { sub(/^    /, ""); print; exit } /^  base を取り込んで通しで 1 回回し直す（マージの根拠になる）:$/ { f = 1 }')"
# base を SHA で固定した指定（ここでは fixture の base コミット）は、取り込んだ後も古い base を測るので、
# 取り込む先（origin/HEAD）と同じ `1` へ戻して案内する。ref 名の指定はそのまま写す（下の 47-T2）。
case "$_chg_t_full" in
  "FF_RUN_ALL_CHANGED=1 bash /"*"/tests/run-all.sh") ok "47-T: 鮮度だけの赤の通しの案内は変更ベースの指定を前置し、SHA で固定した base は 1（origin/HEAD）へ戻す（全件モードへ上げない）" ;;
  *) bad "47-T: 鮮度だけの赤の通しの案内が変更ベースの指定（SHA の base は 1）を前置していない: '${_chg_t_full:-空}'" ;;
esac
expect_lacks '^    FF_RUN_ALL_FULL=1 bash ' "47-T: 変更ベースの回の通し・名指しの回し直しに全件の前置を出さない"
_chg_git branch -f chg-t-base "$_chg_base" >/dev/null 2>&1 || bad "case 47: 47-T2 の base ブランチを作れない"
_chg_run FF_RUN_ALL_CHANGED=chg-t-base CHG_FORCE_STALE=1
_chg_t2_full="$(printf '%s\n' "$RUN_OUT" | awk 'f { sub(/^    /, ""); print; exit } /^  base を取り込んで通しで 1 回回し直す（マージの根拠になる）:$/ { f = 1 }')"
case "$_chg_t2_full" in
  "FF_RUN_ALL_CHANGED=chg-t-base bash /"*"/tests/run-all.sh") ok "47-T2: ref 名で渡した base は通しの案内へそのまま写す（実行時に解決し直すため）" ;;
  *) bad "47-T2: ref 名の base が通しの案内へ写っていない: '${_chg_t2_full:-空}'" ;;
esac
_chg_git branch -D chg-t-base >/dev/null 2>&1 || true
_chg_step "47-U: gamma を変える" "printf 'gamma-u\\n' > plugins/ff/docs/gamma.md"
_chg_run FF_RUN_ALL_CHANGED="$_chg_base" CHG_FORCE_SKIP=1
expect_rc nz "47-U: 必須 suite の skip で終わった変更ベースの実行が非 0（fail-closed）"
expect_has "^    FF_RUN_ALL_CHANGED=${_chg_base} FF_RUN_ALL_ALLOW_MISSING_MCP_DEPS=1 FF_RUN_ALL_ALLOW_SKIP=\"chg-required-probe\" bash tests/run-all\\.sh$" \
  "47-U: 必須 skip の再現コマンドは同じ FF_RUN_ALL_CHANGED の指定を前置する（全件モードへ上げない）"
_chg_git reset -q --hard "$_chg_base" >/dev/null 2>&1
_chg_git clean -qfd >/dev/null 2>&1

# 47-V〜47-Y（Issue `#3006`）。基点を作り直す補助: _chg_base から木を作り直し、呼び出し側が木を書き換えた
# 後で _chg_x_commit を呼ぶと、それを新しい base（_chg_base_x）にする。
_chg_x_reset() {
  _chg_git reset -q --hard "$_chg_base" >/dev/null 2>&1
  _chg_git clean -qfd >/dev/null 2>&1
}
_chg_x_commit() { # <説明>
  _chg_git add -A >/dev/null 2>&1
  _chg_git commit -qm "$1" >/dev/null 2>&1 || bad "case 47: $1 をコミットできない"
  _chg_base_x="$(_chg_git rev-parse HEAD 2>/dev/null)"
}
_chg_x_change() { # <説明> <sh 断片> — 直前の _chg_x_commit の木へ変更を 1 コミット積む
  (cd "$_chg_repo" && sh -c "$2") >/dev/null 2>&1 || bad "case 47: 変更を当てられない: $1"
  _chg_git add -A >/dev/null 2>&1
  _chg_git commit -qm "$1" >/dev/null 2>&1 || bad "case 47: 変更をコミットできない: $1"
}

# 47-V: 依存を宣言した suite は字面の照合をやめ、宣言に当たる変更（と自身のディレクトリ）でだけ選ばれる。
# chg-docs-probe は字面に alpha と delta を持つ。delta だけを宣言すると、alpha の変更では選ばれない。
_chg_x_reset
printf '# run-all-depends: docs/delta.md\n' >> "$_chg_plug/tests/chg-docs-probe/verify.sh"
_chg_x_commit "47-V: chg-docs-probe に依存の宣言を足す"
_chg_v_base="$_chg_base_x"
_chg_x_change "47-V: alpha を変える" "printf 'alpha-v\\n' > plugins/ff/docs/alpha.md"
_chg_run FF_RUN_ALL_CHANGED="$_chg_v_base"
expect_rc 0 "47-V: 宣言のある suite を含む変更ベースの実行が rc=0"
expect_lacks '^CHG-DOCS-PROBE-EXECUTED$' "47-V: 宣言のある suite は、字面にあっても宣言に無い変更（alpha）では選ばれない"
_chg_git reset -q --hard "$_chg_v_base" >/dev/null 2>&1
_chg_x_change "47-V: delta を変える" "printf 'delta-v\\n' > plugins/ff/docs/delta.md"
_chg_run FF_RUN_ALL_CHANGED="$_chg_v_base"
expect_has '^CHG-DOCS-PROBE-EXECUTED$' "47-V: 宣言に当たる変更（delta）では選ばれる"
expect_has '^🎯   chg-docs-probe ← plugins/ff/docs/delta\.md ← 宣言 docs/delta\.md$' "47-V: 根拠に、当たった宣言のパターンを出す"

# 47-W: ランナー（tests/run-all.sh）はブラックボックス。変更は全件へ倒れず、ランナー自身の suite（run-all）を
# 必ず選ぶ。fixture の run-all は字面にランナーを持たない（字面の照合では選ばれない）ので、規則だけで選ばれる。
_chg_x_reset
mkdir -p "$_chg_plug/tests/run-all"
cat > "$_chg_plug/tests/run-all/verify.sh" <<'PROBE'
# 空振り検出: 47-W の fixture（ランナー自身の suite の代役。実物の検査は持たない）
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GAMMA="$ROOT/docs/gamma.md"
echo "CHG-RUNNER-SELF-EXECUTED"
exit 0
PROBE
chmod +x "$_chg_plug/tests/run-all/verify.sh"
awk '{ print } $0 == "    \"$SCRIPT_DIR/chg-tree-probe/verify.sh\"" { print "    \"$SCRIPT_DIR/run-all/verify.sh\"" }' \
  "$_chg_plug/tests/run-all.sh" > "$_chg_plug/tests/run-all.sh.new" \
  && mv "$_chg_plug/tests/run-all.sh.new" "$_chg_plug/tests/run-all.sh" \
  || bad "case 47: 47-W の複製ランナーへ run-all の登録を足せない"
[ "$(grep -c '^    "\$SCRIPT_DIR/run-all/verify\.sh"$' "$_chg_plug/tests/run-all.sh")" -eq 1 ] \
  || bad "case 47: 47-W の複製ランナーへ run-all の登録が入っていない（一覧の書式変更で awk が空振り）"
_chg_x_commit "47-W: ランナー自身の suite を登録する"
_chg_w_base="$_chg_base_x"
_chg_x_change "47-W: ランナーを変える" "printf '# 47-W\\n' >> plugins/ff/tests/run-all.sh"
_chg_run FF_RUN_ALL_CHANGED="$_chg_w_base"
expect_rc 0 "47-W: ランナーの変更の変更ベースの実行が rc=0"
expect_lacks '^↪ 変更ベースの選択' "47-W: ランナーの変更は全件へ倒れない（ブラックボックス）"
expect_has '^🎯 変更ベースの選択: ' "47-W: ランナーの変更でも部分実行を名乗る"
expect_has '^CHG-RUNNER-SELF-EXECUTED$' "47-W: ランナー自身の suite（run-all）を必ず選ぶ"
expect_has '^🎯   run-all ← plugins/ff/tests/run-all\.sh ← ランナー自身の suite' "47-W: 根拠にランナー自身の suite であることを出す"
expect_lacks '^CHG-DOCS-PROBE-EXECUTED$' "47-W: ランナーを参照しない suite は選ばない"

# 47-X: 共有 lib（tests/lib）の変更は全件へ倒れず、その lib を（推移的に）source する suite を選ぶ。
# chg-script-probe は helper を直接、chg-required-probe は helper を source する helper2 を source する。
_chg_x_reset
printf '. "${BASH_SOURCE[0]%%/*}/helper.sh"\n' > "$_chg_plug/tests/lib/helper2.sh"
printf '. "$ROOT/tests/lib/helper.sh"\n' >> "$_chg_plug/tests/chg-script-probe/verify.sh"
printf '. "$ROOT/tests/lib/helper2.sh"\n' >> "$_chg_plug/tests/chg-required-probe/verify.sh"
_chg_x_commit "47-X: lib を source する suite を作る"
_chg_x_base_x="$_chg_base_x"
_chg_x_change "47-X: lib を変える" "printf '# lib-x\\n' >> plugins/ff/tests/lib/helper.sh"
_chg_run FF_RUN_ALL_CHANGED="$_chg_x_base_x"
expect_rc 0 "47-X: lib の変更の変更ベースの実行が rc=0"
expect_lacks '^↪ 変更ベースの選択' "47-X: tests/lib の変更は全件へ倒れない"
expect_has '^CHG-SCRIPT-PROBE-EXECUTED$' "47-X: lib を直接 source する suite を選ぶ"
expect_has '^CHG-REQUIRED-PROBE-EXECUTED$' "47-X: lib を推移的に source する suite（lib を source する lib を source する）を選ぶ"
expect_lacks '^CHG-DOCS-PROBE-EXECUTED$' "47-X: lib を source しない suite は選ばない"
expect_has '^🎯   chg-script-probe ← plugins/ff/tests/lib/helper\.sh を名指す ' "47-X: 根拠に元の lib の変更を出す"
# 推移の 2 段目を観測する: chg-required-probe の verify.sh 自身が利用側に入った（helper2 経由）ときだけ、
# 根拠が「suite 自身のディレクトリ」になる（1 段の展開なら helper2.sh の字面で選ばれ、この行は出ない）
expect_has '^🎯   chg-required-probe ← plugins/ff/tests/lib/helper\.sh を名指す plugins/ff/tests/chg-required-probe/verify\.sh ← suite 自身のディレクトリ$' \
  "47-X: 推移的な利用側は、利用側の suite 自身の変更として選ばれる（2 段目まで広がる）"

# 47-Z: tests/lib のシェル以外の共有ファイル（全 suite の git 設定・lib が読むデータ）は利用側をたどれないので
# 全件へ倒す（CHANGED_FULL_PLUGIN_NONSHELL_DIRS）
_chg_x_reset
_chg_z_base="$_chg_base"
_chg_x_change "47-Z: tests/lib の設定を足す" "printf '[init]\\n' > plugins/ff/tests/lib/isolated.gitconfig"
_chg_run FF_RUN_ALL_CHANGED="$_chg_z_base"
expect_has '^↪ 変更ベースの選択（FF_RUN_ALL_CHANGED）から全件実行へ倒しました: 実行基盤の契約面に触れる変更: plugins/ff/tests/lib/isolated\.gitconfig（CHANGED_FULL_PLUGIN_NONSHELL_DIRS の tests/lib/' \
  "47-Z: tests/lib のシェル以外のファイルの変更は全件へ倒し、名簿の要素を名指す"

# 47-Y: 試算モード（FF_RUN_ALL_SELECT_ONLY=1 + FF_RUN_ALL_CHANGED_FILES_FROM）は選択だけを出して終わる。suite は
# 回さず、記録も書かない。試算モードでない回の注入は全件へ倒す（ゲートの選択に使わせない）。
_chg_x_reset
_chg_y_list="$_chg_fx/inject-y.txt"
printf 'plugins/ff/docs/alpha.md\n' > "$_chg_y_list"
_chg_run FF_RUN_ALL_CHANGED=1 FF_RUN_ALL_SELECT_ONLY=1 FF_RUN_ALL_CHANGED_FILES_FROM="$_chg_y_list" FF_RUN_ALL_ALLOW_DIRTY=1
expect_rc 0 "47-Y: 試算モードは rc=0"
expect_has '^select-only: mode=changed selected=2 registered=4$' "47-Y: 注入した変更一覧への選択の件数を出す"
expect_has '^select-only: suite=chg-docs-probe$' "47-Y: 選ばれた suite を名指す"
expect_lacks '^CHG-DOCS-PROBE-EXECUTED$' "47-Y: 試算モードは suite を回さない"
if [ -f "$_chg_rec" ]; then bad "47-Y: 試算モードがゲートの記録を書いた"; else ok "47-Y: 試算モードはゲートの記録を書かない"; fi
_chg_run FF_RUN_ALL_CHANGED="$_chg_base" FF_RUN_ALL_CHANGED_FILES_FROM="$_chg_y_list"
expect_has '^↪ 変更ベースの選択（FF_RUN_ALL_CHANGED）から全件実行へ倒しました: FF_RUN_ALL_CHANGED_FILES_FROM は試算モード' "47-Y: 試算モードでない回の注入は全件へ倒す"
# 試算モードを変更ベースの選択なしで使った回は、suite を 1 本も回さず終了コード 2
_chg_run FF_RUN_ALL_SELECT_ONLY=1 FF_RUN_ALL_ALLOW_DIRTY=1
expect_rc 2 "47-Y: FF_RUN_ALL_CHANGED の無い試算モードは終了コード 2"
expect_lacks '^CHG-DOCS-PROBE-EXECUTED$' "47-Y: FF_RUN_ALL_CHANGED の無い試算モードは suite を回さない"
_chg_x_reset

# 47-P: 実物の名簿の整合。束の全要素が既定一覧に 1 回だけ登録されていて実体があること、ADR-095
# 決定 2 が名指す束の核（9 suite）が束から外れていないこと、2 種類の契約面の名簿が重ならず、
# 所属が名前で固定されていることを、run-all.sh の配列から読んで確かめる（読めた要素が 0 件なら
# 空振りとして赤）。
_chg_default_names="$(awk '
  /^  SCRIPTS=\($/ { on = 1; next }
  on && /^  \)$/ { exit }
  on && match($0, /"\$SCRIPT_DIR\/[^\/"]+\/verify\.sh"/) {
    s = substr($0, RSTART, RLENGTH)
    sub(/^"\$SCRIPT_DIR\//, "", s)
    sub(/\/verify\.sh"$/, "", s)
    print s
  }
' "$RUNNER")"
_chg_p_n=0
_chg_p_bad=""
while IFS= read -r _chg_b; do
  [ -n "$_chg_b" ] || continue
  _chg_p_n=$((_chg_p_n + 1))
  if [ ! -f "$TESTS_DIR/$_chg_b/verify.sh" ] \
    || [ "$(printf '%s\n' "$_chg_default_names" | grep -cxF -- "$_chg_b")" -ne 1 ]; then
    _chg_p_bad="${_chg_p_bad:+${_chg_p_bad} }${_chg_b}"
  fi
done <<CHG_BUNDLE
$_chg_doc_suites
CHG_BUNDLE
if [ "$_chg_p_n" -ge 1 ] && [ -z "$_chg_p_bad" ]; then
  ok "47-P: 実物の束の ${_chg_p_n} 要素はすべて既定一覧に 1 回だけ登録され、verify.sh の実体がある"
else
  bad "47-P: 実物の束が既定一覧と対応しない（読めた要素 ${_chg_p_n} 件 / 対応しない: ${_chg_p_bad:-なし}。0 件なら配列の書式変更で空振り）"
fi
if [ "$(printf '%s\n' "$_chg_doc_suites" | grep -c .)" -eq "$(printf '%s\n' "$_chg_doc_suites" | grep . | sort -u | grep -c .)" ]; then
  ok "47-P: 実物の束に同じ名前の重複が無い"
else
  bad "47-P: 実物の束に同じ名前が重複している（重複は実行時に全件フォールバックになる）"
fi
_chg_p_missing=""
for _chg_core in docs-gates section-ref-existence root-instructions-parity host-route-parity markdownlint \
  sync-forbidden-patterns skill-count-consistency shared-version-convergence changelog-fragments; do
  if [ "$(printf '%s\n' "$_chg_doc_suites" | grep -cxF -- "$_chg_core")" -ne 1 ]; then
    _chg_p_missing="${_chg_p_missing:+${_chg_p_missing} }${_chg_core}"
  fi
done
if [ -z "$_chg_p_missing" ]; then
  ok "47-P: 束の核（ADR-095 決定 2 が名指す 9 suite）が束に残っている"
else
  bad "47-P: 束の核が束から外れている: ${_chg_p_missing}（外すなら ADR-095 決定 2 を改める）"
fi
_chg_p_overlap=""
while IFS= read -r _chg_b; do
  [ -n "$_chg_b" ] || continue
  if [ "$(printf '%s\n%s\n' "$_chg_plugin_list" "$_chg_repo_list" | grep -cxF -- "$_chg_b")" -ne 0 ]; then
    _chg_p_overlap="${_chg_p_overlap:+${_chg_p_overlap} }${_chg_b}"
  fi
done <<CHG_DOC_PATHS
$_chg_doc_plugin_list
$_chg_doc_repo_list
CHG_DOC_PATHS
if [ -z "$_chg_p_overlap" ] && [ "$_chg_m_n" -ge 3 ]; then
  ok "47-P: 文書契約面の名簿と実行基盤の契約面の名簿は重ならない"
else
  bad "47-P: 2 種類の契約面の名簿が重なっているか、文書契約面の名簿を読めない（重なり: ${_chg_p_overlap:-なし} / 読めた要素 ${_chg_m_n} 件）"
fi

# 2 種類の名簿の所属を名前で固定する（件数だけの照合では、実行基盤の要素を文書側へ移す・文書側の
# 要素を別名へ置き換える変更が、件数を保ったまま通る）。文書側は名簿の全体を固定し、足すときは
# この検査も変える。実行基盤側は、文書側へ移ると少なく回す側へ倒れる要素が残っていることを見る。
_chg_p_doc_set="$(printf '%s\n%s\n' "$_chg_doc_plugin_list" "$_chg_doc_repo_list" | grep . | sort | tr '\n' ' ')"
if [ "$_chg_p_doc_set" = "AGENTS.md CLAUDE.md docs-template/ " ]; then
  ok "47-P: 文書契約面の名簿は docs-template/ と root の 2 入口だけ（足すときは ADR-095 とこの検査を改める）"
else
  bad "47-P: 文書契約面の名簿が想定と違う: [${_chg_p_doc_set}]"
fi
_chg_p_suffixes="$(_chg_list CHANGED_DOC_FILE_SUFFIXES | tr '\n' ' ')"
if [ "$_chg_p_suffixes" = ".md " ]; then
  ok "47-P: 文書として扱う拡張子は .md だけ（配布テンプレート配下の実行コード・設定は全件へ倒れる）"
else
  bad "47-P: 文書として扱う拡張子の名簿が想定と違う: [${_chg_p_suffixes}]"
fi
_chg_p_full_missing=""
for _chg_core in "tests/changed-select/" "hooks/hooks.json" "mcp/package.json" "mcp/package-lock.json"; do
  if [ "$(printf '%s\n' "$_chg_plugin_list" | grep -cxF -- "$_chg_core")" -ne 1 ]; then
    _chg_p_full_missing="${_chg_p_full_missing:+${_chg_p_full_missing} }${_chg_core}"
  fi
done
# ランナーと共有 lib は名簿に載せない（Issue `#3006`。ADR-096）: ランナーはブラックボックスとして
# 自身の suite と参照する suite を、共有 lib は利用側の逆引きで利用側を選ぶ。名簿へ戻すと、run-all.sh や
# tests/lib に触れる PR がまた全件へ倒れる（評価集合の 60 本中 28 本が全件で、うち 19 本はランナーか
# tests/lib だけが理由だった）。tests/lib のシェル以外は CHANGED_FULL_PLUGIN_NONSHELL_DIRS で全件へ倒す。
_chg_p_full_extra=""
for _chg_core in "tests/run-all.sh" "tests/lib/"; do
  if [ "$(printf '%s\n' "$_chg_plugin_list" | grep -cxF -- "$_chg_core")" -ne 0 ]; then
    _chg_p_full_extra="${_chg_p_full_extra:+${_chg_p_full_extra} }${_chg_core}"
  fi
done
if [ "$(_chg_list CHANGED_FULL_PLUGIN_NONSHELL_DIRS | tr '\n' ' ')" = "tests/lib/ " ]; then
  ok "47-P: tests/lib のシェル以外を全件へ倒す名簿は tests/lib/ だけ"
else
  bad "47-P: シェル以外を全件へ倒す名簿が想定と違う: [$(_chg_list CHANGED_FULL_PLUGIN_NONSHELL_DIRS | tr '\n' ' ')]（0 件なら配列の書式変更で空振り）"
fi
if [ -z "$_chg_p_full_extra" ]; then
  ok "47-P: ランナーと共有 lib は実行基盤の契約面の名簿に載っていない（ブラックボックス・利用側の逆引きで選ぶ）"
else
  bad "47-P: ランナー・共有 lib が実行基盤の契約面の名簿に戻っている: ${_chg_p_full_extra}（ブラックボックス化を戻すなら ADR とこの検査を改める）"
fi
for _chg_core in ".github/workflows/" ".github/actions/"; do
  if [ "$(printf '%s\n' "$_chg_repo_list" | grep -cxF -- "$_chg_core")" -ne 1 ]; then
    _chg_p_full_missing="${_chg_p_full_missing:+${_chg_p_full_missing} }${_chg_core}"
  fi
done
if [ -z "$_chg_p_full_missing" ]; then
  ok "47-P: 実行基盤の契約面の名簿に、選択の仕組み・hook 登録・共有依存・CI 定義が残っている"
else
  bad "47-P: 実行基盤の契約面の名簿から外れている要素がある: ${_chg_p_full_missing}"
fi

# 選択に入れない suite の名簿（47-S）の整合。名簿は公開検査だけで、既定一覧に 1 回だけ登録されて
# いること、束と重ならないこと、ランナーの「常に skip する」条件が suite 側の先頭の分岐と同じ字面で、
# その分岐が無条件に suite ごと skip して終わることを、実物から読んで確かめる。suite 側が run-all
# から回るようになったら（分岐の削除・条件の変更）、名簿から外さないと検査を黙って落とすので赤にする。
_chg_never_list="$(_chg_list CHANGED_NEVER_RUN_SUITES | tr '\n' ' ')"
if [ "$_chg_never_list" = "public-layout " ]; then
  ok "47-P: 選択に入れない suite の名簿は public-layout だけ（足すときは ADR-095 とこの検査を改める）"
else
  bad "47-P: 選択に入れない suite の名簿が想定と違う: [${_chg_never_list}]（0 件なら配列の書式変更で空振り）"
fi
if [ -f "$TESTS_DIR/public-layout/verify.sh" ] \
  && [ "$(printf '%s\n' "$_chg_default_names" | grep -cxF -- "public-layout")" -eq 1 ]; then
  ok "47-P: 選択に入れない suite は既定一覧に 1 回だけ登録され、verify.sh の実体がある"
else
  bad "47-P: 選択に入れない suite が既定一覧と対応しない（public-layout の登録か実体が無い）"
fi
if [ "$(printf '%s\n' "$_chg_doc_suites" | grep -cxF -- "public-layout")" -eq 0 ]; then
  ok "47-P: 選択に入れない suite は文書横断 suite の束に入っていない"
else
  bad "47-P: 選択に入れない suite が文書横断 suite の束に入っている（文書契約面の変更が毎回全件へ倒れる）"
fi
# shellcheck disable=SC2016
_chg_never_cond='if [[ "${FF_RUN_PUBLIC_LAYOUT:-}" != "1" && -z "${FF_PUBLIC_LAYOUT_SUITES:-}" ]]; then'
_chg_never_suite_n="$(grep -cxF -- "$_chg_never_cond" "$TESTS_DIR/public-layout/verify.sh")"
_chg_never_runner_n="$(grep -cF -- "$_chg_never_cond" "$RUNNER")"
if [ "$_chg_never_suite_n" -eq 1 ] && [ "$_chg_never_runner_n" -eq 1 ]; then
  ok "47-P: ランナーの「常に skip する」条件は、公開検査の先頭の分岐と同じ字面（どちらも 1 箇所）"
else
  bad "47-P: 「常に skip する」条件の字面が食い違う（公開検査 ${_chg_never_suite_n} 箇所 / ランナー ${_chg_never_runner_n} 箇所。条件を変えたら両方とこの検査を合わせる）"
fi
# 分岐の中身: 次の行が suite ごとの skip 理由行で、その次の行が exit 0（検査を 1 件も実行せずに終わる）。
if awk -v cond="$_chg_never_cond" '
    $0 == cond { on = NR; next }
    on && NR == on + 1 { if ($0 ~ /^  echo "○ skip: /) skip_line = 1; next }
    on && NR == on + 2 { if ($0 == "  exit 0") exit_line = 1; exit }
    END { exit (skip_line && exit_line) ? 0 : 1 }
  ' "$TESTS_DIR/public-layout/verify.sh"; then
  ok "47-P: 公開検査は、明示起動の指定が無い回に検査を 1 件も実行せず suite ごと skip して終わる"
else
  bad "47-P: 公開検査の先頭の分岐が「skip 理由行 → exit 0」ではない（run-all から回るようになったなら CHANGED_NEVER_RUN_SUITES から外す）"
fi
# その分岐が、行頭の if としては suite の最初であること。手前へ if の分岐を足すと、明示起動の指定が
# 無い回にも走る検査ができ、変更ベースの選択からはそれが黙って落ちる（1 行の検査や case など、行頭の
# if 以外の形で手前へ足された検査までは、この照合は拾わない）。
if [ "$(grep -m 1 '^if ' "$TESTS_DIR/public-layout/verify.sh")" = "$_chg_never_cond" ]; then
  ok "47-P: 公開検査の「常に skip する」分岐は、行頭の if として suite の最初"
else
  bad "47-P: 公開検査の最初の if が「常に skip する」分岐ではない（手前に if の分岐があるなら、その検査は変更ベースの選択から落ちる）"
fi
fi
rm -rf "$_chg_fx"
fi
fi
# suite-cases-end: changed-selection.sh
