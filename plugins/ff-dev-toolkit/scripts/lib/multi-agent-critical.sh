#!/usr/bin/env bash
# multi-agent.sh の構成ファイル: 未解消 Critical のガードとレビュー系列の識別。
#
# scripts/multi-agent.sh が開始時に 1 回だけ source する（直接実行しない）。読み込む順・
# 読めないときの停止・--resume の入力 identity への算入は multi-agent.sh の
# MULTI_AGENT_PARTS が正本。本文は分割前の multi-agent.sh の連続した行そのままで、
# トップレベルの初期化は構成ファイル同士で分割前と同じ順に走る（入口に残したタスク種別の既定より
# 後に走る点だけが違う）。ここへ set / trap / source を足さない。
# 末尾の _ma_part_loaded の行は読み込み完了の印（途中で切れたファイルを読み込み部が
# 見分ける）。bash 3.2 互換。分割の判断は ADR-075。
# pipefail-inherited: multi-agent.sh が set -euo pipefail の下で source する

# ── Unresolved Critical guard (Issue `#843`) ──
# A narrowed review rebuilds integrated-report.md from only this run's plan. Read
# the orchestrator-owned state before cleanup and reject a plan that omits a
# still-unresolved perspective. The machine line is always the report's last line;
# legacy reports fall back to the final marker summary lines only.
# rc: 0 = a Critical marker is present, 1 = none is, 2 = the report file could
# not be read. Callers turn rc 2 into "the report file could not be read", so
# the grep rc is normalized instead of returned raw: grep's own error rc (2) and
# a grep missing from PATH (127) would otherwise reach the caller as that same
# claim and misattribute a broken toolchain to an unreadable report.
previous_report_has_critical_marker() { # <report-file>
  local summary
  summary="$(tail -n 12 "$1")" || return 2
  if printf '%s\n' "$summary" \
    | grep -Fx -e '<!-- CRITICAL_BLOCK -->' \
      -e '<!-- CRITICAL_NONBLOCK -->' >/dev/null; then
    return 0
  else
    return 1
  fi
}

# 失敗の理由。呼び出し側は rc=1 だけでは 3 通りを区別できず、案内を「HEAD が解決できる
# worktree で実行」という一般化した言い方にせざるを得なかった。理由を別チャネルで持たせて、
# **このリポジトリのどこが解決できていないか**まで案内できるようにする。
# 値は 2 つに閉じる（repo-root / git-error）。**3 つ目（HEAD だけが壊れている）は作れない** —
# `.git/HEAD` を壊すと `git symbolic-ref --quiet HEAD` は rc=128 を返し、worktree の外で
# 走った場合と**区別がつかない**（`git rev-parse --is-inside-work-tree` も同じく 128。実測）。
# detached の形（rc=1）まで到達した HEAD は 40 桁 hex なので、実在しないオブジェクトでも
# `rev-parse` は成功する（実測）。したがって git-error の案内は 2 つの原因を両方名乗り、
# 両方の直し方を出す。
#
# **なぜ変数ではなくファイルか**: この関数は常に `$(current_review_series_id)` の形で
# 呼ばれる（標準出力が戻り値なので、そうとしか呼べない）。コマンド置換はサブシェルなので、
# そこで代入した変数は呼び出し側へ届かない — アダプタ側の run_with_timeout が失敗理由を
# ファイルで運んでいるのと同じ理由で、ここも同じ形にする。
# 実行ごとのトークン。理由ファイルは PID で名前を作るので、クラッシュした前回の残骸と
# PID が再利用された回、あるいは書き込めない既存ファイルを指した回に、**古い 1 行を今回の
# 理由として読む**余地がある。内容へトークンを前置し、読む側は一致しない行を捨てる
# （捨てた回は一般案内へ倒れる — 誤った原因を名乗るより無害）。
REVIEW_SERIES_REASON_TOKEN="$$-$(date -u +%s 2>/dev/null || echo 0)"

review_series_reason_file() {
  # テストが隔離した場所を指せるようにする（本番の呼び出しは設定しない）。
  if [[ -n "${FF_MULTI_AGENT_REVIEW_SERIES_REASON_FILE:-}" ]]; then
    printf '%s\n' "$FF_MULTI_AGENT_REVIEW_SERIES_REASON_FILE"
    return 0
  fi
  printf '%s\n' "${TMPDIR:-/tmp}/ff-review-series-reason.$$"
}

