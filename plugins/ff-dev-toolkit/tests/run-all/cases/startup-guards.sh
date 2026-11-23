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

echo ""
echo "== case 54: 実行集合に tests/run-all/verify.sh を含む場合の並走早期停止と残骸マーカー回収 =="

if ! command -v git >/dev/null 2>&1; then
  bad "case 54: git が無いため隔離 repo 検証を実行できない"
else
_c54_fx="$RUN_WORK/ff-run-all-concurrent-stop"
rm -rf "$_c54_fx"
mkdir -p "$_c54_fx/repo/tests/run-all" "$_c54_fx/repo/tests/other-probe" "$_c54_fx/repo/tests/lib" "$_c54_fx/repo/scripts" "$_c54_fx/bin"
_c54_rec="$_c54_fx/gate-record"
cat > "$_c54_fx/repo/tests/run-all/verify.sh" <<'PROBE'
#!/usr/bin/env bash
echo "FIXTURE-C54-RUN-ALL-EXECUTED"
exit 0
PROBE
cat > "$_c54_fx/repo/tests/other-probe/verify.sh" <<'PROBE'
#!/usr/bin/env bash
if false; then
  echo "○ skip: material"
  exit 0
fi
echo "FIXTURE-C54-OTHER-EXECUTED"
exit 0
PROBE
chmod +x "$_c54_fx/repo/tests/run-all/verify.sh" "$_c54_fx/repo/tests/other-probe/verify.sh"
awk '
  /^  SCRIPTS=\($/ {
    print
    print "    \"$SCRIPT_DIR/run-all/verify.sh\""
    print "    \"$SCRIPT_DIR/other-probe/verify.sh\""
    in_scripts = 1
    next
  }
  in_scripts && /^  \)$/ { in_scripts = 0; print; next }
  in_scripts { next }
  /^REQUIRED_SUITES=\($/ {
    print
    print "  other-probe"
    in_required = 1
    next
  }
  in_required && /^\)$/ { in_required = 0; print; next }
  in_required { next }
  /^MISS_PROBE_BASELINE=\($/ {
    print
    print "  run-all"
    print "  other-probe"
    in_baseline = 1
    next
  }
  in_baseline && /^\)$/ { in_baseline = 0; print; next }
  in_baseline { next }
  { print }
' "$RUNNER" > "$_c54_fx/repo/tests/run-all.sh"
cp "$TESTS_DIR/lib/gate-in-flight.sh" "$_c54_fx/repo/tests/lib/gate-in-flight.sh"
if [ -f "$TESTS_DIR/lib/utf8-locale.sh" ]; then
  cp "$TESTS_DIR/lib/utf8-locale.sh" "$_c54_fx/repo/tests/lib/utf8-locale.sh"
fi
cp "$TESTS_DIR/../scripts/record-gate-head.sh" "$_c54_fx/repo/scripts/record-gate-head.sh"

_dg_git -C "$_c54_fx/repo" init -q . >/dev/null 2>&1 || true
_dg_git -C "$_c54_fx/repo" add -A >/dev/null 2>&1 || true
_dg_git -C "$_c54_fx/repo" commit -qm "c54-init" >/dev/null 2>&1 || true

_c54_real_ps="$(command -v ps)"
cat > "$_c54_fx/bin/ps" <<'STUB'
#!/usr/bin/env bash
real_ps="${C54_REAL_PS:?}"
if [ "${1:-}" = "-o" ]; then
  exec "$real_ps" "$@"
fi
if [ "${1:-}" = "-ww" ] && [ "${2:-}" = "-eo" ]; then
  case "${C54_GRAPH:-clean}" in
    fail) exit 1 ;;
  esac
  pid="$PPID"
  i=0
  while [ "$i" -lt 6 ] && [ -n "$pid" ] && [ "$pid" != 0 ] && [ "$pid" != 1 ]; do
    printf "%s 1 bash verify.sh\n" "$pid"
    pid="$("$real_ps" -o ppid= -p "$pid" 2>/dev/null | tr -d "[:space:]")" || exit 1
    i=$((i + 1))
  done
  if [ "${C54_GRAPH:-clean}" = "independent" ]; then
    printf "%s 1 bash /x/run-all.sh\n" "${C54_SLEEPER_PID:?}"
  fi
  exit 0
fi
if [ "${1:-}" = "-ww" ] && [ "${2:-}" = "-o" ] && [ "${3:-}" = "args=" ] && [ "${4:-}" = "-p" ]; then
  if [ "${5:-}" = "${C54_SLEEPER_PID:-}" ] && [ "${C54_GRAPH:-clean}" = "independent" ]; then
    printf "%s\n" "bash /x/run-all.sh"
    exit 0
  fi
  exit 1
fi
exec "$real_ps" "$@"
STUB
chmod +x "$_c54_fx/bin/ps"

_c54_runner="$_c54_fx/repo/tests/run-all.sh"
_c54_run() {
  local graph="$1"; shift
  if RUN_OUT="$(env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL -u FF_RUN_ALL_ALLOW_SKIP -u FF_RUN_ALL_CHANGED -u FF_RUN_ALL_ALLOW_DIRTY \
    -u FF_RUN_ALL_WAIT -u FF_RUN_ALL_WAIT_MAX_SECONDS -u FF_RUN_ALL_WAIT_POLL_INTERVAL \
    FF_RUN_ALL_JOBS=1 FF_GATE_RECORD_FILE="$_c54_rec" FF_RUN_ALL_WAIT_DIR="$_c54_fx/wait" \
    C54_GRAPH="$graph" C54_SLEEPER_PID=4194303 C54_REAL_PS="$_c54_real_ps" \
    PATH="$_c54_fx/bin:$PATH" \
    bash "$_c54_runner" "$@" 2>&1)"; then RUN_RC=0; else RUN_RC=$?; fi
}

rm -f "$_c54_rec"
_c54_run independent
expect_rc 2 "54-A: 既定一覧（run-all/verify.sh を含む）で他ゲート並走時は rc=2 で停止"
expect_has '判定不能: 別の全件ゲートが動いています' "54-A: 判定不能メッセージを出力"
expect_has '4194303:/x/run-all\.sh' "54-A: 並走プロセス PID とスクリプト名を名指し"
expect_has 'pgrep -f' "54-A: 復帰手順に誤判定注意の案内を含む"
expect_lacks 'FIXTURE-C54-RUN-ALL-EXECUTED' "54-A: run-all/verify.sh を 1 件も実行しない"
expect_lacks 'FIXTURE-C54-OTHER-EXECUTED' "54-A: 他 suite も 1 件も実行しない"
expect_lacks '^suites: total=' "54-A: サマリーを出さない"
[ ! -e "$_c54_rec" ] && ok "54-A: 停止回は gate-record を作成しない" || bad "54-A: 停止回が gate-record を作成した"

rm -f "$_c54_rec"
_c54_run independent "$_c54_fx/repo/tests/other-probe/verify.sh"
expect_rc 0 "54-B: run-all/verify.sh を含まない部分実行は並走時でも警告のみで続行する"
expect_has 'FIXTURE-C54-OTHER-EXECUTED' "54-B: 部分実行では対象 suite が実行される"
expect_has '起動時の負荷:' "54-B: 並走負荷の警告を出す"

rm -f "$_c54_rec"
_c54_run independent "$_c54_fx/repo/tests/run-all/verify.sh"
expect_rc 2 "54-C: 明示指定に run-all/verify.sh を含むときは並走時に rc=2 で停止"
expect_lacks 'FIXTURE-C54-RUN-ALL-EXECUTED' "54-C: 明示指定でも 1 件も実行しない"

rm -f "$_c54_rec"
_c54_run fail
expect_rc 2 "54-D: run-all/verify.sh を含む実行でプロセス一覧取得失敗時は rc=2 で停止"
expect_has '判定不能: プロセス一覧を取得できない' "54-D: プロセス取得不能の理由を出す"
expect_lacks 'FIXTURE-C54-RUN-ALL-EXECUTED' "54-D: 1 件も実行しない"
[ ! -e "$_c54_rec" ] && ok "54-D: プロセス取得不能時は gate-record を作成しない" || bad "54-D: gate-record が作られた"

_c54_mdir="$_c54_fx/repo/.git/ff-dev-toolkit/run-all-in-flight"
mkdir -p "$_c54_mdir"
printf 'Thu Jan  1 00:00:00 1970\n' > "$_c54_mdir/999999"
printf 'label=dead\ntree=%s\n' "$_c54_fx/repo" > "$_c54_mdir/999999.meta"
printf 'Thu Jan  1 00:00:00 1970\n' > "$_c54_mdir/$$"
printf 'label=reused\ntree=%s\n' "$_c54_fx/repo" > "$_c54_mdir/$$.meta"
rm -f "$_c54_rec"
_c54_run clean
expect_rc 0 "54-E: 死んだ PID と再利用 PID の残骸マーカーを自動回収して実行を完了する"
expect_has 'FIXTURE-C54-RUN-ALL-EXECUTED' "54-E: 残骸掃除後に全 suite が走る"
[ ! -e "$_c54_mdir/999999" ] && [ ! -e "$_c54_mdir/$$" ] \
  && ok "54-E: 非生存・PID 再利用の残骸マーカーを自動削除した" \
  || bad "54-E: 残骸マーカーが削除されていない"

sleep 30 &
_c54_sl_pid=$!
_c54_sl_start="$(LC_ALL=C TZ=UTC0 "$_c54_real_ps" -o lstart= -p "$_c54_sl_pid" 2>/dev/null || true)"
if [ -n "$_c54_sl_start" ]; then
  printf '%s\n' "$_c54_sl_start" > "$_c54_mdir/$_c54_sl_pid"
  printf 'label=live-marker-probe\ntree=%s\n' "$_c54_fx/repo" > "$_c54_mdir/${_c54_sl_pid}.meta"
  _c54_run clean
  expect_rc 2 "54-F: 独立した生存マーカー（lstart 一致）があれば ps に未検出でも rc=2 で停止"
  expect_has 'live-marker-probe' "54-F: 生存マーカーのラベルを名指しする"
  expect_lacks 'FIXTURE-C54-RUN-ALL-EXECUTED' "54-F: suite を実行しない"
else
  bad "54-F: テスト用スリーププロセスの lstart を取得できない"
fi
kill "$_c54_sl_pid" 2>/dev/null || true
wait "$_c54_sl_pid" 2>/dev/null || true
rm -f "$_c54_mdir/${_c54_sl_pid}" "$_c54_mdir/${_c54_sl_pid}.meta"

# 54-G: tests/run-all 配下を cwd にして ../run-all.sh ./verify.sh で呼んでも早期停止する
_c54_g_rc=0
_c54_g_out="$(cd "$_c54_fx/repo/tests/run-all" && env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL -u FF_RUN_ALL_ALLOW_SKIP -u FF_RUN_ALL_CHANGED -u FF_RUN_ALL_ALLOW_DIRTY \
  FF_RUN_ALL_JOBS=1 FF_GATE_RECORD_FILE="$_c54_rec" \
  C54_GRAPH="independent" C54_SLEEPER_PID=4194303 C54_REAL_PS="$_c54_real_ps" \
  PATH="$_c54_fx/bin:$PATH" bash ../run-all.sh ./verify.sh 2>&1)" || _c54_g_rc=$?
[ "$_c54_g_rc" -eq 2 ] && ok "54-G: tests/run-all から ./verify.sh 指定時も rc=2 で早期停止する" || bad "54-G: rc=$_c54_g_rc out=$_c54_g_out"

# 54-H: run-all-in-flight が symlink のときは安全側（rc=2）で止める
_c54_real_mdir="$_c54_mdir"
rm -rf "$_c54_mdir"
ln -s /nonexistent "$_c54_mdir"
_c54_run clean
expect_rc 2 "54-H: symlink 化した run-all-in-flight ディレクトリでは判定不能 rc=2 で停止する"
rm -f "$_c54_mdir"
mkdir -p "$_c54_real_mdir"

# 54-I: SIGTERM 中断時に走行中マーカーと .meta を即時回収する（EXIT trap 無し維持）
# TERM はマーカーの出現に加えて suite（sleep-probe）の起動の印を待ってから送る。run-all.sh は
# マーカーを作った後に INT / TERM の trap を置き、suite はその後に起動するので、印が在れば trap は
# 設置済み。マーカーの出現だけで送ると、作成から trap 設置までの隙間に届いた回は既定動作で死んで
# マーカーが残り、偽の赤になる（Issue `#2878`。出現直後に送る診断では 20/20 回が suite 未起動のまま残存）。
cat > "$_c54_fx/repo/tests/sleep-probe.sh" <<'SLPROBE'
#!/usr/bin/env bash
: > "${0%.sh}.started"
printf 'SLEEP_STARTED\n'
sleep 30
SLPROBE
chmod +x "$_c54_fx/repo/tests/sleep-probe.sh"
_c54_started="$_c54_fx/repo/tests/sleep-probe.started"
rm -f "$_c54_fx/term.log" "$_c54_started"
env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL -u FF_RUN_ALL_ALLOW_SKIP -u FF_RUN_ALL_CHANGED \
  -u FF_RUN_ALL_WAIT -u FF_RUN_ALL_WAIT_MAX_SECONDS -u FF_RUN_ALL_WAIT_POLL_INTERVAL \
  FF_RUN_ALL_ALLOW_DIRTY=1 FF_RUN_ALL_JOBS=1 FF_GATE_RECORD_FILE="$_c54_rec" FF_RUN_ALL_WAIT_DIR="$_c54_fx/wait" \
  C54_GRAPH="clean" C54_REAL_PS="$_c54_real_ps" PATH="$_c54_fx/bin:$PATH" \
  bash "$_c54_runner" "$_c54_fx/repo/tests/sleep-probe.sh" > "$_c54_fx/term.log" 2>&1 &
_c54_term_pid=$!
_c54_w=0
while [ "$_c54_w" -lt 100 ] && { [ ! -e "$_c54_mdir/${_c54_term_pid}" ] || [ ! -e "$_c54_started" ]; }; do
  sleep 0.1
  _c54_w=$((_c54_w + 1))
done
if [ -e "$_c54_mdir/${_c54_term_pid}" ] && [ -e "$_c54_started" ]; then
  kill -TERM "$_c54_term_pid" 2>/dev/null || true
  if wait "$_c54_term_pid" 2>/dev/null; then _c54_term_rc=0; else _c54_term_rc=$?; fi
  if [ ! -e "$_c54_mdir/${_c54_term_pid}" ] && [ ! -e "$_c54_mdir/${_c54_term_pid}.meta" ]; then
    ok "54-I: SIGTERM 中断時に走行中マーカーと .meta を即時削除する"
  else
    bad "54-I: SIGTERM 中断後もマーカーが残存している"
  fi
  # マーカーは正常終了の後片付けでも消える。TERM を無視して suite を完走させた回（trap '' TERM など）を
  # 上の検査は区別できないので、trap が TERM を再送出して終了した（128 + 15）ことも確かめる。
  if [ "$_c54_term_rc" -eq 143 ]; then
    ok "54-I: run-all は TERM で終了した（rc=143。suite を完走させた正常終了ではない）"
  else
    bad "54-I: run-all が TERM で終了していない（rc=${_c54_term_rc}。期待は 143）"
  fi
else
  kill "$_c54_term_pid" 2>/dev/null || true
  wait "$_c54_term_pid" 2>/dev/null || true
  bad "54-I: TERM 検証用 run-all のマーカー設置と suite の起動を確認できなかった"
fi
rm -f "$_c54_fx/repo/tests/sleep-probe.sh" "$_c54_started" "$_c54_fx/term.log"

