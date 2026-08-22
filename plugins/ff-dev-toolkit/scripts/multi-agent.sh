#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────
# multi-agent.sh — Multi-CLI Agent Orchestrator
# ────────────────────────────────────────────────────────────
# Orchestrates 5 AI CLIs (Claude Code, Codex, Copilot, Gemini, Grok)
# for review, explore, and implement tasks using tool-agnostic perspectives.
#
# NOTE: Metered CLIs (currently Copilot CLI / premium requests) are excluded
# from every default task lineup. Opt in explicitly with --cli copilot-cli.
#
# Compatible with bash 3.2+ (macOS default).
#
# Usage:
#   bash scripts/multi-agent.sh --task <type> [options]
#
# Options:
#   --task <type>           review | explore | implement (default: review)
#   --description <text>    Task description (required for explore/implement)
#   --config <path>         Config file (default: $MULTI_AGENT_CONFIG > <project>/.claude/agent-config.yaml > plugin-bundled agent-config.yaml)
#   --mode <mode>           distributed | cross-model
#   --strategy <strategy>   balanced | minimize_cost | maximize_quality
#   --cli <name>            Run only this CLI (repeatable)
#   --exclude-perspective <name>
#                           Drop this perspective from the plan (repeatable).
#                           A name that does not exist is rejected, not ignored.
#   --list-perspectives     Print the perspectives available for --task and exit.
#                           Builds no plan and starts no CLI.
#   --perspective <name>    Run only this perspective (repeatable). In distributed
#                           mode, only its owning CLI remains unless --cli is also
#                           explicit; use --mode cross-model for model comparison.
#   --parallel              Parallel execution (default)
#   --sequential            Sequential execution
#   --output-dir <dir>      Output directory (auto-detected by task type)
#   --base <branch>         Base branch for diff (default: auto-detect from origin/HEAD, fallback: develop)
#   --staged                Review only the staged index diff (review task only; mutually exclusive with --base)
#   --resume                Reuse successful results from an identical prior input and
#                           execute only failed, timed-out, missing, or corrupt tasks
#   --include-diff          Include diff in implement prompts
#   --dry-run               Show plan without executing
#   --timeout <seconds>     Timeout per CLI (default: review 900 / explore 600 / implement 900)
#   --help                  Show this help
#
# Fallback semantics (two different things — do not confuse them):
#   Plan-time (automatic):  a CLI that is NOT INSTALLED has its perspectives
#                           reassigned to its fallback CLI while the plan is built.
#                           The fallback registry lives in this script
#                           (get_cli_fallback); agent-config.yaml only mirrors it
#                           for readers and is never read for this.
#   Runtime (never automatic): a CLI that IS installed but then fails or times out
#                           is NOT retried on another CLI. The task is reported as
#                           failed and the run exits non-zero.
#   Why runtime fallback is deliberately absent: this tool exists to get several
#   *different* models onto the same diff, so silently swapping the model changes
#   what was actually reviewed while the report still shows the perspective as
#   covered; the configured substitute can also be a costlier tier (codex-cli →
#   claude-code is standard → premium) that the user never asked to pay for; and
#   a retry after a timeout spends a second full budget on the same slow work.
#   Re-run the substitute yourself with --cli when you want it — the failure
#   summary prints a ready-to-run command for each failed task, matched to why it
#   failed (a longer limit is only offered when a limit is what ran out).
#
# Perspective resolution:
#   --perspective alone filters the distributed ownership registry and can shrink
#   a review plan to one CLI. The plan reports installed CLIs excluded this way
#   and warns when the remaining review has a single point of failure.
#   A single --cli <name> + single --perspective <name> is an explicit pairing
#   and runs that perspective on that CLI even when the registry assigns it
#   elsewhere. Explicit CLIs are not replaced by a cost strategy. Repeatable
#   multi-value filters retain registry ownership. A requested perspective must
#   exist for the selected task; invalid names are rejected before dry-run.
#
# Output layout (and what is NOT cleaned):
#   <output-dir>/integrated-report.md      Aggregated report for THIS run only.
#   <output-dir>/<cli>/<perspective>.md    This run's per-perspective results.
#   <output-dir>/<cli>/previous/           Results left by an earlier run that this
#                                          run does not plan to write.
#   Before any CLI starts, a result file this orchestrator wrote under a planned
#   CLI's directory that is not one of this run's targets is MOVED into
#   <cli>/previous/, so listing that directory shows this run's results only.
#   `previous/` is rebuilt on every run that includes its CLI — it holds what the
#   latest such run displaced, not an archive; whatever it held is discarded (with
#   a count on stderr). A CLI absent from this run's plan keeps both its results and
#   its `previous/` untouched, so those directories are NOT rebuilt and are NOT this
#   run's output; they are named on stderr and in the report instead.
#   Deliberately untouched: directories of CLIs absent from this run's plan, `.md`
#   files this orchestrator did not write (no `<!-- Multi-CLI ... Result -->` first
#   line — a user's own notes are never moved or discarded), entries that are not
#   `*.md` directly under <cli>/ (implement staging `files/` included), and anything
#   reached through a symlink. A `<cli>/` that resolves anywhere other than itself
#   (a symlink, pointing inside or outside <output-dir>) aborts the run before
#   anything is written, deleted, or restored from the resume cache; a
#   `<cli>/previous` *symlink* is removed as a link, never followed.
#
# Entry Points:
#   Terminal:     bash scripts/multi-agent.sh --task review
#   Claude Code:  /multi-review, /multi-explore, /multi-implement
#   CI/CD:        See docs-template/05-operations/deployment/multi-cli-review-orchestration.md
#
# See: docs-template/05-operations/deployment/multi-cli-review-orchestration.md
# ────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# REPO_ROOT is the *target project* root (diff target and output dirs).
# This script may live inside an installed plugin, so the script location
# must not be used to locate the project. Run from inside the project repo.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
IN_GIT_REPO=true
if [[ -z "$REPO_ROOT" ]]; then
  IN_GIT_REPO=false
  REPO_ROOT="$(pwd)"
  echo "⚠️  Not inside a git repository — using current directory as project root: ${REPO_ROOT}" >&2
fi

# ── Shared adapter utilities ──
# diff の取り方・base ブランチの解決・リビジョンスナップショットは、アダプタと
# **同じ実装**を使う。orchestrator が固定した diff をアダプタが受け取る構造上、
# 2 つの実装がずれると「固定したつもりの diff」と「アダプタが読む diff」が食い違い、
# しかもその食い違いは実行結果からは見えない。
#
# 注意 1: adapter-common.sh は source 時に EXIT trap（clear_timeout_reason）を仕掛ける。
#   本スクリプトは acquire_output_lock で EXIT trap を張り直すのでそちらが勝つ。
#   orchestrator は run_with_timeout を呼ばない（それはアダプタのプロセス内の話）ので、
#   上書きしても失われる後始末は無い。
# 注意 2: adapter-common.sh は意図的に set -euo pipefail を張らないので、
#   source しても本スクリプトのシェルオプションは変わらない。
ADAPTER_COMMON="${SCRIPT_DIR}/adapters/adapter-common.sh"
if [[ ! -f "$ADAPTER_COMMON" ]]; then
  echo "ERROR: shared adapter utilities not found: ${ADAPTER_COMMON}" >&2
  echo "       The orchestrator and the adapters must resolve the same diff; refusing to" >&2
  echo "       continue with a second, drifting copy." >&2
  exit 1
fi
# shellcheck source=adapters/adapter-common.sh
source "$ADAPTER_COMMON"

# ── All known CLI names ──
# ↑ この見出し行は tests/lib/cli-registry-parser.sh が完全一致で registry 境界の開始に
# 使う。文言を変えると両 suite が「境界が一意ではありません」で落ちる。
ALL_CLIS="claude-code codex-cli copilot-cli gemini-cli grok-cli"

# ── Lookup Functions (bash 3.2 compatible — no associative arrays) ──
#
# Every name in ALL_CLIS must be answered by all of the lookups below
# (command, adapter, the three perspective maps, fallback, model env, cost tier).
# A missing case arm returns the empty default and the CLI then drops out of the
# plan silently — no error, just a perspective that nobody runs.
# tests/cli-registry-completeness/verify.sh gates that.

get_cli_command() {
  case "$1" in
    claude-code) echo "claude" ;;
    codex-cli)   echo "codex" ;;
    copilot-cli) echo "copilot" ;;
    gemini-cli)  echo "gemini" ;;
    grok-cli)    echo "grok" ;;
    *) echo "" ;;
  esac
}

get_cli_adapter() {
  case "$1" in
    claude-code) echo "${SCRIPT_DIR}/adapters/claude-code-adapter.sh" ;;
    codex-cli)   echo "${SCRIPT_DIR}/adapters/codex-cli-adapter.sh" ;;
    copilot-cli) echo "${SCRIPT_DIR}/adapters/copilot-cli-adapter.sh" ;;
    gemini-cli)  echo "${SCRIPT_DIR}/adapters/gemini-cli-adapter.sh" ;;
    grok-cli)    echo "${SCRIPT_DIR}/adapters/grok-cli-adapter.sh" ;;
    *) echo "" ;;
  esac
}

# ── Task-type aware perspective mappings ──
#
# code-simplification / pattern-discovery / migration were owned by cursor-cli
# until it was removed (issue #240). They were reassigned rather than retired:
# a perspective with no owner is simply never reviewed.
#   code-simplification → claude-code: direct counterpart in the pr-review-toolkit
#     lineage (code-simplifier), so this is where it belongs.
#   pattern-discovery → gemini-cli: a broad read-only sweep over the codebase,
#     which is what the long-context free tier is for.
#   migration → codex-cli, then → grok-cli when grok joined (issue #252).
#
# grok-cli's own three came from the CLIs carrying the most of each task, and
# were moved rather than shared: the distributed plan runs each CLI's owned
# perspectives, so two default-enabled CLIs sharing one perspective means paying
# to review the same thing twice. Sharing is only harmless when one side is
# excluded by default (copilot-cli, metered).
#   error-handler-hunt → grok-cli (from codex-cli): hunting silent failures is
#     worth a different model's eyes than the general code-review beside it.
#   tech-debt-assessment → grok-cli (from gemini-cli): judgment-heavy, whereas
#     the perspective gemini keeps (pattern-discovery) is the broad sweep its
#     long context is actually for.
#   migration → grok-cli (from codex-cli): self-contained, and it moves load off
#     the CLI that otherwise carries the most of the implement task.

get_cli_perspectives_review() {
  case "$1" in
    claude-code) echo "type-design-analysis code-simplification" ;;
    codex-cli)   echo "code-review test-analysis" ;;
    copilot-cli) echo "test-analysis comment-analysis" ;;  # metered — every task requires explicit --cli copilot-cli (see build_distributed_plan)
    gemini-cli)  echo "security-analysis comment-analysis" ;;
    grok-cli)    echo "error-handler-hunt" ;;
    *) echo "" ;;
  esac
}

get_cli_perspectives_explore() {
  case "$1" in
    claude-code) echo "architecture-analysis" ;;
    codex-cli)   echo "dependency-mapping" ;;
    copilot-cli) echo "api-surface-analysis" ;;  # metered — every task requires explicit --cli copilot-cli
    gemini-cli)  echo "pattern-discovery" ;;
    grok-cli)    echo "tech-debt-assessment" ;;
    *) echo "" ;;
  esac
}

get_cli_perspectives_implement() {
  case "$1" in
    claude-code) echo "feature-implementation" ;;
    codex-cli)   echo "refactoring" ;;
    copilot-cli) echo "test-writing" ;;  # metered — every task requires explicit --cli copilot-cli
    gemini-cli)  echo "documentation" ;;
    grok-cli)    echo "migration" ;;
    *) echo "" ;;
  esac
}

get_cli_fallback() {
  case "$1" in
    claude-code) echo "codex-cli" ;;
    codex-cli)   echo "claude-code" ;;
    copilot-cli) echo "codex-cli" ;;
    gemini-cli)  echo "codex-cli" ;;
    grok-cli)    echo "gemini-cli" ;;   # flat-rate の代替は無料枠が先。minimize_cost の意図を保つ
    *) echo "" ;;
  esac
}

get_cli_cost_tier() {
  case "$1" in
    claude-code) echo "premium" ;;
    codex-cli)   echo "standard" ;;
    copilot-cli) echo "metered" ;;
    gemini-cli)  echo "free-tier" ;;
    grok-cli)    echo "flat-rate" ;;
    # 既定の "unknown" は metered ではないので、resolve_available_fallback の
    # 「最後の砦」に選ばれうる。tier の書き漏れは課金される側へ倒れるということ。
    # 書き漏れ自体は tests/cli-registry-completeness が既知の tier 語で弾く。
    *) echo "unknown" ;;
  esac
}

get_cli_model_env_vars() {
  case "$1" in
    claude-code) echo "MULTI_AGENT_MODEL_CLAUDE_CODE" ;;
    codex-cli)   echo "MULTI_AGENT_MODEL_CODEX_CLI MULTI_AGENT_CODEX_PROFILE MULTI_AGENT_CODEX_REASONING_EFFORT" ;;
    copilot-cli) echo "MULTI_AGENT_MODEL_COPILOT_CLI" ;;
    gemini-cli)  echo "MULTI_AGENT_MODEL_GEMINI_CLI" ;;
    grok-cli)    echo "MULTI_AGENT_MODEL_GROK_CLI" ;;
    *) echo "" ;;
  esac
}

# ── CLI Registry End ──
# 上の境界（registry 定義域）は ALL_CLIS と固定値を返す単純な case lookup だけに保つ。
# tests/lib/cli-registry-parser.sh が shell として実行せず、制限文法として静的解析する。
#
# 境界外での制約（全ファイル走査で fail-closed に検出する）:
#   - ALL_CLIS は参照だけ。`$ALL_CLIS` / `${ALL_CLIS}` の形で書くこと。裸の識別子は
#     書き込みとみなして拒否する（`=` 代入だけでなく printf -v / read / unset も塞ぐ）
#   - `get_cli_*` は定義しない。実行時の入力で戻り値が変わる get_cli_perspectives だけ
#     が例外として許可されている（parser の allowlist に列挙）
#   - どちらの制約も行全体コメントには適用しない。ただし**行末**コメントで裸の
#     ALL_CLIS や `get_cli_foo()` に言及すると検出に引っかかるので、そこでは
#     `$ALL_CLIS` と書くか括弧を外すこと

perspective_excluded() {
  [[ -n "$EXCLUDE_PERSPECTIVES" ]] && list_contains "$EXCLUDE_PERSPECTIVES" "$1"
}

get_cli_perspectives() {
  local cli_name="$1"
  case "$TASK_TYPE" in
    review)    get_cli_perspectives_review "$cli_name" ;;
    explore)   get_cli_perspectives_explore "$cli_name" ;;
    implement) get_cli_perspectives_implement "$cli_name" ;;
    *)         get_cli_perspectives_review "$cli_name" ;;
  esac
}

# get_cli_fallback は 1 手先しか返さない。代替先も未インストールなら、そこで打ち切ると
# 担当観点がプランから黙って消える。実測（claude-code だけ導入した環境）では、
# gemini-cli → codex-cli(未導入) と grok-cli → codex-cli(未導入) が両方行き止まりになり、
# review 7 観点のうち 3 つが「No fallback available」の 1 行だけ残して落ちていた。
# 利用者の多くが単一 CLI 構成であることを踏まえると、これが既定の姿になる。
#
# チェーンを辿って最初に導入済みの CLI を返す。表は相互参照を含む（claude-code ⇄
# codex-cli）ので訪問済みを持って循環を切る。
#
# チェーンを辿るだけでは足りない。対応表のグラフは claude-code ⇄ codex-cli が
# **終端サイクル**で、gemini-cli / grok-cli はそこへ流れ込むだけで逆向きの辺が無い。
# 実測（各 CLI を単独で導入したときに計画された review 観点 / 全 7）:
#   claude のみ 7 / codex のみ 7 / gemini のみ 3 / grok のみ 1
# つまり「1 つでも CLI が入っていれば観点は落ちない」は成り立っていなかった。
#
# そこで、チェーンが行き止まりになったら**導入済みの CLI から選び直す**。観点を
# 落とすくらいなら対応表に無い CLI で見てもらう方がよい（プラン出力に CLI 名と
# コスト帯が出るので、誰が見たかは隠れない）。
#
# 従量課金の CLI は最後の砦から除く。既定で除外している CLI（copilot-cli）へ
# 黙って落とすと、利用者が求めていない課金が発生する。それしか無い場合は空を
# 返し、既定除外のガードと空プラン検査に任せる。
resolve_available_fallback() {
  local cli="$1" seen=" $1 " next candidate
  while :; do
    next="$(get_cli_fallback "$cli")"
    [[ -n "$next" ]] || break
    case "$seen" in
      *" $next "*) break ;;   # 循環 — 設定された経路はここで尽きた
    esac
    if list_contains "$AVAILABLE_CLIS" "$next"; then
      echo "$next"
      return
    fi
    seen="${seen}${next} "
    cli="$next"
  done

  # 設定された経路が尽きた。導入済みの非従量課金 CLI へ回す（ALL_CLIS の順）。
  for candidate in $ALL_CLIS; do
    [[ "$candidate" == "$1" ]] && continue
    list_contains "$AVAILABLE_CLIS" "$candidate" || continue
    [[ "$(get_cli_cost_tier "$candidate")" == "metered" ]] && continue
    echo "$candidate"
    return
  done
  echo ""
}

# ── Model-Selection Env Passthrough ──
# モデル選択の env は「インラインで前置して 1 回だけ効かせる」形（multi-review の
# SKILL.md の例もそれ）なので、元コマンドが終わると消える。再実行コマンドをそのまま
# 出すと、貼り付けた人は既定のモデル / プロファイルで走ることになり、失敗した構成の
# 再現にならない。
#
# 前置は**その行の CLI に効くものだけ**にする。全部まとめて前置すると、代替 CLI を
# 案内する行にも無関係な env が乗り、実際には使われない設定を使うかのように読める。
# get_cli_model_env_vars 自体は上の副作用なしレジストリ定義域に置く。

# 設定されている env だけを `VAR=値 ` の形で連結して返す（無ければ空文字）。
# codex でモデルとプロファイルが両方設定されている場合はアダプタが実行前に拒否するが、
# ここでは両方そのまま前置する — 再実行は「失敗した構成の忠実な再現」であるべきで、
# 片方を黙って落とすと、直したはずの「上書きが静かに消える」問題に戻る。利用者が
# どちらを残すべきかはアダプタのエラーメッセージが明示している。
model_env_prefix() {
  local cli="$1" var prefix=""
  for var in $(get_cli_model_env_vars "$cli"); do
    if [[ -n "${!var:-}" ]]; then
      prefix="${prefix}${var}=$(printf '%q' "${!var}") "
    fi
  done
  printf '%s' "$prefix"
}

# ── Reviewer Pair (main + sub) ──
#
# 分散モードは「全 CLI が入っている」前提の設計だった。実際の利用者はほとんどが
# 単一 CLI で、未導入 CLI の観点は fallback で回されるため「誰が何を見たか」が
# 導入状況で毎回変わる。主（メインで使っている CLI）に review 観点すべてを任せ、
# 副がいれば総合レビューを 1 本だけ足す、という形にする。
#
# 保存するのは **CLI 名だけ**。モデルは各 CLI 自身の設定へ委譲する（issue #239 の
# 不変条件）。設定ファイル経由でモデル slug を保存できてしまうと、.sh しか走査
# しない tests/no-hardcoded-model をすり抜けて ACE-70-2 が再発する。
readonly COMPREHENSIVE_PERSPECTIVE="comprehensive-review"

reviewers_config_file() {
  printf '%s/ff-dev-toolkit/reviewers' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

# 値が CLI 名として妥当かを見る。ここが「モデル slug を保存できない」ことの
# 構造的な担保になるので、enum 一致だけを許して他はすべて落とす。
validate_reviewer_value() { # <役割> <値>
  local role="$1" value="$2"
  [[ -z "$value" ]] && return 0
  if ! is_safe_token "$value"; then
    echo "ERROR: unsafe ${role} reviewer name: '${value}'" >&2
    return 1
  fi
  if ! list_contains "$ALL_CLIS" "$value"; then
    echo "ERROR: unknown ${role} reviewer: '${value}'" >&2
    echo "       Reviewers are CLI names, not model names. Known CLIs: ${ALL_CLIS}" >&2
    echo "       Which model each CLI uses is delegated to that CLI's own config." >&2
    return 1
  fi
  return 0
}

# ユーザーグローバルの保存ファイルを読む（`main=...` / `sub=...` の 2 行）。
# ユーザーグローバルの保存ファイルを読み、指定された変数名へ入れる。
# グローバルを直接書かないのは、フィールド単位の優先順位判定を呼び出し側に
# 一元化するため（ここで書き戻すと「誰が入れた値か」が追えなくなる）。
read_reviewers_file_into() { # <main を入れる変数名> <sub を入れる変数名>
  local f key value
  f="$(reviewers_config_file)"
  [[ -f "$f" ]] || return 0
  # `|| [[ -n "$key" ]]` が要る。read は末尾改行の無い最終行で非 0 を返すため、
  # 素の while だとその行が黙って捨てられる。この設定は ~/.config の平文で説明
  # コメント付きなので手編集を誘うし、落ちる形が「副が黙って消える」——まさに
  # この機能が可視化しようとしている縮退そのもの。
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    case "$key" in
      main) eval "$1=\"\$value\"" ;;
      sub)  eval "$2=\"\$value\"" ;;
    esac
  done < "$f"
  return 0
}

