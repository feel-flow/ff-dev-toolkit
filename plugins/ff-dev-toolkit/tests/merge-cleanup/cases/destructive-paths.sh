# shellcheck shell=bash
# pipefail-inherited: verify.sh が set -euo pipefail の下で source する
# 破壊的経路: 対象 PR・取り残し・保護・lease の検査（項目 1〜6.x）
#
# verify.sh から source される（ok / bad / TMP / TARGET / MOCK / PLUGIN_ROOT / SCRIPT_DIR を共有）。
# 読む順序は verify.sh の一覧が正本で、前の cases の fixture と関数を後ろの cases が使う（Issue `#2697`）。

# ---- 実行 ----------------------------------------------------------------------

echo "== merge-cleanup 破壊的経路テスト =="

remote_has() { git ls-remote --heads origin "refs/heads/$1" | grep . >/dev/null; }

# simple-git-hooks 相当の pre-push: SKIP_SIMPLE_GIT_HOOKS=1 のときだけ通す。
# fixture 組み立て（setup 中の git push --delete）が終わったあとで入れる。
# worktree からもメイン .git/hooks を共有するので、呼び出し元 worktree でも効く。
git branch -q 'feature/#31-hook-probe' develop
git push -q origin 'feature/#31-hook-probe'
# 相対パスだと呼び出し元 worktree へ移ったあと -x 判定が外れる
HOOK_PATH="$TMP/work/.git/hooks/pre-push"
HOOK_LOG="$TMP/pre-push-hook.log"
: > "$HOOK_LOG"
# husky の consumer も同じ hook で模す: husky v9 の runner（`.husky/_/h`）は
# `[ "\${HUSKY-}" = "0" ] && exit 0` で本体を呼ばない。その判定と同じ式を通した結果を
# 記録だけする（止めない — fixture 組み立ての push は SKIP_SIMPLE_GIT_HOOKS=1 だけで通す）。
cat > "$HOOK_PATH" <<HOOK
#!/bin/sh
if [ "\${HUSKY-}" = "0" ]; then
  printf 'husky=skip\n' >> "$HOOK_LOG"
else
  printf 'husky=run\n' >> "$HOOK_LOG"
fi
if [ "\${SKIP_SIMPLE_GIT_HOOKS:-}" = "1" ]; then
  printf 'skip=1\n' >> "$HOOK_LOG"
  exit 0
fi
printf 'block\n' >> "$HOOK_LOG"
echo "pre-push gate ran (SKIP_SIMPLE_GIT_HOOKS is not 1)" >&2
exit 1
HOOK
chmod +x "$HOOK_PATH"

set +e
env -u SKIP_SIMPLE_GIT_HOOKS -u HUSKY git push -q origin --delete 'feature/#31-hook-probe' >/dev/null 2>&1
HOOK_BLOCK_RC=$?
set -e
if [ "$HOOK_BLOCK_RC" -ne 0 ] && remote_has 'feature/#31-hook-probe'; then
  ok "fixture hook は SKIP_SIMPLE_GIT_HOOKS 無しの削除 push を拒否する（self-test）"
else
  bad "fixture hook が削除 push を拒否しない — 以降の削除成功はゲート回避の証拠にならない"
fi
# 31b の対照: HUSKY を外した push では、hook の husky 判定が run 側になる（self-test）。
# これが出ないと、31b の husky=skip は「hook が常に skip と書く」だけでも緑になる。
if grep -q '^husky=run$' "$HOOK_LOG"; then
  ok "fixture hook の husky 判定は HUSKY 無しの push を run と記録する（self-test）"
else
  bad "fixture hook の husky 判定が HUSKY 無しの push を run と記録しない — 31b は空振りする"
fi
# 取り残し照合の mock に載せないので Step 6 は触らない。リモートに残してよい。

# main worktree を detached にし、linked worktree が develop を保持する通常モードを再現する。
# ignored file は clean 判定に出ないが、退避のために worktree ごと消してはならない。
CALLER="$(git rev-parse --show-toplevel)"
BASE_OWNER="$TMP/wt-base-owner"
printf '%s\n' '.cleanup-owner-preserved' >> "$CALLER/.git/info/exclude"
git switch -q --detach develop
git worktree add -q "$BASE_OWNER" develop
BASE_OWNER="$(cd "$BASE_OWNER" && pwd -P)"
echo preserve-me > "$BASE_OWNER/.cleanup-owner-preserved"

# linked worktree の BASE_OWNER からも共有 hook が働くことを実測する。
set +e
env -u SKIP_SIMPLE_GIT_HOOKS git -C "$BASE_OWNER" push -q origin --delete 'feature/#31-hook-probe' >/dev/null 2>&1
HOOK_WT_RC=$?
set -e
if [ "$HOOK_WT_RC" -ne 0 ] && remote_has 'feature/#31-hook-probe'; then
  ok "呼び出し元 worktree からも fixture hook が削除 push を拒否する（self-test）"
else
  bad "呼び出し元 worktree で fixture hook が効いていない"
fi
: > "$HOOK_LOG"

# 未マージ PR: 破壊的処理の前に exit 1 で中断し、リモートに手を付けないこと
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 99 > "$TMP/run-99.log" 2>&1
EXIT_99=$?
set -e
if [ "$EXIT_99" -eq 1 ] && remote_has 'feature/#1-merged-exact'; then
  ok "未マージ PR は破壊的処理前に exit 1 で中断"
else
  bad "未マージ PR の中断が期待どおりでない (exit=$EXIT_99)"
fi

# dirty な base 所有 worktree は detach せず、リモート削除前に停止すること
echo work-in-progress > "$BASE_OWNER/base-owner-dirty.txt"
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 11 > "$TMP/run-11.log" 2>&1
EXIT_11=$?
set -e
if [ "$EXIT_11" -eq 1 ] \
  && [ "$(git -C "$BASE_OWNER" branch --show-current)" = "develop" ] \
  && [ -z "$(git branch --show-current)" ] \
  && remote_has 'feature/#10-target' \
  && grep -q "base ブランチの退避と cleanup を中断" "$TMP/run-11.log"; then
  ok "dirty な base 所有 worktree を変更せず、破壊的処理前に exit 1 で中断"
