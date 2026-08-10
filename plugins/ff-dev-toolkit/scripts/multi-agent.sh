#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────
# multi-agent.sh — Multi-CLI Agent Orchestrator
# ────────────────────────────────────────────────────────────
# Orchestrates 5 AI CLIs (Claude Code, Codex, Copilot, Gemini, Grok)
# for review, explore, and implement tasks using tool-agnostic perspectives.
#
# NOTE: Copilot CLI is metered (premium requests) — excluded from the
# default review lineup. Opt in explicitly with --cli copilot-cli.
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
#   --perspective <name>    Run only this perspective (repeatable). In distributed
#                           mode, only its owning CLI remains unless --cli is also
#                           explicit; use --mode cross-model for model comparison.
#   --parallel              Parallel execution (default)
#   --sequential            Sequential execution
#   --output-dir <dir>      Output directory (auto-detected by task type)
#   --base <branch>         Base branch for diff (default: auto-detect from origin/HEAD, fallback: develop)
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
    copilot-cli) echo "test-analysis comment-analysis" ;;  # metered — runs ONLY with explicit --cli copilot-cli (see build_distributed_plan)
    gemini-cli)  echo "security-analysis comment-analysis" ;;
    grok-cli)    echo "error-handler-hunt" ;;
    *) echo "" ;;
  esac
}

get_cli_perspectives_explore() {
  case "$1" in
    claude-code) echo "architecture-analysis" ;;
    codex-cli)   echo "dependency-mapping" ;;
    copilot-cli) echo "api-surface-analysis" ;;
    gemini-cli)  echo "pattern-discovery" ;;
    grok-cli)    echo "tech-debt-assessment" ;;
    *) echo "" ;;
  esac
}

get_cli_perspectives_implement() {
  case "$1" in
    claude-code) echo "feature-implementation" ;;
    codex-cli)   echo "refactoring" ;;
    copilot-cli) echo "test-writing" ;;
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
    codex-cli)   echo "MULTI_AGENT_MODEL_CODEX_CLI MULTI_AGENT_CODEX_PROFILE" ;;
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
    local existing_main="" existing_sub=""
    read_reviewers_file_into existing_main existing_sub
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
# NOTE: keep this detection in sync with detect_base_branch() in adapters/adapter-common.sh
BASE_BRANCH="${MULTI_AGENT_BASE_BRANCH:-}"
BASE_BRANCH_SOURCE="MULTI_AGENT_BASE_BRANCH env"
if [[ -z "$BASE_BRANCH" ]]; then
  BASE_BRANCH="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)"
  BASE_BRANCH_SOURCE="auto-detected from origin/HEAD"
fi
if [[ -z "$BASE_BRANCH" ]]; then
  BASE_BRANCH="develop"
  BASE_BRANCH_SOURCE="fallback — origin/HEAD not set"
fi
# Prefer the local branch; fall back to the remote-tracking ref when absent (clones)
if ! git rev-parse --verify --quiet "refs/heads/${BASE_BRANCH}" >/dev/null 2>&1; then
  if git rev-parse --verify --quiet "refs/remotes/origin/${BASE_BRANCH}" >/dev/null 2>&1; then
    BASE_BRANCH="origin/${BASE_BRANCH}"
  fi
fi
DRY_RUN=false
TIMEOUT=""

# Space-separated filter lists (bash 3.2 compatible)
CLI_FILTER=""
PERSPECTIVE_FILTER=""

# Detected available CLIs (space-separated)
AVAILABLE_CLIS=""

# Execution plan: CLI_NAME:PERSPECTIVE pairs (newline-separated)
EXECUTION_PLAN=""

