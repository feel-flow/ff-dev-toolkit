#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────
# codex-cli-adapter.sh — Multi-CLI Agent: Codex CLI Adapter
# ────────────────────────────────────────────────────────────
# Usage: ./codex-cli-adapter.sh <perspective-file> <output-file> [options]
#
# Options:
#   --changed-files <files>   Comma-separated list of changed files
#   --base <branch>           Base branch for diff (default: auto-detect from origin/HEAD, fallback: develop)
#   --staged                  Review only staged changes (mutually exclusive with --base)
#   --timeout <seconds>       Timeout in seconds (default: 900; the orchestrator always passes this explicitly)
#   --task-type <type>        review | explore | implement (default: review)
#   --description <text>      Task description (for explore/implement)
#   --staging-dir <dir>       Absolute, existing, writable dir the agent writes generated
#                             files into (implement only; the orchestrator always passes it)
#   --inline-output           implement without a staging dir: the CLI reports file contents
#                             inline instead of writing them. An implement run with neither
#                             this nor --staging-dir is rejected (a dropped path must not
#                             silently degrade into inline mode)
#
# Requires: codex (npm i -g @openai/codex)
# Cost tier: Standard (token-based billing)
# ────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/adapter-common.sh"

readonly CLI_NAME="Codex CLI"
readonly CLI_COMMAND="codex"

# ── Preflight ──

if ! cli_available "$CLI_COMMAND"; then
  echo "ERROR: ${CLI_NAME} (${CLI_COMMAND}) is not installed." >&2
  echo "Install: npm install -g @openai/codex" >&2
  exit 1
fi

# ── Parse Arguments ──

parse_adapter_args "$@"

# perspective_name は build_prompt 失敗時の fail_orchestrator_error にも要る。
# build_prompt を mktemp ガードより前に素で呼ぶと set -e が bare exit し、
# INCOMPLETE 成果物が残らない（Issue #267）。
perspective_name="$(basename "$PERSPECTIVE_FILE" .md)"

# ── Build Prompt ──

if ! prompt="$(build_prompt "$PERSPECTIVE_FILE" "$BASE_BRANCH" "$CHANGED_FILES")"; then
  fail_orchestrator_error "$perspective_name" \
    "cannot build the ${TASK_TYPE:-review} prompt (perspective missing, empty diff, or load failure)."
fi

# ── Task-type specific sandbox ──
#
# **Version numbers in this file are per-claim provenance, not a file-wide
# stamp. Do NOT bulk-rewrite them.** A claim is re-stamped only when it has
# actually been re-measured. Everything reachable for free — `codex exec --help`
# and `codex sandbox`, neither of which invokes a model — was re-measured on
# 0.149.1. The claims that still say 0.144.x are the ones whose only check is a
# BILLED `codex exec` run against the model (`-m` vs `-p` precedence, and codex
# silently ignoring a non-existent profile); they are NOT re-measured on 0.149.1
# and the comments there do not claim they are. Each such block carries the same
# note inline, so a reader who lands mid-file does not have to find this one.
#
# The value goes straight to `codex exec --sandbox`, which is a closed enum.
# Measured on codex-cli 0.149.1 (`codex exec --help`):
#   -s, --sandbox <SANDBOX_MODE>
#       [possible values: read-only, workspace-write, danger-full-access]
# Anything else is rejected by argv parsing with rc=2 **before the CLI runs at
# all** — the perspective is lost for the whole run, and the report shows an
# INCOMPLETE artifact rather than "this adapter is misconfigured". implement used
# to pass `network-off`, which is not in that enum, so every codex implement task
# died there (Issue #403). tests/adapter-sandbox-contract pins this against the
# enum the CLI itself publishes.
#
# Why workspace-write for implement, and what it does to the network. In codex
# these two axes are bundled into the one mode, so there is no "confine writes
# but keep the network off" value to choose separately. Measured on 0.149.1 with
# `codex sandbox` (invokes no model — the probes below are free and local):
#
#   mode                 write into CWD   network
#   read-only            denied           blocked (curl → HTTP 000)
#   workspace-write      allowed          blocked (curl → HTTP 000)
#   danger-full-access   allowed          open    (curl → HTTP 200)
#
# tests/adapter-sandbox-contract re-runs the **write** half of this table against
# the installed codex, so the mode choice stops being a one-time measurement. The
# network half needs an outbound request, which that suite must not do at its slot
# in run-all (static → network → destructive), so it stays a recorded measurement.
#
# So workspace-write is the mode that lets implement write its staging output
# while keeping the network shut — which is what the old `network-off` value was
# reaching for. On the **write axis** it is the direct counterpart of grok's
# `workspace` profile. Do not read that as full parity: grok's `--help` says its
# profiles govern "filesystem and network access", but on the network axis the
# two adapters MEASURABLY DIVERGE (Issue #897, measured 2026-09-01 on grok
# 0.2.118 / macOS): grok's `workspace` runs with outbound network OPEN — and
# even its read-only profile, which records restrict_network:true, does not
# block outbound HTTPS there. The agreement between the adapters is about
# writes only; see grok-cli-adapter.sh and tests/adapter-sandbox-contract's
# README for the measurement record.
#
# The network default is not left to chance: implement also pins
# `-c sandbox_workspace_write.network_access=false` (see sandbox_config_args).
get_sandbox_mode() {
  if [[ "${TASK_TYPE:-review}" == "implement" && "${INLINE_OUTPUT:-false}" == "true" ]]; then
    echo "read-only"
    return
  fi
  case "${TASK_TYPE:-review}" in
    review)    echo "read-only" ;;
    explore)   echo "read-only" ;;
    # implement has to write its staging output, so it gets the mode that allows
    # writes into the agent's working root rather than a mode that denies them
    # (or one that also opens the network). That working root is NOT the whole
    # repository: implement also passes `-C <staging>` (see cd_narrow_args), so
    # the write boundary is the staging dir alone. multi-agent.sh still fixes the
    # process CWD to REPO_ROOT and rejects output dirs outside it before launch —
    # that keeps the git-repo check satisfied and keeps the other three adapters,
    # which have no equivalent of `-C`, inside the repository.
    implement) echo "workspace-write" ;;
    *)         echo "read-only" ;;
  esac
}

