#!/usr/bin/env bash
# 配布文書の GitHub Actions 例から run step を抽出し、step 間の root 引き継ぎと
# 配置・resource guard・review 起動を一時 workspace で連続実行する。

extract_yaml_fence() {
  local source="$1" heading="$2" output="$3"
  awk -v heading="$heading" '
    $0 == heading { found_heading = 1; next }
    found_heading && !in_fence && $0 ~ /^#{1,6}[[:space:]]/ { exit 2 }
    found_heading && !in_fence && $0 == "```yaml" { in_fence = 1; next }
    in_fence && $0 == "```" { found_end = 1; exit 0 }
    in_fence { print }
    END { if (!found_heading || !found_end) exit 2 }
  ' "$source" >"$output"
}

extract_yaml_run_step() {
  local yaml="$1" name="$2" output="$3"
  awk -v wanted="$name" '
    $0 == "      - name: " wanted { in_step = 1; next }
    in_run && /^      - name:/ { exit(found ? 0 : 2) }
    in_step && /^      - name:/ { exit 2 }
    in_step && /^        run: \|[[:space:]]*$/ { in_run = 1; next }
    in_step && /^        run: / {
      sub(/^        run: /, "")
      print
      found = 1
      exit 0
    }
    in_run && /^          / {
      sub(/^          /, "")
      print
      found = 1
      next
    }
    in_run { exit(found ? 0 : 2) }
    END { if (!found) exit 2 }
  ' "$yaml" >"$output"
}

extract_yaml_named_step() {
  local yaml="$1" name="$2" output="$3"
  awk -v wanted="$name" '
    $0 == "      - name: " wanted { in_step = 1 }
    in_step && found && /^      - (name:|uses:)/ { exit 0 }
    in_step { print; found = 1 }
    END { if (!found) exit 2 }
  ' "$yaml" >"$output"
}

