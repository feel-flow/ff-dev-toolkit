#!/usr/bin/env bash
#
# multi-agent-critical-marker: 統合レポートの CRITICAL_BLOCK 判定の構造検査（Issue #272）。
#
# 背景: 旧判定式 `^\s*-\s*\[.*:.*\]` は重大度に関係なく [file:line] 形式の箇条書き
# すべてに発火し、Important のみのレビューでも「Critical issues detected」を宣言して
# いた（PR #270 で実際に発生）。CRITICAL_BLOCK は pre-push ゲート（docs-gates-runtime
# 参照）が push をブロックする根拠なので、誤出力は「Critical が無いのに push が
# 止まる」実害になる。逆に Critical の実所見でマーカーが出ない退行は、ゲートの
# 素通りという逆向きの実害になる。両方向を stub CLI の実走で固定する。
#
# 実 CLI は起動しない。codex コマンドを stub で覆い、レビュー本文だけを差し替えて
# orchestrator → generate_review_report の実経路を通す（判定式を単体で切り出して
# 検査すると、呼び出し側の変化で検査が別物になる）。
#
# 書き込み不可の環境では skip して成功扱いにする。
#
# Issue #1025: 別系列に残った未解消レポートがあっても、--cli だけのフルレビュー
# （codex-review.sh の既定入口）は新系列を開始する。絞り込みは非 0 で止まり
# --fresh を案内する。--fresh は lock 以外を <output-dir>/.prev-<ts>/ へ退避する。
#
# https://github.com/feel-flow/ff-dev-toolkit/issues/96 : その退避先は出力
# ディレクトリの**内側**でなければならない。兄弟
# （<output-dir>.prev-<ts>/）だと消費側の `.review-results/` という ignore 規約に
# 一致せず、退避一式がコミットへ巻き込まれる。ignore 済みであること（check-ignore /
# git status）と、退避先が今回の集計・残骸名指しに現れないことを併せて固定する。
#
# 変異検出（未解消 Critical ガードの原因別案内と文書追随。2026-09-13 実測。変異は 1 件ずつ
# 直列に当て、前後で対照を取る — 同じファイルへ 2 変異を同時に当てると一方の復元が他方を
# 巻き戻し、赤緑がどちらも信用できなくなる）:
#   区別できない 2 原因の併記を削る → 2 件赤。HEAD 破損側の直し方を削る → 1 件赤。
#   プロジェクトルート不在の案内を削る → 1 件赤。系列を作れない分岐へ --fresh 提示を足す
#   → 2 件赤。レポートを読めない分岐へ --fresh 提示を足す → 2 件赤。説明文書の
#   「ファイルを読めない」行から --fresh 禁止を外す → 1 件赤。案内側の case ラベルだけを
#   書き換える → 1 件赤。記録側の理由名だけを書き換える → 2 件赤。レポート側の既定アームを
#   削る → 1 件赤。レポート側の原因別アームを 2 つとも削る → 2 件赤。理由を書かずに返る分岐を
#   作る → 1 件赤。記録失敗の警告を出さなくする → 1 件赤。許可値だけを増やす → 2 件赤。
#   本文側を実装と矛盾する旧記述へ戻す → 1 件赤。
#
#   追加（2026-09-17 実測 / Issue `#1666`。SURVIVED 無し）:
#   SKILL.md 手順 1 の「新ブランチ初回は --fresh」前提を旧形へ戻す → 1 件赤（針は手順 1 の
#   節の中に限定してある。引数一覧の `--fresh` 行は残るので、文書全体の grep では緑で通る）。
#   is_unfiltered_full_review_plan から mode / perspective の条件を落とす（案 A へ寄せた形）
#   → 8 件赤。series 不一致なら filtered でも自動開始する（案 A の素朴実装）→ 8 件赤。
#   どちらも「標準起動形が別系列で中断する」「マージ済みの前 series でも自動開始しない」を
#   含めて赤になるので、将来 filtered 側を緩めるとここで気づく。
#   セルフレビュー指摘で追加（同日実測）: レビュー運用文書
#   （`docs-template/05-operations/deployment/multi-cli-review-orchestration.md`）の
#   該当段落から「手動退避は不要が成立するのはフルレビューだけ」を落とす → 1 件赤
#   （SKILL.md 手順 1 だけを固定していたので、運用文書の追記は消しても緑で通っていた）。
#   マージ済み series ブロックの fixture 復元を落とす → 1 件赤（後続へ実行順結合を
#   残す形。この 1 本が無いと約 1,000 行下で原因不明の失敗になる）。
#
#   **赤転しなかった変異を 1 つ記録する**: current_review_series_id 冒頭の「前回の失敗理由を
#   消す」処理を外す → 緑。失敗する分岐はすべて理由を書いてから返るので、消さなくても直後に
#   上書きされる。将来「理由を書かずに返る分岐」が足されたときだけ効く保険で、その分岐が
#   無いうちは観測できない（黙って外すと、保険が必要になった回に誰も気づかない）。その
#   「理由を書かずに返る分岐」の追加自体は、失敗 return と記録呼び出しの**件数一致**検査が
#   赤にする。
#
#   **赤転しなかった変異をもう 1 つ記録する**: review_series_failure_reason の実行トークン
#   照合（読んだ行を今回の実行が書いたのか確かめる部分）を外す → 緑。剥がし損ねた行は
#   `<別実行のトークン>:repo-root` のまま case へ渡るが、この文字列は原因別ラベルのどれにも
#   マッチせず既定アームへ落ちるので、案内の出力は変わらない（保護の実体は「書く行に
#   トークンを前置する形式」の側にあり、照合そのものは既定アームと二重防御になっている）。
#   実走で測るには「別実行の行が読み戻しまで生き残る」状態が要るが、
#   current_review_series_id は冒頭で理由ファイルを消すので、そこへ到達するには**親
#   ディレクトリが書き込み不可**でなければならない。これは root 実行では再現できず、
#   環境依存の skip を作らずに注入する手段が無い（既定アームの検査は「親ディレクトリごと
#   存在しない」パスで代替した — こちらは権限に依存しない）。case を持たない将来の消費側の
#   ための保険として残し、測れない事実をここに記録する。
#
#   **セルフレビューで塞いだ穴（すべて変異注入で緑を実測してから直した）**: (a) 消費側 case の
#   ラベルを 2 ブロック合併で比べていたため、レポート側ブロックを丸ごと消しても緑だった
#   → ブロックごとに比較する。(b) 既定アーム `*)` を見る検査が今回の diff で原因別の針へ
#   置き換わり無検査になっていた → 理由ファイルのシームを親ディレクトリごと存在しない
#   パスへ向けて実走で固定する。(c) レポート生成側の失敗経路に実走が 1 件も無かった
#   → 遅延注入（N 回目以降の symbolic-ref を落とす）でガードを通過させたまま発火させる。
#   (d) 文書の針が散文にも一致して表の消滅を拾えなかった → 針を表の行へ限定し、本文側の
#   ハンクを独立に固定する。(e) 無マッチ grep の代入が `set -euo pipefail` で落ち、直下の
#   「行が無い」bad が到達不能な死枝だった → `|| true` を通してから空を検出する。
#
#   **針を締め直した経緯も残す**: ルート不在の案内は最初「The project root is gone or
#   unreadable」だけを見ていたが、同じ語がレポート側の短い診断行にもあるため、中断分岐の
#   案内を削っても緑だった。静的な針は**その分岐だけに在る文字列**で持つこと。
#
#   **原因の数え方を実測へ合わせた経緯**: 当初は 3 原因（ルート不在 / worktree の外 /
#   HEAD 破損）を別々に名乗る実装にし、テストは `symbolic-ref` を rc=1 に偽装してから
#   `rev-parse` を落として HEAD 破損を作っていた。実測ではこの形は起きない — `.git/HEAD`
#   を壊すと `symbolic-ref` は **rc=128**（worktree の外と同じ）を返し、
#   `rev-parse --is-inside-work-tree` も 128 なので git から区別できない。detached の形
#   （rc=1）まで到達した HEAD は 40 桁 hex なので、実在しないオブジェクトでも `rev-parse` は
#   成功する。**起きない形を測っていた**ので、原因を 2 つに畳んで案内は両方を名乗る形にした。
#
# run-all-required: no — 一時領域が無い環境の skip を許容する（一時領域依存 suite の必須判断で名簿へ載せなかった側。必須へ昇格するなら REQUIRED_SUITES へ移す）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
# fixture リポジトリの identity を呼び出し元へ漏らさない（Issue #1348 / #1368）
# fixture リポジトリの identity を呼び出し元へ漏らさない（Issue #1348 / #1368）
# shellcheck source=../lib/git-fixture.sh
. "$SCRIPT_DIR/../lib/git-fixture.sh"

MULTI_AGENT="$PLUGIN_ROOT/scripts/multi-agent.sh"

[ -f "$MULTI_AGENT" ] || {
  echo "✗ 対象ファイルが見つかりません: $MULTI_AGENT" >&2
  exit 1
}

