#!/usr/bin/env bash
#
# docs-template のうち placeholder を含まず実行可能なゲート例を Markdown から抽出し、
# fixture に対する exit code を実測する意味的回帰検査（Issue #157）。
#
# 役割分担:
#   - docs-gates/ は修正パターンの実在・退行パターンの不在を文面レベルで固定する。
#   - 本 suite は対象フェンスそのものと配布コマンドを実行し、空振り・未完了・
#     見出し drift・入口 drift が fail-closed になることを fixture / mutation で固定する。
#   - 汎用のコードフェンス解析は行わず、見出しと bash フェンスを対象契約とする。
#
# run-all.sh 契約:
#   - 全ケースが期待 exit code なら 0、違反があれば非 0。
#   - 一時作業領域を作れず検証本体を1件も実行できない場合のみ、行頭 `○ skip` + 0。
#
# 変異検出（リポジトリ正本 TESTING.md ゲートの層 = repo-testing-gate-cases.sh。
# 2026-09-12 実測。検査 1 つにつき 1 変異で注入し、赤転しなかった変異は無し）:
#   docs-gates 側の「新規検査を書いた直後の変異注入バッテリー」検査ブロックを `if false` へ
#   倒すと drop-granularity / drop-one-command / drop-todo / drop-writeback / rename-heading の
#   5 件が赤になる。正本不在の fail-closed ガードを bad → ok へ倒すと missing-testing が赤になる。
#
# macOS 標準 bash 3.2 + POSIX 標準ユーティリティで動かす。テスト対象の差し替えは
# FF_DOCS_GATE_RUNTIME_DOCS=<docs-template root> で行い、変異テストに利用できる。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCS="${FF_DOCS_GATE_RUNTIME_DOCS:-$PLUGIN_ROOT/docs-template}"
FIXTURES="$SCRIPT_DIR/fixtures"
# cases が作る fixture リポジトリの identity を呼び出し元へ漏らさない（Issue #1348）
# fixture リポジトリの identity を呼び出し元へ漏らさない（Issue #1348 / #1368）
# shellcheck source=../lib/git-fixture.sh
. "$SCRIPT_DIR/../lib/git-fixture.sh"
# 本 suite は docs-gates の needle を複製 docs に対して再実行するため、同じロケール依存を持つ。
# POSIX ロケール（cloud 既定）で赤にならないよう入口で UTF-8 へ固定する（docs-gates と同じ処理）。
# verify.sh だけを複製する selftest fixture では lib が無いので素通しする。
if [ -f "$SCRIPT_DIR/../lib/utf8-locale.sh" ]; then
  # shellcheck source=../lib/utf8-locale.sh
  . "$SCRIPT_DIR/../lib/utf8-locale.sh"
  ff_ensure_utf8_locale
fi

[ -d "$DOCS" ] || { echo "✗ docs-template が見つかりません: $DOCS" >&2; exit 1; }
[ -d "$FIXTURES" ] || { echo "✗ fixtures が見つかりません: $FIXTURES" >&2; exit 1; }

# mktemp の stderr を捨てない。捨てると read-only 以外の失敗（TMPDIR が不正な
# パス・quota 超過など）まで「書き込み可能な環境で再実行してください」に
# 誤帰属し、恒常的に壊れた TMPDIR が suite を exit 0 で無効化し続ける。
# 2>&1 で受けると、成功時はパス・失敗時は理由が同じ変数に入る。
# rc=0 でも -d を検査する — 2>&1 の合流は「成功 + stderr 警告」の環境で変数へ
# 警告文が混入し、以後の処理が原因不明の失敗に化けるため。
if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/ff-docs-gates-runtime.XXXXXX" 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  TMP_ROOT="$_ff_mktemp_out"
else
  echo "○ skip: 一時作業領域を作れないため docs-gates-runtime の検証本体を実行できません"
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

