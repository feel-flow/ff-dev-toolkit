#!/usr/bin/env bash
# 同期元 SHA の受け渡しを、実 Git fixture で端から端まで実測する（Issue #895）。
#
# 守っている事故: 同期元 SHA をシェル変数で持ち回ると、手順 3（同期）と手順 4
# （commit）がツール呼び出し境界で別プロセスに割れた瞬間に値が消える。しかも
# 同期スクリプトは書き込み先が clean であることを要求するため、「やり直し」の
# 再実行は直前の成功が残した差分に当たって必ず失敗する — 成功が次の試行を塞ぐ。
# 対策は、同期スクリプトが**実際に展開した内容の SHA** を target の git ディレクトリ
# 配下（`ff-sync-src-sha`）へ書き、commit 側がそれを読むこと。
#
# 検査は 2 系統:
#   A. 同期スクリプトの記録契約 — 成功時だけ書く / 40 桁で同期実行開始時の同期元
#      HEAD と一致 / dry-run では書かず既存の記録も壊さない / 書き込み前に必ず消す
#      （中断した同期の記録を残さない）/ **dirty ガードで止まった再実行では消さない**
#      / `--delete` ミラーでも消えない / 公開リポジトリの追跡内容に出ない
#   B. SKILL.md 手順 4 のコードブロックを**そのまま切り出して実行**し、Issue #895 の
#      GWT 3 ケースを固定する — 別プロセスでも commit まで進む / SSOT の HEAD が
#      動いていたら commit しない / 記録が無ければ commit しない
#
# B は手順書の文面ではなく挙動を見る唯一の層なので、切り出しが空振りした場合は
# 「no commit」を期待する 2 ケースが自動的に緑になる。切り出し結果の非空と要の
# 1 行の存在を先に assert して fail-closed にしている。
#
# 外部要件: git / rsync。ネットワークには触らない（push 先はローカル bare）。
# bash 3.2 互換。

set -euo pipefail

SYNC_SCRIPT="${1:-}"
SKILL="${2:-}"
if [[ -z "$SYNC_SCRIPT" || ! -f "$SYNC_SCRIPT" ]]; then
  echo "✗ 同期スクリプトがありません: ${SYNC_SCRIPT:-<未指定>}" >&2
  exit 1
fi
if [[ -z "$SKILL" || ! -f "$SKILL" ]]; then
  echo "✗ SKILL.md がありません: ${SKILL:-<未指定>}" >&2
  exit 1
fi
command -v rsync >/dev/null 2>&1 || { echo "✗ rsync がありません（同期の実挙動を検証できない）" >&2; exit 1; }

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sync-src-sha.XXXXXX")"
cleanup() {
  local rc=$?
  rm -rf "$TMP_DIR"
  exit "$rc"
}
trap cleanup EXIT HUP INT TERM

# 実行者のグローバル / システム git 設定を fixture へ継承させない（commit.gpgsign や
# core.hooksPath が設定された環境で、対象機能と無関係に fixture の commit が落ちるのを防ぐ）。
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

SSOT="$TMP_DIR/ssot"
PUB="$TMP_DIR/public"
BARE="$TMP_DIR/origin.git"
PUBLIC_ORIGIN_URL="https://github.com/feel-flow/ff-dev-toolkit.git"
RECORD="$PUB/.git/ff-sync-src-sha"

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

git_setup() {
  local repo="$1"
  git -C "$repo" config user.name "Sync SHA Test"
  git -C "$repo" config user.email "sync-sha-test@example.invalid"
  git -C "$repo" config commit.gpgsign false
  git -C "$repo" config core.hooksPath /dev/null
}

