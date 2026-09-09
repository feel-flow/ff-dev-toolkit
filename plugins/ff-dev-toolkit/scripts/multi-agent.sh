#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────
# multi-agent.sh — Multi-CLI Agent Orchestrator
# ────────────────────────────────────────────────────────────
# Orchestrates 4 AI CLIs (Claude Code, Codex, Copilot, Grok)
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
# Effort env (optional, unset = CLI settings):
#   MULTI_AGENT_CLAUDE_EFFORT -> --effort (low/medium/high/xhigh/max)
#   MULTI_AGENT_CODEX_REASONING_EFFORT -> -c model_reasoning_effort
# Models and existing Codex profiles are unchanged; runtime values remain unverified.
#
# Options:
#   --task <type>           review | explore | implement (default: review)
#   --description <text>    Task description (required for explore/implement)
#   --config <path>         Config file (default: $MULTI_AGENT_CONFIG > <project>/.claude/agent-config.yaml > plugin-bundled agent-config.yaml)
#   --mode <mode>           distributed | cross-model
#   --strategy <strategy>   balanced | minimize_cost | maximize_quality
#   --cli <name>            Run only this CLI (repeatable)
#   --exclude-cli <name>    Drop this CLI from the plan (repeatable). The CLI is
#                           treated exactly as if it were not installed, so its
#                           perspectives follow the same fallback path. A name
#                           that does not exist, and excluding a CLI that --cli
#                           also selects, are rejected — not ignored. The config
#                           key `exclude_clis` (space/comma-separated string) sets
#                           defaults for the environment; flag and config exclusions
#                           are unioned, and the plan names which source excluded
#                           each CLI.
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
#   --base <branch>         Base branch for diff (default: auto-detect from origin/HEAD, fallback: develop).
#                           A bare branch name resolves to whichever of the local ref and
#                           origin/<branch> is not stale, without fetching: when the local ref is a
#                           strict ancestor of origin/<branch> (base not pulled yet) the run uses
#                           origin/<branch>, so commits other branches merged into the base cannot
#                           leak into the three-dot diff. Identical / ahead / diverged local refs are
#                           kept as-is. The chosen ref is announced on stderr once, with both short
#                           SHAs (silent when both refs point at the same commit; the line says
#                           "鮮度を判定できませんでした" when git cannot decide, e.g. a shallow clone).
#                           A diverged local ref can still leak, and review / --include-diff runs keep
#                           printing the leak warning before the plan for that case. Pass
#                           origin/<branch> to opt out of the local ref entirely. Review-series
#                           identity and --resume identity use the requested name, not the resolved
#                           one, so pulling the base does not restart the series.
#   --staged                Review only the staged index diff (review task only; mutually exclusive with --base)
#   --resume                Reuse successful results from an identical prior input and
#                           execute only failed, timed-out, missing, or corrupt tasks
#   --fresh                 Archive leftover files in the output dir to
#                           <dir>/.prev-<timestamp>/ (the live lock stays) and start
#                           clean. The archive lives INSIDE the output dir so a
#                           consumer that ignores <dir>/ ignores the archive too — a
#                           sibling <dir>.prev-* did not match that ignore pattern and
#                           got swept into commits. Cannot be combined with --resume.
#   --include-diff          Include diff in implement prompts
#   --dry-run               Show plan without executing
#   --timeout <seconds>     Timeout per CLI (default: review 900 / explore 600 / implement 900)
#   --help                  Show this help
#
# Fallback semantics (two different things — do not confuse them):
#   Plan-time (automatic):  a CLI that is NOT INSTALLED has its perspectives
#                           reassigned to its fallback CLI while the plan is built.
#                           The fallback registry lives in this script
#                           (get_cli_fallback) and nowhere else; agent-config.yaml
#                           carries no copy of it and is never read for this.
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
#   reached through a symlink. Staging is not silent, though (Issue #724): under a
#   planned CLI, a non-empty `files/<perspective>/` outside this implement run's
#   plan (for review/explore runs: any non-empty one — those task types neither
#   clear nor write staging), a stray file or non-directory entry under `files/`,
#   and any symlink (`files/` itself or an entry below it — named as a link, never
#   followed) are all named on stderr and in the report, exactly like unplanned
#   CLI directories; a scan that fails is reported as such, not as "0 files".
#   A `<cli>/` that resolves anywhere other than itself
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
# 注意 1: adapter-common.sh は source 時に EXIT trap（_ff_adapter_exit_cleanup =
#   timeout-reason とプロンプト一時ファイルの掃除）を仕掛ける。
#   本スクリプトは acquire_output_lock で EXIT trap を張り直すのでそちらが勝つ。
#   orchestrator は run_with_timeout も materialize_prompt_file も呼ばない（それは
#   アダプタのプロセス内の話）ので、上書きしても失われる後始末は無い。
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
ALL_CLIS="claude-code codex-cli copilot-cli grok-cli"

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
    grok-cli)    echo "grok" ;;
    *) echo "" ;;
  esac
}

get_cli_adapter() {
  case "$1" in
    claude-code) echo "${SCRIPT_DIR}/adapters/claude-code-adapter.sh" ;;
    codex-cli)   echo "${SCRIPT_DIR}/adapters/codex-cli-adapter.sh" ;;
    copilot-cli) echo "${SCRIPT_DIR}/adapters/copilot-cli-adapter.sh" ;;
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
#   pattern-discovery → gemini-cli (→ grok-cli when gemini was removed, issue
#     #783): a broad read-only sweep; flat-rate has no marginal cost, the closest
#     analogue to the free tier this sweep was originally priced for.
#   migration → codex-cli, then → grok-cli when grok joined (issue #252).
#
# grok-cli's own three came from the CLIs carrying the most of each task, and
# were moved rather than shared: the distributed plan runs each CLI's owned
# perspectives, so two default-enabled CLIs sharing one perspective means paying
# to review the same thing twice. Sharing is only harmless when one side is
# excluded by default (copilot-cli, metered).
#   error-handler-hunt → grok-cli (from codex-cli): hunting silent failures is
#     worth a different model's eyes than the general code-review beside it.
#   tech-debt-assessment → grok-cli (from gemini-cli): judgment-heavy.
#   migration → grok-cli (from codex-cli): self-contained, and it moves load off
#     the CLI that otherwise carries the most of the implement task.
#
# gemini-cli was removed in issue #783 (unused in this project). Its perspectives
# were reassigned rather than retired, same doctrine as the cursor-cli removal:
#   security-analysis → grok-cli: hunting-shaped judgment work, pairs with
#     error-handler-hunt it already owns.
#   comment-analysis → claude-code: pr-review-toolkit lineage (comment-analyzer
#     is a Claude agent). Sharing with copilot-cli is harmless — copilot is
#     metered and excluded by default.
#   pattern-discovery → grok-cli, documentation → codex-cli (see notes above).
#
# acceptance-criteria → codex-cli (issue #1054): Issue の受け入れ条件（GWT / DoD）と
# diff の照合。既定セットに入れる（8 → 9 観点）判断の根拠 — DoD の列挙充足では GWT の
# 全称条件を満たさない非対称による取りこぼしが 2 PR 連続で実測され、観点をプロンプトへ
# 足した回は 1 巡目で検出できた。pair モードの主は perspectives/review のディスク走査で
# 全観点を担当するため、ディレクトリに置いた時点で既定に入る（opt-in にするには
# comprehensive-review 型の除外機構を増やす必要があり、その複雑さに見合う根拠が無い）。
# gh 呼び出しの増分コストは小さい: orchestrated 実行では大半のアダプタが gh を実行
# できず（claude-code の review allowlist は Bash(git diff*) のみ、codex は read-only
# sandbox）、観点内の分岐が PR 本文・diff 内の AC 記載からの照合へ fallback する。
# 所有を codex-cli にするのは、実装主体（多くは Claude 側）と別モデルの目で AC を
# 照合するクロスモデル価値と、DoD / カバレッジ照合系（test-analysis）の系譜が
# codex にあるため。flat-rate（grok）は逐次実行制約で観点追加が実時間に直結し、
# premium（claude-code）は既に 3 観点で最重負荷のため選ばない。
# 非ブロック名簿（DEFAULT_CRITICAL_NONBLOCK_PERSPECTIVES）には載せない —
# AC 未達の Critical はマージを止めるためにこの観点を足すので、ブロック側が既定。

get_cli_perspectives_review() {
  case "$1" in
    claude-code) echo "type-design-analysis code-simplification comment-analysis" ;;
    codex-cli)   echo "code-review test-analysis acceptance-criteria" ;;
    copilot-cli) echo "test-analysis comment-analysis" ;;  # metered — every task requires explicit --cli copilot-cli (see build_distributed_plan)
    grok-cli)    echo "error-handler-hunt security-analysis" ;;
    *) echo "" ;;
  esac
}

get_cli_perspectives_explore() {
  case "$1" in
    claude-code) echo "architecture-analysis" ;;
    codex-cli)   echo "dependency-mapping" ;;
    copilot-cli) echo "api-surface-analysis" ;;  # metered — every task requires explicit --cli copilot-cli
    grok-cli)    echo "tech-debt-assessment pattern-discovery" ;;
    *) echo "" ;;
  esac
}

get_cli_perspectives_implement() {
  case "$1" in
    claude-code) echo "feature-implementation" ;;
    codex-cli)   echo "refactoring documentation" ;;
    copilot-cli) echo "test-writing" ;;  # metered — every task requires explicit --cli copilot-cli
    grok-cli)    echo "migration" ;;
    *) echo "" ;;
  esac
}

get_cli_fallback() {
  case "$1" in
    claude-code) echo "codex-cli" ;;
    codex-cli)   echo "claude-code" ;;
    copilot-cli) echo "codex-cli" ;;
    grok-cli)    echo "codex-cli" ;;
    *) echo "" ;;
  esac
}

get_cli_cost_tier() {
  case "$1" in
    claude-code) echo "premium" ;;
    codex-cli)   echo "standard" ;;
    copilot-cli) echo "metered" ;;
    grok-cli)    echo "flat-rate" ;;
    # 既定の "unknown" は metered ではないので、resolve_available_fallback の
    # 「最後の砦」に選ばれうる。tier の書き漏れは課金される側へ倒れるということ。
    # 書き漏れ自体は tests/cli-registry-completeness が既知の tier 語で弾く。
    *) echo "unknown" ;;
  esac
}

get_cli_model_env_vars() {
  case "$1" in
    claude-code) echo "MULTI_AGENT_MODEL_CLAUDE_CODE MULTI_AGENT_CLAUDE_EFFORT" ;;
    codex-cli)   echo "MULTI_AGENT_MODEL_CODEX_CLI MULTI_AGENT_CODEX_PROFILE MULTI_AGENT_CODEX_REASONING_EFFORT" ;;
    copilot-cli) echo "MULTI_AGENT_MODEL_COPILOT_CLI" ;;
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

# プラン時に「この環境でサンドボックスを適用できるか」を尋ねられるアダプタ。
# 対応アダプタは `--probe-sandbox <task-type>` を受け、拒否を確定できたときだけ
# SANDBOX_PROBE_REFUSED_STATUS を返す（それ以外は 0 = 黙る）。
#
# 名前で分岐するのは、これが CLI 固有の性質そのものだから — grok は起動時に
# サンドボックスを適用してから走る唯一の CLI で、codex は sandbox サブコマンドを
# 持つが起動拒否の形にはならず、claude-code / copilot-cli には --sandbox の概念が無い。
# コスト帯のような横断属性へ畳めない。probe を持つアダプタが増えたらここへ足す。
#
# registry の境界（上の sentinel）の外に置く: この関数は固定値を返す case lookup では
# なく述語で、静的解析側の制限文法に載らない。
cli_sandbox_probe_supported() {
  case "$1" in
    grok-cli) return 0 ;;
    *)        return 1 ;;
  esac
}

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
# （上記実測は gemini-cli 在籍時のもの。#783 で gemini は削除されたが、「チェーンの
# 行き止まりで観点が黙って落ちる」という機構の教訓は CLI 構成に依らず有効）
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

# ── Locale-Independent Shell Quoting ──
#
# 貼り付け用コマンドの引用に `printf '%q'` は使わない。%q は**現在のロケールで
# 文字境界を解釈する**ため、非 UTF-8 ロケール（Windows / Git Bash のコンソール
# codepage 932、LANG 未設定の C ロケールなど）では UTF-8 の日本語がバイト単位に
# 分解され、しかも一部のバイトだけが $'\NNN' へ、残りは生バイトのまま出力される。
# 実測（LC_ALL=C）:
#
#     printf '%q' 'なし'   →   <e3> $'\201' <aa> <e3> $'\201' $'\227'
#
# 生の 0xE3 の直後に ASCII の `$` が続くので、**出力全体が不正な UTF-8 になる**
# （iconv -f UTF-8 -t UTF-8 が Illegal byte sequence で落ちることを実測）。この
# 文字列は失敗時の再実行案内や統合レポートへ載り、それを次回実行の --description
# （prior review evidence）として渡すと prompt 全体が不正な UTF-8 になる。codex-cli
# は "input is not valid UTF-8" で prompt 全体を拒否するため、全観点が incomplete
# で終わる（Windows の既定環境からの導入先報告として実測されている）。
#
# 単引用エスケープはバイト透過なので、入力が valid UTF-8 なら出力も valid UTF-8 で、
# ロケールに依存しない。素で貼っても安全な語はそのまま返す（%q と同じ見た目を保つ）。
# 許可集合は ASCII の英数字と記号だけを意図している。多バイト文字がロケールの照合
# 順で範囲に入って裸のまま返っても、シェルのメタ文字はこの集合に入らないため引用
# としての安全性は変わらない（生バイトのまま = valid UTF-8 のまま）。
shell_quote() {
  local s="$1"
  if [[ -n "$s" && "$s" != *[!A-Za-z0-9._/:=@%+-]* ]]; then
    printf '%s' "$s"
    return
  fi
  # 置換文字列は変数に置く。`${s//\'/...}` のリテラル記法はバックスラッシュの
  # 解釈が bash 3.2（macOS 既定）と 5.x で食い違い、3.2 では壊れた引用を出す（実測）。
  local sq="'" esc="'\\''"
  printf "'%s'" "${s//$sq/$esc}"
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
      prefix="${prefix}${var}=$(shell_quote "${!var}") "
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
CONFIG_PROVENANCE="env"
if [[ -z "$CONFIG_FILE" ]]; then
  if [[ -f "${REPO_ROOT}/.claude/agent-config.yaml" ]]; then
    CONFIG_FILE="${REPO_ROOT}/.claude/agent-config.yaml"
    CONFIG_SOURCE="project override"
    CONFIG_PROVENANCE="project"
  else
    CONFIG_FILE="${SCRIPT_DIR}/agent-config.yaml"
    CONFIG_SOURCE="plugin default"
    CONFIG_PROVENANCE="plugin"
  fi
fi
MODE=""            # 未指定なら apply_task_defaults がタスク種別ごとに決める
REVIEW_MAIN=""
REVIEW_SUB=""
REVIEWERS_SOURCE=""
MODE_EXPLICIT=false
# MODE の出所（--mode flag / config のキー / task default）。whitelist 拒否は config
# 由来でも発火するため、値だけ名指しすると利用者がどこを直せばよいか辿れない
# （STRATEGY_SOURCE と同じ理由 — Issue #691 / #699）。
# 有効なのは validate_mode / apply_task_defaults までで、その後 MODE は --cli 経路や
# レビュワー不在の fallback で distributed へ書き換わりうる（MODE_SOURCE は追随しない）。
# 後段でこの値を表示する読み手を足すなら、そこで出所を取り直すこと。
MODE_SOURCE="task default"
PRINT_REVIEWERS=false
SET_REVIEWERS=""
STRATEGY=""
# STRATEGY の出所（--strategy flag / config のキー / task default）。pair モードの
# 非適用通知と whitelist 拒否は config 由来でも発火するため、値だけ名指しすると
# 利用者がどこを直せばよいか辿れない（Issue #691）。
STRATEGY_SOURCE=""
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
# ── ツリー変化判定のパス除外（Issue #747） ──
#
# 常駐ツール（superpowers スキルが作る .superpowers/ 等）が実行中に書き続ける
# リポジトリでは、リビジョンガードの作業ツリー判定が毎回発火し、全タスク成功後に
# 結果が丸ごと破棄される。FF_MULTI_AGENT_IGNORE_PATHS（':' 区切り、pathspec の
# glob magic として解釈）に一致するパスを判定から外す。除外が効くのは
# **作業ツリーの指紋だけ**で、HEAD / ブランチの変化検出には影響しない
# （capture_repo_snapshot の除外は worktree の問い合わせにしか掛からない）。
# レビューは何も削除しないため、merge-cleanup と違い適用範囲を絞る必要は無い。
#
# .superpowers/** は**既定で除外**する。FF_MULTI_AGENT_IGNORE_PATHS は既定への
# **追加**であって置き換えではない — 置き換えにすると、別のパスを 1 つ設定した
# 瞬間に .superpowers 起因の全破棄が黙って再発する。
# 検証・パターン分解は parse_ignore_paths（main の冒頭で必ず呼ぶ）。
IGNORE_PATHS_DEFAULT='.superpowers/**'
IGNORE_EXCLUDE_PATHSPECS=(":(exclude,glob,top)${IGNORE_PATHS_DEFAULT}")
# 利用者指定パターンの肯定形（報告用）。既定パターンは含めない — 既定と利用者指定は
# ログで別々に名乗る（どちらの指定が効いたのかを実行ログから区別できるように）。
IGNORE_MATCH_PATHSPECS=()
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
# 鮮度解決（ローカル / remote-tracking のどちらが古くないか）は**ここではやらない**。
# parse_args の最後の finalize_base_branch で、最終的な base に対して 1 回だけ行う。
# ここで解決すると、--base を渡した実行でも「使われない既定 base」の選択行が 1 行出て、
# 最終 base の選択行と合わせて 2 行になる（別の base を指定したときは無関係な名前の行）。
#
# 呼び出し側が指定した base の**名前**（origin/ を落とした形）。レビュー系列 ID と
# --resume の identity はこちらを使う。解決結果（BASE_BRANCH）を使うと、ローカルの
# 鮮度が変わっただけで develop ↔ origin/develop が入れ替わり、同じレビュー文脈が
# 別系列と判定される（stale のまま 1 回目 → git pull 後の 2 回目が「another
# branch/base/scope」となり、強制的にフルレビューへ落ちる）。
BASE_BRANCH_IDENTITY="${BASE_BRANCH#origin/}"
DRY_RUN=false
RESUME=false
FRESH=false
TIMEOUT=""

# Space-separated filter lists (bash 3.2 compatible)
CLI_FILTER=""
PERSPECTIVE_FILTER=""
# 除外は包含フィルタへ畳み込まない。PERSPECTIVE_FILTER を埋めると、--cli と併用したとき
# 「明示ペアリング」経路（所有レジストリを迂回する）を意図せず踏む。独立に保つ。
EXCLUDE_PERSPECTIVES=""
# CLI の除外は 2 経路（--exclude-cli と config の exclude_clis）を**別々に**保つ。
# 和集合だけを持つと、プランの 1 行に出す出所（引数由来 / 設定由来）が復元できない —
# 「設定に書いた覚えのない CLI が消えている」を追えることが本機能の目的そのもの。
EXCLUDE_CLIS_FLAG=""
EXCLUDE_CLIS_CONFIG=""
EXCLUDE_CLIS_CONFIG_SOURCE=""
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
# pair の実効レビュワー構成（統合レポートの Reviewers 行。Issue #699）。空のままなら
# 行を出さない = pair 以外のモードでは何も足さない。build_pair_plan だけが埋める。
PAIR_REVIEWERS_NOTE=""

# Tasks that failed this run, as "cli/perspective:exit_code" (space-separated).
# Drives the retry advice printed after execution — a bare count leaves the user to
# work out which CLI to re-run and with what, which is exactly the moment they
# reach for a runtime fallback that does not exist. The exit code rides along
# because the right advice depends on it: more time helps a timeout and is useless
# for expired credentials. cli/perspective are validated single path segments and
# cannot contain ':', so the suffix is unambiguous.
FAILED_TASKS=""

# 先行タスクと同じ理由で確実に失敗すると分かっているタスク（Issue #1143）。
# 形式は "cli/perspective:cause" の空白区切りで、cause は auth | billing。
# FAILED_TASKS とは別に持つ — これらは「失敗した」のではなく「実行していない」ので、
# 失敗の助言（時間を足す / 原因を読む）をそのまま当てると存在しない実行を指す。
# 到達範囲は execute_tasks と同じプロセス（並列ワーカーはステータス dir 経由で
# 親へ渡す）なので、generate_report と print_failure_advice から読める。
SKIPPED_TASKS=""

# スキップしてよい失敗理由（Issue #1143）。classify_cli_failure_cause の 4 分類の
# うち auth / billing だけを採る。
#   - auth / billing … 資格情報・残高は CLI 単位の状態で、同じ実行内の同一 CLI の
#                      他タスクも確実に同じ理由で落ちる
#   - argv           … 採らない。E2BIG は**そのタスクの argv 長**で決まるため、
#                      観点が違えば起動できる余地がある
#   - prompt-too-long … 採らない。超過量は観点ごとのプロンプト長で決まり、
#                      短い観点なら通る余地がある。全滅した回は下の集約案内が
#                      「diff を見よ」と 1 度だけ言うので、実行を先回りで
#                      止めなくても遠回りは塞がる
#   - ""（判定不能） … 採らない。fail-open で従来どおり全タスクを実行する
# 推測でスキップすると、実際には走ったはずのレビューが観点ごと消える — 誤ってスキップ
# する損失（カバレッジ 0）は、誤って実行する損失（setup 1 回分の待ち時間）より大きい。
cli_failure_is_deterministic() { # <cause> → rc0 = 残りのタスクをスキップしてよい
  case "$1" in
    auth|billing) return 0 ;;
    *) return 1 ;;
  esac
}

# auth / billing で落ちた CLI とその理由（"cli:cause" の空白区切り。Issue #1143）。
# 逐次ブランチ専用 — 並列ブランチのワーカーはサブシェルなのでこの変数を共有できず、
# 判断はワーカー内で閉じる（親へはステータス dir の .skip 印で渡す）。
POISONED_CLIS=""

# <cli> が auth / billing で落ちていれば理由を返す（落ちていなければ空文字）。
skipped_cli_cause() { # <cli> → cause | ""
  local cli="$1" entry
  for entry in $POISONED_CLIS; do
    if [[ "${entry%:*}" == "$cli" ]]; then
      printf '%s\n' "${entry##*:}"
      return 0
    fi
  done
  return 0
}

# <cli/perspective> がスキップされていれば理由を返す（未スキップなら空文字）。
skipped_task_cause() { # <cli/perspective> → cause | ""
  local task="$1" entry
  for entry in $SKIPPED_TASKS; do
    if [[ "${entry%:*}" == "$task" ]]; then
      printf '%s\n' "${entry##*:}"
      return 0
    fi
  done
  return 0
}

# Previous unresolved review state captured before result cleanup (Issue #843).
# It is deliberately small: perspective names and their existing block/nonblock
# classification only. A failed rerun keeps that classification; a successful
# rerun is judged from the new result as usual.
PREVIOUS_UNRESOLVED_BLOCK=""
PREVIOUS_UNRESOLVED_NONBLOCK=""
PRESERVE_PREVIOUS_CRITICAL_REPORT=false

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
RESUME_CACHE_PENDING=""

# 同じ output-dir を使う別 orchestrator との排他。成果物は run-id で分離せず、利用者が
# 従来どおり固定パスから読める契約を保つ代わりに、1 output-dir = 1 active run とする。
OUTPUT_LOCK_DIR=""
OUTPUT_LOCK_HELD=false

