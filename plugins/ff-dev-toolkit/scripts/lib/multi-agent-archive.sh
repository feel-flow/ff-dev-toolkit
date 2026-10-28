#!/usr/bin/env bash
# 明示的な旧結果の退避。reviewer/plan に依存せず、既存 series と lock を再利用する。
# 開始時に一度だけ source。保存データを source/eval しない。bash 3.2 互換。
# pipefail-inherited: multi-agent.sh が set -euo pipefail の下で source する

archive_error() {
  echo "ERROR: cannot archive previous review output: $1" >&2
  echo "       Previous results remain under ${OUTPUT_DIR}; finish outstanding delegation with its original invocation, or repair the reported state first." >&2
  return 1
}

# Match review-series identity for detached HEAD; other symbolic-ref failures are errors.
# Critical eligibility still requires a named current branch in archive_validate_report.
archive_current_identity() {
  local identity symbolic_ref_rc
  if identity="$(git symbolic-ref --quiet HEAD)"; then
    printf '%s\n' "$identity"
  else
    symbolic_ref_rc=$?
    [[ "$symbolic_ref_rc" == 1 ]] || return 1
    identity="$(git rev-parse HEAD 2>/dev/null)" || return 1
    printf 'detached:%s\n' "$identity"
  fi
}

# Lane control state stays live across archives: completed IDs prevent a late
# duplicate Stop from consuming a different, newly acquired unadopted lane.
archive_validate_lane_control() {
  local dir="${OUTPUT_DIR}/.review-in-flight.d" item base body GLOBIGNORE=''
  [[ -e "$dir" || -L "$dir" ]] || return 0
  ff_review_output_private "$dir" || return 1
  [[ -r "$dir" && -x "$dir" ]] || return 1
  for item in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
    [[ -e "$item" || -L "$item" ]] || continue
    base="${item##*/}"
    [[ "$base" =~ ^\.done\.[A-Za-z0-9_-]+$ ]] || {
      archive_error "review lanes remain active or need explicit inspection: ${item}"
      echo "       Verify the writer/reviewer has ended, inspect this exact entry, then explicitly recover or remove it: ${item}" >&2
      return 1
    }
    ff_review_output_regular "$item" && [[ -r "$item" ]] || return 1
    body="$(cat "$item")" || return 1
    [[ "$body" =~ ^started_epoch=[0-9]+$ ]] && cmp -s "$item" <(printf '%s\n' "$body") || {
      archive_error 'invalid completed review lane record'; return 1
    }
  done
}

# GLOBIGNORE と dotglob の呼出元設定に左右されず、dotfile/壊れた link も列挙する。
# 3 glob の重複だけを exact path 比較で除く。空集合と読取不能を区別する。
archive_collect_live() {
  local item base seen prior GLOBIGNORE=''
  ARCHIVE_ITEMS=()
  [[ -d "$OUTPUT_DIR" && -r "$OUTPUT_DIR" && -x "$OUTPUT_DIR" ]] || { archive_error "unreadable output directory: ${OUTPUT_DIR}"; return 1; }
  archive_validate_lane_control || return 1
  # Receipts keep absolute paths to historical reports. Validate that retained
  # namespace before moving anything, then leave its paths and bytes live.
  if [[ -e "$OUTPUT_DIR/.evidence" || -L "$OUTPUT_DIR/.evidence" ]]; then
    archive_check_tree "$OUTPUT_DIR/.evidence" || return 1
  fi
  for item in "$OUTPUT_DIR"/* "$OUTPUT_DIR"/.[!.]* "$OUTPUT_DIR"/..?*; do
    [[ -e "$item" || -L "$item" ]] || continue
    base="${item##*/}"
    case "$base" in .multi-agent-run.lock|.multi-agent-output-owner|.review-in-flight.d|.evidence|.prev-*) continue ;; esac
    seen=false
    for prior in ${ARCHIVE_ITEMS[@]+"${ARCHIVE_ITEMS[@]}"}; do [[ "$prior" != "$item" ]] || seen=true; done
    [[ "$seen" != true ]] || continue
    ARCHIVE_ITEMS+=("$item")
  done
}