# ---- fixture SSOT --------------------------------------------------------
mkdir -p "$SSOT/scripts" "$SSOT/plugins/ff-dev-toolkit" "$SSOT/oss/ff-dev-toolkit"
cp "$SYNC_SCRIPT" "$SSOT/scripts/sync-dev-toolkit-to-public.sh"
chmod +x "$SSOT/scripts/sync-dev-toolkit-to-public.sh"
printf 'MIT-ish fixture license\n' > "$SSOT/plugins/ff-dev-toolkit/LICENSE"
printf '# Fixture plugin\n' > "$SSOT/plugins/ff-dev-toolkit/README.md"
printf '# Fixture changelog\n' > "$SSOT/oss/ff-dev-toolkit/CHANGELOG.md"
git -C "$SSOT" init -q
git_setup "$SSOT"
git -C "$SSOT" add -A
git -C "$SSOT" commit -q -m baseline
SYNCED_SHA="$(git -C "$SSOT" rev-parse HEAD)"

# ---- fixture 公開 clone + push 先の bare ----------------------------------
mkdir -p "$PUB"
git -C "$TMP_DIR" init -q --bare "$BARE"
git -C "$PUB" init -q
git -C "$PUB" symbolic-ref HEAD refs/heads/main
git_setup "$PUB"
printf 'seed\n' > "$PUB/seed.txt"
git -C "$PUB" add seed.txt
git -C "$PUB" commit -q -m seed
git -C "$PUB" remote add origin "$PUBLIC_ORIGIN_URL"

run_sync() {
  # 引数はそのまま同期スクリプトへ渡す。stdout/stderr は判定に使う分だけ返す。
  "$SSOT/scripts/sync-dev-toolkit-to-public.sh" --target "$PUB" "$@" 2>&1
}

echo "== 同期元 SHA の記録契約（実 Git fixture） =="

# ---- A1. 同期成功で記録が残り、展開した内容の SHA と一致する ----------------
SYNC_RC=0
SYNC_OUT="$(run_sync)" || SYNC_RC=$?
if [[ "$SYNC_RC" -ne 0 ]]; then
  echo "✗ fixture の同期が失敗しました（rc=${SYNC_RC}）" >&2
  printf '%s\n' "$SYNC_OUT" | sed 's/^/    | /' >&2
  exit 1
fi
if [[ -f "$RECORD" ]]; then
  ok "同期が成功すると target の .git 配下へ同期元 SHA が記録される"
else
  bad "同期が成功しても記録が無い（期待パス: .git/ff-sync-src-sha）"
fi
RECORDED="$(cat "$RECORD" 2>/dev/null || true)"
# 比較相手の SYNCED_SHA は同期を回す前に SSOT で採った HEAD であり、target へ
# 展開された内容そのものではない。ここで見ているのは「記録が同期実行開始時の
# 同期元 HEAD と一致するか」まで（内容一致は静的には観測できないため、記録と
# 展開が同じ SHA を使う構造そのものを verify.sh の順序検査が縛っている）。
if [[ "$RECORDED" == "$SYNCED_SHA" ]]; then
  ok "記録された SHA が、同期実行開始時の同期元 HEAD と一致する（40 桁の完全 SHA）"
else
  bad "記録 SHA が同期実行開始時の同期元 HEAD と一致しない（記録=${RECORDED:-<空>} / 同期元 HEAD=${SYNCED_SHA}）"
fi

# ---- A1b. dirty ガードで止まった再実行は、まだ有効な記録を消さない ----------
# Issue #895 の主たる救済経路そのもの: 手順 3 が成功 → target は同期結果で dirty →
# 手順 4 がツール呼び出し境界で失われる → 手順 3 を素直に再実行 → dirty ガードで
# 停止 → **記録が生きているので手順 4 がそのまま通る**。ここで記録が消えると
# 「記録が無いので手順 3 からやり直す」へ戻り、成功が次の試行を塞ぐ元の詰みが
# そのまま復活する。同期スクリプトの `rm -f` を dirty ガードより前へ動かす変異は、
# 静的針（存在・rsync より前）も他の runtime ケース（すべて clean target 前提）も
# 素通りするため、この 1 ケースだけが検出できる。
RETRY_RC=0
RETRY_OUT="$(run_sync)" || RETRY_RC=$?
RETRY_RECORD="$(cat "$RECORD" 2>/dev/null || true)"
if [[ "$RETRY_RC" -ne 0 ]] \
  && [[ "$RETRY_OUT" == *"未コミットの変更があります"* ]] \
  && [[ "$RETRY_RECORD" == "$SYNCED_SHA" ]]; then
  ok "dirty ガードで止まった再実行は記録を消さない（やり直しの詰みへ戻さない）"