# 実行環境の MULTI_AGENT_* から分離する（Issue #374 / #378 の共通機構）。
# shellcheck source=../lib/adapter-env-isolation.sh
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"
build_isolate_env "MULTI_AGENT_CONFIG MULTI_AGENT_CODEX_PROFILE MULTI_AGENT_CRITICAL_NONBLOCK_PERSPECTIVES FF_MULTI_AGENT_REVIEW_SERIES_REASON_FILE" \
  "$MULTI_AGENT" "$PLUGIN_ROOT"/scripts/adapters/*.sh

# mktemp の stderr を捨てない。捨てると read-only 以外の失敗（TMPDIR が不正な
# パス・quota 超過など）まで「書き込み可能な環境で再実行してください」に誤帰属し、
# 恒常的に壊れた TMPDIR が suite を exit 0 で無効化し続ける。2>&1 で受けると
# 成功時はパス・失敗時は理由が同じ変数に入る。
# rc=0 でも -d を検査する — 2>&1 の合流は「成功 + stderr 警告」の環境で変数へ
# 警告文が混入し、以後の処理が原因不明の失敗に化けるため。
if _ff_mktemp_out="$(mktemp -d 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できない環境のためスキップ"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  FF_REACHED_END=1
  exit 0
fi
# 途中死を沈黙させない。`set -u` 等で死んだとき、トラップ突入時の $? は **0** になるため、
# 終了ステータスを保存し直すだけでは足りない（実測）。「rc=0 なのに最後まで到達して
# いない」を中断として扱う。明示的な非 0 終了はそのまま通す。
FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$TMP"
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ multi-agent-critical-marker: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# --- レビュー対象の差分を持つ一時リポジトリ ---
REPO="$TMP/repo"
ff_git_fixture_init "$REPO" "multi-agent-critical-marker-test" "test@example.com"
cd "$REPO"
git config commit.gpgsign false
git switch -q -c develop
echo base > app.txt
git add app.txt
git commit -qm "init"
git switch -q -c feature/x
printf 'base\nchange for review\n' > app.txt
git add app.txt
git commit -qm "change"

# --- stub CLI（codex のみ。レビュー本文は $TMP/body.md をそのまま出す） ---
STUB="$TMP/bin"
mkdir -p "$STUB"
cat > "$STUB/codex" <<SH
#!/usr/bin/env bash
printf 'call\n' >> "$TMP/stub-calls"
if [[ -f "$TMP/stub-exit" ]]; then
  exit "\$(cat "$TMP/stub-exit")"
fi
if [[ -f "$TMP/stub-sleep" ]]; then
  sleep 30
fi
if [[ -f "$TMP/stub-mutate-repo" ]]; then
  printf 'mutation during review\n' >> "$REPO/app.txt"
fi
# --fresh の退避はタスク実行の前に終わるので、ここから見るのは「退避後の
# ライブな出力ディレクトリ」。lock は実行終了時に解放されるので、実行後の
# 検査では「動かされていない」と「解放済み」を区別できない。
if [[ -f "$TMP/stub-probe-lock" ]]; then
  if [[ -d "$REPO/.review-results/.multi-agent-run.lock" ]]; then
    printf 'live-lock-present\n' > "$TMP/stub-lock-probe"
  else
    printf 'live-lock-missing\n' > "$TMP/stub-lock-probe"
  fi
fi
cat "$TMP/body.md"
SH
chmod +x "$STUB/codex"

# --- stub: tail / git（既定は素通し。センチネルが在るときだけ失敗させる） ---
# 未解消 Critical ガードの残り 3 分岐は「レポートを読めない」「現在の系列を
# 特定できない」という環境側の故障で、レポート本文の細工では到達できない
# （本文で作れるのは機械状態の破損まで）。失敗そのものを注入して実経路を通す。
# 素通しを既定にしているので、センチネルを置かないケースは一切影響を受けない。
# 「レポートを読めない」のうち**実運用で起きる形**（権限）は chmod 000 で直接
# 作るので、tail のセンチネルは chmod が効かない環境の代替と、抽出だけ成功した
# 状態（マーカー検査だけが落ちる）の生成に使う。
REAL_TAIL="$(command -v tail)"
REAL_GIT="$(command -v git)"
cat > "$STUB/tail" <<SH
#!/usr/bin/env bash
# multi-agent.sh がレポートを読む形は \`tail -n 12 <report>\` の 2 箇所だけ
# （機械状態の抽出 → Critical マーカー検査）。N 回目**以降を全部**落とすので、
# N=2 なら抽出を成功させたままマーカー検査だけを落とせ、N=1 なら両方落ちて
# 「ファイルが読めない」（chmod 000 と同じ形）になる。
if [[ -f "$TMP/tail-fail-nth" && "\$*" == "-n 12 "*"integrated-report.md" ]]; then
  printf 'x\n' >> "$TMP/tail-calls"
  if [[ "\$(wc -l < "$TMP/tail-calls")" -ge "\$(cat "$TMP/tail-fail-nth")" ]]; then
    exit 9
  fi
fi
exec "$REAL_TAIL" "\$@"
SH
chmod +x "$STUB/tail"
cat > "$STUB/git" <<SH
#!/usr/bin/env bash
# current_review_series_id() の \`git symbolic-ref --quiet HEAD\` だけを落とす。
# rc=1（detached）は正常系なので、rc!=1 のエラーを注入する。
# \`.git/HEAD\` が壊れている側も**実測では worktree の外と同じ rc=128** で、git から区別
# できない（\`--is-inside-work-tree\` も 128）。専用のセンチネルを分けると「別の形を測って
# いる」ように見えるが実体は同じ注入なので、1 つに畳んで案内の両方の名乗りを同じ実走で
# 固定する。偽装で rc=1 + rev-parse 失敗を作ると、実際には起きない形を測ることになる。
# 理由ファイルのシンボリックリンクを「削除の後・記録の前」に植える。
# current_review_series_id は冒頭で理由ファイルを消してから symbolic-ref を呼ぶので、
# ここは共有 /tmp で他ユーザーが割り込める窓とちょうど同じ位置になる。センチネルの
# 中身は植えるリンクのパス。
if [[ -f "$TMP/plant-reason-symlink" && "\$*" == "symbolic-ref --quiet HEAD" ]]; then
  ln -sfn "$TMP/series-reason-victim" "\$(cat "$TMP/plant-reason-symlink")"
fi
if [[ -f "$TMP/git-symbolic-ref-fail" && "\$*" == "symbolic-ref --quiet HEAD" ]]; then
  exit 128
fi
# レポート生成側（generate_review_report）の系列特定失敗を測るための遅延注入。ガード側は
# 通過させ、N 回目以降の symbolic-ref だけを落とす（tail-fail-nth と同じイディオム）。
if [[ -f "$TMP/git-symbolic-ref-fail-after" && "\$*" == "symbolic-ref --quiet HEAD" ]]; then
  printf 'x\n' >> "$TMP/git-symbolic-ref-calls"
  if [[ "\$(wc -l < "$TMP/git-symbolic-ref-calls")" -ge "\$(cat "$TMP/git-symbolic-ref-fail-after")" ]]; then
    exit 128
  fi
fi
exec "$REAL_GIT" "\$@"
SH
chmod +x "$STUB/git"

REPORT="$REPO/.review-results/integrated-report.md"
MARKER='<!-- CRITICAL_BLOCK -->'
NONBLOCK_MARKER='<!-- CRITICAL_NONBLOCK -->'

# run_case <ラベル> <expect: present|absent> <センチネル> <本文ヒアドキュメントを stdin から>
# センチネルは本文中の一意な行で、「本文がレポートに到達したこと」を先に確かめる。
# これが無いと、stub や adapter 経路の故障で本文が判定器に届かないまま absent ケースが
# 空振り合格する（マーカーが出ない理由が「Critical なし」ではなく「本文なし」でも ✓）。
#
# 観点別段階化（Issue #645）のケースは、既存ケースの呼び出しを変えないため
# グローバル opt-in で条件を渡す。run_case が冒頭で local へ取り込んだ直後に
# リセットするので、早期 return 経路でも次ケースへ漏れない:
#   CASE_PERSPECTIVE      実行する観点（既定 code-review。空文字の明示指定 =
#                         --perspective を渡さず、--cli の registry 所有観点を全部走らせる）
#   CASE_EXPECT_NONBLOCK  <!-- CRITICAL_NONBLOCK --> 注記の期待（present|absent、既定 absent）
#   CASE_NONBLOCK_ENV     設定すると MULTI_AGENT_CRITICAL_NONBLOCK_PERSPECTIVES として渡す
#                         （空文字も「明示指定」として渡す = 全観点ブロックの意思表示）
#   CASE_CONFIG_NONBLOCK  設定すると $REPO/.claude/agent-config.yaml の
#                         review.critical_nonblock_perspectives として書き込む
#                         （config 層の実挙動検査）
#   CASE_CONFIG_RAW       設定すると agent-config.yaml へ**そのまま**書き込む
#                         （YAML リスト誤設定など、整形済みの 1 文字列で表せない形用）
run_case() {
  local label="$1" expect="$2" sentinel="$3" rc=0
  local perspective="${CASE_PERSPECTIVE-code-review}"
  local expect_nonblock="${CASE_EXPECT_NONBLOCK:-absent}"
  local env_set=0 env_val="" cfg_set=0 cfg_val="" cfgraw_set=0 cfgraw_val=""
  if [[ "${CASE_NONBLOCK_ENV+set}" == "set" ]]; then
    env_set=1
    env_val="$CASE_NONBLOCK_ENV"
  fi
  if [[ "${CASE_CONFIG_NONBLOCK+set}" == "set" ]]; then
    cfg_set=1
    cfg_val="$CASE_CONFIG_NONBLOCK"
  fi
  if [[ "${CASE_CONFIG_RAW+set}" == "set" ]]; then
    cfgraw_set=1
    cfgraw_val="$CASE_CONFIG_RAW"
  fi
  unset CASE_PERSPECTIVE CASE_EXPECT_NONBLOCK CASE_NONBLOCK_ENV CASE_CONFIG_NONBLOCK CASE_CONFIG_RAW
  cat > "$TMP/body.md"
  if ! grep -qF "$sentinel" "$TMP/body.md"; then
    bad "${label}: fixture がセンチネル '${sentinel}' を含んでいない（self-test のバグ）"
    return
  fi
  rm -rf "$REPO/.review-results"
  # config はケース単位で用意し、使わないケースには残さない（前ケースの config が
  # 既定層の検査を黙って config 層の検査に変える汚染を防ぐ）
  rm -rf "$REPO/.claude"
  if [[ "$cfg_set" == "1" ]]; then
    mkdir -p "$REPO/.claude"
    printf 'review:\n  critical_nonblock_perspectives: "%s"\n' "$cfg_val" \
      > "$REPO/.claude/agent-config.yaml"
  elif [[ "$cfgraw_set" == "1" ]]; then
    mkdir -p "$REPO/.claude"
    printf '%s\n' "$cfgraw_val" > "$REPO/.claude/agent-config.yaml"
  fi
  # bash 3.2 + set -u は空配列の "${a[@]}" 展開で落ちるため、可変引数は分岐で渡す
  set +e
  if [[ "$env_set" == "1" && -n "$perspective" ]]; then
    run_isolated PATH="$STUB:$PATH" \
      MULTI_AGENT_CRITICAL_NONBLOCK_PERSPECTIVES="$env_val" bash "$MULTI_AGENT" \
      --task review --cli codex-cli --perspective "$perspective" \
      --base develop --timeout 60 >"$TMP/run.log" 2>&1
  elif [[ "$env_set" == "1" ]]; then
    run_isolated PATH="$STUB:$PATH" \
      MULTI_AGENT_CRITICAL_NONBLOCK_PERSPECTIVES="$env_val" bash "$MULTI_AGENT" \
      --task review --cli codex-cli \
      --base develop --timeout 60 >"$TMP/run.log" 2>&1
  elif [[ -n "$perspective" ]]; then
    run_isolated PATH="$STUB:$PATH" bash "$MULTI_AGENT" \
      --task review --cli codex-cli --perspective "$perspective" \
      --base develop --timeout 60 >"$TMP/run.log" 2>&1
  else
    run_isolated PATH="$STUB:$PATH" bash "$MULTI_AGENT" \
      --task review --cli codex-cli \
      --base develop --timeout 60 >"$TMP/run.log" 2>&1
  fi
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    bad "${label}: orchestrator が非 0 終了した (rc=$rc)"
    tail -5 "$TMP/run.log" | sed 's/^/    | /' >&2
    return
  fi
  if [[ ! -f "$REPORT" ]]; then
    bad "${label}: 統合レポートが生成されていない"
    return
  fi
  if ! grep -qF "$sentinel" "$REPORT"; then
    bad "${label}: 本文がレポートに到達していない（判定は空振り）"
    return
  fi
  if grep -qF "$MARKER" "$REPORT"; then
    if [[ "$expect" == "present" ]]; then
      ok "${label}: マーカーが出る"
    else
      bad "${label}: Critical が無い（またはブロック対象外）のにマーカーが出た（push ゲートの誤ブロック）"
      grep -n -B2 -A1 -F "$MARKER" "$REPORT" | sed 's/^/    | /' >&2
    fi
  else
    if [[ "$expect" == "absent" ]]; then
      ok "${label}: マーカーが出ない"
    else
      bad "${label}: Critical の実所見があるのにマーカーが出ない（push ゲートの素通り）"
    fi
  fi
  if grep -qF "$NONBLOCK_MARKER" "$REPORT"; then
    if [[ "$expect_nonblock" == "present" ]]; then
      ok "${label}: 非ブロック注記が出る"
    else
      bad "${label}: 非ブロック観点の Critical が無いのに注記が出た"
      grep -n -B2 -A2 -F "$NONBLOCK_MARKER" "$REPORT" | sed 's/^/    | /' >&2
    fi
  else
    if [[ "$expect_nonblock" == "absent" ]]; then
      : # 既定期待。ケースごとの ✓ は増やさない（既存ケースの出力を変えない）
    else
      bad "${label}: 非ブロック観点の Critical があるのに注記が出ない（重要度の情報が落ちた）"
    fi
  fi
}

echo "== CRITICAL_BLOCK 判定の構造検査 =="

# 1. Important のみ（[file:line] 箇条書きあり・Critical 0 件）→ 出ない
run_case "Important のみの [file:line] 箇条書き" absent "sentinel-case-1" <<'BODY'
<!-- sentinel-case-1 -->
## Code Review Results

### Critical Issues (信頼度 91-100)

なし。

### Important Issues (信頼度 80-90)
- [app.txt:2] 変更行の説明が不足している
  - 信頼度: 85
- [app.txt:1] 既存行との一貫性
  - 信頼度: 82

### Summary
- 検出された問題数: 2
- Critical: 0
- Important: 2
BODY

# 2. Critical セクションに実所見 → 出る
run_case "Critical セクションの実所見" present "sentinel-case-2" <<'BODY'
<!-- sentinel-case-2 -->
## Code Review Results

### Critical Issues (信頼度 91-100)
- [app.txt:2] 認証チェックの欠落
  - 信頼度: 95

### Summary
- Critical: 1
BODY

# 3. 箇条書きは無いが Summary の集計が Critical >= 1 → 出る
run_case "Summary 集計のみの Critical" present "sentinel-case-3" <<'BODY'
<!-- sentinel-case-3 -->
## Review

重大な問題を本文で説明する（箇条書きは使わない）。

### Summary
- Critical: 2
- Important: 0
BODY

# 4. 完了レビューがフェンス内と散文で Critical 判定文字列を引用 → 出ない
#    （本ツールが自身のスクリプトや perspective 文書をレビューすると実際に起こる形）
run_case "フェンス引用と散文言及のみ" absent "sentinel-case-4" <<'BODY'
<!-- sentinel-case-4 -->
## Code Review Results

判定式のレビュー。この検査は `- Critical: 1` のような Summary 行と、
行頭の CRITICAL: マーカーを探す（散文の中の言及はこの行のように無害）。
テンプレートの引用:

```markdown
### Critical Issues (信頼度 91-100)
- [ファイル名:行番号] 問題の説明

### Summary
- Critical: 1
```

### Summary
- 検出された問題数: 0
- Critical: 0
BODY

# 5. 行頭の大文字マーカー → 出る
run_case "行頭 CRITICAL: マーカー" present "sentinel-case-5" <<'BODY'
<!-- sentinel-case-5 -->
## Review

CRITICAL: authentication bypass in app.txt

### Summary
- Critical: 1
BODY

# 6. error-handler-hunt テンプレートの全大文字形 → 出る（同梱 perspective の実契約。
#    大文字小文字の吸収が落ちると同 perspective の Critical が丸ごと素通りする）
run_case "全大文字テンプレート（CRITICAL Issues / - CRITICAL: N）" present "sentinel-case-6" <<'BODY'
<!-- sentinel-case-6 -->
## Error Handler Hunt Results

### CRITICAL Issues
- [app.txt:2] エラーが握りつぶされている
  - 信頼度: 95

### Summary
- CRITICAL: 2
BODY

# 7. 未閉フェンスの後ろに実 Critical → 出る（フェンス不整合は判定不能として安全側 =
#    マーカーありへ倒す。旧トグル実装は以降を全部読み飛ばして素通りしていた）
run_case "未閉フェンスの後ろの実 Critical" present "sentinel-case-7" <<'BODY'
<!-- sentinel-case-7 -->
## Review

途中経過の引用:

```text
（この引用は閉じられないまま本文が続いてしまった）

### Critical Issues
- [app.txt:2] 認証チェックの欠落

### Summary
- Critical: 1
BODY

# 8. Critical 見出し配下の「- なし」箇条書き → 出ない（空所見の箇条書き表記。
#    ケース 1 の散文「なし。」と対で、最も紛らわしい変種を固定する）
run_case "Critical 見出し配下の - なし 箇条書き" absent "sentinel-case-8" <<'BODY'
<!-- sentinel-case-8 -->
## Code Review Results

### Critical Issues (信頼度 91-100)
- なし

### Important Issues (信頼度 80-90)
- [app.txt:2] 軽微な指摘

### Summary
- Critical: 0
BODY

# 9. 見出しなし・語彙違いの集計行のみ（test-analysis 形）→ 出る
run_case "集計行の語彙違い（- Critical Gaps: N）" present "sentinel-case-9" <<'BODY'
<!-- sentinel-case-9 -->
## Test Analysis

本文で重大なギャップを説明する（Critical 見出しは使わない）。

### Summary
- Critical Gaps: 2
BODY

# ── 観点別段階化（Issue #645）──

# 10. 非ブロック観点（既定名簿の comment-analysis）の Critical → CRITICAL_BLOCK は
#     出ず、CRITICAL_NONBLOCK 注記が出る（格下げの本体。修正必須の情報は落とさない）
CASE_PERSPECTIVE=comment-analysis CASE_EXPECT_NONBLOCK=present \
run_case "非ブロック観点（comment-analysis）の Critical" absent "sentinel-case-10" <<'BODY'
<!-- sentinel-case-10 -->
## Comment Analysis Results

### Critical Issues
- [app.txt:2] コメントが実装と食い違っている
  - 信頼度: 95

### Summary
- Critical: 1
BODY

# 10b. 消費側ゲートは囲みなしの部分一致 `grep -q "CRITICAL_BLOCK"` で判定する契約。
#      非ブロック注記のマーカー名・本文がその文字列を含むと、ブロックしないはずの
#      注記がブロックとして誤検知される。ケース 10 のレポート全体で消費側と同じ式が
#      不一致であることを固定する（本文 fixture 側にも当該文字列を書かないこと）。
if [[ -f "$REPORT" ]] && grep -qF "sentinel-case-10" "$REPORT"; then
  if grep -q "CRITICAL_BLOCK" "$REPORT"; then
    bad "非ブロック注記が消費側ゲートの部分一致 grep に誤検知される（CRITICAL_BLOCK を含む行がある）"
    grep -n "CRITICAL_BLOCK" "$REPORT" | sed 's/^/    | /' >&2
  else
    ok "非ブロック注記は消費側ゲートの部分一致 grep に掛からない"
  fi
else
  bad "ケース 10 のレポートが残っていない（10b は空振り）"
fi

# 11. 非ブロック観点でも Critical が無ければ注記も出ない（注記の誤出力は
#     「修正必須の指摘がある」という偽のシグナルになる）
CASE_PERSPECTIVE=comment-analysis \
run_case "非ブロック観点の Important のみ" absent "sentinel-case-11" <<'BODY'
<!-- sentinel-case-11 -->
## Comment Analysis Results

### Critical Issues
- なし

### Important Issues
- [app.txt:2] コメントの言い回しが冗長
  - 信頼度: 82

### Summary
- Critical: 0
BODY

# 12. 既定名簿に載っていない観点（comprehensive-review）の Critical → 従来どおり
#     ブロック（denylist 方式の fail closed。名簿は「格下げする観点」の列挙であり、
#     未知・未列挙の観点が黙って非ブロックへ落ちる退行を許さない）
CASE_PERSPECTIVE=comprehensive-review \
run_case "名簿外の観点（comprehensive-review）の Critical" present "sentinel-case-12" <<'BODY'
<!-- sentinel-case-12 -->
## Comprehensive Review Results

### Critical Issues
- [app.txt:2] 認可チェックの欠落
  - 信頼度: 96

### Summary
- Critical: 1
BODY

# 13. env に空文字を明示指定 → 全観点ブロック（旧挙動への復帰手段。
#     空文字が「未設定」と同一視されて既定名簿へ埋め戻される退行を固定する）
CASE_PERSPECTIVE=comment-analysis CASE_NONBLOCK_ENV="" \
run_case "env 空文字の明示指定で全観点ブロック" present "sentinel-case-13" <<'BODY'
<!-- sentinel-case-13 -->
## Comment Analysis Results

### Critical Issues
- [app.txt:2] コメントが実装と食い違っている
  - 信頼度: 95

### Summary
- Critical: 1
BODY

# 14. env で code-review を格下げ名簿へ（カンマ区切りの受理も兼ねる）→ 既定で
#     ブロックする観点も設定で非ブロックへ上書きできる
CASE_PERSPECTIVE=code-review CASE_EXPECT_NONBLOCK=present \
  CASE_NONBLOCK_ENV="code-review,comment-analysis" \
run_case "env 上書きで code-review を非ブロック化" absent "sentinel-case-14" <<'BODY'
<!-- sentinel-case-14 -->
## Code Review Results

### Critical Issues
- [app.txt:2] 認証チェックの欠落
  - 信頼度: 95

### Summary
- Critical: 1
BODY

# 15. 既定名簿の残り 3 観点も全件、非ブロックであることを固定する（ケース 10 の
#     comment-analysis と合わせて名簿 4 観点が揃う。どれか 1 つが既定から欠ける
#     変異でも該当ケースが赤くなる）
for _persp in test-analysis type-design-analysis code-simplification; do
  CASE_PERSPECTIVE="$_persp" CASE_EXPECT_NONBLOCK=present \
  run_case "既定名簿の非ブロック観点（${_persp}）の Critical" absent "sentinel-case-15" <<'BODY'
<!-- sentinel-case-15 -->
## Review Results

### Critical Issues
- [app.txt:2] 重大な指摘
  - 信頼度: 95

### Summary
- Critical: 1
BODY
done

# 16. 判定不能（未閉フェンス）× 非ブロック観点 → ブロックへ格上げせず、注記側で
#     「実所見」と区別された文言になる（本 PR が旧挙動から意図的に変えた唯一の
#     安全側分岐。「安全側だから」とブロックへ戻す将来のリファクタを赤にする）
CASE_PERSPECTIVE=comment-analysis CASE_EXPECT_NONBLOCK=present \
run_case "未閉フェンス × 非ブロック観点" absent "sentinel-case-16" <<'BODY'
<!-- sentinel-case-16 -->
## Comment Analysis Results

途中経過の引用:

```text
（この引用は閉じられないまま本文が続いてしまった）

### Critical Issues
- [app.txt:2] コメントが実装と食い違っている

### Summary
- Critical: 1
BODY
if [[ -f "$REPORT" ]] && grep -qF "sentinel-case-16" "$REPORT"; then
  if grep -qF "Unparseable result treated as critical, in non-blocking perspectives (comment-analysis)" "$REPORT"; then
    ok "判定不能は注記内で実所見と区別された文言になる"
  else
    bad "判定不能の注記文言が見当たらない（実所見と区別できず、空振りを所見と読ませる）"
  fi
  if grep -qF "Critical findings in non-blocking perspectives" "$REPORT"; then
    bad "判定不能しかないのに実所見の文言が出ている"
  else
    ok "判定不能のみのとき実所見の文言は出ない"
  fi
else
  bad "ケース 16 のレポートが残っていない（文言検査は空振り）"
fi

# 17. 裸の `Critical: 0` 独立行（comprehensive-review のゼロ件報告契約の形。
#     Issue #893 で契約化）→ 出ない。素の `^critical:` 判定はこの行で 100% 偽
#     CRITICAL_BLOCK を発火していた（3 巡目レビューの security-analysis 誤列挙で
#     実証）。ガードは「明示ゼロ」だけを除外し、ケース 5 の数字を含まない散文
#     マーカー（`CRITICAL: 説明`）の検出は維持する。
run_case "裸の Critical: 0 独立行（ゼロ件報告契約）" absent "sentinel-case-17" <<'BODY'
<!-- sentinel-case-17 -->
## 総合レビュー

観点間の隙間と相互作用を中心に diff 全体を確認したが、報告すべき問題は見つからなかった。

Critical: 0 / Warning: 0 / Suggestion: 0
BODY

# 18. 裸の `Critical: 0` 単独行（区切りなしの明示ゼロ）→ 出ない。
#     除外境界のもう一方の正例（ケース 17 は `/` 区切り形）。
run_case "裸の Critical: 0 単独行" absent "sentinel-case-18" <<'BODY'
<!-- sentinel-case-18 -->
## 総合レビュー

diff 全体を読解したが、報告すべき問題は無かった。

Critical: 0
BODY

# 19. `CRITICAL: 0-day …` 型の 0 始まり実指摘 → 出る。明示ゼロ除外を
#     `0([^0-9]|$)` のような広い形にすると、この実指摘まで明示ゼロとして
#     飲み込まれる（fail-open）。除外は「0 の直後が行末 / 空白+行末 / `/`
#     区切り」だけに限定していることの負の回帰。
# 注: Warning bullet はアダプタ側受理ゲートを通すためのもの（bullet 無しの
# `CRITICAL: 散文` は受理ゲートの実体行ではない — 受理と検出は別契約）。
# 集約側の Critical 検出は bare 行だけを見るので、この bullet は判定に混ざらない。
run_case "CRITICAL: 0-day 型の 0 始まり実指摘" present "sentinel-case-19" <<'BODY'
<!-- sentinel-case-19 -->
## Review

CRITICAL: 0-day exploit の兆候が diff の依存追加に含まれている

- Warning: 依存追加の検証手順が未記載
BODY

# 20. `### Critical` 配下の `- 指摘なし` → 出ない。空所見語彙はアダプタ側の
#     受理ゲート s2（指摘なし・該当なし・指摘事項なし）と揃える — 片側だけに
#     語彙があると「アダプタは受理するのに集約は実 Critical と数える」ドリフトで
#     偽 BLOCK になる（5 巡目で実測）。
run_case "Critical 見出し配下の - 指摘なし" absent "sentinel-case-20" <<'BODY'
<!-- sentinel-case-20 -->
## 総合レビュー

### Critical

- 指摘なし

### Warning

- 指摘なし
BODY

# 21. 裸の `Critical: 0 件` → 出ない（明示ゼロの日本語形。除外境界の「件」。
#     ケース 19 の 0-day 負回帰と対）。
run_case "裸の Critical: 0 件" absent "sentinel-case-21" <<'BODY'
<!-- sentinel-case-21 -->
## 総合レビュー

diff 全体を読解した。

Critical: 0 件
BODY

# 22. 裸の `Critical: none`（ゼロ語形の明示ゼロ）→ 出ない。アダプタ側受理ゲート
#     s1 はゼロ語（none / なし / n/a / ゼロ）を契約準拠ゼロ報告として受理する。
#     集約側の除外が数値形だけだと、この受理された正常系が偽 BLOCK になる
#     （語彙の対称性はケース 20 の空所見 bullet と同じ論点）。
run_case "裸の Critical: none（ゼロ語形）" absent "sentinel-case-22" <<'BODY'
<!-- sentinel-case-22 -->
## Review

diff was reviewed in full.

Critical: none
BODY

# 23. 裸の `Critical: zero`（英語ゼロ語のもう一形）→ 出ない。除外語彙は s1 の
#     実列挙（なし / none / n/a / zero / ゼロ）と完全一致させる — 1 語でも欠けると
#     その形の契約準拠ゼロ報告だけが偽 BLOCK になる。
run_case "裸の Critical: zero（英語ゼロ語）" absent "sentinel-case-23" <<'BODY'
<!-- sentinel-case-23 -->
## Review

diff was reviewed in full.

Critical: zero
BODY

# ── 共有パーサー（Issue #908）: 受理される全形式の Critical 指摘行で発火 ──
# アダプタ側受理ゲートが認める bullet 3 種・** 強調・散文指摘行は、共有パーサー
# 一本化（adapter-common.sh critical_findings_present）で集約側も検出する。
# 旧実装（`-` bullet + [1-9] のみの独自 regex）へ戻る変異はここで赤になる
# （受理と検出の全行対応表は tests/severity-parser-intersection が固定する）。

# 24. `*` bullet の集計行 → 出る（旧実装は `-` bullet しか見ず素通り = fail-open）
run_case "共有パーサー: * bullet の集計行" present "sentinel-case-24" <<'BODY'
<!-- sentinel-case-24 -->
## Review

本文で重大な問題を説明する。

### Summary
* Critical: 1
BODY

# 25. 行頭 `**Critical**:` の散文指摘行 → 出る（旧実装は ** 強調形を検出しない）
run_case "共有パーサー: ** 強調の散文指摘行" present "sentinel-case-25" <<'BODY'
<!-- sentinel-case-25 -->
## Review

**Critical**: 認証チェックの欠落（app.txt:2）
BODY

# 26. bullet + 件数なしの散文指摘行 → 出る（旧実装は [1-9] の件数必須で素通り）
run_case "共有パーサー: bullet + 件数なし指摘行" present "sentinel-case-26" <<'BODY'
<!-- sentinel-case-26 -->
## Review

- Critical: 認証チェックの欠落（app.txt:2）
BODY

# 27. bullet 付きゼロ語（`- Critical: none`）→ 出ない（受理ゲート s1 が契約準拠
#     ゼロ報告として受理する形。検出側の除外が bullet 形へ広がっていないと
#     偽 BLOCK になる — ケース 22 / 23 の bullet 版）
run_case "共有パーサー: bullet 付き Critical: none" absent "sentinel-case-27" <<'BODY'
<!-- sentinel-case-27 -->
## Review

diff was reviewed in full.

- Critical: none
BODY

# ── config 層（.claude/agent-config.yaml 経由）の実挙動 ──
# yq の有無で config 契約が丸ごと未検証にならないよう、この suite が書く最小
# config（printf の 2 行）だけを決定的に解釈する yq stub を用意して**常時**実行する。
# stub は実 yq の再実装ではない — 解釈対象の YAML はこの suite 自身が形を固定して
# 書いているので、sed 1 本で忠実に読める。実 yq が居る環境では代表 1 ケース +
# YAML リスト分岐を実 yq でも走らせ、stub と実物の乖離を検出する。
HAVE_YQ=0
command -v yq >/dev/null 2>&1 && HAVE_YQ=1
cat > "$STUB/yq" <<'SH'
#!/usr/bin/env bash
query="" file=""
for a in "$@"; do
  case "$a" in
    -r) ;;
    *) if [ -z "$query" ]; then query="$a"; else file="$a"; fi ;;
  esac
done
case "$query" in
  *critical_nonblock_perspectives*)
    sed -n 's/^  critical_nonblock_perspectives: "\(.*\)"$/\1/p' "$file" ;;
  .) cat "$file" ;;
  *) echo "" ;;
esac
SH
chmod +x "$STUB/yq"

# 17. config だけで code-review を格下げできる（env 未設定）
CASE_PERSPECTIVE=code-review CASE_EXPECT_NONBLOCK=present \
  CASE_CONFIG_NONBLOCK="code-review" \
run_case "config で code-review を非ブロック化 (stub yq)" absent "sentinel-case-17" <<'BODY'
<!-- sentinel-case-17 -->
## Code Review Results

### Critical Issues
- [app.txt:2] 認証チェックの欠落

### Summary
- Critical: 1
BODY

# 17b. config は既定名簿への**追加ではなく置換** — config が code-review だけを
#      挙げたら、既定名簿の comment-analysis はブロックへ戻る
CASE_PERSPECTIVE=comment-analysis CASE_CONFIG_NONBLOCK="code-review" \
run_case "config は既定名簿を置換する（comment-analysis はブロックへ戻る）(stub yq)" present "sentinel-case-17b" <<'BODY'
<!-- sentinel-case-17b -->
## Comment Analysis Results

### Critical Issues
- [app.txt:2] コメントが実装と食い違っている

### Summary
- Critical: 1
BODY

# 18. 非空 env は config より優先される（env に code-review が無い → ブロック）
CASE_PERSPECTIVE=code-review CASE_NONBLOCK_ENV="comment-analysis" \
  CASE_CONFIG_NONBLOCK="code-review" \
run_case "非空 env が config より優先 (stub yq)" present "sentinel-case-18" <<'BODY'
<!-- sentinel-case-18 -->
## Code Review Results

### Critical Issues
- [app.txt:2] 認証チェックの欠落

### Summary
- Critical: 1
BODY

# 19. 空文字 env は config より優先される（全観点ブロックへの復帰は config が
#     あっても埋め戻されない）
CASE_PERSPECTIVE=comment-analysis CASE_NONBLOCK_ENV="" \
  CASE_CONFIG_NONBLOCK="comment-analysis" \
run_case "空文字 env が config より優先（埋め戻さない）(stub yq)" present "sentinel-case-19" <<'BODY'
<!-- sentinel-case-19 -->
## Comment Analysis Results

### Critical Issues
- [app.txt:2] コメントが実装と食い違っている

### Summary
- Critical: 1
BODY

rm -f "$STUB/yq"

if [[ "$HAVE_YQ" -eq 1 ]]; then
  # 17R. 代表ケースを実 yq でも走らせ、stub と実物の乖離（クォート解釈の差など）を検出
  CASE_PERSPECTIVE=code-review CASE_EXPECT_NONBLOCK=present \
    CASE_CONFIG_NONBLOCK="code-review" \
  run_case "config で code-review を非ブロック化 (real yq)" absent "sentinel-case-17R" <<'BODY'
<!-- sentinel-case-17R -->
## Code Review Results

### Critical Issues
- [app.txt:2] 認証チェックの欠落

### Summary
- Critical: 1
BODY

  # L1/L2. YAML リストで書かれた config は警告して既定名簿へ落とす（リスト出力の
  #        形は yq 実装依存のため実 yq でのみ検査する）。fallback 先は「全観点
  #        ブロック」ではなく**既定名簿** — code-review はブロックへ、
  #        comment-analysis は非ブロックへ、がそれぞれ生きていること
  CASE_PERSPECTIVE=code-review \
    CASE_CONFIG_RAW=$'review:\n  critical_nonblock_perspectives:\n    - code-review' \
  run_case "YAML リスト config は既定へ fallback（code-review はブロック）" present "sentinel-case-L1" <<'BODY'
<!-- sentinel-case-L1 -->
## Code Review Results

### Critical Issues
- [app.txt:2] 認証チェックの欠落

### Summary
- Critical: 1
BODY
  if grep -qF "YAML リストではなく 1 文字列" "$TMP/run.log"; then
    ok "YAML リスト config に警告が出る"
  else
    bad "YAML リスト config の警告が出ていない（黙った fallback）"
  fi
  CASE_PERSPECTIVE=comment-analysis CASE_EXPECT_NONBLOCK=present \
    CASE_CONFIG_RAW=$'review:\n  critical_nonblock_perspectives:\n    - code-review' \
  run_case "YAML リスト config の fallback 先は既定名簿（comment-analysis は非ブロック）" absent "sentinel-case-L2" <<'BODY'
<!-- sentinel-case-L2 -->
## Comment Analysis Results

### Critical Issues
- [app.txt:2] コメントが実装と食い違っている

### Summary
- Critical: 1
BODY
else
  echo "  ○ skip: 実 yq が無いため代表照合（17R）と YAML リスト分岐（L1/L2）をスキップ（config 契約自体は stub yq で検査済み）"
fi

# ── 判定器（awk）自体の実行失敗（rc>2）の fail-closed ──
# Critical 判定器（共有パーサー _ff_severity_scan の critical モード —
# adapter-common.sh critical_findings_present）の awk 呼び出しだけを `-v
# ff_mode=critical` 引数で選択して失敗させる stub。同じ共有プログラムを使う
# アダプタ側の受理判定（ff_mode=accept）と他の awk 呼び出し（Status: incomplete
# 検査など）は実物へ委譲する — プログラム文字列での選択に戻すと、受理側まで
# 巻き添えで失敗してアダプタが本文なし扱いになり、このケースが検査したい
# 「集約判定だけの失敗」を再現できない。
REAL_AWK="$(command -v awk)"
cat > "$STUB/awk" <<SH
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in ff_mode=critical) exit 3 ;; esac
done
exec "$REAL_AWK" "\$@"
SH
chmod +x "$STUB/awk"

# 21. awk 失敗 × ブロック観点 → fail closed でマーカーが出る。本文は Critical なし
#     （Important のみ）にして、マーカーが所見ではなく判定不能から来ることを固定する
CASE_PERSPECTIVE=code-review \
run_case "awk 失敗 × ブロック観点は fail closed" present "sentinel-case-21" <<'BODY'
<!-- sentinel-case-21 -->
## Code Review Results

### Important Issues
- [app.txt:2] 軽微な指摘

### Summary
- Critical: 0
BODY
if [[ -f "$REPORT" ]] && grep -qF "sentinel-case-21" "$REPORT"; then
  if grep -qF "Unparseable result treated as critical (code-review)" "$REPORT"; then
    ok "awk 失敗はブロック側でも判定不能の文言になる"
  else
    bad "awk 失敗の判定不能文言が出ていない（実所見と区別できない）"
  fi
else
  bad "ケース 21 のレポートが残っていない（文言検査は空振り）"
fi

# 21b. awk 失敗 × 非ブロック観点 → 注記へ分類される（ブロックへ格上げしない）
CASE_PERSPECTIVE=comment-analysis CASE_EXPECT_NONBLOCK=present \
run_case "awk 失敗 × 非ブロック観点は注記へ" absent "sentinel-case-21b" <<'BODY'
<!-- sentinel-case-21b -->
## Comment Analysis Results

### Important Issues
- [app.txt:2] 軽微な指摘

### Summary
- Critical: 0
BODY
if [[ -f "$REPORT" ]] && grep -qF "sentinel-case-21b" "$REPORT"; then
  if grep -qF "Unparseable result treated as critical, in non-blocking perspectives (comment-analysis)" "$REPORT"; then
    ok "awk 失敗は非ブロック側でも判定不能の文言になる"
  else
    bad "awk 失敗（非ブロック側）の判定不能文言が出ていない"
  fi
else
  bad "ケース 21b のレポートが残っていない（文言検査は空振り）"
fi

rm -f "$STUB/awk"

# 22. タブ区切りの env 名簿も受理される（正規化が落ちるとタブ区切りの観点が
#     黙ってブロック側へ倒れ、利用者の指定が静かに無視される）
CASE_PERSPECTIVE=code-review CASE_EXPECT_NONBLOCK=present \
  CASE_NONBLOCK_ENV=$'code-review\tcomment-analysis' \
run_case "タブ区切りの env 名簿" absent "sentinel-case-22" <<'BODY'
<!-- sentinel-case-22 -->
## Code Review Results

### Critical Issues
- [app.txt:2] 認証チェックの欠落

### Summary
- Critical: 1
BODY

# 20. ブロック観点と非ブロック観点の Critical が同一レポートに混在する
#     （--perspective を渡さず codex-cli の registry 所有 = code-review +
#     test-analysis + acceptance-criteria の 3 観点を実走。stub は同じ本文を
#     返すので全観点が Critical） → 両マーカーが共存し、各行の観点名の帰属が正しい
#     （ブロック側は code-review と acceptance-criteria の 2 観点が並ぶ）
CASE_PERSPECTIVE="" CASE_EXPECT_NONBLOCK=present \
run_case "ブロック + 非ブロックの混在" present "sentinel-case-20" <<'BODY'
<!-- sentinel-case-20 -->
## Review Results

### Critical Issues
- [app.txt:2] 重大な指摘
  - 信頼度: 95

### Summary
- Critical: 1
BODY
if [[ -f "$REPORT" ]] && grep -qF "sentinel-case-20" "$REPORT"; then
  if grep -qF "Critical issues detected (code-review, acceptance-criteria)" "$REPORT"; then
    ok "ブロック行の観点名が code-review と acceptance-criteria に帰属する"
  else
    bad "ブロック行の観点名の帰属が崩れている"
    grep -n "Critical issues detected" "$REPORT" | sed 's/^/    | /' >&2
  fi
  if grep -qF "Critical findings in non-blocking perspectives (test-analysis)" "$REPORT"; then
    ok "非ブロック行の観点名が test-analysis に帰属する"
  else
    bad "非ブロック行の観点名の帰属が崩れている"
    grep -n "Critical findings in non-blocking" "$REPORT" | sed 's/^/    | /' >&2
  fi
else
  bad "ケース 20 のレポートが残っていない（帰属検査は空振り）"
fi

echo "== 未解消 Critical を除外する部分再検証の拒否 =="

run_sequence_step() { # $1: orchestrator / $2: perspective / $3: log / $4: timeout / $5: resume
  local target="$1" perspective="$2" log="$3" timeout="${4:-60}" resume="${5:-false}"
  SEQUENCE_RC=0
  set +e
  if [[ "$resume" == "true" ]]; then
    run_isolated PATH="$STUB:$PATH" bash "$target" \
      --task review --cli codex-cli --perspective "$perspective" \
      --base develop --timeout "$timeout" --resume >"$log" 2>&1
  else
    run_isolated PATH="$STUB:$PATH" bash "$target" \
      --task review --cli codex-cli --perspective "$perspective" \
      --base develop --timeout "$timeout" >"$log" 2>&1
  fi
  SEQUENCE_RC=$?
  set -e
}

rm -rf "$REPO/.review-results"
cat > "$TMP/body.md" <<'BODY'
<!-- sentinel-unresolved-critical -->
## Code Review Results

### Critical Issues
- [app.txt:2] 認証チェックの欠落

### Summary
- Critical: 1
BODY
run_sequence_step "$MULTI_AGENT" code-review "$TMP/unresolved-initial.log"
if [[ "$SEQUENCE_RC" -eq 0 && -f "$REPORT" ]] \
  && grep -qF "$MARKER" "$REPORT" \
  && tail -n 1 "$REPORT" | grep -F 'block:code-review nonblock:-' >/dev/null; then
  ok "未解消 Critical の初回レポートが機械可読な観点状態を持つ"
else
  bad "未解消観点の初回状態を作れない (rc=$SEQUENCE_RC)"
fi

cp "$REPORT" "$TMP/report-before-omission.md"

# ガード通過後の setup failure でも、唯一の永続状態である旧レポートを失わない。
mv "$REPO/.review-results/codex-cli" "$TMP/codex-cli-before-setup-failure"
mkdir -p "$TMP/outside-result-dir"
ln -s "$TMP/outside-result-dir" "$REPO/.review-results/codex-cli"
run_sequence_step "$MULTI_AGENT" code-review "$TMP/unresolved-setup-failure.log"
if [[ "$SEQUENCE_RC" -ne 0 ]] \
  && grep -qF 'Aborted before running any task' "$TMP/unresolved-setup-failure.log" \
  && cmp -s "$TMP/report-before-omission.md" "$REPORT"; then
  ok "再検証の準備失敗でも前回の未解消レポートを保持する"
else
  bad "準備失敗で前回の未解消状態が失われる (rc=$SEQUENCE_RC)"
fi
rm "$REPO/.review-results/codex-cli"
mv "$TMP/codex-cli-before-setup-failure" "$REPO/.review-results/codex-cli"

# タスク完了後の revision guard 失敗でも、旧レポートを新しい成功扱いに
# 置き換えず、次回の省略ガードへ残す。
touch "$TMP/stub-mutate-repo"
run_sequence_step "$MULTI_AGENT" code-review "$TMP/unresolved-revision-failure.log"
rm -f "$TMP/stub-mutate-repo"
printf 'base\nchange for review\n' > "$REPO/app.txt"
if [[ "$SEQUENCE_RC" -ne 0 ]] \
  && grep -qF 'The repository changed while the review was running' "$TMP/unresolved-revision-failure.log" \
  && cmp -s "$TMP/report-before-omission.md" "$REPORT"; then
  ok "リビジョン変更で破棄した再検証も前回の未解消レポートを保持する"
else
  bad "リビジョン変更で前回の未解消状態が失われる (rc=$SEQUENCE_RC)"
fi

calls_before="$(wc -l < "$TMP/stub-calls" | tr -d ' ')"
run_sequence_step "$MULTI_AGENT" code-review "$TMP/unresolved-after-revision-resume.log" 60 true
calls_after="$(wc -l < "$TMP/stub-calls" | tr -d ' ')"
if [[ "$SEQUENCE_RC" -eq 0 && "$calls_after" -eq $((calls_before + 1)) ]] \
  && grep -qF "$MARKER" "$REPORT"; then
  ok "リビジョン変更で破棄した結果を resume cache から再利用しない"
else
  bad "破棄した再検証結果が resume cache から再利用された (rc=$SEQUENCE_RC)"
fi
cp "$REPORT" "$TMP/report-before-omission.md"

cat > "$TMP/body.md" <<'BODY'
<!-- sentinel-omitted-perspective -->
## Comment Analysis Results

### Critical Issues
- なし

### Summary
- Critical: 0
BODY
run_sequence_step "$MULTI_AGENT" comment-analysis "$TMP/unresolved-omitted.log"
if [[ "$SEQUENCE_RC" -ne 0 ]] \
  && grep -qF 'omits unresolved Critical perspective(s): code-review' "$TMP/unresolved-omitted.log"; then
  ok "未解消観点を除外した部分再検証を実行前に拒否する"
else
  bad "未解消観点を除外した部分再検証が拒否されない (rc=$SEQUENCE_RC)"
fi
if cmp -s "$TMP/report-before-omission.md" "$REPORT" \
  && [[ ! -e "$REPO/.review-results/codex-cli/comment-analysis.md" ]]; then
  ok "拒否時は直前レポートと結果ファイルを変更しない"
else
  bad "拒否前の証拠が書き換えられた"
fi

# 別ブランチの同名観点で元ブランチの状態を解消できない。
git switch -q -c other-review-series
run_sequence_step "$MULTI_AGENT" code-review "$TMP/other-series.log"
if [[ "$SEQUENCE_RC" -ne 0 ]] \
  && grep -qF 'belongs to another branch/base/scope' "$TMP/other-series.log" \
  && grep -qF -- '--fresh' "$TMP/other-series.log"; then
  ok "別ブランチからの絞り込み付き再検証を拒否する"
else
  bad "別ブランチの同名観点が元の未解消状態を通過した (rc=$SEQUENCE_RC)"
fi
if cmp -s "$TMP/report-before-omission.md" "$REPORT"; then
  ok "レビュー系列の不一致拒否時も前回レポートを保持する"
else
  bad "レビュー系列の不一致拒否時に証拠が変更された"
fi

SEQUENCE_RC=0
set +e
run_isolated PATH="$STUB:/usr/bin:/bin" bash "$MULTI_AGENT" \
  --task review --mode cross-model --base develop --timeout 60 \
  >"$TMP/other-series-cross-model.log" 2>&1
SEQUENCE_RC=$?
set -e
if [[ "$SEQUENCE_RC" -ne 0 ]] \
  && grep -qF 'belongs to another branch/base/scope' "$TMP/other-series-cross-model.log" \
  && cmp -s "$TMP/report-before-omission.md" "$REPORT"; then
  ok "別系列の cross-model 単一観点をフルレビューとして扱わない"
else
  bad "cross-model 単一観点が別系列の未解消状態を解除した (rc=$SEQUENCE_RC)"
fi

# --- Issue `#1666`: 標準の /multi-review 起動形は「前 series がマージ済み」でも
#     新シリーズを自動開始しない（案 A を採らなかったことを挙動で固定する） ---
#
# 導入先の Git Workflow が案内する標準起動は
#   --mode cross-model --strategy minimize_cost --perspective code-review --base origin/develop
# で、`--mode cross-model` と `--perspective` のどちらも unfiltered の条件を外す。
# したがって新しいブランチの初回は毎回 1 度中断し、`--fresh` を足して再実行になる。
#
# **案 A（前 series のブランチがマージ済みなら filtered でも自動開始する）は
# 実装できない。** 系列 ID は repo/branch/base/scope を `cksum` で畳んだダイジェスト
# （`current_review_series_id`）で、レポート末尾の機械状態が持つのは `series:<n>-<n>`
# だけ。ブランチ名が 1 文字も残らないので、残骸の側から到達可能性を判定する材料が無い。
# 判定材料を足すには機械状態の書式を変えることになり、既存の残骸がすべて legacy 扱いへ
# 落ちる（= 同じ中断が 1 回起きる）。よって案 B（SKILL.md の手順へ前提として書く）を
# 採った。下の 2 本は、その判断が「マージ済みでも中断する」という形で実際に効いている
# ことを固定する — 将来 filtered 側の条件を緩めるなら、ここが赤くなって気付く。
SEQUENCE_RC=0
set +e
run_isolated PATH="$STUB:/usr/bin:/bin" bash "$MULTI_AGENT" \
  --task review --mode cross-model --perspective code-review --base develop --timeout 60 \
  >"$TMP/standard-invocation-other-series.log" 2>&1
SEQUENCE_RC=$?
set -e
if [[ "$SEQUENCE_RC" -ne 0 ]] \
  && grep -qF 'belongs to another branch/base/scope' "$TMP/standard-invocation-other-series.log" \
  && grep -qF -- '--fresh' "$TMP/standard-invocation-other-series.log" \
  && cmp -s "$TMP/report-before-omission.md" "$REPORT"; then
  ok "標準起動形（cross-model + perspective）は別系列で中断し --fresh を案内する"
else
  bad "標準起動形が別系列の未解消状態を素通しした (rc=$SEQUENCE_RC)"
fi

# 前 series のブランチを base へマージしても判定は変わらない（ガードは到達可能性を
# 見ていない。上の理由により見る材料が無い）。
#
# マージの前に現在のブランチへ 1 コミット足す。足さないと `feature/x` を develop へ
# 畳んだ時点で `develop...HEAD` の diff が空になり、レビュー対象なしの別経路で
# 中断してしまう（= 系列ガードを 1 度も通らないまま「中断した」ことになる）。
SERIES_PROBE_BEFORE="$(git rev-parse HEAD)"
printf 'issue-1666\n' > "$REPO/merged-series-probe.txt"
git add merged-series-probe.txt
git commit -q -m "probe: keep a diff against develop after the merge"
DEVELOP_BEFORE_MERGE="$(git rev-parse develop)"
git switch -q develop
git merge -q --no-ff -m "merge feature/x into develop" feature/x
git switch -q other-review-series
if git merge-base --is-ancestor feature/x develop \
  && [[ -n "$(git diff --name-only develop...HEAD)" ]]; then
  ok "前提: 前 series のブランチが base から到達可能で、かつ今回の diff は空でない"
else
  bad "前提が作れていない: feature/x の到達可能性 or develop...HEAD の diff"
fi
SEQUENCE_RC=0
set +e
run_isolated PATH="$STUB:/usr/bin:/bin" bash "$MULTI_AGENT" \
  --task review --mode cross-model --perspective code-review --base develop --timeout 60 \
  >"$TMP/merged-previous-series.log" 2>&1
SEQUENCE_RC=$?
set -e
if [[ "$SEQUENCE_RC" -ne 0 ]] \
  && grep -qF 'belongs to another branch/base/scope' "$TMP/merged-previous-series.log" \
  && grep -qF 'Run an unfiltered full review to start a new review series' "$TMP/merged-previous-series.log" \
  && cmp -s "$TMP/report-before-omission.md" "$REPORT"; then
  ok "前 series がマージ済みでも filtered 起動は新シリーズを自動開始しない（案 A 不採用の固定）"
else
  bad "マージ済みの前 series で filtered 起動が自動開始した (rc=$SEQUENCE_RC): $(tail -n 8 "$TMP/merged-previous-series.log")"
fi
git switch -q develop
git reset -q --hard "$DEVELOP_BEFORE_MERGE"
git switch -q other-review-series
# **ブロック前後で fixture の状態を同一に戻す。** 約 2,700 行の suite で、このブロック
# だけがブランチトポロジと作業ツリーを触る。probe コミットを残すと、後続ケースが
# commit 数や `develop...HEAD` の中身に依存し始めた時点で「原因が 1,000 行上にある」
# 形で壊れる。`git reset --hard` は切り替えで持ち回っている作業ツリーの変更も巻き添えに
# するので、退避してから戻す（2026-09-17 指摘）。
git stash -q --include-untracked 2>/dev/null || true
git reset -q --hard "$SERIES_PROBE_BEFORE"
git stash pop -q 2>/dev/null || true
rm -f "$REPO/merged-series-probe.txt"
if [ "$(git rev-parse HEAD)" = "$SERIES_PROBE_BEFORE" ] \
  && [ "$(git rev-parse develop)" = "$DEVELOP_BEFORE_MERGE" ] \
  && [ ! -e "$REPO/merged-series-probe.txt" ]; then
  ok "マージ済み series ブロックは fixture の状態を元へ戻す（後続へ実行順結合を残さない）"
else
  bad "マージ済み series ブロックが fixture を戻していない（HEAD=$(git rev-parse --short HEAD) develop=$(git rev-parse --short develop)）"
fi

mv "$REPO/.review-results/codex-cli" "$TMP/codex-cli-before-new-series-setup-failure"
mkdir -p "$TMP/outside-new-series-result-dir"
ln -s "$TMP/outside-new-series-result-dir" "$REPO/.review-results/codex-cli"
SEQUENCE_RC=0
set +e
run_isolated PATH="$STUB:/usr/bin:/bin" \
  MULTI_AGENT_REVIEW_MAIN=codex-cli MULTI_AGENT_REVIEW_SUB= \
  bash "$MULTI_AGENT" --task review --base develop --timeout 60 \
  >"$TMP/new-series-setup-failure.log" 2>&1
SEQUENCE_RC=$?
set -e
if [[ "$SEQUENCE_RC" -ne 0 ]] \
  && grep -qF 'Aborted before running any task' "$TMP/new-series-setup-failure.log" \
  && cmp -s "$TMP/report-before-omission.md" "$REPORT"; then
  ok "別系列のフルレビューも準備失敗時は前系列の未解消レポートを保持する"
else
  bad "別系列の準備失敗で前系列の未解消状態が失われる (rc=$SEQUENCE_RC)"
fi
rm "$REPO/.review-results/codex-cli"
mv "$TMP/codex-cli-before-new-series-setup-failure" "$REPO/.review-results/codex-cli"
git switch -q feature/x

# Guard call を外した変異は、同じ入力で部分再検証を通し、マーカーを
# 最新レポートから消すことを実測する。
MUTANT_PLUGIN="$TMP/mutant-plugin"
cp -R "$PLUGIN_ROOT" "$MUTANT_PLUGIN"
sed '/capture_and_guard_unresolved_critical_state || return 2/d' \
  "$MULTI_AGENT" > "$MUTANT_PLUGIN/scripts/multi-agent.sh.mutant"
mv "$MUTANT_PLUGIN/scripts/multi-agent.sh.mutant" "$MUTANT_PLUGIN/scripts/multi-agent.sh"
chmod +x "$MUTANT_PLUGIN/scripts/multi-agent.sh"
run_sequence_step "$MUTANT_PLUGIN/scripts/multi-agent.sh" comment-analysis "$TMP/unresolved-mutant.log"
if [[ "$SEQUENCE_RC" -eq 0 && -f "$REPORT" ]] \
  && grep -qF 'sentinel-omitted-perspective' "$REPORT" \
  && ! grep -qF "$MARKER" "$REPORT"; then
  ok "ガード除去変異は未解消マーカーを消す（suite が退行を検出できる）"
else
  bad "ガード除去変異が従来の偽の緑を再現しない (rc=$SEQUENCE_RC)"
fi

# 未解消観点を再実行しても、CLI 失敗は解消の証拠ではない。
rm -rf "$REPO/.review-results"
cat > "$TMP/body.md" <<'BODY'
<!-- sentinel-rerun-failure-initial -->
## Code Review Results
### Critical Issues
- [app.txt:2] 認可欠落
### Summary
- Critical: 1
BODY
run_sequence_step "$MULTI_AGENT" code-review "$TMP/rerun-failure-initial.log"
printf '17\n' > "$TMP/stub-exit"
run_sequence_step "$MULTI_AGENT" code-review "$TMP/rerun-failure.log"
rm -f "$TMP/stub-exit"
if [[ "$SEQUENCE_RC" -ne 0 ]]; then
  ok "未解消観点の CLI 失敗を非 0 で報告する"
else
  bad "未解消観点の CLI 失敗が成功扱いになった"
fi
if [[ -f "$REPORT" ]] \
  && grep -qF 'Previous Critical remains unresolved because its rerun produced no verdict — it failed, was skipped, or is still delegated to the host (code-review).' "$REPORT" \
  && grep -qF "$MARKER" "$REPORT"; then
  ok "再実行失敗時は前回の未解消マーカーを保持する"
else
  bad "再実行失敗時に未解消マーカーが消えた"
fi

touch "$TMP/stub-sleep"
run_sequence_step "$MULTI_AGENT" code-review "$TMP/rerun-timeout.log" 1
rm -f "$TMP/stub-sleep"
if [[ "$SEQUENCE_RC" -ne 0 ]] && grep -qF 'timed out after 1s' "$TMP/rerun-timeout.log"; then
  ok "未解消観点の実 timeout を非 0 で報告する"
else
  bad "未解消観点の実 timeout 経路を作れない (rc=$SEQUENCE_RC)"
fi
if [[ -f "$REPORT" ]] \
  && grep -qF 'Previous Critical remains unresolved because its rerun produced no verdict — it failed, was skipped, or is still delegated to the host (code-review).' "$REPORT" \
  && grep -qF "$MARKER" "$REPORT"; then
  ok "実 timeout 時も前回の未解消マーカーを保持する"
else
  bad "実 timeout 時に未解消マーカーが消えた"
fi

# 正しい観点が正常完了して解消した場合だけ、状態を消す。
cat > "$TMP/body.md" <<'BODY'
<!-- sentinel-resolved-perspective -->
## Code Review Results
### Critical Issues
- なし
### Summary
- Critical: 0
BODY
run_sequence_step "$MULTI_AGENT" code-review "$TMP/resolved.log"
if [[ "$SEQUENCE_RC" -eq 0 && -f "$REPORT" ]] \
  && grep -qF 'sentinel-resolved-perspective' "$REPORT" \
  && ! grep -qF "$MARKER" "$REPORT" \
  && tail -n 1 "$REPORT" | grep -F 'block:- nonblock:-' >/dev/null; then
  ok "未解消観点の正常再実行でマーカーを解消できる"
else
  bad "未解消観点を正常再実行しても解消できない (rc=$SEQUENCE_RC)"
fi

cat > "$TMP/body.md" <<'BODY'
<!-- sentinel-after-resolution -->
## Comment Analysis Results
### Critical Issues
- なし
### Summary
- Critical: 0
BODY
run_sequence_step "$MULTI_AGENT" comment-analysis "$TMP/after-resolution.log"
if [[ "$SEQUENCE_RC" -eq 0 && -f "$REPORT" ]] \
  && grep -qF 'sentinel-after-resolution' "$REPORT" \
  && ! grep -qF "$MARKER" "$REPORT"; then
  ok "解消後は別観点の部分再検証を許可する"
else
  bad "解消後も部分再検証が拒否される (rc=$SEQUENCE_RC)"
fi

git switch -q -c cleared-other-review-series
run_sequence_step "$MULTI_AGENT" comment-analysis "$TMP/after-resolution-other-series.log"
if [[ "$SEQUENCE_RC" -eq 0 && -f "$REPORT" ]] \
  && grep -qF 'sentinel-after-resolution' "$REPORT" \
  && ! grep -qF "$MARKER" "$REPORT"; then
  ok "未解消観点が無ければ別レビュー系列の絞り込みも許可する"
else
  bad "解消済み状態なのに別レビュー系列の絞り込みが拒否される (rc=$SEQUENCE_RC)"
fi
git switch -q feature/x

# 非ブロック観点も同じ生命周期で保護する。
rm -rf "$REPO/.review-results"
cat > "$TMP/body.md" <<'BODY'
<!-- sentinel-nonblock-initial -->
## Comment Analysis Results
### Critical Issues
- 用語の事実誤認
### Summary
- Critical: 1
BODY
run_sequence_step "$MULTI_AGENT" comment-analysis "$TMP/nonblock-initial.log"
if [[ "$SEQUENCE_RC" -eq 0 && -f "$REPORT" ]] \
  && grep -qF "$NONBLOCK_MARKER" "$REPORT" \
  && tail -n 1 "$REPORT" | grep -F 'nonblock:comment-analysis' >/dev/null; then
  ok "非ブロック Critical も観点状態として記録する"
else
  bad "非ブロック Critical の初回状態を作れない"
fi
run_sequence_step "$MULTI_AGENT" code-review "$TMP/nonblock-omitted.log"
if [[ "$SEQUENCE_RC" -ne 0 ]] \
  && grep -qF 'omits unresolved Critical perspective(s): comment-analysis' "$TMP/nonblock-omitted.log"; then
  ok "未解消の非ブロック観点を省く再検証も拒否する"
else
  bad "非ブロック観点の省略を拒否できない"
fi
printf '17\n' > "$TMP/stub-exit"
run_sequence_step "$MULTI_AGENT" comment-analysis "$TMP/nonblock-failed.log"
rm -f "$TMP/stub-exit"
if [[ "$SEQUENCE_RC" -ne 0 && -f "$REPORT" ]] \
  && grep -qF 'Previous non-blocking Critical remains unresolved because its rerun produced no verdict — it failed, was skipped, or is still delegated to the host (comment-analysis).' "$REPORT"; then
  ok "非ブロック観点も再実行失敗時に分類を保持する"
else
  bad "非ブロック観点の失敗時保持が機能しない"
fi
cat > "$TMP/body.md" <<'BODY'
<!-- sentinel-nonblock-resolved -->
## Comment Analysis Results
### Critical Issues
- なし
### Summary
- Critical: 0
BODY
run_sequence_step "$MULTI_AGENT" comment-analysis "$TMP/nonblock-resolved.log"
if [[ "$SEQUENCE_RC" -eq 0 && -f "$REPORT" ]] \
  && ! grep -qF "$NONBLOCK_MARKER" "$REPORT" \
  && tail -n 1 "$REPORT" | grep -F 'nonblock:-' >/dev/null; then
  ok "非ブロック観点も正常再実行で解消できる"
else
  bad "非ブロック観点を正常再実行しても解消できない"
fi

# 機械状態の構文破損は未解消なしとして通さない。
cat > "$REPORT" <<'REPORT_BODY'
<!-- CRITICAL_BLOCK -->
Critical issues detected (code-review). Review before proceeding.
<!-- MULTI_CLI_UNRESOLVED_CRITICAL series:1-1 block:code-review nonblock:test-analysis nonblock:comment-analysis -->
REPORT_BODY
run_sequence_step "$MULTI_AGENT" code-review "$TMP/malformed-state.log"
if [[ "$SEQUENCE_RC" -ne 0 ]] \
  && grep -qF 'cannot inspect unresolved Critical perspectives' "$TMP/malformed-state.log"; then
  ok "nonblock 区切りが重複する破損状態を fail closed で拒否する"
else
  bad "破損した機械状態から観点が黙って脱落した"
fi

cat > "$REPORT" <<'REPORT_BODY'
<!-- CRITICAL_BLOCK -->
Critical issues detected (code-review). Review before proceeding.
<!-- MULTI_CLI_UNRESOLVED_CRITICAL series:1-1 block: nonblock:- -->
REPORT_BODY
run_sequence_step "$MULTI_AGENT" code-review "$TMP/empty-state-field.log"
if [[ "$SEQUENCE_RC" -ne 0 ]] \
  && grep -qF 'cannot inspect unresolved Critical perspectives' "$TMP/empty-state-field.log"; then
  ok "空の block フィールドを未解消なしとして受理しない"
else
  bad "空の機械状態フィールドを正常状態として受理した"
fi

cat > "$REPORT" <<'REPORT_BODY'
<!-- CRITICAL_BLOCK -->
Critical issues detected (code-review). Review before proceeding.
<!-- MULTI_CLI_UNRESOLVED_CRITICAL series:1-1 block:- nonblock:- -->
REPORT_BODY
run_sequence_step "$MULTI_AGENT" code-review "$TMP/inconsistent-empty-state.log"
if [[ "$SEQUENCE_RC" -ne 0 ]] \
  && grep -qF 'Critical marker but its machine state is empty' "$TMP/inconsistent-empty-state.log"; then
  ok "Critical マーカーと空の機械状態の矛盾を fail closed で拒否する"
else
  bad "Critical マーカーと空状態の矛盾を見逃した"
fi

cat > "$REPORT" <<'REPORT_BODY'
<!-- CRITICAL_BLOCK -->
Critical issues detected (code-review). Review before proceeding.
<!-- MULTI_CLI_UNRESOLVED_CRITICAL series:1-1 block:code-review nonblock:- -->
REPORT_BODY
for trailing_index in 1 2 3 4 5 6 7 8 9 10 11 12 13; do
  printf 'trailing diagnostic %s\n' "$trailing_index" >> "$REPORT"
done
run_sequence_step "$MULTI_AGENT" code-review "$TMP/machine-state-not-final.log"
if [[ "$SEQUENCE_RC" -ne 0 ]] \
  && grep -qF 'cannot inspect unresolved Critical perspectives' "$TMP/machine-state-not-final.log"; then
  ok "最終行でない機械状態を旧形式として復元しない"
else
  bad "位置が壊れた機械状態から series が黙って脱落した"
fi

# アップグレード直後の旧形式レポートは末尾の既存要約から復元する。
cat > "$REPORT" <<'REPORT_BODY'
# Legacy integrated report
<!-- CRITICAL_BLOCK -->
Critical issues detected (code-review). Review before proceeding.
REPORT_BODY
run_sequence_step "$MULTI_AGENT" comment-analysis "$TMP/legacy-state.log"
if [[ "$SEQUENCE_RC" -ne 0 ]] \
  && grep -qF 'omits unresolved Critical perspective(s): code-review' "$TMP/legacy-state.log"; then
  ok "旧形式レポートの観点一覧も部分再検証ガードへ引き継ぐ"
else
  bad "旧形式レポートの未解消観点を復元できない"
fi

echo "== 残存レポートによる中断は 11 分岐すべてで復帰手段を案内する =="

# 中断そのものは fail-closed の設計で、変えるのは案内だけ。abort した人が読むのは
# stderr の数行なので、復帰手段がそこに無い分岐は「次に何をすればよいか」を --help
# から再発見させる。1 分岐だけ欠けていた実績（→ 6 分岐が欠けていた実測）があるため、
# 同関数の abort 11 分岐すべてを実際に発火させ、分岐固有の ERROR 文言と復帰案内を
# 対で固定する。
#
# 復帰手段は分岐ごとに違う。一律 `--fresh` は「誰も読んでいない Critical 状態を
# 退避しろ」と言うのと同じなので、次の 3 種を分けて固定する:
#   1. 残骸を読める          → `add --fresh`（機械状態が信用できない分岐は「先に
#                              本文を読め」を前置き）
#   2. レポートを読めない    → 可読性を先に直す。`add --fresh` は出さない
#   3. 現在の系列を作れない  → 直すのはリポジトリ側。`add --fresh` は出さない
#
# 分類 2 は**実運用で起きる唯一の読み取り故障**（レポートが chmod 000 / I/O
# エラー）を含む。そこは機械状態の抽出そのものが落ちる経路で、分類 1 と同じ
# 入口を通る。rc で分けていないと実在する故障が全部「add --fresh」に落ちるので、
# 入口の 2 分岐（抽出が読めない / 抽出は読めたが解釈できない）を別ケースで固定する。
assert_recovery_hint() { # $1: log / $2: 分岐を名指しする ERROR 文言 / $3: 期待する復帰案内 / $4: ラベル
  if [[ "$SEQUENCE_RC" -ne 0 ]] \
    && grep -qF "$2" "$1" \
    && grep -qF -- "$3" "$1"; then
    ok "$4"
  else
    bad "$4 (rc=$SEQUENCE_RC)"
    sed -n '1,20p' "$1" >&2 || true
  fi
}

# 「一律で --fresh を貼らない」は不在でしか固定できない。`add --fresh` という
# **提示形だけ**を禁じると、`retry with --fresh` のような別表記へ書き換えられた
# ときに黙って通る。`--fresh` の出現そのものを見て、既知の打ち消し文（下の
# FRESH_RULED_OUT_*）だけを明示的に除外する。
FRESH_RULED_OUT_UNREADABLE='--fresh would discard a Critical state nobody has read'
FRESH_RULED_OUT_NO_SERIES='--fresh does not help here: the failure is in the current repository state, not in the leftover report.'
assert_no_fresh_offer() { # $1: log / $2: ラベル
  local stray
  stray="$(grep -F -- '--fresh' "$1" \
    | grep -vF -- "$FRESH_RULED_OUT_UNREADABLE" \
    | grep -vF -- "$FRESH_RULED_OUT_NO_SERIES" || true)"
  if [[ -n "$stray" ]]; then
    bad "$2"
    printf '    | %s\n' "$stray" >&2
  else
    ok "$2"
  fi
}

# `--fresh` を出さない分岐は、出さない**理由**も案内する。理由行が消えても
# 「提示していない」は成立したままなので、不在の検査だけでは落ちない。
assert_fresh_ruled_out() { # $1: log / $2: 期待する打ち消し文 / $3: ラベル
  if grep -qF -- "$2" "$1"; then
    ok "$3"
  else
    bad "$3"
    sed -n '1,20p' "$1" >&2 || true
  fi
}

# 分岐 1: 機械状態そのものを読めない（awk が構文破損で非 0）。レポート本文は
# 読めているので、`--fresh` の前に Critical セクションの手読みを案内する。
cat > "$REPORT" <<'REPORT_BODY'
<!-- CRITICAL_BLOCK -->
Critical issues detected (code-review). Review before proceeding.
<!-- MULTI_CLI_UNRESOLVED_CRITICAL series:1-1 block: nonblock:- -->
REPORT_BODY
run_sequence_step "$MULTI_AGENT" code-review "$TMP/recovery-parse-failure.log"
assert_recovery_hint "$TMP/recovery-parse-failure.log" \
  'cannot inspect unresolved Critical perspectives' \
  'Read the Critical section of the report by hand first, then archive leftover results and retry: add --fresh' \
  "機械状態を読めない中断も復帰手段を案内する"

# 分岐 2: Critical マーカーはあるが観点一覧を復元できない（機械状態行も旧形式の
# 要約行も無い残骸）。
cat > "$REPORT" <<'REPORT_BODY'
# Legacy integrated report
<!-- CRITICAL_BLOCK -->
Critical issues were found, but this line is not a machine readable summary.
REPORT_BODY
run_sequence_step "$MULTI_AGENT" code-review "$TMP/recovery-unreadable-list.log"
assert_recovery_hint "$TMP/recovery-unreadable-list.log" \
  'Critical marker without a readable perspective list' \
  'Inspect the leftover report, then add --fresh' \
  "観点一覧を復元できない中断も復帰手段を案内する"

# 分岐 3: 残骸が別ブランチ / base / scope の系列（series が現在の識別子と一致しない）。
cat > "$REPORT" <<'REPORT_BODY'
<!-- CRITICAL_BLOCK -->
Critical issues detected (code-review). Review before proceeding.
<!-- MULTI_CLI_UNRESOLVED_CRITICAL series:1-1 block:code-review nonblock:- -->
REPORT_BODY
run_sequence_step "$MULTI_AGENT" code-review "$TMP/recovery-other-series.log"
assert_recovery_hint "$TMP/recovery-other-series.log" \
  'belongs to another branch/base/scope' \
  'Or archive leftover results and retry: add --fresh' \
  "別系列の残骸による中断も復帰手段を案内する"

# 分岐 4: 同一系列で、絞り込みが未解消観点を落とす。
rm -rf "$REPO/.review-results"
cat > "$TMP/body.md" <<'BODY'
<!-- sentinel-recovery-unresolved -->
## Code Review Results
### Critical Issues
- [app.txt:2] 認可チェックの欠落
### Summary
- Critical: 1
BODY
run_sequence_step "$MULTI_AGENT" code-review "$TMP/recovery-omitted-initial.log"
if [[ "$SEQUENCE_RC" -eq 0 && -f "$REPORT" ]] && grep -qF "$MARKER" "$REPORT"; then
  ok "同一系列の未解消レポートを用意できる"
else
  bad "同一系列の未解消レポートを作れない (rc=$SEQUENCE_RC)"
fi
run_sequence_step "$MULTI_AGENT" comment-analysis "$TMP/recovery-omitted.log"
assert_recovery_hint "$TMP/recovery-omitted.log" \
  'omits unresolved Critical perspective(s): code-review' \
  'Or archive leftover results and retry: add --fresh' \
  "未解消観点を落とす絞り込みの中断も復帰手段を案内する"

# 分岐 5: 機械状態の series フィールドが系列 ID の形をしていない。
cat > "$REPORT" <<'REPORT_BODY'
<!-- CRITICAL_BLOCK -->
Critical issues detected (code-review). Review before proceeding.
<!-- MULTI_CLI_UNRESOLVED_CRITICAL series:bogus block:code-review nonblock:- -->
REPORT_BODY
run_sequence_step "$MULTI_AGENT" code-review "$TMP/recovery-invalid-series.log"
assert_recovery_hint "$TMP/recovery-invalid-series.log" \
  'invalid review-series entry in previous Critical state' \
  'Read the Critical section of the report by hand first, then archive leftover results and retry: add --fresh' \
  "不正な series エントリの中断も復帰手段を案内する"

# 分岐 6: 機械状態の観点エントリが安全なトークンでない。
cat > "$REPORT" <<'REPORT_BODY'
<!-- CRITICAL_BLOCK -->
Critical issues detected (code-review). Review before proceeding.
<!-- MULTI_CLI_UNRESOLVED_CRITICAL series:1-1 block:code@review nonblock:- -->
REPORT_BODY
run_sequence_step "$MULTI_AGENT" code-review "$TMP/recovery-invalid-perspective.log"
assert_recovery_hint "$TMP/recovery-invalid-perspective.log" \
  'invalid perspective entry in previous Critical state' \
  'Read the Critical section of the report by hand first, then archive leftover results and retry: add --fresh' \
  "不正な観点エントリの中断も復帰手段を案内する"

# 分岐 7: Critical マーカーと空の機械状態が矛盾する。
cat > "$REPORT" <<'REPORT_BODY'
<!-- CRITICAL_BLOCK -->
Critical issues detected (code-review). Review before proceeding.
<!-- MULTI_CLI_UNRESOLVED_CRITICAL series:1-1 block:- nonblock:- -->
REPORT_BODY
run_sequence_step "$MULTI_AGENT" code-review "$TMP/recovery-empty-state.log"
assert_recovery_hint "$TMP/recovery-empty-state.log" \
  'Critical marker but its machine state is empty' \
  'Inspect the Critical section of the leftover report, then add --fresh' \
  "マーカーと空状態の矛盾による中断も復帰手段を案内する"

# 分岐 8: レポートファイルそのものを読めない（**実運用で起きる形**）。権限を
# 落としただけの残骸は機械状態の抽出そのものが落ちるので、分岐 1（機械状態を
# 解釈できない）と同じ入口に来る。ここが `add --fresh` を出すと、誰も読んでいない
# Critical 状態の退避を案内することになる。
#
# chmod が効かない環境（root 実行など）では同じ故障をセンチネルで注入して、
# 検査を空振りさせない。
cat > "$REPORT" <<'REPORT_BODY'
<!-- CRITICAL_BLOCK -->
Critical issues detected (code-review). Review before proceeding.
<!-- MULTI_CLI_UNRESOLVED_CRITICAL series:1-1 block:code-review nonblock:- -->
REPORT_BODY
chmod 000 "$REPORT"
if cat "$REPORT" >/dev/null 2>&1; then
  chmod 644 "$REPORT"
  rm -f "$TMP/tail-calls"
  printf '1\n' > "$TMP/tail-fail-nth"
fi
run_sequence_step "$MULTI_AGENT" code-review "$TMP/recovery-unreadable-extract.log"
chmod 644 "$REPORT" 2>/dev/null || true
rm -f "$TMP/tail-fail-nth" "$TMP/tail-calls"
assert_recovery_hint "$TMP/recovery-unreadable-extract.log" \
  'cannot inspect unresolved Critical perspectives' \
  'The report file could not be read; check its permissions and the filesystem, then retry.' \
  "読めないレポート（権限）の中断も復帰手段を案内する"
assert_no_fresh_offer "$TMP/recovery-unreadable-extract.log" \
  "読めないレポート（権限）には --fresh を提示しない"
assert_fresh_ruled_out "$TMP/recovery-unreadable-extract.log" \
  "$FRESH_RULED_OUT_UNREADABLE" \
  "読めないレポート（権限）は --fresh を出さない理由も案内する"

# 分岐 9 / 10: レポートファイルを読めないが、抽出だけは終わっている（マーカー
# 検査で落ちる）。レポート本文では作れない故障なので tail を 2 回目以降で
# 失敗させて注入する。1 回目（機械状態の抽出）は成功するため、上の分岐 8 ではなく
# マーカー検査の 2 分岐に落ちる。
#
# この 2 分岐は同じ文面を別の呼び出し元から出す。ERROR 行の括弧で経路を名指し
# させ、ケースごとにその語を見る（同じ文字列しか見ないと、両 fixture が片方の
# 分岐へ寄っても緑のまま片側の被覆が消える）。
printf '2\n' > "$TMP/tail-fail-nth"

rm -f "$TMP/tail-calls"
cat > "$REPORT" <<'REPORT_BODY'
# Legacy integrated report
<!-- CRITICAL_BLOCK -->
Critical issues were found, but this line is not a machine readable summary.
REPORT_BODY
run_sequence_step "$MULTI_AGENT" code-review "$TMP/recovery-unreadable-report.log"
assert_recovery_hint "$TMP/recovery-unreadable-report.log" \
  'cannot inspect Critical markers in the previous report (no machine-readable Critical state).' \
  'The report file could not be read; check its permissions and the filesystem, then retry.' \
  "レポートを読めない中断も復帰手段を案内する（観点一覧の復元経路）"
assert_no_fresh_offer "$TMP/recovery-unreadable-report.log" \
  "読めないレポートには --fresh を提示しない（観点一覧の復元経路）"
assert_fresh_ruled_out "$TMP/recovery-unreadable-report.log" \
  "$FRESH_RULED_OUT_UNREADABLE" \
  "読めないレポートは --fresh を出さない理由も案内する（観点一覧の復元経路）"

rm -f "$TMP/tail-calls"
cat > "$REPORT" <<'REPORT_BODY'
<!-- CRITICAL_BLOCK -->
Critical issues detected (code-review). Review before proceeding.
<!-- MULTI_CLI_UNRESOLVED_CRITICAL series:1-1 block:- nonblock:- -->
REPORT_BODY
run_sequence_step "$MULTI_AGENT" code-review "$TMP/recovery-unreadable-report-empty.log"
assert_recovery_hint "$TMP/recovery-unreadable-report-empty.log" \
  'cannot inspect Critical markers in the previous report (Critical state lists no unresolved perspectives).' \
  'The report file could not be read; check its permissions and the filesystem, then retry.' \
  "レポートを読めない中断も復帰手段を案内する（空状態の経路）"
assert_no_fresh_offer "$TMP/recovery-unreadable-report-empty.log" \
  "読めないレポートには --fresh を提示しない（空状態の経路）"
assert_fresh_ruled_out "$TMP/recovery-unreadable-report-empty.log" \
  "$FRESH_RULED_OUT_UNREADABLE" \
  "読めないレポートは --fresh を出さない理由も案内する（空状態の経路）"

rm -f "$TMP/tail-fail-nth" "$TMP/tail-calls"

# 「レポートを読めない」と断定してよいのは tail が落ちたときだけ。マーカー検査の
# grep 自体が失敗しても（grep のエラー rc=2 / PATH 上の grep 不在 rc=127）、戻り値
# を素通しすると同じ「The report file could not be read」に化ける。壊れている
# ツールチェーンを可読性の問題として名指しするのは誤診断なので、grep の失敗が
# その断定を出さないことを固定する。
# stub は 1 ケース分だけ置く（全 grep を wrapper 経由にする負荷を持ち回らない）。
REAL_GREP="$(command -v grep)"
cat > "$STUB/grep" <<SH
#!/usr/bin/env bash
# previous_report_has_critical_marker() の Critical マーカー検査だけを
# grep 自身のエラー（rc=2）にする。それ以外の grep は素通し。
if [[ "\$*" == "-Fx -e <!-- CRITICAL_BLOCK --> -e <!-- CRITICAL_NONBLOCK -->" ]]; then
  printf 'x\n' >> "$TMP/grep-marker-calls"
  exit 2
fi
exec "$REAL_GREP" "\$@"
SH
chmod +x "$STUB/grep"
rm -f "$TMP/grep-marker-calls"
cat > "$REPORT" <<'REPORT_BODY'
<!-- CRITICAL_BLOCK -->
Critical issues detected (code-review). Review before proceeding.
<!-- MULTI_CLI_UNRESOLVED_CRITICAL series:1-1 block:- nonblock:- -->
REPORT_BODY
run_sequence_step "$MULTI_AGENT" code-review "$TMP/recovery-grep-error.log"
rm -f "$STUB/grep"
if [[ -s "$TMP/grep-marker-calls" ]]; then
  ok "マーカー検査の grep 失敗を実際に注入できている"
else
  bad "マーカー検査の grep 失敗が注入できていない（次の検査は空振り）"
fi
if grep -qF 'The report file could not be read' "$TMP/recovery-grep-error.log"; then
  bad "grep の失敗を「レポートを読めない」と誤って断定する"
  sed -n '1,20p' "$TMP/recovery-grep-error.log" >&2 || true
else
  ok "grep の失敗を「レポートを読めない」と断定しない"
fi

# 分岐 11: 現在のレビュー系列を特定できない（残骸ではなくリポジトリ側の故障）。
: > "$TMP/git-symbolic-ref-fail"
cat > "$REPORT" <<'REPORT_BODY'
<!-- CRITICAL_BLOCK -->
Critical issues detected (code-review). Review before proceeding.
<!-- MULTI_CLI_UNRESOLVED_CRITICAL series:1-1 block:code-review nonblock:- -->
REPORT_BODY
run_sequence_step "$MULTI_AGENT" code-review "$TMP/recovery-no-series.log"
rm -f "$TMP/git-symbolic-ref-fail"
# 案内が挙げる原因は実測したものだけ。コミット 0 件のリポジトリは原因にならない
# ——`git symbolic-ref --quiet HEAD` は unborn branch を rc=0 で返す（実測）。
#
# 「worktree の外」と「`.git/HEAD` の破損」は**同じ注入**（symbolic-ref rc=128）で、git から
# 区別できない。以前は専用センチネルを分けて 2 本走らせていたが、実体は同じ分岐の再走
# だったので 1 本に畳み、両方の名乗りと両方の直し方をこの実走で固定する。
assert_recovery_hint "$TMP/recovery-no-series.log" \
  'cannot identify the current review series' \
  'this run is not inside a git worktree' \
  "系列を特定できない中断は、worktree の外側を名乗る"
assert_recovery_hint "$TMP/recovery-no-series.log" \
  'cannot identify the current review series' \
  'or the worktree'"'"'s .git/HEAD is corrupt' \
  "系列を特定できない中断は、区別できない 2 原因を両方名乗る"
assert_recovery_hint "$TMP/recovery-no-series.log" \
  'cannot identify the current review series' \
  'repair .git/HEAD' \
  "系列を特定できない中断は、HEAD 破損側の直し方も出す"
assert_no_fresh_offer "$TMP/recovery-no-series.log" \
  "系列を特定できない中断には --fresh を提示しない"
assert_fresh_ruled_out "$TMP/recovery-no-series.log" \
  "$FRESH_RULED_OUT_NO_SERIES" \
  "系列を特定できない中断は --fresh を出さない理由も案内する"

# 既定アーム（`*)`）は「理由を読めなかった回」の受け皿で、原因を名乗れない代わりに復帰
# 手段だけは残す層。ここを無検査にすると、原因別アームの検査が全部緑のまま既定アームだけ
# 消え、理由を読めない利用者に次の一手が一行も出なくなる（変異注入で緑を実測済み）。
#
# 理由ファイルのシームを**親ディレクトリが存在しないパス**へ向けて実走させる。記録の
# 書き込みが失敗し（→ 警告）、読み戻しも成立しない（→ 理由は空）ので、案内は既定アームへ
# 落ちる。権限（chmod）に依存しないので root 実行でも同じ形で発火する。
: > "$TMP/git-symbolic-ref-fail"
cat > "$REPORT" <<'REPORT_BODY'
<!-- CRITICAL_BLOCK -->
Critical issues detected (code-review). Review before proceeding.
<!-- MULTI_CLI_UNRESOLVED_CRITICAL series:1-1 block:code-review nonblock:- -->
REPORT_BODY
SEQUENCE_RC=0
set +e
run_isolated PATH="$STUB:$PATH" \
  FF_MULTI_AGENT_REVIEW_SERIES_REASON_FILE="$TMP/no-such-dir/reason" \
  bash "$MULTI_AGENT" --task review --cli codex-cli --perspective code-review \
  --base develop --timeout 60 >"$TMP/recovery-default-arm.log" 2>&1
SEQUENCE_RC=$?
set -e
rm -f "$TMP/git-symbolic-ref-fail"
assert_recovery_hint "$TMP/recovery-default-arm.log" \
  'cannot identify the current review series' \
  'with the project root still present and HEAD resolvable' \
  "理由を読めない回は既定アームの復帰手段を出す"
if grep -qF 'could not record the review-series failure reason' "$TMP/recovery-default-arm.log"; then
  ok "理由を記録できなかったことを黙らず警告する"
else
  bad "理由の記録失敗が痕跡なく握り潰されている"
  sed -n '1,20p' "$TMP/recovery-default-arm.log" >&2 || true
fi
if grep -qF 'git cannot read HEAD here' "$TMP/recovery-default-arm.log"; then
  bad "理由を読めていないのに原因を名乗っている（記録失敗が案内に反映されていない）"
  sed -n '1,20p' "$TMP/recovery-default-arm.log" >&2 || true
else
  ok "理由を読めない回は原因を名乗らない"
fi

# 理由ファイルのパスに他ユーザーのシンボリックリンクが置かれている回。素の `>` はリンクを
# 追って**リンク先を truncate** する（共有 sticky /tmp では pid からパスを推測できる）。
# アダプタ側の timeout-reason と**同じ関数**で排他生成するので、ここが緑でも向こうが赤なら
# 片方だけ直った状態が見える。リンクを掴まなかった回は理由を運べないので、案内は既定アーム
# へ落ちる（誤った原因を名乗るより無害）。
SERIES_REASON_SYMLINK="$TMP/series-reason-symlink"
printf 'unrelated payload\n' > "$TMP/series-reason-victim"
rm -f "$SERIES_REASON_SYMLINK"
printf '%s\n' "$SERIES_REASON_SYMLINK" > "$TMP/plant-reason-symlink"
: > "$TMP/git-symbolic-ref-fail"
cat > "$REPORT" <<'REPORT_BODY'
<!-- CRITICAL_BLOCK -->
Critical issues detected (code-review). Review before proceeding.
<!-- MULTI_CLI_UNRESOLVED_CRITICAL series:1-1 block:code-review nonblock:- -->
REPORT_BODY
set +e
run_isolated PATH="$STUB:$PATH" \
  FF_MULTI_AGENT_REVIEW_SERIES_REASON_FILE="$SERIES_REASON_SYMLINK" \
  bash "$MULTI_AGENT" --task review --cli codex-cli --perspective code-review \
  --base develop --timeout 60 >"$TMP/recovery-symlink.log" 2>&1
set -e
rm -f "$TMP/git-symbolic-ref-fail" "$TMP/plant-reason-symlink"
if [[ "$(cat "$TMP/series-reason-victim" 2>/dev/null)" == "unrelated payload" ]]; then
  ok "理由ファイルのシンボリックリンク先を truncate しない"
else
  bad "シンボリックリンクを追ってリンク先を truncate している"
  sed -n '1,20p' "$TMP/recovery-symlink.log" >&2 || true
fi
if grep -qF 'refusing to write the failure reason' "$TMP/recovery-symlink.log"; then
  ok "リンクを掴まなかったことを黙らず警告する"
else
  bad "リンク検知が痕跡なく握り潰されている"
  sed -n '1,20p' "$TMP/recovery-symlink.log" >&2 || true
fi
assert_recovery_hint "$TMP/recovery-symlink.log" \
  'cannot identify the current review series' \
  'with the project root still present and HEAD resolvable' \
  "リンクで理由を運べない回も既定アームの復帰手段を出す"
if grep -qF 'git cannot read HEAD here' "$TMP/recovery-symlink.log"; then
  bad "理由を運べていないのに原因を名乗っている"
  sed -n '1,20p' "$TMP/recovery-symlink.log" >&2 || true
else
  ok "リンクで理由を運べない回は原因を名乗らない"
fi
rm -f "$SERIES_REASON_SYMLINK" "$TMP/series-reason-victim"

# 系列 ID はガード側だけでなく**レポート生成側**でも要る。こちらの失敗経路は今まで実走が
# 1 件も無く、原因別アームを丸ごと消しても緑だった（変異注入で実測）。
#
# ガード側が系列 ID を引くのは「前回レポートに series マーカーが在るとき」だけなので、
# レポートを消した状態で走れば `symbolic-ref` の 1 回目がレポート生成側になる。遅延注入
# （N 回目以降を落とす）で、ガードを通過させたままレポート生成だけを落とす。
rm -f "$REPORT"
rm -f "$TMP/git-symbolic-ref-calls"
printf '1\n' > "$TMP/git-symbolic-ref-fail-after"
run_sequence_step "$MULTI_AGENT" code-review "$TMP/report-no-series.log"
rm -f "$TMP/git-symbolic-ref-fail-after" "$TMP/git-symbolic-ref-calls"
if grep -qF 'cannot identify the current review series for the report.' "$TMP/report-no-series.log"; then
  ok "レポート生成側の系列特定失敗を実走で発火できている"
else
  bad "レポート生成側の系列特定失敗を発火できていない（以降の検査は空振り）"
  sed -n '1,30p' "$TMP/report-no-series.log" >&2 || true
fi
if grep -qF 'git cannot read HEAD here' "$TMP/report-no-series.log"; then
  ok "レポート生成側の中断も原因を名指しする"
else
  bad "レポート生成側の中断が原因を名指ししない"
  sed -n '1,30p' "$TMP/report-no-series.log" >&2 || true
fi
if [[ -f "$REPORT" ]]; then
  bad "系列を書けなかったレポートが公開されている（未解消 Critical の機械状態を欠いた成果物）"
else
  ok "系列を書けなかったレポートは公開しない"
fi

# 前回の失敗理由を消す処理（current_review_series_id 冒頭）は、**現状のどの経路からも
# 観測できない** — 失敗する分岐はすべて理由を書いてから返るので、消さなくても直後に
# 上書きされる。将来「理由を書かずに返る分岐」が足されたときだけ効く保険で、その分岐が
# 無いうちは変異が緑になる（実測）。測れないことを記録して残す（黙って外すと、保険が
# 必要になった回に誰も気づかない）。
#
# 3 つ目の原因（プロジェクトルートが消えた・読めない）は、この経路へ**実走では到達
# できない**: REPO_ROOT は起動時に 1 度だけ解決され、解決できない値だと設定読み込みや
# diff 取得がこの分岐より先に落ちる（実測）。分岐の実在と文言だけを静的に固定する。
# 静的検査に落とすのは「測れないので諦める」ではなく、**測れる層と測れない層を分けて
# どちらも空白にしない**ため（測れない層を黙って落とすと、案内が消えても誰も気づかない）。
# 針は**中断分岐の案内に固有の文言**で持つ。「ルートが読めない」だけだと、レポート側の
# 短い診断行にも同じ語が出るので、中断分岐の案内を削っても緑のまま通る（実測）。
if grep -qF 'The project root is gone or unreadable: ${REPO_ROOT}. Restore it' "$MULTI_AGENT"; then
  ok "系列を特定できない中断にプロジェクトルート不在の案内がある（静的）"
else
  bad "プロジェクトルート不在の案内（中断分岐の復帰手段）が無い"
fi
if grep -qF 'record_review_series_failure repo-root' "$MULTI_AGENT"; then
  ok "プロジェクトルート不在が専用の理由として区別されている（静的）"
else
  bad "プロジェクトルート不在が理由として区別されていない"
fi

# 上の 2 つは「記録する側の文字列」と「案内の文字列」を**別々に**見ているだけなので、
# case のラベル（repo-root）だけを書き換えると両方の文字列が残ったまま緑で通り、実行時は
# 黙って `*)` の一般案内へ落ちる（セルフレビューのクロスモデル指摘）。実装から 3 つの
# 集合／件数を採って、片側だけの書き換え・削除を赤にする。
#
# 集合の比較だけでは足りない点が 2 つある:
#   - 消費側の case は 2 箇所（ガード側とレポート側）あり、**合併**して比べると片方の
#     ブロックを丸ごと消しても、もう片方からラベルが採れる限り一致し続ける（実測で緑）。
#     ブロックごとに比べる。
#   - 同じ理由を記録する地点が複数ある（git-error は 2 箇所）。集合比較では 1 箇所消えても
#     一致したままなので、**失敗して返る地点の数と記録する地点の数が一致すること**を別に
#     見る（理由を書かずに返る分岐が増えたら赤になる）。
#
# grep の非一致は rc=1 で、`set -euo pipefail` 配下では代入ごと落ちて下の空振り検出
# （bad）へ到達できない。抽出は必ず `|| true` を通してから空を検出する。
ALLOWED_REASONS="$({ awk '
  /^record_review_series_failure\(\)/            { inblk = 1; next }
  inblk && /^\}/                                 { inblk = 0; next }
  inblk && match($0, /^[[:space:]]*[a-z][a-z|-]*\)[[:space:]]*:[[:space:]]*;;/) {
    lbl = substr($0, RSTART, RLENGTH)
    sub(/^[[:space:]]*/, "", lbl)
    sub(/\).*$/, "", lbl)
    n = split(lbl, parts, "|")
    for (i = 1; i <= n; i++) print parts[i]
  }
