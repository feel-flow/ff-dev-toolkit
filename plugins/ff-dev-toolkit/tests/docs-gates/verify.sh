#!/usr/bin/env bash
#
# docs-template 内のゲート例（pre-push フック / CI / 判定スクリプト）が
# fail-silent へ退行していないことの drift 検査（Issue #154）。
#
# 背景: PR #153 のレビューで、pre-push フック例が「レビューが 1 件も完走しなかった
# 実行」を合格として通すことが判明した（Issue #152）。同型の問題（終了コードを
# 捨てる / マーカー不在を合格と読む / 失敗回の成果物を回収しない）を Issue #154 で
# docs-template 全体から掃いた。本 suite はその修正結果を文面レベルで固定する。
#
# 検査できること・できないこと:
#   - できる: 修正済みの具体例が退行していないこと（修正パターンの実在と、
#     退行パターンの不在）。文書は実行できないので、これが機械検査の上限。
#   - できない: 「新しく書かれるゲート例が fail-silent でないこと」の意味検査。
#     コードフェンス内のシェルの合否経路を静的に追う汎用検査は誤検出の山になる
#     ため載せない（判断理由の記録: Issue #154 AC3）。新規例は multi-cli-review-
#     orchestration.md の三重ゲート（実行の成否 / 出力の完全性 / 内容の判定）を
#     正本として人間 + レビューで見る。
#
# needle の設計規則（PR #156 レビューでの教訓）:
#   - 説明コメント・散文が同じ文字列を含む場合、固定文字列の存在検査は
#     「コードが消えても散文が残れば合格」になる。コード行にしか現れない形
#     （行頭アンカー + コード固有のプレフィックス）で must_match を使うこと。
#   - needle を追加・変更したら、対象のコード行だけを削除する変異を手で当てて
#     red になることを確認する（15/15 green は drift 検査の証明にならない）。
#   - 文言 needle（散文アンカー）が red になった場合、文書の正当なリライトが
#     原因なら本ファイルの needle も一緒に更新する。
#
# Bash と、本プロジェクトの対応環境に標準搭載される grep / awk / sed / find を使う。
# 一時ファイルを作らない読み取り専用 suite とし、docs の複製を伴う動的 smoke / mutation は
# docs-gates-runtime が担うため、書き込み不可の環境でも本 suite 単体は完走できる。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# needle にマルチバイト文字（`[^）]*` 等）を含むため、POSIX ロケールでは docs の内容と無関係に
# 赤になる（Claude Code cloud の既定。2026-09-08 実測）。単体実行でも同じ結果になるよう
# suite の入口で UTF-8 ロケールへ固定する（run-all.sh 経由でも同じ処理が先に走る）。
# verify.sh だけを複製する selftest fixture では lib が無いので素通しする。
if [ -f "$SCRIPT_DIR/../lib/utf8-locale.sh" ]; then
  # shellcheck source=../lib/utf8-locale.sh
  . "$SCRIPT_DIR/../lib/utf8-locale.sh"
  ff_ensure_utf8_locale
fi
# 変異検査では docs だけを複製し、静的 suite の実装は同じものを使う。
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCS="${FF_DOCS_GATE_DOCS:-$PLUGIN_ROOT/docs-template}"

[ -d "$DOCS" ] || { echo "✗ docs-template が見つかりません: $DOCS" >&2; exit 1; }

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# --- 消費プロジェクトのレビュー入口（Issue #1011） ---
# shellcheck source=consumer-review-entrypoint-scan.sh
. "$SCRIPT_DIR/consumer-review-entrypoint-scan.sh"

consumer_local_rc=0
consumer_local_entries="$(find_consumer_local_review_entries "$DOCS" 2>&1)" || consumer_local_rc=$?
case "$consumer_local_rc" in
  0)
    bad "docs-template が未配置の consumer-local review 入口を案内している"
    printf '%s\n' "$consumer_local_entries" >&2
    ;;
  1)
    ok "docs-template が未配置の consumer-local setup / multi-agent / multi-review を案内しない"
    ;;
  *)
    bad "docs-template の consumer-local review 入口を走査できない (rc=${consumer_local_rc})"
    printf '%s\n' "$consumer_local_entries" >&2
    ;;
esac

# `bash` 形式の root-qualified 実行例を載せる文書は、固定 root の取得・失効時停止を定める正本へ
# 自分から到達できなければならない。対象集合も固定し、文書単位のcommand消失や
# 無関係な文書へのcommand追加で検査対象が入れ替わる退行を検出する。
ROOT_PREREQUISITE_ANCHOR='ff-dev-toolkit-plugin-root-prerequisite'
ROOT_PREREQUISITE_TAG='<a id="ff-dev-toolkit-plugin-root-prerequisite"></a>'
ROOT_PREREQUISITE_DOC="$DOCS/05-operations/deployment/multi-cli-review-orchestration.md"
CI_REVIEW_DOC="$DOCS/05-operations/deployment/multi-cli-review-ci.md"
[ -f "$ROOT_PREREQUISITE_DOC" ] \
  || { echo "✗ plugin root 前提の正本文書が見つかりません: $ROOT_PREREQUISITE_DOC" >&2; exit 1; }
[ -f "$CI_REVIEW_DOC" ] \
  || { echo "✗ Multi-CLI CI 文書が見つかりません: $CI_REVIEW_DOC" >&2; exit 1; }
# shellcheck source=root-prerequisite-scan.sh
. "$SCRIPT_DIR/root-prerequisite-scan.sh"
root_command_docs=0
root_command_doc_entries=""
root_command_doc_rel_entries=""
root_command_doc_rc=0
root_command_doc_entries="$(
  grep -R -lE --include='*.md' \
    'bash[[:space:]]+"\$\{FF_DEV_TOOLKIT_ROOT\}/scripts/(setup-multi-agent|multi-agent|multi-review)\.sh"' \
    "$DOCS" 2>&1
)" || root_command_doc_rc=$?
case "$root_command_doc_rc" in
  0)
    while IFS= read -r root_command_doc; do
      root_command_docs=$((root_command_docs + 1))
      rel_root_command_doc="${root_command_doc#"$DOCS"/}"
      root_command_doc_rel_entries="${root_command_doc_rel_entries}${rel_root_command_doc}
"
      if root_prerequisite_reachable_before_command "$root_command_doc"; then
        ok "${rel_root_command_doc}: 最初の実行例より前に固定 plugin root の前提へ到達できる"
      else
        bad "${rel_root_command_doc}: 最初の実行例より前に有効な plugin root 前提 link / anchor が無い"
      fi
    done < <(printf '%s\n' "$root_command_doc_entries")
    ;;
  1)
    bad "固定 plugin root を使う実行例が 1 件も無い — 入口検査が空振りしている"
    ;;
  *)
    bad "固定 plugin root を使う文書一覧を走査できない (rc=${root_command_doc_rc})"
    printf '%s\n' "$root_command_doc_entries" >&2
    ;;
esac
expected_root_command_docs='05-operations/deployment/automated-code-review.md
05-operations/deployment/git-workflow.md
05-operations/deployment/multi-cli-agent-orchestration.md
05-operations/deployment/multi-cli-review-ci.md
05-operations/deployment/multi-cli-review-orchestration.md
05-operations/deployment/self-review.md
06-reference/REVIEW_AGENT_CREATION_GUIDE.md'
actual_root_command_docs="$(printf '%s' "$root_command_doc_rel_entries" | sed '/^$/d' | sort)"
if [ "$actual_root_command_docs" = "$expected_root_command_docs" ]; then
  ok "固定 plugin root の実行例を載せる文書集合が期待した7件と一致"
else
  bad "固定 plugin root の実行例を載せる文書集合が期待値と不一致（現在${root_command_docs}件）"
  printf 'expected:\n%s\nactual:\n%s\n' \
    "$expected_root_command_docs" "$actual_root_command_docs" >&2
fi

# 対話用の直接実行例は resolver fence と同じ Bash body でguardを再評価する。
# 行頭だけを見ず、`if ! bash` / `cd && bash` / `run: bash` も拾う。永続pre-pushと
# CIは同じ文書内の自己完結bootstrapをruntime suiteで検査するため、文書と節を限定して除外する。
unguarded_direct_commands="$(find "$DOCS" -type f -name '*.md' -exec awk '
  FNR == 1 { in_fence = 0; in_pre_push = 0 }
  /^###[[:space:]]/ { in_pre_push = ($0 == "### Husky pre-push フックとの統合") }
  /^```(bash|sh|zsh|yaml)[[:space:]]*$/ { in_fence = 1; next }
  /^```/ { in_fence = 0; next }
  in_fence && /"\$\{FF_DEV_TOOLKIT_ROOT\}\/scripts\/(setup-multi-agent|multi-agent|multi-review|check-closing-keywords)\.sh"/ {
    if ($0 ~ /^[[:space:]]*ff_require_toolkit_root && ff_require_consumer_root && bash /) next
    if (FILENAME ~ /\/multi-cli-review-ci\.md$/) next
    if (FILENAME ~ /\/multi-cli-review-orchestration\.md$/ && in_pre_push) next
    print FILENAME ":" FNR ":" $0
    }
