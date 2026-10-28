#!/usr/bin/env bash
# adapter-common.sh の構成ファイル: 壁時計の制限・CLI 失敗の説明・モデル引数・effort。
#
# scripts/adapters/adapter-common.sh が source されたときに 1 回だけ source する
# （直接実行しない）。読み込む順・読めないときの停止は入口の
# ADAPTER_COMMON_PARTS が正本。本文は分割前の adapter-common.sh の連続した行そのままで、
# トップレベルの初期化（readonly・trap）も分割前と同じ順に走る。
# ここへ set / trap / source を足さない（本文に元からある trap は分割前のまま）。
# 末尾の _ac_part_loaded の行は読み込み完了の印。bash 3.2 互換。分割の判断は ADR-075。
# pipefail-inherited: 呼び出し元の adapter が set -euo pipefail の下で adapter-common.sh を source する
# Run a command under a wall-clock limit and echo whatever it wrote to stdout.
# Usage: run_with_timeout [--stdin-file <path>] 900 some_command arg1 arg2
#
# --stdin-file <path> は子プロセスの stdin を /dev/null ではなく指定ファイルへ
# 接続する（Issue `#712`: プロンプトを argv で渡すと Windows / Git Bash の
# CreateProcess 上限（約 32KB）を超えた時点で npm shim の node 起動が
# "Argument list too long" の exit 126 になるため、プロンプト本文は stdin か
# CLI のファイル渡しオプションで渡す）。通常ファイルは読み切りで必ず EOF に
# 到達するため、下記コメントの「held-open pipe を待ち続ける」ハングは再発
# しない — 危険なのは stdin を**開いたまま**にする形であり、有限のファイルを
# 与える形ではない。
#
# Returns the command's own exit status, $TIMEOUT_EXIT_CODE (124) when the limit
# fired, or $ORCHESTRATOR_ERROR_EXIT_CODE (125) when this wrapper could not run
# the command at all. Output produced before a kill is still echoed, so a caller
# can salvage partial work instead of discarding it.
#
# Why this supervises the child itself instead of delegating to timeout(1):
# timeout(1)'s exit status cannot say *why* the child died. Measured on GNU
# coreutils 9.7, `timeout -k` returns 124 when the child dies on SIGTERM inside
# the grace period but 137 when it had to escalate to SIGKILL — and a bare 137
# also means "something else SIGKILLed the child" (the OS under memory pressure,
# say). One status, two causes, opposite remedies: "allow more time" fixes the
# first and buries the second. The marker file below removes the ambiguity, so
# 124 always means the deadline and 137 always means an external kill. Running
# one implementation everywhere also means the regression suite covers the code
# that actually runs, on every host.
#
# Three independent guards live here. None substitutes for another:
#
#   1. **The child's stdout goes to a temp file**, never the inherited fd, so the
#      child cannot hold the caller's `$(...)` capture pipe open.
#   2. **The watchdog runs in its own process group and is killed as a group.**
#      This is the guard that makes an early-finishing command return early.
#      Killing only the watchdog subshell leaves its in-flight `sleep` alive as an
#      orphan; an orphan that had inherited the capture pipe keeps `$(...)` from
#      closing, so `result=$(run_with_timeout 900 fast_cmd)` blocked for the full
#      900s even though the command answered in 2s — measured, and exactly what
#      the old implementation did on hosts without timeout(1) (stock macOS; hosts
#      that had timeout(1) never stalled). The /dev/null redirect below is a
#      second line of defence on the same failure: verified that with guard 1 in
#      place but the redirect removed, a 2s command under a 12s limit still
#      blocked the full 12s.
#   3. **The child is a process-group leader and signals go to the group.**
#      Signalling only the direct child leaves the CLI's own workers running —
#      and, for a metered CLI, still billing — past the deadline.
#
# For the record, none of the three caused issue `#152`'s *empty* review. That was
# the adapters' failure path discarding already-captured stdout (see
# fail_cli_task). Guard 2's absence is what made raising the default timeout
# unaffordable, and the old bare `1` return is what made targeted advice
# impossible.
#
# Test seam: FF_TIMEOUT_KILL_GRACE shortens the SIGTERM→SIGKILL grace period.
#
# The *reason* for a non-zero status travels out of band, via timeout_reason_file
# below — an exit status is one channel and would otherwise carry two meanings.
run_with_timeout() {
  local stdin_source=/dev/null
  if [[ "${1:-}" == "--stdin-file" ]]; then
    # 既知の残余（TOCTOU）: この検査と実際の open（子起動時のリダイレクト）の間に
    # ファイルが消えると、リダイレクト失敗は rc=1 として「CLI が 1 で落ちた」に
    # 帰属される（reason は既に command）。bash のエラーメッセージは stderr_log 経由で
    # INCOMPLETE 成果物に残るため無言にはならない。tmp reaper との競合という低頻度
    # ケースのため、帰属の正確化よりコードの単純さを取って受容する。
    if [[ ! -f "${2:-}" || ! -r "${2:-}" ]]; then
      echo "ERROR: run_with_timeout: --stdin-file '${2:-}' is not a readable regular file." >&2
      record_timeout_reason orchestrator-error
      return "$ORCHESTRATOR_ERROR_EXIT_CODE"
    fi
    stdin_source="$2"
    shift 2
  fi
  local timeout_seconds="$1"
  shift

  if [[ -z "${_FF_REASON_PRIVATE_DIR:-}" ]] || ! _ff_reason_parent_is_safe "$_FF_REASON_PRIVATE_DIR"; then
    echo "ERROR: run_with_timeout: cannot allocate a private directory for command metadata." >&2
    record_timeout_reason orchestrator-error
    return "$ORCHESTRATOR_ERROR_EXIT_CODE"
  fi
  record_timeout_reason command

  local out_file marker
  if ! out_file="$(mktemp "${_FF_REASON_PRIVATE_DIR}/command.XXXXXX")"; then
    echo "ERROR: run_with_timeout: cannot create a temp file for command output." >&2
    record_timeout_reason orchestrator-error
    return "$ORCHESTRATOR_ERROR_EXIT_CODE"
  fi
  if ! marker="$(mktemp "${_FF_REASON_PRIVATE_DIR}/deadline.XXXXXX")"; then
    echo "ERROR: run_with_timeout: cannot create a temp file for the timeout marker." >&2
    rm -f "$out_file"
    record_timeout_reason orchestrator-error
    return "$ORCHESTRATOR_ERROR_EXIT_CODE"
  fi

  # Job control makes each background job a process-group leader (pgid == pid),
  # which both guard 2 and guard 3 rely on.
  set -m
  # stdin is closed explicitly. It is NOT enough to rely on "async lists get
  # /dev/null": POSIX grants that only when job control is **inactive**, and the
  # `set -m` immediately above turns it on. Measured on bash 3.2 and 5, caller
  # stdin = a held-open pipe:
  #     `cat &` with job control off  -> fd 0 = /dev/null, returns at once
  #     `cat &` after `set -m`        -> fd 0 = the pipe, blocks until EOF
  # Today every adapter calls this as `result=$(run_with_timeout ...)`, and bash
  # forces job control off inside a command-substitution subshell — so the hazard
  # is masked. Measured: the same call outside a substitution blocks for the full
  # lifetime of the caller's stdin. That is one ordinary refactor away
  # (`run_with_timeout ... > file` instead of `$(...)`), and the failure it
  # resurrects is the worst kind: `codex exec` reads stdin when it is not a TTY,
  # prints nothing to stdout, and waits — indistinguishable from a hang, for the
  # full timeout (Issue `#406`, where it cost 50 minutes and a wrong diagnosis).
  # Since Issue `#712` the prompt travels on stdin (a regular temp file via
  # --stdin-file, default /dev/null) — both give the child a guaranteed EOF, so
  # the held-open-pipe hang above cannot come back through this path. What must
  # NOT come back is inheriting the **caller's** stdin.
  "$@" >"$out_file" <"$stdin_source" &
  local cmd_pid=$!
  (
    sleep "$timeout_seconds"
    # Record the fired deadline BEFORE signalling. Written after the kill, the
    # parent could reap the child and cancel this watchdog before the write
    # landed, and a genuine timeout would be reported as a crash — measured at
    # ~3% of runs (8/240) under CPU contention, returning 143 instead of 124.
    printf 'timeout' >"$marker"
    # Negative pid = process group. Fall back to the lone pid if the child never
    # became a group leader, so a host without job control still gets a timeout
    # rather than none at all.
    kill -TERM -- -"$cmd_pid" 2>/dev/null || kill -TERM "$cmd_pid" 2>/dev/null || true
    sleep "$TIMEOUT_KILL_GRACE"
    kill -KILL -- -"$cmd_pid" 2>/dev/null || kill -KILL "$cmd_pid" 2>/dev/null || true
  ) >/dev/null 2>&1 &
  local watchdog_pid=$!
  set +m

  local rc=0
  wait "$cmd_pid" || rc=$?

  # Kill the watchdog *as a group* so its in-flight `sleep` goes with it (guard 2)
  # instead of idling for the rest of the limit — at a 900s default that is a
  # stray `sleep 900` per task.
  kill -- -"$watchdog_pid" 2>/dev/null || kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true

  # Trust the marker only when the command actually failed. The marker means "the
  # deadline elapsed", which can also happen a hair after a command finished on
  # its own; reclassifying a successful run as a timeout would be worse than the
  # race it fixes. Residual window: a command that fails on its own within
  # milliseconds of the deadline is reported as a timeout — it was about to be
  # killed anyway.
  if [[ "$rc" -ne 0 && -s "$marker" ]]; then
    rc="$TIMEOUT_EXIT_CODE"
    record_timeout_reason timeout
    # `wait` returned as soon as the *direct* child died, and killing the watchdog
    # above cancelled its pending group SIGKILL. A group member that ignores
    # SIGTERM would otherwise outlive the deadline indefinitely, so finish the
    # escalation here: wait out a bounded grace so a well-behaved worker can still
    # flush, then SIGKILL whatever is left. Done in the foreground rather than
    # left to an orphaned watchdog, which would signal a possibly-recycled pgid
    # seconds later. Costs nothing when the group is already empty.
    local waited=0
    while [[ "$waited" -lt "$TIMEOUT_KILL_GRACE" ]] && kill -0 -- -"$cmd_pid" 2>/dev/null; do
      sleep 1
      waited=$((waited + 1))
    done
    kill -KILL -- -"$cmd_pid" 2>/dev/null || true
  fi
  rm -f "$marker"

  cat "$out_file"
  rm -f "$out_file"
  return "$rc"
}

