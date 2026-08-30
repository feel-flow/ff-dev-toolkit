#!/usr/bin/env bash
# Issue #1011 の配布コマンドを、一時 consumer repo と複製 toolkit で実行する helper。
# verify.sh から source して使い、呼び出し側の ok / bad / extract_root_quoted_command と
# TMP_ROOT / PLUGIN_ROOT / DOCS / ROOT_GUARD_SCRIPT を利用する。

make_consumer_cli_stubs() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  printf '%s\n' '#!/bin/sh' 'exit 0' >"$bin_dir/codex"
  chmod +x "$bin_dir/codex"
  # setup の Mike Farah v4 / capability probe と設定読み込みに必要な最小 yq stub。
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "${1:-}" == "--version" ]]; then' \
    '  echo "yq (https://github.com/mikefarah/yq/) version v4.52.4"' \
    '  exit 0' \
    'fi' \
    'config="${@: -1}"' \
    'if [[ "${1:-}" == "." ]]; then' \
    '  grep -F "INVALID_CONFIG" "$config" >/dev/null && exit 1' \
    '  exit 0' \
    'fi' \
    'case "$*" in' \
    '  *".version //"*) echo "2.0" ;;' \
    '  *".mode // \"\""*) echo "distributed" ;;' \
    '  *".tasks.review.timeout"*) sed -n "s/^# fixture-timeout: //p" "$config" ;;' \
    '  *".tasks | keys | .[]"*) echo "review" ;;' \
    '  *".agents | keys | length"*) echo "1" ;;' \
    '  *) exit 0 ;;' \
    'esac' \
    >"$bin_dir/yq"
  chmod +x "$bin_dir/yq"
}

validate_extracted_consumer_command() {
  local command="$1" without_root
  case "$command" in
    'bash "${FF_DEV_TOOLKIT_ROOT}/scripts/setup-multi-agent.sh"'|\
    'bash "${FF_DEV_TOOLKIT_ROOT}/scripts/setup-multi-agent.sh" '*|\
    'bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-agent.sh"'|\
    'bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-agent.sh" '*|\
    'bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh"'|\
    'bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh" '*) ;;
    *) return 1 ;;
  esac
  without_root="${command//'${FF_DEV_TOOLKIT_ROOT}'/FF_DEV_TOOLKIT_ROOT}"
  case "$without_root" in
    *'$'*|*'`'*|*';'*|*'&'*|*'|'*|*'<'*|*'>'*|*'\'*|*$'\n'*|*' #'*) return 1 ;;
  esac
  bash -n -c "$command" >/dev/null 2>&1
}

validate_guarded_consumer_command() {
  local command="$1" resource_command
  local prefix='ff_require_toolkit_root && ff_require_consumer_root && '
  case "$command" in
    'ff_require_toolkit_root && ff_require_consumer_root && bash "${FF_DEV_TOOLKIT_ROOT}/scripts/'*) ;;
    *) return 1 ;;
  esac
  resource_command="${command#"$prefix"}"
  validate_extracted_consumer_command "$resource_command"
}

run_extracted_consumer_command() {
  local label="$1" command="$2" log="$3"
  local consumer="$4" entrypoint_path="$5" entrypoint_home="$6" toolkit_root="$7"
  local expected_source="${8:-plugin default}"
  local explicit_config="${9:-}"
  local expected_timeout="${10:-}"
  if [ -z "$command" ]; then
    bad "$label — 文書から引用付きcommandを抽出できない"
    return
  fi
  if ! validate_extracted_consumer_command "$command"; then
    bad "$label — 抽出commandが実行許可形ではない"
    return
  fi
  if (
    cd "$consumer"
    unset CODEX_HOME CLAUDE_CONFIG_DIR
    if [ -n "$explicit_config" ]; then
      MULTI_AGENT_CONFIG="$explicit_config"
      export MULTI_AGENT_CONFIG
    else
      unset MULTI_AGENT_CONFIG
    fi
    PATH="$entrypoint_path" HOME="$entrypoint_home" \
      FF_DEV_TOOLKIT_ROOT="$toolkit_root" \
      bash -c "$command" >"$log" 2>&1
  ) && grep -F 'Dry run complete' "$log" >/dev/null \
    && grep -F -- "$expected_source" "$log" >/dev/null \
    && { [ -z "$expected_timeout" ] || grep -F "Timeout: ${expected_timeout}s per CLI" "$log" >/dev/null; }; then
    ok "$label"
  else
    bad "$label — consumer sandboxで完走しない"
    sed -n '1,160p' "$log" >&2 || true
  fi
}