' {} +)"
if [ -z "$unguarded_direct_commands" ]; then
  ok "対話用の直接実行例がtoolkit rootとconsumer rootを同じ行で再評価する"
else
  bad "guardなしのplugin root直接実行例がある"
  printf '%s\n' "$unguarded_direct_commands" >&2
fi
# 実行コマンドは root-qualified な正準形だけを許可する。文書一覧を正しい prefix から
# 導出する検査だけでは、絶対 cache path や CLAUDE_PLUGIN_ROOT へ丸ごと置換された文書が
# 対象から脱落するため、resource 名から逆向きにも列挙して照合する。
review_resource_commands=""
review_resource_command_rc=0
review_resource_commands="$(
  find "$DOCS" -type f -name '*.md' -exec awk '
    /(^|[^[:alnum:]_.-])(\/[^[:space:]]*\/)?(bash|sh|zsh|command|exec|env|source)([[:space:]]+[^[:space:]]+)*[[:space:]]+[^[:space:]]*\/(setup-multi-agent|multi-agent|multi-review)\.sh([^[:alnum:]_.-]|$)/ \
      || /(^|[[:space:]|;])(test[[:space:]]+|\[[[:space:]]+)-[frsx][[:space:]]+[^[:space:]]*\/(setup-multi-agent|multi-agent|multi-review)\.sh([^[:alnum:]_.-]|$)/ \
      || /^[[:space:]]*(([-+*]|[0-9]+[.)])[[:space:]]+)?"?(\$\{[^}]+\}|\/)[^[:space:]"`]*\/scripts\/(setup-multi-agent|multi-agent|multi-review)\.sh"?([^[:alnum:]_.-]|$)/ {
        print FILENAME ":" FNR ":" $0
    }
  ' {} + 2>&1
)" || review_resource_command_rc=$?
case "$review_resource_command_rc" in
  0)
    if [ -n "$review_resource_commands" ]; then
      while IFS= read -r review_resource_command; do
        # 同じ行の後方やコメントへ正準形を足しても、前方の別rootを隠せないように
        # 正準pathをすべて除いてからresource参照が残るかを判定する。
        unquoted_review_resource="$(printf '%s\n' "$review_resource_command" | sed \
          -e 's#"${FF_DEV_TOOLKIT_ROOT}/scripts/setup-multi-agent\.sh"##g' \
          -e 's#"${FF_DEV_TOOLKIT_ROOT}/scripts/multi-agent\.sh"##g' \
          -e 's#"${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review\.sh"##g')"
        residual_review_resource="$(printf '%s\n' "$review_resource_command" | sed \
          -e 's#${FF_DEV_TOOLKIT_ROOT}/scripts/setup-multi-agent\.sh##g' \
          -e 's#${FF_DEV_TOOLKIT_ROOT}/scripts/multi-agent\.sh##g' \
          -e 's#${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review\.sh##g')"
        if printf '%s\n' "$unquoted_review_resource" | grep -Eq \
          '\$\{FF_DEV_TOOLKIT_ROOT\}/scripts/(setup-multi-agent|multi-agent|multi-review)\.sh' \
          || printf '%s\n' "$residual_review_resource" | grep -Eq \
          '/(setup-multi-agent|multi-agent|multi-review)\.sh([^[:alnum:]_.-]|$)'; then
          bad "review resource command が固定 root の引用付き正準形ではない: ${review_resource_command}"
        fi
      done < <(printf '%s\n' "$review_resource_commands")
      ok "setup / multi-agent / multi-review の実行コマンドをresource名から逆引きして検査"
    else
      bad "setup / multi-agent / multi-review の実行コマンドが1件も無い"
    fi
    ;;
  *)
    bad "review resource command を走査できない (rc=${review_resource_command_rc})"
    printf '%s\n' "$review_resource_commands" >&2
    ;;
esac

# root-qualified command は1行の引用付き正準形だけを許可する。`bash \` の次行へ
# 未引用 path を逃がすと、空白を含む plugin root で壊れるうえ上の行単位検査を抜ける。
multiline_root_commands=""
multiline_root_command_rc=0
multiline_root_commands="$(find "$DOCS" -type f -name '*.md' -exec awk '
  FNR == 1 { in_shell_continuation = 0 }
  in_shell_continuation {
    if ($0 ~ /\/(setup-multi-agent|multi-agent|multi-review)\.sh([^[:alnum:]_.-]|$)/) {
      print FILENAME ":" FNR ":" $0
    }
    if ($0 !~ /\\[[:space:]]*$/) { in_shell_continuation = 0 }
    next
  }
  /(^|[^[:alnum:]_.\/-])(bash|sh|zsh)([[:space:]]+[^[:space:]\\]+)*[[:space:]]*\\[[:space:]]*$/ {
    in_shell_continuation = 1
  }
' {} + 2>&1)" || multiline_root_command_rc=$?
if [ "$multiline_root_command_rc" -ne 0 ]; then
  bad "複数行 review resource command を走査できない (rc=${multiline_root_command_rc})"
  printf '%s\n' "$multiline_root_commands" >&2
elif [ -n "$multiline_root_commands" ]; then
  bad "review resource command を複数行に分割している — 引用付き1行の正準形を使う"
  printf '%s\n' "$multiline_root_commands" >&2
else
  ok "review resource command に複数行へ分割した非正準形が無い"
fi

# skill側の handoff 文言統一は plugin-root-contract suite が全resource参照skillと
# mutationで担う。host情報からrootを実際に解決する動作はdocs-gates-runtimeが担い、
# ここでは配布文書が同じ2経路と再探索禁止を欠落させないことを照合する。
if grep -qF 'ff_canonical_toolkit_root "$CLAUDE_PLUGIN_ROOT"' "$ROOT_PREREQUISITE_DOC" \
  && grep -qF 'FF_DEV_TOOLKIT_SKILL_FILE' "$ROOT_PREREQUISITE_DOC" \
  && grep -qF 'handoff の producer は skill を実行する AI host' "$ROOT_PREREQUISITE_DOC" \
  && grep -qF 'FF_DEV_TOOLKIT_SKILL_FILE="<skill loader が返したこの SKILL.md の絶対パス>"; export FF_DEV_TOOLKIT_SKILL_FILE' "$ROOT_PREREQUISITE_DOC" \
  && grep -qF 'FF_DEV_TOOLKIT_PROJECT_ROOT="<AI host の task workspace repository root>"; export FF_DEV_TOOLKIT_PROJECT_ROOT' "$ROOT_PREREQUISITE_DOC" \
  && grep -qF '実際に読み込んだ ff-dev-toolkit skill の絶対 `SKILL.md` パス' "$ROOT_PREREQUISITE_DOC" \
  && grep -qF 'skill_dir="$(dirname "$FF_DEV_TOOLKIT_SKILL_FILE")"' "$ROOT_PREREQUISITE_DOC" \
  && grep -qF '$(basename "$skills_dir")" != skills' "$ROOT_PREREQUISITE_DOC" \
  && grep -qF 'キャッシュ全体を探索したり、version 名を並べ替えて別版へ切り替えたりしない' "$ROOT_PREREQUISITE_DOC"; then
  ok "配布文書がClaude/Codexの固定root解決と別version再探索禁止をskill契約に合わせている"
else
  bad "配布文書のhost別plugin root解決がskill契約からdriftしている"
fi

if grep -qF 'ff-dev-toolkitのhandoffを再構成してください' "$ROOT_PREREQUISITE_DOC" \
  && grep -qF 'ff_require_toolkit_root()' "$ROOT_PREREQUISITE_DOC" \
  && grep -qF 'for resource in setup-multi-agent.sh multi-agent.sh multi-review.sh check-closing-keywords.sh' "$ROOT_PREREQUISITE_DOC" \
  && grep -qF 'check-merge-freshness.sh update-version-claim.sh check-version-claims.sh; do' "$ROOT_PREREQUISITE_DOC" \
  && grep -qF '[ ! -f "$resource_path" ]' "$ROOT_PREREQUISITE_DOC" \
  && grep -qF '[ ! -r "$resource_path" ]' "$ROOT_PREREQUISITE_DOC" \
  && grep -qF '[ ! -s "$resource_path" ]' "$ROOT_PREREQUISITE_DOC" \
  && grep -qF '[ -L "${host_root}/scripts" ]' "$ROOT_PREREQUISITE_DOC" \
  && grep -qF 'ff_has_toolkit_manifest_marker()' "$ROOT_PREREQUISITE_DOC" \
  && grep -qF 'return 2' "$ROOT_PREREQUISITE_DOC" \
  && grep -qF 'FF_DEV_TOOLKIT_ROOT_SOURCE=host' "$ROOT_PREREQUISITE_DOC" \
  && grep -qF 'export FF_DEV_TOOLKIT_ROOT' "$ROOT_PREREQUISITE_DOC"; then
  ok "固定 plugin root の前提が相対path・未設定・resource 消失を案内付きで停止する"
else
  bad "固定 plugin root の前提に相対path・未設定・resource 消失の fail-closed guard が無い"
fi

if grep -qF 'sidecar は Git 管理せず' "$ROOT_PREREQUISITE_DOC" \
  && grep -qF 'toolkit 更新後に setup を再実行' "$ROOT_PREREQUISITE_DOC" \
  && grep -qF 'versioned cache を探索・選択する設定として手書きしない' "$ROOT_PREREQUISITE_DOC" \
  && grep -qF '上の対話用 resolver fence は呼ばず' "$ROOT_PREREQUISITE_DOC"; then
  ok "対話skillと永続hook/CIのroot固定ライフサイクルを区別している"
else
  bad "対話skillと永続hook/CIのroot固定ライフサイクルが曖昧"
fi

if grep -qF '消費プロジェクトの repository root' "$ROOT_PREREQUISITE_DOC" \
  && grep -qF 'ff_require_consumer_root()' "$ROOT_PREREQUISITE_DOC" \
  && grep -qF 'git rev-parse --show-toplevel' "$ROOT_PREREQUISITE_DOC" \
  && grep -qF 'review対象がhostのtask workspace repository rootと一致しません' "$ROOT_PREREQUISITE_DOC" \
  && grep -qF '別 repository や repository 外' "$ROOT_PREREQUISITE_DOC"; then
  ok "絶対path実行でもレビュー対象CWDを消費project rootへ固定している"
else
  bad "plugin絶対path実行時のレビュー対象CWD契約が無い"
fi

if grep -qF 'ff_require_toolkit_root && ff_require_consumer_root && bash "${FF_DEV_TOOLKIT_ROOT}/scripts/check-closing-keywords.sh"' \
    "$DOCS/05-operations/deployment/git-workflow.md" \
  && grep -qF 'check-closing-keywords.sh' "$ROOT_PREREQUISITE_DOC"; then
  ok "Git Workflowのclosing keyword検査も同じroot guardで保護される"
else
  bad "Git Workflowのclosing keyword検査がroot guard契約から外れている"
fi

if grep -qF 'FF_DEV_TOOLKIT_REF: <REVIEWED_COMMIT_SHA>' "$CI_REVIEW_DOC" \
  && grep -qF '^[0-9a-f]{40}$' "$CI_REVIEW_DOC" \
  && grep -qF 'checkout_head="$(git -C .ff-dev-toolkit-source rev-parse HEAD)"' "$CI_REVIEW_DOC" \
  && grep -qF '[ "$checkout_head" != "$FF_DEV_TOOLKIT_REF" ]' "$CI_REVIEW_DOC" \
  && grep -qF '"$RUNNER_TEMP/ff-dev-toolkit" >> "$GITHUB_ENV"' "$CI_REVIEW_DOC" \
  && grep -qF 'permissions:' "$CI_REVIEW_DOC" \
  && grep -qF 'contents: read' "$CI_REVIEW_DOC" \
  && grep -qF 'repository: feel-flow/ff-dev-toolkit' "$CI_REVIEW_DOC" \
  && grep -qF 'ref: ${{ env.FF_DEV_TOOLKIT_REF }}' "$CI_REVIEW_DOC" \
  && grep -qF 'path: .ff-dev-toolkit-source' "$CI_REVIEW_DOC" \
  && grep -qF 'cp -R .ff-dev-toolkit-source/plugins/ff-dev-toolkit "$FF_DEV_TOOLKIT_ROOT"' "$CI_REVIEW_DOC" \
  && grep -qF 'rm -rf -- .ff-dev-toolkit-source' "$CI_REVIEW_DOC" \
  && grep -qF 'persist-credentials: false' "$CI_REVIEW_DOC" \
  && grep -qF 'if: github.event.pull_request.head.repo.full_name == github.repository' "$CI_REVIEW_DOC" \
  && grep -qF 'pull_request_target' "$CI_REVIEW_DOC" \
  && grep -qF 'for resource in setup-multi-agent.sh multi-agent.sh multi-review.sh' "$CI_REVIEW_DOC" \
  && grep -qF '[ -L "$resource_path" ]' "$CI_REVIEW_DOC" \
  && grep -qF '[ -L "${FF_DEV_TOOLKIT_ROOT}/scripts" ]' "$CI_REVIEW_DOC" \
  && grep -qF 'Pinned ff-dev-toolkit resource is invalid' "$CI_REVIEW_DOC" \
  && grep -qF 'fetch-depth: 0' "$CI_REVIEW_DOC" \
  && grep -qF -- '--config "${FF_DEV_TOOLKIT_ROOT}/scripts/agent-config.yaml"' "$CI_REVIEW_DOC" \
  && grep -qF -- '--output-dir "$FF_REVIEW_OUTPUT"' "$CI_REVIEW_DOC" \
  && grep -qF 'PR_BASE_REF: ${{ github.base_ref }}' "$CI_REVIEW_DOC" \
  && grep -qF -- '--base "origin/${PR_BASE_REF}"' "$CI_REVIEW_DOC" \
  && grep -qF 'Verify integrated review report' "$CI_REVIEW_DOC" \
  && grep -qF '[ ! -f "$report" ] || [ -L "$report" ] || [ ! -s "$report" ]' "$CI_REVIEW_DOC" \
  && grep -qF '<!-- CRITICAL_BLOCK -->' "$CI_REVIEW_DOC" \
  && grep -qF 'if-no-files-found: error' "$CI_REVIEW_DOC" \
  && grep -qF 'path: ${{ runner.temp }}/ff-review-results/' "$CI_REVIEW_DOC" \
  && grep -qF 'environment: ai-review' "$CI_REVIEW_DOC" \
  && ! grep -qF 'continue-on-error: true' "$CI_REVIEW_DOC" \
  && ! grep -qF 'FF_DEV_TOOLKIT_ROOT: ${{ runner.temp }}' "$CI_REVIEW_DOC" \
  && ! grep -qF 'FF_REVIEW_OUTPUT: ${{ runner.temp }}' "$CI_REVIEW_DOC" \
  && ! grep -qF 'uses: actions/checkout@v4' "$CI_REVIEW_DOC" \
  && ! grep -qF 'uses: actions/upload-artifact@v4' "$CI_REVIEW_DOC"; then
  ok "CI例がreview済みrefを配置し全resourceをfail-closed検証する"
else
  bad "CI例のpin配置または全resource検証が不完全"
fi

ci_upload_condition_count="$(awk '
  /^      - name: Upload results$/ { in_upload = 1; next }
  in_upload && /^      - (name:|uses:)/ { in_upload = 0 }
  in_upload && /if: \$\{\{ always\(\) && steps\.multi_cli_review\.conclusion != '\''skipped'\'' \}\}/ { count++ }
  END { print count + 0 }
' "$CI_REVIEW_DOC")"
ci_review_always_count="$(awk '
  /^      - name: Run Multi-CLI Review$/ { in_review = 1; next }
  in_review && /^      - (name:|uses:)/ { in_review = 0 }
  in_review && /always\(\)/ { count++ }
  END { print count + 0 }
' "$CI_REVIEW_DOC")"
if grep -qE '^on:$' "$CI_REVIEW_DOC" \
  && grep -qE '^  pull_request:$' "$CI_REVIEW_DOC" \
  && ! grep -qE '^  pull_request_target:' "$CI_REVIEW_DOC" \
  && grep -qE '^    if: github\.event\.pull_request\.head\.repo\.full_name == github\.repository$' "$CI_REVIEW_DOC" \
  && grep -qE '^        id: multi_cli_review$' "$CI_REVIEW_DOC" \
  && [ "$ci_upload_condition_count" -eq 1 ] \
  && [ "$ci_review_always_count" -eq 0 ]; then
  ok "CI例のtrigger・job fork境界・review/upload条件が正しいYAML階層にある"
else
  bad "CI例のtrigger・job fork境界・review/upload条件のYAML階層が不正"
fi

checkout_pin_count="$(grep -Ec 'uses: actions/checkout@[0-9a-f]{40}([[:space:]]|$)' \
  "$CI_REVIEW_DOC" || true)"
if [ "$checkout_pin_count" -eq 2 ] \
  && grep -Eq 'uses: actions/upload-artifact@[0-9a-f]{40}([[:space:]]|$)' "$CI_REVIEW_DOC" \
  && grep -qF 'npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"' "$CI_REVIEW_DOC" \
  && grep -qF 'npm install -g "@openai/codex@${CODEX_CLI_VERSION}"' "$CI_REVIEW_DOC" \
  && grep -qF 'npm install -g "@xai-official/grok@${GROK_CLI_VERSION}"' "$CI_REVIEW_DOC"; then
  ok "CI例がActions commitとCLI versionをpinする"
else
  bad "CI例のActionsまたはCLI version pinが不完全"
fi

if ! grep -qF 'IFS= read -r FF_TOOLKIT_SCRIPTS < scripts/.ff-dev-toolkit-root || true' \
    "$ROOT_PREREQUISITE_DOC" \
  && grep -qF 'sidecarを読み込めません' "$ROOT_PREREQUISITE_DOC"; then
  ok "pre-push例がsidecar読込失敗を握りつぶさず停止する"
else
  bad "pre-push例がsidecar読込失敗または部分値を成功扱いする"
fi

COPILOT_AGENTS_DOC="$DOCS/06-reference/COPILOT_AGENTS.md"
if grep -qF '<FF_DEV_TOOLKIT_ROOT>/scripts/' "$COPILOT_AGENTS_DOC" \
  && grep -qF 'plugin root だけに存在し、消費プロジェクトの `scripts/` へはコピーされない' \
    "$COPILOT_AGENTS_DOC" \
  && ! grep -qF 'scripts/multi-agent.sh` を使えば' "$COPILOT_AGENTS_DOC"; then
  ok "COPILOT_AGENTSの構成図がplugin同梱物とconsumer配置物を分離している"
