#!/usr/bin/env bash
# Read-only Bash3.2 counterpart of the TS layout/row contract.
# select BOOK prints a selected path (rc0) or diagnostic (rc2).
# helpful_check BOOK preserves rc0/1/2. Diagnostics identify the actual file.

FF_PLAYBOOK_CHANGELOG_VERDICT=""

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
  local file="$1" scanner="${BASH_SOURCE[0]%/*}/playbook-changelog-scan.awk" permissions
  FF_PLAYBOOK_CHANGELOG_VERDICT=unreadable-file
  FF_PLAYBOOK_CHANGELOG_OUTPUT=""
  if [ ! -f "$file" ] || [ ! -r "$file" ] || [ ! -r "$scanner" ]; then return 2; fi
  if ! permissions="$(LC_ALL=C ls -ld -- "$file" 2>/dev/null)"; then return 2; fi
  [[ "${permissions:1:1}${permissions:4:1}${permissions:7:1}" == *r* ]] || return 2
  if ! FF_PLAYBOOK_CHANGELOG_OUTPUT="$(LC_ALL=C awk -f "$scanner" "$file" 2>/dev/null)"; then return 2; fi
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

ff_playbook_changelog_select() {
  local book="${1:-}" root candidate present=0 chosen="" physical
  if [ -z "$book" ]; then printf '%s\n' 'PLAYBOOK のパスが空です'; return 2; fi
  if _ff_playbook_changelog_scan "$book"; then :; fi
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
  if [ -L "$chosen" ] || [ ! -f "$chosen" ]; then printf '%s\n' "Changelog が通常ファイルではありません: $chosen"; return 2; fi
  if ! physical="$(CDPATH='' cd -P -- "${chosen%/*}" && pwd)"; then return 2; fi
  case "$physical/" in "$root/"*) ;; *) printf '%s\n' "Changelog が PLAYBOOK の領域外です: $chosen"; return 2 ;; esac
  if _ff_playbook_changelog_scan "$chosen"; then :; fi
  case "$FF_PLAYBOOK_CHANGELOG_VERDICT" in
    no-changelog|empty-stub|unreadable-file) printf '%s\n' "Changelog の版を読めません: $chosen"; return 2 ;;
  esac
  printf '%s\n' "$chosen"
}

ff_playbook_changelog_helpful_check() {
  local book="${1:-}" selected
  FF_PLAYBOOK_CHANGELOG_VERDICT=""
  if ! selected="$(ff_playbook_changelog_select "$book")"; then
    FF_PLAYBOOK_CHANGELOG_VERDICT=unreadable-file
    case "$selected" in *候補が複数*) FF_PLAYBOOK_CHANGELOG_VERDICT=ambiguous-changelog ;; esac
    printf '%s\n' "$selected"; return 2
  fi
  if _ff_playbook_changelog_scan "$selected"; then :; fi
  case "$FF_PLAYBOOK_CHANGELOG_VERDICT" in
    ok) return 0 ;;
    unreadable-helpful) printf '%s\n' "$FF_PLAYBOOK_CHANGELOG_OUTPUT" | sed '$d'; return 1 ;;
    no-changelog) printf '%s\n' "PLAYBOOK.md に ## Changelog がありません（parseChangelog と同じく判定不能）: $selected" ;;
    empty-stub|no-rows)
      FF_PLAYBOOK_CHANGELOG_VERDICT=no-rows
      printf '%s\n' "Changelog の追加 / カウンター更新の行が 1 件も読めません: $selected" ;;
    *) printf '%s\n' "Changelog の行形式を読めません: $selected"; printf '%s\n' "$FF_PLAYBOOK_CHANGELOG_OUTPUT" | sed '$d' ;;
  esac
  return 2
}
