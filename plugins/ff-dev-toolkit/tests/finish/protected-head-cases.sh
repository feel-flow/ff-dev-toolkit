#!/usr/bin/env bash
# finish/verify.sh から呼ぶ。保護ブランチの head は生成コマンドでも削除 script でも消えない。
# headRefOid は origin の develop の実 OID にする。別 OID だと削除 script が
# preserved-different-oid で ref を残し、保護を外しても緑になる。
# gh stub は --delete-branch があると origin の対象 ref を消す。尾だけを落としても
# --delete-branch が残っていれば develop が消えて赤になる。

_ff_finish_protected_head_cases() {
  local p_saved_head p_develop p_cmd p_after p_rc p_out p_branch p_err
  p_saved_head="$HEAD_OID"
  p_develop="$(g -C "$WORK" rev-parse refs/heads/develop)"
  p_err="$TMP/protect-script.err"

  _ff_protect_restore() {
    g -C "$WORK" worktree remove --force "$TMP/wt-protect-develop" >/dev/null 2>&1 || true
    g -C "$WORK" checkout -q 'feature/#7-x'
    unset FF_MERGE_CLEANUP_PROTECT_BRANCHES PR_HEAD_REF PR_BASE_REF PR_CROSS
    HEAD_OID="$p_saved_head"
    record pass
  }

  echo
  echo "== P. precheck: 保護ブランチの head は削除しない =="
  g -C "$WORK" checkout -q -B feature/protect-runner "$p_develop"
  record pass
  g -C "$WORK" push -q origin \
    "$p_develop:refs/heads/master" \
    "$p_develop:refs/heads/main" \
    "$p_develop:refs/heads/staging/x" \
    "$p_develop:refs/heads/release/1.0" \
    "$p_develop:refs/heads/lts/1" \
    "$p_develop:refs/heads/feature/deletable" \
    "$p_develop:refs/heads/fixture-protect-stub"

  mkdir -p "$TMP/protect-bin"
  cat >"$TMP/protect-bin/gh" <<'GH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"${P_GH_LOG:?}"
[ "${1:-} ${2:-}" = "pr merge" ] || { echo "fixture: expected pr merge" >&2; exit 91; }
del=0
for a in "$@"; do
  [ "$a" = "--delete-branch" ] && del=1
done
if [ "$del" -eq 1 ]; then
  git --git-dir="${P_ORIGIN:?}" update-ref -d "${P_REF:?}"
fi
exit 0
GH
  chmod +x "$TMP/protect-bin/gh"

  # stub 自体が --delete-branch で ref を消すことを先に測る。消さない stub だと実行検査が偽緑になる。
  : >"$TMP/protect-gh.log"
  ( PATH="$TMP/protect-bin:$PATH" P_GH_LOG="$TMP/protect-gh.log" P_ORIGIN="$TMP/origin.git" \
    P_REF="refs/heads/fixture-protect-stub" bash -c 'gh pr merge 7 --repo https://github.com/owner/repo --delete-branch' ) \
    >/dev/null 2>&1 || true
  p_after="$(g --git-dir="$TMP/origin.git" rev-parse --verify refs/heads/fixture-protect-stub 2>/dev/null || true)"
  if [ -z "$p_after" ]; then
    ok "P0: gh stub は --delete-branch があると origin の ref を消す"
  else
    bad "P0: gh stub が --delete-branch で ref を消さない（${p_after}）"
  fi

  HEAD_OID="$p_develop"
  PR_HEAD_REF=develop
  PR_BASE_REF=master
  write_pr_json "Closes #${PRN}" '[]'
  run_finish "$WORK" precheck 7
  p_cmd="$(printf '%s\n' "$OUT" | awk '/^MERGE_COMMAND_BEGIN$/ { c=1; next } /^MERGE_COMMAND_END$/ { c=0 } c')"
  if [ "$RC" -eq 0 ] && has_line "$OUT" "HEAD_DELETE=skipped-protected" \
    && has_line "$OUT" "HEAD_DELETE_RESULT=skipped-protected" \
    && has_line "$OUT" "DELETE_BRANCH_MODE=delete-branch" \
    && has_text "$p_cmd" "gh pr merge" && ! has_text "$p_cmd" "--delete-branch" \
    && ! has_text "$p_cmd" "ff-delete-merged-head" && ! has_text "$OUT" "HEAD_DELETE=lease"; then
    ok "P1: head=develop で保持が無ければ --delete-branch も削除の尾も付けない"
  else
    bad "P1: 保護 head の生成が違う（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  p_rc=0
  : >"$TMP/protect-gh.log"
  ( PATH="$TMP/protect-bin:$PATH" P_GH_LOG="$TMP/protect-gh.log" P_ORIGIN="$TMP/origin.git" \
    P_REF="refs/heads/develop" bash -c "$p_cmd" ) >"$TMP/protect-run.out" 2>&1 || p_rc=$?
  p_after="$(g --git-dir="$TMP/origin.git" rev-parse --verify refs/heads/develop 2>/dev/null || true)"
  if [ "$p_rc" -eq 0 ] && [ "$p_after" = "$p_develop" ]; then
    ok "P1b: head=develop の生成コマンドを実行しても develop の ref が残る"
  else
    bad "P1b: 生成コマンドが develop を残さない（rc=${p_rc} after=${p_after}）: $(cat "$TMP/protect-run.out")"
    g --git-dir="$TMP/origin.git" update-ref refs/heads/develop "$p_develop"
  fi

  g -C "$WORK" worktree add -q "$TMP/wt-protect-develop" develop
  run_finish "$WORK" precheck 7
  p_cmd="$(printf '%s\n' "$OUT" | awk '/^MERGE_COMMAND_BEGIN$/ { c=1; next } /^MERGE_COMMAND_END$/ { c=0 } c')"
  if [ "$RC" -eq 0 ] && has_line "$OUT" "DELETE_BRANCH_MODE=separate-push" \
    && has_line "$OUT" "HEAD_HELD_BY=" && has_line "$OUT" "HEAD_DELETE=skipped-protected" \
    && has_line "$OUT" "HEAD_DELETE_RESULT=skipped-protected" \
    && ! has_text "$p_cmd" "--delete-branch" && ! has_text "$p_cmd" "ff-delete-merged-head" \
    && ! has_line "$OUT" "HEAD_DELETE=lease"; then
    ok "P2: develop を別 worktree が保持していても削除の尾を付けない"
  else
    bad "P2: 保持中の保護 head の生成が違う（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  p_rc=0
  ( PATH="$TMP/protect-bin:$PATH" P_GH_LOG="$TMP/protect-gh.log" P_ORIGIN="$TMP/origin.git" \
    P_REF="refs/heads/develop" bash -c "$p_cmd" ) >"$TMP/protect-run.out" 2>&1 || p_rc=$?
  p_after="$(g --git-dir="$TMP/origin.git" rev-parse --verify refs/heads/develop 2>/dev/null || true)"
  if [ "$p_rc" -eq 0 ] && [ "$p_after" = "$p_develop" ]; then
    ok "P2b: 保持中の生成コマンドを実行しても develop の ref が残る"
  else
    bad "P2b: 保持中の生成コマンドが develop を残さない（rc=${p_rc} after=${p_after}）: $(cat "$TMP/protect-run.out")"
    g --git-dir="$TMP/origin.git" update-ref refs/heads/develop "$p_develop"
  fi

  PR_CROSS=true write_pr_json "Closes #${PRN}" '[]'
  run_finish "$WORK" precheck 7
  if [ "$RC" -eq 0 ] && has_line "$OUT" "HEAD_DELETE=skipped-fork" \
    && ! has_line "$OUT" "HEAD_DELETE=skipped-protected" \
    && ! has_text "$OUT" "ff-delete-merged-head" && has_text "$ERR" "fork の PR"; then
    ok "P3: fork の head 名が develop でも skipped-fork のまま削除を生成しない"
  else
    bad "P3: fork × 保護名の生成が違う（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  unset PR_CROSS
  g -C "$WORK" worktree remove --force "$TMP/wt-protect-develop" >/dev/null 2>&1 || true

  # 保持なし（delete-branch 経路）では fork / 判定不能でも --delete-branch が残りうる。名前の保護は
  # is_cross と独立に掛かり、HEAD_DELETE の契約は変えない。実行して develop が残ることまで測る。
  for p_branch in true null; do
    PR_CROSS="$p_branch" write_pr_json "Closes #${PRN}" '[]'
    run_finish "$WORK" precheck 7
    p_cmd="$(printf '%s\n' "$OUT" | awk '/^MERGE_COMMAND_BEGIN$/ { c=1; next } /^MERGE_COMMAND_END$/ { c=0 } c')"
    if [ "$RC" -eq 0 ] && has_line "$OUT" "DELETE_BRANCH_MODE=delete-branch" \
      && has_text "$p_cmd" "gh pr merge" && ! has_text "$p_cmd" "--delete-branch" \
      && ! has_text "$p_cmd" "ff-delete-merged-head" && ! has_text "$OUT" "HEAD_DELETE=" \
      && has_text "$ERR" "保護ブランチ"; then
      ok "P3b: isCrossRepository=${p_branch} で保持が無くても head=develop に --delete-branch を付けない"
    else
      bad "P3b: isCrossRepository=${p_branch} × develop × 保持なしの生成が違う（rc=${RC}）: ${OUT} / ${ERR}"
    fi
    p_rc=0
    ( PATH="$TMP/protect-bin:$PATH" P_GH_LOG="$TMP/protect-gh.log" P_ORIGIN="$TMP/origin.git" \
      P_REF="refs/heads/develop" bash -c "$p_cmd" ) >"$TMP/protect-run.out" 2>&1 || p_rc=$?
    p_after="$(g --git-dir="$TMP/origin.git" rev-parse --verify refs/heads/develop 2>/dev/null || true)"
    if [ "$p_rc" -eq 0 ] && [ "$p_after" = "$p_develop" ]; then
      ok "P3c: isCrossRepository=${p_branch} の生成コマンドを実行しても develop の ref が残る"
    else
      bad "P3c: isCrossRepository=${p_branch} の生成コマンドが develop を残さない（rc=${p_rc} after=${p_after}）: $(cat "$TMP/protect-run.out")"
      g --git-dir="$TMP/origin.git" update-ref refs/heads/develop "$p_develop"
    fi
  done
  # 広げた条件の反対側: 保護名でない fork の head は --delete-branch を残し、不正な設定では fork でも止める
  PR_HEAD_REF='feature/deletable'
  PR_CROSS=true write_pr_json "Closes #${PRN}" '[]'
  run_finish "$WORK" precheck 7
  p_cmd="$(printf '%s\n' "$OUT" | awk '/^MERGE_COMMAND_BEGIN$/ { c=1; next } /^MERGE_COMMAND_END$/ { c=0 } c')"
  if [ "$RC" -eq 0 ] && has_text "$p_cmd" "--delete-branch" && ! has_text "$OUT" "HEAD_DELETE="; then
    ok "P3d: fork で保護名でない head は --delete-branch を残す"
  else
    bad "P3d: fork × 非保護名の生成が違う（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  PR_HEAD_REF=develop
  PR_CROSS=true write_pr_json "Closes #${PRN}" '[]'
  FF_MERGE_CLEANUP_PROTECT_BRANCHES='release/*:' run_finish "$WORK" precheck 7
  if [ "$RC" -eq 2 ] && ! has_text "$OUT" "MERGE_COMMAND_BEGIN" && has_text "$ERR" "空のパターンがあります"; then
    ok "P3e: fork の delete-branch 経路でも不正な保護設定は rc 2 で merge コマンドを出さない"
  else
    bad "P3e: fork × 不正設定が fail-open（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  unset PR_CROSS
  write_pr_json "Closes #${PRN}" '[]'

  # bash -c 埋め込み形（BASH_SOURCE が空）でも保護名は照会せずに skipped-protected で返す
  p_rc=0
  p_out="$(bash -c "$(cat "$PLUGIN_ROOT/scripts/lib/finish-delete-merged-head.sh")" ff-delete-merged-head "$WORK" develop "$p_develop" 2>"$p_err")" || p_rc=$?
  p_after="$(g --git-dir="$TMP/origin.git" rev-parse --verify refs/heads/develop 2>/dev/null || true)"
  if [ "$p_rc" -eq 0 ] && [ "$p_out" = "HEAD_DELETE_RESULT=skipped-protected" ] && [ "$p_after" = "$p_develop" ]; then
    ok "P4a: bash -c 埋め込み形でも develop は skipped-protected で残る"
  else
    bad "P4a: 埋め込み形の保護が違う（rc=${p_rc} out=${p_out} after=${p_after}）: $(cat "$p_err")"
    g --git-dir="$TMP/origin.git" update-ref refs/heads/develop "$p_develop"
  fi

  for p_branch in develop main master staging/x release/1.0; do
    p_rc=0
    p_out="$(bash "$PLUGIN_ROOT/scripts/lib/finish-delete-merged-head.sh" "$WORK" "$p_branch" "$p_develop" 2>"$p_err")" || p_rc=$?
    p_after="$(g --git-dir="$TMP/origin.git" rev-parse --verify "refs/heads/$p_branch" 2>/dev/null || true)"
    if [ "$p_rc" -eq 0 ] && [ "$p_out" = "HEAD_DELETE_RESULT=skipped-protected" ] \
      && [ "$p_after" = "$p_develop" ] && has_text "$(cat "$p_err")" "保護ブランチ"; then
      ok "P4: ${p_branch} は削除 script が skipped-protected で ref を残す"
    else
      bad "P4: ${p_branch} の削除 script が違う（rc=${p_rc} out=${p_out} after=${p_after}）: $(cat "$p_err")"
      g --git-dir="$TMP/origin.git" update-ref "refs/heads/$p_branch" "$p_develop"
    fi
  done

  PR_HEAD_REF='lts/1'
  PR_BASE_REF=master
  write_pr_json "Closes #${PRN}" '[]'
  FF_MERGE_CLEANUP_PROTECT_BRANCHES='lts/*' run_finish "$WORK" precheck 7
  p_cmd="$(printf '%s\n' "$OUT" | awk '/^MERGE_COMMAND_BEGIN$/ { c=1; next } /^MERGE_COMMAND_END$/ { c=0 } c')"
  if [ "$RC" -eq 0 ] && has_line "$OUT" "HEAD_DELETE=skipped-protected" && ! has_text "$p_cmd" "--delete-branch"; then
    ok "P5: 追加パターン lts/* の head は削除を付けない"
  else
    bad "P5: lts/* の生成が違う（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  PR_HEAD_REF='release/1.0'
  write_pr_json "Closes #${PRN}" '[]'
  FF_MERGE_CLEANUP_PROTECT_BRANCHES='lts/*' run_finish "$WORK" precheck 7
  p_cmd="$(printf '%s\n' "$OUT" | awk '/^MERGE_COMMAND_BEGIN$/ { c=1; next } /^MERGE_COMMAND_END$/ { c=0 } c')"
  if [ "$RC" -eq 0 ] && has_text "$p_cmd" "--delete-branch" && ! has_line "$OUT" "HEAD_DELETE=skipped-protected"; then
    ok "P5b: lts/* だけを追加した回は release/1.0 を保護しない"
  else
    bad "P5b: カスタム追加パターンが release/* を残している（rc=${RC}）: ${OUT} / ${ERR}"
  fi

  PR_HEAD_REF=develop
  write_pr_json "Closes #${PRN}" '[]'
  FF_MERGE_CLEANUP_PROTECT_BRANCHES=none run_finish "$WORK" precheck 7
  p_cmd="$(printf '%s\n' "$OUT" | awk '/^MERGE_COMMAND_BEGIN$/ { c=1; next } /^MERGE_COMMAND_END$/ { c=0 } c')"
  if [ "$RC" -eq 0 ] && has_line "$OUT" "HEAD_DELETE=skipped-protected" && ! has_text "$p_cmd" "--delete-branch"; then
    ok "P6: none でも develop は保護されたまま"
  else
    bad "P6: none がハードコード保護を外している（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  p_rc=0
  p_out="$(FF_MERGE_CLEANUP_PROTECT_BRANCHES=none bash "$PLUGIN_ROOT/scripts/lib/finish-delete-merged-head.sh" "$WORK" develop "$p_develop" 2>"$p_err")" || p_rc=$?
  p_after="$(g --git-dir="$TMP/origin.git" rev-parse --verify refs/heads/develop 2>/dev/null || true)"
  if [ "$p_rc" -eq 0 ] && [ "$p_out" = "HEAD_DELETE_RESULT=skipped-protected" ] && [ "$p_after" = "$p_develop" ]; then
    ok "P6b: none でも削除 script は develop を消さない"
  else
    bad "P6b: none の削除 script が develop を守らない（rc=${p_rc} out=${p_out} after=${p_after}）"
    g --git-dir="$TMP/origin.git" update-ref refs/heads/develop "$p_develop"
  fi
  PR_HEAD_REF='release/1.0'
  write_pr_json "Closes #${PRN}" '[]'
  FF_MERGE_CLEANUP_PROTECT_BRANCHES=none run_finish "$WORK" precheck 7
  p_cmd="$(printf '%s\n' "$OUT" | awk '/^MERGE_COMMAND_BEGIN$/ { c=1; next } /^MERGE_COMMAND_END$/ { c=0 } c')"
  if [ "$RC" -eq 0 ] && has_text "$p_cmd" "--delete-branch" && ! has_line "$OUT" "HEAD_DELETE=skipped-protected"; then
    ok "P6c: none のとき release/1.0 の生成は削除を含む"
  else
    bad "P6c: none でも release/1.0 を保護している（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  p_rc=0
  p_out="$(FF_MERGE_CLEANUP_PROTECT_BRANCHES=none bash "$PLUGIN_ROOT/scripts/lib/finish-delete-merged-head.sh" "$WORK" release/1.0 "$p_develop" 2>"$p_err")" || p_rc=$?
  p_after="$(g --git-dir="$TMP/origin.git" rev-parse --verify refs/heads/release/1.0 2>/dev/null || true)"
  if [ "$p_rc" -eq 0 ] && [ "$p_out" = "HEAD_DELETE_RESULT=deleted" ] && [ -z "$p_after" ]; then
    ok "P6d: none のとき削除 script は release/1.0 を lease 削除する"
  else
    bad "P6d: none の release/1.0 が消えない（rc=${p_rc} out=${p_out} after=${p_after}）: $(cat "$p_err")"
  fi

  PR_HEAD_REF=develop
  write_pr_json "Closes #${PRN}" '[]'
  FF_MERGE_CLEANUP_PROTECT_BRANCHES='release/*:' run_finish "$WORK" precheck 7
  if [ "$RC" -eq 2 ] && ! has_text "$OUT" "MERGE_COMMAND_BEGIN" && has_text "$ERR" "空のパターンがあります"; then
    ok "P7: 空の保護パターンは rc 2 で merge コマンドを出さない"
  else
    bad "P7: 空パターンが fail-open（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  p_rc=0
  p_out="$(FF_MERGE_CLEANUP_PROTECT_BRANCHES='release/*:' bash "$PLUGIN_ROOT/scripts/lib/finish-delete-merged-head.sh" "$WORK" develop "$p_develop" 2>"$p_err")" || p_rc=$?
  p_after="$(g --git-dir="$TMP/origin.git" rev-parse --verify refs/heads/develop 2>/dev/null || true)"
  if [ "$p_rc" -eq 2 ] && ! has_text "$p_out" "skipped-protected" && [ "$p_after" = "$p_develop" ] \
    && has_text "$(cat "$p_err")" "空のパターンがあります"; then
    ok "P7b: 空パターンの削除 script は rc 2 で ref を残し skipped-protected にしない"
  else
    bad "P7b: 空パターンの削除 script が違う（rc=${p_rc} out=${p_out} after=${p_after}）: $(cat "$p_err")"
    g --git-dir="$TMP/origin.git" update-ref refs/heads/develop "$p_develop"
  fi
  FF_MERGE_CLEANUP_PROTECT_BRANCHES='release/[[:digit:]]*' run_finish "$WORK" precheck 7
  if [ "$RC" -eq 2 ] && ! has_text "$OUT" "MERGE_COMMAND_BEGIN" && has_text "$ERR" "文字クラス"; then
    ok "P7c: 文字クラスの保護パターンは rc 2 で merge コマンドを出さない"
  else
    bad "P7c: 文字クラスが fail-open（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  p_rc=0
  p_out="$(FF_MERGE_CLEANUP_PROTECT_BRANCHES='release/[[:digit:]]*' bash "$PLUGIN_ROOT/scripts/lib/finish-delete-merged-head.sh" "$WORK" feature/deletable "$p_develop" 2>"$p_err")" || p_rc=$?
  p_after="$(g --git-dir="$TMP/origin.git" rev-parse --verify refs/heads/feature/deletable 2>/dev/null || true)"
  if [ "$p_rc" -eq 2 ] && [ "$p_after" = "$p_develop" ] && has_text "$(cat "$p_err")" "文字クラス"; then
    ok "P7d: 文字クラスの削除 script は rc 2 で feature ブランチも消さない"
  else
    bad "P7d: 文字クラスの削除 script が違う（rc=${p_rc} out=${p_out} after=${p_after}）: $(cat "$p_err")"
  fi
  # 前後の空白は一致しないパターンになり、release/* の保護が黙って外れる（fail-open）。rc 2 で拒否する
  FF_MERGE_CLEANUP_PROTECT_BRANCHES=' release/*' run_finish "$WORK" precheck 7
  if [ "$RC" -eq 2 ] && ! has_text "$OUT" "MERGE_COMMAND_BEGIN" && has_text "$ERR" "前後の空白"; then
    ok "P7e: 前後に空白のある保護パターンは rc 2 で merge コマンドを出さない"
  else
    bad "P7e: 前後の空白が fail-open（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  p_rc=0
  p_out="$(FF_MERGE_CLEANUP_PROTECT_BRANCHES='release/* ' bash "$PLUGIN_ROOT/scripts/lib/finish-delete-merged-head.sh" "$WORK" feature/deletable "$p_develop" 2>"$p_err")" || p_rc=$?
  p_after="$(g --git-dir="$TMP/origin.git" rev-parse --verify refs/heads/feature/deletable 2>/dev/null || true)"
  if [ "$p_rc" -eq 2 ] && [ "$p_after" = "$p_develop" ] && ! has_text "$p_out" "HEAD_DELETE_RESULT=" \
    && has_text "$(cat "$p_err")" "前後の空白"; then
    ok "P7f: 前後に空白のある保護パターンの削除 script は rc 2 で feature ブランチも消さない"
  else
    bad "P7f: 空白付きパターンの削除 script が違う（rc=${p_rc} out=${p_out} after=${p_after}）: $(cat "$p_err")"
    g --git-dir="$TMP/origin.git" update-ref refs/heads/feature/deletable "$p_develop"
  fi

  PR_HEAD_REF='feature/deletable'
  PR_BASE_REF=develop
  write_pr_json "Closes #${PRN}" '[]'
  run_finish "$WORK" precheck 7
  p_cmd="$(printf '%s\n' "$OUT" | awk '/^MERGE_COMMAND_BEGIN$/ { c=1; next } /^MERGE_COMMAND_END$/ { c=0 } c')"
  if [ "$RC" -eq 0 ] && has_text "$p_cmd" "--delete-branch" && ! has_line "$OUT" "HEAD_DELETE=skipped-protected"; then
    ok "P8: feature ブランチの生成は --delete-branch を残す"
  else
    bad "P8: feature ブランチの生成が保護されている（rc=${RC}）: ${OUT} / ${ERR}"
  fi
  p_rc=0
  p_out="$(bash "$PLUGIN_ROOT/scripts/lib/finish-delete-merged-head.sh" "$WORK" feature/deletable "$p_develop" 2>"$p_err")" || p_rc=$?
  p_after="$(g --git-dir="$TMP/origin.git" rev-parse --verify refs/heads/feature/deletable 2>/dev/null || true)"
  if [ "$p_rc" -eq 0 ] && [ "$p_out" = "HEAD_DELETE_RESULT=deleted" ] && [ -z "$p_after" ]; then
    ok "P8b: feature ブランチは削除 script が lease 削除する"
  else
    bad "P8b: feature ブランチが消えない（rc=${p_rc} out=${p_out} after=${p_after}）: $(cat "$p_err")"
  fi

  if grep -qF 'develop|main|master|staging/*' "$PLUGIN_ROOT/scripts/merge-cleanup.sh" \
    && grep -qF 'develop|main|master|staging/*' "$PLUGIN_ROOT/scripts/lib/finish-delete-merged-head.sh" \
    && grep -qF "('release/*')" "$PLUGIN_ROOT/scripts/lib/merge-cleanup-pre.sh" \
    && grep -qF "('release/*')" "$PLUGIN_ROOT/scripts/lib/finish-delete-merged-head.sh"; then
    ok "P9: ハードコード保護と既定の release/* が merge-cleanup と同じ文字列である"
  else
    bad "P9: 保護パターンの文字列が merge-cleanup とずれている"
  fi

  # write_pr_json が同じシェルの値を読む。参照を残し、未使用代入に見せない。
  : "${PR_HEAD_REF-}${PR_BASE_REF-}${PR_CROSS-}"
  _ff_protect_restore
  unset -f _ff_protect_restore
}
