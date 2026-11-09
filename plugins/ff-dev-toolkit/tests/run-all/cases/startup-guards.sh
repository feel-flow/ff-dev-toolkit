# shellcheck shell=bash
# RUN_OUT / RUN_RC は source 元の verify.sh の expect_* が読む（このファイル単体では未使用に見える）
# shellcheck disable=SC2034
# pipefail-inherited: verify.sh が set -euo pipefail の下で source する
# case 37・38・39・41・42: 起動ガードと鮮度の分類
#
# verify.sh から source される（ok / bad / expect_* / run_runner / RUN_OUT / RUN_RC / RUNNER / TESTS_DIR を共有）。
# 読む順序は verify.sh の一覧が正本で、前の cases の fixture と関数を後ろの cases が使う（Issue `#2696`）。

echo ""
echo "== case 37: node_modules 不在の案内は mcp/node_modules の実在だけで出し分ける =="
# 実リポジトリの plugins/ff-dev-toolkit/mcp は動かさず、テスト専用の上書き FF_RUN_ALL_MCP_DIR で
# ランナーの判定対象を差し替える（他suiteと並列実行しても共有資源を壊さない）。判定は消費側と
# 同じ 1 点（<mcp>/node_modules/.bin/esbuild が実行可能か）。
_ff_missing_nm="$RUN_WORK/ff-run-all-verify-missing-node_modules"
_ff_ready_mcp="$RUN_WORK/ff-run-all-verify-ready-mcp"
rm -rf "$_ff_missing_nm" "$_ff_ready_mcp"
mkdir -p "$_ff_ready_mcp/node_modules/.bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$_ff_ready_mcp/node_modules/.bin/esbuild"
chmod +x "$_ff_ready_mcp/node_modules/.bin/esbuild"

FF_RUN_ALL_MCP_DIR="$_ff_missing_nm" run_runner "$FIXTURES/pass/verify.sh" "$FIXTURES/skip/verify.sh"
expect_rc 0 "pass + skip の混在は従来どおり rc=0（skip は失敗として数えない）"
expect_has '^○ 案内: 同梱 MCP の依存が揃っていないため' "node_modules 不在 + skip ありの回は案内行を出す"
expect_has 'npm ci --prefix plugins/ff-dev-toolkit/mcp' "案内行に npm ci コマンドを含む"

FF_RUN_ALL_MCP_DIR="$_ff_ready_mcp" run_runner "$FIXTURES/pass/verify.sh" "$FIXTURES/skip/verify.sh"
expect_rc 0 "node_modules が実在する回も rc=0"
expect_lacks '^○ 案内: 同梱 MCP の依存が揃っていないため' "node_modules が実在する回は案内行を出さない（正常系で警告し続けない）"

FF_RUN_ALL_MCP_DIR="$_ff_missing_nm" run_runner "$FIXTURES/pass/verify.sh"
expect_rc 0 "pass のみ（skip/fail 0 件）は rc=0"
expect_lacks '^○ 案内: 同梱 MCP の依存が揃っていないため' "node_modules 不在でも skip/fail が 0 件の回は案内行を出さない"

# SKIPPED が 0 件でも FAILED だけで案内条件が満たされることを実測する（run-all.sh:1588 の
# `${#SKIPPED[@]} -gt 0 || ${#FAILED[@]} -gt 0` の OR 右辺）。skip を混ぜた上のケースだけでは
# 左辺しか通らず、右辺の検出力が無検査になる。
FF_RUN_ALL_MCP_DIR="$_ff_missing_nm" run_runner "$FIXTURES/fail/verify.sh"
expect_rc nz "fail のみ（skip 0 件）は従来どおり rc が非 0"
expect_has '^○ 案内: 同梱 MCP の依存が揃っていないため' "node_modules 不在 + fail のみ（skip 0 件）の回も案内行を出す"

# install が不完全な状態（node_modules は在るが .bin/esbuild が無い）も案内条件を満たす。
# 述語をディレクトリの実在へ退行させるとここだけが赤くなる — 下流 suite は「npm install が
# 不完全」で赤くなるのに、案内は黙るという食い違いが残るため。
# package.json も置く（＝起動ガードの述語を**両方**満たす状態）。これで本ケースは「明示引数の実行では
# ガードが発火しない」ことの実測も兼ねる — ガードの発火条件から USING_DEFAULT_SCRIPTS を落とす変異を
# 入れると、ここが rc=3 で赤くなる。置かないと `-f package.json` で先に落ちて連言が無検査になる。
_ff_partial_mcp="$RUN_WORK/ff-run-all-verify-partial-mcp"
rm -rf "$_ff_partial_mcp"
mkdir -p "$_ff_partial_mcp/node_modules"
: > "$_ff_partial_mcp/package.json"
FF_RUN_ALL_MCP_DIR="$_ff_partial_mcp" run_runner "$FIXTURES/pass/verify.sh" "$FIXTURES/skip/verify.sh"
expect_rc 0 "明示引数の実行は依存が揃っていなくてもガードに止められない（部分実行は正当な用途）"
expect_lacks '環境が未整備です' "明示引数の実行ではガードが発火しない"
expect_has '^○ 案内: 同梱 MCP の依存が揃っていないため' "node_modules は在るが esbuild が無い回も案内行を出す"

rm -rf "$_ff_missing_nm" "$_ff_ready_mcp" "$_ff_partial_mcp"

echo ""
echo "== case 38: 登録のみで他の随伴先に触れていない suite は逆向き導出で名指しし、随伴先文書のパスも出す =="

# run-all.sh を複製し、SCRIPTS と REQUIRED_SUITES の配列本体だけを最小内容へ差し替える
# （関数定義や他ロジックはそのまま）。複製先の $SCRIPT_DIR にはこの 2 suite しか実在しない
# ため、未改変の巨大な REQUIRED_SUITES を残すと「実在しない名前」検査（case 13 と同じ関数の
# 別分岐）が先に落ちて本題（逆向き導出の unlisted 検出）まで届かない。normal-probe は
# skip 経路を持ちつつ REQUIRED_SUITES にも載せた「追随済み」の対照、
# unlisted-required-probe は skip 経路を持つのに REQUIRED_SUITES へは触れていない —
# 「SCRIPTS 配列（追随先 `#1`）へは登録したが他の追随先には一切触れていない」という
# AC2 の Given そのものを表す。
_fu_fx="$RUN_WORK/ff-followup-unlisted-probe"
rm -rf "$_fu_fx"
mkdir -p "$_fu_fx/normal-probe" "$_fu_fx/unlisted-required-probe"
cat > "$_fu_fx/normal-probe/verify.sh" <<'PROBE'
#!/usr/bin/env bash
echo "○ skip: 随伴先チェックリスト fixture（追随済みの対照）"
exit 0
PROBE
cat > "$_fu_fx/unlisted-required-probe/verify.sh" <<'PROBE'
#!/usr/bin/env bash
echo "○ skip: 随伴先チェックリスト fixture（SCRIPTS へは登録したが他の随伴先には触れていない）"
exit 0
PROBE
chmod +x "$_fu_fx/normal-probe/verify.sh" "$_fu_fx/unlisted-required-probe/verify.sh"
awk '
  /^  SCRIPTS=\($/ {
    print
    print "    \"$SCRIPT_DIR/normal-probe/verify.sh\""
    print "    \"$SCRIPT_DIR/unlisted-required-probe/verify.sh\""
    in_scripts = 1
    next
  }
  in_scripts && /^  \)$/ { in_scripts = 0; print; next }
  in_scripts { next }
  /^REQUIRED_SUITES=\($/ {
    print
    print "  normal-probe"
    in_required = 1
    next
  }
  in_required && /^\)$/ { in_required = 0; print; next }
  in_required { next }
  # 空振り検出の免除名簿も fixture の名前へ差し替える（実体の名簿を残すと
  # 「実在しない名前」検査が先に落ちて本題まで届かない。REQUIRED_SUITES と同じ理由）
  /^MISS_PROBE_BASELINE=\($/ {
    print
    print "  normal-probe"
    print "  unlisted-required-probe"
    in_baseline = 1
    next
  }
  in_baseline && /^\)$/ { in_baseline = 0; print; next }
  in_baseline { next }
  { print }
