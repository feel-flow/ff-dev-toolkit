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

  PR_FILES_JSON=""
  write_pr_json "Closes #${PRN}" '[]'
}
