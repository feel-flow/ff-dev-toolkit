#!/usr/bin/env bash
# finish/verify.sh から呼ぶ、クロスモデルレビュー未実施時の再プローブ記録の検査（Issue `#2893`）。
# PR 本文に cross-model 未実施の記録（REVIEW_INFRA_FAILURE / 「cross-model 未実施」等）がある PR は、
# PR の head コミット時刻より新しい再プローブ記録行（再プローブ: PREFLIGHT=<verdict>（<TZ付きISO8601>））が無ければ
# precheck が止める。未実施の記録が無い PR（対象外）では 1 行も出さず従来どおり進む。
# 鮮度記録の無い fixture なので、止まらない回は rc 2（PRECHECK=undetermined）+ MERGE_COMMAND になる。

_ff_cm_passed() { # rc 2 + undetermined + MERGE_COMMAND = この検査では止めていない
  [ "$RC" -eq 2 ] && has_line "$OUT" "PRECHECK=undetermined" && has_text "$OUT" "MERGE_COMMAND_BEGIN" && ! has_line "$OUT" "PRECHECK=blocked"
}
_ff_cm_stopped() { # rc 1 + blocked + MERGE_COMMAND なし + 書式と導入先文書への案内
  [ "$RC" -eq 1 ] && has_line "$OUT" "PRECHECK=blocked" && ! has_text "$OUT" "MERGE_COMMAND_BEGIN" \
    && has_text "$ERR" "再プローブ: PREFLIGHT=<verdict>" && has_text "$ERR" "導入先の文書"
}

