#!/usr/bin/env bash
#
# merge-cleanup.sh — PR マージ後のクリーンアップ一括実行
#
# 使い方: merge-cleanup.sh <PR番号>
#
# やること:
#   1. 未コミット変更ガード（あれば中断）
#   2. 対象 PR の情報取得（MERGED でなければ破壊的処理の前に中断）
#   3. base ブランチへ復帰 + fetch --prune + pull --ff-only
#   3.5 ガード情報の取得（MERGED / open PR 一覧。失敗時は後続の破壊的処理を fail-closed で縮退）
#   4. 対象 PR のリモートブランチ削除（same-repo かつ open PR 未使用、--force-with-lease で OID 一致時のみ）
#   5. [gone] ローカルブランチ + 関連 worktree の削除
#      （dirty worktree は保護。-D は MERGED PR head と OID 一致するブランチのみ）
#   6. リモート取り残しブランチのガード付き自動削除（fail-closed）
#   7. 最終検証と結果サマリー
#
# 終了コード:
#   0 = 完全成功 / 1 = 致命的エラーで中断 / 2 = 完了したが一部失敗・要手動対応あり（PARTIAL）
#
# 安全原則:
#   - 保護ブランチ（develop / main / master / release/* / staging/*）は絶対に削除しない
#   - リモート削除は --force-with-lease=<ref>:<期待OID> で行い、照合と削除の間の
#     push 競合（TOCTOU）をサーバー側で原子的に拒否させる
#   - ローカル [gone] ブランチの -D（強制削除）は (名前, ローカル OID) が
#     MERGED PR の head と一致する場合に限定（[gone] だけではマージ済みの証明にならない）
#   - ガードに必要な情報の取得に失敗したら削除せずスキップ（fail-closed）
#   - dirty な worktree・upstream なしの孤児ブランチは削除しない（警告のみ）

set -Eeuo pipefail

# ---- 共通 -------------------------------------------------------------------

die() {
  echo "❌ $*" >&2
  exit 1
}

