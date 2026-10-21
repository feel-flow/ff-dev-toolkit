#!/usr/bin/env bash
# merge-cleanup.sh の構成ファイル: Step 0.6 から Step 2.7（保護パターン、PR 情報、呼び出し元、pre hook）。
#
# scripts/merge-cleanup.sh が、削除より前（Step 0.5 の直後）に 1 回 source する。
# 読めないときの停止は入口が行う。本文は分割前の連続した行。
# ここへ set / trap / source を足さない（本文中の set +e / set -e は分割前からある）。
# 末尾の _mc_part_loaded の行は読み込み完了の印。bash 3.2 互換。
# pipefail-inherited: merge-cleanup.sh が set -Eeuo pipefail の下で source する

# ---- Step 0.6: 設定可能な保護ブランチパターン（`Issue #1056`） -------------------
#
# release/* は運用によって「長命な統合ブランチ」（保護が正しい）と「リリース単位の
# 作業ブランチ」（マージ後は用済み）に二分する。名前だけで前者と決めつけると、
# 後者の運用ではマージ済み release/* が永久に取り残される。既定は従来どおり
# release/* を保護し（後方互換）、FF_MERGE_CLEANUP_PROTECT_BRANCHES で変更できる:
#
#   FF_MERGE_CLEANUP_PROTECT_BRANCHES='release/*:lts/*'  ← ':' 区切りの glob
#   FF_MERGE_CLEANUP_PROTECT_BRANCHES='none'             ← 追加の保護なし
#
# develop / main / master / staging/* はハードコードのまま（設定でも外せない。
# Step 4 / 5 / 6 すべての最終防壁のため）。空文字列は未設定と同じ（既定を使う）。

PROTECT_EXTRA_PATTERNS=()
PROTECT_RAW="${FF_MERGE_CLEANUP_PROTECT_BRANCHES:-}"
if [ -z "$PROTECT_RAW" ]; then
  PROTECT_EXTRA_PATTERNS=('release/*')
elif [ "$PROTECT_RAW" = "none" ]; then
  : # 追加の保護なし（ハードコード分だけが残る）
else
  PROTECT_REST="${PROTECT_RAW}:"
  while [ -n "$PROTECT_REST" ]; do
    PROTECT_ITEM="${PROTECT_REST%%:*}"
    PROTECT_REST="${PROTECT_REST#*:}"
    if [ -z "$PROTECT_ITEM" ]; then
      # 空パターンを黙って落とすと「書いたのに保護されない」が起き、方向は逆でも
      # IGNORE_PATHS と同じ「指定と実挙動の乖離」なので同じく中断する（fail-closed）
      die "FF_MERGE_CLEANUP_PROTECT_BRANCHES に空のパターンがあります: '${PROTECT_RAW}'（先頭・末尾・連続する ':' を確認。追加の保護を無くす場合は 'none' を指定）"
    fi
    case "$PROTECT_ITEM" in
      [[:space:]]*|*[[:space:]])
        die "FF_MERGE_CLEANUP_PROTECT_BRANCHES のパターンに前後の空白があります: '${PROTECT_ITEM}' — ブランチ名は空白も含めて照合されるため、この指定は意図どおり保護しません"
        ;;
      *\[*|*\]*)
        # release/[[:digit:]]* のような文字クラスは、クラス内の ':' が区切り文字と
        # 衝突して黙って分断される（エラーにならないまま保護が消える fail-open）。
        # 分断後の破片は往々にして「何にも一致しない」正当そうな見た目になるため、
        # 検出できるここで明示的に拒否する。
        die "FF_MERGE_CLEANUP_PROTECT_BRANCHES に文字クラス（[...]）を含むパターンがあります: '${PROTECT_ITEM}' — 文字クラスは ':' 区切りと衝突して黙って分断されるため未対応です。プレフィックス glob（release/* など）を使ってください"
        ;;
    esac
    PROTECT_EXTRA_PATTERNS+=("$PROTECT_ITEM")
  done
fi

# ---- Step 0.7: マージ済み PR 照合上限（`Issue #835`） ---------------------------
#
# Step 5 の -D エスカレーションと Step 6 の取り残し照合が使う MERGED 一覧の
# 取得上限。大きめのリポジトリでは既定の 1000 件でも取得が長引くため設定可能に
# する。既定は従来どおり 1000（後方互換）。不正値は破壊的処理より前に中断する。

MERGED_PR_LIMIT="${FF_MERGE_CLEANUP_MERGED_PR_LIMIT:-1000}"
if ! [[ "$MERGED_PR_LIMIT" =~ ^[1-9][0-9]*$ ]]; then
  die "FF_MERGE_CLEANUP_MERGED_PR_LIMIT は正の整数で指定してください: '${MERGED_PR_LIMIT}'（既定 1000）"
