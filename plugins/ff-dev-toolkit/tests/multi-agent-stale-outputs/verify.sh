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
#   - staging（`<cli>/files/<perspective>/`）は**退避せず名指しだけ**（Issue #724）。
#     ファイルを持つ staging（implement ではプラン内タスクの分だけ除外。review /
#     explore は staging を clear も write もしないため全て対象）・`files/` 直下の
#     生ファイルや非ディレクトリ実体・symlink（`files/` 自体もエントリも追わず
#     リンクとして名指し）・プラン外 CLI の files/ 残骸（直下 .md の有無とは独立に
#     報告）が対象。空の staging は名指しせず、走査に失敗したものは 0 件でも
#     「有り」でもなく「走査できなかった」として名指しする（rc は実行へ波及させない）
#   - 退避は task type 非依存（implement のサマリ .md も同じ経路で previous/ へ）
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
build_isolate_env "MULTI_AGENT_CONFIG MULTI_AGENT_CODEX_PROFILE" \
  "$MULTI_AGENT" "$PLUGIN_ROOT"/scripts/adapters/*.sh

# rc=0 でも -d を検査する — 2>&1 の合流は「成功 + stderr 警告」の環境で変数へ
# 警告文が混入し、以後の処理が原因不明の失敗に化けるため。
if _ff_mktemp_out="$(mktemp -d 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できない環境のためスキップ"
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
ff_git_fixture_init "$REPO" "multi-agent-stale-outputs-test" "test@example.com"
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
# implement 経路の require_cd_capability は起動前に \`codex exec --help\` を読み、
# "-C, --cd" の表記が無ければ中断する。help 応答は起動回数に数えない。
for a in "\$@"; do
  if [[ "\$a" == "--help" ]]; then
    printf '%s\n' '  -C, --cd <DIR>  stub capability probe'
    exit 0
  fi
done
n="\$(cat "$COUNT_FILE")"
printf '%s\n' "\$((n + 1))" > "$COUNT_FILE"
# implement では -C <staging> が渡る。実 CLI と同じく staging へ 1 ファイル生成する
# （観点を絞った再実行のあとに files/ 残骸が残る、という fixture の実体を作る）。
prev=""
for a in "\$@"; do
  if [[ "\$prev" == "-C" ]]; then
    mkdir -p "\$a"
    printf 'GENERATED-BY-STUB\n' > "\$a/generated.txt"
  fi
  prev="\$a"
done
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
# staging の名指し対象と非対象（Issue #724）:
#   keep         … ファイルを持つ staging = 名指しする（上で作成済み）
#   empty-keep   … 空の staging = 名指ししない
#   link-keep    … staging の symlink = 追わず symlink として名指しする
#   dangling     … dangling symlink = 同じく symlink として名指しする
#   stray.txt    … files/ 直下の生ファイル = 名指しする
#   code-review  … プラン内観点だが **review 実行**なので名指しする
#                  （staging は implement の概念。review はここを clear も write も
#                  しないため、プラン内の観点名でも中身は前回の残骸でしかない）
mkdir -p "$OUT/codex-cli/files/empty-keep" "$OUT/codex-cli/files/code-review"
printf '%s\n' "$STALE_MARK" > "$OUT/codex-cli/files/code-review/planned.txt"
ln -s keep "$OUT/codex-cli/files/link-keep"
ln -s no-such-target "$OUT/codex-cli/files/dangling"
printf '%s\n' "$STALE_MARK" > "$OUT/codex-cli/files/stray.txt"
# 直下に .md を持たないが files/ に残骸を持つプラン外 CLI（fall-back の名指し対象）
mkdir -p "$OUT/grok-cli/files/security-analysis"
printf '%s\n' "$STALE_MARK" > "$OUT/grok-cli/files/security-analysis/leftover.txt"
# 直下 .md と files/ 残骸の**両方**を持つプラン外 CLI（.md があっても staging を
# 黙らせない独立報告の検査対象。claude-code は上で comment-analysis.md を植えてある）
mkdir -p "$OUT/claude-code/files/comment-analysis"
printf '%s\n' "$STALE_MARK" > "$OUT/claude-code/files/comment-analysis/leftover.txt"

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

if grep -qF "Not part of this run: codex-cli/files/keep/ (1 staging file(s) from an earlier run — left untouched, not this run's output)" "$TMP/run-a.log"; then
  ok "ファイルを持つプラン外 staging を件数つきで名指しする（Issue #724）"
else
  bad "プラン外 staging の残骸が実行ログに出ない（ls files/ で今回の成果に見える）"
fi

if grep -qF '> - codex-cli/files/keep/' "$REPORT"; then
  ok "staging 残骸の名指しが統合レポートにも載る"
else
  bad "レポート経由の消費者に staging 残骸の存在が届かない"
fi

if grep -qF 'Not part of this run: codex-cli/files/code-review/ (1 staging file(s) from an earlier run' "$TMP/run-a.log"; then
  ok "review 実行ではプラン内観点の staging も名指しする（review は staging を clear も write もしない）"
else
  bad "観点名がプランに載っているだけの理由で staging 残骸が黙って素通りした"
fi

if ! grep -q 'codex-cli/files/empty-keep' "$TMP/run-a.log"; then
  ok "空の staging は名指ししない（誤らせる中身が無い）"
else
  bad "空ディレクトリまで名指しした（ノイズで本物の残骸が埋まる）"
fi

if grep -qF 'Not part of this run: codex-cli/files/link-keep (symlink left from an earlier run — not followed' "$TMP/run-a.log" \
   && [[ -L "$OUT/codex-cli/files/link-keep" ]]; then
  ok "staging の symlink は追わず、symlink として名指しする"
else
  bad "staging の symlink を追った、または黙って素通しした"
fi

if grep -qF 'Not part of this run: codex-cli/files/dangling (symlink left from an earlier run — not followed' "$TMP/run-a.log" \
   && [[ -L "$OUT/codex-cli/files/dangling" ]]; then
  ok "dangling symlink も黙って落とさず、symlink として名指しする"
else
  bad "dangling symlink が glob から黙って抜け落ちた"
fi

if grep -qF 'Not part of this run: codex-cli/files/stray.txt (stray file from an earlier run' "$TMP/run-a.log" \
   && [[ -f "$OUT/codex-cli/files/stray.txt" ]]; then
  ok "files/ 直下の生ファイルも名指しする（触れない）"
else
  bad "files/ 直下の生ファイルが黙って残った"
fi

if grep -qF 'Not part of this run: grok-cli/ (staging file(s) under files/ from an earlier run' "$TMP/run-a.log" \
   && [[ -f "$OUT/grok-cli/files/security-analysis/leftover.txt" ]]; then
  ok "直下に .md が無いプラン外 CLI も files/ の残骸で名指しする（ファイルには触れない）"
else
  bad ".md を持たないプラン外 CLI の staging 残骸が黙って残る"
fi

if grep -qF 'Not part of this run: claude-code/ (1 result file(s) from an earlier run' "$TMP/run-a.log" \
   && grep -qF 'Not part of this run: claude-code/ (staging file(s) under files/ from an earlier run' "$TMP/run-a.log"; then
  ok "プラン外 CLI の直下 .md と files/ 残骸を**独立に**両方名指しする"
else
  bad "直下 .md が 1 件でもあると files/ の残骸が黙って素通りする（elif の束ね）"
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
echo "== <cli>/files 自体が symlink なら追わず、リンクとして名指しする =="
# 名指しのための読み取り走査でも、指し先が出力先の外なら他人のツリーを歩くことに
# なる（巨大ツリーの walk・権限エラーの雪崩）。リンクはリンクとして名指しして終える。
OUTSIDE_FILES="$TMP/outside-files"
mkdir -p "$OUTSIDE_FILES/outside-persp"
printf 'sentinel\n' > "$OUTSIDE_FILES/outside-persp/keep.txt"
rm -rf "$OUT/codex-cli/files"
ln -s "$OUTSIDE_FILES" "$OUT/codex-cli/files"
if run_review "$TMP/run-g2.log"; then
  ok "files/ が symlink でも実行は成功する"
else
  bad "files/ の symlink で実行が失敗した（ログ: $TMP/run-g2.log）"
fi

if grep -qF 'Not part of this run: codex-cli/files (symlink left from an earlier run — not followed' "$TMP/run-g2.log"; then
  ok "files/ 自体の symlink をリンクとして名指しする"
else
  bad "files/ の symlink が黙って素通りした"
fi

if ! grep -q 'codex-cli/files/outside-persp' "$TMP/run-g2.log" \
   && [[ -L "$OUT/codex-cli/files" && -f "$OUTSIDE_FILES/outside-persp/keep.txt" ]]; then
  ok "symlink の指し先を走査しない（中身を perspective として名指ししない・触れない）"
else
  bad "files/ の symlink を追って指し先を走査した"
fi

echo ""
echo "== implement: 絞った再実行がサマリ .md を退避し、staging 残骸を名指しする（Issue #724） =="
# quarantine は execute_tasks 共通経路で task type 非依存のはずだが、これまで実走で
# 固定していたのは review だけ。implement のサマリ .md が同じ経路で退避されること、
# そして staging（files/<perspective>/）は退避せず名指しされることを 1 本で固定する。
IMP_OUT="$REPO/.implement-results"
IMP_REPORT="$IMP_OUT/integrated-report.md"

run_implement() { # <log> [--perspective ...]
  local log="$1" rc=0
  shift
  set +e
  (
    cd "$REPO"
    run_isolated PATH="$STUB:$PATH" bash "$MULTI_AGENT" \
      --task implement --mode distributed --sequential --cli codex-cli \
      --description "stale-outputs implement fixture" --base develop --timeout 60 "$@"
  ) >"$log" 2>&1
  rc=$?
  set -e
  return "$rc"
}

if run_implement "$TMP/run-imp-a.log" --perspective refactoring --perspective documentation; then
  ok "2 観点の implement 実行が成功する"
else
  bad "2 観点の implement 実行が失敗した（ログ: $TMP/run-imp-a.log）"
  sed -n '1,40p' "$TMP/run-imp-a.log" >&2 || true
fi

if [[ -f "$IMP_OUT/codex-cli/refactoring.md" && -f "$IMP_OUT/codex-cli/documentation.md" \
      && -f "$IMP_OUT/codex-cli/files/documentation/generated.txt" ]]; then
  ok "両観点のサマリ .md と staging 生成物が揃っている（fixture の前提）"
else
  bad "implement fixture の前提が崩れている（サマリまたは staging 生成物が無い）"
fi

if run_implement "$TMP/run-imp-b.log" --perspective refactoring; then
  ok "観点を絞った implement 再実行が成功する"
else
  bad "絞った implement 再実行が失敗した（ログ: $TMP/run-imp-b.log）"
  sed -n '1,40p' "$TMP/run-imp-b.log" >&2 || true
fi

if [[ ! -e "$IMP_OUT/codex-cli/documentation.md" \
      && -f "$IMP_OUT/codex-cli/previous/documentation.md" ]] \
   && grep -qF '<!-- Multi-CLI Implement Result -->' "$IMP_OUT/codex-cli/previous/documentation.md"; then
  ok "implement のプラン外サマリ .md も previous/ へ退避される（review 以外の実走経路）"
else
  bad "implement のサマリ .md が退避されない（退避経路が review 専用に縮んでいる）"
fi

if grep -qF 'Moved 1 result(s) from a previous run' "$TMP/run-imp-b.log"; then
  ok "implement でも退避したことと件数を実行ログで名乗る"
else
  bad "implement の退避通知が実行ログに出ない"
fi

if grep -qF 'Not part of this run: codex-cli/files/documentation/ (1 staging file(s) from an earlier run' "$TMP/run-imp-b.log"; then
  ok "プランに入らなかったタスクの staging を実行ログで名指しする"
else
  bad "プラン外タスクの staging 残骸が実行ログに出ない"
fi

if [[ -f "$IMP_OUT/codex-cli/files/documentation/generated.txt" ]]; then
  ok "名指しした staging のファイルには触れない"
else
  bad "プラン外 staging のファイルを動かした（名指しだけの契約破り）"
fi

if grep -qF '> - codex-cli/files/documentation/' "$IMP_REPORT"; then
  ok "staging 残骸の名指しが implement 統合レポートにも載る"
else
  bad "implement レポート経由の消費者に staging 残骸の存在が届かない"
fi

# プラン内除外が働くのは implement のときだけ（review 側は run-a の code-review
# fixture が「名指しする」向きで固定している）。
if ! grep -q 'Not part of this run: codex-cli/files/refactoring/' "$TMP/run-imp-b.log"; then
  ok "implement ではプラン内タスクの staging を名指ししない"
else
  bad "今回の実行対象の staging まで残骸扱いした"
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
echo "== clear_planned_outputs 自体が削除前に symlink な <cli>/ を拒否する（Issue #722） =="
# E2E 経路では Phase 1 の validate_planned_result_dirs が先に中断する（上の run-h /
# run-i）ため、削除の実行点に置いた検査は関数を直接呼ばないと測れない — この
# ブロックだけが、clear_planned_outputs 内の検査を外す変異で赤化する。
# `main "$@"` の行だけを除いた写しを source する。$0 には実スクリプトのパスを渡し、
# SCRIPT_DIR（= adapter-common の解決）を本物に向ける。
FUNCS="$TMP/multi-agent-functions.sh"
if grep -q '^main "\$@"$' "$MULTI_AGENT"; then
  ok "写しの前提（末尾の main 呼び出し行）が実物に存在する"
else
  bad "multi-agent.sh の main 呼び出し行が想定の形ではない（写しに main 実行が残る）"
fi
sed '/^main "\$@"$/d' "$MULTI_AGENT" > "$FUNCS"

run_clear_planned_outputs() { # <output-dir> — 物理パスで渡すこと
  (
    cd "$REPO"
    run_isolated bash -c '
      set -euo pipefail
      source "$1"
      OUTPUT_DIR="$2"
      EXECUTION_PLAN="codex-cli:code-review"
      TASK_TYPE=review
      PRESERVE_PREVIOUS_CRITICAL_REPORT=false
      clear_planned_outputs
    ' "$MULTI_AGENT" "$FUNCS" "$1"
  )
}

UNIT_OUT="$TMP/unit-out"
UNIT_EXT="$TMP/unit-external"
mkdir -p "$UNIT_OUT" "$UNIT_EXT"
UNIT_OUT="$(cd "$UNIT_OUT" && pwd -P)"
UNIT_EXT="$(cd "$UNIT_EXT" && pwd -P)"
printf 'EXTERNAL-PLANNED-KEEP\n' > "$UNIT_EXT/code-review.md"
ln -s "$UNIT_EXT" "$UNIT_OUT/codex-cli"

set +e
run_clear_planned_outputs "$UNIT_OUT" >"$TMP/unit-symlink.log" 2>&1
UNIT_RC=$?
set -e
if [[ "$UNIT_RC" -ne 0 ]]; then
  ok "外を指す symlink な <cli>/ で clear_planned_outputs が非 0 で落ちる"
else
  bad "symlink な <cli>/ でも clear_planned_outputs が成功した（外部を消しに行く）"
fi

if [[ -f "$UNIT_EXT/code-review.md" ]] \
   && grep -qF 'EXTERNAL-PLANNED-KEEP' "$UNIT_EXT/code-review.md"; then
  ok "出力ディレクトリ外の同名ファイルを消さない"
else
  bad "rm -f が symlink を辿って出力ディレクトリ外のファイルを消した"
fi

if grep -qF 'is a symlink to another location — refusing to touch it' "$TMP/unit-symlink.log"; then
  ok "退避処理と同じトーンで fail-loud する（resolve_expected_dir の診断）"
else
  bad "中断の診断が出ない（黙って失敗している）"
  sed -n '1,10p' "$TMP/unit-symlink.log" >&2 || true
fi

# 通常構成（symlink なし）: 今回のプラン対象だけを消し、同居ファイルには触れない。
rm -f "$UNIT_OUT/codex-cli"
mkdir -p "$UNIT_OUT/codex-cli"
printf 'planned\n' > "$UNIT_OUT/codex-cli/code-review.md"
printf 'unplanned\n' > "$UNIT_OUT/codex-cli/test-analysis.md"
if run_clear_planned_outputs "$UNIT_OUT" >"$TMP/unit-normal.log" 2>&1; then
  ok "通常構成では clear_planned_outputs が成功する"
else
  bad "通常構成で clear_planned_outputs が失敗した（symlink でない実体を拒否している）"
  sed -n '1,10p' "$TMP/unit-normal.log" >&2 || true
fi

if [[ ! -e "$UNIT_OUT/codex-cli/code-review.md" ]] \
   && [[ -f "$UNIT_OUT/codex-cli/test-analysis.md" ]]; then
  ok "今回のプラン対象だけを消し、プラン外の同居ファイルには触れない"
else
  bad "削除範囲が今回のプラン対象と一致しない"
fi

# dangling symlink（指し先が無いリンク）: [[ -d ]] が偽になり resolve を通らないが、
# 素通しすると rm -f が「何も消せないまま rc=0」で成功に見える。削除の実行点でも
# validate_result_dir_paths と同じ「not a directory」の fail-loud に揃える。
rm -rf "$UNIT_OUT/codex-cli"
ln -s "$UNIT_OUT/no-such-target" "$UNIT_OUT/codex-cli"
set +e
run_clear_planned_outputs "$UNIT_OUT" >"$TMP/unit-dangling.log" 2>&1
UNIT_RC=$?
set -e
if [[ "$UNIT_RC" -ne 0 ]]; then
  ok "dangling symlink な <cli>/ で clear_planned_outputs が非 0 で落ちる"
else
  bad "dangling symlink な <cli>/ を素通しした（rc=0 の空振り削除）"
fi
if grep -qF 'exists but is not a directory' "$TMP/unit-dangling.log"; then
  ok "validate 側と同じ「not a directory」の診断で fail-loud する"
else
  bad "dangling symlink の中断診断が出ない"
  sed -n '1,10p' "$TMP/unit-dangling.log" >&2 || true
fi

echo ""
echo "== staging の走査失敗は unknown として名指しし、実行は落とさない（Issue #724） =="
# E2E では find を壊せない（orchestrator の他経路も find に依存しうる）ため、
# clear_planned_outputs と同じ FUNCS 直呼びで、失敗する find を PATH 先頭に置いて測る。
FAILFIND="$TMP/failfind"
mkdir -p "$FAILFIND"
cat > "$FAILFIND/find" <<'SH'
#!/usr/bin/env bash
echo "find: injected failure" >&2
exit 1
SH
chmod +x "$FAILFIND/find"

STG_OUT="$TMP/staging-unit-out"
mkdir -p "$STG_OUT/codex-cli/files/keep" "$STG_OUT/claude-code/files/leftover-persp"
printf 'payload\n' > "$STG_OUT/codex-cli/files/keep/generated.txt"
printf 'payload\n' > "$STG_OUT/claude-code/files/leftover-persp/leftover.txt"
STG_OUT="$(cd "$STG_OUT" && pwd -P)"

run_staging_unit() { # <PATH に前置するディレクトリ（"" = なし）> <staging|dirs>
  (
    cd "$REPO"
    run_isolated FF_TEST_PATH_PREFIX="$1" FF_TEST_MODE="$2" bash -c '
      set -euo pipefail
      if [[ -n "${FF_TEST_PATH_PREFIX:-}" ]]; then PATH="${FF_TEST_PATH_PREFIX}:${PATH}"; fi
      source "$1"
      OUTPUT_DIR="$2"
      FULL_EXECUTION_PLAN="codex-cli:code-review"
      TASK_TYPE=review
      UNPLANNED_RESULT_NOTES=""
      if [[ "$FF_TEST_MODE" == "staging" ]]; then
        report_unplanned_staging_dirs codex-cli "${OUTPUT_DIR}/codex-cli"
      else
        report_unplanned_result_dirs
      fi
    ' "$MULTI_AGENT" "$FUNCS" "$STG_OUT"
  )
}

# 正常経路: 名指しは stderr へ、stdout は汚さない（レポート生成等の stdout 消費と
# 混ざらない契約）。
if run_staging_unit "" staging >"$TMP/unit-stg-normal.out" 2>"$TMP/unit-stg-normal.err"; then
  ok "staging 名指しの直呼びが成功する（正常経路）"
else
  bad "staging 名指しの直呼びが失敗した"
  sed -n '1,10p' "$TMP/unit-stg-normal.err" >&2 || true
fi
if grep -qF 'Not part of this run: codex-cli/files/keep/ (1 staging file(s)' "$TMP/unit-stg-normal.err" \
   && [[ ! -s "$TMP/unit-stg-normal.out" ]]; then
  ok "名指しは stderr に出て、stdout を汚さない"
else
  bad "名指しの出力チャネルが契約（stderr）と違う"
fi

# find 失敗注入: rc=0 のまま unknown の別文言で名指しし、原因も握り潰さない。
set +e
run_staging_unit "$FAILFIND" staging >"$TMP/unit-stg-fail.out" 2>"$TMP/unit-stg-fail.err"
UNIT_RC=$?
set -e
if [[ "$UNIT_RC" -eq 0 ]]; then
  ok "find が失敗しても報告経路は rc=0（set -e で実行本体を落とさない）"
else
  bad "走査失敗が報告経路の rc に化けた（実行全体が落ちる）"
  sed -n '1,10p' "$TMP/unit-stg-fail.err" >&2 || true
fi
if grep -qF 'Not part of this run: codex-cli/files/keep/ (could not scan this staging dir' "$TMP/unit-stg-fail.err"; then
  ok "走査できなかったことを 0 件でも断定でもない別文言で名指しする"
else
  bad "unknown が黙殺されたか、「N 件ある」の断定に潰れた"
fi
if ! grep -qF '1 staging file(s)' "$TMP/unit-stg-fail.err"; then
  ok "走査失敗時に件数を断定しない"
else
  bad "観測していない件数を観測したことにした"
fi
if grep -qF 'find: injected failure' "$TMP/unit-stg-fail.err"; then
  ok "走査失敗の原因（find の stderr）を /dev/null に捨てない"
else
  bad "unknown の原因がどこにも残らない"
fi
if [[ -f "$STG_OUT/codex-cli/files/keep/generated.txt" ]]; then
  ok "走査失敗時もファイルには触れない"
else
  bad "走査失敗の経路でファイルが動いた"
fi

# fall-back（プラン外 CLI の files/）も unknown を「有り」へ潰さない。
set +e
run_staging_unit "$FAILFIND" dirs >"$TMP/unit-dirs-fail.out" 2>"$TMP/unit-dirs-fail.err"
UNIT_RC=$?
set -e
if [[ "$UNIT_RC" -eq 0 ]] \
   && grep -qF 'Not part of this run: claude-code/ (could not scan files/' "$TMP/unit-dirs-fail.err" \
   && ! grep -qF 'claude-code/ (staging file(s) under files/' "$TMP/unit-dirs-fail.err"; then
  ok "プラン外 CLI の fall-back も走査失敗を rc=0 のまま別文言で名指しする"
else
  bad "fall-back 側で unknown が rc 化・黙殺・断定のいずれかに化けた"
  sed -n '1,10p' "$TMP/unit-dirs-fail.err" >&2 || true
fi

echo ""
echo "== プラン外 CLI の名指しは DISCARDED の内訳まで出す =="
# 前回走が破棄された結果は 1 行目に `> DISCARDED` バナーを持つ。「今回の結果ではない」
# だけだと、読み手は残骸を完成した前回のレビューとして扱ってしまう。
DISC_OUT="$TMP/discarded-unit-out"
mkdir -p "$DISC_OUT/claude-code"
printf '> DISCARDED — the repository changed while this run was in flight.\n\n## Findings\n' \
  > "$DISC_OUT/claude-code/code-review.md"
printf '## Findings\n- ok\n' > "$DISC_OUT/claude-code/test-analysis.md"
# symlink は count には入るが head しない（FIFO で固まらない・出力先の外を辿らない）
ln -s "$DISC_OUT/claude-code/code-review.md" "$DISC_OUT/claude-code/linked.md"
DISC_OUT="$(cd "$DISC_OUT" && pwd -P)"

run_dirs_unit() { # <OUTPUT_DIR>
  (
    cd "$REPO"
    run_isolated bash -c '
      set -euo pipefail
      source "$1"
      OUTPUT_DIR="$2"
      FULL_EXECUTION_PLAN="codex-cli:code-review"
      TASK_TYPE=review
      UNPLANNED_RESULT_NOTES=""
      report_unplanned_result_dirs
    ' "$MULTI_AGENT" "$FUNCS" "$1"
  )
}

if run_dirs_unit "$DISC_OUT" >"$TMP/unit-disc.out" 2>"$TMP/unit-disc.err"; then
  ok "DISCARDED 内訳つきの名指しが rc=0 で通る"
else
  bad "DISCARDED 内訳つきの名指しが失敗した"
  sed -n '1,10p' "$TMP/unit-disc.err" >&2 || true
fi
if grep -qF 'claude-code/ (3 result file(s) from an earlier run, 1 of them marked DISCARDED by that run' "$TMP/unit-disc.err"; then
  ok "件数と DISCARDED 件数の内訳を出す（symlink は数えるが読まない）"
else
  bad "DISCARDED の内訳が出ない（件数が 0 に潰れたか、symlink を辿って数えた）"
  sed -n '1,10p' "$TMP/unit-disc.err" >&2 || true
fi
rm -f "$DISC_OUT/claude-code/code-review.md" "$DISC_OUT/claude-code/linked.md"
if run_dirs_unit "$DISC_OUT" 2>"$TMP/unit-disc2.err" >/dev/null \
   && grep -qF 'claude-code/ (1 result file(s) from an earlier run — left untouched' "$TMP/unit-disc2.err"; then
  ok "DISCARDED が 0 件なら内訳を足さない（従来文言のまま）"
else
  bad "DISCARDED 0 件のときの文言が変わった"
  sed -n '1,10p' "$TMP/unit-disc2.err" >&2 || true
fi

echo ""
echo "== 結果 =="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
FF_REACHED_END=1
[[ "$FAIL" -eq 0 ]]
