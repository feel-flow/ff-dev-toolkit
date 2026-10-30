#!/usr/bin/env bash
# Sourced by verify.sh; shared by its full run and explicit mutation probe mode.
. "$SCRIPT_DIR/read-boundary.sh"
privacy_canary=ff_lookup_private_canary_2432
privacy_outside="${TMP}/privacy-private"
mkdir -p "$privacy_outside"
printf '## エントリ一覧\n\n### ACE-2432-1: %s\n\n| Category | coding |\n| Status | active |\n\n%s\n' "$privacy_canary" "$privacy_canary" >"$privacy_outside/secret.md"
printf '## エントリ一覧\n\n### OBS-2432: %s\n\n| Status | active |\n\n%s\n' "$privacy_canary" "$privacy_canary" >"$privacy_outside/observation.md"
privacy_n=0
privacy_links=1 # a skipped vector still counts toward the census: the skip line names it
if kl_skip_no_symlink 'K30 の symlink の 8 経路（fifo 以外）とリンクの対照 5 群（範囲内のリンク・記録の論理配置・既定の別名・物理の別名・役割の除外）'; then privacy_links=0; fi
for privacy_case in main category parent ledger archive record pending dangling fifo; do
  if [[ "$privacy_links" -eq 0 && "$privacy_case" != fifo ]]; then privacy_n=$((privacy_n + 1)); continue; fi
  privacy_root="${TMP}/privacy-${privacy_case}"
  mkdir -p "$privacy_root/docs/08-knowledge/playbook/archive"
  printf '## エントリ一覧\n' >"$privacy_root/docs/08-knowledge/PLAYBOOK.md"
  privacy_opts=()
  case "$privacy_case" in
    main) rm "$privacy_root/docs/08-knowledge/PLAYBOOK.md"; ln -s "$privacy_outside/secret.md" "$privacy_root/docs/08-knowledge/PLAYBOOK.md" ;;
    category) ln -s "$privacy_outside/secret.md" "$privacy_root/docs/08-knowledge/playbook/coding.md" ;;
    parent) rm -r "$privacy_root/docs/08-knowledge/playbook"; ln -s "$privacy_outside" "$privacy_root/docs/08-knowledge/playbook" ;;
    ledger) rm "$privacy_root/docs/08-knowledge/PLAYBOOK.md"; ln -s "$privacy_outside/observation.md" "$privacy_root/docs/08-knowledge/OBSERVATIONS.md" ;;
    archive) ln -s "$privacy_outside/secret.md" "$privacy_root/docs/08-knowledge/playbook/archive/coding.md"; privacy_opts=(--include-archived) ;;
    record) ln -s "$privacy_outside/secret.md" "$privacy_root/AGENTS.md" ;;
    pending) ln -s "$privacy_outside/secret.md" "$privacy_root/docs/08-knowledge/PENDING_CANDIDATES.md" ;;
    dangling) rm "$privacy_root/docs/08-knowledge/PLAYBOOK.md"; ln -s "$privacy_outside/missing.md" "$privacy_root/docs/08-knowledge/PLAYBOOK.md" ;;
    fifo) rm "$privacy_root/docs/08-knowledge/PLAYBOOK.md"; mkfifo "$privacy_root/docs/08-knowledge/PLAYBOOK.md" ;;
  esac
  run_lookup "$privacy_root" ${privacy_opts[@]+"${privacy_opts[@]}"} "$privacy_canary"
  if [[ "$RC" -eq 2 && "$OUT" != *"$privacy_canary"* ]]; then
    ok "K30: $privacy_case refuses before external text reaches output"
  else bad "K30: $privacy_case read boundary failed (rc=$RC)"; fi
  privacy_n=$((privacy_n + 1))
  if [[ "$privacy_case" == main ]]; then
    run_lookup "$privacy_root" --playbook "$privacy_root/docs/08-knowledge/PLAYBOOK.md" "$privacy_canary"
    [[ "$RC" -eq 2 && "$OUT" != *"$privacy_canary"* ]] && ok 'K30: in-project explicit main operand creates no external grant' || bad 'K30: in-project operand promoted external target'
    run_lookup "$privacy_root" --playbook "$privacy_root/docs/08-knowledge/PLAYBOOK.md" --resolve-playbook
    [[ "$RC" -eq 2 && "$OUT" == *ACE_PLAYBOOK_STATE=unreadable* ]] && ok 'K30: resolution alone refuses an in-project operand escape' || bad 'K30: resolver promoted an in-project operand escape'
    set +e
    OUT="$(env -u FF_DEV_TOOLKIT_ROOT -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT -u FF_DEV_TOOLKIT_SKILL_FILE ACE_PLAYBOOK_PATH="$privacy_root/docs/08-knowledge/PLAYBOOK.md" bash "$TARGET" --root "$privacy_root" --offline "$privacy_canary" 2>&1)"; RC=$?
    set -e
    [[ "$RC" -eq 2 && "$OUT" != *"$privacy_canary"* ]] && ok 'K30: in-project environment main operand creates no external grant' || bad 'K30: in-project environment operand promoted external target'
  fi
  if [[ "$privacy_case" == ledger ]]; then
    run_lookup "$privacy_root" --ledger "$privacy_root/docs/08-knowledge/OBSERVATIONS.md" "$privacy_canary"
    [[ "$RC" -eq 2 && "$OUT" != *"$privacy_canary"* ]] && ok 'K30: in-project explicit ledger operand creates no external grant' || bad 'K30: in-project ledger operand promoted external target'
  fi
