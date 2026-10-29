#!/usr/bin/env bash
# Read-only Bash3.2 counterpart of the TS layout/row contract.
# select BOOK [PROJECT_ROOT] prints a selected path (rc0) or diagnostic (rc2).
# helpful_check BOOK [PROJECT_ROOT] preserves rc0/1/2. A writer binds its target project.

FF_PLAYBOOK_CHANGELOG_VERDICT=""
_ff_changelog_reader="${BASH_SOURCE[0]%/*}/knowledge-read-boundary.sh"
if [ ! -f "$_ff_changelog_reader" ] || [ -L "$_ff_changelog_reader" ]; then
  printf 'knowledge-read: missing-reader\n' >&2
  return 2
fi
. "$_ff_changelog_reader"

_ff_playbook_changelog_job() {
  local job
  job="$(ff_knowledge_job_directory playbook-changelog)" || return 2
  : >"$job/cache"
  printf '%s\n' "$job"
}

_ff_playbook_changelog_authority() {
  local project selected operand_rc
  if [ -n "${2:-}" ]; then project="$2"
  else project="$(ff_knowledge_project_context)" || return 2
  fi
  project="$(ff_knowledge_canonical_dir "$project")" || return 2
  ff_knowledge_storage "$project" dir || return 2
  if [ -n "${2:-}" ]; then printf '%s\n' "$project"; return 0; fi
  if ff_knowledge_project_operand "$1" "$project"; then printf '%s\n' "$project"
  else
    operand_rc=$?
    [ "$operand_rc" -eq 1 ] || return 2
    selected="$(ff_knowledge_canonical_file "$1")" || return 2
    printf '%s\n' "${selected%/*}"
  fi
}

# A directly requested fixed CHANGELOG must not bypass its book's gate.
ff_playbook_changelog_book() {
  local file="$1" root book="" count=0 candidate
  root="${file%/*}"
  candidate="$root/PLAYBOOK.md"
  if [ -f "$candidate" ]; then book="$candidate"; count=$((count + 1)); fi
  if [ "${root##*/}" = playbook ]; then
    candidate="${root%/*}/PLAYBOOK.md"
    if [ -f "$candidate" ]; then book="$candidate"; count=$((count + 1)); fi
  fi
  if [ "$count" -gt 1 ]; then printf '%s\n' "Changelog に対応する PLAYBOOK が複数あります: $file"; return 2; fi
  if [ "$count" -eq 0 ]; then printf '%s\n' "Changelog に対応する PLAYBOOK がありません: $file"; return 2; fi
  printf '%s\n' "$book"
}

_ff_playbook_changelog_scan() {
  local file="$1" job="$2" authority="$3" scanner="${BASH_SOURCE[0]%/*}/playbook-changelog-scan.awk" canonical stamp snapshot
  FF_PLAYBOOK_CHANGELOG_VERDICT=unreadable-file
  FF_PLAYBOOK_CHANGELOG_OUTPUT=""
  [ -r "$scanner" ] || return 2
  canonical="$(ff_knowledge_authorize "$file" "$authority")" || return 2
  stamp="$(ff_knowledge_meta "$canonical")" || return 2
  snapshot="$(FF_READ_KEY="$canonical" FF_READ_STAMP="$stamp" awk -F '\t' '$1 == ENVIRON["FF_READ_KEY"] { if ($2 != ENVIRON["FF_READ_STAMP"]) exit 2; print $3; exit }' "$job/cache")" || return 2
  if [ -z "$snapshot" ]; then
    snapshot="$(ff_knowledge_snapshot "$file" "$authority" "$job")" || return 2
    printf '%s\t%s\t%s\n' "$canonical" "$stamp" "$snapshot" >>"$job/cache"
  fi
  if ! FF_PLAYBOOK_CHANGELOG_OUTPUT="$(FF_READ_KEY="$file" LC_ALL=C awk -f "$scanner" "$snapshot" 2>/dev/null)"; then return 2; fi
  case "$FF_PLAYBOOK_CHANGELOG_OUTPUT" in
    *VERDICT=ok) FF_PLAYBOOK_CHANGELOG_VERDICT=ok; return 0 ;;
    *VERDICT=unreadable-helpful) FF_PLAYBOOK_CHANGELOG_VERDICT=unreadable-helpful; return 1 ;;
    *VERDICT=unreadable-format) FF_PLAYBOOK_CHANGELOG_VERDICT=unreadable-format ;;
    *VERDICT=no-changelog) FF_PLAYBOOK_CHANGELOG_VERDICT=no-changelog ;;
    *VERDICT=empty-stub) FF_PLAYBOOK_CHANGELOG_VERDICT=empty-stub ;;
    *VERDICT=no-rows) FF_PLAYBOOK_CHANGELOG_VERDICT=no-rows ;;
  esac
  return 2
}

