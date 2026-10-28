#!/usr/bin/env bash
# merge-cleanup.sh の構成ファイル: Step 5 から Step 7.5（[gone] と worktree、エージェントブランチ、トランスクリプト、取り残し、最終検証、post hook）。
#
# scripts/merge-cleanup.sh が、削除より前（Step 0.5 の直後）に 1 回 source する。
# 読めないときの停止は入口が行う。本文は分割前の連続した行。
# ここへ set / trap / source を足さない（本文中の set +e / set -e は分割前からある）。
# 末尾の _mc_part_loaded の行は読み込み完了の印。bash 3.2 互換。
# pipefail-inherited: merge-cleanup.sh が set -Eeuo pipefail の下で source する

# ---- Step 5: [gone] ブランチ + 関連 worktree の削除 ---------------------------

# grep は「マッチ 0 件」で exit 1 を返すが、[gone] ゼロ件は正常系なので || true で許容する
GONE_BRANCHES="$(git for-each-ref \
  --format='%(if:equals=[gone])%(upstream:track)%(then)%(refname:short)%(end)' \
  refs/heads/ | grep -v '^$' || true)"

if [ "$DRY_RUN" = "1" ]; then
  # 仮想 prune。実行時に「リモート削除 → prune → 新たに [gone] → その worktree」と
  # 連鎖して消えるものを、副作用なしで予告へ足す（dry_virtual_prune_gone_branches の
  # コメント参照）。fetch --prune は撃たない = リポジトリ状態は変えない。
  DRY_EXTRA_GONE_LIST="$WORK_TMP/dry_extra_gone.list"
  if dry_virtual_prune_gone_branches > "$DRY_EXTRA_GONE_LIST"; then
    if [ -s "$DRY_EXTRA_GONE_LIST" ]; then
      echo "ℹ️ (dry-run) 実行時の削除と fetch --prune で新たに [gone] になるブランチを予告へ含めます（そのブランチと worktree も実行時には消えます）:"
      sed 's/^/  - /' "$DRY_EXTRA_GONE_LIST"
      if [ -n "$GONE_BRANCHES" ]; then
        GONE_BRANCHES="${GONE_BRANCHES}
$(cat "$DRY_EXTRA_GONE_LIST")"
      else
        GONE_BRANCHES="$(cat "$DRY_EXTRA_GONE_LIST")"
      fi
    fi
  else
    # 予告を出せないまま「[gone] はありません」と書くと、実行すると消えるものが
    # 一覧から丸ごと落ちる。黙らせず失敗として積む（fail-closed）。
    echo "⚠️ origin のブランチ一覧を取得できませんでした。prune 後に新しく [gone] になるブランチ（と、その worktree）を予告できません（fail-closed）: $(cat "$WORK_TMP/dry_virtual_prune_error" 2>/dev/null | tr '\n' ' ')"
    FAILED_ITEMS+=("dry-run: origin のブランチ一覧を取得できず、prune 連鎖で削除されるブランチ / worktree を予告できていない")
  fi
fi

# dry-run の `git branch -d` 相当の判定に使う基準コミット。実行時の -d は
# **base へ switch して pull した後の HEAD** に対してマージ済みかを見る。dry-run は
# switch も pull もしないので、現在の HEAD を基準にすると実行時と判定が食い違う
# （受け入れ条件「dry-run だけ判定が緩まない」に直接抵触する。緩む向きにも厳しくなる
# 向きにもずれる）。実行時が使う base 相当の commit を明示的に基準にする:
#   - switch なし掃除モード = 実行時も HEAD のままなので HEAD
#   - それ以外 = base の先端。pull 後に最も近い origin/<base> を優先し、無ければ
#     ローカルの <base>、どちらも解決できなければ HEAD へ落として理由を出す
DRY_MERGED_BASE_REF=""
if [ "$DRY_RUN" = "1" ]; then
  if [ "$NO_SWITCH_MODE" = "1" ]; then
    DRY_MERGED_BASE_REF="HEAD"
  elif git rev-parse --verify --quiet "refs/remotes/origin/$PR_BASE" >/dev/null 2>&1; then
    DRY_MERGED_BASE_REF="refs/remotes/origin/$PR_BASE"
  elif git rev-parse --verify --quiet "refs/heads/$PR_BASE" >/dev/null 2>&1; then
    DRY_MERGED_BASE_REF="refs/heads/$PR_BASE"
  else
    DRY_MERGED_BASE_REF="HEAD"
    echo "⚠️ (dry-run) ${PR_BASE} の先端を解決できないため、'git branch -d' 相当の判定を現在の HEAD で行います（実行時の判定と食い違う可能性があります）。"
  fi
  echo "ℹ️ (dry-run) [gone] ブランチの 'git branch -d' 相当の判定は ${DRY_MERGED_BASE_REF} を基準に行います（実行時に base へ switch / pull した後の HEAD に相当）。"
fi

if [ -z "$GONE_BRANCHES" ]; then
  echo "✅ [gone] ブランチはありません。"