else
  bad "dirty な base 所有 worktree の保護が期待どおりでない (exit=$EXIT_11)"
fi
rm -f "$BASE_OWNER/base-owner-dirty.txt"

set +e
# 呼び出し元の hook 抑止 env を持ち込まない（CI や開発シェルで HUSKY=0 が export されて
# いると、削除 push 側から HUSKY=0 を外しても 31b が緑のまま空振りする）
PATH="$MOCK:$PATH" env -u SKIP_SIMPLE_GIT_HOOKS -u HUSKY bash "$TARGET" 10 > "$TMP/run.log" 2>&1
EXIT_CODE=$?
set -e

# 1. 対象 PR のリモートブランチが削除される
if remote_has 'feature/#10-target'; then
  bad "対象 PR のリモートブランチが削除されていない (feature/#10-target)"
else
  ok "対象 PR のリモートブランチを削除 (feature/#10-target)"
fi

# 2. (名前, OID) 一致の取り残しは削除される
if remote_has 'feature/#1-merged-exact'; then
  bad "OID 一致の取り残しが削除されていない (feature/#1-merged-exact)"
else
  ok "OID 一致の取り残しを削除 (feature/#1-merged-exact)"
fi

# 31. hook が実際に走り、SKIP_SIMPLE_GIT_HOOKS=1 を見て skip したことをログで見る。
# --no-verify / hooksPath 無効化だと skip=1 は増えない（hook 自体が起動しない）。
HOOK_SKIPS="$(grep -c '^skip=1$' "$HOOK_LOG" 2>/dev/null || true)"
HOOK_BLOCKS="$(grep -c '^block$' "$HOOK_LOG" 2>/dev/null || true)"
if [ "${HOOK_SKIPS:-0}" -ge 2 ] && [ "${HOOK_BLOCKS:-0}" -eq 0 ]; then
  ok "削除 push で fixture hook が SKIP_SIMPLE_GIT_HOOKS=1 を見て skip した"
else
  bad "fixture hook の skip ログが期待どおりでない (skip=${HOOK_SKIPS:-0} block=${HOOK_BLOCKS:-0})"
fi
# 31b. 同じ削除 push で husky の runner 判定も skip 側へ倒れる（HUSKY=0 が hook まで届く。
# 公開 ff-dev-toolkit#137）。件数を SKIP_SIMPLE_GIT_HOOKS 側と突き合わせ、0 件一致を緑にしない。
HOOK_HUSKY_SKIPS="$(grep -c '^husky=skip$' "$HOOK_LOG" 2>/dev/null || true)"
HOOK_HUSKY_RUNS="$(grep -c '^husky=run$' "$HOOK_LOG" 2>/dev/null || true)"
if [ "${HOOK_HUSKY_SKIPS:-0}" -ge 2 ] && [ "${HOOK_HUSKY_SKIPS:-0}" -eq "${HOOK_SKIPS:-0}" ] \
  && [ "${HOOK_HUSKY_RUNS:-0}" -eq 0 ]; then
  ok "削除 push で fixture hook の husky 判定（HUSKY=0）も skip 側になった"
else
  bad "削除 push の環境に HUSKY=0 が届いていない (husky-skip=${HOOK_HUSKY_SKIPS:-0} husky-run=${HOOK_HUSKY_RUNS:-0} skip=${HOOK_SKIPS:-0})"
fi

# 3. OID 不一致（マージ後 push あり）は削除されない
if remote_has 'feature/#2-reused'; then
  ok "OID 不一致の再利用ブランチを保護 (feature/#2-reused)"
else
  bad "マージ後 push のあるブランチが誤削除された (feature/#2-reused)"
fi

# 6.22 OID 不一致の取り残しは、削除が拒否されるより前に**取り残し候補一覧そのもの
#      から除外される**。
#
#      直前の項目 3（remote_has）だけでは、Step 6 の事前照合を「名前一致のみ」へ
#      退化させても検出できない: 削除 push が --force-with-lease（アンカーは
#      MERGED 一覧側の OID）に拒まれ、結局「削除されない」という同じ観測へ落ちる
#      ためで、二重の防御のうち外側（事前照合）が消えた事実が内側に吸われる。
#      そこで候補一覧を直接読み、事前照合の段階で除外されていることを固定する。
#
#      この退化を赤にできる検査は従来 6.12（Step 4 の失敗中に別 OID へ進んだ
#      ブランチ）だけで、そちらは再試行経路のシナリオに従属している。基本の
#      取り残し経路（本ケース）では lease 拒否に吸収されて緑のままだった。
#      シナリオ従属の検査は差し替えれば消えるため、照合そのものを主題にした
#      検査をここへ独立に置く。
leftover_candidates() {
  # $1: 実行ログ。Step 6 が出す取り残し候補一覧のブランチ名だけを 1 行 1 件で返す。
  # 一覧は見出しの直後に "  - <branch>" が並び、空行で終わる。
  awk '
    /^🧹 リモート取り残しのマージ済みブランチを検出しました:$/ { in_list = 1; next }
    in_list && /^  - / { sub(/^  - /, ""); print; next }
    in_list { exit }
  ' "$1"
}

# 一覧はファイルへ落として grep する。パイプで grep -q へ渡すと、一致で早期終了した
# grep が上流へ SIGPIPE を返し、pipefail 下ではその 141 が条件式の値になって
# 「一致したのに偽」という反転を起こす。
LEFTOVER_CANDIDATES="$TMP/run-leftover-candidates.txt"
leftover_candidates "$TMP/run.log" > "$LEFTOVER_CANDIDATES"

# 先に「一覧を読み出せている」ことを固定する（green pin）。見出しの文言が変わって
# awk が何も拾わなくなると、後続の「載っていない」は空振りで緑になるため。
if grep -qxF 'feature/#1-merged-exact' "$LEFTOVER_CANDIDATES"; then
  ok "取り残し候補一覧を読み出せる（(名前, OID) 一致の feature/#1-merged-exact が載る）"
else
  bad "取り残し候補一覧を読み出せない — 以降の「載っていない」主張は空振りの可能性がある"
  { grep -n 'リモート取り残し' "$TMP/run.log" | tail -5 | sed 's/^/     /' >&2 || true; }
fi

