#!/usr/bin/env bash
#
# multi-agent-stale-outputs: 前回実行の観点ファイルが「今回の結果」として読まれない
# ことの実挙動検査（Issue #537 / #654）。
#
# 背景: clear_planned_outputs は**今回のプランが書く先**だけを消すので、観点を絞った
# 実行のあとには前回実行が書いた別観点のファイルが同じディレクトリに残る。
# integrated-report.md はプランを反復するため混ざらないが、`ls .review-results/<cli>/`
# や個別ファイルを直接読む消費者（人間・エージェント）には現行結果と区別がつかない。
# 実運用で 2 度、数日前の別 PR への Critical 指摘を今回の diff への指摘として読み
# 始めるところだった（`Generated` 時刻に気付いて回避 = 能動確認なしでは気付けない）。
#
# 現行の契約:
#   - 今回のプランに載る CLI のディレクトリ直下の「プラン外 × orchestrator 自筆
#     （write_output の 1 行目マーカーを持つ）」の `*.md` を `<cli>/previous/` へ退避
#   - 利用者が置いた `.md`・プラン外 CLI のディレクトリ・非 `.md`・サブディレクトリは
#     動かさず、結果ファイルを持つものは stderr と統合レポートで名指しする
#   - `previous/` は毎回作り直し、捨てた件数を名乗る
#   - 解決検査は resume 書き戻し・clear_planned_outputs より**前**に一括で行う。
#     `<cli>` が出力先の外を指す symlink なら、外部を 1 バイトも触らずに中断する
#   - `<cli>/previous` の symlink は**追わず**リンク自体を消す（追うと指し先を rm -rf）
#
# 実 CLI は起動しない。codex を stub で覆い orchestrator の実経路を通す。
# 書き込み不可の環境では suite 全体を skip する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
MULTI_AGENT="$PLUGIN_ROOT/scripts/multi-agent.sh"

# 針の総数を固定する（TESTING.md の EXPECTED_CHECKS 方針）。針を消す変異が
# 「緑のまま検出力だけ落ちる」形で通らないようにする。
EXPECTED_CHECKS=43

[ -f "$MULTI_AGENT" ] || {
  echo "✗ 対象ファイルが見つかりません: $MULTI_AGENT" >&2
  exit 1
}

