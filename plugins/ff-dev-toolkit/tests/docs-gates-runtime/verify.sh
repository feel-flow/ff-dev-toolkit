#!/usr/bin/env bash
#
# docs-template のうち placeholder を含まず実行可能なゲート例を Markdown から抽出し、
# fixture に対する exit code を実測する意味的回帰検査（Issue #157）。
#
# 役割分担:
#   - docs-gates/ は修正パターンの実在・退行パターンの不在を文面レベルで固定する。
#   - 本 suite は対象フェンスそのものを実行し、空振り・未完了・見出し drift・
#     部分文字列一致が fail-closed になることを fixture で固定する。
#   - 汎用のコードフェンス解析は行わず、見出しと bash フェンスを対象契約とする。
#
# run-all.sh 契約:
#   - 全ケースが期待 exit code なら 0、違反があれば非 0。
#   - 一時作業領域を作れず検証本体を1件も実行できない場合のみ、行頭 `○ skip` + 0。
#
# macOS 標準 bash 3.2 + POSIX 標準ユーティリティで動かす。テスト対象の差し替えは
# FF_DOCS_GATE_RUNTIME_DOCS=<docs-template root> で行い、変異テストに利用できる。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCS="${FF_DOCS_GATE_RUNTIME_DOCS:-$PLUGIN_ROOT/docs-template}"
FIXTURES="$SCRIPT_DIR/fixtures"

[ -d "$DOCS" ] || { echo "✗ docs-template が見つかりません: $DOCS" >&2; exit 1; }
[ -d "$FIXTURES" ] || { echo "✗ fixtures が見つかりません: $FIXTURES" >&2; exit 1; }

# mktemp の stderr を捨てない。捨てると read-only 以外の失敗（TMPDIR が不正な
# パス・quota 超過など）まで「書き込み可能な環境で再実行してください」に
# 誤帰属し、恒常的に壊れた TMPDIR が suite を exit 0 で無効化し続ける。
# 2>&1 で受けると、成功時はパス・失敗時は理由が同じ変数に入る。
if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/ff-docs-gates-runtime.XXXXXX" 2>&1)"; then
  TMP_ROOT="$_ff_mktemp_out"
else
  echo "○ skip: 一時作業領域を作れないため docs-gates-runtime の検証本体を実行できません"
  FF_REACHED_END=1
  exit 0
fi
# 途中死を沈黙させない。`set -u` 等で死んだとき、トラップ突入時の $? は **0** になるため、
# 終了ステータスを保存し直すだけでは足りない（実測）。「rc=0 なのに最後まで到達して
# いない」を中断として扱う。明示的な非 0 終了はそのまま通す。
FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$TMP_ROOT"
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ docs-gates-runtime: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

extract_bash_fence() {
  local source="$1" heading="$2" output="$3"

  if ! awk -v heading="$heading" '
    $0 == heading {
      found_heading = 1
      next
    }
    found_heading && !in_fence && $0 ~ /^#{1,6}[[:space:]]/ {
      exit 2
    }
    found_heading && !in_fence && $0 == "```bash" {
      found_fence = 1
      in_fence = 1
      next
    }
    in_fence && $0 == "```" {
      found_end = 1
      FF_REACHED_END=1
      exit 0
    }
    in_fence {
      print
    }
    END {
      if (!found_heading || !found_fence || !found_end) {
        exit 2
      }
    }
  ' "$source" > "$output"; then
    bad "フェンス抽出失敗: $heading ($source)"
    return 1
  fi

  if [ ! -s "$output" ]; then
    bad "抽出したフェンスが空です: $heading ($source)"
    return 1
  fi

  ok "見出しから bash フェンスを抽出: $heading"
}

REVIEW_SCRIPT="$TMP_ROOT/review-verdict.sh"
PRE_PUSH_SCRIPT="$TMP_ROOT/pre-push.sh"

echo "== Markdown から対象フェンスを抽出 =="
if ! extract_bash_fence \
    "$DOCS/05-operations/deployment/automated-code-review.md" \
    "### レビュー厳格度の調整" \
    "$REVIEW_SCRIPT"; then
  exit 1
fi
if ! extract_bash_fence \
    "$DOCS/05-operations/deployment/multi-cli-review-orchestration.md" \
    "### Husky pre-push フックとの統合" \
    "$PRE_PUSH_SCRIPT"; then
  exit 1
fi

# pre-push フェンス冒頭の husky 初期化を満たす最小 stub。テスト対象はその後の
# review 実行・統合レポート検査であり、husky 自体の挙動ではない。
mkdir -p "$TMP_ROOT/_"
: > "$TMP_ROOT/_/husky.sh"

