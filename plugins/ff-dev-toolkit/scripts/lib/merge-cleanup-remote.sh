#!/usr/bin/env bash
# merge-cleanup.sh の構成ファイル: Step 3 から Step 4（base 復帰、prune、対象 PR のリモートブランチ削除）。
#
# scripts/merge-cleanup.sh が、削除より前（Step 0.5 の直後）に 1 回 source する。
# 読めないときの停止は入口が行う。本文は分割前の連続した行。
# ここへ set / trap / source を足さない（本文中の set +e / set -e は分割前からある）。
# 末尾の _mc_part_loaded の行は読み込み完了の印。bash 3.2 互換。
# pipefail-inherited: merge-cleanup.sh が set -Eeuo pipefail の下で source する

# ---- Step 3: base ブランチ復帰 + 最新化（prune 必須） -------------------------

# リモートブランチ削除より先に base を最新化すること。
# --prune が無いとリモート削除済みブランチに [gone] マーカーが付かず Step 5 で検出できない。

BASE_WORKTREE=""
BASE_WORKTREE_OID=""
BASE_WORKTREE_DETACHED=0

if [ "$NO_SWITCH_MODE" = "1" ]; then
  echo "ℹ️ 呼び出し元は '${CURRENT_BRANCH_BEFORE:-（detached HEAD）}' を保持しています（base=${PR_BASE} / PR head=${PR_HEAD} のいずれでもありません）。"
  echo "   呼び出し元と別 worktree の HEAD を変更しないため、base への復帰・pull を行わない掃除モードで続行します。"

  # base を保持する worktree があれば報告だけする（detach も削除もしない。`#758`:
  # 他セッションの worktree は保持者パス・clean/dirty・最終更新を報告し、処分は
  # ユーザー判断に委ねる）。
  BASE_WORKTREE="$(find_worktree_for_branch "$PR_BASE" || true)"
  if [ -n "$BASE_WORKTREE" ]; then
    BASE_HOLDER_STATE="clean"
    if [ -n "$(git -C "$BASE_WORKTREE" status --porcelain 2>/dev/null)" ]; then
      BASE_HOLDER_STATE="dirty"
    fi
    BASE_HOLDER_LAST="$(git -C "$BASE_WORKTREE" log -1 --format='%cd' --date=iso 2>/dev/null || true)"
    echo "ℹ️ ${PR_BASE} は別の worktree が保持しています（削除も切り替えもしません。処分はユーザー判断）:"
    echo "   保持者: ${BASE_WORKTREE}（${BASE_HOLDER_STATE} / 最終コミット: ${BASE_HOLDER_LAST:-不明}）"
  fi

  if [ "$DRY_RUN" = "1" ]; then
    dry_run_skip "git fetch --prune origin（リモート追跡 ref を書き換えるため行いません）"
  else
    git fetch --prune origin 2>&1 \
      || die "git fetch --prune が失敗しました。ネットワーク / 認証を確認してください。"
  fi

  # checkout せずに base を最新化できるなら行う。base がどこかの worktree に
  # checkout されていると git 自身が拒否する（`#749` の実測）ので、その場合は
  # スキップして報告する（サマリーの未実施項目にも載せる）。
  BASE_FF_OUT=""
  if [ "$DRY_RUN" = "1" ]; then
    BASE_FF_NOTE="未実施（dry-run）"
    dry_run_skip "git fetch origin ${PR_BASE}:${PR_BASE}"
  elif BASE_FF_OUT="$(git fetch origin "$PR_BASE:$PR_BASE" 2>&1)"; then
    BASE_FF_NOTE="実施済み（git fetch origin ${PR_BASE}:${PR_BASE} で checkout せずに更新）"
    echo "ℹ️ ${PR_BASE} は checkout せずに最新化しました（git fetch origin ${PR_BASE}:${PR_BASE}）。"
  else
    BASE_FF_NOTE="未実施（git fetch origin ${PR_BASE}:${PR_BASE} が拒否された。base を保持する worktree 側で pull すること）"
    echo "ℹ️ ${PR_BASE} の checkout なし最新化はできませんでした（base を保持する worktree 側で pull してください）:"
    printf '%s\n' "$BASE_FF_OUT" | sed 's/^/   /'
  fi