# 実行環境の MULTI_AGENT_* から分離する（Issue #374 / #378 の共通機構）。
# shellcheck source=../lib/adapter-env-isolation.sh
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"
build_isolate_env "MULTI_AGENT_CONFIG MULTI_AGENT_CODEX_PROFILE" \
  "$MULTI_AGENT" "$PLUGIN_ROOT"/scripts/adapters/*.sh

if _ff_mktemp_out="$(mktemp -d 2>&1)"; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できない環境（read-only）のためスキップ"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  exit 0
fi

FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$TMP"
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ multi-agent-stale-outputs: 最後まで到達しませんでした（途中で中断）" >&2
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
git init -q "$REPO"
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "multi-agent-stale-outputs-test"
git -C "$REPO" config commit.gpgsign false
git -C "$REPO" switch -q -c develop
printf 'base\n' > "$REPO/app.txt"
git -C "$REPO" add app.txt
git -C "$REPO" commit -qm "init"
git -C "$REPO" switch -q -c feature/stale
printf 'base\nreview change\n' > "$REPO/app.txt"
git -C "$REPO" add app.txt
git -C "$REPO" commit -qm "review change"

# --- stub CLI（起動回数を数える。「起動前に落ちた」を測るため） ---
STUB="$TMP/bin"
COUNT_FILE="$TMP/invocations"
mkdir -p "$STUB"
printf '0\n' > "$COUNT_FILE"
cat > "$STUB/codex" <<SH
#!/usr/bin/env bash
set -euo pipefail
n="\$(cat "$COUNT_FILE")"
printf '%s\n' "\$((n + 1))" > "$COUNT_FILE"
printf '%s\n' \
  "## Stub Review" \
  "" \
  "FRESH-RESULT" \
  "" \
  "### Summary" \
  "- Critical: 0"
SH
chmod +x "$STUB/codex"

OUT="$REPO/.review-results"
REPORT="$OUT/integrated-report.md"
STALE_MARK="STALE-FROM-PREVIOUS-RUN"
PLAN_PERSPECTIVES=(code-review error-handler-hunt type-design-analysis)

count_invocations() { tr -d '[:space:]' < "$COUNT_FILE"; }

# orchestrator 自筆の結果ファイル（write_output の 1 行目マーカー入り）を模す。
# 退避対象はマーカーを持つものだけなので、fixture 側もその形で置く。
plant_result() { # <path> <cli> <perspective> [body]
  local path="$1" cli="$2" persp="$3" body="${4:-$STALE_MARK}"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' \
    '<!-- Multi-CLI Review Result -->' \
    "<!-- CLI: ${cli} -->" \
    "<!-- Perspective: ${persp} -->" \
    '<!-- Task Type: review -->' \
    '<!-- Status: complete -->' \
    '<!-- Generated: 2020-01-01T00:00:00Z -->' \
    '' \
    "$body" > "$path"
}

run_review() { # <log> [extra args...]
  local log="$1" rc=0 args p
  shift
  args=(--task review --mode distributed --sequential --cli codex-cli
        --base develop --timeout 60)
  for p in "${PLAN_PERSPECTIVES[@]}"; do
    args+=(--perspective "$p")
  done
  if [[ "$#" -gt 0 ]]; then
    args+=("$@")
  fi
  set +e
  (
    cd "$REPO"
    run_isolated PATH="$STUB:$PATH" bash "$MULTI_AGENT" "${args[@]}"
  ) >"$log" 2>&1
  rc=$?
  set -e
  return "$rc"
}

echo "== プラン外の自筆結果だけを previous/ へ退避する =="
mkdir -p "$OUT/codex-cli/files/keep" "$OUT/claude-code"
# 前回実行の残骸（今回のプランに無い観点） = 退避対象
plant_result "$OUT/codex-cli/test-analysis.md" codex-cli test-analysis
plant_result "$OUT/codex-cli/security-analysis.md" codex-cli security-analysis
# 今回のプランに載る観点の前回結果（退避対象ではなく、今回の実行が上書きする）
plant_result "$OUT/codex-cli/code-review.md" codex-cli code-review
# 利用者が置いた .md（マーカーなし）= 動かさず名指しだけ
printf '# my notes\n%s\n' "$STALE_MARK" > "$OUT/codex-cli/my-notes.md"
# プランに載っていない CLI のディレクトリ（触ってはいけない）
plant_result "$OUT/claude-code/comment-analysis.md" claude-code comment-analysis
# 結果ファイルではないもの（触ってはいけない）
printf '%s\n' "$STALE_MARK" > "$OUT/codex-cli/notes.txt"
printf '%s\n' "$STALE_MARK" > "$OUT/codex-cli/files/keep/generated.txt"

if run_review "$TMP/run-a.log"; then
  ok "退避を伴う実行が成功する"
else
  bad "退避を伴う実行が失敗した（ログ: $TMP/run-a.log）"
  sed -n '1,40p' "$TMP/run-a.log" >&2 || true
fi

if [[ ! -e "$OUT/codex-cli/test-analysis.md" && ! -e "$OUT/codex-cli/security-analysis.md" ]]; then
  ok "プラン外の前回結果が CLI ディレクトリ直下から消えている"
else
  bad "プラン外の前回結果が直下に残っている（現行結果と誤読される）"
fi

if [[ -f "$OUT/codex-cli/previous/test-analysis.md" \
      && -f "$OUT/codex-cli/previous/security-analysis.md" ]] \
   && grep -qF "$STALE_MARK" "$OUT/codex-cli/previous/test-analysis.md"; then
  ok "前回結果は削除ではなく previous/ へ退避されている"
else
  bad "previous/ に前回結果が退避されていない"
fi

missing_planned=0
for p in "${PLAN_PERSPECTIVES[@]}"; do
  [[ -f "$OUT/codex-cli/${p}.md" ]] || missing_planned=$((missing_planned + 1))
done
if [[ "$missing_planned" -eq 0 ]]; then
  ok "今回のプラン 3 観点の結果ファイルが揃っている"
else
  bad "今回のプランの結果ファイルが ${missing_planned} 件欠けている"
fi

if [[ ! -e "$OUT/codex-cli/previous/code-review.md" ]] \
   && grep -qF 'FRESH-RESULT' "$OUT/codex-cli/code-review.md"; then
  ok "プラン内観点の前回結果は退避せず今回の結果で置き換える"
else
  bad "プラン内観点まで退避した（今回の結果が previous/ に紛れる）"
fi

if ! grep -qF "$STALE_MARK" "$REPORT"; then
  ok "統合レポートに前回実行の内容が混ざらない"
else
  bad "統合レポートに前回実行の内容が混ざった"
fi

if [[ "$(grep -c '^## codex-cli — ' "$REPORT")" -eq 3 ]]; then
  ok "統合レポートの節は今回の 3 観点だけ"
else
  bad "統合レポートの節数が 3 ではない"
fi

if grep -qF 'Moved 2 result(s) from a previous run' "$TMP/run-a.log"; then
  ok "退避したことと件数を実行ログで名乗る"
else
  bad "退避の通知が実行ログに出ない（黙って移動している）"
fi

if grep -E 'Moved 2 result\(s\).*: .*(test-analysis|security-analysis).*(test-analysis|security-analysis)' \
     "$TMP/run-a.log" >/dev/null; then
  ok "退避通知が観点名を列挙する"
else
  bad "退避通知に観点名が出ない（どれが動いたか分からない）"
fi

if [[ -f "$OUT/codex-cli/my-notes.md" ]] && grep -qF "$STALE_MARK" "$OUT/codex-cli/my-notes.md"; then
  ok "orchestrator が書いていない .md は退避しない（利用者のファイル）"
else
  bad "自筆でない .md を退避した（1 実行後に捨てられる場所へ他人のファイルを入れた）"
fi

if grep -qF 'Not part of this run: codex-cli/ (1 .md file(s) this orchestrator did not write' "$TMP/run-a.log"; then
  ok "動かさなかった非自筆 .md を stderr で名指しする"
else
  bad "非自筆 .md を黙って放置した（今回の結果と誤読される）"
fi

if [[ -f "$OUT/claude-code/comment-analysis.md" ]] \
   && grep -qF "$STALE_MARK" "$OUT/claude-code/comment-analysis.md"; then
  ok "今回のプランに無い CLI のディレクトリには触れない"
else
  bad "プラン外 CLI のファイルを動かした（宣言している境界の破り）"
fi

if [[ ! -e "$OUT/claude-code/previous" ]]; then
  ok "プラン外 CLI には previous/ を作らない"
else
  bad "プラン外 CLI に previous/ を作った"
fi

if grep -qF 'Not part of this run: claude-code/ (1 result file(s) from an earlier run' "$TMP/run-a.log"; then
  ok "プラン外 CLI ディレクトリの残骸を stderr で名指しする"
else
  bad "プラン外 CLI の残骸を黙って放置した（ls で今回の結果に見える）"
fi

if grep -qF '**Not part of this run**' "$REPORT" \
   && grep -qF '> - claude-code/' "$REPORT" \
   && grep -qF '> - codex-cli/' "$REPORT"; then
  ok "統合レポートにも「今回の結果ではない」名指しが載る"
else
  bad "レポート経由の消費者に残骸の存在が届かない"
fi

if [[ -f "$OUT/codex-cli/notes.txt" ]]; then
  ok "結果ファイルでない .md 以外は退避しない"
else
  bad "*.md 以外まで退避した"
fi

if [[ -f "$OUT/codex-cli/files/keep/generated.txt" ]]; then
  ok "サブディレクトリ（implement の staging 等）には触れない"
else
  bad "サブディレクトリの中身を動かした"
fi

echo ""
echo "== previous/ は毎回作り直し、捨てた件数を名乗る =="
if run_review "$TMP/run-b.log"; then
  ok "退避対象が無い再実行も成功する"
else
  bad "退避対象が無い再実行が失敗した（ログ: $TMP/run-b.log）"
fi

if [[ ! -e "$OUT/codex-cli/previous" ]]; then
  ok "押し出す結果が無い実行では previous/ が残らない"
else
  bad "previous/ に前々回の退避分が残った（いつの実行か判別できない）"
fi

if grep -qF 'Discarded 2 quarantined result(s)' "$TMP/run-b.log"; then
  ok "退避分を捨てたことと件数を名乗る"
else
  bad "退避分を無言で捨てた（利用者は previous/ を探しに行く）"
fi

echo ""
echo "== --resume で再利用した観点の結果を自分で退避しない =="
# 判定の基準は「今回のプラン全体」（FULL_EXECUTION_PLAN）であって「今回実行する分」
# ではない。実行分だけを基準にすると、resume がキャッシュから書き戻した結果を
# 直後に previous/ へ押し出し、レポートが「出力なし」に化ける。
# 部分 resume（一部再利用・一部再実行）でしか差が出ないため、1 観点分のキャッシュ
# だけを落として「2 件は再利用・1 件は再実行」の実行を作る。
CACHED_CODE_REVIEW="$(find "$OUT/.resume-cache" -path '*/codex-cli/code-review.md' | head -1)"
if [[ -n "$CACHED_CODE_REVIEW" ]]; then
  rm -f "$CACHED_CODE_REVIEW" "${CACHED_CODE_REVIEW}.hash"
  ok "1 観点分の resume キャッシュだけを落とせた（部分 resume の前提）"