# ── Failure Reporting ──

# Describe a non-zero CLI exit status in one phrase.
# Usage: describe_cli_failure <rc> <timeout_seconds> [reason]
#
# `reason` is run_with_timeout's out-of-band verdict (see timeout_reason_file):
# "timeout", "orchestrator-error", "command", or "" when it could not be recorded.
# An adapter may also record a reason itself when the CLI succeeded but the result
# is unusable: "sandbox-refused" (a safety precondition did not hold) or
# "empty-output" (exit 0 with nothing on stdout).
# It is consulted first because the status alone is ambiguous — a CLI is free to
# exit 124 or 125 itself, and only the reason separates that from our own verdict.
# "missing-review-body" is the third adapter-recorded value (exit 0 with output,
# but the output has no valid typed verdict line — the acceptance conditions are
# defined once, in review_body_present's header, and the phrase once, in
# REVIEW_BODY_REFUSAL_PHRASE; Issue `#893` / ADR-066).
describe_cli_failure() {
  local rc="$1" timeout_seconds="$2" reason="${3:-}"

  case "$reason" in
    timeout)
      echo "timed out after ${timeout_seconds}s"
      return
      ;;
    orchestrator-error)
      echo "could not be started by this orchestrator (see the error above)"
      return
      ;;
    sandbox-refused)
      # The CLI ran to completion and exited 0; this adapter is the one that
      # refused the result, because the sandbox it asked for was not in effect.
      # Saying "the CLI exited 1" here would send the reader after a crash that
      # never happened, while the actual thing to fix is the sandbox.
      echo "ran without the sandbox this adapter requires — its result was refused"
      return
      ;;
    empty-output)
      # Exited 0 and was never stopped, but wrote nothing to stdout. The cause is
      # in the CLI's stderr (rate limits, auth), which the artifact carries below.
      echo "exited successfully but produced no output"
      return
      ;;
    missing-review-body)
      # Exited 0 with output, but the captured output has no valid typed verdict
      # line (acceptance conditions: review_body_present's header; the phrase is
      # REVIEW_BODY_REFUSAL_PHRASE, never restated here). The CLI may have emitted
      # the review in an earlier, uncaptured turn (Issue `#893`), or written it in
      # prose without the typed verdict lines the prompt requires (ADR-066).
      echo "finished, but its captured output contains ${REVIEW_BODY_REFUSAL_PHRASE} — refused as a review result"
      return
      ;;
    missing-review-body-prose)
      # Same refusal, but the output was a prose-only review (severity lines without
      # any typed verdict line): the reviewer ignored the typed-verdict contract.
      echo "finished, but its captured output contains ${REVIEW_BODY_REFUSAL_PHRASE} (a prose-only review) — refused as a review result"
      return
      ;;
    review-body-unparsed)
      # The acceptance parser itself failed (e.g. invalid UTF-8 in the output), so
      # whether a typed verdict line was present is unknown. Refused on the safe side.
      echo "finished, but its captured output could not be parsed as a review body — refused as a review result"
      return
      ;;
  esac

  # reason == "command" (the CLI decided its own fate) or "" (unrecordable, so fall
  # back to the status). Only reserved-by-convention codes are interpreted here.
  case "$rc" in
    "$SIGKILL_EXIT_CODE")
      # A fired deadline is reported with reason=timeout above, so reaching here
      # with 137 means something *outside* this wrapper SIGKILLed the CLI, most
      # often the OS under memory pressure. Calling that a timeout would tell the
      # user to allow more time, which cannot help and buries the real cause.
      echo "was killed by SIGKILL — not by the time limit (e.g. the OS under memory pressure)"
      ;;
    "$TIMEOUT_EXIT_CODE"|"$ORCHESTRATOR_ERROR_EXIT_CODE")
      if [[ -z "$reason" ]]; then
        # No reason recorded: the number is all there is, so read it the
        # conventional way rather than pretending the CLI chose it.
        if [[ "$rc" -eq "$TIMEOUT_EXIT_CODE" ]]; then
          echo "timed out after ${timeout_seconds}s"
        else
          echo "could not be started by this orchestrator (see the error above)"
        fi
      else
        echo "exited with status ${rc} (the CLI's own status, not a timeout)"
      fi
      ;;
    *)
      echo "exited with status ${rc}"
      ;;
  esac
}