fi

if [ "$NO_SWITCH_MODE" != "1" ] && [ "$CURRENT_BRANCH_BEFORE" != "$PR_BASE" ]; then
  BASE_WORKTREE="$(find_worktree_for_branch "$PR_BASE" || true)"
fi

if [ "$NO_SWITCH_MODE" != "1" ] && [ -n "$BASE_WORKTREE" ] && [ "$BASE_WORKTREE" != "$REPO_ROOT" ]; then
  # ここも Step 1 と同じ除外指定を効かせる。退避は同一 OID への detach なので
  # 作業ツリーの中身は変わらず、中断しても何も消えない側のガードにあたる。
  # 片方だけ緩めると、除外を設定したユーザーが別の dirty ガードで止まる。
  GUARD_ERR_STEP3="$WORK_TMP/guard_status_error.step3"
  BASE_WORKTREE_STATUS=""
  if ! BASE_WORKTREE_STATUS="$(guarded_status "$BASE_WORKTREE" 2>"$GUARD_ERR_STEP3")"; then
    die "$PR_BASE を保持する worktree の状態取得に失敗しました: $BASE_WORKTREE — $(guard_status_error_text "$GUARD_ERR_STEP3")"
  fi

  # 旧実装は 2>&1 で stderr を status 出力へ合流させており、exit 0 でも警告が出れば
  # 「非空 = dirty」とみなして中断していた（メッセージは的外れだが fail-closed）。
  # stderr を分離するとその判定が消えるので、明示的に戻す。走査が不完全なまま
  # detach → リモート削除 → worktree 削除へ進ませない（Step 5 の clean 確認が
  # 2>&1 のままなのと同じ安全等級を保つ）。
  BASE_WORKTREE_STDERR="$(guard_status_error_raw "$GUARD_ERR_STEP3")"
  if [ -n "$BASE_WORKTREE_STDERR" ]; then
    echo "❌ $PR_BASE を保持する worktree の status が警告を出しました: $BASE_WORKTREE"
    printf '%s\n' "$BASE_WORKTREE_STDERR" | sed 's/^/   /'
    die "作業ツリーを完全に走査できていない可能性があるため中断します（権限・マウント状態を確認してください）。"
  fi

  report_ignored_changes "$BASE_WORKTREE" "（${BASE_WORKTREE}）"

  if [ -n "$BASE_WORKTREE_STATUS" ]; then
    echo "❌ $PR_BASE を保持する別 worktree に未コミット変更があります: $BASE_WORKTREE"
    printf '%s\n' "$BASE_WORKTREE_STATUS"
    die "変更を保護するため、base ブランチの退避と cleanup を中断します。"
  fi

  BASE_WORKTREE_OID="$(git -C "$BASE_WORKTREE" rev-parse HEAD 2>&1)" \
    || die "$PR_BASE を保持する worktree の HEAD 取得に失敗しました: $BASE_WORKTREE — $BASE_WORKTREE_OID"

  if [ "$DRY_RUN" = "1" ]; then
    echo "ℹ️ ${PR_BASE} は別の clean worktree が保持しています（実行時は worktree を残して detached へ退避します）:"
  else
    echo "ℹ️ $PR_BASE は別の clean worktree が保持しています。worktree を残して detached へ退避します:"
  fi
  echo "   $BASE_WORKTREE ($BASE_WORKTREE_OID)"
  if [ "$DRY_RUN" = "1" ]; then
    # dirty ガード（上の status 確認と die）は実行時と同じ条件で通過済み。
    # 見送るのは退避そのものだけで、判定は緩めていない。
    dry_run_skip "git -C ${BASE_WORKTREE} switch --detach ${BASE_WORKTREE_OID}"
  else
    git -C "$BASE_WORKTREE" switch --detach "$BASE_WORKTREE_OID" 2>&1 \
      || die "$PR_BASE を保持する worktree の detached 退避に失敗しました: $BASE_WORKTREE"
    BASE_WORKTREE_DETACHED=1
  fi
fi

if [ "$NO_SWITCH_MODE" != "1" ] && [ "$DRY_RUN" = "1" ]; then
  dry_run_skip "git switch ${PR_BASE} / git fetch --prune origin / git pull --ff-only origin ${PR_BASE}"