else
  bad "COPILOT_AGENTSの構成図が未配置resourceをconsumer-localとして示している"
fi

# 固定文字列がファイルに存在することを要求する（修正パターンの実在検査）。
# ファイル自体が無い場合も loud に落とす（対象消失を pass と読まない）。
# 注意: needle が説明コメントにも現れる場合はこの関数ではなく must_match を使う。
must_contain() {
  local file="$1" needle="$2" label="$3"
  if [ ! -f "$DOCS/$file" ]; then
    bad "$label — 対象ファイルがありません: $file"
    return
  fi
  if grep -qF -- "$needle" "$DOCS/$file"; then
    ok "$label"
  else
    bad "$label — 期待パターンが見つかりません: $needle ($file)"
  fi
}

# 正規表現（ERE）がファイルに存在することを要求する。行頭アンカーで
# 「コード行そのもの」を特定したいときに使う。grep 自体の失敗（rc>=2）は
# 「不在」と区別して loud に落とす。
must_match() {
  local file="$1" regex="$2" label="$3" rc=0
  if [ ! -f "$DOCS/$file" ]; then
    bad "$label — 対象ファイルがありません: $file"
    return
  fi
  grep -qE -- "$regex" "$DOCS/$file" || rc=$?
  case "$rc" in
    0) ok "$label" ;;
    1) bad "$label — 期待パターンが見つかりません: $regex ($file)" ;;
    *) bad "$label — grep が失敗しました (rc=$rc): $regex ($file)" ;;
  esac
}