# A matching root marker grants a namespace, never permission to move arbitrary
# user entries. Validate the whole inventory before the first archive mkdir/mv.
archive_known_entry() { # <path>
  local item="$1" rel first tail cli base
  rel="${item#"$OUTPUT_DIR"/}"; first="${rel%%/*}"; base="${rel##*/}"
  case "$rel" in
    .evidence) [[ -d "$item" ]]; return $? ;;
    .evidence/*)
      tail="${rel#.evidence/}"; first="${tail%%/*}"
      [[ "$first" =~ ^[0-9a-f]{32}$ ]] || return 1
      if [[ "$tail" == "$first" ]]; then [[ -d "$item" ]]; return $?; fi
      [[ "$tail" == "$first/report.md" && -f "$item" ]]; return $? ;;
    integrated-report.md|.fixed-diff|review-evidence.json|.evidence-start.*.json|.evidence-results.*|.report-building.*|.ff-output.*) return 0 ;;
    .delegation-state|.delegation-state/metadata|.delegation-state/manifest|.delegation-state/invocation|.delegation-state/unadopted) return 0 ;;
    .review-in-flight)
      archive_error 'in-flight marker remains; verify the run has ended and remove its stale marker explicitly'; return 1 ;;
    .resume-cache|.resume-cache/last-inputs) return 0 ;;
    .resume-cache/*)
      tail="${rel#.resume-cache/}"; first="${tail%%/*}"
      [[ "$first" =~ ^[0-9a-f]+$ ]] || return 1
      [[ "$tail" == */* ]] || return 0
      tail="${tail#*/}"
      case "$tail" in inputs|.pending) return 0 ;; esac
      cli="${tail%%/*}"; list_contains "$ALL_CLIS" "$cli" || return 1
      [[ "$tail" == */* ]] || return 0
      tail="${tail#*/}"
      case "$tail" in *.md.hash) is_safe_token "${tail%.md.hash}" ;; *.md) is_safe_token "${tail%.md}" ;; *) return 1 ;; esac
      return $? ;;
    .task-rc.*)
      [[ -d "$item" ]] && return 0
      case "$base" in *.rc|*.skip) return 0 ;; *) return 1 ;; esac ;;
  esac
  cli="${rel%%/*}"; list_contains "$ALL_CLIS" "$cli" || return 1
  [[ "$rel" == */* ]] || return 0
  tail="${rel#*/}"
  case "$tail" in
    files|files/*|previous|.delegated|.delegated/generations|.delegated/generations/g-*)
      if [[ -d "$item" ]]; then return 0; fi ;;
  esac
  case "$tail" in
    files/*) return 0 ;;
    .delegated/*.prompt.md|.delegated/*.response*.md) return 0 ;;
    *.findings.tsv) is_safe_token "${base%.findings.tsv}"; return $? ;;
    *.md) is_orchestrator_result "$item"; return $? ;;
  esac
  return 1
}

archive_validate_inventory() {
  local item
  for item in ${ARCHIVE_ITEMS[@]+"${ARCHIVE_ITEMS[@]}"}; do
    archive_check_tree "$item" || return 1
  done
}

# plan/ALL_CLIS に限定しない。全 entry を辿り、未知 lane・旧 generation も保護する。
archive_check_tree() {
  local item="$1" child prior seen GLOBIGNORE=''
  local children=()
  [[ ! -L "$item" && -r "$item" ]] || { archive_error "symlink or unreadable entry: ${item}"; return 1; }
  case "$item" in */.delegated/*.request|*/.delegated/*/*.request|*/.delegated/*/*/*.request)
    archive_error "outstanding request (a response or superseded flag is not adoption): ${item}"; return 1 ;;
  esac
  archive_known_entry "$item" || { archive_error "unrelated or unknown archive entry: ${item}"; return 1; }
  if [[ -d "$item" ]]; then
    ff_review_output_private "$item" || return 1
    [[ -x "$item" ]] || { archive_error "unsearchable directory: ${item}"; return 1; }
    for child in "$item"/* "$item"/.[!.]* "$item"/..?*; do
      [[ -e "$child" || -L "$child" ]] || continue
      seen=false
      for prior in ${children[@]+"${children[@]}"}; do [[ "$prior" != "$child" ]] || seen=true; done
      [[ "$seen" != true ]] || continue
      children+=("$child")
      archive_check_tree "$child" || return 1
    done
  elif [[ ! -f "$item" ]]; then
    archive_error "not a regular file/directory: ${item}"; return 1
  else
    ff_review_output_regular "$item" || return 1
  fi
}

archive_validate_report() {
  local report="${OUTPUT_DIR}/integrated-report.md" parsed entry tag value series='' block='' nonblock='' seen=' '
  local footer marker tail_text current expected digest marker_rc opposite
  [[ -f "$report" && ! -L "$report" && -r "$report" ]] || { archive_error 'live artifacts require a readable current-format integrated report'; return 1; }
  ARCHIVE_REPORT_DIGEST="$(git hash-object --no-filters "$report")" || return 1
  digest="$(LC_ALL=C tr -d '\000' < "$report" | git hash-object --stdin)" || return 1
  [[ "$digest" == "$ARCHIVE_REPORT_DIGEST" ]] || { archive_error 'NUL in report'; return 1; }
  parsed="$(extract_unresolved_critical_perspectives "$report")" || { archive_error 'unreadable or corrupt report footer'; return 1; }
  while IFS= read -r entry; do
    tag="${entry%%:*}"; value="${entry#*:}"
    case "$tag" in
      series)
        [[ -z "$series" && "$value" =~ ^[0-9]+-[0-9]+$ ]] || { archive_error 'invalid or repeated series token'; return 1; }
        series="$value" ;;
      block|nonblock)
        if [[ "$tag" == block ]]; then opposite=nonblock; else opposite=block; fi
        is_safe_token "$value" && [[ "$seen" != *" ${opposite}:${value} "* ]] || { archive_error 'invalid or contradictory perspective'; return 1; }
        seen="${seen}${tag}:${value} "
        if [[ "$tag" == block ]]; then block="${block:+$block }$value"; else nonblock="${nonblock:+$nonblock }$value"; fi ;;
      *) archive_error 'missing current-format series token'; return 1 ;;
    esac
  done <<< "$parsed"
  [[ -n "$series" ]] || { archive_error 'legacy report without a series token'; return 1; }
  footer="$(tail -n 1 "$report")" || return 1
  [[ "$footer" == "<!-- MULTI_CLI_UNRESOLVED_CRITICAL series:${series} block:${block:--} nonblock:${nonblock:--} -->" ]] || { archive_error 'noncanonical report footer'; return 1; }
  tail_text="$(tail -n 12 "$report")" || return 1
  for tag in block nonblock; do
    if [[ "$tag" == block ]]; then marker=CRITICAL_BLOCK; value="$block"; else marker=CRITICAL_NONBLOCK; value="$nonblock"; fi
    if printf '%s\n' "$tail_text" | grep -Fx "<!-- ${marker} -->" >/dev/null; then
      [[ -n "$value" ]] || { archive_error 'Critical marker contradicts empty state'; return 1; }
    else
      marker_rc=$?
      [[ "$marker_rc" == 1 ]] || { archive_error 'cannot inspect Critical markers'; return 1; }
      [[ -z "$value" ]] || { archive_error 'Critical state has no matching marker'; return 1; }
    fi
  done
  if [[ -n "$block$nonblock" ]]; then
    [[ -n "$ARCHIVE_PREVIOUS_BRANCH" ]] || { archive_error 'unresolved Critical requires --archive-only=<known-previous-branch> and the original base identity'; return 1; }
    current="$(git symbolic-ref --quiet HEAD)" || { archive_error 'current branch cannot be identified'; return 1; }
    [[ "$current" != "$ARCHIVE_PREVIOUS_BRANCH" ]] || { archive_error 'same-branch unresolved Critical must carry forward'; return 1; }
    expected="$(review_series_id_for "$ARCHIVE_REPO" "$ARCHIVE_PREVIOUS_BRANCH" "$BASE_BRANCH_IDENTITY" branch)" || return 1
    [[ "$series" == "$expected" ]] || { archive_error 'previous branch/base/scope does not match the report series'; return 1; }
  fi
  digest="$(git hash-object --no-filters "$report")" || return 1
  [[ "$digest" == "$ARCHIVE_REPORT_DIGEST" ]] || { archive_error 'report changed during eligibility checks'; return 1; }
}

archive_recheck() {
  local current digest item found prior
  current="$(archive_current_identity)" || return 1
  [[ "$current" == "$ARCHIVE_CURRENT_BRANCH" ]] || { archive_error 'branch changed during archive'; return 1; }
  digest="$(git hash-object --no-filters "${OUTPUT_DIR}/integrated-report.md")" || return 1
  [[ "$digest" == "$ARCHIVE_REPORT_DIGEST" ]] || { archive_error 'report changed during archive'; return 1; }
  # Only the report is expected after all other inventory entries were moved.
  local original=( ${ARCHIVE_ITEMS[@]+"${ARCHIVE_ITEMS[@]}"} )
  archive_collect_live || return 1
  for item in ${ARCHIVE_ITEMS[@]+"${ARCHIVE_ITEMS[@]}"}; do
    found=false
    for prior in ${original[@]+"${original[@]}"}; do [[ "$item" != "$prior" ]] || found=true; done
    [[ "$found" == true ]] || { archive_error "new live entry during archive: ${item}"; return 1; }
  done
}

# Shared movement for ordinary --fresh and the checked standalone operation.
# Report is last. Only archive-only keeps the existing lock after a partial move.
archive_live_outputs() { # <fresh|archive-only>
  local operation="$1" item base ts archive moved=0 report=''
  local inventory=( ${ARCHIVE_ITEMS[@]+"${ARCHIVE_ITEMS[@]}"} )
  if [[ "${#inventory[@]}" -eq 0 ]]; then
    echo "ℹ️  --${operation}: no previous results to archive in ${OUTPUT_DIR}" >&2
    report_archive_accumulation
    return 0
  fi
  ts="$(date -u +%Y%m%dT%H%M%SZ)" || return 1
  archive="${OUTPUT_DIR}/.prev-${ts}"
  [[ ! -e "$archive" && ! -L "$archive" ]] || archive="${archive}-$$"
  if ! (umask 077; mkdir "$archive"); then
    archive_error "cannot create archive destination: ${archive}"; return 1
  fi
  ARCHIVE_DESTINATION="$archive"
  [[ "$operation" != archive-only ]] || ARCHIVE_KEEP_LOCK=true
  for item in "${inventory[@]}"; do
    base="${item##*/}"
    if [[ "$base" == integrated-report.md ]]; then report="$item"; continue; fi
    if ! mv "$item" "${archive}/${base}"; then
      echo "ERROR: --${operation} left a partial archive at ${archive}: ${item}" >&2; return 1
    fi
    moved=$((moved + 1))
  done
  if [[ "$operation" == archive-only ]]; then
    archive_recheck || return 1
    [[ "${#ARCHIVE_ITEMS[@]}" -eq 1 && "${ARCHIVE_ITEMS[0]}" == "$report" ]] || { archive_error 'live inventory changed before report commit'; return 1; }
  fi
  if [[ -n "$report" ]]; then
    if ! mv "$report" "${archive}/integrated-report.md"; then
      echo "ERROR: --${operation} left a partial archive at ${archive}: ${report}" >&2; return 1
    fi
    moved=$((moved + 1))
  fi
  ARCHIVE_KEEP_LOCK=false
  echo "🧹 --${operation}: archived ${moved} previous result(s) to ${archive}" >&2
  report_archive_accumulation
}

