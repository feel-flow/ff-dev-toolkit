#!/usr/bin/env bash
# multi-agent.sh の構成ファイル: 起動前のレーン確認（利用枠・認証）と、同じレビュー入力の --resume の中での利用不可の記憶。
#
# scripts/multi-agent.sh が開始時に 1 回だけ source する（直接実行しない）。読み込む順・
# 読めないときの停止・--resume の入力 identity への算入は multi-agent.sh の
# MULTI_AGENT_PARTS が正本。ここへ set / trap / source を足さない。
# 末尾の _ma_part_loaded の行は読み込み完了の印（途中で切れたファイルを読み込み部が
# 見分ける）。bash 3.2 互換。分割の判断は ADR-075。
# pipefail-inherited: multi-agent.sh が set -euo pipefail の下で source する

# ── 起動前のレーン確認（Issue `#2044`）──
#
# 潰す事故: 副担当の CLI が利用枠切れ（codex の "Your workspace is out of credits" 等）のまま、
# 同じ日に回すレビューのたびにそのレーンを起動し、約 15 分待ってから INCOMPLETE と分かる
# （導入先で 7 回実測。fast 経路では唯一のレーンが落ちてレーン 0 本になる）。`--resume` は
# 落ちたレーンを「完了したキャッシュが無い」として再び起動し、同じ理由でもう一度落ちていた。
#
# 方式（利用者の決定、2026-11-10）:
#   1. 事前確認は**モデルを起動しない取得だけ**。有料の最小 probe は使わない。何を確かめられるかは
#      CLI ごとに違うので、アダプタが能力を宣言する（adapter-common-cli.sh の
#      handle_adapter_precheck_request。quota = 残量を読める / auth = 認証だけ読める / none）。
#      本体は能力と返ってきた状態だけで分岐し、CLI 名では分岐しない。
#      2026-11-10 の実測: codex = quota（App Server の account/rateLimits/read）、
#      claude = auth（`claude auth status --json` の loggedIn。残量は読めない）、grok / copilot = none。
#   2. 利用不可の記憶は**同じレビュー入力の --resume の中だけ**。置き場は入力 identity ごとの
#      resume キャッシュ（RESUME_CACHE_DIR）なので、別 HEAD・別 diff・別プランでは自然に効かず、
#      確かめ直す（取得は無料なので持ち越す理由が無い）。
#
# 対象のレーン: review の、主担当（REVIEW_MAIN）でもホスト委譲のレーンでもないもの。
#   - 主担当は実装しているホスト自身で、完走しなければ主担当のみの完了も成り立たない
#     （ここで外すと、主担当の失敗が「起動しなかった」に化ける）
#   - 委譲レーンは CLI を起動しない。CLI のアカウントはホストと別でありうるので、CLI の状態で
#     委譲を止めない
#
# 止める状態は 2 つだけ: exhausted（残量の明示状態）と unauthenticated（未ログインの明示状態）。
# available / authenticated / unknown・取得の失敗・timeout・不正な応答・コマンド不在は、どれも
# 「通常どおり起動して、既存の失敗分類へ戻す」。止めすぎる損失（その観点が丸ごと消える）は、
# 止め損ねる損失（従来どおり起動して落ちる）より大きい。
#
# 止めたレーンは、実行時に利用不可で落ちた回（collect_unavailable_cross_tasks）と同じ扱いにそろえる:
# 主担当が全観点を完走していれば「主担当のみで完了」で 0 終了、そうでなければ従来どおり非 0。
# 結果ファイル（Status: incomplete と理由コード）・実行ログ・統合レポートには、実行時の失敗とは
# 別の文言で「起動していない」と書く（「同じ CLI の先行失敗」は事実と違う）。
#
# 無効化: MULTI_AGENT_LANE_PRECHECK=off（false / no / 0 も同じ。事前確認と記憶の両方を止め、従来どおり全レーンを起動する）。
# 記憶だけを捨てて確かめ直す: --retry-exhausted（その回の事前確認は走る）。

LANE_PRECHECK_BLOCKS=""      # "cli:cause:source" の空白区切り。source = precheck | memory
LANE_PRECHECK_SKIP_COUNT=0
readonly LANE_MEMORY_FILE=".lane-unavailable"