run_ci_example_cases() {
  local root="$TMP_ROOT/ci-example" workspace="$TMP_ROOT/ci-workspace"
  local yaml="$root/workflow.yml" root_step="$root/root-step.sh"
  local checkout_step="$root/checkout-step.yml" pin_step="$root/pin-step.sh"
  local place_step="$root/place-step.sh" verify_step="$root/verify-step.sh"
  local cleanup_step="$root/cleanup-step.sh" upload_step="$root/upload-step.yml"
  local output_step="$root/output-step.sh" review_output="$root/runner-temp/ff-review-results"
  local review_step="$root/review-step.sh" review_named_step="$root/review-step.yml"
  local report_step="$root/report-step.sh" install_step="$root/install-step.sh"
  local source_root env_name env_value rc=0 resource report_fixture
  local checkout_repo checkout_ref checkout_path expected_copy pin_ref
  local guard_mode guard_root guard_path
  local review_marker="$root/review-ran" missing_workspace="$TMP_ROOT/ci-missing-source"

  echo
  echo "== GitHub Actions例のstep連鎖 =="
  mkdir -p "$root/runner-temp" "$workspace/.ff-dev-toolkit-source/plugins" "$missing_workspace"
  if ! extract_yaml_fence \
      "$DOCS/05-operations/deployment/multi-cli-review-ci.md" \
      "### CI/CD（GitHub Actions）での実行" "$yaml" \
    || ! extract_yaml_named_step "$yaml" "Checkout pinned ff-dev-toolkit source" "$checkout_step" \
    || ! extract_yaml_run_step "$yaml" "Verify ff-dev-toolkit commit pin" "$pin_step" \
    || ! extract_yaml_run_step "$yaml" "Fix ff-dev-toolkit root to runner temp" "$root_step" \
    || ! extract_yaml_run_step "$yaml" "Place pinned ff-dev-toolkit" "$place_step" \
    || ! extract_yaml_run_step "$yaml" "Remove nested toolkit checkout" "$cleanup_step" \
    || ! extract_yaml_run_step "$yaml" "Install CLI tools" "$install_step" \
    || ! extract_yaml_run_step "$yaml" "Verify pinned ff-dev-toolkit" "$verify_step" \
    || ! extract_yaml_run_step "$yaml" "Prepare trusted review output" "$output_step" \
    || ! extract_yaml_run_step "$yaml" "Run Multi-CLI Review" "$review_step" \
    || ! extract_yaml_named_step "$yaml" "Run Multi-CLI Review" "$review_named_step" \
    || ! extract_yaml_run_step "$yaml" "Verify integrated review report" "$report_step" \
    || ! extract_yaml_named_step "$yaml" "Upload results" "$upload_step"; then
    bad "CI例からroot固定・配置・検証・review stepを抽出できない"
    return
  fi

  if yq -e '.' "$yaml" >/dev/null 2>&1; then
    ok "CI例のworkflow全体がYAMLとしてparseできる"
  else
    bad "CI例のworkflow全体をYAMLとしてparseできない"
  fi
  if awk '
      /^env:/ { in_top_env = 1; next }
      in_top_env && /^[^[:space:]]/ { in_top_env = 0 }
      in_top_env && /runner\.temp/ { found = 1 }
      END { exit(found ? 0 : 1) }
    ' "$yaml"; then
    bad "CI例のworkflow-level envが利用不能なrunner contextを参照する"
  else
    ok "CI例のworkflow-level envはrunner contextを参照しない"
  fi

  checkout_repo="$(awk '$1 == "repository:" { print $2; exit }' "$checkout_step")"
  checkout_ref="$(awk '$1 == "ref:" { sub(/^[[:space:]]*ref:[[:space:]]*/, ""); print; exit }' \
    "$checkout_step")"
  checkout_path="$(awk '$1 == "path:" { print $2; exit }' "$checkout_step")"
  expected_copy="cp -R ${checkout_path}/plugins/ff-dev-toolkit \"\$FF_DEV_TOOLKIT_ROOT\""
  if [ "$checkout_repo" = feel-flow/ff-dev-toolkit ] \
    && [ "$checkout_ref" = '${{ env.FF_DEV_TOOLKIT_REF }}' ] \
    && [ "$checkout_path" = .ff-dev-toolkit-source ] \
    && grep -qF 'fetch-depth: 0' "$yaml" \
    && grep -qF "$expected_copy" "$place_step"; then
    ok "CI例のcheckout repository/ref/pathと配置元が同じpinへ結び付く"
  else
    bad "CI例のcheckout repository/ref/pathと配置元が一致しない"
    return
  fi

  if grep -qE '^on:$' "$yaml" \
    && grep -qE '^  pull_request:$' "$yaml" \
    && ! grep -qE '^  pull_request_target:' "$yaml" \
    && grep -qE '^    if: github\.event\.pull_request\.head\.repo\.full_name == github\.repository$' "$yaml" \
    && grep -qF "        if: \${{ always() && steps.multi_cli_review.conclusion != 'skipped' }}" "$yaml"; then
    ok "CI例のtrigger・job fork境界・upload条件がYAML階層上も正しい"
  else
    bad "CI例のtrigger・job fork境界・upload条件のYAML階層が不正"
  fi
  source_root="$workspace/.ff-dev-toolkit-source/plugins/ff-dev-toolkit"
  mkdir -p "$source_root/scripts" "$source_root/.claude-plugin"
  printf '%s\n' '{"name":"ff-dev-toolkit"}' >"$source_root/.claude-plugin/plugin.json"
  printf '%s\n' 'version: "2.0"' >"$source_root/scripts/agent-config.yaml"
  for resource in setup-multi-agent.sh multi-agent.sh; do
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$source_root/scripts/$resource"
    chmod +x "$source_root/scripts/$resource"
  done
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$@" >"${CI_REVIEW_SENTINEL:?}"' \
    >"$source_root/scripts/multi-review.sh"
  chmod +x "$source_root/scripts/multi-review.sh"
  git -C "$workspace/.ff-dev-toolkit-source" init -q
  git -C "$workspace/.ff-dev-toolkit-source" config user.name fixture
  git -C "$workspace/.ff-dev-toolkit-source" config user.email fixture@example.invalid
  git -C "$workspace/.ff-dev-toolkit-source" add plugins/ff-dev-toolkit
  git -C "$workspace/.ff-dev-toolkit-source" commit -qm fixture
  pin_ref="$(git -C "$workspace/.ff-dev-toolkit-source" rev-parse HEAD)"

  rc=0
  FF_DEV_TOOLKIT_REF="$pin_ref" bash -euo pipefail "$pin_step" \
    >"$root/pin-valid.log" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    ok "CI例が40文字のcommit SHA pinをruntime検証"
  else
    bad "CI例が正しいcommit SHA pinを拒否した (rc=${rc})"
  fi
  for checkout_ref in main 123456789012345678901234567890123456789 \
    12345678901234567890123456789012345678901 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA; do
    rc=0
    FF_DEV_TOOLKIT_REF="$checkout_ref" bash -euo pipefail "$pin_step" \
      >"$root/pin-invalid.log" 2>&1 || rc=$?
    if [ "$rc" -eq 2 ]; then
      ok "CI例が非40文字lowercase SHA pinをstatus 2で拒否: $checkout_ref"
    else
      bad "CI例が不正pinを受理した: $checkout_ref (rc=${rc})"
    fi
  done

  install_bin="$root/install-bin"
  install_log="$root/install.log"
  curl_sentinel="$root/curl-ran"
  mkdir -p "$install_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'touch "${FF_CURL_SENTINEL:?}"' \
    '[ "${FF_CURL_RC:-0}" -eq 0 ] || exit "$FF_CURL_RC"' \
    'output="$2"' \
    'printf "%s\n" "#!/usr/bin/env bash" "if [ \"\${1:-}\" = --version ]; then" "  if [ \"\${FF_YQ_MODE:-ok}\" = bad-version ]; then echo \"other yq\"; else echo \"yq (https://github.com/mikefarah/yq/) version v4.53.3\"; fi" "  exit 0" "fi" "if [ \"\${FF_YQ_MODE:-ok}\" = bad-capability ]; then echo wrong; else echo 2.0; fi" "exit 0" >"$output"' \
    >"$install_bin/curl"
  printf '%s\n' '#!/bin/sh' 'exit "${FF_SHA_RC:-0}"' >"$install_bin/sha256sum"
  printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$*" >>"${FF_NPM_LOG:?}"' \
    'exit "${FF_NPM_RC:-0}"' >"$install_bin/npm"
  chmod +x "$install_bin/curl" "$install_bin/sha256sum" "$install_bin/npm"

  rc=0
  PATH="$install_bin:/usr/bin:/bin" RUNNER_TEMP="$root/runner-temp" \
    GITHUB_PATH="$root/github-path" \
    FF_CURL_SENTINEL="$curl_sentinel" FF_NPM_LOG="$install_log" \
    CLAUDE_CODE_VERSION=1.2.3 CODEX_CLI_VERSION=2.0.0-rc.1 \
    GROK_CLI_VERSION=3.4.5+review.7 YQ_VERSION=4.53.3 \
    YQ_SHA256=0000000000000000000000000000000000000000000000000000000000000000 \
    bash -euo pipefail "$install_step" >"$root/install-valid.log" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ] \
    && grep -F '@anthropic-ai/claude-code@1.2.3' "$install_log" >/dev/null \
    && grep -F '@openai/codex@2.0.0-rc.1' "$install_log" >/dev/null \
    && grep -F '@xai-official/grok@3.4.5+review.7' "$install_log" >/dev/null; then
    ok "CI例のinstall stepが厳密SemVerと各pinを実コマンドへ渡す"
  else
    bad "CI例のinstall step正常系を再現できない (rc=${rc})"
  fi
  for invalid_version in latest '^1.2.3' 01.2.3 1.02.3 1.2.03 1.2.3-01 1.2.3-.. 1.2; do
    rm -f "$curl_sentinel"
    rc=0
    PATH="$install_bin:/usr/bin:/bin" RUNNER_TEMP="$root/runner-temp" \
      GITHUB_PATH="$root/github-path" \
      FF_CURL_SENTINEL="$curl_sentinel" FF_NPM_LOG="$install_log" \
      CLAUDE_CODE_VERSION="$invalid_version" CODEX_CLI_VERSION=2.0.0 \
      GROK_CLI_VERSION=3.4.5 YQ_VERSION=4.53.3 \
      YQ_SHA256=0000000000000000000000000000000000000000000000000000000000000000 \
      bash -euo pipefail "$install_step" >"$root/install-invalid.log" 2>&1 || rc=$?
    if [ "$rc" -eq 2 ] && [ ! -e "$curl_sentinel" ]; then
      ok "CI例は不正なCLI versionをdownload前に拒否: ${invalid_version}"
    else
      bad "CI例が不正なCLI versionを受理: ${invalid_version} (rc=${rc})"
    fi
  done
  for install_failure in download checksum yq-version yq-capability npm; do
    rc=0
    FF_CURL_RC=0 FF_SHA_RC=0 FF_YQ_MODE=ok FF_NPM_RC=0
    case "$install_failure" in
      download) FF_CURL_RC=22 ;;
      checksum) FF_SHA_RC=1 ;;
      yq-version) FF_YQ_MODE=bad-version ;;
      yq-capability) FF_YQ_MODE=bad-capability ;;
      npm) FF_NPM_RC=1 ;;
    esac
    export FF_CURL_RC FF_SHA_RC FF_YQ_MODE FF_NPM_RC
    PATH="$install_bin:/usr/bin:/bin" RUNNER_TEMP="$root/runner-temp" \
      GITHUB_PATH="$root/github-path" \
      FF_CURL_SENTINEL="$curl_sentinel" FF_NPM_LOG="$install_log" \
      CLAUDE_CODE_VERSION=1.2.3 CODEX_CLI_VERSION=2.0.0 \
      GROK_CLI_VERSION=3.4.5 YQ_VERSION=4.53.3 \
      YQ_SHA256=0000000000000000000000000000000000000000000000000000000000000000 \
      bash -euo pipefail "$install_step" >"$root/install-${install_failure}.log" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
      ok "CI例はinstall ${install_failure}失敗を成功扱いしない"
    else
      bad "CI例がinstall ${install_failure}失敗を成功扱いした"
    fi
  done
  unset FF_CURL_RC FF_SHA_RC FF_YQ_MODE FF_NPM_RC

  rc=0
  GITHUB_ENV="$root/github-env" RUNNER_TEMP="$root/runner-temp" \
    bash -euo pipefail "$root_step" >"$root/root-step.log" 2>&1 || rc=$?
  IFS='=' read -r env_name env_value <"$root/github-env" || rc=$?
  if [ "$rc" -eq 0 ] && [ "$env_name" = FF_DEV_TOOLKIT_ROOT ] \
    && [ "$env_value" = "$root/runner-temp/ff-dev-toolkit" ]; then
    ok "CI例がRUNNER_TEMPからGITHUB_ENVへ固定rootを引き継ぐ"
  else
    bad "CI例のGITHUB_ENV root引き継ぎを再現できない (rc=${rc})"
    return
  fi
  if grep -Fx "FF_REVIEW_OUTPUT=$review_output" "$root/github-env" >/dev/null; then
    ok "CI例がRUNNER_TEMPからGITHUB_ENVへreview出力先も引き継ぐ"
  else
    bad "CI例がreview出力先をrunner起動後に固定しない"
  fi

  rc=0
  (cd "$workspace" && FF_DEV_TOOLKIT_REF=0000000000000000000000000000000000000000 \
    FF_DEV_TOOLKIT_ROOT="$env_value" FF_DEV_TOOLKIT_ROOT_SOURCE=ci \
    bash -euo pipefail "$place_step") >"$root/place-ref-mismatch.log" 2>&1 || rc=$?
  if [ "$rc" -eq 2 ] && [ ! -e "$env_value" ]; then
    ok "CI例はcheckout HEADと指定pinの不一致を配置前に拒否"
  else
    bad "CI例がcheckout HEADと指定pinの不一致を受理した (rc=${rc})"
  fi

  rc=0
  (cd "$workspace" && FF_DEV_TOOLKIT_REF="$pin_ref" \
    FF_DEV_TOOLKIT_ROOT="$env_value" FF_DEV_TOOLKIT_ROOT_SOURCE=ci \
    bash -euo pipefail "$place_step") >"$root/place.log" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ] && [ -d "$env_value/scripts" ]; then
    ok "CI例が文書でpinしたplugin階層からrunner tempへtoolkitを配置"
  else
    bad "CI例のtoolkit配置を再現できない (rc=${rc})"
  fi

  rc=0
  (cd "$workspace" && FF_DEV_TOOLKIT_REF="$pin_ref" \
    FF_DEV_TOOLKIT_ROOT="$env_value" FF_DEV_TOOLKIT_ROOT_SOURCE=ci \
    bash -euo pipefail "$place_step") >"$root/existing-target.log" 2>&1 || rc=$?
  if [ "$rc" -eq 2 ]; then
    ok "CI例は配置先が既存なら上書きせずstatus 2で停止"
  else
    bad "CI例が既存の配置先を上書きした (rc=${rc})"
  fi

  rc=0
  (cd "$missing_workspace" && FF_DEV_TOOLKIT_ROOT="$root/missing-target" \
    FF_DEV_TOOLKIT_ROOT_SOURCE=ci bash -euo pipefail "$place_step") \
    >"$root/missing-source.log" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ] && [ ! -e "$root/missing-target" ]; then
    ok "CI例はcheckout内容が欠落していれば配置を完了扱いしない"
  else
    bad "CI例がcheckout内容の欠落を成功扱いした (rc=${rc})"
  fi

  rc=0
  FF_DEV_TOOLKIT_ROOT="$env_value" FF_DEV_TOOLKIT_ROOT_SOURCE=ci \
    bash -euo pipefail "$verify_step" >"$root/verify.log" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    ok "CI例が配置後の3 resourceをfail-closed検証"
  else
    bad "CI例の配置後resource検証が失敗 (rc=${rc})"
  fi

  if grep -qF '[ ! -f "$resource_path" ]' "$verify_step" \
    && grep -qF '[ -L "$resource_path" ]' "$verify_step" \
    && grep -qF '[ ! -r "$resource_path" ]' "$verify_step" \
    && grep -qF '[ ! -s "$resource_path" ]' "$verify_step" \
    && ! grep -qF '[ ! -x "$resource_path" ]' "$verify_step"; then
    ok "抽出したCI resource guardがbash入口に必要な-f/-r/-sを要求"
  else
    bad "抽出したCI resource guardのbash入口契約が不一致"
  fi

  for resource in setup-multi-agent.sh multi-agent.sh multi-review.sh; do
    for guard_mode in missing empty nonexec directory dangling symlink; do
      guard_root="$root/guard-${resource%.sh}-${guard_mode}"
      cp -R "$env_value" "$guard_root"
      guard_path="$guard_root/scripts/$resource"
      case "$guard_mode" in
        missing) rm "$guard_path" ;;
        empty) : >"$guard_path"; chmod +x "$guard_path" ;;
        nonexec) chmod -x "$guard_path" ;;
        directory) rm "$guard_path"; mkdir "$guard_path" ;;
        dangling) rm "$guard_path"; ln -s "$guard_root/scripts/not-found.sh" "$guard_path" ;;
        symlink)
          mv "$guard_path" "$guard_path.file"
          ln -s "$guard_path.file" "$guard_path"
          ;;
      esac
      rc=0
      FF_DEV_TOOLKIT_ROOT="$guard_root" FF_DEV_TOOLKIT_ROOT_SOURCE=ci \
        bash -euo pipefail "$verify_step" \
        >"$root/guard-${resource%.sh}-${guard_mode}.log" 2>&1 || rc=$?
      if [ "$guard_mode" = nonexec ] && [ "$rc" -eq 0 ]; then
        ok "CI例はbashで呼ぶ${resource}を非実行でも読み取り可能なら受理"
      elif [ "$guard_mode" != nonexec ] && [ "$rc" -eq 2 ]; then
        ok "CI例は${resource}の${guard_mode} fixtureをstatus 2で停止"
      else
        bad "CI例の${resource}/${guard_mode}判定が契約と不一致 (rc=${rc})"
      fi
    done

    guard_root="$root/guard-${resource%.sh}-unreadable"
    cp -R "$env_value" "$guard_root"
    guard_path="$guard_root/scripts/$resource"
    chmod 111 "$guard_path"
    if [ ! -r "$guard_path" ]; then
      rc=0
      FF_DEV_TOOLKIT_ROOT="$guard_root" FF_DEV_TOOLKIT_ROOT_SOURCE=ci \
        bash -euo pipefail "$verify_step" \
        >"$root/guard-${resource%.sh}-unreadable.log" 2>&1 || rc=$?
      if [ "$rc" -eq 2 ]; then
        ok "CI例は${resource}のunreadable fixtureをstatus 2で停止"
      else
        bad "CI例が${resource}のunreadable fixtureを成功扱い (rc=${rc})"
      fi
    else
      echo "○ skip: 実行ユーザーが権限bitを超えて読めるため${resource}のunreadable fixtureを作れません"
    fi
  done

  guard_root="$root/guard-scripts-symlink"
  cp -R "$env_value" "$guard_root"
  mv "$guard_root/scripts" "$guard_root/scripts-real"
  ln -s "$guard_root/scripts-real" "$guard_root/scripts"
  rc=0
  FF_DEV_TOOLKIT_ROOT="$guard_root" FF_DEV_TOOLKIT_ROOT_SOURCE=ci \
    bash -euo pipefail "$verify_step" >"$root/guard-scripts-symlink.log" 2>&1 || rc=$?
  if [ "$rc" -eq 2 ]; then
    ok "CI例はscripts directory symlinkをstatus 2で停止"
  else
    bad "CI例がscripts directory symlinkを成功扱い (rc=${rc})"
  fi

  guard_root="$root/guard-chain"
  cp -R "$env_value" "$guard_root"
  rm "$guard_root/scripts/setup-multi-agent.sh"
  rc=0
  FF_DEV_TOOLKIT_ROOT="$guard_root" FF_DEV_TOOLKIT_ROOT_SOURCE=ci \
    CI_REVIEW_SENTINEL="$review_marker" VERIFY_STEP="$verify_step" \
    PR_BASE_REF=develop REVIEW_STEP="$review_step" bash -euo pipefail -c \
      'bash -euo pipefail "$VERIFY_STEP" && bash -euo pipefail "$REVIEW_STEP"' \
      >"$root/verify-review-chain.log" 2>&1 || rc=$?
  if [ "$rc" -eq 2 ] && [ ! -e "$review_marker" ]; then
    ok "CI例はVerify失敗後に認証付きreviewを起動しない"
  else
    bad "CI例がVerify失敗後もreviewを起動した (rc=${rc})"
  fi

  rc=0
  (cd "$workspace" && bash -euo pipefail "$cleanup_step") \
    >"$root/cleanup.log" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ] && [ ! -e "$workspace/.ff-dev-toolkit-source" ]; then
    ok "CI例はreview前にconsumer workspace内のnested toolkit checkoutを削除"
  else
    bad "CI例がreview前にnested toolkit checkoutを残した (rc=${rc})"
  fi

  rc=0
  FF_REVIEW_OUTPUT="$review_output" bash -euo pipefail "$output_step" \
    >"$root/output-step.log" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ] && [ -d "$review_output" ] && [ ! -L "$review_output" ]; then
    ok "CI例がconsumer workspace外に新規review出力先を作成"
  else
    bad "CI例が信頼済みreview出力先を新規作成できない (rc=${rc})"
  fi

  rc=0
  FF_DEV_TOOLKIT_ROOT="$env_value" FF_DEV_TOOLKIT_ROOT_SOURCE=ci \
    FF_REVIEW_OUTPUT="$review_output" CI_REVIEW_SENTINEL="$review_marker" \
    PR_BASE_REF=develop bash -euo pipefail "$review_step" \
    >"$root/review.log" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ] && [ -e "$review_marker" ] \
    && grep -qFx -- '--config' "$review_marker" \
    && grep -qFx -- "$env_value/scripts/agent-config.yaml" "$review_marker" \
    && grep -qFx -- '--output-dir' "$review_marker" \
    && grep -qFx -- "$review_output" "$review_marker" \
    && grep -qFx -- '--base' "$review_marker" \
    && grep -qFx -- 'origin/develop' "$review_marker"; then
    ok "CI例が信頼済みconfig・artifact回収先・PR baseを固定してreviewを起動"
  else
    bad "CI例がreviewのconfigまたはoutput-dirを信頼済みpathへ固定しない (rc=${rc})"
  fi

  if grep -F 'PR_BASE_REF: ${{ github.base_ref }}' "$review_named_step" >/dev/null \
    && ! grep -F '${{ github.base_ref }}' "$review_step" >/dev/null; then
    ok "CI例がPR baseをenv経由でshellへ渡す"
  else
    bad "CI例がGitHub contextをrun scriptへ直接展開する"
  fi

  printf '%s\n' '# complete review' >"$review_output/integrated-report.md"
  rc=0
  FF_REVIEW_OUTPUT="$review_output" bash -euo pipefail "$report_step" \
    >"$root/report-valid.log" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    ok "CI例は通常ファイルかつ非空の統合レポートだけを成功扱いする"
  else
    bad "CI例が正常な統合レポートを拒否した (rc=${rc})"
  fi
  for report_fixture in missing empty directory symlink critical; do
    rm -rf "$review_output/integrated-report.md"
    case "$report_fixture" in
      missing) ;;
      empty) : >"$review_output/integrated-report.md" ;;
      directory) mkdir "$review_output/integrated-report.md" ;;
      symlink) ln -s "$root/report-valid.log" "$review_output/integrated-report.md" ;;
      critical) printf '%s\n' '<!-- CRITICAL_BLOCK -->' >"$review_output/integrated-report.md" ;;
    esac
    rc=0
    FF_REVIEW_OUTPUT="$review_output" bash -euo pipefail "$report_step" \
      >"$root/report-${report_fixture}.log" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
      ok "CI例は${report_fixture}統合レポートを成功扱いしない"
    else
      bad "CI例が${report_fixture}統合レポートを成功扱いした"
    fi
  done

  if grep -qF 'if-no-files-found: error' "$upload_step" \
    && grep -qF 'path: ${{ runner.temp }}/ff-review-results/' "$upload_step" \
    && grep -qF "if: \${{ always() && steps.multi_cli_review.conclusion != 'skipped' }}" \
      "$upload_step"; then
    ok "CI例はreview出力欠落をartifact uploadでエラーにする"
  else
    bad "CI例がreview出力欠落をartifact uploadで検出しない"
  fi
}