# 文書の root-qualified command をテスト側へ書き写さず、その行を直接 smoke へ渡す。
# prefix の引用符も抽出条件に含めるため、引用を外した文書退行は実行前に検出できる。
extract_root_quoted_command() {
  local doc="$1" resource="$2" marker="${3:-}"
  awk -v resource="$resource" -v marker="$marker" '
    index($0, "bash \"${FF_DEV_TOOLKIT_ROOT}/scripts/" resource "\"") \
      && (marker == "" || index($0, marker)) {
        command = $0
        sub(/^[[:space:]]*/, "", command)
        sub(/^ff_require_toolkit_root[[:space:]]+&&[[:space:]]+ff_require_consumer_root[[:space:]]+&&[[:space:]]+/, "", command)
        sub(/[[:space:]]+\|\|[[:space:]]+return[[:space:]]+"\$\?"[[:space:]]*$/, "", command)
        print command
        exit
    }
  ' "$doc"
}

extract_guarded_root_quoted_command() {
  local doc="$1" resource="$2" marker="${3:-}"
  awk -v resource="$resource" -v marker="$marker" '
    index($0, "ff_require_toolkit_root && ff_require_consumer_root && FF_DEV_TOOLKIT_ROOT=\"${FF_DEV_TOOLKIT_ROOT}\" bash \"${FF_DEV_TOOLKIT_ROOT}/scripts/" resource "\"") \
      && (marker == "" || index($0, marker)) {
        command = $0
        sub(/^[[:space:]]*/, "", command)
        print command
        exit
    }
  ' "$doc"
}

REVIEW_SCRIPT="$TMP_ROOT/review-verdict.sh"
PRE_PUSH_SCRIPT="$TMP_ROOT/pre-push.sh"
ROOT_GUARD_SCRIPT="$TMP_ROOT/plugin-root-guard.sh"

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
if ! extract_bash_fence \
    "$DOCS/05-operations/deployment/multi-cli-review-orchestration.md" \
    "## ff-dev-toolkit plugin root の固定（必須）" \
    "$ROOT_GUARD_SCRIPT"; then
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

# fixture 群を別ファイルへ分離し、主要な意味的回帰検査の肥大化を抑える。
# shellcheck source=pre-push-cases.sh
. "$SCRIPT_DIR/pre-push-cases.sh"
run_pre_push_cases