lane_precheck_enabled() {
  [[ "$TASK_TYPE" == "review" ]] || return 1
  # off / false / no / 0 を大文字小文字を問わず無効として読む（打ち間違いで有効のまま残さない）
  case "$(printf '%s' "${MULTI_AGENT_LANE_PRECHECK:-on}" | tr '[:upper:]' '[:lower:]')" in
    off|false|no|0) return 1 ;;
  esac
  return 0
}

lane_precheck_applies_to() { # <cli> → rc0 = 事前確認と記憶の対象
  [[ -n "$REVIEW_MAIN" && "$1" == "$REVIEW_MAIN" ]] && return 1
  task_is_delegated "$1" && return 1
  return 0
}

# <cli> が止められていれば "cause:source" を返す（止められていなければ空文字）。
lane_precheck_block() { # <cli>
  local entry
  for entry in $LANE_PRECHECK_BLOCKS; do
    if [[ "${entry%%:*}" == "$1" ]]; then
      printf '%s\n' "${entry#*:}"
      return 0
    fi
  done
  return 0
}

# アダプタの --precheck を呼んで "<state> <cap>" を返す。state は available | authenticated | exhausted |
# unauthenticated | unknown。cap は宣言した能力（quota / auth / none）か、確かめられなかった回の failed。
# 能力と状態の組が契約に無いもの・出力の欠落は "unknown failed"。
# アダプタは自分で取得を期限付きにしている（adapter-common-cli.sh の lane_precheck_timeout）。
run_lane_precheck() { # <cli>
  local cli="$1" adapter out cap state
  adapter="$(get_cli_adapter "$cli")"
  if [[ -z "$adapter" || ! -f "$adapter" ]]; then
    echo "unknown failed"
    return 0
  fi
  out="$(bash "$adapter" --precheck </dev/null 2>/dev/null)" || out=""
  cap="$(printf '%s\n' "$out" | LC_ALL=C awk -F= '$1 == "capability" { print $2; exit }')" || cap=""
  state="$(printf '%s\n' "$out" | LC_ALL=C awk -F= '$1 == "state" { print $2; exit }')" || state=""
  case "${cap}:${state}" in
    quota:available|quota:exhausted|auth:authenticated|auth:unauthenticated) echo "$state $cap" ;;
    none:unknown) echo "unknown none" ;;
    # 能力を宣言したのに確かめられなかった（取得の失敗・期限切れ・不正な応答）、または出力が契約外
    *) echo "unknown failed" ;;
  esac
}

lane_precheck_state_phrase() { # <state> [cap]
  if [[ "$1" == "unknown" && "${2:-}" == "failed" ]]; then
    echo "the check this CLI supports did not give an answer this time (fetch failed, timed out, or the reply was not understood) — started as usual"
    return 0
  fi
  case "$1" in
    available)       echo "usage is available (read without starting a model)" ;;
    exhausted)       echo "usage / credits are exhausted — the lane will not be started" ;;
    authenticated)   echo "logged in (this CLI cannot report its remaining usage, so it is started as usual)" ;;
    unauthenticated) echo "not logged in — the lane will not be started" ;;
    *)               echo "could not be checked without starting a model — started as usual" ;;
  esac
}

# ── 利用不可の記憶（同じレビュー入力の --resume の中だけ）──
# 印は RESUME_CACHE_DIR/<cli>/.lane-unavailable（"cause=<auth|billing|model-unsupported>" と
# "source=<precheck|runtime>" の 2 行）。読めない・壊れている・形が違う・通常ファイルでない印は
# 「記憶なし」として扱い、通常どおり確かめる（利用可能とも枯渇とも読まない）。書けなかった印は
# 警告して続ける（その回の判定は変わらず、次の --resume が確かめ直すだけになる）。
lane_memory_path() { # <cli>
  printf '%s\n' "${RESUME_CACHE_DIR}/${1}/${LANE_MEMORY_FILE}"
}