# 走行中であることを外部（PreToolUse hook）へ知らせる在庫ファイル。上の
# OUTPUT_LOCK_DIR とは目的が違う — あちらは orchestrator 同士の排他、こちらは
# 「今このツリーを触ると結果が壊れる」を hook が読むための宣言。
REVIEW_IN_FLIGHT_FILE=""

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
# 最終的な base（env / 自動検出 / フォールバック / --base のいずれか）へ鮮度解決を
# **1 回だけ**掛ける。呼び出しは parse_args の末尾 1 箇所だけに保つこと — 解決を
# 複数箇所に置くと選択行が重複し、しかも「実際には使わなかった base」の行が混ざる。
#
# BASE_BRANCH_IDENTITY は解決**前**の名前（origin/ 前置は落とす）。レビュー系列 ID と
# --resume の identity 用で、`--base develop` と `--base origin/develop` と
# 「stale なので origin へ倒した develop」を同じ文脈として扱うためにある。
finalize_base_branch() {
  BASE_BRANCH_IDENTITY="${BASE_BRANCH#origin/}"
  BASE_BRANCH="$(resolve_base_branch_ref "$BASE_BRANCH")"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task)        TASK_TYPE="$2"; shift 2 ;;
      --description) DESCRIPTION="$2"; shift 2 ;;
      --include-diff) INCLUDE_DIFF=true; shift ;;
      --config)      CONFIG_FILE="$2"; CONFIG_SOURCE="--config flag"; CONFIG_PROVENANCE="flag"; shift 2 ;;
      --mode)        MODE="$2"; MODE_EXPLICIT=true; MODE_SOURCE="--mode flag"; shift 2 ;;
      --strategy)    STRATEGY="$2"; STRATEGY_SOURCE="--strategy flag"; shift 2 ;;
      --cli)         CLI_FILTER="${CLI_FILTER:+$CLI_FILTER }$2"; shift 2 ;;
      --exclude-cli)
        # 空文字は「値を渡したつもりで渡せていない」形（`--exclude-cli "$CLI"` で
        # 変数が空、等）。黙って no-op にすると、外したはずの CLI が毎回プランに
        # 載り続ける — この機能が消そうとしている状態そのものになる。シム
        # （templates/codex-review.sh）の同名オプションと同じ文言・同じ rc で拒否する。
        if [[ $# -lt 2 || -z "$2" ]]; then
          echo "ERROR: --exclude-cli には CLI 名が必要です（例: --exclude-cli grok-cli）。" >&2
          exit 2
        fi
        EXCLUDE_CLIS_FLAG="${EXCLUDE_CLIS_FLAG:+$EXCLUDE_CLIS_FLAG }$2"; shift 2 ;;
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
      # 名前をそのまま受ける。鮮度解決は parse_args の最後で最終 base に 1 回だけ
      # 掛ける（finalize_base_branch）。ここで解決すると、init 側の既定 base の解決と
      # 合わせて選択行が 2 行出る。
      --base)        BASE_BRANCH="$2"; BASE_BRANCH_SOURCE="--base flag"; BASE_BRANCH_EXPLICIT=true; shift 2 ;;
      --staged)      STAGED_DIFF=true; shift ;;
      --resume)      RESUME=true; shift ;;
      --fresh)       FRESH=true; shift ;;
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
  if [[ "$FRESH" == "true" && "$RESUME" == "true" ]]; then
    echo "ERROR: --fresh cannot be combined with --resume." >&2
    echo "       --fresh archives previous results; --resume reuses them." >&2
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

  # 引数がすべて確定してから最終 base を 1 回だけ解決する（選択行も 1 行だけ）。
  finalize_base_branch
}

# ── Config Loading (v1/v2 compatible) ──
config_is_explicit() {
  case "$CONFIG_PROVENANCE" in
    env|flag) return 0 ;;
    project|plugin|legacy) return 1 ;;
    *)
      echo "ERROR: invalid config provenance: ${CONFIG_PROVENANCE}" >&2
      exit 2
      ;;
  esac
}

load_config() {
  # Fall back to review-config.yaml if agent-config.yaml doesn't exist
  if [[ ! -f "$CONFIG_FILE" ]]; then
    # An explicitly requested config that is missing must fail loud — silently
    # substituting defaults would run with settings the user did not choose.
    if config_is_explicit; then
      echo "ERROR: config file not found: $CONFIG_FILE (from ${CONFIG_SOURCE})" >&2
      exit 1
    fi
    local fallback_config="${SCRIPT_DIR}/review-config.yaml"
    if [[ -f "$fallback_config" ]]; then
      echo "ℹ️  Using legacy config: $fallback_config" >&2
      CONFIG_FILE="$fallback_config"
      CONFIG_SOURCE="legacy review-config.yaml"
      CONFIG_PROVENANCE="legacy"
    else
      echo "⚠️  Config file not found: $CONFIG_FILE (using defaults)" >&2
      return 0
    fi
  fi

  if command -v yq &>/dev/null; then
    local config_parse_error=""
    if ! config_parse_error="$(yq '.' "$CONFIG_FILE" 2>&1)"; then
      if config_is_explicit; then
        echo "ERROR: explicit config could not be parsed by yq: $CONFIG_FILE (from ${CONFIG_SOURCE})" >&2
        printf 'yq: %s\n' "$config_parse_error" >&2
        exit 1
      fi
      echo "⚠️  Config file could not be parsed by yq. Using defaults." >&2
      printf 'yq: %s\n' "$config_parse_error" >&2
      return 0
    fi

    local cfg_val
    cfg_val=$(yq -r '.mode // ""' "$CONFIG_FILE" 2>/dev/null || true)
    if [[ -n "$cfg_val" ]]; then
      MODE="$cfg_val"
      MODE_SOURCE="config mode (${CONFIG_SOURCE})"
    fi

    cfg_val=$(yq -r '.parallel // ""' "$CONFIG_FILE" 2>/dev/null || true)
    [[ "$cfg_val" == "true" ]] && PARALLEL=true
    [[ "$cfg_val" == "false" ]] && PARALLEL=false

    # 環境ごとの既定除外（例: この機械では grok が起動できない）。version に依らず
    # トップレベルで読む — 除外の理由は「その機械の環境」であってタスク種別ではない。
    # 書式は review.critical_nonblock_perspectives と同じ **1 文字列**（空白または
    # カンマ区切り）。YAML リストで書くと yq -r が複数行を返し、名前が CLI 名に
    # 一致しなくなるので、黙って無視せず警告して読み飛ばす。
    cfg_val=$(yq -r '.exclude_clis // ""' "$CONFIG_FILE" 2>/dev/null || true)
    if [[ "$cfg_val" == *$'\n'* || "$cfg_val" == -* ]]; then
      echo "⚠️  exclude_clis は YAML リストではなく 1 文字列（空白またはカンマ区切り）で指定してください。読み飛ばします" >&2
    elif [[ -n "$cfg_val" && "$cfg_val" != "null" ]]; then
      cfg_val="${cfg_val//,/ }"
      cfg_val="${cfg_val//$'\t'/ }"
      # 連続空白と前後空白を潰す。表示にそのまま出る値なので "a,  b" が
      # "a  b" のまま出ると設定の書き方の差が出力の差に見える。
      # shellcheck disable=SC2086 # 意図的な単語分割による正規化
      cfg_val="$(echo $cfg_val)"
      EXCLUDE_CLIS_CONFIG="$cfg_val"
      EXCLUDE_CLIS_CONFIG_SOURCE="$CONFIG_SOURCE"
    fi

    # v2: task-specific config
    local version
    version=$(yq -r '.version // "1.0"' "$CONFIG_FILE" 2>/dev/null || true)

    if [[ "$version" == "2.0" ]]; then
      # Read task-specific settings
      # mode をタスク単位で読む。グローバルの mode: は全タスク共通の既定で、
      # review だけ pair にしたいといった指定ができなかった（v2.0 で cost_strategy /
      # timeout / output_dir がタスク単位なのと同じ扱いへ揃える）。
      cfg_val=$(yq -r ".tasks.${TASK_TYPE}.mode // \"\"" "$CONFIG_FILE" 2>/dev/null || true)
      if [[ -n "$cfg_val" ]]; then
        MODE="$cfg_val"
        MODE_SOURCE="config tasks.${TASK_TYPE}.mode (${CONFIG_SOURCE})"
      fi

      cfg_val=$(yq -r ".tasks.${TASK_TYPE}.cost_strategy // \"\"" "$CONFIG_FILE" 2>/dev/null || true)
      if [[ -n "$cfg_val" && -z "$STRATEGY" ]]; then
        STRATEGY="$cfg_val"
        STRATEGY_SOURCE="config tasks.${TASK_TYPE}.cost_strategy (${CONFIG_SOURCE})"
      fi

      cfg_val=$(yq -r ".tasks.${TASK_TYPE}.timeout // \"\"" "$CONFIG_FILE" 2>/dev/null || true)
      [[ -n "$cfg_val" && -z "$TIMEOUT" ]] && TIMEOUT="$cfg_val"

      cfg_val=$(yq -r ".tasks.${TASK_TYPE}.output_dir // \"\"" "$CONFIG_FILE" 2>/dev/null || true)
      [[ -n "$cfg_val" && -z "$OUTPUT_DIR" ]] && OUTPUT_DIR="${REPO_ROOT}/${cfg_val}"
    else
      # v1 compatibility
      cfg_val=$(yq -r '.cost_strategy // ""' "$CONFIG_FILE" 2>/dev/null || true)
      if [[ -n "$cfg_val" && -z "$STRATEGY" ]]; then
        STRATEGY="$cfg_val"
        STRATEGY_SOURCE="config cost_strategy (${CONFIG_SOURCE})"
      fi

      cfg_val=$(yq -r '.timeout // ""' "$CONFIG_FILE" 2>/dev/null || true)
      [[ -n "$cfg_val" && -z "$TIMEOUT" ]] && TIMEOUT="$cfg_val"

      cfg_val=$(yq -r '.output_dir // ""' "$CONFIG_FILE" 2>/dev/null || true)
      [[ -n "$cfg_val" && -z "$OUTPUT_DIR" ]] && OUTPUT_DIR="${REPO_ROOT}/${cfg_val}"
    fi
  else
    if config_is_explicit; then
      echo "ERROR: yq is required to read explicit config: $CONFIG_FILE (from ${CONFIG_SOURCE})" >&2
      exit 1
    fi
    echo "ℹ️  yq not found — using defaults. Install yq for config file support." >&2
  fi
  return 0  # last &&-list may legitimately be false — don't let set -e kill the script
}

# ── Apply task-type defaults (after config + CLI args) ──
# mode の whitelist 検証（Issue #699）。未知の値は build_execution_plan の else 経路で
# distributed として走り、プランヘッダは誤値をそのまま表示する — `--mode distribuited`
# や設定ファイルの古い `mode: cross_model` が「指定どおり動いた」ように見える。さらに
# #597 で入った受理ゲートは MODE 文字列に依存するので、誤設定ほど安全網が外れる。
# STRATEGY の whitelist（Issue #691）と同じく CLI・config の両経路がここを通る。
# apply_task_defaults と --list-perspectives の早期 exit の両方から呼ぶため関数にする
# （片方だけに置くと、一覧経路で綴り間違いが rc=0 の「確認」になる）。
validate_mode() {
  # 既定解決前に呼ばれる経路（--list-perspectives）では空でありうる。空は「未指定」で、
  # apply_task_defaults が task 既定を入れるので、ここでは拒否しない。
  [[ -n "$MODE" ]] || return 0
  case "$MODE" in
    pair|distributed|cross-model) return 0 ;;
    *)
      echo "ERROR: unknown mode '${MODE}' (from ${MODE_SOURCE})." >&2
      echo "       Valid values: pair, distributed, cross-model." >&2
      exit 1 ;;
  esac
}

apply_task_defaults() {
  # review だけ pair（主+副）を既定にする。explore / implement は従来の分散のまま。
  # 既存の分散モードは --mode distributed で引き続き使える。
  if [[ -z "$MODE" ]]; then
    if [[ "$TASK_TYPE" == "review" ]]; then MODE="pair"; else MODE="distributed"; fi
    MODE_SOURCE="task default"
  fi
  validate_mode
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
  if [[ -z "$STRATEGY" ]]; then
    STRATEGY="$(get_default_strategy "$TASK_TYPE")"
    STRATEGY_SOURCE="task default"
  fi
  # strategy の whitelist 検証（Issue #691）。未知の値を黙って受けると、どの分岐にも
  # 一致せず balanced と同じ「何もしない」実行に落ちる — minimize_cost の typo
  # （minimize_costs / minimise_cost 等）は振替も pair の非適用通知も出ない完全な
  # 無音になり、この通知が守ろうとする利用者がまさに踏む穴になる。CLI・config の
  # 両経路がここを通るので、dry-run でも実行でも同じく非 0 で拒否する。
  case "$STRATEGY" in
    balanced|minimize_cost|maximize_quality) ;;
    *)
      echo "ERROR: unknown strategy '${STRATEGY}' (from ${STRATEGY_SOURCE})." >&2
      echo "       Valid values: balanced, minimize_cost, maximize_quality." >&2
      exit 1 ;;
  esac
  return 0  # last &&-list may legitimately be false — don't let set -e kill the script
}

# ── CLI Detection ──
# 検出は「PATH に在るか」だけを見る。認証・残高の状態はここでは probe しない —
# 4 CLI の実提供機能を実測したうえでの判断で、根拠と代わりに何をしているかは
# classify_cli_failure_cause のヘッダーに書いてある（Issue #659）。
detect_available_clis() {
  AVAILABLE_CLIS=""
  local cli_name cmd exclusion
  # 除外を掛ける**前**の導入済み本数。空プランの診断で「1 本も入っていない」と
  # 「入っているが全部外した」を分けるのに要る（除外指定の有無だけで分けると、
  # CLI が 1 つも入っていない環境で除外を書いただけの回に install 案内が消える）。
  local installed_before_exclusion=0

  for cli_name in $ALL_CLIS; do
    cmd="$(get_cli_command "$cli_name")"
    local cli_installed=false
    if command -v "$cmd" &>/dev/null; then
      cli_installed=true
      installed_before_exclusion=$((installed_before_exclusion + 1))
    fi
    # 除外は**検出の段**で効かせる。プラン構築側（distributed / cross-model / pair）
    # それぞれに除外条件を配ると、片方だけ直された形でドリフトする。ここで
    # AVAILABLE_CLIS から落とせば、未インストール CLI と同じ 1 本の経路
    # （観点の fallback 再配分・pair の主不在エラー・空プラン検査）をそのまま通る。
    # sandbox probe（warn_unappliable_sandbox）は「起動できないと分かっていても
    # プランからは外さない」側の機構で、こちらはその判断を利用者が明示したときの
    # 受け皿になる。
    exclusion="$(cli_exclusion_source "$cli_name")"
    case "$exclusion" in
      flag)
        echo "  ⏭  ${cli_name} excluded (--exclude-cli). Its perspectives follow the not-installed fallback path." >&2
        continue ;;
      config)
        echo "  ⏭  ${cli_name} excluded (config exclude_clis — ${EXCLUDE_CLIS_CONFIG_SOURCE}). Opt back in for one run with --cli ${cli_name}." >&2
        continue ;;
      config-overridden)
        echo "  ℹ️  ${cli_name} is in config exclude_clis (${EXCLUDE_CLIS_CONFIG_SOURCE}) but --cli named it — running it this time." >&2
        ;;
    esac
    if [[ "$cli_installed" == "true" ]]; then
      AVAILABLE_CLIS="${AVAILABLE_CLIS:+$AVAILABLE_CLIS }$cli_name"
      echo "  ✅ ${cli_name} (${cmd})" >&2
    else
      echo "  ❌ ${cli_name} (${cmd}) — not installed" >&2
    fi
  done

  if [[ -z "$AVAILABLE_CLIS" ]]; then
    # 「1 本も入っていない」と「入っているが全部外した」は利用者の次の一手が違う。
    # 除外で空になった回に install を案内しても指し先が誤っている。逆に、除外を
    # 書いただけで**元から 1 本も入っていない**回に「全部外した」と言うと、唯一
    # 打てる手（install）を隠す。判定は指定の有無ではなく実測した導入本数で行う。
    if [[ "$installed_before_exclusion" -gt 0 ]] \
      && [[ -n "$EXCLUDE_CLIS_FLAG" || -n "$EXCLUDE_CLIS_CONFIG" ]]; then
      echo "" >&2
      echo "ERROR: every installed CLI was excluded — nothing would run." >&2
      [[ -n "$EXCLUDE_CLIS_FLAG" ]] && echo "       --exclude-cli: ${EXCLUDE_CLIS_FLAG}" >&2
      [[ -n "$EXCLUDE_CLIS_CONFIG" ]] && echo "       config exclude_clis (${EXCLUDE_CLIS_CONFIG_SOURCE}): ${EXCLUDE_CLIS_CONFIG}" >&2
      exit 1
    fi
    echo "" >&2
    echo "ERROR: No AI CLIs are installed. Install at least one:" >&2
    echo "  npm install -g @anthropic-ai/claude-code" >&2
    echo "  npm install -g @openai/codex" >&2
    echo "  npm install -g @xai-official/grok" >&2
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
        # 「入っていない」と「入っているが外した」は別の事実。除外で AVAILABLE_CLIS
        # から落ちた CLI にも not installed と書くと、install 済みの機械で偽の診断に
        # なる（利用者は入れ直そうとして、原因である除外へ辿り着けない）。
        local absent_reason
        case "$(cli_exclusion_source "$cli_name")" in
          flag)   absent_reason="${cli_name} excluded by --exclude-cli" ;;
          config) absent_reason="${cli_name} excluded by config exclude_clis (${EXCLUDE_CLIS_CONFIG_SOURCE})" ;;
          *)      absent_reason="${cli_name} not installed" ;;
        esac
        if [[ "$fallback_target" == "$(get_cli_fallback "$cli_name")" ]]; then
          echo "  ↪ ${cli_name} → ${fallback_target} (fallback — ${absent_reason})" >&2
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

  # Apply cost strategy: minimize_cost moves premium → the cheapest remaining
  # tier. The substitute was cursor-cli until issue #240, then gemini-cli
  # [free-tier] until issue #783 removed it; grok-cli [flat-rate] now takes the
  # role (no marginal cost per task — the closest analogue to the free tier).
  # There is no tier ordering in the code (KNOWN_TIERS is an unordered set), so
  # this is a named choice, not a computed one — which is deliberate: naming the
  # substitute keeps the swap readable in the plan output, and the user sees
  # which model actually ran.
  #
  # The sequential-worker mitigation (issue #251) in execute_tasks is tier-keyed
  # and follows the substitute: it now serializes flat-rate CLI groups.
  if [[ "$STRATEGY" == "minimize_cost" && -z "$CLI_FILTER" ]]; then
    local new_plan=""
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      local cli="${entry%%:*}"
      local persp="${entry#*:}"
      if [[ "$cli" == "claude-code" ]] && list_contains "$AVAILABLE_CLIS" "grok-cli"; then
        echo "  💰 minimize_cost: ${persp}: claude-code → grok-cli" >&2
        new_plan="${new_plan:+$new_plan
}grok-cli:${persp}"
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
  PAIR_REVIEWERS_NOTE=""
  local p sub_effective=""

  if ! list_contains "$AVAILABLE_CLIS" "$REVIEW_MAIN"; then
    # 主が居ない理由は「未導入」と「除外した」の 2 つあり、次の一手が違う。
    # 除外した回に「Install it」と言うと、install 済みの機械で偽の診断になる。
    # pair モードでは --cli による一回限りの復帰が使えない（--mode pair の明示と
    # 併用すれば非 0、暗黙なら distributed へ落ちてそもそも pair ではなくなる）ので、
    # 解除は「除外を外す」か「別の主を選ぶ」の 2 つだけだと名乗る。
    case "$(cli_exclusion_source "$REVIEW_MAIN")" in
      flag)
        echo "ERROR: main reviewer '${REVIEW_MAIN}' was excluded by --exclude-cli." >&2
        echo "       Drop '${REVIEW_MAIN}' from --exclude-cli, or pick another main with" >&2
        echo "       --set-reviewers main=<cli> / MULTI_AGENT_REVIEW_MAIN=<cli>." >&2
        echo "       (--cli does not opt it back in here: it is a distributed-mode filter" >&2
        echo "        and cannot be combined with --mode pair.)" >&2 ;;
      config)
        echo "ERROR: main reviewer '${REVIEW_MAIN}' was excluded by config exclude_clis (${EXCLUDE_CLIS_CONFIG_SOURCE})." >&2
        echo "       Remove '${REVIEW_MAIN}' from exclude_clis, or pick another main with" >&2
        echo "       --set-reviewers main=<cli> / MULTI_AGENT_REVIEW_MAIN=<cli>." >&2
        echo "       (--cli does not opt it back in here: it is a distributed-mode filter" >&2
        echo "        and cannot be combined with --mode pair.)" >&2 ;;
      *)
        echo "ERROR: main reviewer '${REVIEW_MAIN}' is not installed." >&2
        echo "       Install it, or pick another with --set-reviewers." >&2 ;;
    esac
    return 1
  fi

  # --strategy minimize_cost は分散プランの振替（premium 観点 → 最安 tier の CLI、
  # build_distributed_plan 末尾）で、pair には対応する概念が無い（Issue #691）。
  # 従来はここで黙って何も起きなかった（効かないつまみ）。#255 の --cli は
  # 「分散モード用のフィルタ」だから分散へ落とすことで指定の意図を守れたが、
  # minimize_cost を同じ形で分散へ落とすと、コストのつまみ一つで設定済みの
  # 主・副（= 誰がレビューしたか）ごと入れ替わる。主を振替先へ差し替える案も
  # 同じ理由で採らない（振替先が副と同一 CLI ならクロスモデル性も消える）。
  # pair のコストは主・副の選定そのもので決まるので、「ここでは効かない」を
  # 名乗り、効かせる場所（--set-reviewers / --mode distributed）を指す。
  # balanced / maximize_quality はプランを変えない既定ラベルなので黙る
  # （毎回の常時表示は雑音で、既定実行の出力を変えない、という契約も守る）。
  if [[ "$STRATEGY" == "minimize_cost" ]]; then
    echo "  ℹ️  cost strategy 'minimize_cost' (from ${STRATEGY_SOURCE}) does not apply in pair mode — reviewers are the configured main/sub pair, not tier-substituted." >&2
    echo "     To lower cost: pick cheaper reviewers (--set-reviewers main=NAME,sub=NAME) or use --mode distributed, where minimize_cost applies." >&2
  fi

  # 副の縮退判定。どれも「主のみで続行」で、理由だけを変えて伝える。
  # 縮退した事実は stderr だけでなく統合レポートにも残す（Issue #699）。stderr は
  # 実行を見ていた人しか読まないが、レポートは後から読まれる — `Mode: pair` だけが
  # 残っていると、単一 CLI で走ったものをクロスモデル済みと誤読する。
  if [[ -z "$REVIEW_SUB" ]]; then
    echo "  ℹ️  No sub reviewer set — running single-reviewer. Set one for cross-model coverage." >&2
    PAIR_REVIEWERS_NOTE="${REVIEW_MAIN} (single — no sub reviewer set)"
  elif [[ "$REVIEW_SUB" == "$REVIEW_MAIN" ]]; then
    echo "  ⏭  sub reviewer is the same CLI as main (${REVIEW_MAIN}) — skipping the duplicate." >&2
    PAIR_REVIEWERS_NOTE="${REVIEW_MAIN} (single — sub '${REVIEW_SUB}' is the same CLI as main)"
  elif cli_excluded "$REVIEW_SUB"; then
    # 除外は未導入と別の事実。ここを not-installed の枝へ落とすと、install 済みの
    # 機械に「not installed」と記録され（レポートへも残る）、しかも
    # PAIR_SUB_DROPPED が立たないので単一 CLI 縮退の警告まで消える。
    # 除外はクロスモデルにできたのに単一へ落ちた経路なので、--perspective で副が
    # 落ちた場合と同じくフラグを立てる（--exclude-perspective の「その観点を走らせ
    # るな」とは違い、外したのは CLI であって総合観点の要否ではない）。
    local sub_excl_desc
    if [[ "$(cli_exclusion_source "$REVIEW_SUB")" == "flag" ]]; then
      sub_excl_desc="--exclude-cli"
    else
      sub_excl_desc="config exclude_clis (${EXCLUDE_CLIS_CONFIG_SOURCE})"
    fi
    PAIR_SUB_DROPPED=true
    echo "  ⚠️  sub reviewer '${REVIEW_SUB}' excluded by ${sub_excl_desc} — running single-reviewer." >&2
    PAIR_REVIEWERS_NOTE="${REVIEW_MAIN} (single — sub '${REVIEW_SUB}' excluded by ${sub_excl_desc})"
  elif ! list_contains "$AVAILABLE_CLIS" "$REVIEW_SUB"; then
    echo "  ⚠️  sub reviewer '${REVIEW_SUB}' is not installed — running single-reviewer." >&2
    PAIR_REVIEWERS_NOTE="${REVIEW_MAIN} (single — sub '${REVIEW_SUB}' not installed)"
  else
    sub_effective="$REVIEW_SUB"
    PAIR_REVIEWERS_NOTE="${REVIEW_MAIN} + ${sub_effective}"
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
        # 副が居ない既定構成（--perspective 無指定）では、総合観点は誰にも割り当て
        # られないままプランが 1 件少なくなる。既定で主へ回さないのは、主が既に
        # 全観点を担当していて同一モデルの二重レビューになるため（pair の設計意図は
        # 別モデルによる総合観点）。ただし「走らない」ことは名乗る — 出力に何も
        # 出ないと、プランの件数が 1 少ない理由が実行ログから復元できない（Issue #699）。
        if [[ -z "$sub_effective" && -z "$PERSPECTIVE_FILTER" ]] \
          && ! perspective_excluded "$COMPREHENSIVE_PERSPECTIVE"; then
          echo "  ⏭  ${COMPREHENSIVE_PERSPECTIVE} — no reviewer; not covered in this run." >&2
        fi
        continue
      fi
      # 除外判定は宣言より前に行う。逆順だと「主に回した」と宣言した直後に捨てる
      # 矛盾出力になる（--perspective X --exclude-perspective X・副なしで再現。Issue #699）。
      perspective_excluded "$p" && continue
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

  # Reviewers 行は**組んだプラン**から導出する（Issue #699）。副の導入可否だけで
  # 決めると、--perspective / --exclude-perspective で副が計画から落ちた回に
  # 「main + sub」と記録され、単一 CLI で走ったものをクロスモデル済みと誤読させる
  # — レポートへ事実を残すという当の目的を裏切る。上の 4 分岐が入れた縮退理由は、
  # プランが実際に単一 CLI のときだけ活かす。
  local planned_clis
  planned_clis="$(printf '%s\n' "$EXECUTION_PLAN" | awk -F: 'NF { print $1 }' | sort -u | tr '\n' ' ')"
  planned_clis="${planned_clis% }"
  case "$planned_clis" in
    "") PAIR_REVIEWERS_NOTE="" ;;                      # 空プラン。後段の gate が止める
    *" "*) PAIR_REVIEWERS_NOTE="${planned_clis// / + }" ;;  # 実際に 2 CLI 以上
    *)
      # 単一 CLI。縮退理由が既にあるならそれを使い、無ければプラン側の事実だけ書く
      # （--perspective で副だけが残った回など、縮退ではなく指定どおりのケース）。
      if [[ "$PAIR_REVIEWERS_NOTE" == "${planned_clis} ("* ]]; then
        : # 4 分岐が入れた理由つきの記録をそのまま使う
      else
        PAIR_REVIEWERS_NOTE="${planned_clis} (single — only this CLI is in the plan)"
      fi ;;
  esac
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