fi

if [ "$NO_SWITCH_MODE" != "1" ] && [ "$DRY_RUN" != "1" ]; then
  SWITCH_OUT=""
  if ! SWITCH_OUT="$(git switch "$PR_BASE" 2>&1)"; then
    if [ "$BASE_WORKTREE_DETACHED" = "1" ]; then
      if git -C "$BASE_WORKTREE" switch "$PR_BASE" >/dev/null 2>&1; then
        echo "ℹ️ 呼び出し元の切り替え失敗に伴い、退避した worktree を $PR_BASE へ復旧しました。" >&2
      else
        die "$PR_BASE への切り替えに失敗し、退避した worktree の復旧にも失敗しました: ${SWITCH_OUT}（要手動確認: ${BASE_WORKTREE}）"
      fi
    fi
    die "$PR_BASE への切り替えに失敗しました: ${SWITCH_OUT}（'git worktree list' / 'git branch -a' を確認）。"
  fi
  printf '%s\n' "$SWITCH_OUT"

  git fetch --prune origin 2>&1 \
    || die "git fetch --prune が失敗しました。ネットワーク / 認証を確認してください。"

  git pull --ff-only origin "$PR_BASE" 2>&1 \
    || die "git pull --ff-only が失敗しました。$PR_BASE がローカルで分岐しているか、未コミット変更（FF_MERGE_CLEANUP_IGNORE_PATHS で除外したものを含む）が更新と競合しています（'git log $PR_BASE..origin/$PR_BASE' と 'git status' で確認し手動解消してください）。"
fi

# ---- Step 3.5: ガード情報の取得（Step 4/5/6 で共用、fail-closed） --------------

# MERGED 一覧: -D エスカレーション（Step 5）と取り残し照合（Step 6）の根拠
# open 一覧:   「同じ head を open PR が再利用していないか」ガード（Step 4/6）
GUARDS_OK=1
MERGED_LIST="$WORK_TMP/merged.list"   # "name<TAB>oid"（same-repo PR のみ）
AGENT_MERGED_OIDS="$WORK_TMP/agent_merged_oids.list"
OPEN_LIST="$WORK_TMP/open.list"       # "name"

# 大きめのリポジトリではこの取得が数分かかることがある（feelflow-website-2026 の
# 実測。`Issue #835`）。無出力のまま待たせると「ハング」と誤診されるため、取得の
# 前後で進捗を出す。上限は FF_MERGE_CLEANUP_MERGED_PR_LIMIT（Step 0.7、既定 1000）。
GH_MERGED_JSON=""
GH_OPEN_JSON=""
mc_file_guard_list() { # operation/state/limit -> canonical array; unavailable means preserve assets
  jq -n --arg repository "$github_repository" --arg state "$2" --argjson limit "$3" '{repository:$repository,state:$state,limit:$limit}' >"$WORK_TMP/github-scope.json" || return 2
  github_file_read "$github_input" "$1" "$WORK_TMP/github-scope.json" cleanup-guards "$WORK_TMP/github-position.json" >"$WORK_TMP/github-list.json" || return 2
  if [ "$GITHUB_INPUT_LAST" = false ]; then
    _github_input_error "$1" 'guard list incomplete: last=false'; return 2
  fi
  if [ -n "$GITHUB_INPUT_HTTP_STATUS" ] && [ "$GITHUB_INPUT_HTTP_STATUS" != 200 ]; then
    _github_input_error "$1" 'guard list unavailable: non-200 HTTP status'; return 2
  fi
  if ! jq -e 'type == "array" and all(.[]; .headRefName | type == "string" and length > 0)' "$WORK_TMP/github-list.json" >/dev/null; then
    _github_input_error "$1" 'required guard field: [].headRefName'; return 2
  fi
  if [ "$2" = merged ] && ! jq -e 'all(.[]; (.isCrossRepository | type == "boolean") and (.baseRefName | type == "string") and has("headRefOid"))' "$WORK_TMP/github-list.json" >/dev/null; then
    _github_input_error "$1" 'required guard field: [].isCrossRepository/baseRefName/headRefOid'; return 2
  fi
  cat "$WORK_TMP/github-list.json"
}
echo "⏳ ガード情報を取得しています: マージ済み PR 一覧（照合上限: ${MERGED_PR_LIMIT} 件）..."
mc_merged_rc=0
if [ -n "$github_input" ]; then
  GH_MERGED_JSON="$(mc_file_guard_list cleanup.merged-list merged "$MERGED_PR_LIMIT" 2>&1)" || mc_merged_rc=$?