else
  bad "dirty ガードで止まった再実行が記録を壊した（rc=${RETRY_RC} / 記録=${RETRY_RECORD:-<不在>} / 期待=${SYNCED_SHA} / 出力: ${RETRY_OUT}）"
fi
# 判定は上で済んでいる。記録が消されていた場合はここで戻す — 後続ケース（B1 の
# `mv "$RECORD"` など）が記録の存在を前提にしており、戻さないと set -e で fixture
# ごと落ちて「以降のケースが 1 件も走らないまま赤」になる。それでも fail-closed
# ではあるが、どのケースが効いたのかが読めず変異の検出範囲を実測できない。
[[ -f "$RECORD" ]] || printf '%s\n' "$SYNCED_SHA" > "$RECORD"

# ---- B. SKILL.md 手順 4 のコードブロックを切り出して実行 --------------------
BLOCK="$TMP_DIR/step4.sh"
awk '
  /^### 4\. commit/ { in_sec = 1; next }
  in_sec && /^### / { exit }
  in_sec && /^```bash$/ { in_block = 1; next }
  in_block && /^```$/ { exit }
  in_block { print }
' "$SKILL" > "$BLOCK"

# 切り出しが空振りすると「commit されないこと」を期待する 2 ケースが自動的に緑になる。
# 実行前に中身を assert して fail-closed にする。
BLOCK_GUARD='if [ -n "${SYNC_SRC_SHA:-}" ] && [ "$(git rev-parse HEAD)" = "$SYNC_SRC_SHA" ]; then'
if [[ -s "$BLOCK" ]] && grep -qF -- "$BLOCK_GUARD" "$BLOCK" \
  && grep -qF -- 'ff-sync-src-sha' "$BLOCK"; then
  ok "手順 4 のコードブロックを切り出せた（突合の if と記録の読み取りを含む）"
else
  bad "手順 4 のコードブロックを切り出せない（空振りのまま後続を緑にしない）"
  echo "✗ src-sha runtime: 切り出し失敗のため以降のケースを実行しません" >&2
  exit 1
fi

# push 先をローカル bare へ差し替える（同期スクリプトの origin ガードは公開 URL を
# 要求するため、同期を回す区間と push する区間で使い分ける）。
use_bare_origin()   { git -C "$PUB" remote set-url origin "$BARE"; }
use_public_origin() { git -C "$PUB" remote set-url origin "$PUBLIC_ORIGIN_URL"; }

run_step4() {
  # 手順 4 を「別プロセス」として実行する。シェル変数は一切引き継がない。
  # 判定は commit の有無と出力で行うので、終了コードは握って先へ進む。
  (cd "$SSOT" && PUBLIC="$PUB" bash "$BLOCK" 2>&1) || true
}

git -C "$PUB" add -A
use_bare_origin
PUB_HEAD_BEFORE="$(git -C "$PUB" rev-parse HEAD)"

# B1（GWT3）: 記録が無ければ commit しない。
mv "$RECORD" "$TMP_DIR/record.bak"
STEP4_OUT="$(run_step4)"
if [[ "$(git -C "$PUB" rev-parse HEAD)" == "$PUB_HEAD_BEFORE" && "$STEP4_OUT" == *NG* ]]; then
  ok "記録が無ければ commit せず中断する（不在を「一致」と扱わない）"
