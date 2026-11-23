#!/usr/bin/env bash
# finish/verify.sh から呼ぶ、専用セキュリティゲートの記録の検査（Issue `#2684`）。
# セキュリティに関わる変更（判定不能を含む）の PR は、本文に「専用セキュリティゲート: … 実施 / 未確認 / 未対応」
# の行が無ければ precheck が止める。再現の入力は、記録が落ちたままマージされた実際の PR の形にそろえる
# （変更ファイルが OAuth の検証で、本文に経路の行はあるがゲートの行が無い）。
# 記録の無い fixture なので、止まらない回は rc 2（PRECHECK=undetermined）+ MERGE_COMMAND になる。

_ff_sr_passed() { # rc 2 + undetermined + MERGE_COMMAND = この検査では止めていない（鮮度の記録不在の fixture）
  [ "$RC" -eq 2 ] && has_line "$OUT" "PRECHECK=undetermined" && has_text "$OUT" "MERGE_COMMAND_BEGIN" && ! has_line "$OUT" "PRECHECK=blocked"
}
_ff_sr_stopped() { # rc 1 + blocked + missing + MERGE_COMMAND なし
  [ "$RC" -eq 1 ] && has_line "$OUT" "PRECHECK=blocked" && has_line "$OUT" "SECURITY_RECORD_GATE=missing" \
    && ! has_text "$OUT" "MERGE_COMMAND_BEGIN" && has_text "$ERR" "専用セキュリティゲートの記録行" \
    && has_text "$ERR" "未確認（<理由>）"
}