# env > プロジェクト設定 > ユーザーグローバル。既存の CONFIG_FILE 解決と同じ形。
# 優先順位は **フィールド単位**（main と sub をそれぞれ独立に env > project > global で
# 解決する）。ペア単位にすると「今回だけ副を変えたい」ができず、片側だけ指定した
# ときに上位層の main と下位層の sub が非対称に混ざる（どちらの規則としても
# 一貫しない状態になる）。フィールド単位なら片側指定の全組合せが説明できる。
#
# 副に空文字を明示指定する（MULTI_AGENT_REVIEW_SUB=）のは「今回は副なし」の意思
# 表示なので、下位層で埋め戻さない。env が設定されているかどうかで判定する。
resolve_reviewer_pair() {
  local v
  REVIEW_MAIN=""
  REVIEW_SUB=""
  local main_src="" sub_src=""
  REVIEWERS_MAIN_SOURCE=""
  REVIEWERS_SUB_SOURCE=""

  if [[ -n "${MULTI_AGENT_REVIEW_MAIN:-}" ]]; then
    REVIEW_MAIN="$MULTI_AGENT_REVIEW_MAIN"; main_src="env"
  fi
  # 空文字での明示指定も「決まった」とみなす（副なしの意思表示）
  if [[ "${MULTI_AGENT_REVIEW_SUB+set}" == "set" ]]; then
    REVIEW_SUB="$MULTI_AGENT_REVIEW_SUB"; sub_src="env"
  fi

  if [[ -f "$CONFIG_FILE" ]] && command -v yq &>/dev/null; then
    if [[ -z "$main_src" ]]; then
      v="$(yq -r '.review.main // ""' "$CONFIG_FILE" 2>/dev/null || true)"
      [[ -n "$v" ]] && { REVIEW_MAIN="$v"; main_src="project config"; }
    fi
    if [[ -z "$sub_src" ]]; then
      v="$(yq -r '.review.sub // ""' "$CONFIG_FILE" 2>/dev/null || true)"
      [[ -n "$v" ]] && { REVIEW_SUB="$v"; sub_src="project config"; }
    fi
  fi

  if [[ -z "$main_src" || -z "$sub_src" ]]; then
    local file_main="" file_sub=""
    read_reviewers_file_into file_main file_sub
    if [[ -z "$main_src" && -n "$file_main" ]]; then REVIEW_MAIN="$file_main"; main_src="user config"; fi
    if [[ -z "$sub_src"  && -n "$file_sub"  ]]; then REVIEW_SUB="$file_sub";  sub_src="user config"; fi
  fi

  # 出所は main / sub が同じなら 1 つ、違えば両方を出す（どこを直せばよいか分かる形）
  if [[ -z "$main_src" && -z "$sub_src" ]]; then
    REVIEWERS_SOURCE=""
  elif [[ "$main_src" == "$sub_src" ]]; then
    REVIEWERS_SOURCE="$main_src"
  else
    REVIEWERS_SOURCE="main:${main_src:-unset} sub:${sub_src:-unset}"
  fi

  REVIEWERS_MAIN_SOURCE="${main_src:-unset}"
  REVIEWERS_SUB_SOURCE="${sub_src:-unset}"

  validate_reviewer_value main "$REVIEW_MAIN" || return 1
  validate_reviewer_value sub  "$REVIEW_SUB"  || return 1
  return 0
}

# 書き込みは hooks/check-update.sh の write_cache と同じアトミック置換。
# 部分的に書けたファイルを残すと、次回の読み出しが壊れた設定を拾う。
write_reviewers_file() { # <main> <sub>
  local f dir tmp
  f="$(reviewers_config_file)"
  dir="$(dirname "$f")"
  mkdir -p "$dir" 2>/dev/null || {
    echo "ERROR: cannot create ${dir}" >&2
    return 1
  }
  # hooks/check-update.sh の write_cache は同じ位置で `rm -rf` して自己修復するが、
  # あちらは**キャッシュ**なので捨ててよい。ここは利用者の設定なので、想定外の
  # 形をしていたら消さずに止める（消してよいかを判断できるのは利用者だけ）。
  if [[ -d "$f" ]]; then
    echo "ERROR: ${f} is a directory, not a config file." >&2
    echo "       Refusing to remove it. Move it aside and retry." >&2
    return 1
  fi
  # kill された過去の実行が残した一時ファイルを掃除する（所有 PID が消えている
  # ので自前の rm では回収できない）。check-update.sh の write_cache と同じ理由。
  rm -f "$f".[0-9]* 2>/dev/null
  tmp="$f.$$"
  # 1 回の printf で書く。複数の printf を { } で束ねると、ブロックの終了状態は
  # **最後の 1 つ**のものになり、途中の書き込み失敗を検出できない（切り詰められた
  # ファイルがそのまま install される）。
  if ! printf '%s\n' \
    "# ff-dev-toolkit review reviewers (CLI names only — models are each CLI's own setting)" \
    "main=$1" \
    "sub=$2" > "$tmp"; then
    rm -f "$tmp" 2>/dev/null
    echo "ERROR: cannot write ${tmp}" >&2
    return 1
  fi
  # mv の stderr は捨てない。EACCES / ENOSPC / read-only fs で次の一手が違う。
  if ! mv -f "$tmp" "$f"; then
    rm -f "$tmp" 2>/dev/null
    echo "ERROR: cannot install ${f}" >&2
    return 1
  fi
  return 0
}

# 機械可読の状態出力。スキル層はこの exit code で分岐する（マーカー行を
# grep -q で拾う形にしない — SIGPIPE + pipefail で判定が反転する。Issue #234）。
#   0 = 主が決まっている / 3 = 未設定
print_reviewers_state() {
  # 状態は検出より**先に**出す。detect_available_clis は CLI が 1 つも無いと
  # インストール案内を出して `exit 1` する（関数の return ではないので `|| true`
  # では捕まえられない）。検出を先に置くと、その環境では 1 バイトも出力されない
  # まま終わる — しかもこれは /multi-review の最初のコマンドで、プラグインを
  # 入れてから CLI を入れる人が最初に踏む経路になる。
  printf 'main=%s\n' "$REVIEW_MAIN"
  printf 'sub=%s\n' "$REVIEW_SUB"
  printf 'main_source=%s\n' "${REVIEWERS_MAIN_SOURCE:-unset}"
  printf 'sub_source=%s\n' "${REVIEWERS_SUB_SOURCE:-unset}"
  printf 'source=%s\n' "${REVIEWERS_SOURCE:-unset}"
  # stderr は握りつぶさない。CLI 未導入時の唯一の手がかり（インストール案内）が
  # そこにしか無い。stdout の ✅/❌ だけを捨てる。
  detect_available_clis >/dev/null
  printf 'available=%s\n' "$AVAILABLE_CLIS"
  printf 'known=%s\n' "$ALL_CLIS"
  [[ -n "$REVIEW_MAIN" ]] && return 0
  return 3
}

# `main=<cli>,sub=<cli>` を検証して保存する。検証はここ 1 箇所に閉じ込め、
# スキル層にはプロンプト以外の判断をさせない。
set_reviewers_from_spec() { # <spec>
  local spec="$1" part key value main="" sub="" sub_given=false
  # IFS の変更はカンマ分割のあいだだけに閉じる。関数の残り（validate_reviewer_value →
  # list_contains）は `for i in $list` の単語分割に依存しているので、IFS=',' のまま
  # 進むと既知の CLI 名すら「未知」と判定される（実際に踏んだ）。
  local saved_ifs="$IFS"
  IFS=','
  for part in $spec; do
    key="${part%%=*}"
    value="${part#*=}"
    case "$key" in
      main) main="$value" ;;
      sub)  sub="$value"; sub_given=true ;;
      *)
        echo "ERROR: unknown reviewer key: '${key}' (expected main= or sub=)" >&2
        return 1
        ;;
    esac
  done

  IFS="$saved_ifs"

  if [[ -z "$main" ]]; then
    echo "ERROR: --set-reviewers requires main=<cli> (sub=<cli> is optional)." >&2
    return 1
  fi
  # `main=X` だけを渡したときに副を黙って消さない。部分更新に見える指定が
  # 全置換として振る舞うのは事故のもと。消したいときは `sub=` を明示する。
  if [[ "$sub_given" != "true" ]]; then
    local _existing_main="" existing_sub=""
    read_reviewers_file_into _existing_main existing_sub
    sub="$existing_sub"
    [[ -n "$sub" ]] && echo "ℹ️  sub は既存の設定（${sub}）を引き継ぎます。消すには sub= を明示してください。" >&2
  fi

  validate_reviewer_value main "$main" || return 1
  validate_reviewer_value sub  "$sub"  || return 1
  if [[ -n "$sub" && "$sub" == "$main" ]]; then
    echo "ERROR: sub reviewer must differ from main (both '${main}')." >&2
    return 1
  fi

  # 従量課金の CLI は分散モードでは毎回 --cli 明示のオプトインを要求している。
  # 保存はその一度きりの選択を「毎回のレビューで課金」へ変えるので、保存の時点で
  # 言う（プラン表示の [metered] は最後の砦であって、気づく最初の機会ではない）。
  local role value
  for role in main sub; do
    [[ "$role" == "main" ]] && value="$main" || value="$sub"
    [[ -z "$value" ]] && continue
    if [[ "$(get_cli_cost_tier "$value")" == "metered" ]]; then
      echo "⚠️  ${value} は従量課金です。${role} に保存すると、変更するまで毎回のレビューで課金されます。" >&2
    fi
  done

  write_reviewers_file "$main" "$sub" || return 1
  echo "✅ Saved reviewers: main=${main} sub=${sub:-（なし）}" >&2
  echo "   $(reviewers_config_file)" >&2
  return 0
}

# ── Task-type defaults ──

get_default_output_dir() {
  case "$1" in
    review)    echo "${REPO_ROOT}/.review-results" ;;
    explore)   echo "${REPO_ROOT}/.explore-results" ;;
    implement) echo "${REPO_ROOT}/.implement-results" ;;
    *)         echo "${REPO_ROOT}/.review-results" ;;
  esac
}

# ── Task-type default timeouts (seconds) ──
# SSOT for the defaults. Every copy of these numbers must agree, and
# tests/multi-agent-timeout/verify.sh gates all of them:
#   - these constants
#   - the --timeout line in this file's header (rendered verbatim as --help)
#   - scripts/agent-config.yaml (tasks.*.timeout)
#   - adapters/adapter-common.sh's REVIEW_TIMEOUT default, for a direct adapter run
#   - the user-facing docs (skills/multi-review/SKILL.md + two docs-template pages)
#
# Review is 900s because 300s did not fit reality: a Codex `exec` review of a
# medium diff (3 files, +881/-14) was still working when the limit fired, so the
# task produced nothing at all (issue #152). Measured after the fix, four runs of
# that same review completed in 299-373s — straddling the old default, so the same
# shape of diff used to succeed or fail by chance. 900s is ~2.4x the longest
# measurement, and matches implement. A generous limit is close to free now that run_with_timeout returns as
# soon as the CLI answers; before that fix, on hosts without timeout(1) (stock
# macOS), every run paid the full limit regardless, which is why raising this
# number used to be unaffordable.
readonly DEFAULT_TIMEOUT_REVIEW=900
readonly DEFAULT_TIMEOUT_EXPLORE=600
readonly DEFAULT_TIMEOUT_IMPLEMENT=900

get_default_timeout() {
  case "$1" in
    review)    echo "$DEFAULT_TIMEOUT_REVIEW" ;;
    explore)   echo "$DEFAULT_TIMEOUT_EXPLORE" ;;
    implement) echo "$DEFAULT_TIMEOUT_IMPLEMENT" ;;
    *)         echo "$DEFAULT_TIMEOUT_REVIEW" ;;
  esac
}

# ── Timeout policy (no per-CLI caps) ──
# Every CLI gets the run-wide $TIMEOUT verbatim. cursor-cli had a cap (its --print mode has a known non-interactive
# hang, so it was clamped to 120s) and was the only CLI that ever did; the cap
# machinery went out with it in issue #240, so the limit reported on failure is
# always the limit that actually applied.
#
# Enforced by tests/multi-agent-timeout/verify.sh, which statically rejects any
# reassignment of TIMEOUT inside an adapter — the shape the old clamp took.
#
# If a future CLI needs a cap, re-introduce it HERE rather than in the adapter
# alone. When the adapter capped silently, a task that stopped at 120s was logged
# as "Timed out after 900s" and the printed remedy was `--timeout 1800` — which
# the adapter clamped straight back to 120, so following the advice changed
# nothing. The orchestrator is what reports and advises about timeouts, so it has
# to know the real number.

get_default_strategy() {
  case "$1" in
    review)    echo "balanced" ;;
    explore)   echo "minimize_cost" ;;
    implement) echo "maximize_quality" ;;
    *)         echo "balanced" ;;
  esac
}

get_task_emoji() {
  case "$1" in
    review)    echo "🔍" ;;
    explore)   echo "🔭" ;;
    implement) echo "🛠️" ;;
    *)         echo "🔍" ;;
  esac
}

# ── Defaults ──
# （旧 registry 境界。現在はどのテストも参照しない。機械的な意味を持つ見出しは
# 上の「All known CLI names」/「CLI Registry End」の 2 つだけ）
TASK_TYPE="review"
DESCRIPTION=""
INCLUDE_DIFF=false
CONFIG_FILE="${MULTI_AGENT_CONFIG:-}"
CONFIG_SOURCE="MULTI_AGENT_CONFIG env"
if [[ -z "$CONFIG_FILE" ]]; then
  if [[ -f "${REPO_ROOT}/.claude/agent-config.yaml" ]]; then
    CONFIG_FILE="${REPO_ROOT}/.claude/agent-config.yaml"
    CONFIG_SOURCE="project override"
  else
    CONFIG_FILE="${SCRIPT_DIR}/agent-config.yaml"
    CONFIG_SOURCE="plugin default"
  fi
fi
MODE=""            # 未指定なら apply_task_defaults がタスク種別ごとに決める
REVIEW_MAIN=""
REVIEW_SUB=""
REVIEWERS_SOURCE=""
MODE_EXPLICIT=false
PRINT_REVIEWERS=false
SET_REVIEWERS=""
STRATEGY=""
PARALLEL=true
OUTPUT_DIR=""
# Whether --output-dir was given, so the retry advice can carry it (the value
# itself is always set later by apply_task_defaults, so it cannot be inferred).
OUTPUT_DIR_EXPLICIT=false
# この実行の diff を固定したファイル。create_fixed_diff が埋め、run_single_task が
# 全アダプタへ --diff-file として配る。diff を持たないタスク（description だけの
# explore など）では空のまま = 従来どおりアダプタ側の判断に委ねる。
FIXED_DIFF_FILE=""
# 実行開始時点のリビジョンスナップショット（capture_repo_snapshot の 1 行）。
# 実行後に取り直した値と突き合わせる。git リポジトリ外では空のまま。
REPO_SNAPSHOT_BEFORE=""
# 検出そのものは adapters/adapter-common.sh の関数へ委譲する（書き写しの人手同期を
# やめるため）。ここに残すのは orchestrator 固有の方針だけ:
#   1) MULTI_AGENT_BASE_BRANCH env を最優先する
#   2) 「自動検出」と「origin/HEAD が無いのでフォールバック」を利用者へ名乗り分ける
# 2 を保つために default_base_branch_name（空を返しうる）と resolve_base_branch_ref を
# 別々に呼ぶ。畳んだ detect_base_branch では、どちらが起きたのか戻り値から分からない。
BASE_BRANCH="${MULTI_AGENT_BASE_BRANCH:-}"
BASE_BRANCH_SOURCE="MULTI_AGENT_BASE_BRANCH env"
BASE_BRANCH_EXPLICIT=false
if [[ -n "$BASE_BRANCH" ]]; then
  BASE_BRANCH_EXPLICIT=true
fi
STAGED_DIFF=false
if [[ -z "$BASE_BRANCH" ]]; then
  BASE_BRANCH="$(default_base_branch_name)"
  BASE_BRANCH_SOURCE="auto-detected from origin/HEAD"
fi
if [[ -z "$BASE_BRANCH" ]]; then
  BASE_BRANCH="develop"
  BASE_BRANCH_SOURCE="fallback — origin/HEAD not set"
fi
# Prefer the local branch; fall back to the remote-tracking ref when absent (clones)
BASE_BRANCH="$(resolve_base_branch_ref "$BASE_BRANCH")"
DRY_RUN=false
RESUME=false
TIMEOUT=""

# Space-separated filter lists (bash 3.2 compatible)
CLI_FILTER=""
PERSPECTIVE_FILTER=""
# 除外は包含フィルタへ畳み込まない。PERSPECTIVE_FILTER を埋めると、--cli と併用したとき
# 「明示ペアリング」経路（所有レジストリを迂回する）を意図せず踏む。独立に保つ。
EXCLUDE_PERSPECTIVES=""
LIST_PERSPECTIVES=false

# Detected available CLIs (space-separated)
AVAILABLE_CLIS=""

# Execution plan: CLI_NAME:PERSPECTIVE pairs (newline-separated)
EXECUTION_PLAN=""

# pair モードで「副を立てられたのに --perspective の指定で落ちた」かどうか。
# 単一 CLI 縮退警告の gate が読む。build_pair_plan を通らないモード（distributed /
# cross-model）では、現状の gate の式が短絡するためこの変数は展開されない。それでも
# 必ず初期化するのは、gate が壊れない根拠を**式の書き方**に依存させないため — 条件の
# 順序を入れ替えた瞬間に set -u で未定義参照になり、しかも壊れるのは pair 以外という
# 遠い場所になる。
PAIR_SUB_DROPPED=false

# Tasks that failed this run, as "cli/perspective:exit_code" (space-separated).
# Drives the retry advice printed after execution — a bare count leaves the user to
# work out which CLI to re-run and with what, which is exactly the moment they
# reach for a runtime fallback that does not exist. The exit code rides along
# because the right advice depends on it: more time helps a timeout and is useless
# for expired credentials. cli/perspective are validated single path segments and
# cannot contain ':', so the suffix is unambiguous.
FAILED_TASKS=""

# Resume state. EXECUTION_PLAN starts as the complete expected plan. Immediately
# before dispatch, prepare_resume_execution_plan saves that plan here and replaces
# EXECUTION_PLAN with only the tasks that still need execution. main restores the
# complete plan before revision verification and report generation.
FULL_EXECUTION_PLAN=""

# 今回の実行では動かさないが、出力ディレクトリに残っている結果ファイルの名指し
# （Issue #537 / #654）。quarantine_unplanned_outputs が実行ごとに詰め直し、
# append_plan_sections が統合レポートへも載せる（stderr だけだと、レポート経由で
# 結果を読む消費者に届かない）。
UNPLANNED_RESULT_NOTES=""
REUSED_TASKS=""
EXECUTED_TASKS=""
RESUME_IDENTITY_VERSION=1
RESUME_IDENTITY=""
RESUME_CACHE_DIR=""

# 同じ output-dir を使う別 orchestrator との排他。成果物は run-id で分離せず、利用者が
# 従来どおり固定パスから読める契約を保つ代わりに、1 output-dir = 1 active run とする。
OUTPUT_LOCK_DIR=""
OUTPUT_LOCK_HELD=false

# ── Utility ──

list_contains() {
  local list="$1" item="$2"
  for i in $list; do
    [[ "$i" == "$item" ]] && return 0
  done
  return 1
}

# ── Usage ──
show_help() {
  sed -n '/^# Usage:/,/^# See:/{/^# See:/d; s/^# \{0,1\}//; p;}' "$0"
  exit 0
}

# ── Argument Parsing ──
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task)        TASK_TYPE="$2"; shift 2 ;;
      --description) DESCRIPTION="$2"; shift 2 ;;
      --include-diff) INCLUDE_DIFF=true; shift ;;
      --config)      CONFIG_FILE="$2"; CONFIG_SOURCE="--config flag"; shift 2 ;;
      --mode)        MODE="$2"; MODE_EXPLICIT=true; shift 2 ;;
      --strategy)    STRATEGY="$2"; shift 2 ;;
      --cli)         CLI_FILTER="${CLI_FILTER:+$CLI_FILTER }$2"; shift 2 ;;
      --perspective) PERSPECTIVE_FILTER="${PERSPECTIVE_FILTER:+$PERSPECTIVE_FILTER }$2"; shift 2 ;;
      --exclude-perspective)
        if [[ $# -lt 2 ]]; then
          echo "ERROR: --exclude-perspective には観点名が必要です。" >&2
          exit 2
        fi
        EXCLUDE_PERSPECTIVES="${EXCLUDE_PERSPECTIVES:+$EXCLUDE_PERSPECTIVES }$2"; shift 2 ;;
      --list-perspectives) LIST_PERSPECTIVES=true; shift ;;
      --parallel)    PARALLEL=true; shift ;;
      --sequential)  PARALLEL=false; shift ;;
      --output-dir)  OUTPUT_DIR="$2"; OUTPUT_DIR_EXPLICIT=true; shift 2 ;;
      --base)        BASE_BRANCH="$2"; BASE_BRANCH_SOURCE="--base flag"; BASE_BRANCH_EXPLICIT=true; shift 2 ;;
      --staged)      STAGED_DIFF=true; shift ;;
      --resume)      RESUME=true; shift ;;
      --dry-run)     DRY_RUN=true; shift ;;
      --print-reviewers) PRINT_REVIEWERS=true; shift ;;
      --set-reviewers)   SET_REVIEWERS="$2"; shift 2 ;;
      --timeout)     TIMEOUT="$2"; shift 2 ;;
      --help|-h)     show_help ;;
      *)
        echo "Unknown option: $1" >&2
        echo "Run with --help for usage" >&2
        exit 1
        ;;
    esac
  done

  # Validate task type
  case "$TASK_TYPE" in
    review|explore|implement) ;;
    *)
      echo "ERROR: Invalid task type: '${TASK_TYPE}'. Must be review, explore, or implement." >&2
      exit 1
      ;;
  esac

  if [[ "$STAGED_DIFF" == "true" && "$TASK_TYPE" != "review" ]]; then
    echo "ERROR: --staged is only valid for review tasks." >&2
    exit 2
  fi
  if [[ "$STAGED_DIFF" == "true" && "$BASE_BRANCH_EXPLICIT" == "true" ]]; then
    echo "ERROR: --staged and an explicit base (--base / MULTI_AGENT_BASE_BRANCH) are mutually exclusive." >&2
    echo "       Choose the staged index or a base-branch diff; they are different review scopes." >&2
    exit 2
  fi

  # Validate description for explore/implement
  # --list-perspectives は「その task にどんな観点があるか」を出すだけで、タスクを
  # 実行しない。description を要求すると、一覧を見たいだけの利用者が explore/implement で
  # 落ちる（実測）。dry-run が免除されているのと同じ理由。
  if [[ "$TASK_TYPE" != "review" && -z "$DESCRIPTION" \
        && "$DRY_RUN" == "false" && "$LIST_PERSPECTIVES" == "false" ]]; then
    echo "ERROR: --description is required for ${TASK_TYPE} tasks." >&2
    exit 1
  fi
}