# 固定文字列がファイルに存在しないことを要求する（退行パターンの不在検査）。
# 負の主張なので、先にファイルの実在を確かめてから主張する。
must_not_contain() {
  local file="$1" needle="$2" label="$3" rc=0
  if [ ! -f "$DOCS/$file" ]; then
    bad "$label — 対象ファイルがありません: $file"
    return
  fi
  grep -qF -- "$needle" "$DOCS/$file" || rc=$?
  case "$rc" in
    0) bad "$label — 退行パターンが再出現しています: $needle ($file)" ;;
    1) ok "$label" ;;
    *) bad "$label — grep が失敗しました (rc=$rc): $needle ($file)" ;;
  esac
}

# 正規表現（ERE）がファイルに存在しないことを要求する。grep の失敗（rc>=2、
# 例: 不正な ERE・読めないファイル)を「不一致 = pass」と読まないよう
# rc を場合分けする（不在検査こそ fail-closed にする）。
must_not_match() {
  local file="$1" regex="$2" label="$3" rc=0
  if [ ! -f "$DOCS/$file" ]; then
    bad "$label — 対象ファイルがありません: $file"
    return
  fi
  grep -qE -- "$regex" "$DOCS/$file" || rc=$?
  case "$rc" in
    0) bad "$label — 退行パターンが再出現しています: $regex ($file)" ;;
    1) ok "$label" ;;
    *) bad "$label — grep が失敗しました (rc=$rc): $regex ($file)" ;;
  esac
}

echo "== docs-template ゲート例の fail-silent 退行検査 =="

# --- multi-cli-review-orchestration.md（Issue #152 / PR #153 の修正本体） ---
f="05-operations/deployment/multi-cli-review-orchestration.md"
must_contain "$f" 'if ! bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh"' \
  "pre-push 例がレビューの終了コードを検査している"
must_contain "$f" 'FF_REVIEW_OUTPUT="$(mktemp -d "${TMPDIR:-/tmp}/ff-pre-push-review.XXXXXX")"' \
  "pre-push 例が実行ごとの専用出力先を作成している"
must_contain "$f" '[ ! -s "$REVIEW_REPORT" ]' \
  "pre-push 例が統合レポートの存在を検査している（未生成を合格と読まない）"
must_contain "$f" 'grep -q "INCOMPLETE" "$REVIEW_REPORT"' \
  "pre-push 例が INCOMPLETE マーカーを検査している"
must_contain "$f" 'grep status ${grep_rc}' \
  "pre-push 例がgrep異常を不一致と区別して停止する"
must_contain "$f" 'IFS= read -r FF_TOOLKIT_SCRIPTS < "$FF_TOOLKIT_SIDECAR"' \
  "pre-push 例が定義済みsidecar変数と同じpathを読み込む"
must_not_contain "$f" 'rm -rf -- "$FF_REVIEW_OUTPUT"' \
  "pre-push 例が成功時のWarning/Suggestion成果物を削除しない"
must_contain "$f" 'echo "✅ レビュー完了。出力先: $FF_REVIEW_OUTPUT"' \
  "pre-push 例が成功時の保全済み出力先を案内する"
# 行頭アンカー必須: 直前の説明コメントに同じ文字列があるため、固定文字列検査だと
# YAML の実 directive を消してもコメントで合格してしまう
f="05-operations/deployment/multi-cli-review-ci.md"
must_contain "$f" 'if: ${{ always() && steps.multi_cli_review.conclusion != '\''skipped'\'' }}' \
  "CI 例がreview実行後の失敗回だけ成果物を回収する"
must_contain "$f" 'if-no-files-found: error' \
  "CI 例がreview成果物の欠落をupload成功にしない"
must_contain "$f" '--config "${FF_DEV_TOOLKIT_ROOT}/scripts/agent-config.yaml"' \
  "CI 例がPR headのproject configではなくpin済みtoolkit configを使う"
must_contain "$f" '--output-dir "$FF_REVIEW_OUTPUT"' \
  "CI 例がreview出力先をrunner tempのartifact回収先へ固定する"
must_not_contain "$f" '--output-dir "$GITHUB_WORKSPACE/.review-results"' \
  "CI 例がPR管理下workspaceをreview出力先にしない"
must_not_contain "$f" 'FF_REVIEW_OUTPUT: ${{ runner.temp }}' \
  "CI 例がworkflow-level envで利用不能なrunner contextを参照しない"
must_contain "$f" 'PR_BASE_REF: ${{ github.base_ref }}' \
  "CI 例がPRのbase branchをenv経由でshellへ渡す"
must_contain "$f" '--base "origin/${PR_BASE_REF}"' \
  "CI 例がPRのbase branchを明示する"
must_contain "$f" 'exact_semver=' \
  "CI 例がCLIとyqの可変tag・version rangeを拒否する"
must_contain "$f" 'YQ_SHA256 must be an exact reviewed sha256.' \
  "CI 例がyq binaryのreview済みsha256を要求する"
must_contain "$f" 'Verify integrated review report' \
  "CI 例が統合レポートを独立stepで検証する"
must_contain "$f" '[ ! -f "$report" ] || [ -L "$report" ] || [ ! -s "$report" ]' \
  "CI 例が統合レポート欠落・symlink・空を拒否する"

# --- ai-tools-integration.md: commit-msg フック例 ---
f="05-operations/deployment/ai-tools-integration.md"
must_contain "$f" 'if ! npx --no-install commitlint --edit' \
  "commit-msg 例が commitlint の終了コードを判定に入れている"
must_not_match "$f" '^[[:space:]]*npx --no-install commitlint' \
  "commit-msg 例に裸の commitlint 呼び出し（終了コード捨て）が無い"

# --- automated-code-review.md: 判定ロジック例 ---
f="05-operations/deployment/automated-code-review.md"
must_contain "$f" '[ ! -s "$REVIEW_RESULT" ]' \
  "判定例が結果ファイルの非空を検査している（未実行を合格と読まない)"
must_contain "$f" 'if ! grep -q "^## Verdict: APPROVED"' \
  "判定例が行頭アンカー付き肯定マーカーで合格を決めている（fail-closed）"
must_not_contain "$f" 'grep -qEi "REJECTED|Important Issues"' \
  "旧・厳格モードの「否定マーカーが無ければ合格」判定が再出現していない"
must_not_contain "$f" 'grep -qEi "REJECTED"' \
  "旧・緩和モードの「REJECTED が無ければ合格」判定が再出現していない"
must_contain "$f" "sed -n '/^## Important Issues/" \
  "厳格モードがセクション抽出（変数受け）で判定している"