else
  bad "記録が無いのに commit された（出力: ${STEP4_OUT}）"
fi
mv "$TMP_DIR/record.bak" "$RECORD"

# B2（GWT2）: 同期後に SSOT の HEAD が動いていたら commit しない（#634 の不変条件）。
git -C "$SSOT" commit -q --allow-empty -m "concurrent merge"
STEP4_OUT="$(run_step4)"
if [[ "$(git -C "$PUB" rev-parse HEAD)" == "$PUB_HEAD_BEFORE" && "$STEP4_OUT" == *NG* ]]; then
  ok "同期後に SSOT の HEAD が動いていたら commit しない"
else
  bad "HEAD が動いたのに commit された（出力: ${STEP4_OUT}）"
fi
git -C "$SSOT" reset -q --hard "$SYNCED_SHA"

# B3（GWT1）: 別プロセスでも、reset --hard / clean -fd を挟まずに commit + push まで進む。
SHORT_SHA="$(git -C "$SSOT" rev-parse --short "$SYNCED_SHA")"
# 期待する commit subject は組み立てる（SSOT リポジトリ名は禁止パターンなので、
# 公開される本ファイルへ literal で書けない）。
EXPECTED_SUBJECT="$(printf 'sync: %s%s %s を反映' 'feelflow' '-plugins' "$SHORT_SHA")"
STEP4_OUT="$(run_step4)"
PUB_SUBJECT="$(git -C "$PUB" log -1 --format=%s 2>/dev/null || true)"
if [[ "$(git -C "$PUB" rev-parse HEAD)" != "$PUB_HEAD_BEFORE" ]] \
  && [[ "$PUB_SUBJECT" == "$EXPECTED_SUBJECT" ]]; then
  ok "別プロセスの手順 4 が、同期した内容の SHA で commit する（やり直し不要）"
else
  bad "別プロセスの手順 4 が commit していない（subject=${PUB_SUBJECT} / 出力: ${STEP4_OUT}）"
fi
if [[ "$(git -C "$BARE" rev-parse main 2>/dev/null || true)" == "$(git -C "$PUB" rev-parse main)" ]]; then
  ok "手順 4 の push が通り、公開側の main が更新される"
else
  bad "手順 4 の push が反映されていない"
fi

# ---- A2. 記録は公開リポジトリの内容に出ない --------------------------------
PORCELAIN="$(git -C "$PUB" status --porcelain)"
if [[ -z "$PORCELAIN" ]]; then
  ok "commit 後の target は clean（記録が作業ツリーへ漏れていない）"
else
  bad "commit 後の target に差分が残る（記録が .git の外にある疑い）: ${PORCELAIN}"
fi
TRACKED="$(git -C "$PUB" ls-files)"
case "$TRACKED" in
  *ff-sync-src-sha*) bad "記録が公開リポジトリの追跡対象に入っている" ;;
  *) ok "記録は公開リポジトリの追跡対象に入らない" ;;
esac

# ---- A3. `--delete` ミラーを跨いでも記録は消えず、新しい SHA へ更新される ----
use_public_origin
printf '# Fixture plugin (updated)\n' > "$SSOT/plugins/ff-dev-toolkit/README.md"
git -C "$SSOT" commit -q -am "second change"
SECOND_SHA="$(git -C "$SSOT" rev-parse HEAD)"
SYNC_RC=0
SYNC_OUT="$(run_sync)" || SYNC_RC=$?
if [[ "$SYNC_RC" -eq 0 && -f "$RECORD" && "$(cat "$RECORD")" == "$SECOND_SHA" ]]; then
  ok "2 回目の同期でも記録は --delete ミラーに消されず、新しい SHA へ更新される"
else
  bad "2 回目の同期後の記録が不正（rc=${SYNC_RC} / 記録=$(cat "$RECORD" 2>/dev/null || echo '<不在>')）"
fi
git -C "$PUB" add -A
git -C "$PUB" commit -q -m "second sync"