' "$MULTI_AGENT" || true; } | LC_ALL=C sort -u)"
CALLED_REASONS="$({ grep -oE 'record_review_series_failure [a-z][a-z-]*;' "$MULTI_AGENT" || true; } \
  | sed 's/^record_review_series_failure //; s/;$//' | LC_ALL=C sort -u)"
CONSUMER_ROWS="$({ awk '
  /case "\$\(review_series_failure_reason\)" in/ { blk++; inblk = 1; next }
  inblk && /^[[:space:]]*esac/                      { inblk = 0; next }
  inblk && /^[[:space:]]*\*\)/                      { print blk "\t*"; next }
  inblk && match($0, /^[[:space:]]*[a-z][a-z-]*\)/) {
    lbl = substr($0, RSTART, RLENGTH)
    sub(/^[[:space:]]*/, "", lbl)
    sub(/\)$/, "", lbl)
    print blk "\t" lbl
  }
' "$MULTI_AGENT" || true; })"

if [[ -z "$ALLOWED_REASONS" || -z "$CALLED_REASONS" || -z "$CONSUMER_ROWS" ]]; then
  bad "失敗理由の許可値／記録地点／消費側ブロックのいずれかを抽出できない（対応検査が空振りしている）"
elif [[ "$ALLOWED_REASONS" != "$CALLED_REASONS" ]]; then
  bad "記録の入口検証が許す理由と、実際に記録している理由が食い違う（許可: $(printf '%s' "$ALLOWED_REASONS" | tr '\n' ' ')/ 記録: $(printf '%s' "$CALLED_REASONS" | tr '\n' ' '))"