' "$RUNNER" > "$_fu_fx/run-all.sh"
chmod +x "$_fu_fx/run-all.sh"
[ "$(grep -c '^  unlisted-required-probe$' "$_fu_fx/run-all.sh")" -eq 1 ] \
  || bad "case 38: 複製ランナーの MISS_PROBE_BASELINE 差し替えが適用されていない（見出し行の改稿で awk が空振り）"

_fu_rc=0
if _fu_out="$(env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL FF_RUN_ALL_CHECK_REGISTRATION=1 \
  FF_GATE_RECORD_FILE="$RUN_GATE_RECORD" bash "$_fu_fx/run-all.sh" 2>&1)"; then _fu_rc=0; else _fu_rc=$?; fi
case "$_fu_out" in
  *"unlisted-required-probe"*) _fu_named=1 ;;
  *) _fu_named=0 ;;
esac
case "$_fu_out" in
  *"docs/04-quality/TESTING.md"*) _fu_doc_path=1 ;;
  *) _fu_doc_path=0 ;;
esac
case "$_fu_out" in
  *"新規 suite 追加の随伴先"*) _fu_doc_section=1 ;;
  *) _fu_doc_section=0 ;;
esac
# unlisted-required-probe は SCRIPTS へ登録済みなので、登録漏れ分岐（run-all.sh:1118
# 付近）とここ（未掲載分岐・run-all.sh:1214 付近）は "unlisted-required-probe" /
# docs パス / 節名の3点とも共通して出す（両分岐が同じ案内文言を再利用しているため）。
# この3点だけでは AC2 の Given（登録済み・REQUIRED_SUITES 未掲載）を固定できず、
# SCRIPTS 側の登録付与だけを外した複製でも「未登録の suite があります」経由で
# 同じ3点が揃って偽の緑になる（実測）。未掲載側だけが出す固有文言の有無で分岐を縛る。
case "$_fu_out" in
  *"REQUIRED_SUITES に載っていない必須 suite"*) _fu_unlisted_branch=1 ;;
  *) _fu_unlisted_branch=0 ;;
esac
case "$_fu_out" in
  *"未登録の suite があります"*) _fu_unregistered_branch=1 ;;
  *) _fu_unregistered_branch=0 ;;
esac
if [ "$_fu_rc" -ne 0 ] && [ "$_fu_named" -eq 1 ] && [ "$_fu_doc_path" -eq 1 ] && [ "$_fu_doc_section" -eq 1 ] \
  && [ "$_fu_unlisted_branch" -eq 1 ] && [ "$_fu_unregistered_branch" -eq 0 ]; then
  ok "登録のみで随伴先未対応の suite を名指しし、随伴先一覧を持つ文書のパスも出す（AC2）"
else
  bad "未追随の名指し、または随伴先文書パスの案内が欠けている、もしくは未掲載分岐に縛れていない (rc=${_fu_rc} named=${_fu_named} doc_path=${_fu_doc_path} doc_section=${_fu_doc_section} unlisted_branch=${_fu_unlisted_branch} unregistered_branch=${_fu_unregistered_branch})"
  printf '%s\n' "$_fu_out" | sed 's/^/    | /' >&2
fi
rm -rf "$_fu_fx"

echo ""
echo "== case 39: dirty tree では既定一覧を起動せず、鮮度記録も作らない（起動ガード）=="

# ガードの対象は「引数なしの既定一覧」なので、疑似 suite を明示引数で渡す本 suite の通常経路では
# 一度も踏まれない。既定一覧の形を作るために、case 26 / case 38 と同じ awk で SCRIPTS と
# REQUIRED_SUITES を最小内容へ差し替えた複製ランナーを、**隔離した一時 git リポジトリ**の中へ置く
# （汚れ判定はランナー自身が在るリポジトリへ掛かるため、本リポジトリの作業ツリーを汚さずに
# dirty / clean の両方を作れる唯一の形）。記録器も同じ木へ写し、記録の中身まで観測する。
if ! command -v git >/dev/null 2>&1; then
  echo "  ○ skip: git が無いため dirty tree 起動ガードの実測をスキップ（case 39 の検査は 1 件も実行していません）"
else
_dg_fx="$RUN_WORK/ff-run-all-dirty-guard"
rm -rf "$_dg_fx"
mkdir -p "$_dg_fx/repo/tests/dirty-guard-probe" "$_dg_fx/repo/tests/dirty-guard-required-probe" "$_dg_fx/repo/scripts"
_dg_rec="$_dg_fx/gate-record"   # 記録先はリポジトリの外（記録の生成自体が木を汚さないように）
cat > "$_dg_fx/repo/tests/dirty-guard-probe/verify.sh" <<'PROBE'
#!/usr/bin/env bash
echo "FIXTURE-DIRTY-GUARD-EXECUTED"
exit 0
PROBE
# REQUIRED_SUITES を空配列にすると bash 3.2 の `${REQUIRED_SUITES[@]}` が set -u で unbound に
# なるため、名簿には 1 件残す。載せる以上は「suite 全体の skip 経路を持つ」必要があるので、
# case 26 と同じく**実行されない分岐**として材料だけ置く（実行時は skip せず pass する）。
cat > "$_dg_fx/repo/tests/dirty-guard-required-probe/verify.sh" <<'PROBE'
#!/usr/bin/env bash
if false; then
  echo "○ skip: 名簿掲載の材料（この分岐は実行されない）"
  exit 0
fi
exit 0
PROBE
chmod +x "$_dg_fx/repo/tests/dirty-guard-probe/verify.sh" "$_dg_fx/repo/tests/dirty-guard-required-probe/verify.sh"
awk '
  /^  SCRIPTS=\($/ {
    print
    print "    \"$SCRIPT_DIR/dirty-guard-probe/verify.sh\""
    print "    \"$SCRIPT_DIR/dirty-guard-required-probe/verify.sh\""
    in_scripts = 1
    next
  }
  in_scripts && /^  \)$/ { in_scripts = 0; print; next }
  in_scripts { next }
  /^REQUIRED_SUITES=\($/ {
    print
    print "  dirty-guard-required-probe"
    in_required = 1
    next
  }
  in_required && /^\)$/ { in_required = 0; print; next }
  in_required { next }
  # 空振り検出の免除名簿も fixture の名前へ差し替える（実体の名簿を残すと
  # 「実在しない名前」検査が先に落ちて本題まで届かない。REQUIRED_SUITES と同じ理由）
  /^MISS_PROBE_BASELINE=\($/ {
    print
    print "  dirty-guard-probe"
    print "  dirty-guard-required-probe"
    in_baseline = 1
    next
  }
  in_baseline && /^\)$/ { in_baseline = 0; print; next }
  in_baseline { next }
  { print }
' "$RUNNER" > "$_dg_fx/repo/tests/run-all.sh"
[ "$(grep -c '^  dirty-guard-probe$' "$_dg_fx/repo/tests/run-all.sh")" -eq 1 ] \
  || bad "case 39: 複製ランナーの MISS_PROBE_BASELINE 差し替えが適用されていない（見出し行の改稿で awk が空振り）"
cp "$TESTS_DIR/../scripts/record-gate-head.sh" "$_dg_fx/repo/scripts/record-gate-head.sh"

# 利用者のグローバル設定（署名・テンプレート）から独立させる。
_dg_git() { git -c commit.gpgsign=false -c user.email=t@example.invalid -c user.name=T -c init.defaultBranch=main "$@"; }
_dg_setup_rc=0
_dg_git -C "$_dg_fx/repo" init -q . >/dev/null 2>&1 || _dg_setup_rc=1
_dg_git -C "$_dg_fx/repo" add -A >/dev/null 2>&1 || _dg_setup_rc=1
_dg_git -C "$_dg_fx/repo" commit -qm "fixture" >/dev/null 2>&1 || _dg_setup_rc=1

