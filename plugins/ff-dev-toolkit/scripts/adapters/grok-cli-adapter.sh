#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────
# grok-cli-adapter.sh — Multi-CLI Agent: Grok CLI Adapter
# ────────────────────────────────────────────────────────────
# Usage: ./grok-cli-adapter.sh <perspective-file> <output-file> [options]
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
# Plan-time probe (no perspective / output file):
#   ./grok-cli-adapter.sh --probe-sandbox [task-type]
#     Reports whether this environment can apply the sandbox profile this adapter
#     would request for <task-type> (default: review). Exit 3 = the sandbox this
#     adapter asks for will not be in effect here; exit 0 = nothing was determined.
#     The probe does NOT take --inline-output: it measures the profile for the
#     task-type the orchestrator passes, which is what the plan is about (for
#     implement, `workspace`). --inline-output would make the real run ask for
#     `read-only` instead; the probe does not model that, and no option is added
#     for it — the plan does not know that flag either. See run_sandbox_probe.
#
# Requires: grok (npm i -g @xai-official/grok)
# Cost tier: Flat-rate (subscription)
# ────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/adapter-common.sh"

readonly CLI_NAME="Grok CLI"
readonly CLI_COMMAND="grok"

# ── Preflight ──

if ! cli_available "$CLI_COMMAND"; then
  echo "ERROR: ${CLI_NAME} (${CLI_COMMAND}) is not installed." >&2
  echo "Install: npm install -g @xai-official/grok" >&2
  exit 1
fi

# ── Parse Arguments ──

# --probe-sandbox はタスクを走らせない別入口なので、観点ファイルも出力先も取らない。
# parse_adapter_args は両方を必須にしている（無ければ usage で rc=1）ため、この分岐は
# パーサーより前に置く。プロンプト構築も行わない — probe が見るのは
# 「この環境でサンドボックスを適用できるか」だけで、diff も観点も要らない。
PROBE_SANDBOX="false"
if [[ "${1:-}" == "--probe-sandbox" ]]; then
  PROBE_SANDBOX="true"
  TASK_TYPE="${2:-review}"
  INLINE_OUTPUT="false"
else
  parse_adapter_args "$@"

  # perspective_name は build_prompt 失敗時の fail_orchestrator_error にも要る。
  # build_prompt を mktemp ガードより前に素で呼ぶと set -e が bare exit し、
  # INCOMPLETE 成果物が残らない（プロンプト構築の失敗を無言の欠落にしないための順序）。
  perspective_name="$(basename "$PERSPECTIVE_FILE" .md)"

  # ── Build Prompt ──

  if ! prompt="$(build_prompt "$PERSPECTIVE_FILE" "$BASE_BRANCH" "$CHANGED_FILES")"; then
    fail_orchestrator_error "$perspective_name" \
      "cannot build the ${TASK_TYPE:-review} prompt (perspective missing, empty diff, or load failure)."
  fi
fi