else
  ok "記録の入口検証が許す理由と、実際に記録している理由が一致する"
fi

CONSUMER_BLOCKS="$(printf '%s\n' "$CONSUMER_ROWS" | awk -F'\t' 'NF { print $1 }' | LC_ALL=C sort -u)"
CONSUMER_BLOCK_COUNT="$(printf '%s\n' "$CONSUMER_BLOCKS" | awk 'NF { c++ } END { print c + 0 }')"
if [[ "$CONSUMER_BLOCK_COUNT" -lt 2 ]]; then
  bad "理由を消費する case ブロックが ${CONSUMER_BLOCK_COUNT} 箇所しかない（ガード側とレポート側の 2 箇所を期待）"
else
  _consumer_mismatch=""
  _consumer_no_default=""
  for _blk in $CONSUMER_BLOCKS; do
    _labels="$(printf '%s\n' "$CONSUMER_ROWS" | awk -F'\t' -v b="$_blk" '$1 == b && $2 != "*" { print $2 }' | LC_ALL=C sort -u)"
    [[ "$_labels" == "$ALLOWED_REASONS" ]] || _consumer_mismatch="${_consumer_mismatch}${_blk} "
    if ! printf '%s\n' "$CONSUMER_ROWS" | awk -F'\t' -v b="$_blk" '$1 == b && $2 == "*" { found = 1 } END { exit found ? 0 : 1 }'; then
      _consumer_no_default="${_consumer_no_default}${_blk} "
    fi
  done
  if [[ -n "$_consumer_mismatch" ]]; then
    bad "理由を消費する case ブロックのラベルが許可値と食い違う（ブロック: ${_consumer_mismatch%% }）"
  else
    ok "理由を消費する ${CONSUMER_BLOCK_COUNT} ブロックすべてが許可値と同じラベルを持つ"
  fi
  # 既定アームは「理由を読めなかった回」の受け皿。消費側のどちらかから消えると、その経路
  # だけ復帰手段がゼロになる（ガード側は実走で固定しているが、レポート側は静的にしか
  # 見られない — 変異注入で緑を実測したので、ここで塞ぐ）。
  if [[ -n "$_consumer_no_default" ]]; then
    bad "理由を消費する case ブロックに既定アームが無い（ブロック: ${_consumer_no_default%% }）"
  else
    ok "理由を消費する ${CONSUMER_BLOCK_COUNT} ブロックすべてが既定アームを持つ"
  fi