else
  bad "resume キャッシュが見つからない（fixture の前提が崩れている）"
fi

if run_review "$TMP/run-c.log" --resume; then
  ok "部分 resume が成功する"
else
  bad "部分 resume が失敗した（ログ: $TMP/run-c.log）"
fi

resume_lost=0
for p in "${PLAN_PERSPECTIVES[@]}"; do
  [[ -f "$OUT/codex-cli/${p}.md" ]] || resume_lost=$((resume_lost + 1))
done
if [[ "$resume_lost" -eq 0 && ! -e "$OUT/codex-cli/previous" ]]; then
  ok "部分 resume で再利用した結果を previous/ へ押し出さない"
else
  bad "部分 resume が書き戻した結果を退避した（欠落 ${resume_lost} 件）"
fi

if [[ "$(grep -c '^\*\*Result source:\*\* reused$' "$REPORT")" -eq 2 \
      && "$(grep -c '^\*\*Result source:\*\* executed$' "$REPORT")" -eq 1 ]]; then
  ok "統合レポートは再利用 2 / 実行 1 を記録する"
else
  bad "部分 resume の由来表示が 2/1 ではない"
fi

# 完全 resume では EXECUTION_PLAN が空になる。プラン全体を基準にしていないと、
# ここは「何も退避しない」形で偶然通る（= 部分 resume と両方が要る）。
if run_review "$TMP/run-d.log" --resume; then
  ok "完全 resume が成功する"