run_resolved_consumer_command() {
  local label="$1" mode="$2" command="$3" log="$4"
  local consumer="$5" entrypoint_path="$6" entrypoint_home="$7" toolkit_root="$8"
  if ! validate_guarded_consumer_command "$command"; then
    bad "$label — 抽出したguard付きcommandが実行許可形ではない"
    return
  fi
  if (
    cd "$consumer"
    unset FF_DEV_TOOLKIT_ROOT CLAUDE_PLUGIN_ROOT FF_DEV_TOOLKIT_SKILL_FILE
    case "$mode" in
      claude) CLAUDE_PLUGIN_ROOT="$toolkit_root"; export CLAUDE_PLUGIN_ROOT ;;
      skill)
        FF_DEV_TOOLKIT_SKILL_FILE="$toolkit_root/skills/multi-review/SKILL.md"
        export FF_DEV_TOOLKIT_SKILL_FILE
        ;;
      *) exit 2 ;;
    esac
    unset MULTI_AGENT_CONFIG CODEX_HOME CLAUDE_CONFIG_DIR
    FF_DEV_TOOLKIT_PROJECT_ROOT="$consumer"
    PATH="$entrypoint_path" HOME="$entrypoint_home"
    export PATH HOME FF_DEV_TOOLKIT_PROJECT_ROOT
    . "$ROOT_GUARD_SCRIPT" || exit $?
    eval "$command" >"$log" 2>&1
  ) && grep -qF 'Dry run complete' "$log" \
    && grep -qF 'plugin default' "$log"; then
    ok "$label"
  else
    bad "$label — resolverからconsumer commandまで完走しない"
    sed -n '1,160p' "$log" >&2 || true
  fi
}