else
  GH_MERGED_JSON="$(gh pr list --state merged --limit "$MERGED_PR_LIMIT" --json headRefName,headRefOid,isCrossRepository,baseRefName 2>&1)" || mc_merged_rc=$?
fi
if [ "$mc_merged_rc" -ne 0 ]; then
  echo "⚠️ マージ済み PR 一覧の取得に失敗しました（fail-closed で縮退）: $GH_MERGED_JSON"
  GUARDS_OK=0
else
  MERGED_FETCHED_COUNT="$(printf '%s' "$GH_MERGED_JSON" | jq 'length' 2>/dev/null)" || MERGED_FETCHED_COUNT=""
  echo "   … マージ済み PR 一覧を取得しました: ${MERGED_FETCHED_COUNT:-?} 件"
  if [ -n "$MERGED_FETCHED_COUNT" ] && [ "$MERGED_FETCHED_COUNT" -ge "$MERGED_PR_LIMIT" ]; then
    echo "ℹ️ マージ済み PR の照合は上限 ${MERGED_PR_LIMIT} 件で打ち切っています（これより古い MERGED PR は照合対象外。上限は FF_MERGE_CLEANUP_MERGED_PR_LIMIT で変更できます）"
  fi
  echo "⏳ ガード情報を取得しています: open PR 一覧..."
  mc_open_rc=0
  if [ -n "$github_input" ]; then
    GH_OPEN_JSON="$(mc_file_guard_list cleanup.open-list open 1000 2>&1)" || mc_open_rc=$?
  else
    GH_OPEN_JSON="$(gh pr list --state open --limit 1000 --json headRefName 2>&1)" || mc_open_rc=$?
  fi
  if [ "$mc_open_rc" -ne 0 ]; then
    echo "⚠️ open PR 一覧の取得に失敗しました（fail-closed で縮退）: $GH_OPEN_JSON"
    GUARDS_OK=0
  else
    echo "   … open PR 一覧を取得しました"
    printf '%s' "$GH_MERGED_JSON" \
      | jq -r '.[] | select(.isCrossRepository | not) | "\(.headRefName)\t\(.headRefOid)"' \
      | LC_ALL=C sort -u > "$MERGED_LIST"
    printf '%s' "$GH_OPEN_JSON" | jq -r '.[].headRefName' | LC_ALL=C sort -u > "$OPEN_LIST"
    printf '%s' "$GH_MERGED_JSON" | jq -r --arg base "$PR_BASE" '
      .[] | select(.isCrossRepository == false and .baseRefName == $base)
      | .headRefOid | select(type == "string" and test("^[0-9a-fA-F]{40}$"))
    ' | sort -u > "$AGENT_MERGED_OIDS"
  fi
fi

# ---- Step 4: 対象 PR のリモートブランチ削除 -----------------------------------

PR_REMOTE_RESULT="skipped"

if [ "$PR_CROSS_REPO" = "true" ]; then
  # fork PR の head は fork 側にある。origin の同名ブランチは別物の可能性があるため触らない
  echo "ℹ️  PR #$PR_NUM は fork からの PR です。origin 側のブランチ削除はスキップします。"
  PR_REMOTE_RESULT="skipped_fork"
elif [ "$GUARDS_OK" != "1" ]; then
  echo "⚠️ open PR ガードを構成できないため、対象 PR のリモートブランチ削除をスキップします（fail-closed）。"
  PR_REMOTE_RESULT="skipped_guard_unavailable"
  FAILED_ITEMS+=("$PR_HEAD: ガード情報取得失敗によりリモート削除未実施")