# Tasks that failed this run, as "cli/perspective:exit_code" (space-separated).
# Drives the retry advice printed after execution — a bare count leaves the user to
# work out which CLI to re-run and with what, which is exactly the moment they
# reach for a runtime fallback that does not exist. The exit code rides along
# because the right advice depends on it: more time helps a timeout and is useless
# for expired credentials. cli/perspective are validated single path segments and
# cannot contain ':', so the suffix is unambiguous.
FAILED_TASKS=""

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
      --parallel)    PARALLEL=true; shift ;;
      --sequential)  PARALLEL=false; shift ;;
      --output-dir)  OUTPUT_DIR="$2"; OUTPUT_DIR_EXPLICIT=true; shift 2 ;;
      --base)        BASE_BRANCH="$2"; BASE_BRANCH_SOURCE="--base flag"; shift 2 ;;
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

  # Validate description for explore/implement
  if [[ "$TASK_TYPE" != "review" && -z "$DESCRIPTION" && "$DRY_RUN" == "false" ]]; then
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

    # Copilot CLI is metered — include in review plans only when explicitly requested via --cli
    if [[ "$cli_name" == "copilot-cli" && "$TASK_TYPE" == "review" && -z "$CLI_FILTER" ]]; then
      echo "  ⏭  copilot-cli skipped (metered). Opt in with --cli copilot-cli." >&2
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
      if [[ -n "$CLI_FILTER" && "$CLI_FILTER" != *" "* \
            && -n "$PERSPECTIVE_FILTER" && "$PERSPECTIVE_FILTER" != *" "* ]]; then
        for p in $PERSPECTIVE_FILTER; do
          add_to_plan "$cli_name" "$p"
        done
      else
        local matched_perspective=false
        for p in $perspectives; do
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
    [[ -n "$PERSPECTIVE_FILTER" ]] && ! list_contains "$PERSPECTIVE_FILTER" "$p" && continue
    add_to_plan "$REVIEW_MAIN" "$p"
  done

  if [[ -n "$sub_effective" ]]; then
    if [[ -z "$PERSPECTIVE_FILTER" ]] || list_contains "$PERSPECTIVE_FILTER" "$COMPREHENSIVE_PERSPECTIVE"; then
      # 副に従量課金 CLI を選ぶのは明示的な指定なので opt-in とみなす。ただし
      # コスト帯はプラン表示に出るので、黙って課金されることはない。
      add_to_plan "$sub_effective" "$COMPREHENSIVE_PERSPECTIVE"
    fi
  fi
  return 0
}

# review の観点ファイル一覧（総合レビューを含む、ディスク上の実体）。
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
  echo "   Base branch: ${BASE_BRANCH} (${BASE_BRANCH_SOURCE})" >&2
  echo "   Config: ${CONFIG_FILE} (${CONFIG_SOURCE})" >&2
  echo "   Timeout: ${TIMEOUT}s per CLI" >&2
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
  # distributed review resolved implicitly to one CLI.
  if [[ "$TASK_TYPE" == "review" && "$MODE" == "distributed" \
        && -z "$CLI_FILTER" && "$planned_cli_count" -eq 1 ]]; then
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

