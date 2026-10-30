#!/usr/bin/env bash
# Sourced by verify.sh. Exercises the real Bash 3.2 reader with synthetic bytes.
. "$PLUGIN_ROOT/scripts/lib/knowledge-read-boundary.sh"
read_probe="$(mktemp -d "$TMP/read-boundary.XXXXXX")" || exit 1
ff_knowledge_private_fresh_directory "$read_probe" || exit 1
mkdir "$read_probe/project" "$read_probe/outside" "$read_probe/job"
ff_knowledge_private_fresh_directory "$read_probe/job" || exit 1
mkdir "$read_probe/control" "$read_probe/control"$'\n'
read_rc=0; read_result="$(
  CDPATH= cd -P -- "$read_probe/control"$'\n' || exit 2
  ff_knowledge_project_context
)" 2>"$read_probe/error" || read_rc=$?
[[ "$read_rc" -eq 2 && -z "$read_result" ]] && ok 'K31: project cwd controls refused before command substitution truncation' || bad 'K31: project context stripped a control byte'
read_rc=0; read_result="$(
  CDPATH= cd -P -- "$read_probe/control"$'\n' || exit 2
  ff_knowledge_lexical_path input.md
)" 2>"$read_probe/error" || read_rc=$?
[[ "$read_rc" -eq 2 && -z "$read_result" ]] && ok 'K31: relative operand refuses control-bearing cwd' || bad 'K31: relative operand stripped a cwd control byte'
read_input="$read_probe/project/input.md"
read_expected="$read_probe/expected"
printf '知識📚\r\n\n' >"$read_input"
cp "$read_input" "$read_expected"
read_rc=0; read_snapshot="$(ff_knowledge_snapshot "$read_input" "$read_probe/project" "$read_probe/job")" || read_rc=$?
[[ "$read_rc" -eq 0 ]] && cmp -s "$read_expected" "$read_snapshot" && ok 'K31: Bash UTF-8/CRLF/trailing LF preserved' || bad 'K31: text fidelity'
for read_case in nul invalid truncated surrogate overlong continuation out-of-range; do
  case "$read_case" in
    nul) printf 'before\000after' >"$read_input" ;;
    invalid) printf '\377' >"$read_input" ;;
    truncated) printf '\342\202' >"$read_input" ;;
    surrogate) printf '\355\240\200' >"$read_input" ;;
    overlong) printf '\300\257' >"$read_input" ;;
    continuation) printf '\200' >"$read_input" ;;
    out-of-range) printf '\364\220\200\200' >"$read_input" ;;
  esac
  read_rc=0; read_snapshot="$(ff_knowledge_snapshot "$read_input" "$read_probe/project" "$read_probe/job" 2>"$read_probe/error")" || read_rc=$?
  [[ "$read_rc" -eq 2 && -z "$read_snapshot" ]] && ok "K31: Bash $read_case refused without snapshot" || bad "K31: $read_case rc=$read_rc"