done
[[ "$privacy_n" -eq 9 ]] && ok 'K30: complete privacy input census' || bad 'K30: empty or omitted privacy vectors'
run_lookup "$privacy_root" --playbook "$privacy_outside/secret.md" "$privacy_canary"
[[ "$RC" -eq 0 && "$OUT" == *"$privacy_canary"* ]] && ok 'K30: explicit external material remains usable' || bad 'K30: explicit external control failed'
privacy_internal="${TMP}/privacy-internal"
if [[ "$privacy_links" -eq 1 ]]; then
  mkdir -p "$privacy_internal/docs/08-knowledge"
  cp "$privacy_outside/secret.md" "$privacy_internal/docs/08-knowledge/actual.md"
  ln -s actual.md "$privacy_internal/docs/08-knowledge/PLAYBOOK.md"
  run_lookup "$privacy_internal" "$privacy_canary"
  [[ "$RC" -eq 0 && "$OUT" == *"$privacy_canary"* ]] && ok 'K30: safe in-project link remains usable' || bad 'K30: internal link control failed'
fi
mkdir "$privacy_internal"$'\n'
run_lookup "$privacy_internal"$'\n' "$privacy_canary"
[[ "$RC" -eq 2 && "$OUT" != *"$privacy_canary"* ]] && ok 'K30: explicit root controls refused without selecting its stripped sibling' || bad 'K30: explicit root stripped a control byte'
if [[ "$privacy_links" -eq 1 ]]; then
  privacy_recorded="$TMP/privacy-recorded"
  mkdir -p "$privacy_recorded/docs/08-knowledge/playbook" "$privacy_recorded/docs/real/playbook"
  printf 'Playbook: docs/08-knowledge/PLAYBOOK.md\n' >"$privacy_recorded/AGENTS.md"
  printf '## エントリ一覧\n' >"$privacy_recorded/docs/real/PLAYBOOK.md"
  ln -s ../real/PLAYBOOK.md "$privacy_recorded/docs/08-knowledge/PLAYBOOK.md"
  printf '### ACE-2432-1: %s logical-category\n\n| Category | coding |\n| Status | active |\n\n' "$privacy_canary" >"$privacy_recorded/docs/08-knowledge/playbook/coding.md"
  printf '### ACE-2432-2: %s physical-neighbor\n\n| Category | coding |\n| Status | active |\n\n' "$privacy_canary" >"$privacy_recorded/docs/real/playbook/coding.md"
  run_lookup "$privacy_recorded" --resolve-playbook
  [[ "$RC" -eq 0 && "$OUT" == *ACE_PLAYBOOK_REL=docs/08-knowledge/PLAYBOOK.md* ]] && ok 'K30: recorded internal leaf retains logical placement' || bad 'K30: recorded leaf canonicalization changed placement'
  run_lookup "$privacy_recorded" "$privacy_canary"
  [[ "$RC" -eq 0 && "$OUT" == *logical-category* && "$OUT" != *physical-neighbor* ]] && ok 'K30: recorded internal leaf uses logical categories without adjacent physical store' || bad 'K30: recorded leaf changed category scope'
  privacy_alias="$TMP/privacy-default-alias"
  mkdir -p "$privacy_alias/docs/08-knowledge"
  printf '## エントリ一覧\n' >"$privacy_alias/docs/08-knowledge/PLAYBOOK.md"
  ln -s 08-knowledge/PLAYBOOK.md "$privacy_alias/docs/PLAYBOOK.md"
  printf 'Playbook: docs/PLAYBOOK.md\n' >"$privacy_alias/AGENTS.md"
  run_lookup "$privacy_alias" --resolve-playbook
  [[ "$RC" -eq 0 && "$OUT" == *ACE_PLAYBOOK_REL=docs/08-knowledge/PLAYBOOK.md* ]] && ok 'K30: recorded alias matches default by authorized physical identity' || bad 'K30: default alias identity mismatch'