# Maximum bytes of CLI stderr copied into the result file. Enough for a stack
# trace or an auth error, small enough that a chatty CLI cannot bury the report.
readonly STDERR_EXCERPT_BYTES=4000

# Record a failed task as an explicitly INCOMPLETE result, then exit non-zero.
# Usage: fail_cli_task <exit_code> <stderr_log> <perspective_name> <partial_output>
# Reads: CLI_NAME, OUTPUT_FILE, TIMEOUT, TASK_TYPE. Does not return.
#
# Writing a file here rather than leaving none keeps whatever the CLI produced
# before it was stopped — issue `#152` threw away a full 300s Codex run because the
# failure path discarded already-captured stdout, leaving a report that only said
# the section was missing. This stays fail-loud: the banner marks the result
# incomplete, the header carries `Status: incomplete`, and the non-zero exit keeps
# the orchestrator counting the task as failed.
#
# The stderr excerpt goes into the file too. For a crash the cause is usually
# *only* on stderr ("auth error: token expired"), and echoing it to the
# orchestrator's stream is not enough: in parallel mode that stream is several
# adapters interleaved, and nothing persists it. Salvaging stdout while dropping
# the one channel that says why would miss the point of the salvage.
#
# No runtime fallback is attempted here, by design. See the "Fallback semantics"
# section of scripts/multi-agent.sh for the reasoning.
fail_cli_task() {
  local rc="$1" stderr_log="$2" perspective_name="$3" partial="$4"

  local kind reason stale_note="" refusal shown_kind stale_head
  kind="$(read_timeout_reason)"
  # 後始末（clear）の前に判定する — 消した後では実体の形を再判定できない。
  # 記録を拒んだ WARNING は orchestrator の stderr（複数アダプタが交錯し、誰も保存しない）
  # にしか出ないので、拒否理由そのものを成果物へ写す（Issue `#1816`）
  if reason_record_may_be_stale; then
    refusal="$(_ff_reason_refusal "$(timeout_reason_file)")" || refusal=""
    # 注記が出る回の理由ファイルは、ハードリンク・他人所有など「自分が書いたとは限らない」
    # 実体である。中身を成果物へそのまま写すと他人のファイル内容が漏れ、改行を含めば
    # `> Reason code:` 行を偽装して統合レポートの未完了理由まで書き換えられるので、
    # record_timeout_reason の許可値に一致するときだけ値を見せる
    if [[ -z "$kind" ]]; then
      shown_kind="none"
    elif _ff_reason_is_known "$kind"; then
      shown_kind="\`${kind}\`"
    else
      shown_kind="not shown (the file there may not be ours)"
    fi
    # 同じシェルの記録失敗は確定、実体の再判定だけで分かった回は「上書きを拒む形をしている」
    # 止まり（サブシェル内の記録が実際に試みられたかはここから見えない）なので書き分ける
    if [[ -n "${_FF_REASON_RECORD_FAILED}" ]]; then
      stale_head="The failure reason for this run could not be updated"
    else
      stale_head="The failure reason for this run may not have been updated (the reason file refuses overwrites)"
    fi
    stale_note="
> ⚠️ ${stale_head}${refusal:+: ${refusal%.}}. The classification above may therefore be stale — it can reflect an earlier stage (recorded reason: ${shown_kind}) rather than the actual failure. Read it as unconfirmed."
  fi
  clear_timeout_reason
  # 本文の不受理は、直前の review_body_present が残した種別で理由コードを細分する
  # （散文だけのレビュー / 解析できない本文）。理由コードは成果物へ 1 行載せ、統合レポートの
  # 「未確認 › 未完了の観点」がそれを読んで理由を名指しする
  if [[ "$kind" == "missing-review-body" ]]; then
    case "${REVIEW_BODY_REFUSAL_KIND:-}" in
      prose)    kind="missing-review-body-prose" ;;
      unparsed) kind="review-body-unparsed" ;;
    esac
  fi
  reason="$(describe_cli_failure "$rc" "$TIMEOUT" "$kind")"

  # Normalise the status at the process boundary. The orchestrator only sees this
  # number, so a CLI that exited 124/125 by its own choice must not arrive looking
  # like our timeout or our own breakage.
  local exit_rc="$rc"
  case "$kind" in
    timeout)            exit_rc="$TIMEOUT_EXIT_CODE" ;;
    orchestrator-error) exit_rc="$ORCHESTRATOR_ERROR_EXIT_CODE" ;;
    command)
      if [[ "$rc" -eq "$TIMEOUT_EXIT_CODE" || "$rc" -eq "$ORCHESTRATOR_ERROR_EXIT_CODE" ]]; then
        exit_rc=1
      fi
      ;;
  esac

  echo "ERROR: ${CLI_NAME} ${reason}." >&2
  if [[ "$exit_rc" -eq "$TIMEOUT_EXIT_CODE" ]]; then
    echo "       Give it more room with: --timeout $((TIMEOUT * 2))" >&2
  fi

  local stderr_excerpt=""
  if [[ -s "$stderr_log" ]]; then
    echo "--- CLI stderr ---" >&2
    cat "$stderr_log" >&2
    echo "--- end stderr ---" >&2
    stderr_excerpt="$(tail -c "$STDERR_EXCERPT_BYTES" "$stderr_log")"
    # バイト数で切った抜粋の先頭行は切れ端で、UTF-8 の多バイト文字の途中から始まりうる
    # （実測: codex がエコーした日本語のプロンプト）。不正な UTF-8 が残ると
    # 下流の awk が `multibyte conversion failure` で落ち、型付き判定は「判定器の実行
    # 失敗 → 安全側 Critical」、失敗分類は空へ化ける。切ったときだけ、先頭の切れ端の行を
    # 捨てる（1 行しか無い抜粋は捨てると何も残らないのでそのまま）。
    local stderr_size
    stderr_size="$(wc -c < "$stderr_log" 2>/dev/null | tr -d '[:space:]')" || stderr_size=""
    if [[ "$stderr_size" =~ ^[0-9]+$ && "$stderr_size" -gt "$STDERR_EXCERPT_BYTES" \
          && "$stderr_excerpt" == *$'\n'* ]]; then
      stderr_excerpt="$(printf '%s\n' "$stderr_excerpt" | LC_ALL=C sed '1d')"
    fi
  fi
  # Guard the empty operand: fail_orchestrator_error calls in with "" (there is no
  # stderr file when creating it is what failed). `rm -f ""` is a no-op on BSD, but
  # rather than depend on every rm(1) agreeing, skip it — if some rm did error here,
  # `set -e` would kill the adapter before it writes the artifact, i.e. exactly the
  # empty-handed failure this function exists to prevent.
  if [[ -n "$stderr_log" ]]; then
    rm -f "$stderr_log"
  fi

  local body
  if [[ -n "$partial" ]]; then
    if [[ "$kind" == "review-body-unparsed" ]]; then
      body="The output that was captured (refused as a ${TASK_TYPE:-review} result because the acceptance parser could not read it — status ${REVIEW_BODY_REFUSAL_RC:-?}, e.g. invalid UTF-8; whether it had a typed verdict line is unknown):