if grep -qxF 'feature/#2-reused' "$LEFTOVER_CANDIDATES"; then
  bad "OID 不一致の再利用ブランチが取り残し候補一覧に載っている（事前照合が名前一致へ退化）"
  { tail -20 "$LEFTOVER_CANDIDATES" | sed 's/^/     /' >&2 || true; }
else
  ok "OID 不一致の再利用ブランチは取り残し候補一覧に載らない (feature/#2-reused)"
fi

# 同じことを削除側からも見る。事前照合で除外されていれば削除は試みられないので、
# lease 拒否のスキップ記録（= 内側の防御が働いた痕跡）もサマリーの列挙も残らない。
# 特定の文言（"lease 拒否): <branch>"）ではなく実行ログ全体での言及 0 件で見るのは、
# 診断文言が変わったときに検査が黙って通る形を避けるため。正しい実行では Step 6 が
# この branch に一切触れないので、この run のログには 1 度も名前が出ない（実測値）。
if grep -qF 'feature/#2-reused' "$TMP/run.log"; then
  bad "OID 不一致の再利用ブランチが Step 6 の処理対象になっている（事前照合を通過している）"
  { grep -n -F 'feature/#2-reused' "$TMP/run.log" | tail -5 | sed 's/^/     /' >&2 || true; }
else
  ok "OID 不一致の再利用ブランチは実行ログに一度も現れない（削除自体を試みていない）"
fi

# 6.23 照合は (名前, OID) の**ペア**で行う。名前の集合と OID の集合を独立に見る形
#      （名前がどれかの head と一致し、かつ OID がどれかの head と一致すれば通す）は、
#      6.22 の入力では区別が付かない — feature/#2-reused の現 OID はどのマージ済み
#      head でもないため、集合独立でも一致しないからだ。区別できるのは、名前と OID を
#      別々の PR から借りられる入力だけ。feature/#47-crosspair は名前が PR A と、
#      現 OID が PR B と一致するが、そのどちらのペアとも一致しない。
#      集合独立の退化では削除まで到達する（lease のアンカーがリモートの現 OID に
#      なるため lease でも止まらない）ので、リモートの残存も併せて固定する。
if grep -qxF 'feature/#47-crosspair' "$LEFTOVER_CANDIDATES"; then
  bad "クロスペアのブランチが取り残し候補一覧に載っている（名前と OID を独立に照合している）"
  { tail -20 "$LEFTOVER_CANDIDATES" | sed 's/^/     /' >&2 || true; }
else
  ok "名前と OID を別 PR から借りたブランチは取り残し候補一覧に載らない (feature/#47-crosspair)"
fi

if grep -qF 'feature/#47-crosspair' "$TMP/run.log"; then
  bad "クロスペアのブランチが Step 6 の処理対象になっている（ペア照合が集合照合へ退化）"
  { grep -n -F 'feature/#47-crosspair' "$TMP/run.log" | tail -5 | sed 's/^/     /' >&2 || true; }
else
  ok "クロスペアのブランチは実行ログに一度も現れない (feature/#47-crosspair)"
fi

if remote_has 'feature/#47-crosspair'; then
  ok "クロスペアのブランチを保護 (feature/#47-crosspair)"
else
  bad "名前と OID が別 PR 由来のブランチが誤削除された (feature/#47-crosspair)"
fi

# 4. open PR の head は削除されない
if remote_has 'feature/#3-open-reuse'; then
  ok "open PR の head を保護 (feature/#3-open-reuse)"
else
  bad "open PR の head が誤削除された (feature/#3-open-reuse)"
fi

# 5. 保護ブランチは削除されない
if remote_has 'release/1.0'; then
  ok "保護ブランチを保護 (release/1.0)"
else
  bad "保護ブランチが誤削除された (release/1.0)"
fi

# 5.5 未マージの固有コミットを持つ [gone] ブランチは -D されない
if git show-ref -q "refs/heads/feature/#5-unmerged"; then
  ok "未マージ [gone] ブランチを保護 (feature/#5-unmerged)"
else
  bad "未マージの固有コミットを持つ [gone] ブランチが誤削除された (feature/#5-unmerged)"
fi

# 6. dirty worktree と対応ブランチが残っている + PARTIAL 終了
if [ -f "$TMP/wt-dirty/wip.txt" ] && git show-ref -q "refs/heads/feature/#10-target"; then
  ok "dirty worktree と対応 [gone] ブランチを保護"
else
  bad "dirty worktree または対応ブランチが失われた"
fi

if [ "$EXIT_CODE" -eq 2 ]; then
  ok "部分失敗（dirty worktree）で終了コード 2 (PARTIAL)"
else
  bad "終了コードが 2 ではない: $EXIT_CODE"
fi

# 6.5 clean な base 所有 worktree は detached へ退避し、呼び出し元が base へ復帰する。
# ignored file と worktree 自体は残す。
if [ "$(git branch --show-current)" = "develop" ] \
  && [ -z "$(git -C "$BASE_OWNER" branch --show-current)" ] \
  && [ -f "$BASE_OWNER/.cleanup-owner-preserved" ] \
  && git worktree list --porcelain | grep -F "worktree $BASE_OWNER" >/dev/null; then
  ok "clean な base 所有 worktree と ignored file を保ち、呼び出し元を develop へ復帰"
else
  bad "clean な base 所有 worktree の退避または呼び出し元の develop 復帰に失敗"
fi

# push の呼び出し記録（mock git）が実際に効いていることの self-test。run 10 は対象 PR の
# head を削除 push で消しているので、記録に 1 行以上あるはず。0 件だと 6.6b / 6.6c の
# 「push しなかった」は記録が空なだけの空振りになる。
# awk で数える（grep -c は 0 件一致で非 0 終了し、set -e 下の代入で suite ごと落ちる）。
# 記録が読めないときに 0 を返さない — 「push しなかった」の緑へ倒れるため。awk の失敗は
# 空文字になり、呼び出し側の数値比較がエラーで偽になる（= bad）。
push_calls_for() {
  # $1: ブランチ名 / $2: 何行目より後を見るか（0 = 全体）
  awk -v ref="refs/heads/$1" -v from="$2" \
    'NR > from && index($0, ref) { n++ } END { print n + 0 }' "$TMP/git-push-calls.log"
}
push_calls_lines() { awk 'END { print NR + 0 }' "$TMP/git-push-calls.log"; }
if [ "$(push_calls_for 'feature/#10-target' 0)" -ge 1 ]; then
  ok "mock git の push 呼び出し記録が効いている（run 10 の削除 push が載る。self-test）"