run_review_case() {
  local label="$1" fixture="$2" strict="$3" expected="$4"
  local output="$TMP_ROOT/review-output.txt" rc=0

  if REVIEW_RESULT="$fixture" REVIEW_STRICT="$strict" \
      bash "$REVIEW_SCRIPT" >"$output" 2>&1; then
    rc=0
  else
    rc=$?
  fi

  if [ "$rc" -eq "$expected" ]; then
    ok "$label (exit $rc)"
  else
    bad "$label — exit ${rc}、期待 ${expected}"
    sed 's/^/      | /' "$output" >&2
  fi
}

echo
echo "== automated-code-review 判定ロジックの fixture 実行 =="
EMPTY_REVIEW="$TMP_ROOT/empty-review.md"
: > "$EMPTY_REVIEW"
run_review_case "正常な APPROVED + Important Issues なし" \
  "$FIXTURES/review/approved.md" 1 0
run_review_case "INCOMPLETE はブロック" \
  "$FIXTURES/review/incomplete.md" 0 1
run_review_case "空ファイルはブロック" \
  "$EMPTY_REVIEW" 0 1
run_review_case "Important Issues 見出し drift は strict mode でブロック" \
  "$FIXTURES/review/heading-drift.md" 1 1
run_review_case "APPROVED でも Important Issues の実指摘は strict mode でブロック" \
  "$FIXTURES/review/approved-with-important-issue.md" 1 1
run_review_case "REJECTED 本文中の APPROVED 引用は合格にしない" \
  "$FIXTURES/review/rejected-approved-quote.md" 0 1

PRE_PUSH_CASE=0
run_pre_push_case() {
  local label="$1" runner_rc="$2" report_fixture="$3" expected="$4"
  local case_dir output rc=0

  PRE_PUSH_CASE=$((PRE_PUSH_CASE + 1))
  case_dir="$TMP_ROOT/pre-push-$PRE_PUSH_CASE"
  output="$case_dir/output.txt"
  mkdir -p "$case_dir/scripts" "$case_dir/.review-results"

  # stub 自身が実行時に読む式なので、生成側では意図的に展開しない。
  # shellcheck disable=SC2016
  printf '%s\n' '#!/usr/bin/env bash' 'exit "${FF_STUB_REVIEW_RC:-0}"' \
    > "$case_dir/scripts/multi-review.sh"

  case "$report_fixture" in
    __EMPTY__)
      : > "$case_dir/.review-results/integrated-report.md"
      ;;
    __MISSING__)
      ;;
    *)
      cp "$report_fixture" "$case_dir/.review-results/integrated-report.md"
      ;;
  esac

  if (cd "$case_dir" && FF_STUB_REVIEW_RC="$runner_rc" \
      bash "$PRE_PUSH_SCRIPT" >"$output" 2>&1); then
    rc=0
  else
    rc=$?
  fi

  if [ "$rc" -eq "$expected" ]; then
    ok "$label (exit $rc)"
  else
    bad "$label — exit ${rc}、期待 ${expected}"
    sed 's/^/      | /' "$output" >&2
  fi
}

echo
echo "== multi-cli-review pre-push 例の fixture 実行 =="
run_pre_push_case "正常なレビュー実行 + 統合レポート" 0 \
  "$FIXTURES/pre-push/normal-report.md" 0
run_pre_push_case "レビュースクリプト非 0 はブロック" 7 \
  "$FIXTURES/pre-push/normal-report.md" 1
run_pre_push_case "空の統合レポートはブロック" 0 __EMPTY__ 1
run_pre_push_case "INCOMPLETE を含む統合レポートはブロック" 0 \
  "$FIXTURES/pre-push/incomplete-report.md" 1
run_pre_push_case "CRITICAL_BLOCK マーカーを含む統合レポートはブロック" 0 \
  "$FIXTURES/pre-push/critical-report.md" 1
# 判定はマーカー**全文**の固定文字列一致（Issue #645 の観点別段階化の前提）。
# 本文中の裸の CRITICAL_BLOCK 言及（Verdict 語彙）や CRITICAL_NONBLOCK 注記で
# 部分一致誤発火すると、非ブロック観点だけの実行でもゲートが再発火し段階化が無効になる
run_pre_push_case "裸の CRITICAL_BLOCK 言及 + 非ブロック注記のみはブロックしない" 0 \
  "$FIXTURES/pre-push/mention-only-report.md" 0

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ docs-gates-runtime verify: $FAIL 件失敗（$PASS 件 pass）" >&2
  exit 1
fi
echo "✓ docs-gates-runtime verify: 全 $PASS 件 pass"
FF_REACHED_END=1