fi

SERIES_FN_BODY="$({ awk '
  /^current_review_series_id\(\)/ { inblk = 1 }
  inblk                            { print }
  inblk && /^\}/                   { inblk = 0 }
' "$MULTI_AGENT" || true; })"
SERIES_FAIL_RETURNS="$(printf '%s\n' "$SERIES_FN_BODY" | { grep -oE 'return 1' || true; } | awk 'END { print NR + 0 }')"
SERIES_RECORDS="$(printf '%s\n' "$SERIES_FN_BODY" | { grep -oE 'record_review_series_failure [a-z][a-z-]*;' || true; } | awk 'END { print NR + 0 }')"
if [[ "$SERIES_FAIL_RETURNS" -lt 1 ]]; then
  bad "current_review_series_id の失敗経路を抽出できない（件数検査が空振りしている）"
elif [[ "$SERIES_FAIL_RETURNS" -eq "$SERIES_RECORDS" ]]; then
  ok "current_review_series_id は失敗して返る ${SERIES_FAIL_RETURNS} 箇所すべてで理由を記録する"
else
  bad "理由を記録せずに失敗して返る分岐がある（失敗 return ${SERIES_FAIL_RETURNS} / 記録 ${SERIES_RECORDS}）"
fi

# Issue `#1666`: `/multi-review` の SKILL.md が「新ブランチ初回は --fresh」を
# **実行手順の位置**に書いていること。案 A（filtered でも自動開始へ広げる）は系列 ID が
# ダイジェストでブランチ名を持たないため実装できず、案 B（手順へ前提として書く）を採った。
# 針を文書全体ではなく**手順 1 の節の中**へ限定するのは、引数一覧（`--fresh` の説明行）
# にも同じ語が在り、節から落としても文書全体の grep では緑のまま通るため。
REVIEW_SKILL="$PLUGIN_ROOT/skills/multi-review/SKILL.md"
if [ ! -f "$REVIEW_SKILL" ]; then
  bad "multi-review の SKILL.md が見つからない: $REVIEW_SKILL"