else
  bad "mock git の push 呼び出し記録が空 — 6.6b / 6.6c の「push しない」は空振りになる"
fi

# 6.6 リモート ref が既に無い場合、`stale info` を lease 拒否と誤表示しない。
PUSH_LINES_BEFORE_12="$(push_calls_lines)"
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-12.log" 2>&1
EXIT_12=$?
set -e
if [ "$EXIT_12" -eq 2 ] \
  && grep -q "リモートブランチは既に削除されていました" "$TMP/run-12.log" \
  && ! grep -q "マージ後に更新されています" "$TMP/run-12.log"; then
  ok "削除済みリモート branch を already removed と判定"
else
  bad "削除済みリモート branch の判定が期待どおりでない (exit=$EXIT_12)"
fi

# 6.6b 本番実行でも、消えた ref へは削除 push 自体を行わない（公開 ff-dev-toolkit#137）。
#      消えた ref への削除 push も pre-push hook を起動し、空の stdin のため consumer の
#      「削除だけならスキップ」判定が効かずフルゲートが走る。文言ではなく push の
#      呼び出し記録で見る（照合を外して push → stale info → 再取得に戻しても、
#      サマリーは同じ already_missing になり文言では区別できない）。
if [ "$(push_calls_for 'feature/#12-already-removed' "$PUSH_LINES_BEFORE_12")" -eq 0 ] \
  && grep -q "削除前の照合（git ls-remote）: origin に feature/#12-already-removed が無いため、削除 push は行いません" "$TMP/run-12.log" \
  && grep -q "リモートブランチ (feature/#12-already-removed): already_missing" "$TMP/run-12.log"; then
  ok "消えた ref には本番実行でも削除 push を行わず already_missing で終わる"
else
  bad "消えた ref へ削除 push を実行した、または already_missing にならない (push=$(push_calls_for 'feature/#12-already-removed' "$PUSH_LINES_BEFORE_12"))"
fi

# 6.6c 削除前の照合そのものが失敗したら（通信・認証。ls-remote --exit-code が 2 以外の
#      非 0）、ref が無いとも在るとも読まず、削除 push をせずに失敗として記録する
#      （fail-closed。dry-run の error と同じ判定）。
: > "$TMP/precheck-fail.enabled"
PUSH_LINES_BEFORE_12C="$(push_calls_lines)"
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 12 > "$TMP/run-12c.log" 2>&1
EXIT_12C=$?
set -e
rm -f "$TMP/precheck-fail.enabled"
if [ "$EXIT_12C" -eq 2 ] \
  && [ "$(push_calls_for 'feature/#12-already-removed' "$PUSH_LINES_BEFORE_12C")" -eq 0 ] \
  && grep -q "削除前の照合（git ls-remote --exit-code）に失敗したため、削除 push は行っていません" "$TMP/run-12c.log" \
  && grep -q "simulated pre-check failure" "$TMP/run-12c.log" \
  && grep -q "feature/#12-already-removed: リモート削除失敗" "$TMP/run-12c.log" \
  && grep -q "リモートブランチ (feature/#12-already-removed): failed" "$TMP/run-12c.log" \
  && ! grep -q "リモートブランチは既に削除されていました" "$TMP/run-12c.log"; then
  ok "削除前の照合が失敗したら push せず、消えたと推測せずに失敗として記録する（fail-closed）"
else
  bad "削除前の照合失敗の扱いが期待どおりでない (exit=$EXIT_12C push=$(push_calls_for 'feature/#12-already-removed' "$PUSH_LINES_BEFORE_12C"))"
fi

# 6.7 ref が別 OID で存在する真の競合は、従来どおり lease 拒否で保護する。
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 13 > "$TMP/run-13.log" 2>&1
EXIT_13=$?
set -e
if [ "$EXIT_13" -eq 2 ] \
  && remote_has 'feature/#2-reused' \
  && grep -q "マージ後に更新されています" "$TMP/run-13.log"; then
  ok "別 OID で存在するリモート branch を lease 拒否として保護"
else
  bad "別 OID リモート branch の lease 保護が期待どおりでない (exit=$EXIT_13)"
fi

# 6.8 ref 再取得が失敗した場合は「削除済み」と推測しない。削除はしないが、
#     Step 6 の取り残し掃除と同じく「失敗として記録して続行」に揃える（PARTIAL）。
# 後続 Step が「見出しに到達した」だけでなく実際に仕事をしたことを見るため、
# この run で消えるはずの [gone] ローカルブランチを仕込む（develop 相当なので
# 完全マージ済み = Step 5 の通常削除の対象）。
git branch 'feature/#19-gone-after-fail' develop
SKIP_SIMPLE_GIT_HOOKS=1 git push -qu origin 'feature/#19-gone-after-fail'
SKIP_SIMPLE_GIT_HOOKS=1 git push -q origin --delete 'feature/#19-gone-after-fail'
# Step 6 が削除に成功する取り残しも同時に置く（対象 PR 以外の成功の影響を見る）
SKIP_SIMPLE_GIT_HOOKS=1 git push -q origin "$OID_LEFTOVER23:refs/heads/feature/#23-leftover-for-14"
# 対象 PR の head を期待 OID で origin に置く。削除前の照合は match になり、mock の
# push が stale info を返して再取得へ落ちる（照合と push の間の競合）。ref が無いままだと
# 照合が missing で短絡し、再取得の経路を 1 度も通らない（公開 ff-dev-toolkit#137 以後）。
SKIP_SIMPLE_GIT_HOOKS=1 git push -q origin "$OID_TARGET:refs/heads/feature/#14-recheck-fails"
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 14 > "$TMP/run-14.log" 2>&1
EXIT_14=$?
set -e
if [ "$EXIT_14" -eq 2 ] \
  && grep -q "remote re-check failed" "$TMP/run-14.log" \
  && grep -q "simulated remote re-check failure" "$TMP/run-14.log" \
  && grep -q "feature/#14-recheck-fails: リモート削除失敗" "$TMP/run-14.log" \
  && grep -q "結果: PARTIAL" "$TMP/run-14.log" \
  && remote_has 'feature/#14-recheck-fails'; then
  ok "lease 拒否後の ref 再取得失敗を失敗として記録し PARTIAL で報告（ref は消していない）"