# ── Task-type specific sandbox ──
#
# grok's --sandbox takes a built-in profile name and is enforced by the kernel
# (Seatbelt on macOS, Landlock on Linux), so it holds for the agent's own file
# tools, anything it spawns through the shell, and MCP servers alike.
#
# Measured on grok 0.2.118, with the agent explicitly told to write and to fall
# back to the shell if its tools failed:
#   --sandbox read-only    → Write tool and printf/echo/touch/cp/dd/python/perl
#                            all returned "Operation not permitted". No file
#                            created, no file modified.
#   --permission-mode plan → the file WAS created and a.txt WAS appended to.
#                            Plan mode is not a write guard; do not use it here.
#   --tools <allowlist>    → blocks the built-in tools only. `--help` says
#                            "Built-in tools to allow", and the agent was
#                            observed reaching for an MCP server instead.
#
# Caveat when re-verifying: the read-only profile permits writes to /tmp,
# /var/tmp and ~/.grok by design. Running the check inside a temp directory
# reports a false negative — the first attempt here did exactly that.
#
# Provenance is stale and cannot be refreshed for free. The table above was
# measured on grok 0.2.118; a 1.0.5 install was observed on another machine
# (2026-08-26). Unlike codex — which ships `codex sandbox`, a subcommand that runs
# an arbitrary command under the same sandbox without invoking a model — grok has
# no way to exercise the WRITE rows offline: proving that a write is blocked needs
# an agent that attempts one, and that is a billed run. So the WRITE rows above are
# NOT re-measured beyond 0.2.118, and this comment does not claim they are.
#
# What IS available offline is narrower and is used by run_sandbox_probe below:
# whether the profile can be **applied at all** in this environment. That question
# is decided at startup, before any model call, so a non-agent subcommand answers
# it for free. Do not read the probe as reviving the write rows — it says nothing
# about what the applied profile then blocks.
#
# Network boundary (Issue #897, measured 2026-09-01 on grok 0.2.118, macOS
# seatbelt, billed runs — commands and results in
# tests/adapter-sandbox-contract/README.md):
#   --sandbox workspace  → ProfileApplied restrict_network:false, and an
#                          outbound HTTPS fetch to an external host SUCCEEDED.
#   --sandbox read-only  → ProfileApplied records restrict_network:true,
#                          enforced:true — and the same outbound HTTPS fetch
#                          STILL SUCCEEDED. The declaration and the effective
#                          boundary diverge on macOS; do not treat a
#                          restrict_network:true record as proof of isolation.
#   Fabrication was ruled out by having the sandboxed agent return the HTTP
#   Date response header, which landed between wall-clock timestamps taken
#   immediately before and after the read-only run.
# grok has no VERIFIED way to close the network: there is no codex-style
# `-c sandbox_workspace_write.network_access=false` equivalent, and while
# ~/.grok/sandbox.toml can define custom profiles, the read-only measurement
# above shows that a profile *recording* restrict_network:true still passes
# outbound HTTPS on macOS — so a custom profile pinning the same knob cannot
# be expected to hold either (custom-profile blocking itself is unmeasured).
# The asymmetry with codex implement (network pinned off) is therefore a
# measured, currently unfixable fact. The adapter therefore TELLS the user before every
# dispatch (see the notice below get_sandbox_profile) instead of silently
# running open — that notice is the "do not run open silently" half of the AC.
# This cannot become a standing gate: measuring requires a billed agent run,
# so it stays a recorded measurement, like the write rows above.
#
# Write-boundary narrowing (Issue #896): codex confines implement writes to the
# staging dir alone via `codex exec -C <staging>`. The equivalent for grok is
# UNMEASURED, not impossible. grok 1.0.5 does expose `--cwd <CWD>` ("Working
# directory"), so the mechanism plausibly exists — but whether the `workspace`
# profile's write root follows `--cwd` cannot be established without a billed
# run, for the reason above. Until someone measures it, the asymmetry stands and
# is intentional:
#
#   codex implement … writes confined to staging by the sandbox
#   grok  implement … writes confined to the repository by the sandbox;
#                     staging-only remains a prompt contract
#
# Do not narrow this adapter on the strength of the codex measurement. The two
# CLIs implement their sandboxes independently, and a `--cwd` that only relocated
# the CWD without moving the sandbox root would silently change nothing while the
# comment claimed otherwise.
get_sandbox_profile() {
  if [[ "${TASK_TYPE:-review}" == "implement" && "${INLINE_OUTPUT:-false}" == "true" ]]; then
    echo "read-only"
    return
  fi
  case "${TASK_TYPE:-review}" in
    review)    echo "read-only" ;;
    explore)   echo "read-only" ;;
    # implement has to write its staging output, so it gets the profile that
    # allows CWD writes rather than no sandbox at all.
    #
    # `workspace` permits writes anywhere under the CWD. multi-agent.sh fixes that
    # CWD to REPO_ROOT and rejects output dirs outside it before launch; confining
    # writes from the whole repository to staging alone remains a prompt contract
    # here (see the note above on why the codex-style narrowing is not copied over).
    implement) echo "workspace" ;;
    *)         echo "read-only" ;;
  esac
}