_ff_finish_security_record_cases() {
  local sr="$TMP/security-record" body line
  local auth_files='[{"path":"plugins/media/scripts/lib/oauth-browser.mjs"},{"path":"docs/a.md"}]'
  local route_line='経路: full（claude-code 4 観点 + codex-cli comprehensive-review）。Critical 0。'
  mkdir -p "$sr"

  echo
  echo "== R. 専用セキュリティゲートの記録 =="
  # ── 該当 + 記録なし（OAuth の検証を変えて記録が落ちた PR の形）──
  PR_FILES_JSON="$auth_files"
  write_pr_json "$(printf '%s\n' "Closes #${PRN}" '' '## セルフレビュー結果' "$route_line")" '[]'
  run_finish "$WORK" precheck 7
  if _ff_sr_stopped && has_line "$OUT" "SECURITY_SENSITIVE=yes" \
    && has_line "$OUT" "SECURITY_EVIDENCE=plugins/media/scripts/lib/oauth-browser.mjs" && ! has_line "$OUT" "SECURITY_EVIDENCE=docs/a.md" \
    && has_text "$ERR" "根拠: plugins/media/scripts/lib/oauth-browser.mjs" && has_text "$ERR" "MULTI_AGENT_SECURITY_REVIEW=off"; then
    ok "R1: セキュリティに関わる変更で本文に記録行が無い PR は rc 1 で止め、根拠の path と書く形を出す（記録が落ちた実 PR の形）"
  else
    bad "R1: 記録の無い該当 PR で止まっていない（rc=${RC}）: ${OUT} / ${ERR}"
  fi

  # ── 記録として認める形 ──
  for line in \
    '- 専用セキュリティゲート: /security-review 実施（指摘 0 件）' \
    '- 専用セキュリティゲート: Codex Security security-diff-scan 実施（指摘 1 件 → 修正済み）' \
    '専用セキュリティゲート: grok-cli セッション内レビュー実施（指摘 0 件）' \
    '- **専用セキュリティゲート**：未確認（glob の誤検知と判断: checkout は git の checkout）' \
    '- 専用セキュリティゲート: 未対応（主担当 unknown。根拠: x）'; do
    write_pr_json "$(printf '%s\n' "Closes #${PRN}" '' "$route_line" "$line")" '[]'
    run_finish "$WORK" precheck 7
    if _ff_sr_passed && has_line "$OUT" "SECURITY_RECORD_GATE=recorded" && has_line "$OUT" "SECURITY_RECORD=${line}"; then
      ok "R2: 記録行「${line}」は認めて、この検査では止めない"
    else
      bad "R2: 記録行「${line}」を認めていない（rc=${RC}）: ${OUT} / ${ERR}"
    fi
  done

  # ── 記録として認めない形 ──
  for line in \
    '- 専用セキュリティゲート: 対象外（該当変更なし）' \
    '- 専用セキュリティゲート: /security-review を実行する（根拠: plugins/media/scripts/lib/oauth-browser.mjs）' \
    '- 専用セキュリティゲートを実施（指摘 0 件）' \
    '- 専用セキュリティゲート: 指摘 0 件' \
    '<!-- 専用セキュリティゲート: /security-review 実施（指摘 N 件） -->' \
    '- 専用セキュリティゲート: 対象外（docs のみのため実施せず）' \
    '- 専用セキュリティゲート: 未実施（時間切れ）' \
    '- 専用セキュリティゲート: 実施しない（対象外と判断）' \
    '- 専用セキュリティゲート: /security-review を実施する' \
    '- 専用セキュリティゲート: 実施予定' \
    '- 専用セキュリティゲート: /security-review を実行する（根拠: src/auth/未確認.ts）' \
    'precheck が `専用セキュリティゲート: … 実施` の行を確かめる' \
    '書く形の例 `専用セキュリティゲート: /security-review 実施（指摘 N 件）`'; do
    write_pr_json "$(printf '%s\n' "Closes #${PRN}" '' "$route_line" "$line")" '[]'
    run_finish "$WORK" precheck 7
    if _ff_sr_stopped && ! has_line "$OUT" "SECURITY_RECORD="; then
      ok "R3: 「${line}」は記録に数えず止める"
    else
      bad "R3: 「${line}」を記録として通している（rc=${RC}）: ${OUT} / ${ERR}"
    fi
  done
  body="$(printf '%s\n' "Closes #${PRN}" '' '```text' '専用セキュリティゲート: /security-review 実施（指摘 0 件）' '```')"
  write_pr_json "$body" '[]'
  run_finish "$WORK" precheck 7
  if _ff_sr_stopped; then
    ok "R3b: フェンスの中の記入例は記録に数えない"
  else
    bad "R3b: フェンスの中の行を記録として通している（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  # 引用の中のフェンス（可視行の抽出は `> ` 付きのフェンスを認識しない）と、引用の中の行
  body="$(printf '%s\n' "Closes #${PRN}" '' '> ```text' '> 専用セキュリティゲート: /security-review 実施（指摘 N 件）' '> ```')"
  write_pr_json "$body" '[]'
  run_finish "$WORK" precheck 7
  if _ff_sr_stopped; then
    ok "R3d: 引用の中のフェンスに置いた記入例は記録に数えない"
  else
    bad "R3d: 引用の中のフェンスの行を記録として通している（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  # 記録行の後ろに長い本文が続く PR（パイプのバッファ 64KB を超える）。最初の一致で読むのをやめると
  # 上流が SIGPIPE で落ち、pipefail で一致を失う
  body="$(printf '%s\n' "Closes #${PRN}" '' '- 専用セキュリティゲート: /security-review 実施（指摘 0 件）'
    i=0; while [ "$i" -lt 1500 ]; do printf '| 行 %d | 本文を長くするための説明の文字列を並べる |\n' "$i"; i=$((i + 1)); done)"
  local body_bytes
  body_bytes="$(printf '%s' "$body" | wc -c | tr -d ' ')"
  write_pr_json "$body" '[]'
  run_finish "$WORK" precheck 7
  if [ "$body_bytes" -gt 65536 ] && _ff_sr_passed && has_line "$OUT" "SECURITY_RECORD_GATE=recorded"; then
    ok "R2b: 記録行の後ろに 64KB を超える本文が続いても記録を落とさない（本文 ${body_bytes} B）"
  else
    bad "R2b: 長い本文で記録を落としている（本文 ${body_bytes} B、rc=${RC}）: $(printf '%s\n' "$OUT" | grep '^SECURITY_') / ${ERR}"
  fi
  # CRLF の本文（GitHub の Web 編集）でも同じ行を認める
  write_pr_json "$(printf 'Closes #%s\r\n\r\n- 専用セキュリティゲート: /security-review 実施（指摘 0 件）\r\n' "$PRN")" '[]'
  run_finish "$WORK" precheck 7
  if _ff_sr_passed && has_line "$OUT" "SECURITY_RECORD_GATE=recorded"; then
    ok "R3c: CRLF の本文の記録行も認める"
  else
    bad "R3c: CRLF の本文で記録行を落としている（rc=${RC}）: ${OUT} / ${ERR}"
  fi

  # ── 該当なし・無効化 ──
  PR_FILES_JSON='[{"path":"x.txt"},{"path":"docs/a.md"}]'
  write_pr_json "Closes #${PRN}" '[]'
  run_finish "$WORK" precheck 7
  if _ff_sr_passed && has_line "$OUT" "SECURITY_SENSITIVE=no" && has_line "$OUT" "SECURITY_RECORD_GATE=not-required" \
    && ! has_line "$OUT" "SECURITY_EVIDENCE="; then
    ok "R4: 該当しない変更は記録行が無くても止めない"
  else
    bad "R4: 該当しない変更で記録を求めている（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  PR_FILES_JSON="$auth_files"
  write_pr_json "Closes #${PRN}" '[]'
  MULTI_AGENT_SECURITY_REVIEW=off run_finish "$WORK" precheck 7
  if _ff_sr_passed && has_line "$OUT" "SECURITY_SENSITIVE=yes" && has_line "$OUT" "SECURITY_RECORD_GATE=off"; then
    ok "R5: security_review=off（env）の導入先は記録を求めない（判定と根拠は出す）"
  else
    bad "R5: off で記録を求めている（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  if command -v yq >/dev/null 2>&1; then
    printf '%s\n' 'review:' '  security_review: "off"' >"$sr/off.yaml"
    MULTI_AGENT_CONFIG="$sr/off.yaml" run_finish "$WORK" precheck 7
    if _ff_sr_passed && has_line "$OUT" "SECURITY_RECORD_GATE=off"; then
      ok "R5b: プロジェクト設定の review.security_review: \"off\" でも記録を求めない"
    else
      bad "R5b: プロジェクト設定の off が効いていない（rc=${RC}）: ${OUT} / ${ERR}"
    fi
  else
    echo "  - R5b: yq が無い環境なので省略（設定の読み取りは security-review-gate suite が固定する）"
  fi

  # ── 判定不能は該当なしへ倒さない ──
  MULTI_AGENT_CONFIG="$sr/absent.yaml" run_finish "$WORK" precheck 7
  if _ff_sr_stopped && has_line "$OUT" "SECURITY_SENSITIVE=unknown" && has_text "$ERR" "判定できません" \
    && has_line "$OUT" "SECURITY_UNKNOWN_REASON=判定不能: MULTI_AGENT_CONFIG の設定ファイルがありません"; then
    ok "R6: 設定を読めない（明示した設定ファイルが無い）回は unknown として記録を求める"
  else
    bad "R6: 設定を読めない回を素通りさせている（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  local keep_head="$HEAD_OID"
  PR_FILES_JSON="$(jq -cn '[range(0;100) | {path: "decoy/\(.).txt"}]')"
  HEAD_OID="$(printf '%040d' 7)"
  write_pr_json "Closes #${PRN}" '[]'
  HEAD_OID="$keep_head"
  run_finish "$WORK" precheck 7
  if [ "$RC" -eq 1 ] && has_line "$OUT" "SECURITY_SENSITIVE=unknown" && has_line "$OUT" "SECURITY_RECORD_GATE=missing" \
    && has_text "$OUT" "SECURITY_UNKNOWN_REASON=PR の変更ファイルを読めません" && has_text "$ERR" "git fetch origin develop"; then
    ok "R6b: 100 件の一覧で差分を読み直せない回は unknown として記録を求める（一覧の 100 件で判定しない）"
  else
    bad "R6b: 読めない変更ファイルを該当なしへ倒している（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  HEAD_OID="$(printf '%040d' 7)"
  write_pr_json "$(printf '%s\n' "Closes #${PRN}" '' '- 専用セキュリティゲート: 未確認（変更ファイルを読めない）')" '[]'
  HEAD_OID="$keep_head"
  run_finish "$WORK" precheck 7
  if has_line "$OUT" "SECURITY_SENSITIVE=unknown" && has_line "$OUT" "SECURITY_RECORD_GATE=recorded" && ! has_line "$OUT" "PRECHECK=blocked"; then
    ok "R6c: unknown の回も「未確認（理由）」の記録で通る"
  else
    bad "R6c: unknown の回に記録の逃げ道が無い（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  HEAD_OID="$(printf '%040d' 7)"
  write_pr_json "Closes #${PRN}" '[]'
  HEAD_OID="$keep_head"
  MULTI_AGENT_SECURITY_REVIEW=off run_finish "$WORK" precheck 7
  if has_line "$OUT" "SECURITY_SENSITIVE=unknown" && has_line "$OUT" "SECURITY_RECORD_GATE=off" && ! has_line "$OUT" "PRECHECK=blocked" \
    && has_text "$OUT" "SECURITY_UNKNOWN_REASON=PR の変更ファイルを読めません" && ! has_text "$ERR" "変更ファイル"; then
    ok "R6d: 変更ファイルを読めない回も security_review=off は効く"
  else
    bad "R6d: 読めない回に off を無視している（rc=${RC}）: ${OUT} / ${ERR}"
  fi

  # 変更 0 件（API の一覧が空で、git の差分も空）は該当なしへ倒さない
  HEAD_OID="$BASE_OID"
  PR_FILES_JSON='[]'
  write_pr_json "Closes #${PRN}" '[]'
  HEAD_OID="$keep_head"
  run_finish "$WORK" precheck 7
  if [ "$RC" -eq 1 ] && has_line "$OUT" "SECURITY_SENSITIVE=unknown" && has_line "$OUT" "SECURITY_UNKNOWN_REASON=PR の変更ファイルが 0 件です" \
    && has_line "$OUT" "SECURITY_RECORD_GATE=missing"; then
    ok "R6e: 変更ファイルが 0 件の回は unknown として記録を求める"
  else
    bad "R6e: 変更 0 件を該当なしへ倒している（rc=${RC}）: ${OUT} / ${ERR}"
  fi

  # ── API の上限（100 件）で切れた一覧は git の差分で読み直す ──
  # fixture の差分（origin/develop...HEAD）は x.txt だけ。x.txt を該当パターンに足し、一覧の 100 件には無い
  PR_FILES_JSON="$(jq -cn '[range(0;100) | {path: "decoy/\(.).txt"}]')"
  write_pr_json "Closes #${PRN}" '[]'
  MULTI_AGENT_SECURITY_GLOB_EXTRA='x.txt' run_finish "$WORK" precheck 7
  if _ff_sr_stopped && has_line "$OUT" "SECURITY_SENSITIVE=yes" && has_line "$OUT" "SECURITY_EVIDENCE=x.txt"; then
    ok "R7: API の一覧が 100 件の回は git の差分で読み直し、101 件目以降の該当で記録を求める"
  else
    bad "R7: 切り詰めの回に該当を落としている（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  PR_FILES_JSON="$(jq -cn '[range(0;99) | {path: "decoy/\(.).txt"}]')"
  write_pr_json "Closes #${PRN}" '[]'
  MULTI_AGENT_SECURITY_GLOB_EXTRA='x.txt' run_finish "$WORK" precheck 7
  if _ff_sr_passed && has_line "$OUT" "SECURITY_RECORD_GATE=not-required"; then
    ok "R7b: 対照: 99 件（上限未満）の一覧は全件として読み、git の差分を足さない"
  else
    bad "R7b: 上限未満の一覧で git の差分を読んでいる（rc=${RC}）: ${OUT} / ${ERR}"
  fi

  # ── 停止理由の先着 ──
  PR_FILES_JSON="$auth_files"
  write_pr_json "Closes #${PRN}" '[]'
  printf '%s\n' '# 背景' '- [ ] まだ' >"$sr/unchecked.md"
  STUB_ISSUE_BODY_FILE="$sr/unchecked.md" run_finish "$WORK" precheck 7
  if [ "$RC" -eq 1 ] && has_line "$OUT" "SECURITY_RECORD_GATE=missing" && has_text "$ERR" "未チェックの受け入れ条件" \
    && has_text "$ERR" "／さらにセキュリティに関わる変更"; then
    ok "R8: 先に決まった停止理由（未チェック AC）を上書きせず、記録の欠落を併記する（1 回の再実行で両方を直せる）"
  else
    bad "R8: 停止理由の先着が崩れている（rc=${RC}）: ${OUT} / ${ERR}"
  fi

  # ── R9〜R14: PR 作成前の単体入口（finish.sh security-record。Issue `#2875`） ──
  echo
  echo "== R-CLI. PR 作成前の専用セキュリティゲート記録確認（finish.sh security-record） =="
  local sr_origin="$sr/cli-origin.git" sr_work="$sr/cli-work" sr_body="$sr/body.md"
  local sr_auth_head="" sr_plain_head="" sr_base_oid=""
  local keep_head2="$HEAD_OID" keep_base2="$BASE_OID" keep_head_ref2="${PR_HEAD_REF:-}"
  g init -q --bare "$sr_origin" >/dev/null 2>&1
  g clone -q "$sr_origin" "$sr_work" >/dev/null 2>&1
  ( cd "$sr_work" \
    && printf 'seed\n' >seed.txt && g add seed.txt >/dev/null 2>&1 && g commit -qm seed >/dev/null 2>&1 \
    && g push -q origin develop >/dev/null 2>&1 \
    && g checkout -q -b 'feature/#7-sr-auth' >/dev/null 2>&1 \
    && mkdir -p plugins/media/scripts/lib docs \
    && printf 'oauth\n' >plugins/media/scripts/lib/oauth-browser.mjs \
    && printf 'doc\n' >docs/a.md \
    && g add -A >/dev/null 2>&1 && g commit -qm 'feat: auth change' >/dev/null 2>&1 \
    && g push -q -u origin 'feature/#7-sr-auth' >/dev/null 2>&1 \
    && g checkout -q develop >/dev/null 2>&1 \
    && g checkout -q -b 'feature/#7-sr-plain' >/dev/null 2>&1 \
    && mkdir -p docs && printf 'plain\n' >x.txt && printf 'doc\n' >docs/a.md \
    && g add -A >/dev/null 2>&1 && g commit -qm 'chore: plain change' >/dev/null 2>&1 \
    && g push -q -u origin 'feature/#7-sr-plain' >/dev/null 2>&1 \
    && g checkout -q develop >/dev/null 2>&1 \
    && g checkout -q -b 'feature/#7-sr-empty' >/dev/null 2>&1 \
    && g checkout -q 'feature/#7-sr-auth' >/dev/null 2>&1 )
  g -C "$sr_work" remote set-head origin develop >/dev/null 2>&1
  sr_base_oid="$(g -C "$sr_work" rev-parse origin/develop)"
  sr_auth_head="$(g -C "$sr_work" rev-parse 'feature/#7-sr-auth')"
  sr_plain_head="$(g -C "$sr_work" rev-parse 'feature/#7-sr-plain')"

  _ff_sr_extract() {
    printf '%s\n' "$1" | awk '/^SECURITY_(SENSITIVE|EVIDENCE|RECORD_GATE|RECORD)=/ { print }'
  }

  # R9: gh も jq も使わず PR 番号なしで判定できる
  printf '%s\n' "Closes #${PRN}" '' '## セルフレビュー結果' "$route_line" >"$sr_body"
  : >"$STUB_LOG"
  run_finish "$sr_work" security-record --body-file "$sr_body" --base origin/develop
  if [ "$RC" -eq 1 ] && [ ! -s "$STUB_LOG" ] && has_line "$OUT" "SECURITY_SENSITIVE=yes" \
    && has_line "$OUT" "SECURITY_EVIDENCE=plugins/media/scripts/lib/oauth-browser.mjs" \
    && has_line "$OUT" "SECURITY_RECORD_GATE=missing" \
    && has_text "$ERR" "finish.sh security-record"; then
    ok "R9: security-record は gh を呼ばず PR 番号なしで missing を rc 1 で返す"
  else
    bad "R9: security-record の missing 判定が違う（rc=${RC} log=$(cat "$STUB_LOG")）: ${OUT} / ${ERR}"
  fi

  # R10: 同じ本文・同じ差分で precheck と security-record の SECURITY_* 判定が完全一致する
  local cli_out="" cli_rc=0 pre_out="" pre_fields="" cli_fields="" case_label="" case_body=""
  HEAD_OID="$sr_auth_head"
  BASE_OID="$sr_base_oid"
  PR_HEAD_REF='feature/#7-sr-auth'
  PR_FILES_JSON="$auth_files"
  for case_label in recorded_exec recorded_unverified recorded_unsupported missing_plan missing_fence missing_comment missing_quote_fence missing_not_done; do
    case "$case_label" in
      recorded_exec) case_body="$(printf '%s\n' "Closes #${PRN}" '' '- 専用セキュリティゲート: /security-review 実施（指摘 0 件）')" ;;
      recorded_unverified) case_body="$(printf '%s\n' "Closes #${PRN}" '' '- **専用セキュリティゲート**：未確認（理由あり）')" ;;
      recorded_unsupported) case_body="$(printf '%s\n' "Closes #${PRN}" '' '- 専用セキュリティゲート: 未対応（主担当 unknown）')" ;;
      missing_plan) case_body="$(printf '%s\n' "Closes #${PRN}" '' '- 専用セキュリティゲート: /security-review を実行する（根拠: plugins/media/scripts/lib/oauth-browser.mjs）')" ;;
      missing_fence) case_body="$(printf '%s\n' "Closes #${PRN}" '' '```text' '専用セキュリティゲート: /security-review 実施（指摘 0 件）' '```')" ;;
      missing_comment) case_body="$(printf '%s\n' "Closes #${PRN}" '' '<!-- 専用セキュリティゲート: /security-review 実施（指摘 0 件） -->')" ;;
      missing_quote_fence) case_body="$(printf '%s\n' "Closes #${PRN}" '' '> ```text' '> 専用セキュリティゲート: /security-review 実施（指摘 0 件）' '> ```')" ;;
      missing_not_done) case_body="$(printf '%s\n' "Closes #${PRN}" '' '- 専用セキュリティゲート: 未実施（時間切れ）')" ;;
    esac
    printf '%s\n' "$case_body" >"$sr_body"
    write_pr_json "$case_body" '[]'
    run_finish "$sr_work" precheck 7
    pre_out="$OUT"
    run_finish "$sr_work" security-record --body-file "$sr_body" --base origin/develop
    cli_out="$OUT"; cli_rc="$RC"
    pre_fields="$(_ff_sr_extract "$pre_out")"
    cli_fields="$(_ff_sr_extract "$cli_out")"
    local expect_rc=1
    case "$case_label" in recorded_*) expect_rc=0 ;; esac
    if [ "$cli_rc" -eq "$expect_rc" ] && [ -n "$pre_fields" ] && [ "$pre_fields" = "$cli_fields" ]; then
      ok "R10/${case_label}: security-record と precheck の判定が完全一致（rc=${cli_rc}）"
    else
      bad "R10/${case_label}: precheck と食い違い（rc=${cli_rc} expect=${expect_rc}）pre=[${pre_fields}] cli=[${cli_fields}]"
    fi
  done

  # R10b: off（env）でも precheck と完全一致し rc 0
  printf '%s\n' "Closes #${PRN}" >"$sr_body"
  write_pr_json "Closes #${PRN}" '[]'
  MULTI_AGENT_SECURITY_REVIEW=off run_finish "$sr_work" precheck 7
  pre_fields="$(_ff_sr_extract "$OUT")"
  MULTI_AGENT_SECURITY_REVIEW=off run_finish "$sr_work" security-record --body-file "$sr_body" --base origin/develop
  cli_fields="$(_ff_sr_extract "$OUT")"
  if [ "$RC" -eq 0 ] && [ "$pre_fields" = "$cli_fields" ] && has_line "$OUT" "SECURITY_RECORD_GATE=off"; then
    ok "R10b: security_review=off でも security-record と precheck が一致し rc 0"
  else
    bad "R10b: off で不一致（rc=${RC}）pre=[${pre_fields}] cli=[${cli_fields}]"
  fi

  # R10c: 該当なしブランチでも precheck と完全一致し rc 0
  g -C "$sr_work" checkout -q 'feature/#7-sr-plain' >/dev/null 2>&1
  HEAD_OID="$sr_plain_head"
  PR_HEAD_REF='feature/#7-sr-plain'
  PR_FILES_JSON='[{"path":"x.txt"},{"path":"docs/a.md"}]'
  write_pr_json "Closes #${PRN}" '[]'
  run_finish "$sr_work" precheck 7
  pre_fields="$(_ff_sr_extract "$OUT")"
  run_finish "$sr_work" security-record --body-file "$sr_body" --base origin/develop
  cli_fields="$(_ff_sr_extract "$OUT")"
  if [ "$RC" -eq 0 ] && [ "$pre_fields" = "$cli_fields" ] && has_line "$OUT" "SECURITY_RECORD_GATE=not-required"; then
    ok "R10c: 該当なしブランチでも security-record と precheck が一致し rc 0"
  else
    bad "R10c: 該当なしで不一致（rc=${RC}）pre=[${pre_fields}] cli=[${cli_fields}]"
  fi

  # R11: --base 省略時は WORKFLOW_TIER_BASE → origin/HEAD → origin/develop の順に使う
  g -C "$sr_work" checkout -q 'feature/#7-sr-auth' >/dev/null 2>&1
  run_finish "$sr_work" security-record --body-file "$sr_body"
  if [ "$RC" -eq 1 ] && has_line "$OUT" "SECURITY_SENSITIVE=yes" && has_line "$OUT" "SECURITY_RECORD_GATE=missing"; then
    ok "R11: --base 省略時は origin/HEAD から差分を判定する"
  else
    bad "R11: --base 省略時の判定が違う（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  WORKFLOW_TIER_BASE="nonexistent-tier-base" run_finish "$sr_work" security-record --body-file "$sr_body"
  if [ "$RC" -eq 1 ] && has_line "$OUT" "SECURITY_SENSITIVE=unknown" && has_text "$OUT" "nonexistent-tier-base...HEAD"; then
    ok "R11b: --base 省略時は WORKFLOW_TIER_BASE を origin/HEAD より優先する"
  else
    bad "R11b: WORKFLOW_TIER_BASE の優先が効いていない（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  g -C "$sr_work" remote set-head origin -d >/dev/null 2>&1
  run_finish "$sr_work" security-record --body-file "$sr_body"
  if [ "$RC" -eq 1 ] && has_line "$OUT" "SECURITY_SENSITIVE=yes" && has_line "$OUT" "SECURITY_RECORD_GATE=missing"; then
    ok "R11c: origin/HEAD 不在かつ --base 省略時は origin/develop へフォールバックする"
  else
    bad "R11c: origin/develop フォールバックが効いていない（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  g -C "$sr_work" remote set-head origin develop >/dev/null 2>&1

  # R12: 分類できない回（変更 0 件・解決できない --base）は unknown として記録を求める
  g -C "$sr_work" checkout -q 'feature/#7-sr-empty' >/dev/null 2>&1
  run_finish "$sr_work" security-record --body-file "$sr_body" --base origin/develop
  if [ "$RC" -eq 1 ] && has_line "$OUT" "SECURITY_SENSITIVE=unknown" && has_line "$OUT" "SECURITY_RECORD_GATE=missing"; then
    ok "R12a: 変更 0 件は unknown として記録を求める（rc 1）"
  else
    bad "R12a: 変更 0 件を該当なしへ倒している（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  printf '%s\n' '- 専用セキュリティゲート: 未確認（変更 0 件）' >"$sr_body"
  run_finish "$sr_work" security-record --body-file "$sr_body" --base origin/develop
  if [ "$RC" -eq 0 ] && has_line "$OUT" "SECURITY_SENSITIVE=unknown" && has_line "$OUT" "SECURITY_RECORD_GATE=recorded"; then
    ok "R12b: 変更 0 件でも未確認の記録行があれば rc 0"
  else
    bad "R12b: 変更 0 件の未確認記録が通っていない（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  printf '%s\n' "Closes #${PRN}" >"$sr_body"
  g -C "$sr_work" checkout -q 'feature/#7-sr-auth' >/dev/null 2>&1
  run_finish "$sr_work" security-record --body-file "$sr_body" --base nonexistent-ref-xyz
  if [ "$RC" -eq 1 ] && has_line "$OUT" "SECURITY_SENSITIVE=unknown" && has_line "$OUT" "SECURITY_RECORD_GATE=missing"; then
    ok "R12c: 解決できない --base は unknown として記録を求める（rc 1）"
  else
    bad "R12c: 解決できない --base の扱いが違う（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  MULTI_AGENT_SECURITY_REVIEW=off run_finish "$sr_work" security-record --body-file "$sr_body" --base nonexistent-ref-xyz
  if [ "$RC" -eq 0 ] && has_line "$OUT" "SECURITY_SENSITIVE=unknown" && has_line "$OUT" "SECURITY_RECORD_GATE=off"; then
    ok "R12d: 解決できない --base でも security_review=off は rc 0"
  else
    bad "R12d: 解決できない --base で off が効いていない（rc=${RC}）: ${OUT} / ${ERR}"
  fi

  # R13: 引数の誤り・ファイル不在は rc 2（判定不能）
  run_finish "$sr_work" security-record
  if [ "$RC" -eq 2 ] && has_text "$ERR" "--body-file"; then
    ok "R13a: --body-file 欠落は rc 2"
  else
    bad "R13a: --body-file 欠落の扱いが違う（rc=${RC}）: ${ERR}"
  fi
  run_finish "$sr_work" security-record --body-file "$sr/no-such-body.md" --base origin/develop
  if [ "$RC" -eq 2 ] && has_text "$ERR" "読めません"; then
    ok "R13b: 不在の --body-file は rc 2"
  else
    bad "R13b: 不在の --body-file の扱いが違う（rc=${RC}）: ${ERR}"
  fi
  run_finish "$sr_work" security-record --body-file "$sr_body" --body-file "$sr_body"
  if [ "$RC" -eq 2 ] && has_text "$ERR" "複数回"; then
    ok "R13c: --body-file の重複指定は rc 2"
  else
    bad "R13c: --body-file の重複指定が通っている（rc=${RC}）: ${ERR}"
  fi
  local injected_base
  injected_base="$(printf 'bad\nSECURITY_RECORD_GATE=recorded\nSECURITY_SENSITIVE=no')"
  run_finish "$sr_work" security-record --body-file "$sr_body" --base "$injected_base"
  if [ "$RC" -eq 2 ] && ! has_line "$OUT" "SECURITY_RECORD_GATE=recorded" && has_text "$ERR" "--base の値が不正"; then
    ok "R13d: 改行を含む --base は rc 2 で拒否し KEY= 行を偽造させない"
  else
    bad "R13d: 改行入り --base を拒否していない（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  run_finish "$sr_work" security-record --body-file "$sr_body" --base "--output=/tmp/x"
  if [ "$RC" -eq 2 ] && has_text "$ERR" "--base の値が不正"; then
    ok "R13d2: 先頭 '-' の --base は rc 2 で拒否する"
  else
    bad "R13d2: 先頭 '-' の --base を拒否していない（rc=${RC}）: ${ERR}"
  fi
  printf '%s\n' "Closes #${PRN}" >"$sr_work/-n"
  RC=0
  OUT="$( cd "$sr_work" && printf '%s\n' '- 専用セキュリティゲート: /security-review 実施（指摘 0 件）' | PATH="$BIN:$PATH" bash "$FINISH" security-record --body-file -n --base origin/develop 2>"$TMP/err" )" || RC=$?
  ERR="$(cat "$TMP/err")"
  rm -f -- "$sr_work/-n"
  if [ "$RC" -eq 1 ] && has_line "$OUT" "SECURITY_RECORD_GATE=missing"; then
    ok "R13e: '-' 始まりの本文ファイル名（-n）でも stdin を読まずファイル本体を判定する"
  else
    bad "R13e: '-' 始まりのファイル名で stdin を誤読している（rc=${RC}）: ${OUT} / ${ERR}"
  fi

  # R14: finish.sh の usage と skill の文書（merge-gate.md）に使い方が載っている
  run_finish "$sr_work" --help
  if [ "$RC" -eq 2 ] && has_text "$ERR" "finish.sh security-record --body-file" \
    && grep -qF "finish.sh\" security-record --body-file" "$PLUGIN_ROOT/skills/close-issue/references/merge-gate.md"; then
    ok "R14: finish.sh の usage と close-issue の merge-gate.md に security-record の使い方が載っている"
  else
    bad "R14: usage または merge-gate.md に security-record の記載が無い"
  fi

  HEAD_OID="$keep_head2"
  BASE_OID="$keep_base2"
  PR_HEAD_REF="$keep_head_ref2"
  PR_FILES_JSON=""
  write_pr_json "Closes #${PRN}" '[]'
}