fi
privacy_alias="$TMP/privacy-duplicate-alias"
mkdir -p "$privacy_alias/custom" "$privacy_alias/alias"
printf '## エントリ一覧\n' >"$privacy_alias/custom/PLAYBOOK.md"
printf 'custom/PLAYBOOK.md alias/PLAYBOOK.md\n' >"$privacy_alias/AGENTS.md"
if [[ "$privacy_links" -eq 1 ]]; then
  ln -s ../custom/PLAYBOOK.md "$privacy_alias/alias/PLAYBOOK.md"
  run_lookup "$privacy_alias" --resolve-playbook
  [[ "$RC" -eq 0 && "$OUT" == *ACE_PLAYBOOK_REL=custom/PLAYBOOK.md* ]] && ok 'K30: physical aliases are one recorded candidate with first logical layout' || bad 'K30: duplicate aliases became ambiguous'
  rm "$privacy_alias/alias/PLAYBOOK.md"
fi
cp "$privacy_alias/custom/PLAYBOOK.md" "$privacy_alias/alias/PLAYBOOK.md"
run_lookup "$privacy_alias" --resolve-playbook
[[ "$RC" -eq 2 && "$OUT" == *ACE_PLAYBOOK_STATE=ambiguous* ]] && ok 'K30: distinct physical candidates remain ambiguous despite identical content' || bad 'K30: distinct physical stores were merged'
if [[ "$privacy_links" -eq 1 ]]; then
  for privacy_role in oss node_modules .git plugin; do
    privacy_alias="$TMP/privacy-role-$privacy_role"
    privacy_role_dir="$privacy_alias/$privacy_role/books"
    if [[ "$privacy_role" == plugin ]]; then
      privacy_role_dir="$privacy_alias/plugin/docs-template/books"
      mkdir -p "$privacy_alias/plugin/.claude-plugin"
      printf '{}' >"$privacy_alias/plugin/.claude-plugin/plugin.json"
    fi
    mkdir -p "$privacy_alias/docs/08-knowledge" "$privacy_role_dir"
    printf '## エントリ一覧\n' >"$privacy_alias/docs/08-knowledge/PLAYBOOK.md"
    printf '## エントリ一覧\n' >"$privacy_role_dir/PLAYBOOK.md"
    ln -s "$privacy_role_dir/PLAYBOOK.md" "$privacy_alias/docs/PLAYBOOK.md"
    printf 'Playbook: docs/PLAYBOOK.md\n' >"$privacy_alias/AGENTS.md"
    run_lookup "$privacy_alias" --resolve-playbook
    [[ "$RC" -eq 0 && "$OUT" == *ACE_PLAYBOOK_SOURCE=default* ]] && ok "K30: physical $privacy_role role remains excluded behind a local alias" || bad "K30: physical $privacy_role exclusion lost"
    rm "$privacy_role_dir/PLAYBOOK.md"
    ln -s "$privacy_alias/docs/08-knowledge/PLAYBOOK.md" "$privacy_role_dir/PLAYBOOK.md"
    printf 'Playbook: %s/PLAYBOOK.md\n' "${privacy_role_dir#"$privacy_alias"/}" >"$privacy_alias/AGENTS.md"
    run_lookup "$privacy_alias" --resolve-playbook
    [[ "$RC" -eq 0 && "$OUT" == *ACE_PLAYBOOK_SOURCE=default* ]] && ok "K30: logical $privacy_role role remains excluded when target is ordinary" || bad "K30: logical $privacy_role exclusion lost"
  done
fi