# 54-J: 並列モード（FF_RUN_ALL_JOBS=2）でも SIGTERM 時に実行中の子 suite を止め、完了後にマーカーを回収する
cat > "$_c54_fx/repo/tests/sleep-par.sh" <<SLPAR
#!/usr/bin/env bash
printf '%s\n' "\$\$" > "${_c54_fx}/par-child.pid"
sleep 30
SLPAR
chmod +x "$_c54_fx/repo/tests/sleep-par.sh"
rm -f "$_c54_fx/par-child.pid" "$_c54_fx/par.log"
env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL -u FF_RUN_ALL_ALLOW_SKIP -u FF_RUN_ALL_CHANGED \
  -u FF_RUN_ALL_WAIT -u FF_RUN_ALL_WAIT_MAX_SECONDS -u FF_RUN_ALL_WAIT_POLL_INTERVAL \
  FF_RUN_ALL_ALLOW_DIRTY=1 FF_RUN_ALL_JOBS=2 FF_GATE_RECORD_FILE="$_c54_rec" FF_RUN_ALL_WAIT_DIR="$_c54_fx/wait" \
  C54_GRAPH="clean" C54_REAL_PS="$_c54_real_ps" PATH="$_c54_fx/bin:$PATH" \
  bash "$_c54_runner" "$_c54_fx/repo/tests/sleep-par.sh" "$_c54_fx/repo/tests/other-probe/verify.sh" > "$_c54_fx/par.log" 2>&1 &
_c54_par_pid=$!
_c54_w=0
while [ "$_c54_w" -lt 60 ] && { [ ! -e "$_c54_mdir/${_c54_par_pid}" ] || [ ! -s "$_c54_fx/par-child.pid" ]; }; do
  sleep 0.1
  _c54_w=$((_c54_w + 1))
done
if [ -e "$_c54_mdir/${_c54_par_pid}" ] && [ -s "$_c54_fx/par-child.pid" ]; then
  _c54_cpid="$(cat "$_c54_fx/par-child.pid" 2>/dev/null || true)"
  kill -TERM "$_c54_par_pid" 2>/dev/null || true
  if wait "$_c54_par_pid" 2>/dev/null; then _c54_par_rc=0; else _c54_par_rc=$?; fi
  sleep 0.1
  if [ ! -e "$_c54_mdir/${_c54_par_pid}" ] && [ ! -e "$_c54_mdir/${_c54_par_pid}.meta" ]; then
    ok "54-J: 並列モードの SIGTERM 後も走行中マーカーと .meta を即時回収する"
  else
    bad "54-J: 並列モード SIGTERM 後もマーカーが残存している"
  fi
  # 54-I と同じ理由で、TERM を無視して子 suite の完了まで走った回（マーカーも子も正常終了で消える）を区別する。
  if [ "$_c54_par_rc" -eq 143 ]; then
    ok "54-J: 並列モードの run-all は TERM で終了した（rc=143）"
  else
    bad "54-J: 並列モードの run-all が TERM で終了していない（rc=${_c54_par_rc}。期待は 143）"
  fi
  if [ -n "$_c54_cpid" ] && ! kill -0 "$_c54_cpid" 2>/dev/null; then
    ok "54-J: 並列実行中の子 suite（PID ${_c54_cpid}）も TERM で停止した"
  else
    [ -n "$_c54_cpid" ] && kill -KILL "$_c54_cpid" 2>/dev/null || true
    bad "54-J: 親だけ終了し、バックグラウンドの子 suite（PID ${_c54_cpid}）が生き残った"
  fi
else
  kill "$_c54_par_pid" 2>/dev/null || true
  wait "$_c54_par_pid" 2>/dev/null || true
  bad "54-J: 並列 TERM 検証用 suite の起動・マーカー設置を確認できなかった"
fi
rm -f "$_c54_fx/repo/tests/sleep-par.sh" "$_c54_fx/par-child.pid" "$_c54_fx/par.log"

awk '
  /^  ff_startup_stop_if_concurrent$/ { print "  :"; next }
  { print }
' "$_c54_runner" > "$_c54_fx/run-all.mut.sh"
mv "$_c54_fx/run-all.mut.sh" "$_c54_runner"
_dg_git -C "$_c54_fx/repo" add -A >/dev/null 2>&1 || true
_dg_git -C "$_c54_fx/repo" commit -qm "c54-mut" >/dev/null 2>&1 || true
_c54_run independent
expect_rc 0 "54-M: 早期停止を無効化した変異は並走下でも rc=0 で通過する（54-A の検出力対照）"
expect_has 'FIXTURE-C54-RUN-ALL-EXECUTED' "54-M: 変異では suite が実際に走る"

rm -rf "$_c54_fx"
fi

echo
echo "== case 55: FF_RUN_ALL_WAIT=1 の自動待機・リリース待機・相互待ち回避・上限停止 =="

if ! command -v git >/dev/null 2>&1; then
  bad "case 55: git が無いため待機機能検証を実行できない"
else
_c55_fx="$RUN_WORK/ff-run-all-wait"
rm -rf "$_c55_fx"
mkdir -p "$_c55_fx/repo/tests/run-all" "$_c55_fx/repo/tests/ok-probe" "$_c55_fx/repo/tests/lib" \
  "$_c55_fx/repo/scripts" "$_c55_fx/bin" "$_c55_fx/wait" \
  "$_c55_fx/vtree/tests/run-all" "$_c55_fx/vtree/tests/lib"
_c55_rec="$_c55_fx/gate-record"
_c55_wdir="$_c55_fx/wait"
_c55_fake_ps="$_c55_fx/fake-ps.txt"
: > "$_c55_fake_ps"
_c55_events="$_c55_fx/events.log"
_c55_bg_pids=""

_c55_kill_bg() {
  local p=""
  for p in $_c55_bg_pids; do
    kill "$p" 2>/dev/null || true
    wait "$p" 2>/dev/null || true
  done
  _c55_bg_pids=""
}

cat > "$_c55_fx/repo/tests/run-all/verify.sh" <<'PROBE'
#!/usr/bin/env bash
echo "FIXTURE-C55-RUN-ALL"
exit 0
PROBE

cat > "$_c55_fx/repo/tests/ok-probe/verify.sh" <<'PROBE'
#!/usr/bin/env bash
if false; then
  echo "○ skip: material"
  exit 0
fi
if [ -n "${C55_EVENT_LOG:-}" ]; then
  printf 'OK_RAN\n' >> "$C55_EVENT_LOG"
fi
echo "FIXTURE-C55-OK"
exit 0
PROBE

cat > "$_c55_fx/repo/tests/slow-probe.sh" <<'PROBE'
#!/usr/bin/env bash
tag="${C55_PAR_TAG:-x}"
if [ -e "${C55_INSIDE_LOCK:?}" ]; then
  printf 'OVERLAP:%s\n' "$tag" >> "${C55_OVERLAP_LOG:?}"
fi
: > "${C55_INSIDE_LOCK:?}"
printf 'ENTER:%s:%s\n' "$tag" "$$" >> "${C55_OVERLAP_LOG:?}"
sleep 0.5
rm -f "${C55_INSIDE_LOCK:?}"
printf 'LEAVE:%s:%s\n' "$tag" "$$" >> "${C55_OVERLAP_LOG:?}"
exit 0
PROBE

chmod +x "$_c55_fx/repo/tests/run-all/verify.sh" "$_c55_fx/repo/tests/ok-probe/verify.sh" "$_c55_fx/repo/tests/slow-probe.sh"

awk '
  /^  SCRIPTS=\($/ {
    print
    print "    \"$SCRIPT_DIR/run-all/verify.sh\""
    print "    \"$SCRIPT_DIR/ok-probe/verify.sh\""
    in_scripts = 1
    next
  }
  in_scripts && /^  \)$/ { in_scripts = 0; print; next }
  in_scripts { next }
  /^REQUIRED_SUITES=\($/ {
    print
    print "  ok-probe"
    in_required = 1
    next
  }
  in_required && /^\)$/ { in_required = 0; print; next }
  in_required { next }
  /^MISS_PROBE_BASELINE=\($/ {
    print
    print "  run-all"
    print "  ok-probe"
    in_baseline = 1
    next
  }
  in_baseline && /^\)$/ { in_baseline = 0; print; next }
  in_baseline { next }
  { print }
' "$RUNNER" > "$_c55_fx/repo/tests/run-all.sh"

cp "$TESTS_DIR/lib/gate-in-flight.sh" "$_c55_fx/repo/tests/lib/gate-in-flight.sh"
if [ -f "$TESTS_DIR/lib/utf8-locale.sh" ]; then
  cp "$TESTS_DIR/lib/utf8-locale.sh" "$_c55_fx/repo/tests/lib/utf8-locale.sh"
fi
cp "$TESTS_DIR/../scripts/record-gate-head.sh" "$_c55_fx/repo/scripts/record-gate-head.sh"

_dg_git -C "$_c55_fx/repo" init -q . >/dev/null 2>&1 || true
_dg_git -C "$_c55_fx/repo" add -A >/dev/null 2>&1 || true
_dg_git -C "$_c55_fx/repo" commit -qm "c55-init" >/dev/null 2>&1 || true
_c55_gdir="$(_dg_git -C "$_c55_fx/repo" rev-parse --absolute-git-dir)"
_c55_mdir="${_c55_gdir}/ff-dev-toolkit/run-all-in-flight"
mkdir -p "$_c55_mdir"

{
  printf '#!/usr/bin/env bash\n'
  printf '# fixture run-all.sh for verify wait test\n'
  printf '# %s / %s\n' "$KEPT_SELFTEST_HEAD" "$KEPT_SELFTEST_TAIL"
  printf '# %s\n' "$STALE_MARKER_LITERAL"
  awk '
    /^# >>> ff-startup-other-gates$/ { g = 1 }
    g { print }
    /^# <<< ff-startup-other-gates$/ { exit }
  ' "$RUNNER"
} > "$_c55_fx/vtree/tests/run-all.sh"
printf '# %s\n' "$STALE_MARKER_LITERAL" > "$_c55_fx/vtree/tests/lib/stale-base.sh"
cp "$TESTS_DIR/lib/gate-in-flight.sh" "$_c55_fx/vtree/tests/lib/gate-in-flight.sh"
cp "$SCRIPT_DIR/verify.sh" "$_c55_fx/vtree/tests/run-all/verify.sh"
_dg_git -C "$_c55_fx/vtree" init -q . >/dev/null 2>&1 || true
_dg_git -C "$_c55_fx/vtree" add -A >/dev/null 2>&1 || true
_dg_git -C "$_c55_fx/vtree" commit -qm "c55-vtree" >/dev/null 2>&1 || true

_c55_real_ps="$(command -v ps)"
cat > "$_c55_fx/bin/ps" <<'STUB'
#!/usr/bin/env bash
real_ps="${C55_REAL_PS:?}"
fake_ps="${C55_FAKE_PS_FILE:-}"
if [ "${1:-}" = "-o" ]; then
  exec "$real_ps" "$@"
fi
if [ "${1:-}" = "-ww" ] && [ "${2:-}" = "-eo" ]; then
  case "${C55_GRAPH:-clean}" in
    fail) exit 1 ;;
  esac
  pid="$PPID"
  i=0
  if [ -n "${C55_FAKE_ROOT_PID:-}" ]; then
    while [ "$i" -lt 4 ] && [ -n "$pid" ] && [ "$pid" != 0 ] && [ "$pid" != 1 ]; do
      ppid="$("$real_ps" -o ppid= -p "$pid" 2>/dev/null | tr -d "[:space:]")" || exit 1
      if [ "$i" -eq 3 ] || [ -z "$ppid" ] || [ "$ppid" = 0 ] || [ "$ppid" = 1 ]; then
        printf "%s %s bash verify.sh\n" "$pid" "${C55_FAKE_ROOT_PID}"
        break
      fi
      printf "%s %s bash verify.sh\n" "$pid" "$ppid"
      pid="$ppid"
      i=$((i + 1))
    done
    printf "%s 1 %s\n" "${C55_FAKE_ROOT_PID}" "${C55_FAKE_ROOT_CMD:?}"
  else
    while [ "$i" -lt 10 ] && [ -n "$pid" ] && [ "$pid" != 0 ] && [ "$pid" != 1 ]; do
      ppid="$("$real_ps" -o ppid= -p "$pid" 2>/dev/null | tr -d "[:space:]")" || exit 1
      printf "%s %s bash verify.sh\n" "$pid" "${ppid:-1}"
      pid="$ppid"
      i=$((i + 1))
    done
  fi
  if [ "${C55_SHOW_SIBLING_RUNNERS:-0}" = "1" ] && [ -n "${C55_RUNNER_MATCH:-}" ]; then
    "$real_ps" -ww -eo pid=,ppid=,args= 2>/dev/null | awk -v me="$PPID" -v pat="$C55_RUNNER_MATCH" '
      NF >= 3 {
        p = $1; pp[p] = $2; raw[p] = $0; sub(/^[[:space:]]+/, "", raw[p])
      }
      END {
        for (p in raw) {
          if (p == me) continue
          if (index(raw[p], pat) > 0 || (pp[p] in raw && index(raw[pp[p]], pat) > 0)) {
            print raw[p]
          }
        }
      }
    ' || true
  fi
  if [ -n "$fake_ps" ] && [ -f "$fake_ps" ]; then
    while IFS='|' read -r fp fpp fa || [ -n "${fp:-}" ]; do
      [ -n "${fp:-}" ] || continue
      printf "%s %s %s\n" "$fp" "${fpp:-1}" "$fa"
    done < "$fake_ps"
  fi
  exit 0
fi
if [ "${1:-}" = "-ww" ] && [ "${2:-}" = "-o" ] && [ "${3:-}" = "args=" ] && [ "${4:-}" = "-p" ]; then
  target="${5:-}"
  if [ -n "${C55_FAKE_ROOT_PID:-}" ] && [ "$target" = "${C55_FAKE_ROOT_PID}" ]; then
    printf "%s\n" "${C55_FAKE_ROOT_CMD:?}"
    exit 0
  fi
  if [ -n "$fake_ps" ] && [ -f "$fake_ps" ]; then
    while IFS='|' read -r fp _fpp fa || [ -n "${fp:-}" ]; do
      if [ "$fp" = "$target" ]; then
        printf "%s\n" "$fa"
        exit 0
      fi
    done < "$fake_ps"
  fi
  exec "$real_ps" "$@"
fi
exec "$real_ps" "$@"
STUB
chmod +x "$_c55_fx/bin/ps"

_c55_runner="$_c55_fx/repo/tests/run-all.sh"
_c55_run_seq=0
_c55_run_log="$_c55_fx/run-0.log"
_c55_run_log_prepared=0
# 解除サブシェルを fork する前に呼び、今回の run 専用ログパスを確定・空作成する
# （前回 run のログ誤読と fork 後のパス食い違いを防ぐ）。_c55_run を通さない 55-L / 55-L2 は
# 呼び出し側で _c55_run_log_prepared=0 を明示リセットして同ログへ直接リダイレクトする。
_c55_prepare_log() {
  _c55_run_seq=$((_c55_run_seq + 1))
  _c55_run_log="$_c55_fx/run-${_c55_run_seq}.log"
  : > "$_c55_run_log"
  _c55_run_log_prepared=1
}
_c55_wait_for_log() { # <fixed-needle> [max-ticks] [log-file]
  local needle="$1" max_ticks="${2:-160}" logf="${3:-$_c55_run_log}" i=0
  while [ "$i" -lt "$max_ticks" ]; do
    if [ -f "$logf" ] && grep -qF -- "$needle" "$logf" 2>/dev/null; then
      return 0
    fi
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}
_c55_run() {
  if [ "$_c55_run_log_prepared" -eq 1 ]; then
    _c55_run_log_prepared=0
  else
    _c55_prepare_log
    _c55_run_log_prepared=0
  fi
  if env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL -u FF_RUN_ALL_ALLOW_SKIP -u FF_RUN_ALL_CHANGED -u FF_RUN_ALL_ALLOW_DIRTY \
    -u FF_RUN_ALL_WAIT -u FF_RUN_ALL_WAIT_MAX_SECONDS \
    FF_RUN_ALL_ALLOW_DIRTY=1 FF_RUN_ALL_JOBS=1 FF_GATE_RECORD_FILE="$_c55_rec" \
    FF_RUN_ALL_WAIT_DIR="$_c55_wdir" FF_RUN_ALL_WAIT_POLL_INTERVAL=0.1 \
    C55_FAKE_PS_FILE="$_c55_fake_ps" C55_REAL_PS="$_c55_real_ps" \
    PATH="$_c55_fx/bin:$PATH" \
    "$@" > "$_c55_run_log" 2>&1; then RUN_RC=0; else RUN_RC=$?; fi
  RUN_OUT="$(cat "$_c55_run_log" 2>/dev/null || true)"
}

