#!/usr/bin/env bash
# Issue #1011 の文書から抽出した plugin root guard を fixture で実行する helper。

make_guard_root() {
  local root="$1" missing="${2:-}" resource
  mkdir -p "$root/scripts" "$root/.claude-plugin"
  printf '%s\n' '{' '  "name": "ff-dev-toolkit",' '  "version": "fixture"' '}' \
    >"$root/.claude-plugin/plugin.json"
  for resource in setup-multi-agent.sh multi-agent.sh multi-review.sh check-closing-keywords.sh \
    check-merge-freshness.sh update-version-claim.sh check-version-claims.sh; do
    if [ "$resource" != "$missing" ]; then
      printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$root/scripts/$resource"
      chmod +x "$root/scripts/$resource"
    fi
  done
}

run_guard_case() {
  local label="$1" root="$2" expected="$3" output="$4" cwd="${5:-}" rc=0
  if [ "$root" = __UNSET__ ]; then
    (unset FF_DEV_TOOLKIT_ROOT FF_DEV_TOOLKIT_ROOT_SOURCE
     unset CLAUDE_PLUGIN_ROOT GROK_PLUGIN_ROOT FF_DEV_TOOLKIT_SKILL_FILE
     bash "$ROOT_GUARD_SCRIPT") >"$output" 2>&1 || rc=$?
  elif [ -n "$cwd" ]; then
    (cd "$cwd" && unset FF_DEV_TOOLKIT_ROOT FF_DEV_TOOLKIT_ROOT_SOURCE FF_DEV_TOOLKIT_SKILL_FILE GROK_PLUGIN_ROOT
     CLAUDE_PLUGIN_ROOT="$root" \
       bash "$ROOT_GUARD_SCRIPT") \
      >"$output" 2>&1 || rc=$?
  else
    (unset FF_DEV_TOOLKIT_ROOT FF_DEV_TOOLKIT_ROOT_SOURCE FF_DEV_TOOLKIT_SKILL_FILE GROK_PLUGIN_ROOT
     CLAUDE_PLUGIN_ROOT="$root" \
       bash "$ROOT_GUARD_SCRIPT") >"$output" 2>&1 || rc=$?
  fi
  if [ "$rc" -eq "$expected" ]; then
    if [ "$expected" -eq 2 ] \
      && ! grep -qF 'ff-dev-toolkitのhandoffを再構成してください' "$output"; then
      bad "$label — exit 2 だがhandoff再構成の案内が無い"
    else
      ok "$label (exit $rc)"
    fi
  else
    bad "$label — exit ${rc}、期待 ${expected}"
    sed -n '1,120p' "$output" >&2 || true
  fi
}