_dg_runner="$_dg_fx/repo/tests/run-all.sh"
# 引数なしで複製ランナーを回す。モード変数と ALLOW_SKIP は常に落とす（外側から漏れるとその回だけ
# 別モードになる）。オプトアウトの有無だけを呼び出し側が "$@" で与える。
_dg_run() { # <env のオプション or 代入>...
  if RUN_OUT="$(env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL -u FF_RUN_ALL_ALLOW_SKIP "$@" \
    FF_RUN_ALL_JOBS=1 FF_GATE_RECORD_FILE="$_dg_rec" bash "$_dg_runner" 2>&1)"; then RUN_RC=0; else RUN_RC=$?; fi
}

# 同じ実行を stdout / stderr を**分けて**捕まえる版。統合してしまうと「警告を stdout へ出す」
# 変異が素通りするため、ストリームの別まで主張したいケース（case 40）はこちらを使う。捕捉先は
# 隔離リポジトリの**外**に置く（捕捉そのものが fixture の木を汚さないように）。
_dg_run_split() { # <env のオプション or 代入>...
  if env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL -u FF_RUN_ALL_ALLOW_SKIP "$@" \
    FF_RUN_ALL_JOBS=1 FF_GATE_RECORD_FILE="$_dg_rec" bash "$_dg_runner" \
    >"$_dg_fx/run.out" 2>"$_dg_fx/run.err"; then RUN_RC=0; else RUN_RC=$?; fi
  RUN_STDOUT="$(cat "$_dg_fx/run.out")"
  RUN_ERR="$(cat "$_dg_fx/run.err")"
  # 既存の expect_has / expect_lacks（統合ストリームを見る側）もそのまま使えるようにしておく。
  RUN_OUT="${RUN_STDOUT}
${RUN_ERR}"
}

if [ "$_dg_setup_rc" -ne 0 ]; then
  bad "case 39: 一時 git リポジトリの fixture を作れない（ガードの実測ができていない）"
else
  # 39-A: clean tree ではガードが無音で、従来どおり既定一覧が走る。
  rm -f "$_dg_rec"
  _dg_run -u FF_RUN_ALL_ALLOW_DIRTY
  expect_rc 0 "clean tree の引数なし実行は従来どおり rc=0"
  expect_has '^FIXTURE-DIRTY-GUARD-EXECUTED$' "clean tree では suite が実際に走る"
  expect_has "^suites: total=2 run=2 passed=2 failed=0 skipped=0 not-run=0$" "clean tree では従来どおりサマリーが出る"
  expect_lacks '未コミットの変更がある作業ツリー' "clean tree ではガードが無音（誤検知しない）"
  expect_lacks 'clean かどうかを確認できません' "clean tree では確認不能の分岐へ落ちない"
  # 依存判定の上書き告知（case 41 が「出ること」を測る側）は、**上書きしていない回に出ない**ことを
  # ここで測る。無条件化する変異を入れると、実運用の全ゲート実行に毎回、設定していない変数名の
  # 警告が乗る。case 41 は全ケースが上書き前提なので、不在を主張できるのはこの経路しかない。
  expect_lacks 'FF_RUN_ALL_MCP_DIR で依存判定の対象を上書き' "上書きしていない回は告知を出さない"

  # 39-B: 未追跡ファイル 1 件だけで止まること。判定を `git diff` 系（未追跡を見ない）へ退行させると
  # ここだけが赤くなる — 記録側 record-gate-head.sh は未追跡も汚れに数えるので、述語がずれると
  # 「ガードは通ったのに DIRTY=yes」が残る。
  rm -f "$_dg_rec"
  : > "$_dg_fx/repo/tests/dirty-guard-probe/scratch.txt"
  _dg_run -u FF_RUN_ALL_ALLOW_DIRTY
  expect_rc nz "未コミットの変更がある木では非 0 で終わる"
  expect_has '^✗ 未コミットの変更がある作業ツリーでは既定一覧のゲートを実行しません' "停止理由を出す"
  expect_has 'dirty-guard-probe/scratch.txt' "未コミットのパスを名指しする（未追跡ファイルも汚れに数える）"
  expect_has '変更をコミットしてから再実行してください' "コミットしてから再実行する旨を出す"
  expect_has 'FF_RUN_ALL_ALLOW_DIRTY=1' "オプトアウトの名前を案内する"
  expect_lacks '^FIXTURE-DIRTY-GUARD-EXECUTED$' "suite を 1 つも実行しない"
  expect_lacks '^suites: total=' "サマリー行を出さない（実行が成立していない）"
  if [ -e "$_dg_rec" ]; then
    bad "停止した実行が鮮度記録を作っている（記録より手前で止まっていない）"
  else
    ok "停止した実行は鮮度記録を作成・更新しない"
  fi

  # 39-C: 明示のオプトアウトなら従来どおり実行され、記録は従来どおり DIRTY=yes で書かれる。
  rm -f "$_dg_rec"
  _dg_run FF_RUN_ALL_ALLOW_DIRTY=1
  expect_rc 0 "オプトアウト付きなら dirty tree でも従来どおり rc=0"
  expect_has '^FIXTURE-DIRTY-GUARD-EXECUTED$' "オプトアウト付きなら suite が走る"
  expect_lacks '未コミットの変更がある作業ツリー' "オプトアウト付きではガードが停止しない"
  if [ -f "$_dg_rec" ] && grep -qF 'DIRTY=yes' "$_dg_rec"; then
    ok "オプトアウトの実行では鮮度記録が従来どおり DIRTY=yes で書かれる"
  else
    bad "オプトアウトの実行で DIRTY=yes の鮮度記録が書かれていない"
  fi

  # 39-D: 汚れているかを確認できない場合（リポジトリの外）は clean と断定せずに止める（fail-closed）。
  rm -f "$_dg_rec"
  mkdir -p "$_dg_fx/nogit"
  cp -R "$_dg_fx/repo/tests" "$_dg_fx/nogit/tests"
  cp -R "$_dg_fx/repo/scripts" "$_dg_fx/nogit/scripts"
  _dg_runner="$_dg_fx/nogit/tests/run-all.sh"
  _dg_run -u FF_RUN_ALL_ALLOW_DIRTY
  expect_rc nz "汚れを確認できない木（リポジトリの外）では非 0 で終わる"
  expect_has '^✗ 作業ツリーが clean かどうかを確認できません' "確認不能であることを明示する"
  expect_lacks '^FIXTURE-DIRTY-GUARD-EXECUTED$' "確認不能の回も suite を 1 つも実行しない"
  expect_lacks '^suites: total=' "確認不能の回はサマリー行を出さない"
  if [ -e "$_dg_rec" ]; then
    bad "確認不能で停止した実行が鮮度記録を作っている"
  else
    ok "確認不能で停止した実行は鮮度記録を作成・更新しない"
  fi


  echo ""
  echo "== case 40: 走行中に汚れた実行は終了時に fail-loud する（終了コードは suite の結果のみ）=="
  # 起動ガード（case 39）が見るのは起動時点だけなので、clean で起動して**走行中に**汚れる回を
  # 作る必要がある。case 39 の隔離リポジトリをそのまま使い、疑似 suite 自身に走行中の書き込みを
  # させる（実行順の制御が要らず、汚れる瞬間が確実に「起動ガードの後・終了時再評価の前」に入る
  # 唯一の形）。差し替えた疑似 suite は commit して、起動時点は clean に戻しておく。
  #
  # 出力の検査は stdout / stderr を**分けて**捕まえる（_dg_run_split）。統合（`2>&1`）して見ると
  # 「警告を stdout へ出す」変異が素通りする — この警告の要件は「目に入る」ことだけでなく、
  # 機械が読むサマリー（stdout）へ混ざらないことでもある。
  _dg_runner="$_dg_fx/repo/tests/run-all.sh"   # 39-D で nogit 側を向いているので戻す
  rm -f "$_dg_fx/repo/tests/dirty-guard-probe/scratch.txt"   # 39-B が置いた汚れを片付ける
  cat > "$_dg_fx/repo/tests/dirty-guard-probe/verify.sh" <<'PROBE'