done
printf normal >"$read_input"
ln "$read_input" "$read_probe/project/hard.md"
read_rc=0; read_snapshot="$(ff_knowledge_snapshot "$read_input" "$read_probe/project" "$read_probe/job" 2>"$read_probe/error")" || read_rc=$?
[[ "$read_rc" -eq 2 && -z "$read_snapshot" ]] && ok 'K31: Bash hardlink refused before bytes' || bad 'K31: hardlink accepted'
rm "$read_probe/project/hard.md" "$read_input"
mkfifo "$read_input"
read_rc=0; read_snapshot="$(ff_knowledge_snapshot "$read_input" "$read_probe/project" "$read_probe/job" 2>"$read_probe/error")" || read_rc=$?
[[ "$read_rc" -eq 2 && -z "$read_snapshot" ]] && ok 'K31: Bash FIFO refused before open' || bad 'K31: FIFO accepted'
rm "$read_input"
dd if=/dev/zero bs=1048576 count=4 2>/dev/null | LC_ALL=C tr '\000' x >"$read_input"
read_rc=0; read_snapshot="$(ff_knowledge_snapshot "$read_input" "$read_probe/project" "$read_probe/job" 2>"$read_probe/error")" || read_rc=$?
[[ "$read_rc" -eq 0 ]] && cmp -s "$read_input" "$read_snapshot" && ok 'K31: Bash exact 4 MiB accepted intact' || bad "K31: byte limit control rc=$read_rc"
printf x >>"$read_input"
read_rc=0; read_snapshot="$(ff_knowledge_snapshot "$read_input" "$read_probe/project" "$read_probe/job" 2>"$read_probe/error")" || read_rc=$?
[[ "$read_rc" -eq 2 && -z "$read_snapshot" ]] && ok 'K31: Bash 4 MiB + 1 refused' || bad 'K31: oversized input accepted'
printf normal >"$read_input"
# A copied executable in the minimal PATH cannot load its DLLs (rc=127), so the copy does not stand in.
if ! kl_skip_no_symlink 'K31 の最小 PATH（コピーした実行ファイルは DLL を読めない）'; then
  read_bin="$read_probe/no-node-bin"; mkdir "$read_bin"
  for read_command in awk uname stat mktemp chmod rm readlink head tr; do
    ln -s "$(command -v "$read_command")" "$read_bin/$read_command"
  done
  read_rc=0; read_snapshot="$(PATH="$read_bin" ff_knowledge_snapshot "$read_input" "$read_probe/project" "$read_probe/job" 2>"$read_probe/error")" || read_rc=$?
  [[ "$read_rc" -eq 0 ]] && cmp -s "$read_input" "$read_snapshot" && ok 'K31: Bash reader needs neither Node nor Python' || bad "K31: minimal PATH rc=$read_rc"
fi
if [[ "$(uname -s)" == Darwin ]]; then
  mkdir "$read_probe/inherited"
  /bin/chmod +a 'everyone allow list,search,readattr,readextattr,readsecurity,file_inherit,directory_inherit' "$read_probe/inherited" || exit 1
  read_parent_before="$(/bin/ls -ldeb "$read_probe/inherited" | awk 'NR == 1 { print substr($0, 1, 11); next } { print }')"
  mkdir "$read_probe/inherited/fresh"
  ff_knowledge_private_fresh_directory "$read_probe/inherited/fresh"; read_rc=$?
  read_parent_after="$(/bin/ls -ldeb "$read_probe/inherited" | awk 'NR == 1 { print substr($0, 1, 11); next } { print }')"
  read_child_acl="$(/bin/ls -ldeb "$read_probe/inherited/fresh")"
  [[ "$read_rc" -eq 0 && "$read_parent_before" == "$read_parent_after" && "$read_child_acl" != *' allow '* ]] \
    && ok 'K31: native Darwin strips inherited grants only on fresh workspace' || bad 'K31: private staging or existing parent preservation'
fi

# The Bash Changelog contract shares the Node selector's boundary and snapshot rule.
. "$PLUGIN_ROOT/scripts/lib/playbook-changelog-functions.sh"
mkdir "$read_probe/history"
read_book="$read_probe/history/PLAYBOOK.md"
read_history="$read_probe/history/CHANGELOG.md"
printf '# Book\n## Changelog\n[history](CHANGELOG.md)\n' >"$read_book"
printf '## Changelog\n### [1.0.0] - 2026-10-29\n#### 追加\n- ACE-2432-1: normal\n' >"$read_probe/history/actual.md"
if kl_skip_no_symlink 'K31 の Bash Changelog のリンク 4 件（範囲内のリンク・外部のリンク・明示の文脈・cwd 相対）'; then
  cp "$read_probe/history/actual.md" "$read_history" # the snapshot count below needs no link
