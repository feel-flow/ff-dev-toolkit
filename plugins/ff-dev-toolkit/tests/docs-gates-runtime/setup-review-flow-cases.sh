#!/usr/bin/env bash
# automated-code-review.md の guard -> setup -> review 停止連鎖を fence 単位で実行する。

run_setup_review_flow_cases() {
  local flow_root="$TMP_ROOT/setup-review-flow" script="$TMP_ROOT/automated-review-setup.sh"
  local harness="$TMP_ROOT/automated-review-harness.sh" setup_marker review_marker rc

  echo
  echo "== automated review setup の停止連鎖 =="
  if ! extract_bash_fence \
      "$DOCS/05-operations/deployment/automated-code-review.md" \
      "### 自動セットアップ（推奨・同梱スクリプト）" \
      "$script"; then
    bad "automated review setup fenceを抽出できない"
    return
  fi

  mkdir -p "$flow_root/scripts"
  printf '%s\n' '#!/usr/bin/env bash' ': >"${SETUP_SENTINEL:?}"' \
    'exit "${SETUP_RESULT:-0}"' >"$flow_root/scripts/setup-multi-agent.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "run\n" >>"${REVIEW_SENTINEL:?}"' \
    'exit "${REVIEW_RESULT:-0}"' >"$flow_root/scripts/multi-review.sh"
  chmod +x "$flow_root/scripts/setup-multi-agent.sh" "$flow_root/scripts/multi-review.sh"
  printf '%s\n' '#!/usr/bin/env bash' \
    'TOOLKIT_GUARD_CALLS=0' \
    'CONSUMER_GUARD_CALLS=0' \
    'ff_require_toolkit_root() {' \
    '  TOOLKIT_GUARD_CALLS=$((TOOLKIT_GUARD_CALLS + 1))' \
    '  if [ "$TOOLKIT_GUARD_CALLS" -eq 1 ]; then return "${FIRST_TOOLKIT_GUARD_RESULT:-0}"; fi' \
    '  return "${SECOND_TOOLKIT_GUARD_RESULT:-0}"' \
    '}' \
    'ff_require_consumer_root() {' \
    '  CONSUMER_GUARD_CALLS=$((CONSUMER_GUARD_CALLS + 1))' \
    '  if [ "$CONSUMER_GUARD_CALLS" -eq 1 ]; then return "${FIRST_CONSUMER_GUARD_RESULT:-0}"; fi' \
    '  return "${SECOND_CONSUMER_GUARD_RESULT:-0}"' \
    '}' \
    '. "${FLOW_SCRIPT:?}"' >"$harness"
  chmod +x "$harness"

  setup_marker="$flow_root/setup-ran"
  review_marker="$flow_root/review-ran"
  rc=0
  FIRST_TOOLKIT_GUARD_RESULT=2 FLOW_SCRIPT="$script" FF_DEV_TOOLKIT_ROOT="$flow_root" \
    SETUP_SENTINEL="$setup_marker" REVIEW_SENTINEL="$review_marker" \
    bash "$harness" >"$flow_root/guard-failure.log" 2>&1 || rc=$?
  if [ "$rc" -eq 2 ] && [ ! -e "$setup_marker" ] && [ ! -e "$review_marker" ]; then
    ok "guard非0ではsetupとreviewを起動しない"
  else
    bad "guard非0でもsetupまたはreviewへ進んだ (rc=${rc})"
  fi

  rm -f "$setup_marker" "$review_marker"
  rc=0
  FIRST_TOOLKIT_GUARD_RESULT=0 FIRST_CONSUMER_GUARD_RESULT=2 \
    FLOW_SCRIPT="$script" FF_DEV_TOOLKIT_ROOT="$flow_root" \
    SETUP_SENTINEL="$setup_marker" REVIEW_SENTINEL="$review_marker" \
    bash "$harness" >"$flow_root/consumer-guard-failure.log" 2>&1 || rc=$?
  if [ "$rc" -eq 2 ] && [ ! -e "$setup_marker" ] && [ ! -e "$review_marker" ]; then
    ok "setup前のconsumer guard非0ではsetupとreviewを起動しない"
  else
    bad "setup前のconsumer guard非0でもsetupまたはreviewへ進んだ (rc=${rc})"
  fi

  rm -f "$setup_marker" "$review_marker"
  rc=0
  FIRST_TOOLKIT_GUARD_RESULT=0 SECOND_TOOLKIT_GUARD_RESULT=2 \
    SETUP_RESULT=0 FLOW_SCRIPT="$script" FF_DEV_TOOLKIT_ROOT="$flow_root" \
    SETUP_SENTINEL="$setup_marker" REVIEW_SENTINEL="$review_marker" \
    bash "$harness" >"$flow_root/recheck-failure.log" 2>&1 || rc=$?
  if [ "$rc" -eq 2 ] && [ -e "$setup_marker" ] && [ ! -e "$review_marker" ]; then
    ok "setup後のtoolkit再検証失敗ではreviewを起動しない"
  else
    bad "setup後のtoolkit再検証失敗でもreviewへ進んだ (rc=${rc})"
  fi

  rm -f "$setup_marker" "$review_marker"
  rc=0
  FIRST_CONSUMER_GUARD_RESULT=0 SECOND_CONSUMER_GUARD_RESULT=2 \
    SETUP_RESULT=0 FLOW_SCRIPT="$script" FF_DEV_TOOLKIT_ROOT="$flow_root" \
    SETUP_SENTINEL="$setup_marker" REVIEW_SENTINEL="$review_marker" \
    bash "$harness" >"$flow_root/consumer-recheck-failure.log" 2>&1 || rc=$?
  if [ "$rc" -eq 2 ] && [ -e "$setup_marker" ] && [ ! -e "$review_marker" ]; then
    ok "setup後のconsumer再検証失敗ではreviewを起動しない"
  else
    bad "setup後のconsumer再検証失敗でもreviewへ進んだ (rc=${rc})"
  fi

  rm -f "$setup_marker" "$review_marker"
  rc=0
  SETUP_RESULT=7 FLOW_SCRIPT="$script" FF_DEV_TOOLKIT_ROOT="$flow_root" \
    SETUP_SENTINEL="$setup_marker" REVIEW_SENTINEL="$review_marker" \
    bash "$harness" >"$flow_root/setup-failure.log" 2>&1 || rc=$?
  if [ "$rc" -eq 7 ] && [ -e "$setup_marker" ] && [ ! -e "$review_marker" ]; then
    ok "setup非0ではreviewを起動せず終了codeを保持する"
  else
    bad "setup非0をreview停止へ伝播できない (rc=${rc})"
  fi

  rm -f "$setup_marker" "$review_marker"
  rc=0
  SETUP_RESULT=0 REVIEW_RESULT=9 FLOW_SCRIPT="$script" \
    FF_DEV_TOOLKIT_ROOT="$flow_root" SETUP_SENTINEL="$setup_marker" \
    REVIEW_SENTINEL="$review_marker" bash "$harness" \
    >"$flow_root/review-failure.log" 2>&1 || rc=$?
  if [ "$rc" -eq 9 ] && [ -e "$setup_marker" ] \
    && [ "$(wc -l <"$review_marker" | tr -d ' ')" -eq 1 ]; then
    ok "review非0の終了codeを保持し、reviewは1回だけ起動する"
  else
    bad "review非0を最終statusへ伝播できない (rc=${rc})"
  fi

  rm -f "$setup_marker" "$review_marker"
  rc=0
  SETUP_RESULT=0 REVIEW_RESULT=0 FLOW_SCRIPT="$script" \
    FF_DEV_TOOLKIT_ROOT="$flow_root" SETUP_SENTINEL="$setup_marker" \
    REVIEW_SENTINEL="$review_marker" bash "$harness" \
    >"$flow_root/success.log" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ] && [ -e "$setup_marker" ] \
    && [ "$(wc -l <"$review_marker" | tr -d ' ')" -eq 1 ]; then
    ok "guardとsetup成功時だけreviewを1回起動する"
  else
    bad "guardからreviewまでの成功連鎖を完走できない (rc=${rc})"
  fi
}