#!/usr/bin/env bash
# 走行中に作業ツリーを汚す疑似 suite。20 行の打ち切りと残件数まで実測するため未追跡ファイルを
# 21 件作る（`git status --porcelain` はパス順に並ぶので、打ち切られる 1 件は必ず
# midrun-21.txt になる）。
_d="$(dirname "$0")"
for _i in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21; do
  : > "${_d}/midrun-${_i}.txt"
done
echo "FIXTURE-DIRTY-GUARD-EXECUTED"
exit 0
PROBE
  chmod +x "$_dg_fx/repo/tests/dirty-guard-probe/verify.sh"
  rm -f "$_dg_fx"/repo/tests/dirty-guard-probe/midrun-*.txt
  _dg_commit_rc=0
  _dg_git -C "$_dg_fx/repo" add -A >/dev/null 2>&1 || _dg_commit_rc=1
  _dg_git -C "$_dg_fx/repo" commit -qm "midrun probe" >/dev/null 2>&1 || _dg_commit_rc=1
  if [ "$_dg_commit_rc" -ne 0 ]; then
    bad "case 40: 走行中に汚れる fixture を commit できない（終了時再評価の実測ができていない）"
  else
    # 40-A: clean で起動 → 走行中に汚れる → サマリーの後に警告が **stderr へ** 出る。汚れたパスの
    # 一覧は 20 行で打ち切り、残件数を出す。記録は従来どおり DIRTY=yes。
    rm -f "$_dg_rec"
    _dg_run_split -u FF_RUN_ALL_ALLOW_DIRTY
    expect_rc 0 "走行中に汚れても終了コードは suite の結果だけで決まる（汚れで非 0 にしない）"
    expect_stdout_has '^FIXTURE-DIRTY-GUARD-EXECUTED$' "起動時は clean なので suite は実際に走る"
    expect_stdout_has "^suites: total=2 run=2 passed=2 failed=0 skipped=0 not-run=0$" "サマリーは従来どおり stdout に出る（実行結果は捨てない）"
    expect_err_has '作業ツリーが走行中に汚れたため、この実行は鮮度記録の証拠になりません' "終了時に stderr で fail-loud する"
    expect_stdout_lacks '作業ツリーが走行中に汚れたため' "警告を stdout へ混ぜない（サマリーを機械で読む側を壊さない）"
    expect_err_has 'dirty-guard-probe/midrun-01\.txt' "走行中に汚れたパスを stderr で名指しする"
    expect_stdout_lacks 'dirty-guard-probe/midrun-01\.txt' "汚れたパスの一覧も stdout へ混ぜない"
    expect_err_has 'dirty-guard-probe/midrun-20\.txt' "20 件目までは一覧に出す"
    expect_err_lacks 'dirty-guard-probe/midrun-21\.txt' "21 件目は 20 行の打ち切りで出さない"
    expect_err_has '… 他 1 件' "打ち切った残件数を出す（21 件中 20 件を出したので 1 件）"
    expect_lacks '未コミットの変更がある作業ツリー' "起動ガードの停止文言は出ない（起動時点は clean だった）"
    if [ -f "$_dg_rec" ] && grep -qF 'DIRTY=yes' "$_dg_rec"; then
      ok "走行中に汚れた実行の鮮度記録は従来どおり DIRTY=yes で書かれる"
    else
      bad "走行中に汚れた実行で DIRTY=yes の鮮度記録が書かれていない"
    fi

    # 40-B: clean のまま完走した回に追加の出力を出さない（誤検知しない側）。
    rm -f "$_dg_rec"
    cat > "$_dg_fx/repo/tests/dirty-guard-probe/verify.sh" <<'PROBE'
#!/usr/bin/env bash
echo "FIXTURE-DIRTY-GUARD-EXECUTED"
exit 0
PROBE
    chmod +x "$_dg_fx/repo/tests/dirty-guard-probe/verify.sh"
    rm -f "$_dg_fx"/repo/tests/dirty-guard-probe/midrun-*.txt
    _dg_commit_rc=0
    _dg_git -C "$_dg_fx/repo" add -A >/dev/null 2>&1 || _dg_commit_rc=1
    _dg_git -C "$_dg_fx/repo" commit -qm "clean probe" >/dev/null 2>&1 || _dg_commit_rc=1
    if [ "$_dg_commit_rc" -ne 0 ]; then
      bad "case 40: clean 完走の fixture を commit できない"
    else
      _dg_run -u FF_RUN_ALL_ALLOW_DIRTY
      expect_rc 0 "clean のまま完走した回は従来どおり rc=0"
      expect_has '^FIXTURE-DIRTY-GUARD-EXECUTED$' "clean 完走でも suite は走る"
      expect_lacks '走行中に汚れた' "clean のまま完走した回は追加の出力を出さない"
      expect_lacks '終了時に作業ツリーの状態を確認できませんでした' "clean 完走で確認不能の分岐へ落ちない"
    fi

    # 40-C: 起動時は clean だったのに終了時は汚れを**確認できない**回（確認不能の分岐）。
    # 39-D は起動ガード側の確認不能（リポジトリの外から起動）を縛るが、終了時の分岐は起動を
    # 通り抜けた回にしか入らないので、走行中に `.git` を退避する疑似 suite で作る。退避先は
    # リポジトリの外に置き、実行後に戻して 40-D の足場を壊さない。
    rm -f "$_dg_rec"
    cat > "$_dg_fx/repo/tests/dirty-guard-probe/verify.sh" <<'PROBE'
#!/usr/bin/env bash
# 走行中にリポジトリを読めなくする疑似 suite（.git を隔離リポジトリの外へ退避する）。起動
# ガードは通過済みなので、終了時の再評価だけが「確認不能」へ落ちる。
_repo="$(cd "$(dirname "$0")/../.." && pwd)"
mv "$_repo/.git" "$_repo/../git-off"
echo "FIXTURE-DIRTY-GUARD-EXECUTED"
exit 0
PROBE
    chmod +x "$_dg_fx/repo/tests/dirty-guard-probe/verify.sh"
    _dg_commit_rc=0
    _dg_git -C "$_dg_fx/repo" add -A >/dev/null 2>&1 || _dg_commit_rc=1
    _dg_git -C "$_dg_fx/repo" commit -qm "unreadable probe" >/dev/null 2>&1 || _dg_commit_rc=1
    if [ "$_dg_commit_rc" -ne 0 ]; then
      bad "case 40: 走行中に確認不能になる fixture を commit できない"
    else
      _dg_run_split -u FF_RUN_ALL_ALLOW_DIRTY
      # 退避した .git は結果を主張する前に戻す（以降のケースの足場）。
      if [ -d "$_dg_fx/git-off" ]; then mv "$_dg_fx/git-off" "$_dg_fx/repo/.git"; fi
      expect_rc 0 "確認不能でも終了コードは suite の結果だけで決まる"
      expect_stdout_has '^FIXTURE-DIRTY-GUARD-EXECUTED$' "確認不能になる回でも suite は走り切る"
      expect_stdout_has "^suites: total=2 run=2 passed=2 failed=0 skipped=0 not-run=0$" "確認不能でもサマリーは従来どおり出る"
      expect_err_has '終了時に作業ツリーの状態を確認できませんでした' "確認不能を黙って clean 扱いにせず stderr で言い切る"
      expect_err_lacks '走行中に汚れた' "確認不能の回に「汚れた」と断定しない（読めていない）"
      if [ -d "$_dg_fx/repo/.git" ]; then
        ok "case 40-C: 退避した .git を戻せた（後続ケースの足場が残る）"
      else
        bad "case 40-C: 退避した .git を戻せない（後続ケースの前提が壊れている）"
      fi
    fi

    # 40-D: 警告は**鮮度記録より前**に出る（AC「サマリーの直後・記録の前」の後半）。記録が実際に
    # 書かれる回は記録側が無言なので順序を観測できない。`FF_GATE_RECORD=0` の回だけ記録段が
    # stderr へ 1 行出すので、同じストリーム上の行番号で前後を主張できる。
    rm -f "$_dg_rec"
    cat > "$_dg_fx/repo/tests/dirty-guard-probe/verify.sh" <<'PROBE'