# ---- A4. dry-run は記録を作らず、既にある記録も壊さない ----------------------
# (a) 記録がある状態の --dry-run。テスト側が事前に記録を消してから回すと、
#     同期スクリプトの `rm -f` を `if [[ "$DRY_RUN" -eq 0 ]]` の外へ出す変異が
#     (b) を素通りする（消える前からもう無いため）。A3 の同期が残した記録
#     （${SECOND_SHA}）が値ごと残ることを、消す前に見る。
SYNC_RC=0
SYNC_OUT="$(run_sync --dry-run)" || SYNC_RC=$?
DRY_RECORD="$(cat "$RECORD" 2>/dev/null || true)"
if [[ "$SYNC_RC" -eq 0 && "$DRY_RECORD" == "$SECOND_SHA" ]]; then
  ok "--dry-run は既にある記録を消さず値も変えない（書き込まない実行が記録を壊さない）"
else
  bad "--dry-run が既存の記録を壊した（rc=${SYNC_RC} / 記録=${DRY_RECORD:-<不在>} / 期待=${SECOND_SHA}）"
fi
# (b) 記録が無い状態の --dry-run。書き込みを伴わない実行を「同期済み」にしない。
rm -f "$RECORD"
SYNC_RC=0
SYNC_OUT="$(run_sync --dry-run)" || SYNC_RC=$?
if [[ "$SYNC_RC" -eq 0 && ! -f "$RECORD" ]]; then
  ok "--dry-run は記録を作らない（書き込みを伴わない実行を「同期済み」にしない）"
else
  bad "--dry-run が記録を作った（rc=${SYNC_RC}）"
fi

# ---- A6. worktree target はミラー前にガードで中断する（Issue #901） ----------
# `--exclude '.git/'` は末尾スラッシュのためディレクトリにしか一致せず、linked
# worktree の file 形式 `.git` は `--delete` ミラーの削除対象になる（target が git
# から切り離される）。書き込みへ入る前の fail-closed 中断と、--dry-run にも同じ
# ガードが掛かること（dry-run が通って本実行だけ落ちる非対称を作らない）を実測で
# 固定する。通常 clone（ディレクトリ形式 `.git`）の非退行は A1〜A4 の run_sync が
# ${PUB}（通常 clone 相当）で成功していることが既に固定している。
WT="$TMP_DIR/pub-worktree"
git -C "$PUB" worktree add -q -b wt-target "$WT" main \
  || { echo "✗ fixture の worktree を作成できません（以降のケースを空振りで緑にしない）" >&2; exit 1; }
WT_RC=0
WT_OUT="$("$SSOT/scripts/sync-dev-toolkit-to-public.sh" --target "$WT" 2>&1)" || WT_RC=$?
if [[ "$WT_RC" -ne 0 && "$WT_OUT" == *"worktree target は使えません"* && -f "$WT/.git" ]]; then
  ok "worktree target（file 形式 .git）は書き込み前にガードで中断し、.git も無傷で残る"
else
  bad "worktree target が中断しない（rc=${WT_RC} / .git=$([[ -e "$WT/.git" ]] && { [[ -d "$WT/.git" ]] && echo dir || echo file; } || echo '<消失>') / 出力: ${WT_OUT}）"
fi
WT_RC=0
WT_OUT="$("$SSOT/scripts/sync-dev-toolkit-to-public.sh" --target "$WT" --dry-run 2>&1)" || WT_RC=$?
if [[ "$WT_RC" -ne 0 && "$WT_OUT" == *"worktree target は使えません"* ]]; then
  ok "worktree target は --dry-run でも同じガードで中断する"
else
  bad "worktree target の --dry-run が中断しない（rc=${WT_RC} / 出力: ${WT_OUT}）"
