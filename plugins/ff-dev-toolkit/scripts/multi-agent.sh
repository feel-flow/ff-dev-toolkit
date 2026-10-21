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
#   --perspective <name>    Run only this perspective (repeatable; a comma-separated
#                           list such as a,b is also accepted). In distributed
#                           mode, only its owning CLI remains unless --cli is also
#                           explicit; use --mode cross-model for model comparison.
#   --parallel              Parallel execution (default). Right before the lanes
#                           start, the 1-minute load average is measured; above
#                           cores x FF_MULTI_AGENT_LOAD_PER_CORE (default 10, 0
#                           disables) the run falls back to sequential and says so
#                           in one line. At or below the threshold nothing is printed.
#   --sequential            Sequential execution
#   --evidence              Emit producer-owned branch-review evidence (python3 required).
#                           review-evidence.py is read once at start and both ends of the
#                           evidence run from those bytes, so a plugin update that deletes
#                           the start root while CLIs run cannot break the finish
#   --require-prior-review <json>  Verify prior review before execution
#   --continue-review <json>  Explicit partial revalidation of a successful review
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
#   --delegate-to-host[=<cli>]
#                           Review only. Start NO CLI for the host's own lane (default
#                           claude-code; =codex-cli / =grok-cli when the host is Codex /
#                           grok CLI): build its
#                           prompts as usual and hand execution back to the host, which runs
#                           them in its own session (subagents) and writes each result to
#                           <output-dir>/<cli>/<perspective>.md. Re-run the SAME
#                           command to adopt those results and finish the report. Every
#                           other lane runs unchanged, and the default (no flag) still
#                           spawns the CLI. See "Host delegation" below.
#   --dry-run               Show plan without executing
#   --print-reviewers       Print the resolved review pair (main / sub / sources) plus
#                           cross_review and its source as key=value lines, then exit
#                           (0 = main set, 3 = unset). Builds no plan.
#   --set-reviewers <spec>  Save main=<cli>[,sub=<cli>][,cross_review=auto|off] to the user
#                           config. main= is required unless only cross_review= is given
#                           (then the saved main, if any, is kept); sub= / cross_review=
#                           left out keep their saved values.
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
# Host delegation (--delegate-to-host, review only):
#   Why: the claude-code lane spawns the `claude` CLI, which uses whatever account that
#   CLI is logged into. When only that account is out of quota, the lane cannot run even
#   though the host session is still working on a different account, and `claude auth`
#   has no per-invocation account selection — so the CLI side cannot fix it.
#   (grok host: headless `grok -p` lanes return no review body; Issue `#2118`.)
#   What changes: for the delegated lane only (claude-code by default, or the
#   --delegate-to-host=<cli> value), no CLI is started. The prompt this run would have
#   sent is written to <output-dir>/<lane>/.delegated/<perspective>.prompt.md together
#   with a request record, and the orchestrator prints a handoff block on STDOUT naming the
#   prompt file and the result path. The task is reported as DELEGATED (pending) — never as
#   a failure, and never as a covered perspective.
#   What does NOT change: plan construction, prompt construction, every other lane, the
#   integrated report, and the default behaviour without the flag.
#   Finishing the round trip: the host writes its result to
#   <output-dir>/<lane>/<perspective>.md and RE-RUNS THE SAME COMMAND (add --resume to
#   keep the other lanes' results). A result is adopted only when it answers THIS run's
#   prompt — the request record holds the prompt digest and a response built from a different
#   input is set aside under .delegated/ with a named path instead of being adopted or
#   deleted. An adopted result is rewritten with the same header the spawned path writes and
#   passes the same review-body acceptance gate, so the report cannot tell the two apart.
#   Exit status: 3 while any delegated task is still pending (distinct from 1 = a task
#   failed, so "waiting for the host" is never read as "the review failed").
#   Scope: the host's own lane only — claude-code (default), codex-cli or grok-cli
#   (--delegate-to-host=<cli>; the host runs each prompt in its own subagent: Claude Code's
#   Agent tool, Codex's spawn_agent, grok's spawn_subagent). Routing a lane of a different model through the host would silently
#   collapse the cross-model independence this tool exists to provide.
#
# Review round limit (review only):
#   A review run on the same branch at a new HEAD is one "round". The third round
#   (limit: FF_REVIEW_ROUND_LIMIT, default 2, 0 disables) is refused before any CLI
#   starts, with exit status 4. Pass it once with FF_REVIEW_ROUND_ACK=1 in front of the
#   command. --dry-run / --print-reviewers / --staged etc. are not rounds. The rules live
#   in tests/lib/review-round-counter.sh (shared with the PreToolUse hook).
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