else
  bad "ref 再取得失敗の報告が期待どおりでない (exit=$EXIT_14)"
fi
# 後続の run が取り残しとして扱わないよう片付ける（MERGED 一覧には載っていない名前）
SKIP_SIMPLE_GIT_HOOKS=1 git push -q origin --delete 'feature/#14-recheck-fails'

# 6.8d 再試行されない対象 PR は failed のまま残る。かつ同じ run で別ブランチの削除が
#      成功しても、対象 PR のサマリー行は書き換わらない（更新条件の 2 つのガード）。
if grep -q "リモートブランチ (feature/#14-recheck-fails): failed" "$TMP/run-14.log" \
  && grep -q "✓ removed: feature/#23-leftover-for-14" "$TMP/run-14.log"; then
  ok "他ブランチの削除成功が対象 PR の failed を書き換えない"
else
  bad "対象 PR のサマリー値が他ブランチの結果に引きずられている"
fi

# 6.8b 上記の失敗で cleanup 全体を落とさない（後続 Step が実行される）。
if grep -q "=== リモート取り残し検証 ===" "$TMP/run-14.log" \
  && grep -q "=== 最終状態 ===" "$TMP/run-14.log"; then
  ok "Step 4 の削除失敗後も Step 6 / Step 7 が実行される"
else
  bad "Step 4 の削除失敗で後続 Step が実行されていない"
fi

# 6.8c 見出しへの到達だけでなく、Step 5 が実際に [gone] ブランチを消したことを見る。
if ! git show-ref --verify --quiet 'refs/heads/feature/#19-gone-after-fail'; then
  ok "Step 4 の削除失敗後も Step 5 が [gone] ローカルブランチを実際に削除する"
else
  bad "Step 4 の削除失敗で [gone] ローカルブランチの削除が行われていない"
fi

# 6.9 ref が期待 OID のまま存在する場合は、競合 push と断定せず原因不明として
#     記録する。削除しない点は従来どおりで、報告だけ PARTIAL 続行へ揃える。
# 続行にしたことで、削除に失敗した対象自身のローカル資産まで掃除してしまわないこと
# を見る。この run はリモート ref が期待 OID のまま残るので [gone] にならない。
git branch 'feature/#15-same-oid' "$OID_SAME" 2>/dev/null || true
git branch --set-upstream-to=origin/'feature/#15-same-oid' 'feature/#15-same-oid' >/dev/null 2>&1
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 15 > "$TMP/run-15.log" 2>&1
EXIT_15=$?
set -e
if [ "$EXIT_15" -eq 2 ] \
  && remote_has 'feature/#15-same-oid' \
  && grep -q "remote re-check returned the expected OID" "$TMP/run-15.log" \
  && grep -q "feature/#15-same-oid: リモート削除失敗" "$TMP/run-15.log" \
  && ! grep -q "マージ後に更新されています" "$TMP/run-15.log"; then
  ok "期待 OID のまま残る ref を原因不明として記録し、削除せず PARTIAL で報告"
else
  bad "期待 OID のまま残る ref の判定が期待どおりでない (exit=$EXIT_15)"
fi

# 6.9b リモート ref が残っている対象のローカルブランチを、続行のついでに消さない。
if git show-ref --verify --quiet 'refs/heads/feature/#15-same-oid'; then
  ok "削除に失敗し ref が残る対象のローカルブランチを掃除しない"
else
  bad "ref が残っているのに対象のローカルブランチが削除された"
fi

# 6.10 stdout が空なら、成功時の stderr 警告を ref 存在と誤読しない。
# 削除前の照合を match で通すため ref を期待 OID で置き、mock の push がそれを消してから
# stale info を返す（照合と push の間に消える競合）。push が実際に呼ばれたことまで見て、
# 照合の missing で短絡した（= 再取得の経路を通っていない）緑を拒む。
SKIP_SIMPLE_GIT_HOOKS=1 git push -q origin "$OID_TARGET:refs/heads/feature/#16-warning-missing"
PUSH_LINES_BEFORE_16="$(push_calls_lines)"
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 16 > "$TMP/run-16.log" 2>&1
EXIT_16=$?
set -e
if [ "$EXIT_16" -eq 2 ] \
  && [ "$(push_calls_for 'feature/#16-warning-missing' "$PUSH_LINES_BEFORE_16")" -ge 1 ] \
  && ! grep -q "削除前の照合（git ls-remote）: origin に feature/#16-warning-missing が無いため" "$TMP/run-16.log" \
  && ! remote_has 'feature/#16-warning-missing' \
  && grep -q "リモートブランチは既に削除されていました" "$TMP/run-16.log" \
  && ! grep -q "マージ後に更新されています" "$TMP/run-16.log"; then
  ok "成功時 stderr 警告を ref 存在と誤読せず already removed と判定"
else
  bad "成功時 stderr 警告の分離が期待どおりでない (exit=$EXIT_16)"
fi

# 6.11 Step 4 が削除に失敗しても、Step 6 の取り残し掃除が同じ branch を再試行する。
#      成功した場合にサマリーが「失敗」のまま残ると実態と食い違うため、結果を更新する。
#      ここで初めて origin へ push する（先行 run が取り残しとして拾わないように）。
# この時点では fixture の pre-push hook が入っているため、削除 push と同じ env を付ける
# 遅延 push が load-bearing（先行 run の取り残し掃除に拾われないため）。
# 既に origin へ出ていたら前提が崩れているので fail-loud にする。
remote_has 'feature/#17-retry-succeeds' && bad "fixture 前提が崩れています（6.11 より前に feature/#17-retry-succeeds が origin へ出ている）"
SKIP_SIMPLE_GIT_HOOKS=1 git push -q origin "$OID_RETRY17:refs/heads/feature/#17-retry-succeeds"
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 17 > "$TMP/run-17.log" 2>&1
EXIT_17=$?
set -e
if [ "$EXIT_17" -eq 2 ] \
  && ! remote_has 'feature/#17-retry-succeeds' \
  && grep -q "deleted_by_leftover_retry" "$TMP/run-17.log" \
  && grep -q "✓ removed: feature/#17-retry-succeeds" "$TMP/run-17.log" \
  && grep -q "feature/#17-retry-succeeds: リモート削除失敗" "$TMP/run-17.log" \
  && ! grep -q "リモートブランチ (feature/#17-retry-succeeds): failed" "$TMP/run-17.log"; then
  ok "Step 6 の再試行で削除できた場合、対象 PR の結果を失敗のまま残さない"