run_archive_only() {
  local item before_branch
  [[ "$IN_GIT_REPO" == true ]] || { archive_error 'not inside a Git repository'; return 1; }
  ARCHIVE_REPO="$(cd "$REPO_ROOT" && pwd -P)" || return 1
  ARCHIVE_CURRENT_BRANCH="$(archive_current_identity)" || { archive_error 'current branch cannot be identified'; return 1; }
  prepare_output_namespace || return 1
  validate_output_dir_boundary || return 1
  acquire_output_lock || return 1
  archive_collect_live || return 1
  [[ "${#ARCHIVE_ITEMS[@]}" -gt 0 ]] || { archive_live_outputs archive-only; return $?; }
  archive_validate_inventory || return 1
  load_delegation_state || return 1
  archive_validate_report || return 1
  before_branch="$(archive_current_identity)" || return 1
  [[ "$before_branch" == "$ARCHIVE_CURRENT_BRANCH" ]] || { archive_error 'branch changed before archive'; return 1; }
  [[ "$(git hash-object --no-filters "${OUTPUT_DIR}/integrated-report.md")" == "$ARCHIVE_REPORT_DIGEST" ]] || { archive_error 'report changed before archive'; return 1; }
  archive_live_outputs archive-only
}

_ma_part_loaded="multi-agent-archive.sh"