# サンドボックスの書き込み境界は、CLI が継承する CWD（アダプタは cd しない）。
# staging がその外に出ると、grok の workspace / codex の workspace-write が書き込みを
# 拒み、パスを渡したのにエージェントが書けない状態になる。
#
# codex がこの警告の対象になったのは Issue #403 から（それ以前は不正な sandbox 値で
# 引数解析の段階で落ちており、staging に触れる所まで到達していなかった）。
#
# 比較は**両辺とも物理パス**で行う。OUTPUT_DIR は execute_tasks で pwd -P 済み、
# ここも ${PWD}（論理パス）ではなく $(pwd -P) を使う。既定の OUTPUT_DIR は
# git rev-parse --show-toplevel（物理）由来なので、論理パスと比べると symlink 越しの
# チェックアウト（macOS の /tmp・/var 配下など）でリポジトリルートに居ながら毎回
# 誤発火する。誤発火する警告は「リポジトリルートで実行しろ」と、すでにそこに居る
# 利用者へ言うことになり、症状から原因へ辿らせるという目的をむしろ壊す。
#
# ここを hard fail にしないのは、`--output-dir /tmp/...` のような CWD 外指定が
# 現に動く経路だから（gemini の implement はサンドボックス無し、ラッパー自身の
# レポート書き込みはサンドボックス外）。staging をサンドボックスルートへ揃える
# 本筋対応は別 Issue #398（アダプタ横断のサンドボックス整合）で扱う。
#
# グリフは助言の ⚠️ に固定する — 致命（staging を作れない・書けない）は ❌ を使い、
# 「続行できる助言」と「そのタスクが死んだ」を見分けられるようにしている。
warn_if_staging_outside_sandbox() {
  local staging_dir="$1"
  local cwd_physical
  cwd_physical="$(pwd -P)"
  case "$staging_dir" in
    "$cwd_physical"/*) return 0 ;;
  esac
  echo "  ⚠️  Staging dir is outside the CLI sandbox root (CWD): ${staging_dir}" >&2
  echo "      CWD: ${cwd_physical}" >&2
  echo "      Sandboxed CLIs (grok: workspace / codex: workspace-write) may be denied writes there." >&2
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
    warn_if_staging_outside_sandbox "$staging_dir"
    extra_args+=(--staging-dir "$staging_dir")
  fi

  bash "$adapter" "$perspective_file" "$output_file" \
    --base "$BASE_BRANCH" \
    --timeout "$TIMEOUT" \
    "${extra_args[@]}"
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
# CLIs, other perspectives, unrelated user files) is touched. Callers run
# validate_execution_plan first, so every token here is already a safe segment.
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
  clear_planned_outputs || return 2

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
  if [[ "$TASK_TYPE" == "review" || "$INCLUDE_DIFF" == "true" ]]; then
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
# no result file is deleted or modified here, so a shared --output-dir re-run or
# a partial --cli/--perspective run is non-destructive. A planned entry with no
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
  local crit_marker=false crit_entry crit_seen="" crit_file crit_rc
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
    case "$crit_rc" in
      0) crit_marker=true ;;
      1) : ;;
      2)
        echo "⚠️ CRITICAL_BLOCK 判定: ${crit_file} のコードフェンスが閉じておらず本文を判定しきれません。判定不能を Critical なしとして通さないため、安全側に倒してマーカーを出します" >&2
        crit_marker=true ;;
      *)
        echo "⚠️ CRITICAL_BLOCK 判定を実行できませんでした（awk rc=${crit_rc}: ${crit_file}）。判定不能を Critical なしとして通さないため、安全側に倒してマーカーを出します" >&2
        crit_marker=true ;;
    esac
  done <<< "$EXECUTION_PLAN"
  if [[ "$crit_marker" == "true" ]]; then
    echo "" >> "$report_file"
    echo "<!-- CRITICAL_BLOCK -->" >> "$report_file"
    echo "Critical issues detected. Review before proceeding." >> "$report_file"
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
  apply_task_defaults
  validate_requested_clis
  validate_requested_perspectives

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
      echo "ERROR: task '${TASK_TYPE}' diffs against '${BASE_BRANCH}', but the current directory is not inside a git repository." >&2
      exit 1
    fi
    if ! git rev-parse --verify --quiet "${BASE_BRANCH}^{commit}" >/dev/null 2>&1; then
      echo "ERROR: base branch '${BASE_BRANCH}' does not resolve to a commit." >&2
      echo "       Fix: pass --base <branch>, set MULTI_AGENT_BASE_BRANCH, or run: git remote set-head origin -a" >&2
      exit 1
    fi
  fi
  if [[ "$TASK_TYPE" == "review" ]]; then
    if git diff --quiet "${BASE_BRANCH}...HEAD" 2>/dev/null && git diff --quiet HEAD 2>/dev/null; then
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

  generate_report

  echo "" >&2
  echo "🏁 Done! View results:" >&2
  echo "   cat ${OUTPUT_DIR}/integrated-report.md" >&2

  if [[ "$task_failed" == "true" ]]; then
    exit 1
  fi
}

main "$@"