fi

# ---- Step 1: 未コミット変更ガード -------------------------------------------

# git の失敗を「変更なし」と読み替えない。ここが fail-open だと、dirty な作業ツリーで
# ガードが素通りして worktree 削除まで進む。
GUARD_ERR_STEP1="$WORK_TMP/guard_status_error.step1"
DIRTY_STATUS=""
if ! DIRTY_STATUS="$(guarded_status "" 2>"$GUARD_ERR_STEP1")"; then
  die "未コミット変更の確認に失敗しました: $(guard_status_error_text "$GUARD_ERR_STEP1")"
fi

# exit 0 でも stderr に出力があれば、作業ツリーを完全には走査できていない可能性がある
# （`warning: could not open directory …: Permission denied` は、その配下の未追跡
# ファイルを列挙できないまま exit 0 になる）。旧実装では stderr が端末へ直接出ていて
# 少なくとも目に入ったので、判定は変えずに可視性だけ戻す。
DIRTY_STATUS_STDERR="$(guard_status_error_raw "$GUARD_ERR_STEP1")"
if [ -n "$DIRTY_STATUS_STDERR" ]; then
  echo "⚠️ git status が警告を出しました（作業ツリーを完全に走査できていない可能性があります）:"
  printf '%s\n' "$DIRTY_STATUS_STDERR" | sed 's/^/   /'
fi

report_ignored_changes "" ""

# dirty での中断判定は Step 2 の後まで保留する（`Issue #758` / `#749`）。呼び出し元が
# base でも PR head でもないブランチ（= 他セッションの作業ブランチの可能性）を
# 保持している場合、本スクリプトはブランチを一切切り替えないモードで続行するため、
# dirty でも呼び出し元の作業ツリーには触れない。base / PR head を保持している
# 場合は従来どおり中断する。どちらかは PR 情報（base / head 名）が無いと決まらない。
CALLER_DIRTY=0
if [ -n "$DIRTY_STATUS" ]; then
  CALLER_DIRTY=1
fi

# ---- Step 2: 対象 PR の情報取得（MERGED でなければここで中断） -----------------

GH_OUT=""
GH_OUT="$(gh pr view "$PR_NUM" --json headRefName,headRefOid,state,baseRefName,title,isCrossRepository 2>&1)" \
  || die "gh pr view が失敗しました: ${GH_OUT}（ネットワーク / 認証 / gh CLI 設定を確認してください）"

PR_STATE="$(printf '%s' "$GH_OUT" | jq -r '.state')"
PR_HEAD="$(printf '%s' "$GH_OUT" | jq -r '.headRefName')"
PR_HEAD_OID="$(printf '%s' "$GH_OUT" | jq -r '.headRefOid')"
PR_BASE="$(printf '%s' "$GH_OUT" | jq -r '.baseRefName')"
PR_TITLE="$(printf '%s' "$GH_OUT" | jq -r '.title')"
PR_CROSS_REPO="$(printf '%s' "$GH_OUT" | jq -r '.isCrossRepository')"

[ -n "$PR_HEAD" ] && [ "$PR_HEAD" != "null" ] || die "PR #$PR_NUM の headRefName が取得できません: $GH_OUT"
[ -n "$PR_BASE" ] && [ "$PR_BASE" != "null" ] || die "PR #$PR_NUM の baseRefName が取得できません: $GH_OUT"

# headRefOid は Step 4 の --force-with-lease のアンカー。未検証のまま渡すと
# 「権限 / ネットワーク / ブランチ保護ルールを確認」という的外れな案内になる（真因は
# 「照合すべき OID が無い」ことで、どの選択肢にも含まれない）。壊れ方は 2 通りで、
# 実際に来るのは前者だけ:
#   - "null": jq -r が JSON null を文字列化した値。git が object name として解析できず
#     push は `stale info` にも `remote ref does not exist` にもマッチせず rc=1 になる
#   - 空文字列: --force-with-lease=<ref>: は「ref は存在しないはず」という別の意味に
#     なり、lease 拒否（= マージ後 push あり）として誤報される。jq -r が空を返す経路は
#     無いので実質到達不能だが、保険で同じ扱いにする
# ここでは die しない — 名前 / base と違い、これが欠けても止まるのは Step 4 の
# リモート削除だけで、[gone] 掃除・トランスクリプト回収・取り残し検証は成立する。
# Step 4 で `skipped_guard_unavailable` と同じ「ガード情報が構成できない → 削除だけ
# スキップして PARTIAL で続行」へ落とす（判断軸は ACE-166-1）。
PR_HEAD_OID_OK=1
if [ -z "$PR_HEAD_OID" ] || [ "$PR_HEAD_OID" = "null" ]; then
  PR_HEAD_OID_OK=0