elif grep -qxF "$PR_HEAD" "$OPEN_LIST"; then
  echo "⚠️ $PR_HEAD は別の open PR の head として使用中です。リモート削除をスキップします。"
  PR_REMOTE_RESULT="skipped_open_reuse"
  SKIPPED_LEFTOVERS+=("$PR_HEAD: open PR の head として使用中")
elif [ "$PR_HEAD_OID_OK" != "1" ]; then
  # open PR ガードの後に置く。open PR で再利用中なら削除しないこと自体は正常系で、
  # OID が無いことを失敗として重ねると余計な PARTIAL になる。
  #
  # 削除を諦める前に ref の実在だけは確かめる。GitHub の merge 時削除などで
  # 既に消えている場合、「削除未実施」を積むと**毎回 PARTIAL が出続ける**
  # （消すものが無いので何度実行しても解消しない）。
  # --exit-code は「ref なし」を 2 で返す。通信・認証の失敗（128 等）と区別し、
  # 後者は「消えている」と断定せず fail-closed で失敗として扱う。
  PR_HEAD_LSREMOTE_ERR="$WORK_TMP/pr_head_lsremote_error"
  PR_HEAD_LSREMOTE_OUT=""
  set +e
  PR_HEAD_LSREMOTE_OUT="$(LC_ALL=C git ls-remote --exit-code --heads origin "refs/heads/$PR_HEAD" 2>"$PR_HEAD_LSREMOTE_ERR")"
  PR_HEAD_LSREMOTE_RC=$?
  set -e
  PR_REMOTE_RESULT="skipped_oid_unavailable"
  case "$PR_HEAD_LSREMOTE_RC" in
    0)
      PR_HEAD_REMOTE_OID="$(printf '%s\n' "$PR_HEAD_LSREMOTE_OUT" | awk 'NR == 1 { print $1 }')"
      echo "⚠️ PR #$PR_NUM の headRefOid を取得できませんでした（gh pr view の応答が null）。--force-with-lease の照合対象が無いため、リモートブランチ削除をスキップします（fail-closed）。"
      echo "   origin には $PR_HEAD が残っています（現在の OID: ${PR_HEAD_REMOTE_OID}）。"
      # 無条件の `push --delete` は案内しない。この時点で「その ref が対象 PR の
      # head である」ことは誰も確認していないため、確認と削除の間に入った push や
      # 同名ブランチの再利用ごと消してしまう。人間が OID を照合したうえで、
      # 照合した OID を lease に載せる形だけを案内する。
      echo "   復旧手順: 1) 上の OID が PR #$PR_NUM の head であることを PR ページ / コミット履歴で確認する"
      echo "             2) 確認できたら: git push origin --force-with-lease=refs/heads/$PR_HEAD:${PR_HEAD_REMOTE_OID} :refs/heads/$PR_HEAD"
      echo "             3) 確認できなければ削除しない（別の作業が push している可能性がある）"
      echo "             4) 削除できたら merge-cleanup を再実行してローカル資産を掃除する"
      # ここでは FAILED_ITEMS へ積まない。Step 6 の取り残し掃除が同じブランチを
      # （一覧側の正常な OID をアンカーに）消せる場合があり、その場合は実際の失敗が
      # 起きていないため。消せなかった場合だけ Step 8 の冒頭で失敗として積む。
      PR_OID_PENDING_FAILURE="$PR_HEAD: headRefOid を取得できずリモート削除未実施 — origin の現 OID ${PR_HEAD_REMOTE_OID} が PR #$PR_NUM の head だと確認できた場合のみ 'git push origin --force-with-lease=refs/heads/$PR_HEAD:${PR_HEAD_REMOTE_OID} :refs/heads/$PR_HEAD' で削除し merge-cleanup を再実行（確認できない場合は削除しない）"
      ;;
    2)
      # ref が無い = 削除すべきものが無い。失敗ではないので積まない
      echo "ℹ️  PR #$PR_NUM の headRefOid は取得できませんでしたが、origin に $PR_HEAD は既にありません（削除不要）。"
      PR_REMOTE_RESULT="already_missing"
      INFO_ITEMS+=("$PR_HEAD: headRefOid は gh pr view から取得できなかったが、origin 上の ref は既に存在しない")
      ;;
    *)
      echo "⚠️ PR #$PR_NUM の headRefOid を取得できず、origin 上の $PR_HEAD の実在確認にも失敗しました。リモートブランチ削除をスキップします（fail-closed）: $(cat "$PR_HEAD_LSREMOTE_ERR")"
      PR_OID_PENDING_FAILURE="$PR_HEAD: headRefOid の取得と ref の実在確認がどちらも失敗しリモート削除未実施 — ネットワーク / 認証を確認して merge-cleanup を再実行（実在と OID を確認できるまで削除しない）"
      ;;
  esac