# ── Write-boundary narrowing: implement writes only into staging ──
#
# `codex exec -C <DIR>` tells the agent to use DIR as its working root, and under
# workspace-write that root **is** the write boundary. Measured on codex-cli
# 0.149.1 with `codex sandbox` (invokes no model — free and local), with the
# probe dir nested inside the repository so the repo root is a real ancestor:
#
#   cwd        mode                 write ../ or REPO_ROOT   write ./
#   staging    workspace-write      DENIED                   allowed
#   REPO_ROOT  workspace-write      allowed (the old shape)  allowed
#   staging    danger-full-access   allowed (positive ctrl)  allowed
#   staging    read-only            DENIED                   DENIED
#
# Three properties of that narrowing were measured rather than assumed:
#
#   1. Reads are NOT narrowed with it. The session's environment_context keeps
#      `access="read"` on `:root` (the whole filesystem) while the single
#      `access="write"` entry is the staging dir, and a narrowed probe reads
#      repository files with zero denials. So the agent can still consult
#      CLAUDE.md, existing implementations and git history (Issue #896).
#   2. The network pin below keeps working while narrowed. Measured on 0.149.1
#      with `codex sandbox --log-denials` against a closed local port (no
#      outbound traffic): read-only, workspace-write, and workspace-write plus
#      the pin all log `(curl) network-outbound` denials; only
#      `network_access=true` and danger-full-access let the connect through.
#   3. `--add-dir` cannot do this. It only ADDS writable roots — passing the
#      staging dir that way leaves the CWD (REPO_ROOT) writable, so it is not a
#      narrowing primitive. It also accepts a non-existent dir without
#      complaining, so a typo there would fail open.
#
# Known consequence, deliberately not papered over here: the agent's working root
# is now the staging dir, so a bare relative path resolves there rather than in
# the repository. The prompt already hands it the staging path as an absolute
# path (Issue #392) and carries the diff inline, and the Execution Boundary
# section already tells it to ignore AGENTS.md / CLAUDE.md for this nested run
# (Issue #263) — but whether codex still discovers a repository-root AGENTS.md
# from a narrowed working root is UNMEASURED (it would take a billed
# `codex exec` run to see). Naming the repository root in the shared prompt was
# considered and rejected for this change: build_prompt is shared with the three
# adapters that are NOT narrowed, so the sentence would be false for them.
# Tracked separately as Issue #900.
#
# `--skip-git-repo-check` is deliberately NOT passed: validate_implement_output_boundary
# (multi-agent.sh) already forces the staging dir to live under REPO_ROOT, so the
# working root is inside a git repository and the check passes.
#
# Note the asymmetry with grok, which is documented at get_sandbox_profile in
# grok-cli-adapter.sh: only codex's implement writes are confined to staging by
# the sandbox. For grok the boundary is still the repository, and staging-only
# remains a prompt contract there.
# Kept pure: it is called inside `$( )`, so it cannot fail the run itself — an
# `exit` from a command substitution only kills the subshell and the caller would
# carry on with an empty array. The "narrow or stop" decision therefore lives at
# the call site below, in the main shell.
cd_narrow_args() {
  # STAGING_DIR is non-empty exactly for a non-inline implement run: build_prompt
  # (called far above, before any argv is assembled) returns 1 for an implement
  # with neither a staging dir nor --inline-output, and this adapter turns that
  # into fail_orchestrator_error. So the third condition is unreachable in this
  # adapter's flow; it is kept so a direct call of this function cannot emit
  # `-C ""`, and the call site below turns the unreachable case into a loud
  # failure rather than a silent widening of the boundary.
  [[ "${TASK_TYPE:-review}" == "implement" ]] || return 0
  [[ "${INLINE_OUTPUT:-false}" != "true" ]] || return 0
  [[ -n "${STAGING_DIR:-}" ]] || return 0
  printf '%s\n%s\n' "-C" "$STAGING_DIR"
}