else
  bad "Step 6 再試行後のサマリーが期待どおりでない (exit=$EXIT_17)"
fi

# 6.12 Step 4 の削除が失敗している間にリモートが別 OID へ進んだ場合、Step 6 の
#      再試行は (名前, OID) 照合で弾かれる。更新済みブランチを消してはならない。
# 遅延 push が load-bearing（先行 run の取り残し掃除に拾われないため）。
# 既に origin へ出ていたら前提が崩れているので fail-loud にする。
remote_has 'feature/#18-changed-before-retry' && bad "fixture 前提が崩れています（6.12 より前に feature/#18-changed-before-retry が origin へ出ている）"
SKIP_SIMPLE_GIT_HOOKS=1 git push -q origin "$OID_CHANGED18:refs/heads/feature/#18-changed-before-retry"
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 18 > "$TMP/run-18.log" 2>&1
EXIT_18=$?
set -e
CHANGED18_NOW="$(git ls-remote --heads origin 'refs/heads/feature/#18-changed-before-retry' | awk '{print $1}')"
if [ "$EXIT_18" -eq 2 ] \
  && [ "$CHANGED18_NOW" = "$OID_CHANGED18B" ] \
  && grep -q "feature/#18-changed-before-retry: リモート削除失敗" "$TMP/run-18.log" \
  && ! grep -qE '^  - feature/#18-changed-before-retry$' "$TMP/run-18.log" \
  && ! grep -q "deleted_by_leftover_retry" "$TMP/run-18.log"; then
  ok "Step 4 失敗中に別 OID へ進んだブランチを Step 6 の再試行が削除しない"
else
  bad "別 OID へ進んだブランチの再試行保護が期待どおりでない (exit=$EXIT_18)"
fi

# 6.13 Step 6 の再試行時点で ref が消えていた場合も、サマリーを失敗のまま残さない。
#      削除したのは自分ではないので deleted ではなく already removed として扱う。
# 遅延 push が load-bearing（先行 run の取り残し掃除に拾われないため）。
# 既に origin へ出ていたら前提が崩れているので fail-loud にする。
remote_has 'feature/#20-vanished-before-retry' && bad "fixture 前提が崩れています（6.13 より前に feature/#20-vanished-before-retry が origin へ出ている）"
SKIP_SIMPLE_GIT_HOOKS=1 git push -q origin "$OID_VANISHED20:refs/heads/feature/#20-vanished-before-retry"
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 20 > "$TMP/run-20.log" 2>&1
EXIT_20=$?
set -e
if [ "$EXIT_20" -eq 2 ] \
  && ! remote_has 'feature/#20-vanished-before-retry' \
  && grep -q "already_missing_at_leftover_retry" "$TMP/run-20.log" \
  && grep -q "feature/#20-vanished-before-retry: リモート削除失敗" "$TMP/run-20.log" \
  && ! grep -q "リモートブランチ (feature/#20-vanished-before-retry): failed" "$TMP/run-20.log"; then
  ok "Step 6 の再試行時点で ref が消えていた場合もサマリーを失敗のまま残さない"
else
  bad "ref 消失時の再試行後サマリーが期待どおりでない (exit=$EXIT_20)"
fi

# 6.14 恒久的な失敗（ブランチ保護・権限など）では、対象 PR の head は必ず Step 6 の
#      (名前, OID) 照合に一致して再試行される。同一文言の失敗項目を 2 行並べない。
remote_has 'feature/#22-retry-fails' && bad "fixture 前提が崩れています（6.14 より前に feature/#22-retry-fails が origin へ出ている）"
SKIP_SIMPLE_GIT_HOOKS=1 git push -q origin "$OID_RETRYFAIL22:refs/heads/feature/#22-retry-fails"
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 22 > "$TMP/run-22.log" 2>&1
EXIT_22=$?
set -e
# 失敗項目は Step 4 と Step 6 で 2 行出るのが正しい（実際に 2 回失敗している）。
# 禁じたいのは「バイト単位で同一の行が並ぶ」こと。行数と重複数の両方を見る。
FAIL_LINES_22="$(grep -cE '^  - feature/#22-retry-fails: リモート削除失敗' "$TMP/run-22.log" || true)"
DUP_LINES_22="$(grep -E '^  - feature/#22-retry-fails: リモート削除失敗' "$TMP/run-22.log" \
  | LC_ALL=C sort | LC_ALL=C uniq -d | grep -c . || true)"
if [ "$EXIT_22" -eq 2 ] \
  && remote_has 'feature/#22-retry-fails' \
  && [ "$FAIL_LINES_22" -eq 2 ] \
  && [ "$DUP_LINES_22" -eq 0 ] \
  && grep -q "feature/#22-retry-fails: リモート削除失敗（Step 6 の再試行も失敗" "$TMP/run-22.log" \
  && grep -q "詳細不明" "$TMP/run-22.log"; then
  ok "再試行も失敗した場合に失敗項目を重複させず、原因が空でも詳細不明で埋める"
else
  bad "再試行も失敗した場合の失敗項目が期待どおりでない (exit=$EXIT_22, 行数=$FAIL_LINES_22, 重複=$DUP_LINES_22)"
fi

