# shellcheck shell=bash
# pipefail-inherited: verify.sh が set -euo pipefail の下で source する
# 項目 43・44: エージェント worktree と switch なし掃除モード
#
# verify.sh から source される（ok / bad / TMP / TARGET / MOCK / PLUGIN_ROOT / SCRIPT_DIR を共有）。
# 読む順序は verify.sh の一覧が正本で、前の cases の fixture と関数を後ろの cases が使う（Issue `#2697`）。

# ---- 43. (Issue 914) マージ済みエージェント worktree の自動処理 ------------------
#
# 「(名前, OID) が MERGED PR の head と一致 かつ ロック理由が claude agent かつ
# untracked が .review-results のみ」の狭い条件で unlock + 削除する設計を固定する。
# 条件を 1 つずつ欠いた fixture（`#53`: 未知の untracked / `#54`: OID 照合不成立 /
# `#55`: 非 claude ロック）が従来どおり保護されることも同じ run で見る。

echo ""
echo "== (Issue 914) マージ済みエージェント worktree =="

setup_agent_worktree() {
  # $1: branch / $2: OID / $3: worktree path / $4: lock reason（空ならロックしない）
  git branch -q "$1" "$2"
  SKIP_SIMPLE_GIT_HOOKS=1 git push -qu origin "$1"
  git worktree add -q "$3" "$1"
  mkdir -p "$3/.review-results"
  echo review > "$3/.review-results/code-review.md"
  if [ -n "$4" ]; then
    git worktree lock --reason "$4" "$3"
  fi
  SKIP_SIMPLE_GIT_HOOKS=1 git push -q origin --delete "$1"
}

setup_agent_worktree 'feature/#52-agent-lock' "$OID_AGENT52" "$TMP/wt-52" 'claude agent worktree'
setup_agent_worktree 'feature/#53-agent-unknown' "$OID_AGENT53" "$TMP/wt-53" 'claude agent worktree'
setup_agent_worktree 'feature/#54-agent-nomatch' "$OID_AGENT54" "$TMP/wt-54" 'claude agent worktree'
setup_agent_worktree 'feature/#55-agent-foreign-lock' "$OID_AGENT55" "$TMP/wt-55" 'manual hold'
setup_agent_worktree 'feature/#56-agent-nolock' "$OID_AGENT56" "$TMP/wt-56" ''
setup_agent_worktree 'feature/#59-agent-toctou' "$OID_AGENT59" "$TMP/wt-59" 'claude agent worktree'
echo scratch > "$TMP/wt-53/notes.txt"

set +e
PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-914.log" 2>&1
EXIT_914=$?
set -e

# 43.1 全条件を満たす worktree は unlock + 削除され、失敗（PARTIAL の原因）として
#      数えられない。補足行（手当て不要）に経緯が残る。
if [ ! -d "$TMP/wt-52" ] \
  && ! git show-ref -q "refs/heads/feature/#52-agent-lock" \
  && grep -q "claude agent ロックを解除しました" "$TMP/run-914.log" \
  && grep -q "使い捨てパス（.review-results）を除去してから worktree を削除します" "$TMP/run-914.log" \
  && grep -q "feature/#52-agent-lock: マージ済みエージェント worktree を自動処理" "$TMP/run-914.log" \
  && ! grep -qE '^  - feature/#52-agent-lock: (worktree|git branch|\[gone\])' "$TMP/run-914.log"; then
  ok "条件を満たすエージェント worktree は unlock + 削除され、PARTIAL に数えない"
else
  bad "エージェント worktree の自動処理が期待どおりでない (exit=$EXIT_914)"
fi

# 43.2 未知の untracked が混ざっていれば、claude ロック + OID 一致でも保護する
if [ -f "$TMP/wt-53/notes.txt" ] \
  && git show-ref -q "refs/heads/feature/#53-agent-unknown" \
  && grep -q "feature/#53-agent-unknown: worktree に未コミット変更あり" "$TMP/run-914.log"; then
  ok "未知の untracked を持つ worktree は従来どおり保護する"
else
  bad "未知の untracked の保護が期待どおりでない"
fi

# 43.3 (名前, OID) が MERGED 一覧と一致しなければ、残置物が .review-results だけでも保護する
if [ -d "$TMP/wt-54" ] \
  && git show-ref -q "refs/heads/feature/#54-agent-nomatch" \
  && grep -q "feature/#54-agent-nomatch: worktree に未コミット変更あり" "$TMP/run-914.log"; then
  ok "MERGED OID 照合が成立しない worktree は保護する"
else
  bad "OID 照合不成立時の保護が期待どおりでない"
fi

# 43.4 ロック理由が claude agent でなければ unlock しない（他者のロックを尊重）
if [ -d "$TMP/wt-55" ] \
  && [ -f "$TMP/wt-55/.review-results/code-review.md" ] \
  && git show-ref -q "refs/heads/feature/#55-agent-foreign-lock" \
  && grep -q "worktree がロックされています（理由: manual hold）" "$TMP/run-914.log" \
  && grep -q "feature/#55-agent-foreign-lock: worktree がロックされており自動 unlock の条件外" "$TMP/run-914.log"; then
  ok "claude agent 以外のロックは unlock せず保護する"