is_protected_branch() {
  case "$1" in
    develop|main|master|release/*|staging/*) return 0 ;;
    *) return 1 ;;
  esac
}

# temp はディレクトリ 1 つにまとめ、trap で確実に回収する
# （コマンド置換内で配列に追記する方式はサブシェルで消えるため使わない）
WORK_TMP="$(mktemp -d)" || die "mktemp -d に失敗しました"
trap 'rm -rf "$WORK_TMP"' EXIT

command -v gh >/dev/null 2>&1 || die "gh CLI が必要です（https://cli.github.com/）"
command -v jq >/dev/null 2>&1 || die "jq が必要です"

# リモート削除の共通関数: --force-with-lease で「期待 OID のときだけ」削除する。
# 戻り値 0=削除 / 2=既に無い / 3=lease 拒否（競合 push あり） / 1=その他失敗
delete_remote_branch_with_lease() {
  # $1: branch / $2: expected OID
  local branch="$1" expected="$2" out=""
  # エラーメッセージの文言照合があるため LC_ALL=C でロケール固定
  if out="$(LC_ALL=C git push --force-with-lease="refs/heads/$branch:$expected" \
      origin ":refs/heads/$branch" 2>&1)"; then
    return 0
  fi
  if printf '%s' "$out" | grep -qE 'remote ref does not exist'; then
    return 2
  fi
  if printf '%s' "$out" | grep -qE 'stale info|\[rejected\]'; then
    echo "$out" > "$WORK_TMP/last_push_error"
    return 3
  fi
  echo "$out" > "$WORK_TMP/last_push_error"
  return 1
}

# ---- Step 0: 引数 -----------------------------------------------------------

PR_NUM="${1:-}"
if [ -z "$PR_NUM" ] || ! [[ "$PR_NUM" =~ ^[0-9]+$ ]]; then
  echo "❌ PR 番号を指定してください（例: merge-cleanup.sh 1234）" >&2
  echo "   PR 番号無しだと delete_branch_on_merge=false な repo でリモートブランチが残ります。" >&2
  exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel)" || die "git リポジトリ内で実行してください"

# 集計用（bash 3.2 の set -u では空配列の "${arr[@]}" 展開がエラーになるため、
# 参照時は必ず ${#arr[@]} でガードする）
DELETED_BRANCHES=()
DELETED_WORKTREES=()
DELETED_LEFTOVERS=()
SKIPPED_LEFTOVERS=()
FAILED_ITEMS=()

# ---- Step 1: 未コミット変更ガード -------------------------------------------

if [ -n "$(git status --porcelain)" ]; then
  echo "❌ 未コミットの変更があります。cleanup を中断します。"
  git status --short
  echo ""
  echo "対応方針（ユーザーが分類して判断）:"
  echo "  1. 作業ブランチで commit し損ねた変更 → 元ブランチに戻して commit / 別 PR 化"
  echo "  2. ツール / 設定（.claude/, scripts/ 等） → chore PR or .gitignore 追記"
  echo "  3. ビルド成果物（dist/, .next/, target/, node_modules/） → .gitignore 追記提案"
  echo "勝手に git restore / git clean は実行しません。"
  exit 1
fi

# ---- Step 1.5: optional pre-merge-cleanup hook -------------------------------

HOOK="$REPO_ROOT/.claude/hooks/pre-merge-cleanup.sh"
if [ -f "$HOOK" ]; then
  if [ -x "$HOOK" ]; then
    echo "▶ running $HOOK"
    "$HOOK" || die "pre-merge-cleanup hook が失敗しました。cleanup を中断します。"
  else
    echo "⚠️ $HOOK は実行可能ではありません（chmod +x してください）。スキップします。"
  fi
fi

# ---- Step 2: 対象 PR の情報取得（MERGED でなければここで中断） -----------------

GH_OUT=""
GH_OUT="$(gh pr view "$PR_NUM" --json headRefName,headRefOid,state,baseRefName,title,isCrossRepository 2>&1)" \
  || die "gh pr view が失敗しました: $GH_OUT（ネットワーク / 認証 / gh CLI 設定を確認してください）"

PR_STATE="$(printf '%s' "$GH_OUT" | jq -r '.state')"
PR_HEAD="$(printf '%s' "$GH_OUT" | jq -r '.headRefName')"
PR_HEAD_OID="$(printf '%s' "$GH_OUT" | jq -r '.headRefOid')"
PR_BASE="$(printf '%s' "$GH_OUT" | jq -r '.baseRefName')"
PR_TITLE="$(printf '%s' "$GH_OUT" | jq -r '.title')"
PR_CROSS_REPO="$(printf '%s' "$GH_OUT" | jq -r '.isCrossRepository')"

[ -n "$PR_HEAD" ] && [ "$PR_HEAD" != "null" ] || die "PR #$PR_NUM の headRefName が取得できません: $GH_OUT"
[ -n "$PR_BASE" ] && [ "$PR_BASE" != "null" ] || die "PR #$PR_NUM の baseRefName が取得できません: $GH_OUT"

if [ "$PR_STATE" != "MERGED" ]; then
  die "PR #$PR_NUM は $PR_STATE 状態です（MERGED ではない）。番号の誤りの可能性があるため、破壊的処理に入る前に中断します。"
fi

if is_protected_branch "$PR_HEAD"; then
  die "PR #$PR_NUM のヘッドブランチが保護対象です ($PR_HEAD)。誤操作防止のため中断します。"
fi

# ---- Step 3: base ブランチ復帰 + 最新化（prune 必須） -------------------------

# リモートブランチ削除より先に base を最新化すること。pre-push hook（simple-git-hooks 等）
# は ref 削除 push にも実行されるため、base が古いまま削除 push すると hook の lint が
# 古い内容で fail して cleanup が中断することがある。
# --prune が無いとリモート削除済みブランチに [gone] マーカーが付かず Step 5 で検出できない。

git switch "$PR_BASE" 2>&1 \
  || die "$PR_BASE への切り替えに失敗しました。他 worktree で使用中、または不存在の可能性があります（'git worktree list' / 'git branch -a' を確認）。"

git fetch --prune origin 2>&1 \
  || die "git fetch --prune が失敗しました。ネットワーク / 認証を確認してください。"

git pull --ff-only origin "$PR_BASE" 2>&1 \
  || die "git pull --ff-only が失敗しました。$PR_BASE がローカルで分岐しています（'git log $PR_BASE..origin/$PR_BASE' 等で確認し手動解消してください）。"

# ---- Step 3.5: ガード情報の取得（Step 4/5/6 で共用、fail-closed） --------------

# MERGED 一覧: -D エスカレーション（Step 5）と取り残し照合（Step 6）の根拠
# open 一覧:   「同じ head を open PR が再利用していないか」ガード（Step 4/6）
GUARDS_OK=1
MERGED_LIST="$WORK_TMP/merged.list"   # "name<TAB>oid"（same-repo PR のみ）
OPEN_LIST="$WORK_TMP/open.list"       # "name"

GH_MERGED_JSON=""
GH_OPEN_JSON=""
if ! GH_MERGED_JSON="$(gh pr list --state merged --limit 1000 --json headRefName,headRefOid,isCrossRepository 2>&1)"; then
  echo "⚠️ マージ済み PR 一覧の取得に失敗しました（fail-closed で縮退）: $GH_MERGED_JSON"
  GUARDS_OK=0
elif ! GH_OPEN_JSON="$(gh pr list --state open --limit 1000 --json headRefName 2>&1)"; then
  echo "⚠️ open PR 一覧の取得に失敗しました（fail-closed で縮退）: $GH_OPEN_JSON"
  GUARDS_OK=0
else
  printf '%s' "$GH_MERGED_JSON" \
    | jq -r '.[] | select(.isCrossRepository | not) | "\(.headRefName)\t\(.headRefOid)"' \
    | sort -u > "$MERGED_LIST"
  printf '%s' "$GH_OPEN_JSON" | jq -r '.[].headRefName' | sort -u > "$OPEN_LIST"
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
else
  echo "🗑️  リモートブランチ削除: $PR_HEAD (PR #$PR_NUM: $PR_TITLE)"
  set +e
  delete_remote_branch_with_lease "$PR_HEAD" "$PR_HEAD_OID"
  rc=$?
  set -e
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
      die "リモートブランチ削除に失敗しました: $(cat "$WORK_TMP/last_push_error" 2>/dev/null || echo '詳細不明')（権限 / ネットワーク / ブランチ保護ルールを確認）"
      ;;
  esac
fi

# 削除を反映して [gone] マーカーを付ける
git fetch --prune origin 2>&1 || die "git fetch --prune（削除反映）が失敗しました。"

# ---- Step 5: [gone] ブランチ + 関連 worktree の削除 ---------------------------

# grep は「マッチ 0 件」で exit 1 を返すが、[gone] ゼロ件は正常系なので || true で許容する
GONE_BRANCHES="$(git for-each-ref \
  --format='%(if:equals=[gone])%(upstream:track)%(then)%(refname:short)%(end)' \
  refs/heads/ | grep -v '^$' || true)"

if [ -z "$GONE_BRANCHES" ]; then
  echo "✅ [gone] ブランチはありません。"
else
  echo "🧹 [gone] ブランチを処理します:"
  printf '%s\n' "$GONE_BRANCHES" | sed 's/^/  - /'

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
    if [ -f "$HOOK" ] && [ -x "$HOOK" ]; then
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
      if [ -n "$WT_STATUS" ]; then
        echo "  ⚠️ worktree に未コミット変更があります。削除をスキップします: $WORKTREE_PATH"
        git -C "$WORKTREE_PATH" status --short | sed 's/^/     /'
        FAILED_ITEMS+=("$branch: worktree に未コミット変更あり ($WORKTREE_PATH)")
        continue
      fi

      echo "  worktree: $WORKTREE_PATH"
      # --force は付けない: 直前の clean 確認の後に変更が入った場合、
      # git 自身が拒否するので TOCTOU の安全網になる。
      # 注意: .gitignore 対象のファイル（.env 等）は clean 扱いのまま削除される。
      # 惜しいファイルを worktree の ignored 領域にだけ置く運用は避けること（コマンド doc にも明記）
      WORKTREE_RM_OUT=""
      if ! WORKTREE_RM_OUT="$(git worktree remove "$WORKTREE_PATH" 2>&1)"; then
        echo "  ❌ worktree 削除に失敗: $WORKTREE_RM_OUT"
        echo "     ブランチ削除もスキップします。手動対応してください。"
        FAILED_ITEMS+=("$branch: worktree 削除失敗 ($WORKTREE_PATH)")
        continue
      fi
      echo "  ✓ worktree removed: $WORKTREE_PATH"
      DELETED_WORKTREES+=("$WORKTREE_PATH")
    fi

    # まず -d（小文字）でマージ済みのみ削除を試す
    BRANCH_DEL_OUT=""
    if BRANCH_DEL_OUT="$(LC_ALL=C git branch -d "$branch" 2>&1)"; then
      echo "  ✓ branch deleted: $branch"
      DELETED_BRANCHES+=("$branch")
    elif printf '%s' "$BRANCH_DEL_OUT" | grep -qE 'not fully merged'; then
      # squash merge 由来は -d で消せない。ただし [gone] は「upstream が消えた」ことしか
      # 保証しないため、-D は (名前, ローカル OID) が MERGED PR の head と一致する
      # ブランチに限定する（手動でリモート削除された未マージ作業を消さないため）
      LOCAL_OID="$(git rev-parse "refs/heads/$branch")"
      if [ "$GUARDS_OK" = "1" ] && grep -qxF "$(printf '%s\t%s' "$branch" "$LOCAL_OID")" "$MERGED_LIST"; then
        if BRANCH_DEL_OUT="$(git branch -D "$branch" 2>&1)"; then
          echo "  ✓ branch deleted (forced, squash merge 済みを OID 照合で確認): $branch"
          DELETED_BRANCHES+=("$branch")
        else
          echo "  ❌ ブランチ削除に失敗: $BRANCH_DEL_OUT"
          FAILED_ITEMS+=("$branch: git branch -D 失敗")
        fi
      else
        echo "  ⚠️ $branch はマージ済み PR の head と OID 一致しません（未マージの固有コミットの可能性）。"
        echo "     削除をスキップします。内容確認のうえ手動で 'git branch -D $branch' してください。"
        FAILED_ITEMS+=("$branch: [gone] だが MERGED PR と OID 不一致（要手動確認）")
      fi
    else
      echo "  ❌ ブランチ削除に失敗: $BRANCH_DEL_OUT"
      FAILED_ITEMS+=("$branch: git branch -d 失敗")
    fi
  done <<< "$GONE_BRANCHES"
fi

# ---- Step 6: リモート取り残しのガード付き自動削除（fail-closed） ---------------

# delete_branch_on_merge=false の repo では UI 経由マージや cleanup スキップで
# マージ済みリモートブランチが累積する。以下の全ガードを通過したものだけ自動削除する:
#   1. (名前, OID) が MERGED 済み PR の head と完全一致（名前再利用・マージ後 push を除外）
#   2. fork PR 由来でない（origin の同名別ブランチを誤射しない）
#   3. 保護ブランチ名でない
#   4. open PR の head として再利用されていない
# 削除自体も --force-with-lease で「照合した OID のときだけ」実行する（TOCTOU 対策）。
# ガード情報の取得に失敗している場合は Step 6 全体をスキップする（fail-closed）

echo ""
echo "=== リモート取り残し検証 ==="

LEFTOVER_CHECK_DONE=0

if [ "$GUARDS_OK" != "1" ]; then
  echo "⚠️ ガード情報（MERGED / open PR 一覧）が構成できていないため、取り残し検証をスキップします（fail-closed）。"
else
  LS_REMOTE_OUT=""
  if ! LS_REMOTE_OUT="$(git ls-remote --heads origin 2>&1)"; then
    echo "⚠️ git ls-remote に失敗しました。取り残し検証をスキップします（fail-closed）: $LS_REMOTE_OUT"
  else
    LEFTOVER_CHECK_DONE=1

    REMOTE_LIST="$WORK_TMP/remote.list"   # "name<TAB>oid"
    printf '%s\n' "$LS_REMOTE_OUT" \
      | awk -F'\t' '{ sub("refs/heads/", "", $2); print $2 "\t" $1 }' \
      | sort -u > "$REMOTE_LIST"

    # (名前, OID) 完全一致のみ候補にする。OID も控えて lease 付き削除に使う
    LEFTOVER="$(comm -12 "$MERGED_LIST" "$REMOTE_LIST")"

    if [ -z "$LEFTOVER" ]; then
      echo "✅ リモート取り残しなし（直近 1000 件のマージ済み PR と (名前, OID) 照合）"
    else
      echo "🧹 リモート取り残しのマージ済みブランチを検出しました:"
      printf '%s\n' "$LEFTOVER" | cut -f1 | sed 's/^/  - /'
      echo ""

      while IFS="$(printf '\t')" read -r rbranch roid; do
        [ -z "$rbranch" ] && continue

        if is_protected_branch "$rbranch"; then
          echo "  ⚠️ skip (保護ブランチ): $rbranch"
          SKIPPED_LEFTOVERS+=("$rbranch: 保護ブランチ")
          continue
        fi

        if grep -qxF "$rbranch" "$OPEN_LIST"; then
          echo "  ⚠️ skip (open PR で再利用中): $rbranch"
          SKIPPED_LEFTOVERS+=("$rbranch: open PR の head として再利用中")
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
            ;;
          2)
            echo "  ℹ️  already removed: $rbranch"
            ;;
          3)
            echo "  ⚠️ skip (照合後に push あり・lease 拒否): $rbranch"
            SKIPPED_LEFTOVERS+=("$rbranch: 照合後に push あり（lease 拒否）")
            ;;
          *)
            echo "  ❌ 削除失敗: $rbranch — $(cat "$WORK_TMP/last_push_error" 2>/dev/null || echo '詳細不明')"
            FAILED_ITEMS+=("$rbranch: リモート削除失敗")
            ;;
        esac
      done <<< "$LEFTOVER"

      # 削除を反映（ここの失敗は最終検証の [gone] 表示が古くなるだけなので警告に留める）
      git fetch --prune origin 2>&1 || echo "⚠️ 最終 fetch --prune が失敗しました（表示が古い可能性があります）"
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
  echo "⚠️ 現在のブランチが $PR_BASE ではありません: $CURRENT_BRANCH"
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
if [ -f "$HOOK" ] && [ -x "$HOOK" ]; then
  echo ""
  echo "▶ running $HOOK"
  if ! "$HOOK"; then
    echo "⚠️ post-merge-cleanup hook が失敗しました（cleanup 自体は完了済み）。"
    FAILED_ITEMS+=("post-merge-cleanup hook 失敗")
  fi
elif [ -f "$HOOK" ]; then
  echo "⚠️ $HOOK は実行可能ではありません（chmod +x してください）。スキップします。"
fi

# ---- Step 8: 結果サマリー -----------------------------------------------------

echo ""
echo "## マージ後 Cleanup 結果"
echo ""
echo "**対象 PR**: #$PR_NUM"
echo ""
echo "- 対象 PR のリモートブランチ ($PR_HEAD): $PR_REMOTE_RESULT"
echo "- 削除した [gone] ローカルブランチ: ${#DELETED_BRANCHES[@]} 本${DELETED_BRANCHES[*]+ (${DELETED_BRANCHES[*]})}"
echo "- 削除した worktree: ${#DELETED_WORKTREES[@]} 個${DELETED_WORKTREES[*]+ (${DELETED_WORKTREES[*]})}"
if [ "$LEFTOVER_CHECK_DONE" = "1" ]; then
  echo "- 自動削除したリモート取り残し: ${#DELETED_LEFTOVERS[@]} 本${DELETED_LEFTOVERS[*]+ (${DELETED_LEFTOVERS[*]})}"
else
  echo "- リモート取り残し検証: スキップ（ガード情報の取得失敗）"
fi
echo "- 現在のブランチ: $CURRENT_BRANCH"

if [ "${#SKIPPED_LEFTOVERS[@]}" -gt 0 ]; then
  echo ""
  echo "**⚠️ スキップした削除候補**:"
  printf '  - %s\n' "${SKIPPED_LEFTOVERS[@]}"
fi

EXIT_CODE=0
if [ "${#FAILED_ITEMS[@]}" -gt 0 ]; then
  echo ""
  echo "**⚠️ 失敗・要手動対応の項目 — 結果: PARTIAL**:"
  printf '  - %s\n' "${FAILED_ITEMS[@]}"
  EXIT_CODE=2
elif [ "$LEFTOVER_CHECK_DONE" != "1" ]; then
  echo ""
  echo "**⚠️ 取り残し検証が未実施です — 結果: PARTIAL**"
  EXIT_CODE=2
fi

echo ""
echo "次のステップ: /ace-curate $PR_NUM で知見をプレイブックへ反映"
exit "$EXIT_CODE"