# `-C/--cd` arrived after the version this adapter was first written against, so
# an older codex on PATH would reject it during argv parsing — the perspective
# would be lost for the whole run and the report would show an INCOMPLETE
# artifact rather than "this machine's codex cannot confine the writes" (the
# Issue #403 failure shape). Worse, "just drop the flag on old versions" would
# put us back to writing anywhere in the repository with no signal at all. So
# require the capability up front and stop loudly if it is missing.
require_cd_capability() {
  local help rc=0
  help="$(run_with_timeout 30 "$CLI_COMMAND" exec --help 2>/dev/null)" || rc=$?
  if [[ "$rc" -ne 0 || -z "$help" ]]; then
    fail_orchestrator_error "$perspective_name" \
      "'${CLI_COMMAND} exec --help' を取得できませんでした（rc=${rc}）。implement の書き込み境界を staging へ絞る -C/--cd の有無を確認できないため、リポジトリ全体を書ける広い境界のまま起動せずに停止します。"
  fi
  case "$help" in
    *"-C, --cd"*) return 0 ;;
  esac
  fail_orchestrator_error "$perspective_name" \
    "インストール済みの ${CLI_NAME} は 'exec -C/--cd' を持ちません（'${CLI_COMMAND} exec --help' に -C, --cd が現れません）。このオプションが無いと implement の書き込み境界が staging ではなくリポジトリ全体になるため、黙って広い境界で走らせずに停止します。codex-cli を 0.149.1 以降へ更新してください（npm install -g @openai/codex）。"
}

# Pin the network off explicitly under workspace-write. The mode default is
# already `false`, so on a stock machine this changes nothing — it exists for the
# machine whose ~/.codex/config.toml (or a layered profile) sets
# `[sandbox_workspace_write] network_access = true`. Measured on 0.149.1 with
# `codex sandbox --log-denials`: with `network_access=true` an outbound connect
# goes through unlogged; adding this override brings back the
# `(curl) network-outbound` denial. The measurement holds with the write boundary
# narrowed to staging, so the two settings do not cancel each other. Without the
# pin the user gets a networked implement run with no signal anywhere — not in
# stdout, not in the artifact, not in the report.
#
# Passing it is weakly dominant, which is the whole argument. codex ignores an
# unrecognized `-c` key silently (measured, with and without --strict-config on
# `codex exec`), so if this key is ever renamed upstream the override simply stops
# applying — and the behaviour degrades to the mode default, i.e. exactly where we
# would have been without it. It can help and it cannot hurt. An earlier revision
# of this adapter used the silent-ignore property as a reason NOT to pin; that
# reasoning was wrong, because the failure mode it feared *is* the alternative.
#
# The silent ignore is still worth detecting, and it is detectable:
# `codex exec --strict-config` rejects an unknown `-c` override with rc=1 and
# "unknown configuration field ... in -c/--config override" (measured).
# tests/adapter-sandbox-contract probes exactly that in a throwaway CODEX_HOME, so
# a rename turns into a red test instead of a guard that quietly evaporates.
# --strict-config is deliberately NOT used here: it also hard-errors on any
# unrecognized field anywhere in the *user's own* config.toml, which would break
# runs on other people's machines for reasons unrelated to this override.
sandbox_config_args() {
  case "$1" in
    workspace-write) printf '%s\n%s\n' "-c" "sandbox_workspace_write.network_access=false" ;;
  esac
}