else
  bad "非 claude ロックの保護が期待どおりでない"
fi

# 43.5 ロックが無い worktree は、MERGED OID 一致 + .review-results のみでも自動処理
#      しない（Issue 914 の条件は 3 つの全充足。ロックはエージェント所有の証拠）
if [ -d "$TMP/wt-56" ] \
  && [ -f "$TMP/wt-56/.review-results/code-review.md" ] \
  && git show-ref -q "refs/heads/feature/#56-agent-nolock" \
  && grep -q "feature/#56-agent-nolock: worktree に未コミット変更あり" "$TMP/run-914.log" \
  && ! grep -qE 'feature/#56-agent-nolock: マージ済みエージェント worktree を自動処理' "$TMP/run-914.log"; then
  ok "未ロックの worktree は使い捨てパスのみ + OID 一致でも自動削除しない"
else
  bad "未ロック worktree の保護が期待どおりでない"
fi

# 43.6 使い捨てパス除去の直後に別の変更が入った場合（TOCTOU）、force なしの
#      `git worktree remove` が git 自身の判定で拒否し、新ファイルは残る。
#      解除していた claude agent ロックは元の理由で復元される（fail-closed へ復帰）。
if [ -f "$TMP/mock-rm-toctou-fired" ] \
  && [ -d "$TMP/wt-59" ] \
  && [ -f "$TMP/wt-59/landed-later.txt" ] \
  && git show-ref -q "refs/heads/feature/#59-agent-toctou" \
  && grep -q "feature/#59-agent-toctou: worktree 削除失敗" "$TMP/run-914.log" \
  && grep -q "解除していた claude agent ロックを元の理由で復元しました" "$TMP/run-914.log"; then
  ok "除去後に入った変更は force なし削除が拒否して保護し、ロックを復元する"
else
  bad "TOCTOU 保護（force なし削除 + ロック復元）が期待どおりでない"
fi

# 43.6b 復元されたロックが実際に元の理由で残っていることを porcelain で実測する
WT59_LOCK_LINE="$(git worktree list --porcelain | grep -A3 "worktree .*wt-59\$" | grep '^locked' || true)"
case "$WT59_LOCK_LINE" in
  *"claude agent worktree"*)
    ok "復元されたロックが元の理由（claude agent worktree）を保持している"
    ;;
  *)
    bad "ロックの復元内容が期待どおりでない (lock=$WT59_LOCK_LINE)"
    ;;
esac

# 43.7 静的検査: `git worktree remove --force` を入口と構成ファイルに持たない（TOCTOU の穴の再混入防止）
MC_FORCE_HITS=0
for _mc_force in "$TARGET" "${MC_PARTS[@]}"; do
  if grep -qE 'git worktree remove --force' "$_mc_force"; then
    MC_FORCE_HITS=1
  fi
done
if [ "$MC_FORCE_HITS" -eq 0 ]; then
  ok "merge-cleanup.sh は git worktree remove --force を使わない（静的検査）"
else
  bad "merge-cleanup.sh に git worktree remove --force が再混入している"
fi

# 後続セクションへ [gone] + FAILED のノイズを持ち越さないよう、保護された fixture を片付ける
git worktree unlock "$TMP/wt-53" 2>/dev/null || true
git worktree unlock "$TMP/wt-54" 2>/dev/null || true
git worktree unlock "$TMP/wt-55" 2>/dev/null || true
git worktree unlock "$TMP/wt-59" 2>/dev/null || true
git worktree remove --force "$TMP/wt-53" 2>/dev/null || true
git worktree remove --force "$TMP/wt-54" 2>/dev/null || true
git worktree remove --force "$TMP/wt-55" 2>/dev/null || true
git worktree remove --force "$TMP/wt-56" 2>/dev/null || true
git worktree remove --force "$TMP/wt-59" 2>/dev/null || true
git branch -q -D 'feature/#53-agent-unknown' 'feature/#54-agent-nomatch' \
  'feature/#55-agent-foreign-lock' 'feature/#56-agent-nolock' \
  'feature/#59-agent-toctou' 2>/dev/null || true

# ---- 44. (Issue 758 / 749) 呼び出し元が base でも PR head でもないブランチ --------
#
# 他セッションの作業ブランチを保持したまま実行しても、そのブランチを switch せずに
# 掃除を完遂する。base を保持する worktree は detach も削除もせず報告だけする。

echo ""
echo "== (Issue 758 / 749) switch なし掃除モード =="

