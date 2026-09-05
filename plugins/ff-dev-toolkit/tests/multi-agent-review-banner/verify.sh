#!/usr/bin/env bash
#
# review タスク起動時の「完了まで worktree を触らない」バナーの回帰テスト。
#
# multi-agent.sh --task review は、実行中に worktree が動くと**終わってから**結果を
# 全破棄する（verify_repo_unchanged）。検出そのものは正しいが、事後検出のため
# 数分のレビューが丸ごと無駄になる再発があった。この suite が固定するのは、破棄
# ロジックではなく**着手前の注意喚起**:
#   - review タスクが実行に入る前に、バナーを 1 回だけ出す
#   - 並列（既定）では待機メッセージ（Waiting for）の直前行
#   - --sequential でも同じく出る（破棄ロジックは経路に関係なく走るため）
#   - バナーは stderr へ出て stdout には出ない（stdout は結果を受け取る側のもの）
#   - バナーに起動時 HEAD の short-sha を含む
#   - explore タスクでは出さない（review 限定）
#
# 実 CLI は 1 つも起動しない（stub で覆う）。書き込み不可の環境では skip。
#
# run-all-required: no — 一時領域が無い環境の skip を許容する（一時領域依存 suite の必須判断で名簿へ載せなかった側。必須へ昇格するなら REQUIRED_SUITES へ移す）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MULTI_AGENT="$PLUGIN_ROOT/scripts/multi-agent.sh"

[ -f "$MULTI_AGENT" ] || { echo "✗ multi-agent.sh が見つかりません" >&2; exit 1; }

