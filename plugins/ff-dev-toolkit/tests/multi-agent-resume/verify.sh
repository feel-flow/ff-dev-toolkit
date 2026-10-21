#!/usr/bin/env bash
#
# multi-agent --resume の入力 identity・成功結果キャッシュ・全観点レポート契約
# （Issue #586）。実 CLI は使わず、逐次実行する codex stub の起動回数で再利用を測る。
#
# run-all-required: no — 一時領域が無い環境の skip を許容する（一時領域依存 suite の必須判断で名簿へ載せなかった側。必須へ昇格するなら REQUIRED_SUITES へ移す）
#
# 空振り検出: compute_resume_identity から構成ファイル（scripts/lib/multi-agent-*.sh）の hash を外すと「構成ファイルの変更時に古い結果を再利用した」が赤（2026-10-20 実測）。直前の「入力が同じなら8観点すべてを再利用」が再利用の起きる入力であることを毎回測るので、この赤は identity の欠落からだけ来る。
# 空振り検出: compute_resume_identity から adapter-common の構成ファイル（ADAPTER_COMMON_PARTS）の hash ループだけを外すと、「adapter-common の構成ファイルの変更時に古い結果を再利用した（resume identity が入口しか見ていない）」の 1 件だけが赤になる（2026-10-21 実測。成功 22。直前の「入力が同じなら8観点すべてを再利用」は緑のまま）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
# fixture リポジトリの identity を呼び出し元へ漏らさない（Issue #1348 / #1368）
# fixture リポジトリの identity を呼び出し元へ漏らさない（Issue #1348 / #1368）
# shellcheck source=../lib/git-fixture.sh
. "$SCRIPT_DIR/../lib/git-fixture.sh"

