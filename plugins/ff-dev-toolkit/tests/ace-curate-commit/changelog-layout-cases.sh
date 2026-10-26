#!/usr/bin/env bash
# Called inside the isolated Git fixture subshell in verify.sh.
run_knowledge_layout_cases() {
  local count=0 location style case_dir target rc out before_index before_pending after_pending
  for location in CHANGELOG.md playbook/CHANGELOG.md; do
    for style in canonical legacy; do
      count=$((count + 1)); case_dir="$KC_TMP/layout-$count"
      new_repo "$case_dir" "Knowledge Test" "knowledge-test@example.com" || return 1
      cd "$case_dir" || return 1
      target="docs/08-knowledge/$location"
      cp docs/08-knowledge/PLAYBOOK.md "$target"
      printf '%s\n' '# playbook' '' '## Changelog' '[history](CHANGELOG.md)' >docs/08-knowledge/PLAYBOOK.md
      if [ "$style" = legacy ]; then
        printf '%s\n' '## v1.0.0 (2026-01-01)' '- 追加: ACE-0-1（coding）、ACE-0-2（testing）' >"$target"
      fi
      # Preserve an existing pending observation and unrelated staged file.
      printf '%s\n' '- baseline' >>docs/08-knowledge/OBSERVATIONS.md
      kc add --source obs --id OBS-layout --summary baseline -- docs/08-knowledge/OBSERVATIONS.md >/dev/null || return 1
      printf '%s\n' sentinel >>unrelated.txt
      git add unrelated.txt
      before_index="$(git write-tree)"
      before_pending="$(kc status)"
      rc=0; out="$(kc add --source ace --id ACE-layout --summary layout -- docs/08-knowledge/PLAYBOOK.md 2>&1)" || rc=$?
      after_pending="$(kc status)"
      if [ "$rc" -ne 2 ] || [[ "$out" != *"明示対象"* ]] || [ "$(git write-tree)" != "$before_index" ] || [ "$after_pending" != "$before_pending" ]; then
        echo "  ✗ layout $count: implicit stage or failure changed state ($rc / $out)" >&2; return 1
      fi
      rc=0; out="$(kc add --source ace --id ACE-layout --summary layout -- docs/08-knowledge/PLAYBOOK.md "$target" 2>&1)" || rc=$?
      if [ "$rc" -ne 0 ] || ! git diff --cached --name-only | grep -Fxq "$target"; then
        echo "  ✗ layout $count: explicit selected path rejected ($rc / $out)" >&2; return 1
      fi
      kc discard >/dev/null; git reset -q
      git add -- docs/08-knowledge/PLAYBOOK.md "$target"
      git commit -qm layout-fixture
      printf '%s\n' '' >>docs/08-knowledge/PLAYBOOK.md
      rc=0; out="$(cd docs/08-knowledge && kc add --source ace --id ACE-layout --summary subdir -- PLAYBOOK.md 2>&1)" || rc=$?
      if [ "$rc" -ne 0 ] || [ "$(git diff --cached --name-only)" != docs/08-knowledge/PLAYBOOK.md ]; then
        echo "  ✗ layout $count: unchanged external history misclassified from subdir ($rc / $out)" >&2; return 1
      fi
      kc discard >/dev/null; git reset -q
      printf '%s\n' '' >>"$target"
      before_index="$(git write-tree)"; before_pending="$(kc status)"
      rc=0; out="$(cd docs/08-knowledge && kc add --source ace --id ACE-layout --summary implicit -- PLAYBOOK.md 2>&1)" || rc=$?
      if [ "$rc" -ne 2 ] || [[ "$out" != *"明示対象"* ]] || [ "$(git write-tree)" != "$before_index" ] || [ "$(kc status)" != "$before_pending" ]; then
        echo "  ✗ layout $count: nested changed history bypass or changed state ($rc / $out)" >&2; return 1
      fi
      rc=0; out="$(cd docs && kc add --source ace --id ACE-layout --summary dot -- 08-knowledge/. 2>&1)" || rc=$?
      if [ "$rc" -ne 0 ]; then echo "  ✗ layout $count: dot directory is not explicit ($rc / $out)" >&2; return 1; fi
      kc discard >/dev/null; git reset -q
      git checkout -q -- "$target"
      rc=0; out="$(cd docs && kc add --source ace --id ACE-layout --summary directory -- 08-knowledge 2>&1)" || rc=$?
      if [ "$rc" -ne 0 ] || ! git diff --cached --name-only | grep -Fxq docs/08-knowledge/PLAYBOOK.md; then
        echo "  ✗ layout $count: valid nested directory cannot stage and record files ($rc / $out)" >&2; return 1
      fi
      kc discard >/dev/null; git reset -q
      before_index="$(git write-tree)"; before_pending="$(kc status)"
      rm docs/08-knowledge/playbook/a.md
      rc=0; out="$(kc add --source ace --id ACE-layout --summary deleted -- docs/08-knowledge 2>&1)" || rc=$?
      if [ "$rc" -ne 2 ] || [[ "$out" != *"playbook/a.md"* ]] || [ "$(git write-tree)" != "$before_index" ] || [ "$(kc status)" != "$before_pending" ]; then
        echo "  ✗ layout $count: deleted tracked file changed state ($rc / $out)" >&2; return 1
      fi
      git checkout -q -- docs/08-knowledge/playbook/a.md
      # A direct CHANGELOG request must resolve its PLAYBOOK and reject bad Helpful.
      if [ "$style" = legacy ]; then
        printf '%s\n' '- 更新: ACE-0-1 / ACE-0-2 Helpful +1（束ね形）' >>"$target"
      else
        printf '%s\n' '#### カウンター更新' '- Helpful +1: ACE-0-1 / ACE-0-2（束ね形）' >>"$target"
      fi
      before_index="$(git write-tree)"; before_pending="$(kc status)"
      rc=0; out="$(kc add --source ace --id ACE-layout --summary invalid -- "$target" 2>&1)" || rc=$?
      if [ "$rc" -ne 1 ] || [[ "$out" != *"$target:"* ]] || [ "$(git write-tree)" != "$before_index" ] || [ "$(kc status)" != "$before_pending" ]; then
        echo "  ✗ layout $count: direct path bypass or changed state ($rc / $out)" >&2; return 1
      fi
      # Directory requests take the same path, rather than bypassing the gate.
      rc=0; out="$(kc add --source ace --id ACE-layout --summary invalid -- docs/08-knowledge 2>&1)" || rc=$?
      if [ "$rc" -ne 1 ] || [ "$(git write-tree)" != "$before_index" ] || [ "$(kc status)" != "$before_pending" ]; then
        echo "  ✗ layout $count: directory bypass or changed state ($rc / $out)" >&2; return 1
      fi
      rc=0; out="$(cd docs && kc add --source ace --id ACE-layout --summary invalid -- 08-knowledge 2>&1)" || rc=$?
      if [ "$rc" -ne 1 ] || [ "$(git write-tree)" != "$before_index" ] || [ "$(kc status)" != "$before_pending" ]; then
        echo "  ✗ layout $count: nested directory bypass or changed state ($rc / $out)" >&2; return 1
      fi
      echo "  ✓ layout $count: $location / $style explicit paths; direct/directory rejection preserves index and pending"
    done
  done
  [ "$count" -eq 4 ] || return 1
  # A missing related book is uncheckable, never permission to skip the gate.
  rm docs/08-knowledge/PLAYBOOK.md
  rc=0; out="$(kc add --source ace --id ACE-layout --summary orphan -- "$target" 2>&1)" || rc=$?
  if [ "$rc" -ne 2 ] || [[ "$out" != *"PLAYBOOK がありません"* ]] || [ "$(git write-tree)" != "$before_index" ] || [ "$(kc status)" != "$before_pending" ]; then
    echo "  ✗ layout orphan: missing book bypass or changed state ($rc / $out)" >&2; return 1
  fi
  echo '  ✓ layout orphan: missing related book is rc2 and preserves index/pending'
  mkdir docs/empty
  rc=0; out="$(kc add --source ace --id ACE-layout --summary empty -- docs/empty 2>&1)" || rc=$?
  if [ "$rc" -ne 2 ] || [[ "$out" != *"ファイルを取得できません"* ]] || [ "$(git write-tree)" != "$before_index" ] || [ "$(kc status)" != "$before_pending" ]; then
    echo "  ✗ layout empty: zero-file directory was accepted or changed state ($rc / $out)" >&2; return 1
  fi
  echo '  ✓ layout empty: zero-file directory is rc2 and preserves index/pending'
}