# ── Excluded CLIs ──
# 除外の出所を返す。引数と設定の両方に載っている CLI は引数側を名乗る — 利用者が
# その実行で明示した意図が上位だから。
#   flag              --exclude-cli による除外
#   config            設定ファイルの exclude_clis による除外
#   config-overridden 設定は外しているが、その実行で --cli が明示的に選んだ
#                     （環境の既定より、その 1 回の明示指定を上に置く。設定を書き換え
#                      なくても「今日は動くか試す」ができる形にしておく）
#   空文字列          除外されていない
cli_exclusion_source() {
  if [[ -n "$EXCLUDE_CLIS_FLAG" ]] && list_contains "$EXCLUDE_CLIS_FLAG" "$1"; then
    echo "flag"
  elif [[ -n "$EXCLUDE_CLIS_CONFIG" ]] && list_contains "$EXCLUDE_CLIS_CONFIG" "$1"; then
    if [[ -n "$CLI_FILTER" ]] && list_contains "$CLI_FILTER" "$1"; then
      echo "config-overridden"
    else
      echo "config"
    fi
  else
    echo ""
  fi
}

cli_excluded() {
  local origin
  origin="$(cli_exclusion_source "$1")"
  [[ "$origin" == "flag" || "$origin" == "config" ]]
}

# 存在しない CLI 名の除外を黙って受けると、typo が「外したつもり」で素通りし、
# 起動できないと分かっている CLI が毎回プランに載り続ける（この機能が消そうとして
# いる状態そのもの）。--cli と同じく、プランを組む前に名指しで拒否する。設定由来の
# 名前も同じ扱い — 設定側だけ緩めると、typo が一度書かれたきり誰にも気づかれない。
#
# --cli X と --exclude-cli X の同時指定も拒否する。片方を優先する規則を置くと、
# 「選んだのに走らない」か「外したのに走る」のどちらかが黙って起きる。
#
# 未知名の扱いは出所で分ける（PR #1410 レビュー項目 12）。
#   引数由来: 非 0 で拒否。その 1 回のためにいま打った指定なので、typo は即座に
#             直せるし、直さないと「外したつもり」の CLI が走る。
#   設定由来: WARNING を出して**その名前だけ**落とし、実行は続ける。設定は複数の
#             機械・複数のリポジトリで共有され、CLI が retire されると（cursor-cli /
#             gemini-cli の前例がある）過去に妥当だった設定が全実行を落とす。
#             「レビューが 1 本も走らない」は「除外が 1 つ効かない」より重い故障で、
#             しかも設定を書いた人と踏む人が違いうる。名前は警告で名指しするので
#             黙って消えることはない。
# 不正トークン（is_safe_token 不一致）は出所に依らず非 0 のまま — こちらは typo で
# はなく注入の形で、警告して読み飛ばす対象ではない。
validate_excluded_clis() {
  local cli_name
  for cli_name in $EXCLUDE_CLIS_FLAG $EXCLUDE_CLIS_CONFIG; do
    if ! is_safe_token "$cli_name"; then
      echo "ERROR: unsafe CLI name in exclusion: '${cli_name}'" >&2
      return 1
    fi
  done
  for cli_name in $EXCLUDE_CLIS_FLAG; do
    if ! list_contains "$ALL_CLIS" "$cli_name"; then
      echo "ERROR: unknown CLI in --exclude-cli: '${cli_name}'" >&2
      echo "       Known CLIs: ${ALL_CLIS}" >&2
      return 1
    fi
  done
  local kept_config=""
  for cli_name in $EXCLUDE_CLIS_CONFIG; do
    if ! list_contains "$ALL_CLIS" "$cli_name"; then
      echo "⚠️  unknown CLI in config exclude_clis (${EXCLUDE_CLIS_CONFIG_SOURCE}): '${cli_name}' — ignoring it." >&2
      echo "    Known CLIs: ${ALL_CLIS}. Remove the stale name from the config." >&2
      continue
    fi
    kept_config="${kept_config:+$kept_config }$cli_name"
  done
  EXCLUDE_CLIS_CONFIG="$kept_config"
  [[ -z "$EXCLUDE_CLIS_CONFIG" ]] && EXCLUDE_CLIS_CONFIG_SOURCE=""
  for cli_name in $CLI_FILTER; do
    if [[ -n "$EXCLUDE_CLIS_FLAG" ]] && list_contains "$EXCLUDE_CLIS_FLAG" "$cli_name"; then
      echo "ERROR: --cli and --exclude-cli both name '${cli_name}'." >&2
      echo "       Drop one: --cli selects what runs, --exclude-cli removes it." >&2
      return 1
    fi
  done
  return 0
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
# --base（または env / 自動検出）が**ローカル** branch を指し、それが origin より
# 後退している場合に、プラン構築前へ警告を 1 行群で出す（Issue #759）。
#
# 背景（消費側 ACE-209-1 の実測）: ブランチは origin/develop から切ったのに
# --base develop はローカル develop（2 コミット古い）を指し、レビュー diff に他人の
# マージ済みコミット 7 ファイルが混入 — Critical 指摘 2 件が全部「自分の差分に無い
# ファイル」の話になった。逆にローカル base が新しい（rebase 済み等）と自分の差分の
# 一部がレビューされない偽陰性にもなる。
#
# 設計:
#   - **中断ではなく警告**。意図的にローカル base を使う運用（オフライン・ローカル
#     統合ブランチ等）を壊さない
#   - **fail-open**: origin/<branch> が無い・rev-list が失敗・数値が取れない場合は
#     黙って従来どおり。判定できないことを警告にすると常時ノイズになる
#   - **--staged は対象外**（base を使わない）。`origin/...` 形式や SHA 指定も対象外
#     （refs/heads に解決されない = ローカル branch を指していない）
#   - **ローカルが進んでいる（ahead）だけの場合も対象外**。未 push のローカル
#     コミットを base にするのは「ローカルで積んだ統合ブランチ」という別の意図的
#     運用で、警告すると常設ノイズになる。混入事故の向き（behind）だけを見る
#   - 判定は behind の**数ではなく merge-base の比較**で行う。diff は三点比較
#     （BASE...HEAD = merge-base(BASE, HEAD) から HEAD）なので、ブランチを**古い
#     ローカル base から**切った場合は、ローカルがいくら behind でも diff は
#     origin 比較と同一で混入は起きない — behind>0 を述語にすると、この最も普通の
#     「pull していないだけ」の形で毎回誤警告する（セルフレビューで実測反証）。
#     混入が起きるのは merge-base(local, HEAD) と merge-base(origin, HEAD) が
#     食い違うときで、その差分コミット数がまさに混入する件数になる
#
# 現在は base 解決（resolve_base_branch_ref）が「ローカルが origin の真の祖先」の場合に
# origin/<base> を採るため、その形はここへ到達する前に origin/* へ倒れて早期 return する。
# ここに残る実効ケースは**分岐**（双方に固有コミット）で、解決側が保守的にローカルを
# 維持する形。混入は起こりうるが自動で差し替えると未 push のコミットが差分から落ちるため、
# 警告に留めるという役割分担にしてある。
warn_if_stale_local_base() {
  [[ "$STAGED_DIFF" == "true" ]] && return 0
  [[ "$IN_GIT_REPO" == "true" ]] || return 0
  local base="$BASE_BRANCH" mb_local mb_origin leaked base_q origin_q
  # origin/ 前置は「remote 側を明示した」意図なので、たとえローカルに同名 branch
  # （refs/heads/origin/develop）が併存していても対象外にする（Codex レビュー指摘）
  case "$base" in origin/*) return 0 ;; esac
  # 裸名だと同名 tag が branch より先に解決されて比較がずれるため、完全修飾で固定する
  git rev-parse --verify --quiet "refs/heads/${base}" >/dev/null 2>&1 || return 0
  git rev-parse --verify --quiet "refs/remotes/origin/${base}" >/dev/null 2>&1 || return 0
  mb_local="$(git merge-base "refs/heads/${base}" HEAD 2>/dev/null)" || return 0
  mb_origin="$(git merge-base "refs/remotes/origin/${base}" HEAD 2>/dev/null)" || return 0
  [[ -n "$mb_local" && -n "$mb_origin" ]] || return 0
  [[ "$mb_local" == "$mb_origin" ]] && return 0
  leaked="$(git rev-list --count "${mb_local}..${mb_origin}" 2>/dev/null)" || return 0
  [[ "$leaked" =~ ^[0-9]+$ ]] || return 0
  if [[ "$leaked" -gt 0 ]]; then
    # 貼り付け実行される案内コマンドに branch 名を素で埋めない（; や $( ) を含む
    # branch 名は git 的に合法で、shell_quote ならシェル安全な引用になる。通常名は素のまま）
    base_q="$(shell_quote "$base")"
    origin_q="$(shell_quote "origin/${base}")"
    echo "" >&2
    echo "⚠️  base '${base}' はローカル ref で、このブランチの分岐点（origin/${base} 基準）より古い状態です。" >&2
    echo "    他ブランチのマージ済みコミット ${leaked} 件が diff に混入します。" >&2
    echo "    最新化（git fetch && git switch ${base_q} && git pull --ff-only）または" >&2
    echo "    --base ${origin_q} を検討してください。" >&2
  fi
  return 0
}

# ── Sandbox applicability warning（プラン時 probe） ──
#
# 潰す事故: **プランには載るのに一度も走らない CLI**。grok はサンドボックスを
# 適用できない環境でモデルを呼ぶ前に起動を拒否する（観測台帳の実測: macOS で
# /var/run/docker.sock が symlink の環境。runtime-socket の deny path を解決できず
# status 1）。実行時の検出（アダプタの refuse → 結果 INCOMPLETE）は既にあるが、
# それが分かるのはタスクを丸ごと失ったあとで、dry-run は毎回「載る」としか言わない。
# 「3 本のクロスモデル」のつもりが常に 2 本で走る、という形が見えないまま続く。
#
# 認証・残高を probe しないという方針（detect_available_clis のヘッダー、および
# classify_cli_failure_cause の「なぜ preflight probe を採らなかったか」）は
# **そのまま維持する**。あちらを退けた理由は「残高・認証は課金される API 呼び出しを
# しないと分からない」で、ここで見るのは性質が違う:
#   - 環境固有（このマシンでは毎回失敗する）
#   - 決定的（同じ環境なら同じ答え）
#   - モデルを呼ぶ前に確定する（= 課金されない手段で観測できる）
# probe の実体はアダプタ側（grok-cli-adapter.sh の run_sandbox_probe）にあり、
# 課金されないことの実測根拠もそこに書いてある。
#
# プランからは**外さない**。実行時の失敗を別モデルへ振り替えない方針（Runtime
# fallback: none）と同じ理由で、走らせる対象を勝手に間引くと「頼んだ CLI が黙って
# 消えた」形になる。表示を足すだけにして、外す判断は利用者へ残す。
#
# fail-open: probe が拒否を確定できなかった場合（probe 自体が失敗した・アダプタが
# 無い・CLI が別の理由で非 0）は何も出さない。「この環境では動く」と断定はしない
# ので、警告が出ないことは成功の保証ではない。
readonly SANDBOX_PROBE_REFUSED_STATUS=3

# 表示位置は**その CLI の項目の直下**（プラン一覧の後ろへまとめない）。CLI が 3 つ
# 並ぶプランで末尾にまとめると、どの行の話かを読み手が数え直すことになる。呼び出し側
# （show_plan のループ）は 1 CLI 分を出し終えた時点でこれを呼ぶ。
warn_unappliable_sandbox() {
  # dry-run のときだけ probe する。実行時は数秒後に本物の dispatch が同じことを
  # 確かめるので、そこへ CLI プロセスをもう 1 つ足す価値が無い（起動回数を数えている
  # 検査もある）。本スキルの手順は dry-run でプランを確認してから実行する形なので、
  # 「起動前に分かる」という目的はこちらだけで満たせる。
  [[ "$DRY_RUN" == "true" ]] || return 0
  local cli="$1" adapter probe_out probe_rc kind reason
  cli_sandbox_probe_supported "$cli" || return 0
  adapter="$(get_cli_adapter "$cli")"
  [[ -n "$adapter" && -f "$adapter" ]] || return 0
  probe_rc=0
  probe_out="$(bash "$adapter" --probe-sandbox "$TASK_TYPE" 2>/dev/null)" || probe_rc=$?
  [[ "$probe_rc" -eq "$SANDBOX_PROBE_REFUSED_STATUS" ]] || return 0
  # アダプタの出力契約: 1 行目 = 種別、2 行目 = CLI 自身が出した理由。
  kind="$(printf '%s\n' "$probe_out" | sed -n '1p')"
  reason="$(printf '%s\n' "$probe_out" | sed -n '2p')"
  echo "     ⚠️  ${cli}: この環境では sandbox を適用できません（起動前に判明）。" >&2
  if [[ -n "$reason" ]]; then
    echo "         ${reason}" >&2
  fi
  # 帰結は種別で分ける。「起動を拒否する」と「sandbox 無しで起動する」は、利用者が
  # 見るログの形も、疑うべき箇所も違う（後者は CLI が正常終了したように見える）。
  if [[ "$kind" == "unsandboxed-start" ]]; then
    echo "         CLI は sandbox 無しで起動するため、このアダプタが要求した保護が" >&2
    echo "         効かないまま走ります。実行時のゲートがその結果を採用しないので、" >&2
    echo "         プランには載っていても成果は得られず、INCOMPLETE として報告されます。" >&2
  else
    echo "         プランには載りますが CLI が起動を拒否するため未実行になり、" >&2
    echo "         結果は INCOMPLETE として報告されます。" >&2
  fi
  echo "         プランからは外しません（実行時の失敗を別モデルへ振り替えない方針のため）。" >&2
  echo "         この実行から外すなら、走らせたい CLI を --cli で明示してください。" >&2
  echo "         検査対象は sandbox の適用可否だけです（認証・残高は probe しません）。" >&2
  return 0
}

show_plan() {
  local effort_cli
  while IFS= read -r effort_cli; do
    [[ -n "$effort_cli" ]] || continue
    validate_effort_env "$effort_cli" || return 1
  done < <(printf '%s\n' "$EXECUTION_PLAN" | cut -d: -f1 | sort -u)
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
  # 除外はプラン本体にも 1 行出す。検出ブロックの ⏭ 行は CLI 検出の文脈にあり、
  # あとから成果物と一緒に読み返されるのはこちらのヘッダー（Mode / Strategy と
  # 同じ段）。出所（引数由来 / 設定由来）まで書かないと「設定に書いた覚えのない
  # CLI が消えている」を追えない。
  # 名簿の生値ではなく**実際に効いた除外**を出す。--cli が設定の除外を上書きした
  # CLI を「除外した」と書くと、走った CLI が除外済みに見える（実測でそうなった）。
  local excl_cli excl_by_flag="" excl_by_config=""
  for excl_cli in $ALL_CLIS; do
    case "$(cli_exclusion_source "$excl_cli")" in
      flag)   excl_by_flag="${excl_by_flag:+$excl_by_flag }$excl_cli" ;;
      config) excl_by_config="${excl_by_config:+$excl_by_config }$excl_cli" ;;
    esac
  done
  if [[ -n "$excl_by_flag" ]]; then
    echo "   Excluded CLIs: ${excl_by_flag} (--exclude-cli)" >&2
  fi
  if [[ -n "$excl_by_config" ]]; then
    echo "   Excluded CLIs: ${excl_by_config} (config exclude_clis — ${EXCLUDE_CLIS_CONFIG_SOURCE})" >&2
  fi
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
      # 直前の CLI の項目を閉じる位置で、その CLI 宛の sandbox 警告を出す。
      if [[ -n "$current_cli" ]]; then
        warn_unappliable_sandbox "$current_cli"
      fi
      current_cli="$cli"
      local tier
      tier="$(get_cli_cost_tier "$cli")"
      echo "   ${cli} [${tier}]:" >&2
      echo_effort_setting "$cli"
    fi
    echo "     - ${persp}" >&2
  done <<< "$EXECUTION_PLAN"
  if [[ -n "$current_cli" ]]; then
    warn_unappliable_sandbox "$current_cli"
  fi

  # 同一 CLI への観点集中の可視化（Issue #251）。minimize_cost の振替で、振替先の
  # CLI（cursor → gemini [free-tier] → issue #783 以降は grok [flat-rate]）に複数
  # 観点が集まる形が典型。実行側は同一 CLI 内を逐次化済みだが、逐次でも連続
  # リクエストで throttle されうるため、プランの時点でリスクを名指しする（実行時
  # fallback は無い = throttle された観点のカバレッジはゼロになる、という帰結まで
  # 書く）。対象 tier は minimize_cost の振替先（flat-rate）。
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
    # 逐次化と対の警告なので発火条件も揃える: minimize_cost の振替で集中した場合
    # だけ。balanced では grok が自前の 2 観点を持つのが常態で、そこへ毎回警告を
    # 出すと「balanced へ分散せよ」という対処文が自己矛盾する（レビュー指摘）。
    if [[ "$STRATEGY" == "minimize_cost" && "$warn_count" -ge 2 && "$warn_tier" == "flat-rate" ]]; then
      echo "" >&2
      echo "   ⚠️  ${warn_cli} [${warn_tier}] runs ${warn_count} perspectives. ${warn_shape}," >&2
      echo "       but consecutive requests can still hit the provider rate limit — and there" >&2
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
  #
  # cross-model も対象に含める（本 Issue）。このモードは「同じ観点を複数モデルに
  # 見せる」ことだけが存在理由なので、除外の結果 1 本になった回はクロスモデルが
  # 成立していない — --mode の表示だけが残ると、単一モデルの結果をクロスモデル済みと
  # 誤読する（pair の PAIR_REVIEWERS_NOTE と同じ失敗の形）。発火条件は
  # 「除外があった」ことに限る: 除外なしで 1 本なら CLI が 1 つしか入っていない環境で、
  # そこへ毎回出しても打てる手が無い（インストール以外に無く、検出一覧が既に言っている）。
  # 明示 `--cli` は意図的な単一モデルなので黙る（L2052 の規約・隣の単一 CLI ゲートと
  # 同じ条件）。--cli で 1 本に絞った回にまで「クロスモデルではない」と言うのは、
  # 利用者が自分で書いたことを読み上げているだけで、打てる手も無い。
  if [[ "$MODE" == "cross-model" && "$planned_cli_count" -eq 1 && -z "$CLI_FILTER" ]] \
     && [[ -n "$excl_by_flag" || -n "$excl_by_config" ]]; then
    echo "" >&2
    echo "   ⚠️  Cross-model plan resolved to a single CLI (${planned_clis}) after exclusion —" >&2
    echo "       this run is NOT cross-model. A failure or timeout here means zero coverage;" >&2
    echo "       runtime fallback is deliberately absent." >&2
    [[ -n "$excl_by_flag" ]] && echo "       Excluded by --exclude-cli: ${excl_by_flag}" >&2
    [[ -n "$excl_by_config" ]] && echo "       Excluded by config exclude_clis (${EXCLUDE_CLIS_CONFIG_SOURCE}): ${excl_by_config}" >&2
    echo "       Drop an exclusion, or install another CLI, to compare models." >&2
  fi

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
# 違う」形の stale が静かに開く。report_unplanned_staging_dirs（プラン外タスクの
# staging 残骸の名指し・Issue #724）も同じ `<cli>/files/<perspective>` レイアウトを
# 前提に走査するので、ここを変えたらそちらも追随させること。
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
# が symlink だと再帰削除が意図しない場所へ抜けるため。例えば <cli>/files が
# /tmp/victim を指す symlink なら、rm -rf <cli>/files/<persp> は /tmp/victim/<persp> を
# 消す。OUTPUT_DIR を pwd -P しても、文字列 prefix 判定では途中の symlink を見抜けない。
# clear_planned_outputs は「プランの対象以外はディスク上の何にも触れない」と宣言して
# いるので、その宣言を実際に成り立たせるための検査。
#
# 判定は「解決先が OUTPUT_DIR 配下か」ではなく「symlink を追わない」で行う（Issue #1120）。
# 配下判定だと**内向き**の symlink — 解決先が出力先の中にあるもの、例えば
# `<cli>/files -> ../codex-cli/files` — が判定を通り、別 CLI / 別観点の staging 成果が
# 丸ごと消える。指し先が出力先の内か外かは、消してよいかどうかと関係がない: どちらも
# 「このタスクの staging ではないもの」を消す。clear_quarantine_dir（#723）と
# clear_planned_outputs（#722）は既にこの方針で、内向き追従が残っていたのはここだけだった。
#
# 形は 2 つに分かれる:
#   - staging パス**自体**が symlink … リンクだけを消して続行する（clear_quarantine_dir と
#     同型。`rm -f` は指し先を追わない）。この後 run_single_task が実体を作り直す
#   - パスの**途中**が symlink … resolve_expected_dir が「解決後 == 渡したパス」を要求して
#     fail-loud（内向き・外向きのどちらも拒否する）。削除は検査した物理パスに対して行い、
#     検査したものと消すものを一致させる
clear_staging_dir() { # <dir> [label]
  local staging_dir="$1" label="${2:-the staging dir}" resolved parent

  # 親（中間コンポーネント）を leaf の存在・種別より**先に**検査する。leaf が未作成の
  # 回は -L / -d / -e がすべて偽で、そのまま素通りすると呼び出し側の `mkdir -p` が
  # リンク先へ staging を作って書き込む（実測: <cli>/files が外を指す symlink で、
  # 観点ディレクトリがまだ無い初回実行）。leaf の状態に関係なく経路を先に塞ぐ。
  parent="$(dirname "$staging_dir")"
  if [[ -e "$parent" || -L "$parent" ]]; then
    resolve_expected_dir "$parent" "the staging parent for ${label}" \
      "Deleting through it would erase another task's staging output." >/dev/null || return 1
  fi

  # symlink は**追わない**。`[[ -d ]]` は symlink→dir でも真になるので -L を先に見る。
  if [[ -L "$staging_dir" ]]; then
    if ! rm -f "$staging_dir"; then
      echo "ERROR: cannot remove the symlink at the staging path: ${staging_dir}" >&2
      return 1
    fi
    echo "  ⚠️ Removed a symlink at the staging path (its target was left untouched): ${staging_dir}" >&2
    return 0
  fi

  if [[ -d "$staging_dir" ]]; then
    resolved="$(resolve_expected_dir "$staging_dir" "$label" \
      "Deleting through it would erase another task's staging output.")" || return 1
    if ! rm -rf "$resolved"; then
      echo "ERROR: cannot clear staging dir: ${resolved}" >&2
      echo "       A previous run's files would be reported as this run's output." >&2
      return 1
    fi
    return 0
  fi

  # ディレクトリでない残骸（通常ファイル等）はそれ自体を消す。symlink は上で処理済み。
  if [[ -e "$staging_dir" ]]; then
    if ! rm -f "$staging_dir"; then
      echo "ERROR: cannot remove non-directory at staging path: ${staging_dir}" >&2
      return 1
    fi
  fi
  return 0
}

# implement の CLI は常に REPO_ROOT から起動する。OUTPUT_DIR（= staging）も同じ
# 物理ルート配下でなければ、プロンプトが「書ける」と名指しした staging を CLI 側が
# 拒否する。警告して続けると起動してから初めて分かるので、起動前に fail-loud で止める。
#
# この検査が何を担保するかはアダプタごとに違う。一括で「4 アダプタのパス境界」と
# 書かないこと — claude-code にはパス境界そのものが無い（adapter-common.sh の
# build_prompt にも同じ注意がある）:
#
#   codex   … `codex exec -C <staging>` で書き込みルートは CWD ではなく staging 単独
#             （Issue #896）。この検査は境界そのものではなく、codex の git リポジトリ
#             検査（`--skip-git-repo-check` を渡さない前提）が要求する「staging が
#             リポジトリ配下」を満たす役割で、外すと implement が起動に失敗する。
#   grok    … `workspace` プロファイルの書き込みルートは CWD = REPO_ROOT。`-C` 相当の
#             絞り込みは未実測（grok-cli-adapter.sh の get_sandbox_profile 直前を参照）
#             なので、この検査が staging をその境界の内側に保つ担保。
#   copilot … 非 inline の implement には permission deny を渡さない（deny 配列は
#             inline 専用）。書き込みが CWD 由来のどこまでに閉じるかはこのリポジトリに
#             実測の記録が無いので、この検査は「staging を REPO_ROOT 配下に保つ」まで。
#   claude-code … パス境界を持たない。書き込みゲートは get_allowed_tools の
#             Write/Edit だけで、この検査はパス境界の担保にはならない（それでも
#             staging がリポジトリ外へ出る形は他の 3 つと同じく塞ぐ）。
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

# ── ツリー変化判定のパス除外の検証・分解（Issue #747） ──
#
# FF_MULTI_AGENT_IGNORE_PATHS を ':' 区切りで分解し、IGNORE_EXCLUDE_PATHSPECS
#（capture_repo_snapshot へ渡す除外形）と IGNORE_MATCH_PATHSPECS（報告用の肯定形）
# を組み立てる。fail-closed の原則は merge-cleanup.sh の
# FF_MERGE_CLEANUP_IGNORE_PATHS と揃える:
#   - 空パターン（先頭・末尾・連続する ':'）は中断 — 空 pathspec は全パスに一致し、
#     ガードを黙って無効化する（fail-open）ため
#   - 前後に空白の付いたパターンは中断 — pathspec は空白も含めて照合するので
#     何にも一致せず、「設定したのに効かない」が無言で続くため
#   - 文字クラス（[...]）は中断 — クラス内の ':' が区切り文字と衝突して黙って分断され、
#     破片は「何にも一致しない」正当そうな見た目になる（fail-open。
#     FF_MERGE_CLEANUP_PROTECT_BRANCHES の先例と同じ扱い）
#   - '.' / '/' 単体は中断 — glob magic では**何にも一致しない**（git 2.50.1 実測:
#     :(exclude,glob,top). / :(exclude,glob,top)/ はどちらも除外 0 件。さらに '/' は
#     肯定形 :(glob,top)/ が rc=128 "fatal: oops in prep_exclude" で落ち、verify 時の
#     除外報告クエリごと道連れにする）。全部を除外したい意図なら '**' を明示させる
#   - 全パス一致（'**' / '**/*'。git 2.50.1 実測でともに全除外）は明示的な選択でも
#     ありうるので中断せず、ガードが事実上無効になる旨を実行ログへ出す。'*' は
#     glob magic では '/' を跨がずリポジトリ直下しか除外しないため、警告対象ではない
# タスクを 1 つも起動する前（main の冒頭）に呼ぶ — CLI に支払った後で設定不正に
# 気づく形にしない。
parse_ignore_paths() {
  local raw="${FF_MULTI_AGENT_IGNORE_PATHS:-}" rest item
  [[ -n "$raw" ]] || return 0
  # 末尾の空要素も検出したいので、終端の ':' を足してから 1 要素ずつ剥がす
  rest="${raw}:"
  while [[ -n "$rest" ]]; do
    item="${rest%%:*}"
    rest="${rest#*:}"
    if [[ -z "$item" ]]; then
      echo "ERROR: FF_MULTI_AGENT_IGNORE_PATHS contains an empty pattern: '${raw}'" >&2
      echo "       An empty pathspec matches every path, which would silently disable the" >&2
      echo "       tree-change guard (check for a leading, trailing, or doubled ':')." >&2
      echo "       ':' is the separator, so pathspec magic like ':(exclude)...' cannot be" >&2
      echo "       written here (mid-pattern it is treated as literal text and matches nothing)." >&2
      return 1
    fi
    case "$item" in
      [[:space:]]*|*[[:space:]])
        echo "ERROR: FF_MULTI_AGENT_IGNORE_PATHS pattern has leading/trailing whitespace: '${item}'" >&2
        echo "       Pathspecs match whitespace literally, so this pattern matches nothing" >&2
        echo "       (check for a space after a ':')." >&2
        return 1
        ;;
    esac
    case "$item" in
      *\[*|*\]*)
        # logs/[[:digit:]]*/** のような文字クラスは、クラス内の ':' が区切り文字と
        # 衝突して黙って分断される（エラーにならないまま除外が消える fail-open）。
        echo "ERROR: FF_MULTI_AGENT_IGNORE_PATHS pattern contains a character class ([...]): '${item}'" >&2
        echo "       A ':' inside the class collides with the ':' separator and the pattern is" >&2
        echo "       silently split into fragments that look valid but match nothing, so" >&2
        echo "       character classes are unsupported (same as FF_MERGE_CLEANUP_PROTECT_BRANCHES)." >&2
        echo "       Use a prefix glob instead (e.g. 'logs/**')." >&2
        return 1
        ;;
    esac
    case "$item" in
      '.'|'/')
        # glob magic では '.' も '/' も**何にも一致しない**（実測: 除外 0 件）。しかも
        # '/' は肯定形 :(glob,top)/ を rc=128 で落とし、verify 時の除外報告ごと壊す。
        echo "ERROR: FF_MULTI_AGENT_IGNORE_PATHS pattern '${item}' matches nothing under" >&2
        echo "       pathspec glob magic — it would sit in the configuration excluding no path" >&2
        echo "       ('/' additionally breaks the exclusion-report query outright)." >&2
        echo "       To exclude every path, write '**' explicitly." >&2
        return 1
        ;;
      '**'|'**/*')
        echo "⚠️ FF_MULTI_AGENT_IGNORE_PATHS pattern '${item}' matches every path — the" >&2
        echo "   tree-change guard is effectively disabled for the working tree." >&2
        ;;
    esac
    IGNORE_EXCLUDE_PATHSPECS+=(":(exclude,glob,top)${item}")
    IGNORE_MATCH_PATHSPECS+=(":(glob,top)${item}")
  done
  return 0
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

  if ! before="$(capture_repo_snapshot "$exclude" "${IGNORE_EXCLUDE_PATHSPECS[@]}")"; then
    echo "ERROR: cannot read the repository state — refusing to start." >&2
    echo "       Without a baseline there is no way to tell afterwards whether the" >&2
    echo "       reviewed revision stayed put, and the result could not be trusted." >&2
    return 1
  fi

  create_fixed_diff || return 1

  if ! after="$(capture_repo_snapshot "$exclude" "${IGNORE_EXCLUDE_PATHSPECS[@]}")"; then
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
  local entry cli_name persp_name staging_dir cli_dir
  # 統合レポートは通常ここで消す。generate_report は成功時にしか書かないので、
  # 「タスクは走ったがレポート生成まで到達しなかった」実行のあとに無関係な前回結果を
  # 残さないためである。ただし未解消 Critical のレポートは、次回ガードが読む唯一の
  # 永続状態でもある。setup failure や事後 revision guard がそれを消すと次回の省略を
  # 許してしまうため、新しい review report が置き換えるまで保持する。
  if [[ "$PRESERVE_PREVIOUS_CRITICAL_REPORT" != "true" ]]; then
    if ! rm -f "${OUTPUT_DIR}/integrated-report.md"; then
      echo "ERROR: cannot clear the previous integrated report: ${OUTPUT_DIR}/integrated-report.md" >&2
      return 1
    fi
  fi
  # .fixed-diff はこの関数より前に capture_baseline_and_fix_diff が現在入力で上書きする。
  # resume identity はその内容 hash を使うため、ここで消してはならない。
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    cli_name="${entry%%:*}"
    persp_name="${entry#*:}"
    # <cli> が symlink だと rm -f はリンクを辿り、指し先ディレクトリ内の同名ファイル
    # （出力ディレクトリの外でありうる）を消す — OUTPUT_DIR 自体は物理解決済みでも
    # 配下コンポーネントは別（Issue #722）。execute_tasks では Phase 1 の
    # validate_planned_result_dirs が先に同じ検査で中断するが、削除の実行点として
    # ここでも自前で検査し、検査した物理パスに対して消す（clear_staging_dir と同じ
    # 「検査したものと消すものを一致させる」形。ヘルパも既存の resolve_expected_dir
    # を再利用する）。
    cli_dir="${OUTPUT_DIR}/${cli_name}"
    if [[ -d "$cli_dir" ]]; then
      cli_dir="$(resolve_expected_dir "$cli_dir" "the result dir for ${cli_name}")" || {
        # ループ途中の中断は「先行エントリは削除済み・以降は未削除」の半端な状態で
        # 抜ける（E2E では Phase 1 の validate が先に止めるため通常は到達しない）。
        # 到達したときに読み手が状態を推測しなくて済むよう 1 行残す。
        echo "       Some planned results may already be cleared before this abort." >&2
        return 1
      }
    elif [[ -e "$cli_dir" || -L "$cli_dir" ]]; then
      # 通常ファイル・dangling symlink は resolve できず [[ -d ]] も偽になるが、
      # 素通しすると rm -f が「何も消せないまま rc=0」で成功に見える。削除の実行点
      # としても validate_result_dir_paths と同じ fail-loud に揃える。
      echo "ERROR: the result path for ${cli_name} exists but is not a directory: ${cli_dir}" >&2
      echo "       Results are written under it, so this run cannot proceed." >&2
      return 1
    fi
    if ! rm -f "${cli_dir}/${persp_name}.md"; then
      echo "ERROR: cannot clear previous result: ${cli_dir}/${persp_name}.md" >&2
      return 1
    fi
    if [[ "${TASK_TYPE:-review}" == "implement" ]]; then
      staging_dir="$(staging_dir_for "$cli_name" "$persp_name")"
      clear_staging_dir "$staging_dir" "the staging dir for ${cli_name}/${persp_name}" || return 1
    fi
  done <<< "$EXECUTION_PLAN"
}

