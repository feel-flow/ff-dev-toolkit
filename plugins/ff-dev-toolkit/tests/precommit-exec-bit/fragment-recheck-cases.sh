# shellcheck shell=bash
# pipefail-inherited: verify.shがset -euo pipefailでsourceするfixtureケース。
# shellcheck disable=SC2034,SC2154
run_fragment_recheck_cases() {
  local repo frag second other marker phase rc output probe base expected
  marker='WARN changelog-fragment:'
  frag='changelog.d/2115.fixed.first.md'
  second='changelog.d/2115.fixed.second.md'
  other='changelog.d/1.fixed.other.md'
  repo="$(new_pub_repo recheck)"
  stage_file "$repo" "$other"
  git -C "$repo" commit -q -m other-fragment
  git -C "$repo" update-ref refs/remotes/origin/develop HEAD
  printf '%s\n' '- index-original' >"$repo/$frag"
  git -C "$repo" add "$frag"
  stage_file "$repo" "$PUB_PATH"
  run_frag "$repo"
  if [ "$RC" -eq 0 ] && [ "$OUT" = 'changelog-fragment: ok 1' ] && ! has_text "$ERR" "$marker"; then
    ok "W1. 初回commitの断片stageはWARNなし"
  else bad "W1. 初回の判定が違います（rc=${RC} / err=${ERR}）"; fi
  git -C "$repo" commit -q -m first
  stage_file "$repo" "$PUB_PATH"
  run_frag "$repo"
  if [ "$RC" -eq 0 ] && [ "$OUT" = 'changelog-fragment: ok 1' ] && has_text "$ERR" "$marker" \
    && has_text "$ERR" "$frag" && has_text "$ERR" '- index-original' && has_text "$ERR" '読み直してください'; then
    ok "W2. 後続公開変更はpath/index本文/読み直しWARN、stdoutとrc0を維持"
  else bad "W2. 後続WARNが違います（rc=${RC} / err=${ERR}）"; fi
  printf '%s\n' '- worktree-only' >"$repo/$frag"
  run_frag "$repo"
  if [ "$RC" -eq 0 ] && has_text "$ERR" "$marker" && has_text "$ERR" '- index-original' && ! has_text "$ERR" '- worktree-only'; then
    ok "W3. 未stageの本文で確認済みにせずindex本文を表示"
  else bad "W3. 本文の読取元が違います（rc=${RC} / err=${ERR}）"; fi
  git -C "$repo" add "$frag"
  run_frag "$repo"
  if [ "$RC" -eq 0 ] && ! has_text "$ERR" "$marker"; then ok "W4. 同じ後続commitで断片もstageすればWARNなし";
  else bad "W4. staged断片の抑止が違います"; fi
  git -C "$repo" reset -q HEAD -- "$frag"
  stage_file "$repo" "$other"
  stage_file "$repo" changelog.d/README.md
  run_frag "$repo"
  if [ "$RC" -eq 0 ] && has_text "$ERR" "$marker" && ! has_text "$ERR" "断片: $other"; then
    ok "W5. 他PRの断片/READMEのstageではWARNを抑止しない"
  else bad "W5. 対象外断片でWARNを抑止した"; fi
  git -C "$repo" restore --worktree -- "$frag"
  printf '%s\n' '- second-index' >"$repo/$second"
  git -C "$repo" add "$second"
  git -C "$repo" commit -q -m second-fragment
  stage_file "$repo" "$PUB_PATH"
  run_frag "$repo"
  if [ "$RC" -eq 0 ] && [ "$OUT" = 'changelog-fragment: ok 2' ] \
    && has_text "$ERR" "断片: $frag (index)" && has_text "$ERR" '- index-original' \
    && has_text "$ERR" "断片: $second (index)" && has_text "$ERR" '- second-index'; then
    ok "W6. 複数断片の全pathとindex本文を対応させて表示"
  else bad "W6. 複数断片の表示が違います（rc=${RC} / err=${ERR}）"; fi
  stage_file "$repo" "$frag"
  run_frag "$repo"
  if [ "$RC" -eq 0 ] && ! has_text "$ERR" "$marker"; then ok "W7. 複数でも共通断片1件以上のstageでWARNなし";
  else bad "W7. 複数断片の抑止が違います"; fi

  repo="$(new_pub_repo recheck-errors)"
  printf '%s\n' '- error-index' >"$repo/$frag"
  git -C "$repo" add "$frag"
  git -C "$repo" commit -q -m first
  stage_file "$repo" docs/private.md
  run_frag "$repo"
  if [ "$RC" -eq 0 ] && [ "$OUT" = 'changelog-fragment: none' ] && ! has_text "$ERR" "$marker"; then ok "W8. 後続でも非公開変更だけならnone/WARNなし";
  else bad "W8. 非公開変更をWARNした"; fi
  stage_file "$repo" "$PUB_PATH"
  mkdir -p "$TMP/recheck-git"
  cp "$SCRIPT_DIR/fragment-recheck-git.fixture" "$TMP/recheck-git/git"
  chmod 755 "$TMP/recheck-git/git"
  for phase in staged partial empty; do
    case "$phase" in
      staged) expected='読み直し判定のstaged一覧を取得できません' ;;
      partial) expected='読み直し判定の一覧がNULで終端していません' ;;
      empty) expected='読み直し判定の一覧に空のパスがあります' ;;
    esac
    rc=0
    output="$(PATH="$TMP/recheck-git:$PATH" RECHECK_PHASE="$phase" RECHECK_REAL_GIT="$REAL_GIT" changelog_fragment_scan "$repo" 2>"$TMP/recheck-err")" || rc=$?
    if [ "$rc" -eq 2 ] && [ -z "$output" ] && has_text "$(cat "$TMP/recheck-err")" "$expected" \
      && ! has_text "$(cat "$TMP/recheck-err")" "$marker"; then ok "W9-${phase}. 読み直し一覧の失敗経路を固有診断で確認";
    else bad "W9-${phase}. 取得不能を正常なWARNで隠した（rc=${rc}）"; fi
  done
  probe="$TMP/recheck-collection"
  mkdir -p "$probe"
  base="$(git -C "$repo" rev-parse HEAD)"
  for phase in missing empty partial empty-name directory; do
    case "$phase" in
      missing|empty|directory) expected='読み直す断片集合が無いか空、または読めません' ;;
      partial) expected='読み直す断片集合がNULで終端していません' ;;
      empty-name) expected='読み直す断片名が空です' ;;
    esac
    rm -f "$probe/frags-z"
    case "$phase" in empty) : >"$probe/frags-z" ;; partial) printf '%s' "$frag" >"$probe/frags-z" ;; empty-name) printf '\0' >"$probe/frags-z" ;; directory) mkdir "$probe/frags-z" ;; esac
    rc=0
    output="$(_changelog_fragment_recheck "$repo" "$probe" "$base" 2>"$TMP/recheck-err")" || rc=$?
    if [ "$rc" -eq 2 ] && [ -z "$output" ] && has_text "$(cat "$TMP/recheck-err")" "$expected"; then ok "W10-${phase}. 確定集合の不在/空/不正を固有診断で確認";
    else bad "W10-${phase}. 不正な確定集合を受理した（rc=${rc}）"; fi
  done
  rmdir "$probe/frags-z"
  printf '%s\0' "$frag" >"$probe/frags-z"
  for phase in missing directory; do
    if [ "$phase" = directory ]; then mkdir "$probe/body.1"; fi
    rc=0
    output="$(_changelog_fragment_recheck "$repo" "$probe" "$base" 2>"$TMP/recheck-err")" || rc=$?
    if [ "$rc" -eq 2 ] && [ -z "$output" ] \
      && has_text "$(cat "$TMP/recheck-err")" '読み直す断片の保存済みindex本文を読めません' \
      && ! has_text "$(cat "$TMP/recheck-err")" "$marker"; then ok "W11-${phase}. 保存済み本文の欠落はrc2でWARNなし";
    else bad "W11-${phase}. 保存済み本文の不在を正常なWARNで隠した（rc=${rc}）"; fi
  done
  rmdir "$probe/body.1"
  FRAGMENT_RECHECK_CASES_REACHED=1
}