read_lane_memory() { # <cli> → cause | ""
  [[ -n "${RESUME_CACHE_DIR:-}" ]] || return 0
  local file cause
  file="$(lane_memory_path "$1")"
  [[ -f "$file" && ! -L "$file" && -r "$file" ]] || return 0
  ff_review_output_regular "$file" 2>/dev/null || return 0
  cause="$(LC_ALL=C awk -F= 'NR == 1 && $1 == "cause" && NF == 2 { print $2 }' "$file" 2>/dev/null)" || return 0
  cli_failure_is_deterministic "$cause" || return 0
  printf '%s\n' "$cause"
}

remember_lane_unavailable() { # <cli> <cause> <source: precheck|runtime>
  [[ -n "${RESUME_CACHE_DIR:-}" ]] || return 0
  cli_failure_is_deterministic "$2" || return 0
  local rel
  rel="$(lane_memory_path "$1")"
  rel="${rel#"$OUTPUT_DIR"/}"
  if ! output_artifact mkdir "${RESUME_CACHE_DIR#"$OUTPUT_DIR"/}/${1}" 2>/dev/null \
     || ! printf 'cause=%s\nsource=%s\n' "$2" "$3" | output_artifact write "$rel" 2>/dev/null; then
    echo "  ⚠️ Could not record that ${1} is unavailable for this review input (${OUTPUT_DIR}/${rel})." >&2
    echo "     This run is unaffected; a --resume of it will check ${1} again instead of skipping it." >&2
  fi
  return 0
}

forget_lane_memory() { # <cli>
  [[ -n "${RESUME_CACHE_DIR:-}" ]] || return 0
  local file
  file="$(lane_memory_path "$1")"
  [[ -e "$file" || -L "$file" ]] || return 0
  rm -f "$file" 2>/dev/null || echo "  ⚠️ Could not remove the remembered unavailability of ${1}: ${file}" >&2
  return 0
}

# 止めた観点の結果ファイル。Status: incomplete と理由コードを持ち、実行時の失敗の成果物と同じ
# 語彙（統合レポートの「未確認 › 未完了の観点」が理由コードを読む）で「起動していない」と書く。
write_lane_precheck_result() { # <cli> <perspective> <cause> <source>
  local cli="$1" persp="$2" cause="$3" source="$4" why code
  code="lane-${source}-${cause}"
  case "$source" in
    precheck)
      case "$cause" in
        billing) why="the lane precheck read ${cli}'s own account state without starting a model and found its usage / credits exhausted" ;;
        *)       why="the lane precheck read ${cli}'s own login state without starting a model and found it not logged in" ;;
      esac ;;
    *)
      why="an earlier run of this same review input already saw ${cli} fail for $(cause_phrase "$cause"), and a --resume keeps that lane stopped (pass --retry-exhausted to start it again)" ;;
  esac
  if ! write_output "${OUTPUT_DIR}/${cli}/${persp}.md" "$cli" "$persp" \
    "> ⚠️ **INCOMPLETE — not started.** ${cli} was not launched for this perspective: ${why}. Nothing was reviewed — read this perspective as unchecked, not as clean.