# ── Config Loading (v1/v2 compatible) ──
load_config() {
  # Fall back to review-config.yaml if agent-config.yaml doesn't exist
  if [[ ! -f "$CONFIG_FILE" ]]; then
    # An explicitly requested config that is missing must fail loud — silently
    # substituting defaults would run with settings the user did not choose.
    if [[ "$CONFIG_SOURCE" == "--config flag" || "$CONFIG_SOURCE" == "MULTI_AGENT_CONFIG env" ]]; then
      echo "ERROR: config file not found: $CONFIG_FILE (from ${CONFIG_SOURCE})" >&2
      exit 1
    fi
    local fallback_config="${SCRIPT_DIR}/review-config.yaml"
    if [[ -f "$fallback_config" ]]; then
      echo "ℹ️  Using legacy config: $fallback_config" >&2
      CONFIG_FILE="$fallback_config"
      CONFIG_SOURCE="legacy review-config.yaml"
    else
      echo "⚠️  Config file not found: $CONFIG_FILE (using defaults)" >&2
      return 0
    fi
  fi

  if command -v yq &>/dev/null; then
    if ! yq '.' "$CONFIG_FILE" >/dev/null 2>&1; then
      echo "⚠️  Config file could not be parsed by yq. Using defaults." >&2
      return 0
    fi

    local cfg_val
    cfg_val=$(yq -r '.mode // ""' "$CONFIG_FILE" 2>/dev/null || true)
    [[ -n "$cfg_val" ]] && MODE="$cfg_val"

    cfg_val=$(yq -r '.parallel // ""' "$CONFIG_FILE" 2>/dev/null || true)
    [[ "$cfg_val" == "true" ]] && PARALLEL=true
    [[ "$cfg_val" == "false" ]] && PARALLEL=false

    # v2: task-specific config
    local version
    version=$(yq -r '.version // "1.0"' "$CONFIG_FILE" 2>/dev/null || true)

    if [[ "$version" == "2.0" ]]; then
      # Read task-specific settings
      # mode をタスク単位で読む。グローバルの mode: は全タスク共通の既定で、
      # review だけ pair にしたいといった指定ができなかった（v2.0 で cost_strategy /
      # timeout / output_dir がタスク単位なのと同じ扱いへ揃える）。
      cfg_val=$(yq -r ".tasks.${TASK_TYPE}.mode // \"\"" "$CONFIG_FILE" 2>/dev/null || true)
      [[ -n "$cfg_val" ]] && MODE="$cfg_val"

      cfg_val=$(yq -r ".tasks.${TASK_TYPE}.cost_strategy // \"\"" "$CONFIG_FILE" 2>/dev/null || true)
      [[ -n "$cfg_val" && -z "$STRATEGY" ]] && STRATEGY="$cfg_val"

      cfg_val=$(yq -r ".tasks.${TASK_TYPE}.timeout // \"\"" "$CONFIG_FILE" 2>/dev/null || true)
      [[ -n "$cfg_val" && -z "$TIMEOUT" ]] && TIMEOUT="$cfg_val"

      cfg_val=$(yq -r ".tasks.${TASK_TYPE}.output_dir // \"\"" "$CONFIG_FILE" 2>/dev/null || true)
      [[ -n "$cfg_val" && -z "$OUTPUT_DIR" ]] && OUTPUT_DIR="${REPO_ROOT}/${cfg_val}"
    else
      # v1 compatibility
      cfg_val=$(yq -r '.cost_strategy // ""' "$CONFIG_FILE" 2>/dev/null || true)
      [[ -n "$cfg_val" && -z "$STRATEGY" ]] && STRATEGY="$cfg_val"

      cfg_val=$(yq -r '.timeout // ""' "$CONFIG_FILE" 2>/dev/null || true)
      [[ -n "$cfg_val" && -z "$TIMEOUT" ]] && TIMEOUT="$cfg_val"

      cfg_val=$(yq -r '.output_dir // ""' "$CONFIG_FILE" 2>/dev/null || true)
      [[ -n "$cfg_val" && -z "$OUTPUT_DIR" ]] && OUTPUT_DIR="${REPO_ROOT}/${cfg_val}"
    fi
  else
    echo "ℹ️  yq not found — using defaults. Install yq for config file support." >&2
  fi
  return 0  # last &&-list may legitimately be false — don't let set -e kill the script
}

# ── Apply task-type defaults (after config + CLI args) ──
apply_task_defaults() {
  # review だけ pair（主+副）を既定にする。explore / implement は従来の分散のまま。
  # 既存の分散モードは --mode distributed で引き続き使える。
  if [[ -z "$MODE" ]]; then
    if [[ "$TASK_TYPE" == "review" ]]; then MODE="pair"; else MODE="distributed"; fi
  fi
  # pair は review 専用。build_pair_plan は review の観点しか組まないので、他タスクで
  # 受け入れると dry-run だけ成功して実行時に「観点ファイルが無い」で全件失敗する
  # （プランは正しく見えるのに中身が存在しない、という一番たちの悪い形）。
  if [[ "$MODE" == "pair" && "$TASK_TYPE" != "review" ]]; then
    echo "ERROR: --mode pair is review-only (got --task ${TASK_TYPE})." >&2
    echo "       explore / implement use the distributed plan." >&2
    exit 1
  fi
  [[ -z "$OUTPUT_DIR" ]] && OUTPUT_DIR="$(get_default_output_dir "$TASK_TYPE")"
  [[ -z "$TIMEOUT" ]] && TIMEOUT="$(get_default_timeout "$TASK_TYPE")"
  [[ -z "$STRATEGY" ]] && STRATEGY="$(get_default_strategy "$TASK_TYPE")"
  return 0  # last &&-list may legitimately be false — don't let set -e kill the script
}

# ── CLI Detection ──
detect_available_clis() {
  AVAILABLE_CLIS=""
  local cli_name cmd

  for cli_name in $ALL_CLIS; do
    cmd="$(get_cli_command "$cli_name")"
    if command -v "$cmd" &>/dev/null; then
      AVAILABLE_CLIS="${AVAILABLE_CLIS:+$AVAILABLE_CLIS }$cli_name"
      echo "  ✅ ${cli_name} (${cmd})" >&2
    else
      echo "  ❌ ${cli_name} (${cmd}) — not installed" >&2
    fi
  done

  if [[ -z "$AVAILABLE_CLIS" ]]; then
    echo "" >&2
    echo "ERROR: No AI CLIs are installed. Install at least one:" >&2
    echo "  npm install -g @anthropic-ai/claude-code" >&2
    echo "  npm install -g @openai/codex" >&2
    echo "  npm install -g @google/gemini-cli" >&2
    exit 1
  fi
}

# ── Add to Execution Plan ──
add_to_plan() {
  local cli_name="$1" perspective="$2"
  EXECUTION_PLAN="${EXECUTION_PLAN:+$EXECUTION_PLAN
}${cli_name}:${perspective}"
}

# ── Build Execution Plan (distributed mode) ──
build_distributed_plan() {
  EXECUTION_PLAN=""
  local cli_name perspectives fallback_target

  for cli_name in $ALL_CLIS; do
    perspectives="$(get_cli_perspectives "$cli_name")"
    [[ -z "$perspectives" ]] && continue

    # A cost-bearing CLI must never enter any default task plan merely because it
    # is installed. The cost tier is the SSOT: future metered CLIs inherit the
    # same fail-safe without another name-specific branch. An explicit --cli is
    # the auditable opt-in for review, explore, and implement alike (Issue #250).
    if [[ "$(get_cli_cost_tier "$cli_name")" == "metered" && -z "$CLI_FILTER" ]]; then
      echo "  ⏭  ${cli_name} skipped (metered). Opt in with --cli ${cli_name}." >&2
      continue
    fi

    if [[ -n "$CLI_FILTER" ]] && ! list_contains "$CLI_FILTER" "$cli_name"; then
      continue
    fi

    if list_contains "$AVAILABLE_CLIS" "$cli_name"; then
      # When both filters are explicit, the pair is the user's execution intent.
      # This is also the shape printed by failure advice for a substitute CLI:
      # forcing it back through the ownership registry can otherwise produce an
      # empty plan (for example codex-cli + security-analysis).
      #
      # 観点は**複数でもよい**。以前はここで `"$PERSPECTIVE_FILTER" != *" "*` を要求し、
      # 2 つ以上を指定すると下の所有権フィルタへ落ちていた。そちらは「1 つも一致
      # しなかった」ときにしか警告しないため、**一部だけ所有している場合に残りが
      # 黙って落ちる**（実測: codex-cli へ 3 観点を渡すと 1 観点だけが計画され、
      # 落ちた 2 つはどこにも名指しされなかった）。下のループは元から複数を回せる
      # 形になっており、条件だけが単数に絞っていた。CLI が 1 つに定まっていれば、
      # 「この CLI にこれらの観点をやらせる」は曖昧さのない指定なので通す。
      if [[ -n "$CLI_FILTER" && "$CLI_FILTER" != *" "* \
            && -n "$PERSPECTIVE_FILTER" ]]; then
        for p in $PERSPECTIVE_FILTER; do
          perspective_excluded "$p" && continue
          add_to_plan "$cli_name" "$p"
        done
      else
        local matched_perspective=false
        for p in $perspectives; do
          perspective_excluded "$p" && continue
          if [[ -n "$PERSPECTIVE_FILTER" ]] && ! list_contains "$PERSPECTIVE_FILTER" "$p"; then
            continue
          fi
          add_to_plan "$cli_name" "$p"
          matched_perspective=true
        done

        # Availability and perspective ownership are different facts. Surface
        # the latter so an installed CLI is not mistaken for missing.
        if [[ -n "$PERSPECTIVE_FILTER" && "$matched_perspective" == "false" ]]; then
          if [[ "$PERSPECTIVE_FILTER" == *" "* ]]; then
            echo "  ⏭  ${cli_name} skipped — owns none of the requested perspectives (${PERSPECTIVE_FILTER})" >&2
          else
            echo "  ⏭  ${cli_name} skipped — owns no '${PERSPECTIVE_FILTER}' perspective" >&2
          fi
          echo "     (has: ${perspectives}). Use --mode cross-model to include it." >&2
        fi
      fi
    else
      fallback_target="$(resolve_available_fallback "$cli_name")"
      if [[ -n "$fallback_target" ]]; then
        if [[ -n "$CLI_FILTER" ]] && ! list_contains "$CLI_FILTER" "$fallback_target"; then
          echo "  ⚠️  ${cli_name}: fallback ${fallback_target} excluded by --cli filter. Skipping." >&2
          continue
        fi
        # 「対応表どおりの代替」と「対応表が尽きて選び直した先」は利用者にとって
        # 別の話。後者は設定していない CLI が担当することになるので、そう読める
        # 表示にする。コスト帯も出す（最後の砦は課金先が変わりうる）。
        if [[ "$fallback_target" == "$(get_cli_fallback "$cli_name")" ]]; then
          echo "  ↪ ${cli_name} → ${fallback_target} (fallback — ${cli_name} not installed)" >&2
        else
          echo "  ↪ ${cli_name} → ${fallback_target} [$(get_cli_cost_tier "$fallback_target")] (last-resort — configured chain exhausted)" >&2
        fi
        for p in $perspectives; do
          perspective_excluded "$p" && continue
          if [[ -n "$PERSPECTIVE_FILTER" ]] && ! list_contains "$PERSPECTIVE_FILTER" "$p"; then
            continue
          fi
          add_to_plan "$fallback_target" "$p"
        done
      else
        # 「代替が設定されていない」と「設定はあるが連鎖の先まで全部未導入」は
        # 利用者にとって別の話（後者はインストールで直る）。区別して出す。
        echo "  ⚠️  ${cli_name}: no installed fallback (configured: $(get_cli_fallback "$cli_name")). Skipping: ${perspectives}" >&2
      fi
    fi
  done

  # Apply cost strategy: minimize_cost moves premium → free-tier.
  # The substitute was hardcoded to cursor-cli until issue #240 deleted that arm;
  # gemini-cli [free-tier] took its place. There is no tier ordering in the code
  # (KNOWN_TIERS is an unordered set), so this is a named choice, not a computed
  # one — which is deliberate: naming the substitute keeps the swap readable in
  # the plan output, and the user sees which model actually ran.
  #
  # Known tradeoff of that swap: the substitute is now the ONE rate-limited tier.
  # Rate limiting is a *runtime* failure, and runtime fallback is deliberately
  # absent (see the header), so a throttled task is zero coverage for that
  # perspective rather than a retry elsewhere. As mitigation (issue #251),
  # execute_tasks runs a free-tier CLI's tasks sequentially on one worker (no
  # simultaneous burst) and show_plan names the residual risk — the limit itself
  # does not disappear, so spreading perspectives across CLIs remains the real fix.
  if [[ "$STRATEGY" == "minimize_cost" && -z "$CLI_FILTER" ]]; then
    local new_plan=""
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      local cli="${entry%%:*}"
      local persp="${entry#*:}"
      if [[ "$cli" == "claude-code" ]] && list_contains "$AVAILABLE_CLIS" "gemini-cli"; then
        echo "  💰 minimize_cost: ${persp}: claude-code → gemini-cli" >&2
        new_plan="${new_plan:+$new_plan
}gemini-cli:${persp}"
      else
        new_plan="${new_plan:+$new_plan
}${entry}"
      fi
    done <<< "$EXECUTION_PLAN"
    EXECUTION_PLAN="$new_plan"
  fi
}

# ── Build Execution Plan (pair mode: main + sub) ──
#
# 主 = review 観点すべて / 副 = 総合レビュー 1 本。副が居なければ主だけに縮退する。
# 縮退はすべて続行（exit 0）で、止めるのは「主が未インストール」のときだけ。
build_pair_plan() {
  EXECUTION_PLAN=""
  PAIR_SUB_DROPPED=false
  local p sub_effective=""

  if ! list_contains "$AVAILABLE_CLIS" "$REVIEW_MAIN"; then
    echo "ERROR: main reviewer '${REVIEW_MAIN}' is not installed." >&2
    echo "       Install it, or pick another with --set-reviewers." >&2
    return 1
  fi

  # 副の縮退判定。どれも「主のみで続行」で、理由だけを変えて伝える。
  if [[ -z "$REVIEW_SUB" ]]; then
    echo "  ℹ️  No sub reviewer set — running single-reviewer. Set one for cross-model coverage." >&2
  elif [[ "$REVIEW_SUB" == "$REVIEW_MAIN" ]]; then
    echo "  ⏭  sub reviewer is the same CLI as main (${REVIEW_MAIN}) — skipping the duplicate." >&2
  elif ! list_contains "$AVAILABLE_CLIS" "$REVIEW_SUB"; then
    echo "  ⚠️  sub reviewer '${REVIEW_SUB}' is not installed — running single-reviewer." >&2
  else
    sub_effective="$REVIEW_SUB"
  fi

  for p in $(get_cli_perspectives_review "$REVIEW_MAIN"); do
    perspective_excluded "$p" && continue
    [[ -n "$PERSPECTIVE_FILTER" ]] && ! list_contains "$PERSPECTIVE_FILTER" "$p" && continue
    add_to_plan "$REVIEW_MAIN" "$p"
  done
  # 主は「review 観点すべて」を担当する。所有レジストリは分散モード用の割当なので、
  # 主が所有していない観点もここでは主に回す（それが pair モードの定義）。
  for p in $(all_review_perspectives); do
    list_contains "$(get_cli_perspectives_review "$REVIEW_MAIN")" "$p" && continue
    # 総合観点は副の担当なので、既定では主に載せない。ただし --perspective で
    # 明示指定されていて副が居ない場合は主へ回す。ここを飛ばすと空プランになり、
    # 「副が居なければ主のみで続行」という縮退契約に反して exit 1 で止まる。
    if [[ "$p" == "$COMPREHENSIVE_PERSPECTIVE" ]]; then
      if [[ -n "$sub_effective" ]] \
        || [[ -z "$PERSPECTIVE_FILTER" ]] \
        || ! list_contains "$PERSPECTIVE_FILTER" "$COMPREHENSIVE_PERSPECTIVE"; then
        continue
      fi
      echo "  ↪ ${COMPREHENSIVE_PERSPECTIVE} → ${REVIEW_MAIN} (no sub reviewer available)" >&2
    fi
    perspective_excluded "$p" && continue
    [[ -n "$PERSPECTIVE_FILTER" ]] && ! list_contains "$PERSPECTIVE_FILTER" "$p" && continue
    add_to_plan "$REVIEW_MAIN" "$p"
  done

  if [[ -n "$sub_effective" ]]; then
    if ! perspective_excluded "$COMPREHENSIVE_PERSPECTIVE" \
      && { [[ -z "$PERSPECTIVE_FILTER" ]] || list_contains "$PERSPECTIVE_FILTER" "$COMPREHENSIVE_PERSPECTIVE"; }; then
      # 副に従量課金 CLI を選ぶのは明示的な指定なので opt-in とみなす。ただし
      # コスト帯はプラン表示に出るので、黙って課金されることはない。
      add_to_plan "$sub_effective" "$COMPREHENSIVE_PERSPECTIVE"
    elif perspective_excluded "$COMPREHENSIVE_PERSPECTIVE"; then
      # --exclude-perspective で副の唯一の担当を外したケース。理由は名乗るが、
      # 単一 CLI 縮退警告（下の PAIR_SUB_DROPPED）は立てない。「その観点を走らせ
      # るな」という明示指定は #183 の --cli と同じく意図的な単一モデルなので、
      # 黙る側に倒す。
      echo "  ⏭  sub reviewer '${sub_effective}' runs only '${COMPREHENSIVE_PERSPECTIVE}', excluded by --exclude-perspective — running single-reviewer." >&2
    else
      # --perspective が総合観点を含まないケース（Issue #597）。他 3 経路（副が
      # 未設定 / 主と同一 / 未導入）は全部理由を出しているのに、ここだけ else が
      # 無く無言で落ちていた。書式を揃える。
      #
      # ここだけが「クロスモデルにできたのに単一になった」経路なので、単一 CLI
      # 縮退警告のフラグを立てるのもここだけ。他 3 経路は主しか使えない状況を
      # それぞれの 1 行で説明済みで、そこへ「--mode cross-model にせよ」と足しても
      # 副が居ない事実は変わらない。逆に --perspective comprehensive-review は
      # 副だけが残って単一 CLI になるが、それは要求どおりなので警告しない
      # （プラン CLI 数だけを見る一般化された gate では、この差が潰れる）。
      PAIR_SUB_DROPPED=true
      echo "  ⏭  sub reviewer '${sub_effective}' runs only '${COMPREHENSIVE_PERSPECTIVE}', not in --perspective (${PERSPECTIVE_FILTER}) — running single-reviewer." >&2
    fi
  fi
  return 0
}