clear_previous_integrated_report() {
  [[ -n "${OUTPUT_DIR:-}" ]] || return 0
  if [[ "$PRESERVE_PREVIOUS_CRITICAL_REPORT" == "true" ]]; then
    return 0
  fi
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
# ディレクトリは report_unplanned_result_dirs が、プラン外タスクの staging 残骸は
# report_unplanned_staging_dirs が名指しする）。
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
# 第 3 引数は**内向き**（解決先が OUTPUT_DIR 配下）のときに出す 1 行の説明。既定は
# 結果ディレクトリ／退避先の話なので、staging のように壊れ方が違う呼び出し（Issue #1120）
# は自分の言葉で上書きする。外向きの説明は呼び出し側によらず同じ（出力先の外へ届く）
# なので共有のままにする。
resolve_expected_dir() { # <path> <label> [inward-note]
  local path="$1" label="$2" inward_note="${3:-}" resolved
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
        if [[ -n "$inward_note" ]]; then
          echo "       ${inward_note}" >&2
        else
          echo "       Results are keyed by CLI name; two names sharing one directory would" >&2
          echo "       quarantine from a directory this run also reports as not its own." >&2
        fi
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
  # 削除で塞ぐ。同型の内向き追従は clear_staging_dir にも残っていたが、Issue #1120 で
  # 同じ方針（リンクは追わない）へ揃えた。#722 の対象は clear_planned_outputs の
  # 外向き symlink だが、そこで再利用した resolve_expected_dir は内外どちらの
  # symlink も拒否する。
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
  # 報告専用（quarantine_unplanned_outputs の report_unplanned_result_dirs と同じ扱い）。
  # 走査の rc で退避成功の実行ごと落とさない。
  report_unplanned_staging_dirs "$cli" "$resolved_cli"
  return 0
}

# プラン外の CLI ディレクトリは 1 バイトも動かさない。ただし黙っていると
# `ls .review-results/` が前回実行の結果一式を今回の結果のように見せるので、
# 結果ファイルを持つものを名指しする（本 Issue が塞いだ誤読の、ディレクトリ単位版）。
report_unplanned_result_dirs() {
  local dir cli count discarded file
  for dir in "$OUTPUT_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    cli="${dir%/}"
    cli="${cli##*/}"
    # `*` は通常ドット始まりを外すが、**呼び出し元の環境に GLOBIGNORE があると
    # bash は dotglob を暗黙に有効化する**（`GLOBIGNORE` 非空 = dotglob 相当）。
    # そのまま通すと `--fresh` の退避先 `.prev-<ts>/` や `.resume-cache/` が
    # 「Not part of this run」として名指しされ、利用者は自分の出力ディレクトリの
    # 内部構造を残骸と読み違える。CLI 名がドットで始まることは無いので明示的に外す。
    case "$cli" in .*) continue ;; esac
    plan_has_cli "$cli" && continue
    count=0
    discarded=0
    for file in "${dir}"*.md; do
      if [[ -f "$file" || -L "$file" ]]; then
        count=$((count + 1))
        # 前回走が破棄された結果は mark_outputs_discarded が 1 行目へ
        # `> DISCARDED` バナーを書く。「今回の結果ではない」
        # に加えて「そもそも完成した結果ではない」まで言えるので、内訳を出す。
        # 読めないファイルは discarded と断定しない（数えないだけ）。
        # symlink は **通常ファイルのときだけ** 読む。プラン外ディレクトリは 1 バイトも
        # 動かさない契約で、その読み取りも同じ線引きに揃える（FIFO を head すると
        # 書き手が現れるまで固まり、出力先の外を指すリンクは辿ること自体が契約違反）。
        if [[ -f "$file" && ! -L "$file" ]]; then
          case "$(head -n 1 "$file" 2>/dev/null)" in
            '> DISCARDED'*) discarded=$((discarded + 1)) ;;
          esac
        fi
      fi
    done
    if [[ "$count" -gt 0 ]]; then
      if [[ "$discarded" -gt 0 ]]; then
        note_unplanned_results "${cli}/ (${count} result file(s) from an earlier run, ${discarded} of them marked DISCARDED by that run — left untouched, not this run's output)"
      else
        note_unplanned_results "${cli}/ (${count} result file(s) from an earlier run — left untouched, not this run's output)"
      fi
    fi
    # staging（files/）は直下の .md とは**独立に**名指しする。elif で束ねると、.md が
    # 1 件でもあるプラン外 CLI の staging 残骸が黙って素通りする（.md の名指しは
    # ディレクトリ直下の話で、files/ の中身の存在を伝えない）。プラン外 CLI は
    # 1 バイトも動かさない契約なので、ここも名指しだけ。unknown（走査できなかった）は
    # 「残骸あり」と断定せず、0 件とも言い切らない別文言で報告する。
    case "$(staging_root_state "${dir}files")" in
      symlink)
        note_unplanned_results "${cli}/ (files/ is a symlink left from an earlier run — not followed, not this run's output)"
        ;;
      files)
        note_unplanned_results "${cli}/ (staging file(s) under files/ from an earlier run — left untouched, not this run's output)"
        ;;
      unknown)
        note_unplanned_results "${cli}/ (could not scan files/ — treat it as possibly holding an earlier run's staging output; left untouched)"
        ;;
    esac
  done
}

# ── プラン外タスクの staging（<cli>/files/<perspective>/）の名指し（Issue #724） ──
#
# clear_planned_outputs が消す staging は**今回のプランに載るタスク**の分だけなので、
# 観点セットを絞った再実行のあとには、プランに入らなかったタスクの files/ に前回
# 実行の生成物が残る。`.md` 結果で塞いだ誤読（「そこにある = 今回の成果」）が一段
# 下で開いたままになる形（本 Issue）。
#
# `.md` と違い **退避はせず名指しだけ** にする（対称性を意図的に崩す）:
#   - staging の中身は orchestrator 自筆ではなく各 CLI（またはその指示で動く
#     エージェント）の生成物で、write_output の 1 行目マーカーによる「自筆かどうか」
#     の判定が任意形式のファイルには使えない。判定なしで動かすと、利用者が staging へ
#     置いたファイルまで「次の実行で捨てられる previous/」へ入れることになり、
#     `.md` 側で「他人のファイルは動かさない」と決めた根拠が 1 実行遅れで嘘になる
#   - 統合レポートの implement セクションは staging を実測して件数と実パスを書くので、
#     レポート経由の消費者はプラン内の staging だけ読む。残る誤読経路は
#     `ls <cli>/files/` の直接読みで、それは名指し（stderr + レポートの
#     Not part of this run 節）で塞がる
#
# 報告専用: 走査に失敗しても実行は落とさない（report_unplanned_result_dirs と同じ
# 扱い）。ただし数えられなかったことは隠さず「走査できなかった」として名指しする —
# 0 件と言い切ると「観測できなかった」が「何も無い」に化けるし、「N 件ある」と
# 断定すると観測していないものを観測したことにする（append_plan_sections の
# staging 実測と同じ理由で、三値〔有 / 無 / unknown〕を文言まで保って伝える）。
#
# プラン内タスクの除外は **implement のときだけ**。staging は implement の概念で、
# review / explore の実行は staging を clear もしなければ書きもしない — そこで
# plan_has_entry を見て黙ると、「観点名が今回のプランに載っている」だけの理由で
# 前回 implement の生成物が名指しから漏れる。
#
# symlink（files/ 自体・その配下のエントリとも）は**追わない**。名指しのための
# 読み取り走査でも、指し先が OUTPUT_DIR の外なら他人のツリーを歩くことになり、
# 「1 バイトも触れない」の精神（clear_quarantine_dir が rm で守っているもの）を
# 読み取りで破ることになる。リンクはリンクとして名指しして終える。
report_unplanned_staging_dirs() { # <cli> <resolved-cli-dir>
  local cli="$1" files_root="$2/files" entry name count
  if [[ -L "$files_root" ]]; then
    note_unplanned_results "${cli}/files (symlink left from an earlier run — not followed, not this run's output)"
    return 0
  fi
  [[ -d "$files_root" ]] || return 0
  for entry in "$files_root"/*; do
    # glob 不一致はパターンそのものへ展開されるので実体検査で弾く（dangling symlink
    # は -e が偽になるため -L も見る）。
    [[ -e "$entry" || -L "$entry" ]] || continue
    name="${entry##*/}"
    if [[ -L "$entry" ]]; then
      note_unplanned_results "${cli}/files/${name} (symlink left from an earlier run — not followed, not this run's output)"
      continue
    fi
    if [[ -d "$entry" ]]; then
      if [[ "${TASK_TYPE:-review}" == "implement" ]] && plan_has_entry "${cli}:${name}"; then
        continue
      fi
      count="$(count_staging_files "$entry")"
      case "$count" in
        0) ;;  # 空ディレクトリは読み手を誤らせる中身が無い
        unknown)
          note_unplanned_results "${cli}/files/${name}/ (could not scan this staging dir — treat it as possibly holding an earlier run's output; left untouched)"
          ;;
        *)
          note_unplanned_results "${cli}/files/${name}/ (${count} staging file(s) from an earlier run — left untouched, not this run's output)"
          ;;
      esac
      continue
    fi
    if [[ -f "$entry" ]]; then
      note_unplanned_results "${cli}/files/${name} (stray file from an earlier run — left untouched, not this run's output)"
      continue
    fi
    # fifo / socket 等。レイアウト外の実体も黙って素通しはしない。
    note_unplanned_results "${cli}/files/${name} (non-directory entry from an earlier run — left untouched, not this run's output)"
  done
  return 0
}

# staging 配下のファイル数を数える。走査失敗（権限・I/O、計数パイプの失敗）は
# 0 件と区別して "unknown" を返す。rc は**常に 0** — 報告専用経路で使うため、
# ここの失敗が set -e / 呼び出し元経由で実行本体を落としてはいけない。
# symlink も数える（指し先がどこでも「残骸がある」ことに変わりはない。-P 既定
# なので辿りはしない）。件数は -print0 の NUL を数える — 改行入りのファイル名を
# 行数で数えると 1 件が複数件に化ける。find の stderr は捨てない（unknown に
# なった原因が実行ログに残るように）。
count_staging_files() { # <dir>
  local count
  if ! count="$(find "$1" \( -type f -o -type l \) -print0 | tr -cd '\0' | wc -c | tr -d '[:space:]')" \
     || [[ ! "$count" =~ ^[0-9]+$ ]]; then
    printf 'unknown\n'
    return 0
  fi
  printf '%s\n' "$count"
  return 0
}