#!/usr/bin/env bash
: > "$(dirname "$0")/midrun.txt"
echo "FIXTURE-DIRTY-GUARD-EXECUTED"
exit 0
PROBE
    chmod +x "$_dg_fx/repo/tests/dirty-guard-probe/verify.sh"
    rm -f "$_dg_fx/repo/tests/dirty-guard-probe/midrun.txt"
    _dg_commit_rc=0
    _dg_git -C "$_dg_fx/repo" add -A >/dev/null 2>&1 || _dg_commit_rc=1
    _dg_git -C "$_dg_fx/repo" commit -qm "order probe" >/dev/null 2>&1 || _dg_commit_rc=1
    if [ "$_dg_commit_rc" -ne 0 ]; then
      bad "case 40: 出力順序を測る fixture を commit できない"
    else
      _dg_run_split -u FF_RUN_ALL_ALLOW_DIRTY FF_GATE_RECORD=0
      expect_rc 0 "FF_GATE_RECORD=0 の回も終了コードは suite の結果だけで決まる"
      expect_err_has '作業ツリーが走行中に汚れたため' "記録を止めた回でも走行中の汚れは fail-loud する"
      expect_err_has 'ゲート実測対象を記録しません' "FF_GATE_RECORD=0 の回は記録段が 1 行出す（順序の目印）"
      _dg_warn_ln="$(printf '%s\n' "$RUN_ERR" | grep -n '作業ツリーが走行中に汚れたため' | sed -n '1s/:.*//p' || true)"
      _dg_rec_ln="$(printf '%s\n' "$RUN_ERR" | grep -n 'ゲート実測対象を記録しません' | sed -n '1s/:.*//p' || true)"
      if [ -n "${_dg_warn_ln:-}" ] && [ -n "${_dg_rec_ln:-}" ] && [ "$_dg_warn_ln" -lt "$_dg_rec_ln" ]; then
        ok "警告は鮮度記録の段より前に出る（stderr 上の行番号 ${_dg_warn_ln} < ${_dg_rec_ln}）"
      else
        bad "警告が鮮度記録の段より前に出ていない (warn=${_dg_warn_ln:-none} record=${_dg_rec_ln:-none})"
        printf '%s\n' "$RUN_ERR" | sed 's/^/    | /' >&2
      fi
    fi
  fi
fi
rm -rf "$_dg_fx"
fi

echo ""
echo "== case 41: 同梱 MCP の依存が無い既定一覧は「環境の未整備」として起動前に止める =="

# ガードの対象は「引数なしの既定一覧」なので、疑似 suite を明示引数で渡す通常経路（case 37 ほか）
# では一度も踏まれない。case 39 と同じ awk で SCRIPTS / REQUIRED_SUITES を最小内容へ差し替えた
# 複製ランナーを隔離した一時 git リポジトリへ置き、**判定対象の mcp ディレクトリはリポジトリの外**
# に作る（FF_RUN_ALL_MCP_DIR で差し替える。リポジトリ内に作ると dirty ガードが先に
# 発火して、測りたいガードへ到達しない）。
if ! command -v git >/dev/null 2>&1; then
  echo "  ○ skip: git が無いため MCP 依存ガードの実測をスキップ（case 41 の検査は 1 件も実行していません）"
else
_mg_fx="$RUN_WORK/ff-run-all-mcp-deps-guard"
rm -rf "$_mg_fx"
mkdir -p "$_mg_fx/repo/tests/mcp-guard-probe" "$_mg_fx/repo/tests/mcp-guard-required-probe" "$_mg_fx/repo/scripts" "$_mg_fx/mcp"
# macOS の /var → /private/var を npm の lock 生成前に正規化する。
_mg_fx="$(cd -P "$_mg_fx" && pwd -P)"
_mg_rec="$_mg_fx/gate-record"
_mg_mcp="$_mg_fx/mcp"                 # ランナーへ渡す判定対象（mcp パッケージのディレクトリ）
_mg_nm="$_mg_mcp/node_modules"
_mg_esbuild="$_mg_nm/.bin/esbuild"
_mg_pkg="$_mg_mcp/package.json"
# ネットワークを使わない小さな実 npm fixture。センチネルだけを作る偽の正常系にしない。
mkdir -p "$_mg_fx/probe-dep/package"
printf '%s\n' '{"name":"preflight-probe-dev","version":"1.0.0"}' > "$_mg_fx/probe-dep/package/package.json"
tar -czf "$_mg_fx/probe-dev.tgz" -C "$_mg_fx/probe-dep" package
printf '%s\n' '{"name":"preflight-fixture","version":"1.0.0","devDependencies":{"preflight-probe-dev":"file:../probe-dev.tgz"}}' > "$_mg_pkg"
if ! npm install --prefix "$_mg_mcp" --package-lock-only --ignore-scripts --offline --no-audit --no-fund > "$_mg_fx/npm-setup.log" 2>&1; then
  cat "$_mg_fx/npm-setup.log"
  bad "case 41: npm fixture の lock を作成できない"
fi
# 配布 MCP と同じ semver 宣言へ揃える。取得先だけローカル tarball のままにして offline を保つ。
node - "$_mg_mcp" <<'FIXTURE_JSON'
const fs = require('node:fs');
const dir = process.argv[2];
for (const file of ['package.json', 'package-lock.json']) {
  const path = `${dir}/${file}`;
  const data = JSON.parse(fs.readFileSync(path, 'utf8'));
  const root = file === 'package.json' ? data : data.packages[''];
  root.devDependencies['preflight-probe-dev'] = '1.0.0';
  fs.writeFileSync(path, JSON.stringify(data, null, 2) + '\n');
}
FIXTURE_JSON
cp "$_mg_pkg" "$_mg_fx/package.json.saved"
_mg_install_deps() {
  cp "$_mg_fx/package.json.saved" "$_mg_pkg"
  if ! npm ci --prefix "$_mg_mcp" --include=dev --ignore-scripts --offline --no-audit --no-fund > "$_mg_fx/npm-setup.log" 2>&1; then
    cat "$_mg_fx/npm-setup.log"
    bad "case 41: npm ci の正対照を準備できない"
  fi
  mkdir -p "$_mg_nm/.bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$_mg_esbuild"
  chmod +x "$_mg_esbuild"
}
# rc は環境変数で切り替える（既定 0）。fixture の中身を書き換えると隔離リポジトリが dirty になり、
# dirty ガードが先に発火して測りたいガードへ到達しないため、ファイルは固定して外から振る。
cat > "$_mg_fx/repo/tests/mcp-guard-probe/verify.sh" <<'PROBE'
#!/usr/bin/env bash
echo "FIXTURE-MCP-GUARD-EXECUTED"
exit "${FIXTURE_MCP_GUARD_PROBE_RC:-0}"
PROBE
# case 39 と同じ理由（bash 3.2 の set -u）で必須名簿には 1 件残す。skip 経路は材料だけ置く。
cat > "$_mg_fx/repo/tests/mcp-guard-required-probe/verify.sh" <<'PROBE'
#!/usr/bin/env bash
if [ "${FIXTURE_MCP_GUARD_REQUIRED_SKIP:-0}" = "1" ]; then
  echo "○ skip: 依存が無いため（41-G が必須 skip 経路へ到達するための材料）"
  exit 0