# ff-dev-toolkit-script-root-guard:start
# plugin root 固定ガード（script 側）。同じ停止を skill 本文の契約節も述べているが、
# ホストが実行部だけを解決済み絶対 path として注入し契約節が本文から落ちた経路では、
# 散文のガードはちょうどそのとき手元に無い（防御が守ろうとしている失敗と、防御が
# 失われる条件が同じ）。実行部と同じファイルへ置くことで、契約を読んでいない consumer
# でも止まる。**候補は探しに行かない** — cache / marketplace / 旧インストール領域の
# 走査も version 名の並べ替えによる選び直しもしない。それが本ガードの防ごうとしている
# 失敗そのもので、探索を足すと防御が防御対象を踏む。渡された handoff を canonical 化
# して自分の実体位置と比べるだけにする。handoff が 1 つも無い直接起動（端末・テスト・
# CI の pin 実行）は止めない — 比較対象が無い状態を不一致とみなすと、正規の直接起動が
# 全部止まる。
#
# 到達性は呼び出し側とセットで成り立つ。host は plugin root を Bash tool の環境へ
# export せず、実行部テキストへ解決済みの値を差し込むだけなので、handoff を運ぶのが
# skill 本文の resolver だけだと「本文が落ちた」ちょうどそのときに handoff も消え、
# ガードは比較対象なしで素通しになる。そこで固定 root 経由の実行部は
# `FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/<名>"`
# の形にして handoff を**同じ 1 行へ**載せる。実行するスクリプトの path だけを別領域へ
# 書き換える事故は、この 1 行の中の不一致として検出できる。
#
# 判定不能は素通しではなく停止に倒す（fail-closed）。更新中の部分的な消失では、
# 判定材料（別 plugin かどうかを言う manifest）そのものが壊れた領域の内側にある。
#
# 外部コマンドを使わない。PATH が壊れた環境はこのガードが最後の砦になる場面そのもので、
# dirname / grep / sed に依存すると「自分の位置を判定できないまま素通し」になる。
# その代わり builtin 側の環境依存を自分で閉じる: path の canonical 化はすべて
# `CDPATH= cd -P --` で行う。`cd` は CDPATH が効くと**別のdirectoryへ移動したうえで
# 移動先を stdout へ出す**ので、export された CDPATH に同名の subdirectory があると
# 相対起動（`bash scripts/<名>`）で自分の位置を取り違え、コマンド置換も 2 行になる。
# 「止めない」と明文で約束している端末・テスト・CI の直接起動が、正規の handoff 付き
# でも止まっていた。各 script の複製は byte 一致で、tests/plugin-root-contract が固定する。
ff_script_root_guard_manifest_field() { # <plugin.json> <キー> → 値をstdoutへ / 読めなければ非0
  # JSON を「文字列の外 / 中」に分けて走査し、**root object 直下（ネスト深さ 1）のキー**
  # だけを返す。行単位に最初の `"<キー>"` を拾う形だと、`author` のような入れ子 object が
  # top-level の `name` より前にある manifest で `author.name` を掴み、別 plugin と誤読して
  # 照合ごと飛ばす（= fail-open）。同じ判定を docs-template の resolver fence の awk も
  # 「`{` 直後の name marker」として要求しており、厳しさを揃える。fence と違って version も
  # 読むので「最初のキー」ではなく「深さ 1 のキー」に寄せる。
  local file="$1" key="$2" line="" rest="" seg="" tmp="" acc=""
  local depth=0 instr=0 expect=0 last="" bs=0
  # symlink・非通常ファイル・読めないものは「確認できない」に倒す（除外の根拠にしない）。
  [ -f "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    rest="$line"
    while [ -n "$rest" ]; do
      if [ "$instr" -eq 1 ]; then
        case "$rest" in
          *'"'*) seg="${rest%%'"'*}"; rest="${rest#*'"'}" ;;
          *) acc="${acc}${rest}"; rest=""; continue ;;
        esac
        # 直前が奇数個の backslash なら、その `"` は escape されていて文字列は続く。
        tmp="$seg"; bs=0
        while [ "${tmp%\\}" != "$tmp" ]; do bs=$((bs + 1)); tmp="${tmp%\\}"; done
        acc="${acc}${seg}"
        if [ $((bs % 2)) -eq 1 ]; then acc="${acc}\""; continue; fi
        instr=0
        if [ "$expect" -eq 1 ]; then printf '%s' "$acc"; return 0; fi
        last="$acc"; acc=""
        continue
      fi
      case "$rest" in
        *'"'*) seg="${rest%%'"'*}"; rest="${rest#*'"'}"; instr=1; acc="" ;;
        *) seg="$rest"; rest="" ;;
      esac
      # 深さは文字列の外に出た構造文字だけで数える（値の中の括弧に釣られない）。
      tmp="$seg"
      while [ "${tmp#*'{'}" != "$tmp" ]; do depth=$((depth + 1)); tmp="${tmp#*'{'}"; done
      tmp="$seg"
      while [ "${tmp#*'['}" != "$tmp" ]; do depth=$((depth + 1)); tmp="${tmp#*'['}"; done
      tmp="$seg"
      while [ "${tmp#*'}'}" != "$tmp" ]; do depth=$((depth - 1)); tmp="${tmp#*'}'}"; done
      tmp="$seg"
      while [ "${tmp#*']'}" != "$tmp" ]; do depth=$((depth - 1)); tmp="${tmp#*']'}"; done
      case "$seg" in
        *:*) if [ "$depth" -eq 1 ] && [ -n "$last" ] && [ "$last" = "$key" ]; then expect=1; fi ;;
      esac
      # 値が object / array なら、次に閉じる文字列はその中身であって値ではない。
      case "$seg" in
        *'{'*|*'['*|*,*) expect=0 ;;
      esac
      last=""
    done
  done < "$file"
  return 1
}
ff_assert_script_plugin_root() {
  local self="${1:-}" dir="" root="" var="" value="" canonical="" used="" skipped="" other="" version="" quiet=0
  [ -n "$self" ] || { echo "❌ 起動したスクリプトの実体位置を取得できません" >&2; return 1; }
  case "$self" in */*) dir="${self%/*}" ;; *) dir="." ;; esac
  dir="$(CDPATH= cd -P -- "$dir" 2>/dev/null && pwd -P)" || dir=""
  [ -n "$dir" ] || { echo "❌ 起動したスクリプトのdirectoryを解決できません: ${self}" >&2; return 1; }
  root="$(CDPATH= cd -P -- "${dir}/.." 2>/dev/null && pwd -P)" || root=""
  [ -n "$root" ] || { echo "❌ 自分のplugin rootを解決できません: ${dir}" >&2; return 1; }
  self="${dir}/${self##*/}"
  # スクリプト自身がsymlinkなら止める。親directoryしかcanonical化しないと、期待root内の
  # symlinkから別checkoutの実体を実行でき、「実体位置とhandoffの照合」の前提が崩れる。
  if [ -L "$self" ]; then
    {
      echo "❌ ff-dev-toolkit更新後にこのskillを再呼び出してください（起動したスクリプトがsymlinkです）"
      echo "   起動したスクリプト: ${self}"
      echo "   symlinkは期待rootの内側から別領域の実体を指せるため、実体位置の照合が成立しません。"
      echo "   別のインストール領域へ切り替えて実行しないこと — version混在と未リリースWIPの実行になります。"
      echo "   cacheや別checkoutを探さず、実体のパスで起動してください。"
    } >&2
    return 1
  fi
  for var in FF_DEV_TOOLKIT_ROOT CLAUDE_PLUGIN_ROOT GROK_PLUGIN_ROOT; do
    eval "value=\${${var}:-}"
    [ -n "$value" ] || continue
    canonical="$(CDPATH= cd -P -- "$value" 2>/dev/null && pwd -P)" || canonical=""
    # 正規形は plugin root だが、scripts/ を直接指す綴りも正規に受理されている
    # （templates/codex-review.sh の canonical_toolkit_root が両方を受ける）。同じ実体を
    # 指している限り一致として扱う。
    if [ -n "$canonical" ] && { [ "$canonical" = "$root" ] || [ "$canonical" = "$dir" ]; }; then
      [ -n "$used" ] || used="$var"
      continue
    fi
    # 実在する別 plugin の root は我々への handoff ではない（別 plugin 経由の正規呼び出し
    # まで殺さない）。ただし除外できるのは「manifestが通常ファイルとして読めて、名前が別だと
    # 確認できた」ときだけにする。消えているroot も、読めないmanifest も、誰のものか判定
    # できない点は同じ。
    other=""
    if [ -n "$canonical" ]; then
      other="$(ff_script_root_guard_manifest_field "${canonical}/.claude-plugin/plugin.json" name)" || other=""
    fi
    if [ -n "$other" ] && [ "$other" != "ff-dev-toolkit" ]; then
      skipped="${skipped:+${skipped} }${var}=別plugin(${other})"
      continue
    fi
    {
      echo "❌ ff-dev-toolkit更新後にこのskillを再呼び出してください（plugin rootが固定値と一致しません）"
      echo "   起動したスクリプト: ${self}"
      echo "   このスクリプトのplugin root: ${root}"
      echo "   hostが渡したroot（${var}）: ${value}"
      if [ -z "$canonical" ]; then
        echo "   不一致の内容: 指しているdirectoryが実在しません（plugin rootが消えています）"
      elif [ -z "$other" ]; then
        echo "   不一致の内容: 指す先のplugin manifestを読めず、誰のrootか判定できません（判定不能は停止に倒します）"
      else
        echo "   不一致の内容: このスクリプトは別のインストール領域の実体です"
      fi
      echo "   別のインストール領域へ切り替えて実行しないこと — version混在と未リリースWIPの実行になります。"
      echo "   cacheや別checkoutを探さず、pluginを再導入してからskillを呼び直してください。"
    } >&2
    return 1
  done
  # provenance（実体 path と version の 1 行）は「想定外の場所から起動された」ことを
  # agent にもログを読む人にも見せて診断コストを下げる。照合を飛ばした handoff も理由付きで
  # 出す — 渡っていた事実を「なし・直接起動」と報告すると、診断価値を損ない事実とも食い違う。
  # 出力そのものが契約になっている script（成功時は無出力・stderr を混ぜない等）では情報行が
  # 契約違反になるので、その basename だけを**この block 内の allowlist**で抑止する。
  # 外から env で抑止できる形にすると allowlist が実効的な制約にならないので、環境変数では
  # 抑止できない。抑止できるのは provenance だけで、停止の判定と案内は抑止できない。
  case "${self##*/}" in
    check-merge-freshness.sh|check-plugin-versions.sh) quiet=1 ;;
  esac
  if [ "$quiet" -ne 1 ]; then
    version="$(ff_script_root_guard_manifest_field "${root}/.claude-plugin/plugin.json" version)" || version=""
    echo "ℹ️  ff-dev-toolkit ${version:-version不明} — 実行実体: ${self}（handoff: ${used:-なし・直接起動}${skipped:+ / 照合対象外: ${skipped}}）" >&2
  fi
  return 0
}
ff_assert_script_plugin_root "${BASH_SOURCE[0]}" || exit 2
# ff-dev-toolkit-script-root-guard:end

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
    grok-cli)    echo "MULTI_AGENT_MODEL_GROK_CLI MULTI_AGENT_GROK_READONLY_PROFILE" ;;
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