else
  bad "完全 resume が失敗した（ログ: $TMP/run-d.log）"
fi

if grep -qF 'All review tasks were restored' "$TMP/run-d.log"; then
  ok "完全 resume は 1 観点も実行しない（EXECUTION_PLAN が空の経路）"
else
  bad "完全 resume の経路に入っていない（fixture の前提が崩れている）"
fi

resume_lost=0
for p in "${PLAN_PERSPECTIVES[@]}"; do
  [[ -f "$OUT/codex-cli/${p}.md" ]] || resume_lost=$((resume_lost + 1))
done
if [[ "$resume_lost" -eq 0 && ! -e "$OUT/codex-cli/previous" ]]; then
  ok "完全 resume でも再利用した 3 件を退避しない"
else
  bad "完全 resume が書き戻した結果を退避した（欠落 ${resume_lost} 件）"
fi

echo ""
echo "== previous/ の symlink は追わず、リンク自体だけを消す =="
# `[[ -d ]]` は symlink→dir でも真になるため、-L を先に見ないと解決先を rm -rf する。
# 出力先の**内側**を指していても消してはいけない（ここでは他 CLI のディレクトリ）。
rm -rf "$OUT/codex-cli/previous"
ln -s "../claude-code" "$OUT/codex-cli/previous"
plant_result "$OUT/codex-cli/test-analysis.md" codex-cli test-analysis
if run_review "$TMP/run-e.log"; then
  ok "previous/ が symlink でも実行は成功する"