else
  echo "🧹 [gone] ブランチを処理します:"
  printf '%s\n' "$GONE_BRANCHES" | sed 's/^/  - /'

  # switch なし掃除モードでは呼び出し元のブランチが [gone] のこともある。checkout 中の
  # ブランチは git 自身が削除を拒否するが、失敗（PARTIAL）ではなく名指しのスキップにする
  CURRENT_BRANCH_STEP5="$(git branch --show-current)"
  if [ "$DRY_RUN" = "1" ] && [ "$NO_SWITCH_MODE" != "1" ]; then
    # 実行時はこの時点で既に base へ switch している。現在の checkout を基準にすると、
    # 実行時には切り替わって削除できるブランチを「呼び出し元がチェックアウト中」として
    # 予告から落とすことになる（-d の判定基準を base 相当に寄せるのと同じ理由で、
    # 予告が実際の削除より少なくなる向きのずれを塞ぐ）。
    CURRENT_BRANCH_STEP5="$PR_BASE"
  fi

  while IFS= read -r branch; do
    [ -z "$branch" ] && continue
    echo ""
    echo "=== Processing: $branch ==="

    # [gone] に保護ブランチが現れるのは異常系だが、絶対に削除しない
    if is_protected_branch "$branch"; then
      echo "  ⚠️ skip (保護ブランチ): $branch"
      SKIPPED_LEFTOVERS+=("$branch: 保護ブランチ（ローカル [gone]）")
      continue
    fi

    if [ -n "$CURRENT_BRANCH_STEP5" ] && [ "$branch" = "$CURRENT_BRANCH_STEP5" ]; then
      echo "  ⚠️ skip (呼び出し元がチェックアウト中): $branch"
      SKIPPED_LEFTOVERS+=("$branch: 呼び出し元がチェックアウト中のためローカル削除せず")
      continue
    fi

    # worktree path を porcelain 出力から抽出（スペース含むパスにも対応）
    WORKTREE_PATH=""
    current_wt=""
    while IFS= read -r line; do
      case "$line" in
        "worktree "*) current_wt="${line#worktree }" ;;
        "branch refs/heads/$branch") WORKTREE_PATH="$current_wt"; break ;;
      esac
    done < <(git worktree list --porcelain)

    # optional post-branch-cleanup hook（DDEV stop など project 固有処理の差し込みポイント）
    HOOK="$REPO_ROOT/.claude/hooks/post-branch-cleanup.sh"
    if [ -f "$HOOK" ] && [ "$DRY_RUN" = "1" ]; then
      dry_run_skip "post-branch-cleanup hook の実行: ${HOOK} (${branch})"
    elif [ -f "$HOOK" ] && [ -x "$HOOK" ]; then
      echo "▶ running $HOOK ($branch)"
      if ! BRANCH="$branch" WORKTREE_PATH="$WORKTREE_PATH" "$HOOK"; then
        echo "  ⚠️ post-branch-cleanup hook が失敗。次のブランチへ進みます。"
        FAILED_ITEMS+=("$branch: post-branch-cleanup hook 失敗")
        continue
      fi
    elif [ -f "$HOOK" ]; then
      echo "  ⚠️ $HOOK は実行可能ではありません（chmod +x してください）。スキップします。"
    fi

    if [ -n "$WORKTREE_PATH" ] && [ "$WORKTREE_PATH" != "$REPO_ROOT" ]; then
      # dirty な worktree は削除しない（未コミット変更を握りつぶさない）
      WT_STATUS="$(git -C "$WORKTREE_PATH" status --porcelain 2>&1)" || {
        echo "  ❌ worktree の状態確認に失敗: $WT_STATUS"
        FAILED_ITEMS+=("$branch: worktree 状態確認失敗 ($WORKTREE_PATH)")
        continue
      }

      # マージ済みエージェント worktree の自動処理（`Issue #914`）。
      # サブエージェント並列開発の worktree はハーネスのロック（reason: claude agent）と
      # untracked の .review-results で毎回削除に失敗し、unlock → force remove の手動
      # 3 手を要して常に PARTIAL になっていた。次の **3 条件をすべて**満たす場合に限り
      # unlock + 使い捨てパスの除去 + 削除を自動で行う:
      #   1. (名前, ローカル OID) が MERGED PR の head と一致（-D エスカレーションと同じ証拠）
      #   2. ロックされていて、ロック理由に claude agent を含む（未ロックは対象外）
      #   3. dirty の内訳が既知の使い捨てパス（.review-results）の untracked だけ（clean も可）
      # 証拠が欠ける・未知の残置物がある・ロックが無い/理由が異なる場合は
      # 従来どおり削除せず保護する（fail-closed）。
      WT_LOCAL_OID="$(git rev-parse "refs/heads/$branch" 2>/dev/null || true)"
      WT_MERGED_MATCH=0
      if [ "$GUARDS_OK" = "1" ] && [ -n "$WT_LOCAL_OID" ] \
        && grep -qxF "$(printf '%s\t%s' "$branch" "$WT_LOCAL_OID")" "$MERGED_LIST"; then
        WT_MERGED_MATCH=1
      fi

      WT_LOCK_REASON=""
      WT_LOCKED=0
      if WT_LOCK_REASON="$(worktree_lock_reason "$WORKTREE_PATH")"; then
        WT_LOCKED=1
      fi
      WT_CLAUDE_LOCK=0
      if [ "$WT_LOCKED" = "1" ] && grep -qi 'claude agent' <<<"$WT_LOCK_REASON"; then
        WT_CLAUDE_LOCK=1
      fi

      WT_AGENT_PATH=0
      if [ "$WT_MERGED_MATCH" = "1" ] && [ "$WT_CLAUDE_LOCK" = "1" ] \
        && { [ -z "$WT_STATUS" ] || agent_disposable_status_only "$WT_STATUS"; }; then
        WT_AGENT_PATH=1
      fi

      # claude agent 以外のロックは、dirty かどうかによらずロックを理由に保護する
      # （ロックがある限り削除は成立せず、真の障害物はロックのため）
      if [ "$WT_LOCKED" = "1" ] && [ "$WT_CLAUDE_LOCK" != "1" ]; then
        echo "  ⚠️ worktree がロックされています（理由: ${WT_LOCK_REASON:-（記載なし）}）。削除をスキップします。"
        echo "     自動 unlock するのは「ロック理由が claude agent かつ (名前, OID) が MERGED PR の head と一致」の場合だけです。"
        FAILED_ITEMS+=("$branch: worktree がロックされており自動 unlock の条件外 ($WORKTREE_PATH)")
        continue
      fi

      if [ -n "$WT_STATUS" ] && [ "$WT_AGENT_PATH" != "1" ]; then
        echo "  ⚠️ worktree に未コミット変更があります。削除をスキップします: $WORKTREE_PATH"
        git -C "$WORKTREE_PATH" status --short | sed 's/^/     /'
        FAILED_ITEMS+=("$branch: worktree に未コミット変更あり ($WORKTREE_PATH)")
        continue
      fi

      if [ "$WT_LOCKED" = "1" ] && [ "$WT_AGENT_PATH" != "1" ]; then
        # claude agent ロックだが MERGED OID 照合が成立しない（clean だが unlock 条件外）
        echo "  ⚠️ worktree がロックされています（理由: ${WT_LOCK_REASON:-（記載なし）}）。削除をスキップします。"
        echo "     自動 unlock するのは「ロック理由が claude agent かつ (名前, OID) が MERGED PR の head と一致」の場合だけです。"
        FAILED_ITEMS+=("$branch: worktree がロックされており自動 unlock の条件外 ($WORKTREE_PATH)")
        continue
      fi

      WT_AGENT_NOTES=""
      if [ "$WT_AGENT_PATH" = "1" ] && [ "$DRY_RUN" = "1" ]; then
        # 3 条件（OID 照合 / claude agent ロック / 残置物が使い捨てパスのみ）は
        # 上で実行時と同じ条件を通過済み。unlock と除去だけを見送る。
        echo "  ℹ️ マージ済みエージェント worktree の条件を満たします（実行時は unlock と使い捨てパス除去を行います）。"
        dry_run_skip "git worktree unlock ${WORKTREE_PATH} / rm -rf ${WORKTREE_PATH}/.review-results"
        WT_AGENT_NOTES="claude agent ロックの解除と使い捨てパス除去（dry-run のため未実施）"
      elif [ "$WT_AGENT_PATH" = "1" ]; then
        WT_UNLOCK_OUT=""
        if WT_UNLOCK_OUT="$(git worktree unlock "$WORKTREE_PATH" 2>&1)"; then
          echo "  ℹ️ claude agent ロックを解除しました（(名前, OID) が MERGED PR の head と一致）: ${WT_LOCK_REASON:-（理由の記載なし）}"
          WT_AGENT_NOTES="claude agent ロックを解除"
        else
          echo "  ❌ worktree の unlock に失敗: $WT_UNLOCK_OUT"
          FAILED_ITEMS+=("$branch: worktree unlock 失敗 ($WORKTREE_PATH)")
          continue
        fi
        if [ -n "$WT_STATUS" ]; then
          # --force での worktree ごと削除はしない。status 確認の後に入った変更まで
          # 巻き込むため（TOCTOU）。既知の使い捨てパスだけを個別に除去し、削除自体は
          # force なしの `git worktree remove` に委ねる — 確認後に別の変更が入っていれば
          # git 自身が拒否して fail-closed に戻る。
          echo "  ℹ️ worktree の残置物は既知の使い捨てパス（.review-results）だけで、(名前, OID) は MERGED PR の head と一致します。"
          echo "     使い捨てパス（.review-results）を除去してから worktree を削除します:"
          printf '%s\n' "$WT_STATUS" | sed 's/^/     /'
          if ! rm -rf "$WORKTREE_PATH/.review-results"; then
            echo "  ❌ 使い捨てパスの除去に失敗しました。ロックを元に戻して保護します: $WORKTREE_PATH"
            git worktree lock --reason "$WT_LOCK_REASON" "$WORKTREE_PATH" 2>&1 \
              || echo "  ⚠️ ロックの復元にも失敗しました（unlock されたまま残ります）: $WORKTREE_PATH"
            FAILED_ITEMS+=("$branch: 使い捨てパスの除去失敗 ($WORKTREE_PATH)")
            continue
          fi
          WT_AGENT_NOTES="${WT_AGENT_NOTES}、使い捨てパス（.review-results）を除去"
        fi
      fi

      echo "  worktree: $WORKTREE_PATH"
      # Claude Code はトランスクリプト格納先の名前を「symlink 解決済みの絶対パス」から
      # 導出する（macOS の /tmp は /private/tmp として記録される）。削除後は解決できない
      # ので Step 5.5 のためにここで控える。解決できなければ元のパスで代用するが、
      # その場合は候補名が総当たりで外れうるので黙って進めない。
      WORKTREE_REAL="$(resolve_dir "$WORKTREE_PATH" || true)"
      if [ -z "$WORKTREE_REAL" ]; then
        echo "  ⚠️ worktree パスを正規化できませんでした。トランスクリプトを取りこぼす可能性があります: $WORKTREE_PATH"
      fi
      # --force は付けない（エージェント経路を含む全経路）: 直前の clean 確認・
      # 使い捨てパス除去の後に変更が入った場合、git 自身が拒否するので TOCTOU の
      # 安全網になる。エージェント経路で拒否された場合は unlock 前の状態へ戻す
      # （元の理由で再ロック）。
      # 注意: .gitignore 対象のファイル（.env 等）は clean 扱いのまま削除される。
      # 惜しいファイルを worktree の ignored 領域にだけ置く運用は避けること（コマンド doc にも明記）
      WORKTREE_RM_OUT=""
      if [ "$DRY_RUN" = "1" ]; then
        # clean 確認・ロック判定は実行時と同じ条件を通過済み。削除だけ見送る。
        dry_run_skip "git worktree remove ${WORKTREE_PATH}"
      elif ! WORKTREE_RM_OUT="$(git worktree remove "$WORKTREE_PATH" 2>&1)"; then
        echo "  ❌ worktree 削除に失敗: $WORKTREE_RM_OUT"
        echo "     ブランチ削除もスキップします。手動対応してください。"
        if [ "$WT_AGENT_PATH" = "1" ]; then
          if git worktree lock --reason "$WT_LOCK_REASON" "$WORKTREE_PATH" 2>&1; then
            echo "     解除していた claude agent ロックを元の理由で復元しました。"
          else
            echo "  ⚠️ ロックの復元にも失敗しました（unlock されたまま残ります）: $WORKTREE_PATH"
          fi
        fi
        FAILED_ITEMS+=("$branch: worktree 削除失敗 ($WORKTREE_PATH)")
        continue
      fi
      if [ "$DRY_RUN" = "1" ]; then
        echo "  ✓ (dry-run) 削除対象の worktree: $WORKTREE_PATH"
      else
        echo "  ✓ worktree removed: $WORKTREE_PATH"
      fi
      if [ -n "$WT_AGENT_NOTES" ]; then
        INFO_ITEMS+=("$branch: マージ済みエージェント worktree を自動処理（(名前, OID) が MERGED PR の head と一致。${WT_AGENT_NOTES}）")
      fi
      DELETED_WORKTREES+=("$WORKTREE_PATH")
      DELETED_WORKTREE_REALS+=("${WORKTREE_REAL:-$WORKTREE_PATH}")
    fi

    # まず -d（小文字）でマージ済みのみ削除を試す。
    # dry-run では -d 自体が削除なので撃てない。同じ 1 段目（マージ済みか）を、
    # 削除を伴わない merge-base で等価に判定してから 2 段目の OID 照合へ落とす。
    # 判定材料（MERGED 一覧・ローカル OID）は実行時とまったく同じものを使う。
    BRANCH_DEL_OUT=""
    BRANCH_DELETE_MODE="run"
    if [ "$DRY_RUN" = "1" ]; then
      if git merge-base --is-ancestor "refs/heads/$branch" "$DRY_MERGED_BASE_REF" 2>/dev/null; then
        BRANCH_DELETE_MODE="dry_merged"
      else
        BRANCH_DELETE_MODE="dry_escalate"
      fi
    fi

    if [ "$BRANCH_DELETE_MODE" = "dry_merged" ]; then
      dry_run_skip "git branch -d ${branch}"
      echo "  ✓ (dry-run) 削除対象のブランチ: $branch"
      DELETED_BRANCHES+=("$branch")
    elif [ "$BRANCH_DELETE_MODE" != "dry_escalate" ] \
      && BRANCH_DEL_OUT="$(LC_ALL=C git branch -d "$branch" 2>&1)"; then
      echo "  ✓ branch deleted: $branch"
      DELETED_BRANCHES+=("$branch")
    elif [ "$BRANCH_DELETE_MODE" = "dry_escalate" ] \
      || grep -qE 'not fully merged' <<<"$BRANCH_DEL_OUT"; then
      # squash merge 由来は -d で消せない。ただし [gone] は「upstream が消えた」ことしか
      # 保証しないため、-D は (名前, ローカル OID) が MERGED PR の head と一致する
      # ブランチに限定する（手動でリモート削除された未マージ作業を消さないため）
      LOCAL_OID="$(git rev-parse "refs/heads/$branch")"
      if [ "$GUARDS_OK" = "1" ] && grep -qxF "$(printf '%s\t%s' "$branch" "$LOCAL_OID")" "$MERGED_LIST"; then
        if [ "$DRY_RUN" = "1" ]; then
          dry_run_skip "git branch -D ${branch}（squash merge 済みを OID 照合で確認）"
          echo "  ✓ (dry-run) 削除対象のブランチ: $branch"
          DELETED_BRANCHES+=("$branch")
        elif BRANCH_DEL_OUT="$(git branch -D "$branch" 2>&1)"; then
          echo "  ✓ branch deleted (forced, squash merge 済みを OID 照合で確認): $branch"
          DELETED_BRANCHES+=("$branch")
        else
          echo "  ❌ ブランチ削除に失敗: $BRANCH_DEL_OUT"
          FAILED_ITEMS+=("$branch: git branch -D 失敗")
        fi
      elif [ "$GUARDS_OK" = "1" ] && grep -qxF "$(printf '%s\tnull' "$branch")" "$MERGED_LIST"; then
        # MERGED 一覧に名前は載っているが、一覧側の headRefOid が null で返っている
        # （`#570` / `#703` の root cause）。このとき実際に無いのは**照合材料**であって
        # 未マージの証拠ではないため、「未マージの固有コミットの可能性」と誤帰属しない。
        # 利用者に存在しない未マージコミットを探させないことが目的で、削除しない点は同じ。
        echo "  ⚠️ $branch は MERGED PR の head 名として一覧に載っていますが、一覧側の OID が null で照合材料がありません。"
        echo "     未マージの可能性ではなく OID 照合が成立しないため、削除をスキップします。"
        echo "     マージ済みであることを PR ページで確認できた場合のみ、手動で次を実行してください:"
        echo "       $(ff_shell_argv git branch -D "$branch")"
        FAILED_ITEMS+=("$branch: [gone] だが MERGED 一覧側の OID が null で照合材料が無い（要手動確認）")
      else
        echo "  ⚠️ $branch はマージ済み PR の head と OID 一致しません（未マージの固有コミットの可能性）。"
        echo "     削除をスキップします。内容確認のうえ手動で次を実行してください:"
        echo "       $(ff_shell_argv git branch -D "$branch")"
        FAILED_ITEMS+=("$branch: [gone] だが MERGED PR と OID 不一致（要手動確認）")
      fi
    else
      echo "  ❌ ブランチ削除に失敗: $BRANCH_DEL_OUT"
      FAILED_ITEMS+=("$branch: git branch -d 失敗")
    fi
  done <<< "$GONE_BRANCHES"