else
  STEP1_SECTION="$(awk '/^### 1\. プラン確認/{f=1} f{print} /^### 2\. レビュー実行/{if(f)exit}' "$REVIEW_SKILL")"
  for _needle in '新しいブランチでの初回レビューは `--fresh` を付けます' \
    '本スキルの標準起動では構造的に発火しません' \
    '同じブランチの 2 回目以降に `--fresh` を付けてはいけません' \
    'すでにマージ済みでも変わりません'; do
    if grep -qF -- "$_needle" <<<"$STEP1_SECTION"; then
      ok "SKILL.md 手順 1 が新ブランチ初回の前提を書いている: ${_needle}"
    else
      bad "SKILL.md 手順 1 に記述が無い（引数一覧だけに在っても不可）: ${_needle}"
    fi
  done
fi

# 運用文書側にも同じ前提の針を張る。SKILL.md 手順 1 だけを固定すると、運用文書の
# 追記（「手動退避は不要」が成立するのはフルレビューだけ）を消しても緑で通り、
# 標準起動形の読者は旧い案内に戻る（クロスモデルレビューが指摘。2026-09-17）。
# 針は当該段落に限定する — 文書全体だと別節の `--fresh` 言及で緑になる。
ORCH_REVIEW_DOC="$PLUGIN_ROOT/docs-template/05-operations/deployment/multi-cli-review-orchestration.md"
if [ ! -f "$ORCH_REVIEW_DOC" ]; then
  bad "レビュー運用文書が見つからない: $ORCH_REVIEW_DOC"
else
  FRESH_SECTION="$(awk '/^# フルレビューとして新しい系列を開始する/{f=1} f{print} /^### 結果の不整合/{if(f)exit}' "$ORCH_REVIEW_DOC")"
  for _needle in '「手動退避は不要」が成立するのはフルレビューだけである' \
    '新ブランチの初回は最初から `--fresh` を付ける' \
    'すでにマージ済みでも変わらない'; do
    if grep -qF -- "$_needle" <<<"$FRESH_SECTION"; then
      ok "レビュー運用文書が新ブランチ初回の前提を書いている: ${_needle}"
    else
      bad "レビュー運用文書の該当段落に記述が無い: ${_needle}"
    fi
  done
