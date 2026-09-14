#!/usr/bin/env bash
#
# review-wrapper-shim suite の検査ファイル（verify.sh から source される。単独実行不可）。
# 範囲: diff サイズ歯止めの計測基準 ref が委譲先（resolve_base_branch_ref）と一致すること（origin/<base> 解決・stale ローカル・解決不能・adapter 不在・toolkit 未解決）。
# 依存: run_shim（RUN_SHIM_CWD / RUN_SHIM_TOOLKIT）。Git fixture はこのファイル内で作る。
# source 順は verify.sh の一覧が正本。fixture・関数・変数は同一プロセスで共有され、
# 後続ファイルは先行ファイルが作った fixture を参照するので、順序を入れ替えない。

# ── 計測基準の ref は委譲先が解決する ref と同じにする ──────────────────────────
#
# 委譲先（multi-agent.sh → resolve_base_branch_ref）は、ローカル `<base>` が無い
# クローンや stale なローカル `<base>` では `origin/<base>` をレビュー対象にする。
# 歯止めを**生の `--base` の値**で測ると 2 つの形で壊れる:
#   1. ローカル `<base>` の無いクローン（`git clone --branch <feature>` / CI）では
#      `git diff develop...HEAD` 自体が失敗し、「diff を測れませんでした」で exit 2 —
#      委譲先なら origin/develop で普通にレビューできるのに 1 つも届かない
#   2. ローカル `<base>` が stale なときは、古い基準で測って新しい基準でレビューする
#      （CODEX_REVIEW_MAX_DIFF_BYTES で課金を抑えている前提が静かに崩れる）
# fixture は remote-tracking ref を直接置いて作る（ネットワークに触らない）。

# (1) ローカル develop が無く、origin/develop だけがある
NOBASE_REPO="$WORK/nobase-repo"
ff_git_fixture_init "$NOBASE_REPO"
git -C "$NOBASE_REPO" checkout -q -b feature
printf 'base\n' > "$NOBASE_REPO/app.txt"
git -C "$NOBASE_REPO" add app.txt
git -C "$NOBASE_REPO" commit -qm base
NOBASE_BASE_SHA="$(git -C "$NOBASE_REPO" rev-parse HEAD)"
printf 'changed\n' >> "$NOBASE_REPO/app.txt"
git -C "$NOBASE_REPO" add app.txt
git -C "$NOBASE_REPO" commit -qm changed
git -C "$NOBASE_REPO" update-ref refs/remotes/origin/develop "$NOBASE_BASE_SHA"
if [ -z "$(git -C "$NOBASE_REPO" branch --list develop)" ]; then
  ok "fixture: ローカル develop が無く origin/develop だけがある"
else
  bad "fixture: ローカル develop が残っている（ローカル base 無しのケースが成立しない）"
fi
RUN_SHIM_CWD="$NOBASE_REPO" run_shim CODEX_REVIEW_MAX_DIFF_BYTES=1000000 --base develop --dry-run
if [ "$RUN_RC" -eq 0 ] && [ -s "$WORK/argv.log" ]; then
  ok "ローカル base の無いクローンでも origin/<base> で測り、委譲先まで届く"
else
  bad "ローカル base の無いクローンで diff サイズを測れず委譲が止まった (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/out.log" >&2
fi

# (2) ローカル develop が origin/develop より stale（真の祖先）
STALE_REPO="$WORK/stale-base-repo"
ff_git_fixture_init "$STALE_REPO"
git -C "$STALE_REPO" checkout -q -b develop
printf 'base\n' > "$STALE_REPO/app.txt"
git -C "$STALE_REPO" add app.txt
git -C "$STALE_REPO" commit -qm base
git -C "$STALE_REPO" checkout -q -b feature
# origin/develop はローカル develop の 1 コミット先。差分が両基準で明確に違うよう、
# origin 側だけに大きめのファイルを入れる。
awk 'BEGIN { for (i = 0; i < 400; i++) print "filler line " i }' > "$STALE_REPO/filler.txt"
git -C "$STALE_REPO" add filler.txt
git -C "$STALE_REPO" commit -qm "origin advance"
git -C "$STALE_REPO" update-ref refs/remotes/origin/develop "$(git -C "$STALE_REPO" rev-parse HEAD)"
printf 'changed\n' >> "$STALE_REPO/app.txt"
git -C "$STALE_REPO" add app.txt
git -C "$STALE_REPO" commit -qm changed
# 委譲先が使う基準（origin/develop）での実測バイト数。シムは BASE...HEAD に加えて
# 作業ツリーの変更も測るので、同じ 2 本を足して比べる。
STALE_ORIGIN_BYTES="$( { git -C "$STALE_REPO" diff origin/develop...HEAD; git -C "$STALE_REPO" diff HEAD; } | wc -c | tr -d ' ')"
STALE_LOCAL_BYTES="$( { git -C "$STALE_REPO" diff develop...HEAD; git -C "$STALE_REPO" diff HEAD; } | wc -c | tr -d ' ')"
if [ "$STALE_LOCAL_BYTES" -gt "$STALE_ORIGIN_BYTES" ]; then
  ok "fixture: stale なローカル base の方が大きく測れる（両基準を判別できる）"