# shellcheck source=../lib/adapter-env-isolation.sh
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"
# shellcheck source=../lib/multi-agent-sources.sh
. "$SCRIPT_DIR/../lib/multi-agent-sources.sh"

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
# 抽出源は入口と構成ファイル（scripts/lib/multi-agent-*.sh）の全部。MULTI_AGENT_CROSS_REVIEW は
# 構成ファイルにだけ現れるので、構成ファイルを渡し忘れると fail-closed で止まる
ma_sources_load "${MULTI_AGENT%/*}"
build_isolate_env "MULTI_AGENT_CONFIG MULTI_AGENT_CODEX_PROFILE MULTI_AGENT_CROSS_REVIEW" \
  "${MA_SOURCES[@]}" "$FIXTURE_PLUGIN"/scripts/adapters/*.sh

REPO="$TMP/repo"
STUB="$TMP/bin"
COUNT_FILE="$TMP/invocations"
FAIL_ON_NINTH="$TMP/fail-on-ninth"
CONFIG_FILE="$TMP/agent-config.yaml"
mkdir -p "$REPO" "$STUB"
printf '0\n' > "$COUNT_FILE"
printf 'armed\n' > "$FAIL_ON_NINTH"
cat > "$CONFIG_FILE" <<'YAML'
version: "2.0"
parallel: false
tasks:
  review:
    mode: distributed
    timeout: 60
YAML

ff_git_fixture_init "$REPO" "multi-agent-resume-test" "test@example.com"
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
if [[ -f "$FAIL_ON_NINTH" && "\$n" -eq 9 ]]; then
  rm -f "$FAIL_ON_NINTH"
  echo "simulated timeout/failure" >&2
  exit 1
fi
printf '%s\n' \
  "## Stub Review" \
  "" \
  "invocation=\$n" \
  "" \
  "### Summary" \
  "- Critical: 0" \
  "- verdict: none"
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
  acceptance-criteria
  comprehensive-review
)

run_review() { # <log> <timeout> <resume:true|false> [perspective count] [base]
  local log="$1" timeout="$2" resume="$3" perspective_count="${4:-9}" base="${5:-develop}"
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

echo "== 8成功・1失敗から未完了1観点だけを再実行 =="
if run_review "$TMP/first.log" 60 false; then
  bad "初回の9観点目失敗が exit 0 になった"
else
  ok "初回は8成功・1失敗として非0終了"
fi
if [[ "$(count_invocations)" -eq 9 ]]; then
  ok "初回は9観点すべてを起動"
else
  bad "初回の起動数が9ではない: $(count_invocations)"
fi
if [[ "$(find "$REPO/.review-results/.resume-cache" -name '*.md' | wc -l | tr -d ' ')" -eq 8 ]]; then
  ok "成功した8観点だけをキャッシュ"
else
  bad "成功キャッシュ数が8ではない"
fi

# timeout は identity 外。失敗後に延長しても成功8観点を再利用できる。
if run_review "$TMP/resume.log" 120 true; then
  ok "timeout延長付きresumeが成功"
else
  bad "timeout延長付きresumeが失敗"
fi
if [[ "$(count_invocations)" -eq 10 ]]; then
  ok "resumeは未完了1観点だけを起動"
else
  bad "resume後の累計起動数が10ではない: $(count_invocations)"
fi
if [[ "$(grep -c '^\*\*Result source:\*\* reused$' "$REPORT")" -eq 8 \
      && "$(grep -c '^\*\*Result source:\*\* executed$' "$REPORT")" -eq 1 \
      && "$(grep -c '^## codex-cli — ' "$REPORT")" -eq 9 ]]; then
  ok "統合レポートは全9観点とreused/executed由来を記録"
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
  && [[ "$(count_invocations)" -eq 11 ]] \
  && [[ "$(grep -c '^\*\*Result source:\*\* reused$' "$REPORT")" -eq 8 ]] \
  && [[ "$(grep -c '^\*\*Result source:\*\* executed$' "$REPORT")" -eq 1 ]]; then
  ok "hash欠落を再実行して回復"
else
  bad "hash欠落時の起動数または由来表示が不一致"
fi

rm -f "$CORRUPT_CACHE"
if run_review "$TMP/missing-result.log" 120 true \
  && [[ "$(count_invocations)" -eq 12 ]] \
  && [[ "$(grep -c '^\*\*Result source:\*\* reused$' "$REPORT")" -eq 8 ]] \
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
if [[ "$(count_invocations)" -eq 13 \
      && "$(grep -c '^\*\*Result source:\*\* reused$' "$REPORT")" -eq 8 \
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
  && [[ "$(count_invocations)" -eq 22 ]] \
  && [[ "$(grep -c '^\*\*Result source:\*\* executed$' "$REPORT")" -eq 9 ]]; then
  ok "HEAD変更で9観点すべてを新規実行"
else
  bad "HEAD変更時に古い結果を再利用した"
fi

git -C "$REPO" branch alternate-base develop
if run_review "$TMP/base-change.log" 120 true 9 alternate-base \
  && [[ "$(count_invocations)" -eq 31 ]] \
  && [[ "$(grep -c '^\*\*Result source:\*\* executed$' "$REPORT")" -eq 9 ]]; then
  ok "base変更で9観点すべてを新規実行"
else
  bad "base変更時に古い結果を再利用した"
fi

printf '\n# identity change\n' >> "$CONFIG_FILE"
if run_review "$TMP/config-change.log" 120 true \
  && [[ "$(count_invocations)" -eq 40 ]] \
  && [[ "$(grep -c '^\*\*Result source:\*\* executed$' "$REPORT")" -eq 9 ]]; then
  ok "設定変更で9観点すべてを新規実行"
else
  bad "設定変更時に古い結果を再利用した"
fi

printf '\n<!-- identity change -->\n' >> "$FIXTURE_PLUGIN/scripts/perspectives/review/code-review.md"
if run_review "$TMP/perspective-definition-change.log" 120 true \
  && [[ "$(count_invocations)" -eq 49 ]] \
  && [[ "$(grep -c '^\*\*Result source:\*\* executed$' "$REPORT")" -eq 9 ]]; then
  ok "perspective定義変更で9観点すべてを新規実行"
else
  bad "perspective定義変更時に古い結果を再利用した"
fi

printf '\nworktree review input change\n' >> "$REPO/app.txt"
if run_review "$TMP/review-input-change.log" 120 true \
  && [[ "$(count_invocations)" -eq 58 ]] \
  && [[ "$(grep -c '^\*\*Result source:\*\* executed$' "$REPORT")" -eq 9 ]]; then
  ok "review入力変更で9観点すべてを新規実行"
else
  bad "review入力変更時に古い結果を再利用した"
fi

if run_review "$TMP/perspective-set-change.log" 120 true 8 \
  && [[ "$(count_invocations)" -eq 66 ]] \
  && [[ "$(grep -c '^## codex-cli — ' "$REPORT")" -eq 8 ]] \
  && [[ "$(grep -c '^\*\*Result source:\*\* executed$' "$REPORT")" -eq 8 ]]; then
  ok "perspective集合変更で新しい8観点計画をすべて実行"
else
  bad "perspective集合変更時に古い集合の結果を再利用した"
fi

# 構成ファイル（scripts/lib/multi-agent-*.sh。multi-agent.sh が開始時に source する本体。
# ADR-075）も orchestrator の一部として identity に入る。入口だけを hash する形へ戻ると、
# 本体の変更が古い結果の再利用を止めない。先に「同じ入力なら全観点を再利用する」ことを
# 測り、差が構成ファイルの変更から来ていることを示す。
if run_review "$TMP/orchestrator-part-unchanged.log" 120 true 8 \
  && [[ "$(count_invocations)" -eq 66 ]] \
  && [[ "$(grep -c '^\*\*Result source:\*\* reused$' "$REPORT")" -eq 8 ]]; then
  ok "入力が同じなら8観点すべてを再利用（構成ファイル変更の比較の前提）"
else
  bad "入力が同じなのに再利用されない（構成ファイル変更の比較が成立しない）"
fi

# 変更は shebang の直後へ入れる。末尾へ足すと、最後の行が読み込み完了の印でなくなり入口が
# 「途中で切れている」として止まる（構成ファイルの契約。ADR-075）
_part="$FIXTURE_PLUGIN/scripts/lib/multi-agent-report.sh"
{ head -n 1 "$_part"; printf '%s\n' '# identity change'; tail -n +2 "$_part"; } > "$_part.new"
mv "$_part.new" "$_part"
if run_review "$TMP/orchestrator-part-change.log" 120 true 8 \
  && [[ "$(count_invocations)" -eq 74 ]] \
  && [[ "$(grep -c '^\*\*Result source:\*\* executed$' "$REPORT")" -eq 8 ]]; then
  ok "構成ファイル（scripts/lib/multi-agent-*.sh）の変更で8観点すべてを新規実行"
else
  bad "構成ファイルの変更時に古い結果を再利用した（resume identity が入口しか見ていない）"
fi

# adapter-common.sh の構成ファイルも同じ identity に入る。入口だけを hash する形へ戻ると、
# 本体の変更が古い結果の再利用を止めない。変更は shebang の直後（末尾は読み込み完了の印）。
_ac_part="$FIXTURE_PLUGIN/scripts/lib/adapter-common-git.sh"
{ head -n 1 "$_ac_part"; printf '%s\n' '# identity change'; tail -n +2 "$_ac_part"; } > "$_ac_part.new"
mv "$_ac_part.new" "$_ac_part"
if run_review "$TMP/adapter-part-change.log" 120 true 8 \
  && [[ "$(count_invocations)" -eq 82 ]] \
  && [[ "$(grep -c '^\*\*Result source:\*\* executed$' "$REPORT")" -eq 8 ]]; then
  ok "構成ファイル（scripts/lib/adapter-common-*.sh）の変更で8観点すべてを新規実行"
else
  bad "adapter-common の構成ファイルの変更時に古い結果を再利用した（resume identity が入口しか見ていない）"
fi

echo ""
# Claude effort belongs to resume identity, just like model/profile.
cp "$STUB/codex" "$STUB/claude"
for effort in medium medium high; do
  before="$(count_invocations)"
  if ( cd "$REPO" && run_isolated PATH="$STUB:$PATH" MULTI_AGENT_CLAUDE_EFFORT="$effort" \
    bash "$MULTI_AGENT" --task review --cli claude-code --perspective code-review --base develop \
    --config "$CONFIG_FILE" --output-dir "$TMP/claude-results" --resume --sequential ); then
    after="$(count_invocations)"
    if [[ "${previous_effort:-}" == "$effort" ]]; then expected="$before"; else expected=$((before + 1)); fi
    if [[ "$after" -eq "$expected" ]]; then ok "Claude effort $effort: resume invocation count"; else bad "Claude effort $effort: stale reuse or unnecessary execution"; fi
  else bad "Claude effort resume failed"; fi
  previous_effort="$effort"
done

echo "== 結果 =="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
FF_REACHED_END=1
[[ "$FAIL" -eq 0 ]]