# <cli>/files の状態を三値 + α で返す: absent | symlink | empty | files | unknown。
# report_unplanned_result_dirs（プラン外 CLI の fall-back 名指し）用。unknown を
# 「有り」へ潰さない — 呼び出し側が文言を分けて伝える。rc は常に 0。
staging_root_state() { # <files-root>
  if [[ -L "$1" ]]; then
    printf 'symlink\n'
    return 0
  fi
  if [[ ! -d "$1" ]]; then
    printf 'absent\n'
    return 0
  fi
  local count
  count="$(count_staging_files "$1")"
  case "$count" in
    0) printf 'empty\n' ;;
    unknown) printf 'unknown\n' ;;
    *) printf 'files\n' ;;
  esac
  return 0
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
    # 解決結果ではなく指定された名前を使う。解決結果を混ぜると、ローカル base を
    # pull しただけで origin/develop → develop と名乗りが変わり、同じ入力の再実行が
    # 「別の入力」に見えて resume が丸ごと無効化される（base-oid が実体の変化を見る）。
    printf 'base-ref=%s\nbase-oid=%s\nhead=%s\n' "$BASE_BRANCH_IDENTITY" "$base_oid" "$head_oid"
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
  [[ ! -e "${RESUME_CACHE_DIR}/.pending" ]] || return 1
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

  if [[ -n "$EXECUTION_PLAN" ]]; then
    RESUME_CACHE_PENDING="${RESUME_CACHE_DIR}/.pending"
    if ! printf 'pid=%s\n' "$$" > "$RESUME_CACHE_PENDING"; then
      echo "ERROR: cannot mark the resume cache as pending verification: ${RESUME_CACHE_PENDING}" >&2
      return 1
    fi
  fi
}

finalize_resume_cache() {
  [[ -n "$RESUME_CACHE_PENDING" ]] || return 0
  if ! rm -f "$RESUME_CACHE_PENDING"; then
    echo "ERROR: cannot mark the resume cache as verified: ${RESUME_CACHE_PENDING}" >&2
    return 1
  fi
  RESUME_CACHE_PENDING=""
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

# ── 走行中ロック ──
# 起動バナー（execute_tasks の「完了まで worktree を変更しないでください」）は stdout /
# stderr を読む人間にしか届かない。background 起動ではそれを誰も読まないまま編集が
# 始まり、数分ぶんのレビューが revision guard で丸ごと破棄される再発が観測されている。
# ロックは**機械が読む宣言**で、PreToolUse hook（hooks/guard-review-in-flight.sh）が
# これを見て編集系ツールを止める。orchestrator 側は「置く / 必ず消す」だけを担い、
# 何を止めるかは hook が決める（破棄ロジック・終了コードはこの機構で変えない）。
#
# 置き場所は OUTPUT_DIR 直下の `.review-in-flight`。hook は既定の出力先
# （<repo root>/.review-results）しか探さないので、--output-dir で既定から動かした
# 実行は hook から見えない（hook 側ヘッダーに明記。fail-open）。
#
# task 名を引数に取るのは explore / implement へ広げる余地を残すため。現状の呼び出しは
# review だけで、他の task では呼ばない（バナーと同じ線引き）。
write_run_in_flight() { # <task> <head-sha> <perspectives-csv>
  local task="$1" head_sha="$2" perspectives="$3" f
  [[ -n "${OUTPUT_DIR:-}" && -d "$OUTPUT_DIR" ]] || return 0
  f="${OUTPUT_DIR}/.review-in-flight"
  # 書けなくても実行は止めない。これは追加の防御層で、これが無い状態は
  # 「この機構を入れる前」と同じ（revision guard は従来どおり効く）。
  if printf 'pid=%s\ntask=%s\nhead=%s\nstarted=%s\nstarted_epoch=%s\nperspectives=%s\n' \
      "$$" "$task" "$head_sha" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date -u +%s)" \
      "$perspectives" > "$f" 2>/dev/null; then
    REVIEW_IN_FLIGHT_FILE="$f"
  else
    echo "WARNING: could not write the in-flight marker: ${f}" >&2
    echo "         The tree-edit guard hook will not fire for this run." >&2
  fi
  return 0
}

# 正常終了・DISCARDED・タイムアウト・トラップ可能なシグナル（HUP / INT / TERM）のどれでも
# 消える必要がある。消し漏らすと以後の全編集が hook に止められるので、EXIT trap
# （output_lock_exit）から呼ぶ。個々の失敗経路へ後始末を配らないのは、経路が増えるたびに
# 1 つ書き忘れるクラスの事故を構造で消すため。
# 限界: SIGKILL（kill -9）とホストのクラッシュでは trap が走らずロックが残る。その残骸への
# 緩和は hook 側にあり、PID 生存判定と経過時間の上限
# （FF_REVIEW_LOCK_MAX_AGE_SECONDS、既定 4 時間）を超えたロックは stale として
# 警告だけで通す。手で消す場合は `rm <OUTPUT_DIR>/.review-in-flight`。
remove_run_in_flight() {
  [[ -n "$REVIEW_IN_FLIGHT_FILE" ]] || return 0
  if ! rm -f "$REVIEW_IN_FLIGHT_FILE" 2>/dev/null; then
    echo "WARNING: could not remove the in-flight marker: ${REVIEW_IN_FLIGHT_FILE}" >&2
    echo "         Remove it by hand, or the edit guard keeps firing." >&2
  fi
  REVIEW_IN_FLIGHT_FILE=""
  return 0
}

output_lock_exit() {
  local rc=$?
  remove_run_in_flight
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

# ── Fresh start: archive leftover output (Issue #1025) ──
# Run after the output lock is held so a concurrent run cannot have its files
# moved out from under it. The lock directory itself stays; everything else
# (reports, per-CLI results, resume cache) moves to `${OUTPUT_DIR}/.prev-<ts>/`.
# The unresolved-Critical guard then sees an empty output dir.
#
# 退避先は OUTPUT_DIR の**内側**（https://github.com/feel-flow/ff-dev-toolkit/issues/96）。
# 以前は兄弟の `<dir>.prev-<ts>/` で、
# 消費側が規約どおり `.review-results/` だけを gitignore していると一致せず、退避一式
# （実測 521 ファイル / 約 8MB）が丸ごとコミットへ巻き込まれた。規約を配っている側が
# 規約から外れる名前を実行時に生やしていたのが原因なので、名前の方を規約へ戻す。
#
# 結果ファイルの走査が `.prev-*` を拾わないことの確認（本 Issue の AC）:
#   - プラン外の結果ディレクトリ / staging の走査は `"$OUTPUT_DIR"/*/` の glob。
#     このスクリプトは dotglob を有効化していないが、**呼び出し元の環境に
#     `GLOBIGNORE` が設定されていると bash は dotglob を暗黙に有効化する**ので
#     `*` だけでは `.` 始まりを排除できない。report_unplanned_result_dirs は
#     ループ内で `.` 始まりを明示 skip して、退避先を「今回のプラン外」として
#     名指ししないようにしている。
#   - integrated-report / resume-cache / series タグ / 未解消 Critical guard /
#     各タスクの結果判定は固定パス（`${OUTPUT_DIR}/integrated-report.md`,
#     `${OUTPUT_DIR}/.resume-cache/<identity>`, `${OUTPUT_DIR}/<cli>/<persp>.md`）
#     だけを読む。退避後はそれらが `.prev-<ts>/` の下へ移るので今回の走査に入らない。
# ドットを含めて走査するのはこの関数だけなので、退避先と既存の `.prev-*` はここで外す。
archive_previous_outputs_if_fresh() {
  [[ "$FRESH" == "true" ]] || return 0
  [[ -n "${OUTPUT_DIR:-}" && -d "$OUTPUT_DIR" ]] || return 0

  local item base ts archive archive_base moved=0
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  archive_base=".prev-${ts}"
  archive="${OUTPUT_DIR}/${archive_base}"
  if [[ -e "$archive" ]]; then
    archive_base="${archive_base}-$$"
    archive="${OUTPUT_DIR}/${archive_base}"
  fi
  if [[ -e "$archive" ]]; then
    echo "ERROR: archive destination already exists: ${archive}" >&2
    echo "       Previous results were left untouched: ${OUTPUT_DIR}" >&2
    return 1
  fi

  for item in "$OUTPUT_DIR"/* "$OUTPUT_DIR"/.[!.]* "$OUTPUT_DIR"/..?*; do
    [[ -e "$item" || -L "$item" ]] || continue
    base="${item##*/}"
    [[ "$base" == ".multi-agent-run.lock" ]] && continue
    # 退避先を自分自身の中へ入れない。加えて過去の実行が残した `.prev-*` も動かさない
    # （`.[!.]*` はこれらを拾う）。動かすと退避が入れ子に積み上がり、`--fresh` のたびに
    # 同じバイト列を 1 段深くコピーし直すことになる。
    [[ "$base" == "$archive_base" ]] && continue
    case "$base" in .prev-*) continue ;; esac
    if [[ "$moved" -eq 0 ]]; then
      if ! mkdir "$archive"; then
        echo "ERROR: cannot create archive dir: ${archive}" >&2
        echo "       Previous results were left untouched: ${OUTPUT_DIR}" >&2
        return 1
      fi
    fi
    if ! mv "$item" "${archive}/${base}"; then
      echo "ERROR: cannot archive previous result: ${item}" >&2
      echo "       --fresh left a partial archive at ${archive}" >&2
      return 1
    fi
    moved=$((moved + 1))
  done

  if [[ "$moved" -eq 0 ]]; then
    echo "ℹ️  --fresh: no previous results to archive in ${OUTPUT_DIR}" >&2
    report_archive_accumulation
    return 0
  fi
  echo "🧹 --fresh: archived ${moved} previous result(s) to ${archive}" >&2
  report_archive_accumulation
  return 0
}

# 退避先は出力ディレクトリの内側なので gitignore に乗り、`git status` にも `ls` にも
# 現れない。コミットへ巻き込まれないのが狙いだが、見えない分だけ `--fresh` のたびに
# 黙って積み上がる（旧形式の兄弟は少なくとも untracked として見えていた）。退避完了の
# 直後に件数と合計サイズを 1 行出し、掛け目で気づけるようにする。
# 報告専用: `du` が無い / 失敗しても件数だけ出して実行は落とさない。
report_archive_accumulation() {
  local cand count=0 total=""
  local archives=()
  for cand in "$OUTPUT_DIR"/.prev-*; do
    [[ -d "$cand" ]] || continue
    archives+=("$cand")
    count=$((count + 1))
  done
  [[ "$count" -gt 0 ]] || return 0
  if total="$(du -shc "${archives[@]}" 2>/dev/null | tail -n 1 | awk '{print $1}')" \
    && [[ -n "$total" ]]; then
    echo "   ↳ ${count} archive(s) now under ${OUTPUT_DIR}/.prev-* (${total} total) — remove with: rm -rf ${OUTPUT_DIR}/.prev-*" >&2
  else
    echo "   ↳ ${count} archive(s) now under ${OUTPUT_DIR}/.prev-* — remove with: rm -rf ${OUTPUT_DIR}/.prev-*" >&2
  fi
  return 0
}

# ── Unresolved Critical guard (Issue #843) ──
# A narrowed review rebuilds integrated-report.md from only this run's plan. Read
# the orchestrator-owned state before cleanup and reject a plan that omits a
# still-unresolved perspective. The machine line is always the report's last line;
# legacy reports fall back to the final marker summary lines only.
previous_report_has_critical_marker() { # <report-file>
  local summary
  summary="$(tail -n 12 "$1")" || return 2
  printf '%s\n' "$summary" \
    | grep -Fx -e '<!-- CRITICAL_BLOCK -->' \
      -e '<!-- CRITICAL_NONBLOCK -->' >/dev/null
}

current_review_series_id() {
  local branch scope repo symbolic_ref_rc
  repo="$(cd "$REPO_ROOT" && pwd -P)" || return 1
  if branch="$(git symbolic-ref --quiet HEAD)"; then
    :
  else
    symbolic_ref_rc=$?
    [[ "$symbolic_ref_rc" -eq 1 ]] || return 1
    branch="detached:$(git rev-parse HEAD 2>/dev/null)" || return 1
  fi
  if [[ "$STAGED_DIFF" == "true" ]]; then scope="staged"; else scope="branch"; fi
  # This is an accidental-mixing guard, not an authentication boundary. POSIX
  # cksum keeps the persisted token portable across macOS and Linux.
  #
  # base は**解決前の名前**（BASE_BRANCH_IDENTITY）を使う。解決結果を混ぜると、
  # ローカル base の鮮度だけで develop ↔ origin/develop が入れ替わり、同じレビュー
  # 文脈が別系列になる（stale のまま 1 回目 → git pull 後の 2 回目が
  # "another branch/base/scope" と判定され、未解決 Critical を引き継げずに
  # 強制フルレビューへ落ちる偽陽性）。
  printf 'repo=%s\nbranch=%s\nbase=%s\nscope=%s\n' "$repo" "$branch" "$BASE_BRANCH_IDENTITY" "$scope" \
    | cksum | awk '{ print $1 "-" $2 }'
}

extract_unresolved_critical_perspectives() { # <report-file>
  local last_line report_tail
  report_tail="$(tail -n 12 "$1")" || return 1
  last_line="$(printf '%s\n' "$report_tail" | tail -n 1)" || return 1
  case "$last_line" in
    '<!-- MULTI_CLI_UNRESOLVED_CRITICAL series:'*' block:'*' nonblock:'*' -->')
      printf '%s\n' "$last_line" | awk '
        {
          line = $0
          sub(/^<!-- MULTI_CLI_UNRESOLVED_CRITICAL series:/, "", line)
          sub(/ -->$/, "", line)
          if (split(line, series_parts, " block:") != 2) exit 2
          if (split(series_parts[2], parts, " nonblock:") != 2) exit 2
          if (parts[1] == "" || parts[2] == "") exit 2
          print "series:" series_parts[1]
          if (parts[1] != "-") {
            n = split(parts[1], names, " ")
            for (i = 1; i <= n; i++) if (names[i] != "") print "block:" names[i]
          }
          if (parts[2] != "-") {
            n = split(parts[2], names, " ")
            for (i = 1; i <= n; i++) if (names[i] != "") print "nonblock:" names[i]
          }
        }
      '
      return $?
      ;;
  esac

  # A machine-state marker is valid only in its complete final-line form. If a
  # marker-like line exists elsewhere in the tail, legacy parsing must not drop
  # its series identity and silently accept a different branch/base/scope.
  if grep -F 'MULTI_CLI_UNRESOLVED_CRITICAL' "$1" >/dev/null; then
    return 1
  else
    local marker_scan_rc=$?
    [[ "$marker_scan_rc" -eq 1 ]] || return 1
  fi

  printf '%s\n' "$report_tail" | awk '
    /^Critical issues detected \([^)]*\)\. Review before proceeding\.$/ ||
    /^Unparseable result treated as critical \([^)]*\):/ {
      line = $0; sub(/^[^(]*\(/, "", line); sub(/\).*$/, "", line)
      gsub(/,[[:space:]]*/, "\nblock:", line); print "block:" line
    }
    /^Critical findings in non-blocking perspectives \([^)]*\)\.$/ ||
    /^Unparseable result treated as critical, in non-blocking perspectives \([^)]*\)\.$/ {
      line = $0; sub(/^[^(]*\(/, "", line); sub(/\).*$/, "", line)
      gsub(/,[[:space:]]*/, "\nnonblock:", line); print "nonblock:" line
    }
  '
}

execution_plan_has_perspective() { # <perspective>
  local entry
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    [[ "${entry#*:}" == "$1" ]] && return 0
  done <<< "$EXECUTION_PLAN"
  return 1
}

is_unfiltered_full_review_plan() {
  # A "full" review that may start a new series is: every default perspective
  # for the selected CLI set. --cli is not a perspective filter —
  # scripts/codex-review.sh always passes --cli codex-cli, and that is the
  # Git Workflow's full Codex review (Issue #1025). --perspective,
  # --exclude-perspective, and cross-model (typically one perspective across
  # CLIs) still cannot start a new series, because they would drop unresolved
  # perspectives from the previous series without reviewing them.
  [[ "$MODE" != "cross-model" \
    && -z "$PERSPECTIVE_FILTER" \
    && -z "$EXCLUDE_PERSPECTIVES" ]]
}

capture_and_guard_unresolved_critical_state() {
  [[ "$TASK_TYPE" == "review" ]] || return 0
  local report_file="${OUTPUT_DIR}/integrated-report.md" parsed tagged tag perspective missing="" marker_rc=0
  local previous_series="" current_series="" base_q
  [[ -f "$report_file" ]] || return 0
  if ! parsed="$(extract_unresolved_critical_perspectives "$report_file")"; then
    echo "ERROR: cannot inspect unresolved Critical perspectives in the previous report." >&2
    echo "       Previous results were left untouched: ${report_file}" >&2
    return 1
  fi
  if [[ -z "$parsed" ]]; then
    if previous_report_has_critical_marker "$report_file"; then
      marker_rc=0
    else
      marker_rc=$?
    fi
    case "$marker_rc" in
      1) return 0 ;;
      0)
        echo "ERROR: the previous report has a Critical marker without a readable perspective list." >&2
        echo "       Inspect the leftover report, then add --fresh, or move/delete it if it is obsolete and run a full review." >&2
        echo "       Previous results were left untouched: ${report_file}" >&2
        return 1
        ;;
      *)
        echo "ERROR: cannot inspect Critical markers in the previous report." >&2
        echo "       Previous results were left untouched: ${report_file}" >&2
        return 1
        ;;
    esac
  fi

  while IFS= read -r tagged; do
    [[ -n "$tagged" ]] || continue
    tag="${tagged%%:*}"
    perspective="${tagged#*:}"
    if [[ "$tag" == "series" ]]; then
      if [[ -n "$previous_series" ]] || ! [[ "$perspective" =~ ^[0-9]+-[0-9]+$ ]]; then
        echo "ERROR: invalid review-series entry in previous Critical state: '${tagged}'" >&2
        echo "       Previous results were left untouched: ${report_file}" >&2
        return 1
      fi
      previous_series="$perspective"
      continue
    fi
    if [[ "$tag" != "block" && "$tag" != "nonblock" ]] || ! is_safe_token "$perspective"; then
      echo "ERROR: invalid perspective entry in previous Critical state: '${tagged}'" >&2
      echo "       Previous results were left untouched: ${report_file}" >&2
      return 1
    fi
    if [[ "$tag" == "block" ]]; then
      list_contains "$PREVIOUS_UNRESOLVED_BLOCK" "$perspective" \
        || PREVIOUS_UNRESOLVED_BLOCK="${PREVIOUS_UNRESOLVED_BLOCK:+$PREVIOUS_UNRESOLVED_BLOCK }$perspective"
    else
      list_contains "$PREVIOUS_UNRESOLVED_NONBLOCK" "$perspective" \
        || PREVIOUS_UNRESOLVED_NONBLOCK="${PREVIOUS_UNRESOLVED_NONBLOCK:+$PREVIOUS_UNRESOLVED_NONBLOCK }$perspective"
    fi
  done <<< "$parsed"

  if [[ -n "$PREVIOUS_UNRESOLVED_BLOCK" || -n "$PREVIOUS_UNRESOLVED_NONBLOCK" ]]; then
    # Keep the prior report until an atomically completed new report replaces
    # it. A new review series does not inherit the classifications, but setup
    # failure must still not erase the old series' only durable evidence.
    PRESERVE_PREVIOUS_CRITICAL_REPORT=true
  fi

  # A machine state line is written after every review, including an all-clear
  # run. With no unresolved perspectives there is nothing to protect, so a
  # later base/branch/scope change must not block an otherwise valid run.
  if [[ -z "$PREVIOUS_UNRESOLVED_BLOCK" && -z "$PREVIOUS_UNRESOLVED_NONBLOCK" ]]; then
    if previous_report_has_critical_marker "$report_file"; then
      echo "ERROR: the previous report has a Critical marker but its machine state is empty." >&2
      echo "       Previous results were left untouched: ${report_file}" >&2
      return 1
    else
      marker_rc=$?
    fi
    case "$marker_rc" in
      1) return 0 ;;
      *)
        echo "ERROR: cannot inspect Critical markers in the previous report." >&2
        echo "       Previous results were left untouched: ${report_file}" >&2
        return 1
        ;;
    esac
  fi

  # A legacy report (written before the machine state carried series:) has no
  # series identity at all. That is not a fail-open case: an unreadable series
  # cannot prove the leftover belongs to *this* series, so it is treated as
  # another series. An unfiltered full review re-runs every default perspective
  # anyway, so it may start a new series — otherwise the first review after a
  # toolkit upgrade always aborts and forces a manual move of the leftover.
  # Narrowed runs keep falling through to the perspective check below, so they
  # still pass only when the plan covers every unresolved perspective.
  local previous_series_is_current=false
  if [[ -n "$previous_series" ]]; then
    current_series="$(current_review_series_id)" || {
      echo "ERROR: cannot identify the current review series." >&2
      return 1
    }
    [[ "$previous_series" == "$current_series" ]] && previous_series_is_current=true
  fi

  if [[ "$previous_series_is_current" != "true" ]]; then
    if is_unfiltered_full_review_plan; then
      PREVIOUS_UNRESOLVED_BLOCK=""
      PREVIOUS_UNRESOLVED_NONBLOCK=""
      if [[ -n "$previous_series" ]]; then
        echo "ℹ️  Previous Critical state belongs to another branch/base/scope; this unfiltered full review starts a new series." >&2
      else
        echo "ℹ️  Previous Critical state predates review-series tracking; this unfiltered full review starts a new series." >&2
      fi
      return 0
    fi
    if [[ -n "$previous_series" ]]; then
      echo "ERROR: the previous Critical state belongs to another branch/base/scope." >&2
      echo "       Run an unfiltered full review to start a new review series." >&2
      echo "       Full review = no --perspective / --exclude-perspective / --mode cross-model (--cli is allowed)." >&2
      echo "       Example: bash scripts/codex-review.sh --base ${BASE_BRANCH}" >&2
      echo "       Or archive leftover results and retry: add --fresh" >&2
      echo "       Previous results were left untouched: ${report_file}" >&2
      return 1
    fi
  fi

  for perspective in $PREVIOUS_UNRESOLVED_BLOCK $PREVIOUS_UNRESOLVED_NONBLOCK; do
    execution_plan_has_perspective "$perspective" \
      || missing="${missing:+$missing }$perspective"
  done

  if [[ -n "$missing" ]]; then
    # The recovery routes must be spelled out here too. A leftover report can
    # list perspectives that no narrowed plan can cover (a distributed plan owns
    # only a subset), so "include every listed perspective" alone leaves the
    # caller with no way forward but a manual move of the previous results.
    echo "ERROR: narrowed review omits unresolved Critical perspective(s): ${missing}" >&2
    echo "       Include every listed perspective and verify its marker is resolved before narrowing." >&2
    # The full-review route is offered only when the leftover is NOT from this
    # series. Within the same series a full review starts no new series, and the
    # suggested entry point runs a distributed plan whose single CLI owns only a
    # subset of the perspectives — a perspective owned by another CLI stays
    # missing and reproduces this very error. Advertising it there would send the
    # caller around a loop that cannot succeed; --fresh remains the way out.
    if [[ "$previous_series_is_current" != "true" ]]; then
      echo "       Or run a full review, which covers every default perspective:" >&2
      # 貼り付け実行される案内なので branch 名を素で埋めない（既存の base_q と同じ流儀。
      # printf '%q' は使わない — 現在のロケールでマルチバイトを分解して壊すため。
      # shell_quote は valid UTF-8 のまま安全に引用する）
      base_q="$(shell_quote "$BASE_BRANCH")"
      echo "       bash scripts/codex-review.sh --base ${base_q}" >&2
    fi
    echo "       Or archive leftover results and retry: add --fresh" >&2
    echo "       Previous results were left untouched: ${report_file}" >&2
    return 1
  fi
  return 0
}