# review の観点ファイル一覧（総合レビューを含む、ディスク上の実体）。
# タスク種別に対応する観点の一覧。観点の実体は perspectives/<task>/*.md なので、
# 一覧も除外の検証もここから導出する。別に配列を持つと、ファイルを足したときに
# 片方だけ古くなる。
all_task_perspectives() {
  local f
  for f in "${SCRIPT_DIR}/perspectives/${TASK_TYPE}"/*.md; do
    [[ -f "$f" ]] || continue
    basename "$f" .md
  done
}

all_review_perspectives() {
  local f
  for f in "${SCRIPT_DIR}/perspectives/review"/*.md; do
    [[ -f "$f" ]] || continue
    basename "$f" .md
  done
}

# ── Build Execution Plan (cross-model mode) ──
build_cross_model_plan() {
  EXECUTION_PLAN=""
  local perspective="${PERSPECTIVE_FILTER:-code-review}"
  perspective="${perspective%% *}"

  echo "  🔄 Cross-model mode: all CLIs run '${perspective}'" >&2

  for cli_name in $AVAILABLE_CLIS; do
    if [[ -n "$CLI_FILTER" ]] && ! list_contains "$CLI_FILTER" "$cli_name"; then
      continue
    fi
    # Copilot CLI is metered — include only when explicitly requested via --cli
    if [[ "$cli_name" == "copilot-cli" && -z "$CLI_FILTER" ]]; then
      echo "  ⏭  copilot-cli skipped (metered). Opt in with --cli copilot-cli." >&2
      continue
    fi
    perspective_excluded "$perspective" && continue
    add_to_plan "$cli_name" "$perspective"
  done
}

# ── Validate Requested CLIs ──
# An unknown --cli used to fail late and vaguely: the name matched nothing in the
# ownership registry, every CLI was filtered out, and the empty-plan guard then
# reported "no CLI/perspective matched the given filters" without ever naming the
# CLI that does not exist — leaving the user to guess whether the fault was the
# --cli, the --perspective, or the --mode. A retired name (cursor-cli, removed in
# issue #240) is the case that makes that guessing expensive, because the name
# looks valid. Reject it here instead: before the plan is built, naming the
# offending value and the CLIs that do exist.
# 存在しない観点名の除外を黙って受けると、typo が「除外したつもり」で素通りし、
# 意図せず課金される観点が走る。名前は観点ファイルの実体と照合する。
validate_excluded_perspectives() {
  [[ -n "$EXCLUDE_PERSPECTIVES" ]] || return 0
  local known ex
  known="$(all_task_perspectives | tr '\n' ' ')"
  for ex in $EXCLUDE_PERSPECTIVES; do
    if ! list_contains "$known" "$ex"; then
      echo "ERROR: --exclude-perspective に存在しない観点が指定されました: ${ex}" >&2
      echo "       task '${TASK_TYPE}' で使える観点: ${known}" >&2
      exit 2
    fi
  done
}

validate_requested_clis() {
  local cli_name
  for cli_name in $CLI_FILTER; do
    if ! is_safe_token "$cli_name"; then
      echo "ERROR: unsafe CLI name: '${cli_name}'" >&2
      return 1
    fi
    if ! list_contains "$ALL_CLIS" "$cli_name"; then
      echo "ERROR: unknown CLI: '${cli_name}'" >&2
      echo "       Known CLIs: ${ALL_CLIS}" >&2
      return 1
    fi
  done
}

# ── Validate Requested Perspectives ──
# A dry-run is a plan validation boundary, not only a pretty-printer. Reject an
# unsafe, unknown, or other-task perspective before showing a successful plan;
# otherwise the same command fails only after a real CLI dispatch is attempted.
validate_requested_perspectives() {
  local perspective perspective_file
  for perspective in $PERSPECTIVE_FILTER; do
    if ! is_safe_token "$perspective"; then
      echo "ERROR: unsafe perspective name: '${perspective}'" >&2
      return 1
    fi
    perspective_file="$(resolve_perspective_file "$perspective")"
    if [[ -z "$perspective_file" ]]; then
      echo "ERROR: perspective '${perspective}' does not exist for task '${TASK_TYPE}'." >&2
      return 1
    fi
  done
}

# ── Show Execution Plan ──
show_plan() {
  local emoji
  emoji="$(get_task_emoji "$TASK_TYPE")"

  echo "" >&2
  echo "📋 Execution Plan:" >&2
  echo "   Task: ${TASK_TYPE} ${emoji}" >&2
  echo "   Mode: ${MODE}" >&2
  echo "   Strategy: ${STRATEGY}" >&2
  echo "   Parallel: ${PARALLEL}" >&2
  echo "   Output: ${OUTPUT_DIR}" >&2
  if [[ "$STAGED_DIFF" == "true" ]]; then
    echo "   Diff source: staged index (git diff --cached)" >&2
  else
    echo "   Base branch: ${BASE_BRANCH} (${BASE_BRANCH_SOURCE})" >&2
  fi
  echo "   Config: ${CONFIG_FILE} (${CONFIG_SOURCE})" >&2
  echo "   Timeout: ${TIMEOUT}s per CLI" >&2
  echo "   Resume: ${RESUME}" >&2
  echo "   Runtime fallback: none — a CLI that fails or times out is reported as" >&2
  echo "                     failed, never retried on another model (see --help)" >&2
  if [[ -n "$DESCRIPTION" ]]; then
    echo "   Description: ${DESCRIPTION}" >&2
  fi
  echo "" >&2

  if [[ -z "$EXECUTION_PLAN" ]]; then
    echo "   ⚠️  No CLIs/perspectives to execute." >&2
    return
  fi

  local current_cli=""
  local planned_clis=""
  local planned_cli_count=0
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    local cli="${entry%%:*}"
    local persp="${entry#*:}"
    if ! list_contains "$planned_clis" "$cli"; then
      planned_clis="${planned_clis:+$planned_clis }$cli"
      planned_cli_count=$((planned_cli_count + 1))
    fi
    if [[ "$cli" != "$current_cli" ]]; then
      current_cli="$cli"
      local tier
      tier="$(get_cli_cost_tier "$cli")"
      echo "   ${cli} [${tier}]:" >&2
    fi
    echo "     - ${persp}" >&2
  done <<< "$EXECUTION_PLAN"

  # 同一 CLI への観点集中の可視化（Issue #251）。minimize_cost の振替でレート制限
  # のある free-tier CLI に複数観点が集まる形が典型。実行側は同一 CLI 内を逐次化
  # 済みだが、逐次でも連続リクエストで throttle されうるため、プランの時点で
  # リスクを名指しする（実行時 fallback は無い = throttle された観点のカバレッジは
  # ゼロになる、という帰結まで書く）。
  # --sequential でも残存リスク（連続リクエストの throttle）は同じなので、警告は
  # 実行モードに関係なく出し、実行形の説明だけ切り替える。
  local warn_cli warn_count warn_tier warn_shape
  if [[ "$PARALLEL" == "true" ]]; then
    warn_shape="Its tasks are serialized (no burst)"
  else
    warn_shape="The run is already sequential"
  fi
  for warn_cli in $planned_clis; do
    warn_count="$(printf '%s\n' "$EXECUTION_PLAN" | LC_ALL=C sort -u | grep -c "^${warn_cli}:")" || warn_count=0
    warn_tier="$(get_cli_cost_tier "$warn_cli")"
    if [[ "$warn_count" -ge 2 && "$warn_tier" == "free-tier" ]]; then
      echo "" >&2
      echo "   ⚠️  ${warn_cli} [${warn_tier}] runs ${warn_count} perspectives. ${warn_shape}," >&2
      echo "       but consecutive requests can still hit the free-tier rate limit — and there" >&2
      echo "       is no runtime fallback, so a throttled perspective yields zero coverage." >&2
      echo "       Serialization also means this CLI can take up to ${warn_count} × ${TIMEOUT}s" >&2
      echo "       wall-clock in the worst case. Consider spreading perspectives across CLIs" >&2
      echo "       (--strategy balanced)." >&2
    fi
  done

  # An explicit --cli is intentionally single-model and should stay quiet.
  # Cross-model mode is already the remedy, so this warning only applies when a
  # review resolved *implicitly* to one CLI.
  #
  # pair モードも対象に含める（Issue #597）。#183 でこの警告を入れた時点では
  # review の既定が distributed だったが、#255 で pair が既定になり、いちばん
  # 踏みやすい構成でだけ警告が出ない状態になっていた。ただし pair は「プランの
  # CLI が 1 つ」だけでは判定できない — --perspective comprehensive-review は
  # 副だけの単一 CLI プランになるが、それは要求どおりで警告は雑音になる。
  # 「副を立てられたのに落ちた」= PAIR_SUB_DROPPED を条件にする。
  #
  # 非対称なのは承知のうえ: distributed 側は利用者の意図を見ずに、--exclude-perspective
  # で 1 CLI へ絞った場合でも警告する。あちらは観点と CLI の対応がレジストリ次第で、
  # 「1 つに絞った」のか「絞った結果たまたま 1 つになった」のかを区別できないため。
  # pair は副の担当が comprehensive-review 固定なので、その区別がつく。
  if [[ "$TASK_TYPE" == "review" && -z "$CLI_FILTER" && "$planned_cli_count" -eq 1 ]] \
     && { [[ "$MODE" == "distributed" ]] \
          || [[ "$MODE" == "pair" && "$PAIR_SUB_DROPPED" == "true" ]]; }; then
    echo "" >&2
    echo "   ⚠️  Plan resolved to a single CLI (${planned_clis}). A failure or timeout here" >&2
    echo "       means zero review coverage — runtime fallback is deliberately absent." >&2
    if [[ "$PERSPECTIVE_FILTER" == *" "* ]]; then
      echo "       For cross-model coverage, run each perspective separately:" >&2
      local requested_perspective
      for requested_perspective in $PERSPECTIVE_FILTER; do
        echo "         --mode cross-model --perspective ${requested_perspective}" >&2
      done
    else
      echo "       For cross-model coverage: --mode cross-model --perspective ${PERSPECTIVE_FILTER:-code-review}" >&2
    fi
  fi
  echo "" >&2
}

# ── Resolve perspective file path (task-type aware) ──
resolve_perspective_file() {
  local perspective="$1"

  # Try task-type subdirectory first
  local subdir_file="${SCRIPT_DIR}/perspectives/${TASK_TYPE}/${perspective}.md"
  if [[ -f "$subdir_file" ]]; then
    echo "$subdir_file"
    return
  fi

  # Fall back to root perspectives (backward compat)
  local root_file="${SCRIPT_DIR}/perspectives/${perspective}.md"
  if [[ -f "$root_file" ]]; then
    echo "$root_file"
    return
  fi

  echo ""
}

# ── Staging Directory（Issue #392） ──
# implement タスクで生成物を置かせる実ディレクトリ。**タスク単位** = (CLI, 観点) 単位
# であることが要点。CLI 単位にすると、同じ CLI に複数の観点が乗ったプランで並列に
# 走るタスクが同一ディレクトリへ書き、同名ファイルが後勝ちで黙って消える。これは
# 例外的な構成ではない: 導入済みの CLI が 1 つしかなければ fallback で全観点がその
# CLI に集まるし、CLI が 1 つ欠けるだけでも fallback 先に 2 観点が乗る（実測）。
#
# パスを組み立てるのはここ 1 箇所で、消費点は run_single_task（作成して渡す）と
# clear_planned_outputs（前回実行の残骸を消す）。両者がずれると「消した先と書く先が
# 違う」形の stale が静かに開く。
# ここを変えたらレイアウトを literal で案内している次も追随させること:
#   - append_plan_sections の "**Staging:**" 行 … 実パスを出すので tests/
#     adapter-prompt-guard が照合する（追随漏れは赤になる）
#   - generate_implement_report のヘッダの `<cli>/files/<perspective>/` … 形だけの
#     案内で、**機械ゲートは無い**。ここは人が揃える
#   - skills/multi-implement/SKILL.md の表と注記 … 同上、機械ゲートは無い
#
# レポート本体（${OUTPUT_DIR}/${cli}/${persp}.md）と同じ階層に置かず専用の
# サブディレクトリへ落とすのは、write_output が CLI 完走**後**に ${persp}.md を
# 書くため — エージェントが同名のファイル（例: refactoring.md）を生成すると
# レポートに黙って上書きされる。
#
# 引数はどちらも validate_execution_plan で安全な単一セグメントと確認済み。
staging_dir_for() {
  printf '%s\n' "${OUTPUT_DIR}/${1}/files/${2}"
}

# 前回実行の staging を消す。`rm -rf` を素で撃たないのは、パスの**途中の**コンポーネント
# が symlink だと再帰削除が OUTPUT_DIR の外へ抜けるため。例えば <cli>/files が
# /tmp/victim を指す symlink なら、rm -rf <cli>/files/<persp> は /tmp/victim/<persp> を
# 消す。OUTPUT_DIR を pwd -P しても、文字列 prefix 判定では途中の symlink を見抜けない。
# clear_planned_outputs は「プランの対象以外はディスク上の何にも触れない」と宣言して
# いるので、その宣言を実際に成り立たせるための検査。
#
# 消す前に**解決後の物理パス**が OUTPUT_DIR 配下かを確認し、外なら消さずに落とす。
# 削除自体も解決後のパスに対して行い、検査したものと消すものを一致させる。
clear_staging_dir() {
  local staging_dir="$1"

  if [[ -d "$staging_dir" ]]; then
    local resolved
    if ! resolved="$(cd "$staging_dir" && pwd -P)"; then
      echo "ERROR: cannot resolve staging dir: ${staging_dir}" >&2
      return 1
    fi
    case "$resolved" in
      "$OUTPUT_DIR"/*) ;;
      *)
        echo "ERROR: staging dir resolves outside the output dir — refusing to delete." >&2
        echo "       path:     ${staging_dir}" >&2
        echo "       resolves: ${resolved}" >&2
        echo "       output:   ${OUTPUT_DIR}" >&2
        echo "       A symlinked component would make this a recursive delete elsewhere." >&2
        return 1
        ;;
    esac
    if ! rm -rf "$resolved"; then
      echo "ERROR: cannot clear staging dir: ${resolved}" >&2
      echo "       A previous run's files would be reported as this run's output." >&2
      return 1
    fi
    return 0
  fi

  # ディレクトリでない残骸（ファイル・symlink・壊れた symlink）はリンク/ファイル
  # 自体だけを消す。`rm -f` は symlink の指す先を追わないので、ここは安全。
  if [[ -e "$staging_dir" || -L "$staging_dir" ]]; then
    if ! rm -f "$staging_dir"; then
      echo "ERROR: cannot remove non-directory at staging path: ${staging_dir}" >&2
      return 1
    fi
  fi
  return 0
}

# implement の CLI は常に REPO_ROOT から起動する。その CWD が codex workspace-write /
# grok workspace / Copilot path boundary の書き込みルートになるため、OUTPUT_DIR も同じ
# 物理ルート配下でなければならない。警告して続けると、プロンプトが「書ける」と名指し
# した staging を sandbox が拒否するので、CLI を起動する前に fail-loud で止める。
validate_implement_output_boundary() {
  [[ "${TASK_TYPE:-review}" == "implement" ]] || return 0
  local repo_physical
  if ! repo_physical="$(cd "$REPO_ROOT" && pwd -P)"; then
    echo "ERROR: cannot resolve repository sandbox root: ${REPO_ROOT}" >&2
    return 1
  fi
  case "$OUTPUT_DIR" in
    "$repo_physical"|"$repo_physical"/*) return 0 ;;
  esac
  echo "ERROR: implement output dir is outside the CLI sandbox root — refusing to name an unwritable staging path." >&2
  echo "       output:  ${OUTPUT_DIR}" >&2
  echo "       sandbox: ${repo_physical}" >&2
  echo "       Choose --output-dir under the repository root." >&2
  return 1
}

# ── 出力ディレクトリのリポジトリ相対パス ──
#
# capture_repo_snapshot へ渡す除外パス。orchestrator は実行中ずっとこの配下へ成果物を
# 書き続けるので、作業ツリーの変化として数えると**正常な実行が毎回**「リポジトリが
# 変化した」と判定される。本リポジトリは .review-results/ を gitignore しているが、
# 利用者のリポジトリがそうしている保証はない。
#
# 含有関係を確定できないときは**何も返さない**（= 何も除外しない）。推測した接頭辞で
# 除外すると、本来監視すべき範囲を黙って監視対象から外しかねない。なお出力先が
# リポジトリ外なのは異常ではない — 配下であることを検査しているのは implement だけで
# （validate_implement_output_boundary）、review / explore は外を指定できる。
output_dir_repo_relative() {
  [[ -n "${OUTPUT_DIR:-}" ]] || return 0
  local repo_physical parent base resolved
  repo_physical="$(cd "$REPO_ROOT" 2>/dev/null && pwd -P)" || return 0
  # OUTPUT_DIR はこの時点ではまだ存在しないことがある（作るのは execute_tasks）。
  # 親は存在するので、親を物理パスへ解決してから名前を足す。論理パス（$PWD 由来）と
  # 物理パス（git rev-parse --show-toplevel 由来）の綴り違いを揃える狙いも兼ねる
  # （symlink 越しのチェックアウトで同じ場所が別の綴りになる。execute_tasks が
  # OUTPUT_DIR を pwd -P で正規化しているのと同じ理由）。
  parent="$(dirname "$OUTPUT_DIR")"
  base="$(basename "$OUTPUT_DIR")"
  parent="$(cd "$parent" 2>/dev/null && pwd -P)" || return 0
  resolved="${parent%/}/${base}"
  case "$resolved" in
    "$repo_physical"/*) printf '%s\n' "${resolved#"$repo_physical"/}" ;;
    *) return 0 ;;
  esac
}

# ── 出力ディレクトリの境界検証 ──
#
# リビジョンガードは「出力ディレクトリ配下は orchestrator 自身が書くので数えない」
# という前提で除外を掛ける。その前提が崩れる 2 つの構成をここで弾く。黙って動かすと、
# **正しい実行が毎回破棄される**か、**ガードが実質的に無効化される**。
#
#   1) 出力先がリポジトリ root … 除外は厳密な部分パスしか表せないので何も除外できず、
#      自分が書く .fixed-diff で毎回ガードに掛かる。しかも診断は「リポジトリが変化した」
#      と出るので、利用者は起きていない checkout を探すことになる。
#   2) 出力先に tracked ファイルがある … この実行はその配下を上書き・削除するため
#      tracked の内容が動き、やはり毎回破棄になる。同時にこの検査は `--output-dir src`
#      のようにソースを含むディレクトリを出力先に指定して**監視から外す**使い方も塞ぐ
#      （除外は 4 つの問い合わせすべてに効くので、弾かないと実コードの変更がガードから
#      消える）。
validate_output_dir_boundary() {
  [[ "$IN_GIT_REPO" == "true" ]] || return 0
  local repo_physical rel tracked
  repo_physical="$(cd "$REPO_ROOT" 2>/dev/null && pwd -P)" || return 0

  if [[ "$OUTPUT_DIR" == "$repo_physical" ]]; then
    echo "ERROR: the output dir must not be the repository root: ${OUTPUT_DIR}" >&2
    echo "       This run writes its own artifacts there, and the revision guard would read" >&2
    echo "       those writes as the repository changing under it — every run would be" >&2
    echo "       discarded, blaming a checkout that never happened." >&2
    echo "       Pass --output-dir <subdirectory> instead." >&2
    return 1
  fi

  rel="$(output_dir_repo_relative)"
  # リポジトリ外の出力先は対象外（review / explore では正当な指定）。
  [[ -n "$rel" ]] || return 0

  tracked="$(cd "$repo_physical" && git ls-files -- ":(literal)${rel}" 2>/dev/null | head -1)" || return 0
  if [[ -n "$tracked" ]]; then
    echo "ERROR: the output dir contains tracked files: ${OUTPUT_DIR}" >&2
    echo "       first match: ${tracked}" >&2
    echo "       This run overwrites and deletes files under the output dir. Tracked content" >&2
    echo "       there would register as the repository changing mid-run, so every run would" >&2
    echo "       be discarded after the CLIs had already been paid for." >&2
    echo "       Pass an --output-dir that holds no tracked files." >&2
    return 1
  fi
  return 0
}

# ── この実行の diff を 1 度だけ固定する ──
#
# 以前は各アダプタが**自分の起動時に** git から diff を取っていた。並列タスクの起動
# 時刻はばらけるので、実行中に checkout / commit / stash が入るとタスクごとに別の
# 瞬間の diff をレビューし、しかも全員が正常終了する。ここで 1 度だけ取ってファイルへ
# 固定し、全タスクへ同じバイト列を配る。
#
# 置き場所が出力ディレクトリなのは、スナップショットの除外対象と同じ場所だから
# （作業ツリーを汚さない）。同じ出力先の同時実行は acquire_output_lock が既に排他して
# いるので、固定名で衝突しない。実行後もそのまま残すので、レポートと並べて
# 「実際に何をレビューしたのか」を後から確認できる。
create_fixed_diff() {
  [[ "$IN_GIT_REPO" == "true" ]] || return 0
  # diff をプロンプトへ載せないタスクでは何も固定しない。載せないものを固定しても
  # 意味が無いうえ、diff を持たないリポジトリ状態での失敗を持ち込むだけになる。
  if [[ "$TASK_TYPE" != "review" && "$INCLUDE_DIFF" != "true" ]]; then
    return 0
  fi
  local target="${OUTPUT_DIR}/.fixed-diff"
  # get_diff_content は STAGED_DIFF を見て --staged 実行を切り替える（adapter-common）。
  # 同じプロセス内の変数なので、ここでの呼び出しにもそのまま効く。
  if ! get_diff_content "$BASE_BRANCH" >"$target"; then
    echo "ERROR: cannot capture this run's diff: ${target}" >&2
    echo "       Every task must review the same bytes; refusing to let each adapter" >&2
    echo "       compute its own diff instead." >&2
    rm -f "$target" || echo "WARNING: could not remove the partial fixed diff: ${target}" >&2
    return 1
  fi
  FIXED_DIFF_FILE="$target"
  return 0
}

# ── 基準スナップショットの取得と diff 固定（この 2 つは隣接させる） ──
#
# 基準を先に離れた場所で取ると、基準取得から diff 固定までのあいだに「動いて元へ戻る」
# 変化が入りうる。前後のスナップショットは一致するのに、固定 diff だけが途中の状態を
# 写した内容になり、**この修正が防ごうとしている食い違いを自分で作る**。
# そこで固定の直前と直後で 2 回取り、一致しなければ開始前に止める。一致した方を基準に
# 採用するので、基準と固定 diff が同じ瞬間のリポジトリを写していることを、
# **スナップショットが見える範囲で**確かめたことになる（見えない範囲は
# capture_repo_snapshot の「見えないものを明示しておく」の項を参照）。
#
# --dry-run はここへ到達しない（main が手前で exit する）ので、実際にタスクを起動する
# 実行だけが対象になる。review だけでなく explore / implement も対象: どのタスクでも
# CLI エージェントは作業ツリーのファイルを読み、implement はそこへ書きうるので、
# 対象が動けば結果の意味が変わるのは同じ。
capture_baseline_and_fix_diff() {
  [[ "$IN_GIT_REPO" == "true" ]] || return 0

  local exclude before after
  exclude="$(output_dir_repo_relative)"

  if ! before="$(capture_repo_snapshot "$exclude")"; then
    echo "ERROR: cannot read the repository state — refusing to start." >&2
    echo "       Without a baseline there is no way to tell afterwards whether the" >&2
    echo "       reviewed revision stayed put, and the result could not be trusted." >&2
    return 1
  fi

  create_fixed_diff || return 1

  if ! after="$(capture_repo_snapshot "$exclude")"; then
    echo "ERROR: cannot re-read the repository state while fixing this run's diff." >&2
    return 1
  fi
  if [[ "$before" != "$after" ]]; then
    echo "ERROR: the repository changed while this run's diff was being captured." >&2
    echo "       The captured diff would describe a state that no longer holds." >&2
    echo "       Re-run once the repository is settled." >&2
    return 1
  fi

  REPO_SNAPSHOT_BEFORE="$after"
  return 0
}

# ── Execute Single Task ──
run_single_task() {
  local cli_name="$1"
  local perspective="$2"

  local adapter
  adapter="$(get_cli_adapter "$cli_name")"

  local perspective_file
  perspective_file="$(resolve_perspective_file "$perspective")"
  local output_file="${OUTPUT_DIR}/${cli_name}/${perspective}.md"

  if [[ -z "$perspective_file" ]]; then
    echo "  ⚠️  Perspective file not found: ${TASK_TYPE}/${perspective}.md" >&2
    return 1
  fi

  if [[ ! -f "$adapter" ]]; then
    echo "  ⚠️  Adapter not found: ${adapter}" >&2
    return 1
  fi

  local extra_args=()
  extra_args+=(--task-type "$TASK_TYPE")
  if [[ -n "$DESCRIPTION" ]]; then
    extra_args+=(--description "$DESCRIPTION")
  fi
  # 固定した diff を全タスクへ配る。渡さなかった場合はアダプタが自分で git から取る
  # （直叩き互換）ので、ここを落とすと不整合が黙って戻る。
  if [[ -n "$FIXED_DIFF_FILE" ]]; then
    extra_args+=(--diff-file "$FIXED_DIFF_FILE")
  fi
  if [[ "$INCLUDE_DIFF" == "true" ]]; then
    extra_args+=(--include-diff)
  fi
  if [[ "$TASK_TYPE" == "implement" ]]; then
    local staging_dir
    staging_dir="$(staging_dir_for "$cli_name" "$perspective")"
    # エージェント側で mkdir させない。staging が CWD の外に出る構成（--output-dir で
    # 別の場所を指した場合など）ではサンドボックス下の親ディレクトリ作成が拒まれ、
    # そこで詰まったエージェントは書ける場所を探し始める。既定の staging は CWD 配下
    # なので拒まれないが、その 1 ケースのために毎回エージェント任せにはしない。
    if ! mkdir -p "$staging_dir"; then
      echo "  ❌ Cannot create staging dir: ${staging_dir}" >&2
      echo "     Check the permissions of --output-dir; re-running as-is will fail again." >&2
      return 1
    fi
    # mkdir -p は**既存ディレクトリなら権限に関係なく rc=0** を返す。この検査が
    # 無いと、書き込めない staging に対してプロンプトが "It already exists and is
    # writable" と断言することになる。書けると保証されたエージェントが書き込みを
    # 拒まれると、拒否を報告するより「自分の理解が違う」と解釈して別の場所を
    # 探す方向へ倒れる — プロンプトに書く断定は、コードが検証した分だけにする。
    #
    # -w だけでは足りない。ディレクトリにエントリを作るには write と search(x) の
    # 両方が要るので、mode 0222 は -w を通っても書けない。
    # なお -w -x は必要条件であって十分条件ではない（ACL・read-only マウント・
    # 容量不足はここでは分からない）。build_prompt 側でも同じ検査をしている。
    if [[ ! -w "$staging_dir" || ! -x "$staging_dir" ]]; then
      echo "  ❌ Staging dir is not writable: ${staging_dir}" >&2
      echo "     Check the permissions of --output-dir; re-running as-is will fail again." >&2
      return 1
    fi
    extra_args+=(--staging-dir "$staging_dir")
  fi

  # 全 adapter を対象リポジトリの物理 root から起動する。サブディレクトリから
  # orchestrator を呼んでも CLI の CWD（sandbox root）を狭めないためで、diff の
  # repository-relative path 解決も同じ基準へ固定される。
  ( cd "$REPO_ROOT" && \
    if [[ "$STAGED_DIFF" == "true" ]]; then
      bash "$adapter" "$perspective_file" "$output_file" \
        --staged --timeout "$TIMEOUT" "${extra_args[@]}"
    else
      bash "$adapter" "$perspective_file" "$output_file" \
        --base "$BASE_BRANCH" --timeout "$TIMEOUT" "${extra_args[@]}"
    fi )
}

# ── Path-Segment Safety ──
# A CLI / perspective name is used as a single path segment under OUTPUT_DIR.
# Reject anything that is not a plain identifier so a crafted --cli/--perspective
# value (e.g. "../../secret") cannot escape OUTPUT_DIR when we build result paths.
is_safe_token() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] && [[ "$1" != "." && "$1" != ".." ]]
}

# ── Validate Execution Plan ──
# Fail loud (never a silent skip) if any plan entry carries a cli/perspective
# token that is not a safe single path segment. Called once at each consumption
# entry point (execute_tasks, generate_report) BEFORE the plan is used, so a
# crafted --cli/--perspective value cannot reach the execute (write), cleanup, or
# report (read) paths and escape OUTPUT_DIR — and a malformed plan surfaces as an
# error instead of silently collapsing to "(No results found.)".
validate_execution_plan() {
  local entry cli_name persp_name bad=0
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    # Require the exact "cli:perspective" shape. Without a ':', ${entry%%:*} and
    # ${entry#*:} both collapse to the whole string, so a malformed entry would
    # otherwise pass and drive read/delete/write at the wrong path.
    if [[ "$entry" != *:* ]]; then
      echo "ERROR: malformed execution plan entry (expected 'cli:perspective'): '${entry}'" >&2
      bad=1
      continue
    fi
    cli_name="${entry%%:*}"
    persp_name="${entry#*:}"
    if ! is_safe_token "$cli_name" || ! is_safe_token "$persp_name"; then
      echo "ERROR: unsafe token in execution plan entry: '${entry}'" >&2
      bad=1
    fi
  done <<< "$EXECUTION_PLAN"
  [[ "$bad" -eq 0 ]]
}

# ── Clear This Run's Planned Outputs ──
# The report reads ${cli}/${perspective}.md for each plan entry; adapters only
# (over)write that file on success, leaving a prior run's file in place on
# failure/timeout. Deleting exactly this run's own targets up front means a task
# that produces no output leaves NO stale same-name file to be mis-reported as
# current — instead the report surfaces it as "no output". Scoped to
# the plan's own (cli, perspective) targets only; nothing else on disk (other
# CLIs, other perspectives, unrelated user files) is DELETED here. Callers run
# validate_execution_plan first, so every token here is already a safe segment.
# 「消さない」だけでは、観点を絞った実行のあとに前回結果が同じディレクトリへ残って
# 今回の結果と読まれる（Issue #537 / #654）。その分は削除ではなく移動で塞ぐ —
# 直後に走る quarantine_unplanned_outputs が、今回のプラン外の**自筆の**結果を
# <cli>/previous/ へ退避する。利用者のファイルは移動対象にもしない。
#
# implement の staging（Issue #392）も同じ理由で消す。レポートだけ消して生成物を
# 残すと、今回何も書かなかった実行のあとに前回の生成物がそのまま残り、「staging に
# ある = 今回の成果」という読み方が静かに嘘になる — レポートについて上で塞いだ
# 失敗と同型。
#
# 削除の失敗は握り潰さない。rm の rc を捨てると、消せなかった前回の生成物が
# 今回の成果としてレポートに案内されたまま exit 0 で終わる（実測で再現した形）。
# 痕跡は rm 自身の stderr 1 行だけで、並列実行では他タスクの出力に紛れる。
clear_planned_outputs() {
  [[ -n "${OUTPUT_DIR:-}" ]] || return 0
  local entry cli_name persp_name staging_dir
  # 統合レポートも先に消す。generate_report は成功時にしか書かないので、これが無いと
  # 「タスクは走ったがレポート生成まで到達しなかった」実行のあとに前回のレポートが
  # そのまま残る。利用者へ案内している次の一手は `cat integrated-report.md` なので、
  # 中断を告げた直後にその中断とは無関係な前回の結果を読ませることになる — 個別結果に
  # ついて上で塞いだ stale 誤読と同型。
  if ! rm -f "${OUTPUT_DIR}/integrated-report.md"; then
    echo "ERROR: cannot clear the previous integrated report: ${OUTPUT_DIR}/integrated-report.md" >&2
    return 1
  fi
  # .fixed-diff はこの関数より前に capture_baseline_and_fix_diff が現在入力で上書きする。
  # resume identity はその内容 hash を使うため、ここで消してはならない。
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    cli_name="${entry%%:*}"
    persp_name="${entry#*:}"
    if ! rm -f "${OUTPUT_DIR}/${cli_name}/${persp_name}.md"; then
      echo "ERROR: cannot clear previous result: ${OUTPUT_DIR}/${cli_name}/${persp_name}.md" >&2
      return 1
    fi
    if [[ "${TASK_TYPE:-review}" == "implement" ]]; then
      staging_dir="$(staging_dir_for "$cli_name" "$persp_name")"
      clear_staging_dir "$staging_dir" || return 1
    fi
  done <<< "$EXECUTION_PLAN"
}

clear_previous_integrated_report() {
  [[ -n "${OUTPUT_DIR:-}" ]] || return 0
  if ! rm -f "${OUTPUT_DIR}/integrated-report.md"; then
    echo "ERROR: cannot clear the previous integrated report: ${OUTPUT_DIR}/integrated-report.md" >&2
    return 1
  fi
}

# ── Quarantine Previous Runs' Unplanned Results（Issue #537 / #654） ──
#
# clear_planned_outputs が消すのは**今回のプランが書く先**だけなので、観点セットを
# 絞った実行のあとには前回実行で書かれた別観点のファイルが同じディレクトリに残る。
# integrated-report.md はプランを反復するので混ざらないが、`ls .review-results/<cli>/`
# や個別ファイルを直接読む消費者（人間・エージェント）には現行結果と区別がつかない。
# 実運用で 2 度、数日前の別 PR への Critical 指摘を今回の diff への指摘として読み
# 始めるところだった（どちらもファイル先頭の `Generated` 時刻に気付いて回避した =
# 能動的に確認しない限り気付けない状態だった）。
#
# 削除ではなく `<cli>/previous/` への**退避**にするのは、clear_planned_outputs が
# 宣言している「プランの対象以外はディスク上の何にも触れない」を壊さないため
# （`rm -rf <cli>/` は利用者がそこへ置いた無関係なファイルまで消す）。
#
# 動かすのは **orchestrator 自身が書いた結果ファイルだけ**（write_output の固定
# 1 行目マーカーで判定する）。利用者が同じディレクトリへ置いた `.md` は退避しない
# — 退避物は次の実行で捨てられるので、他人のファイルを退避すると「削除ではない」
# という上の根拠が 1 実行遅れで嘘になる。マーカーの無い `.md` は動かさずに名指しする。
#
# 対象は今回のプランに載っている CLI のディレクトリ**だけ**、その直下の `*.md`
# **だけ**。プラン外の CLI のディレクトリ、`files/`（implement の staging）、
# `.md` 以外のファイルには触れない（触れない代わりに、結果ファイルを持つプラン外
# ディレクトリは report_unplanned_result_dirs が名指しする）。
#
# `previous/` は毎回作り直す（追記しない）。世代を溜めると previous/ 自体が
# 「いつの実行のものか分からない」第二の stale になり、本 Issue と同じ誤読を
# 一段深いところで再現する。previous/ はアーカイブではなく「直前の実行が
# 押し出した結果」の置き場で、次にその CLI を含む実行が走った時点で捨てる。

# write_output（adapters/adapter-common.sh）が全結果ファイルの 1 行目へ必ず書く
# マーカーの形。ここを変えるなら write_output と同時に変えること（退避対象の判定が
# 静かに全外れして、前回結果が今回の結果として残る形の退行になる）。
# ワイルドカードが受け持つのは task_label（Review / Explore / Implement）1 語ぶんだけ
# — その語に ` Result -->` は現れないので、3 タスクすべてを取りこぼさず、
# かつ本文の任意行を誤って 1 行目扱いすることもない。
is_orchestrator_result() { # <file>
  local path="$1" first=""
  # `read` の rc は捨てる — 改行で終わらない 1 行ファイルは EOF で 1 を返すが、
  # 読めた内容は正しい。読めなければ first は空のままで下の照合が偽になる。
  IFS= read -r first < "$path" 2>/dev/null || true
  [[ "$first" == '<!-- Multi-CLI '*' Result -->' ]]
}

# 解決後の物理パスが**渡されたパスそのもの**であることを確認して、その物理パスを返す。
# 呼び出し側は OUTPUT_DIR（既に pwd -P 済み）から組み立てたパスを渡すので、実体の
# ディレクトリなら解決結果は必ず一致する。一致しない = 途中に symlink があるという
# ことで、そのときは触らない。
#
# 「OUTPUT_DIR 配下か」だけを見ないのは、配下判定が 2 つの穴を通すため:
#   - <cli> が出力先の**内側**を指す symlink（例 codex-cli -> ./claude-code）だと配下
#     判定を通るが、2 つの CLI 名が同じ実ディレクトリを共有し、同じ場所から退避しつつ
#     「今回のプラン外」と名指しする矛盾した実行になる
#   - 文字列 prefix 判定は途中の symlink を見抜けない（clear_staging_dir と同じ理由）
# 検査したものと操作するものを一致させるため、呼び出し側は返り値の物理パスを使う。
#
# 前提（呼び出し側の責務）: 渡すパスの**接頭部は既に物理**であること。現在の呼び出しは
# すべて OUTPUT_DIR（execute_tasks が pwd -P 済み）から組み立てている。論理パスを
# 渡すと、symlink でないディレクトリでも不一致になり「symlink だ」と誤って中断する。
resolve_expected_dir() { # <path> <label>
  local path="$1" label="$2" resolved
  if ! resolved="$(cd "$path" && pwd -P)"; then
    echo "ERROR: cannot resolve ${label}: ${path}" >&2
    return 1
  fi
  if [[ "$resolved" != "$path" ]]; then
    echo "ERROR: ${label} is a symlink to another location — refusing to touch it." >&2
    echo "       path:     ${path}" >&2
    echo "       resolves: ${resolved}" >&2
    case "$resolved" in
      "$OUTPUT_DIR"/*)
        echo "       Results are keyed by CLI name; two names sharing one directory would" >&2
        echo "       quarantine from a directory this run also reports as not its own." >&2
        ;;
      *)
        echo "       output:   ${OUTPUT_DIR}" >&2
        echo "       Moving or deleting through it would reach outside the output dir." >&2
        ;;
    esac
    return 1
  fi
  printf '%s\n' "$resolved"
}

# ── Phase 1: 検査（最初の破壊操作より前に一括で） ──
# resume の書き戻し（restore_cached_result の mkdir -p + cp）も clear_planned_outputs
# の rm -f も `${OUTPUT_DIR}/<cli>/` を素通りするので、<cli> が外向き symlink だと
# **退避処理へ到達する前に**外部へ書き、外部を消してしまう。したがって解決検査は
# 退避の中ではなく、プラン上の全 CLI について execute_tasks の破壊操作より前で行う。
# 一括にするもう 1 つの理由: CLI ごとに検査していると「A は退避済み・B で検査落ち」
# の中断が起こり、退避済みの A が次回実行の previous/ 作り直しで失われる。
validate_planned_result_dirs() {
  [[ -n "${OUTPUT_DIR:-}" ]] || return 0
  local entry cli seen_clis=""
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    cli="${entry%%:*}"
    case " ${seen_clis} " in
      *" ${cli} "*) continue ;;
    esac
    seen_clis="${seen_clis} ${cli}"
    validate_result_dir_paths "$cli" || return 1
  done <<< "$EXECUTION_PLAN"
}

validate_result_dir_paths() { # <cli>
  local cli="$1" cli_dir="${OUTPUT_DIR}/${cli}" prev_dir
  if [[ -d "$cli_dir" ]]; then
    resolve_expected_dir "$cli_dir" "the result dir for ${cli}" >/dev/null || return 1
  elif [[ -e "$cli_dir" || -L "$cli_dir" ]]; then
    echo "ERROR: the result path for ${cli} exists but is not a directory: ${cli_dir}" >&2
    echo "       Results are written under it, so this run cannot proceed." >&2
    return 1
  else
    return 0
  fi
  prev_dir="${cli_dir}/previous"
  # symlink は追わずリンク自体を消す（clear_quarantine_dir）ので、解決検査が要るのは
  # 実体のディレクトリだけ。
  if [[ -d "$prev_dir" && ! -L "$prev_dir" ]]; then
    resolve_expected_dir "$prev_dir" "the quarantine dir" >/dev/null || return 1
  fi
  return 0
}

# ── Phase 2: 退避（clear_planned_outputs の後） ──
quarantine_unplanned_outputs() {
  [[ -n "${OUTPUT_DIR:-}" ]] || return 0
  UNPLANNED_RESULT_NOTES=""
  local entry cli seen_clis=""
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    cli="${entry%%:*}"
    case " ${seen_clis} " in
      *" ${cli} "*) continue ;;
    esac
    seen_clis="${seen_clis} ${cli}"
    quarantine_cli_results "$cli" || return 1
  done <<< "$FULL_EXECUTION_PLAN"
  # 報告専用の関数を最終式にしない。呼び出し側は rc=2（準備段階の失敗 = レポートを
  # 出さずに中断）へ倒すので、名指しの走査が何かの拍子に非 0 を返すと、退避は成功して
  # いるのに実行ごと落ちる。退避の成否は上のループが既に返している。
  report_unplanned_result_dirs
  return 0
}

# 前回退避分を消す。素の `rm -rf` を撃たないのは clear_staging_dir と同じ理由
# （途中の symlink で再帰削除が OUTPUT_DIR の外へ抜ける）。
clear_quarantine_dir() { # <dir>
  local dir="$1" resolved discarded=0 f
  # symlink は**追わない**。`[[ -d ]]` は symlink→dir でも真になるため -L を先に見る。
  # 追うと指し先を丸ごと消す — `previous -> ../claude-code` ならプラン外 CLI の結果
  # 一式、`previous -> .` なら自分の CLI ディレクトリ（staging の files/ を含む）。
  # 解決先が OUTPUT_DIR 配下でも消してはいけないので、配下判定ではなくリンク自体の
  # 削除で塞ぐ。同型の追従は clear_staging_dir にも残るが、そちらは Issue #722 の
  # スコープ（本 PR は診断文言を固定している既存 suite を壊さないため触らない）。
  if [[ -L "$dir" ]]; then
    if ! rm -f "$dir"; then
      echo "ERROR: cannot remove the symlink at the quarantine path: ${dir}" >&2
      return 1
    fi
    echo "  ⚠️ Removed a symlink at the quarantine path (its target was left untouched): ${dir}" >&2
    return 0
  fi
  if [[ -d "$dir" ]]; then
    resolved="$(resolve_expected_dir "$dir" "the quarantine dir")" || return 1
    for f in "$resolved"/*.md; do
      if [[ -f "$f" || -L "$f" ]]; then
        discarded=$((discarded + 1))
      fi
    done
    if ! rm -rf "$resolved"; then
      echo "ERROR: cannot clear the previous quarantine dir: ${resolved}" >&2
      return 1
    fi
    # 無言で捨てない。退避物の寿命は「次にこの CLI を含む実行が走るまで」なので、
    # 捨てた事実と件数が出ていないと、利用者は previous/ を残っているものとして探す。
    if [[ "$discarded" -gt 0 ]]; then
      echo "  🗑️  Discarded ${discarded} quarantined result(s) from an earlier run: ${resolved}" >&2
    fi
    return 0
  fi
  # ディレクトリでない残骸（ファイル・壊れた symlink 以外の実体）はそれ自体を消す。
  if [[ -e "$dir" ]]; then
    if ! rm -f "$dir"; then
      echo "ERROR: cannot remove non-directory at quarantine path: ${dir}" >&2
      return 1
    fi
  fi
  return 0
}

plan_has_entry() { # <cli:perspective>
  local target="$1" entry
  while IFS= read -r entry; do
    [[ "$entry" == "$target" ]] && return 0
  done <<< "$FULL_EXECUTION_PLAN"
  return 1
}

plan_has_cli() { # <cli>
  local target="$1" entry
  while IFS= read -r entry; do
    [[ "${entry%%:*}" == "$target" ]] && return 0
  done <<< "$FULL_EXECUTION_PLAN"
  return 1
}

# 動かさないが名指しはする残骸を記録する。stderr へ 1 行出し、統合レポートにも
# 同じ内容を載せる（レポートだけを読む消費者にも届かせるため）。
note_unplanned_results() { # <text>
  UNPLANNED_RESULT_NOTES="${UNPLANNED_RESULT_NOTES:+${UNPLANNED_RESULT_NOTES}
}$1"
  echo "  ⚠️ Not part of this run: $1" >&2
}

quarantine_cli_results() { # <cli>
  local cli="$1"
  local cli_dir="${OUTPUT_DIR}/${cli}"
  [[ -d "$cli_dir" ]] || return 0

  local resolved_cli
  resolved_cli="$(resolve_expected_dir "$cli_dir" "the result dir for ${cli}")" || return 1

  local prev_dir="${resolved_cli}/previous"
  clear_quarantine_dir "$prev_dir" || return 1

  local moved=0 foreign=0 moved_names="" file base resolved_prev=""
  for file in "$resolved_cli"/*.md; do
    # nullglob は使わない（グローバルに効かせると他の展開の意味まで変わる）。
    # 一致 0 件のとき glob はパターンそのものへ展開されるので、実体検査で弾く。
    # ディレクトリ（`foo.md/`）は結果ファイルではないので触らない。
    [[ -f "$file" || -L "$file" ]] || continue
    base="${file##*/}"
    plan_has_entry "${cli}:${base%.md}" && continue
    if ! is_orchestrator_result "$file"; then
      foreign=$((foreign + 1))
      continue
    fi
    if [[ -z "$resolved_prev" ]]; then
      if ! mkdir -p "$prev_dir"; then
        echo "ERROR: cannot create quarantine dir: ${prev_dir}" >&2
        return 1
      fi
      resolved_prev="$(resolve_expected_dir "$prev_dir" "the quarantine dir")" || return 1
    fi
    if ! mv "$file" "${resolved_prev}/${base}"; then
      echo "ERROR: cannot quarantine a previous run's result: ${file}" >&2
      echo "       A previous run's result would be read as this run's output." >&2
      return 1
    fi
    moved=$((moved + 1))
    moved_names="${moved_names:+${moved_names}, }${base%.md}"
  done

  if [[ "$moved" -gt 0 ]]; then
    echo "  🧹 Moved ${moved} result(s) from a previous run into ${resolved_prev}: ${moved_names}" >&2
  fi
  if [[ "$foreign" -gt 0 ]]; then
    note_unplanned_results "${cli}/ (${foreign} .md file(s) this orchestrator did not write — left in place, not this run's output)"
  fi
  return 0
}