# Issue #1011 の live 検出器へ実際の退行を注入する。静的 suite 自身は読み取り専用に
# 保ち、コピー・書き込み・negative control は一時領域依存の本 suite で担う。
run_docs_gate_mutation() {
  local mutation="$1" label="$2" expected="$3" case_root docs_copy target log rc=0
  case_root="$TMP_ROOT/docs-mutation-${mutation}"
  docs_copy="$case_root/docs-template"
  log="$case_root/output.log"
  mkdir -p "$case_root"
  cp -R "$DOCS" "$docs_copy"

  case "$mutation" in
    consumer-inline)
      target="$docs_copy/99-consumer-local-regression.md"
      printf '%s\n' '本文: `bash scripts/setup-multi-agent.sh`' >"$target"
      ;;
    consumer-zsh)
      target="$docs_copy/99-consumer-zsh-regression.md"
      printf '%s\n' 'zsh "scripts/multi-agent.sh" --task review' >"$target"
      ;;
    consumer-continuation)
      target="$docs_copy/99-consumer-continuation-regression.md"
      printf '%s\n' 'bash \' '  ./scripts/multi-review.sh --dry-run' >"$target"
      ;;
    consumer-shell-option)
      target="$docs_copy/99-consumer-shell-option-regression.md"
      printf '%s\n' 'bash -x -- scripts/multi-review.sh --dry-run' >"$target"
      ;;
    consumer-multiline-options)
      target="$docs_copy/99-consumer-multiline-options-regression.md"
      printf '%s\n' 'bash \' '  -x \' '  ./scripts/multi-review.sh --dry-run' >"$target"
      ;;
    consumer-inline-direct)
      target="$docs_copy/99-consumer-inline-direct-regression.md"
      printf '%s\n' '本文: `./scripts/multi-agent.sh --dry-run`' >"$target"
      ;;
    consumer-bullet-direct)
      target="$docs_copy/99-consumer-bullet-direct-regression.md"
      printf '%s\n' '- ./scripts/multi-review.sh --dry-run' >"$target"
      ;;
    consumer-ordered-direct)
      target="$docs_copy/99-consumer-ordered-direct-regression.md"
      printf '%s\n' '1. ./scripts/multi-agent.sh --dry-run' >"$target"
      ;;
    consumer-normalized-dot)
      target="$docs_copy/99-consumer-normalized-dot-regression.md"
      printf '%s\n' 'bash scripts/./multi-review.sh --dry-run' >"$target"
      ;;
    consumer-normalized-slash)
      target="$docs_copy/99-consumer-normalized-slash-regression.md"
      printf '%s\n' 'env FOO=1 ./scripts//multi-agent.sh --task review' >"$target"
      ;;
    consumer-command-wrapper)
      target="$docs_copy/99-consumer-command-wrapper-regression.md"
      printf '%s\n' 'command ./scripts/multi-review.sh --dry-run' >"$target"
      ;;
    consumer-exec-wrapper)
      target="$docs_copy/99-consumer-exec-wrapper-regression.md"
      printf '%s\n' 'exec ./scripts/multi-agent.sh --task review' >"$target"
      ;;
    consumer-env-wrapper)
      target="$docs_copy/99-consumer-env-wrapper-regression.md"
      printf '%s\n' 'env FOO=1 ./scripts/setup-multi-agent.sh --skip-install' >"$target"
      ;;
    consumer-absolute-shell)
      target="$docs_copy/99-consumer-absolute-shell-regression.md"
      printf '%s\n' '/bin/bash ./scripts/multi-review.sh --dry-run' >"$target"
      ;;
    consumer-source)
      target="$docs_copy/99-consumer-source-regression.md"
      printf '%s\n' 'source ./scripts/multi-agent.sh' >"$target"
      ;;
    consumer-dot-source)
      target="$docs_copy/99-consumer-dot-source-regression.md"
      printf '%s\n' '. ./scripts/setup-multi-agent.sh' >"$target"
      ;;
    consumer-test-probe)
      target="$docs_copy/99-consumer-test-probe-regression.md"
      printf '%s\n' 'test -x scripts/multi-review.sh' >"$target"
      ;;
    late-prerequisite)
      target="$docs_copy/99-late-prerequisite-regression.md"
      printf '%s\n' \
        'bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh" --dry-run' \
        '[root prerequisite](./05-operations/deployment/multi-cli-review-orchestration.md#ff-dev-toolkit-plugin-root-prerequisite)' \
        >"$target"
      ;;
    unquoted-root)
      target="$docs_copy/99-unquoted-root-regression.md"
      printf '%s\n' \
        '[root prerequisite](./05-operations/deployment/multi-cli-review-orchestration.md#ff-dev-toolkit-plugin-root-prerequisite)' \
        'bash ${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh --dry-run' \
        >"$target"
      ;;
    alternate-root)
      target="$docs_copy/99-alternate-root-regression.md"
      printf '%s\n' \
        '[root prerequisite](./05-operations/deployment/multi-cli-review-orchestration.md#ff-dev-toolkit-plugin-root-prerequisite)' \
        'bash "${CLAUDE_PLUGIN_ROOT}/scripts/multi-review.sh" --dry-run' \
        >"$target"
      ;;
    aliased-root-command)
      target="$docs_copy/99-aliased-root-command-regression.md"
      printf '%s\n' \
        '[root prerequisite](./05-operations/deployment/multi-cli-review-orchestration.md#ff-dev-toolkit-plugin-root-prerequisite)' \
        'TOOLKIT_SCRIPTS="${FF_DEV_TOOLKIT_ROOT}/scripts"; bash "$TOOLKIT_SCRIPTS/multi-review.sh" --dry-run' \
        >"$target"
      ;;
    bullet-alternate-root)
      target="$docs_copy/99-bullet-alternate-root-regression.md"
      printf '%s\n' \
        '[root prerequisite](./05-operations/deployment/multi-cli-review-orchestration.md#ff-dev-toolkit-plugin-root-prerequisite)' \
        '- "${CLAUDE_PLUGIN_ROOT}/scripts/multi-review.sh" --dry-run' \
        >"$target"
      ;;
    root-command-disappears)
      target="$docs_copy/05-operations/deployment/multi-cli-agent-orchestration.md"
      awk '
        {
          gsub(/bash "\$\{FF_DEV_TOOLKIT_ROOT\}\/scripts\/multi-agent\.sh"/, "path-only: multi-agent.sh")
          gsub(/bash "\$\{FF_DEV_TOOLKIT_ROOT\}\/scripts\/multi-review\.sh"/, "path-only: multi-review.sh")
          print
        }
      ' "$target" >"$target.tmp"
      mv "$target.tmp" "$target"
      ;;
    unguarded-direct)
      target="$docs_copy/05-operations/deployment/multi-cli-agent-orchestration.md"
      awk '
        !changed && sub(/^ff_require_toolkit_root && ff_require_consumer_root && /, "") { changed = 1 }
        { print }
      ' "$target" >"$target.tmp"
      mv "$target.tmp" "$target"
      ;;
    unguarded-env-direct)
      target="$docs_copy/05-operations/deployment/multi-cli-agent-orchestration.md"
      awk '
        !changed && sub(/^ff_require_toolkit_root && ff_require_consumer_root && FF_DEV_TOOLKIT_ROOT="[$][{]FF_DEV_TOOLKIT_ROOT[}]" bash /, "  env REVIEW=1 FF_DEV_TOOLKIT_ROOT=\"${FF_DEV_TOOLKIT_ROOT}\" bash ") { changed = 1 }
        { print }
      ' "$target" >"$target.tmp"
      mv "$target.tmp" "$target"
      ;;
    unguarded-sh-direct)
      target="$docs_copy/99-unguarded-sh-regression.md"
      printf '%s\n' \
        '[root prerequisite](./05-operations/deployment/multi-cli-review-orchestration.md#ff-dev-toolkit-plugin-root-prerequisite)' \
        '```bash' \
        'sh "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh" --dry-run' \
        '```' >"$target"
      ;;
    unguarded-bare-direct)
      target="$docs_copy/99-unguarded-bare-regression.md"
      printf '%s\n' \
        '[root prerequisite](./05-operations/deployment/multi-cli-review-orchestration.md#ff-dev-toolkit-plugin-root-prerequisite)' \
        '```bash' \
        '"${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh" --dry-run' \
        '```' >"$target"
      ;;
    unguarded-if-direct)
      target="$docs_copy/99-unguarded-if-regression.md"
      printf '%s\n' \
        '[root prerequisite](./05-operations/deployment/multi-cli-review-orchestration.md#ff-dev-toolkit-plugin-root-prerequisite)' \
        '```bash' \
        'if ! bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh" --dry-run; then exit 1; fi' \
        '```' >"$target"
      ;;
    unguarded-run-direct)
      target="$docs_copy/99-unguarded-run-regression.md"
      printf '%s\n' \
        '[root prerequisite](./05-operations/deployment/multi-cli-review-orchestration.md#ff-dev-toolkit-plugin-root-prerequisite)' \
        '```yaml' \
        'run: bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh" --dry-run' \
        '```' >"$target"
      ;;
    consumer-guard-missing)
      target="$docs_copy/05-operations/deployment/multi-cli-agent-orchestration.md"
      awk '
        !changed && sub(/ff_require_consumer_root && FF_DEV_TOOLKIT_ROOT="[$][{]FF_DEV_TOOLKIT_ROOT[}]" bash /, "FF_DEV_TOOLKIT_ROOT=\"${FF_DEV_TOOLKIT_ROOT}\" bash ") { changed = 1 }
        { print }
      ' "$target" >"$target.tmp"
      mv "$target.tmp" "$target"
      ;;
    ci-checkout-path-drift)
      target="$docs_copy/05-operations/deployment/multi-cli-review-ci.md"
      sed 's/path: \.ff-dev-toolkit-source/path: .other-toolkit-source/' \
        "$target" >"$target.tmp"
      mv "$target.tmp" "$target"
      ;;
    ci-checkout-ref-drift)
      target="$docs_copy/05-operations/deployment/multi-cli-review-ci.md"
      sed 's/ref: \${{ env\.FF_DEV_TOOLKIT_REF }}/ref: main/' \
        "$target" >"$target.tmp"
      mv "$target.tmp" "$target"
      ;;
    ci-fork-gate-missing)
      target="$docs_copy/05-operations/deployment/multi-cli-review-ci.md"
      sed '/if: github\.event\.pull_request\.head\.repo\.full_name == github\.repository/d' \
        "$target" >"$target.tmp"
      mv "$target.tmp" "$target"
      ;;
    ci-trigger-target)
      target="$docs_copy/05-operations/deployment/multi-cli-review-ci.md"
      sed 's/^  pull_request:$/  pull_request_target:/' "$target" >"$target.tmp"
      mv "$target.tmp" "$target"
      ;;
    ci-fork-gate-moved)
      target="$docs_copy/05-operations/deployment/multi-cli-review-ci.md"
      sed 's/^    if: github\.event\.pull_request/        if: github.event.pull_request/' \
        "$target" >"$target.tmp"
      mv "$target.tmp" "$target"
      ;;
    ci-upload-condition-moved)
      target="$docs_copy/05-operations/deployment/multi-cli-review-ci.md"
      awk '
        /^      - name: Run Multi-CLI Review$/ { print; in_review = 1; next }
        in_review && /^[[:space:]]*id: multi_cli_review$/ {
          print
          print "        if: ${{ always() && steps.multi_cli_review.conclusion != '\''skipped'\'' }}"
          in_review = 0
          next
        }
        /^        if: \$\{\{ always\(\) && steps\.multi_cli_review\.conclusion != '\''skipped'\'' \}\}$/ { next }
        { print }
      ' "$target" >"$target.tmp"
      mv "$target.tmp" "$target"
      ;;
    ci-action-unpinned)
      target="$docs_copy/05-operations/deployment/multi-cli-review-ci.md"
      sed 's#actions/checkout@11d5960a326750d5838078e36cf38b85af677262#actions/checkout@main#' \
        "$target" >"$target.tmp"
      mv "$target.tmp" "$target"
      ;;
    ci-cli-unpinned)
      target="$docs_copy/05-operations/deployment/multi-cli-review-ci.md"
      sed 's#@openai/codex@${CODEX_CLI_VERSION}#@openai/codex#' \
        "$target" >"$target.tmp"
      mv "$target.tmp" "$target"
      ;;
    ci-runtime-pin-guard-missing)
      target="$docs_copy/05-operations/deployment/multi-cli-review-ci.md"
      awk '
        !changed && index($0, "^[0-9a-f]{40}$") { sub(/40/, "39"); changed = 1 }
        { print }
      ' "$target" >"$target.tmp"
      mv "$target.tmp" "$target"
      ;;
    ci-checkout-head-check-missing)
      target="$docs_copy/05-operations/deployment/multi-cli-review-ci.md"
      sed 's/"$checkout_head" != "$FF_DEV_TOOLKIT_REF"/"$checkout_head" != "$checkout_head"/' \
        "$target" >"$target.tmp"
      mv "$target.tmp" "$target"
      ;;
    ci-resource-symlink-guard-missing)
      target="$docs_copy/05-operations/deployment/multi-cli-review-ci.md"
      sed 's/ || \[ -L "$resource_path" \]//' "$target" >"$target.tmp"
      mv "$target.tmp" "$target"
      ;;
    ci-verify-continue-on-error)
      target="$docs_copy/05-operations/deployment/multi-cli-review-ci.md"
      awk '
        { print }
        /- name: Verify pinned ff-dev-toolkit/ { print "        continue-on-error: true" }
      ' "$target" >"$target.tmp"
      mv "$target.tmp" "$target"
      ;;
    ci-review-always)
      target="$docs_copy/05-operations/deployment/multi-cli-review-ci.md"
      awk '
        { print }
        /- name: Run Multi-CLI Review/ { print "        if: always()" }
      ' "$target" >"$target.tmp"
      mv "$target.tmp" "$target"
      ;;
    ci-top-env-runner-context)
      target="$docs_copy/05-operations/deployment/multi-cli-review-ci.md"
      awk '
        { print }
        !changed && /^env:$/ {
          print "  FF_REVIEW_OUTPUT: ${{ runner.temp }}/ff-review-results"
          changed = 1
        }
      ' "$target" >"$target.tmp"
      mv "$target.tmp" "$target"
      ;;
    ci-report-verification-missing)
      target="$docs_copy/05-operations/deployment/multi-cli-review-ci.md"
      awk '
        /^      - name: Verify integrated review report$/ { drop = 1; next }
        drop && /^      - name:/ { drop = 0 }
        !drop { print }
      ' "$target" >"$target.tmp"
      mv "$target.tmp" "$target"
      ;;
    multiline-root)
      target="$docs_copy/99-multiline-root-regression.md"
      printf '%s\n' \
        '[root prerequisite](./05-operations/deployment/multi-cli-review-orchestration.md#ff-dev-toolkit-plugin-root-prerequisite)' \
        'bash \' \
        '  ${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh --dry-run' \
        >"$target"
      ;;
    option-unquoted-root)
      target="$docs_copy/99-option-unquoted-root-regression.md"
      printf '%s\n' \
        '[root prerequisite](./05-operations/deployment/multi-cli-review-orchestration.md#ff-dev-toolkit-plugin-root-prerequisite)' \
        'bash -x -- ${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh --dry-run' \
        >"$target"
      ;;
    direct-alternate-root)
      target="$docs_copy/99-direct-alternate-root-regression.md"
      printf '%s\n' \
        '[root prerequisite](./05-operations/deployment/multi-cli-review-orchestration.md#ff-dev-toolkit-plugin-root-prerequisite)' \
        '${CLAUDE_PLUGIN_ROOT}/scripts/multi-review.sh --dry-run' \
        >"$target"
      ;;
    quoted-direct-alternate-root)
      target="$docs_copy/99-quoted-direct-alternate-root-regression.md"
      printf '%s\n' \
        '[root prerequisite](./05-operations/deployment/multi-cli-review-orchestration.md#ff-dev-toolkit-plugin-root-prerequisite)' \
        '"${CLAUDE_PLUGIN_ROOT}/scripts/multi-review.sh" --dry-run' \
        >"$target"
      ;;
    quoted-absolute-cache)
      target="$docs_copy/99-quoted-absolute-cache-regression.md"
      printf '%s\n' \
        '[root prerequisite](./05-operations/deployment/multi-cli-review-orchestration.md#ff-dev-toolkit-plugin-root-prerequisite)' \
        '"/tmp/cache/ff-dev-toolkit/9.9.9/scripts/multi-review.sh" --dry-run' \
        >"$target"
      ;;
    command-alternate-root)
      target="$docs_copy/99-command-alternate-root-regression.md"
      printf '%s\n' \
        '[root prerequisite](./05-operations/deployment/multi-cli-review-orchestration.md#ff-dev-toolkit-plugin-root-prerequisite)' \
        'command "${CLAUDE_PLUGIN_ROOT}/scripts/multi-review.sh" --dry-run' \
        >"$target"
      ;;
    test-alternate-root)
      target="$docs_copy/99-test-alternate-root-regression.md"
      printf '%s\n' \
        '[root prerequisite](./05-operations/deployment/multi-cli-review-orchestration.md#ff-dev-toolkit-plugin-root-prerequisite)' \
        'test -x "${CLAUDE_PLUGIN_ROOT}/scripts/multi-review.sh"' \
        >"$target"
      ;;
    same-line-alternate-root)
      target="$docs_copy/99-same-line-alternate-root-regression.md"
      printf '%s\n' \
        '[root prerequisite](./05-operations/deployment/multi-cli-review-orchestration.md#ff-dev-toolkit-plugin-root-prerequisite)' \
        'bash "${CLAUDE_PLUGIN_ROOT}/scripts/multi-review.sh"; bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh"' \
        >"$target"
      ;;
    comment-covered-alternate-root)
      target="$docs_copy/99-comment-covered-alternate-root-regression.md"
      printf '%s\n' \
        '[root prerequisite](./05-operations/deployment/multi-cli-review-orchestration.md#ff-dev-toolkit-plugin-root-prerequisite)' \
        'bash "${CLAUDE_PLUGIN_ROOT}/scripts/multi-review.sh" # bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh"' \
        >"$target"
      ;;
    fake-prerequisite)
      target="$docs_copy/99-fake-prerequisite-regression.md"
      printf '%s\n' '<a id="ff-dev-toolkit-plugin-root-prerequisite"></a>' \
        >"$docs_copy/99-anchor-only.md"
      printf '%s\n' \
        '[root prerequisite](./99-anchor-only.md#ff-dev-toolkit-plugin-root-prerequisite)' \
        'bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh" --dry-run' \
        >"$target"
      ;;
    inline-prerequisite)
      target="$docs_copy/99-inline-prerequisite-regression.md"
      printf '%s\n' \
        '`[root prerequisite](./05-operations/deployment/multi-cli-review-orchestration.md#ff-dev-toolkit-plugin-root-prerequisite)`' \
        'bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh" --dry-run' \
        >"$target"
      ;;
    tilde-prerequisite)
      target="$docs_copy/99-tilde-prerequisite-regression.md"
      printf '%s\n' \
        '~~~markdown' \
        '[root prerequisite](./05-operations/deployment/multi-cli-review-orchestration.md#ff-dev-toolkit-plugin-root-prerequisite)' \
        '~~~' \
        'bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh" --dry-run' \
        >"$target"
      ;;
    bare-parenthesis-prerequisite)
      target="$docs_copy/99-bare-parenthesis-prerequisite-regression.md"
      printf '%s\n' \
        '(./05-operations/deployment/multi-cli-review-orchestration.md#ff-dev-toolkit-plugin-root-prerequisite)' \
        'bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh" --dry-run' \
        >"$target"
      ;;
    deleg-link-moved-out-of-section)
      # 委譲の待機・回収規定の到達点（子側 / 親側の正本節へのリンクとタイムアウトの実値）を
      # 並列委譲手順から取り除き、**同じ文書の末尾**へそのまま移す。文書全体の grep だけで
      # 見ている検査はこの変異を素通しする（リンクも実値も文書内には残っている）。
      target="$docs_copy/05-operations/deployment/git-workflow.md"
      awk '
        index($0, "2. **実装は worktree 隔離のサブエージェントで並列に行い") == 1 {
          moved = $0
          print "2. **実装は worktree 隔離のサブエージェントで並列に行い、レビュー・マージは親が直列に行う。** 詳細は文末の付記を参照。"
          next
        }
        { print }
        END {
          if (moved != "") {
            print ""
            print "## 付記（手順の外へ移した解説）"
            print ""
            print moved
          }
        }
      ' "$target" >"$target.tmp"
      mv "$target.tmp" "$target"
      ;;
    deleg-timeout-value-dropped)
      # 並列委譲手順からタイムアウトの実値だけを落とす（リンクは残す）。正本を読まない
      # 消費地点には値が届かなくなるので、実値の針が赤になること自体を固定する。
      target="$docs_copy/05-operations/deployment/git-workflow.md"
      sed 's/`timeout` へ `600000`（ミリ秒）を明示して/タイムアウトを明示して/' \
        "$target" >"$target.tmp"
      mv "$target.tmp" "$target"
      ;;
    *)
      bad "未知の docs gate mutation: $mutation"
      return
      ;;
  esac

  FF_DOCS_GATE_DOCS="$docs_copy" \
    bash "$PLUGIN_ROOT/tests/docs-gates/verify.sh" >"$log" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ] && grep -qF "$expected" "$log"; then
    ok "$label"
  else
    bad "$label — 期待した検出器で拒否されない (rc=${rc}, expected=${expected})"
    sed -n '1,160p' "$log" >&2 || true
  fi
}