# ── Sandbox applicability probe（--probe-sandbox） ──
#
# 潰す事故: **プランには載るのに一度も走らない CLI**。サンドボックスを適用できない
# 環境では grok はモデルを呼ぶ前に起動を拒否する（status 1、stdout 空）。実行時の
# 検出は既にあるが、それが分かるのはタスクを 1 つ丸ごと失ったあとで、dry-run は
# 毎回「載る」としか言わない。起動前に決まっている失敗は起動前に言う。
#
# 課金しない probe が成立する理由（本実装の要点）。サンドボックスの適用は起動時に
# 済み、失敗すればそこで拒否される — つまり**エージェントを走らせないサブコマンド**
# でも同じ適用経路を踏む。実測（grok 0.2.118 / macOS seatbelt、2026-09-06）:
#   grok --sandbox read-only inspect  → rc=0。sandbox-events.jsonl へ
#                                       ProfileApplied / enforced:true が 1 行増える。
#                                       モデル呼び出し・ネットワーク往復は無し
#   grok --sandbox workspace inspect  → rc=0（同上）
#   grok --sandbox <適用できない値> inspect
#                                     → rc=1、stderr に
#                                       "warning: sandbox could not be applied: ..." と
#                                       "... refusing to start." — 観測台帳が記録した
#                                       実環境の失敗（runtime-socket の deny path が
#                                       symlink）と同じ形
# `inspect` を選ぶのは、設定探索を表示するだけでローカル完結だから。`models` は
# 同じくサンドボックスを適用するが認証済みアカウントへ問い合わせるので使わない。
# **`inspect` の存在は grok 0.2.118 で実測したもの**で、ベンダーの互換保証ではない。
# 将来のバージョンで消える・改名されると probe は「目印が出ない」経路へ落ちて
# fail-open で黙る（= 警告が消えるだけで、赤くはならない）。probe が常に無言に
# なったらまずこのサブコマンドの現存を疑うこと。
#
# **副作用**: probe も本物の起動なので、適用に成功したときは
# ${GROK_HOME:-~/.grok}/sandbox-events.jsonl へ ProfileApplied を 1 行足す。
# GROK_HOME を一時領域へ逃がして避けることはしない — 逃がすと ~/.grok/sandbox.toml
# の探索先まで変わり、**本番とは別の条件**を測ることになるため。この追記が下の
# ProfileApplied ゲートに与える影響は、そのゲート側のコメント（残る限界）に書く。
#
# 判定は**片側だけ**。拒否を確定できたときにだけ非 0 を返し、それ以外は 0 を返す
# （= 呼び出し側は黙る）。「適用できる」と断定はしない — probe が rc=0 で返っても、
# 本番の実行が別の理由で拒否される可能性は消えないし、実際にサンドボックスが効いた
# かどうかの肯定確認は下の ProfileApplied ゲートが実行のたびに取り直す。誤った断定
# （「この環境では動く」）は、動かなかったときに読み手を無関係な原因へ送る。
#
# 認証・残高は probe の対象外。オーケストレータ側が dispatch 前の preflight probe を
# 採らなかった判断（classify_cli_failure_cause のヘッダー）は生きている — あちらの
# 理由は「残高・認証は課金される API 呼び出しをしないと分からない」で、ここで見るのは
# 環境固有・決定的・起動前に確定する別種の性質なので、その判断とは衝突しない。
readonly SANDBOX_PROBE_REFUSED_STATUS=3
# probe はローカル完結なので長い猶予は要らない。刺さったまま dry-run を止めない
# ための上限で、公開つまみにはしない（延ばして直る種類の失敗ではない）。
readonly SANDBOX_PROBE_TIMEOUT=30

# 目印は **stderr の行頭**にアンカーして見る。stdout を混ぜた部分一致で拾うと、
# `inspect` が設定ダンプとして同じ語を素通しで出しただけ・別のエラーが文中で
# 引用しただけで「拒否」と読み、存在しない環境問題を毎回警告することになる。
#
# 区別する形は 2 つ:
#   REFUSED — 起動を拒否する側。warning 行と error 行が対で出て、rc も非 0 になる
#             （実測 rc=1）。rc≠0 と目印の両方が揃ったときだけ拒否と読む
#   UNSANDBOXED — サンドボックス**無しで続行する**側。こちらは rc=0 で走りうるので
#             rc は条件にしない。走ってもレビュー結果は下の ProfileApplied ゲートが
#             refuse するので、プラン時点で言うべきことは同じ（ただし理由が違う）
readonly SANDBOX_MARKER_REFUSED_WARNING='^warning: sandbox could not be applied'
readonly SANDBOX_MARKER_REFUSED_ERROR='^error: could not apply the .* sandbox profile'
readonly SANDBOX_MARKER_UNSANDBOXED='^Sandbox could not be applied, continuing without sandbox'