fi
exit 0
PROBE
chmod +x "$_mg_fx/repo/tests/mcp-guard-probe/verify.sh" "$_mg_fx/repo/tests/mcp-guard-required-probe/verify.sh"
awk '
  /^  SCRIPTS=\($/ {
    print
    print "    \"$SCRIPT_DIR/mcp-guard-probe/verify.sh\""
    print "    \"$SCRIPT_DIR/mcp-guard-required-probe/verify.sh\""
    in_scripts = 1
    next
  }
  in_scripts && /^  \)$/ { in_scripts = 0; print; next }
  in_scripts { next }
  /^REQUIRED_SUITES=\($/ {
    print
    print "  mcp-guard-required-probe"
    in_required = 1
    next
  }
  in_required && /^\)$/ { in_required = 0; print; next }
  in_required { next }
  # 空振り検出の免除名簿も fixture の名前へ差し替える（実体の名簿を残すと
  # 「実在しない名前」検査が先に落ちて本題まで届かない。REQUIRED_SUITES と同じ理由）
  /^MISS_PROBE_BASELINE=\($/ {
    print
    print "  mcp-guard-probe"
    print "  mcp-guard-required-probe"
    in_baseline = 1
    next
  }
  in_baseline && /^\)$/ { in_baseline = 0; print; next }
  in_baseline { next }
  { print }
' "$RUNNER" > "$_mg_fx/repo/tests/run-all.sh"
[ "$(grep -c '^  mcp-guard-probe$' "$_mg_fx/repo/tests/run-all.sh")" -eq 1 ] \
  || bad "case 40: 複製ランナーの MISS_PROBE_BASELINE 差し替えが適用されていない（見出し行の改稿で awk が空振り）"
cp "$TESTS_DIR/../scripts/record-gate-head.sh" "$_mg_fx/repo/scripts/record-gate-head.sh"
# 41-G の停止文（scripts/lib/stop-block.sh）を実際の相対パスで読ませる（Issue `#2712`）
mkdir -p "$_mg_fx/repo/scripts/lib"
cp "$TESTS_DIR/../scripts/lib/stop-block.sh" "$_mg_fx/repo/scripts/lib/stop-block.sh"

_mg_git() { git -c commit.gpgsign=false -c user.email=t@example.invalid -c user.name=T -c init.defaultBranch=main "$@"; }
_mg_setup_rc=0
_mg_git -C "$_mg_fx/repo" init -q . >/dev/null 2>&1 || _mg_setup_rc=1
_mg_git -C "$_mg_fx/repo" add -A >/dev/null 2>&1 || _mg_setup_rc=1
_mg_git -C "$_mg_fx/repo" commit -qm "fixture" >/dev/null 2>&1 || _mg_setup_rc=1

_mg_run() { # <env のオプション or 代入>...
  rm -f "$_mg_rec"
  if RUN_OUT="$(env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL -u FF_RUN_ALL_ALLOW_SKIP \
    -u FF_RUN_ALL_ALLOW_MISSING_MCP_DEPS -u FIXTURE_MCP_GUARD_PROBE_RC -u FIXTURE_MCP_GUARD_REQUIRED_SKIP -u FF_GATE_RECORD -u FF_RUN_ALL_ALLOW_DIRTY -u FF_RUN_ALL_CHECK_REGISTRATION "$@" FF_RUN_ALL_JOBS=1 FF_RUN_ALL_MCP_DIR="$_mg_mcp" \
    FF_GATE_RECORD_FILE="$_mg_rec" bash "$_mg_fx/repo/tests/run-all.sh" 2>&1)"; then RUN_RC=0; else RUN_RC=$?; fi
}

if [ "$_mg_setup_rc" -ne 0 ]; then
  bad "case 41: 一時 git リポジトリの fixture を作れない（ガードの実測ができていない）"