fi

# ---- Step 5.4: 取り残されたエージェントブランチの削除 ------------------------
# agent-branch-cleanup:start
# [gone] にならない初期ブランチだけの取り残しも扱う。worktree はこの経路で
# unlock / remove しない。名前だけで実行中の委譲先を片付けないための境界。
AGENT_BRANCHES=""
if ! AGENT_BRANCHES="$(git for-each-ref --format='%(refname:short)' 'refs/heads/worktree-agent-*' 2>"$WORK_TMP/agent_refs.err")"; then
  FAILED_ITEMS+=("worktree-agent-*: ローカルブランチ一覧の取得失敗により削除未実施")
elif [ -n "$AGENT_BRANCHES" ]; then
  AGENT_WORKTREES="$WORK_TMP/agent_worktrees.list"
  AGENT_WORKTREES_OK=1
  if ! git worktree list --porcelain > "$AGENT_WORKTREES" 2>"$WORK_TMP/agent_worktrees.err" \
    || [ -s "$WORK_TMP/agent_worktrees.err" ] \
    || ! grep -q '^worktree ' "$AGENT_WORKTREES"; then
    AGENT_WORKTREES_OK=0
  fi
  # この機能は常に base を基準にする。他セッションの HEAD はマージ証拠にしない。
  AGENT_BASE_REF="refs/heads/$PR_BASE"
  if [ "$DRY_RUN" = "1" ] && git rev-parse --verify --quiet "refs/remotes/origin/$PR_BASE" >/dev/null 2>&1; then
    AGENT_BASE_REF="refs/remotes/origin/$PR_BASE"
  fi
  echo "🧹 worktree-agent-* ローカルブランチの削除候補を確認します:"
  while IFS= read -r branch; do
    [ -n "$branch" ] || continue
    AGENT_SKIP=""
    AGENT_LOCAL_OID=""
    if is_protected_branch "$branch"; then
      AGENT_SKIP="保護ブランチ"
    elif [ "$AGENT_WORKTREES_OK" != "1" ]; then
      AGENT_SKIP="worktree 一覧を確認できない（fail-closed）"
    elif grep -qxF "branch refs/heads/$branch" "$AGENT_WORKTREES"; then
      AGENT_SKIP="worktree が保持中（削除・unlock しない）"
    elif ! AGENT_LOCAL_OID="$(git rev-parse --verify "refs/heads/$branch" 2>/dev/null)"; then
      AGENT_SKIP="ローカル OID を確認できない（fail-closed）"
    elif ! git merge-base --is-ancestor "$AGENT_LOCAL_OID" "$AGENT_BASE_REF" 2>/dev/null; then
      if [ "$GUARDS_OK" != "1" ] || ! grep -qxF "$AGENT_LOCAL_OID" "$AGENT_MERGED_OIDS"; then
        AGENT_SKIP="base の祖先ではなく、同じ base の MERGED PR head OID とも一致しない"
      fi
    fi
    if [ -z "$AGENT_SKIP" ]; then
      AGENT_REMOTE_RC=0
      git ls-remote --exit-code --heads origin "refs/heads/$branch" > "$WORK_TMP/agent_remote.out" 2>"$WORK_TMP/agent_remote.err" || AGENT_REMOTE_RC=$?
      case "$AGENT_REMOTE_RC" in
        2) if [ -s "$WORK_TMP/agent_remote.out" ] || [ -s "$WORK_TMP/agent_remote.err" ]; then
             AGENT_SKIP="origin の同名 ref の不存在を確認できない（fail-closed）"
           fi ;;
        0) AGENT_SKIP="origin に同名 ref が存在する" ;;
        *) AGENT_SKIP="origin の同名 ref を照合できない（fail-closed）" ;;
      esac
    fi
    if [ -n "$AGENT_SKIP" ]; then
      echo "  ⚠️ skip: ${branch}: ${AGENT_SKIP}"
      SKIPPED_LEFTOVERS+=("${branch}: ${AGENT_SKIP}")
    elif [ "$DRY_RUN" = "1" ]; then
      echo "  ✓ (dry-run) 削除候補のエージェントブランチ: $branch"
      DELETED_AGENT_BRANCHES+=("$branch")
    elif AGENT_DEL_OUT="$(git branch -D "$branch" 2>&1)"; then
      echo "  ✓ エージェントブランチを削除: $branch"
      DELETED_AGENT_BRANCHES+=("$branch")
    else
      FAILED_ITEMS+=("${branch}: エージェントブランチ削除失敗 (${AGENT_DEL_OUT})")
    fi
  done <<< "$AGENT_BRANCHES"