# ── Orchestrator parts（開始時に 1 回だけ読む） ──
# 本体は責務ごとに scripts/lib/multi-agent-*.sh へ分けてあり、ここで下の順に source する
# （MASTER.md のファイルサイズ閾値。判断は ADR-075）。名簿はこの 1 か所だけに置き、
# --resume の入力 identity（compute_resume_identity）も同じ名簿を読む。
#
# - 開始時に、トップレベルで、無条件に読む。CLI の完走後の工程（レポート生成・evidence の
#   finish・委譲の引き渡し）は plugin root から何も読まない（ADR-073）。bash は source した
#   ファイルを読み切ってから実行するので、読み込んだ後に root が消えても定義は変わらない
# - 順序は分割前の行順。各ファイルのトップレベルの初期化（既定値・readonly）は構成ファイル
#   同士で分割前と同じ順に走る（上に残したタスク種別の既定が先に走る点だけが違う。互いを
#   参照しない）。関数の中では source しない
# - パスは SCRIPT_DIR（$0 由来）から作る。テストは /tmp に置いた本ファイルの写しを、$0 を
#   実体のパスにして source する
# - 読めないときは別の版を探さず、root guard と同じ案内で exit 2 にする（ADR-036）。CLI は
#   まだ 1 つも起動していない。対象は、置き場の scripts/lib が通常のディレクトリでない
#   （symlink の先は別のインストール領域でありうる）・構成ファイルが不在・symlink・空・
#   読み取り不可・最後の行が読み込み完了の印でない（途中で切れている）のいずれか。印は
#   source の前に読んで照合する — 関数やヒアドキュメントの途中で切れたファイルは source が
#   構文エラーで落ち、案内を出す前に set -e で止まるため。source の後にも、印の代入が
#   実際に走ったことを確かめる
# - source は素のまま書く（`|| ...` を付けると、構成ファイルのトップレベルで set -e が効かなくなる）
MULTI_AGENT_PARTS=(
  "${SCRIPT_DIR}/lib/multi-agent-lanes.sh"
  "${SCRIPT_DIR}/lib/multi-agent-options.sh"
  "${SCRIPT_DIR}/lib/multi-agent-plan.sh"
  "${SCRIPT_DIR}/lib/multi-agent-prepare.sh"
  "${SCRIPT_DIR}/lib/multi-agent-outputs.sh"
  "${SCRIPT_DIR}/lib/multi-agent-critical.sh"
  "${SCRIPT_DIR}/lib/multi-agent-execute.sh"
  "${SCRIPT_DIR}/lib/multi-agent-failure.sh"
  "${SCRIPT_DIR}/lib/multi-agent-codex-update.sh"
  "${SCRIPT_DIR}/lib/multi-agent-advice.sh"
  "${SCRIPT_DIR}/lib/multi-agent-report-body.sh"
  "${SCRIPT_DIR}/lib/multi-agent-report.sh"
)
ma_refuse_part() { # <理由> <対象のパス>
  {
    echo "❌ ff-dev-toolkit更新後にこのskillを再呼び出してください（multi-agent.sh の構成ファイル${1}）"
    echo "   対象: ${2}"
    echo "   cache を手で直さず、plugin を更新・再導入してから skill を呼び直してください。"
    echo "   別のインストール領域へ切り替えて実行しないこと — version混在と未リリースWIPの実行になります。"
    echo "   CLI はまだ 1 つも起動していません。"
  } >&2
  exit 2
}
if [[ -L "${SCRIPT_DIR}/lib" || ! -d "${SCRIPT_DIR}/lib" ]]; then
  ma_refuse_part "の置き場が通常のディレクトリではないか symlink です" "${SCRIPT_DIR}/lib"