# 44.1 clean な占有ブランチ: switch せず完遂し、base 保持 worktree を報告する
git -C "$CALLER" switch -q -c other-session-work develop
git -C "$BASE_OWNER" switch -q develop
git branch -q 'feature/#57-gone-noswitch' develop
SKIP_SIMPLE_GIT_HOOKS=1 git push -qu origin 'feature/#57-gone-noswitch'
SKIP_SIMPLE_GIT_HOOKS=1 git push -q origin --delete 'feature/#57-gone-noswitch'
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-noswitch.log" 2>&1
EXIT_NOSWITCH=$?
set -e
if [ "$EXIT_NOSWITCH" -eq 2 ] \
  && [ "$(git -C "$CALLER" branch --show-current)" = "other-session-work" ] \
  && [ "$(git -C "$BASE_OWNER" branch --show-current)" = "develop" ] \
  && grep -q "呼び出し元は 'other-session-work' を保持しています" "$TMP/run-noswitch.log" \
  && grep -q "保持者: $BASE_OWNER" "$TMP/run-noswitch.log" \
  && grep -q "最終コミット:" "$TMP/run-noswitch.log" \
  && grep -q "switch なし掃除モードでの未実施項目" "$TMP/run-noswitch.log" \
  && grep -q "リモートブランチの削除:" "$TMP/run-noswitch.log" \
  && ! git show-ref -q "refs/heads/feature/#57-gone-noswitch"; then
  ok "占有ブランチを switch せず掃除を完遂し、base 保持 worktree は報告のみ"
else
  bad "switch なし掃除モードが期待どおりでない (exit=$EXIT_NOSWITCH)"
fi

# 44.1b base が別 worktree に checkout されている間は、checkout なしの base 最新化
#       （fetch base:base）が git 自身に拒否される。スキップして報告することを固定する
if grep -q "checkout なし最新化はできませんでした" "$TMP/run-noswitch.log"; then
  ok "base が checkout 済みなら fetch base:base の拒否をスキップとして報告する"
else
  bad "fetch base:base 拒否時の報告が無い"
fi

# 44.2 dirty な占有ブランチでも中断せず、変更に触れないまま掃除を完遂する
echo scratch > "$CALLER/session-scratch.txt"
git branch -q 'feature/#58-gone-noswitch' develop
SKIP_SIMPLE_GIT_HOOKS=1 git push -qu origin 'feature/#58-gone-noswitch'
SKIP_SIMPLE_GIT_HOOKS=1 git push -q origin --delete 'feature/#58-gone-noswitch'
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-noswitch-dirty.log" 2>&1
EXIT_NOSWITCH_DIRTY=$?
set -e
if [ "$EXIT_NOSWITCH_DIRTY" -eq 2 ] \
  && [ -f "$CALLER/session-scratch.txt" ] \
  && [ "$(git -C "$CALLER" branch --show-current)" = "other-session-work" ] \
  && grep -q "ブランチ切り替えを伴わない掃除モードで続行します" "$TMP/run-noswitch-dirty.log" \
  && ! grep -q "cleanup を中断します" "$TMP/run-noswitch-dirty.log" \
  && ! git show-ref -q "refs/heads/feature/#58-gone-noswitch"; then
  ok "dirty な占有ブランチでも中断せず、変更に触れないまま掃除を完遂する"
else
  bad "dirty な占有ブランチの扱いが期待どおりでない (exit=$EXIT_NOSWITCH_DIRTY)"
fi
rm -f "$CALLER/session-scratch.txt"

# 44.3 base をどの worktree も保持していなければ、checkout せずに base を最新化する
git -C "$BASE_OWNER" switch -q --detach
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-noswitch-ff.log" 2>&1
EXIT_NOSWITCH_FF=$?
set -e
if [ "$EXIT_NOSWITCH_FF" -eq 2 ] \
  && grep -q "checkout せずに最新化しました" "$TMP/run-noswitch-ff.log"; then
  ok "base が未保持なら fetch base:base で checkout せずに最新化する"
else
  bad "checkout なし最新化が期待どおりでない (exit=$EXIT_NOSWITCH_FF)"
fi

# 44.4 switch なし掃除モードで pre-merge-cleanup hook が呼び出し元のブランチを
#      切り替えた場合、「呼び出し元に触れない」契約を守れないため中断する
mkdir -p "$CALLER/.claude/hooks"
cat > "$CALLER/.claude/hooks/pre-merge-cleanup.sh" <<'HOOK'
#!/bin/sh
git switch -q --detach
HOOK
chmod +x "$CALLER/.claude/hooks/pre-merge-cleanup.sh"
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-noswitch-hook.log" 2>&1
EXIT_NOSWITCH_HOOK=$?
set -e
rm -rf "$CALLER/.claude"
git -C "$CALLER" switch -q other-session-work 2>/dev/null || true
if [ "$EXIT_NOSWITCH_HOOK" -eq 1 ] \
  && grep -q "pre-merge-cleanup hook が呼び出し元のブランチを" "$TMP/run-noswitch-hook.log" \
  && ! grep -q "マージ後 Cleanup 結果" "$TMP/run-noswitch-hook.log"; then
  ok "hook がブランチを切り替えたら switch なし掃除モードの契約違反として中断する"
else
  bad "hook のブランチ切り替え検出が期待どおりでない (exit=$EXIT_NOSWITCH_HOOK)"
fi

# 後続セクション（32 系）の前提（呼び出し元 develop 保持 / base 所有 detached）へ戻す
git -C "$CALLER" switch -q develop
git -C "$CALLER" branch -q -D other-session-work


# suite-cases-end: agent-worktrees.sh