elif [ "$DRY_RUN" = "1" ]; then
  # ここに来る時点で、fork 判定・ガード情報の有無・open PR 再利用・headRefOid の
  # 有無は実行時と同じ順に評価済み。見送るのは削除 push そのものだけ。
  #
  # ただし「push を見送る」は「無条件に削除対象と書いてよい」ではない。実行時の削除は
  # --force-with-lease で origin 側の OID を照合するため、ref が無い / OID が違えば
  # 実行しても消えない。headRefOid が取れたことだけを根拠に would_delete と書くと、
  # 再利用された同名ブランチや既に消えた ref を過剰に予告することになる。
  DRY_PR_HEAD_VERDICT="$(remote_delete_verdict "$PR_HEAD" "$PR_HEAD_OID")"
  # 区切りはタブ。リテラルのタブを ${} の中へ直書きすると読み手に見えないので cut で割る
  DRY_PR_HEAD_REMOTE_OID="$(printf '%s' "$DRY_PR_HEAD_VERDICT" | cut -f2-)"
  case "$(printf '%s' "$DRY_PR_HEAD_VERDICT" | cut -f1)" in
    match)
      echo "🗑️  リモートブランチ削除（対象）: $PR_HEAD (PR #$PR_NUM: $PR_TITLE)"
      dry_run_skip "git push --force-with-lease=refs/heads/${PR_HEAD}:${PR_HEAD_OID} origin :refs/heads/${PR_HEAD}"
      PR_REMOTE_RESULT="would_delete"
      ;;
    mismatch)
      # 実行時は lease に拒否されて削除されない（= 保護）。予告でも削除対象にしない。
      echo "  ⚠️ $PR_HEAD はマージ後に更新されています（origin の現 OID ${DRY_PR_HEAD_REMOTE_OID} ≠ PR #$PR_NUM の head ${PR_HEAD_OID}）。実行時も lease 拒否で削除されないため、削除対象にしません。"
      PR_REMOTE_RESULT="skipped_lease_rejected"
      SKIPPED_LEFTOVERS+=("$PR_HEAD: マージ後 push あり（実行時も lease 拒否）")
      ;;
    missing)
      echo "ℹ️  origin に $PR_HEAD は既にありません（実行時も削除は不要）。"
      PR_REMOTE_RESULT="already_missing"
      ;;
    *)
      # 判定材料が取れないなら削除対象と書かない（fail-closed）。予告を出せていない
      # ことは黙らせず、サマリーの失敗項目にも載せる。
      echo "⚠️ origin 上の $PR_HEAD の実在・OID を確認できませんでした。削除対象かどうか判定できないため予告しません（fail-closed）: ${DRY_PR_HEAD_REMOTE_OID}"
      PR_REMOTE_RESULT="skipped_remote_check_failed"
      FAILED_ITEMS+=("$PR_HEAD: origin 上の ref を確認できず dry-run の削除予告を保留（ネットワーク / 認証を確認）")
      ;;
  esac