# 55-A: 別の全件ゲート終了後に自動で開始する
: > "$_c55_events"
: > "$_c55_fake_ps"
rm -f "$_c55_rec"
sleep 15 &
_c55_sl=$!
_c55_bg_pids="$_c55_sl"
_c55_lstart="$(ff_gate_ps_lstart "$_c55_sl")"
printf '%s\n' "$_c55_lstart" > "$_c55_mdir/${_c55_sl}"
printf 'label=tests/run-all.sh\ntree=%s\n' "$_c55_fx/repo" > "$_c55_mdir/${_c55_sl}.meta"
_c55_prepare_log
(
  if _c55_wait_for_log "${_c55_sl}:tests/run-all.sh" 160 "$_c55_run_log"; then
    printf 'BLOCKER_CLEARED\n' >> "$_c55_events"
    rm -f "$_c55_mdir/${_c55_sl}" "$_c55_mdir/${_c55_sl}.meta"
    kill "$_c55_sl" 2>/dev/null || true
  else
    printf 'SYNC_TIMEOUT\n' >> "$_c55_events"
  fi
) &
_c55_bg_pids="$_c55_bg_pids $!"
_c55_run env FF_RUN_ALL_WAIT=1 FF_RUN_ALL_WAIT_MAX_SECONDS=10 C55_EVENT_LOG="$_c55_events" \
  bash "$_c55_runner" "$_c55_fx/repo/tests/ok-probe/verify.sh"
_c55_kill_bg
expect_rc 0 "55-A: 先行ゲート終了後に自動開始して rc=0"
expect_has '完了を待っています' "55-A: 待機メッセージを出力"
expect_has '先行処理の終了を確認しました' "55-A: 再開メッセージを出力"
expect_has 'FIXTURE-C55-OK' "55-A: 待機後に suite を実行"
if [ "$(tr '\n' ',' < "$_c55_events")" = "BLOCKER_CLEARED,OK_RAN," ]; then
  ok "55-A: 先行ゲート解除の後から suite が始まった"
else
  bad "55-A: 実行順が不正（$(cat "$_c55_events")）"
fi
if [ -z "$(find "$_c55_wdir/waiting" "$_c55_wdir/active" -mindepth 1 2>/dev/null)" ]; then
  ok "55-A: 完了後に waiting / active マーカーを片付ける"
else
  bad "55-A: 完了後にマーカーが残存している"
fi

# 55-B: public-layout/verify.sh 終了後に自動開始する
: > "$_c55_events"
printf '4194301|1|bash /x/public-layout/verify.sh\n' > "$_c55_fake_ps"
_c55_prepare_log
(
  if _c55_wait_for_log "4194301:/x/public-layout/verify.sh" 160 "$_c55_run_log"; then
    printf 'PUBLIC_LAYOUT_CLEARED\n' >> "$_c55_events"
    : > "$_c55_fake_ps"
  else
    printf 'SYNC_TIMEOUT\n' >> "$_c55_events"
  fi
) &
_c55_bg_pids="$!"
_c55_run env FF_RUN_ALL_WAIT=1 FF_RUN_ALL_WAIT_MAX_SECONDS=10 C55_EVENT_LOG="$_c55_events" \
  bash "$_c55_runner" "$_c55_fx/repo/tests/ok-probe/verify.sh"
_c55_kill_bg
: > "$_c55_fake_ps"
expect_rc 0 "55-B: public-layout 終了後に自動開始して rc=0"
expect_has '4194301:/x/public-layout/verify\.sh' "55-B: 待機対象に public-layout を名指し"
expect_has 'FIXTURE-C55-OK' "55-B: public-layout 解除後に suite を実行"

# 55-B2: 同一 run-all.sh 祖先の兄弟 public-layout/verify.sh は誤検知しない（負の対照）
printf '4194301|4194399|bash /x/public-layout/verify.sh\n' > "$_c55_fake_ps"
_c55_run env C55_FAKE_ROOT_PID=4194399 C55_FAKE_ROOT_CMD="bash /shared/run-all.sh" \
  FF_RUN_ALL_WAIT=1 FF_RUN_ALL_WAIT_MAX_SECONDS=2 \
  bash "$_c55_runner" "$_c55_fx/repo/tests/ok-probe/verify.sh"
: > "$_c55_fake_ps"
expect_rc 0 "55-B2: 同じ run-all.sh 祖先下の兄弟 public-layout では待たず rc=0"
expect_lacks '完了を待っています' "55-B2: 兄弟 public-layout で待たない"

# 55-C: リリース中マーカーおよび別 clone リリースプロセス終了後に自動開始する
: > "$_c55_events"
rm -rf "$_c55_gdir/ff-release-in-flight"
sleep 15 &
_c55_rel_sl=$!
_c55_bg_pids="$_c55_rel_sl"
mkdir -p "$_c55_gdir/ff-release-in-flight"
{
  printf 'token=c55tok\npid=%s\nhost=%s\nstarted=%s\nversion=1.2.3\n' \
    "$_c55_rel_sl" "$(hostname 2>/dev/null || echo unknown)" "$(date +%s)"
  printf 'lstart=%s\n' "$(ff_gate_ps_lstart "$_c55_rel_sl")"
} > "$_c55_gdir/ff-release-in-flight/info"
_c55_prepare_log
(
  if _c55_wait_for_log "release:${_c55_rel_sl}:scripts/release-dev-toolkit.sh" 160 "$_c55_run_log"; then
    printf 'RELEASE_CLEARED\n' >> "$_c55_events"
    rm -rf "$_c55_gdir/ff-release-in-flight"
    kill "$_c55_rel_sl" 2>/dev/null || true
  else
    printf 'SYNC_TIMEOUT\n' >> "$_c55_events"
  fi
) &
_c55_bg_pids="$_c55_bg_pids $!"
_c55_run env FF_RUN_ALL_WAIT=1 FF_RUN_ALL_WAIT_MAX_SECONDS=10 C55_EVENT_LOG="$_c55_events" \
  bash "$_c55_runner" "$_c55_fx/repo/tests/ok-probe/verify.sh"
_c55_kill_bg
rm -rf "$_c55_gdir/ff-release-in-flight"
expect_rc 0 "55-C: リリース終了後に自動開始して rc=0"
expect_has "release:${_c55_rel_sl}:scripts/release-dev-toolkit\\.sh" "55-C: 待機対象に release を名指し"
if [ "$(tr '\n' ',' < "$_c55_events")" = "RELEASE_CLEARED,OK_RAN," ]; then
  ok "55-C: リリース解除の後から suite が始まった"
else
  bad "55-C: リリース待機の順序が不正（$(cat "$_c55_events")）"
fi

# 55-C2: 別 clone の release-dev-toolkit.sh プロセスも追従 push 中を含め待機対象にする
: > "$_c55_events"
printf '4194305|1|bash /other-clone/scripts/release-dev-toolkit.sh\n' > "$_c55_fake_ps"
_c55_prepare_log
(
  if _c55_wait_for_log "release:4194305:/other-clone/scripts/release-dev-toolkit.sh" 160 "$_c55_run_log"; then
    printf 'CROSS_REL_CLEARED\n' >> "$_c55_events"
    : > "$_c55_fake_ps"
  else
    printf 'SYNC_TIMEOUT\n' >> "$_c55_events"
  fi
) &
_c55_bg_pids="$!"
_c55_run env FF_RUN_ALL_WAIT=1 FF_RUN_ALL_WAIT_MAX_SECONDS=10 C55_EVENT_LOG="$_c55_events" \
  bash "$_c55_runner" "$_c55_fx/repo/tests/ok-probe/verify.sh"
_c55_kill_bg
: > "$_c55_fake_ps"
expect_rc 0 "55-C2: 別 clone の release-dev-toolkit.sh 終了後に自動開始して rc=0"
expect_has 'release:4194305:/other-clone/scripts/release-dev-toolkit\.sh' "55-C2: 別 clone の release プロセスを名指し"
if [ "$(tr '\n' ',' < "$_c55_events")" = "CROSS_REL_CLEARED,OK_RAN," ]; then
  ok "55-C2: 別 clone の release 解除後に suite が始まった"
else
  bad "55-C2: 別 clone release 待機の順序が不正（$(cat "$_c55_events")）"
fi

# 55-C3: 祖先の release-dev-toolkit.sh プロセスでは自己待機しない（負の対照）
_c55_run env C55_FAKE_ROOT_PID=4194398 C55_FAKE_ROOT_CMD="bash /anc/scripts/release-dev-toolkit.sh" \
  FF_RUN_ALL_WAIT=1 FF_RUN_ALL_WAIT_MAX_SECONDS=2 \
  bash "$_c55_runner" "$_c55_fx/repo/tests/ok-probe/verify.sh"
expect_rc 0 "55-C3: 祖先の release プロセスでは待たず rc=0"
expect_lacks '完了を待っています' "55-C3: 祖先 release プロセスで待たない"

# 55-D: 自系譜（祖先）のリリースマーカーでは自己待機しない
rm -rf "$_c55_gdir/ff-release-in-flight"
mkdir -p "$_c55_gdir/ff-release-in-flight"
{
  printf 'token=self\npid=%s\nhost=%s\nstarted=%s\nversion=1.2.3\n' \
    "$$" "$(hostname 2>/dev/null || echo unknown)" "$(date +%s)"
  printf 'lstart=%s\n' "$(ff_gate_ps_lstart "$$")"
} > "$_c55_gdir/ff-release-in-flight/info"
_c55_run env FF_RUN_ALL_WAIT=1 FF_RUN_ALL_WAIT_MAX_SECONDS=2 \
  bash "$_c55_runner" "$_c55_fx/repo/tests/ok-probe/verify.sh"
rm -rf "$_c55_gdir/ff-release-in-flight"
expect_rc 0 "55-D: 祖先の release マーカーでは自己待機せず rc=0"
expect_lacks '完了を待っています' "55-D: 祖先リリースで待たない"
expect_has 'FIXTURE-C55-OK' "55-D: 即座に suite を実行"

# 55-E: 待機上限超過時は相手を名指しして rc=2（suite・記録は走らない）
rm -f "$_c55_rec"
sleep 15 &
_c55_sl=$!
_c55_bg_pids="$_c55_sl"
printf '%s\n' "$(ff_gate_ps_lstart "$_c55_sl")" > "$_c55_mdir/${_c55_sl}"
printf 'label=tests/run-all.sh\ntree=%s\n' "$_c55_fx/repo" > "$_c55_mdir/${_c55_sl}.meta"
_c55_run env FF_RUN_ALL_WAIT=1 FF_RUN_ALL_WAIT_MAX_SECONDS=1 \
  bash "$_c55_runner" "$_c55_fx/repo/tests/ok-probe/verify.sh"
rm -f "$_c55_mdir/${_c55_sl}" "$_c55_mdir/${_c55_sl}.meta"
_c55_kill_bg
expect_rc 2 "55-E: 上限超過時は rc=2 で停止"
expect_has '待機上限（1 秒）に達したため停止しました' "55-E: 上限超過メッセージを出力"
expect_has "${_c55_sl}:tests/run-all\\.sh" "55-E: 待っていた相手を名指しする"
# 名指しは上限超過の停止文より後ろでも確かめる。待機開始の ⏳ 行も相手を名指しするので、出力全体への
# 照合だけでは、停止文から名指しを落とす変異が ⏳ 行の出た回に通る（⏳ 行が出るかどうかは、上限 1 秒に
# 対する開始時刻の秒の位相で決まる）。
_c55_e_tail="${RUN_OUT#*待機上限（1 秒）に達したため停止しました}"
if [ "$_c55_e_tail" != "$RUN_OUT" ]; then
  case "$_c55_e_tail" in
    *"${_c55_sl}:tests/run-all.sh"*) ok "55-E: 上限超過の停止文の後ろで、待っていた相手を名指しする" ;;
    *) bad "55-E: 上限超過の停止文の後ろに、待っていた相手の名指しが無い" ;;
  esac
else
  bad "55-E: 上限超過の停止文が出力に無い（名指しの位置を確かめられない）"
fi
expect_lacks 'FIXTURE-C55-OK' "55-E: 上限超過時に suite を実行しない"
[ ! -e "$_c55_rec" ] && ok "55-E: 上限超過回は gate-record を作成しない" || bad "55-E: gate-record が作られた"
if [ -z "$(find "$_c55_wdir/waiting" "$_c55_wdir/active" -mindepth 1 2>/dev/null)" ]; then
  ok "55-E: 上限超過時に waiting / active マーカーを残さない"
else
  bad "55-E: 上限超過後にマーカーが残存"
fi

# 55-E2: 待機期限経過後に空きになってもゲートを開始しない（期限判定を枠取得より先に行う）
_c55_sync_ok="$_c55_fx/e2-synced"
rm -f "$_c55_sync_ok"
printf '4194306|1|bash /x/run-all.sh\n' > "$_c55_fake_ps"
_c55_prepare_log
(
  if _c55_wait_for_log "4194306:/x/run-all.sh" 160 "$_c55_run_log"; then
    : > "$_c55_fake_ps"
    : > "$_c55_sync_ok"
  fi
) &
_c55_bg_pids="$!"
_c55_run env FF_RUN_ALL_WAIT=1 FF_RUN_ALL_WAIT_MAX_SECONDS=1 FF_RUN_ALL_WAIT_POLL_INTERVAL=5 \
  bash "$_c55_runner" "$_c55_fx/repo/tests/ok-probe/verify.sh"
_c55_kill_bg
: > "$_c55_fake_ps"
expect_rc 2 "55-E2: 期限到達後にブロッカーが消えても開始せず rc=2 で停止"
expect_lacks 'FIXTURE-C55-OK' "55-E2: 期限到達後の空きでは suite を実行しない"
[ -e "$_c55_sync_ok" ] && ok "55-E2: 待機ログ出力後にブロッカー解除が実際に実行された" || bad "55-E2: ブロッカー解除の同期が成立しなかった"
rm -f "$_c55_sync_ok"