run_root_guard_cases() {
  unset GROK_PLUGIN_ROOT
  local GUARD_ROOT="$TMP_ROOT/root-guard"
  local valid_root relative_root missing_resource missing_root
  local nonexec_root empty_root unreadable_root directory_root dangling_root
  local fallback_root fallback_marker fixed_missing_root fallback_rc skill_file source_rc
  local missing_skill_root mismatch_root mismatch_marker invalid_skill_case=0 recovery_rc
  local target_repo other_repo outside_dir target_rc
  local preserve_rc symlink_skill_root symlink_resource_root symlink_scripts_root
  local invalid_identity_root grok_mismatch_root

  echo
  echo "== plugin root guard の fixture 実行 =="
  valid_root="$GUARD_ROOT/valid root"
  make_guard_root "$valid_root"
  run_guard_case "必須resourceが実在すれば通過" "$valid_root" 0 "$GUARD_ROOT/valid.log"
  run_guard_case "root未設定を案内付きで拒否" __UNSET__ 2 "$GUARD_ROOT/unset.log"
  fallback_rc=0
  (unset CLAUDE_PLUGIN_ROOT GROK_PLUGIN_ROOT FF_DEV_TOOLKIT_SKILL_FILE FF_DEV_TOOLKIT_ROOT_SOURCE
   FF_DEV_TOOLKIT_ROOT="$valid_root" bash "$ROOT_GUARD_SCRIPT") \
    >"$GUARD_ROOT/source-missing.log" 2>&1 || fallback_rc=$?
  if [ "$fallback_rc" -eq 2 ]; then
    ok "host handoffも明示sourceもない既存rootを拒否"
  else
    bad "読み込み元不明の既存rootを受理した (rc=${fallback_rc})"
  fi
  source_rc=0
  if FF_DEV_TOOLKIT_GUARD="$ROOT_GUARD_SCRIPT" bash -c '
      set -u
      unset FF_DEV_TOOLKIT_ROOT FF_DEV_TOOLKIT_ROOT_SOURCE
      unset CLAUDE_PLUGIN_ROOT GROK_PLUGIN_ROOT FF_DEV_TOOLKIT_SKILL_FILE
      . "$FF_DEV_TOOLKIT_GUARD"
      guard_rc=$?
      printf "after-source:%s\n" "$guard_rc"
      exit 0
    ' >"$GUARD_ROOT/source.log" 2>&1; then
    source_rc=0
  else
    source_rc=$?
  fi
  if [ "$source_rc" -eq 0 ] && grep -qF 'after-source:2' "$GUARD_ROOT/source.log"; then
    ok "guard失敗をsourceしても対話shell相当の呼び出し元を終了しない"
  else
    bad "guard失敗のexit 2がsource元shellまで終了する (rc=${source_rc})"
  fi
  source_rc=0
  if FF_DEV_TOOLKIT_GUARD="$ROOT_GUARD_SCRIPT" bash -c '
      set -eu
      unset FF_DEV_TOOLKIT_ROOT FF_DEV_TOOLKIT_ROOT_SOURCE
      unset CLAUDE_PLUGIN_ROOT GROK_PLUGIN_ROOT FF_DEV_TOOLKIT_SKILL_FILE
      set +e
      . "$FF_DEV_TOOLKIT_GUARD"
      guard_rc=$?
      set -e
      printf "after-errexit-source:%s\n" "$guard_rc"
    ' >"$GUARD_ROOT/source-errexit.log" 2>&1; then
    source_rc=0
  else
    source_rc=$?
  fi
  if [ "$source_rc" -eq 0 ] \
    && grep -qF 'after-errexit-source:2' "$GUARD_ROOT/source-errexit.log"; then
    ok "set -e下でもerrexitを一時解除してsourceの非0を捕捉できる"
  else
    bad "set -e下のsource失敗をerrexit一時解除で捕捉できない (rc=${source_rc})"
  fi

  fallback_rc=0
  (unset FF_DEV_TOOLKIT_ROOT FF_DEV_TOOLKIT_ROOT_SOURCE FF_DEV_TOOLKIT_SKILL_FILE GROK_PLUGIN_ROOT
   CLAUDE_PLUGIN_ROOT="$valid_root" bash "$ROOT_GUARD_SCRIPT") \
    >"$GUARD_ROOT/claude-root.log" 2>&1 || fallback_rc=$?
  if [ "$fallback_rc" -eq 0 ]; then
    ok "CLAUDE_PLUGIN_ROOTから未設定rootを固定できる"
  else
    bad "CLAUDE_PLUGIN_ROOTから未設定rootを固定できない (rc=${fallback_rc})"
  fi

  fallback_rc=0
  (unset FF_DEV_TOOLKIT_ROOT FF_DEV_TOOLKIT_ROOT_SOURCE FF_DEV_TOOLKIT_SKILL_FILE CLAUDE_PLUGIN_ROOT
   GROK_PLUGIN_ROOT="$valid_root" bash "$ROOT_GUARD_SCRIPT") \
    >"$GUARD_ROOT/grok-root.log" 2>&1 || fallback_rc=$?
  if [ "$fallback_rc" -eq 0 ]; then
    ok "GROK_PLUGIN_ROOTから未設定rootを固定できる"
  else
    bad "GROK_PLUGIN_ROOTから未設定rootを固定できない (rc=${fallback_rc})"
  fi

  fallback_rc=0
  (unset FF_DEV_TOOLKIT_ROOT FF_DEV_TOOLKIT_ROOT_SOURCE FF_DEV_TOOLKIT_SKILL_FILE
   CLAUDE_PLUGIN_ROOT="$valid_root" GROK_PLUGIN_ROOT="$valid_root/" \
     bash "$ROOT_GUARD_SCRIPT") \
    >"$GUARD_ROOT/host-same.log" 2>&1 || fallback_rc=$?
  if [ "$fallback_rc" -eq 0 ]; then
    ok "同じ実体のCLAUDE_PLUGIN_ROOTとGROK_PLUGIN_ROOTを受理"
  else
    bad "同じ実体のhost plugin rootを拒否した (rc=${fallback_rc})"
  fi

  fallback_rc=0
  (unset FF_DEV_TOOLKIT_ROOT FF_DEV_TOOLKIT_ROOT_SOURCE FF_DEV_TOOLKIT_SKILL_FILE CLAUDE_PLUGIN_ROOT
   GROK_PLUGIN_ROOT=relative bash "$ROOT_GUARD_SCRIPT") \
    >"$GUARD_ROOT/grok-relative.log" 2>&1 || fallback_rc=$?
  if [ "$fallback_rc" -eq 2 ] \
    && grep -qF 'Grok plugin rootが絶対pathではありません' "$GUARD_ROOT/grok-relative.log"; then
    ok "GROK_PLUGIN_ROOTの相対pathを案内付きで拒否"
  else
    bad "GROK_PLUGIN_ROOTの相対pathを拒否できない (rc=${fallback_rc})"
    sed -n '1,80p' "$GUARD_ROOT/grok-relative.log" >&2 || true
  fi

  grok_mismatch_root="$GUARD_ROOT/grok mismatch root"
  make_guard_root "$grok_mismatch_root"
  fallback_rc=0
  (unset FF_DEV_TOOLKIT_ROOT FF_DEV_TOOLKIT_ROOT_SOURCE FF_DEV_TOOLKIT_SKILL_FILE
   CLAUDE_PLUGIN_ROOT="$valid_root" GROK_PLUGIN_ROOT="$grok_mismatch_root" \
     bash "$ROOT_GUARD_SCRIPT") \
    >"$GUARD_ROOT/host-claude-grok-mismatch.log" 2>&1 || fallback_rc=$?
  if [ "$fallback_rc" -eq 2 ] \
    && grep -qF 'hostのplugin rootが一致しません' "$GUARD_ROOT/host-claude-grok-mismatch.log"; then
    ok "CLAUDE_PLUGIN_ROOTとGROK_PLUGIN_ROOTの実体不一致を拒否"
  else
    bad "host plugin rootの実体不一致を拒否できない (rc=${fallback_rc})"
    sed -n '1,80p' "$GUARD_ROOT/host-claude-grok-mismatch.log" >&2 || true
  fi

  mkdir -p "$valid_root/skills/group/multi-review"
  printf '%s\n' '# nested fixture skill' \
    >"$valid_root/skills/group/multi-review/SKILL.md"
  for skill_file in \
    'relative/skills/multi-review/SKILL.md' \
    "$GUARD_ROOT/not-under-skills/SKILL.md" \
    "$GUARD_ROOT/missing/skills/multi-review/SKILL.md" \
    "$valid_root/skills/group/multi-review/SKILL.md"; do
    invalid_skill_case=$((invalid_skill_case + 1))
    fallback_rc=0
    (unset FF_DEV_TOOLKIT_ROOT FF_DEV_TOOLKIT_ROOT_SOURCE CLAUDE_PLUGIN_ROOT GROK_PLUGIN_ROOT
     FF_DEV_TOOLKIT_SKILL_FILE="$skill_file" bash "$ROOT_GUARD_SCRIPT") \
      >"$GUARD_ROOT/invalid-skill-$invalid_skill_case.log" 2>&1 || fallback_rc=$?
    if [ "$fallback_rc" -eq 2 ] \
      && grep -qF 'ff-dev-toolkitのhandoffを再構成してください' \
        "$GUARD_ROOT/invalid-skill-$invalid_skill_case.log"; then
      ok "不正・不存在のSKILL.md handoffを案内付きで拒否: $skill_file"
    else
      bad "不正・不存在のSKILL.md handoffを受理した: $skill_file (rc=${fallback_rc})"
    fi
  done

  mkdir -p "$valid_root/skills/multi-review"
  skill_file="$valid_root/skills/multi-review/SKILL.md"
  printf '%s\n' '# fixture skill' >"$skill_file"
  # skill契約に記載したhost producerの代入を実値へ置換した場合の成功経路。
  fallback_rc=0
  (unset FF_DEV_TOOLKIT_ROOT FF_DEV_TOOLKIT_ROOT_SOURCE CLAUDE_PLUGIN_ROOT GROK_PLUGIN_ROOT
   FF_DEV_TOOLKIT_SKILL_FILE="$skill_file" bash "$ROOT_GUARD_SCRIPT") \
    >"$GUARD_ROOT/skill-file.log" 2>&1 || fallback_rc=$?
  if [ "$fallback_rc" -eq 0 ]; then
    ok "skill loaderが返した絶対SKILL.mdのhost代入からrootを固定できる"
  else
    bad "絶対SKILL.md pathからrootを固定できない (rc=${fallback_rc})"
  fi

  target_repo="$GUARD_ROOT/consumer repo"
  other_repo="$GUARD_ROOT/other repo"
  outside_dir="$GUARD_ROOT/outside"
  mkdir -p "$target_repo/subdir" "$other_repo" "$outside_dir"
  git -C "$target_repo" init -q
  git -C "$other_repo" init -q

  target_rc=0
  (cd "$target_repo" \
   && CLAUDE_PLUGIN_ROOT="$valid_root" FF_DEV_TOOLKIT_PROJECT_ROOT="$target_repo" \
     FF_GUARD_SCRIPT="$ROOT_GUARD_SCRIPT" bash -c \
       '. "$FF_GUARD_SCRIPT" && ff_require_consumer_root') \
    >"$GUARD_ROOT/consumer-root-valid.log" 2>&1 || target_rc=$?
  if [ "$target_rc" -eq 0 ]; then
    ok "hostのtask workspace・物理CWD・git rootが一致すればconsumer rootを受理"
  else
    bad "一致するconsumer rootを拒否した (rc=${target_rc})"
  fi

  target_rc=0
  (cd "$target_repo" \
   && unset FF_DEV_TOOLKIT_PROJECT_ROOT \
   && CLAUDE_PLUGIN_ROOT="$valid_root" FF_GUARD_SCRIPT="$ROOT_GUARD_SCRIPT" \
     bash -c '. "$FF_GUARD_SCRIPT" && ff_require_consumer_root') \
    >"$GUARD_ROOT/consumer-root-unset.log" 2>&1 || target_rc=$?
  if [ "$target_rc" -eq 2 ]; then
    if grep -qF 'AI hostからFF_DEV_TOOLKIT_PROJECT_ROOTを渡して' \
        "$GUARD_ROOT/consumer-root-unset.log"; then
      ok "consumer root handoff未設定を原因別案内付きstatus 2で拒否"
    else
      bad "consumer root handoff未設定の診断が再実行だけを促している"
    fi
  else
    bad "consumer root handoff未設定を受理した (rc=${target_rc})"
  fi

  target_rc=0
  (cd "$target_repo/subdir" \
   && CLAUDE_PLUGIN_ROOT="$valid_root" FF_DEV_TOOLKIT_PROJECT_ROOT="$target_repo" \
     FF_GUARD_SCRIPT="$ROOT_GUARD_SCRIPT" bash -c \
       '. "$FF_GUARD_SCRIPT" && ff_require_consumer_root') \
    >"$GUARD_ROOT/consumer-root-subdir.log" 2>&1 || target_rc=$?
  if [ "$target_rc" -eq 2 ]; then
    ok "task workspaceのsubdirectoryからのreview起動をstatus 2で拒否"
  else
    bad "task workspaceのsubdirectoryをrepository rootとして受理した (rc=${target_rc})"
  fi

  preserve_rc=0
  (cd "$target_repo/subdir" \
   && CLAUDE_PLUGIN_ROOT="$valid_root" FF_DEV_TOOLKIT_PROJECT_ROOT="$target_repo" \
     FF_GUARD_SCRIPT="$ROOT_GUARD_SCRIPT" bash -c '
       . "$FF_GUARD_SCRIPT" || exit $?
       fixed_root="$FF_DEV_TOOLKIT_ROOT"
       ff_require_consumer_root
       consumer_rc=$?
       [ "$consumer_rc" -eq 2 ] \
         && [ "$FF_DEV_TOOLKIT_ROOT" = "$fixed_root" ] \
         && [ "$FF_DEV_TOOLKIT_ROOT_SOURCE" = host ]
     ') >"$GUARD_ROOT/consumer-root-preserved.log" 2>&1 || preserve_rc=$?
  if [ "$preserve_rc" -eq 0 ]; then
    ok "consumer root不一致でも検証済みtoolkit rootを破棄しない"
  else
    bad "consumer root失敗が検証済みtoolkit rootを巻き添えで破棄した"
  fi

  target_rc=0
  (cd "$other_repo" \
   && CLAUDE_PLUGIN_ROOT="$valid_root" FF_DEV_TOOLKIT_PROJECT_ROOT="$target_repo" \
     FF_GUARD_SCRIPT="$ROOT_GUARD_SCRIPT" bash -c \
       '. "$FF_GUARD_SCRIPT" && ff_require_consumer_root') \
    >"$GUARD_ROOT/consumer-root-mismatch.log" 2>&1 || target_rc=$?
  if [ "$target_rc" -eq 2 ]; then
    ok "別repositoryからのreview起動をstatus 2で拒否"
  else
    bad "別repositoryをhostのtask workspaceとして受理した (rc=${target_rc})"
  fi

  target_rc=0
  (cd "$outside_dir" \
   && CLAUDE_PLUGIN_ROOT="$valid_root" FF_DEV_TOOLKIT_PROJECT_ROOT="$outside_dir" \
     FF_GUARD_SCRIPT="$ROOT_GUARD_SCRIPT" bash -c \
       '. "$FF_GUARD_SCRIPT" && ff_require_consumer_root') \
    >"$GUARD_ROOT/consumer-root-outside.log" 2>&1 || target_rc=$?
  if [ "$target_rc" -eq 2 ]; then
    ok "repository外からのreview起動をstatus 2で拒否"
  else
    bad "repository外をconsumer rootとして受理した (rc=${target_rc})"
  fi
  relative_root="$GUARD_ROOT/relative"
  make_guard_root "$relative_root"
  run_guard_case "resourceが実在しても相対rootは案内付きで拒否" \
    relative 2 "$GUARD_ROOT/relative.log" "$GUARD_ROOT"
  for missing_resource in setup-multi-agent.sh multi-agent.sh multi-review.sh check-closing-keywords.sh \
    check-merge-freshness.sh update-version-claim.sh check-version-claims.sh; do
    missing_root="$GUARD_ROOT/missing-${missing_resource%.sh}"
    make_guard_root "$missing_root" "$missing_resource"
    run_guard_case "${missing_resource}欠落を案内付きで拒否" \
      "$missing_root" 2 "$GUARD_ROOT/missing-${missing_resource%.sh}.log"
  done

  missing_skill_root="$GUARD_ROOT/skill-missing-resource"
  make_guard_root "$missing_skill_root" multi-review.sh
  mkdir -p "$missing_skill_root/skills/multi-review"
  skill_file="$missing_skill_root/skills/multi-review/SKILL.md"
  printf '%s\n' '# fixture skill' >"$skill_file"
  fallback_rc=0
  (unset FF_DEV_TOOLKIT_ROOT FF_DEV_TOOLKIT_ROOT_SOURCE CLAUDE_PLUGIN_ROOT GROK_PLUGIN_ROOT
   FF_DEV_TOOLKIT_SKILL_FILE="$skill_file" bash "$ROOT_GUARD_SCRIPT") \
    >"$GUARD_ROOT/skill-missing-resource.log" 2>&1 || fallback_rc=$?
  if [ "$fallback_rc" -eq 2 ]; then
    ok "SKILL.mdから解決したrootのresource欠落を拒否"
  else
    bad "SKILL.mdから解決したrootのresource欠落を受理した (rc=${fallback_rc})"
  fi
  recovery_rc=0
  FF_GUARD_SCRIPT="$ROOT_GUARD_SCRIPT" FF_BAD_ROOT="$missing_skill_root" \
    FF_GOOD_ROOT="$valid_root" bash -c '
      unset FF_DEV_TOOLKIT_ROOT FF_DEV_TOOLKIT_ROOT_SOURCE FF_DEV_TOOLKIT_SKILL_FILE
      CLAUDE_PLUGIN_ROOT="$FF_BAD_ROOT"
      . "$FF_GUARD_SCRIPT"
      first_rc=$?
      if [ -n "${FF_DEV_TOOLKIT_ROOT+x}" ]; then
        printf "leftover=%s\n" "$FF_DEV_TOOLKIT_ROOT"
        exit 1
      fi
      CLAUDE_PLUGIN_ROOT="$FF_GOOD_ROOT"
      . "$FF_GUARD_SCRIPT"
      second_rc=$?
      printf "first=%s second=%s final=%s\n" "$first_rc" "$second_rc" "$FF_DEV_TOOLKIT_ROOT"
      [ "$first_rc" -eq 2 ] && [ "$second_rc" -eq 0 ]
    ' >"$GUARD_ROOT/source-recovery.log" 2>&1 || recovery_rc=$?
  if [ "$recovery_rc" -eq 0 ] \
    && grep -qF "first=2 second=0 final=$(cd "$valid_root" && pwd -P)" \
      "$GUARD_ROOT/source-recovery.log"; then
    ok "resource欠落で失敗したhost rootをsource元に残さず再呼び出しで復旧"
  else
    bad "失敗候補がsource元に残り正しいhost rootで復旧できない"
    sed -n '1,120p' "$GUARD_ROOT/source-recovery.log" >&2 || true
  fi
  nonexec_root="$GUARD_ROOT/nonexec"
  make_guard_root "$nonexec_root"
  chmod -x "$nonexec_root/scripts/multi-review.sh"
  run_guard_case "bashで呼ぶresourceは非実行でも読み取り可能なら受理" \
    "$nonexec_root" 0 "$GUARD_ROOT/nonexec.log"
  empty_root="$GUARD_ROOT/empty"
  make_guard_root "$empty_root"
  : >"$empty_root/scripts/multi-agent.sh"
  chmod +x "$empty_root/scripts/multi-agent.sh"
  run_guard_case "実行可能でも0バイトのresourceを案内付きで拒否" \
    "$empty_root" 2 "$GUARD_ROOT/empty.log"
  unreadable_root="$GUARD_ROOT/unreadable"
  make_guard_root "$unreadable_root"
  chmod 111 "$unreadable_root/scripts/multi-review.sh"
  if [ ! -r "$unreadable_root/scripts/multi-review.sh" ]; then
    run_guard_case "実行可能でも読み取り不能のresourceを案内付きで拒否" \
      "$unreadable_root" 2 "$GUARD_ROOT/unreadable.log"
  else
    echo "○ skip: 実行ユーザーが権限bitを超えて読めるためunreadable resource fixtureを作れません"
  fi
  directory_root="$GUARD_ROOT/directory"
  make_guard_root "$directory_root" multi-agent.sh
  mkdir "$directory_root/scripts/multi-agent.sh"
  run_guard_case "resource名のdirectoryを案内付きで拒否" \
    "$directory_root" 2 "$GUARD_ROOT/directory.log"
  dangling_root="$GUARD_ROOT/dangling"
  make_guard_root "$dangling_root" setup-multi-agent.sh
  ln -s "$dangling_root/scripts/not-found.sh" "$dangling_root/scripts/setup-multi-agent.sh"
  run_guard_case "dangling symlink resourceを案内付きで拒否" \
    "$dangling_root" 2 "$GUARD_ROOT/dangling.log"

  symlink_resource_root="$GUARD_ROOT/symlink-resource"
  make_guard_root "$symlink_resource_root" multi-review.sh
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' \
    >"$symlink_resource_root/scripts/multi-review-real.sh"
  chmod +x "$symlink_resource_root/scripts/multi-review-real.sh"
  ln -s "$symlink_resource_root/scripts/multi-review-real.sh" \
    "$symlink_resource_root/scripts/multi-review.sh"
  run_guard_case "実在先を持つresource symlinkも案内付きで拒否" \
    "$symlink_resource_root" 2 "$GUARD_ROOT/symlink-resource.log"

  symlink_scripts_root="$GUARD_ROOT/symlink-scripts"
  make_guard_root "$symlink_scripts_root"
  mv "$symlink_scripts_root/scripts" "$symlink_scripts_root/scripts-real"
  ln -s "$symlink_scripts_root/scripts-real" "$symlink_scripts_root/scripts"
  run_guard_case "scripts directory symlinkを案内付きで拒否" \
    "$symlink_scripts_root" 2 "$GUARD_ROOT/symlink-scripts.log"

  invalid_identity_root="$GUARD_ROOT/invalid-identity"
  make_guard_root "$invalid_identity_root"
  printf '%s\n' '{"name":"another-plugin"}' \
    >"$invalid_identity_root/.claude-plugin/plugin.json"
  run_guard_case "bundled manifestの先頭name markerが異なるrootを案内付きで拒否" \
    "$invalid_identity_root" 2 "$GUARD_ROOT/invalid-identity.log"

  invalid_identity_root="$GUARD_ROOT/nested-name-marker"
  make_guard_root "$invalid_identity_root"
  printf '%s\n' '{' '  "name": "another-plugin",' \
    '  "nested": {"name": "ff-dev-toolkit"}' '}' \
    >"$invalid_identity_root/.claude-plugin/plugin.json"
  run_guard_case "nested fieldだけがff-dev-toolkit名のmanifestを拒否" \
    "$invalid_identity_root" 2 "$GUARD_ROOT/nested-name-marker.log"

  symlink_skill_root="$GUARD_ROOT/symlink-skill"
  make_guard_root "$symlink_skill_root"
  mkdir -p "$symlink_skill_root/skills/multi-review"
  printf '%s\n' '# fixture skill' >"$symlink_skill_root/skills/multi-review/real.md"
  ln -s "$symlink_skill_root/skills/multi-review/real.md" \
    "$symlink_skill_root/skills/multi-review/SKILL.md"
  fallback_rc=0
  (unset FF_DEV_TOOLKIT_ROOT FF_DEV_TOOLKIT_ROOT_SOURCE CLAUDE_PLUGIN_ROOT GROK_PLUGIN_ROOT
   FF_DEV_TOOLKIT_SKILL_FILE="$symlink_skill_root/skills/multi-review/SKILL.md" \
     bash "$ROOT_GUARD_SCRIPT") >"$GUARD_ROOT/symlink-skill.log" 2>&1 || fallback_rc=$?
  if [ "$fallback_rc" -eq 2 ]; then
    ok "SKILL.md symlinkをhost handoffとして拒否"
  else
    bad "SKILL.md symlinkをhost handoffとして受理した (rc=${fallback_rc})"
  fi

  # hostが示すrootと既存rootの不一致では、resource検査より前に固定契約を拒否する。
  fallback_root="$GUARD_ROOT/newer-alternate"
  make_guard_root "$fallback_root"
  fallback_marker="$GUARD_ROOT/alternate-ran"
  printf '%s\n' '#!/usr/bin/env bash' "touch \"$fallback_marker\"" \
    >"$fallback_root/scripts/multi-review.sh"
  chmod +x "$fallback_root/scripts/multi-review.sh"
  fixed_missing_root="$GUARD_ROOT/fixed-missing"
  make_guard_root "$fixed_missing_root" multi-review.sh
  fallback_rc=0
  CLAUDE_PLUGIN_ROOT="$fallback_root" \
    FF_DEV_TOOLKIT_ROOT="$fixed_missing_root" \
    bash "$ROOT_GUARD_SCRIPT" >"$GUARD_ROOT/fallback.log" 2>&1 || fallback_rc=$?
  if [ "$fallback_rc" -eq 2 ] && [ ! -e "$fallback_marker" ]; then
    ok "host rootと既存rootが不一致なら別候補へ切り替えずexit 2"
  else
    bad "host rootと既存rootの不一致時に別候補へ切り替えた (rc=${fallback_rc})"
  fi

  # resource欠落分岐そのものへ到達させる。専用HOMEの既知cache形に完全な別候補を
  # 置いても、hostが渡したrootだけを検査し、cacheへ切り替えない。
  fallback_root="$GUARD_ROOT/cache-home/.codex/plugins/cache/marketplace/ff-dev-toolkit/9.9.9"
  make_guard_root "$fallback_root"
  fixed_missing_root="$GUARD_ROOT/fixed-resource-missing"
  make_guard_root "$fixed_missing_root" multi-review.sh
  fallback_rc=0
  (unset FF_DEV_TOOLKIT_ROOT FF_DEV_TOOLKIT_ROOT_SOURCE FF_DEV_TOOLKIT_SKILL_FILE
   HOME="$GUARD_ROOT/cache-home" CLAUDE_PLUGIN_ROOT="$fixed_missing_root" \
     bash "$ROOT_GUARD_SCRIPT") \
    >"$GUARD_ROOT/resource-no-fallback.log" 2>&1 || fallback_rc=$?
  if [ "$fallback_rc" -eq 2 ] \
    && grep -qF 'resourceを解決できません' "$GUARD_ROOT/resource-no-fallback.log"; then
    ok "resource欠落時に完全なcache候補があっても探索せずexit 2"
  else
    bad "resource欠落時に固定root以外へ切り替えた (rc=${fallback_rc})"
  fi

  mismatch_root="$GUARD_ROOT/host-mismatch"
  make_guard_root "$mismatch_root"
  mismatch_marker="$GUARD_ROOT/mismatch-ran"
  printf '%s\n' '#!/usr/bin/env bash' "touch \"$mismatch_marker\"" \
    >"$mismatch_root/scripts/multi-review.sh"
  chmod +x "$mismatch_root/scripts/multi-review.sh"
  fallback_rc=0
  CLAUDE_PLUGIN_ROOT="$valid_root" FF_DEV_TOOLKIT_ROOT="$mismatch_root" \
    bash "$ROOT_GUARD_SCRIPT" >"$GUARD_ROOT/host-mismatch.log" 2>&1 || fallback_rc=$?
  if [ "$fallback_rc" -eq 2 ] && [ ! -e "$mismatch_marker" ]; then
    ok "既存rootがhost実体と不一致なら実行せず拒否"
  else
    bad "既存rootとhost実体の不一致を受理した (rc=${fallback_rc})"
  fi
  fallback_rc=0
  FF_GUARD_SCRIPT="$ROOT_GUARD_SCRIPT" FF_HOST_ROOT="$valid_root" \
    FF_STALE_ROOT="$mismatch_root" FF_STALE_MARKER="$mismatch_marker" bash -c '
      set +e
      CLAUDE_PLUGIN_ROOT="$FF_HOST_ROOT"
      FF_DEV_TOOLKIT_ROOT="$FF_STALE_ROOT"
      FF_DEV_TOOLKIT_ROOT_SOURCE=sidecar
      export CLAUDE_PLUGIN_ROOT FF_DEV_TOOLKIT_ROOT FF_DEV_TOOLKIT_ROOT_SOURCE
      . "$FF_GUARD_SCRIPT"
      guard_rc=$?
      if [ -n "${FF_DEV_TOOLKIT_ROOT+x}" ] \
        || [ -n "${FF_DEV_TOOLKIT_ROOT_SOURCE+x}" ]; then
        exit 1
      fi
      [ "$guard_rc" -eq 2 ] && [ ! -e "$FF_STALE_MARKER" ]
    ' >"$GUARD_ROOT/host-mismatch-source.log" 2>&1 || fallback_rc=$?
  if [ "$fallback_rc" -eq 0 ]; then
    ok "host不一致で拒否したstale root/sourceをsource元から破棄"
  else
    bad "host不一致の失敗後にstale root/sourceがsource元へ残る"
    sed -n '1,120p' "$GUARD_ROOT/host-mismatch-source.log" >&2 || true
  fi

  fallback_rc=0
  CLAUDE_PLUGIN_ROOT="$valid_root/" \
    FF_DEV_TOOLKIT_SKILL_FILE="$valid_root/skills/multi-review/SKILL.md" \
    bash "$ROOT_GUARD_SCRIPT" >"$GUARD_ROOT/dual-same.log" 2>&1 || fallback_rc=$?
  if [ "$fallback_rc" -eq 0 ]; then
    ok "Claude rootとSKILL.md handoffの末尾slash差を正規化して通過"
  else
    bad "同じ物理rootのhost handoff併存を拒否した (rc=${fallback_rc})"
  fi

  mkdir -p "$mismatch_root/skills/multi-review"
  printf '%s\n' '# fixture skill' >"$mismatch_root/skills/multi-review/SKILL.md"
  fallback_rc=0
  CLAUDE_PLUGIN_ROOT="$valid_root" \
    FF_DEV_TOOLKIT_SKILL_FILE="$mismatch_root/skills/multi-review/SKILL.md" \
    bash "$ROOT_GUARD_SCRIPT" >"$GUARD_ROOT/dual-mismatch.log" 2>&1 || fallback_rc=$?
  if [ "$fallback_rc" -eq 2 ]; then
    ok "Claude rootとSKILL.md handoffが別実体なら拒否"
  else
    bad "別実体を示すhost handoff併存を受理した (rc=${fallback_rc})"
  fi
}