must_contain "$f" 'REVIEW_STRICT' \
  "厳格モードが選択可能なノブ（REVIEW_STRICT）として残っている"
must_contain "$f" 'if ! STAGED_FILES=$(git diff --cached --name-only)' \
  "除外スニペットが git diff の失敗とステージ空を区別している"
must_not_contain "$f" '|| true)' \
  "除外スニペットの grep 失敗を || true で丸める形が再出現していない"

# --- REVIEW_AGENT_CREATION_GUIDE.md: アダプター骨格 ---
f="06-reference/REVIEW_AGENT_CREATION_GUIDE.md"
# echo プレフィックス込みの行頭アンカー: `Status: incomplete` はコメント・散文・
# チェックリストにも現れるため、裸の固定文字列検査は骨格のコード行を消しても
# 合格してしまう
must_match "$f" '^[[:space:]]*echo "<!-- Status: incomplete -->"' \
  "アダプター骨格が機械判定契約のヘッダーマーカーを出力する"
must_match "$f" '^[[:space:]]*echo "## INCOMPLETE"' \
  "アダプター骨格が INCOMPLETE バナー付き部分出力を残す"
must_contain "$f" 'if ! {cli} -p "$PROMPT"' \
  "アダプター骨格が CLI の終了コードを握らず失敗経路へ分岐する"
must_contain "$f" '[ ! -s "$OUTPUT_FILE" ]' \
  "アダプター骨格が exit 0 + 空出力を「完走」と読まない"
must_contain "$f" '`multi-agent.sh` の `ALL_CLIS` と `get_cli_*` 関数を更新' \
  "新CLI追加ガイドが実行時レジストリの正本を案内する"
must_not_contain "$f" 'project `.claude/agent-config.yaml` または plugin 同梱 `agent-config.yaml` に新CLIエントリを追加' \
  "新CLI追加ガイドが非実行設定を登録先として案内しない"
must_contain "$f" '`FF_DEV_TOOLKIT_ROOT` 未指定時は、cache全体のSemVer最大版をsidecarより優先' \
  "shimガイドが固定rootを含む実際の選択優先順位を説明する"

f="05-operations/deployment/multi-cli-review-orchestration.md"
must_contain "$f" '`version: "2.0"` のときだけ `tasks.<task>.{mode,cost_strategy,timeout,output_dir}`' \
  "設定Noteがtasks.*のversion 2.0条件を明記する"

# --- 06-reference/DECISIONS.md: ADR 番号の重複と見出し ↔ 決定ログ表の不一致（OBS-066 昇格）---
# ADR 番号は共有台帳のグローバル連番なので、並行セッションが同日に採番すると衝突する。
# rebase 競合で気付けるのは挿入位置がたまたま重なったときだけで、別位置へ挿入されていれば
# 機械マージが通り同番号の ADR が 2 本並ぶ。判定本体は adr-number-scan.sh に置き、
# 配布テンプレート（${DOCS}。導入先へ配られる雛形）と正本（リポジトリ docs/）の両方へ当てる。
# 対象 2 文書が緑なだけでは「検査が効いている」の証明にならないので、検出器が空振りして
# いないことを fixture で先に固定する（重複・両方向の不一致・抽出不能）。
# shellcheck source=adr-number-scan.sh
. "$SCRIPT_DIR/adr-number-scan.sh"

ADR_FIXTURES="$SCRIPT_DIR/fixtures/adr-numbers"

adr_scan_case() { # $1: fixture 名 / $2: 期待 rc / $3: 出力に要る文字列（空なら不問）/ $4: 説明
  local fixture="$ADR_FIXTURES/$1.md" expected_rc="$2" needle="$3" label="$4"
  local out
  local rc=0
  if [ ! -f "$fixture" ]; then
    bad "${label} — fixture が見つかりません: ${fixture}"
    return
  fi
  out="$(ff_adr_number_scan "$fixture")" || rc=$?
  if [ "$rc" -ne "$expected_rc" ]; then
    bad "${label} — rc=${rc}（期待 ${expected_rc}）"
    printf '%s\n' "$out" >&2
    return
  fi
  if [ -n "$needle" ]; then
    case "$out" in
      *"$needle"*) : ;;
      *)
        bad "${label} — 出力が ${needle} を名指ししていません"
        printf '%s\n' "$out" >&2
        return
        ;;
    esac
  fi
  ok "$label"
}

adr_scan_case clean 0 "" \
  "ADR 番号検査: 整合した DECISIONS を通す（フェンス内の雛形・例示を名簿へ入れない。見出し側・表側の双方）"
adr_scan_case duplicate-heading 1 "duplicate-heading: ADR-002" \
  "ADR 番号検査: 同番号の見出し 2 本を非 0 で名指しする"
adr_scan_case duplicate-table 1 "duplicate-table: ADR-002" \
  "ADR 番号検査: 決定ログ表の同番号 2 行を非 0 で名指しする"
adr_scan_case heading-only 1 "heading-only: ADR-002" \
  "ADR 番号検査: 見出しにあって決定ログ表に無い番号を列挙する"
adr_scan_case table-only 1 "table-only: ADR-002" \
  "ADR 番号検査: 決定ログ表にあって見出しが無い番号を列挙する"
adr_scan_case no-log-section 2 "決定ログ表" \
  "ADR 番号検査: 決定ログ節を失った文書を fail-closed で落とす（表側の抽出不能を名指しする）"
adr_scan_case no-headings 2 "ADR 見出し" \
  "ADR 番号検査: 見出しが無く決定ログ表だけの文書を fail-closed で落とす（見出し側の抽出不能を名指しする）"
adr_scan_case table-outside-log-section 0 "" \
  "ADR 番号検査: 決定ログ節の外にある比較表の番号を走査対象に含めない"
adr_scan_case zero-pad-match 0 "" \
  "ADR 番号検査: 見出しのゼロ埋め表記と表の非ゼロ埋め表記を同一番号として一致させる"
adr_scan_case zero-pad-duplicate 1 "duplicate-table: ADR-048" \
  "ADR 番号検査: 決定ログ表のゼロ埋め有無違いの表記を正規化後の重複として名指しする"

adr_scan_doc() { # $1: 表示名 / $2: DECISIONS.md のパス
  local label="$1" doc="$2"
  local out
  local rc=0
  out="$(ff_adr_number_scan "$doc")" || rc=$?
  case "$rc" in
    0) ok "${label} の ADR 番号が重複無し・見出しと決定ログ表で一致" ;;
    1)
      bad "${label} の ADR 番号が整合していません（並行採番の衝突か表の追随漏れ）"
      printf '%s\n' "$out" >&2
      ;;
    *)
      bad "${label} の ADR 番号を照合できません (rc=${rc})"
      printf '%s\n' "$out" >&2
      ;;
  esac
}

adr_scan_doc "docs-template/06-reference/DECISIONS.md" "$DOCS/06-reference/DECISIONS.md"
# 正本（リポジトリ docs/）は公開 checkout には無いので、存在するときだけ当てる。
REPO_DECISIONS="$PLUGIN_ROOT/../../docs/06-reference/DECISIONS.md"
if [ -f "$REPO_DECISIONS" ]; then
  adr_scan_doc "docs/06-reference/DECISIONS.md" "$REPO_DECISIONS"
fi

# --- 04-quality/TESTING.md: CI 例 ---
must_match "04-quality/TESTING.md" '^[[:space:]]*if: always\(\)[[:space:]]*$' \
  "TESTING.md の CI 例が失敗回でもカバレッジを回収する（if: always() の実 directive）"

# --- 04-quality/TESTING.md: 変異注入の適用確認（Issue #628） ---
# 変異が当たらなくても「テストが緑」は検出失敗と同じ出力になるため、適用確認の
# 規範が節ごと消える退行を固定する。針は本文の主張そのもの（散文アンカー）と、
# 良い例の実コード行（出現回数の検査・適用失敗で後続へ進まない分岐）の両方で持つ。
f="04-quality/TESTING.md"
must_contain "$f" '**変異が実際に適用されたことを機械的に確認してから**結果を読む' \
  "TESTING.md の変異注入節が適用確認を先に要求している"
must_contain "$f" "クォート済みヒアドキュメント（\`<<'PY'\`）でファイルへ書き出してから実行する" \
  "TESTING.md の変異注入節がシェル補間を禁止しヒアドキュメント化を要求している"
must_contain "$f" '適用に失敗したら非 0 で即座に落とす' \
  "TESTING.md の変異注入節が出現回数検査と非 0 即停止を要求している"
must_contain "$f" '「変異が当たらなかった」と「変異が検出されなかった」を出力から区別できる形にする' \
  "TESTING.md の変異注入節が適用の成否と検査結果の併記を要求している"
must_contain "$f" 'if s.count("needle\n") != 1:' \
  "TESTING.md の良い例が出現回数を明示分岐で検査している（assert は -O で消えるため不可）"
