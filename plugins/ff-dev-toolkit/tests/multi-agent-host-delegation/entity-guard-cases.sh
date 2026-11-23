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

  # Claude Code Agent output_file symlink into ~/.claude/projects/.../subagents/*.jsonl is resolved
  claude_sub_dir="$TMP/home/.claude/projects/demo-proj/sess-1/subagents"
  mkdir -p "$claude_sub_dir" "$area/tasks"
  cp "$fixtures/claude.jsonl" "$claude_sub_dir/agent-ok.jsonl"
  link_claude_ok="$area/tasks/ok.output"
  ln -s "$claude_sub_dir/agent-ok.jsonl" "$link_claude_ok"
  OUT_N=$((OUT_N + 1))
  out_sym_ok="$area/out-sym-claude-ok.md"
  ext_rc=0
  run_isolated PATH="$STUB_PATH" HOME="$TMP/home" \
    FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" bash "$MULTI_AGENT" \
    --extract-subagent-response "$link_claude_ok" --output-file "$out_sym_ok" \
    > "$TMP/out.${OUT_N}.sym-claude-ok" 2> "$TMP/err.${OUT_N}.sym-claude-ok" || ext_rc=$?
  if [[ "$ext_rc" -eq 0 ]] && [[ -f "$out_sym_ok" ]] && cmp -s "$out_sym_ok" "$fixtures/claude.expected.md"; then
    ok "AC4 (claude-symlink): resolves Claude output_file symlink inside ~/.claude/projects/.../subagents/*.jsonl"
  else
    bad "AC4 (claude-symlink): failed to resolve valid Claude transcript symlink (rc=${ext_rc}, err=$(cat "$TMP/err.${OUT_N}.sym-claude-ok"))"
  fi

  # CLAUDE_CONFIG_DIR/projects/.../subagents/*.jsonl symlink is also resolved
  cfg_dir="$area/custom-claude-cfg"
  cfg_sub_dir="$cfg_dir/projects/demo-proj/sess-2/subagents"
  mkdir -p "$cfg_sub_dir"
  cp "$fixtures/claude.jsonl" "$cfg_sub_dir/agent-cfg.jsonl"
  link_cfg_ok="$area/tasks/cfg.output"
  ln -s "$cfg_sub_dir/agent-cfg.jsonl" "$link_cfg_ok"
  OUT_N=$((OUT_N + 1))
  out_sym_cfg="$area/out-sym-cfg-ok.md"
  ext_rc=0
  run_isolated PATH="$STUB_PATH" HOME="$TMP/home" CLAUDE_CONFIG_DIR="$cfg_dir" \
    FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" bash "$MULTI_AGENT" \
    --extract-subagent-response "$link_cfg_ok" --output-file "$out_sym_cfg" \
    > "$TMP/out.${OUT_N}.sym-cfg-ok" 2> "$TMP/err.${OUT_N}.sym-cfg-ok" || ext_rc=$?
  if [[ "$ext_rc" -eq 0 ]] && [[ -f "$out_sym_cfg" ]] && cmp -s "$out_sym_cfg" "$fixtures/claude.expected.md"; then
    ok "AC4 (claude-symlink): resolves symlink inside CLAUDE_CONFIG_DIR/projects/.../subagents/*.jsonl"
  else
    bad "AC4 (claude-symlink): failed to resolve CLAUDE_CONFIG_DIR transcript symlink (rc=${ext_rc})"
  fi

  # Negative symlink checks: isolate each boundary with valid Claude transcript content and verify stderr says refusing symlink target
  eg_expect_symlink_refusal() {
    local label="$1" extra_cfg="${2:-}" link_path="$3"
    OUT_N=$((OUT_N + 1))
    ext_out="$TMP/out.${OUT_N}.${label}"
    ext_err="$TMP/err.${OUT_N}.${label}"
    ext_rc=0
    if [[ -n "$extra_cfg" ]]; then
      run_isolated PATH="$STUB_PATH" HOME="$TMP/home" CLAUDE_CONFIG_DIR="$extra_cfg" \
        FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" bash "$MULTI_AGENT" \
        --extract-subagent-response "$link_path" --output-file "$bad_out" \
        > "$ext_out" 2> "$ext_err" || ext_rc=$?
    else
      run_isolated PATH="$STUB_PATH" HOME="$TMP/home" \
        FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" bash "$MULTI_AGENT" \
        --extract-subagent-response "$link_path" --output-file "$bad_out" \
        > "$ext_out" 2> "$ext_err" || ext_rc=$?
    fi
    if [[ "$ext_rc" -eq 1 ]] && [[ ! -e "$bad_out" ]] && grep -qF 'refusing symlink target' "$ext_err"; then
      ok "AC4 negative (${label}): refused symlink target (rc=1)"
    else
      bad "AC4 negative (${label}): expected refusing symlink target rc=1 (got rc=${ext_rc}, err=$(cat "$ext_err"))"
    fi
  }

  # 1) Valid subagents/*.jsonl structure + valid Claude transcript, but outside allowed root
  mkdir -p "$area/outside-root/demo-proj/sess-1/subagents"
  cp "$fixtures/claude.jsonl" "$area/outside-root/demo-proj/sess-1/subagents/agent-out.jsonl"
  link_outside_sub="$area/tasks/outside-sub.output"
  ln -s "$area/outside-root/demo-proj/sess-1/subagents/agent-out.jsonl" "$link_outside_sub"
  eg_expect_symlink_refusal "symlink-outside-root-with-subagents-shape" "" "$link_outside_sub"

  # 2) Inside allowed root + valid Claude transcript + .jsonl suffix, but outside subagents/ directory
  cp "$fixtures/claude.jsonl" "$TMP/home/.claude/projects/demo-proj/sess-1/agent-direct.jsonl"
  link_claude_non_sub="$area/tasks/non-sub.output"
  ln -s "$TMP/home/.claude/projects/demo-proj/sess-1/agent-direct.jsonl" "$link_claude_non_sub"
  eg_expect_symlink_refusal "symlink-claude-outside-subagents" "" "$link_claude_non_sub"

  # 3) Inside allowed root + subagents/ + valid Claude transcript, but non-.jsonl suffix
  cp "$fixtures/claude.jsonl" "$claude_sub_dir/agent-bad.json"
  link_claude_bad_ext="$area/tasks/bad-ext.output"
  ln -s "$claude_sub_dir/agent-bad.json" "$link_claude_bad_ext"
  eg_expect_symlink_refusal "symlink-claude-non-jsonl-ext" "" "$link_claude_bad_ext"

  # 4) Relative CLAUDE_CONFIG_DIR is ignored (not accepted as an allowed root)
  eg_expect_symlink_refusal "symlink-relative-claude-config-dir" "relative/claude-cfg" "$link_cfg_ok"

  # 5) Directory target and dangling symlink inside allowed root
  mkdir -p "$claude_sub_dir/not-a-file.jsonl"
  link_claude_dir="$area/tasks/dir.output"
  ln -s "$claude_sub_dir/not-a-file.jsonl" "$link_claude_dir"
  eg_expect_symlink_refusal "symlink-claude-dir-target" "" "$link_claude_dir"

  link_claude_dangling="$area/tasks/dangling.output"
  ln -s "$claude_sub_dir/missing.jsonl" "$link_claude_dangling"
  eg_expect_symlink_refusal "symlink-claude-dangling" "" "$link_claude_dangling"

  # Duplicate --output-file / --extract-subagent-response are rejected (rc=2)
  eg_expect_extract_fail "duplicate-output-file" 2 "$bad_out" "$MULTI_AGENT" --extract-subagent-response "$fixtures/claude.jsonl" --output-file "$bad_out" --output-file "$area/dup-out.md"
  eg_expect_extract_fail "duplicate-extract-flag" 2 "$bad_out" "$MULTI_AGENT" --extract-subagent-response "$fixtures/claude.jsonl" --extract-subagent-response "$fixtures/claude.jsonl" --output-file "$bad_out"

  # Delegated lane release: --extract-subagent-response releases only the matching delegated-review lane (not newer relaunched lanes or symlinks)
  rel_root="$area/release-test-out"
  rel_gen="$rel_root/claude-code/.delegated/generations/g-100-1-0"
  rel_lane_dir="$rel_root/.review-in-flight.d"
  mkdir -p "$rel_gen" "$rel_lane_dir"
  rel_resp_a="$rel_gen/code-review.response.md"
  rel_resp_b="$rel_gen/test-analysis.response.md"
  printf 'pid=$$\ntask=review\n' > "$rel_root/.review-in-flight"
  printf 'writer_pid=1\ntask=subagent-review\nstarted_epoch=1700000000\nperspectives=delegated-review\nagent_id=\noutput_file=%s\n' "$rel_resp_a" > "$rel_lane_dir/lane-a.1700000000.1.lane"
  printf 'writer_pid=1\ntask=subagent-review\nstarted_epoch=1700000000\nperspectives=delegated-review\nagent_id=\noutput_file=%s\n' "$rel_resp_b" > "$rel_lane_dir/lane-b.1700000000.2.lane"
  touch -t 202001010000 "$rel_lane_dir/lane-a.1700000000.1.lane" "$rel_lane_dir/lane-b.1700000000.2.lane"
  printf 'writer_pid=1\ntask=subagent-review\nstarted_epoch=1700000000\nperspectives=pr-review-toolkit:code-reviewer\nagent_id=ag1\n' > "$rel_lane_dir/lane-other.1700000000.3.lane"
  # Symlink decoy carries the exact matching delegated-review/output_file payload so dropping S_ISLNK fails this test.
  printf 'writer_pid=1\ntask=subagent-review\nstarted_epoch=1700000000\nperspectives=delegated-review\nagent_id=\noutput_file=%s\n' "$rel_resp_a" > "$area/decoy.lane"
  ln -s "$area/decoy.lane" "$rel_lane_dir/lane-sym.1700000000.4.lane"
  # Newer lane (future mtime) for the same output_file simulates a relaunch after response write; must stay intact.
  printf 'writer_pid=1\ntask=subagent-review\nstarted_epoch=4070908800\nperspectives=delegated-review\nagent_id=\noutput_file=%s\n' "$rel_resp_a" > "$rel_lane_dir/lane-newer.4070908800.5.lane"
  touch -t 209901010000 "$rel_lane_dir/lane-newer.4070908800.5.lane"
  OUT_N=$((OUT_N + 1))
  ext_rc=0
  run_isolated PATH="$STUB_PATH" HOME="$TMP/home" \
    FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" bash "$MULTI_AGENT" \
    --extract-subagent-response "$fixtures/claude.jsonl" --output-file "$rel_resp_a" \
    > "$TMP/out.${OUT_N}.rel-a" 2> "$TMP/err.${OUT_N}.rel-a" || ext_rc=$?
  if [[ "$ext_rc" -eq 0 ]] \
    && [[ ! -e "$rel_lane_dir/lane-a.1700000000.1.lane" ]] \
    && [[ -f "$rel_lane_dir/lane-b.1700000000.2.lane" ]] \
    && [[ -f "$rel_lane_dir/lane-other.1700000000.3.lane" ]] \
    && [[ -f "$rel_root/.review-in-flight" ]] \
    && [[ -L "$rel_lane_dir/lane-sym.1700000000.4.lane" ]] \
    && [[ -f "$area/decoy.lane" ]] \
    && [[ -f "$rel_lane_dir/lane-newer.4070908800.5.lane" ]]; then
    ok "AC4 (lane-release): extract releases only older matching delegated-review lane and keeps newer/other lanes, locks and symlinks"
  else
    bad "AC4 (lane-release): unexpected lane release state after extracting lane A (rc=${ext_rc})"
  fi
  OUT_N=$((OUT_N + 1))
  ext_rc=0
  run_isolated PATH="$STUB_PATH" HOME="$TMP/home" \
    FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" bash "$MULTI_AGENT" \
    --extract-subagent-response "$fixtures/claude.jsonl" --output-file "$rel_resp_b" \
    > "$TMP/out.${OUT_N}.rel-b" 2> "$TMP/err.${OUT_N}.rel-b" || ext_rc=$?
  if [[ "$ext_rc" -eq 0 ]] \
    && [[ ! -e "$rel_lane_dir/lane-b.1700000000.2.lane" ]] \
    && [[ -f "$rel_lane_dir/lane-other.1700000000.3.lane" ]] \
    && [[ -f "$rel_root/.review-in-flight" ]]; then
    ok "AC4 (lane-release): extracting second perspective releases second delegated-review lane while preserving non-delegated lane and lock"
  else
    bad "AC4 (lane-release): unexpected lane release state after extracting lane B (rc=${ext_rc})"
  fi

  # Boundary checks on the Python extractor helper itself:
  # (a) same-timestamp lane (st_mtime_ns == out_mtime_ns) stays intact (matches strict -nt), while strictly older lane is removed
  # (b) dir_fd + O_NOFOLLOW confined read rejects an intermediate directory swapped to a symlink
  local eq_rc=0 confined_rc=0
  python3 - "$PLUGIN_ROOT/scripts/lib/multi-agent-delegation-state.sh" "$rel_gen/same-mtime.response.md" "$rel_lane_dir" <<'PY' || eq_rc=$?