# 55-F: 同時に 2 本の FF_RUN_ALL_WAIT=1 を起動しても ps 経由の相手・子孫を相互除外して直列完走する
_c55_ov="$_c55_fx/overlap.log"
_c55_lockf="$_c55_fx/inside.lock"
rm -f "$_c55_ov" "$_c55_lockf"
env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL -u FF_RUN_ALL_ALLOW_SKIP -u FF_RUN_ALL_CHANGED -u FF_RUN_ALL_ALLOW_DIRTY \
  FF_RUN_ALL_ALLOW_DIRTY=1 FF_RUN_ALL_JOBS=1 FF_GATE_RECORD_FILE="$_c55_rec" \
  FF_RUN_ALL_WAIT=1 FF_RUN_ALL_WAIT_MAX_SECONDS=15 FF_RUN_ALL_WAIT_DIR="$_c55_wdir" FF_RUN_ALL_WAIT_POLL_INTERVAL=0.1 \
  C55_PAR_TAG="P1" C55_INSIDE_LOCK="$_c55_lockf" C55_OVERLAP_LOG="$_c55_ov" \
  C55_SHOW_SIBLING_RUNNERS=1 C55_RUNNER_MATCH="$_c55_runner" \
  C55_FAKE_PS_FILE="$_c55_fake_ps" C55_REAL_PS="$_c55_real_ps" PATH="$_c55_fx/bin:$PATH" \
  bash "$_c55_runner" "$_c55_fx/repo/tests/slow-probe.sh" > "$_c55_fx/p1.log" 2>&1 &
_c55_p1=$!
env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL -u FF_RUN_ALL_ALLOW_SKIP -u FF_RUN_ALL_CHANGED -u FF_RUN_ALL_ALLOW_DIRTY \
  FF_RUN_ALL_ALLOW_DIRTY=1 FF_RUN_ALL_JOBS=1 FF_GATE_RECORD_FILE="$_c55_rec" \
  FF_RUN_ALL_WAIT=1 FF_RUN_ALL_WAIT_MAX_SECONDS=15 FF_RUN_ALL_WAIT_DIR="$_c55_wdir" FF_RUN_ALL_WAIT_POLL_INTERVAL=0.1 \
  C55_PAR_TAG="P2" C55_INSIDE_LOCK="$_c55_lockf" C55_OVERLAP_LOG="$_c55_ov" \
  C55_SHOW_SIBLING_RUNNERS=1 C55_RUNNER_MATCH="$_c55_runner" \
  C55_FAKE_PS_FILE="$_c55_fake_ps" C55_REAL_PS="$_c55_real_ps" PATH="$_c55_fx/bin:$PATH" \
  bash "$_c55_runner" "$_c55_fx/repo/tests/slow-probe.sh" > "$_c55_fx/p2.log" 2>&1 &
_c55_p2=$!
if wait "$_c55_p1" 2>/dev/null; then _c55_rc1=0; else _c55_rc1=$?; fi
if wait "$_c55_p2" 2>/dev/null; then _c55_rc2=0; else _c55_rc2=$?; fi
if [ "$_c55_rc1" -eq 0 ] && [ "$_c55_rc2" -eq 0 ]; then
  ok "55-F: 同時起動した 2 本の FF_RUN_ALL_WAIT=1 が相互待ちせず両方 rc=0 で完走"
else
  bad "55-F: 同時待機のいずれかが失敗（rc1=${_c55_rc1} rc2=${_c55_rc2}）"
fi
if grep -qF '完了を待っています' "$_c55_fx/p1.log" "$_c55_fx/p2.log" 2>/dev/null; then
  ok "55-F: 後続が実際に待機して順番待ちした"
else
  bad "55-F: 後続に待機ログが出ていない"
fi
if [ -f "$_c55_ov" ] && [ "$(grep -c '^ENTER:' "$_c55_ov" || true)" -eq 2 ] \
    && [ "$(grep -c '^LEAVE:' "$_c55_ov" || true)" -eq 2 ] \
    && [ "$(grep -c '^OVERLAP:' "$_c55_ov" || true)" -eq 0 ]; then
  ok "55-F: 2 本の実行区間が重ならず直列に並んだ"
else
  bad "55-F: 実行区間に重なりまたは欠落がある（$(cat "$_c55_ov" 2>/dev/null || true)）"
fi

# 55-G: 待機中（waiting）プロセスとその子孫サブシェルは非待機の並走停止・負荷警告に含めない
_c55_wchild_f="$_c55_fx/wchild.pid"
rm -f "$_c55_wchild_f"
bash -c 'sleep 20 & echo "$!" > "'"$_c55_wchild_f"'"; wait' &
_c55_wsl=$!
_c55_bg_pids="$_c55_wsl"
_c55_ww=0
while [ "$_c55_ww" -lt 30 ] && [ ! -s "$_c55_wchild_f" ]; do
  sleep 0.05
  _c55_ww=$((_c55_ww + 1))
done
_c55_wchild="$(cat "$_c55_wchild_f" 2>/dev/null || true)"
[ -n "$_c55_wchild" ] && _c55_bg_pids="$_c55_bg_pids $_c55_wchild"
mkdir -p "$_c55_wdir/waiting"
printf '%s\n' "$(ff_gate_ps_lstart "$_c55_wsl")" > "$_c55_wdir/waiting/${_c55_wsl}"
printf '%s|%s|bash /x/run-all.sh\n' "$_c55_wchild" "$_c55_wsl" > "$_c55_fake_ps"
_c55_run bash "$_c55_runner"
expect_rc 0 "55-G: waiting 祖先のサブシェル子プロセスも並走停止に数えず rc=0"
expect_has 'FIXTURE-C55-RUN-ALL' "55-G: run-all/verify.sh が実行される"
expect_has 'FIXTURE-C55-OK' "55-G: ok-probe が実行される"
expect_lacks '他ゲート .*run-all\.sh' "55-G: 起動時の負荷警告に待機側を混ぜない"

# 55-G2: waiting マーカーのない非待機兄弟プロセスは除外しない（負の対照）
sleep 20 &
_c55_nw=$!
_c55_bg_pids="$_c55_bg_pids $_c55_nw"
printf '%s|1|bash /x/run-all.sh\n' "$_c55_nw" > "$_c55_fake_ps"
_c55_run bash "$_c55_runner"
expect_rc 2 "55-G2: waiting マーカーのないプロセスは除外せず rc=2 で止まる"

# 55-H: 不正設定・symlink 待機領域は fail-closed rc=2
_c55_run env FF_RUN_ALL_WAIT=true \
  bash "$_c55_runner" "$_c55_fx/repo/tests/ok-probe/verify.sh"
expect_rc 2 "55-H: FF_RUN_ALL_WAIT=true（明示スイート）は rc=2（fail-closed）"
expect_lacks 'FIXTURE-C55-OK' "55-H: 不正 FF_RUN_ALL_WAIT=true で suite を実行しない"
_c55_run env FF_RUN_ALL_WAIT=yes \
  bash "$_c55_runner" "$_c55_fx/repo/tests/ok-probe/verify.sh"
expect_rc 2 "55-H: FF_RUN_ALL_WAIT=yes は rc=2（fail-closed）"
_c55_run env FF_RUN_ALL_WAIT=1 FF_RUN_ALL_WAIT_MAX_SECONDS=0 \
  bash "$_c55_runner" "$_c55_fx/repo/tests/ok-probe/verify.sh"
expect_rc 2 "55-H: FF_RUN_ALL_WAIT_MAX_SECONDS=0 は rc=2（fail-closed）"
_c55_run env FF_RUN_ALL_WAIT=1 FF_RUN_ALL_WAIT_MAX_SECONDS=abc \
  bash "$_c55_runner" "$_c55_fx/repo/tests/ok-probe/verify.sh"
expect_rc 2 "55-H: FF_RUN_ALL_WAIT_MAX_SECONDS=abc は rc=2（fail-closed）"
_c55_run env FF_RUN_ALL_WAIT=1 FF_RUN_ALL_WAIT_MAX_SECONDS=86401 \
  bash "$_c55_runner" "$_c55_fx/repo/tests/ok-probe/verify.sh"
expect_rc 2 "55-H: FF_RUN_ALL_WAIT_MAX_SECONDS=86401 は rc=2（fail-closed）"
ln -s "$_c55_wdir" "$_c55_fx/wait-link"
_c55_run env FF_RUN_ALL_WAIT=1 FF_RUN_ALL_WAIT_MAX_SECONDS=3 FF_RUN_ALL_WAIT_DIR="$_c55_fx/wait-link" \
  bash "$_c55_runner" "$_c55_fx/repo/tests/ok-probe/verify.sh"
rm -f "$_c55_fx/wait-link"
expect_rc 2 "55-H: symlink の FF_RUN_ALL_WAIT_DIR は rc=2（fail-closed）"
expect_lacks 'FIXTURE-C55-OK' "55-H: 不正待機領域で suite を実行しない"

# 55-K: 死んだ PID の残骸 start.lock は自動回収し、生存中 start.lock は過剰回収しない
rm -rf "$_c55_wdir/waiting" "$_c55_wdir/active" "$_c55_wdir/start.lock"
: > "$_c55_fake_ps"
_c55_kill_bg
sleep 0 &
_c55_dead=$!
wait "$_c55_dead" 2>/dev/null || true
mkdir -p "$_c55_wdir/start.lock"
printf 'token=deadtok\npid=%s\nlstart=Thu Jan  1 00:00:00 1970\nstarted=1\n' "$_c55_dead" > "$_c55_wdir/start.lock/info"
_c55_run env FF_RUN_ALL_WAIT=1 FF_RUN_ALL_WAIT_MAX_SECONDS=5 \
  bash "$_c55_runner" "$_c55_fx/repo/tests/ok-probe/verify.sh"
expect_rc 0 "55-K: 死んだ PID の start.lock を回収して rc=0"
[ ! -e "$_c55_wdir/start.lock" ] && [ ! -e "$_c55_wdir/start-reclaim.lock" ] && ok "55-K: 回収後の start.lock と start-reclaim.lock が解放されている" || bad "55-K: ロックが残存している"

mkdir -p "$_c55_wdir/start.lock" "$_c55_wdir/start-reclaim.lock"
printf 'token=deadtok\npid=%s\nlstart=Thu Jan  1 00:00:00 1970\nstarted=1\n' "$_c55_dead" > "$_c55_wdir/start.lock/info"
printf 'token=deadrel\npid=%s\nlstart=Thu Jan  1 00:00:00 1970\nstarted=1\n' "$_c55_dead" > "$_c55_wdir/start-reclaim.lock/info"
_c55_run env FF_RUN_ALL_WAIT=1 FF_RUN_ALL_WAIT_MAX_SECONDS=5 \
  bash "$_c55_runner" "$_c55_fx/repo/tests/ok-probe/verify.sh"
expect_rc 0 "55-K: 死んだ PID の start-reclaim.lock 残骸も回収して rc=0"
[ ! -e "$_c55_wdir/start.lock" ] && [ ! -e "$_c55_wdir/start-reclaim.lock" ] && ok "55-K: start-reclaim.lock 回収後に残存ロックがない" || bad "55-K: start-reclaim.lock が残存している"

sleep 15 &
_c55_alive_lk=$!
_c55_bg_pids="$_c55_alive_lk"
mkdir -p "$_c55_wdir/start.lock"
printf 'token=livetok\npid=%s\nlstart=%s\nstarted=1\n' \
  "$_c55_alive_lk" "$(ff_gate_ps_lstart "$_c55_alive_lk")" > "$_c55_wdir/start.lock/info"
_c55_run env FF_RUN_ALL_WAIT=1 FF_RUN_ALL_WAIT_MAX_SECONDS=1 \
  bash "$_c55_runner" "$_c55_fx/repo/tests/ok-probe/verify.sh"
_c55_kill_bg
rm -rf "$_c55_wdir/start.lock"
expect_rc 2 "55-K: 生存中 PID の start.lock は 60 秒経過扱いでも過剰回収せず rc=2"
expect_has 'start-lock:' "55-K: start-lock 待機中の理由を名指し"

# 55-L: 待機明け（GATE_DID_WAIT=1）の clean 再確認と新 HEAD の記録更新（ALLOW_DIRTY なし）
_c55_sync_ok="$_c55_fx/l1-synced"
rm -f "$_c55_sync_ok"
: > "$_c55_fake_ps"
printf '4194307|1|bash /x/run-all.sh\n' > "$_c55_fake_ps"
_c55_prepare_log
(
  if _c55_wait_for_log "4194307:/x/run-all.sh" 160 "$_c55_run_log"; then
    printf '# dirty during wait\n' >> "$_c55_fx/repo/tests/ok-probe/verify.sh"
    : > "$_c55_sync_ok"
    : > "$_c55_fake_ps"
  fi
) &
_c55_bg_pids="$!"
_c55_run_log_prepared=0
if env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL -u FF_RUN_ALL_ALLOW_SKIP -u FF_RUN_ALL_CHANGED -u FF_RUN_ALL_ALLOW_DIRTY \
  FF_RUN_ALL_JOBS=1 FF_GATE_RECORD_FILE="$_c55_rec" FF_RUN_ALL_WAIT=1 FF_RUN_ALL_WAIT_MAX_SECONDS=10 \
  FF_RUN_ALL_WAIT_DIR="$_c55_wdir" FF_RUN_ALL_WAIT_POLL_INTERVAL=0.1 \
  C55_FAKE_PS_FILE="$_c55_fake_ps" C55_REAL_PS="$_c55_real_ps" PATH="$_c55_fx/bin:$PATH" \
  bash "$_c55_runner" > "$_c55_run_log" 2>&1; then RUN_RC=0; else RUN_RC=$?; fi
RUN_OUT="$(cat "$_c55_run_log" 2>/dev/null || true)"
_c55_kill_bg
: > "$_c55_fake_ps"
_dg_git -C "$_c55_fx/repo" checkout -- tests/ok-probe/verify.sh >/dev/null 2>&1 || true
expect_rc 1 "55-L: 待機中に作業ツリーが汚れると終了せず rc=1 で止まる"
expect_has '待機中に作業ツリーが変更された' "55-L: 待機中の作業ツリー変更を検出して診断する"
expect_lacks 'FIXTURE-C55-OK' "55-L: 汚れた場合は suite を実行しない"
[ -e "$_c55_sync_ok" ] && ok "55-L(dirty): 待機ログ出力後に dirty 注入・解除が同期実行された" || bad "55-L(dirty): 同期が成立しなかった"
rm -f "$_c55_sync_ok"

rm -f "$_c55_rec"
_c55_sync_ok="$_c55_fx/l2-synced"
rm -f "$_c55_sync_ok"
printf '4194307|1|bash /x/run-all.sh\n' > "$_c55_fake_ps"
_c55_newhead_f="$_c55_fx/newhead.txt"
rm -f "$_c55_newhead_f"
_c55_prepare_log
(
  if _c55_wait_for_log "4194307:/x/run-all.sh" 160 "$_c55_run_log"; then
    printf 'added\n' > "$_c55_fx/repo/wait-head-advance.txt"
    git -C "$_c55_fx/repo" add wait-head-advance.txt
    _dg_git -C "$_c55_fx/repo" commit -qm "advance head during wait"
    git -C "$_c55_fx/repo" rev-parse HEAD > "$_c55_newhead_f"
    : > "$_c55_sync_ok"
    : > "$_c55_fake_ps"
  fi
) &
_c55_bg_pids="$!"
_c55_run_log_prepared=0
if env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL -u FF_RUN_ALL_ALLOW_SKIP -u FF_RUN_ALL_CHANGED -u FF_RUN_ALL_ALLOW_DIRTY \
  FF_RUN_ALL_JOBS=1 FF_GATE_RECORD_FILE="$_c55_rec" FF_RUN_ALL_WAIT=1 FF_RUN_ALL_WAIT_MAX_SECONDS=10 \
  FF_RUN_ALL_WAIT_DIR="$_c55_wdir" FF_RUN_ALL_WAIT_POLL_INTERVAL=0.1 \
  C55_FAKE_PS_FILE="$_c55_fake_ps" C55_REAL_PS="$_c55_real_ps" PATH="$_c55_fx/bin:$PATH" \
  bash "$_c55_runner" > "$_c55_run_log" 2>&1; then RUN_RC=0; else RUN_RC=$?; fi