run_consumer_command_smoke() {
  local ENTRYPOINT_ROOT="$TMP_ROOT/consumer-entrypoints"
  local ENTRYPOINT_CONSUMER="$ENTRYPOINT_ROOT/consumer"
  local ENTRYPOINT_HOME="$ENTRYPOINT_ROOT/home"
  local ENTRYPOINT_TOOLKIT_ROOT="$ENTRYPOINT_ROOT/toolkit root"
  local ENTRYPOINT_PATH ENTRYPOINT_NO_YQ_PATH setup_doc_command setup_log
  local expected_sidecar_root agent_doc skill_doc shim_log
  local explicit_config flag_config flag_command invalid_config_rc
  local broken_sidecar_rc safe_command unsafe_command unsafe_fail=0
  local unsafe_commands

  echo
  echo "== 配布文書のplugin root commandをconsumerから実行 =="
  mkdir -p "$ENTRYPOINT_CONSUMER" "$ENTRYPOINT_HOME"
  make_consumer_cli_stubs "$ENTRYPOINT_ROOT/bin"
  ENTRYPOINT_PATH="$ENTRYPOINT_ROOT/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  mkdir -p "$ENTRYPOINT_ROOT/bin-no-yq"
  printf '%s\n' '#!/bin/sh' 'exit 0' >"$ENTRYPOINT_ROOT/bin-no-yq/codex"
  chmod +x "$ENTRYPOINT_ROOT/bin-no-yq/codex"
  ENTRYPOINT_NO_YQ_PATH="$ENTRYPOINT_ROOT/bin-no-yq:/usr/bin:/bin:/usr/sbin:/sbin"
  # setup が chmod しても開発中の worktree を変えない。symlink では permission 退行を
  # smoke 自身が修復して隠すため、toolkit 一式を一時領域へ複製する。
  cp -R "$PLUGIN_ROOT" "$ENTRYPOINT_TOOLKIT_ROOT"
  (cd "$ENTRYPOINT_CONSUMER" && git init -q)

  safe_command='bash "${FF_DEV_TOOLKIT_ROOT}/scripts/multi-review.sh" --dry-run'
  unsafe_commands=(
    "${safe_command}; touch '$ENTRYPOINT_ROOT/markdown-command-ran'"
    "${safe_command} && true"
    "${safe_command} | true"
    "${safe_command} > '$ENTRYPOINT_ROOT/redirected'"
    "${safe_command} \$(touch '$ENTRYPOINT_ROOT/substitution-ran')"
    "${safe_command} \`touch '$ENTRYPOINT_ROOT/backtick-ran'\`"
    "${safe_command}"$'\n''true'
    "${safe_command} # hidden suffix"
  )
  for unsafe_command in "${unsafe_commands[@]}"; do
    if validate_extracted_consumer_command "$unsafe_command"; then
      unsafe_fail=$((unsafe_fail + 1))
    fi
  done
  if validate_extracted_consumer_command "$safe_command" && [ "$unsafe_fail" -eq 0 ]; then
    ok "Markdown抽出commandは正準形だけをbash -cへ許可しshell接尾辞8種を拒否する"
  else
    bad "Markdown抽出commandのallowlistが安全な正準形とshell接尾辞を区別しない"
  fi

  setup_doc_command="$(extract_root_quoted_command \
    "$DOCS/05-operations/deployment/automated-code-review.md" setup-multi-agent.sh)"
  setup_log="$ENTRYPOINT_ROOT/setup.log"
  expected_sidecar_root="$(cd "$ENTRYPOINT_TOOLKIT_ROOT/scripts" && pwd -P)"
  if [ -z "$setup_doc_command" ]; then
    bad "setup-multi-agent: 文書から引用付きcommandを抽出できない"
  elif ! validate_extracted_consumer_command "$setup_doc_command"; then
    bad "setup-multi-agent: 抽出commandが実行許可形ではない"
  elif (
    cd "$ENTRYPOINT_CONSUMER"
    PATH="$ENTRYPOINT_PATH" HOME="$ENTRYPOINT_HOME" \
      FF_DEV_TOOLKIT_ROOT="$ENTRYPOINT_TOOLKIT_ROOT" \
      bash -c "${setup_doc_command} --skip-install" >"$setup_log" 2>&1
  ) && grep -qF 'セットアップ完了' "$setup_log" \
    && [ -x "$ENTRYPOINT_CONSUMER/scripts/codex-review.sh" ] \
    && [ -f "$ENTRYPOINT_CONSUMER/scripts/.ff-dev-toolkit-root" ] \
    && [ "$(cd "$(sed -n '1p' "$ENTRYPOINT_CONSUMER/scripts/.ff-dev-toolkit-root")" && pwd -P)" \
         = "$expected_sidecar_root" ] \
    && [ ! -e "$ENTRYPOINT_CONSUMER/scripts/setup-multi-agent.sh" ] \
    && [ ! -e "$ENTRYPOINT_CONSUMER/scripts/multi-agent.sh" ] \
    && [ ! -e "$ENTRYPOINT_CONSUMER/scripts/multi-review.sh" ]; then
    ok "文書から抽出したsetup行がconsumer側へshimだけを配置"
  else
    bad "文書から抽出したsetup行がconsumer配置契約を満たさない"
    sed -n '1,200p' "$setup_log" >&2 || true
  fi

  agent_doc="$DOCS/05-operations/deployment/multi-cli-agent-orchestration.md"
  run_extracted_consumer_command "文書のmulti-agent review commandが空白pathで完走" \
    "$(extract_root_quoted_command "$agent_doc" multi-agent.sh '--task review --dry-run')" \
    "$ENTRYPOINT_ROOT/multi-agent-review.log" "$ENTRYPOINT_CONSUMER" "$ENTRYPOINT_PATH" \
    "$ENTRYPOINT_HOME" "$ENTRYPOINT_TOOLKIT_ROOT"
  run_extracted_consumer_command "文書のmulti-agent explore commandが空白pathで完走" \
    "$(extract_root_quoted_command "$agent_doc" multi-agent.sh '--task explore')" \
    "$ENTRYPOINT_ROOT/multi-agent-explore.log" "$ENTRYPOINT_CONSUMER" "$ENTRYPOINT_PATH" \
    "$ENTRYPOINT_HOME" "$ENTRYPOINT_TOOLKIT_ROOT"
  run_extracted_consumer_command "文書のmulti-agent implement commandが空白pathで完走" \
    "$(extract_root_quoted_command "$agent_doc" multi-agent.sh '--task implement')" \
    "$ENTRYPOINT_ROOT/multi-agent-implement.log" "$ENTRYPOINT_CONSUMER" "$ENTRYPOINT_PATH" \
    "$ENTRYPOINT_HOME" "$ENTRYPOINT_TOOLKIT_ROOT"
  run_extracted_consumer_command "文書のmulti-review commandが空白pathで完走" \
    "$(extract_root_quoted_command \
      "$DOCS/05-operations/deployment/multi-cli-review-orchestration.md" multi-review.sh '--dry-run')" \
    "$ENTRYPOINT_ROOT/multi-review.log" "$ENTRYPOINT_CONSUMER" "$ENTRYPOINT_PATH" \
    "$ENTRYPOINT_HOME" "$ENTRYPOINT_TOOLKIT_ROOT"
  run_resolved_consumer_command "CLAUDE_PLUGIN_ROOTからguard→文書commandを同じshellで完走" \
    claude "$(extract_guarded_root_quoted_command \
      "$DOCS/05-operations/deployment/multi-cli-review-orchestration.md" multi-review.sh '--dry-run')" \
    "$ENTRYPOINT_ROOT/multi-review-resolved-claude.log" "$ENTRYPOINT_CONSUMER" \
    "$ENTRYPOINT_PATH" "$ENTRYPOINT_HOME" "$ENTRYPOINT_TOOLKIT_ROOT"
  skill_doc="$ENTRYPOINT_TOOLKIT_ROOT/skills/multi-review/SKILL.md"
  if grep -qF '読み込んだこの `SKILL.md` のdirectoryを基準にした [plugin root固定契約](../../docs-template/05-operations/deployment/multi-cli-review-orchestration.md#ff-dev-toolkit-plugin-root-prerequisite)' \
      "$skill_doc" \
    && grep -qF '同節のresolver + guard fence全体を読み' "$skill_doc" \
    && grep -qF 'handoff設定・guard・resource呼び出しを同じshell script bodyで実行' \
      "$skill_doc"; then
    ok "multi-review skillが実行可能なresolver正本と同一shell連鎖を指示"
  else
    bad "multi-review skillがhandoff変数だけ定義しresolver実行を指示しない"
  fi
  run_resolved_consumer_command "SKILL.md指示のhandoff→guard→文書commandを同じshellで完走" \
    skill "$(extract_guarded_root_quoted_command \
      "$DOCS/05-operations/deployment/multi-cli-review-orchestration.md" multi-review.sh '--dry-run')" \
    "$ENTRYPOINT_ROOT/multi-review-resolved-skill.log" "$ENTRYPOINT_CONSUMER" \
    "$ENTRYPOINT_PATH" "$ENTRYPOINT_HOME" "$ENTRYPOINT_TOOLKIT_ROOT"

  # 文書で案内する project override → plugin default の優先順位を動的に固定する。
  mkdir -p "$ENTRYPOINT_CONSUMER/.claude"
  cp "$ENTRYPOINT_TOOLKIT_ROOT/scripts/agent-config.yaml" \
    "$ENTRYPOINT_CONSUMER/.claude/agent-config.yaml"
  printf '%s\n' '# fixture-timeout: 111' \
    >>"$ENTRYPOINT_CONSUMER/.claude/agent-config.yaml"
  run_extracted_consumer_command "consumer設定がplugin defaultより優先される" \
    "$(extract_root_quoted_command "$agent_doc" multi-agent.sh '--task review --dry-run')" \
    "$ENTRYPOINT_ROOT/multi-agent-project-override.log" "$ENTRYPOINT_CONSUMER" "$ENTRYPOINT_PATH" \
    "$ENTRYPOINT_HOME" "$ENTRYPOINT_TOOLKIT_ROOT" "project override" "" 111

  explicit_config="$ENTRYPOINT_ROOT/explicit-agent-config.yaml"
  cp "$ENTRYPOINT_TOOLKIT_ROOT/scripts/agent-config.yaml" "$explicit_config"
  printf '%s\n' '# fixture-timeout: 222' >>"$explicit_config"
  run_extracted_consumer_command "MULTI_AGENT_CONFIGがproject設定より優先される" \
    "$(extract_root_quoted_command "$agent_doc" multi-agent.sh '--task review --dry-run')" \
    "$ENTRYPOINT_ROOT/multi-agent-explicit-override.log" "$ENTRYPOINT_CONSUMER" \
    "$ENTRYPOINT_PATH" "$ENTRYPOINT_HOME" "$ENTRYPOINT_TOOLKIT_ROOT" \
    "MULTI_AGENT_CONFIG env" "$explicit_config" 222

  flag_config="$ENTRYPOINT_ROOT/flag-agent-config.yaml"
  cp "$ENTRYPOINT_TOOLKIT_ROOT/scripts/agent-config.yaml" "$flag_config"
  printf '%s\n' '# fixture-timeout: 333' >>"$flag_config"
  flag_command="$(extract_root_quoted_command \
    "$agent_doc" multi-agent.sh '--task review --dry-run') --config \"$flag_config\""
  run_extracted_consumer_command "--configが環境変数とproject設定より優先される" \
    "$flag_command" "$ENTRYPOINT_ROOT/multi-agent-flag-override.log" \
    "$ENTRYPOINT_CONSUMER" "$ENTRYPOINT_PATH" "$ENTRYPOINT_HOME" \
    "$ENTRYPOINT_TOOLKIT_ROOT" "--config flag" "$explicit_config" 333

  invalid_config_rc=0
  (
    cd "$ENTRYPOINT_CONSUMER"
    PATH="$ENTRYPOINT_PATH" HOME="$ENTRYPOINT_HOME" \
      FF_DEV_TOOLKIT_ROOT="$ENTRYPOINT_TOOLKIT_ROOT" \
      bash -c "$(extract_root_quoted_command \
        "$agent_doc" multi-agent.sh '--task review --dry-run') --config '$ENTRYPOINT_ROOT/missing.yaml'" \
      >"$ENTRYPOINT_ROOT/multi-agent-missing-config.log" 2>&1
  ) || invalid_config_rc=$?
  if [ "$invalid_config_rc" -ne 0 ] \
    && ! grep -qF 'plugin default' "$ENTRYPOINT_ROOT/multi-agent-missing-config.log"; then
    ok "不存在の--configをplugin defaultへ黙ってfallbackしない"
  else
    bad "不存在の--configを非0で拒否しない、またはplugin defaultへfallbackした"
  fi

  printf '%s\n' 'INVALID_CONFIG' >"$ENTRYPOINT_ROOT/invalid.yaml"
  invalid_config_rc=0
  (
    cd "$ENTRYPOINT_CONSUMER"
    PATH="$ENTRYPOINT_PATH" HOME="$ENTRYPOINT_HOME" \
      FF_DEV_TOOLKIT_ROOT="$ENTRYPOINT_TOOLKIT_ROOT" \
      bash -c "$(extract_root_quoted_command \
        "$agent_doc" multi-agent.sh '--task review --dry-run') --config '$ENTRYPOINT_ROOT/invalid.yaml'" \
      >"$ENTRYPOINT_ROOT/multi-agent-invalid-config.log" 2>&1
  ) || invalid_config_rc=$?
  if [ "$invalid_config_rc" -ne 0 ] \
    && grep -qF 'explicit config could not be parsed' \
      "$ENTRYPOINT_ROOT/multi-agent-invalid-config.log"; then
    ok "parse不能の--configを既定値へfallbackせず拒否"
  else
    bad "parse不能の--configを非0で拒否しない"
  fi

  invalid_config_rc=0
  (
    cd "$ENTRYPOINT_CONSUMER"
    PATH="$ENTRYPOINT_PATH" HOME="$ENTRYPOINT_HOME" \
      FF_DEV_TOOLKIT_ROOT="$ENTRYPOINT_TOOLKIT_ROOT" \
      MULTI_AGENT_CONFIG="$ENTRYPOINT_ROOT/invalid.yaml" \
      bash -c "$(extract_root_quoted_command \
        "$agent_doc" multi-agent.sh '--task review --dry-run')" \
      >"$ENTRYPOINT_ROOT/multi-agent-invalid-env-config.log" 2>&1
  ) || invalid_config_rc=$?
  if [ "$invalid_config_rc" -ne 0 ] \
    && grep -qF 'MULTI_AGENT_CONFIG env' \
      "$ENTRYPOINT_ROOT/multi-agent-invalid-env-config.log"; then
    ok "parse不能のMULTI_AGENT_CONFIGを既定値へfallbackせず拒否"
  else
    bad "parse不能のMULTI_AGENT_CONFIGを非0で拒否しない"
  fi

  for explicit_source in flag env; do
    invalid_config_rc=0
    if [ "$explicit_source" = flag ]; then
      (
        cd "$ENTRYPOINT_CONSUMER"
        PATH="$ENTRYPOINT_NO_YQ_PATH" HOME="$ENTRYPOINT_HOME" \
          FF_DEV_TOOLKIT_ROOT="$ENTRYPOINT_TOOLKIT_ROOT" \
          bash -c "$(extract_root_quoted_command \
            "$agent_doc" multi-agent.sh '--task review --dry-run') --config '$explicit_config'" \
          >"$ENTRYPOINT_ROOT/multi-agent-no-yq-${explicit_source}.log" 2>&1
      ) || invalid_config_rc=$?
    else
      (
        cd "$ENTRYPOINT_CONSUMER"
        PATH="$ENTRYPOINT_NO_YQ_PATH" HOME="$ENTRYPOINT_HOME" \
          FF_DEV_TOOLKIT_ROOT="$ENTRYPOINT_TOOLKIT_ROOT" \
          MULTI_AGENT_CONFIG="$explicit_config" \
          bash -c "$(extract_root_quoted_command \
            "$agent_doc" multi-agent.sh '--task review --dry-run')" \
          >"$ENTRYPOINT_ROOT/multi-agent-no-yq-${explicit_source}.log" 2>&1
      ) || invalid_config_rc=$?
    fi
    if [ "$invalid_config_rc" -ne 0 ] \
      && grep -qF 'yq is required to read explicit config' \
        "$ENTRYPOINT_ROOT/multi-agent-no-yq-${explicit_source}.log"; then
      ok "yq不在時の明示config(${explicit_source})を非0で拒否"
    else
      bad "yq不在時の明示config(${explicit_source})を拒否しない"
    fi
  done

  invalid_config_rc=0
  (
    cd "$ENTRYPOINT_CONSUMER"
    unset MULTI_AGENT_CONFIG
    PATH="$ENTRYPOINT_NO_YQ_PATH" HOME="$ENTRYPOINT_HOME" \
      FF_DEV_TOOLKIT_ROOT="$ENTRYPOINT_TOOLKIT_ROOT" \
      bash -c "$(extract_root_quoted_command \
        "$agent_doc" multi-agent.sh '--task review --dry-run')" \
      >"$ENTRYPOINT_ROOT/multi-agent-no-yq-implicit.log" 2>&1
  ) || invalid_config_rc=$?
  if [ "$invalid_config_rc" -eq 0 ] \
    && grep -qF 'yq not found — using defaults' \
      "$ENTRYPOINT_ROOT/multi-agent-no-yq-implicit.log"; then
    ok "yq不在時の暗黙project configは従来どおり既定値へ戻る"
  else
    bad "yq不在時の暗黙config fallbackが従来契約と不一致"
  fi

  shim_log="$ENTRYPOINT_ROOT/generated-shim.log"
  mkdir -p "$ENTRYPOINT_CONSUMER/nested"
  if (
    cd "$ENTRYPOINT_CONSUMER/nested"
    unset FF_DEV_TOOLKIT_ROOT MULTI_AGENT_CONFIG CODEX_HOME CLAUDE_CONFIG_DIR
    PATH="$ENTRYPOINT_PATH" HOME="$ENTRYPOINT_HOME" \
      bash ../scripts/codex-review.sh --dry-run >"$shim_log" 2>&1
  ) && grep -qF 'Dry run complete' "$shim_log" \
    && grep -qF 'project override' "$shim_log"; then
    ok "生成shimが別cwdからsidecarの空白pathを読みconsumer reviewへ委譲"
  else
    bad "生成shimが別cwdからsidecarのtoolkitへ委譲できない"
    sed -n '1,180p' "$shim_log" >&2 || true
  fi

  # 後方互換 shim の cache 探索契約自体は本 Issue で変えない。cache を持たない専用
  # HOME では、壊れた sidecar を成功扱いせず再セットアップ案内と非0を返すことを確認する。
  cp "$ENTRYPOINT_CONSUMER/scripts/.ff-dev-toolkit-root" \
    "$ENTRYPOINT_CONSUMER/scripts/.ff-dev-toolkit-root.valid"
  printf '%s\n' "$ENTRYPOINT_ROOT/missing toolkit/scripts" \
    >"$ENTRYPOINT_CONSUMER/scripts/.ff-dev-toolkit-root"
  broken_sidecar_rc=0
  (
    cd "$ENTRYPOINT_CONSUMER/nested"
    unset FF_DEV_TOOLKIT_ROOT MULTI_AGENT_CONFIG CODEX_HOME CLAUDE_CONFIG_DIR
    PATH="$ENTRYPOINT_PATH" HOME="$ENTRYPOINT_HOME" \
      bash ../scripts/codex-review.sh --dry-run \
      >"$ENTRYPOINT_ROOT/generated-shim-broken-sidecar.log" 2>&1
  ) || broken_sidecar_rc=$?
  mv "$ENTRYPOINT_CONSUMER/scripts/.ff-dev-toolkit-root.valid" \
    "$ENTRYPOINT_CONSUMER/scripts/.ff-dev-toolkit-root"
  if [ "$broken_sidecar_rc" -ne 0 ] \
    && grep -qF 'setup-multi-agent.sh を再実行してください' \
      "$ENTRYPOINT_ROOT/generated-shim-broken-sidecar.log"; then
    ok "生成shimはcache無し環境の壊れたsidecarを案内付きで拒否"
  else
    bad "生成shimがcache無し環境の壊れたsidecarをfail-closedに扱わない"
    sed -n '1,180p' "$ENTRYPOINT_ROOT/generated-shim-broken-sidecar.log" >&2 || true
  fi
}