fi

# 文書側が 3 分類に追随していること。コード側は分岐ごとに --fresh の可否が変わるので、
# 文書が 2 分岐のままだと「--fresh は一律の復帰手段」と読める。
ORCH_DOC="$PLUGIN_ROOT/docs-template/05-operations/deployment/multi-cli-review-orchestration.md"
if [ ! -f "$ORCH_DOC" ]; then
  bad "説明文書が見つからない: $ORCH_DOC"
else
  # 分類名を文書全体から探すと、同じ語を含む散文（再検証の節）にも一致するので、3 分類表が
  # 丸ごと消えても緑で通りうる。針は**表の行そのもの**（`| **<分類名>**`）に限定する。
  # 一律禁止文だけは表の外の地の文なので文書全体から探す。
  for _needle in '| **残骸は読める**' '| **ファイルを読めない**' '| **系列を作れない**' \
    '`--fresh` を一律の復帰手段として使わないこと'; do
    if grep -qF -- "$_needle" "$ORCH_DOC"; then
      ok "説明文書が 3 分類へ追随している: ${_needle}"
    else
      bad "説明文書に 3 分類の記述が無い: ${_needle}"
    fi
  done
  # 3 分類表とは別に、再検証の節（本文側）にも「分類によって --fresh の可否が変わる」記述が
  # ある。表の側の針だけだと、本文を実装と矛盾する旧記述へ書き戻しても緑で通る。
  for _prose in 'ファイルを読めない分類と系列を作れない分類では `--fresh` を提示しない' \
    '案内は両方を名乗って両方の直し方を出す'; do
    if grep -qF -- "$_prose" "$ORCH_DOC"; then
      ok "再検証の節が分類ごとの復帰手段に追随している"
    else
      bad "再検証の節が分類ごとの復帰手段に追随していない: ${_prose}"
    fi
  done
  # 語句が在るだけでは足りない。**どの分類で --fresh が使えるか**の対応まで固定する
  # （3 分類の名前と一律禁止文を残したまま、行の復帰手段を --fresh 推奨へ書き換えられる）。
  for _row in 'ファイルを読めない' '系列を作れない'; do
    # 無マッチの grep は rc=1。`set -euo pipefail` 配下では代入ごと落ちて、直下の
    # 「行が無い」bad へ到達できない（表の行を消す変異が無名の中断に化ける）。
    _line="$({ grep -F -- "| **${_row}**" "$ORCH_DOC" || true; } | head -n 1)"
    if [ -z "$_line" ]; then
      bad "3 分類表に「${_row}」の行が無い"
    elif [[ "$_line" == *'**`--fresh` を使わない**'* ]]; then
      ok "3 分類表の「${_row}」行が --fresh を使わないと書いている"
    else
      bad "3 分類表の「${_row}」行が --fresh を使わないと書いていない（実装と食い違う）"
    fi
  done
  # 表の「系列を作れない」行は、実装と同じ原因の名乗り方（ルート不在は名指し／残り 2 つは
  # 区別できないので併記）まで書いていること。行の存在だけだと、原因の説明が実装と
  # 食い違う旧記述へ戻っても緑で通る。
  _no_series_line="$({ grep -F -- '| **系列を作れない**' "$ORCH_DOC" || true; } | head -n 1)"
  if [[ "$_no_series_line" == *'区別できない'* ]]; then
    ok "3 分類表の「系列を作れない」行が、区別できない 2 原因の扱いを書いている"
  else
    bad "3 分類表の「系列を作れない」行が原因の名乗り方を実装と同じに書いていない"
  fi
  _leftover_line="$({ grep -F -- '| **残骸は読める**' "$ORCH_DOC" || true; } | head -n 1)"
  if [[ "$_leftover_line" == *'`--fresh`'* ]]; then
    ok "3 分類表の「残骸は読める」行だけが --fresh を復帰手段として挙げている"
  else
    bad "3 分類表の「残骸は読める」行に --fresh の案内が無い"
  fi
fi

echo "== Issue #1025: 別系列の残存結果と --fresh =="

# 退避先は出力ディレクトリの内側（<dir>/.prev-<ts>/）なので、この 1 行で残骸も消える。
rm -rf "$REPO/.review-results"

cat > "$TMP/body.md" <<'BODY'
<!-- sentinel-1025-initial -->
## Code Review Results
### Critical Issues
- [app.txt:2] leftover critical from previous PR
### Summary
- Critical: 1
BODY
run_sequence_step "$MULTI_AGENT" code-review "$TMP/issue-1025-initial.log"
if [[ "$SEQUENCE_RC" -eq 0 && -f "$REPORT" ]] \
  && grep -qF "$MARKER" "$REPORT"; then
  ok "#1025 前回 PR 相当の未解消レポートを用意できる"
else
  bad "#1025 初期未解消レポートを作れない (rc=$SEQUENCE_RC)"
fi
cp "$REPORT" "$TMP/issue-1025-report-before.md"

git switch -q -c issue-1025-other-series

run_sequence_step "$MULTI_AGENT" comment-analysis "$TMP/issue-1025-narrowed.log"
if [[ "$SEQUENCE_RC" -ne 0 ]] \
  && grep -qF 'belongs to another branch/base/scope' "$TMP/issue-1025-narrowed.log" \
  && grep -qF -- '--fresh' "$TMP/issue-1025-narrowed.log" \
  && grep -qF 'bash scripts/codex-review.sh --base' "$TMP/issue-1025-narrowed.log" \
  && cmp -s "$TMP/issue-1025-report-before.md" "$REPORT"; then
  ok "別系列の絞り込みは非 0 で止まり --fresh とフルレビューコマンドを案内する"
else
  bad "別系列の絞り込み案内が不足 (rc=$SEQUENCE_RC)"
  sed -n '1,40p' "$TMP/issue-1025-narrowed.log" >&2 || true
fi

EXCLUDE_RC=0
set +e
run_isolated PATH="$STUB:$PATH" bash "$MULTI_AGENT" \
  --task review --cli codex-cli --exclude-perspective code-review \
  --base develop --timeout 60 \
  >"$TMP/issue-1025-exclude.log" 2>&1
EXCLUDE_RC=$?
set -e
if [[ "$EXCLUDE_RC" -ne 0 ]] \
  && grep -qF 'belongs to another branch/base/scope' "$TMP/issue-1025-exclude.log" \
  && cmp -s "$TMP/issue-1025-report-before.md" "$REPORT"; then
  ok "別系列の --exclude-perspective も新系列を開始せず前回レポートを保持する"
else
  bad "別系列の --exclude-perspective が新系列として通った (rc=$EXCLUDE_RC)"
  sed -n '1,40p' "$TMP/issue-1025-exclude.log" >&2 || true
fi

FRESH_RESUME_RC=0
set +e
run_isolated PATH="$STUB:$PATH" bash "$MULTI_AGENT" \
  --task review --cli codex-cli --perspective comment-analysis \
  --base develop --timeout 60 --fresh --resume \
  >"$TMP/issue-1025-fresh-resume.log" 2>&1
FRESH_RESUME_RC=$?
set -e
fresh_resume_archive=""
for cand in "$REPO"/.review-results/.prev-*; do
  [[ -d "$cand" ]] || continue
  fresh_resume_archive="$cand"
  break
done
if [[ "$FRESH_RESUME_RC" -eq 2 ]] \
  && grep -qF -- '--fresh cannot be combined with --resume' "$TMP/issue-1025-fresh-resume.log" \
  && cmp -s "$TMP/issue-1025-report-before.md" "$REPORT" \
  && [[ -z "$fresh_resume_archive" ]]; then
  ok "--fresh と --resume の併用を rc=2 で拒否し成果物を触らない"
else
  bad "--fresh --resume の拒否が成立しない (rc=$FRESH_RESUME_RC archive=${fresh_resume_archive:-none})"
  sed -n '1,40p' "$TMP/issue-1025-fresh-resume.log" >&2 || true
fi

cat > "$TMP/body.md" <<'BODY'
<!-- sentinel-1025-full-new-series -->
## Review Results
### Critical Issues
- なし
### Summary
- Critical: 0
BODY
FULL_RC=0
set +e
run_isolated PATH="$STUB:$PATH" bash "$MULTI_AGENT" \
  --task review --cli codex-cli --base develop --timeout 60 \
  >"$TMP/issue-1025-full.log" 2>&1
FULL_RC=$?
set -e
if [[ "$FULL_RC" -eq 0 ]] \
  && grep -qF 'this unfiltered full review starts a new series' "$TMP/issue-1025-full.log" \
  && [[ -f "$REPORT" ]] \
  && grep -qF 'sentinel-1025-full-new-series' "$REPORT" \
  && ! grep -qF 'sentinel-1025-initial' "$REPORT"; then
  ok "別系列でも --cli だけのフルレビューは手動退避なしで新系列を開始する"
else
  bad "--cli フルレビューが新系列を開始できない (rc=$FULL_RC)"
  sed -n '1,80p' "$TMP/issue-1025-full.log" >&2 || true
fi

git switch -q feature/x
rm -rf "$REPO/.review-results"
# 消費側の規約どおり「ライブ出力ディレクトリだけ」を ignore した状態を作る。
# 退避先が兄弟（`.review-results.prev-*`）だとこのパターンに一致せず、
# untracked のまま追跡候補として現れ、コミットへ巻き込まれる
# （https://github.com/feel-flow/ff-dev-toolkit/issues/96 ）。
printf '.review-results/\n' > "$REPO/.gitignore"
git add .gitignore
git commit -qm "ignore live review output dir only"
cat > "$TMP/body.md" <<'BODY'
<!-- sentinel-1025-fresh-initial -->
## Code Review Results
### Critical Issues
- [app.txt:2] leftover for --fresh
### Summary
- Critical: 1
BODY
run_sequence_step "$MULTI_AGENT" code-review "$TMP/issue-1025-fresh-initial.log"
if [[ "$SEQUENCE_RC" -eq 0 && -f "$REPORT" ]] \
  && grep -qF "$MARKER" "$REPORT"; then
  ok "#1025 --fresh 用の未解消レポートを用意できる"
else
  bad "#1025 --fresh 用の未解消レポートを作れない (rc=$SEQUENCE_RC)"
fi
git switch -q -c issue-1025-fresh-series

cat > "$TMP/body.md" <<'BODY'
<!-- sentinel-1025-fresh-run -->
## Comment Analysis Results
### Critical Issues
- なし
### Summary
- Critical: 0
BODY
FRESH_RC=0
rm -f "$TMP/stub-lock-probe"
: > "$TMP/stub-probe-lock"
set +e
run_isolated PATH="$STUB:$PATH" bash "$MULTI_AGENT" \
  --task review --cli codex-cli --perspective comment-analysis \
  --base develop --timeout 60 --fresh \
  >"$TMP/issue-1025-fresh.log" 2>&1
FRESH_RC=$?
set -e
rm -f "$TMP/stub-probe-lock"

archive_dir=""
for cand in "$REPO"/.review-results/.prev-*; do
  [[ -d "$cand" ]] || continue
  archive_dir="$cand"
  break
done
# 旧形式（兄弟）の退避先が作られていないことも同時に見る。ここを見ないと、
# 内側の退避先を追加しつつ兄弟も作る実装が両方の検査を通ってしまう。
sibling_archive=""
for cand in "$REPO"/.review-results.prev-*; do
  [[ -e "$cand" || -L "$cand" ]] || continue
  sibling_archive="$cand"
  break
done

if [[ "$FRESH_RC" -eq 0 ]] \
  && [[ -n "$archive_dir" ]] \
  && [[ -z "$sibling_archive" ]] \
  && grep -qF "archived" "$TMP/issue-1025-fresh.log" \
  && grep -qF -- '.review-results/.prev-' "$TMP/issue-1025-fresh.log" \
  && grep -qF 'sentinel-1025-fresh-initial' "${archive_dir}/integrated-report.md" \
  && [[ -f "${archive_dir}/codex-cli/code-review.md" ]] \
  && [[ ! -e "${archive_dir}/.multi-agent-run.lock" ]] \
  && [[ -f "$REPORT" ]] \
  && grep -qF 'sentinel-1025-fresh-run' "$REPORT" \
  && ! grep -qF 'sentinel-1025-fresh-initial' "$REPORT"; then
  ok "--fresh は前回結果を timestamp 付きへ退避して新しいレビューを生成する"
else
  bad "--fresh が前回結果を退避して再実行できない (rc=$FRESH_RC archive=${archive_dir:-none} sibling=${sibling_archive:-none})"
  sed -n '1,80p' "$TMP/issue-1025-fresh.log" >&2 || true
fi

# 退避先に lock が無いこと（上）だけでは「lock を退避もせず削除した」実装も通る。
# lock は実行終了時に解放されて消えるので、実行後には確かめられない。
# 退避の後に走る stub CLI から、ライブの `.multi-agent-run.lock` が OUTPUT_DIR
# 直下に居座ったままかを実測する（同時実行の相互排除が退避で外れないこと）。
fresh_lock_probe=""
[[ -f "$TMP/stub-lock-probe" ]] && fresh_lock_probe="$(cat "$TMP/stub-lock-probe")"
if [[ "$fresh_lock_probe" == "live-lock-present" ]]; then
  ok "--fresh の退避後もライブの lock は出力ディレクトリ直下に残る"
else
  bad "--fresh がライブの lock を動かしている (probe=${fresh_lock_probe:-none})"
fi

# ── 退避先が消費側の gitignore に載る / 集計に混ざらない ──
# （https://github.com/feel-flow/ff-dev-toolkit/issues/96 ）
#
# (a) `.review-results/` だけを ignore した消費側で、退避先も無視されること。
#     `git check-ignore` の rc（0=無視される）と `git status --porcelain` の
#     両方で見る。前者だけだと ignore ルールの一致は取れても、実際に追跡候補として
#     現れないことまでは言えない。
FRESH_IGNORE_RC=0
set +e
git -C "$REPO" check-ignore -q "${archive_dir#"$REPO/"}"
FRESH_IGNORE_RC=$?
set -e
git -C "$REPO" status --porcelain > "$TMP/issue-1400-fresh-status.txt"
fresh_status="$(cat "$TMP/issue-1400-fresh-status.txt")"
if [[ "$FRESH_IGNORE_RC" -eq 0 ]] \
  && ! grep -qF '.review-results' "$TMP/issue-1400-fresh-status.txt"; then
  ok "退避先は .review-results/ の ignore に載り、git status に現れない"
else
  bad "退避先が消費側の gitignore から漏れる (check-ignore rc=$FRESH_IGNORE_RC)"
  printf '%s\n' "$fresh_status" >&2 || true
fi

# 退避先は ignore 済み = 目に入らないまま溢れるので、退避完了行の直後に現在の
# 退避件数と掃除コマンドを 1 行出す。
if grep -qE 'archive\(s\) now under .*/\.prev-\*' "$TMP/issue-1025-fresh.log" \
  && grep -qF -- 'rm -rf' "$TMP/issue-1025-fresh.log"; then
  ok "--fresh は退避完了後に退避件数と掃除コマンドを出す"
else
  bad "--fresh の退避件数行が出ていない"
  grep -nF -- '.prev-' "$TMP/issue-1025-fresh.log" >&2 || true
fi

# (b) 退避した結果が今回の集計へ混ざらないこと。統合レポートの sentinel 検査
#     （上のケース）に加えて、退避先が「プラン外の残骸」としても名指しされない
#     ことまで見る。`.prev-*` を拾う走査が生えたら、Not part of this run 節か
#     本文のどちらかに `.prev-` が漏れる。
if ! grep -qF -- '.prev-' "$REPORT" \
  && ! grep -qF 'Not part of this run' "$REPORT" \
  && ! grep -qF -- '⚠️ Not part of this run' "$TMP/issue-1025-fresh.log"; then
  ok "退避した前回結果は今回の集計にも残骸の名指しにも現れない"
else
  bad "退避先が今回の走査に拾われている"
  grep -nF -- '.prev-' "$REPORT" >&2 || true
  grep -nF 'Not part of this run' "$REPORT" >&2 || true
fi

# (c) 退避先が出力ディレクトリの内側にある以上、2 回目の --fresh は 1 回目の退避先を
#     拾いうる（走査は `.[!.]*` でドットも見る）。拾うと退避が入れ子に積み上がり、
#     `--fresh` のたびに同じバイト列を 1 段深くコピーし直す。既存の `.prev-*` を
#     退避対象から外していることを 2 回目の実走で固定する。
cat > "$TMP/body.md" <<'BODY'
<!-- sentinel-1400-fresh-twice -->
## Comment Analysis Results
### Critical Issues
- なし
### Summary
- Critical: 0
BODY
FRESH2_RC=0
set +e
run_isolated PATH="$STUB:$PATH" bash "$MULTI_AGENT" \
  --task review --cli codex-cli --perspective comment-analysis \
  --base develop --timeout 60 --fresh \
  >"$TMP/issue-1400-fresh-twice.log" 2>&1
FRESH2_RC=$?
set -e
fresh_archive_count=0
nested_archive=""
for cand in "$REPO"/.review-results/.prev-*; do
  [[ -d "$cand" ]] || continue
  fresh_archive_count=$((fresh_archive_count + 1))
  for nested in "$cand"/.prev-*; do
    [[ -e "$nested" || -L "$nested" ]] || continue
    nested_archive="$nested"
  done
done
if [[ "$FRESH2_RC" -eq 0 ]] \
  && [[ "$fresh_archive_count" -eq 2 ]] \
  && [[ -z "$nested_archive" ]] \
  && grep -qF 'sentinel-1400-fresh-twice' "$REPORT"; then
  ok "2 回目の --fresh は既存の退避先を入れ子に取り込まない"
else
  bad "--fresh の再実行で退避が入れ子になる (rc=$FRESH2_RC archives=$fresh_archive_count nested=${nested_archive:-none})"
  sed -n '1,40p' "$TMP/issue-1400-fresh-twice.log" >&2 || true
fi