_ff_playbook_changelog_select() {
  local book="${1:-}" job="$2" authority="$3" root candidate present=0 chosen="" physical
  if [ -z "$book" ]; then printf '%s\n' 'PLAYBOOK のパスが空です'; return 2; fi
  if _ff_playbook_changelog_scan "$book" "$job" "$authority"; then :; fi
  case "$FF_PLAYBOOK_CHANGELOG_VERDICT" in
    no-changelog|empty-stub) ;;
    unreadable-file) printf '%s\n' "Changelog を読めません: $book"; return 2 ;;
    *) printf '%s\n' "$book"; return 0 ;;
  esac
  root="${book%/*}"
  if [ "$root" = "$book" ]; then root=.; fi
  if ! root="$(CDPATH='' cd -P -- "$root" && pwd)"; then return 2; fi
  for candidate in "$root/CHANGELOG.md" "$root/playbook/CHANGELOG.md"; do
    if [ -e "$candidate" ] || [ -L "$candidate" ]; then present=$((present + 1)); chosen="$candidate"; fi
  done
  if [ "$present" -gt 1 ]; then
    printf '%s\n' "Changelog の候補が複数あります: $root/CHANGELOG.md / $root/playbook/CHANGELOG.md"; return 2
  fi
  if [ "$present" -eq 0 ]; then printf '%s\n' "$book"; return 0; fi
  if ! physical="$(ff_knowledge_authorize "$chosen" "$authority")"; then return 2; fi
  case "$physical" in "$root/"*) ;; *) printf '%s\n' "Changelog が PLAYBOOK の領域外です: $chosen"; return 2 ;; esac
  if _ff_playbook_changelog_scan "$chosen" "$job" "$authority"; then :; fi
  case "$FF_PLAYBOOK_CHANGELOG_VERDICT" in
    no-changelog|empty-stub|unreadable-file) printf '%s\n' "Changelog の版を読めません: $chosen"; return 2 ;;
  esac
  printf '%s\n' "$chosen"
}

ff_playbook_changelog_select() (
  local book="${1:-}" job authority
  authority="$(_ff_playbook_changelog_authority "$book" "${2:-}")" || return 2
  job="$(_ff_playbook_changelog_job)" || return 2
  trap 'rm -rf -- "$job"' EXIT
  _ff_playbook_changelog_select "$book" "$job" "$authority"
)

ff_playbook_changelog_helpful_check() {
  local book="${1:-}" selected job authority result=2
  FF_PLAYBOOK_CHANGELOG_VERDICT=""
  authority="$(_ff_playbook_changelog_authority "$book" "${2:-}")" || { FF_PLAYBOOK_CHANGELOG_VERDICT=unreadable-file; return 2; }
  job="$(_ff_playbook_changelog_job)" || { FF_PLAYBOOK_CHANGELOG_VERDICT=unreadable-file; return 2; }
  if ! selected="$(_ff_playbook_changelog_select "$book" "$job" "$authority")"; then
    FF_PLAYBOOK_CHANGELOG_VERDICT=unreadable-file
    case "$selected" in *候補が複数*) FF_PLAYBOOK_CHANGELOG_VERDICT=ambiguous-changelog ;; esac
    printf '%s\n' "$selected"; rm -rf -- "$job"; return 2
  fi
  if _ff_playbook_changelog_scan "$selected" "$job" "$authority"; then :; fi
  case "$FF_PLAYBOOK_CHANGELOG_VERDICT" in
    ok) result=0 ;;
    unreadable-helpful) printf '%s\n' "$FF_PLAYBOOK_CHANGELOG_OUTPUT" | sed '$d'; result=1 ;;
    no-changelog) printf '%s\n' "PLAYBOOK.md に ## Changelog がありません（parseChangelog と同じく判定不能）: $selected" ;;
    empty-stub|no-rows)
      FF_PLAYBOOK_CHANGELOG_VERDICT=no-rows
      printf '%s\n' "Changelog の追加 / カウンター更新の行が 1 件も読めません: $selected" ;;
    *) printf '%s\n' "Changelog の行形式を読めません: $selected"; printf '%s\n' "$FF_PLAYBOOK_CHANGELOG_OUTPUT" | sed '$d' ;;
  esac
  rm -rf -- "$job"
  return "$result"
}