fi
for _ma_part in "${MULTI_AGENT_PARTS[@]}"; do
  if [[ -L "$_ma_part" ]]; then
    ma_refuse_part "が symlink です" "$_ma_part"
  elif [[ ! -f "$_ma_part" ]]; then
    ma_refuse_part "がありません" "$_ma_part"
  elif [[ ! -s "$_ma_part" ]]; then
    ma_refuse_part "が 0 バイトです" "$_ma_part"
  elif [[ ! -r "$_ma_part" ]]; then
    ma_refuse_part "を読み取れません" "$_ma_part"
  fi
  _ma_part_last="$(awk 'NF { l = $0 } END { print l }' "$_ma_part" 2>/dev/null)" || _ma_part_last=""
  if [[ "$_ma_part_last" != "_ma_part_loaded=\"${_ma_part##*/}\"" ]]; then
    ma_refuse_part "が末尾まで読めていません（最後の行が読み込み完了の印ではありません）" "$_ma_part"
  fi
  _ma_part_loaded=""
  # shellcheck source=/dev/null
  source "$_ma_part"
  if [[ "$_ma_part_loaded" != "${_ma_part##*/}" ]]; then
    ma_refuse_part "が末尾まで読めていません（読み込み完了の印がありません）" "$_ma_part"
  fi