must_match "$f" '^[[:space:]]*python3 "\$MUT" \|\| exit 1' \
  "TESTING.md の良い例が適用失敗で後続の検査へ進まない（|| exit 1 の実コード行）"

# 正本（リポジトリ docs/）と配布テンプレートの節同期。上の針はすべて $DOCS =
# docs-template 側にしか掛からないため、正本側だけのリライトは針では捕まらない。
# 公開 checkout には正本（docs/04-quality/TESTING.md）が無いので、存在するときだけ
# 突き合わせる（不在は skip であって欠陥ではない）。
REPO_TESTING="$PLUGIN_ROOT/../../docs/04-quality/TESTING.md"
if [ -f "$REPO_TESTING" ]; then
  extract_mutation_section() {
    awk '/^### 変異注入の適用確認$/ { f = 1 }
         f && !/^### 変異注入の適用確認$/ && (/^## / || /^### /) { exit }
         f { print }' "$1"
  }
  repo_section="$(extract_mutation_section "$REPO_TESTING")"
  tmpl_section="$(extract_mutation_section "$DOCS/04-quality/TESTING.md")"
  if [ -z "$repo_section" ] || [ -z "$tmpl_section" ]; then
    bad "「変異注入の適用確認」節の抽出が空です（見出しの改名か節の削除。fail-closed）"
  elif [ "$repo_section" = "$tmpl_section" ]; then
    ok "「変異注入の適用確認」節が正本（docs/）と配布テンプレートで一致"
  else
    bad "「変異注入の適用確認」節が正本（docs/04-quality/TESTING.md）と配布テンプレートで乖離している"
  fi
fi

# --- 04-quality/TESTING.md: 節スコープ照合の consumer 名簿 ↔ 実体 ---
# TESTING.md は「移行済みの consumer suite は次の N 件」と表で名簿を持つが、これを
# 強制するゲートが無いと、次に tests/lib/section-scope.sh を source する suite を
# 足した時点で黙って drift する（`adapter-env-isolation-selftest` の consumer_roster に
# 相当するものが section-scope 側には無い。2026-09 のレビュー指摘）。実体は
# **source 行そのもの**で数える — 文字列一致だけだと、lib を fixture へ写すだけの
# selftest（cp するパス文字列を持つ）まで consumer に数えてしまう。
if [ -f "$REPO_TESTING" ]; then
  ss_actual="$(
    for _ss_v in "$PLUGIN_ROOT"/tests/*/verify.sh; do
      [ -f "$_ss_v" ] || continue
      if awk '/^\.[[:space:]].*lib\/section-scope\.sh/ { found = 1 } END { exit found ? 0 : 1 }' "$_ss_v"; then
        _ss_d="${_ss_v%/verify.sh}"
        printf '%s\n' "${_ss_d##*/}"
      fi
    done | LC_ALL=C sort
  )"
  ss_listed="$(awk '
    index($0, "移行済みの consumer suite は次の") == 1 { f = 1; next }
    f == 0 { next }
    /^\|/ {
      intab = 1
      if ($0 ~ /^\|[[:space:]]*suite[[:space:]]*\|/) next
      if ($0 ~ /^\|[[:space:]]*-/) next
      name = $0
      sub(/^\|[[:space:]]*`/, "", name)
      sub(/`.*/, "", name)
      if (name != "") print name
      next
    }
    intab == 1 { exit }
  ' "$REPO_TESTING" | LC_ALL=C sort)"
  ss_declared="$(awk '
    index($0, "移行済みの consumer suite は次の") == 1 {
      n = $0
      sub(/^.*次の /, "", n)
      sub(/ 件.*/, "", n)
      print n
      exit
    }
  ' "$REPO_TESTING")"

  if [ -z "$ss_actual" ] || [ -z "$ss_listed" ]; then
    bad "節スコープ照合の consumer 名簿を突き合わせられません（実体 or 表の抽出が空。見出し・表書式の変更。fail-closed）"
  elif [ "$ss_actual" = "$ss_listed" ]; then
    ok "TESTING.md の節スコープ consumer 一覧が実体（section-scope.sh を source する suite）と一致"
  else
    bad "TESTING.md の節スコープ consumer 一覧が実体と乖離しています（表を更新すること）"
    printf '      表のみ: %s\n' "$(comm -13 <(printf '%s\n' "$ss_actual") <(printf '%s\n' "$ss_listed") | tr '\n' ' ')" >&2
    printf '      実体のみ: %s\n' "$(comm -23 <(printf '%s\n' "$ss_actual") <(printf '%s\n' "$ss_listed") | tr '\n' ' ')" >&2
  fi

  ss_actual_n=0
  [ -z "$ss_actual" ] || ss_actual_n="$(printf '%s\n' "$ss_actual" | wc -l | tr -d ' ')"
  case "$ss_declared" in
    ''|*[!0-9]*)
      bad "TESTING.md の節スコープ consumer 件数を読み取れません（「次の N 件」の書式変更。fail-closed）"
      ;;
    *)
      if [ "$ss_declared" -eq "$ss_actual_n" ]; then
        ok "TESTING.md の節スコープ consumer 件数が実体と一致（${ss_actual_n} 件）"
      else
        bad "TESTING.md の節スコープ consumer 件数 ${ss_declared} が実体 ${ss_actual_n} と一致しません"
      fi
      ;;
  esac
fi

# --- 04-quality/TESTING.md: 新規 suite 追加の随伴先一覧（suite 追加の追随漏れ対策） ---
# 随伴先を1箇所へ集約した一覧が、追随先の行を保っていることを固定する。表の行と
# 実体（各追随先の識別子）を突き合わせる術が無いため、行ごとに散文の言い換えでは
# 消えない固有語（配列名・宣言文言・suite名・ファイルパス）を針として持つ。一覧から
# 1行を落とす退行を検出するのが目的で、針が1つでも欠ければ「何かの行が消えた」と
# 読める（実測は PR 本文へ記録する）。
if [ -f "$REPO_TESTING" ]; then
  extract_followups_section() {
    awk '/^### 新規 suite 追加の随伴先$/ { f = 1 }
         f && !/^### 新規 suite 追加の随伴先$/ && (/^## / || /^### /) { exit }
         f { print }' "$1"
  }
  followups_section="$(extract_followups_section "$REPO_TESTING")"
  if [ -z "$followups_section" ]; then
    bad "「新規 suite 追加の随伴先」節が見つかりません（見出しの改名か節の削除。fail-closed）"
  else
    followups_missing=()
    while IFS= read -r _fu_needle; do
      [ -n "$_fu_needle" ] || continue
      case "$followups_section" in
        *"$_fu_needle"*) : ;;
        *) followups_missing+=("$_fu_needle") ;;
      esac
    done <<'FOLLOWUP_NEEDLES'