else
  bad "fixture: 2 つの基準の diff サイズが判別できない（local=${STALE_LOCAL_BYTES} origin=${STALE_ORIGIN_BYTES}）"
fi
# 上限をちょうど origin 基準のバイト数に置く。委譲先と同じ基準で測っていれば超えず、
# 生の develop（stale）で測ると超えて rc=3 になる。
RUN_SHIM_CWD="$STALE_REPO" run_shim "CODEX_REVIEW_MAX_DIFF_BYTES=$STALE_ORIGIN_BYTES" --base develop --dry-run
if [ "$RUN_RC" -eq 0 ] && [ -s "$WORK/argv.log" ]; then
  ok "ローカル base が stale でも委譲先と同じ ref で測る（上限判定が一致する）"
else
  bad "stale なローカル base で測っており、レビュー範囲と歯止めの基準がずれている (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/out.log" >&2
fi

# (3) 解決できない名前は素通し。従来どおり「測れない」で非 0 のまま（歯止めを
#     要求されたのに測れないまま課金される実行を始めない）。
RUN_SHIM_CWD="$NOBASE_REPO" run_shim CODEX_REVIEW_MAX_DIFF_BYTES=1000000 --base nosuchbase --dry-run
if [ "$RUN_RC" -ne 0 ] && [ ! -s "$WORK/argv.log" ] \
   && grep -q 'diff を測れませんでした' "$WORK/out.log"; then
  ok "解決できない base 名は素通しのまま「測れない」で非 0"
else
  bad "解決できない base 名の扱いが退行した (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/out.log" >&2
fi

# (4)(5) 解決実装に届かない toolkit では、生の値へ落ちること自体は正しい（委譲先にも
#        resolve_base_branch_ref が無いので、生の値の方が委譲先のレビュー範囲と一致する）。
#        ただし**黙って**落ちると、歯止めがどちらの基準で測ったのか後から分からない。
#        WARNING が stderr に出ることを実測する（rc は従来どおり——ハードエラーにしない）。
NOADAPTER_TOOLKIT="$WORK/toolkit-no-adapter"
cp -R "$TOOLKIT" "$NOADAPTER_TOOLKIT"
rm -f "$NOADAPTER_TOOLKIT/scripts/adapters/adapter-common.sh"
RUN_SHIM_CWD="$NOBASE_REPO" RUN_SHIM_TOOLKIT="$NOADAPTER_TOOLKIT" \
  run_shim CODEX_REVIEW_MAX_DIFF_BYTES=1000000 --base develop --dry-run
unset RUN_SHIM_TOOLKIT  # bash では関数呼び出し前置の代入が呼び出し後も残る（後続ケースへ漏らさない）
if grep -q 'WARNING: base ref の解決実装が見つかりませんでした' "$WORK/err.log" \
   && grep -q '生の値 develop で diff サイズを測ります' "$WORK/err.log"; then
  ok "adapter-common.sh が無い toolkit では WARNING を出してから生の値へ落ちる"
else
  bad "adapter-common.sh が無い toolkit で無警告のまま生の値へ落ちている"
  sed 's/^/    | /' "$WORK/out.log" >&2
fi