else
  bad "previous/ の symlink で実行が失敗した（ログ: $TMP/run-e.log）"
fi

if [[ -f "$OUT/claude-code/comment-analysis.md" ]] \
   && grep -qF "$STALE_MARK" "$OUT/claude-code/comment-analysis.md"; then
  ok "symlink の指し先（他 CLI のディレクトリ）を消さない"
else
  bad "previous/ の symlink を追って指し先を消した"
fi

if [[ -d "$OUT/codex-cli/previous" && ! -L "$OUT/codex-cli/previous" ]] \
   && [[ -f "$OUT/codex-cli/previous/test-analysis.md" ]]; then
  ok "symlink を外して実ディレクトリを作り直し、退避先として使う"
else
  bad "symlink 除去後の previous/ が実ディレクトリになっていない"
fi

if grep -qF 'Removed a symlink at the quarantine path' "$TMP/run-e.log"; then
  ok "symlink を外したことを名乗る"
else
  bad "symlink の除去を黙って行った"
fi

echo ""
echo "== previous がディレクトリでない残骸でも退避できる =="
rm -rf "$OUT/codex-cli/previous"
printf 'not a directory\n' > "$OUT/codex-cli/previous"
plant_result "$OUT/codex-cli/test-analysis.md" codex-cli test-analysis
if run_review "$TMP/run-f.log"; then
  ok "previous が通常ファイルでも実行は成功する"
else
  bad "previous が通常ファイルのとき実行が失敗した（ログ: $TMP/run-f.log）"
fi

if [[ -d "$OUT/codex-cli/previous" && -f "$OUT/codex-cli/previous/test-analysis.md" ]]; then
  ok "非ディレクトリの残骸を退けて退避先を作り直す"
else
  bad "非ディレクトリの previous を処理できていない"
fi

echo ""
echo "== previous/ が出力先の外を指す symlink でも外部を触らない =="
OUTSIDE="$TMP/outside-previous"
mkdir -p "$OUTSIDE"
printf 'sentinel\n' > "$OUTSIDE/keep-me.txt"
rm -rf "$OUT/codex-cli/previous"
ln -s "$OUTSIDE" "$OUT/codex-cli/previous"
plant_result "$OUT/codex-cli/test-analysis.md" codex-cli test-analysis
if run_review "$TMP/run-g.log"; then
  ok "外を指す previous/ の symlink でも実行は成功する"
else
  bad "外を指す previous/ の symlink で実行が失敗した（ログ: $TMP/run-g.log）"
fi

if [[ -f "$OUTSIDE/keep-me.txt" ]]; then
  ok "出力先の外のファイルを消さない・動かさない"
else
  bad "出力先の外のファイルを壊した"
fi

echo ""
echo "== CLI ディレクトリが出力先の外を指すなら、何も書かず消さずに中断する =="
# 検査は resume 書き戻し・clear_planned_outputs より**前**に行う。後ろに置くと、
# 中断する前に (a) clear_planned_outputs の rm -f が外部の**プラン内**ファイルを消し、
# (b) --resume ではキャッシュの cp が外部の同名ファイルを上書きする。
# --resume を付けて実行するのは (b) も同じ針で測るため — この時点でキャッシュは
# 直前の実行で埋まっているので、検査が後ろにあれば書き戻しが外部へ届く。
rm -rf "$OUT/codex-cli/previous"
OUTSIDE_CLI="$TMP/outside-cli"
mkdir -p "$OUTSIDE_CLI"
plant_result "$OUTSIDE_CLI/test-analysis.md" codex-cli test-analysis
plant_result "$OUTSIDE_CLI/code-review.md" codex-cli code-review "EXTERNAL-PLANNED-KEEP"
rm -rf "$OUT/codex-cli"
ln -s "$OUTSIDE_CLI" "$OUT/codex-cli"
rm -f "$REPORT"
BEFORE_H="$(count_invocations)"
if run_review "$TMP/run-h.log" --resume; then
  bad "出力先の外を指す CLI ディレクトリでも実行が成功した"