# プラン外の CLI ディレクトリは 1 バイトも動かさない。ただし黙っていると
# `ls .review-results/` が前回実行の結果一式を今回の結果のように見せるので、
# 結果ファイルを持つものを名指しする（本 Issue が塞いだ誤読の、ディレクトリ単位版）。
report_unplanned_result_dirs() {
  local dir cli count file
  for dir in "$OUTPUT_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    cli="${dir%/}"
    cli="${cli##*/}"
    plan_has_cli "$cli" && continue
    count=0
    for file in "${dir}"*.md; do
      if [[ -f "$file" || -L "$file" ]]; then
        count=$((count + 1))
      fi
    done
    if [[ "$count" -gt 0 ]]; then
      note_unplanned_results "${cli}/ (${count} result file(s) from an earlier run — left untouched, not this run's output)"
    fi
  done
}

# ── Resume Identity And Cache（Issue #586） ──
#
# Cache only complete task results, keyed by the whole run input. A task-level key
# would wrongly reuse seven perspectives after the caller changed the requested
# perspective set, which is explicitly part of the review contract. timeout is
# intentionally absent: extending a deadline is the main recovery path resume is
# meant to support and does not change what the CLI is asked to review.
hash_file_or_missing() { # <label> <path>
  local label="$1" path="$2" digest
  if [[ -f "$path" ]]; then
    digest="$(git hash-object "$path" 2>/dev/null)" || return 1
    printf '%s=%s\n' "$label" "$digest"
  else
    printf '%s=(missing)\n' "$label"
  fi
}

