#!/usr/bin/env bash
#
# review-wrapper-shim suite の検査ファイル（verify.sh から source される。単独実行不可）。
# 範囲: recovery モードフラグ（--all-perspectives / --mode / --resume / --fresh）とヘルプ掲載、staged 経路の diff 歯止め。
# 依存: run_shim / argv_has*。
# source 順は verify.sh の一覧が正本。fixture・関数・変数は同一プロセスで共有され、
# 後続ファイルは先行ファイルが作った fixture を参照するので、順序を入れ替えない。

# ── recovery モードフラグ（`Issue #970`） ──────────────────────────────────────
# multi-agent.sh が Critical state からの復旧として案内する経路を、シム経由の
# 1 コマンドで実行できること。復旧の実体は「観点フィルタ無しの unfiltered full
# review」なので、--all-perspectives は委譲 argv へ観点フィルタが 1 つも
# 載らないことの保証として写る（verbatim 転送だと委譲先の Unknown option で落ちる）。
run_shim --base develop --all-perspectives
if [ "$RUN_RC" -eq 0 ] && argv_has_seq "--task" "review" \
   && ! argv_has "--perspective" && ! argv_has "--exclude-perspective" \
   && ! argv_has "--mode" \
   && ! argv_has "--all-perspectives"; then
  ok "--all-perspectives が観点フィルタ無しの full review として委譲される"
else
  bad "--all-perspectives が受理されない、または観点フィルタ／未知フラグが委譲された (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/out.log" >&2
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi

# 絞る指定との併用は矛盾なので委譲前に拒否する。黙ってどちらかを勝たせると、
# 「復旧が始まらない」か「指定した観点で走らない」が無言で起きる。拒否は
# 何を直せばよいかまで案内する（無言の exit 2 にしない）。
run_shim --base develop --all-perspectives --reviewers code-review
if [ "$RUN_RC" -eq 2 ] && [ ! -s "$WORK/argv.log" ] \
   && grep -q -- '--all-perspectives は --reviewers / --exclude-reviewers と同時に指定できません' "$WORK/err.log"; then
  ok "--all-perspectives と --reviewers の併用を委譲前に診断つきで拒否する"
else
  bad "--all-perspectives と --reviewers の矛盾指定が委譲された、または診断が出ない (rc=$RUN_RC)"
fi
run_shim --base develop --exclude-reviewers comment-analysis --all-perspectives
if [ "$RUN_RC" -eq 2 ] && [ ! -s "$WORK/argv.log" ] \
   && grep -q -- '--all-perspectives は --reviewers / --exclude-reviewers と同時に指定できません' "$WORK/err.log"; then
  ok "--all-perspectives と --exclude-reviewers の併用を委譲前に診断つきで拒否する"
else
  bad "--all-perspectives と --exclude-reviewers の矛盾指定が委譲された、または診断が出ない (rc=$RUN_RC)"
fi

# --mode は委譲先の実在フラグ。設定ファイル由来の mode: cross-model を持つ
# リポジトリでは --all-perspectives だけでは full review にならないため、
# --mode distributed の併用が唯一の上書き経路になる（シム経由で表現できること）。
run_shim --base develop --all-perspectives --mode distributed
if [ "$RUN_RC" -eq 0 ] && argv_has_seq "--mode" "distributed" \
   && ! argv_has "--perspective" && ! argv_has "--exclude-perspective"; then
  ok "--all-perspectives --mode distributed が config 上書きとして委譲される"
else
  bad "--mode distributed がシムに拒否された、または委譲先へ届いていない (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/out.log" >&2
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi

# cross-model は観点を 1 つに絞るモードで、unfiltered full review 判定
# （is_unfiltered_full_review_plan）が明示除外している。--all-perspectives の
# 約束（復旧 = 新 series 開始）と両立しないため委譲前に拒否する。
run_shim --base develop --all-perspectives --mode cross-model
if [ "$RUN_RC" -eq 2 ] && [ ! -s "$WORK/argv.log" ] \
   && grep -q -- '--all-perspectives は --mode cross-model と同時に指定できません' "$WORK/err.log"; then
  ok "--all-perspectives と --mode cross-model の併用を委譲前に診断つきで拒否する"
else
  bad "--all-perspectives と --mode cross-model の矛盾指定が委譲された、または診断が出ない (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/err.log" >&2
fi

# = 形式でも同じに扱う（--base= / --timeout= と同じ GNU 慣用経路）。
run_shim --base develop --mode=distributed
if [ "$RUN_RC" -eq 0 ] && argv_has_seq "--mode" "distributed"; then
  ok "--mode=distributed（= 形式）も委譲先へ届く"
else
  bad "--mode=distributed が委譲先へ届いていない (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi

# env の既定観点が足されると unfiltered full review ではなくなり、復旧（新 series の
# 開始）が黙って始まらない。--reviewers 明示時と同じく、無視 + 1 行通知にする。
run_shim CODEX_DEFAULT_REVIEWERS=code-reviewer --base develop --all-perspectives
if [ "$RUN_RC" -eq 0 ] && ! argv_has "--perspective" \
   && grep -q 'CODEX_DEFAULT_REVIEWERS は無視します' "$WORK/err.log"; then
  ok "--all-perspectives 指定時は CODEX_DEFAULT_REVIEWERS を通知つきで無視する"
