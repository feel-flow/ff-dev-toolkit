#!/usr/bin/env bash
#
# multi-agent --resume の入力 identity・成功結果キャッシュ・全観点レポート契約
# （Issue #586）。実 CLI は使わず、逐次実行する codex stub の起動回数で再利用を測る。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

# shellcheck source=../lib/adapter-env-isolation.sh
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"

if _ff_mktemp_out="$(mktemp -d 2>&1)"; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できない環境（read-only）のためスキップ"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  exit 0
fi

FF_REACHED_END=0
cleanup() {
  rc=$?
  rm -rf "$TMP"
  if [[ "$rc" -eq 0 && "$FF_REACHED_END" -ne 1 ]]; then
    echo "✗ multi-agent-resume: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$rc"
}
trap cleanup EXIT

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# perspective 定義変更を実作業ツリーへ入れず検査するため、配布 scripts だけを隔離コピー。
FIXTURE_PLUGIN="$TMP/plugin"
mkdir -p "$FIXTURE_PLUGIN"
cp -R "$PLUGIN_ROOT/scripts" "$FIXTURE_PLUGIN/scripts"
MULTI_AGENT="$FIXTURE_PLUGIN/scripts/multi-agent.sh"
build_isolate_env "MULTI_AGENT_CONFIG MULTI_AGENT_CODEX_PROFILE" \
  "$MULTI_AGENT" "$FIXTURE_PLUGIN"/scripts/adapters/*.sh

REPO="$TMP/repo"
STUB="$TMP/bin"
COUNT_FILE="$TMP/invocations"
FAIL_ON_EIGHTH="$TMP/fail-on-eighth"
CONFIG_FILE="$TMP/agent-config.yaml"
mkdir -p "$REPO" "$STUB"
printf '0\n' > "$COUNT_FILE"
printf 'armed\n' > "$FAIL_ON_EIGHTH"
cat > "$CONFIG_FILE" <<'YAML'
version: "2.0"
parallel: false
tasks:
  review:
    mode: distributed
    timeout: 60
YAML

git init -q "$REPO"
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "multi-agent-resume-test"
git -C "$REPO" config commit.gpgsign false
git -C "$REPO" switch -q -c develop
printf 'base\n' > "$REPO/app.txt"
git -C "$REPO" add app.txt
git -C "$REPO" commit -qm "init"
git -C "$REPO" switch -q -c feature/resume
printf 'base\nreview change\n' > "$REPO/app.txt"
git -C "$REPO" add app.txt
git -C "$REPO" commit -qm "review change"

cat > "$STUB/codex" <<SH
#!/usr/bin/env bash
set -euo pipefail
n="\$(cat "$COUNT_FILE")"
n=\$((n + 1))
printf '%s\n' "\$n" > "$COUNT_FILE"
if [[ -f "$FAIL_ON_EIGHTH" && "\$n" -eq 8 ]]; then
  rm -f "$FAIL_ON_EIGHTH"
  echo "simulated timeout/failure" >&2
  exit 1
fi
printf '%s\n' \
  "## Stub Review" \
  "" \
  "invocation=\$n" \
  "" \
  "### Summary" \
  "- Critical: 0"
SH
chmod +x "$STUB/codex"

PERSPECTIVES=(
  code-review
  error-handler-hunt
  type-design-analysis
  code-simplification
  test-analysis
  security-analysis
  comment-analysis
  comprehensive-review
)

run_review() { # <log> <timeout> <resume:true|false> [perspective count] [base]
  local log="$1" timeout="$2" resume="$3" perspective_count="${4:-8}" base="${5:-develop}"
  local args=(
    --task review --mode distributed --sequential
    --cli codex-cli --base "$base" --config "$CONFIG_FILE" --timeout "$timeout"
  )
  [[ "$resume" == "true" ]] && args+=(--resume)
  local i
  for ((i = 0; i < perspective_count; i++)); do
    args+=(--perspective "${PERSPECTIVES[$i]}")
  done
  (
    cd "$REPO"
    run_isolated PATH="$STUB:$PATH" bash "$MULTI_AGENT" "${args[@]}"
  ) >"$log" 2>&1
}

count_invocations() { tr -d '[:space:]' < "$COUNT_FILE"; }
REPORT="$REPO/.review-results/integrated-report.md"

echo "== 7成功・1失敗から未完了1観点だけを再実行 =="
if run_review "$TMP/first.log" 60 false; then
  bad "初回の8観点目失敗が exit 0 になった"
else
  ok "初回は7成功・1失敗として非0終了"
fi
if [[ "$(count_invocations)" -eq 8 ]]; then
  ok "初回は8観点すべてを起動"
else
  bad "初回の起動数が8ではない: $(count_invocations)"
fi
if [[ "$(find "$REPO/.review-results/.resume-cache" -name '*.md' | wc -l | tr -d ' ')" -eq 7 ]]; then
  ok "成功した7観点だけをキャッシュ"
else
  bad "成功キャッシュ数が7ではない"
fi

# timeout は identity 外。失敗後に延長しても成功7観点を再利用できる。
if run_review "$TMP/resume.log" 120 true; then
  ok "timeout延長付きresumeが成功"
else
  bad "timeout延長付きresumeが失敗"
fi
if [[ "$(count_invocations)" -eq 9 ]]; then
  ok "resumeは未完了1観点だけを起動"
else
  bad "resume後の累計起動数が9ではない: $(count_invocations)"
fi
if [[ "$(grep -c '^\*\*Result source:\*\* reused$' "$REPORT")" -eq 7 \
      && "$(grep -c '^\*\*Result source:\*\* executed$' "$REPORT")" -eq 1 \
      && "$(grep -c '^## codex-cli — ' "$REPORT")" -eq 8 ]]; then
  ok "統合レポートは全8観点とreused/executed由来を記録"
else
  bad "統合レポートの全観点または由来表示が不一致"
fi
if ! grep -qF '<!-- CRITICAL_BLOCK -->' "$REPORT"; then
  ok "Critical 0件では既存marker契約を維持"
else
  bad "Critical 0件なのにCRITICAL_BLOCKが出た"
fi

echo ""
echo "== 欠落・破損キャッシュはfail closedで1観点だけ再実行 =="
CORRUPT_CACHE="$(find "$REPO/.review-results/.resume-cache" -path '*/codex-cli/code-review.md' | head -1)"
rm -f "${CORRUPT_CACHE}.hash"
if run_review "$TMP/missing-hash.log" 120 true \
  && [[ "$(count_invocations)" -eq 10 ]] \
  && [[ "$(grep -c '^\*\*Result source:\*\* reused$' "$REPORT")" -eq 7 ]] \
  && [[ "$(grep -c '^\*\*Result source:\*\* executed$' "$REPORT")" -eq 1 ]]; then
  ok "hash欠落を再実行して回復"
