#!/usr/bin/env bash
# Extended H23 matrix. All inputs are isolated copies of the synthetic book.
run_h23_layout_cases() {
  local layout_root="$WORK/history-layouts" layout_count=0 layout_case layout_target
  mkdir -p "$layout_root"
  h23_layout_make() {
    local name="$1" location="$2"
    layout_case="$layout_root/$name"
    mkdir -p "$layout_case/playbook"
    cp "$SYN/playbook/testing.md" "$layout_case/playbook/testing.md"
    awk '/^## Changelog/ { exit } { print }' "$SYN/PLAYBOOK.md" >"$layout_case/PLAYBOOK.md"
    layout_target="$layout_case/$location"
    awk '/^## Changelog/ { found=1 } found { print }' "$SYN/PLAYBOOK.md" >"$layout_target"
  }
  h23_layout_check() {
    layout_count=$((layout_count + 1))
    h23_case "layout-$1" "$layout_case/PLAYBOOK.md" "$2"
  }
  h23_layout_legacy() {
    printf '%s\n' '## v1.2.0 (2026-03-01)' \
      '- 追加: ACE-30-1（testing）、ACE-10-2（testing）' \
      '- 更新: ACE-10-1 Helpful +1（同じ操作）' \
      '## v1.1.0 (2026-02-01)' '- 追加: ACE-20-1（testing）' >"$layout_target"
  }
  for layout_location in CHANGELOG.md playbook/CHANGELOG.md; do
    if [ "$layout_location" = CHANGELOG.md ]; then layout_label=root; else layout_label=sub; fi
    h23_layout_make "canonical-$layout_label" "$layout_location"; h23_layout_check "canonical-$layout_label" ok
    h23_layout_make "legacy-$layout_label" "$layout_location"; h23_layout_legacy; h23_layout_check "legacy-$layout_label" ok
    h23_layout_make "stub-$layout_label" "$layout_location"
    printf '%s\n' '' '## Changelog' '' '[history](CHANGELOG.md)' >>"$layout_case/PLAYBOOK.md"
    h23_layout_check "stub-$layout_label" ok
  done
  h23_layout_make main-bad CHANGELOG.md
  cp "$WORK/badhelp/PLAYBOOK.md" "$layout_case/PLAYBOOK.md"
  h23_layout_check main-bad unreadable-helpful
  h23_layout_make ambiguous CHANGELOG.md
  cp "$layout_target" "$layout_case/playbook/CHANGELOG.md"
  h23_layout_check ambiguous ambiguous-changelog
  h23_layout_make empty CHANGELOG.md; : >"$layout_target"; h23_layout_check empty unreadable-file
  h23_layout_make missing CHANGELOG.md; rm "$layout_target"; h23_layout_check missing no-changelog
  h23_layout_make unreadable CHANGELOG.md; chmod 000 "$layout_target"
  h23_layout_check unreadable unreadable-file; chmod 644 "$layout_target"
  h23_layout_make symlink CHANGELOG.md; mv "$layout_target" "$layout_case/history.md"
  ln -s history.md "$layout_target"; h23_layout_check symlink unreadable-file
  h23_layout_make legacy-bundled CHANGELOG.md; h23_layout_legacy
  printf '%s\n' '- 更新: ACE-10-1 / ACE-20-1 Helpful +1（束ね形）' >>"$layout_target"
  h23_layout_check legacy-bundled unreadable-helpful
  h23_layout_make legacy-unknown CHANGELOG.md; h23_layout_legacy
  printf '%s\n' '- 追加: unknown' >>"$layout_target"
  h23_layout_check legacy-unknown unreadable-format
  h23_layout_make examples CHANGELOG.md
  cp "$layout_target" "$layout_case/history.md"
  {
    printf '%s\n' '---' 'example: ignored' '---' '```md' '## v9.9.9 (2026-03-01)' '- 更新: broken Helpful +1' '```' '<!--' '## Changelog' '- Helpful +1: broken' '-->'
    cat "$layout_case/history.md"
    printf '%s\n' '## Other' '- Helpful +1: ignored'
  } >"$layout_target"
  h23_layout_check examples ok
  h23_layout_make comment-fence CHANGELOG.md
  cp "$layout_target" "$layout_case/history.md"
  { printf '%s\n' '<!--' '```md' '## Changelog' '- Helpful +1: ignored' '```' '-->'; cat "$layout_case/history.md"; } >"$layout_target"
  h23_layout_check comment-fence ok
  h23_layout_make joined-heading CHANGELOG.md
  sed 's/^## Changelog$/## Change<!-- x -->log/' "$layout_target" >"$layout_target.tmp"
  mv "$layout_target.tmp" "$layout_target"; h23_layout_check joined-heading unreadable-file
  h23_layout_make joined-id CHANGELOG.md; h23_layout_legacy
  printf '%s\n' '- 更新: ACE-10<!-- x -->-1 Helpful +1（分断ID）' >>"$layout_target"
  h23_layout_check joined-id unreadable-helpful
  h23_layout_make trailing-comment CHANGELOG.md
  sed 's/^## Changelog$/## Changelog<!-- x -->/' "$layout_target" >"$layout_target.tmp"
  mv "$layout_target.tmp" "$layout_target"; h23_layout_check trailing-comment ok
  h23_layout_make legacy-empty CHANGELOG.md; h23_layout_legacy
  printf '%s\n' '- 追加:' >>"$layout_target"; h23_layout_check legacy-empty unreadable-format
  h23_layout_make legacy-no-space CHANGELOG.md; h23_layout_legacy
  printf '%s\n' '- 追加:ACE-0-2（testing）' >>"$layout_target"; h23_layout_check legacy-no-space unreadable-format
  h23_layout_make spaced-version CHANGELOG.md
  sed 's/^### \[/###  [/' "$layout_target" >"$layout_target.tmp"
  mv "$layout_target.tmp" "$layout_target"; h23_layout_check spaced-version no-rows
  h23_layout_make date-less CHANGELOG.md
  printf '%s\n' '### [0.0.1]' '#### カウンター更新' '- Helpful +1: ACE-0-1 / ACE-0-2（invalid）' >>"$layout_target"
  h23_layout_check date-less unreadable-helpful
  h23_layout_make legacy-empty-space CHANGELOG.md; h23_layout_legacy
  printf '%s\n' '- 追加: ' >>"$layout_target"; h23_layout_check legacy-empty-space unreadable-format
  if [[ "$layout_count" -eq 24 ]]; then ok 'H23 layout: 24ケースを実行した'; else bad "H23 layout: ケースが空または欠落（$layout_count / 24）"; fi
}