# (d) 呼び出し元の環境に `GLOBIGNORE` があると bash は dotglob を**暗黙に有効化**
#     する。プラン外の結果ディレクトリの走査は `"$OUTPUT_DIR"/*/` なので、
#     そのままだと退避先 `.prev-<ts>/`（中に integrated-report.md を持つ）を
#     「Not part of this run」として名指しし、利用者は自分の出力ディレクトリの
#     内部構造を残骸と読み違える。退避先が 2 件残っているこの位置で実走する。
cat > "$TMP/body.md" <<'BODY'
<!-- sentinel-1400-globignore -->
## Comment Analysis Results
### Critical Issues
- なし
### Summary
- Critical: 0
BODY
# `GLOBIGNORE` を env で渡すだけで dotglob が付くのは bash 4 以降で、bash 3.2
# （macOS 同梱）は環境からの取り込みで特殊変数のフックを呼ばない（実測）。版に
# よらず「呼び出し元由来の GLOBIGNORE 代入」を再現するため、BASH_ENV でシェル内の
# 代入も併せて与える（非対話 bash は起動時に BASH_ENV を読む）。
printf 'GLOBIGNORE=x\n' > "$TMP/globignore-env.sh"
GLOBIGNORE_RC=0
set +e
run_isolated GLOBIGNORE=x BASH_ENV="$TMP/globignore-env.sh" PATH="$STUB:$PATH" bash "$MULTI_AGENT" \
  --task review --cli codex-cli --perspective comment-analysis \
  --base develop --timeout 60 --fresh \
  >"$TMP/issue-1400-globignore.log" 2>&1
GLOBIGNORE_RC=$?
set -e
grep -F 'Not part of this run' "$TMP/issue-1400-globignore.log" > "$TMP/issue-1400-globignore-notpart.txt" || true
if [[ "$GLOBIGNORE_RC" -eq 0 ]] \
  && grep -qF 'sentinel-1400-globignore' "$REPORT" \
  && ! grep -qF -- '.prev-' "$TMP/issue-1400-globignore-notpart.txt" \
  && ! grep -qF -- '.prev-' "$REPORT"; then
  ok "GLOBIGNORE 付きの環境でも退避先をプラン外の残骸として名指ししない"
else
  bad "GLOBIGNORE 環境で退避先が名指しされる (rc=$GLOBIGNORE_RC)"
  grep -nF 'Not part of this run' "$TMP/issue-1400-globignore.log" >&2 || true
  grep -nF -- '.prev-' "$REPORT" >&2 || true
fi

git switch -q feature/x
# ── series タグを持たない旧形式レポート ────────────────────────────
#
# --fresh / 「別 series なら新シリーズ」導入より前に生成された
# `.review-results/integrated-report.md` には機械状態行が無く、series を読めない。
# 「今回の series である」ことは証明できないので、既定観点を全て回し直す
# unfiltered full review は新シリーズを開始できなければならない（さもないと
# アップグレード直後の最初のレビューが必ず止まり、手動退避を強いる）。
# 絞り込みは従来どおり止めるが、案内に復旧手段（--fresh と具体コマンド）が要る。
echo
echo "== 旧形式（series タグ無し）レポートの扱い =="

reset_review_results() {
  # 退避先は出力ディレクトリの内側なので、これだけで `.prev-*` も一緒に消える。
  rm -rf "$REPO/.review-results"
}

# 案内は「貼ればそのまま走る 1 行」であることに意味がある。前方一致で見ていると
# base 名が落ちた・引用が壊れた退行を通してしまうので、fixture の base（develop）
# まで含めた行全体を固定する。
LEGACY_FULL_REVIEW_HINT='       bash scripts/codex-review.sh --base develop'

# 旧形式の未解消 Critical レポートを置く。観点は codex-cli の distributed 実行計画
# （code-review / test-analysis / acceptance-criteria）に**無い** comprehensive-review
# にする — 実測の障害はまさに「計画に無い観点」で起きており、計画内の観点だと
# 観点照合を素通りして退行を検出できない。
write_legacy_report() {
  mkdir -p "$REPO/.review-results"
  cat > "$REPORT" <<'REPORT_BODY'
# Legacy integrated report (pre-series-tag format)
<!-- CRITICAL_BLOCK -->
Critical issues detected (comprehensive-review). Review before proceeding.
REPORT_BODY
}

# run_legacy_narrowed <log> <絞り込みフラグ...> — 旧形式レポートを残したまま走らせる
run_legacy_narrowed() {
  local log="$1"
  shift
  LEGACY_NARROWED_RC=0
  set +e
  run_isolated PATH="$STUB:$PATH" bash "$MULTI_AGENT" \
    --task review --cli codex-cli --base develop --timeout 60 "$@" \
    >"$log" 2>&1
  LEGACY_NARROWED_RC=$?
  set -e
}

# check_legacy_narrowed_guidance <ラベル> <rc> <log> <実行前レポート>
check_legacy_narrowed_guidance() {
  local label="$1" rc="$2" log="$3" before="$4"
  if [[ "$rc" -ne 0 ]] \
    && grep -qF 'omits unresolved Critical perspective(s): comprehensive-review' "$log" \
    && grep -qF -- '--fresh' "$log" \
    && grep -qxF "$LEGACY_FULL_REVIEW_HINT" "$log" \
    && cmp -s "$before" "$REPORT"; then
    ok "旧形式レポートの絞り込み（${label}）は非 0 で止まり --fresh と具体コマンドを案内する"
  else
    bad "旧形式レポートの絞り込み（${label}）で案内が不足 (rc=${rc})"
    sed -n '1,40p' "$log" >&2 || true
  fi
}

# (1) 旧形式 + 絞り込み → 非 0 で止まり、--fresh と具体コマンドを案内する。
# 絞り込みの 3 経路（--perspective / --exclude-perspective / --mode cross-model）を
# 同じ fixture で回す。1 経路だけ見ていると、残り 2 つが案内を落としても気づけない
# （どれも「新シリーズを開始できない実行」として同じ扱いを受ける必要がある）。
for legacy_narrowing in "perspective:--perspective comment-analysis" \
                        "exclude-perspective:--exclude-perspective code-review" \
                        "mode-cross-model:--mode cross-model"; do
  legacy_label="${legacy_narrowing%%:*}"
  legacy_flags="${legacy_narrowing#*:}"
  reset_review_results
  write_legacy_report
  cp "$REPORT" "$TMP/legacy-narrowed-${legacy_label}-before.md"
  # shellcheck disable=SC2086 # フラグ列は語分割させる（この配列は当ファイル内の定数）
  run_legacy_narrowed "$TMP/legacy-narrowed-${legacy_label}.log" $legacy_flags
  check_legacy_narrowed_guidance "$legacy_label" "$LEGACY_NARROWED_RC" \
    "$TMP/legacy-narrowed-${legacy_label}.log" "$TMP/legacy-narrowed-${legacy_label}-before.md"
done

# (2) 旧形式 + unfiltered full review → 手動退避なしで新シリーズを開始する
reset_review_results
write_legacy_report
cat > "$TMP/body.md" <<'BODY'
<!-- sentinel-legacy-full-review -->
## Review Results
### Critical Issues
- なし
### Summary
- Critical: 0
BODY
LEGACY_FULL_RC=0
set +e
run_isolated PATH="$STUB:$PATH" bash "$MULTI_AGENT" \
  --task review --cli codex-cli --base develop --timeout 60 \
  >"$TMP/legacy-full-review.log" 2>&1
LEGACY_FULL_RC=$?
set -e
if [[ "$LEGACY_FULL_RC" -eq 0 ]] \
  && grep -qF 'this unfiltered full review starts a new series' "$TMP/legacy-full-review.log" \
  && [[ -f "$REPORT" ]] \
  && grep -qF 'sentinel-legacy-full-review' "$REPORT" \
  && ! grep -qF 'pre-series-tag format' "$REPORT"; then
  ok "series タグ無しでも unfiltered full review は手動退避なしで新系列を開始する"
else
  bad "旧形式レポートで unfiltered full review が止まる (rc=$LEGACY_FULL_RC)"
  sed -n '1,80p' "$TMP/legacy-full-review.log" >&2 || true
fi

# (3) 回帰: series タグを持つ同一 series の未解消 Critical は従来どおりブロックする。
# 併せて、フルレビュー案内が**出ない**ことも固定する — 同一 series ではフルレビューを
# 回しても新シリーズにはならず、案内先の入口は distributed 実行計画なので、担当 CLI が
# 持たない観点は missing のまま同じエラーを再現する（案内が無限ループになる）。
reset_review_results
cat > "$TMP/body.md" <<'BODY'
<!-- sentinel-same-series-unresolved -->
## Code Review Results
### Critical Issues
- [app.txt:2] unresolved critical in the current series
### Summary
- Critical: 1
BODY
run_sequence_step "$MULTI_AGENT" code-review "$TMP/same-series-initial.log"
if [[ "$SEQUENCE_RC" -eq 0 && -f "$REPORT" ]] \
  && grep -qF "$MARKER" "$REPORT" \
  && tail -n 1 "$REPORT" | grep -F 'MULTI_CLI_UNRESOLVED_CRITICAL series:' >/dev/null; then
  ok "同一 series の未解消レポート（series タグ付き）を用意できる"
else
  bad "同一 series の未解消レポートを作れない (rc=$SEQUENCE_RC)"
fi
cp "$REPORT" "$TMP/same-series-before.md"
run_sequence_step "$MULTI_AGENT" comment-analysis "$TMP/same-series-narrowed.log"
if [[ "$SEQUENCE_RC" -ne 0 ]] \
  && grep -qF 'omits unresolved Critical perspective(s): code-review' "$TMP/same-series-narrowed.log" \
  && cmp -s "$TMP/same-series-before.md" "$REPORT"; then
  ok "同一 series の絞り込みは従来どおりブロックする（回帰なし）"
else
  bad "同一 series の絞り込みブロックが退行した (rc=$SEQUENCE_RC)"
  sed -n '1,40p' "$TMP/same-series-narrowed.log" >&2 || true
fi
if ! grep -qF 'Or run a full review, which covers every default perspective:' "$TMP/same-series-narrowed.log" \
  && ! grep -qxF "$LEGACY_FULL_REVIEW_HINT" "$TMP/same-series-narrowed.log"; then
  ok "同一 series では成立しないフルレビュー案内を出さない"
else
  bad "同一 series の絞り込みで成立しないフルレビュー案内が出ている"
  sed -n '1,40p' "$TMP/same-series-narrowed.log" >&2 || true
fi

reset_review_results


# ── pair 縮退の統合レポート記録（Issue #699） ──────────────────────
#
# 副が居ないまま単一 CLI で走った事実は stderr にしか出ておらず、レポートは
# `Mode: pair` と主張したままだった。後からレポートだけ読む人・エージェントが
# クロスモデル済みと誤読する。ここで検査するのは 2 点:
#   (1) 縮退の事実が Reviewers 行としてレポートに残る
#   (2) その行が共有 severity パーサー（Issue #908）の判定を動かさない
#       — 受理ゲート・CRITICAL_BLOCK は行文法で判定するので、レポートへ足す行が
#         severity 行に見えると偽 BLOCK になる。既存の Mode / Strategy 行と同じ
#         `**Label:** value` 形にしてあることを、実走のマーカー不在で確かめる。
echo
echo "== pair 縮退のレポート記録（Issue #699） =="
# 主レビュワーと HOME / XDG は明示固定する。クリーン環境では主が未設定になり
# pair プランが組まれず Reviewers 行が出ないため、環境依存で赤くなる。
ISSUE_699_HOME="$TMP/home-699"
mkdir -p "$ISSUE_699_HOME"

# (a) 副が未設定 → 縮退理由つきで記録される
rm -rf "$REPO/.review-results" "$REPO/.claude"
printf '%s\n' 'Summary' '' '- Critical: 0' '' 'sentinel-699-reviewers-line' > "$TMP/body.md"
set +e
run_isolated PATH="$STUB:/usr/bin:/bin" HOME="$ISSUE_699_HOME" XDG_CONFIG_HOME="$ISSUE_699_HOME/.config" \
  MULTI_AGENT_REVIEW_MAIN=codex-cli MULTI_AGENT_REVIEW_SUB= bash "$MULTI_AGENT" \
  --task review --perspective code-review \
  --base develop --timeout 60 >"$TMP/issue-699-report.log" 2>&1
ISSUE_699_RC=$?
set -e
if [ "$ISSUE_699_RC" -eq 0 ] && [ -f "$REPORT" ]; then
  if grep -q '^\*\*Reviewers:\*\* codex-cli (single — no sub reviewer set)$' "$REPORT"; then
    ok "副なしの縮退が統合レポートの Reviewers 行に残る"
  else
    bad "縮退がレポートに残らない（Mode: pair だけが残りクロスモデル済みと誤読される）"
    sed -n '1,10p' "$REPORT" | sed 's/^/    | /' >&2
  fi
  # ヘッダ書式が壊れていないこと自体を見る。CRITICAL_BLOCK は result file を読むので
  # ヘッダを壊しても立たず、マーカー不在は非干渉の証明にならない（Issue #699 レビュー）。
  if grep -q '^\*\*Mode:\*\* pair$' "$REPORT" \
    && grep -q '^\*\*Strategy:\*\* ' "$REPORT" \
    && grep -q '^\*\*Base Branch:\*\* ' "$REPORT"; then
    ok "Reviewers 行の挿入で既存ヘッダ行（Mode / Strategy / Base Branch）が壊れない"
  else
    bad "Reviewers 行の挿入でヘッダ書式が壊れた（コマンド置換の改行処理）"
    sed -n '1,10p' "$REPORT" | sed 's/^/    | /' >&2
  fi
  if ! grep -qF "$MARKER" "$REPORT"; then
    ok "ゼロ件本文で CRITICAL_BLOCK が立たない（Reviewers 行が判定を動かさない）"
  else
    bad "Reviewers 行の追加で CRITICAL_BLOCK が立った（共有 severity パーサーと干渉している）"
    sed -n '1,10p' "$REPORT" | sed 's/^/    | /' >&2
  fi
else
  bad "Issue #699 のレポート検査を実行できない (rc=${ISSUE_699_RC} report=${REPORT})"
  tail -5 "$TMP/issue-699-report.log" | sed 's/^/    | /' >&2
fi

# (b) 副は導入済みだが --perspective で計画から外れる経路。副の導入可否だけで
#     Reviewers 行を決めると、ここが「codex-cli + claude-code」と嘘をつく。
#     副を「導入済み」にするため claude stub をこのケースの間だけ置く。
cat > "$STUB/claude" <<SH
#!/usr/bin/env bash
cat "$TMP/body.md"
SH
chmod +x "$STUB/claude"
rm -rf "$REPO/.review-results" "$REPO/.claude"
printf '%s\n' 'Summary' '' '- Critical: 0' '' 'sentinel-699-filtered-sub' > "$TMP/body.md"
set +e
run_isolated PATH="$STUB:/usr/bin:/bin" HOME="$ISSUE_699_HOME" XDG_CONFIG_HOME="$ISSUE_699_HOME/.config" \
  MULTI_AGENT_REVIEW_MAIN=codex-cli MULTI_AGENT_REVIEW_SUB=claude-code bash "$MULTI_AGENT" \
  --task review --perspective code-review \
  --base develop --timeout 60 >"$TMP/issue-699-filtered.log" 2>&1
ISSUE_699_FILTERED_RC=$?
set -e
if [ "$ISSUE_699_FILTERED_RC" -eq 0 ] && [ -f "$REPORT" ]; then
  # 副が導入済みでも計画に居ないので、2 CLI 形（`A + B`）にはならないこと。
  # 縮退理由の文中に副の名が出るのは正しい（誰が落ちたかを名乗るため）。
  if grep -q '^\*\*Reviewers:\*\* codex-cli (single' "$REPORT" \
    && ! grep -q '^\*\*Reviewers:\*\* .* + ' "$REPORT"; then
    ok "計画から外れた副を実効レビュワーとして記録しない（実効プランから導出）"
  else
    bad "走っていない副がレビュワーとして記録された（クロスモデル済みと誤読される）"
    sed -n '1,10p' "$REPORT" | sed 's/^/    | /' >&2
  fi
else
  bad "Issue #699 の filter 経路を実行できない (rc=${ISSUE_699_FILTERED_RC})"
  tail -5 "$TMP/issue-699-filtered.log" | sed 's/^/    | /' >&2
fi

# (c) 正常系: 副が計画に入る既定構成は 2 CLI 形で記録される。縮退側だけを pin すると、
#     健全系を壊す実装（固定文字列を返す等）が緑のまま通る（ACE-253-3/4）。
rm -rf "$REPO/.review-results" "$REPO/.claude"
printf '%s\n' 'Summary' '' '- Critical: 0' '' 'sentinel-699-pair-both' > "$TMP/body.md"
set +e
run_isolated PATH="$STUB:/usr/bin:/bin" HOME="$ISSUE_699_HOME" XDG_CONFIG_HOME="$ISSUE_699_HOME/.config" \
  MULTI_AGENT_REVIEW_MAIN=codex-cli MULTI_AGENT_REVIEW_SUB=claude-code bash "$MULTI_AGENT" \
  --task review --base develop --timeout 60 >"$TMP/issue-699-both.log" 2>&1
ISSUE_699_BOTH_RC=$?
set -e
if [ "$ISSUE_699_BOTH_RC" -eq 0 ] && [ -f "$REPORT" ]; then
  if grep -q '^\*\*Reviewers:\*\* claude-code + codex-cli$' "$REPORT"; then
    ok "副が計画に入る既定構成は 2 CLI 形で記録される（正常系）"
  else
    bad "正常系の Reviewers 行が 2 CLI 形になっていない"
    grep '^\*\*Reviewers:' "$REPORT" | sed 's/^/    | /' >&2
  fi
else
  bad "Issue #699 の正常系を実行できない (rc=${ISSUE_699_BOTH_RC})"
  tail -5 "$TMP/issue-699-both.log" | sed 's/^/    | /' >&2
fi

# (d) pair 以外では 1 バイトも足さない（レポート書式の不変を pin）。
rm -rf "$REPO/.review-results" "$REPO/.claude"
printf '%s\n' 'Summary' '' '- Critical: 0' '' 'sentinel-699-distributed' > "$TMP/body.md"
set +e
run_isolated PATH="$STUB:/usr/bin:/bin" HOME="$ISSUE_699_HOME" XDG_CONFIG_HOME="$ISSUE_699_HOME/.config" \
  bash "$MULTI_AGENT" --task review --mode distributed --cli codex-cli \
  --base develop --timeout 60 >"$TMP/issue-699-distributed.log" 2>&1
ISSUE_699_DIST_RC=$?
set -e
if [ "$ISSUE_699_DIST_RC" -eq 0 ] && [ -f "$REPORT" ]; then
  if ! grep -q '^\*\*Reviewers:' "$REPORT"; then
    ok "pair 以外のモードではレポートへ Reviewers 行を足さない"
  else
    bad "distributed モードで Reviewers 行が出ている（他モードの書式を変えている）"
    sed -n '1,10p' "$REPORT" | sed 's/^/    | /' >&2
  fi
else
  bad "Issue #699 の distributed 経路を実行できない (rc=${ISSUE_699_DIST_RC})"
  tail -5 "$TMP/issue-699-distributed.log" | sed 's/^/    | /' >&2
fi
rm -f "$STUB/claude"

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ multi-agent-critical-marker verify: $FAIL 件失敗" >&2
  exit 1
fi
echo "✓ multi-agent-critical-marker verify: 全 $PASS 件 pass"
FF_REACHED_END=1