fi

if [ "$PR_STATE" != "MERGED" ]; then
  die "PR #$PR_NUM は $PR_STATE 状態です（MERGED ではない）。番号の誤りの可能性があるため、破壊的処理に入る前に中断します。"
fi

if is_protected_branch "$PR_HEAD"; then
  die "PR #$PR_NUM のヘッドブランチが保護対象です ($PR_HEAD)。誤操作防止のため中断します。"
fi

# ---- Step 2.5: 呼び出し元ブランチの判定（switch なし掃除モード。`#758` / `#749`） ---
#
# 呼び出し元が base でも PR head でもない名前付きブランチにいる場合、そのブランチは
# 他セッションの作業ブランチの可能性がある。Step 3 で base へ switch すると他人の
# 作業を勝手に切り替えることになるため、**切り替えを伴わない掃除モード**へ落とす:
#   - base への復帰・pull は行わない（base の最新化は checkout 不要な
#     `git fetch origin <base>:<base>` を試み、拒否されたらスキップして報告）
#   - リモート削除・[gone] 掃除・worktree 削除・取り残し検証は通常どおり実施
#   - 未実施の項目はサマリーで名指しする
# detached HEAD（空文字列）は従来どおり通常モード（switch して base へ復帰する）。

CURRENT_BRANCH_BEFORE="$(git branch --show-current)"
NO_SWITCH_MODE=0
BASE_FF_NOTE=""
if [ -n "$CURRENT_BRANCH_BEFORE" ] \
  && [ "$CURRENT_BRANCH_BEFORE" != "$PR_BASE" ] \
  && [ "$CURRENT_BRANCH_BEFORE" != "$PR_HEAD" ]; then
  NO_SWITCH_MODE=1
fi

# ---- Step 2.6: 対象 PR の worktree を cwd にした起動の検出 --------------------
#
# マージ直後に PR の worktree のまま cleanup を呼ぶ動線がある。この cwd では
# 本スクリプトの主目的が 2 つとも達成できない:
#   - 掃除対象であるこの worktree 自身は、そこに立っている以上 Step 5 で削除できない
#   - base を別の worktree（多くは main tree）が保持していれば、Step 3 が base を
#     取り戻すにはその worktree を detached HEAD へ退避することになる（呼び出し元を
#     優先して他方の checkout を崩す）。base を誰も保持していなければこちらは起きない
#     ので、案内では実際に保持している worktree を見つけたときだけ言及する
# 前者だけでも「気付きにくい未完了」に化けるため、破壊的処理へ入る前に止める。
# 案内は main tree のパスが取れれば再実行コマンド、取れない構成（bare リポジトリ）
# では原因と対処を出す。パスが取れないことを理由に素通しはしない。
#
# 検出は「cwd が linked worktree」かつ「その worktree が対象 PR の head を保持」に
# 限る。linked worktree からの実行そのものは正当な運用で、
#   - base でも PR head でもないブランチ = 切り替えを伴わない掃除モード（下記）
#   - detached / base 保持 = 従来どおり通常モード
# はいずれも完走できる。ここを「linked worktree なら一律中断」へ広げると、
# それらの経路まで巻き添えで止まる。
IN_PR_WORKTREE=0
MAIN_WORKTREE=""
PR_BASE_WORKTREE=""
if [ "$CURRENT_BRANCH_BEFORE" = "$PR_HEAD" ] && is_linked_worktree; then
  IN_PR_WORKTREE=1
  # main tree のパスは「どこでやり直せばよいか」の案内にだけ使う。取れなくても
  # （bare リポジトリの main レコードは cd 先にできない）中断は取り消さない。
  # ここを素通しさせると、下の 2 つの未完了を黙ったまま破壊的処理へ進むことになる。
  MAIN_WORKTREE="$(main_worktree_path || true)"
  PR_BASE_WORKTREE="$(find_worktree_for_branch "$PR_BASE" || true)"