review_series_failure_reason() { # stdout: 今回の実行が書いた失敗理由（無ければ空）
  local f line
  f="$(review_series_reason_file)"
  # 書く側がリンクを掴まない以上、リンクが在る回の中身は自分が書いたものではない
  # （トークン照合でも落ちるが、他人のファイルを読むこと自体をここで止める）。
  if [[ -L "$f" ]]; then
    return 0
  fi
  [[ -r "$f" ]] || return 0
  line="$(head -n 1 "$f" 2>/dev/null || true)"
  # トークンが一致しない = 今回の実行が書いたものではない（残骸・書き込み失敗）。
  [[ "$line" == "${REVIEW_SERIES_REASON_TOKEN}:"* ]] || return 0
  printf '%s\n' "${line#"${REVIEW_SERIES_REASON_TOKEN}":}"
}

record_review_series_failure() { # <理由>
  local reason="$1" f
  # 許可値の検証を入口へ集約する（record_timeout_reason と同じ理由）。任意文字列を
  # 受けると、typo した理由は消費側の case をすべて素通りして既定アームへ黙って落ち、
  # 「原因を名乗る」という本機能が痕跡なしに無効化される。
  case "$reason" in
    repo-root|git-error) : ;;
    *)
      echo "WARNING: record_review_series_failure called with unknown reason '${reason}' (orchestrator bug); not recording it. The guidance falls back to the generic wording." >&2
      return 0
      ;;
  esac
  f="$(review_series_reason_file)"
  # 書けなくても呼び出し側の失敗処理は続ける。ただし黙ると原因別案内が一般文言へ
  # 痕跡なしに退行するので、失敗時は stderr へ 1 行だけ警告する（先行実装と同じ）。
  # 既存の実体を掴まない書き込みも、アダプタ側と**同じ関数**（adapter-common.sh の
  # write_reason_file）で行う。2 経路は同じ形の一時ファイルなので、片方だけ直すと
  # 「同じ方法で解いている」という対応が崩れる。
  if ! write_reason_file "$f" "${REVIEW_SERIES_REASON_TOKEN}:${reason}"$'\n'; then
    echo "WARNING: could not record the review-series failure reason '${reason}' at ${f}; the guidance below falls back to the generic wording." >&2
  fi
}

current_review_series_id() {
  local branch scope repo symbolic_ref_rc
  # 前回の失敗が残っていると、次の成功を失敗として読む呼び出し側が出る。
  clear_reason_file "$(review_series_reason_file)"
  # プロジェクトルートが消えた・読めない。残骸ではなくリポジトリ側の問題。
  repo="$(cd "$REPO_ROOT" && pwd -P)" || { record_review_series_failure repo-root; return 1; }
  if branch="$(git symbolic-ref --quiet HEAD)"; then
    :
  else
    symbolic_ref_rc=$?
    # rc=1 は「detached HEAD」（正常な状態）。それ以外は git 側のエラーで、
    # worktree の外で走っている場合が代表。
    [[ "$symbolic_ref_rc" -eq 1 ]] || { record_review_series_failure git-error; return 1; }
    # ここへ来る HEAD は 40 桁 hex なので、実在しないオブジェクトでも rev-parse は
    # 成功する（実測）。失敗は git 側の異常なので、上と同じ分類にする。
    branch="detached:$(git rev-parse HEAD 2>/dev/null)" \
      || { record_review_series_failure git-error; return 1; }
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
  review_series_id_for "$repo" "$branch" "$BASE_BRANCH_IDENTITY" "$scope"
}

review_series_id_for() { # <physical-root> <branch> <base-identity> <scope>
  printf 'repo=%s\nbranch=%s\nbase=%s\nscope=%s\n' "$1" "$2" "$3" "$4" \
    | cksum | awk '{ print $1 "-" $2 }'
}