else
  bad "--all-perspectives 指定時に env の既定観点が混入、または無視が無通知 (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi

# --resume は失敗・timeout からの復旧経路。委譲先のフラグそのままなので verbatim に届く。
run_shim --resume --base develop
if [ "$RUN_RC" -eq 0 ] && argv_has "--resume" && argv_has_seq "--base" "develop"; then
  ok "--resume が委譲先へ届く"
else
  bad "--resume がシムに拒否された、または委譲先へ届いていない (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/out.log" >&2
fi

# 受け付けるフラグはヘルプにも載っていること（案内→実行が 1 コマンドで閉じる）。
run_shim --help
if grep -q -- '--all-perspectives' "$WORK/out.log" && grep -q -- '--resume' "$WORK/out.log" \
   && grep -q -- '--mode distributed' "$WORK/out.log"; then
  ok "--help が recovery モードフラグ（--all-perspectives / --resume / --mode）を案内する"
else
  bad "--help に recovery モードフラグの案内が無い（--mode distributed の config 上書き案内を含む）"
fi

printf '%s\n' 'PREVIOUS-REVIEW-MARKER' 'gate: unit tests passed' > "$WORK/review-context.txt"
run_shim --review-context-file "$WORK/review-context.txt" --base develop
if [ "$RUN_RC" -eq 0 ] \
   && awk 'prev == "--description" && $0 == "PREVIOUS-REVIEW-MARKER" { marker = 1 }
           marker && $0 == "gate: unit tests passed" { gate = 1 }
           { prev = $0 }
           END { exit(marker && gate ? 0 : 1) }' "$WORK/argv.log"; then
  ok "--review-context-file の内容が --description として委譲される"
else
  bad "--review-context-file の内容が委譲先へ届いていない (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi
: > "$WORK/empty-context.txt"
run_shim --review-context-file "$WORK/empty-context.txt" --base develop
if [ "$RUN_RC" -eq 2 ] && [ ! -s "$WORK/argv.log" ]; then
  ok "空の --review-context-file を委譲前に拒否する"
else
  bad "空の --review-context-file が委譲された (rc=$RUN_RC)"
fi
run_shim --review-context-file "$WORK/missing-context.txt" --base develop
if [ "$RUN_RC" -eq 2 ] && [ ! -s "$WORK/argv.log" ]; then
  ok "不在の --review-context-file を委譲前に拒否する"
else
  bad "不在の --review-context-file が委譲された (rc=$RUN_RC)"
fi
run_shim --review-context-file="$WORK/review-context.txt" --base develop
if [ "$RUN_RC" -eq 0 ] && argv_has "PREVIOUS-REVIEW-MARKER"; then
  ok "--review-context-file=<path> 形式も委譲される"
else
  bad "--review-context-file=<path> 形式が委譲されない (rc=$RUN_RC)"
fi
head -c 65536 /dev/zero | tr '\0' x > "$WORK/context-65536.txt"
run_shim --review-context-file "$WORK/context-65536.txt" --base develop
if [ "$RUN_RC" -eq 0 ] && argv_has "--description"; then
  ok "--review-context-file は上限ちょうど 65536 bytes を受理する"
else
  bad "--review-context-file が上限ちょうどを拒否した (rc=$RUN_RC)"
fi
printf x >> "$WORK/context-65536.txt"
run_shim --review-context-file "$WORK/context-65536.txt" --base develop
if [ "$RUN_RC" -eq 2 ] && [ ! -s "$WORK/argv.log" ]; then
  ok "--review-context-file は 65537 bytes を委譲前に拒否する"
else
  bad "--review-context-file が上限超過を委譲した (rc=$RUN_RC)"
fi

run_shim --staged
if [ "$RUN_RC" -eq 0 ] && argv_has "--staged" && ! argv_has "--base"; then
  ok "--staged が base を足さずオーケストレータへ委譲される"
else
  bad "--staged の委譲範囲が不正 (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/argv.log" >&2
fi

run_shim --staged --base develop
if [ "$RUN_RC" -eq 2 ] && [ ! -s "$WORK/argv.log" ]; then
  ok "シムも --staged と --base の同時指定を委譲前に拒否する"
else
  bad "シムが曖昧な staged/base 指定を委譲した (rc=$RUN_RC)"
fi

STAGED_REPO="$WORK/staged-repo"
ff_git_fixture_init "$STAGED_REPO"
printf 'base\n' > "$STAGED_REPO/app.txt"
git -C "$STAGED_REPO" add app.txt
git -C "$STAGED_REPO" commit -qm init
printf 'staged\n' >> "$STAGED_REPO/app.txt"
git -C "$STAGED_REPO" add app.txt
RUN_SHIM_CWD="$STAGED_REPO" run_shim CODEX_REVIEW_MIN_LINES=999 --staged --dry-run
if [ "$RUN_RC" -eq 0 ] && [ ! -s "$WORK/argv.log" ] \
   && grep -q 'CODEX_REVIEW_MIN_LINES=999 未満' "$WORK/out.log"; then
  ok "staged 指定時の diff サイズ歯止めも index だけを測って skip する"
else
  bad "staged diff のサイズ歯止めが委譲範囲と一致しない (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/out.log" >&2
fi