fi
if [ "$IN_PR_WORKTREE" = "1" ]; then
  echo "❌ 対象 PR のワークツリーを cwd にして実行しています: ${REPO_ROOT}"
  echo "   このまま続けると、掃除対象であるこのワークツリー自身は削除できません。"
  if [ -n "$PR_BASE_WORKTREE" ]; then
    echo "   さらに base (${PR_BASE}) を別のワークツリー (${PR_BASE_WORKTREE}) が保持しているため、"
    echo "   base へ復帰するにはそのワークツリーを detached HEAD へ退避することになります。"
  fi
  echo "   破壊的処理の前に中断します（リモートブランチ・ローカルブランチ・worktree は何も削除していません）。"
  echo ""
  if [ -n "$MAIN_WORKTREE" ]; then
    echo "main tree で実行し直してください:"
    # パスに空白等が含まれていてもそのまま貼って実行できるよう %q で引用する。
    printf '  cd %q && bash %q %s\n' "$MAIN_WORKTREE" "$(script_self_path)" "$PR_NUM"
  else
    echo "別のワークツリーで実行し直してください（main tree のパスを特定できませんでした）:"
    echo "  原因: cwd が対象 PR のブランチ (${PR_HEAD}) を保持するリンクされたワークツリーです。"
    echo "  対処: bare リポジトリなど main tree が checkout を持たない構成のため、"
    echo "        'git worktree list' で対象 PR のブランチを保持しない作業ツリーを選び、そこで実行してください。"
  fi
  exit 1
fi

if [ "$CALLER_DIRTY" = "1" ]; then
  if [ "$NO_SWITCH_MODE" = "1" ]; then
    # このモードでは呼び出し元のブランチも作業ツリーも一切触らないため、dirty を
    # 理由に全体を止めない（止めると cleanup の実体を毎回手作業で再現することになる。
    # `#749` の実測）。変更に触れないことと、base 復帰を行わないことだけ明示する。
    echo "⚠️ 未コミットの変更がありますが、呼び出し元は base でも PR head でもない '${CURRENT_BRANCH_BEFORE}' を保持しています。"
    echo "   ブランチ切り替えを伴わない掃除モードで続行します（下の変更には一切触れません）:"
    printf '%s\n' "$DIRTY_STATUS" | sed 's/^/   /'
  else
    echo "❌ 未コミットの変更があります。cleanup を中断します。"
    printf '%s\n' "$DIRTY_STATUS"
    echo ""
    echo "対応方針（ユーザーが分類して判断）:"
    echo "  1. 作業ブランチで commit し損ねた変更 → 元ブランチに戻して commit / 別 PR 化"
    echo "  2. ツール / 設定（.claude/, scripts/ 等） → chore PR or .gitignore 追記"
    echo "  3. ビルド成果物（dist/, .next/, target/, node_modules/） → .gitignore 追記提案"
    echo "勝手に git restore / git clean は実行しません。"
    if [ -z "$IGNORE_RAW" ]; then
      echo "常駐ツールが書き続けるパスなら FF_MERGE_CLEANUP_IGNORE_PATHS で対象外にできます。"
    else
      # 設定済みの利用者に「設定できます」と案内すると、効いていないのかと読める
      echo "現在の FF_MERGE_CLEANUP_IGNORE_PATHS: '${IGNORE_RAW}' — 上の変更はこの指定に一致していません。"
    fi
    exit 1
  fi
fi

# ---- Step 2.7: optional pre-merge-cleanup hook -------------------------------

HOOK="$REPO_ROOT/.claude/hooks/pre-merge-cleanup.sh"
if [ -f "$HOOK" ]; then
  if [ "$DRY_RUN" = "1" ]; then
    # hook は project 固有の破壊的処理（DDEV stop・キャッシュ削除など）の差し込み口で、
    # 何をするかはこちらからは分からない。dry-run では起動しない。
    dry_run_skip "pre-merge-cleanup hook の実行: ${HOOK}"
  elif [ -x "$HOOK" ]; then
    echo "▶ running $HOOK"
    "$HOOK" || die "pre-merge-cleanup hook が失敗しました。cleanup を中断します。"
    if [ "$NO_SWITCH_MODE" = "1" ]; then
      # switch なし掃除モードの契約は「呼び出し元のブランチに触れない」。hook が
      # ブランチを切り替えていたら、この契約を以降のステップで守れないため中断する
      HOOK_BRANCH_NOW="$(git branch --show-current)"
      if [ "$HOOK_BRANCH_NOW" != "$CURRENT_BRANCH_BEFORE" ]; then
        die "pre-merge-cleanup hook が呼び出し元のブランチを '${CURRENT_BRANCH_BEFORE}' から '${HOOK_BRANCH_NOW:-（detached）}' へ切り替えました。switch なし掃除モードの契約（呼び出し元のブランチに触れない）を守れないため中断します。hook を修正するか、base か PR head のブランチから再実行してください。"
      fi
    fi
  else
    echo "⚠️ $HOOK は実行可能ではありません（chmod +x してください）。スキップします。"
  fi
fi

_mc_part_loaded="merge-cleanup-pre.sh"