> Reason code: \`${code}\`
> 記録: $(lane_precheck_label_ja "$cli")" incomplete; then
    echo "  ⚠️ Could not write the not-started result for ${cli}/${persp}; the integrated report still names it." >&2
  fi
  return 0
}

# execute_tasks から、どのタスクも起動する前に 1 回呼ぶ。止めたレーンの観点を EXECUTION_PLAN から
# 外し、SKIPPED_TASKS へ載せ、LANE_PRECHECK_SKIP_COUNT に数を残す（呼び出し側が失敗数へ足す）。
apply_lane_precheck() {
  LANE_PRECHECK_BLOCKS=""
  LANE_PRECHECK_SKIP_COUNT=0
  lane_precheck_enabled || return 0
  local entry cli persp clis="" cause source state cap
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    cli="${entry%%:*}"
    list_contains "$clis" "$cli" || clis="${clis:+$clis }$cli"
  done <<< "$EXECUTION_PLAN"
  for cli in $clis; do
    lane_precheck_applies_to "$cli" || continue
    cause=""
    source=""
    if [[ "${RETRY_EXHAUSTED:-false}" == "true" ]]; then
      forget_lane_memory "$cli"
    elif [[ "$RESUME" == "true" ]]; then
      cause="$(read_lane_memory "$cli")"
      if [[ -n "$cause" ]]; then
        source="memory"
        echo "  🔎 Lane precheck: ${cli} — remembered as unavailable for this review input ($(cause_phrase "$cause")); not started on --resume (--retry-exhausted starts it again)" >&2
      fi
    fi
    if [[ -z "$cause" ]]; then
      read -r state cap <<<"$(run_lane_precheck "$cli")"
      echo "  🔎 Lane precheck: ${cli} — $(lane_precheck_state_phrase "$state" "$cap")" >&2
      case "$state" in
        exhausted)       cause="billing" ;;
        unauthenticated) cause="auth" ;;
      esac
      if [[ -n "$cause" ]]; then
        source="precheck"
        remember_lane_unavailable "$cli" "$cause" precheck
      else
        # 起動するレーンは、同じ入力の前の記憶を捨てる。残すと、この回に起動して別の理由で
        # 落ちたレーンを、次の --resume が古い「利用枠切れ」で止める
        forget_lane_memory "$cli"
      fi
    fi
    [[ -n "$cause" ]] || continue
    LANE_PRECHECK_BLOCKS="${LANE_PRECHECK_BLOCKS:+$LANE_PRECHECK_BLOCKS }${cli}:${cause}:${source}"
  done
  [[ -n "$LANE_PRECHECK_BLOCKS" ]] || return 0

  local kept="" seen="" block
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    if list_contains "$seen" "$entry"; then continue; fi
    seen="${seen:+$seen }$entry"
    cli="${entry%%:*}"
    persp="${entry#*:}"
    block="$(lane_precheck_block "$cli")"
    if [[ -z "$block" ]]; then
      kept="${kept:+$kept
}${entry}"
      continue
    fi
    SKIPPED_TASKS="${SKIPPED_TASKS:+$SKIPPED_TASKS }${cli}/${persp}:${block%%:*}"
    LANE_PRECHECK_SKIP_COUNT=$((LANE_PRECHECK_SKIP_COUNT + 1))
    write_lane_precheck_result "$cli" "$persp" "${block%%:*}" "${block#*:}"
    echo "  ⏭ Not started: ${cli}/${persp} — $(lane_precheck_block_phrase "$cli")" >&2
  done <<< "$EXECUTION_PLAN"
  EXECUTION_PLAN="$kept"
  return 0
}

lane_precheck_block_phrase() { # <cli> → 実行ログ・案内の 1 句（英語）
  local block cause source
  block="$(lane_precheck_block "$1")"
  [[ -n "$block" ]] || return 0
  cause="${block%%:*}"
  source="${block#*:}"
  if [[ "$source" == "memory" ]]; then
    echo "an earlier run of this same review input saw $(cause_phrase "$cause") on ${1} (--retry-exhausted starts it again)"
  elif [[ "$cause" == "billing" ]]; then
    echo "the lane precheck found ${1}'s usage / credits exhausted before launch"
  else
    echo "the lane precheck found ${1} not logged in before launch"
  fi
}

# 未確認の理由（日本語）。統合レポートと結果ファイルの理由コードで同じ語を使う。
lane_precheck_label_ja() { # <cli>
  local block cause source label
  block="$(lane_precheck_block "$1")"
  [[ -n "$block" ]] || return 0
  cause="${block%%:*}"
  source="${block#*:}"
  case "$cause" in
    billing) label="未確認（利用枠）" ;;
    auth)    label="未確認（認証）" ;;
    *)       label="未確認（$(unavailable_cause_label_ja "$cause")）" ;;
  esac
  if [[ "$source" == "memory" ]]; then
    echo "${label} — 同じレビュー入力の前回の実行で$(unavailable_cause_label_ja "$cause")と確定したため、--resume では起動していない（--retry-exhausted で再試行）"
  elif [[ "$cause" == "billing" ]]; then
    echo "${label} — 起動前の確認でクレジット・利用枠の上限と判明したため起動していない"
  else
    echo "${label} — 起動前の確認で未ログインと判明したため起動していない"
  fi
}

# 実行時の失敗が「この CLI はこの入力では使えない」と確定した観点か。条件は
# collect_unavailable_cross_tasks の失敗側と同じで、主担当・pair の条件だけを外す
# （fast 経路のように主担当がプランに居ない回でも記憶できるように）。
#   - 時間切れ（124）・成功（0）は除く / 結果ファイルがある / アダプタの拒否（理由コード行）が無い /
#     部分出力が無い（CLI が何も出力せずに終了した）/ stderr 抜粋の**末尾 5 行**（空行を除く）の分類が auth・billing・
#     model-unsupported
task_failure_confirms_unavailable() { # <cli/perspective> <rc> → cause（rc0）| rc1
  local task="$1" rc="$2" result cause
  [[ "$rc" != "124" && "$rc" != "0" ]] || return 1
  result="${OUTPUT_DIR}/${task}.md"
  [[ -f "$result" ]] || return 1
  grep -q '^> Reason code: ' "$result" 2>/dev/null && return 1
  grep -qxF 'No output was captured before the CLI was stopped.' "$result" 2>/dev/null || return 1
  cause="$(classify_cli_failure_cause "$result" tail)"
  cli_failure_is_deterministic "$cause" || return 1
  printf '%s\n' "$cause"
}

# 実行後に、実行時の失敗から確定した利用不可を記憶する（同じ入力の --resume が読む）。
remember_runtime_unavailable() {
  lane_precheck_enabled || return 0
  local entry task rc cli cause done_clis=""
  for entry in $FAILED_TASKS; do
    task="${entry%:*}"; rc="${entry##*:}"; cli="${task%%/*}"
    lane_precheck_applies_to "$cli" || continue
    list_contains "$done_clis" "$cli" && continue
    cause="$(task_failure_confirms_unavailable "$task" "$rc")" || continue
    done_clis="${done_clis:+$done_clis }$cli"
    remember_lane_unavailable "$cli" "$cause" runtime
  done
  return 0
}

# どのレーンも起動しなかった回（fast 経路で唯一のレーンが止められた等）の案内。スクリプト自身は
# 直読をしない・記録しないので、完了を名乗らない。
print_lane_precheck_direct_read_advice() {
  [[ "$LANE_PRECHECK_SKIP_COUNT" -gt 0 ]] || return 0
  [[ -z "$EXECUTION_PLAN" && -z "${REUSED_TASKS:-}" ]] || return 0
  echo "" >&2
  echo "ℹ️  No CLI lane was started in this run: every planned lane was stopped before launch." >&2
  echo "   The main reviewer (the host) reads the diff directly and records the result itself." >&2
  echo "   This script did not perform or record that read, so this run is not a completed review." >&2
}

# dry-run のプランで、その CLI の項目の直下に起動前の確認の結果を出す（warn_unappliable_sandbox と
# 同じ位置）。表示だけで、プランからは外さない（外すのは実行時の apply_lane_precheck）。
show_lane_precheck() { # <cli>
  [[ "$DRY_RUN" == "true" ]] || return 0
  lane_precheck_enabled || return 0
  lane_precheck_applies_to "$1" || return 0
  local state cap
  read -r state cap <<<"$(run_lane_precheck "$1")"
  case "$state" in
    available)       echo "     🔎 起動前の確認（モデルは起動しない）: 利用枠あり" >&2 ;;
    exhausted)       echo "     🔎 起動前の確認（モデルは起動しない）: 利用枠切れ — 実行時はこのレーンを起動せず「未確認（利用枠）」と記録する" >&2 ;;
    authenticated)   echo "     🔎 起動前の確認（モデルは起動しない）: ログイン済み（この CLI は残量を報告できないので、通常どおり起動する）" >&2 ;;
    unauthenticated) echo "     🔎 起動前の確認（モデルは起動しない）: 未ログイン — 実行時はこのレーンを起動せず「未確認（認証）」と記録する" >&2 ;;
    *)               echo "     🔎 起動前の確認（モデルは起動しない）: 確かめられない（通常どおり起動する）" >&2 ;;
  esac
}

# 読み込み完了の印（multi-agent.sh の読み込み部が照合する。最後の行に置く）
_ma_part_loaded="multi-agent-precheck.sh"