# 6.15 削除反映の fetch --prune が失敗しても中断しない。ここで die すると、
#      リモート削除の失敗で掃除全体を止めないという契約が 2 行先で破れる。
remote_has 'feature/#21-prune-fails' && bad "fixture 前提が崩れています（6.15 より前に feature/#21-prune-fails が origin へ出ている）"
SKIP_SIMPLE_GIT_HOOKS=1 git push -q origin "$OID_PRUNEFAIL21:refs/heads/feature/#21-prune-fails"
# 見出し到達だけでなく実効を見る。Step 3 の prune の時点で既に [gone] になる
# ローカルブランチを置き、削除反映 prune が飛んでも Step 5 が消すことを確かめる。
git branch 'feature/#24-gone-before-prune' develop
SKIP_SIMPLE_GIT_HOOKS=1 git push -qu origin 'feature/#24-gone-before-prune'
SKIP_SIMPLE_GIT_HOOKS=1 git push -q origin --delete 'feature/#24-gone-before-prune'
: > "$TMP/prune21.enabled"
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 21 > "$TMP/run-21.log" 2>&1
EXIT_21=$?
set -e
rm -f "$TMP/prune21.enabled" "$TMP/prune21.first"
if [ "$EXIT_21" -eq 2 ] \
  && grep -q "=== 最終状態 ===" "$TMP/run-21.log" \
  && grep -q "削除反映の fetch --prune" "$TMP/run-21.log" \
  && grep -qE '^  - .*fetch --prune' "$TMP/run-21.log"; then
  ok "削除反映の fetch --prune 失敗で中断せず、失敗として記録して続行する"
else
  bad "fetch --prune 失敗時の扱いが期待どおりでない (exit=$EXIT_21)"
fi

# 6.15b prune 失敗後も Step 5 が実際に [gone] ブランチを消す（見出し到達だけでなく）。
if ! git show-ref --verify --quiet 'refs/heads/feature/#24-gone-before-prune'; then
  ok "削除反映 prune が失敗しても Step 5 が [gone] ブランチを実際に削除する"
else
  bad "削除反映 prune 失敗後に Step 5 の削除が行われていない"
fi

# 6.16 headRefOid が null で返る PR。lease のアンカーが無いので削除は行わず、
#      「headRefOid を取得できない」ことを名指しする（push のエラーを「権限 /
#      ネットワーク / ブランチ保護ルール」へ誤帰属させない）。Step 6 の取り残し
#      掃除も、一覧側の OID が null なら (名前, OID) 照合に一致せず削除しない。
# 遅延 push が load-bearing（先行 run の取り残し掃除に拾われないため）。
remote_has 'feature/#41-null-oid' && bad "fixture 前提が崩れています（6.16 より前に feature/#41-null-oid が origin へ出ている）"
SKIP_SIMPLE_GIT_HOOKS=1 git push -q origin "$OID_NULLOID41:refs/heads/feature/#41-null-oid"
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 41 > "$TMP/run-41.log" 2>&1
EXIT_41=$?
set -e
NULLOID41_NOW="$(git ls-remote --heads origin 'refs/heads/feature/#41-null-oid' | awk '{print $1}')"
if [ "$EXIT_41" -eq 2 ] \
  && [ "$NULLOID41_NOW" = "$OID_NULLOID41" ] \
  && grep -q "headRefOid を取得できませんでした" "$TMP/run-41.log" \
  && grep -q "リモートブランチ (feature/#41-null-oid): skipped_oid_unavailable" "$TMP/run-41.log" \
  && grep -qE '^  - feature/#41-null-oid: headRefOid を取得できず' "$TMP/run-41.log" \
  && ! grep -q "権限 / ネットワーク / ブランチ保護ルールを確認" "$TMP/run-41.log" \
  && grep -q "=== 最終状態 ===" "$TMP/run-41.log"; then
  ok "headRefOid が null なら削除せず、原因を名指しして PARTIAL で続行する"
else
  bad "headRefOid が null のときの扱いが期待どおりでない (exit=$EXIT_41)"
fi

# 6.17 混在ケース: gh pr view は headRefOid=null だが、取り残し一覧側の OID は正常。
#      Step 6 は照合済み OID をアンカーに実際に削除できるので、サマリーを
#      deleted_by_leftover_retry へ更新し、「リモート削除未実施」の虚偽行を出さない。
#      Step 4 は削除を試みてすらいないため、この経路は失敗として数えない（補足行）。
# 遅延 push が load-bearing（先行 run の取り残し掃除に拾われないため）。
remote_has 'feature/#42-null-oid-mixed' && bad "fixture 前提が崩れています（6.17 より前に feature/#42-null-oid-mixed が origin へ出ている）"
SKIP_SIMPLE_GIT_HOOKS=1 git push -q origin "$OID_NULLOID42:refs/heads/feature/#42-null-oid-mixed"
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 42 > "$TMP/run-42.log" 2>&1
EXIT_42=$?
set -e
# この run には別件（feature/#22-retry-fails の恒久的な削除失敗）が必ず混ざるため
# 終了コードは 2 になる。見たいのは「`#42` が失敗として数えられていないこと」なので、
# 全体の PARTIAL ではなく `#42` の行だけを見る。
if ! remote_has 'feature/#42-null-oid-mixed' \
  && grep -q "✓ removed: feature/#42-null-oid-mixed" "$TMP/run-42.log" \
  && grep -q "リモートブランチ (feature/#42-null-oid-mixed): deleted_by_leftover_retry" "$TMP/run-42.log" \
  && grep -q "補足（手当て不要）" "$TMP/run-42.log" \
  && grep -qE '^  - feature/#42-null-oid-mixed: headRefOid は gh pr view から取得できなかったが、取り残し検証の \(名前, OID\) 照合で削除済み' "$TMP/run-42.log" \
  && ! grep -q "feature/#42-null-oid-mixed: headRefOid を取得できずリモート削除未実施" "$TMP/run-42.log" \
  && ! grep -qE '^  - feature/#42-null-oid-mixed: リモート削除' "$TMP/run-42.log"; then
  ok "headRefOid が view だけ null の混在ケースは Step 6 が削除し、失敗行を残さない"
else
  bad "混在ケース（view=null / list=正常 OID）の扱いが期待どおりでない (exit=$EXIT_42)"
fi