# rc: 0 = the unresolved-Critical state was read (it may legitimately be empty),
# 1 = the report is readable but its machine state is not, 2 = the report file
# could not be read at all. The caller needs those two failures apart: a
# readable leftover can be archived with --fresh, an unreadable one must not be
# (archiving would discard a Critical state nobody has read). Every non-read
# failure below is normalized to 1 so that rc 2 stays exclusive to a read
# failure — awk's own `exit 2` for a malformed state line would otherwise be
# reported to the caller as an unreadable file.
extract_unresolved_critical_perspectives() { # <report-file>
  local last_line report_tail
  report_tail="$(tail -n 12 "$1")" || return 2
  last_line="$(printf '%s\n' "$report_tail" | tail -n 1)" || return 2
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
      ' || return 1
      return 0
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
  # Git Workflow's full Codex review (Issue `#1025`). --perspective,
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
  local previous_series="" current_series="" base_q extract_rc=0
  [[ -f "$report_file" ]] || return 0
  # An abort that names no recovery route sends the caller back to --help, so
  # every abort in this function names one. The route is NOT the same
  # everywhere — a blanket "add --fresh" would tell the caller to archive state
  # nobody has read. Three kinds, decided by what is actually broken:
  #   1. the leftover report is readable → archive it and retry (--fresh);
  #      when its machine state cannot be trusted (unparseable, corrupt entry,
  #      marker/state contradiction) the guidance says to read the report's
  #      Critical section by hand first;
  #   2. the report file cannot be read at all → fix readability first, because
  #      archiving discards a Critical state nobody has read; --fresh is ruled
  #      out in the message rather than left unmentioned;
  #   3. the current review series cannot be computed → the leftover is fine
  #      and the repository state is what needs fixing, so --fresh is ruled out.
  # Kind 1 and kind 2 both surface here, so the two are told apart by rc rather
  # than merged: an unreadable report (chmod 000, I/O error) is the failure that
  # actually happens in the field, and it used to be answered with "add --fresh".
  parsed="$(extract_unresolved_critical_perspectives "$report_file")" || extract_rc=$?
  case "$extract_rc" in
    0) ;;
    2)
      # Kind 2: the file could not be read, so nobody has seen what is Critical in it.
      echo "ERROR: cannot inspect unresolved Critical perspectives in the previous report." >&2
      echo "       The report file could not be read; check its permissions and the filesystem, then retry." >&2
      echo "       Read its Critical section before archiving the leftover — --fresh would discard a Critical state nobody has read." >&2
      echo "       Previous results were left untouched: ${report_file}" >&2
      return 1
      ;;
    *)
      # Kind 1: the machine state cannot be parsed, but the report itself is
      # still there to read — so the recovery route reads it before archiving.
      echo "ERROR: cannot inspect unresolved Critical perspectives in the previous report." >&2
      echo "       The machine state in the report could not be parsed, so it cannot name the unresolved perspectives." >&2
      echo "       Read the Critical section of the report by hand first, then archive leftover results and retry: add --fresh" >&2
      echo "       Previous results were left untouched: ${report_file}" >&2
      return 1
      ;;
  esac
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
        # Kind 2: previous_report_has_critical_marker only fails this way when
        # the report file itself could not be read.
        # The same failure is reported from two call sites, reached by different
        # leftovers. Naming the route keeps the two apart in a log — and keeps a
        # test from covering one while believing it covers both.
        echo "ERROR: cannot inspect Critical markers in the previous report (no machine-readable Critical state)." >&2
        echo "       The report file could not be read; check its permissions and the filesystem, then retry." >&2
        echo "       Read its Critical section before archiving the leftover — --fresh would discard a Critical state nobody has read." >&2
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
        # Kind 1 with an untrusted state line: the report body is still readable,
        # so the caller can see what is unresolved — but not from this line.
        echo "ERROR: invalid review-series entry in previous Critical state: '${tagged}'" >&2
        echo "       The machine state on the last line of the report is corrupt, so it cannot name the unresolved perspectives." >&2
        echo "       Read the Critical section of the report by hand first, then archive leftover results and retry: add --fresh" >&2
        echo "       Previous results were left untouched: ${report_file}" >&2
        return 1
      fi
      previous_series="$perspective"
      continue
    fi
    if [[ "$tag" != "block" && "$tag" != "nonblock" ]] || ! is_safe_token "$perspective"; then
      # Kind 1 with an untrusted state line (see the invalid-series branch above).
      echo "ERROR: invalid perspective entry in previous Critical state: '${tagged}'" >&2
      echo "       The machine state on the last line of the report is corrupt, so it cannot name the unresolved perspectives." >&2
      echo "       Read the Critical section of the report by hand first, then archive leftover results and retry: add --fresh" >&2
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
      # Kind 1: the marker and the state contradict each other, but the report
      # is readable, so the caller can settle it by reading the Critical section.
      echo "ERROR: the previous report has a Critical marker but its machine state is empty." >&2
      echo "       Inspect the Critical section of the leftover report, then add --fresh, or move/delete it if it is obsolete and run a full review." >&2
      echo "       Previous results were left untouched: ${report_file}" >&2
      return 1
    else
      marker_rc=$?
    fi
    case "$marker_rc" in
      1) return 0 ;;
      *)
        # Kind 2 (see the same message above): the report file could not be read.
        # This is the other call site; the parenthetical names which one.
        echo "ERROR: cannot inspect Critical markers in the previous report (Critical state lists no unresolved perspectives)." >&2
        echo "       The report file could not be read; check its permissions and the filesystem, then retry." >&2
        echo "       Read its Critical section before archiving the leftover — --fresh would discard a Critical state nobody has read." >&2
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
      # Kind 3: nothing is wrong with the leftover — the repository state this
      # run is standing in cannot be resolved into a series identity.
      # The measured causes are: the run is outside a git worktree, HEAD cannot
      # be resolved (a corrupt .git/HEAD), or the project root is gone or
      # unreadable. A repository with no commits is NOT one of them — HEAD is an
      # unborn branch there and symbolic-ref still resolves it.
      echo "ERROR: cannot identify the current review series." >&2
      # 理由ごとに直す場所が違う。一般化した案内だと「自分の状況に当てはまるのか」が
      # 読み手に判断できない。
      case "$(review_series_failure_reason)" in
        repo-root)
          echo "       The project root is gone or unreadable: ${REPO_ROOT}. Restore it (or run from a checkout that still has it), then retry." >&2
          ;;
        git-error)
          # この 2 つは git の側から区別できない（どちらも rc=128。実測）ので、両方名乗って
          # 両方の直し方を出す。片方だけ書くと、もう片方を踏んだ利用者が「自分の話ではない」
          # と読んで手が止まる。
          echo "       git cannot read HEAD here. Two causes look identical from git: this run is not inside a git worktree, or the worktree's .git/HEAD is corrupt." >&2
          echo "       Run it from inside the repository worktree; if you are already there, repair .git/HEAD (for example, check out a branch or a known commit), then retry." >&2
          ;;
        *)
          echo "       Run from inside the repository worktree, with the project root still present and HEAD resolvable, then retry." >&2
          ;;
      esac
      echo "       --fresh does not help here: the failure is in the current repository state, not in the leftover report." >&2
      echo "       Previous results were left untouched: ${report_file}" >&2
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
      if [[ "$DELEGATE_TO_HOST" == true ]]; then
        print_archive_recovery critical
      else
        echo "       Or archive leftover results and retry: add --fresh" >&2
      fi
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
# （Issue `#1143`。分けたのは案内の文面であって、この述語の意味ではない）。
# 片方だけを見ると、スキップされた観点は成果物も無いため判定ループの
# `[[ -f "$crit_file" ]] || continue` で捨てられ、前回の CRITICAL_BLOCK が
# 静かに消える — pre-push ゲートが素通りする fail-open。
task_left_perspective_unproven() { # <cli> <perspective>
  local entry prefix="${1}/${2}:"
  for entry in $FAILED_TASKS $SKIPPED_TASKS; do
    [[ "$entry" == "$prefix"* ]] && return 0
  done
  # 委譲待ちも「この実行がその観点の判定を出していない」側。成果物が
  # 無い点はスキップと同じなので、ここを抜かすと前回の CRITICAL_BLOCK が判定ループの
  # `[[ -f "$crit_file" ]] || continue` で静かに消え、pre-push ゲートが素通りする。
  # DELEGATED_TASKS は接尾辞を持たない（"cli/perspective" のみ）ので完全一致で見る。
  delegated_task_pending "${1}/${2}" && return 0
  return 1
}

# 読み込み完了の印（multi-agent.sh の読み込み部が照合する。最後の行に置く）
_ma_part_loaded="multi-agent-critical.sh"