${partial}"
    elif [[ "$kind" == "missing-review-body" || "$kind" == "missing-review-body-prose" ]]; then
      # The CLI was never stopped here — it finished, and this is everything it
      # gave us. Calling that "partial output before the CLI was stopped" would
      # send the reader after a crash or timeout that never happened.
      body="The output that was captured (refused as a ${TASK_TYPE:-review} result because it contains ${REVIEW_BODY_REFUSAL_PHRASE}):

${partial}"
    else
      body="Partial output captured before the CLI was stopped:

${partial}"
    fi
  else
    if [[ "$kind" == "empty-output" ]]; then
      body="The CLI exited 0 without writing any output."
    else
      body="No output was captured before the CLI was stopped."
    fi
  fi

  if [[ -n "$stderr_excerpt" ]]; then
    # フェンスは抜粋中の最長のバッククォート列より 1 本長くする。
    # codex は stderr へプロンプトをエコーし、プロンプトは出力テンプレートの ``` を
    # 含む。固定の ``` で囲むと内側の ``` がフェンスを閉じ、型付き判定は「フェンス
    # 未閉」として安全側（Critical あり）へ倒れ、失敗分類は末尾の API エラー行へ
    # 届かない（実測: 400 のモデル非対応が Critical 扱いの INCOMPLETE になった）。
    local stderr_fence
    stderr_fence="$(printf '%s\n' "$stderr_excerpt" | LC_ALL=C awk '
      { s = $0; while (match(s, /`+/)) { if (RLENGTH > max) max = RLENGTH; s = substr(s, RSTART + RLENGTH) } }
      END { n = (max >= 3 ? max + 1 : 3); out = ""; for (i = 0; i < n; i++) out = out "`"; print out }')" \
      || stderr_fence=""
    [[ "$stderr_fence" =~ ^\`{3,}$ ]] || stderr_fence='````````````````'
    body="${body}

### CLI stderr (last $((STDERR_EXCERPT_BYTES / 1000))KB)

${stderr_fence}
${stderr_excerpt}
${stderr_fence}"
  fi

  # The "never reached its conclusion" clause is false for a result we refused
  # after the CLI finished, and a banner that misstates what happened sends the
  # reader to the wrong place. Keep the INCOMPLETE contract, change the reason.
  local banner_detail="the CLI never reached its conclusion, so anything it had not gotten to is simply absent — read the gaps as unknown, not as clean"
  case "$kind" in
    missing-review-body|missing-review-body-prose)
      banner_detail="the CLI did finish, but its captured output contains ${REVIEW_BODY_REFUSAL_PHRASE}, so this perspective went effectively unreviewed — read it as unchecked, not as clean"
      ;;
    review-body-unparsed)
      banner_detail="the CLI did finish, but its captured output could not be parsed, so this perspective went effectively unreviewed — read it as unchecked, not as clean"
      ;;
    sandbox-refused)
      banner_detail="the CLI did finish, but it ran outside the sandbox this adapter requires, so its findings are unverified and it may have modified the working tree — read this as unknown, not as clean"
      ;;
    empty-output)
      # "below" must point at something that exists. When the CLI wrote nothing to
      # stderr either, the excerpt section is absent (the -s guard above), and the
      # most-diagnosis-needed artifact would send its reader hunting for a section
      # that is not there.
      if [[ -n "$stderr_excerpt" ]]; then
        banner_detail="the CLI exited successfully but wrote nothing, so nothing was reviewed at all — the reason is in the stderr excerpt below, not in a crash"
      else
        banner_detail="the CLI exited successfully but wrote nothing to stdout or stderr, so no cause was captured — check the CLI's own logs or its auth/rate-limit state directly"
      fi
      ;;
  esac

  # INCOMPLETE 成果物すら書けなかった回は、失敗の**理由**を持ち帰る先が無い。
  # 元の exit_rc（例 124）ではなく 125 で終えるのは、次に直すべきものが出力先だから
  # — 出力先が書けないうちは、どのタスクも同じ形で失敗し、時間を足しても直らない。
  # CLI 側の理由（timeout / crash）は上の ERROR 行に残してあるので失われない。
  # 本文の不受理だけは理由コードを 1 行載せる（統合レポートの未完了の理由が読む。
  # multi-agent.sh の review_task_incomplete_reason。scripts/lib/multi-agent-report-body.sh）
  local reason_line=""
  case "$kind" in
    missing-review-body|missing-review-body-prose|review-body-unparsed)
      reason_line="
> Reason code: \`${kind}\`" ;;
  esac
  if ! write_output "$OUTPUT_FILE" "$CLI_NAME" "$perspective_name" \
    "> ⚠️ **INCOMPLETE — ${CLI_NAME} ${reason}.** This is not a finished ${TASK_TYPE:-review}: ${banner_detail}.${reason_line}${stale_note}

${body}" \
    "incomplete"; then
    echo "ERROR: the INCOMPLETE ${TASK_TYPE:-review} artifact could not be written either, so nothing about this failure was saved to ${OUTPUT_FILE} (see the error above)." >&2
    echo "       Reporting it as an orchestrator-side failure (exit ${ORCHESTRATOR_ERROR_EXIT_CODE}): fix the output path first — every task writes to the same place." >&2
    exit "$ORCHESTRATOR_ERROR_EXIT_CODE"
  fi

  exit "$exit_rc"
}

# Abort as an orchestrator-side failure, still leaving an INCOMPLETE artifact.
# Usage: fail_orchestrator_error <perspective_name> <what went wrong>
# Reads: CLI_NAME, OUTPUT_FILE, TIMEOUT, TASK_TYPE. Does not return.
#
# Needed for the setup that happens BEFORE run_with_timeout — creating the stderr
# temp file. Under the adapters' `set -e` a failed `mktemp` there killed the
# process with a bare 1, so a broken TMPDIR was filed as "the CLI exited 1" and no
# artifact was written at all: the 125 handling inside run_with_timeout could never
# be reached on the most likely path to it.
fail_orchestrator_error() {
  local perspective_name="$1" what="$2"
  echo "ERROR: ${what}" >&2
  record_timeout_reason orchestrator-error
  fail_cli_task "$ORCHESTRATOR_ERROR_EXIT_CODE" "" "$perspective_name" ""
}

# ── Model Selection ──
#
# ラッパーはモデルを選ばない。どのモデルを使うかは各 CLI 自身の設定
# （~/.codex/config.toml、Claude Code のモデル設定など）へ委譲し、env が
# 設定されているときだけフラグを組み立てる。未設定ならフラグ自体を渡さない。
#
# 既定値としてモデル slug を持たせると、その値の SSOT がユーザーの CLI 設定と
# ラッパーの 2 箇所に分裂してラッパー側が必ず古くなる。しかも無条件にフラグを
# 渡す実装だと、ユーザー設定を黙って上書きするうえ同じ設定ファイル内の関連項目
# （reasoning effort など）は上書きされないため、「古いモデル + 新しい付随設定」
# という誰も意図していない組み合わせで動く。実害の記録は
# 実害の記録は ACE-70-2（本リポジトリの ACE Playbook）を参照。
#
# 第 3 引数の既定値に書いてよいのは「ベンダー中立で世代交代しない語」だけ。
# 現状これを使っているアダプタは無い。唯一の利用者だった cursor-agent の `auto`
# は issue `#240` の cursor-cli 削除で消えた（copilot も値として auto を受け付ける
# が、それは利用者が env に指定する値であってラッパーが持つ既定値ではない）。
# 具体的なモデル slug は既定値としてもフォールバックとしても持たないこと —
# tests/no-hardcoded-model/verify.sh がこれを機械的に検査している。
#
# 代入ではなく追記にしているのは、codex が -m（モデル）と -p（プロファイル）の
# 2 フラグを同時に取りうるため。代入式だと後の呼び出しが前の結果を黙って捨てる。

MODEL_ARGS=()

# Usage: reset_model_args
reset_model_args() {
  MODEL_ARGS=()
}

# Usage: add_model_arg <flag> <ENV_VAR_NAME> [vendor_neutral_default]
# 値は間接展開で読む（bash 3.2 には declare -n が無い）。
#
# 引数の不正は「呼び出し側のバグ」なので沈黙せず非 0 で返す。env 変数名を打ち
# 間違えた呼び出し（例: MULTI_AGENT_MODEL_GEMINI_CL1）は、黙って無視すると
# 利用者が設定した値が永久に届かない「効かないつまみ」になり、しかも実行結果
# からは区別できない。素の呼び出しなら set -e が拾って落ちる。
add_model_arg() {
  if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "add_model_arg: 引数は 2〜3 個です（受領: $#）" >&2
    return 2
  fi
  local flag="$1" var="$2" fallback="${3:-}" value
  if [[ ! "$var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "add_model_arg: 第 2 引数は環境変数名でなければなりません（受領: '$var'）" >&2
    return 2
  fi
  value="${!var:-}"
  [[ -z "$value" ]] && value="$fallback"
  [[ -n "$value" ]] && MODEL_ARGS+=("$flag" "$value")
  return 0
}

# 解決したモデル引数を起動バナーに出す。
#
# 委譲した以上「実際にどのモデルが使われたか」はラッパーには断定できないので、
# ここで報告するのは**渡した引数**だけにし、実使用モデルを名乗らない。それでも
# 出す価値があるのは、env 名の打ち間違いや未 export が「(なし)」として即座に
# 見えるため — 設定したつもりで効いていない事故は、これが無いと成果物からも
# ログからも判別できない。
# Usage: echo_model_args
echo_model_args() {
  if [[ ${#MODEL_ARGS[@]} -gt 0 ]]; then
    echo "   Model args: ${MODEL_ARGS[*]} (env 由来。実使用モデルは CLI 側の解決結果に従う)" >&2
  else
    echo "   Model args: (なし — CLI 自身の設定へ委譲)" >&2
  fi
}

# ── Argument Parsing Helper ──

# Parse common adapter arguments
# Sets: PERSPECTIVE_FILE, OUTPUT_FILE, CHANGED_FILES, BASE_BRANCH, STAGED_DIFF, TIMEOUT,
#       TASK_TYPE, DESCRIPTION, INCLUDE_DIFF, STAGING_DIR, INLINE_OUTPUT, DIFF_FILE
# Usage: parse_adapter_args "$@"
parse_adapter_args() {
  PERSPECTIVE_FILE=""
  OUTPUT_FILE=""
  CHANGED_FILES=""
  BASE_BRANCH="$(detect_base_branch)"
  BASE_BRANCH_EXPLICIT="false"
  STAGED_DIFF="false"
  # Standalone default for a direct adapter invocation. Kept in step with
  # multi-agent.sh's DEFAULT_TIMEOUT_REVIEW — an adapter run by hand should not
  # inherit the 300s that issue `#152` identified as too short. The orchestrator
  # always passes --timeout explicitly, so this value only applies to direct runs.
  # tests/multi-agent-timeout/verify.sh gates it against that constant.
  TIMEOUT="${REVIEW_TIMEOUT:-900}"
  TASK_TYPE="review"
  DESCRIPTION=""
  INCLUDE_DIFF="false"
  # 直叩き実行では空のまま。orchestrator 経由のときだけ実パスが入る（Issue `#392`）。
  STAGING_DIR=""
  # staging 無しの implement を許す明示的オプトイン。無指定で staging も無ければ
  # build_prompt が fail-loud に落ちる（渡し忘れを黙って退避モードにしないため）。
  INLINE_OUTPUT="false"
  # orchestrator が固定した diff のパス。直叩き実行では空のままで、その場合は
  # 従来どおりアダプタ自身が git から取る（prompt_diff_content を参照）。
  DIFF_FILE=""
  # ホスト委譲の受け渡しディレクトリ。空 = 従来どおり CLI を起動する。
  # 非空のとき、そのアダプタは CLI を 1 つも起動せず delegate_task へ委ねる。
  DELEGATE_DIR=""

  while [[ $# -gt 0 ]]; do
    # 値付きフラグを末尾に置いた場合、各 arm でいきなり "$2" を読むと set -u が
    # 発火する。macOS 既定の Bash 3.2 ではこの死が呼び出し側から rc=0 に見えることが
    # あり、「成功・成果物なし」へ反転する。値付きフラグの集合をここで一括して守り、
    # どれか1つだけ直して残りが同じ silent exit を持ち続ける形を作らない。
    case "$1" in
      --changed-files|--base|--timeout|--task-type|--description|--staging-dir|--diff-file|--delegate-dir)
        if [[ $# -lt 2 ]]; then
          echo "ERROR: ${1} requires a value." >&2
          return 2
        fi
        # 次の既知フラグを値として吸収しない。末尾だけを見ると
        # `--description --inline-output` が description の値として通り、利用者が指定した
        # inline-output は黙って消える。未知の `--foo` まで一律拒否はしない（説明文等の
        # 実値であり得るため）。このパーサー自身が知るフラグだけを欠落の証拠にする。
        case "$2" in
          --changed-files|--base|--timeout|--task-type|--description|--include-diff|--staged|--staging-dir|--inline-output|--diff-file|--delegate-dir)
            echo "ERROR: ${1} requires a value; got option '${2}'." >&2
            return 2
            ;;
        esac
        ;;
    esac
    case "$1" in
      --changed-files)
        CHANGED_FILES="$2"
        shift 2
        ;;
      --base)
        # 既定値（detect_base_branch）と同じ鮮度解決を通す。verbatim 代入だと、
        # アダプタを直接起動したときだけ stale なローカル ref のまま diff を取る。
        # orchestrator から渡ってくる値はすでに解決済みだが、この関数は冪等なので
        # 二重解決にはならない（選択行も増えない）。
        BASE_BRANCH="$(resolve_base_branch_ref "$2")"
        BASE_BRANCH_EXPLICIT="true"
        shift 2
        ;;
      --staged)
        STAGED_DIFF="true"
        shift
        ;;
      --timeout)
        TIMEOUT="$2"
        shift 2
        ;;
      --task-type)
        TASK_TYPE="$2"
        shift 2
        ;;
      --description)
        DESCRIPTION="$2"
        shift 2
        ;;
      --include-diff)
        INCLUDE_DIFF="true"
        shift
        ;;
      --staging-dir)
        STAGING_DIR="$2"
        shift 2
        ;;
      --diff-file)
        DIFF_FILE="$2"
        shift 2
        ;;
      --delegate-dir)
        DELEGATE_DIR="$2"
        shift 2
        ;;
      --inline-output)
        INLINE_OUTPUT="true"
        shift
        ;;
      *)
        if [[ -z "$PERSPECTIVE_FILE" ]]; then
          PERSPECTIVE_FILE="$1"
        elif [[ -z "$OUTPUT_FILE" ]]; then
          OUTPUT_FILE="$1"
        fi
        shift
        ;;
    esac
  done

  if [[ "$STAGED_DIFF" == "true" && "$BASE_BRANCH_EXPLICIT" == "true" ]]; then
    echo "ERROR: --staged and --base are mutually exclusive." >&2
    return 2
  fi
  if [[ "$STAGED_DIFF" == "true" && "$TASK_TYPE" != "review" ]]; then
    echo "ERROR: --staged is only valid for review tasks." >&2
    return 2
  fi

  # 委譲に対応していないアダプタが --delegate-dir を**黙って無視**すると、委譲した
  # つもりのレーンで CLI が起動し、枯渇したアカウントで同じ失敗を引く。効かないつまみを
  # 受理しない（対応アダプタは parse_adapter_args より前に opt-in を立てる）。
  if [[ -n "$DELEGATE_DIR" ]]; then
    if [[ "${ADAPTER_SUPPORTS_DELEGATION:-false}" != "true" ]]; then
      echo "ERROR: --delegate-dir is not supported by $(basename "$0")." >&2
      echo "       Host delegation exists only for a lane the host itself can run (claude-code /" >&2
      echo "       codex-cli / grok-cli); routing another lane through it would silently lose" >&2
      echo "       model independence." >&2
      return 2
    fi
    if [[ "$TASK_TYPE" != "review" ]]; then
      echo "ERROR: --delegate-dir is only valid for review tasks (got '${TASK_TYPE}')." >&2
      return 2
    fi
  fi

  if [[ -z "$PERSPECTIVE_FILE" || -z "$OUTPUT_FILE" ]]; then
    echo "Usage: $(basename "$0") <perspective-file> <output-file> [--changed-files <files>] [--base <branch> | --staged] [--diff-file <path>] [--timeout <seconds>] [--task-type <review|explore|implement>] [--description <text>] [--staging-dir <dir>] [--inline-output] [--delegate-dir <dir>]" >&2
    return 1
  fi
}