# ── Execute Task ──

echo "🔍 Running ${CLI_NAME} ${TASK_TYPE:-review}..." >&2
echo "   Perspective: ${perspective_name}" >&2
echo "   Task type: ${TASK_TYPE:-review}" >&2
echo "   Timeout: ${TIMEOUT}s" >&2

sandbox_mode="$(get_sandbox_mode)"
# bash 3.2 has no readarray; read the newline-separated pairs into an array with
# a plain loop. The values are fixed literals from sandbox_config_args, so there
# is no quoting hazard here, but keep them one-per-element so a value containing
# a space could never split into two argv entries.
SANDBOX_CONFIG_ARGS=()
while IFS= read -r _sandbox_cfg_arg; do
  [[ -n "$_sandbox_cfg_arg" ]] && SANDBOX_CONFIG_ARGS+=("$_sandbox_cfg_arg")
done <<EOF
$(sandbox_config_args "$sandbox_mode")
EOF

# 同じ理由で `-C <staging>` も 1 要素 1 引数で受ける（staging パスは空白を含みうる）。
CD_NARROW_ARGS=()
while IFS= read -r _cd_narrow_arg; do
  [[ -n "$_cd_narrow_arg" ]] && CD_NARROW_ARGS+=("$_cd_narrow_arg")
done <<EOF
$(cd_narrow_args)
EOF
# 「絞るはずの実行なのに -C が組み立てられなかった」を黙って通さない。ここで
# 素通りさせると、書き込み境界がリポジトリ全体に戻った implement が**警告なしで**
# 走る（プロンプトは staging を名指ししたままなので、出力からも判別できない）。
# 上のとおり build_prompt が先に拒否するので現状は到達しないが、防御の向きは
# 「絞れないなら止める」で揃えておく — 到達不能なガードが黙って広い方へ倒れる形は、
# このアダプタが他所（--add-dir の fail-open）で避けているクラスそのもの。
if [[ "${TASK_TYPE:-review}" == "implement" && "${INLINE_OUTPUT:-false}" != "true" \
      && "${#CD_NARROW_ARGS[@]}" -eq 0 ]]; then
  fail_orchestrator_error "$perspective_name" \
    "implement（非 inline）なのに書き込み境界を staging へ絞る -C を組み立てられませんでした（--staging-dir が空）。リポジトリ全体を書ける広い境界のまま起動せずに停止します。"
fi
if [[ "${#CD_NARROW_ARGS[@]}" -gt 0 ]]; then
  echo "   Write boundary: ${STAGING_DIR} (codex exec -C)" >&2
fi

# Guard this mktemp explicitly: under `set -e` a failure here would kill the
# adapter with a bare 1 before run_with_timeout is ever reached, filing a broken
# TMPDIR as "the CLI exited 1" and writing no artifact at all.
stderr_log="$(mktemp 2>/dev/null)" || stderr_log=""
if [[ -z "$stderr_log" ]]; then
  fail_orchestrator_error "$perspective_name" \
    "cannot create a temp file for ${CLI_NAME} stderr (check TMPDIR)."
fi