SCRIPTS` 配列
run-all-required: yes/no
adapter-env-isolation-selftest
section-scope.sh
docs-fact-drift
npm ci の前提
8 件の明示許可
weekly-run-all.yml
FOLLOWUP_NEEDLES
    if [ "${#followups_missing[@]}" -eq 0 ]; then
      ok "「新規 suite 追加の随伴先」節が随伴先 8 件をすべて保持"
    else
      bad "「新規 suite 追加の随伴先」節から随伴先が欠落しています:"
      printf '    %s\n' "${followups_missing[@]}" >&2
    fi
  fi
fi

# --- 04-quality/TESTING.md: 必須 suite 名簿 ↔ run-all.sh の REQUIRED_SUITES ---
# TESTING.md「一時領域依存 suite の skip 方針」の bullet 名簿は REQUIRED_SUITES の
# 人手の写しで、これまで機械ゲートが無かった。実際に片側だけ更新した drift が起きて
# いる（同文書 1.x の Changelog）。名簿から 1 行落としても suite は走り続けるので、
# 見た目には何も起きない = 最も気づきにくい形で文書だけが腐る。
#
# 実体は `run-all.sh` の `REQUIRED_SUITES` 配列を **静的に読む**。run-all.sh は
# `FF_RUN_ALL_DUMP_DECLARATIONS=1` で導出材料をダンプする口を持つが、docs-gates は
# 一時ファイルを作らない読み取り専用 suite なので、外部プロセスを起こさない静的読みを
# 採る。名簿が写しているのは `REQUIRED_SUITES` そのもので、導出集合との整合は
# run-all.sh 自身が毎回照合しているため、docs 側は配列と一致すれば十分。
if [ -f "$REPO_TESTING" ]; then
  # 配列内の各行を分類する。裸名 / "裸名" / '裸名'（前後空白・末尾 # コメント許容）を
  # OK、コメント行・空行は無視、それ以外（1 行複数要素・書式崩れ等）は BAD として
  # 拾う。BAD が 1 件でもあれば黙って読み飛ばさず fail-closed にする。
  rq_awk_out="$(awk '
    /^REQUIRED_SUITES=\($/ { f = 1; next }
    f && /^\)[[:space:]]*$/ { exit }
    f {
      line = $0
      gsub(/^[[:space:]]+/, "", line)
      gsub(/[[:space:]]+$/, "", line)
      if (line == "") next
      if (line ~ /^#/) next
      sub(/[[:space:]]+#.*$/, "", line)
      gsub(/[[:space:]]+$/, "", line)
      if (line == "") next
      if (match(line, /^"[a-z0-9][a-z0-9-]*"$/)) {
        print "OK\t" substr(line, RSTART + 1, RLENGTH - 2)
        next
      }
      if (match(line, /^'"'"'[a-z0-9][a-z0-9-]*'"'"'$/)) {
        print "OK\t" substr(line, RSTART + 1, RLENGTH - 2)
        next
      }
      if (match(line, /^[a-z0-9][a-z0-9-]*$/)) {
        print "OK\t" line
        next
      }
      print "BAD\t" line
    }
  ' "$PLUGIN_ROOT/tests/run-all.sh")"
  rq_bad="$(printf '%s\n' "$rq_awk_out" | awk -F'\t' '$1 == "BAD" { print $2 }')"
  rq_actual="$(printf '%s\n' "$rq_awk_out" | awk -F'\t' '$1 == "OK" { print $2 }' | LC_ALL=C sort)"
  rq_listed="$(awk '
    /^### 一時領域依存 suite の skip 方針$/ { f = 1; next }
    f && /^#+[[:space:]]/ { exit }
    f && match($0, /^- `[a-z0-9][a-z0-9-]*`/) {
      print substr($0, RSTART + 3, RLENGTH - 4)
    }
  ' "$REPO_TESTING" | LC_ALL=C sort)"

  if [ -n "$rq_bad" ]; then
    bad "run-all.sh の REQUIRED_SUITES 配列内に想定外の形式の行があります（fail-closed）:"
    printf '      %s\n' "$rq_bad" >&2
  elif [ -z "$rq_actual" ] || [ -z "$rq_listed" ]; then
    bad "必須 suite 名簿を突き合わせられません（REQUIRED_SUITES 配列 or 名簿の抽出が空。書式・見出しの変更。fail-closed）"
  elif [ "$rq_actual" = "$rq_listed" ]; then
    ok "TESTING.md の必須 suite 名簿が run-all.sh の REQUIRED_SUITES と一致"
  else
    bad "TESTING.md の必須 suite 名簿が run-all.sh の REQUIRED_SUITES と乖離しています（名簿を更新すること）"
    printf '      名簿のみ: %s\n' "$(comm -13 <(printf '%s\n' "$rq_actual") <(printf '%s\n' "$rq_listed") | tr '\n' ' ')" >&2
    printf '      実体のみ: %s\n' "$(comm -23 <(printf '%s\n' "$rq_actual") <(printf '%s\n' "$rq_listed") | tr '\n' ' ')" >&2
  fi
fi

# --- CLI 別 reviewer ページ: timeout(1) ラッパーの取り残し（PR #153 の残骸） ---
# stock macOS に timeout(1) は無いので、コマンド例が直接それを呼ぶと利用者の手元で
# 動かない。散文中の言及（「timeout 120 ... は使えない」）は許容し、コマンド例と
# しての行頭 timeout 呼び出し（インデント・gtimeout・秒サフィックス変種を含む）
# のみを退行とみなす。
#
# ファイル名を直書きせず glob で回すのは、cursor-cli-reviewer.md を消したとき
# （issue #240）に「対象ファイルが無い」で red になったのと同じ更新漏れを、CLI を
# 増減するたびに繰り返さないため。対象が 0 件なら検査が空振りしているので落とす。
reviewer_pages=0
for reviewer_page in "$DOCS"/05-operations/deployment/*-cli-reviewer.md; do
  [ -f "$reviewer_page" ] || continue
  reviewer_pages=$((reviewer_pages + 1))
  rel="${reviewer_page#"$DOCS"/}"
  must_not_match "$rel" \
    '^[[:space:]]*g?timeout [0-9]+s? ' \
    "${rel##*/}: timeout(1) ラッパー（stock macOS に無い）が残っていない"
  # `-adapter.sh` を含むだけでは、gemini のページが codex のアダプタを案内していても
  # 通る。削除済みのアダプタ名（cursor-cli-adapter.sh）ですら通った。ページの CLI
  # 接頭辞から期待するアダプタ名を導き、その実在まで確認する。
  page_cli="${rel##*/}"; page_cli="${page_cli%-reviewer.md}"
  must_contain "$rel" "${page_cli}-adapter.sh" \
    "${rel##*/}: 自分の CLI のアダプタ（${page_cli}-adapter.sh）へ誘導している"
  if [ -f "$PLUGIN_ROOT/scripts/adapters/${page_cli}-adapter.sh" ]; then
    ok "${rel##*/}: 案内先のアダプタが実在する"
  else
    bad "${rel##*/}: 案内先のアダプタが存在しない: scripts/adapters/${page_cli}-adapter.sh"
  fi
done
if [ "$reviewer_pages" -gt 0 ]; then
  ok "*-cli-reviewer.md を ${reviewer_pages} 件検査した"
else
  bad "*-cli-reviewer.md が 1 件も見つからない — 検査が空振りしている"
fi

# --- DEPENDENCY_LINT.md: warn 設定のまま CI に載せる空振りへの注意 ---
must_contain "03-implementation/DEPENDENCY_LINT.md" '"severity": "error"' \
  "DEPENDENCY_LINT.md の config 例が forbidden ルールに severity: error を明記している"
must_contain "03-implementation/DEPENDENCY_LINT.md" '常に緑になる' \
  "DEPENDENCY_LINT.md の CI 例に warn 既定の空振り注意がある"

# --- health-check.md: 終了コードを持たない診断スクリプトのゲート化禁止注意 ---
must_contain "05-operations/organizational-rollout/health-check.md" '自動ゲートにコピーしない' \
  "health-check.md §1 に自動ゲート化禁止の注意がある"
must_contain "05-operations/organizational-rollout/health-check.md" 'が非空であることを確認' \
  "health-check.md §4 に中間ファイル空振りの注意がある"

# --- Windows 記述が doc セット内で矛盾しないこと ---
# 配布物は端から端まで bash なので Windows ネイティブは非対応。初学者向け文書が
# 「コマンドプロンプトで実行」と読める状態は、いちばん踏まれやすい。
# 語だけを見ると、本文の別箇所（コード内コメント等）に同じ語が残っているだけで
# 通ってしまう（実測: 相互参照リンクを消しても緑のままだった）。**リンク先そのもの**を要求する。
must_contain "GETTING_STARTED_ABSOLUTE_BEGINNER.md" 'multi-cli-review-orchestration.md#対応プラットフォーム' \
  "GETTING_STARTED が対応プラットフォーム節へ相互参照している"
must_contain "GETTING_STARTED_ABSOLUTE_BEGINNER.md" 'PowerShell / コマンドプロンプト版は存在しません' \
  "GETTING_STARTED が Windows ネイティブ非対応を明記している"
# 固定文字列の不在検査は「その文言の復活」しか止められない。全角/半角括弧の差や
# 言い換えは素通りする（実測）。ラベルは**実際に守っている範囲**まで狭めておく。
must_not_contain "GETTING_STARTED_ABSOLUTE_BEGINNER.md" 'コマンドプロンプト（Windows）で実行' \
  "GETTING_STARTED に旧文言『コマンドプロンプト（Windows）で実行』が復活していない"
# 見出し（適用範囲の注意）ではなく**主張そのもの**を固定する。見出しだけを見ると、
# 本文を「Windows ネイティブでも動きます」へ反転しても緑のまま通る（実測）。
must_contain "05-operations/deployment/agent-deletion-prevention-harness.md" \
  'Windows ネイティブで動くという意味ではありません' \
  "削除防止ハーネスが「Windows 対象」の適用範囲を限定している"
must_contain "05-operations/deployment/agent-deletion-prevention-harness.md" 'multi-cli-review-orchestration.md#対応プラットフォーム' \
  "削除防止ハーネスが対応プラットフォーム節へ相互参照している"
# リンク**先**が実在すること。参照側の文字列だけを守っていると、見出しを改名した
# 瞬間に両方のリンクが死ぬのに検査は緑のまま（実測: 「動作環境」へ改名しても通った）。
must_match "05-operations/deployment/multi-cli-review-orchestration.md" \
  '^#{2,4} 対応プラットフォーム$' \
  "リンク先の見出し『対応プラットフォーム』が実在する"

# --- Git Workflow ステップ1: 起票参考例は body-file + 単純コマンド分割方式（Issue #1079）---
# 旧 1 ブロック方式（label_args 配列・bash 3.2 の空配列展開・fail-soft 分岐）は worktree 隔離
# セッションの複合コマンド拒否ガードに当たる。コード行の針は行頭アンカーで固定し、旧方式の
# 指紋は tests/issue-label-contract と同じ集合を不在検査する（散文での名指しも拒否する）。
# 書き分け規則は散文のまま、規則本文（断定禁止）を固定する。
f="05-operations/deployment/git-workflow.md"
must_match "$f" '^gh label list --repo "\$expected_repo" --limit 200 --json name --jq' \
  "Git Workflow ステップ1 がラベル照会を単独コマンドで行う"
must_match "$f" '^  --body-file "\{本文ファイルのパス\}"\)"$' \
  "Git Workflow ステップ1 の起票例が --body-file で本文を渡す（パスはプレースホルダ）"
must_match "$f" '^  --label "\{実在を確認したラベル\}" \\$' \
  "Git Workflow ステップ1 の起票例がラベル名を直書きしない"
for fp in 'label_args' 'for candidate in ' 'issue_body' 'LABEL_LOOKUP_FAILED' 'までを 1 つの bash ブロックで'; do
  must_not_contain "$f" "$fp" \
    "Git Workflow ステップ1 に旧 1 ブロック方式の指紋『${fp}』が復活していない"
done
# 照会と起票が別フェンスにあること。行の存在検査だけでは同一フェンスへ戻す退行を通す（実測）。
mixed="$(awk '/^```/{ if (f) { if (l && c) print "MIXED"; f=0 } else { f=1; l=0; c=0 }; next }
  f && /^gh label list / { l=1 }  f && /gh issue create / { c=1 }' "$DOCS/$f")"