# 実行環境の MULTI_AGENT_* からの分離（共有ライブラリの既定作法）。
# shellcheck source=../lib/adapter-env-isolation.sh
. "$PLUGIN_ROOT/tests/lib/adapter-env-isolation.sh"
build_isolate_env "MULTI_AGENT_CONFIG" \
  "$MULTI_AGENT" "$PLUGIN_ROOT"/scripts/adapters/*.sh

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# バナー本文の固定パターン（絵文字 + 主要語）。全文一致にしない — 文言の細部が
# 変わっても suite が過剰に赤くならないようにしつつ、意味は固定する。
BANNER_PATTERN='⚠️.*worktree.*HEAD: '

# 行数を数える小道具。grep は不一致で rc=1 を返すので set -e 下では素で使えない。
count_matches() { # $1: pattern / $2: file
  /usr/bin/grep -cE "$1" "$2" 2>/dev/null || true
}
first_line_of() { # $1: pattern / $2: file  → 行番号 or 空
  /usr/bin/grep -nE "$1" "$2" 2>/dev/null | head -1 | cut -d: -f1
}

if _ff_mktemp_out="$(mktemp -d 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できない環境のためスキップ"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  exit 0
fi
trap 'cd /; rm -rf "$TMP"' EXIT

# ── 被検体リポジトリ ──
REPO="$TMP/repo"
git init -q "$REPO"
cd "$REPO"
git config user.email "test@example.com"
git config user.name "multi-agent-review-banner-test"
git config commit.gpgsign false
git switch -q -c develop
mkdir -p src
echo base > src/app.txt
git add src/app.txt
git commit -qm "init"
git switch -q -c feature/x
printf 'base\nchange\n' > src/app.txt
git add src/app.txt
git commit -qm "change"

HEAD_SHORT="$(git rev-parse --short HEAD)"

STUB="$TMP/bin"
mkdir -p "$STUB"

# codex stub。プロンプトは stdin 経由で届くので読み捨てる。worktree・HEAD は一切
# 動かさない — この suite が見るのはバナーの有無・順序・ストリーム・内容だけで、
# 破棄ロジックの検査は multi-agent-revision-guard の担当。
cat > "$STUB/codex" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
echo "## Findings"
echo "- Suggestion: stub result"
SH
chmod +x "$STUB/codex"

# stdout / stderr は**分けて**捕捉する。バナーの出し先（stderr）が契約の一部で、
# 2>&1 で合流させるとその契約を検証できない。
run_review() { # $1: 被検体スクリプト / $2: ログの接頭辞 / $3...: 追加引数
  local script="$1" prefix="$2"; shift 2
  set +e
  run_isolated PATH="$STUB:/usr/bin:/bin" bash "$script" \
    --task review --cli codex-cli --perspective code-review \
    --base develop --timeout 60 "$@" \
    >"$TMP/${prefix}.out" 2>"$TMP/${prefix}.err"
  local rc=$?
  set -e
  return $rc
}

run_explore() {
  set +e
  run_isolated PATH="$STUB:/usr/bin:/bin" bash "$1" \
    --task explore --cli codex-cli --perspective dependency-mapping \
    --description "stub exploration" --output-dir "$REPO/.explore-results" \
    --timeout 60 >"$TMP/explore.out" 2>"$TMP/explore.err"
  local rc=$?
  set -e
  return $rc
}

# ══════════════════════════════════════════════════════════════
echo "== review 起動時のバナー（並列・既定） =="
# ══════════════════════════════════════════════════════════════
rm -rf "$REPO/.review-results"
if run_review "$MULTI_AGENT" "review"; then
  ok "review の正常系が誤発火せず完走する"
else
  bad "review の正常系が非 0 終了した"
  tail -15 "$TMP/review.err" | sed 's/^/    | /' >&2
fi

BANNER_COUNT="$(count_matches "$BANNER_PATTERN" "$TMP/review.err")"
if [[ "$BANNER_COUNT" == "1" ]]; then
  ok "バナーが stderr へちょうど 1 回だけ出る"
else
  bad "stderr のバナー出現回数が 1 でない（${BANNER_COUNT} 回）"
  tail -15 "$TMP/review.err" | sed 's/^/    | /' >&2
fi

# ストリームの pin: 進行表示は隣の "⏳ Waiting for" を含めすべて stderr で、stdout は
# 結果を受け取る側が使う。バナーが stdout へ漏れると、結果をパイプで受けている
# 利用者の出力へ注意喚起が混ざる。
STDOUT_BANNER_COUNT="$(count_matches "$BANNER_PATTERN" "$TMP/review.out")"
if [[ "$STDOUT_BANNER_COUNT" == "0" ]]; then
  ok "バナーは stdout には出ない（stderr 専用）"
else
  bad "バナーが stdout へ漏れている（${STDOUT_BANNER_COUNT} 回）"
  head -15 "$TMP/review.out" | sed 's/^/    | /' >&2
fi

# 「直前」を前方一致ではなく**同一ストリーム上の隣接行**として固定する。行番号の差が
# 1 でなければ、間に別の出力が挟まった（＝バナーが待機直前ではなくなった）ということ。
BANNER_LINE="$(first_line_of "$BANNER_PATTERN" "$TMP/review.err")"
WAITING_LINE="$(first_line_of 'Waiting for' "$TMP/review.err")"
if [[ -n "$BANNER_LINE" && -n "$WAITING_LINE" && $((WAITING_LINE - BANNER_LINE)) -eq 1 ]]; then
  ok "バナーは待機メッセージ（Waiting for）の直前行に出る"
else
  bad "バナーが待機メッセージの直前行でない（banner=${BANNER_LINE:-なし}, waiting=${WAITING_LINE:-なし}）"
  tail -15 "$TMP/review.err" | sed 's/^/    | /' >&2
fi

if /usr/bin/grep -F "HEAD: ${HEAD_SHORT}" "$TMP/review.err" >/dev/null 2>&1; then
  ok "バナーに起動時 HEAD の short-sha (${HEAD_SHORT}) が含まれる"
else
  bad "バナーに起動時 HEAD の short-sha が含まれない"
  tail -15 "$TMP/review.err" | sed 's/^/    | /' >&2
fi

# 破棄ロジック・終了コードには触れていないことの非回帰（最小限の確認）。
if [[ -f "$REPO/.review-results/integrated-report.md" ]]; then
  ok "正常系: 統合レポートは従来どおり生成される（破棄ロジックへ影響していない）"
else
  bad "正常系で統合レポートが生成されない（無関係のはずの破棄ロジックが壊れた疑い）"
fi

# ══════════════════════════════════════════════════════════════
echo "== --sequential でもバナーが出る =="
# ══════════════════════════════════════════════════════════════
# 破棄（verify_repo_unchanged）は PARALLEL に関係なく走るので、逐次経路だけバナーが
# 出ないと「注意されないまま全破棄される」経路が残る。
rm -rf "$REPO/.review-results"
if run_review "$MULTI_AGENT" "review-seq" --sequential; then
  ok "--sequential の正常系が誤発火せず完走する"
else
  bad "--sequential の正常系が非 0 終了した"
  tail -15 "$TMP/review-seq.err" | sed 's/^/    | /' >&2
fi

SEQ_BANNER_COUNT="$(count_matches "$BANNER_PATTERN" "$TMP/review-seq.err")"
if [[ "$SEQ_BANNER_COUNT" == "1" ]]; then
  ok "--sequential でもバナーが stderr へちょうど 1 回だけ出る"
else
  bad "--sequential の stderr でバナー出現回数が 1 でない（${SEQ_BANNER_COUNT} 回）"
  tail -20 "$TMP/review-seq.err" | sed 's/^/    | /' >&2
fi

SEQ_STDOUT_BANNER_COUNT="$(count_matches "$BANNER_PATTERN" "$TMP/review-seq.out")"
if [[ "$SEQ_STDOUT_BANNER_COUNT" == "0" ]]; then
  ok "--sequential でもバナーは stdout には出ない"
else
  bad "--sequential でバナーが stdout へ漏れている（${SEQ_STDOUT_BANNER_COUNT} 回）"
fi

# 逐次経路に待機メッセージは無いので、「タスク実行の開始表示（▶）より前」で固定する。
SEQ_BANNER_LINE="$(first_line_of "$BANNER_PATTERN" "$TMP/review-seq.err")"
SEQ_TASK_LINE="$(first_line_of '^▶ ' "$TMP/review-seq.err")"
if [[ -n "$SEQ_BANNER_LINE" && -n "$SEQ_TASK_LINE" && "$SEQ_BANNER_LINE" -lt "$SEQ_TASK_LINE" ]]; then
  ok "--sequential ではタスク実行（▶）の開始より前にバナーが出る"
else
  bad "--sequential でバナーがタスク実行開始より前に出ていない（banner=${SEQ_BANNER_LINE:-なし}, task=${SEQ_TASK_LINE:-なし}）"
  tail -20 "$TMP/review-seq.err" | sed 's/^/    | /' >&2
fi

if /usr/bin/grep -F "HEAD: ${HEAD_SHORT}" "$TMP/review-seq.err" >/dev/null 2>&1; then
  ok "--sequential のバナーにも起動時 HEAD の short-sha が含まれる"
else
  bad "--sequential のバナーに起動時 HEAD の short-sha が含まれない"
  tail -20 "$TMP/review-seq.err" | sed 's/^/    | /' >&2
fi

# ══════════════════════════════════════════════════════════════
echo "== explore タスクではバナーを出さない =="
# ══════════════════════════════════════════════════════════════
rm -rf "$REPO/.explore-results"
if run_explore "$MULTI_AGENT"; then
  ok "explore の正常系が誤発火せず完走する"
else
  bad "explore の正常系が非 0 終了した"
  tail -15 "$TMP/explore.err" | sed 's/^/    | /' >&2
fi

EXPLORE_BANNER_COUNT="$(count_matches "$BANNER_PATTERN" "$TMP/explore.err")"
if [[ "$EXPLORE_BANNER_COUNT" == "0" ]]; then
  ok "explore 実行ではバナーを出さない"
else
  bad "explore 実行でもバナーが出た（review 限定のはずが漏れている / ${EXPLORE_BANNER_COUNT} 回）"
  tail -15 "$TMP/explore.err" | sed 's/^/    | /' >&2
fi

# ══════════════════════════════════════════════════════════════
echo "== ミューテーション: バナー行を削るとこの suite が検出すること =="
# ══════════════════════════════════════════════════════════════
# 「検出ロジックを一時的に外して赤になることを実測する」の対象は、ここではバナーを
# 出す echo 行そのもの。行を削除すると構文が崩れる箇所があるため、no-op （`:`）へ
# 置換して挙動だけを変える。
MUTANT_ROOT="$TMP/mutant"
mkdir -p "$MUTANT_ROOT/scripts"
cp -R "$PLUGIN_ROOT/scripts/." "$MUTANT_ROOT/scripts/"
MUTANT_MULTI_AGENT="$MUTANT_ROOT/scripts/multi-agent.sh"

perl -pi -e 's/^(\s*)echo "⚠️.*HEAD: \$\{banner_head\}）" >&2$/$1:/' "$MUTANT_MULTI_AGENT"

if cmp -s "$MUTANT_MULTI_AGENT" "$PLUGIN_ROOT/scripts/multi-agent.sh"; then
  bad "ミューテーションを適用できなかった（被検体と同一。検査が無意味）"
else
  rm -rf "$REPO/.review-results"
  run_review "$MUTANT_MULTI_AGENT" "mutant-review" || true
  MUTANT_BANNER_COUNT="$(count_matches "$BANNER_PATTERN" "$TMP/mutant-review.err")"
  if [[ "$MUTANT_BANNER_COUNT" == "0" ]]; then
    ok "バナー行を削ると本 suite の検査が赤になる（検出ロジックが効いている証拠）"
  else
    bad "バナー行を削っても検出をすり抜けた（この suite が空振りしている疑い / ${MUTANT_BANNER_COUNT} 回）"
    tail -15 "$TMP/mutant-review.err" | sed 's/^/    | /' >&2
  fi
fi

# ══════════════════════════════════════════════════════════════
echo ""
echo "── 結果: ${PASS} passed, ${FAIL} failed ──"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
