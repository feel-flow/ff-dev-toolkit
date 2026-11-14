#!/usr/bin/env bash
# finish/verify.sh から呼ぶ、マージ後工程の判定（FF_POST_MERGE_TERMS / FF_POST_MERGE_PATHS）の検査。
# 再現の入力は、本番適用が未実施のまま Issue が閉じた実際の回の本文と完了報告の形にそろえる。
# 記録の無い fixture なので、止まらない回は rc 2（PRECHECK=undetermined）+ MERGE_COMMAND になる。
# 止まった回は rc 1 + PRECHECK=blocked で MERGE_COMMAND を出さない。

_ff_pm_hit_body='- [x] 決めた内容を migration にし、確かめる。本番への適用は main リリースの範囲で、承認を得て行う'
_ff_pm_report_line='| 本番適用は承認を得て行う | ✅ 達成 | マージ後に当てる |'
_ff_pm_files='[{"path":"migrations/211_close.sql"},{"path":"docs/a.md"}]'

_ff_pm_passed() { # rc 2 + undetermined + MERGE_COMMAND = 判定を通過した（記録不在の fixture）
  [ "$RC" -eq 2 ] && has_line "$OUT" "PRECHECK=undetermined" && has_text "$OUT" "MERGE_COMMAND_BEGIN"
}
_ff_pm_stopped() { # rc 1 + blocked + MERGE_COMMAND なし
  [ "$RC" -eq 1 ] && has_line "$OUT" "PRECHECK=blocked" && ! has_text "$OUT" "MERGE_COMMAND_BEGIN"
}
_ff_pm_undetermined_no_merge() { # rc 2 + MERGE_COMMAND なし + 止める判定にしていない
  [ "$RC" -eq 2 ] && ! has_text "$OUT" "MERGE_COMMAND_BEGIN" && ! has_line "$OUT" "PRECHECK=blocked" && ! has_line "$OUT" "POST_MERGE_GATE="
}
_ff_pm_comments() { # <出力先> <本文...> → gh issue view --json comments の形
  local dest="$1"; shift
  printf '%s\0' "$@" | jq -Rs 'split("\u0000") | map(select(length > 0)) | {comments: map({body: .})}' >"$dest"
}
_ff_pm_no_gh() { # gh を 1 回も呼んでいない
  ! [ -s "$STUB_LOG" ]
}