hash_text_value() { # <label> <value>
  local label="$1" value="$2" digest
  digest="$(printf '%s' "$value" | git hash-object --stdin 2>/dev/null)" || return 1
  printf '%s=%s\n' "$label" "$digest"
}

compute_resume_identity() {
  local plan_sorted entry cli persp env_name env_value head_oid="" base_oid=""
  plan_sorted="$(printf '%s\n' "$EXECUTION_PLAN" | LC_ALL=C sort -u)"
  if [[ "$IN_GIT_REPO" == "true" ]]; then
    head_oid="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null)" || return 1
    if [[ "$STAGED_DIFF" == "true" ]]; then
      base_oid="(staged)"
    else
      base_oid="$(git -C "$REPO_ROOT" rev-parse "${BASE_BRANCH}^{commit}" 2>/dev/null)" || return 1
    fi
  fi

  {
    printf 'identity-version=%s\n' "$RESUME_IDENTITY_VERSION"
    printf 'task=%s\nmode=%s\nstrategy=%s\n' "$TASK_TYPE" "$MODE" "$STRATEGY"
    printf 'base-ref=%s\nbase-oid=%s\nhead=%s\n' "$BASE_BRANCH" "$base_oid" "$head_oid"
    printf 'staged=%s\ninclude-diff=%s\n' "$STAGED_DIFF" "$INCLUDE_DIFF"
    hash_text_value description "$DESCRIPTION"
    printf '%s\n' "$plan_sorted" | sed 's/^/plan=/'
    hash_file_or_missing config "$CONFIG_FILE"
    hash_file_or_missing orchestrator "${SCRIPT_DIR}/multi-agent.sh"
    hash_file_or_missing adapter-common "$ADAPTER_COMMON"
    if [[ -n "$FIXED_DIFF_FILE" ]]; then
      hash_file_or_missing fixed-diff "$FIXED_DIFF_FILE"
    else
      printf '%s\n' 'fixed-diff=(none)'
    fi
    while IFS= read -r entry; do
      [[ -n "$entry" ]] || continue
      cli="${entry%%:*}"
      persp="${entry#*:}"
      hash_file_or_missing "adapter:${cli}" "$(get_cli_adapter "$cli")"
      hash_file_or_missing "perspective:${TASK_TYPE}:${persp}" "$(resolve_perspective_file "$persp")"
      for env_name in $(get_cli_model_env_vars "$cli"); do
        eval "env_value=\${${env_name}-}"
        hash_text_value "env:${env_name}" "$env_value"
      done
    done <<EOF
$plan_sorted
EOF
  } | git hash-object --stdin 2>/dev/null
}

cache_task_result() { # <cli> <perspective>
  local cli="$1" persp="$2" source_file cache_dir cache_file digest
  source_file="${OUTPUT_DIR}/${cli}/${persp}.md"
  [[ -f "$source_file" ]] || return 1
  cache_dir="${RESUME_CACHE_DIR}/${cli}"
  cache_file="${cache_dir}/${persp}.md"
  mkdir -p "$cache_dir" || return 1
  digest="$(git hash-object "$source_file" 2>/dev/null)" || return 1
  cp "$source_file" "${cache_file}.tmp.$$" || return 1
  printf '%s\n' "$digest" >"${cache_file}.hash.tmp.$$" || return 1
  mv "${cache_file}.tmp.$$" "$cache_file" || return 1
  mv "${cache_file}.hash.tmp.$$" "${cache_file}.hash" || return 1
}

restore_cached_result() { # <cli> <perspective>
  local cli="$1" persp="$2" cache_file expected actual target
  cache_file="${RESUME_CACHE_DIR}/${cli}/${persp}.md"
  [[ -f "$cache_file" && -f "${cache_file}.hash" ]] || return 1
  expected="$(cat "${cache_file}.hash" 2>/dev/null)" || return 1
  [[ "$expected" =~ ^[0-9a-f]+$ ]] || return 1
  actual="$(git hash-object "$cache_file" 2>/dev/null)" || return 1
  [[ "$actual" == "$expected" ]] || return 1
  target="${OUTPUT_DIR}/${cli}/${persp}.md"
  mkdir -p "$(dirname "$target")" || return 1
  cp "$cache_file" "$target" || return 1
}

prepare_resume_execution_plan() {
  local entry cli persp active_plan=""
  FULL_EXECUTION_PLAN="$EXECUTION_PLAN"
  REUSED_TASKS=""
  EXECUTED_TASKS=""
  RESUME_IDENTITY="$(compute_resume_identity)" || {
    echo "ERROR: cannot compute the resume input identity." >&2
    return 1
  }
  [[ -n "$RESUME_IDENTITY" ]] || {
    echo "ERROR: computed an empty resume input identity." >&2
    return 1
  }
  RESUME_CACHE_DIR="${OUTPUT_DIR}/.resume-cache/${RESUME_IDENTITY}"
  mkdir -p "$RESUME_CACHE_DIR" || {
    echo "ERROR: cannot create resume cache: ${RESUME_CACHE_DIR}" >&2
    return 1
  }

  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    cli="${entry%%:*}"
    persp="${entry#*:}"
    if [[ "$RESUME" == "true" ]] && restore_cached_result "$cli" "$persp"; then
      REUSED_TASKS="${REUSED_TASKS:+$REUSED_TASKS }${cli}/${persp}"
      echo "  ♻️  Reused: ${cli}/${persp}" >&2
    else
      if [[ "$RESUME" == "true" ]]; then
        echo "  ▶ Resume executes: ${cli}/${persp} (no valid completed cache)" >&2
      fi
      active_plan="${active_plan:+$active_plan
}${entry}"
      EXECUTED_TASKS="${EXECUTED_TASKS:+$EXECUTED_TASKS }${cli}/${persp}"
    fi
  done <<< "$FULL_EXECUTION_PLAN"
  EXECUTION_PLAN="$active_plan"
}

# ── Output Directory Lock（Issue #402） ──
# レポート・staging は固定パスなので、同じ output-dir の 2 run を許すと後発 run の
# clear_planned_outputs が先行 run の生成物を削除する。mkdir の原子性を lock として使い、
# 同時実行はタスク起動前に fail-loud で止める。PID の生存確認による自動 stale 回収は
# PID 再利用と確認→削除の race があるため行わない。異常終了後の lock は利用者が実行中
# process が無いことを確認してから明示的に削除する。
release_output_lock() {
  [[ "$OUTPUT_LOCK_HELD" == "true" ]] || return 0
  local owner_file="${OUTPUT_LOCK_DIR}/owner"
  rm -f "$owner_file" 2>/dev/null || true
  if ! rmdir "$OUTPUT_LOCK_DIR" 2>/dev/null; then
    echo "WARNING: could not release output-dir lock: ${OUTPUT_LOCK_DIR}" >&2
    echo "         Refusing recursive cleanup because unexpected files may be present." >&2
    return 1
  fi
  OUTPUT_LOCK_HELD=false
  return 0
}

output_lock_exit() {
  local rc=$?
  release_output_lock || {
    [[ "$rc" -ne 0 ]] || rc=1
  }
  exit "$rc"
}

acquire_output_lock() {
  OUTPUT_LOCK_DIR="${OUTPUT_DIR}/.multi-agent-run.lock"
  if ! mkdir "$OUTPUT_LOCK_DIR" 2>/dev/null; then
    echo "ERROR: output dir is already in use by another orchestrator (or a stale lock remains)." >&2
    echo "       output: ${OUTPUT_DIR}" >&2
    echo "       lock:   ${OUTPUT_LOCK_DIR}" >&2
    echo "       Use a different --output-dir, or after confirming no run is active remove the stale lock." >&2
    return 1
  fi
  OUTPUT_LOCK_HELD=true
  if ! printf 'pid=%s\ntask=%s\ncwd=%s\n' "$$" "$TASK_TYPE" "$(pwd -P)" >"${OUTPUT_LOCK_DIR}/owner"; then
    release_output_lock || true
    echo "ERROR: cannot write output-dir lock metadata: ${OUTPUT_LOCK_DIR}/owner" >&2
    return 1
  fi
  # Hold the lock through report generation. Releasing after execute_tasks but before generate_report
  # would let another run clear the files while this run is reading them.
  trap output_lock_exit EXIT
  trap 'exit 130' HUP INT TERM
  return 0
}

# ── タスク実行 + rc 記録（Issue #251） ──
# タスクの rc は 1 ファイルずつ status dir へ記録し、親が wait 後に回収する
# （background プロセスの exit code だけでは、逐次ワーカーが抱える複数タスクの
# 内訳が失われるため、並列タスク側も同じ記録方式に揃える）。
# 記録は tmp へ書いてから mv する原子的保存 — 書き込み途中の死（ENOSPC 等）で
# **空の rc ファイル**が残ると、bash 3.2 では [[ "" -eq 0 ]] が真になり、失敗した
# タスクが INCOMPLETE 成果物の存在だけで「✅ Done」へ化ける（アダプタは失敗時も
# サルベージ成果物を書く仕様のため、-f 検査はバックストップにならない）。
# rc ファイルは ${cli}/${persp}.rc のサブディレクトリ構成 — 平坦な連結名だと
# 区切り文字を含む CLI 名が将来入ったときに衝突が静かに開く。
run_task_recorded() { # $1: cli / $2: perspective / $3: status dir
  local rc=0
  run_single_task "$1" "$2" || rc=$?
  mkdir -p "${3}/${1}"
  if ! { printf '%s\n' "$rc" > "${3}/${1}/${2}.rc.tmp" \
         && mv "${3}/${1}/${2}.rc.tmp" "${3}/${1}/${2}.rc"; }; then
    # 記録に失敗してもワーカーは死んでよいが、死ぬ前に名乗る — 回収側は
    # 「ファイルなし = 失敗」で安全側に拾うが、原因（どのタスクの記録が
    # 書けなかったか）はこの行にしか残らない。
    echo "  ⚠️ Failed to record status for ${1}/${2} (task rc=${rc}): ${3} is not writable" >&2
    return 1
  fi
}

# ── Per-CLI Worker（Issue #251） ──
# EXECUTION_PLAN から自分の CLI の観点だけを計画順に**逐次**実行する。free-tier
# CLI 専用 — レート制限は実行時失敗であり、本ツールは実行時 fallback を持たない
# ため、throttle された観点はカバレッジゼロになる。同時 burst を作らないことが
# 防御になる。premium / standard tier は従来どおりタスク単位で並列（一律逐次化は
# pair モード既定の premium 7 観点で実行時間を観点数倍にする退行になる）。
run_cli_group() { # $1: cli / $2: status dir
  local cli="$1" sdir="$2" entry gseen=""
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    [[ "${entry%%:*}" == "$cli" ]] || continue
    if [[ " $gseen " == *" $entry "* ]]; then continue; fi
    gseen="$gseen $entry"
    # 進捗を名乗ってから実行する — ワーカーが途中で死んだとき、どのタスクの
    # 処理中だったかはこの行でしか相関できない（逐次ブランチの ▶ 表示と対）。
    echo "▶ ${cli} → ${entry#*:} (serialized)" >&2
    run_task_recorded "$cli" "${entry#*:}" "$sdir" || return 1
  done <<< "$EXECUTION_PLAN"
}

# ── Execute All Tasks ──
execute_tasks() {
  if [[ -z "$EXECUTION_PLAN" ]]; then
    echo "Nothing to execute." >&2
    return 0
  fi

  # Reject a plan with unsafe path segments before writing/deleting anything.
  # ここから下の準備段階の失敗は rc=2 で返す（main がレポート生成を止める根拠）。
  validate_execution_plan || return 2

  mkdir -p "$OUTPUT_DIR"
  # 実在させた直後に**絶対かつ物理**のパスへ解決する。ここが staging パスの
  # 正規化の単一地点で、2 つの嘘を同時に潰している:
  #   1) --output-dir / 設定ファイルは値を無加工で受けるので相対値が入りうる。
  #      相対のまま implement へ流すと、プロンプトが "(absolute path)" と断言
  #      しながら相対パスを渡し、受け取ったエージェントは自分の CWD = 作業ツリー
  #      基準で解決してそこへ書く（本 Issue が塞ごうとした汚染そのもの）。
  #   2) 既定の OUTPUT_DIR は git rev-parse --show-toplevel（物理）由来、$PWD は
  #      論理なので、symlink 越しのチェックアウトでは同じ場所を違う綴りで指す。
  #      揃えておかないと warn_if_staging_outside_sandbox が毎回誤発火する。
  if ! OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"; then
    echo "ERROR: cannot resolve output dir: ${OUTPUT_DIR}" >&2
    return 2
  fi
  validate_implement_output_boundary || return 2
  validate_output_dir_boundary || return 2
  acquire_output_lock || return 2
  # capture/identity preparation can fail before clear_planned_outputs. Remove the
  # prior report first so that a setup failure can never leave a stale report at
  # the exact path printed by successful runs.
  clear_previous_integrated_report || return 2
  # 結果ディレクトリの解決検査は**<cli>/ 配下へ触る最初の操作より前**に一括で行う
  # （Issue #537 / #654）。この下の resume 書き戻し（cp）・clear_planned_outputs
  # （rm -f）・退避（mv）はどれも `${OUTPUT_DIR}/<cli>/` を素通りするので、検査を
  # 退避の中に置くと <cli> が外向き symlink のときに検査到達前へ書き込み・削除が
  # 済んでしまう。統合レポートの削除より後に置くのは、この検査で落ちた実行が
  # 「前回のレポートを今回の結果として案内する」状態を残さないため（上の理由と対）。
  validate_planned_result_dirs || return 2
  # A task without prompt diff must not inherit the previous review's fixed diff.
  # Diff-bearing tasks overwrite the file in create_fixed_diff below; removing it
  # here for all tasks would erase the bytes before resume identity can hash them.
  if [[ "$TASK_TYPE" != "review" && "$INCLUDE_DIFF" != "true" ]]; then
    if ! rm -f "${OUTPUT_DIR}/.fixed-diff"; then
      echo "ERROR: cannot clear the previous fixed diff: ${OUTPUT_DIR}/.fixed-diff" >&2
      return 2
    fi
  fi
  capture_baseline_and_fix_diff || return 2
  prepare_resume_execution_plan || return 2
  clear_planned_outputs || return 2
  # 今回のプランに載っていない前回結果を退避する。プラン**全体**（resume で再利用へ
  # 倒れた観点を含む FULL_EXECUTION_PLAN）を基準にする — 実行分だけの
  # EXECUTION_PLAN で判定すると、resume が直前にキャッシュから書き戻した結果を
  # 自分で退避してしまう。レポートも main で FULL_EXECUTION_PLAN へ戻してから
  # 反復するので、「今回のもの」の定義が両者で一致する。
  quarantine_unplanned_outputs || return 2

  if [[ -z "$EXECUTION_PLAN" ]]; then
    echo "♻️  All ${TASK_TYPE} tasks were restored from the validated resume cache." >&2
    return 0
  fi

  local pids=""
  local failed=0
  local count=0
  local seen=""
  FAILED_TASKS=""

  if [[ "$PARALLEL" == "true" ]]; then
    # ── 並列実行: CLI 間は並列、同一 CLI 内は逐次（Issue #251） ──
    # minimize_cost が premium の観点を最安 tier へ振り替えると、同一 CLI
    # （現行の振替先はレート制限のある free-tier）へ複数観点が集中する。本ツールは
    # 実行時 fallback を意図的に持たないため、throttle されたタスクは別 CLI で
    # 再実行されず**その観点のカバレッジがゼロ**になる — 同一 CLI への同時 burst を
    # 作らないことが防御になる。CLI が違えばレート制限は独立なので並列のまま。
    # status dir は実行ごとに一意にする — 固定パスだと同じ OUTPUT_DIR を使う
    # 並行実行が互いの rc を削除・混同する。一意化は mktemp ではなく自 PID で行う
    # — orchestrator は mktemp を呼ばない、がこのスクリプトの検査済み契約で
    # （multi-agent-timeout suite の tmpdir ケースは「mktemp が壊れても落ちるのは
    # アダプタ側だけ」を固定している）、並行実行は別プロセス = 別 PID なので
    # 一意性はこれで足りる。同一 PID の残骸（過去のクラッシュ）は先に消す。
    local status_dir="${OUTPUT_DIR}/.task-rc.$$"
    rm -rf "$status_dir"
    if ! mkdir -p "$status_dir"; then
      echo "ERROR: cannot create task-status directory: ${status_dir}" >&2
      return 1
    fi

    local group_clis=""
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      # Skip a duplicate plan entry so the same cli:perspective is not executed
      # twice (a plan fallback can list it more than once).
      if [[ " $seen " == *" $entry "* ]]; then continue; fi
      seen="$seen $entry"
      count=$((count + 1))
      local cli="${entry%%:*}"
      if ! list_contains "$group_clis" "$cli"; then
        group_clis="${group_clis:+$group_clis }$cli"
      fi
    done <<< "$EXECUTION_PLAN"

    # free-tier CLI は 1 本の逐次ワーカーへ、それ以外は従来どおりタスク単位で並列。
    # pid と並行してラベル（worker:<cli> / task:<cli>/<persp>。空白を含まない）を
    # 記録する — rc ファイル不在の失敗で「どのプロセスが・どの rc で死んだか」を
    # 相関できるのはこの対応表だけ（wait の rc は下で回収して報告する）。
    local serialized_clis="" pid_labels=""
    local group_cli
    for group_cli in $group_clis; do
      if [[ "$(get_cli_cost_tier "$group_cli")" == "free-tier" ]]; then
        serialized_clis="${serialized_clis:+$serialized_clis }$group_cli"
        run_cli_group "$group_cli" "$status_dir" &
        pids="${pids:+$pids }$!"
        pid_labels="${pid_labels:+$pid_labels }worker:${group_cli}"
      fi
    done
    local spawn_seen=""
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      if [[ " $spawn_seen " == *" $entry "* ]]; then continue; fi
      spawn_seen="$spawn_seen $entry"
      local spawn_cli="${entry%%:*}"
      if list_contains "$serialized_clis" "$spawn_cli"; then continue; fi
      run_task_recorded "$spawn_cli" "${entry#*:}" "$status_dir" &
      pids="${pids:+$pids }$!"
      pid_labels="${pid_labels:+$pid_labels }task:${spawn_cli}/${entry#*:}"
    done <<< "$EXECUTION_PLAN"

    if [[ -n "$serialized_clis" ]]; then
      # 公開ユーザーの端末へ毎回出る行なので、SSOT 側の Issue 番号は書かない
      # （公開リポジトリでは独立採番のため無関係な Issue を指す）。追跡はコメントで。
      echo "⏳ Waiting for ${count} ${TASK_TYPE} task(s) — free-tier CLI(s) run their tasks sequentially (rate-limit protection):${serialized_clis:+ }${serialized_clis}" >&2
    else
      echo "⏳ Waiting for ${count} parallel ${TASK_TYPE} tasks..." >&2
    fi
    # wait の rc は成否の情報源ではない（rc ファイルが単一情報源）が、外部 kill 等で
    # ワーカーが記録前に死んだときの唯一の死因なので、非 0 は名指しで残す。
    set +e
    local pid wait_idx=0 wrc wlabel
    for pid in $pids; do
      wait_idx=$((wait_idx + 1))
      wait "$pid"
      wrc=$?
      if [[ $wrc -ne 0 ]]; then
        # shellcheck disable=SC2086 # one whitespace-delimited label per worker
        wlabel="$(printf '%s\n' $pid_labels | awk -v n="$wait_idx" 'NR == n')"
        echo "  ⚠️ ${wlabel:-worker} exited with rc=${wrc} — tasks it had not recorded yet will be counted as failed below" >&2
      fi
    done
    set -e

    # 回収は計画順。rc ファイルが無い = ワーカーが記録前に死んだ（kill・クラッシュ）
    # 形で、これも失敗として数える — 沈黙の未実行を「成功」に見せない。
    local collect_seen=""
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      if [[ " $collect_seen " == *" $entry "* ]]; then continue; fi
      collect_seen="$collect_seen $entry"
      local cli="${entry%%:*}"
      local persp="${entry#*:}"
      local task_name="${cli}/${persp}"
      local rc_file="${status_dir}/${cli}/${persp}.rc"
      local exit_code
      if [[ ! -f "$rc_file" ]]; then
        failed=$((failed + 1))
        FAILED_TASKS="${FAILED_TASKS:+$FAILED_TASKS }${task_name}:1"
        echo "  ❌ Worker died before recording a status: ${task_name}" >&2
        continue
      fi
      # 読めない・空・非数値の rc は「判定不能」として失敗へ倒す。bash 3.2 の
      # [[ "" -eq 0 ]] は真、英字は unbound variable で set -e 即死のため、
      # 数値検証を通してからでないと -eq 比較に入れられない。
      exit_code="$(cat "$rc_file" 2>/dev/null)" || exit_code=""
      if ! [[ "$exit_code" =~ ^[0-9]+$ ]]; then
        failed=$((failed + 1))
        FAILED_TASKS="${FAILED_TASKS:+$FAILED_TASKS }${task_name}:1"
        echo "  ❌ Corrupt/empty status file (content='${exit_code}'): ${task_name}" >&2
        continue
      fi
      if [[ "$exit_code" -eq 0 && -f "${OUTPUT_DIR}/${task_name}.md" ]]; then
        echo "  ✅ Done: ${task_name}" >&2
        if ! cache_task_result "$cli" "$persp"; then
          failed=$((failed + 1))
          FAILED_TASKS="${FAILED_TASKS:+$FAILED_TASKS }${task_name}:1"
          echo "  ❌ Cannot persist completed resume cache: ${task_name}" >&2
        fi
      elif [[ "$exit_code" -ne 0 ]]; then
        failed=$((failed + 1))
        FAILED_TASKS="${FAILED_TASKS:+$FAILED_TASKS }${task_name}:${exit_code}"
        report_task_failure "$task_name" "$exit_code"
      else
        # Success exit but no output file — surface as a failure, not silent OK.
        failed=$((failed + 1))
        FAILED_TASKS="${FAILED_TASKS:+$FAILED_TASKS }${task_name}:0"
        echo "  ❌ No output file: ${task_name}" >&2
      fi
    done <<< "$EXECUTION_PLAN"
    rm -rf "$status_dir"
  else
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      # Skip a duplicate plan entry so the same cli:perspective is not executed
      # twice (a plan fallback can list it more than once).
      if [[ " $seen " == *" $entry "* ]]; then continue; fi
      seen="$seen $entry"
      local cli="${entry%%:*}"
      local persp="${entry#*:}"

      echo "▶ ${cli} → ${persp}" >&2
      # Capture the status rather than testing it inline: the parallel branch
      # distinguishes a fired deadline from a crash, and this path has to give the
      # same diagnosis or the reason depends on which mode you happened to run.
      local task_rc=0
      run_single_task "$cli" "$persp" || task_rc=$?
      if [[ $task_rc -ne 0 ]]; then
        failed=$((failed + 1))
        FAILED_TASKS="${FAILED_TASKS:+$FAILED_TASKS }${cli}/${persp}:${task_rc}"
        report_task_failure "${cli}/${persp}" "$task_rc"
      elif [[ ! -f "${OUTPUT_DIR}/${cli}/${persp}.md" ]]; then
        # Adapter reported success but wrote no output — count it as a failure so
        # a silently-empty run shows up in the exit code, not only the report.
        failed=$((failed + 1))
        FAILED_TASKS="${FAILED_TASKS:+$FAILED_TASKS }${cli}/${persp}:0"
        echo "  ❌ No output file: ${cli}/${persp}" >&2
      elif ! cache_task_result "$cli" "$persp"; then
        failed=$((failed + 1))
        FAILED_TASKS="${FAILED_TASKS:+$FAILED_TASKS }${cli}/${persp}:1"
        echo "  ❌ Cannot persist completed resume cache: ${cli}/${persp}" >&2
      fi
    done <<< "$EXECUTION_PLAN"
  fi

  echo "" >&2
  if [[ $failed -gt 0 ]]; then
    echo "⚠️  ${failed} ${TASK_TYPE} task(s) failed." >&2
    print_failure_advice
    return 1
  else
    echo "✅ All ${TASK_TYPE} tasks completed successfully." >&2
  fi
}