if [ -z "$mixed" ]; then
  ok "Git Workflow ステップ1 がラベル照会と起票を別フェンスに分けている"
else
  bad "Git Workflow ステップ1 でラベル照会と起票が同一フェンスに戻っている"
fi
must_contain "$f" '「不在」と「照会失敗」を書き分ける' \
  "Git Workflow ステップ1 がラベル不在と照会失敗の書き分け規則を持つ"
must_contain "$f" '後者を「存在しない」と断定しない' \
  "Git Workflow ステップ1 が照会失敗を『存在しない』と断定しない規則を維持している"

# --- Git Workflow: Epic の一括対応手順（Issue #1145。観測台帳 OBS-038 から昇格）---
# 契約文は番号付き太字の行頭から句点までをアンカーする。部分一致だけでは
# 「…組む必要はない」のような否定の後置で反転しても緑のまま通る（実測）。
must_match "$f" '^## Epic の一括対応（バッチ分割・worktree 並列・直列マージ）$' \
  "Git Workflow に Epic 一括対応の節が実在する"
must_match "$f" '^1\. \*\*バッチは対象ファイル集合が互いに素になるように組む。\*\*' \
  "Epic 一括対応: バッチ分割の基準（対象ファイル集合が互いに素）"
must_contain "$f" '同一ファイルを触る Issue は同一バッチに入れず、依存として先行バッチのマージ後に開始する。' \
  "Epic 一括対応: 同一ファイルを触る Issue は先行バッチのマージ後に開始する"
must_match "$f" '^2\. \*\*実装は worktree 隔離のサブエージェントで並列に行い、レビュー・マージは親が直列に行う。\*\*' \
  "Epic 一括対応: 実装は worktree 並列・レビューとマージは親が直列"
must_match "$f" '^3\. \*\*Issue 本文が順序制約を持つ場合（[^）]*）は、それをバッチ境界として採用する。\*\*' \
  "Epic 一括対応: Issue 本文の順序制約をバッチ境界に採用する"
must_match "$f" '^4\. \*\*changelog は fragment 方式（`changelog\.d/` への 1 断片追加）にする。\*\*' \
  "Epic 一括対応: changelog は fragment 方式"
must_contain "$f" 'claim（`.version-claims/`）が stale になり再生成が要る' \
  "Epic 一括対応: 並列マージ後の version claim 再生成"

# --- Git Workflow: 仕上げ側の detached 運用と version / suite 数の振り直し（Issue #1312。観測台帳 OBS-094 / OBS-095 から昇格）---
# 役割表の行も定型作業の段落も 1 行に収まるため、行頭から末尾のコマンド／文言までを
# 順序付きでアンカーする。コマンド単体の部分一致では、別の役割の行に同じ文字列が
# 現れた場合や手順の順序が入れ替わった場合に緑のまま通る。
must_match "$f" '^\| レビュー・AC 照合・マージ（親） \| 直列 \|.*`git switch --detach origin/<branch>`.*`HEAD:<branch>`.*`gh pr merge <PR番号> --squash` と `git push origin --delete <head>` に分割する' \
  "Epic 一括対応: 仕上げ担当は PR ブランチを detached で扱い --delete-branch を分割する"
must_match "$f" '^\*\*並列マージで残る定型作業\*\*:.*並列側は frontmatter `version` と suite 数の確定値を書かない。.*`origin/develop` の現在値 \+1、suite 数を `tests/run-all\.sh` の登録実体から数え直して作り直し、両側の Changelog エントリを保持したうえで claim を再生成する。' \
  "Epic 一括対応: version / suite 数は仕上げ側が rebase 後に作り直す"
must_contain "$f" '同じ文書を触る単発 PR が同時に開いているとき' \
  "Epic 一括対応: 振り直しの定型はバッチ外の単発 PR 並行にも適用する"

# --- Git Workflow: 状態を変える複数行の手順とプロンプト特殊文字は heredoc / ファイル経由（観測台帳 OBS-092 から昇格）---
must_contain "$f" 'プロンプト等の特殊文字（バッククォート・`$VAR`・条件展開）を含む文字列はヒアドキュメントで一時ファイルに書いてから渡す' \
  "Git Workflow が特殊文字を含む文字列をヒアドキュメント経由で渡す規則を持つ"
must_contain "$f" '状態を変える複数行の手順は `bash -e <<'\''EOF'\'' … EOF` の形で Bash ツールへ渡し' \
  "Git Workflow が状態を変える複数行の手順を quoted heredoc で bash に渡す規則を持つ"

# --- Git Workflow: 長時間ゲート開始前の並行セッション実測（ソースリポジトリの観測台帳 OBS-014 から昇格）---
# `gh pr list` による並行マージの静止確認は、同じ作業ツリーで動く別セッション
# （untracked ファイル・別ブランチへの checkout）を検出しない。節の消失・要求の
# 骨抜き（実測コマンドを削って散文だけ残す等）を固定文字列で検出する。
must_contain "$f" '並行マージの静止確認と並べて、同じ作業ツリーで動く並行セッションの実測も行う' \
  "長時間ゲート開始前の節が並行セッション実測を並行マージの静止確認と並べて要求する"
must_contain "$f" 'git worktree list --porcelain`、`git branch --show-current` で、別セッションが同じ作業ツリーへ untracked ファイルを書き込んでいないか・別ブランチへ checkout していないかを確認する' \
  "長時間ゲート開始前の節が具体的な実測コマンドと検出対象を明記している"

# --- multi-review SKILL.md: レビュー待ち時間の使い方（https://github.com/feel-flow/ff-dev-toolkit/issues/99）---
# SKILL.md は ${DOCS}（docs-template）の外（plugin 直下の skills/）にあるため、
# must_contain の $DOCS 前提には乗せられない。ここだけ絶対パスへ直接 grep する。
MULTI_REVIEW_SKILL="$PLUGIN_ROOT/skills/multi-review/SKILL.md"
if [ ! -f "$MULTI_REVIEW_SKILL" ]; then
  bad "multi-review SKILL.md が見つかりません: $MULTI_REVIEW_SKILL"
else
  if grep -qF '### レビュー待ち時間の使い方' "$MULTI_REVIEW_SKILL"; then
    ok "multi-review SKILL.md に「レビュー待ち時間の使い方」の項が実在する"
  else
    bad "multi-review SKILL.md に「レビュー待ち時間の使い方」の項が見つかりません"
  fi
  if grep -qF 'Issue 本文の AC 更新・PR 本文の更新・follow-up の起票・完了報告の下書き）は作業ツリーを触らないので' \
      "$MULTI_REVIEW_SKILL"; then
    ok "レビュー待ち時間の使い方が許可側（gh 経由の GitHub 側作業）を明記している"
  else
    bad "レビュー待ち時間の使い方の許可側（gh 経由の GitHub 側作業）が見つかりません"
  fi
  if grep -qF 'レビュー終端後に直したらすぐ commit し、次の回転を dirty な作業ツリーで起動しない' \
      "$MULTI_REVIEW_SKILL"; then
    ok "レビュー待ち時間の使い方が禁止側（ファイルの編集を溜めない）を明記している"
  else
    bad "レビュー待ち時間の使い方の禁止側（ファイルの編集を溜めない）が見つかりません"
  fi
  if grep -qF 'レビューエージェント（`git diff <base>...HEAD` を見る）は PR の内容としては未解消のままと判定する' \
      "$MULTI_REVIEW_SKILL"; then
    ok "レビュー待ち時間の使い方が禁止側の理由（DISCARDED・未解消判定）を明記している"
  else
    bad "レビュー待ち時間の使い方の禁止側の理由が見つかりません"
  fi
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "✗ docs-gates verify: $FAIL 件失敗" >&2
  exit 1
fi
echo "✓ docs-gates verify: 全 $PASS 件 pass"
