# shellcheck shell=bash
# Actual hook entry: full-prefix scope must precede ASDD and detector faults.
CONSUMER_CANDIDATE_CASES=0
candidate_expect() { # <deny|pass> <label> <command> [NAME=VALUE ...]
  local expected="$1" label="$2" command="$3"
  shift 3
  run_hook "$command" "$@"
  if [ "$expected" = deny ]; then assert_fire "$label"; else assert_pass "$label"; fi
  CONSUMER_CANDIDATE_CASES=$((CONSUMER_CANDIDATE_CASES + 1))
}
candidate_raw_expect() { # <deny|pass> <label> <json> <cwd> [NAME=VALUE ...]
  local expected="$1" label="$2" json="$3" cwd="$4"
  shift 4
  ff_asdd_drain_probe "$TARGET" "$json" "$cwd" "$@"
  RC="$FF_ASDD_DRAIN_RC"; OUT="$FF_ASDD_DRAIN_OUT"
  DECISION="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)"
  EVENT="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName // empty' 2>/dev/null || true)"
  REASON="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || true)"
  if [ "$expected" = deny ]; then assert_fire "$label"; else assert_pass "$label"; fi
  CONSUMER_CANDIDATE_CASES=$((CONSUMER_CANDIDATE_CASES + 1))
}
candidate_expect pass 'consumer未宣言の別gateは正常時に素通し' 'make build'
candidate_expect pass 'consumer未宣言の別gateは検出器故障時も素通し' 'make build' FF_EXIT_CODE_AWK=false
candidate_expect pass 'consumer宣言と別のfull prefixは正常時に素通し' 'make build' 'FF_EXIT_CODE_GUARD_GATES=make ci'
candidate_expect pass 'consumer宣言と別のfull prefixは検出器故障時も素通し' 'make build' 'FF_EXIT_CODE_GUARD_GATES=make ci' FF_EXIT_CODE_AWK=false
candidate_expect pass 'consumerの語末lookalikeは故障時も非候補' 'make city' 'FF_EXIT_CODE_GUARD_GATES=make ci' FF_EXIT_CODE_AWK=false
candidate_expect pass 'consumerの語頭lookalikeは故障時も非候補' 'premake ci' 'FF_EXIT_CODE_GUARD_GATES=make ci' FF_EXIT_CODE_AWK=false
candidate_expect pass 'consumerのbash宣言は別のbash引数へ広がらない' 'bash -n foo.sh' 'FF_EXIT_CODE_GUARD_GATES=bash scripts/ci.sh' FF_EXIT_CODE_AWK=false
candidate_expect deny 'consumer自身は検出器故障時にdenyする' 'make ci > log; tail log' 'FF_EXIT_CODE_GUARD_GATES=make ci' FF_EXIT_CODE_AWK=false
candidate_expect deny 'consumerのtabはraw JSON escapeを越えて候補になる' $'make\tci > log; tail log' 'FF_EXIT_CODE_GUARD_GATES=make ci' FF_EXIT_CODE_AWK=false
candidate_expect deny 'consumerのliteral backslashをrawで失わない' 'make\probe ci > log; tail log' 'FF_EXIT_CODE_GUARD_GATES=make\probe ci' FF_EXIT_CODE_AWK=false
candidate_expect pass 'literal backslash-tを語間tabへ変えない' 'make\tci > log; tail log' 'FF_EXIT_CODE_GUARD_GATES=make ci' FF_EXIT_CODE_AWK=false
candidate_expect pass 'consumerの改行は語間spaceへ変えない' $'make\nci > log; tail log' 'FF_EXIT_CODE_GUARD_GATES=make ci' FF_EXIT_CODE_AWK=false
candidate_expect deny 'consumerの複数宣言とwrapperは候補に届く' 'MODE=1 timeout 600 make ci > log; tail log' $'FF_EXIT_CODE_GUARD_GATES=\n pnpm other \n make  ci \n' FF_EXIT_CODE_AWK=false
candidate_expect pass '非候補はstrip故障より前に絞る' 'make build' 'FF_EXIT_CODE_GUARD_GATES=make ci' FF_HEREDOC_AWK=false
candidate_expect deny 'consumer自身はstrip故障でもdenyする' 'make ci > log; tail log' 'FF_EXIT_CODE_GUARD_GATES=make ci' FF_HEREDOC_AWK=false
candidate_expect pass 'heredoc内だけの宣言はcode側で再度絞る' $'make build\ncat <<EOF\nmake ci\nEOF' 'FF_EXIT_CODE_GUARD_GATES=make ci' FF_EXIT_CODE_AWK=false
candidate_json="$(jq -n --arg c $'make\tci > log; tail log' --arg d "$TEST_TMP" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')"
candidate_token='\t'; candidate_replacement='\u0009'
candidate_json="${candidate_json//"$candidate_token"/$candidate_replacement}"
candidate_raw_expect deny 'consumerのJSON unicode tabも候補へ届く' "$candidate_json" "$TEST_TMP" 'FF_EXIT_CODE_GUARD_GATES=make ci' FF_EXIT_CODE_AWK=false
candidate_json="$(jq -n --arg c 'make\probe ci > log; tail log' --arg d "$TEST_TMP" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')"
candidate_token='\\'; candidate_replacement='\u005c'
candidate_json="${candidate_json//"$candidate_token"/$candidate_replacement}"
candidate_raw_expect deny 'consumerのJSON unicode backslashを再解釈しない' "$candidate_json" "$TEST_TMP" 'FF_EXIT_CODE_GUARD_GATES=make\probe ci' FF_EXIT_CODE_AWK=false
candidate_json="$(jq -n --arg c 'bash scripts/ci.sh > log; tail log' --arg d "$TEST_TMP" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')"
candidate_token='/'; candidate_replacement='\/'
candidate_json="${candidate_json//"$candidate_token"/$candidate_replacement}"
candidate_raw_expect deny 'consumerのJSON escaped slashも候補へ届く' "$candidate_json" "$TEST_TMP" 'FF_EXIT_CODE_GUARD_GATES=bash scripts/ci.sh' FF_EXIT_CODE_AWK=false
candidate_expect deny 'consumerのUnicode gateはUTF8入力でも候補へ届く' 'npm run 検証 > log; tail log' 'FF_EXIT_CODE_GUARD_GATES=npm run 検証'
candidate_json="$(jq -an --arg c 'npm run 検証 > log; tail log' '{tool_name:"Bash",tool_input:{command:$c}}')"
candidate_raw_expect deny 'consumerのUnicode gateはJSON ASCII escapeでも候補へ届く' "$candidate_json" "$TEST_TMP" 'FF_EXIT_CODE_GUARD_GATES=npm run 検証'
candidate_expect deny 'consumerのUnicode command名はUTF8入力でも候補へ届く' './検証.sh > log; tail log' 'FF_EXIT_CODE_GUARD_GATES=./検証.sh'
candidate_json="$(jq -an --arg c './検証.sh > log; tail log' '{tool_name:"Bash",tool_input:{command:$c}}')"
candidate_raw_expect deny 'consumerのUnicode command名はJSON ASCII escapeでも候補へ届く' "$candidate_json" "$TEST_TMP" 'FF_EXIT_CODE_GUARD_GATES=./検証.sh'
CANDIDATE_ASDD="$TEST_TMP/candidate-asdd"
CANDIDATE_NODE2="$TEST_TMP/candidate-node2"
mkdir -p "$CANDIDATE_ASDD" "$CANDIDATE_NODE2"
ff_asdd_fixture "$CANDIDATE_ASDD" true
printf '#!/bin/sh\nexit 2\n' > "$CANDIDATE_NODE2/node"
chmod +x "$CANDIDATE_NODE2/node"
for candidate_field in cwd transcript_path; do
  candidate_json="$(jq -n --arg f "$candidate_field" '{tool_name:"Bash",tool_input:{command:"echo hello"}} | .[$f]="make ci"')"
  candidate_raw_expect pass "metadata($candidate_field)だけのprefixはASDD故障でも非候補" "$candidate_json" "$CANDIDATE_ASDD" 'FF_EXIT_CODE_GUARD_GATES=make ci' "PATH=$CANDIDATE_NODE2:$PATH"
done
candidate_json='{"tool_name":"Bash","tool_input":{"command":"make ci > log; tail log"}}'
candidate_raw_expect deny 'consumer自身はASDD故障でdenyする' "$candidate_json" "$CANDIDATE_ASDD" 'FF_EXIT_CODE_GUARD_GATES=make ci' "PATH=$CANDIDATE_NODE2:$PATH"