else
  # 41-A: 入れる先（package.json）が在るのに node_modules が無い回は、suite を 1 つも実行せずに止まる。
  cp "$_mg_fx/package.json.saved" "$_mg_pkg"
  rm -rf "$_mg_nm"
  _mg_run
  expect_rc 3 "依存が無い既定一覧は環境分類の専用コード（3）で終わる（suite 失敗の 1 と区別できる）"
  expect_has '^✗ 環境が未整備です' "変更起因ではなく環境であることを先頭で名乗る"
  expect_has '^  次を実行してから回し直してください: npm ci --prefix plugins/ff-dev-toolkit/mcp' "復旧コマンドを出す（末尾の案内行ではなくガードの行であることまで固定する）"
  expect_has 'FF_RUN_ALL_ALLOW_MISSING_MCP_DEPS=1' "オプトアウトの名前を案内する"
  expect_lacks '^FIXTURE-MCP-GUARD-EXECUTED$' "suite を 1 つも実行しない（十数分を先に捨てない）"
  expect_lacks '^suites: total=' "サマリー行を出さない（実行が成立していない）"
  if [ -e "$_mg_rec" ]; then
    bad "停止した実行が鮮度記録を作っている（記録より手前で止まっていない）"
  else
    ok "停止した実行は鮮度記録を作成・更新しない"
  fi

  # 41-B: 依存が整っている通常環境ではガードが無音で、従来どおり既定一覧が走る（AC3）。
  _mg_install_deps
  _mg_run
  expect_rc 0 "依存が在る回は従来どおり rc=0"
  expect_has '^FIXTURE-MCP-GUARD-EXECUTED$' "依存が在る回は suite が実際に走る"
  expect_lacks '環境が未整備です' "依存が在る回はガードが無音（正常系で警告し続けない）"
  expect_lacks '^○ 案内: 同梱 MCP の依存が揃っていないため' "依存が在る回は末尾の案内も出ない"
  # 41-A の「停止した回は記録を作らない」は負の主張なので、記録器が一度も動かない fixture では
  # 空振りのまま緑になる。走った回に記録が**在る**ことを対で主張して足場を確かめる。
  if [ -f "$_mg_rec" ]; then
    ok "走りきった回は鮮度記録が書かれる（41-A の負の主張が空振りでないことの対）"
  else
    bad "走りきった回でも鮮度記録が書かれない（記録器の配線が壊れており 41-A が空振りする）"
  fi

  # 41-C: 入れる先が無い checkout（配布物・fixture 複製）では止めない。案内が成立しないうえ、
  # ここで止めると回せる実行を奪うだけになる。述語を「node_modules の不在」だけへ退行させると
  # このケースが赤くなる。
  rm -rf "$_mg_nm" "$_mg_pkg"
  _mg_run
  expect_rc 0 "mcp/package.json が無い checkout では止めない"
  expect_has '^FIXTURE-MCP-GUARD-EXECUTED$' "入れる先が無い回は従来どおり suite が走る"
  expect_lacks '環境が未整備です' "入れる先が無い回はガードが発火しない"

  # 41-D: 明示のオプトアウトなら従来どおり走り、実行後の案内行（原因の名指し）は残る。
  cp "$_mg_fx/package.json.saved" "$_mg_pkg"
  rm -rf "$_mg_nm"
  _mg_run FF_RUN_ALL_ALLOW_MISSING_MCP_DEPS=1
  expect_rc 0 "オプトアウト付きなら依存が無くても従来どおり走る"
  expect_has '^FIXTURE-MCP-GUARD-EXECUTED$' "オプトアウト付きなら suite が走る"
  expect_lacks '環境が未整備です' "オプトアウト付きではガードが停止しない"

  # 41-F: オプトアウトして suite が fail した回は、実行後の案内行が原因を名指しする。
  # ガードが既定一覧を止めるようになったぶん、この案内行へ到達するのは「明示引数」と「オプトアウト」の
  # 2 経路だけになった。判定対象 MCP_NODE_MODULES の解決を起動ガード側へ移した変更が、末尾の案内へ
  # 正しく共有されているかはここでしか観測できない（41-D は suite が全部 pass するので案内条件を満たさない）。
  _mg_run FF_RUN_ALL_ALLOW_MISSING_MCP_DEPS=1 FIXTURE_MCP_GUARD_PROBE_RC=1
  expect_rc nz "オプトアウトして suite が fail した回は従来どおり非 0"
  expect_has '^○ 案内: 同梱 MCP の依存が揃っていないため' "オプトアウト経路では実行後の案内行が残る"
  expect_has 'npm ci --prefix plugins/ff-dev-toolkit/mcp' "案内行に復旧コマンドを含む"

  # 41-G: オプトアウト経路で必須 suite が skip したとき、再現コマンドに前置が残る。
  # 前置を落とした案内をコピペすると起動ガードに止められ、案内どおりに再実行できない
  # （案内が自分で自分を無効化する）。fixture の必須 probe を skip させて到達させる。
  _mg_run FF_RUN_ALL_ALLOW_MISSING_MCP_DEPS=1 FIXTURE_MCP_GUARD_REQUIRED_SKIP=1
  expect_rc nz "必須 suite が skip した回は従来どおり非 0"
  expect_has '環境都合で消してはいけない suite が skip しました' "必須 skip の停止理由を出す"
  expect_has 'FF_RUN_ALL_ALLOW_MISSING_MCP_DEPS=1 FF_RUN_ALL_ALLOW_SKIP=' "再現コマンドにオプトアウト前置が残る（コピペで再実行できる）"
  # 出力の最後は停止文の共通形の 3 行（方針 / required-suite-skipped）で、次の一手に同じ再現コマンドが入る（Issue `#2712`）
  _mg_tail="$(printf '%s\n' "$RUN_OUT" | tail -n 3)"
  _mg_t1="$(printf '%s\n' "$_mg_tail" | sed -n 1p)"
  _mg_t2="$(printf '%s\n' "$_mg_tail" | sed -n 2p)"
  _mg_t3="$(printf '%s\n' "$_mg_tail" | sed -n 3p)"
  if [ "$_mg_t1" = '止めた層: 方針' ] \
    && case "$_mg_t2" in '止めた規則: required-suite-skipped（tests/run-all.sh）— '*) true ;; *) false ;; esac \
    && case "$_mg_t3" in '次の一手: '*'FF_RUN_ALL_ALLOW_MISSING_MCP_DEPS=1 FF_RUN_ALL_ALLOW_SKIP="'*'" bash tests/run-all.sh') true ;; *) false ;; esac \
    && [ "$(printf '%s\n' "$RUN_OUT" | grep -c '次の一手: ')" -eq 1 ]; then
    ok "必須 skip の停止は出力の最後を停止文の 3 行で終え、次の一手 1 行に再現コマンドを載せる"
  else
    bad "必須 skip の停止の末尾 3 行が停止文の共通形でない: [${_mg_tail}]"
  fi
  # 41-G2: 停止文の lib が先頭で exit しても run-all は非 0 で止まり、stop-block-unavailable の 3 行を残す
  # （lib を本体のシェルで読むと rc 0 で終わり、summary の failed=0 だけが残る。Issue `#2712`）
  cp "$_mg_fx/repo/scripts/lib/stop-block.sh" "$_mg_fx/stop-block.sh.saved"
  { printf '%s\n' 'exit 0'; cat "$_mg_fx/stop-block.sh.saved"; } >"$_mg_fx/repo/scripts/lib/stop-block.sh"
  # 写しの差し替えで fixture の作業ツリーが汚れるので、汚れた木の停止より先へ進めるため ALLOW_DIRTY を付ける
  _mg_run FF_RUN_ALL_ALLOW_DIRTY=1 FF_RUN_ALL_ALLOW_MISSING_MCP_DEPS=1 FIXTURE_MCP_GUARD_REQUIRED_SKIP=1
  expect_rc nz "停止文の lib が先頭で exit しても、必須 suite が skip した回は非 0"
  _mg_tail="$(printf '%s\n' "$RUN_OUT" | tail -n 3)"
  if [ "$(printf '%s\n' "$_mg_tail" | sed -n 1p)" = '止めた層: 方針' ] \
    && case "$(printf '%s\n' "$_mg_tail" | sed -n 2p)" in '止めた規則: stop-block-unavailable（scripts/lib/stop-block.sh）— '*) true ;; *) false ;; esac \
    && case "$(printf '%s\n' "$_mg_tail" | sed -n 3p)" in '次の一手: '*) true ;; *) false ;; esac; then
    ok "停止文の lib が先頭で exit しても、必須 skip の停止は stop-block-unavailable の 3 行で終わる"
  else
    bad "停止文の lib が先頭で exit すると、必須 skip の停止の末尾 3 行が stop-block-unavailable でない: [${_mg_tail}]"
  fi
  cp "$_mg_fx/stop-block.sh.saved" "$_mg_fx/repo/scripts/lib/stop-block.sh"

  # 41-H: install が不完全（node_modules は在るが .bin/esbuild が無い）な回も止める。
  # 述語をディレクトリの実在へ退行させるとここだけが赤くなる — npm ci --omit=dev / 中断した
  # install がこの状態を作り、下流 suite は「npm install が不完全」で赤くなる。
  cp "$_mg_fx/package.json.saved" "$_mg_pkg"
  rm -rf "$_mg_nm"
  mkdir -p "$_mg_nm"
  _mg_run
  expect_rc 3 "依存が在るが不完全な回も環境分類で止まる"
  expect_has '依存は展開されていますが依存照合に失敗しました' "「在るが足りない」を「まるごと無い」と別の文言で名乗る"
  expect_lacks '^FIXTURE-MCP-GUARD-EXECUTED$' "不完全な回も suite を 1 つも実行しない"

  # 41-M: esbuild が在っても、任意の devDependency が欠ければ起動しない。
  _mg_install_deps
  rm -rf "$_mg_nm/preflight-probe-dev"
  _mg_run FF_RUN_ALL_FULL=1 NODE_ENV=production npm_config_omit=dev npm_config_package_lock_only=true
  expect_rc 3 "esbuild が在っても欠落した devDependency を検出する（敵対 npm 設定下）"
  expect_has 'missing: preflight-probe-dev' "欠けた依存名を npm の診断で名指しする"
  expect_lacks '^FIXTURE-MCP-GUARD-EXECUTED$' "依存欠落時は suite を実行しない"

  # 41-N: 同じ敵対設定でも npm ci 直後は通る（無条件に赤い検査にしない）。
  _mg_install_deps
  _mg_run FF_RUN_ALL_FULL=1 NODE_ENV=production npm_config_omit=dev npm_config_package_lock_only=true
  expect_rc 0 "npm ci 直後は設定に左右されず全件を開始する"
  expect_has '^FIXTURE-MCP-GUARD-EXECUTED$' "正常系は suite を実行する"

  # 41-O: npm だけを PATH から除く。npm 以外は同じ実行物を symlink で供給する。
  mkdir -p "$_mg_fx/no-npm"
  for _mg_cmd in bash basename dirname git awk grep sort sed head tail wc tr cut cat date; do
    _mg_cmd_path="$(command -v "$_mg_cmd")"
    ln -s "$_mg_cmd_path" "$_mg_fx/no-npm/$_mg_cmd"
  done
  _mg_run FF_RUN_ALL_FULL=1 PATH="$_mg_fx/no-npm"
  expect_rc 3 "npm 不在は判定不能として rc 3"
  expect_has 'npm が PATH にありません' "npm 不在を名指しする"
  expect_lacks '^FIXTURE-MCP-GUARD-EXECUTED$' "npm 不在では suite を実行しない"

  # 41-P: lock 不在を npm ls の成功で緑へ倒さない。
  mv "$_mg_mcp/package-lock.json" "$_mg_fx/lock.saved"
  _mg_run FF_RUN_ALL_FULL=1
  expect_rc 3 "lock 不在は判定不能として rc 3"
  expect_has 'package-lock.json が無いか読めません' "lock 不在を名指しする"
  expect_lacks '^FIXTURE-MCP-GUARD-EXECUTED$' "lock 不在では suite を実行しない"
  mv "$_mg_fx/lock.saved" "$_mg_mcp/package-lock.json"

  # 41-I: 判定対象の上書きが効いている回は 1 行名乗る（無音の迂回路にしない）。
  # この上書きは検査専用だが、ガードの発火可否を決めるようになったので、黙って効くと
  # 「export したシェルでは以後すべての既定一覧ゲートが無防備」を作れてしまう。
  _mg_install_deps
  _mg_run
  expect_has 'FF_RUN_ALL_MCP_DIR で依存判定の対象を上書きしています' "上書きが効いている回は 1 行名乗る"

  # 41-J: 依存が無くても、**登録漏れ（変更起因の赤）は先に出る**。ガードを登録照合の前へ戻すと
  # ここが赤になる。この PR が意図的に動かした配置で、順序を主張する唯一のケース。
  cp "$_mg_fx/package.json.saved" "$_mg_pkg"
  rm -rf "$_mg_nm"
  mkdir -p "$_mg_fx/repo/tests/mcp-guard-unlisted-probe"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$_mg_fx/repo/tests/mcp-guard-unlisted-probe/verify.sh"
  chmod +x "$_mg_fx/repo/tests/mcp-guard-unlisted-probe/verify.sh"
  _mg_git -C "$_mg_fx/repo" add -A >/dev/null 2>&1 || true
  _mg_git -C "$_mg_fx/repo" commit -qm "unlisted probe" >/dev/null 2>&1 || true
  _mg_run
  expect_has '未登録の suite があります' "依存が無くても登録漏れ（変更起因の赤）は先に出る"
  expect_lacks '環境が未整備です' "登録漏れがある回は環境分類より先に登録照合で止まる"
  # 後続ケースのために未登録 probe を取り除いて commit し直す（木は clean へ戻す）。
  rm -rf "$_mg_fx/repo/tests/mcp-guard-unlisted-probe"
  _mg_git -C "$_mg_fx/repo" add -A >/dev/null 2>&1 || true
  _mg_git -C "$_mg_fx/repo" commit -qm "drop unlisted probe" >/dev/null 2>&1 || true

  # 41-K: 依存が無く、かつ木が汚れている回は **dirty 側が先に止める**（ガードを dirty の前へ
  # 移すと赤）。どちらも「実行しない」判断だが、汚れた木は依存を入れても証拠にならないので
  # 先に言う必要がある。
  : > "$_mg_fx/repo/tests/mcp-guard-probe/scratch.txt"
  _mg_run
  expect_has '未コミットの変更がある作業ツリー' "依存不足と dirty が同時なら dirty 側が先に止める"
  expect_lacks '環境が未整備です' "dirty で止まった回は環境分類の行を出さない"
  rm -f "$_mg_fx/repo/tests/mcp-guard-probe/scratch.txt"

  # 41-L: 検査専用モード（登録照合のみ）は依存が無くても回る。ガードを検査専用モードの早期 exit
  # より前へ移すと赤。実行も記録もしないモードを依存不足で止める理由が無い。
  _mg_run FF_RUN_ALL_CHECK_REGISTRATION=1
  expect_rc 0 "検査専用モードは依存が無くても回る"
  expect_lacks '環境が未整備です' "検査専用モードはガードの対象外"

  # 41-E: 解釈できない値は 1 行警告のうえガード有効のまま（fail-closed 側）。
  rm -rf "$_mg_nm"
  _mg_run FF_RUN_ALL_ALLOW_MISSING_MCP_DEPS=yes
  expect_rc 3 "解釈できない値ではガードが有効のまま（オプトアウトにならない）"
  expect_has 'FF_RUN_ALL_ALLOW_MISSING_MCP_DEPS="yes" は解釈できない値です' "解釈できない値を 1 行で警告する"