# 出力契約: 拒否を確定できたときだけ stdout に 2 行を書き、
# SANDBOX_PROBE_REFUSED_STATUS を返す。
#   1 行目 = 種別（refused-to-start / unsandboxed-start）— 呼び出し側の帰結文の出し分け用
#   2 行目 = CLI 自身が出した理由の行（そのまま）
# それ以外（rc=0 / timeout / 想定外の rc / 目印なし）は無出力で rc=0（fail-open）。
run_sandbox_probe() { # $1: profile
  local profile="$1" stderr_file="" probe_stdout="" probe_rc=0 marker=""
  if ! stderr_file="$(mktemp)"; then
    # probe の足回りすら用意できない環境では何も確定できない。fail-open。
    return 0
  fi
  # 起動形は他のアダプタ呼び出しと同じ「コマンド置換で受ける」形に揃える
  # （run_with_timeout はこの形を前提に stdin の EOF を保証している）。判定に
  # 使うのは stderr だけなので、stdout はファイルへ分けずに置換で捨てる。
  probe_stdout="$(run_with_timeout "$SANDBOX_PROBE_TIMEOUT" \
    "$CLI_COMMAND" --sandbox "$profile" inspect 2>"$stderr_file")" || probe_rc=$?
  : "${probe_stdout:-}"

  # timeout は「拒否」ではない。刺さった probe を環境の欠陥として警告すると、
  # 一時的な負荷が恒久的な環境問題として表示され続ける。
  if [[ "$probe_rc" -eq "$TIMEOUT_EXIT_CODE" ]]; then
    rm -f "$stderr_file"
    return 0
  fi

  marker="$(grep -m1 -E "$SANDBOX_MARKER_UNSANDBOXED" "$stderr_file" || true)"
  if [[ -n "$marker" ]]; then
    printf 'unsandboxed-start\n%s\n' "$marker"
    rm -f "$stderr_file"
    return "$SANDBOX_PROBE_REFUSED_STATUS"
  fi

  if [[ "$probe_rc" -ne 0 ]]; then
    marker="$(grep -m1 -E "$SANDBOX_MARKER_REFUSED_WARNING" "$stderr_file" || true)"
    if [[ -z "$marker" ]]; then
      marker="$(grep -m1 -E "$SANDBOX_MARKER_REFUSED_ERROR" "$stderr_file" || true)"
    fi
    if [[ -n "$marker" ]]; then
      printf 'refused-to-start\n%s\n' "$marker"
      rm -f "$stderr_file"
      return "$SANDBOX_PROBE_REFUSED_STATUS"
    fi
  fi

  # 想定外の rc（未ログイン・サブコマンド消失・CLI 不在）は拒否と読まない。
  rm -f "$stderr_file"
  return 0
}

if [[ "$PROBE_SANDBOX" == "true" ]]; then
  probe_rc=0
  run_sandbox_probe "$(get_sandbox_profile)" || probe_rc=$?
  exit "$probe_rc"
fi

# ── Execute Task ──

echo "🔍 Running ${CLI_NAME} ${TASK_TYPE:-review}..." >&2
echo "   Perspective: ${perspective_name}" >&2
echo "   Task type: ${TASK_TYPE:-review}" >&2
echo "   Timeout: ${TIMEOUT}s" >&2

sandbox_profile="$(get_sandbox_profile)"

# grok のサンドボックスは outbound network を遮断しない（Issue #897 の実測
# 2026-09-01 / grok 0.2.118 / macOS: workspace は宣言どおり開放、read-only は
# restrict_network:true を記録しながら外部 HTTPS が通る）。閉じる設定手段が無い
# ため、黙って開放のまま走らせず毎回提示する（codex implement は network を
# 明示ピンで遮断しており、非対称）。Linux（Landlock）は未測定だが、保守側 =
# 開放前提に倒して同じ通知を出す（意図的な過剰警告。測定したら文言を分岐する）。
echo "   ⚠️ network: grok の '${sandbox_profile}' sandbox は外部ネットワークを遮断しません（macOS 実測 2026-09-01 / 0.2.118、Linux は未測定・開放前提。codex と非対称）" >&2

