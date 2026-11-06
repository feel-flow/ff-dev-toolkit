# shellcheck shell=bash
# Sourced by release-runtime.sh after the stage fixtures finish.
release_issue_cases() {
  echo "-- release: private Issue handoff and fixed HEAD --"
  local issue_db="$STATE/release-issues.json" approved version before pub_before saved first second private_repo dry_plan forged pinned other
  cp "$REPO_ROOT/scripts/lib/release-issue-functions.sh" "$SSOT/scripts/lib/"
  mv "$STUB_BIN/gh" "$STUB_BIN/gh-legacy"
  cp "$SCRIPT_DIR/fixtures/release-issue-gh.py" "$STUB_BIN/gh.py"
  write_stub "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
exec "$RELEASE_RT_REAL_PYTHON" "$0.py" "$@"
STUB
  # The actual clone transports remain local; only URL identification is stubbed.
  export RELEASE_RT_GIT RELEASE_RT_REAL_PYTHON
  RELEASE_RT_GIT="$(command -v git)"
  write_stub "$STUB_BIN/git" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "config --local --get-all remote.origin.url"|"remote get-url --push --all origin")
    printf '%s/%s/%s%s\n' 'https://github.com' 'feel-flow' 'feelflow-' 'plugins.git' ;;
  *) exec "$RELEASE_RT_GIT" "$@" ;;