_ff_finish_cross_model_reprobe_cases() {
  local cm="$TMP/cross-model-reprobe" cm_origin="$TMP/cm-origin.git" cm_work="$TMP/cm-work"
  local keep_head="$HEAD_OID" keep_base="$BASE_OID" keep_files="${PR_FILES_JSON:-}" keep_head_ref="${PR_HEAD_REF:-}"
  local cm_head="" cm_base="" body="" line=""
  mkdir -p "$cm"

  echo
  echo "== CM. クロスモデルレビュー未実施時の再プローブ記録 =="
  # 決定的な鮮度比較のため、head コミットの committer 時刻を 2026-11-20T12:00:00Z に固定した repo を用意する
  g init -q --bare "$cm_origin" >/dev/null 2>&1
  g clone -q "$cm_origin" "$cm_work" >/dev/null 2>&1
  ( cd "$cm_work" \
    && printf 'seed\n' >seed.txt \
    && g add seed.txt >/dev/null 2>&1 \
    && GIT_AUTHOR_DATE="2026-11-20T10:00:00Z" GIT_COMMITTER_DATE="2026-11-20T10:00:00Z" g commit -qm seed >/dev/null 2>&1 \
    && g push -q origin develop >/dev/null 2>&1 \
    && g checkout -q -b 'feature/#7-cm' >/dev/null 2>&1 \
    && printf 'cm\n' >cm.txt && g add cm.txt >/dev/null 2>&1 \
    && GIT_AUTHOR_DATE="2026-11-20T11:00:00Z" GIT_COMMITTER_DATE="2026-11-20T12:00:00Z" g commit -qm "feat: #${PRN} cm" >/dev/null 2>&1 \
    && g push -q -u origin 'feature/#7-cm' >/dev/null 2>&1 )
  g -C "$cm_work" remote set-head origin develop >/dev/null 2>&1
  cm_head="$(g -C "$cm_work" rev-parse HEAD)"
  cm_base="$(g -C "$cm_work" rev-parse origin/develop)"

  HEAD_OID="$cm_head"
  BASE_OID="$cm_base"
  PR_HEAD_REF='feature/#7-cm'
  PR_FILES_JSON='[{"path":"cm.txt"}]'

  # ── CM1: 対象外（cross-model 未実施の記録が無い PR 本文）は 1 行も出さず従来どおり ──
  for body in \
    "$(printf '%s\n' "Closes #${PRN}" '' '- cross-model レビュー: Codex 実施（指摘 0 件）')" \
    "$(printf '%s\n' "Closes #${PRN}" '' '- 専用セキュリティゲート: 未実施（別軸テスト）')" \
    "$(printf '%s\n' "Closes #${PRN}" '' '```text' 'REVIEW_INFRA_FAILURE' 'cross-model 未実施' '```')" \
    "$(printf '%s\n' "Closes #${PRN}" '' '<!-- REVIEW_INFRA_FAILURE / cross-model 未実施 -->')" \
    "$(printf '%s\n' "Closes #${PRN}" '' '> REVIEW_INFRA_FAILURE' '> cross-model 未実施')" \
    "$(printf '%s\n' "Closes #${PRN}" '' '- > REVIEW_INFRA_FAILURE' '1. > cross-model 未実施')" \
    "$(printf '%s\n' "Closes #${PRN}" '' 'トークン名 MY_REVIEW_INFRA_FAILURE_CODE の説明')"; do
    write_pr_json "$body" '[]'
    run_finish "$cm_work" precheck 7
    if _ff_cm_passed && ! has_text "$OUT" "CROSS_MODEL_" && ! has_text "$ERR" "再プローブ"; then
      ok "CM1: 対象外の本文では CROSS_MODEL_* を出さず従来どおり通る"
    else
      bad "CM1: 対象外の本文に反応している（rc=${RC}）: ${OUT} / ${ERR}"
    fi
  done

  # ── CM2: 未実施の記録があり、再プローブ行が無い PR 本文は rc 1 で止め、書式と案内を出す ──
  for line in \
    '- Codex レビュー: REVIEW_INFRA_FAILURE（workspace is out of credits）' \
    '- Codex レビュー: `REVIEW_INFRA_FAILURE`（workspace is out of credits）' \
    '- cross-model 未実施（Codex 障害）' \
    '- **cross-model レビュー**：未実施（利用枠切れ）' \
    '- Cross-Model review: 未実施（infra failure）' \
    '- クロスモデル未実施（Codex 応答なし）' \
    '- クロスモデルレビュー: 未実施（基盤障害）' \
    '- [ ] クロスモデルレビュー（Toolkit とは別モデルの AI CLI）: 未実施（Codex 利用枠切れ）' \
    '- クロスモデルレビュー（Codex／別ツール・クラウド）: 未実施（利用枠切れ）' \
    '| cross-model レビュー | 未実施 |'; do
    write_pr_json "$(printf '%s\n' "Closes #${PRN}" '' "$line")" '[]'
    run_finish "$cm_work" precheck 7
    if _ff_cm_stopped && has_line "$OUT" "CROSS_MODEL_SKIP_RECORD=${line}" \
      && has_line "$OUT" "CROSS_MODEL_REPROBE_GATE=missing" \
      && ! has_text "$OUT" "CROSS_MODEL_REPROBE_RECORD="; then
      ok "CM2: 未実施記録「${line}」で再プローブ行が無い PR は blocked + 書式・案内が出る"
    else
      bad "CM2: 未実施記録「${line}」の欠落を止めていない（rc=${RC}）: ${OUT} / ${ERR}"
    fi
  done

  # ── CM3: フェンス・HTML コメント・引用・地の文・プレースホルダ・不正書式/時刻は認めない ──
  local skip_line='- Codex レビュー: REVIEW_INFRA_FAILURE（workspace is out of credits）'
  # フェンス内・HTML コメント内・引用内・地の文言及 → missing 扱い
  for body in \
    "$(printf '%s\n' "Closes #${PRN}" '' "$skip_line" '```text' '再プローブ: PREFLIGHT=failed（2026-11-20T13:00:00Z）' '```')" \
    "$(printf '%s\n' "Closes #${PRN}" '' "$skip_line" '<!-- 再プローブ: PREFLIGHT=failed（2026-11-20T13:00:00Z） -->')" \
    "$(printf '%s\n' "Closes #${PRN}" '' "$skip_line" '> 再プローブ: PREFLIGHT=failed（2026-11-20T13:00:00Z）')" \
    "$(printf '%s\n' "Closes #${PRN}" '' "$skip_line" '記録行の例は `再プローブ: PREFLIGHT=failed（2026-11-20T13:00:00Z）` である')"; do
    write_pr_json "$body" '[]'
    run_finish "$cm_work" precheck 7
    if _ff_cm_stopped && has_line "$OUT" "CROSS_MODEL_REPROBE_GATE=missing"; then
      ok "CM3a: 非記録位置の再プローブ行は数えず missing で止める"
    else
      bad "CM3a: 非記録位置の再プローブ行を通している（rc=${RC}）: ${OUT} / ${ERR}"
    fi
  done

  # 行頭「再プローブ:」だが書式不正・TZ 欠落・存在しない日付 → invalid で止める
  for line in \
    '- 再プローブ: PREFLIGHT=<verdict>（<時刻>）' \
    '- 再プローブ: PREFLIGHT=（2026-11-20T13:00:00Z）' \
    '- 再プローブ: 実施済み（2026-11-20T13:00:00Z）' \
    '- 再プローブ: PREFLIGHT=failed（2026-11-20 13:00:00）' \
    '- 再プローブ: PREFLIGHT=failed（2026-11-20）' \
    '- 再プローブ: PREFLIGHT=failed（2026-02-29T13:00:00Z）' \
    '- 再プローブ: PREFLIGHT=failed（2026-11-20T25:00:00Z）'; do
    write_pr_json "$(printf '%s\n' "Closes #${PRN}" '' "$skip_line" "$line")" '[]'
    run_finish "$cm_work" precheck 7
    if _ff_cm_stopped && has_line "$OUT" "CROSS_MODEL_REPROBE_GATE=invalid" \
      && has_line "$OUT" "CROSS_MODEL_REPROBE_RECORD=${line}"; then
      ok "CM3b: 不正な再プローブ行「${line}」は invalid で止める"
    else
      bad "CM3b: 不正な再プローブ行「${line}」を通している（rc=${RC}）: ${OUT} / ${ERR}"
    fi
  done

  # ── CM4: 古い再プローブ（head より前・head と同一秒・TZ 換算で head より前）は stale で止める ──
  # head コミット committer 時刻は 2026-11-20T12:00:00Z（author は 11:00:00Z なので committer 比較も同時確認）
  for line in \
    '- 再プローブ: PREFLIGHT=failed（2026-11-20T11:59:59Z）' \
    '- 再プローブ: PREFLIGHT=failed（2026-11-20T11:30:00Z）' \
    '- 再プローブ: PREFLIGHT=failed（2026-11-20T12:00:00Z）' \
    '- 再プローブ: PREFLIGHT=failed（2026-11-20T20:59:59+09:00）' \
    '- 再プローブ: PREFLIGHT=failed（2026-11-20 21:00:00 JST）' \
    '- 再プローブ: PREFLIGHT=failed（2026-11-20T06:59:59-05:00）' \
    '- 再プローブ: PREFLIGHT=failed（2026-11-20T07:00:00-0500）' \
    '- 再プローブ: PREFLIGHT=failed（2026-11-20T17:30:00+05:30）' \
    '- 再プローブ: PREFLIGHT=failed（2026-11-21T01:00:00+13:00）'; do
    write_pr_json "$(printf '%s\n' "Closes #${PRN}" '' "$skip_line" "$line")" '[]'
    run_finish "$cm_work" precheck 7
    if _ff_cm_stopped && has_line "$OUT" "CROSS_MODEL_REPROBE_GATE=stale" \
      && has_line "$OUT" "CROSS_MODEL_REPROBE_RECORD=${line}"; then
      ok "CM4: head より新しくない再プローブ行「${line}」は stale で止める"
    else
      bad "CM4: 古い再プローブ行「${line}」を通している（rc=${RC}）: ${OUT} / ${ERR}"
    fi
  done

  # ── CM5: PR の head より新しい再プローブ行は fresh で通過 ──
  for line in \
    '- 再プローブ: PREFLIGHT=failed（2026-11-20T12:00:01Z）' \
    '- 再プローブ: PREFLIGHT=ok（2026-11-20T12:05:00Z）' \
    '再プローブ: PREFLIGHT=out_of_credits (2026-11-20T21:00:01+09:00)' \
    '- **再プローブ**：`PREFLIGHT=REVIEW_INFRA_FAILURE`（2026-11-20 21:01 JST）' \
    '- **再プローブ:** PREFLIGHT=failed（2026-11-20T12:05:00Z）' \
    '- **再プローブ：** PREFLIGHT=failed（2026-11-20T12:05:00Z）' \
    '- 再プローブ: PREFLIGHT=failed（2026-11-20 12:00:01 UTC / workspace is out of credits）' \
    '- 再プローブ: PREFLIGHT=failed（2026-11-20T12:00:01.250Z）' \
    '- 再プローブ: PREFLIGHT=failed（2026-11-20T07:00:01-05:00）' \
    '- 再プローブ: PREFLIGHT=failed（2026-11-20T07:00:01-0500）' \
    '- 再プローブ: PREFLIGHT=failed（2026-11-20T17:30:01+05:30）' \
    '- 再プローブ: PREFLIGHT=failed（2026-11-21T01:00:01+13:00）'; do
    write_pr_json "$(printf '%s\n' "Closes #${PRN}" '' "$skip_line" "$line")" '[]'
    run_finish "$cm_work" precheck 7
    if _ff_cm_passed && has_line "$OUT" "CROSS_MODEL_SKIP_RECORD=${skip_line}" \
      && has_line "$OUT" "CROSS_MODEL_REPROBE_GATE=fresh" \
      && has_line "$OUT" "CROSS_MODEL_REPROBE_RECORD=${line}"; then
      ok "CM5: head より新しい再プローブ行「${line}」は fresh で通る"
    else
      bad "CM5: 新しい再プローブ行「${line}」で止まっている（rc=${RC}）: ${OUT} / ${ERR}"
    fi
  done

  # CRLF 本文（GitHub Web 編集）+ 64KB 超本文（SIGPIPE 耐性）
  write_pr_json "$(printf 'Closes #%s\r\n\r\n%s\r\n- 再プローブ: PREFLIGHT=failed（2026-11-20T12:05:00Z）\r\n' "$PRN" "$skip_line")" '[]'
  run_finish "$cm_work" precheck 7
  if _ff_cm_passed && has_line "$OUT" "CROSS_MODEL_REPROBE_GATE=fresh"; then
    ok "CM5b: CRLF 本文の再プローブ行も fresh で通る"
  else
    bad "CM5b: CRLF 本文で再プローブ行を落としている（rc=${RC}）: ${OUT} / ${ERR}"
  fi

  body="$(printf '%s\n' "Closes #${PRN}" '' "$skip_line" '- 再プローブ: PREFLIGHT=failed（2026-11-20T12:05:00Z）'
    i=0; while [ "$i" -lt 1500 ]; do printf '| 行 %d | 本文を長くするための説明の文字列を並べる |\n' "$i"; i=$((i + 1)); done)"
  local cm_bytes
  cm_bytes="$(printf '%s' "$body" | wc -c | tr -d ' ')"
  write_pr_json "$body" '[]'
  run_finish "$cm_work" precheck 7
  if [ "$cm_bytes" -gt 65536 ] && _ff_cm_passed && has_line "$OUT" "CROSS_MODEL_REPROBE_GATE=fresh"; then
    ok "CM5c: 64KB 超の長い本文でも SIGPIPE で落とさず fresh で通る（${cm_bytes} B）"
  else
    bad "CM5c: 長い本文で判定が壊れている（${cm_bytes} B、rc=${RC}）: ${OUT} / ${ERR}"
  fi

  # ── CM6: 複数行追記（古い行と新しい行の両方がある場合、新しい方を採用） ──
  local old_reprobe='- 再プローブ: PREFLIGHT=failed（2026-11-20T11:00:00Z）'
  local new_reprobe='- 再プローブ: PREFLIGHT=failed（2026-11-20T12:30:00Z）'
  write_pr_json "$(printf '%s\n' "Closes #${PRN}" '' "$skip_line" "$old_reprobe" "$new_reprobe")" '[]'
  run_finish "$cm_work" precheck 7
  if _ff_cm_passed && has_line "$OUT" "CROSS_MODEL_REPROBE_GATE=fresh" \
    && has_line "$OUT" "CROSS_MODEL_REPROBE_RECORD=${new_reprobe}"; then
    ok "CM6a: 古い行→新しい行の順に追記された本文は最新の行を採って fresh で通る"
  else
    bad "CM6a: 古い行→新しい行の追記で止まっている（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  write_pr_json "$(printf '%s\n' "Closes #${PRN}" '' "$skip_line" "$new_reprobe" "$old_reprobe")" '[]'
  run_finish "$cm_work" precheck 7
  if _ff_cm_passed && has_line "$OUT" "CROSS_MODEL_REPROBE_GATE=fresh" \
    && has_line "$OUT" "CROSS_MODEL_REPROBE_RECORD=${new_reprobe}"; then
    ok "CM6b: 新しい行→古い行の順に並んだ本文でも最大の時刻を採って fresh で通る"
  else
    bad "CM6b: 新しい行→古い行の並びで止まっている（rc=${RC}）: ${OUT} / ${ERR}"
  fi

  # ── CM7: head 時刻の取得不能（手元 git になく API にも committedDate が無い）→ unknown で fail-closed ──
  HEAD_OID="$(printf '%040d' 8)"
  write_pr_json "$(printf '%s\n' "Closes #${PRN}" '' "$skip_line" "$new_reprobe")" '[]'
  run_finish "$cm_work" precheck 7
  if _ff_cm_stopped && has_line "$OUT" "CROSS_MODEL_REPROBE_GATE=unknown" \
    && has_text "$ERR" "git fetch origin develop"; then
    ok "CM7a: head コミット時刻を取得できない回は unknown で止め、fetch を案内する"
  else
    bad "CM7a: head 時刻不明を素通りさせている（rc=${RC}）: ${OUT} / ${ERR}"
  fi

  # API の commits[].committedDate に時刻がある場合はフォールバックして判定する
  jq --arg ts "2026-11-20T12:00:00Z" '.commits[0].committedDate = $ts' "$TMP/pr.json" >"$TMP/pr-cm-api.json"
  cp "$TMP/pr-cm-api.json" "$TMP/pr.json"
  run_finish "$cm_work" precheck 7
  if has_line "$OUT" "CROSS_MODEL_REPROBE_GATE=fresh" && ! has_line "$OUT" "PRECHECK=blocked"; then
    ok "CM7b: 手元 git に無くても API commits[].committedDate で新しい記録を fresh と判定する"
  else
    bad "CM7b: API committedDate フォールバックが効いていない（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  jq --arg ts "2026-11-20T13:00:00Z" '.commits[0].committedDate = $ts' "$TMP/pr.json" >"$TMP/pr-cm-api-stale.json"
  cp "$TMP/pr-cm-api-stale.json" "$TMP/pr.json"
  run_finish "$cm_work" precheck 7
  if _ff_cm_stopped && has_line "$OUT" "CROSS_MODEL_REPROBE_GATE=stale"; then
    ok "CM7c: API commits[].committedDate より古い記録は stale で止める"
  else
    bad "CM7c: API committedDate の stale 判定が効いていない（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  HEAD_OID="not-a-hex-oid"
  write_pr_json "$(printf '%s\n' "Closes #${PRN}" '' "$skip_line" "$new_reprobe")" '[]'
  run_finish "$cm_work" precheck 7
  if [ "$RC" -eq 2 ] && has_line "$OUT" "CROSS_MODEL_REPROBE_GATE=unknown" && ! has_text "$OUT" "MERGE_COMMAND_BEGIN"; then
    ok "CM7d: 非 hex の headRefOid は git show に渡さず unknown とし、MERGE_COMMAND を出さない"
  else
    bad "CM7d: 非 hex headRefOid の扱いが不正（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  HEAD_OID="$cm_head"

  # ── CM8: 先着停止理由（未チェック AC）との併記 ──
  printf '%s\n' '# AC' '- [ ] まだ未チェック' >"$cm/unchecked.md"
  write_pr_json "$(printf '%s\n' "Closes #${PRN}" '' "$skip_line")" '[]'
  STUB_ISSUE_BODY_FILE="$cm/unchecked.md" run_finish "$cm_work" precheck 7
  if [ "$RC" -eq 1 ] && has_line "$OUT" "CROSS_MODEL_REPROBE_GATE=missing" \
    && has_text "$ERR" "未チェックの受け入れ条件" && has_text "$ERR" "／さらにPR 本文に cross-model 未実施の記録"; then
    ok "CM8: 先着の停止理由（未チェック AC）を上書きせず、再プローブ記録の欠落を併記する"
  else
    bad "CM8: 先着停止との併記が崩れている（rc=${RC}）: ${OUT} / ${ERR}"
  fi

  # 復元
  HEAD_OID="$keep_head"
  BASE_OID="$keep_base"
  PR_HEAD_REF="$keep_head_ref"
  PR_FILES_JSON="$keep_files"
  write_pr_json "Closes #${PRN}" '[]'
}