# サンドボックス適用の肯定確認は、この実行で**追記された**イベントだけを見る。
# 実行前の行数を控えておく。
#
# 行数を取れなかったときに 0 で代用してはいけない。0 だと実行後の `tail -n +1` が
# ファイル全体を「この実行の追記分」として返し、**前回の実行が残した ProfileApplied**
# で確認が成立する（実測で再現）。baseline を確立できないなら確認もできないので、
# 空にして後段で fail-closed に倒す。
# grok home の解決順は GROK_HOME → HOME（CLI 側も同じ順で、無ければ
# "no user grok home (set $GROK_HOME or $HOME)" で落ちる）。ここで素に $HOME を
# 参照すると、両方未設定の環境（CI コンテナ / systemd / cron）で set -u が
# bare exit 1 を投げ、成果物を 1 つも残さずに終わる — 3 行下の mktemp ガードが
# まさに防いでいる形の失敗を、そのガードの手前で作ることになる。
sandbox_home="${GROK_HOME:-${HOME:-}}"
if [[ -z "$sandbox_home" ]]; then
  fail_orchestrator_error "$perspective_name" \
    "GROK_HOME も HOME も設定されていないため、${CLI_NAME} のサンドボックス適用を確認できません。"
fi
if [[ -n "${GROK_HOME:-}" ]]; then
  sandbox_events_file="${GROK_HOME}/sandbox-events.jsonl"
else
  sandbox_events_file="${sandbox_home}/.grok/sandbox-events.jsonl"
fi
sandbox_events_before=""
if [[ -f "$sandbox_events_file" ]]; then
  sandbox_events_before="$(wc -l < "$sandbox_events_file" 2>/dev/null | tr -d ' ' || true)"
  [[ "$sandbox_events_before" =~ ^[0-9]+$ ]] || sandbox_events_before=""
else
  # ファイル未作成なら、この実行が作る分がまるごと追記分になる。
  sandbox_events_before=0
fi
# Guard this mktemp explicitly: under `set -e` a failure here would kill the
# adapter with a bare 1 before run_with_timeout is ever reached, filing a broken
# TMPDIR as "the CLI exited 1" and writing no artifact at all.
stderr_log="$(mktemp 2>/dev/null)" || stderr_log=""
if [[ -z "$stderr_log" ]]; then
  fail_orchestrator_error "$perspective_name" \
    "cannot create a temp file for ${CLI_NAME} stderr (check TMPDIR)."
fi

# モデルは既定では指定せず Grok CLI 側の設定に委譲する（ACE-70-2）。
# MULTI_AGENT_MODEL_GROK_CLI が設定されたときだけ -m を渡す。
# 引数不正は呼び出し側（このファイル）のバグ。素の呼び出しだと set -e が bare exit 2 で
# 落とすため、INCOMPLETE 成果物が残らず「CLI が 2 で落ちた」と誤読される。
reset_model_args
add_model_arg -m MULTI_AGENT_MODEL_GROK_CLI \
  || fail_orchestrator_error "$perspective_name" "add_model_arg の呼び出しが不正です（アダプタ側のバグ）。"
echo_model_args

# プロンプトは argv ではなく一時ファイルで渡す（Issue #712: argv 渡しは Windows の
# CreateProcess 上限 ~32KB で exit 126 になる）。grok は stdin をプロンプトとして
# 読まない（0.2.118 で実測: stdin のマーカーが届かない）ため、専用の
# `--prompt-file <PATH>`（Single-turn prompt from a file）を使う（同バージョンで
# 実測済み）。stdin は run_with_timeout の既定どおり /dev/null に閉じる。
prompt_file="$(materialize_prompt_file "$prompt")" || prompt_file=""
if [[ -z "$prompt_file" ]]; then
  fail_orchestrator_error "$perspective_name" \
    "cannot hand the prompt to the CLI (temp-file write failed, or the prompt is not valid UTF-8 — see the error above)."