else
  echo "🗑️  リモートブランチ削除: $PR_HEAD (PR #$PR_NUM: $PR_TITLE)"
  # 削除 push の前に、dry-run と同じ判定で ref の実在と OID 一致を確かめる
  # （公開 ff-dev-toolkit#137）。消えた ref への削除 push も pre-push hook を起動し、
  # git は更新する ref が無いので hook へ空の stdin を渡す。consumer の「削除だけなら
  # スキップ」判定（全行の local sha が 0 のとき）は行が無いと成り立たず、フル
  # ゲートが走る。match のときだけ push し、それ以外は push せずに delete_remote_
  # branch_with_lease と同じ戻り値へ写して下の分岐を共有する。push 時の
  # stale info 再取得は残す — 照合と push の間に ref が消える / 進む競合は残るため。
  PR_HEAD_VERDICT="$(remote_delete_verdict "$PR_HEAD" "$PR_HEAD_OID")"
  PR_HEAD_VERDICT_DETAIL="$(printf '%s' "$PR_HEAD_VERDICT" | cut -f2-)"
  case "$(printf '%s' "$PR_HEAD_VERDICT" | cut -f1)" in
    match)
      set +e
      delete_remote_branch_with_lease "$PR_HEAD" "$PR_HEAD_OID"
      rc=$?
      set -e
      ;;
    missing)
      echo "  ℹ️  削除前の照合（git ls-remote）: origin に $PR_HEAD が無いため、削除 push は行いません。"
      rc=2
      ;;
    mismatch)
      echo "  ℹ️  削除前の照合（git ls-remote）: origin の現 OID ${PR_HEAD_VERDICT_DETAIL} ≠ PR #$PR_NUM の head ${PR_HEAD_OID} のため、削除 push は行いません（push しても lease に拒否される）。"
      rc=3
      ;;
    *)
      printf '削除前の照合（git ls-remote --exit-code）に失敗したため、削除 push は行っていません: %s\n' \
        "$PR_HEAD_VERDICT_DETAIL" > "$WORK_TMP/last_push_error"
      rc=1
      ;;
  esac
  case "$rc" in
    0)
      echo "  ✓ removed: $PR_HEAD"
      PR_REMOTE_RESULT="deleted"
      ;;
    2)
      echo "  ℹ️  リモートブランチは既に削除されていました（続行）"
      PR_REMOTE_RESULT="already_missing"
      ;;
    3)
      echo "  ⚠️ $PR_HEAD はマージ後に更新されています（lease 拒否 = 新しい push あり）。削除をスキップします。"
      PR_REMOTE_RESULT="skipped_lease_rejected"
      SKIPPED_LEFTOVERS+=("$PR_HEAD: マージ後 push あり（lease 拒否）")
      ;;
    *)
      # 削除できなかったこと自体は Step 5 以降の掃除と独立している。ここで die すると
      # 一過性のネットワーク断で [gone] ブランチ削除・トランスクリプト回収・取り残し
      # 掃除・最終検証が丸ごと未実施のまま終わるため、Step 6 と同じく失敗として記録し
      # PARTIAL で続行する（削除していない点は変わらない = 保護は維持）。
      echo "  ❌ リモートブランチ削除に失敗しました: $(last_push_error_text)（権限 / ネットワーク / ブランチ保護ルールを確認）"
      PR_REMOTE_RESULT="failed"
      # 原因をサマリーまで運ぶ。従来は die のメッセージが最終行に出ていたが、続行に
      # したことで診断行とサマリーの間に Step 5〜7 の出力が挟まるため。
      FAILED_ITEMS+=("$PR_HEAD: リモート削除失敗（$(last_push_error_head)）")
      ;;
  esac
fi

# 削除を反映して [gone] マーカーを付ける。
# ここで die すると、リモート削除の失敗で掃除全体を止めないという上の判断が 2 行先で
# 破れる（rc=1 の主要因であるネットワーク断は、この fetch も同時に失敗させる）。
# 失敗しても安全側にしか外れない: ref は Step 3 の fetch 時点まで新しく、prune が
# 飛ぶと「消えたはずのブランチが [gone] に見えない」= 処理対象が減るだけ。Step 5 の
# -D は MERGED PR との (名前, OID) 照合を維持し、Step 6 は自前の ls-remote で判定する。
if [ "$DRY_RUN" = "1" ]; then
  dry_run_skip "削除反映の git fetch --prune origin（代わりに read-only の ls-remote で prune 後の [gone] を予測します）"
else
  git fetch --prune origin 2>&1 || {
    echo "⚠️ 削除反映の fetch --prune が失敗しました。[gone] 判定が不完全な可能性があります。"
    FAILED_ITEMS+=("削除反映の fetch --prune 失敗: [gone] 検出が不完全な可能性")
  }
fi

_mc_part_loaded="merge-cleanup-remote.sh"