else
  ok "出力先の外を指す CLI ディレクトリで非 0 終了する"
fi

if grep -qF 'Aborted before running any task' "$TMP/run-h.log"; then
  ok "タスク起動前に中断したことを名乗る"
else
  bad "中断の宣言が無い（レポートまで進んでいる可能性）"
fi

if [[ -f "$OUTSIDE_CLI/code-review.md" ]] \
   && grep -qF 'EXTERNAL-PLANNED-KEEP' "$OUTSIDE_CLI/code-review.md"; then
  ok "外部の**プラン内**ファイルを削除も上書きもしない（検査が resume 復元 / clear より前）"
else
  bad "検査到達前に外部のプラン内ファイルが壊れた（--resume 実行なので最初に届くのは restore_cached_result の cp、次が clear_planned_outputs の rm -f）"
fi

if [[ -f "$OUTSIDE_CLI/test-analysis.md" ]] \
   && grep -qF "$STALE_MARK" "$OUTSIDE_CLI/test-analysis.md"; then
  ok "外部のプラン外ファイルを退避先へ動かさない"
else
  bad "出力先の外のファイルを動かした"
fi

if [[ "$(count_invocations)" -eq "$BEFORE_H" ]]; then
  ok "CLI を 1 つも起動せずに落ちる"
else
  bad "落ちる前に CLI を起動した（課金・実行時間の無駄）"
fi

if [[ ! -e "$REPORT" ]]; then
  ok "中断した実行は統合レポートを残さない"
else
  bad "中断したのに統合レポートがある（前回の結果を今回として案内する）"
fi

echo ""
echo "== CLI ディレクトリが出力先の**内側**を指す symlink でも中断する =="
# 配下であるだけでは足りない。別名で 2 つの CLI が同じ実ディレクトリを指すと、
# 同じ場所から退避しつつ「今回のプラン外」と名指しする矛盾した実行になる。
rm -f "$OUT/codex-cli"
mkdir -p "$OUT/claude-code"
plant_result "$OUT/claude-code/comment-analysis.md" claude-code comment-analysis
ln -s "claude-code" "$OUT/codex-cli"
BEFORE_I="$(count_invocations)"
if run_review "$TMP/run-i.log"; then
  bad "出力先の内側を指す CLI ディレクトリの別名でも実行が成功した"
else
  ok "出力先の内側を指す CLI ディレクトリの別名で非 0 終了する"
fi

if [[ -f "$OUT/claude-code/comment-analysis.md" ]] \
   && grep -qF "$STALE_MARK" "$OUT/claude-code/comment-analysis.md" \
   && [[ ! -e "$OUT/claude-code/previous" ]] \
   && [[ "$(count_invocations)" -eq "$BEFORE_I" ]]; then
  ok "別名の指し先を退避も削除もせず、CLI を起動しない"
else
  bad "別名の指し先へ退避・削除が及んだ（プラン外 CLI の結果が動く）"
fi

echo ""
echo "== 結果 =="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
TOTAL=$((PASS + FAIL))
if [[ "$TOTAL" -ne "$EXPECTED_CHECKS" ]]; then
  echo "✗ 検査総数が ${EXPECTED_CHECKS} ではありません（実測 ${TOTAL}）。針の増減時は EXPECTED_CHECKS も更新すること" >&2
  exit 1
fi
FF_REACHED_END=1
[[ "$FAIL" -eq 0 ]]