# 6.18 混在ケースで Step 6 の削除が lease 拒否になった場合。削除しないのは
#      「マージ後 push があったので保護した」という正常系（Step 4 の
#      skipped_lease_rejected と同格）なので、失敗として数えない。
# 遅延 push が load-bearing（先行 run の取り残し掃除に拾われないため）。
remote_has 'feature/#43-null-oid-lease' && bad "fixture 前提が崩れています（6.18 より前に feature/#43-null-oid-lease が origin へ出ている）"
SKIP_SIMPLE_GIT_HOOKS=1 git push -q origin "$OID_NULLOID43:refs/heads/feature/#43-null-oid-lease"
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 43 > "$TMP/run-43.log" 2>&1
EXIT_43=$?
set -e
NULLOID43_NOW="$(git ls-remote --heads origin 'refs/heads/feature/#43-null-oid-lease' | awk '{print $1}')"
if [ "$NULLOID43_NOW" = "$OID_NULLOID43B" ] \
  && grep -q "skip (照合後に push あり・lease 拒否): feature/#43-null-oid-lease" "$TMP/run-43.log" \
  && grep -q "リモートブランチ (feature/#43-null-oid-lease): skipped_lease_rejected_at_leftover_retry" "$TMP/run-43.log" \
  && grep -qE '^  - feature/#43-null-oid-lease: 照合後に push あり' "$TMP/run-43.log" \
  && ! grep -q "feature/#43-null-oid-lease: headRefOid を取得できずリモート削除未実施" "$TMP/run-43.log" \
  && ! grep -qE '^  - feature/#43-null-oid-lease: リモート削除' "$TMP/run-43.log"; then
  ok "混在ケースの lease 拒否は保護として扱い、削除未実施の失敗行を残さない"
else
  bad "混在ケースの lease 拒否の扱いが期待どおりでない (exit=$EXIT_43)"
fi

# 6.19 混在ケースで Step 6 の削除が一般エラーで失敗した場合。Step 4 は削除を試みて
#      いないので「未実施」と「削除失敗」を 2 行並べず、1 行に束ねる。
# 遅延 push が load-bearing（先行 run の取り残し掃除に拾われないため）。
remote_has 'feature/#44-null-oid-failure' && bad "fixture 前提が崩れています（6.19 より前に feature/#44-null-oid-failure が origin へ出ている）"
SKIP_SIMPLE_GIT_HOOKS=1 git push -q origin "$OID_NULLOID44:refs/heads/feature/#44-null-oid-failure"
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 44 > "$TMP/run-44.log" 2>&1
EXIT_44=$?
set -e
FAIL_LINES_44="$(grep -cE '^  - feature/#44-null-oid-failure:' "$TMP/run-44.log" || true)"
if [ "$EXIT_44" -eq 2 ] \
  && remote_has 'feature/#44-null-oid-failure' \
  && [ "$FAIL_LINES_44" -eq 1 ] \
  && grep -q "feature/#44-null-oid-failure: リモート削除失敗（headRefOid が無く Step 4 はスキップ" "$TMP/run-44.log" \
  && grep -q -- "--force-with-lease=refs/heads/feature/#44-null-oid-failure:$OID_NULLOID44" "$TMP/run-44.log" \
  && ! grep -q "feature/#44-null-oid-failure: headRefOid を取得できずリモート削除未実施" "$TMP/run-44.log"; then
  ok "混在ケースの一般エラーは 1 行に束ね、二重計上せず ref を残す"
else
  bad "混在ケースの一般エラーの扱いが期待どおりでない (exit=$EXIT_44, 行数=$FAIL_LINES_44)"
fi

# 6.20 混在ケースで、Step 6 の削除 push の時点には ref が消えていた場合。
#      消したのは自分ではないので already 扱いにし、失敗としては数えない。
remote_has 'feature/#45-null-oid-vanished' && bad "fixture 前提が崩れています（6.20 より前に feature/#45-null-oid-vanished が origin へ出ている）"
SKIP_SIMPLE_GIT_HOOKS=1 git push -q origin "$OID_NULLOID45:refs/heads/feature/#45-null-oid-vanished"
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 45 > "$TMP/run-45.log" 2>&1
EXIT_45=$?
set -e
if ! remote_has 'feature/#45-null-oid-vanished' \
  && grep -q "already removed: feature/#45-null-oid-vanished" "$TMP/run-45.log" \
  && grep -q "リモートブランチ (feature/#45-null-oid-vanished): already_missing_at_leftover_retry" "$TMP/run-45.log" \
  && grep -qE '^  - feature/#45-null-oid-vanished: headRefOid は gh pr view から取得できなかったが、取り残し検証の時点で既に削除済み' "$TMP/run-45.log" \
  && ! grep -qE '^  - feature/#45-null-oid-vanished: (headRefOid を取得できず|リモート削除失敗)' "$TMP/run-45.log"; then
  ok "混在ケースで再試行時点に ref が消えていたら already 扱いにし、失敗に数えない"
else
  bad "混在ケースの ref 消失時の扱いが期待どおりでない (exit=$EXIT_45)"
fi

# 6.21 headRefOid が null で、origin にも ref が無い場合。削除すべきものが無いので
#      失敗として積まない（積むと何度実行しても解消しない PARTIAL になる）。
remote_has 'feature/#46-null-oid-gone' && bad "fixture 前提が崩れています（6.21 の対象が origin へ出ている）"
set +e
PATH="$MOCK:$PATH" bash "$TARGET" 46 > "$TMP/run-46.log" 2>&1
EXIT_46=$?
set -e
if grep -q "リモートブランチ (feature/#46-null-oid-gone): already_missing" "$TMP/run-46.log" \
  && grep -q "origin に feature/#46-null-oid-gone は既にありません" "$TMP/run-46.log" \
  && grep -qE '^  - feature/#46-null-oid-gone: headRefOid は gh pr view から取得できなかったが、origin 上の ref は既に存在しない' "$TMP/run-46.log" \
  && ! grep -q "feature/#46-null-oid-gone: headRefOid を取得できずリモート削除未実施" "$TMP/run-46.log" \
  && ! grep -qE '^  - feature/#46-null-oid-gone:.*リモート削除未実施' "$TMP/run-46.log"; then
  ok "headRefOid が null でも ref が既に無ければ already_missing とし、失敗に数えない"
else
  bad "ref 不在時の headRefOid 欠落の扱いが期待どおりでない (exit=$EXIT_46)"
fi

# 7. サマリーに失敗項目が列挙されている（状態がサマリーまで届く）
if grep -q "worktree に未コミット変更あり" "$TMP/run.log"; then
  ok "失敗項目がサマリーに列挙される"
else
  bad "失敗項目がサマリーに出ていない"
fi

# suite-cases-end: destructive-paths.sh