# Effort is a requested CLI setting, not an observation of runtime reasoning.
validate_effort_env() {
  local cli="$1" value
  case "$cli" in
    claude-code)
      [[ "${MULTI_AGENT_CLAUDE_EFFORT+x}" == x ]] || return 0
      value="${MULTI_AGENT_CLAUDE_EFFORT}"
      case "$value" in low|medium|high|xhigh|max) return 0 ;; esac
      echo "ERROR: MULTI_AGENT_CLAUDE_EFFORT='$value' は不正です (low / medium / high / xhigh / max)" >&2 ;;
    codex-cli)
      [[ "${MULTI_AGENT_CODEX_REASONING_EFFORT+x}" == x ]] || return 0
      value="${MULTI_AGENT_CODEX_REASONING_EFFORT}"
      case "$value" in none|minimal|low|medium|high|xhigh|max|ultra) return 0 ;; esac
      echo "ERROR: MULTI_AGENT_CODEX_REASONING_EFFORT='$value' は不正です (none / minimal / low / medium / high / xhigh / max / ultra)" >&2 ;;
    *) return 0 ;;
  esac
  return 1
}

echo_effort_setting() {
  case "$1" in
    claude-code)
      if [[ "${MULTI_AGENT_CLAUDE_EFFORT+x}" == x ]]; then
        echo "   Effort requested: ${MULTI_AGENT_CLAUDE_EFFORT} (MULTI_AGENT_CLAUDE_EFFORT -> --effort; 実値未確認)" >&2
      else
        echo "   Effort: 継承・実値未確認 (Claude CLI settings)" >&2
      fi ;;
    codex-cli)
      if [[ "${MULTI_AGENT_CODEX_REASONING_EFFORT+x}" == x ]]; then
        echo "   Effort requested: ${MULTI_AGENT_CODEX_REASONING_EFFORT} (MULTI_AGENT_CODEX_REASONING_EFFORT -> -c; 実値未確認)" >&2
        if [[ -n "${MULTI_AGENT_CODEX_PROFILE:-}" ]]; then
          echo "   Reasoning effort: explicit -c override; profile value is overridden" >&2
        fi
      else
        echo "   Effort: 継承・実値未確認 (Codex CLI settings; profile=${MULTI_AGENT_CODEX_PROFILE:-未指定})" >&2
      fi ;;
  esac
}
_ac_part_loaded="adapter-common-cli.sh"