else
  bad "hash欠落時の起動数または由来表示が不一致"
fi

rm -f "$CORRUPT_CACHE"
if run_review "$TMP/missing-result.log" 120 true \
  && [[ "$(count_invocations)" -eq 11 ]] \
  && [[ "$(grep -c '^\*\*Result source:\*\* reused$' "$REPORT")" -eq 7 ]] \
  && [[ "$(grep -c '^\*\*Result source:\*\* executed$' "$REPORT")" -eq 1 ]]; then
  ok "結果本体の欠落を再実行して回復"
else
  bad "結果本体の欠落時の起動数または由来表示が不一致"
fi

printf '\ncorrupt\n' >> "$CORRUPT_CACHE"
if run_review "$TMP/corrupt.log" 120 true; then
  ok "破損キャッシュを再実行して回復"
else
  bad "破損キャッシュの回復実行が失敗"
fi
if [[ "$(count_invocations)" -eq 12 \
      && "$(grep -c '^\*\*Result source:\*\* reused$' "$REPORT")" -eq 7 \
      && "$(grep -c '^\*\*Result source:\*\* executed$' "$REPORT")" -eq 1 ]]; then
  ok "破損した1観点だけをexecutedへ倒す"
else
  bad "破損時の起動数または由来表示が不一致"
fi

echo ""
echo "== identity変更では古い結果を再利用しない =="
printf 'base\nreview change\nhead change\n' > "$REPO/app.txt"
git -C "$REPO" add app.txt
git -C "$REPO" commit -qm "head change"
if run_review "$TMP/head-change.log" 120 true \
  && [[ "$(count_invocations)" -eq 20 ]] \
  && [[ "$(grep -c '^\*\*Result source:\*\* executed$' "$REPORT")" -eq 8 ]]; then
  ok "HEAD変更で8観点すべてを新規実行"
else
  bad "HEAD変更時に古い結果を再利用した"
fi

git -C "$REPO" branch alternate-base develop
if run_review "$TMP/base-change.log" 120 true 8 alternate-base \
  && [[ "$(count_invocations)" -eq 28 ]] \
  && [[ "$(grep -c '^\*\*Result source:\*\* executed$' "$REPORT")" -eq 8 ]]; then
  ok "base変更で8観点すべてを新規実行"
else
  bad "base変更時に古い結果を再利用した"
fi

printf '\n# identity change\n' >> "$CONFIG_FILE"
if run_review "$TMP/config-change.log" 120 true \
  && [[ "$(count_invocations)" -eq 36 ]] \
  && [[ "$(grep -c '^\*\*Result source:\*\* executed$' "$REPORT")" -eq 8 ]]; then
  ok "設定変更で8観点すべてを新規実行"
else
  bad "設定変更時に古い結果を再利用した"
fi

printf '\n<!-- identity change -->\n' >> "$FIXTURE_PLUGIN/scripts/perspectives/review/code-review.md"
if run_review "$TMP/perspective-definition-change.log" 120 true \
  && [[ "$(count_invocations)" -eq 44 ]] \
  && [[ "$(grep -c '^\*\*Result source:\*\* executed$' "$REPORT")" -eq 8 ]]; then
  ok "perspective定義変更で8観点すべてを新規実行"
else
  bad "perspective定義変更時に古い結果を再利用した"
fi

printf '\nworktree review input change\n' >> "$REPO/app.txt"
if run_review "$TMP/review-input-change.log" 120 true \
  && [[ "$(count_invocations)" -eq 52 ]] \
  && [[ "$(grep -c '^\*\*Result source:\*\* executed$' "$REPORT")" -eq 8 ]]; then
  ok "review入力変更で8観点すべてを新規実行"
else
  bad "review入力変更時に古い結果を再利用した"
fi

if run_review "$TMP/perspective-set-change.log" 120 true 7 \
  && [[ "$(count_invocations)" -eq 59 ]] \
  && [[ "$(grep -c '^## codex-cli — ' "$REPORT")" -eq 7 ]] \
  && [[ "$(grep -c '^\*\*Result source:\*\* executed$' "$REPORT")" -eq 7 ]]; then
  ok "perspective集合変更で新しい7観点計画をすべて実行"
else
  bad "perspective集合変更時に古い集合の結果を再利用した"
fi

echo ""
echo "== 結果 =="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
FF_REACHED_END=1
[[ "$FAIL" -eq 0 ]]