else
  ln -s actual.md "$read_history"
  read_rc=0; ff_playbook_changelog_helpful_check "$read_book" >"$read_probe/history-output" 2>"$read_probe/error" || read_rc=$?
  [[ "$read_rc" -eq 0 && "$FF_PLAYBOOK_CHANGELOG_VERDICT" == ok ]] && ok 'K31: Bash Changelog accepts a protected in-area link' || bad 'K31: Bash Changelog safe-link compatibility'
  rm "$read_history"; ln -s "$read_probe/outside/private.md" "$read_history"
  printf '## Changelog\n### [1.0.0] - 2026-10-29\n#### 追加\n- ACE-2432-1: private-history-canary-2432\n' >"$read_probe/outside/private.md"
  read_rc=0; ff_playbook_changelog_helpful_check "$read_book" >"$read_probe/history-output" 2>"$read_probe/error" || read_rc=$?
  [[ "$read_rc" -eq 2 && "$FF_PLAYBOOK_CHANGELOG_VERDICT" == unreadable-file && "$(cat "$read_probe/history-output" "$read_probe/error")" != *private-history-canary-2432* ]] \
    && ok 'K31: Bash Changelog refuses discovered external text' || bad 'K31: Bash Changelog external read'
  mkdir "$read_probe/bound-project"
  ln -s "$read_probe/outside/private.md" "$read_probe/bound-project/PLAYBOOK.md"
  read_rc=0; ff_playbook_changelog_helpful_check "$read_probe/bound-project/PLAYBOOK.md" "$read_probe/bound-project" >"$read_probe/history-output" 2>"$read_probe/error" || read_rc=$?
  [[ "$read_rc" -eq 2 && "$FF_PLAYBOOK_CHANGELOG_VERDICT" == unreadable-file && "$(cat "$read_probe/history-output" "$read_probe/error")" != *private-history-canary-2432* ]] \
    && ok 'K31: Bash writer uses its explicit project context outside caller cwd' || bad 'K31: external writer context silently promoted a main link'
  read_rc=0; read_result="$(
    CDPATH= cd -P -- "$read_probe/bound-project" || exit 2
    ff_playbook_changelog_helpful_check "$read_probe/bound-project/PLAYBOOK.md"
  )" 2>"$read_probe/error" || read_rc=$?
  [[ "$read_rc" -eq 2 && "$read_result$(cat "$read_probe/error")" != *private-history-canary-2432* ]] \
    && ok 'K31: Bash Changelog local operand creates no external grant' || bad 'K31: local main operand silently promoted by selector'
  rm "$read_history"; ln -s actual.md "$read_history"
fi
# Fixed transform of our own reader for an open-count oracle; no input text is executed.
sed 's/^ff_knowledge_snapshot()/ff_counted_original_snapshot()/' "$PLUGIN_ROOT/scripts/lib/knowledge-read-boundary.sh" >"$read_probe/counted-reader.sh"
cp "$PLUGIN_ROOT/scripts/lib/knowledge-read-acl.ps1" "$read_probe/knowledge-read-acl.ps1"
. "$read_probe/counted-reader.sh"
: >"$read_probe/open-count"
ff_knowledge_snapshot() {
  printf '%s\n' "$1" >>"$read_probe/open-count"
  ff_counted_original_snapshot "$@"
}
read_rc=0; ff_playbook_changelog_helpful_check "$read_book" >"$read_probe/history-output" 2>"$read_probe/error" || read_rc=$?
read_open_count="$(awk 'END { print NR + 0 }' "$read_probe/open-count")"
[[ "$read_rc" -eq 0 && "$read_open_count" -eq 2 ]] && ok 'K31: Bash Changelog snapshots main/history once each across selection and validation' || bad "K31: Bash Changelog original reopen (rc=$read_rc opens=$read_open_count)"
. "$PLUGIN_ROOT/scripts/lib/knowledge-read-boundary.sh"