esac
STUB
  printf '%s\n' '- 受付中のリリース' >"$SSOT/changelog.d/2649.fixed.release-issue.md"
  commit_push "fix: release handoff fixture"
  iso_ago 3600 >"$STATE/published_at"
  run_orch --update-release-issue --dry-run
  if [[ "$RC" -eq 0 && ! -e "$issue_db" ]] && has "PLAN: release Issue を作成"; then
    ok "受付 dry-run は作成予定だけを出す"
  else bad "受付 dry-run が書き込んだ、または作成予定が無い (rc=$RC)"; dump; fi
  dry_plan="$OUT"
  private_repo="$(printf '%s%s' 'feel-flow/feelflow-' 'plugins')"
  jq -n --arg repo "$private_repo" '{full_name:$repo,private:true,visibility:"private"}' >"$STATE/issue-repo.json"
  printf '[]\n' >"$STATE/issue-list.json"
  jq -n --arg published "$(cat "$STATE/published_at")" '{published_at:$published}' >"$STATE/issue-due.json"
  jq -n --arg path "$STATE" --arg repo "https://github.com/$private_repo" '
    {version:1,responses:[
      {operation:"release.issue-repo",scope:{repository:$repo},phase:"queue",body:($path+"/issue-repo.json")},
      {operation:"release.issue-list",scope:{repository:$repo},phase:"queue",body:($path+"/issue-list.json"),last:true},
      {operation:"release.latest-due",scope:{repository:"https://github.com/feel-flow/ff-dev-toolkit"},phase:"due",body:($path+"/issue-due.json")}
    ]}' >"$STATE/issue-index.json"
  : >"$STATE/issue-denied"
  run_orch --update-release-issue --dry-run --github-input "$STATE/issue-index.json"
  rm "$STATE/issue-denied"
  if [[ "$RC" -eq 0 && "$OUT" == "$dry_plan" && ! -e "$issue_db" ]]; then
    ok "raw-file と gh は受付 dry-run の判定・出力が同じ"
  else bad "raw-file と gh の受付 dry-run の判定が違う"; dump; fi
  git clone -q -b develop "$SSOT_ORIGIN" "$TMP/other-releaser"
  release_case_init_clone "$TMP/other-releaser"
  : >"$STATE/issue-race"
  bash "$SSOT/scripts/release-dev-toolkit.sh" --update-release-issue >"$STATE/first-issue.log" 2>&1 &
  first=$!
  bash "$TMP/other-releaser/scripts/release-dev-toolkit.sh" --update-release-issue >"$STATE/second-issue.log" 2>&1 &
  second=$!
  wait "$first" || true
  wait "$second" || true
  rm "$STATE/issue-race"
  OUT="$(cat "$STATE/first-issue.log" "$STATE/second-issue.log")"
  if has "RELEASE_ISSUE_URL=" && jq -e 'length == 1 and .[0].comments == []' "$issue_db" >/dev/null; then
    ok "別 clone から同時に更新しても受付中 Issue は 1 件"
  else bad "同時更新で受付中 Issue が 1 件にならない"; dump; return; fi

  git -C "$SSOT" commit -qm "docs: latest neutral commit" --allow-empty
  git -C "$SSOT" push -q origin develop
  run_orch --update-release-issue
  approved="$(git -C "$SSOT" rev-parse HEAD)"
  if [[ "$RC" -eq 0 ]] && jq -e --arg sha "$approved" 'length == 1 and .[0].comments == [] and (.[0].body | contains($sha))' "$issue_db" >/dev/null; then
    ok "既存の受付中 Issue を同じ番号・コメントなしで更新"
  else bad "既存の受付中 Issue を更新できない"; dump; fi

  saved="$(cat "$issue_db")"
  jq '. + [.[0] | .number = 2]' <<<"$saved" >"$issue_db"
  run_orch --update-release-issue
  if [[ "$RC" -eq 1 ]] && has "$(printf '#%s, #%s' 1 2)"; then ok "受付中の重複は全番号を示して停止"; else bad "重複した受付を更新した"; dump; fi
  printf '%s\n' "$saved" >"$issue_db"

  version="$(jq -r .version "$SSOT/plugins/ff-dev-toolkit/.claude-plugin/plugin.json" | awk -F. '{ print $1 "." $2 "." ($3 + 1) }')"
  before="$(count_runall)"
  pub_before="$(git -C "$PUB_ORIGIN" rev-parse main)"
  other="$TMP/other-releaser"
  git -C "$other" pull -q --ff-only origin develop
  printf '%s\n' 'outside approval' >"$other/plugins/ff-dev-toolkit/scripts/unapproved.txt"
  jq --arg version "$version" '.version = $version' "$other/plugins/ff-dev-toolkit/.claude-plugin/plugin.json" >"$STATE/forged-version.json"
  cp "$STATE/forged-version.json" "$other/plugins/ff-dev-toolkit/.claude-plugin/plugin.json"
  awk -v v="$version" '/^## \[Unreleased\]$/ {print; print ""; print "## [" v "] - 2026-11-06"; print ""; print "### 修正"; print ""; print "- Unapproved payload."; next} {print}' \
    "$other/oss/ff-dev-toolkit/CHANGELOG.md" >"$STATE/forged-changelog.md"
  cp "$STATE/forged-changelog.md" "$other/oss/ff-dev-toolkit/CHANGELOG.md"
  git -C "$other" add -A
  git -C "$other" commit -qm "release: ff-dev-toolkit v$version" -m "Release-Issue: $(printf '#%s' 1)"
  forged="$(git -C "$other" rev-parse HEAD)"
  git -C "$other" push -q origin develop
  run_orch --executor first --expect-version "$version" --approved-head "$approved"
  if [[ "$RC" -eq 1 && "$(git -C "$SSOT" rev-parse HEAD)" == "$approved" ]] && has "ADVANCE=public" && ! has "RELEASE_STAGE=gate"; then
    ok "件名と Issue 番号を似せた未承認コミットは checkout と検査より前に停止"
  else bad "件名と Issue 番号だけで未承認コミットを受け入れた"; dump; fi
  git -C "$SSOT_ORIGIN" update-ref refs/heads/develop "$approved" "$forged"
  : >"$STATE/issue-denied"
  run_orch --executor first --expect-version "$version" --approved-head "$approved"
  rm "$STATE/issue-denied"
  if [[ "$RC" -eq 2 ]] && has "RELEASE_RESULT=unavailable" && ! has "RELEASE_STAGE=prepare"; then
    ok "private リポジトリを確認できない実行は prepare 前に停止"
  else bad "private リポジトリを確認せずに進んだ"; dump; fi

  : >"$STATE/issue-readback-mismatch"
  run_orch --executor first --expect-version "$version" --approved-head "$approved"
  rm "$STATE/issue-readback-mismatch"
  if [[ "$RC" -eq 1 ]] && has "読み戻し" && ! has "RELEASE_STAGE=prepare"; then
    ok "担当 token の読み戻し不一致は prepare 前に停止"
  else bad "担当 token の読み戻し不一致で停止しない"; dump; fi
  run_orch --executor second --expect-version "$version" --approved-head "$approved"
  if [[ "$RC" -eq 1 ]] && has "first が走行中" && ! has "RELEASE_STAGE=prepare"; then
    ok "別 token の担当が走行中なら prepare 前に停止"
  else bad "走行中の担当を上書きした"; dump; fi
  [[ "$(count_runall)" == "$before" && "$(git -C "$PUB_ORIGIN" rev-parse main)" == "$pub_before" ]] || bad "担当を取得できない回が公開へ進んだ"
  # Expire the simulated abandoned owner without wall-clock sleeps.
  saved="$(jq -c '.[0].body |= sub("\"started\":[0-9]+"; "\"started\":1")' "$issue_db")"
  printf '%s\n' "$saved" >"$issue_db"
  : >"$STATE/public-layout.red"
  run_orch --executor second --take-over --expect-version "$version" --approved-head "$approved"
  rm "$STATE/public-layout.red"
  if [[ "$RC" -eq 1 ]] && has "RELEASE_FIXED_HEAD=" && has "RELEASE_RESULT=stopped" &&
    jq -e '.[0] | (.state == "open") and (.body | contains("\"owner\":null")) and (.comments | any(contains("stopped (gate)")))' "$issue_db" >/dev/null; then
    ok "固定後の停止は担当欄を空にし、走行中 Issue に停止段と再開方法を記録"
  else bad "固定後の停止を再開できる形で記録できない"; dump; fi
  pinned="$(git -C "$SSOT_ORIGIN" rev-parse develop)"
  git -C "$other" fetch -q origin develop
  git -C "$other" checkout -q --detach "$pinned"
  cp -R "$SSOT/plugins/ff-media-toolkit/node_modules" "$other/plugins/ff-media-toolkit/"
  saved="$(cat "$issue_db")"
  RC=0
  OUT="$(RELEASE_RT_MEDIA="$(cd "$other/plugins/ff-media-toolkit" && pwd -P)" \
    bash "$other/scripts/release-dev-toolkit.sh" --public "$PUB" --dry-run 2>&1)" || RC=$?
  if [[ "$RC" -eq 0 && "$(release_head)" == "$pinned" && "$(cat "$issue_db")" == "$saved" ]] && has "RELEASE_RESULT=dry-run"; then
    ok "別 clone で固定 SHA の dry-run ができる"
  else bad "別 clone で固定 SHA の承認を取り直せない"; dump; fi
  printf '%s\n' pinned >"$STATE/runall.advance"
  run_orch --public ../public --executor second --expect-version "$version" --approved-head "$approved"
  if [[ "$RC" -eq 0 ]] && has "RELEASE_RESULT=released" &&
    [[ "$(count_runall)" -eq "$((before + 2))" ]] &&
    git -C "$SSOT_ORIGIN" cat-file -e develop:plugins/ff-dev-toolkit/scripts/next-release.txt &&
    ! git -C "$PUB_ORIGIN" cat-file -e main:plugins/ff-dev-toolkit/scripts/next-release.txt 2>/dev/null &&
    jq -e 'length == 2 and .[0].state == "closed" and .[1].state == "open" and (.[0].comments | any(contains("から引き継ぎ"))) and (.[0].comments | any(contains("released:")))' "$issue_db" >/dev/null; then
    ok "別 clone の前進は次の Issue へ回し、固定した版だけ公開して走行中 Issue を閉じる"
  else bad "固定リリースの公開・比較リンク・次の受付の分離に失敗 (rc=$RC)"; dump; fi

  if [[ -n "$HOOK" && -f "$HOOK" ]]; then
    mkdir -p "$SSOT/.claude/hooks"
    cp "$HOOK" "$SSOT/.claude/hooks/post-merge-dev-toolkit-sync.sh"
    cp "$REPO_ROOT/.claude/hooks/session-start-sync-drift.sh" "$SSOT/.claude/hooks/"
    printf '%s\n' plugins/ff-dev-toolkit/skills/demo/SKILL.md changelog.d/2649.fixed.release-issue.md >"$STATE/pr-files"
    OUT="$(printf '%s' '{"tool_input":{"command":"gh pr merge 77 --squash"}}' | bash "$SSOT/.claude/hooks/post-merge-dev-toolkit-sync.sh" 2>&1)"
    if has "issues/2 RELEASE_DUE=" && ! has "しますか"; then ok "PostToolUse は受付 URL と時期だけ通知"; else bad "PostToolUse の受付通知"; dump; fi
    : >"$STATE/drift.stale"
    OUT="$(bash "$SSOT/.claude/hooks/session-start-sync-drift.sh" </dev/null 2>&1)"
    rm "$STATE/drift.stale"
    if has "最新の未同期件数を確かめられない" && ! has "しますか"; then ok "SessionStart の受付失敗は理由だけ通知"; else bad "SessionStart の失敗通知"; dump; fi
  fi
}
