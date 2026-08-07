#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────
# grok-cli-adapter.sh — Multi-CLI Agent: Grok CLI Adapter
# ────────────────────────────────────────────────────────────
# Usage: ./grok-cli-adapter.sh <perspective-file> <output-file> [options]
#
# Options:
#   --changed-files <files>   Comma-separated list of changed files
#   --base <branch>           Base branch for diff (default: auto-detect from origin/HEAD, fallback: develop)
#   --timeout <seconds>       Timeout in seconds (default: 900; the orchestrator always passes this explicitly)
#   --task-type <type>        review | explore | implement (default: review)
#   --description <text>      Task description (for explore/implement)
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
get_sandbox_profile() {
  case "${TASK_TYPE:-review}" in
    review)    echo "read-only" ;;
    explore)   echo "read-only" ;;
    # implement has to write its staging output, so it gets the profile that
    # allows CWD writes rather than no sandbox at all.
    #
    # Be honest about the gap: `workspace` permits writes anywhere under the CWD,
    # i.e. the whole working tree — while the implement preamble in
    # adapter-common.sh only *asks* the agent to confine itself to the staging
    # directory. The kernel enforces "not outside the CWD"; "not outside staging"
    # is a promise in the prompt. Narrowing that for every adapter (codex uses
    # network-off, gemini passes no sandbox at all) is tracked separately.
    implement) echo "workspace" ;;
    *)         echo "read-only" ;;
  esac
}

# ── Execute Task ──

echo "🔍 Running ${CLI_NAME} ${TASK_TYPE:-review}..." >&2
echo "   Perspective: ${perspective_name}" >&2
echo "   Task type: ${TASK_TYPE:-review}" >&2
echo "   Timeout: ${TIMEOUT}s" >&2

sandbox_profile="$(get_sandbox_profile)"

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

# MODEL_ARGS は空になりうる。bash 3.2 では set -u 下で空配列を "${a[@]}" と
# 展開すると unbound variable で落ちるため ${a[@]+"${a[@]}"} を使う。
result=$(run_with_timeout "$TIMEOUT" \
  "$CLI_COMMAND" -p "$prompt" \
    --sandbox "$sandbox_profile" \
    --output-format plain \
    ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} \
  2>"$stderr_log") || {
    # Capture the status first: any command inside this block would overwrite $?.
    rc=$?
    fail_cli_task "$rc" "$stderr_log" "$perspective_name" "$result"
  }

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
# ゼロではない。完全な相関には実行 ID かログ単位の排他が要る。
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
rm -f "$stderr_log"

# ── Write Output ──

write_output "$OUTPUT_FILE" "$CLI_NAME" "$perspective_name" "$result"