fi
# agent-branch-cleanup:end

# ---- Step 5.5: 削除した worktree のトランスクリプト回収 -----------------------
#
# Claude Code は作業ディレクトリごとに独立したトランスクリプトディレクトリを
# <config>/projects/ 配下へ作る。worktree を消してもこれは残るため、二度と
# 参照されない履歴が無制限に溜まる（標準の cleanupPeriodDays は経過日数でしか
# 消さないので、期限内の孤児は残り続ける）。
#
# 「名前が一致したから消す」ことはしない。jsonl に記録された cwd が削除した
# worktree を指していることを照合してから処理する。リモート削除を
# --force-with-lease に、-D を OID 照合に限定しているのと同じ fail-closed の
# 考え方で、名前だけの一致では /a/b-c と /a/b/c を区別できない。
#
# 既定は削除ではなく tar.gz へのアーカイブ。履歴を失わずに容量を回収でき、
# 「未コミット変更を握りつぶさない」という本スクリプトの原則とも揃う。
#
# 環境変数:
#   FF_MERGE_CLEANUP_TRANSCRIPTS=off                … この Step を無効化（既定 archive）
#   FF_MERGE_CLEANUP_PROJECTS_DIR=<path>            … projects ディレクトリの上書き
#   FF_MERGE_CLEANUP_TRANSCRIPT_ARCHIVE_DIR=<path>  … アーカイブ先の上書き

TRANSCRIPT_MODE="${FF_MERGE_CLEANUP_TRANSCRIPTS:-archive}"

# 値の検証は「削除した worktree があったか」に依存させない。綴り違いで黙って
# 無効化されると「回収したはず」の誤解を生むため、実行のたびに必ず報告する。
if [ "$TRANSCRIPT_MODE" != "archive" ] && [ "$TRANSCRIPT_MODE" != "off" ]; then
  echo ""
  echo "⚠️ FF_MERGE_CLEANUP_TRANSCRIPTS の値が不正です: ${TRANSCRIPT_MODE}（archive / off のみ）"
  TRANSCRIPT_STEP_NOTE="スキップ（環境変数の値が不正: ${TRANSCRIPT_MODE}）"
  FAILED_ITEMS+=("トランスクリプト回収: FF_MERGE_CLEANUP_TRANSCRIPTS の値が不正 ($TRANSCRIPT_MODE)")
elif [ "$TRANSCRIPT_MODE" = "off" ]; then
  TRANSCRIPT_STEP_NOTE="無効（FF_MERGE_CLEANUP_TRANSCRIPTS=off）"
elif [ "$DRY_RUN" = "1" ]; then
  # この Step の対象は「今回実際に削除できた worktree の分」だけで、dry-run では
  # 1 つも削除しない。候補を先回りして一覧にすると、実行時に worktree の削除が
  # 保護・失敗で見送られた場合にアーカイブもされないため、一覧が実行時と食い違う。
  # 値の検証（上の不正値ブロック）は dry-run でも実行時と同じに行う。
  TRANSCRIPT_STEP_NOTE="未評価（dry-run。実際に削除できた worktree の分だけが対象のため）"
elif [ "${#DELETED_WORKTREES[@]}" -eq 0 ]; then
  : # 削除した worktree が無ければ対象も無い