RUN_OUT="$(cat "$_c55_run_log" 2>/dev/null || true)"
_c55_kill_bg
: > "$_c55_fake_ps"
expect_rc 0 "55-L: 待機中にコミットが進んだクリーンな再開で rc=0"
[ -e "$_c55_sync_ok" ] && ok "55-L(advance): 待機ログ出力後に HEAD 前進・解除が同期実行された" || bad "55-L(advance): 同期が成立しなかった"
rm -f "$_c55_sync_ok"
if [ -s "$_c55_newhead_f" ] && [ -s "$_c55_rec" ] && grep -qF "COMMIT=$(cat "$_c55_newhead_f")" "$_c55_rec"; then
  ok "55-L: gate-record に待機明けの最新 HEAD を記録した"
else
  bad "55-L: gate-record が待機前 HEAD のまま、または記録なし（$(cat "$_c55_rec" 2>/dev/null || true) / new=$(cat "$_c55_newhead_f" 2>/dev/null || true)）"
fi

# 55-N: 非待機モードでも public-layout / release 並走を検出して rc=2 で止まる
printf '4194301|1|bash /x/public-layout/verify.sh\n' > "$_c55_fake_ps"
_c55_run bash "$_c55_runner"
: > "$_c55_fake_ps"
expect_rc 2 "55-N: 非待機モードで別ツリー public-layout 検出時は rc=2"
expect_has '4194301:/x/public-layout/verify\.sh' "55-N: 非待機で public-layout を名指し"

sleep 15 &
_c55_rel_nw=$!
_c55_bg_pids="$_c55_rel_nw"
mkdir -p "$_c55_gdir/ff-release-in-flight"
{
  printf 'token=nw\npid=%s\nhost=%s\nstarted=%s\nversion=1.2.3\n' \
    "$_c55_rel_nw" "$(hostname 2>/dev/null || echo unknown)" "$(date +%s)"
  printf 'lstart=%s\n' "$(ff_gate_ps_lstart "$_c55_rel_nw")"
} > "$_c55_gdir/ff-release-in-flight/info"
_c55_run bash "$_c55_runner"
_c55_kill_bg
rm -rf "$_c55_gdir/ff-release-in-flight"
expect_rc 2 "55-N: 非待機モードで生存中リリース検出時は rc=2"
expect_has 'release:' "55-N: 非待機で release を名指し"
expect_has '--take-over' "55-N: 非待機の release 停止文に復帰手段を含む"

# 55-I: 単体 tests/run-all/verify.sh は別のゲートを待たない（観測を自分の系譜へ閉じるので、待つ
# 相手が居ない。ADR-095）。別の run-all.sh が終わらずに見え続けていても、待機の指定と上限 1 秒を
# 持ち込まれても、時間切れにならず隔離を通過する。
: > "$_c55_fake_ps"
rm -f "$_c55_wdir/waiting/${_c55_wsl:-none}"
_c55_kill_bg
printf '4194302|1|bash /x/run-all.sh\n' > "$_c55_fake_ps"
_c55_i_before="$(find "$_c55_wdir" -type f 2>/dev/null | sort)"
_c55_run env -u FF_RUN_ALL_NESTED FF_RUN_ALL_WAIT=1 FF_RUN_ALL_WAIT_MAX_SECONDS=1 FF_RUN_ALL_VERIFY_STOP_AFTER_GUARD=1 \
  bash "$_c55_fx/vtree/tests/run-all/verify.sh"
_c55_i_after="$(find "$_c55_wdir" -type f 2>/dev/null | sort)"
expect_rc 0 "55-I: 単体 run-all/verify.sh は別のゲートが動き続けていても rc=0 で隔離を通過する"
expect_has 'GUARD_PASSED' "55-I: GUARD_PASSED に到達"
expect_has '^ISOLATED_OTHER_GATES=none$' "55-I: 隔離した後の観測に別のゲートが現れない"
expect_lacks '4194302' "55-I: 単体 verify は別のゲートを待機対象として名指ししない"
expect_lacks '待機上限' "55-I: 単体 verify は待機の上限で止まらない（待機の指定を持ち込まない）"
expect_has '^ISOLATED_ENV=wait:unset nested:1 wait-dir:private$' "55-I: 内側の実行は、待機の指定なし・入れ子・私有の待機領域の環境を受け継ぐ"
if [ "$_c55_i_before" = "$_c55_i_after" ]; then
  ok "55-I: 単体 verify の起動の前後で、渡された待機領域の中身が変わらない（印を置かない）"
else
  bad "55-I: 単体 verify が渡された待機領域を変えた: 前=[${_c55_i_before}] 後=[${_c55_i_after}]"
fi
# 同じ並走を、ゲート（実行集合に run-all/verify.sh を含む）は従来どおり判定不能で止める
# （単体 verify を外しただけで、ゲート間の排他は残っていることの対照）。
_c55_run bash "$_c55_runner"
: > "$_c55_fake_ps"
expect_rc 2 "55-I: 同じ並走をゲートは従来どおり rc=2 で止める（ゲート間の排他は残る）"
expect_has '4194302:/x/run-all\.sh' "55-I: ゲートは並走を名指しする"

# 55-J: 待機中の SIGTERM で waiting マーカーとロックを消して rc=143 で終わる
printf '4194302|1|bash /x/run-all.sh\n' > "$_c55_fake_ps"
rm -f "$_c55_fx/wait-term.log"
env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL -u FF_RUN_ALL_ALLOW_SKIP -u FF_RUN_ALL_CHANGED -u FF_RUN_ALL_ALLOW_DIRTY \
  FF_RUN_ALL_ALLOW_DIRTY=1 FF_RUN_ALL_JOBS=1 FF_GATE_RECORD_FILE="$_c55_rec" \
  FF_RUN_ALL_WAIT=1 FF_RUN_ALL_WAIT_MAX_SECONDS=30 FF_RUN_ALL_WAIT_DIR="$_c55_wdir" FF_RUN_ALL_WAIT_POLL_INTERVAL=0.1 \
  C55_FAKE_PS_FILE="$_c55_fake_ps" C55_REAL_PS="$_c55_real_ps" PATH="$_c55_fx/bin:$PATH" \
  bash "$_c55_runner" "$_c55_fx/repo/tests/ok-probe/verify.sh" > "$_c55_fx/wait-term.log" 2>&1 &
_c55_tpid=$!
_c55_w=0
while [ "$_c55_w" -lt 80 ]; do
  if [ -e "$_c55_wdir/waiting/${_c55_tpid}" ] && grep -qF '完了を待っています' "$_c55_fx/wait-term.log" 2>/dev/null; then
    break
  fi
  sleep 0.1
  _c55_w=$((_c55_w + 1))
done
if [ -e "$_c55_wdir/waiting/${_c55_tpid}" ]; then
  kill -TERM "$_c55_tpid" 2>/dev/null || true
  if wait "$_c55_tpid" 2>/dev/null; then _c55_trc=0; else _c55_trc=$?; fi
  if [ "$_c55_trc" -eq 143 ]; then
    ok "55-J: 待機中の SIGTERM は rc=143 で終了する"
  else
    bad "55-J: 待機中 SIGTERM の rc が 143 でない（rc=${_c55_trc}）"
  fi
  if [ ! -e "$_c55_wdir/waiting/${_c55_tpid}" ] && [ ! -e "$_c55_wdir/start.lock" ]; then
    ok "55-J: 待機中 SIGTERM 後に waiting マーカーと start.lock が残らない"
  else
    bad "55-J: 待機中 SIGTERM 後に状態ファイルが残存している"
  fi
else
  kill "$_c55_tpid" 2>/dev/null || true
  wait "$_c55_tpid" 2>/dev/null || true
  bad "55-J: 待機マーカーの出現を確認できなかった"
fi
: > "$_c55_fake_ps"
rm -f "$_c55_fx/wait-term.log"

# 55-L2: 待機中に別コミットで未登録 suite が増えたら、最新 HEAD 再評価（exec）で検出して rc=1 停止
_c55_l2_prev="$(git -C "$_c55_fx/repo" rev-parse HEAD)"
rm -f "$_c55_rec"
_c55_sync_ok="$_c55_fx/l2u-synced"
rm -f "$_c55_sync_ok"
printf '4194307|1|bash /x/run-all.sh\n' > "$_c55_fake_ps"
_c55_prepare_log
(
  if _c55_wait_for_log "4194307:/x/run-all.sh" 160 "$_c55_run_log"; then
    mkdir -p "$_c55_fx/repo/tests/unreg-after-wait"
    printf '#!/usr/bin/env bash\necho "UNREG_SHOULD_NOT_RUN"\nexit 0\n' > "$_c55_fx/repo/tests/unreg-after-wait/verify.sh"
    chmod +x "$_c55_fx/repo/tests/unreg-after-wait/verify.sh"
    git -C "$_c55_fx/repo" add tests/unreg-after-wait/verify.sh
    _dg_git -C "$_c55_fx/repo" commit -qm "add unregistered suite during wait"
    : > "$_c55_sync_ok"
    : > "$_c55_fake_ps"
  fi
) &
_c55_bg_pids="$!"
_c55_run_log_prepared=0
if env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL -u FF_RUN_ALL_ALLOW_SKIP -u FF_RUN_ALL_CHANGED -u FF_RUN_ALL_ALLOW_DIRTY \
  FF_RUN_ALL_JOBS=1 FF_GATE_RECORD_FILE="$_c55_rec" FF_RUN_ALL_WAIT=1 FF_RUN_ALL_WAIT_MAX_SECONDS=10 \
  FF_RUN_ALL_WAIT_DIR="$_c55_wdir" FF_RUN_ALL_WAIT_POLL_INTERVAL=0.1 \
  C55_FAKE_PS_FILE="$_c55_fake_ps" C55_REAL_PS="$_c55_real_ps" PATH="$_c55_fx/bin:$PATH" \
  bash "$_c55_runner" > "$_c55_run_log" 2>&1; then RUN_RC=0; else RUN_RC=$?; fi
RUN_OUT="$(cat "$_c55_run_log" 2>/dev/null || true)"
_c55_kill_bg
: > "$_c55_fake_ps"
git -C "$_c55_fx/repo" reset -q --hard "$_c55_l2_prev" >/dev/null 2>&1 || true
rm -rf "$_c55_fx/repo/tests/unreg-after-wait"
expect_rc 1 "55-L2: 待機中に未登録 suite がコミットされたら新 HEAD 再評価で rc=1 停止"
expect_lacks 'UNREG_SHOULD_NOT_RUN' "55-L2: 待機前の一覧のまま suite を実行しない"
[ ! -e "$_c55_rec" ] && ok "55-L2: 新 HEAD 再評価の失敗時は gate-record を作らない" || bad "55-L2: 古い基準の gate-record が作られた"
[ -e "$_c55_sync_ok" ] && ok "55-L2: 待機ログ出力後に未登録 suite 追加・解除が同期実行された" || bad "55-L2: 同期が成立しなかった"
rm -f "$_c55_sync_ok"

# 55-O: 未検証のラッパー親候補が真の実行中子 run-all.sh を祖先畳み込みで隠さない
printf '4194310|1|bash /no/such/wrapper /x/other/tests/run-all.sh\n4194311|4194310|bash /x/other/tests/run-all.sh\n' > "$_c55_fake_ps"
_c55_run bash "$_c55_runner"
: > "$_c55_fake_ps"
expect_rc 2 "55-O: 未検証ラッパー親が真の子 run-all.sh を隠さず rc=2"
expect_has '4194311:/x/other/tests/run-all\.sh' "55-O: 真の子ゲートを名指し"

# 55-P: 単体 run-all/verify.sh は active マーカーを置かず、待機起動のゲートもそれを待たない
# （単体 verify はゲート間の排他へ参加しない。ADR-095）。隔離を済ませた単体 verify を走らせた
# まま待機起動のゲートを始め、印が無いこと・待たずに suite が走ることを確かめる。
: > "$_c55_events"
_c55_v_nonwait="$_c55_fx/vtree/tests/run-all/verify-nonwait.sh"
_c55_v_ready="$_c55_fx/vnonwait.ready"
rm -f "$_c55_v_nonwait" "$_c55_v_ready"
awk '/^ff_verify_isolate_observation$/ { exit } { print }' "$_c55_fx/vtree/tests/run-all/verify.sh" > "$_c55_v_nonwait"
if [ "$(grep -c '^ff_verify_isolate_observation() {$' "$_c55_v_nonwait")" -eq 1 ] \
  && [ "$(grep -cx 'ff_verify_isolate_observation' "$_c55_fx/vtree/tests/run-all/verify.sh")" -eq 1 ]; then
  ok "55-P: 単体 verify.sh の写しを隔離の呼び出しの直前で切り出せた"
else
  bad "55-P: 単体 verify.sh の隔離の呼び出し行を特定できない（切り出しが空振りしている）"
fi
printf '%s\n' \
  'ff_verify_isolate_observation' \
  '[ -n "${C55_P_READY:-}" ] && : > "$C55_P_READY"' \
  '_c55_p_i=0' \
  'while [ ! -e "${C55_P_RELEASE:?}" ] && [ "$_c55_p_i" -lt 1200 ]; do sleep 0.05; _c55_p_i=$((_c55_p_i + 1)); done' \
  'if [ -n "${C55_EVENT_LOG:-}" ]; then printf '\''NONWAIT_VERIFY_DONE\n'\'' >> "$C55_EVENT_LOG"; fi' \
  'FF_REACHED_END=1' \
  'exit 0' >> "$_c55_v_nonwait"
chmod +x "$_c55_v_nonwait"
# 単体 verify は、ゲートが走り終えてこの印を置くまで終わらない（時間ではなく順序で前後を決める）。
_c55_v_release="$_c55_fx/vnonwait.release"
rm -f "$_c55_v_release"
_c55_p_before="$(find "$_c55_wdir" -type f -path '*/active/*' 2>/dev/null | sort)"
env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL -u FF_RUN_ALL_ALLOW_SKIP -u FF_RUN_ALL_CHANGED -u FF_RUN_ALL_ALLOW_DIRTY \
  -u FF_RUN_ALL_WAIT -u FF_RUN_ALL_WAIT_MAX_SECONDS \
  FF_RUN_ALL_WAIT_DIR="$_c55_wdir" C55_P_READY="$_c55_v_ready" C55_P_RELEASE="$_c55_v_release" C55_EVENT_LOG="$_c55_events" \
  C55_FAKE_PS_FILE="$_c55_fake_ps" C55_REAL_PS="$_c55_real_ps" PATH="$_c55_fx/bin:$PATH" \
  bash "$_c55_v_nonwait" > "$_c55_fx/vnonwait.log" 2>&1 &
_c55_vnw=$!
_c55_bg_pids="$_c55_vnw"
_c55_pw=0
while [ "$_c55_pw" -lt 400 ]; do
  if [ -e "$_c55_v_ready" ] || ! kill -0 "$_c55_vnw" 2>/dev/null; then
    break
  fi
  sleep 0.05
  _c55_pw=$((_c55_pw + 1))
done
if [ -e "$_c55_v_ready" ] && kill -0 "$_c55_vnw" 2>/dev/null; then
  ok "55-P: 単体 verify.sh が隔離を済ませて走行中になった"
else
  bad "55-P: 単体 verify.sh が走行中にならない（以降の検査は成立していません）: $(cat "$_c55_fx/vnonwait.log" 2>/dev/null)"
fi
_c55_p_after="$(find "$_c55_wdir" -type f -path '*/active/*' 2>/dev/null | sort)"
if [ ! -e "$_c55_wdir/active/${_c55_vnw}" ] && [ "$_c55_p_before" = "$_c55_p_after" ]; then
  ok "55-P: 走行中の単体 verify.sh は active マーカーを置かない（起動の前後で active の中身が変わらない）"