_ff_finish_post_merge_cases() {
  # 変更ファイルの fixture（migrations/*.sql）は専用セキュリティゲートの分類に当たる。ここで測るのは
  # マージ後工程の判定なので、記録の検査は off にして結果を混ぜない（記録の検査は security-record-cases.sh）
  export MULTI_AGENT_SECURITY_REVIEW=off
  local pm="$TMP/post-merge" terms='本番適用:本番への適用:production' paths='migrations/**'
  mkdir -p "$pm"
  printf '%s\n' '# 背景' "$_ff_pm_hit_body" '- [x] done' >"$pm/hit.md"
  printf '%s\n' '# 背景' '- [x] done' >"$pm/plain.md"
  PR_FILES_JSON="$_ff_pm_files"
  write_pr_json "Closes #${PRN}" '[]'

  echo
  echo "== P. マージ後工程の判定 =="
  # ── AC1: チェック済み + 語 + パス ──
  : >"$STUB_LOG"
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS="$paths" STUB_ISSUE_BODY_FILE="$pm/hit.md" run_finish "$WORK" precheck 7
  if _ff_pm_stopped && has_line "$OUT" "POST_MERGE_GATE=blocked" && has_line "$OUT" "POST_MERGE_HIT_COUNT=1" \
    && has_line "$OUT" "POST_MERGE_HIT=owner/repo#7	body	${_ff_pm_hit_body}" \
    && has_line "$OUT" "POST_MERGE_PATH=migrations/211_close.sql" && ! has_line "$OUT" "POST_MERGE_PATH=docs/a.md" \
    && has_line "$OUT" "AC_UNCHECKED_COUNT=0" \
    && has_text "$ERR" "Refs" && has_text "$ERR" "--ack-post-merge"; then
    ok "P1: チェック済み + 語 + パスの一致は rc 1 で止め、一致行と次の一手を出す（AC1 / 再発した回の本文の形）"
  else
    bad "P1: チェック済みの語で止まっていない（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  _ff_pm_comments "$pm/report.json" "$(printf '%s\n' '<!-- close-issue-report:PR-7 -->' '## 完了報告' "$_ff_pm_report_line")"
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS="$paths" STUB_ISSUE_BODY_FILE="$pm/plain.md" STUB_ISSUE_COMMENTS_FILE="$pm/report.json" run_finish "$WORK" precheck 7
  if _ff_pm_stopped && has_line "$OUT" "POST_MERGE_HIT=owner/repo#7	report	${_ff_pm_report_line}" \
    && ! has_line "$OUT" "POST_MERGE_HIT=owner/repo#7	body"; then
    ok "P1b: 本文に語が無くても、この PR の完了報告の行で止める（再発した回の報告の形）"
  else
    bad "P1b: 完了報告の行を拾っていない（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  _ff_pm_comments "$pm/others.json" \
    "$(printf '%s\n' '<!-- close-issue-report:PR-70 -->' "$_ff_pm_report_line")" \
    "$(printf '%s\n' 'ただの会話' "$_ff_pm_report_line")"
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS="$paths" STUB_ISSUE_BODY_FILE="$pm/plain.md" STUB_ISSUE_COMMENTS_FILE="$pm/others.json" run_finish "$WORK" precheck 7
  if _ff_pm_passed && has_line "$OUT" "POST_MERGE_GATE=clear" && has_line "$OUT" "POST_MERGE_HIT_COUNT=0"; then
    ok "P1c: 別の PR の報告（番号の前方一致を含む）と普通のコメントは拾わない"
  else
    bad "P1c: 対象外のコメントを拾っている（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  printf '%s\n' '- [x] Apply to PRODUCTION' >"$pm/upper.md"
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS="$paths" STUB_ISSUE_BODY_FILE="$pm/upper.md" run_finish "$WORK" precheck 7
  if _ff_pm_stopped && has_line "$OUT" "POST_MERGE_HIT=owner/repo#7	body	- [x] Apply to PRODUCTION"; then
    ok "P1d: 英字の語は大文字小文字を区別しない"
  else
    bad "P1d: 大文字の語を拾っていない（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  cat >"$pm/hidden.md" <<'BODY'
<!--
本番適用 in comment
-->
```
本番適用 in fence
```
- [x] done
BODY
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS="$paths" STUB_ISSUE_BODY_FILE="$pm/hidden.md" run_finish "$WORK" precheck 7
  if _ff_pm_passed && has_line "$OUT" "POST_MERGE_GATE=clear"; then
    ok "P1e: フェンスと HTML コメントの中の語は数えない"
  else
    bad "P1e: 隠れた行を拾っている（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  printf '%s\n' '```npm run deploy``` は本番適用の後に流す' '- [x] 本番適用する' >"$pm/inline.md"
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS="$paths" STUB_ISSUE_BODY_FILE="$pm/inline.md" run_finish "$WORK" precheck 7
  if _ff_pm_stopped && has_line "$OUT" "POST_MERGE_HIT_COUNT=2" && has_line "$OUT" "POST_MERGE_HIT=owner/repo#7	body	- [x] 本番適用する"; then
    ok "P1e2: 行頭のインライン三連バッククォートをフェンスと読まず、以降の行を隠さない"
  else
    bad "P1e2: インラインコードの行が以降を隠している（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  # 未チェックの検査は visible の例外を受けない（設定なしの出力を変えない）
  printf '%s\n' '```npm run x``` のあと' '- [ ] 隠れる行' >"$pm/inline-unchecked.md"
  STUB_ISSUE_BODY_FILE="$pm/inline-unchecked.md" run_finish "$WORK" precheck 7
  if has_line "$OUT" "AC_UNCHECKED_COUNT=0"; then
    ok "P1e4: 未チェックの検査の走査は変えない"
  else
    bad "P1e4: 未チェックの検査の走査が変わった（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  _ff_pm_comments "$pm/two-reports.json" \
    "$(printf '%s\n' '<!-- close-issue-report:PR-7 -->' '```' 'この報告はフェンスを閉じない')" \
    "$(printf '%s\n' '<!-- close-issue-report:PR-7 -->' "$_ff_pm_report_line")"
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS="$paths" STUB_ISSUE_BODY_FILE="$pm/plain.md" STUB_ISSUE_COMMENTS_FILE="$pm/two-reports.json" run_finish "$WORK" precheck 7
  if _ff_pm_stopped && has_line "$OUT" "POST_MERGE_HIT=owner/repo#7	report	${_ff_pm_report_line}"; then
    ok "P1e3: 閉じないフェンスの報告が次の報告を隠さない"
  else
    bad "P1e3: 報告の間でフェンスの状態が残っている（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  printf '%s\n' '- [x] a.b を直す' >"$pm/literal.md"
  FF_POST_MERGE_TERMS='a.c' FF_POST_MERGE_PATHS="$paths" STUB_ISSUE_BODY_FILE="$pm/literal.md" run_finish "$WORK" precheck 7
  if _ff_pm_passed && has_line "$OUT" "POST_MERGE_GATE=clear"; then
    ok "P1f: 語は正規表現ではなく文字どおりに照合する"
  else
    bad "P1f: 語を正規表現で読んでいる（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  printf '%s\n' '- [ ] 本番適用する' >"$pm/both.md"
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS="$paths" STUB_ISSUE_BODY_FILE="$pm/both.md" run_finish "$WORK" precheck 7
  if _ff_pm_stopped && has_line "$OUT" "AC_UNCHECKED_COUNT=1" && has_line "$OUT" "POST_MERGE_GATE=blocked" \
    && has_text "$ERR" "未チェック" && has_text "$ERR" "マージ後" && has_text "$ERR" "--ack-unchecked" && has_text "$ERR" "--ack-post-merge"; then
    ok "P1g: 先に止まる理由を上書きせず併記する（2 段停止にしない）"
  else
    bad "P1g: 停止理由の併記が違う（rc=${RC}）: ${OUT} / ${ERR}"
  fi

  # ── 閉じた工数ブロックの effort_evidence / effort_basis は語の一致から外す ──
  cat >"$pm/effort-only.md" <<'BODY'
# 背景
<!-- ff-effort:begin -->
- effort_unit: h
- effort_basis: 本番適用の手順を根拠にした見積もり
- effort_evidence: 本番への適用は未実施
- effort_deploy: なし（コードのみ）
- effort_ai_planned: 1.0h
<!-- ff-effort:end -->
- [x] migration を確かめる
BODY
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS="$paths" STUB_ISSUE_BODY_FILE="$pm/effort-only.md" run_finish "$WORK" precheck 7
  if _ff_pm_passed && has_line "$OUT" "POST_MERGE_GATE=clear" && has_line "$OUT" "POST_MERGE_HIT_COUNT=0" \
    && has_line "$OUT" "POST_MERGE_EXCLUDED=owner/repo#7	body	- effort_basis: 本番適用の手順を根拠にした見積もり" \
    && has_line "$OUT" "POST_MERGE_EXCLUDED=owner/repo#7	body	- effort_evidence: 本番への適用は未実施" \
    && ! has_line "$OUT" "POST_MERGE_HIT=" \
    && ! has_line "$OUT" "POST_MERGE_EXCLUDED=owner/repo#7	body	- effort_deploy:" \
    && ! has_line "$OUT" "POST_MERGE_EXCLUDED=owner/repo#7	body	- effort_unit:" \
    && ! has_line "$OUT" "POST_MERGE_EXCLUDED=owner/repo#7	body	- effort_ai_planned:" \
    && ! has_line "$OUT" "POST_MERGE_EXCLUDED=owner/repo#7	body	- [x] migration"; then
    ok "P1h: 閉じた工数ブロックの effort_basis と effort_evidence だけを外し、通過する"
  else
    bad "P1h: 工数ブロックの除外が違う（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  cat >"$pm/effort-keep.md" <<'BODY'
<!-- ff-effort:begin -->
- effort_basis: 本番適用を見込む
- effort_evidence: 本番への適用の記録
- effort_deploy: 本番適用を行う
<!-- ff-effort:end -->
- [x] 本番適用する
BODY
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS="$paths" STUB_ISSUE_BODY_FILE="$pm/effort-keep.md" run_finish "$WORK" precheck 7
  if _ff_pm_stopped && has_line "$OUT" "POST_MERGE_GATE=blocked" && has_line "$OUT" "POST_MERGE_HIT_COUNT=2" \
    && has_line "$OUT" "POST_MERGE_HIT=owner/repo#7	body	- effort_deploy: 本番適用を行う" \
    && has_line "$OUT" "POST_MERGE_HIT=owner/repo#7	body	- [x] 本番適用する" \
    && has_line "$OUT" "POST_MERGE_EXCLUDED=owner/repo#7	body	- effort_basis: 本番適用を見込む" \
    && has_line "$OUT" "POST_MERGE_EXCLUDED=owner/repo#7	body	- effort_evidence: 本番への適用の記録" \
    && ! has_line "$OUT" "POST_MERGE_EXCLUDED=owner/repo#7	body	- effort_deploy:" \
    && ! has_line "$OUT" "POST_MERGE_HIT=owner/repo#7	body	- effort_basis:" \
    && ! has_line "$OUT" "POST_MERGE_HIT=owner/repo#7	body	- effort_evidence:"; then
    ok "P1i: effort_deploy と受け入れ条件は止め、根拠の 2 行は除外として出す"
  else
    bad "P1i: 残す行と除外する行が違う（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  printf '%s\n' '<!-- ff-effort:begin -->' '- effort_basis: 本番適用のまま閉じない' >"$pm/effort-unclosed.md"
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS="$paths" STUB_ISSUE_BODY_FILE="$pm/effort-unclosed.md" run_finish "$WORK" precheck 7
  if _ff_pm_stopped && has_line "$OUT" "POST_MERGE_HIT=owner/repo#7	body	- effort_basis: 本番適用のまま閉じない" \
    && ! has_line "$OUT" "POST_MERGE_EXCLUDED="; then
    ok "P1j: 閉じていないブロックは除外せず、根拠の行で止める"
  else
    bad "P1j: 未閉鎖を除外している（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  cat >"$pm/effort-end-first.md" <<'BODY'
<!-- ff-effort:end -->
<!-- ff-effort:begin -->
- effort_basis: 本番適用が end より前
- effort_evidence: 本番への適用
<!-- ff-effort:end -->
BODY
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS="$paths" STUB_ISSUE_BODY_FILE="$pm/effort-end-first.md" run_finish "$WORK" precheck 7
  if _ff_pm_stopped && has_line "$OUT" "POST_MERGE_HIT_COUNT=2" \
    && has_line "$OUT" "POST_MERGE_HIT=owner/repo#7	body	- effort_basis: 本番適用が end より前" \
    && has_line "$OUT" "POST_MERGE_HIT=owner/repo#7	body	- effort_evidence: 本番への適用" \
    && ! has_line "$OUT" "POST_MERGE_EXCLUDED="; then
    ok "P1k: end が begin より前の本文は、後の組が閉じても可視の全行を見る"
  else
    bad "P1k: 前後が逆の本文を除外している（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  cat >"$pm/effort-nested.md" <<'BODY'
<!-- ff-effort:begin -->
- effort_basis: 本番適用 a
<!-- ff-effort:begin -->
- effort_basis: 本番適用 b
<!-- ff-effort:end -->
BODY
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS="$paths" STUB_ISSUE_BODY_FILE="$pm/effort-nested.md" run_finish "$WORK" precheck 7
  if _ff_pm_stopped && has_line "$OUT" "POST_MERGE_HIT_COUNT=2" \
    && has_line "$OUT" "POST_MERGE_HIT=owner/repo#7	body	- effort_basis: 本番適用 a" \
    && has_line "$OUT" "POST_MERGE_HIT=owner/repo#7	body	- effort_basis: 本番適用 b" \
    && ! has_line "$OUT" "POST_MERGE_EXCLUDED="; then
    ok "P1l: begin が入れ子の本文は、後の end が 1 つでも両方の根拠行で止める"
  else
    bad "P1l: 入れ子を除外している（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  cat >"$pm/effort-outside.md" <<'BODY'
- effort_basis: 本番適用はブロックの外
<!-- ff-effort:begin -->
- effort_basis: 本番適用はブロックの中
<!-- ff-effort:end -->
BODY
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS="$paths" STUB_ISSUE_BODY_FILE="$pm/effort-outside.md" run_finish "$WORK" precheck 7
  if _ff_pm_stopped && has_line "$OUT" "POST_MERGE_HIT_COUNT=1" \
    && has_line "$OUT" "POST_MERGE_HIT=owner/repo#7	body	- effort_basis: 本番適用はブロックの外" \
    && has_line "$OUT" "POST_MERGE_EXCLUDED=owner/repo#7	body	- effort_basis: 本番適用はブロックの中" \
    && ! has_line "$OUT" "POST_MERGE_EXCLUDED=owner/repo#7	body	- effort_basis: 本番適用はブロックの外"; then
    ok "P1m: ブロックの外の根拠行は止め、中の根拠行は除外する"
  else
    bad "P1m: ブロックの内外が違う（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  cat >"$pm/effort-fence.md" <<'BODY'
```
<!-- ff-effort:begin -->
- effort_basis: 本番適用はフェンスの中
```
- effort_basis: 本番適用はフェンスの外
<!-- ff-effort:end -->
BODY
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS="$paths" STUB_ISSUE_BODY_FILE="$pm/effort-fence.md" run_finish "$WORK" precheck 7
  if _ff_pm_stopped && has_line "$OUT" "POST_MERGE_HIT_COUNT=1" \
    && has_line "$OUT" "POST_MERGE_HIT=owner/repo#7	body	- effort_basis: 本番適用はフェンスの外" \
    && ! has_line "$OUT" "POST_MERGE_EXCLUDED=" \
    && ! has_text "$OUT" "フェンスの中"; then
    ok "P1n: フェンスの中の begin は、後の end と組まず、外の根拠行で止める"
  else
    bad "P1n: フェンスの中のマーカーを見ている（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  printf '%s\n' ' <!-- ff-effort:begin -->' '- effort_basis: 本番適用は字下げのマーカー' '<!-- ff-effort:end -->' >"$pm/effort-indent.md"
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS="$paths" STUB_ISSUE_BODY_FILE="$pm/effort-indent.md" run_finish "$WORK" precheck 7
  if _ff_pm_stopped && has_line "$OUT" "POST_MERGE_HIT=owner/repo#7	body	- effort_basis: 本番適用は字下げのマーカー" \
    && ! has_line "$OUT" "POST_MERGE_EXCLUDED="; then
    ok "P1o: 字下げしたマーカーはマーカーにせず、可視の全行を見る"
  else
    bad "P1o: 字下げしたマーカーを認めている（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  printf '%s\n' '<!-- ff-effort:begin --> ' '- effort_basis: 本番適用は末尾空白の begin' '<!-- ff-effort:end -->' >"$pm/effort-trail-begin.md"
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS="$paths" STUB_ISSUE_BODY_FILE="$pm/effort-trail-begin.md" run_finish "$WORK" precheck 7
  if _ff_pm_stopped && has_line "$OUT" "POST_MERGE_HIT=owner/repo#7	body	- effort_basis: 本番適用は末尾空白の begin" \
    && ! has_line "$OUT" "POST_MERGE_EXCLUDED="; then
    ok "P1p: 末尾に空白のある begin はマーカーにせず、可視の全行を見る"
  else
    bad "P1p: 末尾空白の begin を認めている（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  printf '%s\n' '<!-- ff-effort:begin -->' '- effort_basis: 本番適用は末尾空白の end' '<!-- ff-effort:end --> ' >"$pm/effort-trail-end.md"
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS="$paths" STUB_ISSUE_BODY_FILE="$pm/effort-trail-end.md" run_finish "$WORK" precheck 7
  if _ff_pm_stopped && has_line "$OUT" "POST_MERGE_HIT=owner/repo#7	body	- effort_basis: 本番適用は末尾空白の end" \
    && ! has_line "$OUT" "POST_MERGE_EXCLUDED="; then
    ok "P1p2: 末尾に空白のある end は閉じたブロックにせず、除外しない"
  else
    bad "P1p2: 末尾空白の end を閉じたと読んでいる（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  printf '%s\n' '<!-- ff-effort:begin -->' '- effort_basis: 本番適用はコメントに飲まれた end の前' '<!-- まだ' '<!-- ff-effort:end -->' >"$pm/effort-comment-end.md"
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS="$paths" STUB_ISSUE_BODY_FILE="$pm/effort-comment-end.md" run_finish "$WORK" precheck 7
  if _ff_pm_stopped && has_line "$OUT" "POST_MERGE_HIT=owner/repo#7	body	- effort_basis: 本番適用はコメントに飲まれた end の前" \
    && ! has_line "$OUT" "POST_MERGE_EXCLUDED="; then
    ok "P1y: 開いた HTML コメントの中の end は閉じたブロックにせず、根拠行で止める"
  else
    bad "P1y: コメントの中の end を閉じたと読んでいる（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  printf '%s\n' '<!-- 下書き' '<!-- ff-effort:begin -->' '- effort_basis: 本番適用はコメントの外' '<!-- ff-effort:end -->' >"$pm/effort-comment-begin.md"
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS="$paths" STUB_ISSUE_BODY_FILE="$pm/effort-comment-begin.md" run_finish "$WORK" precheck 7
  if _ff_pm_stopped && has_line "$OUT" "POST_MERGE_HIT=owner/repo#7	body	- effort_basis: 本番適用はコメントの外" \
    && ! has_line "$OUT" "POST_MERGE_EXCLUDED="; then
    ok "P1y2: 開いた HTML コメントの中の begin は、後の end と組まず、根拠行で止める"
  else
    bad "P1y2: コメントの中の begin を認めている（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  cat >"$pm/effort-orphan-begin.md" <<'BODY'
<!-- ff-effort:begin -->
- effort_basis: 本番適用は閉じた組のあと
<!-- ff-effort:end -->
<!-- ff-effort:begin -->
BODY
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS="$paths" STUB_ISSUE_BODY_FILE="$pm/effort-orphan-begin.md" run_finish "$WORK" precheck 7
  if _ff_pm_stopped && has_line "$OUT" "POST_MERGE_HIT=owner/repo#7	body	- effort_basis: 本番適用は閉じた組のあと" \
    && ! has_line "$OUT" "POST_MERGE_EXCLUDED="; then
    ok "P1z: 閉じた組のあとに begin が残る本文は、先頭の組も除外しない"
  else
    bad "P1z: 壊れた境界を組の中だけに閉じている（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  printf '%s\n' '<!-- ff-effort:begin -->' '- effort_basis: 本番適用は途中の非マーカー' '<!-- ff-effort:end --> ' '<!-- ff-effort:end -->' >"$pm/effort-near-end.md"
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS="$paths" STUB_ISSUE_BODY_FILE="$pm/effort-near-end.md" run_finish "$WORK" precheck 7
  if _ff_pm_passed && has_line "$OUT" "POST_MERGE_GATE=clear" && has_line "$OUT" "POST_MERGE_HIT_COUNT=0" \
    && has_line "$OUT" "POST_MERGE_EXCLUDED=owner/repo#7	body	- effort_basis: 本番適用は途中の非マーカー" \
    && ! has_line "$OUT" "POST_MERGE_HIT="; then
    ok "P1z2: 末尾空白の end はマーカーにせず、後続の完全一致の end が組を閉じる"
  else
    bad "P1z2: 完全一致しない行で閉じた組を壊している（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  cat >"$pm/effort-two.md" <<'BODY'
<!-- ff-effort:begin -->
- effort_basis: 本番適用 one
<!-- ff-effort:end -->
<!-- ff-effort:begin -->
- effort_evidence: 本番への適用 two
<!-- ff-effort:end -->
BODY
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS="$paths" STUB_ISSUE_BODY_FILE="$pm/effort-two.md" run_finish "$WORK" precheck 7
  if _ff_pm_passed && has_line "$OUT" "POST_MERGE_GATE=clear" && has_line "$OUT" "POST_MERGE_HIT_COUNT=0" \
    && has_line "$OUT" "POST_MERGE_EXCLUDED=owner/repo#7	body	- effort_basis: 本番適用 one" \
    && has_line "$OUT" "POST_MERGE_EXCLUDED=owner/repo#7	body	- effort_evidence: 本番への適用 two" \
    && ! has_line "$OUT" "POST_MERGE_HIT="; then
    ok "P1q: 閉じた組が二つあっても、それぞれの根拠行を外す"
  else
    bad "P1q: 二つ目のブロックの扱いが違う（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  cat >"$pm/effort-prose.md" <<'BODY'
<!-- ff-effort:begin -->
本番適用は後で行う
<!-- ff-effort:end -->
BODY
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS="$paths" STUB_ISSUE_BODY_FILE="$pm/effort-prose.md" run_finish "$WORK" precheck 7
  if _ff_pm_stopped && has_line "$OUT" "POST_MERGE_HIT_COUNT=1" \
    && has_line "$OUT" "POST_MERGE_HIT=owner/repo#7	body	本番適用は後で行う" \
    && ! has_line "$OUT" "POST_MERGE_EXCLUDED="; then
    ok "P1r: キーの形でない地の文はブロックの中でも止める"
  else
    bad "P1r: 地の文を除外している（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  cat >"$pm/effort-other-key.md" <<'BODY'
<!-- ff-effort:begin -->
- effort_ai_planned: 本番適用を含む
- effort_basis_note: 本番適用の注記
<!-- ff-effort:end -->
BODY
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS="$paths" STUB_ISSUE_BODY_FILE="$pm/effort-other-key.md" run_finish "$WORK" precheck 7
  if _ff_pm_stopped && has_line "$OUT" "POST_MERGE_HIT_COUNT=2" \
    && has_line "$OUT" "POST_MERGE_HIT=owner/repo#7	body	- effort_ai_planned: 本番適用を含む" \
    && has_line "$OUT" "POST_MERGE_HIT=owner/repo#7	body	- effort_basis_note: 本番適用の注記" \
    && ! has_line "$OUT" "POST_MERGE_EXCLUDED="; then
    ok "P1s: 別名のキーはブロックの中でも止める"
  else
    bad "P1s: 別名のキーを除外している（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  cat >"$pm/effort-spaces.md" <<'BODY'
<!-- ff-effort:begin -->
- effort_basis:本番適用
-  effort_evidence : 本番への適用
<!-- ff-effort:end -->
BODY
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS="$paths" STUB_ISSUE_BODY_FILE="$pm/effort-spaces.md" run_finish "$WORK" precheck 7
  if _ff_pm_passed && has_line "$OUT" "POST_MERGE_GATE=clear" && has_line "$OUT" "POST_MERGE_HIT_COUNT=0" \
    && has_line "$OUT" "POST_MERGE_EXCLUDED=owner/repo#7	body	- effort_basis:本番適用" \
    && has_line "$OUT" "POST_MERGE_EXCLUDED=owner/repo#7	body	-  effort_evidence : 本番への適用" \
    && ! has_line "$OUT" "POST_MERGE_HIT="; then
    ok "P1t: コロン前後の空白が違っても、二つの根拠キーは外す"
  else
    bad "P1t: 空白の違う根拠キーを残している（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  cat >"$pm/effort-noterm.md" <<'BODY'
<!-- ff-effort:begin -->
- effort_basis: 見積もりの根拠
- effort_evidence: diff +1
<!-- ff-effort:end -->
- [x] done
BODY
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS="$paths" STUB_ISSUE_BODY_FILE="$pm/effort-noterm.md" run_finish "$WORK" precheck 7
  if _ff_pm_passed && has_line "$OUT" "POST_MERGE_GATE=clear" && has_line "$OUT" "POST_MERGE_HIT_COUNT=0" \
    && ! has_line "$OUT" "POST_MERGE_EXCLUDED=" && ! has_line "$OUT" "POST_MERGE_HIT="; then
    ok "P1u: 語に当たらない根拠行は除外行も出さない"
  else
    bad "P1u: 語に当たらない行を出している（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  printf '%s\r\n' '<!-- ff-effort:begin -->' '- effort_basis: 本番適用' '<!-- ff-effort:end -->' >"$pm/effort-crlf.md"
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS="$paths" STUB_ISSUE_BODY_FILE="$pm/effort-crlf.md" run_finish "$WORK" precheck 7
  if _ff_pm_passed && has_line "$OUT" "POST_MERGE_GATE=clear" && has_line "$OUT" "POST_MERGE_HIT_COUNT=0" \
    && has_line "$OUT" "POST_MERGE_EXCLUDED=owner/repo#7	body	- effort_basis: 本番適用" \
    && ! has_line "$OUT" "POST_MERGE_HIT=" \
    && [ "$(printf '%s' "$OUT" | tr -cd '\r' | wc -c | tr -d ' ')" = "0" ]; then
    ok "P1v: 行末の CR を外したマーカーは閉じたブロックとして根拠行を外す"
  else
    bad "P1v: 行末の CR の扱いが違う（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  _ff_pm_comments "$pm/effort-report-clear.json" "$(printf '%s\n' '<!-- close-issue-report:PR-7 -->' '<!-- ff-effort:begin -->' '- effort_basis: 本番適用を報告に書く' '- effort_evidence: 本番への適用の記録' '<!-- ff-effort:end -->')"
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS="$paths" STUB_ISSUE_BODY_FILE="$pm/plain.md" STUB_ISSUE_COMMENTS_FILE="$pm/effort-report-clear.json" run_finish "$WORK" precheck 7
  if _ff_pm_passed && has_line "$OUT" "POST_MERGE_GATE=clear" && has_line "$OUT" "POST_MERGE_HIT_COUNT=0" \
    && has_line "$OUT" "POST_MERGE_EXCLUDED=owner/repo#7	report	- effort_basis: 本番適用を報告に書く" \
    && has_line "$OUT" "POST_MERGE_EXCLUDED=owner/repo#7	report	- effort_evidence: 本番への適用の記録" \
    && ! has_line "$OUT" "POST_MERGE_HIT="; then
    ok "P1w: 完了報告の閉じた工数ブロックも、根拠の 2 行だけを外して通過する"
  else
    bad "P1w: 完了報告の除外が違う（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  _ff_pm_comments "$pm/effort-report-hit.json" "$(printf '%s\n' '<!-- close-issue-report:PR-7 -->' '<!-- ff-effort:begin -->' '- effort_basis: 本番適用を報告に書く' '<!-- ff-effort:end -->' '| 本番適用は承認を得て行う | 達成 |')"
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS="$paths" STUB_ISSUE_BODY_FILE="$pm/plain.md" STUB_ISSUE_COMMENTS_FILE="$pm/effort-report-hit.json" run_finish "$WORK" precheck 7
  if _ff_pm_stopped && has_line "$OUT" "POST_MERGE_HIT_COUNT=1" \
    && has_line "$OUT" "POST_MERGE_HIT=owner/repo#7	report	| 本番適用は承認を得て行う | 達成 |" \
    && has_line "$OUT" "POST_MERGE_EXCLUDED=owner/repo#7	report	- effort_basis: 本番適用を報告に書く" \
    && ! has_line "$OUT" "POST_MERGE_HIT=owner/repo#7	report	- effort_basis:"; then
    ok "P1x: 完了報告でも地の文は止め、根拠行は除外として出す"
  else
    bad "P1x: 完了報告の地の文の扱いが違う（rc=${RC}）: ${OUT} / ${ERR}"
  fi

  # ── パスの条件 ──
  : >"$STUB_LOG"
  PR_FILES_JSON='[{"path":"docs/a.md"}]'
  write_pr_json "Closes #${PRN}" '[]'
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS='seed.txt' STUB_ISSUE_BODY_FILE="$pm/hit.md" run_finish "$WORK" precheck 7
  if _ff_pm_passed && has_line "$OUT" "POST_MERGE_GATE=no-path" && ! has_line "$OUT" "POST_MERGE_HIT" \
    && ! has_text "$(cat "$STUB_LOG")" "--json comments"; then
    ok "P2: 設定したパスを含まない PR は判定せず、コメントも取りに行かない"
  else
    bad "P2: パスの条件が効いていない（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  for spec in 'migrations|migrations/211_close.sql' 'migrations/|migrations/211_close.sql' 'migrations/*.sql|migrations/211_close.sql' 'docs/a.md:migrations|migrations/211_close.sql'; do
    PR_FILES_JSON="$_ff_pm_files"
    write_pr_json "Closes #${PRN}" '[]'
    FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS="${spec%%|*}" STUB_ISSUE_BODY_FILE="$pm/hit.md" run_finish "$WORK" precheck 7
    if _ff_pm_stopped && has_line "$OUT" "POST_MERGE_PATH=${spec##*|}"; then
      ok "P2b: パス指定 ${spec%%|*} は配下のファイルに一致する"
    else
      bad "P2b: パス指定 ${spec%%|*} が一致しない（rc=${RC}）: ${OUT} / ${ERR}"
    fi
  done
  PR_FILES_JSON='[{"path":"docs_old/x.sql"}]'
  write_pr_json "Closes #${PRN}" '[]'
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS='docs' STUB_ISSUE_BODY_FILE="$pm/hit.md" run_finish "$WORK" precheck 7
  if _ff_pm_passed && has_line "$OUT" "POST_MERGE_GATE=no-path"; then
    ok "P2c: ディレクトリ指定は同じ接頭辞の別ディレクトリに一致しない"
  else
    bad "P2c: 接頭辞だけで一致している（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  # gh pr view --json files は 100 件で切れる。実 PR の 101 件目以降に一致するファイルがある回の再現
  PR_FILES_JSON="$(jq -cn '[range(0;100) | {path: "decoy/\(.).txt"}]')"
  write_pr_json "Closes #${PRN}" '[]'
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS='x.txt' STUB_ISSUE_BODY_FILE="$pm/hit.md" run_finish "$WORK" precheck 7
  if _ff_pm_stopped && has_line "$OUT" "POST_MERGE_PATH=x.txt"; then
    ok "P2d: API の一覧が 100 件（切り詰めの可能性）の回は git の差分で読み直し、切れた側の一致で止める"
  else
    bad "P2d: 切り詰めの回に一致を落としている（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  PR_FILES_JSON="$(jq -cn '[range(0;99) | {path: "decoy/\(.).txt"}]')"
  write_pr_json "Closes #${PRN}" '[]'
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS='x.txt' STUB_ISSUE_BODY_FILE="$pm/hit.md" run_finish "$WORK" precheck 7
  if _ff_pm_passed && has_line "$OUT" "POST_MERGE_GATE=no-path"; then
    ok "P2e: 99 件までは API の一覧を正として読む"
  else
    bad "P2e: 切り詰めの境界が違う（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  # API の一覧が空の回も切り詰めと同じく git で読む
  PR_FILES_JSON='[]'
  write_pr_json "Closes #${PRN}" '[]'
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS='x.txt' STUB_ISSUE_BODY_FILE="$pm/hit.md" run_finish "$WORK" precheck 7
  if _ff_pm_stopped && has_line "$OUT" "POST_MERGE_PATH=x.txt"; then
    ok "P2d2: API の一覧が空の回は git の差分で読み直す"
  else
    bad "P2d2: 空の一覧を「パスなし」へ倒している（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  # jq.exe の -r は行末が CRLF になる。行末の CR が照合と出力へ混ざらないこと
  PR_FILES_JSON='[{"path":"migrations/211_close.sql\r"}]'
  write_pr_json "Closes #${PRN}" '[]'
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS='migrations/211_close.sql' STUB_ISSUE_BODY_FILE="$pm/hit.md" run_finish "$WORK" precheck 7
  if _ff_pm_stopped && has_line "$OUT" "POST_MERGE_PATH=migrations/211_close.sql" && [ "$(printf '%s' "$OUT" | tr -cd '\r' | wc -c | tr -d ' ')" = "0" ]; then
    ok "P2d3: 行末の CR を外してパスを照合し、出力へ残さない"
  else
    bad "P2d3: 行末の CR の扱いが違う（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  # どのファイルにも当たらない要素は、誤字でも改名でも毎回 no-path になり判定が黙って消える
  local typo
  for typo in 'migraton/**' 'seed.txt:migraton' '.' '../x'; do
    PR_FILES_JSON='[{"path":"seed.txt"}]'
    write_pr_json "Closes #${PRN}" '[]'
    FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS="$typo" STUB_ISSUE_BODY_FILE="$pm/hit.md" run_finish "$WORK" precheck 7
    if _ff_pm_undetermined_no_merge && has_text "$ERR" "どのファイルにも一致しません"; then
      ok "P2h: どのファイルにも当たらない要素は rc 2（${typo}）"
    else
      bad "P2h: 当たらない要素を受け入れている（${typo}、rc=${RC}）: ${OUT} / ${ERR}"
    fi
  done
  # サブディレクトリから起動しても、追跡中のファイルはルート基準で読む
  PR_FILES_JSON='[{"path":"docs/a.md"}]'
  write_pr_json "Closes #${PRN}" '[]'
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS='seed.txt' STUB_ISSUE_BODY_FILE="$pm/hit.md" run_finish "$WORK/docs" precheck 7
  if _ff_pm_passed && has_line "$OUT" "POST_MERGE_GATE=no-path"; then
    ok "P2h2: サブディレクトリからの起動でもパスの要素をルート基準で確かめる"
  else
    bad "P2h2: 起動位置で要素の検査が変わる（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  # diff.relative=true の導入先がサブディレクトリから起動しても、cwd の外の変更を落とさない
  PR_FILES_JSON="$(jq -cn '[range(0;100) | {path: "decoy/\(.).txt"}]')"
  write_pr_json "Closes #${PRN}" '[]'
  g -C "$WORK" config diff.relative true
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS='x.txt' STUB_ISSUE_BODY_FILE="$pm/hit.md" run_finish "$WORK/docs" precheck 7
  g -C "$WORK" config --unset diff.relative
  if _ff_pm_stopped && has_line "$OUT" "POST_MERGE_PATH=x.txt"; then
    ok "P2h3: diff.relative=true でも git の差分をルート基準で読む"
  else
    bad "P2h3: git の設定で変更ファイルが消えている（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  # git の引用で一致を落とさないこと（`"` を含むパスは core.quotePath=false でも引用される）
  local q_work="$pm/quoted-work" q_head="" q_file='migrations/a"b.sql' q_real_head="$HEAD_OID"
  if g init -q --bare "$pm/quoted.git" >/dev/null 2>&1 && g clone -q "$pm/quoted.git" "$q_work" >/dev/null 2>&1 \
    && g -C "$q_work" checkout -q -B develop >/dev/null 2>&1 && printf 'seed\n' >"$q_work/seed.txt" \
    && g -C "$q_work" add -A >/dev/null 2>&1 && g -C "$q_work" commit -qm seed >/dev/null 2>&1 \
    && g -C "$q_work" push -q origin develop >/dev/null 2>&1 && g -C "$q_work" checkout -q -b 'feature/#7-x' >/dev/null 2>&1 \
    && mkdir -p "$q_work/migrations" && { printf 'x\n' >"$q_work/$q_file"; } 2>/dev/null; then
    g -C "$q_work" add -A >/dev/null 2>&1; g -C "$q_work" commit -qm 'fix: x' >/dev/null 2>&1
    g -C "$q_work" push -q -u origin 'feature/#7-x' >/dev/null 2>&1; g -C "$q_work" remote set-head origin develop >/dev/null 2>&1
    q_head="$(g -C "$q_work" rev-parse HEAD)"
    PR_FILES_JSON="$(jq -cn '[range(0;100) | {path: "decoy/\(.).txt"}]')"
    HEAD_OID="$q_head"
    write_pr_json "Closes #${PRN}" '[]'
    HEAD_OID="$q_real_head"
    FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS='migrations/**' STUB_ISSUE_BODY_FILE="$pm/hit.md" run_finish "$q_work" precheck 7
    if _ff_pm_stopped && has_line "$OUT" "POST_MERGE_PATH=${q_file}"; then
      ok "P2i: 引用が付くパスも git の差分から元の名前で照合する"
    else
      bad "P2i: 引用されたパスの一致を落としている（rc=${RC}）: ${OUT} / ${ERR}"
    fi
  else
    # Windows のファイルシステムは `"` をファイル名に使えない
    echo "  ○ skip: P2i はファイル名に二重引用符を使えない環境では実測しない"
  fi
  local real_head="$HEAD_OID"
  PR_FILES_JSON="$(jq -cn '[range(0;100) | {path: "decoy/\(.).txt"}]')"
  HEAD_OID="$(printf '%040d' 7)"
  write_pr_json "Closes #${PRN}" '[]'
  HEAD_OID="$real_head"
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS='x.txt' STUB_ISSUE_BODY_FILE="$pm/hit.md" run_finish "$WORK" precheck 7
  if _ff_pm_undetermined_no_merge && has_text "$ERR" "変更ファイル"; then
    ok "P2f: 切り詰めの回に git でも読めなければ rc 2（一致なしと読まない）"
  else
    bad "P2f: 読めない変更ファイルを一致なしへ倒している（rc=${RC}）: ${OUT} / ${ERR}"
  fi

  # ── AC2: Refs へ変えると止まらない ──
  PR_FILES_JSON="$_ff_pm_files"
  write_pr_json "Refs #${PRN}" '[]'
  : >"$STUB_LOG"
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS="$paths" STUB_ISSUE_BODY_FILE="$pm/hit.md" run_finish "$WORK" precheck 7 --subject 'work' --body "Refs #${PRN}"
  if _ff_pm_passed && has_line "$OUT" "REFS=owner/repo#7" && has_line "$OUT" "POST_MERGE_GATE=no-closes" \
    && ! has_line "$OUT" "POST_MERGE_HIT" && ! has_text "$(cat "$STUB_LOG")" "issue view"; then
    ok "P3: Refs へ変えると Issue を読まず止めない（AC2）"
  else
    bad "P3: Refs で止まっている（rc=${RC}）: ${OUT} / ${ERR}"
  fi

  # ── AC3: --ack-post-merge ──
  write_pr_json "Closes #${PRN}" '[]'
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS="$paths" STUB_ISSUE_BODY_FILE="$pm/hit.md" run_finish "$WORK" precheck 7 --ack-post-merge 'owner/repo#7' --ack-post-merge-reason '本番適用は完了し読み戻し済み'
  if _ff_pm_passed && has_line "$OUT" "POST_MERGE_GATE=acked" \
    && has_line "$OUT" "POST_MERGE_ACKED=owner/repo#7	本番適用は完了し読み戻し済み" \
    && has_line "$OUT" "POST_MERGE_HIT=owner/repo#7	body	${_ff_pm_hit_body}"; then
    ok "P4: --ack-post-merge は止めず、理由と一致行を出力へ残す（AC3）"
  else
    bad "P4: ack の扱いが違う（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  for form in "#${PRN}" "${PRN}" "https://github.com/Owner/Repo/issues/${PRN}" "Owner/Repo#${PRN}"; do
    FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS="$paths" STUB_ISSUE_BODY_FILE="$pm/hit.md" run_finish "$WORK" precheck 7 --ack-post-merge "$form" --ack-post-merge-reason '確認済み'
    if _ff_pm_passed && has_line "$OUT" "POST_MERGE_ACKED=owner/repo#7	確認済み"; then
      ok "P4b: ack の表記 ${form} を owner/repo#N へ揃える（--ack-unchecked と同じ）"
    else
      bad "P4b: ack の表記 ${form} の扱いが違う（rc=${RC}）: ${OUT} / ${ERR}"
    fi
  done
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS="$paths" STUB_ISSUE_BODY_FILE="$pm/hit.md" run_finish "$WORK" precheck 7 --ack-post-merge 'owner/repo#8' --ack-post-merge-reason '別件'
  if _ff_pm_stopped && has_line "$OUT" "POST_MERGE_ACKED=owner/repo#8	別件"; then
    ok "P4c: 別 Issue の ack は対象の一致を消さない"
  else
    bad "P4c: 別 Issue の ack が対象を消している（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  local second=8
  write_pr_json "Closes #${PRN}, Closes #${second}" '[]'
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS="$paths" STUB_ISSUE_BODY_FILE="$pm/hit.md" run_finish "$WORK" precheck 7 --ack-post-merge 'owner/repo#7' --ack-post-merge-reason '片方'
  if _ff_pm_stopped && has_line "$OUT" "POST_MERGE_HIT=owner/repo#8	body	${_ff_pm_hit_body}"; then
    ok "P4d: 複数の Closes は Issue ごとに ack が要る"
  else
    bad "P4d: 片方の ack で通っている（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS="$paths" STUB_ISSUE_BODY_FILE="$pm/hit.md" run_finish "$WORK" precheck 7 \
    --ack-post-merge 'owner/repo#7' --ack-post-merge-reason '済み 7' --ack-post-merge "#${second}" --ack-post-merge-reason '済み 8'
  if _ff_pm_passed && has_line "$OUT" "POST_MERGE_ACKED=owner/repo#7	済み 7" && has_line "$OUT" "POST_MERGE_ACKED=owner/repo#8	済み 8"; then
    ok "P4e: ack は繰り返せて、理由は Issue ごとに残る"
  else
    bad "P4e: 繰り返しの ack が違う（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  write_pr_json "Closes #${PRN}" '[]'
  local bad_ack
  : >"$STUB_LOG"
  run_finish "$WORK" precheck 7 --ack-post-merge 'owner/repo#7'
  if [ "$RC" -eq 2 ] && has_text "$ERR" "--ack-post-merge-reason" && _ff_pm_no_gh; then
    ok "P5: 理由の無い ack は gh を呼ぶ前に rc 2"
  else
    bad "P5: 理由の無い ack の扱いが違う（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  for bad_ack in '   ' "$(printf 'a\nPRECHECK=ready')" "$(printf 'a\tb')" "$(printf 'a\rb')"; do
    : >"$STUB_LOG"
    run_finish "$WORK" precheck 7 --ack-post-merge 'owner/repo#7' --ack-post-merge-reason "$bad_ack"
    if [ "$RC" -eq 2 ] && has_text "$ERR" "--ack-post-merge-reason" && _ff_pm_no_gh && ! has_line "$OUT" "PRECHECK=ready"; then
      ok "P5b: 空白だけ・改行・タブ・CR の理由は gh を呼ぶ前に rc 2（出力の行を偽造させない）"
    else
      bad "P5b: 理由の検査が違う（rc=${RC}）: ${OUT} / ${ERR}"
    fi
  done
  : >"$STUB_LOG"
  run_finish "$WORK" precheck 7 --ack-post-merge-reason '理由だけ'
  if [ "$RC" -eq 2 ] && has_text "$ERR" "--ack-post-merge" && _ff_pm_no_gh; then
    ok "P5c: 理由だけの指定は rc 2"
  else
    bad "P5c: 理由だけの指定の扱いが違う（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS="$paths" STUB_ISSUE_BODY_FILE="$pm/hit.md" run_finish "$WORK" precheck 7 --ack-post-merge 'not a token' --ack-post-merge-reason '理由'
  if [ "$RC" -eq 2 ] && has_text "$ERR" "--ack-post-merge の値" && ! has_text "$OUT" "MERGE_COMMAND_BEGIN"; then
    ok "P5d: 解釈できない ack の値は rc 2"
  else
    bad "P5d: 不正な ack の値の扱いが違う（rc=${RC}）: ${OUT} / ${ERR}"
  fi

  # ── AC4: 設定が無い導入先 ──
  : >"$STUB_LOG"
  STUB_ISSUE_BODY_FILE="$pm/hit.md" run_finish "$WORK" precheck 7
  if _ff_pm_passed && ! has_text "$OUT" "POST_MERGE" && ! has_text "$ERR" "POST_MERGE" \
    && ! has_text "$ERR" "マージ後" && ! has_text "$(cat "$STUB_LOG")" "--json comments"; then
    ok "P6: 設定が無ければ語とパスが揃っても出力へ何も足さず、コメントも取りに行かない（AC4）"
  else
    bad "P6: 設定なしの出力が変わっている（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  STUB_ISSUE_BODY_FILE="$pm/effort-only.md" run_finish "$WORK" precheck 7
  if _ff_pm_passed && ! has_text "$OUT" "POST_MERGE" && ! has_text "$ERR" "POST_MERGE"; then
    ok "P6d: 工数ブロックに語があっても、設定が無い導入先は除外行を出さない"
  else
    bad "P6d: 設定なしで工数ブロックの行が出ている（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  STUB_ISSUE_BODY_FILE="$pm/hit.md" run_finish "$WORK" precheck 7 --ack-post-merge 'owner/repo#7' --ack-post-merge-reason '理由'
  if _ff_pm_passed && has_line "$OUT" "POST_MERGE_ACKED=owner/repo#7	理由" && ! has_line "$OUT" "POST_MERGE_GATE="; then
    ok "P6b: 設定が無い導入先の ack は受け取って記録だけ残す（--ack-unchecked と同じ）"
  else
    bad "P6b: 設定なしの ack の扱いが違う（rc=${RC}）: ${OUT} / ${ERR}"
  fi

  # 設定が無ければ変更ファイルも読まない。100 件の一覧 + 解決できない先端でも、この判定では止まらない
  local no_cfg_head="$HEAD_OID"
  PR_FILES_JSON="$(jq -cn '[range(0;100) | {path: "decoy/\(.).txt"}]')"
  HEAD_OID="$(printf '%040d' 7)"
  write_pr_json "Closes #${PRN}" '[]'
  HEAD_OID="$no_cfg_head"
  STUB_ISSUE_BODY_FILE="$pm/hit.md" run_finish "$WORK" precheck 7
  if ! has_text "$ERR" "変更ファイル" && ! has_text "$OUT" "POST_MERGE"; then
    ok "P6c: 設定が無い導入先は変更ファイルの読み直しを走らせない"
  else
    bad "P6c: 設定なしで変更ファイルを読んでいる（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  PR_FILES_JSON="$_ff_pm_files"
  write_pr_json "Closes #${PRN}" '[]'

  # ── AC5: 取得失敗 ──
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS="$paths" STUB_ISSUE_MISSING=1 run_finish "$WORK" precheck 7
  if _ff_pm_undetermined_no_merge; then
    ok "P7: Issue 本文の取得失敗は rc 2 で、一致なしと読まない（AC5）"
  else
    bad "P7: 本文の取得失敗の扱いが違う（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS="$paths" STUB_ISSUE_BODY_FILE="$pm/plain.md" STUB_ISSUE_COMMENTS_MISSING=1 run_finish "$WORK" precheck 7
  if _ff_pm_undetermined_no_merge && has_text "$ERR" "コメント" && has_text "$ERR" "一致なしとは読まない"; then
    ok "P7b: コメントの取得失敗は rc 2 で、一致なしと読まない（AC5）"
  else
    bad "P7b: コメントの取得失敗の扱いが違う（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  local broken
  for broken in '{"comments":null}' '{"comments":"x"}' '{"comments":[1]}' '{"comments":[{"body":3}]}' '{}' 'not json'; do
    printf '%s\n' "$broken" >"$pm/broken.json"
    FF_POST_MERGE_TERMS="$terms" FF_POST_MERGE_PATHS="$paths" STUB_ISSUE_BODY_FILE="$pm/plain.md" STUB_ISSUE_COMMENTS_FILE="$pm/broken.json" run_finish "$WORK" precheck 7
    if _ff_pm_undetermined_no_merge && has_text "$ERR" "コメント"; then
      ok "P7c: 解釈できないコメントの応答は rc 2（${broken}）"
    else
      bad "P7c: 解釈できない応答を 0 件へ倒している（rc=${RC}、${broken}）: ${OUT} / ${ERR}"
    fi
  done

  # ── 設定の検査（PR を読む前に rc 2） ──
  local spec_t spec_p
  while IFS='|' read -r spec_t spec_p; do
    : >"$STUB_LOG"
    (
      unset FF_POST_MERGE_TERMS FF_POST_MERGE_PATHS
      [ "$spec_t" = '<unset>' ] || export FF_POST_MERGE_TERMS="$spec_t"
      [ "$spec_p" = '<unset>' ] || export FF_POST_MERGE_PATHS="$spec_p"
      run_finish "$WORK" precheck 7
      printf '%s\n' "$RC" >"$pm/cfg.rc"; printf '%s\n' "$ERR" >"$pm/cfg.err"
    )
    if [ "$(cat "$pm/cfg.rc")" = "2" ] && grep -q -e FF_POST_MERGE_TERMS -e FF_POST_MERGE_PATHS "$pm/cfg.err" && _ff_pm_no_gh; then
      ok "P8: 不正な設定は gh を呼ぶ前に rc 2（語='${spec_t}' パス='${spec_p}'）"
    else
      bad "P8: 不正な設定を受け入れている（語='${spec_t}' パス='${spec_p}'）: $(cat "$pm/cfg.err")"
    fi
  done <<'SPECS'
本番|<unset>
<unset>|migrations
|migrations
本番|
:本番|migrations
本番:|migrations
本番::production|migrations
 本番|migrations
本番|migrations:
本番|:migrations
本番|migrations: docs
本番|/migrations
本番|./migrations
SPECS
  PR_FILES_JSON=""
  unset MULTI_AGENT_SECURITY_REVIEW
  write_pr_json "Closes #${PRN}" '[]'
}