else
  CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}"
  PROJECTS_DIR="${FF_MERGE_CLEANUP_PROJECTS_DIR:-$CLAUDE_HOME/projects}"
  ARCHIVE_DIR="${FF_MERGE_CLEANUP_TRANSCRIPT_ARCHIVE_DIR:-$CLAUDE_HOME/transcript-archives}"
  PROJECTS_REAL=""
  ARCHIVE_DIR_READY=0
  PROCESSED_NAMES=""
  TRANSCRIPT_CANDIDATES=0

  if ! PROJECTS_REAL="$(resolve_dir "$PROJECTS_DIR")"; then
    # 既定パスが無いのは Claude Code 未使用というだけで異常ではない。一方、
    # 明示的に指定されたパスが解決できないのは設定ミスなので PARTIAL にする。
    TRANSCRIPT_STEP_NOTE="スキップ（projects ディレクトリを解決できません: ${PROJECTS_DIR}）"
    if [ -n "${FF_MERGE_CLEANUP_PROJECTS_DIR:-}" ] || [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
      echo ""
      echo "⚠️ 明示指定された projects ディレクトリを解決できません: ${PROJECTS_DIR}"
      FAILED_ITEMS+=("トランスクリプト回収: 指定された projects ディレクトリを解決できない ($PROJECTS_DIR)")
    fi
  else
    echo ""
    echo "🗂 削除した worktree のトランスクリプトを回収します（アーカイブ先: ${ARCHIVE_DIR}）"

    for WT_IDX in "${!DELETED_WORKTREES[@]}"; do
      # symlink 解決の前後どちらで記録されていても拾えるよう、両方を基準にする
      WT_BASES="$(printf '%s\n%s\n' \
        "${DELETED_WORKTREES[$WT_IDX]}" "${DELETED_WORKTREE_REALS[$WT_IDX]}" \
        | awk 'NF && !seen[$0]++')"

      while IFS= read -r WT_BASE; do
        [ -n "$WT_BASE" ] || continue

        while IFS= read -r CAND_NAME; do
          # 複数の基準パスや worktree が同じ名前へ潰れても 1 回だけ処理する
          case "$PROCESSED_NAMES" in
            *"<$CAND_NAME>"*) continue ;;
          esac
          case "$CAND_NAME" in
            ''|.|..|*/*) continue ;;
          esac
          PROCESSED_NAMES="$PROCESSED_NAMES<$CAND_NAME>"

          CAND_PATH="$PROJECTS_DIR/$CAND_NAME"
          [ -d "$CAND_PATH" ] || continue
          # 1 件でも候補を見たら「対象なし」とは言わない（保護・失敗で終わった
          # ものを「そもそも無かった」と報告すると、事実と食い違う）
          TRANSCRIPT_CANDIDATES=$((TRANSCRIPT_CANDIDATES + 1))
          # 候補そのものが symlink なら、リンク先が projects 内でも辿らない
          if [ -L "$CAND_PATH" ]; then
            echo "  ○ シンボリックリンクのため辿りません: $CAND_PATH"
            SKIPPED_TRANSCRIPTS+=("$CAND_NAME: シンボリックリンク")
            continue
          fi
          # 経路の途中に symlink があっても projects 直下へ着地することを確認する
          # （直前の -L と重なる保護だが、片方だけでは経路途中の差し替えを塞げない）
          CAND_REAL=""
          if ! CAND_REAL="$(resolve_dir "$CAND_PATH")" \
            || [ "$(dirname "$CAND_REAL")" != "$PROJECTS_REAL" ]; then
            echo "  ○ projects ディレクトリ直下に解決されないため残します: $CAND_PATH"
            SKIPPED_TRANSCRIPTS+=("$CAND_NAME: projects 直下へ解決されない")
            continue
          fi

          CWD_VERDICT=0
          transcript_cwd_verdict "$CAND_REAL" "$WT_BASES" || CWD_VERDICT=$?
          case "$CWD_VERDICT" in
            0)
              CAND_REASON="cwd 照合一致"
              if [ -s "$WORK_TMP/transcript_foreign_cwd" ]; then
                # 通常はセッションが親リポジトリ等へ移動しただけ。ただし名前が
                # 衝突した別プロジェクトと同居している可能性も残るため、
                # アーカイブごと回収する事実を見えるところに出す。
                CAND_REASON="cwd 照合一致（worktree 外の cwd も含む）"
                echo "  ℹ️ この履歴には worktree 外の作業ディレクトリも記録されています。まとめてアーカイブします:"
                sed 's/^/       /' "$WORK_TMP/transcript_foreign_cwd"
              fi
              ;;
            2)
              # cwd を記録した jsonl が無い。プラグインが書く付随データ
              # （skill-injections.jsonl 等）だけのディレクトリが常にこれに当たる。
              #
              # ここで「名前が worktree 由来に見えるから消す」と降格させない。候補名は
              # 削除した worktree のパスから導出したものなので、その名前を見ても
              # 「渡されたパスが worktree だった」以上のことは分からず、目の前の
              # ディレクトリが誰のものかという肝心の問いには答えていない。
              # 回収できない分は別途 sweep 側で扱う。
              SKIPPED_TRANSCRIPTS+=("$CAND_NAME: cwd を記録した jsonl が無く所有者を確認できない")
              echo "  ○ 所有者を確認できないため残します（cwd を記録した jsonl なし）: $CAND_NAME"
              continue
              ;;
            3)
              # 名前が衝突した別プロジェクトのディレクトリはここに来る。異常では
              # ないので PARTIAL にはせず、保護した事実だけ残す。
              SKIPPED_TRANSCRIPTS+=("$CAND_NAME: cwd がこの worktree を指していない")
              echo "  ○ この worktree を指す cwd が無いため残します: $CAND_NAME"
              continue
              ;;
            4)
              # 証拠の取得自体に失敗している。「証拠が無い」と同じ扱いにはできない
              # （読めなかっただけかもしれない）ので、手当が要る失敗として報告する。
              echo "  ⚠️ jsonl の走査でエラーが出たため処理しません（証拠を取り切れていない）: $CAND_NAME"
              FAILED_ITEMS+=("トランスクリプト回収: jsonl 走査エラーで保護 ($CAND_NAME)")
              continue
              ;;
            *)
              echo "  ⚠️ 想定外の照合結果のため処理しません（判定コード ${CWD_VERDICT}）: $CAND_NAME"
              FAILED_ITEMS+=("トランスクリプト回収: 想定外の照合結果で保護 ($CAND_NAME)")
              continue
              ;;
          esac

          if [ "$ARCHIVE_DIR_READY" != "1" ]; then
            if ! mkdir -p "$ARCHIVE_DIR" 2>/dev/null; then
              echo "  ❌ アーカイブ先を作成できません: $ARCHIVE_DIR"
              echo "     残りの候補も同じ理由で失敗するため、この Step を中断します。"
              FAILED_ITEMS+=("トランスクリプト回収: アーカイブ先を作成できない ($ARCHIVE_DIR)")
              # note を立てないと、この後のサマリーが「対象はありませんでした」と
              # 中断の事実に反する表示になる
              TRANSCRIPT_STEP_NOTE="中断（アーカイブ先を作成できない: ${ARCHIVE_DIR}）"
              break 3
            fi
            ARCHIVE_DIR_READY=1
          fi

          # 容量は付随情報。du の失敗で破壊的 Step 全体を落とさない
          # （pipefail + errexit の下では、代入内のパイプ失敗がそのまま致命傷になる）
          CAND_KB=""
          CAND_KB="$(du -sk "$CAND_REAL" 2>"$WORK_TMP/du_error" | awk 'NR == 1 { print $1 }')" || CAND_KB=""
          if [ -z "$CAND_KB" ]; then
            CAND_KB=0
            echo "  ⚠️ 容量を計測できませんでした（回収は続行します）: $CAND_NAME"
          fi

          # 同一秒に同名が来ても既存アーカイブを黙って上書きしない
          # （-e は壊れた symlink を見落とすので -L も見る）
          ARCHIVE_STAMP="$(date +%Y%m%d-%H%M%S)"
          ARCHIVE_FILE="$ARCHIVE_DIR/$CAND_NAME-$ARCHIVE_STAMP.tar.gz"
          ARCHIVE_SEQ=1
          while [ -e "$ARCHIVE_FILE" ] || [ -L "$ARCHIVE_FILE" ]; do
            ARCHIVE_FILE="$ARCHIVE_DIR/$CAND_NAME-$ARCHIVE_STAMP-$ARCHIVE_SEQ.tar.gz"
            ARCHIVE_SEQ=$((ARCHIVE_SEQ + 1))
          done

          # 完成するまで最終名を名乗らせない。作業ファイル名は予測させない
          # （予測できる名前だと、先回りして置かれた symlink のリンク先を
          #  tar が切り詰めうる）。mktemp なら常に新規の通常ファイルになる。
          ARCHIVE_TMP=""
          if ! ARCHIVE_TMP="$(mktemp "$ARCHIVE_DIR/.merge-cleanup-archive-XXXXXX")"; then
            FAILED_ITEMS+=("トランスクリプト回収: 作業ファイルを作成できない ($CAND_NAME)")
            echo "  ❌ アーカイブ用の作業ファイルを作成できません。元ディレクトリは残します: $CAND_NAME"
            continue
          fi
          ARCHIVE_LIST="$WORK_TMP/archive_list"
          ARCHIVE_ERR="$WORK_TMP/archive_error"
          ARCHIVE_VERIFY=""
          TAR_OUT=""
          ARCHIVE_FAIL=""

          # ディレクトリ名は '-' 始まりなので、-C + './名前' でオプション誤認を避ける
          if ! TAR_OUT="$(tar -czf "$ARCHIVE_TMP" -C "$PROJECTS_REAL" "./$CAND_NAME" 2>&1)"; then
            ARCHIVE_FAIL="tar が失敗しました"
          elif ! tar -tzf "$ARCHIVE_TMP" > "$ARCHIVE_LIST" 2>"$ARCHIVE_ERR"; then
            # 終了コードだけを信じない。読み直せないアーカイブを根拠に元を消すと
            # そのまま履歴の消失になる
            TAR_OUT="$(cat "$ARCHIVE_ERR")"
            ARCHIVE_FAIL="アーカイブを読み直せませんでした"
          else
            SRC_ENTRIES=""
            SRC_ENTRIES="$(find "$CAND_REAL" ! -type d 2>/dev/null | wc -l | tr -d ' ')" || SRC_ENTRIES=""
            # tar はディレクトリを末尾 '/' 付きで並べるので、それ以外を数える
            ARC_ENTRIES="$(grep -cv '/$' "$ARCHIVE_LIST" || true)"
            if [ -z "$SRC_ENTRIES" ] || [ "$SRC_ENTRIES" != "$ARC_ENTRIES" ]; then
              TAR_OUT="元 ${SRC_ENTRIES:-?} 件 / アーカイブ ${ARC_ENTRIES} 件"
              ARCHIVE_FAIL="アーカイブの件数が元と一致しません"
            elif ! ARCHIVE_VERIFY="$(mktemp -d "$WORK_TMP/archive-verify-XXXXXX")"; then
              TAR_OUT="検証用ディレクトリを作成できません"
              ARCHIVE_FAIL="アーカイブと元を比較できませんでした"
            elif ! tar -xzf "$ARCHIVE_TMP" -C "$ARCHIVE_VERIFY" > /dev/null 2> "$ARCHIVE_ERR"; then
              TAR_OUT="$(cat "$ARCHIVE_ERR")"
              ARCHIVE_FAIL="アーカイブを検証用に展開できませんでした"
            else
              # marker との mtime 比較は、時計補正や時刻分解能の境界で未変更ファイルを
              # 誤検出し、同一 mtime の追記を見逃しうる。作成済みアーカイブを展開して
              # バイト列を直接比較し、tar 実行後の追加・削除・内容変更を判定する。
              DIFF_RC=0
              diff -r --no-dereference "$CAND_REAL" "$ARCHIVE_VERIFY/$CAND_NAME" > "$ARCHIVE_ERR" 2>&1 || DIFF_RC=$?
              if [ "$DIFF_RC" -eq 1 ]; then
                TAR_OUT="$(cat "$ARCHIVE_ERR")"
                ARCHIVE_FAIL="アーカイブ中に元が変更されました"
              elif [ "$DIFF_RC" -ne 0 ]; then
                TAR_OUT="$(cat "$ARCHIVE_ERR")"
                ARCHIVE_FAIL="アーカイブと元を比較できませんでした"
              fi
            fi
          fi

          if [ -n "$ARCHIVE_FAIL" ]; then
            # 記録を先に積む。この後の出力や rm が失敗しても PARTIAL の主張を失わない
            FAILED_ITEMS+=("トランスクリプト回収: $ARCHIVE_FAIL ($CAND_NAME)")
            echo "  ❌ ${ARCHIVE_FAIL}。元ディレクトリは残します: $CAND_NAME"
            printf '%s\n' "$TAR_OUT" | sed 's/^/     /' || true
            rm -f "$ARCHIVE_TMP" || true
            continue
          fi

          if ! mv "$ARCHIVE_TMP" "$ARCHIVE_FILE"; then
            FAILED_ITEMS+=("トランスクリプト回収: アーカイブの確定に失敗 ($CAND_NAME)")
            echo "  ❌ アーカイブの確定に失敗しました。元ディレクトリは残します: $CAND_NAME"
            rm -f "$ARCHIVE_TMP" || true
            continue
          fi

          # 照合から削除までの隙間で候補が差し替えられていないか直前に確かめ直す。
          # bash では fd を握ったまま削除できないため窓を狭めるだけで、完全には
          # 閉じられない（残る窓は mv 直後から rm までの数ミリ秒）
          RECHECK_REAL=""
          if [ -L "$CAND_PATH" ] \
            || ! RECHECK_REAL="$(resolve_dir "$CAND_PATH")" \
            || [ "$RECHECK_REAL" != "$CAND_REAL" ] \
            || [ "$(dirname "$RECHECK_REAL")" != "$PROJECTS_REAL" ]; then
            FAILED_ITEMS+=("トランスクリプト回収: 削除直前の再確認に失敗したため保護 ($CAND_NAME)")
            echo "  ⚠️ 削除直前の再確認に失敗したため元ディレクトリは残します: $CAND_NAME"
            echo "     アーカイブは作成済みです: $ARCHIVE_FILE"
            continue
          fi

          if ! rm -rf "$CAND_REAL"; then
            FAILED_ITEMS+=("トランスクリプト回収: アーカイブ後の削除失敗 ($CAND_NAME)")
            echo "  ❌ アーカイブ後の削除に失敗しました（アーカイブと元が二重に残ります）: $CAND_REAL"
            continue
          fi

          ARCHIVE_KB=""
          ARCHIVE_KB="$(du -sk "$ARCHIVE_FILE" 2>/dev/null | awk 'NR == 1 { print $1 }')" || ARCHIVE_KB=""
          [ -n "$ARCHIVE_KB" ] || ARCHIVE_KB=0
          echo "  ✓ archived: $CAND_NAME (${CAND_KB} KB → ${ARCHIVE_KB} KB, $CAND_REASON)"
          ARCHIVED_TRANSCRIPTS+=("$CAND_NAME")
          ARCHIVED_TRANSCRIPT_KB=$((ARCHIVED_TRANSCRIPT_KB + CAND_KB))
          ARCHIVE_TOTAL_KB=$((ARCHIVE_TOTAL_KB + ARCHIVE_KB))
        done < <(transcript_dir_names_for "$WT_BASE")
      done <<< "$WT_BASES"
    done

    if [ "$TRANSCRIPT_CANDIDATES" -eq 0 ] && [ -z "$TRANSCRIPT_STEP_NOTE" ]; then
      echo "  対象のトランスクリプトはありませんでした。"
    fi
  fi
fi

# ---- Step 6: リモート取り残しのガード付き自動削除（fail-closed） ---------------

# delete_branch_on_merge=false の repo では UI 経由マージや cleanup スキップで
# マージ済みリモートブランチが累積する。以下の全ガードを通過したものだけ自動削除する:
#   1. (名前, OID) が MERGED 済み PR の head と完全一致（名前再利用・マージ後 push を除外）
#   2. fork PR 由来でない（origin の同名別ブランチを誤射しない）
#   3. 保護ブランチ名でない
#   4. open PR の head として再利用されていない
# 削除自体も --force-with-lease で「照合した OID のときだけ」実行する（TOCTOU 対策）。
# 削除は delete_remote_branch_with_lease（SKIP_SIMPLE_GIT_HOOKS=1 HUSKY=0）経由。
# 候補は直前の ls-remote 一覧に載った (名前, OID) なので、Step 4 の事前照合は重ねない。
# ガード情報の取得に失敗している場合は Step 6 全体をスキップする（fail-closed）

echo ""
echo "=== リモート取り残し検証 ==="

LEFTOVER_CHECK_DONE=0

if [ "$GUARDS_OK" != "1" ]; then
  echo "⚠️ ガード情報（MERGED / open PR 一覧）が構成できていないため、取り残し検証をスキップします（fail-closed）。"
else
  echo "⏳ リモートブランチ一覧を取得しています（git ls-remote --heads origin）..."
  LS_REMOTE_OUT=""
  if ! LS_REMOTE_OUT="$(git ls-remote --heads origin 2>&1)"; then
    echo "⚠️ git ls-remote に失敗しました。取り残し検証をスキップします（fail-closed）: $LS_REMOTE_OUT"
  else
    LEFTOVER_CHECK_DONE=1

    REMOTE_LIST="$WORK_TMP/remote.list"   # "name<TAB>oid"
    printf '%s\n' "$LS_REMOTE_OUT" \
      | awk -F'\t' '{ sub("refs/heads/", "", $2); print $2 "\t" $1 }' \
      | LC_ALL=C sort -u > "$REMOTE_LIST"

    # (名前, OID) 完全一致のみ候補にする。OID も控えて lease 付き削除に使う
    LEFTOVER="$(LC_ALL=C comm -12 "$MERGED_LIST" "$REMOTE_LIST")"

    if [ -z "$LEFTOVER" ]; then
      # 対象 PR の削除をスキップしていた場合、その head は照合に一致しないまま
      # origin に残っている可能性がある。「取り残しなし」と断定すると、スキップの
      # 通知を読み飛ばした利用者に「掃除は完了した」と伝わるため、除外を添える。
      LEFTOVER_NONE_NOTE=""
      case "$PR_REMOTE_RESULT" in
        skipped*) LEFTOVER_NONE_NOTE="（今回スキップした ${PR_HEAD} を除く）" ;;
      esac
      echo "✅ リモート取り残しなし（直近 ${MERGED_PR_LIMIT} 件のマージ済み PR と (名前, OID) 照合）${LEFTOVER_NONE_NOTE}"
    else
      echo "🧹 リモート取り残しのマージ済みブランチを検出しました:"
      printf '%s\n' "$LEFTOVER" | cut -f1 | sed 's/^/  - /'
      echo ""

      while IFS="$(printf '\t')" read -r rbranch roid; do
        [ -z "$rbranch" ] && continue

        if is_hardcoded_protected_branch "$rbranch"; then
          echo "  ⚠️ skip (保護ブランチ): $rbranch"
          SKIPPED_LEFTOVERS+=("$rbranch: 保護ブランチ")
          continue
        fi

        if grep -qxF "$rbranch" "$OPEN_LIST"; then
          echo "  ⚠️ skip (open PR で再利用中): $rbranch"
          SKIPPED_LEFTOVERS+=("$rbranch: open PR の head として再利用中")
          continue
        fi

        # 設定可能な保護パターン（既定 release/*。`Issue #1056`）に止められたものは、
        # ここまでの全ガード（MERGED head と (名前, OID) 一致 / fork 由来でない /
        # open PR 未使用）を通過している = 「マージ済みで安全に消せる」ことが証明済みで、
        # 止めているのは名前パターンだけ。毎回同じ skip が無言で積み上がると本当に
        # 判断が要る skip がノイズに埋もれるため、手動判断の材料（削除コマンドと
        # 恒久設定）を添えて報告する。
        if PROTECT_HIT="$(matched_extra_protect_pattern "$rbranch")"; then
          echo "  ⚠️ skip (設定保護パターン '${PROTECT_HIT}' に一致): $rbranch"
          echo "     このブランチはマージ済みで他の全ガードを通過しています。長命ブランチでなければ手動で削除できます:"
          echo "       $(ff_shell_argv git push origin "--force-with-lease=refs/heads/$rbranch:$roid" ":refs/heads/$rbranch")"
          echo "     恒久対応は FF_MERGE_CLEANUP_PROTECT_BRANCHES の見直し（既定 'release/*'、'none' で追加保護なし。develop/main/master/staging/* は設定でも外れません）"
          SKIPPED_LEFTOVERS+=("$rbranch: 設定保護パターン '${PROTECT_HIT}' に一致（マージ済み・手動削除コマンドは実行ログ参照）")
          continue
        fi

        if [ "$DRY_RUN" = "1" ]; then
          # Step 4 で削除対象に挙げた head は、実行時にはこの時点で既に消えていて
          # 取り残し一覧に載らない。dry-run では消していないので載るが、同じ 1 本を
          # 2 回数えると「実行時に削除されるもの」の件数が実態とずれる。
          if [ "$PR_REMOTE_RESULT" = "would_delete" ] \
            && [ "$rbranch" = "$PR_HEAD" ] && [ "$roid" = "$PR_HEAD_OID" ]; then
            echo "  ℹ️ (dry-run) $rbranch は Step 4 の削除対象です（実行時はこの時点で既に消えているため、ここでは重複して数えません）。"
            continue
          fi
          dry_run_skip "git push --force-with-lease=refs/heads/${rbranch}:${roid} origin :refs/heads/${rbranch}"
          echo "  ✓ (dry-run) 削除対象の取り残し: $rbranch"
          DELETED_LEFTOVERS+=("$rbranch")
          continue
        fi

        set +e
        delete_remote_branch_with_lease "$rbranch" "$roid"
        rc=$?
        set -e
        case "$rc" in
          0)
            echo "  ✓ removed: $rbranch"
            DELETED_LEFTOVERS+=("$rbranch")
            # Step 4 で削除に失敗した対象 PR の head をここで削除できた場合、サマリーの
            # 「対象 PR のリモートブランチ」を失敗のまま残すと実態と食い違う。
            # FAILED_ITEMS の記録は残す（実際に 1 回失敗しており PARTIAL が正しい）。
            # 名前だけでなく OID も照合する（同名別 OID の取り残しを消したときに
            # 対象 PR の行を書き換えないため）。
            if is_pr_head_retry "$rbranch" "$roid"; then
              PR_REMOTE_RESULT="deleted_by_leftover_retry"
            elif is_pr_head_retry_no_oid "$rbranch"; then
              # headRefOid が取れずスキップした対象を、一覧側の正常な OID を
              # アンカーにここで消せたケース。Step 4 の「失敗」は起きていない
              # （削除を見送っただけ）ので、保留していた失敗行は補足行へ落とす。
              PR_REMOTE_RESULT="deleted_by_leftover_retry"
              PR_OID_PENDING_FAILURE=""
              INFO_ITEMS+=("$rbranch: headRefOid は gh pr view から取得できなかったが、取り残し検証の (名前, OID) 照合で削除済み")
            fi
            ;;
          2)
            echo "  ℹ️  already removed: $rbranch"
            # 再試行の時点で消えていた場合も、Step 4 の failed を残すと最終状態と
            # 食い違う。消したのは自分ではないので deleted ではなく already 扱い。
            if is_pr_head_retry "$rbranch" "$roid"; then
              PR_REMOTE_RESULT="already_missing_at_leftover_retry"
            elif is_pr_head_retry_no_oid "$rbranch"; then
              PR_REMOTE_RESULT="already_missing_at_leftover_retry"
              PR_OID_PENDING_FAILURE=""
              INFO_ITEMS+=("$rbranch: headRefOid は gh pr view から取得できなかったが、取り残し検証の時点で既に削除済み")
            fi
            ;;
          3)
            echo "  ⚠️ skip (照合後に push あり・lease 拒否): $rbranch"
            SKIPPED_LEFTOVERS+=("$rbranch: 照合後に push あり（lease 拒否）")
            if is_pr_head_retry_no_oid "$rbranch"; then
              # headRefOid が取れずスキップした対象を Step 6 が拾い、照合の後に
              # push が入って lease に拒否されたケース。**削除しないのは保護**で
              # あって失敗ではない（Step 4 の skipped_lease_rejected と同格）ため、
              # 保留していた「削除未実施」の失敗行を落とす。残さないと、正常な
              # 保護に対して PARTIAL と誤った復旧手順を出すことになる。
              # 既知 OID 側（is_pr_head_retry）の rc=3 はここでは触らない。
              # あちらは Step 4 で実際に削除を試みて失敗しており、その失敗行が
              # 残るのは正当なため。
              PR_REMOTE_RESULT="skipped_lease_rejected_at_leftover_retry"
              PR_OID_PENDING_FAILURE=""
            fi
            ;;
          *)
            echo "  ❌ 削除失敗: $rbranch — $(last_push_error_text)"
            # 恒久的な失敗（ブランチ保護・権限など）では、Step 4 で失敗した head が
            # ここで必ず再試行されて再び失敗する。同じ文言を 2 行並べると「2 本
            # 失敗した」と読めるため、2 回目であることを文言で区別する。
            if is_pr_head_retry "$rbranch" "$roid"; then
              FAILED_ITEMS+=("$rbranch: リモート削除失敗（Step 6 の再試行も失敗: $(last_push_error_head)）")
            elif is_pr_head_retry_no_oid "$rbranch"; then
              # Step 4 は削除を試みていない（headRefOid が無くスキップ）ので「再試行」
              # ではなく最初の試行。保留していた「未実施」の行はここで消し、1 行に
              # 束ねる（「未実施」と「削除失敗」を 2 行並べると実態と食い違う）。
              PR_OID_PENDING_FAILURE=""
              # ここでの $roid は取り残し一覧との (名前, OID) 完全一致を通っており、
              # 「MERGED 済み PR の head」であることが確認済み。無条件の削除ではなく、
              # その OID を lease に載せた形を案内する（再試行までの間に push が
              # 入っていれば、この形なら拒否されて保護される）。
              FAILED_ITEMS+=("$rbranch: リモート削除失敗（headRefOid が無く Step 4 はスキップ / 取り残し検証での削除も失敗: $(last_push_error_head)）— 再試行して merge-cleanup を再実行。再試行のコマンド: $(ff_shell_argv git push origin "--force-with-lease=refs/heads/$rbranch:$roid" ":refs/heads/$rbranch")")
            else
              FAILED_ITEMS+=("$rbranch: リモート削除失敗（$(last_push_error_head)）")
            fi
            ;;
        esac
      done <<< "$LEFTOVER"

      # 削除を反映（ここの失敗は最終検証の [gone] 表示が古くなるだけなので警告に留める）
      if [ "$DRY_RUN" = "1" ]; then
        dry_run_skip "削除反映の git fetch --prune origin"
      else
        git fetch --prune origin 2>&1 || echo "⚠️ 最終 fetch --prune が失敗しました（表示が古い可能性があります）"
      fi
    fi
  fi
fi

# ---- Step 7: 最終検証 ---------------------------------------------------------

echo ""
echo "=== 最終状態 ==="
git branch -vv
echo ""
git worktree list
echo ""
git status

CURRENT_BRANCH="$(git branch --show-current)"
if [ "$CURRENT_BRANCH" != "$PR_BASE" ]; then
  if [ "$DRY_RUN" = "1" ]; then
    echo "ℹ️ dry-run のため ${PR_BASE} への復帰は行っていません: ${CURRENT_BRANCH:-（detached）}"
  elif [ "$NO_SWITCH_MODE" = "1" ]; then
    echo "ℹ️ 呼び出し元のブランチを保持したままです: ${CURRENT_BRANCH:-（detached HEAD）}（switch なし掃除モードのため base への復帰は行っていません）"
  else
    echo "⚠️ 現在のブランチが $PR_BASE ではありません: $CURRENT_BRANCH"
  fi
fi

# upstream の存在を先に判定してから rev-list を無抑制で呼ぶ（エラーの丸め込みを避ける）
if git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
  UPSTREAM_DIFF="$(git rev-list --left-right --count "HEAD...@{u}")"
  if [ "$UPSTREAM_DIFF" != "$(printf '0\t0')" ]; then
    echo "⚠️ $PR_BASE が origin/$PR_BASE に完全追従していません: ahead/behind = $UPSTREAM_DIFF"
  fi
fi

REMAINING_GONE="$(git for-each-ref \
  --format='%(if:equals=[gone])%(upstream:track)%(then)%(refname:short)%(end)' \
  refs/heads/ | grep -v '^$' || true)"
if [ -n "$REMAINING_GONE" ]; then
  echo "⚠️ まだ [gone] ブランチが残っています:"
  printf '%s\n' "$REMAINING_GONE" | sed 's/^/  - /'
fi

# upstream なしの孤児ブランチを警告のみ（削除しない）
ORPHANS="$(git for-each-ref \
  --format='%(if)%(upstream)%(then)%(else)%(refname:short)%(end)' \
  refs/heads/ | grep -v '^$' | grep -vE '^(develop|main|master)$' || true)"
if [ -n "$ORPHANS" ]; then
  echo ""
  echo "ℹ️ upstream なしの孤児ブランチ（中身確認後に手動削除）:"
  printf '%s\n' "$ORPHANS" | sed 's/^/  - /'
fi

# ---- Step 7.5: optional post-merge-cleanup hook -------------------------------

HOOK="$REPO_ROOT/.claude/hooks/post-merge-cleanup.sh"
if [ -f "$HOOK" ] && [ "$DRY_RUN" = "1" ]; then
  echo ""
  dry_run_skip "post-merge-cleanup hook の実行: ${HOOK}"
elif [ -f "$HOOK" ] && [ -x "$HOOK" ]; then
  echo ""
  echo "▶ running $HOOK"
  if ! "$HOOK"; then
    echo "⚠️ post-merge-cleanup hook が失敗しました（cleanup 自体は完了済み）。"
    FAILED_ITEMS+=("post-merge-cleanup hook 失敗")
  fi
elif [ -f "$HOOK" ]; then
  echo "⚠️ $HOOK は実行可能ではありません（chmod +x してください）。スキップします。"
fi

_mc_part_loaded="merge-cleanup-local.sh"