# モデルは既定では指定せず ~/.codex/config.toml に委譲する（ACE-70-2）。
# 明示指定が要るときは -p（プロファイル）が推奨経路 — プロファイルはモデルと
# model_reasoning_effort を 1 ファイルで束ねられるため、「古いモデル + 新しい
# reasoning effort」という意図しない組み合わせを避けられる。
#
# ただしその利点が成立するのは -p 単独のときだけ。codex 0.144.5 で実測すると
# -m を併用した場合は -m のモデルがプロファイルのモデルに勝ち、reasoning effort
# だけプロファイル由来になる — ACE-70-2 が問題視した組み合わせそのものになる。
# **版数は 0.144.5 のまま（意図）。** 優先順位はモデルへ到達しないと観測できず、
# 確認には課金される `codex exec` の実行が要るため、このファイルの他の主張と違って
# 0.149.1 では再測していない（していないものを再測したことにしない）。冒頭の
# 「版数は主張ごとの出典」の注記のとおり、ここを機械的に 0.149.1 へ書き換えないこと。
# 黙って通すと利用者は「プロファイルで束ねたつもり」のまま不整合な設定で走るので、
# 両方が設定されていたら落とす。
if [[ -n "${MULTI_AGENT_MODEL_CODEX_CLI:-}" && -n "${MULTI_AGENT_CODEX_PROFILE:-}" ]]; then
  fail_orchestrator_error "$perspective_name" \
    "MULTI_AGENT_MODEL_CODEX_CLI と MULTI_AGENT_CODEX_PROFILE は同時に指定できません（-m のモデルがプロファイルのモデルを上書きし、reasoning effort だけプロファイル由来という不整合な組み合わせになります）。どちらか一方にしてください。"
fi

# reasoning effort はモデルやプロファイルを作らず単発指定できる。Codex が受ける
# 設定 enum を adapter 側でも検証し、typo を base config への黙った fallback に
# しない。profile との併用は許可し、後段の -c が profile の値を明示上書きする。
if [[ "${MULTI_AGENT_CODEX_REASONING_EFFORT+x}" == "x" ]]; then
  case "${MULTI_AGENT_CODEX_REASONING_EFFORT:-}" in
    none|minimal|low|medium|high|xhigh|max|ultra) ;;
    *)
      fail_orchestrator_error "$perspective_name" \
        "MULTI_AGENT_CODEX_REASONING_EFFORT=${MULTI_AGENT_CODEX_REASONING_EFFORT:-} は不正です。none / minimal / low / medium / high / xhigh / max / ultra のいずれかを指定してください。"
      ;;
  esac
fi

# codex は**存在しないプロファイル名を黙って無視し、base config のまま完走する**
# （0.144.5 で実測）。**版数は 0.144.5 のまま（意図）。** 「完走する」の確認は
# モデルへ到達する実行を伴うため課金され、0.149.1 では再測していない。冒頭の
# 「版数は主張ごとの出典」の注記のとおり、機械的に書き換えないこと。
#
# 名前を打ち間違えると「専用プロファイルでレビューさせたつもり」のまま既定設定で
# 走り、成果物からもログからも判別できない。ラッパー側で存在を確認して落とす
# （ACE-70-2 の再発そのものを防ぐ）。
if [[ -n "${MULTI_AGENT_CODEX_PROFILE:-}" ]]; then
  codex_profile_file="${CODEX_HOME:-$HOME/.codex}/${MULTI_AGENT_CODEX_PROFILE}.config.toml"
  if [[ ! -f "$codex_profile_file" ]]; then
    fail_orchestrator_error "$perspective_name" \
      "MULTI_AGENT_CODEX_PROFILE=${MULTI_AGENT_CODEX_PROFILE} に対応する ${codex_profile_file} がありません。codex はプロファイル不在をエラーにせず base config のまま完走するため、ラッパー側で落としています。"
  fi
fi

# 引数不正は呼び出し側（このファイル）のバグ。素の呼び出しだと set -e が bare exit 2 で
# 落とすため、INCOMPLETE 成果物が残らず「CLI が 2 で落ちた」と誤読される。
reset_model_args
add_model_arg -m MULTI_AGENT_MODEL_CODEX_CLI \
  || fail_orchestrator_error "$perspective_name" "add_model_arg の呼び出しが不正です（アダプタ側のバグ）。"
add_model_arg -p MULTI_AGENT_CODEX_PROFILE \
  || fail_orchestrator_error "$perspective_name" "add_model_arg の呼び出しが不正です（アダプタ側のバグ）。"
if [[ -n "${MULTI_AGENT_CODEX_REASONING_EFFORT:-}" ]]; then
  MODEL_ARGS+=(-c "model_reasoning_effort=${MULTI_AGENT_CODEX_REASONING_EFFORT}")
fi
echo_model_args
if [[ -n "${MULTI_AGENT_CODEX_REASONING_EFFORT:-}" ]]; then
  if [[ -n "${MULTI_AGENT_CODEX_PROFILE:-}" ]]; then
    echo "   Reasoning effort: ${MULTI_AGENT_CODEX_REASONING_EFFORT} (explicit -c override; profile value is overridden)" >&2
  else
    echo "   Reasoning effort: ${MULTI_AGENT_CODEX_REASONING_EFFORT} (explicit -c override)" >&2
  fi