done
unset _ma_part _ma_part_last _ma_part_loaded
unset -f ma_refuse_part

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
  # 負荷判定の係数の書式。dry-run・--sequential・1 タスクの実行でも同じく弾く。
  validate_load_gate_config || exit 2

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

  # 信頼度の報告閾値は CLI を 1 つも起動する前に検証する — 不正値で課金した後の
  # レポート生成で落ちる形にしない（parse_ignore_paths と同じ理由）。
  if [[ "$TASK_TYPE" == "review" ]]; then
    REVIEW_CONFIDENCE_THRESHOLD="$(resolve_review_confidence_threshold)" || exit 1
    resolve_critical_nonblock_at_start
  fi
  # evidence の producer は開始時に読み、begin / finish の両方をそのバイト列で実行する。
  # 読めない回は巡を数える前・CLI を 1 つも起動する前に止める。
  if [[ "$REVIEW_EVIDENCE" == true ]]; then
    pin_review_evidence_producer || exit $?
  fi

  # ── レビュー巡回の上限（全ホスト共通の経路）──
  # 同じブランチで異なる HEAD に対するレビューの起動を巡として数え、上限（既定 2 巡）を超える巡は
  # 何も起動せず exit 4 で止める。hook（guard-review-in-flight.sh）と同じライブラリ・同じ記録を
  # 読むので、hook が数えた起動・multi-review.sh 経由の起動を二重に数えない。判定・母集団・
  # 通過口（FF_REVIEW_ROUND_ACK=1 を起動コマンドの先頭へ）・無効化（FF_REVIEW_ROUND_LIMIT=0）の
  # 正本は tests/lib/review-round-counter.sh のヘッダ。ライブラリを読めない回は判定不能として
  # 警告だけ出して通す（fail-soft）。
  if [[ "$TASK_TYPE" == "review" ]]; then
    local round_lib="$SCRIPT_DIR/../tests/lib/review-round-counter.sh"
    # shellcheck source=../tests/lib/review-round-counter.sh
    if [[ -r "$round_lib" ]] && . "$round_lib" 2>/dev/null \
      && [[ "$(type -t ff_review_round_script_gate 2>/dev/null)" == "function" ]]; then
      if ! ff_review_round_script_gate "$@"; then
        exit 4
      fi
    else
      echo "ℹ️ ff-dev-toolkit guard（レビュー巡回カウンタ）: 巡回カウンタ（${round_lib}）を読めないため巡を数えられません。判定不能として通します。" >&2
    fi
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
  if [[ ! "$TIMEOUT" =~ ^[0-9]+$ ]] || [[ "$TIMEOUT" -eq 0 ]]; then
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

  # 委譲を指定したのに対象レーンがプランに居ない実行は、利用者の意図が黙って落ちた
  # 状態（--exclude-cli / --cli / --perspective / --mode の組み合わせで消えうる）。
  # 他レーンだけ走らせて「委譲したはずの観点」をレポートから落とさない。
  # dry-run でも同じ判定にする — プラン検証の境界で通ったものが実行で落ちる形にしない。
  if [[ "$DELEGATE_TO_HOST" == "true" ]] && ! plan_lists_cli "$DELEGATION_LANE"; then
    echo "ERROR: --delegate-to-host was given but ${DELEGATION_LANE} is not in this plan." >&2
    echo "       Delegation exists for the ${DELEGATION_LANE} lane only, so there is nothing to delegate." >&2
    echo "       Check --cli / --exclude-cli / --perspective / --mode, or drop --delegate-to-host." >&2
    exit 1
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    # codex-cli の版チェック（dry-run は表示だけ）
    ensure_codex_cli_current
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
  local delegated_entry
  # codex-cli が古ければ dispatch 前に更新する。事前検査（base の解決・空 diff）より後に
  # 置く — 止まる実行でグローバルな入れ替えをしない。
  ensure_codex_cli_current
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
  report_plugin_root_change
  if [[ "$REVIEW_EVIDENCE" == true ]]; then
    # 生成した直後のレポートの digest。finish はアーカイブするバイト列とこれを照合する
    # （生成から finish までの間の書き換えを、受理される証跡へ持ち込まない）。
    if ! evidence_report_sha="$(python3 -I -c 'import hashlib, sys; sys.stdout.write(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' \
      "${OUTPUT_DIR}/integrated-report.md")" || [[ ! "$evidence_report_sha" =~ ^[0-9a-f]{64}$ ]]; then
      echo "ERROR: cannot take the digest of the generated report: ${OUTPUT_DIR}/integrated-report.md" >&2
      print_evidence_finish_failure "(not written)" "unavailable"
      exit 1
    fi
    evidence_results="${OUTPUT_DIR}/.evidence-results.$$"
    : > "$evidence_results" || exit 1
    while IFS= read -r evidence_task; do
      [[ -n "$evidence_task" ]] || continue
      evidence_cli="${evidence_task%%:*}"
      evidence_persp="${evidence_task#*:}"
      evidence_status=complete
      if [[ -n "$(review_task_incomplete_reason "$evidence_cli" "$evidence_persp")" ]]; then
        evidence_status=incomplete
        if [[ -n "$(unavailable_cross_task_cause "${evidence_cli}/${evidence_persp}")" ]]; then
          evidence_status=unavailable
        fi
      fi
      printf '%s\t%s\n' "$evidence_task" "$evidence_status" >> "$evidence_results" || exit 1
    done <<< "${FULL_EXECUTION_PLAN:-$EXECUTION_PLAN}"
    if ! run_review_evidence finish --file "$REVIEW_EVIDENCE_START" --output "$OUTPUT_DIR" \
      --results "$evidence_results" --report-sha256 "$evidence_report_sha"; then
      print_evidence_finish_failure "$evidence_results" "$evidence_report_sha"
      exit 1
    fi
    # rc 0 は receipt を書いたことの代わりにならない（何もしない producer でも 0 で返る）。
    if [[ ! -s "${OUTPUT_DIR}/review-evidence.json" ]]; then
      echo "ERROR: review evidence finish returned success but wrote no receipt: ${OUTPUT_DIR}/review-evidence.json" >&2
      print_evidence_finish_failure "$evidence_results" "$evidence_report_sha"
      exit 1
    fi
    rm -f "$REVIEW_EVIDENCE_START" "$evidence_results" || exit 1
  fi

  echo "" >&2
  if [[ -n "$DELEGATED_TASKS" ]]; then
    # 「Done」と名乗らない。委譲したレーンはまだ結果を持っていない。
    echo "🤝 Not finished — perspective(s) delegated to the host are still pending:" >&2
    for delegated_entry in $DELEGATED_TASKS; do
      echo "     ${delegated_entry}" >&2
    done
    echo "   1) Run each prompt below in this host's own session (read-only; do not touch the worktree)." >&2
    echo "      Keep the line 'FF-REVIEW-DELEGATED: <prompt-file>' AT THE START OF ITS OWN LINE in" >&2
    echo "      the prompt you hand to the subagent, with the prompt-file path exactly as printed" >&2
    echo "      below. The review-in-flight guard identifies this path by what is handed over, not" >&2
    echo "      by subagent type (a generic type is used here), and freezes edits while the review" >&2
    echo "      runs. It requires the line anchor and an existing prompt file, so a mention of the" >&2
    echo "      marker inside prose does not freeze anything. Dropping the line only loses that" >&2
    echo "      guard; the review still works." >&2
    echo "      The lane is released when the launch is denied, or by its own age limit — a" >&2
    echo "      subagent-stop event carries no correlation id, so a generic type cannot be matched" >&2
    echo "      back to this review without risking the release of someone else's lane." >&2
    echo "   2) Write each result to the output-file path named with it." >&2
    echo "   3) Re-run this command WITH --resume to adopt them and regenerate the report." >&2
    echo "      --resume is not optional here beyond saving the other lanes' work: without it this" >&2
    echo "      run clears every planned result first, so perspectives already adopted in an earlier" >&2
    echo "      round are cleared too and handed back out again — a lane with several perspectives" >&2
    echo "      never converges." >&2
    echo "   Report so far (delegated perspectives are marked INCOMPLETE): ${OUTPUT_DIR}/integrated-report.md" >&2
    echo "" >&2
    print_delegation_handoff
  else
    echo "🏁 Done! View results:" >&2
    echo "   cat ${OUTPUT_DIR}/integrated-report.md" >&2
  fi

  # 失敗は委譲待ちより重い。両方ある実行で 3 を返すと、消費側は「ホストを待てばよい」と
  # 読んで失敗したタスクの再実行を落とす。順序はこの 1 箇所でだけ決める。
  if [[ "$task_failed" == "true" ]]; then
    exit 1
  fi
  if [[ -n "$DELEGATED_TASKS" ]]; then
    exit 3
  fi
}

main "$@"
