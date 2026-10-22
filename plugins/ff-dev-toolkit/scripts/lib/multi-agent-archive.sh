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

# GLOBIGNORE と dotglob の呼出元設定に左右されず、dotfile/壊れた link も列挙する。
# 3 glob の重複だけを exact path 比較で除く。空集合と読取不能を区別する。
archive_collect_live() {
  local item base seen prior GLOBIGNORE=''
  ARCHIVE_ITEMS=()
  [[ -d "$OUTPUT_DIR" && -r "$OUTPUT_DIR" && -x "$OUTPUT_DIR" ]] || { archive_error "unreadable output directory: ${OUTPUT_DIR}"; return 1; }
  for item in "$OUTPUT_DIR"/* "$OUTPUT_DIR"/.[!.]* "$OUTPUT_DIR"/..?*; do
    [[ -e "$item" || -L "$item" ]] || continue
    base="${item##*/}"
    case "$base" in .multi-agent-run.lock|.prev-*) continue ;; esac
    seen=false
    for prior in ${ARCHIVE_ITEMS[@]+"${ARCHIVE_ITEMS[@]}"}; do [[ "$prior" != "$item" ]] || seen=true; done
    [[ "$seen" != true ]] || continue
    ARCHIVE_ITEMS+=("$item")
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
  if [[ -d "$item" ]]; then
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
  if ! mkdir "$archive"; then
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
  [[ ! -L "$OUTPUT_DIR" ]] || { archive_error 'output directory is a symlink'; return 1; }
  mkdir -p "$OUTPUT_DIR" || return 1
  OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)" || return 1
  validate_output_dir_boundary || return 1
  acquire_output_lock || return 1
  archive_collect_live || return 1
  [[ "${#ARCHIVE_ITEMS[@]}" -gt 0 ]] || { archive_live_outputs archive-only; return $?; }
  for item in "${ARCHIVE_ITEMS[@]}"; do archive_check_tree "$item" || return 1; done
  load_delegation_state || return 1
  archive_validate_report || return 1
  before_branch="$(archive_current_identity)" || return 1
  [[ "$before_branch" == "$ARCHIVE_CURRENT_BRANCH" ]] || { archive_error 'branch changed before archive'; return 1; }
  [[ "$(git hash-object --no-filters "${OUTPUT_DIR}/integrated-report.md")" == "$ARCHIVE_REPORT_DIGEST" ]] || { archive_error 'report changed before archive'; return 1; }
  archive_live_outputs archive-only
}

_ma_part_loaded="multi-agent-archive.sh"