else
  bad "55-P: 走行中の単体 verify.sh が active マーカーを置いた: 前=[${_c55_p_before}] 後=[${_c55_p_after}]"
fi
_c55_run env FF_RUN_ALL_WAIT=1 FF_RUN_ALL_WAIT_MAX_SECONDS=10 C55_EVENT_LOG="$_c55_events" \
  bash "$_c55_runner" "$_c55_fx/repo/tests/ok-probe/verify.sh"
_c55_p_alive=0
if kill -0 "$_c55_vnw" 2>/dev/null; then _c55_p_alive=1; fi
expect_rc 0 "55-P: 単体 verify.sh の走行中に始めた待機起動のゲートが rc=0"
expect_lacks 'tests/run-all/verify\.sh' "55-P: 待機起動のゲートは単体 verify.sh を待機対象として名指ししない"
expect_lacks '先行処理の終了を確認' "55-P: 待機起動のゲートは単体 verify.sh の終了を待たない"
if [ "$_c55_p_alive" = 1 ] && [ "$(tr '\n' ',' < "$_c55_events")" = "OK_RAN," ]; then
  ok "55-P: 単体 verify.sh がまだ走っている間に suite が走り終えた（待っていない）"
else
  bad "55-P: 単体 verify.sh との前後が不正（alive=${_c55_p_alive} events=$(tr '\n' ',' < "$_c55_events")）"
fi
: > "$_c55_v_release"
_c55_pw=0
while [ "$_c55_pw" -lt 400 ] && kill -0 "$_c55_vnw" 2>/dev/null; do
  sleep 0.05
  _c55_pw=$((_c55_pw + 1))
done
_c55_kill_bg
rm -f "$_c55_v_nonwait" "$_c55_v_ready" "$_c55_v_release" "$_c55_fx/vnonwait.log"

# 55-P2: ps に現れず、待機領域の active マーカーだけで見える先行者（待機起動で走行中のゲート）を、
# 待機起動のゲートは名指しして終了まで待つ。単体 verify を排他から外した後も、印だけで見える
# ゲートどうしの検知が残っていることを固定する（印の走査の配線を落とすと、待たずに始まって赤）。
: > "$_c55_events"
_c55_holder="$_c55_fx/active-holder.sh"
_c55_h_ready="$_c55_fx/holder.ready"
_c55_h_release="$_c55_fx/holder.release"
rm -f "$_c55_h_ready" "$_c55_h_release"
cat > "$_c55_holder" <<'HOLDER'
#!/usr/bin/env bash
# 待機領域へ active マーカーを置き、合図が来るまで居座る（ps の stub には現れない）。
# shellcheck disable=SC1090
. "${C55_LIB:?}" || exit 3
marker="$(ff_gate_active_marker_write "c55-active-holder")" || exit 3
[ -n "$marker" ] || exit 3
: > "${C55_H_READY:?}"
i=0
while [ ! -e "${C55_H_RELEASE:?}" ] && [ "$i" -lt 1200 ]; do
  sleep 0.05
  i=$((i + 1))
done
printf 'HOLDER_DONE\n' >> "${C55_EVENT_LOG:?}"
ff_gate_active_marker_remove "$marker"
HOLDER
env -u FF_RUN_ALL_WAIT -u FF_RUN_ALL_WAIT_MAX_SECONDS \
  FF_RUN_ALL_WAIT_DIR="$_c55_wdir" C55_LIB="$_c55_fx/repo/tests/lib/gate-in-flight.sh" \
  C55_H_READY="$_c55_h_ready" C55_H_RELEASE="$_c55_h_release" C55_EVENT_LOG="$_c55_events" \
  bash "$_c55_holder" > "$_c55_fx/holder.log" 2>&1 &
_c55_hpid=$!
_c55_bg_pids="$_c55_hpid"
_c55_pw=0
while [ "$_c55_pw" -lt 400 ]; do
  if [ -e "$_c55_h_ready" ] || ! kill -0 "$_c55_hpid" 2>/dev/null; then
    break
  fi
  sleep 0.05
  _c55_pw=$((_c55_pw + 1))
done
if [ -e "$_c55_h_ready" ] && [ -e "$_c55_wdir/active/${_c55_hpid}" ]; then
  ok "55-P2: 先行者が待機領域へ active マーカーを置いて走行中になった"
else
  bad "55-P2: 先行者の active マーカーを用意できない（以降の検査は成立していません）: $(cat "$_c55_fx/holder.log" 2>/dev/null)"
fi
# 待機側が先行者を見つけて「待っています」と出力してから、先行者を解放する（時間ではなく順序で決める）。
# waiting マーカーの出現では早すぎる — 待機側はそれを最初の走査より前に置くので、走査の時点で先行者の
# 印がもう消えている回ができる。解放役は、この回のログ（_c55_run_log）にその出力が現れるのを待つ。
# 現れないまま上限に達した回は、先行者を解放したうえで SYNC_TIMEOUT を残して実行順の検査を赤にする。
_c55_prepare_log
(
  if ! _c55_wait_for_log "完了を待っています" 600 "$_c55_run_log"; then
    printf 'SYNC_TIMEOUT\n' >> "$_c55_events"
  fi
  : > "$_c55_h_release"
) &
_c55_rel_pid=$!
_c55_run env FF_RUN_ALL_WAIT=1 FF_RUN_ALL_WAIT_MAX_SECONDS=60 C55_EVENT_LOG="$_c55_events" \
  bash "$_c55_runner" "$_c55_fx/repo/tests/ok-probe/verify.sh"
wait "$_c55_rel_pid" 2>/dev/null || true
expect_rc 0 "55-P2: active マーカーだけで見える先行者の終了後に自動開始して rc=0"
expect_has 'c55-active-holder' "55-P2: 待機対象に active マーカーの先行者を名指しする"
expect_has '先行処理の終了を確認' "55-P2: 先行者の終了を待ってから始めたことを出す"
if [ "$(tr '\n' ',' < "$_c55_events")" = "HOLDER_DONE,OK_RAN," ]; then
  ok "55-P2: 先行者が終わってから suite が始まった"
else
  bad "55-P2: 実行順が不正（$(tr '\n' ',' < "$_c55_events")）"
fi
_c55_kill_bg
rm -f "$_c55_holder" "$_c55_h_ready" "$_c55_h_release" "$_c55_fx/holder.log"

# 55-Q: マーカー走査・生存判定の TOCTOU 耐性と fail-closed 陰性ケース
_c55_q_lib="$_c55_fx/repo/tests/lib/gate-in-flight.sh"
_c55_q_dir="$_c55_fx/q-markers"
rm -rf "$_c55_q_dir"
mkdir -p "$_c55_q_dir"

# 55-Q1: [ -f "$f" ] 通過〜[ -r "$f" ] 直前に通常ファイルが消える TOCTOU で rc=2（unknown）に倒れない
_c55_q1_lib="$_c55_fx/q1-gif.sh"
awk '
  /^  case "\$base" in$/ { in_case = 1 }
  { print }
  in_case && /^  esac$/ {
    print "  if [ \"${C55_Q1_UNLINK:-0}\" = \"1\" ]; then rm -f -- \"$f\"; fi"
    in_case = 0
  }
' "$_c55_q_lib" > "$_c55_q1_lib"
if ! grep -qF 'C55_Q1_UNLINK' "$_c55_q1_lib"; then
  bad "55-Q1: awk による消失注入がアンカーに一致しなかった"
else
  printf 'Thu Jan  1 00:00:00 1970\n' > "$_c55_q_dir/999991"
  _c55_q1_res="$(
    bash -c '
      . "$1"
      C55_Q1_UNLINK=1 ff_gate_marker_sweep_dir "$2" 0 ""
      printf "rc=%s unk=[%s] live=[%s] rec=%s\n" "$?" "$GATE_UNKNOWN_LINES" "$GATE_LIVE_LINES" "$GATE_RECLAIMED_COUNT"
    ' _ "$_c55_q1_lib" "$_c55_q_dir"
  )"
  if [ "$_c55_q1_res" = "rc=0 unk=[] live=[] rec=0" ] && [ ! -e "$_c55_q_dir/999991" ]; then
    ok "55-Q1: 走査〜読み取り間の通常ファイル消失（TOCTOU）で判定不能にならず走査を継続（rec=0）"
  else
    bad "55-Q1: 消失 TOCTOU の結果が不正: $_c55_q1_res"
  fi
fi

# 55-Q2: kill -0 〜 ps -o lstart= 間に待機対象プロセスが終了・回収される TOCTOU で rc=2（unknown）に倒れない
# 親マネージャーが子を kill + wait で確実に回収してから done 印を出し、孤児回収タイミングへ依存しない
_c55_q2_ctl="$_c55_fx/q2-ctl"
rm -rf "$_c55_q2_ctl"
mkdir -p "$_c55_q2_ctl"
bash -c '
  sleep 300 >/dev/null 2>&1 &
  spid=$!
  printf "%s\n" "$spid" > "$1/pid"
  while [ ! -e "$1/stop" ]; do
    sleep 0.02
  done
  kill -9 "$spid" 2>/dev/null || true
  wait "$spid" 2>/dev/null || true
  : > "$1/reaped"
' _ "$_c55_q2_ctl" >/dev/null 2>&1 &
_c55_q2_mgr=$!
_c55_bg_pids="$_c55_q2_mgr"
_c55_pw=0
while [ "$_c55_pw" -lt 250 ] && [ ! -s "$_c55_q2_ctl/pid" ]; do
  sleep 0.02
  _c55_pw=$((_c55_pw + 1))
done
_c55_q2_pid="$(cat "$_c55_q2_ctl/pid" 2>/dev/null || true)"
_c55_bg_pids="$_c55_q2_mgr $_c55_q2_pid"
_c55_q2_start="$(ff_gate_ps_lstart "$_c55_q2_pid" || true)"
printf '%s\n' "$_c55_q2_start" > "$_c55_q_dir/${_c55_q2_pid}"
_c55_q2_bin="$_c55_fx/q2-bin"
mkdir -p "$_c55_q2_bin"
cat > "$_c55_q2_bin/ps" <<'Q2PS'
#!/usr/bin/env bash
if [ -n "${C55_Q2_CTL:-}" ]; then
  : > "${C55_Q2_CTL}/ps_called"
  : > "${C55_Q2_CTL}/stop"
  _w=0
  while [ "$_w" -lt 1000 ] && [ ! -e "${C55_Q2_CTL}/reaped" ]; do
    sleep 0.02
    _w=$((_w + 1))
  done
fi
exit 1
Q2PS
chmod +x "$_c55_q2_bin/ps"
_c55_q2_res="$(
  PATH="$_c55_q2_bin:$PATH" C55_Q2_CTL="$_c55_q2_ctl" bash -c '
    . "$1"
    ff_gate_marker_sweep_dir "$2" 0 ""
    printf "rc=%s unk=[%s] live=[%s] rec=%s\n" "$?" "$GATE_UNKNOWN_LINES" "$GATE_LIVE_LINES" "$GATE_RECLAIMED_COUNT"
  ' _ "$_c55_q_lib" "$_c55_q_dir"
)"
_c55_kill_bg
if [ "$_c55_q2_res" = "rc=0 unk=[] live=[] rec=1" ] && [ -e "$_c55_q2_ctl/ps_called" ] && [ ! -e "$_c55_q_dir/${_c55_q2_pid}" ]; then
  ok "55-Q2: kill -0 〜 ps 間のプロセス終了（TOCTOU）で判定不能にならず残骸回収して継続（rec=1）"
else
  bad "55-Q2: kill -0 〜 ps 間の TOCTOU 結果が不正: $_c55_q2_res (ps_called=$([ -e "$_c55_q2_ctl/ps_called" ] && echo yes || echo no))"
fi

# 55-Q3a: 陰性ケース — 実在するが読み取り不可の通常ファイルは fail-closed（rc=2 / 削除しない）
printf 'Thu Jan  1 00:00:00 1970\n' > "$_c55_q_dir/999992"
chmod 000 "$_c55_q_dir/999992" 2>/dev/null || true
if [ ! -r "$_c55_q_dir/999992" ]; then
  _c55_q3a_res="$(
    bash -c '
      . "$1"
      st=0; ff_gate_marker_status "$2/999992" || st=$?
      ff_gate_marker_sweep_dir "$2" 0 ""
      printf "st=%s unk=[%s]\n" "$st" "$GATE_UNKNOWN_LINES"
    ' _ "$_c55_q_lib" "$_c55_q_dir"
  )"
  if case "$_c55_q3a_res" in *"st=2 unk=[999992:"*) true ;; *) false ;; esac && [ -e "$_c55_q_dir/999992" ]; then
    ok "55-Q3a: 実在する読み取り不可マーカーは fail-closed（rc=2）で残置"
  else
    bad "55-Q3a: 読み取り不可マーカーの fail-closed が崩れた: $_c55_q3a_res"
  fi
else
  # root / MSYS 等で chmod 000 が読み取りを拒否しない環境でも黙って通過せず、! -r 分岐の fail-closed を代替検証する
  _c55_q3a_lib="$_c55_fx/q3a-gif.sh"
  awk '
    /^  if \[ ! -r "\$f" \]; then$/ {
      print "  if [ \"${C55_Q3A_UNREADABLE:-0}\" = \"1\" ] || [ ! -r \"$f\" ]; then"
      next
    }
    { print }
  ' "$_c55_q_lib" > "$_c55_q3a_lib"
  if ! grep -qF 'C55_Q3A_UNREADABLE' "$_c55_q3a_lib"; then
    bad "55-Q3a: 代替読み取り不可分岐の注入に失敗"
  else
    _c55_q3a_res="$(
      bash -c '
        . "$1"
        st=0; C55_Q3A_UNREADABLE=1 ff_gate_marker_status "$2/999992" || st=$?
        C55_Q3A_UNREADABLE=1 ff_gate_marker_sweep_dir "$2" 0 ""
        printf "st=%s unk=[%s]\n" "$st" "$GATE_UNKNOWN_LINES"
      ' _ "$_c55_q3a_lib" "$_c55_q_dir"
    )"
    if case "$_c55_q3a_res" in *"st=2 unk=[999992:"*) true ;; *) false ;; esac && [ -e "$_c55_q_dir/999992" ]; then
      ok "55-Q3a: 実在する読み取り不可マーカーは fail-closed（rc=2）で残置（chmod 非適用環境向け代替経路）"
    else
      bad "55-Q3a: 代替読み取り不可マーカーの fail-closed が崩れた: $_c55_q3a_res"
    fi
  fi
  rm -f "$_c55_q3a_lib"
fi
chmod 600 "$_c55_q_dir/999992" 2>/dev/null || true
rm -f "$_c55_q_dir/999992"

# 55-Q3b: 陰性ケース — symlink マーカーは fail-closed（rc=2 / 削除しない）
ln -s /nonexistent "$_c55_q_dir/999993"
_c55_q3b_res="$(
  bash -c '
    . "$1"
    st=0; ff_gate_marker_status "$2/999993" || st=$?
    ff_gate_marker_sweep_dir "$2" 0 ""
    printf "st=%s unk=[%s]\n" "$st" "$GATE_UNKNOWN_LINES"
  ' _ "$_c55_q_lib" "$_c55_q_dir"
)"
if case "$_c55_q3b_res" in *"st=2 unk=[999993:"*) true ;; *) false ;; esac && [ -L "$_c55_q_dir/999993" ]; then
  ok "55-Q3b: symlink マーカーは fail-closed（rc=2）で残置"
else
  bad "55-Q3b: symlink マーカーの fail-closed が崩れた: $_c55_q3b_res"
