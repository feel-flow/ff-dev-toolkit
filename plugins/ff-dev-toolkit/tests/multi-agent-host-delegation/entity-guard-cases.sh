#!/usr/bin/env bash
# HTML entity guard and transcript extraction regression cases; sourced by verify.sh.

run_entity_guard_cases() {
  echo '-- host delegation entity guard & transcript extraction (AC 1-5) --'
  local original area REPO REPO_PHYS out out_mr out_ac2 out_cl
  local prompt_f req_f resp_f canon_f report_f req_snap_dir entity_tag e_char
  local fixtures ext_rc ext_out ext_err out_file bad_out link_t link_dir link_out
  local out_sp sp_resp sp_canon out_par par_cr_resp par_bh_resp retry_cmd par_rc cwd_out desc_rc
  local -a eg_args mr_args par_args
  # shellcheck disable=SC2034 # run_ma reads this local variable from the caller scope
  local MA_ENTRY="$MULTI_AGENT"

  original="$(pwd -P)"
  area="$TMP/entity-guard"
  mkdir -p "$area"
  area="$(CDPATH='' cd -P -- "$area" && pwd -P)"

  REPO="$area/repo"
  ff_git_fixture_init "$REPO" 'entity guard fixture' 'entity-guard@example.com'
  cd "$REPO" || return 1
  git branch -M develop
  printf 'base\n' >app.txt
  printf '/.review-results/\n' >.gitignore
  git add app.txt .gitignore
  git commit -qm init
  git switch -q -c feature/entity-guard
  printf 'base\n<html>\n' >app.txt
  git add app.txt
  git commit -qm change
  REPO_PHYS="$(pwd -P)"

  out="$REPO_PHYS/.review-results-ac1"
  eg_args=(--task review --mode cross-model --perspective code-review --base develop --cli claude-code --delegate-to-host --output-dir "$out")
  PROMPT_FILE=""
  RESPONSE_FILE=""
  run_ma eg-launch "${eg_args[@]}"
  prompt_f="$PROMPT_FILE"
  resp_f="$RESPONSE_FILE"
  req_f="${prompt_f%.prompt.md}.request"
  canon_f="$out/claude-code/code-review.md"
  report_f="$out/integrated-report.md"

  # AC 5: handoff stderr & pending report warn against <task-notification> and name --extract-subagent-response
  if [[ "$RUN_RC" -eq 3 ]] \
    && grep -qF '<task-notification>' "$RUN_ERR" \
    && grep -qF -- '--extract-subagent-response' "$RUN_ERR"; then
    ok "AC5: initial handoff Step 2 warns against <task-notification> and names --extract-subagent-response"
  else
    bad "AC5: handoff stderr missing <task-notification> warning or --extract-subagent-response (rc=${RUN_RC})"
  fi

  if [[ -f "$report_f" ]] \
    && grep -qF '<task-notification>' "$report_f" \
    && grep -qF -- '--extract-subagent-response' "$report_f"; then
    ok "AC5: pending integrated-report warns against <task-notification> and names --extract-subagent-response"
  else
    bad "AC5: pending integrated-report missing <task-notification> / --extract-subagent-response guidance"
  fi

  # AC 1: &lt; / &gt; / &amp; are refused on --resume, leaving .response.md and .request intact
  req_snap_dir="$area/req-snap"
  mkdir -p "$req_snap_dir"
  cp "$req_f" "$req_snap_dir/orig.request"

  for entity_tag in lt gt amp; do
    e_char="&${entity_tag};"
    cat > "$resp_f" <<EOF
- Critical: 0
- Important: 0
- Minor: 1
- Finding: tag rendering sample ${e_char} needs review
- verdict: severity=warning failure_scenario=yes confidence=85 file=app.txt line=2
EOF
    cp "$resp_f" "$area/expected-${entity_tag}.response.md"
    run_ma "eg-refuse-${entity_tag}" "${eg_args[@]}" --resume

    if [[ "$RUN_RC" -eq 1 ]] \
      && grep -qF 'claude-code/code-review' "$RUN_ERR" \
      && grep -qF "$resp_f" "$RUN_ERR" \
      && grep -qF -- '--allow-html-entities' "$RUN_ERR"; then
      ok "AC1 (${e_char}): --resume refuses with rc=1 and names perspective and response path"
    else
      bad "AC1 (${e_char}): expected refusal rc=1 naming claude-code/code-review & ${resp_f} (got rc=${RUN_RC})"
    fi

    if cmp -s "$area/expected-${entity_tag}.response.md" "$resp_f" \
      && cmp -s "$req_snap_dir/orig.request" "$req_f" \
      && ! compgen -G "${resp_f%.response.md}.response.rejected.*" >/dev/null \
      && [[ ! -e "$canon_f" ]] \
      && grep -qF 'INCOMPLETE' "$report_f" \
      && grep -qF 'REFUSED' "$report_f" \
      && grep -qF '実体参照' "$report_f"; then
      ok "AC1 (${e_char}): .response.md and .request left intact without adoption; report records refusal"
    else
      bad "AC1 (${e_char}): response/request mutated or adopted unexpectedly"
    fi
  done

  # AC 1 (--sequential --resume): sequential execution also refuses cleanly
  cat > "$resp_f" <<'EOF'
- Critical: 0
- Important: 0
- Finding: sequential entity &lt;span&gt;
- verdict: none
EOF
  cp "$resp_f" "$area/expected-seq.response.md"
  run_ma eg-refuse-seq "${eg_args[@]}" --sequential --resume
  if [[ "$RUN_RC" -eq 1 ]] \
    && grep -qF 'claude-code/code-review' "$RUN_ERR" \
    && grep -qF "$resp_f" "$RUN_ERR" \
    && cmp -s "$area/expected-seq.response.md" "$resp_f" \
    && cmp -s "$req_snap_dir/orig.request" "$req_f"; then
    ok "AC1 (--sequential): refuses entity reference with rc=1 and keeps files intact"
  else
    bad "AC1 (--sequential): failed refusal check (rc=${RUN_RC})"
  fi

  # AC 3 validation: --allow-html-entities requires --delegate-to-host and rejects --route fast
  run_ma eg-allow-no-delegate --task review --mode cross-model --perspective code-review --base develop --cli claude-code --allow-html-entities
  if [[ "$RUN_RC" -eq 2 ]]; then
    ok "AC3: --allow-html-entities without --delegate-to-host exits rc=2"
  else
    bad "AC3: --allow-html-entities without --delegate-to-host expected rc=2 (got ${RUN_RC})"
  fi

  OUT_N=$((OUT_N + 1))
  ext_out="$TMP/out.${OUT_N}.mr-fast-allow"
  ext_err="$TMP/err.${OUT_N}.mr-fast-allow"
  ext_rc=0
  run_isolated PATH="$STUB_PATH" HOME="$TMP/home" \
    FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" bash "$PLUGIN_ROOT/scripts/multi-review.sh" \
    --route fast --allow-html-entities > "$ext_out" 2> "$ext_err" || ext_rc=$?
  if [[ "$ext_rc" -eq 2 ]] && ! grep -qF 'ℹ️  --route fast:' "$ext_err"; then
    ok "AC3: multi-review.sh --route fast --allow-html-entities rejects with rc=2 before banner"
  else
    bad "AC3: multi-review.sh --route fast --allow-html-entities expected rc=2 without banner (got rc=${ext_rc})"
  fi

  # AC 3: --resume --allow-html-entities adopts the intact .response.md containing entities
  run_ma eg-allow-adopt "${eg_args[@]}" --resume --allow-html-entities
  if [[ "$RUN_RC" -eq 0 ]] && [[ -f "$canon_f" ]] && grep -qF '&lt;span&gt;' "$canon_f" && ! grep -qF 'INCOMPLETE' "$report_f"; then
    ok "AC3: --resume --allow-html-entities adopts intact .response.md cleanly (rc=0)"
  else
    bad "AC3: --resume --allow-html-entities failed adoption (rc=${RUN_RC})"
  fi

  # AC 3 via multi-review.sh wrapper
  out_mr="$REPO_PHYS/.review-results-mr"
  mr_args=(--base develop --cli claude-code --perspective code-review --description "entity guard check" --delegate-to-host --output-dir "$out_mr")
  PROMPT_FILE=""
  RESPONSE_FILE=""
  OUT_N=$((OUT_N + 1))
  RUN_OUT="$TMP/out.${OUT_N}.mr-launch"
  RUN_ERR="$TMP/err.${OUT_N}.mr-launch"
  RUN_RC=0
  run_isolated PATH="$STUB_PATH" HOME="$TMP/home" \
    FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" bash "$PLUGIN_ROOT/scripts/multi-review.sh" "${mr_args[@]}" > "$RUN_OUT" 2> "$RUN_ERR" || RUN_RC=$?
  RESPONSE_FILE="$(handoff_field "$RUN_OUT" output-file)"
  if [[ "$RUN_RC" -eq 3 ]] && [[ -n "$RESPONSE_FILE" ]]; then
    ok "AC3 (multi-review.sh): delegated launch produces output-file (rc=3)"
  else
    bad "AC3 (multi-review.sh): delegated launch failed (rc=${RUN_RC})"
  fi
  cat > "$RESPONSE_FILE" <<'EOF'
- Critical: 0
- Important: 0
- Finding: multi-review literal entity &gt; check
- verdict: none
EOF
  OUT_N=$((OUT_N + 1))
  RUN_OUT="$TMP/out.${OUT_N}.mr-allow-resume"
  RUN_ERR="$TMP/err.${OUT_N}.mr-allow-resume"
  RUN_RC=0
  run_isolated PATH="$STUB_PATH" HOME="$TMP/home" \
    FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" bash "$PLUGIN_ROOT/scripts/multi-review.sh" "${mr_args[@]}" --resume --allow-html-entities > "$RUN_OUT" 2> "$RUN_ERR" || RUN_RC=$?
  if [[ "$RUN_RC" -eq 0 ]] && [[ -f "$out_mr/claude-code/code-review.md" ]] && grep -qF '&gt;' "$out_mr/claude-code/code-review.md"; then
    ok "AC3 (multi-review.sh): --resume --allow-html-entities forwards and adopts cleanly"
  else
    bad "AC3 (multi-review.sh): --resume --allow-html-entities failed (rc=${RUN_RC})"
  fi

  # AC 2: normal unescaped < > &quot; bare & adopt cleanly without --allow-html-entities
  out_ac2="$REPO_PHYS/.review-results-ac2"
  PROMPT_FILE=""
  RESPONSE_FILE=""
  run_ma eg-ac2-launch --task review --mode cross-model --perspective code-review --base develop --cli claude-code --delegate-to-host --output-dir "$out_ac2"
  cat > "$RESPONSE_FILE" <<'EOF'
- Critical: 0
- Important: 0
- Finding: verified <html><div>, a < b && c > d, <!-- ok -->, &quot;q&quot;, bare & in prose
- verdict: none
EOF
  run_ma eg-ac2-resume --task review --mode cross-model --perspective code-review --base develop --cli claude-code --delegate-to-host --output-dir "$out_ac2" --resume
  if [[ "$RUN_RC" -eq 0 ]] && [[ -f "$out_ac2/claude-code/code-review.md" ]] && grep -qF '<html><div>' "$out_ac2/claude-code/code-review.md"; then
    ok "AC2: normal < > and bare & adopt cleanly without --allow-html-entities"
  else
    bad "AC2: normal < > adoption unexpectedly failed (rc=${RUN_RC})"
  fi

  # AC 4: --extract-subagent-response across Claude, Antigravity (send_message + content), Grok ACP, Grok Chat, Codex
  fixtures="$area/transcripts"
  mkdir -p "$fixtures"
  python3 -I -B - "$fixtures" <<'PY'
import json
import os
import sys

root = sys.argv[1]

def write_jsonl(name, rows):
    with open(os.path.join(root, name), "w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")

def write_expected(name, text):
    with open(os.path.join(root, name), "w", encoding="utf-8", newline="") as f:
        f.write(text)

# 1. Claude Code: streaming same message.id + multiple text blocks + Japanese & unescaped < > &
claude_b1 = "- Critical: 0\n- Important: 0\n- Finding: Check <html> & a < b"
claude_b2 = "- verdict: none\n  日本語の詳細: `x > 0 && y < 1`\n"
claude_expected = claude_b1 + "\n" + claude_b2
write_expected("claude.expected.md", claude_expected)
write_jsonl("claude.jsonl", [
    {"type": "user", "message": {"role": "user", "content": "Review step 1"}},
    {"type": "assistant", "message": {"id": "m-old", "role": "assistant", "content": [{"type": "tool_use", "id": "t1", "name": "Read", "input": {}}]}},
    {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": "file body"}]}},
    {"type": "user", "isMeta": True, "message": {"role": "user", "content": "meta continuation"}},
    {"type": "assistant", "message": {"id": "m-final", "role": "assistant", "content": [{"type": "thinking", "thinking": "..."}, {"type": "text", "text": claude_b1}]}},
    {"type": "assistant", "message": {"id": "m-final", "role": "assistant", "content": [{"type": "thinking", "thinking": "..."}, {"type": "text", "text": claude_b1}, {"type": "text", "text": claude_b2}]}},
])

# 2. Antigravity send_message: SYSTEM_MESSAGE step 0 (no USER_INPUT), send_message before trailing summary
ag_sm_expected = "- Critical: 0\n- Important: 0\n- Finding: Antigravity <section> & attr=\"1\"\n- verdict: none\n"
write_expected("ag_send_message.expected.md", ag_sm_expected)
write_jsonl("ag_send_message.jsonl", [
    {"step_index": 0, "type": "SYSTEM_MESSAGE", "source": "SYSTEM", "content": "System prompt"},
    {"step_index": 1, "type": "PLANNER_RESPONSE", "status": "DONE", "tool_calls": [{"name": "send_message", "arguments": {"Recipient": "parent", "Message": "stale earlier"}}]},
    {"step_index": 2, "type": "PLANNER_RESPONSE", "status": "DONE", "tool_calls": [{"name": "send_message", "arguments": {"Recipient": "parent", "Message": ag_sm_expected}}]},
    {"step_index": 3, "type": "GENERIC", "content": "message delivered"},
    {"step_index": 4, "type": "PLANNER_RESPONSE", "status": "DONE", "tool_calls": [], "content": "Done sending review."},
])

# 3. Antigravity direct PLANNER_RESPONSE content (no send_message)
ag_content_expected = "- Critical: 0\n- Important: 0\n- verdict: none\n  Note: x < y & z > w"
write_expected("ag_content.expected.md", ag_content_expected)
write_jsonl("ag_content.jsonl", [
    {"step_index": 0, "type": "USER_INPUT", "source": "USER_EXPLICIT", "content": "first"},
    {"step_index": 1, "type": "PLANNER_RESPONSE", "status": "DONE", "content": "earlier reply"},
    {"step_index": 2, "type": "USER_INPUT", "source": "USER_EXPLICIT", "content": "second"},
    {"step_index": 3, "type": "PLANNER_RESPONSE", "status": "DONE", "tool_calls": [], "content": ag_content_expected},
])

# 4. Grok ACP
grok_acp_expected = "- Critical: 0\n- Important: 0\n- Finding: ACP <xml> & value\n- verdict: none"
write_expected("grok_acp.expected.md", grok_acp_expected)
write_jsonl("grok_acp.jsonl", [
    {"params": {"update": {"sessionUpdate": "agent_message_chunk", "content": "draft "}}},
    {"params": {"update": {"sessionUpdate": "tool_call", "name": "read_file"}}},
    {"params": {"update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "- Critical: 0\n- Important: 0\n"}}}},
    {"params": {"update": {"sessionUpdate": "agent_message_chunk", "content": "- Finding: ACP <xml> & value\n- verdict: none"}}},
])

# 5. Grok Chat (ignores synthetic user entry)
grok_chat_expected = "- Critical: 0\n- Important: 0\n- Finding: Chat <elem> & flag\n- verdict: none"
write_expected("grok_chat.expected.md", grok_chat_expected)
write_jsonl("grok_chat.jsonl", [
    {"type": "user", "content": "Start"},
    {"type": "assistant", "content": "thinking", "tool_calls": [{"name": "grep"}]},
    {"type": "tool_result", "content": "ok"},
    {"type": "assistant", "content": "- Critical: 0\n- Important: 0\n- Finding: Chat <elem> & flag"},
    {"type": "user", "synthetic_reason": "continue", "content": "keep going"},
    {"type": "assistant", "content": "- verdict: none"},
])

# 6. Codex rollout
codex_expected = "- Critical: 0\n- Important: 0\n- Finding: Codex <code> & spec\n- verdict: none"
write_expected("codex.expected.md", codex_expected)
write_jsonl("codex.jsonl", [
    {"type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "Review"}]}},
    {"type": "response_item", "payload": {"type": "function_call", "name": "shell"}},
    {"type": "response_item", "payload": {"type": "function_call_output", "output": "ok"}},
    {"type": "response_item", "payload": {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": codex_expected}]}},
])

# Negative fixtures
with open(os.path.join(root, "malformed.jsonl"), "w", encoding="utf-8") as f:
    f.write('{"type": "user"}\n{not json\n')

write_jsonl("claude_unfinished_tool.jsonl", [
    {"type": "user", "message": {"role": "user", "content": "Go"}},
    {"type": "assistant", "message": {"id": "m1", "role": "assistant", "content": [{"type": "text", "text": "hi"}, {"type": "tool_use", "id": "t1", "name": "Read", "input": {}}]}},
])

write_jsonl("ag_truncated.jsonl", [
    {"step_index": 0, "type": "PLANNER_RESPONSE", "status": "DONE", "truncated_fields": ["tool_calls"], "tool_calls": [{"name": "send_message", "arguments": {"Message": "partial"}}]},
])
PY

  local fmt
  for fmt in claude ag_send_message grok_acp grok_chat codex; do
    out_file="$area/out-${fmt}.md"
    OUT_N=$((OUT_N + 1))
    ext_out="$TMP/out.${OUT_N}.ext-${fmt}"
    ext_err="$TMP/err.${OUT_N}.ext-${fmt}"
    ext_rc=0
    run_isolated PATH="$STUB_PATH" HOME="$TMP/home" \
      FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" bash "$MULTI_AGENT" \
      --extract-subagent-response "$fixtures/${fmt}.jsonl" --output-file "$out_file" \
      > "$ext_out" 2> "$ext_err" || ext_rc=$?
    if [[ "$ext_rc" -eq 0 ]] && cmp -s "$fixtures/${fmt}.expected.md" "$out_file"; then
      ok "AC4 (${fmt}): extracted bytes are identical to subagent response"
    else
      bad "AC4 (${fmt}): extraction mismatch or failed (rc=${ext_rc})"
    fi
  done

  # AC 4 via multi-review.sh wrapper using = syntax (ag_content)
  out_file="$area/out-ag_content.md"
  OUT_N=$((OUT_N + 1))
  ext_out="$TMP/out.${OUT_N}.ext-ag-content"
  ext_err="$TMP/err.${OUT_N}.ext-ag-content"
  ext_rc=0
  run_isolated PATH="$STUB_PATH" HOME="$TMP/home" \
    FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" bash "$PLUGIN_ROOT/scripts/multi-review.sh" \
    "--extract-subagent-response=$fixtures/ag_content.jsonl" "--output-file=$out_file" \
    > "$ext_out" 2> "$ext_err" || ext_rc=$?
  if [[ "$ext_rc" -eq 0 ]] && cmp -s "$fixtures/ag_content.expected.md" "$out_file"; then
    ok "AC4 (ag_content via multi-review.sh): extracted bytes match exactly"
  else
    bad "AC4 (ag_content via multi-review.sh): failed (rc=${ext_rc})"
  fi

  # AC 4 end-to-end: extract directly into delegated output-file, then --resume adopts without error
  out_cl="$REPO_PHYS/.review-results-extract-adopt"
  PROMPT_FILE=""
  RESPONSE_FILE=""
  run_ma eg-extract-adopt-launch --task review --mode cross-model --perspective code-review --base develop --cli claude-code --delegate-to-host --output-dir "$out_cl"
  OUT_N=$((OUT_N + 1))
  ext_rc=0
  run_isolated PATH="$STUB_PATH" HOME="$TMP/home" \
    FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" bash "$MULTI_AGENT" \
    --extract-subagent-response "$fixtures/claude.jsonl" --output-file "$RESPONSE_FILE" \
    > "$TMP/out.${OUT_N}.e2e" 2> "$TMP/err.${OUT_N}.e2e" || ext_rc=$?
  run_ma eg-extract-adopt-resume --task review --mode cross-model --perspective code-review --base develop --cli claude-code --delegate-to-host --output-dir "$out_cl" --resume
  if [[ "$ext_rc" -eq 0 ]] && [[ "$RUN_RC" -eq 0 ]] && grep -qF 'Check <html> & a < b' "$out_cl/claude-code/code-review.md"; then
    ok "AC4 (end-to-end): extracted .response.md adopts cleanly via --delegate-to-host --resume"
  else
    bad "AC4 (end-to-end): extract + --resume failed (ext_rc=${ext_rc}, resume_rc=${RUN_RC})"
  fi

  # AC 4 negative fail-closed checks
  eg_expect_extract_fail() {
    local label="$1" expected_rc="$2" forbidden_target="$3" script="$4"
    shift 4
    OUT_N=$((OUT_N + 1))
    ext_out="$TMP/out.${OUT_N}.${label}"
    ext_err="$TMP/err.${OUT_N}.${label}"
    ext_rc=0
    run_isolated PATH="$STUB_PATH" HOME="$TMP/home" \
      FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" bash "$script" "$@" \
      > "$ext_out" 2> "$ext_err" || ext_rc=$?
    if [[ "$ext_rc" -eq "$expected_rc" ]] && [[ -z "$forbidden_target" || ! -e "$forbidden_target" ]]; then
      ok "AC4 negative (${label}): failed closed rc=${ext_rc}"
    else
      bad "AC4 negative (${label}): expected rc=${expected_rc} with no output (got rc=${ext_rc})"
    fi
  }

  bad_out="$area/neg-should-not-exist.md"
  eg_expect_extract_fail "missing-output-file" 2 "" "$MULTI_AGENT" --extract-subagent-response "$fixtures/claude.jsonl"
  eg_expect_extract_fail "missing-extract-flag" 2 "$bad_out" "$MULTI_AGENT" --output-file "$bad_out"
  eg_expect_extract_fail "flag-swallow-guard" 2 "$bad_out" "$MULTI_AGENT" --extract-subagent-response --resume --output-file "$bad_out"
  eg_expect_extract_fail "conflict-resume" 2 "$bad_out" "$MULTI_AGENT" --extract-subagent-response "$fixtures/claude.jsonl" --output-file "$bad_out" --resume
  eg_expect_extract_fail "malformed-json" 1 "$bad_out" "$MULTI_AGENT" --extract-subagent-response "$fixtures/malformed.jsonl" --output-file "$bad_out"
  eg_expect_extract_fail "unfinished-tool-use" 1 "$bad_out" "$MULTI_AGENT" --extract-subagent-response "$fixtures/claude_unfinished_tool.jsonl" --output-file "$bad_out"
  eg_expect_extract_fail "ag-truncated-fields" 1 "$bad_out" "$MULTI_AGENT" --extract-subagent-response "$fixtures/ag_truncated.jsonl" --output-file "$bad_out"

  OUT_N=$((OUT_N + 1))
  ext_rc=0
  run_isolated PATH="$STUB_PATH" HOME="$TMP/home" \
    FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" bash "$PLUGIN_ROOT/scripts/multi-review.sh" \
    --route fast --extract-subagent-response "$fixtures/claude.jsonl" --output-file "$bad_out" \
    > "$TMP/out.${OUT_N}.mr-fast" 2> "$TMP/err.${OUT_N}.mr-fast" || ext_rc=$?
  if [[ "$ext_rc" -eq 2 ]] && [[ ! -e "$bad_out" ]] && ! grep -qF 'ℹ️  --route fast:' "$TMP/err.${OUT_N}.mr-fast"; then
    ok "AC4 negative (multi-review --route fast): rejects with rc=2 before banner"
  else
    bad "AC4 negative (multi-review --route fast): failed guard (rc=${ext_rc})"
  fi

  OUT_N=$((OUT_N + 1))
  ext_rc=0
  run_isolated PATH="$STUB_PATH" HOME="$TMP/home" \
    FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" bash "$PLUGIN_ROOT/scripts/multi-review.sh" \
    --route full --extract-subagent-response "$fixtures/claude.jsonl" --output-file "$bad_out" \
    > "$TMP/out.${OUT_N}.mr-full" 2> "$TMP/err.${OUT_N}.mr-full" || ext_rc=$?
  if [[ "$ext_rc" -eq 2 ]] && [[ ! -e "$bad_out" ]] && ! grep -qF 'ℹ️  --route full:' "$TMP/err.${OUT_N}.mr-full"; then
    ok "AC4 negative (multi-review --route full): rejects with rc=2 before banner"
  else
    bad "AC4 negative (multi-review --route full): failed guard (rc=${ext_rc})"
  fi

  # Symlink guards on both transcript and output-file / ancestors
  link_t="$area/sym-transcript.jsonl"
  ln -s "$fixtures/claude.jsonl" "$link_t"
  eg_expect_extract_fail "symlink-transcript" 1 "$bad_out" "$MULTI_AGENT" --extract-subagent-response "$link_t" --output-file "$bad_out"

  link_dir="$area/sym-dir"
  ln -s "$fixtures" "$link_dir"
  eg_expect_extract_fail "symlink-transcript-dir" 1 "$bad_out" "$MULTI_AGENT" --extract-subagent-response "$link_dir/claude.jsonl" --output-file "$bad_out"
  eg_expect_extract_fail "symlink-output-dir" 1 "" "$MULTI_AGENT" --extract-subagent-response "$fixtures/claude.jsonl" --output-file "$link_dir/should-not-write.md"

  link_out="$area/sym-out.md"
  : > "$area/real-target.md"
  ln -s "$area/real-target.md" "$link_out"
  eg_expect_extract_fail "symlink-output-file" 1 "" "$MULTI_AGENT" --extract-subagent-response "$fixtures/claude.jsonl" --output-file "$link_out"
  if [[ ! -s "$area/real-target.md" ]]; then
    ok "AC4 negative (symlink-output-file): symlink target bytes remain unmodified"
  else
    bad "AC4 negative (symlink-output-file): symlink target was modified"
  fi

  # AC 1: >220KB multiline response with early HTML entity must not fail open via SIGPIPE
  out_sp="$REPO_PHYS/.review-results-sigpipe"
  PROMPT_FILE=""
  RESPONSE_FILE=""
  run_ma eg-sigpipe-launch --task review --mode cross-model --perspective code-review --base develop --cli claude-code --delegate-to-host --output-dir "$out_sp"
  sp_resp="$RESPONSE_FILE"
  sp_canon="$out_sp/claude-code/code-review.md"
  {
    printf '%s\n' '- Critical: 0' '- Important: 0' '- Finding: early entity &lt;script&gt; triggers SIGPIPE guard' '- verdict: severity=warning failure_scenario=yes confidence=85 file=app.txt line=2'
    LC_ALL=C awk 'BEGIN { for (i = 0; i < 4000; i++) printf "padding line %04d: 0123456789abcdef0123456789abcdef0123456789abcdef\n", i }'
  } > "$sp_resp"
  run_ma eg-sigpipe-resume --task review --mode cross-model --perspective code-review --base develop --cli claude-code --delegate-to-host --output-dir "$out_sp" --resume
  if [[ "$RUN_RC" -eq 1 ]] \
    && ! grep -qiF 'broken pipe' "$RUN_ERR" \
    && [[ ! -e "$sp_canon" ]] \
    && grep -qF '&lt;' "$RUN_ERR"; then
    ok "AC1 (large >220KB multiline): refuses early entity without SIGPIPE fail-open"
  else
    bad "AC1 (large >220KB multiline): failed entity refusal or hit SIGPIPE (rc=${RUN_RC})"
  fi

  # AC 1/3: custom --output-dir + --parallel multi-perspective isolation & full retry command execution
  out_par="$REPO_PHYS/.review-results-parallel"
  par_args=(--task review --mode distributed --perspective type-design-analysis --perspective code-simplification --base develop --cli claude-code --delegate-to-host --output-dir "$out_par" --parallel)
  run_ma eg-par-launch "${par_args[@]}"
  par_cr_resp="$(handoff_field "$RUN_OUT" output-file type-design-analysis claude-code)"
  par_bh_resp="$(handoff_field "$RUN_OUT" output-file code-simplification claude-code)"
  retry_cmd=""
  if [[ "$RUN_RC" -eq 3 && -n "$par_cr_resp" && -n "$par_bh_resp" ]]; then
    cat > "$par_bh_resp" <<'EOF'
- Critical: 0
- Important: 0
- Finding: clean sibling <span> response
- verdict: none
EOF
    cat > "$par_cr_resp" <<'EOF'
- Critical: 0
- Important: 1
- Finding: contaminated &lt;div&gt; sibling response
- verdict: severity=warning failure_scenario=yes confidence=85 file=app.txt line=2
EOF
    run_ma eg-par-resume "${par_args[@]}" --resume
    retry_cmd="$(awk '/--allow-html-entities/ && /--resume/ { line=$0 } END { sub(/^[[:space:]]+/, "", line); print line }' "$RUN_ERR")"
  fi
  if [[ "$RUN_RC" -eq 1 ]] \
    && [[ -n "$par_cr_resp" && -n "$par_bh_resp" ]] \
    && [[ -s "$out_par/claude-code/code-simplification.md" ]] \
    && [[ ! -e "$out_par/claude-code/type-design-analysis.md" ]] \
    && grep -qF "$par_cr_resp" "$out_par/integrated-report.md" \
    && ! grep -qF -- '--output-file ...' "$out_par/integrated-report.md" \
    && [[ -n "$retry_cmd" ]] \
    && [[ "$retry_cmd" == *"--output-dir"* ]] \
    && [[ "$retry_cmd" == *"--mode distributed"* ]] \
    && [[ "$retry_cmd" == *"type-design-analysis"* && "$retry_cmd" == *"code-simplification"* ]] \
    && [[ "$retry_cmd" == *"--parallel"* ]]; then
    ok "AC1 (--parallel multi-perspective): adopts clean sibling, prints concrete report path and full retry command"
  else
    bad "AC1 (--parallel multi-perspective): sibling isolation or retry advice incomplete (rc=${RUN_RC})"
  fi

  OUT_N=$((OUT_N + 1))
  par_rc=1
  if [[ -n "$retry_cmd" ]]; then
    par_rc=0
    run_isolated PATH="$STUB_PATH" HOME="$TMP/home" \
      FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" bash -c "$retry_cmd" \
      > "$TMP/out.${OUT_N}.par-retry" 2> "$TMP/err.${OUT_N}.par-retry" || par_rc=$?
  fi
  if [[ "$par_rc" -eq 0 ]] \
    && [[ -s "$out_par/claude-code/type-design-analysis.md" ]] \
    && [[ -s "$out_par/claude-code/code-simplification.md" ]] \
    && grep -qF '&lt;div&gt;' "$out_par/claude-code/type-design-analysis.md"; then
    ok "AC3 (stderr retry command): executing printed retry command completes adoption (rc=0)"
  else
    bad "AC3 (stderr retry command): printed retry command failed (rc=${par_rc})"
  fi

  # AC 4 negative: earlier Antigravity truncated_fields=['tool_calls'] with stripped tool_calls
  printf '%s\n' \
    '{"step_index":0,"type":"USER_INPUT","source":"USER_EXPLICIT","content":"review"}' \
    '{"step_index":1,"type":"PLANNER_RESPONSE","status":"DONE","truncated_fields":["tool_calls"],"tool_calls":[]}' \
    '{"step_index":2,"type":"PLANNER_RESPONSE","status":"DONE","tool_calls":[],"content":"fallback summary"}' \
    > "$fixtures/ag_early_truncated.jsonl"
  eg_expect_extract_fail "ag-early-truncated-tool-calls" 1 "$bad_out" "$MULTI_AGENT" --extract-subagent-response "$fixtures/ag_early_truncated.jsonl" --output-file "$bad_out"

  # AC 4 negative: Grok Chat non-list tool_calls
  printf '%s\n' \
    '{"type":"user","content":"review"}' \
    '{"type":"assistant","tool_calls":"bad","content":"ok"}' \
    > "$fixtures/grok_chat_bad_calls.jsonl"
  eg_expect_extract_fail "grok-chat-nonlist-tool-calls" 1 "$bad_out" "$MULTI_AGENT" --extract-subagent-response "$fixtures/grok_chat_bad_calls.jsonl" --output-file "$bad_out"

  # AC 4 negative: relative --output-file inside a symlinked CWD
  mkdir -p "$area/real-cwd"
  ln -s "$area/real-cwd" "$area/sym-cwd"
  OUT_N=$((OUT_N + 1))
  cwd_out="$area/real-cwd/rel-out.md"
  par_rc=0
  run_isolated PATH="$STUB_PATH" HOME="$TMP/home" \
    FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" bash -c 'cd "$1" && exec bash "$2" --extract-subagent-response "$3" --output-file rel-out.md' _ \
    "$area/sym-cwd" "$MULTI_AGENT" "$fixtures/claude.jsonl" \
    > "$TMP/out.${OUT_N}.sym-cwd" 2> "$TMP/err.${OUT_N}.sym-cwd" || par_rc=$?
  if [[ "$par_rc" -eq 1 ]] && [[ ! -e "$cwd_out" ]]; then
    ok "AC4 negative (symlink-cwd): refuses relative --output-file inside symlinked CWD"
  else
    bad "AC4 negative (symlink-cwd): relative --output-file inside symlinked CWD was not blocked (rc=${par_rc})"
  fi

  # AC 4 negative-false-positive control: option value '--output-file' after --description must not trigger extract guard
  OUT_N=$((OUT_N + 1))
  desc_rc=0
  run_isolated PATH="$STUB_PATH" HOME="$TMP/home" \
    FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" bash "$PLUGIN_ROOT/scripts/multi-review.sh" \
    --route fast --base develop --description --output-file --dry-run \
    > "$TMP/out.${OUT_N}.desc-prescan" 2> "$TMP/err.${OUT_N}.desc-prescan" || desc_rc=$?
  if [[ "$desc_rc" -eq 0 ]] && ! grep -qF 'cannot be combined with' "$TMP/err.${OUT_N}.desc-prescan"; then
    ok "AC4 prescan: multi-review.sh --description --output-file does not trigger extract guard (rc=0)"
  else
    bad "AC4 prescan: multi-review.sh --description --output-file misfired (rc=${desc_rc})"
  fi

  # AC 5: docs-template warns against <task-notification> and documents both CLI flags
  local orch_doc="$PLUGIN_ROOT/docs-template/05-operations/deployment/multi-cli-review-orchestration.md"
  if grep -qF '<task-notification>' "$orch_doc" \
    && grep -qF -- '--extract-subagent-response' "$orch_doc" \
    && grep -qF -- '--allow-html-entities' "$orch_doc"; then
    ok "AC5 (docs): multi-cli-review-orchestration.md documents <task-notification> warning and both flags"
  else
    bad "AC5 (docs): multi-cli-review-orchestration.md missing required guidance"
  fi

  cd "$original" || return 1
}