# shellcheck source=docs-mutation-invocations.sh
. "$SCRIPT_DIR/docs-mutation-invocations.sh"
run_docs_gate_mutations

# docs-gates 側の「リポジトリ正本 TESTING.md」検出器を、隔離した偽リポジトリ root で実測する。
# 静的 suite は自分の検査が消えたことを測れないので、その層を本 suite が担う。
# shellcheck source=repo-testing-gate-cases.sh
. "$SCRIPT_DIR/repo-testing-gate-cases.sh"
run_repo_testing_gate_cases

# shellcheck source=setup-review-flow-cases.sh
. "$SCRIPT_DIR/setup-review-flow-cases.sh"
run_setup_review_flow_cases

# shellcheck source=ci-example-cases.sh
. "$SCRIPT_DIR/ci-example-cases.sh"
run_ci_example_cases

# shellcheck source=root-guard-cases.sh
. "$SCRIPT_DIR/root-guard-cases.sh"
run_root_guard_cases

# shellcheck source=consumer-command-smoke.sh
. "$SCRIPT_DIR/consumer-command-smoke.sh"
run_consumer_command_smoke

# shellcheck source=shim-cache-selection-cases.sh
. "$SCRIPT_DIR/shim-cache-selection-cases.sh"
run_shim_cache_selection

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ docs-gates-runtime verify: $FAIL 件失敗（$PASS 件 pass）" >&2
  exit 1
fi
echo "✓ docs-gates-runtime verify: 全 $PASS 件 pass"
FF_REACHED_END=1