fi
rm -f "$_c55_q_dir/999993"

# 55-Q3c: 陰性ケース — 生存中の PID に対して ps が空出力を返す場合は fail-closed（rc=2 / 削除しない）
sleep 300 >/dev/null 2>&1 &
_c55_q3c_pid=$!
_c55_bg_pids="$_c55_q3c_pid"
_c55_q3c_start="$(ff_gate_ps_lstart "$_c55_q3c_pid" || true)"
printf '%s\n' "$_c55_q3c_start" > "$_c55_q_dir/${_c55_q3c_pid}"
_c55_q3c_res="$(
  PATH="$_c55_q2_bin:$PATH" C55_Q2_CTL="" bash -c '
    . "$1"
    st=0; ff_gate_marker_status "$2/$3" || st=$?
    ff_gate_marker_sweep_dir "$2" 0 ""
    printf "st=%s unk=[%s]\n" "$st" "$GATE_UNKNOWN_LINES"
  ' _ "$_c55_q_lib" "$_c55_q_dir" "$_c55_q3c_pid"
)"
_c55_kill_bg
if case "$_c55_q3c_res" in *"st=2 unk=[${_c55_q3c_pid}:"*) true ;; *) false ;; esac && [ -e "$_c55_q_dir/${_c55_q3c_pid}" ]; then
  ok "55-Q3c: 生存 PID に対する ps 異常時は fail-closed（rc=2）で残置"
else
  bad "55-Q3c: 生存 PID + ps 異常の fail-closed が崩れた: $_c55_q3c_res"
fi
rm -f "$_c55_q_dir/${_c55_q3c_pid}"

# 55-Q4: 変異対照 — 消失分岐・kill_ok 分岐の kill -0 再確認を除去すると 55-Q1/55-Q2 相当が unknown（rc=2）で検出される
_c55_q4a_lib="$_c55_fx/q4a-gif.sh"
awk '
  /^  if \[ ! -r "\$f" \]; then$/ {
    print "  [ -r \"$f\" ] || return 2"
    skip = 1
    next
  }
  skip && /^  fi$/ { skip = 0; next }
  skip { next }
  { print }
' "$_c55_q1_lib" > "$_c55_q4a_lib"
if cmp -s "$_c55_q1_lib" "$_c55_q4a_lib"; then
  bad "55-Q4a: 消失分岐除去の変異がアンカーに一致しなかった"
else
  printf 'Thu Jan  1 00:00:00 1970\n' > "$_c55_q_dir/999994"
  _c55_q4a_res="$(
    bash -c '
      . "$1"
      C55_Q1_UNLINK=1 ff_gate_marker_sweep_dir "$2" 0 ""
      printf "unk=[%s]\n" "$GATE_UNKNOWN_LINES"
    ' _ "$_c55_q4a_lib" "$_c55_q_dir"
  )"
  if case "$_c55_q4a_res" in *"unk=[999994:"*) true ;; *) false ;; esac; then
    ok "55-Q4a: 消失分岐を除いた変異で 55-Q1 の TOCTOU 誤停止（unknown）を再現・検出"
  else
    bad "55-Q4a: 消失分岐除去の変異を検出できない: $_c55_q4a_res"
  fi
fi

_c55_q4b_lib="$_c55_fx/q4b-gif.sh"
awk '
  /^    if \[ -z "\$have" \]; then$/ {
    print "    [ -n \"$have\" ] || return 2"
    skip = 1
    next
  }
  skip && /^    fi$/ { skip = 0; next }
  skip { next }
  { print }
' "$_c55_q_lib" > "$_c55_q4b_lib"
if cmp -s "$_c55_q_lib" "$_c55_q4b_lib"; then
  bad "55-Q4b: kill_ok 分岐の kill -0 再確認除去変異がアンカーに一致しなかった"
else
  rm -rf "$_c55_q2_ctl"
  mkdir -p "$_c55_q2_ctl"
  bash -c '
    sleep 300 >/dev/null 2>&1 &
    spid=$!
    printf "%s\n" "$spid" > "$1/pid"
    while [ ! -e "$1/stop" ]; do
      sleep 0.02
    done
    kill -9 "$spid" 2>/dev/null || true
    wait "$spid" 2>/dev/null || true
    : > "$1/reaped"
  ' _ "$_c55_q2_ctl" >/dev/null 2>&1 &
  _c55_q4b_mgr=$!
  _c55_bg_pids="$_c55_q4b_mgr"
  _c55_pw=0
  while [ "$_c55_pw" -lt 250 ] && [ ! -s "$_c55_q2_ctl/pid" ]; do
    sleep 0.02
    _c55_pw=$((_c55_pw + 1))
  done
  _c55_q4b_pid="$(cat "$_c55_q2_ctl/pid" 2>/dev/null || true)"
  _c55_bg_pids="$_c55_q4b_mgr $_c55_q4b_pid"
  printf '%s\n' "$(ff_gate_ps_lstart "$_c55_q4b_pid" || true)" > "$_c55_q_dir/${_c55_q4b_pid}"
  _c55_q4b_res="$(
    PATH="$_c55_q2_bin:$PATH" C55_Q2_CTL="$_c55_q2_ctl" bash -c '
      . "$1"
      ff_gate_marker_sweep_dir "$2" 0 ""
      printf "unk=[%s]\n" "$GATE_UNKNOWN_LINES"
    ' _ "$_c55_q4b_lib" "$_c55_q_dir"
  )"
  _c55_kill_bg
  if case "$_c55_q4b_res" in *"unk=[${_c55_q4b_pid}:"*) true ;; *) false ;; esac; then
    ok "55-Q4b: kill_ok 分岐の kill -0 再確認を除いた変異で 55-Q2 の TOCTOU 誤停止（unknown）を再現・検出"
  else
    bad "55-Q4b: kill_ok 分岐の kill -0 再確認除去の変異を検出できない: $_c55_q4b_res"
  fi
fi
rm -rf "$_c55_q_dir" "$_c55_q2_bin" "$_c55_q2_ctl" "$_c55_q1_lib" "$_c55_q4a_lib" "$_c55_q4b_lib"

# 55-R: 高負荷起動遅延でも同期待機が成立することの回帰検証と空振り対照
_c55_slow_start="$_c55_fx/slow-start-runner.sh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [ -n "${C55_R_GO:-}" ]; then' \
  '  _r_i=0' \
  '  while [ "$_r_i" -lt 160 ] && [ ! -e "$C55_R_GO" ]; do sleep 0.05; _r_i=$((_r_i + 1)); done' \
  'else' \
  '  sleep 0.8' \
  'fi' \
  'exec bash "'"$_c55_runner"'" "$@"' > "$_c55_slow_start"
chmod +x "$_c55_slow_start"

# 55-R1: 起動が 0.8 秒遅れても（旧固定 sleep 0.6 を超過）同期待機で待機ログ・順序・rc=0 を満たす
: > "$_c55_events"
printf '4194308|1|bash /x/public-layout/verify.sh\n' > "$_c55_fake_ps"
_c55_prepare_log
(
  if _c55_wait_for_log "4194308:/x/public-layout/verify.sh" 160 "$_c55_run_log"; then
    printf 'SLOW_START_CLEARED\n' >> "$_c55_events"
    : > "$_c55_fake_ps"
  else
    printf 'SYNC_TIMEOUT\n' >> "$_c55_events"
  fi
) &
_c55_bg_pids="$!"
_c55_run env FF_RUN_ALL_WAIT=1 FF_RUN_ALL_WAIT_MAX_SECONDS=10 C55_EVENT_LOG="$_c55_events" \
  bash "$_c55_slow_start" "$_c55_fx/repo/tests/ok-probe/verify.sh"
_c55_kill_bg
: > "$_c55_fake_ps"
expect_rc 0 "55-R1: 0.8 秒起動遅延下でも同期待機が成立して rc=0"
expect_has '完了を待っています' "55-R1: 0.8 秒起動遅延下でも待機メッセージを出力"
expect_has '4194308:/x/public-layout/verify\.sh' "55-R1: 0.8 秒起動遅延下でも待機対象を名指し"
if [ "$(tr '\n' ',' < "$_c55_events")" = "SLOW_START_CLEARED,OK_RAN," ]; then
  ok "55-R1: 0.8 秒起動遅延下でも解除後から suite が始まった"
else
  bad "55-R1: 実行順が不正（$(cat "$_c55_events")）"
fi

# 55-R2: 同期待機ヘルパは一致しないログで無限待機せず有界タイムアウト（非 0）を返す
: > "$_c55_fx/empty-r2.log"
if _c55_wait_for_log "NEVER-MATCH-NEEDLE-C55-R2" 2 "$_c55_fx/empty-r2.log"; then
  bad "55-R2: 不一致ログで _c55_wait_for_log が 0 を返した"
else
  ok "55-R2: 不一致ログで _c55_wait_for_log が有界タイムアウト（非 0）を返した"
fi
rm -f "$_c55_fx/empty-r2.log"

# 55-R3: 変異対照 — 待機ログを待たずにブロッカーがランナー起動完了前に解除される変異では待機ログが欠落する（決定論的順序制御）
_c55_r3_go="$_c55_fx/r3.go"
rm -f "$_c55_r3_go"
printf '4194309|1|bash /x/public-layout/verify.sh\n' > "$_c55_fake_ps"
(
  : > "$_c55_fake_ps"
  : > "$_c55_r3_go"
) &
_c55_bg_pids="$!"
_c55_run env FF_RUN_ALL_WAIT=1 FF_RUN_ALL_WAIT_MAX_SECONDS=10 C55_R_GO="$_c55_r3_go" \
  bash "$_c55_slow_start" "$_c55_fx/repo/tests/ok-probe/verify.sh"
_c55_kill_bg
: > "$_c55_fake_ps"
rm -f "$_c55_r3_go"
expect_rc 0 "55-R3: 未同期の先行解除変異でもランナー自体は正常終了する（早期異常終了ではない）"
expect_has 'FIXTURE-C55-OK' "55-R3: 未同期の先行解除変異でも suite が実際に実行される"
expect_lacks '完了を待っています' "55-R3: 未同期の先行解除変異では待機に入らずログが欠落する（55-R1 の対照）"
expect_lacks '4194309:/x/public-layout/verify\.sh' "55-R3: 未同期の先行解除変異では待機対象ログが欠落する"
rm -f "$_c55_slow_start"

# 55-M: 待機除外判定を無効化した変異は 55-G 条件を rc=2 にする（55-G の検出力対照）
sleep 20 &
_c55_wsl=$!
_c55_bg_pids="$_c55_wsl"
mkdir -p "$_c55_wdir/waiting"
printf '%s\n' "$(ff_gate_ps_lstart "$_c55_wsl")" > "$_c55_wdir/waiting/${_c55_wsl}"
printf '%s|1|bash /x/run-all.sh\n' "$_c55_wsl" > "$_c55_fake_ps"
awk '
  /^ff_gate_pid_is_waiting\(\)/ { print; print "  return 1"; next }
  { print }
' "$_c55_fx/repo/tests/lib/gate-in-flight.sh" > "$_c55_fx/gate-in-flight.mut.sh"
mv "$_c55_fx/gate-in-flight.mut.sh" "$_c55_fx/repo/tests/lib/gate-in-flight.sh"
_dg_git -C "$_c55_fx/repo" add -A >/dev/null 2>&1 || true
_dg_git -C "$_c55_fx/repo" commit -qm "c55-mut" >/dev/null 2>&1 || true
_c55_run bash "$_c55_runner"
_c55_kill_bg
rm -f "$_c55_wdir/waiting/${_c55_wsl}"
: > "$_c55_fake_ps"
expect_rc 2 "55-M: 待機除外を無効化した変異では waiting PID を並走扱いして rc=2（55-G の対照）"
expect_lacks 'FIXTURE-C55-RUN-ALL' "55-M: 変異では suite が走らない"

rm -rf "$_c55_fx"
fi

echo
echo "== case 56: 大量出力の標準出力書き込みエラー（EINTR 等）でも集計と鮮度記録を完走する =="

if ! command -v git >/dev/null 2>&1; then
  bad "case 56: git が無いため標準出力書き込み耐性の検証を実行できない"
else
_c56_fx="$RUN_WORK/ff-stdout-write"
rm -rf "$_c56_fx"
mkdir -p "$_c56_fx/repo/tests/s1" "$_c56_fx/repo/tests/s2" "$_c56_fx/repo/tests/f1" \
  "$_c56_fx/repo/tests/lib" "$_c56_fx/repo/scripts"

# 56-A: ff-stdout-write-block 単体 — 一過性 EINTR は再試行で回復し、恒久失敗は 1 回だけ警告して rc=0
_c56_blk="$_c56_fx/stdout-block.sh"
awk '/^# >>> ff-stdout-write-block/{f=1} f{print} /^# <<< ff-stdout-write-block/{exit}' "$RUNNER" > "$_c56_blk"
if [ ! -s "$_c56_blk" ] || ! grep -qF 'ff_stdout_write()' "$_c56_blk" || ! grep -qF 'ff_stdout_note_error()' "$_c56_blk"; then
  bad "56-A: run-all.sh から ff-stdout-write-block を抽出できなかった"