# 「この実行がその観点の判定を出していない」— 失敗（FAILED_TASKS）とスキップ
# （SKIPPED_TASKS）の**両方**を見る。前回の未解消 Critical を保持するかどうかは
# 「解消が証明されたか」で決まり、スキップは失敗以上に何も証明していない
# （Issue #1143。分けたのは案内の文面であって、この述語の意味ではない）。
# 片方だけを見ると、スキップされた観点は成果物も無いため判定ループの
# `[[ -f "$crit_file" ]] || continue` で捨てられ、前回の CRITICAL_BLOCK が
# 静かに消える — pre-push ゲートが素通りする fail-open。
task_left_perspective_unproven() { # <cli> <perspective>
  local entry prefix="${1}/${2}:"
  for entry in $FAILED_TASKS $SKIPPED_TASKS; do
    [[ "$entry" == "$prefix"* ]] && return 0
  done
  return 1
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
  # 逐次ワーカー（run_cli_group）が「この CLI はもう走らせない」を判断するために
  # rc を必要とする。rc ファイル経由で読ませると、記録に失敗した回に判断材料ごと
  # 消える（記録失敗はワーカーを殺すが、殺す前に判断は済ませたい）。
  LAST_TASK_RC="$rc"
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
# EXECUTION_PLAN から自分の CLI の観点だけを計画順に**逐次**実行する。flat-rate
# CLI 専用 — レート制限は実行時失敗であり、本ツールは実行時 fallback を持たない
# ため、throttle された観点はカバレッジゼロになる。同時 burst を作らないことが
# 防御になる。premium / standard tier は従来どおりタスク単位で並列（一律逐次化は
# pair モード既定の premium 8 観点で実行時間を観点数倍にする退行になる）。
run_cli_group() { # $1: cli / $2: status dir
  local cli="$1" sdir="$2" entry gseen="" persp poison="" cause=""
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    [[ "${entry%%:*}" == "$cli" ]] || continue
    if [[ " $gseen " == *" $entry "* ]]; then continue; fi
    gseen="$gseen $entry"
    persp="${entry#*:}"
    # 先行タスクが auth / billing で落ちていたら、この CLI の残りは実行しない
    # （Issue #1143）。フル setup（プロンプト構築・diff 読み込み・タイムアウト待ち）
    # を払ってから同じ失敗を引くだけなので、払う前に落とす。
    # 親プロセスは変数を見られない（このワーカーはバックグラウンドのサブシェル）ので、
    # 理由はステータス dir へ書いて回収側に読ませる。
    if [[ -n "$poison" ]]; then
      record_task_skipped "$cli" "$persp" "$poison" "$sdir" || return 1
      continue
    fi
    # 進捗を名乗ってから実行する — ワーカーが途中で死んだとき、どのタスクの
    # 処理中だったかはこの行でしか相関できない（逐次ブランチの ▶ 表示と対）。
    echo "▶ ${cli} → ${persp} (serialized)" >&2
    run_task_recorded "$cli" "$persp" "$sdir" || return 1
    if [[ "${LAST_TASK_RC:-0}" -ne 0 && "${LAST_TASK_RC:-0}" -ne 124 ]]; then
      cause="$(classify_cli_failure_cause "${OUTPUT_DIR}/${cli}/${persp}.md")"
      if cli_failure_is_deterministic "$cause"; then
        poison="$cause"
      fi
    fi
  done <<< "$EXECUTION_PLAN"
}

# スキップを回収側へ伝える印。rc ファイルは書かない — rc の意味論（0 = 成功 /
# 非 0 = その終了コードで失敗 / 不在 = ワーカーが記録前に死んだ）へ 4 つ目の値を
# 混ぜると、既存の 3 分岐すべてが「この値は何を意味するか」を再解釈することになる。
record_task_skipped() { # $1: cli / $2: perspective / $3: cause / $4: status dir
  mkdir -p "${4}/${1}"
  if ! { printf '%s\n' "$3" > "${4}/${1}/${2}.skip.tmp" \
         && mv "${4}/${1}/${2}.skip.tmp" "${4}/${1}/${2}.skip"; }; then
    # 印を書けなければスキップを黙って成立させない。回収側は rc ファイル不在を
    # 「ワーカーが記録前に死んだ」= 失敗として拾うので、安全側には倒れる。
    echo "  ⚠️ Failed to record the skip marker for ${1}/${2}: ${4} is not writable" >&2
    return 1
  fi
  echo "  ⏭ Skipped ${1}/${2} — ${1} already failed in this run for a ${3} reason (not task-specific)." >&2
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
  #      揃えておかないと validate_implement_output_boundary が毎回誤発火する
  #      （旧名 warn_if_staging_outside_sandbox。現存しないので grep しないこと）。
  if ! OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"; then
    echo "ERROR: cannot resolve output dir: ${OUTPUT_DIR}" >&2
    return 2
  fi
  validate_implement_output_boundary || return 2
  validate_output_dir_boundary || return 2
  acquire_output_lock || return 2
  # --fresh must run after the lock and before the unresolved-Critical guard,
  # so leftover reports are no longer the guard's input.
  archive_previous_outputs_if_fresh || return 2
  # The previous report is the evidence this guard validates. Run it before
  # clear_previous_integrated_report and before any result file is changed.
  capture_and_guard_unresolved_critical_state || return 2
  # An all-clear prior report is stale once this run starts. An unresolved prior
  # report remains the durable guard state until a new report proves resolution,
  # so clear_previous_integrated_report deliberately preserves that case.
  clear_previous_integrated_report || return 2
  # 結果ディレクトリの解決検査は**<cli>/ 配下へ触る最初の操作より前**に一括で行う
  # （Issue #537 / #654）。この下の resume 書き戻し（cp）・clear_planned_outputs
  # （rm -f）・退避（mv）はどれも `${OUTPUT_DIR}/<cli>/` を素通りするので、検査を
  # 退避の中に置くと <cli> が外向き symlink のときに検査到達前へ書き込み・削除が
  # 済んでしまう。all-clear の統合レポート削除より後に置く。未解消レポートは次回
  # ガードの状態なので、この検査が落ちても保持する（上の例外規則）。
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
  SKIPPED_TASKS=""
  POISONED_CLIS=""

  # review だけ: タスクを 1 つでも起動する前に「完了までツリーを触らない」バナーを
  # 1 回出す。ツリーが動いた実行の破棄（verify_repo_unchanged）は**事後検出**で、
  # 着手前に注意を促さないと数分のレビューが丸ごと無駄になる再発が起きていた。
  # 破棄ロジックは並列・逐次のどちらの経路でも同じように走るので、バナーもこの
  # 分岐の**外**で出す（片方の経路にしか置かないと、出ないほうで同じ事故が再発する）。
  # explore / implement では出さない（review 限定）。破棄ロジック・終了コードは変えない。
  if [[ "$TASK_TYPE" == "review" ]]; then
    # HEAD は起動時に固定した基準（REPO_SNAPSHOT_BEFORE の第 1 フィールド＝フル SHA）
    # から作る。ここで HEAD を引き直すと、baseline を取ってからバナーを出すまでの間に
    # HEAD が動いた場合に、破棄診断の「HEAD: <前> → <後>」の <前> と食い違う値を
    # 見せてしまう。短縮は記録済みの SHA を引くだけなので HEAD の移動に影響されない。
    local banner_head="n/a"
    if [[ -n "$REPO_SNAPSHOT_BEFORE" ]]; then
      local banner_head_full="${REPO_SNAPSHOT_BEFORE%% *}"
      case "$banner_head_full" in
        unborn) banner_head="unborn" ;;
        *)
          banner_head="$(git rev-parse --short "$banner_head_full" 2>/dev/null || printf '%s' "${banner_head_full:0:12}")"
          [[ -n "$banner_head" ]] || banner_head="n/a"
          ;;
      esac
    fi
    # 進行表示はこのスクリプトでは一貫して stderr（直後の "⏳ Waiting for" と同じ）。
    # stdout は結果を受け取る側のものなので、注意喚起をそちらへ混ぜない。
    echo "⚠️  完了まで worktree を変更しないでください（commit / push / checkout / 編集）。変更を検出すると結果は全破棄されます（HEAD: ${banner_head}）" >&2
    # バナーと同じ地点で機械可読の宣言も置く。読まれないバナーの
    # 代わりに hook が読む。観点一覧は今回のプラン**全体**（resume で再利用へ倒れた
    # 観点を含む FULL_EXECUTION_PLAN）から作る — 利用者から見て「走っているレビュー」
    # はレポートに載る観点の集合であって、実行したタスクだけではない。
    local in_flight_perspectives="" in_flight_seen="" plan_entry plan_persp
    while IFS= read -r plan_entry; do
      [[ -n "$plan_entry" ]] || continue
      plan_persp="${plan_entry#*:}"
      list_contains "$in_flight_seen" "$plan_persp" && continue
      in_flight_seen="${in_flight_seen:+${in_flight_seen} }${plan_persp}"
      in_flight_perspectives="${in_flight_perspectives:+${in_flight_perspectives},}${plan_persp}"
    done <<< "$FULL_EXECUTION_PLAN"
    write_run_in_flight "$TASK_TYPE" "${REPO_SNAPSHOT_BEFORE%% *}" "$in_flight_perspectives"
  fi

  if [[ "$PARALLEL" == "true" ]]; then
    # ── 並列実行: CLI 間は並列、同一 CLI 内は逐次（Issue #251） ──
    # minimize_cost が premium の観点を最安 tier へ振り替えると、同一 CLI
    # （現行の振替先は flat-rate の grok-cli — issue #783 で free-tier が消えた後の
    # 最安 tier）へ複数観点が集中する。本ツールは
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

    # minimize_cost の振替で観点が集中したときだけ、振替先 tier（flat-rate）の CLI を
    # 1 本の逐次ワーカーへ（balanced 等では flat-rate も従来どおりタスク並列 — 自前の
    # 2 観点は集中ではなく常態のため。レビュー指摘で strategy 条件を追加）。それ以外は
    # 従来どおりタスク単位で並列。
    # pid と並行してラベル（worker:<cli> / task:<cli>/<persp>。空白を含まない）を
    # 記録する — rc ファイル不在の失敗で「どのプロセスが・どの rc で死んだか」を
    # 相関できるのはこの対応表だけ（wait の rc は下で回収して報告する）。
    local serialized_clis="" pid_labels=""
    local group_cli
    for group_cli in $group_clis; do
      if [[ "$STRATEGY" == "minimize_cost" && "$(get_cli_cost_tier "$group_cli")" == "flat-rate" ]]; then
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
      echo "⏳ Waiting for ${count} ${TASK_TYPE} task(s) — flat-rate CLI(s) run their tasks sequentially (rate-limit protection):${serialized_clis:+ }${serialized_clis}" >&2
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
      local skip_file="${status_dir}/${cli}/${persp}.skip"
      local exit_code
      # スキップは rc の判定より**前**に見る（Issue #1143）。スキップしたタスクは
      # rc ファイルを書かないので、順序を逆にすると「ワーカーが記録前に死んだ」へ
      # 落ちて、理由が失われたうえに死因の追跡へ読み手を送る。
      if [[ -f "$skip_file" ]]; then
        local skip_cause
        skip_cause="$(cat "$skip_file" 2>/dev/null)" || skip_cause=""
        if ! cli_failure_is_deterministic "$skip_cause"; then
          # 印が読めない / 想定外の値。スキップは実行の欠落なので、理由が確定
          # できないものを「意図したスキップ」として通さない（失敗側へ倒す）。
          failed=$((failed + 1))
          FAILED_TASKS="${FAILED_TASKS:+$FAILED_TASKS }${task_name}:1"
          echo "  ❌ Unreadable skip marker (content='${skip_cause}'): ${task_name}" >&2
          continue
        fi
        failed=$((failed + 1))
        SKIPPED_TASKS="${SKIPPED_TASKS:+$SKIPPED_TASKS }${task_name}:${skip_cause}"
        continue
      fi
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

      # 先行タスクが auth / billing で落ちた CLI の残りは実行しない（Issue #1143）。
      # 逐次ブランチはループ自体が親プロセスなので、ステータス dir を経由せず
      # そのまま SKIPPED_TASKS へ記録する。
      local seq_cause
      seq_cause="$(skipped_cli_cause "$cli")"
      if [[ -n "$seq_cause" ]]; then
        failed=$((failed + 1))
        SKIPPED_TASKS="${SKIPPED_TASKS:+$SKIPPED_TASKS }${cli}/${persp}:${seq_cause}"
        echo "  ⏭ Skipped ${cli}/${persp} — ${cli} already failed in this run for a ${seq_cause} reason (not task-specific)." >&2
        continue
      fi

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
        # この CLI の残タスクを落とすかどうかは、失敗のたびに判定する（Issue #1143）。
        # 124（timeout）は除く — 案内層と同じ規則（print_failure_advice は 124 の
        # とき分類を断定材料にしない）。時間を足せば通る失敗でカバレッジを捨てない。
        local seq_fail_cause
        if [[ $task_rc -ne 124 ]]; then
          seq_fail_cause="$(classify_cli_failure_cause "${OUTPUT_DIR}/${cli}/${persp}.md")"
          if cli_failure_is_deterministic "$seq_fail_cause"; then
            POISONED_CLIS="${POISONED_CLIS:+$POISONED_CLIS }${cli}:${seq_fail_cause}"
          fi
        fi
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
  local skipped_count=0 entry_count
  for entry_count in $SKIPPED_TASKS; do
    skipped_count=$((skipped_count + 1))
  done
  local failed_only=$((failed - skipped_count))
  [[ "$failed_only" -ge 0 ]] || failed_only=0
  if [[ $failed -gt 0 ]]; then
    if [[ $skipped_count -gt 0 ]]; then
      echo "⚠️  ${failed_only} ${TASK_TYPE} task(s) failed, ${skipped_count} not executed (skipped)." >&2
    else
      echo "⚠️  ${failed} ${TASK_TYPE} task(s) failed." >&2
    fi
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

report_discarded_output_paths() {
  local entry cli persp f reported=false
  # Only name files that were actually written. A failed task can leave no file,
  # and telling the user to preserve a path that does not exist hides that fact.
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    cli="${entry%%:*}"
    persp="${entry#*:}"
    f="${OUTPUT_DIR}/${cli}/${persp}.md"
    [[ -f "$f" ]] || continue
    if [[ "$reported" == "false" ]]; then
      echo "   The discarded per-task results are kept as evidence — read them before anything else:" >&2
      reported=true
    fi
    printf '     %s\n' "$f" >&2
  done <<< "$EXECUTION_PLAN"
  if [[ "$reported" == "true" ]]; then
    echo "   Re-running clears these files first, so read or copy them now." >&2
  fi
}

# ── 除外に一致した変化の報告（Issue #747） ──
#
# 除外パス配下の変化は判定から消えるが、**黙って消してはいけない** — 実行ログから
# 「ガードが緩んだのか、本当に何も変わっていないのか」を区別できなくなる
# （merge-cleanup の report_ignored_changes と同じ原則）。判定後に status を
# 肯定形の同じパターンで引き直し、件数と一覧を出す:
#   - 利用者指定（FF_MULTI_AGENT_IGNORE_PATHS）… 一致 0 件でもその旨を出す。
#     「設定したのに何も変わらない」の原因がパターンの書き間違いだと分かるように
#   - 既定（.superpowers/**）… 一致があるときだけ 1 行 + 一覧。無いのが通常なので
#     毎回のログを占有しない
# status の失敗は非 0 で返す — 呼び出し側（verify_repo_unchanged）が破棄へ倒す。
# 「除外した中身を確認できない」は「除外が正しく効いたか分からない」と同じで、
# 分からないまま成功を名乗るのはこのガードが塞いでいる silent failure そのもの。
report_ignored_tree_changes() {
  [[ "$IN_GIT_REPO" == "true" ]] || return 0
  local root ignored count
  if ! root="$(cd "$REPO_ROOT" 2>/dev/null && pwd -P)"; then
    echo "ERROR: cannot resolve the repository root to list ignored tree changes." >&2
    return 1
  fi
  if [[ "${#IGNORE_MATCH_PATHSPECS[@]}" -gt 0 ]]; then
    # 全体一致の :(top) を先頭に置いてから肯定形を並べる意味は無い（こちらは除外では
    # なく選択）。CWD 相対に縮まないよう root へ cd してから引く（capture_repo_snapshot
    # と同じ理由）。
    if ! ignored="$(cd "$root" && git status --porcelain -- "${IGNORE_MATCH_PATHSPECS[@]}")"; then
      echo "ERROR: cannot list the changes matched by FF_MULTI_AGENT_IGNORE_PATHS." >&2
      return 1
    fi
    if [[ -z "$ignored" ]]; then
      echo "ℹ️ No uncommitted changes match FF_MULTI_AGENT_IGNORE_PATHS (patterns are repo-root-relative globs: '${FF_MULTI_AGENT_IGNORE_PATHS:-}')" >&2
    else
      count="$(printf '%s\n' "$ignored" | wc -l | tr -d ' ')" || {
        echo "ERROR: cannot count the changes matched by FF_MULTI_AGENT_IGNORE_PATHS." >&2
        return 1
      }
      echo "ℹ️ Excluded from the tree-change check: ${count} path(s) matched FF_MULTI_AGENT_IGNORE_PATHS" >&2
      printf '%s\n' "$ignored" | sed 's/^/  - /' >&2 || {
        echo "ERROR: cannot print the changes matched by FF_MULTI_AGENT_IGNORE_PATHS." >&2
        return 1
      }
    fi
  fi
  if ! ignored="$(cd "$root" && git status --porcelain -- ":(glob,top)${IGNORE_PATHS_DEFAULT}")"; then
    echo "ERROR: cannot list the changes matched by the default ignore pattern '${IGNORE_PATHS_DEFAULT}'." >&2
    return 1
  fi
  if [[ -n "$ignored" ]]; then
    count="$(printf '%s\n' "$ignored" | wc -l | tr -d ' ')" || {
      echo "ERROR: cannot count the changes matched by the default ignore pattern '${IGNORE_PATHS_DEFAULT}'." >&2
      return 1
    }
    echo "ℹ️ Default exclusion '${IGNORE_PATHS_DEFAULT}' kept ${count} changed path(s) out of the tree-change check" >&2
    printf '%s\n' "$ignored" | sed 's/^/  - /' >&2 || {
      echo "ERROR: cannot print the changes matched by the default ignore pattern '${IGNORE_PATHS_DEFAULT}'." >&2
      return 1
    }
  fi
  return 0
}