import os, pathlib, sys
src_text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
marker_start = "python3 -I -B - \"$EXTRACT_SUBAGENT_RESPONSE\" \"$EXTRACT_OUTPUT_FILE\" <<'PY'\n"
marker_end = "\nPY\n}"
i = src_text.index(marker_start) + len(marker_start)
j = src_text.index(marker_end, i)
ns = {"__name__": "extract_unit"}
exec(compile(src_text[i:j], sys.argv[1], "exec"), ns)

resp_path = sys.argv[2]
lane_dir = sys.argv[3]
pathlib.Path(resp_path).write_text("ok\n", encoding="utf-8")
out_ns = os.lstat(resp_path).st_mtime_ns

same_lane = os.path.join(lane_dir, "lane-same.1700000000.6.lane")
older_lane = os.path.join(lane_dir, "lane-older.1700000000.7.lane")
body = f"writer_pid=1\ntask=subagent-review\nstarted_epoch=1700000000\nperspectives=delegated-review\nagent_id=\noutput_file={resp_path}\n"
pathlib.Path(same_lane).write_text(body, encoding="utf-8")
pathlib.Path(older_lane).write_text(body, encoding="utf-8")
os.utime(same_lane, ns=(out_ns, out_ns))
os.utime(older_lane, ns=(out_ns - 2_000_000_000, out_ns - 2_000_000_000))
assert os.lstat(same_lane).st_mtime_ns == out_ns, "same_lane mtime setup mismatch"
assert os.lstat(older_lane).st_mtime_ns < out_ns, "older_lane mtime setup mismatch"