fi

# プロンプトは argv ではなく stdin で渡す（Issue #712: argv 渡しは Windows の
# CreateProcess 上限 ~32KB で exit 126 になる）。`codex exec -` は PROMPT を
# stdin から読む（0.149.1 の `codex exec --help` に明記 —「If not provided as an
# argument (or if `-` is used), instructions are read from stdin」。help を読むだけ
# なので無料で再確認でき、0.144.1 + 一時ファイル経由の実測も併せて済んでいる。
# 有限ファイルなので Issue #406 の stdin 待ちハングは起きない）。
prompt_file="$(materialize_prompt_file "$prompt")" || prompt_file=""
if [[ -z "$prompt_file" ]]; then
  fail_orchestrator_error "$perspective_name" \
    "cannot write the prompt to a temp file (check TMPDIR)."
fi
_FF_PROMPT_FILE="$prompt_file"

# 能力確認は起動直前に置く。ここより上の検証（モデル引数・プロファイル・TMPDIR）は
# すべてローカルで完結するので、それらが落ちる実行に CLI 起動を 1 回足さない。
if [[ "${#CD_NARROW_ARGS[@]}" -gt 0 ]]; then
  require_cd_capability
fi

# MODEL_ARGS は空になりうる。bash 3.2 では set -u 下で空配列を "${a[@]}" と
# 展開すると unbound variable で落ちるため ${a[@]+"${a[@]}"} を使う。
result=$(run_with_timeout --stdin-file "$prompt_file" "$TIMEOUT" \
  "$CLI_COMMAND" exec - \
    --sandbox "$sandbox_mode" \
    ${SANDBOX_CONFIG_ARGS[@]+"${SANDBOX_CONFIG_ARGS[@]}"} \
    ${CD_NARROW_ARGS[@]+"${CD_NARROW_ARGS[@]}"} \
    ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} \
  2>"$stderr_log") || {
    # Capture the status first: any command inside this block would overwrite $?.
    rc=$?
    fail_cli_task "$rc" "$stderr_log" "$perspective_name" "$result"
  }
rm -f "$prompt_file"
_FF_PROMPT_FILE=""
# exit 0 + 空出力。ここで stderr を先に捨てると「なぜ空だったか」を言う唯一の
# チャネルが消え、成果物も残らない（実測: レート制限の一文が stderr にだけ出て、
# 成果物もログも残らなかった — feel-flow/ff-dev-toolkit#6 の残件）。fail_cli_task
# へ通して、INCOMPLETE 成果物（stderr があれば抜粋つき）を残す。
if [[ -z "$result" ]]; then
  echo "ERROR: ${CLI_NAME} produced no output. The ${TASK_TYPE:-review} may have failed silently." >&2
  # クラッシュではない（0 で終了し、止められてもいない）。既定の reason のままだと
  # 「CLI が status 1 で落ちた／途中で止められた」と報告され、読み手は存在しない
  # クラッシュを追う。実際に見るべきは成果物に残る stderr 抜粋。
  record_timeout_reason empty-output
  fail_cli_task 1 "$stderr_log" "$perspective_name" ""
fi
# exit 0 + 非空でも、レビュー本文の実体行を 1 行も含まない捕捉結果は complete に
# しない（Issue #893。観測は claude-code だが、捕捉経路は「CLI の最終出力を command
# substitution で受ける」の 4 アダプタ共通形なので同じゲートを掛ける）。**受理条件の
# 正は adapter-common.sh の review_body_present ヘッダ** — ここに列挙を複製しない。
if [[ "${TASK_TYPE:-review}" == "review" ]] && ! review_body_present "$result"; then
  echo "ERROR: ${CLI_NAME} output ($(printf '%s' "$result" | wc -c | tr -d '[:space:]') bytes) contains no severity count/zero line, no severity-labeled finding line, and no finding bullet under a severity heading — refusing it as a review result. The review body may have been emitted in an earlier, uncaptured turn." >&2
  record_timeout_reason missing-review-body
  fail_cli_task 1 "$stderr_log" "$perspective_name" "$result"
fi
rm -f "$stderr_log"

# ── Write Output ──

write_output "$OUTPUT_FILE" "$CLI_NAME" "$perspective_name" "$result"