verify_repo_unchanged() {
  local after
  if ! after="$(capture_repo_snapshot "$(output_dir_repo_relative)" "${IGNORE_EXCLUDE_PATHSPECS[@]}")"; then
    echo "" >&2
    echo "❌ Cannot read the repository state after the run — discarding the result." >&2
    echo "   The baseline was taken, so this is a failure to verify, not a clean run:" >&2
    echo "   nothing here can confirm the reviewed revision stayed put. Reporting an" >&2
    echo "   unverifiable run as valid is the exact failure this guard exists to prevent." >&2
    mark_outputs_discarded
    echo "   No report was generated; this run's per-task results are marked DISCARDED." >&2
    report_discarded_output_paths
    echo "   Re-run once the repository is settled." >&2
    return 1
  fi

  # 除外に一致した変化を名指しする（黙って無視しない）。この一覧が取れないなら、
  # 除外が正しく効いたかどうかも確認できていない — スナップショット不能と同じく
  # fail-closed で破棄する（Issue #747）。
  if ! report_ignored_tree_changes; then
    echo "" >&2
    echo "❌ Cannot list the changes excluded from the tree-change check — discarding the result." >&2
    echo "   Without that listing there is no way to confirm the exclusion worked as" >&2
    echo "   configured, so this run cannot be verified (same as an unreadable snapshot)." >&2
    mark_outputs_discarded
    echo "   No report was generated; this run's per-task results are marked DISCARDED." >&2
    report_discarded_output_paths
    echo "   Re-run once the repository is settled." >&2
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
  report_discarded_output_paths
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

# ── CLI 側の失敗理由の切り分け（Issue #659） ──
#
# Issue #1148 で 3 つ目の分類 `argv` を足した。プロンプトは Issue #712 以降 argv に
# 乗らない（materialize_prompt_file → stdin / --prompt-file）ので、E2BIG は
# 「diff が大きいから」では起きなくなったが、起きたときの 1 行が
# 「exit code: 126」だけだと、CLI 側のクラッシュと区別が付かない。実測（公開
# feel-flow/ff-dev-toolkit#55、0.36.0 / macOS ARG_MAX 1,048,576 に 2,129,295 バイトの
# diff）では 3 CLI が同じ行で落ち、利用者は --timeout を延ばす方向へ倒れた —
# 起動前に失敗しているので時間では直らない。分類を持てば「起動できていない」と
# 名指しできる。
#
# 実測（1 セッションで 3 回の失敗 dispatch）: codex の OAuth 切れ（401、websocket
# 再接続 5 回のあと失敗）→ 再ログイン後にクレジット切れ（"Your workspace is out of
# credits"）→ grok の 402（"Grok Build usage balance exhausted"）。どれも「時間を
# 足しても直らない失敗」として同じ 1 行に丸められるため、**認証を直せば同じ CLI で
# 続けられる**のか**この CLI では今日もう何も走らない**のかが読めず、代替 CLI へ
# 切り替える判断が 3 往復ぶん遅れた。
#
# なぜ dispatch 前の preflight probe を採らなかったか（Issue #659 の提案そのもの）。
# 4 CLI の実提供機能を実測して判断した:
#   codex-cli   … `codex login status` あり。保存済み資格情報を読んで
#                 "Logged in using ChatGPT" / "Not logged in"（rc=1）を返す
#   claude-code … `claude auth status` あり。保存済み資格情報を JSON
#                 （loggedIn / authMethod / subscriptionType）で返す
#   grok-cli    … status 系サブコマンド無し（`login` / `logout` のみ）= probe 対象外
#   copilot-cli … 同上（`login` のみ。`copilot help billing` は静的なヘルプ話題）
# 決め手は 2 つ。(1) **残高・クレジットを報告する手段がどの CLI にも無い** —
# 実測 3 件のうち 2 件（workspace out of credits / usage balance exhausted）は
# 課金される API 呼び出しをしない限り観測できず、それを preflight でやるのは
# 「レビュー 1 回ごとに余計な API 呼び出しをしない」という本 Issue の制約そのものを
# 破る。(2) 残る 1 件（OAuth 切れ）も上の 2 コマンドでは陰性になる — どちらも
# **保存されている**資格情報を読むだけで、サーバ側で失効した token を "logged in" と
# 報告する（実測 0.16s / 0.23s。ネットワーク往復を含む所要ではない）。つまり probe が
# 陽性を返せるのは「一度もログインしていない」という利用者が既に知っている状態だけで、
# 実測した 3 件のどれも捕まえられない。4 CLI 中 2 つは probe 自体が無いので、いずれに
# せよ失敗側の切り分けが必要になる。
#
# そこで preflight ではなく**失敗時の切り分け**で AC を満たす。判定材料は成果物に
# 保全済みの CLI stderr（adapter-common.sh の fail_cli_task が `### CLI stderr` 節へ
# 書く）だけで、追加のプロセスもネットワークも課金も発生しない。
#
# 走査は stderr 節に限る。ファイル全体を見ると、レビュー本文が引用した "401" や
# "credits" で誤判定する（この成果物は失敗した実行の**部分出力**を保全している）。
# **🔑 / 💳 が出ないことは「認証・課金の問題ではない」の証拠にはならない。** stderr の
# 抜粋は末尾 4KB に頭打ちされる（adapter-common.sh の tail -c）ので、再接続リトライで
# 末尾が埋まった回は先頭の 401 が抜粋外に落ちる。分類は「出たら手がかり」であって
# 「出なければ無関係」ではない — 陰性を根拠に切り分けを打ち切らないこと。
#
# 判定不能は空文字を返す = 従来どおりの案内に落ちる fail-open。誤った断定は
# 「認証を直しに行ったが実際はクラッシュだった」形の遠回りを生むので、
# 迷ったら分類しない側へ倒す。
## ── モデル側のプロンプト超過（公開 feel-flow/ff-dev-toolkit#95）──
#
# 5 つ目の分類 `prompt-too-long`。E2BIG（`argv`）が「OS が起動を拒んだ」なのに対し、
# こちらは「CLI は起動してモデルへ送ったが、モデルがリクエストごと拒否した」形で、
# 実測（公開 #95、`git diff origin/develop | wc -c` = 8,048,710 / 525 files）では
# 3 CLI が同時に落ちた。auth / billing / argv と違うのは**原因が CLI 側ではなく
# レビュー対象側にある**点で、同じ CLI を再実行しても代替 CLI へ振っても直らない。
#
# 出力先と文言が CLI ごとに違うので、走査面を 2 つ持つ:
#   codex-cli   … stderr。API 由来の拒否をそのまま stderr へ流す（実測: stdout が
#                 空で stderr にだけ材料が出た）。stderr 節は CLI 自身のチャネル
#                 なので、auth / billing と同じく無条件の語彙照合でよい。
#   claude-code … stdout。`API Error: 400 {"type":"error","error":
#                 {"type":"invalid_request_error","message":"Prompt is too long…"}}`
#                 の形で出て、成果物では「部分出力」として保全される（実測: 公開
#                 #95 の 3 CLI のうち claude-code はこの形だった）。
#   grok-cli / copilot-cli … 本 Issue の時点で超過の実測を再現できていない。両者とも
#                 上流 API のエラーメッセージを素通しするので、同じ語彙表
#                 （context length / token limit / too long）で拾える見込みだが、
#                 **見込みであって実測ではない**。外れた回は空文字＝従来案内へ落ちる。
#
# **語彙だけでは判定しない。** どちらの走査面にも、その語を「話題として」書いた行が
# 混ざる — 保全されるのはレビュー本文であり（このリポジトリのソース・docs・テストは
# 現にその語を含む）、stderr にも進捗・デバッグ行が流れる。そこで語彙を 2 段に割り、
# 面ごとに要求を変える:
#
#   canonical … `prompt is too long` / `prompt too long`。モデルの拒否文そのもので、
#               他の意味で書かれることが実質ない。stderr 側では単独で採る。
#   broad     … context length / input too large / token limit 等。単独では日常語に
#               近いので、**同じ行に API エラーらしさの語**が並ぶことを要求する。
#
# `token limit` はとくに危険で、`monthly token limit`（= プラン・残高の上限）が同じ語を
# 使う。プロンプト長の話であることを示す `context` / `prompt` / `input` が同じ行に
# 並ぶことを追加で要求し、billing の材料を奪わない。
#
# 部分出力（stdout）側はさらに**行の形**でも絞る。実測の claude-code 形は
# `API Error: 400 {...}` のように行頭がエラーの体裁になっており、レビュー本文の
# 箇条書き（`- Suggestion: … prompt is too long …`）はそうならない。行頭アンカーを
# 掛けてから語彙と文脈語を見ることで、この suite 自身の fixture のような「生きた
# 誤診源」を構造で外す。閉じた側の代償は偽陰性 = 従来案内で、これは今日の挙動と同じ。
_PROMPT_TOO_LONG_CANONICAL_RE='prompt is too long|prompt too long'
_PROMPT_TOO_LONG_RE='prompt is too long|prompt too long|input is too long|input too large|request too large|too many tokens|context_length_exceeded|request_too_large|(maximum|max) context (length|window)|context (length|window) (exceeded|limit)|exceeds? the ((model|models|model.s) )?context (window|length)|(context|prompt|input).*token limit|token limit.*(context|prompt|input)'
# 「その行が API のエラーとして出た」ことの目印。canonical 以外の語彙は、これと同じ行に
# 並ぶことを要求する（stderr 側・部分出力側の共通条件）。
_PROMPT_TOO_LONG_CONTEXT_RE='api error|invalid_request_error|request_too_large|context_length_exceeded|invalid request|bad request|refused|rejected|too large|\berror\b|error[^a-z0-9]{0,4}(400|413)|(http|status|code)[^0-9]{0,10}(400|413)'
# 部分出力側でだけ掛ける行頭アンカー。CLI / API が吐いたエラー行の体裁を列挙する。
# レビュー本文の箇条書き・散文・引用（`- `, `> `, `  1. ` 等）はここで落ちる。
_PROMPT_TOO_LONG_ERRLINE_RE='^[[:space:]]{0,4}(api error|stream error|error|fatal|request failed|unhandled|\{"(type|error)"|\[error\])'

# 語彙照合の本体。面によって要求を変える。
#   stderr  … canonical は単独可（CLI 自身のチャネルで、そこに拒否文がそのまま出る）。
#             それ以外の語彙は文脈語との同一行共起を要求する。
#   partial … 行頭がエラーの体裁である行だけに絞ってから、**canonical も含めて**
#             文脈語との同一行共起を要求する。保全されるのはレビュー本文なので、
#             canonical をそのまま引用した行が来うるため。
# grep を 2 段のパイプにしないのは、前段が早期終了で EPIPE を受けて pipefail 下の
# rc=141 が「不一致」に化けるため（argv / billing の項と同じ理由）。
prompt_too_long_matches() { # <text> <stderr|partial> → rc 0 で一致
  local text="$1" surface="$2" both err_lines
  both="((${_PROMPT_TOO_LONG_RE}).*(${_PROMPT_TOO_LONG_CONTEXT_RE}))|((${_PROMPT_TOO_LONG_CONTEXT_RE}).*(${_PROMPT_TOO_LONG_RE}))"
  if [[ "$surface" == "stderr" ]]; then
    grep -qiE "$_PROMPT_TOO_LONG_CANONICAL_RE" <<<"$text" && return 0
    grep -qiE "$both" <<<"$text" && return 0
    return 1
  fi
  err_lines="$(grep -iE "$_PROMPT_TOO_LONG_ERRLINE_RE" <<<"$text")" || return 1
  [[ -n "$err_lines" ]] || return 1
  grep -qiE "$both" <<<"$err_lines" && return 0
  return 1
}
classify_cli_failure_cause() { # <result-file> → "auth" | "billing" | "argv" | "prompt-too-long" | ""
  local file="$1" stderr_section="" partial_section=""
  [[ -f "$file" ]] || return 0
  # アダプタが**末尾へ**付ける stderr 節の、コードフェンスの中身だけを取る。
  # 最初の `### CLI stderr` から EOF まで取ると、保全された部分出力がその見出しを
  # 引用している回（このリポジトリのレビュー結果は現にこの文字列を書く）に、
  # レビュー本文の "401" や "credits" を stderr と誤読して分類が化ける。
  # 見出しは最後の一致を使い、その直後のフェンスで閉じた範囲だけを見る。
  stderr_section="$(awk '
    /^### CLI stderr/ { start = NR }
    { line[NR] = $0 }
    END {
      if (!start) exit 0
      infence = 0
      for (i = start + 1; i <= NR; i++) {
        if (line[i] ~ /^```/) { if (infence) break; infence = 1; continue }
        if (infence) print line[i]
      }
    }' "$file" 2>/dev/null)" || return 0

  # stderr 節が無くても打ち切らない。プロンプト超過は stdout 側にだけ出る CLI 形
  # （claude-code）があり、ここで return すると実測 2 形のうち片方を構造的に拾えない。
  if [[ -n "$stderr_section" ]]; then
    # exec 段の失敗を最初に見る（Issue #1148）。E2BIG は CLI が**起動する前**に
    # execve が返す失敗なので、そのとき stderr にはモデルの応答が 1 バイトも無い。
    # auth / billing の語彙と競合しないが、順序で意味を固定する — 起動できなかった
    # 実行を「認証が拒否された」と読ませないため。
    # 語は execve の失敗をシェル / libc が訳したもので、ロケールで揺れる。実測した
    # 英語形（bash / zsh の "Argument list too long"）に加えて E2BIG も拾う。
    # 拾えなかった回は空文字 = 従来の案内に落ちるだけで、断定はしない。
    if grep -qiE 'argument list too long|\bE2BIG\b' <<<"$stderr_section"; then
      printf 'argv\n'
      return 0
    fi

    # プロンプト超過は残高・認証より**先**に見る。順序を決めた根拠は 3 つ:
    #   1. 語彙が重ならない。canonical は拒否文そのもので、broad 側は 400 / 413 系の
    #      文脈語を要求する。billing（402 / credits）・auth（401 / credentials）とは
    #      交わらず、`monthly token limit` は文脈語の要求で ptl 側へ落ちない。
    #   2. 狭めた語彙を**検査の効く位置**に残せる。billing を先に評価すると、語彙が
    #      緩む退行が起きても billing が先に当たって症状が隠れ、テストが緑のまま通る
    #      （実測: `token limit` を素の語へ戻す変異は、この順序でのみ赤になる）。
    #   3. 意味の順序としても「そもそも受け付けられたか」が「誰の資格で送ったか」より先。
    if prompt_too_long_matches "$stderr_section" stderr; then
      printf 'prompt-too-long\n'
      return 0
    fi

    # 残高側を先に見る。クレジット切れの応答は認証の語（unauthorized 等）を含みうるが、
    # 逆は起きない。取り違えると「再ログインすれば直る」と案内して、実際には同じ失敗を
    # もう一度引かせることになる。
    #
    # 数値ステータスは単独では見ない（stderr 抜粋に現れる "402 files" のような無関係な
    # 数字を拾う）。HTTP 文脈の語と同じ行に並んでいるときだけ採る。
    # パイプにしないのは `set -o pipefail` 下で grep -q が先頭付近で早期終了すると
    # printf が EPIPE で死に、パイプライン rc=141 が「不一致」に化けるため（実測: 先頭に
    # unauthorized を置いた 640KB 入力が LOST）。真陽性が読み解けない形で落ちる。
    if grep -qiE \
      'out of credits|no credits|insufficient credit|credit balance|balance exhausted|insufficient_quota|payment required|(http|status|code)[^0-9]{0,10}402|402[^0-9]{0,12}(payment|http|status)' <<<"$stderr_section"; then
      printf 'billing\n'
      return 0
    fi
    if grep -qiE \
      'unauthorized|not logged in|not signed in|authentication (failed|error)|invalid api key|invalid_api_key|expired (token|credential)|token (is |has )?expired|please (log ?in|sign in)|re-?authenticate|(http|status|code)[^0-9]{0,10}401|401[^0-9]{0,12}(unauthorized|http|status)' <<<"$stderr_section"; then
      printf 'auth\n'
      return 0
    fi
  fi

  # ── 部分出力側（claude-code 形）──
  # 走査範囲は最後の `### CLI stderr` 見出しより**手前**、つまりバナーと保全された
  # 部分出力。stderr 節を含めないのは二重走査を避けるためで、そちらは既に上で見た。
  partial_section="$(awk '
    { line[NR] = $0; if ($0 ~ /^### CLI stderr/) last = NR }
    END {
      end = last ? last - 1 : NR
      for (i = 1; i <= end; i++) print line[i]
    }' "$file" 2>/dev/null)" || return 0
  [[ -n "$partial_section" ]] || return 0
  # エラー行の体裁を持つ行に絞ってから、語彙と文脈語が**同じ行**に並ぶことを要求する。
  # 語彙の位置関係は決め打ちしない（`API Error: 400 … "Prompt is too long"` も
  # `prompt is too long (invalid_request_error)` も同じ事実）。
  if prompt_too_long_matches "$partial_section" partial; then
    printf 'prompt-too-long\n'
    return 0
  fi
  return 0
}

# ── レビュー対象 diff の実測値（公開 feel-flow/ff-dev-toolkit#95）──
#
# プロンプト超過の案内に添える材料。オーケストレータは既にこの実行の diff を
# 1 ファイルへ固定している（create_fixed_diff）ので、そのバイト列を数えるのが
# **実際にプロンプトへ載ったもの**の唯一正しい実測になる。実行後に diff を
# 取り直すと、レビュー中に作業ツリーが動いた回に別の数字を報告する。
#
# **固定 diff が無い経路（--include-diff なしの explore / implement）では測らない。**
# numstat へ落ちると「送っていない diff」のファイル数を、送ったものとして名指しする
# ことになる。空文字を返し、呼び出し側の「no fixed diff for this task type」分岐へ渡す。
#
# **計測は親シェルで 1 回だけ。** 値を返す関数を `$(...)` で呼ぶと、command
# substitution は subshell なのでキャッシュが親へ残らず、失敗タスクごとに固定 diff を
# 舐め直す（実測の diff は 8,048,710 bytes）。出力側は ensure_diff_size_summary を
# 呼んでから **$DIFF_SIZE_SUMMARY を直接読む**。
DIFF_SIZE_SUMMARY=""
DIFF_SIZE_SUMMARY_COMPUTED=false
ensure_diff_size_summary() { # DIFF_SIZE_SUMMARY を "N bytes across M changed file(s)" | "" にする
  [[ "$DIFF_SIZE_SUMMARY_COMPUTED" == "true" ]] && return 0
  DIFF_SIZE_SUMMARY_COMPUTED=true
  local bytes="" files=""
  [[ -n "$FIXED_DIFF_FILE" && -r "$FIXED_DIFF_FILE" ]] || return 0
  bytes="$(wc -c < "$FIXED_DIFF_FILE" 2>/dev/null | tr -d '[:space:]')" || bytes=""
  # 読めなかった回に 0 と書くと、観測していないものを観測したことにする。
  [[ "$bytes" =~ ^[0-9]+$ ]] || return 0
  # 固定 diff は `BASE...HEAD` と作業ツリー分の**連結**（get_diff_content）なので、
  # 両方に現れたファイルはヘッダー行が 2 度出る。素の件数だとそれを 2 個と数え、
  # 案内が実際より大きなファイル数を名指しする。ヘッダー行はパス対ごとに一意なので、
  # 行を dedup してから数えれば distinct なファイル数になる。
  # `grep` は 0 件で rc=1 を返す（= 変更 0 件という正当な観測）ので rc は見ない。
  files="$( { grep '^diff --git ' "$FIXED_DIFF_FILE" 2>/dev/null || true; } | sort -u | wc -l | tr -d '[:space:]')" || files=""
  if [[ "$files" =~ ^[0-9]+$ ]]; then
    DIFF_SIZE_SUMMARY="${bytes} bytes across ${files} changed file(s)"
  else
    DIFF_SIZE_SUMMARY="${bytes} bytes (changed-file count not measured)"
  fi
  return 0
}
# この実行が「プロンプト超過で全滅した」と言ってよいか（公開 feel-flow/ff-dev-toolkit#95）。
#
# 全滅は個別の失敗の集合ではなく 1 つの事実 —「レビュー対象が大きすぎる」。個別の
# 再実行コマンドだけを並べると、利用者は CLI を 1 つずつ試す方向へ倒れる（実測では
# 原因に辿り着くまで 3 回分の実行を空費した）。全滅を検出できたときだけ、再実行
# コマンドより**先に**対象側を見よと言う。
#
# 条件は「全 executed task が prompt-too-long に分類された」ではない。それだと、
# 動機になった事故（codex が stdout 空 + stderr に diff 断片だけを残した回）で
# 案内が出ない — 分類器が材料不足で空文字を返した 1 タスクが、他の全タスクが
# 名指しで超過を言っていても案内を丸ごと消してしまう。そこで:
#
#   - prompt-too-long が 1 件以上（言うべき事実が実在する）
#   - **別原因**に分類された task が 0（auth / billing / argv が混ざっていれば全滅ではない）
#   - 成功 0 / skip 0（走って通った観点、走らなかった観点があれば全滅ではない）
#   - 分類不能（空文字）は阻害しない。**別原因ではない** — 材料が無いだけで、
#     それを「違う原因だった」と読むのは観測していないことの断定になる
#   - rc=124（時間切れ）の task は集計から外し、かつ全滅とは言わない。個別層は
#     124 に対して原因を断定しない（print_failure_advice は cause を空へ倒す）ので、
#     run-wide が代わりに断定してはいけない。時間切れた観点は「送る前に断られた」
#     とは限らず、途中まで走っていた可能性が残る
#
# 分母は「この実行が走らせたタスク」。前回結果を再利用したタスク（REUSED_TASKS）は
# 除く — 走っていないものの成否で全滅判定を左右させない。
prompt_too_long_run_wide() {
  [[ -n "$FAILED_TASKS" ]] || return 1
  # スキップは実行の欠落。今日はスキップの理由が auth / billing に限られるため下の
  # 別原因判定でも落ちるが、条件としては独立に持つ（スキップ可能な原因が増えたとき、
  # 「走らなかった観点があるのに全滅と言う」形が静かに開かないように）。
  [[ -z "$SKIPPED_TASKS" ]] || return 1
  [[ -n "$EXECUTION_PLAN" ]] || return 1
  local entry cli persp seen="" hits=0 cause rc
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    if [[ " $seen " == *" $entry "* ]]; then continue; fi
    seen="$seen $entry"
    cli="${entry%%:*}"
    persp="${entry#*:}"
    if list_contains "$REUSED_TASKS" "${cli}/${persp}"; then continue; fi
    # 成功したタスクが 1 つでもあれば全滅ではない
    task_left_perspective_unproven "$cli" "$persp" || return 1
    rc="$(failed_task_rc "$cli" "$persp")"
    [[ "$rc" == "124" ]] && return 1
    cause="$(classify_cli_failure_cause "${OUTPUT_DIR}/${cli}/${persp}.md")"
    case "$cause" in
      prompt-too-long) hits=$((hits + 1)) ;;
      "") : ;;   # 分類不能。別原因ではないので阻害しない
      *) return 1 ;;
    esac
  done <<< "$EXECUTION_PLAN"
  [[ "$hits" -gt 0 ]]
}

# 失敗として記録された rc（FAILED_TASKS は `<cli>/<persp>:<rc>` 形）。記録が無ければ空。
failed_task_rc() { # <cli> <perspective>
  local entry prefix="${1}/${2}:"
  for entry in $FAILED_TASKS; do
    if [[ "$entry" == "$prefix"* ]]; then
      printf '%s\n' "${entry##*:}"
      return 0
    fi
  done
  return 0
}
# 全滅時の案内本文。stdout（stderr ストリーム）と統合レポートの両方が同じ文面を使う
# — 片方だけに置くと、レポート経由で結果を読む消費者か、端末を見ている利用者の
# どちらかがこの 1 事実を受け取り損ねる。
prompt_too_long_advice_lines() {
  # 呼び出し側（親シェル）が ensure_diff_size_summary を済ませている前提。この関数は
  # process substitution 越しに呼ばれるので、ここで計測してもキャッシュが親へ残らない。
  local size="$DIFF_SIZE_SUMMARY"
  echo "Every task in this run was refused by the model for the same reason: the prompt"
  echo "was too long. Look at the reviewed diff first — re-running a CLI, giving it more"
  echo "time, or switching to the substitute CLI does not change what is being sent."
  if [[ -n "$size" ]]; then
    echo "Reviewed diff: ${size}."
  else
    echo "Reviewed diff: size could not be measured (no fixed diff for this task type)."
  fi
  echo "A diff that size is usually an accident rather than a change set: check whether"
  echo "large untracked files or build artifacts were swept into it — an earlier run's"
  echo "archived results under ${OUTPUT_DIR}/.prev-<timestamp>/ are a known source — and"
  echo "that .gitignore covers them. Shrink what is reviewed (or pass a different"
  echo "--base), then re-run."
}

# 失敗した観点の**成果物**へ実測値を書き足す（公開 feel-flow/ff-dev-toolkit#95 の AC）。
#
# アダプタは自分が拒否された理由（プロンプト超過）を保全するが、**何バイト送ったのか**
# は知らない — diff を固定したのはオーケストレータ側だから。成果物を単体で開いた
# 読み手（レポートではなく `.review-results/<cli>/<persp>.md` を見る側）が、そこで
# `git diff | wc -c` を手で打たずに済むように、持っている実測値をここで添える。
#
# 追記位置は末尾。ヘッダーの `Status: incomplete` 判定は空行までの窓しか見ないので
# 影響せず、保全された部分出力と CLI stderr 節も書き換えない（観測の改変はしない）。
# 書けなかった場合は警告して続行する — 案内が 1 行減るだけで、stdout とレポートの
# 同じ材料は残る。
annotate_result_prompt_too_long() { # <result-file>
  local file="$1" size
  [[ -f "$file" && -w "$file" ]] || return 0
  # 二重追記を避ける（同じ実行内で 2 回呼ばれることは無い想定だが、追記は冪等に）。
  grep -qF -- '<!-- prompt-too-long-diagnosis -->' "$file" && return 0
  ensure_diff_size_summary
  size="$DIFF_SIZE_SUMMARY"
  [[ -n "$size" ]] || return 0
  {
    echo ""
    echo "<!-- prompt-too-long-diagnosis -->"
    echo "### Why this failed: the prompt was too long"
    echo ""
    echo "The model refused the request itself, so nothing was looked at. The size of what"
    echo "this run sent for review, measured from the diff this run fixed for every task:"
    echo ""
    echo "- reviewed diff: ${size}"
    echo ""
    echo "Re-running this CLI, giving it more time, or switching to the substitute CLI"
    echo "sends the same bytes. Shrink what is under review instead."
  } >> "$file" || echo "WARNING: could not annotate the result file with the diff size: ${file}" >&2
  return 0
}

# 分類値を英文へ差し込む名詞句。分類値をそのまま埋めると "a auth problem" /
# "a argv problem" になる。分類を足すたびに文面が壊れるのを避けるため、語形は
# ここに 1 箇所だけ置く。未知の値でも文として成立する既定を返す（分類の追加漏れが
# 案内行の消失や壊れた英文にならないように）。
cause_phrase() { # <cause> → 英文へ差し込む名詞句
  case "$1" in
    auth)    echo "an authentication problem" ;;
    billing) echo "a credits / usage balance problem" ;;
    argv)    echo "an argument-list-too-long (E2BIG) failure, i.e. the CLI never started" ;;
    prompt-too-long)
             echo "a prompt-too-long rejection from the model, i.e. the request was refused before any ${TASK_TYPE:-review} happened" ;;
    *)       echo "a problem it names itself" ;;
  esac
}

# 再ログインの入口は CLI ごとに違う（実測: codex / grok / copilot は `<cmd> login`、
# claude は `claude auth login`）。レジストリ（ALL_CLIS の lockstep lookup）には置かない
# — 全 CLI が答えを持つ表ではなく、既定の空文字は「案内行を 1 本出さない」という
# 無害な縮退だから。書き漏らしても診断そのものは出る。
cli_login_command() { # <cli>
  case "$1" in
    claude-code) echo "claude auth login" ;;
    codex-cli)   echo "codex login" ;;
    copilot-cli) echo "copilot login" ;;
    grok-cli)    echo "grok login" ;;
    *) echo "" ;;
  esac
}