# ── 実行中にレビュー対象が動いていないことの検証 ──
#
# 実行開始時に取ったスナップショットと突き合わせ、一致しなければ結果を破棄する。
# 警告に留めない理由: この機構が守っているのは「レポートの内容」ではなく「レポートを
# 信じてよいかどうか」で、信じてよいか分からない結果を exit 0 で返すのは、この Issue が
# 塞ごうとしている silent failure そのもの。
#
# 検出できない形は 1 つではない。既知のものを明示しておく:
#   - 実行中に動いて**元へ戻された**変化（前後比較の原理的な限界）
#   - gitignore 済みパスへの書き込み、除外パス配下の変化、内容を読めない untracked
#     エントリの中身（capture_repo_snapshot の「見えないものを明示しておく」の項）
#
# 往復のケースで固定 diff が守るのは**プロンプトへ載る diff のバイト列**までで、
# 「往復を受け持つ」わけではない。その区間にエージェントが直接読んだ作業ツリーの
# ファイル実体は、固定 diff でも前後比較でも守れず、既知の穴として残る。
# それでも 2 つで 1 組にする意味はある — 固定 diff は往復中も diff を動かさず、
# 前後比較は往復しない変化（大多数）を捕らえるので、片方だけより穴が小さい。
# 破棄した実行の成果物を「完成した結果」に見せない。
#
# レポートを書かないだけでは足りない。個別結果 ${cli}/${persp}.md はタスクが書いた
# 時点でディスクに残り、ヘッダーは `Status: complete` のままになる。しかもそのパスは
# skills/multi-review/SKILL.md が「結果は後から参照できる」と案内している場所そのもの
# で、破棄を宣言した直後に完成扱いの結果が同じ場所に並ぶ。消さずに印を付けるのは、
# CLI に払ったぶんの出力を証跡として残すため。
mark_outputs_discarded() {
  local entry cli persp f tmp
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    cli="${entry%%:*}"
    persp="${entry#*:}"
    f="${OUTPUT_DIR}/${cli}/${persp}.md"
    [[ -f "$f" ]] || continue
    tmp="${f}.discarding.$$"
    # 差し替えは ASCII のみのパターンで行う（ロケール依存の text 処理を持ち込まない）。
    if { printf '%s\n\n' "> DISCARDED — the repository changed while this run was in flight. Nothing below was verified against a stable revision; do not read it as a finished ${TASK_TYPE}." \
         && sed 's/^<!-- Status: complete -->$/<!-- Status: discarded -->/' "$f"; } > "$tmp" 2>/dev/null \
       && mv "$tmp" "$f"; then
      continue
    fi
    rm -f "$tmp" 2>/dev/null || true
    echo "  could not mark as discarded: ${f}" >&2
  done <<< "$EXECUTION_PLAN"
}

verify_repo_unchanged() {
  local after
  if ! after="$(capture_repo_snapshot "$(output_dir_repo_relative)")"; then
    echo "" >&2
    echo "❌ Cannot read the repository state after the run — discarding the result." >&2
    echo "   The baseline was taken, so this is a failure to verify, not a clean run:" >&2
    echo "   nothing here can confirm the reviewed revision stayed put. Reporting an" >&2
    echo "   unverifiable run as valid is the exact failure this guard exists to prevent." >&2
    mark_outputs_discarded
    echo "   No report was generated; this run's per-task results are marked DISCARDED." >&2
    return 1
  fi
  [[ "$after" == "$REPO_SNAPSHOT_BEFORE" ]] && return 0

  # どこが動いたのかを名指しする。3 つのうちどれが変わったかで利用者の次の一手が
  # まったく違う（ブランチを戻す / commit を戻す / 作業ツリーを片付ける）。
  local b_head b_branch b_tree a_head a_branch a_tree
  read -r b_head b_branch b_tree <<< "$REPO_SNAPSHOT_BEFORE"
  read -r a_head a_branch a_tree <<< "$after"

  echo "" >&2
  echo "❌ The repository changed while the ${TASK_TYPE} was running — discarding the result." >&2
  if [[ "$b_branch" != "$a_branch" ]]; then
    echo "   branch:   ${b_branch} → ${a_branch}" >&2
  fi
  if [[ "$b_head" != "$a_head" ]]; then
    echo "   HEAD:     ${b_head} → ${a_head}" >&2
  fi
  if [[ "$b_tree" != "$a_tree" ]]; then
    echo "   worktree: changed (tracked and untracked files, excluding the output dir)" >&2
  fi
  echo "" >&2
  echo "   Tasks read the working tree while they run, so what each one actually looked" >&2
  echo "   at is now unknown — and a report built from that would read as a clean result." >&2
  mark_outputs_discarded
  echo "   No report was generated; this run's per-task results are marked DISCARDED" >&2
  echo "   so they cannot be mistaken for a finished ${TASK_TYPE}." >&2
  echo "   Re-run once the repository is settled." >&2
  return 1
}

# ── One-Line Failure Diagnosis ──
# $TIMEOUT is the limit that actually applied — no CLI is capped below it any
# more (see "Per-CLI Timeout Caps"), so this function does not need to know
# which CLI failed. Re-introducing a cap means taking `cli_name` back as a
# parameter (both call sites have it) and reporting the capped number rather
# than the run-wide one: naming a deadline that never existed sends the user
# after the wrong remedy.
# 124 is run_with_timeout's timeout status (see adapters/adapter-common.sh).
report_task_failure() {
  local task_name="$1" rc="$2"
  if [[ "$rc" -eq 124 ]]; then
    echo "  ❌ Timed out after ${TIMEOUT}s: ${task_name}" >&2
  else
    echo "  ❌ Failed: ${task_name} (exit code: ${rc})" >&2
  fi
}

# ── Retry Advice For Failed Tasks ──
# A failed task is never re-dispatched to another CLI (see "Fallback semantics"
# in the header). That is only a defensible default if the user is handed the
# commands they would otherwise have wanted the tool to run behind their back,
# so print them: same CLI with more time, or the configured substitute — named
# explicitly, with its cost tier, as a choice rather than a surprise.
print_failure_advice() {
  [[ -n "$FAILED_TASKS" ]] || return 0

  # Absolute path, not basename: this script normally lives inside an installed
  # plugin and is invoked from the target project, where no same-named file
  # exists. A bare `bash multi-agent.sh ...` would fail the moment it is pasted.
  # printf %q keeps a path with spaces runnable.
  local self
  self="bash $(printf '%q' "${SCRIPT_DIR}/multi-agent.sh") --task ${TASK_TYPE}"
  # Carry the flags that decide WHAT gets looked at. Dropping --base would retry
  # against a different diff than the run that just failed, which makes the
  # suggested command quietly not-a-retry.
  if [[ "$STAGED_DIFF" == "true" ]]; then
    self="${self} --staged"
  elif [[ "$TASK_TYPE" == "review" || "$INCLUDE_DIFF" == "true" ]]; then
    self="${self} --base $(printf '%q' "$BASE_BRANCH")"
  fi
  if [[ "$INCLUDE_DIFF" == "true" ]]; then
    # Without this the retry builds a prompt with no diff in it — a different task,
    # not a retry of the one that failed.
    self="${self} --include-diff"
  fi
  if [[ "$CONFIG_SOURCE" == "--config flag" || "$CONFIG_SOURCE" == "MULTI_AGENT_CONFIG env" ]]; then
    self="${self} --config $(printf '%q' "$CONFIG_FILE")"
  fi
  if [[ "$OUTPUT_DIR_EXPLICIT" == "true" ]]; then
    self="${self} --output-dir $(printf '%q' "$OUTPUT_DIR")"
  fi
  if [[ -n "$DESCRIPTION" ]]; then
    self="${self} --description $(printf '%q' "$DESCRIPTION")"
  fi

  echo "" >&2
  echo "   No runtime fallback was attempted (by design: swapping the model changes" >&2
  echo "   what got reviewed, and the substitute may bill a costlier tier)." >&2
  echo "   Re-run the failed task(s) yourself:" >&2

  local entry task rc cli persp fb fb_tier
  for entry in $FAILED_TASKS; do
    task="${entry%:*}"
    rc="${entry##*:}"
    cli="${task%%/*}"
    persp="${task#*/}"
    echo "" >&2
    # Only a timeout is helped by a longer limit. Offering it for expired
    # credentials or a crash sends the user off to wait twice as long for the
    # identical failure.
    if [[ "$rc" -eq 124 ]]; then
      echo "     ${task} — more time on the same CLI:" >&2
      echo "       $(model_env_prefix "$cli")${self} --cli ${cli} --perspective ${persp} --timeout $((TIMEOUT * 2))" >&2
    elif [[ -f "${OUTPUT_DIR}/${cli}/${persp}.md" ]]; then
      echo "     ${task} — failed for a reason more time will not fix; read the CLI" >&2
      echo "       stderr in ${OUTPUT_DIR}/${cli}/${persp}.md, then re-run:" >&2
      echo "       $(model_env_prefix "$cli")${self} --cli ${cli} --perspective ${persp}" >&2
    else
      # ワーカーが記録前に死んだ形。成果物は書かれていないので、存在しない
      # ファイルを読めとは案内しない（死因は上の ⚠️ worker 行にある）。
      echo "     ${task} — no result file was written (orchestrator-side failure;" >&2
      echo "       see the ⚠️ worker line above). Re-run:" >&2
      echo "       $(model_env_prefix "$cli")${self} --cli ${cli} --perspective ${persp}" >&2
    fi
    # プラン構築と同じ解決を使う。ここだけ get_cli_fallback を直接呼ぶと、
    # 「設定上の代替は未導入だが、その先には導入済みがある」場合に代替案が出ない。
    fb="$(resolve_available_fallback "$cli")"
    if [[ -n "$fb" ]]; then
      fb_tier="$(get_cli_cost_tier "$fb")"
      echo "     ${task} — or the configured substitute ${fb} [${fb_tier}]:" >&2
      # 代替 CLI の行には代替 CLI に効く env だけを前置する（失敗した CLI の
      # モデル指定を持ち越すと、実際には使われない設定を使うかのように読める）
      echo "       $(model_env_prefix "$fb")${self} --cli ${fb} --perspective ${persp}" >&2
    fi
  done
}

# ── Report Body (shared by review / explore / implement) ──
# Appends one section per plan entry to $1. Returns 0 if at least one section was
# written, 1 if the plan yielded none (the caller prints its own "no results" line).
#
# Stale-result guard: report exactly THIS run's entries by iterating the execution plan
# instead of globbing ${cli}/*.md. A perspective absent from this plan is never
# read. In the normal flow execute_tasks clears each entry's target before
# running (clear_planned_outputs), so a prior run's result — a different
# perspective, or a same-named stale file left by a failed task — does not
# appear as current. The report only reads result files and writes report_file;
# no result file is deleted or modified *here*, though the run itself is not
# side-effect free on a shared --output-dir: execute_tasks deletes this run's own
# targets (clear_planned_outputs) and moves the plan's other results into
# <cli>/previous/, discarding what an earlier run left there
# (quarantine_unplanned_outputs). A planned entry with no
# output file (CLI failure) is surfaced, not silently dropped. Callers must pass
# only validated plan entries — today every caller reaches here via
# generate_report, which runs validate_execution_plan first.
#
# This was three byte-identical copies, one per task type. The incomplete-result
# banner below has to be on every path — a truncated review that reads as a clean
# one is the failure mode issue #152 is about — so there is one copy to change.
append_plan_sections() {
  local report_file="$1"
  local wrote_any=1

  # 今回の実行が書かなかった結果ファイルの名指し（Issue #537 / #654）。退避できない
  # もの（プラン外 CLI のディレクトリ・orchestrator 以外が書いた .md）は動かさない
  # 契約なので、レポート側で「これは今回の結果ではない」と言い切っておく。
  local note
  if [[ -n "${UNPLANNED_RESULT_NOTES:-}" ]]; then
    {
      echo ""
      echo "> **Not part of this run** — the output directory also holds files this run did not write."
      echo "> They were left untouched and are NOT this run's results:"
      echo ">"
      while IFS= read -r note; do
        [[ -n "$note" ]] || continue
        echo "> - ${note}"
      done <<< "$UNPLANNED_RESULT_NOTES"
    } >> "$report_file"
  fi

  local entry seen=""
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    # Skip a duplicate plan entry so a repeated cli:perspective (e.g. a plan
    # fallback that reassigns a perspective to an already-listed CLI) is not
    # pasted into the report twice.
    if [[ " $seen " == *" $entry "* ]]; then continue; fi
    seen="$seen $entry"
    local cli_name="${entry%%:*}"
    local perspective_name="${entry#*:}"
    local result_file="${OUTPUT_DIR}/${cli_name}/${perspective_name}.md"
    wrote_any=0

    local tier
    tier="$(get_cli_cost_tier "$cli_name")"

    {
      echo ""
      echo "## ${cli_name} — ${perspective_name} [${tier}]"
      echo ""
      if list_contains "$REUSED_TASKS" "${cli_name}/${perspective_name}"; then
        echo "**Result source:** reused"
      else
        echo "**Result source:** executed"
      fi
      echo ""
      # implement は staging を**実測して**書く（Issue #392）。ヘッダの無条件な
      # 「生成物は staging にある」だけだと、1 ファイルも生成しなかったタスクも
      # 同じ案内になり、利用者は空のディレクトリを探しに行く。件数は数えれば
      # 分かるのだから、断定ではなく観測を載せる。
      # 0 件を失敗にはしない — 分析だけで生成ファイルが 0 個という結果は正当。
      if [[ "${TASK_TYPE:-review}" == "implement" ]]; then
        local staging_dir file_list file_count
        staging_dir="$(staging_dir_for "$cli_name" "$perspective_name")"
        if [[ ! -d "$staging_dir" ]]; then
          echo "**Staging:** \`${staging_dir}\` — (no files generated)"
        # find の rc を捨てると、走査に失敗した（権限・I/O エラー）ケースが
        # 「0 件」や部分件数として出る。断定を観測に置き換えるのが目的なのに、
        # 観測できなかったことを 0 件と言い切っては元の木阿弥になる。
        elif ! file_list="$(find "$staging_dir" -type f 2>/dev/null)"; then
          echo "**Staging:** \`${staging_dir}\` — ⚠️ could not read the staging directory (count unknown)"
        else
          # 空文字のときに grep -c が 1 を返す形を避けるため、空を先に分岐する。
          if [[ -z "$file_list" ]]; then
            file_count=0
          else
            file_count="$(printf '%s\n' "$file_list" | wc -l | tr -d ' ')"
          fi
          if [[ "$file_count" -gt 0 ]]; then
            echo "**Staging:** \`${staging_dir}\` (${file_count} file(s))"
          else
            echo "**Staging:** \`${staging_dir}\` — (no files generated)"
          fi
        fi
        echo ""
      fi
      if [[ -f "$result_file" ]]; then
        # An adapter marks salvaged partial output with `Status: incomplete`
        # (adapters/adapter-common.sh). Repeat that in the report: without it the
        # section looks like any other and its silence reads as "found nothing"
        # rather than "never got there".
        #
        # Scoped to the header block, because a *complete* review whose body
        # quotes that marker line would otherwise be flagged incomplete — very
        # reachable here, where the tool reviews its own scripts.
        #
        # The scope ends at the first blank line, which is what separates
        # write_output's header from the body. A fixed line count would silently
        # drift the wrong way if the header ever gained a line: the marker would
        # fall outside the window and an incomplete result would read as complete.
        #
        # Done with awk rather than `head | grep -q`: grep's early exit SIGPIPEs
        # head, and under pipefail the pipeline returns 141, flipping a match into
        # a non-match (the inversion class recorded in ACE-149).
        if awk '/^$/ { exit } /^<!-- Status: incomplete -->$/ { found = 1 } END { exit found ? 0 : 1 }' "$result_file"; then
          echo "⚠️ **INCOMPLETE** — the CLI failed or timed out; what follows is partial"
          echo "output salvaged from that run, not a finished ${TASK_TYPE}. Absence of a"
          echo "finding here means unchecked, not clean."
          echo ""
        fi
        cat "$result_file"
      else
        echo "⚠️ No output produced by this task — the CLI failed before writing any"
        echo "result. See the orchestrator log for the reason and the retry command."
      fi
      echo ""
      echo "---"
      echo ""
    } >> "$report_file"
  done <<< "$EXECUTION_PLAN"

  return "$wrote_any"
}

# ── CRITICAL_BLOCK 段階化（Issue #645）──
# 「非ブロック」へ格下げする観点の集合。ここに載った観点の Critical は修正必須の
# まま（本文はレポートに従来どおり Critical として現れる）だが、それ単独では
# <!-- CRITICAL_BLOCK --> を立てず <!-- CRITICAL_NONBLOCK --> の注記になる。
# 実測 22 巡のうち終盤 4 巡が comment-analysis の文言 Critical だけでフルゲートを
# 再実行しており、セキュリティ穴と文言指摘が同じ重さでは重い方の警報が薄まる。
#
# 集合は denylist — 載っていない観点（comprehensive-review・将来の追加観点を含む）
# は従来どおりブロックする。allowlist（ブロックする観点を列挙）にすると、新設の
# セキュリティ系観点が名簿更新を忘れただけで黙って非ブロックへ落ちる（fail open）。
#
# 解決の**形**（env の `+set` 判定・空文字の意思表示・project config の yq 読み）は
# resolve_reviewer_pair に合わせるが、第 3 層は別物 — あちらはユーザーグローバル
# （reviewers ファイル）へ落ち、こちらは組み込み既定へ落ちる:
#   env    MULTI_AGENT_CRITICAL_NONBLOCK_PERSPECTIVES
#          空文字の明示指定は「全観点ブロック（旧挙動）」の意思表示なので、
#          下位層で埋め戻さない
#   config review.critical_nonblock_perspectives（空白またはカンマ区切りの **1 文字列**。
#          YAML リストで書くと yq -r が複数行を返し名前が観点に一致しなくなるため、
#          警告して既定へ落とす。yq が無い環境でも読めず既定へ落ちる — 解析不能な
#          config を既定で動かす扱いは load_config と同じ）
DEFAULT_CRITICAL_NONBLOCK_PERSPECTIVES="comment-analysis test-analysis type-design-analysis code-simplification"

resolve_critical_nonblock_perspectives() {
  local v cfg
  if [[ "${MULTI_AGENT_CRITICAL_NONBLOCK_PERSPECTIVES+set}" == "set" ]]; then
    v="$MULTI_AGENT_CRITICAL_NONBLOCK_PERSPECTIVES"
  else
    v="$DEFAULT_CRITICAL_NONBLOCK_PERSPECTIVES"
    if [[ -f "$CONFIG_FILE" ]] && command -v yq &>/dev/null; then
      cfg="$(yq -r '.review.critical_nonblock_perspectives // ""' "$CONFIG_FILE" 2>/dev/null || true)"
      # 複数行 = 複数要素のリスト、行頭の "- " = 単一要素のリスト（yq -r は
      # どちらもブロックシーケンス形で返す。観点名が "-" で始まることはない）
      if [[ "$cfg" == *$'\n'* || "$cfg" == -* ]]; then
        echo "⚠️ review.critical_nonblock_perspectives は YAML リストではなく 1 文字列（空白またはカンマ区切り）で指定してください。読み飛ばして既定名簿を使います" >&2
      elif [[ -n "$cfg" && "$cfg" != "null" ]]; then
        v="$cfg"
      fi
    fi
  fi
  # 区切りをスペースへ正規化（カンマ・タブ区切りも受ける）。membership 判定は
  # 前後スペースの literal 一致なので、正規化しないとタブ区切りで指定された観点が
  # 黙ってブロック側へ倒れる — fail closed の向きではあるが、利用者の指定が
  # 静かに無視される形になる
  v="${v//,/ }"
  v="${v//$'\t'/ }"
  printf '%s\n' "$v"
}