fi
_FF_PROMPT_FILE="$prompt_file"

# MODEL_ARGS は空になりうる。bash 3.2 では set -u 下で空配列を "${a[@]}" と
# 展開すると unbound variable で落ちるため ${a[@]+"${a[@]}"} を使う。
result=$(run_with_timeout "$TIMEOUT" \
  "$CLI_COMMAND" --prompt-file "$prompt_file" \
    --sandbox "$sandbox_profile" \
    --output-format plain \
    ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} \
  2>"$stderr_log") || {
    # Capture the status first: any command inside this block would overwrite $?.
    rc=$?
    fail_cli_task "$rc" "$stderr_log" "$perspective_name" "$result"
  }
rm -f "$prompt_file"
_FF_PROMPT_FILE=""

# ── Confirm the sandbox actually took effect ──
#
# The sandbox is the whole reason this adapter is safe to point at a working tree,
# so it is verified positively rather than by the absence of a warning.
#
# Measured on grok 0.2.118 (do not re-derive these from the flag names):
#   - A successful sandboxed run writes **nothing** to stderr. There is no
#     confirmation line to grep for.
#   - The confirmation is structured, in ${GROK_HOME:-~/.grok}/sandbox-events.jsonl:
#       {"event_type":"ProfileApplied","profile":"read-only","enforced":true,...}
#     The binary also carries an "ApplyFailed" event type.
#   - The binary contains TWO different failure strings, and they behave
#     differently:
#       "warning: sandbox could not be applied:"            → CLI refuses to start
#                                                             (exit 1, empty stdout)
#       "Sandbox could not be applied, continuing without sandbox"
#                                                           → runs UNSANDBOXED
#     An earlier version of this guard grepped only for the first — the one the
#     exit-code path already covers — and therefore missed the only case it was
#     written to defend against. Matching a string this adapter invented, and then
#     stubbing that same invented string in the test, made the check agree with
#     the bug (ACE-249-1).
#
# So: require the positive event, and treat "cannot tell" as failure. A review
# that silently ran unsandboxed is worse than one that loudly did not run.
new_sandbox_events=""
if [[ -n "$sandbox_events_before" && -f "$sandbox_events_file" ]]; then
  new_sandbox_events="$(tail -n "+$((sandbox_events_before + 1))" "$sandbox_events_file" 2>/dev/null || true)"
fi

# 3 条件を別々に grep すると**別々の行**で成立してしまう。実測: 「workspace が
# enforced:false で適用された」行と「read-only を含む無関係な行」が並んでいるだけで
# 「read-only が enforced で適用された」と判定された。1 行が 3 条件すべてを満たす
# ことを要求する。
#
# 行数の差分だけでは、同じイベントログを共有する**別プロセス**の成功イベントを
# 自分の証明として受け取りうる（同時に走る 2 つの grok が同じ baseline を取る）。
# イベント行の workspace で相関させて絞る。実測でこの値は `pwd -P` と一致する
# （シンボリックリンクは解決済みで記録される）。
#
# 残る限界: 同一ディレクトリ・同一プロファイルでの並行実行は相関しきれない。
# オーケストレータはタスクごとに grok を 1 つしか計画しないので露出は小さいが、
# ゼロではない。完全な相関には実行 ID かログ単位の排他が要る（未実装）。
#
# **この限界には dry-run の sandbox probe も乗る。** probe（run_sandbox_probe）も
# 本物の起動なので、成功時は同じ sandbox-events.jsonl へ ProfileApplied を 1 行足す。
# 同一 worktree で dry-run と実行が並行すると、probe が書いた行がこちらの窓に入り、
# プロファイルが違えば other_profile として**偽陰性**（実際には効いていたのに
# 「確認できない」）になりうる。probe を GROK_HOME ごと一時領域へ逃がす回避は
# 採らない — 逃がすと ~/.grok/sandbox.toml の探索先まで変わり、probe が本番とは
# 別の条件を測ることになるため。解消も上と同じ実行 ID / ログ排他が要る。
#
# 判定は awk で「1 行が全条件を含む」を見る。正規表現で `.*` を挟んで繋ぐと JSON の
# フィールド順に依存し、並びが変わっただけで確認が取れなくなる（実測: 実際の行は
# timestamp が先頭で、`{"event_type"` を先頭に置いた初版パターンは正常系まで落とした）。
# index() なら順序非依存で、部分文字列の意味も変わらない。
sandbox_workspace="$(pwd -P 2>/dev/null || pwd)"