fi
# ガード退行時は worktree の .git がミラーに消され `worktree remove` 自体が失敗する。
# クリーンアップの失敗で suite を即死させると、退行検出時に限って A5 以降と
# サマリーが失われるため、fallback（実体削除 + prune）で必ず後続へ進む。
git -C "$PUB" worktree remove --force "$WT" 2>/dev/null \
  || { rm -rf "$WT"; git -C "$PUB" worktree prune; }
git -C "$PUB" branch -q -D wt-target \
  || { echo "✗ fixture の wt-target branch を削除できません" >&2; exit 1; }

# symlink 形式 `.git`（.git -> 実 git ディレクトリ）もガードで弾く。`-d` は symlink を
# 追跡して真になる一方、rsync の `--exclude '.git/'` は symlink に一致しないため、
# `-d` 単独のガードでは「ガードは通るのにミラーが .git を消す」fail-open になる
# （Codex / silent-failure-hunter が独立に指摘し実測で確認）。
SYM="$TMP_DIR/pub-symlink"
mkdir -p "$SYM"
ln -s "$PUB/.git" "$SYM/.git"
SYM_RC=0
SYM_OUT="$("$SSOT/scripts/sync-dev-toolkit-to-public.sh" --target "$SYM" 2>&1)" || SYM_RC=$?
if [[ "$SYM_RC" -ne 0 && "$SYM_OUT" == *"worktree target は使えません"* && -L "$SYM/.git" ]]; then
  ok "symlink 形式 .git の target もガードで中断し、symlink も無傷で残る"
else
  bad "symlink 形式 .git の target が中断しない（rc=${SYM_RC} / .git=$([[ -L "$SYM/.git" ]] && echo symlink || { [[ -e "$SYM/.git" ]] && echo あり || echo '<消失>'; }) / 出力: ${SYM_OUT}）"
fi
rm -rf "$SYM"

# ---- A5. 中断した同期は記録を残さない（書き込み前に必ず消す） ----------------
# 前回の記録が残ったまま同期が途中で落ちると、手順 4 がそれを読んで部分同期を
# commit する（fail-open）。禁止パターン検査で落ちる入力を与え、事前に置いた
# 記録が消えていることを見る。
#
# 測定範囲の但し書き: 本ケースが狙っているのは変異 M1（`rm -f` そのものの削除）
# の検出であって、`rm -f` の**位置**を禁止パターン検査より前に固定することでは
# ない。契約は「ミラー書き込みの前に消す」（verify.sh の順序検査 L_RM < L_RSYNC）
# なので、`rm -f` を staging 構築・scan の後・rsync の直前へ動かすリファクタは
# 契約を満たす。その形にすると本ケースは赤くなるので、そのときは契約側（順序
# 検査）が緑であることを確認したうえで、落ちる入力を rsync 以降で失敗するものへ
# 差し替えること — 記録を残さない対象は「ミラー書き込みへ入った同期」である。
SENTINEL="0123456789abcdef0123456789abcdef01234567"
printf '%s\n' "$SENTINEL" > "$RECORD"
forbidden_sample="$(printf '%s%s' 'plugins/' 'dev-toolkit')"
printf '%s\n' "$forbidden_sample" >> "$SSOT/plugins/ff-dev-toolkit/README.md"
git -C "$SSOT" commit -q -am "inject forbidden pattern"
SYNC_RC=0
SYNC_OUT="$(run_sync)" || SYNC_RC=$?
if [[ "$SYNC_RC" -ne 0 && ! -f "$RECORD" ]]; then
  ok "同期が中断すると記録は残らない（古い記録が「同期済み」に化けない）"
else
  bad "中断した同期の後に記録が残っている（rc=${SYNC_RC} / 記録=$(cat "$RECORD" 2>/dev/null || echo '<不在>')）"
fi

if [[ "$FAIL" -gt 0 ]]; then
  echo "✗ src-sha runtime: $FAIL 件失敗 / $PASS 件成功" >&2
  exit 1
fi
echo "✓ src-sha runtime: 全 $PASS 件 pass"