# ── Generate Report (review) ──
generate_review_report() {
  local report_file="${OUTPUT_DIR}/integrated-report.md"

  echo "📝 Generating integrated review report..." >&2

  cat > "$report_file" <<HEADER
# Multi-CLI Review — Integrated Report

**Generated:** $(date -u +"%Y-%m-%dT%H:%M:%SZ")
**Mode:** ${MODE}
**Strategy:** ${STRATEGY}
**Base Branch:** ${BASE_BRANCH}

---

HEADER

  local has_results=true
  append_plan_sections "$report_file" || has_results=false

  if [[ "$has_results" == "false" ]]; then
    echo "(No review results found.)" >> "$report_file"
  fi

  # CRITICAL_BLOCK は Critical の実所見があるときだけ出す（Issue #272）。マーカーは
  # pre-push ゲートが push をブロックする根拠なので、誤出力は誤ブロック、出力漏れは
  # ゲートの素通りになる。旧判定 `^\s*-\s*\[.*:.*\]` は重大度に関係なく [file:line]
  # 箇条書き全部に発火し、Important のみのレビューでも Critical と宣言していた。
  #
  # さらに観点別の段階化を掛ける（Issue #645）: 非ブロック観点（既定は
  # DEFAULT_CRITICAL_NONBLOCK_PERSPECTIVES、上の resolve_critical_nonblock_perspectives
  # で上書き可）の Critical は CRITICAL_BLOCK を立てず、<!-- CRITICAL_NONBLOCK -->
  # の注記として出す。注記のマーカー名と本文に文字列 "CRITICAL_BLOCK" を含めては
  # ならない — 消費側ゲートの正規契約はマーカー全文の固定文字列一致
  # `grep -qF -- '<!-- CRITICAL_BLOCK -->'`（multi-cli-review-orchestration.md）だが、
  # 旧来のゲートには裸の部分一致 `grep -q "CRITICAL_BLOCK"` が残っており、含めると
  # ブロックしないはずの注記がブロックとして誤検知される。なお連結される各 result
  # file の**本文**が当該文字列を含む可能性（Verdict 語彙・マーカーの引用）は
  # 生成側では消せない — 引用ごと書き換えるとレビュー本文を改変することになる。
  # だからこそ消費側契約をマーカー全文一致に締めてある（裸の言及では発火しない）。
  #
  # 判定は連結後の統合レポートではなく**各 result file の本文**に掛ける — 連結後に
  # 掛けると (1) 1 本の CLI 出力の未閉フェンスが後続セクション全部を不可視にする
  # 越境マスク、(2) orchestrator 自身が書く節見出しの判定への混入、が構造的に生まれる。
  # 判定の 3 経路（大文字小文字は tolower で吸収。perspective テンプレート群の
  # CRITICAL Issues / Critical Vulnerabilities / Critical Gaps 表記を含む契約）:
  #   (a) critical を含む見出しの配下の箇条書き。別の同深度以浅の見出しでスコープ
  #       終了（サブ見出しでは維持）。no critical / non-critical 見出しと、
  #       「- なし」「- none」等の空所見箇条書きは不算入
  #   (b) 集計行 `- Critical[ Issues| Vulnerabilities| Gaps]: N`（N>=1。行頭アンカー
  #       + 語彙固定で、散文の言及や「- critical path latency: 3ms」を拾わない）
  #   (c) 行頭の `CRITICAL:` マーカー
  # コードフェンス内（先頭空白許容）は引用として数えない — 本ツールが自身のスクリプト
  # や perspective 文書をレビューすると、テンプレートの Critical 見出しごと引用される。
  # フェンスが閉じないまま本文が終わる場合は判定不能（rc=2）として安全側（マーカー
  # あり）へ倒す。awk 自体の失敗も同様に安全側へ倒し、診断を stderr へ残す。
  # 検出力は tests/multi-agent-critical-marker/ が stub CLI の実走で固定する。
  local crit_entry crit_seen="" crit_file crit_rc crit_found crit_persp
  local crit_block_hits="" crit_nonblock_hits="" crit_nonblock_set
  # 判定不能（未閉フェンス / awk 失敗）は実所見と別のリストに持つ。マーカーの
  # 発火条件としては同格（安全側 = Critical あり）だが、レポート上で「実所見が
  # あった」と「本文を判定しきれなかった」を同じ文で報告すると、判定不能の観測が
  # stderr にしか残らず、INCOMPLETE と同型の「空振りを所見と読む」誤読を生む。
  local crit_block_unparse="" crit_nonblock_unparse="" crit_target
  crit_nonblock_set="$(resolve_critical_nonblock_perspectives)"
  # 名簿の typo は「その観点が計画に現れない」だけでブロック側へ倒れる（fail closed）
  # ため実害はないが、意図した格下げが黙って効かないので診断を残す。
  for crit_persp in $crit_nonblock_set; do
    if [[ -z "$(resolve_perspective_file "$crit_persp")" ]]; then
      echo "⚠️ critical_nonblock_perspectives の '${crit_persp}' は存在しない観点名です（typo?）。未知の名前は無視され、載っていない観点は従来どおりブロックします" >&2
    fi
  done
  while IFS= read -r crit_entry; do
    [[ -z "$crit_entry" ]] && continue
    if [[ " $crit_seen " == *" $crit_entry "* ]]; then continue; fi
    crit_seen="$crit_seen $crit_entry"
    crit_file="${OUTPUT_DIR}/${crit_entry%%:*}/${crit_entry#*:}.md"
    [[ -f "$crit_file" ]] || continue
    set +e
    awk '
      /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
      fence { next }
      { l = tolower($0) }
      /^#+[[:space:]]/ {
        match($0, /^#+/); lvl = RLENGTH
        if (in_crit && lvl > crit_lvl) next
        in_crit = 0
        if (l ~ /critical/ && l !~ /no[[:space:]]+critical/ && l !~ /non-critical/) {
          in_crit = 1; crit_lvl = lvl
        }
        next
      }
      in_crit && l ~ /^[[:space:]]*-[[:space:]]/ {
        if (l !~ /^[[:space:]]*-[[:space:]]*(なし|該当なし|特になし|none|n\/a|no issues)[[:space:]。.]*$/) found = 1
      }
      l ~ /^[[:space:]]*-[[:space:]]*critical( issues| vulnerabilities| gaps)?:[[:space:]]*[1-9]/ { found = 1 }
      l ~ /^critical:/ { found = 1 }
      END {
        if (fence != 0) exit 2
        exit found ? 0 : 1
      }
    ' "$crit_file"
    crit_rc=$?
    set -e
    # 判定不能（rc=2: 未閉フェンス / rc>2: awk 失敗）は「Critical あり」へ倒す。
    # 倒した先の重さ（ブロック / 非ブロック）はその観点の段階に従う — 非ブロック
    # 観点は Critical が実在してもブロックしない契約なので、判定不能をブロックまで
    # 格上げすると安全側を越えて旧挙動の誤ブロックが戻る。
    crit_found=""
    case "$crit_rc" in
      0) crit_found=real ;;
      1) : ;;
      2)
        echo "⚠️ CRITICAL_BLOCK 判定: ${crit_file} のコードフェンスが閉じておらず本文を判定しきれません。判定不能を Critical なしとして通さないため、安全側（Critical あり）に倒します" >&2
        crit_found=unparse ;;
      *)
        echo "⚠️ CRITICAL_BLOCK 判定を実行できませんでした（awk rc=${crit_rc}: ${crit_file}）。判定不能を Critical なしとして通さないため、安全側（Critical あり）に倒します" >&2
        crit_found=unparse ;;
    esac
    if [[ -n "$crit_found" ]]; then
      crit_persp="${crit_entry#*:}"
      if [[ " ${crit_nonblock_set} " == *" ${crit_persp} "* ]]; then
        crit_target="nonblock"
      else
        crit_target="block"
      fi
      case "${crit_target}:${crit_found}" in
        block:real)
          [[ " ${crit_block_hits} " == *" ${crit_persp} "* ]] || crit_block_hits="${crit_block_hits:+${crit_block_hits} }${crit_persp}" ;;
        block:unparse)
          [[ " ${crit_block_unparse} " == *" ${crit_persp} "* ]] || crit_block_unparse="${crit_block_unparse:+${crit_block_unparse} }${crit_persp}" ;;
        nonblock:real)
          [[ " ${crit_nonblock_hits} " == *" ${crit_persp} "* ]] || crit_nonblock_hits="${crit_nonblock_hits:+${crit_nonblock_hits} }${crit_persp}" ;;
        nonblock:unparse)
          [[ " ${crit_nonblock_unparse} " == *" ${crit_persp} "* ]] || crit_nonblock_unparse="${crit_nonblock_unparse:+${crit_nonblock_unparse} }${crit_persp}" ;;
      esac
    fi
  done <<< "$EXECUTION_PLAN"
  if [[ -n "$crit_block_hits" || -n "$crit_block_unparse" ]]; then
    {
      echo ""
      echo "<!-- CRITICAL_BLOCK -->"
      if [[ -n "$crit_block_hits" ]]; then
        echo "Critical issues detected (${crit_block_hits// /, }). Review before proceeding."
      fi
      if [[ -n "$crit_block_unparse" ]]; then
        echo "Unparseable result treated as critical (${crit_block_unparse// /, }): the body could not be fully judged — see the run diagnostics."
      fi
    } >> "$report_file"
  fi
  if [[ -n "$crit_nonblock_hits" || -n "$crit_nonblock_unparse" ]]; then
    # 本文に "CRITICAL_BLOCK" を部分一致で含めないこと（上の段階化コメント参照）。
    {
      echo ""
      echo "<!-- CRITICAL_NONBLOCK -->"
      if [[ -n "$crit_nonblock_hits" ]]; then
        echo "Critical findings in non-blocking perspectives (${crit_nonblock_hits// /, })."
      fi
      if [[ -n "$crit_nonblock_unparse" ]]; then
        echo "Unparseable result treated as critical, in non-blocking perspectives (${crit_nonblock_unparse// /, })."
      fi
      echo "Fix them per the review response policy; on their own they do not re-trigger the full gate."
    } >> "$report_file"
  fi

  echo "📄 Report: ${report_file}" >&2
}

# ── Generate Report (explore) ──
generate_explore_report() {
  local report_file="${OUTPUT_DIR}/integrated-report.md"

  echo "📝 Generating integrated explore report..." >&2

  cat > "$report_file" <<HEADER
# Multi-CLI Explore — Integrated Report

**Generated:** $(date -u +"%Y-%m-%dT%H:%M:%SZ")
**Description:** ${DESCRIPTION}
**Mode:** ${MODE}
**Strategy:** ${STRATEGY}

---

HEADER

  local has_results=true
  append_plan_sections "$report_file" || has_results=false

  if [[ "$has_results" == "false" ]]; then
    echo "(No explore results found.)" >> "$report_file"
  fi

  echo "📄 Report: ${report_file}" >&2
}

# ── Generate Report (implement) ──
generate_implement_report() {
  local report_file="${OUTPUT_DIR}/integrated-report.md"

  echo "📝 Generating integrated implement report..." >&2

  cat > "$report_file" <<HEADER
# Multi-CLI Implement — Integrated Report

**Generated:** $(date -u +"%Y-%m-%dT%H:%M:%SZ")
**Description:** ${DESCRIPTION}
**Mode:** ${MODE}
**Strategy:** ${STRATEGY}

---

⚠️ **Generated files are in the staging directory, not the working tree.** Review before applying.

Staging (per task): \`${OUTPUT_DIR}/<cli>/files/<perspective>/\` — each section below
names its own path and the number of files actually found there.

Only the tasks in **this** run's plan had their staging cleared beforehand. If you
narrowed the run (\`--cli\` / \`--perspective\`), other tasks' \`files/\` directories may
still hold output from an earlier run — read the sections below, not the whole tree.

---

HEADER

  local has_results=true
  append_plan_sections "$report_file" || has_results=false

  if [[ "$has_results" == "false" ]]; then
    echo "(No implement results found.)" >> "$report_file"
  fi

  echo "📄 Report: ${report_file}" >&2
}

# ── Generate Report (dispatcher) ──
generate_report() {
  # Reject a plan with unsafe path segments before any builder reads from it.
  validate_execution_plan || return 1
  case "$TASK_TYPE" in
    review)    generate_review_report ;;
    explore)   generate_explore_report ;;
    implement) generate_implement_report ;;
  esac
}

# ── Main ──
main() {
  local emoji

  # Two-pass parsing: extract --config and --task first
  local prev_flag=""
  for arg in "$@"; do
    if [[ "$prev_flag" == "--config" ]]; then
      CONFIG_FILE="$arg"
      CONFIG_SOURCE="--config flag"
      prev_flag=""
      continue
    fi
    if [[ "$prev_flag" == "--task" ]]; then
      TASK_TYPE="$arg"
      prev_flag=""
      continue
    fi
    if [[ "$arg" == "--config" || "$arg" == "--task" ]]; then
      prev_flag="$arg"
    else
      prev_flag=""
    fi
  done

  load_config
  parse_args "$@"

  # 一覧は description 必須検査より前に返す（explore/implement で「一覧を見たいだけ」
  # なのに落ちるのを避ける）。ただし**引数の妥当性検査は通す** — ここを飛ばすと
  # `--list-perspectives --cli no-such-cli` が rc=0 になり、綴り間違いが成功として
  # 返る（実測で一度そう作ってしまった）。
  if [[ "$LIST_PERSPECTIVES" == "true" ]]; then
    validate_requested_clis
    validate_requested_perspectives
    validate_excluded_perspectives
    all_task_perspectives
    exit 0
  fi
  apply_task_defaults
  validate_requested_clis
  validate_requested_perspectives
  validate_excluded_perspectives

  # ── レビュワーの参照・保存（プランを組む前に処理して終了する経路） ──
  #
  # 聞く役はスキル層に置く。Claude Code の Bash 実行は stdin/stdout/stderr すべて
  # NOT-TTY と実測済みで、`[ -t 0 ]` で対話を出す設計だと /multi-review 経由では
  # プロンプトが一度も出ず、全員が黙って単一レビューのまま固定される。ここは
  # 「状態を機械可読で返す」「検証して保存する」の 2 つだけを担う。
  if [[ -n "$SET_REVIEWERS" ]]; then
    set_reviewers_from_spec "$SET_REVIEWERS"
    exit $?
  fi

  resolve_reviewer_pair || exit 1

  # 一覧はプランを構築する**前**に返す。プラン構築まで進むと、一覧のつもりの実行で
  # CLI 検出や設定読み込みの副作用が走る。
  if [[ "$PRINT_REVIEWERS" == "true" ]]; then
    print_reviewers_state
    exit $?
  fi

  # --cli は分散モード用のフィルタ（所有レジストリを絞る）で、pair モードには
  # 対応する概念が無い。review の既定が pair になったことで、従来 --cli で回して
  # いた指定が**黙って無視される**状態になっていた（効かないつまみ）。
  # 明示的に --mode pair を要求されている場合だけ矛盾としてエラーにし、それ以外は
  # 分散モードへ落として通知する（従来の使い方をそのまま通す）。
  if [[ "$MODE" == "pair" && -n "$CLI_FILTER" ]]; then
    if [[ "$MODE_EXPLICIT" == "true" ]]; then
      echo "ERROR: --cli cannot be combined with --mode pair." >&2
      echo "       In pair mode the reviewers are the main/sub pair, not a filter." >&2
      echo "       Override them for one run with MULTI_AGENT_REVIEW_MAIN / _SUB." >&2
      exit 1
    fi
    echo "ℹ️  --cli given — using the distributed plan (it is a distributed-mode filter)." >&2
    echo "   To pick reviewers for one run instead: MULTI_AGENT_REVIEW_MAIN=<cli> MULTI_AGENT_REVIEW_SUB=<cli>" >&2
    MODE="distributed"
  fi

  # review で主が決まっていない場合の縮退。CI を止めないため、対話は試みず
  # 従来の分散プランへ落とす（今日までと同じ挙動）。
  if [[ "$MODE" == "pair" && -z "$REVIEW_MAIN" ]]; then
    echo "ℹ️  No reviewers configured — falling back to the distributed plan." >&2
    echo "   Set them once with: bash $(printf '%q' "${SCRIPT_DIR}/multi-agent.sh") --task review --set-reviewers main=<cli>,sub=<cli>" >&2
    MODE="distributed"
  fi

  emoji="$(get_task_emoji "$TASK_TYPE")"

  echo "${emoji} Multi-CLI Agent Orchestrator — ${TASK_TYPE}" >&2
  echo "================================================" >&2
  echo "" >&2

  echo "🔎 Detecting available CLIs..." >&2
  detect_available_clis

  echo "" >&2
  echo "📊 Building execution plan..." >&2

  if [[ "$MODE" == "cross-model" ]]; then
    build_cross_model_plan
  elif [[ "$MODE" == "pair" ]]; then
    build_pair_plan || exit 1
  else
    build_distributed_plan
  fi

  show_plan

  # Validate TIMEOUT
  if ! echo "$TIMEOUT" | grep -qE '^[0-9]+$' || [[ "$TIMEOUT" -eq 0 ]]; then
    echo "ERROR: --timeout must be a positive integer, got: '${TIMEOUT}'" >&2
    exit 1
  fi

  # Fail loudly on an empty plan — never report success when nothing ran.
  #
  # This sits BEFORE the dry-run exit on purpose. It used to sit after, so a
  # filter combination that matched nothing exited 1 on a real run but 0 on
  # --dry-run, printing "🏁 Dry run complete." A dry run is a plan validation
  # boundary (see the header), so the two paths have to agree on what an empty
  # plan means.
  if [[ -z "$EXECUTION_PLAN" ]]; then
    echo "ERROR: Execution plan is empty — nothing would be reviewed." >&2
    # 原因は 2 種類あり、利用者の次の一手が違う。フィルタを 1 つも渡していない人に
    # 「--cli / --perspective を見直せ」と言っても指し先が誤っている。
    if [[ -z "$CLI_FILTER" && -z "$PERSPECTIVE_FILTER" ]]; then
      echo "       Every installed CLI is metered and excluded from the default lineup." >&2
      echo "       Opt in explicitly (e.g. --cli copilot-cli), or install a non-metered CLI." >&2
    else
      echo "       Check --cli / --perspective / --mode combinations." >&2
    fi
    exit 1
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "🏁 Dry run complete. No tasks executed." >&2
    exit 0
  fi

  # ── Pre-dispatch safety: never burn CLI quota on a meaningless diff ──
  if [[ "$TASK_TYPE" == "review" || "$INCLUDE_DIFF" == "true" ]]; then
    if [[ "$IN_GIT_REPO" != "true" ]]; then
      echo "ERROR: task '${TASK_TYPE}' requires a git diff, but the current directory is not inside a git repository." >&2
      exit 1
    fi
    if [[ "$STAGED_DIFF" != "true" ]] && ! git rev-parse --verify --quiet "${BASE_BRANCH}^{commit}" >/dev/null 2>&1; then
      echo "ERROR: base branch '${BASE_BRANCH}' does not resolve to a commit." >&2
      echo "       Fix: pass --base <branch>, set MULTI_AGENT_BASE_BRANCH, or run: git remote set-head origin -a" >&2
      exit 1
    fi
  fi
  if [[ "$TASK_TYPE" == "review" ]]; then
    if [[ "$STAGED_DIFF" == "true" ]]; then
      if git diff --cached --quiet 2>/dev/null; then
        echo "ℹ️  No staged changes to review — skipping without starting any CLI." >&2
        exit 0
      fi
    elif git diff --quiet "${BASE_BRANCH}...HEAD" 2>/dev/null && git diff --quiet HEAD 2>/dev/null; then
      echo "ERROR: nothing to review — branch diff against '${BASE_BRANCH}' and working-tree changes are both empty." >&2
      exit 1
    fi
  fi

  # execute_tasks の rc は 2 種類を区別する:
  #   1 … タスクが失敗した。実行はしたので、何が落ちたかを含むレポートに価値がある
  #   2 … 実行前の準備が失敗した（プラン検証・出力先の解決・前回出力の掃除）。
  #        この場合レポートを出してはいけない — 掃除できなかった前回の成果物を
  #        「今回の結果」として並べ、"Done! View results" と案内したうえで
  #        exit 1 する形になり、本 PR が塞いだ stale 誤読をレポート層で再現する。
  local task_failed=false
  local setup_failed=false
  local exec_rc=0
  execute_tasks || exec_rc=$?
  if [[ -n "$FULL_EXECUTION_PLAN" ]]; then
    EXECUTION_PLAN="$FULL_EXECUTION_PLAN"
  fi
  case "$exec_rc" in
    0) ;;
    2) setup_failed=true ;;
    *) task_failed=true ;;
  esac

  if [[ "$setup_failed" == "true" ]]; then
    echo "" >&2
    echo "❌ Aborted before running any task — no report was generated." >&2
    echo "   (a report here would list the previous run's output as if it were this run's)" >&2
    exit 1
  fi

  # ── リビジョンガード: 実行後の照合 ──
  # 基準は execute_tasks が diff を固定するのと同じ瞬間に取っている
  # （capture_baseline_and_fix_diff）。ここはその基準との突き合わせだけを行う。
  # レポート生成の**前**に置く。後に置くと、破棄すると宣言した実行のレポートを
  # 先に書き出してしまい、"Done! View results" の案内先にそれが残る。
  # git リポジトリ外・タスク未実行では基準が空のままなので、その場合は何もしない。
  if [[ -n "$REPO_SNAPSHOT_BEFORE" ]]; then
    verify_repo_unchanged || exit 1
  fi

  generate_report

  echo "" >&2
  echo "🏁 Done! View results:" >&2
  echo "   cat ${OUTPUT_DIR}/integrated-report.md" >&2

  if [[ "$task_failed" == "true" ]]; then
    exit 1
  fi
}

main "$@"