# 判定は awk で「1 行が全条件を含む」を見る。正規表現で `.*` を挟んで繋ぐと JSON の
# フィールド順に依存し、並びが変わっただけで確認が取れなくなる（実測: 実際の行は
# timestamp が先頭で、`{"event_type"` を先頭に置いた初版パターンは正常系まで落とした）。
# index() なら順序非依存で、部分文字列の意味も変わらない。
#
# workspace で相関させるのは、同じイベントログを共有する**別プロセス**の成功イベントを
# 自分の証明として受け取らないため（行数の差分だけでは並行実行を切り分けられない）。
# 実測でこの値は `pwd -P` と一致する。残る限界は同一ディレクトリ・同一プロファイルでの
# 並行実行で、完全な相関には実行 ID かログ単位の排他が要る。
#
# 失格条件は「肯定の裏返し」で対称に置く。肯定だけを条件にすると、要求より広い
# プロファイルが同じ窓で適用されていても通ってしまう（実ログでは 107ms の間に
# workspace / read-only / strict の 3 プロファイルが並ぶことがある）。
#   ApplyFailed    — 適用そのものの失敗
#   BypassGranted  — 個別操作が deny を迂回できた記録（operation / target / command /
#                    tool_call_id を伴う操作系イベント）。意味論はベンダー文書で確認
#                    できていないが、名前と随伴フィールドから離脱と読むのが保守側。
#                    実測ではレビュー実行中に一度も出ていない
#   FsViolation / NetViolation は**失格にしない**。これはサンドボックスが実際に
#   操作を止めた記録で、機能している証拠だから（実測: 書き込みを試させたときに 1 件出た）
sandbox_confirmed=false
if [[ -n "$new_sandbox_events" ]] \
  && printf '%s\n' "$new_sandbox_events" \
     | awk -v prof="\"profile\":\"${sandbox_profile}\"" -v ws="\"workspace\":\"${sandbox_workspace}\"" '
         index($0, "\"event_type\":\"ProfileApplied\"") && index($0, ws) {
           if (index($0, prof) && index($0, "\"enforced\":true")) applied = 1
           else other_profile = 1          # 要求と違うプロファイルが同じ窓で適用された
         }
         index($0, "\"event_type\":\"ApplyFailed\"")   { failed = 1 }
         index($0, "\"event_type\":\"BypassGranted\"") { failed = 1 }
         END { exit (applied && !other_profile && !failed) ? 0 : 1 }
       '; then
  sandbox_confirmed=true
fi


# backstop として stderr の警告文字列も見ていたが、撤去した。真理値表を取ると、
# その grep が結果を変えるのは「肯定確認が取れている」行だけで、コメントが謳って
# いた「イベントログが使えないときの保険」では sandbox_confirmed が既に false な
# ため出番が無い。つまり唯一の効き目は**確認が取れた実行を捨てること**で、実際
# stderr がその文言を引用しただけの実行を落とした（無アンカーの grep は、CLI 自身の
# 警告と CLI が中継した文字列を区別できない）。肯定確認だけに寄せる。
if [[ "$sandbox_confirmed" != "true" ]]; then
  echo "ERROR: ${CLI_NAME} did not confirm the '${sandbox_profile}' sandbox took effect." >&2
  echo "       Expected a ProfileApplied/enforced event in ${sandbox_events_file}." >&2
  echo "       Refusing the result: this ${TASK_TYPE:-review} may have run with wider" >&2
  echo "       filesystem access than intended, so its findings are unverified." >&2
  # Not a CLI crash — it may well have exited 0 and reached a conclusion. Record
  # the real reason so the report names the sandbox rather than sending the
  # reader after a crash that never happened.
  record_timeout_reason sandbox-refused
  fail_cli_task 1 "$stderr_log" "$perspective_name" "$result"
fi

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