else
  _c56_a1_cnt="$_c56_fx/a1.cnt"
  _c56_a1_out="$_c56_fx/a1.out"
  _c56_a1_err="$_c56_fx/a1.err"
  printf '0\n' > "$_c56_a1_cnt"
  if bash -euo pipefail -c '
    . "$1"
    CNT_FILE="$2"
    printf() {
      case "${1:-}" in
        "\\n") builtin printf "$@"; return $? ;;
      esac
      local c
      c="$(cat "$CNT_FILE")"
      c=$((c + 1))
      builtin printf "%s\n" "$c" > "$CNT_FILE"
      if [ "$c" -eq 1 ]; then
        builtin printf "PARTIAL-"
        builtin printf "printf: write error: Interrupted system call\n" >&2
        return 1
      fi
      builtin printf "$@"
    }
    ff_stdout_write "PAYLOAD-RECOVERED-LINE"
    builtin printf "ERR=%s WARN=%s\n" "$STDOUT_WRITE_ERRORS" "$STDOUT_WRITE_WARNED" >&2
  ' _ "$_c56_blk" "$_c56_a1_cnt" > "$_c56_a1_out" 2> "$_c56_a1_err"; then
    _c56_a1_rc=0
  else
    _c56_a1_rc=$?
  fi
  if [ "$_c56_a1_rc" -eq 0 ] \
      && grep -qxF 'PAYLOAD-RECOVERED-LINE' "$_c56_a1_out" \
      && [ "$(cat "$_c56_a1_cnt")" = "2" ] \
      && grep -qF 'ERR=0 WARN=0' "$_c56_a1_err"; then
    ok "56-A: 一過性 EINTR（部分書き込み後）は新しい行頭から再試行して全量出力・回復する（警告なし・rc=0）"
  else
    bad "56-A: 一過性 EINTR の再試行回復が不正（rc=${_c56_a1_rc} cnt=$(cat "$_c56_a1_cnt" 2>/dev/null) out=$(cat "$_c56_a1_out" 2>/dev/null) err=$(cat "$_c56_a1_err" 2>/dev/null)）"
  fi

  _c56_a2_cnt="$_c56_fx/a2.cnt"
  _c56_a2_err="$_c56_fx/a2.err"
  printf '0\n' > "$_c56_a2_cnt"
  if bash -euo pipefail -c '
    . "$1"
    CNT_FILE="$2"
    printf() {
      case "${1:-}:${2:-}" in
        *:⚠️*) builtin printf "$@" ;;
        *)
          local c
          c="$(cat "$CNT_FILE")"
          c=$((c + 1))
          builtin printf "%s\n" "$c" > "$CNT_FILE"
          return 1
          ;;
      esac
    }
    ff_stdout_write "PERSISTENT-FAIL-1"
    ff_stdout_write "PERSISTENT-FAIL-2"
    builtin printf "ERR=%s WARN=%s\n" "$STDOUT_WRITE_ERRORS" "$STDOUT_WRITE_WARNED" >&2
  ' _ "$_c56_blk" "$_c56_a2_cnt" >/dev/null 2> "$_c56_a2_err"; then
    _c56_a2_rc=0
  else
    _c56_a2_rc=$?
  fi
  _c56_a2_wcnt="$(grep -cF '標準出力への書き込みに失敗しました（rc=1）' "$_c56_a2_err" || true)"
  if [ "$_c56_a2_rc" -eq 0 ] \
      && [ "$(cat "$_c56_a2_cnt")" = "6" ] \
      && [ "$_c56_a2_wcnt" -eq 1 ] \
      && grep -qF 'ERR=2 WARN=1' "$_c56_a2_err"; then
    ok "56-A: 恒久書き込み失敗は最大 3 回試行（初回 1 回＋再試行 2 回）後に stderr へ 1 回だけ rc=1 を警告して継続する"
  else
    bad "56-A: 恒久失敗の挙動が不正（rc=${_c56_a2_rc} cnt=$(cat "$_c56_a2_cnt" 2>/dev/null) wcnt=${_c56_a2_wcnt} err=$(cat "$_c56_a2_err" 2>/dev/null)）"
  fi

  # 56-A3: ff_emit_summary_head の途中行（suites:）が部分書き込み後に 1 回 EINTR 失敗しても新しい行頭から再試行し機械判定行を保つ
  _c56_sum_blk="$_c56_fx/summary-block.sh"
  awk '/^# >>> ff-summary-head-block/{f=1} f{print} /^# <<< ff-summary-head-block/{exit}' "$RUNNER" > "$_c56_sum_blk"
  _c56_a3_cnt="$_c56_fx/a3.cnt"
  _c56_a3_out="$_c56_fx/a3.out"
  _c56_a3_err="$_c56_fx/a3.err"
  printf '0\n' > "$_c56_a3_cnt"
  if bash -euo pipefail -c '
    . "$1"
    . "$2"
    CNT_FILE="$3"
    FF_SELF_FINGERPRINT_START=""
    SCRIPTS=(a b) PASSED=(a b) FAILED=() SKIPPED=() NOT_RUN=()
    CHECKS_SKIPPED_TOTAL=0 CHECKS_SKIPPED=()
    echo() {
      case "${1:-}" in
        "suites: "*)
          local c
          c="$(cat "$CNT_FILE")"
          c=$((c + 1))
          builtin printf "%s\n" "$c" > "$CNT_FILE"
          if [ "$c" -eq 1 ]; then
            builtin printf "sui"
            return 1
          fi
          ;;
      esac
      builtin echo "$@"
    }
    ff_emit_summary_head
    builtin printf "ERR=%s WARN=%s\n" "$STDOUT_WRITE_ERRORS" "$STDOUT_WRITE_WARNED" >&2
  ' _ "$_c56_blk" "$_c56_sum_blk" "$_c56_a3_cnt" > "$_c56_a3_out" 2> "$_c56_a3_err"; then
    _c56_a3_rc=0
  else
    _c56_a3_rc=$?
  fi
  if [ "$_c56_a3_rc" -eq 0 ] \
      && [ "$(cat "$_c56_a3_cnt")" = "2" ] \
      && grep -qxF 'suites: total=2 run=2 passed=2 failed=0 skipped=0 not-run=0' "$_c56_a3_out" \
      && grep -qF 'ERR=0 WARN=0' "$_c56_a3_err"; then
    ok "56-A3: ff_emit_summary_head の途中行（suites:）が部分書き込み後に失敗しても行頭から再試行し ^suites: 行を保つ"
  else
    bad "56-A3: ff_emit_summary_head の途中行再試行に失敗（rc=${_c56_a3_rc} cnt=$(cat "$_c56_a3_cnt" 2>/dev/null) out=$(cat "$_c56_a3_out" 2>/dev/null) err=$(cat "$_c56_a3_err" 2>/dev/null)）"
  fi
fi

# 56-B〜56-D 用 fixture リポジトリ構築
cp "$RUNNER" "$_c56_fx/repo/tests/run-all.sh"
cp "$TESTS_DIR/lib/gate-in-flight.sh" "$_c56_fx/repo/tests/lib/gate-in-flight.sh"
if [ -f "$TESTS_DIR/lib/utf8-locale.sh" ]; then
  cp "$TESTS_DIR/lib/utf8-locale.sh" "$_c56_fx/repo/tests/lib/utf8-locale.sh"
fi
cp "$TESTS_DIR/../scripts/record-gate-head.sh" "$_c56_fx/repo/scripts/record-gate-head.sh"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  ': > "${C56_SENTINEL_DIR:?}/s1.ran"' \
  'awk '\''BEGIN { for (i = 0; i < 400; i++) printf "S1-LINE-%04d-0123456789abcdef0123456789abcdef0123456789abcdef\n", i }'\''' \
  'exit 0' > "$_c56_fx/repo/tests/s1/verify.sh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  ': > "${C56_SENTINEL_DIR:?}/s2.ran"' \
  'awk '\''BEGIN { for (i = 0; i < 400; i++) printf "S2-LINE-%04d-0123456789abcdef0123456789abcdef0123456789abcdef\n", i }'\''' \
  'exit 0' > "$_c56_fx/repo/tests/s2/verify.sh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  ': > "${C56_SENTINEL_DIR:?}/f1.ran"' \
  'echo "F1-INTENTIONAL-FAIL"' \
  'exit 1' > "$_c56_fx/repo/tests/f1/verify.sh"
chmod +x "$_c56_fx/repo/tests/s1/verify.sh" "$_c56_fx/repo/tests/s2/verify.sh" "$_c56_fx/repo/tests/f1/verify.sh"

_dg_git -C "$_c56_fx/repo" init -q . >/dev/null 2>&1 || true
_dg_git -C "$_c56_fx/repo" add -A >/dev/null 2>&1 || true
_dg_git -C "$_c56_fx/repo" commit -qm "c56-init" >/dev/null 2>&1 || true
_c56_head="$(git -C "$_c56_fx/repo" rev-parse HEAD)"

# 56-B: 実カーネルの標準出力クローズ（1>&-）下で逐次・並列とも全 suite 完走し gate-record が書かれる
for _c56_jobs in 1 2; do
  _c56_rec="$_c56_fx/rec-j${_c56_jobs}.env"
  _c56_err="$_c56_fx/err-j${_c56_jobs}.log"
  rm -f "$_c56_fx/s1.ran" "$_c56_fx/s2.ran" "$_c56_rec" "$_c56_err"
  if env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL -u FF_RUN_ALL_ALLOW_SKIP -u FF_RUN_ALL_CHANGED -u FF_RUN_ALL_ALLOW_DIRTY \
    -u FF_RUN_ALL_WAIT -u FF_RUN_ALL_WAIT_MAX_SECONDS \
    FF_RUN_ALL_ALLOW_DIRTY=1 FF_RUN_ALL_JOBS="$_c56_jobs" \
    FF_GATE_RECORD=1 FF_GATE_RECORD_FILE="$_c56_rec" \
    C56_SENTINEL_DIR="$_c56_fx" \
    bash "$_c56_fx/repo/tests/run-all.sh" \
      "$_c56_fx/repo/tests/s1/verify.sh" \
      "$_c56_fx/repo/tests/s2/verify.sh" 1>&- 2>"$_c56_err"; then
    _c56_rc=0
  else
    _c56_rc=$?
  fi
  _c56_wcnt="$(grep -cF '標準出力への書き込みに失敗しました' "$_c56_err" || true)"
  if [ "$_c56_rc" -eq 0 ] \
      && [ -e "$_c56_fx/s1.ran" ] && [ -e "$_c56_fx/s2.ran" ] \
      && [ "$_c56_wcnt" -eq 1 ] \
      && [ -s "$_c56_rec" ] \
      && grep -qF "COMMIT=${_c56_head}" "$_c56_rec" \
      && grep -qF 'STATUS=partial' "$_c56_rec" \
      && grep -qxF 'SUITES=s1 s2' "$_c56_rec" \
      && grep -qF 'RESULT=passed=2 failed=0 skipped=0 not-run=0' "$_c56_rec"; then
    ok "56-B(jobs=${_c56_jobs}): 閉じた stdout（1>&-）下でも全 suite 完走し rc=0・警告 1 回・gate-record 書込み完了"
  else
    bad "56-B(jobs=${_c56_jobs}): 閉じた stdout 下の完走に失敗（rc=${_c56_rc} s1=$([ -e "$_c56_fx/s1.ran" ] && echo y || echo n) s2=$([ -e "$_c56_fx/s2.ran" ] && echo y || echo n) wcnt=${_c56_wcnt} rec=$(cat "$_c56_rec" 2>/dev/null || echo MISSING)）"
  fi
done

# 56-C1: 陰性ケース — 閉じた stdout 下でも赤の suite は rc=1 と STATUS=fail で fail-closed（後続 suite も実行）
_c56_rec="$_c56_fx/rec-fail.env"
_c56_err="$_c56_fx/err-fail.log"
rm -f "$_c56_fx/f1.ran" "$_c56_fx/s2.ran" "$_c56_rec" "$_c56_err"
if env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL -u FF_RUN_ALL_ALLOW_SKIP -u FF_RUN_ALL_CHANGED -u FF_RUN_ALL_ALLOW_DIRTY \
  -u FF_RUN_ALL_WAIT -u FF_RUN_ALL_WAIT_MAX_SECONDS \
  FF_RUN_ALL_ALLOW_DIRTY=1 FF_RUN_ALL_JOBS=2 \
  FF_GATE_RECORD=1 FF_GATE_RECORD_FILE="$_c56_rec" \
  C56_SENTINEL_DIR="$_c56_fx" \
  bash "$_c56_fx/repo/tests/run-all.sh" \
    "$_c56_fx/repo/tests/f1/verify.sh" \
    "$_c56_fx/repo/tests/s2/verify.sh" 1>&- 2>"$_c56_err"; then
  _c56_rc=0
else
  _c56_rc=$?
fi
if [ "$_c56_rc" -eq 1 ] \
    && [ -e "$_c56_fx/f1.ran" ] && [ -e "$_c56_fx/s2.ran" ] \
    && [ -s "$_c56_rec" ] \
    && grep -qF 'STATUS=fail' "$_c56_rec" \
    && grep -qF 'RESULT=passed=1 failed=1 skipped=0 not-run=0' "$_c56_rec"; then
  ok "56-C1: 閉じた stdout 下で失敗 suite を含むと後続も完走しつつ rc=1・STATUS=fail で fail-closed"
else
  bad "56-C1: 失敗 suite の fail-closed が崩れた（rc=${_c56_rc} f1=$([ -e "$_c56_fx/f1.ran" ] && echo y || echo n) s2=$([ -e "$_c56_fx/s2.ran" ] && echo y || echo n) rec=$(cat "$_c56_rec" 2>/dev/null || echo MISSING)）"
fi

# 56-C2: 陰性ケース — 閉じた stdout 下でも不在 suite（not-run）は rc=1 と STATUS=fail で fail-closed
_c56_rec="$_c56_fx/rec-notrun.env"
_c56_err="$_c56_fx/err-notrun.log"
rm -f "$_c56_fx/s1.ran" "$_c56_rec" "$_c56_err"
if env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL -u FF_RUN_ALL_ALLOW_SKIP -u FF_RUN_ALL_CHANGED -u FF_RUN_ALL_ALLOW_DIRTY \
  -u FF_RUN_ALL_WAIT -u FF_RUN_ALL_WAIT_MAX_SECONDS \
  FF_RUN_ALL_ALLOW_DIRTY=1 FF_RUN_ALL_JOBS=1 \
  FF_GATE_RECORD=1 FF_GATE_RECORD_FILE="$_c56_rec" \
  C56_SENTINEL_DIR="$_c56_fx" \
  bash "$_c56_fx/repo/tests/run-all.sh" \
    "$_c56_fx/repo/tests/s1/verify.sh" \
    "$_c56_fx/repo/tests/missing/verify.sh" 1>&- 2>"$_c56_err"; then
  _c56_rc=0
else
  _c56_rc=$?
fi
if [ "$_c56_rc" -eq 1 ] \
    && [ -e "$_c56_fx/s1.ran" ] \
    && [ -s "$_c56_rec" ] \
    && grep -qF 'STATUS=fail' "$_c56_rec" \
    && grep -qF 'not-run=1' "$_c56_rec"; then
  ok "56-C2: 閉じた stdout 下で不在 suite を含むと rc=1・STATUS=fail・not-run=1 で fail-closed"
else
  bad "56-C2: 不在 suite の fail-closed が崩れた（rc=${_c56_rc} rec=$(cat "$_c56_rec" 2>/dev/null || echo MISSING)）"
fi

# 56-D: 変異対照 — ff_stdout_write "$FF_SUITE_OUTPUT" を素の printf へ戻すと閉じた stdout 下で途中終了し gate-record が失われる
_c56_mut="$_c56_fx/repo/tests/run-all.mut.sh"
awk '
  /^  ff_stdout_write "\$FF_SUITE_OUTPUT"$/ {
    print "  printf '\''%s\\n'\'' \"$FF_SUITE_OUTPUT\""
    next
  }
  { print }
' "$_c56_fx/repo/tests/run-all.sh" > "$_c56_mut"
if cmp -s "$_c56_fx/repo/tests/run-all.sh" "$_c56_mut"; then
  bad "56-D: 素の printf への戻し変異がアンカーに一致しなかった"
else
  _c56_rec="$_c56_fx/rec-mut.env"
  _c56_err="$_c56_fx/err-mut.log"
  rm -f "$_c56_fx/s1.ran" "$_c56_fx/s2.ran" "$_c56_rec" "$_c56_err"
  if env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL -u FF_RUN_ALL_ALLOW_SKIP -u FF_RUN_ALL_CHANGED -u FF_RUN_ALL_ALLOW_DIRTY \
    -u FF_RUN_ALL_WAIT -u FF_RUN_ALL_WAIT_MAX_SECONDS \
    FF_RUN_ALL_ALLOW_DIRTY=1 FF_RUN_ALL_JOBS=1 \
    FF_GATE_RECORD=1 FF_GATE_RECORD_FILE="$_c56_rec" \
    C56_SENTINEL_DIR="$_c56_fx" \
    bash "$_c56_mut" \
      "$_c56_fx/repo/tests/s1/verify.sh" \
      "$_c56_fx/repo/tests/s2/verify.sh" 1>&- 2>"$_c56_err"; then
    _c56_rc=0
  else
    _c56_rc=$?
  fi
  if [ "$_c56_rc" -ne 0 ] && [ -e "$_c56_fx/s1.ran" ] && [ ! -e "$_c56_fx/s2.ran" ] && [ ! -e "$_c56_rec" ]; then
    ok "56-D: 素の printf へ戻した変異は s1 実行後に閉じた stdout 下で rc=${_c56_rc} 途中終了し後続 suite と gate-record が欠落（56-B の対照）"
  else
    bad "56-D: 変異対照が障害を再現しなかった（rc=${_c56_rc} s1=$([ -e "$_c56_fx/s1.ran" ] && echo y || echo n) s2=$([ -e "$_c56_fx/s2.ran" ] && echo y || echo n) rec=$([ -e "$_c56_rec" ] && echo y || echo n)）"
  fi
fi

rm -rf "$_c56_fx"
fi

# suite-cases-end: startup-guards.sh