# ── Retry Advice For Failed Tasks ──
# A failed task is never re-dispatched to another CLI (see "Fallback semantics"
# in the header). That is only a defensible default if the user is handed the
# commands they would otherwise have wanted the tool to run behind their back,
# so print them: same CLI with more time, or the configured substitute — named
# explicitly, with its cost tier, as a choice rather than a surprise.
print_failure_advice() {
  # スキップは FAILED_TASKS に載せない（実行していないものを「終了コード付きの失敗」
  # として記録すると、rc を読む全分岐が 4 つ目の意味を持つことになる）。案内は必要
  # なので、両方の一覧を走査対象にする（Issue #1143）。
  [[ -n "${FAILED_TASKS}${SKIPPED_TASKS}" ]] || return 0

  # Absolute path, not basename: this script normally lives inside an installed
  # plugin and is invoked from the target project, where no same-named file
  # exists. A bare `bash multi-agent.sh ...` would fail the moment it is pasted.
  # shell_quote keeps a path with spaces runnable, and unlike printf %q it is
  # byte-transparent, so a non-ASCII --description survives a non-UTF-8 locale as
  # valid UTF-8 (see the shell_quote header for the measurement).
  local self
  self="bash $(shell_quote "${SCRIPT_DIR}/multi-agent.sh") --task ${TASK_TYPE}"
  # Carry the flags that decide WHAT gets looked at. Dropping --base would retry
  # against a different diff than the run that just failed, which makes the
  # suggested command quietly not-a-retry.
  if [[ "$STAGED_DIFF" == "true" ]]; then
    self="${self} --staged"
  elif [[ "$TASK_TYPE" == "review" || "$INCLUDE_DIFF" == "true" ]]; then
    self="${self} --base $(shell_quote "$BASE_BRANCH")"
  fi
  if [[ "$INCLUDE_DIFF" == "true" ]]; then
    # Without this the retry builds a prompt with no diff in it — a different task,
    # not a retry of the one that failed.
    self="${self} --include-diff"
  fi
  if config_is_explicit; then
    self="${self} --config $(shell_quote "$CONFIG_FILE")"
  fi
  if [[ "$OUTPUT_DIR_EXPLICIT" == "true" ]]; then
    self="${self} --output-dir $(shell_quote "$OUTPUT_DIR")"
  fi
  if [[ -n "$DESCRIPTION" ]]; then
    self="${self} --description $(shell_quote "$DESCRIPTION")"
  fi

  # 全滅した prompt-too-long は、個別の再実行コマンドより**先に**出す（公開
  # feel-flow/ff-dev-toolkit#95）。順序が案内そのもの — 後ろに置くと、読み手は先頭の
  # 再実行コマンドを打ってから原因に辿り着く。
  if prompt_too_long_run_wide; then
    local ptl_line ptl_prefix="   📐 "
    ensure_diff_size_summary
    echo "" >&2
    while IFS= read -r ptl_line; do
      echo "${ptl_prefix}${ptl_line}" >&2
      ptl_prefix="      "
    done < <(prompt_too_long_advice_lines)
  fi

  echo "" >&2
  echo "   No runtime fallback was attempted (by design: swapping the model changes" >&2
  echo "   what got reviewed, and the substitute may bill a costlier tier)." >&2
  echo "   Re-run the failed task(s) yourself:" >&2

  local entry task rc cli persp fb fb_tier cause login_cmd skip_cause
  for entry in $FAILED_TASKS $SKIPPED_TASKS; do
    task="${entry%:*}"
    rc="${entry##*:}"
    cli="${task%%/*}"
    persp="${task#*/}"
    echo "" >&2
    # 認証切れ / 残高切れの切り分け（Issue #659）。retry コマンドの**前**に出す —
    # 「どちらでもない」失敗と同じ 1 行に丸めると、再ログインで直るのか、この CLI
    # では今日もう何も走らないのかが読めず、代替 CLI への切替判断が遅れる。
    # timeout（124）でも分類は**する**が、断定はしない。実測 1 件目（401 → websocket
    # 再接続 5 回 → 失敗）は短い --timeout なら容易に 124 側へ倒れ、そこで切り分けを
    # 完全に抑止すると「時間を倍にせよ」だけが出る — 同じ失敗を倍待たせる案内で、
    # まさに下の分岐が避けているものになる。補足として出し、判断は利用者に渡す。
    # スキップしたタスクは「失敗」ではなく「実行していない」。下の分岐は成果物の
    # stderr を判定材料にするが、スキップには成果物が無いので、そのまま流すと
    # 「結果ファイルが書かれていない（orchestrator 起因）」という別の失敗として
    # 案内され、読み手は存在しないクラッシュを追う（Issue #1143）。
    skip_cause="$(skipped_task_cause "$task")"
    # スキップは失敗の分類・rc 由来の案内を一切通さない。cause も明示的に空へ倒す
    # （前の反復の値が残ると、実行していないタスクに 🔑 / 💳 / 📏 が付く）。
    if [[ -n "$skip_cause" ]]; then
      cause=""
      echo "     ⏭ ${task} — not executed. ${cli} had already failed in this run with" >&2
      echo "        $(cause_phrase "$skip_cause"), which is a property of the CLI and not of" >&2
      echo "        the task: every remaining task on ${cli} would have failed identically." >&2
      echo "        Fix that first (see the ${cli} entry above), then re-run:" >&2
      echo "       $(model_env_prefix "$cli")${self} --cli ${cli} --perspective ${persp}" >&2
    else
    cause="$(classify_cli_failure_cause "${OUTPUT_DIR}/${cli}/${persp}.md")"
    if [[ "$rc" -eq 124 && -n "$cause" ]]; then
      echo "     ⏱ ${cli} — hit the time limit, but its stderr also shows $(cause_phrase "$cause")." >&2
      echo "        Check that first: more time does not fix what the stderr is reporting." >&2
      cause=""   # 断定はしない。下の 🔑 / 💳 / 📏 は時間切れでない失敗のためのもの
    fi
    case "$cause" in
      auth)
        echo "     🔑 ${cli} — the CLI stderr says its credentials were rejected, not that it" >&2
        echo "        ran out of time. Re-running as-is will fail identically." >&2
        login_cmd="$(cli_login_command "$cli")"
        if [[ -n "$login_cmd" ]]; then
          echo "        Re-authenticate first: ${login_cmd}" >&2
        else
          # 表に無い CLI（新規追加で書き漏らした場合を含む）でも助言を行き止まりに
          # しない。具体的な入口が無いことと、次に何を探せばよいかは別。
          echo "        Re-authenticate with ${cli}'s own login command first." >&2
        fi
        ;;
      billing)
        echo "     💳 ${cli} — the CLI stderr says its credits / usage balance are exhausted." >&2
        echo "        No amount of retrying or extra time changes that; either restore billing" >&2
        echo "        for this CLI or use the substitute below." >&2
        ;;
      argv)
        echo "     📏 ${cli} — the CLI never started: the OS rejected its argument list as too" >&2
        echo "        long (E2BIG). This is not a model failure and not a timeout — nothing ran." >&2
        echo "        The prompt does not travel on argv (it goes to the CLI on stdin or via a" >&2
        echo "        prompt file), so what is left on argv is only the CLI's own flags: the" >&2
        echo "        model selection from MULTI_AGENT_MODEL_<CLI>, sandbox / permission flags," >&2
        echo "        and (grok) the prompt-file path. Look at an oversized MULTI_AGENT_MODEL_*" >&2
        echo "        value, or an environment whose limit is far below \`getconf ARG_MAX\`" >&2
        echo "        (Git Bash on Windows caps CreateProcess near 32KB)." >&2
        ;;
      prompt-too-long)
        # 全滅していれば上の集約案内が既に対象側を名指ししているので、ここは
        # 「この CLI も同じ理由」であることと、実測値だけを繰り返さずに置く。
        echo "     📐 ${cli} — the model refused the request itself: the prompt was too long." >&2
        echo "        Nothing was looked at, and neither more time nor a different CLI changes" >&2
        echo "        the bytes being sent — the diff under review is what has to shrink." >&2
        ensure_diff_size_summary
        if [[ -n "$DIFF_SIZE_SUMMARY" ]]; then
          echo "        Reviewed diff: ${DIFF_SIZE_SUMMARY}." >&2
        fi
        # 成果物を単体で開く読み手にも同じ実測値を残す。ここで書くのは、この関数が
        # レポート生成より前に 1 度だけ走り、分類済みの cause を既に持っているため
        # （分類をもう 1 周させないための同居であって、助言の副作用ではない）。
        annotate_result_prompt_too_long "${OUTPUT_DIR}/${cli}/${persp}.md"
        ;;
    esac
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
    fi
    # 代替 CLI の案内はスキップにも出す（Issue #1143）。資格情報・残高が死んで
    # いる CLI では「代替で今すぐ回す」が最も実行可能な次の一手であり、同じ理由で
    # 落とされた観点こそその案内を必要とする。
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

  # 全滅した prompt-too-long は個別セクションより**手前**に置く（公開
  # feel-flow/ff-dev-toolkit#95）。各セクションの INCOMPLETE を 1 本ずつ読んでから
  # 「実は全部同じ 1 つの原因だった」と気付く順序では、実測の遠回り（CLI を 1 つずつ
  # 再実行する）がレポート経由でもそのまま再現する。
  if prompt_too_long_run_wide; then
    local ptl_line
    ensure_diff_size_summary
    {
      echo ""
      echo "> **📐 PROMPT TOO LONG — read this before the per-task sections.**"
      while IFS= read -r ptl_line; do
        echo "> ${ptl_line}"
      done < <(prompt_too_long_advice_lines)
      echo ""
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
      elif [[ -n "$(skipped_task_cause "${cli_name}/${perspective_name}")" ]]; then
        # スキップした節へ executed と書くと、数行下の「this task was not executed」と
        # 同じ節の中で矛盾する（Issue #1143）。
        echo "**Result source:** skipped"
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
          # 理由は断定しない — incomplete はクラッシュ・タイムアウトだけでなく、
          # アダプタが結果を拒否した場合（sandbox-refused / missing-review-body）も
          # 通る。具体的な理由は成果物内の INCOMPLETE バナーが名指しする。
          echo "⚠️ **INCOMPLETE** — the CLI failed, timed out, or its result was refused;"
          echo "what follows is output salvaged from that run, not a finished ${TASK_TYPE}."
          echo "Absence of a finding here means unchecked, not clean."
          echo ""
        fi
        cat "$result_file"
      elif [[ -n "$(skipped_task_cause "${cli_name}/${perspective_name}")" ]]; then
        # スキップは「失敗して何も書けなかった」とは別の状態（Issue #1143）。
        # 同じ 1 行に丸めると、読み手は起きていないクラッシュの原因を探しに行く。
        # 名指しするのは (a) 実行していないこと (b) その理由が CLI 単位であること
        # (c) この節の沈黙が「所見なし」ではないこと の 3 点。
        echo "⏭ **SKIPPED** — this task was not executed, so it counts as **INCOMPLETE**."
        echo "${cli_name} had already failed in this run for a $(skipped_task_cause "${cli_name}/${perspective_name}") reason, which is a"
        echo "property of the CLI and not of the task, so every remaining ${cli_name} task was"
        echo "dropped before paying for its setup."
        echo "Absence of a finding here means unchecked, not clean."
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
# pair の実効レビュワー行（Issue #699）。pair 以外・未設定では 1 バイトも足さない
# ので、他モードのレポート書式は不変。severity 行文法（`- Critical: N` 等）にも
# ゼロ語文法にも一致しない `**Label:** value` 形なので、共有 severity パーサー
# （adapter-common.sh の _ff_severity_scan）の受理判定・CRITICAL_BLOCK 検出とは
# 干渉しない — 既存の Mode / Strategy 行と同じ形にしてあるのはそのため。
# 先頭に改行を置くのは、コマンド置換が末尾改行を落とすため（`$(...)` の直後に
# 改行を書くと、行が空のとき余分な空行が残る）。ヒアドキュメント側は
# `**Mode:** ...$(pair_reviewers_report_line)` と続けて書く。
pair_reviewers_report_line() {
  [[ -n "$PAIR_REVIEWERS_NOTE" ]] || return 0
  printf '\n**Reviewers:** %s' "$PAIR_REVIEWERS_NOTE"
}

generate_review_report() {
  local final_report_file="${OUTPUT_DIR}/integrated-report.md"
  local report_file="${final_report_file}.building.$$"

  echo "📝 Generating integrated review report..." >&2

  if ! rm -f "$report_file"; then
    echo "ERROR: cannot clear the temporary integrated review report: ${report_file}" >&2
    return 1
  fi
  if ! cat > "$report_file" <<HEADER
# Multi-CLI Review — Integrated Report

**Generated:** $(date -u +"%Y-%m-%dT%H:%M:%SZ")
**Mode:** ${MODE}$(pair_reviewers_report_line)
**Strategy:** ${STRATEGY}
**Base Branch:** ${BASE_BRANCH}

---

HEADER
  then
    echo "ERROR: cannot initialize the integrated review report." >&2
    rm -f "$report_file" 2>/dev/null || true
    return 1
  fi

  local has_results=true
  append_plan_sections "$report_file" || has_results=false

  if [[ "$has_results" == "false" ]]; then
    if ! echo "(No review results found.)" >> "$report_file"; then
      echo "ERROR: cannot write the integrated review report." >&2
      rm -f "$report_file" 2>/dev/null || true
      return 1
    fi
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
  #
  # 判定本体は共有重大度行パーサー critical_findings_present
  # （adapters/adapter-common.sh の _ff_severity_scan、Issue #908）へ委譲する —
  # アダプタ側の受理ゲート review_body_present と**同一の行分類**（CommonMark
  # フェンス追跡・重大度行文法 s1〜s4・数値ゼロ / ゼロ語のゼロ件文法・参照語 veto）
  # を参照し、Critical 発火条件（c1〜c4: critical ラベルの件数行 / 指摘行、critical
  # 見出しスコープ配下の bullet、行頭 CRITICAL: マーカー）は同ファイルのヘッダが
  # 正。ここへ判定式を複製しないこと — 独立実装だった間は、片側へ語彙・境界を
  # 足すたびにズレて fail-open / 偽 BLOCK の両方向の非対称が再発した（Issue #893
  # の 7 巡レビューで実測。受理と検出の積集合は tests/severity-parser-intersection
  # が同一入力表で固定する）。
  #
  # フェンスが閉じないまま本文が終わる場合は判定不能（rc=2）として安全側（マーカー
  # あり）へ倒す。判定を実行できない場合（rc=3: 不可読ファイル / awk 実行失敗 —
  # rc の写像は critical_findings_present が行う）も同様に安全側へ倒し、診断を
  # stderr へ残す。検出力は tests/multi-agent-critical-marker/ が stub CLI の
  # 実走で固定する。
  local crit_entry crit_seen="" crit_file crit_rc crit_found crit_persp
  local crit_block_hits="" crit_nonblock_hits="" crit_nonblock_set
  # 判定不能（未閉フェンス / awk 失敗）は実所見と別のリストに持つ。マーカーの
  # 発火条件としては同格（安全側 = Critical あり）だが、レポート上で「実所見が
  # あった」と「本文を判定しきれなかった」を同じ文で報告すると、判定不能の観測が
  # stderr にしか残らず、INCOMPLETE と同型の「空振りを所見と読む」誤読を生む。
  local crit_block_unparse="" crit_nonblock_unparse="" crit_target
  local crit_block_retained="" crit_nonblock_retained="" state_block state_nonblock state_series
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
    crit_persp="${crit_entry#*:}"
    # A failed/timeout/skipped rerun did not prove resolution. Preserve that
    # perspective's prior classification instead of judging incomplete output.
    if task_left_perspective_unproven "${crit_entry%%:*}" "$crit_persp"; then
      if list_contains "$PREVIOUS_UNRESOLVED_BLOCK" "$crit_persp"; then
        crit_block_retained="${crit_block_retained:+$crit_block_retained }$crit_persp"
        continue
      fi
      if list_contains "$PREVIOUS_UNRESOLVED_NONBLOCK" "$crit_persp"; then
        crit_nonblock_retained="${crit_nonblock_retained:+$crit_nonblock_retained }$crit_persp"
        continue
      fi
    fi
    crit_file="${OUTPUT_DIR}/${crit_entry%%:*}/${crit_entry#*:}.md"
    [[ -f "$crit_file" ]] || continue
    set +e
    critical_findings_present "$crit_file"
    crit_rc=$?
    set -e
    # 判定不能（rc=2: 未閉フェンス / rc=3 以上: 不可読ファイル・awk 失敗）は
    # 「Critical あり」へ倒す。
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
        echo "⚠️ CRITICAL_BLOCK 判定を実行できませんでした（判定 rc=${crit_rc}: ${crit_file} — 不可読ファイルまたは判定器の実行失敗）。判定不能を Critical なしとして通さないため、安全側（Critical あり）に倒します" >&2
        crit_found=unparse ;;
    esac
    if [[ -n "$crit_found" ]]; then
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
  if [[ -n "$crit_block_hits" || -n "$crit_block_unparse" || -n "$crit_block_retained" ]]; then
    if ! {
      echo ""
      echo "<!-- CRITICAL_BLOCK -->"
      if [[ -n "$crit_block_hits" ]]; then
        echo "Critical issues detected (${crit_block_hits// /, }). Review before proceeding."
      fi
      if [[ -n "$crit_block_unparse" ]]; then
        echo "Unparseable result treated as critical (${crit_block_unparse// /, }): the body could not be fully judged — see the run diagnostics."
      fi
      if [[ -n "$crit_block_retained" ]]; then
        echo "Previous Critical remains unresolved because its rerun failed or was skipped (${crit_block_retained// /, })."
      fi
    } >> "$report_file"; then
      echo "ERROR: cannot write blocking Critical state to the integrated review report." >&2
      rm -f "$report_file" 2>/dev/null || true
      return 1
    fi
  fi
  if [[ -n "$crit_nonblock_hits" || -n "$crit_nonblock_unparse" || -n "$crit_nonblock_retained" ]]; then
    # 本文に "CRITICAL_BLOCK" を部分一致で含めないこと（上の段階化コメント参照）。
    if ! {
      echo ""
      echo "<!-- CRITICAL_NONBLOCK -->"
      if [[ -n "$crit_nonblock_hits" ]]; then
        echo "Critical findings in non-blocking perspectives (${crit_nonblock_hits// /, })."
      fi
      if [[ -n "$crit_nonblock_unparse" ]]; then
        echo "Unparseable result treated as critical, in non-blocking perspectives (${crit_nonblock_unparse// /, })."
      fi
      if [[ -n "$crit_nonblock_retained" ]]; then
        echo "Previous non-blocking Critical remains unresolved because its rerun failed or was skipped (${crit_nonblock_retained// /, })."
      fi
      echo "Fix them per the review response policy; on their own they do not re-trigger the full gate."
    } >> "$report_file"; then
      echo "ERROR: cannot write non-blocking Critical state to the integrated review report." >&2
      rm -f "$report_file" 2>/dev/null || true
      return 1
    fi
  fi

  # Machine-readable final line for the next partial run. It is intentionally
  # unsigned and minimal: the guard prevents accidental omission, not hostile
  # report tampering. Perspective names are validated before they are consumed.
  state_block="${crit_block_hits}${crit_block_hits:+ }${crit_block_unparse}${crit_block_unparse:+ }${crit_block_retained}"
  state_nonblock="${crit_nonblock_hits}${crit_nonblock_hits:+ }${crit_nonblock_unparse}${crit_nonblock_unparse:+ }${crit_nonblock_retained}"
  state_block="${state_block% }"
  state_nonblock="${state_nonblock% }"
  state_series="$(current_review_series_id)" || {
    echo "ERROR: cannot identify the current review series for the report." >&2
    rm -f "$report_file" 2>/dev/null || true
    return 1
  }
  if ! printf '<!-- MULTI_CLI_UNRESOLVED_CRITICAL series:%s block:%s nonblock:%s -->\n' \
    "$state_series" "${state_block:--}" "${state_nonblock:--}" >> "$report_file"; then
    echo "ERROR: cannot persist unresolved Critical state in the integrated report." >&2
    rm -f "$report_file" 2>/dev/null || true
    return 1
  fi

  if ! mv "$report_file" "$final_report_file"; then
    echo "ERROR: cannot publish the completed integrated review report." >&2
    rm -f "$report_file" 2>/dev/null || true
    return 1
  fi

  echo "📄 Report: ${final_report_file}" >&2
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
If any such leftovers exist, a "Not part of this run" list naming them appears
below (and on stderr); they are left untouched and are NOT this run's output.

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
      CONFIG_PROVENANCE="flag"
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

  # ツリー変化判定のパス除外の検証はタスクを 1 つも起動する前に済ませる — 不正な
  # FF_MULTI_AGENT_IGNORE_PATHS で CLI に支払った後に落ちる形にしない（Issue #747）。
  parse_ignore_paths || exit 1

  # 一覧は description 必須検査より前に返す（explore/implement で「一覧を見たいだけ」
  # なのに落ちるのを避ける）。ただし**引数の妥当性検査は通す** — ここを飛ばすと
  # `--list-perspectives --cli no-such-cli` が rc=0 になり、綴り間違いが成功として
  # 返る（実測で一度そう作ってしまった）。
  if [[ "$LIST_PERSPECTIVES" == "true" ]]; then
    # mode の妥当性もここで見る（Issue #699）。apply_task_defaults の手前で抜けるので、
    # ここを飛ばすと `--mode distribuited --list-perspectives` が rc=0 になり、
    # 綴り間違いが「その mode は在る」という誤った確認になる（--cli と同じ形）。
    validate_mode
    validate_requested_clis
    validate_excluded_clis
    validate_requested_perspectives
    validate_excluded_perspectives
    all_task_perspectives
    exit 0
  fi
  apply_task_defaults
  validate_requested_clis
  validate_excluded_clis
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
    echo "   Set them once with: bash $(shell_quote "${SCRIPT_DIR}/multi-agent.sh") --task review --set-reviewers main=<cli>,sub=<cli>" >&2
    MODE="distributed"
  fi

  emoji="$(get_task_emoji "$TASK_TYPE")"

  echo "${emoji} Multi-CLI Agent Orchestrator — ${TASK_TYPE}" >&2
  echo "================================================" >&2
  echo "" >&2

  echo "🔎 Detecting available CLIs..." >&2
  detect_available_clis

  # base の diff を実際に使うタスクでだけ警告する（explore / implement（--include-diff
  # 無し）は base を読まないので、混入の警告は虚偽になる — セルフレビュー指摘）
  if [[ "$TASK_TYPE" == "review" || "$INCLUDE_DIFF" == "true" ]]; then
    warn_if_stale_local_base
  fi

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
      echo "       Check --cli / --perspective / --exclude-perspective / --mode combinations." >&2
      # 矛盾した ↪ 宣言を消した（Issue #699 項目 4）ぶん、除外が原因のときは
      # ここで名指しする。3 つのつまみだけを指すと、実際の原因である
      # --exclude-perspective が候補にすら挙がらない。
      if [[ -n "$EXCLUDE_PERSPECTIVES" ]]; then
        echo "       --exclude-perspective (${EXCLUDE_PERSPECTIVES}) removed perspective(s) that would otherwise run." >&2
      fi
    fi
    # CLI 除外はフィルタの有無に依らず原因になりうるので、上の 2 分岐の外で名指しする。
    if [[ -n "$EXCLUDE_CLIS_FLAG" ]]; then
      echo "       --exclude-cli (${EXCLUDE_CLIS_FLAG}) removed CLI(s) that would otherwise run." >&2
    fi
    if [[ -n "$EXCLUDE_CLIS_CONFIG" ]]; then
      echo "       config exclude_clis (${EXCLUDE_CLIS_CONFIG_SOURCE}: ${EXCLUDE_CLIS_CONFIG}) removed CLI(s) that would otherwise run." >&2
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
  finalize_resume_cache || exit 1

  generate_report || exit 1

  echo "" >&2
  echo "🏁 Done! View results:" >&2
  echo "   cat ${OUTPUT_DIR}/integrated-report.md" >&2

  if [[ "$task_failed" == "true" ]]; then
    exit 1
  fi
}

main "$@"