STUBADAPTER_TOOLKIT="$WORK/toolkit-stub-adapter"
cp -R "$TOOLKIT" "$STUBADAPTER_TOOLKIT"
# adapter は読めるが resolve_base_branch_ref を持たない（解決実装より前の版）。
cat > "$STUBADAPTER_TOOLKIT/scripts/adapters/adapter-common.sh" <<'SH'
#!/usr/bin/env bash
# resolve_base_branch_ref を持たない旧 adapter を模す
ff_adapter_common_loaded=1
SH
RUN_SHIM_CWD="$NOBASE_REPO" RUN_SHIM_TOOLKIT="$STUBADAPTER_TOOLKIT" \
  run_shim CODEX_REVIEW_MAX_DIFF_BYTES=1000000 --base develop --dry-run
unset RUN_SHIM_TOOLKIT  # bash では関数呼び出し前置の代入が呼び出し後も残る（後続ケースへ漏らさない）
if grep -q 'WARNING: base ref を委譲先と同じ実装で解決できませんでした' "$WORK/err.log" \
   && grep -q '生の値 develop で diff サイズを測ります' "$WORK/err.log"; then
  ok "解決関数を持たない adapter でも WARNING を出してから生の値へ落ちる"
else
  bad "解決関数を持たない adapter で無警告のまま生の値へ落ちている"
  sed 's/^/    | /' "$WORK/out.log" >&2
fi

# 履歴差分を使う検査は、checkout 側の fetch-depth や直近コミットが空かどうかに
# 依存させない。2つの非空コミットを持つ専用 fixture で HEAD~1 を必ず成立させる。
DIFF_REPO="$WORK/diff-repo"
ff_git_fixture_init "$DIFF_REPO"
printf 'base\n' > "$DIFF_REPO/app.txt"
git -C "$DIFF_REPO" add app.txt
git -C "$DIFF_REPO" commit -qm base
printf 'changed\n' >> "$DIFF_REPO/app.txt"
git -C "$DIFF_REPO" add app.txt
git -C "$DIFF_REPO" commit -qm changed

# (6) toolkit そのものを解決できない経路も黙って生の値へ落とさない。歯止めは委譲より**前**に
#     走り、小 diff なら skip して exit 0 で終わる —— つまり委譲段の ERROR には到達しないので、
#     ここで黙ると「どの基準で測って skip したか」がどこにも残らない。(4)(5) と同水準の
#     WARNING を出すこと（rc は従来どおり。ハードエラーにはしない）。
RUN_SHIM_CWD="$DIFF_REPO" RUN_SHIM_TOOLKIT="$WORK/no-such-toolkit" \
  run_shim CODEX_REVIEW_MIN_LINES=999999 --base HEAD~1
unset RUN_SHIM_TOOLKIT
if [ "$RUN_RC" -eq 0 ] && [ ! -s "$WORK/argv.log" ] \
   && grep -q 'WARNING: toolkit を解決できなかったため base ref を解決できません' "$WORK/err.log" \
   && grep -q '生の値 HEAD~1 で diff サイズを測ります' "$WORK/err.log" \
   && grep -q 'CODEX_REVIEW_MIN_LINES' "$WORK/err.log"; then
  ok "toolkit を解決できない経路でも、歯止めで skip する前に測定基準を WARNING で残す"
else
  bad "toolkit 未解決のまま無警告で生の値へ落ち、skip の測定基準が記録に残らない (rc=$RUN_RC)"
  sed 's/^/    | /' "$WORK/out.log" >&2
fi

# pipefail コメントは条件を反転させない。マスクが起きるのは pipefail が**無い**ときで、
# 「pipefail 下でもマスクされる」と読める記述は、`set -o pipefail` を対処法として明記して
# いる消費側プロジェクトに自分の SSOT を疑わせる（構造そのもの——rc と tail を分ける——は
# 正しいので変えない。直すのは根拠の書き方だけ）。
if grep -q 'pipefail 下でも' "$SHIM"; then
  bad "pipefail コメントが条件を反転している（マスクは pipefail が無いときに起きる）"
elif grep -q 'pipefail が無い環境では' "$SHIM" && grep -q 'pipefail 下では非 0 が保たれる' "$SHIM"; then
  ok "pipefail コメントがマスクの起きる条件（pipefail が無い環境）を正しく書いている"
else
  bad "pipefail コメントからマスクの条件が読み取れない"
fi