ns["release_completed_delegated_lane"](resp_path, out_ns)
assert os.path.exists(same_lane), "same-mtime lane was erroneously removed"
assert not os.path.exists(older_lane), "strictly older lane was not removed"
PY
  if [[ "$eq_rc" -eq 0 ]]; then
    ok "AC4 (lane-release same-mtime): preserves lane with st_mtime_ns == out_mtime_ns and removes strictly older lane"
  else
    bad "AC4 (lane-release same-mtime): boundary check failed (rc=${eq_rc})"
  fi

  python3 - "$PLUGIN_ROOT/scripts/lib/multi-agent-delegation-state.sh" "$area" "$fixtures/claude.jsonl" <<'PY' || confined_rc=$?
import io, os, pathlib, sys
src_text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
marker_start = "python3 -I -B - \"$EXTRACT_SUBAGENT_RESPONSE\" \"$EXTRACT_OUTPUT_FILE\" <<'PY'\n"
marker_end = "\nPY\n}"
i = src_text.index(marker_start) + len(marker_start)
j = src_text.index(marker_end, i)
ns = {"__name__": "extract_unit"}
exec(compile(src_text[i:j], sys.argv[1], "exec"), ns)

area = pathlib.Path(sys.argv[2])
outside_dir = area / "swap-outside"
outside_dir.mkdir(parents=True, exist_ok=True)
(outside_dir / "agent-swap.jsonl").write_text(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8"), encoding="utf-8")
swap_root = area / "swap-root"
(swap_root / "demo-proj" / "sess-1").mkdir(parents=True, exist_ok=True)
os.symlink(str(outside_dir), str(swap_root / "demo-proj" / "sess-1" / "subagents"))

buf = io.StringIO()
orig_err = sys.stderr
sys.stderr = buf
try:
    try:
        ns["read_regular_utf8_confined"](swap_root, pathlib.Path("demo-proj/sess-1/subagents/agent-swap.jsonl"), "swapped.output")
        raise AssertionError("expected confined read to fail on intermediate symlink")
    except SystemExit as exc:
        assert exc.code == 1, f"unexpected exit code: {exc.code}"
finally:
    sys.stderr = orig_err
assert "refusing symlink target" in buf.getvalue(), f"unexpected stderr: {buf.getvalue()}"
PY
  if [[ "$confined_rc" -eq 0 ]]; then
    ok "AC4 (claude-symlink confined): dir_fd + O_NOFOLLOW rejects intermediate symlink directory swap"
  else
    bad "AC4 (claude-symlink confined): confined read did not reject intermediate symlink (rc=${confined_rc})"
  fi

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