fi
rm -rf "$_mg_fx"
fi

echo ""
echo "== case 42: base の鮮度が原因の赤は failed の内訳として別行で名指しする（赤のまま） =="

# 並行して default branch が進む環境では、ブランチが古くなった瞬間に「base が HEAD の祖先」を
# 要求する検査が落ちる。その赤は変更の是非を語らないのに、従来は変更起因の赤と同じ形で出ていた。
# 分類だけを変え、**赤であることは変えない**（古い base で判定を諦めて skip へ倒すのは fail-open）。
run_runner "$FIXTURES/stale/verify.sh" "$FIXTURES/pass/verify.sh"
expect_rc nz "鮮度由来の赤でも従来どおり非 0 で終わる（skip へ倒さない）"
expect_has '^✗ failed: .*stale' "鮮度の suite は failed 一覧からも外さない（赤は赤のまま・名指しまで固定する）"
expect_has '^✗ stale (base が先行しているための赤を含む): ' "鮮度由来を別行で名指しする"
# サマリー行の指定インデント（2 スペース）まで固定する。fixture 側は復旧手段を出さないので、
# ここが一致するのはランナーが出した行だけである（fixture が同じ文言を出すと変異を吸収する）。
expect_has '^  取り込んでから回し直してください: git merge ' "取り込む側の復旧手段（merge）を出す"
expect_has '^  取り込んでから回し直してください: .*git rebase ' "履歴を畳む側の復旧手段（rebase）も同じ行に出す"
expect_has '取り込んでも同じ suite が赤いままなら、それは変更起因の赤です' "取り込んでも赤なら変更起因だと言い切る（鮮度で片付けさせない）"
expect_has '^FIXTURE-PASS-EXECUTED$' "鮮度の赤は後続 suite の実行を止めない"

# 変更起因の赤しか無い回に鮮度の行を出さない（正常系で毎回警告し続けない）。
run_runner "$FIXTURES/fail/verify.sh"
expect_rc nz "変更起因の赤は従来どおり非 0"
expect_lacks '^✗ stale ' "鮮度マーカーの無い赤では stale 行を出さない"
expect_lacks '取り込んでから回し直してください' "鮮度の案内も出さない"

# 緑の回にも出さない。
run_runner "$FIXTURES/pass/verify.sh"
expect_rc 0 "緑の回は従来どおり rc=0"
expect_lacks '^✗ stale ' "緑の回に stale 行を出さない"

# 行頭マーカーだけを拾う（部分 skip と同じ境界）。**非 0 で終わり、かつインデント付きで**
# 鮮度マーカーを引用しただけの suite は分類しない — この repo の標準ダンプ書式（`sed 's/^/    | /'`）
# は他 suite の出力をそのまま引用するので、部分一致へ緩むと変更起因の赤が鮮度として報告される。
run_runner "$FIXTURES/stale-indented/verify.sh"
expect_rc nz "インデント付き引用の suite も従来どおり赤"
expect_lacks '^✗ stale ' "インデント付きの鮮度マーカーは分類に使わない（行頭アンカー）"

# 鮮度マーカーを出しながら緑で終わる = 判定を諦めた fail-open。passed に数えつつ 1 行 fail-loud する。
run_runner "$FIXTURES/stale-green/verify.sh"
expect_rc 0 "緑で終わった suite の終了コードは変えない"
expect_lacks '^✗ stale ' "緑の suite は stale バケットへ入れない（STALE は FAILED の部分集合）"
expect_has '鮮度マーカーを出しながら緑で終わりました' "鮮度マーカー付きの緑は fail-loud する（分類は skip 経路ではない）"

# 既定は並列実行。分類が逐次経路にしか無いと、実運用では一度も出ない。
RUN_JOBS=2 run_runner "$FIXTURES/stale/verify.sh" "$FIXTURES/pass/verify.sh"
expect_rc nz "並列経路でも鮮度由来の赤は非 0"
expect_has '^✗ stale (base が先行しているための赤を含む): ' "並列経路でも鮮度バケットへ分類する"

run_runner "$FIXTURES/partial-skip/verify.sh"
expect_lacks '^✗ stale ' "鮮度と無関係な suite を巻き込まない"

# suite-cases-end: startup-guards.sh
